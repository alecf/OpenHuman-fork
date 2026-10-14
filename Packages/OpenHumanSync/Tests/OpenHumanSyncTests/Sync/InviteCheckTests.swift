import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanMIME
import OpenHumanStore
import Testing
@testable import OpenHumanSync

enum GoogleInviteFixture {
    static let ics = "BEGIN:VCALENDAR\r\nPRODID:-//Example//Fixture//EN\r\nVERSION:2.0\r\nMETHOD:REQUEST\r\n"
        + "BEGIN:VEVENT\r\nUID:fixture-1@example.com\r\nSUMMARY:Design review\r\nDTSTART:20261019T100000Z\r\n"
        + "DTEND:20261019T110000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
    static let subject = "Invitation: Design review @ Mon Oct 19, 2026 10am - 11am (UTC) (me@example.com)"
    static let googleFrom = "Sam Rivera (via Google Calendar) <calendar-notification@google.com>"

    private static func h(_ n: String, _ v: String) -> GmailHeader { GmailHeader(name: n, value: v) }

    private static func text(_ id: String, _ type: String, _ content: String, extra: String = "") -> GmailMessagePart {
        GmailMessagePart(partId: id, mimeType: type, filename: "",
                         headers: [h("Content-Type", "\(type); charset=\"UTF-8\"\(extra)")],
                         body: GmailMessagePartBody(size: content.utf8.count, data: Base64URL.encode(Data(content.utf8))))
    }

    static func payload(from: String = googleFrom, subject: String = subject, messageID: String = "<fixture-1@example.com>",
                        method: String = "REQUEST", calendarInline: Bool = true, withCalendarAlternative: Bool = true,
                        withICSAttachment: Bool = true) -> GmailMessagePart {
        var alternatives = [text("0.0", "text/plain", "Design review. Join with the link in the event."),
                            text("0.1", "text/html", "<p>Design review</p><p>Going? Yes - Maybe - No</p>")]
        if withCalendarAlternative {
            let type = "text/calendar"
            alternatives.append(GmailMessagePart(
                partId: "0.2", mimeType: type, filename: "",
                headers: [h("Content-Type", "\(type); charset=\"UTF-8\"; method=\(method)"),
                          h("Content-Transfer-Encoding", "7bit")],
                body: calendarInline
                    ? GmailMessagePartBody(size: ics.utf8.count, data: Base64URL.encode(Data(ics.utf8)))
                    : GmailMessagePartBody(attachmentId: "ANGjdJ-cal", size: ics.utf8.count)))
        }
        var parts = [GmailMessagePart(partId: "0", mimeType: "multipart/alternative", filename: "",
                                      headers: [h("Content-Type", "multipart/alternative; boundary=\"alt\"")],
                                      body: GmailMessagePartBody(size: 0), parts: alternatives)]
        if withICSAttachment {
            parts.append(GmailMessagePart(
                partId: "1", mimeType: "application/ics", filename: "invite.ics",
                headers: [h("Content-Type", "application/ics; name=\"invite.ics\""),
                          h("Content-Disposition", "attachment; filename=\"invite.ics\""),
                          h("Content-Transfer-Encoding", "base64")],
                body: GmailMessagePartBody(attachmentId: "ANGjdJ-ics", size: ics.utf8.count)))
        }
        return GmailMessagePart(
            partId: "", mimeType: "multipart/mixed", filename: "",
            headers: [h("From", from), h("To", "me@example.com"), h("Subject", subject),
                      h("Date", "Mon, 12 Oct 2026 09:00:00 +0000"), h("Message-ID", messageID), h("MIME-Version", "1.0"),
                      h("Content-Type", "multipart/mixed; boundary=\"mixed\"")],
            body: GmailMessagePartBody(size: 0), parts: parts)
    }

    static func message(_ payload: GmailMessagePart) -> GmailMessage {
        GmailMessage(id: "m1", threadId: "t1", labelIds: ["INBOX", "UNREAD"], snippet: "Design review", historyId: "1200",
                     internalDate: "1789900060000", sizeEstimate: 4000, payload: payload)
    }
}

@Suite struct CalendarPartFlagTests {
    private func flag(_ payload: GmailMessagePart) throws -> Bool? {
        try GmailMapper.messageUpsert(GoogleInviteFixture.message(payload), includeBody: true).body?.hasCalendarInvite
    }

    @Test func everyCalendarPartShapeSetsTheFlag() throws {
        #expect(try flag(GoogleInviteFixture.payload()) == true, "the whole Google shape")
        #expect(try flag(GoogleInviteFixture.payload(calendarInline: false, withICSAttachment: false)) == true,
                "text/calendar served by attachment id only (before: false)")
        #expect(try flag(GoogleInviteFixture.payload(withCalendarAlternative: false)) == true,
                "only the application/ics invite.ics attachment (before: false)")
        #expect(try flag(GoogleInviteFixture.payload(method: "CANCEL")) == true)
        #expect(try flag(GoogleInviteFixture.payload(method: "REPLY")) == true)
    }

    @Test func aTextCalendarFileWithADispositionSetsTheFlag() throws {
        let part = GmailMessagePart(partId: "1", mimeType: "text/calendar", filename: "meeting.ics",
                                    headers: [GmailHeader(name: "Content-Disposition", value: "attachment; filename=meeting.ics")],
                                    body: GmailMessagePartBody(attachmentId: "A", size: 300))
        let root = GmailMessagePart(partId: "", mimeType: "multipart/mixed", filename: "",
                                    headers: [GmailHeader(name: "From", value: "lee@example.net")],
                                    body: GmailMessagePartBody(size: 0),
                                    parts: [GmailMessagePart(partId: "0", mimeType: "text/plain", filename: "",
                                                             body: GmailMessagePartBody(size: 2, data: Base64URL.encode(Data("Hi".utf8)))),
                                            part])
        #expect(try flag(root) == true)
    }

    @Test func ordinaryAttachmentsAndMetadataDoNotSetTheFlag() throws {
        let root = GmailMessagePart(partId: "", mimeType: "multipart/mixed", filename: "",
                                    headers: [GmailHeader(name: "From", value: "lee@example.net")],
                                    body: GmailMessagePartBody(size: 0),
                                    parts: [GmailMessagePart(partId: "0", mimeType: "text/plain", filename: "",
                                                             body: GmailMessagePartBody(size: 2, data: Base64URL.encode(Data("Hi".utf8)))),
                                            GmailMessagePart(partId: "1", mimeType: "application/pdf", filename: "agenda.pdf",
                                                             body: GmailMessagePartBody(attachmentId: "A", size: 300))])
        #expect(try flag(root) == false)
        let metadata = try GmailMapper.messageUpsert(GoogleInviteFixture.message(GoogleInviteFixture.payload()),
                                                     includeBody: false)
        #expect(metadata.body == nil)
    }
}

@Suite struct InviteCheckTests {
    private func harness(cap: Int = 20) throws -> SyncHarness {
        try SyncHarness(settings: SyncSettings(prefetchFullBodies: 0, inviteChecksPerRun: cap))
    }

    private func getMessageCalls(_ h: SyncHarness) async -> Int {
        await h.gmail.callLog.filter { $0 == .getMessage }.count
    }

    @Test func aMetadataOnlyGoogleInvitationGetsItsFlagAndStaysInTheCalendarTab() async throws {
        let h = try harness()
        let calendar = try #require(try h.store.splits(account: h.account).first { $0.name == "Calendar" })
        _ = try h.store.upsertSplit(account: h.account, id: calendar.id, name: "Calendar", ruleText: "has:invite",
                                    position: nil, enabled: true)
        let (invite, thread) = await h.gmail.deliver(payload: GoogleInviteFixture.payload(), snippet: "Design review")
        let (plain, _) = await h.gmail.deliver(subject: "Quarterly numbers")
        try await h.syncer.sync(reason: "launch")

        let message = try #require(try h.message(invite))
        #expect(message.bodyState == .stored && message.hasCalendarInvite)
        #expect(try h.message(plain)?.bodyState == .metadataOnly, "ordinary mail is not fetched")
        #expect(await getMessageCalls(h) == 1, "one GET, for the invitation only")
        #expect(try h.store.splits(account: h.account).first { $0.name == "Calendar" }?.totalThreads == 1,
                "has:invite matches once the flag is set")

        await h.gmail.resetAccounting()
        await h.gmail.modifyLabels(messageID: invite, add: ["IMPORTANT"])
        try await h.syncer.sync(reason: "poll")
        #expect(await getMessageCalls(h) == 0)
        #expect(try h.message(invite)?.hasCalendarInvite == true)
        let after = try h.store.splits(account: h.account)
        #expect(after.first { $0.name == "Calendar" }?.totalThreads == 1, "an important invite is still listed")
        #expect(after.first { $0.name == "Important" }?.totalThreads == 1, "and stays in Important")
        #expect(try h.thread(thread) != nil)
    }

    @Test func theFlagSurvivesAFullResync() async throws {
        let h = try harness()
        let (invite, _) = await h.gmail.deliver(payload: GoogleInviteFixture.payload())
        try await h.syncer.sync(reason: "launch")
        #expect(try h.message(invite)?.hasCalendarInvite == true)
        try h.store.updateSyncState(account: h.account) { $0.phase = .resyncRequired }
        await h.gmail.resetAccounting()
        try await h.syncer.sync(reason: "resync")
        #expect(try h.message(invite)?.hasCalendarInvite == true)
        #expect(await getMessageCalls(h) == 0, "nothing to check again")
    }

    @Test func anInvitationSubjectFromAnyoneIsChecked() async throws {
        let h = try harness()
        let (invite, _) = await h.gmail.deliver(payload: GoogleInviteFixture.payload(
            from: "Lee Park <lee@example.net>", subject: "Fwd: Invitation: Offsite planning", messageID: "<fw-1@example.net>"))
        try await h.syncer.sync(reason: "launch")
        #expect(try h.message(invite)?.hasCalendarInvite == true)
    }

    @Test func theCheckIsCappedPerRun() async throws {
        let h = try harness(cap: 2)
        var ids: [String] = []
        for n in 0..<5 {
            ids.append(await h.gmail.deliver(payload: GoogleInviteFixture.payload(messageID: "<inv-\(n)@example.com>")).messageID)
        }
        try await h.syncer.sync(reason: "launch")
        #expect(await getMessageCalls(h) == 2)
        #expect(try ids.filter { try h.message($0)?.hasCalendarInvite == true }.count == 2)
        await h.gmail.resetAccounting()
        try await h.syncer.sync(reason: "poll")
        #expect(await getMessageCalls(h) == 2)
        await h.gmail.resetAccounting()
        try await h.syncer.sync(reason: "poll")
        #expect(await getMessageCalls(h) == 1)
        #expect(try ids.allSatisfy { try h.message($0)?.hasCalendarInvite == true })
        await h.gmail.resetAccounting()
        try await h.syncer.sync(reason: "poll")
        #expect(await getMessageCalls(h) == 0, "done: no more GETs")
    }

    @Test func aZeroCapMakesNoRequest() async throws {
        let h = try harness(cap: 0)
        let (invite, _) = await h.gmail.deliver(payload: GoogleInviteFixture.payload())
        try await h.syncer.sync(reason: "launch")
        #expect(await getMessageCalls(h) == 0)
        #expect(try h.message(invite)?.bodyState == .metadataOnly)
        #expect(try h.store.splits(account: h.account).first { $0.name == "Calendar" }?.totalThreads == 1)
    }
}
