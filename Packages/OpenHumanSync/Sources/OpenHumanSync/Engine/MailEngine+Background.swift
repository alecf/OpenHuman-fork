import Foundation
import OpenHumanCore
import OpenHumanStore

extension LocalWindow {
    public static let standard = LocalWindow(metadataHorizonDays: SettingKey<Int?>.metadataHorizonDays.defaultValue,
                                             bodyHorizonDays: SettingKey<Int>.bodyHorizonDays.defaultValue,
                                             downloadBodies: SettingKey<Bool>.downloadBodies.defaultValue)
    // Why: the phone keeps a smaller local window and leaves most of the shared Gmail budget to the Mac
    public static let phone = LocalWindow(metadataHorizonDays: 365, bodyHorizonDays: 30, downloadBodies: false,
                                          backfillUnitsPerMinute: 1_500)

    public static var platformDefault: LocalWindow {
        #if os(iOS)
        .phone
        #else
        .standard
        #endif
    }

    var bodyHorizonKey: SettingKey<Int> {
        SettingKey(name: SettingKey<Int>.bodyHorizonDays.name, defaultValue: bodyHorizonDays, isSafetyKey: false)
    }

    var metadataHorizonKey: SettingKey<Int?> {
        SettingKey(name: SettingKey<Int?>.metadataHorizonDays.name, defaultValue: metadataHorizonDays, isSafetyKey: false)
    }

    var downloadBodiesKey: SettingKey<Bool> {
        SettingKey(name: SettingKey<Bool>.downloadBodies.name, defaultValue: downloadBodies, isSafetyKey: false)
    }
}

extension MailEngine {
    public static let backgroundFlushDeadline: Duration = .seconds(5)
    public static let refreshOperationLimit = 25

    func enterBackground() async {
        inBackground = true
        isActive = false
        store.setExternalChangePollActive(false)
        for runtime in runtimes.values {
            await runtime.syncer.pauseBackfill()
            await runtime.setActive(false)
        }
        await flushPendingSends(deadline: Self.backgroundFlushDeadline)
    }

    public func refreshOnce(deadline: Date, maxOperations: Int = refreshOperationLimit) async -> RefreshReport {
        var report = RefreshReport()
        guard configuration.role == .app else { return report }
        let clock = configuration.clock
        let accounts = ((try? store.accounts()) ?? []).filter(Self.isSyncable).sorted { $0.id < $1.id }
        var leases: OwnershipManager?
        for account in accounts {
            if clock.now >= deadline || Task.isCancelled {
                report.deadlineReached = clock.now >= deadline
                break
            }
            let runtime: AccountRuntime
            var transient = false
            if let owned = runtimes[account.id] {
                runtime = owned
            } else if started {
                if await ownership?.isOwner(account.id) != true { report.ownedElsewhere.append(account.id) }
                continue
            } else {
                let manager = leases ?? OwnershipManager(store: store, identity: processIdentity, kind: "app", clock: clock)
                leases = manager
                guard await manager.acquire(account.id) else {
                    report.ownedElsewhere.append(account.id)
                    continue
                }
                reconcileAtLaunch(account)
                guard let made = makeRuntime(account) else {
                    await manager.release(account.id)
                    continue
                }
                runtime = made
                transient = true
            }
            let (outcome, reached) = await Self.racing(deadline, clock: clock) {
                await runtime.refresh(until: deadline, maxOperations: maxOperations)
            }
            if transient {
                await runtime.stop()
                if !started { await leases?.release(account.id) }
            }
            switch outcome?.sync {
            case .success(let sync)?:
                report.syncs.append(sync)
            case .failure(let error)?:
                report.syncs.append(SyncReport(accountID: account.id, kind: "sync", added: 0, changed: 0, deleted: 0,
                                               units: 0, duration: .zero, error: AccountSyncer.code(error)))
            case nil:
                break
            }
            if let operations = outcome?.operations { report.operations[account.id] = operations }
            if reached || clock.now >= deadline { report.deadlineReached = true }
        }
        return report
    }

    private enum Lap<T: Sendable>: Sendable { case finished(T), deadline, cancelled }

    static func racing<T: Sendable>(_ deadline: Date, clock: any OHClock,
                                    _ work: @escaping @Sendable () async -> T) async -> (T?, Bool) {
        await withTaskGroup(of: Lap<T>.self) { group in
            group.addTask { .finished(await work()) }
            group.addTask {
                do { try await clock.sleep(until: deadline) } catch { return .cancelled }
                return .deadline
            }
            var value: T?
            var reached = false
            while let lap = await group.next() {
                switch lap {
                case .finished(let result):
                    value = result
                    group.cancelAll()
                case .deadline:
                    reached = true
                    group.cancelAll()
                case .cancelled:
                    break
                }
            }
            return (value, reached)
        }
    }
}
