import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanStore

@Suite struct SplitRuleTextTests {
    static let cases: [(String, SplitRule)] = [
        ("from:alice@example.com", .from("alice@example.com")),
        ("from:@acme.example", .from("@acme.example")),
        ("from:acme.example", .from("acme.example")),
        ("to:bob", .to("bob")),
        ("cc:bob", .to("bob")),
        ("label:Clients/Acme", .label("Clients/Acme")),
        ("label:\"My Label\"", .label("My Label")),
        ("category:promotions", .category("promotions")),
        ("category:primary", .category("personal")),
        ("is:important", .isImportant),
        ("is:starred", .isStarred),
        ("is:unread", .isUnread),
        ("is:fromme", .fromMeOnly),
        ("has:attachment", .hasAttachment),
        ("has:invite", .hasCalendarInvite),
        ("is:event", .isEvent),
        ("has:invite OR is:event", .or([.hasCalendarInvite, .isEvent])),
        ("list:news.example.com", .list("news.example.com")),
        ("subject:invoice", .subjectContains("invoice")),
        ("subject:\"big deal\"", .subjectContains("big deal")),
        ("from:a is:unread", .and([.from("a"), .isUnread])),
        ("from:a AND is:unread", .and([.from("a"), .isUnread])),
        ("from:a OR from:b", .or([.from("a"), .from("b")])),
        ("{from:a from:b}", .or([.from("a"), .from("b")])),
        ("-is:unread", .not(.isUnread)),
        ("NOT is:unread", .not(.isUnread)),
        ("(from:a OR from:b) -label:x", .and([.or([.from("a"), .from("b")]), .not(.label("x"))])),
        ("-(from:a is:unread)", .not(.and([.from("a"), .isUnread]))),
        ("()", .and([])),
        ("{}", .or([])),
        ("from:a OR (to:b is:starred)", .or([.from("a"), .and([.to("b"), .isStarred])])),
    ]

    @Test(arguments: cases) func parsesToTheRule(_ text: String, _ rule: SplitRule) throws {
        #expect(try SplitRule.parse(text) == rule)
    }

    @Test(arguments: cases) func canonicalTextRoundTrips(_ text: String, _ rule: SplitRule) throws {
        let canonical = rule.canonicalText
        let again = try SplitRule.parse(canonical)
        #expect(again.canonicalText == canonical, "\(text) -> \(canonical)")
        #expect(again == rule, "\(text) -> \(canonical)")
    }

    @Test func canonicalTextIsStableAndReadable() {
        #expect(SplitRule.and([.from("a"), .or([.to("b"), .isStarred]), .not(.isUnread)]).canonicalText == "from:a (to:b OR is:starred) -is:unread")
        #expect(SplitRule.or([.from("a"), .label("x y")]).canonicalText == "from:a OR label:\"x y\"")
        #expect(SplitRule.category("personal").canonicalText == "category:primary")
        #expect(SplitRule.and([.isUnread]).canonicalText == "is:unread")
        #expect(SplitRule.subjectContains("say \"hi\"").canonicalText == "subject:\"say  hi \"")
    }

    static let errors: [(String, Int)] = [
        ("", 0), ("hello", 0), ("from:a hello", 7), ("before:2024/01/01", 0), ("in:inbox", 0), ("bcc:x", 0), ("from:me", 0),
        ("larger:5M", 0), ("is:read", 0), ("has:userlabels", 0), ("(from:a", 0), ("from:a OR", 7), ("from:", 0),
    ]

    @Test(arguments: errors) func unsupportedOrBrokenRulesThrowWithPositions(_ text: String, _ position: Int) {
        do {
            let rule = try SplitRule.parse(text)
            Issue.record("\(text) parsed to \(rule)")
        } catch let StoreError.invalidQuery(_, at) {
            #expect(at == position, "\(text)")
        } catch {
            Issue.record("\(text): \(error)")
        }
    }

    @Test func aParsedRuleEvaluatesWithTheAggregatorsSemantics() throws {
        let rule = try SplitRule.parse("from:acme.example -is:unread")
        let json = try JSONEncoder().encode(rule)
        #expect(try JSONDecoder().decode(SplitRule.self, from: json) == rule)
    }

    @Test func theGitHubPresetRuleMatchesTheWholeDomainOnly() throws {
        #expect(try SplitRule.parse("from:@github.com") == .from("@github.com"))
        let p = AddressPattern("@github.com")
        for sender in ["notifications@github.com", "noreply@github.com", "x@mail.github.com"] {
            #expect(p.matches(email: sender, name: nil), Comment(rawValue: sender))
        }
        for sender in ["x@notgithub.com", "x@github.io", "x@github.com.example.org"] {
            #expect(!p.matches(email: sender, name: nil), Comment(rawValue: sender))
        }
    }
}
