import Foundation
import MailModel
import Observation
import OpenHumanAI

@MainActor @Observable
public final class AIComposerModel: Identifiable {
    public enum Scope: Equatable, Sendable {
        case selection
        case wholeDraft
        case notes
    }

    public enum Phase: Equatable, Sendable {
        case ready
        case working
        case done
        case failed(String)
    }

    public struct Version: Identifiable, Hashable, Sendable {
        public let id: Int
        public let instruction: String
        public internal(set) var text: String
        public internal(set) var badge: AIProviderBadge?
        public internal(set) var isSuspicious = false
        public internal(set) var isTruncated = false
        public internal(set) var isComplete = false
        public internal(set) var base: String?
        var modelInstruction = ""
        public internal(set) var rating: Bool?
    }

    public struct Preset: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let prompt: PromptName
        public let completesInput: Bool

        public init(id: String, title: String, prompt: PromptName, completesInput: Bool = false) {
            self.id = id
            self.title = title
            self.prompt = prompt
            self.completesInput = completesInput
        }

        public var instruction: String {
            let text = (try? PromptLibraryProvider.shared.current.instruction(prompt)) ?? ""
            return completesInput && !text.isEmpty ? text + " " : text
        }
    }

    public static let presets: [Preset] = [
        Preset(id: "improve", title: String(localized: "Improve writing"), prompt: .composerImprove),
        Preset(id: "shorter", title: String(localized: "Shorten"), prompt: .composerShorter),
        Preset(id: "longer", title: String(localized: "Lengthen"), prompt: .composerLonger),
        Preset(id: "clearer", title: String(localized: "Simplify"), prompt: .composerClearer),
        Preset(id: "friendlier", title: String(localized: "Friendlier"), prompt: .composerFriendlier),
        Preset(id: "direct", title: String(localized: "More direct"), prompt: .composerDirect),
        Preset(id: "spelling", title: String(localized: "Fix spelling"), prompt: .composerSpelling),
        Preset(id: "translate", title: String(localized: "Translate…"), prompt: .composerTranslate, completesInput: true),
    ]

    public static let voicePreset = Preset(id: "voice", title: String(localized: "In my voice"), prompt: .composerVoice)

    public static let voiceOffMacNote = String(localized: "In my voice uses your sent mail, so it runs only with AI on this Mac.")

    public static let maxVersions = 3

    public let id = UUID()
    public let scope: Scope
    public var instruction = ""
    public private(set) var phase: Phase = .ready
    public private(set) var versions: [Version] = []
    public private(set) var current: Int?
    public var showsDiff = false
    public private(set) var consent: AIProviderConsentRequest?
    public let quickReplies: QuickRepliesModel?
    public let original: String
    public private(set) var voiceExamples: [String] = []
    public private(set) var voiceRefusal: String?

    @ObservationIgnored let range: Range<Int>?
    @ObservationIgnored let caret: Int?
    @ObservationIgnored private weak var session: ComposeSession?
    @ObservationIgnored private weak var center: AICenter?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var voiceTask: Task<Void, Never>?
    @ObservationIgnored private var nextVersionID = 0

    init(session: ComposeSession, center: AICenter, preferQuickReplies: Bool) {
        self.session = session
        self.center = center
        if let editor = session.editor {
            let selection = editor.editorSelection
            let selected = editor.text(in: selection) ?? ""
            let all = editor.editorText
            if !selection.isEmpty, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scope = .selection
                range = selection
                original = selected
            } else if !all.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scope = .wholeDraft
                range = editor.fullRange
                original = all
            } else {
                scope = .notes
                range = editor.fullRange
                original = ""
            }
            caret = selection.lowerBound
        } else {
            let text = session.plainText
            scope = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .notes : .wholeDraft
            range = nil
            caret = nil
            original = scope == .notes ? "" : text
        }
        if let thread = session.thread, session.mode == .reply || session.mode == .replyAll,
           scope == .notes,
           !Self.stripIsTheSet(session, thread: thread, center: center, asked: preferQuickReplies) {
            let replies = center.quickReplies(for: thread, replyingTo: Self.draftTarget(session))
            quickReplies = replies
            if scope == .notes {
                replies.request(trigger: .user)
            }
        } else {
            quickReplies = nil
        }
        if scope != .notes, center.settings.enabled {
            voiceTask = Task { [weak self] in await self?.loadVoice() }
        }
    }

    isolated deinit {
        task?.cancel()
        voiceTask?.cancel()
    }

    public var shownPresets: [Preset] { voiceExamples.isEmpty ? Self.presets : Self.presets + [Self.voicePreset] }

    public func isDisabled(_ preset: Preset) -> Bool { preset.id == Self.voicePreset.id && voiceRefusal != nil }

    func settleVoice() async { await voiceTask?.value }

    private func loadVoice() async {
        guard let center, let session else { return }
        let examples = await center.styleExamples(for: session.account)
        let status = await center.features.status(for: .rewrite, accountKey: center.policyKey(session.account.id))
        guard !Task.isCancelled else { return }
        voiceRefusal = status.dataLocation?.leavesDevice == true ? Self.voiceOffMacNote : nil
        voiceExamples = examples
    }

    public var placeholder: String {
        scope == .notes ? String(localized: "Write, find, schedule, or ask anything") : Self.editPlaceholder
    }

    public var scopeTitle: String {
        switch scope {
        case .selection: String(localized: "Rewrite the selection")
        case .wholeDraft: String(localized: "Rewrite the draft")
        case .notes: String(localized: "Write from notes")
        }
    }

    public var currentVersion: Version? { current.flatMap { versions.indices.contains($0) ? versions[$0] : nil } }

    public var counterText: String? {
        guard let current, versions.count > 1 else { return nil }
        return "\(current + 1)/\(versions.count)"
    }

    public var canApply: Bool { currentVersion.map { $0.isComplete && !$0.text.isEmpty } ?? false }

    public var diff: [AITextDiff.Segment] {
        guard let version = currentVersion else { return [] }
        return AITextDiff.segments(from: original, to: version.text)
    }

    public func submit() {
        let typed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty, let reply = quickReplies?.selectedOption {
            use(reply)
            return
        }
        if let version = currentVersion, version.instruction == typed, canApply {
            replace()
            return
        }
        generate()
    }

    public func run(_ preset: Preset) {
        if preset.completesInput {
            instruction = preset.instruction
            return
        }
        if isDisabled(preset) {
            phase = .failed(voiceRefusal ?? Self.voiceOffMacNote)
            return
        }
        instruction = preset.instruction
        generate()
    }

    public func generate() {
        let typed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let asked = typed.isEmpty ? (currentVersion?.instruction ?? "") : typed
        guard !asked.isEmpty else {
            phase = .failed(scope == .notes ? String(localized: "Jot a few notes first")
                                            : String(localized: "Describe the change, or pick a preset"))
            return
        }
        let modelInstruction = scope == .notes
            ? ((try? PromptLibraryProvider.shared.current.instruction(.composerNotes, values: ["notes": asked])) ?? asked)
            : asked
        start(asked: asked, modelInstruction: modelInstruction, from: original, base: nil)
    }

    public var editInstruction = ""

    public func submitEdit() {
        let typed = editInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else {
            replace()
            return
        }
        refine(instruction: typed)
        editInstruction = ""
    }

    public func refine(_ preset: Preset) {
        if preset.completesInput {
            if currentVersion == nil { instruction = preset.instruction } else { editInstruction = preset.instruction }
            return
        }
        if isDisabled(preset) {
            phase = .failed(voiceRefusal ?? Self.voiceOffMacNote)
            return
        }
        guard currentVersion != nil else {
            run(preset)
            return
        }
        refine(instruction: preset.instruction)
    }

    public func refine(instruction typed: String) {
        guard let version = currentVersion, version.isComplete, !version.text.isEmpty else { return }
        start(asked: typed, modelInstruction: typed, from: version.text, base: version.text)
    }

    public func retry() {
        guard let version = currentVersion else {
            generate()
            return
        }
        let modelInstruction = version.modelInstruction.isEmpty ? version.instruction : version.modelInstruction
        start(asked: version.instruction, modelInstruction: modelInstruction, from: version.base ?? original,
              base: version.base)
    }

    public func stop() {
        guard phase == .working else { return }
        task?.cancel()
        task = nil
        if let current, versions.indices.contains(current), !versions[current].isComplete {
            versions.remove(at: current)
        }
        current = versions.isEmpty ? nil : versions.count - 1
        phase = versions.isEmpty ? .ready : .done
    }

    public func rate(up: Bool) {
        guard let current, versions.indices.contains(current) else { return }
        let previous = versions[current].rating
        versions[current].rating = previous == up ? nil : up
        center?.recordRewriteFeedback(up: up, undo: previous == up)
    }

    public static let examples: [String] = [
        String(localized: "Write a short update on the project"),
        String(localized: "Thank them and confirm the time"),
        String(localized: "Ask to move our call to next week"),
    ]

    public private(set) var examplesDismissed = false

    public var showsExamples: Bool {
        scope == .notes && instruction.isEmpty && versions.isEmpty && phase == .ready && consent == nil
            && !examplesDismissed
    }

    public func useExample(_ example: String) {
        instruction = example
    }

    public func dismissExamples() {
        examplesDismissed = true
    }

    public var editPresets: [Preset] {
        let ids = ["improve", "shorter", "longer", "clearer"]
        return ids.compactMap { id in Self.presets.first { $0.id == id } }
    }

    public var morePresets: [Preset] {
        let shown = Set(editPresets.map(\.id))
        return shownPresets.filter { !shown.contains($0.id) }
    }

    public static let workingText = String(localized: "One moment…")

    public static let editPlaceholder = String(localized: "Describe how to edit the text")

    private func start(asked: String, modelInstruction: String, from text: String, base: String?) {
        guard let center, let session else { return }
        task?.cancel()
        consent = nil
        var version = Version(id: nextVersionID, instruction: asked, text: "")
        version.base = base
        version.modelInstruction = modelInstruction
        nextVersionID += 1
        versions.append(version)
        if versions.count > Self.maxVersions { versions.removeFirst(versions.count - Self.maxVersions) }
        current = versions.count - 1
        let versionID = version.id
        phase = .working
        var context = rewriteContext(session: session, center: center)
        if asked == Self.voicePreset.instruction, voiceRefusal == nil { context.styleExamples = voiceExamples }
        let events = center.features.rewriteEvents(text, instruction: modelInstruction, context: context)
        task = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled, let self else { return }
                    switch event {
                    case .started(let provenance):
                        self.updateVersion(versionID) { $0.badge = AIProviderBadge(provenance: provenance) }
                    case .textDelta(let delta):
                        self.updateVersion(versionID) { $0.text += delta }
                    case .completed(let report):
                        self.updateVersion(versionID) {
                            $0.isSuspicious = report.suspicious
                            $0.isTruncated = report.truncated
                            if report.truncated { $0.text = AnswerTrim.toLastCompleteSentence($0.text) }
                        }
                    }
                }
                guard !Task.isCancelled, let self else { return }
                self.updateVersion(versionID) { $0.isComplete = true }
                let empty = self.versions.first { $0.id == versionID }?.text.isEmpty ?? true
                self.phase = empty ? .failed(String(localized: "The model returned no text")) : .done
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.versions.removeAll { $0.id == versionID }
                self.current = self.versions.isEmpty ? nil : self.versions.count - 1
                await self.failed(error)
            }
        }
    }

    public func previousVersion() {
        guard let current, current > 0 else { return }
        self.current = current - 1
    }

    public func nextVersion() {
        guard let current, current + 1 < versions.count else { return }
        self.current = current + 1
    }

    private func updateVersion(_ id: Int, _ change: (inout Version) -> Void) {
        guard let index = versions.firstIndex(where: { $0.id == id }) else { return }
        change(&versions[index])
    }

    private func failed(_ error: any Error) async {
        if case AIError.unavailable(.notConsented) = error, let center, let session {
            let status = await center.features.status(for: .rewrite, accountKey: center.policyKey(session.account.id))
            if let id = status.providerID, let request = await center.consentRequest(for: id) {
                consent = request
                phase = .ready
                return
            }
        }
        phase = .failed(AIWording.failure(error))
    }

    static func draftTarget(_ session: ComposeSession) -> MessageKey? {
        session.offeredReplyTarget ?? session.replyTo
    }

    static func stripIsTheSet(_ session: ComposeSession, thread: ThreadKey, center: AICenter, asked: Bool) -> Bool {
        if session.offeredReplyTarget == nil, let scheduling = center.environment?.schedulingIfStarted,
           !scheduling.suggestions(for: thread, message: draftTarget(session)).isEmpty {
            return true
        }
        guard !asked, session.offeredReplyTarget == nil, case .docked = session.placement,
              let row = center.inlineReplies.current, row.thread == thread else { return false }
        return row.state == .ready
    }

    private func rewriteContext(session: ComposeSession, center: AICenter) -> AIThreadInput {
        let key = center.policyKey(session.account.id)
        if let thread = session.thread {
            let target = Self.draftTarget(session) ?? center.replyTarget(in: thread)
            if var loaded = center.loadedInput(thread, upTo: target) {
                loaded.trigger = .user
                loaded.accountKey = key
                return loaded
            }
            return AIThreadInput(threadKey: AIThreadLoader.threadKey(thread), subject: session.subject, messages: [],
                                 accountKey: key, trigger: .user)
        }
        return AIThreadInput(threadKey: "draft.\(session.id.uuidString)", subject: session.subject, messages: [],
                             accountKey: key, trigger: .user)
    }

    public func acceptConsent() async {
        guard let consent, let center else { return }
        do {
            try await center.grantConsent(consent)
            self.consent = nil
            generate()
        } catch {
            phase = .failed(String(localized: "Couldn't save the choice"))
        }
    }

    public func declineConsent() {
        guard let consent else { return }
        self.consent = nil
        phase = .failed(AIWording.reason(.notConsented, providerName: consent.providerName))
    }

    public func replace() {
        guard canApply, let text = currentVersion?.text else { return }
        apply(text, below: false)
    }

    public func insertBelow() {
        guard canApply, let text = currentVersion?.text else { return }
        apply(text, below: true)
    }

    public func use(_ reply: QuickReply) {
        guard let session, let center else { return }
        guard let editor = session.editor else {
            center.copyInstead(reply.body, session: session, reason: String(localized: "The composer isn't on screen."))
            close()
            return
        }
        let target: Range<Int>
        switch scope {
        case .notes:
            target = QuickReplyInsertion.target(in: editor)
        case .selection:
            target = range ?? editor.editorSelection
        case .wholeDraft:
            let at = min(caret ?? editor.editorSelection.lowerBound, editor.fullRange.upperBound)
            target = at..<at
        }
        QuickReplyInsertion.insert(reply, over: target, expected: target == range ? original : nil, editor: editor,
                                   session: session, center: center)
        close()
    }

    private func apply(_ text: String, below: Bool) {
        guard let session, let center else { return }
        guard let editor = session.editor else {
            center.copyInstead(text, session: session, reason: String(localized: "The composer isn't on screen."))
            close()
            return
        }
        let resolved: Range<Int>
        let expected: String?
        if let range {
            resolved = range
            expected = scope == .notes ? nil : original
        } else if editor.editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolved = editor.fullRange
            expected = nil
        } else {
            resolved = editor.editorSelection
            expected = nil
        }
        if below {
            let at = resolved.upperBound
            put((original.isEmpty ? "" : "\n\n") + text, over: at..<at, expected: nil, editor: editor, session: session,
                center: center, check: expected.map { (resolved, $0) })
        } else {
            put(text, over: resolved, expected: expected, editor: editor, session: session, center: center)
        }
    }

    private func put(_ text: String, over target: Range<Int>, expected: String?, editor: any ComposeTextEditing,
                     session: ComposeSession, center: AICenter, check: (Range<Int>, String)? = nil) {
        let stale: Bool
        if let expected, editor.text(in: target) != expected {
            stale = true
        } else if let check, editor.text(in: check.0) != check.1 {
            stale = true
        } else {
            stale = target.upperBound > editor.fullRange.upperBound
        }
        if stale || !editor.replaceText(in: target, with: text) {
            center.copyInstead(text, session: session,
                               reason: String(localized: "The draft changed while the AI was writing, so the text wasn't put in."))
        }
        close()
    }

    public func close(refocus: Bool = true) {
        task?.cancel()
        task = nil
        guard let session else { return }
        if session.aiPanel === self { session.aiPanel = nil }
        if refocus { session.editor?.focusEditor() }
    }
}
