import AppKit
import MailFeatures
import MailTheme
import MailUI
import SwiftUI

@MainActor
final class InlineComposerView: NSView {
    let session: ComposeSession
    private let layoutModel = InlineComposerLayout()
    private let hosting: NSHostingView<InlineComposerRoot>

    init(session: ComposeSession, manager: ComposeManager, theme: ThemeTokens) {
        self.session = session
        let resolved = Self.resolvedTheme(for: theme)
        hosting = NSHostingView(rootView: InlineComposerRoot(session: session, manager: manager, layout: layoutModel,
                                                             theme: resolved))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = [.intrinsicContentSize]
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(false)
        identifier = NSUserInterfaceItemIdentifier("reader.inlineComposer")
        layoutModel.reveal = ComposerReveal { [weak self] frame in self?.reveal(frame) }
    }

    private(set) var revealedPanelFrame: NSRect?

    func reveal(_ cardFrame: CGRect) {
        let frame = hosting.convert(cardFrame, to: self)
        revealedPanelFrame = frame
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.enclosingScrollView?.documentView?.layoutSubtreeIfNeeded()
            _ = self.scrollToVisible(frame.insetBy(dx: 0, dy: -ComposerRevealMetrics.margin))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func resolvedTheme(for tokens: ThemeTokens) -> ResolvedTheme {
        let shared = ComposerWindows.shared.theme
        if shared.tokens == tokens { return shared }
        return ResolvedTheme(themeID: shared.themeID, themeName: shared.themeName, accentID: shared.accentID,
                             appearance: ReaderAppearance.appearance(of: tokens), tokens: tokens)
    }

    var cardFrame: NSRect { bounds }

    var hostMessage: MessageContainerView? {
        var view = superview
        while let current = view, !(current is MessageContainerView) { view = current.superview }
        return view as? MessageContainerView
    }

    override func layout() {
        super.layout()
        updateLayoutModel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayoutModel()
    }

    private func updateLayoutModel() {
        let width = bounds.width
        if width > 0, abs(layoutModel.width - width) > 0.5 { layoutModel.width = width }
        if let visible = enclosingScrollView?.contentView.bounds.height, visible > 0 {
            let cap = max(ComposerMetrics.editorMinDocked, (visible * ComposerMetrics.dockedMaxFraction).rounded())
            if abs(layoutModel.maxEditorHeight - cap) > 0.5 { layoutModel.maxEditorHeight = cap }
        }
    }

    var hasKeyboardFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    func focusIfRequested(attempt: Int = 0, didFocus: @escaping @MainActor () -> Void) {
        guard session.focusRequest != session.focusHandled, window != nil else { return }
        let request = session.focusRequest
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, self.session.focusRequest == request else { return }
            if self.session.mode == .forward, self.session.to.tokens.isEmpty {
                self.session.focusHandled = request
                didFocus()
                return
            }
            guard let editor = self.session.editor else {
                if attempt < 10 { self.focusIfRequested(attempt: attempt + 1, didFocus: didFocus) }
                return
            }
            editor.focusEditor()
            self.session.focusHandled = request
            didFocus()
        }
    }
}

@MainActor @Observable
final class InlineComposerLayout {
    var width: CGFloat = 600
    var maxEditorHeight: CGFloat = 400
    @ObservationIgnored var reveal: ComposerReveal?
}

enum ComposerRevealMetrics {
    static let margin: CGFloat = 12
}

struct InlineComposerRoot: View {
    let session: ComposeSession
    let manager: ComposeManager
    let layout: InlineComposerLayout
    let theme: ResolvedTheme

    var body: some View {
        ComposerCard(session: session, manager: manager, onClose: { manager.close(session) }) {
            ComposerBody(session: session, manager: manager, theme: theme.tokens, focusOnAppear: false,
                         placeholder: ComposerEditor.placeholder(for: session.mode), growsWithContent: true,
                         minHeight: ComposerMetrics.editorMinDocked, maxHeight: layout.maxEditorHeight,
                         onClose: { manager.close(session) })
        }
        .frame(width: layout.width)
        .shortcutTipRoot()
        .environment(\.composerReveal, layout.reveal)
        .environment(\.theme, theme)
        .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
        .tint(theme.accentFill.color)
    }
}
