import Crypto
import Foundation
import OpenHumanCore

extension OAuthClientConfig {
    public static let clientsDirectoryName = "oauth-clients"

    public var registryKey: String { Self.registryKey(clientID: clientID) }

    public static func registryKey(clientID: String) -> String {
        SHA256.hash(data: Data(clientID.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public var shortID: String { Self.shortID(clientID: clientID) }

    public static func shortID(clientID: String) -> String {
        let trimmed = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.range(of: ".apps").map { String(trimmed[..<$0.lowerBound]) } ?? trimmed
        return String(base.suffix(8))
    }

    @discardableResult
    public static func importClient(_ data: Data, storeDirectory: URL) throws -> OAuthClientConfig {
        let config = try parseGoogleJSON(data, source: "import")
        let replacesDefault: Bool
        switch storedDefault(storeDirectory) {
        case .missing, .unusable: replacesDefault = true
        case .client(let current): replacesDefault = current.clientID == config.clientID || !current.hasClientSecret
        }
        do {
            try SecureFile.ensureDirectory(storeDirectory, mode: 0o700, tighten: false)
            try SecureFile.ensureDirectory(clientsDirectoryURL(storeDirectory), mode: 0o700, tighten: true)
            let normalized = try config.normalizedGoogleJSON()
            try SecureFile.writeAtomically(normalized, to: clientFileURL(storeDirectory, key: config.registryKey), mode: 0o600)
            if replacesDefault {
                try SecureFile.writeAtomically(normalized, to: storeFileURL(storeDirectory), mode: 0o600)
            }
        } catch let failure as SecureFile.Failure {
            throw OAuthError.configurationMissing("import: could not write \(clientsDirectoryName) (\(failure.description))")
        }
        Log(.oauth).notice("OAuth client imported into \(clientsDirectoryName)\(replacesDefault ? " (also the default)" : "")")
        return config
    }

    public static func importedClients(storeDirectory: URL) -> [OAuthClientConfig] {
        let directory = clientsDirectoryURL(storeDirectory)
        guard let type = (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType,
              type == .typeDirectory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var clients: [OAuthClientConfig] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard let config = try? readClientFile(url, label: clientsDirectoryName) else {
                Log(.oauth).notice("\(clientsDirectoryName): a client file was skipped (not a valid owner-only client file)")
                continue
            }
            guard name == "\(config.registryKey).json" else {
                Log(.oauth).notice("\(clientsDirectoryName): a client file was skipped (its name is not its client's key)")
                continue
            }
            clients.append(config)
        }
        return clients
    }

    public static func availableClients(environment: [String: String], storeDirectory: URL?) -> [OAuthClientConfig] {
        var result: [OAuthClientConfig] = []
        func add(_ client: OAuthClientConfig) {
            if !result.contains(where: { $0.clientID == client.clientID }) { result.append(client) }
        }
        if let main = try? load(environment: environment, storeDirectory: storeDirectory) {
            add(main)
        }
        if let storeDirectory {
            if case .client(let legacy) = storedDefault(storeDirectory) { add(legacy) }
            for client in importedClients(storeDirectory: storeDirectory) { add(client) }
        }
        return result
    }

    public static func inspectImport(_ data: Data) throws -> OAuthClientConfig {
        try parseGoogleJSON(data, source: "import")
    }

    public static func isRegistryKey(_ key: String) -> Bool {
        key.utf8.count == 32 && key.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    public static func importedAt(key: String, storeDirectory: URL) -> Date? {
        guard isRegistryKey(key) else { return nil }
        let url = clientFileURL(storeDirectory, key: key)
        guard SecureFile.inspect(url).kind == .regularFile,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return attributes[.modificationDate] as? Date
    }

    public static func removeImportedClient(key: String, storeDirectory: URL) throws {
        guard isRegistryKey(key) else {
            throw OAuthError.configurationMissing("\(clientsDirectoryName): not a client key")
        }
        let url = clientFileURL(storeDirectory, key: key)
        switch SecureFile.inspect(url).kind {
        case .missing: return
        case .regularFile: break
        case .other: throw OAuthError.configurationMissing("\(clientsDirectoryName): not a regular file")
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw OAuthError.configurationMissing("\(clientsDirectoryName): the client file could not be removed")
        }
        Log(.oauth).notice("\(clientsDirectoryName): a client file was removed")
    }

    static func clientsDirectoryURL(_ storeDirectory: URL) -> URL {
        storeDirectory.appendingPathComponent(clientsDirectoryName, isDirectory: true)
    }

    static func clientFileURL(_ storeDirectory: URL, key: String) -> URL {
        clientsDirectoryURL(storeDirectory).appendingPathComponent("\(key).json", isDirectory: false)
    }

    private enum StoredDefault { case missing, unusable, client(OAuthClientConfig) }

    private static func storedDefault(_ storeDirectory: URL) -> StoredDefault {
        let url = storeFileURL(storeDirectory)
        guard SecureFile.inspect(url).kind != .missing else { return .missing }
        guard let config = try? readClientFile(url, label: storeFileName) else { return .unusable }
        return .client(config)
    }
}

extension OAuthClientConfig {
    static func legacyDefaultClient(storeDirectory: URL) -> OAuthClientConfig? {
        if case .client(let config) = storedDefault(storeDirectory) { return config }
        return nil
    }

    static func deleteClientFile(_ url: URL) throws {
        guard SecureFile.inspect(url).kind == .regularFile else {
            throw OAuthError.configurationMissing("not a regular file")
        }
        try FileManager.default.removeItem(at: url)
    }

    static func removeClientsDirectoryIfEmpty(_ storeDirectory: URL) {
        let directory = clientsDirectoryURL(storeDirectory)
        guard let type = (try? FileManager.default.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType,
              type == .typeDirectory,
              (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}

extension OAuthClientConfig {
    public static func google(clientID: String, clientSecret: String?) -> OAuthClientConfig {
        OAuthClientConfig(clientID: clientID, clientSecret: (clientSecret ?? "").isEmpty ? nil : clientSecret,
                          authURI: defaultAuthURI, tokenURI: defaultTokenURI)
    }
}
