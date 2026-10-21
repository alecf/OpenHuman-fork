import Foundation
import MailFeatures
import Observation
import Sparkle

@MainActor @Observable
final class SparkleUpdater: SoftwareUpdater {
    static let feedKey = "SUFeedURL"
    static let publicKeyKey = "SUPublicEDKey"

    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    // Why: Sparkle keeps this setting itself; the Settings switch reads and writes it through here so it redraws
    var automaticallyChecksForUpdates: Bool {
        get {
            access(keyPath: \.automaticallyChecksForUpdates)
            return controller.updater.automaticallyChecksForUpdates
        }
        set {
            withMutation(keyPath: \.automaticallyChecksForUpdates) {
                controller.updater.automaticallyChecksForUpdates = newValue
            }
        }
    }

    var lastUpdateCheckDate: Date? { controller.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // Why: Sparkle refuses to start without an HTTPS feed and an EdDSA public key, and says so in an alert
    static func isConfigured(_ info: [String: Any]) -> Bool {
        func value(_ key: String) -> String? {
            let text = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        guard let feed = value(feedKey).flatMap(URL.init(string:)), feed.scheme == "https", feed.host() != nil else { return false }
        return value(publicKeyKey).flatMap { Data(base64Encoded: $0) }?.count == 32
    }
}
