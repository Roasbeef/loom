-- Pinned pre-provenance format-1 schema; recovery must never backfill its rows.
-- Permanent generation custody, separate from hot endpoint registrations.
CREATE TABLE generation_meta (
 id INTEGER PRIMARY KEY CHECK(id=1),
 format INTEGER NOT NULL CHECK(format=1),
 live_limit INTEGER NOT NULL CHECK(live_limit BETWEEN 1 AND 16),
 row_limit INTEGER NOT NULL CHECK(row_limit BETWEEN 1 AND 4096),
 byte_limit INTEGER NOT NULL CHECK(byte_limit BETWEEN 1 AND 268435456)
);
CREATE TABLE generation_record (
 key BLOB PRIMARY KEY NOT NULL CHECK(length(key) BETWEEN 1 AND 1024),
 scope BLOB NOT NULL CHECK(length(scope) BETWEEN 1 AND 1024),
 generation INTEGER NOT NULL CHECK(generation BETWEEN 1 AND 2147483647),
 association BLOB NOT NULL CHECK(length(association) BETWEEN 0 AND 1024),
 association_digest BLOB NOT NULL CHECK(length(association_digest) IN (0,32)),
 owner_use BLOB NOT NULL CHECK(length(owner_use) IN (0,36)),
 doors BLOB NOT NULL CHECK(length(doors) BETWEEN 0 AND 4096),
 claim_incarnation BLOB NOT NULL CHECK(length(claim_incarnation) IN (0,36)),
 claimed INTEGER NOT NULL CHECK(claimed IN (0,1)),
 endpoint_incarnation BLOB NOT NULL CHECK(length(endpoint_incarnation) IN (0,32)),
 ever_published INTEGER NOT NULL CHECK(ever_published IN (0,1)),
 live INTEGER NOT NULL CHECK(live IN (0,1)),
 phase INTEGER NOT NULL CHECK(phase BETWEEN 0 AND 6),
 reservation INTEGER NOT NULL CHECK(reservation BETWEEN 1 AND 268435456),
 retirement BLOB NOT NULL CHECK(length(retirement) BETWEEN 0 AND 8192),
 retirement_digest BLOB NOT NULL CHECK(length(retirement_digest) IN (0,32)),
 owner_close BLOB NOT NULL CHECK(length(owner_close) BETWEEN 0 AND 8192),
 owner_close_digest BLOB NOT NULL CHECK(length(owner_close_digest) IN (0,32)),
 CHECK((ever_published=0 AND length(endpoint_incarnation)=0) OR (ever_published=1 AND length(endpoint_incarnation)=32)),
 CHECK((claimed=0 AND live=0 AND ever_published=0 AND length(association)=0 AND length(owner_use)=0 AND length(doors)=0 AND length(claim_incarnation)=0 AND phase IN (4,5)) OR (claimed=1 AND length(association)>0 AND length(association_digest)=32 AND length(owner_use)=36 AND length(doors)>0 AND length(claim_incarnation)=36)),
 CHECK((phase IN (4,5) AND length(retirement)>0 AND length(retirement_digest)=32) OR (phase IN (0,1,2,3,6) AND length(retirement)=0 AND length(retirement_digest)=0)),
 CHECK((length(owner_close)=0 AND length(owner_close_digest)=0) OR (length(owner_close)>0 AND length(owner_close_digest)=32 AND phase IN (4,5))),
 CHECK((claimed=0 OR phase=5) AND live=0 OR claimed=1 AND phase<>5 AND live=1)
);
CREATE UNIQUE INDEX generation_live_scope ON generation_record(scope) WHERE live=1;
CREATE UNIQUE INDEX generation_original_owner ON generation_record(owner_use) WHERE claimed=1;
