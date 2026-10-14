import Foundation
import MailFeatures
import OpenHumanCore
import Testing
@testable import OpenHumanMail

@MainActor
@Suite(.serialized) struct FocusFilterIntentTests {
    @Test(arguments: [FocusOpenOnAppEnum.important, .inbox, .stay], [false, true])
    func performMapsTheParametersToTheState(_ openOn: FocusOpenOnAppEnum, _ flag: Bool) async throws {
        let recorder = RecordingIntents()
        IntentBridge.override = recorder
        defer { IntentBridge.override = nil }
        var filter = MailFocusFilter()
        filter.accounts = [AccountEntity(id: "2", title: "Personal"), AccountEntity(id: "not-an-id", title: "x"),
                           AccountEntity(id: "1", title: "Work")]
        filter.openOn = openOn
        filter.holdOtherNotifications = flag
        filter.badgeOnlyTheseAccounts = !flag
        _ = try await filter.perform()
        let expected = FocusFilterState(accounts: [AccountID(2), AccountID(1)], openOn: openOn.value,
                                        holdOtherNotifications: flag, badgeOnlyTheseAccounts: !flag)
        #expect(recorder.focusStates == [expected])
        #expect(openOn.value.rawValue == openOn.rawValue)
    }

    @Test func noAccountIsNoFilter() async throws {
        let recorder = RecordingIntents()
        IntentBridge.override = recorder
        defer { IntentBridge.override = nil }
        _ = try await MailFocusFilter().perform()
        var junk = MailFocusFilter()
        junk.accounts = [AccountEntity(id: "x", title: "x")]
        _ = try await junk.perform()
        #expect(recorder.focusStates == [nil, nil])
    }

    @Test func suggestionsAreOnePerAccount() async throws {
        let recorder = RecordingIntents()
        IntentBridge.override = recorder
        defer { IntentBridge.override = nil }
        let suggestions = await MailFocusFilter.suggestions()
        #expect(suggestions.count == 2)
        #expect(suggestions.map { $0.state?.accounts ?? [] } == [[AccountID(1)], [AccountID(2)]])
        #expect(suggestions.allSatisfy { $0.state?.openOn == .important })
        #expect(suggestions.allSatisfy { $0.state?.holdOtherNotifications == false && $0.state?.badgeOnlyTheseAccounts == false })
    }
}
