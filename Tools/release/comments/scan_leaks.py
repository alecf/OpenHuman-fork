#!/usr/bin/env python3
"""List references a public source tree should not carry, as path:line: [pattern] text.

Built-in patterns:
  missing-doc-path    a docs/... path that does not exist in the scanned tree (or relative to the file)
  process-author      "author" in prose
  process-coordinator "coordinator" in prose
  process-overnight   "overnight" in prose
  process-session     "session" used for a working session (previous session, session handoff, ...)
  process-agent       "agent" used for an AI worker (subagent, per-package agent, AGENTS.md, ...)
  home-path           /Users/<name>, /home/<name> or ~/Projects style personal paths
  email-personal      an address at a consumer mail provider (gmail.com, icloud.com, outlook.com, ...)
  email-other         any other address outside the reserved example/test domains
  ai-trailer          assistant co-author or session trailers
  commit-identity     author or committer addresses of the scanned commits (with --git-log)

Prose means comments and string literals in Swift and Python, and the whole text of every other file. Patterns
marked prose-only do not match identifiers.

--patterns FILE adds patterns, one per line: NAME REGEX, or NAME:prose REGEX for prose-only. Lines starting with #
are ignored. Use it for names that must not be written into this repository, such as private repository names.

Files: every tracked file under --root (or every file when --root is not a git checkout), skipping binary files and
this tool's own directory (--include-self scans it too). --git-log also scans commit messages of RANGE (default
HEAD).
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import lexers

RESERVED_EMAIL_DOMAINS = re.compile(
    r"(?i)(?:^|\.)(?:example\.(?:com|net|org)|example|test|invalid|localhost|local|users\.noreply\.github\.com)$")
PLACEHOLDER_USERS = {"shared", "you", "your", "me", "user", "username", "runner", "example", "name", "someone",
                     "jane", "john", "alice", "bob", "foo", "x", "xxx", "admin", "guest"}
BINARY_EXTENSIONS = (".png", ".jpg", ".jpeg", ".gif", ".pdf", ".ico", ".icns", ".heic", ".sqlite", ".db", ".zip",
                     ".gz", ".dmg", ".mlmodel", ".bin", ".car", ".ttf", ".otf", ".woff", ".woff2", ".mp4", ".mov")

SESSION = (r"(?i)\b(?:previous|prior|earlier|later|next|future|planning|coding|agent|ai|overnight|"
           r"review|fix(?:ing)?|handoff|claude|codex|chat)\s+sessions?\b"
           r"|\bsessions?\s+(?:handoffs?|briefs?|instructions?|transcripts?|summar(?:y|ies))\b"
           r"|\bsession\s+\d+\b"
           r"|\b(?:this|that|a|the)\s+session\s+(?:found|verified|fixed|decided|reviewed|ran|wrote|measured|confirmed|"
           r"added|changed|left|did)\b")
AGENT = (r"(?i)\bsub-?agents?\b"
         r"|\bper-(?:package|module|area|file)\s+agents?\b"
         r"|\b(?:coding|worker|fixer|writer|reviewer|research)\s+agents?\b"
         r"|\bas\s+agents\s+must\b|\bagents?\s+(?:must|should)\s+(?:not\s+)?(?:run|use|read|follow|set)\b"
         r"|\bagent(?:'s)?\s+(?:briefs?|handoffs?)\b"
         r"|\bCLAUDE\.md\b")
CONSUMER_EMAIL_DOMAINS = re.compile(
    r"(?i)^(?:g(?:oogle)?mail\.com|icloud\.com|me\.com|mac\.com|outlook\.com|hotmail\.com|live\.com|msn\.com|"
    r"yahoo\.[a-z.]+|aol\.com|proton(?:mail)?\.(?:me|com|ch)|pm\.me|fastmail\.(?:com|fm)|hey\.com|gmx\.[a-z.]+|"
    r"zoho\.com|yandex\.[a-z]+|mail\.ru|qq\.com|163\.com)$")
EMAIL = r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b"
HOME = r"(?:/Users|/home)/[A-Za-z0-9._-]+|~/(?:Projects|Developer|src|code|work|repos)\b"
DOC_PATH = r"[\w./-]*\bdocs/[\w./-]+"
AI_TRAILER = (r"(?im)^[ \t]*(?:co-authored-by:.*\b(?:claude|codex|copilot|gpt|gemini|anthropic|openai)\b"
              r"|claude-session:)")


@dataclass
class Pattern:
    name: str
    regex: "re.Pattern[str]"
    prose: bool = False
    accept: Optional[Callable[[str, "Context"], bool]] = None


@dataclass
class Context:
    root: str
    path: str
    tree: frozenset


@dataclass
class Hit:
    pattern: str
    location: str
    line: int
    text: str
    match: str

    def format(self) -> str:
        where = "%s:%d" % (self.location, self.line) if self.line else self.location
        return "%s: [%s] %s" % (where, self.pattern, self.text)


def _email_ok(match: str, ctx: Context) -> bool:
    local, domain = match.rsplit("@", 1)
    domain = domain.rstrip(".")
    if re.fullmatch(r"(?i)no-?reply|do-?not-?reply", local):
        return False
    if RESERVED_EMAIL_DOMAINS.search(domain):
        return False
    if re.search(r"(?i)\.(?:png|jpe?g|gif|pdf|svg)$", domain) or re.fullmatch(r"\d+x\.\w+", domain):
        return False
    return True


def _personal_email(match: str, ctx: Context) -> bool:
    return _email_ok(match, ctx) and bool(CONSUMER_EMAIL_DOMAINS.match(match.rsplit("@", 1)[1].rstrip(".")))


def _other_email(match: str, ctx: Context) -> bool:
    return _email_ok(match, ctx) and not CONSUMER_EMAIL_DOMAINS.match(match.rsplit("@", 1)[1].rstrip("."))


def _home_ok(match: str, ctx: Context) -> bool:
    if match.startswith("~"):
        return True
    user = match.split("/")[2]
    return len(user) > 1 and user.lower() not in PLACEHOLDER_USERS


def _doc_path_ok(match: str, ctx: Context) -> bool:
    if match.startswith("//") or re.match(r"^[\w-]+(?:\.[\w-]+)+/", match):
        return False
    candidate = match.rstrip(".,:;)")
    candidate = candidate.split("#", 1)[0]
    if not candidate:
        return False
    tree = ctx.tree
    norm = os.path.normpath(candidate)
    if _in_tree(norm, tree):
        return False
    relative = os.path.normpath(os.path.join(os.path.dirname(ctx.path), candidate))
    if _in_tree(relative, tree):
        return False
    tail = norm[norm.find("docs/"):] if "docs/" in norm else norm
    if _in_tree(tail, tree):
        return False
    return True


def _in_tree(path: str, tree: frozenset) -> bool:
    path = re.split(r"[*<{]", path, maxsplit=1)[0].rstrip("/")
    return path in tree


def tree_index(files: Iterable[str]) -> frozenset:
    out = set()
    for f in files:
        out.add(f)
        parts = f.split("/")
        for k in range(1, len(parts)):
            out.add("/".join(parts[:k]))
    return frozenset(out)


def builtin_patterns() -> List[Pattern]:
    return [
        Pattern("missing-doc-path", re.compile(DOC_PATH), accept=_doc_path_ok),
        Pattern("process-author", re.compile(r"(?i)\bauthor(?:'s|s)?\b"), prose=True),
        Pattern("process-coordinator", re.compile(r"(?i)\bcoordinators?(?:'s)?\b"), prose=True),
        Pattern("process-overnight", re.compile(r"(?i)\bovernight\b"), prose=True),
        Pattern("process-session", re.compile(SESSION), prose=True),
        Pattern("process-agent", re.compile(AGENT), prose=True),
        Pattern("home-path", re.compile(HOME), accept=_home_ok),
        Pattern("email-personal", re.compile(EMAIL), accept=_personal_email),
        Pattern("email-other", re.compile(EMAIL), accept=_other_email),
        Pattern("ai-trailer", re.compile(AI_TRAILER)),
    ]


def load_patterns(path: str) -> List[Pattern]:
    out = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                raise SystemExit("bad pattern line: " + line)
            name, regex = parts
            prose = name.endswith(":prose")
            if prose:
                name = name[: -len(":prose")]
            try:
                out.append(Pattern(name, re.compile(regex), prose=prose))
            except re.error as exc:
                raise SystemExit("bad regex for %s: %s" % (name, exc))
    return out


def list_files(root: str) -> List[str]:
    try:
        raw = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True, capture_output=True).stdout
        files = [p for p in raw.decode("utf-8").split("\0") if p]
    except (subprocess.CalledProcessError, FileNotFoundError):
        files = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in (".git", ".build", ".swiftpm")]
            files.extend(os.path.relpath(os.path.join(dirpath, f), root) for f in filenames)
    return sorted(f for f in files if os.path.isfile(os.path.join(root, f)))


def prose_spans(path: str, text: str) -> Optional[List[Tuple[int, int]]]:
    language = lexers.detect_language(path, text[:200])
    if language not in ("swift", "python"):
        return None
    try:
        lexed = lexers.lex(language, text)
    except (lexers.LexError, RecursionError):
        return None
    spans = [(c.start, c.end) for c in lexed.comments] + list(lexed.strings)
    return sorted(spans)


def _inside(spans: List[Tuple[int, int]], offset: int) -> bool:
    lo, hi = 0, len(spans)
    while lo < hi:
        mid = (lo + hi) // 2
        if spans[mid][0] <= offset:
            lo = mid + 1
        else:
            hi = mid
    return lo > 0 and spans[lo - 1][0] <= offset < spans[lo - 1][1]


def scan_text(location: str, text: str, patterns: Sequence[Pattern], ctx: Context,
              spans: Optional[List[Tuple[int, int]]] = None) -> List[Hit]:
    hits = []
    starts = lexers.line_starts(text)
    lines = text.split("\n")
    for pattern in patterns:
        seen_lines = set()
        for m in pattern.regex.finditer(text):
            if pattern.prose and spans is not None and not _inside(spans, m.start()):
                continue
            if pattern.accept and not pattern.accept(m.group(0), ctx):
                continue
            line = lexers.offset_to_line(starts, m.start())
            if line in seen_lines:
                continue
            seen_lines.add(line)
            snippet = lines[line - 1].strip() if line - 1 < len(lines) else ""
            hits.append(Hit(pattern.name, location, line, snippet[:200], m.group(0)))
    return hits


def scan_tree(root: str, patterns: Sequence[Pattern], include_self: bool = False,
              excludes: Sequence[str] = ()) -> List[Hit]:
    files = list_files(root)
    tree = tree_index(files)
    own = os.path.relpath(HERE, root)
    hits: List[Hit] = []
    for rel in files:
        if not include_self and not own.startswith("..") and (rel + "/").startswith(own + "/"):
            continue
        if any(fnmatch.fnmatch(rel, g) for g in excludes):
            continue
        if rel.lower().endswith(BINARY_EXTENSIONS):
            continue
        with open(os.path.join(root, rel), "rb") as handle:
            data = handle.read()
        if b"\0" in data[:8192]:
            continue
        text = data.decode("utf-8", "replace")
        ctx = Context(root, rel, tree)
        hits.extend(scan_text(rel, text, patterns, ctx, prose_spans(rel, text)))
    return hits


def scan_git_log(root: str, revision: str, patterns: Sequence[Pattern]) -> List[Hit]:
    proc = subprocess.run(["git", "-C", root, "log", "--format=%H%x1f%ae%x1f%ce%x1f%B%x1e", revision],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise SystemExit("git log failed: " + proc.stderr.strip())
    hits: List[Hit] = []
    seen_identities = set()
    ctx = Context(root, "", tree_index(list_files(root)))
    for record in proc.stdout.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        sha, author, committer, message = record.split("\x1f", 3)
        location = "commit:" + sha[:12]
        hits.extend(scan_text(location, message, patterns, ctx))
        for role, address in (("author", author), ("committer", committer)):
            if address and address not in seen_identities and _email_ok(address, ctx):
                seen_identities.add(address)
                hits.append(Hit("commit-identity", location + ":" + role, 0, address, address))
    return hits


def summarize(hits: Iterable[Hit]) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for h in hits:
        out[h.pattern] = out.get(h.pattern, 0) + 1
    return dict(sorted(out.items()))


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=".", help="tree to scan (default: current directory)")
    parser.add_argument("--patterns", action="append", default=[], help="extra pattern file (repeatable)")
    parser.add_argument("--only", action="append", default=[], help="report only these pattern names")
    parser.add_argument("--git-log", nargs="?", const="HEAD", metavar="RANGE", help="also scan commit messages")
    parser.add_argument("--include-self", action="store_true", help="scan this tool's own directory too")
    parser.add_argument("--exclude", action="append", default=[], help="glob of paths to skip (repeatable)")
    parser.add_argument("--json", metavar="FILE", help="write the hits as JSON")
    parser.add_argument("--summary", action="store_true", help="print only the counts per pattern")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    patterns = builtin_patterns()
    for path in args.patterns:
        patterns.extend(load_patterns(path))
    if args.only:
        patterns = [p for p in patterns if p.name in args.only]
    hits = scan_tree(root, patterns, args.include_self, args.exclude)
    if args.git_log:
        hits.extend(scan_git_log(root, args.git_log, patterns))
    if not args.summary:
        for h in hits:
            print(h.format())
    counts = summarize(hits)
    print("hits=%d %s" % (len(hits), " ".join("%s=%d" % kv for kv in counts.items())))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump([h.__dict__ for h in hits], handle, indent=1)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
