# Current handoff

Issue #530 is done through phase 4 on `main` at `b4eeb50c`. The client is
now a pure engine and two hosts. The engine is `packages/session_view`: the
session lane, the protocol decoders, snapshot adoption, the history window,
the transcript projection and the operator's command arms, held by lint R6
to depend on nothing BEAM-only. The terminal (`packages/tui`) wraps it in a
step that reads no clock, file, mailbox, process or environment variable
and returns its effects as values. The web view (`packages/web_view`) wraps
it in a Lustre server component that `loomd --ui` serves to a browser, and
an operator's page can prompt, steer and answer approvals.

| PR | Result |
|---|---|
| [#549](https://github.com/Roasbeef/loom/pull/549) | Phase 2 (#544 to #548): mailbox reads, recording, jobs, the attachment attempt and file reads leave the step. |
| [#550](https://github.com/Roasbeef/loom/pull/550) | Phase 3: the client's own `msg.Msg` in front of the step, and admission that files arrivals without reducing them. |
| [#551](https://github.com/Roasbeef/loom/pull/551) | One mailbox scan for the jobs and the replay inbox per event. |
| [#552](https://github.com/Roasbeef/loom/pull/552) | Phase 4: `session_view` extracted, and a read-only web view behind `loomd --ui`, linked by `loom --ui`. |
| [#553](https://github.com/Roasbeef/loom/pull/553) | `docs/lustre.md`, the guide to Lustre 5.7.1 server components for this code. |
| [#554](https://github.com/Roasbeef/loom/pull/554) | Milestone 1: the operator's page (composer, allow once and deny), page keys, nonces and role ceilings. |
| [#555](https://github.com/Roasbeef/loom/pull/555) | `loom --ui --open`, and protocol-change/052 proposed (design only). |
| [#556](https://github.com/Roasbeef/loom/pull/556) | The streaming live tail: the terminal redraws a growing answer from what changed. |
| [#557](https://github.com/Roasbeef/loom/pull/557) | The hand-run queue that landed #553 to #556 together. |
| [#559](https://github.com/Roasbeef/loom/pull/559) | Architecture docs for the web view and the engine layering, the web UI design note, and package READMEs. Pending. |

[ADR-013](adr/013-tui-effects-as-values.md) records each terminal phase in
an addendum. [ADR-014](adr/014-second-runtime.md) and
[protocol-change/051](../protocol-change/051-web-view-route.md) with its
addenda record the web view. [The web view](architecture/web-view.md) is
the map of the request path, the processes and the security layers, and
[the client engine and its hosts](architecture/client.md#the-client-engine-and-its-hosts)
draws the layering.

## Where the tree is

**The terminal.** `tui.update` is
`runtime.settle(step(runtime.message(event, model), runtime.receive(model)))`.
`runtime.message` stamps the clocks and reads a pasted file into the input;
`runtime.receive` reads job replies and each inbox's mailbox up to its room
and has `tui/admission` file them; the step reduces an input at a tick or a
key, in `tick.update_tick`'s fixed drain order; and `runtime.settle`
performs the effects and stores the job table. Jobs are keyed data
(`tui/job`, `tui/job_runner`), and replies are admitted only by the key
their slot holds. The live answer is drawn by `tui/live_tail`, whose cache
lives in the terminal's view state (`View.live_tail`), so a frame costs what
the new text changes rather than the length of the answer. The session
socket wakes etui's loop after each frame it files, paced to one wake per
16 ms, and the poll timeout sleeps until the lane's
`session_channel.next_due` when nothing else is owed
([delivery.md](architecture/delivery.md)).

**The web view.** `loom --ui --session <id> [--operate] [--open]` asks the
daemon for a single-use ticket with `ui.link` and prints the link. The
browser exchanges the ticket for an `HttpOnly`, `SameSite=Strict` cookie
scoped to a page key, keeps a per-tab nonce in `sessionStorage`, and opens
the page's socket with it. `ui_socket` starts `web_view/component` for an
observer or `web_view/operator_page` for an operator, chosen by the smallest
of the membership role, the link's ceiling and Operator, and `ui_relay`
attaches it to the session's gateway. The component's selector drains a
burst of up to 64 frames into one `Arrived`, which is reduced at once, and
one timer armed for the lane's `next_due` replaces the old 250 ms tick, so
a burst costs one render per batch and an idle page wakes at the lane's
refresh.
The page shows `main` only, and only durable records: no streams, tool
tails or live tail yet.

## In flight

- **Web UI phase A**, on `web_view/agents-and-cache`: the agent strip,
  cache rings and cache-miss rows, folded work, sub-agent spawn and result
  rows, advisor nudges, and peer message cards, all drawn from the cut and
  the pushes without the extracted step. The direction is
  [the web UI design note](design-notes/web-ui.md), sections 3.8 and 3.9
  and screen (d).
- **protocol-change/053**, claim tokens and owner admin
  ([#558](https://github.com/Roasbeef/loom/pull/558)), accepted by the owner
  on 2026-09-27. Step 1, the claim flow (`loom claim`, `loom enroll` and
  the `/v2/claim` route, so no invitation carries a bearer), is on
  `access/claim-flow`. Steps 2 to 4 (`loom access` and the listings, the
  terminal overlay, the admin page) wait for the owner's go-ahead.
- **The package README audit**, [#560](https://github.com/Roasbeef/loom/pull/560).

## Event-driven delivery: landed on `client/event-driven-delivery`

Both hosts now reduce traffic when it arrives and wake for time only at
the lane's next deadline. [ADR-013](adr/013-tui-effects-as-values.md)'s
addendum on event-driven delivery records the decision, what it costs and
the measurements, and [delivery.md](architecture/delivery.md) traces a
frame from the socket to the screen in both hosts. The decided plan above
was built as written except in two places. No gap detection was added:
a notice at or above the cut already catches up from `cut.next_seq`, so
only a lost final notice waits for the refresh. And the terminal's idle
wait is capped at one second rather than at the lane's refresh, because
etui notices a resized window only when its loop runs. The `Pushing`
refresh is 5 s, as planned, now that a join is pushed
([protocol-change/054](../protocol-change/054-roster-push-on-subscribe.md),
accepted 2026-09-27 and implemented on `gateway/roster-push-on-subscribe`).

Follow-ups, in order:

1. **Merge the etui `wake-clause` branch** (two commits: the wake clause
   and the 40 ms bound on a lone escape byte), then move the pin in
   `packages/tui` and `packages/client` to the fork's `main`. Exit: the
   pin names a commit on `main` and the manifests agree.
2. **Protocol-change/054 is implemented** (accepted by the owner 2026-09-27;
   branch `gateway/roster-push-on-subscribe`). The hub pushes the
   `presence` roster to every subscribed peer, the newcomer included,
   when a network peer subscribes, and `pushing_refresh_ms` is back to
   5000. In `tui_shipped_multiplayer_test` Alice sees Bob's rejoin within
   34 to 118 ms of his terminal starting (it was 4,979 ms at 5 s without
   the push), and an idle terminal on a quiet session issues 0.20
   catch-ups a second. The client tests that read the frames after a
   subscribe now consume the join explicitly: `gateway_test`'s
   `network_socket`, `daemon_server_test.subscribe` for real sockets, and
   `ui_relay_test`'s `subscribed`; `session_authorization_test` counts
   three checks per subscribe. Still open from 054's verification list:
   a live drive of a web page on a quiet session, to confirm it reaches
   `Pushing` at attach and renders at the pushed rate.
3. **Wake etui's loop on SIGWINCH.** With a resize announced, the
   terminal's one-second idle ceiling can rise to the lane's refresh.
   Exit: an idle terminal wakes only for its lane, and a resize repaints
   without waiting for a poll.

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
a review finding.

**Effects are values and name their handles.** A step or a lane returns
what it decided; the host performs it, in decision order, against the
handle each effect names, never a handle looked up at perform time. The
web host performs the lane's outputs inside one `effect.from`, because
Lustre's `effect.batch` does not order them.

**The buffer bound is the host's.** Admission never drops a frame for
capacity, a host reads no more from a mailbox than a buffer has room for,
and admission files a frame only into the inbox whose subject it names, so
nothing from a replaced inbox reaches a reducer after an adoption.
Event-driven delivery changes when a host reduces, not these.

**A page is never more than an operator.** The role is the smallest of the
membership, the ceiling the link was minted with, and Operator. A page
never offers allow for the session, its approval cards sit below the
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

## Open, deliberately

- **Remote access to the page**, protocol-change/052: a TLS proxy at a
  listed origin with a `__Host-` cookie. Proposed, design only; today a
  remote person uses `ssh -L`.
- **The 053 admin page.** A later phase of 053, if built at all: loopback
  only, revoke-only, rendering each grant as a `loom access` line.
- **Web UI phase B**, interactivity beyond the composer and approvals:
  strand focus, history paging, fork, abort, image prompts and the
  auxiliary reads. It needs strand focus, and with it the extracted step:
  of ADR-014's four blockers the inbox split is done, and engine-owned key
  and pointer types, the split of the model into engine and view state,
  and host handles as type parameters remain.
- **`conformance` declares `prompt` as a dependency and imports nothing
  from it.** Remove it, with the manifest updates that follow.
- `msg.Event` still carries etui's `keys.Key` and `backend.MouseButton`,
  and the test fixture `pushed.attached()` is a replaying peer with a lane,
  a state the shipped client never reaches.

## Earlier on main

The collaboration stack landed in
[#510](https://github.com/Roasbeef/loom/pull/510) at `645b8faf`: async
execution, resident peer messaging, the named workflow core, virtual reads
at `cap://` and `job://`, owner inspection and linking from the CLI, the
terminal's link manager (`/sessions` then `l`, `/peers`, `/agents` then
`p`), and executable collaboration examples. Protocols 048 and 049 own the
wire; [async collaboration](architecture/async-collaboration.md) and
[messaging](architecture/messaging.md) explain it. Still open from it:
measuring how virtual-read discovery affects prompt size and cached-prefix
reuse; an example of a coordinator sending follow-up tasks to children it
already launched; saved-session outboxes, cross-machine transport and
durable actor recovery; and the link-admission race at the outgoing-link
limit, which can leave a stale incoming grant.

A running shell that hits a kernel permission error settles in band, and
a failed `bash` call tells the agent to retry with `permissions` naming the
needed roots, which then go through canonicalization, protected-path
checks and the operator dialog.

## Validation boundary

This handoff was written against `main` at `b4eeb50c`, the merge of the
#557 queue. It re-states what the merged PRs and their ADR addenda record
and does not re-run their signoffs; check the queue's signoff and the
hosted checks before relying on a claim here. #559 is documentation only
and changes no Gleam source; `make doc-check` exits 0 on it.
