-- Catalogue v10: the model key a session was created with, empty for none.
ALTER TABLE catalogue_sessions ADD COLUMN model TEXT NOT NULL DEFAULT ''
  CHECK(length(CAST(model AS BLOB)) <= 64);
