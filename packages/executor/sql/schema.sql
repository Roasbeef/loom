-- Executor custody history. This is the runtime and sqlc schema source.
CREATE TABLE custody_meta (
  id INTEGER PRIMARY KEY CHECK(id = 1),
  binding BLOB NOT NULL,
  capacity INTEGER NOT NULL,
  version INTEGER NOT NULL CHECK(version >= 0 AND version <= capacity * 6 + 1),
  bytes INTEGER NOT NULL CHECK(bytes >= 0 AND bytes <= version * 138)
);

CREATE TABLE custody_event (
  seq INTEGER PRIMARY KEY,
  payload BLOB NOT NULL
);


-- Immutable native request/output/terminal custody. Slots never evict keys.
CREATE TABLE custody_payload (
  request BLOB NOT NULL CHECK(length(request) <= 138),
  digest BLOB NOT NULL CHECK(length(digest) = 32),
  kind INTEGER NOT NULL CHECK(kind BETWEEN 0 AND 4),
  ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 63),
  body BLOB NOT NULL CHECK(length(body) <= 131072),
  PRIMARY KEY (request, kind, ordinal)
);
