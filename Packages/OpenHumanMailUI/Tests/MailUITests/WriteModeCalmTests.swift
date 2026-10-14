import Foundation
import MailFakes
import MailFeatures
import MailModel
import Testing
@testable import MailUI

private enum CalmSources {
    static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let repo = package.deletingLastPathComponent().deletingLastPathComponent()
    static var roots: [URL] {
        [package.appendingPathComponent("Sources"), repo.appendingPathComponent("Apps/Mail/Sources")]
    }

    static func all() throws -> [String: String] {
        var out: [String: String] = [:]
        for root in roots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                out[file.lastPathComponent] = text.joined(separator: "\n")
            }
        }
        return out
    }

    static func block(around index: String.Index, in text: String) -> Substring {
        let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
        var open = text[index..<lineEnd].firstIndex(of: "{")
        if open == nil {
            var depth = 0
            var cursor = index
            while cursor > text.startIndex {
                cursor = text.index(before: cursor)
                if text[cursor] == "}" { depth += 1 }
                if text[cursor] == "{" {
                    if depth == 0 { open = cursor; break }
                    depth -= 1
                }
            }
        }
        guard let open else { return text[...] }
        var depth = 0
        var cursor = open
        while cursor < text.endIndex {
            if text[cursor] == "{" { depth += 1 }
            if text[cursor] == "}" {
                depth -= 1
                if depth == 0 { return text[open...cursor] }
            }
            cursor = text.index(after: cursor)
        }
        return text[open...]
    }
}

@MainActor
@Suite struct WriteModeCalmTests {
    @Test func aWriteModeWindowShowsNoModeIndicator() async throws {
        let store = FakeMailStore(corpus: .small, options: .init(remoteAck: .immediate))
        let environment = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: true,
                                         featureFlags: FeatureFlags(), writeMode: WriteModeSession())
        #expect(environment.writeMode != nil && environment.status.isWriteMode)
        #expect(environment.status.safeModeText == nil && environment.status.safeModeDetail == nil
            && environment.status.safeModeHelp == nil)
        #expect(!environment.router.windowTitle.contains("Write mode"))
        #expect(SignInView.modeText(.normal) == nil)
        let access = SignInView.accessText(.normal)
        for alarm in ["real mail", "Warning", "careful", "danger", "!"] { #expect(!access.contains(alarm), "\(alarm)") }
    }

    @Test func noWriteModeSurfaceUsesTheErrorOrWarningColourTokens() throws {
        let sources = try CalmSources.all()
        #expect(sources.count > 50, "found the UI and app sources")
        let marker = try Regex(#"\bwriteMode\b|isWriteMode|WriteModeSession|WriteModeSetting|WriteModeConfirmationSheet|SendConfirmationCard|sendConfirmation|confirmEverySend|showsWriteModeSending|safeMode == \.normal"#)
        let alarming = try Regex(#"textDanger|bgDanger|textWarning|bgWarning|borderDanger|borderWarning|\.danger\b|\.warning\b|exclamationmark|systemRed|systemOrange|systemYellow|\.red\b|\.orange\b|\.yellow\b"#)
        var checked = 0
        for (file, text) in sources.sorted(by: { $0.key < $1.key }) {
            for match in text.matches(of: marker) {
                checked += 1
                let block = CalmSources.block(around: match.range.lowerBound, in: text)
                let found = block.matches(of: alarming).map { String(block[$0.range]) }
                let line = text[..<match.range.lowerBound].filter { $0 == "\n" }.count + 1
                #expect(found.isEmpty, "\(file):\(line) \(text[match.range]) uses \(Set(found).sorted())")
            }
        }
        #expect(checked > 20, "the write-mode surfaces were found (Settings, composer card, app wiring)")
    }
}
