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
