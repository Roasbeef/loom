# Current handoff

This handoff is pinned to `868dfedd8754e1b8a750add24227bd2b83fcd167`
plus the documentation cleanup commits on `docs/tracker-cleanup`. Live
tracker state was checked on 2026-09-27. Main subsequently merged #576 and
#577 through #578 at `e386fc5d`; those shared-step design and web-layout
changes are outside this branch's baseline.

The previous edition was pinned to `b4eeb50c` and carried stale in-flight
statuses. #558–#560, claim-flow step 1 (#562), web UI phase A (#563),
event-driven delivery (#567), roster-on-subscribe (#574), and the etui
pin (#570) are merged. Their old signoffs are not new validation of this
branch.

## Where the tree is

`packages/session_view` owns the portable session lane, decoders, snapshot
adoption and transcript projection. Its manifest depends on `core`,
`machine` and the standard library. `packages/tui` owns the terminal step
and its effects, and `packages/web_view` owns the Lustre component and
operator page. ADR-013, ADR-014 and protocol-change/051 record the split;
[the client architecture](architecture/client.md#the-client-engine-and-its-hosts)
is the map.

The terminal runtime stamps and admits inputs, the step returns effects,
and the runtime settles those effects. Socket arrivals wake the terminal.
`terminal_poll_timeout` follows the lane deadline, with a one-second idle
ceiling because resize still needs a poll. Both client and terminal pin
etui at `58d0cbd775aad61b2a42830eb818a83e1a0ad1d8`. The lane's pushing
refresh is 5000 ms, and the gateway publishes presence on subscription.
[Delivery](architecture/delivery.md) explains the ordering and ownership.

The web component takes bursts of at most 64 frames and schedules the
lane's next deadline. Its strand is `main`. Claim invitations no longer
carry a bearer: protocol-change/053 step 1 is merged. The remaining owner
admin steps still need an implementation decision; do not infer approval
from the claim-flow merge.

## Tracker cleanup wave

The survey covered 90 issues. #1, #139, #372, #426 and #481 were closed
with evidence. #19 was consolidated into #181, preserving the dedicated
credential-store work; [#579](https://github.com/Roasbeef/loom/pull/579)
updates its plan and spec-gap references. None of these closures claims
that keychain-backed storage has shipped.

This branch addresses #394, #94 and #76:

- Waking schedule confirmation names `[schedules] model_created = "wake"`.
  The example explains `off`/`steer`/`wake`, recurring expiry, late one-shot
  delivery, and the provider spending boundary. Subagent schedules steer.
- The production Anthropic serializer advertises 22 built-ins. The full
  both-mode tool array is 68,311 Unicode characters / 68,419 UTF-8 bytes.
  The 17.1K–22.8K token range is a character estimate, not a provider token
  count. `scripts/measure_tool_surface.escript` and its Python summarizer
  reproduce the census; the [design note](design-notes/tool-search-and-code-mode.md)
  revises the recommendation against it.
- The style audit corrects eager-argument and effectful-escape guidance,
  and the stale claims about `api.compact`, `api.navigate`, idle strand
  creation and conformance assertion checking. Lint severity is unchanged.

Two independent implementation branches are still in progress: operator
diagnostics (#363, #377, #286), and terminal state (#399, #524). Their
proposals 055 and 056 and their unmerged behavior are not part of this
branch. Each needs its own adversarial review and exact-head validation.

The survey added `work:*`, `batch:*`, `status:partial`, `needs:upstream`,
and missing `area:*` labels while preserving existing phase and priority
labels. The batch labels identify related work; they do not assert that
all acceptance criteria have passed.

## Next actions, in order

1. Review and land the independent cleanup PRs only after their exact-head
   gates and required Linux signoff pass. Merge is not authorized by this
   survey task. Resolve shared documentation conflicts against the final
   merged code rather than retaining both branches' line citations.
2. Measure actual provider token counts and representative workloads before
   choosing tool search. Exit: measured prompt size, cache-prefix behavior
   and discovery cost, rather than another character estimate.
3. Wake etui on SIGWINCH before raising the terminal's one-second idle
   ceiling. Exit: resize repaints without waiting for a poll, and a quiet
   terminal wakes only for work its lane or runtime owes.
4. Continue the shared-step and owner-admin plans from their current merged
   proposals. Exit criteria belong in their issues and protocol changes;
   the tracker sweep does not expand their authorized scope.

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

## Deliberately open and carried forward

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

## Earlier collaboration follow-ups

The collaboration stack landed through #510 at `645b8faf`; protocols 048
and 049 own its wire. [Async collaboration](architecture/async-collaboration.md)
and [messaging](architecture/messaging.md) explain it. Saved-session
outboxes, cross-machine transport, durable actor recovery, and the
outgoing-link limit race remain carried-forward follow-ups. The coordinator
example for following up with already launched children also remains open.
Protocol 054 still needs its previously requested live quiet-web drive to
confirm attachment reaches `Pushing` and rendering follows the pushed rate.
This docs
batch did not re-test their reachability or close them.

## Validation boundary

The cleanup passed format, doc, prelude and lint checks, the 17 schedule
tests, TOML policy parsing, mirror equality, and a byte-identical replay of
all three measured tool-array profiles. Removing the operator-setting
text fails the new regression; restoring it passes. Doc and lint checks
retain existing warnings. An independent Astra pass found two inaccurate
prose claims; both were corrected and rechecked with no remaining findings.

Full `make check`, hosted CI and Linux signoff remain separate gates for
this branch. [Provider PR #579](https://github.com/Roasbeef/loom/pull/579)'s hosted Linux gate passed, but its separate
remote signoff stopped in dependency preparation after three Hex rate-limit
retries. No passing signoff is inferred from hosted CI. The carried-forward
rulings above were retained as design constraints; this wave does not
re-certify their historical end-to-end tests.
