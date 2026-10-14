import Foundation
import OpenHumanCore
import OpenHumanGmail
import Testing
@testable import OpenHumanSync

@Suite struct BlockIngestTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func message(_ id: String, from: String, labels: [String] = ["INBOX", "UNREAD"]) -> GmailMessage {
        GmailMessage(id: id, threadId: "t-\(id)", labelIds: labels,
                     payload: GmailMessagePart(headers: [GmailHeader(name: "from", value: from)]))
    }

    func rule(_ kind: BlockRule.Kind, _ value: String, _ disposition: BlockDisposition? = nil) -> BlockRule {
        BlockRule(kind: kind, value: value, disposition: disposition, createdAt: Self.now)!
    }

    @Test func archivesAndTrashesPerRuleAndDefault() {
        let rules = [rule(.sender, "news@acme.example"), rule(.domain, "spam.example", .trash)]
        let arrived = [
            message("1", from: "News <news@acme.example>"),
            message("2", from: "bob@mail.spam.example"),
            message("3", from: "friend@other.example"),
        ]
        let plan = BlockIngest.plan(arrived: arrived, rules: rules, defaultDisposition: .archive)
        #expect(plan.archive == [GmailMessageID("1")])
        #expect(plan.trash == [GmailMessageID("2")])
        let trashing = BlockIngest.plan(arrived: arrived, rules: rules, defaultDisposition: .trash)
        #expect(trashing.archive.isEmpty)
        #expect(trashing.trash == [GmailMessageID("1"), GmailMessageID("2")])
    }

    @Test func aRuleOverridesTheGlobalDefaultEitherWay() {
        let rules = [rule(.sender, "news@acme.example", .archive)]
        let plan = BlockIngest.plan(arrived: [message("1", from: "news@acme.example")], rules: rules,
                                    defaultDisposition: .trash)
        #expect(plan.archive == [GmailMessageID("1")])
    }

    @Test func neverTouchesSentDraftsOrMailAlreadyOutOfTheInbox() {
        let rules = [rule(.domain, "acme.example")]
        let arrived = [
            message("1", from: "me@acme.example", labels: ["SENT"]),
            message("2", from: "x@acme.example", labels: ["DRAFT"]),
            message("3", from: "x@acme.example", labels: ["TRASH"]),
            message("4", from: "x@acme.example", labels: ["SPAM"]),
            message("5", from: "x@acme.example", labels: ["CATEGORY_UPDATES"]),
            message("6", from: "x@acme.example", labels: ["INBOX", "SENT"]),
        ]
        #expect(BlockIngest.plan(arrived: arrived, rules: rules, defaultDisposition: .archive).isEmpty)
    }

    @Test func noRulesOrNoFromHeaderChangesNothing() {
        let noFrom = GmailMessage(id: "1", labelIds: ["INBOX"], payload: GmailMessagePart())
        #expect(BlockIngest.plan(arrived: [noFrom], rules: [rule(.domain, "acme.example")], defaultDisposition: .archive).isEmpty)
        #expect(BlockIngest.plan(arrived: [message("1", from: "x@acme.example")], rules: [], defaultDisposition: .archive).isEmpty)
    }

    @Test func theSchedulerOpShapesAreRecognised() {
        let inbox = GmailLabelID("INBOX"), unread = GmailLabelID("UNREAD"), trash = GmailLabelID("TRASH")
        #expect(BlockIngest.isBlockOp(add: [], remove: [inbox, unread]))
        #expect(BlockIngest.isBlockOp(add: [trash], remove: [inbox]))
        #expect(!BlockIngest.isBlockOp(add: [inbox], remove: []))
        #expect(!BlockIngest.isBlockOp(add: [], remove: [inbox]))
    }
}
