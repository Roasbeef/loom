-- ASCII-only static workspace queries for Parrot/sqlc.
-- name: InitializeWorkspace :exec
INSERT INTO workspace_meta(id, format, mode, binding, row_limit, byte_limit) VALUES(1, 2, 0, ?, ?, ?);

-- name: WorkspaceMetadata :many
SELECT CAST(CASE WHEN typeof(id)='integer' AND id=1 AND typeof(format)='integer' AND format=2 AND typeof(binding)='blob' AND length(binding)<=303 THEN binding ELSE NULL END AS BLOB) AS binding,
       CAST(CASE WHEN typeof(mode)='integer' AND mode IN (0,1) THEN mode ELSE NULL END AS INTEGER) AS mode,
       CAST(CASE WHEN typeof(row_limit)='integer' THEN row_limit ELSE NULL END AS INTEGER) AS row_limit,
       CAST(CASE WHEN typeof(byte_limit)='integer' THEN byte_limit ELSE NULL END AS INTEGER) AS byte_limit
FROM workspace_meta LIMIT 2;

-- Header projections never materialize request or completion bodies.
-- name: WorkspaceHeaders :many
SELECT CAST(CASE WHEN typeof(id)='blob' AND length(id)=36 THEN id ELSE NULL END AS BLOB) AS id,
       CAST(CASE WHEN typeof(request_digest)='blob' AND length(request_digest)=32 THEN request_digest ELSE NULL END AS BLOB) AS request_digest,
       CAST(CASE WHEN typeof(request_size)='integer' AND request_size BETWEEN 1 AND 9437184 THEN request_size ELSE NULL END AS INTEGER) AS request_size,
       CAST(CASE WHEN typeof(phase)='integer' AND phase BETWEEN 0 AND 4 THEN phase ELSE NULL END AS INTEGER) AS phase,
       CAST(CASE WHEN typeof(result_digest)='blob' AND length(result_digest) IN (0,32) THEN result_digest ELSE NULL END AS BLOB) AS result_digest,
       CAST(CASE WHEN typeof(result_size)='integer' AND result_size BETWEEN 0 AND 33554432 THEN result_size ELSE NULL END AS INTEGER) AS result_size,
       CAST(CASE WHEN typeof(request)='blob' AND typeof(result)='blob'
         AND ((phase IN (0,1,4) AND length(request)=request_size AND length(result)=0 AND result_size=0 AND length(result_digest)=0)
           OR (phase=2 AND length(request)=request_size AND length(result)=result_size AND result_size>0 AND length(result_digest)=32)
           OR (phase=3 AND length(request)=0 AND length(result)=0 AND result_size>0 AND length(result_digest)=32))
         THEN 1 ELSE 0 END AS INTEGER) AS valid
FROM workspace_call ORDER BY id LIMIT ?;

-- Bounds stay in SQL as well as headers, before the driver sees a BLOB.
-- name: WorkspaceBodies :many
SELECT CAST(CASE WHEN typeof(request)='blob' AND length(request)<=9437184 THEN request ELSE NULL END AS BLOB) AS request,
       CAST(CASE WHEN typeof(result)='blob' AND length(result)<=33554432 THEN result ELSE NULL END AS BLOB) AS result
FROM workspace_call WHERE id=? LIMIT 2;

-- name: InsertWorkspace :exec
INSERT INTO workspace_call(id,request_digest,request_size,phase,request,result_digest,result_size,result)
VALUES(?,?,?,0,?,X'',0,X'');

-- name: ClaimWorkspace :many
UPDATE workspace_call SET phase=1 WHERE id=? AND phase=0 RETURNING phase;

-- name: FinishWorkspace :many
UPDATE workspace_call SET phase=2,result_digest=?,result_size=?,result=? WHERE id=? AND phase=1 RETURNING phase;

-- name: AcknowledgeWorkspace :many
UPDATE workspace_call SET phase=3,request=X'',result=X'' WHERE id=? AND phase=2 RETURNING phase;

-- name: CancelWorkspace :many
UPDATE workspace_call SET phase=4 WHERE id=? AND phase=0 RETURNING phase;

-- A sealed scope never reopens; retained completions and receipts remain usable.
-- name: SealWorkspace :many
UPDATE workspace_meta SET mode=1 WHERE id=1 RETURNING mode;
