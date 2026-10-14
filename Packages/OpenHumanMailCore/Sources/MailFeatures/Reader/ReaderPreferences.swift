import Foundation
import Observation

@MainActor
@Observable
public final class ReaderPreferences {
    public static let zoomSteps: [Double] = [0.9, 1.0, 1.1, 1.25, 1.5]
    static let earlierSteps: [Double: Double] = [0.8: 0.9, 1.75: 1.5, 2.0: 1.5]
    public static let zoomKey = "dev.openhuman.mail.reader.textZoom"

    public static let shared = ReaderPreferences(defaults: .standard)

    public private(set) var textZoom: Double
    @ObservationIgnored private let defaults: UserDefaults?

    public init(defaults: UserDefaults?) {
        self.defaults = defaults
        let stored = defaults?.double(forKey: Self.zoomKey) ?? 0
        textZoom = Self.zoomSteps.contains(stored) ? stored : Self.earlierSteps[stored] ?? 1
    }

    public var canZoomIn: Bool { textZoom < Self.zoomSteps.last! }
    public var canZoomOut: Bool { textZoom > Self.zoomSteps.first! }

    public var zoomPercent: String { Self.percent(textZoom) }

    nonisolated public static func percent(_ zoom: Double) -> String { "\(Int((zoom * 100).rounded()))%" }

    public func zoomIn() { set(Self.zoomSteps.first { $0 > textZoom } ?? textZoom) }
    public func zoomOut() { set(Self.zoomSteps.last { $0 < textZoom } ?? textZoom) }
    public func resetZoom() { set(1) }

    public func setZoom(_ value: Double) {
        guard Self.zoomSteps.contains(value) else { return }
        set(value)
    }

    private func set(_ value: Double) {
        guard value != textZoom else { return }
        textZoom = value
        defaults?.set(value, forKey: Self.zoomKey)
    }
}
