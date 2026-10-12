-- Named static queries for the search database (ADR-004 parrot pilot).
-- Compiled to `src/events/sql.gleam` by `scripts/gen-sql.sh`; the
-- generated module is committed. Schema DDL lives in `sql/schema.sql`
-- and stays hand-written.

-- name: InsertEntryText :exec
INSERT INTO entry_fts (session_id, entry_id, kind, ts, text)
VALUES (@session_id, @entry_id, @kind, CAST(@ts AS INTEGER), @text);

-- name: DeleteSessionIndex :exec
DELETE FROM entry_fts WHERE session_id = ?;

-- The `kind` and `ts` columns are read through COALESCE: a row an older
-- binary inserted has them NULL, and the schema is not migrated past version
-- 1, so a NULL must read as a legacy row (kind '' and ts 0) rather than fail
-- the whole query.
--
-- An empty @kind or @before means no filter. Entry ids are UUIDv7, so their
-- text order is commit-time order across sessions, which is what makes
-- `entry_id < @before` a keyset over history. Without @before hits are ranked;
-- with it they come newest first, so feeding the oldest hit of a page back as
-- the next @before visits every older match exactly once. sqlc does not rewrite
-- a named parameter inside ORDER BY, so there it is written by position, `?N`
-- being the first-use number of @before in the statement.
-- name: SearchEntries :many
SELECT
  session_id,
  entry_id,
  COALESCE(kind, '') AS kind,
  CAST(COALESCE(ts, 0) AS INTEGER) AS ts,
  snippet(entry_fts, 4, '[', ']', '...', 12) AS snippet
FROM entry_fts
WHERE entry_fts.text MATCH @query
  AND (CAST(@kind AS TEXT) = '' OR entry_fts.kind = CAST(@kind AS TEXT))
  AND (CAST(@before AS TEXT) = '' OR entry_fts.entry_id < CAST(@before AS TEXT))
ORDER BY CASE WHEN CAST(?3 AS TEXT) = '' THEN rank END, entry_fts.entry_id DESC
LIMIT @max_hits;

-- name: SearchEntriesInSession :many
SELECT
  session_id,
  entry_id,
  COALESCE(kind, '') AS kind,
  CAST(COALESCE(ts, 0) AS INTEGER) AS ts,
  snippet(entry_fts, 4, '[', ']', '...', 12) AS snippet
FROM entry_fts
WHERE entry_fts.text MATCH @query
  AND session_id = @session
  AND (CAST(@kind AS TEXT) = '' OR entry_fts.kind = CAST(@kind AS TEXT))
  AND (CAST(@before AS TEXT) = '' OR entry_fts.entry_id < CAST(@before AS TEXT))
ORDER BY CASE WHEN CAST(?4 AS TEXT) = '' THEN rank END, entry_fts.entry_id DESC
LIMIT @max_hits;

-- The newest rows one session has indexed, for browsing without a query.
-- FTS5 assigns rowids in insertion order and a sync inserts a session's
-- entries in log order, so the highest rowids are its most recent entries.
-- There is no MATCH to anchor snippet(), so the excerpt is the opening of
-- the indexed text.
-- name: RecentEntriesInSession :many
SELECT
  session_id,
  entry_id,
  COALESCE(kind, '') AS kind,
  CAST(COALESCE(ts, 0) AS INTEGER) AS ts,
  substr(text, 1, 160) AS snippet
FROM entry_fts
WHERE session_id = ?
ORDER BY rowid DESC
LIMIT ?;

-- name: GetCursor :one
SELECT generation, high_water
FROM search_cursor
WHERE session_id = ?;

-- name: SearchAuthorizedEntries :many
SELECT session_id, entry_id, COALESCE(kind, '') AS kind,
  CAST(COALESCE(ts, 0) AS INTEGER) AS ts,
  snippet(entry_fts, 4, '[', ']', '...', 12) AS snippet
FROM entry_fts
WHERE entry_fts.text MATCH @query
  AND session_id IN (SELECT value FROM json_each(CAST(@sessions AS TEXT)))
  AND (CAST(@kind AS TEXT) = '' OR entry_fts.kind = CAST(@kind AS TEXT))
  AND (CAST(@before AS TEXT) = '' OR entry_fts.entry_id < CAST(@before AS TEXT))
ORDER BY CASE WHEN CAST(?4 AS TEXT) = '' THEN rank END, entry_fts.entry_id DESC
LIMIT @max_hits;

-- name: SetCursor :exec
INSERT INTO search_cursor (session_id, generation, high_water)
VALUES (?, ?, ?)
ON CONFLICT (session_id) DO UPDATE SET
  generation = excluded.generation,
  high_water = excluded.high_water;

-- name: DeleteCursor :exec
DELETE FROM search_cursor WHERE session_id = ?;

-- name: RegisterSource :exec
INSERT INTO search_source (session_id, path) VALUES (?, ?)
ON CONFLICT (session_id) DO UPDATE SET path = excluded.path;

-- name: GetSource :many
SELECT path FROM search_source WHERE session_id = ?;

-- name: DeleteSource :exec
DELETE FROM search_source WHERE session_id = ?;
