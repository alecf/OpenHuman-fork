import Foundation
import MailFeatures
import Testing

struct BuildLabelTests {
    @Test func anEarlyDevelopmentBuildSaysSo() {
        let label = BuildLabel(infoDictionary: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1001",
                                                "OHReleaseChannel": "early-development"])
        #expect(label == BuildLabel(version: "0.1.0", build: "1001", channel: "early-development"))
        #expect(label.isEarlyDevelopment)
        #expect(label.versionLine == "Version 0.1.0 (1001)")
        #expect(label.notice == "Early development build — expect rough edges. Please send feedback.")
    }

    @Test func otherChannelsShowNoNotice() {
        for channel in ["", "stable", "Early-Development", "early-development-x"] {
            let label = BuildLabel(version: "1.0.0", build: "7", channel: channel)
            #expect(!label.isEarlyDevelopment, "\(channel)")
            #expect(label.notice == nil, "\(channel)")
        }
    }

    @Test func missingOrEmptyKeysFallBack() {
        let label = BuildLabel(infoDictionary: ["CFBundleShortVersionString": "", "OHReleaseChannel": 3])
        #expect(label == BuildLabel(version: "0", build: "0", channel: ""))
        #expect(label.versionLine == "Version 0 (0)")
        #expect(label.notice == nil)
    }

    @Test func surroundingWhitespaceIsIgnored() {
        let label = BuildLabel(infoDictionary: ["CFBundleShortVersionString": " 0.2.0\n", "CFBundleVersion": "12",
                                                "OHReleaseChannel": " early-development "])
        #expect(label.version == "0.2.0")
        #expect(label.isEarlyDevelopment)
    }
}
