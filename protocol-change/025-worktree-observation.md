# Session-scoped worktree observations

Status: proposed implementation of the approved worktree-diff and file-navigator
scope. Affects the client command and optional snapshot surface in Part 1.6.

## Problem

The terminal's diff view renders captured edit-tool results. Those records omit
external edits, staged changes, untracked files, and edits outside the retained
conversation window. Running Git in the terminal would observe its launch
directory rather than the attached session's workspace. Running Git directly
inside the daemon would let repository configuration execute outside the jail.

## Decision

A human requests a fresh worktree observation through the attached session's
gateway. The gateway admits only a currently authenticated owner and a subscribed
attachment. Transcript membership, including operator status, does not grant
filesystem-wide observation. It revalidates authority before delivery, binds the
result to the original request and attachment, and cancels pending work when
the original socket exits. Explicit detach closes
that socket; authority revalidation closes a revoked attachment. A host-only
fixture has no socket and retains its bounded capture until completion or the
run deadline, suppressing delivery after detach. The observation is transient
and does not create a model turn or a durable conversation entry.

The host injects a capability that captures the session workspace, final sandbox
policy, existing broker, enforcement demand, clock, and operation entropy. The
command carries neither a directory nor argv. The gateway runs capture in a
bounded worker rather than blocking its actor. The broker already monitors the
worker and cancels native execution if it dies.

All Git invocations use the broker. The capture policy demotes existing writable
roots and explicit mounts to readable access, keeps protected paths and required
mounts, and disables network access. Scratch remains ephemeral. This preserves
read authority over linked-worktree metadata without adding any filesystem path.
The environment retains only an allowed PATH and fixed HOME/LANG values; daemon
credentials and Git directory overrides never reach the child. Pager, external
diff, text conversion, filesystem-monitor hooks, rename detection, and submodule
recursion are disabled. Repository-influenced execution remains inside the jail.

## Observation and encoding

The `worktree_diff` command accepts an empty body. It returns a `snapshot` with
`mode: "worktree_diff"` and `board: {status: "pending", request_id: Int}`. The
request ID is the original command ID. The gateway then pushes one final bounded
snapshot to that original connection with the same `request_id` in its board.
The final event has no `reply_to`: the pending acknowledgement already consumed
the synchronous request, and a late synchronous reply would poison the channel.
It does not consume a second synchronous request capability or broadcast the
result. A successful final board adds `status: "ready"`; a failed final board is
`{status: "failed", request_id, code: "unavailable", message}`. Refused admission
returns a normal protocol error without creating pending work.

The ready `worktree_diff` board is an object with `source: "git"`,
`observed_at_ms`, `repository`, `entries`, `total`, `omitted`, and `extent`.
`repository` is `head`, `unborn`, or `not_repository`. Each entry contains its
literal workspace-relative UTF-8 `path`, one-character `index_status` and
`worktree_status`, `patch`, `kind`, and `extent`. A renderer must escape terminal
control characters without changing the stored path identity.

The `kind` values are `text`, `binary`, `no_net_change`, and `metadata_only`.
An untracked nested repository is listed as metadata without recursive traversal.
`extent` is `complete` or `limited`, on both the board and individual entries.
An unsupported command is an explicit unavailable surface for an older peer. An
empty complete ready entry list authoritatively reports a clean captured status.

Status uses porcelain-v1 NUL framing with rename detection disabled. Every
returned pathname is decoded exactly; non-UTF-8 names refuse the observation
instead of being replaced. Status is scoped to the session workspace subtree.
Git's repository-relative names are converted with its own captured prefix.

The HEAD commit is resolved once, and tracked files are compared against that
commit. Thus each patch shows the net effect of staged and unstaged changes.
Separate status columns preserve the case where those changes cancel each other
and the net patch is empty. Untracked files and files in an unborn repository
are additions against an empty original. Binary files retain Git's binary
summary rather than being coerced to text. No-index exit status 1 means a
difference; other command failures remain classified failures.

These reads are not atomic with concurrent filesystem edits. The timestamp
records when capture began, not a repository revision or a conversation sequence.
A successful response makes no claim that files still contain those bytes.

## Bounds and failure behavior

The gateway admits at most two captures globally and one per connection. A
pending record and its Weft report channel remain held until `AllDelivered` or
`RunLost`, including after detachment. A 14-second Weft deadline bounds the
worker; the linked relay cancels it when the gateway dies. Socket death cancels
through `weft.cancel_when_exits`, requiring no separate cancellation process.

Capture has one 8-second execution deadline shared by status, metadata probes,
and at most 24 literal per-file patch calls. Cleanup may take up to 5 additional
seconds; the outer worker must outwait that grace. Each process has finite
CPU, wall, memory, pid, file-size, and stdout/stderr ceilings. Status is limited
to 256 KiB, each patch stream to 16 KiB, and aggregate collected output to
512 KiB. The complete encoded board is at most 40 KiB.

A status excerpt cannot establish `total`, so truncated status is a failure.
Individual patch excerpts are marked `limited`; omitted files remain counted
in `total` and `omitted`. The encoded-byte bound may retain fewer than 24 files.
No repository, no changes, output limits, decoding failures, policy refusals,
Git errors, execution cancellation, and missing settlement remain distinct.
Missing settlement requests cancellation before returning; it is not a claim
that native cleanup has completed.

## Alternatives and cost

Captured tool diffs cannot answer a current worktree question. Local terminal
Git observes the wrong authority and directory. An aggregate patch parser would
have to associate quoted display headers with exact filenames containing spaces
or newlines. Bounded per-file argv costs additional helper calls but preserves
identity without a second quoting grammar or a jailed orchestration script.

The implementation adds no dependency, actor, durable storage format, automatic
refresh loop, staging command, or write capability. Gateway lifecycle integration
and the terminal navigator consume this bounded read surface.
