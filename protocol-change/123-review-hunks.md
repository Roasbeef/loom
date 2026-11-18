# protocol-change/123: the review read, a session's worktree as bounded hunks

**Status**: PROPOSED 2026-11-18. The owner accepted autonomous protocol
changes for the attention inbox build on 2026-11-17. This is the daemon half
of phase 1's review pane.
**Affects**: one new v2 control command (`sessions.review`); one new field on
the daemon's router configuration (`server.Config.worktree`); one new in-process
read for the home page (`server.home_review`); one new typed module shared by
the page and a control client (`web_view/review_feed`). No existing command,
frame, event, record or `loom.toml` key changes. Nothing is added to the
session's peer endpoint, the catalogue or the sandbox.
**Raised by**: phase 1 of the attention inbox
(`docs/design-notes/attention-inbox/README.md`, section 2.1 and ruling 4 of
section 3: "Its first version reads the worktree's hunks and the agent's last
message").
**Builds on**: [051](051-web-view-route.md), the addendum on the worktree read
(the observation and who is shown it), [120](120-attention-feed.md) (the
authority walk this read repeats) and [118](118-inbox-thread-send.md) (the
home page's in-process commands).

## Problem

A finished session's thread should show what the agent changed: the files, each
file's hunks, and a count, in the order a reviewer reads them. Today the daemon
holds one projection of a session's worktree, the board the Changes tab and the
terminal's worktree view read (`session_view/worktree_view.Board`). It is not
reachable from Home, which is bound to no session, and its shape is wrong for a
review: each file's patch is one string, the files are in status order, and it
promises nothing about the size of the page that draws it.

This document defines how the daemon reads one session's tree for a review,
who may ask, what bounds the answer, and what each of those costs. It reads
only. It adds no staging, no comment record and no send: ruling 4 says a review
has no review record, no line-anchored comment and no local draft in this phase,
and the thread send of [118](118-inbox-thread-send.md) is how a person's words
reach the agent.

## What was considered

### Running Git from the daemon

The daemon could run `git diff` in the session's workspace itself. Rejected
without weighing cost. The workspace holds repository configuration and hooks
that a model may have written, and running Git over it in the harness's own VM
is what Rule Zero forbids. The observation the Changes tab already makes runs a
fixed set of Git calls through the session's broker, inside its sandbox, with
filesystem grants demoted to reads. A second path that did not would be a
second thing to keep safe.

### A new observation, beside the Changes tab's

A review could ask the session for a richer observation: hunks parsed in the
sandbox, renames detected, the committed history parsed. Rejected for this
phase. It would add a command to the session's peer endpoint or the broker, and
a sandbox-side parser for repository text. The existing board already carries
each file's patch under a byte bound, and a patch is plain unified-diff text
that the portable `session_view/diff_view` reads in the daemon without running
anything the repository supplied. The cost is the board's limits (below), which
a later observation can lift.

### Serving the board unchanged

The page could read the board as the Changes tab does. Rejected. The Changes
tab's page asks through `ui_socket.worktree_answer` and draws the board with its
own bounds. A thread pane needs hunks it can open one at a time, a stat, an
order, and a size promise that holds for the control socket's 60,000-byte reply
as well as for a page. Those are the review's own type (`review_feed`), and a
second decoder for the same board would drift from the first.

### Sending the agent's last message and the finds with the review

The review could carry `last_message` and the finds. Rejected. Phase 0 already
sends the last message to Home in `sessions.activity`, and the finds come from
the attention feed ([120](120-attention-feed.md)). A copy in the review would
be a second text the agent wrote, with its own freshness, in a reply whose
bound is for hunks. The pane draws the three from the three reads that already
exist, and pins a find at a path and line by matching the review's file paths.

### Reading a saved session

The daemon could open a saved session to read its tree. Rejected, as
[120](120-attention-feed.md) rejects it for records: a read must not start a
session, and a saved session has no instance holding a broker. It is
`not_resident`.

## Decision

### The command

`sessions.review` takes `session` (a canonical identity) and the current
`epoch`, and is a control read: it remains available during a drain, as
`attention.read` does. Reply `sessions.review`, whose body is a review:

```json
{"v":2,"reply_to":1,"event":"sessions.review","body":{"observed_at_ms":1763400000000,"repository":"head","stat":{"files":3,"added":41,"removed":9},"omitted":0,"extent":"whole","files":[{"path":"src/retry.gleam","change":"modified","section":"source","content":"text","added":30,"removed":9,"hunks_omitted":0,"extent":"whole","hunks":[{"header":"@@ -80,6 +80,9 @@ pub fn retry(","omitted":0,"shortened":0,"lines":[{"k":" ","o":80,"n":80,"t":"let wait = base"},{"k":"-","o":81,"t":"loop(base)"},{"k":"+","n":81,"t":"loop(base * 2)"}]}]}]}}
```

`repository` is `head`, `unborn` or `not_repository`. Each file has `change`
(`added`, `modified`, `deleted`), `section` (`source`, `tests`, `docs`),
`content` (`text`, `binary`, `no_net_change`, `metadata_only`), its line counts,
its hunks, and an `extent` of `whole` or `cut`. A line is `k` (`+`, `-`, a space
for context, `\` for git's no-newline note), the line numbers `o` and `n` it has
in the old and new file when its header gave them, and its text `t`. The
shape's single owner is `web_view/review_feed`: `encode` writes it and `decode`
reads it, so the page and a control client share one total decoder.

An in-process read serves the home page: `server.home_review(config, registry,
digest, reserve)` returns a function from a session identity to the review or
the refusal. It makes the same read as the command, through the same module
(`client/daemon/review_door`), and the page spends its credential's allowance
through `reserve`.

### Who may ask

The credential's authority is read from the registry at the call
(`manager.session_authority`) and never from the request: the owner, and a member
holding the session as an Operator. An observer is refused as `forbidden`,
for the same reason as the Changes tab: the addendum to
[051](051-web-view-route.md) shows the worktree to an owner's page and an
operator's and never to an observer's, because an observer link is meant to be
handed to someone who may only watch, and the tree's bytes are not what they
were given. A session the credential does not hold is `not_found`, the word an
unknown session gets. A caller that holds an observer-ceiling page does not
offer it `home_review` (the ceiling is the page's, not the credential's, and the
function does not see it). Home's inbox is owner-only in phase 0, so no caller
offers it today.

### Reading the tree: the effect path

The daemon does not read the workspace and does not run Git. A resident
instance already holds `worktree`, a closure built when the session was
assembled (`serve.gleam`, `observe_worktree`) over the session's workspace, the
base commit recorded before its first turn, and its effect broker. Calling it
runs `worktree_diff.capture_since`: a fixed list of Git calls, each cleared
through that session's broker, in the session's sandbox policy with filesystem
grants demoted to reads, under one deadline (8 s) and a byte budget. Nothing
the page or the caller sends reaches it: not a path, not a command, not a
revision. `server.Config` gains one projection, `worktree`, from the resident to
that closure, as `peer_endpoint` projects the resident's peer address. The
review calls it in a weft run of its own with a 14 s deadline (the observation's
8 s execution deadline, the broker's 5 s cleanup grace, and a second), and the
caller waits on the run; the registry and the session are never held.

The board it returns is decoded with the terminal's decoder
(`worktree_view.decode`), which validates every field and the 24-file bound,
before anything is read from it. `review_feed.of_board` then reads each file's
patch into hunks with `session_view/diff_view`, which is portable, total and
performs no I/O.

A resident with no observation, a saved session and a session that is opening
or stopping are all `not_resident`: nothing is running that could read its tree.

### Bounds

The board's own limits hold first: 24 files, 16,384 bytes of patch per file,
an observation deadline, and an encoded ceiling of 40,960 bytes. The review adds
its own on what it carries, and says so when it cuts.

| Bound | Value | What counts the cut |
| --- | --- | --- |
| Files | 24 | `omitted`, with the stat's `files` giving the number read |
| Hunks per file | 12 | the file's `hunks_omitted` |
| Lines per hunk | 80 | the hunk's `omitted` |
| Bytes per line | 400 | the hunk's `shortened`, the number of lines cut |
| Encoded review | 48,000 | `omitted`; the last files, docs first, go |
| Path | 1,024 bytes | the file is left out and counted in `omitted` |

A file's `extent` is `cut` when its patch was cut by the observation or by any
bound above, and the review's is `cut` when anything was. The stat counts every
file the observation read, those left out included, and counts lines as far as
each patch was read, so a cut file's counts are lower bounds. A binary file is
named and carries no hunks. A path that is absolute, empty, longer than the
bound, has a NUL, or has a `..` segment is not a workspace path: its file is
left out and counted, never named. The observation asks Git for paths relative
to the workspace, so this is a check that a damaged answer cannot widen where
the page thinks a file is.

The decoder holds the same bounds on what it keeps: a damaged file is dropped
alone and counted in `omitted`, files, hunks and lines past the bounds are
dropped, and text past the line bound is cut at a character boundary. A value
from any source is as bounded as one the daemon made.

Files are ordered source, then tests, then docs, and by path inside each, by a
pure rule (`review_feed.order`). A document is decided first: a file under
`docs/` or `doc/`, or with a prose extension (`.md`, `.mdx`, `.rst`, `.adoc`,
`.txt`), or named `README`, `CHANGELOG`, `LICENSE`, `NOTICE` or `AUTHORS`. A
test is a file under `test`, `tests`, `spec`, `specs`, `__tests__`, `testdata`
or `fixtures`, or named `*_test.*`, `*.test.*`, `*_spec.*`, `*.spec.*` or
`test_*`. Anything else is source.

### Refusals

| Code | Meaning |
| --- | --- |
| `stale_epoch` | the `epoch` is not the daemon's current one |
| `bad_request` | `session` is not a canonical identity |
| `forbidden` | the credential holds the session as an observer |
| `not_found` | an unknown session, or one the credential does not hold |
| `not_resident` | the session is saved, opening, stopping or has no observation |
| `unavailable` | the credential's workspace reads were spent, or the observation failed, ran past its deadline, or answered something that is not a board |
| `metadata_too_large` | the encoded frame would pass 60,000 bytes; the review's own bound makes it unreachable, and the check keeps the arithmetic honest |

Every refusal is a code and fixed words. A failing observation's own text can
carry a repository's words, so it is never forwarded.

## Threat model

- **Model-influenced bytes in the harness VM.** The patch text is the
  repository's, which the agent may have written. It is read by `diff_view`, a
  portable parser with no `@external`, no regex and no allocation beyond the
  patch it was given (at most 16 KiB per file). The Git processes that produced
  it ran in the session's sandbox. A hostile patch can be wrong, or large; it
  cannot name a different file than the one its path names, because the
  observation compares each displayed file separately and the review takes the
  path from the status entry, never from a patch header.
- **A path that climbs out.** Left out and counted, in the builder and in the
  decoder.
- **Markup in a line.** Every string is drawn as a text node, and every class a
  page picks comes from a closed type (`diff_view.Kind`, `Change`, `Section`,
  `Content`, `Extent`). No line chooses a class or an element.
- **Reading another session's tree.** The authority walk is the registry's, at
  the call. An unknown session and a session the credential does not hold are
  the same refusal, so a reply never confirms that a session exists.
- **An observer reads hunks.** Refused (above), as the Changes tab refuses
  it. The check is made from the registry at the call, before the allowance is
  spent and before the observation runs.
- **Exhausting the helper pool.** A credential's reads are counted together with
  the Changes tab's (`ui_sessions.reserve_worktree_read`), so sockets and
  threads cannot spend a session's helper pool on Git calls. A refused read is
  `unavailable`, which tells the caller nothing about the workspace. A daemon
  with no web view has no table to count in; its control sockets belong to the
  owner and its members, and a read is one run under a deadline.
- **A page that is slow or a socket that never reads.** The run is waited on by
  the caller's own process and is cancelled with it; the weft run has a
  deadline of its own.
- **A reply that is too large.** The review is fitted to 48,000 bytes and the
  frame checked against 60,000.

## What it costs

- **Renames are a removal and an addition.** The observation runs Git with
  renames disabled, so a moved file is two entries and the review shows both.
  Detecting renames is a change to the observation and is left open.
- **Committed work is not shown.** The board carries a patch stream of the
  commits made since the session began, in one string with its headers. The
  review does not parse it, so a session that committed all it did shows an
  empty review. The pane should say how many commits there are from the
  activity read until a later change parses them. This is the largest gap, and
  it is left open deliberately: the stream is not per-file, and splitting it
  needs the observation's help.
- **Twenty-four files and 16 KiB a file.** A larger change is shown cut and says
  so. These are the observation's limits and are not new.
- **A page that reads often costs Git calls.** The allowance is the Changes
  tab's, so the pane and a session page open at once draw on one count.
- **One more field on `server.Config`.** Six constructors across the daemon
  and its tests carry `worktree: fn(_) { None }`; the daemon's own passes the
  resident's closure.
- **No push.** A review is read when the pane opens and when a thread is
  selected; nothing tells the page the tree changed.

## Verification

- `web_view/review_feed`: file order by pile and path (an example, and a
  qcheck property over mixed paths with a fixed seed that the result is a
  permutation in pile order); the pile each path is in; a patch read into
  hunks with its line numbers and stat; each status pair's change; a binary
  file named without hunks; a renamed file as a removal and an addition; an
  empty tree; a workspace that is not a checkout; paths that are absolute or
  climb out; the observation's own limits carried; every bound holding under a
  qcheck property over hunk count, line count and line width, with each cut
  counted; a review over the byte bound losing the last files; and a total
  decoder that round trips, refuses a damaged whole, drops one damaged file at
  a time, refuses a foreign path and cuts to the bounds.
- `client/daemon_review_test`: over a real registry, catalogue and resident
  sessions, the owner reads a review in order, an old epoch is refused, an
  observation that fails is `unavailable` and its words are not in the reply,
  an unknown identity is `not_found` and a malformed one `bad_request`, a
  stopped session is `not_resident`, an operator reads, an observer is `forbidden`
  and a member holding nothing is `not_found`, the door refuses a bystander or an observer
  without spending the allowance, and a credential past its allowance is `unavailable`.
- `make check-core`, `check-web_view`, `lint`, `doc-check`, `client-check`,
  `prelude-check`, and the `ui_socket`, `ui_route` and `daemon_server` tests.

## Decisions for the owner

1. **Committed work.** Whether the review should wait for a per-file committed
   observation, or ship with the gap named, before the pane is the landing
   page.
