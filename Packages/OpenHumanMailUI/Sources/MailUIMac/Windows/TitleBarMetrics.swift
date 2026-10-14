import AppKit

@MainActor
protocol TitleBarMeasuring: AnyObject {
    var contentViewHeight: CGFloat { get }
    var layoutRectMaxY: CGFloat { get }
    var isFullScreen: Bool { get }
}

extension NSWindow: TitleBarMeasuring {
    var contentViewHeight: CGFloat { contentView?.bounds.height ?? contentLayoutRect.maxY }
    var layoutRectMaxY: CGFloat { contentLayoutRect.maxY }
    var isFullScreen: Bool { styleMask.contains(.fullScreen) }
}

enum TitleBarMetrics {
    @MainActor
    static func stripHeight(of window: some TitleBarMeasuring) -> CGFloat {
        guard !window.isFullScreen else { return 0 }
        return max(0, (window.contentViewHeight - window.layoutRectMaxY).rounded(.up))
    }
}
