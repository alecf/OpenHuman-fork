import Foundation
import MailModel
import Testing
@testable import MailFeatures

@MainActor
struct SettingsSearchTests {
    private var pages: [SettingsPageEntry] { SettingsShellModel(environment: SettingsFixture().env).pages }

    @Test func aWordFindsTheRowsWhoseTitleStartsWithItFirstAndSaysWhereTheyLive() throws {
        let results = SettingsSearch.results(for: "undo", pages: pages)
        let first = try #require(results.first)
        #expect(first.entry.title == "Undo send")
        #expect(first.entry.kind == .row)
        #expect(first.location == "General › Sending")
        #expect(first.symbol == SettingsPageID.general.symbol)
    }

    @Test func everyWordHasToMatchAndCaseAndAccentsDoNotMatter() {
        #expect(SettingsSearch.results(for: "ZOOM", pages: pages).first?.entry.title == "Zoom")
        #expect(SettingsSearch.results(for: "théme dark", pages: pages).first?.entry.title == "Theme when dark")
        #expect(SettingsSearch.results(for: "undo zebra", pages: pages).isEmpty)
        #expect(SettingsSearch.results(for: "  ", pages: pages).isEmpty)
    }

    @Test func keywordsFindRowsByTheWordsPeopleUse() {
        let titles = SettingsSearch.results(for: "hotkey", pages: pages).map(\.entry.title)
        #expect(titles.contains("Open a new message with a global shortcut"))
        let darkMode = SettingsSearch.results(for: "dark mode", pages: pages).map(\.entry.page)
        #expect(darkMode.contains(SettingsPageID.appearance.rawValue))
    }

    @Test func pagesAreResultsTooAndOpenWithoutAHighlight() throws {
        let result = try #require(SettingsSearch.results(for: "appear", pages: pages).first)
        #expect(result.entry.kind == .page)
        #expect(result.entry.page == SettingsPageID.appearance.rawValue)
        #expect(result.location == nil)
    }

    @Test func aPageThatIsNotShownHasNoResults() {
        let off = SettingsShellModel(environment: SettingsFixture(flags: FeatureFlags().with(.notifications, false)).env)
        #expect(SettingsSearch.results(for: "test notification", pages: pages).contains { $0.entry.page == "notifications" })
        #expect(!SettingsSearch.results(for: "test notification", pages: off.pages).contains { $0.entry.page == "notifications" })
    }

    @Test func developerRowsAreFoundOnlyWhenDeveloperItemsShow() {
        #expect(SettingsSearch.results(for: "tailscale", pages: pages).isEmpty)
        #expect(!SettingsSearch.results(for: "tailscale", pages: pages, includesDeveloperItems: true).isEmpty)
    }

    @Test func everyCatalogEntryNamesARealPageAndTab() {
        let ids = Set(pages.map(\.id))
        let tabs: [String: Set<String>] = ["importance": ["rules", "categories", "tracking"],
                                           "ai": ["overview", "prompts", "activity"]]
        for entry in SettingsSearchCatalog.entries {
            #expect(ids.contains(entry.page), "\(entry.title) is on an unknown page \(entry.page)")
            if let tab = entry.tab { #expect(tabs[entry.page]?.contains(tab) == true, "\(entry.title) is on tab \(tab)") }
            #expect(!entry.title.isEmpty)
        }
        let all = SettingsSearchCatalog.entries.map(\.id)
        #expect(Set(all).count == all.count, "no entry is listed twice")
    }

    @Test func openingAResultShowsItsPageAndHighlightsUntilThePageChanges() throws {
        let model = SettingsShellModel(environment: SettingsFixture().env)
        let zoom = try #require(SettingsSearch.results(for: "zoom", pages: model.pages).first)
        model.openResult(zoom.entry)
        #expect(model.selected == "general")
        let reveal = try #require(model.reveal)
        #expect(reveal.entry == zoom.entry)
        model.endReveal(reveal.serial + 1)
        #expect(model.reveal != nil, "a newer search keeps its highlight")
        model.selected = "privacy"
        #expect(model.reveal == nil)
        model.openResult(zoom.entry)
        let again = try #require(model.reveal)
        #expect(again.serial > reveal.serial, "opening the same result again scrolls to it again")
        model.endReveal(again.serial)
        #expect(model.reveal == nil)
        model.openResult(SettingsSearchEntry(page: "search", kind: .page, title: "Search"))
        #expect(model.selected == "search" && model.reveal == nil)
        model.openResult(SettingsSearchEntry(page: "nowhere", kind: .row, title: "Nothing"))
        #expect(model.selected == "search", "a result for a page that is not shown does nothing")
    }
}
