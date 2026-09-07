-- Catalogue v2: display labels do not replace immutable creation metadata.
CREATE TABLE catalogue_session_names(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  name TEXT NOT NULL CHECK(length(CAST(name AS BLOB)) BETWEEN 1 AND 256)
);
