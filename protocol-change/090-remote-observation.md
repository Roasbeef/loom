# protocol-change/090: observing a child on another orchestrator

**Status**: ACCEPTED 2026-10-17 · **Affects**: the orchestrator port's closed
message type (one constructor, `ChildHistory`), `SpawnHost`,
`agency.DelegateEndpoint` and `remote_reach.Reach` (one function each),
`remote_spawn.SpawnRefusal` (one variant, `TranscriptHidden`), `loom.toml` (one
key, `[spawners.<name>] transcript`), the parent's stub (`glanceSeenMs`), the
client protocol (one command, `child_history`, and two `snapshot` modes,
`remote_children` and `child_history`), `session_view` (`agent_view.Row.placement`,
two modules) and the event bus (one data-free event, `RemoteChildrenChanged`) ·
**Raised by**: remote subagents phase 4, slice S12, and the owner's ruling of
2026-10-16 on transcript observation · **Implemented**: client, session_view,
events, tui, web_view

This builds on [084](084-remote-subagents.md), whose phase 4 named observation
of a remote child as work for later, and which the design note's section 16
records as given up until then: "Transcripts stay on the remote until phase 4,
so the laptop's operator sees a remote child's result and notes but not its
working." Spec Part 1 is unchanged.

## Problem

A child that runs on another orchestrator has no strand in its parent's session.
Phase 2 of 084 pushes the child's newest glance to the parent's daemon
(`ChildProgress`), which keeps it on the child's stub, but nothing showed it to a
person. The parent's agent strip, in the terminal and in the web view, is built
from the session's capture, and a stub is not in the capture, so a remote child
was invisible while it ran. Its result reached the parent's model through a
join, and its notes through `agent_notes`, but the operator could not see what
it was doing, or read what it had done.

Two different things were missing, and they cross different lines.

- **Progress** is a view of what the stub already holds on the parent's own
  machine: the standing the spawn has reached and the newest glance. Showing it
  sends nothing anywhere.
- **The transcript** is recorded on the box, in the delegate session's store,
  and may hold what the box's tools returned from the box's filesystem. Reading
  it from the laptop ships content the box owner has not agreed to ship. 084
  did not propose to cross that line, so it needs its own decision.

## Considered

**Pull the glance with every `Join`.** The planner's first revision carried the
glance in the `Join` answer. The owner ruled on 2026-10-16 that traffic from the
box is pushed, and S9 built `ChildProgress` that way. The laptop already holds
the glance on the stub, so there is nothing to pull.

**Put the stubs in the capture.** The capture plan could select the
`remote-child/` prefix, and `session_view` could decode the stub. The stub's
encoding belongs to `client/remote_child`, and a second decoder in
`session_view` would drift from it. The capture is also driven by commits that
carry an emit, and a stub write is a reserved fact, which no emit carries, so
the strip would change only when some unrelated entry was committed.

**A new event class for the strip.** A `remote_children_changed` push in the
manner of `goal_changed` would make the client ask for the list again. That is
a new event name, a new correlated read and a round trip for every glance. A
`snapshot` push that carries the list itself does the same in one frame and
under an event name every client already decodes.

**Read the transcript through the credited lineage transfer of 072.** The box's
gateway serves `history_lineage` to its own clients as descriptors and
fragments under credit. The laptop's daemon is not a client of the box's
gateway, and the page crosses the pinned distribution connection as one term, so
the transfer's credit and reassembly would be machinery with no reader. The
records 072 reads are the strand's path from its leaf down its parent links; the
box reads the same path through the frozen storage interface's
`scan_branch(from: leaf)`, which returns decoded entries newest first with a
sequence cursor, and bounds the page itself.

**Let the laptop read any strand of the delegate session.** The delegate
session holds the children of one parent session. A parent strand could then
read its siblings' children, and the delegate session's own `main`. The read is
restricted to descendants of the parent's reference, the test a send into a
child already makes.

**Make transcripts visible by default.** The box owner is the one whose machine
recorded the transcript, so the default keeps it there, and the box owner opts
in per spawner.

## Decision

**Accepted.**

### Progress: the stub as a strip row

`client/remote_child.agents` projects each stub into a
`session_view/remote_agent.RemoteAgent`: the child's strand name on the box, the
parent strand, the orchestrator, the standing (`starting`, `running`,
`expired`, `completed`, `stopped`, `refused`), the newest glance's title (or the
purpose the spawn asked for), its summary and tokens, the model, and `age_ms`,
how long before the push the glance reached the parent's daemon. A `Spawned`
stub past its deadline is `expired`, because `is_live` no longer counts it and
no join has said how it ended.

The age is measured on one clock. The stub gains `glanceSeenMs`, the parent
session's clock when the newest glance was stored, written by `progressed` with
the glance; a stub written before this field reads it as zero, which means no
age is known. The glance's own `at` is the box's clock and is compared only with
other glances from the box, as before.

The gateway sends the list as a `snapshot` with mode `remote_children`: once to
a connection when it subscribes (and only when the list is not empty), and to
every subscriber when the session's bus carries `RemoteChildrenChanged`, which
`remote_child` publishes after every stub write lands. The event carries no
data; the stubs in the store are the truth, and the gateway reads them again. A
lost publication leaves a strip stale until the next stub change. The list
reaches a client as one pushed frame, which the gateway bounds at 64 KiB, so it
is bounded to fit: the daemon clips a row's title, summary and model to 256
bytes, the names (the child, the parent, the orchestrator) are at most 512
bytes, and `remote_agent.within_bound` keeps the longest head of at most 64 rows
whose encoded list is within 60,000 bytes. The client decodes it totally: a
malformed entry, or a string over its bound, refuses the whole snapshot.

`agent_view.Row` gains `placement: Option(String)`, the orchestrator, `None` for
a strand of the session. `session_view/agent_roster` keeps the newest list and
the host's clock at its arrival (`observe_remote`), and `remote_rows` turns each
entry into a row with its placement set, which both hosts list after the
capture's rows. A remote line carries the glance's tokens and `age_s`, the
daemon's age plus the time the host has held the snapshot, so a strip whose
daemon cannot reach the orchestrator shows the last glance growing older and
says so (`seen 2m 05s ago`) once it is a minute old. Nothing is sent to refresh
it. The terminal's strip and the web view's cards name a placed row
`<child> @ <orchestrator>`.

### Transcript: `ChildHistory`

`orchestrator_port.Message` gains `ChildHistory(parent, child, cursor, limit,
reply)`, sent laptop to box. `SpawnHost.history`, `DelegateEndpoint.history`
and `Reach.history` carry it through. The box's spawn host:

1. finds the spawner by the message's node, or refuses `UnknownSpawner`;
2. refuses `TranscriptHidden` unless the spawner's table says
   `transcript = "visible"`, before any session is looked for;
3. finds the pair's delegate session with `delegate_host.existing_endpoint`, which
   reads the pair's row and answers the Agency only of a session that is
   resident. It creates and opens nothing. A pair with no session, or one that
   is closed, is refused as holding no such child, so a `ChildHistory` that
   arrives before its `Spawn`, from a different process, creates nothing;
4. asks the delegate Agency's `delegate_history`, which refuses a child that is
   not a descendant of `^{parent.strand}` and otherwise reads the child's
   branch with `storage.scan_branch` from the child's leaf, newest first, with
   `cursor` as the exclusive sequence bound (zero for the newest page) and one
   entry more than `limit` to say whether older ones exist.

The page (`session_view/remote_transcript.Page`) is the child's name, at most
`max_entries` (50) entries oldest first, at most `page_bytes_limit` (49,152
bytes) of encoded entries, `omitted`, the count of entries in the page's span that were
too large to send alone, and `next`, the sequence the next older page reads
below, or null at the child's first entry. An entry over the byte bound alone is
counted and skipped, so one large tool result cannot stall the paging, and a
page always takes or omits at least one entry. The byte bound is the gateway's:
the page reaches the client in one pushed observation, which is bounded at 64
KiB encoded, and the entries leave room under it for the board and the
envelope. Before an entry is measured its reasoning blocks are taken out
(`remote_transcript.without_reasoning`), in assistant messages and in a
compaction's retained tail: no host draws them, and the provider's reasoning is
not part of the child's working to ship. Entries are encoded with the shared
core codec. The laptop decodes the page totally (`remote_transcript.decode`):
more than 50 entries, an entry the codec cannot read, or a cursor that is not a
positive sequence refuses the page.

`ChildHistory` is a read. It writes nothing on either side and is safe to send
any number of times. The box answers it in a task linked to the port, as it
does a send.

### The client's read: `child_history`

The session endpoint gains `child_history`, body `{child: string, before:
integer}`, in the read-only set. `child` is the child's strand name on the box,
as `remote_children` lists it, and the gateway finds the stub by that name, so a
name that is not a remote child of the session reads nothing. The read is an
observation in the manner of `context` (section 4.9.21 of the client protocol):
the reply is a `snapshot` with mode `child_history` and `board.status` `pending`,
and the outcome is pushed with the same `board.request_id`, `ready` with the
page's fields, or `failed` with `message`. It shares the observation worker
slots, the fourteen-second deadline and the socket cancellation, so the box's
answer never holds the session's hub, and the box is asked by the stub's
orchestrator through `Reach.history` with a ten-second bound. A board is bounded
to 65,536 encoded bytes, the gateway's bound on a push. A gateway with no reach
answers `unavailable`.

### Drawing it

The page is model text recorded on another machine. A host draws it as data:
every word is a text node in the web view and a plain line in the terminal,
never passed through either host's Markdown renderer, never an attribute, class
or key. The page is framed by two lines the harness writes and the text cannot
supply, `strand_framing.transcript_head(child, orchestrator)` and
`transcript_foot`, in the manner of the framing the Agency puts around a message
between strands. Reasoning blocks never reach the laptop, and image bytes are
not drawn; a brief or a
message the parent sent loses the Agency's framing, as it does locally.

- **The terminal.** `/peek <name>` opens a peek at a remote child, named as the
  strip shows it or by its whole strand name, and `/peek close` closes it.
  Choosing a remote row on the strip opens one too, since there is no strand
  to switch to. The peek takes the lower half of the transcript area, the lane
  the side question uses when no side question is shown.
- **The web view.** Focusing a remote child's card (`FocusRequested`, the
  strand focus of 051) opens a peek instead of a strand switch: the component
  runs the shared step's `Peek` command as a control, which sends
  `child_history`, and the Strands tab draws the peek in place of the list as a
  strand's own view is drawn (`web_view/view/peek`). Its back link is the strand
  view's marker control on `main`'s card, and focusing any card closes the peek,
  so the peek adds no event class, no admitted path, no scope and no change to
  the content security policy.

### The spawner's key

`[spawners.<name>] transcript` is `"visible"` or `"hidden"`, default `"hidden"`.
Any other value is refused when the file is read.

## Costs

**Transcript content leaves the box when the box owner allows it.** That is the
point, and it is why the key defaults to hidden. A visible spawner's children's
working, including what the box's tools returned, is readable by every
subscriber of the parent session, an observer included, a page at a time. The
spawn policy binds an honest peer only (084, "What it costs"), so the key bounds
an honest laptop: a compromised one holds the distribution connection and does
not need this message.

**A closed delegate session is not read.** A child whose session has closed,
because the box's sweep closed an idle one, has no page until the next spawn or
join reopens the session. The parent still has the child's result from its join.

**The strip is as current as the last push.** A glance lost to a disconnect is
not resent (084's addendum on S9), and a lost bus publication leaves the list
stale until the next stub change. The age says how stale.

**The web peek has no paging control.** Older pages need a control the page
does not have, and a new control is a new admitted event under 051. The page
says when older entries exist. The terminal's `/peek` reads the newest page as
well; the wire carries the cursor for a client that pages.

**One more field on the stub, one more variant on `SpawnRefusal`, one more
event on the bus.** Old stubs decode with no age. A port of an older build has no
clause for `ChildHistory` and stops, as for the other constructors 084 added
(protocol-change/078, "Mixed builds"), so the two orchestrators are assumed to be
of the same build.


## Addendum: refusal details (2026-10-29)

Issue #1137 found that a refused stub lost its reason when projected into the
strip. For standing `refused`, `RemoteAgent.summary` now carries the refusal
reason ahead of any older glance. It keeps the existing 256-byte UTF-8 bound,
list bound and total decoder. Other standings keep their existing summaries;
title, tokens, model and glance age keep their existing meaning. No wire field,
constructor, transcript permission or retry policy is added.

The roster treats the summary as plain, single-line text. The web card now
includes nonempty activity on a failed remote row; local failure labels keep
their existing wording. Remote `stopped` and `refused` already share the roster's
failed status, so a stopped card can also show its last activity. Settled cards
remain in the existing collapsed group. This does not grant transcript access.

The sender and receiver log definitive spawn refusals at warning level, using
fixed classes from `remote_spawn.refusal_class`. Operation and call-site
coordinates correlate the attempt; peer text uses ordinary scrubbed fields and
is diagnostic attribution, not a new authority check. An unconfigured sender
omits the model-supplied destination name. Briefs, model choices, tool lists and
free-form refusal text are absent from these diagnostics. `NotYetOpen` remains
retryable and produces no final-refusal diagnostic.
