import Foundation
import Testing
@testable import OpenHumanCore

@Suite(.serialized) struct ScopedDefaultsTests {
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func stored(_ defaults: ScopedDefaults) throws -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: defaults.plist.path) else { return nil }
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    @Test func eachSuiteIsUniqueAndKeepsItsValues() throws {
        let first = ScopedDefaults("openhuman.test.scoped")
        let second = ScopedDefaults("openhuman.test.scoped")
        defer { first.cleanup(); second.cleanup() }
        let file = first.plist.lastPathComponent
        #expect(file.hasPrefix("openhuman.test.scoped.") && file.hasSuffix(".plist"))
        #expect(UUID(uuidString: String(file.dropFirst("openhuman.test.scoped.".count).dropLast(".plist".count))) != nil)
        #expect(first.name != second.name)
        first.set("kept", forKey: "value")
        #expect(first.string(forKey: "value") == "kept")
        #expect(second.string(forKey: "value") == nil)
        let reopened = try #require(UserDefaults(suiteName: first.name))
        #expect(reopened.string(forKey: "value") == "kept")
    }

    @Test func thePlistLivesInTheProcessFolderAndNotInPreferences() throws {
        let defaults = ScopedDefaults("openhuman.test.scoped")
        defer { defaults.cleanup() }
        defaults.set(true, forKey: "flag")
        let folder = defaults.plist.deletingLastPathComponent()
        #expect(folder.path == ScopedDefaults.folder.path)
        #expect(folder.deletingLastPathComponent().path == FileManager.default.temporaryDirectory.path) // temp-ok: compares paths only
        #expect(folder.lastPathComponent.hasPrefix("oh-defaults-\(getpid())-"))
        #expect(defaults.name == defaults.plist.deletingPathExtension().path)
        #expect(exists(defaults.plist))
        let library = try #require(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
        #expect(!exists(library.appendingPathComponent("Preferences/\(defaults.plist.lastPathComponent)")))
    }

    @Test func writesReachThePlistAtOnceSoNoneIsLeftToWriteLater() throws {
        let defaults = ScopedDefaults("openhuman.test.scoped")
        defer { defaults.cleanup() }
        defaults.set("kept", forKey: "value")
        #expect(try stored(defaults)?["value"] as? String == "kept")
        defaults.removePersistentDomain(forName: defaults.name)
        #expect(try stored(defaults)?.isEmpty == true)
    }

    @Test func cleanupRemovesTheDomainAndThePlist() throws {
        let defaults = ScopedDefaults("openhuman.test.scoped")
        defer { defaults.cleanup() }
        defaults.set(true, forKey: "flag")
        #expect(exists(defaults.plist))
        defaults.cleanup()
        #expect(defaults.object(forKey: "flag") == nil)
        #expect(!exists(defaults.plist))
        #expect(UserDefaults(suiteName: defaults.name)?.object(forKey: "flag") == nil)
        #expect(!exists(defaults.plist), "reading it back writes nothing")
    }

    @Test func releasingItRemovesItsPlist() throws {
        let (name, plist) = autoreleasepool { () -> (String, URL) in
            let defaults = ScopedDefaults("openhuman.test.scoped")
            defaults.set(true, forKey: "flag")
            #expect(exists(defaults.plist))
            return (defaults.name, defaults.plist)
        }
        #expect(!exists(plist))
        #expect(UserDefaults(suiteName: name)?.object(forKey: "flag") == nil)
        #expect(!exists(plist), "reading it back writes nothing")
    }

    @Test func atExitEverySuiteStillHeldIsEmptiedAndTheFolderRemoved() throws {
        let root = TemporaryDirectory("oh-core-defaults", isDirectory: true)
        defer { root.cleanup() }
        try FileManager.default.createDirectory(at: root.url, withIntermediateDirectories: true)
        autoreleasepool {
            let held = ScopedDefaults("openhuman.test.scoped", in: root.url)
            held.set("held", forKey: "value")
            #expect(exists(held.plist))
            ScopedDefaults.removeAll(in: root.url)
            #expect(!exists(root.url))
            #expect(held.object(forKey: "value") == nil)
        }
        #expect(!exists(root.url), "releasing the owner afterwards writes nothing")
    }
}
