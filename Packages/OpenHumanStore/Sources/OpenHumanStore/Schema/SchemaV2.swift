enum SchemaV2 {
    static let sql = #"""
-- A snippet can add recipients and carry files. JSON shapes as drafts.to_json (WireAddress) and
-- [{"hash","filename","mimeType","size"}]; the bytes live in Snippets/<hash>/<filename> under the store directory.
ALTER TABLE snippets ADD COLUMN to_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE snippets ADD COLUMN cc_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE snippets ADD COLUMN bcc_json TEXT NOT NULL DEFAULT '[]';
ALTER TABLE snippets ADD COLUMN attachments_json TEXT NOT NULL DEFAULT '[]';
-- The text part's RFC 3676 parameters: 'fixed', 'flowed' or 'flowed-delsp'. No CHECK on purpose: since
-- SQLite 3.37 an added CHECK is verified against every existing row (a full scan of the largest table).
ALTER TABLE message_bodies ADD COLUMN text_format TEXT NOT NULL DEFAULT 'fixed';
-- The Waiting view. Membership is the aggregator's (thread_labels of the account's oh:waiting row, sort key = the
-- send time of the account's newest message, oldest first). The user's "not waiting" / "waiting" choice per
-- conversation is kept across re-derivations, local to this Mac.
CREATE TABLE waiting_overrides (
  tid         INTEGER PRIMARY KEY REFERENCES threads(tid) ON DELETE CASCADE,
  account_id  INTEGER NOT NULL,
  state       TEXT NOT NULL CHECK (state = 'not_waiting' OR state = 'waiting'),
  set_at      INTEGER NOT NULL
);
CREATE INDEX waiting_overrides_by_account ON waiting_overrides (account_id);
-- One oh:waiting view row per existing account (new accounts get it from addAccount); oldest first like
-- oh:snoozed. Its rows are filled by the re-aggregation the derived-version bump starts on the next open.
INSERT INTO labels (account_id, key, kind, name, display_name, position, sort_direction, updated_at)
  SELECT account_id, 'oh:waiting', 'virtual', 'Waiting', 'Waiting', 4, 1, CAST(strftime('%s', 'now') AS INTEGER) * 1000
  FROM accounts;
"""#
}
