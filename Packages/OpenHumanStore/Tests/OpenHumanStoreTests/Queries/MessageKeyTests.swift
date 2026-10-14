import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct MessageKeyTests {
    @Test func aMessageRowAndAnAttachmentRowResolveToTheirGmailIDs() throws {
        let (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        let other = try store.addAccount(email: "other@example.com", displayName: nil, scopes: [])
        try store.upsertLabels(OpenHumanStoreTesting.systemLabels, account: other, removeMissing: false)
        _ = try store.upsertMessages([.fixture("m1", thread: "t1"), .fixture("m2", thread: "t1", minutes: 1)],
                                     account: account, generation: 1)
        _ = try store.upsertMessages([.fixture("m1", thread: "t9")], account: other, generation: 1)
        try store.storeBodies([(GmailMessageID("m2"), .fixture(), [
            AttachmentUpsert(partID: "2", filename: "a.pdf", mimeType: "application/pdf", size: 10, isInline: false),
            AttachmentUpsert(partID: "3", filename: "b.png", mimeType: "image/png", size: 10, contentID: "c1",
                             isInline: true)])],
            account: account)

        let thread = try #require(try store.thread(account: account, gmailThreadID: GmailThreadID("t1")))
        let m2 = try #require(try store.message(account: account, gmailMessageID: GmailMessageID("m2")))
        let key = try #require(try store.messageKey(m2.id))
        #expect(key.ref == thread && key.gmailMessageID == GmailMessageID("m2"))

        let elsewhere = try #require(try store.message(account: other, gmailMessageID: GmailMessageID("m1")))
        let otherKey = try #require(try store.messageKey(elsewhere.id))
        #expect(otherKey.ref.accountID == other && otherKey.ref.gmailThreadID == GmailThreadID("t9"))
        #expect(otherKey.gmailMessageID == GmailMessageID("m1"))

        for attachment in m2.attachments {
            let byAttachment = try #require(try store.attachmentKey(attachment.id))
            #expect(byAttachment.ref == thread && byAttachment.gmailMessageID == GmailMessageID("m2"))
        }
        #expect(m2.attachments.count == 2)

        #expect(try store.messageKey(MessageRowID(rawValue: 999_999)) == nil)
        #expect(try store.attachmentKey(999_999) == nil)
    }

    @Test func theLookupsAreIndexed() throws {
        let (store, _) = try OpenHumanStoreTesting.storeWithAccount()
        let found = try plans(store) { db in
            _ = try MailStore.messageKey(mid: 1, in: db)
            _ = try MailStore.attachmentKey(aid: 1, in: db)
        }
        #expect(found.count == 2)
        expectIndexed(found)
    }
}
