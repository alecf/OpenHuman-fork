import AppKit
import MailFeatures
import MailTheme
import MailUI
import SwiftUI

public struct ComposerHostView: View {
    let manager: ComposeManager
    @Environment(\.theme) private var theme

    public init(manager: ComposeManager) {
        self.manager = manager
        ComposerWindows.shared.install(on: manager)
    }

    public var body: some View {
        ZStack(alignment: .top) {
            if let session = manager.windowSession, session.placement == .modal {
                modalCard(session)
            } else if let message = manager.shownSending {
                sendingCard(message)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { manager.restoreOpenDrafts() }
        .onAppear { ComposerWindows.shared.theme = theme }
        .onChange(of: theme) { _, new in ComposerWindows.shared.theme = new }
    }

    private func modalCard(_ session: ComposeSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                card(session, editorMinHeight: ComposerHostMetrics.editorMinModal, focusBody: session.mode != .new)
                    .padding(.top, ComposerHostMetrics.modalTop)
                    .padding(.horizontal, theme.space7)
                    .padding(.bottom, theme.space7)
                    .frame(maxWidth: .infinity)
            }
            .environment(\.composerReveal, ComposerReveal { _ in proxy.scrollTo(ComposerReveal.panelID) })
        }
        .background(theme.bgCanvas.color)
        .id(session.id)
    }

    private func sendingCard(_ message: SendingMessage) -> some View {
        ScrollView {
            SendingCard(message: message, manager: manager)
                .padding(.top, ComposerHostMetrics.modalTop)
                .padding(.horizontal, theme.space7)
                .padding(.bottom, theme.space7)
                .frame(maxWidth: .infinity)
        }
        .background(theme.bgCanvas.color)
        .id(message.id)
    }

    private func card(_ session: ComposeSession, editorMinHeight: CGFloat, focusBody: Bool) -> some View {
        ComposerCard(session: session, manager: manager, onClose: { manager.close(session) }) {
            ComposerBody(session: session, manager: manager, theme: theme.tokens, focusOnAppear: focusBody,
                         placeholder: ComposerEditor.placeholder(for: session.mode), onClose: { manager.close(session) })
                .frame(minHeight: editorMinHeight, maxHeight: .infinity)
        }
    }
}

enum ComposerHostMetrics {
    static let modalTop: CGFloat = 48
    static let editorMinModal: CGFloat = 240
    static let windowSize = NSSize(width: 720, height: 640)
}

@MainActor
public final class ComposerWindows: NSObject, NSWindowDelegate {
    public static let shared = ComposerWindows()

    private var windows: [UUID: NSWindow] = [:]
    private var managers: [UUID: ComposeManager] = [:]
    public var theme: ResolvedTheme = .light

    public func install(on manager: ComposeManager) {
        guard manager.openWindow == nil else { return }
        manager.openWindow = { [weak self, weak manager] session in
            guard let self, let manager else { return }
            self.show(session, manager: manager)
        }
        manager.closeWindow = { [weak self] session in self?.close(session) }
        manager.chooseFiles = { session in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            panel.prompt = String(localized: "Attach")
            panel.begin { response in
                guard response == .OK else { return }
                let urls = panel.urls
                MainActor.assumeIsolated { session.attach(urls) }
            }
        }
    }

    func show(_ session: ComposeSession, manager: ComposeManager) {
        if let window = windows[session.id] {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = ComposerWindowRoot(session: session, manager: manager)
            .environment(\.theme, theme)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(ComposerHostMetrics.windowSize)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.title = session.title
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[session.id] = window
        managers[session.id] = manager
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ session: ComposeSession) {
        guard let window = windows.removeValue(forKey: session.id) else { return }
        managers[session.id] = nil
        window.delegate = nil
        window.close()
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
        let manager = managers.removeValue(forKey: id)
        if let session = manager?.sessions.first(where: { $0.id == id }) { manager?.close(session) }
    }
}

struct ComposerWindowRoot: View {
    let session: ComposeSession
    let manager: ComposeManager
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ComposerCard(session: session, manager: manager, onClose: { manager.close(session) }) {
                    ComposerBody(session: session, manager: manager, theme: theme.tokens,
                                 focusOnAppear: session.mode != .new,
                                 placeholder: ComposerEditor.placeholder(for: session.mode),
                                 onClose: { manager.close(session) })
                        .frame(minHeight: ComposerHostMetrics.editorMinModal, maxHeight: .infinity)
                }
                .padding(theme.space6)
            }
            .environment(\.composerReveal, ComposerReveal { _ in proxy.scrollTo(ComposerReveal.panelID) })
        }
        .shortcutTipRoot()
        .background(theme.bgCanvas.color)
    }
}
