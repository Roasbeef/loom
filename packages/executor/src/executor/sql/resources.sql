-- Named preparation queries preserve evidence without granting live resource custody.
-- name: InitializeResources :exec
INSERT INTO resource_meta(id,format,mode,enrollment,row_limit,byte_limit)
VALUES(1,2,0,?,?,?);

-- A format-only scalar guard is compatible with the previous column layout.
-- name: ResourceFormat :many
SELECT CAST(CASE WHEN typeof(format)='integer' AND format BETWEEN 1 AND 2
                 THEN format ELSE NULL END AS INTEGER) AS format
FROM resource_meta WHERE id=1 LIMIT 2;

-- The enrollment is bounded before the driver materializes its full snapshot.
-- name: ResourceMetadata :many
SELECT CAST(CASE WHEN typeof(id)='integer' AND id=1 AND typeof(format)='integer' AND format=2
                 AND typeof(enrollment)='blob' AND length(enrollment) BETWEEN 1 AND 262144
                 THEN enrollment ELSE NULL END AS BLOB) AS enrollment,
       CAST(CASE WHEN typeof(mode)='integer' AND mode IN (0,1) THEN mode ELSE NULL END AS INTEGER) AS mode,
       CAST(CASE WHEN typeof(row_limit)='integer' AND row_limit BETWEEN 1 AND 65536 THEN row_limit ELSE NULL END AS INTEGER) AS row_limit,
       CAST(CASE WHEN typeof(byte_limit)='integer' AND byte_limit>0 THEN byte_limit ELSE NULL END AS INTEGER) AS byte_limit
FROM resource_meta LIMIT 2;

-- Header scanning exposes scalar sizes, never large addresses, keys or source bodies.
-- name: ResourceHeaders :many
SELECT CAST(CASE WHEN typeof(id)='blob' AND length(id)=36 THEN id ELSE NULL END AS BLOB) AS id,
       CAST(CASE WHEN typeof(address)='blob' AND length(address) BETWEEN 1 AND 8192 THEN length(address) ELSE NULL END AS INTEGER) AS address_size,
       CAST(CASE WHEN typeof(service_header)='blob' AND length(service_header) BETWEEN 1 AND 8192 THEN length(service_header) ELSE NULL END AS INTEGER) AS header_size,
       CAST(CASE WHEN typeof(role)='integer' AND role IN (0,1) THEN role ELSE NULL END AS INTEGER) AS role,
       CAST(CASE WHEN typeof(input_digest)='blob' AND length(input_digest)=32 THEN input_digest ELSE NULL END AS BLOB) AS input_digest,
       CAST(CASE WHEN typeof(input_size)='integer' AND input_size BETWEEN 1 AND 9437184 THEN input_size ELSE NULL END AS INTEGER) AS input_size,
       CAST(CASE WHEN typeof(phase)='integer' AND phase BETWEEN 0 AND 4 THEN phase ELSE NULL END AS INTEGER) AS phase,
       CAST(CASE WHEN typeof(ready_digest)='blob' AND length(ready_digest) IN (0,32) THEN ready_digest ELSE NULL END AS BLOB) AS ready_digest,
       CAST(CASE WHEN typeof(ready_size)='integer' AND ready_size BETWEEN 0 AND 262144 THEN ready_size ELSE NULL END AS INTEGER) AS ready_size,
       CAST(CASE WHEN native_id IS NULL THEN X'' WHEN typeof(native_id)='blob' AND length(native_id)=36 THEN native_id ELSE NULL END AS BLOB) AS native_id,
       CAST(CASE WHEN typeof(command_ref)='blob' AND length(command_ref)<=8192 THEN length(command_ref) ELSE NULL END AS INTEGER) AS ref_size,
       CAST(CASE WHEN typeof(native_identity)='blob' AND length(native_identity) IN (0,106) THEN length(native_identity) ELSE NULL END AS INTEGER) AS identity_size,
       CAST(CASE WHEN typeof(native_prepared)='blob' AND length(native_prepared)<=131072 THEN length(native_prepared) ELSE NULL END AS INTEGER) AS prepared_size,
       CAST(CASE WHEN typeof(completion)='blob' AND length(completion)<=262144 THEN length(completion) ELSE NULL END AS INTEGER) AS completion_size,
       CAST(CASE WHEN typeof(completion_digest)='blob' AND length(completion_digest) IN (0,32) THEN completion_digest ELSE NULL END AS BLOB) AS completion_digest,
       CAST(CASE WHEN typeof(outer_receipt)='integer' AND outer_receipt IN (0,1) THEN outer_receipt ELSE NULL END AS INTEGER) AS outer_receipt,
       CAST(CASE WHEN typeof(input)='blob' AND length(input)=input_size
                 AND typeof(ready)='blob' AND length(ready)=ready_size
                 AND ((ready_size=0 AND length(ready_digest)=0 AND phase IN (0,1,3,4))
                   OR (ready_size>0 AND length(ready_digest)=32 AND phase IN (2,3,4)))
                 AND ((native_id IS NULL AND length(command_ref)=0 AND length(native_identity)=0 AND length(native_prepared)=0)
                   OR (native_id IS NOT NULL AND length(command_ref)>0 AND length(native_identity)=106 AND length(native_prepared)>0 AND ready_size>0))
                 AND ((length(completion)=0 AND length(completion_digest)=0 AND outer_receipt=0)
                   OR (length(completion)>0 AND length(completion_digest)=32 AND (native_id IS NOT NULL OR (ready_size=0 AND phase IN (3,4)))))
                 THEN 1 ELSE 0 END AS INTEGER) AS valid
FROM resource_call ORDER BY id LIMIT ?;

-- The journal reads one checked row after validating count and aggregate reservation.
-- name: ResourceBodies :many
SELECT CAST(CASE WHEN typeof(address)='blob' AND length(address) BETWEEN 1 AND 8192 THEN address ELSE NULL END AS BLOB) AS address,
       CAST(CASE WHEN typeof(service_header)='blob' AND length(service_header) BETWEEN 1 AND 8192 THEN service_header ELSE NULL END AS BLOB) AS service_header,
       CAST(CASE WHEN typeof(input)='blob' AND length(input) BETWEEN 1 AND 9437184 THEN input ELSE NULL END AS BLOB) AS input,
       CAST(CASE WHEN typeof(ready)='blob' AND length(ready)<=262144 THEN ready ELSE NULL END AS BLOB) AS ready,
       CAST(CASE WHEN typeof(command_ref)='blob' AND length(command_ref)<=8192 THEN command_ref ELSE NULL END AS BLOB) AS command_ref,
       CAST(CASE WHEN typeof(native_identity)='blob' AND length(native_identity) IN (0,106) THEN native_identity ELSE NULL END AS BLOB) AS native_identity,
       CAST(CASE WHEN typeof(native_prepared)='blob' AND length(native_prepared)<=131072 THEN native_prepared ELSE NULL END AS BLOB) AS native_prepared,
       CAST(CASE WHEN typeof(completion)='blob' AND length(completion)<=262144 THEN completion ELSE NULL END AS BLOB) AS completion
FROM resource_call WHERE id=? LIMIT 2;

-- name: InsertResource :many
INSERT INTO resource_call(id,address,service_header,role,input_digest,input_size,input,phase,ready_digest,ready_size,ready)
VALUES(?,?,?,?,?,?,?,0,X'',0,X'') RETURNING id;

-- Only an open Reserved row can transfer the first preparation claim.
-- name: ClaimResource :many
UPDATE resource_call SET phase=1 WHERE resource_call.id=? AND resource_call.phase=0
AND EXISTS(SELECT 1 FROM resource_meta WHERE resource_meta.id=1 AND resource_meta.mode=0) RETURNING phase;

-- name: CommitResourceReady :many
UPDATE resource_call SET phase=2,ready_digest=?,ready_size=?,ready=?
WHERE id=? AND phase=1 RETURNING phase;

-- Unknown and released states retain any original issued Ready bytes.
-- name: MarkResourceUnknown :many
UPDATE resource_call SET phase=3 WHERE id=? AND phase IN (1,2) RETURNING phase;

-- Original cancellation also fences an unclaimed reservation without fabricating a claim.
-- name: FenceResourcePreparation :many
UPDATE resource_call SET phase=3 WHERE id=? AND phase IN (0,1,2) RETURNING phase;

-- name: ReleaseResource :many
UPDATE resource_call SET phase=4 WHERE id=? AND phase IN (1,2,3) RETURNING phase;

-- name: SealResources :many
UPDATE resource_meta SET mode=1 WHERE id=1 RETURNING mode;

-- Separate address lookup keeps changed immutable evidence at its original fence.
-- name: ResourceAddress :many
SELECT CAST(CASE WHEN typeof(id)='blob' AND length(id)=36 THEN id ELSE NULL END AS BLOB) AS id
FROM resource_call WHERE address=? LIMIT 2;

-- name: AssociateResourceNative :many
UPDATE resource_call SET command_ref=?,native_id=?,native_identity=?,native_prepared=?
WHERE id=? AND native_id IS NULL AND ready_size>0 AND length(completion)=0 RETURNING native_id;

-- name: ResourceNativeOwner :many
SELECT CAST(CASE WHEN typeof(id)='blob' AND length(id)=36 THEN id ELSE NULL END AS BLOB) AS id
FROM resource_call WHERE native_id=? LIMIT 2;

-- name: CommitResourceCompile :many
UPDATE resource_call SET completion_digest=?,completion=?
WHERE id=? AND native_id IS NOT NULL AND length(completion)=0 RETURNING completion_digest;

-- name: FailResourcePreparation :many
UPDATE resource_call SET phase=3,completion_digest=?,completion=?
WHERE id=? AND phase=1 AND ready_size=0 AND native_id IS NULL AND length(completion)=0 RETURNING completion_digest;

-- name: AcknowledgeResourceCompile :many
UPDATE resource_call SET outer_receipt=1
WHERE id=? AND completion_digest=? AND length(completion)>0 AND outer_receipt=0 RETURNING outer_receipt;
