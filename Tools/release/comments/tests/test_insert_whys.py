import os
import tempfile
import unittest

import insert_whys


class InsertWhysTests(unittest.TestCase):
    def test_inserts_above_unique_anchor_with_indent(self):
        out, reason = insert_whys.insert("a\n    foo()\n\n    bar()\n", ["    bar()"], "Why: x", "//")
        self.assertIsNone(reason)
        self.assertEqual(out, "a\n    foo()\n\n    // Why: x\n    bar()\n")

    def test_ambiguous_anchor_is_skipped(self):
        out, reason = insert_whys.insert("x()\nx()\n", "x()", "t", "#")
        self.assertIsNone(out)
        self.assertEqual(reason, "ambiguous")

    def test_missing_anchor_is_skipped(self):
        self.assertEqual(insert_whys.insert("x()\n", "y()", "t", "#"), (None, "missing"))

    def test_multi_line_anchor_disambiguates(self):
        out, _ = insert_whys.insert("x()\na\nx()\nb\n", ["x()", "b"], "t", "#")
        self.assertEqual(out, "x()\na\n# t\nx()\nb\n")

    def test_apply_writes_file_and_reports_skips(self):
        with tempfile.TemporaryDirectory() as root:
            with open(os.path.join(root, "f.swift"), "w") as handle:
                handle.write("let a = 1\n")
            done, skipped = insert_whys.apply(root, [
                {"file": "f.swift", "anchor": "let a = 1", "text": "Why: b"},
                {"file": "f.swift", "anchor": "nope", "text": "Why: c"},
            ])
            self.assertEqual((done, skipped), (1, [("f.swift", "missing")]))
            with open(os.path.join(root, "f.swift")) as handle:
                self.assertEqual(handle.read(), "// Why: b\nlet a = 1\n")


if __name__ == "__main__":
    unittest.main()
