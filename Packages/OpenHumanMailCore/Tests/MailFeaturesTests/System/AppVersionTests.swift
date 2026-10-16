import Foundation
import Testing
@testable import MailFeatures

@Suite struct AppVersionTests {
    func v(_ text: String, build: String? = nil) throws -> AppVersion { try #require(AppVersion(text, build: build), "\(text)") }

    @Test(arguments: [
        ("0.1.0", "0.1.1"), ("0.1.1", "0.2.0"), ("0.2.0", "1.0.0"), ("0.9.0", "0.10.0"), ("1.9.9", "1.10.0"),
        ("0.1.0-early", "0.1.0"), ("0.2.0-early.2", "0.2.0-early.10"), ("0.2.0-alpha", "0.2.0-beta"),
        ("0.2.0-1", "0.2.0-alpha"), ("0.2.0-early", "0.2.0-early.1"), ("0.1.0", "0.1.1-early"), ("0.1.0+1001", "0.1.0+1002"),
        ("0.2.0-rc.1+9", "0.2.0-rc.2+1"), ("0.1.9+9999", "0.2.0+1"),
    ])
    func theSecondIsNewer(_ pair: (String, String)) throws {
        let older = try v(pair.0), newer = try v(pair.1)
        #expect(newer.isNewer(than: older), "\(pair.1) > \(pair.0)")
        #expect(!older.isNewer(than: newer), "\(pair.0) < \(pair.1)")
        #expect(AppVersion.order(older, newer) == .orderedAscending && AppVersion.order(newer, older) == .orderedDescending)
    }

    @Test(arguments: [
        ("0.1.0", "v0.1.0"), ("0.1", "0.1.0"), ("1", "1.0.0"), (" V2.0.0 ", "2.0.0"), ("0.1.0", "0.1.0+abc.def"),
        ("0.1.0-early.1", "0.1.0-early.1"), ("0.1.0+7", "0.1.0"),
    ])
    func theseAreTheSameVersion(_ pair: (String, String)) throws {
        let a = try v(pair.0), b = try v(pair.1)
        #expect(AppVersion.order(a, b) == .orderedSame && AppVersion.order(b, a) == .orderedSame, "\(pair.0) = \(pair.1)")
    }

    @Test func theBuildNumberDecidesOnlyWhenBothSidesHaveOne() throws {
        let running = try v("0.1.0", build: "1001")
        #expect(running.build == 1001 && running.displayName == "0.1.0 (1001)")
        let newerBuild = try v("0.1.0+1002"), sameBuild = try v("0.1.0+1001"), olderBuild = try v("0.1.0+1000")
        let tagOnly = try v("v0.1.0")
        #expect(newerBuild.isNewer(than: running), "same version, newer build")
        #expect(!sameBuild.isNewer(than: running) && !running.isNewer(than: sameBuild), "same version, same build")
        #expect(running.isNewer(than: olderBuild))
        #expect(!tagOnly.isNewer(than: running) && !running.isNewer(than: tagOnly), "a tag without a build is the same release")
        #expect(try v("0.1.0+5", build: "6").build == 6, "the bundle's build number wins over the text")
        #expect(try v("0.1.0", build: "1.2").build == nil, "a build that is not a number is ignored")
        #expect(try v("0.1.0+sha.abc").build == nil)
    }

    @Test func textAndFlags() throws {
        let tagged = try v("v0.2.0-early.1+9"), short = try v("0.2"), early = try v("0.2.0-early"), release = try v("0.2.0")
        #expect(tagged.description == "0.2.0-early.1" && tagged.displayName == "0.2.0-early.1 (9)")
        #expect(short.description == "0.2.0" && short.displayName == "0.2.0")
        #expect(early.isPreRelease && !release.isPreRelease)
    }

    @Test(arguments: ["", "v", "V", "1.2.3.4", "1..2", ".1", "1.", "a.b.c", "1.2.x", "1.2.3-", "1.2.3+", "1.2.3-ab$", "-1.2.3",
                      "1.2.3-a..b", "1.2.3+a..b", "1234567890.0.0", "１.２.３", "1.2.3 beta", "OpenHuman Mail 0.1.0"])
    func malformedVersionsAreRejected(_ text: String) {
        #expect(AppVersion(text) == nil, "\(text)")
    }
}
