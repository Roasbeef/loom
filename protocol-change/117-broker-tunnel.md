# protocol-change/117: the broker tunnel, so non-tool callers reach an untrusted executor

**Status**: ACCEPTED 2026-11-17 by the owner, who answered "Decisions for the
owner" below as recommended. Proposed 2026-11-16 and revised after one
independent adversarial review and its re-check ("Review and disposition").
Not built.
**Affects**: the untrusted executor wire of [109](109-untrusted-executors.md)
(`untrusted_wire.version` 4 to 5): one new request and its reply, and one new
frame from the executor. One new process per untrusted executor on the
orchestrator (the link's tunnel door). In `client`, the non-tool callers of an
executor's broker take a clearing function in place of a `broker.Broker`; goal
checks and Git observation are served through the tunnel, and imported hooks
stay refused on an untrusted executor. `core/json` gains a parse that bounds the
number of values. The remote node vocabulary of
[078](078-distributed-runtime.md) and its `protocol.version` (7), `loom.toml`,
the client control protocol and every Part 1 interface are unchanged, and so
is a trusted executor's wire.
**Raised by**: the microVM tier. The owner ruled on 2026-11-13 that `loom vm up`
reaches guests over the untrusted link by default once this lands
(`docs/design-notes/microvm-untrusted-link.md`, section 5 and slice 3).
**Builds on**: 109 (the link, the gateway, bindings), 110 (a request that names
a binding, and the lost form of an oversized reply), 116 (the link's owner and
restarts).
**Issue**: loom #85.

## Problem

Four things a session does through its executor's broker are refused when the
executor is untrusted, because they call `broker.clear_call`, `broker.stdin` and
`broker.cancel` on `WorkspacePlane.broker` (`client/workspace_plane.gleam:367`),
and the link puts a broker subject whose owner has exited in that place
(`refusing_broker` (`client/remote/untrusted_link.gleam:555`)):

1. Goal checks, through `tool.broker_runner` in
   `goal_check_wiring` (`client/serve.gleam:6935`).
2. The Changes tab (`observe_worktree` (`client/serve.gleam:4752`)) and the peer
   view of the worktree (`peer_observation` (`client/worktree_diff.gleam:1195`)),
   both through `run_git` (`client/worktree_diff.gleam:738`).
3. The session's Git baseline. `session_git.prepare` probes it once, for a new
   session, and stores the answer (`prepare` (`client/session_git.gleam:33`)).
   Through the refusing broker the stored answer is `Unavailable`.
4. Project hooks: `hookrunner.run` clears each command
   (`clear_call` (`client/hookrunner.gleam:250`)), wired by
   `with_imported_hooks` (`client/serve.gleam:273`).

The first three are regressions against a trusted executor, and the untrusted
link cannot become the default for guests while they are refused. This
proposal serves them.

The fourth stays refused ("Hooks stay refused"). It is not a regression in
practice. The project's own settings files run only with a trust record that no
command writes yet, and the operator's user-level hooks, which are tried on a
trusted guest today, run there with `HOME` naming the operator's home, a path
the guest does not have, so the commands that name scripts under it fail.

## What was considered

### The link stands in for the broker actor (rejected)

The owner port already gives every remote session's non-tool callers a stable
subject and forwards each `broker.Msg` to the subject the latest attach named
(`owner_port.retarget` (`client/remote/owner_port.gleam:275`)). The link could
name a subject of its own there and serve the broker's messages itself, with no
change to any caller. `broker.Msg` is opaque (`Msg` (`broker/broker.gleam:259`))
and `CallHandle` can be made only inside the broker package, so this needs the
broker to export a reading of its own actor protocol, including the congestion
epochs `clear_call` retries with, `QueryRelay` and the abort sweeps.

### Re-send tunnelled calls as runs are re-sent (rejected)

A `run` is re-sent after a dropped connection because the executor's host
admits it by key and joins the call already running. A broker call has no key,
and a goal check sent again would run again. A tunnelled call is sent on one
connection at most.

### Hold a `clear_call` for the next connection (rejected)

The link could keep a call made while it has no connection and send it after
the next welcome. A link with a live binding redials with a pause of at most two
seconds, so holding gains little, and while a guest is down every held call
would stall its caller for its whole wait, where a trusted executor that is gone
refuses at once.

### A wall timer in the link (rejected)

The link could settle a running call as lost at the spec's wall plus a grace,
whatever the caller does. With output buffered to the settlement nothing renews
a caller's wait, and every caller already cancels when its wait ends, so the
timer is only a backstop. Any grace short enough to matter is below the relay's
own (`relay_grace_ms` (`broker/dispatch.gleam:68`), five seconds) and would
report an honest slow kill as lost.

### Wire hooks to the tunnel now (rejected)

No hook source can run through the tunnel until a command writes trust records
("Hooks stay refused"). Wiring hooks now would ship a path from executor-written
output into clearance, the run end and the run start that no user can exercise
and that only a test with a hand-written trust record covers, and it would carry
a disclosure that is not resolved: `hook_environment`
(`client/serve.gleam:402`) sets `HOME` to the operator's home for every hook,
and the session's `transcript_path` usually lies under it.

### Negotiate the tunnel in `welcome` (rejected)

The executor could announce the tunnel as a flag, so an old executor serves
tools and refuses only the tunnelled callers. 109 refuses any version mismatch
at the handshake, 110 and 111 kept that rule, and a guest image is built from
the same release as the host.

### Reach the link through a weft registry address (rejected for now)

A `weft/registry` address would give the link a second typed subject without an
atom. The address is a reference, so it would have to travel from the registry
of 116 to `workspace.untrusted_candidate` with the row, as a new field on
`executors.Executor`. A second registered name follows the pattern the link
already uses (`name_for` (`client/remote/untrusted_link.gleam:416`)).

### Corrections to the design note

Section 5 of the design note is the starting point. Against the code:

- A remote session's non-tool callers hold
  `broker.over(owner_port.broker(port), executor_clock)`
  (`build` (`client/remote/workspace.gleam:669`), line 697), a relay the owner
  port retargets at every attach, not `broker.over(census.broker, ..)`.
- The executor side does not see the plane's broker subject when it encodes an
  attach reply. `untrusted_bridge.ask_host` projects the census onto the wire
  inside the waiter (`projected` (`client/remote/untrusted_bridge.gleam:1305`)),
  and the gateway's `answer` (`client/remote/untrusted_gateway.gleam:644`) gets
  a `Response` with the subject already dropped.
- The seam cannot be the two-argument `tool.broker_runner` shape, which fixes
  the clearance wait when it is built; `hookrunner.run` and `run_git` choose a
  different wait for every call. The peer view and `git_identity.run`
  (`client/git_identity.gleam:419`) use `worktree_diff.Wiring`, so two types
  change.
- A hook's `allow` already skips nothing. `ToolPermission`
  (`client/hookdecisions.gleam:95`) maps `allow` to `Proceed`, and
  `hookserve.cleared` (`client/hookserve.gleam:1050`) asks hooks only after the
  harness has cleared the call. The note's step 6 is therefore not built; what a
  guest's hooks would add is listed under "Hooks stay refused".
- A session that stored `Unavailable` keeps a Changes tab once the tunnel lands.
  Its working tree is observed afresh on every request; only the commits since
  the session started stay unavailable, because `capture_committed`
  (`client/worktree_diff.gleam:412`) shows the stored reason in their place.
- The note gives the clearing function no way to reach the link, which
  `executors.reload` can replace at any time.
- The wire version the note names, 5, is right: 111 moved it to 4.

## Decision

### Wire version

`untrusted_wire.version` (`client/remote/untrusted_wire.gleam:112`) goes from 4
to 5. `protocol.version` stays 7.

### The seam in `client`

One function type, defined in `client/clear_call` and re-exported by
`client/workspace_plane` (which imports `worktree_diff`, so a definition there
would make the import graph cyclic):

```gleam
pub type ClearCall =
  fn(broker.CallSpec, Subject(broker.CallEvent), Int) ->
    Result(tool.RunningCall, broker.Refusal)
```

The third argument is the clearance wait, in milliseconds. `WorkspacePlane`
gains `clear_call: ClearCall` beside `broker`, and the doc comment of `broker`
stops naming the non-tool callers. `hookrunner.Context`
(`client/hookrunner.gleam:91`) and `worktree_diff.Wiring`
(`client/worktree_diff.gleam:76`) replace their `broker` field with
`clear_call: ClearCall` and use the `RunningCall` closures for stdin and
cancel; so does `git_identity.run`, which reads the same `Wiring`.
`goalcheck.Runner` keeps its two-argument field, and `goal_check_wiring` fills
it with `plane.clear_call` applied to `workspace_plane.jobs_clearance_ms`.

A local plane and a trusted remote one set `clear_call` to
`fn(spec, events, waiting) { tool.broker_runner(broker:, waiting:)(spec, events) }`
over the broker they hold today, so their behaviour does not change. An
untrusted placement sets it to `untrusted_link.tunnel(executor, session)`, and
`with_imported_hooks` gives the hook context of an untrusted placement a
function that answers `Error(BrokerUnavailable)`, so hooks there are refused as
they are today. `WorkspacePlane.broker` stays for the code that holds a broker
actor for other reasons; on an untrusted placement it is the refusing relay it
is today.

Two constraints from other work bind the build. `serve`'s `observe_worktree`
stays a zero-argument closure handed to `assemble_in`. `worktree_diff.capture_timeout_ms`
and `worktree_diff.settlement_grace_ms` stay exported.

### Reaching the link

The link starts a door, a `weft/actor` linked to it and registered under
`untrusted_link.tunnel_name_for(executor)`, which forwards every message to the
link. A link restarted by `executors.reload` starts a new door under the same
name, so the clearing function looks the door up by name on every call and
holds no pid. `untrusted_links` clears the door's name as it clears the link's
before a start. Each executor name makes two atoms, so 116's bound of 1,024
names bounds them at 2,048.

The function sends `Clear(session, spec, events, waiting, reply)` to the door,
where `reply` is a subject it makes for this call, and waits for the answer,
monitoring the door. A door that is not registered, or dies first, is
`Error(BrokerUnavailable)`. The link answers within `waiting`, so the
function's own wait is `waiting` plus two seconds. If that wait ends, the
function sends `Withdraw(reply)` and answers `Error(BrokerUnavailable)`; the
link's answer, if it was sent, stays unread on a subject nobody selects again.

### Frames

| Item | Direction | Fields | Reply |
|---|---|---|---|
| `clear_call` request | orchestrator | `binding`, `spec`, `waiting_ms` | `cleared` |
| `cleared` response | executor | `Ok` or a `broker.Refusal` | none |
| `cancel` frame, existing | orchestrator | `id`; kills the waiter, as for a `run` | none |
| `call_event` frame, new | executor | `call`, `event`: `output {stream, data}` or `settled {outcome}` | none |

The wire's spec carries `op_id`, `step_id`, `base_policy`, `requirements`,
`response`, `argv`, `env`, `cwd` and `budget` (`max_outstanding`,
`deadline_ms`). It carries no `grants` and no `demand`, which the executor
takes from nowhere but itself ("Authority on the executor"). `outcome` is
`exited {result}` with the whole `ExecResult`, or `failed {failure}` with every
`ExecFailure` variant. Policies use the codec's existing `encode_sandbox_policy`
(`client/remote/untrusted_codec.gleam:1829`), and a `PolicyRefused` refusal
reuses `decode_denial` (`client/remote/untrusted_codec.gleam:2902`). The codec
refuses a `waiting_ms` above 4,294,967,295, the longest timeout a receive
takes; a `deadline_ms` above 2^42 epoch milliseconds, because the executor's
relay arms a timer for the time left to it; an `argv` of more than 4,096
entries; and an `env` of more than 1,024 pairs, as 109's codec refuses absurd
sizes. The link refuses the same values before it sends a request.

`waiting_ms` is the caller's wait less one second, and at least one
millisecond, so an honest `NoHelper` answered at the executor's deadline reaches
the link before the link's own wait ends.

There is no stdin frame. Every caller the tunnel serves writes no input and
closes stdin at once: `run_git` sends `<<>>` with end of input, as do the goal
check (`execute`, `client/goalcheck.gleam:225`) and `git_identity.run`. The
tunnel waiter closes the child's stdin when the call clears, and the tunnel's
`RunningCall.stdin` does nothing. A caller that needs input, as hooks would,
needs a frame for it first.

An `output` event carries no `truncated` and no `total_bytes`. The tunnel
waiter forwards no chunk with no bytes: the helper sends one when a stream's
admitted bytes reach its cap exactly and the child writes more (`pump`
(`internal/jail/run.go:668`)), and that chunk says only that truncation began.
At settlement the link builds each stream's `CallOutput` with `truncated:
False` and the stream's byte count as `total_bytes`. The collector reads
`truncated` (`collect_window` (`tools/tool.gleam:1338`)), so truncation
reaches the callers through the outcome instead: `worktree_diff.settled` reads
`ExecResult.stdout_truncated` and `stderr_truncated` beside the collector's
flags, and the goal check keeps a tail and reads no truncation at all.

`cancel` keeps its one 109 meaning, for a `clear_call` as for a `run`: the
gateway kills the request's waiter. No caller waits for the executor's account
of a cancelled call: `run_git` returns `NoSettlement` after its cancel, and the
goal check records "did not settle". `cancel` goes out only on an open
connection, like `ack`.

### A tunnelled call on the orchestrator

The link keeps tunnelled calls in a table of their own, by request id, never in
`outstanding`, so 109's re-send never sees them. A call counts as sent when the
link calls `send` for its frame, whatever `send` returns. An entry is `Clearing`
from its send until `cleared(Ok)`, and `Running` from then until it is removed.

The link answers a `Clear` at once, and sends nothing, when its connection is
not open, when the session holds no binding on this link (a link started in
place of another, 116), when the spec carries grants, when its output limit is
zero or above `max_call_output_bytes` (1 MiB, the goal check's own cap), when
the frame would pass `max_frame_bytes` or `max_frame_values`, which the link
checks where it checks `too_large_to_send`
(`client/remote/untrusted_link.gleam:826`), and when the binding already has 8
entries or the link 64. Each is `Error(BrokerUnavailable)` and is logged; no
caller in the tree sends a spec the link refuses for its shape, and a refused
request is never kept or re-sent.

Every ordering ends in one stated outcome:

| What happens | Entry | Asker hears | Frame sent |
|---|---|---|---|
| `cleared(Ok)` while `Clearing` | becomes `Running` | `Ok(RunningCall)` | none |
| `cleared(Error(r))` while `Clearing` | removed | `Error(r)` | none |
| `waiting` passes while `Clearing` | removed | `Error(BrokerUnavailable)` | `cancel` |
| `Withdraw(reply)` | removed if held | nothing more | `cancel` if held |
| `call_event output` while `Running` | stays | nothing yet; the bytes are buffered | none |
| `call_event settled` while `Running` | removed | one `CallOutput` per stream with bytes, then `CallSettled` | none |
| `RunningCall.cancel()` | removed | `CallSettled(CallFailed(ExecutionLost(RelayDown)))` | `cancel` |
| the asker dies | removed | nobody | `cancel` |
| the connection drops | removed | `Error(BrokerUnavailable)` if `Clearing`, `CallSettled(CallFailed(ExecutionLost(RelayDown)))` if `Running` | none |
| `cleared` or `call_event` for an id the link issued and no longer holds | none | nothing | none (dropped) |
| `cleared` while `Running`, `call_event` while `Clearing`, either for an id never issued or held as another kind of request | none | as for a dropped connection, for every entry | violation, closes the connection |

The dropped-frame rule is 109's for responses (`responded`
(`client/remote/untrusted_link.gleam:1225`)): an id from 1 up to `next_id` was
issued, so a frame for it that the link no longer holds crossed a removal. A
second `settled` is therefore dropped, not a violation.

`ExecutionLost` (`broker/exec.gleam:337`) is the one failure that says the
effect may have run and must not be replayed; its `RelayDown` cause is the link
standing where a relay would stand.

**Every caller of `ClearCall` bounds its wait and cancels when it ends.**
`run_git` collects within its remaining deadline plus
`settlement_grace_ms` and cancels on silence (`client/worktree_diff.gleam:793`);
the goal check collects within its wall plus its settle grace and cancels
(`execute` (`client/goalcheck.gleam:225`)); `hookrunner.run`
(`client/hookrunner.gleam:236`) collects within its timeout plus its settle
grace and cancels. The
collector's window renews at each event (`collect_events`
(`tools/tool.gleam:1272`)), but the link delivers a call's events only at its
settlement, so before that the window is one wait from the moment the call
cleared. A cancel or the asker's death removes the entry. The 8-per-binding and
64-per-link bounds hold whatever a caller does.

The link buffers a `Running` call's output per stream and hands it to the
caller only at settlement. The buffer grows with a bit-array expression,
`<<buffer:bits, chunk:bits>>`, which the runtime extends in place when the
buffer is not shared; `bit_array.append` goes through `list_to_bitstring`
and copies the whole buffer for every chunk. The callers fold output into a
result and show none of it while the call runs, so nothing they do changes.
The memory the link holds for tunnelled output is the bytes themselves, at most
64 entries of two 1 MiB streams, rather than one message per chunk in each
caller's mailbox, which a stream of one-byte chunks would make tens of times
larger.

A link that dies, or is replaced by `executors.reload`, settles nothing. Its
callers' waits end and they cancel into a link that is gone, and the executor
cancels the children when the connection closes.

### The executor side

Each `clear_call` runs in a tunnel waiter: a process that owns the `events`
subject the broker is given, clears with `broker.over` on the recorded broker
subject, closes the child's stdin, and forwards each non-empty chunk and the
settlement as `call_event` frames. Its `cleared` reply reaches the connection
before its first event, because both are messages from the waiter to the
connection.

The waiter is linked to its connection, so a connection that crashes takes its
waiters with it. A connection does not trap exits, so a waiter killed while
linked would take the connection with it: the gateway unlinks a tunnel waiter
before it kills it for a `cancel`. Every path by which a connection stops
normally (`closed` (`client/remote/untrusted_gateway.gleam:830`), an ended or
broken socket) unlinks and kills the connection's tunnel waiters first, because
a normal stop does not propagate through a link. A waiter killed inside
`broker.clear_call`, which waits out a congested pool in the caller's own
process, dies at once. If the broker dispatches the call afterwards, it still
names the dead waiter as the call's caller, the relay's monitor on that pid
fires at once (`caller` (`broker/dispatch.gleam:190`)), and the child is
cancelled just after it starts. This is the reverse of a `run`'s waiter, which
outlives its connection so that the call's outcome reaches the ledger for the
re-send.

Over the tunnel, `BrokerUnavailable` does not prove that the command never
started: a call killed with its connection, or withdrawn while clearing, may
have started and been cancelled. No caller re-runs on that refusal.
`goalcheck.admitted` (`client/goalcheck.gleam:279`) retries only
`OutstandingCapReached`, and `run_git` reports the refusal.

### Bounds on what an executor sends

A violation is logged and closes the connection. The tunnelled entries end as
for a dropped connection, and runs and requests are re-sent as 109 describes.

| An executor sends | Response |
|---|---|
| a frame over `max_frame_bytes` | the socket refuses it (109) |
| a frame whose JSON holds more than `max_frame_values` (1,048,576) values | violation |
| more `output` bytes on one stream than the spec's `requirements.limits.output_bytes` | violation |
| an event or a `cleared` the table above calls a violation | violation |

`max_frame_values` is the bound, in JSON values, for 109's decoded-breadth risk
(finding F5 of the design note). It applies to every frame through `decode_envelope`
(`client/remote/untrusted_codec.gleam:329`) and to a fetched outcome through
`decode_outcome_bytes` (`client/remote/untrusted_codec.gleam:390`), which reads
up to `max_outcome_bytes` (96 MiB) inside the link. A fetched outcome that the
bounded parse refuses is answered to its asker as lost (`fetched`
(`client/remote/untrusted_link.gleam:1450`)), which is no violation. An honest
gateway counts a response's values where `replied`
(`client/remote/untrusted_gateway.gleam:771`) checks `fits`, and sends a
response over the count as `Oversized`, as it sends one over the byte bound. The
orchestrator then fetches the outcome and answers it lost, or answers a reply
that holds no outcome lost at once, so an honest executor never loops on a
re-send.

An event names no binding. Its call id is minted by the link and is the
authority it carries, so an event for another session's call is a claim about a
call this executor runs, which it can make in any case.

### Authority on the executor

`clear_call` is admitted under the binding it names, which must be one this
orchestrator holds in the book (`HolderOf` (`client/remote/untrusted_gateway.gleam:118`)),
as for a blob request. At attach the bridge hands the gateway the plane's broker
subject and base policy beside the projected response, and the attach's waiter
records both under the binding with a call the book answers before the attach
reply is sent, so a `clear_call` that follows the reply finds them. A binding
with no record, or a retired one, is answered `cleared(Error(BrokerUnavailable))`.

The tunnel waiter builds the spec it clears as follows.

- `base_policy` is the first value of
  `policy.compose(base: plane_view, requirements: spec_base, grants: [])`
  (`compose` (`broker/policy.gleam:623`)), where `plane_view` is the plane's
  base with its writable roots also listed as readable. The meet intersects
  readable and writable roots separately (`meet` (`broker/policy.gleam:699`)),
  and `worktree_diff.read_policy` (`client/worktree_diff.gleam:870`) moves the
  writable roots into the readable list, so a meet against the plane's base as
  it stands would drop every root the plane holds as writable only (a linked
  worktree's Git directory, a short tool tmpdir) and refuse every Git call.
  Counting a writable root as readable widens nothing: the jail already lets a
  writable root be read. A spec cannot widen the plane's base.
- `grants` is empty. 109's `run` brings the executor grants only from approved
  escalations; a tunnelled call has no escalation path.
- `demand` is the executor's own, from a new `untrusted_gateway.Config.demand`
  set from the setting the plane is built with.
- `argv`, `env`, `cwd`, `requirements`, `response` and `budget` are the
  orchestrator's. The broker composes the requirements onto the base, and
  `RefuseNarrowed` refuses anything the base withholds.

The executor refuses, with `cleared(Error(BrokerUnavailable))` and before it
starts a waiter, a spec whose base policy or requirements name a readable or
writable root that is not a plain absolute path: one with a `.`, a `..` or an
empty segment, read as bytes. The meet compares roots as text, so a plane
root `/w` keeps a spec root `/w/..`, and the helper cleans that to `/` when it
builds the jail. The other path fields cannot widen the plane (protected paths
are a union, a mount is kept only when it equals one of the base's, the
scratch is the base's or a tmpfs, and the working directory is not part of the
policy) and are not checked, so an honest base with an unplain protected path
still clears. The cause is that `broker/policy.validate` admits uncanonical
roots; refusing them there is left as a follow-up.

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
(`client/peer_mail.gleam:1361`)), where repository similarity confers no
messaging grant or filesystem authority. No orchestrator-side decision reads any
of the three. A refusal's text that the baseline probe stores in
`session/git-start` (`error_message` (`client/worktree_diff.gleam:1171`)) is
clipped to 512 characters before it is stored, as `capture_committed` clips it
for display, so executor text does not land in the session store at frame size.

### A baseline stored before the tunnel

New sessions probe a real baseline through the tunnel. A session that stored
`Unavailable` over the link before the tunnel existed keeps it. A probe now
would record the current `HEAD` as the session's start, and `session_git` exists
so that no session acquires a baseline later than its real start; its reopen
path never probes (`initialize` (`client/session_git.gleam:52`)). Such a session
shows its working-tree changes and, where its commits would be, the stored
reason. Every session opened on an untrusted executor under 109 holds one: on a
guest made with the hidden `--link untrusted`, and on every untrusted pod.

### Hooks stay refused, and what wiring them later requires

A session on an untrusted executor runs no imported hook, as today. No source
could run through the tunnel when it lands. `hookserve.locations`
(`client/hookserve.gleam:170`) finds three: the operator's
`~/.claude/settings.json` and the project's two settings files. `first_sight`
(`client/hookserve.gleam:498`) serves the project's files only with a trust
record, and no command writes one yet; `LoomInline` has no loader that produces
entries, and plugins are not located. That leaves the user-level file, which the
first precondition below excludes.

A hook that ran on an untrusted executor would answer whatever the executor
wants: its settings bytes are checked against the trust record on the
orchestrator, but the script a command runs is in the executor's workspace and
the outcome comes back over the link. A later change that wires hooks to the
tunnel must first build these preconditions, and they are to be settled with
the trust command, which decides what trusting a guest's project file means.

1. **No user-level source.** Served through the tunnel, each command of the
   operator's file would be sent as the spec's `argv` (`["sh", "-c", command]`,
   so any URL or token written inline in a command), and the scripts those
   commands name are not on the guest. A session on an untrusted executor
   serves no `UserSettings` source and logs one line naming the file it
   skipped.
2. **A hook sees only the executor's tools.** `hookserve.tool_gate`
   (`client/hookserve.gleam:551`) and `hookserve.tool_feedback`
   (`client/hookserve.gleam:666`) ask no tunnelled hook about a call whose tool
   is not in `tool_placement.workspace_names`. A payload otherwise sends the
   executor the arguments of calls that ran on the orchestrator (notes, peer
   messages), which 109 never sends.
3. **No rewrite.** In `hookserve.cleared`, a `Rewrite` from a tunnelled hook is
   a refusal naming the hook, not a call to `recleared`
   (`client/hookserve.gleam:1117`). A second clearance on guest-chosen arguments
   can reach an operator's approval prompt, and 109 rules out asking the
   operator about a call with arguments the executor describes.
4. **No compaction note.** `compaction_note` (`client/hookserve.gleam:705`)
   returns `None` for a tunnelled hook. The note is placed at the end of the
   summarizer's input without a fence, and the summary replaces history durably.
5. **Bounded text.** A tunnelled `Stop` reason, `Ask` reason and `PostToolUse`
   context pass through `hookdecisions.capped`
   (`client/hookdecisions.gleam:519`), as a deny, feedback and an injection
   already do, applied for tunnelled hooks only so local hooks are unchanged.
6. **No operator home.** A tunnelled hook is given neither the operator's `HOME`
   (`hook_environment` sets it for every hook) nor a `transcript_path` under
   it.
7. **A stdin frame.** A hook reads its payload on stdin, which the tunnel does
   not carry.

### Compatibility

A version 4 executor and a version 5 orchestrator, or the reverse, refuse each
other at the handshake, and every session on that executor is refused, tools
included. Today the link reads only the peer's `protocol.version` from a
mismatched `welcome` and refuses with `VersionMismatch(supported: theirs)`
(`greeted` (`client/remote/untrusted_link.gleam:1084`)), whose text names
protocol versions; on a wire-only mismatch it reads "the executor speaks
protocol version 7 and this orchestrator does not". Slice 2 logs both wire and
both protocol numbers at every mismatch, and when the protocol numbers agree it
refuses with `Unreachable` naming both wire numbers.

`loom vm up` replaces a guest root built from other artifacts than the host's
manifest in place (`root_step` (`client/vm_spec.gleam:1161`)), so the next `up`
or `ensure` after a release removes the mismatch; under a `dev` manifest the
root is kept and `up --fresh` is the remedy. A pod deployment upgrades its
orchestrator and its executors together.

## Threat model

Everything in 109's threat model stands. This proposal adds, for the sessions
placed on a hostile executor:

**What it can do.** Return any outcome for a goal check or a Git call; report a
false goal check, a false worktree board, a false baseline and a false peer
view; hold an entry until the clearance wait passes or, once cleared, for at
most the caller's wait, which with 8 entries per binding refuses that session's
later checks and observations for as long.

**What it cannot do.** Start a call: only the orchestrator sends `clear_call`.
Run a call twice: nothing is re-sent. Keep a child running after the
orchestrator's connection is gone, in a compliant gateway; a hostile one can
keep its own processes running in any case. Widen the plane's base policy or
add a grant through a spec. Deliver more output than the orchestrator's cap, or
make the link hold more than those bytes. Hold an entry past its caller's wait.
Run a hook, or receive a hook's command, payload or the operator's home path.
Make a frame or a fetched outcome decode to more than `max_frame_values` JSON
values.

**Residual risks.** The executor sees the goal check command and the Git
commands, which describe work it already holds. A base64 string is one JSON
value but can carry a nested document that is decoded outside the value bound:
`msgpack_of`, `decode_sandbox_policy` and `decode_lsp_server` in
`client/remote/untrusted_codec.gleam` each parse one, and about 24 MiB of
msgpack inside a 32 MiB frame can hold millions of values. The bound is on JSON values, not on
everything a frame decodes to. A byte cap on `msgpack_of` would refuse honest
large binary arguments, so the risk is recorded rather than closed.

*Addendum, 2026-11-18 (issues #1278 and #1279).* The msgpack half of this risk
is closed by a value bound, not a byte cap, so honest large binary arguments
are unaffected: a `bin` is one value however long. `msgpack_of`, and the two
sandbox policy readers that now go through it, decode with
`msgpack.decode_bounded` under `untrusted_wire.max_msgpack_values`
(1,048,576, the order of `max_frame_values`). A payload past it is a decode
error, so the link closes the connection as it does for an oversized frame; the
untrusted wire version stays 5, because this refuses input and adds no frame.
The first value past the bound is refused as it is reached, so a payload of 24
MiB of one-byte values is refused after about 1,048,576 values of work, not
24 million. Measured on the development Mac under OTP 29, decoding a payload of
exactly the bound's values takes about 0.16 s for an array of nils (1 MiB),
about 0.23 s for an array of `uint16` integers (3 MiB), and about 1.1 s for a
map of 524,287 four-byte string keys with nil values (3.5 MiB), the most
expensive shape found because each key is also entered in the duplicate-key
index; refusing a payload one past the bound costs about 0.11 s, and refusing
24 MiB of nils about 0.12 s. Each runs in the link's process. The sender side
is not extended: `encode_fitting` still counts JSON values only, so an honest
executor whose capability result holds more than the bound's msgpack values
would close the connection; no such result exists today, since tool output
crosses as strings and `bin`. `core/json.parse_number` also refuses a run of
more than `json.max_number_digits` (4,096) digits, which the value bound did
not limit because a number is one value. `decode_lsp_server` parses a JSON text
carried in a string with `gleam_json` and is not bounded by either change.

## What it costs

About 1,650 lines of product code and 850 of tests: the seam (about 170, with
`git_identity` and the refusing hook function), the codec (about 500, most of
it `ExecResult`, `ExecFailure` and `broker.Refusal`), the link's tunnel table,
door and buffer (about 400), the gateway's waiter and the book's record (about
300), the value bound in `core/json` and its uses on both sides (about 90), and
the bridge's attach change.

Each executor costs a second process and a second atom. Each output chunk costs
a frame, grown by a third as base64. A version 4 executor and a version 5
orchestrator no longer work together.

### Not carried after this

- Imported hooks on an untrusted executor, until a trust command exists and the
  seven preconditions above are built.
- Remote evolution (109's slice 4). The link still sets the census to
  `Uncompiled`.
- The executor's node report of 085, which the machines view asks over
  distribution.
- `broker.abort` and `abort_step` through the plane's `broker`. Goal checks
  clear under an attribution-only operation that nothing aborts.
- The 109 residual risk of a remembered "for this session" grant from an
  escalation over the link.

## Slices

Each slice lands alone, in this order, and each exit is a check that fails
without the slice. The default flip of the design note's slice 4 waits for
slice 4 here.

1. **The seam.** `workspace_plane.ClearCall`, `WorkspacePlane.clear_call`, and
   `hookrunner.Context`, `worktree_diff.Wiring` and `git_identity.run` taking
   it. **Exit**: a new case in `hookrunner_test` and one in `worktree_diff_test`
   drive the caller through a fake `ClearCall` that records the spec and answers
   a scripted settlement; `make check` is green.
2. **Wire 5, the codec and the value bound.** The new items in
   `untrusted_wire`, their codec, the bounded parse in `core/json` used by
   `decode_envelope` and `decode_outcome_bytes`, the value count on the link's
   own sends and beside the gateway's `fits`, and the version mismatch's log and
   refusal text ("Compatibility"). Its gateway answers every `clear_call` with
   `cleared(Error(BrokerUnavailable))` until slice 3 lands. **Exit**:
   `remote/untrusted_codec_test` round-trips every new item and every
   `ExecFailure` and `broker.Refusal` variant, refuses a spec with a `grants`
   member and each oversized field, and extends the kind matrices so only the
   diagonal decodes; `core/json_test` runs the count's cases at a small size
   on both targets, because the JavaScript parser takes a stack frame per array
   item, and the full bound of `max_frame_values` values, accepted and then
   refused one past, is exercised on the BEAM in the client suites; `remote/untrusted_link_test`
   refuses a 1,048,577-value frame, answers a fetched outcome over the bound as
   lost, and names both wire numbers on a wire-only mismatch;
   `remote/untrusted_gateway_test` answers a `clear_call` with
   `BrokerUnavailable`.
3. **The tunnel.** The door and `untrusted_link.tunnel`, the call table and
   buffer, the gateway's waiter and the book's record, and `workspace.build`
   setting `clear_call` for an untrusted placement while `with_imported_hooks`
   sets the refusing function. The link checks a spec's `argv`, `env`,
   `waiting_ms` and `deadline_ms` against the codec's limits where it checks
   `encode_fitting`, so an over-limit spec is refused locally with
   `BrokerUnavailable` and never makes the gateway close the connection.
   **Exit**: `remote/untrusted_link_test` has the
   hostile executor send events for an id never issued, for a `run`'s id, for a
   call still `Clearing`, a `cleared` for a `Running` call, and output past the
   cap, each closing the connection while the link survives and a `Running`
   asker hears `ExecutionLost(RelayDown)`; it drops a late `cleared` and a
   second `settled` without a violation; it drops the connection under a
   `Running` and a `Clearing` call and asserts nothing is re-sent; it kills an
   asker, cancels, and withdraws, each sending one `cancel`; it refuses a `Clear`
   with no connection, with no binding, and a ninth on one binding.
   `remote/untrusted_gateway_test` with a real broker and helper: a dropped
   connection cancels the child, including one whose waiter is still clearing
   against a full pool; `cancel` kills the waiter and the connection serves the
   next request; a command printing past its cap settles with
   `ExecResult.stdout_truncated` set and no violation; a plane whose base holds a
   writable-only root runs a `read_policy` Git call; a spec whose base is wider
   than the plane's, sent with `ProceedNarrowed`, runs under the plane's base; a
   binding the orchestrator does not hold is refused.
   `remote/untrusted_end_to_end_test` runs a goal check, a baseline probe, a
   worktree diff after a jailed edit and a peer observation through the link
   into a real plane, and shows a hook refused.
4. **The microVM step and the record.** A step of `daemon_shipped_microvm_test`
   on a guest made with `--link untrusted`: the session's baseline is a
   revision, a jailed `bash` edit shows in the Changes tab against it, and a goal
   check passes. A pointer addendum on 109, and the "Untrusted executors"
   section of `packages/client/CLAUDE.md`. **Exit**: the step passes on a host
   with the microVM tier and fails on the tree before slice 3; `make doc-check`
   passes.

## Decisions for the owner

The owner accepted all three recommendations on 2026-11-17: a stale guest is
refused, hooks stay refused, and a stored `Unavailable` is kept.

1. **Is a stale guest (wire version 4) refused until `loom vm up` upgrades its
   root, rather than served without the tunnel?** Recommendation: refuse.
   Refused, the guest's sessions do not open until `up` or `ensure` runs, and
   the error names both wire versions; served, they open with tools and without
   a Changes tab or goal checks.
2. **Do hooks stay refused in sessions on an untrusted executor until a trust
   command exists and the seven preconditions are built?** Recommendation: yes.
   Refused, the operator's user-level hooks do not run in a `--vm` session once
   the untrusted link is the default; today, over distribution, they are tried
   there with the operator's `HOME`, which names a path the guest does not have,
   so the ones that name scripts fail either way.
3. **Does a session that stored `Unavailable` over the link keep it?**
   Recommendation: keep it. Kept, its Changes tab shows the working tree and,
   in place of its commits, the stored reason; probed again, it shows commits
   since the moment of the probe as if the session had started then.

## Review and disposition

One independent, read-only adversarial review, 2026-11-16, of the first draft
against the code at 206f18fa8, reporting findings only. Each finding was checked
in the code before it was taken; the two HIGH findings were also checked
separately by the coordinator of the work.

The same reviewer re-checked the revision at d8a7ac90f on 2026-11-17. It found
the first round's findings closed except as listed below, confirmed that no
caller depends on output before settlement, and confirmed that no hook source
can run through the tunnel, which led to keeping hooks refused.

A fourth review, of slice 3 as built (`remote/broker-tunnel` at 3f1ba87b3), was
read-only and found no way for a hostile executor to break the orchestrator
side; its findings and those of its re-check of the fixes are the last six
rows.

| Severity | Finding | Disposition | Where it landed |
|---|---|---|---|
| HIGH | An honest helper sends an empty chunk with `truncated` when a stream reaches its cap exactly (`pump`), which the draft called a violation | Accepted. No empty chunk is forwarded; `truncated` and `total_bytes` are not carried and are rebuilt at settlement | "Frames", "Bounds", slice 3 |
| HIGH | User-level hook commands, the operator's home and the transcript path would be sent to the executor | Accepted with change: hooks stay refused; the rule is precondition 1 | "Hooks stay refused", decision 2 |
| MEDIUM | The meet against the plane's base drops writable-only roots for `read_policy` specs | Accepted | "Authority on the executor", slice 3 |
| MEDIUM | The state table left orderings open | Accepted with change. No held calls, no `Withdrawn`, issued-and-gone frames dropped, unbound sessions refused, `Withdraw` for the function's own wait | "A tunnelled call on the orchestrator" |
| MEDIUM (simplify) | `cancel` with two meanings | Accepted. `cancel` kills the waiter; the link delivers `ExecutionLost(RelayDown)` | "Frames", the table |
| MEDIUM (simplify) | Holding a `clear_call` for the next connection | Accepted. Refused unless the connection is open | "What was considered", the table |
| MEDIUM | A waiter blocked in `clear_call` cannot see its connection drop | Accepted. Linked, and killed with its connection; the refusal does not prove nothing ran | "The executor side" |
| MEDIUM | Callers' waits are idle windows a hostile executor renews | Accepted with change. Closed by buffering output to the settlement; the wall timer of the revision was later cut | "A tunnelled call on the orchestrator" |
| MEDIUM | F5 is not bounded for a fetched outcome, and an honest response over the bound would loop | Accepted | "Bounds" |
| MEDIUM | The hook enumeration omits `PreCompact`; `Stop`, `Ask` and context text are uncapped | Accepted as preconditions 4 and 5 | "Hooks stay refused" |
| MEDIUM | The version mismatch names one protocol number | Accepted | "Compatibility", slice 2 |
| LOW | `git_identity.run` reads `worktree_diff.Wiring`; slice 1's exit passed without the slice | Accepted | "The seam", slice 1 |
| LOW | Tool payloads carry arguments, not results | Accepted | precondition 2 |
| LOW | Every 109 session on an untrusted pod also stored `Unavailable` | Accepted | "A baseline stored before the tunnel" |
| LOW | Refusal text stored unclipped; the real memory ceiling of buffered output | Accepted. Clipped to 512; buffering makes the ceiling the bytes | "Goal checks, the diff...", the buffer paragraph |
| LOW | The codec's size refusals, the record-before-reply ordering, a test naming a refusal as a run | Accepted | "Frames", "Authority on the executor", slice 3 |
| (slices) | Hook rules before the tunnel; the wire slice's gateway answers `BrokerUnavailable` | Accepted, then superseded for hooks by the re-check | "Slices" |
| Re-check, HIGH | A waiter killed for a `cancel` while linked takes the connection down, because a connection does not trap exits | Accepted. The gateway unlinks before it kills | "The executor side", slice 3 |
| Re-check | "The executor refuses a dispatch whose `events` owner is dead" is not in the code; the call is dispatched and then cancelled | Accepted | "The executor side" |
| Re-check | The link's wall timer is a backstop whose grace is below the relay's and the hook's kill grace | Accepted. Cut; the invariant that every caller bounds its wait and cancels replaces it | "What was considered", "A tunnelled call on the orchestrator" |
| Re-check | Wiring hooks ships an unexercised path and an unresolved `HOME` disclosure | Accepted. Hooks stay refused, with seven preconditions for a later change | "Hooks stay refused", decision 2 |
| Re-check | `bit_array.append` copies the buffer per chunk | Accepted. The buffer grows with a bit-array expression | the buffer paragraph |
| Re-check, LOW | `CallOutput` fields at settlement; the value count on the link's own sends; `waiting_ms` against the link's own wait | Accepted | "Frames", the table's refusals |
| Slice 3, MEDIUM | A spec root with a `..` segment survives the textual meet and the helper cleans it into more than the plane holds | Accepted. The executor refuses roots that are not plain absolute paths; `policy.validate` is a follow-up | "Authority on the executor" |
| Slice 3, MEDIUM | Executor-chosen refusal and failure text is stored at frame size in the peer view's fact, the board and a goal check's reason | Accepted. Clipped by bytes in `worktree_diff.error_message` and the goal check | "Goal checks, the diff, the baseline and the peer view" |
| Slice 3, MEDIUM (test) | The hook-refused test passed whichever function hooks were given | Accepted. It drives both arms over a recording clearing function | "Hooks stay refused" |
| Slice 3, LOW | A door replaced between lookup and send leaves an admitted call held for nobody | Accepted. The clearing function sends `Withdraw` when its door goes down | "Reaching the link" |
| Slice 3 re-check, MEDIUM | The plain-path test split by grapheme clusters, so a slash followed by a combining mark hid a `..` segment | Accepted. The test reads bytes | "Authority on the executor" |
| Slice 3 re-check, MEDIUM | The plain-path test also judged protected paths, mounts, the scratch and the working directory, which cannot widen and refused honest bases | Accepted. Only readable and writable roots are judged | "Authority on the executor" |

A third review, 2026-11-17, of the integrated slices 1 and 2
(c62d24f08..b5150d68f), read-only. Its verdict was merge as is; the follow-ups
below were taken before slice 3.

| Severity | Finding | Disposition | Where it landed |
|---|---|---|---|
| HIGH, pre-existing | A refused document costs tens of bytes of heap per byte consumed, because `codepoint_offset` builds the codepoint list of the prefix | Accepted. The offset counts non-continuation bytes and allocates nothing | `core/json` |
| MEDIUM, pre-existing | A duplicate-key refusal quotes the whole key | Accepted. Clipped to a 96-byte prefix cut at a codepoint boundary, with the key's size in bytes | `core/json` |
| MEDIUM | `sent_callback` checks neither frame bound, so an honest over-count callback closes the connection | Accepted. It sends with `encode_fitting`, fails its asker when the callback does not fit | `untrusted_gateway` |
| MEDIUM, pre-existing | Nested msgpack and JSON documents are decoded outside the value bound | Recorded, not closed | "Residual risks", "Bounds" |
| LOW | `wide_int_of` accepts an integer of any magnitude | Accepted. Magnitudes above 2^256 are refused | `untrusted_codec` |
| LOW | The argv, env and millisecond limits are private to the decoder | Accepted for slice 3 | slice 3 |
| LOW | A link test asserts staying open after an at-bound frame, which is no barrier | Accepted. The at-bound half is dropped; the over-bound wait is 30 seconds | `untrusted_link_test` |
| LOW | Slice 2's exit claims the full bound on both targets | Accepted. Amended to say what runs where | slice 2 |
