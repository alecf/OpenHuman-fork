import AppKit
import MailFeatures
import MailTheme
import MailUI
import SwiftUI

@MainActor
final class FormatBarPanel {
    private var panel: NSPanel?
    private let model = FormatBarModel()
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []

    var isVisible: Bool { panel?.isVisible == true }

    var frame: NSRect? { isVisible ? panel?.frame : nil }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        if let panel {
            parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    func show(over selection: NSRect, in window: NSWindow, state: ComposeFormatState, theme: ResolvedTheme,
              scrolling: [NSClipView], action: @escaping @MainActor (ComposeFormatCommand) -> Void) {
        model.state = state
        model.theme = theme
        model.action = action
        let panel = self.panel ?? makePanel()
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(Self.origin(for: size, over: selection, in: window))
        if parent !== window {
            if let parent { parent.removeChildWindow(panel) }
            window.addChildWindow(panel, ordered: .above)
            parent = window
        }
        if !panel.isVisible { panel.orderFront(nil) }
        watch(scrolling)
    }

    func hide() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let panel else { return }
        if let parent { parent.removeChildWindow(panel) }
        parent = nil
        panel.orderOut(nil)
    }

    static func origin(for size: NSSize, over selection: NSRect, in window: NSWindow) -> NSPoint {
        let room = FormatBarRoot.shadowRoom
        let gap: CGFloat = 6
        let screen = window.screen?.visibleFrame ?? window.frame
        var x = selection.minX - room
        x = min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width))
        var y = selection.maxY + gap - room
        if y + size.height - room > min(screen.maxY, window.frame.maxY) {
            y = selection.minY - gap - size.height + room
        }
        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    private func makePanel() -> NSPanel {
        let panel = FormatBarWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: FormatBarMetrics.height),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        let hosting = FirstMouseHostingView(rootView: FormatBarRoot(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        panel.contentView = hosting
        self.panel = panel
        return panel
    }

    private func watch(_ clips: [NSClipView]) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = clips.map { clip in
            clip.postsBoundsChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                          queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            }
        }
    }
}

@MainActor @Observable
final class FormatBarModel {
    var state = ComposeFormatState()
    var theme: ResolvedTheme = .light
    @ObservationIgnored var action: @MainActor (ComposeFormatCommand) -> Void = { _ in }
}

struct FormatBarRoot: View {
    static let shadowRoom: CGFloat = 8

    let model: FormatBarModel

    var body: some View {
        FormatBarView(state: model.state, style: .floating) { command in model.action(command) }
            .fixedSize()
            .padding(Self.shadowRoom)
            .environment(\.theme, model.theme)
            .environment(\.colorScheme, model.theme.appearance == .dark ? .dark : .light)
            .tint(model.theme.accentFill.color)
    }
}

final class FormatBarWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
