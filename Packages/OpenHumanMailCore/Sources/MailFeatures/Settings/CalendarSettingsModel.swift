import Foundation
import MailActions
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class CalendarSettingsModel {
    public struct ZoneChoice: Identifiable, Hashable, Sendable {
        public let identifier: String?
        public let title: String
        public var id: String { identifier ?? "" }
    }

    public static let notConnectedTitle = "Google Calendar is not connected"
    public static let unavailableNote = "Google Calendar connects only on a real Google account, from this page. This run "
        + "has no connection to Google, so the calendar sidebar and its shortcuts are not shown."
    public static let connectNote = "Turning this on opens Google in your browser to let Mail read this account's calendar "
        + "(events and free/busy) and create events. It is asked for on its own: your Gmail sign-in and its "
        + "permission don't change. Turning it off deletes Mail's calendar access on this Mac; nothing is revoked at Google."
    public static let createNote = "Nothing is created until you press Create event. An event that emails its attendees waits a few seconds first, so Undo "
        + "(⌘Z) can stop it; any other can be undone (deleted) in the same few seconds."
    public static let zoneNote = "Shown beside every time in the calendar sidebar and in the event draft. Stored on this Mac."
    public static let meetNote = "Google Meet only. Each draft has its own switch; this is where it starts. Stored on this Mac."
    public static let reconnectText = "Google stopped accepting Mail's calendar access. Turn this on to connect again."

    public let secondTimeZone: StoredSetting<String?>
    public let addMeetLink: StoredSetting<Bool>
    public let confirmMoves: StoredSetting<Bool>
    public let workdayStart: StoredSetting<Int>
    public let workdayEnd: StoredSetting<Int>
    public let bufferMinutes: StoredSetting<Int>
    public let acceptedHoldKind: StoredSetting<CalendarHoldKind>
    public let schedulingLink: StoredSetting<String?>
    public let suggestReplyTimes: StoredSetting<Bool>
    public let offerMoves: StoredSetting<Bool>
    public static let schedulingNote = "Times are suggested from your calendar on this Mac. Replies open as drafts; "
        + "nothing is sent for you. Moving a meeting waits a few seconds so Undo can stop it, and Google emails its "
        + "attendees."
    public static let linkNote = "Your own booking page, added to suggested-times replies. Mail never makes one up."
    public let showAll: StoredSetting<Bool>
    public private(set) var connection: CalendarConnectionState?
    public private(set) var isConnecting = false
    public private(set) var connectError: String?
    public private(set) var inboxCalendars: [InboxCalendar] = []
    @ObservationIgnored private unowned let environment: AppEnvironment
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var inboxTask: Task<Void, Never>?
    @ObservationIgnored private var pending: Bool?

    public init(environment: AppEnvironment) {
        self.environment = environment
        secondTimeZone = StoredSetting(AppSettings.calendarSecondTimeZone, port: environment.settings)
        addMeetLink = StoredSetting(AppSettings.calendarAddMeetLink, port: environment.settings)
        confirmMoves = StoredSetting(AppSettings.calendarConfirmMoves, port: environment.settings)
        workdayStart = StoredSetting(AppSettings.calendarWorkdayStartHour, port: environment.settings)
        workdayEnd = StoredSetting(AppSettings.calendarWorkdayEndHour, port: environment.settings)
        bufferMinutes = StoredSetting(AppSettings.calendarBufferMinutes, port: environment.settings)
        acceptedHoldKind = StoredSetting(AppSettings.calendarAcceptedHoldKind, port: environment.settings)
        schedulingLink = StoredSetting(AppSettings.calendarSchedulingLink, port: environment.settings)
        suggestReplyTimes = StoredSetting(AppSettings.calendarSuggestReplyTimes, port: environment.settings)
        offerMoves = StoredSetting(AppSettings.calendarOfferMoves, port: environment.settings)
        showAll = StoredSetting(AppSettings.calendarShowAll, port: environment.settings)
        accountsPort = environment.accounts
    }

    isolated deinit {
        connectionTask?.cancel()
        inboxTask?.cancel()
        clientTask?.cancel()
    }

    public func start() {
        secondTimeZone.start()
        addMeetLink.start()
        confirmMoves.start()
        for setting in [workdayStart, workdayEnd, bufferMinutes] { setting.start() }
        acceptedHoldKind.start()
        schedulingLink.start()
        suggestReplyTimes.start()
        offerMoves.start()
        showAll.start()
        startInboxes()
        guard connectionTask == nil, let port = environment.calendarConnection else { return }
        connectionTask = Task { [weak self] in
            for await next in port.connectionStates() {
                guard !Task.isCancelled, let self else { return }
                self.connection = next
            }
        }
    }

    public var isConfigured: Bool { environment.calendar != nil }
    public var routesByAccount: Bool { environment.calendarConnections?.routesByAccount == true }
    public var isRunning: Bool { environment.modules.modules.contains(.calendar) }
    public var canChangeZone: Bool { environment.settings != nil }
    public var canChangeMeetDefault: Bool { environment.settings != nil }
    public var canConnect: Bool { environment.calendarConnection != nil }

    public var isConnected: Bool { pending ?? (connection?.status == .connected) }

    public func setConnected(_ on: Bool) async {
        guard let port = environment.calendarConnection, !isConnecting else { return }
        isConnecting = true
        pending = on
        connectError = nil
        defer {
            isConnecting = false
            pending = nil
        }
        do {
            if on { try await port.connect() } else { try await port.disconnect() }
        } catch {
            connectError = (error as? CalendarError)?.description ?? "That didn't work. Try again."
        }
    }

    public func setAddMeetLink(_ on: Bool) async { await addMeetLink.set(on) }
    public func setConfirmMoves(_ on: Bool) async { await confirmMoves.set(on) }

    public private(set) var clients: [OAuthClientSummary] = []
    public private(set) var gmailClients: [AccountID: OAuthClientSummary.ID] = [:]
    public private(set) var chosenClients: [AccountID: OAuthClientSummary.ID] = [:]
    public private(set) var clientError: String?
    @ObservationIgnored private var clientTask: Task<Void, Never>?
    @ObservationIgnored private let accountsPort: (any AccountManaging)?

    public var calendarInboxes: [InboxCalendar] { inboxCalendars.filter(\.canConnect) }

    public var showsClientPicker: Bool { clients.count > 1 }

    public func connectClient(_ inbox: InboxCalendar) -> OAuthClientSummary? {
        let key = chosenClients[inbox.id] ?? gmailClients[inbox.id]
        return clients.first { $0.id == key } ?? clients.first(where: \.isDefault)
    }

    public func chooseClient(_ id: OAuthClientSummary.ID, for inbox: InboxCalendar) {
        chosenClients[inbox.id] = id == gmailClients[inbox.id] ? nil : id
    }

    public static func rowStatus(_ inbox: InboxCalendar) -> String {
        if inbox.isBusy { return "Waiting for Google in your browser…" }
        switch inbox.state?.status {
        case .connected?: return inbox.state?.canCreateEvents == true ? "Connected" : "Connected (read only)"
        case .needsReconnect?: return "Needs connecting again"
        case .disconnected?, nil: return "Not connected"
        }
    }

    public static func rowProblem(_ inbox: InboxCalendar) -> String? {
        inbox.errorMessage ?? inbox.state?.problem
            ?? (inbox.needsReconnect ? reconnectRowText : nil)
    }

    public static let reconnectRowText = "Google stopped accepting Mail's calendar access. Click Reconnect to connect again."

    public func clientLine(_ inbox: InboxCalendar) -> String? {
        if inbox.isConnected {
            return inbox.state?.clientShortID.map { "Connected with the Google client ending …\($0)" }
        }
        guard let next = connectClient(inbox) else { return nil }
        let own = next.id == gmailClients[inbox.id] ? " (this inbox's Gmail client)" : ""
        return "Connects with the Google client ending …\(next.shortID)\(own)"
    }

    public static func refreshLine(_ inbox: InboxCalendar, now: Date = Date()) -> String? {
        guard inbox.isConnected else { return nil }
        guard let last = inbox.state?.lastRefreshed else { return "Not read yet since Mail opened" }
        return "Read " + last.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    public func connect(_ inbox: InboxCalendar) async {
        let chosen = chosenClients[inbox.id]
        if await inbox.connect(client: chosen) {
            try? await environment.settings?.set(AppSettings.calendarSetupSkipped(inbox.id), false)
        }
    }

    public func disconnect(_ inbox: InboxCalendar) async { await inbox.disconnect() }

    public func cancel(_ inbox: InboxCalendar) { inbox.cancelConnect() }

    public func importClient(json: Data) async {
        guard let accounts = accountsPort else { return }
        clientError = nil
        do { try await accounts.importOAuthClient(json: json) } catch {
            clientError = (error as? AccountSetupError)?.message ?? "That file couldn't be imported."
        }
        refreshClients()
    }

    public func importFailed() { clientError = "That file couldn't be read." }

    func refreshClients() {
        guard let accounts = accountsPort else { return }
        let ids = inboxCalendars.map(\.id)
        clientTask?.cancel()
        clientTask = Task { [weak self] in
            let known = await accounts.oauthClients()
            var own: [AccountID: OAuthClientSummary.ID] = [:]
            for id in ids {
                if let short = await accounts.oauthClientShortID(for: id),
                   let match = known.first(where: { $0.shortID == short }) {
                    own[id] = match.id
                }
            }
            guard !Task.isCancelled, let self else { return }
            self.clients = known
            self.gmailClients = own
        }
    }

    public static let otherInboxesNote = "Each inbox's calendar is its own Google permission, asked for on its own; "
        + "its email sign-in doesn't change. The calendar sidebar shows the calendar of each conversation's own inbox."

    public var otherInboxes: [InboxCalendar] {
        let own = connection?.account.lowercased()
        return inboxCalendars.filter { $0.canConnect && $0.account.email.lowercased() != own }
    }

    public func setConnected(_ on: Bool, inbox: InboxCalendar) async {
        if on {
            if await inbox.connect() {
                try? await environment.settings?.set(AppSettings.calendarSetupSkipped(inbox.id), false)
            }
        } else {
            await inbox.disconnect()
        }
    }

    public static func status(_ inbox: InboxCalendar) -> String {
        if let error = inbox.errorMessage { return error }
        if inbox.isBusy { return "Waiting for Google in your browser…" }
        switch inbox.state?.status {
        case .connected?: return "Connected."
        case .needsReconnect?: return reconnectText
        case .disconnected?, nil: return "Off."
        }
    }

    private func startInboxes() {
        guard inboxTask == nil, let ports = environment.calendarConnections else { return }
        let data = environment.data
        inboxTask = Task { [weak self] in
            do {
                for try await list in data.accounts() {
                    guard !Task.isCancelled, let self else { return }
                    let shown = list.filter { $0.health != .removing && $0.health != .disabled }
                    let kept = Dictionary(uniqueKeysWithValues: self.inboxCalendars.map { ($0.id, $0) })
                    self.inboxCalendars = shown.map { account in
                        if let existing = kept[account.id] { return existing }
                        let made = InboxCalendar(account: account, port: ports.calendarConnection(for: account))
                        made.start()
                        return made
                    }
                    for gone in kept.values where !shown.contains(where: { $0.id == gone.id }) { gone.stop() }
                    self.refreshClients()
                }
            } catch {
                return
            }
        }
    }

    public var status: String {
        if isConnecting { return pending == true ? "Waiting for Google in your browser…" : "Disconnecting…" }
        if routesByAccount {
            guard canConnect else { return Self.notConnectedTitle + "." }
            switch connection?.status {
            case .connected?:
                guard isRunning else { return "Connected, but the calendar module is off (Settings › Advanced)." }
                return "Connected. Show the sidebar with View › Calendar Sidebar\(sidebarKeyHint)."
            case .needsReconnect?: return Self.reconnectText
            case .disconnected?, nil: return "Off. Mail asks Google for calendar access only when you turn this on."
            }
        }
        if let calendar = environment.calendar {
            switch connection?.status {
            case .disconnected?: return "Disconnected. The calendar sidebar goes away when Mail reopens."
            case .needsReconnect?: return Self.reconnectText
            case .connected?, nil: break
            }
            let name = calendar.info.isSample ? "\(calendar.info.name) (fake data)" : Self.describe(calendar.info)
            guard isRunning else { return "\(name) is connected, but the calendar module is off (Settings › Advanced)." }
            return "Connected: \(name). Show the sidebar with View › Calendar Sidebar\(sidebarKeyHint)."
        }
        guard canConnect else { return Self.notConnectedTitle + "." }
        switch connection?.status {
        case .connected?: return "Connected. Quit and reopen Mail to show the calendar sidebar."
        case .needsReconnect?: return Self.reconnectText
        case .disconnected?, nil: return "Off. Mail asks Google for calendar access only when you turn this on."
        }
    }

    private var sidebarKeyHint: String {
        environment.actions.descriptor(.calendarToggleSidebar)?.shortcutHint.map { ", or press the \($0) key" } ?? ""
    }

    public static let needsConnectedText = "Needs a connected calendar."

    public var connectedCalendars: [InboxCalendar] { calendarInboxes.filter(\.isConnected) }

    public var createConnectOffers: [InboxCalendar] {
        routesByAccount ? calendarInboxes.filter { !$0.isConnected } : []
    }

    public static func connectTitle(_ inbox: InboxCalendar) -> String {
        inbox.needsReconnect ? "Reconnect calendar for \(inbox.account.email)" : "Connect calendar for \(inbox.account.email)"
    }

    public var createStatus: String {
        if routesByAccount { return accountsCreateStatus }
        if let refusal = environment.calendar?.info.createRefusal { return refusal }
        if connection?.status == .connected, connection?.canCreateEvents == false {
            return "Reconnect Google Calendar to create events: turn Connect Google Calendar off and on again."
        }
        return isConfigured ? "Events can be created from the sidebar's draft, with undo." : Self.needsConnectedText
    }

    private var accountsCreateStatus: String {
        let connected = connectedCalendars
        guard !connected.isEmpty else { return Self.needsConnectedText }
        let writable = connected.filter { $0.state?.canCreateEvents == true }.map(\.account.email)
        let viewOnly = connected.filter { $0.state?.canCreateEvents != true }.map(\.account.email)
        var text = writable.isEmpty ? "" : "Events can be created from the sidebar's draft, with undo, on "
            + Self.list(writable) + "'s calendar."
        if !viewOnly.isEmpty {
            text += (text.isEmpty ? "" : " ") + "Reconnect Google Calendar to create events on " + Self.list(viewOnly)
                + "'s calendar: disconnect it and connect it again."
        }
        return text
    }

    static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    public var canCreateEvents: Bool {
        if routesByAccount { return connectedCalendars.contains { $0.state?.canCreateEvents == true } }
        return isConfigured && environment.calendar?.info.createRefusal == nil
    }

    public func setSecondTimeZone(_ identifier: String?) async { await secondTimeZone.set(identifier) }

    public func zoneChoices(now: Date = Date()) -> [ZoneChoice] {
        var ids = TimeZone.knownTimeZoneIdentifiers.sorted()
        if let stored = secondTimeZone.value, !ids.contains(stored) { ids.insert(stored, at: 0) }
        return [ZoneChoice(identifier: nil, title: "None")] + ids.map { id in
            ZoneChoice(identifier: id, title: Self.title(id, now: now))
        }
    }

    static func title(_ identifier: String, now: Date) -> String {
        guard let zone = TimeZone(identifier: identifier) else { return identifier }
        let seconds = zone.secondsFromGMT(for: now)
        let sign = seconds < 0 ? "-" : "+"
        let hours = abs(seconds) / 3600, minutes = abs(seconds) % 3600 / 60
        let offset = seconds == 0 ? "GMT" : minutes == 0 ? "GMT\(sign)\(hours)" : String(format: "GMT%@%d:%02d", sign, hours, minutes)
        return "\(identifier.replacingOccurrences(of: "_", with: " ")) — \(offset)"
    }

    static func describe(_ info: CalendarProviderInfo) -> String {
        info.account.map { "\(info.name) (\($0))" } ?? info.name
    }
}
