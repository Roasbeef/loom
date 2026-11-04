# protocol-change/107: moving repository state between machines

**Status**: PROPOSED 2026-11-03. Slice 1 is partly built: the local capture and
import of PR #1147 (merged). Everything that crosses a link is not. The rulings
this rests on were agreed with the owner on 2026-11-01 and are recorded on loom
#1137; the spellings below are provisional until a slice builds them. The
git-identity message (see "Git identity on an executor") was added on
2026-11-03 so the version bump is paid once.
**Affects**: the orchestrator port's closed message type (four constructors),
the remote node vocabulary of [078](078-distributed-runtime.md) (the executor
host gains four, `remote/protocol` version 5 to 6), the subagent `Request` and
`Joined` of [084](084-remote-subagents.md) (one optional field each) and its
`SpawnRefusal` (two variants), `loom.toml` (one key on `[spawners.<name>]`), and
a per-node state store under the node's state directory. No Part 1 interface and
no client control protocol command changes.
**Raised by**: the owner's 2026-11-01 test of a box orchestrator delegating a
commit to the laptop. The child ran on the laptop and could not see the box
checkout, so the box agent staged a `git bundle` on its own disk for the operator
to carry by hand.
**Builds on**: 078 (workspaces, executors, the pinned link), 084 (remote
children, the outbox that resends a spawn), [095](095-worktree-workspaces.md)
(a linked worktree per session, and `client/worktree_git`, the jailed Git
runner), the session move of 078 phase 5 (`client/session_move`: the
acknowledged, offset-checked, hash-verified chunk transfer this proposal reuses)
and `client/repository_snapshot` (PR #1147), which captures a quiescent
workspace into a verified bundle and a private child without touching the source.
**Issue**: loom #1137 (work item "State transport").

## Problem

Loom separates the machine that holds a conversation (the orchestrator) from the
machine that holds a checkout (the executor). It has no way to move a checkout
from one to the other. Three things follow.

A remote child starts with an empty directory or with whatever checkout the
receiver's `[spawners.<name>]` table points at. It cannot start from the
parent's work, so "finish the rest of this on that machine" cannot be said.

A remote child's commits stay on the machine that made them. The parent's
`Joined` entry carries the child's result text and nothing a repository can
apply. Today the only way back is a push to a forge, which needs a token on the
remote machine, or a person copying files.

`sessions.move` carries the conversation file and refuses a session whose
checkout is a directory on the source, so a laptop session cannot continue on a
box.

All three are the same missing piece: a way to carry Git objects over the link
the machines already trust, and apply them without running anything the model
influenced inside the daemon.

## What was considered

### Push and fetch through the forge (rejected)

Have the child push a branch and the parent fetch it. This needs a credential on
the remote machine, which is what loom #1136 wanted to avoid, publishes work in
progress, and fails on an offline link or a private repository the remote cannot
reach. It also gives up the rule that only the owning machine publishes.

### Executors fetch from each other (rejected)

Open a Git transport (ssh or the git protocol) between the two machines. It adds a
network surface and a second set of credentials beside the pinned distribution
link, is invisible to the execution ledger, and cannot be fenced by the
incarnation checks that every other cross-machine step goes through.

### Carry the bundle in tool calls (rejected)

Let the model run `git bundle create` and read the file back. Results are capped
at `default_max_result_bytes` (16 MiB), the bytes pass through the model's
context or a code-mode program, and integrity depends on the model copying them.
The mover must be the daemon, not the model.

### Copy the working tree (rejected)

`tar` the tree. It drops history, so the return trip cannot say which commits
are new, has no hash to verify against, and ships ignored build output.

### Git bundles as hash-addressed chunked blobs on the pinned link (accepted)

A bundle is Git's own transport object: history plus refs, verifiable, thin when
the receiver already holds the prerequisites. The session move already moves a
large file between two orchestrators in acknowledged 256 KiB chunks and checks
its hash; the same chunks move a bundle.

## Decision

**Proposed.** A node can capture a checkout as a bundle, hold it in a state
store, send it to another node in chunks, and apply it in a repository there.
Applying never changes a checked-out branch, an index or a working tree that
exists already. Nothing in this proposal merges, pushes or publishes.

### The state object

A state is identified by `hash`, the SHA-256 of its bundle file. Its description
is plain data:

| Field | Meaning |
|---|---|
| `hash` | SHA-256 of the bundle, lower-case hex. |
| `size` | Bytes of the bundle. At most `size_limit`, see Open. |
| `tip` | The commit the bundle delivers, which carries the captured work. |
| `base` | The commit the bundle is thin against, or none for a full bundle. |
| `dirty` | Whether `tip` is a snapshot commit that records uncommitted changes. |

### Capture

Capture runs on the node that holds the repository, through `client/worktree_git`
and so inside the sandbox (Rule Zero: the repository's config and hooks are
shaped by the model). `client/repository_snapshot.capture` is the local half and
is already written. What it fixes for this proposal:

- The source is not touched. The snapshot commit is built with a private index
  and object store inside a private stage, so the source's `HEAD`, index, refs and
  files are byte-identical afterwards. No ref is written in the source
  repository.
- The snapshot is a commit on top of `HEAD`, made from the working bytes as they
  are. Staged and unstaged changes collapse into one tree. Untracked files that
  `.gitignore` does not exclude are included. Ignored files and Loom's own
  runtime data are not, and a tracked file that collides with a protected path
  refuses the capture.
- A repository that is shallow, has submodules or gitlinks, uses LFS or a legacy
  line-ending or other content transformation, has an unborn `HEAD`, a promisor
  remote or grafts, or an unreadable ignore rule is refused with a reason. LFS
  pointers are therefore not shipped as pointers; the repository is refused.
- Every Git process runs with the network off, finite limits and one work
  deadline. The bundle is verified in a fresh repository before capture
  returns.
- The caller must have serialized and drained the source and must keep external
  writers quiet. The module cannot check this, and no production caller exists
  yet. Slice 3 is where a caller appears, so the requirement is settled there
  (see Open).

What this proposal adds on top is the part that needs a peer. Capture of a
child's result is *thin* against the state the child was handed, and capture for
a first send asks the receiver which of a few commits it has (`HEAD`, its parent
chain to a limit of 16, the merge base with the upstream branch). The newest one
it holds becomes `base`; if it holds none, the bundle is full, which is the only
shape `repository_snapshot` produces today. The bundle file is hashed and kept
in the node's state store at `<state>/states/<hash>.bundle`.

### Send

The sender streams the bundle to the receiver's store using the `Chunk` of
`client/session_move`: 256 KiB pieces, each acknowledged before the next, each
carrying its offset and the declared size, with a piece at the wrong offset
answered by restarting from the receiver's offset. The receiver verifies the
hash when the last piece lands and refuses a mismatch. A transfer interrupted by
a dropped link resumes at the receiver's offset, and a finished state is not sent
twice. The orchestrator relays between a source node's store and a target node's
store one chunk at a time, so it holds no whole bundle in memory.

### Apply

Apply runs on the receiving node, again through the sandboxed Git runner, with
`core.hooksPath` pointed at an empty directory. `repository_snapshot` already
imports a bundle into a fresh private repository. Apply adds the two shapes a
receiver needs:

- Into a registered workspace that is a repository: fetch the bundle into
  `refs/loom/in/<hash8>`, touching no other ref, then create the child's
  workspace from it with the worktree machinery of 095, as
  `git worktree add -b loom/<session> refs/loom/in/<hash8>`.
- Into a plain `directory` placement, which has no repository: clone the bundle
  into `<directory>/<child>`, which is what the existing private import does.

A dirty snapshot arrives as one commit whose subject says it is a Loom snapshot,
so the child starts with the parent's uncommitted work as the first commit on its
branch and nothing is lost.

### Spawn: sending the parent's state with a child

`agent_spawn` does not gain an argument the model can widen. The
`[spawners.<name>]` table, which is the owner's ceiling, gains one key:

```toml
[spawners.box]
seed = "workspace"     # "none" (default) or "workspace"
```

With `seed = "workspace"`, a spawn from a session that has a workspace sends that
workspace's state with the child. The model may narrow this to none; it may not
turn it on where the owner left it off. The result is the same as today for every
existing configuration.

The wire change follows the rule that makes a spawn safe to resend. `Request`
gains `state: Option(State)`. The receiver's `Spawn` answers
`Error(StateMissing(hash, have))` when the state is not in its store or not
complete, where `have` is the offset it holds. The sender streams from `have`,
then sends the same `Spawn` again. The call site still derives the same child
name, so the answer to the repeated spawn is the same handle, as 084 requires,
and the outbox drainer's retry ladder covers a state transfer with no new timer.

### Return: the child's work comes back

When a child that held a state ends, its node captures the child's workspace the
same way, thin against the state it was handed, and keeps it in its store for
`retain_s`. The `Joined` entry gains `state: Option(State)`. The parent's node
then pulls it: `StateFetch(hash, offset)` returns chunks, the parent verifies the
hash, and apply fetches it into the parent's repository under
`refs/loom/children/<child>/<tip8>`.

A pull, not a push, because the child's node may restart and the parent's turn
may end long before the child does. The state stays where it was made until it
is fetched or expires, and a fetch resumes at an offset.

The parent's checked-out branch and tree are not touched. The join text names the
ref and the number of commits ("the child made 3 commits, at
`refs/loom/children/fix-cache/9f1c2a7`"), and the model or the operator merges
with ordinary Git. This is the point at which only the owning machine publishes:
the commits are now on a machine that has the token, and it can push them. A
child on a machine with no token never needs one.

**The microVM tier is the one exception.** The standing guest of ADR-022 pushes
through its credential proxy and so can publish its own work, and the 2026-11-01
ruling accepts that for guests. That does not remove the return path. A child in
a guest still returns its commits to the owner by this mechanism, because the
operator's checkout is where the work is merged and a pushed branch is only one
way to get it there. A guest that has pushed is a convenience, not the transport.

### A session move with a checkout

`sessions.move` gains a step before the six it has now: when the session's
workspace is a directory on the source, capture it, send it to the target's
registered workspace, and apply it, then run the move. The move is refused if the
target has no workspace to receive it, as it refuses a local session today. The
single-writer rule is unchanged: the source stops writing before the target
activates, and the checkout copy is a point-in-time snapshot taken after the
session's slot is stopped. Stopping the slot is also what drains the source, which
is the precondition `repository_snapshot` states, so this is the one caller where
the precondition holds by construction.

### Wire

- `orchestrator_port.Message` gains `StateChunk` (one piece, verdict reply),
  `StateStatus` (how many bytes of a state the node holds) and `StateFetch` (one
  piece of a held state, so a node can serve what it captured).
- `HostMessage` gains `StateCapture`, `StateChunk`, `StateStatus` and
  `StateFetch`, so an executor holding the repository speaks the same pieces. A
  census field says whether the executor can capture and apply (it needs Git and
  the sandbox helper). `protocol.version` moves from 5 to 6, and `Attach` keeps
  its shape.
- `remote_spawn.Request` gains `state`, `Joined` gains `state`, and
  `SpawnRefusal` gains `StateMissing(hash, have)` and `StateRefused(reason)`.
  A peer on the earlier version never sees the new field, because the host
  refuses it at the attach.
- The pushed `remote_children` snapshot gains `commits` and the returned ref for
  a settled child, optional, so an older client ignores them.

### Git identity on an executor

A child that commits on an executor needs an author. Today the executor builds
the tool's `gitconfig` from its own global `user.name` and `user.email`
(`workspace_plane.prepare_identity`, through `git_identity.prepare`). On a
machine that never set them the file holds only `useConfigOnly`, `git commit`
fails, and the agent works around it by writing `git config user.name` into the
shared repository's `.git/config` (loom #1061). The orchestrator's identity has
no way to reach the executor, because `Attach` is frozen and the host's attach
spec carries none.

`orchestrator_port.Message` gains `AskGitIdentity`, which the executor sends once
per scope build after the version check, as it does `AskMcpPlan`. The reply is an
optional `GitIdentity(name, email)` decoded totally in `peer_codec`. Both values
must be non-empty after trimming and carry no control character or NUL, or the
owner answers none. The owner answers from the identity the orchestrator already
resolves for its own sessions (`git_identity.resolve`).

An executor that receives an identity publishes it through `git_identity.publish`
and adds `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME` and
`GIT_COMMITTER_EMAIL` to the tool environment. A repository's `.git/config` and
the executor's own `~/.gitconfig` then cannot change the author. The four names
join the refusal lists in `catalog.parse_tools` and `lsp/profile`, so a
configuration cannot set them either. A session on an executor that received no
identity behaves as today, and a local session is unchanged: its repository's own
`user.*` still wins.

This is the same version bump as the chunk messages, so executors upgrade with
their orchestrators once. It lands with slice 2.

## Safety

- Git never runs in the daemon's own VM against a repository the model has
  written. Capture and apply go through `worktree_git`, whose calls carry a policy
  built from their arguments, with no network and writable roots limited to the
  stage, the repository's `.git` for a fetch, and the destination.
- Capture writes nothing into the source. Apply writes refs under `refs/loom/`
  only. It cannot move a branch the session or the operator uses, and it runs no
  hook.
- The hash and size are checked before anything is applied. A state is a value
  to compare, not a reference to trust.
- A snapshot contains the committed history reachable from `HEAD` and the
  untracked files `.gitignore` does not exclude. A secret in an unignored file or
  in history would travel; capture is not a content scanner. The protected-path
  refusal and the exclusion of Loom's runtime data are the whole of the
  filtering, and the operation record holds each state's hash and size so a
  transfer can be audited.
- Sending a checkout to another machine needs no approval beyond the spawn. The
  destination is a peer in the pinned ledger, the spawner table that names it is
  the owner's, and `seed` is off unless the owner turned it on.

## What it costs

A per-node store of bundles that needs a size bound and a sweep (by the same
`retain_s` and a total cap) so it cannot fill the disk. `repository_snapshot`
states that its free-space check is an observation and not a reservation, so the
store's cap is the only bound on what this adds. One more constructor group in
each of two closed vocabularies, and a version bump on the executor link, so
executors upgrade with their orchestrators.

A thin bundle needs the receiver to hold the base commit. When it does not, the
bundle is full, and a large repository can exceed `size_limit`. The limit is a
refusal with a reason, not a degraded mode.

Capture refuses more repositories than a person might expect (submodules, LFS,
shallow clones, conversions). That is deliberate: a snapshot that silently
changes bytes is worse than one that says no.

It does not replicate. Each state has one writer, the node that captured it. It
does not merge, and does not carry ignored files (build output, dependency
directories), so a child begins with a cold build.

## Slices

1. Local capture and import: PR #1147. Not yet a state: it returns a private
   child and has no hash-addressed store, no thin bundle and no apply into a
   registered workspace. Those three finish the slice, with their tests against a
   real repository with a hostile `.git/config`. No wire.
2. The chunk messages on both vocabularies, version 6, and the P model case for a
   drop mid-transfer and a restart of either side, beside the 084 cases. The
   `AskGitIdentity` message rides this bump, with a real-repository test that a
   hostile `.git/config` and a planted `~/.gitconfig` cannot change the author.
3. `Request.state`, `Joined.state`, the `seed` key and the refusals: a
   delegated child starts from the parent's work, and its commits come back.
   This slice also owns the drain: a spawn runs inside a parent turn that can
   have other tool calls in flight.
4. The `sessions.move` checkout step.
5. The page: the returned ref and commit count on the child's card.

Slice 3 is the first that can be driven live, against exit criterion 1 of #1137
with no token on the remote machine.

## Open

- **Quiescence at a spawn.** `repository_snapshot` requires a drained,
  serialized source. A spawn happens while the parent session is mid-turn, and
  its other tool calls (a parallel `bash`, an edit) can be writing. Either the
  spawn takes the workspace's write lock for the duration of the capture, or the
  capture is declared best-effort and the result says so. This draft prefers the
  lock, because a snapshot that mixes two writes is the failure the module was
  written to refuse. It needs a look at how workspace effects are serialized
  today before it is settled.
- The right `size_limit`. A 270 MB working-copy drive of the capture succeeded
  in #1147's review with sampled process-tree peaks near 790 MB, so a limit is a
  disk and memory question as much as a link one. 256 MiB is carried over from
  the session move and is a placeholder.
- Whether the return should also be offered for a child that was not handed a
  state, from an empty directory. This draft returns only what the child
  committed on top of a state it received.
- Whether the owner can name an identity per executor (a `git_name` and
  `git_email` on `[executors.<name>]`) in place of the one it resolves for
  itself. This draft sends only the resolved identity, because a new permanent
  key is not needed to unblock the drive.
- Whether `git commit --amend` and a rebase keep an existing author under the
  pinned environment. Git does, but the slice's test should run it.
- Whether `loom vm sync` (#1155) should be rebuilt on this transport. It fetches
  a guest's committed work to the host, and with `--to-guest` the other way, by
  its own path, and it cannot carry uncommitted edits.

## Addendum: slice 2 built (2026-11-03)

Slice 2 is built: the chunk messages on both vocabularies, `AskGitIdentity`,
`protocol.version` 5 to 6, and the P model case for a drop and a restart of either
end. This addendum records what it settled and where it differs from the text
above. Nothing above is edited.

**Settled: `amend` and `rebase` under the pinned environment.** Both keep an
existing author. The test runs real commits in the jail with `GIT_AUTHOR_*` and
`GIT_COMMITTER_*` pinned: a commit made with `--author` and then amended keeps its
author and takes the pinned committer, and a commit replayed by `rebase` does the
same. The pinned name is therefore the committer of every commit made or replayed
there, and the author of every commit that did not name one. A `.git/config` that
sets `user.name` and a tool-home gitconfig overwritten by the model do not change
either.

**Settled: the store's numbers.** `size_limit` stays 256 MiB for one bundle,
`total_cap` 1 GiB for the directory and `retain_s` seven days. The cap is checked
on every piece and not only at admission, because transfers in flight share the
directory, and a piece that does not fit removes its half-written file.

**Differences from the text above.**

- *Where the checks live.* "Wire" and "Git identity on an executor" put the total
  decoders in `peer_codec`. The messages are typed Erlang terms matched directly,
  and `peer_codec` is the JSON of the stable peer exchange (protocol 105), which
  none of them crosses. The bounds are in the vocabulary instead:
  `protocol.git_identity_of` for the author, and `state_transfer.take` for a
  piece, which judges the description, the size against the store's limit, the
  piece's length and its place in the declared size before the disk is touched.
- *The thin basis has no message yet.* "Capture" says a first send asks the
  receiver which of a few commits it holds. The proposal names no message for
  that question, and slice 2 adds none: `StateCapture` takes a `Basis`, `Full` or
  `Thin(base)`, and the caller chooses it. The question needs an owner in the
  loop that can ask a node, so it belongs with the first caller, in slice 3.
- *Capture is not wired on an executor.* `HostMessage.StateCapture` is fenced
  like an evolution write and served by the plane's optional `Capturing`.
  No production plane carries one, so it answers `NoStates`. `RemoteCensus.states`
  reports whether Git and an enforcing helper are present, which is what a plane
  will need to carry one.
- *The node's store has one owner.* `client/state_service` owns the directory and
  both carriers answer through it, because the store has no lock and a daemon can
  be orchestrator and executor at once.
- *Serving costs more than receiving.* There is no ranged read without new FFI,
  so `StateFetch` reads a prefix of the bundle up to the end of the piece. A whole
  bundle served that way reads the square of its size in pieces, bounded by
  `size_limit`. A ranged read is a `host/bootstrap` change if it ever matters.

**Found by building it, and settled: where the owner's identity comes from.**
107 says the owner answers from `git_identity.resolve`. `resolve` runs Git
through a sandbox broker with a `worktree_diff.Wiring`, which an orchestrator
holds only for a workspace it runs locally, and the only session that asks has
its workspace on an executor. The identity an executor needs is the operator's
global `user.name` and `user.email` on the orchestrator's machine, not anything
of the session, so it is read once for all sessions by `client/owner_identity`
through a sandboxed Git runner (`client/worktree_git`) that the daemon starts
when it has a `[distribution]` table. `worktree_git.read_global_config` runs
`git config --global --includes --null --get-regexp` with the runner's fixed
environment, the operator's `HOME`, and the operator's own `XDG_CONFIG_HOME` and
`GIT_CONFIG_GLOBAL` if set; no network, nothing writable, the state root and node
credentials masked. The host stays readable, as for every call of that runner,
because an include may name any path. `git_identity` is factored so the query
arguments and `identity_of_query` are shared with a session's own query. The
result is held for a minute, a failure included, so a session build waits at most
the lookup's 5 s once and a Git that hangs delays one build and no more. The owner
port still sends none for an incomplete identity or one that fails
`protocol.git_identity_of`. No new key, no new FFI and no wire change.

**Slices.** Slice 2 is done as above. Slices 3 to 5 are unchanged.
