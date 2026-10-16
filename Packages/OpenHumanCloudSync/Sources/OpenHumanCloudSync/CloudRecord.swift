import Crypto
import Foundation

public struct CloudZoneID: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let name: String

    public init(_ name: String) {
        self.name = name
    }

    public static let app = CloudZoneID("app")

    // Why: zone names are visible to the server, so the address is hashed
    public static func account(email: String) -> CloudZoneID {
        let digest = SHA256.hash(data: Data(("openhuman.account.v1:" + email.lowercased()).utf8))
        return CloudZoneID("acct-" + CloudCanonical.hex(digest.prefix(8)))
    }

    public var kind: String {
        if self == .app { return "app" }
        return name.hasPrefix("acct-") ? "account" : "other"
    }

    public static func < (lhs: CloudZoneID, rhs: CloudZoneID) -> Bool { lhs.name < rhs.name }

    public var description: String { name }
}

public struct CloudRecordID: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let zone: CloudZoneID
    public let name: String

    public init(zone: CloudZoneID, name: String) {
        self.zone = zone
        self.name = name
    }

    public var isValid: Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix("_") && name.utf8.allSatisfy { (0x21...0x7E).contains($0) }
    }

    public static func < (lhs: CloudRecordID, rhs: CloudRecordID) -> Bool {
        (lhs.zone.name, lhs.name) < (rhs.zone.name, rhs.name)
    }

    public var description: String { zone.name + "/" + name }
}

public enum CloudPayload: Sendable, Hashable, Codable {
    case inline(Data)
    case asset(Data)
    // A conflict reply carries no asset bytes; the record has to be fetched
    case unavailable
}

public enum CloudRecordField {
    public static let format = "f"
    public static let keyID = "kid"
    public static let hlc = "hlc"
    public static let device = "dev"
    public static let deleted = "del"
    public static let blob = "blob"
    public static let asset = "asset"
}

public struct CloudRecord: Sendable, Hashable, Codable {
    public var id: CloudRecordID
    public var type: String
    public var format: Int
    public var keyID: String
    public var hlc: HLC
    public var device: String
    public var deleted: Bool
    public var payload: CloudPayload
    public var systemFields: Data?

    public init(id: CloudRecordID, type: String, format: Int, keyID: String, hlc: HLC, device: String, deleted: Bool,
                payload: CloudPayload, systemFields: Data? = nil) {
        self.id = id
        self.type = type
        self.format = format
        self.keyID = keyID
        self.hlc = hlc
        self.device = device
        self.deleted = deleted
        self.payload = payload
        self.systemFields = systemFields
    }

    public var estimatedBytes: Int {
        var inline = 0
        if case .inline(let data) = payload { inline = data.count }
        let names = [id.zone.name, id.name, type, keyID, hlc.description, device].reduce(0) { $0 + $1.utf8.count }
        return inline + names + 256
    }

    // Why: binds the sealed payload to its record and envelope, so neither can be moved or altered on the server
    var authenticatedData: Data {
        let parts = ["openhuman.cloud.v1", id.zone.name, id.name, type, String(format), keyID, hlc.description, device,
                     deleted ? "1" : "0"]
        return Data(parts.joined(separator: "\u{1F}").utf8)
    }
}
