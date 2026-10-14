import Foundation
import OpenHumanAI

public struct AgentCLIConfiguration: Sendable {
    public var overridePath: String?
    public var model: String?
    public var policyInputCap: Int
    public var homeDirectory: String
    public var shellLookup: (@Sendable (String) async -> String?)?
    public var temporaryRoot: URL
    public var probeTimeout: Duration
    public var killGrace: Duration
    public var timeoutOverride: Duration?
    public var extraPathDirectories: [String]

    public init(
        overridePath: String? = nil, model: String? = nil, policyInputCap: Int = AIPolicy.agentCLIDefaultInputCap,
        homeDirectory: String = NSHomeDirectory(), shellLookup: (@Sendable (String) async -> String?)? = nil,
        temporaryRoot: URL = FileManager.default.temporaryDirectory, probeTimeout: Duration = .seconds(10),
        killGrace: Duration = .seconds(3), timeoutOverride: Duration? = nil, extraPathDirectories: [String] = []
    ) {
        self.overridePath = overridePath
        self.model = model
        self.policyInputCap = policyInputCap
        self.homeDirectory = homeDirectory
        self.shellLookup = shellLookup
        self.temporaryRoot = temporaryRoot
        self.probeTimeout = probeTimeout
        self.killGrace = killGrace
        self.timeoutOverride = timeoutOverride
        self.extraPathDirectories = extraPathDirectories
    }
}

public enum AgentCLIDiscovery {
    public static func locate(_ kind: AgentCLIKind, configuration: AgentCLIConfiguration) async -> URL? {
        if let path = configuration.overridePath, !path.isEmpty {
            return isExecutableFile(path) ? URL(fileURLWithPath: path) : nil
        }
        if let lookup = configuration.shellLookup {
            if let path = await lookup(kind.executableName), isExecutableFile(path) { return URL(fileURLWithPath: path) }
        } else if let path = await loginShellLookup(kind, configuration: configuration), isExecutableFile(path) {
            return URL(fileURLWithPath: path)
        }
        for path in kind.knownLocations(home: configuration.homeDirectory) where isExecutableFile(path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    private static func loginShellLookup(_ kind: AgentCLIKind, configuration: AgentCLIConfiguration) async -> String? {
        let spec = ProcessSpec(
            executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", "command -v \(kind.executableName)"],
            environment: ["HOME": configuration.homeDirectory, "PATH": "/usr/bin:/bin"],
            workingDirectory: configuration.temporaryRoot, timeout: .seconds(3), killGrace: .milliseconds(500))
        guard let (lines, result) = try? await ProcessRunner.collect(spec), result.exitCode == 0 else { return nil }
        return lines.last { $0.hasPrefix("/") }
    }
}
