#!/usr/bin/env python3
"""Check added Swift test lines for sleeps, elapsed-time assertions, real services, raw temporary paths and raw
defaults suites.

Usage: Tools/ci/check-test-patterns.py [--base origin/main] [--diff-file FILE]
Allow an intentional pattern with // flake-ok: <reason>, a temporary path with // temp-ok: <reason>, or a defaults
suite with // defaults-ok: <reason>.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

BANNED = [
    (re.compile(r"\b(Task|Thread)\.sleep\b|\busleep\("), "fixed sleep: await the real signal or inject a test clock"),
    (re.compile(r"ContinuousClock\(\)\s*\.measure|\bclock\.measure\b|\.measure\s*\{"), "wall-clock measurement"),
    (re.compile(r"timeIntervalSince\([^)]*\)\s*(<|<=)"), "elapsed-time assertion"),
    (re.compile(r"\belapsed\s*(<|<=)"), "elapsed-time assertion"),
    (re.compile(r"\bWKWebView\("), "real WKWebView in a unit test: use a seam (or flake-ok for the one real-service test)"),
    (re.compile(r"QLPreviewPanel\.shared"), "real Quick Look panel: use a seam"),
    (re.compile(r"\bSecItem(Add|CopyMatching|Delete|Update)\b"), "real Keychain: use an in-memory fake"),
]
WARN = re.compile(r"(?<!func )\b(eventually|waitUntil|waitFor|eventuallyAsync)\s*[({]|\buntil\s*(\(|\{)")
OK = re.compile(r"//\s*flake-ok:\s*\S")
TEMP = re.compile(r"\.temporaryDirectory\b|\bNSTemporaryDirectory\s*\(|\bmk[ds]temp\s*\(|\.itemReplacementDirectory\b")
TEMP_OK = re.compile(r"//\s*temp-ok:\s*\S")
TEMP_HELPER = {"Packages/OpenHumanCore/Tests/OpenHumanCoreTests/TemporaryDirectoryTests.swift"}
DEFAULTS = re.compile(r"\bUserDefaults(\.init)?\s*\(\s*suiteName\s*:")
DEFAULTS_OK = re.compile(r"//\s*defaults-ok:\s*\S")
DEFAULTS_HELPER = {"Packages/OpenHumanCore/Tests/OpenHumanCoreTests/ScopedDefaultsTests.swift"}


def is_test(path: str) -> bool:
    p = Path(path)
    return p.suffix == ".swift" and "Tests" in p.parts


def run(args: list[str]) -> str:
    return subprocess.run(args, capture_output=True, text=True).stdout


def added_lines(base: str) -> list[tuple[str, int, str]]:
    out: list[tuple[str, int, str]] = []
    diff = run(["git", "diff", "-U0", "--no-color", f"{base}...HEAD"]) + run(["git", "diff", "-U0", "--no-color", "HEAD"])
    path, line = "", 0
    for raw in diff.splitlines():
        if raw.startswith("+++ "):
            path = raw[6:] if raw.startswith("+++ b/") else ""
        elif raw.startswith("@@"):
            m = re.search(r"\+(\d+)", raw)
            line = int(m.group(1)) if m else 0
        elif raw.startswith("+") and not raw.startswith("+++"):
            if path and is_test(path):
                out.append((path, line, raw[1:]))
            line += 1
    for f in run(["git", "ls-files", "--others", "--exclude-standard"]).split("\n"):
        if f and is_test(f):
            for i, l in enumerate(Path(f).read_text(errors="replace").splitlines(), 1):
                out.append((f, i, l))
    return out


def check(lines: list[tuple[str, int, str]]) -> tuple[list[str], list[str]]:
    bad, warn = [], []
    for path, n, text in lines:
        code = text.split("//")[0] if "flake-ok" not in text else text
        if OK.search(text):
            continue
        stripped = text.lstrip()
        if stripped.startswith("//") or stripped.startswith("///"):
            continue
        for rx, why in BANNED:
            if rx.search(text.split("//")[0]):
                bad.append(f"{path}:{n}: {why}: {text.strip()[:110]}")
                break
        else:
            if TEMP.search(text.split("//")[0]) and path not in TEMP_HELPER and not TEMP_OK.search(text):
                bad.append(f"{path}:{n}: raw temporary path: use TemporaryDirectory so the test removes it: "
                           f"{text.strip()[:110]}")
            elif DEFAULTS.search(text.split("//")[0]) and path not in DEFAULTS_HELPER and not DEFAULTS_OK.search(text):
                bad.append(f"{path}:{n}: raw defaults suite: use ScopedDefaults so the test removes it: "
                           f"{text.strip()[:110]}")
            elif WARN.search(text.split("//")[0]):
                warn.append(f"{path}:{n}: polling helper: {text.strip()[:110]}")
    return bad, warn


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="origin/main")
    ap.add_argument("--diff-file", help="test hook: lines as 'path:line:text'")
    a = ap.parse_args()
    if a.diff_file:
        lines = []
        for l in Path(a.diff_file).read_text().splitlines():
            p, n, t = l.split(":", 2)
            if is_test(p):
                lines.append((p, int(n), t))
    else:
        lines = added_lines(a.base)
    bad, warn = check(lines)
    for w in warn:
        print("warn  " + w)
    for b in bad:
        print("FAIL  " + b)
    if bad:
        print(f"check-test-patterns: {len(bad)} banned pattern(s) in new test code; "
              "(or add `// flake-ok: <reason>`, `// temp-ok: <reason>` for a temporary path, "
              "or `// defaults-ok: <reason>` for a defaults suite)")
        return 1
    print(f"check-test-patterns: OK ({len(lines)} added test line(s), {len(warn)} warning(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
