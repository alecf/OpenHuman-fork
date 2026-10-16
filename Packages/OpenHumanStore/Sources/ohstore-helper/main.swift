import Foundation
import GRDB
import OpenHumanCore
import OpenHumanStore

func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func fail(_ message: String, code: Int32 = 70) -> Never {
    FileHandle.standardError.write(Data(("ohstore-helper: " + message + "\n").utf8))
    exit(code)
}

func usage() -> Never {
    fail("usage: [--home <dir>] hold-write <secs> | bump | hold-lease <account> | write-archive <dir> <tid>", code: 64)
}

var args = Array(CommandLine.arguments.dropFirst())
var home: String?
if let i = args.firstIndex(of: "--home") {
    guard i + 1 < args.count else { usage() }
    home = args[i + 1]
    args.removeSubrange(i...(i + 1))
}
guard let command = args.first else { usage() }

func location(_ override: String?) -> StoreLocation {
    if let override { return StoreLocation(directory: URL(fileURLWithPath: override, isDirectory: true)) }
    let home = ProcessInfo.processInfo.environment["OPENHUMAN_HOME"]
    do { return try StoreLocation.resolve(home: home) } catch { fail("cannot resolve the store location: \(error)") }
}

func openStore(_ loc: StoreLocation) -> MailStore {
    do {
        return try MailStore.open(StoreOptions(location: loc, processKind: .cli, appVersion: "0.0.0-helper"))
    } catch { fail("cannot open the store: \(error)") }
}

switch command {
case "hold-write":
    guard args.count == 2, let secs = Double(args[1]), secs >= 0 else { usage() }
    let loc = location(home)
    try? openStore(loc).close()
    do {
        var config = Configuration()
        config.busyMode = .timeout(5)
        let queue = try DatabaseQueue(path: loc.databaseURL.path, configuration: config)
        try queue.writeWithoutTransaction { db in
            try db.inTransaction(.immediate) {
                try db.execute(sql: "UPDATE observation_pulse SET seq = seq WHERE id = 1")
                say("ready")
                Thread.sleep(forTimeInterval: secs)
                return .commit
            }
        }
        say("done")
    } catch { fail("hold-write: \(error)") }

case "bump":
    guard args.count == 1 else { usage() }
    let store = openStore(location(home))
    do {
        _ = try store.addAccount(email: "bump-\(UUID().uuidString.prefix(8).lowercased())@example.com",
                                 displayName: nil, scopes: [])
        say("ready")
        try store.close()
        say("done")
    } catch { fail("bump: \(error)") }

case "hold-lease":
    guard args.count == 2, let raw = Int64(args[1]) else { usage() }
    let store = openStore(location(home))
    let account = AccountID(raw)
    do {
        let host = ProcessIdentity.localHostName
        let pid = ProcessInfo.processInfo.processIdentifier
        guard try store.acquireLease(account: account, ownerID: store.writerID, kind: "cli", pid: pid, host: host,
                                     now: Date(), ttl: .seconds(45)) != nil else {
            fail("lease for account \(raw) is held by another owner")
        }
        say("ready")
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler {
            _ = try? store.renewLease(account: account, ownerID: store.writerID, now: Date(), ttl: .seconds(45))
        }
        timer.resume()
        while FileHandle.standardInput.availableData.count > 0 {}
        timer.cancel()
        try store.releaseLease(account: account, ownerID: store.writerID)
        try store.close()
        say("done")
    } catch { fail("hold-lease: \(error)") }

case "write-archive":
    guard args.count == 3, let tid = Int64(args[2]) else { usage() }
    let store = openStore(location(args[1]))
    do {
        guard let detail = try store.threadDetail(ThreadRowID(rawValue: tid)) else { fail("no thread \(tid)") }
        _ = try store.apply(.archive([detail.thread.ref]), origin: .cli)
        say("ready")
        try store.close()
        say("done")
    } catch { fail("write-archive: \(error)") }

default:
    usage()
}
