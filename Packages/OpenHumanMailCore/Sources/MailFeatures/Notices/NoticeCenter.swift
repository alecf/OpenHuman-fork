import Foundation
import Observation

public struct Toast: Identifiable, Sendable, Hashable {
    public enum Style: Sendable, Hashable {
        case info
        case undo
        case error
    }

    public let id: UUID
    public var message: String
    public var style: Style
    public var actionTitle: String?
    public var shortcut: String?
    public var postedAt: Date
    public var expiresAt: Date?
    public var holdsWindow: Bool
    public var secondaryActionTitle: String?
    public var secondaryShortcut: String?
    public var animates: Bool

    public init(id: UUID = UUID(), message: String, style: Style, actionTitle: String? = nil, shortcut: String? = nil,
                postedAt: Date, expiresAt: Date?, holdsWindow: Bool = false, animates: Bool = true) {
        self.id = id
        self.message = message
        self.style = style
        self.actionTitle = actionTitle
        self.shortcut = shortcut
        self.postedAt = postedAt
        self.expiresAt = expiresAt
        self.holdsWindow = holdsWindow
        self.animates = animates
    }
}

@MainActor @Observable
public final class NoticeCenter {
    public static let toastDuration: Duration = .seconds(6)
    public static let maxVisibleToasts = 2
    public static let resumeMinimum: Duration = .milliseconds(1500)

    public private(set) var toasts: [Toast] = []
    @ObservationIgnored public var timing = ToastTiming.standard
    @ObservationIgnored public var reduceMotion = false

    @ObservationIgnored public var onPost: (@MainActor (Toast) -> Void)?
    @ObservationIgnored private var actions: [Toast.ID: @MainActor () async -> Void] = [:]
    @ObservationIgnored private var secondaryActions: [Toast.ID: @MainActor () async -> Void] = [:]
    @ObservationIgnored private var timers: [Toast.ID: Task<Void, Never>] = [:]
    @ObservationIgnored private var paused: [Toast.ID: TimeInterval] = [:]
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let autoExpire: Bool

    public init(now: @escaping @Sendable () -> Date = { Date() }, autoExpire: Bool = true) {
        self.now = now
        self.autoExpire = autoExpire
    }

    @discardableResult
    public func post(_ message: String, style: Toast.Style = .info, actionTitle: String? = nil, shortcut: String? = nil,
                     duration: Duration? = NoticeCenter.toastDuration, holdsWindow: Bool = false,
                     animates: Bool = true,
                     secondary: Choice? = nil, action: (@MainActor () async -> Void)? = nil) -> Toast.ID {
        let posted = now()
        let lifetime = duration.map { timing.themed($0) }
        var toast = Toast(message: message, style: style, actionTitle: actionTitle, shortcut: shortcut, postedAt: posted,
                          expiresAt: lifetime.map { posted.addingTimeInterval(Self.seconds($0)) },
                          holdsWindow: holdsWindow, animates: animates)
        if let secondary {
            toast.secondaryActionTitle = secondary.title
            toast.secondaryShortcut = secondary.shortcut
            secondaryActions[toast.id] = secondary.action
        }
        return show(toast, duration: duration, action: action)
    }

    public struct Choice {
        public let title: String
        public let shortcut: String?
        public let action: @MainActor () async -> Void

        public init(_ title: String, shortcut: String? = nil, action: @escaping @MainActor () async -> Void) {
            self.title = title
            self.shortcut = shortcut
            self.action = action
        }
    }

    @discardableResult
    public func postChoice(_ message: String, _ first: Choice, _ second: Choice, style: Toast.Style = .info,
                           duration: Duration? = NoticeCenter.toastDuration) -> Toast.ID {
        let posted = now()
        var toast = Toast(message: message, style: style, actionTitle: first.title, shortcut: first.shortcut,
                          postedAt: posted, expiresAt: duration.map { posted.addingTimeInterval(Self.seconds($0)) })
        toast.secondaryActionTitle = second.title
        toast.secondaryShortcut = second.shortcut
        secondaryActions[toast.id] = second.action
        return show(toast, duration: duration, action: first.action)
    }

    private func show(_ toast: Toast, duration: Duration?, action: (@MainActor () async -> Void)?) -> Toast.ID {
        while toasts.count >= Self.maxVisibleToasts, let oldest = toasts.first(where: { !$0.holdsWindow }) ?? toasts.first {
            dismiss(oldest.id)
        }
        toasts.append(toast)
        if let action { actions[toast.id] = action }
        onPost?(toast)
        if let lifetime = duration.map({ timing.themed($0) }) { startTimer(toast.id, after: lifetime) }
        return toast.id
    }

    public func pause(_ id: Toast.ID) {
        guard paused[id] == nil, let expiresAt = toasts.first(where: { $0.id == id })?.expiresAt else { return }
        paused[id] = max(0, expiresAt.timeIntervalSince(now()))
        timers.removeValue(forKey: id)?.cancel()
    }

    public func resume(_ id: Toast.ID, minimum: Duration = NoticeCenter.resumeMinimum) {
        guard let left = paused.removeValue(forKey: id), let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        let remaining = max(left, Self.seconds(minimum))
        toasts[index].expiresAt = now().addingTimeInterval(remaining)
        startTimer(id, after: .seconds(remaining))
    }

    public func isPaused(_ id: Toast.ID) -> Bool { paused[id] != nil }

    private func startTimer(_ id: Toast.ID, after duration: Duration) {
        timers.removeValue(forKey: id)?.cancel()
        guard autoExpire else { return }
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(id)
        }
    }

    public func activate(_ id: Toast.ID) async {
        guard toasts.contains(where: { $0.id == id }) else { return }
        let action = actions[id]
        dismiss(id)
        await action?()
    }

    public func activateSecondary(_ id: Toast.ID) async {
        guard toasts.contains(where: { $0.id == id }) else { return }
        let action = secondaryActions[id]
        dismiss(id)
        await action?()
    }

    public func dismiss(_ id: Toast.ID) {
        toasts.removeAll { $0.id == id }
        actions[id] = nil
        secondaryActions[id] = nil
        paused[id] = nil
        timers.removeValue(forKey: id)?.cancel()
    }

    public func expire(asOf date: Date) {
        for toast in toasts where paused[toast.id] == nil && (toast.expiresAt.map { $0 <= date } ?? false) {
            dismiss(toast.id)
        }
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
