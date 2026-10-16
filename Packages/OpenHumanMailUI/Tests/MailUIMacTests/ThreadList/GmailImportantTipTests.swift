import AppKit
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
@Suite struct GmailImportantTipTests {
    static let now = Date(timeIntervalSince1970: 1_791_000_000)
    static let reason = "In Other: never important from nia@letters.example; Gmail marks it important"

    static func cell(chips: [ThreadRowChip]) -> ThreadRowView {
        let style = ThreadRowStyle(theme: .light)
        let row = ThreadRow(id: ThreadKey(account: AccountID(1), rowID: 9, gmailThreadID: GmailThreadID("t9")),
                            subject: "Weekly digest", snippet: "This week in letters", participantsDisplay: "Nia Letters",
                            participants: [], messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0,
                            isUnread: false, isStarred: false, isImportant: true, userLabelIDs: [], lastMessageAt: now,
                            sortAt: now)
        let texts = style.texts(for: row, chips: chips, format: ThreadRowFormatting(), location: .splitOther)
        let cell = ThreadRowView(style: style)
        cell.frame = NSRect(x: 0, y: 0, width: 900, height: style.rowHeight)
        cell.importanceTip = { reason }
        cell.configure(row, texts: texts, date: style.date("1:33 PM", unread: false, upcoming: false), indicators: [],
                       isChecked: false)
        return cell
    }

    @Test func theGmailImportantChipGivesItsReasonOnHover() throws {
        let gmail = ThreadRowChip(kind: .gmailImportant, title: ThreadRowFormatting.gmailImportantTitle)
        let cell = Self.cell(chips: [gmail, ThreadRowChip(kind: .category, title: "Social")])
        var visits = 0
        cell.onPointerEnter = { visits += 1 }
        let line = try #require(cell.drawnFrames().line)
        let rect = try #require(cell.importanceTipRect())
        #expect(rect.minX >= line.minX && rect.width > 20 && rect.maxX < line.minX + line.width / 2,
                "only over the chip: \(rect) in \(line)")
        #expect(cell.view(cell, stringForToolTip: 0, point: NSPoint(x: rect.midX, y: rect.midY), userData: nil) == Self.reason)
        cell.setHovering(true)
        cell.setHovering(true)
        #expect(visits == 1, "one look-up per visit")
        cell.prepareForReuse()
        #expect(cell.importanceTipRect() == nil)
    }

    @Test func otherChipsHaveNoTooltip() {
        let cell = Self.cell(chips: [ThreadRowChip(kind: .important, title: "Important"),
                                     ThreadRowChip(kind: .category, title: "Social")])
        #expect(cell.importanceTipRect() == nil)
    }
}
