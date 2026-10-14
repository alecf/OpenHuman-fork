import Foundation

public struct UndoToken: Hashable, Sendable, Codable {
    public let payload: Data
    public let changesNothing: Bool

    public init(payload: Data, changesNothing: Bool = false) {
        self.payload = payload
        self.changesNothing = changesNothing
    }

    private enum CodingKeys: String, CodingKey { case payload, changesNothing }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        payload = try container.decode(Data.self, forKey: .payload)
        changesNothing = try container.decodeIfPresent(Bool.self, forKey: .changesNothing) ?? false
    }
}

public protocol MailUndoing: Sendable {
    func undo(_ token: UndoToken) async throws -> UndoToken?
}
