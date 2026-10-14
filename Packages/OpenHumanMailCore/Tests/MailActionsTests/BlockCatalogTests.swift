import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailActions

@Suite struct BlockCatalogTests {
    let key = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))

    func context(_ scope: ActionScope = .list, location: MailLocation = .system(.inbox), sender: String? = "dana@acme.example",
                 safeMode: SafeModeInfo = .normal) -> ActionContext {
        ActionContext(scope: scope, account: AccountID(1), accountCount: 1, location: location, selection: [key],
                      focusedThread: key, sender: sender, hasRows: true, safeMode: safeMode)
    }

    func availability(_ id: ActionID, _ c: ActionContext) -> ActionAvailability {
        ActionRules.availability(ActionCatalog.descriptor(id)!, in: c)
    }

    @Test func theEntriesBelongToTheBlockModuleAndChangeMail() throws {
        for id in [ActionID.blockSender, .blockDomain] {
            let d = try #require(ActionCatalog.descriptor(id))
            #expect(d.module == .block && d.changesMail && d.effect == .mail && !d.isDestructive)
            #expect(d.scopes == [.list, .reader] && d.target == .focusedThread)
            #expect(d.appearsInMenu && d.appearsInPalette)
        }
        let go = try #require(ActionCatalog.descriptor(.goBlocked))
        #expect(go.module == .block && go.effect == .view, "the list view only reads")
        #expect(FeatureModuleID.mur2.contains(.block))
        #expect(ActionCatalog.descriptor(.settingsPage("blocked"))?.title == "Settings: Blocked")
    }

    @Test func theKeysAreChordsNobodyElseUses() throws {
        let sender = try #require(ActionCatalog.descriptor(.blockSender)).defaultBindings
        let domain = try #require(ActionCatalog.descriptor(.blockDomain)).defaultBindings
        #expect(sender.map(\.description) == ["⌥⌘B"] && domain.map(\.description) == ["⌥⇧⌘B"])
        for binding in sender + domain {
            let users = ActionCatalog.all.filter { $0.defaultBindings.contains(binding) }.map(\.id)
            #expect(users.count == 1, "\(binding) is also bound to \(users)")
        }
    }

    @Test func readOnlySafeModeDisablesBlockingWithTheUsualReason() {
        let c = context(safeMode: .readOnly)
        #expect(availability(.blockSender, c) == .disabled(.safeMode))
        #expect(availability(.blockDomain, c) == .disabled(.safeMode))
        #expect(availability(.blockSender, context()) == .enabled)
        #expect(availability(.blockDomain, context(.reader)) == .enabled)
        #expect(availability(.goBlocked, c) == .enabled, "the list works in every mode")
    }

    @Test func notOfferedWhereTheMailIsTheAuthorsOwnOrAlreadyGone() {
        for location in [MailLocation.system(.sent), .system(.drafts), .system(.scheduled), .system(.trash), .system(.spam)] {
            #expect(availability(.blockSender, context(location: location)) == .hidden, "\(location)")
            #expect(availability(.blockDomain, context(location: location)) == .hidden, "\(location)")
        }
        #expect(availability(.blockSender, context(location: .system(.allMail))) == .enabled)
    }

    @Test func aConversationWithoutAnAddressSaysSo() {
        let c = context(sender: nil)
        #expect(availability(.blockSender, c) == .disabled(.other("No sender address")))
        #expect(availability(.blockDomain, c) == .disabled(.other("No sender domain")))
    }

    @Test func notInTheComposer() {
        #expect(availability(.blockSender, context(.composer)) == .hidden)
    }
}
