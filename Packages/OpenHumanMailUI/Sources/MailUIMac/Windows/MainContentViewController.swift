import AppKit
import MailActions
import MailFeatures
import MailModel
import MailTheme
import MailUI

@MainActor
public final class MainContentViewController: NSViewController {
    public let windowModel: AppRouter
    public var router: AppRouter { windowModel }
    public let keyRouter = KeyRouter.catalog()
    public private(set) var theme: ThemeTokens
    private var listController: ThreadListViewController
    private var readerController: ReaderViewController
    private var observation: ObservationLoop?
    private var keymapObservation: ObservationLoop?
    private var loadedKeymapRevision: Int?
    private var shownMode: AppRouter.Mode?
    private var shownUnified = false
    private weak var boundAccount: AccountState?
    private var pendingScrollTop: ThreadKey?
    private var scrollRetries = 0
    private var scrollObserver: (any NSObjectProtocol)?
    private var wakeObserver: (any NSObjectProtocol)?
    private var seenFieldFocus = 0
    private var seenResultsFocus = 0
    private lazy var printer = ConversationPrinter { [weak self] in self?.view.window }
    private(set) lazy var overlayFocus = OverlayFocusKeeper { [weak self] in self?.view.window }

    public convenience init(environment: AppEnvironment) {
        self.init(router: environment.router, theme: environment.theme)
    }

    public init(router: AppRouter, theme: ThemeTokens? = nil) {
        self.windowModel = router
        let theme = theme ?? router.environment.theme
        self.theme = theme
        listController = ThreadListViewController(theme: theme)
        readerController = ReaderViewController(theme: theme)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    public var tableView: ThreadTableView { listController.tableView }

    public var showsDateGroups: Bool {
        get { listController.showsDateGroups }
        set { listController.showsDateGroups = newValue }
    }

    var reader: ReaderViewController { readerController }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.bgWindow.nsColor.cgColor
        view = root
        install(listController, readerController)
        listController.threadDragWriter = { [weak self] in self?.router.environment.threadDrag }
        listController.dragFailed = { [weak self] in
            self?.router.environment.notices.post("Couldn't copy the conversation", style: .info, duration: NoticeCenter.infoDuration)
        }

        keyRouter.load(KeyTable.build(router.environment.actions.descriptors))
        loadedKeymapRevision = router.environment.actions.keymapRevision
        keymapObservation = ObservationLoop.observe { [weak self] in
            guard let self else { return }
            let actions = self.router.environment.actions
            let revision = actions.keymapRevision
            guard revision != self.loadedKeymapRevision else { return }
            self.loadedKeymapRevision = revision
            self.keyRouter.load(KeyTable.build(actions.descriptors))
        }
        keyRouter.activeScopes = { [weak self] in
            if self?.router.environment.overlays.isShowing == true { return [.global] }
            if self?.router.environment.calendarWindowIfStarted?.isOpen == true { return [.calendar, .global] }
            if self?.router.unifiedInbox != nil { return [.global] }
            if self?.router.mode == .list, case .reviewQueue? = self?.router.active?.location {
                return [.review, .global]
            }
            return self?.router.mode == .reader ? [.reader, .global] : [.list, .global]
        }
        keyRouter.perform = { [weak self] action, _ in self?.router.perform(action) ?? false }
        keyRouter.editingKeyHandler = { [weak self] event in self?.editSearchQuery(with: event) ?? false }
        keyRouter.isMailWindow = { [weak self] window in window === self?.view.window }
        keyRouter.onPendingSequence = { [weak self] prefix in
            self?.router.sequenceHint = prefix.map { Self.hint(for: $0) }
        }

        Task { await ReaderWebKit.shared.prepare() }
        router.environment.actions.superhumanCore?.printer = printer
        router.environment.overlays.focusKeeper = overlayFocus
        router.willPersist = { [weak self] in self?.captureScroll(into: self?.boundAccount) }
        router.start()
        observation = ObservationLoop.observe { [weak self] in self?.render() }
        router.environment.ai?.preparation.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.router.environment.ai?.preparation.systemDidWake() }
        }
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        keyRouter.install()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        keyRouter.uninstall()
        captureScroll(into: boundAccount)
        router.persist()
    }

    isolated deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }

    public func apply(theme newTheme: ThemeTokens) {
        guard newTheme != theme else { return }
        theme = newTheme
        listController.apply(theme: newTheme)
        guard isViewLoaded else {
            readerController = ReaderViewController(theme: newTheme)
            return
        }
        let oldReader = readerController
        oldReader.view.removeFromSuperview()
        oldReader.removeFromParent()
        oldReader.model = nil
        readerController = ReaderViewController(theme: newTheme)
        view.layer?.backgroundColor = newTheme.bgWindow.nsColor.cgColor
        installReader(readerController)
        shownMode = nil
        render()
    }

    private func installReader(_ reader: ReaderViewController) {
        addChild(reader)
        reader.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(reader.view)
        NSLayoutConstraint.activate([
            reader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            reader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            reader.view.topAnchor.constraint(equalTo: view.topAnchor),
            reader.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        reader.view.isHidden = true
    }

    private func install(_ list: ThreadListViewController, _ reader: ReaderViewController) {
        addChild(list)
        addChild(reader)
        for content in [list.view, reader.view] {
            content.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(content)
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.topAnchor.constraint(equalTo: view.topAnchor),
                content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
        reader.view.isHidden = true
        list.onOpen = { [weak self] key in self?.router.openRow(key) }
        observeScroll(of: list)
    }

    private func observeScroll(of list: ThreadListViewController) {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard let clip = list.tableView.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pendingScrollTop == nil else { return }
                self.captureScroll(into: self.boundAccount)
            }
        }
    }

    private func render() {
        let active = router.active
        let mode = router.mode
        let list = active?.list
        let reader = active?.reader
        _ = list?.revision
        if active !== boundAccount {
            captureScroll(into: boundAccount)
            boundAccount = active
            pendingScrollTop = active?.selection.scrollTop
            scrollRetries = 0
            shownMode = nil
        }
        if listController.model !== list { listController.model = list }
        if router.accountsError != nil {
            listController.placeholder = "Couldn't open the mail store."
        } else {
            listController.placeholder = router.accountsLoaded && active == nil ? "No account yet." : nil
        }
        readerController.meAddress = active?.account.email ?? ""
        readerController.meAddresses = active?.account.myAddresses ?? []
        if readerController.model !== reader { readerController.model = reader }
        applyPendingScroll()

        if !router.environment.overlays.isShowing { overlayFocus.overlayChanged(showing: false) }

        let search = router.environment.overlays.search
        let fieldTakesFocus = search.focusRequest != seenFieldFocus
        seenFieldFocus = search.focusRequest
        if search.resultsFocusRequest != seenResultsFocus {
            seenResultsFocus = search.resultsFocusRequest
            if mode == .list { view.window?.makeFirstResponder(listController.tableView) }
        }

        let unified = router.unifiedInbox != nil
        if unified != shownUnified {
            shownUnified = unified
            shownMode = nil
        }
        if unified {
            listController.view.isHidden = true
            readerController.view.isHidden = true
            return
        }
        guard shownMode != mode else { return }
        shownMode = mode
        listController.view.isHidden = mode == .reader
        readerController.view.isHidden = mode == .list
        guard !(mode == .list && fieldTakesFocus) else { return }
        view.window?.makeFirstResponder(mode == .reader ? readerController.focusView : listController.tableView)
    }

    var topVisibleKey: ThreadKey? {
        guard let list = listController.model, !list.rows.isEmpty,
              let clip = listController.tableView.enclosingScrollView?.contentView else { return nil }
        let height = max(listController.tableView.rowHeight, 1)
        let index = list.rowIndex(atOrAfterDisplay: max(0, Int((clip.bounds.origin.y / height).rounded(.down))))
        return list.rows.indices.contains(index) ? list.rows[index].id : nil
    }

    private func captureScroll(into state: AccountState?) {
        guard let state, listController.model === state.list, pendingScrollTop == nil,
              let key = topVisibleKey, let index = listController.model?.displayIndex(of: key),
              let clip = listController.tableView.enclosingScrollView?.contentView else { return }
        let offset = Double(clip.bounds.origin.y - CGFloat(index) * listController.tableView.rowHeight)
        if state.selection.scrollTop != key { state.selection.scrollTop = key }
        if state.selection.scrollOffset != offset { state.selection.scrollOffset = offset }
    }

    private func applyPendingScroll() {
        guard let key = pendingScrollTop, let list = listController.model else { return }
        guard let index = list.displayIndex(of: key) else {
            if list.state != .loading { pendingScrollTop = nil }
            return
        }
        let table = listController.tableView
        guard table.numberOfRows > index, let scroll = table.enclosingScrollView else {
            if scrollRetries < 5 {
                scrollRetries += 1
                Task { @MainActor [weak self] in self?.applyPendingScroll() }
            }
            return
        }
        pendingScrollTop = nil
        let maxY = max(0, table.bounds.height - scroll.contentView.bounds.height)
        let y = min(max(0, CGFloat(index) * table.rowHeight + CGFloat(boundAccount?.selection.scrollOffset ?? 0)), maxY)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func editSearchQuery(with event: NSEvent) -> Bool {
        let search = router.environment.overlays.search
        guard router.mode == .list, search.isOpen, search.shownQuery != nil, !router.environment.overlays.isShowing,
              let window = view.window, let field = searchField(in: window), window.makeFirstResponder(field),
              let editor = field.currentEditor() as? NSTextView else { return false }
        if editor.string.isEmpty, event.keyCode == 51, let reopened = SearchQueryTokens.reopeningLast(search.text) {
            search.text = reopened
            return true
        }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.keyDown(with: event)
        return true
    }

    func searchField(in window: NSWindow) -> NSTextField? {
        guard let root = window.contentView else { return nil }
        let band = CGFloat(theme.component.toolbar.height)
        return OverlayFocusKeeper.editableFields(in: window).first { field in
            guard !field.isHiddenOrHasHiddenAncestor, !field.isDescendant(of: view) else { return false }
            let frame = root.convert(field.bounds, from: field)
            let top = root.isFlipped ? frame.minY : root.bounds.height - frame.maxY
            return top >= 0 && top < band
        }
    }

    static func hint(for chord: KeyChord) -> String {
        switch chord.key {
        case .character(let c): c.uppercased() + "…"
        case .named: "…"
        }
    }
}
