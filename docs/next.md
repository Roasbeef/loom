# Current handoff

The MCP extraction is rebased onto `origin/main` at
`275efc42e7909c3c3ec481b7466c3484f381eb80`, including the typed capability
surface from PR #670. Recovery refs retain the previously tested `a569e1f68`
and `a102a3523` heads. The import conflict retains both main's typed-operation
module and the extracted SDK client; the package documentation retains both
main's typed schedule projections and the MCP boundary. Main's capability
sources, generated prelude and protocol 057 remain unchanged by extraction.

The independent GPT-6.1 Sol review at high reasoning found no high or medium
findings at `14dc4545d`; its stale ownership comment was corrected without
changing executable code. The preceding published head `a102a3523` passed
complete hosted Linux/macOS CI in [run 36795638550](https://github.com/Roasbeef/loom/actions/runs/36795638550)
and a fresh containerized Linux signoff, including all six lanes, release
updates and a clean skip census. Its full local gate passed with 2,401 client
tests and zero lint errors. These results belong to that head; validation of
the latest rebase is recorded on PR #669 before merge.

## Standalone MCP extraction

Generic JSON/JSON-RPC, framing, client actors and native process custody
live in [Gleam MCP](https://github.com/Roasbeef/gleam-mcp). Both direct
consumers and the conformance closure pin
`686955fc0461630bf64a4dc8eb51565dc7ca1ac9`. Its full Linux/macOS CI passed
[run 36765278006](https://github.com/Roasbeef/gleam-mcp/actions/runs/36765278006):
232 unit tests, including every required Draft 2020-12 vector; 139 linter
tests; five tooling checks; and 39 native stdio/HTTP/TLS checks. Independent
review findings were fixed and rechecked before publication.

The direct Mist dependency matches the SDK at
`28b43178ff57bfb619c64b8c3544831646d5fdb9`; all affected locks resolve Glisten
to `3eb785919be0736da0a20732a56275dce0132327`. Glisten registers its connection
factory before its listener and acceptors start. Mist registers its SSE
factory before Glisten starts. Reverse shutdown stops admission before
retiring those factories. Mist's framing and startup fixes passed
[CI](https://github.com/Roasbeef/mist/actions/runs/36764236673) and remain
open in [PR #2](https://github.com/Roasbeef/mist/pull/2) and
[PR #3](https://github.com/Roasbeef/mist/pull/3).

[Glisten PR #1](https://github.com/Roasbeef/glisten/pull/1) merged into
`compat/v9.0.1` at `1e53a4d9befb3fe6fb6f9cee2d9b13ba621a2e67`. Consumers
retain the tested `3eb7859` commit rather than moving to that merge commit.
The upstream startup-order report is
[rawhat/glisten#55](https://github.com/rawhat/glisten/issues/55).

The SDK adds released MCP `2026-07-28`, typed tool definitions, HTTP, explicit
multi-round-trip continuations and owned subscriptions. Loom continues to
use its initialized stdio profile and supplies its own client identity,
server isolation and result reduction. Optional resource and prompt APIs
are tracked in [SDK issue #1](https://github.com/Roasbeef/gleam-mcp/issues/1).

`packages/mcp` retains four pure adapters: code generation, schema planning,
name sanitization and MessagePack interchange. Frozen core and capability
interfaces are unchanged. `client/mcp` reduces lossless non-text content
only when constructing the existing capability result. The generic suites
moved with their implementation; local adapter and actual-server fixtures
remain here. Current main's other dependencies, including weft 0.4.5 and
its shared UI packages, were preserved during rebase.

The fresh offline seed and focused `make check-mcp` passed at `7b8cd39f9`,
each with its own zero exit status. The full local `make check` also exited
zero through the public SDK/Mist/Glisten pins with that fresh seed and the
CI-matching patched Gleam 1.19.0-rc2 compiler. All packages, native tests,
static gates and lint passed; lint reported zero errors and 943 warnings.
Published extraction head `6de0188aaea01ede036082d0d5c19ce0d06dd5af`
passed the required Linux gate and macOS advisory package check in
[run 36767905423](https://github.com/Roasbeef/loom/actions/runs/36767905423).
A fresh public Linux checkout built its helper and seed, then passed 102
adapter tests, 29 native client MCP tests and both actual MCP/configured-server
code-mode exchanges with no skips. An independent rerun of both E2Es passed
at that same head. These results belong to `6de0188`, rather than being
reassigned to the subsequent fixture correction.

The first macOS e2e attempt timed out observing the shipped multiplayer tool's
return to idle after its final answer was visible. The original shipped-bootstrap
target passed locally, followed by five fresh runs of the original multiplayer
module. The hosted rerun also passed bootstrap. The first timeout remains
intermittent with no established source cause; no deadline or assertion changed.

The macOS rerun then failed `worktree_diff_test.gleam:95` with GitFailed(128),
matching [exact base main `01f14ef8`](https://github.com/Roasbeef/loom/actions/runs/36694588061/job/109820029705).
The earlier assumption that repository layout alone explained this failure was
incomplete. A normal local clone still passed under Apple Git 2.39; changing
only the Git version to 2.55 reproduced the failure. Both independent runs
used the original source and helper: fourteen tests passed under 2.39, while
2.55 failed one with `fatal: error reading '<checkout>/.git'`.

The uninitialized fixture was beneath the source checkout, so it did not
satisfy its outside-Git premise. Seatbelt correctly denied reads of ancestor
repository metadata, and Git 2.55 treats that discovery denial as fatal.
Correction `b69de8672` constructs private fixtures under `/var/tmp`, following
the existing shipped-jobs convention and avoiding Linux's `/tmp` scratch mount.
All fourteen assertions pass on the changed source under Git 2.55 with no skips.
The full client gate also passed under Git 2.55: 2,398 tests, formatting and
warning-free compilation. The documentation check exited zero.
The sandbox grants, production error classification and test deadlines remain
unchanged. Independent review found no additional affected assertion.
Published correction head `314c3071c` passed its required Linux gate. Its actual
Linux jail ran all fourteen observations under Git 2.55 with eleven enforcement
layers active and zero skips, and its terminal-observation skip census was clean.

That head's macOS run passed multiplayer, then failed the shipped-confinement
turn at `daemon_shipped_confinement_test.gleam:353` before reaching the corrected
Git fixture. The interval between the token tool-use and final-text provider
announcements was 7.887702 seconds; the final announcement preceded the original
eight-second UI timeout by only 32.902 ms. That interval includes transport,
durable transitions, tool execution and the next provider request, so it cannot
be attributed to shell execution from the uploaded evidence. Five fresh local
runs of the original confinement fixture passed. Neither this timeout nor the
earlier multiplayer timeout has an established source cause.

Diagnostic commit `759ab088d` uses the existing terminal recorder in those two
fixtures, with unique session/role paths. Their assertions and deadlines remain
identical. `LOOM_TEST_TIMING=1` adds a second stock OTP handler only to the private
shipped daemon launcher; it retains UTC event timestamps and existing debug
provider/tool dispatch and settlement events without changing the JSON handler.
Terminal recordings are unconditional in the two fixtures; the extra daemon
handler is opt-in. Its 8,192-character limit applies per event, not to the file.
The actual local confinement and multiplayer suites passed with this handler,
and their generated logs and raw frames were inspected. Independent review
approved the unchanged cleanup, grants and assertions. The complete local
client gate also passed all 2,398 tests, formatting and warning-free compilation;
the documentation check exited zero.

CI commit `a0300e896` enables this evidence for shipped bootstrap and uploads the
private effect logs and terminal recordings. The original hard macOS terminal
observations run before bootstrap so its failure cannot hide their result; the
zero-skip census and failing fan-in are unchanged. Pre-rebase head
`a569e1f681fae2098979ff79bd327fc30e43ebde` passed both aggregate gates in
[run 36779051580](https://github.com/Roasbeef/loom/actions/runs/36779051580).
Its timing artifacts were inspected. Both intermittent timeout causes remain
unconfirmed; a green run does not prove their correction. The rebased head
requires its own hosted verification.

[Jevelin MCP](https://github.com/Roasbeef/jevelin-mcp) consumes the SDK and
existing Jevelin library directly. Published application head
`fb5b434bde8d48736c835d44a4a176efb17d007d` passed Linux/macOS CI in
[run 36766066616](https://github.com/Roasbeef/jevelin-mcp/actions/runs/36766066616).
Its four shared typed definitions retain original label/rubric/batch
decoders. An independent Linux build passed the full application gate through
the public dependencies, then fifty fresh runs of the original HTTP peer.
Those runs retained all assertions, including 150 bearer refusals and fifty
Origin refusals. The inherited startup blocker is closed by the published
factory-order fixes above. No authenticated live Jev request has been made.

[PR #669](https://github.com/Roasbeef/loom/pull/669) records the current
validation boundary and review status. Continue to require the full gate,
real native MCP process and configured-server code-mode exchanges when
updating this dependency. Remote MCP admission policy remains separate
from the reusable library's HTTP implementation.

## Existing work on main

The preceding main handoff is preserved below. Its references and validation
are attached to the heads it names, rather than reassigned to this extraction.


This handoff is baselined against `998be7a64` (`main` after #666, the last
pull request that closed [#569](https://github.com/Roasbeef/loom/issues/569))
on 2026-09-30. Tracker state was read with `gh` the same day. Every claim
below was checked against that tree or that tracker; a claim that could not be
checked says so.

## Herdr integration corrections (this branch)

The `tui/herdr` adapter was audited against upstream herdrdev/herdr
(v0.9.1 locally, v0.9.3 upstream) and four real bugs were fixed. The
previous wire format was schema-valid but claimed an identity Herdr
cannot honor: it reported under the reserved `herdr:loom` source, and
its docs claimed session restore keyed off the announced session id —
but Herdr's `agent_session_id` restore path is gated by a hard-coded
allowlist of its own integrations (`is_official_agent_source` in
upstream `src/agent_resume.rs`), in every version through 0.9.3, so
resume never worked and the announce was dead weight. The adapter now:

- reports under the third-party source `loom:terminal` (the `herdr:`
  prefix is reserved for Herdr's own integrations, per their
  add-herdr-support guide)
- carries `resume_argv` `["loom", "--session", <id>]` on every state
  report — the actual third-party resume mechanism, honoured by Herdr
  0.9.2+ and safely ignored by older servers
- queues `pane.release_agent` on quit as the last effect of the step,
  a bounded synchronous exchange the runtime performs before the loop
  exits, so the pane clears before the VM halts instead of waiting for
  Herdr's idle-shell safety net
- names the pending approval in a blocked report's `message` (tool +
  preview, with a count when several queue up), and the message is part
  of the change comparison, so a second approval while blocked
  republishes

What was already correct and is pinned by tests: the env gate, NDJSON
framing, one-request-per-connection exchanges, the `PaneAgentState`
enum, the wall-clock sequence seed, and change-detection. Herdr 0.9.1
→ 0.9.3 upgrade is safe for existing panes (no breaking change beyond
the removed pane-graphics API, which Loom never used) and is what
activates `resume_argv`.

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

The messaging work landed in #667 at `01f14ef8f` on 2026-09-30. The upstream
web and issue #569 priorities below retain their order; their original
handoff baseline above is separate from this messaging update.

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
policy; the page-seek regression fails against the old SQL. The final PR head
`00229385e` passed the fresh-container Linux signoff, including all six lanes,
release verification and the skip census, before #667 merged. Hosted macOS
has a separately
confirmed baseline `worktree_diff_test` ancestor-read failure; do not describe
that CI as fully green or change messaging scope to work around it.

## Typed capability follow-up

The owner's follow-up covers `cap/peer`, `cap/workflow`, `cap/execution`,
`cap/strand`, `cap/job` and `cap/schedule`. [Protocol 057](../protocol-change/057-typed-capability-results.md)
records the approved source API migration, and [the migration guide](capability-types.md)
names the public records, variants, identity parsers and cursor constructors.
Peer pages and receipts are decoded inside the satellite; workflow and
execution preserve channel error categories. Child and job identities and
independent cursors are validated before they become usable handles. Schedule
creation and listing expose granted cadence projected from the host's timing
record, while keeping `when` for display.

The wire shapes remain unchanged except for the additive schedule cadence
field. Sender-owned payloads and custom metadata remain open values. Authority,
delivery priority, admission semantics and retention remain those of #667.
The generated capability prelude prefers each module's own public identity
aliases, so peer-only host programs need no child-strand import.

The follow-up on `cap/typed-surface` is rebased onto `01f14ef8f`. The full
`make check` at `01844b49a` exited zero, including 126 cap tests, 2,399 client
tests, 1,032 terminal tests and zero lint errors. Real jailed proofs cover
peer inspection with exact bodies in both host modes, schedule admission,
listing and cancellation, resident actor input, cross-session grants and
workflow recovery. The independent review's custom metadata collision and
lost body assertion findings were fixed and rechecked. Negative checks kill
both defects, invalid-ID admission, negative-cursor clamping and the original
alias renderer. Capability mutations need a rebuilt code-mode seed; the final
full gate used a restored seed. Hosted CI and Linux signoff on the new PR
remain separate from this local verification.

## Language-server support (issue #25)

Loom's own agent can ask a language server about the code it is editing. The
ruling is [ADR-013](adr/013-language-servers-as-jailed-leases.md) and the
account is [the LSP architecture doc](architecture/lsp.md). Read both before
touching any of it; the ADR's "Measured" table and its corrections are what
the code is built against.

A session whose `loom.toml` carries an `[lsp.<name>]` table gets:

- seven tools, `lsp_definition`, `lsp_references`, `lsp_hover`, `lsp_symbols`,
  `lsp_calls`, `lsp_diagnostics` and `lsp_rename`. They address symbols by
  name (optionally qualified, `util.Greet`, and narrowed by a path and a
  1-based line), never by position, and answer with anchored sites a model can
  feed straight into `fs_edit`.
- settled diagnostics appended to `fs_write` and `fs_edit` results for files
  the running server owns.
- `cap/lsp` in code mode, admitted only when a server is configured, so a
  session without one pays nothing in its cached prefix.
- a rename that previews by default and applies through the hashline landing
  path, refusing the whole rename when any file on disk no longer matches what
  the server saw.

The server runs as an ordinary jailed exec under the session's own enforcement
demand, after a probe proves that demand is met, one per session, with a lazy
restart. Nothing is discovered or installed; an unconfigured workspace starts
nothing.

Validated on a cgroup-v1 container, so under `BestEffort`: the scripted-model
acceptance in `conformance/lsp_e2e_test.gleam` against a jailed `gleam lsp`
(rename across three files, concurrent-write rejection, an `fs_edit` using a
references anchor) and a `gopls` variant. Not validated there: the enforced
path under `PlatformEnforcement` (the probe refuses on that host, correctly),
and macOS. The Linux signoff on a host with a delegated cgroup v2 base is where
those run.

Rulings the next change must preserve:

- **Positions never leave `packages/lsp`.** The model and every surface speak
  `lsp/query.Site`; `lsp/text` is the only converter, against the exact text a
  position was computed on. A site's text is the line as hashline sees it (a
  CRLF line keeps its `\r`), so its anchor is the one `fs_read` prints.
- **Gate every request on advertised capabilities.** `gleam lsp` never answers
  a request it did not advertise.
- **Edits land only through hashline.** The server never writes;
  `workspace/applyEdit` is declined and resource operations are refused.
- **The harness never reads a path a server merely names.** The jail bounds
  what a server reads, not what it names. `client/lsp/resolve.admit` admits a
  server-named path only under the server's root and outside every protected
  entry; anything else is shown with no text and never opened.
- **Enforcement is proven before a server starts,** because the helper reports
  enforcement only when an execution exits.

A weft ordering race the LSP end-to-end exposed, not fixed here. `make check`
failed the LSP rename end-to-end once, on a machine loaded by two parallel cold
builds. The cause is in weft. A custodian adopts a published transport owner
as Transitive and monitors it, but the begin permit reaches the owner through
another process chain and can overtake the monitor signal, because BEAM orders
signals only per sender and receiver pair. An owner that exits normally in that
window is judged `noproc`, weft reads that as `weft_drain_proof_lost`, and the
session fails closed. A thirty-line plain-Erlang module reproduces the ordering
(a few dozen `noproc`s per 1.6M runs under load), and a round trip or
`process_info(Owner, current_function)` after the monitor removes it. The
proposed fix is that barrier in weft's `adopt_published` and the `OwnedTask`
arm of `fill_slots`, recording `ProofAbsent` when the owner is really gone. It
was observed on weft 0.4.4; this tree pins 0.4.5 and that release has not been
checked for the barrier. The scripted provider's owner exits about 100 µs after
begin, which is why this test finds the window first; real httpc owners are
exposed too, only rarely.

Remaining language-server work:

1. Land the weft barrier above, if 0.4.5 does not carry it, and bump the pin.
2. The daemon custody retirement path stops the manager with the service tree,
   racing the broker stop that follows. A graceful ordered stop needs a custody
   part in `internal/instance_owner`.
3. The helper writes stdin while holding the mutex `Cancel` needs (ADR-013 §1,
   known hazard), so a wedged server blocks cancel until the broker's
   three-second helper kill. Worth fixing in the helper.
4. Count extension hosts against the per-session lease cap.
5. A second server per session. A Go and a Gleam project side by side evict
   each other today.
6. Follow-ups from the design discussion that are the owner's call: move #26
   (DAP) out of release-blocker in favour of a satellite-local trace
   capability; bounded read-only BEAM introspection for the agent (#454);
   structured session-trace queries beside `history_search` (#236); write the
   upstreaming stance down.

The root `CLAUDE.md` paragraph on `gleam lsp` is about the editor tooling a
developer drives this repo with, which is separate from everything above:
Claude Code still has no Gleam server configured. A project-local plugin with
an `.lsp.json` (`gleam lsp`, `.gleam`) would give local CLI sessions
go-to-definition and post-edit diagnostics; cloud sessions do not start
language servers.

## Next actions, in order

Terminal CPU work merged in #664 at `a54effa07` and is locally verified
against installed `3088ee3ce`: counting strip rows during layout and painting
known-width
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
Protocol-change/058 adds an explicitly approved session lifetime for Bash and
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
