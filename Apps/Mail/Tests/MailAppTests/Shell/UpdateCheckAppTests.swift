import AppKit
import MailFakes
import MailFeatures
import Testing
@testable import OpenHumanMail

@MainActor
@Suite(.serialized)
struct UpdateCheckAppTests {
    static let label = BuildLabel(version: "0.1.0", build: "1001", channel: BuildLabel.earlyDevelopmentChannel)

    @Test func aTestRunNeverAsksGitHub() async {
        let center = UpdateCheckSupport.makeCenter(environment: ["XCTestConfigurationFilePath": "x"], label: Self.label)
        #expect(center.feed == .openHuman && center.phase == .idle)
        await center.check()
        #expect(center.result == .couldNotCheck(.unavailable))
        await MailApp.updates.check()
        #expect(MailApp.updates.result == .couldNotCheck(.unavailable), "the app's own check is the test-safe one under tests")
        #expect(MailApp.updates.feed == .openHuman && !MailApp.updates.isPresented)
    }

    @Test func theAppMenuOffersCheckForUpdatesUnderAbout() throws {
        let appMenu = try #require(NSApp.mainMenu?.items.first?.submenu)
        let titles = appMenu.items.map(\.title)
        let about = try #require(titles.firstIndex(of: "About OpenHuman Mail"), "\(titles)")
        let check = try #require(titles.firstIndex(of: UpdateCheckCenter.menuTitle), "\(titles)")
        #expect(check > about && check <= about + 2, "\(titles)")
        #expect(appMenu.items[check].keyEquivalent.isEmpty)
    }

    @Test func installingPutsTheCheckWhereSettingsAndThePaletteFindIt() {
        let environment = AppEnvironment.fake(corpus: FakeCorpus.make(threadCount: 4))
        #expect(environment.system.updates == nil)
        let center = UpdateCheckSupport.makeCenter(environment: ["XCTestConfigurationFilePath": "x"], label: Self.label)
        UpdateCheckSupport.install(in: environment, center: center)
        #expect(environment.system.updates === center)
    }
}
