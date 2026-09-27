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
the new text changes rather than the length of the answer.

**The web view.** `loom --ui --session <id> [--operate] [--open]` asks the
daemon for a single-use ticket with `ui.link` and prints the link. The
browser exchanges the ticket for an `HttpOnly`, `SameSite=Strict` cookie
scoped to a page key, keeps a per-tab nonce in `sessionStorage`, and opens
the page's socket with it. `ui_socket` starts `web_view/component` for an
observer or `web_view/operator_page` for an operator, chosen by the smallest
of the membership role, the link's ceiling and Operator, and `ui_relay`
attaches it to the session's gateway. The component files arrivals and
reduces on a 250 ms tick, except that a reply the lane is waiting for is
reduced on arrival, which took a first capture from 2.77 s to about 4 ms.
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

## What to work on next: event-driven delivery

Both hosts still poll. The component reduces on a 250 ms tick, and the
lane's idle refresh issues a `catch_up` every 250 ms whether or not the
daemon has anything new. The decided next step replaces both:

- **Reduce on arrival, coalesced.** An arrival schedules one reduction
  rather than waiting for the tick, and every arrival that lands before
  that reduction runs is taken in the same batch. Batches stay intact:
  reduction still drains what is held in arrival order, never one message
  per reduce.
- **A deadline timer instead of the refresh poll.** A new
  `session_channel.next_due` answers when the lane next needs to act (a
  request deadline, a due catch-up), and the host arms one timer for that
  instant instead of ticking.
- **Refresh backs off while the daemon pushes.** While pushes arrive, the
  idle refresh drops to a slower recovery rate, since the pushes already
  carry the news; a gap in the pushed notice sequence triggers a
  `catch_up` at once.

This revises ADR-013's option C, which says arrivals are filed and reduced
only at fixed points, so it lands with an ADR-013 addendum that says what
replaces the rule and why ADR-010's ordering (Escape acts before traffic is
reduced) still holds. A new `docs/architecture/delivery.md` follows it.

Exit criteria: no performance regression, measured with
`scripts/tui_perf.sh` against the backlog cases in ADR-013's mailbox-scan
addendum and with the web view's first-capture timing; batches still
intact, pinned by a test that sends a burst and sees it reduced together;
the replay goldens byte-identical; and `make check` green by its own exit
code.

## Rulings to preserve

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
