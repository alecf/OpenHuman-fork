import Foundation
import MailModel
import Observation
import OpenHumanCore

@MainActor @Observable
public final class InboxCalendar: Identifiable {
    public let account: Account
    public nonisolated var id: AccountID { account.id }
    public private(set) var state: CalendarConnectionState?
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?
    public var canConnect: Bool { port != nil }
    public var isConnected: Bool { state?.status == .connected }
    public var needsReconnect: Bool { state?.status == .needsReconnect }

    @ObservationIgnored private let port: (any CalendarConnecting)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, any Error>?

    public init(account: Account, port: (any CalendarConnecting)?) {
        self.account = account
        self.port = port
    }

    isolated deinit {
        task?.cancel()
    }

    public func start() {
        guard task == nil, let port else { return }
        task = Task { [weak self] in
            for await next in port.connectionStates() {
                guard !Task.isCancelled, let self else { return }
                self.state = next
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    @discardableResult
    public func connect(client: OAuthClientSummary.ID? = nil) async -> Bool {
        guard let port, !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        let attempt = Task { try await port.connect(client: client) }
        connectTask = attempt
        defer {
            isBusy = false
            connectTask = nil
        }
        do {
            try await attempt.value
            if state?.status != .connected {
                state = CalendarConnectionState(status: .connected, account: state?.account ?? account.email,
                                                canCreateEvents: state?.canCreateEvents ?? false,
                                                needsRestart: state?.needsRestart ?? false)
            }
            return true
        } catch is CancellationError {
            errorMessage = Self.cancelled
            return false
        } catch {
            errorMessage = (error as? CalendarError)?.description ?? Self.genericError
            return false
        }
    }

    public func cancelConnect() {
        connectTask?.cancel()
    }

    static let cancelled = "Connecting was cancelled. Nothing was stored."

    public func disconnect() async {
        guard let port, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await port.disconnect()
            state?.status = .disconnected
            state?.canCreateEvents = false
        } catch {
            errorMessage = (error as? CalendarError)?.description ?? Self.genericError
        }
    }

    static let genericError = "Connecting didn't work. Nothing was stored. Try again."
}

public struct InboxRow: Identifiable, Hashable, Sendable {
    public enum EmailStatus: Sendable, Hashable { case connected, needsSignIn }
    public enum CalendarStatus: Sendable, Hashable {
        case connected
        case skipped
        case notConnected
        case needsReconnect
        case unavailable
    }

    public let account: Account
    public let email: EmailStatus
    public let calendar: CalendarStatus
    public let syncLine: String?
    public var id: AccountID { account.id }

    public init(account: Account, email: EmailStatus, calendar: CalendarStatus, syncLine: String? = nil) {
        self.account = account
        self.email = email
        self.calendar = calendar
        self.syncLine = syncLine
    }

    public var emailText: String {
        switch email {
        case .connected: "Email connected"
        case .needsSignIn: "Email needs you to sign in again"
        }
    }

    public var calendarText: String {
        switch calendar {
        case .connected: "Calendar connected"
        case .skipped: "Calendar skipped for now"
        case .notConnected: "Calendar not connected yet"
        case .needsReconnect: "Calendar needs connecting again"
        case .unavailable: "Calendar connects only on a real Google account"
        }
    }

    public var calendarCanBeFixed: Bool {
        switch calendar {
        case .skipped, .notConnected, .needsReconnect: true
        case .connected, .unavailable: false
        }
    }

    public var isComplete: Bool { email == .connected && (calendar == .connected || calendar == .unavailable) }

    public var accessibilityLabel: String { "\(account.email): \(emailText), \(calendarText)" }
}
