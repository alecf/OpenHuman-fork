import Foundation
import MailActions
import MailModel
import Observation

@MainActor @Observable
public final class ShortcutLearning {
    public static let changesPerSave = 5
    public static let resetMessage = String(localized: "Shortcut hints will show again after a click")

    public private(set) var counts: [ActionID: ShortcutUseCount] = [:]
    public private(set) var hintOnClick = AppSettings.hintOnClick.defaultValue
    public private(set) var isStarted = false

    @ObservationIgnored private let settings: (any SettingsPort)?
    @ObservationIgnored private let notices: NoticeCenter
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var unsaved = 0
    @ObservationIgnored private var follower: Task<Void, Never>?
    @ObservationIgnored public private(set) var lastSave: Task<Void, Never>?

    public init(settings: (any SettingsPort)?, notices: NoticeCenter) {
        self.settings = settings
        self.notices = notices
    }

    isolated deinit {
        follower?.cancel()
    }

    public func start() async {
        guard !starting else { return }
        starting = true
        if let settings {
            let stored = (try? await settings.get(AppSettings.shortcutLearning)) ?? [:]
            counts = Self.decode(stored)
            hintOnClick = (try? await settings.get(AppSettings.hintOnClick)) ?? AppSettings.hintOnClick.defaultValue
            follower = Task { [weak self] in
                for await on in settings.observe(AppSettings.hintOnClick) {
                    guard !Task.isCancelled, let self else { return }
                    self.hintOnClick = on
                }
            }
        }
        isStarted = true
    }

    @discardableResult
    public func performed(_ id: ActionID, source: ActionSource, descriptor: ActionDescriptor?,
                          context: ActionContext) -> ShortcutHintPolicy.Hint? {
        guard isStarted, let descriptor, !descriptor.defaultBindings.isEmpty,
              let use = ShortcutHintPolicy.use(of: source) else { return nil }
        let counts = record(id, use)
        let settings = ShortcutHintPolicy.Settings(hintOnClick: hintOnClick, reduceMotion: notices.reduceMotion)
        guard let hint = ShortcutHintPolicy.decision(descriptor, source: source, counts: counts, scope: context.scope,
                                                     title: ActionRules.title(for: descriptor, in: context),
                                                     settings: settings) else { return nil }
        notices.post(hint.message, style: .info, duration: hint.duration, animates: hint.animates)
        return hint
    }

    @discardableResult
    func record(_ id: ActionID, _ use: ShortcutHintPolicy.Use) -> ShortcutUseCount {
        var count = counts[id] ?? ShortcutUseCount()
        guard count.keyboard < ShortcutHintPolicy.learnedAfterKeyboardUses else { return count }
        switch use {
        case .keyboard: count.keyboard += 1
        case .mouse: count.mouse += 1
        }
        counts[id] = count
        unsaved += 1
        if unsaved >= Self.changesPerSave { save() }
        return count
    }

    public var canReset: Bool { !counts.isEmpty }

    @discardableResult
    public func flush() -> Task<Void, Never>? {
        guard unsaved > 0 else { return lastSave }
        return save()
    }

    public func reset() async {
        counts = [:]
        await save()?.value
    }

    @discardableResult
    private func save() -> Task<Void, Never>? {
        unsaved = 0
        guard let settings else { return nil }
        let value = Self.encode(counts)
        let previous = lastSave
        let task = Task {
            await previous?.value
            try? await settings.set(AppSettings.shortcutLearning, value)
        }
        lastSave = task
        return task
    }

    static func encode(_ counts: [ActionID: ShortcutUseCount]) -> [String: ShortcutUseCount] {
        Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) })
    }

    static func decode(_ stored: [String: ShortcutUseCount]) -> [ActionID: ShortcutUseCount] {
        Dictionary(uniqueKeysWithValues: stored.map { (ActionID($0.key), $0.value) })
    }
}

@MainActor
final class ShortcutHintActionHandler: ActionHandler {
    static let ids: [ActionID] = [.resetShortcutHints]
    private let learning: ShortcutLearning
    private let notices: NoticeCenter

    init(learning: ShortcutLearning, notices: NoticeCenter) {
        self.learning = learning
        self.notices = notices
    }

    func perform(_ request: ActionRequest) -> ActionPerformance {
        guard request.id == .resetShortcutHints else { return .notHandled }
        let learning = self.learning, notices = self.notices
        return .started(Task { @MainActor in
            await learning.reset()
            notices.post(ShortcutLearning.resetMessage, style: .info, duration: NoticeCenter.infoDuration)
        })
    }
}
