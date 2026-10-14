import Foundation
import MailActions

public struct IntentPreferences {
    public static let enabledKey = FeatureFlags.key(.appIntents)
    public static let shareSubjectsKey = "intents.shareSubjects"
    public static let allowMailChangesKey = "intents.allowMailChanges"
    public static let askBeforeChangesKey = "intents.askBeforeChanges"

    let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    public var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    public var shareSubjects: Bool {
        get { defaults.object(forKey: Self.shareSubjectsKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.shareSubjectsKey) }
    }

    public var allowMailChanges: Bool {
        get { defaults.object(forKey: Self.allowMailChangesKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.allowMailChangesKey) }
    }

    public var askBeforeChanges: Bool {
        get { defaults.object(forKey: Self.askBeforeChangesKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.askBeforeChangesKey) }
    }
}
