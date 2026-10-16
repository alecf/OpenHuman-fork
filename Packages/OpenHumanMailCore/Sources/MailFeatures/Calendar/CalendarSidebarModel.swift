import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class CalendarSidebarModel {
    public struct Day: Identifiable, Hashable, Sendable {
        public let start: Date
        public var id: Date { start }
        public let isMentioned: Bool
        public var events: [CalendarEvent] = []
        public var busy: [CalendarBusyInterval] = []
        public var free: [CalendarBusyInterval] = []
        public var note: String?
    }

    public enum LoadState: Equatable, Sendable { case idle, loading, loaded, failed(String) }

    public static let workdayHours = 9..<18
    public static let minimumFree: TimeInterval = 15 * 60

    public let provider: any CalendarProviding
    public private(set) var shownProvider: (any CalendarProviding)?
    public private(set) var calendarNote: String?
    public private(set) var connectionStates: [AccountID: CalendarConnectionState] = [:]
    public private(set) var connectAccount: Account?
    public private(set) var connectIsReconnect = false
    public private(set) var isConnecting = false
    public private(set) var connectError: String?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var followers: [AccountID: Task<Void, Never>] = [:]
    @ObservationIgnored private var shownOwner: AccountID?
    public let showAllSetting: StoredSetting<Bool>
    public private(set) var isVisible = false
    public private(set) var thread: ThreadKey?
    public private(set) var days: [Day] = []
    public private(set) var state: LoadState = .idle
    public private(set) var mentionCount = 0
    public var draft: CalendarEventDraft? {
        didSet {
            if oldValue == nil, draft != nil { openedEvent = nil }
            if draft != oldValue { draftNote = nil }
            if !switchingDraft, draft != oldValue { mirrorDraft() }
        }
    }
    @ObservationIgnored private var switchingDraft = false
    @ObservationIgnored var draftKeyOverride: PendingEventKey?
    public private(set) var draftNote: String?
    public private(set) var isCreating = false
    public let secondTimeZoneSetting: StoredSetting<String?>
    public let ignoreConflictsSetting: StoredSetting<Bool>
    public private(set) var isBrowsing = false
    public private(set) var followsDraft = false
    public private(set) var suggestion: CalendarAvailability?
    public private(set) var suggestionNote: String?
    public private(set) var isSuggesting = false
    public private(set) var progress: CalendarLoadProgress?
    public private(set) var refreshNote: String?
    public private(set) var mentionFocus: DateInterval?
    public private(set) var openedEvent: CalendarEvent?
    public private(set) var focusedEventKey: String?
    @ObservationIgnored public var timeZone: TimeZone
    @ObservationIgnored public var now: @MainActor () -> Date
    @ObservationIgnored public var createWindow: Duration = NoticeCenter.toastDuration
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    @ObservationIgnored var loadText: (ThreadKey) async -> CalendarThreadText?

    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var text: CalendarThreadText?
    @ObservationIgnored private var mentions: [CalendarDateMention] = []
    @ObservationIgnored private var textThread: ThreadKey?
    @ObservationIgnored private var shownStarts: [(Date, Bool)] = []
    @ObservationIgnored private var draftThread: ThreadKey?
    public private(set) var draftAccountRefusal: String?
    @ObservationIgnored private var draftProvider: (any CalendarProviding)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var sources: [(owner: String, key: CalendarCacheKey, provider: any CalendarProviding)] = []
    @ObservationIgnored private var mergedSources = false
    @ObservationIgnored private var storeObserver: UUID?
    @ObservationIgnored private var heldCreates: [UUID: (task: Task<Void, Never>, draft: CalendarEventDraft, thread: ThreadKey?,
                                                         calendar: any CalendarProviding)] = [:]
    @ObservationIgnored private var createdEvents: [UUID: (event: CalendarEvent, calendar: any CalendarProviding)] = [:]
    @ObservationIgnored private var undoerStorage: CalendarEventUndoer?
    @ObservationIgnored private var heldPlaceholders: [UUID: (key: CalendarCacheKey, id: String)] = [:]

    public init(environment: AppEnvironment, provider: any CalendarProviding, timeZone: TimeZone = .current,
                now: @escaping @MainActor () -> Date = Date.init) {
        self.environment = environment
        self.provider = provider
        self.timeZone = timeZone
        self.now = now
        secondTimeZoneSetting = StoredSetting(AppSettings.calendarSecondTimeZone, port: environment.settings)
        ignoreConflictsSetting = StoredSetting(AppSettings.calendarAvailabilityIgnoresConflicts, port: environment.settings)
        showAllSetting = StoredSetting(AppSettings.calendarShowAll, port: environment.settings)
        shownProvider = provider
        let loader = CalendarThreadLoader(data: environment.data)
        loadText = { await loader.load($0) }
        eventStore = environment.calendarEvents
        storeObserver = eventStore.observe { [weak self] change in self?.cacheChanged(change) }
    }

    isolated deinit {
        followTask?.cancel()
        for follower in followers.values { follower.cancel() }
    }

    public let eventStore: CalendarEventStore

    public var providerName: String { (draftProvider ?? shownProvider ?? provider).info.name }
    public var isSample: Bool { (shownProvider ?? provider).info.isSample }

    public var calendarLine: String {
        guard let account = (draftProvider ?? shownProvider ?? provider).info.account, !account.isEmpty else {
            return providerName
        }
        return "\(providerName) · \(account)"
    }

    public var routesByAccount: Bool { environment.calendarConnections?.routesByAccount == true }

    public var showsAllCalendars: Bool { routesByAccount && showAllSetting.value }

    public func setShowAll(_ on: Bool) async {
        await showAllSetting.set(on)
        await selectCalendar(for: thread)
        await refresh()
    }

    public static func notConnected(_ email: String) -> String {
        String(localized: "The calendar of \(email) isn't connected. Connect it in Settings › Calendar.")
    }

    public static func needsSignInAgain(_ email: String) -> String {
        String(localized: "Calendar needs sign-in again: Google no longer accepts Mail's access to the calendar of \(email).")
    }

    public static func loadFailed(_ reason: String) -> String {
        String(localized: "Couldn't load events: \(reason)")
    }

    public var connectTitle: String? {
        guard let account = connectAccount else { return nil }
        return connectIsReconnect ? String(localized: "Reconnect calendar for \(account.email)")
                                  : String(localized: "Connect calendar for \(account.email)")
    }

    func calendarOf(_ account: AccountID?, fallback: AccountID? = nil)
        async -> (provider: (any CalendarProviding)?, owner: Account?) {
        guard routesByAccount, let connections = environment.calendarConnections else { return (provider, nil) }
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        if let id = account ?? fallback {
            guard let owner = accounts.first(where: { $0.id == id }) else { return (nil, nil) }
            return (connections.calendarProvider(for: owner), owner)
        }
        for owner in accounts {
            if let found = connections.calendarProvider(for: owner) { return (found, owner) }
        }
        return (nil, accounts.first)
    }

    private func allCalendars() async -> [(key: String, provider: any CalendarProviding)] {
        guard let connections = environment.calendarConnections else { return [] }
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        return accounts.compactMap { owner in
            connections.calendarProvider(for: owner).map { (owner.email.lowercased(), $0) }
        }
    }

    private func shownCalendars() async -> [(key: String, provider: any CalendarProviding)] {
        if showsAllCalendars { return await allCalendars() }
        guard let shown = shownProvider else { return [] }
        return [((shown.info.account ?? "").lowercased(), shown)]
    }

    @ObservationIgnored public var activeAccount: @MainActor () -> AccountID? = { nil }

    private func selectCalendar(for thread: ThreadKey?) async {
        let found = await calendarOf(thread?.account, fallback: thread == nil ? activeAccount() : nil)
        shownProvider = found.provider
        shownOwner = found.owner?.id
        guard found.provider == nil, !showsAllCalendars else {
            calendarNote = nil
            connectAccount = nil
            connectIsReconnect = false
            connectError = nil
            return
        }
        let email = found.owner?.email ?? String(localized: "this account")
        let state = await connectionState(of: found.owner)
        connectIsReconnect = state?.status == .needsReconnect
        calendarNote = connectIsReconnect ? Self.needsSignInAgain(email) : Self.notConnected(email)
        if let owner = found.owner, environment.calendarConnections?.calendarConnection(for: owner) != nil {
            connectAccount = owner
        } else {
            connectAccount = nil
        }
    }

    private func connectionState(of owner: Account?) async -> CalendarConnectionState? {
        guard let owner else { return nil }
        if let known = connectionStates[owner.id] { return known }
        guard let port = environment.calendarConnections?.calendarConnection(for: owner) else { return nil }
        for await first in port.connectionStates() { return first }
        return nil
    }

    func followConnections() {
        guard followTask == nil, routesByAccount, let connections = environment.calendarConnections else { return }
        let data = environment.data
        followTask = Task { [weak self] in
            do {
                for try await list in data.accounts() {
                    guard !Task.isCancelled, let self else { return }
                    self.follow(list, connections: connections)
                }
            } catch {
                return
            }
        }
    }

    private func follow(_ accounts: [Account], connections: any CalendarConnectionsProviding) {
        let shown = accounts.filter { $0.health != .removing && $0.health != .disabled }
        for account in shown where followers[account.id] == nil {
            guard let port = connections.calendarConnection(for: account) else { continue }
            let id = account.id
            followers[id] = Task { [weak self] in
                for await state in port.connectionStates() {
                    guard !Task.isCancelled, let self else { return }
                    await self.connectionChanged(id, to: state)
                }
            }
        }
        for id in Array(followers.keys) where !shown.contains(where: { $0.id == id }) {
            followers.removeValue(forKey: id)?.cancel()
            connectionStates[id] = nil
        }
    }

    private func connectionChanged(_ id: AccountID, to state: CalendarConnectionState) async {
        let before = connectionStates[id]
        connectionStates[id] = state
        let changed: Bool
        if let before {
            changed = before.status != state.status || before.canCreateEvents != state.canCreateEvents
        } else {
            changed = id == shownOwner && (state.status == .connected) != (shownProvider != nil) && !showsAllCalendars
        }
        guard changed else { return }
        Log(.calendar).notice("account \(id.rawValue): calendar now \(Self.statusCode(state.status)); the sidebar follows")
        guard isVisible || draft != nil else { return }
        await reselect()
    }

    static func statusCode(_ status: CalendarConnectionState.Status) -> String {
        switch status {
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .needsReconnect: "needsReconnect"
        }
    }

    private func reselect() async {
        await selectCalendar(for: thread)
        if draft != nil {
            let target = await draftTarget(for: draftThread)
            draftProvider = target.calendar
            draftAccountRefusal = target.refusal
        }
        await refresh()
    }

    public func connectShownCalendar() async {
        guard let owner = connectAccount, !isConnecting,
              let port = environment.calendarConnections?.calendarConnection(for: owner) else { return }
        isConnecting = true
        connectError = nil
        defer { isConnecting = false }
        do {
            try await port.connect(client: nil)
        } catch is CancellationError {
            connectError = InboxCalendar.cancelled
            return
        } catch {
            connectError = (error as? CalendarError)?.description ?? InboxCalendar.genericError
            return
        }
        try? await environment.settings?.set(AppSettings.calendarSetupSkipped(owner.id), false)
        for await now in port.connectionStates() {
            connectionStates[owner.id] = now
            break
        }
        await reselect()
    }

    public var secondTimeZone: TimeZone? {
        guard let id = secondTimeZoneSetting.value, let zone = TimeZone(identifier: id),
              zone.identifier != timeZone.identifier else { return nil }
        return zone
    }

    public func setVisible(_ visible: Bool) {
        let opened = visible && !isVisible
        isVisible = visible
        if !visible { forgetEvent() }
        if visible {
            followConnections()
            secondTimeZoneSetting.start()
            ignoreConflictsSetting.start()
            showAllSetting.start()
        }
        if opened, !sources.isEmpty { Task { [weak self] in await self?.revalidateShown(force: false) } }
    }

    public func appBecameActive() async {
        guard isVisible else { return }
        await revalidateShown(force: false)
    }

    public func tick() async {
        guard isVisible else { return }
        await revalidateShown(force: false)
    }

    public var refreshInterval: Duration { .seconds(Int(eventStore.refreshInterval)) }

    public func toggle() { setVisible(!isVisible) }

    public func show(thread: ThreadKey?) async {
        followConnections()
        if thread != self.thread { forgetEvent() }
        generation += 1
        let mine = generation
        if draft != nil, thread != draftThread { stashDraft() }
        self.thread = thread
        var loaded: CalendarThreadText?
        if let thread { loaded = await loadText(thread) }
        guard mine == generation, !Task.isCancelled else { return }
        let zone = timeZone
        let found = await Self.scan(loaded, timeZone: zone, now: now())
        guard mine == generation, !Task.isCancelled else { return }
        text = loaded
        mentions = found
        textThread = thread
        mentionCount = found.count
        mentionFocus = Self.focus(in: found, now: now())
        if draft == nil, let thread, let pending = environment.pendingEvents.pending(for: .thread(thread)) {
            let target = await draftTarget(for: thread)
            guard mine == generation, !Task.isCancelled else { return }
            if draft == nil { restore(pending, calendar: target.calendar, refusal: target.refusal) }
        }
        isBrowsing = false
        followsDraft = false
        let starts = Self.days(for: found, timeZone: zone, now: now())
        shownStarts = starts
        await selectCalendar(for: thread)
        guard mine == generation, !Task.isCancelled else { return }
        await load(days: starts, generation: mine, force: false)
    }

    public func refresh() async {
        generation += 1
        let mine = generation
        let starts = shownStarts.isEmpty ? Self.days(for: mentions, timeZone: timeZone, now: now()) : shownStarts
        Log(.calendar).info("sidebar refresh (\(starts.count) days)")
        await load(days: starts, generation: mine, force: true)
    }

    public func moveDay(by delta: Int) async {
        guard let target = day(movedBy: delta) else { return }
        await showDay(target)
    }

    @discardableResult
    public func moveDayInstantly(by delta: Int) -> Task<Void, Never>? {
        guard let target = day(movedBy: delta) else { return nil }
        return revalidateInBackground(generation: beginShowing(day: target))
    }

    public func goToToday() async {
        await showDay(CalendarDateMentions.calendar(timeZone).startOfDay(for: now()))
    }

    @discardableResult
    public func goToTodayInstantly() -> Task<Void, Never> {
        revalidateInBackground(generation: beginShowing(day: CalendarDateMentions.calendar(timeZone).startOfDay(for: now())))
    }

    private func revalidateInBackground(generation mine: Int) -> Task<Void, Never> {
        guard !sources.isEmpty else {
            let starts = shownStarts
            return Task { [weak self] in await self?.load(days: starts, generation: mine, force: false) }
        }
        return Task { [weak self] in
            await self?.revalidateShown(force: false, generation: mine)
            guard let self, mine == self.generation, !Task.isCancelled else { return }
            self.state = self.paint() ? .loaded : self.failureState() ?? .loaded
        }
    }

    private func day(movedBy delta: Int) -> Date? {
        let calendar = CalendarDateMentions.calendar(timeZone)
        let anchor = days.first?.start ?? calendar.startOfDay(for: now())
        return calendar.date(byAdding: .day, value: delta, to: anchor).map { calendar.startOfDay(for: $0) }
    }

    private func showDay(_ start: Date) async {
        let mine = beginShowing(day: start)
        await load(days: shownStarts, generation: mine, force: false)
    }

    private func beginShowing(day start: Date) -> Int {
        generation += 1
        forgetEvent()
        isBrowsing = true
        followsDraft = false
        let mentioned = Set(CalendarDateMentions.days(mentions, timeZone: timeZone, today: now(), limit: .max))
        shownStarts = [(start, mentioned.contains(start))]
        if !sources.isEmpty, paint() { state = .loaded }
        return generation
    }

    public func follow(typed text: String) async {
        let zone = timeZone
        let found = await Self.scan([text], timeZone: zone)
        guard !found.isEmpty else { return }
        let starts = CalendarDateMentions.days(found, timeZone: zone, today: now()).map { ($0, true) }
        if let typed = Self.focus(in: found, now: now()) { mentionFocus = typed }
        if followsDraft, starts.map(\.0) == days.map(\.start) { return }
        generation += 1
        let mine = generation
        followsDraft = true
        isBrowsing = false
        shownStarts = starts
        await load(days: starts, generation: mine, force: false)
    }

    public static let noFreeTimes = String(localized: "No free 30-minute times in the next five working days (9 AM to 6 PM).")

    @discardableResult
    public func suggestTimes() async -> CalendarAvailability? {
        await suggestTimes(account: thread?.account)
    }

    @discardableResult
    public func suggestTimes(account: AccountID?) async -> CalendarAvailability? {
        let found = await calendarOf(account, fallback: account == nil ? activeAccount() : nil)
        guard let chosen = found.provider else {
            suggestion = nil
            suggestionNote = Self.notConnected(found.owner?.email ?? String(localized: "this account"))
            return nil
        }
        return await suggestTimes(using: chosen)
    }

    private func suggestTimes(using calendarProvider: any CalendarProviding) async -> CalendarAvailability? {
        isSuggesting = true
        defer { isSuggesting = false }
        suggestionNote = nil
        let zone = timeZone
        let calendar = CalendarDateMentions.calendar(zone)
        let current = now()
        let workdays = CalendarAvailability.days(from: current, calendar: calendar)
        guard let first = workdays.first, let last = workdays.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else {
            suggestion = nil
            suggestionNote = Self.noFreeTimes
            return nil
        }
        let ignore = await ignoresConflicts()
        var busy: [CalendarBusyInterval] = []
        if !ignore {
            do {
                let answer = try await calendarProvider.freeBusy(from: first, to: end)
                busy = answer.busy
                if !answer.errors.isEmpty { suggestionNote = String(localized: "Some calendars couldn't be read.") }
            } catch {
                suggestion = nil
                suggestionNote = String(localized: "Couldn't read your calendar. \(Self.message(error))")
                return nil
            }
        }
        let slots = CalendarAvailability.slots(days: workdays, busy: busy, now: current, calendar: calendar,
                                               ignoreConflicts: ignore)
        guard !slots.isEmpty else {
            suggestion = nil
            suggestionNote = Self.noFreeTimes
            return nil
        }
        let made = CalendarAvailability(slots: slots, asOf: current, ignoresConflicts: ignore)
        suggestion = made
        return made
    }

    public func suggestionText(_ availability: CalendarAvailability) -> String? {
        availability.text(timeZone: timeZone, secondTimeZone: secondTimeZone)
    }

    @discardableResult
    public func insertAvailability(into session: ComposeSession) async -> Bool {
        guard let found = await suggestTimes(account: session.account.id), let text = suggestionText(found) else {
            session.notice = ComposeSession.Notice(.info, suggestionNote ?? Self.noFreeTimes)
            return false
        }
        guard let editor = session.editor, editor.replaceText(in: editor.editorSelection, with: text + "\n") else {
            session.notice = ComposeSession.Notice(.info, String(localized: "Couldn't put the free times in the draft. Click in the message and try again."))
            return false
        }
        return true
    }

    private func ignoresConflicts() async -> Bool {
        guard let settings = environment.settings,
              let stored = try? await settings.get(AppSettings.calendarAvailabilityIgnoresConflicts) else {
            return ignoreConflictsSetting.value
        }
        return stored
    }

    public func beginDraft(for thread: ThreadKey?) async {
        setVisible(true)
        let target = thread ?? self.thread
        let started = generation
        if let target, draft != nil, draftKey == .thread(target) { return }
        if let target, let pending = environment.pendingEvents.pending(for: .thread(target)) {
            let chosen = await draftTarget(for: target)
            if generation != started, target != self.thread { return }
            if draft != nil { stashDraft() }
            restore(pending, calendar: chosen.calendar, refusal: chosen.refusal)
            return
        }
        var source: CalendarThreadText?
        var found: [CalendarDateMention] = []
        if let target {
            if target == textThread, let text {
                source = text
                found = mentions
            } else {
                source = await loadText(target)
                found = await Self.scan(source, timeZone: timeZone, now: now())
            }
        }
        var mine = await myAddresses(target)
        let chosen = await calendarOf(target?.account, fallback: target == nil ? activeAccount() : nil)
        if let calendarAccount = chosen.provider?.info.account { mine.insert(calendarAccount.lowercased()) }
        let accountRefusal = await accountRefusal(for: target, calendar: chosen)
        let addMeet = await meetDefault()
        if generation != started, target != self.thread { return }
        draftThread = target
        draftProvider = chosen.provider
        var made = CalendarEventDraftBuilder.draft(from: source, mentions: found, myAddresses: mine, timeZone: timeZone,
                                                   now: now())
        if let target, let summary = environment.ai?.finishedSummary(target),
           let title = CalendarEventDraftBuilder.title(fromSummary: summary) {
            made.title = title
        }
        made.addMeetLink = addMeet
        draftAccountRefusal = accountRefusal
        if draft != nil, draftKey != target.map({ .thread($0) }) { stashDraft() }
        draftKeyOverride = nil
        draft = made
        draftNote = nil
        if let key = draftKey { environment.pendingEvents.save(made, for: key, thread: target, titleIsSuggested: true) }
    }

    public func cancelDraft() {
        let key = draftKey
        switchingDraft = true
        draft = nil
        switchingDraft = false
        draftNote = nil
        draftKeyOverride = nil
        if let key { environment.pendingEvents.cancel(key) }
    }

    public func beginDraft(for thread: ThreadKey?, at mention: CalendarDateMention, key: PendingEventKey? = nil) async {
        let target = thread ?? (key == nil ? self.thread : nil)
        let wanted = key ?? target.map { .thread($0) }
        var fresh = false
        if let wanted, wanted != draftKey, let pending = environment.pendingEvents.pending(for: wanted) {
            let chosen = await draftTarget(for: target)
            if draft != nil { stashDraft() }
            restore(pending, calendar: chosen.calendar, refusal: chosen.refusal)
        } else if draft == nil || wanted != draftKey {
            fresh = true
            if key == nil {
                await beginDraft(for: target)
            } else {
                await beginComposerDraft(key: key, thread: target)
            }
        }
        guard let made = draft else { return }
        if fresh, let title = await peopleTitle(for: made, thread: target) {
            draft?.title = title
            if let key = draftKey, let current = draft {
                environment.pendingEvents.save(current, for: key, thread: draftThread, titleIsSuggested: true)
            }
        }
        let (start, length) = Self.time(of: mention, timeZone: timeZone)
        draft?.start = start
        draft?.end = start.addingTimeInterval(length)
        await show(day: start)
    }

    private func peopleTitle(for draft: CalendarEventDraft, thread: ThreadKey?) async -> String? {
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        let me = accounts.first { $0.id == thread?.account } ?? accounts.first
        return CalendarEventDraftBuilder.peopleTitle(me: me, others: draft.attendees)
    }

    private func beginComposerDraft(key: PendingEventKey?, thread: ThreadKey?) async {
        setVisible(true)
        if let thread {
            let existed = environment.pendingEvents.pending(for: .thread(thread)) != nil
            await beginDraft(for: thread)
            guard let made = draft else { return }
            stashDraft()
            if !existed { environment.pendingEvents.remove(.thread(thread)) }
            draftKeyOverride = key
            draftThread = thread
            switchingDraft = true
            draft = made
            switchingDraft = false
            if let key { environment.pendingEvents.save(made, for: key, thread: thread, titleIsSuggested: true) }
            return
        }
        let addMeet = await meetDefault()
        let chosen = await draftTarget(for: nil)
        if draft != nil { stashDraft() }
        draftKeyOverride = key
        draftThread = nil
        draftProvider = chosen.calendar
        draftAccountRefusal = chosen.refusal
        let start = CalendarEventDraftBuilder.time(mentions: [], calendar: CalendarDateMentions.calendar(timeZone),
                                                   now: now()).0
        draft = CalendarEventDraft(title: String(localized: "Meeting"), start: start,
                                   end: start.addingTimeInterval(CalendarEventDraftBuilder.defaultDuration),
                                   timeZone: timeZone.identifier, addMeetLink: addMeet)
        if let key, let made = draft {
            environment.pendingEvents.save(made, for: key, thread: nil, titleIsSuggested: true)
        }
    }

    static func time(of mention: CalendarDateMention, timeZone: TimeZone) -> (Date, TimeInterval) {
        let length = mention.duration ?? CalendarEventDraftBuilder.defaultDuration
        guard !mention.hasTime else { return (mention.date, length) }
        let calendar = CalendarDateMentions.calendar(timeZone)
        let day = calendar.startOfDay(for: mention.date)
        let start = calendar.date(bySettingHour: CalendarEventDraftBuilder.defaultHour, minute: 0, second: 0, of: day) ?? day
        return (start, CalendarEventDraftBuilder.defaultDuration)
    }

    public var titleIsSuggested: Bool {
        guard let key = draftKey else { return false }
        return environment.pendingEvents.pending(for: key)?.titleIsSuggested ?? false
    }

    public func recordFeedback(_ feedback: PendingEventStore.Feedback) {
        environment.pendingEvents.record(feedback)
    }

    var draftKey: PendingEventKey? { draftKeyOverride ?? draftThread.map { .thread($0) } }

    private func mirrorDraft() {
        guard let key = draftKey else { return }
        if let draft {
            environment.pendingEvents.save(draft, for: key, thread: draftThread)
        } else {
            environment.pendingEvents.remove(key)
        }
    }

    private func stashDraft() {
        if let key = draftKey { environment.pendingEvents.deactivate(key) }
        switchingDraft = true
        draft = nil
        switchingDraft = false
        draftKeyOverride = nil
    }

    private func draftTarget(for thread: ThreadKey?) async -> (calendar: (any CalendarProviding)?, refusal: String?) {
        let chosen = await calendarOf(thread?.account, fallback: thread == nil ? activeAccount() : nil)
        return (chosen.provider, await accountRefusal(for: thread, calendar: chosen))
    }

    private func restore(_ pending: PendingEvent, calendar: (any CalendarProviding)?, refusal: String?) {
        switch pending.key {
        case .thread: draftKeyOverride = nil
        case .draft: draftKeyOverride = pending.key
        }
        draftThread = pending.thread
        draftProvider = calendar
        draftAccountRefusal = refusal
        switchingDraft = true
        draft = pending.draft
        switchingDraft = false
        draftNote = nil
        environment.pendingEvents.activate(pending.key)
    }

    private var draftCalendar: (any CalendarProviding)? { routesByAccount ? draftProvider : (draftProvider ?? provider) }

    public var createRefusal: String? {
        let target: (any CalendarProviding)? = draft != nil ? draftCalendar : (shownProvider ?? provider)
        return (draft != nil ? draftAccountRefusal : nil) ?? target?.info.createRefusal
    }

    public var canCreate: Bool { createRefusal == nil && draft?.problem == nil && !isCreating }

    @discardableResult
    public func createEvent() async -> Bool {
        guard let draft, !isCreating else { return false }
        guard let target = draftCalendar else {
            draftNote = draftAccountRefusal ?? Self.notConnected(String(localized: "this account"))
            return false
        }
        if let refusal = draftAccountRefusal ?? target.info.createRefusal {
            draftNote = refusal
            return false
        }
        if let problem = draft.problem {
            draftNote = problem
            return false
        }
        if draft.mayEmailAttendees {
            hold(draft, on: target)
            return true
        }
        isCreating = true
        defer { isCreating = false }
        let key = CalendarEventStore.key(for: target)
        let pending = placeholder(for: draft, on: target)
        eventStore.applyLocal(key, upsert: pending, provisional: true)
        let event: CalendarEvent
        do {
            event = try await target.createEvent(draft)
        } catch CalendarError.unclear {
            eventStore.removeLocal(key, id: pending.id)
            if await findCreated(draft, on: target) != nil {
                self.draft = nil
                calendarChanged()
                environment.notices.post(String(localized: "Event created."), duration: NoticeCenter.infoDuration)
                await refresh()
                return true
            }
            draftNote = Self.unclearNotFound
            return false
        } catch {
            eventStore.removeLocal(key, id: pending.id)
            draftNote = "Couldn't create the event. \(Self.message(error))"
            return false
        }
        eventStore.replaceLocal(key, id: pending.id, with: event)
        self.draft = nil
        calendarChanged()
        offerUndo(of: event, draft: draft, on: target)
        await refresh()
        return true
    }

    static let unclearNotFound = "Google may not have created the event: it isn't on your calendar yet. "
        + "Check your calendar before you try again."
    static let unclearWithAttendees = "Google may have created the event and emailed its attendees. "
        + "Check your calendar; Mail won't create it again."

    var heldCreateCount: Int { heldCreates.count }

    @ObservationIgnored public var didWrite: (@MainActor () -> Void)?

    private func calendarChanged() {
        didWrite?()
    }

    public func beginDraft(start: Date, end: Date, key: PendingEventKey) async {
        let wasVisible = isVisible
        await beginComposerDraft(key: key, thread: nil)
        setVisible(wasVisible)
        guard draft != nil, draftKey == key else { return }
        draft?.start = start
        draft?.end = max(end, start.addingTimeInterval(15 * 60))
    }

    public func dropDraft() {
        let key = draftKey
        switchingDraft = true
        draft = nil
        switchingDraft = false
        draftNote = nil
        draftKeyOverride = nil
        if let key { environment.pendingEvents.remove(key) }
    }

    @discardableResult
    public func chooseDraftCalendar(account: AccountID) async -> Bool {
        guard draft != nil, draftThread == nil else { return false }
        let chosen = await calendarOf(account)
        guard routesByAccount ? chosen.provider != nil : true else { return false }
        draftProvider = chosen.provider ?? provider
        draftAccountRefusal = await accountRefusal(for: nil, calendar: chosen)
        return true
    }

    public var draftIsFromConversation: Bool { draftThread != nil }

    public var draftCalendarAccount: String? { (draftProvider ?? shownProvider ?? provider).info.account }

    public func show(day: Date) async {
        await showDay(CalendarDateMentions.calendar(timeZone).startOfDay(for: day))
    }

    public var focusSlot: DateInterval? {
        if let draft, draft.end > draft.start { return DateInterval(start: draft.start, end: draft.end) }
        if let thread, let proposal = environment.scheduling?.analyses[thread]?.proposal, proposal.precision != .day,
           proposal.end > proposal.start {
            return DateInterval(start: proposal.start, end: proposal.end)
        }
        return mentionFocus
    }

    public var dayViewDay: Day? {
        let calendar = CalendarDateMentions.calendar(timeZone)
        if let focus = focusSlot, let match = days.first(where: { calendar.isDate($0.start, inSameDayAs: focus.start) }) {
            return match
        }
        return days.first
    }

    public func timeline(for day: Day) -> CalendarDayTimeline {
        CalendarDayTimeline(day: day.start, events: day.events, focus: focusSlot, timeZone: timeZone, now: now())
    }

    public func dayHeader(_ day: Day) -> String {
        day.start.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day())
    }

    public func openEvent(_ event: CalendarEvent) {
        focusedEventKey = CalendarDayTimeline.key(for: event)
        openedEvent = event
    }

    public func closeEvent(keepsFocus: Bool = false) {
        openedEvent = nil
        if !keepsFocus { focusedEventKey = nil }
    }

    private func forgetEvent() {
        openedEvent = nil
        focusedEventKey = nil
    }

    public func isOpened(_ event: CalendarEvent) -> Bool {
        openedEvent.map { CalendarDayTimeline.key(for: $0) == CalendarDayTimeline.key(for: event) } ?? false
    }

    public func isFocused(_ event: CalendarEvent) -> Bool { focusedEventKey == CalendarDayTimeline.key(for: event) }

    public var focusableEvents: [CalendarEvent] {
        guard let day = dayViewDay else { return [] }
        return timeline(for: day).shownEvents
    }

    @discardableResult
    public func moveEventFocus(by delta: Int) -> Bool {
        let shown = focusableEvents
        guard !shown.isEmpty else { return false }
        let keys = shown.map(CalendarDayTimeline.key(for:))
        let index: Int
        if let current = focusedEventKey, let at = keys.firstIndex(of: current) {
            index = min(max(at + delta, 0), keys.count - 1)
        } else {
            index = delta < 0 ? keys.count - 1 : 0
        }
        focusedEventKey = keys[index]
        if openedEvent != nil { openedEvent = shown[index] }
        return true
    }

    @discardableResult
    public func openFocusedEvent() -> Bool {
        let shown = focusableEvents
        guard let event = shown.first(where: { CalendarDayTimeline.key(for: $0) == focusedEventKey }) ?? shown.first else {
            return false
        }
        openEvent(event)
        return true
    }

    public var openedDetails: CalendarEventDetails? {
        guard let opened = openedEvent else { return nil }
        let key = CalendarDayTimeline.key(for: opened)
        let latest = days.lazy.flatMap(\.events).first { CalendarDayTimeline.key(for: $0) == key }
        return details(for: latest ?? opened)
    }

    public func details(for event: CalendarEvent) -> CalendarEventDetails {
        let calendar = eventCalendar(event)
        return CalendarEventDetails(event: event, timeZone: timeZone, calendarName: calendar.name, calendarKey: calendar.key,
                                    myAddresses: calendar.key.isEmpty ? [] : [calendar.key])
    }

    func eventCalendar(_ event: CalendarEvent) -> (key: String, name: String) {
        let key = (event.account ?? shownProvider?.info.account ?? "").lowercased()
        let info = sources.first { $0.owner == key }?.provider.info ?? (shownProvider ?? provider).info
        if let named = event.calendarName?.trimmingCharacters(in: .whitespacesAndNewlines), !named.isEmpty, named != info.name {
            return (key, named)
        }
        let owner = info.account ?? event.account ?? ""
        return (key, owner.isEmpty ? info.name : "\(info.name) · \(owner)")
    }

    static func focus(in mentions: [CalendarDateMention], now: Date) -> DateInterval? {
        let timed = mentions.filter(\.hasTime)
        guard let pick = timed.first(where: { $0.date >= now }) ?? timed.first else { return nil }
        return DateInterval(start: pick.date, duration: pick.duration ?? CalendarEventDraftBuilder.defaultDuration)
    }

    public func dayTitle(_ day: Day) -> String {
        let calendar = CalendarDateMentions.calendar(timeZone)
        let date = day.start.formatted(Date.FormatStyle(timeZone: timeZone).weekday(.abbreviated).month(.abbreviated).day())
        return calendar.isDate(day.start, inSameDayAs: now()) ? String(localized: "Today") + ", " + date : date
    }

    public func timeText(_ start: Date, _ end: Date, allDay: Bool = false) -> String {
        allDay ? String(localized: "All day") : Self.range(start, end, timeZone)
    }

    public func secondTimeText(_ start: Date, _ end: Date, allDay: Bool = false) -> String? {
        guard !allDay, let zone = secondTimeZone else { return nil }
        return Self.range(start, end, zone) + " " + Self.city(zone)
    }

    public func workdayText(_ day: Day) -> String {
        let calendar = CalendarDateMentions.calendar(timeZone)
        guard let open = calendar.date(bySettingHour: Self.workdayHours.lowerBound, minute: 0, second: 0, of: day.start),
              let close = calendar.date(bySettingHour: Self.workdayHours.upperBound, minute: 0, second: 0, of: day.start)
        else { return "" }
        return Self.range(open, close, timeZone)
    }

    public var zonesText: String {
        let first = Self.city(timeZone)
        guard let second = secondTimeZone else { return String(localized: "Times in \(first)") }
        return String(localized: "Times in \(first) · \(Self.city(second))")
    }

    private var undoer: CalendarEventUndoer {
        if let undoerStorage { return undoerStorage }
        let made = CalendarEventUndoer(model: self)
        undoerStorage = made
        return made
    }

    private func hold(_ draft: CalendarEventDraft, on target: any CalendarProviding) {
        let id = UUID()
        let window = createWindow
        let sleep = self.sleep
        let heldThread = draftThread
        let key = CalendarEventStore.key(for: target)
        let pending = placeholder(for: draft, on: target)
        eventStore.applyLocal(key, upsert: pending, provisional: true)
        heldPlaceholders[id] = (key, pending.id)
        let task = Task { [weak self] in
            do { try await sleep(window) } catch { return }
            guard let self, let held = self.heldCreates.removeValue(forKey: id) else { return }
            let shown = self.heldPlaceholders.removeValue(forKey: id)
            await self.createHeld(held.draft, thread: held.thread, on: held.calendar, placeholder: shown)
        }
        heldCreates[id] = (task: task, draft: draft, thread: heldThread, calendar: target)
        self.draft = nil
        let title: LocalizedStringResource = "Creating event…"
        if let undo = environment.undo {
            undo.push(UndoCoordinator.Entry(title: title, token: UndoToken(payload: Data(id.uuidString.utf8)),
                                            expiresAt: Date().addingTimeInterval(NoticeCenter.seconds(window)),
                                            threads: heldThread.map { [$0] } ?? [], undoer: undoer))
        } else {
            environment.notices.post(String(localized: title), duration: window)
        }
    }

    private func createHeld(_ draft: CalendarEventDraft, thread: ThreadKey?, on target: any CalendarProviding,
                            placeholder shown: (key: CalendarCacheKey, id: String)? = nil) async {
        if let refusal = target.info.createRefusal {
            if let shown { eventStore.removeLocal(shown.key, id: shown.id) }
            environment.notices.post(String(localized: "Couldn't create the event. \(refusal)"), style: .error)
            return
        }
        let created: CalendarEvent
        do {
            created = try await target.createEvent(draft)
        } catch CalendarError.unclear {
            if let shown { eventStore.removeLocal(shown.key, id: shown.id) }
            if await findCreated(draft, on: target) != nil {
                calendarChanged()
                environment.notices.post(String(localized: "Event created."), duration: NoticeCenter.infoDuration)
                await refresh()
            } else {
                environment.notices.post(Self.unclearWithAttendees, style: .error)
            }
            return
        } catch {
            if let shown { eventStore.removeLocal(shown.key, id: shown.id) }
            environment.notices.post(String(localized: "Couldn't create the event. \(Self.message(error))"), style: .error)
            if self.draft == nil, self.thread == thread {
                draftThread = thread
                draftProvider = target
                self.draft = draft
                draftNote = "Couldn't create the event. \(Self.message(error))"
            }
            return
        }
        if let shown { eventStore.replaceLocal(shown.key, id: shown.id, with: created) }
        calendarChanged()
        environment.notices.post(draft.emailsAttendees ? String(localized: "Event created. Google emails the invitations.")
                                                       : String(localized: "Event created."),
                                 duration: NoticeCenter.infoDuration)
        await refresh()
    }

    private func findCreated(_ draft: CalendarEventDraft, on target: any CalendarProviding) async -> CalendarEvent? {
        let zone = TimeZone(identifier: draft.timeZone) ?? timeZone
        let calendar = CalendarDateMentions.calendar(zone)
        let day = calendar.startOfDay(for: draft.start)
        let next = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        guard let events = try? await target.events(from: day, to: max(next, draft.end)) else { return nil }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = Set(draft.attendees.map { $0.email.lowercased() })
        return events.first { event in
            event.title.trimmingCharacters(in: .whitespacesAndNewlines) == title && event.start == draft.start
                && wanted.isSubset(of: Set(event.attendees.map { $0.email.lowercased() }))
        }
    }

    private func offerUndo(of event: CalendarEvent, draft: CalendarEventDraft, on target: any CalendarProviding) {
        guard let undo = environment.undo, !event.id.isEmpty, event.attendees.isEmpty, !draft.mayEmailAttendees else {
            environment.notices.post(String(localized: "Event created."))
            return
        }
        let id = UUID()
        createdEvents[id] = (event: event, calendar: target)
        undo.push(UndoCoordinator.Entry(title: "Event created.", token: UndoToken(payload: Data(id.uuidString.utf8)),
                                        expiresAt: Date().addingTimeInterval(NoticeCenter.seconds(createWindow)),
                                        threads: draftThread.map { [$0] } ?? [], undoer: undoer))
    }

    func undoCreate(_ id: UUID) async {
        if let held = heldCreates.removeValue(forKey: id) {
            held.task.cancel()
            if let shown = heldPlaceholders.removeValue(forKey: id) { eventStore.removeLocal(shown.key, id: shown.id) }
            if draft == nil, thread == held.thread {
                draftThread = held.thread
                draftProvider = held.calendar
                draft = held.draft
            }
            environment.notices.post(String(localized: "Event canceled. Nothing was created."),
                                     duration: NoticeCenter.infoDuration)
            return
        }
        guard let created = createdEvents.removeValue(forKey: id), created.event.attendees.isEmpty else {
            environment.notices.post(String(localized: "Too late to undo: the event was already created."),
                                     duration: NoticeCenter.infoDuration)
            return
        }
        let key = CalendarEventStore.key(for: created.calendar)
        eventStore.removeLocal(key, id: created.event.id)
        do {
            try await created.calendar.deleteEvent(created.event)
        } catch {
            eventStore.applyLocal(key, upsert: created.event)
            let why = Self.message(error)
            environment.notices.post(String(localized: "Couldn't remove the event: \(why) Remove it in your calendar."),
                                     style: .error)
            return
        }
        calendarChanged()
        environment.notices.post(String(localized: "Event removed."), duration: NoticeCenter.infoDuration)
        await refresh()
    }

    private func load(days starts: [(Date, Bool)], generation mine: Int, force: Bool) async {
        let calendars = await shownCalendars()
        guard mine == generation, !Task.isCancelled else { return }
        await eventStore.restore(now: now())
        guard mine == generation, !Task.isCancelled else { return }
        sources = calendars.map { (owner: $0.key, key: CalendarEventStore.key(for: $0.provider), provider: $0.provider) }
        mergedSources = showsAllCalendars
        shownStarts = starts
        guard !sources.isEmpty else {
            days = []
            refreshNote = nil
            state = .loaded
            return
        }
        state = paint() ? .loaded : .loading
        await revalidateShown(force: force, generation: mine)
        guard mine == generation, !Task.isCancelled else { return }
        let complete = paint()
        state = complete ? .loaded : failureState() ?? .loaded
    }

    private func revalidateShown(force: Bool, generation mine: Int? = nil) async {
        guard let visible = shownSpan, !sources.isEmpty else { return }
        let calendar = CalendarDateMentions.calendar(timeZone)
        let current = now()
        let store = eventStore
        let due = sources.filter { force || !store.covers($0.key, from: visible.start, to: visible.end)
            || store.isDue($0.key, now: current) }
        if !due.isEmpty { progress = CalendarLoadProgress(done: 0, total: due.count) }
        defer { if mine == nil || mine == generation { progress = nil } }
        for (index, source) in due.enumerated() {
            if Task.isCancelled { return }
            if mine == nil || mine == generation { progress?.done = index + 1 }
            if store.covers(source.key, from: visible.start, to: visible.end) {
                await store.revalidate(source.key, provider: source.provider, visible: visible, today: current,
                                       calendar: calendar, now: current, force: force)
            } else {
                await store.ensure(source.key, provider: source.provider, from: visible.start, to: visible.end,
                                   today: current, calendar: calendar, now: current)
            }
        }
        for source in sources {
            store.prefetchAdjacent(source.key, provider: source.provider, around: visible.start, calendar: calendar,
                                   now: current)
        }
    }

    private var shownSpan: DateInterval? {
        let calendar = CalendarDateMentions.calendar(timeZone)
        guard let first = shownStarts.map(\.0).min(), let last = shownStarts.map(\.0).max() else { return nil }
        let end = calendar.date(byAdding: .day, value: 1, to: last) ?? last.addingTimeInterval(86_400)
        return DateInterval(start: first, end: max(end, first))
    }

    @discardableResult
    private func paint() -> Bool {
        let calendar = CalendarDateMentions.calendar(timeZone)
        let store = eventStore
        var complete = true
        var out: [Day] = []
        var stale = false
        for (start, mentioned) in shownStarts {
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            var day = Day(start: start, isMentioned: mentioned)
            var events: [CalendarEvent] = []
            var busy: [CalendarBusyInterval] = []
            var read = 0
            for source in sources {
                guard let found = store.events(source.key, from: start, to: end),
                      let blocks = store.busy(source.key, from: start, to: end) else {
                    complete = false
                    if let error = store.lastError(source.key), !store.isUpdating(source.key), day.note == nil {
                        day.note = mergedSources && !source.owner.isEmpty
                            ? String(localized: "Couldn't read the calendar of \(source.owner). \(error)")
                            : String(localized: "Couldn't read this day. \(error)")
                    }
                    continue
                }
                read += 1
                if store.lastError(source.key) != nil { stale = true }
                events += mergedSources ? found.map { event in
                    var tagged = event
                    tagged.account = source.owner.isEmpty ? nil : source.owner
                    return tagged
                } : found
                busy += blocks
            }
            if read > 0 {
                day.events = events.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }
                day.busy = CalendarEventStore.merged(busy.sorted { $0.start < $1.start })
                day.free = Self.free(day: day.start, busy: day.busy, calendar: calendar)
            }
            out.append(day)
        }
        if days != out { days = out }
        let note = stale ? CalendarEventStore.couldNotRefresh : nil
        if refreshNote != note { refreshNote = note }
        return complete
    }

    private func failureState() -> LoadState? {
        guard let visible = shownSpan else { return nil }
        let store = eventStore
        let errors = sources.compactMap { source -> String? in
            store.covers(source.key, from: visible.start, to: visible.end) ? nil : store.lastError(source.key)
        }
        guard !errors.isEmpty, errors.count == sources.count else { return nil }
        return .failed(Self.loadFailed(errors[0]))
    }

    private func cacheChanged(_ change: CalendarEventStoreChange) {
        guard sources.contains(where: { $0.key == change.key }) else { return }
        if paint(), state == .loading { state = .loaded }
    }

    public static let placeholderPrefix = "local-"

    private func placeholder(for draft: CalendarEventDraft, on target: any CalendarProviding) -> CalendarEvent {
        CalendarEvent(id: Self.placeholderPrefix + UUID().uuidString, title: draft.title, start: draft.start, end: draft.end,
                      timeZone: draft.timeZone, attendees: draft.attendees, calendarName: target.info.name,
                      organizerIsMe: true)
    }

    private func meetDefault() async -> Bool {
        guard let settings = environment.settings,
              let stored = try? await settings.get(AppSettings.calendarAddMeetLink) else {
            return AppSettings.calendarAddMeetLink.defaultValue
        }
        return stored
    }

    private func accountRefusal(for thread: ThreadKey?,
                                calendar chosen: (provider: (any CalendarProviding)?, owner: Account?)) async -> String? {
        if routesByAccount {
            guard chosen.provider == nil else { return nil }
            return Self.notConnected(chosen.owner?.email ?? String(localized: "this account"))
        }
        guard let calendarAccount = provider.info.account?.lowercased(), !calendarAccount.isEmpty, let thread else {
            return nil
        }
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        guard let owner = accounts.first(where: { $0.id == thread.account }) else {
            return "Mail couldn't tell which account this conversation is in, so it won't create an event from it."
        }
        if owner.email.lowercased() == calendarAccount { return nil }
        return "This conversation is in \(owner.email); the calendar is \(calendarAccount)'s. "
            + "Mail never puts one account's event on another account's calendar."
    }

    private func myAddresses(_ thread: ThreadKey?) async -> Set<String> {
        let accounts = await AIThreadLoader.first(environment.data.accounts()) ?? []
        let mine = accounts.filter { thread == nil || $0.id == thread?.account }
        return mine.reduce(into: Set<String>()) { $0.formUnion($1.myAddresses) }
    }

    static func days(for mentions: [CalendarDateMention], timeZone: TimeZone, now: Date) -> [(Date, Bool)] {
        let mentioned = CalendarDateMentions.days(mentions, timeZone: timeZone, today: now)
        if mentioned.isEmpty { return [(CalendarDateMentions.calendar(timeZone).startOfDay(for: now), false)] }
        return mentioned.map { ($0, true) }
    }

    nonisolated static func scan(_ thread: CalendarThreadText?, timeZone: TimeZone, now: Date) async -> [CalendarDateMention] {
        var out = await scan(thread?.texts ?? [], timeZone: timeZone)
        if let thread, let facts = EmailEventExtractor.extract(texts: thread.texts, htmls: thread.htmls, timeZone: timeZone,
                                                              now: now), !out.contains(where: { $0.date == facts.start }),
           facts.start >= now || !CalendarEventDraftBuilder.hasFutureTimedMention(out, now: now) {
            let span = facts.end.map { $0.timeIntervalSince(facts.start) }
            out.insert(CalendarDateMention(date: facts.start, hasTime: facts.hasTime, duration: span.flatMap { $0 > 0 ? $0 : nil },
                                           namedTimeZone: facts.zoneAbbreviation != nil), at: 0)
        }
        return out
    }

    nonisolated static func scan(_ texts: [String], timeZone: TimeZone) async -> [CalendarDateMention] {
        await Task.detached(priority: .userInitiated) {
            var out: [CalendarDateMention] = []
            for text in texts where out.count < CalendarDateMentions.maxMentions {
                out += CalendarDateMentions.find(in: text, timeZone: timeZone)
            }
            return Array(out.prefix(CalendarDateMentions.maxMentions))
        }.value
    }

    static func free(day: Date, busy: [CalendarBusyInterval], calendar: Calendar) -> [CalendarBusyInterval] {
        guard let open = calendar.date(bySettingHour: workdayHours.lowerBound, minute: 0, second: 0, of: day),
              let close = calendar.date(bySettingHour: workdayHours.upperBound, minute: 0, second: 0, of: day) else { return [] }
        var gaps: [CalendarBusyInterval] = []
        var cursor = open
        for block in busy.sorted(by: { $0.start < $1.start }) where block.end > cursor && block.start < close {
            if block.start > cursor { gaps.append(CalendarBusyInterval(start: cursor, end: min(block.start, close))) }
            cursor = max(cursor, block.end)
        }
        if cursor < close { gaps.append(CalendarBusyInterval(start: cursor, end: close)) }
        return gaps.filter { $0.duration >= minimumFree }
    }

    static func range(_ start: Date, _ end: Date, _ zone: TimeZone) -> String {
        (start..<max(start, end)).formatted(Date.IntervalFormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }

    static func city(_ zone: TimeZone) -> String {
        let last = zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier
        return last.replacingOccurrences(of: "_", with: " ")
    }

    static func message(_ error: Error) -> String {
        (error as? CalendarError)?.description ?? String(localized: "The calendar didn't answer.")
    }
}

@MainActor
final class CalendarEventUndoer: MailUndoing {
    private weak var model: CalendarSidebarModel?

    init(model: CalendarSidebarModel) {
        self.model = model
    }

    nonisolated func undo(_ token: UndoToken) async throws -> UndoToken? {
        guard let id = UUID(uuidString: String(decoding: token.payload, as: UTF8.self)) else { return nil }
        await undoCreate(id)
        return nil
    }

    private func undoCreate(_ id: UUID) async { await model?.undoCreate(id) }
}
