import Foundation
import MailModel
import Observation
import OpenHumanCore

public struct SettingsBundle: Codable, Sendable, Equatable {
    public static let format = "openhuman-settings"
    public static let currentVersion = 1

    public struct Global: Codable, Sendable, Equatable {
        public var undoSendSeconds: Int?
        public var snoozeMarkUnread: Bool?
        public var schedulerSnooze: Bool?
        public var schedulerSendLater: Bool?
        public var schedulerReminders: Bool?

        mutating func dropOutOfRangeValues() -> Int {
            guard let seconds = undoSendSeconds, !AppSettings.undoSendSecondsRange.contains(seconds) else { return 0 }
            undoSendSeconds = nil
            return 1
        }
    }

    public struct Split: Codable, Sendable, Equatable {
        public var name: String
        public var ruleText: String
        public var enabled: Bool
    }

    public struct AccountSettings: Codable, Sendable, Equatable {
        public var email: String
        public var splits: [Split]
        public var remoteImages: RemoteImagePolicy?
        public var remoteImageSenders: [String]?
        public var defaultFrom: String?
        public var replyFrom: ReplyFromPolicy?
        public var savedSearches: [SavedSearch]?
    }

    public struct Snippet: Codable, Sendable, Equatable {
        public var name: String
        public var accountEmail: String?
        public var shortcut: String?
        public var subject: String?
        public var bodyHTML: String
        public var variables: [SnippetVariableInfo]
        public var to: [EmailAddress]?
        public var cc: [EmailAddress]?
        public var bcc: [EmailAddress]?
    }

    public var format: String
    public var version: Int
    public var global: Global
    public var accounts: [AccountSettings]
    public var snippets: [Snippet]
}

public struct SettingsImportPreview: Equatable, Sendable {
    public var splitsToAdd = 0
    public var splitsToReplace = 0
    public var snippetsToAdd = 0
    public var snippetsToReplace = 0
    public var settingsToApply = 0
    public var settingsSkipped = 0
    public var accountsSkipped = 0
    public var storedItemsNote: String?

    public var isEmpty: Bool {
        splitsToAdd + splitsToReplace + snippetsToAdd + snippetsToReplace + settingsToApply == 0
    }
}

public enum SettingsTransferError: Error, Equatable, CustomStringConvertible {
    case notASettingsFile
    case newerVersion

    public var description: String {
        switch self {
        case .notASettingsFile: "That isn't a Mail settings file."
        case .newerVersion: "That file was made by a newer version of Mail."
        }
    }
}

@MainActor @Observable
public final class SettingsTransferModel {
    public private(set) var preview: SettingsImportPreview?
    public private(set) var message: String?
    public let availability: SettingsAvailability

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let commands: (any MailCommanding)?
    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored private var pending: SettingsBundle?

    public init(data: any MailDataSource, commands: (any MailCommanding)?, settings: (any SettingsPort)?,
                availability: SettingsAvailability) {
        self.data = data
        self.commands = commands
        self.settings = settings
        self.availability = availability
    }

    public convenience init(environment: AppEnvironment) {
        self.init(data: environment.data, commands: environment.commands, settings: environment.settings,
                  availability: SettingsAvailability(environment: environment))
    }

    public func export() async throws -> Data {
        var bundle = SettingsBundle(format: SettingsBundle.format, version: SettingsBundle.currentVersion,
                                    global: .init(), accounts: [], snippets: [])
        if let settings {
            let undoSend = try await settings.get(AppSettings.undoSendSeconds)
            bundle.global = SettingsBundle.Global(
                undoSendSeconds: AppSettings.undoSendSecondsRange.contains(undoSend) ? undoSend : nil,
                snoozeMarkUnread: try await settings.get(AppSettings.snoozeMarkUnread),
                schedulerSnooze: try await settings.get(AppSettings.schedulerSnooze),
                schedulerSendLater: try await settings.get(AppSettings.schedulerSendLater),
                schedulerReminders: try await settings.get(AppSettings.schedulerReminders))
        }
        let accounts = try await first(data.accounts()) ?? []
        for account in accounts {
            var entry = SettingsBundle.AccountSettings(email: account.email, splits: [])
            entry.splits = (try await first(data.splits(account.id)) ?? []).sorted { $0.position < $1.position }
                .map { SettingsBundle.Split(name: $0.name, ruleText: $0.ruleText, enabled: $0.enabled) }
            if let settings {
                entry.remoteImages = try await settings.get(AppSettings.remoteImages(account.id))
                entry.remoteImageSenders = try await settings.get(AppSettings.remoteImageSenders(account.id))
                entry.defaultFrom = try await settings.get(ComposeSettings.defaultFrom(account.id))
                entry.replyFrom = try await settings.get(ComposeSettings.replyFrom(account.id))
                let saved = try await settings.get(AppSettings.savedSearches(account.id))
                entry.savedSearches = saved.isEmpty ? nil : saved
            }
            bundle.accounts.append(entry)
        }
        let emails = Dictionary(accounts.map { ($0.id, $0.email) }, uniquingKeysWith: { first, _ in first })
        for snippet in try await first(data.snippets(nil)) ?? [] {
            bundle.snippets.append(SettingsBundle.Snippet(
                name: snippet.name, accountEmail: snippet.account.flatMap { emails[$0] }, shortcut: snippet.shortcut,
                subject: snippet.subject, bodyHTML: snippet.bodyHTML, variables: snippet.variables,
                to: snippet.to.isEmpty ? nil : snippet.to, cc: snippet.cc.isEmpty ? nil : snippet.cc,
                bcc: snippet.bcc.isEmpty ? nil : snippet.bcc))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(bundle)
    }

    public func prepareImport(_ file: Data) async throws -> SettingsImportPreview {
        message = nil
        guard var bundle = try? JSONDecoder().decode(SettingsBundle.self, from: file), bundle.format == SettingsBundle.format
        else { throw SettingsTransferError.notASettingsFile }
        guard bundle.version <= SettingsBundle.currentVersion else { throw SettingsTransferError.newerVersion }
        let skipped = bundle.global.dropOutOfRangeValues()
        let accounts = try await first(data.accounts()) ?? []
        let byEmail = Dictionary(accounts.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var preview = SettingsImportPreview()
        preview.storedItemsNote = availability.storedItemsNote
        let canStore = availability.hasCommands
        if availability.canEditSettings {
            preview.settingsSkipped = skipped
            preview.settingsToApply += [bundle.global.undoSendSeconds != nil, bundle.global.snoozeMarkUnread != nil,
                                        bundle.global.schedulerSnooze != nil, bundle.global.schedulerSendLater != nil,
                                        bundle.global.schedulerReminders != nil].filter { $0 }.count
        }
        for entry in bundle.accounts {
            guard let account = byEmail[entry.email.lowercased()] else {
                preview.accountsSkipped += 1
                continue
            }
            if availability.canEditSettings {
                preview.settingsToApply += [entry.remoteImages != nil, entry.remoteImageSenders != nil,
                                            entry.defaultFrom != nil, entry.replyFrom != nil,
                                            entry.savedSearches?.isEmpty == false].filter { $0 }.count
            }
            guard canStore else { continue }
            let existing = try await first(data.splits(account.id)) ?? []
            for split in entry.splits {
                if existing.contains(where: { $0.name.caseInsensitiveCompare(split.name) == .orderedSame }) {
                    preview.splitsToReplace += 1
                } else {
                    preview.splitsToAdd += 1
                }
            }
        }
        if canStore {
            let existing = try await first(data.snippets(nil)) ?? []
            for snippet in bundle.snippets {
                let owner = snippet.accountEmail.flatMap { byEmail[$0.lowercased()]?.id }
                if snippet.accountEmail != nil, owner == nil { continue }
                if existing.contains(where: { $0.account == owner && $0.name.caseInsensitiveCompare(snippet.name) == .orderedSame }) {
                    preview.snippetsToReplace += 1
                } else {
                    preview.snippetsToAdd += 1
                }
            }
        }
        pending = bundle
        self.preview = preview
        return preview
    }

    public func cancelImport() {
        pending = nil
        preview = nil
    }

    @discardableResult
    public func applyImport() async -> String {
        guard let bundle = pending else { return "Nothing to import." }
        pending = nil
        preview = nil
        var failures = 0
        func attempt(_ work: () async throws -> Void) async {
            do { try await work() } catch { failures += 1 }
        }
        let accounts = (try? await first(data.accounts())) ?? []
        let byEmail = Dictionary(accounts.map { ($0.email.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        if let settings, availability.canEditSettings {
            let g = bundle.global
            if let v = g.undoSendSeconds { await attempt { try await settings.set(AppSettings.undoSendSeconds, v) } }
            if let v = g.snoozeMarkUnread { await attempt { try await settings.set(AppSettings.snoozeMarkUnread, v) } }
            if let v = g.schedulerSnooze { await attempt { try await settings.set(AppSettings.schedulerSnooze, v) } }
            if let v = g.schedulerSendLater { await attempt { try await settings.set(AppSettings.schedulerSendLater, v) } }
            if let v = g.schedulerReminders { await attempt { try await settings.set(AppSettings.schedulerReminders, v) } }
        }
        for entry in bundle.accounts {
            guard let account = byEmail[entry.email.lowercased()] else { continue }
            let id = account.id
            if let settings, availability.canEditSettings {
                if let v = entry.remoteImages { await attempt { try await settings.set(AppSettings.remoteImages(id), v) } }
                if let v = entry.remoteImageSenders { await attempt { try await settings.set(AppSettings.remoteImageSenders(id), v) } }
                if let v = entry.replyFrom { await attempt { try await settings.set(ComposeSettings.replyFrom(id), v) } }
                // Only an address this account really has; otherwise Gmail's default stays
                if let v = entry.defaultFrom, account.isMe(v) { await attempt { try await settings.set(ComposeSettings.defaultFrom(id), v) } }
                if let incoming = entry.savedSearches, !incoming.isEmpty {
                    await attempt {
                        let key = AppSettings.savedSearches(id)
                        try await settings.set(key, Self.merge(try await settings.get(key), incoming))
                    }
                }
            }
            guard let commands, availability.hasCommands else { continue }
            let existing = (try? await first(data.splits(id))) ?? []
            for split in entry.splits {
                let match = existing.first { $0.name.caseInsensitiveCompare(split.name) == .orderedSame }
                await attempt {
                    _ = try await commands.upsertSplit(SplitDefinition(account: id, id: match?.id, name: split.name,
                                                                       ruleText: split.ruleText, enabled: split.enabled))
                }
            }
        }
        if let commands, availability.hasCommands {
            let existing = (try? await first(data.snippets(nil))) ?? []
            for snippet in bundle.snippets {
                let owner = snippet.accountEmail.flatMap { byEmail[$0.lowercased()]?.id }
                if snippet.accountEmail != nil, owner == nil { continue }
                let match = existing.first { $0.account == owner && $0.name.caseInsensitiveCompare(snippet.name) == .orderedSame }
                await attempt {
                    _ = try await commands.upsertSnippet(SnippetInfo(
                        id: match?.id ?? "", account: owner, name: snippet.name, shortcut: snippet.shortcut,
                        subject: snippet.subject, bodyHTML: snippet.bodyHTML, variables: snippet.variables,
                        useCount: match?.useCount ?? 0,
                        to: snippet.to ?? match?.to ?? [], cc: snippet.cc ?? match?.cc ?? [],
                        bcc: snippet.bcc ?? match?.bcc ?? [], attachments: match?.attachments ?? []))
                }
            }
        }
        let text = failures == 0 ? "Settings imported." : "Settings imported; \(failures) item\(failures == 1 ? "" : "s") couldn't be applied."
        message = text
        return text
    }

    static func merge(_ existing: [SavedSearch], _ incoming: [SavedSearch]) -> [SavedSearch] {
        var result = existing
        for search in incoming {
            if let index = result.firstIndex(where: { $0.name.caseInsensitiveCompare(search.name) == .orderedSame }) {
                result[index].query = search.query
            } else if result.count < SavedSearch.maxPerAccount, !result.contains(where: { $0.query == search.query }) {
                result.append(search)
            }
        }
        return result
    }

    private func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }
}
