import Foundation
import MailModel
import Observation

public enum PermissionID: String, Sendable, Hashable, CaseIterable {
    case gmail, notifications, openAtLogin, onDeviceAI
}

public struct PermissionInfo: Sendable, Hashable, Identifiable {
    public let id: PermissionID
    public let title: String
    public let why: String
    public let whatBreaksIfDenied: String
    public let actionTitle: String

    public static let all: [PermissionInfo] = [
        PermissionInfo(id: .gmail, title: "Gmail access",
                       why: "Mail reads your inbox and makes the changes you ask for with Google's permission.",
                       whatBreaksIfDenied: "Without Gmail access no mail can load, but you can still change settings and look around.",
                       actionTitle: "Sign in with Google"),
        PermissionInfo(id: .notifications, title: "Notifications",
                       why: "So new important mail and reminders can reach you when Mail isn't in front.",
                       whatBreaksIfDenied: "Without notifications Mail can't alert you to new important mail or reminders; "
                       + "you still see them in Mail, and everything else works.",
                       actionTitle: "Allow notifications"),
        PermissionInfo(id: .openAtLogin, title: "Open at login",
                       why: "So Mail is already running and up to date when you sit down.",
                       whatBreaksIfDenied: "Without it Mail doesn't start by itself; open it from the Dock and it catches up.",
                       actionTitle: "Open at login"),
        PermissionInfo(id: .onDeviceAI, title: "On-device AI",
                       why: "Summaries and reply drafts run on this Mac's own model, so email text never leaves it.",
                       whatBreaksIfDenied: "Without it the on-device AI features stay off; Mail works the same and sends nothing "
                       + "elsewhere instead.",
                       actionTitle: "See how to turn it on"),
    ]

    public static func info(_ id: PermissionID) -> PermissionInfo { all.first { $0.id == id } ?? all[0] }
}

public enum PermissionState: Sendable, Hashable {
    case notAsked
    case granted
    case denied
    case unavailable(String)
    case needsApproval

    public var text: String {
        switch self {
        case .notAsked: "Not asked yet"
        case .granted: "On"
        case .denied: "Off"
        case .unavailable(let hint): hint
        case .needsApproval: "Needs approval in System Settings › Login Items"
        }
    }
}

@MainActor @Observable
public final class PermissionsModel {
    public struct Row: Identifiable, Hashable {
        public let info: PermissionInfo
        public let state: PermissionState
        public var id: PermissionID { info.id }
        public var whatBreaks: String { info.whatBreaksIfDenied }
        public var showsWhatBreaks: Bool { state != .granted }
    }

    public private(set) var states: [PermissionID: PermissionState] = [:]

    @ObservationIgnored private let notifier: any SystemNotifying
    @ObservationIgnored private let loginItem: any LoginItemControlling
    @ObservationIgnored private let ai: any AIOnboardingPort
    @ObservationIgnored private let signedIn: @MainActor () -> Bool

    public init(notifier: any SystemNotifying, loginItem: any LoginItemControlling, ai: any AIOnboardingPort,
                signedIn: @escaping @MainActor () -> Bool) {
        self.notifier = notifier
        self.loginItem = loginItem
        self.ai = ai
        self.signedIn = signedIn
    }

    public var rows: [Row] { PermissionInfo.all.map { Row(info: $0, state: states[$0.id] ?? .notAsked) } }

    public var guideRows: [Row] { rows.filter { $0.id != .gmail } }

    public func refresh() async {
        states[.gmail] = signedIn() ? .granted : .notAsked
        switch await notifier.authorization() {
        case .notDetermined: states[.notifications] = .notAsked
        case .authorized: states[.notifications] = .granted
        case .denied: states[.notifications] = .denied
        }
        switch loginItem.status() {
        case .notRegistered: states[.openAtLogin] = .notAsked
        case .enabled: states[.openAtLogin] = .granted
        case .requiresApproval: states[.openAtLogin] = .needsApproval
        case .notFound: states[.openAtLogin] = .unavailable(Self.loginItemUnavailable)
        }
        switch await ai.onDeviceStatus() {
        case .available: states[.onDeviceAI] = .granted
        case .unavailable(let hint): states[.onDeviceAI] = .unavailable(hint)
        }
    }

    public func requestNotifications() async {
        let allowed = await notifier.requestAuthorization()
        states[.notifications] = allowed ? .granted : .denied
    }

    public func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try loginItem.register() } else { try loginItem.unregister() }
        } catch {
            states[.openAtLogin] = .denied
            return
        }
        switch loginItem.status() {
        case .enabled: states[.openAtLogin] = .granted
        case .requiresApproval: states[.openAtLogin] = .needsApproval
        case .notRegistered: states[.openAtLogin] = .notAsked
        case .notFound: states[.openAtLogin] = .unavailable(Self.loginItemUnavailable)
        }
    }

    public static let loginItemUnavailable = "Mail can't be added to Open at login right now."

    public var blocksContinuing: Bool { false }
}
