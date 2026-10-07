-- Catalogue v9: the model profile a session was created with, empty for none.
ALTER TABLE catalogue_sessions ADD COLUMN profile TEXT NOT NULL DEFAULT ''
  CHECK(length(CAST(profile AS BLOB)) <= 64);
