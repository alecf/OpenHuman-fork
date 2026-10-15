#!/usr/bin/env python3
"""Validate the dev test checklist like DevChecklistLoader (DevChecklist.swift).

Without a path: the fragments Apps/Mail/Resources/checklist/<id>.json (file name = id, one item each), the file
Tools/ci/checklist.py assembles from them, and the generated Apps/Mail/Resources/dev-test-checklist.json when present
(stale = FAIL; `python3 Tools/ci/checklist.py build` regenerates it). With a path: that one whole-file checklist (an
override file in the app's support folder, or a checkout from before the split).
Fails (exit 1) on whatever makes the Swift loader report an issue or reject the file; warns on
truncations (the Swift cleaner shortens over-long strings) and on the house rule of max 4 steps.
Stdlib only. Usage: check-checklist.py [--root DIR] [path]
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True
import unicodedata

FORMAT = "openhuman-dev-checklist"
MAX_FILE_BYTES = 512 * 1024
MAX_ITEMS = 700
MAX_DEPTH = 8
MAX_STEPS = 12
MAX_ID, MAX_AREA, MAX_TITLE, MAX_STEP, MAX_EXPECTED, MAX_ADDED_IN = 64, 60, 200, 300, 400, 32
MAX_LINK_BYTES = 2048
HOUSE_MAX_STEPS = 4
REQUIRES = ("fake", "real")
DEFAULT_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                            "Apps", "Mail", "Resources", "dev-test-checklist.json")
ID_RE = re.compile(r"\A[A-Za-z0-9._-]{1,64}\Z")
BAD_CATEGORIES = {"Cc", "Cf", "Co", "Cs", "Cn", "Zl", "Zp"}


def clean(value):
    """Mirror of DevChecklistLoader.clean without the length cap; returns the cleaned text."""
    out = []
    last_space = False
    for ch in value:
        cat = unicodedata.category(ch)
        if cat in BAD_CATEGORIES:
            if ch in "\n\t\r":
                if not last_space:
                    out.append(" ")
                last_space = True
            continue
        if cat == "Zs":
            if not last_space:
                out.append(" ")
            last_space = True
        else:
            out.append(ch)
            last_space = False
    return "".join(out).strip(" ")


def nesting_depth(data):
    depth = deepest = 0
    in_string = escaped = False
    for byte in data:
        if in_string:
            if escaped:
                escaped = False
            elif byte == 0x5C:
                escaped = True
            elif byte == 0x22:
                in_string = False
            continue
        if byte == 0x22:
            in_string = True
        elif byte in (0x5B, 0x7B):
            depth += 1
            deepest = max(deepest, depth)
            if deepest > MAX_DEPTH:
                return deepest
        elif byte in (0x5D, 0x7D):
            depth -= 1
    return deepest


def text(value, limit, label, warnings):
    """Cleaned string or None (not a string or empty); warns when it would be truncated."""
    if not isinstance(value, str):
        return None
    cleaned = clean(value)
    if not cleaned:
        return None
    if len(cleaned) > limit:
        warnings.append("%s: truncated (%d > %d chars)" % (label, len(cleaned), limit))
    return cleaned


def check_item(raw, index, seen, errors, warnings):
    pos = "item %d" % (index + 1)
    if not isinstance(raw, dict):
        errors.append("%s: not an object" % pos)
        return
    item_id = raw.get("id")
    if not isinstance(item_id, str) or not ID_RE.match(item_id):
        errors.append("%s: id must be 1-%d letters, digits, '.', '_' or '-'" % (pos, MAX_ID))
        return
    ok = True

    def fail(msg):
        errors.append("%s: %s" % (item_id, msg))

    if text(raw.get("area"), MAX_AREA, item_id + " area", warnings) is None:
        fail("missing area")
        ok = False
    if text(raw.get("title"), MAX_TITLE, item_id + " title", warnings) is None:
        fail("missing title")
        ok = False
    steps = raw.get("steps")
    if not isinstance(steps, list) or not steps or len(steps) > MAX_STEPS:
        fail("steps must be 1-%d strings" % MAX_STEPS)
        ok = False
    else:
        if len(steps) > HOUSE_MAX_STEPS:
            warnings.append("%s: house rule: %d steps (max %d)" % (item_id, len(steps), HOUSE_MAX_STEPS))
        for n, step in enumerate(steps, 1):
            if text(step, MAX_STEP, "%s step %d" % (item_id, n), warnings) is None:
                fail("a step is not text (step %d)" % n)
                ok = False
                break
    if text(raw.get("expected"), MAX_EXPECTED, item_id + " expected", warnings) is None:
        fail("missing expected")
        ok = False
    if not isinstance(raw.get("requires"), str) or raw.get("requires") not in REQUIRES:
        fail('requires must be "fake" or "real"')
        ok = False
    added_in = raw.get("addedIn")
    if added_in is not None and text(added_in, MAX_ADDED_IN, item_id + " addedIn", warnings) is None:
        warnings.append("%s: addedIn is not usable text (becomes empty)" % item_id)
    if "deepLink" in raw and raw["deepLink"] is not None:
        link = raw["deepLink"]
        if not (isinstance(link, str) and len(link.encode("utf-8")) <= MAX_LINK_BYTES
                and link.startswith("openhuman://")):
            fail("deep link dropped (not a valid openhuman:// link)")
            ok = False
    if not ok:
        return
    if item_id in seen:
        errors.append("%s: duplicate id (item %d)" % (item_id, index + 1))
        return
    seen.add(item_id)


def check_data(data):
    """Returns (errors, warnings) for the raw file bytes."""
    errors, warnings = [], []
    if len(data) > MAX_FILE_BYTES:
        return ["file is larger than %d KB" % (MAX_FILE_BYTES // 1024)], warnings
    if nesting_depth(data) > MAX_DEPTH:
        return ["JSON nested deeper than %d levels" % MAX_DEPTH], warnings
    try:
        root = json.loads(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        return ["not valid JSON"], warnings
    if isinstance(root, dict):
        if "format" in root and root["format"] != FORMAT:
            return ['format is not "%s"' % FORMAT], warnings
        items = root.get("items")
        if not isinstance(items, list):
            return ['no "items" array'], warnings
    elif isinstance(root, list):
        items = root
    else:
        return ["top level must be an object or an array"], warnings
    seen = set()
    for index, raw in enumerate(items):
        if index >= MAX_ITEMS:
            errors.append("only the first %d items are used (file has %d)" % (MAX_ITEMS, len(items)))
            break
        check_item(raw, index, seen, errors, warnings)
    return errors, warnings


def load_fragments_tool():
    """Tools/ci/checklist.py (fragments, assembly), loaded by path."""
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("checklist_tool", os.path.join(here, "checklist.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def check_tree(root):
    """(errors, warnings, notes) for a checkout: the fragments in Apps/Mail/Resources/checklist/ (one <id>.json per
    item), the file assembled from them, and the generated bundled file when present (it must not be stale)."""
    tool = load_fragments_tool()
    fragments = os.path.join(root, tool.FRAGMENTS)
    assembled_path = os.path.join(root, tool.ASSEMBLED)
    notes = []
    if not os.path.isdir(fragments):
        try:
            with open(assembled_path, "rb") as handle:
                data = handle.read()
        except OSError:
            return ["%s could not be read" % assembled_path], [], notes
        errors, warnings = check_data(data)
        return errors, warnings, notes
    items, errors = tool.read_fragments(fragments)
    if errors:
        return errors, [], notes
    data = tool.assemble_bytes(items)
    errors, warnings = check_data(data)
    try:
        with open(assembled_path, "rb") as handle:
            current = handle.read()
    except OSError:
        current = None
    if current is None:
        notes.append("%s not assembled yet (Tools/bootstrap.sh or %s)" % (tool.ASSEMBLED, tool.BUILD_HINT))
    elif current != data:
        errors.append("%s is stale (fragments changed); %s" % (tool.ASSEMBLED, tool.BUILD_HINT))
    return errors, warnings, notes


def main(argv):
    args = argv[1:]
    root = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    if len(args) >= 2 and args[0] == "--root":
        root = os.path.abspath(args[1])
        args = args[2:]
    notes = []
    if args:
        path = args[0]
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError:
            print("FAIL: %s could not be read" % path)
            return 1
        errors, warnings = check_data(data)
    else:
        errors, warnings, notes = check_tree(root)
    for line in warnings:
        print("WARN: " + line)
    for line in notes:
        print("NOTE: " + line)
    for line in errors:
        print("FAIL: " + line)
    if errors:
        return 1
    print("checklist ok (%d warnings)" % len(warnings))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
