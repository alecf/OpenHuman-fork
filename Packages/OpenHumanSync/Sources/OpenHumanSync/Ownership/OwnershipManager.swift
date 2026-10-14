import Foundation
import OpenHumanCore
import OpenHumanStore

public actor OwnershipManager {
    public static let ttl: Duration = .seconds(45)
    public static let heartbeatInterval: Duration = .seconds(15)

    public nonisolated let identity: ProcessIdentity
    public nonisolated let kind: String
    private let store: any LeaseStoring
    private let clock: any OHClock
    private let log = Log(.sync)

    private var wanted: Set<AccountID> = []
    private var contested: Set<AccountID> = []
    public private(set) var owned: Set<AccountID> = []
    private var heartbeat: Task<Void, Never>?

    public init(store: any LeaseStoring, identity: ProcessIdentity, kind: String = "app", clock: any OHClock) {
        self.store = store
        self.identity = identity
        self.kind = kind
        self.clock = clock
    }

    @discardableResult
    public func acquire(_ account: AccountID) -> Bool {
        wanted.insert(account)
        do {
            let lease = try store.acquireLease(account: account, ownerID: identity.writerID, kind: kind,
                                               pid: identity.pid, host: identity.host, now: clock.now, ttl: Self.ttl)
            if lease != nil {
                owned.insert(account)
                contested.remove(account)
                return true
            }
            owned.remove(account)
            if contested.insert(account).inserted {
                log.notice("account \(account.rawValue): lease held by another live process")
            }
        } catch {
            log.error("account \(account.rawValue): lease acquire failed (\(String(describing: type(of: error))))")
        }
        return false
    }

    public func release(_ account: AccountID) {
        wanted.remove(account)
        guard owned.remove(account) != nil else { return }
        do { try store.releaseLease(account: account, ownerID: identity.writerID) } catch {
            log.error("account \(account.rawValue): lease release failed (\(String(describing: type(of: error))))")
        }
    }

    public func releaseAll() {
        for account in wanted.union(owned).sorted() { release(account) }
    }

    public func isOwner(_ account: AccountID) -> Bool { owned.contains(account) }

    public func tick() -> [(account: AccountID, isOwner: Bool)] {
        var changes: [(AccountID, Bool)] = []
        let now = clock.now
        for account in wanted.sorted() {
            if owned.contains(account) {
                let renewed: Bool
                do {
                    renewed = try store.renewLease(account: account, ownerID: identity.writerID, now: now, ttl: Self.ttl)
                } catch {
                    log.error("account \(account.rawValue): lease renew failed (\(String(describing: type(of: error))))")
                    continue
                }
                if !renewed {
                    owned.remove(account)
                    log.notice("account \(account.rawValue): lease lost")
                    changes.append((account, false))
                }
            } else if acquire(account) {
                log.notice("account \(account.rawValue): lease acquired")
                changes.append((account, true))
            }
        }
        return changes
    }

    public func startHeartbeat(onChange: @escaping @Sendable (AccountID, Bool) async -> Void,
                               afterTick: (@Sendable () async -> Void)? = nil) {
        guard heartbeat == nil else { return }
        let clock = self.clock
        let interval = Self.heartbeatInterval.timeInterval
        var next = clock.now.addingTimeInterval(interval)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await clock.sleep(until: next) } catch { return }
                next = clock.now.addingTimeInterval(interval)
                guard let self else { return }
                for change in await self.tick() { await onChange(change.account, change.isOwner) }
                await afterTick?()
            }
        }
    }

    public func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    public nonisolated static func liveOwner(account: AccountID, store: any LeaseStoring) -> LeaseInfo? {
        guard let lease = try? store.lease(account: account), lease.isLive else { return nil }
        return lease
    }
}
