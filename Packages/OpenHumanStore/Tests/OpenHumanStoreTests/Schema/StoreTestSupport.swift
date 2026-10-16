import Foundation
import GRDB
import OpenHumanCore
import Testing
@testable import OpenHumanStore

func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("oh-store-\(UUID().uuidString)")
}

@discardableResult
func openTemp(kind: ProcessKind = .test, readOnly: Bool = false, observe: Bool = false,
              dir: URL? = nil, notificationName: String = OHIdentifiers.storeChangedNotification,
              pollOnly: Bool = false) throws -> (store: MailStore, dir: URL) {
    let directory = dir ?? tempDirectory()
    let store = try MailStore.open(StoreOptions(location: StoreLocation(directory: directory), processKind: kind,
                                                readOnly: readOnly, observeExternalChanges: observe,
                                                appVersion: "0.0.0-test",
                                                changeNotificationName: notificationName, pollOnly: pollOnly))
    return (store, directory)
}

func changeFeedSeq(_ store: MailStore, writer: String? = nil) throws -> Int64 {
    try store.read { db in
        try Int64.fetchOne(db, sql: "SELECT seq FROM change_feed WHERE writer_id = ?", arguments: [writer ?? store.writerID]) ?? -1
    }
}

func pulseSeq(_ store: MailStore) throws -> Int64 {
    try store.read { try Int64.fetchOne($0, sql: "SELECT seq FROM observation_pulse WHERE id = 1") ?? -1 }
}

func helperURL() -> URL? {
    var candidates: [URL] = []
    candidates.append(Bundle(for: HelperProcess.self).bundleURL.deletingLastPathComponent())
    for bundle in Bundle.allBundles { candidates.append(bundle.bundleURL.deletingLastPathComponent()) }
    candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
    let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    for relative in [".build/out/Products/Debug", ".build/debug", ".build/arm64-apple-macosx/debug"] {
        candidates.append(packageRoot.appendingPathComponent(relative))
    }
    for dir in candidates {
        let url = dir.appendingPathComponent("ohstore-helper")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
    }
    return nil
}

// `Process.waitUntilExit()` can miss the exit of a fast child; use a termination handler plus a hard timeout
final class ProcessExit: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    func attach(to process: Process) { process.terminationHandler = { [done] _ in done.signal() } }
    func wait(_ process: Process, timeout: TimeInterval = 30, _ what: String = "child process") -> Bool {
        if done.wait(timeout: .now() + timeout) == .success { return true }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        Issue.record("\(what) (pid \(process.processIdentifier)) did not exit within \(Int(timeout)) s; killed")
        return false
    }
}

final class HelperProcess {
    let process = Process()
    private let out = Pipe()
    private let err = Pipe()
    private let input = Pipe()
    private let exit = ProcessExit()

    init(_ arguments: [String]) throws {
        let url = try #require(helperURL(), "ohstore-helper not found next to the test bundle")
        process.executableURL = url
        process.arguments = arguments
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        exit.attach(to: process)
        try process.run()
    }

    func waitFor(_ expected: String) -> Bool {
        var buffer = Data()
        let handle = out.fileHandleForReading
        let watchdog = DispatchWorkItem { [process] in if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { return false }
            buffer.append(chunk)
            if String(decoding: buffer, as: UTF8.self).split(separator: "\n").contains(Substring(expected)) { return true }
        }
    }

    func closeInput() { try? input.fileHandleForWriting.close() }
    func finish() -> Int32 {
        guard exit.wait(process, timeout: 30, "ohstore-helper") else { return -1 }
        return process.terminationStatus
    }
    var stderrText: String { String(decoding: err.fileHandleForReading.availableData, as: UTF8.self) }
}
