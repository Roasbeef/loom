-- The executor's execution ledger: one SQLite file per executor, rows keyed by
-- session (protocol-change/078). It is a database of its own and never part of
-- the catalogue or a session file.
--
-- `scope` is one session's attachment to this executor. `incarnation` rises
-- only when a cleanly closed scope reopens, and `attach_token` is the one token
-- the executor accepts from the session's current runtime.
CREATE TABLE scope(
  session TEXT NOT NULL,
  workspace TEXT NOT NULL,
  incarnation INTEGER NOT NULL CHECK(incarnation >= 0),
  state TEXT NOT NULL CHECK(state IN ('open', 'closing', 'closed')),
  close_outcome TEXT,
  attach_token BLOB NOT NULL CHECK(length(attach_token) > 0),
  PRIMARY KEY(session, workspace)
);

-- `call` is one tool call, keyed by the identity the orchestrator's planner
-- already uses. There is no acknowledged state: an acknowledgement deletes the
-- row. `outcome_bytes` is the reservation while the call is `admitted`, the
-- outcome's size once it is `terminal`, and zero for an `unknown` call.
CREATE TABLE call(
  session TEXT NOT NULL,
  op TEXT NOT NULL,
  step TEXT NOT NULL,
  source_index INTEGER NOT NULL CHECK(source_index >= 0),
  incarnation INTEGER NOT NULL CHECK(incarnation >= 0),
  tool TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('admitted', 'terminal', 'unknown')),
  outcome BLOB,
  outcome_digest BLOB,
  outcome_bytes INTEGER NOT NULL DEFAULT 0 CHECK(outcome_bytes >= 0),
  PRIMARY KEY(session, op, step, source_index)
);
