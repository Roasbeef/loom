# Current handoff

This handoff is baselined against `c5fe2441d` (`main` after #619, S5 of the
step extraction) on 2026-09-29, plus the S6 documentation commits on
`docs/step-extraction-record`. Tracker state was read with `gh` the same
day. Every claim below was checked against that tree or that tracker; a
claim that could not be checked says so.

## What the previous edition got wrong

The previous edition was pinned to `868dfedd8` and written on a branch that
predates the whole step extraction. Four of its statements are now false.

- It said web UI phase B needed the extracted step and that three of
  ADR-014's four blockers remained. All four are closed, and the step lives
  in `session_view`. ADR-014's addendum of 2026-09-29 says how.
- It said the web view drives the lane and the projection. The web view
  drives the shared step (`step.update`), and its component holds two
  records, `shared` and `view`.
- It said the client and the terminal pin etui at `58d0cbd7`. Both pin
  `c10f6a64` (`gleam.toml`), which adds a linear wrap for a word wider than
  the row.
- It said an approval card sits below the composer. The card sits above it,
  in the dock the stylesheet pins to the viewport's bottom edge, so a card
  appearing grows the dock upward and never moves Send.

It also treated operator diagnostics (#363, #377, #286) and the provider
debt PR #579 as unmerged. Those issues are closed and #579 merged on
2026-09-28. The terminal-state work (#399, #524, PR #583) is still open.

## Where the tree is

**Part 1 of [issue #569](https://github.com/Roasbeef/loom/issues/569) is
done.** The session's half of the client step lives in `packages/session_view`,
which depends on `core`, `machine` and `gleam_stdlib` alone, held there by
lint R6. It holds the lane (`session_channel`), the decoders, snapshot
adoption, the projection and the line builders, and, since S4, the shared
step: the session record `model.Shared(socket, recorder, source,
replay_source)`, the folds of pushed events and lane updates
(`event_fold`, `lane_fold`), the operator's commands (`commands`), the
side-surface reads (`surfaces`), the settle, and `step.update`.

The two hosts run it in different shapes.

- **The terminal** (`packages/tui`) holds `Model(shared, view)`, with
  `TerminalShared` binding the four handle parameters. It calls the shared
  units one at a time, applies the surface facts each records between the
  drain's updates, and does not call `step.update`. The terminal runtime
  stamps and admits inputs, the step returns effects, and the runtime
  performs them. Its socket wakes its loop, and `terminal_poll_timeout`
  follows the lane's deadline with a one-second idle ceiling, because a
  resize needs a poll.
- **The web view** (`packages/web_view`) holds `component.Model(shared,
  view)`. `update` reads the transport's clock once, hands the step a
  message (`Arrived` files, `Ticked` drains and ticks, `Acted` runs a
  command) and derives what it draws from the record the step left,
  rebuilding a projection only when its inputs moved. A burst of at most 64
  frames is one message, and so one render, and one timer is armed for the
  lane's `next_due`. `session_view/step_test` holds `step.update` to the
  order of the terminal's tick, since nothing else does.

The lane's pushing refresh is 5,000 ms, and the gateway pushes the roster to
a subscriber (protocol-change/054). [Delivery](architecture/delivery.md)
explains the ordering and ownership, and [the client
architecture](architecture/client.md#the-client-engine-and-its-hosts) is the
map.

**The page today.** `loomd --ui` serves an observer's page and an operator's
page for one session, on the strand `main`. Both draw the agent strip with
cache rings and miss notices, turns with folded work, sub-agent, advisor and
peer rows, rendered Markdown, and the newest 150 rows with paging back to 300
(`Load older`). An operator's page also has a composer and approval cards,
and since S5 it runs any session command a draft names, except `/add-dir` and
`/add-write-dir` (protocol-change/051, the newest addendum). It cannot yet
draw a live answer, a todo board, an expanded row or a second strand. Its
composer completes slash commands, sends on Command or Control with Enter and
takes a returned prompt back into the editor (#624). Claim invitations carry no bearer: 053 step 1 is
merged, and the owner admin steps still need an implementation decision. Do
not infer approval from the claim-flow merge.

The toolchain is Gleam 1.19.0-rc2 (`.github/workflows/ci.yml`). `make
check-affected BASE=origin/main` runs only the gates a change can affect; a
change to the daemon's package also needs `make signoff`.

## Next actions, in order

Part 2 of #569 (the web UI's phase B) is the current work. A first batch is
in progress and is not on `main`; look for its branch or PR before
starting any of it. Items 1 to 3 are in the order that work is running.

1. **A pinned frame, and following the tail.** Header and agent strip pinned
   at the top, the composer and approval cards pinned at the bottom, and the
   transcript its own scroll container that follows the tail unless the
   reader scrolled up, with a "jump to latest" control when they have. This
   replaces whole-page scrolling, which is what makes following fragile
   (`<loom-follow>` landed in #577 and does not follow in practice). Exit:
   find whether following regressed or covers only some growth (a capture
   against a push, a reader a few pixels above the bottom), then a hand check
   in a browser of the operator page, the observer page and a session with a
   running strand. S5's own hand check was run before it merged
   (2026-09-29, the operator and observer pages over a live session with
   Kimi K3): `/add-dir` and `/help` are refused with notices, `/compact`
   reaches the daemon, a prompt round-trips, and the observer page is
   read-only. It found the composer's "advisor_pending sent" notice, which
   is item 2's typed notice.
2. **The composer.** Slash-command autocomplete listing the session commands
   the page can run (not surface commands, not `/add-dir` or `/add-write-dir`),
   with the names and argument hints the terminal's completer draws from
   `command`; Cmd+Enter and Ctrl+Enter submit, and plain Enter inserts a
   newline, as a client-side listener that adds no event to the socket's
   accepted list; a typed notice, so the page draws command outcomes and
   refusals and not read names ("advisor_pending sent" on every page load);
   and a prompt the daemon returns put back in the composer, or at least a
   notice naming the strand and count. Exit for the last two: the page
   states what happened to a returned prompt, and no notice shows an internal
   read name.
3. **Expand a row, then the todo panel.** A `code_mode` call shows a
   six-line preview and the program it ran cannot be read from the page;
   the same holds for tool results and reasoning. The todo panel is a view
   over state already shared (`todo_board`, `core/todo_list.decode`): the
   active phase expanded, other phases folded, the terminal's status glyphs
   and `n/m done`, with the reviewer band beside it.
4. **The rest of Part 2**, in the order #569 lists it: strand focus (advisor
   and `sub:*` as their own columns), live streams (the streaming reasoning
   row with its elapsed time and headline, and a streaming answer), the
   session sidebar, advisor nudges, changes and trace panes, peer reply,
   session actions (fork, stop, goals), images, the admin page and CLI (053
   steps 2 onward), share and invite from the page (needs a narrow 051
   addendum), and a visual design pass (specified in
   [the web design note](design-notes/web-design.md), with its pull request
   breakdown). Also open there: an ended page must
   say so, a decision on more than one page per principal per session, and
   whether the memory context the daemon attaches to each prompt belongs in
   the transcript.
5. **Option (d), later.** Once S5's engine has run for a while, examine
   moving the terminal onto `step.update` by passing a pure callback
   the sequencer calls after each piece, so both hosts run one sequence. It
   is recorded on #569 and not planned. Exit: a written estimate of the three
   costs the note names (callbacks through the step, reordering risk that
   the replay identity checks catch, and the Erlang inliner on long settle
   chains), measured with `scripts/tui_perf.sh` and `erlc +time` before any
   code.
6. **Terminal state.** Land or close PR #583 (#399, #524).
7. **Wake etui on SIGWINCH** before raising the terminal's one-second idle
   ceiling. Exit: resize repaints without waiting for a poll, and a quiet
   terminal wakes only for work its lane or runtime owes.
8. **Measure actual provider token counts** and representative workloads
   before choosing tool search. Exit: measured prompt size, cache-prefix
   behavior and discovery cost, rather than the character estimate in
   [the design note](design-notes/tool-search-and-code-mode.md).

Before remote multi-viewer use of the page (052), measure the server-side
re-render and diff cost per batch per viewer.

## Rulings to preserve

**Hosts do not poll for traffic.** A frame is reduced when it arrives: the
terminal's socket wakes its loop, and the web view's selector is the wake.
A host sleeps until `session_channel.next_due` and wakes on its own only
for what no wake announces. A fixed-cadence tick added to find traffic is
a review finding; a new source of messages that wakes nothing belongs in
`tick.wakes_itself` or gets a wake of its own.

**Session logic has one home.** What a frame means, when to catch up,
which lines a capture becomes and what an operator's input becomes on the
wire are `session_view`'s. A host owns its runtime and its view and
nothing else; session logic found in `web_view`, or duplicated in `tui`, is
a review finding. The page compares what each projection was built from, and
not `render_revision`, which moves for stream fragments and tool tails the
page does not draw (question 3 of the step-extraction note).

**Commands, not a shared key vocabulary** (owner, 2026-09-27). Keys stay in
the terminal, and both hosts hand the session the same closed
`msg.Command`. The web view maps its DOM events to it. ADR-014's second
blocker is amended accordingly.

**Daemon control, reconnect and the attachment jobs stay terminal-only**
(owner, 2026-09-27). A session sidebar mounts one component per session.

**The host keeps the loop over a drain's updates** (owner, 2026-09-28,
question 11). One update is the shared unit, and the recorded facts are
applied between updates.

**`step.update` is the entry for a host with no surfaces of its own** (owner,
2026-09-28, question 12, option (a)). The terminal keeps calling the shared
units, and a `session_view` test holds the two orders together. A change to
the terminal's tick order changes `update` and `step_test` too.

**The page runs every session command but adding a directory** (owner,
2026-09-29). `/add-dir` and `/add-write-dir` name a path on the daemon's
host and are refused on the page. A `command.Surface` command is refused
with a notice and never sent as a prompt.

**Effects are values and name their handles.** A step or a lane returns
what it decided; the host performs it, in decision order, against the
handle each effect names, never a handle looked up at perform time. The
web host performs the step's effects inside one `effect.from`, because
Lustre's `effect.batch` does not order them.

**The buffer bound is the host's.** Admission never drops a frame for
capacity, a host reads no more from a mailbox than a buffer has room for,
and admission files a frame only into the inbox whose subject it names, so
nothing from a replaced inbox reaches a reducer after an adoption.
Event-driven delivery changes when a host reduces, not these.

**A page is never more than an operator.** The role is the smallest of the
membership, the ceiling the link was minted with, and Operator. A page
never offers allow for the session, its approval cards sit above the
composer and are drawn from the record alone, nothing from the session
becomes markup, and the page nonce is never rendered into a document.

**Authority and communication are separate.** A peer link grants neither
child custody nor filesystem access. A peer receipt proves durable
admission, not that a model read the message. `busy_only` never wakes an
idle target; `may_wake` is a separate owner choice.

**A virtual read is a capability call.** `cap://` and `job://` are served
through the capability router, not mounted, and prompt guidance must match
the installed router and generated prelude.

**Operator surfaces do not open saved sessions.** The CLI and the terminal
use the membership- and epoch-checked control protocol, and a
listing is never permission to activate a saved target.

## Deliberately open and carried forward

- **The page runs reads for surfaces it does not draw.** After a first
  capture it reads notes, context, advisor nudges and the goal, four round
  trips that hold the lane's command slot, and it reads the context again
  when an operation ends. The owner chose this over choosing which reads a
  host has a surface for. Revisit it if a per-page cost is measured.
- **The page loads no skills catalogue**, so a skill's slash command is
  refused as unknown there. Reading the catalogue is a follow-up.
- **Remote access to the page**, protocol-change/052: a TLS proxy at a
  listed origin with a `__Host-` cookie. Proposed, design only; today a
  remote person uses `ssh -L`.
- **The 053 admin page.** A later phase of 053: loopback only, revoke-only,
  rendering each grant as a `loom access` line.
- **`conformance` declares `prompt` as a dependency and imports nothing
  from it.** Remove it, with the manifest updates that follow.
- The module comment of `session_view/model.gleam` still says the web view
  "will bind" the handles to its relay and `Nil`. It does, so the sentence
  is stale; fix it with the next change to that file.
- The test fixture `pushed.attached()` is a replaying peer with a lane, a
  state the shipped client never reaches.

## Earlier collaboration follow-ups

The collaboration stack landed through #510 at `645b8faf`; protocols 048
and 049 own its wire. [Async collaboration](architecture/async-collaboration.md)
and [messaging](architecture/messaging.md) explain it. Saved-session
outboxes, cross-machine transport, durable actor recovery, and the
outgoing-link limit race remain carried-forward follow-ups. The coordinator
example for following up with already launched children also remains open.
Protocol 054 still needs its previously requested live quiet-web drive to
confirm attachment reaches `Pushing` and rendering follows the pushed rate.
This edition did not re-test the reachability of these items or close them.

## Validation boundary

S6 changed documents only. `make doc-check` is the proof: coverage, the
`AGENTS.md` mirrors and every file:line citation in the documents it
checks. No code was built or run for this edition, so the counts and timings
it relies on are the ones recorded slice by slice in section 5 of
[the step-extraction note](design-notes/step-extraction.md), measured
against the trees named there. The browser hand check of S5 is described
under item 1. Where a document and the code disagreed, the code was taken;
the note's S6 entry lists the disagreements.
