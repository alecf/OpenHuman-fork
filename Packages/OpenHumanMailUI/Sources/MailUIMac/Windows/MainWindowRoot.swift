import AppKit
import MailFeatures
import MailTheme
import MailUI
import SwiftUI

public struct MainWindowRoot: View {
    let environment: AppEnvironment
    let themes: ThemeStore
    let onAttach: ((MainContentViewController) -> Void)?
    @State private var titleBarInset: CGFloat = 0

    public init(environment: AppEnvironment, themes: ThemeStore, onAttach: ((MainContentViewController) -> Void)? = nil) {
        self.environment = environment
        self.themes = themes
        self.onAttach = onAttach
        ThemeActionHandler.install(in: environment.actions, store: themes)
    }

    public var body: some View {
        let router = environment.router
        let resolved = themes.resolved
        MailShellView(router: router) {
            HStack(spacing: 0) {
                MainContentRepresentable(router: router, theme: resolved.tokens,
                                         hidesMail: environment.calendarWindow?.isOpen == true, onMake: onAttach)
                    .overlay { ReviewHostView(environment: environment) }
                    .overlay { ComposerHostView(manager: environment.compose) }
                if let calendar = environment.calendarSidebar, calendar.isVisible {
                    CalendarSidebarView(model: calendar, router: router)
                } else if let contact = environment.actions.superhumanCore?.contextSidebar, contact.isVisible {
                    ContextSidebarView(model: contact, router: router)
                }
            }
            .overlay {
                if let window = environment.calendarWindow, window.isOpen {
                    CalendarWindowView(model: window, router: router)
                        .transaction { $0.disablesAnimations = true }
                }
            }
        }
        .themed(by: themes)
        .environment(\.titleBarInset, titleBarInset)
        .navigationTitle(router.windowTitle)
        .background(WindowHooks(theme: resolved, router: router, titleBarInset: $titleBarInset))
        .task { await environment.status.run() }
        .task { await environment.failedOperationNotices.run() }
    }
}

struct MainContentRepresentable: NSViewControllerRepresentable {
    let router: AppRouter
    let theme: ThemeTokens
    var hidesMail = false
    let onMake: ((MainContentViewController) -> Void)?

    func makeNSViewController(context: Context) -> MainContentViewController {
        let controller = MainContentViewController(router: router, theme: theme)
        controller.showsDateGroups = true
        controller.view.isHidden = hidesMail
        onMake?(controller)
        return controller
    }

    func updateNSViewController(_ controller: MainContentViewController, context: Context) {
        controller.apply(theme: theme)
        guard controller.view.isHidden != hidesMail else { return }
        // Why: AppKit would pass a hidden first responder's place to the next key view (the Calendar's Meet field)
        if hidesMail, let window = controller.view.window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: controller.view) {
            window.makeFirstResponder(nil)
        }
        controller.view.isHidden = hidesMail
    }
}

struct WindowHooks: NSViewRepresentable {
    let theme: ResolvedTheme
    let router: AppRouter
    @Binding var titleBarInset: CGFloat

    func makeNSView(context: Context) -> WindowHookView {
        let view = WindowHookView(theme: theme, router: router)
        view.onTitleBarInset = { value in DispatchQueue.main.async { if titleBarInset != value { titleBarInset = value } } }
        return view
    }

    func updateNSView(_ view: WindowHookView, context: Context) {
        view.theme = theme
        view.onTitleBarInset = { value in DispatchQueue.main.async { if titleBarInset != value { titleBarInset = value } } }
        view.applyToWindow()
    }
}

final class WindowHookView: NSView {
    var theme: ResolvedTheme
    let router: AppRouter
    private var tracker: WindowPlaceTracker?
    var onTitleBarInset: ((CGFloat) -> Void)? { didSet { reportTitleBarInset() } }
    private var chromeObservers: [any NSObjectProtocol] = []
    private var layoutRectObservation: NSKeyValueObservation?

    init(theme: ResolvedTheme, router: AppRouter) {
        self.theme = theme
        self.router = router
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToWindow()
    }

    func applyToWindow() {
        guard let window else { return }
        // Claim the frame name once, when the view reaches a window; re-claiming would steal it from a window whose name was cleared
        let reachedWindow = tracker?.window !== window
        MainWindowHooks.configure(window, theme: theme, restoreFrame: reachedWindow)
        if reachedWindow {
            tracker = WindowPlaceTracker(window: window, router: router)
            observeChrome(of: window)
        }
        reportTitleBarInset()
    }

    private func reportTitleBarInset() {
        guard let window else { return }
        onTitleBarInset?(TitleBarMetrics.stripHeight(of: window))
        WindowZoomMenuState.shared.refresh(from: window)
    }

    private func observeChrome(of window: NSWindow) {
        for observer in chromeObservers { NotificationCenter.default.removeObserver(observer) }
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.willEnterFullScreenNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.willExitFullScreenNotification, NSWindow.didExitFullScreenNotification,
        ]
        chromeObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportTitleBarInset() }
            }
        }
        layoutRectObservation = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.reportTitleBarInset() }
        }
    }

    isolated deinit {
        for observer in chromeObservers { NotificationCenter.default.removeObserver(observer) }
    }
}

@MainActor
public enum MainWindowHooks {
    public static let frameAutosaveName = "dev.openhuman.mail.main"

    public static func configure(_ window: NSWindow, theme: ResolvedTheme, restoreFrame: Bool = true) {
        window.applyThemeAppearance(theme)
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let background = theme.bgWindow.nsColor
        if window.backgroundColor != background { window.backgroundColor = background }
        if restoreFrame, window.frameAutosaveName.isEmpty {
            window.setFrameUsingName(frameAutosaveName)
            window.setFrameAutosaveName(frameAutosaveName)
        }
    }
}
