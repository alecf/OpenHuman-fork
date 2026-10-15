import Foundation
import OpenHumanCore
import OpenHumanStoreTesting
import Testing
@testable import OpenHumanStore

@Suite struct BlockSearchTests {
    let store: MailStore
    let account: AccountID

    init() throws {
        (store, account) = try OpenHumanStoreTesting.storeWithAccount()
        func mail(_ id: String, _ minutes: Int, from: String, labels: [String] = ["INBOX", "UNREAD"],
                  to: [String] = ["me@example.com"]) -> MessageUpsert {
            MessageUpsert.fixture(id, minutes: minutes, labels: labels, from: from, fromName: nil, to: to,
                                  subject: "Synthetic \(id)", snippet: "synthetic", body: .fixture(html: nil, text: "Synthetic body"))
        }
        var cc = mail("sentCc", 6, from: "me@example.com", labels: ["SENT"], to: ["friend@other.example"])
        cc.headers?.cc = [EmailAddress(name: nil, email: "carol@team.acme.example")]
        var bcc = mail("sentBcc", 7, from: "me@example.com", labels: ["SENT"], to: ["someone@other.example"])
        bcc.headers?.bcc = [EmailAddress(name: nil, email: "dave@hidden.example")]
        _ = try store.upsertMessages([
            mail("news", 0, from: "news@acme.example"),
            mail("sub", 1, from: "alerts@mail.acme.example"),
            mail("look", 2, from: "promo@acme.example.net"),
            mail("plus", 3, from: "news+offers@acme.example"),
            mail("filed", 4, from: "old@acme.example", labels: []),
            mail("sentTo", 5, from: "me@example.com", labels: ["SENT"], to: ["bob@acme.example"]),
            cc, bcc,
        ], account: account, generation: 1)
    }

    func threads(_ query: String?) throws -> Set<String> {
        let text = try #require(query)
        return Set(try store.search(try store.parseSearch(text), accounts: [account], after: nil, limit: 50).hits
            .map { $0.thread.ref.gmailThreadID.rawValue })
    }

    @Test func theWrittenToGuardFindsSentMailByToCcAndBcc() throws {
        #expect(try threads(BlockMatcher.sentToQuery(kind: .sender, value: "bob@acme.example")) == ["t-sentTo"])
        #expect(try threads(BlockMatcher.sentToQuery(kind: .sender, value: "carol@team.acme.example")) == ["t-sentCc"],
                "a Cc'd recipient counts as written to")
        #expect(try threads(BlockMatcher.sentToQuery(kind: .sender, value: "dave@hidden.example")) == ["t-sentBcc"],
                "Bcc is stored on our own sent mail")
        #expect(try threads(BlockMatcher.sentToQuery(kind: .sender, value: "news@acme.example")).isEmpty,
                "mail received from them is not mail sent to them")
    }

    @Test func theWrittenToGuardForADomainCoversItsSubdomains() throws {
        #expect(try threads(BlockMatcher.sentToQuery(kind: .domain, value: "acme.example")) == ["t-sentTo", "t-sentCc"])
        #expect(try threads(BlockMatcher.sentToQuery(kind: .domain, value: "nobody.example")).isEmpty)
    }

    @Test func theCleanupSearchForADomainFindsSubdomainsAndOnlyInboxMail() throws {
        let found = try threads(BlockMatcher.cleanupQuery(kind: .domain, value: "acme.example"))
        #expect(found.isSuperset(of: ["t-news", "t-sub", "t-plus"]), "the domain and its subdomains")
        #expect(!found.contains("t-filed"), "only the inbox")
        #expect(!found.contains("t-look"), "a lookalike domain is not found")
        #expect(!BlockMatcher.matches(BlockRule(kind: .domain, value: "acme.example", createdAt: Date())!,
                                      address: "promo@acme.example.net"))
    }

    @Test func theCleanupSearchForAnAddressIsExact() throws {
        #expect(try threads(BlockMatcher.cleanupQuery(kind: .sender, value: "news@acme.example")) == ["t-news"],
                "a plus-addressed variant is not found by the local search (documented)")
    }
}
