import Foundation
import Observation
import OpenHumanCore
import OpenHumanLinks

@MainActor
public final class DeepLinkRouter {
    public struct Limits: Sendable {
        public var maxLinks: Int
        public var window: TimeInterval
        public var maxQueued: Int

        public init(maxLinks: Int = 5, window: TimeInterval = 10, maxQueued: Int = 10) {
            self.maxLinks = maxLinks
            self.window = window
            self.maxQueued = maxQueued
        }
    }

    public enum Result: Equatable, Sendable {
        case followed(LinkOutcome)
        case queued
        case dropped
        case invalid
    }

    public static let invalidText = "Mail can't open that link."
    public static let rateLimitedText = "Too many links at once. Mail ignored the extra ones."

    public let limits: Limits
    public var didFollow: (@MainActor (LinkOutcome) -> Void)?

    private let routerProvider: @MainActor () -> AppRouter?
    private var received: [Date] = []
    private var announcedLimit = false
    private var queue: [MailLink] = []
    private var waiting = false
    private let log = Log(.links)

    public init(limits: Limits = Limits(), router: @escaping @MainActor () -> AppRouter?) {
        self.limits = limits
        self.routerProvider = router
    }

    public var queuedCount: Int { queue.count }

    @discardableResult
    public func handle(_ url: URL, receivedAt: Date = Date()) -> Result {
        let parsed = MailLinkParser.parse(url)
        received.removeAll { receivedAt.timeIntervalSince($0) >= limits.window }
        let overLimit = received.count >= limits.maxLinks
        if !overLimit { received.append(receivedAt) }
        if overLimit {
            if !announcedLimit {
                announcedLimit = true
                routerProvider()?.environment.notices.post(Self.rateLimitedText, style: .info,
                                                           duration: NoticeCenter.infoDuration)
            }
            log.info("link dropped (rate limit)")
            return .dropped
        }
        announcedLimit = false
        guard case .success(let link) = parsed else {
            log.info("link rejected (\(Self.failure(parsed)))")
            routerProvider()?.environment.notices.post(Self.invalidText, style: .info, duration: NoticeCenter.infoDuration)
            return .invalid
        }
        guard let router = readyRouter() else {
            guard queue.count < limits.maxQueued else {
                log.info("link dropped (queue full)")
                return .dropped
            }
            queue.append(link)
            log.info("link queued: \(Self.name(link))")
            watchReadiness()
            return .queued
        }
        return .followed(follow(link, with: router))
    }

    public func readinessChanged() {
        guard !queue.isEmpty, let router = readyRouter() else {
            if !queue.isEmpty { watchReadiness() }
            return
        }
        let held = queue
        queue = []
        for link in held { follow(link, with: router) }
    }

    private func readyRouter() -> AppRouter? {
        guard let router = routerProvider(), router.accountsLoaded else { return nil }
        return router
    }

    @discardableResult
    private func follow(_ link: MailLink, with router: AppRouter) -> LinkOutcome {
        log.info("link followed: \(Self.name(link))")
        let outcome = router.route(link)
        if outcome.handled {
            didFollow?(outcome)
        } else {
            router.environment.notices.post(outcome.message, style: .info, duration: NoticeCenter.infoDuration)
        }
        return outcome
    }

    private func watchReadiness() {
        guard !waiting, let router = routerProvider() else { return }
        waiting = true
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

    private static func failure(_ result: Swift.Result<MailLink, MailLinkError>) -> String {
        if case .failure(let error) = result { return "\(error)" }
        return "ok"
    }

    static func name(_ link: MailLink) -> String {
        switch link {
        case .thread: "thread"
        case .draft: "draft"
        case .review: "review"
        case .search: "search"
        case .compose: "compose"
        case .settings: "settings"
        }
    }
}
