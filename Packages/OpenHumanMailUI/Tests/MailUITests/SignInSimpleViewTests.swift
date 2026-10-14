#if os(macOS)
import AppKit
import Foundation
import MailFeatures
import MailModel
import MailTheme
import OpenHumanCore
import SwiftUI
import Testing
@testable import MailUI

private struct FixedClient: AccountManaging {
    let status: OAuthClientStatus
    var waits = false

    func oauthClientStatus() -> AsyncStream<OAuthClientStatus> {
        let status = status
        return AsyncStream { $0.yield(status); $0.finish() }
    }
    func importOAuthClient(json: Data) async throws {}
    func addAccount(loginHint: String?) async throws -> AccountID {
        if waits { try await Task.sleep(for: .seconds(3600)) }
        return AccountID(1)
    }
}

private enum SignInSource {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/MailUI/Onboarding/SignInView.swift")

    static func code() throws -> String { try code(of: file) }

    static func code(_ path: String) throws -> String {
        try code(of: file.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(path))
    }

    private static func code(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    static func block(_ opening: String, in text: String) throws -> Substring {
        let start = try #require(text.range(of: opening), "\(opening) not found")
        let open = try #require(text[start.lowerBound...].firstIndex(of: "{"))
        var depth = 0
        var cursor = open
        while cursor < text.endIndex {
            if text[cursor] == "{" { depth += 1 }
            if text[cursor] == "}" {
                depth -= 1
                if depth == 0 { return text[open...cursor] }
            }
            cursor = text.index(after: cursor)
        }
        return text[open...]
    }

    static func count(_ needle: String, in text: Substring) -> Int {
        if needle.allSatisfy(\.isLetter), let word = try? Regex("\\b\(needle)\\b") {
            return text.matches(of: word).count
        }
        return text.components(separatedBy: needle).count - 1
    }
}

@MainActor
@Suite struct SignInSimpleViewTests {
    @Test func theMainScreenDrawsOnlyTheNameTheSentenceAndTheOneButton() throws {
        let code = try SignInSource.code()
        let main = try SignInSource.block("private var main: some View", in: code)
        #expect(SignInSource.count("Text(", in: main) == 2, "the name and the one sentence")
        #expect(SignInSource.count("Text(screen.appName)", in: main) == 1)
        #expect(SignInSource.count("Text(screen.sentence)", in: main) == 1)
        #expect(SignInSource.count("Button", in: main) == 0)
        #expect(SignInSource.count("primaryButton(", in: main) == 1)
        let primary = try SignInSource.block("private func primaryButton(", in: code)
        #expect(SignInSource.count("Button", in: primary) == 2, "one button in each of the two exclusive branches")
        let content = try SignInSource.block("private var content: some View", in: code)
        #expect(SignInSource.count("Button", in: content) == 0, "the column adds no button of its own")
        for gone in ["headline", "promise", "noClientText", "Show me how", "keeps up with you"] {
            #expect(!code.contains(gone), "\(gone) is gone from the sign-in screen")
        }
    }

    @Test func theAccessWordsAndTheFlowsLiveUnderMoreOptions() throws {
        let code = try SignInSource.code()
        let main = try SignInSource.block("private var main: some View", in: code)
        let access = try SignInSource.block("private var accessInfo: some View", in: code)
        for name in ["accessText", "calendarNote", "whatBreaksIfDenied", "modeText"] {
            #expect(access.contains(name), "\(name) under What does Mail ask for?")
            #expect(!main.contains(name), "\(name) not on the main screen")
        }
        let options = try SignInSource.block("private func moreOption(", in: code)
        for flow in ["Use a specific account…", "Sign in from another device", "ownClientDisclosure", "clientChoice",
                     "I already have the file…", "accessInfo"] {
            #expect(options.contains(flow), "\(flow) under More options")
        }
        #expect(code.contains("disclosure(\"More options\""))
        #expect(code.contains("disclosure(\"What does Mail ask for?\""))
    }

    @Test func theKeychainSentenceIsOnTheSignInScreenTheConnectStepAndAccounts() throws {
        let content = try SignInSource.block("private var content: some View", in: try SignInSource.code())
        #expect(content.contains("if model.showsKeychainNote"))
        #expect(content.contains("Text(model.keychainNote)"))
        let connect = try SignInSource.block("private struct ConnectEmailStep",
                                             in: try SignInSource.code("Onboarding/WelcomeGuideView.swift"))
        #expect(connect.contains("if signIn.showsKeychainNote"))
        #expect(connect.contains("Text(signIn.keychainNote)"))
        let page = try SignInSource.block("struct AccountsSettingsPage",
                                          in: try SignInSource.code("Settings/Pages/GeneralAccountsPages.swift"))
        let accounts = try SignInSource.block("var body: some View", in: String(page))
        #expect(accounts.contains("SettingsSection(footnote: model.keychainNote)"))
    }

    @Test func theMovedWordsAreStillTheUsers() {
        for mode in [SafeModeInfo.readOnly, .writeAllowlist, .normal] {
            let text = SignInView.accessText(mode)
            #expect(!text.contains("gmail.") && !text.contains("Safe mode") && !text.contains("Write mode"), "\(mode)")
            #expect(text.hasPrefix("Mail asks Gmail"), "it answers What does Mail ask for?: \(mode)")
        }
        #expect(SignInView.calendarNote.contains("isn't part of this sign-in"))
        #expect(SignInView.remoteText.contains("error page"), "the error page is expected")
    }

    @Test func theScreenLaysOutCollapsedAndExpanded() async throws {
        let ready = SignInModel(accounts: FixedClient(status: .configured(source: .file)), safeMode: .normal)
        await ready.run()
        #expect(ready.phase == .ready && !ready.showsMoreOptions)
        try layOut(ready, "signin-simple-ready")
        ready.toggleMoreOptions()
        ready.toggleAccessInfo()
        ready.toggleOwnClient()
        try layOut(ready, "signin-simple-more-options")

        let none = SignInModel(accounts: FixedClient(status: .missing), safeMode: .normal)
        await none.run()
        #expect(none.screen.action == .setUpGoogle)
        try layOut(none, "signin-simple-no-client")

        let waiting = SignInModel(accounts: FixedClient(status: .configured(source: .environment), waits: true),
                                  safeMode: .normal)
        await waiting.run()
        waiting.signIn()
        #expect(waiting.phase == .signingIn && waiting.screen.action == .cancel)
        try layOut(waiting, "signin-simple-waiting")
        waiting.cancel()
    }

    private func layOut(_ model: SignInModel, _ name: String) throws {
        for (width, height, size) in [(960, 640, "default"), (480, 600, "narrow")] {
            let hosting = NSHostingView(rootView: SignInView(model: model, theme: .light))
            hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
            hosting.layoutSubtreeIfNeeded()
            #expect(hosting.fittingSize.width > 0, "\(name)-\(size)")
            if let dir = ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] {
                let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(size).png"))
            }
        }
    }
}
#endif
