import Foundation
import OpenHumanCore
import OpenHumanGmail
import Security

public struct KeychainTokenStore: TokenStore {
    public let service: String
    public let label: String
    public let items: KeychainItems
    let isAppProcess: @Sendable () -> Bool

    static let maxItemBytes = 16 * 1024
    public static let defaultLabel = "OpenHuman Mail (Gmail OAuth)"

    public init(service: String = OHIdentifiers.keychainService, label: String = KeychainTokenStore.defaultLabel) {
        self.init(service: service, items: .shared, isAppProcess: { KeychainTokenStore.runningInAppBundle() },
                  label: label)
    }

    init(service: String, items: KeychainItems, isAppProcess: @escaping @Sendable () -> Bool,
         label: String = KeychainTokenStore.defaultLabel) {
        self.service = service
        self.label = label
        self.items = items
        self.isAppProcess = isAppProcess
    }

    public func load(account email: String) throws -> StoredToken? {
        try requireAppProcess()
        let key = KeychainItems.Item(service: service, account: try Self.account(email))
        return try tokenErrors {
            guard let entry = try items.read(key) else { return nil }
            guard entry.data.count <= Self.maxItemBytes,
                  let payload = try? JSONDecoder().decode(TokenItemPayload.self, from: entry.data),
                  !payload.refreshToken.isEmpty, !payload.clientID.isEmpty else { throw TokenStoreError.corrupt }
            var token = payload.token
            if let memory = items.memory(key, as: TokenAccessMemory.self),
               memory.refreshToken == token.refreshToken, memory.clientID == token.clientID {
                token.accessToken = memory.accessToken
                token.accessTokenExpiry = memory.accessTokenExpiry
            }
            return token
        }
    }

    public func save(_ token: StoredToken, account email: String) throws {
        try requireAppProcess()
        let key = KeychainItems.Item(service: service, account: try Self.account(email))
        guard !token.refreshToken.isEmpty, !token.clientID.isEmpty,
              let validation = try? JSONEncoder().encode(token), validation.count <= Self.maxItemBytes else {
            throw TokenStoreError.corrupt
        }
        try tokenErrors {
            try items.withItem(key) {
                let (previous, device) = stored(key)
                var payload = TokenItemPayload(token, device: device)
                payload.accessToken = nil
                payload.accessTokenExpiry = nil
                var comparable = previous
                comparable?.accessToken = nil
                comparable?.accessTokenExpiry = nil
                if comparable != payload {
                    let data = try payload.encoded()
                    guard data.count <= Self.maxItemBytes else { throw TokenStoreError.corrupt }
                    try items.write(key, data: data, label: label, generic: payload.sharing)
                }
                items.setMemory(key, TokenAccessMemory(token))
            }
        }
    }

    // Why: an unreadable item is replaced without asking again, so it keeps only the sharing its attributes record
    private func stored(_ key: KeychainItems.Item) -> (payload: TokenItemPayload?, device: TokenDeviceRecord?) {
        do {
            let previous = try items.read(key).map { try JSONDecoder().decode(TokenItemPayload.self, from: $0.data) }
            return (previous, previous?.device)
        } catch {
            let sharing = items.storedAttributes(key)?[kSecAttrGeneric as String] as? Data
            return (nil, TokenItemPayload.device(sharing: sharing))
        }
    }

    public func delete(account email: String) throws {
        try requireAppProcess()
        let key = KeychainItems.Item(service: service, account: try Self.account(email))
        try tokenErrors { try items.delete(key) }
    }

    public func allAccounts() throws -> [String] {
        try requireAppProcess()
        return try tokenErrors { try items.accounts(service: service).filter { (try? Self.account($0)) == $0 } }
    }

    func baseQuery(account: String?) -> [String: Any] {
        return items.query(service: service, account: account)
    }

    func addAttributes(account: String, data: Data) -> [String: Any] {
        return items.addAttributes(.init(service: service, account: account), data: data, label: label)
    }

    static func account(_ email: String) throws -> String {
        let account = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !account.isEmpty, !account.contains("\0") else { throw TokenStoreError.invalidAccount }
        return account
    }

    private func requireAppProcess() throws {
        guard isAppProcess() else { throw TokenStoreError.notAppProcess }
    }

    static func runningInAppBundle() -> Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }
}

protocol KeychainBackend: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?)
    func delete(_ query: [String: Any]) -> OSStatus
    // Why: a delete then add would reach other devices as a removal first, so synchronizable items update in place
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
}

extension KeychainBackend {
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus { errSecUnimplemented }
}

struct SecItemBackend: KeychainBackend {
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        Self.noteThread()
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        Self.noteThread()
        return SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, CFTypeRef?) {
        Self.noteThread()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        Self.noteThread()
        return SecItemDelete(query as CFDictionary)
    }

    // Why: a dialog raised from the main thread freezes every window until it is answered
    private static func noteThread() {
        #if DEBUG
        if Thread.isMainThread { Log(.keychain).error("a Keychain call ran on the main thread") }
        #endif
    }
}

struct TokenItemPayload: Codable, Equatable {
    var refreshToken: String
    var accessToken: String?
    var accessTokenExpiry: Date?
    var grantedScopes: [String]
    var clientID: String
    var device: TokenDeviceRecord?
    init(_ token: StoredToken, device: TokenDeviceRecord? = nil) {
        refreshToken = token.refreshToken
        accessToken = token.accessToken
        accessTokenExpiry = token.accessTokenExpiry
        grantedScopes = token.grantedScopes
        clientID = token.clientID
        self.device = device
    }
    var token: StoredToken {
        StoredToken(refreshToken: refreshToken, accessToken: accessToken, accessTokenExpiry: accessTokenExpiry,
                    grantedScopes: grantedScopes, clientID: clientID)
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self)
    }

    private enum Sharing: String { case shared, dontSync, ownSignIn }

    var sharing: Data? {
        guard let device else { return nil }
        var sharing = Sharing.shared
        if device.choice == .ownSignIn || device.refused != nil { sharing = .ownSignIn }
        if device.choice == .dontSync { sharing = .dontSync }
        return Data(sharing.rawValue.utf8)
    }

    static func device(sharing: Data?) -> TokenDeviceRecord {
        switch sharing.flatMap({ String(data: $0, encoding: .utf8) }).flatMap(Sharing.init(rawValue:)) {
        case .shared?: TokenDeviceRecord()
        case .ownSignIn?: TokenDeviceRecord(choice: .ownSignIn)
        case .dontSync?, nil: TokenDeviceRecord(choice: .dontSync)
        }
    }
}

private struct TokenAccessMemory: Sendable {
    var refreshToken: String
    var clientID: String
    var accessToken: String?
    var accessTokenExpiry: Date?
    init(_ token: StoredToken) {
        refreshToken = token.refreshToken
        clientID = token.clientID
        accessToken = token.accessToken
        accessTokenExpiry = token.accessTokenExpiry
    }
}

func tokenErrors<R>(_ body: () throws -> R) throws -> R {
    do { return try body() }
    catch KeychainItemsError.notOurs { throw TokenStoreError.corrupt }
    catch KeychainItemsError.status(let status) { throw TokenStoreError.keychain(status) }
}
