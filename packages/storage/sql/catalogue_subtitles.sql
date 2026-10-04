-- Catalogue v5: a session's subtitle is written once and never replaced.
CREATE TABLE catalogue_session_subtitles(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  subtitle TEXT NOT NULL CHECK(length(subtitle) BETWEEN 1 AND 60)
);
