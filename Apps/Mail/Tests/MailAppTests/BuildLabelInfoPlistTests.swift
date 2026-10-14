import Foundation
import MailFeatures
import Testing

@Test func theBuiltAppIsMarkedAsAnEarlyDevelopmentBuild() {
    #expect(Bundle.main.object(forInfoDictionaryKey: "OHReleaseChannel") as? String == "early-development")
    #expect(BuildLabel.main.isEarlyDevelopment)
    #expect(BuildLabel.main.notice == BuildLabel.earlyDevelopmentNotice)
}
