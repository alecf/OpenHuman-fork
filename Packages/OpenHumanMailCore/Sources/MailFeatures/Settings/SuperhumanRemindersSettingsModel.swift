import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class SuperhumanRemindersSettingsModel {
    public enum Phase: Equatable {
        case idle
        case counting
        case preview(SuperhumanReminderImportPreview)
        case applying
        case applied(String)
        case failed(String)
    }

    public let hide: StoredSetting<Bool>
    public let senders: StoredSetting<[String]>
    public let archiveInGmail: StoredSetting<Bool>
    public let availability: SettingsAvailability
    public var sendersText = ""
    public private(set) var sendersError: String?
    public private(set) var phase: Phase = .idle
    public private(set) var unmatched: [SuperhumanReminderEmail] = []
    public private(set) var scanUnavailable = false

    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored private let commands: (any MailCommanding)?
    @ObservationIgnored private let undo: UndoCoordinator?
    @ObservationIgnored private let accounts: @Sendable () async -> [AccountID]
    @ObservationIgnored private let scan: @Sendable (AccountID) async throws -> [SuperhumanReminderEmail]
    @ObservationIgnored private var undoEntry: UndoCoordinator.Entry.ID?
    @ObservationIgnored private var lastImport: UndoToken?
    @ObservationIgnored private var sendersTask: Task<Void, Never>?

    public init(settings: (any SettingsPort)?, commands: (any MailCommanding)?, undo: UndoCoordinator?,
                availability: SettingsAvailability, accounts: @escaping @Sendable () async -> [AccountID],
                scan: @escaping @Sendable (AccountID) async throws -> [SuperhumanReminderEmail]) {
        self.settings = settings
        self.commands = commands
        self.undo = undo
        self.availability = availability
        self.accounts = accounts
        self.scan = scan
        hide = StoredSetting(AppSettings.superhumanRemindersHide, port: settings)
        senders = StoredSetting(AppSettings.superhumanReminderSenders, port: settings)
        archiveInGmail = StoredSetting(AppSettings.superhumanRemindersArchiveInGmail, port: settings)
        sendersText = Self.text(AppSettings.superhumanReminderSenders.defaultValue)
    }

    public convenience init(environment: AppEnvironment) {
        let data = environment.data
        self.init(settings: environment.settings, commands: environment.commands, undo: environment.undo,
                  availability: SettingsAvailability(environment: environment),
                  accounts: {
                      do {
                          for try await list in data.accounts() { return list.map(\.id) }
                      } catch {}
                      return []
                  },
                  scan: { try await data.superhumanReminderEmails($0, limit: SuperhumanReminderImport.scanLimit) })
    }

    isolated deinit {
        sendersTask?.cancel()
    }

    public func start() {
        hide.start()
        senders.start()
        archiveInGmail.start()
        if sendersTask == nil, let settings {
            sendersTask = Task { [weak self] in
                for await list in settings.observe(AppSettings.superhumanReminderSenders) {
                    guard !Task.isCancelled, let self else { return }
                    self.sendersText = Self.text(list)
                }
            }
        }
        Task { await refreshUnmatched() }
    }

    public nonisolated static func parseSenders(_ text: String) -> [String]? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }).map { $0.lowercased() }
        guard !parts.isEmpty else { return nil }
        var seen = Set<String>()
        var out: [String] = []
        for part in parts {
            guard let at = part.firstIndex(of: "@"), at != part.startIndex, part.index(after: at) != part.endIndex,
                  part[part.index(after: at)...].contains(".") else { return nil }
            if seen.insert(part).inserted { out.append(part) }
        }
        return out
    }

    public nonisolated static func text(_ senders: [String]) -> String { senders.joined(separator: ", ") }

    public func commitSenders() async {
        guard let list = Self.parseSenders(sendersText) else {
            sendersError = Self.sendersInvalid
            return
        }
        sendersError = nil
        guard list != senders.value else { return }
        await senders.set(list)
        await refreshUnmatched()
    }

    public func resetSenders() async {
        sendersText = Self.text(AppSettings.superhumanReminderSenders.defaultValue)
        await commitSenders()
    }

    public var canImport: Bool { availability.canEditSettings && hide.value && !scanUnavailable }

    public func findReminders() async {
        guard let settings else { return }
        phase = .counting
        let importer = SuperhumanReminderImport(settings: settings, commands: commands, scan: scan)
        do {
            let preview = try await importer.preview(accounts: await accounts())
            phase = .preview(preview)
            unmatched = await notDismissed(preview.unmatched)
        } catch let error as MailPortError {
            if case .unsupported = error { scanUnavailable = true }
            phase = .failed(Self.scanFailed)
        } catch {
            phase = .failed(Self.scanFailed)
        }
    }

    public func cancelPreview() {
        if case .preview = phase { phase = .idle }
    }

    public func applyImport() async {
        guard case .preview(let preview) = phase, let settings else { return }
        phase = .applying
        let importer = SuperhumanReminderImport(settings: settings, commands: canWriteMail ? commands : nil, scan: scan)
        do {
            let (token, skipped) = try await importer.apply(preview, archiveInGmail: archiveInGmail.value)
            phase = .applied(Self.appliedText(preview, skipped: skipped))
            guard !token.changesNothing else { return }
            lastImport = token
            if let undo {
                let entry = UndoCoordinator.Entry(title: Self.undoTitle(preview.changeCount - skipped), token: token,
                                                  undoer: SuperhumanReminderImportUndoer(settings: settings, commands: commands))
                undo.push(entry)
                undoEntry = entry.id
            }
        } catch {
            phase = .failed(Self.importFailed)
        }
    }

    public var canUndoImport: Bool {
        guard lastImport != nil else { return false }
        guard let undo, let undoEntry else { return true }
        return undo.stack.contains { $0.id == undoEntry }
    }

    public func undoImport() async {
        guard canUndoImport, let token = lastImport, let settings else { return }
        lastImport = nil
        if let undo, let undoEntry {
            await undo.undo(entryID: undoEntry)
        } else {
            do { _ = try await SuperhumanReminderImportUndoer(settings: settings, commands: commands).undo(token) } catch {
                phase = .failed(Self.undoFailed)
                return
            }
        }
        undoEntry = nil
        phase = .idle
        await refreshUnmatched()
    }

    public func dismiss(_ email: SuperhumanReminderEmail) async {
        unmatched.removeAll { $0.id == email.id }
        guard let settings else { return }
        let key = AppSettings.superhumanRemindersDismissed(email.id.account)
        var dismissed = (try? await settings.get(key)) ?? []
        let id = email.id.gmailMessageID.rawValue
        guard !dismissed.contains(id) else { return }
        dismissed.append(id)
        try? await settings.set(key, dismissed)
    }

    func refreshUnmatched() async {
        var found: [SuperhumanReminderEmail] = []
        for account in await accounts() {
            do {
                found += try await scan(account).filter { $0.target == nil }
            } catch let error as MailPortError {
                if case .unsupported = error { scanUnavailable = true }
                return
            } catch {
                return
            }
        }
        unmatched = await notDismissed(found)
    }

    private func notDismissed(_ emails: [SuperhumanReminderEmail]) async -> [SuperhumanReminderEmail] {
        guard let settings else { return emails }
        var dismissed: [AccountID: Set<String>] = [:]
        for account in Set(emails.map(\.id.account)) {
            dismissed[account] = Set((try? await settings.get(AppSettings.superhumanRemindersDismissed(account))) ?? [])
        }
        return emails.filter { !(dismissed[$0.id.account]?.contains($0.id.gmailMessageID.rawValue) ?? false) }
    }

    private var canWriteMail: Bool { availability.canEditStoredItems }

    public static let sectionTitle = "Superhuman reminders"
    public static let hideTitle = "Hide Superhuman reminder emails"
    public static let hideNote = "Superhuman brings a reminder back by sending you an email. Mail hides those emails on "
        + "this Mac and shows the conversation as a returned reminder at the top of the inbox. Nothing changes in Gmail."
    public static let senderTitle = "Reminder sender"
    public static let senderNote = "The address Superhuman's reminder emails come from. Separate several with commas."
    public static let sendersInvalid = "Enter one or more email addresses, separated by commas."
    public static let archiveTitle = "Also archive them in Gmail"
    public static let archiveNote = "When the import matches a reminder email that came as a conversation of its own, it "
        + "also archives that email in Gmail. You can undo it."
    public static let importTitle = "Import Superhuman reminders"
    public static let importNote = "For reminder emails that arrived before Mail: hides them and shows their "
        + "conversations as returned reminders. Mail counts first; nothing changes until you confirm, and one undo takes "
        + "it all back."
    public static let pendingNote = "Reminders still waiting in Superhuman are kept on Superhuman's servers. Mail can't "
        + "see or bring them over. If Superhuman sends one later as an email, Mail handles it when it arrives."
    public static let couldNotMatchTitle = "Could not match"
    public static let couldNotMatchNote = "Mail couldn't tell which conversation this reminder email is about, so it "
        + "stays in your inbox."
    public static let scanFailed = "Mail couldn't look for reminder emails. Try again."
    public static let importFailed = "The import didn't go through. Nothing was changed."
    public static let undoFailed = "Couldn't undo the import."
    public static let unavailableNote = "Not available with this mail source."

    public static func undoTitle(_ count: Int) -> LocalizedStringResource {
        count == 1 ? "Imported 1 Superhuman reminder" : "Imported \(count) Superhuman reminders"
    }

    public static func summary(_ preview: SuperhumanReminderImportPreview) -> String {
        guard preview.found > 0 else { return "No Superhuman reminder emails on this Mac." }
        var parts = [preview.found == 1 ? "1 reminder email found." : "\(preview.found) reminder emails found."]
        if preview.changeCount > 0 {
            let conversations = preview.conversationCount == 1 ? "1 conversation" : "\(preview.conversationCount) conversations"
            parts.append("\(preview.changeCount) will be hidden and \(conversations) shown as returned reminders.")
        }
        let back = preview.conversationsToBringBack.count
        if back > 0 {
            parts.append(back == 1 ? "1 conversation comes back to the inbox in Gmail."
                                   : "\(back) conversations come back to the inbox in Gmail.")
        }
        if !preview.unmatched.isEmpty {
            parts.append(preview.unmatched.count == 1 ? "1 could not be matched and stays visible."
                                                      : "\(preview.unmatched.count) could not be matched and stay visible.")
        }
        if preview.alreadyHandled > 0 {
            parts.append(preview.alreadyHandled == 1 ? "1 is already hidden." : "\(preview.alreadyHandled) are already hidden.")
        }
        return parts.joined(separator: " ")
    }

    static func appliedText(_ preview: SuperhumanReminderImportPreview, skipped: Int) -> String {
        let done = preview.changeCount - skipped
        var text = done == 1 ? "Imported 1 reminder." : "Imported \(done) reminders."
        if skipped > 0 {
            text += skipped == 1 ? " 1 matched reminder was left as it was: Mail can't change Gmail right now."
                                 : " \(skipped) matched reminders were left as they were: Mail can't change Gmail right now."
        }
        return text
    }
}
