import importlib.util
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("check_checklist", os.path.join(HERE, "..", "check-checklist.py"))
cc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cc)


def item(**over):
    base = {"id": "a.b-1", "area": "Inbox", "title": "T", "steps": ["Press J"], "deepLink": None,
            "expected": "It moves", "requires": "fake", "addedIn": "x"}
    base.update(over)
    return {k: v for k, v in base.items() if v is not ...}


def run(items, wrap=True):
    root = {"format": cc.FORMAT, "items": items} if wrap else items
    return cc.check_data(json.dumps(root).encode())


class CheckChecklistTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(run([item()]), ([], []))

    def test_bare_array(self):
        self.assertEqual(run([item()], wrap=False)[0], [])

    def test_requires_is_fake_or_real_only(self):
        self.assertEqual(run([item(requires="real")])[0], [])
        for value in ("real-readonly", "real-write", "live"):
            errors, _ = run([item(requires=value)])
            self.assertEqual(len(errors), 1)
            self.assertIn("a.b-1", errors[0])

    def test_bad_id(self):
        self.assertTrue(run([item(id="bad id")])[0])
        self.assertTrue(run([item(id="x" * 65)])[0])

    def test_duplicate_id(self):
        errors, _ = run([item(), item()])
        self.assertIn("duplicate", errors[0])

    def test_steps_bounds_and_house_rule(self):
        self.assertTrue(run([item(steps=[])])[0])
        self.assertTrue(run([item(steps=["a"] * 13)])[0])
        errors, warnings = run([item(steps=["a"] * 5)])
        self.assertEqual(errors, [])
        self.assertIn("house rule", warnings[0])
        self.assertTrue(run([item(steps=["ok", "  "])])[0])

    def test_truncation_only_warns(self):
        errors, warnings = run([item(title="t" * 201)])
        self.assertEqual(errors, [])
        self.assertTrue(warnings)

    def test_missing_expected_and_area(self):
        self.assertTrue(run([item(expected="")])[0])
        self.assertTrue(run([item(area=...)])[0])

    def test_deep_link(self):
        self.assertEqual(run([item(deepLink="openhuman://inbox")])[0], [])
        self.assertTrue(run([item(deepLink="https://example.com")])[0])

    def test_format_and_shape(self):
        self.assertTrue(cc.check_data(b'{"format": "other", "items": []}')[0])
        self.assertTrue(cc.check_data(b'"x"')[0])
        self.assertTrue(cc.check_data(b"{")[0])

    def test_too_many_items(self):
        items = [item(id="i%d" % n) for n in range(cc.MAX_ITEMS + 1)]
        self.assertTrue(run(items)[0])

    def test_current_checklist_passes(self):
        root = os.path.join(HERE, "..", "..", "..")
        errors, _warnings, _notes = cc.check_tree(root)
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
