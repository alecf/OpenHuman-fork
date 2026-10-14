import Foundation
import Synchronization
import Testing
@testable import OpenHumanCore

@Suite(.serialized) struct LogMirrorTests {
    @Test func mirrorReceivesRedactedLinesUntilRemoved() {
        let seen = Mutex<[Log.Record]>([])
        let marker = "mirror-\(UUID().uuidString)"
        Log.setMirror { record in
            guard record.message.contains(marker) else { return }
            seen.withLock { $0.append(record) }
        }
        Log(.sync).error("\(marker) token ya29.a0AfH6SMBx-y_z refresh=1//0gAbC end")
        Log.setMirror(nil)
        Log(.sync).error("\(marker) after removal")

        let records = seen.withLock { $0 }
        #expect(records.count == 1)
        #expect(records.first?.category == .sync)
        #expect(records.first?.level == "error")
        #expect(records.first?.message == "\(marker) token <redacted> refresh=<redacted> end")
    }
}
