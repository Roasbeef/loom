-- ASCII-only named generation queries. Scalar checks precede payload reads.
-- name: InitializeGenerations :exec
INSERT INTO generation_meta(id,format,live_limit,row_limit,byte_limit) VALUES(1,2,?,?,?);

-- name: GenerationFormat :many
SELECT CAST(CASE WHEN typeof(format)='integer' AND format IN (1,2) THEN format ELSE NULL END AS INTEGER) AS format FROM generation_meta LIMIT 2;

-- name: GenerationMetadata :many
SELECT CAST(CASE WHEN typeof(live_limit)='integer' AND live_limit BETWEEN 1 AND 16 THEN live_limit ELSE NULL END AS INTEGER) AS live_limit,
 CAST(CASE WHEN typeof(row_limit)='integer' AND row_limit BETWEEN 1 AND 4096 THEN row_limit ELSE NULL END AS INTEGER) AS row_limit,
 CAST(CASE WHEN typeof(byte_limit)='integer' AND byte_limit BETWEEN 1 AND 268435456 THEN byte_limit ELSE NULL END AS INTEGER) AS byte_limit
FROM generation_meta WHERE id=1 LIMIT 2;

-- Grouped field guards keep BETWEEN/AND chains unambiguous to sqlc.
-- The rows alias is quoted because SQL reserves that keyword.
-- name: GenerationInventory :many
SELECT COUNT(*) AS "rows", COALESCE(SUM(live),0) AS live, COALESCE(SUM(reservation),0) AS bytes,
 COALESCE(SUM(CASE WHEN (typeof(key)='blob' AND length(key) BETWEEN 1 AND 1024)
 AND (typeof(scope)='blob' AND length(scope) BETWEEN 1 AND 1024)
 AND (typeof(association)='blob' AND length(association) BETWEEN 0 AND 1024)
 AND (typeof(doors)='blob' AND length(doors) BETWEEN 0 AND 4096)
 AND (typeof(retirement)='blob' AND length(retirement) BETWEEN 0 AND 8192)
 AND (typeof(owner_close)='blob' AND length(owner_close) BETWEEN 0 AND 8192)
 AND (typeof(reservation)='integer' AND reservation BETWEEN 1 AND 268435456)
 AND (typeof(live)='integer' AND live IN (0,1))
 AND (typeof(generation)='integer' AND generation BETWEEN 1 AND 2147483647)
 AND (typeof(phase)='integer' AND phase BETWEEN 0 AND 6)
 AND (typeof(claimed)='integer' AND claimed IN (0,1))
 AND (typeof(endpoint_incarnation)='blob' AND length(endpoint_incarnation) IN (0,32))
 AND (typeof(ever_published)='integer' AND ever_published IN (0,1))
 AND (typeof(association_digest)='blob' AND length(association_digest) IN (0,32))
 AND (typeof(owner_use)='blob' AND length(owner_use) IN (0,36))
 AND (typeof(claim_incarnation)='blob' AND length(claim_incarnation) IN (0,36))
 AND (typeof(retirement_digest)='blob' AND length(retirement_digest) IN (0,32))
 AND (typeof(owner_close_digest)='blob' AND length(owner_close_digest) IN (0,32))
 THEN 0 ELSE 1 END),0) AS invalid
FROM generation_record;

-- name: GenerationHeaders :many
SELECT key, scope, generation, claimed, ever_published, live, phase, reservation,
 length(association) AS association_size,length(doors) AS doors_size,
 length(retirement) AS retirement_size,length(owner_close) AS owner_close_size,
 association_digest,owner_use,claim_incarnation,endpoint_incarnation,retirement_digest,owner_close_digest
FROM generation_record ORDER BY key LIMIT ?;

-- name: GenerationBody :many
SELECT association,doors,retirement,owner_close FROM generation_record
WHERE key=? AND length(association)<=1024 AND length(doors)<=4096 AND length(retirement)<=8192 AND length(owner_close)<=8192 LIMIT 2;

-- name: InsertGenerationClaim :exec
INSERT INTO generation_record(key,scope,generation,association,association_digest,owner_use,doors,claim_incarnation,claimed,endpoint_incarnation,ever_published,live,phase,reservation,retirement,retirement_digest,owner_close,owner_close_digest)
VALUES(?,?,?,?,?,?,?,?,1,X'',0,1,0,?,X'',X'',X'',X'');

-- name: InsertGenerationNeverStarted :exec
INSERT INTO generation_record(key,scope,generation,association,association_digest,owner_use,doors,claim_incarnation,claimed,endpoint_incarnation,ever_published,live,phase,reservation,retirement,retirement_digest,owner_close,owner_close_digest)
VALUES(?,?,?,X'',X'',X'',X'',X'',0,X'',0,0,4,?,?,?,X'',X'');

-- name: PublishGenerationIntent :many
UPDATE generation_record SET phase=1,ever_published=1,endpoint_incarnation=? WHERE key=? AND phase=0 AND claim_incarnation=? RETURNING phase;

-- name: CompleteGenerationPublication :many
UPDATE generation_record SET phase=2 WHERE key=? AND phase=1 AND claim_incarnation=? RETURNING phase;

-- name: CloseGenerationFence :many
UPDATE generation_record SET phase=3 WHERE key=? AND phase IN (0,1,2) RETURNING phase;

-- name: RetireGeneration :many
UPDATE generation_record SET phase=4,retirement=?,retirement_digest=? WHERE key=? AND phase=3 AND claim_incarnation=? RETURNING phase;

-- name: RemoveGeneration :many
UPDATE generation_record SET phase=5,live=0 WHERE key=? AND phase=4 AND retirement_digest=? RETURNING phase;

-- name: RetainGenerationOwnerClose :many
UPDATE generation_record SET owner_close=?,owner_close_digest=? WHERE key=? AND phase IN (4,5) AND length(owner_close)=0 AND retirement_digest=? RETURNING phase;

-- name: RecoverGenerationUncertainty :exec
UPDATE generation_record SET phase=6 WHERE claimed=1 AND phase IN (0,1,2,3) AND claim_incarnation<>?;

-- Scalar plan integrity precedes every body read, including orphan detection.
-- name: GenerationPlanInventory :many
SELECT COUNT(*) AS "rows",
 COALESCE(SUM(CASE WHEN typeof(p.key)='blob' AND length(p.key) BETWEEN 1 AND 1024
 AND typeof(p.header)='blob' AND length(p.header) BETWEEN 1 AND 262144
 AND typeof(p.enrollment)='blob' AND length(p.enrollment) BETWEEN 1 AND 262144
 AND typeof(p.digest)='blob' AND length(p.digest)=32
 AND r.claimed=1 THEN 0 ELSE 1 END),0) AS invalid
FROM generation_scope_plan p LEFT JOIN generation_record r ON r.key=p.key;

-- Every parent accounts its exact immutable child plus the reserved base.
-- name: GenerationPlanCharges :many
SELECT COALESCE(SUM(CASE WHEN r.reservation=length(r.key)*2+1024+4096+36*2+32*4+8192*2
 +COALESCE(length(p.header)+length(p.enrollment)+32,0) THEN 0 ELSE 1 END),0) AS invalid
FROM generation_record r LEFT JOIN generation_scope_plan p ON r.key=p.key;

-- name: GenerationPlanHeader :many
SELECT length(header) AS header_size,length(enrollment) AS enrollment_size,digest
FROM generation_scope_plan WHERE key=? LIMIT 2;

-- name: GenerationPlanBody :many
SELECT header,enrollment FROM generation_scope_plan
WHERE key=? AND typeof(header)='blob' AND length(header) BETWEEN 1 AND 262144
 AND typeof(enrollment)='blob' AND length(enrollment) BETWEEN 1 AND 262144
 AND typeof(digest)='blob' AND length(digest)=32 LIMIT 2;

-- name: InsertGenerationScopePlan :exec
INSERT INTO generation_scope_plan(key,header,enrollment,digest) VALUES(?,?,?,?);
