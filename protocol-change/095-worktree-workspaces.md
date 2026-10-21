# protocol-change/095: a Git worktree per session on an executor workspace

**Status**: ACCEPTED 2026-10-21. The owner authorised the placement revamp end
to end, including the protocol changes it needs
([docs/design-notes/placement-revamp.md](../docs/design-notes/placement-revamp.md)).
Revised the same day after an independent review: the close ignores
`.codemode`, a deletion leaves an orphan for `loomd executor release`, a
failed or interrupted create removes its directory, and the isolation claim is
narrowed. Built in slice S3 of that note.
**Affects**: no Part 1 interface. The executor's node vocabulary
(`client/remote/protocol`, not Part 1 by [078](078-distributed-runtime.md))
gains one refusal and one census member and moves to version 4 with `Attach`
unchanged in shape; `loom.toml` gains `mode` and `base` on
`[workspaces.<name>]`; the execution ledger's scope row gains a worktree
record.
**Raised by**: the owner's expectation that "each session gets its own
worktree of it automatically, so you never think about worktrees", and the
mockups' "each session gets its own branch".
**Builds on**: 078 (registered workspaces, scopes, the execution ledger, pool
placement), [068](068-working-directories-and-lsp-scope.md) (working
directories inside a workspace), and the linked-worktree widening in
`packages/client/src/client/workspace_policy.gleam`.
**Amends**: the statement in `docs/architecture/sessions.md` that Loom neither
creates nor removes Git worktrees, for workspaces in worktree mode.

## Problem

An executor serves each registered workspace as one fixed checkout. Every
session that attaches under the name gets its own scope (scratch directory,
helpers, ledger row) but runs its tools in the same `root`: the plane passes
`workspace: root` for every session (`executor_plane.gleam:418`). Two sessions
on `exec:repo` edit the same files, check out branches under each other, and
see each other's uncommitted work. The owner's mental model, and the mockups,
assume each session has its own copy.

## What was considered

### A copy of the tree per session (rejected)

`cp -a` or a reflink of `root` per scope. Simple and independent of Git, but
it duplicates the object store unless the filesystem supports reflinks, and
the copy is not a branch the owner can push or review.

### Worktrees under the repository (rejected)

`git worktree add <root>/.loom-worktrees/<session>`. The tree would sit inside
`root`, so every session in shared mode, and every tool that walks `root`,
would see the others' trees, and `git status` in `root` would list them unless
ignored.

### Worktrees under the executor's state directory (accepted)

`git worktree add <state root>/worktrees/<workspace>/<session> -b <branch>
<base>`. The tree is outside `root`, the object store is shared, and the
branch is an ordinary branch in the repository.

### Remove the tree at every scope close (rejected)

Scopes close often: on an idle close (`idle_close_s`), on a daemon restart,
before a move. Removing the tree each time would lose uncommitted work and
would rebuild the tree on every reopen.

## Decision

**Accepted.** A workspace in worktree mode gives each session its own linked
worktree and branch, created at the session's first attach, kept across scope
closes while it holds uncommitted work, removed at a clean close, and
recreated from the branch on reopen.

### Configuration, on the executor

```toml
[workspaces.repo]
root = "/home/exedev/src/loom"
mode = "worktree"          # "shared" (default) or "worktree"
base = "origin/main"       # the start point of each new branch; default "HEAD"
```

| Key | Meaning |
|---|---|
| `mode` | `shared`: today's behaviour, every session uses `root`. `worktree`: each session gets its own linked worktree of `root`. Default `shared`, so existing configurations do not change. |
| `base` | With `worktree`: the commit-ish each new branch starts from, resolved in `root` when the worktree is created. Default `HEAD`. Refused with `shared`. |

With `worktree` the daemon refuses to start unless `root` is the top of a
non-bare Git repository whose `.git` is a directory (a primary checkout, not
itself a linked worktree), so the common directory is `<root>/.git`.

### Paths and names

- The tree lives at `<state root>/worktrees/<workspace>/<session>`, beside
  `scopes/` and `blobs/`. It is not under `scopes/<session>`, because the
  scope directory is deleted and recreated at every attach
  (`scope_directory`, `executor_plane.gleam:324`).
- The branch is `loom/<session id>`, the session's UUIDv7 in its canonical
  form. It is unique without coordination, and the page shows it shortened.
  A rename is left to the agent or the owner with ordinary Git.
- The session's workspace for the sandbox, the tools, the language servers and
  068's working directories is the tree's path. `root` is no longer a writable
  root for that session.

### Lifecycle

The executor keeps a worktree record on the scope's ledger row:
`{path, branch, state}`, with `state` one of `creating`, `present`, `kept`,
`removing` and `removed`. All Git operations on one workspace run in one weft
task per workspace, so `git worktree` never races itself on the same
repository.

1. **First attach** (no record). Write `creating` with the path and branch,
   then run `git worktree add <path> -b <branch> <base>`, then write
   `present`. If the command fails, delete the directory at the recorded path
   if it exists (the `creating` record proves Loom made it), run `git worktree
   prune`, write `removed`, and refuse the attach with
   `WorktreeFailed(reason)`, where `reason` is Git's message cut to 512
   printable bytes. Without the delete, a half-made directory would make every
   later attach fail the same way. The session sees the refusal as it sees
   `CapacityExhausted` today.
2. **Reopen** (a record exists). `present` or `kept` with the path on disk:
   adopt it after `git worktree repair <path>`. `removed`, or the path missing:
   run `git worktree add <path> <branch>`, which checks out the existing branch
   with its commits, and write `present`. A branch that no longer exists is
   recreated from `base`, and the census reports it.
3. **Close.** After the scope's own cleanup (`settle_scope`,
   `executor_plane.gleam:758`) proves `AllRetired`, read
   `git -C <path> status --porcelain=v1 --untracked-files=normal -- .
   ':(exclude).codemode'`. The exclusion is Loom's own directory: code mode's
   exec root (`work_directory`, `codemode.gleam:913`) and the tool Git
   identity (`.codemode/home/gitconfig`, `git_identity.gleam:70`) live in
   `.codemode` inside the workspace, so an unfiltered status is never empty
   for a session that used code mode.
   - Empty: write `removing`, run `git worktree remove --force <path>`, then
     write `removed`. `--force` is needed only to remove `.codemode`, which
     the filtered status has shown is the only thing that is not clean. The
     branch stays.
   - Not empty: write `kept` and leave the tree. Loom never force-removes a
     tree that holds user changes, and never discards, stashes or commits
     them.
   - `UnknownCleanup`: leave the tree and the record as they are, as the scope
     directory is left today; `loomd executor release` handles both.

Deleting a session does not reach the executor: today's `Close` carries no
deletion marker, and `manager.delete_session` refuses a session that holds a
slot. A deleted session's tree is therefore an orphan once its last close
settles. The census reports orphaned trees (a record whose session the
orchestrator no longer lists), and `loomd executor release` removes them under
the same rule as a close: a tree with user changes is kept unless the owner
names it.

Loom never deletes a branch. Branches accumulate one per session; the owner
prunes them with Git. The census reports how many `loom/` branches have no
session, so Admin can show it.

### Start-up reconciliation

At start, before the host admits attaches, for each worktree record:

- `creating`: if the path exists and `git worktree list --porcelain` lists it,
  write `present`. Otherwise delete the recorded path if it exists, run `git
  worktree prune`, and write `removed`. This covers a crash on either side of
  `git worktree add`.
- `removing`: run the close's filtered status and removal again if the path
  exists, then write `removed`. This covers a crash during removal.
- `removed` with the path still present: the record proves Loom created it and
  had decided to remove it, so delete it and prune.
- `present` or `kept` with the path missing: write `removed`.

Then `git worktree prune` once per workspace, which drops Git's records of
trees deleted outside Loom. A directory under `worktrees/<workspace>/` with no
record is left in place and reported in the census, never deleted: Loom
removes only what its ledger says it created.

Reconciliation runs in a weft task before the host admits attaches. It logs
`executor.worktree_reconcile` with the count done and the count left every
100 records, and gives up after 60 s with the rest left for the next start; a
workspace whose records were not all reconciled refuses attaches with
`PlaneBuilding` until they are.

### The sandbox

`root.directories` (`daemon/root.gleam:920`), which creates the state root's
directories, gains `worktrees/`. A worktree session's writable roots are its
own tree and the two linked Git directories below; the rest of the state root
stays masked as it is for `scopes/` and `blobs/` today, so `worktrees/` is not
covered by any mask over the whole root that would hide a session's own tree.
S3's tests include "a worktree session cannot read `<state
root>/scopes/<other>`" and "cannot read `<state root>/worktrees/<workspace>/<other>`".

### Pools and stickiness

Unchanged. A pool chooses an executor at the first open and the scope record
names it from then on (`Scope`, `remote/scope.gleam:78`). The tree and its
branch exist only on that executor, which is one more reason the session never
moves to another. A move to another orchestrator closes the scope (the tree
stays if dirty, otherwise is removed) and the new owner's first attach on the
same executor recreates or adopts it.

### The linked-worktree widening

`workspace_policy.linked_git_directories` reads the tree's `.git` file, its
`gitdir` (`<root>/.git/worktrees/<name>`) and that directory's `commondir`
(`<root>/.git`), and `widening_linked_worktree`
(`workspace_policy.gleam:334`) makes both writable so that a jailed `git
commit` works. In worktree mode this applies to every session. The session can
therefore write the shared object store, refs and hooks of `root`'s
repository. That is the same reach a session has in shared mode, where `root`
and its `.git` are writable outright; worktree mode takes away write access to
`root`'s own files and adds nothing.

The isolation worktree mode gives is protection against accidents (two agents
editing one file, checking out branches under each other), not against a
hostile model. Because the shared `.git` is writable, a session can rewrite
another session's `.git/worktrees/<other>/HEAD` and index, move its branch, or
set `core.hooksPath` or `core.fsmonitor` in `.git/config` so that a command in
another session runs code it chose. None of this is new: in shared mode a
session can do all of it to every other session directly.

### Wire

- The executor's census gains `mode` per registered workspace, so
  `Placements` (094) and the web Code chip can say "each session gets its own
  branch".
- `Refusal` gains `WorktreeFailed(reason)`.
- The session's census answer gains `branch` for a worktree session, which the
  session header shows.
- `protocol.version` moves from 3 to 4. `Attach` keeps its shape, as the
  module requires.

## What it costs

- Git becomes a dependency of the executor host for worktree workspaces,
  invoked through the existing process machinery, never through a new FFI.
- One more directory tree under the state directory, bounded by the number of
  sessions with uncommitted work.
- Branches accumulate in the repository, one per session, until the owner
  prunes them.
- A first attach takes as long as `git worktree add`, which checks out the
  whole tree; on a large repository that is seconds. The attach is already
  answered `PlaneBuilding` while a build is in flight.
- Every worktree session can still write the shared `.git`, as every session
  could before.
- The version step from 3 to 4 means every executor must upgrade, including
  one that serves no worktree workspace, because orchestrators and executors
  must agree on the version. A session that a pool placed on an executor that
  has not upgraded is refused at attach until that executor upgrades; it is
  never moved to another executor.
- Start-up reconciliation adds time before an executor admits attaches,
  bounded at 60 s and logged as it goes.
