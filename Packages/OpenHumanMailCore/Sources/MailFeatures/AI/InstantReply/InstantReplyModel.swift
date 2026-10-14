import Foundation
import MailModel
import Observation
import OpenHumanAI
import OpenHumanCore
import os

public enum InstantReplyEligibility: Equatable, Sendable {
    case eligible
    case ineligible(Reason)

    public enum Reason: Equatable, Sendable {
        case moduleOff, aiOff, stripOff, draftRepliesNotOnDeviceAuto, notAReply, notTheUsersDraft, bodyNotEmpty,
             messageIsMine, hiddenForConversation, decidedTooLate, unavailable
        case calendarInvite, promotionOrSocial, bulkSender, notInInbox, spamOrTrash, tooLong

        init(_ exclusion: QuickReplyExclusion) {
            self = switch exclusion {
            case .calendarInvite: .calendarInvite
            case .promotionOrSocial: .promotionOrSocial
            case .bulkSender: .bulkSender
            case .notInInbox: .notInInbox
            case .spamOrTrash: .spamOrTrash
            case .tooLong: .tooLong
            }
        }
    }

    public static func evaluate(settings: AISettings, moduleOn: Bool, mode: DraftMode, source: DraftSource,
                                bodyIsEmpty: Bool, replyTo: MessageKey?, answered: MessageKey?, answeredIsMine: Bool?,
                                hidden: Bool, threadPhase: QuickRepliesModel.Phase,
                                excluded: QuickReplyExclusion? = nil) -> InstantReplyEligibility {
        guard moduleOn else { return .ineligible(.moduleOff) }
        guard settings.enabled else { return .ineligible(.aiOff) }
        guard settings.instantReplyStrip else { return .ineligible(.stripOff) }
        guard settings.draftReplies == .onDeviceAuto else { return .ineligible(.draftRepliesNotOnDeviceAuto) }
        guard mode == .reply || mode == .replyAll else { return .ineligible(.notAReply) }
        guard source == .user else { return .ineligible(.notTheUsersDraft) }
        guard bodyIsEmpty else { return .ineligible(.bodyNotEmpty) }
        guard !hidden else { return .ineligible(.hiddenForConversation) }
        if let excluded { return .ineligible(Reason(excluded)) }
        switch threadPhase {
        case .idle, .loading, .ready:
            break
        case .failed, .unavailable:
            return .ineligible(.unavailable)
        }
        guard let answered, let answeredIsMine else { return .ineligible(.decidedTooLate) }
        if let replyTo, replyTo != answered { return .ineligible(.decidedTooLate) }
        guard !answeredIsMine else { return .ineligible(.messageIsMine) }
        return .eligible
    }

    var reasonName: String {
        guard case .ineligible(let reason) = self else { return "eligible" }
        return switch reason {
        case .moduleOff: "moduleOff"
        case .aiOff: "aiOff"
        case .stripOff: "stripOff"
        case .draftRepliesNotOnDeviceAuto: "draftRepliesNotOnDeviceAuto"
        case .notAReply: "notAReply"
        case .notTheUsersDraft: "notTheUsersDraft"
        case .bodyNotEmpty: "bodyNotEmpty"
        case .messageIsMine: "messageIsMine"
        case .hiddenForConversation: "hiddenForConversation"
        case .decidedTooLate: "decidedTooLate"
        case .unavailable: "unavailable"
        case .calendarInvite: "calendarInvite"
        case .promotionOrSocial: "promotionOrSocial"
        case .bulkSender: "bulkSender"
        case .notInInbox: "notInInbox"
        case .spamOrTrash: "spamOrTrash"
        case .tooLong: "tooLong"
        }
    }
}

public struct InstantReplyHint: Hashable, Sendable {
    public let key: String
    public let title: String

    public init(key: String, title: String) {
        self.key = key
        self.title = title
    }
}

@MainActor @Observable
public final class InstantReplyModel {
    public enum Phase: Equatable, Sendable {
        case waiting
        case ready
        case quiet(String, canRetry: Bool)
        case used(Int)
        case hidden
    }

    public enum Key: Sendable { case next, previous, use, clear }

    public enum Via: String, Sendable { case returnKey = "return", command, click }

    public private(set) var selection: Int?
    public private(set) var hovered: Int?
    public private(set) var insertedUntouched = false
    public private(set) var isSlow = false
    public let replies: QuickRepliesModel

    private var usedIndex: Int?
    private var gaveUp = false
    @ObservationIgnored private weak var session: ComposeSession?
    @ObservationIgnored private weak var center: AICenter?
    @ObservationIgnored private var inserting = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var waitingSince: ContinuousClock.Instant?
    @ObservationIgnored private var interval: OSSignpostIntervalState?

    init(session: ComposeSession, center: AICenter, replies: QuickRepliesModel) {
        self.session = session
        self.center = center
        self.replies = replies
    }

    isolated deinit {
        timer?.cancel()
    }

    public var phase: Phase {
        if replies.hiddenInComposer { return .hidden }
        if let usedIndex { return .used(usedIndex) }
        switch replies.phase {
        case .idle, .loading:
            return gaveUp ? .quiet(AIWording.failure(AIError.timeout), canRetry: true) : .waiting
        case .ready:
            return replies.options.isEmpty ? .quiet(Self.noReplies, canRetry: false) : .ready
        case .failed(let text), .unavailable(let text):
            switch replies.failure {
            case .empty?: return .quiet(Self.noReplies, canRetry: false)
            case .error(let error)?: return .quiet(text, canRetry: Self.canRetry(error))
            case .excluded?, .notOffered?, nil: return .quiet(text, canRetry: false)
            }
        }
    }

    public var suggestions: [ReplySuggestion] {
        let calendar = session?.thread.flatMap { thread in
            center?.environment?.schedulingIfStarted?.suggestions(for: thread, message: replies.target ?? session?.replyTo)
        } ?? []
        return ReplySuggestions.merge(scheduling: calendar, quickReplies: replies.options).filter(\.isReply)
    }

    public var options: [QuickReply] {
        suggestions.enumerated().map { $0.element.quickReply(id: $0.offset) }
    }

    public var selectedSuggestionID: String? {
        guard isLive, let shown = hovered ?? selection else { return nil }
        let all = suggestions
        return all.indices.contains(shown) ? all[shown].id : nil
    }
    public var badge: AIProviderBadge? { replies.badge }
    public var isSuspicious: Bool { replies.isSuspicious }

    public var showsRow: Bool {
        guard isAllowed, let session, session.isOpen, session.aiPanel == nil else { return false }
        guard Self.bodyIsEmpty(session) else { return false }
        switch phase {
        case .waiting, .ready, .quiet: return true
        case .used, .hidden: return false
        }
    }

    public var isLive: Bool {
        guard showsRow, phase == .ready, !options.isEmpty, let session, session.snippetPicker == nil else { return false }
        return Self.bodyIsEmpty(session)
    }

    public var ghostText: String? {
        guard isLive, let shown = hovered ?? selection, options.indices.contains(shown) else { return nil }
        return options[shown].body
    }

    public var placeholder: String? {
        isLive && selection == nil ? String(localized: "Write your reply, or press ⇥ for a quick reply") : nil
    }

    public var accessibilityPlaceholder: String? {
        isLive ? String(localized: "Quick replies available. Tab previews, Return uses.") : nil
    }

    public var hint: [InstantReplyHint] {
        guard showsRow, phase == .ready else { return [] }
        guard isLive else { return [InstantReplyHint(key: "⌘1–3", title: String(localized: "insert"))] }
        if selection == nil {
            return [InstantReplyHint(key: "⇥", title: String(localized: "preview")),
                    InstantReplyHint(key: "⌘1–3", title: String(localized: "use"))]
        }
        return [InstantReplyHint(key: "↵", title: String(localized: "use")),
                InstantReplyHint(key: "⇥", title: String(localized: "next")),
                InstantReplyHint(key: "esc", title: String(localized: "clear"))]
    }

    public var waitingText: String {
        isSlow ? String(localized: "Still thinking…") : String(localized: "Thinking…")
    }

    public var accessibilityLabel: String {
        var parts = [String(localized: "Quick replies")]
        if !options.isEmpty { parts.append(String(localized: "\(options.count) suggestions")) }
        if let badge { parts.append(badge.leavesMac ? badge.title : String(localized: "made on this Mac")) }
        return parts.joined(separator: ", ")
    }

    public var previewAnnouncement: String? {
        guard let selection, options.indices.contains(selection) else { return nil }
        return String(localized: "Quick reply \(selection + 1) of \(options.count): \(options[selection].label)")
    }

    var isPreviewingUnaccepted: Bool { isLive && selection != nil }

    private var isAllowed: Bool {
        guard let settings = center?.settings else { return false }
        return settings.enabled && settings.instantReplyStrip && settings.draftReplies == .onDeviceAuto
    }

    public func handle(_ key: Key) -> Bool {
        guard isLive else { return false }
        switch key {
        case .next:
            selection = selection.map { ($0 + 1) % options.count } ?? 0
            return true
        case .previous:
            selection = selection.map { ($0 - 1 + options.count) % options.count } ?? options.count - 1
            return true
        case .use:
            guard let selection else { return false }
            insert(selection, via: .returnKey)
            return true
        case .clear:
            guard selection != nil else { return false }
            selection = nil
            Self.log("instantReply cleared reason=esc")
            return true
        }
    }

    public func use(_ index: Int, via: Via = .command) {
        guard showsRow, phase == .ready, options.indices.contains(index) else { return }
        insert(index, via: via)
    }

    public func hover(_ index: Int?) {
        guard let index else {
            hovered = nil
            return
        }
        hovered = isLive && options.indices.contains(index) ? index : nil
    }

    @discardableResult
    public func preview(_ index: Int) -> Bool {
        guard isLive, options.indices.contains(index) else { return false }
        selection = index
        return true
    }

    public func applyPendingPreview() {
        guard let session, let index = session.pendingQuickReplyPreview, isLive else { return }
        session.pendingQuickReplyPreview = nil
        preview(index)
    }

    public func hideForConversation() {
        guard !replies.hiddenInComposer else { return }
        replies.hiddenInComposer = true
        selection = nil
        timer?.cancel()
        Self.log("instantReply cleared reason=hide")
    }

    public func retry() {
        guard case .quiet(_, canRetry: true) = phase else { return }
        gaveUp = false
        replies.retryAutomatic()
        guard phase == .waiting else { return }
        startWaiting()
    }

    private func insert(_ index: Int, via: Via) {
        let all = suggestions
        guard let session, all.indices.contains(index), let body = all[index].body else { return }
        let suggestion = all[index]
        inserting = true
        let alone = session.insertSuggestedReply(body)
        inserting = false
        if alone {
            session.scheduling = suggestion.schedulingOption.flatMap { option in
                session.thread.flatMap { center?.environment?.schedulingIfStarted?.replyContext(option, in: $0) }
            }
        }
        let warns = suggestion.kind == .quickReply && isSuspicious
        if let notice = QuickReplyInsertion.notice(for: suggestion.quickReply(id: index), suspicious: warns) {
            session.notice = notice
        }
        selection = nil
        hovered = nil
        usedIndex = index
        insertedUntouched = true
        Self.log("instantReply used index=\(index + 1) via=\(via.rawValue)")
    }

    func bodyDidChange() {
        guard !inserting, let session else { return }
        hovered = nil
        insertedUntouched = false
        if Self.bodyIsEmpty(session) {
            guard usedIndex != nil else { return }
            usedIndex = nil
            selection = nil
        } else if selection != nil {
            selection = nil
            Self.log("instantReply cleared reason=typed")
        }
    }

    func shown() {
        InstantReplySignposts.shown()
        Self.log("instantReply shown state=\(phase == .ready ? "ready" : "waiting")")
        if phase == .ready {
            logReady(milliseconds: 0)
        } else if phase == .waiting {
            if replies.phase == .idle { replies.request(trigger: .automatic) }
            startWaiting()
        }
        follow()
    }

    func sendRefused() {
        Self.log("instantReply guard send-refused")
    }

    private func startWaiting() {
        timer?.cancel()
        isSlow = false
        waitingSince = ContinuousClock.now
        if interval == nil { interval = InstantReplySignposts.beginRequest() }
        guard let center else { return }
        let timing = center.instantReplyTiming
        let giveUp = InstantReplyPolicy.giveUp(agentCLIMayServe: center.settings.agentCLIAutoQuickReplies)
        timer = Task { [weak self] in
            do {
                try await timing.sleep(InstantReplyPolicy.slowNotice)
                guard !Task.isCancelled else { return }
                self?.becameSlow()
                try await timing.sleep(giveUp - InstantReplyPolicy.slowNotice)
                guard !Task.isCancelled else { return }
                self?.giveUpWaiting()
            } catch {}
        }
    }

    private func becameSlow() {
        guard phase == .waiting else { return }
        isSlow = true
    }

    private func giveUpWaiting() {
        guard phase == .waiting else { return }
        replies.cancelAutomatic()
        gaveUp = true
        settled()
    }

    private func follow() {
        withObservationTracking {
            _ = replies.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.threadChanged()
                self.follow()
            }
        }
    }

    private func threadChanged() {
        guard waitingSince != nil else { return }
        switch phase {
        case .ready, .quiet: settled()
        case .waiting, .used, .hidden: break
        }
    }

    private func settled() {
        timer?.cancel()
        timer = nil
        isSlow = false
        if let interval { InstantReplySignposts.endRequest(interval) }
        interval = nil
        guard let since = waitingSince else { return }
        waitingSince = nil
        switch phase {
        case .ready:
            logReady(milliseconds: Int(((ContinuousClock.now - since) / .milliseconds(1)).rounded()))
        case .quiet:
            Self.log("instantReply quiet kind=\(quietKind)")
        case .waiting, .used, .hidden:
            break
        }
    }

    private func logReady(milliseconds: Int) {
        let location = badge?.leavesMac == true ? "thirdParty" : "onDevice"
        Self.log("instantReply ready ms=\(milliseconds) cached=\(replies.fromCache) location=\(location) options=\(options.count)")
    }

    var quietKind: String {
        if gaveUp, replies.phase == .idle || replies.phase == .loading { return "timeout" }
        switch replies.failure {
        case .empty?: return "empty"
        case .error(let error)?: return Self.caseName(error)
        case .excluded(let exclusion)?: return exclusion.rawValue
        case .notOffered?, nil: return "unavailable"
        }
    }

    static let noReplies = String(localized: "No quick replies this time")

    static func canRetry(_ error: AIError) -> Bool {
        switch error {
        case .invalidOutput, .timeout, .providerFailed, .cancelled: true
        case .unavailable, .contextOverflow, .refused, .outputBlocked: false
        }
    }

    static func caseName(_ error: AIError) -> String {
        switch error {
        case .unavailable: "unavailable"
        case .contextOverflow: "contextOverflow"
        case .invalidOutput: "invalidOutput"
        case .refused: "refused"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .providerFailed: "providerFailed"
        case .outputBlocked: "outputBlocked"
        }
    }

    static func bodyIsEmpty(_ session: ComposeSession) -> Bool {
        let documentIsEmpty = session.plainText.isEmpty
        if let editor = session.editor { return editor.editorText.isEmpty }
        return documentIsEmpty
    }

    private nonisolated static let logger = Log(.ai)

    nonisolated static func log(_ line: String) {
        logger.info(line)
    }
}

enum InstantReplySignposts {
    static let signposter = OSSignposter(subsystem: OHIdentifiers.logSubsystem, category: "ai")

    static func beginRequest() -> OSSignpostIntervalState {
        signposter.beginInterval("ai.instantReply.request", id: signposter.makeSignpostID())
    }

    static func endRequest(_ state: OSSignpostIntervalState) {
        signposter.endInterval("ai.instantReply.request", state)
    }

    static func shown() {
        signposter.emitEvent("ai.instantReply.shown")
    }
}
