import AppKit
import MailFeatures
import MailModel
import MailUI
import MailUIMac
import SwiftUI

@MainActor
final class SignInPanelController {
    private(set) static var shared: SignInPanelController?

    let model: SignInWaitingModel
    private var panel: NSPanel?
    private var task: Task<Void, Never>?

    init(port: any SignInBrowsing, clipboard: any SignInClipboard) {
        model = SignInWaitingModel(port: port, clipboard: clipboard)
        model.start()
        task = Task { [weak self] in
            for await pending in port.pendingSignIns() {
                guard !Task.isCancelled else { return }
                self?.update(pending)
            }
        }
    }

    static func install(_ broker: any SignInBrowsing) {
        guard shared == nil, !QuietTestHost.isActive else { return }
        shared = SignInPanelController(port: broker, clipboard: PasteboardSignInClipboard())
    }

    private func update(_ pending: PendingSignIn?) {
        guard pending != nil else {
            panel?.orderOut(nil)
            return
        }
        let shown = panel ?? makePanel()
        panel = shown
        shown.center()
        shown.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let made = NSPanel(contentRect: NSRect(x: 0, y: 0, width: SignInWaitingPanel.width, height: 260),
                           styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered,
                           defer: true)
        made.title = "Google sign-in"
        made.titlebarAppearsTransparent = true
        made.isFloatingPanel = true
        made.hidesOnDeactivate = false
        made.becomesKeyOnlyIfNeeded = false
        made.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SignInWaitingPanel(model: model).themed(by: AppThemes.store))
        host.sizingOptions = [.preferredContentSize]
        made.contentView = host
        return made
    }
}
