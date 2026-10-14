import Foundation
import Testing
@testable import OpenHumanCore

@Suite struct IdentifierTests {
    @Test func rawValueCodingIsSingleValue() throws {
        let data = try JSONEncoder().encode([GmailThreadID("abc")])
        #expect(String(decoding: data, as: UTF8.self) == "[\"abc\"]")
        let ids = try JSONDecoder().decode([AccountID].self, from: Data("[3,1]".utf8))
        #expect(ids.sorted() == [AccountID(1), AccountID(3)])
        #expect(HistoryID(5) < HistoryID(9))
    }

    @Test func sharedNamesUseConstantPrefix() {
        #expect(OHIdentifiers.prefix == "dev.openhuman.mail")
        #expect(OHIdentifiers.keychainService == "dev.openhuman.mail.oauth.v1")
        #expect(OHIdentifiers.storeChangedNotification == "dev.openhuman.mail.store.changed")
        #expect(OHIdentifiers.logSubsystem == "dev.openhuman.mail")
    }
}

@Suite struct Base64URLTests {
    @Test func roundTripAndTolerance() {
        let bytes = Data([0xfb, 0xff, 0xbf, 0x00, 0x10])
        let s = Base64URL.encode(bytes)
        #expect(!s.contains("+") && !s.contains("/") && !s.contains("="))
        #expect(Base64URL.decode(s) == bytes)
        #expect(Base64URL.decode(s + "=") == bytes)
        #expect(Base64URL.decode("aGVs\nbG8") == Data("hello".utf8))
        #expect(Base64URL.decode("a") == nil)
    }
}

@Suite struct RedactionTests {
    @Test(arguments: [
        ("token ya29.a0AfH6SMBx-y_z end", "token <redacted> end"),
        ("refresh=1//0gAbC-dEf_123 ok", "refresh=<redacted> ok"),
        ("Authorization: Bearer abc.def", "Authorization: Bearer <redacted>"),
        ("account_id=3 threads=50", "account_id=3 threads=50"),
        ("ya29. alone", "ya29. alone"),
        ("sendAs Dana.Ruiz+x@mail.example.com refused", "sendAs <email> refused"),
        ("path users/dana%40example.org/messages", "path users/<email>/messages"),
        ("from a@b.example.", "from <email>."),
        ("two a@x.example,b@y.example", "two <email>,<email>"),
        ("kept: @example.com a@b x@localhost 1@2", "kept: @example.com a@b x@localhost 1@2"),
    ])
    func redacts(input: String, expected: String) {
        #expect(Log.redact(input) == expected)
    }

    @Test func aTokenAndAnAddressInOneLine() {
        #expect(Log.redact("Bearer abc.def for me@example.com") == "Bearer <redacted> for <email>")
    }
}

@Suite struct TestClockTests {
    @Test func sleepersResumeInDeadlineOrder() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 0))
        let order = Order()
        async let a: Void = { try await clock.sleep(for: .seconds(30)); await order.add("a") }()
        async let b: Void = { try await clock.sleep(for: .seconds(10)); await order.add("b") }()
        while clock.sleeperCount < 2 { await Task.yield() }
        #expect(clock.nextDeadline == Date(timeIntervalSince1970: 10))
        clock.advance(by: .seconds(10))
        try await b
        #expect(await order.items == ["b"])
        #expect(clock.sleeperCount == 1)
        clock.advance(by: .seconds(20))
        try await a
        #expect(await order.items == ["b", "a"])
        #expect(clock.now == Date(timeIntervalSince1970: 30))
    }

    @Test func pastDeadlineReturnsImmediately() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        try await clock.sleep(until: Date(timeIntervalSince1970: 50))
        #expect(clock.sleeperCount == 0)
    }

    @Test func cancellationThrows() async {
        let clock = TestClock()
        let task = Task { try await clock.sleep(for: .seconds(60)) }
        while clock.sleeperCount < 1 { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(clock.sleeperCount == 0)
    }

    @Test func neverMovesBackwards() {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        clock.advance(to: Date(timeIntervalSince1970: 50))
        #expect(clock.now == Date(timeIntervalSince1970: 100))
    }

    actor Order {
        var items: [String] = []
        func add(_ s: String) { items.append(s) }
    }
}
