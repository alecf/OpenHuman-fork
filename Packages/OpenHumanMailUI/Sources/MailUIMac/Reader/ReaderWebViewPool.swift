import AppKit
import WebKit

@MainActor
final class ReaderWebViewPool {
    static let capacity = 6

    private(set) var idle: [ReaderWebView] = []
    private(set) var created = 0

    func dequeue(_ mode: ReaderWebKit.Mode, webKit: ReaderWebKit) -> ReaderWebView? {
        if let i = idle.firstIndex(where: { $0.mode == mode }) { return idle.remove(at: i) }
        guard let configuration = webKit.makeConfiguration(mode) else { return nil }
        created += 1
        return ReaderWebView(mode: mode, configuration: configuration, webKit: webKit)
    }

    func recycle(_ view: ReaderWebView) {
        guard !idle.contains(where: { $0 === view }) else { return }
        view.resetForPool()
        if idle.count < Self.capacity { idle.append(view) }
    }
}
