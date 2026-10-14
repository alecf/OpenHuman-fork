import Foundation
import MailModel
import MailTheme
import SwiftSoup
import Testing
@testable import MailRender

@Test(.enabled(if: ProcessInfo.processInfo.environment["OPENHUMAN_PERF"] == "1"))
func oneMegabyteNewsletter() throws {
    let fixture = try #require(EmailFixture.all.first { $0.name == "c01-newsletter-cards" })
    let row = "<tr><td style=\"padding:8px 16px;color:#33415c;font-family:Helvetica,Arial,sans-serif\"><h2 style=\"margin:0\">"
        + "<a href=\"https://news.example/story?id=1&amp;utm_source=mail\" style=\"color:#1d2433\">A headline about the week</a></h2>"
        + "<p class=\"lead\">A paragraph of newsletter text that runs long enough to look like the real thing, with a "
        + "<a href=\"https://news.example/more\">link</a> in it.</p><img src=\"https://img.news.example/p.jpg\" width=\"560\" "
        + "height=\"200\" alt=\"Picture\"></td></tr>"
    var body = ""
    while body.utf8.count < 1_000_000 { body += row }
    let html = fixture.html.replacingOccurrences(of: "<tr><td style=\"padding:24px 32px", with: body + "<tr><td style=\"padding:24px 32px")
    #expect(html.utf8.count > 1_000_000)
    let renderer = MessageRenderer(theme: .dark, appearance: .dark)
    var sanitize: [Duration] = [], render: [Duration] = [], parse: [Duration] = []
    let clock = ContinuousClock()
    for _ in 0..<5 {
        sanitize.append(clock.measure { _ = HTMLSanitizer.sanitize(html) })
        render.append(clock.measure { _ = renderer.render(MessageContent(html: html, text: nil)) })
        parse.append(clock.measure { _ = try? SwiftSoup.parse(html) })
    }
    print("PERF 1 MB newsletter: SwiftSoup parse alone \(parse.sorted()[2]), sanitize \(sanitize.sorted()[2]), "
          + "full render \(render.sorted()[2]) (medians of 5)")
}
