#!/usr/bin/env python3
"""Generate public memberwise initializers inside contract structs.

Swift synthesizes memberwise initializers only with internal access, but other packages (Sync, the CLI, the app's
adapter, fakes) must construct contract value types. A public init in an extension with the memberwise signature
is rejected ("invalid redeclaration of synthesized initializer"), so this tool writes the init INSIDE each
`public struct` of every `Packages/*/Sources/*/Contracts/*.swift` file, between marker comments:

    // generated-init: Tools/ci/gen-public-inits.py
    public init(...) { ... }
    // end generated-init

Optionals default to nil; declared defaults are kept. Structs that declare an `init(` themselves, or carry
`// no-generated-init` on their declaration line, are skipped. One-line structs are expanded to several lines.

Usage: Tools/ci/gen-public-inits.py            rewrite the contract files in place
       Tools/ci/gen-public-inits.py --check    exit 1 if any file would change (CI)
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BEGIN = "// generated-init: Tools/ci/gen-public-inits.py"
END = "// end generated-init"
STRUCT_RE = re.compile(r"^(\s*)public\s+struct\s+(\w+)(<[^>{]*>)?[^{]*\{")
PROP_RE = re.compile(r"^public\s+(var|let)\s+(\w+)\s*:\s*(.+)$")


def strip_comment(line):
    i = line.find("//")
    return line if i < 0 else line[:i]


def split_top(text, sep):
    parts, depth, cur, i = [], 0, "", 0
    while i < len(text):
        c = text[i]
        if c in "([<{":
            depth += 1
        elif c in ")]>}":
            depth -= 1
        if depth == 0 and text.startswith(sep, i):
            parts.append(cur)
            cur = ""
            i += len(sep)
            continue
        cur += c
        i += 1
    parts.append(cur)
    return parts


def properties(body_lines):
    props = []
    for raw in body_lines:
        code = strip_comment(raw).strip()
        for decl in split_top(code, ";"):
            m = PROP_RE.match(decl.strip())
            if not m:
                continue
            kind, name, rest = m.groups()
            if "{" in rest:
                continue
            td = split_top(rest, " = ")
            ptype, default = td[0].strip(), (td[1].strip() if len(td) > 1 else None)
            if kind == "let" and default is not None:
                continue
            props.append((name, ptype, default))
    return props


def render_init(indent, props):
    pad = indent + "    "
    params = []
    for name, ptype, default in props:
        d = default if default is not None else ("nil" if ptype.endswith("?") else None)
        params.append(f"{pad}    {name}: {ptype}" + (f" = {d}" if d is not None else ""))
    out = [f"{pad}{BEGIN}", f"{pad}public init("]
    out.append(",\n".join(params))
    out.append(f"{pad}) {{")
    out += [f"{pad}    self.{name} = {name}" for name, _, _ in props]
    out += [f"{pad}}}", f"{pad}{END}"]
    return out


def process(source):
    lines = source.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        m = STRUCT_RE.match(line)
        if not m:
            out.append(line)
            i += 1
            continue
        indent = m.group(1)
        skip = "no-generated-init" in line
        depth = line.count("{") - line.count("}")
        if depth == 0:
            head, body = line[: line.index("{") + 1], line[line.index("{") + 1: line.rindex("}")]
            body_lines = [indent + "    " + body.strip()] if body.strip() else []
            closing = indent + "}"
            i += 1
        else:
            head, body_lines = line, []
            i += 1
            while i < len(lines):
                depth += lines[i].count("{") - lines[i].count("}")
                if depth <= 0:
                    closing = lines[i]
                    i += 1
                    break
                body_lines.append(lines[i])
                i += 1
        cleaned, inside = [], False
        for b in body_lines:
            if b.strip() == BEGIN:
                inside = True
                continue
            if b.strip() == END:
                inside = False
                continue
            if not inside:
                cleaned.append(b)
        top, d = [], 0
        for b in cleaned:
            if d == 0:
                top.append(b)
            d += b.count("{") - b.count("}")
        if any(re.search(r"\binit\??\(", strip_comment(b)) for b in top):
            skip = True
        props = properties(top)
        if skip or not props:
            if depth == 0 and line.count("{") == line.count("}"):
                out.append(line)
                continue
            out += [head] + cleaned + [closing]
            continue
        while cleaned and not cleaned[-1].strip():
            cleaned.pop()
        out += [head] + cleaned + [""] + render_init(indent, props) + [closing]
    return "\n".join(out)


def main():
    check = "--check" in sys.argv
    stale = []
    for path in sorted(glob.glob(os.path.join(ROOT, "Packages/*/Sources/*/Contracts/*.swift"))):
        text = open(path, encoding="utf-8").read()
        new = process(text)
        if new != text:
            if check:
                stale.append(os.path.relpath(path, ROOT))
            else:
                open(path, "w", encoding="utf-8").write(new)
                print("updated", os.path.relpath(path, ROOT))
    if stale:
        print("contract inits out of date (run Tools/ci/gen-public-inits.py):", *stale, sep="\n  ")
        sys.exit(1)


if __name__ == "__main__":
    main()
