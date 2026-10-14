import Foundation
import MailModel
import OpenHumanCore

public struct SuperhumanReminderImportPreview: Sendable, Equatable {
    public var inConversation: [SuperhumanReminderEmail]
    public var matched: [SuperhumanReminderEmail]
    public var unmatched: [SuperhumanReminderEmail]
    public var alreadyHandled: Int

    public init(inConversation: [SuperhumanReminderEmail] = [], matched: [SuperhumanReminderEmail] = [],
                unmatched: [SuperhumanReminderEmail] = [], alreadyHandled: Int = 0) {
        self.inConversation = inConversation
        self.matched = matched
        self.unmatched = unmatched
        self.alreadyHandled = alreadyHandled
    }

    public static func make(_ emails: [SuperhumanReminderEmail]) -> SuperhumanReminderImportPreview {
        var preview = SuperhumanReminderImportPreview()
        for email in emails {
            if email.isHidden {
                preview.alreadyHandled += 1
                continue
            }
            switch email.match {
            case .sameConversation: preview.inConversation.append(email)
            case .replyHeaders: preview.matched.append(email)
            case .unmatched: preview.unmatched.append(email)
            }
        }
        return preview
    }

    public var changeCount: Int { inConversation.count + matched.count }
    public var conversationCount: Int { Set((inConversation + matched).compactMap(\.target)).count }
    public var found: Int { changeCount + unmatched.count + alreadyHandled }

    public var conversationsToBringBack: [ThreadKey] {
        Self.unique(matched.filter { $0.isInInbox && !$0.targetInInbox }.compactMap(\.target))
    }

    public var conversationsToArchive: [ThreadKey] {
        Self.unique(matched.filter(\.isInInbox).map(\.thread))
    }

    private static func unique(_ keys: [ThreadKey]) -> [ThreadKey] {
        var seen = Set<ThreadKey>()
        return keys.filter { seen.insert($0).inserted }
    }
}

struct SuperhumanReminderImportReceipt: Codable, Sendable, Equatable {
    struct AccountChange: Codable, Sendable, Equatable {
        var account: AccountID
        var addedConverted: [String] = []
        var addedReturned: [String] = []
        var previousReturned: [String: Int64] = [:]
    }

    var backlogBefore = false
    var backlogChanged = false
    var accounts: [AccountChange] = []
    var commandTokens: [Data] = []
    var skippedMatched = 0

    var changesNothing: Bool {
        !backlogChanged && commandTokens.isEmpty
            && accounts.allSatisfy { $0.addedConverted.isEmpty && $0.addedReturned.isEmpty && $0.previousReturned.isEmpty }
    }
}

public struct SuperhumanReminderImport: Sendable {
    public static let scanLimit = 5000

    let settings: any SettingsPort
    let commands: (any MailCommanding)?
    let scan: @Sendable (AccountID) async throws -> [SuperhumanReminderEmail]

    public init(settings: any SettingsPort, commands: (any MailCommanding)?,
                scan: @escaping @Sendable (AccountID) async throws -> [SuperhumanReminderEmail]) {
        self.settings = settings
        self.commands = commands
        self.scan = scan
    }

    public func preview(accounts: [AccountID]) async throws -> SuperhumanReminderImportPreview {
        var emails: [SuperhumanReminderEmail] = []
        for account in accounts { emails += try await scan(account) }
        return .make(emails)
    }

    public func apply(_ preview: SuperhumanReminderImportPreview,
                      archiveInGmail: Bool) async throws -> (token: UndoToken, skipped: Int) {
        var receipt = SuperhumanReminderImportReceipt()
        var matched = preview.matched
        do {
            if !matched.isEmpty {
                let back = preview.conversationsToBringBack
                let own = archiveInGmail ? preview.conversationsToArchive : []
                if !back.isEmpty || !own.isEmpty {
                    if let commands {
                        do {
                            if !back.isEmpty {
                                let token = try await commands.apply(.moveToInbox(back))
                                receipt.record(token)
                            }
                            if !own.isEmpty {
                                let token = try await commands.apply(.markDone(own))
                                receipt.record(token)
                            }
                        } catch {
                            await Self.undoCommands(receipt.commandTokens, commands: commands)
                            receipt.commandTokens = []
                            receipt.skippedMatched = matched.count
                            matched = []
                        }
                    } else {
                        receipt.skippedMatched = matched.count
                        matched = []
                    }
                }
            }
            for (account, emails) in Dictionary(grouping: matched, by: \.id.account).sorted(by: { $0.key < $1.key }) {
                receipt.accounts.append(try await record(emails, account: account))
            }
            receipt.backlogBefore = try await settings.get(AppSettings.superhumanRemindersBacklogImported)
            if !preview.inConversation.isEmpty, !receipt.backlogBefore {
                try await settings.set(AppSettings.superhumanRemindersBacklogImported, true)
                receipt.backlogChanged = true
            }
        } catch {
            try? await SuperhumanReminderImportUndoer.revert(receipt, settings: settings, commands: commands)
            throw error
        }
        let token = UndoToken(payload: try JSONEncoder().encode(receipt), changesNothing: receipt.changesNothing)
        return (token, receipt.skippedMatched)
    }

    private func record(_ emails: [SuperhumanReminderEmail],
                        account: AccountID) async throws -> SuperhumanReminderImportReceipt.AccountChange {
        let convertedKey = AppSettings.superhumanRemindersConverted(account)
        let returnedKey = AppSettings.superhumanRemindersReturned(account)
        var converted = try await settings.get(convertedKey)
        var returned = try await settings.get(returnedKey)
        var change = SuperhumanReminderImportReceipt.AccountChange(account: account)
        for email in emails {
            let id = email.id.gmailMessageID.rawValue
            if !converted.contains(id) {
                converted.append(id)
                change.addedConverted.append(id)
            }
            guard let target = email.target else { continue }
            let key = target.gmailThreadID.rawValue
            let at = Int64((email.date.timeIntervalSince1970 * 1000).rounded())
            if let old = returned[key] {
                guard at > old else { continue }
                if change.previousReturned[key] == nil, !change.addedReturned.contains(key) { change.previousReturned[key] = old }
                returned[key] = at
            } else {
                returned[key] = at
                change.addedReturned.append(key)
            }
        }
        if !change.addedReturned.isEmpty || !change.previousReturned.isEmpty { try await settings.set(returnedKey, returned) }
        if !change.addedConverted.isEmpty { try await settings.set(convertedKey, converted) }
        return change
    }

    static func undoCommands(_ tokens: [Data], commands: any MailCommanding) async {
        for payload in tokens.reversed() { _ = try? await commands.undo(UndoToken(payload: payload)) }
    }

    public static func markRuleStart(settings: (any SettingsPort)?, now: Date) async {
        guard let settings else { return }
        let current: Int64?
        do { current = try await settings.get(AppSettings.superhumanRemindersSince) } catch { return }
        guard current == nil else { return }
        try? await settings.set(AppSettings.superhumanRemindersSince, Int64((now.timeIntervalSince1970 * 1000).rounded()))
    }
}

extension SuperhumanReminderImportReceipt {
    mutating func record(_ token: UndoToken) {
        if !token.changesNothing { commandTokens.append(token.payload) }
    }
}

final class SuperhumanReminderImportUndoer: MailUndoing {
    private let settings: any SettingsPort
    private let commands: (any MailCommanding)?

    init(settings: any SettingsPort, commands: (any MailCommanding)?) {
        self.settings = settings
        self.commands = commands
    }

    func undo(_ token: UndoToken) async throws -> UndoToken? {
        let receipt = try JSONDecoder().decode(SuperhumanReminderImportReceipt.self, from: token.payload)
        try await Self.revert(receipt, settings: settings, commands: commands)
        return nil
    }

    static func revert(_ receipt: SuperhumanReminderImportReceipt, settings: any SettingsPort,
                       commands: (any MailCommanding)?) async throws {
        if receipt.backlogChanged {
            try await settings.set(AppSettings.superhumanRemindersBacklogImported, receipt.backlogBefore)
        }
        for change in receipt.accounts {
            if !change.addedConverted.isEmpty {
                let key = AppSettings.superhumanRemindersConverted(change.account)
                let removed = Set(change.addedConverted)
                let kept = try await settings.get(key).filter { !removed.contains($0) }
                try await settings.set(key, kept)
            }
            if !change.addedReturned.isEmpty || !change.previousReturned.isEmpty {
                let key = AppSettings.superhumanRemindersReturned(change.account)
                var returned = try await settings.get(key)
                for thread in change.addedReturned { returned[thread] = nil }
                for (thread, at) in change.previousReturned { returned[thread] = at }
                try await settings.set(key, returned)
            }
        }
        if let commands {
            for payload in receipt.commandTokens.reversed() { _ = try await commands.undo(UndoToken(payload: payload)) }
        }
    }
}
