enum SchemaV1 {
    static let sql = #"""
CREATE TABLE schema_info (
  id                  INTEGER PRIMARY KEY CHECK (id = 1),
  compat_level        INTEGER NOT NULL,          -- see section 4.3
  created_by_version  TEXT NOT NULL,             -- app/CLI semver that created the file
  created_at          INTEGER NOT NULL
);

CREATE TABLE change_feed (
  writer_id   TEXT PRIMARY KEY,                  -- per-process UUID
  pid         INTEGER NOT NULL,
  kind        TEXT NOT NULL CHECK (kind IN ('app','cli','test')),
  seq         INTEGER NOT NULL DEFAULT 0,
  updated_at  INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TABLE observation_pulse (
  id   INTEGER PRIMARY KEY CHECK (id = 1),
  seq  INTEGER NOT NULL DEFAULT 0
);
INSERT INTO observation_pulse (id, seq) VALUES (1, 0);

-- Long-running maintenance done in background chunks, never inside a migration.
CREATE TABLE maintenance_tasks (
  task        TEXT PRIMARY KEY,                  -- e.g. 'fts_rebuild', 'contacts_rebuild'
  state       TEXT NOT NULL CHECK (state IN ('pending','running','done')),
  cursor      TEXT,                              -- task-specific resume point
  updated_at  INTEGER NOT NULL
) WITHOUT ROWID;

CREATE TABLE accounts (
  account_id      INTEGER PRIMARY KEY,           -- local, small, used in every join
  email           TEXT NOT NULL UNIQUE COLLATE NOCASE,
  display_name    TEXT,
  alias           TEXT UNIQUE COLLATE NOCASE,    -- 'work', 'personal' (CLI --account)
  color           TEXT,                          -- '#RRGGBB'
  position        INTEGER NOT NULL DEFAULT 0,
  status          TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','needs_reauth','disabled','removing')),
  granted_scopes  TEXT NOT NULL DEFAULT '',      -- space separated, as granted
  send_as_json    TEXT NOT NULL DEFAULT '[]',    -- [{email,name,isDefault,isPrimary,signatureHtml,replyTo}]
  added_at        INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE TABLE labels (
  label_rid              INTEGER PRIMARY KEY,
  account_id             INTEGER NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  key                    TEXT NOT NULL,
  kind                   TEXT NOT NULL CHECK (kind IN ('system','category','user','virtual','split')),
  name                   TEXT NOT NULL,          -- Gmail full name 'Clients/Acme'; local name for virtual
  display_name           TEXT NOT NULL,          -- last path component
  color_bg               TEXT,
  color_text             TEXT,
  label_list_visibility  TEXT,                   -- Gmail: labelShow | labelShowIfUnread | labelHide
  message_list_visibility TEXT,                  -- Gmail: show | hide
  is_hidden              INTEGER NOT NULL DEFAULT 0,
  position               INTEGER NOT NULL DEFAULT 0,
  sort_direction         INTEGER NOT NULL DEFAULT -1,  -- -1 newest first; +1 oldest first (snoozed)
  total_threads          INTEGER NOT NULL DEFAULT 0,   -- maintained by triggers (3.5)
  unread_threads         INTEGER NOT NULL DEFAULT 0,   -- maintained by triggers (3.5)
  server_threads_total   INTEGER,                -- from labels.get, informational only
  server_threads_unread  INTEGER,
  updated_at             INTEGER NOT NULL,
  UNIQUE (account_id, key)
);

CREATE TABLE threads (
  tid                   INTEGER PRIMARY KEY,
  account_id            INTEGER NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  gmail_thread_id       TEXT NOT NULL,
  subject               TEXT NOT NULL DEFAULT '',  -- first message's subject, prefixes kept
  snippet               TEXT NOT NULL DEFAULT '',  -- latest visible message's Gmail snippet, entity-decoded
  participants_display  TEXT NOT NULL DEFAULT '',  -- 'Alice, Bob, me' (precomputed, section 5.3)
  participants_json     TEXT NOT NULL DEFAULT '[]',-- [{n:name,e:email,me:0|1,u:0|1}] max 6 entries
  message_count         INTEGER NOT NULL DEFAULT 0,-- visible messages (not trash/spam, not drafts)
  unread_count          INTEGER NOT NULL DEFAULT 0,
  draft_count           INTEGER NOT NULL DEFAULT 0,
  attachment_count      INTEGER NOT NULL DEFAULT 0,-- non-inline attachments across visible messages
  is_starred            INTEGER NOT NULL DEFAULT 0,
  is_important          INTEGER NOT NULL DEFAULT 0,
  in_inbox              INTEGER NOT NULL DEFAULT 0,
  is_trashed            INTEGER NOT NULL DEFAULT 0,-- every message in TRASH
  is_spam               INTEGER NOT NULL DEFAULT 0,-- every message in SPAM
  user_label_rids       TEXT NOT NULL DEFAULT '',  -- '12,15' label_rid list for chips (user kind only)
  last_message_at       INTEGER NOT NULL DEFAULT 0,-- max internal_date of visible non-draft messages
  sort_boost_at         INTEGER,                   -- local: snooze wake / reminder fire time (5.2)
  split_rid             INTEGER,                   -- label_rid of the split this inbox thread is in (5.5.3)
  importance            TEXT NOT NULL DEFAULT 'normal'  -- 5.5.2; 'normal' outside the inbox. OR, not IN (...): an
                        -- IN-list CHECK costs ~4 us per row update on this hot table (measured, importance module)
                        CHECK (importance = 'important' OR importance = 'normal' OR importance = 'suppressed'),
  importance_reason_rid INTEGER,                   -- importance_rules.rule_rid that decided (5.5.2); NULL = default signal or none
  split_chip_rids       TEXT NOT NULL DEFAULT '',  -- '21,24' label_rids of other matching splits, shown as chips (5.5.3)
  snoozed_until         INTEGER,                   -- derived cache: effective wake time from OpenHuman/Snoozed/<stamp> labels (3.15.2)
  reminder_at           INTEGER,                   -- mirror of the active local reminder (reminders table)
  scheduled_send_at     INTEGER,                   -- derived cache: earliest send-later due time of a draft in the thread (3.15.2)
  history_id            INTEGER NOT NULL DEFAULT 0,-- max history_id of its messages
  sync_generation       INTEGER NOT NULL DEFAULT 0,-- see 03-sync full resync sweep
  updated_at            INTEGER NOT NULL,
  UNIQUE (account_id, gmail_thread_id)
);

-- Importance counts for the Dock badge (5.5.7): a covering scan of the account's inbox threads.
CREATE INDEX threads_inbox_importance ON threads (account_id, importance, unread_count) WHERE in_inbox = 1;

CREATE TABLE thread_labels (
  label_rid  INTEGER NOT NULL REFERENCES labels(label_rid) ON DELETE CASCADE,
  sort_at    INTEGER NOT NULL,
  tid        INTEGER NOT NULL REFERENCES threads(tid) ON DELETE CASCADE,
  unread     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (label_rid, sort_at, tid)
) WITHOUT ROWID;

CREATE INDEX thread_labels_by_thread ON thread_labels (tid, label_rid);

CREATE TRIGGER thread_labels_ai AFTER INSERT ON thread_labels BEGIN
  UPDATE labels
     SET total_threads  = total_threads + 1,
         unread_threads = unread_threads + NEW.unread
   WHERE label_rid = NEW.label_rid;
END;

CREATE TRIGGER thread_labels_ad AFTER DELETE ON thread_labels BEGIN
  UPDATE labels
     SET total_threads  = total_threads - 1,
         unread_threads = unread_threads - OLD.unread
   WHERE label_rid = OLD.label_rid;
END;

CREATE TRIGGER thread_labels_au AFTER UPDATE OF unread ON thread_labels
WHEN OLD.unread <> NEW.unread BEGIN
  UPDATE labels
     SET unread_threads = unread_threads + NEW.unread - OLD.unread
   WHERE label_rid = NEW.label_rid;
END;

CREATE TABLE messages (
  mid                    INTEGER PRIMARY KEY,   -- stable rowid; FTS content_rowid relies on it
  account_id             INTEGER NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  gmail_message_id       TEXT NOT NULL,
  tid                    INTEGER NOT NULL REFERENCES threads(tid) ON DELETE CASCADE,
  history_id             INTEGER NOT NULL DEFAULT 0,
  internal_date          INTEGER NOT NULL,      -- Gmail internalDate (ms); the sort key
  header_date            INTEGER,               -- parsed Date: header, display only
  subject                TEXT NOT NULL DEFAULT '',
  snippet                TEXT NOT NULL DEFAULT '',
  from_name              TEXT,
  from_email             TEXT COLLATE NOCASE,
  to_json                TEXT NOT NULL DEFAULT '[]',   -- [{"n":"Name","e":"a@b"}]
  cc_json                TEXT NOT NULL DEFAULT '[]',
  bcc_json               TEXT NOT NULL DEFAULT '[]',   -- only present on our own sent/draft messages
  reply_to_json          TEXT NOT NULL DEFAULT '[]',
  rfc822_message_id      TEXT,                  -- Message-ID header, angle brackets stripped
  in_reply_to            TEXT,
  references_ids         TEXT,                  -- space separated, brackets stripped
  list_id                TEXT,
  list_unsubscribe       TEXT,
  list_unsubscribe_post  TEXT,
  server_label_ids       TEXT NOT NULL DEFAULT '',     -- sorted, comma separated, as last seen from Gmail
  label_ids              TEXT NOT NULL DEFAULT '',     -- effective = server + pending overlay (section 5.4)
  is_unread              INTEGER NOT NULL DEFAULT 0,   -- derived from label_ids
  is_starred             INTEGER NOT NULL DEFAULT 0,
  is_draft               INTEGER NOT NULL DEFAULT 0,
  is_sent                INTEGER NOT NULL DEFAULT 0,
  in_trash               INTEGER NOT NULL DEFAULT 0,
  in_spam                INTEGER NOT NULL DEFAULT 0,
  is_from_me             INTEGER NOT NULL DEFAULT 0,   -- from_email in account send-as list
  has_attachments        INTEGER NOT NULL DEFAULT 0,
  has_calendar_invite    INTEGER NOT NULL DEFAULT 0,
  size_estimate          INTEGER NOT NULL DEFAULT 0,
  body_state             INTEGER NOT NULL DEFAULT 0,   -- 0 none, 1 metadata only, 2 body stored, 3 body fetch failed permanently
  sync_generation        INTEGER NOT NULL DEFAULT 0,
  updated_at             INTEGER NOT NULL,
  UNIQUE (account_id, gmail_message_id)
);

CREATE INDEX messages_by_thread   ON messages (tid, internal_date);
CREATE INDEX messages_need_body   ON messages (account_id, internal_date DESC) WHERE body_state < 2;
CREATE INDEX messages_by_rfc822   ON messages (account_id, rfc822_message_id);
CREATE INDEX messages_by_from     ON messages (account_id, from_email, internal_date DESC);
CREATE INDEX messages_by_date     ON messages (account_id, internal_date DESC);
CREATE INDEX messages_generation  ON messages (account_id, sync_generation);
CREATE INDEX messages_sent        ON messages (account_id, internal_date DESC) WHERE is_sent = 1;
-- recentThreads(involving:): from-side uses messages_by_from; to-side scans the newest
-- 2,000 rows of messages_sent with a LIKE on to_json/cc_json (bounded, ~1–3 ms).

CREATE TABLE message_bodies (
  mid               INTEGER PRIMARY KEY REFERENCES messages(mid) ON DELETE CASCADE,
  html              TEXT,             -- raw HTML as decoded by OpenHumanMIME, NOT sanitized
  text              TEXT,             -- text/plain part, or NULL
  html_byte_count   INTEGER NOT NULL DEFAULT 0,
  has_remote_content INTEGER NOT NULL DEFAULT 0, -- html references http(s) resources (precomputed hint)
  decode_warnings   TEXT,             -- e.g. 'charset:unknown x-mac-foo; used windows-1252'
  fetched_at        INTEGER NOT NULL
);

CREATE TABLE attachments (
  aid                  INTEGER PRIMARY KEY,
  mid                  INTEGER NOT NULL REFERENCES messages(mid) ON DELETE CASCADE,
  account_id           INTEGER NOT NULL,
  part_id              TEXT NOT NULL,          -- MIME partId, stable for a message
  gmail_attachment_id  TEXT,                   -- VERIFY: Gmail attachmentId can differ between fetches; re-read it from a fresh messages.get on 404
  filename             TEXT NOT NULL DEFAULT '',
  mime_type            TEXT NOT NULL DEFAULT 'application/octet-stream',
  size                 INTEGER NOT NULL DEFAULT 0,
  content_id           TEXT,                   -- for cid: inline images, brackets stripped
  is_inline            INTEGER NOT NULL DEFAULT 0,
  local_path           TEXT,                   -- relative to the store directory, once downloaded
  downloaded_at        INTEGER,
  UNIQUE (mid, part_id)
);
CREATE INDEX attachments_by_content_id ON attachments (mid, content_id);

CREATE TABLE message_search_docs (
  mid               INTEGER PRIMARY KEY REFERENCES messages(mid) ON DELETE CASCADE,
  subject           TEXT NOT NULL DEFAULT '',
  participants      TEXT NOT NULL DEFAULT '',  -- 'Name <email>' for from/to/cc, one line each
  body              TEXT NOT NULL DEFAULT '',  -- normalized text, capped (section 9.4); snippet until body fetched
  attachment_names  TEXT NOT NULL DEFAULT ''
);

CREATE VIRTUAL TABLE messages_fts USING fts5(
  subject, participants, body, attachment_names,
  content = 'message_search_docs',
  content_rowid = 'mid',
  tokenize = 'trigram case_sensitive 0'
);

CREATE TRIGGER message_search_docs_ai AFTER INSERT ON message_search_docs BEGIN
  INSERT INTO messages_fts (rowid, subject, participants, body, attachment_names)
  VALUES (NEW.mid, NEW.subject, NEW.participants, NEW.body, NEW.attachment_names);
END;

CREATE TRIGGER message_search_docs_ad AFTER DELETE ON message_search_docs BEGIN
  INSERT INTO messages_fts (messages_fts, rowid, subject, participants, body, attachment_names)
  VALUES ('delete', OLD.mid, OLD.subject, OLD.participants, OLD.body, OLD.attachment_names);
END;

CREATE TRIGGER message_search_docs_au AFTER UPDATE ON message_search_docs BEGIN
  INSERT INTO messages_fts (messages_fts, rowid, subject, participants, body, attachment_names)
  VALUES ('delete', OLD.mid, OLD.subject, OLD.participants, OLD.body, OLD.attachment_names);
  INSERT INTO messages_fts (rowid, subject, participants, body, attachment_names)
  VALUES (NEW.mid, NEW.subject, NEW.participants, NEW.body, NEW.attachment_names);
END;

CREATE TABLE deleted_messages (
  account_id        INTEGER NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  gmail_message_id  TEXT NOT NULL,
  history_id        INTEGER NOT NULL,
  deleted_at        INTEGER NOT NULL,
  PRIMARY KEY (account_id, gmail_message_id)
) WITHOUT ROWID;

CREATE TABLE contacts (
  account_id        INTEGER NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  email             TEXT NOT NULL COLLATE NOCASE,
  name              TEXT,
  sent_count        INTEGER NOT NULL DEFAULT 0,   -- messages I sent to them
  received_count    INTEGER NOT NULL DEFAULT 0,   -- messages they sent that I received
  last_sent_at      INTEGER,
  last_received_at  INTEGER,
  score             REAL NOT NULL DEFAULT 0,      -- section 7.2.6
  PRIMARY KEY (account_id, email)
) WITHOUT ROWID;
CREATE INDEX contacts_by_score ON contacts (account_id, score DESC);
CREATE INDEX contacts_by_name  ON contacts (account_id, name COLLATE NOCASE);

CREATE TABLE drafts (
  draft_uuid            TEXT PRIMARY KEY,         -- local id, UUID string; used in deep links before a Gmail id exists
  account_id            INTEGER NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  gmail_draft_id        TEXT,                     -- NULL until created on Gmail
  gmail_message_id      TEXT,                     -- message currently backing the Gmail draft (changes on every update)
  tid                   INTEGER REFERENCES threads(tid) ON DELETE SET NULL,
  gmail_thread_id       TEXT,                     -- for replies: the thread to send into
  compose_mode          TEXT NOT NULL DEFAULT 'new'
                        CHECK (compose_mode IN ('new','reply','reply_all','forward')),
  reply_to_gmail_message_id TEXT,                 -- message being replied to / forwarded
  from_email            TEXT,
  to_json               TEXT NOT NULL DEFAULT '[]',
  cc_json               TEXT NOT NULL DEFAULT '[]',
  bcc_json              TEXT NOT NULL DEFAULT '[]',
  subject               TEXT NOT NULL DEFAULT '',
  body_html             TEXT NOT NULL DEFAULT '',
  body_text             TEXT,                     -- NULL = derive from html at send
  attachments_json      TEXT NOT NULL DEFAULT '[]', -- [{localPath|sourceAid, filename, mimeType, size, contentId?, inline}]
  extra_headers_json    TEXT NOT NULL DEFAULT '{}', -- In-Reply-To, References, X-OpenHuman-Origin, ...
  origin                TEXT NOT NULL DEFAULT 'user' CHECK (origin IN ('user','agent','cli')),
  review_state          TEXT NOT NULL DEFAULT 'none'
                        CHECK (review_state IN ('none','pending','approved','rejected')),
  state                 TEXT NOT NULL DEFAULT 'editing'
                        CHECK (state IN ('editing','scheduled','sending','sent','failed','discarded')),
  send_at               INTEGER,                  -- send-later due time (state='scheduled'); derived cache of the draft's
                                                  -- OpenHuman/Scheduled/<stamp> label / X-OpenHuman-Send-At header (3.15.2)
  local_version         INTEGER NOT NULL DEFAULT 1,
  synced_version        INTEGER NOT NULL DEFAULT 0, -- dirty iff local_version > synced_version
  remote_conflict_json  TEXT,                     -- remote copy kept when both sides changed (03-sync 5.4)
  agent_note            TEXT CHECK (agent_note IS NULL OR length(agent_note) <= 500), -- why the agent drafted this (07 §5)
  agent_snapshot_json   TEXT,                     -- DraftContent as the agent last wrote it, for review diffs
  last_error            TEXT,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  UNIQUE (account_id, gmail_draft_id)
);
CREATE INDEX drafts_by_account ON drafts (account_id, state, updated_at DESC);
CREATE INDEX drafts_review     ON drafts (review_state, updated_at DESC) WHERE review_state = 'pending';
CREATE INDEX drafts_scheduled  ON drafts (send_at) WHERE state = 'scheduled';
CREATE INDEX drafts_by_thread  ON drafts (tid);

CREATE TABLE snippets (
  snippet_id      TEXT PRIMARY KEY,               -- UUID
  account_id      INTEGER REFERENCES accounts(account_id) ON DELETE CASCADE, -- NULL = all accounts
  name            TEXT NOT NULL,
  shortcut        TEXT UNIQUE COLLATE NOCASE,     -- e.g. 'intro', expanded by typing ;;intro + space/tab (trigger rule: 05 §8.7)
  subject         TEXT,
  body_html       TEXT NOT NULL,
  variables_json  TEXT NOT NULL DEFAULT '[]',     -- [{name, default}] ; placeholders {{name}}
  use_count       INTEGER NOT NULL DEFAULT 0,
  last_used_at    INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL
);

CREATE TABLE pending_operations (
  op_id            INTEGER PRIMARY KEY,
  account_id       INTEGER NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  kind             TEXT NOT NULL CHECK (kind IN (
                     'modify_labels',   -- messages.batchModify (archive, read, star, label, spam, snooze labels)
                     'trash',           -- messages.trash per id / threads.trash
                     'untrash',
                     'upsert_draft',    -- drafts.create / drafts.update
                     'delete_draft',    -- drafts.delete
                     'send_draft',      -- drafts.send (undo-send window via not_before)
                     'create_label')),
  payload_json     TEXT NOT NULL,       -- kind-specific, section 7.3
  status           TEXT NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending','in_flight','succeeded','failed','cancelled')),
  attempts         INTEGER NOT NULL DEFAULT 0,
  not_before       INTEGER NOT NULL DEFAULT 0,   -- earliest execution (undo window, send-later)
  next_retry_at    INTEGER NOT NULL DEFAULT 0,
  depends_on       INTEGER REFERENCES pending_operations(op_id) ON DELETE SET NULL,
  coalesce_key     TEXT,                         -- ops with equal key may be merged by the drainer
  origin           TEXT NOT NULL DEFAULT 'app' CHECK (origin IN ('app','cli','scheduler','agent')),
  claimed_by       TEXT,                         -- writer_id of the owner that set in_flight
  claimed_at       INTEGER,
  last_error_code  TEXT,
  last_error_message TEXT,
  created_at       INTEGER NOT NULL,
  updated_at       INTEGER NOT NULL
);
CREATE INDEX pending_ops_ready  ON pending_operations (account_id, status, not_before, next_retry_at);
CREATE INDEX pending_ops_status ON pending_operations (status, updated_at);

-- Which local messages an op affects; drives the optimistic overlay.
CREATE TABLE pending_op_messages (
  mid    INTEGER NOT NULL REFERENCES messages(mid) ON DELETE CASCADE,
  op_id  INTEGER NOT NULL REFERENCES pending_operations(op_id) ON DELETE CASCADE,
  PRIMARY KEY (mid, op_id)
) WITHOUT ROWID;
CREATE INDEX pending_op_messages_by_op ON pending_op_messages (op_id);

-- Derived cache. Written ONLY by the aggregator (5.6) from effective label_ids, in the
-- same transaction as the label change. Never written from user intent directly:
-- a snooze is a modify_labels op, and the overlay (5.4) makes it visible at once.
CREATE TABLE snoozes (
  tid                 INTEGER PRIMARY KEY REFERENCES threads(tid) ON DELETE CASCADE,
  account_id          INTEGER NOT NULL,
  gmail_thread_id     TEXT NOT NULL,
  wake_at             INTEGER,                    -- NULL when status = 'malformed'
  label_name          TEXT,                       -- the effective schedule label (earliest stamp), e.g. 'OpenHuman/Snoozed/20261012T0900Z'
  stamp_label_count   INTEGER NOT NULL DEFAULT 1, -- distinct valid stamps on the thread; > 1 needs normalizing (3.15.2)
  status              TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','malformed'))
);
CREATE INDEX snoozes_due ON snoozes (status, wake_at);

-- Local only (not in Gmail, not shared between Macs). Source of truth for reminders.
CREATE TABLE reminders (
  reminder_id         TEXT PRIMARY KEY,           -- UUID
  tid                 INTEGER NOT NULL REFERENCES threads(tid) ON DELETE CASCADE,
  account_id          INTEGER NOT NULL,
  gmail_thread_id     TEXT NOT NULL,
  set_at              INTEGER NOT NULL,
  due_at              INTEGER NOT NULL,
  condition           TEXT NOT NULL CHECK (condition IN ('always','if_no_reply')),
  anchor_message_id   TEXT,                       -- latest message when set; 'reply' = any later message not from me
  state               TEXT NOT NULL DEFAULT 'active'
                      CHECK (state IN ('active','fired','satisfied','cancelled'))
);
CREATE INDEX reminders_due ON reminders (state, due_at);
CREATE UNIQUE INDEX reminders_one_active ON reminders (tid) WHERE state = 'active';

CREATE TABLE sync_lease (
  account_id             INTEGER PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  owner_id               TEXT NOT NULL,           -- writer_id of the owning process
  owner_kind             TEXT NOT NULL CHECK (owner_kind IN ('app','cli','cli_daemon')),
  owner_pid              INTEGER NOT NULL,
  host                   TEXT NOT NULL,
  acquired_at            INTEGER NOT NULL,
  heartbeat_at           INTEGER NOT NULL,
  expires_at             INTEGER NOT NULL,        -- heartbeat_at + 45 s
  takeover_requested_by  TEXT,
  takeover_requested_at  INTEGER
);

CREATE TABLE splits (
  split_id    TEXT PRIMARY KEY,                    -- UUID
  account_id  INTEGER NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  label_rid   INTEGER NOT NULL UNIQUE REFERENCES labels(label_rid) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  position    INTEGER NOT NULL,                    -- evaluation and display order
  rule_text   TEXT NOT NULL,                       -- canonical text form, e.g. 'from:(@acme.com) OR label:Clients'
  rule_json   TEXT NOT NULL,                       -- parsed SplitRule (section 5.5)
  enabled     INTEGER NOT NULL DEFAULT 1,
  role        TEXT CHECK (role IS NULL OR role = 'important'), -- 'important' = the importance split ("Primary", 5.5.2)
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  UNIQUE (account_id, name)
);
CREATE UNIQUE INDEX splits_one_importance ON splits (account_id) WHERE role = 'important';

CREATE TABLE importance_rules (
  rule_rid    INTEGER PRIMARY KEY AUTOINCREMENT,   -- never reused, so an undo can restore a deleted rule under its id
  account_id  INTEGER REFERENCES accounts(account_id) ON DELETE CASCADE, -- NULL = every account
  kind        TEXT NOT NULL CHECK (kind IN ('sender','domain','keyword','label','matcher')),
  value       TEXT NOT NULL,                       -- normalized per kind (5.5.4)
  effect      TEXT NOT NULL CHECK (effect IN ('important','never_important','exempt_from_split')),
  split_id    TEXT REFERENCES splits(split_id) ON DELETE CASCADE, -- exempt_from_split only; NULL = every split but the importance split
  source      TEXT NOT NULL DEFAULT 'user' CHECK (source IN ('user','ai')),
  created_at  INTEGER NOT NULL,
  updated_at  INTEGER NOT NULL,
  CHECK (split_id IS NULL OR (effect = 'exempt_from_split' AND account_id IS NOT NULL))
);
-- One importance rule per (scope, kind, value, source): 'important' and 'never_important' replace each other (5.5.6);
-- one exemption per (scope, kind, value, split, source).
CREATE UNIQUE INDEX importance_rules_key ON importance_rules (
  COALESCE(account_id, 0), kind, value, source,
  CASE effect WHEN 'exempt_from_split' THEN 'x:' || COALESCE(split_id, '*') ELSE 'i' END);
CREATE INDEX importance_rules_by_account ON importance_rules (account_id);

CREATE TABLE sync_state (
  account_id            INTEGER PRIMARY KEY REFERENCES accounts(account_id) ON DELETE CASCADE,
  phase                 TEXT NOT NULL DEFAULT 'new'
                        CHECK (phase IN ('new','bootstrapping','inbox_ready','backfilling','incremental','resync_required')),
  history_id            INTEGER,                 -- last history id fully applied; NULL before bootstrap
  bootstrap_history_id  INTEGER,                 -- profile.historyId captured before initial listing
  generation            INTEGER NOT NULL DEFAULT 1,
  backfill_oldest_at    INTEGER,                 -- oldest internal_date covered by metadata backfill
  backfill_complete     INTEGER NOT NULL DEFAULT 0,
  body_backfill_complete INTEGER NOT NULL DEFAULT 0,
  labels_refreshed_at   INTEGER,
  drafts_refreshed_at   INTEGER,
  send_as_refreshed_at  INTEGER,
  last_incremental_at   INTEGER,
  last_success_at       INTEGER,
  last_attempt_at       INTEGER,
  consecutive_failures  INTEGER NOT NULL DEFAULT 0,
  last_error_code       TEXT,
  last_error_message    TEXT,
  updated_at            INTEGER NOT NULL
);

CREATE TABLE sync_log (
  log_id        INTEGER PRIMARY KEY,
  account_id    INTEGER NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  started_at    INTEGER NOT NULL,
  finished_at   INTEGER,
  kind          TEXT NOT NULL,         -- 'bootstrap','inbox','backfill','bodies','incremental','full_resync','labels','drafts','queue'
  outcome       TEXT,                  -- 'ok','error','cancelled'
  quota_units   INTEGER NOT NULL DEFAULT 0,
  requests      INTEGER NOT NULL DEFAULT 0,
  added         INTEGER NOT NULL DEFAULT 0,
  changed       INTEGER NOT NULL DEFAULT 0,
  deleted       INTEGER NOT NULL DEFAULT 0,
  error_code    TEXT,
  detail        TEXT                   -- no message content, no addresses
);
CREATE INDEX sync_log_recent ON sync_log (account_id, started_at DESC);

CREATE TABLE settings (
  scope       TEXT NOT NULL,           -- 'global' or 'account:<account_id>'
  key         TEXT NOT NULL,
  value_json  TEXT NOT NULL,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (scope, key)
) WITHOUT ROWID;

"""#
}
