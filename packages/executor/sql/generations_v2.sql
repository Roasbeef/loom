-- Upgrade only checked version-1 custody; original rows are never backfilled.
CREATE TABLE generation_meta_v2 (
 id INTEGER PRIMARY KEY CHECK(id=1),
 format INTEGER NOT NULL CHECK(format=2),
 live_limit INTEGER NOT NULL CHECK(live_limit BETWEEN 1 AND 16),
 row_limit INTEGER NOT NULL CHECK(row_limit BETWEEN 1 AND 4096),
 byte_limit INTEGER NOT NULL CHECK(byte_limit BETWEEN 1 AND 268435456)
);
INSERT INTO generation_meta_v2(id,format,live_limit,row_limit,byte_limit)
 SELECT id,2,live_limit,row_limit,byte_limit FROM generation_meta;
DROP TABLE generation_meta;
ALTER TABLE generation_meta_v2 RENAME TO generation_meta;
CREATE TABLE generation_scope_plan (
 key BLOB PRIMARY KEY NOT NULL REFERENCES generation_record(key),
 header BLOB NOT NULL CHECK(length(header) BETWEEN 1 AND 262144),
 enrollment BLOB NOT NULL CHECK(length(enrollment) BETWEEN 1 AND 262144),
 digest BLOB NOT NULL CHECK(length(digest)=32)
);
