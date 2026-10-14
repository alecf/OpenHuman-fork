import Foundation
import MailFakes
import MailModel
import Testing
@testable import MailFeatures

@MainActor
struct AIConnectionsTests {
    private func make() -> (AIConnectionsModel, FakeAIConnections, InMemorySecretStore) {
        let port = FakeAIConnections()
        let secrets = InMemorySecretStore()
        return (AIConnectionsModel(port: port, secrets: secrets, now: { Date(timeIntervalSince1970: 1_791_000_000) }), port, secrets)
    }

    @Test func savingAProviderSendsNothingAndSelectsNothing() async throws {
        let (model, port, secrets) = make()
        let cli = await model.save(AIConnectionDraft(title: "Claude Code", kind: .agentCLI, binaryPath: "/usr/local/bin/claude"))
        let keyed = await model.save(AIConnectionDraft(title: "My provider", kind: .apiKey), apiKey: "sk-test-1234567890")
        #expect(cli != nil && keyed != nil)
        #expect(port.providerContacts.isEmpty, "saving contacted no provider")
        #expect(port.log == ["save", "save"], "the only port call is the configuration write")
        #expect(model.connections.count == 2)
        #expect(model.connections.allSatisfy { !$0.isInUse && $0.consentGrantedAt == nil }, "saving never selects")
        #expect(model.consent == nil)
        let edited = await model.save(AIConnectionDraft(id: cli?.id, title: "Claude Code (work)", kind: .agentCLI))
        #expect(edited?.isInUse == false)
        #expect(secrets.names == ["ai.connection.\(keyed!.id)"])
    }

    @Test func theKeyLivesOnlyInTheSecretStore() async throws {
        let (model, port, secrets) = make()
        let key = "sk-live-ABCDEF0123456789"
        let saved = try #require(await model.save(AIConnectionDraft(title: "Provider", kind: .apiKey), apiKey: key))
        #expect(saved.hasKey)
        #expect(secrets.value(for: AIConnectionsModel.secretName(saved.id)) == key)
        let everything = String(describing: await port.connections()) + String(describing: model.connections)
            + String(describing: model.errorMessage) + port.log.joined()
        #expect(!everything.contains(key), "the key is in no connection record, error or log")
        let again = try #require(await model.save(AIConnectionDraft(id: saved.id, title: "Provider 2", kind: .apiKey), apiKey: ""))
        #expect(again.hasKey && secrets.value(for: AIConnectionsModel.secretName(saved.id)) == key)
        await model.remove(saved.id)
        #expect(!secrets.hasSecret(for: AIConnectionsModel.secretName(saved.id)) && model.connections.isEmpty)
    }

    @Test func useAsksFirstAndOnlyAcceptingSelectsTheConnection() async throws {
        let (model, port, _) = make()
        let saved = try #require(await model.save(AIConnectionDraft(title: "Codex", kind: .agentCLI)))
        model.askToUse(saved.id)
        let request = try #require(model.consent)
        #expect(request.connectionID == saved.id && request.title == "Use Codex?")
        #expect(request.leaves.contains { $0.contains("text of the email") } && !request.stays.isEmpty)
        model.decline()
        #expect(model.consent == nil && model.connections.first?.isInUse == false)
        #expect(!port.log.contains("use"))
        model.askToUse(saved.id)
        await model.accept()
        let used = try #require(model.connections.first)
        #expect(used.isInUse && used.consentGrantedAt == Date(timeIntervalSince1970: 1_791_000_000))
        model.askToUse(saved.id)
        #expect(model.consent == nil, "already in use: not asked again")
        await model.stopUsing(saved.id)
        #expect(model.connections.first?.isInUse == false)
    }

    @Test func thePortRefusesToSelectWithoutConsentAndEveryKindAsksFirst() async throws {
        let (model, port, _) = make()
        let saved = try #require(await model.save(AIConnectionDraft(title: "PCC", kind: .privateCloud)))
        await #expect(throws: MailPortError.self) { try await port.setInUse(saved.id, inUse: true, consentGrantedAt: nil) }
        for kind in AIConnectionKind.allCases {
            #expect(kind.leavesMac, "\(kind) needs the consent sheet")
            let connection = AIConnection(id: "x", title: "T", kind: kind)
            #expect(!AIConnectionsModel.consentRequest(for: connection).leaves.isEmpty)
        }
    }

    @Test func aNameIsRequired() async {
        let (model, port, _) = make()
        #expect(await model.save(AIConnectionDraft(title: "  ", kind: .agentCLI)) == nil)
        #expect(model.errorMessage == "Give the connection a name." && port.log.isEmpty)
    }
}
