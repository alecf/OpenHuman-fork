import AppKit
import MailFeatures
import MailModel
import MailRender
import MailTheme
@testable import MailUI
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUIMac

@MainActor
@Suite(.serialized)
struct RenderReviewFixTests {
    typealias F = UIFixtures

    nonisolated static let lightThemes = [BuiltinThemeID.light, BuiltinThemeID.paper, BuiltinThemeID.systemLight]
    nonisolated static let darkThemes = [BuiltinThemeID.dark, BuiltinThemeID.midnight, BuiltinThemeID.systemDark]

    static func tokens(_ themeID: String, accent: String? = nil, increaseContrast: Bool = false) -> ThemeTokens {
        ThemeLibrary.builtIn.resolve(themeID: themeID, appearance: darkThemes.contains(themeID) ? .dark : .light,
                                     preferences: ThemePreferences(accentID: accent), increaseContrast: increaseContrast).tokens
    }

    static func same(_ a: NSColor?, _ b: NSColor) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.002 && abs(a.greenComponent - b.greenComponent) < 0.002
            && abs(a.blueComponent - b.blueComponent) < 0.002 && abs(a.alphaComponent - b.alphaComponent) < 0.002
    }

    static func sameFont(_ a: NSFont?, _ b: NSFont) -> Bool {
        a?.fontName == b.fontName && a?.pointSize == b.pointSize
    }

    @Test(arguments: lightThemes)
    func theNewMessagesPillLabelIsTextOnAccent(themeID: String) {
        for accent in BuiltinThemeID.accents {
            let t = Self.tokens(themeID, accent: accent)
            #expect(t.accentOnFill.contrastRatio(on: t.accentFill) >= 4.5, "\(themeID) \(accent): text on the accent")
        }
        let t = Self.tokens(themeID)
        let pill = NewMessagesPillView(theme: t)
        for count in [3, 1, 2] {
            pill.update(count: count, key: nil)
            let text = pill.label.attributedStringValue
            #expect(text.string == ReaderFormatting.newMessagesTitle(count))
            #expect(Self.same(text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, t.accentOnFill.nsColor),
                    "\(themeID) count \(count): the label keeps accent.onFill")
            #expect(Self.sameFont(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, t.typeLabel.font),
                    "\(themeID) count \(count): the label keeps type.label")
        }
    }

    @Test func theOutgoingStatusKeepsItsTypeWhenItChanges() {
        let t = ThemeTokens.light
        func message(_ state: OutgoingMessage.State, id: UUID) -> OutgoingMessage {
            OutgoingMessage(id: id, thread: F.thread(1), mode: .reply, from: F.me, to: [F.dana], cc: [], text: "On it",
                            date: Date(), earlierMessages: [], state: state)
        }
        let id = UUID()
        let view = OutgoingMessageView(message(.undoable, id: id), theme: t, format: ThreadRowFormatting())
        #expect(view.statusText == "Sending…")
        #expect(Self.same(view.statusColor, t.textSecondary.nsColor))
        view.update(message(.sent, id: id))
        #expect(view.statusText == "Sent")
        #expect(Self.same(view.statusColor, t.textSuccess.nsColor))
        #expect(Self.sameFont(view.statusFont, t.typeMeta.font))
        #expect(view.accessibilityLabel()?.hasSuffix(", sent") == true)
    }

    @Test func quickReplyChipsAreCapsules() {
        let rect = CGRect(x: 0, y: 0, width: 96, height: 28)
        for themeID in Self.lightThemes + Self.darkThemes {
            let chip = Self.tokens(themeID).component.chipAI
            let shape = ChipShape(radius: CGFloat(chip.radius))
            let frame = CGRect(x: 0, y: 0, width: 96, height: chip.height)
            #expect(shape.path(in: frame) == Capsule(style: .circular).path(in: frame), "\(themeID)")
            #expect(shape.inset(by: 0.75).path(in: frame) == Capsule(style: .circular).path(in: frame.insetBy(dx: 0.75, dy: 0.75)),
                    "\(themeID): the border's inset outline is a capsule too")
        }
        #expect(ChipShape(radius: 6).path(in: rect) == RoundedRectangle(cornerRadius: 6, style: .circular).path(in: rect))
        #expect(ChipShape(radius: 6).inset(by: 1).path(in: rect)
                == RoundedRectangle(cornerRadius: 5, style: .circular).path(in: rect.insetBy(dx: 1, dy: 1)))
    }

    private func harness(theme: ThemeTokens = .light, count: Int = 2) async throws -> (ReaderHarness, ConversationDetail) {
        let detail = F.conversation(2, count: count)
        var bodies: [MessageKey: MessageContent] = [:]
        for message in detail.messages { bodies[message.id] = MessageContent(html: nil, text: "Thanks, Thursday works.") }
        let h = try await ReaderHarness.make(UITestSource(details: [detail], bodies: bodies), thread: detail.id, theme: theme)
        return (h, detail)
    }

    @Test func theOneLineHeaderIsOneBand() async throws {
        let (h, detail) = try await harness()
        defer { h.close() }
        let key = try #require(detail.messages.last?.id)
        let header = try await h.header(key)
        h.controller.view.layoutSubtreeIfNeeded()
        #expect(MessageHeaderView.isOneLine)
        #expect(abs(header.frame.height - MessageHeaderView.oneLineBand) < 0.5, "height \(header.frame.height)")
        #expect(header.bodyGap >= 0 && header.bodyGap <= ThemeTokens.light.space4)
        let buttons = header.actionButtons
        #expect(!buttons.isEmpty)
        for button in buttons {
            let frame = button.convert(button.bounds, to: header)
            #expect(abs(frame.midY - header.bounds.midY) <= 1, "\(button.identifier?.rawValue ?? ""): \(frame.midY)")
            #expect(header.bounds.contains(frame.insetBy(dx: 0.5, dy: 0.5)), "inside the band, so it takes its clicks")
        }
    }

    @Test(arguments: lightThemes + darkThemes)
    func increaseContrastStrengthensTheCardEdgeAndRingsFocus(themeID: String) {
        let on = Self.tokens(themeID, increaseContrast: true)
        let off = Self.tokens(themeID)
        #expect(on.increaseContrast && !off.increaseContrast)
        let card = MessageCardView(theme: on)
        #expect(Self.same(card.border, on.borderControl.nsColor))
        #expect(Self.same(card.ring, on.accentRing.nsColor))
        #expect(on.accentRing.contrastRatio(on: on.bgCard) >= 3, "\(themeID): the ring on the card")
        #expect(on.borderControl.contrastRatio(on: on.bgWindow) >= 3, "\(themeID): the edge")
        let plain = MessageCardView(theme: off)
        #expect(Self.same(plain.border, off.borderElevated.nsColor))
        #expect(plain.ring == nil)
    }

    @Test(arguments: [false, true])
    func theFocusedCardRingsUnderIncreaseContrast(increaseContrast: Bool) async throws {
        let (h, detail) = try await harness(theme: Self.tokens(BuiltinThemeID.light, increaseContrast: increaseContrast))
        defer { h.close() }
        let first = detail.messages[0].id, last = detail.messages[1].id
        h.model.focus(last)
        try await until { h.container(last)?.isFocused == true }
        let focused = try #require(h.container(last)?.card)
        #expect((focused.showsFocusRing && focused.ring != nil) == increaseContrast)
        #expect(h.container(first)?.card.showsFocusRing == false)
    }

    @Test func theConversationLeavesRoomForTheToastBand() async throws {
        let (h, detail) = try await harness(count: 3)
        defer { h.close() }
        let t = ThemeTokens.light
        #expect(abs(Double(h.controller.toastBand) - (t.component.toast.bottom + t.component.toast.height + t.space3)) < 0.001)
        let lastKey = try #require(detail.messages.last?.id)
        try await until { h.container(lastKey) != nil }
        let last = try #require(h.container(lastKey))
        h.controller.view.layoutSubtreeIfNeeded()
        let document = try #require(last.enclosingScrollView?.documentView)
        let frame = last.convert(last.bounds, to: document)
        #expect(document.bounds.maxY - frame.maxY >= h.controller.toastBand - 0.5, "room under the last card")
    }

    @Test func thePlainTextFoldIsQuietDots() throws {
        let t = ThemeTokens.light
        let document = PlainTextDocument.parse("Sounds good, see https://example.com/plan\n\nOn Tue, Sam wrote:\n> Can we move it?\n> Wednesday is packed.")
        let view = PlainTextMessageView(document, theme: t, quotesExpanded: false)
        #expect(view.hasFoldedText)
        #expect(view.textView.linkTextAttributes?[.foregroundColor] == nil)
        let storage = try #require(view.textView.textStorage)
        let string = storage.string as NSString
        let fold = string.range(of: "•••")
        #expect(fold.location != NSNotFound)
        #expect(storage.attribute(.link, at: fold.location, effectiveRange: nil) as? URL == PlainTextMessageView.foldURL)
        #expect(Self.same(storage.attribute(.foregroundColor, at: fold.location, effectiveRange: nil) as? NSColor,
                          t.textTertiary.nsColor))
        let link = string.range(of: "https://example.com/plan")
        #expect(storage.attribute(.link, at: link.location, effectiveRange: nil) as? URL == URL(string: "https://example.com/plan"))
        #expect(Self.same(storage.attribute(.foregroundColor, at: link.location, effectiveRange: nil) as? NSColor,
                          t.component.link.text.nsColor))
    }

    @Test func composerPolishMetrics() {
        #expect(FormatBarMetrics.glyphInset == (FormatBarMetrics.button - FormatBarMetrics.glyph) / 2)
        #expect(FormatBarMetrics.glyphInset > 0)
        #expect(!RecipientToken.showsRemove(hovered: false))
        #expect(RecipientToken.showsRemove(hovered: true))
    }
}
