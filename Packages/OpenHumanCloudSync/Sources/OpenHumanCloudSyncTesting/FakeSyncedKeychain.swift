import Foundation
import OpenHumanCloudSync
import Synchronization

public final class FakeSyncedKeychain: Sendable {
    private struct State {
        var views: [String: [String: CloudKey]] = [:]
        var deleted: Set<String> = []
        var unavailable: Set<String> = []
    }

    private let state = Mutex(State())

    public init() {}

    public func store(for device: String) -> FakeCloudKeyStore {
        state.withLock { state in
            if state.views[device] == nil { state.views[device] = [:] }
        }
        return FakeCloudKeyStore(keychain: self, device: device)
    }

    public func deliver() {
        state.withLock { state in
            var all: [String: CloudKey] = [:]
            for device in state.views.keys.sorted() {
                for (id, key) in state.views[device] ?? [:] where all[id] == nil { all[id] = key }
            }
            for id in state.deleted { all[id] = nil }
            for device in state.views.keys { state.views[device] = all }
        }
    }

    public func keyIDs(on device: String) -> [String] {
        state.withLock { ($0.views[device] ?? [:]).keys.sorted() }
    }

    public func setUnavailable(_ unavailable: Bool, on device: String) {
        state.withLock { state in
            if unavailable { state.unavailable.insert(device) } else { state.unavailable.remove(device) }
        }
    }

    func load(_ device: String) throws -> [CloudKey] {
        try state.withLock { state in
            if state.unavailable.contains(device) { throw CloudKeyStoreError.unavailable(status: -34018) }
            return (state.views[device] ?? [:]).values.sorted { $0.id < $1.id }
        }
    }

    func save(_ key: CloudKey, on device: String) throws {
        try state.withLock { state in
            if state.unavailable.contains(device) { throw CloudKeyStoreError.unavailable(status: -34018) }
            state.deleted.remove(key.id)
            if state.views[device]?[key.id] == nil { state.views[device, default: [:]][key.id] = key }
        }
    }

    func deleteAll(on device: String) throws {
        try state.withLock { state in
            if state.unavailable.contains(device) { throw CloudKeyStoreError.unavailable(status: -34018) }
            state.deleted.formUnion((state.views[device] ?? [:]).keys)
            state.views[device] = [:]
        }
    }
}

public struct FakeCloudKeyStore: CloudKeyStore {
    let keychain: FakeSyncedKeychain
    let device: String

    public func loadKeys() throws -> [CloudKey] {
        try keychain.load(device)
    }

    public func save(_ key: CloudKey) throws {
        try keychain.save(key, on: device)
    }

    public func deleteAll() throws {
        try keychain.deleteAll(on: device)
    }
}
