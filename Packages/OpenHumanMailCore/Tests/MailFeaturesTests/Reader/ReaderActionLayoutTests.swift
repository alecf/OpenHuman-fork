import Foundation
import MailActions
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

struct ReaderActionLayoutTests {
    @Test func theRowHoldsDoneSnoozeAndRemind() {
        #expect(ReaderActions.primaryThreadActionIDs == [.markDone, .snooze, .remind])
    }

    @Test func labelAndTrashAreInTheMoreMenusConversationSection() {
        let sections = ReaderActions.moreMenuSections
        #expect(sections.count == 3)
        let conversation = sections[1].map(\.id)
        #expect(conversation.contains(.label), "Label… is in ⋯")
        #expect(conversation.contains(.trash), "Trash is in ⋯")
        for id in ReaderActions.primaryThreadActionIDs {
            #expect(!sections.joined().contains { $0.id == id }, "\(id.rawValue) is on the row, not repeated in ⋯")
        }
    }

    @Test func previousAndNextHaveSymbolsAndAreNotThreadActions() {
        #expect(ReaderActions.navigationActionIDs == [.previousThread, .nextThread])
        #expect(ReaderActions.symbol(for: .previousThread) == "chevron.up")
        #expect(ReaderActions.symbol(for: .nextThread) == "chevron.down")
        for id in ReaderActions.navigationActionIDs {
            let descriptor = ActionCatalog.all.first { $0.id == id }
            #expect(descriptor?.scopes.contains(.reader) == true, "\(id.rawValue) works in a conversation")
            #expect(descriptor?.category == .navigation)
            #expect(descriptor?.changesMail == false, "\(id.rawValue) never changes mail (enabled in read-only safe mode)")
            #expect(!ReaderActions.threadActions.contains { $0.id == id })
            #expect(!ReaderActions.moreMenuSections.joined().contains { $0.id == id })
        }
        #expect(ReaderActions.navigationActions.map(\.id) == ReaderActions.navigationActionIDs)
    }

    @Test func readOnlySafeModeLeavesTheArrowsEnabled() throws {
        let thread = ThreadKey(account: AccountID(1), rowID: 1, gmailThreadID: GmailThreadID("t1"))
        var context = ActionContext(accountCount: 1, location: .system(.inbox))
        context.scope = .reader
        context.selection = [thread]
        context.focusedThread = thread
        context.safeMode = .readOnly
        for descriptor in ReaderActions.navigationActions {
            #expect(ActionRules.availability(descriptor, in: context) == .enabled, "\(descriptor.id.rawValue)")
        }
        let done = try #require(ActionCatalog.descriptor(.markDone))
        #expect(ActionRules.availability(done, in: context) == .disabled(.safeMode), "the rule applies here")
    }
}
