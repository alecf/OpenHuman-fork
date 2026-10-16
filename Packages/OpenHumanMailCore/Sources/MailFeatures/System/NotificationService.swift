import Foundation
import MailActions
import MailModel
import OpenHumanCore

public enum NotificationRoute: Sendable, Hashable {
    case thread(ThreadKey)
    case reviewQueue
}

@MainActor
public final class NotificationService {
    public static let defaultCoalesce: Duration = .seconds(2)

    private let data: any MailDataSource
    private let notices: NoticeCenter
    private let notifier: any SystemNotifying
    private let preferences: SystemPreferences
    private let isAppActive: @MainActor () -> Bool
    private let activateApp: @MainActor () -> Void
    private let mirror: ReminderNotificationMirror?
    var coalesce: Duration
    private let calendar: Calendar
    private let locale: Locale
    private let now: @Sendable () -> Date
    private let systemNotifications: Bool
    private weak var environment: AppEnvironment?

    private var accountsTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var mailTasks: [AccountID: Task<Void, Never>] = [:]
    private var seen: [AccountID: [ThreadKey: Date]] = [:]
    private var newMail: [AccountID: [ThreadRow]] = [:]
    private var flushTasks: [String: Task<Void, Never>] = [:]
    private var knownDrafts: Set<DraftKey>?
    private var newDrafts = 0
    private var wokenThreads: [ThreadKey] = []
    private var batchCounter = 0
    private var accountNames: [AccountID: String] = [:]
    public private(set) var postedCount = 0
    private var postedByAccount: [AccountID: Set<String>] = [:]

    public init(environment: AppEnvironment, platform: SystemPlatform, preferences: SystemPreferences,
                mirror: ReminderNotificationMirror?, coalesce: Duration = NotificationService.defaultCoalesce,
                calendar: Calendar = .current, locale: Locale = .current,
                systemNotifications: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) {
        self.systemNotifications = systemNotifications
        self.now = now
        self.environment = environment
        self.data = environment.data
        self.notices = environment.notices
        self.notifier = platform.notifier
        self.preferences = preferences
        self.isAppActive = platform.isAppActive
        self.activateApp = platform.activateApp
        self.mirror = mirror
        self.coalesce = coalesce
        self.calendar = calendar
        self.locale = locale
    }

    isolated deinit {
        accountsTask?.cancel()
        reviewTask?.cancel()
        for task in mailTasks.values { task.cancel() }
        for task in flushTasks.values { task.cancel() }
    }

    public func start() {
        guard accountsTask == nil else { return }
        notifier.setResponder { [weak self] response in self?.respond(to: response) }
        let data = self.data
        accountsTask = Task { [weak self] in
            do {
                for try await accounts in data.accounts() {
                    guard let self else { return }
                    self.accountNames = Dictionary(accounts.map { ($0.id, $0.alias ?? $0.email) }, uniquingKeysWith: { a, _ in a })
                    self.follow(accounts.map(\.id))
                }
            } catch {}
        }
        reviewTask = Task { [weak self] in
            do {
                for try await drafts in data.reviewQueue(nil) {
                    guard let self else { return }
                    self.reviewQueueChanged(drafts)
                }
            } catch {}
        }
    }

    public func stop() {
        accountsTask?.cancel()
        reviewTask?.cancel()
        accountsTask = nil
        reviewTask = nil
        for task in mailTasks.values { task.cancel() }
        mailTasks = [:]
        notifier.setResponder(nil)
    }

    private func follow(_ accounts: [AccountID]) {
        let wanted = Set(accounts)
        for (id, task) in mailTasks where !wanted.contains(id) {
            task.cancel()
            mailTasks[id] = nil
            seen[id] = nil
        }
        for id in accounts where mailTasks[id] == nil {
            let data = self.data
            mailTasks[id] = Task { [weak self] in
                do {
                    for try await window in data.threadWindow(.system(.inbox), account: id, limit: 50) {
                        guard let self else { return }
                        self.inboxChanged(account: id, rows: window.rows)
                    }
                } catch {}
            }
        }
    }

    func inboxChanged(account: AccountID, rows: [ThreadRow]) {
        let previous = seen[account]
        var next: [ThreadKey: Date] = [:]
        for row in rows { next[row.id] = row.lastMessageAt }
        seen[account] = next
        guard let previous else { return }
        let mode = preferences.newMailMode(account)
        guard mode != .off else { return }
        let fresh = rows.filter { row in
            row.isUnread && (mode == .allInbox || row.isImportant)
                && (previous[row.id].map { row.lastMessageAt > $0 } ?? true)
        }
        guard !fresh.isEmpty else { return }
        var notify = fresh
        if let focus = environment?.system.focus, focus.holdsNewMail(for: account) {
            let vips = environment?.vips
            let held = fresh.filter { !(vips?.hasVIPSender($0) ?? false) }
            if !held.isEmpty { focus.hold(held.map(\.id)) }
            notify = fresh.filter { vips?.hasVIPSender($0) ?? false }
            guard !notify.isEmpty else { return }
        }
        newMail[account, default: []].append(contentsOf: notify)
        scheduleFlush("mail.\(account.rawValue)") { await $0.flushNewMail(account) }
    }

    private func flushNewMail(_ account: AccountID) async {
        let rows = newMail.removeValue(forKey: account) ?? []
        let mode = preferences.newMailMode(account)
        var unique: [ThreadRow] = []
        for row in rows where !unique.contains(where: { $0.id == row.id }) && (mode == .allInbox || row.isImportant) {
            unique.append(row)
        }
        let inbox = seen[account] ?? [:]
        unique.removeAll { inbox[$0.id] == nil }
        if unique.contains(where: { !$0.userLabelIDs.isEmpty }), let muted = await mutedLabelID(account) {
            unique.removeAll { $0.userLabelIDs.contains(muted) }
        }
        guard !unique.isEmpty, mode != .off, !isAppActive() else { return }
        guard await ensureAuthorized() else { return }
        let previews = !preferences.hidePreviews
        batchCounter += 1
        let id = "newmail.\(account.rawValue).\(batchCounter)"
        if unique.count == 1, let row = unique.first {
            let hidden = mode == .allInbox ? Self.hiddenPreviewTitleAnyMail : Self.hiddenPreviewTitle
            await post(SystemNotification(identifier: id, title: previews ? Self.sender(of: row) : hidden,
                                          subtitle: subtitle(for: account),
                                          body: previews ? row.subject : "", threadIdentifier: "account.\(account.rawValue)",
                                          category: .newMail, userInfo: NotificationRouting.userInfo(for: row.id)))
        } else {
            let senders = unique.prefix(3).map(Self.sender(of:)).joined(separator: ", ")
            let title = mode == .allInbox ? "\(unique.count) new messages" : "\(unique.count) new important messages"
            await post(SystemNotification(identifier: id, title: title,
                                          subtitle: subtitle(for: account),
                                          body: previews ? senders : "", threadIdentifier: "account.\(account.rawValue)",
                                          userInfo: ["account": String(account.rawValue)]))
        }
    }

    func subtitle(for account: AccountID) -> String? {
        accountNames.count >= 2 ? accountNames[account] : nil
    }

    public static let hiddenPreviewTitle = "New important message"
    public static let hiddenPreviewTitleAnyMail = "New message"

    public static let focusSummaryTitle = "While your Focus was on"

    func postFocusSummary(account: AccountID, name: String, count: Int) async {
        guard count > 0, await ensureAuthorized() else { return }
        batchCounter += 1
        let body = count == 1 ? "1 important conversation arrived in \(name)."
                              : "\(count) important conversations arrived in \(name)."
        await post(SystemNotification(identifier: "focus.\(account.rawValue).\(batchCounter)", title: Self.focusSummaryTitle,
                                      body: body, threadIdentifier: "account.\(account.rawValue)",
                                      userInfo: NotificationRouting.importantRoute(account)))
    }

    static func sender(of row: ThreadRow) -> String {
        let other = row.participants.first { !$0.isMe }
        let name = other.flatMap { $0.name?.isEmpty == false ? $0.name : $0.email }
        return name ?? (row.participantsDisplay.isEmpty ? "New message" : row.participantsDisplay)
    }

    func reviewQueueChanged(_ drafts: [DraftSummary]) {
        let pending = Set(drafts.filter { $0.review == .pending }.map(\.id))
        defer { knownDrafts = pending }
        guard let known = knownDrafts else { return }
        let added = pending.subtracting(known).count
        guard added > 0, preferences.agentDrafts else { return }
        newDrafts += added
        scheduleFlush("review") { await $0.flushDrafts() }
    }

    private func flushDrafts() async {
        let count = newDrafts
        newDrafts = 0
        guard count > 0, preferences.agentDrafts else { return }
        let text = count == 1 ? "1 draft ready to review" : "\(count) drafts ready to review"
        if isAppActive() {
            notices.post(text, style: .info, actionTitle: "Review") { [weak self] in self?.route(.reviewQueue) }
            return
        }
        guard await ensureAuthorized() else { return }
        batchCounter += 1
        await post(SystemNotification(identifier: "review.\(batchCounter)", title: text, threadIdentifier: "review",
                                      userInfo: NotificationRouting.reviewRoute))
    }

    public func handle(_ notice: AppEngineNotice) async {
        switch notice {
        case .operationFailed(_, let kind, _):
            notices.post("Couldn't \(Self.phrase(for: kind)). The change didn't go through.", style: .error,
                         duration: notices.timing.error)
        case .sendFailed:
            await alert(id: "sendfailed", title: "Couldn't send a message", body: "It is saved as a draft.",
                        toast: "Couldn't send. Saved as draft.", style: .error, persistent: true)
        case .sendInterrupted:
            await alert(id: "sendinterrupted", title: "A send was interrupted", body: "Check Drafts before sending again.",
                        toast: "A send was interrupted. Check Drafts before sending again.", style: .error, persistent: true)
        case .scheduledSendNeedsConfirmation:
            await alert(id: "sendreview", title: "A scheduled send needs your review",
                        body: "It was not sent. Open Drafts to review it.",
                        toast: "A scheduled send needs your review before it can send.", style: .info, persistent: false)
        case .scheduledSendCancelledByReply:
            await alert(id: "sendcancelledreply", title: Self.cancelledByReplyTitle, body: Self.cancelledByReplyBody,
                        toast: Self.cancelledByReplyToast, style: .info, persistent: false)
        case .schedulerDegraded(let kind):
            notices.post(Self.schedulerStoppedText(kind), style: .error, duration: notices.timing.error)
        case .accountNeedsReauth(let account):
            guard !isAppActive(), await ensureAuthorized() else { return }
            let name = subtitle(for: account)
            await post(SystemNotification(identifier: "reauth.\(account.rawValue)",
                                          title: name.map { "\($0) needs you to sign in" } ?? "Sign in to Mail again",
                                          body: name.map { "Mail can't sync \($0) until you sign in again." }
                                              ?? "Google needs you to sign in again before mail can sync."))
        case .scheduleLabelBudget:
            break
        case .snoozeWoke(let thread, _):
            guard systemNotifications, preferences.snoozeReturned else { return }
            wokenThreads.append(thread)
            scheduleFlush("snooze") { await $0.flushWoken() }
        case .reminderFired(let thread, let overdue):
            guard systemNotifications else { return }
            await reminderFired(thread, overdue: overdue)
        }
    }

    private func flushWoken() async {
        var threads: [ThreadKey] = []
        for thread in wokenThreads where !threads.contains(thread) { threads.append(thread) }
        wokenThreads = []
        guard !threads.isEmpty, preferences.snoozeReturned else { return }
        let subject = threads.count == 1 ? await subject(of: threads[0]) : nil
        let previews = !preferences.hidePreviews
        let title = threads.count == 1 ? "Snooze returned" : "\(threads.count) snoozed conversations are back"
        let body = previews ? (subject ?? "") : ""
        if isAppActive() {
            let text = threads.count == 1 ? (previews && subject != nil ? "“\(subject!)” is back in your inbox" : "A snoozed conversation is back")
                                           : title
            let first = threads[0]
            notices.post(text, style: .info, actionTitle: threads.count == 1 ? "Open" : nil) { [weak self] in
                self?.route(.thread(first))
            }
            return
        }
        guard await ensureAuthorized() else { return }
        batchCounter += 1
        let accounts = Set(threads.map(\.account))
        await post(SystemNotification(identifier: "snooze.\(batchCounter)", title: title,
                                      subtitle: accounts.count == 1 ? accounts.first.flatMap { subtitle(for: $0) } : nil,
                                      body: body, threadIdentifier: "snooze",
                                      userInfo: threads.count == 1 ? NotificationRouting.userInfo(for: threads[0]) : [:]))
    }

    private func reminderFired(_ thread: ThreadKey, overdue: TimeInterval) async {
        guard let item = mirror?.lastSeen[thread] else { return }
        let hide = preferences.hidePreviews
        let late = overdue >= 120
        if isAppActive() {
            let text = late ? ReminderNotificationMirror.missedTitle(for: item, hidePreviews: hide, calendar: calendar, locale: locale)
                            : ReminderNotificationMirror.title(for: item, hidePreviews: hide)
            notices.post(text, style: .info, actionTitle: "Open", duration: notices.timing.error) { [weak self] in
                self?.route(.thread(thread))
            }
            return
        }
        guard late else { return }
        let delivered = await notifier.deliveredIdentifiers()
        guard !delivered.contains(item.notificationIdentifier), await ensureAuthorized() else { return }
        await post(SystemNotification(
            identifier: "reminder.missed.\(item.id)",
            title: ReminderNotificationMirror.missedTitle(for: item, hidePreviews: hide, calendar: calendar, locale: locale),
            threadIdentifier: "reminders", userInfo: NotificationRouting.userInfo(for: thread)))
    }

    private func alert(id: String, title: String, body: String, toast: String, style: Toast.Style, persistent: Bool) async {
        if isAppActive() {
            guard !notices.toasts.contains(where: { $0.message == toast }) else { return }
            notices.post(toast, style: style, duration: persistent ? nil : notices.timing.error)
            return
        }
        guard await ensureAuthorized() else { return }
        await post(SystemNotification(identifier: id, title: title, body: body))
    }

    static func phrase(for kind: String) -> String {
        switch kind {
        case "markDone": "mark done"
        case "moveToInbox": "move to Inbox"
        case "trash": "move to Trash"
        case "untrash": "restore from Trash"
        case "markRead": "mark read"
        case "markUnread": "mark unread"
        case "star": "star"
        case "unstar": "remove the star"
        case "markSpam": "mark as spam"
        case "markNotSpam": "mark as not spam"
        case "modifyLabels": "change labels"
        case "snooze": "snooze"
        case "unsnooze": "wake"
        case "sendDraft", "send_draft": "send"
        case "modify_labels": "update labels"
        case "upsert_draft": "save a draft to Gmail"
        case "delete_draft": "delete a draft in Gmail"
        case "create_label": "create a label"
        default: "make that change"
        }
    }

    static func schedulerName(_ kind: String) -> String? {
        switch kind {
        case "snooze": "Snooze"
        case "send_later": "Send later"
        case "reminder": "Reminders"
        default: nil
        }
    }

    static func schedulerStoppedText(_ kind: String) -> String {
        guard let name = schedulerName(kind) else {
            return "Background tasks stopped after repeated errors. Quit and open Mail again."
        }
        return "\(name) stopped after repeated errors. Restart Mail to try again."
    }

    static let cancelledByReplyTitle = "A scheduled send was cancelled"
    static let cancelledByReplyBody = "Someone replied before it was due. It's back in Drafts."
    static let cancelledByReplyToast = "Someone replied first, so a scheduled send was cancelled. It's in Drafts."

    func respond(to response: NotificationResponse) {
        let thread = NotificationRouting.thread(from: response.userInfo)
        switch response.action {
        case .open:
            activateApp()
            if let thread { route(.thread(thread)) } else if response.userInfo["route"] == "review" { route(.reviewQueue) }
            else if let account = response.userInfo["account"].flatMap(Int64.init) {
                environment?.router.switchAccount(to: AccountID(account))
                if response.userInfo["route"] == NotificationRouting.importantRouteName { environment?.router.goToImportant() }
            }
        case .markDone, .markRead, .snooze, .remindIfNoReply:
            guard let thread, let environment else { return }
            runButton(response.action, thread: thread, environment: environment)
            Task { await notifier.remove(identifiers: [response.identifier]) }
        }
    }

    private func runButton(_ action: NotificationResponse.Action, thread: ThreadKey, environment: AppEnvironment) {
        switch action {
        case .markDone, .markRead:
            var context = environment.router.actionContext()
            context.account = thread.account
            context.selection = [thread]
            context.focusedThread = thread
            context.targets.anyUnread = true
            let id: ActionID = action == .markDone ? .markDone : .toggleRead
            Task { await environment.actions.run(id, source: .toast, host: environment.router, context: context) }
        case .snooze:
            guard environment.actions.descriptor(.snooze) != nil,
                  let date = Self.snoozeTime(now: now(), calendar: calendar, defaults: environment.reminderTimes.defaults)
            else { return }
            environment.actions.threadActions?.snooze([thread], until: date, host: environment.router)
        case .remindIfNoReply:
            guard environment.actions.descriptor(.remind) != nil,
                  let date = Self.remindTime(now: now(), calendar: calendar, defaults: environment.reminderTimes.defaults)
            else { return }
            environment.actions.threadActions?.remind(thread, at: date, kind: .ifNoReply, host: environment.router)
        case .open:
            break
        }
    }

    static func snoozeTime(now: Date, calendar: Calendar, defaults: TimeDefaults = TimeDefaults()) -> Date? {
        TimePresets(timeZone: calendar.timeZone, defaults: defaults).presets(for: .snooze, now: now)
            .first { $0.date != nil }?.date
    }

    static func remindTime(now: Date, calendar: Calendar, defaults: TimeDefaults = TimeDefaults()) -> Date? {
        TimePresets(timeZone: calendar.timeZone, defaults: defaults).presets(for: .remind, now: now)
            .first { $0.id == "tomorrowMorning" }?.date
    }

    func route(_ route: NotificationRoute) {
        guard let router = environment?.router else { return }
        switch route {
        case .thread(let key):
            router.switchAccount(to: key.account)
            router.open(key)
        case .reviewQueue:
            router.go(to: .reviewQueue(nil))
        }
    }

    public func removeAccount(_ account: AccountID) async {
        mailTasks.removeValue(forKey: account)?.cancel()
        seen[account] = nil
        newMail[account] = nil
        flushTasks.removeValue(forKey: "mail.\(account.rawValue)")?.cancel()
        wokenThreads.removeAll { $0.account == account }
        let prefix = "newmail.\(account.rawValue)."
        let reauth = "reauth.\(account.rawValue)"
        var identifiers = postedByAccount.removeValue(forKey: account) ?? []
        let delivered = await notifier.deliveredIdentifiers()
        let pending = await notifier.pendingIdentifiers()
        for id in delivered + pending where id.hasPrefix(prefix) || id == reauth { identifiers.insert(id) }
        if !identifiers.isEmpty { await notifier.remove(identifiers: identifiers.sorted()) }
        await mirror?.removeAccount(account)
    }

    func hasBaseline(for account: AccountID) -> Bool { seen[account] != nil }
    var hasReviewBaseline: Bool { knownDrafts != nil }
    func pendingNewMailCount(_ account: AccountID) -> Int { newMail[account]?.count ?? 0 }
    func inboxHas(_ thread: ThreadKey) -> Bool { seen.values.contains { $0[thread] != nil } }

    private func mutedLabelID(_ account: AccountID) async -> Int64? {
        do {
            for try await labels in data.labels(account) { return labels.first { $0.name == OHGmailLabels.muted }?.id }
        } catch {}
        return nil
    }

    func ensureAuthorized() async -> Bool {
        guard systemNotifications else { return false }
        return await notifier.authorization() == .authorized
    }

    public func requestPermissionIfNeeded() async -> NotificationAuthorization {
        if systemNotifications, await notifier.authorization() == .notDetermined {
            _ = await notifier.requestAuthorization()
        }
        return await notifier.authorization()
    }

    private func post(_ notification: SystemNotification) async {
        postedCount += 1
        if let raw = notification.userInfo["account"].flatMap(Int64.init) {
            postedByAccount[AccountID(raw), default: []].insert(notification.identifier)
        }
        await notifier.schedule(notification)
    }

    private func subject(of thread: ThreadKey) async -> String? {
        do {
            for try await detail in data.threadDetail(thread) { return detail?.subject }
        } catch {}
        return nil
    }

    private func scheduleFlush(_ key: String, _ body: @escaping @MainActor (NotificationService) async -> Void) {
        guard flushTasks[key] == nil else { return }
        let window = coalesce
        flushTasks[key] = Task { [weak self] in
            if window > .zero { try? await Task.sleep(for: window) }
            guard !Task.isCancelled, let self else { return }
            self.flushTasks[key] = nil
            await body(self)
        }
    }

    public func flushNow() async {
        for task in flushTasks.values { task.cancel() }
        flushTasks = [:]
        for account in Array(newMail.keys) { await flushNewMail(account) }
        await flushDrafts()
        await flushWoken()
    }
}
