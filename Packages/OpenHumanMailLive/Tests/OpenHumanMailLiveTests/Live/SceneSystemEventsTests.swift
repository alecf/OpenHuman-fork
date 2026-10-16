import Foundation
import OpenHumanSync
import SwiftUI
import Testing
@testable import OpenHumanMailLive

@Suite struct SceneSystemEventsTests {
    @Test func scenePhasesBecomeEngineEvents() async {
        let source = SceneSystemEvents(monitorsNetwork: false)
        source.scenePhaseChanged(to: .inactive)
        source.scenePhaseChanged(to: .background)
        source.scenePhaseChanged(to: .active)
        source.networkChanged(true)
        source.networkChanged(false)
        source.networkChanged(false)
        source.stop()

        var names: [String] = []
        for await event in source.events { names.append(String(describing: event)) }
        #expect(names == ["didResignActive", "didEnterBackground", "didBecomeActive", "networkReachable(false)"])
    }
}
