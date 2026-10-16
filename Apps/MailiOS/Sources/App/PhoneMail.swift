import Foundation
import MailActions
import MailFeatures
import MailModel
import MailRender
import MailTheme
import Observation
import OpenHumanCore

struct RemindTarget: Identifiable, Hashable {
    let thread: ThreadKey
    let source: ActionSource
    var id: ThreadKey { thread }
}

struct HeldSwipe: Equatable {
    let thread: ThreadKey
    let offset: Double
}

@MainActor @Observable
final class PhoneMail {
    enum Route: Hashable { case reader }

    let environment: AppEnvironment
    let formatting = ThreadRowFormatting()
    var showsMailboxes = false
    var showsSettings = false
    var showsSearch = false
    var remindTarget: RemindTarget?
    var heldSwipe: HeldSwipe?
    var linkWarning: SuspiciousLinkPrompt?
    var chromeHeight: CGFloat = 0
    var readerBarHeight: CGFloat = 0
    var isRendering = false
    @ObservationIgnored private var started = false

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var router: AppRouter { environment.router }
    var active: AccountState? { router.active }
    var list: ThreadListModel? { router.list }
    var reader: ReaderModel? { router.mode == .reader ? router.reader : nil }
    var compose: ComposeManager { environment.compose }
    var search: SearchModel { environment.overlays.search }
    var notices: NoticeCenter { environment.notices }

    func start() {
        guard !started else { return }
        started = true
        router.start()
        _ = environment.compose
    }

    var path: [Route] {
        get { reader == nil ? [] : [.reader] }
        set { if newValue.isEmpty, router.mode == .reader { router.closeReader() } }
    }

    var composer: ComposeSession? {
        compose.sessions.last { $0.placement != .window }
    }

    var isSearching: Bool {
        if case .search = active?.location { return true }
        return false
    }

    var tabs: [MailTab] { active?.tabs ?? [] }

    var showsSplitStrip: Bool {
        guard let location = active?.location else { return true }
        return tabs.contains { $0.location == location }
    }

    var locationTitle: String? {
        guard let active, let location = active.location, !showsSplitStrip else { return nil }
        return active.title(for: location)
    }

    func go(to location: MailLocation) {
        if isSearching { search.close() }
        router.go(to: location)
        showsMailboxes = false
    }

    func goToFirstTab() {
        guard let active else { return }
        go(to: active.firstTab)
    }

    func open(_ key: ThreadKey) {
        router.open(key)
    }

    func back() {
        router.closeReader()
    }

    func refresh() async {
        guard let account = active?.id else { return }
        try? await environment.data.refresh(account)
    }

    func context(for key: ThreadKey) -> ActionContext {
        var context = router.contentContext()
        guard !(router.mode == .reader && router.reader?.thread == key) else { return context }
        let row = list?.row(for: key)
        context.scope = .list
        context.account = key.account
        context.focusedThread = key
        context.focusedMessage = nil
        context.selection = [key]
        context.checkedCount = 0
        context.sender = row?.participants.first { !$0.isMe }?.email.lowercased()
        context.targets = TargetState(anyUnread: row?.isUnread ?? false, allStarred: row?.isStarred ?? false,
                                      anySnoozed: row?.snoozedUntil != nil, anyReminder: row?.reminderAt != nil,
                                      anyDraft: (row?.draftCount ?? 0) > 0, anyScheduled: row?.scheduledSendAt != nil)
        return context
    }

    @discardableResult
    func perform(_ id: ActionID, on key: ThreadKey, source: ActionSource) -> Bool {
        environment.actions.perform(id, source: source, host: router, context: context(for: key))
    }

    @discardableResult
    func done(_ key: ThreadKey, source: ActionSource = .swipe) -> Bool {
        perform(.markDone, on: key, source: source)
    }

    func askReminder(_ key: ThreadKey, source: ActionSource = .swipe) {
        remindTarget = RemindTarget(thread: key, source: source)
    }

    @discardableResult
    func remind(_ key: ThreadKey, until date: Date, source: ActionSource) -> Task<Void, Never>? {
        remindTarget = nil
        return environment.actions.threadActions?.snooze([key], until: date, host: router, source: source)
    }

    func newMessage() {
        compose.openNew(placement: .modal)
    }

    func reply(all: Bool) {
        guard let thread = reader?.thread else { return }
        compose.openReply(thread, mode: all ? .replyAll : .reply, message: reader?.replyTarget)
    }

    func forward() {
        guard let thread = reader?.thread else { return }
        compose.openReply(thread, mode: .forward, message: reader?.replyTarget)
    }

    func closeComposer(_ session: ComposeSession) {
        guard session.isOpen else { return }
        compose.close(session)
    }

    func discard(_ session: ComposeSession) {
        compose.perform(.discardDraft, in: session)
    }

    func send(_ session: ComposeSession) {
        _ = session.to.commitText()
        _ = session.cc.commitText()
        compose.perform(.send, in: session)
    }

    func openSearch() {
        search.open()
        showsSearch = true
    }

    func closeSearch() {
        search.close()
        showsSearch = false
    }

    func activate(_ toast: Toast) {
        Task { await notices.activate(toast.id) }
    }

    func follow(_ url: URL, in message: RenderedMessage?) {
        if let suspicious = message?.suspiciousLink(for: url) {
            linkWarning = SuspiciousLinkPrompt(url: url, shown: suspicious.displayedDestination ?? suspicious.displayText,
                                               actual: suspicious.actualHost ?? suspicious.actualDestination)
            return
        }
        followNow(url)
    }

    @ObservationIgnored var openExternal: @MainActor (URL) -> Void = { _ in }

    func followNow(_ url: URL) {
        linkWarning = nil
        let action = ReaderLinkAction.resolve(url)
        if case .openInBrowser(let target) = action {
            openExternal(target)
            return
        }
        if let message = action.follow(with: router) {
            notices.post(message, style: .info, duration: NoticeCenter.infoDuration)
        }
    }

    func useTheme(_ tokens: ThemeTokens, appearance: ThemeAppearance) {
        let renderer = MessageRenderer(theme: tokens, appearance: appearance, emailColors: tokens.readerEmailColors)
        environment.renderQueue.setRenderer(renderer)
        router.reader?.useRenderer(renderer)
    }
}

struct SuspiciousLinkPrompt: Identifiable, Equatable {
    let url: URL
    let shown: String
    let actual: String
    var id: URL { url }
}
