import Foundation
import MailFeatures
import OpenHumanGmail
import Testing
@testable import OpenHumanMailLive

// Why: every request is answered in-process, so nothing reaches the network
private final class GitHubStub: URLProtocol {
    static let routes = [
        "https://api.github.com/repos/owner/moved/releases": "https://api.github.com/repositories/1/releases",
        "https://api.github.com/repos/owner/away/releases": "https://evil.test/releases",
        "https://api.github.com/repos/owner/lookalike/releases": "https://api.github.com.evil.test/releases",
        "https://api.github.com/repos/owner/userinfo/releases": "https://github.com@evil.test/releases",
        "https://api.github.com/repos/owner/plain/releases": "http://api.github.com/repos/owner/plain/releases",
        "https://api.github.com/hop/1": "https://api.github.com/hop/2",
        "https://api.github.com/hop/2": "https://github.com/hop/3",
        "https://github.com/hop/3": "https://api.github.com/hop/4",
        "https://api.github.com/hop/4": "https://github.com/hop/5",
    ]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        if let next = Self.routes[url.absoluteString], let target = URL(string: next) {
            var redirected = request
            redirected.url = target
            let moved = HTTPURLResponse(url: url, statusCode: 301, httpVersion: "HTTP/1.1", headerFields: ["Location": next])!
            client.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: moved)
            return
        }
        let reply = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client.urlProtocol(self, didReceive: reply, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data("\(url.absoluteString) \(request.value(forHTTPHeaderField: "User-Agent") ?? "")".utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite struct ReleaseFeedRedirectTests {
    private let session = URLSession(configuration: .ephemeral)

    private static func transport() -> ReleaseFeedTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubStub.self]
        return ReleaseFeedTransport(userAgent: "OpenHumanMail/9.9", configuration: configuration)
    }

    private static func fetch(_ url: String) async throws -> String {
        let reply = try await ReleaseFeedClient(transport: transport()).fetch(URL(string: url)!)
        return String(decoding: reply.body, as: UTF8.self)
    }

    private func hop(_ delegate: ReleaseFeedRedirects, from source: String, to target: String) async -> (URLRequest?, URLSessionTask) {
        let request = URLRequest(url: URL(string: source)!)
        let task = session.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": target])!
        var next = request
        next.url = URL(string: target)!
        let decision = await delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next)
        return (decision, task)
    }

    @Test func theDelegateFollowsExactlyWhatTheRuleAllows() async {
        let source = UpdateFeed.openHuman.releasesURL
        let targets = [
            "https://api.github.com/repositories/1/releases", "https://github.com/michaelmagan/OpenHuman/releases/download/v1/a.zip",
            "https://evil.test/releases", "https://api.github.com.evil.test/releases", "https://github.com@evil.test/releases",
            "https://user:@github.com/releases", "https://github.com:8443/releases", "http://github.com/releases",
        ]
        for target in targets {
            let delegate = ReleaseFeedRedirects()
            let (decision, task) = await hop(delegate, from: source.absoluteString, to: target)
            defer { task.cancel() }
            let allowed = UpdateFeed.allowsRedirect(from: source, to: URL(string: target)!, count: 1)
            #expect(decision?.url?.absoluteString == (allowed ? target : nil), "\(target)")
            #expect(delegate.refused == !allowed, "\(target)")
            #expect((task.state != .suspended) == !allowed, "a refused hop cancels the request: \(target)")
        }
    }

    @Test func theDelegateRefusesTheFourthHop() async {
        let delegate = ReleaseFeedRedirects()
        let chain = ["https://api.github.com/a", "https://github.com/b", "https://api.github.com/c", "https://github.com/d",
                     "https://api.github.com/e"]
        for index in 0..<UpdateFeed.maxRedirects {
            let (decision, task) = await hop(delegate, from: chain[index], to: chain[index + 1])
            task.cancel()
            #expect(decision != nil, "hop \(index + 1)")
        }
        #expect(!delegate.refused)
        let (fourth, task) = await hop(delegate, from: chain[3], to: chain[4])
        #expect(fourth == nil && delegate.refused && task.state != .suspended)
    }

    @Test func aRedirectWithinGitHubIsFollowed() async throws {
        #expect(try await Self.fetch("https://api.github.com/repos/owner/moved/releases")
                == "https://api.github.com/repositories/1/releases OpenHumanMail/9.9")
        #expect(try await Self.fetch("https://api.github.com/hop/2") == "https://github.com/hop/5 OpenHumanMail/9.9",
                "three hops are followed")
    }

    @Test(arguments: ["repos/owner/away/releases", "repos/owner/lookalike/releases", "repos/owner/userinfo/releases",
                      "repos/owner/plain/releases", "hop/1"])
    func aRedirectOffGitHubOrPastThreeHopsEndsTheCheck(_ path: String) async {
        await #expect(throws: UpdateFeedFailure.redirectRefused) {
            _ = try await Self.fetch("https://api.github.com/\(path)")
        }
    }

    @Test func theRequestKeepsNothingAndCarriesOnlyTheFixedUserAgent() async throws {
        let configuration = Self.transport().session.configuration
        #expect(configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil && configuration.urlCredentialStorage == nil)
        #expect(try await Self.fetch("https://api.github.com/repos/owner/direct/releases")
                == "https://api.github.com/repos/owner/direct/releases OpenHumanMail/9.9")
    }

    @Test func networkErrorsKeepTheirMeaning() {
        let cases: [(URLError.Code, TransportError)] = [
            (.timedOut, .timedOut), (.notConnectedToInternet, .notConnected), (.dataNotAllowed, .notConnected),
            (.cannotFindHost, .cannotConnect), (.cannotConnectToHost, .cannotConnect), (.dnsLookupFailed, .cannotConnect),
            (.cancelled, .cancelled), (.badServerResponse, .other("URLError \(URLError.Code.badServerResponse.rawValue)")),
        ]
        for (code, expected) in cases {
            #expect(ReleaseFeedTransport.map(URLError(code)) == expected, "\(code)")
        }
        #expect(ReleaseFeedTransport.map(CancellationError()) == .cancelled)
    }
}
