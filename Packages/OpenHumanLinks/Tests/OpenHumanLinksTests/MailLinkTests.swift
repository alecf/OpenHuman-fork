import Foundation
import Testing
@testable import OpenHumanLinks

private func parse(_ s: String) -> Result<MailLink, MailLinkError> { MailLinkParser.parse(string: s) }

@Suite struct ParserTests {
    @Test func thread() {
        #expect(parse("openhuman://thread/me@example.com/18c2a1f0b9") ==
            .success(.thread(account: AccountRef("me@example.com"), threadID: "18c2a1f0b9")))
        #expect(parse("OpenHuman://thread/me%40example.com/abc") ==
            .success(.thread(account: AccountRef("me@example.com"), threadID: "abc")))
        #expect(parse("openhuman://draft/work/0b6e4c2a-1111-4c55-9d1b-2f1f8c5e9a10") ==
            .success(.draft(account: AccountRef("work"), draftID: "0b6e4c2a-1111-4c55-9d1b-2f1f8c5e9a10")))
    }

    @Test func review() {
        #expect(parse("openhuman://review?account=me@x.com&ids=a1,b2") ==
            .success(.review([DraftRef(account: AccountRef("me@x.com"), draftID: "a1"),
                              DraftRef(account: AccountRef("me@x.com"), draftID: "b2")])))
        #expect(parse("openhuman://review?ids=a@x.com:a1,b@y.com:b2") ==
            .success(.review([DraftRef(account: AccountRef("a@x.com"), draftID: "a1"),
                              DraftRef(account: AccountRef("b@y.com"), draftID: "b2")])))
        #expect(parse("openhuman://review?ids=a1") == .failure(.invalidID))
        let many = (0..<51).map { "d\($0)" }.joined(separator: ",")
        #expect(parse("openhuman://review?account=w&ids=" + many) == .failure(.tooManyItems))
    }

    @Test func searchKeepsPlusLiteral() {
        #expect(parse("openhuman://search?q=a+b%20c&account=work&utm=x") ==
            .success(.search(query: "a+b c", account: AccountRef("work"))))
    }

    @Test func compose() {
        let r = parse("openhuman://compose?account=work&to=a@x.com,%20b@y.org&cc=c@z.io&subject=Hi%07there&body=line1%0Aline2%0D&bcc=evil@x.com")
        #expect(r == .success(.compose(ComposePrefill(account: AccountRef("work"), to: ["a@x.com", "b@y.org"],
                                                       cc: ["c@z.io"], subject: "Hithere", body: "line1\nline2",
                                                       droppedBcc: true))))
        #expect(parse("openhuman://compose?to=Name%20%3Ca@x.com%3E") == .failure(.invalidAddress))
        #expect(parse("openhuman://compose?to=nobody") == .failure(.invalidAddress))
        let body = String(repeating: "x", count: 32 * 1024 + 1)
        #expect(parse("openhuman://compose?body=" + body) == .failure(.tooLong))
    }

    @Test(arguments: [
        ("http://thread/a/b", MailLinkError.wrongScheme),
        ("mailto:a@b.com", .wrongScheme),
        ("openhuman://user:pw@thread/a/b", .invalidEncoding),
        ("openhuman://thread:80/a/b", .invalidEncoding),
        ("openhuman://thread/a/b#frag", .invalidEncoding),
        ("openhuman://thread/../b", .invalidID),
        ("openhuman://thread/a/../../etc", .unknownRoute),
        ("openhuman://thread/a/b/", .unknownRoute),
        ("openhuman://thread/a", .unknownRoute),
        ("openhuman://thread/a/javascript:alert(1)", .invalidID),
        ("openhuman://thread/a/%FF%FE", .invalidEncoding),
        ("openhuman://send/a/b", .unknownRoute),
        ("openhuman://v2/thread/a/b", .unknownRoute),
        ("openhuman://thread/a/" + String(repeating: "x", count: 65), .invalidID),
        ("openhuman://search?q=" + String(repeating: "x", count: 41 * 1024), .tooLong),
    ])
    func rejectsHostileInput(input: String, expected: MailLinkError) {
        #expect(parse(input) == .failure(expected), "\(input.prefix(60))")
    }
}

@Suite struct RoundTripTests {
    struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func string(from alphabet: [Character], _ range: ClosedRange<Int>) -> String {
            String((0..<(range.lowerBound + int(range.count))).map { _ in alphabet[int(alphabet.count)] })
        }
    }

    static let idChars = Array("abcdefABCDEF0123456789_-")
    static let textChars = Array("ab c+&=?#%/,:;@\n\téü日本😀\"'<>")

    func account(_ g: inout SplitMix) -> AccountRef {
        g.int(2) == 0 ? AccountRef(g.string(from: Array("abcxyz019"), 1...8) + "@ex-" + g.string(from: Array("abc"), 1...4) + ".com")
                      : AccountRef(g.string(from: Array("work_+.-1"), 0...6) + "w")
    }

    func link(_ g: inout SplitMix) -> MailLink {
        switch g.int(5) {
        case 0: return .thread(account: account(&g), threadID: g.string(from: Self.idChars, 1...64))
        case 1: return .draft(account: account(&g), draftID: g.string(from: Self.idChars, 1...40))
        case 2:
            let shared = account(&g)
            let mixed = g.int(2) == 0
            return .review((0..<(1 + g.int(50))).map { _ in
                DraftRef(account: mixed ? account(&g) : shared, draftID: g.string(from: Self.idChars, 1...36))
            })
        case 3: return .search(query: g.string(from: Self.textChars, 0...40), account: g.int(2) == 0 ? nil : account(&g))
        default:
            let addr = { (g: inout SplitMix) in g.string(from: Array("abc.+_9"), 1...6) + "x@d" + g.string(from: Array("ab-"), 0...4) + "q.org" }
            return .compose(ComposePrefill(
                account: g.int(2) == 0 ? nil : account(&g),
                to: (0..<g.int(4)).map { _ in addr(&g) }, cc: (0..<g.int(3)).map { _ in addr(&g) },
                subject: g.int(3) == 0 ? nil : g.string(from: Self.textChars, 0...60),
                body: g.int(3) == 0 ? nil : g.string(from: Self.textChars, 0...400)))
        }
    }

    @Test func parseOfBuildIsIdentity() {
        var g = SplitMix(state: 42)
        for _ in 0..<2000 {
            let l = link(&g)
            let url = MailLinkBuilder.url(for: l)
            #expect(MailLinkParser.parse(url) == .success(l), "\(url)")
        }
    }

    @Test func builderShape() {
        #expect(MailLinkBuilder.string(for: .search(query: "from:a b+c", account: nil)) == "openhuman://search?q=from%3Aa%20b%2Bc")
        #expect(MailLinkBuilder.string(for: .thread(account: AccountRef("me@x.com"), threadID: "abc")) == "openhuman://thread/me@x.com/abc")
    }

    @Test func fuzzNeverCrashes() {
        var g = SplitMix(state: 7)
        let alphabet = Array("openhuman:/?&=%,@#+threaddraftreviewsearchcompose ids account q to cc bcc AFaf09\u{0}\u{7f}é")
        for _ in 0..<5000 {
            let s = (g.int(2) == 0 ? "openhuman://" : "") + g.string(from: alphabet, 0...80)
            _ = MailLinkParser.parse(string: s)
            if let url = URL(string: s) { _ = MailLinkParser.parse(url) }
        }
        var bytes = SplitMix(state: 99)
        for _ in 0..<2000 {
            let data = Data((0..<bytes.int(64)).map { _ in UInt8(truncatingIfNeeded: bytes.next()) })
            _ = MailLinkParser.parse(string: "openhuman://" + String(decoding: data, as: UTF8.self))
        }
    }
}
