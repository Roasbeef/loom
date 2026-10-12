-- Catalogue v15: the delegate sessions a remote orchestrator's subagents run in
-- (protocol-change/084). One row names the session this daemon created for one
-- (spawner, parent session) pair on the first subagent spawn from that parent.
-- The spawner is the key of a [spawners.<name>] table, and the parent session is
-- the spawning orchestrator's own session identity. A session with a row here is
-- a delegate session: it serves its spawner and is never moved. The contact time
-- is the last message from the spawner, in Unix milliseconds.
CREATE TABLE catalogue_delegate_sessions(
  spawner TEXT NOT NULL CHECK(length(CAST(spawner AS BLOB)) BETWEEN 1 AND 32),
  parent_session TEXT NOT NULL CHECK(length(CAST(parent_session AS BLOB)) BETWEEN 1 AND 64),
  session_id TEXT NOT NULL UNIQUE REFERENCES catalogue_sessions(session_id),
  last_contact_ms INTEGER NOT NULL CHECK(last_contact_ms >= 0),
  PRIMARY KEY (spawner, parent_session)
);
