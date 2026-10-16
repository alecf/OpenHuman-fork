import Foundation
import Security
import Synchronization
import Testing
@testable import MailSystem

final class FakeSecretKeychain: SecretKeychainBackend {
    struct Item: Sendable, Equatable {
        var service: String
        var account: String
        var synchronizable: Bool
        var data: Data
    }
    private struct State {
        var items: [Item] = []
        var calls: [String] = []
        var pinned = true
        var accessibility: [String?] = []
        var answer: Item?
        var status: OSStatus?
        var addStatus: OSStatus?
    }
    private let state = Mutex(State())

    var items: [Item] { state.withLock { $0.items } }
    var calls: [String] { state.withLock { $0.calls } }
    var everyQueryPinned: Bool { state.withLock { $0.pinned } }
    var accessibility: [String?] { state.withLock { $0.accessibility } }

    func plant(_ item: Item) { state.withLock { $0.items.append(item) } }
    func answerWith(_ item: Item?, status: OSStatus? = nil) { state.withLock { $0.answer = item; $0.status = status } }
    func failAdds(with status: OSStatus) { state.withLock { $0.addStatus = status } }

    private func record(_ name: String, _ query: [String: Any]) {
        let pinned = (query[kSecAttrSynchronizable as String] as? Bool) == false
            && (query[kSecUseDataProtectionKeychain as String] as? Bool) == false
        state.withLock {
            $0.calls.append(name)
            $0.pinned = $0.pinned && pinned
        }
    }

    private func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        if let service = query[kSecAttrService as String] as? String, service != item.service { return false }
        if let account = query[kSecAttrAccount as String] as? String, account != item.account { return false }
        return ((query[kSecAttrSynchronizable as String] as? Bool) ?? false) == item.synchronizable
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        record("add", attributes)
        guard let data = attributes[kSecValueData as String] as? Data,
              let service = attributes[kSecAttrService as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String else { return errSecParam }
        let item = Item(service: service, account: account,
                        synchronizable: (attributes[kSecAttrSynchronizable as String] as? Bool) ?? false, data: data)
        let accessible = attributes[kSecAttrAccessible as String] as? String
        return state.withLock { s in
            s.accessibility.append(accessible)
            if let failure = s.addStatus { return failure }
            if s.items.contains(where: { $0.service == item.service && $0.account == item.account
                                           && $0.synchronizable == item.synchronizable }) { return errSecDuplicateItem }
            s.items.append(item)
            return errSecSuccess
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        record("copy", query)
        let (override, status, stored) = state.withLock { ($0.answer, $0.status, $0.items) }
        if let status, status != errSecSuccess { return (status, nil) }
        guard let found = override ?? stored.first(where: { matches($0, query) }) else {
            return (errSecItemNotFound, nil)
        }
        let attributes: [String: Any] = [kSecAttrService as String: found.service,
                                         kSecAttrAccount as String: found.account,
                                         kSecAttrSynchronizable as String: found.synchronizable]
        return (errSecSuccess, attributes as NSDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        record("delete", query)
        return state.withLock { s in
            let before = s.items.count
            s.items.removeAll { matches($0, query) }
            return s.items.count < before ? errSecSuccess : errSecItemNotFound
        }
    }
}

@Suite struct KeychainSecretStoreTests {
    private let service = "dev.openhuman.mail.secrets.v1"
    private let whenUnlockedThisDeviceOnly = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    private func store(_ keychain: FakeSecretKeychain) -> KeychainSecretStore {
        KeychainSecretStore(backend: keychain)
    }

    @Test func aFirstSaveAddsOneUnsynchronizedItemThatIsNotReadableWhileLocked() throws {
        let keychain = FakeSecretKeychain()
        let secrets = store(keychain)
        #expect(KeychainSecretStore.service == service)
        try secrets.setSecret("synthetic-key-1", for: "openai")
        #expect(keychain.calls == ["add"])
        #expect(keychain.items == [.init(service: service, account: "openai", synchronizable: false,
                                         data: Data("synthetic-key-1".utf8))])
        #expect(keychain.accessibility == [whenUnlockedThisDeviceOnly])
        #expect(secrets.hasSecret(for: "openai"))
        #expect(!secrets.hasSecret(for: "anthropic"))
        #expect(keychain.everyQueryPinned)
    }

    @Test func saveReplacesAnExistingItemAndNeverUpdatesItInPlace() throws {
        let keychain = FakeSecretKeychain()
        keychain.plant(.init(service: service, account: "openai", synchronizable: false, data: Data("planted".utf8)))
        try store(keychain).setSecret("synthetic-key-2", for: "openai")
        #expect(keychain.calls == ["add", "delete", "add"])
        #expect(keychain.items.map(\.data) == [Data("synthetic-key-2".utf8)])
        #expect(keychain.accessibility == [whenUnlockedThisDeviceOnly, whenUnlockedThisDeviceOnly],
                "the replacement asks for the accessibility again")
        #expect(keychain.everyQueryPinned)
    }

    @Test func theStoreHasNoUpdatePath() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MailSystem/KeychainSecretStore.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("SecItemAdd(") && text.contains("SecItemDelete("))
        #expect(!text.contains("SecItemUpdate("), "an item is replaced, never updated in place")
    }

    @Test func onlyAnItemThatIsExactlyOursCounts() {
        let cases: [(String, FakeSecretKeychain.Item)] = [
            ("other service", .init(service: "com.example.other", account: "openai", synchronizable: false,
                                    data: Data())),
            ("other name", .init(service: service, account: "anthropic", synchronizable: false, data: Data())),
            ("synchronized", .init(service: service, account: "openai", synchronizable: true, data: Data())),
        ]
        for (label, item) in cases {
            let keychain = FakeSecretKeychain()
            keychain.answerWith(item)
            #expect(!store(keychain).hasSecret(for: "openai"), "\(label)")
        }
        let keychain = FakeSecretKeychain()
        keychain.answerWith(.init(service: service, account: "openai", synchronizable: false, data: Data()))
        #expect(store(keychain).hasSecret(for: "openai"))
        keychain.answerWith(nil, status: errSecInteractionNotAllowed)
        #expect(!store(keychain).hasSecret(for: "openai"), "a keychain that refuses answers no")
        #expect(keychain.everyQueryPinned)
    }

    @Test func removeDeletesOnlyOurItemAndIsIdempotent() throws {
        let keychain = FakeSecretKeychain()
        let synced = FakeSecretKeychain.Item(service: service, account: "openai", synchronizable: true,
                                             data: Data("s".utf8))
        keychain.plant(synced)
        let secrets = store(keychain)
        try secrets.setSecret("synthetic-key-3", for: "openai")
        try secrets.removeSecret(for: "openai")
        try secrets.removeSecret(for: "openai")
        #expect(keychain.items == [synced], "a synchronized item is never written or deleted")
        #expect(keychain.everyQueryPinned)
    }

    @Test func failuresArePassedOnAsStatusCodesOnly() {
        let keychain = FakeSecretKeychain()
        keychain.failAdds(with: errSecInteractionNotAllowed)
        do {
            try store(keychain).setSecret("synthetic-key-4", for: "openai")
            Issue.record("expected a Keychain error")
        } catch let error as KeychainError {
            #expect(error.status == errSecInteractionNotAllowed)
            #expect(error.description == "Keychain error \(errSecInteractionNotAllowed)")
        } catch {
            Issue.record("unexpected error type \(type(of: error))")
        }
        #expect(keychain.items.isEmpty)
    }
}
