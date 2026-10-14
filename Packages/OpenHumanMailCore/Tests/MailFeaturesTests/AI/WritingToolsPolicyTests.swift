import Foundation
import MailFakes
import MailModel
import OpenHumanAI
import Testing
@testable import MailFeatures

@MainActor
@Suite(.serialized) struct WritingToolsPolicyTests {
    @Test func offByDefaultAndOnOnlyOnceTheUserAllowsIt() async throws {
        let f = AIFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        #expect(!f.compose.allowsWritingTools(in: session), "off until the user allows it")
        let page = AISettingsPageModel(center: f.center, environment: f.env)
        #expect(!page.allowWritingTools)
        #expect(AISettingsPageModel.writingToolsNote.contains("On-device AI only"))

        page.allowWritingTools = true
        #expect(f.center.settings.allowWritingTools, "saved through the AI center, the settings' one owner")
        #expect(f.compose.allowsWritingTools(in: session))
        page.useAI = false
        #expect(!f.compose.allowsWritingTools(in: session), "Use AI off turns it off")
        page.useAI = true
        #expect(f.compose.allowsWritingTools(in: session))
        page.allowWritingTools = false
        #expect(!f.compose.allowsWritingTools(in: session))
        #expect(f.recorder.calls.isEmpty, "nothing is written to mail")
        f.compose.close(session)
    }

    @Test func anOnDeviceOnlyAccountNeverGetsIt() async throws {
        let f = AIFixture(settings: AISettings(allowWritingTools: true))
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal, account: AIFixture.work))
        #expect(f.compose.allowsWritingTools(in: session))
        try f.center.setOnDeviceOnly(true, accountID: AIFixture.work)
        #expect(!f.compose.allowsWritingTools(in: session))
        #expect(!f.center.allowsWritingTools(for: session.account))
        let other = try #require(f.router.accounts.map(\.account).first { $0.id != AIFixture.work })
        #expect(f.center.allowsWritingTools(for: other))
        try f.center.setOnDeviceOnly(false, accountID: AIFixture.work)
        #expect(f.compose.allowsWritingTools(in: session))
        f.compose.close(session)
    }

    @Test func offWithTheModuleOffOrWithoutAnAICenter() async throws {
        let off = AIFixture(settings: AISettings(allowWritingTools: true), flags: FeatureFlags().with(.ai, false))
        await off.loaded()
        let first = try #require(off.compose.openNew(placement: .modal))
        #expect(off.compose.aiCenter == nil)
        #expect(!off.compose.allowsWritingTools(in: first))
        off.compose.close(first)

        let none = AIFixture(settings: AISettings(allowWritingTools: true), withAI: false)
        await none.loaded()
        let second = try #require(none.compose.openNew(placement: .modal))
        #expect(!none.compose.allowsWritingTools(in: second))
        none.compose.close(second)
    }
}
