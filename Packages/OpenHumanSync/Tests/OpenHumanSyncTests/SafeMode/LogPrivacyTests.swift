import Foundation
import Testing

@Suite struct LogPrivacyTests {
    @Test func noLogLineInterpolatesARawError() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count > 20)
        let rawError = try Regex(#"(log|Log\([^)]*\))\s*\.\s*(debug|info|notice|error|fault)\(.*\\\(error\)"#)
        var offenders: [String] = []
        for file in files {
            for (index, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated()
            where line.contains(rawError) {
                offenders.append("\(file.lastPathComponent):\(index + 1)")
            }
        }
        #expect(offenders.isEmpty, "raw error descriptions logged: \(offenders)")
    }
}
