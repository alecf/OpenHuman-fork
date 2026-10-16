import Foundation
import Testing
@testable import OpenHumanCore

@Suite struct TemporaryDirectoryTests {
    @Test func theURLIsUniqueUnderTheTemporaryFolderAndNotCreated() {
        let first = TemporaryDirectory("oh-core-temp")
        let second = TemporaryDirectory("oh-core-temp", isDirectory: true)
        defer { first.cleanup(); second.cleanup() }
        #expect(first.url.deletingLastPathComponent().path == FileManager.default.temporaryDirectory.path)
        #expect(first.url.lastPathComponent.hasPrefix("oh-core-temp-"))
        #expect(first.url != second.url)
        #expect(!first.url.hasDirectoryPath)
        #expect(second.url.hasDirectoryPath)
        #expect(first.path == first.url.path)
        #expect(!FileManager.default.fileExists(atPath: first.path))
    }

    @Test func cleanupRemovesTheFolderAndItsContents() throws {
        let temp = TemporaryDirectory("oh-core-temp")
        defer { temp.cleanup() }
        try FileManager.default.createDirectory(at: temp.url.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: temp.url.appendingPathComponent("nested/file.txt"))
        temp.cleanup()
        #expect(!FileManager.default.fileExists(atPath: temp.path))
        temp.cleanup()
    }

    @Test func releasingItRemovesTheFolder() throws {
        var temp: TemporaryDirectory? = TemporaryDirectory("oh-core-temp")
        let path = try #require(temp?.path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        #expect(FileManager.default.fileExists(atPath: path))
        temp = nil
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aProcessScopedFolderRemovesOnlyTheOnesLeftByProcessesThatExited() throws {
        let root = TemporaryDirectory("oh-core-scoped")
        defer { root.cleanup() }
        let prefix = "OpenHumanTest-Scoped-"
        let exited = "\(prefix)111-\(UUID().uuidString)"
        let kept = ["\(prefix)222-\(UUID().uuidString)", "\(prefix)\(UUID().uuidString)", "\(prefix)0-\(UUID().uuidString)",
                    "\(prefix)333-notes", "Other-111-\(UUID().uuidString)"]
        for name in kept + [exited] {
            try FileManager.default.createDirectory(at: root.url.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        var asked: [pid_t] = []

        let fresh = TemporaryDirectory.processScoped(prefix, in: root.url) { pid in
            asked.append(pid)
            return pid == 222
        }

        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set(kept))
        #expect(Set(asked) == [111, 222])
        #expect(fresh.deletingLastPathComponent().path == root.path)
        #expect(fresh.lastPathComponent.hasPrefix("\(prefix)\(getpid())-"))
        #expect(UUID(uuidString: String(fresh.lastPathComponent.dropFirst("\(prefix)\(getpid())-".count))) != nil)
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        #expect(TemporaryDirectory.processIsRunning(getpid()))
    }
}
