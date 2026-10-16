import Crypto
import Foundation

public enum CloudCodecError: Error, Sendable, Hashable {
    case emptyDocument
    case unknownKey(String)
    case unsupportedFormat(Int)
    case payloadUnavailable
    case tampered
    case malformed
    case envelopeMismatch

    public var code: String {
        switch self {
        case .emptyDocument: return "emptyDocument"
        case .unknownKey: return "unknownKey"
        case .unsupportedFormat: return "unsupportedFormat"
        case .payloadUnavailable: return "payloadUnavailable"
        case .tampered: return "tampered"
        case .malformed: return "malformed"
        case .envelopeMismatch: return "envelopeMismatch"
        }
    }
}

struct CloudRecordCodec {
    static let currentFormat = 1

    let inlineLimit: Int

    func encode(_ document: CloudDocument, id: CloudRecordID, type: String, key: CloudKey, writer: String,
                systemFields: Data?, forceAsset: Bool) throws -> CloudRecord {
        guard let version = document.version else { throw CloudCodecError.emptyDocument }
        var record = CloudRecord(id: id, type: type, format: Self.currentFormat, keyID: key.id, hlc: version, device: writer,
                                 deleted: document.isDeleted, payload: .unavailable, systemFields: systemFields)
        let plaintext = try CloudCanonical.encode(document)
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key.material), authenticating: record.authenticatedData)
        guard let sealed = box.combined else { throw CloudCodecError.malformed }
        record.payload = forceAsset || sealed.count > inlineLimit ? .asset(sealed) : .inline(sealed)
        return record
    }

    func decode(_ record: CloudRecord, key: CloudKey) throws -> CloudDocument {
        guard record.format <= Self.currentFormat else { throw CloudCodecError.unsupportedFormat(record.format) }
        guard record.keyID == key.id else { throw CloudCodecError.unknownKey(record.keyID) }
        let sealed: Data
        switch record.payload {
        case .inline(let data), .asset(let data): sealed = data
        case .unavailable: throw CloudCodecError.payloadUnavailable
        }
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key.material), authenticating: record.authenticatedData)
        } catch {
            throw CloudCodecError.tampered
        }
        guard let document = try? JSONDecoder().decode(CloudDocument.self, from: plaintext) else {
            throw CloudCodecError.malformed
        }
        guard document.version == record.hlc, document.isDeleted == record.deleted else {
            throw CloudCodecError.envelopeMismatch
        }
        return document
    }
}
