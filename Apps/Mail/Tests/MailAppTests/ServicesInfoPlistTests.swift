import Foundation
import MailUIMac
import Testing

@MainActor
@Test func theInfoPlistListsTheThreeServicesEntries() throws {
    let entries = try #require(Bundle.main.object(forInfoDictionaryKey: "NSServices") as? [[String: Any]])
    #expect(entries.count == 3)
    let messages = entries.compactMap { $0["NSMessage"] as? String }
    #expect(messages == MacServicesProvider.messages)
    let titles = entries.compactMap { ($0["NSMenuItem"] as? [String: String])?["default"] }
    #expect(titles == ["New Message in OpenHuman Mail", "New Message with Files in OpenHuman Mail",
                       "Search in OpenHuman Mail"])
    for entry in entries {
        #expect(entry["NSPortName"] as? String == "OpenHumanMail")
        #expect(entry["NSReturnTypes"] == nil && entry["NSKeyEquivalent"] == nil && entry["NSRestricted"] == nil)
        #expect(entry["NSSendTypes"] != nil || entry["NSSendFileTypes"] != nil)
    }
}

@MainActor
@Test func theAppIsNamedOpenHumanMailAndKeepsItsIdentifiers() throws {
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "OpenHuman Mail")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == "OpenHuman Mail")
    let id = try #require(Bundle.main.bundleIdentifier)
    #expect(id.hasSuffix(".mail"), "the bundle id keeps its form: \(id)")
    #expect(Bundle.main.bundleURL.lastPathComponent == "OpenHumanMail.app", "the built bundle keeps its file name")
    let urlTypes = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
    #expect(urlTypes.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("openhuman") == true })
}
