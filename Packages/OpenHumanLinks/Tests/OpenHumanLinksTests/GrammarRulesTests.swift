import Foundation
import Testing
@testable import OpenHumanLinks

private func parse(_ s: String) -> Result<MailLink, MailLinkError> { MailLinkParser.parse(string: s) }

@Suite struct GrammarRulesTests {
    @Test func versionAndSchemeCase() {
        #expect(LinkGrammar.version == 1 && LinkGrammar.scheme == "openhuman")
        #expect(parse("OPENHUMAN://search?q=x") == .success(.search(query: "x", account: nil)))
        #expect(parse("openhuman:thread/a/b") == .failure(.unknownRoute), "no authority, no route")
        #expect(parse("") == .failure(.wrongScheme))
    }

    @Test func recipientAndSubjectLimitsAtTheirEdges() {
        let fifty = (0..<50).map { "u\($0)@example.com" }
        #expect(parse("openhuman://compose?to=" + fifty.joined(separator: ",")) != .failure(.tooManyItems))
        let split = "openhuman://compose?to=" + fifty.prefix(30).joined(separator: ",") + "&cc=" + fifty.suffix(21).joined(separator: ",")
        #expect(parse(split) == .failure(.tooManyItems), "to + cc counted together (51)")
        #expect(parse("openhuman://compose?to=" + (fifty + ["x@example.com"]).joined(separator: ",")) == .failure(.tooManyItems))
        let subject = String(repeating: "s", count: 998)
        #expect(parse("openhuman://compose?subject=" + subject) == .success(.compose(ComposePrefill(subject: subject))))
        #expect(parse("openhuman://compose?subject=" + subject + "s") == .failure(.tooLong))
        let body = String(repeating: "b", count: 32 * 1024)
        #expect(parse("openhuman://compose?body=" + body) == .success(.compose(ComposePrefill(body: body))))
    }

    @Test func reviewAllowsFiftyIDsAndKeepsTheirOrder() {
        let ids = (0..<50).map { "d\($0)" }
        guard case .success(.review(let refs)) = parse("openhuman://review?account=w&ids=" + ids.joined(separator: ",")) else {
            Issue.record("50 ids should parse"); return
        }
        #expect(refs.map(\.draftID) == ids)
        #expect(parse("openhuman://review?account=w&ids=") == .failure(.invalidID))
        #expect(parse("openhuman://review?account=w") == .failure(.invalidID))
        #expect(parse("openhuman://review?account=w&ids=a,,b") == .failure(.invalidID), "an empty id is not skipped")
        #expect(parse("openhuman://review?ids=a@x.com:a1,b2") == .failure(.invalidID), "one bare id fails the whole link")
        #expect(parse("openhuman://review/extra?account=w&ids=a") == .failure(.unknownRoute))
    }

    @Test func controlCharactersAreRemovedExceptNewlineAndTab() {
        let r = parse("openhuman://compose?subject=a%00b%1Fc%7Fd&body=x%0Ay%09z%0Bw%1B%5B31m")
        #expect(r == .success(.compose(ComposePrefill(subject: "abcd", body: "x\ny\tzw[31m"))))
    }

    @Test func plusIsLiteralAndTheFirstOccurrenceOfAParameterWins() {
        #expect(parse("openhuman://search?q=a+b&q=second") == .success(.search(query: "a+b", account: nil)))
        #expect(parse("openhuman://compose?subject=1+1%3D2") == .success(.compose(ComposePrefill(subject: "1+1=2"))))
    }

    @Test func aLinkCanNeverCarryBccAttachmentsHTMLFromOrSend() {
        let r = parse("openhuman://compose?to=a@example.com&bcc=b@example.com&attach=/etc/passwd&html=%3Cb%3E&from=x@y.com&send=1&in-reply-to=abc")
        #expect(r == .success(.compose(ComposePrefill(to: ["a@example.com"], droppedBcc: true))))
        #expect(parse("openhuman://compose?bcc=not-an-address") == .success(.compose(ComposePrefill(droppedBcc: true))))
        #expect(parse("openhuman://compose?BCC=b@example.com") == .success(.compose(ComposePrefill(droppedBcc: true))),
                "parameter names are case-insensitive")
        for host in ["send", "reply", "forward", "delete", "archive", "attach"] {
            #expect(parse("openhuman://\(host)/a/b") == .failure(.unknownRoute), "\(host)")
        }
    }

    @Test func unknownParametersAreIgnoredAcrossRoutes() {
        #expect(parse("openhuman://thread/a/b?utm=x&anything=1") == .success(.thread(account: AccountRef("a"), threadID: "b")))
        #expect(parse("openhuman://review?account=w&ids=a1&future=1") == .success(.review([DraftRef(account: AccountRef("w"), draftID: "a1")])))
    }

    @Test func accountsAreEmailsOrAliasesAndNothingElse() {
        #expect(parse("openhuman://thread/me%40example.com/a") == .success(.thread(account: AccountRef("me@example.com"), threadID: "a")))
        #expect(parse("openhuman://thread/work/a") == .success(.thread(account: AccountRef("work"), threadID: "a")))
        for bad in ["a%20b", "a%2Fb", "%3Cscript%3E", "a:b", String(repeating: "x", count: 255)] {
            #expect(parse("openhuman://thread/\(bad)/a") != .success(.thread(account: AccountRef(bad), threadID: "a")), "\(bad)")
        }
        #expect(parse("openhuman://thread/a%2Fb/c") == .failure(.invalidID))
    }

    @Test func theBuilderNeverEmitsBccOrUnencodedSpaces() {
        let link = MailLink.compose(ComposePrefill(account: AccountRef("work"), to: ["a@example.com"], cc: ["c@example.com"],
                                                   subject: "Plan B & more", body: "line one\nline two", droppedBcc: true))
        let text = MailLinkBuilder.string(for: link)
        #expect(!text.lowercased().contains("bcc") && !text.contains(" ") && !text.contains("&&"))
        #expect(text == "openhuman://compose?account=work&to=a@example.com&cc=c@example.com&subject=Plan%20B%20%26%20more&body=line%20one%0Aline%20two")
        guard case .success(.compose(let back)) = MailLinkParser.parse(MailLinkBuilder.url(for: link)) else {
            Issue.record("did not round trip"); return
        }
        #expect(back.to == ["a@example.com"] && back.cc == ["c@example.com"] && back.subject == "Plan B & more" && !back.droppedBcc)
    }

    @Test func theCLIsReviewLinkFormIsTheOneTheAppParses() {
        let uuids = ["0b6e4c2a-1111-4c55-9d1b-2f1f8c5e9a10", "7c1d9a30-2222-4b11-8a0e-5d5d5d5d5d5d", "f00dfeed-3333-4a2b-9c3c-123456789abc"]
        let link = MailLink.review(uuids.map { DraftRef(account: AccountRef("me@work.example"), draftID: $0) })
        let text = MailLinkBuilder.string(for: link)
        #expect(text == "openhuman://review?account=me@work.example&ids=" + uuids.joined(separator: ","))
        #expect(parse(text) == .success(link))
        #expect(parse(text.replacingOccurrences(of: "@", with: "%40")) == .success(link), "percent-encoded @ is accepted")
    }
}
