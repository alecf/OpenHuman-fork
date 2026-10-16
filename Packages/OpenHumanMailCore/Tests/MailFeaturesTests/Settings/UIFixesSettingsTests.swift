import Foundation
import MailActions
import MailModel
import OpenHumanAI
import OpenHumanAITesting
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
struct UIFixesSettingsTests {
    @Test func advancedNamesEveryWholeFeatureSwitchApartFromItsEverydaySwitch() throws {
        let defaults = ScopedDefaults("openhuman.test.ui-fixes-settings")
        defer { defaults.cleanup() }
        let rows = FeaturesSettingsModel(modules: ModuleList.all, registered: [], defaults: defaults).rows
        let everyday: Set<String> = ["Snoozing", "Send later", "Reminders", "Open at login", "Dock badge", "Notifications"]
        for row in rows {
            #expect(!everyday.contains(row.title), "\(row.id) is titled like an everyday switch: \(row.title)")
        }
        for (id, page) in FeaturesSettingsModel.everydayPage {
            let row = try #require(rows.first { $0.id == id })
            #expect(row.title.hasSuffix("(whole feature)") && row.detail.hasSuffix("The everyday switch is in \(page)."))
        }
        #expect(!FeaturesSettingsModel.userFacing.contains(.dockBadge) && !FeaturesSettingsModel.userFacing.contains(.launchAtLogin))
        #expect(FeaturesSettingsModel.userFacing.isDisjoint(with: Set(FeaturesSettingsModel.everydayPage.keys)))
        #expect(FeaturesSettingsModel.userFacing.contains(.ai), "the user's own switches stay")
    }

    @Test func developerOptionsAreOffByDefaultAndOnlyOfferedInADevToolsBuild() throws {
        let defaults = ScopedDefaults("openhuman.test.ui-fixes-settings")
        defer { defaults.cleanup() }
        for availability in [DevFeedbackAvailability.off, .devTools] {
            let options = DeveloperOptions(devFeedback: availability, defaults: defaults)
            #expect(!options.isOn && !options.showsDeveloperItems, "\(availability)")
            #expect(!options.debuggingTools && !options.showsDebuggingTools, "\(availability)")
        }
        let devTools = DeveloperOptions(devFeedback: .devTools, defaults: defaults)
        devTools.isOn = true
        devTools.debuggingTools = true
        let again = DeveloperOptions(devFeedback: .devTools, defaults: defaults)
        #expect(again.showsDeveloperItems && again.showsDebuggingTools)
        let release = DeveloperOptions(devFeedback: .off, defaults: defaults)
        #expect(!release.isAvailable && !release.showsDeveloperItems && !release.showsDebuggingTools,
                "a stored choice never turns anything on in a public build")
        release.debuggingTools = true
        #expect(!release.showsDebuggingTools)
        release.isOn = false
        #expect(DeveloperOptions(devFeedback: .devTools, defaults: defaults).showsDeveloperItems,
                "a public build leaves the stored choice alone")
    }

    @Test func theCalendarNotesUseNoModeWording() {
        for note in [CalendarSettingsModel.createNote, CalendarSettingsModel.connectNote] {
            for word in ["safe mode", "test-writes", "write mode", "read-only"] {
                #expect(!note.lowercased().contains(word), "\(word)")
            }
        }
        #expect(CalendarSettingsModel.createNote.contains("Undo"))
    }

    @Test func theCalendarStatusSaysTheKeyAsAKey() {
        let f = SettingsFixture()
        let status = CalendarSettingsModel(environment: f.env).status
        #expect(!status.contains(" (0)"), "\(status)")
    }

    @Test func aLongSplitRuleIsCutAfterAWholeWord() {
        #expect(SplitSettingsModel.ruleSummary("from:(@example.com)") == "from:(@example.com)")
        let long = "from:(@example.com) OR label:Clients OR subject:(quarterly report)"
        let summary = SplitSettingsModel.ruleSummary(long)
        #expect(summary.hasSuffix("…") && summary.count <= 37)
        let words = Set(long.split(separator: " ").map(String.init))
        #expect(summary.dropLast().split(separator: " ").allSatisfy { words.contains(String($0)) }, "no word cut in half")
        #expect(SplitSettingsModel.ruleSummary(String(repeating: "x", count: 50)).count == 37, "one long word is cut")
        #expect(SplitSettingsModel.unreadTitle(3) == "3 unread")
    }

    @Test func theQuickRepliesSwitchSaysWhyItIsGreyedOut() async {
        let f = AIFixture(settings: AISettings(draftReplies: .onDemand))
        await f.loaded()
        let page = AISettingsPageModel(center: f.center, environment: f.env)
        #expect(!page.offersInstantReplyStrip)
        #expect(page.instantReplyStripStatus == AISettingsPageModel.instantReplyStripNeedsDrafts)
        page.useAI = false
        #expect(page.instantReplyStripStatus == AISettingsPageModel.instantReplyStripNeedsAI)
        page.useAI = true
        page.draftReplies = .onDeviceAuto
        #expect(page.instantReplyStripStatus == nil)
    }

    @Test func aUserSeesOnlyTheModelsThisVersionHas() async {
        let f = AIFixture(providers: [ScriptedProvider()])
        await f.loaded()
        let user = AISettingsPageModel(center: f.center, environment: f.env, listsUnavailableModels: false)
        await user.refresh()
        #expect(user.providers.map(\.id) == ["fake"])
        let developer = AISettingsPageModel(center: f.center, environment: f.env)
        #expect(developer.providers.map(\.id) == ["fake", "local", "apple.pcc"])
    }

    @Test func reviewQueueShortcutsComeAfterTheEverydayOnes() {
        let model = ShortcutsSettingsModel(environment: SettingsFixture().env)
        for section in model.sections {
            let review = ShortcutLine.placeName(of: [.review])
            let isReview = section.lines.map { line in !line.places.isEmpty && line.places.allSatisfy { $0 == review } }
            if let first = isReview.firstIndex(of: true) {
                #expect(!isReview[first...].contains(false), "\(section.title): an everyday key after the review queue's")
            }
        }
    }
}
