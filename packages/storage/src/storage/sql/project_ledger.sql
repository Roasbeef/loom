-- name: ProjectLedgerAppend :one
INSERT INTO ledger_event (at_ms, event_json) VALUES (?, ?) RETURNING seq;

-- name: ProjectLedgerEventsAfter :many
SELECT seq, at_ms, event_json FROM ledger_event WHERE seq > ? ORDER BY seq LIMIT ?;

-- name: ProjectLedgerLastSeq :one
SELECT CAST(COALESCE(MAX(seq), 0) AS INTEGER) AS last_seq FROM ledger_event;

-- name: ProjectLedgerSnapshot :many
SELECT before_seq, at_ms, snapshot_json FROM ledger_snapshot;

-- name: ProjectLedgerPutSnapshot :exec
INSERT INTO ledger_snapshot (slot, before_seq, at_ms, snapshot_json) VALUES (1, ?, ?, ?)
ON CONFLICT(slot) DO UPDATE
SET before_seq = excluded.before_seq, at_ms = excluded.at_ms, snapshot_json = excluded.snapshot_json;

-- name: ProjectLedgerDeleteBefore :exec
DELETE FROM ledger_event WHERE seq < ?;

-- name: ProjectLedgerCursor :many
SELECT entry_id FROM scanner_cursor WHERE session_id = ?;

-- name: ProjectLedgerPutCursor :exec
INSERT INTO scanner_cursor (session_id, entry_id) VALUES (?, ?)
ON CONFLICT(session_id) DO UPDATE SET entry_id = excluded.entry_id;

-- name: ProjectLedgerPutEffect :exec
INSERT INTO effect_row (kind, key, payload_json, attempts, due_ms) VALUES (?, ?, ?, 0, ?)
ON CONFLICT(kind, key) DO UPDATE
SET payload_json = excluded.payload_json, attempts = 0, due_ms = excluded.due_ms;

-- name: ProjectLedgerEffectsDue :many
SELECT kind, key, payload_json, attempts, due_ms FROM effect_row
WHERE due_ms <= ? ORDER BY due_ms, kind, key LIMIT ?;

-- name: ProjectLedgerDeferEffect :many
UPDATE effect_row SET attempts = attempts + 1, due_ms = ?
WHERE kind = ? AND key = ? RETURNING attempts;

-- name: ProjectLedgerDeleteEffect :exec
DELETE FROM effect_row WHERE kind = ? AND key = ?;
