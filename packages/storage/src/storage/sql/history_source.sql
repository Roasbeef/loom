-- Bounded same-connection identity and generation for shared history readers.

-- name: HistorySourceHeader :one
SELECT CAST(COALESCE(length(metadata), 0) AS INTEGER) AS metadata_bytes,
  next_seq FROM session LIMIT 2;

-- name: HistorySourceMetadata :one
SELECT metadata FROM session LIMIT 2;

-- name: HistorySourceEntry :many
SELECT seq, length(payload) AS payload_bytes FROM entries
WHERE id = @entry_id AND seq < @before_seq LIMIT 2;
