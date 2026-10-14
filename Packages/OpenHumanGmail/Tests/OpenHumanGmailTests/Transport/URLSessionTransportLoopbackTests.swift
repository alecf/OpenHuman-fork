#if canImport(Network)
import Foundation
import Synchronization
import Testing
@testable import OpenHumanGmail

@Suite struct URLSessionTransportLoopbackTests {
    private func transport() -> URLSessionTransport { URLSessionTransport(userAgent: "OpenHumanMail/test") }

    private func request(_ server: LoopbackHTTPServer, _ path: String = "/gmail/v1/users/me/profile", method: String = "GET",
                         body: Data? = nil, headers: [String: String] = [:],
                         timeout: Duration = .seconds(10)) -> HTTPRequest {
        HTTPRequest(method: method, url: URL(string: server.url.absoluteString + path)!, headers: headers, body: body,
                    timeout: timeout)
    }

    @Test func roundTripLowercasesHeadersAndNeverThrowsForStatusCodes() async throws {
        let server = try await LoopbackHTTPServer.start { _ in
            .response(status: 429, headers: ["Retry-After": "7", "X-Custom": "A"], body: Data("{\"e\":1}".utf8))
        }
        defer { server.stop() }
        let response = try await transport().send(request(server, headers: ["Authorization": "Bearer t"]))
        #expect(response.status == 429)
        #expect(response.headers["retry-after"] == "7" && response.headers["x-custom"] == "A")
        #expect(String(decoding: response.body, as: UTF8.self) == "{\"e\":1}")
        let seen = try #require(server.requests.first)
        #expect(seen.headers["authorization"] == "Bearer t")
        #expect(seen.headers["user-agent"] == "OpenHumanMail/test (gzip)")
    }

    @Test func postBodyAndContentTypeArrive() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .response(status: 200, body: Data("{}".utf8)) }
        defer { server.stop() }
        let body = Data("--b\r\nbinary\u{0}bytes\r\n--b--".utf8)
        _ = try await transport().send(request(server, "/batch/gmail/v1", method: "POST", body: body,
                                               headers: ["Content-Type": "multipart/mixed; boundary=b"]))
        let seen = try #require(server.requests.first)
        #expect(seen.method == "POST" && seen.body == body && seen.headers["content-type"] == "multipart/mixed; boundary=b")
    }

    @Test func gzipResponsesAreDecodedAndAcceptEncodingIsOffered() async throws {
        let json = Data(String(repeating: "{\"id\":\"abc\"},", count: 200).utf8)
        let server = try await LoopbackHTTPServer.start { _ in
            .response(status: 200, headers: ["Content-Encoding": "gzip", "Content-Type": "application/json"], body: gzipped(json))
        }
        defer { server.stop() }
        let response = try await transport().send(request(server))
        #expect(response.body == json)
        #expect(server.requests.first?.headers["accept-encoding"]?.contains("gzip") == true)
    }

    @Test func callerCannotOverrideTheUserAgentOrSuppressCompression() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .response(status: 200) }
        defer { server.stop() }
        _ = try await transport().send(request(server, headers: ["User-Agent": "evil", "Accept-Encoding": "identity"]))
        let seen = try #require(server.requests.first)
        #expect(seen.headers["user-agent"] == "OpenHumanMail/test (gzip)")
        #expect(seen.headers["accept-encoding"]?.contains("gzip") == true)
    }

    @Test func noCookiesAreKeptBetweenRequests() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .response(status: 200, headers: ["Set-Cookie": "sid=1; Path=/"]) }
        defer { server.stop() }
        let t = transport()
        _ = try await t.send(request(server))
        _ = try await t.send(request(server))
        #expect(server.requests.count == 2 && server.requests.allSatisfy { $0.headers["cookie"] == nil })
    }

    @Test func sequentialRequestsReuseOneConnection() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .response(status: 200, body: Data("{}".utf8)) }
        defer { server.stop() }
        let t = transport()
        for _ in 0..<5 { _ = try await t.send(request(server)) }
        #expect(server.requests.count == 5)
        #expect(server.connectionCount == 1)
    }

    @Test func idleTimeoutMapsToTimedOut() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .hang }
        defer { server.stop() }
        await #expect(throws: TransportError.timedOut) {
            _ = try await transport().send(request(server, timeout: .milliseconds(300)))
        }
    }

    @Test func aTricklingServerHitsTheTotalDeadline() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .trickle(interval: 0.05) }
        defer { server.stop() }
        await #expect(throws: TransportError.timedOut) {
            _ = try await transport().send(request(server, timeout: .milliseconds(400)))
        }
    }

    @Test func cancellationMapsToCancelledAndStopsWaiting() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .hang }
        defer { server.stop() }
        let t = transport()
        let req = request(server)
        let task = Task { try await t.send(req) }
        while server.requests.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await task.value }
    }

    @Test func aCancelledTaskNeverStartsARequest() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .response(status: 200) }
        defer { server.stop() }
        let t = transport()
        let req = request(server)
        let task = Task { () throws -> HTTPResponse in
            while !Task.isCancelled { await Task.yield() }
            return try await t.send(req)
        }
        task.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await task.value }
        #expect(server.requests.isEmpty)
    }

    @Test func connectionRefusedIsCannotConnect() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .response(status: 200) }
        let dead = request(server)
        server.stop()
        await #expect(throws: TransportError.cannotConnect) { _ = try await transport().send(dead) }
    }

    @Test func aSocketClosedWithoutAnAnswerIsConnectionLostOrOther() async throws {
        let server = try await LoopbackHTTPServer.start { _ in .close }
        defer { server.stop() }
        do {
            _ = try await transport().send(request(server))
            Issue.record("expected a transport error")
        } catch let error as TransportError {
            switch error {
            case .connectionLost(requestMayHaveBeenSent: true), .other: break
            default: Issue.record("unexpected \(error)")
            }
        }
    }

    @Test func manyConcurrentRequestsAllComplete() async throws {
        let server = try await LoopbackHTTPServer.start { request in .response(status: 200, body: Data(request.path.utf8)) }
        defer { server.stop() }
        let t = transport()
        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for n in 0..<40 {
                let req = request(server, "/p\(n)")
                group.addTask { String(decoding: try await t.send(req).body, as: UTF8.self) }
            }
            var all: Set<String> = []
            for try await path in group { all.insert(path) }
            return all
        }
        #expect(results == Set((0..<40).map { "/p\($0)" }))
        #expect(server.connectionCount <= 8)
    }

    @Test func userAgentGzipMarker() {
        #expect(URLSessionTransport.userAgentWithGzip("OpenHumanMail/1 (gzip)") == "OpenHumanMail/1 (gzip)")
        #expect(URLSessionTransport.userAgentWithGzip("OpenHumanMail/1") == "OpenHumanMail/1 (gzip)")
    }

    @Test func extraURLErrorMapping() {
        #expect(URLSessionTransport.map(URLError(.dataNotAllowed)) == .notConnected)
        if case .tls = URLSessionTransport.map(URLError(.appTransportSecurityRequiresSecureConnection)) {} else { Issue.record("tls") }
    }
}
#endif
