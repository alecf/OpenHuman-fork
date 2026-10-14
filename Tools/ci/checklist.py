#!/usr/bin/env python3
"""The dev test checklist as one file per item.

Every manual check lives in its own file, Apps/Mail/Resources/checklist/<id>.json: one item object with the same
fields as before (id, area, title, steps, deepLink, expected, requires, addedIn). The app still bundles one file,
Apps/Mail/Resources/dev-test-checklist.json, which is GENERATED from the fragments (git-ignored, never edited by
hand): items sorted by id, keys in a fixed order, byte-for-byte deterministic. Two branches that add items add
different files, so they never conflict.

  checklist.py build              assemble the bundled file (Tools/bootstrap.sh runs this before XcodeGen)
  checklist.py build --check      exit 1 when the assembled file is missing or stale (does not write)
  checklist.py split FILE         write one fragment per item of a whole-file checklist (the one-time migration)
  checklist.py resolve            inside a conflicted `git merge`: merge the checklist 3-way by item id (also a
                                  branch that still edits the old single file), validate, stage. Exit 1 = left as is.
Options: --root DIR (repository root; default: the repository this script is in). Stdlib only.
"""
import importlib.util
import json
import os
import subprocess
import sys

sys.dont_write_bytecode = True
import tempfile

FRAGMENTS = "Apps/Mail/Resources/checklist"
ASSEMBLED = "Apps/Mail/Resources/dev-test-checklist.json"
FORMAT = "openhuman-dev-checklist"
FORMAT_VERSION = 1
KEY_ORDER = ("id", "area", "title", "steps", "deepLink", "expected", "requires", "addedIn")
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
BUILD_HINT = "run: python3 Tools/ci/checklist.py build"

_validator = None


def validator():
    """Tools/ci/check-checklist.py (the mirror of the Swift loader), loaded once."""
    global _validator
    if _validator is None:
        spec = importlib.util.spec_from_file_location("check_checklist", os.path.join(HERE, "check-checklist.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _validator = module
    return _validator


def canonical_item(item):
    """The item with the known keys first in KEY_ORDER, then any other keys sorted by name."""
    out = {key: item[key] for key in KEY_ORDER if key in item}
    for key in sorted(k for k in item if k not in KEY_ORDER):
        out[key] = item[key]
    return out


def dumps(value):
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def fragment_bytes(item):
    return dumps(canonical_item(item))


def assemble_bytes(items):
    """The bundled file for these items (any order in, sorted by id out)."""
    ordered = sorted((canonical_item(i) for i in items), key=lambda i: i["id"])
    return dumps({"format": FORMAT, "formatVersion": FORMAT_VERSION, "items": ordered})


def read_fragments(directory):
    """(items in file-name order, errors). Every non-hidden entry must be <id>.json holding one item object."""
    errors, items = [], []
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return [], ["%s: missing (no checklist fragments)" % directory]
    lowered = {}
    for name in names:
        if name.startswith("."):
            continue
        path = os.path.join(directory, name)
        if not name.endswith(".json") or not os.path.isfile(path):
            errors.append("%s: unexpected entry (only <id>.json item files belong here)" % name)
            continue
        try:
            with open(path, "rb") as handle:
                item = json.loads(handle.read().decode("utf-8"))
        except (OSError, ValueError, UnicodeDecodeError):
            errors.append("%s: not valid JSON" % name)
            continue
        if not isinstance(item, dict):
            errors.append("%s: must hold one item object" % name)
            continue
        item_id = item.get("id")
        if not isinstance(item_id, str) or name != item_id + ".json":
            errors.append("%s: file name must be the item's id plus .json (id is %r)" % (name, item_id))
            continue
        key = item_id.lower()
        if key in lowered:
            errors.append("%s: id differs only in case from %s (breaks case-insensitive disks)" % (name, lowered[key]))
            continue
        lowered[key] = name
        items.append(item)
    return items, errors


def items_by_id(items):
    return {item["id"]: item for item in items}


def assemble_tree(root):
    """(bytes or None, errors, warnings) for the fragments under root, validated like the Swift loader."""
    items, errors = read_fragments(os.path.join(root, FRAGMENTS))
    if errors:
        return None, errors, []
    data = assemble_bytes(items)
    v_errors, warnings = validator().check_data(data)
    return (None if v_errors else data), v_errors, warnings


def write_atomic(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=os.path.dirname(path))
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)


def cmd_build(root, check):
    data, errors, warnings = assemble_tree(root)
    if warnings:
        print("checklist: %d warnings (python3 Tools/ci/check-checklist.py lists them)" % len(warnings))
    if data is None:
        for line in errors:
            print("FAIL: " + line)
        print("FAIL: checklist not assembled (fix the fragments in %s)" % FRAGMENTS)
        return 1
    path = os.path.join(root, ASSEMBLED)
    try:
        with open(path, "rb") as handle:
            current = handle.read()
    except OSError:
        current = None
    if check:
        if current is None:
            print("FAIL: %s is missing; %s" % (ASSEMBLED, BUILD_HINT))
            return 1
        if current != data:
            print("FAIL: %s is stale (fragments changed); %s" % (ASSEMBLED, BUILD_HINT))
            return 1
        print("checklist assembled file up to date (%d items)" % len(json.loads(data)["items"]))
        return 0
    if current != data:
        write_atomic(path, data)
    print("checklist assembled: %d items -> %s" % (len(json.loads(data)["items"]), ASSEMBLED))
    return 0


def cmd_split(root, source):
    with open(source, "rb") as handle:
        data = json.loads(handle.read().decode("utf-8"))
    items = data["items"] if isinstance(data, dict) else data
    directory = os.path.join(root, FRAGMENTS)
    os.makedirs(directory, exist_ok=True)
    written = 0
    for item in items:
        item_id = item.get("id") if isinstance(item, dict) else None
        if not isinstance(item_id, str) or not validator().ID_RE.match(item_id):
            print("FAIL: an item has no usable id: %r" % (item_id,))
            return 1
        path = os.path.join(directory, item_id + ".json")
        body = fragment_bytes(item)
        if os.path.exists(path):
            with open(path, "rb") as handle:
                if json.loads(handle.read().decode("utf-8")) != item:
                    print("FAIL: %s exists with different content" % os.path.relpath(path, root))
                    return 1
            continue
        write_atomic(path, body)
        written += 1
    print("split: %d items, %d new fragment files" % (len(items), written))
    return 0


class ResolveError(Exception):
    pass


def git(root, *args, data=None):
    proc = subprocess.run(["git", "-C", root] + list(args), input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise ResolveError("git %s failed: %s" % (" ".join(args), proc.stderr.decode("utf-8", "replace").strip()))
    return proc.stdout


def unmerged_paths(root):
    """{path: {stage: blob sha}} for the conflicted paths of the merge in progress."""
    out = {}
    for record in git(root, "ls-files", "-u", "-z").split(b"\0"):
        if not record:
            continue
        meta, path = record.split(b"\t", 1)
        _mode, sha, stage = meta.decode().split()
        out.setdefault(path.decode("utf-8"), {})[int(stage)] = sha
    return out


def tree_has(root, rev, path):
    return subprocess.run(["git", "-C", root, "cat-file", "-e", "%s:%s" % (rev, path)],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def load_blob(root, sha):
    """(metadata dict, items list) of a whole-file checklist blob; empty when sha is None."""
    if sha is None:
        return {}, []
    try:
        data = json.loads(git(root, "cat-file", "blob", sha).decode("utf-8"))
    except ValueError:
        raise ResolveError("one side's %s is not valid JSON" % ASSEMBLED)
    if isinstance(data, list):
        return {}, data
    if not isinstance(data, dict) or not isinstance(data.get("items"), list):
        raise ResolveError("one side's %s has no items array" % ASSEMBLED)
    items = data["items"]
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise ResolveError("one side's %s has an item without an id" % ASSEMBLED)
    return {k: v for k, v in data.items() if k != "items"}, items


def merge3(base, ours, theirs):
    """3-way merge of {id: item} maps. Returns (merged map, ids changed differently on both sides)."""
    merged, conflicts = {}, []
    ids = list(ours) + [i for i in theirs if i not in ours] + [i for i in base if i not in ours and i not in theirs]
    for item_id in ids:
        b, o, t = base.get(item_id), ours.get(item_id), theirs.get(item_id)
        if o == t:
            result = o
        elif o == b:
            result = t
        elif t == b:
            result = o
        else:
            conflicts.append(item_id)
            continue
        if result is not None:
            merged[item_id] = result
    return merged, conflicts


def merged_order(ours_items, theirs_items, merged):
    """Whole-file order: ours first, then items only theirs has (in theirs' order)."""
    order = [i["id"] for i in ours_items if i["id"] in merged]
    seen = set(order)
    order += [i["id"] for i in theirs_items if i["id"] in merged and i["id"] not in seen]
    return [merged[i] for i in order]


def resolve(root):
    if subprocess.run(["git", "-C", root, "rev-parse", "-q", "--verify", "MERGE_HEAD"],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
        raise ResolveError("no merge in progress")
    unmerged = unmerged_paths(root)
    fragment_conflicts = sorted(p for p in unmerged if p.startswith(FRAGMENTS + "/"))
    if fragment_conflicts:
        names = ", ".join(os.path.basename(p)[:-5] if p.endswith(".json") else p for p in fragment_conflicts)
        raise ResolveError("both sides changed the same checklist item(s): %s; edit %s/<id>.json by hand"
                           % (names, FRAGMENTS))
    ours_new, theirs_new = tree_has(root, "HEAD", FRAGMENTS), tree_has(root, "MERGE_HEAD", FRAGMENTS)
    if ASSEMBLED not in unmerged:
        if ours_new or theirs_new:
            write_assembled(root)
        return "no checklist conflict"
    stages = unmerged[ASSEMBLED]
    base_meta, base_items = load_blob(root, stages.get(1))
    base = items_by_id(base_items)

    if not ours_new and not theirs_new:
        if 2 not in stages or 3 not in stages:
            raise ResolveError("%s was deleted on one side; resolve by hand" % ASSEMBLED)
        ours_meta, ours_items = load_blob(root, stages[2])
        theirs_meta, theirs_items = load_blob(root, stages[3])
        merged, conflicts = merge3(base, items_by_id(ours_items), items_by_id(theirs_items))
        if conflicts:
            raise ResolveError("checklist item(s) changed differently on both sides: %s" % ", ".join(conflicts))
        meta = theirs_meta if ours_meta == base_meta else ours_meta
        root_obj = dict(meta)
        root_obj["items"] = merged_order(ours_items, theirs_items, merged)
        data = dumps(root_obj) if meta else dumps(root_obj["items"])
        errors, _ = validator().check_data(data)
        if errors:
            raise ResolveError("merged checklist is invalid: " + "; ".join(errors[:5]))
        write_atomic(os.path.join(root, ASSEMBLED), data)
        git(root, "add", "--", ASSEMBLED)
        return "merged the single file by id (%d items)" % len(root_obj["items"])

    if ours_new and theirs_new:
        raise ResolveError("%s is tracked again on a branch that has fragments; resolve by hand" % ASSEMBLED)

    directory = os.path.join(root, FRAGMENTS)
    current_items, errors = read_fragments(directory)
    if errors:
        raise ResolveError("fragments unreadable: " + "; ".join(errors[:5]))
    legacy_stage = 3 if ours_new else 2
    if legacy_stage not in stages:
        raise ResolveError("%s: unexpected conflict shape (stages %s)" % (ASSEMBLED, sorted(stages)))
    _meta, legacy_items = load_blob(root, stages[legacy_stage])
    current = items_by_id(current_items)
    legacy = items_by_id(legacy_items)
    if ours_new:
        merged, conflicts = merge3(base, current, legacy)
    else:
        merged, conflicts = merge3(base, legacy, current)
    if conflicts:
        raise ResolveError("checklist item(s) changed differently on both sides: %s" % ", ".join(conflicts))
    for item_id in merged:
        if not validator().ID_RE.match(item_id):
            raise ResolveError("item id %r cannot be a fragment file name" % item_id)
    data = assemble_bytes(merged.values())
    v_errors, _ = validator().check_data(data)
    if v_errors:
        raise ResolveError("merged checklist is invalid: " + "; ".join(v_errors[:5]))
    added = changed = removed = 0
    for item_id, item in merged.items():
        if item_id not in current:
            added += 1
        elif current[item_id] != item:
            changed += 1
        else:
            continue
        write_atomic(os.path.join(directory, item_id + ".json"), fragment_bytes(item))
    for item_id in current:
        if item_id not in merged:
            os.remove(os.path.join(directory, item_id + ".json"))
            removed += 1
    git(root, "rm", "-q", "-f", "--cached", "--ignore-unmatch", "--", ASSEMBLED)
    git(root, "add", "-A", "--", FRAGMENTS)
    write_assembled(root)
    return ("carried the single-file edits into fragments: %d added, %d changed, %d removed (%d items)"
            % (added, changed, removed, len(merged)))


def write_assembled(root):
    """Regenerates the (ignored) bundled file so the merged tree builds; raises when the fragments are invalid."""
    data, errors, _ = assemble_tree(root)
    if data is None:
        raise ResolveError("merged checklist is invalid: " + "; ".join(errors[:5]))
    write_atomic(os.path.join(root, ASSEMBLED), data)


def cmd_resolve(root):
    try:
        summary = resolve(root)
    except ResolveError as problem:
        print("FAIL: checklist not resolved: %s" % problem)
        return 1
    print("checklist resolved: " + summary)
    return 0


def main(argv):
    args = argv[1:]
    root = DEFAULT_ROOT
    if "--root" in args:
        at = args.index("--root")
        if at + 1 >= len(args):
            print(__doc__)
            return 2
        root = os.path.abspath(args[at + 1])
        del args[at:at + 2]
    if args == ["build"]:
        return cmd_build(root, check=False)
    if args == ["build", "--check"]:
        return cmd_build(root, check=True)
    if len(args) == 2 and args[0] == "split":
        return cmd_split(root, args[1])
    if args == ["resolve"]:
        return cmd_resolve(root)
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
