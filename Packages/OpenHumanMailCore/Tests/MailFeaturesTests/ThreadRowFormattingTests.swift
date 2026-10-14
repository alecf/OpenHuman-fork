import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}
private let format = ThreadRowFormatting(calendar: utc, locale: Locale(identifier: "en_US"))
private let now = Date(timeIntervalSince1970: 1_791_640_800)

@Test func listDateFormats() {
    #expect(format.listDate(now.addingTimeInterval(-3_600), now: now) == "1:00\u{202F}PM")
    #expect(format.listDate(now.addingTimeInterval(-3 * 86_400), now: now) == "OCT 7")
    #expect(format.listDate(now.addingTimeInterval(-40 * 86_400), now: now) == "AUG 31")
    #expect(format.listDate(now.addingTimeInterval(-400 * 86_400), now: now) == "SEP 5, 2025")
    #expect(format.spokenListDate(now.addingTimeInterval(-3 * 86_400), now: now) == "Oct 7")
}

@Test func listDateUppercasesLatinScriptOnly() {
    #expect(ThreadRowFormatting.isLatinScript("Oct 7"))
    #expect(ThreadRowFormatting.isLatinScript("7 déc. 2025"))
    #expect(!ThreadRowFormatting.isLatinScript("7 окт."))
    #expect(!ThreadRowFormatting.isLatinScript("10月7日"))
    let russian = ThreadRowFormatting(calendar: utc, locale: Locale(identifier: "ru_RU"))
    let date = now.addingTimeInterval(-3 * 86_400)
    #expect(russian.listDate(date, now: now) == russian.spokenListDate(date, now: now))
}

@Test func headerDateFormats() {
    #expect(format.headerDate(now.addingTimeInterval(-2 * 3_600), now: now) == "12:00\u{202F}PM (2 h ago)")
    #expect(format.headerDate(now.addingTimeInterval(-3 * 86_400), now: now) == "Oct 7, 2:00\u{202F}PM")
}

@Test func senderCountAndAccessibility() {
    let key = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t"))
    let row = ThreadRow(id: key, subject: "  ", snippet: "s", participantsDisplay: "Dana, Sam, me", participants: [],
                        messageCount: 3, unreadCount: 1, draftCount: 0, attachmentCount: 1, isUnread: true,
                        isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: now, sortAt: now)
    #expect(format.sender(row) == ("Dana, Sam, me", "(3)"))
    let stored = ThreadRow(id: key, subject: "s", snippet: "s", participantsDisplay: "Dana, Sam, me (3)", participants: [],
                           messageCount: 3, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false,
                           isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: now, sortAt: now)
    #expect(format.sender(stored) == ("Dana, Sam, me", "(3)"))
    for text in ["Bob, Alice (3)", "To: Bob (3)", "Dee, Cy, Bo +2 (3)"] {
        let r = ThreadRow(id: key, subject: "s", snippet: "s", participantsDisplay: text, participants: [],
                          messageCount: 3, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false,
                          isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: now, sortAt: now)
        #expect(format.sender(r) == (String(text.dropLast(4)), "(3)"))
    }
    #expect(format.subject(row) == nil)
    #expect(format.accessibilityLabel(row, now: now) == "Unread, Dana, Sam, me, No subject, 2:00\u{202F}PM, has attachment")
}

@Test func recipientsAndInitials() {
    let m = MessageSummary(id: MessageKey(account: AccountID(1), rowID: 1, gmailMessageID: GmailMessageID("m")),
                           from: nil, to: [EmailAddress(name: "Robin Example", email: "robin@example.com")],
                           cc: [EmailAddress(name: "Sam Lee", email: "sam@example.org")], bcc: [], date: now,
                           snippet: "", isUnread: false, attachments: [])
    #expect(format.recipientsLine(m, me: "ROBIN@example.com") == "to me, Sam")
    #expect(format.initials(name: "Dana Ruiz", email: "dana@example.com") == "DR")
    #expect(format.initials(name: nil, email: "billing@shop.example") == "BS")
}
