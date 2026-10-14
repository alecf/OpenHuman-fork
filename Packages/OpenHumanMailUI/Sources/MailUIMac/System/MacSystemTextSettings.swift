import AppKit
import MailModel

@MainActor
public final class MacSystemTextSettings: SystemTextSettings {
    private var body: (@MainActor (SystemTextValues) -> Void)?
    private var tokens: [NSObjectProtocol] = []

    public init() {}

    isolated deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }

    public func current() -> SystemTextValues {
        SystemTextValues(autocorrect: NSSpellChecker.isAutomaticSpellingCorrectionEnabled,
                         textReplacement: NSSpellChecker.isAutomaticTextReplacementEnabled,
                         quoteSubstitution: NSSpellChecker.isAutomaticQuoteSubstitutionEnabled,
                         dashSubstitution: NSSpellChecker.isAutomaticDashSubstitutionEnabled)
    }

    public func observe(_ body: @escaping @MainActor (SystemTextValues) -> Void) {
        self.body = body
        guard tokens.isEmpty else { return }
        let names: [Notification.Name] = [
            NSSpellChecker.didChangeAutomaticSpellingCorrectionNotification,
            NSSpellChecker.didChangeAutomaticTextReplacementNotification,
            NSSpellChecker.didChangeAutomaticQuoteSubstitutionNotification,
            NSSpellChecker.didChangeAutomaticDashSubstitutionNotification,
        ]
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            }
        }
    }

    private func changed() {
        body?(current())
    }
}
