import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class SuperhumanImportModel {
    public static let mutedLabelName = "[Superhuman]/Muted"
    public static let snoozedLabelName = "[Superhuman]/Is Snoozed"
    public nonisolated static let maxConversations = 10_000

    public struct Snoozed: Identifiable, Hashable, Sendable {
        public let thread: ThreadKey
        public let subject: String
        public let lastMessageAt: Date
        public var id: ThreadKey { thread }
    }

    public enum Phase: Hashable, Sendable {
        case idle, counting, counted, importing
        case done(String)
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public internal(set) var account: Account?
    public private(set) var hasMutedLabel = false
    public private(set) var hasSnoozedLabel = false
    public private(set) var mutedTotal = 0
    public internal(set) var toMute: [ThreadKey] = []
    public private(set) var snoozed: [Snoozed] = []
    @ObservationIgnored private var snoozedLabelID: GmailLabelID?
    @ObservationIgnored private weak var environment: AppEnvironment?

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public static let note = "Counts first and changes nothing until you choose. Superhuman's own labels stay as they are."

    public var mutedSummary: String {
        guard hasMutedLabel else { return "No \(Self.mutedLabelName) label on this account." }
        let total = mutedTotal == 1 ? "1 conversation is" : "\(mutedTotal.formatted()) conversations are"
        let left = toMute.count == 1 ? "1 isn't" : "\(toMute.count.formatted()) aren't"
        return "\(total) muted in Superhuman; \(left) muted here yet."
    }

    public var snoozedSummary: String {
        guard hasSnoozedLabel else { return "No \(Self.snoozedLabelName) label on this account." }
        let n = snoozed.count == 1 ? "1 conversation was" : "\(snoozed.count.formatted()) conversations were"
        return "\(n) snoozed in Superhuman. Snooze them again with H in Mail; their wake times aren't known."
    }

    public var muteTitle: String { toMute.count == 1 ? "Mute 1 conversation" : "Mute \(toMute.count.formatted()) conversations" }

    public func count() async {
        guard let environment else { return }
        guard let account = environment.router.active?.account else {
            phase = .failed("Sign in first.")
            return
        }
        self.account = account
        phase = .counting
        let data = environment.data
        do {
            let labels = try await Self.labels(account: account.id, data: data)
            let muted = Self.label(named: Self.mutedLabelName, in: labels)
            let snoozedLabel = Self.label(named: Self.snoozedLabelName, in: labels)
            let ours = labels.first { $0.name == OHGmailLabels.muted }?.id
            hasMutedLabel = muted != nil
            hasSnoozedLabel = snoozedLabel != nil
            snoozedLabelID = snoozedLabel?.labelID
            if let muted {
                let rows = try await Self.rows(of: .label(muted.labelID), account: account.id, data: data)
                mutedTotal = rows.count
                toMute = rows.filter { row in ours.map { !row.userLabelIDs.contains($0) } ?? true }.map(\.id)
            } else {
                mutedTotal = 0
                toMute = []
            }
            if let snoozedLabel {
                snoozed = try await Self.rows(of: .label(snoozedLabel.labelID), account: account.id, data: data)
                    .map { Snoozed(thread: $0.id, subject: $0.subject, lastMessageAt: $0.lastMessageAt) }
            } else {
                snoozed = []
            }
            phase = .counted
        } catch {
            phase = .failed("Couldn't read this account's labels.")
        }
    }

    @discardableResult
    public func importMuted() async -> Bool {
        guard let environment, let account, !toMute.isEmpty else { return false }
        if environment.status.safeMode == .readOnly {
            phase = .failed("Read-only: Mail can't change your mail in this session.")
            return false
        }
        guard environment.commands != nil, environment.actions.descriptor(.toggleMute) != nil else {
            phase = .failed("Mute is off in this build or mode.")
            return false
        }
        phase = .importing
        let router = environment.router
        var context = router.actionContext()
        context.scope = .list
        context.account = account.id
        context.selection = toMute
        context.focusedThread = nil
        context.location = nil
        context.targets = TargetState()
        let count = toMute.count
        guard await environment.actions.run(.toggleMute, source: .palette, host: router, context: context) else {
            phase = .failed("Couldn't mute them.")
            return false
        }
        toMute = []
        phase = .done(count == 1 ? "Muted 1 conversation. ⌘Z in the mail window puts it back."
                                 : "Muted \(count.formatted()) conversations. ⌘Z in the mail window puts them back.")
        return true
    }

    public func showSnoozedInMail() {
        guard let environment, let account, let label = snoozedLabelID else { return }
        let router = environment.router
        router.switchAccount(to: account.id)
        router.go(to: .label(label))
    }

    nonisolated static func labels(account: AccountID, data: any MailDataSource) async throws -> [LabelInfo] {
        for try await list in data.labels(account) { return list }
        return []
    }

    nonisolated static func label(named name: String, in labels: [LabelInfo]) -> LabelInfo? {
        labels.first { $0.name == name } ?? labels.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    nonisolated static func rows(of location: MailLocation, account: AccountID,
                                 data: any MailDataSource) async throws -> [ThreadRow] {
        var found: [ThreadRow] = []
        var cursor: PageCursor?
        repeat {
            let page = try await data.threadPage(location, account: account, after: cursor, limit: 500)
            found += page.rows
            cursor = page.next
        } while cursor != nil && found.count < maxConversations && !Task.isCancelled
        return found
    }
}
