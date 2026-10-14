import Foundation
import Network
import OpenHumanGmail
import Synchronization
import Testing
@testable import OpenHumanGmailApple

private func rawStatus(port: UInt16, _ request: String) async -> Int? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Int?, Never>) in
        let done = Mutex(false)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        @Sendable func finish(_ status: Int?) {
            let first = done.withLock { d -> Bool in
                defer { d = true }
                return !d
            }
            guard first else { return }
            connection.cancel()
            continuation.resume(returning: status)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                        let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                        let parts = text.split(separator: " ", maxSplits: 2)
                        finish(parts.count >= 2 && parts[0].hasPrefix("HTTP/1.") ? Int(parts[1]) : nil)
                    }
                })
            case .failed, .cancelled: finish(nil)
            case .waiting: finish(nil)
            default: break
            }
        }
        connection.start(queue: .global())
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
    }
}

private func get(_ port: UInt16, _ target: String, host: String? = nil) -> String {
    "GET \(target) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\nConnection: close\r\n\r\n"
}

@Suite(.serialized) struct NWLoopbackReceiverHardeningTests {
    private static let html = "<!doctype html><p>done</p>"

    @Test func aForgedCallbackIsIgnoredAndTheRealOneStillArrives() async throws {
        let receiver = NWLoopbackReceiver()
        let port = try #require(try await receiver.start().port.map(UInt16.init))
        await receiver.expectState("the-real-state")
        let waiter = Task { try await receiver.waitForCallback(timeout: .seconds(10), successHTML: Self.html) }

        #expect(await rawStatus(port: port, get(port, "/oauth2callback?code=evil&state=forged")) == 400)
        #expect(await rawStatus(port: port, get(port, "/oauth2callback?code=evil")) == 400)
        #expect(await rawStatus(port: port, get(port, "/oauth2callback?code=a&code=b&state=the-real-state")) == 400)
        #expect(await rawStatus(port: port, get(port, "/oauth2callback?state=the-real-state&state=forged&code=x")) == 400)
        #expect(await rawStatus(port: port, get(port, "/oauth2callback?code=good&state=the-real-state")) == 200)

        let components = try await waiter.value
        #expect(components.queryItems?.first { $0.name == "code" }?.value == "good")
        #expect(await rawStatus(port: port, get(port, "/oauth2callback?code=late&state=the-real-state")) != 200)
        await receiver.stop()
    }

    @Test func onlyRequestsAddressedTo127_0_0_1AndThisPortAreServed() async throws {
        let receiver = NWLoopbackReceiver()
        let port = try #require(try await receiver.start().port.map(UInt16.init))
        await receiver.expectState("s")
        let target = "/oauth2callback?code=c&state=s"
        for host in ["evil.example:\(port)", "localhost:\(port)", "127.0.0.1:\(port &+ 1)", "127.0.0.1", ""] {
            #expect(await rawStatus(port: port, get(port, target, host: host)) == 400, "\(host)")
        }
        #expect(await rawStatus(port: port, "GET \(target) HTTP/1.1\r\nConnection: close\r\n\r\n") == 400)
        #expect(await rawStatus(port: port, "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n"
                                + "Host: evil.example\r\n\r\n") == 400)
        #expect(await rawStatus(port: port, "GET \(target) HTTP/2.0\r\nHost: 127.0.0.1:\(port)\r\n\r\n") == 400)
        #expect(await rawStatus(port: port, get(port, target)) == 200)
        let components = try await receiver.waitForCallback(timeout: .seconds(5), successHTML: Self.html)
        #expect(components.queryItems?.first { $0.name == "code" }?.value == "c")
        await receiver.stop()
    }

    @Test func aReceiverIsSingleUse() async throws {
        let receiver = NWLoopbackReceiver()
        _ = try await receiver.start()
        await #expect(throws: OAuthError.denied("loopback_receiver_reused")) { _ = try await receiver.start() }
        await receiver.stop()
        await #expect(throws: OAuthError.denied("loopback_receiver_reused")) { _ = try await receiver.start() }
    }

    @Test func theTimeoutClosesTheListener() async throws {
        let receiver = NWLoopbackReceiver()
        let port = try #require(try await receiver.start().port.map(UInt16.init))
        await #expect(throws: OAuthError.timedOut) {
            _ = try await receiver.waitForCallback(timeout: .milliseconds(200), successHTML: Self.html)
        }
        #expect(await rawStatus(port: port, get(port, "/oauth2callback?code=c&state=s")) != 200)
        await #expect(throws: OAuthError.cancelled) {
            _ = try await receiver.waitForCallback(timeout: .seconds(1), successHTML: Self.html)
        }
        await receiver.stop()
    }

    @Test func requestClassification() {
        let port: UInt16 = 50000
        func classify(_ text: String) -> NWLoopbackReceiver.Verdict {
            NWLoopbackReceiver.classify(head: Data(text.utf8), port: port)
        }
        guard case .callback(let components) = classify(get(port, "/oauth2callback?code=c&state=s")) else {
            Issue.record("expected a callback")
            return
        }
        #expect(components.path == "/oauth2callback")
        #expect(classify(get(port, "/favicon.ico")) == .reject("404 Not Found"))
        #expect(classify("POST /oauth2callback HTTP/1.1\r\nHost: 127.0.0.1:50000\r\n\r\n") == .reject("405 Method Not Allowed"))
        #expect(classify("GET /oauth2callback\r\nHost: 127.0.0.1:50000\r\n\r\n") == .reject("400 Bad Request"))
        #expect(classify("GET http://evil/oauth2callback HTTP/1.1\r\nHost: 127.0.0.1:50000\r\n\r\n")
                == .reject("400 Bad Request"))
        #expect(classify("GET /oauth2callback HTTP/1.1\nhost: 127.0.0.1:50000\n\n") != .reject("400 Bad Request"))
        #expect(NWLoopbackReceiver.classify(head: Data(get(port, "/oauth2callback").utf8), port: nil)
                == .reject("400 Bad Request"))
    }

    @Test func callbackParameterRules() {
        func components(_ query: String) -> URLComponents { URLComponents(string: "http://127.0.0.1/oauth2callback?\(query)")! }
        #expect(NWLoopbackReceiver.isValidCallback(components("code=c&state=s"), expected: "s"))
        #expect(NWLoopbackReceiver.isValidCallback(components("error=access_denied&state=s"), expected: "s"))
        #expect(!NWLoopbackReceiver.isValidCallback(components("code=c&state=t"), expected: "s"))
        #expect(!NWLoopbackReceiver.isValidCallback(components("code=c"), expected: "s"))
        #expect(!NWLoopbackReceiver.isValidCallback(components("code=c&state=s&state=s"), expected: "s"))
        #expect(!NWLoopbackReceiver.isValidCallback(components("code=c&code=d&state=s"), expected: "s"))
        #expect(!NWLoopbackReceiver.isValidCallback(components("error=a&error=b&state=s"), expected: "s"))
        #expect(NWLoopbackReceiver.isValidCallback(components("code=c"), expected: nil))
        #expect(NWLoopbackReceiver.constantTimeEquals("abc", "abc"))
        #expect(!NWLoopbackReceiver.constantTimeEquals("abc", "abd") && !NWLoopbackReceiver.constantTimeEquals("abc", "ab"))
    }

    @Test func onlyLoopbackPeersAreAccepted() {
        #expect(NWLoopbackReceiver.isLoopbackPeer(.hostPort(host: .ipv4(.loopback), port: 1234)))
        #expect(!NWLoopbackReceiver.isLoopbackPeer(.hostPort(host: .ipv4(IPv4Address("127.0.0.9")!), port: 1234)))
        #expect(!NWLoopbackReceiver.isLoopbackPeer(.hostPort(host: .ipv4(IPv4Address("192.168.1.20")!), port: 1234)))
        #expect(!NWLoopbackReceiver.isLoopbackPeer(.hostPort(host: .name("localhost", nil), port: 1234)))
        #expect(!NWLoopbackReceiver.isLoopbackPeer(.hostPort(host: .ipv6(.loopback), port: 1234)))
    }
}
