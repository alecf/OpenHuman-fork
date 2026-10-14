import AppKit
import Foundation
import MailFeatures
import OpenHumanCore
import OpenHumanStore

@MainActor
final class LiveWriteModeSwitch: WriteModeSwitching {
    nonisolated static var key: SettingKey<Bool> { MailStoreSettings.storeKey(WriteModeSession.allowChanges) }

    let launchSource: WriteModeLaunchSource
    var writesNow = false
    private let store: any SettingsStoring
    private let reopenMail: @MainActor () -> Void

    init(store: any SettingsStoring, launchSource: WriteModeLaunchSource, reopen: @escaping @MainActor () -> Void) {
        self.store = store
        self.launchSource = launchSource
        self.reopenMail = reopen
    }

    var allowsChanges: Bool { Self.read(store) }

    func save(_ allowsChanges: Bool) throws {
        try store.setSetting(Self.key, allowsChanges, scope: .global)
        Log(.app).notice("write mode switch saved \(allowsChanges ? "on" : "off") (applies from the next launch)")
    }

    func reopen() { reopenMail() }

    nonisolated static func atLaunch(store: any SettingsStoring, environment: [String: String]) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return false }
        return read(store)
    }

    nonisolated static func read(_ store: any SettingsStoring) -> Bool {
        (try? store.setting(key, scope: .global)) ?? false
    }
}

// Why: relaunch through LaunchServices like a Dock launch, so Terminal variables such as OPENHUMAN_SAFE_MODE do not carry over
@MainActor
enum AppRelaunch {
    static let script = #"i=0; while /bin/kill -0 "$1" 2>/dev/null && [ "$i" -lt 600 ]; do /bin/sleep 0.1; i=$((i+1)); done; exec /usr/bin/open "$2""#

    static func relaunch() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        do { try helper.run() } catch {
            Log(.app).error("reopen helper did not start; Mail stays open")
            return
        }
        NSApp.terminate(nil)
    }
}
