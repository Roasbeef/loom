-- name: SnapshotSession :one
SELECT next_seq, message_count, length(usage_payload) AS usage_bytes
FROM session LIMIT 2;

-- name: SnapshotUsageValue :one
SELECT usage_payload FROM session LIMIT 2;

-- name: SnapshotRegisterHeaders :many
SELECT key, seq, length(value) AS value_bytes
FROM registers
WHERE ns = @namespace AND substr(key, 1, length(CAST(@prefix AS TEXT))) = @prefix
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
WHERE ns = @namespace AND substr(key, 1, length(CAST(@prefix AS TEXT))) = @prefix
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
