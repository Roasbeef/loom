-- Catalogue v8: the folders the owner recently started a session in, newest last.
CREATE TABLE catalogue_recent_folders(
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  workspace TEXT NOT NULL UNIQUE
    CHECK(length(CAST(workspace AS BLOB)) BETWEEN 1 AND 4096)
);
