import Foundation
import OpenHumanCore
import os

enum SyncSignposts {
    static let signposter = OSSignposter(subsystem: OHIdentifiers.logSubsystem, category: "sync")

    struct Interval {
        let name: StaticString
        let state: OSSignpostIntervalState
    }

    static func begin(_ name: StaticString) -> Interval {
        Interval(name: name, state: signposter.beginInterval(name, id: signposter.makeSignpostID()))
    }

    static func end(_ interval: Interval) {
        signposter.endInterval(interval.name, interval.state)
    }
}
