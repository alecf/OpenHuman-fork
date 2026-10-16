import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanGmail

private let email = "someone@example.com"
private let macGrant = SharedGrant(refreshToken: "synthetic-refresh-mac", clientID: Synthetic.clientID,
                                   grantedScopes: [GmailScope.readonly], version: 1)

private struct Phone {
    let local = InMemoryTokenStore()
    let records = InMemoryTokenDeviceStore()
    let store: SyncedTokenStore
    let log: CredentialChainLog

    init(cloud: any SharedGrantStore) {
        log = CredentialChainLog(clock: TestClock())
        store = SyncedTokenStore(local: local, shared: cloud, device: records, log: log)
    }

    func intake(_ transport: ScriptedTransport, clients: [OAuthClientConfig] = [Synthetic.client]) -> SharedSignInIntake {
        SharedSignInIntake(tokens: store, clients: { clients }, transport: transport, clock: TestClock(), retryWaits: [],
                           log: log)
    }

    var subject: String { CredentialChainLog.subject(account: email) }
}

private func google(refusing code: String? = nil, rotateTo rotated: String? = nil) -> ScriptedTransport {
    ScriptedTransport { _ in
        if let code { return jsonResponse(400, ["error": code, "error_description": "Synthetic refusal."]) }
        var body: [String: Any] = ["access_token": "synthetic-phone-access", "expires_in": 3600, "token_type": "Bearer",
                                   "scope": GmailScope.readonly]
        if let rotated { body["refresh_token"] = rotated }
        return jsonResponse(200, body)
    }
}

private struct StubIntake: CredentialIntake {
    let source: CredentialSource
    func check() async -> CredentialIntakeState { .unavailable(.noItem) }
    func take(account email: String) async -> CredentialIntakeResult { .failed(.noItem) }
}

private func clientJSON(_ id: String) -> Data {
    Data(#"{"installed":{"client_id":"\#(id)","client_secret":"SYNTHETIC-CHAIN"}}"#.utf8)
}

@Suite struct CredentialIntakeTests {
    @Test func aBuildThatCannotReadICloudKeychainSaysSoAtEveryStep() async {
        let phone = Phone(cloud: InMemorySharedGrantStore(available: false))
        let transport = google()
        let rung = phone.intake(transport)
        #expect(await rung.check() == .unavailable(.noEntitlement))
        #expect(await rung.take(account: email) == .failed(.noEntitlement))
        #expect(transport.requests.isEmpty)
        #expect(phone.log.latest(.readSignIn, subject: phone.subject)?.outcome == .noEntitlement)
    }

    @Test func nothingSharedYetSaysNoItemAndSendsNothing() async {
        let phone = Phone(cloud: InMemorySharedGrantStore())
        let transport = google()
        let rung = phone.intake(transport)
        #expect(await rung.check() == .unavailable(.noItem))
        #expect(await rung.take(account: email) == .failed(.noItem))
        #expect(transport.requests.isEmpty)
        #expect(phone.log.latest(.readSignIn, subject: phone.subject)?.outcome == .noItem)
    }

    @Test func aSignInWhoseClientIsNotHereYetSaysClientMissingAndNeverSendsTheToken() async {
        let cloud = InMemorySharedGrantStore()
        cloud.deliver(macGrant, account: email)
        let phone = Phone(cloud: cloud)
        let transport = google()
        let other = OAuthClientConfig.google(clientID: "9999-synthetic-other.apps.googleusercontent.com", clientSecret: nil)
        let rung = phone.intake(transport, clients: [other])
        #expect(await rung.check() == .ready(accounts: [], clientMissing: [email]))
        #expect(await rung.take(account: email) == .failed(.clientMissing))
        #expect(transport.requests.isEmpty, "a refresh token is never sent with another client")
        #expect(phone.log.latest(.readClient, subject: phone.subject)?.outcome == .clientMissing)
        #expect(phone.log.latest(.readSignIn, subject: phone.subject)?.outcome == .ok)
    }

    @Test(arguments: ["invalid_grant", "invalid_client", "unauthorized_client"])
    func aRefusalByGoogleCarriesItsCodeAndKeepsTheSharedCopy(_ code: String) async throws {
        let cloud = InMemorySharedGrantStore()
        cloud.deliver(macGrant, account: email)
        let phone = Phone(cloud: cloud)
        let transport = google(refusing: code)
        let rung = phone.intake(transport)
        #expect(await rung.check() == .ready(accounts: [email], clientMissing: []))
        #expect(await rung.take(account: email) == .failed(.googleRefused(code: code)))
        #expect(transport.requests.count == 1)
        #expect(cloud.peek(email) == macGrant, "never deleted: the Mac may still use it")
        #expect(phone.log.latest(.refresh, subject: phone.subject)?.outcome == .googleRefused(code: code))
        #expect(try phone.records.load(account: email)?.source == nil)

        #expect(await rung.take(account: email) == .failed(.refusedHere), "a refused sign-in is not sent again")
        #expect(transport.requests.count == 1)
        #expect(await rung.check() == .unavailable(.refusedHere), "not offered again, and not mistaken for nothing shared")
    }

    @Test func aSharedSignInThatWorksIsAddedAndNotesWhereItCameFrom() async throws {
        let cloud = InMemorySharedGrantStore()
        cloud.deliver(macGrant, account: email)
        let phone = Phone(cloud: cloud)
        let transport = google()
        let rung = phone.intake(transport)
        #expect(await rung.take(account: " Someone@Example.com ") == .added(scopes: [GmailScope.readonly]))
        let request = try #require(transport.requests.first)
        let fields = formFields(request.body)
        #expect(transport.requests.count == 1 && request.url == Synthetic.client.tokenURI)
        #expect(fields["refresh_token"] == macGrant.refreshToken && fields["client_secret"] == Synthetic.clientSecret)
        #expect(try phone.records.load(account: email)?.source == .shared)
        #expect(try phone.local.load(account: email) == nil, "the phone keeps no refresh token of its own")
        #expect(phone.log.latest(.refresh, subject: phone.subject)?.outcome == .ok)
        #expect(cloud.writeCount == 0, "using the shared sign-in never writes it")
    }

    @Test func aRotatedTokenIsWrittenBackAndTheLogSaysSo() async throws {
        let cloud = InMemorySharedGrantStore()
        cloud.deliver(macGrant, account: email)
        let phone = Phone(cloud: cloud)
        let rung = phone.intake(google(rotateTo: "synthetic-refresh-rotated"))
        #expect(await rung.take(account: email) == .added(scopes: [GmailScope.readonly]))
        #expect(cloud.peek(email)?.refreshToken == "synthetic-refresh-rotated" && cloud.peek(email)?.version == 2)
        #expect(phone.log.latest(.writeBack, subject: phone.subject)?.outcome == .ok)
    }

    @Test func aDeviceThatKeepsItsOwnSignInIsNotOfferedTheSharedOne() async throws {
        let cloud = InMemorySharedGrantStore()
        cloud.deliver(macGrant, account: email)
        let phone = Phone(cloud: cloud)
        try phone.local.save(Synthetic.token(refresh: "synthetic-refresh-own"), account: email)
        try phone.records.save(TokenDeviceRecord(choice: .ownSignIn), account: email)
        let transport = google()
        #expect(await phone.intake(transport).check() == .unavailable(.keptLocal))
        #expect(await phone.intake(transport).take(account: email) == .failed(.keptLocal))
        #expect(transport.requests.isEmpty)
    }

    @Test func theIntakeListRunsInRungOrderWithOneProviderPerSource() {
        let later = CredentialSource(rawValue: "somethingLater")
        let list = CredentialIntakeList([StubIntake(source: .manualDesktop), StubIntake(source: later),
                                         StubIntake(source: .paired), StubIntake(source: .shared),
                                         StubIntake(source: .paired)])
        #expect(list.sources == [.shared, .paired, .manualDesktop, later])
        #expect(list.provider(.macMinted) == nil)
        #expect(list.provider(.paired)?.source == .paired)
        #expect(CredentialSource.rungOrder == [.shared, .paired, .macMinted, .ownClient, .manualDesktop])
    }
}

@Suite struct CredentialChainLogTests {
    @Test func theLogHoldsNoAddressTokenOrSecret() {
        let log = CredentialChainLog(clock: TestClock())
        let subject = CredentialChainLog.subject(account: " Someone@Example.com ")
        #expect(subject == CredentialChainLog.subject(account: email))
        #expect(!subject.contains("@") && !subject.contains("someone"))
        #expect(CredentialChainLog.subject(account: "other@example.com") != subject)
        log.record(.refresh, .googleRefused(code: "1//synthetic-refresh-token"), subject: subject)
        log.record(.readSignIn, .ok, subject: email)
        log.record(.refresh, .googleRefused(code: "invalid_grant"), subject: subject)
        let events = log.events()
        #expect(events.map(\.outcome) == [.googleRefused(code: "other"), .ok, .googleRefused(code: "invalid_grant")])
        #expect(events[1].subject == nil, "a subject that could be an address is dropped")
        #expect(events.allSatisfy { !$0.line.contains("@") && !$0.line.contains("1//") && !$0.line.contains("synthetic") })
        let client = CredentialChainLog.subject(client: Synthetic.clientID)
        #expect(client.hasPrefix("client-") && !client.contains("synthetic"))
    }

    @Test func repeatsCountInsteadOfFillingTheLogAndTheOldestEntriesDrop() {
        let clock = TestClock()
        let log = CredentialChainLog(clock: clock, capacity: 3)
        let subject = CredentialChainLog.subject(account: email)
        log.record(.refresh, .ok, subject: subject)
        clock.advance(by: .seconds(60))
        log.record(.refresh, .ok, subject: subject)
        #expect(log.events().count == 1)
        #expect(log.events().first?.count == 2 && log.events().first?.at == clock.now)
        #expect(log.events().first?.line == "refresh: ok [\(subject)] x2")
        log.record(.readSignIn, .noItem)
        log.record(.readClient, .clientMissing)
        log.record(.groupMove, .keychain(status: -25308))
        #expect(log.events().map(\.step) == [.readSignIn, .readClient, .groupMove])
        #expect(log.latest(.refresh) == nil)
        #expect(log.latest(.groupMove)?.outcome.summary == "Keychain OSStatus -25308")
        log.clear()
        #expect(log.events().isEmpty)
    }

    @Test func theSourceIsAnOptionalFieldThatOlderAndNewerBuildsBothRead() throws {
        let stored = Data(#"{"choice":"ownSignIn","wrote":"abc"}"#.utf8)
        let old = try JSONDecoder().decode(TokenDeviceRecord.self, from: stored)
        #expect(old.source == nil && old.choice == .ownSignIn && old.wrote == "abc")
        let record = TokenDeviceRecord(wrote: "abc", source: .paired)
        let encoded = try JSONEncoder().encode(record)
        #expect(String(decoding: encoded, as: UTF8.self).contains(#""source":"paired""#))
        #expect(try JSONDecoder().decode(TokenDeviceRecord.self, from: encoded) == record)
        let later = Data(#"{"wrote":"abc","source":"somethingLater"}"#.utf8)
        #expect(try JSONDecoder().decode(TokenDeviceRecord.self, from: later).source
                    == CredentialSource(rawValue: "somethingLater"), "an unknown source never makes the record unreadable")
    }

    @Test func theLaunchShareRecordsWhyASignInStaysOnThisDevice() throws {
        let local = InMemoryTokenStore(["a@example.com": Synthetic.token(refresh: "synthetic-refresh-a"),
                                        "b@example.com": Synthetic.token(refresh: "synthetic-refresh-b")])
        let records = InMemoryTokenDeviceStore()
        try records.save(TokenDeviceRecord(choice: .dontSync), account: "b@example.com")
        let log = CredentialChainLog(clock: TestClock())
        let unavailable = SyncedTokenStore(local: local, shared: InMemorySharedGrantStore(available: false),
                                           device: records, log: log)
        #expect(unavailable.migrateLocalSignIns() == TokenSyncMigrationReport())
        #expect(log.latest(.entitlement)?.outcome == .noEntitlement)

        let cloud = InMemorySharedGrantStore()
        let store = SyncedTokenStore(local: local, shared: cloud, device: records, log: log)
        store.migrateLocalSignIns()
        let a = CredentialChainLog.subject(account: "a@example.com")
        let b = CredentialChainLog.subject(account: "b@example.com")
        #expect(log.latest(.shareSignIn, subject: b)?.outcome == .keptLocal)
        cloud.deliver(nil, account: "a@example.com")
        store.migrateLocalSignIns()
        #expect(log.latest(.shareSignIn, subject: a)?.outcome == .removedElsewhere)
    }
}

@Suite struct ClientShareAtLaunchTests {
    private let workID = "111111111111-chainworkaaaa.apps.googleusercontent.com"
    private let otherID = "222222222222-chainotherbbb.apps.googleusercontent.com"

    @Test func aClientSavedWhileICloudKeychainWasUnavailableIsSharedAtTheNextLaunch() throws {
        let store = InMemoryOAuthClientStore(syncAvailable: false)
        let log = CredentialChainLog(clock: TestClock())
        let vault = OAuthClientVault(store: store, log: log)
        let work = try vault.importClient(clientJSON(workID))
        #expect(vault.entry(key: work.registryKey)?.sync == .unavailable)
        #expect(vault.migrateSyncWanted() == OAuthClientShareReport(), "nothing is tried while sync is unavailable")
        #expect(store.saveCount == 1)
        #expect(log.latest(.entitlement)?.outcome == .noEntitlement)

        store.setSyncAvailable(true)
        var shared = OAuthClientShareReport()
        shared.shared = 1
        #expect(vault.migrateSyncWanted() == shared)
        #expect(vault.entry(key: work.registryKey)?.sync == .syncing)
        #expect(vault.entry(key: work.registryKey)?.isDefault == true, "sharing keeps the default")
        var again = OAuthClientShareReport()
        again.alreadyShared = 1
        #expect(vault.migrateSyncWanted() == again)
        #expect(store.saveCount == 2, "safe to run at every launch")
    }

    @Test func theLaunchShareLeavesDontSyncAndCopiesRemovedElsewhereAlone() throws {
        let store = InMemoryOAuthClientStore()
        let log = CredentialChainLog(clock: TestClock())
        let vault = OAuthClientVault(store: store, log: log)
        let work = try vault.importClient(clientJSON(workID))
        let other = try vault.importClient(clientJSON(otherID))
        try vault.setSynchronizable(key: other.registryKey, false)
        store.removeSharedCopy(key: work.registryKey)
        let saves = store.saveCount
        var expected = OAuthClientShareReport()
        expected.stayLocal = 1
        expected.removedElsewhere = 1
        #expect(vault.migrateSyncWanted() == expected)
        #expect(store.saveCount == saves, "nothing is written")
        #expect(vault.entry(key: work.registryKey)?.sync == .unavailable)
        #expect(vault.entry(key: other.registryKey)?.sync == .notSyncing)
        #expect(log.latest(.shareClient, subject: CredentialChainLog.subject(client: workID))?.outcome
                    == .removedElsewhere)
    }

    @Test func aStoreThatCannotBeReadIsReportedAndNothingIsWritten() throws {
        let store = InMemoryOAuthClientStore()
        let log = CredentialChainLog(clock: TestClock())
        let vault = OAuthClientVault(store: store, log: log)
        _ = try vault.importClient(clientJSON(workID))
        store.failLoads(true)
        let saves = store.saveCount
        #expect(vault.migrateSyncWanted() == OAuthClientShareReport())
        #expect(store.saveCount == saves)
        #expect(log.latest(.shareClient)?.outcome == .keychain(status: -50))
    }
}
