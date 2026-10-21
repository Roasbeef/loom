# protocol-change/095: a Git worktree per session on an executor workspace

**Status**: ACCEPTED 2026-10-21. The owner authorised the placement revamp end
to end, including the protocol changes it needs
([docs/design-notes/placement-revamp.md](../docs/design-notes/placement-revamp.md)).
Built in slice S3 of that note.
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
   `present`. If the command fails, write `removed`, run `git worktree prune`,
   and refuse the attach with `WorktreeFailed(reason)`, where `reason` is
   Git's message cut to 512 printable bytes. The session sees the refusal as
   it sees `CapacityExhausted` today.
2. **Reopen** (a record exists). `present` or `kept` with the path on disk:
   adopt it after `git worktree repair <path>`. `removed`, or the path missing:
   run `git worktree add <path> <branch>`, which checks out the existing branch
   with its commits, and write `present`. A branch that no longer exists is
   recreated from `base`, and the census reports it.
3. **Close.** After the scope's own cleanup (`settle_scope`,
   `executor_plane.gleam:758`) proves `AllRetired`, read `git -C <path> status
   --porcelain=v1 --untracked-files=normal`.
   - Empty: write `removing`, run `git worktree remove <path>` without
     `--force`, then write `removed`. The branch stays.
   - Not empty: write `kept` and leave the tree. Uncommitted work is never
     discarded, stashed or committed by Loom.
   - `UnknownCleanup`: leave the tree and the record as they are, as the scope
     directory is left today; `loomd executor release` handles both.
4. **Session deleted** on its orchestrator. The executor learns of it through
   the existing close that a deletion sends. A deletion removes the tree with
   `git worktree remove --force` after the close settles, because the owner
   asked for the session to go. The branch stays.

Loom never deletes a branch. Branches accumulate one per session; the owner
prunes them with Git. The census reports how many `loom/` branches have no
session, so Admin can show it.

### Start-up reconciliation

At start, before the host admits attaches, for each worktree record:

- `creating`: if the path exists and `git worktree list --porcelain` lists it,
  write `present`; otherwise `git worktree prune` and write `removed`. This
  covers a crash on either side of `git worktree add`.
- `removing`: run `git worktree remove` again if the path exists, then write
  `removed`. This covers a crash during removal.
- `present` or `kept` with the path missing: write `removed`.

Then `git worktree prune` once per workspace, which drops Git's records of
trees deleted outside Loom. A directory under `worktrees/<workspace>/` with no
record is left in place and reported in the census, never deleted: Loom
removes only what its ledger says it created.

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
`root`'s own files and adds nothing. A session can still affect another
session through the repository (a hook, a forced ref update), as it can today.

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
