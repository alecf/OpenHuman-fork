import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct FlowedMappingTests {
    private func header(_ n: String, _ v: String) -> GmailHeader { GmailHeader(name: n, value: v) }

    private func textPart(_ text: String, contentType: String) -> GmailMessagePart {
        GmailMessagePart(partId: "", mimeType: "text/plain",
                         headers: [header("From", "me@example.com"), header("To", "bo@example.com"), header("Subject", "Plain"),
                                   header("Content-Type", contentType)],
                         body: GmailMessagePartBody(size: text.utf8.count, data: Base64URL.encode(Data(text.utf8))))
    }

    @Test func aFlowedBodyIsStoredAsSentWithItsFormat() throws {
        let parsed = try MIMEParser.parse(gmailPayload: textPart("A long sentence \r\nthat continues.\r\n> quoted \r\n> on",
                                                                 contentType: "text/plain; charset=UTF-8; format=flowed").mimePart)
        let (body, _) = GmailMapper.bodyUpsert(parsed)
        #expect(body.textFormat == .flowed)
        #expect(body.text == parsed.textBody, "the text is stored as sent; the reader joins it")
        #expect(body.searchText.contains("A long sentence that continues."), "search finds a phrase across a soft break")
        let delSp = try MIMEParser.parse(gmailPayload: textPart("x \r\ny", contentType: "text/plain; format=flowed; delsp=yes").mimePart)
        #expect(GmailMapper.bodyUpsert(delSp).0.textFormat == .flowedDelSp)
        let fixed = try MIMEParser.parse(gmailPayload: textPart("x \r\ny", contentType: "text/plain; charset=UTF-8").mimePart)
        #expect(GmailMapper.bodyUpsert(fixed).0.textFormat == .fixed)
    }

    @Test func aFlowedTextOnlyDraftComesBackAsPlainText() throws {
        let draft = GmailDraft(id: "r1", message: GmailMessage(
            id: "dm1", threadId: "t1", labelIds: ["DRAFT"], historyId: "1", internalDate: "1789900060000",
            payload: textPart("Hello there, this \r\nis one line.\r\n\r\n-- \r\nSam", contentType: "text/plain; format=flowed")))
        let upsert = try GmailMapper.remoteDraft(draft)
        #expect(upsert.content.bodyHTML.isEmpty, "plain text only: reopens in plain-text mode")
        #expect(upsert.content.bodyText == "Hello there, this is one line.\n\n-- \nSam")
    }

    @Test func aDraftWithoutHTMLIsSentFlowed() async throws {
        func outgoing(html: String, text: String?) async throws -> OutgoingMessage {
            let item = DraftListItem(
                id: DraftID("00000000-0000-4000-8000-000000000001"), accountID: AccountID(1), composeMode: .new,
                content: DraftContent(from: EmailAddress(email: "me@example.com"), to: [EmailAddress(email: "bo@example.com")],
                                      cc: [], bcc: [], subject: "Plain", bodyHTML: html, bodyText: text, attachments: []),
                origin: .user, reviewState: .none, state: .editing, isDirty: true, hasRemoteConflict: false,
                updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
            return try await DraftMessage.make(item, account: nil, date: Date(timeIntervalSince1970: 1_790_000_000),
                                               attachmentData: { _ in Data() }).outgoing
        }
        let plain = try await outgoing(html: "", text: "A plain message.")
        #expect(plain.htmlBody == nil && plain.textFormat == .flowed(delSp: false))
        let rich = try await outgoing(html: "<p>Rich</p>", text: "Rich")
        #expect(rich.htmlBody != nil && rich.textFormat == .fixed)
        let raw = String(decoding: try MIMEBuilder.build(plain, bcc: .strip), as: UTF8.self)
        #expect(raw.contains("format=flowed"))
    }

    @Test func aReplyQuotesAFlowedMessageByItsLogicalLines() {
        let body = MessageBody(messageRowID: MessageRowID(rawValue: 1), text: "Soft \nbreak here\n> old \n> quote",
                               hasRemoteContent: false, inlineParts: [:], decodeWarnings: [], textFormat: .flowed)
        #expect(DraftSkeleton.logicalText(body) == "Soft break here\n> old quote")
        var fixed = body
        fixed.textFormat = .fixed
        #expect(DraftSkeleton.logicalText(fixed) == "Soft \nbreak here\n> old \n> quote")
    }
}
