# protocol-change/012 — `hook_call` and `hook_result`: the harness calls into a satellite

**Status**: PROPOSED 2026-09-02 · **Affects**: Part 1.4 frame kinds ·
**Raised by**: ADR-007, `docs/design-notes/extension-architecture.md`
Decision 3 · **Implements**: extension phase 3 (persistent satellite,
tier-J hooks)

## Problem

Every frame on the capability channel today is asked by the satellite
and answered by the harness: `cap_call` up, `cap_result` down, with
`cancel` and `heartbeat` beside them and code mode's own `outcome` frame
ending the execution. The protocol has no way for the harness to ask the
satellite anything. That was the right shape for a code-mode program,
which is one execution with no caller but itself, and it is the reason
#98 recorded that a hook surface could not be shimmed.

An extension is different in two ways the current frames cannot carry.

- **A hook fires on the harness's timeline.** `tool_call` happens when
  the planner has a call and has not dispatched it; `context` happens
  before a provider request. The harness holds the event and the
  deadline, and the satellite has to be *told*, not left to poll.
- **A satellite that lives for the session cannot pull its work.**
  Phase 1's `ext.call` is a pull: the node boots, asks once, answers
  once, exits. A persistent satellite, which is what stops every tool
  call paying a node boot and what lets an extension keep actors
  between calls, has nothing to pull against after its first answer and
  no token for its second.

Both are the same missing thing: a frame the harness sends that the
satellite answers.

## Proposal

Two kinds, mirroring the existing pair:

```
hook_call.body   := { token: bin, kind: "tool" | "event", name: str,
                      args: msgpack, deadline_ms: u64 }
hook_result.body := { ok: true, value: msgpack }
                  | { ok: false, code: str, message: str }
```

- `hook_call` flows harness → satellite; `hook_result` flows satellite →
  harness with the **same frame `id`**, which is the correlation.
- **At most one `hook_call` is outstanding per satellite.** The harness
  serialises; a second `hook_call` before the first `hook_result` is a
  protocol error on the harness side, never a case the satellite handles.
  Hooks and tool calls are already serialised per strand, so this costs
  nothing and keeps the satellite runtime a loop rather than a scheduler.
- **`token` is the token for this invocation.** Tokens are minted for one
  `{op_id, step_id}` and checked on every `cap_call`; a satellite that
  outlives an execution has no valid token of its own. The `hook_call`
  hands it one, the satellite uses it for every `cap_call` it makes
  while answering, and a `cap_call` made outside any open invocation
  presents a stale token and is refused as unauthorized. That is the
  property the persistent satellite has to preserve from the
  fresh-node-per-execution design: **an extension can act only while
  the harness is asking it something.** Background actors an extension
  keeps between calls may compute; they may not reach a capability.
- `deadline_ms` has the semantics of `cap_call.deadline_ms`. When it
  passes with no `hook_result`, the harness stops waiting, answers the
  event in band as if the extension had failed with
  `code: "deadline"`, and **destroys the satellite**. A satellite that
  ignores its deadline is not one the harness can keep trusting with a
  session's worth of state, and a restart is a `session_start` away.
  The extension's handler on the hook bus returns `Failed` and the
  extension is out for the rest of the session, logged with the reason.
- `kind: "tool"` carries a model-made call: `name` is the tool,
  `args` is `{args: <json>, strand: str}`, and `value` is
  `{content: [...], terminate: bool}`, the same value phase 1's
  `outcome` frame carries for a tool. `kind: "event"` carries a hook
  event: `name` is one of the seven in the design note's table, `args`
  and `value` are that row's payload and return. The exact per-event
  shapes are fixed by the phase 3 implementation in `ext/runtime` and
  `codemode/satellite`, in one place each, with a conformance test that
  round-trips every one.
- `cancel` and `heartbeat` are unchanged. `cap_call` and `cap_result`
  are unchanged. Code mode's `outcome` frame is unchanged and remains
  the end of a code-mode execution; a persistent extension satellite
  never sends it, because it has no execution to end.

## Impact

- **Part 1.4 frame kinds** gain `hook_call` and `hook_result`. The list
  is frozen; this proposal is how it moves.
- **`broker/framing`**: `Body` gains `HookCall(token, kind, name, args,
  deadline_ms)` and `HookResult(outcome)`, with `decode_body` arms and
  `check_keys` lists; both fields required, no defaults, for the reason
  006 gave.
- **`codemode/satellite`**: a send path for `hook_call`, a one-slot
  pending table keyed by frame `id`, and the deadline-then-destroy
  behaviour above. `handle_frame` gains a `HookResult` arm; a
  `HookResult` with no pending call is a protocol fault.
- **`cap/runtime`** and **`ext/runtime`**: after boot, a receive loop
  over `hook_call` frames replacing phase 1's single `ext.call` pull.
  The token from each `hook_call` is installed for the duration of the
  answer. The boot runtime's refusal to install a channel over a live
  predecessor stays; it is the guard `code-mode.md` already names for
  this mode.
- **The Go helper is untouched.** These frames cross only the AF_UNIX
  capability socket between harness and satellite; `loom-exec` never
  sees them, so no `bin/loom-exec` rebuild.
- **No durable format changes.** Nothing here is stored.

## Alternatives considered

- **Keep pulling.** The satellite could loop on `ext.call`, and the
  harness could park each pull until an event arrives. That inverts the
  deadline (the harness cannot start a hook's clock until the satellite
  happens to ask), needs a parked-call table on the harness that
  `hook_call`'s one slot replaces, and still leaves the token question
  unanswered. Dismissed.
- **A second socket.** A separate harness → satellite channel would keep
  `framing` untouched but would double the token and lifecycle
  machinery for no isolation gain: both ends are the same two
  processes. Dismissed.
- **Tokens that outlive an invocation.** A session-scoped token for the
  persistent satellite would let background actors reach capabilities
  between calls. That is exactly the authority the fresh-node design
  never granted, and it is refused on purpose; see the token bullet.

## Decision

Pending. Phase 3 starts when this is accepted; phases 1 and 2 do not
depend on it.
