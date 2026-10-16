import Foundation
import OpenHumanCloudSync
import OpenHumanCloudSyncTesting
import OpenHumanCore
import Testing

@Suite("Two devices and one cloud")
struct TwoDeviceSyncTests {
    @Test func concurrentCreatesCollapseIntoOneRecord() async throws {
        let pair = try await Pair()
        let rule = recordID("rule.4f2a9c")
        let values: [String: CloudValue] = ["kind": "sender", "value": "news@example.test", "effect": "important"]
        try await pair.a.edit(rule, type: "ImportanceRule", values)
        pair.later()
        try await pair.b.edit(rule, type: "ImportanceRule", values)
        await pair.a.sync.send()
        pair.keychain.deliver()
        await pair.b.sync.send()
        await pair.a.sync.sync()

        #expect(pair.account.records(in: workZone).count == 1)
        #expect(await pair.a.local.values(rule) == values)
        #expect(await pair.b.local.values(rule) == values)
        #expect(await pair.a.sync.document(rule) == pair.b.sync.document(rule))
        #expect(await pair.a.sync.pendingUploadCount() == 0)
        #expect(await pair.b.sync.pendingUploadCount() == 0)
    }

    @Test func concurrentEditsOfASplitMergeFieldByField() async throws {
        let pair = try await Pair()
        let split = recordID("split.6b1d")
        try await pair.a.edit(split, ["name": "Team", "rule": "label:team", "enabled": true, "order": 1])
        await pair.share()
        #expect(await pair.b.local.values(split)?["name"] == "Team")

        pair.later()
        try await pair.a.edit(split, ["name": "Team mail", "rule": "label:team", "enabled": true, "order": 1])
        pair.later()
        try await pair.b.edit(split, ["name": "Team", "rule": "label:team", "enabled": false, "order": 1])
        await pair.a.sync.sync()
        await pair.b.sync.sync()
        await pair.a.sync.sync()

        let expected: [String: CloudValue] = ["name": "Team mail", "rule": "label:team", "enabled": false, "order": 1]
        #expect(await pair.a.local.values(split) == expected)
        #expect(await pair.b.local.values(split) == expected)
        #expect(pair.account.records(in: workZone).count == 1)
    }

    @Test func aTombstoneBeatsAnOlderEdit() async throws {
        let pair = try await Pair()
        let split = recordID("split.receipts")
        try await pair.a.edit(split, ["name": "Receipts", "enabled": true])
        await pair.share()

        pair.later()
        try await pair.b.edit(split, ["name": "Receipts 2026", "enabled": true])
        pair.later()
        try await pair.a.edit(split, nil)
        await pair.a.sync.sync()
        await pair.b.sync.sync()
        await pair.a.sync.sync()

        #expect(await pair.a.local.values(split) == nil)
        #expect(await pair.b.local.values(split) == nil)
        let server = try #require(pair.account.record(split))
        #expect(server.deleted)
        #expect(await pair.b.sync.pendingUploadCount() == 0)
    }

    @Test func aNewerEditRevivesADeletedItem() async throws {
        let pair = try await Pair()
        let split = recordID("split.travel")
        try await pair.a.edit(split, ["name": "Travel", "enabled": true])
        await pair.share()

        pair.later()
        try await pair.a.edit(split, nil)
        await pair.a.sync.sync()
        pair.later()
        try await pair.b.edit(split, ["name": "Travel plans", "enabled": true])
        await pair.b.sync.sync()
        await pair.a.sync.sync()

        let expected: [String: CloudValue] = ["name": "Travel plans", "enabled": true]
        #expect(await pair.a.local.values(split) == expected)
        #expect(await pair.b.local.values(split) == expected)
        #expect(pair.account.record(split)?.deleted == false)
    }

    @Test func aSaveOnAStaleCopyMergesWithTheServerAndSavesOnTop() async throws {
        let pair = try await Pair()
        let split = recordID("split.bills")
        try await pair.a.edit(split, ["name": "Bills", "enabled": true, "order": 3])
        await pair.share()

        pair.later()
        try await pair.a.edit(split, ["name": "Bills and receipts", "enabled": true, "order": 3])
        await pair.a.sync.send()
        pair.later()
        try await pair.b.edit(split, ["name": "Bills", "enabled": false, "order": 3])
        await pair.b.sync.send()

        let merged: [String: CloudValue] = ["name": "Bills and receipts", "enabled": false, "order": 3]
        #expect(await pair.b.local.values(split) == merged)
        #expect(await pair.b.sync.diagnostics().contains { $0.kind == .conflictMerged })
        #expect(await pair.b.sync.pendingUploadCount() == 0)
        await pair.a.sync.sync()
        #expect(await pair.a.local.values(split) == merged)
        #expect(await pair.a.sync.document(split) == pair.b.sync.document(split))
    }

    @Test func aDeletedZoneStopsSyncButKeepsLocalData() async throws {
        let pair = try await Pair()
        let split = recordID("split.family")
        try await pair.a.edit(split, ["name": "Family"])
        await pair.share()

        try await pair.a.sync.deleteCloudData(zones: [workZone])
        #expect(await pair.a.sync.status == .deletedHere)
        #expect(pair.account.zoneIDs.isEmpty)

        pair.later()
        try await pair.b.edit(split, ["name": "Family and friends"])
        await pair.b.sync.sync()
        #expect(await pair.b.sync.status == .deletedElsewhere)
        #expect(await pair.b.sync.zoneState(workZone) == .deletedRemotely)
        #expect(await pair.b.sync.pendingUploadCount() == 0)
        #expect(pair.account.zoneIDs.isEmpty)
        #expect(await pair.b.local.values(split) == ["name": "Family and friends"])
        #expect(await pair.b.sync.diagnostics().contains { $0.kind == .zoneDeleted && $0.code == "deleted.account" })

        #expect(await pair.b.sync.resume() == .running)
        await pair.b.sync.sync()
        let restored = try #require(pair.account.record(split))
        #expect(!restored.deleted)
    }

    @Test func anAccountSwitchDropsTheOutbox() async throws {
        let clock = TestClock()
        let first = FakeCloudAccount()
        let second = FakeCloudAccount()
        let device = try TestDevice("A", account: first, keychain: FakeSyncedKeychain(), clock: clock)
        await device.sync.start()
        let setting = recordID("s.undo_send_seconds", zone: .app)
        try await device.edit(setting, type: "Setting", ["value": 10])
        #expect(await device.sync.pendingUploadCount() == 1)

        await device.cloud.switchAccount(to: second)
        #expect(await device.sync.status == .needsConsent(.switchAccounts))
        #expect(await device.sync.pendingUploadCount() == 0)
        await device.sync.sync()
        #expect(first.zoneIDs.isEmpty)
        #expect(second.zoneIDs.isEmpty)
        #expect(await device.local.values(setting) == ["value": 10])
        #expect(await device.sync.diagnostics().contains { $0.kind == .accountChanged && $0.code == "switchAccounts" })

        #expect(await device.sync.resume() == .running)
        await device.sync.sync()
        #expect(second.record(setting) != nil)
        #expect(first.record(setting) == nil)
    }

    @Test func aKeyRaceKeepsBothKeysAndConvergesOnTheSmallestID() async throws {
        let pair = try await Pair(keyA: "key-2", keyB: "key-1")
        let first = recordID("split.first")
        let second = recordID("split.second")
        try await pair.a.edit(first, ["name": "Alpha"])
        try await pair.b.edit(second, ["name": "Beta"])
        await pair.a.sync.sync()
        await pair.b.sync.sync()
        await pair.a.sync.sync()
        #expect(pair.account.record(first)?.keyID == "key-2")
        #expect(pair.account.record(second)?.keyID == "key-1")
        #expect(await pair.a.local.values(second) == nil)
        #expect(await pair.b.local.values(first) == nil)

        pair.keychain.deliver()
        #expect(pair.keychain.keyIDs(on: "A") == ["key-1", "key-2"])
        #expect(pair.keychain.keyIDs(on: "B") == ["key-1", "key-2"])
        await pair.a.sync.sync()
        await pair.b.sync.sync()
        #expect(await pair.a.local.values(second) == ["name": "Beta"])
        #expect(await pair.b.local.values(first) == ["name": "Alpha"])

        pair.later()
        try await pair.a.edit(first, ["name": "Alpha 2"])
        try await pair.b.edit(second, ["name": "Beta 2"])
        await pair.a.sync.sync()
        await pair.b.sync.sync()
        #expect(pair.account.record(first)?.keyID == "key-1")
        #expect(pair.account.record(second)?.keyID == "key-1")
        #expect(await pair.a.sync.knownKeyIDs() == ["key-1", "key-2"])
        #expect(await pair.b.sync.knownKeyIDs() == ["key-1", "key-2"])
    }

    @Test func aRecordUnderAnUnknownKeyWaitsForTheKey() async throws {
        let pair = try await Pair()
        let split = recordID("split.waiting")
        try await pair.a.edit(split, ["name": "First"])
        await pair.a.sync.sync()
        await pair.b.sync.sync()
        #expect(await pair.b.local.values(split) == nil)
        #expect(await pair.b.sync.document(split) == nil)
        #expect(await pair.b.sync.waitingRecordCount() == 1)
        #expect(await pair.b.sync.diagnostics().contains { $0.kind == .waitingForKey && $0.count == 1 })

        pair.later()
        try await pair.a.edit(split, ["name": "Newer"])
        await pair.a.sync.sync()
        await pair.b.sync.sync()
        #expect(await pair.b.sync.waitingRecordCount() == 1)
        #expect(await pair.b.local.applied.isEmpty)

        pair.keychain.deliver()
        await pair.b.sync.sync()
        #expect(await pair.b.local.values(split) == ["name": "Newer"])
        #expect(await pair.b.sync.waitingRecordCount() == 0)
        #expect(await pair.b.local.applied.count == 1)
        #expect(await pair.b.sync.diagnostics().contains { $0.kind == .keyArrived })
    }

    @Test func limitExceededSplitsBatchesUntilTheServerAccepts() async throws {
        let pair = try await Pair()
        pair.account.setLimits(FakeCloudAccount.Limits(maxRecordsPerRequest: 3))
        for index in 0..<10 {
            try await pair.a.edit(recordID("split.\(index)"), ["name": .string("Split \(index)")])
        }
        await pair.a.sync.sync()

        #expect(pair.account.records(in: workZone).count == 10)
        #expect(pair.account.requests.map(\.count) == [10, 5, 2, 2, 2, 2, 2])
        #expect(await pair.a.sync.pendingUploadCount() == 0)
        #expect(await pair.a.sync.diagnostics().filter { $0.kind == .batchSplit }.map(\.count) == [5, 2])
    }

    @Test func aRecordTooLargeForARequestMovesToAnAsset() async throws {
        let pair = try await Pair()
        pair.account.setLimits(FakeCloudAccount.Limits(maxBytesPerRequest: 4_000))
        let snippet = recordID("s.signature")
        try await pair.a.edit(snippet, type: "Setting", ["body": .string(String(repeating: "x", count: 6_000))])
        await pair.a.sync.sync()

        let stored = try #require(pair.account.record(snippet))
        guard case .asset = stored.payload else {
            Issue.record("expected an asset payload")
            return
        }
        #expect(pair.account.requests.map(\.outcome) == [.limitExceeded, .accepted])
        #expect(await pair.a.sync.diagnostics().contains { $0.kind == .payloadMovedToAsset })
    }

    @Test func anEditMadeDuringAnUploadIsSentAfterIt() async throws {
        let pair = try await Pair()
        let split = recordID("split.inflight")
        try await pair.a.edit(split, ["name": "Draft"])
        let gate = pair.a.cloud.suspendNextUpload()
        let sync = pair.a.sync
        async let uploading: Void = sync.send()
        await gate.reached()
        pair.later()
        try await pair.a.edit(split, ["name": "Final"])
        gate.release()
        await uploading

        #expect(pair.account.requests.count == 2)
        #expect(await pair.a.sync.pendingUploadCount() == 0)
        pair.keychain.deliver()
        await pair.b.sync.sync()
        #expect(await pair.b.local.values(split) == ["name": "Final"])
    }

    @Test func expiredTombstonesAreRemovedForGood() async throws {
        let pair = try await Pair()
        let split = recordID("split.old")
        try await pair.a.edit(split, ["name": "Old"])
        await pair.share()
        pair.later()
        try await pair.a.edit(split, nil)
        await pair.a.sync.sync()
        await pair.b.sync.sync()
        #expect(await pair.b.local.values(split) == nil)
        #expect(pair.account.record(split)?.deleted == true)

        pair.clock.advance(by: .seconds(91 * 86_400))
        await pair.a.sync.stop()
        await pair.a.sync.start()
        await pair.a.sync.sync()
        #expect(pair.account.record(split) == nil)
        #expect(await pair.a.sync.document(split) == nil)
        await pair.b.sync.sync()
        #expect(await pair.b.sync.document(split) == nil)
    }

    @Test func diagnosticsNameNoRecordsZonesOrAddresses() async throws {
        let pair = try await Pair()
        let split = recordID("split.private-note")
        try await pair.a.edit(split, ["name": "Private note", "enabled": true])
        await pair.a.sync.sync()
        await pair.b.sync.sync()
        pair.keychain.deliver()
        await pair.b.sync.sync()
        pair.later()
        try await pair.a.edit(split, ["name": "Private note 2", "enabled": true])
        await pair.a.sync.send()
        pair.later()
        try await pair.b.edit(split, ["name": "Private note", "enabled": false])
        await pair.b.sync.send()
        try await pair.a.sync.deleteCloudData(zones: [workZone])
        await pair.b.sync.sync()

        let entries = await pair.a.sync.diagnostics() + pair.b.sync.diagnostics()
        #expect(entries.contains { $0.kind == .conflictMerged })
        #expect(entries.contains { $0.kind == .waitingForKey })
        #expect(entries.contains { $0.kind == .zoneDeleted })
        for entry in entries {
            let text = (entry.kind.rawValue + " " + (entry.code ?? "")).lowercased()
            for secret in ["private", "someone", "example", workZone.name, "split.", "device-"] {
                #expect(!text.contains(secret.lowercased()))
            }
        }
    }
}
