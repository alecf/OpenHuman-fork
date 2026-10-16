import Foundation
import Testing

@Suite struct LogCallSiteTests {
    static let folders = [
        "Packages/OpenHumanMailCore/Sources", "Packages/OpenHumanMailUI/Sources", "Packages/OpenHumanAI/Sources",
        "Packages/OpenHumanAIMLX/Sources", "Packages/OpenHumanCore/Sources", "Packages/OpenHumanLinks/Sources",
        "Packages/OpenHumanCLI/Sources", "Packages/OpenHumanMailLive/Sources", "Apps/Mail/Sources",
    ]

    static func patterns() throws -> (call: Regex<AnyRegexOutput>, raw: Regex<AnyRegexOutput>) {
        let call = try Regex(#"(log|Log\([^)]*\))\s*\.\s*(debug|info|notice|error|fault)\("#)
        let raw = try Regex(#"\\\((error|err|failure)(\.localizedDescription)?\)"#
                            + #"|String\((describing|reflecting):\s*(error|err|failure)\)"#)
        return (call, raw)
    }

    @Test func noLogLineInterpolatesARawError() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root = root.deletingLastPathComponent() }
        let (call, raw) = try Self.patterns()
        var scanned = 0
        var offenders: [String] = []
        for folder in Self.folders {
            let url = root.appendingPathComponent(folder)
            let files = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil),
                                     "\(folder)")
            for case let file as URL in files where file.pathExtension == "swift" {
                scanned += 1
                let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                for (index, line) in lines.enumerated() where line.contains(call) && line.contains(raw) {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(scanned > 300, "found the sources")
        #expect(offenders.isEmpty, "raw error descriptions logged: \(offenders)")
    }

    @Test func theScanCatchesTheRawFormsAndPassesCodesAndTypeNames() throws {
        let (call, raw) = try Self.patterns()
        for bad in [#"log.error("failed: \(error)")"#, #"Log(.app).notice("x (\(error.localizedDescription))")"#,
                    #"Self.log.error("x (\(String(describing: error)))")"#] {
            #expect(bad.contains(call) && bad.contains(raw), "\(bad)")
        }
        for good in [#"log.error("failed (\(AccountSyncer.code(error)))")"#,
                     #"Log(.app).error("x (\(String(describing: type(of: error))))")"#] {
            #expect(!(good.contains(call) && good.contains(raw)), "\(good)")
        }
    }
}
