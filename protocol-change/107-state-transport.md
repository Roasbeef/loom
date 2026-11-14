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
- *Serving uses a positioned read.* `StateFetch` at offset N reads only that
  piece, with `host/bootstrap.read_range`, a `file:pread/3` added beside
  `read_prefix` in the existing `host_bootstrap_ffi.erl` with the owner's
  approval. It is bounded like `read_prefix` and adds the bounds a peer's offset
  needs. An offset at or past the end is served from the last byte.

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

**Review findings, fixed and accepted.** An independent review of the PR found
three things that are fixed here. A half-written file that reached the declared
size without `finish` having run answered every later attempt with `Partial` of
the whole size, and nothing could finish it: the receiver now finishes it on the
first piece in range, a faulted finish discards it, and `send` clamps to the last
byte so it always cuts a piece in range. An abandoned `.part` held `total_cap` for
the seven days a finished state is kept: parts are now swept after an hour. And
`pull` took the `Store`, which would have made a first caller a second writer
beside `state_service`: it now takes the `Endpoint`.

Accepted for now, with the reason. `held_verdict` and `stage` call
`state_store.get`, which hashes the whole bundle to confirm a complete state, on
every `StateChunk` and `StateStatus` for it, and a flood of requests to one
owner queues in its mailbox. The peers are pinned, trusted executors, every
request serializes in the one owner's turn, and the work is bounded by the
256 MiB size limit, so neither is reachable by an untrusted peer. The cost of
`StateFetch`'s read, which the review also raised, is fixed by the positioned
read above, which the owner approved. The sender's `resyncs` bound is unchanged.

**Slices.** Slice 2 is done as above. Slices 3 to 5 are unchanged.

## Addendum: slice 3, the send direction (2026-11-04)

Slice 3 is built in two pieces. This one is the send: a delegated remote child can
start from the parent's workspace. The return of the child's commits (`Joined.state`
filled in, the pull, the ref in the parent's repository) is the next piece and is
not built. This addendum records what was settled and where the build differs from
the text above. Nothing above is edited.

**Settled: the quiescence lock.** The open question prefers a lock, and a look at
how workspace effects are serialized shows half of one. `agent_spawn` is an
`Exclusive` tool, and the strand driver starts an `Exclusive` call only when none
of that strand's other calls is running, so a spawn already drains the parent's
own turn. It does not drain the session's other strands. `client/workspace_gate`
is the missing half: every workspace-side tool call of a session runs inside its
shared side (`wiring.run_gated`), and a capture runs inside `exclusive`. A capture
asks for the workspace, new calls wait at the gate, the calls in flight finish
within 30 seconds or the capture is refused (`NotQuiet`) and the gate reopens, and
the gate is held for at most 330 seconds, after which it reopens under the capture
and the capture's late answer is `Lapsed`, so its result is discarded. A call that
waits at a closed gate gives up in band after 340 seconds. A background process a
tool left running (`bash` with `&`, a code-mode execution) is not a call in flight
and is outside the gate; capture is a snapshot of the working bytes and the spawn
says so. A code-mode program's own `agent_spawn` cannot ask for the workspace,
because the program is a tool call that holds the gate its capture would wait for.

**Settled: how the parent asks.** `agent_spawn` gains no argument. `context`, which
already says what a child starts with, gains a third word, `my_workspace`, offered
only where `on` is. It starts the child with a fresh conversation and a copy of the
workspace. The spawner's `seed` key is the owner's ceiling on the receiving
machine, as 107 says, and the sending side has no switch of its own: the sender
cannot read the receiver's table, so the receiver's refusal, which names the key, is
how a model learns the ceiling. The text above says the model "may narrow this to
none"; with the ask explicit and off by default there is nothing to narrow.

**Differences from the text above.**

- *The child shares its session's workspace.* 107 says the receiver applies into
  "the child's workspace" and starts the child there. A remote child is a strand in
  the delegate session of its (spawner, parent) pair, which has one workspace, and
  the Agency has no per-strand directory. The copy is therefore a repository at
  `seeds/<name>` under the spawner's `directory`, the name is a digest of the call
  site and the state, and the child's brief is told where the copy is and which
  branch it is on. The child is still a strand that can read the rest of the
  workspace.
- *Only a `directory` placement takes a copy.* A spawner placed on an `executor` or
  a `pool` has its workspace on another machine, and applying a state there needs an
  apply message in the executor vocabulary that 107 does not list. Adding one is a
  second change to the version 6 vocabulary, so the receiver refuses with
  `StateRefused` and says why. `Worktree` apply stays unused by a spawn.
- *The copy is made in a stage and renamed in.* `into_clone` makes
  `destination` and `destination/.git` writable roots after `git init`, which in a
  session's workspace would let a concurrent child swap them. The apply runs in
  `<state root>/seed-staging`, which no session can write, and the finished
  repository is moved into the workspace with one rename. A copy at its final name
  is whole, which also makes a resent spawn idempotent. The stage cannot be under
  `repository-snapshots` because a mask wins over a write grant inside it, and the
  rename needs the spawner's directory and the state root on one filesystem. A
  failure to rename is a `StateRefused` that says so.
- *The `states` mask.* `workspace_policy.established_masks` names
  `<state root>/states` and the daemon root makes it before any session is admitted.
  The sandboxed Git runner shares the mask and lifts it for one call,
  `git bundle unbundle`, through `worktree_git.run_reading_store`; every other call of
  the runner and every session tool finds the store masked.
- *No thin basis.* 107 and the slice 2 addendum leave the question "which of these
  commits do you hold" for the first caller. Asking it needs an owner that can run
  Git where the receiver's repository is, which for a `directory` placement is a
  repository that does not exist yet. Every state a spawn sends is full, and the
  `Basis` that `StateCapture` and `capture_against` accept stays for the slice that
  returns a child's work, where the sender holds the base.
- *The sender holds the state.* A state captured on an executor would have to be
  relayed into the orchestrator's store for the outbox to resend it. That relay is
  `state_transfer.pull`, which exists, and the executor's `Capturing` is wired
  (`executor_plane.factory_capturing`) and tested through the real host. The session
  assembly does not use them yet: a session whose workspace is on an executor asks
  for a copy and is refused with a reason that says so. A session with a workspace on
  the orchestrator's machine captures it directly, through the same
  `client/state_capture`.
- *`Joined.state` is a field and nothing fills it.* It is `None` until the return.

**Safety checks settled.** A hostile `.git/config` on the parent (an fsmonitor
program and a clean filter) is neither run by the capture nor by the apply; the test
plants a canary the programs would create. The spawner's directory is the only path
an apply can write into, and it comes from the table; the copy's name is a digest
and no peer text reaches a path. A spawner with `seed = "none"` is refused before a
session is found or a byte is stored.

**What the live drive still needs.** A session on the box with a `[distribution]`
table, a `[spawners.box]` on the laptop with `directory` and `seed = "workspace"`,
and a model call `agent_spawn(on: "laptop", context: "my_workspace")` from a session
whose workspace is on the box. The transfer over a real TLS distribution link, and
the capture under Linux's bubblewrap and Landlock, were not exercised here.

**Slice 3, send direction: changes after review (2026-11-04).** An independent review
of the build above found the following, all fixed, and two statements above are
narrowed.

- *The final destination is not safe from a session.* The apply's stage is
  daemon-owned, but the rename into `<directory>/seeds/<name>` is made by the daemon,
  outside any jail, through a directory that any session on that workspace can write.
  A child that made `seeds` a link would have had the rename land the repository
  elsewhere. Now `seeds` must be a real directory at its canonical path before the
  move, a name that is a link or anything but a real directory is refused (it is no
  longer taken for a finished copy), and after the move the copy's canonical path must
  be exactly `<directory>/seeds/<name>`, else what the daemon placed is removed and the
  spawn is refused with a constant reason. **The residual:** check-then-rename is still
  racy against a child that swaps `seeds` in the window between the check and the
  rename. The after-check then finds and removes what landed, but the rename itself
  has happened outside the jail, with a repository the daemon made from a bundle at a
  name the daemon chose. Closing it for good needs a destination no session can write,
  which is a design change for a later slice.
- *An apply could not outlive its asker, and attempts shared a stage.* The first ask
  waits 30 seconds and the sandboxed Git allows ten minutes, so a state needing more
  restarted from nothing on every retry and never finished, and the attempts, which
  shared one stage name, deleted each other's trees. Now every attempt has a stage of
  its own (the name and a unique integer) and deletes only that, `seed-staging` is
  emptied when the daemon starts, and the apply runs in a process of its own under a
  deadline of its own (11 minutes), so an asker that stops waiting is answered
  `NotYetOpen` ("ask again") and the apply goes on. A resend finds the finished copy
  before it reads the store, so it is quick and survives the bundle's expiry. A claim,
  a marker directory made atomically beside the stages, keeps the asks that arrive
  meanwhile from each starting a full apply of the same copy; a claim older than 15
  minutes is taken over. Duplicates remain correct if they ever happen, because stages
  are unique and the attempt that renames second finds the name taken and removes its
  own stage. The claim is a file-system marker and not a process, so it needs no
  owner and survives nothing: a restart sweeps it.
- *Unplaced tools bypassed the gate.* Extension and MCP tools have no placement and
  went to the owner untouched, so a filesystem server could write during a capture.
  They run on the shared side now. `agent_spawn` is placed on the owner and does not
  wait on the gate it closes.
- *The hostile-configuration claim is narrower than it read.* The guarantee is that
  a program a repository's configuration names cannot write outside the jail, on
  either machine; for a filter the jail is the guarantee, and the `-c` overrides cover
  hooks and the file-system monitor. The test now attaches the filter with a
  `.gitattributes`, and a control runs the same configuration under ordinary Git
  outside the jail and shows the program fires. "Never run" above should be read as
  "cannot write outside the jail".

**Slice 3, send direction: second review (2026-11-04).** Three more findings, fixed.

- *The after-the-move check no longer deletes.* The previous paragraph said a copy
  that landed away from its name is removed. That delete is made outside the jail, by
  path, through a tree a session that already won the first race can still rearrange,
  and a link swapped into it mid-walk would have the daemon delete its own private
  files. The daemon now deletes nothing there. It refuses with the same constant
  reason and leaves the repository where the rename put it: a repository the daemon
  made from a bundle at a name it chose, in a place the session could already write.
  The refusal is logged by the spawn host with the rest of the final refusals. The
  stage and the claim, which are daemon-owned under `seed-staging`, are still removed.
- *A late failure is answered, not repeated.* An apply that failed after its asker had
  gone sent its refusal to nobody, released the claim, and every retry ran a full
  apply again. The attempt now keeps a verdict, `<name>.refused` in `seed-staging`
  (the reason, printable and at most 512 bytes, written to a temporary file and
  renamed), before it releases the claim, and an ask for a copy that is not yet there
  looks for the verdict first and answers `StateRefused` with it. The startup sweep
  clears it, and a resend with a different state has a different name.
- *Test order.* The tests that look at `seed-staging` now wait for it to drain, since
  the attempt removes its stage and claim after the rename has made the copy whole.

## Addendum: slice 3b, the return direction (2026-11-04)

Slice 3 is now whole: a child started from the parent's workspace finishes, and the
commits it made on top of that workspace arrive as one ref in the parent's repository.
This addendum records what the build settled and where it differs from the text above.
Nothing above is edited. No wire constructor was added and the version stays at 6:
`Joined.state` and the optional `remote_children` members were already in "Wire".

**What comes back.** Only commits. The receiver captures `HEAD` thin against the tip of
the state the child was handed, with the working tree left unread
(`repository_snapshot.capture_commits`, the existing capture with a `CommittedOnly`
content: no inventory, no attribute check, no comparison of the index with the tree).
Edits the child left uncommitted, staged or untracked do not travel, and the child's
report says that there were some. A child that was handed no state, or committed
nothing, returns nothing, and a `HEAD` that does not descend from the sent tip (a child
that reset or rewrote what it was given) is a refusal with a reason.

**Settled: who moves the bundle.** 107 says the parent pulls with `StateFetch`. The
build pushes: the receiver sends from its store to the parent's over the orchestrator
port with `state_transfer.send`, from inside the join. The join is the one message the
receiver is sure to get after the child's run has ended, and the parent is connected for
its duration, so the push needs no message the vocabulary lacks and no timer on the
parent. The reasons for a pull still hold in part and are met differently: the receiver
keeps what it learned in a verdict file under `<state root>/seed-returns`, a directory no
session can read, so a restart of the receiver or the end of the parent's turn loses
nothing, and a transfer that did not finish resumes at the parent's offset on the next
join. A captured state that is not yet in the parent's store is `Pending` to the parent;
a `Ready` carrying a state always means the bundle is already in the parent's store.

**Differences from the text above.**

- *The join waits for the return.* A seeded child's entry is `Pending` while its commits
  are being captured and moved (a join waits 1.5 s for the work before answering), so the
  parent is not told a child finished until the matter of its commits is decided: moved,
  none, or given up. The work runs in a process of its own under a 14-minute deadline,
  claimed so concurrent joins do not each start it, and a transfer that does not finish is
  tried at the next join up to five times, then ends in a refusal that names the hash the
  commits are kept under in the receiver's store.
- *A return does not fail a child.* A refused capture, a declined bundle, a copy swapped
  for a link and a transfer that never finishes each append one fixed sentence to the
  child's report. The child's text is otherwise unchanged.
- *The ref and its sentence.* The ref is `refs/loom/children/<child>/<tip8>`, where
  `<child>` is the last segment of the daemon-minted strand (`state_object.child_component`
  accepts lower-case letters, digits and single dashes and nothing else). The model-visible
  text gains one paragraph naming the count and the ref, and the Git commands to use; the
  ref and the count are built from validated values, and a refusal's reason is cut to 300
  bytes.
- *The apply also unpacks the sent bundle.* The sent tip of a dirty workspace is a
  snapshot commit that only the bundle ever held, so the returned bundle's one
  prerequisite is a commit the parent's repository lacks. `apply_returned` unpacks the
  sent bundle first when the sent tip is absent, which writes objects and no ref; it does
  not create `refs/loom/in/<hash8>`. The ref the apply makes is the one ref.
- *Prerequisites are exactly the sent tip.* The returned description must name the sent
  tip as its base and the bundle header must list it as its only prerequisite. A child
  that merged older history or rewrote below the sent tip lists another boundary and is
  refused, so the parent is only ever asked to supply what it sent.
- *The workspace gate's exclusive side.* The shared side is not enough. The apply unpacks
  objects that nothing references until the ref exists, and every workspace tool call
  holds the shared side, so a `git gc --prune=now` or `git repack -ad` from one of them
  would run beside the apply. The apply takes `workspace_gate.exclusive` with the capture's
  bounds (30 s drain, 330 s hold). A gate that does not go quiet is a reason to try again:
  it is told in the report and not recorded, and the next wait applies again; a hold that
  lapses discards the answer and the retry finds the ref already made. A test holds the
  gate closed during an apply and shows a tool call cannot enter, and another holds a
  tool call open and shows the apply is refused as retry and writes nothing.
- *The apply is for the workspace the child started from.* The stub records the canonical
  directory the spawn captured, as a `seeded` member that is absent for every other
  child, so a stub written earlier decodes unchanged. The apply runs only when the
  session's workspace resolves to that directory now, and only into a primary checkout.
  A session moved to another machine, or whose workspace changed, is told its commits
  could not be applied; they stay in the parent's store for its retention.
- *Decided once.* The answer is written to the stub once (`remote_child.returned`, a
  compare-and-set on a settled seeded stub with nothing decided), so a second wait tells the
  same sentence, applies nothing, and one child makes at most one ref. A replayed return that
  does reach the apply is `AlreadyThere`; a ref that exists with another tip is refused and
  never moved.
- *The strip.* `remote_children` rows gain `commits` and `returned_ref`, written only for a
  child whose commits were applied. A client built before them ignores both, and a client
  that reads them treats an incomplete or malformed pair as absent. The card cannot tell
  "no commits" from "could not be returned": both leave the pair absent, and the report
  carries the difference in words.

**Costs and limits accepted for now.**

- A linked-worktree workspace (095) is refused by the apply, which takes only a primary
  checkout whose `.git` is a directory. The path of the primary checkout cannot be read
  from a `.git` file the model can write, and a daemon-owned record of it is not wired to
  the session assembly. A session in a linked worktree is told its commits could not be
  applied.
- Commits made after the join first reported the child finished are not returned; the
  first decision is final. A child sent a message after it settled and given more work
  returns nothing of the second run.
- A crash between the receiver's answer to a spawn and the write of its record loses that
  child's return. The window is two calls wide and the commits stay in the child's copy.
- `seed-returns` holds a record and a verdict of a few hundred bytes per seeded child and
  has no sweep beyond clearing claims at start.
- An executor or pool placement takes no copy and so returns nothing, as in the send
  direction.
- For a dirty workspace, `hold_sent` writes the snapshot commit, which holds the
  parent's tracked and untracked working bytes at spawn time, into the parent's `.git`,
  and the child's ref makes it reachable for good. `git log --all`, `git push --mirror`
  and `git bundle create --all` therefore carry it. The ref is the only one made, but it
  is a ref like any other once it exists.
- When the 330 s exclusive hold lapses while an apply is still running, the gate admits
  tool calls again, and a `git gc --prune=now` between the walk of the returned tip and
  `update-ref` could leave the ref naming a pruned commit. It needs an apply of over
  330 s and a prune in a narrow window, and is accepted.
- Added after review: the apply also requires the returned tip to descend from the sent
  tip (`merge-base --is-ancestor`, constant reason, no ref written), because a header
  that lists the sent tip as its prerequisite does not say what the tip is built on. A
  refused or faulted capture reaches the parent as a fixed sentence and the detail goes to
  the receiver's log, since Git's words can name the receiver's directories.

**What the live drive of exit criterion 1 still needs.** Nothing here was run over a real
TLS distribution link, under bubblewrap and Landlock, or by a model. The drive is a box
orchestrator with a `[distribution]` table and a session whose workspace is a primary
checkout on the box; a laptop with `[spawners.box]` set to a `directory` and
`seed = "workspace"`; a model call `agent_spawn(on: "laptop", context: "my_workspace")`;
the child committing in `seeds/<name>` on the laptop; and then the box's `agent_wait`
reporting the ref, with `git log refs/loom/children/...` on the box showing the commits and
the box's checkout untouched. It also needs the keeper link to stay up between the child's
end and the join, a Git identity on the laptop for the child's commits (the executor
identity path of slice 2 does not apply to a `directory` placement), and the box's session
to be outside a code-mode program when it waits, since a program holds the gate's shared
side.

## Addendum: slice 5, the page says what happened (2026-11-04)

Slice 5 draws what slice 3b records, and says why a remote spawn failed. No wire member,
constructor or version changed: both pieces read fields the `remote_children` snapshot and
the agency's failed result already carry.

**The returned work.** A card of a remote child whose entry has the `commits` and
`returned_ref` pair gains two quiet lines, `N commits returned` (`1 commit returned`) and the
ref. `agent_roster.Line` carries the pair as one `Option(Returned)`, so a line has both or
neither, and the ref is made one line there. The page draws the count and the ref as text
nodes, and the ref is also the `title` of its line, because a card cuts a line at its edge and
the end of a ref is the part that tells two apart. A child that returned nothing draws the
card exactly as before. The ref is plain text and not a copy control: `<loom-copy>` copies
only the sign-in commands the page composes itself, and teaching it a ref is a larger change
than this slice.

**The reason of a failed spawn.** A refused remote child already showed its reason on its
card (`Failed · <reason>`, from the entry's `summary`). What had no reason was the
transcript's spawn line of a call that failed, which read `Spawned · failed` because the
failed result's details were not read. `turns.Spawned` gains `refusal`, the `reason` detail
of the agency's refusal outcome, made one line and cut to 300 characters, and the line reads
`Spawned · failed: <reason>`. A failure that recorded no reason reads as it did. The reason
may quote what a remote orchestrator said, so it is a text node like every other word from
another machine.

**The wording of a slow read.** A read of a slow orchestrator no longer claims an unknown
mutation outcome: `ui_top.read_failure` words silence as "the orchestrator did not answer"
for every read, and `top_relay.describe`'s "not known whether it happened" is kept for the
calls that change something. This was done before this slice (`8a793e6ef`) and is recorded
here so the next reader does not look for it.

## Addendum: live drive of exit criterion 1 (2026-11-04)

The drive that the slice 3b addendum said was still needed has been run, on commit
`5f4ebffa5`. It was one Mac with two orchestrators as two daemons under separate home
directories on the loopback address (a box with a session whose workspace is a primary
checkout, and a laptop with `[spawners.box]` set to a `directory` and
`seed = "workspace"`), provisioned with `loom distribution provision --static` and
`install --home`, and a scripted model provider. The link was TLS distribution. It was
not run under a real model, over a real network or on Linux under bubblewrap and
Landlock. Nothing above is edited, no wire constructor was added and the version stays
at 6. `docs/distributed-setup.md`, "Quick start D", is the procedure as it was run.

**What passed.**

- The laptop's copy under `<directory>/seeds/seed-*` equalled the box checkout, the
  modified and the untracked bytes included, and the box checkout was unchanged: the
  hashes of its files and the list of its refs were equal before and after.
- A child that committed in the copy returned its commit, which arrived on the box as
  `refs/loom/children/<child>/<tip8>`. The ref's history is the box's history, then the
  `Working snapshot` commit holding the dirty bytes, then the child's commit.
- A laptop table with `seed` unset refused the spawn with a `StateRefused` that names
  `[spawners.box] seed = "none"`, and the model saw that sentence.
- A 100 MiB workspace (a bundle of 104,890,392 bytes) crossed the loopback link in
  about 1.3 seconds. The laptop daemon was killed with SIGKILL after 40,632,320 bytes
  had arrived. After it restarted, the sender continued from the partial file's offset,
  the whole bundle was in the laptop's store 2.6 seconds after the restart began, and
  the child ran and returned its commit.

**Defects the drive found, fixed on `distributed/drive-fixes`.**

- *Stage leak and name reuse.* A capture's stage was named from a per-VM counter and a
  failed capture left it in `<state>/repository-snapshots`, which was never swept. After
  a restart the counter began again, and the first capture could draw the name of a
  stage a failed or killed capture had left, and was refused with `snapshot stage already
  exists or cannot be created`. `state_capture` now removes the stage when a capture
  fails (it is the caller that knows the Git calls have settled, which `repository_snapshot`
  does not), draws the name from random bytes, and sweeps the directory when the daemon
  starts, as `seed-staging` already was.
- *A misleading identity error.* The snapshot commit uses the operator's global Git
  identity alone. A repository with its own `user.name` and `user.email` still failed
  when `~/.gitconfig` had none, with `invalid arguments: ... user.name and user.email are
  incomplete`, and the session-open warning said to configure the identity "in the
  repository". Both now say that the identity belongs in the operator's global Git
  configuration, with the command, and that a setting in the repository itself is not
  used for the snapshot. The failure class is unchanged: the Agency reports a capture
  failure as an invalid argument, and no existing refusal fits better (`RemoteRefused`
  would blame the other orchestrator).
- *No success logging.* Only refusals were logged. The sender now logs
  `remote_spawn.state_sent`, the receiver `remote_spawn.seed_placed` and the parent
  `remote_spawn.commits_applied`, each at info level with short hashes, sizes and names,
  and no path of either machine.

**Observed and not fixed.** These are recorded so that the next reader does not
rediscover them.

- `.codemode/.gitignore` and `.codemode/home/gitconfig` appear in the operator's
  checkout when a session opens in it. A capture leaves untracked `.codemode` paths out
  of the bundle (`repository_snapshot.runtime_path`), so they do not travel, but they
  show in the operator's `git status`, and they make a checkout that nobody touched
  differ from the one before the session opened.
- After a SIGKILL of the receiving daemon, `daemon.session_start_failed` with `class`
  `lease_held` is logged at error level for about 45 seconds, once per attempt, until the
  dead daemon's writer lease expires. Nothing is lost and the spawn waits, but the level
  reads as a fault.
- The sender pays for the capture and for the local store before the receiver can refuse
  a spawn. A laptop whose `seed` is `none` is only asked after the box has bundled the
  workspace, so a refusal costs the box a capture and a stored state that retention later
  removes. The refusal is correct and the order is the cost of sending the state with the
  request; asking the receiver's terms first would need a message the vocabulary does not
  have.

## Addendum: slice 4a, the executor applies a state (2026-11-04)

Slice 3 left a placement the spawn refused: a spawner on an `executor` or a `pool` has
its workspace on another machine, and applying a state there needs an apply message in
the executor vocabulary, which 107 does not list. This addendum adds it, and the
capture that returns a child's commits from an executor's scope. It is one wire change
inside the unreleased protocol version 6 (the last tag is v0.3.2), so it is an addendum
here and not a new protocol, and `protocol.version` stays at 6. Nothing above is edited.
The orchestrator side that calls either message (the seed from a session whose
workspace is local, the return of a child's commits, and the executor placement of a
spawner) is not built; it is the next piece, and so is the `sessions.move` checkout step
of slice 4.

**What was added.**

- `HostMessage.StateApply(session, incarnation, token, state, reply)`. `state` is the
  description of a state that the executor's store already holds, put there by
  `StateChunk` and `StateStatus` as any state is. The reply is `Result(String,
  Refusal)`: the tip the tree has checked out, or a refusal. The executor
  imports the state into the workspace's root repository, where the objects and one ref,
  `refs/loom/in/<hash8>`, land with the connectivity walk, the guarded `update-ref`, the
  disabled hooks and file-system monitor and `GIT_NO_LAZY_FETCH` that `state_apply`
  already uses, and it never fetches. It then checks out the session's branch
  `loom/<session>` at the tip, in the scope's own worktree, with `checkout -B`
  (`state_apply.Reset`).
- `StateCapture` gains `content`, of the type `state_object.Content`: `WithWorkingTree`
  is the capture as it was, and `CommittedOnly` reads no working tree and makes no
  snapshot commit, so its tip is `HEAD` and only commits travel, thin against the basis.
  It is the capture of 3b (`capture_commits`) made available to the wire, with the
  working tree left unread so that a child's uncommitted edits stay where they are.
- The reply of `StateCapture` becomes `Result(Option(State), Refusal)`. A committed-only
  capture of a tree whose `HEAD` is the thin base has nothing to deliver, and a caller
  that returns a child's work must tell that from a refusal. `None` is only ever that
  answer. This is a change to a message of version 6 that no caller used yet.

**The fence.** `StateApply` is fenced exactly as `StateCapture` is: the scope's
incarnation and attach token are judged first, in the host, by the ledger's own check, so
a request from a dead runtime learns that it is dead (`StaleToken`, `StaleIncarnation`,
`ScopeNotOpen`) whatever the plane can do and the plane never sees it. A plane with no
capturer answers `NoStates`. What the workspace decides about the state is answered as a
refused capture is, `ExecutorFault(reason)`, so a caller tells a dead runtime
(`StaleToken`, `StaleIncarnation`) from a workspace that cannot take the state by the
variant. A first draft carried a separate `ApplyAnswer` with `Applied` and `Refused`; a
review found it a second spelling of the same distinction, and it was dropped.

**The run is not cancelled with its requester.** The other state requests run in a run
of their own that the host cancels when the requester exits, because an abandoned
capture only leaves a stage. An apply cut off in the middle of `checkout -B` would leave
HEAD at the old tip with a partly written tree, which every resend would then refuse for
holding changes. The apply therefore runs to its end, as an ordinary run does, and a send
to a requester that has gone is harmless. A test sends the request from a process that
exits at once and finds the tree whole and the resend answered with the tip.

**Filters and transports.** A `.gitattributes` in the bundle's tree can attach a filter
driver the executor's configuration defines, and a checkout runs its `smudge` command on
each file. The first draft relied on the jail alone. A test showed the program does run
inside the jail and can write where the jail lets Git write, which is the repository's own
`.git`. Every checkout of `state_apply` now lists the `filter.<name>` drivers its
configuration names and empties each one's `smudge`, `clean` and `process` for the call and
turns `required` off, and refuses a driver name that cannot be written on a command line
faithfully. The guards also set `submodule.recurse=false` and `protocol.allow=never`. The
test attaches a filter to a hand-made bundle, because capture refuses such a tree, and
asserts that the marker its program would write is not created, with a control in which the
operator's Git runs the same program.

**The mode requirement.** Only `mode = "worktree"` takes a state. A shared workspace has
no tree of the scope's own: its sessions all work in the root, and moving a branch there
would move it under every other session. It is refused with a reason that names both
modes. The scope's repository is the canonical root the configuration fixed
(`Custody.repository`), and the tree is the scope's directory; neither is read from the
tree, whose `.git` file the session can rewrite.

**A scope's tree is fresh.** The apply runs before the child's first turn, and replaces the
tree's checkout. A tree with a change in it, staged, unstaged or untracked, is refused. A
tree on another branch, in another repository, or whose `.git` is a link or is not a plain
file is refused before anything is written. A tree that already contains the tip is
answered with the tip and not touched, so a resend after a lost reply is harmless, including
after the session has begun to commit on top. A dirty state's snapshot commit is checked
out as it is: the child sees the sender's uncommitted work as committed content, and
`git log` shows one commit on its branch with the subject `Working snapshot`.

**Committed-only capture in a linked worktree.** `capture_commits` refuses a repository
that resolves anywhere but the top of a primary checkout at its directory, which is what
stops a session from planting a `.git` that names another repository. A scope's tree is a
linked worktree, so `repository_snapshot.capture_committed` takes a `Checkout`, `Primary`
or `LinkedTo(common_dir)`. For a linked worktree the capture is refused unless the top of
the tree is the directory, its Git directory is one of that repository's `worktrees`, and
its common directory is the one the caller names from its own configuration.

**What it costs.**

- The apply hashes the bundle twice: `state_store.get` confirms the stored state, and
  `state_apply` compares the bytes with the description. Both are bounded by the size
  limit and run in a run of their own, off the host's turn.
- It takes no worktree gate. Git takes its own locks, so a concurrent `git worktree add`
  for another scope can make an apply fail with a lock error, which is a refusal the
  caller may resend.
- A tree the session has already committed in, whose history does not contain the tip, is
  moved if it has no change in it. The previous tip stays in the reflog. The "before the
  first turn" ordering is enforced by nothing in this slice: the host cannot tell a tree
  the session has worked in from a fresh one beyond the checks above. The orchestrator
  side, which is the next slice, must refuse to send `StateApply` after a session's first
  turn. `worktrees.open` adopting a tree that holds an earlier incarnation's commits is a
  gap that was there before this slice and is accepted.
- The `Capturer` holds a read handle on the node's store, so `state_capture.new` takes the
  store. That is a change to the signature of the module's constructor and no more.

**What stays unbuilt.** No orchestrator code sends either message. The seed of a session
whose workspace is on an executor (`state_transfer.pull` into the orchestrator's store,
then a send to the target), the return of a child's commits from an executor, the
`executor` and `pool` placements of a spawner taking a copy, and the `sessions.move`
step are later work. Nothing here was run over a real TLS distribution link or by a
model.

**Not touched.** `peer_codec` is the JSON of the stable peer exchange (protocol 105) and,
as the slice 2 addendum says, none of the state messages crosses it, so it has no
encoder or decoder to extend. The P model of the transfer
(`protocol/models/state-transfer`) models the pieces and the store and not the capture or
the apply, which are local to an executor, so it needs no new transition.

## Addendum: the filter listing and the checkout share a tree (2026-11-04)

The "Filters and transports" paragraph of the slice 4a addendum says that every checkout of
`state_apply` lists the `filter.<name>` drivers its configuration names. A review of the
merged slice found that this was not true of `Worktree`. The listing ran in the
repository, but `git worktree add` performs its checkout in a subprocess inside the new
tree, and a conditional include in the repository's `.git/config`, one that matches
`onbranch:loom/**` or the Git directory of a linked worktree, can pull a `filter.<name>`
driver into that tree alone. A session that wrote the configuration earlier could name a
driver the listing never saw. The jail still bounded what its program could do, so the
consequence was the one the first draft of that paragraph already described, a write
inside the repository's `.git`, and the claim was wrong rather than the sandbox.

`Worktree` now runs `git worktree add --no-checkout -b loom/<session>`, which writes no
file, and then `git reset --hard` from inside the new tree through the same `checked_out`
call as the other placements. The listing and the checkout therefore read the
configuration of one tree, and the paragraph is true of every placement. A failed
checkout removes the tree this call made, as a failed `git worktree add` did, and leaves
the branch, which is how `git worktree add -b` behaved. `Clone` and `Reset` already listed
and wrote in the directory they checked out and are unchanged. A test gives the
repository an `includeIf` on the linked worktree's Git directory that defines a
`filter.evil.smudge`, attaches the filter to a hand-made bundle, and asserts that the
marker its program would write is not created and that the file arrives intact. A control
adds a worktree of the same commit with the operator's Git and finds the marker, and the
test fails against the previous `worktree add` form.

## Addendum: slice 4c, the checkout step of `sessions.move` (2026-11-04)

Slice 4 is built for the case that exit criterion 2 of #1137 names: a session that works in
a directory on its orchestrator moves to another orchestrator, and its checkout arrives on
an executor that orchestrator reaches. No wire constructor was added and the version stays
at 6: the step sends `StateChunk` and `StateStatus` to the executor's host as any state is
sent, and one `StateApply`, both of which slice 4a built. Nothing above is edited.

**What was added.** `client/move_checkout` is a step of the mover, taken after the stop and
before the close by a session whose registration names no executor and no pool. In order:

1. The directory is captured with its working tree and full history (`state_capture.capture`,
   `Full`). An uncommitted edit and the untracked files that `.gitignore` does not exclude
   become one `Working snapshot` commit on top of the directory's history, as they do in a
   spawn's seed, authored by the operator's global Git identity. The checkout therefore
   arrives as committed content, and the session's first `git status` there is clean.
2. The state is sent to the executor with `state_transfer.send` over `state_link.via_host`,
   which asks how far the executor has got and resumes at that offset.
3. The source attaches a scope for the session on that executor (`workspace.attach` over the
   stopped session file, with a new `owner_services.declining` owner), sends one `StateApply`
   under the scope's own incarnation and token (`Hands.apply_state`), and closes the scope.
   The close removes the tree and keeps `loom/<session>`, which the apply moved to the tip,
   and writes the clean-close cell that the six steps already read. The receiver attaches
   at the next incarnation, and its plane recreates the tree from the branch.
4. A reserved cell in the session file, `client/move/checkout`, records the operation, the
   captured state and whether the landing was done.

The place comes from the source's configuration: `[orchestrators.<name>]` gains
`checkout_executor` and `checkout_workspace`, given together. The destination must list an
executor of the same name that reaches the same machine. The importer checks that the name
is listed and cannot check that the two names reach one machine.
`sessions.move` refuses a local session, before it stops anything, when the destination names
no place, when this daemon does not list the executor, or when the directory is not the top of
a primary checkout (a linked worktree has a file where the repository directory is).

**Ordering.** Nothing enforced "never admit a turn on the destination before the apply is
answered" in slice 4a, and this slice enforces it by construction: the destination is not told
of the session until the checkout is recorded as done, so it cannot admit a turn for it earlier.
The apply is also the only writer of the tree, the source's slot is stopped, and the scope the
source attached is closed before the destination's attach.

**Differences from the text above.**

- *The source's row is not rewritten.* The brief for this slice, and "A session move with a
  checkout" above, rewrite the stopped session's registration from local to executor and
  workspace. The build hands the later steps a copy that names them (`move_checkout.relocated`),
  and the manifest carries it to the receiver, which builds its own registration from it. The
  source's row is read again at each run and is never changed, so a move that is abandoned
  leaves a plain local session that opens in its directory as it did, with no reverse edit to
  get wrong, and the catalogue needed no schema change. The cost is that the choice of place is
  read from the configuration at each run, which is why it is a configuration key and not an
  argument of the command.
- *The apply needs an open scope.* `StateApply` is fenced, so the source attaches a scope for
  it. The text above says "send it to the target's registered workspace, and apply it". The
  scope exists for the length of one request and is closed, and the destination's first attach
  costs an extra incarnation. A source that is lost between the attach and the close leaves
  the scope open, and the next attach rebinds it.
- *The checkout is a seventh step.* `session_move.Step` gains `Checkout`, between `Intent` and
  `Close`, so `LOOM_MOVE_CRASH_AFTER=checkout` can halt the daemon after it.
- *The receiver is the one that already existed.* The orchestrator-to-orchestrator move needs
  no change on the receiving side: it sees a closed scope, a manifest that names an executor and
  workspace, and a session file that also carries the step's cell.

**Resuming.** The step is entered again after a crash, a stall and a restart, and takes what is
left. A cell for this operation with a captured state is used again while the source's store
holds the bundle, because capturing a dirty directory again would make another snapshot commit
and another hash, and the transfer would start at the beginning. A cell for another operation
is ignored and replaced. A crash after the capture resumes at the send, after the send at the
landing, and after the landing but before the cell says so lands again: an apply of a tip the
tree already has answers the tip and changes nothing. Each of those is a test, with a link
that drops after the first piece for the transfer.

**Refusals.** Every failure names the stage (`capturing the workspace`, `sending the state to
the executor`, `putting the checkout in the executor's tree`). What resending cannot change
abandons the move and the session stays on the source, resident and openable, its directory as
it was: a directory the capture refuses, a `shared` workspace on the executor (the apply
refuses it and names both modes), a name the executor does not serve, a tree that holds
changes, a store that declines the bundle. What may pass stalls it: no answer from the
executor, a fence race, an executor that is still preparing the workspace. A configuration
that makes the executor refuse every attach, such as a misspelt `checkout_workspace`, therefore
stalls and does not abandon, because the attach reports its refusal as a string that the mover
cannot tell from a connection failure. A directory member ends it with `sessions.move
--abandon`; otherwise it is fixed in the file and the daemon restarted.

**Costs and limits.**

- The capture runs against the source's stopped session, and the stop does not quiet other
  sessions or processes that work in the same directory. The precondition of
  `repository_snapshot` is still the operator's to keep.
- The state is the whole history, not a thin bundle: the source cannot ask the executor what it
  holds (the open question above), so a repository the executor already has is sent again in
  full, up to `size_limit`, and a larger one is refused.
- The session's workspace-private memory stays on the source, as for every moved session. A
  strand's remembered working directory is a path under the old workspace and is revalidated at
  each use, so the first tool call that relies on one may be refused until the model sets
  another.
- The session file the receiver gets carries the step's cell, which names the captured state.
  It is a few hundred bytes and is not read again.
- The executor keeps the state in its store for seven days and the branch indefinitely, as for
  any state and any scope.
- A session in a pool that has not attached yet has no workspace to carry and is refused.
  The web home and the terminal's candidate read (`move_candidates`) still offer no Move for a
  local row; `loom sessions move ID --to NAME` is the way in.

**Not built.** A thin basis for the checkout, which needs a question to the executor. A
local session on a `shared` executor workspace, which `StateApply` refuses by design. Moving
a session whose directory is a linked worktree. A candidate read that tells the operator which
orchestrators have a place for a local session. Moving the checkout back from the executor to
a directory on a laptop. Nothing here was run over a real TLS distribution link or by a
model, and the live drive of exit criterion 2 is not done: it needs a laptop daemon with
`[orchestrators.box]` naming `checkout_executor` and `checkout_workspace`, a box that is both
orchestrator and executor with a `worktree` workspace, and `loom sessions move` on a session
that has run in a dirty repository.

**Slice 4c: changes after review (2026-11-04).** An independent review of the build found
the following. Two are fixed here and two are accepted, with the reason.

- *A directory member does not move a local session yet.* A member's mover swaps the owner
  record from `Serving` to `Moving`, and a local session's record is `Local`, which no
  swap handles, so the move would stall for good (the abandon fails the same way) or, with
  no record yet, end in a tombstone the receiver never got. `sessions.move` now refuses such
  a move before it stops the session. A member path needs `Local -> Moving` and
  `Moving -> Local` swaps in `client/directory/ownership` and arms in the mover, and is not
  built.
- *A scope record from an earlier move names the executor.* The attach follows the file's
  scope record whatever the placement says, so a record left by an abandoned move, followed by
  a move whose `checkout_executor` differs, would have put the checkout on the first executor
  and told the receiver the second. The landing now refuses a record that names another
  executor, with the executor named.
- *Accepted: a retry after an abort can deliver the earlier snapshot.* `StateApply` treats a
  tree that already contains the tip as applied, and "contains" is ancestry
  (`state_apply.holds_tip`), which a resend after the session has committed needs. If a move is
  abandoned after the landing, the operator discards the uncommitted edits in the directory,
  and the move is asked for again, the new tip is an ancestor of the executor's earlier
  snapshot and the tree is left at the snapshot. The move's report does not say so. Tightening
  the apply to equality would break the resend rule of slice 4a, so it stays; a directory that
  was edited again is captured as a new snapshot and does move the branch.
- *Accepted: the close after an unanswered apply.* When the executor is silent for the
  15 minutes `apply_within_ms` allows, the landing closes the scope while an apply that runs to
  its end on the executor may still be writing the tree, and a close that finds the tree busy
  can record `UnknownCleanup`, which an operator on the executor releases. It needs an apply
  that outlives the wait.

## Addendum: the checkout step is modelled, and `holds_tip` is wrong for it (2026-11-13)

The checkout step of slice 4c merged without a formal model. It has one now,
`protocol/models/session-move/MoveCheckout.tla`, which extends `Move.tla`. It models the
laptop directory as a git repository the operator can change whenever no move runs
(including between an abandon and a retry), the capture, the state store, the executor's
scope, tree and branch, one fenced `StateApply` with a lost reply and a retry, the
progress cell and what a restarted mover does for each of its values, crashes of the
source, the destination and the executor, the abandons of the step, and a second attempt
after an abandon. Nothing in the code, the wire or this protocol changes, and the version
stays at 6. Nothing above is edited; this addendum corrects one entry of the slice 4c
review.

**What holds.** With the apply rule described below, the model checks that once the
destination owns the session the executor's branch holds exactly the content the laptop
directory had when that attempt began; that the step never writes the directory; that an
apply changes the tree only under the fence of a scope the current attempt attached; that
after an abandon the laptop owns the session alone and no run takes another attempt's
state for its own; that a settled move leaves no scope that the source attached; and that
a move with a checkout step settles. `OneOwner` and the other `Move.tla` invariants hold
over the composition. Four mutants of those rules are each caught: a cell believed for any
move, an apply that skips the fence, a capture that commits into the directory, and an
abandon on request while the scope is open.

**What does not hold: `state_apply.holds_tip`.** The review above accepted one defect, "a
retry after an abort can deliver the earlier snapshot", on the ground that tightening the
apply to equality would break the resend rule of slice 4a. The model confirms it and
finds a second trace that needs no abandon:

- *The retry.* After an abandon that follows the landing, the executor's branch is at the
  abandoned attempt's snapshot. If the operator discards the edits and moves again, the
  capture of the clean tree has `HEAD` as its tip, which is the snapshot's parent, and the
  tree that the executor recreates from the branch already contains it. `holds_tip` answers
  that the apply is done, and the destination continues in a tree that holds the discarded
  edits. The same happens when the operator resets `HEAD` to an older commit.
- *An executor that is ahead.* The first apply of a clean directory is taken for done
  whenever the tip is an ancestor of the commit the executor's workspace starts a tree
  from (`worktrees.create` branches from `base`, which is `HEAD` unless the workspace sets
  another). A box that has pulled further than the laptop gives the destination its own
  commit, and the move reports the laptop's tip.

The traces, with the function and line of each step, are in the README of the model. Both
are reachable from real inputs. A dirty directory is not affected on a first attempt,
because its snapshot commit is new and descends from nothing the executor holds.

**What the fix needs.** Ancestry answers two questions at once: whether this state was
applied to this tree (a resend), and whether the tree already contains it (a session
that committed on top). The first is what the apply needs to know. The rule the model
checks as correct is that the tree is left alone when its `HEAD` is the tip, or when the
last apply for the session was of this tip; the second condition covers a resend after
the session has committed on top, and the first covers a crash between the checkout and
the record. The model separates this rule from the ancestry rule, but it has no step that
commits on the executor's branch, so the resend after a commit on top is covered by the
code test `applying_into_the_same_tree_twice_changes_nothing_test`, not by the model. The record is one ref per session on the executor, for example
`refs/loom/applied/<session>`, written after the `checkout -B`. The shipped rule is the
mutants `MoveCheckoutMutantHoldsTipAncestry` and `MoveCheckoutMutantHoldsTipAhead`, which
TLC reports as the violations they are, and the clean configuration is the proposed rule.
The first live drive of `sessions.move` reproduced the retry trace on real daemons
(`docs/review/distributed-1137.md`, finding 2). The change is made on its own branch,
`distributed/move-checkout-stale-tip`, with regression tests that fail against the
ancestry rule; it adds the one ref per session and keeps the resend rule of slice 4a.

**A second defect, in the executor ledger.** The same drive found (finding 1 there) that
a failed landing leaves the session's scope bound to the workspace it named. The ledger
binds a scope to the first workspace an attach names, whether or not the attach
succeeded (`exec_ledger.same_workspace`), and refuses an attach that names another. A
refused apply (a `shared` workspace) leaves a closed scope bound to it, and an attach for
a name the executor does not serve leaves an open one. A move with the corrected
`checkout_workspace` then stalls for good, the owner cannot release the scope, and a
daemon that decides by catalogue rows has no abandon on request. The model reproduces
both cases (`MoveCheckoutMutantScopeKeepsWorkspace`, `MoveCheckoutMutantScopeKeepsWorkspaceStall`),
and the clean configurations check a rule that lets an attach rebind a scope with no
tree record. That rule is not built: it also loosens the binding for a live session in a
`shared` workspace, which has no tree record, so the options (a rebind only for a scope
the move created, which needs the landing to say so on the wire; a rebind of a closed
scope plus a release of an open one; binding after the plane is built) are for the
ledger's owner to choose. The text of this protocol that says to fix the file and restart
the daemon does not recover a move that failed this way.

**Also recorded by the model.** The cell `client/move/checkout` stays in the session file
after the move settles and names the finished attempt. A later attempt ignores a cell of
another attempt, so it is a leftover and not a state any step trusts. An abandon on
request, which only a directory member has, may arrive while the source's landing scope is
open and does not close it. A directory member does not move a local session yet, so this
is not reachable today. `MoveCheckoutMutantOperatorAbandon` records it for whoever builds
the member path.

The placement claims of a pool (PR #1185) are modelled the same way, in
`protocol/models/placement-claims`; that is not part of this protocol.

## Addendum: a failed landing no longer binds the scope (2026-11-13)

The previous addendum recorded that a move that failed at the executor left the session's
scope bound to the workspace it named, so that a move with the corrected
`checkout_workspace` stalled for good. Three rules, none of which changes the wire or a
configuration key, remove it. The first live drive of `sessions.move` found it
(`docs/review/distributed-1137.md`, finding 1), and `MoveCheckout.tla` checks the rules.
Nothing above is edited.

- *The ledger rebinds a closed scope that holds nothing.* An attach that names another
  workspace takes over a scope that is closed cleanly and has no tree record, in the
  attach's transaction, and the incarnation rule is the same. An open scope, a scope with
  a tree record and a scope closed with unknown cleanup keep their workspace and answer
  `WorkspaceMismatch`. The open scope is the protection for a live session, which in a
  `shared` workspace has no tree record.
- *A failed attach leaves a closed scope, not an open one.* An attach for a name the
  executor does not serve creates a scope and cannot build its plane. The host closes it as
  retired, since no plane means no call was admitted, and the source closes it too and
  records the close. The reason of the refusal starts with a fixed sentence
  (`protocol.unserved_workspace`) so that the source can tell it without a new refusal.
- *A refusal that will not change abandons the move.* The checkout step used to report every
  attach error as one that may pass, so the move stalled. A scope bound to another
  workspace and a workspace the executor does not serve are now final: the move is
  abandoned with the reason and the session is resident on the source again. A connection
  failure, the fence and a plane still being built stay unfinished. In the same file a full
  store on the executor is unfinished and no longer final, and the apply's refusals are
  classified by naming every variant.

The fix-the-file-and-restart recovery that slice 4c describes now works for a `shared`
workspace and for a name the executor does not serve. One case is left. If the source dies
after the attach for an unserved name and before it closes the scope, and the operator then
corrects the name, the scope is open and bound to the old one. The move is refused for that
workspace, which the refusal names, and the scope stays open. `loomd executor release`
refuses an open scope, so nothing frees it yet. Letting `release` take an open scope is a
few lines of the ledger and a state word in the release table, and is not built.

## Addendum: corrections to the workspace rebind, and the apply record as shipped (2026-11-14)

Review of the workspace rebind found five points in the previous addendum that are wrong or
incomplete, and the apply record of an earlier addendum is now in the code. Nothing above is
edited.

- *The unserved attach closes a scope only when it opened it.* The host closes the scope
  that an attach for a workspace the executor does not serve leaves, but only for a scope
  that the attach created or reopened. A rebound scope is a session's own, with a tree and
  earlier calls, and an executor restarted with the workspace dropped from its
  configuration must not close it as retired. The source closes it only when its record
  shows the same: no record, or a record whose close was written.
- *A close that names the corrected workspace ends the move.* If the source's record names
  an incarnation with no close written (it died between the attach and the record, or the
  reply was lost) and the executor's scope is closed at that incarnation and bound to the
  old name, the attach under the new name is answered that the scope is at that
  incarnation, and the question about the close names the new workspace, which the scope is
  not bound to. That refusal is final and the move is abandoned. It used to read as a lost
  connection, and the move stalled and retried every five seconds with the session
  `moving`.
- *A full store on the executor is final.* The earlier addendum said it is unfinished. It is
  the store's total byte cap, room returns only when held states expire, which takes days,
  a daemon that decides by catalogue rows has no abandon on request, and each retry sends
  the bundle again from the start. The move is abandoned with the reason.
- *The case the rules leave is the `shared` one.* It was described as a source that dies
  after an attach for an unserved name. The host closes that scope. What leaves an open scope
  is a source that dies in the landing for a `shared` workspace, after the attach and before
  the close, followed by a corrected name: the move is refused for the open scope's
  workspace and the scope stays open. `loomd executor release` refuses an open scope, so the
  recovery is the one the refusal gives. Set `checkout_workspace` back to the name the scope
  is bound to, move again so that the move ends and closes the scope, then correct the name
  and move. No release of an open scope is added, and the earlier addendum's statement that
  nothing frees the scope is corrected by this recovery.
- *Still open.* A `WorktreeFailed` attach and a `NoPlane` for a root that is not a directory
  leave an open scope, and a failed `git worktree add` leaves a `Removed` tree row, which
  counts as a tree record and keeps the scope from being rebound. An attach for an unserved
  name whose build dies before the workspace is checked, followed by a retry, leaves an open
  scope bound to that name: the retry is a rebound attach and neither side closes a rebound
  scope. It needs both faults, and no recovery is built for it.
- *What the refusal's recovery does not reach.* A scope that still holds a tree after the
  move ends keeps its workspace for as long as the tree exists, so the corrected name is
  taken only by a scope that closed with no tree. The refusal says so.

**The apply record, as shipped.** The record of the last apply decides whether an apply is a
resend. `state_apply.into_existing` answers a request as applied when
`refs/loom/applied/<session>` names the tip, and when the tree's `HEAD` is the tip, in which
case it writes the record. Anything else moves a clean tree with `checkout -B`. A tip that is
only an ancestor of the tree's `HEAD` is not a resend, which is what ancestry took it for.
The record is deleted before the checkout and written after it, so that a crash at any point
leaves either no record, which the tree's own `HEAD` answers, or a record that names what the
tree holds. Left in place across the checkout, a crash would leave it naming the older tip
while the tree held the new one, and a later request for the older tip would be answered as
applied. The record trusts that `loom/<session>` is moved only by an apply or by the session.
A branch deleted out of band is made again from the base, and a request for the recorded tip
would then be answered as applied. The model checks the rule and separates it from ancestry,
and has no step that commits on the branch, so the resend after the session committed on top
is covered by `applying_into_the_same_tree_twice_changes_nothing_test`.
