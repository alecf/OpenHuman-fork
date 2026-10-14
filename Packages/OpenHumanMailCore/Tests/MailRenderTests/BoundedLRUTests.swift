import Foundation
import Testing
@testable import MailRender

@Suite struct BoundedLRUTests {
    @Test func theCountBoundEvictsTheLeastRecentlyUsed() {
        var cache = BoundedLRU<Int, String>(countLimit: 3)
        for i in 1...3 { cache.insert("v\(i)", for: i) }
        #expect(cache.value(for: 1) == "v1")
        cache.insert("v4", for: 4)
        #expect(cache.count == 3 && !cache.contains(2) && cache.contains(1) && cache.contains(3) && cache.contains(4))
    }

    @Test func theCostBoundHoldsAfterEveryInsert() {
        var cache = BoundedLRU<Int, Int>(countLimit: 1_000, costLimit: 64)
        for i in 0..<300 {
            cache.insert(i, for: i, cost: 10)
            #expect(cache.totalCost <= 64)
        }
        #expect(cache.contains(299), "the newest entry stays")
        #expect(cache.count == cache.totalCost / 10)
    }

    @Test func anEntryLargerThanTheCostBoundIsNotKeptAndReplacesNothingStale() {
        var cache = BoundedLRU<String, Int>(countLimit: 10, costLimit: 100)
        cache.insert(1, for: "a", cost: 40)
        cache.insert(2, for: "a", cost: 500)
        #expect(!cache.contains("a") && cache.totalCost == 0)
    }

    @Test func reinsertingAKeyReplacesItsCost() {
        var cache = BoundedLRU<String, Int>(countLimit: 10, costLimit: 100)
        cache.insert(1, for: "a", cost: 60)
        cache.insert(2, for: "a", cost: 30)
        #expect(cache.totalCost == 30 && cache.count == 1 && cache.peek("a") == 2)
    }

    @Test func fiftyThousandInsertsStayUnderTheCountBound() {
        var cache = BoundedLRU<Int, Double>(countLimit: 5_000)
        for i in 0..<50_000 {
            cache.insert(Double(i), for: i)
            #expect(cache.count <= 5_000)
        }
        #expect(cache.contains(49_999) && !cache.contains(0))
    }
}
