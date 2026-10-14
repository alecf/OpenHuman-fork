import json
import os
import unittest

from support import TempDirTestCase, dedent, dry_run, git, strip_comments

SOURCE = dedent('''
    // Package intro (docs/plans/01.md).
    import Foundation

    /// Gmail returns 429 under load, so this must back off before retrying.
    func retry() {}
    // MARK: - Helpers
    let a = 1 // the author decided this
''')


class DryRunTests(TempDirTestCase):
    def test_report_on_a_copy(self):
        repo = os.path.join(self.tmp, "repo")
        self.write("Packages/Kit/Sources/Kit/A.swift", SOURCE, root=repo)
        self.write("Tools/run.sh", "#!/bin/bash\n# helper\necho hi\n", root=repo)
        self.write("README.md", "See docs/plans/01.md.\n", root=repo)
        git(repo, "init", "-q")
        git(repo, "add", ".")
        git(repo, "commit", "-q", "-m", "Initial")
        out = os.path.join(self.tmp, "out")

        report = dry_run.run(repo, out, strip_comments.Options(), [], use_compiler=False, work=None,
                             keep_work=False, log_range="HEAD",
                             check_commands=["bash Tools/run.sh; pwd", "sed -n 2p Tools/run.sh"])

        with open(os.path.join(repo, "Packages/Kit/Sources/Kit/A.swift")) as handle:
            self.assertEqual(handle.read(), SOURCE)
        kit = report["packages"]["Packages/Kit"]
        self.assertEqual((kit["comments"], kit["removed"], kit["kept"]), (4, 4, 0))
        self.assertEqual((kit["why_high"], kit["verify_pass"], kit["verify_fail"]), (1, 1, 0))
        self.assertEqual(kit["leaks_before"], {"missing-doc-path": 1, "process-author": 1})
        self.assertEqual(kit["leaks_after"], {})
        self.assertEqual(report["packages"]["(root)"]["leaks_after"], {"missing-doc-path": 1})
        self.assertEqual(report["packages"]["Tools"]["kept_by"], {"shebang": 1})
        self.assertEqual(report["verify"]["failed"], 0)
        self.assertEqual([(c["before_exit"], c["after_exit"], c["same"]) for c in report["check_commands"]],
                         [(0, 0, True), (0, 0, False)])
        with open(os.path.join(out, "why-candidates.txt")) as handle:
            why = handle.read()
        self.assertIn("Packages/Kit/Sources/Kit/A.swift:4 [high", why)
        self.assertIn("Gmail returns 429", why)
        for name in ("summary.txt", "report.json", "removed-comments.tsv", "verify.txt", "leaks-before.txt",
                     "leaks-after.txt", "strip.diff", "checks.txt"):
            self.assertTrue(os.path.exists(os.path.join(out, name)), name)
        with open(os.path.join(out, "report.json")) as handle:
            self.assertEqual(json.load(handle)["totals"]["removed"], 5)

    def test_why_classifier(self):
        self.assertEqual(dry_run.classify_why("Never send the token to an untrusted host."), ("high", ["security"]))
        self.assertEqual(dry_run.classify_why("The list of rows."), (None, []))
        self.assertEqual(dry_run.classify_why("The thread's Gmail id."), (None, []))
        self.assertEqual(dry_run.classify_why("Kept so that the list does not jump."), ("medium", ["reason"]))
        self.assertEqual(dry_run.classify_why("TODO: tidy"), ("medium", ["todo"]))


if __name__ == "__main__":
    unittest.main()
