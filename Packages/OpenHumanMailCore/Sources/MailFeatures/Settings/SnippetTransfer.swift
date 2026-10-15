import Foundation
import MailModel
import Observation
import OpenHumanCore

public typealias SnippetBundle = SnippetsFile

public struct SnippetImportPreview: Equatable, Sendable {
    public var toAdd = 0
    public var toReplace = 0
    public var shortcutsDropped = 0
    public var storedItemsNote: String?
    public var withRecipients = 0
    public var files = 0
    public var filesDropped = 0

    public var isEmpty: Bool { toAdd + toReplace == 0 }

    public var detail: String? {
        var parts: [String] = []
        if withRecipients > 0 {
            parts.append(withRecipients == 1 ? String(localized: "1 of them adds recipients when inserted.")
                                             : String(localized: "\(withRecipients) of them add recipients when inserted."))
        }
        if files > 0 {
            parts.append(files == 1 ? String(localized: "1 file comes with them.")
                                    : String(localized: "\(files) files come with them."))
        }
        if filesDropped > 0 {
            parts.append(filesDropped == 1 ? String(localized: "1 file is too large or damaged and is left out.")
                                           : String(localized: "\(filesDropped) files are too large or damaged and are left out."))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public var summary: String {
        let add = toAdd == 1 ? String(localized: "1 snippet") : String(localized: "\(toAdd) snippets")
        return String(localized: "This file would add \(add) and replace \(toReplace) with the same name.")
    }
}

public enum SnippetTransferError: Error, Equatable, CustomStringConvertible {
    case notASnippetsFile
    case newerVersion

    public var description: String {
        switch self {
        case .notASnippetsFile: "That isn't a Mail snippets file."
        case .newerVersion: "That file was made by a newer version of Mail."
        }
    }
}

@MainActor @Observable
public final class SnippetTransferModel {
    public private(set) var preview: SnippetImportPreview?
    public private(set) var message: String?
    public let availability: SettingsAvailability

    @ObservationIgnored private let data: any MailDataSource
    @ObservationIgnored private let commands: (any MailCommanding)?
    @ObservationIgnored private var pending: SnippetBundle?

    public static let maxSnippets = SnippetsFile.maxSnippets

    public init(data: any MailDataSource, commands: (any MailCommanding)?, availability: SettingsAvailability) {
        self.data = data
        self.commands = commands
        self.availability = availability
    }

    public convenience init(environment: AppEnvironment) {
        self.init(data: environment.data, commands: environment.commands,
                  availability: SettingsAvailability(environment: environment))
    }

    public func export() async throws -> Data {
        let stored = try await first(data.snippets(nil)) ?? []
        var unreadable = 0
        let snippets = stored.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { info -> SnippetBundle.Snippet in
                var files: [SnippetBundle.File] = []
                for file in info.attachments {
                    guard let url = file.fileURL, let bytes = try? Data(contentsOf: url), bytes.count == file.size else {
                        unreadable += 1
                        continue
                    }
                    files.append(SnippetBundle.File(filename: file.filename, mimeType: file.mimeType, size: file.size,
                                                    contentHash: file.contentHash, data: bytes))
                }
                return SnippetBundle.Snippet(name: info.name, shortcut: info.shortcut, subject: info.subject, bodyHTML: info.bodyHTML,
                                             variables: info.variables.map { .init(name: $0.name, defaultValue: $0.defaultValue) },
                                             to: info.to.isEmpty ? nil : info.to, cc: info.cc.isEmpty ? nil : info.cc,
                                             bcc: info.bcc.isEmpty ? nil : info.bcc, files: files.isEmpty ? nil : files)
            }
        message = unreadable == 0 ? nil
            : String(localized: "\(unreadable) snippet file(s) couldn't be read and are not in the export.")
        return try SnippetBundle(snippets: snippets).encoded()
    }

    public func prepareImport(_ file: Data) async throws -> SnippetImportPreview {
        message = nil
        let bundle: SnippetBundle
        do {
            bundle = try SnippetBundle.decode(file)
        } catch .notASnippetsFile {
            throw SnippetTransferError.notASnippetsFile
        } catch .newerVersion {
            throw SnippetTransferError.newerVersion
        }
        let existing = try await first(data.snippets(nil)) ?? []
        var preview = SnippetImportPreview()
        preview.storedItemsNote = availability.storedItemsNote
        for plan in Self.plan(Self.usable(bundle.snippets), existing: existing) {
            if plan.match == nil { preview.toAdd += 1 } else { preview.toReplace += 1 }
            if plan.dropsShortcut { preview.shortcutsDropped += 1 }
            if plan.snippet.hasRecipients { preview.withRecipients += 1 }
            let files = Self.acceptedFiles(plan.snippet.files ?? [])
            preview.files += files.count
            preview.filesDropped += (plan.snippet.files ?? []).count - files.count
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
        guard let bundle = pending else { return String(localized: "Nothing to import.") }
        pending = nil
        preview = nil
        guard let commands, availability.hasCommands else {
            let text = availability.storedItemsNote ?? String(localized: "Snippets can't be saved here.")
            message = text
            return text
        }
        let existing = (try? await first(data.snippets(nil))) ?? []
        var saved = 0
        var failures = 0
        for plan in Self.plan(Self.usable(bundle.snippets), existing: existing) {
            let snippet = plan.snippet
            let match = plan.match
            do {
                var files: [SnippetAttachmentInfo] = []
                for file in Self.acceptedFiles(snippet.files ?? []) {
                    files.append(try await commands.storeSnippetAttachment(data: file.data, filename: file.filename,
                                                                           mimeType: file.mimeType))
                }
                _ = try await commands.upsertSnippet(SnippetInfo(
                    id: match?.id ?? "", account: match?.account, name: snippet.name,
                    shortcut: plan.dropsShortcut ? match?.shortcut : snippet.shortcut.flatMap({ SnippetSettingsModel.normalizedShortcut($0) }),
                    subject: snippet.subject, bodyHTML: snippet.bodyHTML,
                    variables: snippet.variables.map { SnippetVariableInfo(name: $0.name, defaultValue: $0.defaultValue) },
                    useCount: match?.useCount ?? 0,
                    to: snippet.to.map(Self.validRecipients) ?? match?.to ?? [],
                    cc: snippet.cc.map(Self.validRecipients) ?? match?.cc ?? [],
                    bcc: snippet.bcc.map(Self.validRecipients) ?? match?.bcc ?? [],
                    attachments: snippet.files == nil ? (match?.attachments ?? []) : files))
                saved += 1
            } catch {
                failures += 1
            }
        }
        let text = failures == 0
            ? String(localized: "Imported \(saved) snippets.")
            : String(localized: "Imported \(saved) snippets; \(failures) couldn't be saved.")
        message = text
        return text
    }

    struct Plan {
        var snippet: SnippetBundle.Snippet
        var match: SnippetInfo?
        var dropsShortcut: Bool
    }

    static func usable(_ snippets: [SnippetBundle.Snippet]) -> [SnippetBundle.Snippet] {
        SnippetBundle(snippets: snippets).usableSnippets
    }

    static func acceptedFiles(_ files: [SnippetBundle.File]) -> [SnippetBundle.File] {
        SnippetBundle.acceptedFiles(files, maxFiles: SnippetAttachmentRules.maxFiles, maxFileBytes: SnippetAttachmentRules.maxFileBytes,
                                    maxTotalBytes: SnippetAttachmentRules.maxTotalBytes)
    }

    static func validRecipients(_ list: [EmailAddress]) -> [EmailAddress] {
        var seen = Set<String>()
        return list.filter { RecipientParser.isValid($0.email) && seen.insert($0.email.lowercased()).inserted }
    }

    static func plan(_ snippets: [SnippetBundle.Snippet], existing: [SnippetInfo]) -> [Plan] {
        var taken = Dictionary(existing.compactMap { info in info.shortcut.map { ($0.lowercased(), info.id) } },
                               uniquingKeysWith: { first, _ in first })
        return snippets.map { snippet in
            let same = existing.filter { $0.name.caseInsensitiveCompare(snippet.name) == .orderedSame }
            let match = same.first { $0.account == nil } ?? same.first
            var drops = false
            if let shortcut = snippet.shortcut.flatMap({ SnippetSettingsModel.normalizedShortcut($0) }) {
                if let owner = taken[shortcut], owner != match?.id {
                    drops = true
                } else {
                    taken[shortcut] = match?.id ?? "new:\(snippet.name.lowercased())"
                }
            }
            return Plan(snippet: snippet, match: match, dropsShortcut: drops)
        }
    }

    private func first<T: Sendable>(_ stream: AsyncThrowingStream<T, Error>) async throws -> T? {
        for try await value in stream { return value }
        return nil
    }
}
