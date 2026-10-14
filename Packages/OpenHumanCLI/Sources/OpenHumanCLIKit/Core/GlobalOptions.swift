import ArgumentParser
import Foundation

public enum ColorMode: String, ExpressibleByArgument, CaseIterable, Sendable {
    case auto, always, never
}

public struct GlobalOptions: ParsableArguments {
    @Option(name: [.short, .long], help: "Account email, alias or `all` (default: the default_account setting, else the only account).")
    public var account: String?
    @Flag(name: .long, help: "JSON envelope on stdout (default when stdout is not a terminal).") public var json = false
    @Flag(name: .long, help: "One JSON item per line for list commands.") public var jsonl = false
    @Flag(name: .long, help: "Tab-separated records.") public var plain = false
    @Flag(name: .long, help: "Human-readable text (default on a terminal).") public var human = false
    @Flag(name: .long, help: "Add a header line to --plain output.") public var header = false
    @Flag(name: .long, help: "Never prompt; a needed confirmation exits 2.") public var noInput = false
    @Flag(name: .long, help: "Open the store read-only; every write command exits 5.") public var readonly = false
    @Flag(name: .long, help: "Validate and print what would happen; write nothing.") public var dryRun = false
    @Flag(name: .long, help: "Wrap email-derived text in nonce-tagged markers.") public var wrapUntrusted = false
    @Flag(name: .long, help: "Strip control characters, bidi marks and HTML tags; truncate bodies.") public var sanitizeContent = false
    @Option(name: .long, help: "Body size cap for --sanitize-content, in bytes.") public var maxBodyBytes: Int = 32 * 1024
    @Option(name: .long, help: "Store directory (default: OPENHUMAN_HOME, else Application Support).") public var home: String?
    @Option(name: .long, help: "Wait limit for writes, e.g. 30s, 2s, 1m; at most 1h.") public var timeout: String?
    @Flag(name: .long, help: "Sync first. Needs network access: exits 12 in Phase 1.") public var sync = false
    @Flag(name: [.short, .long], help: "No stderr chatter.") public var quiet = false
    @Flag(name: [.short, .long], help: "More stderr detail.") public var verbose = false
    @Option(name: .long, help: "Color: auto, always or never.") public var color: ColorMode = .auto

    public init() {}
}

public struct WriteOptions: ParsableArguments {
    @Flag(name: .long, inversion: .prefixedNo, help: "Wait for the app to apply the write (default).") public var wait = true
    public init() {}
}

enum OutputFormat: String, Sendable { case json, jsonl, plain, human }

let maxTimeoutSeconds: Double = 3600

func parseDuration(_ text: String) -> Duration? {
    let t = text.trimmingCharacters(in: .whitespaces).lowercased()
    let units: [(String, Double)] = [("ms", 0.001), ("s", 1), ("m", 60), ("h", 3600)]
    var number = Substring(t)
    var scale: Double = 1
    if let unit = units.first(where: { t.hasSuffix($0.0) }) {
        number = number.dropLast(unit.0.count)
        scale = unit.1
    }
    guard let n = Double(number), n.isFinite, n >= 0 else { return nil }
    let seconds = n * scale
    guard seconds <= maxTimeoutSeconds else { return nil }
    return .milliseconds(Int(seconds * 1000))
}
