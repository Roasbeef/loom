-- The executor ledger's fourth schema version (protocol-change/095). A
-- workspace in worktree mode gives each session its own linked Git worktree and
-- branch, and this table is the executor's proof of what it created, so that it
-- removes only what it made.
--
-- One row per session. The row is written before `git worktree add` runs
-- (`creating`), so a crash on either side of the command leaves a record that
-- names the directory to look at. `present` is a tree on disk, `kept` is a tree
-- a clean close found with user changes and so left, `removing` is written
-- before `git worktree remove`, and `removed` is a tree that is gone while the
-- branch stays. The row is never deleted: a `removed` row is what lets a
-- reopen recreate the tree from the branch. Nothing here is a path the
-- orchestrator chose; the path is derived from the state root, the workspace
-- name and the session id.
CREATE TABLE scope_worktree(
  session TEXT NOT NULL PRIMARY KEY,
  workspace TEXT NOT NULL,
  path TEXT NOT NULL CHECK(length(path) > 0),
  branch TEXT NOT NULL CHECK(length(branch) > 0),
  state TEXT NOT NULL
    CHECK(state IN ('creating', 'present', 'kept', 'removing', 'removed'))
);
