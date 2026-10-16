import Foundation
import MailModel
import MailRender
import Observation
import OpenHumanCore
import OpenHumanLinks

@MainActor
public protocol DevFeedbackHost: AnyObject {
    var appInfo: DevFeedbackSnapshot.AppInfo { get }
    var screenName: String { get }
    var theme: DevFeedbackSnapshot.ThemeInfo? { get }
    var extraDenylist: [String] { get }
    func accountCounters() async -> [DevFeedbackSnapshot.AccountInfo]
    func captureScreenshot() -> Data?
    func showMainWindow()
    func keychainDiagnostics() async -> DevFeedbackSnapshot.KeychainInfo?
}

extension DevFeedbackHost {
    public func keychainDiagnostics() async -> DevFeedbackSnapshot.KeychainInfo? { nil }
}

@MainActor
@Observable
public final class DevFeedbackCenter {
    public let availability: DevFeedbackAvailability
    public let settings: DevFeedbackSettings
    public let paths: DevFeedbackPaths
    public let checklist: DevChecklistModel
    public let history: DevFeedbackHistory
    @ObservationIgnored public let logs: DevFeedbackLogBuffer

    public var feedback: DevFeedbackModel?
    public var isFeedbackSheetPresented: Bool {
        get { feedback != nil }
        set { if !newValue { feedback = nil } }
    }

    @ObservationIgnored public var host: (any DevFeedbackHost)?
    @ObservationIgnored public weak var window: MailWindowModel?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let timeZone: TimeZone
    @ObservationIgnored private let bundledChecklist: URL?

    public static let maxRecentErrors = 20

    public init(availability: DevFeedbackAvailability, settings: DevFeedbackSettings, paths: DevFeedbackPaths,
                bundledChecklist: URL?, logs: DevFeedbackLogBuffer = DevFeedbackLogBuffer(),
                now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.availability = availability
        self.settings = settings
        self.paths = paths
        self.bundledChecklist = bundledChecklist
        self.logs = logs
        self.now = now
        self.timeZone = timeZone
        self.history = DevFeedbackHistory(now: now)
        let list = DevChecklistLoader.load(bundled: bundledChecklist, override: paths.checklistOverride)
        self.checklist = DevChecklistModel(checklist: list, store: DevChecklistAnswerStore(url: paths.answers), now: now)
        checklist.linkHandler = { [weak self] link in self?.follow(link) ?? "No mail window is open." }
    }

    public var isEnabled: Bool { availability.isAvailable && settings.isEnabled }

    public func reloadChecklist() {
        checklist.reload(DevChecklistLoader.load(bundled: bundledChecklist, override: paths.checklistOverride))
    }

    @discardableResult
    public func beginFeedback() -> DevFeedbackModel {
        if let open = feedback, open.state != .saving, !open.isSaved {
            host?.showMainWindow()
            return open
        }
        history.record("menu:dev.giveFeedback")
        let content = threadContent()
        let model = DevFeedbackModel(center: self, threadContent: content, screenshot: host?.captureScreenshot(),
                                     denylist: denylist() + (content.map { [$0.subject, $0.sender] } ?? []))
        model.captureSnapshot { [weak self] in await self?.snapshot() }
        host?.showMainWindow()
        feedback = model
        return model
    }

    var currentDate: Date { now() }

    public var isChecklistOpen = false
    @ObservationIgnored private var reopenChecklist = false

    public var panelsPlace: PanelsPlace {
        PanelsPlace(checklistOpen: isChecklistOpen, checklistItemID: checklist.viewingItemID, feedbackOpen: feedback != nil,
                    feedbackText: feedback?.text ?? "")
    }

    public func adopt(_ router: AppRouter) {
        router.panelsSource = { [weak self] in self?.panelsPlace ?? PanelsPlace() }
        guard isEnabled, let place = router.restoredPanels, panelsAdopted == false else { return }
        panelsAdopted = true
        if let id = place.checklistItemID, checklist.items.contains(where: { $0.id == id }) { checklist.viewingItemID = id }
        reopenChecklist = place.checklistOpen
        if place.feedbackOpen {
            beginFeedback().text = place.feedbackText
        }
    }

    @ObservationIgnored private var panelsAdopted = false

    public func takeChecklistReopen() -> Bool {
        defer { reopenChecklist = false }
        return reopenChecklist
    }

    public func follow(_ link: MailLink) -> String {
        history.record("link:\(Self.linkKind(link))")
        guard let window else { return "No mail window is open." }
        let outcome = window.route(link)
        if outcome.handled { host?.showMainWindow() }
        return outcome.message
    }

    static func linkKind(_ link: MailLink) -> String {
        switch link {
        case .thread: "thread"
        case .draft: "draft"
        case .review: "review"
        case .search: "search"
        case .compose: "compose"
        case .settings: "settings"
        }
    }

    public func snapshot() async -> DevFeedbackSnapshot {
        let date = now()
        let scrubber = DevFeedbackRedactor(denylist: denylist())
        var screen = host?.screenName ?? (window == nil ? "unknown" : "mail")
        var route = screen
        var list: DevFeedbackSnapshot.ListInfo?
        var reader: DevFeedbackSnapshot.ReaderInfo?
        var status: DevFeedbackSnapshot.StatusInfo?
        var errors: [DevFeedbackSnapshot.ErrorEntry] = []
        var connectivity: [AccountID: ConnectivityState] = [:]
        if let window, screen.hasPrefix("mail") {
            screen = "mail"
            route = "mail/\(window.mode == .reader ? "reader" : "list")/\(Self.locationName(window.location))"
            list = Self.listInfo(window.list)
            reader = Self.readerInfo(window.reader)
            let model = window.environment.status
            connectivity = model.connectivity
            status = DevFeedbackSnapshot.StatusInfo(syncText: model.syncText(now: date))
            if let error = window.accountsError { errors.append(.init(at: nil, source: "accounts", message: scrubber.scrub(error))) }
            if case .failed(let reason) = window.list?.state { errors.append(.init(at: nil, source: "list", message: scrubber.scrub(reason))) }
            if case .failed(let reason) = window.reader?.state { errors.append(.init(at: nil, source: "reader", message: scrubber.scrub(reason))) }
            for message in window.reader?.messages ?? [] {
                if case .failed(let reason) = message.body {
                    errors.append(.init(at: nil, source: "body \(message.id.gmailMessageID.rawValue)", message: scrubber.scrub(reason)))
                }
            }
        }

        var accounts = await host?.accountCounters() ?? []
        if accounts.isEmpty, let account = window?.account {
            accounts = [DevFeedbackSnapshot.AccountInfo(index: 1, idHash: DevFeedbackHash.account(account.email),
                                                        health: Self.caseName(account.health))]
        }
        let states = connectivity.sorted { $0.key < $1.key }.map(\.value)
        for (i, state) in states.enumerated() where i < accounts.count && accounts[i].connectivity == nil {
            accounts[i].connectivity = Self.describe(state)
        }

        let logErrors = logs.lines(now: date).filter { $0.level == "error" }.suffix(Self.maxRecentErrors)
        errors += logErrors.map { .init(at: $0.at, source: "log.\($0.category)", message: scrubber.scrub($0.message)) }

        var calendars: [DiagnosticsCalendarEntry]?
        if let environment = window?.environment, environment.calendarConnections != nil {
            calendars = await environment.calendarDiagnostics(now: date).map { $0.sanitized(DiagnosticsExporter.code) }
        }

        var snapshot = DevFeedbackSnapshot(
            capturedAtUTC: DevFeedbackSnapshot.utcString(date),
            capturedAtLocal: DevFeedbackSnapshot.localString(date, timeZone: timeZone),
            timeZone: timeZone.identifier,
            app: host?.appInfo ?? DevFeedbackSnapshot.AppInfo(version: "unknown", build: "unknown", gitCommit: "unknown",
                                                               configuration: "unknown", dataMode: "unknown",
                                                               devFeedbackEnabledBy: availability.rawValue, os: "unknown"),
            screen: screen, route: route, status: status,
            accountCount: accounts.count, accounts: accounts, list: list, reader: reader, theme: host?.theme,
            recentCommands: history.commands, checklistViewing: checklist.viewingItemID,
            recentErrors: Array(errors.suffix(Self.maxRecentErrors)))
        snapshot.calendars = calendars
        snapshot.keychain = await host?.keychainDiagnostics()
        return snapshot
    }

    public func denylist() -> [String] {
        var strings: [String] = host?.extraDenylist ?? []
        if let window {
            if let account = window.account { strings += [account.email, account.displayName ?? "", account.alias ?? ""] }
            for row in (window.list?.rows ?? []).prefix(500) {
                strings += [row.subject, row.snippet, row.participantsDisplay]
                strings += row.participants.flatMap { [$0.name ?? "", $0.email] }
            }
            if let reader = window.reader {
                strings.append(reader.subject)
                for message in reader.messages {
                    let summary = message.summary
                    let people = [summary.from].compactMap { $0 } + summary.to + summary.cc + summary.bcc
                    strings += people.flatMap { [$0.name ?? "", $0.email] }
                    strings.append(summary.snippet)
                    strings += summary.attachments.map(\.filename)
                    if case .rendered(.plain(let document)) = message.body { strings += Self.lines(of: document) }
                }
            }
        }
        return strings
    }

    func threadContent() -> DevFeedbackBundle.ThreadContent? {
        guard let window, window.mode == .reader, let reader = window.reader else { return nil }
        let sender = reader.messages.last?.summary.from.map { address in
            address.name.map { "\($0) <\(address.email)>" } ?? address.email
        } ?? ""
        return DevFeedbackBundle.ThreadContent(threadID: reader.thread.gmailThreadID.rawValue, subject: reader.subject,
                                               sender: sender)
    }

    static func locationName(_ location: MailLocation) -> String {
        switch location {
        case .system(let folder): folder.rawValue
        case .split(let id): "split-\(id.rawValue)"
        case .splitOther: "splitOther"
        case .label(let id): "label-\(id.rawValue)"
        case .reviewQueue: "reviewQueue"
        case .search: "search"
        }
    }

    static func listInfo(_ list: ThreadListModel?) -> DevFeedbackSnapshot.ListInfo? {
        guard let list else { return nil }
        let state: String = switch list.state {
        case .loading: "loading"
        case .loaded: "loaded"
        case .failed: "failed"
        }
        return DevFeedbackSnapshot.ListInfo(
            location: locationName(list.location), state: state, rows: list.rows.count, totalCount: list.totalCount,
            hasMore: list.hasMore, unreadRows: list.rows.filter(\.isUnread).count,
            loadedMessages: list.rows.reduce(0) { $0 + $1.messageCount }, cursorIndex: list.cursorIndex,
            cursorThreadID: list.cursor?.gmailThreadID.rawValue)
    }

    static func readerInfo(_ reader: ReaderModel?) -> DevFeedbackSnapshot.ReaderInfo? {
        guard let reader else { return nil }
        let state: String = switch reader.state {
        case .loading: "loading"
        case .loaded: "loaded"
        case .missing: "missing"
        case .failed: "failed"
        }
        let messages = reader.messages.map { message -> DevFeedbackSnapshot.ReaderMessage in
            var entry = DevFeedbackSnapshot.ReaderMessage(
                messageID: message.id.gmailMessageID.rawValue, isExpanded: message.isExpanded,
                isUnread: message.summary.isUnread, body: "notLoaded")
            switch message.body {
            case .notLoaded: entry.body = "notLoaded"
            case .fetching: entry.body = "fetching"
            case .failed: entry.body = "failed"
            case .rendered(.empty): entry.body = "empty"
            case .rendered(.plain): entry.body = "plainText"
            case .rendered(.html(let rendered)):
                entry.body = "html"
                entry.hasRemoteContent = rendered.hasRemoteContent
                entry.blockedRemote = rendered.blockedCount
                entry.trackers = rendered.trackerCount
                entry.renderHash = String(rendered.contentHash, radix: 16)
            }
            return entry
        }
        let kinds = Set(messages.map(\.body).filter { $0 == "html" || $0 == "plainText" })
        let mode = kinds.isEmpty ? "none" : (kinds.count > 1 ? "mixed" : (kinds.first ?? "none"))
        return DevFeedbackSnapshot.ReaderInfo(
            threadID: reader.thread.gmailThreadID.rawValue, threadRowID: reader.thread.rowID, state: state,
            messageCount: reader.messages.count, expandedCount: reader.messages.filter(\.isExpanded).count,
            focusedMessageID: reader.messages.last?.id.gmailMessageID.rawValue, mode: mode, imagePolicy: "blockRemote",
            messages: messages)
    }

    static func describe(_ state: ConnectivityState) -> String {
        switch state {
        case .online(let syncing, let last): "online(syncing: \(syncing), lastSync: \(last.map(DevFeedbackSnapshot.utcString) ?? "never"))"
        case .offline: "offline"
        case .rateLimited: "rateLimited"
        case .syncFailing(let code, let failures, _): "syncFailing(\(DevFeedbackRedactor().scrub(code)), failures: \(failures))"
        case .needsReauth: "needsReauth"
        }
    }

    public nonisolated static func caseName(_ value: Any) -> String {
        let text = String(describing: value)
        return String(text.prefix { $0 != "(" }).components(separatedBy: ".").last ?? text
    }

    static func lines(of document: PlainTextDocument) -> [String] {
        document.blocks.flatMap { block -> [String] in
            switch block {
            case .body(let text), .quote(let text, _), .signature(let text): text.components(separatedBy: "\n")
            }
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0.count >= 8 }
    }
}
