import AppKit
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
struct FlatCollapsedRowTests {
    private func olderRow(_ theme: ThemeTokens, width: CGFloat = 700) -> OlderMessagesPillView {
        let row = OlderMessagesPillView(count: 9, theme: theme)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func collapsedRow(_ theme: ThemeTokens, width: CGFloat = 700, unread: Bool = false) -> CollapsedMessageView {
        let fixed = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let summary = MessageSummary(id: UIFixtures.message(1), from: UIFixtures.dana, to: [UIFixtures.me], cc: [], bcc: [],
                                     date: fixed.addingTimeInterval(-3600), snippet: "Works for me, see you then",
                                     isUnread: unread, attachments: [])
        let row = CollapsedMessageView(summary: summary, theme: theme, format: ThreadRowFormatting(), now: fixed)
        row.widthAnchor.constraint(equalToConstant: width).isActive = true
        row.layoutSubtreeIfNeeded()
        return row
    }

    @Test func theCardIsRaisedWhenOpenHoveredFocusedOrHoldingAReply() {
        var flat: [[Bool]] = []
        for expanded in [false, true] {
            for hovering in [false, true] {
                for focused in [false, true] {
                    for composer in [false, true] {
                        let look = MessageCardView.appearance(expanded: expanded, hovering: hovering, focused: focused,
                                                              hasComposer: composer)
                        if look == .flat { flat.append([expanded, hovering, focused, composer]) }
                    }
                }
            }
        }
        #expect(flat == [[false, false, false, false]])
    }

    @Test func aCollapsedRowHasMoreAirAndTheOlderRowItsHeight() {
        for density in ThemeDensity.allCases {
            var theme = ThemeTokens.light
            theme.density = density
            let expected = CGFloat(theme.collapsedMessageRow + theme.space2)
            #expect(collapsedRow(theme).fittingSize.height == expected, "\(density): 40 / 44 / 48")
            #expect(olderRow(theme).fittingSize.height == expected, "\(density): the older-messages row too")
        }
    }

    @Test func theSnippetStartsAfterTheSenderColumn() throws {
        let theme = ThemeTokens.light
        for unread in [false, true] {
            let row = collapsedRow(theme, unread: unread)
            let snippet = row.snippetLabel.alignmentRect(forFrame: row.snippetLabel.frame)
            #expect(abs(snippet.minX - CGFloat(theme.component.row.senderMin + theme.space5)) < 0.5, "was \(snippet.minX)")
            let name = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Dana Ruiz" })
            let nameFrame = name.alignmentRect(forFrame: name.frame)
            #expect(abs(nameFrame.minX) < 0.5, "the sender at the content edge, was \(nameFrame.minX)")
            #expect(nameFrame.width <= CGFloat(theme.component.row.senderMin) + 0.5, "inside its column")
            let font = name.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            #expect(font?.fontName == theme.typeBodyStrong.font.fontName, "the sender is semibold, read or not")
        }
    }

    @Test func theOlderMessagesLabelSitsInTheSenderColumn() throws {
        for density in ThemeDensity.allCases {
            var theme = ThemeTokens.light
            theme.density = density
            let row = olderRow(theme)
            let label = try #require(row.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "9 older messages" })
            let frame = label.alignmentRect(forFrame: label.frame)
            #expect(abs(frame.minX - MessageContainerView.horizontalPadding(theme)) < 0.5,
                    "\(density): the label starts where the senders do, was \(frame.minX)")
            #expect(abs(frame.midY - row.bounds.midY) < 1, "\(density): centred vertically in the row")
        }
    }

    @Test func theOlderMessagesRowLiftsUnderThePointer() throws {
        let row = olderRow(.light)
        let frame = row.frame
        #expect(row.cardAppearance == .flat)
        let enter = try #require(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                        windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                                                        userData: nil))
        row.mouseEntered(with: enter)
        #expect(row.cardAppearance == .raised)
        row.layoutSubtreeIfNeeded()
        #expect(row.frame == frame, "raising never changes a frame")
        row.mouseExited(with: enter)
        #expect(row.cardAppearance == .flat)
    }
}
