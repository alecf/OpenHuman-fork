import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Synchronization
import Testing
@testable import MailFeatures

private final class ManagedClients: AccountManaging {
    struct Client {
        var id: String
        var short: String
        var isDefault = false
        var importedAt: Date? = Date(timeIntervalSince1970: 1_790_000_000)
        var accounts: [AccountID] = []
        var calendars: [AccountID] = []
        var sync: OAuthClientSync?
    }
    private struct State {
        var clients: [Client]
        var calls: [String] = []
        var cancelMoveOf: AccountID?
    }
    private let state: Mutex<State>

    init(_ clients: [Client], cancelMoveOf: AccountID? = nil) {
        state = Mutex(State(clients: clients, cancelMoveOf: cancelMoveOf))
    }

    var calls: [String] { state.withLock { $0.calls } }
    func client(_ id: String) -> Client? { state.withLock { s in s.clients.first { $0.id == id } } }

    private static func key(of json: Data) throws -> (id: String, short: String) {
        guard let text = String(data: json, encoding: .utf8), text.hasPrefix("file:") else {
            throw AccountSetupError(.clientMissing, "That file isn't a Google sign-in client file.")
        }
        let short = String(text.dropFirst("file:".count))
        return ("key-\(short)", short)
    }

    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        let (stream, continuation) = AsyncStream<OAuthClientStatus>.makeStream()
        continuation.yield(.configured(source: .file))
        return stream
    }

    func importOAuthClient(json: Data) async throws {
        let parsed = try Self.key(of: json)
        state.withLock { s in
            s.calls.append("import \(parsed.id)")
            if !s.clients.contains(where: { $0.id == parsed.id }) { s.clients.append(Client(id: parsed.id, short: parsed.short)) }
        }
    }

    func oauthClients() async -> [OAuthClientSummary] {
        state.withLock { s in
            s.clients.map { OAuthClientSummary(id: $0.id, shortID: $0.short, isDefault: $0.isDefault, isSelected: $0.isDefault,
                                               hasSecret: true) }
        }
    }

    func oauthClientUsage() async -> [OAuthClientUsage] {
        state.withLock { s in
            s.clients.map { client in
                OAuthClientUsage(client: OAuthClientSummary(id: client.id, shortID: client.short, isDefault: client.isDefault,
                                                            isSelected: client.isDefault, hasSecret: true),
                                 importedAt: client.importedAt, accounts: client.accounts, calendars: client.calendars,
                                 sync: client.sync)
            }
        }
    }

    func removeOAuthClient(_ id: OAuthClientSummary.ID) async throws {
        state.withLock { s in
            s.calls.append("remove \(id)")
            s.clients.removeAll { $0.id == id }
        }
    }

    func inspectOAuthClientFile(_ json: Data, replacing id: OAuthClientSummary.ID) async throws -> OAuthClientReplacement {
        let parsed = try Self.key(of: json)
        state.withLock { $0.calls.append("inspect \(parsed.id)") }
        return parsed.id == id ? .sameClient : .differentClient(id: parsed.id, shortID: parsed.short)
    }

    func replaceOAuthClient(_ id: OAuthClientSummary.ID, json: Data) async throws {
        state.withLock { s in
            s.calls.append("replace \(id)")
            if let index = s.clients.firstIndex(where: { $0.id == id }) {
                s.clients[index].importedAt = Date(timeIntervalSince1970: 1_800_000_000)
            }
        }
    }

    func addAccount(loginHint: String?) async throws -> AccountID {
        throw AccountSetupError(.failed, "Not used by these tests.")
    }

    func setOAuthClientSync(_ id: OAuthClientSummary.ID, enabled: Bool) async throws {
        state.withLock { s in
            s.calls.append("sync \(id) \(enabled)")
            if let index = s.clients.firstIndex(where: { $0.id == id }) {
                s.clients[index].sync = enabled ? .syncing : .notSyncing
            }
        }
    }

    func moveAccount(_ account: AccountID, toOAuthClient id: OAuthClientSummary.ID) async throws {
        try state.withLock { s in
            s.calls.append("move \(account.rawValue) \(id)")
            if s.cancelMoveOf == account { throw AccountSetupError(.cancelled, "Sign-in was cancelled.") }
            for index in s.clients.indices { s.clients[index].accounts.removeAll { $0 == account } }
            if let index = s.clients.firstIndex(where: { $0.id == id }) { s.clients[index].accounts.append(account) }
        }
    }
}

@MainActor
private func loadedModel(_ f: SettingsFixture, _ accounts: ManagedClients, count: Int) async -> AccountsSettingsModel {
    let model = AccountsSettingsModel(data: f.env.data, accounts: accounts, settings: f.env.settings,
                                      availability: f.availability)
    model.start()
    await eventually(timeout: .seconds(60)) { model.rows.count == 2 && model.clientRows.count == count }
    return model
}

@MainActor
@Test func theClientListNamesWhoUsesEachClientAndWhenItWasImported() async throws {
    let f = SettingsFixture()
    let accounts = ManagedClients([
        .init(id: "key-aaaa1111", short: "aaaa1111", isDefault: true, accounts: [f.work]),
        .init(id: "key-bbbb2222", short: "bbbb2222", accounts: [f.personal], calendars: [f.work]),
        .init(id: "key-cccc3333", short: "cccc3333"),
        .init(id: "key-build", short: "dddd4444", importedAt: nil),
    ])
    let model = await loadedModel(f, accounts, count: 4)
    let work = try #require(model.rows.first { $0.id == f.work }?.email)
    let personal = try #require(model.rows.first { $0.id == f.personal }?.email)
    let rows = model.clientRows
    #expect(rows.map(\.title) == ["Client …aaaa1111 (default)", "Client …bbbb2222", "Client …cccc3333", "Client …dddd4444"])
    #expect(rows[0].usedBy == "Used by \(work)")
    #expect(rows[1].usedBy == "Used by \(personal)" && rows[1].calendars == "Calendar of \(work)")
    #expect(rows[2].usedBy == "No account signs in with it" && rows[2].calendars == nil)
    #expect(rows[0].imported?.hasPrefix("Imported ") == true)
    #expect(rows[3].imported == nil && !rows[3].isImported, "a client from the build has no file to replace or remove")
}

@MainActor
@Test func removeIsRefusedWithAPlainReasonWhileAnythingUsesTheClient() async throws {
    let f = SettingsFixture()
    let accounts = ManagedClients([
        .init(id: "key-aaaa1111", short: "aaaa1111", isDefault: true),
        .init(id: "key-bbbb2222", short: "bbbb2222", accounts: [f.personal]),
        .init(id: "key-cccc3333", short: "cccc3333", calendars: [f.work]),
        .init(id: "key-eeee5555", short: "eeee5555"),
    ])
    let model = await loadedModel(f, accounts, count: 4)
    let work = try #require(model.rows.first { $0.id == f.work }?.email)
    let personal = try #require(model.rows.first { $0.id == f.personal }?.email)

    await model.removeClient("key-bbbb2222")
    #expect(model.errorMessage == "…bbbb2222 is still used by \(personal). Move it to another client with Replace…, or "
        + "sign it out, first.")
    await model.removeClient("key-cccc3333")
    #expect(model.errorMessage == "…cccc3333 is still used by the calendar of \(work). Connect that calendar with another "
        + "client in Settings › Calendar first.")
    await model.removeClient("key-aaaa1111")
    #expect(model.errorMessage == "…aaaa1111 is the default client for new sign-ins, so Mail keeps it.")
    #expect(accounts.calls.isEmpty, "nothing reached the data layer while a reason stood")

    await model.removeClient("key-eeee5555")
    #expect(model.errorMessage == nil)
    #expect(accounts.calls == ["remove key-eeee5555"])
    #expect(model.clientNotice == "Removed client …eeee5555 from this Mac's Keychain (and from iCloud Keychain, if it synced). Nothing changed at Google.")
    await eventually(timeout: .seconds(60)) { model.clientRows.count == 3 }
}

@MainActor
@Test func replacingWithTheSameClientUpdatesInPlaceWithoutAsking() async throws {
    let f = SettingsFixture()
    let accounts = ManagedClients([.init(id: "key-aaaa1111", short: "aaaa1111", isDefault: true, accounts: [f.work])])
    let model = await loadedModel(f, accounts, count: 1)
    await model.replaceClient("key-aaaa1111", json: Data("file:aaaa1111".utf8))
    #expect(model.pendingMove == nil, "the same client never asks anyone to sign in again")
    #expect(accounts.calls == ["inspect key-aaaa1111", "replace key-aaaa1111"])
    #expect(model.clientNotice?.hasPrefix("Updated client …aaaa1111") == true)
    #expect(accounts.client("key-aaaa1111")?.accounts == [f.work], "the account stays where it was")

    await model.replaceClient("key-aaaa1111", json: Data("not a client file".utf8))
    #expect(model.errorMessage == "That file isn't a Google sign-in client file.")
    #expect(accounts.calls.count == 2, "a refused file changes nothing")
}

@MainActor
@Test func replacingWithAnotherClientAsksFirstThenSignsEachAccountInAgain() async throws {
    let f = SettingsFixture()
    let accounts = ManagedClients([
        .init(id: "key-aaaa1111", short: "aaaa1111", isDefault: true),
        .init(id: "key-bbbb2222", short: "bbbb2222", accounts: [f.work, f.personal], calendars: [f.work]),
    ])
    let model = await loadedModel(f, accounts, count: 2)
    let work = try #require(model.rows.first { $0.id == f.work }?.email)
    let personal = try #require(model.rows.first { $0.id == f.personal }?.email)

    await model.replaceClient("key-bbbb2222", json: Data("file:ffff6666".utf8))
    let move = try #require(model.pendingMove)
    #expect(accounts.calls == ["inspect key-ffff6666"], "nothing imported or moved before the yes")
    #expect(model.moveTitle(move) == "Sign in again with client …ffff6666?")
    let message = model.moveMessage(move)
    #expect(message.contains("\(work) and \(personal) signed in with …bbbb2222; to use …ffff6666 they must sign in again"))
    #expect(message.contains("The calendar of \(work) stays connected with …bbbb2222"))
    #expect(message.hasSuffix("…bbbb2222 stays on this Mac until you remove it."))
    #expect(model.moveButton(move) == "Sign In Again")

    model.cancelMove()
    #expect(model.pendingMove == nil && accounts.calls == ["inspect key-ffff6666"])

    await model.replaceClient("key-bbbb2222", json: Data("file:ffff6666".utf8))
    await model.confirmMove()
    #expect(accounts.calls.suffix(3) == ["import key-ffff6666", "move \(f.work.rawValue) key-ffff6666",
                                          "move \(f.personal.rawValue) key-ffff6666"])
    #expect(model.clientNotice == "\(work) and \(personal) signed in again with …ffff6666.")
    #expect(accounts.client("key-bbbb2222") != nil, "the old client is never removed by a move")
    #expect(!model.isMoving)
}

@MainActor
@Test func aCancelledSignInStopsTheMoveAndSaysWhoStaysOnTheOldClient() async throws {
    let f = SettingsFixture()
    let accounts = ManagedClients([
        .init(id: "key-bbbb2222", short: "bbbb2222", isDefault: false, accounts: [f.work, f.personal]),
    ], cancelMoveOf: f.work)
    let model = await loadedModel(f, accounts, count: 1)
    let work = try #require(model.rows.first { $0.id == f.work }?.email)
    await model.replaceClient("key-bbbb2222", json: Data("file:ffff6666".utf8))
    await model.confirmMove()
    #expect(accounts.calls.last == "move \(f.work.rawValue) key-ffff6666", "the second account was not asked")
    #expect(model.errorMessage == "\(work) still signs in with …bbbb2222. Sign-in was cancelled.")
    #expect(model.clientNotice == nil)
    #expect(accounts.client("key-bbbb2222")?.accounts == [f.work, f.personal])
}

@MainActor
@Test func anotherClientWithNobodyOnTheOldOneIsJustAdded() async throws {
    let f = SettingsFixture()
    let accounts = ManagedClients([.init(id: "key-cccc3333", short: "cccc3333")])
    let model = await loadedModel(f, accounts, count: 1)
    await model.replaceClient("key-cccc3333", json: Data("file:ffff6666".utf8))
    let move = try #require(model.pendingMove)
    #expect(model.moveTitle(move) == "Add client …ffff6666?" && model.moveButton(move) == "Add Client")
    #expect(model.moveMessage(move).contains("No account signs in with …cccc3333"))
    await model.confirmMove()
    #expect(accounts.calls == ["inspect key-ffff6666", "import key-ffff6666"])
    #expect(model.clientNotice == "Added client …ffff6666.")
}

@MainActor
@Test func theDontSyncSwitchExplainsICloudKeychainAndChangesOnlyThatClient() async throws {
    let f = SettingsFixture()
    let accounts = ManagedClients([
        .init(id: "key-aaaa1111", short: "aaaa1111", isDefault: true, sync: .syncing),
        .init(id: "key-bbbb2222", short: "bbbb2222", sync: .unavailable),
        .init(id: "key-build", short: "dddd4444", importedAt: nil),
    ])
    let model = await loadedModel(f, accounts, count: 3)
    let rows = model.clientRows
    #expect(rows[0].syncNote == "Syncs through iCloud Keychain to your other devices." && !rows[0].dontSync)
    #expect(rows[1].syncNote?.hasPrefix("Couldn't sync") == true && !rows[1].dontSync)
    #expect(rows[2].syncNote == nil, "a client that is not in the Keychain has nothing to sync")

    await model.setDontSync("key-aaaa1111", true)
    #expect(accounts.calls == ["sync key-aaaa1111 false"])
    await eventually(timeout: .seconds(60)) { model.clientRows[0].dontSync }
    #expect(model.clientRows[0].syncNote == "Stays on this Mac. It does not sync.")
    #expect(!model.clientRows[1].dontSync, "another client is untouched")

    await model.setDontSync("key-aaaa1111", false)
    #expect(accounts.calls.last == "sync key-aaaa1111 true")
    await eventually(timeout: .seconds(60)) { !model.clientRows[0].dontSync }
}
