-- Catalogue v11: the executor a session's workspace is registered on, empty for
-- a session whose workspace is a path on this host.
ALTER TABLE catalogue_sessions ADD COLUMN executor TEXT NOT NULL DEFAULT ''
  CHECK(length(CAST(executor AS BLOB)) <= 64);
