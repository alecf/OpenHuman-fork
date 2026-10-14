import Foundation
import OpenHumanLinks
import Testing
@testable import MailRender

@Test func registrableDomains() {
    #expect(RegistrableDomain.of("www.paypal.com") == "paypal.com")
    #expect(RegistrableDomain.of("Mail.Example.CO.UK.") == "example.co.uk")
    #expect(RegistrableDomain.of("a.b.example.com.au") == "example.com.au")
    #expect(RegistrableDomain.of("phish.github.io") == "phish.github.io")
    #expect(RegistrableDomain.of("x.y.blob.core.windows.net") == "y.blob.core.windows.net")
    #expect(RegistrableDomain.of("192.0.2.1") == "192.0.2.1")
    #expect(RegistrableDomain.of("localhost") == "localhost")
    #expect(RegistrableDomain.of("") == nil)
    #expect(RegistrableDomain.of("a..b") == nil)
}

private func check(_ href: String, _ text: String) -> SuspiciousLink? { LinkAnalyzer.check(href: href, displayText: text) }

@Test func mismatchedDisplayDomainsAreFlagged() {
    #expect(check("https://evil.example/x", "https://www.paypal.com/signin")?.reasons == [.domainMismatch])
    #expect(check("https://evil.example/x", "www.paypal.com")?.displayedDestination == "paypal.com")
    #expect(check("https://evil.example/x", "paypal.com")?.actualDestination == "evil.example")
    #expect(check("https://evil.example/x", "<https://paypal.com>.")?.reasons == [.domainMismatch])
    #expect(check("https://evil.example/x", "support@paypal.com")?.reasons == [.domainMismatch])
    #expect(check("mailto:a@evil.example", "help@bank.example")?.reasons == [.addressMismatch])
    #expect(check("mailto:a@evil.example", "www.bank.example")?.reasons == [.domainMismatch])
    #expect(check("https://evil.example", "\u{202E}moc.lapyap.www")?.reasons == [.domainMismatch], "a bidi-override trick is still flagged")
    #expect(check("https://evil.example", "paypal\u{3002}com")?.displayedDestination == "paypal.com")
    #expect(check("https://evil.example", "pay\u{200B}pal.com")?.displayedDestination == "paypal.com")
}

@Test func matchingOrHarmlessLinksAreNotFlagged() {
    #expect(check("https://www.paypal.com/help", "paypal.com") == nil)
    #expect(check("https://news.example.com/x", "https://example.com") == nil, "same registrable domain")
    #expect(check("https://example.com/report.pdf", "report.pdf") == nil, "file names are not domains")
    #expect(check("https://example.com", "Read more") == nil)
    #expect(check("https://example.com", "v1.2.3") == nil)
    #expect(check("mailto:Help@Example.com", "help@example.com") == nil)
    #expect(check("https://example.com", "") == nil)
    #expect(check("https://example.com", "see example.org for details") == nil, "only whole-text destinations count")
}

@Test func dangerousHrefsAreFlaggedWhateverTheText() {
    #expect(check("https://bank.example@evil.example/", "Sign in")?.reasons == [.credentialsInURL])
    #expect(check("http://192.0.2.7/login", "Sign in")?.reasons == [.ipAddressHost])
    #expect(check("http://[2001:db8::1]/", "Sign in")?.reasons == [.ipAddressHost])
    #expect(check("https://xn--pypal-4ve.com/", "Sign in")?.reasons == [.punycodeHost])
    #expect(check("https:\\\\evil.example\\x", "paypal.com")?.actualHost == "evil.example", "backslashes read like WebKit")
}

@Test func navigationURLsMatchTheirHref() throws {
    let link = try #require(check("https://Evil.Example:443?x=1#frag", "paypal.com"))
    #expect(link.matches(URL(string: "https://evil.example/?x=1")!))
    #expect(!link.matches(URL(string: "https://evil.example/other")!))
    let rendered = MessageRenderer().render(.init(html: "<a href=\"https://evil.example/a%20b\">www.bank.example</a>", text: nil))
    guard case .html(let r) = rendered else { Issue.record("expected html"); return }
    #expect(r.suspiciousLink(for: URL(string: "https://evil.example/a%20b")!) != nil)
    #expect(r.suspiciousLink(for: URL(string: "https://bank.example/")!) == nil)
}

@Test func mailtoParsesLikeAComposeLink() throws {
    let prefill = try MailtoLink.parse(string: "mailto:ana@example.com,bo%40example.com?cc=cy@example.com&subject=Hello%20there&body=Line%201%0ALine%202&bcc=hidden@example.com&in-reply-to=%3Cx%40y%3E").get()
    #expect(prefill.to == ["ana@example.com", "bo@example.com"])
    #expect(prefill.cc == ["cy@example.com"])
    #expect(prefill.subject == "Hello there")
    #expect(prefill.body == "Line 1\nLine 2")
    #expect(prefill.droppedBcc)
    #expect(prefill.account == nil)
}

@Test func mailtoAcceptsCommonVariants() throws {
    #expect(try MailtoLink.parse(string: "MAILTO:help@shop.example").get().to == ["help@shop.example"])
    #expect(try MailtoLink.parse(string: "mailto:?to=a@example.com&to=b@example.com").get().to == ["a@example.com", "b@example.com"])
    #expect(try MailtoLink.parse(string: "mailto:Help%20Desk%20%3Chelp@example.com%3E").get().to == ["help@example.com"])
    #expect(try MailtoLink.parse(string: "mailto:a@example.com?subject=a+b").get().subject == "a+b", "+ is literal")
    #expect(try MailtoLink.parse(string: "mailto:?subject=only").get().subject == "only")
}

@Test func mailtoRejectsHostileInput() {
    #expect(MailtoLink.parse(string: "https://example.com") == .failure(.wrongScheme))
    #expect(MailtoLink.parse(string: "mailto:not-an-address") == .failure(.invalidAddress))
    #expect(MailtoLink.parse(string: "mailto:") == .failure(.invalidAddress))
    #expect(MailtoLink.parse(string: "mailto:a@b.example?subject=%ZZ") == .failure(.invalidEncoding))
    let many = (0..<60).map { "u\($0)@example.com" }.joined(separator: ",")
    #expect(MailtoLink.parse(string: "mailto:" + many) == .failure(.tooManyItems))
    #expect(MailtoLink.parse(string: "mailto:a@example.com?body=" + String(repeating: "x", count: 33_000)) == .failure(.tooLong))
    if case .success(let p) = MailtoLink.parse(string: "mailto:a@example.com?subject=a%07b%0Dc") {
        #expect(p.subject == "abc", "control characters are removed")
    } else {
        Issue.record("expected success")
    }
}
