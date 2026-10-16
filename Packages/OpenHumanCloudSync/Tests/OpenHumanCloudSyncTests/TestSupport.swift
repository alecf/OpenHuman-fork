import Foundation
import OpenHumanCloudSync
import OpenHumanCloudSyncTesting
import OpenHumanCore

let splitType = CloudRecordType("Split", policy: .perField)
let settingType = CloudRecordType("Setting", policy: .lastWriterWins)
let ruleType = CloudRecordType("ImportanceRule", policy: .lastWriterWins)

let workZone = CloudZoneID.account(email: "someone@example.test")

func recordID(_ name: String, zone: CloudZoneID = workZone) -> CloudRecordID {
    CloudRecordID(zone: zone, name: name)
}

func testKey(_ id: String) -> CloudKey {
    var bytes = Array(id.utf8.prefix(32))
    bytes += Array(repeating: 0x5A, count: 32 - bytes.count)
    return CloudKey(id: id, material: Data(bytes))
}

struct TestDevice {
    let name: String
    let cloud: FakeCloudDevice
    let local: InMemoryCloudLocal
    let sync: CloudSync

    init(_ name: String, account: FakeCloudAccount?, keychain: FakeSyncedKeychain, clock: TestClock, keyID: String? = nil,
         limits: CloudLimits = .standard, store: CloudSyncStoreLocation = .inMemory) throws {
        let cloud = FakeCloudDevice(account: account)
        let local = InMemoryCloudLocal()
        let key = testKey(keyID ?? "key-" + name.lowercased())
        let configuration = CloudSync.Configuration(deviceID: "device-" + name.lowercased(),
                                                    types: [splitType, settingType, ruleType], limits: limits)
        self.name = name
        self.cloud = cloud
        self.local = local
        sync = try CloudSync(store: store, configuration: configuration, keys: keychain.store(for: name), local: local,
                             clock: clock, makeKey: { key }, database: cloud.makeDatabase)
    }

    func edit(_ id: CloudRecordID, type: String = "Split", _ values: [String: CloudValue]?) async throws {
        await local.set(id, values)
        try await sync.recordLocalChange(id, type: type, values: values)
    }
}

struct Pair {
    let clock: TestClock
    let account: FakeCloudAccount
    let keychain: FakeSyncedKeychain
    let a: TestDevice
    let b: TestDevice

    init(keyA: String = "key-a", keyB: String = "key-b", limits: CloudLimits = .standard) async throws {
        let clock = TestClock()
        let account = FakeCloudAccount()
        let keychain = FakeSyncedKeychain()
        self.clock = clock
        self.account = account
        self.keychain = keychain
        a = try TestDevice("A", account: account, keychain: keychain, clock: clock, keyID: keyA, limits: limits)
        b = try TestDevice("B", account: account, keychain: keychain, clock: clock, keyID: keyB, limits: limits)
        await a.sync.start()
        await b.sync.start()
    }

    func later() {
        clock.advance(by: .seconds(1))
    }

    func share() async {
        await a.sync.sync()
        keychain.deliver()
        await b.sync.sync()
    }
}

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
