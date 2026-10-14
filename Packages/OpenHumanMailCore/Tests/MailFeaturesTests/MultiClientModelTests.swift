import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private final class ClientChoiceAccounts: AccountManaging {
    private struct State {
        var clients: [(id: String, short: String, secret: Bool)]
        var selected: String?
        var perAccount: [AccountID: String] = [:]
        var selections: [String?] = []
        var signInsWith: [String?] = []
    }
    private let state: Mutex<State>

    init(clients: [(id: String, short: String, secret: Bool)], perAccount: [AccountID: String] = [:]) {
        state = Mutex(State(clients: clients, perAccount: perAccount))
    }

    var selections: [String?] { state.withLock { $0.selections } }
    var signInsWith: [String?] { state.withLock { $0.signInsWith } }

    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        let (stream, continuation) = AsyncStream<OAuthClientStatus>.makeStream()
        continuation.yield(.configured(source: .file))
        return stream
    }

    func importOAuthClient(json: Data) async throws {
        guard let text = String(data: json, encoding: .utf8), text.hasPrefix("client:") else {
            throw AccountSetupError(.clientMissing, "That file isn't a Google sign-in client file.")
        }
        let short = String(text.dropFirst("client:".count))
        state.withLock { s in
            s.clients.append((id: "key-\(short)", short: short, secret: true))
            s.selected = "key-\(short)"
        }
    }

    func oauthClients() async -> [OAuthClientSummary] {
        state.withLock { s in
            s.clients.enumerated().map { index, client in
                OAuthClientSummary(id: client.id, shortID: client.short, isDefault: index == 0,
                                   isSelected: client.id == (s.selected ?? s.clients.first?.id), hasSecret: client.secret)
            }
        }
    }

    func selectOAuthClient(_ id: OAuthClientSummary.ID?) async throws {
        try state.withLock { s in
            s.selections.append(id)
            guard id == nil || s.clients.contains(where: { $0.id == id }) else {
                throw AccountSetupError(.clientMissing, "That sign-in client is no longer on this Mac.")
            }
            s.selected = id
        }
    }

    func oauthClientShortID(for account: AccountID) async -> String? {
        state.withLock { $0.perAccount[account] }
    }

    func addAccount(loginHint: String?) async throws -> AccountID {
        state.withLock { s in
            let used = s.selected ?? s.clients.first?.id
            s.signInsWith.append(used)
        }
        return AccountID(42)
    }
}

@MainActor
@Test func theSignInScreenNamesTheClientAndPicksAnother() async throws {
    let accounts = ClientChoiceAccounts(clients: [(id: "key-work", short: "aaaa1111", secret: true),
                                                  (id: "key-personal", short: "bbbb2222", secret: true)])
    let model = SignInModel(accounts: accounts, safeMode: .readOnly)
    let runner = Task { await model.run() }
    defer { runner.cancel() }
    await eventually { model.phase == .ready && model.clients.count == 2 }
    #expect(model.showsClientPicker)
    #expect(model.clientLabel == "Google client …aaaa1111 (default)")
    #expect(model.canImportAnotherClient, "another client file can be added while one works")

    await model.selectClient("key-personal")
    #expect(model.selectedClient?.shortID == "bbbb2222")
    #expect(model.clientLabel == "Google client …bbbb2222")
    model.signIn()
    await eventually { model.phase == .signedIn(AccountID(42)) }
    #expect(accounts.signInsWith == ["key-personal"], "the sign-in used the picked client")

    let again = SignInModel(accounts: accounts, safeMode: .readOnly)
    let second = Task { await again.run() }
    defer { second.cancel() }
    await eventually { again.phase == .ready && again.clients.count == 2 }
    await again.selectClient("key-gone")
    #expect(again.errorMessage == "That sign-in client is no longer on this Mac.")
    #expect(again.selectedClient?.shortID == "bbbb2222")
}

@MainActor
@Test func importingAnotherClientSelectsItAndOneClientShowsNoPicker() async throws {
    let accounts = ClientChoiceAccounts(clients: [(id: "key-work", short: "aaaa1111", secret: true)])
    let model = SignInModel(accounts: accounts, safeMode: .readOnly)
    let runner = Task { await model.run() }
    defer { runner.cancel() }
    await eventually { model.phase == .ready && model.clients.count == 1 }
    #expect(!model.showsClientPicker)
    await model.importClient(json: Data("not a client".utf8))
    #expect(model.errorMessage == "That file isn't a Google sign-in client file.")
    #expect(model.clients.count == 1)
    await model.importClient(json: Data("client:cccc3333".utf8))
    #expect(model.errorMessage == nil)
    #expect(model.showsClientPicker && model.selectedClient?.shortID == "cccc3333")
    #expect(model.clients.map(\.title) == ["…aaaa1111 (default)", "…cccc3333"])
}

@MainActor
@Test func settingsAccountsShowsEachAccountsClientAndAddsWithThePickedOne() async throws {
    let f = SettingsFixture()
    let accounts = ClientChoiceAccounts(clients: [(id: "key-work", short: "aaaa1111", secret: true),
                                                  (id: "key-personal", short: "bbbb2222", secret: false)],
                                        perAccount: [f.work: "aaaa1111", f.personal: "bbbb2222"])
    let model = AccountsSettingsModel(data: f.env.data, accounts: accounts, settings: f.env.settings,
                                      availability: f.availability)
    model.start()
    await untilObserved { model.rows.count == 2 && model.clients.count == 2 && model.rows.allSatisfy { $0.clientShortID != nil } }
    #expect(model.rows.first { $0.id == f.work }?.clientShortID == "aaaa1111")
    #expect(model.rows.first { $0.id == f.personal }?.clientShortID == "bbbb2222")
    #expect(model.showsClientPicker && model.selectedClient?.isDefault == true)
    #expect(model.clients.last?.title == "…bbbb2222 (no secret)")

    await model.selectClient("key-personal")
    await eventually { model.selectedClient?.id == "key-personal" }
    await model.addAccount()
    #expect(accounts.signInsWith == ["key-personal"])

    await model.importClient(json: Data("client:dddd4444".utf8))
    await eventually { model.selectedClient?.shortID == "dddd4444" }
    #expect(model.errorMessage == nil)
    await model.importClient(json: Data("{}".utf8))
    #expect(model.errorMessage == "That file isn't a Google sign-in client file.")
}
