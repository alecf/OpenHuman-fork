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
        let none = style.fitted(line, width: fits - 1)
        #expect(attachments(none).isEmpty)
        #expect(none.string.hasPrefix("Budget follow-up"))
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
