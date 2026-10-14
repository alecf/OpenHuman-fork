#!/usr/bin/env python3
"""Prove that two trees differ only in comments and meaningless whitespace.

Every file must exist in both trees. Files that differ must be Swift, Python, shell or YAML, and for each pair:

  tokens   the comment-free token streams are equal (Swift tokens carry operator spacing and line-start flags)
  parser   Swift: `swiftc -frontend -dump-parse` output is equal once source locations are removed
           Python: `ast.dump` is equal
           shell: bash parses both and prints the same function body (`declare -f`)
           YAML: the composed node trees are equal (PyYAML when installed, otherwise Ruby's Psych)

Any difference is printed and the exit status is 1. A parser that is not installed is reported as skipped;
--require-parsers turns a skip into a failure.
"""
from __future__ import annotations

import argparse
import ast
import json
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lexers

SKIP_DIRS = {".git", ".build", ".swiftpm"}


@dataclass
class Outcome:
    path: str
    language: Optional[str]
    checks: Dict[str, str] = field(default_factory=dict)
    problems: List[str] = field(default_factory=list)

    @property
    def failed(self) -> bool:
        return bool(self.problems)


def walk(root: str) -> List[str]:
    out = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            out.append(os.path.relpath(os.path.join(dirpath, name), root))
    return sorted(out)


def _describe_token(tok: tuple) -> str:
    flags = "".join("1" if x else "0" for x in tok[2:])
    return repr(tok[1])[:60] + " " + tok[0] + (" " + flags if flags else "")


def compare_tokens(language: str, before: str, after: str) -> Optional[str]:
    a = lexers.lex(language, before)
    b = lexers.lex(language, after)
    if a.tokens == b.tokens:
        return None
    starts_a = lexers.line_starts(before)
    starts_b = lexers.line_starts(after)
    k = 0
    while k < min(len(a.tokens), len(b.tokens)) and a.tokens[k] == b.tokens[k]:
        k += 1
    where_a = lexers.offset_to_line(starts_a, a.token_offsets[k]) if k < len(a.tokens) else "end"
    where_b = lexers.offset_to_line(starts_b, b.token_offsets[k]) if k < len(b.tokens) else "end"
    left = _describe_token(a.tokens[k]) if k < len(a.tokens) else "<end>"
    right = _describe_token(b.tokens[k]) if k < len(b.tokens) else "<end>"
    return "token %d differs: before line %s %s / after line %s %s" % (k, where_a, left, where_b, right)


_RANGE = re.compile(r"\s*\b\w*(?:range|location|loc)=\[[^\]]*\]")
_ADDRESS = re.compile(r"0x[0-9a-fA-F]+")
_LOCATION = re.compile(r"([\w./+@-]+\.swift):\d+:\d+")
_DIAGNOSTIC = re.compile(r"^(.*?\.swift):\d+:\d+: (error|warning|note|remark): (.*)$")


def find_swiftc() -> Optional[List[str]]:
    if shutil.which("xcrun"):
        found = subprocess.run(["xcrun", "--find", "swiftc"], capture_output=True, text=True)
        if found.returncode == 0 and found.stdout.strip():
            return [found.stdout.strip()]
    path = shutil.which("swiftc")
    return [path] if path else None


def swift_parse_dump(swiftc: Sequence[str], root: str, rel: str) -> str:
    proc = subprocess.run(list(swiftc) + ["-frontend", "-dump-parse", "-swift-version", "6",
                                          "-diagnostic-style", "llvm", rel],
                          cwd=root, capture_output=True, text=True)
    dump = _ADDRESS.sub("0x", _RANGE.sub("", proc.stdout))
    dump = _LOCATION.sub(r"\1", dump)
    diagnostics = []
    for line in proc.stderr.splitlines():
        m = _DIAGNOSTIC.match(line)
        if m:
            diagnostics.append("%s: %s: %s" % m.groups())
    return "exit=%d\n%s\n%s" % (proc.returncode, "\n".join(diagnostics), dump)


def python_ast(text: str) -> str:
    try:
        return ast.dump(ast.parse(text))
    except SyntaxError as exc:
        return "SyntaxError: %s" % exc.msg


_SHELL_PROLOGUE = (
    'for __strip_verify_b in $(compgen -b); do\n'
    '  case "$__strip_verify_b" in declare|enable) ;; *) enable -n "$__strip_verify_b" ;; esac\n'
    'done\n'
    'enable -n enable\n'
)


def shell_canonical(text: str, timeout: float = 30) -> str:
    """Why: the body is defined, never called, in a restricted shell with no PATH and no builtins but declare,
    so a script that closes the function early cannot run commands or write files."""
    name = "__strip_verify_body__"
    program = "%s%s() {\n%s\n}\ndeclare -f %s\n" % (_SHELL_PROLOGUE, name, text, name)
    bash = shutil.which("bash") or "/bin/bash"
    try:
        proc = subprocess.run([bash, "--noprofile", "--norc", "-r", "-s"], input=program, capture_output=True,
                              text=True, env={"PATH": "", "LC_ALL": "C"}, timeout=timeout)
    except subprocess.TimeoutExpired:
        return "timed out"
    errors = re.sub(r"line \d+", "line N", proc.stderr)
    return "exit=%d\n%s\n%s" % (proc.returncode, errors, proc.stdout)


_RUBY_YAML = r"""
require 'psych'
def d(n)
  case n
  when Psych::Nodes::Scalar then ['S', n.tag, n.value, n.style, n.anchor]
  when Psych::Nodes::Alias then ['A', n.anchor]
  else [n.class.name.split('::').last, (n.tag rescue nil), (n.anchor rescue nil), n.children.map { |c| d(c) }]
  end
end
begin
  print d(Psych.parse_stream(STDIN.read)).inspect
rescue Psych::SyntaxError => e
  print 'SyntaxError ' + e.problem.to_s
end
"""


def _pyyaml():
    try:
        import yaml
        return yaml
    except ImportError:
        return None


def yaml_tree(text: str) -> Optional[str]:
    yaml = _pyyaml()
    if yaml is not None:
        def d(node):
            if isinstance(node, yaml.ScalarNode):
                return ["S", node.tag, node.value, node.style]
            if isinstance(node, yaml.SequenceNode):
                return ["Seq", node.tag, [d(x) for x in node.value]]
            return ["Map", node.tag, [[d(k), d(v)] for k, v in node.value]]
        try:
            return json.dumps([d(n) for n in yaml.compose_all(text, Loader=yaml.SafeLoader)])
        except yaml.YAMLError as exc:
            return "YAMLError " + str(getattr(exc, "problem", exc))
    if shutil.which("ruby"):
        proc = subprocess.run(["ruby", "-e", _RUBY_YAML], input=text, capture_output=True, text=True)
        if proc.returncode == 0:
            return proc.stdout
    return None


def _read(path: str) -> Optional[bytes]:
    with open(path, "rb") as handle:
        return handle.read()


def verify(before_root: str, after_root: str, paths: Optional[Sequence[str]] = None, use_compiler: bool = True,
           require_parsers: bool = False, jobs: int = 0) -> List[Outcome]:
    if paths is None:
        before_files = set(walk(before_root))
        after_files = set(walk(after_root))
        paths = sorted(before_files | after_files)
    swiftc = find_swiftc() if use_compiler else None
    outcomes: List[Outcome] = []
    swift_jobs: List[Tuple[Outcome, str]] = []
    for rel in paths:
        a_path = os.path.join(before_root, rel)
        b_path = os.path.join(after_root, rel)
        outcome = Outcome(rel, None)
        outcomes.append(outcome)
        if not os.path.lexists(a_path) or not os.path.lexists(b_path):
            outcome.problems.append("missing from the %s tree" % ("after" if os.path.lexists(a_path) else "before"))
            continue
        if os.path.islink(a_path) or os.path.islink(b_path):
            if os.path.islink(a_path) != os.path.islink(b_path) or os.readlink(a_path) != os.readlink(b_path):
                outcome.problems.append("symbolic link changed")
            continue
        a_bytes, b_bytes = _read(a_path), _read(b_path)
        if a_bytes == b_bytes:
            outcome.checks["identical"] = "pass"
            continue
        head = a_bytes[:200].decode("utf-8", "replace")
        language = lexers.detect_language(rel, head)
        outcome.language = language
        if language is None:
            outcome.problems.append("changed, but it is not a Swift, Python, shell or YAML file")
            continue
        try:
            a_text, b_text = a_bytes.decode("utf-8"), b_bytes.decode("utf-8")
        except UnicodeDecodeError:
            outcome.problems.append("not UTF-8")
            continue
        try:
            difference = compare_tokens(language, a_text, b_text)
        except lexers.LexError as exc:
            outcome.problems.append("tokens: cannot lex: %s" % exc)
            continue
        outcome.checks["tokens"] = "fail" if difference else "pass"
        if difference:
            outcome.problems.append("tokens: " + difference)
        if language == "swift":
            if swiftc:
                swift_jobs.append((outcome, rel))
            else:
                _skip(outcome, "swiftc", require_parsers)
        elif language == "python":
            _record(outcome, "ast", python_ast(a_text), python_ast(b_text))
        elif language == "shell":
            if shutil.which("bash"):
                _record(outcome, "bash", shell_canonical(a_text), shell_canonical(b_text))
            else:
                _skip(outcome, "bash", require_parsers)
        elif language == "yaml":
            a_tree = yaml_tree(a_text)
            if a_tree is None:
                _skip(outcome, "yaml", require_parsers)
            else:
                _record(outcome, "yaml", a_tree, yaml_tree(b_text))
    if swift_jobs:
        def run(job):
            outcome, rel = job
            return outcome, swift_parse_dump(swiftc, before_root, rel), swift_parse_dump(swiftc, after_root, rel)
        with ThreadPoolExecutor(max_workers=jobs or os.cpu_count() or 4) as pool:
            for outcome, a_dump, b_dump in pool.map(run, swift_jobs):
                _record(outcome, "swiftc", a_dump, b_dump)
    return outcomes


def _record(outcome: Outcome, check: str, before: Optional[str], after: Optional[str]):
    if before == after:
        outcome.checks[check] = "pass"
        return
    outcome.checks[check] = "fail"
    a_lines = (before or "").splitlines()
    b_lines = (after or "").splitlines()
    k = 0
    while k < min(len(a_lines), len(b_lines)) and a_lines[k] == b_lines[k]:
        k += 1
    a_line = a_lines[k] if k < len(a_lines) else "<end>"
    b_line = b_lines[k] if k < len(b_lines) else "<end>"
    outcome.problems.append("%s: output line %d differs: %s | %s" % (check, k + 1, a_line.strip()[:120],
                                                                     b_line.strip()[:120]))


def _skip(outcome: Outcome, check: str, required: bool):
    outcome.checks[check] = "skipped"
    if required:
        outcome.problems.append("%s: not installed" % check)


def tally(outcomes: Sequence[Outcome]) -> Dict[str, Dict[str, int]]:
    out: Dict[str, Dict[str, int]] = {}
    for o in outcomes:
        for check, status in o.checks.items():
            out.setdefault(check, {}).setdefault(status, 0)
            out[check][status] += 1
    return out


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("before", help="tree before stripping")
    parser.add_argument("after", help="tree after stripping")
    parser.add_argument("--no-compiler", action="store_true", help="skip the swiftc parse comparison")
    parser.add_argument("--require-parsers", action="store_true", help="fail when a parser check cannot run")
    parser.add_argument("--jobs", type=int, default=0, help="parallel swiftc processes (default: CPU count)")
    args = parser.parse_args(argv)
    outcomes = verify(os.path.abspath(args.before), os.path.abspath(args.after), use_compiler=not args.no_compiler,
                      require_parsers=args.require_parsers, jobs=args.jobs)
    failures = [o for o in outcomes if o.failed]
    for o in failures:
        for problem in o.problems:
            print("FAIL %s: %s" % (o.path, problem))
    counts = tally(outcomes)
    print("files=%d failed=%d %s" % (len(outcomes), len(failures), " ".join(
        "%s:%s" % (check, ",".join("%s=%d" % kv for kv in sorted(statuses.items())))
        for check, statuses in sorted(counts.items()))))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
