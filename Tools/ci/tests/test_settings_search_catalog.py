"""The Settings search catalog (SettingsSearch.swift) lists the titles the settings pages show.

A row or section added to a page with a literal title has to be added to the catalog (or to IGNORED below) so the
search can find it, and a catalog title has to still exist on a page so opening the result highlights something.
"""
import glob
import os
import re
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
CATALOG = os.path.join(ROOT, "Packages/OpenHumanMailCore/Sources/MailFeatures/Settings/SettingsSearch.swift")
SOURCE_GLOBS = [
    "Packages/OpenHumanMailUI/Sources/MailUI/Settings/**/*.swift",
    "Packages/OpenHumanMailUI/Sources/MailUI/DevFeedback/DevFeedbackSettingsView.swift",
    "Packages/OpenHumanMailLive/Sources/OpenHumanMailLive/Semantic/SmartSearchIndexSettingsView.swift",
    "Apps/Mail/Sources/Settings/*.swift",
    # Why: the Platform features page titles its sections with these features' titles
    "Packages/OpenHumanMailCore/Sources/MailFeatures/Settings/PlatformFeatures.swift",
]
LITERAL = r'"((?:[^"\\]|\\.)*)"'
PAGE_TITLE = re.compile(r"\b(?:SettingsRow|SettingsSection|switchRow)\(\s*(?:String\(localized:\s*)?" + LITERAL)
CATALOG_TITLE = re.compile(r"(?<!page)\(\s*" + LITERAL + r"\s*,\s*\[")

# Titles too generic or short-lived to be worth a result: editor fields, status lines and per-account rows.
IGNORED = {
    "Applies to",
    "Mail is",
    "Run with this text",
    "Test on this thread",
    "Status",
    "Show",
    "Last read",
    "Connect with",
    "Google client",
    "Calendar",
    "Preview",
    "Import",
    "Rename saved search",
    "[Superhuman]/AI/",
}


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def sources():
    paths = sorted({p for g in SOURCE_GLOBS for p in glob.glob(os.path.join(ROOT, g), recursive=True)})
    return [p for p in paths if os.path.abspath(p) != CATALOG]


def page_titles():
    titles = {}
    for path in sources():
        for match in PAGE_TITLE.finditer(read(path)):
            title = match.group(1)
            if "\\(" not in title:
                titles.setdefault(title, os.path.relpath(path, ROOT))
    return titles


def catalog_titles():
    text = read(CATALOG)
    return set(CATALOG_TITLE.findall(text[text.index("enum SettingsSearchCatalog"):]))


class SettingsSearchCatalogTests(unittest.TestCase):
    def test_every_literal_settings_title_is_searchable(self):
        catalog = catalog_titles()
        missing = sorted(f"{path}: {title!r}" for title, path in page_titles().items()
                         if title not in catalog and title not in IGNORED)
        self.assertEqual(missing, [], "add these to SettingsSearchCatalog (or IGNORED in this test)")

    def test_every_catalog_title_is_still_on_a_page(self):
        text = "\n".join(read(p) for p in sources())
        stale = sorted(t for t in catalog_titles() if f'"{t}"' not in text)
        self.assertEqual(stale, [], "these catalog titles no longer appear in a settings page")

    def test_ignored_titles_are_still_used(self):
        titles = page_titles()
        self.assertEqual(sorted(t for t in IGNORED if t not in titles), [])


if __name__ == "__main__":
    unittest.main()
