import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailActions

@Suite struct DraftActionRulesTests {
    let key = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))

    func context(_ location: MailLocation, targets: TargetState = TargetState(), safeMode: SafeModeInfo = .normal,
                 scope: ActionScope = .list) -> ActionContext {
        ActionContext(scope: scope, account: AccountID(1), accountCount: 1, location: location, selection: [key],
                      focusedThread: key, targets: targets, hasRows: true, safeMode: safeMode)
    }

    func availability(_ id: ActionID, _ c: ActionContext) -> ActionAvailability {
        ActionRules.availability(ActionCatalog.descriptor(id)!, in: c)
    }

    @Test func theEntriesAreInTheCatalogWithTheirEffectsAndModules() throws {
        let open = try #require(ActionCatalog.descriptor(.openDraft))
        #expect(open.effect == .view && open.module == nil && open.scopes == [.list, .reader])
        let reschedule = try #require(ActionCatalog.descriptor(.rescheduleSend))
        #expect(reschedule.effect == .external && reschedule.module == .sendLater)
        let cancel = try #require(ActionCatalog.descriptor(.cancelScheduledSend))
        #expect(cancel.effect == .mail && cancel.module == .sendLater)
        for descriptor in [open, reschedule, cancel] {
            #expect(descriptor.defaultBindings.isEmpty, "no key: ↵ in Drafts and Scheduled, the palette, the bar")
            #expect(descriptor.cliCommand == nil && descriptor.target == .focusedThread && descriptor.appearsInPalette)
            #expect(descriptor.category == .thread)
        }
        #expect(ActionCatalog.descriptors(module: .sendLater).map(\.id).contains(.cancelScheduledSend))
    }

    @Test func shownWhereARowHasADraftOrAScheduledSendAndInDraftsAndScheduled() {
        let inbox = context(.system(.inbox))
        #expect(availability(.openDraft, inbox) == .hidden)
        #expect(availability(.cancelScheduledSend, inbox) == .hidden)
        #expect(availability(.rescheduleSend, inbox) == .hidden)
        #expect(availability(.openDraft, context(.system(.inbox), targets: TargetState(anyDraft: true))) == .enabled)
        let scheduledRow = context(.system(.inbox), targets: TargetState(anyScheduled: true))
        #expect(availability(.cancelScheduledSend, scheduledRow) == .enabled)
        #expect(availability(.rescheduleSend, scheduledRow) == .enabled)
        #expect(availability(.openDraft, scheduledRow) == .enabled)
        #expect(availability(.openDraft, context(.system(.drafts))) == .enabled)
        #expect(availability(.cancelScheduledSend, context(.system(.drafts))) == .hidden, "not every draft is scheduled")
        #expect(availability(.openDraft, context(.system(.scheduled))) == .enabled)
        #expect(availability(.cancelScheduledSend, context(.system(.scheduled))) == .enabled)
        #expect(availability(.rescheduleSend, context(.system(.scheduled), scope: .reader)) == .enabled)
        #expect(availability(.cancelScheduledSend, context(.system(.scheduled), scope: .composer)) == .hidden,
                "the composer has its own Cancel on the Sends at line")
    }

    @Test func safeModesRefuseTheChangesNotTheOpening() {
        let readOnly = context(.system(.scheduled), safeMode: .readOnly)
        #expect(availability(.openDraft, readOnly) == .enabled, "opening a draft only shows it")
        #expect(availability(.cancelScheduledSend, readOnly) == .disabled(.safeMode))
        #expect(availability(.rescheduleSend, readOnly) == .disabled(.safeMode))
        let allowlist = context(.system(.scheduled), safeMode: .writeAllowlist)
        #expect(availability(.cancelScheduledSend, allowlist) == .enabled)
        #expect(availability(.rescheduleSend, allowlist) == .disabled(.safeMode), "a send time is a send")
        var noPort = context(.system(.scheduled))
        noPort.canWrite = false
        #expect(availability(.cancelScheduledSend, noPort) == .disabled(.unavailable("Cancel scheduled send")))
        #expect(availability(.openDraft, noPort) == .enabled)
    }
}
