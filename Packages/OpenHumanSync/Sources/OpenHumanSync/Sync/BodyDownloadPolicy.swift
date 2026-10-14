import Foundation

public struct BodyDownloadPolicy: Sendable, Hashable {
    public var enabled: Bool
    public var maxMessages: Int?

    public init(enabled: Bool = true, maxMessages: Int? = nil) {
        self.enabled = enabled
        self.maxMessages = maxMessages.map { max($0, 0) }
    }
}
