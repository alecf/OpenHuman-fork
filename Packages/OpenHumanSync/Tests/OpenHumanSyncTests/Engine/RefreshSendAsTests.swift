import Foundation
import OpenHumanCore
import OpenHumanGmail
import OpenHumanGmailTesting
import OpenHumanStore
import Testing
@testable import OpenHumanSync

@Suite struct RefreshSendAsTests {
    @Test(arguments: [GmailScope.modify, GmailScope.readonly])
    func aRefreshRequestReReadsSendAsOnce(_ grant: String) async throws {
        let h = try await EngineHarness(scopes: [grant])
        let engine = h.engine()
        await engine.start()
        try await h.waitForSyncs(engine)
        let before = await h.gmail.callCount(.listSendAs)

        let primary = h.gmail.accountEmail
        await h.gmail.setSendAs([
            GmailSendAs(sendAsEmail: primary, displayName: "Test Account", signature: "<div>Synthetic</div>",
                        isPrimary: true, isDefault: true, verificationStatus: "accepted"),
            GmailSendAs(sendAsEmail: "alias@relay.example", displayName: "Alias", isPrimary: false, isDefault: false,
                        verificationStatus: "accepted"),
        ])
        try h.store.setSetting(SettingKey<Int?>.syncRequestAt, 1, scope: .global)
        try await eventually("send-as re-read") { await h.gmail.callCount(.listSendAs) == before + 1 }
        try await eventually("aliases stored") {
            let account = try h.store.accounts().first { $0.id == h.account }
            return account?.sendAs.map(\.email) == [primary, "alias@relay.example"]
                && account?.sendAs.first?.signatureHTML == "<div>Synthetic</div>"
        }
        try await h.waitForSyncs(engine, 2)
        #expect(await h.gmail.callCount(.listSendAs) == before + 1, "one GET per account per request")
        await engine.stop()
    }
}
