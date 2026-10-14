#!/usr/bin/env python3
"""Writes the schema-v1 fixture database for the v1 -> v2 migration tests.

The file is what a v1 build leaves behind: migration "v1" applied (the exact SQL of SchemaV1.swift, plus GRDB's
`grdb_migrations` table with its one row) and a little synthetic data in the tables v2 extends or must not disturb:
an account, a thread with one message, its body, its search document (so the FTS index has a row), a snippet, a
contact and a setting. Synthetic data only (example.com addresses). Deterministic: same input, same rows.

Usage: python3 -I Tools/fixtures/make-store-schema-v1.py   (rewrites the fixture; commit it with the test change)
"""
import os
import re
import sqlite3

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
STORE = os.path.join(ROOT, "Packages/OpenHumanStore")
SCHEMA_V1 = os.path.join(STORE, "Sources/OpenHumanStore/Schema/SchemaV1.swift")
OUT = os.path.join(STORE, "Tests/OpenHumanStoreTests/Fixtures/schema/schema-v1.sqlite")
T = 1_760_000_000_000


def v1_sql():
    text = open(SCHEMA_V1, encoding="utf-8").read()
    m = re.search(r'#"""\n(.*?)"""#', text, re.S)
    return m.group(1)


def main():
    if os.path.exists(OUT):
        os.remove(OUT)
    db = sqlite3.connect(OUT)
    db.execute("PRAGMA page_size = 1024")
    db.execute("PRAGMA auto_vacuum = INCREMENTAL")
    db.executescript(v1_sql())
    db.execute("CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
    db.execute("INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
    db.execute("INSERT INTO schema_info (id, compat_level, created_by_version, created_at) VALUES (1, 1, '0.0.0-fixture', ?)", (T,))
    db.execute("INSERT INTO accounts (account_id, email, display_name, added_at, updated_at) "
               "VALUES (1, 'fixture@example.com', 'Fixture', ?, ?)", (T, T))
    db.execute("INSERT INTO sync_state (account_id, updated_at) VALUES (1, ?)", (T,))
    db.execute("INSERT INTO threads (tid, account_id, gmail_thread_id, subject, snippet, message_count, last_message_at, "
               "updated_at) VALUES (1, 1, 'fixture-thread-1', 'Fixture subject', 'Plain fixture body', 1, ?, ?)", (T, T))
    db.execute("INSERT INTO messages (mid, account_id, gmail_message_id, tid, internal_date, subject, snippet, from_name, "
               "from_email, to_json, body_state, updated_at) VALUES (1, 1, 'fixture-message-1', 1, ?, 'Fixture subject', "
               "'Plain fixture body', 'Sender', 'sender@example.com', '[{\"e\":\"fixture@example.com\"}]', 2, ?)", (T, T))
    db.execute("INSERT INTO message_bodies (mid, html, text, html_byte_count, fetched_at) "
               "VALUES (1, NULL, 'Plain fixture body that wraps \nonto a second line.', 0, ?)", (T,))
    db.execute("INSERT INTO message_search_docs (mid, subject, participants, body, attachment_names) VALUES "
               "(1, 'Fixture subject', 'Sender <sender@example.com>', 'plain fixture body that wraps onto a second line', '')")
    db.execute("INSERT INTO snippets (snippet_id, account_id, name, shortcut, subject, body_html, variables_json, use_count, "
               "created_at, updated_at) VALUES ('fixture-snippet-1', NULL, 'Fixture snippet', 'fix', 'Hello', "
               "'<p>Hello {{first_name}}</p>', '[{\"default\":\"there\",\"name\":\"first_name\"}]', 3, ?, ?)", (T, T))
    db.execute("INSERT INTO contacts (account_id, email, name, sent_count, received_count, last_sent_at, score) "
               "VALUES (1, 'friend@example.com', 'Friend', 4, 2, ?, 4.002)", (T,))
    db.execute("INSERT INTO settings (scope, key, value_json, updated_at) VALUES ('global', 'fixture.flag', 'true', ?)", (T,))
    db.commit()
    db.execute("VACUUM")
    db.close()
    print("wrote", os.path.relpath(OUT, ROOT), os.path.getsize(OUT), "bytes")


if __name__ == "__main__":
    main()
