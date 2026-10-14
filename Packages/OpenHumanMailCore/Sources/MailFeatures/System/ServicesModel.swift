import Foundation
import MailModel
import Observation
import OpenHumanCore
import OpenHumanLinks

@MainActor
public final class ServicesModel {
    public static let offText = "Mail's Services menu items are off. Turn them on in Settings › Platform features."
    public static let noTextText = "There was no text to use."
    public static let cutText = "Only the first 32 KB of the selection was used."
    public static let foldersText = "Folders and packages can't be attached."
    public static let unreadableText = "Mail couldn't read some of the selected files."
    public static let noFilesText = "There were no files to attach."
    public static let tooManyFilesText = "Mail attaches at most \(ServiceInput.maxFiles) files at a time. Select fewer files."
    public static let rateLimitedText = "Too many Services requests at once. Mail ignored the extra ones."

    public let limits: DeepLinkRouter.Limits
    public private(set) var isRegistered = false

    private unowned let environment: AppEnvironment
    private let registrar: any ServicesRegistering
    private let preferences: SystemPreferences
    private let showMainWindow: @MainActor () -> Void
    private let now: @MainActor () -> Date
    private var received: [Date] = []
    private var announcedLimit = false
    private var queue: [ServiceRequest] = []
    private var waiting = false
    private let log = Log(.app)

    public init(environment: AppEnvironment, registrar: any ServicesRegistering, preferences: SystemPreferences,
                limits: DeepLinkRouter.Limits = DeepLinkRouter.Limits(), showMainWindow: @escaping @MainActor () -> Void,
                now: @escaping @MainActor () -> Date = { Date() }) {
        self.environment = environment
        self.registrar = registrar
        self.preferences = preferences
        self.limits = limits
        self.showMainWindow = showMainWindow
        self.now = now
    }

    isolated deinit {
        if isRegistered { registrar.unregister() }
    }

    public var queuedCount: Int { queue.count }

    public func start() {
        guard !isRegistered else { return }
        isRegistered = true
        registrar.register { [weak self] request in self?.receive(request) }
    }

    public func stop() {
        guard isRegistered else { return }
        isRegistered = false
        queue = []
        registrar.unregister()
    }

    public func receive(_ request: ServiceRequest) {
        let at = now()
        received.removeAll { at.timeIntervalSince($0) >= limits.window }
        guard received.count < limits.maxLinks else {
            if !announcedLimit {
                announcedLimit = true
                post(Self.rateLimitedText)
            }
            log.info("services: \(request.name) dropped (rate limit)")
            return
        }
        received.append(at)
        announcedLimit = false
        guard preferences.servicesEnabled else {
            showMainWindow()
            post(Self.offText)
            log.info("services: \(request.name) refused (switched off)")
            return
        }
        guard environment.router.accountsLoaded else {
            guard queue.count < limits.maxQueued else {
                log.info("services: \(request.name) dropped (queue full)")
                return
            }
            queue.append(request)
            log.info("services: \(request.name) held until the window is ready")
            watchReadiness()
            return
        }
        perform(request)
    }

    public func readinessChanged() {
        guard !queue.isEmpty else { return }
        guard environment.router.accountsLoaded else {
            watchReadiness()
            return
        }
        let held = queue
        queue = []
        for request in held { perform(request) }
    }

    private func perform(_ request: ServiceRequest) {
        switch request {
        case .newMessage(let raw):
            guard let body = ServiceInput.body(raw) else {
                showMainWindow()
                post(Self.noTextText)
                log.info("services: newMessage refused (no text)")
                return
            }
            showMainWindow()
            let outcome = environment.router.route(Self.newMessageLink(body.text))
            finish(request, outcome)
            if outcome.handled, body.wasCut { post(Self.cutText) }
        case .search(let raw):
            showMainWindow()
            guard let query = ServiceInput.searchQuery(raw) else {
                post(Self.noTextText)
                log.info("services: search refused (no text)")
                return
            }
            finish(request, environment.router.route(Self.searchLink(query)))
        case .attachFiles(let urls):
            showMainWindow()
            attach(urls)
        }
    }

    public nonisolated static func newMessageLink(_ body: String) -> MailLink {
        .compose(ComposePrefill(body: body))
    }

    public nonisolated static func searchLink(_ query: String) -> MailLink {
        .search(query: query, account: nil)
    }

    private func attach(_ urls: [URL]) {
        guard urls.count <= ServiceInput.maxFiles * 10 else {
            post(Self.tooManyFilesText)
            log.info("services: attachFiles refused (too many)")
            return
        }
        let selection = ServiceInput.files(urls)
        guard selection.files.count <= ServiceInput.maxFiles else {
            post(Self.tooManyFilesText)
            log.info("services: attachFiles refused (too many)")
            return
        }
        guard !selection.files.isEmpty else {
            post(selection.foldersSkipped > 0 ? Self.foldersText : Self.noFilesText)
            log.info("services: attachFiles refused (no regular files)")
            return
        }
        guard let session = environment.compose.openNew(placement: .modal) else {
            log.info("services: attachFiles refused (no account)")
            return
        }
        session.attach(selection.files, countsAsEdit: false)
        if selection.foldersSkipped > 0 { post(Self.foldersText) }
        if selection.unreadableSkipped > 0 { post(Self.unreadableText) }
        log.info("services: attachFiles opened a composer (\(selection.files.count) files)")
    }

    private func finish(_ request: ServiceRequest, _ outcome: LinkOutcome) {
        if outcome.handled {
            log.info("services: \(request.name) handled")
        } else {
            post(outcome.message)
            log.info("services: \(request.name) not handled")
        }
    }

    private func post(_ message: String) {
        environment.notices.post(message, style: .info, duration: NoticeCenter.infoDuration)
    }

    private func watchReadiness() {
        guard !waiting else { return }
        waiting = true
        let router = environment.router
        withObservationTracking {
            _ = router.accountsLoaded
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.waiting = false
                self.readinessChanged()
            }
        }
    }
}
