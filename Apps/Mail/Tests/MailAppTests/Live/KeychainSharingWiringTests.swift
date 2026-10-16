import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailApple
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanMail
@testable import OpenHumanMailLive

private let sharedGroup = "ABCDE12345." + KeychainSharing.groupName

private let launchClientID = "888888888888-launchshare8.apps.googleusercontent.com"

private func launchClientJSON() -> Data {
    Data("""
        {"installed":{"client_id":"\(launchClientID)","client_secret":"SYNTHETIC-L8-not-a-secret",
        "auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}
        """.utf8)
}

@MainActor
@Test func theAppsKeychainStoresUseTheGroupTheyAreGiven() throws {
    // Only values are read: this test host is an app bundle, so calling a store would reach the real Keychain
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-keychain-wiring-\(UUID().uuidString)")
    let environment = ["OPENHUMAN_HOME": home.path]
    let shared = CompositionRoot.keychainStores(environment: environment, directory: home, accessGroup: sharedGroup)
    #expect(shared.client.accessGroup == sharedGroup)
    let grants = try #require(shared.tokens.shared as? KeychainSharedGrantStore)
    #expect(grants.accessGroup == sharedGroup)
    #expect(grants.service == CompositionRoot.keychainService(environment: environment, directory: home))

    let unshared = CompositionRoot.keychainStores(environment: environment, directory: home, accessGroup: nil)
    #expect(unshared.client.accessGroup == nil)
    let unsharedGrants = try #require(unshared.tokens.shared as? KeychainSharedGrantStore)
    #expect(unsharedGrants.accessGroup == nil)
}

@MainActor
@Test func aConfiguredGroupIsUsedOnlyOnceTheSignatureGrantsIt() {
    let info: [String: Any] = [KeychainSharing.infoKey: sharedGroup]
    #expect(CompositionRoot.keychainAccessGroup(info: info, entitled: [sharedGroup]) == sharedGroup)
    #expect(CompositionRoot.keychainAccessGroup(info: info, entitled: []) == nil, "an ad hoc or CI build")
    #expect(CompositionRoot.keychainAccessGroup(info: info, entitled: ["ABCDE12345.dev.openhuman.mail"]) == nil,
            "a build that holds only its own group")
    for raw in ["", "$(AppIdentifierPrefix)" + KeychainSharing.groupName, KeychainSharing.groupName] {
        #expect(CompositionRoot.keychainAccessGroup(info: [KeychainSharing.infoKey: raw], entitled: [raw, sharedGroup]) == nil,
                "unexpanded or empty: \(raw)")
    }
    #expect(CompositionRoot.keychainAccessGroup(info: [:], entitled: [sharedGroup]) == nil)
    #expect(CompositionRoot.keychainAccessGroup(info: nil, entitled: [sharedGroup]) == nil)
}

@MainActor
@Test func theBuiltAppNamesTheSharedGroupAndKeepsTheDefaultOneWithoutTheEntitlement() throws {
    let raw = try #require(Bundle.main.object(forInfoDictionaryKey: KeychainSharing.infoKey) as? String)
    #expect(raw.hasSuffix(KeychainSharing.groupName), "\(raw)")
    #expect(!CompositionRoot.entitledKeychainGroups().contains { $0.hasSuffix("." + KeychainSharing.groupName) },
            "Mail.entitlements grants no shared group yet")
    #expect(CompositionRoot.keychainAccessGroup() == nil)
}

@Test func launchSharesAClientSavedWhileICloudKeychainWasOffExactlyOnce() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("oh-launch-share-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let clients = InMemoryOAuthClientStore(syncAvailable: false)
    let client = try OAuthClientVault(store: clients).importClient(launchClientJSON())
    func launch() throws -> LiveAccountManager {
        LiveAccountManager(
            store: try MailStore.openInMemoryForTesting(),
            dependencies: LiveAccountManager.Dependencies(
                environment: [:], storeDirectory: home, clientStore: clients, tokenStore: InMemoryTokenStore(),
                transport: FakeHTTPTransport(), makeReceiver: { AnsweringReceiver(browser: RecordingBrowser()) },
                browser: RecordingBrowser(), clock: TestClock()))
    }
    let saves = clients.saveCount

    _ = try launch()
    #expect(clients.saveCount == saves, "nothing is tried while the store can't share")
    #expect(try clients.loadAll().map(\.sync) == [.unavailable])

    clients.setSyncAvailable(true)
    _ = try launch()
    #expect(try clients.loadAll().map(\.sync) == [.syncing], "shared at launch")
    #expect(try clients.loadAll().first?.config.clientID == client.clientID)
    #expect(clients.saveCount == saves + 1, "one write")

    _ = try launch()
    #expect(clients.saveCount == saves + 1, "the next launch finds it shared and writes nothing")
}
