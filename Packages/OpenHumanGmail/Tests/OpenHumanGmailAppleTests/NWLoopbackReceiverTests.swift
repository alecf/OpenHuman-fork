import Foundation
import OpenHumanGmail
import Testing
@testable import OpenHumanGmailApple

@Suite(.serialized) struct NWLoopbackReceiverTests {
    private static let html = "<!doctype html><p>done</p>"

    private func get(_ url: URL) async -> (Int, String)? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else { return nil }
        return (http.statusCode, String(decoding: data, as: UTF8.self))
    }

    private func callbackURL(_ redirect: URL, query: String) -> URL {
        URL(string: redirect.absoluteString + "?" + query)!
    }

    @Test func bindsIPv4LoopbackOnEphemeralPort() async throws {
        let receiver = NWLoopbackReceiver()
        let redirect = try await receiver.start()
        defer { Task { await receiver.stop() } }
        #expect(redirect.scheme == "http")
        #expect(redirect.host == "127.0.0.1")
        #expect((redirect.port ?? 0) > 0)
        #expect(redirect.path == "/oauth2callback")
        let v6 = URL(string: "http://[::1]:\(redirect.port!)/oauth2callback?code=x&state=y")!
        #expect(await get(v6) == nil)
        await receiver.stop()
    }

    @Test func ignoresFaviconAndDeliversFirstCallback() async throws {
        let receiver = NWLoopbackReceiver()
        let redirect = try await receiver.start()
        let waiter = Task { try await receiver.waitForCallback(timeout: .seconds(10), successHTML: Self.html) }

        let favicon = URL(string: "http://127.0.0.1:\(redirect.port!)/favicon.ico")!
        #expect(await get(favicon)?.0 == 404)

        let reply = await get(callbackURL(redirect, query: "code=c0de&state=st4te"))
        #expect(reply?.0 == 200)
        #expect(reply?.1 == Self.html)

        let components = try await waiter.value
        #expect(components.path == "/oauth2callback")
        #expect(components.queryItems?.first { $0.name == "code" }?.value == "c0de")
        #expect(components.queryItems?.first { $0.name == "state" }?.value == "st4te")

        let second = await get(callbackURL(redirect, query: "code=other&state=st4te"))
        #expect(second?.0 != 200)
        await receiver.stop()
    }

    @Test func callbackBeforeWaitIsBuffered() async throws {
        let receiver = NWLoopbackReceiver()
        let redirect = try await receiver.start()
        let reply = await get(callbackURL(redirect, query: "code=early&state=s"))
        #expect(reply?.0 == 200)
        let components = try await receiver.waitForCallback(timeout: .seconds(5), successHTML: Self.html)
        #expect(components.queryItems?.first { $0.name == "code" }?.value == "early")
        await receiver.stop()
    }

    @Test func nonGETIsRejectedAndNotDelivered() async throws {
        let receiver = NWLoopbackReceiver()
        let redirect = try await receiver.start()
        var request = URLRequest(url: callbackURL(redirect, query: "code=c&state=s"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        let session = URLSession(configuration: .ephemeral)
        let (_, response) = try await session.data(for: request)
        session.invalidateAndCancel()
        #expect((response as? HTTPURLResponse)?.statusCode == 405)
        await #expect(throws: OAuthError.timedOut) {
            _ = try await receiver.waitForCallback(timeout: .milliseconds(300), successHTML: Self.html)
        }
        await receiver.stop()
    }

    @Test func timesOut() async throws {
        let receiver = NWLoopbackReceiver()
        _ = try await receiver.start()
        await #expect(throws: OAuthError.timedOut) {
            _ = try await receiver.waitForCallback(timeout: .milliseconds(200), successHTML: Self.html)
        }
        await receiver.stop()
    }

    @Test func stopCancelsWaiter() async throws {
        let receiver = NWLoopbackReceiver()
        _ = try await receiver.start()
        let waiter = Task { try await receiver.waitForCallback(timeout: .seconds(30), successHTML: Self.html) }
        try await Task.sleep(for: .milliseconds(100))
        await receiver.stop()
        await #expect(throws: OAuthError.cancelled) { _ = try await waiter.value }
    }

    @Test func taskCancellationCancelsWaiter() async throws {
        let receiver = NWLoopbackReceiver()
        _ = try await receiver.start()
        let waiter = Task { try await receiver.waitForCallback(timeout: .seconds(30), successHTML: Self.html) }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        await #expect(throws: OAuthError.cancelled) { _ = try await waiter.value }
        await receiver.stop()
    }

    @Test func headerEndDetection() {
        #expect(NWLoopbackReceiver.headerEnd(in: Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) == 27)
        #expect(NWLoopbackReceiver.headerEnd(in: Data("GET / HTTP/1.1\nHost: x\n\n".utf8)) == 24)
        #expect(NWLoopbackReceiver.headerEnd(in: Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)) == nil)
    }
}
