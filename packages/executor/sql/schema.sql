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
