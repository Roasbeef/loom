-- Catalogue v12: where a session is going to or came from. A session with no
-- row is served by this catalogue and has never moved. A row is 'moving' while
-- this side hands the session to the peer, 'moved' once it has (a tombstone with
-- no way out), or 'imported' on the side that received it. The op identifies one
-- move end to end, so a repeated step of the same op is recognized.
CREATE TABLE catalogue_session_moves(
  session_id TEXT NOT NULL PRIMARY KEY REFERENCES catalogue_sessions(session_id),
  op TEXT NOT NULL CHECK(length(CAST(op AS BLOB)) BETWEEN 1 AND 64),
  peer TEXT NOT NULL CHECK(length(CAST(peer AS BLOB)) BETWEEN 1 AND 64),
  state TEXT NOT NULL CHECK(state IN ('moving', 'moved', 'imported'))
);
