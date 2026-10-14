import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanMIME

private func addr(_ email: String, _ name: String? = nil) -> EmailAddress { EmailAddress(name: name, email: email) }

private func context(subject: String = "Plan", from: EmailAddress? = addr("alice@example.com", "Alice"),
                     to: [EmailAddress] = [addr("me@example.com"), addr("bob@example.org")],
                     cc: [EmailAddress] = [addr("carol@example.org")], replyTo: [EmailAddress] = [],
                     references: [String] = ["<r1@x>"], inReplyTo: String? = nil, messageID: String? = "<m1@x>",
                     html: String? = nil, text: String? = "line one\n\nline three") -> ReplyContext {
    ReplyContext(messageID: messageID, references: references, inReplyTo: inReplyTo, subject: subject, from: from, to: to,
                 cc: cc, replyTo: replyTo, date: Date(timeIntervalSince1970: 1_791_617_400), htmlBody: html,
                 textBody: text, gmailThreadID: "t1")
}

private func skeleton(_ c: ReplyContext, _ mode: ReplyMode, me: [String] = ["me@example.com"]) -> ReplySkeleton {
    ReplyComposer.skeleton(for: c, mode: mode, myAddresses: me, locale: Locale(identifier: "en_US"),
                           timeZone: TimeZone(identifier: "UTC")!)
}

@Suite struct ReplyComposerTests {
    @Test func replyGoesToSender() {
        let s = skeleton(context(), .reply)
        #expect(s.to == [addr("alice@example.com", "Alice")] && s.cc.isEmpty)
        #expect(s.subject == "Re: Plan" && s.inReplyTo == "<m1@x>" && s.references == ["<r1@x>", "<m1@x>"])
        #expect(s.gmailThreadID == "t1")
    }

    @Test func replyHonoursReplyTo() {
        let s = skeleton(context(replyTo: [addr("list@example.org")]), .reply)
        #expect(s.to == [addr("list@example.org")])
        let all = skeleton(context(replyTo: [addr("list@example.org")]), .replyAll)
        #expect(all.to == [addr("list@example.org")] && all.cc.map(\.email) == ["bob@example.org", "carol@example.org"])
    }

    @Test func replyAllRemovesMeAndDuplicates() {
        let c = context(to: [addr("ME@example.com"), addr("Bob@example.org"), addr("alice@example.com")],
                        cc: [addr("bob@EXAMPLE.org"), addr("dave@example.org"), addr("me@example.com")])
        let s = skeleton(c, .replyAll, me: ["me@Example.com", "alias@example.com"])
        #expect(s.to.map(\.email) == ["alice@example.com"])
        #expect(s.cc.map(\.email) == ["Bob@example.org", "dave@example.org"])
    }

    @Test func replyToOwnMessageGoesToOriginalRecipients() {
        let c = context(from: addr("ME@example.com"), to: [addr("bob@example.org")], cc: [addr("carol@example.org"), addr("me@example.com")])
        let r = skeleton(c, .reply)
        #expect(r.to.map(\.email) == ["bob@example.org"] && r.cc.isEmpty)
        let all = skeleton(c, .replyAll)
        #expect(all.to.map(\.email) == ["bob@example.org"] && all.cc.map(\.email) == ["carol@example.org"])
    }

    @Test func neverBcc() {
        let s = skeleton(context(), .replyAll)
        #expect(Set((s.to + s.cc).map(\.email)).isSubset(of: ["alice@example.com", "bob@example.org", "carol@example.org"]))
    }

    @Test func forward() {
        let s = skeleton(context(subject: "Re: Plan"), .forward)
        #expect(s.to.isEmpty && s.cc.isEmpty && s.subject == "Fwd: Plan")
        #expect(s.inReplyTo == nil && s.references.isEmpty && s.gmailThreadID == nil)
        #expect(s.quotedText.hasPrefix("---------- Forwarded message ---------\nFrom: Alice <alice@example.com>\nDate: "))
        #expect(s.quotedText.contains("\nSubject: Re: Plan\nTo: me@example.com, bob@example.org\nCc: carol@example.org\n\nline one"))
        #expect(s.quotedHTML.contains("data-oh-quote=\"1\"") && s.quotedHTML.contains("Forwarded message"))
        #expect(!s.quotedText.lowercased().contains("bcc"))
    }

    @Test(arguments: [
        ("Hello", "Re: Hello"), ("Re: Hello", "Re: Hello"), ("RE: Hello", "Re: Hello"), ("re:Hello", "Re: Hello"),
        ("Re: Re: Re: Hello", "Re: Hello"), ("Re[2]: Hello", "Re: Hello"), ("Re(3): Hello", "Re: Hello"),
        ("Aw: Hello", "Re: Hello"), ("AW: Hello", "Re: Hello"), ("Sv: Hello", "Re: Hello"), ("WG: Hello", "Re: Hello"),
        ("Fwd: Hello", "Re: Hello"), ("FW: Hello", "Re: Hello"), ("Fw: Re: Hello", "Re: Hello"),
        ("  Re :  Hello  ", "Re: Hello"), ("Re: Aw: Fwd: Hello", "Re: Hello"), ("Re:Re:Re:Re:Re:Re: Hello", "Re: Hello"),
        ("Regarding: Hello", "Re: Regarding: Hello"), ("Reply: Hello", "Re: Reply: Hello"), ("Re: Hello: world", "Re: Hello: world"),
        ("Re[x]: Hello", "Re: Re[x]: Hello"), ("", "Re: "), ("Re:", "Re: "), ("Hello Re: there", "Re: Hello Re: there"),
        ("RE: FW: re: Hello", "Re: Hello"),
    ] as [(String, String)])
    func replySubjects(input: String, expected: String) {
        #expect(skeleton(context(subject: input), .reply).subject == expected)
    }

    @Test func forwardSubject() {
        #expect(skeleton(context(subject: "RE: Fwd: Hello"), .forward).subject == "Fwd: Hello")
        #expect(skeleton(context(subject: "Hello"), .forward).subject == "Fwd: Hello")
    }

    @Test func references() {
        let many = (1...25).map { "<r\($0)@x>" }
        let s = skeleton(context(references: many), .reply)
        #expect(s.references.count == 20 && s.references.first == "<r1@x>" && s.references.last == "<m1@x>")
        #expect(s.references[1] == "<r8@x>")
        let irt = skeleton(context(references: [], inReplyTo: "<p@x>"), .reply)
        #expect(irt.references == ["<p@x>", "<m1@x>"] && irt.inReplyTo == "<m1@x>")
        #expect(skeleton(context(references: []), .reply).references == ["<m1@x>"])
        #expect(skeleton(context(references: [], messageID: nil), .reply).inReplyTo == nil)
    }

    @Test func quoteBlocks() {
        let s = skeleton(context(text: "hello\n\nworld"), .reply)
        #expect(s.quotedText.hasPrefix("On ") && s.quotedText.contains(", Alice <alice@example.com> wrote:\n> hello\n>\n> world"))
        #expect(s.quotedText.contains("2026"))
        #expect(s.quotedHTML.hasPrefix("<div class=\"gmail_quote\" data-oh-quote=\"1\">"))
        #expect(s.quotedHTML.contains("<blockquote class=\"gmail_quote\"") && s.quotedHTML.hasSuffix("</blockquote></div>"))
        #expect(s.quotedHTML.contains("hello<br>"))
        let evil = skeleton(context(from: addr("a@example.com", "<img src=x onerror=alert(1)>")), .reply)
        #expect(!evil.quotedHTML.contains("<img"))
        let htmlOnly = skeleton(context(html: "<p>Hi <b>there</b></p>", text: nil), .reply)
        #expect(htmlOnly.quotedText.contains("> Hi there"))
    }

    @Test func quotedHTMLIsCleaned() {
        let html = """
            <html><head><style>p{}</style><script>alert(1)</script></head><body onload="x()">
            <p onclick="evil()" class="c">Hi <a href="javascript:alert(1)">bad</a> <a href="https://example.com/a?b=1&c=2">ok</a></p>
            <img src="https://tracker.example/pixel.gif" alt="t"><img src="cid:logo@x"><img src="data:image/png;base64,AAAA">
            <!-- comment --><iframe src="https://x"></iframe><SCRIPT>bad()</SCRIPT><div>tail</div></body></html>
            """
        let q = skeleton(context(html: html), .reply).quotedHTML
        for forbidden in ["<script", "alert(1)", "<style", "<head", "onclick", "onload", "tracker.example", "javascript:", "<iframe",
                          "<!--", "<body", "<html", "bad()"] {
            #expect(!q.lowercased().contains(forbidden), "\(forbidden) in \(q)")
        }
        for kept in ["class=\"c\"", "https://example.com/a?b=1&c=2", "cid:logo@x", "data:image/png", "tail", "alt=\"t\""] {
            #expect(q.contains(kept), "\(kept) missing")
        }
    }

    @Test func hostileHTMLTerminates() {
        let junk = String(repeating: "<a href='", count: 20_000) + String(repeating: "<", count: 20_000)
            + String(repeating: "<script>", count: 5_000) + "<img src=\"http://x" 
        let q = skeleton(context(html: junk), .reply).quotedHTML
        #expect(q.hasPrefix("<div"))
    }

    @Test func messageIDs() {
        let id = ReplyComposer.makeMessageID(from: addr("me@sub.example.com"), uuid: UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!)
        #expect(id == "<oh.abcdef01-2345-6789-abcd-ef0123456789@sub.example.com>")
        #expect(ReplyComposer.makeMessageID(from: addr("odd"), uuid: UUID()).hasSuffix("@localhost>"))
    }
}
