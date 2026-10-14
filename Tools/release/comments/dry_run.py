#!/usr/bin/env python3
"""Rehearse the comment policy on a copy of a repository and report per package.

Copies every tracked file of --repo twice into a work directory (before/ and after/), strips comments in after/,
verifies the two trees, scans both for leaks (and the repository's commit messages), and writes to --out:

  summary.txt          per-package counts: comments, removed, kept, verifier result, leak hits by pattern
  report.json          the same counts as data
  why-candidates.txt   removed comments that probably explain a non-obvious reason, to re-express as one short Why:
                       line: high = security, sanitizing, Gmail behavior or platform terms plus causal wording
                       (because, otherwise, must, never, cannot, workaround, ...); medium = causal wording or a TODO
  removed-comments.tsv every removed comment block
  verify.txt           verifier failures and the per-check tally
  leaks-before.txt     leak hits in the original tree and commit messages
  leaks-after.txt      leak hits that remain once comments are gone
  strip.diff           the full diff the policy would apply
  checks.txt           each --check-command run in both copies: exit codes and whether the output matched

A --check-command is a shell command run from the root of each copy (for example a generator's --check or a
script's --help). Its exit code and output, with the copy's path and decimal-second timings masked, must match.
The repository itself is never modified.
"""
from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Dict, List, Optional, Sequence, Tuple

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import scan_leaks
import strip_comments
import verify_strip

WHY_CATEGORIES = {
    "security": re.compile(
        r"(?i)secur|attack|exploit|inject|\bxss\b|csrf|spoof|phish|malicious|hostile|untrusted|allow-?list|deny-?list|"
        r"block-?list|\bnonce|\bcsp\b|sandbox|quarantine|keychain|secret|credential|\btokens?\b|oauth|pkce|password|"
        r"encrypt|signature|\btls\b|certificate|privacy|leak|redact|safe.?mode|write.?guard|read.?only|refuse|consent|"
        r"exfiltrat|fails? closed|tracker|tracking|permission|entitlement"),
    "sanitizer": re.compile(
        r"(?i)saniti[sz]|escap|\bhtml\b|\bcss\b|webkit|wkwebview|javascript|\bscript|iframe|remote (?:content|image)|"
        r"\bcid:|bidi|homoglyph|normaliz|percent-encod|url-encod|control char"),
    "gmail": re.compile(
        r"(?i)gmail|google|history.?id|label.?ids?\b|quota|rate.?limit|\b429\b|\b403\b|\b404\b|backoff|\bbatch|"
        r"thread.?id|message.?id|\brfc ?\d{3,4}|\bmime\b|multipart|base64|\bheaders?\b|\bimap\b|\bsmtp\b|"
        r"page.?token|list-unsubscribe|one-click|\bdkim\b|\bspf\b|\bics\b|calendar api"),
    "platform": re.compile(
        r"(?i)workaround|work around|\bbug\b|radar|\bFB\d{5,}|appkit|swiftui|uikit|\bNS[A-Z]\w+|first responder|"
        r"responder chain|macos \d|ios \d|xcode|compiler|swift \d|sendable|main.?thread|mainactor|deadlock|"
        r"\brace\b|crash|retain cycle|\bsqlite\b|\bgrdb\b|\bwal\b|filesystem|apfs|launchd|\bxpc\b|foundationmodels|"
        r"\bmlx\b|\bmetal\b|voiceover|run ?loop|reentran"),
}
STRONG_CAUSE = re.compile(
    r"(?i)because|otherwise|so that|in order to|\bmust\b|\bnever\b|cannot|can't|\bdo(?:es)? not\b|don't|\bavoid|"
    r"prevent|workaround|work around|quirk|fails? closed|\bwould\b|\bsilently\b|\bon purpose\b|deliberate|\bhack\b")
TODO = re.compile(r"\b(?:TODO|FIXME|XXX|HACK)\b")


def package_of(rel: str) -> str:
    parts = rel.split("/")
    if parts[0] in ("Packages", "Apps", "Tools") and len(parts) > 2:
        return "/".join(parts[:2])
    if len(parts) == 1:
        return "(root)"
    return parts[0]


def classify_why(text: str) -> Tuple[Optional[str], List[str]]:
    categories = [name for name, rx in WHY_CATEGORIES.items() if rx.search(text)]
    strong = bool(STRONG_CAUSE.search(text))
    todo = bool(TODO.search(text))
    if todo:
        categories.append("todo")
    if categories and strong:
        return "high", categories
    if todo or strong:
        return "medium", categories or ["reason"]
    return None, []


def copy_tracked(repo: str, dest: str) -> List[str]:
    raw = subprocess.run(["git", "-C", repo, "ls-files", "-z"], check=True, capture_output=True).stdout
    files = [p for p in raw.decode("utf-8").split("\0") if p]
    copied = []
    for rel in files:
        src = os.path.join(repo, rel)
        if not os.path.lexists(src) or os.path.isdir(src):
            continue
        target = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(src, target, follow_symlinks=False)
        copied.append(rel)
    return copied


def joined_text(block: strip_comments.Block, language: str) -> str:
    lines = [line.strip() for c in block.comments for line in strip_comments.body_lines(c, language)]
    return " ".join(line for line in lines if line)


_SECONDS = re.compile(r"\b\d+\.\d+ ?s\b")


def run_check(command: str, root: str, timeout: float) -> Tuple[int, str]:
    try:
        proc = subprocess.run(["bash", "-c", command], cwd=root, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return -1, "timed out"
    output = (proc.stdout + "\n--stderr--\n" + proc.stderr).replace(os.path.realpath(root), "<root>")
    return proc.returncode, _SECONDS.sub("<s>", output.replace(root, "<root>"))


def run(repo: str, out: str, options: strip_comments.Options, pattern_files: Sequence[str], use_compiler: bool,
        work: Optional[str], keep_work: bool, log_range: str, check_commands: Sequence[str] = (),
        check_timeout: float = 900) -> Dict:
    repo = os.path.abspath(repo)
    os.makedirs(out, exist_ok=True)
    work_dir = work or tempfile.mkdtemp(prefix="comment-dry-run-")
    before = os.path.join(work_dir, "before")
    after = os.path.join(work_dir, "after")
    for d in (before, after):
        if os.path.exists(d):
            shutil.rmtree(d)
    copy_tracked(repo, before)
    copy_tracked(repo, after)

    results = strip_comments.process_tree(after, options=options, write=True)
    outcomes = verify_strip.verify(before, after, use_compiler=use_compiler)
    checks = []
    for command in check_commands:
        before_exit, before_output = run_check(command, before, check_timeout)
        after_exit, after_output = run_check(command, after, check_timeout)
        checks.append({"command": command, "before_exit": before_exit, "after_exit": after_exit,
                       "same": before_exit == after_exit and before_output == after_output,
                       "after_output": after_output[-2000:]})

    patterns = scan_leaks.builtin_patterns()
    for path in pattern_files:
        patterns.extend(scan_leaks.load_patterns(path))
    own = os.path.relpath(HERE, repo)
    excludes = [own + "/*"] if not own.startswith("..") else []
    hits_before = scan_leaks.scan_tree(before, patterns, excludes=excludes)
    hits_commits = scan_leaks.scan_git_log(repo, log_range, patterns)
    hits_after = scan_leaks.scan_tree(after, patterns, excludes=excludes)

    packages: Dict[str, Dict] = {}

    def pkg(name: str) -> Dict:
        return packages.setdefault(name, {
            "files": 0, "files_changed": 0, "generated_skipped": 0, "errors": 0, "comments": 0, "comment_lines": 0,
            "removed": 0, "removed_lines": 0, "kept": 0, "kept_lines": 0, "kept_by": {}, "flagged": 0,
            "docstrings": 0, "why_high": 0, "why_medium": 0, "verify_pass": 0, "verify_fail": 0,
            "leaks_before": {}, "leaks_after": {}})

    why_rows: List[Tuple[str, str, str, int, int, List[str], str]] = []
    removed_rows: List[str] = ["path\tline\tend_line\tstyle\ttext"]
    diff_chunks: List[str] = []
    for r in results:
        p = pkg(package_of(r.path))
        if r.skipped == "generated":
            p["generated_skipped"] += 1
            continue
        if r.error:
            p["errors"] += 1
            continue
        p["files"] += 1
        p["files_changed"] += int(r.changed)
        for k, v in r.counts().items():
            p[k] += v
        for k, v in r.kept_reasons().items():
            p["kept_by"][k] = p["kept_by"].get(k, 0) + v
        for b in r.blocks:
            if b.keep:
                continue
            text = joined_text(b, r.language)
            removed_rows.append("%s\t%d\t%d\t%s\t%s" % (r.path, b.line, b.end_line, b.style,
                                                         text.replace("\t", " ")))
            tier, categories = classify_why(text)
            if tier:
                p["why_" + tier] += 1
                why_rows.append((package_of(r.path), tier, r.path, b.line, b.end_line, categories, text))
        if r.changed:
            diff_chunks.extend(difflib.unified_diff(r.original.splitlines(True), r.stripped.splitlines(True),
                                                    "a/" + r.path, "b/" + r.path))
    for o in outcomes:
        if o.checks.get("identical") == "pass" and not o.failed:
            continue
        p = pkg(package_of(o.path))
        p["verify_fail" if o.failed else "verify_pass"] += 1
    for hits, key in ((hits_before, "leaks_before"), (hits_after, "leaks_after")):
        for h in hits:
            counts = pkg(package_of(h.location))[key]
            counts[h.pattern] = counts.get(h.pattern, 0) + 1
    for h in hits_commits:
        counts = pkg("(commits)")["leaks_before"]
        counts[h.pattern] = counts.get(h.pattern, 0) + 1

    totals = strip_comments.summarize(results)
    verify_tally = verify_strip.tally(outcomes)
    failures = [o for o in outcomes if o.failed]
    report = {
        "repo_head": subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True,
                                    text=True).stdout.strip(),
        "options": {"keep_mark": options.keep_mark, "keep_public_doc": options.keep_public_doc,
                    "why_max": options.why_max, "doc_max": options.doc_max,
                    "keep_entries": len(options.keep_entries), "swiftc": use_compiler},
        "totals": totals,
        "verify": {"files": len(outcomes), "failed": len(failures), "checks": verify_tally},
        "check_commands": [{k: v for k, v in c.items() if k != "after_output"} for c in checks],
        "leaks_before": scan_leaks.summarize(hits_before),
        "leaks_commits": scan_leaks.summarize(hits_commits),
        "leaks_after": scan_leaks.summarize(hits_after),
        "why": {"high": sum(1 for w in why_rows if w[1] == "high"),
                "medium": sum(1 for w in why_rows if w[1] == "medium")},
        "packages": packages,
        "work_dir": work_dir if keep_work else None,
    }

    def write(name: str, text: str):
        with open(os.path.join(out, name), "w", encoding="utf-8") as handle:
            handle.write(text)

    write("report.json", json.dumps(report, indent=1, sort_keys=True) + "\n")
    write("removed-comments.tsv", "\n".join(removed_rows) + "\n")
    write("strip.diff", "".join(diff_chunks))
    write("verify.txt", "".join("FAIL %s: %s\n" % (o.path, p) for o in failures for p in o.problems)
          + "tally: %s\n" % json.dumps(verify_tally, sort_keys=True))
    write("leaks-before.txt", "".join(h.format() + "\n" for h in hits_before + hits_commits))
    write("leaks-after.txt", "".join(h.format() + "\n" for h in hits_after))
    write("why-candidates.txt", format_why(why_rows))
    write("checks.txt", "".join("%s: before exit %d, after exit %d, %s\n%s\n\n" % (
        c["command"], c["before_exit"], c["after_exit"], "same output" if c["same"] else "OUTPUT DIFFERS",
        "" if c["same"] else c["after_output"]) for c in checks))
    write("summary.txt", format_summary(report))
    if not keep_work:
        shutil.rmtree(work_dir, ignore_errors=True)
    return report


def format_why(rows: List[Tuple[str, str, str, int, int, List[str], str]]) -> str:
    out = ["Removed comments that probably carry a non-obvious reason. Re-express each that still matters as one",
           "short comment starting with 'Why:' (no private references), or let it go.", ""]
    by_package: Dict[str, List] = {}
    for row in rows:
        by_package.setdefault(row[0], []).append(row)
    for name in sorted(by_package):
        entries = by_package[name]
        high = [e for e in entries if e[1] == "high"]
        medium = [e for e in entries if e[1] == "medium"]
        out.append("== %s (high %d, medium %d)" % (name, len(high), len(medium)))
        for tier, group in (("high", high), ("medium", medium)):
            for _, _, path, line, end_line, categories, text in sorted(group, key=lambda e: (e[2], e[3])):
                where = "%s:%d" % (path, line) if line == end_line else "%s:%d-%d" % (path, line, end_line)
                snippet = text if len(text) <= 400 else text[:397] + "..."
                out.append("%s [%s %s] %s" % (where, tier, ",".join(categories), snippet))
        out.append("")
    return "\n".join(out)


def format_summary(report: Dict) -> str:
    t = report["totals"]
    lines = [
        "Comment policy dry run at %s" % report["repo_head"],
        "options: %s" % json.dumps(report["options"], sort_keys=True),
        "",
        "TOTAL files=%d changed=%d generated-skipped=%d errors=%d comments=%d (%d lines) removed=%d (%d lines) "
        "kept=%d (%d lines) flagged=%d python-docstrings-left=%d" % (
            t.get("files", 0), t.get("files_changed", 0), t.get("generated_skipped", 0), t.get("errors", 0),
            t.get("comments", 0), t.get("comment_lines", 0), t.get("removed", 0), t.get("removed_lines", 0),
            t.get("kept", 0), t.get("kept_lines", 0), t.get("flagged", 0), t.get("docstrings", 0)),
        "kept by reason: %s" % " ".join("%s=%d" % (k[5:], v) for k, v in sorted(t.items()) if k.startswith("kept:")),
        "verifier: files=%d failed=%d %s" % (report["verify"]["files"], report["verify"]["failed"],
                                              json.dumps(report["verify"]["checks"], sort_keys=True)),
        "why candidates: high=%d medium=%d" % (report["why"]["high"], report["why"]["medium"]),
        "check commands: %s" % (" ".join("[%s: %d/%d %s]" % (c["command"], c["before_exit"], c["after_exit"],
                                                           "same" if c["same"] else "DIFFERS")
                                         for c in report["check_commands"]) or "none"),
        "leaks before: %s" % " ".join("%s=%d" % kv for kv in report["leaks_before"].items()),
        "leaks in commit messages/identities: %s" % " ".join("%s=%d" % kv for kv in report["leaks_commits"].items()),
        "leaks after stripping: %s" % " ".join("%s=%d" % kv for kv in report["leaks_after"].items()),
        "",
        "%-34s %5s %6s %7s %6s %7s %5s %5s %5s %9s" % (
            "package", "files", "cmts", "lines", "remove", "rm-lns", "keep", "whyH", "whyM", "verify"),
    ]
    for name, p in sorted(report["packages"].items()):
        if name == "(commits)":
            continue
        verify = "fail %d" % p["verify_fail"] if p["verify_fail"] else "pass %d" % p["verify_pass"]
        lines.append("%-34s %5d %6d %7d %6d %7d %5d %5d %5d %9s" % (
            name, p["files"], p["comments"], p["comment_lines"], p["removed"], p["removed_lines"], p["kept"],
            p["why_high"], p["why_medium"], verify))
    lines += ["", "Leak hits by package and pattern (before -> after stripping):"]
    for name, p in sorted(report["packages"].items()):
        patterns = sorted(set(p["leaks_before"]) | set(p["leaks_after"]))
        if not patterns:
            continue
        lines.append("%s: %s" % (name, " ".join(
            "%s=%d->%d" % (k, p["leaks_before"].get(k, 0), p["leaks_after"].get(k, 0)) for k in patterns)))
    return "\n".join(lines) + "\n"


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", default=".", help="repository to rehearse on (default: current directory)")
    parser.add_argument("--out", required=True, help="directory for the reports")
    parser.add_argument("--patterns", action="append", default=[], help="extra leak pattern file (repeatable)")
    parser.add_argument("--keep-mark", action="store_true")
    parser.add_argument("--keep-public-doc", action="store_true")
    parser.add_argument("--doc-max", type=int, default=100)
    parser.add_argument("--why-max", type=int, default=120)
    parser.add_argument("--keep-file")
    parser.add_argument("--keep-pattern", action="append", default=[])
    parser.add_argument("--no-compiler", action="store_true", help="skip the swiftc parse comparison")
    parser.add_argument("--work", help="work directory for the two copies (default: a new temporary directory)")
    parser.add_argument("--keep-work", action="store_true", help="leave the copies in place")
    parser.add_argument("--git-log", default="HEAD", metavar="RANGE", help="commits to scan (default: HEAD)")
    parser.add_argument("--check-command", action="append", default=[],
                        help="shell command to run in both copies and compare (repeatable)")
    parser.add_argument("--check-timeout", type=float, default=900, help="seconds per check command")
    args = parser.parse_args(argv)
    options = strip_comments.Options(args.keep_mark, args.keep_public_doc, args.doc_max, args.why_max,
                                     strip_comments.parse_keep_file(args.keep_file) if args.keep_file else (),
                                     [re.compile(p) for p in args.keep_pattern])
    report = run(args.repo, args.out, options, args.patterns, not args.no_compiler, args.work, args.keep_work,
                 args.git_log, args.check_command, args.check_timeout)
    with open(os.path.join(args.out, "summary.txt"), encoding="utf-8") as handle:
        sys.stdout.write(handle.read())
    differing = [c for c in report["check_commands"] if not c["same"]]
    return 1 if report["verify"]["failed"] or report["totals"].get("errors") or differing else 0


if __name__ == "__main__":
    sys.exit(main())
