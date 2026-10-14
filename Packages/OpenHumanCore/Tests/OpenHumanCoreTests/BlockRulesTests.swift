import Foundation
import Testing
@testable import OpenHumanCore

@Suite struct BlockRulesTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func rule(_ kind: BlockRule.Kind, _ value: String, _ disposition: BlockDisposition? = nil) -> BlockRule {
        BlockRule(kind: kind, value: value, disposition: disposition, createdAt: Self.now)!
    }


    @Test func addressesAreLowercasedUnwrappedAndLoseTheirPlusTag() {
        #expect(BlockMatcher.normalizedAddress("Dana Sample <News+Promo@Acme.Example>") == "news@acme.example")
        #expect(BlockMatcher.normalizedAddress("  NEWS@acme.example ") == "news@acme.example")
        #expect(BlockMatcher.normalizedAddress("a+b+c@acme.example") == "a@acme.example")
    }

    @Test(arguments: ["", "no-at-sign", "a@b@acme.example", "@acme.example", "+tag@acme.example", "a@localhost",
                      "a@acme..example", "a b@acme.example", "a@acme.example>", "\"a\"@acme.example", "a,b@acme.example"])
    func unusableAddressesAreRejected(_ raw: String) {
        #expect(BlockMatcher.normalizedAddress(raw) == nil)
        #expect(BlockRule(kind: .sender, value: raw, createdAt: Self.now) == nil)
    }

    @Test func domainsAcceptAtSignAndTrailingDotAndNeedADot() {
        #expect(BlockMatcher.normalizedDomain("@Acme.Example") == "acme.example")
        #expect(BlockMatcher.normalizedDomain("acme.example.") == "acme.example")
        #expect(BlockMatcher.normalizedDomain("localhost") == nil)
        #expect(BlockMatcher.normalizedDomain("a b.example") == nil)
        #expect(BlockMatcher.normalizedDomain("a@acme.example") == nil)
        #expect(BlockMatcher.domain(of: "Dana <x@Mail.Acme.Example>") == "mail.acme.example")
    }


    @Test func aSenderRuleMatchesThatAddressOnly() {
        let r = rule(.sender, "news@acme.example")
        #expect(BlockMatcher.matches(r, address: "news@acme.example"))
        #expect(BlockMatcher.matches(r, address: "NEWS@ACME.EXAMPLE"))
        #expect(BlockMatcher.matches(r, address: "Acme News <news@acme.example>"))
        #expect(!BlockMatcher.matches(r, address: "other@acme.example"))
        #expect(!BlockMatcher.matches(r, address: "news@mail.acme.example"), "a sender rule never reaches another domain")
        #expect(!BlockMatcher.matches(r, address: "newsletter@acme.example"))
    }

    @Test func plusAddressingMatchesInBothDirections() {
        #expect(BlockMatcher.matches(rule(.sender, "news@acme.example"), address: "news+offers@acme.example"))
        let r = rule(.sender, "News+Offers@acme.example")
        #expect(r.value == "news@acme.example")
        #expect(BlockMatcher.matches(r, address: "news@acme.example"))
    }

    @Test func aDomainRuleCoversSubdomainsButNotLookalikes() {
        let r = rule(.domain, "acme.example")
        #expect(BlockMatcher.matches(r, address: "a@acme.example"))
        #expect(BlockMatcher.matches(r, address: "a@Mail.Acme.Example"))
        #expect(BlockMatcher.matches(r, address: "a@deep.mail.acme.example"))
        #expect(!BlockMatcher.matches(r, address: "a@notacme.example"))
        #expect(!BlockMatcher.matches(r, address: "a@acme.example.evil.test"))
        #expect(!BlockMatcher.matches(r, address: "a@example"))
    }

    @Test func aSubdomainRuleDoesNotCoverItsParent() {
        let r = rule(.domain, "mail.acme.example")
        #expect(BlockMatcher.matches(r, address: "a@mail.acme.example"))
        #expect(!BlockMatcher.matches(r, address: "a@acme.example"))
        #expect(!BlockMatcher.matches(r, address: "a@other.acme.example"))
    }

    @Test func aSenderRuleBeatsADomainRuleAndTheLongerDomainWins() {
        let rules = [rule(.domain, "acme.example", .trash), rule(.domain, "mail.acme.example", .archive),
                     rule(.sender, "boss@mail.acme.example", .trash)]
        #expect(BlockMatcher.firstMatch(in: rules, address: "boss@mail.acme.example")?.kind == .sender)
        #expect(BlockMatcher.firstMatch(in: rules, address: "x@mail.acme.example")?.value == "mail.acme.example")
        #expect(BlockMatcher.firstMatch(in: rules, address: "x@acme.example")?.value == "acme.example")
        #expect(BlockMatcher.firstMatch(in: rules, address: "x@elsewhere.example") == nil)
    }


    @Test func decisionFollowsTheRulesChoiceThenTheDefault() {
        let rules = [rule(.sender, "a@acme.example"), rule(.domain, "spam.example", .trash), rule(.sender, "b@acme.example", .archive)]
        let inbox = ["INBOX", "UNREAD"]
        #expect(BlockMatcher.decide(from: "a@acme.example", labelIDs: inbox, rules: rules, defaultDisposition: .archive) == .archive)
        #expect(BlockMatcher.decide(from: "a@acme.example", labelIDs: inbox, rules: rules, defaultDisposition: .trash) == .trash)
        #expect(BlockMatcher.decide(from: "x@spam.example", labelIDs: inbox, rules: rules, defaultDisposition: .archive) == .trash)
        #expect(BlockMatcher.decide(from: "b@acme.example", labelIDs: inbox, rules: rules, defaultDisposition: .trash) == .archive)
        #expect(BlockMatcher.decide(from: "c@acme.example", labelIDs: inbox, rules: rules, defaultDisposition: .trash) == .keep)
        #expect(BlockMatcher.decide(from: nil, labelIDs: inbox, rules: rules, defaultDisposition: .trash) == .keep)
    }

    @Test(arguments: [["SENT"], ["INBOX", "SENT"], ["DRAFT"], ["INBOX", "DRAFT"], ["TRASH"], ["INBOX", "TRASH"], ["SPAM"],
                      ["CATEGORY_PROMOTIONS"], []])
    func sentDraftedAndAlreadyFiledMailIsNeverTouched(_ labels: [String]) {
        let rules = [rule(.domain, "acme.example")]
        #expect(BlockMatcher.decide(from: "me@acme.example", labelIDs: labels, rules: rules, defaultDisposition: .trash) == .keep)
    }


    @Test func rulesRoundTripAsJSONWhateverTheDateStrategy() throws {
        let rules = [rule(.sender, "news@acme.example", .trash), rule(.domain, "spam.example")]
        let plain = try JSONDecoder().decode([BlockRule].self, from: JSONEncoder().encode(rules))
        #expect(plain == rules)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoded = try JSONDecoder().decode([BlockRule].self, from: encoder.encode(rules))
        #expect(decoded == rules, "the date is stored as epoch seconds, never through the encoder's date strategy")
        #expect(rules[0].id == "sender:news@acme.example")
        let json = String(decoding: try JSONEncoder().encode(rules), as: UTF8.self)
        #expect(!json.contains("Gmail"))
        let older = #"[{"kind":"sender","value":"news@acme.example","alsoBlockInGmail":true,"created":1}]"#
        #expect(try JSONDecoder().decode([BlockRule].self, from: Data(older.utf8)).map(\.id) == ["sender:news@acme.example"])
    }

    @Test func aStoredValueThatIsNotUsableFailsToDecode() {
        let json = #"[{"kind":"domain","value":"nodot","created":1}]"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([BlockRule].self, from: Data(json.utf8)) }
    }

    @Test func theSearchQueriesQuoteTheTarget() {
        #expect(BlockMatcher.sentToQuery(kind: .sender, value: "News+x@Acme.Example")
            == "in:sent (to:\"news@acme.example\" OR cc:\"news@acme.example\" OR bcc:\"news@acme.example\")")
        #expect(BlockMatcher.sentToQuery(kind: .domain, value: "@acme.example")
            == "in:sent (to:\"acme.example\" OR cc:\"acme.example\" OR bcc:\"acme.example\")")
        #expect(BlockMatcher.cleanupQuery(kind: .sender, value: "news@acme.example") == "from:\"news@acme.example\" in:inbox")
        #expect(BlockMatcher.cleanupQuery(kind: .domain, value: "@acme.example") == "from:\"acme.example\" in:inbox")
        #expect(BlockMatcher.showQuery(kind: .domain, value: "acme.example") == "from:\"acme.example\"")
        #expect(BlockMatcher.recheckQuery(kind: .domain, value: "acme.example", since: Date(timeIntervalSince1970: 1_800_000_000.9))
            == "from:\"acme.example\" after:1800000000 in:anywhere")
        #expect(BlockMatcher.recheckQuery(kind: .sender, value: "news@acme.example", since: Date(timeIntervalSince1970: 0))
            == "from:\"news@acme.example\" after:100000000 in:anywhere", "Unix seconds need 9 digits")
        #expect(BlockMatcher.sentToQuery(kind: .sender, value: "not an address") == nil)
        #expect(BlockMatcher.cleanupQuery(kind: .domain, value: "a\"b.example") == nil)
    }

    @Test func aSearchResultIsKeptOnlyWhenOneOfItsSendersIsCovered() {
        let domain = BlockRule(kind: .domain, value: "acme.example", createdAt: Date())!
        #expect(BlockMatcher.coversAny(domain, senders: ["friend@other.example", "alerts@mail.acme.example"]))
        #expect(!BlockMatcher.coversAny(domain, senders: ["promo@acme.example.net", "offers@notacme.example"]))
        #expect(!BlockMatcher.coversAny(domain, senders: []))
        let sender = BlockRule(kind: .sender, value: "news@acme.example", createdAt: Date())!
        #expect(BlockMatcher.coversAny(sender, senders: ["News+Weekly@Acme.Example"]))
        #expect(!BlockMatcher.coversAny(sender, senders: ["xnews@acme.example"]))
    }
}
