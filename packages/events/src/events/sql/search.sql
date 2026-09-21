-- Named static queries for the search database (ADR-004 parrot pilot).
-- Compiled to `src/events/sql.gleam` by `scripts/gen-sql.sh`; the
-- generated module is committed. Schema DDL lives in `sql/schema.sql`
-- and stays hand-written.

-- name: InsertEntryText :exec
INSERT INTO entry_fts (session_id, entry_id, text)
VALUES (?, ?, ?);

-- name: DeleteSessionIndex :exec
DELETE FROM entry_fts WHERE session_id = ?;

-- name: SearchEntries :many
SELECT
  session_id,
  entry_id,
  snippet(entry_fts, 2, '[', ']', '...', 12) AS snippet
FROM entry_fts
WHERE entry_fts.text MATCH ?
ORDER BY rank
LIMIT ?;

-- name: SearchEntriesInSession :many
SELECT
  session_id,
  entry_id,
  snippet(entry_fts, 2, '[', ']', '...', 12) AS snippet
FROM entry_fts
WHERE entry_fts.text MATCH ?
  AND session_id = ?
ORDER BY rank
LIMIT ?;

-- The newest rows one session has indexed, for browsing without a query.
-- FTS5 assigns rowids in insertion order and a sync inserts a session's
-- entries in log order, so the highest rowids are its most recent entries.
-- There is no MATCH to anchor snippet(), so the excerpt is the opening of
-- the indexed text.
-- name: RecentEntriesInSession :many
SELECT
  session_id,
  entry_id,
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
SELECT session_id, entry_id,
  snippet(entry_fts, 2, '[', ']', '...', 12) AS snippet
FROM entry_fts
WHERE entry_fts.text MATCH @query
  AND session_id IN (SELECT value FROM json_each(CAST(@sessions AS TEXT)))
ORDER BY rank LIMIT @max_hits;

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
