-- Prefix selection is an index range on registers(ns, key), never a scan of
-- the namespace: @prefix_upper is the prefix's successor, computed in Gleam,
-- so wildcard characters keep carrying no special meaning. An empty
-- @prefix_upper means the prefix has no successor and the range is open
-- above; a BLOB sorts after every TEXT value in SQLite, which is how one
-- statement expresses both cases. The JSON predicate then runs only on the
-- narrowed window.
-- name: SnapshotSession :one
SELECT next_seq, message_count, length(usage_payload) AS usage_bytes
FROM session LIMIT 2;

-- name: SnapshotUsageValue :one
SELECT usage_payload FROM session LIMIT 2;

-- name: SnapshotRegisterHeaders :many
SELECT key, seq, length(value) AS value_bytes
FROM registers
WHERE ns = @namespace AND key >= @prefix AND key <
  CASE WHEN CAST(@prefix_upper AS TEXT) = '' THEN CAST('' AS BLOB)
  ELSE CAST(@prefix_upper AS TEXT) END
AND CASE
  WHEN CAST(@field AS TEXT) = '' THEN 1
  WHEN length(value) > 1048576 THEN 1
  WHEN NOT json_valid(CAST(value AS TEXT)) THEN 1
  WHEN json_type(CAST(value AS TEXT), '$.' || @field) IS NOT 'text' THEN 1
  ELSE json_extract(CAST(value AS TEXT), '$.' || @field) = CAST(@expected AS TEXT)
END
ORDER BY key LIMIT 1025;

-- name: SnapshotRegisterBudget :one
SELECT COUNT(*) AS cell_count,
  CAST(COALESCE(SUM(length(value) + length(CAST(key AS BLOB)) + length(CAST(ns AS BLOB)) + 65), 0) AS INTEGER) AS total_bytes
FROM registers
WHERE ns = @namespace AND key >= @prefix AND key <
  CASE WHEN CAST(@prefix_upper AS TEXT) = '' THEN CAST('' AS BLOB)
  ELSE CAST(@prefix_upper AS TEXT) END
AND CASE
  WHEN CAST(@field AS TEXT) = '' THEN 1
  WHEN length(value) > 1048576 THEN 1
  WHEN NOT json_valid(CAST(value AS TEXT)) THEN 1
  WHEN json_type(CAST(value AS TEXT), '$.' || @field) IS NOT 'text' THEN 1
  ELSE json_extract(CAST(value AS TEXT), '$.' || @field) = CAST(@expected AS TEXT)
END;

-- name: SnapshotRegisterValue :one
SELECT value FROM registers
WHERE ns = @namespace AND key = @key AND seq = @seq;

-- The cursor and limit narrow the header window before either budget
-- accounting or payload fetching, so retained history outside this page
-- cannot make a small read exceed the metadata budget.
-- name: SnapshotRegisterPageBudget :one
SELECT COUNT(*) AS cell_count,
  CAST(COALESCE(SUM(value_bytes + key_bytes + ns_bytes + 65), 0) AS INTEGER) AS total_bytes
FROM (
  SELECT length(value) AS value_bytes, length(CAST(key AS BLOB)) AS key_bytes,
    length(CAST(ns AS BLOB)) AS ns_bytes
  FROM registers
  WHERE ns = @namespace
  AND key >= MAX(CAST(@prefix AS TEXT), CAST(@after_key AS TEXT))
  AND key <> @after_key AND key <
    CASE WHEN CAST(@prefix_upper AS TEXT) = '' THEN CAST('' AS BLOB)
    ELSE CAST(@prefix_upper AS TEXT) END
  ORDER BY key LIMIT @page_size
);

-- name: SnapshotRegisterPageHeaders :many
SELECT key, seq, length(value) AS value_bytes
FROM registers
WHERE ns = @namespace
AND key >= MAX(CAST(@prefix AS TEXT), CAST(@after_key AS TEXT))
AND key <> @after_key AND key <
  CASE WHEN CAST(@prefix_upper AS TEXT) = '' THEN CAST('' AS BLOB)
  ELSE CAST(@prefix_upper AS TEXT) END
ORDER BY key LIMIT @page_size;

-- name: SnapshotRegisterHeader :one
SELECT seq, length(value) AS value_bytes FROM registers
WHERE ns = @namespace AND key = @key;

-- name: SnapshotEntryPage :many
SELECT CAST(CASE WHEN length(CAST(id AS BLOB)) = 36 THEN id ELSE '' END AS TEXT) AS id,
  seq, length(payload) AS payload_bytes FROM entries
WHERE seq > @after_seq AND seq < @before_seq
ORDER BY seq ASC LIMIT @page_size;

-- name: SnapshotRecentEntries :many
SELECT CAST(CASE WHEN length(CAST(id AS BLOB)) = 36 THEN id ELSE '' END AS TEXT) AS id,
  seq, length(payload) AS payload_bytes FROM entries
WHERE seq < @before_seq ORDER BY seq DESC LIMIT @page_size;

-- name: SnapshotEntryFragment :one
SELECT CAST(substr(payload, CAST(@offset AS INTEGER) + 1, @fragment_size) AS BLOB) AS fragment FROM entries
WHERE id = @id AND seq = @seq AND length(payload) = CAST(@payload_bytes AS INTEGER);

-- One entry's placement without its payload, by identity, for the walk down a
-- strand's ancestry. Each call is a primary-key probe of entries, so a walk
-- costs the records it returns and never the records of other strands written
-- between them. An entry whose sequence is not below @before_seq is not
-- returned, which keeps the walk inside the high-water the transfer was
-- captured at.
-- name: SnapshotEntryHead :many
SELECT CAST(CASE WHEN length(CAST(id AS BLOB)) = 36 THEN id ELSE '' END AS TEXT) AS id,
  parent_id, seq, length(payload) AS payload_bytes FROM entries
WHERE id = @entry_id AND seq < @before_seq LIMIT 2;
