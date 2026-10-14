import AppKit
import MailFeatures

@MainActor
final class WindowPlaceTracker {
    let window: NSWindow
    private let router: AppRouter
    private var observers: [any NSObjectProtocol] = []

    init(window: NSWindow, router: AppRouter) {
        self.window = window
        self.router = router
        apply(router.restoredWindowPlace)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification, NSWindow.didResizeNotification,
            NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.capture() }
            }
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    static func visibleFrames(of screens: [NSScreen] = NSScreen.screens) -> [CGRect] {
        screens.map(\.visibleFrame)
    }

    static func displayID(of screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    func apply(_ place: WindowPlace?) {
        guard let place else { return }
        if let frame = place.validatedFrame(screens: Self.visibleFrames()), frame != window.frame {
            window.setFrame(frame, display: false)
        }
        if place.isFullScreen {
            if !window.styleMask.contains(.fullScreen) {
                DispatchQueue.main.async { [window] in window.toggleFullScreen(nil) }
            }
        } else if place.isZoomed, !window.isZoomed {
            window.zoom(nil)
        }
    }

    func capture() {
        let full = window.styleMask.contains(.fullScreen)
        let frame = full ? (router.windowPlace?.frame ?? window.frame) : window.frame
        let place = WindowPlace(frame: frame, displayID: Self.displayID(of: window.screen), isFullScreen: full,
                                isZoomed: !full && window.isZoomed)
        if place != router.windowPlace { router.windowPlace = place }
    }
}
