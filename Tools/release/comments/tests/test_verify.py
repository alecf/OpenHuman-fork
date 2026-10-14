import os
import shutil
import unittest

from support import quiet, TempDirTestCase, dedent, strip_comments, swiftc_available, verify_strip

SWIFT = dedent('''
    import Foundation
    // comment
    let a = 1 + 2 /* inline */
    let s = "// kept"
    func f() -> Int {
        return a
    }
''')
PYTHON = 'import os  # c\n\n# c\nx = "#"\n'
SHELL = '#!/bin/bash\n# c\necho "# x" # c\ncat <<EOF\n# body\nEOF\n'
YAML = '# c\nkey: "a # b" # c\nlist:\n  - run: |\n      # body\n'


class VerifyTests(TempDirTestCase):
    def setUp(self):
        super().setUp()
        self.before = os.path.join(self.tmp, "before")
        self.after = os.path.join(self.tmp, "after")
        for name, text in (("A.swift", SWIFT), ("a.py", PYTHON), ("a.sh", SHELL), ("a.yml", YAML),
                           ("notes.md", "# Notes\n")):
            self.write(name, text, root=self.before)
        shutil.copytree(self.before, self.after)

    def replace(self, rel, old, new):
        path = os.path.join(self.after, rel)
        with open(path) as handle:
            text = handle.read()
        self.assertIn(old, text)
        with open(path, "w") as handle:
            handle.write(text.replace(old, new))

    def failures(self, use_compiler=False):
        return {o.path: o.problems for o in verify_strip.verify(self.before, self.after, use_compiler=use_compiler)
                if o.failed}

    def test_a_real_strip_passes_every_check(self):
        strip_comments.process_tree(self.after, ["."], write=True)
        outcomes = verify_strip.verify(self.before, self.after, use_compiler=swiftc_available())
        self.assertEqual([o.problems for o in outcomes if o.failed], [])
        checks = {o.path: o.checks for o in outcomes}
        self.assertEqual(checks["a.py"], {"tokens": "pass", "ast": "pass"})
        self.assertEqual(checks["a.sh"]["bash"], "pass")
        self.assertEqual(checks["notes.md"], {"identical": "pass"})
        if swiftc_available():
            self.assertEqual(checks["A.swift"]["swiftc"], "pass")

    def test_changed_operator_fails(self):
        self.replace("A.swift", "1 + 2", "1 - 2")
        self.assertIn("A.swift", self.failures())

    def test_changed_operator_spacing_fails(self):
        self.replace("A.swift", "1 + 2", "1 +2")
        self.assertTrue(any(p.startswith("tokens:") for p in self.failures()["A.swift"]))

    def test_joined_lines_fail(self):
        self.replace("A.swift", "    return a\n", "    return\na\n")
        self.assertIn("A.swift", self.failures())

    @unittest.skipUnless(swiftc_available(), "swiftc is not installed")
    def test_swiftc_sees_a_changed_string(self):
        self.replace("A.swift", '"// kept"', '"// changed"')
        problems = self.failures(use_compiler=True)["A.swift"]
        self.assertTrue(any(p.startswith("swiftc:") for p in problems))

    def test_python_change_fails_tokens_and_ast(self):
        self.replace("a.py", 'x = "#"', 'x = "#!"')
        problems = self.failures()["a.py"]
        self.assertTrue(any(p.startswith("tokens:") for p in problems))
        self.assertTrue(any(p.startswith("ast:") for p in problems))

    def test_shell_heredoc_change_fails(self):
        self.replace("a.sh", "# body", "body")
        self.assertIn("a.sh", self.failures())

    def test_yaml_value_change_fails(self):
        self.replace("a.yml", '"a # b"', '"a"')
        self.assertIn("a.yml", self.failures())

    def test_other_files_must_be_identical(self):
        self.replace("notes.md", "# Notes", "Notes")
        self.assertIn("notes.md", self.failures())

    def test_missing_file_fails(self):
        os.remove(os.path.join(self.after, "a.py"))
        self.assertEqual(self.failures()["a.py"], ["missing from the after tree"])

    def test_shell_check_cannot_run_the_script(self):
        marker = os.path.join(self.tmp, "ran")
        breakout = "true\n}\nprintf x > %s\n/usr/bin/touch %s\ntouch %s\n__again() {\n" % (marker, marker, marker)
        verify_strip.shell_canonical(breakout)
        self.assertFalse(os.path.exists(marker))
        self.assertIn("<<EOF\nbody\nEOF", verify_strip.shell_canonical("cat <<EOF\nbody\nEOF\n"))

    def test_cli_exit_status(self):
        self.assertEqual(quiet(verify_strip.main, [self.before, self.after, "--no-compiler"]), 0)
        self.replace("a.py", "import os", "import sys")
        self.assertEqual(quiet(verify_strip.main, [self.before, self.after, "--no-compiler"]), 1)


if __name__ == "__main__":
    unittest.main()
