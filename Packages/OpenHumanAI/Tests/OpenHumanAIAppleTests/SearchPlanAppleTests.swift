import Foundation
import Testing

@testable import OpenHumanAI
@testable import OpenHumanAIApple

@Suite(.enabled(if: systemModelIsAvailable, "needs the Apple system model")) struct SearchPlanAppleTests {
    @available(macOS 27, iOS 27, *)
    @Test func theSystemModelPlansASearchOnThisMac() async throws {
        let features = makeFeatures([AppleSystemProvider(source: SystemModelSource())])
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await features.planSearch("invoices from Sarah last month", accountKey: nil)
        print("apple.system search plan: \(clock.now - start)")
        #expect(result.provenance.providerID == .appleSystem)
        #expect(result.provenance.dataLocation == .onDevice)
        #expect(result.plan.keywords.count <= AIPolicy.searchPlanMaxKeywords)
        #expect(result.plan.from.count <= AIPolicy.searchPlanMaxPeople)
        if result.plan.timeframe.needsCount { #expect(result.plan.count != nil) }
    }
}
