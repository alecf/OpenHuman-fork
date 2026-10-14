import Foundation
import MailFakes
import MailModel
import Testing
@testable import MailRender

@Test func fakeCorpusRendersSafely() throws {
    let corpus = FakeCorpus.make(threadCount: 60, now: Date(timeIntervalSince1970: 1_791_000_000))
    var html = 0, plain = 0
    for thread in corpus.threads {
        for (key, content) in thread.bodies {
            switch MessageRenderer().render(content) {
            case .html(let r):
                html += 1
                let problems = try SafetyInvariants.violations(in: r.html)
                #expect(problems.isEmpty, "\(String(describing: thread.bodyKinds[key])): \(problems)")
                if thread.bodyKinds[key] == .newsletter {
                    #expect(r.hasRemoteContent && r.blockedCount >= 2 && r.trackerCount == 1)
                }
                if thread.bodyKinds[key] == .gmailReply { #expect(r.hasQuotedText) }
            case .plain:
                plain += 1
            case .empty:
                Issue.record("empty body")
            }
        }
    }
    #expect(html > 0 && plain > 0)
}
