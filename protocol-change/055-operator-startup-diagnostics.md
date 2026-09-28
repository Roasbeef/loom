# protocol-change/055: bounded operator startup diagnostics

**Status**: Implementation authorized for the operator diagnostics batch
(#363, #377, #286), pending root review. **Affects**: daemon control v2
(protocol 015) and credited session metadata (protocol 018).

## Problem

A rejected catalogue keeps its parser reason until domain assembly, then
loses it before the operator polls the admitted operation. An installed
extension keeps its refusal until registration, then logs it without
including it in the attachment's snapshot. Both leave the operator with a
missing capability and no actionable diagnosis.

## Decision

We carry these diagnoses through existing bounded surfaces. We add no
command, push event, dependency, or execution authority.

For an authorized `operations.get` of the exact failed opening operation,
`error.body.code` remains `start_failed` and `error.body.message` carries
one line of at most 2048 UTF-8 bytes. The existing epoch, credential and
session membership checks precede the read. Other control refusals retain
`request refused`. The terminal accepts at most 2048 bytes in an error
message and renders the startup reason. The manager stores one operation
and reason per session, in the existing map capped at runtime capacity,
and clears that memo on the next admission. Failed domain construction
records the reason for its waiting sessions before cleanup retires them.
The exact failure memo takes precedence over live operation status, including
`Stopping` while custody is still closing. That diagnostic read releases no
reservation and permits no replacement. A newly admitted operation clears
the old memo before its builder can publish a result.
The memo changes neither lifecycle custody nor replacement permission.

The message may contain the configuration file path and the parser's
expected/received token or catalogue key. This is an explicit exception to
015's path-free generic refusal: it is available to an authenticated member
of that session, never in hello or an unauthenticated refusal. The daemon
log retains `configuration_rejected` for filtering and adds the same
bounded reason. The current TOML parser exposes no line number; the host
preserves its available context rather than inventing one.

Credited snapshot metadata's `tool_availability` object gains an optional
`extension_refusals` array. Each string is at most 2048 UTF-8 bytes and the
array has at most 32 items. An omitted array means no reported refusals,
so a new client can read an old daemon. A present malformed or oversized
array refuses the capture as a whole. Existing clients ignore the additive
field. Assembly reports the installed name, bounded reason, and guidance
for the existing `loom ext remove <name>` then `loom ext install <source>`
workflow. More than 32 assembly refusals retain the first 31 in discovery
order and a final notice directing the operator to `loom ext list`. The
immutable gateway capture reaches every authenticated attachment and
reconnect; the terminal includes it in its ordinary startup lines.

Hook diagnostics need no protocol change. A broker `CallFailed` remains
exit 1 with empty stdout. Its bounded stderr carries the helper refusal
code/reason, or the degraded execution's enforcement entries. Timed-out
or cancelled degraded executions remain `WallCancelled` with both streams
empty, so a partial permission decision cannot escape output discard.
The enforcement demand and install replacement policy stay unchanged.
This is preservation at the `hookrunner.Outcome` boundary. Existing shipped
compatibility consumers can discard exit-1 stderr, including session context
injection; this change establishes no new transcript or debug-log delivery.
The #377 criterion covered here is the bounded refusal reason in the outcome,
with unchanged decision semantics and timeout output discard.

## Alternatives and costs

A new notice event would need another delivery and recovery path. A
class-only response would leave the operator reading the daemon log.
Keeping failed owners alive would confuse diagnosis with cleanup custody.
We retain bounded immutable text instead. Each manager memo costs at most
2048 bytes of text; each gateway's notice list costs at most 65536 bytes.
The existing credited metadata transfer pays for delivery without enlarging
individual frames. Diagnostics beyond those bounds are explicitly shortened.

## Verification

The client tests exercise malformed TOML and missing-model catalogue errors
through production domain assembly, the real authenticated control socket,
the terminal decoder and its startup rendering. The manager regression
checks retirement, exact operation identity and a multibyte reason bound.
A deterministic storage-custody barrier keeps a failed opening live in
`Stopping`: its exact operation already returns the reason, a different
operation is stale, and capacity and replacement remain fenced. The next
builder is parked before publication to prove admission clears the old memo.
A real assembled session with a format-1 extension record sends the refusal
through its credited socket snapshot into the shared decoder and terminal
startup projection while omitting the refused tool from its registry.
Deterministic helper-protocol fixtures exercise the real broker and hook
runner with `PlatformEnforcement`, an unexpected skipped layer, a helper
refusal and timed-out degraded output. Terminal tests cover both diagnostic
byte bounds, missing additive metadata, and total refusal of malformed lists.
Gate and mutation results belong in the batch handoff and progress report.
