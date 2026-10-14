import Foundation
import MailModel
import Observation

@MainActor @Observable
public final class SignInWaitingModel {
    public static let copiedText = "Link copied. Paste it into any browser on this Mac."
    public static let thisMacNote = "Use a browser on this Mac: when you finish, Google sends you back to Mail on this Mac, "
        + "so a browser on another device can't finish it."
    public static let openFailedLine = "Mail couldn't open a browser; pick one or copy the link under More options."
    public static let clipboardLifetime: Duration = .seconds(600)

    public private(set) var pending: PendingSignIn?
    public private(set) var browsers: [InstalledBrowser] = []
    public private(set) var remembered: InstalledBrowser.ID?
    public private(set) var showsLink = false
    public private(set) var copiedNote: String?
    public private(set) var errorMessage: String?

    @ObservationIgnored private let port: any SignInBrowsing
    @ObservationIgnored private let clipboard: (any SignInClipboard)?
    @ObservationIgnored private let notices: NoticeCenter?
    @ObservationIgnored private let lifetime: Duration
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var copiedMark: Int?

    public init(port: any SignInBrowsing, clipboard: (any SignInClipboard)?, notices: NoticeCenter? = nil,
                clipboardLifetime: Duration = SignInWaitingModel.clipboardLifetime,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.port = port
        self.clipboard = clipboard
        self.notices = notices
        lifetime = clipboardLifetime
        self.sleep = sleep
    }

    isolated deinit {
        task?.cancel()
        clearTask?.cancel()
    }

    public func start() {
        guard task == nil else { return }
        let port = self.port
        task = Task { [weak self] in
            for await next in port.pendingSignIns() {
                guard !Task.isCancelled, let self else { return }
                await self.changed(to: next)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    func changed(to next: PendingSignIn?) async {
        let previous = pending
        pending = next
        if previous?.id != next?.id {
            showsLink = false
            errorMessage = nil
            if previous != nil { clearCopiedLink() }
        }
        guard let next, previous?.id != next.id else { return }
        browsers = await port.installedBrowsers()
        remembered = await port.rememberedBrowser(for: next.account)
    }

    public var title: String {
        switch pending?.purpose {
        case .calendar?: "Finish connecting the calendar in your browser"
        case .email?, nil: "Finish signing in with Google in your browser"
        }
    }

    public var openedLine: String? {
        guard let pending else { return nil }
        if pending.openFailed { return Self.openFailedLine }
        if let name = pending.openedIn { return "Opened in \(name)." }
        return "Opened in your default browser."
    }

    public var rememberedName: String? { browsers.first { $0.id == remembered }?.name }

    public func openInDefaultBrowser() async { await open(nil) }

    public func open(in browser: InstalledBrowser.ID) async { await open(.some(browser)) }

    private func open(_ browser: InstalledBrowser.ID?) async {
        guard let pending else { return }
        errorMessage = nil
        do {
            try await port.open(pending.id, in: browser)
            remembered = browser
        } catch {
            errorMessage = (error as? SignInBrowserError)?.message ?? "That browser didn't open. Try another, or copy the link."
        }
    }

    public func copyLink() {
        guard let pending, let clipboard else { return }
        clearCopiedLink()
        copiedMark = clipboard.copy(pending.url.absoluteString)
        copiedNote = Self.copiedText
        notices?.post(Self.copiedText, duration: NoticeCenter.infoDuration)
        let lifetime = self.lifetime, sleep = self.sleep
        clearTask = Task { [weak self] in
            do { try await sleep(lifetime) } catch { return }
            self?.clearCopiedLink()
        }
    }

    public func toggleLink() { showsLink.toggle() }

    public func cancel() async {
        guard let pending else { return }
        await port.cancel(pending.id)
    }

    private func clearCopiedLink() {
        clearTask?.cancel()
        clearTask = nil
        if let mark = copiedMark { clipboard?.clear(ifUnchangedSince: mark) }
        copiedMark = nil
        copiedNote = nil
    }
}
