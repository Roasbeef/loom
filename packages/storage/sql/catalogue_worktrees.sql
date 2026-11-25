-- Catalogue v24: a session created in its own Git worktree (protocol-change/133). The row exists only for such a session, and names the commit-ish its branch started from.
CREATE TABLE catalogue_session_worktrees(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  base TEXT NOT NULL CHECK(length(base) BETWEEN 1 AND 255)
);
