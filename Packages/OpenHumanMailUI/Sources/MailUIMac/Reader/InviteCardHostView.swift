import AppKit
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI

@MainActor
final class InviteCardHostView: NSView {
    let key: MessageKey
    private let center: InviteCenter
    private let hosting: NSHostingView<InviteCardRoot>
    private(set) var showsCard = false
    var onShowsCardChange: ((Bool) -> Void)?
    private var loop: ObservationLoop?

    init(center: InviteCenter, message: MessageKey, theme: ThemeTokens, openLink: @escaping (URL) -> Void) {
        key = message
        self.center = center
        let resolved = InlineComposerView.resolvedTheme(for: theme)
        hosting = NSHostingView(rootView: InviteCardRoot(center: center, message: message, theme: resolved,
                                                         openLink: openLink))
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
        identifier = NSUserInterfaceItemIdentifier("reader.inviteCard")
        observe()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func observe() {
        loop = ObservationLoop.observe { [weak self] in
            guard let self else { return }
            let shows = self.center.showsCard(self.key)
            guard shows != self.showsCard else { return }
            self.showsCard = shows
            self.onShowsCardChange?(shows)
            self.superview?.needsLayout = true
        }
    }
}

struct InviteCardRoot: View {
    let center: InviteCenter
    let message: MessageKey
    let theme: ResolvedTheme
    let openLink: (URL) -> Void

    var body: some View {
        InviteCardView(center: center, message: message, openLink: openLink)
            .environment(\.theme, theme)
            .environment(\.colorScheme, theme.appearance == .dark ? .dark : .light)
            .tint(theme.accentFill.color)
    }
}
