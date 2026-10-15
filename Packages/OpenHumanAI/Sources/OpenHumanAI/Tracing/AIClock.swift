import Foundation

public protocol AIClock: Sendable {
    func elapsed() -> Duration
}

public struct ContinuousAIClock: AIClock {
    private let origin = ContinuousClock.now

    public init() {}

    public func elapsed() -> Duration { ContinuousClock.now - origin }
}

extension Duration {
    var wholeMilliseconds: Int {
        let parts = components
        return Int(parts.seconds) * 1_000 + Int(parts.attoseconds / 1_000_000_000_000_000)
    }
}
