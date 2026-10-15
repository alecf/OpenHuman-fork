import Foundation
import MailActions
import MailModel

public struct DiagnosticsAppInfo: Sendable, Hashable, Codable {
    public var version: String
    public var build: String
    public var gitCommit: String
    public var os: String
    public var dataMode: String

    public init(version: String, build: String, gitCommit: String, os: String, dataMode: String) {
        self.version = version
        self.build = build
        self.gitCommit = gitCommit
        self.os = os
        self.dataMode = dataMode
    }
}

public struct DiagnosticsCalendarEntry: Sendable, Codable, Hashable {
    public var index: Int
    public var status: String
    public var canCreateEvents: Bool
    public var lastReadAt: Date?
    public var hasProblem: Bool
    public var scopes: [String]?
    public var lastFetchAt: Date?
    public var lastFetchAgeSeconds: Int?
    public var lastError: String?

    public init(index: Int, status: String, canCreateEvents: Bool = false, lastReadAt: Date? = nil,
                hasProblem: Bool = false, scopes: [String]? = nil, lastFetchAt: Date? = nil,
                lastFetchAgeSeconds: Int? = nil, lastError: String? = nil) {
        self.index = index
        self.status = status
        self.canCreateEvents = canCreateEvents
        self.lastReadAt = lastReadAt
        self.hasProblem = hasProblem
        self.scopes = scopes
        self.lastFetchAt = lastFetchAt
        self.lastFetchAgeSeconds = lastFetchAgeSeconds
        self.lastError = lastError
    }

    public init(index: Int, state: CalendarConnectionState?, now: Date? = nil) {
        let status: String
        switch state?.status {
        case .connected?: status = "connected"
        case .disconnected?: status = "disconnected"
        case .needsReconnect?: status = "needsReconnect"
        case nil: status = "unavailable"
        }
        let fetched = state?.lastFetch
        var age: Int?
        if let fetched, let now { age = max(0, Int(now.timeIntervalSince(fetched).rounded())) }
        self.init(index: index, status: status, canCreateEvents: state?.canCreateEvents ?? false,
                  lastReadAt: state?.lastRefreshed, hasProblem: state?.problem != nil,
                  scopes: state.map { $0.scopes.map(CalendarConnectionState.scopeName) }, lastFetchAt: fetched,
                  lastFetchAgeSeconds: age, lastError: state?.lastFetchError)
    }

    func sanitized(_ code: (String) -> String) -> DiagnosticsCalendarEntry {
        var e = self
        e.status = code(status)
        e.scopes = scopes?.map(code)
        e.lastError = lastError.map(code)
        return e
    }
}

struct DiagnosticsDocument: Codable {
    var generatedAt: Date
    var app: DiagnosticsAppInfo
    var modules: [String: Bool]
    var snapshot: DiagnosticsSnapshot
    var calendars: [DiagnosticsCalendarEntry] = []
}

@MainActor
public final class DiagnosticsExporter {
    public enum Failure: Error, Equatable { case unavailable, writeFailed }

    private let data: any MailDataSource
    private let info: @Sendable () -> DiagnosticsAppInfo
    private let modules: @MainActor () -> [String: Bool]
    private let logLines: @MainActor () -> [String]
    private let now: @Sendable () -> Date
    private let calendars: @MainActor () async -> [DiagnosticsCalendarEntry]

    public init(data: any MailDataSource, info: @escaping @Sendable () -> DiagnosticsAppInfo,
                modules: @escaping @MainActor () -> [String: Bool], logLines: @escaping @MainActor () -> [String] = { [] },
                now: @escaping @Sendable () -> Date = { Date() },
                calendars: @escaping @MainActor () async -> [DiagnosticsCalendarEntry] = { [] }) {
        self.data = data
        self.info = info
        self.modules = modules
        self.logLines = logLines
        self.now = now
        self.calendars = calendars
    }

    public func suggestedFileName() -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now())
        return String(format: "Mail-Diagnostics-%04d%02d%02d-%02d%02d%02d.zip", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    public func build() async throws -> Data {
        let snapshot: DiagnosticsSnapshot
        do { snapshot = try await data.diagnosticsSnapshot() } catch { throw Failure.unavailable }
        let generated = now()
        let calendarEntries = await calendars().map { $0.sanitized(Self.code) }
        let document = DiagnosticsDocument(generatedAt: generated, app: info(), modules: modules(),
                                           snapshot: Self.sanitized(snapshot), calendars: calendarEntries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let redactor = DevFeedbackRedactor()
        let log = logLines().map { redactor.scrub($0) }.joined(separator: "\n")
        var zip = ZipArchive()
        zip.add(name: "README.txt", text: Self.readme, modified: generated)
        zip.add(name: "diagnostics.json", data: try encoder.encode(document), modified: generated)
        zip.add(name: "log.txt", text: log.isEmpty ? "(no log lines in this build)\n" : log + "\n", modified: generated)
        return zip.data()
    }

    public func export(to url: URL) async throws {
        let bytes = try await build()
        do { try bytes.write(to: url, options: .atomic) } catch { throw Failure.writeFailed }
    }

    static let readme = """
        OpenHuman Mail diagnostics
        Contains no email content: no subjects, snippets, message text, addresses, label names or attachment names.
        Accounts are numbered. diagnostics.json has versions, module switches, sync status and counts, and
        error codes, and each numbered account's calendar connection state; log.txt is the app's recent log with
        anything that could be content removed.
        """

    static func sanitized(_ snapshot: DiagnosticsSnapshot) -> DiagnosticsSnapshot {
        var copy = snapshot
        copy.accounts = snapshot.accounts.map { entry in
            var e = entry
            e.health = code(entry.health)
            e.connectivity = code(entry.connectivity)
            return e
        }
        copy.operations = snapshot.operations.map { DiagnosticsSnapshot.OperationTally(kind: code($0.kind), status: code($0.status), count: $0.count) }
        copy.recentErrors = snapshot.recentErrors.map { DiagnosticsSnapshot.ErrorTally(code: code($0.code), count: $0.count, lastAt: $0.lastAt) }
        return copy
    }

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.()-|:")

    static func code(_ value: String) -> String {
        guard value.count <= 64, value.unicodeScalars.allSatisfy(allowed.contains) else { return "<redacted>" }
        return value
    }
}
