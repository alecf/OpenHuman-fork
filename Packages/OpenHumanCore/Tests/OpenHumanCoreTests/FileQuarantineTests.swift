import Foundation
import Testing
@testable import OpenHumanCore

@Suite struct FileQuarantineTests {
    @Test func theValueCarriesTheSharedFlagsTheTimeTheAgentAndAnEventID() {
        let value = FileQuarantine.value(now: Date(timeIntervalSince1970: 0x6500_0000))
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        #expect(parts.count == 4)
        #expect(parts[0] == FileQuarantine.flags && parts[0] == "0083")
        #expect(parts[1] == "65000000")
        #expect(parts[2] == "OpenHuman Mail" && parts[2] == FileQuarantine.agent)
        #expect(UUID(uuidString: parts[3]) != nil)
        #expect(FileQuarantine.value() != FileQuarantine.value(), "a new event id each time")
        #expect(FileQuarantine.attribute == "com.apple.quarantine")
    }

    #if canImport(Darwin)
    @Test func ensureSetsAValueOnlyWhenTheFileHasNone() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-quarantine-\(UUID().uuidString).txt")
        try Data("synthetic".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(FileQuarantine.read(file) == nil)
        try FileQuarantine.ensure(file)
        let first = try #require(FileQuarantine.read(file))
        #expect(first.hasPrefix(FileQuarantine.flags + ";"))
        try FileQuarantine.ensure(file)
        #expect(FileQuarantine.read(file) == first, "an existing value is kept")
        try FileQuarantine.write("0081;00000000;Other;x", to: file)
        try FileQuarantine.ensure(file)
        #expect(FileQuarantine.read(file) == "0081;00000000;Other;x")
    }
    #endif
}
