import Foundation
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@Suite struct ThreadListTailTests {
    private static let start = Date(timeIntervalSince1970: 1_791_000_000)

    private static func rows(_ count: Int, offset: Int = 0) -> [ThreadRow] {
        (0..<count).map { i in
            let n = offset + i
            let at = start.addingTimeInterval(-Double(n) * 60)
            return ThreadRow(id: ThreadKey(account: AccountID(1), rowID: Int64(n + 1), gmailThreadID: GmailThreadID("t\(n + 1)")),
                             subject: "Subject \(n)", snippet: "", participantsDisplay: "Sam", participants: [],
                             messageCount: 1, unreadCount: 0, draftCount: 0, attachmentCount: 0, isUnread: false,
                             isStarred: false, isImportant: false, userLabelIDs: [], lastMessageAt: at, sortAt: at)
        }
    }


    @Test func theSkeletonWaitsForTheSpinnerDelayAndNeverFollowsAFailure() {
        let delay = Duration.milliseconds(150)
        #expect(!ThreadListSkeleton.shows(pagingFailed: true, visibleFor: .seconds(5), delay: delay), "failed: no skeleton")
        #expect(!ThreadListSkeleton.shows(pagingFailed: false, visibleFor: nil, delay: delay), "nothing on screen yet")
        #expect(!ThreadListSkeleton.shows(pagingFailed: false, visibleFor: .milliseconds(100), delay: delay), "a fast load")
        #expect(ThreadListSkeleton.shows(pagingFailed: false, visibleFor: .milliseconds(150), delay: delay))
        #expect(ThreadListSkeleton.shows(pagingFailed: false, visibleFor: .seconds(2), delay: delay))
    }


    @Test func aTotalAboveTheRowsHeldMakesNoPlaceholdersWhenNothingIsLeftToLoad() {
        var assembler = ThreadListAssembler(sortsAscending: false)
        assembler.live = Self.rows(100)
        assembler.liveTotal = 105
        assembler.liveHasMore = false
        let snapshot = assembler.assemble().snapshot
        #expect(snapshot.rows.count == 100)
        #expect(snapshot.placeholderCount == 0 && !snapshot.hasMore)
    }

    @Test func aListPagedToItsEndMakesNoPlaceholders() {
        var assembler = ThreadListAssembler(sortsAscending: false)
        assembler.live = Self.rows(2_000)
        assembler.liveTotal = 2_500
        assembler.liveHasMore = true
        assembler.pages = [ThreadListPage(after: nil, rows: Self.rows(300, offset: 2_000), next: nil, generation: 0,
                                          fetchedAt: Self.start)]
        assembler.pagingFinished = true
        let snapshot = assembler.assemble().snapshot
        #expect(snapshot.rows.count == 2_300)
        #expect(snapshot.placeholderCount == 0 && !snapshot.hasMore)
    }

    @Test func aSourceThatCannotPageMakesNoPlaceholders() {
        var assembler = ThreadListAssembler(sortsAscending: false)
        assembler.live = Self.rows(200)
        assembler.liveTotal = 900
        assembler.liveHasMore = true
        assembler.pagingUnavailable = true
        #expect(assembler.assemble().snapshot.placeholderCount == 0)
    }

    @Test func moreToLoadKeepsPlaceholdersForTheRest() {
        var assembler = ThreadListAssembler(sortsAscending: false)
        assembler.live = Self.rows(200)
        assembler.liveTotal = 900
        assembler.liveHasMore = true
        let snapshot = assembler.assemble().snapshot
        #expect(snapshot.placeholderCount == 700 && snapshot.hasMore)
    }
}
