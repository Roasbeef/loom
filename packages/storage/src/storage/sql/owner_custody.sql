-- name: OwnerCustodyMetadata :many
SELECT CASE WHEN length(CAST(session_id AS BLOB)) = 36 THEN session_id ELSE '' END AS session_id,
  tool_limit, child_limit, byte_limit, payload_limit FROM owner_custody_meta LIMIT 2;

-- name: InitializeOwnerCustody :exec
INSERT INTO owner_custody_meta(singleton, session_id, tool_limit, child_limit, byte_limit, payload_limit)
VALUES (1, @session_id, @tool_limit, @child_limit, @byte_limit, @payload_limit);

-- name: OwnerCustodyBudget :one
SELECT CAST((SELECT COUNT(*) FROM owner_custody_tools) AS INTEGER) AS tools,
  CAST((SELECT COUNT(*) FROM owner_custody_children) AS INTEGER) AS children,
  CAST(COALESCE((SELECT SUM(reserved_bytes) FROM owner_custody_tools), 0)
    + COALESCE((SELECT SUM(reserved_bytes) FROM owner_custody_children), 0) AS INTEGER) AS bytes;

-- name: OwnerToolHeader :many
SELECT CAST(CASE WHEN typeof(identity) = 'blob' THEN length(identity) ELSE -1 END AS INTEGER) AS identity_bytes, CAST(CASE WHEN typeof(arguments) = 'blob' THEN length(arguments) ELSE -1 END AS INTEGER) AS argument_bytes,
  CAST(CASE WHEN typeof(request) = 'blob' THEN length(request) ELSE -1 END AS INTEGER) AS request_bytes, CAST(CASE WHEN outcome IS NULL THEN 0 WHEN typeof(outcome) = 'blob' THEN length(outcome) ELSE -1 END AS INTEGER) AS outcome_bytes,
  CASE WHEN state IN ('retained', 'frozen') THEN state ELSE '' END AS state,
  reserved_bytes FROM owner_custody_tools WHERE address = @address LIMIT 2;

-- name: OwnerToolValue :many
SELECT identity, arguments, request, outcome FROM owner_custody_tools
WHERE address = @address AND typeof(identity) = 'blob' AND length(identity) <= 8192
  AND typeof(arguments) = 'blob' AND typeof(request) = 'blob' AND length(arguments) <= CAST(@payload_limit AS INTEGER) AND length(request) <= CAST(@payload_limit AS INTEGER)
  AND (outcome IS NULL OR (typeof(outcome) = 'blob' AND length(outcome) <= CAST(@payload_limit AS INTEGER))) LIMIT 2;

-- name: InsertOwnerTool :exec
INSERT INTO owner_custody_tools(address, identity, result_entry, arguments, request, state, reserved_bytes)
VALUES (@address, @identity, @result_entry, @arguments, @request, 'retained', @reserved_bytes);

-- name: FinishOwnerTool :exec
UPDATE owner_custody_tools SET outcome = @outcome WHERE address = @address AND state = 'retained' AND outcome IS NULL;

-- name: FreezeOwnerTool :exec
UPDATE owner_custody_tools SET arguments = X'', request = X'', outcome = NULL, state = 'frozen',
  reserved_bytes = length(identity) + length(CAST(address AS BLOB)) + 128 WHERE address = @address;

-- name: OwnerChildHeader :many
SELECT CASE WHEN length(CAST(request_id AS BLOB)) = 36 THEN request_id ELSE '' END AS request_id,
  CAST(CASE WHEN typeof(request) = 'blob' THEN length(request) ELSE -1 END AS INTEGER) AS request_bytes, CAST(CASE WHEN terminal IS NULL THEN 0 WHEN typeof(terminal) = 'blob' THEN length(terminal) ELSE -1 END AS INTEGER) AS terminal_bytes,
  CASE WHEN state IN ('retained', 'frozen', 'cancelled') THEN state ELSE '' END AS state,
  reserved_bytes FROM owner_custody_children WHERE origin = @origin LIMIT 2;

-- name: OwnerChildValue :many
SELECT request, terminal FROM owner_custody_children WHERE origin = @origin
  AND typeof(request) = 'blob' AND length(request) <= CAST(@payload_limit AS INTEGER) AND (terminal IS NULL OR (typeof(terminal) = 'blob' AND length(terminal) <= CAST(@payload_limit AS INTEGER))) LIMIT 2;

-- name: OwnerChildCount :one
SELECT CAST(COUNT(*) AS INTEGER) AS children FROM owner_custody_children WHERE parent = @parent;

-- name: InsertOwnerChild :exec
INSERT INTO owner_custody_children(origin, parent, request_id, request, state, reserved_bytes)
VALUES (@origin, @parent, @request_id, @request, 'retained', @reserved_bytes);

-- name: FinishOwnerChild :exec
UPDATE owner_custody_children SET terminal = @terminal WHERE origin = @origin AND terminal IS NULL AND state IN ('retained', 'cancelled');

-- name: FreezeOwnerChildren :exec
UPDATE owner_custody_children SET request = X'', terminal = NULL, state = 'frozen',
  reserved_bytes = length(CAST(origin AS BLOB)) + length(CAST(parent AS BLOB)) + 164 WHERE parent = @parent;

-- name: CancelOwnerChild :exec
INSERT INTO owner_custody_children(origin, parent, request_id, request, state, reserved_bytes)
VALUES (@origin, @parent, NULL, X'', 'cancelled', @reserved_bytes)
ON CONFLICT(origin) DO UPDATE SET state = CASE WHEN state = 'frozen' THEN 'frozen' ELSE 'cancelled' END;
