import Foundation
import GRDB
import OpenHumanCore
import Testing
@testable import OpenHumanStore

@Suite struct LeaseTests {
    private let host = "test-host"
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func fixture() throws -> (MailStore, AccountID) {
        let store = try MailStore.openInMemoryForTesting()
        return (store, try store.addAccount(email: "me@example.com", displayName: nil, scopes: []))
    }

    private func acquire(_ store: MailStore, _ account: AccountID, _ owner: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                         at now: Date? = nil, host: String? = nil) throws -> LeaseInfo? {
        try store.acquireLease(account: account, ownerID: owner, kind: "app", pid: pid, host: host ?? self.host,
                               now: now ?? t0, ttl: .seconds(45))
    }

    @Test func freeLeaseIsTakenAndReported() throws {
        let (store, account) = try fixture()
        #expect(try store.lease(account: account) == nil)
        let info = try #require(try acquire(store, account, "A"))
        #expect(info.ownerID == "A" && info.kind == "app" && info.isLive)
        #expect(try store.lease(account: account)?.ownerID == "A")
    }

    @Test func aLiveOwnerBlocksOthersButCanReacquire() throws {
        let (store, account) = try fixture()
        _ = try acquire(store, account, "A", host: "other-host")
        #expect(try acquire(store, account, "B", at: t0.addingTimeInterval(10), host: "other-host") == nil)
        #expect(try acquire(store, account, "A", at: t0.addingTimeInterval(10), host: "other-host") != nil)
    }

    @Test func anExpiredLeaseCanBeTaken() throws {
        let (store, account) = try fixture()
        _ = try acquire(store, account, "A", host: "other-host")
        #expect(try acquire(store, account, "B", at: t0.addingTimeInterval(44), host: "other-host") == nil)
        let taken = try acquire(store, account, "B", at: t0.addingTimeInterval(46), host: "other-host")
        #expect(taken?.ownerID == "B")
        #expect(try store.renewLease(account: account, ownerID: "A", now: t0.addingTimeInterval(47), ttl: .seconds(45)) == false)
    }

    @Test func renewalExtendsTheLease() throws {
        let (store, account) = try fixture()
        _ = try acquire(store, account, "A", host: "other-host")
        #expect(try store.renewLease(account: account, ownerID: "A", now: t0.addingTimeInterval(30), ttl: .seconds(45)))
        #expect(try acquire(store, account, "B", at: t0.addingTimeInterval(60), host: "other-host") == nil)
        #expect(try acquire(store, account, "B", at: t0.addingTimeInterval(76), host: "other-host") != nil)
    }

    @Test func aDeadPidOnThisHostIsTakenOverImmediately() throws {
        let (store, account) = try fixture()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let exit = ProcessExit()
        exit.attach(to: child)
        try child.run()
        #expect(exit.wait(child, timeout: 30, "/usr/bin/true"))
        let deadPid = child.processIdentifier
        _ = try acquire(store, account, "A", pid: deadPid)
        let taken = try acquire(store, account, "B", at: t0.addingTimeInterval(1))
        #expect(taken?.ownerID == "B")
        let (s2, a2) = try fixture()
        _ = try acquire(s2, a2, "A", pid: deadPid, host: "elsewhere")
        #expect(try acquire(s2, a2, "B", at: t0.addingTimeInterval(1), host: "somewhere-else") == nil)
        let (s3, a3) = try fixture()
        _ = try acquire(s3, a3, "A")
        #expect(try acquire(s3, a3, "B", at: t0.addingTimeInterval(1)) == nil)
    }

    @Test func releaseFreesOnlyTheOwnersLease() throws {
        let (store, account) = try fixture()
        _ = try acquire(store, account, "A", host: "other-host")
        try store.releaseLease(account: account, ownerID: "B")
        #expect(try store.lease(account: account)?.ownerID == "A")
        try store.releaseLease(account: account, ownerID: "A")
        #expect(try store.lease(account: account) == nil)
    }

    @Test func takeoverRequestIsRecordedForTheOwnerAndClearedOnHandover() throws {
        let (store, account) = try fixture()
        _ = try acquire(store, account, "A", host: "other-host")
        try store.requestTakeover(account: account, requesterID: "B", now: t0.addingTimeInterval(5))
        #expect(try store.takeoverRequester(account: account) == "B")
        try store.requestTakeover(account: account, requesterID: "A", now: t0.addingTimeInterval(6))
        #expect(try store.takeoverRequester(account: account) == "B")
        try store.releaseLease(account: account, ownerID: "A")
        _ = try acquire(store, account, "B", at: t0.addingTimeInterval(7), host: "other-host")
        #expect(try store.takeoverRequester(account: account) == nil)
        let other = try store.addAccount(email: "two@example.com", displayName: nil, scopes: [])
        try store.requestTakeover(account: other, requesterID: "B", now: t0)
        #expect(try store.lease(account: other) == nil)
    }

    @Test func removingTheAccountDropsItsLease() throws {
        let (store, account) = try fixture()
        _ = try acquire(store, account, "A")
        try store.removeAccountData(account) { _ in }
        #expect(try store.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM sync_lease") } == 0)
    }

    @Test func rejectsAnUnknownOwnerKind() throws {
        let (store, account) = try fixture()
        #expect(throws: StoreError.self) {
            try store.acquireLease(account: account, ownerID: "A", kind: "daemon", pid: 1, host: host, now: t0, ttl: .seconds(45))
        }
    }

    @Test func durationConversion() {
        #expect(MailStore.millis(.seconds(45)) == 45_000)
        #expect(MailStore.millis(.milliseconds(250)) == 250)
        #expect(MailStore.millis(.seconds(1) + .milliseconds(500)) == 1500)
    }

    @Test func aLeaseHeldByAnotherProcessBlocksUsUntilItExits() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let helper = try HelperProcess(["--home", dir.path, "hold-lease", String(account.rawValue)])
        #expect(helper.waitFor("ready"), Comment(rawValue: helper.stderrText))
        let ours = ProcessIdentity.localHostName
        let held = try #require(try store.lease(account: account))
        #expect(held.kind == "cli" && held.isLive && held.pid == helper.process.processIdentifier)
        #expect(try store.acquireLease(account: account, ownerID: store.writerID, kind: "app",
                                       pid: ProcessInfo.processInfo.processIdentifier, host: ours, now: Date(), ttl: .seconds(45)) == nil)
        helper.closeInput()
        #expect(helper.waitFor("done"))
        #expect(helper.finish() == 0)
        #expect(try store.acquireLease(account: account, ownerID: store.writerID, kind: "app",
                                       pid: ProcessInfo.processInfo.processIdentifier, host: ours, now: Date(), ttl: .seconds(45)) != nil)
    }

    @Test func aKilledOwnerIsReportedNotLiveAndCanBeTakenAtOnce() throws {
        let (store, dir) = try openTemp(kind: .app)
        defer { try? FileManager.default.removeItem(at: dir) }
        let account = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let helper = try HelperProcess(["--home", dir.path, "hold-lease", String(account.rawValue)])
        #expect(helper.waitFor("ready"))
        helper.process.interrupt()
        kill(helper.process.processIdentifier, SIGKILL)
        _ = helper.finish()
        #expect(try store.lease(account: account)?.isLive == false)
        let taken = try store.acquireLease(account: account, ownerID: store.writerID, kind: "app",
                                           pid: ProcessInfo.processInfo.processIdentifier,
                                           host: ProcessIdentity.localHostName, now: Date(), ttl: .seconds(45))
        #expect(taken != nil)
    }
}
