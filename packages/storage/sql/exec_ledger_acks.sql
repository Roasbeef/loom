-- The executor ledger's third schema version (protocol-change/078, addendum:
-- the P model of remote execution). Acknowledging a call used to delete its
-- row, and a Run for the same key that was still in flight, from a runtime that
-- restarted inside one open and so holds the same attach token, found no row
-- and started the call again. An acknowledgement now leaves a tombstone here.
--
-- One row per acknowledged key, with the incarnation it was acknowledged
-- under. A key with a row here is never admitted again in that incarnation. The
-- rows of a session go when its scope reopens at a new incarnation, which
-- refuses every request from the old one by itself, and when it closes with
-- every child retired. A tombstone holds no outcome and no reserved bytes, so
-- it is not counted against the ledger's byte budget.
CREATE TABLE call_ack(
  session TEXT NOT NULL,
  op TEXT NOT NULL,
  step TEXT NOT NULL,
  source_index INTEGER NOT NULL CHECK(source_index >= 0),
  incarnation INTEGER NOT NULL CHECK(incarnation >= 0),
  PRIMARY KEY(session, op, step, source_index)
);
