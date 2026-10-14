import AppKit
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailUIMac

@MainActor
struct RelatedMarkerTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func row(_ match: SearchMatchKind?) -> ThreadRow {
        ThreadRow(id: ThreadKey(account: AccountID(1), rowID: 7, gmailThreadID: GmailThreadID("t7")),
                  subject: "Offsite planning", snippet: "Agenda attached", participantsDisplay: "Dana", participants: [],
                  messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false, isStarred: false,
                  isImportant: false, userLabelIDs: [], lastMessageAt: now, sortAt: now, searchMatch: match)
    }

    private func attachments(_ line: NSAttributedString) -> [NSColor?] {
        var found: [NSColor?] = []
        line.enumerateAttribute(.attachment, in: NSRange(location: 0, length: line.length)) { value, range, _ in
            guard value is NSTextAttachment else { return }
            found.append(line.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor)
        }
        return found
    }

    @Test func onlyRelatedRowsCarryTheSparkle() {
        for theme in [ThemeTokens.light, ThemeTokens.dark] {
            let style = ThreadRowStyle(theme: theme)
            let format = ThreadRowFormatting()
            let location = MailLocation.search("retreat")
            let plain = style.texts(for: row(nil), chips: [], format: format, location: location).line
            let lexical = style.texts(for: row(.lexical), chips: [], format: format, location: location).line
            let related = style.texts(for: row(.related), chips: [], format: format, location: location).line
            #expect(attachments(plain).isEmpty)
            #expect(lexical.string == plain.string && attachments(lexical).isEmpty, "a word match draws as before")
            let marks = attachments(related)
            #expect(marks.count == 1)
            #expect(marks.first??.isEqual(theme.textAI.nsColor) == true, "the sparkle takes the theme's `text.ai`")
            #expect(related.string.hasSuffix("Agenda attached"), "the snippet follows the sparkle, unmarked")
        }
    }
}
