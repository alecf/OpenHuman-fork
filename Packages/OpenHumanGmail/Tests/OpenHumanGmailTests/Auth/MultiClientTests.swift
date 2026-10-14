import Foundation
import OpenHumanCore
import OpenHumanGmailTesting
import Testing
@testable import OpenHumanGmail

private enum TwoClients {
    static let workID = "111111111111-workclientaaaaaaaa.apps.googleusercontent.com"
    static let personalID = "222222222222-personalclientbbbb.apps.googleusercontent.com"
    static let workSecret = "SYNTHETIC-WORK-SECRET"
    static let personalSecret = "SYNTHETIC-PERSONAL-SECRET"

    static func config(_ id: String, _ secret: String?) -> OAuthClientConfig {
        OAuthClientConfig(clientID: id, clientSecret: secret,
                          authURI: URL(string: "https://accounts.example.invalid/o/oauth2/auth")!,
                          tokenURI: URL(string: "https://oauth2.example.invalid/token")!)
    }

    static let work = config(workID, workSecret)
    static let personal = config(personalID, personalSecret)

    static func json(_ id: String, secret: String? = nil, tokenURI: String = "https://oauth2.googleapis.com/token") -> Data {
        let secretField = secret.map { #","client_secret":"\#($0)""# } ?? ""
        return Data(#"{"installed":{"client_id":"\#(id)"\#(secretField),"token_uri":"\#(tokenURI)"}}"#.utf8)
    }

    static func tokenEndpoint(scope: @escaping @Sendable (String) -> String = { _ in GmailScope.readonly })
        -> ScriptedTransport {
        ScriptedTransport { request in
            let client = formFields(request.body)["client_id"] ?? ""
            return jsonResponse(200, ["access_token": "access-from-\(client.prefix(12))", "expires_in": 3600,
                                      "scope": scope(client), "token_type": "Bearer"])
        }
    }
}

@Suite struct OAuthClientRegistryTests {
    private func names(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    @Test func eachImportIsItsOwnOwnerOnlyFileAndTheFirstBecomesTheDefault() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let work = try OAuthClientConfig.importClient(TwoClients.json(TwoClients.workID, secret: TwoClients.workSecret),
                                                      storeDirectory: dir.url)
        let personal = try OAuthClientConfig.importClient(
            TwoClients.json(TwoClients.personalID, secret: TwoClients.personalSecret), storeDirectory: dir.url)
        let clients = dir.url.appendingPathComponent("oauth-clients", isDirectory: true)
        #expect(posixMode(clients) == 0o700)
        #expect(try names(clients) == ["\(work.registryKey).json", "\(personal.registryKey).json"].sorted(),
                "one file per client, named by its key; no temporary file left")
        for name in try names(clients) { #expect(posixMode(clients.appendingPathComponent(name)) == 0o600) }
        #expect(posixMode(dir.url.appendingPathComponent("oauth-client.json")) == 0o600)
        #expect(try OAuthClientConfig.load(environment: [:], storeDirectory: dir.url).clientID
                == TwoClients.workID)
        let available = OAuthClientConfig.availableClients(environment: [:], storeDirectory: dir.url)
        #expect(available.map(\.clientID) == [TwoClients.workID, TwoClients.personalID], "default first, each id once")
        #expect(available.map(\.clientSecret) == [TwoClients.workSecret, TwoClients.personalSecret])
        #expect(available.allSatisfy { $0.tokenURI == OAuthClientConfig.defaultTokenURI })
        #expect(Set(OAuthClientConfig.importedClients(storeDirectory: dir.url).map(\.clientID))
                == [TwoClients.workID, TwoClients.personalID])
    }

    @Test func aDefaultWithoutASecretOrTheSameClientAgainIsReplaced() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        try TwoClients.json(TwoClients.workID).write(to: dir.url.appendingPathComponent("oauth-client.json"))
        chmod(dir.url.appendingPathComponent("oauth-client.json").path, 0o600)
        _ = try OAuthClientConfig.importClient(TwoClients.json(TwoClients.personalID, secret: "SYNTHETIC-OLD"),
                                               storeDirectory: dir.url)
        var main = try OAuthClientConfig.load(environment: [:], storeDirectory: dir.url)
        #expect(main.clientID == TwoClients.personalID, "a secret-less default cannot sign in: the import replaces it")
        _ = try OAuthClientConfig.importClient(TwoClients.json(TwoClients.personalID, secret: TwoClients.personalSecret),
                                               storeDirectory: dir.url)
        main = try OAuthClientConfig.load(environment: [:], storeDirectory: dir.url)
        #expect(main.clientSecret == TwoClients.personalSecret, "a newer download of the same client updates it")
        #expect(OAuthClientConfig.importedClients(storeDirectory: dir.url).map(\.clientSecret) == [TwoClients.personalSecret])
    }

    @Test func aRefusedImportWritesNothing() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let refused = [
            TwoClients.json(TwoClients.workID, secret: "S", tokenURI: "https://oauth2.example.invalid/token"),
            TwoClients.json(TwoClients.workID, secret: "S", tokenURI: "http://oauth2.googleapis.com/token"),
            Data(#"{"installed":{"client_secret":"S"}}"#.utf8),
            Data("not json".utf8),
        ]
        for json in refused {
            do {
                _ = try OAuthClientConfig.importClient(json, storeDirectory: dir.url)
                Issue.record("a refused client file was imported")
            } catch let OAuthError.configurationMissing(why) {
                #expect(!why.contains(TwoClients.workID) && !why.contains("example.invalid"), "names no value")
            }
        }
        #expect(try names(dir.url).isEmpty)
    }

    @Test func everyImportedFileIsCheckedWhenRead() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let good = try OAuthClientConfig.importClient(TwoClients.json(TwoClients.workID, secret: TwoClients.workSecret),
                                                      storeDirectory: dir.url)
        let clients = dir.url.appendingPathComponent("oauth-clients", isDirectory: true)
        func place(_ data: Data, as name: String, mode: mode_t = 0o600) throws {
            let url = clients.appendingPathComponent(name)
            try data.write(to: url)
            chmod(url.path, mode)
        }
        let hostileID = "333333333333-hostile.apps.googleusercontent.com"
        try place(TwoClients.json(hostileID, secret: "S", tokenURI: "https://oauth2.example.invalid/token"),
                  as: "\(OAuthClientConfig.registryKey(clientID: hostileID)).json")
        try place(TwoClients.json("444444444444-misnamed.apps.googleusercontent.com", secret: "S"),
                  as: "\(OAuthClientConfig.registryKey(clientID: "something-else")).json")
        try place(Data("{".utf8), as: "\(OAuthClientConfig.registryKey(clientID: "broken")).json")
        let outside = dir.url.appendingPathComponent("outside.json")
        let linkedID = "555555555555-linked.apps.googleusercontent.com"
        try TwoClients.json(linkedID, secret: "S").write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: clients.appendingPathComponent("\(OAuthClientConfig.registryKey(clientID: linkedID)).json"),
            withDestinationURL: outside)
        let looseID = "666666666666-loose.apps.googleusercontent.com"
        let loose = "\(OAuthClientConfig.registryKey(clientID: looseID)).json"
        try place(TwoClients.json(looseID, secret: "S"), as: loose, mode: 0o644)

        let read = OAuthClientConfig.importedClients(storeDirectory: dir.url)
        #expect(Set(read.map(\.clientID)) == [good.clientID, looseID])
        #expect(posixMode(clients.appendingPathComponent(loose)) == 0o600)
    }

    @Test func theDefaultsResolutionOrderIsUnchangedAndComesFirst() throws {
        let dir = try TempDirectory()
        defer { dir.cleanup() }
        let store = dir.url.appendingPathComponent("store", isDirectory: true)
        _ = try OAuthClientConfig.importClient(TwoClients.json(TwoClients.workID, secret: "S1"), storeDirectory: store)
        _ = try OAuthClientConfig.importClient(TwoClients.json(TwoClients.personalID, secret: "S2"), storeDirectory: store)
        let envFile = dir.url.appendingPathComponent("env.json")
        try Synthetic.installedJSON(clientID: "env-client").write(to: envFile)
        let env = [OAuthClientConfig.environmentKey: envFile.path]
        #expect(try OAuthClientConfig.load(environment: env, storeDirectory: store).clientID == "env-client")
        #expect(try OAuthClientConfig.load(environment: [:], storeDirectory: store).clientID
                == TwoClients.workID)
        #expect(throws: OAuthError.self) { try OAuthClientConfig.load(environment: [:], storeDirectory: nil) }
        #expect(OAuthClientConfig.availableClients(environment: env, storeDirectory: store)
            .map(\.clientID) == ["env-client", TwoClients.workID, TwoClients.personalID])
        #expect(OAuthClientConfig.availableClients(environment: [:], storeDirectory: store)
            .map(\.clientID) == [TwoClients.workID, TwoClients.personalID])
        #expect(OAuthClientConfig.availableClients(environment: [:], storeDirectory: nil).isEmpty)
    }

    @Test func theShortIDAndTheKeyNeverRevealTheSecret() {
        #expect(OAuthClientConfig.shortID(clientID: "123456789012-abcdefghijklmnop.apps.googleusercontent.com")
                == "ijklmnop")
        #expect(OAuthClientConfig.shortID(clientID: "plain-client-id-1234") == "-id-1234")
        #expect(OAuthClientConfig.shortID(clientID: "abc.apps.googleusercontent.com") == "abc")
        let key = TwoClients.work.registryKey
        #expect(key.count == 32 && key.allSatisfy(\.isHexDigit))
        #expect(key == OAuthClientConfig.registryKey(clientID: TwoClients.workID))
        #expect(key != TwoClients.personal.registryKey)
        #expect(!key.contains("workclient") && !key.contains(TwoClients.workSecret))
        #expect(!"\(TwoClients.work)".contains(TwoClients.workID) && !"\(TwoClients.work)".contains(TwoClients.workSecret))
    }
}

@Suite struct MultiClientCredentialsTests {
    private func credentials(_ store: any TokenStore, _ transport: ScriptedTransport, _ clock: TestClock,
                             known: [OAuthClientConfig] = [TwoClients.work, TwoClients.personal],
                             events: EventLog? = nil) -> AccountCredentials {
        AccountCredentials(store: store, client: TwoClients.work, transport: transport, clock: clock,
                           minimumValidity: .seconds(300), retryWaits: [], onEvent: events?.sink,
                           knownClients: { known })
    }

    private func expired(_ refresh: String, _ clientID: String, _ clock: TestClock,
                         scopes: [String] = [GmailScope.readonly]) -> StoredToken {
        Synthetic.token(refresh: refresh, access: "old", expiry: clock.now.addingTimeInterval(-1), clientID: clientID,
                        scopes: scopes)
    }

    @Test func eachAccountRefreshesWithItsOwnClient() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([
            "work@example.com": expired("refresh-work", TwoClients.workID, clock),
            "personal@example.com": expired("refresh-personal", TwoClients.personalID, clock),
        ])
        let endpoint = TwoClients.tokenEndpoint()
        let registry = credentials(store, endpoint, clock)
        #expect(registry.client(for: "Personal@Example.com").clientID == TwoClients.personalID)
        #expect(registry.client(for: "work@example.com").clientID == TwoClients.workID)

        _ = try await registry.tokenManager(for: "work@example.com").accessToken()
        _ = try await registry.tokenManager(for: "personal@example.com").accessToken()
        let sent = endpoint.requests.map { formFields($0.body) }
        #expect(sent.map { $0["refresh_token"] } == ["refresh-work", "refresh-personal"])
        #expect(sent.map { $0["client_id"] } == [TwoClients.workID, TwoClients.personalID])
        #expect(sent.map { $0["client_secret"] } == [TwoClients.workSecret, TwoClients.personalSecret])
        #expect(registry.tokenManager(for: "work@example.com") !== registry.tokenManager(for: "personal@example.com"))
        #expect(try store.load(account: "personal@example.com")?.clientID == TwoClients.personalID,
                "a refresh keeps the token's own client")
    }

    @Test func aBroaderGrantOnOneClientStopsOnlyThatAccount() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([
            "work@example.com": expired("w", TwoClients.workID, clock, scopes: [GmailScope.modify]),
            "personal@example.com": expired("p", TwoClients.personalID, clock, scopes: [GmailScope.modify]),
        ])
        let endpoint = TwoClients.tokenEndpoint { client in
            client == TwoClients.personalID ? "\(GmailScope.modify) https://mail.google.com/" : GmailScope.modify
        }
        let events = EventLog()
        let registry = credentials(store, endpoint, clock, events: events)
        await #expect(throws: OAuthError.reauthRequired) {
            _ = try await registry.tokenManager(for: "personal@example.com").accessToken()
        }
        #expect(try await registry.tokenManager(for: "work@example.com").accessToken().hasPrefix("access-from-"))
        #expect(await registry.authState(for: "personal@example.com") == .needsReauth(.broaderGrant))
        #expect(await registry.authState(for: "work@example.com") == .authorized)
        #expect(try store.load(account: "personal@example.com") == nil)
        #expect(try store.load(account: "work@example.com")?.grantedScopes == [GmailScope.modify])
        #expect(events.all == [.needsReauth(account: "personal@example.com", reason: .broaderGrant)])
        await #expect(throws: OAuthError.reauthRequired) {
            _ = try await registry.tokenManager(for: "personal@example.com").accessToken()
        }
        #expect(endpoint.requests.count == 2)
    }

    @Test func aTokenFromAnUnknownClientIsNeverRefreshedWithAnother() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore([
            "other@example.com": expired("x", "999999999999-unknown.apps.googleusercontent.com", clock),
        ])
        let endpoint = TwoClients.tokenEndpoint()
        let registry = credentials(store, endpoint, clock)
        #expect(registry.client(for: "other@example.com").clientID == TwoClients.workID, "the default")
        await #expect(throws: OAuthError.reauthRequired) {
            _ = try await registry.tokenManager(for: "other@example.com").accessToken()
        }
        #expect(await registry.authState(for: "other@example.com") == .needsReauth(.clientMismatch))
        #expect(endpoint.requests.isEmpty)
    }

    @Test func aSignInWithAnotherClientMovesTheAccountToIt() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(["work@example.com": expired("old", TwoClients.workID, clock)])
        let endpoint = TwoClients.tokenEndpoint()
        let registry = credentials(store, endpoint, clock)
        let before = registry.tokenManager(for: "work@example.com")
        try await registry.save(Synthetic.result(email: "work@example.com", token: Synthetic.token(
            refresh: "new", access: "a", expiry: clock.now.addingTimeInterval(-1), clientID: TwoClients.personalID)))
        let after = registry.tokenManager(for: "work@example.com")
        #expect(after !== before)
        _ = try await after.accessToken()
        #expect(formFields(endpoint.requests.last?.body)["client_id"] == TwoClients.personalID)
        await #expect(throws: OAuthError.denied("client_mismatch")) {
            try await registry.save(Synthetic.result(email: "work@example.com", token: Synthetic.token(
                refresh: "stray", access: "a", expiry: clock.now, clientID: "unknown-client")))
        }
        #expect(try store.load(account: "work@example.com")?.refreshToken == "new")
    }

    @Test func theFactoryRebuildsAClientWhenTheAccountsClientChanged() async throws {
        let clock = TestClock()
        let store = InMemoryTokenStore(["me@example.com": Synthetic.token(
            refresh: "r1", access: "first", expiry: clock.now.addingTimeInterval(3600), clientID: TwoClients.workID)])
        let registry = credentials(store, TwoClients.tokenEndpoint(), clock)
        let api = FakeHTTPTransport()
        api.on("GET", "/gmail/v1/users/me/labels") { _ in FakeHTTPTransport.json(200, ["labels": []]) }
        let factory = DefaultGmailClientFactory(safeMode: .readOnly, accountCredentials: registry, apiTransport: api,
                                                config: GmailClientConfig(userAgent: "t"), clock: clock)
        let first = try factory.gmailClient(for: "me@example.com")
        #expect(try factory.gmailClient(for: "me@example.com") === first)
        try await registry.save(Synthetic.result(email: "me@example.com", token: Synthetic.token(
            refresh: "r2", access: "second", expiry: clock.now.addingTimeInterval(3600), clientID: TwoClients.personalID)))
        let second = try factory.gmailClient(for: "me@example.com")
        #expect(second !== first)
        _ = try await second.listLabels()
        #expect(api.requests.last?.headers["Authorization"] == "Bearer second")
    }
}
