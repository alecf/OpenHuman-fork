import Foundation
import MailModel
import MailRender
import OpenHumanCore

public struct ReviewChanges: Equatable, Sendable {
    public enum Op: Equatable, Sendable { case same, added, removed }

    public struct Run: Equatable, Sendable {
        public let op: Op
        public let text: String

        public init(_ op: Op, _ text: String) {
            self.op = op
            self.text = text
        }
    }

    public let changedFields: [String]
    public let body: [Run]

    public init(changedFields: [String], body: [Run]) {
        self.changedFields = changedFields
        self.body = body
    }

    public var isEmpty: Bool { changedFields.isEmpty && !body.contains { $0.op != .same } }
}

public enum ReviewDiff {
    public static func changes(from old: DraftFields, to new: DraftFields) -> ReviewChanges {
        var fields: [String] = []
        if addresses(old.to) != addresses(new.to) { fields.append("To") }
        if addresses(old.cc) != addresses(new.cc) { fields.append("Cc") }
        if old.subject != new.subject { fields.append("Subject") }
        return ReviewChanges(changedFields: fields, body: words(from: plainText(old), to: plainText(new)))
    }

    public static func plainText(_ fields: DraftFields) -> String {
        if let text = fields.bodyText { return text }
        return PlainTextExtractor.text(fromHTML: fields.bodyHTML)
    }

    private static func addresses(_ list: [EmailAddress]) -> [String] { list.map { $0.email.lowercased() } }

    public static func words(from old: String, to new: String, limit: Int = 2000) -> [ReviewChanges.Run] {
        let a = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let b = new.split(whereSeparator: \.isWhitespace).map(String.init)
        guard a.count <= limit, b.count <= limit else {
            return merge([a.isEmpty ? nil : ReviewChanges.Run(.removed, a.joined(separator: " ")),
                          b.isEmpty ? nil : ReviewChanges.Run(.added, b.joined(separator: " "))].compactMap { $0 })
        }
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var runs: [ReviewChanges.Run] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                runs.append(.init(.same, a[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                runs.append(.init(.removed, a[i]))
                i += 1
            } else {
                runs.append(.init(.added, b[j]))
                j += 1
            }
        }
        while i < a.count { runs.append(.init(.removed, a[i])); i += 1 }
        while j < b.count { runs.append(.init(.added, b[j])); j += 1 }
        return merge(runs)
    }

    private static func merge(_ runs: [ReviewChanges.Run]) -> [ReviewChanges.Run] {
        var out: [ReviewChanges.Run] = []
        for run in runs {
            if let last = out.last, last.op == run.op {
                out[out.count - 1] = .init(run.op, last.text + " " + run.text)
            } else {
                out.append(run)
            }
        }
        return out
    }
}

public struct ReviewRecipientFlags: Equatable, Sendable {
    public var newRecipients: [String]
    public var externalRecipients: [String]

    public init(newRecipients: [String] = [], externalRecipients: [String] = []) {
        self.newRecipients = newRecipients
        self.externalRecipients = externalRecipients
    }

    static let consumerDomains: Set<String> = ["gmail.com", "googlemail.com"]

    public static func compute(fields: DraftFields, account: String, known: Set<String>) -> ReviewRecipientFlags {
        let all = (fields.to + fields.cc + fields.bcc).map { $0.email.lowercased() }
        let own = account.lowercased().split(separator: "@").last.map(String.init) ?? ""
        let isWork = !own.isEmpty && !consumerDomains.contains(own)
        var flags = ReviewRecipientFlags()
        for address in all where !flags.newRecipients.contains(address) {
            if !known.contains(address) { flags.newRecipients.append(address) }
        }
        if isWork {
            for address in all where !flags.externalRecipients.contains(address) {
                if address.split(separator: "@").last.map(String.init) != own { flags.externalRecipients.append(address) }
            }
        }
        return flags
    }
}
