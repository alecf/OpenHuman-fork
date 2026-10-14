import os
import unittest

from support import quiet, TempDirTestCase, dedent, git, scan_leaks

SWIFT = dedent('''
    // See docs/plans/mail.md and docs/BUILD.md.
    let author = 1
    let message = "the author decided"
    let session = URLSession.shared
    // A previous session found this; the per-package agent fixed it.
    let drafts = "agent drafts"
    let paths = ["/Users/pat/Projects/x", "/Users/you/Library"]
    let mails = ["a@example.com", "real.person@gmail.com", "ops@acme.io", "x@mail.test"]
''')


class ScanTests(TempDirTestCase):
    def scan(self, extra=()):
        patterns = scan_leaks.builtin_patterns() + list(extra)
        return {(h.pattern, h.location, h.line) for h in scan_leaks.scan_tree(self.tmp, patterns)}

    def test_builtin_patterns(self):
        self.write("docs/BUILD.md", "Build.\n")
        self.write("Sources/A.swift", SWIFT)
        hits = self.scan()
        self.assertEqual(hits, {
            ("missing-doc-path", "Sources/A.swift", 1),
            ("process-author", "Sources/A.swift", 3),
            ("process-session", "Sources/A.swift", 5),
            ("process-agent", "Sources/A.swift", 5),
            ("home-path", "Sources/A.swift", 7),
            ("email-personal", "Sources/A.swift", 8),
            ("email-other", "Sources/A.swift", 8),
        })

    def test_doc_paths_relative_to_the_file(self):
        self.write("docs/guide/README.md", "See ../BUILD.md and docs/guide/README.md and docs/gone.md.\n")
        self.write("docs/BUILD.md", "x\n")
        self.write("Tools/x.sh", "# docs/guide/ exists; https://example.com/docs/remote does not count\n")
        hits = self.scan()
        self.assertEqual(hits, {("missing-doc-path", "docs/guide/README.md", 1)})

    def test_prose_only_patterns_ignore_identifiers_but_not_other_files(self):
        self.write("a.py", "author = 1\nsession_count = 2\n")
        self.write("notes.txt", "author = 1\n")
        self.assertEqual(self.scan(), {("process-author", "notes.txt", 1)})

    def test_pattern_file(self):
        path = self.write("patterns.txt", "# comment\nsecret-name \\bProjectX\\b\nword:prose \\bzebra\\b\n")
        patterns = scan_leaks.load_patterns(path)
        self.assertEqual([(p.name, p.prose) for p in patterns], [("secret-name", False), ("word", True)])
        os.remove(path)
        self.write("A.swift", "let zebra = ProjectX // zebra\n")
        self.assertEqual(self.scan(patterns), {("secret-name", "A.swift", 1), ("word", "A.swift", 1)})

    def test_binary_files_are_skipped(self):
        with open(os.path.join(self.tmp, "image.dat"), "wb") as handle:
            handle.write(b"\0docs/plans/x.md")
        self.assertEqual(self.scan(), set())

    def test_commit_messages_and_identities(self):
        git(self.tmp, "init", "-q")
        self.write("a.txt", "x\n")
        git(self.tmp, "add", "a.txt")
        git(self.tmp, "commit", "-q", "-m", "Fix per docs/plans/x.md\n\nCo-Authored-By: Claude <noreply@anthropic.com>")
        self.write("b.txt", "y\n")
        git(self.tmp, "add", "b.txt")
        git(self.tmp, "commit", "-q", "-m", "Plain change", author="Someone <someone@gmail.com>")
        hits = scan_leaks.scan_git_log(self.tmp, "HEAD", scan_leaks.builtin_patterns())
        found = sorted((h.pattern, h.line, h.text if h.pattern == "commit-identity" else "") for h in hits)
        self.assertEqual(found, [("ai-trailer", 3, ""), ("commit-identity", 0, "someone@gmail.com"),
                                 ("missing-doc-path", 1, "")])

    def test_cli_exit_status(self):
        self.write("clean.txt", "Nothing to see.\n")
        self.assertEqual(quiet(scan_leaks.main, ["--root", self.tmp, "--summary"]), 0)
        self.write("leak.txt", "/home/pat/x\n")
        self.assertEqual(quiet(scan_leaks.main, ["--root", self.tmp, "--summary"]), 1)


if __name__ == "__main__":
    unittest.main()
