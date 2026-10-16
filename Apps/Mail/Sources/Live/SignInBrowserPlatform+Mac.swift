import AppKit
import Foundation
import MailModel
import OpenHumanGmailApple
import OpenHumanMailLive

extension SignInBrowserPlatform {
    static let system = SignInBrowserPlatform(
        openDefault: { try await SystemBrowser().open($0) },
        openWith: { url, browser in
            let app = URL(fileURLWithPath: browser.appPath)
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: app,
                                                  configuration: NSWorkspace.OpenConfiguration())
        },
        browsers: {
            await MainActor.run {
                guard let probe = URL(string: "https://accounts.google.com/") else { return [] }
                let own = Bundle.main.bundleIdentifier
                var seen = Set<String>()
                return NSWorkspace.shared.urlsForApplications(toOpen: probe).compactMap { app -> InstalledBrowser? in
                    guard let id = Bundle(url: app)?.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
                    let name = FileManager.default.displayName(atPath: app.path)
                    let trimmed = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
                    return InstalledBrowser(id: id, name: trimmed, appPath: app.path)
                }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        })
}

@MainActor
final class PasteboardSignInClipboard: SignInClipboard {
    func copy(_ text: String) -> Int {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        return board.changeCount
    }

    @discardableResult
    func clear(ifUnchangedSince mark: Int) -> Bool {
        let board = NSPasteboard.general
        guard board.changeCount == mark else { return false }
        board.clearContents()
        return true
    }
}
