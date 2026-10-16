import Foundation
import OpenHumanCloudSyncTesting
import OpenHumanCore
import Testing
@testable import OpenHumanCloudSync

@Suite("Clocks, values and merges")
struct ClockAndMergeTests {
    @Test func ticksStayOrderedWhileTheClockStandsStill() {
        var clock = HLCClock(device: "d1", last: nil)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let stamps = (0..<5).map { _ in clock.tick(now: now) }
        #expect(stamps == stamps.sorted())
        #expect(Set(stamps).count == 5)
    }

    @Test func observingAStampFromAheadMovesPastIt() {
        var clock = HLCClock(device: "d1", last: nil)
        let remote = HLC(millis: 1_790_000_999_000, counter: 7, device: "d2")
        clock.observe(remote)
        #expect(clock.tick(now: Date(timeIntervalSince1970: 1_790_000_000)) > remote)
    }

    @Test func textRoundTripsAndSortsLikeTheClock() {
        let early = HLC(millis: 5, counter: 1, device: "x")
        let late = HLC(millis: 16, counter: 0, device: "a")
        #expect(HLC(early.description) == early)
        #expect(early < late)
        #expect(early.description < late.description)
        #expect(HLC("not a clock") == nil)
    }

    @Test func valuesRoundTripExactly() throws {
        let value: CloudValue = ["i": 5, "d": 5.0, "s": "x", "b": true, "n": .null, "x": .data(Data([1, 2])), "a": [1, "two"]]
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(CloudValue.self, from: data) == value)
    }

    @Test func mergesAreCommutativeAndIdempotent() {
        var rng = SeededGenerator(state: 11)
        for _ in 0..<300 {
            let x = randomDocument(&rng)
            let y = randomDocument(&rng)
            for type in [splitType, settingType] {
                let xy = type.merge(x, y)
                #expect(xy == type.merge(y, x))
                #expect(type.merge(x, x) == x)
                #expect(type.merge(xy, y) == xy)
            }
        }
    }

    @Test func aTombstoneHidesOnlyOlderFields() {
        let old = HLC(millis: 1, counter: 0, device: "a")
        let delete = HLC(millis: 2, counter: 0, device: "b")
        let newer = HLC(millis: 3, counter: 0, device: "a")
        let tombstone = CloudDocument(fields: ["name": CloudField(value: "Old", hlc: old)], deletedAt: delete)
        #expect(tombstone.isDeleted)
        #expect(tombstone.values.isEmpty)
        let edit = CloudDocument(fields: ["name": CloudField(value: "New", hlc: newer)])
        let merged = CloudMerge.perField(tombstone, edit)
        #expect(!merged.isDeleted)
        #expect(merged.values == ["name": "New"])
    }

    @Test func accountZonesHideTheAddress() {
        let zone = CloudZoneID.account(email: "Someone@Example.test")
        #expect(zone == CloudZoneID.account(email: "someone@example.test"))
        #expect(zone.name.hasPrefix("acct-"))
        #expect(zone.name.count == 21)
        #expect(!zone.name.contains("example"))
        #expect(zone.kind == "account")
        #expect(CloudZoneID.app.kind == "app")
    }

    private func randomDocument(_ rng: inout SeededGenerator) -> CloudDocument {
        func stamp() -> HLC {
            HLC(millis: Int64.random(in: 0..<4, using: &rng), counter: UInt32.random(in: 0..<2, using: &rng),
                device: ["d1", "d2"].randomElement(using: &rng)!)
        }
        var fields: [String: CloudField] = [:]
        for key in ["name", "rule", "enabled"] where Bool.random(using: &rng) {
            let choices: [CloudValue] = [.null, "one", "two", 3, true]
            fields[key] = CloudField(value: choices.randomElement(using: &rng)!, hlc: stamp())
        }
        return CloudDocument(fields: fields, deletedAt: Bool.random(using: &rng) ? stamp() : nil)
    }
}

@Suite("Sealed records")
struct SealedRecordTests {
    let key = CloudKey(id: "k1", material: Data(repeating: 7, count: 32))
    let document = CloudDocument(fields: ["name": CloudField(value: "Work", hlc: HLC(millis: 1, counter: 0, device: "d"))])

    @Test func aSealedPayloadIsBoundToItsRecordAndEnvelope() throws {
        let codec = CloudRecordCodec(inlineLimit: 50_000)
        let record = try codec.encode(document, id: recordID("split.one"), type: "Split", key: key, writer: "d",
                                      systemFields: nil, forceAsset: false)
        #expect(try codec.decode(record, key: key) == document)
        guard case .inline(let sealed) = record.payload else {
            Issue.record("expected an inline payload")
            return
        }
        #expect(!String(decoding: sealed, as: UTF8.self).contains("Work"))
        var moved = record
        moved.id = recordID("split.two")
        #expect(throws: CloudCodecError.tampered) { try codec.decode(moved, key: key) }
        var flipped = record
        flipped.deleted = true
        #expect(throws: CloudCodecError.tampered) { try codec.decode(flipped, key: key) }
        let wrong = CloudKey(id: "k1", material: Data(repeating: 8, count: 32))
        #expect(throws: CloudCodecError.tampered) { try codec.decode(record, key: wrong) }
    }

    @Test func largePayloadsMoveToAssets() throws {
        let codec = CloudRecordCodec(inlineLimit: 1_000)
        let large = CloudDocument(fields: ["body": CloudField(value: .string(String(repeating: "x", count: 2_000)),
                                                             hlc: HLC(millis: 1, counter: 0, device: "d"))])
        let record = try codec.encode(large, id: recordID("snip.big"), type: "Setting", key: key, writer: "d",
                                      systemFields: nil, forceAsset: false)
        guard case .asset = record.payload else {
            Issue.record("expected an asset payload")
            return
        }
        #expect(record.estimatedBytes < 1_000)
        #expect(try codec.decode(record, key: key) == large)
    }

    @Test func newerFormatsAreRefused() throws {
        let codec = CloudRecordCodec(inlineLimit: 50_000)
        var record = try codec.encode(document, id: recordID("split.one"), type: "Split", key: key, writer: "d",
                                      systemFields: nil, forceAsset: false)
        record.format = 2
        #expect(throws: CloudCodecError.unsupportedFormat(2)) { try codec.decode(record, key: key) }
    }

    @Test func outboxAndClockSurviveReopening() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ohcloudsync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("cloud-sync.sqlite")
        let clock = TestClock()
        let account = FakeCloudAccount()
        let keychain = FakeSyncedKeychain()
        let id = recordID("split.saved")
        var first: TestDevice? = try TestDevice("A", account: account, keychain: keychain, clock: clock, store: .file(file))
        try await first?.edit(id, ["name": "Kept"])
        let stamp = try #require(await first?.sync.document(id)?.version)
        first = nil
        let second = try TestDevice("A", account: account, keychain: keychain, clock: clock, store: .file(file))
        #expect(await second.sync.pendingUploadCount() == 1)
        try await second.edit(id, ["name": "Kept twice"])
        let next = try #require(await second.sync.document(id)?.version)
        #expect(next > stamp)
        await second.sync.start()
        await second.sync.sync()
        #expect(account.record(id) != nil)
        #expect(await second.sync.pendingUploadCount() == 0)
    }

    @Test func noAccountIsRecordedAndChangesWaitForOne() async throws {
        let clock = TestClock()
        let keychain = FakeSyncedKeychain()
        let device = try TestDevice("A", account: nil, keychain: keychain, clock: clock)
        #expect(await device.sync.start() == .unavailable(.noAccount))
        let last = await device.sync.diagnostics().last
        #expect(last?.kind == .accountStatus)
        #expect(last?.code == "noAccount")
        let id = recordID("split.offline")
        try await device.edit(id, ["name": "Offline"])
        #expect(await device.sync.pendingUploadCount() == 1)
        let account = FakeCloudAccount()
        await device.cloud.switchAccount(to: account)
        #expect(await device.sync.start() == .running)
        await device.sync.sync()
        #expect(account.record(id) != nil)
    }
}
