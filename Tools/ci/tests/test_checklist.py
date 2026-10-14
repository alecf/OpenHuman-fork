"""Tests for Tools/ci/checklist.py: fragments, deterministic assembly, the stale check, the split migration and the
merge resolver (scratch git repositories; stdlib only). Run: python3 -m unittest discover -s Tools/ci/tests"""
import importlib.util
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "..", filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cl = load("checklist_tool", "checklist.py")
cc = load("check_checklist", "check-checklist.py")
cl.print = lambda *args, **kwargs: None
MONO, FRAG = cl.ASSEMBLED, cl.FRAGMENTS


def item(item_id, **over):
    base = {"id": item_id, "area": "Inbox", "title": "Title " + item_id, "steps": ["Press j"], "deepLink": None,
            "expected": "It moves", "requires": "fake", "addedIn": "2026-10-13"}
    base.update(over)
    return base


def whole_file(items):
    return cl.dumps({"format": cl.FORMAT, "formatVersion": 1, "items": items})


def write(root, rel, data):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data if isinstance(data, bytes) else data.encode("utf-8"))


def read(root, rel):
    with open(os.path.join(root, rel), "rb") as handle:
        return handle.read()


def write_fragments(root, items):
    for it in items:
        write(root, os.path.join(FRAG, it["id"] + ".json"), cl.fragment_bytes(it))


class TempRoot(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="checklist-test-")
        self.addCleanup(shutil.rmtree, self.root, True)


class SerialisationTests(unittest.TestCase):
    def test_assembly_is_sorted_and_independent_of_input_order(self):
        items = [item("b.two"), item("a.one"), item("c-3"), item("A.upper")]
        expected = cl.assemble_bytes(items)
        for _ in range(5):
            random.shuffle(items)
            self.assertEqual(cl.assemble_bytes(items), expected)
        ids = [i["id"] for i in json.loads(expected)["items"]]
        self.assertEqual(ids, sorted(ids))
        self.assertTrue(expected.endswith(b"}\n"))

    def test_canonical_key_order(self):
        scrambled = dict(reversed(list(item("x", zeta=1, alpha=2).items())))
        keys = list(json.loads(cl.fragment_bytes(scrambled)).keys())
        self.assertEqual(keys, list(cl.KEY_ORDER) + ["alpha", "zeta"])

    def test_assembled_root_shape(self):
        root = json.loads(cl.assemble_bytes([item("a")]))
        self.assertEqual(list(root), ["format", "formatVersion", "items"])
        self.assertEqual(root["format"], cl.FORMAT)
        self.assertEqual(cc.check_data(cl.assemble_bytes([item("a")])), ([], []))


class FragmentDirTests(TempRoot):
    def frag_dir(self):
        return os.path.join(self.root, FRAG)

    def test_reads_valid_fragments_and_ignores_hidden_files(self):
        write_fragments(self.root, [item("b"), item("a")])
        write(self.root, os.path.join(FRAG, ".DS_Store"), b"x")
        items, errors = cl.read_fragments(self.frag_dir())
        self.assertEqual(errors, [])
        self.assertEqual([i["id"] for i in items], ["a", "b"])

    def test_file_name_must_be_the_id(self):
        write(self.root, os.path.join(FRAG, "wrong.json"), cl.fragment_bytes(item("right")))
        _, errors = cl.read_fragments(self.frag_dir())
        self.assertIn("file name must be", errors[0])

    def test_invalid_json_non_object_and_stray_files_fail(self):
        write(self.root, os.path.join(FRAG, "a.json"), b"{")
        write(self.root, os.path.join(FRAG, "b.json"), b"[1]")
        write(self.root, os.path.join(FRAG, "notes.txt"), b"x")
        _, errors = cl.read_fragments(self.frag_dir())
        self.assertEqual(len(errors), 3)
        self.assertTrue(any("not valid JSON" in e for e in errors))
        self.assertTrue(any("one item object" in e for e in errors))
        self.assertTrue(any("unexpected entry" in e for e in errors))

    def test_missing_directory_fails(self):
        _, errors = cl.read_fragments(self.frag_dir())
        self.assertIn("missing", errors[0])

    def test_ids_differing_only_in_case_fail(self):
        write_fragments(self.root, [item("Aa")])
        probe = os.path.join(self.frag_dir(), "aa.json")
        if os.path.exists(probe):
            self.skipTest("case-insensitive file system: such files cannot coexist here")
        write_fragments(self.root, [item("aa")])
        _, errors = cl.read_fragments(self.frag_dir())
        self.assertIn("only in case", errors[0])


class BuildAndCheckTests(TempRoot):
    def test_build_then_check_then_stale_then_missing(self):
        write_fragments(self.root, [item("a"), item("b")])
        self.assertEqual(cl.cmd_build(self.root, check=True), 1, "missing before the first build")
        self.assertEqual(cl.cmd_build(self.root, check=False), 0)
        first = read(self.root, MONO)
        self.assertEqual(first, cl.assemble_bytes([item("a"), item("b")]))
        self.assertEqual(cl.cmd_build(self.root, check=True), 0)
        self.assertEqual(cl.cmd_build(self.root, check=False), 0)
        self.assertEqual(read(self.root, MONO), first, "byte-for-byte the same on a rebuild")
        write_fragments(self.root, [item("c")])
        self.assertEqual(cl.cmd_build(self.root, check=True), 1, "stale after a fragment was added")
        errors, _, _ = cc.check_tree(self.root)
        self.assertTrue(any("stale" in e for e in errors))
        os.remove(os.path.join(self.root, MONO))
        errors, _, notes = cc.check_tree(self.root)
        self.assertEqual(errors, [])
        self.assertIn("not assembled", notes[0])

    def test_invalid_fragment_fails_the_build_and_writes_nothing(self):
        write_fragments(self.root, [item("a", requires="real")])
        self.assertEqual(cl.cmd_build(self.root, check=False), 1)
        self.assertFalse(os.path.exists(os.path.join(self.root, MONO)))
        errors, _, _ = cc.check_tree(self.root)
        self.assertIn("requires", errors[0])

    def test_check_tree_reads_a_single_file_checkout(self):
        write(self.root, MONO, whole_file([item("a")]))
        self.assertEqual(cc.check_tree(self.root)[0], [])
        write(self.root, MONO, b"{")
        self.assertEqual(cc.check_tree(self.root)[0], ["not valid JSON"])

    def test_split_round_trip_is_lossless(self):
        items = [item("z.last", steps=["a", "b"]), item("a.first", deepLink="openhuman://inbox"), item("m.mid")]
        write(self.root, "whole.json", whole_file(items))
        self.assertEqual(cl.cmd_split(self.root, os.path.join(self.root, "whole.json")), 0)
        self.assertEqual(cl.cmd_split(self.root, os.path.join(self.root, "whole.json")), 0, "re-running is a no-op")
        self.assertEqual(cl.cmd_build(self.root, check=False), 0)
        assembled = json.loads(read(self.root, MONO))
        self.assertEqual({i["id"]: i for i in assembled["items"]}, {i["id"]: i for i in items})
        write(self.root, os.path.join(FRAG, "m.mid.json"), cl.fragment_bytes(item("m.mid", title="changed")))
        self.assertEqual(cl.cmd_split(self.root, os.path.join(self.root, "whole.json")), 1, "never overwrites")


class Merge3Tests(unittest.TestCase):
    def test_cases(self):
        a, a2, a3, b, c, d = item("a"), item("a", title="A2"), item("a", title="A3"), item("b"), item("c"), item("d")
        base = {"a": a, "b": b}
        merged, conflicts = cl.merge3(base, {"a": a2, "b": b, "c": c}, {"a": a, "d": d})
        self.assertEqual(conflicts, [])
        self.assertEqual(merged, {"a": a2, "c": c, "d": d}, "ours edit kept, theirs deletion of b kept, both adds")
        _, conflicts = cl.merge3(base, {"a": a2, "b": b}, {"a": a3, "b": b})
        self.assertEqual(conflicts, ["a"])
        _, conflicts = cl.merge3(base, {"b": b}, {"a": a2, "b": b})
        self.assertEqual(conflicts, ["a"], "deleted on one side, edited on the other")
        merged, conflicts = cl.merge3({}, {"c": c}, {"c": c})
        self.assertEqual((merged, conflicts), ({"c": c}, []), "the same add on both sides")
        _, conflicts = cl.merge3({}, {"c": c}, {"c": item("c", title="other")})
        self.assertEqual(conflicts, ["c"])


GIT = ["git", "-c", "user.name=test", "-c", "user.email=test@invalid", "-c", "commit.gpgsign=false",
       "-c", "core.hooksPath=/dev/null"]


class ResolveTests(TempRoot):
    """Scratch repositories in the shapes a merge can meet: both sides on the single file, one side split, both split."""

    def git(self, *args, check=True):
        proc = subprocess.run(GIT + ["-C", self.root] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if check and proc.returncode != 0:
            raise AssertionError("git %s: %s" % (args, proc.stderr.decode()))
        return proc

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def setUp(self):
        super().setUp()
        self.git("init", "-q", "-b", "main")
        write(self.root, MONO, whole_file([item("a"), item("b")]))
        write(self.root, "README", "x\n")
        self.commit("base")

    def split_here(self):
        """What the split commit does: fragments, the single file untracked and ignored."""
        self.assertEqual(cl.cmd_split(self.root, os.path.join(self.root, MONO)), 0)
        write(self.root, ".gitignore", "/" + MONO + "\n")
        self.git("rm", "-q", "--cached", MONO)
        os.remove(os.path.join(self.root, MONO))

    def merge(self, branch):
        return self.git("merge", "--no-ff", "--no-edit", branch, check=False).returncode == 0

    def resolve(self):
        return cl.cmd_resolve(self.root)

    def unmerged(self):
        return self.git("ls-files", "-u").stdout.decode().strip()

    def fragment_ids(self):
        return sorted(n[:-5] for n in os.listdir(os.path.join(self.root, FRAG)) if n.endswith(".json"))

    def test_single_file_both_sides_append(self):
        self.git("checkout", "-q", "-b", "theirs")
        write(self.root, MONO, whole_file([item("a"), item("b"), item("d")]))
        self.commit("theirs adds d")
        self.git("checkout", "-q", "main")
        write(self.root, MONO, whole_file([item("a"), item("b"), item("c")]))
        self.commit("ours adds c")
        self.assertFalse(self.merge("theirs"))
        self.assertEqual(self.resolve(), 0)
        self.assertEqual(self.unmerged(), "")
        merged = json.loads(read(self.root, MONO))
        self.assertEqual([i["id"] for i in merged["items"]], ["a", "b", "c", "d"], "ours order, then theirs' new")
        self.assertEqual(cc.check_data(read(self.root, MONO))[0], [])

    def test_single_file_same_item_changed_twice_fails_loudly_and_changes_nothing(self):
        self.git("checkout", "-q", "-b", "theirs")
        write(self.root, MONO, whole_file([item("a", title="theirs"), item("b"), item("d")]))
        self.commit("theirs")
        self.git("checkout", "-q", "main")
        write(self.root, MONO, whole_file([item("a", title="ours"), item("b"), item("c")]))
        self.commit("ours")
        self.assertFalse(self.merge("theirs"))
        before = read(self.root, MONO)
        self.assertEqual(self.resolve(), 1)
        self.assertNotEqual(self.unmerged(), "", "still conflicted for a person")
        self.assertEqual(read(self.root, MONO), before)

    def test_split_ours_and_single_file_theirs(self):
        self.git("checkout", "-q", "-b", "theirs")
        write(self.root, MONO, whole_file([item("a"), item("b", title="edited"), item("d")]))
        self.commit("theirs edits b, adds d (old layout)")
        self.git("checkout", "-q", "main")
        self.split_here()
        write_fragments(self.root, [item("e")])
        self.commit("split, then e")
        self.assertFalse(self.merge("theirs"), "modify/delete on the single file")
        self.assertEqual(self.resolve(), 0)
        self.assertEqual(self.unmerged(), "")
        self.assertEqual(self.fragment_ids(), ["a", "b", "d", "e"])
        frag_b = json.loads(read(self.root, os.path.join(FRAG, "b.json")))
        self.assertEqual(frag_b["title"], "edited")
        self.assertNotIn(MONO, self.git("ls-files").stdout.decode(), "the single file stays untracked")
        self.assertEqual(read(self.root, MONO), cl.assemble_bytes([item("a"), item("b", title="edited"), item("d"),
                                                                    item("e")]))
        self.git("commit", "-q", "--no-edit")
        self.assertEqual(self.git("status", "--porcelain").stdout.decode(), "")

    def test_single_file_ours_and_split_theirs(self):
        self.git("checkout", "-q", "-b", "theirs")
        self.split_here()
        write_fragments(self.root, [item("e")])
        self.commit("split, then e")
        self.git("checkout", "-q", "main")
        write(self.root, MONO, whole_file([item("b"), item("d")]))
        self.commit("ours removes a, adds d (old layout)")
        self.assertFalse(self.merge("theirs"))
        self.assertEqual(self.resolve(), 0)
        self.assertEqual(self.unmerged(), "")
        self.assertEqual(self.fragment_ids(), ["b", "d", "e"])
        self.assertNotIn(MONO, self.git("ls-files").stdout.decode())

    def test_single_file_edit_against_a_split_side_edit_of_the_same_item_fails(self):
        self.git("checkout", "-q", "-b", "theirs")
        write(self.root, MONO, whole_file([item("a", title="theirs"), item("b")]))
        self.commit("theirs")
        self.git("checkout", "-q", "main")
        self.split_here()
        write_fragments(self.root, [item("a", title="ours")])
        self.commit("split, edit a")
        self.assertFalse(self.merge("theirs"))
        self.assertEqual(self.resolve(), 1)
        self.assertEqual(json.loads(read(self.root, os.path.join(FRAG, "a.json")))["title"], "ours", "untouched")

    def test_split_both_sides_adds_merge_cleanly_and_same_item_edits_fail(self):
        self.split_here()
        self.commit("split")
        self.git("checkout", "-q", "-b", "theirs")
        write_fragments(self.root, [item("d"), item("a", title="theirs")])
        self.commit("theirs")
        self.git("checkout", "-q", "main")
        write_fragments(self.root, [item("c")])
        self.commit("ours adds c")
        self.assertTrue(self.merge("theirs"), "different item files never conflict")
        self.assertEqual(self.fragment_ids(), ["a", "b", "c", "d"])
        write_fragments(self.root, [item("a", title="ours again")])
        self.commit("ours edits a")
        self.git("checkout", "-q", "theirs")
        write_fragments(self.root, [item("a", title="theirs again")])
        self.commit("theirs edits a")
        self.git("checkout", "-q", "main")
        self.assertFalse(self.merge("theirs"))
        self.assertEqual(self.resolve(), 1)

    def test_no_merge_in_progress(self):
        self.assertEqual(self.resolve(), 1)


class MigrationTests(unittest.TestCase):
    """The split commit in this repository: its fragments assemble to exactly the items of the single file before it."""

    def git(self, *args, data=None):
        return subprocess.run(["git", "-C", REPO] + list(args), input=data, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL)

    def test_split_commit_is_lossless(self):
        log = self.git("log", "--format=%H", "--diff-filter=A", "--", FRAG + "/inbox.jk.json")
        commits = log.stdout.decode().split()
        if log.returncode != 0 or not commits:
            self.skipTest("the split is not committed in this checkout")
        split = commits[-1]
        before = self.git("show", "%s^1:%s" % (split, MONO))
        if before.returncode != 0:
            self.skipTest("no single file before the split commit")
        old = json.loads(before.stdout.decode("utf-8"))
        names = self.git("ls-tree", "--name-only", "%s:%s" % (split, FRAG)).stdout.decode().split()
        batch = "".join("%s:%s/%s\n" % (split, FRAG, n) for n in names).encode()
        out = self.git("cat-file", "--batch", data=batch).stdout
        items, pos = [], 0
        while pos < len(out):
            header_end = out.index(b"\n", pos)
            size = int(out[pos:header_end].split()[2])
            items.append(json.loads(out[header_end + 1:header_end + 1 + size].decode("utf-8")))
            pos = header_end + 1 + size + 1
        self.assertEqual(len(items), len(old["items"]))
        self.assertEqual({i["id"]: i for i in items}, {i["id"]: i for i in old["items"]})
        self.assertEqual(sorted(n[:-5] for n in names), sorted(i["id"] for i in items), "file name = id")
        assembled = json.loads(cl.assemble_bytes(items))
        self.assertEqual({k: v for k, v in assembled.items() if k != "items"},
                         {k: v for k, v in old.items() if k != "items"})
        self.assertEqual(cl.assemble_bytes(items), cl.assemble_bytes(old["items"]))


if __name__ == "__main__":
    unittest.main()
