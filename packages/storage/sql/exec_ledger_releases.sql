-- The executor ledger's second schema version (protocol-change/078, addendum:
-- the review of the remote core). A scope that closed with unknown cleanup, or
-- stopped in `closing` because the executor's VM ended mid-close, has no
-- automatic successor. An operator releases it with `loomd executor release`,
-- and this table is the record that they did.
--
-- One row per release, in the order they happened. `was` is the state the scope
-- had before: `closing`, or `unknown:<count>` for the cleanup that could not be
-- proven. `released_at_ms` is the executor's wall clock in Unix milliseconds.
CREATE TABLE scope_release(
  id INTEGER PRIMARY KEY,
  session TEXT NOT NULL,
  workspace TEXT NOT NULL,
  incarnation INTEGER NOT NULL CHECK(incarnation >= 0),
  was TEXT NOT NULL,
  released_at_ms INTEGER NOT NULL
);
