import Foundation
import MailModel
import MailTheme
import OpenHumanCore
import Testing
@testable import MailRender

@Test func trackerHostsMatchSubdomainsOnly() {
    #expect(TrackerList.isTracker(host: "us12.list-manage.com"))
    #expect(TrackerList.isTracker(host: "LIST-MANAGE.COM."))
    #expect(!TrackerList.isTracker(host: "notlist-manage.com"))
    #expect(!TrackerList.isTracker(host: "list-manage.com.evil.example"))
    #expect(TrackerList.isTracker(url: "https://news.example/track/open.php?u=1"))
    #expect(TrackerList.isTracker(url: "https://news.example/WF/OPEN?x"))
    #expect(!TrackerList.isTracker(url: "https://news.example/opening-hours.png"))
}

@Test func contentRuleListIsValidJSON() throws {
    let json = TrackerList.contentRuleListJSON()
    let rules = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    #expect(rules.count == TrackerList.hosts.count)
    let filters = rules.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String }
    #expect(filters.contains("^https?://(.*\\.)?list-manage\\.com[/:]"))
    for filter in filters {
        #expect(!filter.contains("|") && !filter.contains("[^"), "content-blocker regexes have no disjunction or negated classes")
        let regex = try NSRegularExpression(pattern: filter, options: [.caseInsensitive])
        let host = filter.replacingOccurrences(of: "^https?://(.*\\.)?", with: "").replacingOccurrences(of: "[/:]", with: "")
            .replacingOccurrences(of: "\\.", with: ".")
        for (url, matches) in [("https://\(host)/o.gif", true), ("https://a.\(host)/o.gif", true), ("https://\(host).evil.example/", false)] {
            let found = regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
            #expect(found == matches, "\(filter) on \(url)")
        }
    }
}

@Test func remoteImagesPerSender() {
    let list = ["dana@example.com", "@news.example.org", "@bad", "  @Shop.Example  "]
    #expect(RemoteImageRules.decision(policy: .block, allowedSenders: list, sender: "Dana <DANA@example.com>") == .load)
    #expect(RemoteImageRules.decision(policy: .block, allowedSenders: list, sender: "x@news.example.org") == .load)
    #expect(RemoteImageRules.decision(policy: .block, allowedSenders: list, sender: "x@mail.news.example.org") == .load)
    #expect(RemoteImageRules.decision(policy: .block, allowedSenders: list, sender: "x@shop.example") == .load)
    #expect(RemoteImageRules.decision(policy: .block, allowedSenders: list, sender: "x@evilnews.example.org") == .block)
    #expect(RemoteImageRules.decision(policy: .block, allowedSenders: list, sender: "x@bad") == .block)
    #expect(RemoteImageRules.decision(policy: .ask, allowedSenders: [], sender: "x@y.example") == .block)
    #expect(RemoteImageRules.decision(policy: .ask, allowedSenders: [], sender: "x@y.example", loadOnce: true) == .load)
    #expect(RemoteImageRules.decision(policy: .allow, allowedSenders: [], sender: nil) == .load)
    #expect(RemoteImageRules.decision(policy: .block, allowedSenders: list, sender: nil) == .block)
    #expect(RemoteImageRules.domainEntry(forSender: "Ann <Ann@Mail.Example.com>") == "@mail.example.com")
    #expect(RemoteImageRules.addressEntry(forSender: "Ann <Ann@Mail.Example.com>") == "ann@mail.example.com")
    #expect(RemoteImageRules.domainEntry(forSender: "not an address") == nil)
}

@Test func inlinePartURLs() {
    #expect(InlineParts.contentID(from: URL(string: "ohcid:chart-1@fake.example")!) == "chart-1@fake.example")
    #expect(InlineParts.contentID(fromString: "ohcid:%3Cpart%40x%3E") == "part@x")
    #expect(InlineParts.contentID(fromString: "cid:a%20b") == "a b")
    #expect(InlineParts.contentID(fromString: "https://x.example/a") == nil)
    #expect(InlineParts.contentID(fromString: "ohcid:") == nil)
    #expect(InlineParts.normalize(" <abc@x> ") == "abc@x")
    #expect(InlineParts.matches("<ABC@x>", "abc@x"))
    let url = InlineParts.urlString(forContentID: "<odd id/with?chars@x>")
    #expect(url == "ohcid:odd%20id%2Fwith%3Fchars@x")
    #expect(InlineParts.contentID(fromString: url) == "odd id/with?chars@x")
}

@Test func nestingLimiterLeavesOrdinaryMailAlone() {
    for fixture in EmailFixture.all {
        let (out, changed) = NestingLimiter.limit(fixture.html, maxDepth: 200, maxTableDepth: 24)
        #expect(!changed && out == fixture.html, "\(fixture.name)")
    }
}

@Test func nestingLimiterCutsDeepAndTableBombs() {
    let deep = String(repeating: "<div>", count: 1_000) + "x" + String(repeating: "</div>", count: 1_000)
    let (limited, changed) = NestingLimiter.limit(deep, maxDepth: 200, maxTableDepth: 24)
    #expect(changed)
    #expect(limited.components(separatedBy: "<div>").count - 1 == 200)
    #expect(limited.components(separatedBy: "</div>").count - 1 == 200)
    let tables = String(repeating: "<table><tr><td>", count: 100) + "x"
    let (cut, _) = NestingLimiter.limit(tables, maxDepth: 200, maxTableDepth: 24)
    #expect(cut.components(separatedBy: "<table>").count - 1 == 24)
    let script = "<script>" + String(repeating: "<div>", count: 500) + "</script><!--" + String(repeating: "<div>", count: 500) + "--><p>x</p>"
    #expect(!NestingLimiter.limit(script, maxDepth: 200, maxTableDepth: 24).changed)
    #expect(!NestingLimiter.limit("<div title=\"a>b\"><p>x</p></div>", maxDepth: 1, maxTableDepth: 1).changed)
}

@Test func deepMarkupKeepsItsTextAndStaysWithinLimits() throws {
    let html = String(repeating: "<div><span>", count: 3_000) + "deep text" + String(repeating: "</span></div>", count: 3_000)
    guard case .html(let r) = MessageRenderer().render(MessageContent(html: html, text: nil)) else { Issue.record("expected html"); return }
    #expect(r.html.contains("deep text"))
    #expect(r.html.components(separatedBy: "<div>").count < 260)
}

@Test func oversizedMessagesAreCutAndFlagged() {
    let big = "<p>" + String(repeating: "é", count: 3_000_000) + "</p><p>tail</p>"
    let s = HTMLSanitizer.sanitize(big)
    #expect(s.isTruncated)
    #expect(s.bodyHTML.hasPrefix("<p>éé"), "the first 4 MB still render")
    #expect(s.bodyHTML.utf8.count > 3_000_000)
    #expect(!s.bodyHTML.contains("tail"))
    #expect(!s.bodyHTML.contains("\u{FFFD}"), "cut at a character boundary")
    let small = HTMLSanitizer.sanitize("<p>x</p>")
    #expect(!small.isTruncated)
}

@Test func elementLimitTruncates() {
    var limits = RenderLimits()
    limits.maxElements = 50
    let s = HTMLSanitizer.sanitize(String(repeating: "<p>x</p>", count: 200), options: SanitizerOptions(limits: limits))
    #expect(s.isTruncated)
    #expect(s.bodyHTML.components(separatedBy: "<p>").count - 1 == 50)
}

@Test func giantAttributesAreDropped() {
    let s = HTMLSanitizer.sanitize("<p title=\"" + String(repeating: "t", count: 20_000) + "\" class=\""
        + (0..<100).map { "c\($0)" }.joined(separator: " ") + "\">x</p>")
    #expect(!s.bodyHTML.contains("title="))
    #expect(s.bodyHTML.contains("class=\"c0 c1"))
    #expect(!s.bodyHTML.contains("c40"))
}

@Test func giantStylesheetsStopAtTheBudget() {
    let s = HTMLSanitizer.sanitize("<style>.a{color:red}</style><style>" + String(repeating: ".b{color:blue}", count: 50_000) + "</style><p>x</p>")
    #expect(s.headCSS == [".oh-body .a{color:red}"])
}

@Test func cacheKeyCoversEveryInput() {
    let key = MessageKey(account: AccountID(rawValue: 1), rowID: 7, gmailMessageID: GmailMessageID("m7"))
    let light = MessageRenderer(theme: .light, appearance: .light)
    let dark = MessageRenderer(theme: .dark, appearance: .dark)
    let base = light.cacheKey(for: key, context: RenderContext())
    #expect(base == light.cacheKey(for: key, context: RenderContext()))
    #expect(base != dark.cacheKey(for: key, context: RenderContext()))
    #expect(base != light.cacheKey(for: key, context: RenderContext(allowRemoteImages: true)))
    #expect(base != light.cacheKey(for: key, context: RenderContext(colorOverride: .darkColors)))
    #expect(base != light.cacheKey(for: key, context: RenderContext(textFormat: .flowed(delSp: true))))
    var always = light
    always.emailColors = .alwaysOriginal
    #expect(base != always.cacheKey(for: key, context: RenderContext()))
    #expect(base.themeFingerprint == MessageRenderer(theme: .light).themeFingerprint, "stable across instances")
    #expect(!base.stableName.contains("/") && base.stableName.contains("v\(HTMLSanitizer.version)"))
}
