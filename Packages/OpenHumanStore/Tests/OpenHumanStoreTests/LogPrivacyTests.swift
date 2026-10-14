import Foundation
import GRDB
import Testing
@testable import OpenHumanStore

@Suite struct LogPrivacyTests {
    @Test func noLogStatementInterpolatesARawError() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        let logCall = try Regex(#"((^|[^A-Za-z0-9_])log|Log\([^)]*\))\s*\.\s*(debug|info|notice|error|fault)\("#)
        let rawError = try Regex(#"\\\((error|failure)\)|describing:\s*(error|failure)\b|localizedDescription"#)
        var statements = 0
        var offenders: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                guard let match = line.firstMatch(of: logCall) else { continue }
                statements += 1
                var text = String(line[match.range.lowerBound...])
                var depth = 0, next = index
                while true {
                    depth += text.filter { $0 == "(" }.count - text.filter { $0 == ")" }.count
                    if text.contains(rawError) { offenders.append("\(file.lastPathComponent):\(index + 1)") }
                    next += 1
                    guard depth > 0, next < lines.count else { break }
                    text = lines[next]
                }
            }
        }
        #expect(statements > 5)
        #expect(offenders.isEmpty, "raw error descriptions logged: \(offenders)")
    }

    @Test func theLogCodeCarriesNoText() {
        let secret = "Synthetic subject 7f3a"
        let database = DatabaseError(resultCode: .SQLITE_CONSTRAINT, message: "UNIQUE failed: \(secret)",
                                     sql: "INSERT INTO drafts (subject) VALUES (?)", arguments: [secret])
        #expect(storeLogCode(database) == "sqlite \(ResultCode.SQLITE_CONSTRAINT.rawValue)")
        #expect(storeLogCode(StoreError.conflict(secret)) == "StoreError")
        struct Other: Error { let text: String }
        #expect(storeLogCode(Other(text: secret)) == "Other")
        for error: any Error in [database, StoreError.notFound(secret), Other(text: secret)] {
            #expect(!storeLogCode(error).contains("7f3a"))
        }
    }
}
