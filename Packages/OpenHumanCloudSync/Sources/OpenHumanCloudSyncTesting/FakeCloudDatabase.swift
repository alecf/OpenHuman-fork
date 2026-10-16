import Foundation
import OpenHumanCloudSync
import Synchronization

public enum FakeCloudFailure: Error, Sendable, Hashable {
    case tooManyRounds
}

public final class FakeCloudDevice: Sendable {
    private struct Registered {
        weak var database: FakeCloudDatabase?
    }

    private struct State {
        var account: FakeCloudAccount?
        var statusOverride: CloudAccountStatus?
        var databases: [Registered] = []
        var suspensions: [FakeSuspension] = []
    }

    private let state: Mutex<State>

    public init(account: FakeCloudAccount?) {
        state = Mutex(State(account: account))
    }

    public var account: FakeCloudAccount? {
        state.withLock { $0.account }
    }

    public var accountStatus: CloudAccountStatus {
        state.withLock { $0.statusOverride ?? ($0.account == nil ? .noAccount : .available) }
    }

    public var makeDatabase: CloudDatabaseFactory {
        { [self] engineState, delegate in
            let database = FakeCloudDatabase(device: self, state: engineState, delegate: delegate)
            state.withLock { $0.databases.append(Registered(database: database)) }
            return database
        }
    }

    public func setAccountStatus(_ status: CloudAccountStatus?) {
        state.withLock { $0.statusOverride = status }
    }

    public func switchAccount(to account: FakeCloudAccount?) async {
        let (databases, change) = state.withLock { state -> ([FakeCloudDatabase], CloudAccountChange) in
            let change: CloudAccountChange = account == nil ? .signOut : (state.account == nil ? .signIn : .switchAccounts)
            state.account = account
            state.databases.removeAll { $0.database == nil }
            return (state.databases.compactMap(\.database), change)
        }
        for database in databases { await database.accountDidChange(change) }
    }

    public func suspendNextUpload() -> FakeSuspension {
        let suspension = FakeSuspension()
        state.withLock { $0.suspensions.append(suspension) }
        return suspension
    }

    func takeSuspension() -> FakeSuspension? {
        state.withLock { $0.suspensions.isEmpty ? nil : $0.suspensions.removeFirst() }
    }
}

public final class FakeSuspension: Sendable {
    private struct State {
        var arrived = false
        var released = false
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
        var releaseWaiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    public init() {}

    public func reached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.arrived { return true }
                state.arrivalWaiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    public func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.released = true
            defer { state.releaseWaiter = nil }
            return state.releaseWaiter
        }
        waiter?.resume()
    }

    func arrive() async {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.arrived = true
            defer { state.arrivalWaiters = [] }
            return state.arrivalWaiters
        }
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.released { return true }
                state.releaseWaiter = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }
}

public actor FakeCloudDatabase: CloudDatabase {
    struct EngineState: Codable {
        var databaseToken = 0
        var zoneTokens: [String: Int] = [:]
        var pendingRecords: [CloudPendingChange] = []
        var pendingZones: [CloudPendingZoneChange] = []
    }

    public static let maxRounds = 1_000

    private let device: FakeCloudDevice
    private weak var delegate: (any CloudDatabaseDelegate)?
    private var engine: EngineState
    private var cancelled = false

    init(device: FakeCloudDevice, state: Data?, delegate: any CloudDatabaseDelegate) {
        self.device = device
        self.delegate = delegate
        engine = state.flatMap { try? JSONDecoder().decode(EngineState.self, from: $0) } ?? EngineState()
    }

    public var pendingRecordChanges: [CloudPendingChange] { engine.pendingRecords }

    public var isCancelled: Bool { cancelled }

    public func addZoneChanges(_ changes: [CloudPendingZoneChange]) {
        for change in changes where !engine.pendingZones.contains(change) { engine.pendingZones.append(change) }
    }

    public func addRecordChanges(_ changes: [CloudPendingChange]) {
        for change in changes where !engine.pendingRecords.contains(change) { engine.pendingRecords.append(change) }
    }

    public func accountStatus() async throws -> CloudAccountStatus {
        device.accountStatus
    }

    public func cancel() {
        cancelled = true
    }

    public func fetchChanges() async throws {
        let account = try currentAccount()
        let changes = account.databaseChanges(since: engine.databaseToken)
        if !changes.deleted.isEmpty {
            for deletion in changes.deleted { engine.zoneTokens[deletion.zone.name] = nil }
            await delegate?.handle(.zonesDeleted(changes.deleted))
        }
        for zone in changes.changed {
            guard !cancelled else { return }
            let zoneChanges = account.zoneChanges(zone, since: engine.zoneTokens[zone.name] ?? 0)
            engine.zoneTokens[zone.name] = zoneChanges.token
            if !zoneChanges.modified.isEmpty || !zoneChanges.deleted.isEmpty {
                await delegate?.handle(.recordsFetched(modified: zoneChanges.modified, deleted: zoneChanges.deleted,
                                                       unreadable: 0))
            }
        }
        guard !cancelled else { return }
        engine.databaseToken = changes.token
        await emitState()
    }

    public func sendChanges() async throws {
        let account = try currentAccount()
        await sendZones(to: account)
        var rounds = 0
        while !engine.pendingRecords.isEmpty, !cancelled {
            rounds += 1
            guard rounds <= Self.maxRounds else { throw FakeCloudFailure.tooManyRounds }
            guard let delegate, let batch = await delegate.nextBatch(for: engine.pendingRecords) else { break }
            engine.pendingRecords.removeAll { batch.discarded.contains($0) }
            let sent = Set(batch.saves.map { CloudPendingChange.saveRecord($0.id) } + batch.deletes.map { CloudPendingChange.deleteRecord($0) })
            if sent.isEmpty { continue }
            engine.pendingRecords.removeAll { sent.contains($0) }
            if let suspension = device.takeSuspension() { await suspension.arrive() }
            guard !cancelled else { return }
            let result = account.modify(saves: batch.saves, deletes: batch.deletes)
            await delegate.handle(.recordsSent(saved: result.saved, deleted: result.deleted,
                                               failedSaves: result.failedSaves, failedDeletes: result.failedDeletes))
            await sendZones(to: account)
        }
        guard !cancelled else { return }
        await emitState()
    }

    func accountDidChange(_ change: CloudAccountChange) async {
        engine = EngineState()
        await delegate?.handle(.accountChange(change))
    }

    private func sendZones(to account: FakeCloudAccount) async {
        guard !engine.pendingZones.isEmpty, !cancelled else { return }
        let changes = engine.pendingZones
        engine.pendingZones = []
        var saves: [CloudZoneID] = []
        var deletes: [CloudZoneID] = []
        for change in changes {
            switch change {
            case .saveZone(let zone): saves.append(zone)
            case .deleteZone(let zone): deletes.append(zone)
            }
        }
        let result = account.modifyZones(saving: saves, deleting: deletes)
        await delegate?.handle(.zonesSent(saved: result.saved, deleted: result.deleted, failed: []))
    }

    private func currentAccount() throws -> FakeCloudAccount {
        guard !cancelled, device.accountStatus == .available, let account = device.account else {
            throw CloudError.notAuthenticated
        }
        return account
    }

    private func emitState() async {
        guard let data = try? JSONEncoder().encode(engine) else { return }
        await delegate?.handle(.stateUpdate(data))
    }
}
