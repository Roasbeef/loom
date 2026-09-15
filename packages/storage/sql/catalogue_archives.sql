-- Catalogue v3: archive visibility is independent of initialization state.
CREATE TABLE catalogue_session_archives(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id)
);
