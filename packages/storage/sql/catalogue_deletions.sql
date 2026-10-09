-- Catalogue v13: a remote session whose deletion has begun on a daemon that
-- is a member of the session directory (protocol-change/080). The row is
-- written in the registry turn that checks no slot is open, before the
-- directory record is deleted, and admission refuses a session that has one.
-- It is removed with the registration once the record is gone, or on its own
-- when the record turns out to belong to someone else. Its presence is what
-- lets a restarted daemon finish a deletion: an absent record alone never
-- deletes anything.
CREATE TABLE catalogue_session_deletions(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id)
);
