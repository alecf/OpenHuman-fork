import Foundation
import MailFeatures
import OpenHumanGmail
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanMailLive

private let transportFailures: [(TransportError, UpdateFeedFailure)] = [
    (.notConnected, .offline), (.cannotConnect, .offline), (.timedOut, .timedOut), (.tls("x"), .unreachable),
    (.connectionLost(requestMayHaveBeenSent: false), .unreachable), (.cancelled, .unreachable),
]

private let feedNow = Date(timeIntervalSince1970: 1_791_000_000)
private let feedLabel = BuildLabel(version: "0.1.0", build: "1001", channel: "early-development")

@MainActor
@Suite struct ReleaseFeedClientTests {
    func center(_ transport: FakeHTTPTransport, opened: @escaping @MainActor (URL) -> Void = { _ in }) -> UpdateCheckCenter {
        UpdateCheckCenter(current: feedLabel, feed: .openHuman, fetch: ReleaseFeedClient(transport: transport).fetch,
                          openURL: opened, now: { feedNow })
    }

    @Test func oneClickSendsOnePlainGETWithNothingAboutThePerson() async throws {
        let transport = FakeHTTPTransport()
        transport.on("GET", "/repos/michaelmagan/OpenHuman/releases") { _ in
            FakeHTTPTransport.json(200, [["tag_name": "v0.2.0", "draft": false, "prerelease": true, "body": "Faster search",
                                          "html_url": "https://github.com/michaelmagan/OpenHuman/releases/tag/v0.2.0"]])
        }
        let updates = center(transport)
        #expect(transport.requests.isEmpty, "nothing is sent before the click")
        updates.begin()
        await updates.settle()
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.method == "GET" && request.body == nil)
        #expect(request.url == UpdateFeed.openHuman.releasesURL)
        #expect(request.url.absoluteString == "https://api.github.com/repos/michaelmagan/OpenHuman/releases?per_page=10")
        #expect(request.headers == ["Accept": "application/vnd.github+json", "Accept-Language": "en",
                                    "X-GitHub-Api-Version": "2022-11-28"])
        for name in request.headers.keys.map({ $0.lowercased() }) {
            #expect(!["authorization", "cookie", "user-agent", "x-device-id", "x-client-id"].contains(name), "\(name)")
        }
        #expect(updates.available?.version.description == "0.2.0")
    }

    @Test func aPrivateOrMissingRepositoryReadsAsCouldNotCheckYet() async {
        let transport = FakeHTTPTransport()
        let updates = center(transport)
        await updates.check()
        #expect(transport.requests.count == 1, "the fake answers 404 for a route it doesn't know")
        #expect(updates.result == .notPublishedYet)
        #expect(updates.message?.headline == "Couldn't check yet" && updates.message?.tone == .neutral)
    }

    @Test func aRateLimitSaysWhenToTryAgain() async {
        let transport = FakeHTTPTransport()
        let reset = Int(feedNow.timeIntervalSince1970) + 30 * 60
        transport.on("GET", "/repos/") { _ in
            HTTPResponse(status: 403, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "\(reset)"], body: Data("{}".utf8))
        }
        let updates = center(transport)
        await updates.check()
        #expect(updates.result == .couldNotCheck(.rateLimited(retryAt: Date(timeIntervalSince1970: TimeInterval(reset)))))
        #expect(updates.message?.detail.hasSuffix("Try again in about 30 minutes.") == true)
    }

    @Test(arguments: transportFailures)
    func transportFailuresBecomeFeedFailures(_ pair: (TransportError, UpdateFeedFailure)) async {
        let transport = FakeHTTPTransport()
        transport.failNext(pair.0)
        do {
            _ = try await ReleaseFeedClient(transport: transport).fetch(UpdateFeed.openHuman.releasesURL)
            Issue.record("expected a failure")
        } catch let failure as UpdateFeedFailure {
            #expect(failure == pair.1)
        } catch {
            Issue.record("unexpected \(type(of: error))")
        }
    }

    @Test func onlyHTTPSIsAsked() async {
        let transport = FakeHTTPTransport()
        let plain = URL(string: "http://api.github.com/repos/michaelmagan/OpenHuman/releases")!
        await #expect(throws: UpdateFeedFailure.unreachable) {
            _ = try await ReleaseFeedClient(transport: transport).fetch(plain)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test func downloadOpensTheBrowserAndTheClientFetchesNothingMore() async {
        let transport = FakeHTTPTransport()
        transport.on("GET", "/repos/") { _ in
            FakeHTTPTransport.json(200, [["tag_name": "v0.3.0", "draft": false, "prerelease": true,
                                          "html_url": "https://github.com/michaelmagan/OpenHuman/releases/tag/v0.3.0"]])
        }
        var opened: [URL] = []
        let updates = center(transport, opened: { opened.append($0) })
        await updates.check()
        updates.download()
        #expect(opened.map(\.absoluteString) == ["https://github.com/michaelmagan/OpenHuman/releases/tag/v0.3.0"])
        #expect(transport.requests.count == 1)
    }
}
