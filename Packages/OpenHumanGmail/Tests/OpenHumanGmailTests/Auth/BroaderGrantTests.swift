import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanGmail

@Suite struct BroaderGrantTests {
    private static let me = "me@example.com"

    private func api() -> FakeHTTPTransport {
        let http = FakeHTTPTransport()
        http.on("GET", "/gmail/v1/users/me/labels") { _ in FakeHTTPTransport.json(200, ["labels": []]) }
        http.on("POST", "/gmail/v1/users/me/threads/") { request in
            let id = request.url.pathComponents.dropLast().last ?? ""
            return FakeHTTPTransport.json(200, ["id": id, "messages": [["id": "m1", "threadId": id]]])
        }
        return http
    }

    @Test func aBroaderGrantOnRefreshNeverReachesGmailAndTheClientIsDropped() async throws {
        let clock = TestClock()
        let stored = Synthetic.token(refresh: "r", access: "first", expiry: clock.now.addingTimeInterval(3600),
                                     scopes: [GmailScope.modify])
        let tokenStore = InMemoryTokenStore([Self.me: stored])
        let grant = Mutex(GmailScope.modify)
        let tokenEndpoint = ScriptedTransport { _ in
            jsonResponse(200, ["access_token": "refreshed", "expires_in": 3600, "scope": grant.withLock { $0 }])
        }
        let events = EventLog()
        let credentials = AccountCredentials(store: tokenStore, client: Synthetic.client, transport: tokenEndpoint,
                                             clock: clock, onEvent: events.sink)
        let wire = api()
        let factory = DefaultGmailClientFactory(safeMode: .normal, accountCredentials: credentials, apiTransport: wire,
                                                config: GmailClientConfig(userAgent: "t"), clock: clock)
        let client = try factory.gmailClient(for: Self.me)
        _ = try await client.listLabels()
        #expect(try factory.gmailClient(for: Self.me) === client, "same grant: the cached client")

        clock.advance(by: .seconds(3600))
        grant.withLock { $0 = "\(GmailScope.modify) https://mail.google.com/" }
        await #expect(throws: GmailError.reauthRequired) { _ = try await client.trashThread(id: "t1") }
        #expect(wire.requests.count == 1, "the request that needed the broader token never left the process")
        #expect(events.all == [.needsReauth(account: Self.me, reason: .broaderGrant)])
        #expect(try tokenStore.load(account: Self.me) == nil)
        #expect(throws: GmailError.reauthRequired) { _ = try factory.client(for: Self.me) }
        await #expect(throws: GmailError.reauthRequired) { _ = try await client.listLabels() }
        #expect(tokenEndpoint.requests.count == 1 && wire.requests.count == 1)

        grant.withLock { $0 = GmailScope.modify }
        try await credentials.save(Synthetic.result(email: Self.me, token: Synthetic.token(
            refresh: "r2", access: "signed-in", expiry: clock.now.addingTimeInterval(3600), scopes: [GmailScope.modify])))
        let fresh = try factory.gmailClient(for: Self.me)
        #expect(fresh !== client)
        _ = try await fresh.trashThread(id: "t1")
        #expect(wire.requests.count == 2)
    }

    @Test func theFactoryNeverHandsOutAClientBuiltForAnotherGrant() async throws {
        let scopes = Mutex<[String]?>([GmailScope.modify])
        let wire = api()
        let factory = DefaultGmailClientFactory(safeMode: .normal, apiTransport: wire,
                                                config: GmailClientConfig(userAgent: "t"), clock: InstantClock()) { _ in
            guard let granted = scopes.withLock({ $0 }) else { throw GmailError.reauthRequired }
            return (StaticTokenProvider(), granted)
        }
        let writer = try factory.gmailClient(for: Self.me)
        _ = try await writer.trashThread(id: "t1")
        #expect(wire.requests.count == 1)

        scopes.withLock { $0 = [GmailScope.readonly] }
        let reader = try factory.gmailClient(for: Self.me)
        #expect(reader !== writer)
        #expect(try factory.effectiveMode(for: Self.me) == .readOnly)
        await #expect(throws: GmailError.transport(.blockedBySafeMode("POST /gmail/v1/users/me/threads/t1/trash"))) {
            _ = try await reader.trashThread(id: "t1")
        }
        #expect(wire.requests.count == 1)

        scopes.withLock { $0 = nil }
        #expect(throws: GmailError.reauthRequired) { _ = try factory.client(for: Self.me) }
        scopes.withLock { $0 = [GmailScope.readonly] }
        #expect(try factory.gmailClient(for: Self.me) !== reader, "nothing was kept across the failure")
    }
}
