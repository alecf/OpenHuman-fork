import Foundation
import MailActions
import MailModel
import Observation

public struct PlatformFeature: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let requirement: String

    public init(id: String, title: String, detail: String, requirement: String = "A notarized build") {
        self.id = id
        self.title = title
        self.detail = detail
        self.requirement = requirement
    }
}

public enum PlatformFeatureCatalog {
    public static let all: [PlatformFeature] = [
        PlatformFeature(id: "services", title: "Services menu",
                        detail: "Send selected text or files from other apps into a new message, or search Mail for "
                            + "selected text."),
        PlatformFeature(id: "menuBarExtra", title: "Menu bar item",
                        detail: "A small menu bar icon with the unread count and quick actions."),
        PlatformFeature(id: "globalHotkey", title: "Global shortcut",
                        detail: "A key combination that opens a new message from any app."),
        PlatformFeature(id: "appIntents", title: "Shortcuts and Siri",
                        detail: "Actions other apps and Shortcuts can run."),
        PlatformFeature(id: "spotlight", title: "Spotlight",
                        detail: "Find conversations from Spotlight. Only sender names, dates, labels and importance are indexed "
                            + "unless you allow subjects. Message text is never indexed.",
                        requirement: "A notarized build"),
        PlatformFeature(id: "focusFilters", title: "Focus filters",
                        detail: "Show only some accounts or splits while a Focus is on."),
        PlatformFeature(id: "writingTools", title: "Apple Writing Tools in the composer",
                        detail: "The system's Writing Tools in the composer. Off until you allow them in Settings › AI, "
                            + "and never for accounts set to On-device AI only."),
    ]
}

public struct PlatformFeatureAvailability: Sendable, Hashable {
    public var available: Set<String>
    public init(available: Set<String> = []) { self.available = available }
    public static let none = PlatformFeatureAvailability()
}

@MainActor @Observable
public final class PlatformFeaturesModel {
    public struct Row: Identifiable, Hashable {
        public let feature: PlatformFeature
        public let isAvailable: Bool
        public var id: String { feature.id }
        public var status: String { isAvailable ? "Available" : "Not in this build yet. Needs: \(feature.requirement)." }
    }

    public let rows: [Row]
    public let spotlight: SpotlightSettingsModel?
    public let menuBar: MenuBarSettingsModel?
    public let hotkey: GlobalHotkeySettingsModel?
    public let services: ServicesSettingsModel?
    public let writingTools: WritingToolsSettingsModel?
    public let intents: AppIntentsSettingsModel?
    public let focus: FocusFilterSettingsModel?
    public static let intro = "Extras that work with the rest of your Mac. The Services menu and Focus filters are on; "
        + "the others are off until you turn them on (Writing Tools in Settings › AI)."
    public var intro: String { Self.intro }

    public init(availability: PlatformFeatureAvailability = .none, catalog: [PlatformFeature] = PlatformFeatureCatalog.all) {
        rows = catalog.map { Row(feature: $0, isAvailable: availability.available.contains($0.id)) }
        spotlight = nil
        menuBar = nil
        hotkey = nil
        services = nil
        writingTools = nil
        intents = nil
        focus = nil
    }

    public init(environment: AppEnvironment, catalog: [PlatformFeature] = PlatformFeatureCatalog.all) {
        let availability = PlatformFeatureAvailability(available: ["spotlight", "menuBarExtra", "globalHotkey", "services",
                                                                   "appIntents", "focusFilters", "writingTools"])
        rows = catalog.map { Row(feature: $0, isAvailable: availability.available.contains($0.id)) }
        spotlight = SpotlightSettingsModel(environment: environment)
        menuBar = MenuBarSettingsModel(system: environment.system)
        hotkey = GlobalHotkeySettingsModel(system: environment.system)
        services = ServicesSettingsModel(system: environment.system)
        writingTools = WritingToolsSettingsModel(environment: environment)
        intents = AppIntentsSettingsModel(environment: environment)
        focus = FocusFilterSettingsModel(system: environment.system)
    }
}

@MainActor @Observable
public final class ServicesSettingsModel {
    public static let note = "macOS reads these items from Mail itself, so they are always listed. To hide one or give it a "
        + "key, use System Settings › Keyboard › Keyboard Shortcuts › Services."
    public static let unconfirmedNote = "If the items are missing after an update, quit and reopen Mail; macOS may need you "
        + "to log out and in to see a new build (unconfirmed)."
    public static let entryTitles = ["New Message in OpenHuman Mail", "New Message with Files in OpenHuman Mail",
                                     "Search in OpenHuman Mail"]

    @ObservationIgnored private let system: SystemCenter

    public init(system: SystemCenter) { self.system = system }

    public var isOn: Bool { system.preferences.servicesEnabled }

    public func setOn(_ on: Bool) { system.setServices(enabled: on) }

    public var status: String {
        isOn ? "On. Select text or files in another app, then right-click › Services."
             : "Off. The items still appear in the Services menu, but Mail doesn't act on them."
    }
}

@MainActor @Observable
public final class WritingToolsSettingsModel {
    public static let warning = "Writing Tools is part of Apple Intelligence. Whether it sends draft text to Apple's servers "
        + "is not confirmed."
    public static let note = "Accounts set to on-device AI only never get it."

    public private(set) var consent: AIProviderConsentRequest?

    @ObservationIgnored private unowned let environment: AppEnvironment

    public init(environment: AppEnvironment) { self.environment = environment }

    private var settings: ComposeTextSettings { environment.composeText }

    public var isOn: Bool { settings.allowWritingTools }

    public func setOn(_ on: Bool) {
        guard on else {
            consent = nil
            settings.allowWritingTools = false
            return
        }
        guard !settings.allowWritingTools else { return }
        consent = ComposeTextSettings.writingToolsConsent(accounts: accounts, onDeviceOnly: { self.onDeviceOnly($0) })
    }

    public func allow() {
        consent = nil
        settings.allowWritingTools = true
    }

    public func decline() { consent = nil }

    public var aiCenter: AICenter? { environment.ai }

    public var status: String {
        guard isOn else { return "Off." }
        let names = accounts.map { StatusBanner.name($0) }
        let excluded = accounts.filter { onDeviceOnly($0) }.map { StatusBanner.name($0) }
        let allowed = names.filter { !excluded.contains($0) }
        guard !names.isEmpty else { return "On." }
        guard !allowed.isEmpty else { return "On, but every account is set to on-device AI only." }
        let on = "On for \(Self.list(allowed))"
        guard !excluded.isEmpty else { return on + "." }
        return on + "; " + Self.list(excluded) + (excluded.count == 1 ? " is" : " are") + " set to on-device AI only."
    }

    private var accounts: [Account] { environment.router.accounts.map(\.account) }

    private func onDeviceOnly(_ account: Account) -> Bool { environment.ai?.isOnDeviceOnly(account) ?? false }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}

@MainActor @Observable
public final class AppIntentsSettingsModel {
    public static let subjectsNote = "Shortcuts can pass what Mail returns to other apps and actions. With this off, results "
        + "name the sender and date only. Message text is never shared."
    public static let changesNote = "Mark done, snooze and remind me only. Sending, trashing and unsubscribing are never "
        + "available to Shortcuts."
    public static let readOnlyNote = "Read-only safe mode: Shortcuts can't change mail in this session."
    public static let unconfirmedNote = "Whether Shortcuts lists actions from a build that is not notarized is not confirmed "
        + "yet. If Mail is missing from Shortcuts, that is the first thing to check. Whether Siri or Apple Intelligence "
        + "process what Mail returns on this Mac is not confirmed either."

    public private(set) var isOn: Bool
    public private(set) var shareSubjects: Bool
    public private(set) var allowMailChanges: Bool
    public private(set) var askBeforeChanges: Bool
    public let isReadOnly: Bool

    @ObservationIgnored private let preferences: IntentPreferences

    public init(environment: AppEnvironment) {
        preferences = IntentPreferences(defaults: environment.system.preferences.defaults)
        isOn = preferences.isEnabled
        shareSubjects = preferences.shareSubjects
        allowMailChanges = preferences.allowMailChanges
        askBeforeChanges = preferences.askBeforeChanges
        isReadOnly = !environment.status.safeMode.allowsMailChanges
    }

    public var status: String {
        isOn ? "On. Look for OpenHuman Mail in the Shortcuts app." : "Off. Shortcuts that use Mail stop with a message."
    }

    public var changesStatus: String? { isReadOnly ? Self.readOnlyNote : nil }

    public func setOn(_ on: Bool) {
        preferences.isEnabled = on
        isOn = on
    }

    public func setShareSubjects(_ on: Bool) {
        preferences.shareSubjects = on
        shareSubjects = on
    }

    public func setAllowMailChanges(_ on: Bool) {
        preferences.allowMailChanges = on
        allowMailChanges = on
    }

    public func setAskBeforeChanges(_ on: Bool) {
        preferences.askBeforeChanges = on
        askBeforeChanges = on
    }
}

@MainActor @Observable
public final class FocusFilterSettingsModel {
    public static let note = "Set it up in System Settings › Focus: pick a Focus, then Add Filter › OpenHuman Mail. A Focus "
        + "filter never hides mail: every account stays one key away (⌃1, ⌃2), and important mail held during a Focus is "
        + "summed up when it ends."
    public static let unconfirmedNote = "Whether macOS offers Focus filters from a build that is not notarized is not "
        + "confirmed yet. If Mail is missing under Add Filter, that is the first thing to check."

    @ObservationIgnored private let system: SystemCenter

    public init(system: SystemCenter) { self.system = system }

    public var isOn: Bool { system.focus != nil }

    public func setOn(_ on: Bool) async { await system.setFocusFilters(enabled: on) }

    public var status: String {
        guard let focus = system.focus else { return "Off. A Focus filter changes nothing in Mail." }
        return focus.settingsStatus
    }

    public var canIgnore: Bool { system.focus?.active != nil }

    public func ignoreThisFocus() async { await system.focus?.ignoreUntilChanged() }
}

@MainActor @Observable
public final class MenuBarSettingsModel {
    public static let note = "The menu has Open Mail, New message and Quit. The number comes from mail already on this Mac; "
        + "showing it never contacts Gmail."

    @ObservationIgnored private let system: SystemCenter

    public init(system: SystemCenter) { self.system = system }

    public var isOn: Bool { system.menuBar != nil }

    public func setOn(_ on: Bool) { system.setMenuBar(enabled: on) }

    public var count: DockBadgeSource {
        get { system.preferences.menuBarCount }
        set { system.preferences.menuBarCount = newValue }
    }

    public static func countTitle(_ source: DockBadgeSource) -> String {
        source == .off ? "No number" : source.title
    }

    public var status: String {
        guard isOn else { return "Off." }
        switch count {
        case .important: return "Shows how many important conversations are unread, and the icon alone at 0."
        case .inbox: return "Shows how many inbox conversations are unread, and the icon alone at 0."
        case .off: return "Shows the icon without a number."
        }
    }
}

@MainActor @Observable
public final class GlobalHotkeySettingsModel {
    public static let note = "Click the shortcut, then press a letter or a digit while holding at least two of ⌃ ⌥ ⌘."

    public var draft: String
    public private(set) var problem: String?

    @ObservationIgnored private let system: SystemCenter

    public init(system: SystemCenter) {
        self.system = system
        draft = (system.globalHotkey?.binding ?? GlobalHotkeyModel.binding(stored: system.preferences.globalHotkeyBinding)).grammar
    }

    public var isOn: Bool { system.globalHotkey != nil }

    public func setOn(_ on: Bool) { system.setGlobalHotkey(enabled: on) }

    public var current: String {
        system.globalHotkey?.display ?? GlobalHotkeyModel.binding(stored: system.preferences.globalHotkeyBinding).description
    }

    public var status: String {
        guard let model = system.globalHotkey else { return "Off. \(current) does nothing." }
        if let message = model.errorMessage { return message }
        return model.isRegistered ? "\(current) opens a new message." : "Not active yet."
    }

    public func record(key: String, modifiers: KeyBinding.Modifiers) {
        guard let binding = GlobalHotkeyRules.recorded(key: key, modifiers: modifiers) else {
            problem = GlobalHotkeyRules.Problem.unsupportedKey.description
            return
        }
        draft = binding.grammar
        apply()
        if problem != nil {
            draft = (system.globalHotkey?.binding ?? GlobalHotkeyModel.binding(stored: system.preferences.globalHotkeyBinding)).grammar
        }
    }

    public func apply() {
        if let model = system.globalHotkey {
            problem = model.change(to: draft)?.description
            if problem == nil { draft = model.binding.grammar }
            return
        }
        switch GlobalHotkeyRules.parse(draft, catalog: system.effectiveCatalog) {
        case .failure(let reason):
            problem = reason.description
        case .success(let binding):
            system.preferences.globalHotkeyBinding = binding.grammar
            draft = binding.grammar
            problem = nil
        }
    }
}

@MainActor @Observable
public final class SpotlightSettingsModel {
    public static let subjectsNote = "Other apps on this Mac can read the Spotlight index. With this off, only the sender's "
        + "name, the date, labels and whether it is important are indexed. With it on, subject lines and a short preview "
        + "are indexed too. Message text is never indexed."
    public static let unconfirmedNote = "Whether Spotlight accepts items from a build that is not notarized is not confirmed yet. "
        + "If a search finds nothing, that is the first thing to check."
    public static let removeNote = "Remove all deletes everything Mail put in Spotlight and turns indexing off."

    public let subjects: StoredSetting<Bool>
    public private(set) var busy = false

    @ObservationIgnored private unowned let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
        subjects = StoredSetting(AppSettings.spotlightIndexSubjects, port: environment.settings)
    }

    public func start() { subjects.start() }

    public var isOn: Bool { environment.system.spotlight != nil }
    public var canChangeSubjects: Bool { environment.settings != nil }

    public var status: String {
        guard let indexer = environment.system.spotlight else { return "Off. Nothing is indexed." }
        if indexer.lastFailed { return "Spotlight didn't accept the last update. Try Rebuild." }
        if indexer.isPaused { return "Waiting for the first sync to finish. \(indexer.indexedCount) indexed so far." }
        return indexer.indexedCount == 1 ? "1 conversation indexed." : "\(indexer.indexedCount) conversations indexed."
    }

    public func setOn(_ on: Bool) async {
        busy = true
        defer { busy = false }
        await environment.system.setSpotlight(enabled: on)
    }

    public func rebuild() async {
        busy = true
        defer { busy = false }
        await environment.system.rebuildSpotlight()
    }

    public func removeAll() async {
        busy = true
        defer { busy = false }
        await environment.system.removeAllSpotlight()
    }

    public func setSubjects(_ on: Bool) async { await subjects.set(on) }
}
