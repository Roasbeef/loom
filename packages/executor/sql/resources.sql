-- Exact preparation custody; retained byte limits exclude SQLite page/WAL overhead.
CREATE TABLE resource_meta (
  id INTEGER PRIMARY KEY CHECK(id = 1),
  format INTEGER NOT NULL CHECK(format = 1),
  mode INTEGER NOT NULL CHECK(mode IN (0, 1)),
  enrollment BLOB NOT NULL CHECK(length(enrollment) BETWEEN 1 AND 262144),
  row_limit INTEGER NOT NULL CHECK(row_limit BETWEEN 1 AND 65536),
  byte_limit INTEGER NOT NULL CHECK(byte_limit > 0)
);

-- Address and UUID are independent uniqueness fences; content never chooses either.
CREATE TABLE resource_call (
  id BLOB PRIMARY KEY NOT NULL CHECK(length(id) = 36),
  address BLOB NOT NULL UNIQUE CHECK(length(address) BETWEEN 1 AND 8192),
  service_header BLOB NOT NULL CHECK(length(service_header) BETWEEN 1 AND 8192),
  role INTEGER NOT NULL CHECK(role IN (0, 1)),
  input_digest BLOB NOT NULL CHECK(length(input_digest) = 32),
  input_size INTEGER NOT NULL CHECK(input_size BETWEEN 1 AND 9437184),
  input BLOB NOT NULL CHECK(length(input) = input_size),
  phase INTEGER NOT NULL CHECK(phase BETWEEN 0 AND 4),
  ready_digest BLOB NOT NULL CHECK(length(ready_digest) IN (0, 32)),
  ready_size INTEGER NOT NULL CHECK(ready_size BETWEEN 0 AND 262144),
  ready BLOB NOT NULL CHECK(length(ready) = ready_size),
  CHECK(
    (ready_size = 0 AND length(ready_digest) = 0 AND phase IN (0, 1, 3, 4))
    OR (ready_size > 0 AND length(ready_digest) = 32 AND phase IN (2, 3, 4))
  )
);
