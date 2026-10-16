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
        guard configuration.role == .app else { return RefreshReport() }
        let pass = refreshPass(deadline: deadline, maxOperations: maxOperations)
        return await withTaskCancellationHandler { await pass.value } onCancel: { pass.cancel() }
    }

    func refreshPass(deadline: Date, maxOperations: Int) -> Task<RefreshReport, Never> {
        if let running = refreshing { return running }
        let pass = Task { await runRefresh(deadline: deadline, maxOperations: maxOperations) }
        refreshing = pass
        return pass
    }

    func settleRefresh() async {
        while let pass = refreshing {
            pass.cancel()
            _ = await pass.value
        }
    }

    func cancelRefresh() { refreshing?.cancel() }

    private func runRefresh(deadline: Date, maxOperations: Int) async -> RefreshReport {
        var report = RefreshReport()
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
                if let ownership, await !ownership.isOwner(account.id) { report.ownedElsewhere.append(account.id) }
                continue
            } else {
                let manager: OwnershipManager
                if let leases { manager = leases } else { manager = await renewedLeases() }
                leases = manager
                guard await manager.acquire(account.id) else {
                    await manager.release(account.id)
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
            let outcome = await runtime.refresh(until: deadline, maxOperations: maxOperations)
            if transient {
                await runtime.stop()
                await leases?.release(account.id)
            }
            switch outcome.sync {
            case .success(let sync)?:
                report.syncs.append(sync)
            case .failure(let error)?:
                report.syncs.append(SyncReport(accountID: account.id, kind: "sync", added: 0, changed: 0, deleted: 0,
                                               units: 0, duration: .zero, error: AccountSyncer.code(error)))
            case nil:
                break
            }
            if let operations = outcome.operations { report.operations[account.id] = operations }
            if clock.now >= deadline { report.deadlineReached = true }
        }
        if let leases {
            await leases.stopHeartbeat()
            await leases.releaseAll()
        }
        refreshing = nil
        return report
    }

    private func renewedLeases() async -> OwnershipManager {
        let manager = OwnershipManager(store: store, identity: processIdentity, kind: "app", clock: configuration.clock)
        await manager.startHeartbeat(onChange: { [weak self] _, isOwner in
            if !isOwner { await self?.cancelRefresh() }
        })
        return manager
    }
}
