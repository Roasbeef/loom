# Current handoff

This handoff is baselined against `998be7a64` (`main` after #666, the last
pull request that closed [#569](https://github.com/Roasbeef/loom/issues/569))
on 2026-09-30. Tracker state was read with `gh` the same day. Every claim
below was checked against that tree or that tracker; a claim that could not be
checked says so.

## What the previous edition got wrong

The previous edition was pinned to `3088ee3ce`, before the last three lanes of
#569 landed. It is stale in these ways.

- It called #569 open and listed its remaining items as work. All of them
  merged in #665 and #666, and #569 was closed on 2026-09-30 with a comment
  that says so.
- It said the page cannot show settled strands or images, and that 053 phases
  2 and 3 and the invite control were not built. They are built (below).
- It ordered the Trace tab and remote access after the terminal revamp with
  the revamp waiting on #569. The revamp is now first, and #656 and #654 follow
  it.
- It said a streamed code block re-sends the whole block each batch and that
  an unsettled generation leaks its start time. Both are fixed (#658).

The statements about the step extraction (ADR-014's blockers, the shared step)
were checked again and still hold.

## Where the tree is

**Part 1 of #569 is done, and so is the issue.** The session's half of the
client step lives in `packages/session_view`, which depends on `core`,
`machine` and `gleam_stdlib` alone, held there by lint R6. It holds the lane
(`session_channel`), the decoders, snapshot adoption, the projection and the
line builders, and the shared step: the session record
`model.Shared(socket, recorder, source, replay_source)`, the folds of pushed
events and lane updates (`event_fold`, `lane_fold`), the operator's commands
(`commands`), the side-surface reads (`surfaces`), the settle, and
`step.update`.

The two hosts run it in different shapes.

- **The terminal** (`packages/tui`) holds `Model(shared, view)`, with
  `TerminalShared` binding the four handle parameters. It calls the shared
  units one at a time, applies the surface facts each records between the
  drain's updates, and does not call `step.update`. Its socket wakes its
  loop, and `terminal_poll_timeout` follows the lane's deadline with a
  one-second idle ceiling, because a resize needs a poll.
- **The web view** (`packages/web_view`) holds `component.Model(shared,
  view)`. `update` reads the transport's clock once, hands the step a
  message (`Arrived` files, `Ticked` drains and ticks, `Acted` runs a
  command) and derives what it draws from the record the step left. A burst
  of at most 64 frames is one message, and so one render, and one timer is
  armed for the lane's `next_due`. `session_view/step_test` holds
  `step.update` to the order of the terminal's tick.

The lane's pushing refresh is 5,000 ms, and the gateway pushes the roster to
a subscriber (protocol-change/054). [Delivery](architecture/delivery.md)
explains the ordering and ownership, and [the client
architecture](architecture/client.md#the-client-engine-and-its-hosts) is the
map.

**The page today (concept A2, [the web design
note](design-notes/web-design.md)).** `loomd --ui` serves an observer's page
and an operator's page for one session. Both draw:

- **Three collapsible columns** inside `<loom-shell>`: a sessions sidebar
  (operator pages only), the transcript and dock in the centre, and a
  right-hand panel. Buttons at the ends of the top bar hide each side
  column, and a hidden column is inert and out of the tab order.
- **A tabbed panel** with Strands, Changes and Session. Strands holds the
  strand cards and the detail of the strand in focus, and lists settled
  strands after the live ones as a collapsed group (#659). Changes lists the
  files the session's own edits changed, keyed by path, and is always
  present. Session shows the goal, jobs, viewers (operator pages only) and
  estimated cost. There is no Trace tab (#656).
- **Strand focus.** A card, a chip of the agent strip or a timeline row
  focuses a strand, and the transcript, breadcrumb, composer target and
  approval cards follow it. The transcript is a timeline with a dot in the
  hue of each piece's strand. A settled strand can be focused, and the roster
  then lists it.
- **Rows and streams.** The agent strip with cache rings and miss notices,
  turns with folded work, sub-agent, advisor and peer rows, rendered
  Markdown, expandable rows, the todo panel with the reviewer band, live
  reasoning and answer streams, and the newest 150 rows with paging back to
  300 (`Load older`). A streamed fenced code block is drawn as keyed line
  spans, so a batch patches the lines that changed and not the whole block.
  The generation clock restarts per request and on a change of strand, so an
  unsettled generation no longer leaks its start into the next elapsed
  reading (#658). The memory context the daemon attaches to a prompt is shown
  collapsed under it. Advisor nudges are shown read-only.
- **Images** (#661). A transcript row shows the images its message carries,
  served from a same-origin image route that reads under the page's cookie
  (`ui_sessions.images`), so the content security policy does not loosen. The
  operator's composer attaches images with a prompt. An operator's page
  socket takes a 12 MiB frame, and the `PageOperator` connection class is
  charged 64 MiB, which covers the five copies of that frame the submit's
  decode chain holds at once (`ui_socket`, `root.operator_peak`).
- **Keyboard.** `<loom-shell>` listens on the document for three keys
  (`shell_rule.intent`): Command or Control with B toggles the sidebar, with
  Alt as well it toggles the panel, and Escape returns to `main`. A key is
  ignored while composing, when already handled, when held down, and inside
  an approval card. Escape also does nothing in the composer. None of them
  sends a decision.
- **Saved layout and theme.** Whether each side column is open and which tab
  shows are kept in the browser's storage per workspace, under a key built
  from a digest the daemon computes, and the theme (system, light, dark) is
  kept per browser. The storage is two calls, `storage_read` and
  `storage_write` in `web_client/internal/dom.mjs`, reached through
  `web_client/internal/ffi_dom`; `layout_rule` does the rest and reads any
  stored string totally. Nothing derived from a session is stored, and the
  server never learns the layout.
- **The operator's composer** completes slash commands, sends on Command or
  Control with Enter, takes a returned prompt back into the editor, and
  runs any session command a draft names except `/add-dir` and
  `/add-write-dir` (protocol-change/051, the newest addenda).
- **Session switching** (operator pages). A sidebar row for a running
  session other than the one on screen, or an Open button on a peer message
  that names one, asks the daemon for a ticket. `ui_socket` mints it into
  the ticket table with the page's own principal and ceiling, and
  `<loom-switch>` navigates the browser to the exchange address after
  `switch_rule` checks its shape, with `location.replace` so the tab keeps one
  history entry per page and Back does not land on a page whose nonce is gone
  (#658). A ticket whose source page has already ended is refused as
  unknown, so a switch never revives a page past its deadline. A principal
  may hold up to four pages per session (`ending.max_pages`), and a page
  ended by that cap or by a restart says so.
- **Share and invite** (owner's operator page, #663). An "invite to this
  session" control offers an observer button and an operator button. It makes
  the invitation `loomd access invite` makes, with a claim that lives one hour
  (`invites.claim_ttl_ms`), and shows the command and token once in copy
  boxes. A credential may mint three invitations an hour
  (`ui_sessions.reserve_invite`). The page checks the principal and the
  capability again when the click arrives (`ui_socket.invite_for`). The
  protocol-change/051 addendum on inviting from the session page says what a
  stolen owner page is worth.

**Access tooling.** 053 phases 1 to 3 are merged; phase 4 is not. `loom access`
lists principals and memberships and shows one (`host/access`, the grammar
`loomd access` shares), served by `principals.list` and
`principals.memberships` on the client protocol. The terminal's `/access`
overlay (`tui/access_overlay`) shows the same checks `loom access list` and
`show` print (`membership_lines`), and on a rotation shows the `loom access`
line to run in a shell.

The page still cannot show per-call timing, a skills catalogue for slash
commands, or the composer target menu of the design note's section 3.3 (not
built, no owner ruling).

The toolchain is Gleam 1.19.0-rc2 (`.github/workflows/ci.yml`). `make
check-affected BASE=origin/main` runs only the gates a change can affect; a
change to the daemon's package also needs `make signoff`.

## Caller-owned messaging inspection and fair delivery

The messaging work is based on `e79f722de`; its implementation and focused
validation were checked at `54aeb10b4` on 2026-09-29. The upstream web and
issue #569 priorities below retain their order. The original handoff baseline
above describes those upstream priorities rather than claiming this feature
has landed or that its final integration gates have passed.

The default code-mode host now exposes caller-owned pending and transcript
inspection through `cap/peer`, existing recipient admission receipt history,
and linked sender receipt lookup. The router supplies session and strand
identity; `peer.roster` still means authorized outgoing remote links. A queued
steer is eligible after the current complete tool batch and before the next
provider request. This removes repeated-tool starvation without preemption.

Inspection is read-only. Admission is not a read receipt. No new local
post-abort retention or acknowledgement was added. Receipt cursors order hash
keys, so pollers rescan and reconcile identities rather than treating them as
arrival watermarks. Protocol 056 records the decision; the independent review
and focused gate evidence are in
[the messaging review](review/message-inspection-and-steering.md).

The six ownership/pagination/abort tests, seventy-two production code-mode
wiring tests, cap marshalling, model-visible discovery, and real jailed
cap-channel proof passed. The next-request runtime regression checks exact
local and remote bodies after a blocked tool completes. The parent's full
`make check` at `c52038cd2` exited zero, including 2359 client tests, 990 TUI
tests and zero lint errors. The next-request regression fails against the old
policy; the page-seek regression fails against the old SQL. Platform signoff
still must exercise shipped-daemon prerequisites before landing. Hosted macOS
currently has a separately
confirmed baseline `worktree_diff_test` ancestor-read failure; do not describe
that CI as fully green or change messaging scope to work around it.

## Next actions, in order

Terminal CPU work on `tui/render-cpu` is locally verified against installed
`3088ee3ce`: counting strip rows during layout and painting known-width
padding directly reduced frame reductions by 37.6% and scroll reductions
by 40.8% at 200×50, with identical styled-cell witnesses. Full `make check`
passed; the changed client has not been installed or measured live. See
[the measured report](review/tui-render-cpu-2026-09-29.md) for the fixture,
limits and next live check. The changed client still needs the live CPU and scrolling check.

**Check open pull requests and branches first.** A branch may exist and a pull
request may have opened since this baseline. Continue an existing lane rather
than starting a second one.

The owner's order (2026-09-30) is the terminal revamp, then the Trace tab and
remote access.

1. **The terminal revamp, [#655](https://github.com/Roasbeef/loom/issues/655).**
   It takes the web design (A2) as its reference and begins with a design note
   and screenshots for the owner's sign-off, as the web pass did. Decide first
   whether it takes option (d): moving the terminal onto `step.update` with a
   pure `fn(view, facts) -> view` callback the sequencer calls after each
   piece, so both hosts run one sequence. Exit for that decision: a written
   estimate of the three costs the step-extraction note names (callbacks
   through the step, reordering risk that the replay identity checks catch,
   and the Erlang inliner on long settle chains), measured with
   `scripts/tui_perf.sh` and `erlc +time` before any code. The small composer
   notice bug, which reads "prompt_content admitted" after a send, is listed on
   #655 and can go in with it.
2. **The Trace tab, [#656](https://github.com/Roasbeef/loom/issues/656).**
   Two steps. First the untimed list of the latest `code_mode` program's
   calls, drawn from what the page already receives. Then per-call timing: a
   `protocol-change/NNN.md` for per-call start and end fields on the wire,
   bars in the tab, and optionally in the terminal.
3. **Remote access, [#654](https://github.com/Roasbeef/loom/issues/654).**
   [protocol-change/052](../protocol-change/052-web-view-remote-origin.md) is
   still a proposal, and the owner accepts or amends it before work starts. It
   means the page behind a TLS reverse proxy on the daemon's host for remote
   teammates, with a `Host` allowlist and no TLS code in `loomd`. It does not
   mean TLS in the daemon. Before it, measure the server-side re-render and
   diff cost per batch per viewer, and add the mailbox and patch-rate
   metrics the step extraction deferred to 052.
4. **Terminal state.** Land or close PR #583 (#399, #524).
5. **Wake etui on SIGWINCH** before raising the terminal's one-second idle
   ceiling. Exit: resize repaints without waiting for a poll, and a quiet
   terminal wakes only for work its lane or runtime owes.
6. **Measure actual provider token counts** and representative workloads
   before choosing tool search. Exit: measured prompt size, cache-prefix
   behavior and discovery cost, rather than the character estimate in
   [the design note](design-notes/tool-search-and-code-mode.md).

Known small follow-ups, none of which has its own issue:

- The composer notice above.
- A settled strand's row shows no end time, because the roster carries none.
  It needs a wire field, so a `protocol-change/NNN.md`.
- `loom access` takes its global flags before the subcommand.

## How work lands here

[docs/execution.md](execution.md) is the method: briefing, verification and
landing. In practice a batch of ready pull requests lands like this.

1. Make a queue branch, `queue/<name>`, from `main` and merge each pull
   request into it with `--no-ff`.
2. Run `make check-affected BASE=origin/main` and `make doc-check` on it,
   and check the page by hand in a browser against a drive daemon for any
   web change.
3. Push the queue branch and run one Linux signoff on it (`make
   signoff-remote`, about 13 minutes, one at a time, since concurrent runs
   share caches and produce false reds). A flake never blocks a merge: rerun,
   and give the flake its own fix pull request.
4. On green, open a queue pull request and merge it with `gh pr merge
   --admin`, because `main` rejects direct pushes. The constituent pull
   requests close as merged.

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

**053 phase 4 waits for use** (owner, 2026-09-30). The admin page is built
only after the owner has used the terminal's `/access` overlay and says it
leaves a need.

**The page invite keeps both buttons** (owner, 2026-09-30). The observer and
the operator button both stay. The risk is accepted: a stolen owner page can
mint an operator invitation, bounded by three an hour for the credential, and
each invitation is a durable membership the owner can revoke.

**The operator page frame is 12 MiB, and `PageOperator` reserves 64 MiB**
(owner, 2026-09-30). The reservation covers the five copies of a frame the
submit's decode chain holds at once. A change to the frame limit changes the
reservation with it.

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
- **The 053 admin page** (phase 4) is built only on the owner's confirmation,
  after use of the `/access` overlay.
- **The composer target menu** of the design note's section 3.3 is not built
  and has no owner ruling.
- **`conformance` declares `prompt` as a dependency and imports nothing
  from it.** Remove it, with the manifest updates that follow.
- The module comment of `session_view/model.gleam` still says the web view
  "will bind" the handles to its relay and `Nil`. It does, so the sentence
  is stale; fix it with the next change to that file.
- The test fixture `pushed.attached()` is a replaying peer with a lane, a
  state the shipped client never reaches.

## Background watcher lifetime work

The background-watch-lifecycle branch is based on `01f14ef8f` after #667.
Protocol-change/057 adds an explicitly approved session lifetime for Bash and
code-mode background jobs, retaining finite defaults. It also fixes cancellation
grace measured from a stale timestamp before a quiet receive. The installed
`loom-herdr-update` session still runs its earlier release and finite jobs;
this branch does not upgrade that daemon or replay its watcher commands.
Local validation and independent review are recorded in the PR, with hosted
signoff required before landing.

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

This edition changed documents only. `make doc-check` is the proof:
coverage, the `AGENTS.md` mirrors and every file:line citation in the
documents it checks. No code was built or run for it. The description of the
page was checked by reading the source at `998be7a64` (the `web_client`
element modules and their rules, `web_view/view/*`, `component.gleam`,
`ending.gleam`) and the tracker, not by driving a browser. Where the tracker
and the code disagreed, the code was taken.
