import Foundation
import MailModel
import OpenHumanCore

@MainActor
public final class ReminderNotificationMirror {
    public static let pendingLimit = 50
    public static let prefix = "reminder."

    public enum Permission: Sendable, Hashable { case unknown, allowed, denied }
    public private(set) var permission: Permission = .unknown

    private let data: any MailDataSource
    private let settings: (any SettingsPort)?
    private let notifier: any SystemNotifying
    private let now: @Sendable () -> Date
    private let hidePreviews: @MainActor () -> Bool
    private let calendar: @Sendable () -> Calendar
    private var task: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var scheduled: [String: ScheduledCopy] = [:]
    private struct ScheduledCopy: Equatable {
        let dueAt: Date
        let title: String
    }
    private var items: [ReminderItem] = []
    private var enabled = true
    private(set) var lastSeen: [ThreadKey: ReminderItem] = [:]
    private var passTail: Task<Void, Never>?
    private(set) var passesInFlight = 0

    public init(data: any MailDataSource, settings: (any SettingsPort)?, notifier: any SystemNotifying,
                hidePreviews: @escaping @MainActor () -> Bool = { false },
                now: @escaping @Sendable () -> Date = { Date() }, calendar: @escaping @Sendable () -> Calendar = { .current }) {
        self.data = data
        self.settings = settings
        self.notifier = notifier
        self.hidePreviews = hidePreviews
        self.now = now
        self.calendar = calendar
    }

    isolated deinit {
        task?.cancel()
        for t in tasks { t.cancel() }
    }

    public func start() {
        guard task == nil else { return }
        let data = self.data
        task = Task { [weak self] in
            do {
                for try await list in data.reminders(nil) {
                    guard let self else { return }
                    await self.sync(list)
                }
            } catch {}
        }
        if let settings {
            tasks.append(Task { [weak self] in
                for await value in settings.observe(AppSettings.schedulerReminders) {
                    guard let self else { return }
                    self.enabled = value
                    await self.sync(self.items)
                }
            })
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        for t in tasks { t.cancel() }
        tasks = []
    }

    public func resync() async {
        await serially { [self] in
            scheduled = [:]
            await reconcile()
        }
    }

    public func removeAccount(_ account: AccountID) async {
        await serially { [self] in
            let known = items.filter { $0.thread.account == account } + lastSeen.values.filter { $0.thread.account == account }
            let identifiers = Set(known.flatMap { [$0.notificationIdentifier, "reminder.missed.\($0.id)"] })
            lastSeen = lastSeen.filter { $0.key.account != account }
            for id in identifiers { scheduled[id] = nil }
            if !identifiers.isEmpty { await notifier.remove(identifiers: identifiers.sorted()) }
            items = items.filter { $0.thread.account != account }
            await reconcile()
        }
    }

    public func sync(_ list: [ReminderItem]) async {
        items = list
        for item in list { lastSeen[item.thread] = item }
        if lastSeen.count > 500 { lastSeen = Dictionary(uniqueKeysWithValues: list.map { ($0.thread, $0) }) }
        await serially { [self] in await reconcile() }
    }

    private func serially(_ pass: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = passTail
        passesInFlight += 1
        let mine = Task { @MainActor in
            await previous?.value
            await pass()
        }
        passTail = mine
        await mine.value
        passesInFlight -= 1
    }

    private func reconcile() async {
        let list = items
        let current = now()
        let wanted = enabled
            ? list.filter { $0.dueAt > current && !$0.isSomeday }.sorted { $0.dueAt < $1.dueAt }.prefix(Self.pendingLimit)
            : []
        let authorization = await notifier.authorization()
        permission = switch authorization {
        case .authorized: .allowed
        case .denied: .denied
        case .notDetermined: .unknown
        }
        let pending = await notifier.pendingIdentifiers().filter { $0.hasPrefix(Self.prefix) }
        let wantedIDs = Set(wanted.map(\.notificationIdentifier))
        let stale = pending.filter { !wantedIDs.contains($0) }
        if !stale.isEmpty {
            await notifier.remove(identifiers: stale)
            for id in stale { scheduled[id] = nil }
        }
        guard authorization == .authorized else { return }
        let category: SystemNotification.Category = data.safeMode().allowsMailChanges ? .reminder : .readOnly
        let pendingSet = Set(pending)
        let hide = hidePreviews()
        for item in wanted {
            let id = item.notificationIdentifier
            let copy = ScheduledCopy(dueAt: item.dueAt, title: Self.title(for: item, hidePreviews: hide))
            if pendingSet.contains(id), scheduled[id] == copy { continue }
            scheduled[id] = copy
            await notifier.schedule(SystemNotification(
                identifier: id, title: copy.title,
                threadIdentifier: "reminders", category: category, deliverAt: item.dueAt, userInfo: NotificationRouting.userInfo(for: item.thread)))
        }
    }

    static func title(for item: ReminderItem, hidePreviews: Bool) -> String {
        let lead = item.kind == .ifNoReply ? "No reply yet" : "Reminder"
        return hidePreviews || item.subject.isEmpty ? lead : "\(lead): \(item.subject)"
    }

    static func missedTitle(for item: ReminderItem, hidePreviews: Bool, calendar: Calendar, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        style.calendar = calendar
        let due = item.dueAt.formatted(style)
        let subject = hidePreviews || item.subject.isEmpty ? "" : ": \(item.subject)"
        return "Missed reminder\(subject) (due \(due))"
    }
}
