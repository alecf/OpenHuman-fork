import AppKit
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
struct FollowUpReasonRowTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private var row: ThreadRow {
        ThreadRow(id: ThreadKey(account: AccountID(1), rowID: 9, gmailThreadID: GmailThreadID("t9")),
                  subject: "Budget", snippet: "Could you send the numbers", participantsDisplay: "me", participants: [],
                  messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false, isStarred: false,
                  isImportant: false, userLabelIDs: [], lastMessageAt: now, sortAt: now,
                  reminderAt: now.addingTimeInterval(86_400))
    }

    private func attachmentCount(_ line: NSAttributedString) -> Int {
        var count = 0
        line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length)) { value, _, _ in
            if value is NSTextAttachment { count += 1 }
        }
        return count
    }

    @Test func theReasonReplacesTheSnippetAfterTheSparkle() {
        let style = ThreadRowStyle(theme: .light)
        let format = ThreadRowFormatting()
        let location = MailLocation.system(.reminders)
        let plain = style.texts(for: row, chips: [], format: format, location: location).line
        #expect(plain.string.hasSuffix("Could you send the numbers") && attachmentCount(plain) == 0)
        let reasoned = style.texts(for: row, chips: [], format: format, location: location,
                                   followUpReason: "Asked for the budget numbers").line
        #expect(reasoned.string.hasSuffix("Asked for the budget numbers"))
        #expect(!reasoned.string.contains("Could you send the numbers"))
        #expect(attachmentCount(reasoned) == 1, "the AI sparkle")
        let again = style.texts(for: row, chips: [], format: format, location: location).line
        #expect(again.string == plain.string, "no reason, no cached reason line")
    }
}
