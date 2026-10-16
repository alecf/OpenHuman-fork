import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Synchronization
import Testing
@testable import OpenHumanGmail

@Suite struct ClientFactoryGuardTests {
    private func makeFactory(_ transport: any HTTPTransport, gate: SendRecipientGate? = nil,
                         tokens: StaticTokenProvider = StaticTokenProvider(),
                         scopes: @escaping @Sendable () -> [String] = { [GmailScope.modify] }) -> DefaultGmailClientFactory {
        DefaultGmailClientFactory(apiTransport: transport, config: GmailClientConfig(userAgent: "t"), clock: InstantClock(),
                                  recipientGate: gate) { _ in (tokens, scopes()) }
    }

    @Test func everyClientIsBehindTheDenyListExactlyOnce() async throws {
        let gate = SendRecipientGate()
        let inner = ScriptedTransport()
        let factory = makeFactory(inner, gate: gate)
        for email in ["robin@example.com", "dana@example.org"] {
            let client = try factory.gmailClient(for: email)
            let outer = try #require(client.executor.transport as? DenyListTransport, "\(email)")
            #expect(outer.recipients === gate)
            #expect(!(outer.wrapped is DenyListTransport), "\(email): one deny list, not two")
            #expect((outer.wrapped as? ScriptedTransport) === inner)
            let delete = GmailRequests.request("DELETE", GmailRequests.api + "messages/m1")
            await #expect(throws: TransportError.refusedByGuard("DELETE /gmail/v1/users/me/messages/m1")) {
                _ = try await client.executor.transport.send(delete)
            }
        }
        #expect(inner.requests.isEmpty, "a permanent delete never reached the wire")
    }

    @Test func wrappingIsNotDoubled() throws {
        let gate = SendRecipientGate()
        let inner = ScriptedTransport()
        let alreadyGuarded = DenyListTransport(wrapping: inner, recipients: gate)
        let client = try makeFactory(alreadyGuarded, gate: gate).gmailClient(for: "robin@example.com")
        let outer = try #require(client.executor.transport as? DenyListTransport)
        #expect(outer.recipients === gate)
        #expect((outer.wrapped as? ScriptedTransport) === inner, "a transport already behind the deny list is reused")

        let once = DefaultGmailClientFactory.guarded(inner, recipients: gate)
        let twice = DefaultGmailClientFactory.guarded(once, recipients: gate)
        #expect(twice.recipients === gate && (twice.wrapped as? ScriptedTransport) === inner)
        let ungated = DefaultGmailClientFactory.guarded(inner, recipients: nil)
        #expect(ungated.recipients == nil && (ungated.wrapped as? ScriptedTransport) === inner)
    }

    @Test func aGrantWithoutModifyNeedsReauthBeforeAnyRequest() {
        for scopes in [[GmailScope.readonly], [], ["openid", "email"], ["https://mail.google.com/"],
                       [GmailScope.readonly, "https://www.googleapis.com/auth/gmail.send"]] {
            let inner = ScriptedTransport()
            let tokens = StaticTokenProvider()
            let factory = makeFactory(inner, tokens: tokens, scopes: { scopes })
            #expect(throws: GmailError.reauthRequired, "\(scopes)") { _ = try factory.client(for: "robin@example.com") }
            #expect(throws: GmailError.reauthRequired, "\(scopes)") { _ = try factory.gmailClient(for: "robin@example.com") }
            #expect(inner.requests.isEmpty, "\(scopes): nothing was sent")
            #expect(tokens.calls == 0, "\(scopes): no token was fetched")
        }
    }

    @Test func losingModifyDropsTheCachedClient() async throws {
        let inner = ScriptedTransport { _ in jsonResponse(200, ["labels": [Any]()]) }
        let granted = Mutex([GmailScope.modify])
        let factory = makeFactory(inner, scopes: { granted.withLock { $0 } })
        let first = try factory.gmailClient(for: "robin@example.com")
        _ = try await first.listLabels()
        #expect(inner.requests.count == 1)

        granted.withLock { $0 = [GmailScope.readonly] }
        #expect(throws: GmailError.reauthRequired) { _ = try factory.gmailClient(for: "robin@example.com") }
        #expect(inner.requests.count == 1)

        granted.withLock { $0 = [GmailScope.modify] }
        #expect(try factory.gmailClient(for: "robin@example.com") !== first, "nothing was kept across the refusal")
    }
}
