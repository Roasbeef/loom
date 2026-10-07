-- Permanent executor LSP custody. Bodies are canonical and never raw stdout.
CREATE TABLE lsp_meta(id INTEGER PRIMARY KEY CHECK(id=1),format INTEGER NOT NULL CHECK(format=1),scope BLOB NOT NULL CHECK(length(scope) BETWEEN 1 AND 1024),contract BLOB NOT NULL CHECK(length(contract)=32),row_limit INTEGER NOT NULL CHECK(row_limit BETWEEN 1 AND 4096),byte_limit INTEGER NOT NULL CHECK(byte_limit BETWEEN 1 AND 268435456),sealed INTEGER NOT NULL CHECK(sealed IN (0,1)));
CREATE TABLE lsp_identity(address TEXT PRIMARY KEY NOT NULL CHECK(length(CAST(address AS BLOB)) BETWEEN 1 AND 32768),kind INTEGER NOT NULL CHECK(kind BETWEEN 0 AND 2),reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes BETWEEN 1 AND 268435456));
CREATE TABLE lsp_lease(address TEXT PRIMARY KEY NOT NULL REFERENCES lsp_identity(address),slot TEXT NOT NULL CHECK(length(CAST(slot AS BLOB)) BETWEEN 1 AND 32768),deadline_tick INTEGER NOT NULL CHECK(deadline_tick<>0),clock_era TEXT NOT NULL CHECK(length(clock_era)=36),
 identity BLOB NOT NULL CHECK(length(identity) BETWEEN 1 AND 8192),
 input BLOB NOT NULL CHECK(length(input) BETWEEN 1 AND 131072),
 generation_key BLOB NOT NULL CHECK(length(generation_key) BETWEEN 1 AND 1024),
 enrollment_digest BLOB NOT NULL CHECK(length(enrollment_digest)=32),
 reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes BETWEEN 1 AND 268435456),
 phase INTEGER NOT NULL CHECK(phase BETWEEN 0 AND 8),
 offer BLOB NOT NULL DEFAULT X'' CHECK(length(offer)<=131072),
 native_identity BLOB NOT NULL DEFAULT X'' CHECK(length(native_identity)<=8192),
 native_prepared BLOB NOT NULL DEFAULT X'' CHECK(length(native_prepared)<=131072),
 terminal BLOB NOT NULL DEFAULT X'' CHECK(length(terminal)<=32768),
 reusable_witness BLOB NOT NULL DEFAULT X'' CHECK(length(reusable_witness)<=8192),
 projected_result BLOB NOT NULL DEFAULT X'' CHECK(length(projected_result)<=4464896),
 receipt BLOB NOT NULL DEFAULT X'' CHECK(length(receipt) IN (0,32)),
 retirement BLOB NOT NULL DEFAULT X'' CHECK(length(retirement)<=8192)
);
CREATE TABLE lsp_finite(address TEXT PRIMARY KEY NOT NULL REFERENCES lsp_identity(address),anchor BLOB NOT NULL CHECK(length(anchor) BETWEEN 1 AND 8192),anchor_tick INTEGER NOT NULL,clock_era TEXT NOT NULL CHECK(length(clock_era)=36),timing_proposal BLOB NOT NULL DEFAULT X'' CHECK(length(timing_proposal)<=8192),timing_digest BLOB NOT NULL DEFAULT X'' CHECK(length(timing_digest) IN (0,32)),remaining_ms INTEGER NOT NULL DEFAULT 0 CHECK(remaining_ms BETWEEN 0 AND 86400000),deadline_tick INTEGER NOT NULL DEFAULT 0,
 identity BLOB NOT NULL CHECK(length(identity) BETWEEN 1 AND 8192),
 input BLOB NOT NULL CHECK(length(input) BETWEEN 1 AND 131072),
 generation_key BLOB NOT NULL CHECK(length(generation_key) BETWEEN 1 AND 1024),
 enrollment_digest BLOB NOT NULL CHECK(length(enrollment_digest)=32),
 reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes BETWEEN 1 AND 268435456),
 phase INTEGER NOT NULL CHECK(phase BETWEEN 0 AND 8),
 offer BLOB NOT NULL DEFAULT X'' CHECK(length(offer)<=131072),
 native_identity BLOB NOT NULL DEFAULT X'' CHECK(length(native_identity)<=8192),
 native_prepared BLOB NOT NULL DEFAULT X'' CHECK(length(native_prepared)<=131072),
 terminal BLOB NOT NULL DEFAULT X'' CHECK(length(terminal)<=32768),
 reusable_witness BLOB NOT NULL DEFAULT X'' CHECK(length(reusable_witness)<=8192),
 projected_result BLOB NOT NULL DEFAULT X'' CHECK(length(projected_result)<=4464896),
 receipt BLOB NOT NULL DEFAULT X'' CHECK(length(receipt) IN (0,32)),
 retirement BLOB NOT NULL DEFAULT X'' CHECK(length(retirement)<=8192)
);
CREATE TABLE lsp_command(address TEXT PRIMARY KEY NOT NULL REFERENCES lsp_identity(address),parent_kind INTEGER NOT NULL CHECK(parent_kind IN (0,1)),parent_address TEXT NOT NULL CHECK(length(CAST(parent_address AS BLOB)) BETWEEN 1 AND 32768),parent BLOB NOT NULL CHECK(length(parent) BETWEEN 1 AND 8192),startup_role INTEGER NOT NULL CHECK(startup_role BETWEEN -1 AND 2),search_profile_ordinal INTEGER NOT NULL CHECK(search_profile_ordinal BETWEEN -1 AND 15),search_root TEXT NOT NULL CHECK(length(CAST(search_root AS BLOB))<=8192),
 identity BLOB NOT NULL CHECK(length(identity) BETWEEN 1 AND 8192),
 input BLOB NOT NULL CHECK(length(input) BETWEEN 1 AND 131072),
 generation_key BLOB NOT NULL CHECK(length(generation_key) BETWEEN 1 AND 1024),
 enrollment_digest BLOB NOT NULL CHECK(length(enrollment_digest)=32),
 reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes BETWEEN 1 AND 268435456),
 phase INTEGER NOT NULL CHECK(phase BETWEEN 0 AND 8),
 offer BLOB NOT NULL DEFAULT X'' CHECK(length(offer)<=131072),
 native_identity BLOB NOT NULL DEFAULT X'' CHECK(length(native_identity)<=8192),
 native_prepared BLOB NOT NULL DEFAULT X'' CHECK(length(native_prepared)<=131072),
 terminal BLOB NOT NULL DEFAULT X'' CHECK(length(terminal)<=32768),
 reusable_witness BLOB NOT NULL DEFAULT X'' CHECK(length(reusable_witness)<=8192),
 projected_result BLOB NOT NULL DEFAULT X'' CHECK(length(projected_result)<=4464896),
 receipt BLOB NOT NULL DEFAULT X'' CHECK(length(receipt) IN (0,32)),
 retirement BLOB NOT NULL DEFAULT X'' CHECK(length(retirement)<=8192)
);
CREATE TABLE lsp_current_slot(slot TEXT PRIMARY KEY NOT NULL,address TEXT UNIQUE NOT NULL REFERENCES lsp_lease(address));
CREATE VIEW lsp_rows AS SELECT address,0 AS kind,slot,-1 AS parent_kind,'' AS parent_address,X'' AS parent,-1 AS startup_role,-1 AS search_profile_ordinal,'' AS search_root,X'' AS anchor,0 AS anchor_tick,clock_era,X'' AS timing_proposal,X'' AS timing_digest,0 AS remaining_ms,deadline_tick,identity,input,generation_key,enrollment_digest,reserved_bytes,phase,offer,native_identity,native_prepared,terminal,reusable_witness,projected_result,receipt,retirement FROM lsp_lease UNION ALL SELECT address,1 AS kind,'' AS slot,-1 AS parent_kind,'' AS parent_address,X'' AS parent,-1 AS startup_role,-1 AS search_profile_ordinal,'' AS search_root,anchor,anchor_tick,clock_era,timing_proposal,timing_digest,remaining_ms,deadline_tick,identity,input,generation_key,enrollment_digest,reserved_bytes,phase,offer,native_identity,native_prepared,terminal,reusable_witness,projected_result,receipt,retirement FROM lsp_finite UNION ALL SELECT address,2 AS kind,'' AS slot,parent_kind,parent_address,parent,startup_role,search_profile_ordinal,search_root,X'' AS anchor,0 AS anchor_tick,'' AS clock_era,X'' AS timing_proposal,X'' AS timing_digest,0 AS remaining_ms,0 AS deadline_tick,identity,input,generation_key,enrollment_digest,reserved_bytes,phase,offer,native_identity,native_prepared,terminal,reusable_witness,projected_result,receipt,retirement FROM lsp_command;
CREATE UNIQUE INDEX lsp_one_search_per_profile ON lsp_command(parent_address,search_profile_ordinal) WHERE parent_kind=1;
