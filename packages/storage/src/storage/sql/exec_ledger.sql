-- Internal queries for the executor's execution ledger. Every write belongs to
-- a transaction that storage/exec_ledger opens, because the checks that guard a
-- write and the write itself must commit together.

-- name: LedgerScope :many
SELECT session, workspace, incarnation, state, close_outcome, attach_token
FROM scope WHERE session = ?;

-- name: LedgerUncleanScopeCount :one
SELECT COUNT(*) AS scopes FROM scope
WHERE state != 'closed' OR close_outcome IS NOT 'all_retired';

-- name: InsertLedgerScope :exec
INSERT INTO scope(session, workspace, incarnation, state, close_outcome, attach_token)
VALUES (?, ?, ?, 'open', NULL, ?);

-- name: RebindLedgerScope :exec
UPDATE scope SET attach_token = ? WHERE session = ? AND workspace = ?;

-- name: ReopenLedgerScope :exec
UPDATE scope
SET incarnation = ?, state = 'open', close_outcome = NULL, attach_token = ?
WHERE session = ? AND workspace = ?;

-- name: BeginLedgerScopeClose :exec
UPDATE scope SET state = 'closing' WHERE session = ? AND workspace = ?;

-- name: FinishLedgerScopeClose :exec
UPDATE scope SET state = 'closed', close_outcome = ?
WHERE session = ? AND workspace = ?;

-- name: LedgerCall :many
SELECT tool, state, outcome, outcome_digest, outcome_bytes
FROM call
WHERE session = ? AND op = ? AND step = ? AND source_index = ?;

-- name: LedgerReservedBytes :one
SELECT CAST(COALESCE(SUM(outcome_bytes), 0) AS INTEGER) AS bytes FROM call
WHERE state IN ('admitted', 'terminal');

-- name: InsertLedgerCall :exec
INSERT INTO call(
  session, op, step, source_index, incarnation, tool,
  state, outcome, outcome_digest, outcome_bytes)
VALUES (?, ?, ?, ?, ?, ?, 'admitted', NULL, NULL, ?);

-- name: InsertLedgerFence :exec
INSERT INTO call(
  session, op, step, source_index, incarnation, tool,
  state, outcome, outcome_digest, outcome_bytes)
VALUES (?, ?, ?, ?, ?, ?, 'terminal', ?, ?, ?);

-- name: FinishLedgerCall :exec
UPDATE call
SET state = 'terminal', outcome = ?, outcome_digest = ?, outcome_bytes = ?
WHERE session = ? AND op = ? AND step = ? AND source_index = ?
  AND state = 'admitted';

-- name: MarkLedgerCallUnknown :exec
UPDATE call SET state = 'unknown', outcome_bytes = 0
WHERE session = ? AND op = ? AND step = ? AND source_index = ?
  AND state = 'admitted';

-- name: AckLedgerCall :exec
DELETE FROM call
WHERE session = ? AND op = ? AND step = ? AND source_index = ?
  AND state IN ('terminal', 'unknown');

-- name: RecoverLedgerCalls :exec
UPDATE call SET state = 'unknown', outcome_bytes = 0 WHERE state = 'admitted';

-- name: LedgerUnackedKeys :many
SELECT op, step, source_index, state FROM call
WHERE session = ? AND state IN ('terminal', 'unknown')
ORDER BY op, step, source_index;
