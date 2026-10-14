import AppKit
import Foundation
import PerfHarnessKit

@main
struct PerfHarnessMain {
    @MainActor
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var options = arguments.contains("--smoke") ? ListPerfHarness.Options.smoke : ListPerfHarness.Options()
        var reportPath: String?
        var enforce = false
        while !arguments.isEmpty {
            let argument = arguments.removeFirst()
            switch argument {
            case "--threads": options.threadCount = Int(arguments.isEmpty ? "" : arguments.removeFirst()) ?? options.threadCount
            case "--onscreen": options.onscreen = true
            case "--smoke": break
            case "--report": reportPath = arguments.isEmpty ? nil : arguments.removeFirst()
            case "--enforce": enforce = true
            case "--only": options.only = Set((arguments.isEmpty ? "" : arguments.removeFirst()).split(separator: ",").map(String.init))
            default:
                FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8))
                exit(2)
            }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(options.onscreen ? .regular : .prohibited)
        let harness = ListPerfHarness(options: options)
        do {
            let report = try await harness.run { step in
                FileHandle.standardError.write(Data("… \(step)\n".utf8))
            }
            print(report.text)
            if let reportPath { try report.text.write(toFile: reportPath, atomically: true, encoding: .utf8) }
            exit(enforce && !(report.failures.isEmpty && harness.problems.isEmpty) ? 1 : 0)
        } catch {
            FileHandle.standardError.write(Data("perf-harness failed: \(error)\n".utf8))
            exit(1)
        }
    }
}
