import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanStore

@Suite struct StoreFilePolicyTests {
    private let container = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/SYNTHETIC/Library/Application Support",
                                isDirectory: true)

    @Test func thePhoneStoreLivesInTheAppContainersApplicationSupport() {
        let location = StoreLocation.resolve(home: nil, files: .phone, applicationSupport: container)
        #expect(location.directory.path == container.path + "/OpenHuman/Mail")
        #expect(location.databaseURL.path == container.path + "/OpenHuman/Mail/mail.sqlite")
        #expect(location.files == .phone)

        let developer = StoreLocation.resolve(home: "/tmp/oh-dev-home", files: .phone, applicationSupport: container)
        #expect(developer.directory.path == "/tmp/oh-dev-home")
        #expect(developer.files == .phone, "a development home keeps the platform's file policy")
    }

    @Test func theHomeOverrideNeverAsksForApplicationSupport() throws {
        struct Unreachable: Error {}
        func support() throws -> URL { throw Unreachable() }
        let location = try StoreLocation.resolve(home: "/tmp/oh-dev-home", files: .standard, applicationSupport: try support())
        #expect(location.directory.path == "/tmp/oh-dev-home")
    }

    @Test func thePhoneProtectsAndExcludesTheStoreAndItsSidecars() {
        #expect(StoreFilePolicy.phone == StoreFilePolicy(protection: .untilFirstUnlock, excludesStoreFromBackup: true))
        let location = StoreLocation.resolve(home: nil, files: .phone, applicationSupport: container)
        let everything: Set<String> = ["Mail", "Attachments", "Drafts", "Logs", "mail.sqlite", "mail.sqlite-wal",
                                       "mail.sqlite-shm"]
        #expect(Set(location.backupExclusions.map(\.lastPathComponent)) == everything)
        #expect(Set(location.protectedItems.map(\.lastPathComponent)) == everything)
        #expect(location.backupExclusions.allSatisfy { $0.path.hasPrefix(location.directory.path) })
    }

    @Test func theMacKeepsItsBackupsAndProtectionAsBefore() {
        #if os(macOS)
        #expect(StoreFilePolicy.platformDefault == .standard)
        #expect(StoreLocation(directory: container).files == .standard)
        #endif
        let location = StoreLocation.resolve(home: nil, files: .standard, applicationSupport: container)
        #expect(location.backupExclusions == [location.attachmentsDirectory])
        #expect(location.protectedItems.isEmpty)
    }

    #if canImport(Darwin)
    @Test func openingAPhoneStoreExcludesItsDirectoryAndDatabaseFromBackups() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: dir, files: .phone),
                                                    processKind: .app, appVersion: "0.0.0-test"))
        _ = try store.addAccount(email: "me@example.com", displayName: nil, scopes: [])
        let location = store.location
        func excluded(_ url: URL) throws -> Bool {
            try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
        }
        for url in [location.directory, location.attachmentsDirectory, location.draftsDirectory, location.logsDirectory,
                    location.databaseURL] {
            #expect(try excluded(url), "\(url.lastPathComponent)")
        }
        try store.close()
        #expect(try excluded(location.databaseURL))
    }
    #endif
}
