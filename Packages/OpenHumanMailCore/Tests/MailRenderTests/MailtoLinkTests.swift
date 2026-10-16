import Foundation
import OpenHumanLinks
import Testing
@testable import MailRender

@Suite struct MailtoLinkTests {
    func parse(_ raw: String) -> Result<ComposePrefill, MailLinkError> { MailtoLink.parse(string: raw) }

    func prefill(_ raw: String) throws -> ComposePrefill { try parse(raw).get() }

    @Test func everyFieldOfRFC6068IsRead() throws {
        let p = try prefill("mailto:ana@example.test,bo%40example.test?to=cy@example.test&cc=dee@example.test,eli@example.test"
            + "&subject=Hello%20there&body=Line%201%0D%0ALine%202")
        #expect(p.to == ["ana@example.test", "bo@example.test", "cy@example.test"])
        #expect(p.cc == ["dee@example.test", "eli@example.test"])
        #expect(p.subject == "Hello there")
        #expect(p.body == "Line 1\nLine 2", "CRLF in a body becomes one line break")
        #expect(!p.droppedBcc && p.account == nil)
    }

    @Test func bccIsNeverCarriedOnlyNoted() throws {
        let p = try prefill("mailto:a@example.test?bcc=b@example.test&BCC=c@example.test")
        #expect(p.to == ["a@example.test"] && p.cc.isEmpty && p.droppedBcc)
        #expect(parse("mailto:?bcc=spy@evil.example") == .failure(.invalidAddress), "a link that only adds a hidden recipient opens nothing")
    }

    @Test func repeatedFieldsAddRecipientsAndTheFirstSubjectAndBodyWin() throws {
        let p = try prefill("mailto:?to=a@example.test&to=b@example.test&cc=c@example.test&cc=d@example.test"
            + "&subject=First&subject=Second&body=One&body=Two")
        #expect(p.to == ["a@example.test", "b@example.test"] && p.cc == ["c@example.test", "d@example.test"])
        #expect(p.subject == "First" && p.body == "One")
    }

    @Test func namesAndEncodingsAreReadAsTheRFCSays() throws {
        #expect(try prefill("MAILTO:help@shop.example").to == ["help@shop.example"])
        #expect(try prefill("mailto:a@example.test?SUBJECT=Hi&To=b@example.test").to == ["a@example.test", "b@example.test"])
        #expect(try prefill("mailto:a@example.test?SUBJECT=Hi").subject == "Hi")
        #expect(try prefill("mailto:a@example.test?subject=1+1%3D2").subject == "1+1=2", "+ is a plus, not a space")
        #expect(try prefill("mailto:a@example.test?body=Tom%20%26%20Jerry").body == "Tom & Jerry")
        #expect(try prefill("mailto:a@example.test?subject=%E2%9C%93%20done&body=caf%C3%A9").subject == "✓ done")
        #expect(try prefill("mailto:a@example.test?body=caf%C3%A9").body == "café")
        #expect(try prefill("mailto:Help%20Desk%20%3Chelp@example.test%3E").to == ["help@example.test"])
        #expect(try prefill("mailto:%20a@example.test%20,,%20b@example.test").to == ["a@example.test", "b@example.test"])
        #expect(try prefill("mailto:a+tag@example.test").to == ["a+tag@example.test"])
        #expect(try prefill("mailto:a@example.test?subject").subject == "", "a field without a value is empty")
        #expect(try prefill("mailto:?body=hello").to.isEmpty)
    }

    @Test func otherHeadersAndTheFragmentAreIgnored() throws {
        let p = try prefill("mailto:a@example.test?in-reply-to=%3Cx%40y%3E&from=evil@example.test&x-mailer=1&=x&subject=Hi#section")
        #expect(p == ComposePrefill(to: ["a@example.test"], subject: "Hi"))
        #expect(try prefill("mailto:a@example.test#x").to == ["a@example.test"])
        #expect(try prefill("mailto:a@example.test?subject=a?b").subject == "a?b")
    }

    @Test func aLineBreakNeverReachesARecipientOrTheSubject() throws {
        #expect(parse("mailto:a@example.test%0D%0ABcc:%20spy@evil.example") == .failure(.invalidAddress))
        #expect(parse("mailto:?to=a@example.test%0ABcc:spy@evil.example") == .failure(.invalidAddress))
        #expect(parse("mailto:?cc=a@example.test%0D%0AX-Header:%201") == .failure(.invalidAddress))
        #expect(parse("mailto:a@example.test,b@example.test%0ACc:c@example.test") == .failure(.invalidAddress))
        let p = try prefill("mailto:a@example.test?subject=Hello%0D%0ABcc:%20spy@evil.example%0AX-Priority:%201")
        #expect(p.subject == "Hello Bcc: spy@evil.example X-Priority: 1")
        #expect(p.to == ["a@example.test"] && !p.droppedBcc, "header text in the subject is only text")
        #expect(try prefill("mailto:a@example.test?subject=a%E2%80%A8b%09c").subject == "a b c")
        #expect(try prefill("mailto:a@example.test%0A").to == ["a@example.test"], "surrounding white space is trimmed")
    }

    @Test func controlCharactersAreRemoved() throws {
        let p = try prefill("mailto:a@example.test?subject=a%00b%07c&body=x%1B%5B31my%0Bz")
        #expect(p.subject == "abc" && p.body == "x[31myz")
    }

    @Test func malformedLinksAreRejected() {
        #expect(parse("https://example.test") == .failure(.wrongScheme))
        #expect(parse("mailtox:a@example.test") == .failure(.wrongScheme))
        #expect(parse("mailto") == .failure(.wrongScheme))
        #expect(parse("") == .failure(.wrongScheme))
        #expect(parse("mailto:") == .failure(.invalidAddress))
        #expect(parse("mailto:?") == .failure(.invalidAddress))
        #expect(parse("mailto:?unknown=1") == .failure(.invalidAddress))
        #expect(parse("mailto:not-an-address") == .failure(.invalidAddress))
        #expect(parse("mailto:a@b") == .failure(.invalidAddress))
        #expect(parse("mailto:@example.test") == .failure(.invalidAddress))
        #expect(parse("mailto:a@@example.test") == .failure(.invalidAddress))
        #expect(parse("mailto:a%20b@example.test") == .failure(.invalidAddress))
        #expect(parse("mailto:" + String(repeating: "a", count: 250) + "@example.test") == .failure(.invalidAddress))
        #expect(parse("mailto:a@example.test?subject=%ZZ") == .failure(.invalidEncoding))
        #expect(parse("mailto:a@example.test?body=%") == .failure(.invalidEncoding))
        #expect(parse("mailto:%E2%28") == .failure(.invalidEncoding), "not UTF-8")
    }

    @Test func longBodiesAndManyRecipientsHaveLimits() throws {
        let edge = String(repeating: "b", count: LinkGrammar.maxBodyBytes)
        #expect(try prefill("mailto:a@example.test?body=" + edge).body == edge)
        #expect(parse("mailto:a@example.test?body=" + edge + "b") == .failure(.tooLong))
        let subject = String(repeating: "s", count: LinkGrammar.maxSubjectCharacters)
        #expect(try prefill("mailto:a@example.test?subject=" + subject).subject == subject)
        #expect(parse("mailto:a@example.test?subject=" + subject + "s") == .failure(.tooLong))
        #expect(parse("mailto:a@example.test?x=" + String(repeating: "y", count: LinkGrammar.maxURLBytes)) == .failure(.tooLong))
        let fifty = (0..<50).map { "u\($0)@example.test" }
        #expect(try prefill("mailto:" + fifty.joined(separator: ",")).to.count == 50)
        let split = "mailto:" + fifty.prefix(30).joined(separator: ",") + "?cc=" + fifty.suffix(21).joined(separator: ",")
        #expect(parse(split) == .failure(.tooManyItems), "to and cc count together")
    }

    @Test func aURLParsesLikeItsText() throws {
        let url = try #require(URL(string: "mailto:dana@example.test?subject=Lunch%3F&body=Noon%0D%0Aworks"))
        #expect(MailtoLink.parse(url) == parse(url.absoluteString))
        #expect(try MailtoLink.parse(url).get() == ComposePrefill(to: ["dana@example.test"], subject: "Lunch?", body: "Noon\nworks"))
    }
}
