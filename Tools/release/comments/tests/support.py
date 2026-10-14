import contextlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.dirname(HERE)
sys.path.insert(0, TOOL)

import dry_run
import lexers
import scan_leaks
import strip_comments
import verify_strip


def dedent(text):
    return textwrap.dedent(text).lstrip("\n")


def strip(text, path="Sources/File.swift", **options):
    keep_entries = options.pop("keep_entries", ())
    result = strip_comments.process_text(path, text, strip_comments.Options(keep_entries=keep_entries, **options))
    if result.error:
        raise AssertionError(result.error)
    return result


class TempDirTestCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="comment-tool-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, rel, text, root=None):
        path = os.path.join(root or self.tmp, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        return path


GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_DATE": "2026-01-01T00:00:00Z",
    "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z",
}


def git(repo, *args, author="Dev <dev@example.com>"):
    name, email = author[:-1].split(" <")
    env = dict(os.environ, **GIT_ENV, GIT_AUTHOR_NAME=name, GIT_AUTHOR_EMAIL=email, GIT_COMMITTER_NAME=name,
               GIT_COMMITTER_EMAIL=email)
    return subprocess.run(["git", "-C", repo, "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"]
                          + list(args), check=True, capture_output=True, text=True, env=env).stdout


def swiftc_available():
    return verify_strip.find_swiftc() is not None


def quiet(main, argv):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return main(argv)
