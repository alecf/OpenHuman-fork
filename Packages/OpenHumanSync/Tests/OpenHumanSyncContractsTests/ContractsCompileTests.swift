import Foundation
import Testing
import OpenHumanCore
import OpenHumanGmail
import OpenHumanMIME
import OpenHumanStore
import OpenHumanSync

@Suite struct SyncContractsCompileTests {
    @Test func engineTypes() {
        let config = EngineConfiguration(role: .localClient, appVersion: "0.1.0",
                                         gmail: GmailClientConfig(userAgent: "ua"), clock: TestClock())
        #expect(config.pollInterval == .seconds(60))
        #expect(config.schedulers == Set(ScheduleKind.allCases))
        let roles: [EngineRole] = [.app, .localClient, .readOnly, .cliOneShot, .cliDaemon]
        #expect(roles.count == 5)
        let events: [SystemEvent] = [.didWake, .didEnterBackground, .networkReachable(false), .willTerminate]
        #expect(events.count == 4)
        #expect(config.window == .platformDefault)
        #expect(RefreshReport().syncs.isEmpty && !RefreshReport().deadlineReached)
        #expect(EngineError.requiresApp("sync") != .sendNotAllowed)
        #expect(EngineError.writeAccessMissing("send") != .sendNotAllowed)
        let ref = ThreadRef(accountID: AccountID(1), rowID: ThreadRowID(rawValue: 1), gmailThreadID: GmailThreadID("t"))
        let engineEvents: [EngineEvent] = [
            .snoozeWoke(ref, overdueBy: .seconds(5)), .reminderFired(ref, overdueBy: .zero),
            .schedulerDegraded(.sendLater, "x"), .scheduleLabelBudget(AccountID(1), count: 2001),
            .initialSyncProgress(AccountID(1), phase: .bootstrapping, oldest: nil), .sent(DraftID("d"), nil),
        ]
        #expect(engineEvents.count == 6)
        let draft = NewDraft(id: DraftID("d"), version: 1,
                             skeleton: ReplySkeleton(to: [], cc: [], subject: "Re: x", references: [], quotedHTML: "", quotedText: ""))
        #expect(draft.version == 1)
        #expect(AccountConnectivity.online(syncing: false, lastSyncAt: nil) != .needsReauth)
        let report = SyncReport(accountID: AccountID(1), kind: "incremental", added: 1, changed: 0, deleted: 0, units: 2,
                                duration: .milliseconds(30))
        #expect(report.error == nil)
        let auth: [SendAuthorization] = [.userConfirmed, .scheduled]
        #expect(auth.count == 2)
    }
}
