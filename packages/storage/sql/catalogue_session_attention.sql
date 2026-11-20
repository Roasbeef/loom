-- Catalogue v22: a session's attention summary, written on change so Home's counts survive a restart.
CREATE TABLE catalogue_session_attention(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  pending_approvals INTEGER NOT NULL CHECK(pending_approvals >= 0),
  open_asks INTEGER NOT NULL CHECK(open_asks >= 0),
  open_finds INTEGER NOT NULL CHECK(open_finds >= 0),
  oldest_open_at INTEGER,
  updated_at INTEGER NOT NULL
);
