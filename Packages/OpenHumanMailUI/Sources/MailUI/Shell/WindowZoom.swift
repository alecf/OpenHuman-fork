#if os(macOS)
import AppKit
import Observation

public enum TitleBarDoubleClickAction: Equatable, Sendable {
    case zoom, minimize, none

    public init(preference: String?) {
        switch preference {
        case "Minimize": self = .minimize
        case "None": self = .none
        default: self = .zoom
        }
    }
}

public enum WindowZoomPlan {
    public static let defaultSize = CGSize(width: 1360, height: 860)
    public static let fillTolerance: CGFloat = 4

    public static func fillFrame(visible: CGRect) -> CGRect { visible }

    public static func isFilled(frame: CGRect, visible: CGRect) -> Bool {
        guard !visible.isEmpty else { return false }
        return abs(frame.minX - visible.minX) <= fillTolerance && abs(frame.maxX - visible.maxX) <= fillTolerance
            && abs(frame.minY - visible.minY) <= fillTolerance && abs(frame.maxY - visible.maxY) <= fillTolerance
    }

    public static func restoreFrame(saved: CGRect?, visible: CGRect, minSize: CGSize,
                                    defaultSize: CGSize = WindowZoomPlan.defaultSize) -> CGRect {
        let wanted = saved?.size ?? defaultSize
        let width = min(max(wanted.width, minSize.width), max(visible.width, minSize.width))
        let height = min(max(wanted.height, minSize.height), max(visible.height, minSize.height))
        let size = CGSize(width: width, height: height)
        var origin: CGPoint
        if let saved, saved.intersects(visible) {
            origin = saved.origin
        } else {
            origin = CGPoint(x: visible.midX - width / 2, y: visible.midY - height / 2)
        }
        origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - width))
        origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - height))
        return CGRect(origin: origin, size: size)
    }

    public static func toggle(current: CGRect, saved: CGRect?, visible: CGRect, minSize: CGSize)
        -> (frame: CGRect, remember: CGRect?) {
        if isFilled(frame: current, visible: visible) {
            return (restoreFrame(saved: saved, visible: visible, minSize: minSize), nil)
        }
        return (fillFrame(visible: visible), current)
    }
}

@MainActor @Observable
public final class WindowZoomMenuState {
    public static let shared = WindowZoomMenuState()
    public private(set) var isZoomed = false
    public private(set) var canZoom = false

    public func refresh(from window: NSWindow?) {
        isZoomed = window.map(WindowZoomController.isZoomed) ?? false
        canZoom = window.map { !$0.styleMask.contains(.fullScreen) } ?? false
    }
}

@MainActor
public enum WindowZoomController {
    private static let remembered = NSMapTable<NSWindow, NSValue>.weakToStrongObjects()

    private static func visibleFrame(of window: NSWindow) -> CGRect? {
        (window.screen ?? NSScreen.main)?.visibleFrame
    }

    public static func effectiveMinSize(of window: NSWindow) -> CGSize {
        let content = window.frameRect(forContentRect: CGRect(origin: .zero, size: window.contentMinSize)).size
        return CGSize(width: max(window.minSize.width, content.width), height: max(window.minSize.height, content.height))
    }

    public static func isZoomed(_ window: NSWindow) -> Bool {
        guard !window.styleMask.contains(.fullScreen), let visible = visibleFrame(of: window) else { return false }
        return WindowZoomPlan.isFilled(frame: window.frame, visible: visible)
    }

    public static func toggle(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), let visible = visibleFrame(of: window) else { return }
        let plan = WindowZoomPlan.toggle(current: window.frame, saved: remembered.object(forKey: window)?.rectValue,
                                         visible: visible, minSize: effectiveMinSize(of: window))
        if let remember = plan.remember { remembered.setObject(NSValue(rect: remember), forKey: window) }
        else { remembered.removeObject(forKey: window) }
        window.setFrame(plan.frame, display: true, animate: true)
        WindowZoomMenuState.shared.refresh(from: window)
    }

    public static func handleTitleBarDoubleClick(in window: NSWindow, preference: String? = UserDefaults.standard
        .string(forKey: "AppleActionOnDoubleClick")) {
        switch TitleBarDoubleClickAction(preference: preference) {
        case .zoom: toggle(window)
        case .minimize: window.performMiniaturize(nil)
        case .none: break
        }
    }
}
#endif
