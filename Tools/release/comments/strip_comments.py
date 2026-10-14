#!/usr/bin/env python3
"""Remove comments from Swift, Python, shell and YAML sources, keeping only an allow-list.

Kept: shebangs and Python encoding lines; a license header before the first line of code (copyright, license or
SPDX text); tool directives (swift-tools-version, swiftlint, swift-format, sourcery, periphery, the generated-init
markers of Tools/ci/gen-public-inits.py, shellcheck, yamllint, Python type/noqa/pragma/fmt/pylint/mypy); comments
matching --keep-pattern; short one-line comments that start with "Why:"; comments named in a keep file; with
--keep-mark, MARK lines; with --keep-public-doc, one-line doc comments on public or open Swift declarations.
Generated files (a "GENERATED ... Do not edit" or "@generated" header) are skipped. Markdown and other file types
are never touched. Python docstrings are runtime values and are left alone.

Dry run by default. --write edits files in place. --check exits 1 while any file has a removable comment or a
flagged one. Flags: why-too-long (a Why: comment longer than one short line, kept); reads-own-source (a shell
script prints these comment lines, e.g. sed -n '2,9p' "$0", so they are kept until the help text moves into code);
nested-comment (inside a Swift string interpolation or a shell command substitution, left for a person).

Keep file: one entry per line, "path:LINE", "path:FIRST-LAST" or "path:text" (text is a substring of the comment).
A matching entry keeps the whole comment block it touches. Lines starting with # are ignored.
"""
from __future__ import annotations

import argparse
import bisect
import difflib
import fnmatch
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lexers

DIRECTIVES = {
    "swift": re.compile(r"^//\s*(?:swift-tools-version\s*:|swiftlint:|swift-format-ignore|swiftformat:|sourcery:|"
                        r"periphery:|generated-init:|end generated-init|no-generated-init)"),
    "python": re.compile(r"^#\s*(?:type:|noqa\b|pragma\b|fmt:|pylint:|mypy:|isort:|pyright:|ruff:)"),
    "shell": re.compile(r"^#\s*shellcheck\s"),
    "yaml": re.compile(r"^#\s*(?:yamllint\b|yaml-language-server:)"),
}
MARK = re.compile(r"^//\s*MARK:")
LICENSE = re.compile(r"(?i)copyright|SPDX-License-Identifier|licensed under|\b(?:apache|mit|bsd|gpl|lgpl|mpl)\b[\w .-]{0,20}"
                     r"licen[cs]e|^\W*licen[cs]e:")
GENERATED = re.compile(r"\bGENERATED\b|@generated")
DO_NOT_EDIT = re.compile(r"(?i)do not edit")
WHY = re.compile(r"^Why:\s*\S")
SELF_PATH = re.compile(r"\$(?:0\b|\{0\}|\{?BASH_SOURCE)")
READER = re.compile(r"\b(?:sed|awk|head|tail|grep|cat)\b")
SED_RANGE = re.compile(r"sed\s+-n\s+['\"]?(\d+),(\d+)p")
SWIFT_DECL_KEYWORDS = {
    "func", "var", "let", "class", "struct", "enum", "protocol", "init", "subscript", "typealias", "case", "actor",
    "extension", "macro", "associatedtype", "deinit", "operator", "precedencegroup",
}
SUPPORTED_EXTENSIONS = (".swift", ".py", ".sh", ".bash", ".yml", ".yaml")


@dataclass
class Options:
    keep_mark: bool = False
    keep_public_doc: bool = False
    doc_max: int = 100
    why_max: int = 120
    keep_entries: Sequence[Tuple[str, str]] = ()
    keep_patterns: Sequence["re.Pattern[str]"] = ()


@dataclass
class Block:
    comments: List[lexers.Comment]
    line: int
    end_line: int
    style: str
    keep: bool = False
    reason: str = "removed"
    flag: Optional[str] = None

    @property
    def lines(self) -> int:
        return self.end_line - self.line + 1

    def raw(self) -> str:
        return "\n".join(c.text for c in self.comments)


@dataclass
class FileResult:
    path: str
    language: Optional[str]
    skipped: Optional[str] = None
    error: Optional[str] = None
    blocks: List[Block] = field(default_factory=list)
    docstrings: int = 0
    original: str = ""
    stripped: str = ""

    @property
    def changed(self) -> bool:
        return self.stripped != self.original

    def counts(self) -> Dict[str, int]:
        removed = [b for b in self.blocks if not b.keep]
        kept = [b for b in self.blocks if b.keep]
        return {
            "comments": len(self.blocks),
            "comment_lines": sum(b.lines for b in self.blocks),
            "removed": len(removed),
            "removed_lines": sum(b.lines for b in removed),
            "kept": len(kept),
            "kept_lines": sum(b.lines for b in kept),
            "flagged": sum(1 for b in self.blocks if b.flag),
            "docstrings": self.docstrings,
        }

    def kept_reasons(self) -> Dict[str, int]:
        out: Dict[str, int] = {}
        for b in self.blocks:
            if b.keep:
                out[b.reason] = out.get(b.reason, 0) + 1
        return out


def body_lines(comment: lexers.Comment, language: str) -> List[str]:
    text = comment.text
    if language == "swift" and comment.style in ("block", "doc-block"):
        inner = text[3:-2] if comment.style == "doc-block" else text[2:-2]
        lines = [re.sub(r"^\s*\*?[ \t]?", "", line, count=1) for line in inner.split("\n")]
    elif language == "swift":
        lines = [re.sub(r"^///?[ \t]?", "", text, count=1)]
    else:
        lines = [re.sub(r"^#+[ \t]?", "", text, count=1)]
    return [line.rstrip() for line in lines]


def _full_line(text: str, comment: lexers.Comment) -> bool:
    start = text.rfind("\n", 0, comment.start) + 1
    end = text.find("\n", comment.end)
    end = len(text) if end < 0 else end
    return text[start:comment.start].strip() == "" and text[comment.end:end].strip() == ""


def _standalone(comment: lexers.Comment, language: str, keep_patterns: Sequence["re.Pattern[str]"] = ()) -> bool:
    if comment.style in ("shebang", "encoding"):
        return True
    if DIRECTIVES[language].match(comment.text) or any(p.search(comment.text) for p in keep_patterns):
        return True
    return language == "swift" and bool(MARK.match(comment.text))


def group_blocks(text: str, comments: Sequence[lexers.Comment], language: str,
                 keep_patterns: Sequence["re.Pattern[str]"] = ()) -> List[Block]:
    blocks: List[Block] = []
    previous: Optional[lexers.Comment] = None
    previous_full = False
    for comment in sorted(comments, key=lambda c: c.start):
        full = _full_line(text, comment) and comment.style in ("line", "doc-line")
        if blocks and previous is not None and full and previous_full and comment.line == previous.end_line + 1 \
                and comment.is_doc == previous.is_doc and not _standalone(comment, language, keep_patterns) \
                and not _standalone(previous, language, keep_patterns):
            blocks[-1].comments.append(comment)
            blocks[-1].end_line = comment.end_line
        else:
            blocks.append(Block([comment], comment.line, comment.end_line, comment.style))
        previous, previous_full = comment, full
    return blocks


def parse_keep_file(path: str) -> List[Tuple[str, str]]:
    entries = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = re.match(r"^([^:]+):(.*)$", line)
            if not m or not m.group(2).strip():
                raise SystemExit("bad keep-file entry: " + line)
            entries.append((os.path.normpath(m.group(1).strip()), m.group(2).strip()))
    return entries


def _keep_entry_matches(block: Block, spec: str) -> bool:
    m = re.fullmatch(r"(\d+)(?:-(\d+))?", spec)
    if m:
        first = int(m.group(1))
        last = int(m.group(2) or first)
        return not (last < block.line or first > block.end_line)
    return spec in block.raw()


def _public_declaration_follows(lexed: lexers.Lexed, offset: int) -> bool:
    toks = lexed.tokens
    k = bisect.bisect_left(lexed.token_offsets, offset)
    modifiers = set()
    while k < len(toks):
        kind, text = toks[k][0], toks[k][1]
        if kind == "punct" and text == "@":
            k += 2
            if k < len(toks) and toks[k][0] == "punct" and toks[k][1] == "(":
                depth = 0
                while k < len(toks):
                    if toks[k][1] == "(":
                        depth += 1
                    elif toks[k][1] == ")":
                        depth -= 1
                        if depth == 0:
                            k += 1
                            break
                    k += 1
            continue
        if kind != "ident":
            return False
        if text in SWIFT_DECL_KEYWORDS:
            return bool(modifiers & {"public", "open"})
        modifiers.add(text)
        if k + 1 < len(toks) and toks[k + 1][1] == "(" and k + 3 < len(toks) and toks[k + 3][1] == ")":
            k += 4
            continue
        k += 1
    return False


def self_read_ranges(text: str, lexed: lexers.Lexed) -> Tuple[bool, List[Tuple[int, int]]]:
    single_quoted = [(s, e) for s, e in lexed.strings if text[s] == "'"]
    found = False
    ranges = []
    for m in SELF_PATH.finditer(text):
        if any(s <= m.start() < e for s, e in single_quoted):
            continue
        line_start = text.rfind("\n", 0, m.start()) + 1
        line_end = text.find("\n", m.start())
        line = text[line_start:len(text) if line_end < 0 else line_end]
        if not READER.search(line):
            continue
        if line[:m.start() - line_start].count("'") % 2 == 1:
            continue
        found = True
        for r in SED_RANGE.finditer(line):
            ranges.append((int(r.group(1)), int(r.group(2))))
    return found, ranges


def classify(path: str, text: str, language: str, lexed: lexers.Lexed, blocks: List[Block], options: Options):
    first_code = lexed.token_offsets[0] if lexed.token_offsets else len(text)
    reads_itself, help_ranges = self_read_ranges(text, lexed) if language == "shell" else (False, [])
    if reads_itself and not help_ranges:
        first = next((b for b in blocks if b.style != "shebang"), None)
        if first is not None:
            help_ranges = [(first.line, first.end_line)]
    directive = DIRECTIVES[language]
    keep_specs = [spec for entry_path, spec in options.keep_entries if entry_path == os.path.normpath(path)]
    for block in blocks:
        first = block.comments[0]
        bodies = [line for c in block.comments for line in body_lines(c, language)]
        first_body = next((line.strip() for line in bodies if line.strip()), "")
        if block.style in ("shebang", "encoding"):
            block.keep, block.reason = True, block.style
        elif any(not (last < block.line or start > block.end_line) for start, last in help_ranges):
            block.keep, block.reason, block.flag = True, "help-text", "reads-own-source"
        elif first.start < first_code and LICENSE.search(block.raw()):
            block.keep, block.reason = True, "license"
        elif all(directive.match(c.text) for c in block.comments):
            block.keep, block.reason = True, "directive"
        elif options.keep_patterns and all(any(p.search(c.text) for p in options.keep_patterns)
                                           for c in block.comments):
            block.keep, block.reason = True, "keep-pattern"
        elif any(_keep_entry_matches(block, spec) for spec in keep_specs):
            block.keep, block.reason = True, "keep-file"
        elif WHY.match(first_body):
            block.keep, block.reason = True, "why"
            nonblank = [line for line in bodies if line.strip()]
            if len(nonblank) > 1 or len(first_body) > options.why_max:
                block.flag = "why-too-long"
        elif language == "swift" and MARK.match(first.text) and len(block.comments) == 1:
            if options.keep_mark:
                block.keep, block.reason = True, "mark"
        elif language == "swift" and options.keep_public_doc and block.style.startswith("doc") \
                and len([line for line in bodies if line.strip()]) == 1 and len(first_body) <= options.doc_max \
                and _public_declaration_follows(lexed, block.comments[-1].end):
            block.keep, block.reason = True, "public-doc"


def is_generated(text: str) -> bool:
    head = "\n".join(text.split("\n", 6)[:6])
    return bool(GENERATED.search(head) and (DO_NOT_EDIT.search(head) or "@generated" in head))


def process_text(path: str, text: str, options: Options, language: Optional[str] = None) -> FileResult:
    language = language or lexers.detect_language(path, text[:200])
    result = FileResult(path, language, original=text, stripped=text)
    if language is None:
        result.skipped = "unsupported"
        return result
    if is_generated(text):
        result.skipped = "generated"
        return result
    try:
        lexed = lexers.lex(language, text)
    except (lexers.LexError, RecursionError) as exc:
        result.error = str(exc)
        return result
    blocks = group_blocks(text, lexed.comments, language, options.keep_patterns)
    classify(path, text, language, lexed, blocks, options)
    for comment in lexed.nested:
        blocks.append(Block([comment], comment.line, comment.end_line, comment.style, keep=True, reason="nested",
                            flag="nested-comment"))
    blocks.sort(key=lambda b: b.comments[0].start)
    result.blocks = blocks
    if language == "python":
        result.docstrings = len(lexers.python_docstrings(text))
    comments = [c for b in blocks if b.reason != "nested" for c in b.comments]
    remove = [not b.keep for b in blocks if b.reason != "nested" for _ in b.comments]
    result.stripped = lexers.remove_comments(text, comments, remove, language)
    return result


def list_files(root: str, paths: Sequence[str], excludes: Sequence[str]) -> List[str]:
    candidates: List[str] = []
    if paths:
        for p in paths:
            full = p if os.path.isabs(p) else os.path.join(root, p)
            if os.path.isdir(full):
                for dirpath, dirnames, filenames in os.walk(full):
                    dirnames[:] = [d for d in dirnames if d not in (".git", ".build", "build", ".swiftpm")]
                    for f in filenames:
                        candidates.append(os.path.relpath(os.path.join(dirpath, f), root))
            else:
                candidates.append(os.path.relpath(full, root))
    else:
        candidates = tracked_files(root)
    out = []
    for rel in sorted(set(candidates)):
        if any(fnmatch.fnmatch(rel, pattern) for pattern in excludes):
            continue
        out.append(rel)
    return out


def tracked_files(root: str) -> List[str]:
    try:
        raw = subprocess.run(["git", "-C", root, "ls-files", "-z"], check=True, capture_output=True).stdout
        return [p for p in raw.decode("utf-8").split("\0") if p and os.path.isfile(os.path.join(root, p))]
    except (subprocess.CalledProcessError, FileNotFoundError):
        out = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in (".git", ".build", "build", ".swiftpm")]
            for f in filenames:
                out.append(os.path.relpath(os.path.join(dirpath, f), root))
        return out


def candidate_language(root: str, rel: str) -> Optional[str]:
    full = os.path.join(root, rel)
    if os.path.islink(full):
        return None
    if rel.endswith(SUPPORTED_EXTENSIONS):
        return lexers.detect_language(rel)
    if os.path.splitext(rel)[1]:
        return None
    try:
        with open(full, "rb") as handle:
            head = handle.read(200)
    except OSError:
        return None
    if b"\0" in head:
        return None
    return lexers.detect_language(rel, head.decode("utf-8", "replace"))


def process_tree(root: str, paths: Sequence[str] = (), options: Optional[Options] = None,
                 excludes: Sequence[str] = (), write: bool = False) -> List[FileResult]:
    options = options or Options()
    results = []
    for rel in list_files(root, paths, excludes):
        language = candidate_language(root, rel)
        if language is None:
            continue
        full = os.path.join(root, rel)
        with open(full, "rb") as handle:
            data = handle.read()
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError:
            results.append(FileResult(rel, language, error="not UTF-8"))
            continue
        result = process_text(rel, text, options, language)
        results.append(result)
        if write and result.changed and not result.error:
            with open(full, "w", encoding="utf-8", newline="") as handle:
                handle.write(result.stripped)
    return results


def summarize(results: Sequence[FileResult]) -> Dict[str, int]:
    total: Dict[str, int] = {"files": 0, "files_changed": 0, "errors": 0, "generated_skipped": 0}
    for r in results:
        if r.skipped == "generated":
            total["generated_skipped"] += 1
            continue
        if r.error:
            total["errors"] += 1
            continue
        total["files"] += 1
        total["files_changed"] += int(r.changed)
        for k, v in r.counts().items():
            total[k] = total.get(k, 0) + v
        for k, v in r.kept_reasons().items():
            total["kept:" + k] = total.get("kept:" + k, 0) + v
    return total


def first_line(block: Block, language: str) -> str:
    for c in block.comments:
        for line in body_lines(c, language):
            if line.strip():
                return line.strip()
    return ""


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", help="files or directories (default: every tracked file under --root)")
    parser.add_argument("--root", default=".", help="repository root (default: current directory)")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="edit files in place")
    mode.add_argument("--check", action="store_true", help="exit 1 when anything would be removed or is flagged")
    parser.add_argument("--diff", action="store_true", help="print a unified diff of the changes")
    parser.add_argument("--list", action="store_true", help="list every removed and flagged comment")
    parser.add_argument("--json", metavar="FILE", help="write per-file counts and decisions as JSON")
    parser.add_argument("--keep-mark", action="store_true", help="keep // MARK: lines")
    parser.add_argument("--keep-public-doc", action="store_true",
                        help="keep one-line doc comments on public/open Swift declarations")
    parser.add_argument("--doc-max", type=int, default=100, help="longest public doc comment kept (characters)")
    parser.add_argument("--why-max", type=int, default=120, help="longest Why: comment accepted (characters)")
    parser.add_argument("--keep-file", help="reviewer keep list")
    parser.add_argument("--keep-pattern", action="append", default=[],
                        help="regular expression; comments whose text matches are kept (repeatable)")
    parser.add_argument("--exclude", action="append", default=[], help="glob of paths to skip (repeatable)")
    args = parser.parse_args(argv)

    root = os.path.abspath(args.root)
    options = Options(args.keep_mark, args.keep_public_doc, args.doc_max, args.why_max,
                      parse_keep_file(args.keep_file) if args.keep_file else (),
                      [re.compile(p) for p in args.keep_pattern])
    results = process_tree(root, args.paths, options, args.exclude, write=args.write)

    for r in results:
        if r.error:
            print("%s: ERROR %s" % (r.path, r.error), file=sys.stderr)
        if args.list:
            for b in r.blocks:
                if not b.keep or b.flag:
                    tag = b.flag or "remove"
                    print("%s:%d-%d: [%s] %s" % (r.path, b.line, b.end_line, tag, first_line(b, r.language)[:160]))
        if args.diff and r.changed:
            sys.stdout.writelines(difflib.unified_diff(
                r.original.splitlines(True), r.stripped.splitlines(True), "a/" + r.path, "b/" + r.path))
    total = summarize(results)
    if args.json:
        payload = {"summary": total, "files": [
            {"path": r.path, "language": r.language, "skipped": r.skipped, "error": r.error, "changed": r.changed,
             "counts": r.counts(), "kept": r.kept_reasons(),
             "blocks": [{"line": b.line, "end_line": b.end_line, "style": b.style, "keep": b.keep,
                         "reason": b.reason, "flag": b.flag, "text": b.raw()} for b in r.blocks]}
            for r in results]}
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=1)
    print(" ".join("%s=%d" % (k, v) for k, v in sorted(total.items())))
    if total["errors"]:
        return 2
    if args.check and (total.get("removed", 0) or total.get("flagged", 0)):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
