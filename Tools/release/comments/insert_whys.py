#!/usr/bin/env python3
"""Insert short comments above anchor lines.

Input is a JSON list of {"file", "anchor", "text"}; anchor is a line or a list of consecutive non-blank lines.
A comment is inserted above the first anchor line only when the anchor sequence occurs exactly once in the file
(blank lines ignored). Missing or ambiguous anchors are skipped and reported.
"""
import argparse
import json
import os
import sys

PREFIX = {".swift": "//", ".py": "#", ".sh": "#", ".yml": "#", ".yaml": "#"}


def insert(source, anchor, text, prefix):
    lines = source.split("\n")
    seq = [a.rstrip() for a in (anchor if isinstance(anchor, list) else [anchor])]
    indexes = [i for i, line in enumerate(lines) if line.strip()]
    hits = [k for k in range(len(indexes) - len(seq) + 1)
            if [lines[indexes[k + j]].rstrip() for j in range(len(seq))] == seq]
    if len(hits) != 1:
        return None, "missing" if not hits else "ambiguous"
    at = indexes[hits[0]]
    first = lines[at]
    indent = first[:len(first) - len(first.lstrip())]
    lines.insert(at, "%s%s %s" % (indent, prefix, text.strip()))
    return "\n".join(lines), None


def apply(root, entries):
    done, skipped = 0, []
    for entry in entries:
        path = os.path.join(root, entry["file"])
        prefix = PREFIX.get(os.path.splitext(path)[1])
        text = entry["text"].strip()
        if prefix is None or "\n" in text or not text:
            skipped.append((entry["file"], "unsupported"))
            continue
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        updated, reason = insert(source, entry["anchor"], text, prefix)
        if updated is None:
            skipped.append((entry["file"], reason))
            continue
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(updated)
        done += 1
    return done, skipped


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("json_file")
    parser.add_argument("--root", default=".")
    args = parser.parse_args(argv)
    with open(args.json_file, encoding="utf-8") as handle:
        entries = json.load(handle)
    done, skipped = apply(args.root, entries)
    print("inserted=%d skipped=%d" % (done, len(skipped)))
    for path, reason in skipped:
        print("skip %s: %s" % (path, reason), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
