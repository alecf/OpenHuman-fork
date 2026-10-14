import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailActions

@Suite struct InstantIntroTests {
    private func availability(_ scope: ActionScope) -> ActionAvailability {
        ActionRules.availability(ActionCatalog.descriptor(.instantIntro)!, in: ActionContext(scope: scope))
    }

    @Test func theKeyIsCommandShiftIInEveryWindowScope() throws {
        let descriptor = try #require(ActionCatalog.descriptor(.instantIntro))
        #expect(descriptor.defaultBindings.map(\.grammar) == ["⌘I"], "grammar: an uppercase letter is typed with shift, so this is ⇧⌘I (italic is ⌘i)")
        #expect(descriptor.defaultBindings.map(\.description) == ["⇧⌘I"])
        for scope in [ActionScope.list, .reader, .composer, .review, .calendar] {
            #expect(ActionRules.isInScope(descriptor, scope), "\(scope)")
        }
        #expect(descriptor.appearsInPalette == false && descriptor.appearsInMenu == false, "not offered until it works")
        #expect(descriptor.menuKeyEquivalent == nil, "the key router owns the chord")
    }

    @Test(arguments: [ActionScope.list, .reader, .review, .calendar])
    func outsideAComposerItSaysWhereItWorks(_ scope: ActionScope) {
        let result = availability(scope)
        #expect(result.reason?.description
            == "Instant Intro only works when you are writing a reply to an introduction", "\(scope)")
        #expect(result.reason?.announces == true, "\(scope): the key is consumed with a notice")
    }

    @Test func inAComposerTheCatalogAllowsItAndTheHandlerSaysItIsNotBuilt() {
        #expect(availability(.composer) == .enabled, "the handler has the last word")
        let notBuilt = DisabledReason.notBuilt("Instant Intro")
        #expect(notBuilt.description == "Instant Intro isn't built in OpenHuman Mail yet")
        #expect(notBuilt.announces)
    }

    @Test func noOtherCatalogEntryUsesTheSameKey() {
        let users = ActionCatalog.all.filter { descriptor in
            descriptor.defaultBindings.contains { $0.grammar == "⌘I" }
        }
        #expect(users.map(\.id) == [.instantIntro])
    }

    @Test func wrongContextReasonsAnnounceExceptTheOnesAViewAnswers() {
        #expect(DisabledReason.needs(action: "X", context: "Y").announces)
        #expect(DisabledReason.noSelection.announces)
        #expect(DisabledReason.other("x").announces == false)
        #expect(DisabledReason.nothingToRedo.announces == false)
    }
}
