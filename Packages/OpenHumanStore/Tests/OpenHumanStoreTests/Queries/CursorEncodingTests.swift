import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanStore

@Suite struct CursorEncodingTests {
    @Test func singleAccountCursorRoundTrips() {
        for cursor in [ThreadCursor(sortAt: 1_790_000_000_000, tid: 42), ThreadCursor(sortAt: 0, tid: 1),
                       ThreadCursor(sortAt: -5, tid: Int64.max), ThreadCursor(sortAt: Int64.min, tid: 0)] {
            #expect(ThreadCursor(encoded: cursor.encoded) == cursor)
        }
    }

    @Test func unifiedCursorRoundTripsAndIsCanonical() {
        let cursor = ThreadCursor(sortAt: 9, tid: 3, perAccount: [
            AccountID(2): ThreadCursorPosition(sortAt: 8, tid: 7), AccountID(1): ThreadCursorPosition(sortAt: 9, tid: 3)])
        #expect(ThreadCursor(encoded: cursor.encoded) == cursor)
        let again = ThreadCursor(sortAt: 9, tid: 3, perAccount: [
            AccountID(1): ThreadCursorPosition(sortAt: 9, tid: 3), AccountID(2): ThreadCursorPosition(sortAt: 8, tid: 7)])
        #expect(cursor.encoded == again.encoded)
    }

    @Test func encodingIsURLSafeWithoutPadding() {
        for tid in Int64(0)..<200 {
            let text = ThreadCursor(sortAt: 1_790_000_000_000 + tid * 7919, tid: tid * 104_729).encoded
            #expect(!text.contains("+") && !text.contains("/") && !text.contains("="))
        }
    }

    @Test func malformedTextIsRejected() {
        func b64(_ text: String) -> String {
            Data(text.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let bad = ["", "!!!", "abc def", "====", b64(""), b64("12"), b64("a:b"), b64("1:2:"), b64("1:2:x"), b64("1:2:3=4"),
                   b64("1:2:3=4.5.6"), b64("1:2:3=4.5:3=6.7"), b64("+1:2"), b64("01:2"), b64("1:2:03=4.5"), b64("1: 2")]
        for text in bad { #expect(ThreadCursor(encoded: text) == nil, "\(text)") }
        #expect(ThreadCursor(encoded: Data("1:23".utf8).base64EncodedString()) == nil)
    }

    @Test func aCursorFromTheStoreResumesThePage() throws {
        let (store, account) = try OpenHumanStoreTestingBridge.seeded(count: 30)
        let first = try store.threadPage(view: .system(account, .inbox), after: nil, limit: 10)
        let token = try #require(first.nextCursor).encoded
        let second = try store.threadPage(view: .system(account, .inbox), after: ThreadCursor(encoded: token), limit: 10)
        #expect(second.items.first?.id != first.items.last?.id)
        #expect(Set(first.items.map(\.id)).isDisjoint(with: second.items.map(\.id)))
    }
}
