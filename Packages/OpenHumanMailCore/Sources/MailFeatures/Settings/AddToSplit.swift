import Foundation
import MailActions
import MailModel
import OpenHumanCore

public struct SplitRuleChoice: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable { case sender, domain, recipient, subject, label }

    public let kind: Kind
    public let value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public var fragment: String {
        switch kind {
        case .sender: "from:" + value
        case .domain: "from:@" + value
        case .recipient: "to:" + value
        case .subject: "subject:\"" + value + "\""
        case .label: "label:\"" + value + "\""
        }
    }

    public var title: String {
        switch kind {
        case .sender: "from \(value)"
        case .domain: "from @\(value)"
        case .recipient: "to \(value)"
        case .subject: "subject “\(value)”"
        case .label: "label \(value)"
        }
    }
}

public enum AddToSplit {
    public static let paletteQuery = "Add to split"
    static let maxSubject = 80

    public static func choices(sender: String?, recipient: String?, subject: String, labels: [String]) -> [SplitRuleChoice] {
        var result: [SplitRuleChoice] = []
        if let sender = sender?.lowercased(), isAddress(sender) {
            result.append(SplitRuleChoice(kind: .sender, value: sender))
            if let at = sender.lastIndex(of: "@") {
                let domain = String(sender[sender.index(after: at)...])
                if !domain.isEmpty { result.append(SplitRuleChoice(kind: .domain, value: domain)) }
            }
        }
        if let recipient = recipient?.lowercased(), isAddress(recipient), recipient != sender?.lowercased() {
            result.append(SplitRuleChoice(kind: .recipient, value: recipient))
        }
        let bare = strippedSubject(subject)
        if !bare.isEmpty, bare.count <= maxSubject, !bare.contains("\""), !bare.contains("\\") {
            result.append(SplitRuleChoice(kind: .subject, value: bare))
        }
        for label in labels where !label.isEmpty && !label.contains("\"") && !label.contains("\\") {
            result.append(SplitRuleChoice(kind: .label, value: label))
        }
        return result
    }

    public static func appending(_ fragment: String, to rule: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fragment }
        if trimmed.lowercased().contains(fragment.lowercased()) { return trimmed }
        return "(\(trimmed)) OR \(fragment)"
    }

    public static func targets(_ splits: [SplitInfo]) -> [SplitInfo] {
        splits.filter { $0.ruleText.trimmingCharacters(in: .whitespaces).lowercased() != "is:important" }
    }

    public static func canAddSafely(to split: SplitInfo) -> Bool {
        guard !targets([split]).isEmpty else { return false }
        var parser = SplitRuleEvaluator.Parser(Array(split.ruleText))
        guard let node = parser.parseExpression(), parser.atEnd else { return false }
        return !isEventsOnly(node)
    }

    private static func isEventsOnly(_ node: SplitRuleEvaluator.Node) -> Bool {
        switch node {
        case let .term(name, value):
            let value = value.lowercased()
            return (name == "is" && value == "event") || (name == "has" && value == "invite")
        case let .and(items), let .or(items):
            return !items.isEmpty && items.allSatisfy(isEventsOnly)
        case .not:
            return false
        }
    }

    static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_+%'@"))
        return text.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    static func strippedSubject(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        while let range = text.range(of: #"^(re|fwd?|aw|wg)\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            text.removeSubrange(range)
        }
        return text
    }

    @MainActor
    static func choices(for thread: ThreadKey, router: AppRouter) -> [SplitRuleChoice] {
        guard let active = router.accounts.first(where: { $0.id == thread.account }) else { return [] }
        let isMe: (String) -> Bool = { active.account.isMe($0) }
        var sender: String?
        var recipient: String?
        var subject = ""
        var labelIDs: [Int64] = []
        if let reader = active.reader, reader.thread == thread {
            subject = reader.subject
            labelIDs = reader.userLabelIDs
            let messages = reader.messages.map(\.summary)
            sender = messages.last { !isMe($0.from?.email ?? "") }?.from?.email
            recipient = messages.reversed().flatMap { $0.to + $0.cc }.first { !isMe($0.email) }?.email
        } else if let row = active.list?.row(for: thread) {
            subject = row.subject
            labelIDs = row.userLabelIDs
            sender = row.participants.first { !$0.isMe }?.email
        }
        let names = labelIDs.compactMap { id in
            active.labels.first { $0.id == id && $0.kind == .user && !$0.isHidden }?.displayName
        }
        return choices(sender: sender, recipient: recipient, subject: subject, labels: names)
    }
}

enum SplitEdit: Codable, Sendable {
    case rule(account: AccountID, split: SplitID, name: String, ruleText: String, enabled: Bool)
    case delete(account: AccountID, split: SplitID, name: String, ruleText: String)
    case create(account: AccountID, name: String, ruleText: String)
}

final class SplitEditUndoer: MailUndoing {
    private let commands: any MailCommanding

    init(commands: any MailCommanding) {
        self.commands = commands
    }

    func undo(_ token: UndoToken) async throws -> UndoToken? {
        let edit = try JSONDecoder().decode(SplitEdit.self, from: token.payload)
        let redo: SplitEdit
        switch edit {
        case .rule(let account, let split, let name, let ruleText, let enabled):
            let current = try await Self.split(split, account: account, commands: commands)
            _ = try await commands.upsertSplit(SplitDefinition(account: account, id: split, name: name, ruleText: ruleText,
                                                               enabled: enabled))
            redo = .rule(account: account, split: split, name: current?.name ?? name,
                         ruleText: current?.ruleText ?? ruleText, enabled: current?.enabled ?? enabled)
        case .delete(let account, let split, let name, let ruleText):
            try await commands.deleteSplit(account, split)
            redo = .create(account: account, name: name, ruleText: ruleText)
        case .create(let account, let name, let ruleText):
            let key = try await commands.upsertSplit(SplitDefinition(account: account, name: name, ruleText: ruleText))
            redo = .delete(account: account, split: key, name: name, ruleText: ruleText)
        }
        return UndoToken(payload: try JSONEncoder().encode(redo))
    }

    private static func split(_ id: SplitID, account: AccountID, commands: any MailCommanding) async throws -> SplitInfo? {
        guard let data = commands as? any MailDataSource else { return nil }
        for try await list in data.splits(account) { return list.first { $0.id == id } }
        return nil
    }
}

extension SuperhumanCoreActionHandler {
    @discardableResult
    func addToSplit(_ choice: SplitRuleChoice, into split: SplitKey?, account: AccountID) async -> Bool {
        guard let split else {
            return await createSplit(named: choice.value, ruleText: choice.fragment, account: account,
                                     title: "New split \(choice.value)")
        }
        guard let current = await currentSplit(split, account: account) else {
            feedback.failed("Couldn't find that split")
            return false
        }
        let rule = AddToSplit.appending(choice.fragment, to: current.ruleText)
        guard rule != current.ruleText.trimmingCharacters(in: .whitespacesAndNewlines) else {
            environment?.notices.post("\(current.name) already has \(choice.title)", style: .info,
                                      duration: NoticeCenter.infoDuration)
            return false
        }
        let before = SplitEdit.rule(account: account, split: split, name: current.name, ruleText: current.ruleText,
                                    enabled: current.enabled)
        let definition = SplitDefinition(account: account, id: split, name: current.name, ruleText: rule,
                                         enabled: current.enabled)
        return await editSplit(before, title: "Added \(choice.title) to \(current.name)") { commands in
            _ = try await commands.upsertSplit(definition)
            return nil
        }
    }

    @discardableResult
    func createSplit(named name: String, ruleText: String, account: AccountID, title: LocalizedStringResource) async -> Bool {
        var created: SplitKey?
        let done = await editSplit(nil, title: title) { commands in
            let key = try await commands.upsertSplit(SplitDefinition(account: account, name: name, ruleText: ruleText))
            created = key
            return SplitEdit.delete(account: account, split: key, name: name, ruleText: ruleText)
        }
        if done, let created { environment?.router.go(to: .split(created)) }
        return done
    }

    func editSplit(_ before: SplitEdit?, title: LocalizedStringResource,
                           _ write: (any MailCommanding) async throws -> SplitEdit?) async -> Bool {
        guard let environment, let commands = environment.commands else { return false }
        do {
            let undo = try await write(commands) ?? before
            if let undo, let payload = try? JSONEncoder().encode(undo) {
                environment.undo?.push(UndoCoordinator.Entry(title: title, token: UndoToken(payload: payload),
                                                             undoer: SplitEditUndoer(commands: commands)))
            } else {
                environment.notices.post(String(localized: title), style: .info, duration: NoticeCenter.infoDuration)
            }
            return true
        } catch {
            feedback.failed((error as? MailPortError)?.description ?? "Couldn't change the split")
        }
        return false
    }

    private func currentSplit(_ id: SplitKey, account: AccountID) async -> SplitInfo? {
        if let known = environment?.router.accounts.first(where: { $0.id == account })?.splits.first(where: { $0.id == id }) {
            return known
        }
        guard let data = environment?.data else { return nil }
        do {
            for try await list in data.splits(account) { return list.first { $0.id == id } }
        } catch {}
        return nil
    }
}
