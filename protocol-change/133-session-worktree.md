# protocol-change/133: a session in its own Git worktree, chosen when it is created

**Status**: PROPOSED 2026-11-24, built in the same pull request.
**Affects**: the control command `sessions.create` gains an optional `worktree`
member, and its replies, `sessions.get` and `sessions.list` records gain a
`worktree` member for a session that has one. `sessions.create` gains the
refusal code `not_a_repository`. The catalogue moves to version 24 and gains
one table. No Part 1 interface changes, and the executor's node vocabulary
(`client/remote/protocol`) is untouched.
**Raised by**: the owner's request for what Claude's desktop app has, a
"Worktree" checkbox beside the folder when a session starts, so that the
session's changes land in a worktree and branch of their own and not in the
folder.
**Builds on**: [095](095-worktree-workspaces.md), whose creation, adoption,
removal and reconciliation of a session's tree this proposal reuses without a
second implementation.
**Amends**: the statement in `docs/architecture/sessions.md` that a plain local
session always runs in its folder, for a session created with the choice.

## Problem

Worktree mode is a property of a workspace an executor serves
(`[workspaces.<name>] mode = "worktree"`). A session in a local folder has no
such table: it always runs in the folder, so two sessions of one folder edit the
same files, and a session's changes mix with the owner's own. The owner wants to
choose, for one session at a time, to work in a worktree of the folder.

## What was considered

### A `mode` for local folders in `loom.toml` (rejected)

A table of folders and their modes would make the choice a property of the
folder. The owner's request is per session, made at the moment the folder is
chosen, and a folder the daemon has never been told about cannot be listed in
advance. A per-folder default may be added later on top of the per-session
choice; the reverse is not possible.

### A second implementation of the tree's lifecycle (rejected)

The create, adopt, recreate, remove-when-clean and keep-when-dirty rules of 095
are the product of a review and several crash cases. A second copy for local
sessions would drift from them. This proposal calls `client/worktrees` and adds
only what a folder the daemon did not know in advance needs
(`client/local_trees`).

### Recording the choice in the registration (rejected)

`catalogue.Registration` is built in about forty test modules, and a new field
would change each. The choice is kept in a side table keyed by session, as the
subagent limits are (`113`), and is read where it is needed.

## Decision

### The wire

`sessions.create` accepts an optional object:

```json
{"worktree": {"base": "origin/main"}}
```

`base` is the commit-ish the session's branch starts from. It is optional and
defaults to `HEAD`, so `{"worktree": {}}` asks for a worktree from `HEAD`. The
presence of the member is the choice: a request without it is the request it
always was, and a daemon that predates this proposal ignores a member it does
not know, which is why a client that needs the worktree must check the reply's
`worktree` member (below).

Refusals, all before an identity is reserved, so a refused request leaves
nothing behind and its key may be used again:

| Condition | Code |
|---|---|
| `worktree` is not an object, holds a key other than `base`, or `base` is not a string | `bad_request` |
| `base` is empty, longer than 255 bytes, starts with `-`, or holds a space or a control character (the rule of `[workspaces.<name>] base`, shared in `catalogue.is_worktree_base`) | `bad_request` |
| `worktree` beside `executor` or `pool`: an executor's workspace chooses its own mode in the executor's table | `bad_request` |
| The folder, once canonicalized, is not the top of a primary checkout, that is a directory with a `.git` directory (a subdirectory of a repository, a bare repository, a linked worktree, or not a repository) | `not_a_repository` |

Whether `base` names a commit is Git's to say when the tree is made. A base that
does not resolve fails the session's first open, and the reason is recorded as
the session's start failure, as for any other failure to start.

A retry under the same `request_key` must repeat the choice: the same base, or
the same absence of one. A different one is `conflict`, as for a different
profile.

The reply of `sessions.create`, a `sessions.get` for the owner and each record
of `sessions.list` carry, for a session that has a worktree:

```json
{"worktree": {"base": "origin/main", "branch": "loom/0198c0de-0000-7000-8000-000000000001"}}
```

A session without one omits the member, so its record is byte for byte what it
was. The record's `workspace` stays the folder the session was created in. The
folder is what the home page groups by, what the owner's recent folders list
and what the session's memory is keyed by. The tree's own path is not on the
wire; the session's tools and prompt see it as their working directory.

### The catalogue

Version 24 adds `catalogue_session_worktrees(session_id, base)`, one row for a
session created with the choice, written in the transaction that reserves the
registration (`domain.reserve_session_with_agency`), and deleted with the
session. A session with no row works in its folder. The branch is not stored:
it is `loom/<session id>`, as in 095, so it cannot disagree with the id.

### The lifecycle

The lifecycle is 095's, with the folder in the place of a configured root:

1. **First open.** The daemon's session builder reads the session's base. With
   one, it asks `client/local_trees` for the tree before it resolves the
   session's settings, so the settings (the jail's writable roots, the Git
   widening for a linked worktree, the language servers, the Go caches) are
   resolved against the tree. The tree is
   `<state root>/worktrees/local-<digest of the folder>/<session id>` on the
   branch `loom/<session id>`, made by `git worktree add -b` from `base`.
2. **Reopen.** The record in the execution ledger is found, and the tree is
   adopted after `git worktree repair`, or recreated from the session's branch
   if it is gone, with the commits the branch holds.
3. **Close.** When the session's helpers are confirmed stopped, the retirement
   removes the tree if `git status` is clean (ignoring `.codemode`) and HEAD is
   a branch, and keeps it otherwise. The branch is never deleted. The daemon
   logs `daemon.session_worktree_removed` or `daemon.session_worktree_kept`
   with the session and, for a kept tree, the reason.
4. **Failure.** A failed or interrupted create removes the directory it made,
   prunes and records `removed`, as in 095. The session fails to start with
   Git's message, cut to 512 printable bytes.

The session's jail is the tree: its writable roots are the tree and the linked
Git directories (`<folder>/.git/worktrees/<name>` and the common directory), so
the folder's own files are readable, as the rest of the host is, and not
writable. The common directory is writable so that `git commit` works, which is
the same reach a session in the folder has and 095 records.

A folder that is itself a linked worktree is refused, as in 095, because the
common directory the jail must write is `<folder>/.git` only for a primary
checkout.

### Where a kept tree is found and cleaned up

A kept tree is an ordinary linked worktree of the folder, so the owner finds it
with `git worktree list` in the folder, on the branch `loom/<session id>`, and
the daemon's log line names its session. It is removed in three ways, none of
which needs a new command:

- the session is reopened and closed again clean, which removes it under the
  close rule above;
- the owner removes it with `git worktree remove <path>`, and the next reopen
  recreates it from the branch if the session is used again;
- the owner deletes the branch with `git branch -d loom/<session id>` once the
  work is merged or abandoned. Loom never does.

`loomd executor release --worktrees` does not cover these trees. It settles the
trees of the workspaces an executor's `loom.toml` serves, and a local folder's
service is not in that table. Deleting a session does not remove a kept tree, as
in 095: the tree and its branch outlive the registration, and `git worktree
list` is where they are found.

### The service for each folder

`client/worktrees` serves a fixed list of workspaces, each with a gate that runs
its Git work one job at a time. A folder becomes a workspace named
`local-<sixteen hex digits of the SHA-256 of its canonical path>`, and
`client/local_trees` starts that workspace's service the first time a session of
the folder needs it and keeps it. Two sessions of one folder therefore share a
gate, and sessions of different folders do not wait for each other.

The `git-cow` that makes the tree is resolved from the daemon's `PATH` (or beside the
server) and runs in the same sandbox as the Git it replaces.

## What it costs

- One catalogue migration, and one more table that every session deletion
  touches.
- A session in a worktree has its own Go build caches, because the caches are
  keyed by the workspace path, and the first build in a new tree is cold.
- A tree on disk for each session that holds changes, until the owner removes
  it, and a branch for each session that used the choice.
- A control client must read the reply's `worktree` member to know that the
  daemon honoured the choice, since an older daemon would ignore it.
- A session's tree is opened before its settings are resolved and its cleanup is filed
  only once assembly starts, so a session whose settings fail to resolve leaves a
  clean tree, recorded as present. The next open adopts it, and the next clean close
  removes it. This is a known gap, left because the tree holds nothing.
- A session that works in a worktree is not moved to another orchestrator: a move
  carries the folder and not the tree, so `sessions.move` refuses it as not movable.
- The first session of each folder boots a sandboxed Git (two helper pools,
  started lazily) that lives as long as the daemon.
