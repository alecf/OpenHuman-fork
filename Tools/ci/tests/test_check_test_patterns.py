import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("ctp", pathlib.Path(__file__).resolve().parents[1] / "check-test-patterns.py")
ctp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctp)


def lines(*texts, path="Packages/P/Tests/PTests/ATests.swift"):
    return [(path, i + 1, t) for i, t in enumerate(texts)]


class CheckTestPatterns(unittest.TestCase):
    def test_banned(self):
        for t in ["try await Task.sleep(for: .seconds(1))", "let d = ContinuousClock().measure { x() }",
                  "#expect(Date().timeIntervalSince(start) < 1)", "let v = WKWebView(frame: .zero)",
                  "let s = QLPreviewPanel.shared()", "SecItemAdd(q, nil)"]:
            bad, _ = ctp.check(lines(t))
            self.assertEqual(len(bad), 1, t)

    def test_allowed_and_comments(self):
        bad, _ = ctp.check(lines("try await Task.sleep(for: .seconds(1)) // flake-ok: the sleep is the behaviour",
                                 "// Task.sleep is banned", "/// uses Task.sleep(for:)", "let x = 1"))
        self.assertEqual(bad, [])

    def test_polling_warns_only(self):
        bad, warn = ctp.check(lines("await eventually { model.ready }", "try await until { v.ok }"))
        self.assertEqual((len(bad), len(warn)), (0, 2))

    def test_raw_temporary_paths(self):
        for t in ['let d = FileManager.default.temporaryDirectory.appendingPathComponent("oh-x-\\(UUID().uuidString)")',
                  "let p = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)",
                  "let u = URL.temporaryDirectory.appending(path: name)", "let f = fm.temporaryDirectory",
                  "guard mkdtemp(&template) != nil else { return }",
                  "let r = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: u, create: true)"]:
            bad, _ = ctp.check(lines(t))
            self.assertEqual(len(bad), 1, t)
            self.assertIn("TemporaryDirectory", bad[0])

    def test_temporary_helper_and_escapes_allowed(self):
        bad, _ = ctp.check(lines('let temp = TemporaryDirectory("oh-x")', "defer { temp.cleanup() }",
                                 "let w = Watcher(url: FileManager.default.temporaryDirectory) // temp-ok: watches only",
                                 "// FileManager.default.temporaryDirectory is banned",
                                 "let temporaryDirectory = temp.url"))
        self.assertEqual(bad, [])
        helper = "Packages/OpenHumanCore/Tests/OpenHumanCoreTests/TemporaryDirectoryTests.swift"
        bad, _ = ctp.check(lines("#expect(a.path == FileManager.default.temporaryDirectory.path)", path=helper))
        self.assertEqual(bad, [])

    def test_raw_defaults_suites(self):
        for t in ['let d = UserDefaults(suiteName: "openhuman.test.\\(UUID().uuidString)")!',
                  "let d = try #require(UserDefaults(suiteName: suite))",
                  "let d = name.flatMap(UserDefaults.init(suiteName:)) ?? .standard",
                  "SystemPreferences(defaults: UserDefaults( suiteName : name) ?? .standard)"]:
            bad, _ = ctp.check(lines(t))
            self.assertEqual(len(bad), 1, t)
            self.assertIn("ScopedDefaults", bad[0])

    def test_defaults_helper_and_escapes_allowed(self):
        bad, _ = ctp.check(lines('let defaults = ScopedDefaults("openhuman.test.x")', "defer { defaults.cleanup() }",
                                 "let store = AISettingsStore(suiteName: defaults.name)",
                                 'let nav = UserDefaultsNavigationStore(scope: "fake", suiteName: defaults.name)',
                                 "let keys = UserDefaultsKeymapStore(suiteName: defaults.name)",
                                 "let group = UserDefaults(suiteName: groupID) // defaults-ok: reads the shared group",
                                 "// UserDefaults(suiteName:) is banned", "let d = UserDefaults.standard"))
        self.assertEqual(bad, [])
        helper = "Packages/OpenHumanCore/Tests/OpenHumanCoreTests/ScopedDefaultsTests.swift"
        bad, _ = ctp.check(lines("let reopened = try #require(UserDefaults(suiteName: first.name))", path=helper))
        self.assertEqual(bad, [])

    def test_only_test_files(self):
        self.assertFalse(ctp.is_test("Packages/P/Sources/P/A.swift"))
        self.assertTrue(ctp.is_test("Apps/Mail/Tests/MailAppTests/A.swift"))


if __name__ == "__main__":
    unittest.main()
