import Foundation
import OpenHumanCore

enum DraftRowCodec {
    private struct WireAttachment: Codable {
        var localPath: String?
        var sourceAid: Int64?
        var filename: String
        var mimeType: String
        var size: Int
        var contentId: String?
        var inline: Bool
    }

    struct RemoteConflict: Codable, Equatable {
        var content: DraftContent
        var extraHeaders: [String: String]
        var gmailMessageID: String
    }

    static func addresses(_ list: [EmailAddress]) -> String {
        WireAddress.encode(list.map { WireAddress(n: $0.name, e: $0.email) })
    }

    static func decodeAddresses(_ json: String) -> [EmailAddress] {
        WireAddress.decode(json).map { EmailAddress(name: $0.n, email: $0.e) }
    }

    static func attachments(_ list: [DraftAttachment]) -> String {
        guard !list.isEmpty else { return "[]" }
        let wire = list.map {
            WireAttachment(localPath: $0.localPath, sourceAid: $0.sourceAttachmentID, filename: $0.filename,
                           mimeType: $0.mimeType, size: $0.size, contentId: $0.contentID, inline: $0.isInline)
        }
        return encode(wire) ?? "[]"
    }

    static func decodeAttachments(_ json: String) -> [DraftAttachment] {
        guard json != "[]", let list = try? JSONDecoder().decode([WireAttachment].self, from: Data(json.utf8)) else { return [] }
        return list.map {
            DraftAttachment(localPath: $0.localPath, sourceAttachmentID: $0.sourceAid, filename: $0.filename,
                            mimeType: $0.mimeType, size: $0.size, contentID: $0.contentId, isInline: $0.inline)
        }
    }

    static func headers(_ headers: [String: String]) -> String {
        guard !headers.isEmpty else { return "{}" }
        return encode(headers) ?? "{}"
    }

    static func decodeHeaders(_ json: String) -> [String: String] {
        guard json != "{}" else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: Data(json.utf8))) ?? [:]
    }

    static func header(_ name: String, in headers: [String: String]) -> String? {
        if let exact = headers[name] { return exact }
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }

    static func content(_ content: DraftContent) -> String? { encode(content) }

    static func conflict(_ conflict: RemoteConflict) -> String? { encode(conflict) }

    static func decodeConflict(_ json: String?) -> RemoteConflict? {
        guard let json else { return nil }
        return try? JSONDecoder().decode(RemoteConflict.self, from: Data(json.utf8))
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        (try? StoreJSON.encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
