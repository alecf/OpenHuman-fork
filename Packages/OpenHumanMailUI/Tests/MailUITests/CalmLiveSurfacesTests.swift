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
        [package.appendingPathComponent("Sources"), repo.appendingPathComponent("Packages/OpenHumanMailLive/Sources"),
         repo.appendingPathComponent("Apps/Mail/Sources")]
    }

    static func files(under roots: [URL]) -> [URL] {
        roots.flatMap { root in
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        }
    }

    static func all() throws -> [String: String] {
        var out: [String: String] = [:]
        for file in files(under: roots) {
            let text = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            out[file.lastPathComponent] = text.joined(separator: "\n")
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

private enum ModeWording {
    static let pattern = [
        #"(?<![A-Za-z])[Ss]afe[ _-]?[Mm]odes?|(?<=[a-z])Safe[ _-]?Modes?|SAFE_?MODE"#,
        #"(?<![A-Za-z])[Rr]ead[ _-]?[Oo]nly|(?<=[a-z])Read[ _-]?Only|READ_?ONLY"#,
        #"(?<![A-Za-z])[Tt]est[ _-]?[Ww]rites?|(?<=[a-z])Test[ _-]?Writes?"#,
        #"(?<![A-Za-z])[Ww]rite[ _-]?[Mm]odes?|(?<=[a-z])Write[ _-]?Modes?|WRITE_?MODE"#,
        #"(?<![A-Za-z])[Ww]rite[ _-]?[Aa]llowlist|(?<=[a-z])Write[ _-]?Allowlist"#,
    ].joined(separator: "|")

    static let unrelatedMeanings: [(marker: String, meaning: String)] = [
        ("organiz", "calendar fields locked for an event someone else organizes"),
        ("ReadOnlyTransport", "the sign-in transport, which only needs to read"),
        ("sandbox", "the coding agent's own sandbox setting"),
    ]

    static func hits(in text: String) throws -> [(line: Int, text: String)] {
        let regex = try NSRegularExpression(pattern: pattern)
        var out: [(line: Int, text: String)] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            guard regex.firstMatch(in: line, range: range) != nil else { continue }
            if unrelatedMeanings.contains(where: { line.contains($0.marker) }) { continue }
            out.append((index + 1, line.trimmingCharacters(in: .whitespaces)))
        }
        return out
    }
}

@MainActor
@Suite struct CalmLiveSurfacesTests {
    @Test func aLiveWindowShowsNoModeIndicator() async throws {
        let store = FakeMailStore(corpus: .small, options: .init(remoteAck: .immediate))
        let environment = AppEnvironment(data: store, commands: store, accounts: store, settings: store, isFake: true,
                                         featureFlags: FeatureFlags(), isLiveAccount: true)
        #expect(environment.isLiveAccount)
        #expect(!environment.status.isVisible, "nothing in the status bar just because the account is live")
        #expect(!FooterView.isVisible(status: environment.status, hints: nil))
        #expect(!environment.router.windowTitle.lowercased().contains("mode"))
        let statusBar = try #require(try CalmSources.all()["StatusBarView.swift"])
        #expect(!statusBar.contains("lock.fill") && !statusBar.contains(".popover("), "no mode chip or its popover")
        for alarm in ["real mail", "Warning", "careful", "danger", "!"] {
            #expect(!SignInView.accessText.contains(alarm), "\(alarm)")
        }
    }

    @Test func noSendConfirmationSurfaceUsesTheErrorOrWarningColourTokens() throws {
        let sources = try CalmSources.all()
        #expect(sources.count > 50, "found the UI and app sources")
        let marker = try Regex(#"SendConfirmationCard|sendConfirmation|confirmEverySend|showsConfirmBeforeSending"#)
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
        #expect(checked >= 5, "the send-confirmation surfaces were found (Settings row, composer card)")
    }

    @Test func theUISourcesHaveNoSafeModeReadOnlyOrTestWritesWording() throws {
        let files = CalmSources.files(under: [CalmSources.package.appendingPathComponent("Sources")])
        #expect(files.count > 50, "found the UI sources")
        var found: [String] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for hit in try ModeWording.hits(in: text) {
                found.append("\(file.lastPathComponent):\(hit.line) \(hit.text)")
            }
        }
        #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    }

    @Test func theWordingScanCatchesEachSpellingAndSkipsTheAllowedMeanings() throws {
        for line in ["Read-only: Mail can't change your mail", "Off in safe mode", "Test writes only", "write mode",
                     "status.safeModeText", "model.isReadOnly", "WriteModeSession()", "OPENHUMAN_SAFE_MODE",
                     "case readonly", "Safe mode: test writes only"] {
            #expect(try ModeWording.hits(in: line).count == 1, "\(line)")
        }
        for line in ["threadOnly", "the latest writes", "isSafe", "rewrite model", "unsafeMode",
                     "Read-only because someone else organizes this event", "ReadOnlyTransport(wrapping: base)",
                     "codex --sandbox read-only"] {
            #expect(try ModeWording.hits(in: line).isEmpty, "\(line)")
        }
    }
}
