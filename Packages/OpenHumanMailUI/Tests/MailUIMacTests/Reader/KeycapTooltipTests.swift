import AppKit
import MailActions
import MailFeatures
import MailModel
import MailTheme
import Testing
@testable import MailUIMac

@MainActor
struct KeycapTooltipTests {

    @Test func anEnabledActionShowsItsNameAndKey() throws {
        let done = try #require(ActionCatalog.descriptor(.markDone))
        let tip = KeycapTooltipContent.make(title: done.title, bindings: [.key("e")], enabled: true, reason: nil)
        #expect(tip.title == "Mark done" && tip.keycaps == ["E"])
        #expect(tip.plainText == "Mark done  E")
        #expect(tip.plainText == ReaderActions.availability(done, decided: .enabled).help)
    }

    @Test func aSequenceShowsOneKeycapPerChordAndAShiftedKeyShowsShift() {
        let sequence = KeycapTooltipContent.make(title: "Go to Inbox", bindings: [.sequence("g", "i")], enabled: true, reason: nil)
        #expect(sequence.keycaps == ["G", "I"])
        #expect(sequence.plainText == "Go to Inbox  G I")
        let shifted = KeycapTooltipContent.make(title: "Snooze…", bindings: [.key("H")], enabled: true, reason: nil)
        #expect(shifted.keycaps == ["shift", "H"])
        #expect(shifted.title == "Snooze" && shifted.plainText == "Snooze…  ⇧H")
        let first = KeycapTooltipContent.make(title: "Mute", bindings: [.key("M"), .key("m")], enabled: true, reason: nil)
        #expect(first.keycaps == ["shift", "M"], "the first binding only")
        let chord = KeycapTooltipContent.make(title: "Attach files…", bindings: [.chord("U", .command)], enabled: true, reason: nil)
        #expect(chord.keycaps == ["⌘", "shift", "U"])
    }

    @Test func aShortcutTipCarriesItsHintAndTheHintTakesALine() {
        let tip = ShortcutTip(title: "Attach files", keycaps: ["⌘", "shift", "U"], hint: "(or drag ’n’ drop files)")
        let content = KeycapTooltipContent(tip)
        #expect(content.title == "Attach files" && content.keycaps == ["⌘", "shift", "U"])
        #expect(content.hint == "(or drag ’n’ drop files)")
        let view = KeycapTooltipView(theme: .light)
        let plain = view.pillSize(for: KeycapTooltipContent(title: "Attach files", keycaps: ["⌘", "shift", "U"]))
        let hinted = view.pillSize(for: content)
        let theme = ThemeTokens.light
        #expect(abs(hinted.height - (plain.height + theme.space1 + CGFloat(theme.typeLabel.lineHeight))) < 0.5)
        #expect(hinted.width >= plain.width)
    }

    @Test func theListRowTipNamesTheActionAndItsKey() throws {
        let controller = ThreadListViewController(theme: .light)
        let done = try #require(controller.rowActionTip(ThreadRowView.HoverAction(action: .markDone, symbol: "checkmark",
                                                                                  title: "Mark done")))
        #expect(done.title == "Mark done" && done.keycaps == ["E"])
        let remind = try #require(controller.rowActionTip(ThreadRowView.HoverAction(action: .remind, symbol: "bell",
                                                                                    title: "Remind me")))
        let remindKeys = try #require(ActionCatalog.descriptor(.remind).map(ShortcutTip.keycaps))
        #expect(remind.title == "Remind me" && !remindKeys.isEmpty && remind.keycaps == remindKeys)
    }

    @Test func thePresenterPlacesTheTipUnderTheButtonAndHidesIt() {
        let presenter = KeycapTooltipPresenter(theme: .light)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let button = NSView(frame: NSRect(x: 300, y: 500, width: 28, height: 28))
        root.addSubview(button)
        root.addSubview(presenter.view)
        let content = KeycapTooltipContent(title: "Mark done", keycaps: ["E"])
        presenter.show(content, for: button)
        #expect(!presenter.view.isHidden && presenter.anchor === button)
        #expect(presenter.view.pillFrame.maxY == button.frame.minY - KeycapTooltipView.gap, "below the button")
        #expect(!presenter.view.pillFrame.intersects(button.frame))
        presenter.hover(button, content: content, inside: false)
        #expect(presenter.view.isHidden && presenter.anchor == nil)
        presenter.show(content, for: button)
        presenter.apply(theme: .dark)
        #expect(presenter.view.isHidden, "a theme change drops the tip")
        let stray = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        presenter.show(content, for: stray)
        #expect(presenter.view.isHidden, "only buttons inside the host get a tip")
    }

    @Test func aDisabledActionShowsTheReasonWithoutKeys() {
        let reason = DisabledReason.noSelection.description
        let tip = KeycapTooltipContent.make(title: "Mark done", bindings: [.key("e")], enabled: false, reason: reason)
        #expect(tip.title == reason && tip.keycaps.isEmpty && tip.plainText == reason)
        let noKey = KeycapTooltipContent.make(title: "More actions", bindings: [], enabled: true, reason: nil)
        #expect(noKey.title == "More actions" && noKey.keycaps.isEmpty && noKey.plainText == "More actions")
    }


    private let bounds = NSRect(x: 0, y: 0, width: 800, height: 600)
    private let size = NSSize(width: 120, height: 26)

    @Test func theTipSitsCentredUnderTheButton() {
        let anchor = NSRect(x: 300, y: 500, width: 28, height: 28)
        let frame = KeycapTooltipLayout.frame(anchor: anchor, size: size, bounds: bounds, gap: 6, margin: 8, flipped: false)
        #expect(frame.maxY == anchor.minY - 6 && frame.midX == anchor.midX && frame.size == size)
        let flipped = KeycapTooltipLayout.frame(anchor: anchor, size: size, bounds: bounds, gap: 6, margin: 8, flipped: true)
        #expect(flipped.minY == anchor.maxY + 6 && flipped.midX == anchor.midX)
    }

    @Test func nearTheBottomTheTipGoesAbove() {
        let low = NSRect(x: 300, y: 20, width: 28, height: 28)
        let frame = KeycapTooltipLayout.frame(anchor: low, size: size, bounds: bounds, gap: 6, margin: 8, flipped: false)
        #expect(frame.minY == low.maxY + 6, "above the button")
        #expect(!frame.intersects(low), "never over its button")
        let lowFlipped = NSRect(x: 300, y: 560, width: 28, height: 28)
        let flipped = KeycapTooltipLayout.frame(anchor: lowFlipped, size: size, bounds: bounds, gap: 6, margin: 8, flipped: true)
        #expect(flipped.maxY == lowFlipped.minY - 6)
    }

    @Test func theTipStaysEightPointsInsideTheSides() {
        let left = NSRect(x: 2, y: 300, width: 28, height: 28)
        #expect(KeycapTooltipLayout.frame(anchor: left, size: size, bounds: bounds, gap: 6, margin: 8, flipped: false).minX == 8)
        let right = NSRect(x: 780, y: 300, width: 28, height: 28)
        #expect(KeycapTooltipLayout.frame(anchor: right, size: size, bounds: bounds, gap: 6, margin: 8, flipped: false).maxX == 792)
    }


    @Test func coldTheTipWaitsWarmItShowsAtOnce() {
        let timing = KeycapTooltipTiming(delay: .milliseconds(500), warm: .milliseconds(1500))
        #expect(timing.wait(sinceLastHidden: nil) == .milliseconds(500), "cold")
        #expect(timing.wait(sinceLastHidden: .seconds(1)) == .zero, "warm: another tip hid 1 s ago")
        #expect(timing.wait(sinceLastHidden: .seconds(2)) == .milliseconds(500), "cold again after 1.5 s")
        let theme = KeycapTooltipTiming(theme: .light)
        #expect(theme.delay == .milliseconds(Int(ThemeTokens.light.motionTooltipDelay)))
        #expect(theme.warm == .milliseconds(Int(ThemeTokens.light.motionTooltipWarm)))
    }


    @Test func theViewShowsAndHidesAndIsNotAControl() {
        let view = KeycapTooltipView(theme: .light)
        #expect(view.isHidden)
        let content = KeycapTooltipContent.make(title: "Mark done", bindings: [.key("e")], enabled: true, reason: nil)
        let size = view.pillSize(for: content)
        #expect(size.height == CGFloat(ThemeTokens.light.component.keycap.height + 2 * ThemeTokens.light.space2))
        let bare = view.pillSize(for: KeycapTooltipContent(title: "Mark done"))
        #expect(size.width > bare.width, "the keycap takes room")
        view.show(content, at: NSRect(origin: NSPoint(x: 100, y: 100), size: size))
        #expect(!view.isHidden && view.content == content && view.pillFrame.size == size)
        #expect(view.frame.contains(view.pillFrame), "the shadow's room around the pill")
        #expect(view.hitTest(NSPoint(x: 110, y: 110)) == nil, "takes no clicks")
        #expect(!view.isAccessibilityElement())
        view.hide()
        #expect(view.isHidden)
    }


    private final class Count { var value = 0 }

    @Test func theHeaderGlyphsHaveKeycapTipsAndTheChevronTogglesTheDetails() throws {
        let fixed = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let summary = MessageSummary(id: UIFixtures.message(7), from: UIFixtures.dana, to: [UIFixtures.me], cc: [], bcc: [],
                                     date: fixed.addingTimeInterval(-3600), snippet: "Hi", isUnread: false, attachments: [])
        let toggled = Count()
        var actions = MessageHeaderActions()
        actions.availability = { ReaderActions.availability($0, decided: .enabled) }
        actions.toggleDetails = { toggled.value += 1 }
        let header = MessageHeaderView(summary, me: ["robin@example.com"], theme: .light, format: ThreadRowFormatting(),
                                       reader: ReaderFormatting(), now: fixed, actions: actions)
        let caps = header.actionButtons.compactMap { $0.tip?.keycaps.first }
        #expect(caps == ["R", "A", "F"], "reply, reply all, forward")
        #expect(header.actionButtons.allSatisfy { $0.toolTip == nil && $0.tip != nil }, "one tip only")
        let chevron = try #require(header.detailsButton)
        #expect(chevron.tipText == "Show details" && chevron.tip?.keycaps.isEmpty == true)
        #expect(chevron.accessibilityLabel() == "Show details")
        chevron.onPress?()
        #expect(header.detailsShown && toggled.value == 1)
        #expect(chevron.tipText == "Hide details" && chevron.accessibilityLabel() == "Hide details")
        chevron.onPress?()
        #expect(!header.detailsShown && chevron.tipText == "Show details")
    }

    @Test func aButtonWithATipHasNoSystemTooltip() {
        let button = ReaderButton.icon("checkmark", help: "Mark done", theme: .light) {}
        #expect(button.toolTip == "Mark done" && button.tipText == "Mark done")
        button.tip = KeycapTooltipContent.make(title: "Mark done", bindings: [.key("e")], enabled: true, reason: nil)
        #expect(button.toolTip == nil && button.tipText == "Mark done  E")
        #expect(button.accessibilityHelp() == "Mark done  E")
    }
}
