-- Catalogue v16: the release of a delegate session (protocol-change/084,
-- phase 2). Two changes, one per side of the wire.
--
-- A delegate session gains a state. A session is open until its spawner tells
-- this daemon that the parent session was deleted. The message stops the
-- session's children and marks the row releasing. The registry marks it released
-- once the session's slot has drained, and deletes the session and the row
-- together, so a row left in the released state is a deletion that failed and
-- the retention sweep removes it.
ALTER TABLE catalogue_delegate_sessions
  ADD COLUMN state TEXT NOT NULL DEFAULT 'open'
  CHECK(state IN ('open', 'releasing', 'released'));

-- The other side. A parent session that is deleted on the spawning orchestrator
-- leaves one row for each orchestrator that may hold children for it, written
-- before the session goes. The row is the durable promise to send that
-- orchestrator a Release, and it is deleted only when the orchestrator answers.
-- It names no registration: the session it concerns is gone by design.
CREATE TABLE catalogue_remote_releases(
  parent_session TEXT NOT NULL CHECK(length(CAST(parent_session AS BLOB)) BETWEEN 1 AND 64),
  orchestrator TEXT NOT NULL CHECK(length(CAST(orchestrator AS BLOB)) BETWEEN 1 AND 32),
  written_ms INTEGER NOT NULL CHECK(written_ms >= 0),
  PRIMARY KEY (parent_session, orchestrator)
);
