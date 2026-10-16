import AppKit
import Foundation
import OpenHumanCore
import Testing
@testable import OpenHumanMail

@MainActor
private final class FakeSwapper: AppIconSwapping {
    private(set) var calls: [String] = []
    func showOpenIcon() { calls.append("open") }
    func restoreBundleIcon() { calls.append("restore") }
}

private func freshDefaults() -> ScopedDefaults { ScopedDefaults("dev.openhuman.mail.tests.icon") }

@MainActor
@Suite struct AppIconTests {
    private var catalog: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Assets.xcassets")
    }

    private func images(_ set: String) throws -> [[String: String]] {
        let data = try Data(contentsOf: catalog.appendingPathComponent("\(set)/Contents.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["images"] as? [[String: String]])
    }

    private func pixelWidth(_ file: URL) throws -> Int {
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: file)))
        return rep.pixelsWide
    }

    @Test func appIconSetHasEveryStandardMacSize() throws {
        let entries = try images("AppIcon.appiconset")
        #expect(entries.count == 10)
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let entry = try #require(entries.first { $0["size"] == "\(pt)x\(pt)" && $0["scale"] == "\(scale)x" },
                                         "missing \(pt)pt @\(scale)x")
                #expect(entry["idiom"] == "mac")
                let file = catalog.appendingPathComponent("AppIcon.appiconset/\(try #require(entry["filename"]))")
                #expect(FileManager.default.fileExists(atPath: file.path))
                #expect(try pixelWidth(file) == pt * scale)
            }
        }
    }

    @Test func openIconAndMenuBarTemplateSetsHaveTheirFiles() throws {
        let open = try images("AppIconOpen.imageset")
        #expect(try open.map { try pixelWidth(catalog.appendingPathComponent("AppIconOpen.imageset/\($0["filename"]!)")) }.sorted() == [512, 1024])
        let menu = try images("MenuBarTemplate.imageset")
        #expect(try menu.map { try pixelWidth(catalog.appendingPathComponent("MenuBarTemplate.imageset/\($0["filename"]!)")) }.sorted() == [18, 36])
        let data = try Data(contentsOf: catalog.appendingPathComponent("MenuBarTemplate.imageset/Contents.json"))
        let properties = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["properties"] as? [String: String])
        #expect(properties["template-rendering-intent"] == "template")
    }

    @Test func theBundleShipsTheOpenIconImage() {
        #expect(NSImage(named: AppIconController.openImageName) != nil)
    }

    @Test func launchRequestsTheOpenIconOnceByDefault() {
        let swapper = FakeSwapper()
        let controller = AppIconController(swapper: swapper, defaults: freshDefaults(), underTest: false)
        #expect(controller.isEnabled)
        controller.applyAtLaunch()
        #expect(swapper.calls == ["open"])
    }

    @Test func settingOffSetsNothingAtLaunch() {
        let defaults = freshDefaults()
        defer { defaults.cleanup() }
        defaults.set(false, forKey: AppIconController.settingKey)
        let swapper = FakeSwapper()
        AppIconController(swapper: swapper, defaults: defaults, underTest: false).applyAtLaunch()
        #expect(swapper.calls.isEmpty)
    }

    @Test func theSwitchRestoresAndReappliesLive() {
        let defaults = freshDefaults()
        defer { defaults.cleanup() }
        let swapper = FakeSwapper()
        let controller = AppIconController(swapper: swapper, defaults: defaults, underTest: false)
        controller.setEnabled(false)
        #expect(!controller.isEnabled)
        controller.setEnabled(true)
        #expect(controller.isEnabled)
        #expect(swapper.calls == ["restore", "open"])
    }

    @Test func nothingIsSwappedUnderXCTest() {
        let swapper = FakeSwapper()
        let controller = AppIconController(swapper: swapper, defaults: freshDefaults(), underTest: true)
        controller.applyAtLaunch()
        controller.setEnabled(false)
        controller.setEnabled(true)
        #expect(swapper.calls.isEmpty)
    }

    @Test func theDefaultControllerIsUnderTestHere() {
        #expect(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil)
        let swapper = FakeSwapper()
        let controller = AppIconController(swapper: swapper, defaults: freshDefaults())
        controller.applyAtLaunch()
        #expect(swapper.calls.isEmpty)
    }
}
