# protocol-change/117: the broker tunnel, so non-tool callers reach an untrusted executor

**Status**: PROPOSED 2026-11-16. Not built. It needs the review that
`docs/execution.md` section 7 asks of a security-sensitive change before it is
accepted.
**Affects**: the untrusted executor wire of [109](109-untrusted-executors.md)
(`untrusted_wire.version` 4 to 5): one new request and its reply, one new
request with no reply, a second meaning for the existing `cancel` frame, and one
new frame from the executor. One new process per untrusted executor on the
orchestrator (the link's tunnel door). In `client`, the four non-tool callers
of an executor's broker take a clearing function in place of a `broker.Broker`,
and imported hooks that run on an untrusted executor are read under two
narrower rules. `core/json` gains a parse that bounds the number of values. The
remote node vocabulary of [078](078-distributed-runtime.md) and its
`protocol.version` (7), `loom.toml`, the client control protocol and every
Part 1 interface are unchanged, and so is a trusted executor's wire.
**Raised by**: the microVM tier. The owner ruled on 2026-11-13 that `loom vm up`
reaches guests over the untrusted link by default once this lands
(`docs/design-notes/microvm-untrusted-link.md`, section 5 and slice 3).
**Builds on**: 109 (the link, the gateway, bindings), 110 (the precedent for a
request that names a binding), 116 (the link's owner and restarts).
**Issue**: loom #85.

## Problem

Four things a session does through its executor's broker are refused when the
executor is untrusted, because they call `broker.clear_call`, `broker.stdin` and
`broker.cancel` on `WorkspacePlane.broker` (`client/workspace_plane.gleam:367`),
and the link puts a broker subject whose owner has exited in that place
(`refusing_broker` (`client/remote/untrusted_link.gleam:556`)):

1. Project hooks: `hookrunner.run` clears each command
   (`clear_call` (`client/hookrunner.gleam:250`)), wired by
   `with_imported_hooks` (`client/serve.gleam:273`).
2. Goal checks, through `tool.broker_runner` in
   `goal_check_wiring` (`client/serve.gleam:6935`).
3. The Changes tab (`observe_worktree` (`client/serve.gleam:4752`)) and the peer
   view of the worktree (`peer_observation` (`client/worktree_diff.gleam:1195`)),
   both through `run_git` (`client/worktree_diff.gleam:738`).
4. The session's Git baseline. `session_git.prepare` probes it once, for a new
   session, and stores the answer (`prepare` (`client/session_git.gleam:33`)).
   Through the refusing broker the stored answer is `Unavailable`.

Each is a regression against a trusted executor, and the untrusted link cannot
become the default for guests while they are refused.

## What was considered

### The link stands in for the broker actor (rejected)

The owner port already gives every remote session's non-tool callers a stable
subject and forwards each `broker.Msg` to the subject the latest attach named
(`owner_port.retarget` (`client/remote/owner_port.gleam:275`)). The link could
name a subject of its own there and serve the broker's messages itself, with no
change to any caller. `broker.Msg` is opaque (`Msg` (`broker/broker.gleam:259`))
and `CallHandle` can be made only inside the broker package, so this needs the
broker to export a reading of its own actor protocol, including the
congestion epochs `clear_call` retries with, `QueryRelay` and the abort sweeps.
That couples the link to the broker's internals for four callers that use three
functions.

### Re-send tunnelled calls as runs are re-sent (rejected)

A `run` is re-sent after a dropped connection because the executor's host
admits it by key and joins the call already running. A broker call has no key.
A hook or a goal check sent again would run again, and a hook that runs twice is
wrong. A tunnelled call is therefore sent on one connection at most, and a
dropped connection ends it on both sides.

### Negotiate the tunnel in `welcome` (rejected)

The executor could announce the tunnel as a flag, so an old executor serves
tools and refuses only the four callers. 109 refuses any version mismatch at the
handshake, 110 and 111 kept that rule, and a guest image is built from the same
release as the host. A flag is a second compatibility mechanism for a case the
release process already removes.

### Reach the link through a weft registry address (rejected for now)

A `weft/registry` address would give the link a second typed subject without an
atom. The address is a reference, so it has to travel from the registry of 116
to `workspace.untrusted_candidate` with the row, which means a new field on
`executors.Executor`. A second registered name follows the pattern the link
already uses (`name_for` (`client/remote/untrusted_link.gleam:417`)) and needs no
plumbing.

### Corrections to the design note

Section 5 of the design note is the starting point. Against the code:

- A remote session's non-tool callers do not hold `broker.over(census.broker, ..)`.
  They hold `broker.over(owner_port.broker(port), executor_clock)`
  (`build` (`client/remote/workspace.gleam:669`), line 697), a relay the owner
  port retargets at every attach. The relay is why a trusted executor that
  restarts keeps working, and it is unchanged here.
- The executor side does not see the plane's broker subject when it encodes an
  attach reply. `untrusted_bridge.ask_host` projects the census onto the wire
  inside the waiter (`projected` (`client/remote/untrusted_bridge.gleam:1304`)),
  and the gateway's `answer` (`client/remote/untrusted_gateway.gleam:643`) gets
  a `Response` with the subject already dropped. The bridge has to hand the
  subject out beside the response.
- The seam cannot be the two-argument `tool.broker_runner` shape. That shape
  fixes the clearance wait when it is built, and `hookrunner.run` and `run_git`
  choose a different wait for every call. The seam takes the wait as an
  argument. The peer view uses `worktree_diff.Wiring`, so two types change, not
  three.
- A hook's `allow` already skips nothing. `ToolPermission`
  (`client/hookdecisions.gleam:95`) maps `allow` to `Proceed`, and
  `hookserve.cleared` (`client/hookserve.gleam:1050`) asks hooks only after the
  harness has cleared the call. The exposure a guest's hooks add is elsewhere: a
  `Rewrite` puts guest-chosen arguments through the clearance again, and the
  payloads carry the inputs and results of tool calls that never ran on the
  executor ("Hooks on an untrusted executor").
- A session opened over the link before the tunnel keeps a Changes tab after the
  tunnel lands. Its working-tree half is observed afresh on every request; only
  the commits since the session started stay unavailable, because
  `capture_committed` (`client/worktree_diff.gleam:412`) shows the stored reason
  in their place.
- The note names no way for the clearing function to reach the link, which can
  be replaced at any time by `executors.reload`. "Reaching the link" below does.
- The note settles an output overrun as a failed call. An honest helper never
  sends more than the cap on a stream (`ExecOut` (`broker/framing.gleam:176`)),
  so this proposal treats an overrun as a protocol violation, as 109 treats
  every frame an honest executor never sends.
- The wire version the note names, 5, is right: 111 moved it to 4.

## Decision

### Wire version

`untrusted_wire.version` (`client/remote/untrusted_wire.gleam:92`) goes from 4
to 5. `protocol.version` stays 7.

### The seam in `client`

One function type, defined in `client/workspace_plane`:

```gleam
pub type ClearCall =
  fn(broker.CallSpec, Subject(broker.CallEvent), Int) ->
    Result(tool.RunningCall, broker.Refusal)
```

The third argument is the clearance wait, in milliseconds. `WorkspacePlane`
gains `clear_call: ClearCall` beside `broker`. `hookrunner.Context`
(`client/hookrunner.gleam:91`) and `worktree_diff.Wiring`
(`client/worktree_diff.gleam:76`) replace their `broker` field with
`clear_call: ClearCall`, and use the `RunningCall` closures for stdin and
cancel. `goalcheck.Runner` keeps its two-argument field, and
`goal_check_wiring` fills it with `plane.clear_call` applied to
`workspace_plane.jobs_clearance_ms`.

A local plane and a trusted remote one set `clear_call` to
`fn(spec, events, waiting) { tool.broker_runner(broker:, waiting:)(spec, events) }`
over the broker they hold today, so their behaviour does not change. An
untrusted placement sets it to `untrusted_link.tunnel(executor, session)`.
`WorkspacePlane.broker` stays for the code that holds a broker actor for other
reasons; on an untrusted placement it is the refusing relay it is today, and
none of the four callers reads it.

### Reaching the link

The link starts a door, a `weft/actor` linked to it and registered under
`untrusted_link.tunnel_name_for(executor)`, which forwards every message to the
link. A link restarted by `executors.reload` starts a new door under the same
name, so the clearing function looks the door up by name on every call and
holds no pid. `untrusted_links` clears the door's name as it clears the link's
before a start. Each executor name makes two atoms, so 116's bound of 1,024
names bounds them at 2,048.

The function sends `Clear(session, spec, events, waiting, reply)` to the door
and waits for the reply, monitoring the door. A door that is not registered, or
dies first, is `Error(BrokerUnavailable)`. The link answers within `waiting`, so
the function's own wait is `waiting` plus two seconds and is reached only when
the link has stopped answering.

### Frames

| Item | Direction | Fields | Reply |
|---|---|---|---|
| `clear_call` request | orchestrator | `binding`, `spec`, `waiting_ms` | `cleared` |
| `cleared` response | executor | `Ok` or a `broker.Refusal` | none |
| `call_stdin` request | orchestrator | `call` (the `clear_call`'s request id), `data` (base64), `eof` | none |
| `cancel` frame, existing | orchestrator | `id` | none |
| `call_event` frame, new | executor | `call`, `event`: `output {stream, data}` or `settled {outcome}` | none |

The wire's spec carries `op_id`, `step_id`, `base_policy`, `requirements`,
`response`, `argv`, `env`, `cwd` and `budget` (`max_outstanding`,
`deadline_ms`). It carries no `grants` and no `demand`: the executor takes
neither from the orchestrator ("Authority on the executor"). `outcome` is
`exited {result}` with the whole `ExecResult`, or `failed {failure}` with every
`ExecFailure` variant. Policies use the codec's existing `encode_sandbox_policy`
(`client/remote/untrusted_codec.gleam:1642`), and a `PolicyRefused` refusal
reuses `decode_denial` (`client/remote/untrusted_codec.gleam:2715`).

`cancel` names a request id, as in 109. For a `run` it still kills the waiter.
For a `clear_call` it asks the executor to cancel the call, which still ends
with one `settled` event. `call_stdin` and `cancel` go out only on an open
connection, like `ack`, because a call outlives no connection.

### A tunnelled call on the orchestrator

The link keeps tunnelled calls in a table of their own, by request id, never in
`outstanding`, so the re-send on a new connection never sees them. An entry is
in one of three states.

| State | Entered when | Events from the executor |
|---|---|---|
| `Clearing` | the link sends `clear_call`, or holds it for the next connection | a violation |
| `Running` | `cleared(Ok)` arrives; the asker is answered `Ok(RunningCall)` | delivered to the asker's `events` |
| `Withdrawn` | `waiting` passed in `Clearing`; the asker is answered `Error(BrokerUnavailable)` and `cancel` goes out | read and dropped |

`cleared(Error(refusal))` answers the asker with the refusal and removes the
entry. A `settled` event removes it. The asker is monitored. Its death, or a
`cancel()` through its `RunningCall`, sends `cancel` once. The entry stays
until its `settled` arrives, which is delivered to whoever is listening.

A `clear_call` made while the link has no connection is held in `Clearing` and
sent on the next connection's welcome, which is its first send. The link dials
for it as it dials for any request.

### A dropped connection

On the orchestrator, every tunnelled entry ends when its connection does. A
`Clearing` entry answers its asker `Error(BrokerUnavailable)`. A `Running`
entry delivers
`CallSettled(CallFailed(ExecutionLost(RelayDown)))` (`ExecutionLost`
(`broker/exec.gleam:337`)), the one failure that says the effect may have run
and must not be replayed. A `Withdrawn` entry is dropped. Nothing is sent again.

On the executor, each `clear_call` runs in a tunnel waiter: a process that owns
the `events` subject the broker is given, monitors its connection, and exits
when the connection does. The dispatcher watches the owner of every call's
`events` subject and cancels the execution when it dies (`caller`
(`broker/dispatch.gleam:190`)). So the child of a tunnelled call is cancelled
when the orchestrator's connection goes away, and nobody waits for it. This is
the reverse of a `run`'s waiter, which outlives its connection so that the
call's outcome reaches the ledger for the re-send.

A link that dies, or is replaced by `executors.reload`, settles nothing: its
callers' bounded waits end (`hookrunner.NeverSettled`, `worktree_diff`'s
`NoSettlement`, the goal check's "did not settle"), and the executor cancels the
children when the connection closes.

### Bounds

Each rule is checked by the link. A violation is logged and closes the
connection, which ends every tunnelled call on it as above; runs and requests
are re-sent as 109 describes.

| An executor sends | Response |
|---|---|
| a frame over `max_frame_bytes` | the socket refuses it (109) |
| a frame whose JSON holds more than `max_frame_values` (1,048,576) values | violation; `core/json` stops counting there, which bounds 109's decoded-breadth risk (finding F5) for every frame, not only these |
| a `call_event` for an id that is not a held tunnelled entry (never issued, issued for another kind of request, already settled) | violation; a second `settled` is this case |
| a `call_event` for an entry in `Clearing` | violation |
| an `output` event with no bytes | violation |
| more `output` bytes on one stream than the spec's `requirements.limits.output_bytes` | violation |
| a `cleared` of another kind, or for an id the link holds otherwise | violation (109's kind rule) |
| `total_bytes` | not carried; the link delivers its own running count |

The orchestrator also bounds what it opens. A spec whose `grants` are not empty,
or whose output limit is zero or above `max_call_output_bytes` (1 MiB, the
hooks' and the goal check's own cap), is refused at once with
`BrokerUnavailable` and logged; no caller in the tree sends one. A binding has
at most 8 open tunnelled entries and a link 64, counting `Withdrawn` ones; past
either the call is refused at once with `BrokerUnavailable`. A `call_stdin`
whose frame would pass the frame limit is not sent, and the link sends `cancel`
for its call. Output held for callers is therefore at most 64 calls of two 1 MiB
streams, all of them calls the orchestrator chose to open.

An event names no binding. Its call id is minted by the link and is the
authority it carries, so an event for another session's call is a claim about a
call this executor runs, which it can make in any case.

### Authority on the executor

`clear_call` is admitted under the binding it names, which must be one this
orchestrator holds in the book (`HolderOf` (`client/remote/untrusted_gateway.gleam:118`)),
as for a blob request. At attach the bridge hands the gateway the plane's broker
subject and base policy beside the projected response, and the book records
both under the binding. A binding with no record, or a retired one, is answered
`cleared(Error(BrokerUnavailable))`.

The tunnel waiter clears through `broker.over` on the recorded subject, with
the executor's own clock, and builds the spec it clears as follows.

- `base_policy` is the meet of the plane's base and the spec's, the first value
  of `policy.compose(base: plane_base, requirements: spec_base, grants: [])`
  (`compose` (`broker/policy.gleam:623`)). The orchestrator's callers send the
  census's base, or `worktree_diff.read_policy` of it, so the meet is what they
  asked for; a spec cannot widen the plane's base.
- `grants` is empty. 109's `run` brings the executor grants only from approvals
  of escalations; a tunnelled call has no escalation path.
- `demand` is the executor's own, from a new `untrusted_gateway.Config.demand`
  set from the setting the plane is built with.
- `argv`, `env`, `cwd`, `requirements`, `response` and `budget` are the
  orchestrator's. The broker composes the requirements onto the base, and
  `RefuseNarrowed` refuses anything the base withholds.

So the orchestrator chooses what to run, and the executor's jail decides what it
may touch, as for a `run`.

### Hooks on an untrusted executor

A hook that runs on an untrusted executor answers whatever the executor wants:
the settings bytes are checked against the trust record on the orchestrator, but
the script a hook command runs is in the executor's workspace, and the outcome
comes back over the link. `hookrunner.Context` gains `site`, `Here` or
`Tunnelled`, set by `with_imported_hooks` from the placement, and
`hookserve` reads a tunnelled hook under two rules.

1. **A hook sees only the executor's tools.** `hookserve.tool_gate`
   (`client/hookserve.gleam:551`) and `hookserve.tool_feedback`
   (`client/hookserve.gleam:666`) ask no tunnelled hook about a call whose tool
   is not in `tool_placement.workspace_names`. Without this, a `PreToolUse` or
   `PostToolUse` payload sends the executor the arguments and results of calls
   that ran on the orchestrator (notes, peer messages, orchestrator-run MCP
   servers), which 109 never sends. A guard hook on such a tool protects
   nothing when the executor writes its answer.
2. **A tunnelled hook cannot rewrite a call.** In `hookserve.cleared`, a
   `Rewrite` from a tunnelled hook is a refusal naming the reason, not a call to
   `recleared` (`client/hookserve.gleam:1117`). A second clearance on
   guest-chosen arguments can reach an operator's approval prompt, and 109 rules
   out asking the operator about a call with arguments the executor describes.

Everything else a hook can return is accepted as it stands. A deny or an exit 2
refuses one call, and `ask` already degrades to a refusal: both are denial of
service. `updatedToolOutput` changes the result of a call the executor ran
anyway. `SessionStart` context reaches the model as untrusted text, as the
census's guidance files do. A `Stop` continuation costs a model turn on the
orchestrator's provider key and is capped at `stop_block_cap`
(`client/hookserve.gleam:745`), eight per operation. A hook refused for a bound,
or lost to a dropped connection, is a hook that did not answer, which the
contract reads as no decision.

A user-level hook whose command uses `~` runs with `HOME` naming the operator's
home (`hook_environment` (`client/serve.gleam:402`)), a path the guest does not
have. That is true of a trusted remote executor today and is not changed here.

### Goal checks, the diff, the baseline and the peer view

A goal check's result is evidence for the reviewer (`CheckResult`
(`client/goalstate.gleam:235`)). An executor that reports exit 0 for a check
that failed can end a goal early, and one that reports failures can keep it
running until the goal's own accounting stops it. Both are lies about work the
executor holds, which 109 already accepts for every tool outcome.

The Changes tab, the baseline and the peer view are what the executor says about
its own worktree. The board is bounded by `board_byte_limit` and shown only to
the operator's terminal and the web view. The peer view is published as a
reserved fact and read into peer activity (`activity`
(`client/peer_mail.gleam:1361`)), where the code states that repository
similarity confers no messaging grant or filesystem authority. No
orchestrator-side decision reads any of the three.

### A baseline stored before the tunnel

New sessions probe a real baseline through the tunnel. A session that stored
`Unavailable` over the link before the tunnel existed keeps it. A probe now
would record the current `HEAD` as the session's start, and
`session_git` exists so that no session acquires a replacement baseline later
than its real start; its reopen path never probes (`initialize`
(`client/session_git.gleam:52`)). Such a session shows its working-tree changes
and, where its commits would be, the stored reason. It can exist only on a
guest made with the hidden `--link untrusted` of the design note's slice 1.

### Compatibility

A version 4 executor and a version 5 orchestrator, or the reverse, refuse each
other at the handshake. The executor answers `welcome` with its own numbers
before it closes, so the link knows why, and the session open reports the
attach's `VersionMismatch`, naming both versions. Every session on that
executor is refused, tools included, as for any version step of 109. `loom vm
up` replaces a guest root built from other artifacts than the host's manifest
in place (`root_step` (`client/vm_spec.gleam:1161`)), so the next `up` or
`ensure` after a release removes the mismatch; under a `dev` manifest the root
is kept and `up --fresh` is the remedy. A pod deployment upgrades its
orchestrator and its executors together.

## Threat model

Everything in 109's threat model stands. This proposal adds, for the sessions
placed on a hostile executor:

**What it can do.** Return any output and any outcome for a tunnelled call;
answer every hook about its own tools as it likes (deny, context, a rewritten
result, a stop continuation up to the cap); report a false goal check, a false
worktree board, a false baseline and a false peer view; hold up to 8 entries per
binding by never settling them, which refuses that session's later hooks and
observations until the connection drops.

**What it cannot do.** Start a call: only the orchestrator sends `clear_call`.
Run a call twice: nothing is re-sent. Keep a child running after the
orchestrator's connection is gone, in a compliant gateway; a hostile one can
keep its own processes running in any case. Widen the plane's base policy or
add a grant through a spec. Deliver more output than the orchestrator's cap, or
events for a call the link does not hold. Rewrite the arguments of any call, or
see the payload of a call that ran on the orchestrator. Make a frame decode to
more than `max_frame_values` values.

**Residual risks.**

- The executor sees the hook payloads of its own tools (arguments, results,
  the session's transcript path), the goal check command and the Git commands,
  all of which describe work it already holds.
- A hook's verdicts about the executor's own tools carry no assurance. An
  operator who relies on a `PreToolUse` guard must not rely on it for a session
  on an untrusted executor.

## What it costs

About 1,700 lines of product code and 900 of tests, the size of 109's slice 2:
the seam (about 150), the codec (about 500, most of it `ExecResult`,
`ExecFailure` and `broker.Refusal`), the link's tunnel table and door (about
400), the gateway's waiter and the book's record (about 300), the hook rules
(about 60), the value bound in `core/json` (about 60), and the bridge's
attach change.

Each executor costs a second process and a second atom. Each output chunk costs
a frame, and a hook's payload crosses the link as stdin, grown by a third as
base64. Hooks lose the ability to rewrite a call on an untrusted executor.
A version 4 executor and a version 5 orchestrator no longer work together.

### Not carried after this

- Remote evolution (109's slice 4). The link still sets the census to
  `Uncompiled`.
- The executor's node report of 085, which the machines view asks over
  distribution.
- `broker.abort` and `abort_step` through the plane's `broker`. Hooks and goal
  checks clear under attribution-only operations that nothing aborts, so no
  caller loses anything.
- The 109 residual risk of a remembered "for this session" grant from an
  escalation over the link.

## Slices

Each slice lands alone, in this order. The default flip of the design note's
slice 4 waits for slice 5.

1. **The seam.** `workspace_plane.ClearCall`, `WorkspacePlane.clear_call`, and
   `hookrunner.Context` and `worktree_diff.Wiring` taking it. No wire change.
   **Exit**: `hookrunner_test`, `hookserve_test`, `hookserve_e2e_test`,
   `worktree_diff_test`, `worktree_diff_limits_test` and `goalcheck_test` pass
   with no assertion changed, and `make check` is green.
2. **Wire 5, the codec and the value bound.** The new items in
   `untrusted_wire`, their codec, and `max_frame_values` through a bounded parse
   in `core/json`, used by `decode_envelope`
   (`client/remote/untrusted_codec.gleam:225`). **Exit**:
   `remote/untrusted_codec_test` round-trips every new item and every
   `ExecFailure` and `broker.Refusal` variant, refuses a spec with a `grants`
   member, and extends the kind matrices so only the diagonal decodes;
   `core/json_test` shows a document of `max_frame_values` values parses and one
   more is refused, on both targets.
3. **The tunnel for goal checks and Git.** The door and `untrusted_link.tunnel`,
   the call table and its rules, the gateway's waiter and the book's record, and
   `workspace.build` setting `clear_call` for an untrusted placement. Hooks keep
   the refusing path. **Exit**: `remote/untrusted_link_test` has the hostile
   executor send events for an id never issued, for a `run`'s id, for a call
   still `Clearing`, after its `settled`, a second `settled`, an empty output,
   output past the cap and a 1,048,577-value frame, each closing the connection
   while the link survives and the asker of a `Running` call hears
   `ExecutionLost(RelayDown)`; it drops the connection under a `Running` and a
   `Clearing` call and asserts nothing is re-sent; it kills an asker and asserts
   one `cancel`; and it refuses a ninth open call on one binding.
   `remote/untrusted_gateway_test` with a real broker: a dropped connection
   cancels the child; `cancel` ends the call with one `settled`; a spec whose
   base is wider than the plane's runs under the plane's; a binding the
   orchestrator does not hold is refused. `remote/untrusted_end_to_end_test`
   runs a goal check, a baseline probe, a worktree diff after a jailed edit and
   a peer observation through the link into a real plane.
4. **Hooks.** `hookrunner.Context.site`, the two rules in `hookserve`, and the
   hook context's `clear_call` set for an untrusted placement. **Exit**:
   `hookserve_test` shows a tunnelled hook is not asked about a tool outside
   `workspace_names`, a tunnelled `Rewrite` is refused without a second
   clearance, and a hook on a local plane still rewrites;
   `remote/untrusted_end_to_end_test` runs a `PreToolUse` deny and a `Stop`
   continuation through the link.
5. **The microVM step and the record.** A step of `daemon_shipped_microvm_test`
   on a guest made with `--link untrusted`: the session's baseline is a
   revision, a jailed `bash` edit shows in the Changes tab against it, and a goal
   check passes. A pointer addendum on 109, and the "Untrusted executors"
   section of `packages/client/CLAUDE.md`. **Exit**: the step passes on a host
   with the microVM tier, and `make doc-check` passes.

## Decisions for the owner

1. **Is a version 4 executor refused outright, rather than served without the
   tunnel?** Recommendation: refuse, as 110 and 111 did; guests share the host's
   release.
2. **Do hooks on an untrusted executor see only the executor's tools?**
   Recommendation: yes. The alternative sends orchestrator-side arguments and
   results to the executor for a verdict the executor controls.
3. **Is a tunnelled `Rewrite` refused, rather than read as `Proceed`?**
   Recommendation: refuse, so an operator whose hook rewrites sees why it did
   not, rather than a call that runs unchanged.
4. **Does a session that stored `Unavailable` over the link keep it?**
   Recommendation: keep it; only opt-in guests can hold one, and a later probe
   would claim a start the session never had.
5. **Is an output overrun a protocol violation, rather than a failure of one
   call?** Recommendation: a violation, as for every other frame an honest
   executor never sends.
6. **Does the decoded-value bound (F5) land here, for every frame?**
   Recommendation: yes. The orchestrator a guest talks to is the developer's
   whole daemon, and the bound is about 60 lines.
7. **Is a link restart allowed to leave a tunnelled call unsettled until its
   caller's own wait ends?** Recommendation: yes. Every caller bounds its wait,
   and the executor cancels the child when the connection closes.

## Review and disposition

To be filled by the reviewer.
