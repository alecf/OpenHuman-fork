import AppKit
import MailActions
import MailFeatures
import MailModel
import MailTheme
import MailUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized)
struct ReaderHeaderPolishTests {
    typealias F = UIFixtures

    private func harness(subject: String, safeMode: SafeModeInfo = .normal) async throws -> ReaderHarness {
        let detail = F.conversation(2, count: 1, subject: subject)
        let source = UITestSource(details: [detail], bodies: [detail.messages[0].id: MessageContent(html: nil, text: "Hi")],
                                  safeMode: safeMode)
        let h = try await ReaderHarness.make(source, thread: detail.id, safeMode: safeMode)
        try await until { !h.controller.threadActionButtons.isEmpty }
        h.controller.view.layoutSubtreeIfNeeded()
        return h
    }

    private let longSubject = "Re: Fwd: The quarterly planning review for the whole platform organisation, with the budget "
        + "assumptions, hiring plan and the open questions from last week's leadership sync"

    @Test(arguments: [(640.0, "narrow"), (1500.0, "wide")])
    func subjectSpansTheColumnAndActionsSitBelowIt(width: Double, name: String) async throws {
        let h = try await harness(subject: longSubject)
        defer { h.close() }
        h.window.setFrame(NSRect(x: -5000, y: -5000, width: width, height: 900), display: true)
        h.controller.view.layoutSubtreeIfNeeded()
        let subject = h.controller.subjectView
        let row = h.controller.subjectContainer
        #expect(subject.alignmentRect(forFrame: subject.frame).width == row.frame.width, "\(name): the subject is the container width")
        #expect(row.frame.width > 300, "\(name)")
        #expect(row.frame.width <= 760)
        let buttons = h.controller.threadActionButtons
        #expect(!h.controller.actionsOnSubjectLine, "\(name): a subject this long keeps the actions on their own row")
        let subjectFrame = row.convert(subject.bounds, from: subject)
        for button in buttons {
            let frame = row.convert(button.bounds, from: button)
            #expect(!frame.intersects(subjectFrame), "\(name): \(button.identifier?.rawValue ?? "")")
        }
        if width < 700 { #expect(subject.frame.height > 40) }
    }

    @Test(arguments: [SafeModeInfo.normal, SafeModeInfo.readOnly])
    func theActionBarNeverHoldsAnActionWithoutASymbol(safeMode: SafeModeInfo) async throws {
        let h = try await harness(subject: "Plan", safeMode: safeMode)
        defer { h.close() }
        let buttons = h.controller.threadActionButtons
        #expect(!buttons.isEmpty)
        for button in buttons {
            let id = try #require(button.identifier?.rawValue)
            let symbol = try #require(ReaderActions.symbol(for: ActionID(id)), "\(id) has no symbol")
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(id): \(symbol)")
            #expect(button.image?.size.width ?? 0 > 0, "\(id) draws a glyph")
            #expect(button.frame.width >= 28 && button.frame.height >= 28, "\(id) hit target")
            #expect(!(button.tipText ?? "").isEmpty, "\(id) tooltip")
            #expect(!(button.accessibilityLabel() ?? "").isEmpty, "\(id) VoiceOver label")
        }
    }

    @Test func aShortSubjectKeepsTheActionsOnItsLine() async throws {
        let h = try await harness(subject: "Plan")
        defer { h.close() }
        h.window.setFrame(NSRect(x: -5000, y: -5000, width: 1360, height: 900), display: true)
        h.controller.view.layoutSubtreeIfNeeded()
        h.controller.view.layoutSubtreeIfNeeded()
        #expect(h.controller.actionsOnSubjectLine)
        let row = h.controller.subjectContainer
        let subject = row.convert(h.controller.subjectView.bounds, from: h.controller.subjectView)
        let buttons = h.controller.threadActionButtons
        #expect(buttons.map { $0.identifier?.rawValue } == ReaderActions.primaryThreadActionIDs.map(\.rawValue)
            .filter { id in buttons.contains { $0.identifier?.rawValue == id } })
        let more = row.convert(h.controller.threadMoreButton.bounds, from: h.controller.threadMoreButton)
        #expect(more.minX > subject.minX && abs(more.midY - subject.midY) < 8, "⋯ ends the strip on the subject's line")
        #expect((h.controller.subjectView as? NSTextField)?.font?.pointSize == CGFloat(ThemeTokens.light.typeDisplay.size))
    }

    @Test func thePreviousAndNextArrowsEndTheStrip() async throws {
        let h = try await harness(subject: "Plan")
        defer { h.close() }
        h.window.setFrame(NSRect(x: -5000, y: -5000, width: 1360, height: 900), display: true)
        h.controller.view.layoutSubtreeIfNeeded()
        h.controller.view.layoutSubtreeIfNeeded()
        let nav = h.controller.threadNavButtons
        #expect(nav.map { $0.identifier?.rawValue } == ReaderActions.navigationActionIDs.map(\.rawValue))
        #expect(nav.map { $0.accessibilityLabel() } == ["Previous conversation", "Next conversation"])
        let row = h.controller.subjectContainer
        let more = row.convert(h.controller.threadMoreButton.bounds, from: h.controller.threadMoreButton)
        let previous = row.convert(nav[0].bounds, from: nav[0])
        let next = row.convert(nav[1].bounds, from: nav[1])
        #expect(abs(previous.minX - more.maxX - CGFloat(ThemeTokens.light.space4)) < 0.5, "12 pt after ⋯")
        #expect(abs(next.minX - previous.maxX - CGFloat(ThemeTokens.light.space2)) < 0.5, "4 pt between the arrows")
        #expect(abs(next.midY - more.midY) <= 1.5 && abs(previous.midY - more.midY) <= 1.5, "on the same line")
        #expect(nav.allSatisfy { $0.image?.size.width ?? 0 > 0 && $0.frame.width >= 28 })
    }

    @Test func theDoneTipShowsUnderItsButtonAndAScrollHidesIt() async throws {
        let h = try await harness(subject: "Plan")
        defer { h.close() }
        h.window.setFrame(NSRect(x: -5000, y: -5000, width: 1360, height: 900), display: true)
        h.controller.view.layoutSubtreeIfNeeded()
        let done = try #require(h.controller.threadActionButtons.first { $0.identifier?.rawValue == ActionID.markDone.rawValue })
        #expect(done.tip?.title == "Mark done" && done.tip?.keycaps == ["E"] && done.toolTip == nil)
        let tip = h.controller.tooltipView
        #expect(tip.isHidden)
        h.controller.showTooltipNow(for: done)
        #expect(!tip.isHidden && tip.content == done.tip)
        let root = h.controller.view
        let button = done.convert(done.bounds, to: root)
        let pill = tip.pillFrame
        #expect(!pill.intersects(button), "never over its button")
        #expect(abs(pill.midX - button.midX) < 0.5 || pill.minX == root.bounds.minX + KeycapTooltipView.margin
                || pill.maxX == root.bounds.maxX - KeycapTooltipView.margin, "centred under it unless at an edge")
        #expect(root.bounds.insetBy(dx: KeycapTooltipView.margin - 0.5, dy: KeycapTooltipView.margin - 0.5).contains(pill),
                "inside the reader")
        #expect(root.isFlipped ? pill.minY >= button.maxY : pill.maxY <= button.minY, "under the button")
        h.controller.userScrolled()
        #expect(tip.isHidden, "a scroll hides it")
    }

    @Test func everyActionThePolicyOffersHasASymbol() {
        for action in ReaderActions.threadActions + ReaderActions.messageActions {
            #expect(ReaderActions.symbol(for: action.id) != nil, "\(action.id.rawValue)")
        }
    }

    @Test(arguments: [true, false])
    func theStarButtonShowsTheStarredState(starred: Bool) async throws {
        let base = F.conversation(3, count: 1, subject: "Plan")
        let detail = ConversationDetail(id: base.id, subject: base.subject, messages: base.messages, isStarred: starred)
        let source = UITestSource(details: [detail], bodies: [detail.messages[0].id: MessageContent(html: nil, text: "Hi")])
        let h = try await ReaderHarness.make(source, thread: detail.id)
        defer { h.close() }
        try await until { !h.controller.threadActionButtons.isEmpty && h.model.isStarred == starred }
        #expect(!h.controller.threadActionButtons.contains { $0.identifier?.rawValue == ActionID.toggleStar.rawValue },
                "Star is not one of the primary five")
        let star = try #require(h.controller.threadMoreMenu().items.first { $0.identifier?.rawValue == ActionID.toggleStar.rawValue })
        #expect(star.title.hasPrefix(starred ? "Unstar" : "Star"), "\(star.title)")
        #expect(star.state == (starred ? .on : .off))
    }

    @Test func theToolbarTitleIsNeverABareCount() async throws {
        let h = try await harness(subject: "Plan")
        defer { h.close() }
        let title = ShellToolbar.conversationTitle(h.model)
        #expect(title.isEmpty || title.contains("·") || title.hasSuffix("messages"), "\(title)")
        #expect(ShellToolbar.conversationTitle(nil).isEmpty)
    }
}
