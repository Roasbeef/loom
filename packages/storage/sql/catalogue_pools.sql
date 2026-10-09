-- Catalogue v12: the executor pool a session was created in, empty for a session
-- that named no pool.
ALTER TABLE catalogue_sessions ADD COLUMN pool TEXT NOT NULL DEFAULT ''
  CHECK(length(CAST(pool AS BLOB)) <= 64);
