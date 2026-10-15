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

    def test_only_test_files(self):
        self.assertFalse(ctp.is_test("Packages/P/Sources/P/A.swift"))
        self.assertTrue(ctp.is_test("Apps/Mail/Tests/MailAppTests/A.swift"))


if __name__ == "__main__":
    unittest.main()
