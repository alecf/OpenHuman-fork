import AppKit
import SwiftUI

@MainActor
enum QuietTestHost {
    nonisolated static var isActive: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static var observers: [any NSObjectProtocol] = []
    private static var orderedBack: Set<ObjectIdentifier> = []

    static func installIfTesting() {
        guard isActive, observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.willFinishLaunchingNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.setActivationPolicy(.prohibited) }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                nonisolated(unsafe) let window = note.object as? NSWindow
                MainActor.assumeIsolated { window.map(quiet) }
            })
        }
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                            queue: .main) { _ in
            MainActor.assumeIsolated { NSApp.deactivate() }
        })
    }

    static func quiet(_ window: NSWindow) {
        guard isActive else { return }
        if window.alphaValue != 0 { window.alphaValue = 0 }
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.animationBehavior = .none
        if window.isVisible, orderedBack.insert(ObjectIdentifier(window)).inserted { window.orderBack(nil) }
    }

    // AppKit pulls an off-screen titled window back on screen with a fade-in, so hide it by alpha instead
    static func prepareTestWindow(_ window: NSWindow) {
        window.animationBehavior = .none
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
    }

    struct WindowHook: NSViewRepresentable {
        func makeNSView(context: Context) -> HookView { HookView() }
        func updateNSView(_ view: HookView, context: Context) {}

        final class HookView: NSView {
            override func viewWillMove(toWindow newWindow: NSWindow?) {
                super.viewWillMove(toWindow: newWindow)
                if let newWindow { MainActor.assumeIsolated { QuietTestHost.quiet(newWindow) } }
            }
        }
    }
}

extension View {
    @ViewBuilder
    func quietUnderTests() -> some View {
        if QuietTestHost.isActive {
            background(QuietTestHost.WindowHook().frame(width: 0, height: 0))
        } else {
            self
        }
    }
}
