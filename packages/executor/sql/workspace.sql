-- Whole semantic workspace custody. Logical reservation is not a disk/WAL bound.
CREATE TABLE workspace_meta (
  id INTEGER PRIMARY KEY CHECK(id = 1),
  format INTEGER NOT NULL CHECK(format = 1),
  binding BLOB NOT NULL CHECK(length(binding) <= 303),
  row_limit INTEGER NOT NULL CHECK(row_limit BETWEEN 1 AND 4096),
  byte_limit INTEGER NOT NULL CHECK(byte_limit BETWEEN 1 AND 268435456)
);
CREATE TABLE workspace_call (
  id BLOB PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  request_digest BLOB NOT NULL CHECK(length(request_digest) = 32),
  request_size INTEGER NOT NULL CHECK(request_size BETWEEN 1 AND 9437184),
  phase INTEGER NOT NULL CHECK(phase BETWEEN 0 AND 4),
  request BLOB NOT NULL CHECK(length(request) <= 9437184),
  result_digest BLOB NOT NULL CHECK(length(result_digest) IN (0, 32)),
  result_size INTEGER NOT NULL CHECK(result_size BETWEEN 0 AND 33554432),
  result BLOB NOT NULL CHECK(length(result) <= 33554432)
);
