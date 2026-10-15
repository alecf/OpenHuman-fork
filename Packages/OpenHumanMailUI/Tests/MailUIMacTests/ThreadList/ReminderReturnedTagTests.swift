import AppKit
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
@Suite struct ReminderReturnedTagTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private var row: ThreadRow {
        ThreadRow(id: ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("r1")),
                  subject: "Budget follow-up", snippet: "An invented snippet", participantsDisplay: "Dana Ruiz",
                  participants: [], messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false,
                  isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: now, sortAt: now,
                  returnedByReminder: true)
    }

    private func attachments(_ line: NSAttributedString) -> [NSTextAttachment] {
        var result: [NSTextAttachment] = []
        line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length)) { value, _, _ in
            if let attachment = value as? NSTextAttachment { result.append(attachment) }
        }
        return result
    }

    @Test func chipsThatWouldStarveTheSubjectAreDroppedWholeFromTheEnd() throws {
        let style = ThreadRowStyle(theme: .light)
        let clients = ThreadRowChip(kind: .label, title: "Clients", color: "#fb4c2f")
        let line = style.texts(for: row, chips: [.reminderReturned, clients], format: ThreadRowFormatting(),
                               location: .system(.inbox)).line
        #expect(attachments(line).count == 2)
        #expect(style.fitted(line, width: 2_000) === line)
        let first = try #require(line.attribute(ThreadRowStyle.chipEnd, at: 0, effectiveRange: nil) as? CGFloat)
        let fits = style.minimumSubjectWidth + first + CGFloat(style.theme.space3)
        let one = style.fitted(line, width: fits)
        #expect(attachments(one).compactMap { $0.image?.size.width } == [first])
        #expect(one.string.contains("Budget follow-up"))
        let count = style.fitted(line, width: fits - 1)
        #expect(attachments(count).map { $0.image } == [style.chips.image("+2", hue: .neutral, muted: false).image],
                "both chips fold into a count once the tag no longer fits")
        #expect(count.string.contains("Budget follow-up"))
        let plus = style.chips.image("+2", hue: .neutral, muted: false).image.size.width
        let none = style.fitted(line, width: style.minimumSubjectWidth + plus + CGFloat(style.theme.space3) - 1)
        #expect(attachments(none).isEmpty)
        #expect(none.string.hasPrefix("Budget follow-up"))
    }

    @Test func droppedChipsLeaveACountInTheirPlaceWhenItFits() throws {
        let style = ThreadRowStyle(theme: .light)
        let chips = [ThreadRowChip.reminderReturned, ThreadRowChip(kind: .label, title: "Clients", color: "#fb4c2f"),
                     ThreadRowChip(kind: .category, title: "Updates")]
        let line = style.texts(for: row, chips: chips, format: ThreadRowFormatting(), location: .system(.inbox)).line
        func image(_ title: String) -> NSImage { style.chips.image(title, hue: .neutral, muted: false).image }
        let tag = try #require(line.attribute(ThreadRowStyle.chipEnd, at: 0, effectiveRange: nil) as? CGFloat)
        let gap = CGFloat(style.theme.space2), tail = CGFloat(style.theme.space3), minimum = style.minimumSubjectWidth
        let clients = style.chips.image("clients", hue: chips[1].hue, muted: false).image.size.width
        #expect(attachments(line).count == 3)
        #expect(clients > image("+2").size.width)

        let withCount = style.fitted(line, width: minimum + tag + gap + image("+2").size.width + tail)
        #expect(attachments(withCount).map { $0.image } == [image("Reminder returned"), image("+2")])
        #expect(withCount.string.contains("Budget follow-up"))
        let tagOnly = style.fitted(line, width: minimum + tag + gap + image("+2").size.width + tail - 1)
        #expect(attachments(tagOnly).map { $0.image } == [image("Reminder returned")], "no room for the count: dropped as before")
        let countOnly = style.fitted(line, width: minimum + image("+3").size.width + tail)
        #expect(attachments(countOnly).map { $0.image } == [image("+3")], "the tag is never clipped, it is counted")
        #expect(countOnly.string.contains("Budget follow-up"))
        let bare = style.fitted(line, width: minimum + image("+3").size.width + tail - 1)
        #expect(attachments(bare).isEmpty)
        #expect(bare.string.hasPrefix("Budget follow-up"))
        #expect(LabelChipRenderer.shown(chips, maximum: ThreadRowStyle.maximumFilledChips).map(\.title)
            == ["Reminder returned", "clients", "+1"])
    }

    @Test func theHoverRowFitsItsChipsToTheLineItDraws() throws {
        let style = ThreadRowStyle(theme: .light)
        let texts = style.texts(for: row, chips: [.reminderReturned], format: ThreadRowFormatting(), location: .system(.inbox))
        let tag = try #require(texts.line.attribute(ThreadRowStyle.chipEnd, at: 0, effectiveRange: nil) as? CGFloat)
        let needed = style.minimumSubjectWidth + tag + CGFloat(style.theme.space3)
        let width = try #require((400...1200).map { CGFloat($0) }.first { w in
            let c = style.columns(width: w)
            return c.subject.upperBound - c.subject.lowerBound >= needed
        })
        let rowView = ThreadRowBackgroundView(style: style)
        rowView.frame = NSRect(x: 0, y: 0, width: width, height: style.rowHeight)
        let cell = ThreadRowView(style: style)
        cell.frame = rowView.bounds
        cell.hoverActions = { RowActionsOverlapTests.actions }
        rowView.addSubview(cell)
        cell.configure(row, texts: texts, date: style.date("OCT 8", unread: false, upcoming: false), indicators: [],
                       isChecked: false)
        #expect(cell.drawnLine(cell.drawnFrames()) === texts.line, "the tag fits the resting row")

        cell.setHovering(true)
        cell.layoutSubtreeIfNeeded()
        let frames = cell.drawnFrames()
        let line = try #require(frames.line)
        #expect(line.width < needed, "five buttons narrow the drawn line")
        let drawn = try #require(cell.drawnLine(frames))
        let plus = style.chips.image("+1", hue: .neutral, muted: false).image
        let countFits = line.width - style.minimumSubjectWidth >= plus.size.width + CGFloat(style.theme.space3)
        let expected: [NSImage?] = countFits ? [plus] : []
        #expect(attachments(drawn).map { $0.image } == expected, "the tag gives way to a count on the narrower line")
        #expect(drawn.string.contains("Budget follow-up"))
        cell.setHovering(false)
        #expect(cell.drawnLine(cell.drawnFrames()) === texts.line)
    }

    @Test func theSenderYieldsSoTheSubjectKeepsItsFloorAtTheNarrowestList() {
        let light = ThemeTokens.light
        let narrowest = CGFloat(light.component.window.minWidth - light.component.labelSidebar.width - light.component.sidebar.width)
        #expect(narrowest == 440)
        for themeID in RowActionsOverlapTests.themeIDs {
            for density in [ThemeDensity.compact, .default] {
                let style = ThreadRowStyle(theme: RowActionsOverlapTests.tokens(themeID, density: density))
                for width in [narrowest, 420] {
                    let c = style.columns(width: width)
                    let subject = c.subject.upperBound - c.subject.lowerBound
                    let sender = c.sender.upperBound - c.sender.lowerBound
                    #expect(subject >= style.minimumSubjectWidth, "\(themeID) \(density) \(width): subject \(subject)")
                    #expect(sender >= ThreadRowStyle.narrowSenderMin && sender < style.metrics.senderMin, "\(themeID) \(density)")
                }
            }
        }
        let style = ThreadRowStyle(theme: light)
        func senderAndSubject(_ width: CGFloat) -> [CGFloat] {
            let c = style.columns(width: width)
            return [c.sender.upperBound - c.sender.lowerBound, c.subject.upperBound - c.subject.lowerBound]
        }
        #expect(senderAndSubject(440) == [128, 104])
        #expect(senderAndSubject(420) == [108, 104])
        #expect(senderAndSubject(400) == [100, 92], "the sender stops at its floor")
        #expect(senderAndSubject(472) == [160, 104])
        #expect(senderAndSubject(620) == [160, 252], "a list with room keeps the design columns")
        #expect(senderAndSubject(1000) == [220, 572])
        let comfortable = ThreadRowStyle(theme: RowActionsOverlapTests.tokens(BuiltinThemeID.light, density: .comfortable))
        let roomy = comfortable.columns(width: 620)
        #expect(roomy.subject.upperBound - roomy.subject.lowerBound >= comfortable.minimumSubjectWidth)
        let tight = comfortable.columns(width: narrowest)
        #expect(tight.sender.upperBound - tight.sender.lowerBound == ThreadRowStyle.narrowSenderMin)
    }

    @Test func aNarrowRowShowsTheSubjectRatherThanAnEllipsis() {
        let style = ThreadRowStyle(theme: .light)
        let texts = style.texts(for: row, chips: [.reminderReturned], format: ThreadRowFormatting(),
                                location: .system(.inbox))
        let cell = ThreadRowView(style: style)
        cell.frame = NSRect(x: 0, y: 0, width: 420, height: style.rowHeight)
        cell.configure(row, texts: texts, date: style.date("OCT 8", unread: false, upcoming: false), indicators: [],
                       isChecked: false)
        func subjectWidth(_ width: CGFloat) -> CGFloat {
            let c = style.columns(width: width)
            return c.subject.upperBound - c.subject.lowerBound
        }
        let narrow = cell.fittedLine(width: subjectWidth(420))
        #expect(attachments(narrow).isEmpty)
        #expect(narrow.string.hasPrefix("Budget follow-up"))
        #expect(cell.fittedLine(width: subjectWidth(1000)) === texts.line)
    }

    @Test func theFilledChipKeepsItsExactWordingWhileOtherChipsAreLowercased() {
        let chips = [ThreadRowChip.reminderReturned, ThreadRowChip(kind: .vip, title: "VIP"),
                     ThreadRowChip(kind: .label, title: "Clients", color: "#fb4c2f")]
        let shown = LabelChipRenderer.shown(chips, maximum: ThreadRowStyle.maximumFilledChips)
        #expect(shown.map(\.title) == ["Reminder returned", "vip", "+1"])
        #expect(shown.first?.hue == .neutral && shown.first?.muted == false)
        #expect(LabelChipRenderer.shown([ThreadRowChip(kind: .important, title: "Important")], maximum: 2).map(\.title)
            == ["important"])
    }

    @Test func theReaderMetaLineUsesTheListRowWhenThereIsOne() {
        let chips = ReaderViewController.metaChips(listChips: [.reminderReturned, ThreadRowChip(kind: .label, title: "Clients")],
                                                   returnedByReminder: false)
        let line = NSMutableAttributedString(string: "2 messages")
        ReaderViewController.appendMetaChips(chips, to: line, theme: .light)
        #expect(ReaderViewController.metaAccessibilityLabel(line) == "2 messages   Reminder returned   Clients")
        #expect(ReaderViewController.metaChips(listChips: [], returnedByReminder: true).isEmpty)
    }

    @Test func theReaderMetaLineFallsBackToTheConversation() {
        let line = NSMutableAttributedString(string: "2 messages")
        ReaderViewController.appendMetaChips(ReaderViewController.metaChips(listChips: nil, returnedByReminder: true),
                                             to: line, theme: .dark)
        #expect(ReaderViewController.metaAccessibilityLabel(line) == "2 messages   Reminder returned")
        #expect(ReaderViewController.metaChips(listChips: nil, returnedByReminder: false).isEmpty)
    }
}
