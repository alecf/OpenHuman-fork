import AppKit
import Foundation
import MailFeatures
import MailModel
import MailTheme
import MailUI
import SwiftUI
import Testing
@testable import OpenHumanMail

private struct SweepTailscale: TailscaleRunning {
    var sendExitCode: Int32 = 0

    func run(arguments: [String], timeout: Duration) async throws -> TailscaleRunResult {
        if arguments == TaildropArguments.statusArguments {
            let json = """
            {"BackendState":"Running","Self":{"UserID":1},"Peer":{
              "a":{"HostName":"Mac mini","DNSName":"mac-mini.example.ts.net.","OS":"macOS","UserID":1,"Online":true},
              "b":{"HostName":"Studio","DNSName":"studio.example.ts.net.","OS":"macOS","UserID":1,"Online":true},
              "c":{"HostName":"Phone","DNSName":"phone.example.ts.net.","OS":"iOS","UserID":1,"Online":true}}}
            """
            return TailscaleRunResult(exitCode: 0, output: Data(json.utf8))
        }
        return TailscaleRunResult(exitCode: sendExitCode, errorText: "no such host")
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OH_SNAPSHOT_DIR"] != nil))
struct RenderSweepFeedbackTests {
    static let size = NSSize(width: 520, height: 640)

    static func fakeScreenshot() -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: .systemTeal, ending: .systemIndigo)?.draw(in: NSRect(x: 0, y: 0, width: 640, height: 400), angle: 45)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    func model(runner: (any TailscaleRunning)?) -> SendFeedbackModel {
        SendFeedbackModel(SendFeedbackDependencies(
            runner: runner, appInfo: { DiagnosticsAppInfo(version: "1.0", build: "1", gitCommit: "abc1234", os: "Version 27.0", dataMode: "fake") },
            screenshot: { Self.fakeScreenshot() },
            thread: { FeedbackThreadHeader(subject: "Sample subject", senderName: "Sample Sender") }))
    }

    @Test(arguments: RenderSweepTheme.builtIns)
    func sendFeedbackSheet(_ theme: RenderSweepTheme) async throws {
        let directory = try RenderSweepOutput.directory()
        let themes = theme.makeStore()

        let ready = model(runner: SweepTailscale())
        await ready.load()
        ready.selectedDevice = "mac-mini"
        ready.note = "The reply box lost my text after I switched accounts."
        ready.includeScreenshot = true
        try await shoot(SendFeedbackSheet(model: ready, onClose: {}), "send-feedback-sheet", theme, themes, directory)

        guard theme.slug == "light" || theme.slug == "dark" else { return }
        let missing = model(runner: nil)
        await missing.load()
        try await shoot(SendFeedbackSheet(model: missing, onClose: {}), "send-feedback-sheet-no-tailscale", theme, themes, directory)

        let failed = model(runner: SweepTailscale(sendExitCode: 1))
        await failed.load()
        failed.selectedDevice = "studio"
        await failed.send()
        try await shoot(SendFeedbackSheet(model: failed, onClose: {}), "send-feedback-sheet-failed", theme, themes, directory)
    }

    private func shoot<V: View>(_ view: V, _ screen: String, _ theme: RenderSweepTheme, _ themes: ThemeStore, _ directory: URL) async throws {
        let window = RenderSweepSettingsTests.window(view.background(Color(nsColor: .windowBackgroundColor)), themes: themes, size: Self.size)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(400))
        try RenderSweepSettingsTests.shoot(window, screen: screen, theme: theme, in: directory)
    }
}
