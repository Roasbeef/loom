-- A project's ledger file (protocol-change/106, "Durable state"). One SQLite
-- file per project with one writer, the project actor, and never replicated.
-- The file is its own database and holds no catalogue table. Times are Unix
-- milliseconds read from the system clock, never the monotonic clock.
--
-- ledger_event is the engine's append-only history. event_json is the engine's
-- own encoding of one event, which storage keeps as opaque text after checking
-- that it is a JSON document. seq is assigned by SQLite and rises by one for
-- each event. Compaction only deletes the lowest rows and always keeps the
-- newest, so seq never repeats.
CREATE TABLE ledger_event(
  seq INTEGER PRIMARY KEY,
  at_ms INTEGER NOT NULL CHECK(at_ms >= 0),
  event_json TEXT NOT NULL CHECK(length(CAST(event_json AS BLOB)) BETWEEN 2 AND 1048576)
);

-- The scanner's read position in each worker session's commit stream: the id
-- of the last entry whose report or human turn the engine has taken in.
CREATE TABLE scanner_cursor(
  session_id TEXT NOT NULL PRIMARY KEY CHECK(length(CAST(session_id AS BLOB)) BETWEEN 1 AND 64),
  entry_id TEXT NOT NULL CHECK(length(CAST(entry_id AS BLOB)) BETWEEN 1 AND 64)
);

-- Outside actions the engine has decided on and the host has not yet settled,
-- one row per (kind, key). The key derives from the event that caused the
-- effect, so enqueueing the same intent twice is one row. attempts counts the
-- deferrals since the row was written, and due_ms is the earliest time the
-- host may try it.
CREATE TABLE effect_row(
  kind TEXT NOT NULL CHECK(length(CAST(kind AS BLOB)) BETWEEN 1 AND 64),
  key TEXT NOT NULL CHECK(length(CAST(key AS BLOB)) BETWEEN 1 AND 256),
  payload_json TEXT NOT NULL CHECK(length(CAST(payload_json AS BLOB)) BETWEEN 2 AND 1048576),
  attempts INTEGER NOT NULL CHECK(attempts >= 0),
  due_ms INTEGER NOT NULL CHECK(due_ms >= 0),
  PRIMARY KEY (kind, key)
);

CREATE INDEX effect_row_due ON effect_row(due_ms, kind, key);

-- The retention hook: at most one row, the engine's state as of every event
-- below before_seq. Events below before_seq are deleted in the same
-- transaction that writes the row, so a replay starts from this row and the
-- events at and above before_seq.
CREATE TABLE ledger_snapshot(
  slot INTEGER NOT NULL PRIMARY KEY CHECK(slot = 1),
  before_seq INTEGER NOT NULL CHECK(before_seq >= 1),
  at_ms INTEGER NOT NULL CHECK(at_ms >= 0),
  snapshot_json TEXT NOT NULL CHECK(length(CAST(snapshot_json AS BLOB)) BETWEEN 2 AND 67108864)
);
