import Foundation
import Testing
@testable import MailTheme

private func temporaryFolder() throws -> ThemeFolder {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("oh-themes-\(UUID().uuidString)", isDirectory: true)
    let folder = ThemeFolder(url: url)
    try folder.create()
    return folder
}

private func remove(_ folder: ThemeFolder) { try? FileManager.default.removeItem(at: folder.url) }

@Suite struct FolderTests {
    @Test func scanLoadsThemesAndAccentsAndSkipsJunk() async throws {
        let folder = try temporaryFolder()
        defer { remove(folder) }
        try themeJSON(userTheme(id: "me.one", name: "One")).write(to: folder.url.appendingPathComponent("one.json"))
        let accent: [String: Any] = ["format": "openhuman-accent", "formatVersion": 1, "id": "me.accent.sunset", "name": "Sunset",
                                     "light": ["accent.fill": "#C2410C", "accent.fillHover": "#A8380A", "accent.text": "#B23C0B",
                                               "accent.subtle": "#FDEEE6", "accent.onFill": "#FFFFFF", "accent.ring": "#C2410C"],
                                     "dark": ["accent.fill": "#C2410C", "accent.fillHover": "#D24A12", "accent.text": "#F59E6B",
                                              "accent.subtle": "#3A2216", "accent.onFill": "#FFFFFF", "accent.ring": "#F08A4B"]]
        try themeJSON(accent).write(to: folder.accentsURL.appendingPathComponent("sunset.json"))
        try Data("not json".utf8).write(to: folder.url.appendingPathComponent("broken.json"))
        try Data("ignored".utf8).write(to: folder.url.appendingPathComponent("notes.txt"))
        try FileManager.default.createSymbolicLink(at: folder.url.appendingPathComponent("link.json"),
                                                   withDestinationURL: folder.url.appendingPathComponent("one.json"))
        try Data(repeating: 0x20, count: ThemeValidator.maxFileSize + 10).write(to: folder.url.appendingPathComponent("huge.json"))

        let loader = ThemeLoader(folder: folder)
        let files = await loader.scan()
        #expect(files.count == 5)
        #expect(await loader.validationCount == 3)
        var library = ThemeLibrary.builtIn
        library.replaceUserFiles(files)
        #expect(library.summary(id: "me.one")?.isSelectable == true)
        #expect(library.accentIDs.contains("sunset"))
        let refused = library.summaries.filter { !$0.isBuiltIn && !$0.isUsable }.map(\.source.fileName).sorted()
        #expect(refused == ["broken.json", "huge.json", "link.json"])
        let resolved = library.resolve(ThemePreferences(lightThemeID: "me.one", accentID: "sunset"), appearance: .light)
        #expect(resolved.accentRing == ThemeColor(hex: "#C2410C"))
    }

    @Test func rescanRevalidatesOnlyChangedFiles() async throws {
        let folder = try temporaryFolder()
        defer { remove(folder) }
        let a = folder.url.appendingPathComponent("a.json")
        let b = folder.url.appendingPathComponent("b.json")
        try themeJSON(userTheme(id: "me.a")).write(to: a)
        try themeJSON(userTheme(id: "me.b")).write(to: b)
        let loader = ThemeLoader(folder: folder)
        _ = await loader.scan()
        #expect(await loader.validationCount == 2)
        _ = await loader.scan()
        #expect(await loader.validationCount == 2)
        try themeJSON(userTheme(id: "me.b", name: "Changed")).write(to: b, options: .atomic)
        let files = await loader.scan()
        #expect(await loader.validationCount == 3)
        #expect(files.first { $0.source.lastPathComponent == "b.json" }?.result.file?.name == "Changed")
        try FileManager.default.removeItem(at: a)
        #expect(await loader.scan().count == 1)
    }

    @Test func numberedScansCountUpAndSeeTheLatestFolder() async throws {
        let folder = try temporaryFolder()
        defer { remove(folder) }
        let file = folder.url.appendingPathComponent("a.json")
        try themeJSON(userTheme(id: "me.a", name: "First")).write(to: file)
        let loader = ThemeLoader(folder: folder)
        let first = await loader.numberedLibrary()
        try themeJSON(userTheme(id: "me.a", name: "Second")).write(to: file, options: .atomic)
        let second = await loader.numberedLibrary()
        #expect(second.number > first.number)
        #expect(first.library.summary(id: "me.a")?.name == "First")
        #expect(second.library.summary(id: "me.a")?.name == "Second")
    }

    @Test func importCopiesValidFilesAndRefusesBadOnes() throws {
        let folder = try temporaryFolder()
        defer { remove(folder) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        try themeJSON(userTheme(id: "me.imported", name: "Imported")).write(to: outside)
        let (url, result) = try folder.importFile(from: outside)
        #expect(url.lastPathComponent == "me.imported.json" && url.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL)
        #expect(result.file?.name == "Imported")
        try themeJSON(userTheme(id: "openhuman.fake")).write(to: outside)
        #expect(throws: ThemeFileError.self) { try folder.importFile(from: outside) }
        #expect(folder.jsonFiles().count == 1)
    }

    @Test func manualWatcherDeliversToEverySubscriber() async {
        let watcher = ManualThemeFolderWatcher()
        let first = watcher.changes()
        let second = watcher.changes()
        watcher.trigger()
        var a = first.makeAsyncIterator()
        var b = second.makeAsyncIterator()
        #expect(await a.next() != nil)
        #expect(await b.next() != nil)
    }
}

@Suite struct RoundTripTests {
    @Test(arguments: [(BuiltinThemeID.light, ThemeAppearance.light), (BuiltinThemeID.dark, .dark),
                      (BuiltinThemeID.paper, .light), (BuiltinThemeID.midnight, .dark)])
    func flattenedBuiltInResolvesToTheSameTable(_ id: String, _ appearance: ThemeAppearance) throws {
        let original = ThemeLibrary.builtIn.resolve(themeID: id, appearance: appearance)
        let data = ThemeExport.flattened(original.tokens, id: "me.copy", name: "Copy", appearance: appearance == .dark ? .dark : .light,
                                         defaultAccent: original.accentID)
        let result = ThemeValidator.validate(data: data)
        #expect(result.issues.isEmpty, "\(result.issues)")
        var library = ThemeLibrary.builtIn
        let summary = library.add(result, source: .user(URL(fileURLWithPath: "/tmp/copy.json")))
        #expect(summary.issues.isEmpty, "\(summary.issues)")
        let copy = library.resolve(themeID: "me.copy", appearance: appearance)
        #expect(copy.tokens == original.tokens)
    }

    @Test func exportedCustomizationsImportToTheSameLook() throws {
        let folder = try temporaryFolder()
        defer { remove(folder) }
        let prefs = ThemePreferences(lightThemeID: BuiltinThemeID.paper, accentID: "pine", readerTextSize: 16,
                                     uiFont: .systemRounded, readerFont: .systemSerif, emailColors: .alwaysOriginal)
        var library = ThemeLibrary.builtIn
        let base = try #require(library.summary(id: BuiltinThemeID.paper))
        let data = ThemeExport.customizations(named: "My Paper!", baseTheme: base, preferences: prefs)
        let url = try folder.write(themeData: data)
        #expect(url.lastPathComponent == "user.my-paper.json")
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["extends"] as? String == BuiltinThemeID.paper)
        #expect(object["semantic"] == nil && object["components"] == nil)
        #expect(data.count < 600)

        let expected = library.resolve(prefs, appearance: .light)
        library.replaceUserFiles(ThemeLoader.syncScan(folder))
        let imported = library.resolve(ThemePreferences(lightThemeID: "user.my-paper"), appearance: .light)
        #expect(imported.tokens == expected.tokens)
        #expect(imported.accentID == "pine" && imported.emailColors == .alwaysOriginal)
    }

    @Test func slugs() {
        #expect(ThemeExport.slug("My Paper!") == "my-paper")
        #expect(ThemeExport.slug("  ") == "custom")
        #expect(ThemeExport.slug("Ünï Côde") == "n-c-de")
        #expect(ThemeFile.isValidID("user." + ThemeExport.slug("Ünï Côde")))
    }
}

extension ThemeLoader {
    static func syncScan(_ folder: ThemeFolder) -> [(source: URL, result: ValidationResult)] {
        folder.jsonFiles().map { url in (url, ThemeValidator.validate(data: (try? Data(contentsOf: url)) ?? Data())) }
    }
}
