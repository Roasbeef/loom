# Current handoff

## Distributed runtime integration (unmerged)

[PR #819](https://github.com/Roasbeef/loom/pull/819) is the single draft review
for issue #697, replacing 37 component PRs while retaining their commits and
review records. Integration source is now `fb6d078e0`. The owner has authorized
TLS BEAM executors, scoped endpoint lifetimes, original native-close proof,
and bounded transcript previews backed by complete durable reports. No API
permission hold remains for those changes. No main merge is authorized.

The [integration guide](design-notes/distributed-runtime-integration.md) maps
components and remaining product criteria. Native execution, semantic workspace
operations, whole Compile, command forwarding and owner custody use the trusted
TLS BEAM endpoint. The merged Weft revision is pinned. Executors share the
runtime trust domain; satellites remain jailed and distribution-disabled, and
executor membership does not grant Raft voting membership.

The scoped native host now fences its original endpoint row, drains transport
while producers remain alive, retains the actual original native close proof,
and releases the journal only after the separate required proofs. The full
executor gate passes 314 tests with no skips. Independent review replayed 17
TLS controls and five compiling mutants. The
[scoped host review](review/distributed-scoped-host.md) states the limits: this
host does not yet own Compile/Launch resources or prove whole-system retirement.

Complete-report storage, foreground rendering, typed capability reads and
owner-local read-route composition are committed. SQLite format 5 reserves the
full allowance before execution, commits the complete report before its bounded
final, validates exact history on reopen, and refuses reclaimable handles for
retention. The authenticated reader installs its route and 261-call ceiling
from one owner/session choice. See the [storage](review/distributed-report-storage.md),
[renderer](review/distributed-report-renderer.md) and
[router](review/distributed-report-router.md) reviews.

A real compiler-path check found that report metadata expected bare hex while
production artifacts use `sha256-` plus 64 hex digits. That mismatch is corrected;
metadata now preserves the original fingerprint while URI content digests retain
their separate bare-hex contract. A real jailed run reproduced the original
failure. A Sol worker has a passing genuine producer/readback run and is adding
actual cross-reference quota exhaustion before freezing the test for root replay.
This evidence is not yet a committed live acceptance gate.

Current root gates pass 186 core tests plus 72 JavaScript finite-value controls,
182 cap tests, 202 storage tests and 707 tools tests. The current focused client
replay passes 101 tests with no skips. The earlier complete client gate at the
storage integration milestone passed 2,855 tests with fifteen explicit optional
SKIPs: one Linux `/proc`, thirteen shipped-server and one rust-analyzer control.
Package lint and documentation checks pass with existing warnings. The previous
aggregate repository run failed a Go sandbox test because PATH selected Codex's
`rg`; its separate Go replay with Homebrew `rg` and full lint passed. That failed
aggregate has not become a passing aggregate by combining later commands.

Two component freezes are awaiting integration. The owner Launch command slice
adds SatelliteCommand validation using original successful Compile custody and
actual Broker clearance; twenty controls and four compiled mutants pass. The
raw terminal decoder validates transport shape and terminal budgets before
large generic MessagePack allocation. Its worker passed 185 core, 24 broker,
36 satellite and twelve JavaScript scanner controls plus five compiled mutants;
a separate Sol reader is reviewing it. The scanner's JS tail recursion is fixed,
while the unrelated generic JS decoder's large-sibling stack limit is explicitly
recorded. Neither freeze has been imported yet.

Astra is reviewing the next concrete Launch/duplex-channel design. Whole Launch
must own token placement after successful Compile, typed uncertain launch,
executor-local listener/token custody, and actual final-recipient consumption
credit. Endpoint request credits cannot substitute for channel consumption.
The owner host must retain completed replies in their original admitted slots
until the bounded writer consumes them. Independent cancellation and original
native retirement remain separate from channel close and report COMMIT.

The corrected P report-custody extension passes 146 bounded cases/probes, with
twelve new report mutations and nine replayed owner mutations. The prior full
P gate passed 126 cases/probes and 56 mutants before that extension; the entire
old mutant suite has not been replayed after it. The
[model review](review/distributed-report-custody-model.md) explains truthful
COMMIT/drain assumptions and the producer-provenance correction. These are
bounded model checks, not an implementation refinement or power-loss proof.

Next: finish the live retained-report gate; integrate the cold-reviewed terminal
preflight and Launch command slices; implement the reviewed Launch resource and
consumed-stream boundary; wire remote LSP and registered daemon assembly; then
run the actual separate-host ordinary-tool/code-mode/LSP acceptance with no owner
checkout. Retained-report companion archive/restore/compaction is still required.
Executor pools, Khepri-backed orchestrator ownership/routing, durable cross-node
messaging and controlled session movement (C1/C2/C3/M1) remain required issue #697
work. The bounded Khepri compatibility probe passed; a production wrapper and
receipt-retention lifecycle are still pending. Current main must be integrated
before the final full repository gate and adversarial assembled-system review.

Preserve the unrelated untracked `packages/client/test/owner_binding_runner.gleam`
and the main checkout's unrelated files. Workers own isolated slices; the root
owns integration, final gates and commits. The PR remains draft until the full
acceptance criteria are met.

The following handoff comes from current main and describes work already on that
branch. Its stated baselines and verification limits remain attached to those
claims.

This file is the handoff: where the tree stands against the work in
flight, what to do next, which rulings are already made, and what is
deliberately left open. It is rewritten at the end of a body of work and
never appended to. A section of it that is dated, or that names a head
that no longer exists, is a sign it was carried forward and not
re-checked.

This edition is baselined against `556e419af` (`main` after #768) on
2026-10-04, and it follows the terminal revamp ([#655](https://github.com/Roasbeef/loom/issues/655),
landed by #760). Every claim below was checked against that tree or
against GitHub on that day. Where a claim could not be checked, it says
so. The previous edition was about 1,400 lines of dated validation
records, one per body of work, and most of them described pull requests
that have since merged; this edition drops those records, and each
body of work's own pull request, review document and architecture page
carries its evidence.

Hosted CI does not gate `main`. The `signoff/linux` status posted by
`scripts/signoff.sh` does, and #760 and #761 both landed on a green one
(1410 s and 1336 s, skip census clean). The hosted runs on `main` for
the 2026-10-04 merges were not green when read: those for #745 and #760
were cancelled by later pushes, and those for #753 and #761 were queued
or pending. That is the state of the hosted record, not a failure of
the code, and it was not re-run.

## Where the tree is

| Body of work | Where it stands |
|---|---|
| Terminal revamp ([#655](https://github.com/Roasbeef/loom/issues/655)) | Landed as #760 (`2625d2251`): all sixteen layers of stack #718. Open edges and follow-ups below. |
| protocol-change 059, strand message origin | Accepted 2026-10-03, reader and writer both on `main`. No release has been cut since `v0.2.0` (2026-09-14), so the next release carries both. |
| protocol-change 060, code-mode call record | Accepted. The record, the terminal's rows and the web Trace tab's rows are built. The live feed for a running program is not ([#765](https://github.com/Roasbeef/loom/issues/765)). |
| Web view | Four-tab panel (Strands, Changes, Trace, Session), a visual system, a home page that opens running and saved sessions, a Home button on pages it opened, an invitee-chosen name. PRs 1, 2, 3 and 6 of workspace mode's ten are built. |
| Executor service ([#696](https://github.com/Roasbeef/loom/issues/696)) | Closed. Landed as #727 and #732; `broker/direct` is gone. |
| Language servers | Stack merged (#680), SQL observations (#693), dependency preparation (#728). |
| Flake fixes | #746 and #747 merged through #761. #513 is still open. |

### The terminal revamp

#760 is a queue pull request. Its head, `22a0a7362`, is the top of stack
#718 and carries every layer, which is why `signoff/linux` on that one
commit covers all of them. The layers, bottom to top, were #708 (the
design note), #709 (session picker), #710 (workspace and the
seven-agents strip), #711 (full-frame render helper, failed count,
folded polls), #712 (identity line, rounded input frame, approval
block), #713 (message headings, one-row turns, call and result rows),
#714 (code-mode blocks), #715 (the 060 call record), #716 (call counts
and call lists), #717 (image placeholder rows), #729 (drawn images),
#731 (per-workspace layout memory), #733 (the docked rail), #734 (the
rail's tabs), #735 (the narrow-terminal sheet) and #739 (the 059
writer). #708 shows as merged; the other fifteen were closed with a link
to #760.

What a reader needs to know about the result, with the module that
holds it:

- **Layout.** At 120 columns or wider the rail docks beside the
  transcript with four tabs, Strands, Changes, Trace and Session
  (`tui/rail`, `rail.narrowest`). It is docked by default from 160. Below
  120 the same four tabs are a sheet that replaces the transcript and
  leaves the input frame, strip and footer in place (`layout.sheet_shown`).
  The 100-to-119-column 34-cell rail no longer exists.
- **Layout memory.** `<state-dir>/tui/layout.json`, keyed by a digest of
  the workspace path (`tui/layout_memory`, `tui/layout_save`). It records
  the rail and the tab, only when the operator chose one, and keeps 64
  workspaces. A missing, oversized, foreign or malformed file is an empty
  memory, so it cannot stop a launch.
- **Images.** Placeholder rows read dimensions from the image header
  (`session_view/image_header`). Drawn images use kitty graphics with
  Unicode placeholders and OSC 1337 for iTerm2, through etui, which is
  pinned at `4d5e466` in `packages/tui` and `packages/client`. The
  `o` key opens an image externally without new FFI.
- **Trace.** `session_view/trace_view` is one module used by both hosts.
  The web view calls `fold`, the terminal calls `newest`, and 060 call
  rows appear in both.
- **059 release N+1.** The Agency writes `StrandOrigin` on briefs and on
  `agent_send` messages (`client/agency`). `docs/updating.md` carries the
  rule that every older client must be stopped before that release is
  selected.

The call record, the design and the as-built notes for slices 14 and 15
are in `design-notes/terminal-design.md`. Option (d) of #569, moving the
terminal onto `step.update`, was not taken and is not a prerequisite of
anything built (`review/terminal-option-d-2026-09-30.md`). Slice 16,
strand focus from the timeline, was not built.

### The web view

The panel has four tabs, not three: #742 added Trace, which lists the
`code_mode` programs a session ran and each program's calls, and #751 filled in the rest of the panel. #740 gave the page a
visual system, #741 reworked the top bar and sidebar, #748 and #749
rebuilt the transcript rows, the dock, the composer and the approval
card, and #725 and #726 moved advisor commentary and nudges out of the
lane and dock into the panel. `loomd --ui`, or `[daemon] ui = true`
(#690), serves it.

Workspace mode ([design note](design-notes/web-workspace-mode.md),
[protocol-change/065](../protocol-change/065-web-workspace-mode.md)) is
ten pull requests in the note's section 7, and four have landed: PR 1,
the read-only home page (#743, `loom ui` with no `--session`); PR 2,
navigation (#752, merged through #757: a running session's row on the
home opens it, and a session page opened from the home has a Home
button); PR 3, opening a saved session (#768: a saved row on an
operator-ceiling home or session page is a button, and the daemon runs the
control command's own authority check, opens the session and waits up to
30 seconds for it to be resident); and PR 6, the claim name (#750,
`loom claim --name`). Not built: PR 4 (creating a session), PR 5
(`sessions.members` and the admin page), PR 7 (credential kinds), PR 8
(the browser login), PR 9 (the browser claim) and PR 10
(`principals.rename`, optional). 065's status line says only that "PR 1
of the plan is on `main`". That is stale, since PRs 2, 3 and 6 are on
`main` too, and the next change to 065 should correct it.

#757 also carried the owner's two rulings of 2026-10-04 on the login's
security review (#754, folded into 065 and the design note): the admin
page and device links are minted only from a `Fresh` home, one opened by
`loom ui` or a claim, never from a `Resumed` home reached by the
thirty-day login or a page's Home control. #755 fixed the Trace and
Changes tabs skipping a call made beside visible prose.

### The executor service

The previous edition described #696 as a stack of six phase branches to
merge bottom up. They merged differently: #698 and #699 merged on
2026-10-02, #727 landed the service stack as one queue pull request
(with #700), and #732 finished the follow-ups. #701 and #704 through
#707 were closed without merging; #727 is what landed. `broker/direct` is deleted
and every session's effect plane runs `broker/executor`. The design is
`architecture/executor.md`, the decisions are ADR-017 and ADR-018, and
the witnessed-kill rules are the addenda inside protocol-change/014.
Read those before touching the lifecycle; the invariants live there and
no longer in this file. Open: [#703](https://github.com/Roasbeef/loom/issues/703)
(`OutputIsWire` leases stream with no output cap), [#283](https://github.com/Roasbeef/loom/issues/283)
(idle retirement, which the service only has to not block), and the
epic [#697](https://github.com/Roasbeef/loom/issues/697) for remote
executors. `make executor-smoke` and `make bench-exec` exist.

### The runtime projection cache

#724 keeps the strand's pure default projection beside the leaf-keyed scan
cache, so planning over an unchanged leaf reuses the projected messages
instead of rebuilding them; a live profile had found the same leaf rebuilt
15 times in three seconds. Appends, forks, rewinds, compaction and a cold
restart invalidate it through the scan cache's existing rules, and
request-local transforms stay outside it. The same pull request projects
the reaper before building the provider worker closure, which had captured
the whole driver. The live profile is
[daemon-profile-2026-10-02](review/daemon-profile-2026-10-02.md). The
runtime package gate runs `scripts/projection_cache_bench.escript ...
--expect-cached`, which checks both the cache-hit reductions and what the
provider worker closure captures, so restoring either old behaviour fails it.
A matched installed-daemon comparison is still item 8 below.

### What the previous edition got wrong

- It named the terminal revamp as the first item of work, to begin with
  a decision about option (d). The revamp is done, and option (d) was
  measured and deferred.
- It said the web page has no Trace tab and three panel tabs. It has
  four, and the Trace tab exists. What is still missing is timing bars,
  which stay under [#656](https://github.com/Roasbeef/loom/issues/656).
- It told the next session to "land or close PR #583". #583 merged on
  2026-10-01, and the same edition's own corrections section said so.
- It described #679, #683, #687, #689, #691, #693 and #719 as pull
  requests awaiting verification or merge. All seven merged between
  2026-10-01 and 2026-10-03.
- It listed the executor branches as work to merge. See above.
- It cited "protocol 062" for two different documents. `protocol-change/`
  holds duplicate numbers for 056, 057, 062 and 065 (see the working
  notes), so cite a protocol change by number and name.
- protocol-change/065 says its four rulings are recorded in this file.
  They were not. They are summarised under "Rulings already made" and
  live in 065 and its design note.
- The claim that the daemon's installed build was `a3dc2535` and had no
  RSS saving could not be re-checked from the tree. It is dropped; check
  `loomd` on the running machine before quoting it.

## What to do next

Check open pull requests and branches first, and continue an existing
lane rather than starting a second one. The order below is a
recommendation, not an owner ruling, except where a ruling is cited.

1. **Try the revamp on real terminals.** Drive `bin/loom` in Ghostty,
   iTerm2 and WezTerm, in its own window, at 200x50, 120x40 and 80x24,
   with an image row and a resize across 120 columns. Exit: the kitty
   placeholder path is shown to work, or to fall back cleanly, on a real
   Ghostty; the XTVERSION assumption in the first open edge below is
   confirmed or fixed in etui; and what was seen is recorded beside the
   frames in the design note. **Cut list:** no new layer, no strand
   focus from the timeline, no redesign.
2. **Cut a release before main drifts further.** Nothing has been cut
   since `v0.2.0`, and `main` now writes the strand origin, so an
   older client that reaches a session written by a build from `main`
   fails the whole session on its first strand-origin entry. Exit: a release whose notes carry
   the 059 stop-every-older-client instruction from `docs/updating.md`,
   built and verified by `make release-smoke`. The user cuts releases.
3. **The four revamp follow-ups, in this order.**
   [#766](https://github.com/Roasbeef/loom/issues/766) first: the Trace
   tab is re-derived on every paint, which is a cost the terminal pays
   forever and is a small change. Then
   [#764](https://github.com/Roasbeef/loom/issues/764) (a peer session
   shows as `session 01a07d74` outside the picker; naming it needs a
   fetch the client does not make today), then
   [#763](https://github.com/Roasbeef/loom/issues/763) (harness notices
   are written as user messages with no origin, so they draw as operator
   turns; telling them apart needs a wire marker, which is a
   `protocol-change/NNN.md`, and the client must not match the `[loom] `
   text), and
   [#765](https://github.com/Roasbeef/loom/issues/765) last, because the
   live call feed is protocol-change/060's optional slice 5 and needs
   the owner's decision before work. Exit for each: its own issue's
   acceptance, with the frame in `packages/tui/test/frame_scene.gleam`
   updated where a row changes.
4. **Timing bars in the Trace tab, [#656](https://github.com/Roasbeef/loom/issues/656).**
   The 060 record carries per-call offsets, and neither host draws them.
   Exit: the web tab draws bars from the offsets with the status class
   taken from the closed `CallStatus`, and the terminal's Trace tab
   states duration on slow and failed calls only if that is what the
   design note says. Fix the stale module comment in
   `web_view/view/trace.gleam` in the same change; it still says no
   capability call is recorded.
5. **The rest of web workspace mode.** Section 7 of
   `design-notes/web-workspace-mode.md`: PR 4 (creating a session)
   continues the chain PRs 1 to 3 began; PR 5 (the
   admin page) needs PR 1; PR 7 (credential kinds) is independent and
   lands before PR 8 (the browser login), which needs PRs 1 and 7; PR 9
   (the browser claim) needs PRs 6 and 8; PR 10 needs PR 5.
   Exit per PR: the invariants its section lists, a Fable review, and a
   browser drive against a drive daemon. **Cut list:** the observer page
   keeps its no-sidebar behaviour, and nothing here adds TLS.
6. **Remote access, [#654](https://github.com/Roasbeef/loom/issues/654).**
   [protocol-change/052](../protocol-change/052-web-view-remote-origin.md)
   is still PROPOSED. The owner accepts or amends it before work starts.
   It means the page behind a TLS reverse proxy with a `Host` allowlist
   and no TLS code in `loomd`. Before it, measure the server-side
   re-render and diff cost per batch per viewer.
7. **Executor follow-ups.** #703, then #283.
8. **A matched installed memory measurement, [#454](https://github.com/Roasbeef/loom/issues/454).**
   Same workload, same observation cuts, installed baseline against
   candidate; keep process heaps, allocator carriers and OS RSS
   separate. Unchanged from the previous edition and not re-checked.
9. **Two items carried unverified.** Waking etui on SIGWINCH before the
   terminal's one-second idle ceiling is raised, and measuring actual
   provider token counts before choosing tool search
   (`design-notes/tool-search-and-code-mode.md`). Neither has an issue,
   and neither was re-checked against the tree for this edition.

## Rulings already made

Each of these is settled. Re-open one only with new evidence, and
record the reopening where the ruling lives.

### Settled during the terminal revamp

**`/summary` is the full-screen summary at every width.** Session is
reached by its digit, `4`, and no `/session` command exists.
`design-notes/terminal-design.md`, slice 14.

**The strip under the input stays visible on Trace and Session.** The
digits choose a tab while the rail has the keyboard. Same place.

**The 34-cell rail for 100 to 119 columns was removed in favour of the
sheet.** The sheet is not a preference: opening it records no choice and
a launch never opens it. Slice 15.

**Growing past 120 columns closes the sheet and keeps its tab without
auto-docking.** A notice says so (`sheet closed · Shift+Tab docks the
rail on ...`, in `tui/submit`). Narrowing with the rail docked opens
nothing over the transcript being read.

**Layout memory records only real choices.** Changes is never
remembered, because it opens an observation a launch has not made.

**059 ships its reader and writer in the same next release.** The
two-release rollout the proposal described did not happen, so every
older client must be stopped before that release is selected.
`docs/updating.md`; protocol-change/059, "Decision".

**A merge on a busy main may use a narrow re-gate** (owner, 2026-10-04):
when `main` moves without conflicts after a green signoff, run the
affected gate against the new base and merge. `docs/execution.md` §5.

### Web workspace mode

Owner rulings of 2026-10-03, recorded in
[protocol-change/065](../protocol-change/065-web-workspace-mode.md) and
its design note: a browser may hold a thirty-day login that is itself a
macaroon-style credential; a browser claimant is never shown a key;
sessions are created only in a workspace the owner already has sessions
in; and an operator-ceiling page opens a saved session through the
control command's own checks. Those amend four earlier rulings: "daemon
control stays terminal-only" admits creation from an owner's operator
home, "operator surfaces do not open saved sessions" admits that
page (implemented by #768, under the new wording "a listing is never
permission to open a saved session; the control command's own checks are":
the principal's role in the target, Owner or Operator, is what grants it,
and an observer-ceiling page or an observer member is refused), "053 phase 4 waits for use" is superseded by the admin page in
065, and the observer-sidebar ruling holds for one-session pages only.
The owner's two further rulings of 2026-10-04, the `Fresh` home origin
for the admin page and device links, are in the addendum at the end of
065. 065 is a draft; these amendments take effect with its pull requests,
not before.

### Carried forward from earlier editions

These were checked to still hold in the tree where a symbol is named.

**Hosts do not poll for traffic.** A frame is reduced when it arrives.
A host sleeps until `session_channel.next_due`. A fixed-cadence tick
added to find traffic is a review finding; a new message source that
wakes nothing belongs in `tick.wakes_itself` or gets its own wake.

**Session logic has one home, `session_view`.** What a frame means, when
to catch up, which lines a capture becomes and what an operator's input
becomes on the wire are its. A host owns its runtime and its view.

**Commands, not a shared key vocabulary** (owner, 2026-09-27). Keys
stay in the terminal; both hosts hand the session the same closed
`msg.Command`.

**Daemon control, reconnect and the attachment jobs stay terminal-only**
(owner, 2026-09-27), as amended above for 065.

**The host keeps the loop over a drain's updates, and `step.update` is
the entry for a host with no surfaces of its own** (owner, 2026-09-28,
questions 11 and 12). A change to the terminal's tick order changes
`update` and `step_test` too.

**The page runs every session command but adding a directory** (owner,
2026-09-29). A `command.Surface` command is refused with a notice and
never sent as a prompt.

**Effects are values and name their handles.** The web host performs a
step's effects inside one `effect.from`, because Lustre's `effect.batch`
does not order them.

**The buffer bound is the host's.** Admission never drops a frame for
capacity.

**A page is never more than an operator.** The role is the smallest of
the membership, the ceiling the link was minted with, and Operator. A
page never offers allow for the session, and nothing from the session
becomes markup.

**The page invite keeps both buttons** (owner, 2026-09-30), bounded at
three invitations an hour per credential. **The operator page frame is
12 MiB and `PageOperator` reserves 64 MiB** (owner, 2026-09-30); a
change to one changes the other.

**Authority and communication are separate.** A peer link grants
neither child custody nor filesystem access, and a peer receipt proves
durable admission, not that a model read the message. `busy_only` never
wakes an idle target.

**A virtual read is a capability call.** `cap://` and `job://` go
through the capability router and are not mounted.

**Language servers** ([ADR-015](adr/015-language-servers-as-jailed-leases.md),
[ADR-016](adr/016-language-profiles.md)): positions never leave
`packages/lsp`; gate every request on advertised capabilities; edits
land only through hashline and `workspace/applyEdit` is declined; the
harness never reads a path a server merely names; enforcement is proven
before a server starts. A wedged server can still hold the helper's
stdin mutex that `Cancel` needs until the broker's three-second kill
(ADR-015 section 1); that is known and unfixed.

**Exact-action consent cannot become general wall authority,** and
session job attribution and broker custody have different identities
([protocol-change/061](../protocol-change/061-watch-and-lsp-reliability.md)).

**`strand.wait` slices past the host clamp, and the clamp stays**
([protocol-change/062-strand-wait-slicing](../protocol-change/062-strand-wait-slicing.md)).
A never-settling child now blocks up to the program's own deadline;
raising `max_wait_ms` was rejected.

**Style gates** (issue #593): R13 to R16 fail the build. Never pad a
module doc with helper names to quiet R18.

## Deliberately open

None of these is unfinished work somebody forgot.

- **The Ghostty XTVERSION prefix.** etui believes kitty placeholders
  only when XTVERSION names kitty or Ghostty, and assumes Ghostty's
  reply starts with `ghostty`. It has not been tried on a real Ghostty.
  The etui `examples/image` prints the reply to check. Undesigned risk,
  not unbuilt work; item 1 above retires it.
- **The demo shows mostly empty states in the rail's tabs.**
  `bin/loom --demo` seeds an image row (`tui/demo_image`) but no goal,
  jobs, calls or strands for the Strands, Trace and Session tabs.
  Unbuilt; cheap, and no issue.
- **Strand focus from the timeline** (slice 16 of the terminal design,
  question 4). Waits for the owner.
- **The 060 live feed** ([#765](https://github.com/Roasbeef/loom/issues/765)).
  A running block shows no calls until its result arrives. Needs a
  decision, since it adds a durable or wire shape.
- **053 phase 4, the admin page,** is now 065's PR 5 and waits on the
  chain above.
- **The composer target menu** of the web design note's section 3.3 and
  the page's skills catalogue are not built, with no owner ruling.
- **The page runs reads for surfaces it does not draw** (notes, context,
  nudges, goal). The owner chose this over per-host read selection.
  Revisit only if a per-page cost is measured.
- **Epics [#697](https://github.com/Roasbeef/loom/issues/697),
  [#720](https://github.com/Roasbeef/loom/issues/720) and
  [#730](https://github.com/Roasbeef/loom/issues/730)** (remote
  executors and runtime observability) are designs. Open pull requests
  #756 and #758 begin the first of them (distributed runtime foundations
  and remote admission custody); they were not reviewed for this edition.
- **Issue [#672](https://github.com/Roasbeef/loom/issues/672)** is the
  revamp's design-review thread and is still open. Its rulings are in
  the design note. Not re-checked whether #504 and #447 (rail and
  changes pane together, nudge text in compact mode) are answered by the
  revamp.
- **Release blockers** still open: #18, #26, #30, #31, #32. Not
  re-read for this edition.

## Working notes

**Landing a `gh stack`.** `gh stack merge` needs `signoff/linux` on every
layer head, and only the top is signed off. Land through a queue pull
request whose head is the signed-off top, then close the other stacked
pull requests with a link to it. This is how #760 landed.
`docs/execution.md` §5 has the steps.

**Protocol-change numbering has collisions.** 056, 057, 062 and 065 each
exist twice. Cite number and name, and take the next free number when
adding one. The root `CLAUDE.md` still says there are thirteen
protocol changes; there are 71 files.

**Toolchain.** Gleam 1.19.0-rc2 (`.github/workflows/ci.yml`), pinned
because it carries the path-dependency fix.

## How to verify

`make check` is the full gate, and `make check-affected BASE=origin/main`
runs only the gates a change can affect. Run `make fmt`, `make doc-check`
and `make lint` before every push; `make check` does not include
`make doc-check`. A change to the client, the daemon or shipped
fixtures also needs `make signoff` or
`LOOM_SIGNOFF_HOST=<ssh alias> make signoff-remote`, one at a time.
`make executor-smoke`, `make release-smoke` and `make selftest` cover the
executor, the release and the sandbox layers.

**Read a gate's own exit code.** Piping `make` into `tail` reports
`tail`'s status and has produced a false green here twice.

**A local macOS run is not the authority for two skips.** The MCP
server death test needs `/proc`, and the LSP manager test needs
`rust-analyzer`. `signoff/linux` provisions both.

**A new `dispatch.install` caller needs a `scripts/serial-tests` line,**
because capability channels are VM-global.

**Never put a worktree under `/tmp`.** Code mode refuses a cap socket
there, since the jail replaces `/tmp`.

**A capability change needs a rebuilt code-mode seed.** The seed is
offline. Run `make codemode-seed` in any fresh worktree before a code-mode
drive, and check the log for `codemode.ready`.

`docs/execution.md` has the rest: briefing, monitoring, the verification
standard and the hazards that have cost real time.
