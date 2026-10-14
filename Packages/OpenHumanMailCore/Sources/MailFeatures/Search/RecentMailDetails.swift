import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class RecentMailDetails {
    public private(set) var details: [String: String] = [:]
    public private(set) var lookups = 0

    @ObservationIgnored public var delay: Duration = .milliseconds(80)
    @ObservationIgnored public var lookup: (@Sendable (String) async -> ThreadRow?)?
    @ObservationIgnored public var now: @Sendable () -> Date = { Date() }
    @ObservationIgnored public var locale: Locale = .autoupdatingCurrent
    @ObservationIgnored public var timeZone: TimeZone = .autoupdatingCurrent
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var highlighted: String?

    public init(lookup: (@Sendable (String) async -> ThreadRow?)? = nil) {
        self.lookup = lookup
    }

    isolated deinit { task?.cancel() }

    public func detail(for email: String) -> String? {
        guard let line = details[email.lowercased()], !line.isEmpty else { return nil }
        return line
    }

    public func highlight(_ email: String?) {
        let key = email?.lowercased()
        guard key != highlighted else { return }
        highlighted = key
        task?.cancel()
        task = nil
        guard let key, details[key] == nil, let lookup else { return }
        let delay = self.delay
        task = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled, let self else { return }
            self.lookups += 1
            let row = await lookup(key)
            guard !Task.isCancelled else { return }
            self.details[key] = row.map(self.line) ?? ""
        }
    }

    public func reset() {
        task?.cancel()
        task = nil
        highlighted = nil
        details = [:]
    }

    public func line(_ row: ThreadRow) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var style = Date.FormatStyle(date: .omitted, time: .omitted, locale: locale, calendar: calendar, timeZone: timeZone)
            .month(.abbreviated).day()
        if calendar.component(.year, from: row.lastMessageAt) != calendar.component(.year, from: now()) {
            style = style.year()
        }
        let subject = row.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Last: \(subject.isEmpty ? "(no subject)" : subject) · \(row.lastMessageAt.formatted(style))"
    }
}

extension ComposeManager {
    public func recentMailLookup(for session: ComposeSession) -> (@Sendable (String) async -> ThreadRow?)? {
        guard environment.modules.modules.contains(.smartSearch) else { return nil }
        let data = environment.data
        let account = session.account.id
        return { email in try? await data.recentThreads(involving: email, account: account, limit: 1).first }
    }
}
