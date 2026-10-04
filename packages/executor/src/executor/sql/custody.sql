-- Static custody queries. Keep ASCII-only for parrot's byte slicing.

-- name: InitializeCustody :exec
INSERT INTO custody_meta (id, binding, capacity, version, bytes)
VALUES (1, ?, ?, 0, 0);

-- Bound values before the SQLite driver can materialize corrupt blobs.
-- name: CustodyMetadata :many
SELECT CAST(CASE WHEN typeof(binding) = 'blob' AND length(binding) <= 303
                 THEN binding ELSE NULL END AS BLOB) AS binding,
       CAST(CASE WHEN typeof(capacity) = 'integer'
                 THEN capacity ELSE NULL END AS INTEGER) AS capacity,
       CAST(CASE WHEN typeof(version) = 'integer'
                 THEN version ELSE NULL END AS INTEGER) AS version,
       CAST(CASE WHEN typeof(bytes) = 'integer'
                 THEN bytes ELSE NULL END AS INTEGER) AS bytes
FROM custody_meta LIMIT 2;

-- name: CustodyEvents :many
SELECT seq,
       CAST(CASE WHEN typeof(payload) = 'blob' AND length(payload) <= 138
                 THEN payload ELSE NULL END AS BLOB) AS payload
FROM custody_event ORDER BY seq LIMIT ?;

-- name: AppendCustodyEvent :exec
INSERT INTO custody_event (seq, payload) VALUES (?, ?);

-- name: AdvanceCustodyHead :many
UPDATE custody_meta SET version = @next_version, bytes = @next_bytes
WHERE id = 1 AND version = @previous_version AND bytes = @previous_bytes
RETURNING version;


-- name: PayloadInventory :many
SELECT COUNT(*) AS items,
       CAST(COALESCE(SUM(length(body)), 0) AS INTEGER) AS bytes
FROM custody_payload WHERE request = ? AND kind = ?;

-- name: PayloadReservations :many
SELECT COUNT(DISTINCT request) AS items FROM custody_payload WHERE kind IN (0, 4);

-- Bound every column before materializing corrupt payloads.
-- name: ReadCustodyPayload :many
SELECT CAST(CASE WHEN typeof(digest) = 'blob' AND length(digest) = 32
                 THEN digest ELSE NULL END AS BLOB) AS digest,
       CAST(CASE WHEN typeof(kind) = 'integer' AND kind BETWEEN 0 AND 4
                 THEN kind ELSE NULL END AS INTEGER) AS kind,
       CAST(CASE WHEN typeof(ordinal) = 'integer' AND ordinal BETWEEN 0 AND 63
                 THEN ordinal ELSE NULL END AS INTEGER) AS ordinal,
       CAST(CASE WHEN typeof(body) = 'blob'
                 AND length(body) <= CASE kind WHEN 0 THEN 131072 WHEN 1 THEN 1024
                   WHEN 2 THEN 16384 WHEN 3 THEN 32768 WHEN 4 THEN 32768 ELSE 0 END
                 THEN body ELSE NULL END AS BLOB) AS body
FROM custody_payload WHERE request = ? ORDER BY kind, ordinal LIMIT 69;

-- name: InsertCustodyPayload :exec
INSERT INTO custody_payload (request, digest, kind, ordinal, body) VALUES (?, ?, ?, ?, ?);
