import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanSync

@Suite(.serialized) struct AutoLabelVisibilityTests {
    @Test func autoLabelsAreCreatedVisibleByDefaultAndHiddenWhenTheSwitchIsOff() {
        let before = AutoLabelVisibility.showInGmail
        defer { AutoLabelVisibility.showInGmail = before }
        AutoLabelVisibility.showInGmail = true
        #expect(LabelBook.visibility(for: "OpenHuman/Pitch") == ("labelShow", "show"))
        AutoLabelVisibility.showInGmail = false
        #expect(LabelBook.visibility(for: "OpenHuman/Pitch") == ("labelHide", "hide"))
    }

    @Test func scheduleStampsStayHiddenWhateverTheSwitchSays() {
        let before = AutoLabelVisibility.showInGmail
        defer { AutoLabelVisibility.showInGmail = before }
        AutoLabelVisibility.showInGmail = true
        #expect(LabelBook.visibility(for: "OpenHuman/Snoozed/20261012T0900Z") == ("labelHide", "hide"))
    }
}
