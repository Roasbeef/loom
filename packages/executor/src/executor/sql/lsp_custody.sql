-- ASCII-only executor LSP SQL. Every mutation names one original row.

-- name: InitializeLsp :exec
INSERT INTO lsp_meta(id,format,scope,contract,row_limit,byte_limit,sealed) VALUES(1,1,?,?,?,?,0);

-- name: LspMetadata :many
SELECT format,scope,contract,row_limit,byte_limit,sealed FROM lsp_meta WHERE id=1 AND typeof(format)='integer' AND format=1 AND typeof(scope)='blob' AND length(scope) BETWEEN 1 AND 1024 AND typeof(contract)='blob' AND length(contract)=32 AND typeof(row_limit)='integer' AND row_limit BETWEEN 1 AND 4096 AND typeof(byte_limit)='integer' AND byte_limit BETWEEN 1 AND 268435456 AND typeof(sealed)='integer' AND sealed IN (0,1) LIMIT 2;

-- name: LspLedger :many
SELECT COUNT(*) AS count,COALESCE(SUM(reserved_bytes),0) AS bytes,COALESCE(SUM(CASE WHEN typeof(address)='text' AND length(CAST(address AS BLOB)) BETWEEN 1 AND 32768 AND typeof(kind)='integer' AND kind BETWEEN 0 AND 2 AND typeof(reserved_bytes)='integer' AND reserved_bytes BETWEEN 1 AND 268435456 THEN 0 ELSE 1 END),0) AS invalid FROM lsp_identity;

-- name: LspInsertIdentity :exec
INSERT INTO lsp_identity(address,kind,reserved_bytes) VALUES(?,?,?);

-- name: LspSeal :exec
UPDATE lsp_meta SET sealed=1 WHERE id=1;

-- name: LspSlots :many
SELECT CAST(CASE WHEN typeof(slot)='text' AND length(CAST(slot AS BLOB)) BETWEEN 1 AND 32768 THEN slot ELSE '' END AS TEXT) AS slot,CAST(CASE WHEN typeof(address)='text' AND length(CAST(address AS BLOB)) BETWEEN 1 AND 32768 THEN address ELSE '' END AS TEXT) AS address,CASE WHEN (typeof(slot)='text' AND length(CAST(slot AS BLOB)) BETWEEN 1 AND 32768) AND (typeof(address)='text' AND length(CAST(address AS BLOB)) BETWEEN 1 AND 32768) THEN 0 ELSE 1 END AS invalid FROM lsp_current_slot LIMIT 4097;

-- name: LspInsertSlot :exec
INSERT INTO lsp_current_slot(slot,address) VALUES(?,?);

-- name: LspRemoveSlot :many
DELETE FROM lsp_current_slot WHERE slot=? AND address=? RETURNING address;

-- name: LspHeaders :many
SELECT CAST(CASE WHEN typeof(address)='text' AND length(CAST(address AS BLOB)) BETWEEN 1 AND 32768 THEN address ELSE '' END AS TEXT) AS address,kind,CAST(CASE WHEN typeof(phase)='integer' AND phase BETWEEN 0 AND 8 THEN phase ELSE -1 END AS INTEGER) AS phase,CAST(CASE WHEN typeof(reserved_bytes)='integer' AND reserved_bytes BETWEEN 1 AND 268435456 THEN reserved_bytes ELSE 0 END AS INTEGER) AS reserved_bytes,length(identity) AS identity_size,length(input) AS input_size,length(generation_key) AS generation_key_size,length(enrollment_digest) AS enrollment_digest_size,length(parent) AS parent_size,length(anchor) AS anchor_size,length(timing_proposal) AS timing_proposal_size,length(timing_digest) AS timing_digest_size,length(offer) AS offer_size,length(native_identity) AS native_identity_size,length(native_prepared) AS native_prepared_size,length(terminal) AS terminal_size,length(reusable_witness) AS reusable_witness_size,length(projected_result) AS projected_result_size,length(receipt) AS receipt_size,length(retirement) AS retirement_size,CASE WHEN (typeof(identity)='blob' AND length(identity)<= 8192) AND (typeof(input)='blob' AND length(input)<= 131072) AND (typeof(generation_key)='blob' AND length(generation_key)<= 1024) AND (typeof(enrollment_digest)='blob' AND length(enrollment_digest)<= 32) AND (typeof(parent)='blob' AND length(parent)<= 8192) AND (typeof(anchor)='blob' AND length(anchor)<= 8192) AND (typeof(timing_proposal)='blob' AND length(timing_proposal)<= 8192) AND (typeof(timing_digest)='blob' AND length(timing_digest)<= 32) AND (typeof(offer)='blob' AND length(offer)<= 131072) AND (typeof(native_identity)='blob' AND length(native_identity)<= 8192) AND (typeof(native_prepared)='blob' AND length(native_prepared)<= 131072) AND (typeof(terminal)='blob' AND length(terminal)<= 32768) AND (typeof(reusable_witness)='blob' AND length(reusable_witness)<= 8192) AND (typeof(projected_result)='blob' AND length(projected_result)<= 4464896) AND (typeof(receipt)='blob' AND length(receipt)<= 32) AND (typeof(retirement)='blob' AND length(retirement)<= 8192) AND (typeof(phase)='integer' AND phase BETWEEN 0 AND 8) AND (typeof(reserved_bytes)='integer' AND reserved_bytes BETWEEN 1 AND 268435456) AND (typeof(address)='text' AND length(CAST(address AS BLOB)) BETWEEN 1 AND 32768) AND (typeof(slot)='text' AND length(CAST(slot AS BLOB))<=32768) AND (typeof(parent_address)='text' AND length(CAST(parent_address AS BLOB))<=32768) AND (typeof(search_root)='text' AND length(CAST(search_root AS BLOB))<=8192) AND (typeof(clock_era)='text' AND length(clock_era) IN (0,36)) AND (typeof(parent_kind)='integer' AND parent_kind BETWEEN -1 AND 1) AND (typeof(startup_role)='integer' AND startup_role BETWEEN -1 AND 2) AND (typeof(search_profile_ordinal)='integer' AND search_profile_ordinal BETWEEN -1 AND 15) AND (typeof(anchor_tick)='integer') AND (typeof(remaining_ms)='integer' AND remaining_ms BETWEEN 0 AND 86400000) AND (typeof(deadline_tick)='integer') THEN 0 ELSE 1 END AS invalid FROM lsp_rows LIMIT 4097;

-- name: LspRead :many
SELECT address,kind,slot,parent_kind,parent_address,CAST(parent AS BLOB) AS parent,startup_role,search_profile_ordinal,search_root,CAST(anchor AS BLOB) AS anchor,anchor_tick,clock_era,CAST(timing_proposal AS BLOB) AS timing_proposal,CAST(timing_digest AS BLOB) AS timing_digest,remaining_ms,deadline_tick,identity,input,generation_key,enrollment_digest,reserved_bytes,phase,offer,native_identity,native_prepared,terminal,reusable_witness,projected_result,receipt,retirement FROM lsp_rows WHERE address=? AND (typeof(identity)='blob' AND length(identity)<= 8192) AND (typeof(input)='blob' AND length(input)<= 131072) AND (typeof(generation_key)='blob' AND length(generation_key)<= 1024) AND (typeof(enrollment_digest)='blob' AND length(enrollment_digest)<= 32) AND (typeof(parent)='blob' AND length(parent)<= 8192) AND (typeof(anchor)='blob' AND length(anchor)<= 8192) AND (typeof(timing_proposal)='blob' AND length(timing_proposal)<= 8192) AND (typeof(timing_digest)='blob' AND length(timing_digest)<= 32) AND (typeof(offer)='blob' AND length(offer)<= 131072) AND (typeof(native_identity)='blob' AND length(native_identity)<= 8192) AND (typeof(native_prepared)='blob' AND length(native_prepared)<= 131072) AND (typeof(terminal)='blob' AND length(terminal)<= 32768) AND (typeof(reusable_witness)='blob' AND length(reusable_witness)<= 8192) AND (typeof(projected_result)='blob' AND length(projected_result)<= 4464896) AND (typeof(receipt)='blob' AND length(receipt)<= 32) AND (typeof(retirement)='blob' AND length(retirement)<= 8192) AND (typeof(phase)='integer' AND phase BETWEEN 0 AND 8) AND (typeof(reserved_bytes)='integer' AND reserved_bytes BETWEEN 1 AND 268435456) AND (typeof(address)='text' AND length(CAST(address AS BLOB)) BETWEEN 1 AND 32768) AND (typeof(slot)='text' AND length(CAST(slot AS BLOB))<=32768) AND (typeof(parent_address)='text' AND length(CAST(parent_address AS BLOB))<=32768) AND (typeof(search_root)='text' AND length(CAST(search_root AS BLOB))<=8192) AND (typeof(clock_era)='text' AND length(clock_era) IN (0,36)) AND (typeof(parent_kind)='integer' AND parent_kind BETWEEN -1 AND 1) AND (typeof(startup_role)='integer' AND startup_role BETWEEN -1 AND 2) AND (typeof(search_profile_ordinal)='integer' AND search_profile_ordinal BETWEEN -1 AND 15) AND (typeof(anchor_tick)='integer') AND (typeof(remaining_ms)='integer' AND remaining_ms BETWEEN 0 AND 86400000) AND (typeof(deadline_tick)='integer') LIMIT 2;

-- name: LspInsertLease :exec
INSERT INTO lsp_lease(address,slot,deadline_tick,clock_era,identity,input,generation_key,enrollment_digest,reserved_bytes,phase) VALUES(?,?,?,?,?,?,?,?,?,?);

-- name: LspUpdateLease :many
UPDATE lsp_lease SET phase=:new_phase,offer=?,native_identity=?,native_prepared=?,terminal=?,reusable_witness=?,projected_result=?,receipt=?,retirement=? WHERE address=? AND phase=:old_phase RETURNING phase;

-- name: LspRecoverLease :exec
UPDATE lsp_lease SET phase=8 WHERE phase NOT IN (6,7,8);

-- name: LspInsertFinite :exec
INSERT INTO lsp_finite(address,anchor,anchor_tick,clock_era,identity,input,generation_key,enrollment_digest,reserved_bytes,phase) VALUES(?,?,?,?,?,?,?,?,?,?);

-- name: LspUpdateFinite :many
UPDATE lsp_finite SET phase=:new_phase,offer=?,native_identity=?,native_prepared=?,terminal=?,reusable_witness=?,projected_result=?,receipt=?,retirement=?,timing_proposal=?,timing_digest=?,remaining_ms=?,deadline_tick=? WHERE address=? AND phase=:old_phase RETURNING phase;

-- name: LspRecoverFinite :exec
UPDATE lsp_finite SET phase=8 WHERE phase NOT IN (6,7,8);

-- name: LspInsertCommand :exec
INSERT INTO lsp_command(address,parent_kind,parent_address,parent,startup_role,search_profile_ordinal,search_root,identity,input,generation_key,enrollment_digest,reserved_bytes,phase) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?);

-- name: LspUpdateCommand :many
UPDATE lsp_command SET phase=:new_phase,offer=?,native_identity=?,native_prepared=?,terminal=?,reusable_witness=?,projected_result=?,receipt=?,retirement=? WHERE address=? AND phase=:old_phase RETURNING phase;

-- name: LspRecoverCommand :exec
UPDATE lsp_command SET phase=8 WHERE phase NOT IN (6,7,8);

-- name: LspInventoryIntegrity :many
SELECT COUNT(*) AS invalid FROM lsp_identity AS i WHERE NOT EXISTS(SELECT 1 FROM lsp_rows AS r WHERE r.address=i.address AND r.kind=i.kind AND r.reserved_bytes=i.reserved_bytes);

-- name: LspLinkedSqlite :many
SELECT sqlite_version() AS version,sqlite_source_id() AS source;
