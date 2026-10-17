-- The search database schema (hand-written; ADR-004 keeps DDL out of
-- codegen). One standalone SQLite file per repository — never inside a
-- session file. `events/search` executes these statements verbatim at
-- open; `scripts/gen-sql.sh` loads this file into a throwaway database
-- for the parrot/sqlc code generation. The `schema_matches_source_test`
-- in `events_test` pins the copy embedded in `events/search` to this
-- file, so the two cannot drift.

-- The full-text index: one row per indexed entry. `session_id`, `entry_id`,
-- `kind` and `ts` are stored but not tokenized; `text` is the searchable
-- extracted entry text. `kind` is `user`, `assistant`, `tool` or `summary`
-- (empty for a row migrated from an index that predates the column) and `ts`
-- is the entry's commit time in milliseconds since the epoch (0 for the same
-- migrated rows). The schema version lives in `PRAGMA user_version`, which
-- `events/search` sets after migrating; a FTS5 table cannot be altered, so
-- the migration copies the rows into a table of this shape.
CREATE VIRTUAL TABLE IF NOT EXISTS entry_fts USING fts5(
  session_id UNINDEXED,
  entry_id UNINDEXED,
  kind UNINDEXED,
  ts UNINDEXED,
  text
);

-- The per-session sync cursor: the highest entry seq indexed, together
-- with the session-store generation that numbering belongs to. A
-- generation mismatch at sync time invalidates the session's index rows
-- (the precise rewrite may renumber seqs).
CREATE TABLE IF NOT EXISTS search_cursor (
  session_id TEXT NOT NULL PRIMARY KEY,
  generation INTEGER NOT NULL,
  high_water INTEGER NOT NULL
) WITHOUT ROWID;

-- Host-registered source locators for lease-free exact entry reads.
CREATE TABLE IF NOT EXISTS search_source (
  session_id TEXT NOT NULL PRIMARY KEY,
  path TEXT NOT NULL
) WITHOUT ROWID;
