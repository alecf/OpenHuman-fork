import AppKit
import MailActions
import MailFakes
import MailFeatures
import MailModel
import MailTheme
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI
@testable import MailUIMac

private let stripNow = Date(timeIntervalSince1970: 1_791_000_000)

@MainActor
@Suite(.serialized) struct InstantReplyViewTests {
    static let first = "Sounds good, thanks."
    static let second = "Thanks, but I can't make it."

    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 600), styleMask: [.titled],
                          backing: .buffered, defer: false)

    init() { window.isReleasedWhenClosed = false }

    func key(_ chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 100,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func editor(width: CGFloat = 400, height: CGFloat = 200) -> ComposerTextView {
        let text = ComposerTextView.make()
        text.bridge = AttributedBridge(theme: ThemeTokens.light)
        text.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView?.addSubview(text)
        return text
    }

    @Test func tabGoesToTheStripOnlyWhileItIsLive() async throws {
        let text = editor()
        var asked: [InstantReplyModel.Key] = []
        var takes = true
        text.suggestionKeys = { key in
            asked.append(key)
            return takes
        }
        text.insertTab(nil)
        #expect(text.string.isEmpty && asked == [.next], "taken by the row: no tab character")
        takes = false
        text.insertTab(nil)
        #expect(text.string == "\t" && asked == [.next, .next], "not live: ⇥ types a tab as before")
        text.pickerKeys = { _ in true }
        text.insertTab(nil)
        #expect(asked.count == 2 && text.string == "\t", "the snippet picker takes ⇥ before the row is asked")
        text.removeFromSuperview()

        let stage = try await StripStage.make()
        defer { stage.close() }
        let strip = try #require(stage.session.instantReply)
        let body = try stage.textView()
        #expect(strip.isLive && body.string.isEmpty)
        body.insertTab(nil)
        #expect(body.string.isEmpty && strip.selection == 0, "⇥ previews the first draft; the body stays empty")
        try await until {
            stage.layout()
            return body.ghostText == Self.first
        }
        #expect(stage.session.plainText.isEmpty, "the preview is not in the draft")
        body.insertText("x", replacementRange: body.selectedRange())
        #expect(strip.selection == nil && !strip.isLive, "typing removes the preview and releases the keys")
        body.insertTab(nil)
        #expect(body.string == "x\t", "⇥ is a tab again")
        #expect(!strip.showsRow && strip.phase == .ready, "the row steps aside; its drafts stay ready")
        try await until {
            stage.layout()
            return body.ghostText == nil
        }
    }

    @Test func shiftTabReturnAndEscapeFollowTheOrder() throws {
        let text = editor()
        defer { text.removeFromSuperview() }
        #expect(window.makeFirstResponder(text))
        var asked: [InstantReplyModel.Key] = []
        var takes = true
        text.suggestionKeys = { key in
            asked.append(key)
            return takes
        }
        var escaped = 0
        text.onEscape = { escaped += 1 }
        text.keyDown(with: key("\t", code: 48))
        text.keyDown(with: key("\u{19}", code: 48, modifiers: .shift))
        text.keyDown(with: key("\r", code: 36))
        text.keyDown(with: key("\u{1b}", code: 53))
        #expect(asked == [.next, .previous, .use, .clear], "⇥ ⇧⇥ ↵ Esc reach the row")
        #expect(text.string.isEmpty && escaped == 0, "taken: no tab, no new line, the composer stays open")

        var picker: [ComposerTextView.PickerKey] = []
        text.pickerKeys = { key in
            picker.append(key)
            return true
        }
        text.cancelOperation(nil)
        #expect(picker == [.close] && asked.count == 4 && escaped == 0, "the picker closes first")
        text.pickerKeys = nil
        takes = false
        text.cancelOperation(nil)
        #expect(asked.last == .clear && escaped == 1, "nothing previewed: Esc closes the composer")

        text.keyDown(with: key("\t", code: 48))
        text.keyDown(with: key("\r", code: 36))
        #expect(text.string == "\t\n")
    }

    @Test func theGhostIsDrawnLikeThePlaceholderAndIsNotText() throws {
        let tokens = ThemeTokens.light
        let text = editor(width: 400, height: 60)
        defer { text.removeFromSuperview() }
        let words = "Sounds good, thanks. Talk soon"
        text.ghostText = words
        let ghost = try #require(ComposerTests.inkBounds(of: text))
        #expect(text.string.isEmpty && (text.textStorage?.length ?? 0) == 0, "the ghost is not the text view's value")
        text.ghostText = nil
        text.insertText(words, replacementRange: NSRange(location: 0, length: 0))
        let typed = try #require(ComposerTests.inkBounds(of: text))
        #expect(abs(ghost.minX - typed.minX) <= 1 && abs(ghost.minY - typed.minY) <= 1,
                "the ghost sits where typed text goes: \(ghost) vs \(typed)")
        #expect(abs(ghost.height - typed.height) <= 1)
        #expect(text.bridge.ghostColor == tokens.textSecondary.nsColor, "text.secondary")
        #expect(text.bridge.placeholderColor == tokens.textTertiary.nsColor, "the placeholder stays text.tertiary")

        text.string = ""
        text.ghostText = String(repeating: "Thanks for the update, I will look at the numbers tomorrow morning. ", count: 12)
        let long = try #require(ComposerTests.inkBounds(of: text))
        #expect(long.maxY <= text.bounds.height - ComposerTextView.verticalInset + 1,
                "clipped to the visible height: \(long)")
        #expect(text.contentHeight(forWidth: 400) == 18 + 2 * ComposerTextView.verticalInset,
                "the editor's own height ignores the ghost")

        text.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        let one = try #require(ComposerTests.inkBounds(of: text))
        #expect(one.width < 20 && one.height <= 18, "only the typed character is drawn: \(one)")

        text.string = ""
        text.placeholder = "Write your reply. ⌘J for AI help"
        text.spokenPlaceholder = "Quick replies available. Tab previews, Return uses."
        #expect(text.accessibilityPlaceholderValue() == "Quick replies available. Tab previews, Return uses.")
        text.spokenPlaceholder = nil
        #expect(text.accessibilityPlaceholderValue() == "Write your reply. ⌘J for AI help")
    }

    @Test func insertingIsOneUndoStepAndUndoBringsTheRowBack() async throws {
        let stage = try await StripStage.make()
        defer { stage.close() }
        let strip = try #require(stage.session.instantReply)
        let body = try stage.textView()
        body.insertTab(nil)
        body.insertTab(nil)
        try #require(strip.isLive && strip.selection == 1, "the second draft is previewed")
        try await until {
            stage.layout()
            return body.ghostText == Self.second
        }
        let undo = try #require(body.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        defer { undo.groupsByEvent = true }
        body.insertNewline(nil)
        #expect(body.string == Self.second && stage.session.plainText == Self.second, "↵ puts the preview in as text")
        #expect(strip.phase == .used(1) && !strip.showsRow)
        #expect(body.selectedRange() == NSRange(location: (Self.second as NSString).length, length: 0),
                "the caret after the reply")
        #expect(undo.canUndo)
        undo.undo()
        #expect(body.string.isEmpty && stage.session.plainText.isEmpty, "⌘Z empties the body in one step")
        #expect(!undo.canUndo)
        #expect(strip.phase == .ready && strip.isLive && strip.selection == nil, "the row is back, nothing previewed")
    }

    @Test func theRowNeverMovesTheBody() async throws {
        let (center, clock) = StripStage.aiCenter(ReplyScript(holdsFirst: true))
        let w = try await InlineReplyWindow.make(frameName: "dev.openhuman.tests.instant-reply", ai: center)
        defer { w.close() }
        let (thread, count) = try await StripStage.eligibleThread(w.environment)
        _ = try await w.open(thread)
        center.conversationAppeared(thread, messageCount: count)
        let replies = center.quickReplies(for: thread)
        try await until { replies.phase == .loading }
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await until { composer.session.instantReply != nil }
        let strip = try #require(composer.session.instantReply)
        #expect(strip.phase == .waiting && strip.showsRow)

        let sizes = [NSSize(width: 640, height: 700), NSSize(width: 1100, height: 800)]
        func bodyFrames() async throws -> [NSRect] {
            var frames: [NSRect] = []
            for size in sizes {
                w.resize(size)
                var last: NSRect?
                var settled = NSRect.zero
                try await until {
                    w.window.contentView?.layoutSubtreeIfNeeded()
                    guard let scroll = w.editors.first?.enclosingScrollView else { return false }
                    let frame = scroll.convert(scroll.bounds, to: composer)
                    defer { last = frame }
                    guard frame == last else { return false }
                    settled = frame
                    return true
                }
                frames.append(settled)
            }
            return frames
        }
        let waiting = try await bodyFrames()

        try await until { clock.waiting == [InstantReplyPolicy.slowNotice] }
        clock.releaseNext()
        try await until { strip.isSlow && clock.waiting == [InstantReplyPolicy.giveUp - InstantReplyPolicy.slowNotice] }
        clock.releaseNext()
        try await until { if case .quiet(_, canRetry: true) = strip.phase { true } else { false } }
        let quiet = try await bodyFrames()

        strip.retry()
        try await until { strip.phase == .ready }
        let ready = try await bodyFrames()

        for (index, size) in sizes.enumerated() {
            #expect(abs(waiting[index].minY - quiet[index].minY) < 0.5
                    && abs(waiting[index].height - quiet[index].height) < 0.5, "waiting → quiet moved the body at \(size)")
            #expect(abs(waiting[index].minY - ready[index].minY) < 0.5
                    && abs(waiting[index].height - ready[index].height) < 0.5, "quiet → ready moved the body at \(size)")
        }
        let card = composer.convert(composer.cardFrame, to: nil)
        for (key, view) in w.reader.messageViews where !view.isHiddenOrHasHiddenAncestor && view !== composer.hostMessage {
            let overlap = view.convert(view.bounds, to: nil).intersection(card)
            #expect(overlap.isNull || overlap.height < 0.5 || overlap.width < 0.5,
                    "the composer covers no message (\(key.gmailMessageID.rawValue))")
        }
        #expect(w.isUnderItsMessage(composer))
    }

    @Test func narrowWidthsKeepTheBadgeAndHide() async throws {
        #expect(ChipRowLayout.fitted([100, 110, 114], into: 240, floor: 40) == [80, 80, 80])
        #expect(ChipRowLayout.fitted([50, 110, 114], into: 240, floor: 40) == [50, 95, 95])
        #expect(ChipRowLayout.fitted([50, 60], into: 400, floor: 40) == [50, 60])
        #expect(ChipRowLayout.fitted([200, 200, 200], into: 30, floor: 40) == [40, 40, 40])
        #expect(InstantReplyStrip.tooltip("Line one\nLine two\nLine three") == "Line one\nLine two")

        let (center, _) = StripStage.aiCenter(ReplyScript())
        let w = try await InlineReplyWindow.make(size: NSSize(width: 640, height: 700),
                                                 frameName: "dev.openhuman.tests.instant-reply-narrow", ai: center)
        defer { w.close() }
        let (thread, count) = try await StripStage.eligibleThread(w.environment)
        _ = try await w.open(thread)
        center.conversationAppeared(thread, messageCount: count)
        try await until { center.quickReplies(for: thread).phase == .ready }
        #expect(w.router.perform(.reply))
        let composer = try await w.inlineComposer()
        try await until { composer.session.instantReply?.phase == .ready }
        let strip = try #require(composer.session.instantReply)
        #expect(strip.badge?.leavesMac == false, "the row carries the badge")
        let narrowest = composer.bounds.width
        #expect(narrowest > 200)
        for width in [narrowest, 360] {
            for theme in [ResolvedTheme.light, .dark] {
                let row = InstantReplyStrip(model: strip).environment(\.theme, theme)
                let size = NSHostingController(rootView: row).sizeThatFits(in: CGSize(width: width, height: 100))
                #expect(size.width <= width + 0.5, "the row fits \(width) pt (\(size.width))")
                let host = NSHostingView(rootView: row.frame(width: width, height: InstantReplyMetrics.rowHeight))
                host.frame = NSRect(x: 0, y: 0, width: width, height: InstantReplyMetrics.rowHeight)
                window.contentView?.addSubview(host)
                let ink = try #require(ComposerTests.inkBounds(of: host))
                #expect(ink.maxX <= width + 0.5 && ink.maxX >= width - InstantReplyMetrics.hideTarget,
                        "× is drawn at the right end at \(width) pt: \(ink)")
                host.removeFromSuperview()
            }
        }
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct InstantReplySnapshotTests {
    let renderer = SnapshotRenderTests()

    @Test func renderTheQuickRepliesRow() async throws {
        for (name, theme) in [("light", ResolvedTheme.light), ("dark", .dark)] {
            let held = try await StripStage.make(script: ReplyScript(holdsFirst: true), theme: theme)
            let waiting = try #require(held.session.instantReply)
            try await Task.sleep(for: .milliseconds(400))
            try renderer.snapshot(held.window, name: "instant-reply-waiting-\(name)")
            try await until { held.clock.waiting == [InstantReplyPolicy.slowNotice] }
            held.clock.releaseNext()
            try await until { waiting.isSlow && held.clock.waiting.count == 1 }
            held.clock.releaseNext()
            try await until { if case .quiet = waiting.phase { true } else { false } }
            try await Task.sleep(for: .milliseconds(500))
            try renderer.snapshot(held.window, name: "instant-reply-quiet-\(name)")
            held.close()

            let stage = try await StripStage.make(theme: theme)
            try await Task.sleep(for: .milliseconds(300))
            try renderer.snapshot(stage.window, name: "instant-reply-ready-\(name)")
            let body = try stage.textView()
            body.insertTab(nil)
            body.insertTab(nil)
            try await Task.sleep(for: .milliseconds(300))
            try renderer.snapshot(stage.window, name: "instant-reply-previewed-\(name)")
            stage.close()
        }

        let stage = try await StripStage.make()
        defer { stage.close() }
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 700, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScrollView {
            AISettingsSection(center: stage.center, environment: stage.env).padding(32)
        }
        .environment(\.theme, .light).frame(width: 700, height: 900).background(Color.white))
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(500))
        try renderer.snapshot(window, name: "instant-reply-settings")
        window.close()
    }
}

@MainActor
final class StripStage {
    let env: AppEnvironment
    let center: AICenter
    let clock: StripClock
    let session: ComposeSession
    let window: NSWindow
    let host: NSView

    private init(env: AppEnvironment, center: AICenter, clock: StripClock, session: ComposeSession, window: NSWindow,
                 host: NSView) {
        self.env = env
        self.center = center
        self.clock = clock
        self.session = session
        self.window = window
        self.host = host
    }

    static func aiCenter(_ script: ReplyScript) -> (AICenter, StripClock) {
        let provider = ScriptedProvider(displayName: "Apple on-device model") { request, _ in script.respond(request) }
        let settings = AISettings(draftReplies: .onDeviceAuto, instantReplyStrip: true)
        let center = AICenter.make(registry: ProviderRegistry(providers: [provider]),
                                   settings: AISettingsBox(store: InMemoryAISettingsStore(settings)))
        let clock = StripClock()
        center.instantReplyTiming = clock.timing
        return (center, clock)
    }

    static func make(script: ReplyScript = ReplyScript(), theme: ResolvedTheme = .light,
                     size: NSSize = NSSize(width: 900, height: 700)) async throws -> StripStage {
        let (center, clock) = aiCenter(script)
        let env = AppEnvironment.fake(corpus: .rich(threadCount: 60, now: stripNow), options: .init(remoteAck: .immediate),
                                      featureFlags: FeatureFlags(), ai: center)
        env.router.start()
        try await until { env.router.list?.state == .loaded && env.router.accounts.count == 2 }
        let (thread, count) = try await eligibleThread(env)
        let replies = center.quickReplies(for: thread)
        center.conversationAppeared(thread, messageCount: count)
        try await until { replies.phase != .idle && (script.holdsFirst || replies.phase != .loading) }
        let session = try #require(env.compose.openReply(thread, mode: .reply))
        await session.settle()
        session.placement = .modal
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ComposerHostView(manager: env.compose).environment(\.theme, theme)
            .frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try await until {
            host.layoutSubtreeIfNeeded()
            return session.instantReply != nil && session.editor != nil
        }
        return StripStage(env: env, center: center, clock: clock, session: session, window: window, host: host)
    }

    func textView() throws -> ComposerTextView {
        try #require(subviews(of: ComposerTextView.self, in: host).first)
    }

    func layout() {
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        if session.isOpen { env.compose.close(session) }
        window.orderOut(nil)
        window.close()
    }

    static func eligibleThread(_ env: AppEnvironment) async throws -> (ThreadKey, Int) {
        let account = AccountID(1)
        let me = try #require(env.router.accounts.first { $0.id == account }?.account)
        let rows = try await env.data.threadPage(.system(.inbox), account: account, after: nil, limit: 500).rows
        for row in rows where row.categoryLabelIDs.isEmpty {
            var messages: [MessageSummary] = []
            for try await detail in env.data.threadDetail(row.id) {
                messages = detail?.messages ?? []
                break
            }
            guard let last = messages.last, !me.isMe(last.from?.email ?? ""), !last.hasCalendarInvite else { continue }
            let unsubscribes = ((try? await env.data.unsubscribeInfo(last.id)) ?? nil) != nil
            if !unsubscribes { return (row.id, messages.count) }
        }
        Issue.record("no conversation in the fake inbox that quick replies are drafted for")
        throw TimeoutError()
    }
}

final class ReplyScript: @unchecked Sendable {
    let holdsFirst: Bool
    private let lock = NSLock()
    private var replyRequests = 0

    init(holdsFirst: Bool = false) {
        self.holdsFirst = holdsFirst
    }

    func respond(_ request: AIRequest) -> FakeResponse {
        guard request.task == .replyOptions else { return FakeAIProvider.cannedScript(request) }
        let index = lock.withLock { () -> Int in
            replyRequests += 1
            return replyRequests
        }
        return holdsFirst && index == 1 ? .hang : FakeAIProvider.cannedScript(request)
    }
}

final class StripClock: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [(id: Int, duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = []
    private var nextID = 0

    var timing: InstantReplyTiming { InstantReplyTiming(sleep: { [self] duration in try await self.sleep(duration) }) }

    var waiting: [Duration] { lock.withLock { waiters.map { $0.duration } } }

    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    waiters.append((id, duration, continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index).continuation
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    @discardableResult
    func releaseNext() -> Bool {
        let waiter = lock.withLock { waiters.isEmpty ? nil : waiters.removeFirst() }
        waiter?.continuation.resume()
        return waiter != nil
    }
}
