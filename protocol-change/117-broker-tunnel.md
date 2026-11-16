# protocol-change/117: the broker tunnel, so non-tool callers reach an untrusted executor

**Status**: PROPOSED 2026-11-16, revised the same day after one independent
adversarial review ("Review and disposition" below). Not built. It is accepted
under `docs/execution.md` section 7 once the owner has answered "Decisions for
the owner".
**Affects**: the untrusted executor wire of [109](109-untrusted-executors.md)
(`untrusted_wire.version` 4 to 5): one new request and its reply, one new
request with no reply, and one new frame from the executor. One new process
per untrusted executor on the orchestrator (the link's tunnel door). In
`client`, the non-tool callers of an executor's broker take a clearing
function in place of a `broker.Broker`, and imported hooks that run on an
untrusted executor are served under narrower rules. `core/json` gains a parse
that bounds the number of values. The remote node vocabulary of
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
broker to export a reading of its own actor protocol, including the congestion
epochs `clear_call` retries with, `QueryRelay` and the abort sweeps.

### Re-send tunnelled calls as runs are re-sent (rejected)

A `run` is re-sent after a dropped connection because the executor's host
admits it by key and joins the call already running. A broker call has no key,
and a hook or a goal check sent again would run again. A tunnelled call is sent
on one connection at most.

### Hold a `clear_call` for the next connection (rejected)

The link could keep a call made while it has no connection and send it after
the next welcome. A link with a live binding redials with a pause of at most two
seconds, so holding gains little, and while a guest is down every held hook
would stall its strand for its whole wait (up to 610 seconds for a hook), where
a trusted executor that is gone refuses at once.

### Negotiate the tunnel in `welcome` (rejected)

The executor could announce the tunnel as a flag, so an old executor serves
tools and refuses only the four callers. 109 refuses any version mismatch at the
handshake, 110 and 111 kept that rule, and a guest image is built from the same
release as the host.

### Reach the link through a weft registry address (rejected for now)

A `weft/registry` address would give the link a second typed subject without an
atom. The address is a reference, so it would have to travel from the registry
of 116 to `workspace.untrusted_candidate` with the row, as a new field on
`executors.Executor`. A second registered name follows the pattern the link
already uses (`name_for` (`client/remote/untrusted_link.gleam:417`)).

### Corrections to the design note

Section 5 of the design note is the starting point. Against the code:

- A remote session's non-tool callers hold
  `broker.over(owner_port.broker(port), executor_clock)`
  (`build` (`client/remote/workspace.gleam:669`), line 697), a relay the owner
  port retargets at every attach, not `broker.over(census.broker, ..)`.
- The executor side does not see the plane's broker subject when it encodes an
  attach reply. `untrusted_bridge.ask_host` projects the census onto the wire
  inside the waiter (`projected` (`client/remote/untrusted_bridge.gleam:1304`)),
  and the gateway's `answer` (`client/remote/untrusted_gateway.gleam:643`) gets
  a `Response` with the subject already dropped.
- The seam cannot be the two-argument `tool.broker_runner` shape, which fixes
  the clearance wait when it is built; `hookrunner.run` and `run_git` choose a
  different wait for every call. The peer view and `git_identity.run`
  (`client/git_identity.gleam:419`) use `worktree_diff.Wiring`, so two types
  change.
- A hook's `allow` already skips nothing. `ToolPermission`
  (`client/hookdecisions.gleam:95`) maps `allow` to `Proceed`, and
  `hookserve.cleared` (`client/hookserve.gleam:1050`) asks hooks only after the
  harness has cleared the call. What a guest's hooks add is described under
  "Hooks on an untrusted executor".
- A session that stored `Unavailable` keeps a Changes tab once the tunnel lands.
  Its working tree is observed afresh on every request; only the commits since
  the session started stay unavailable, because `capture_committed`
  (`client/worktree_diff.gleam:412`) shows the stored reason in their place.
- The note gives the clearing function no way to reach the link, which
  `executors.reload` can replace at any time.
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
untrusted placement sets it to `untrusted_link.tunnel(executor, session)`.
`WorkspacePlane.broker` stays for the code that holds a broker actor for other
reasons; on an untrusted placement it is the refusing relay it is today.

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
| `call_stdin` request | orchestrator | `call` (the `clear_call`'s request id), `data` (base64), `eof` | none |
| `cancel` frame, existing | orchestrator | `id`; kills the waiter, as for a `run` | none |
| `call_event` frame, new | executor | `call`, `event`: `output {stream, data}` or `settled {outcome}` | none |

The wire's spec carries `op_id`, `step_id`, `base_policy`, `requirements`,
`response`, `argv`, `env`, `cwd` and `budget` (`max_outstanding`,
`deadline_ms`). It carries no `grants` and no `demand`, which the executor
takes from nowhere but itself ("Authority on the executor"). `outcome` is
`exited {result}` with the whole `ExecResult`, or `failed {failure}` with every
`ExecFailure` variant. Policies use the codec's existing `encode_sandbox_policy`
(`client/remote/untrusted_codec.gleam:1642`), and a `PolicyRefused` refusal
reuses `decode_denial` (`client/remote/untrusted_codec.gleam:2715`). The codec
refuses a `waiting_ms` or a `deadline_ms` outside 0 to 2^53, an `argv` of more
than 4,096 entries, and an `env` of more than 1,024 pairs, as 109's codec
refuses absurd sizes.

An `output` event carries no `truncated` and no `total_bytes`. The tunnel
waiter forwards no chunk with no bytes: the helper sends one when a stream's
admitted bytes reach its cap exactly and the child writes more (`pump`
(`internal/jail/run.go:668`)), and that chunk says only that truncation began.
Truncation reaches the callers through the outcome: `hookrunner.settled`
(`client/hookrunner.gleam:339`) and `worktree_diff.settled` read
`ExecResult.stdout_truncated` and `stderr_truncated` beside the collector's
flags, and the goal check keeps a tail and reads no truncation at all.

`cancel` keeps its one 109 meaning, for a `clear_call` as for a `run`: the
gateway kills the request's waiter. The dispatcher watches the owner of every
call's `events` subject and cancels the execution when it dies (`caller`
(`broker/dispatch.gleam:190`)), and the tunnel waiter is that owner. No caller
waits for the executor's account of a cancelled call: `hookrunner.run` returns
`NeverSettled` after its cancel, `run_git` returns `NoSettlement`, and the goal
check records "did not settle". `call_stdin` and `cancel` go out only on an open
connection, like `ack`.

### A tunnelled call on the orchestrator

The link keeps tunnelled calls in a table of their own, by request id, never in
`outstanding`, so 109's re-send never sees them. A call counts as sent when the
link calls `send` for its frame, whatever `send` returns. An entry is `Clearing`
from its send until `cleared(Ok)`, and `Running` from then until it is removed.

The link answers a `Clear` at once, and sends nothing, when its connection is
not open, when the session holds no binding on this link (a link started in
place of another, 116), when the spec carries grants, when its output or wall
limit is zero, or its output limit is above `max_call_output_bytes` (1 MiB, the
hooks' and the goal check's own cap), and when the binding already has 8 entries
or the link 64. Each is `Error(BrokerUnavailable)` and is logged; no caller in
the tree sends a spec the link refuses for its shape.

Every ordering ends in one stated outcome:

| What happens | Entry | Asker hears | Frame sent |
|---|---|---|---|
| `cleared(Ok)` while `Clearing` | becomes `Running` | `Ok(RunningCall)` | none |
| `cleared(Error(r))` while `Clearing` | removed | `Error(r)` | none |
| `waiting` passes while `Clearing` | removed | `Error(BrokerUnavailable)` | `cancel` |
| `Withdraw(reply)` (case (e) of the review) | removed if held | nothing more | `cancel` if held |
| `call_event output` while `Running` | stays | nothing yet; the bytes are buffered | none |
| `call_event settled` while `Running` | removed | one `CallOutput` per stream with bytes, then `CallSettled` | none |
| `RunningCall.cancel()` | removed | `CallSettled(CallFailed(ExecutionLost(RelayDown)))` | `cancel` |
| the asker dies | removed | nobody | `cancel` |
| the wall timer fires while `Running` | removed | `CallSettled(CallFailed(ExecutionLost(RelayDown)))` | `cancel` |
| the connection drops | removed | `Error(BrokerUnavailable)` if `Clearing`, `CallSettled(CallFailed(ExecutionLost(RelayDown)))` if `Running` | none |
| `cleared` or `call_event` for an id the link issued and no longer holds | none | nothing | none (dropped) |
| `cleared` while `Running`, `call_event` while `Clearing`, either for an id never issued or held as another kind of request | none | as for a dropped connection, for every entry | violation, closes the connection |

The dropped-frame rule is 109's for responses (`responded`
(`client/remote/untrusted_link.gleam:1178`)): an id from 1 up to `next_id` was
issued, so a frame for it that the link no longer holds crossed a removal. A
second `settled` is therefore dropped, not a violation.

`ExecutionLost` (`broker/exec.gleam:337`) is the one failure that says the
effect may have run and must not be replayed; its `RelayDown` cause is the link
standing where a relay would stand.

The wall timer starts at `cleared(Ok)` and runs for the spec's
`requirements.limits.wall_s` plus `tunnel_grace_ms` (3 s). It is placed in the
link rather than in the three collectors because the link is the one place every
tunnelled call passes, and it holds whatever a caller's wait does. The callers'
waits are idle windows that each `output` would renew (`collect_events`
(`tools/tool.gleam:1272`)); with output buffered to the settlement and the
timer in the link, a hostile executor holds an entry for at most its wall and
three seconds. Three seconds is below the smallest caller grace
(`worktree_diff.settlement_grace_ms`, five seconds), so the timer fires before
any caller gives up.

The link buffers a `Running` call's output per stream, appending each chunk to
one binary, and hands it to the caller only at settlement. The four callers
fold output into a result and show none of it while the call runs, so nothing
they do changes. The memory the link holds for tunnelled output is the bytes
themselves, at most 64 entries of two 1 MiB streams, rather than one message per
chunk in each caller's mailbox, which a stream of one-byte chunks would make
tens of times larger.

A link that dies, or is replaced by `executors.reload`, settles nothing. Its
callers' waits end because no event arrives (`hookrunner.NeverSettled`,
`NoSettlement`, the goal check's "did not settle"), and the executor cancels
the children when the connection closes.

### The executor side

Each `clear_call` runs in a tunnel waiter: a process that owns the `events`
subject the broker is given, clears with `broker.over` on the recorded broker
subject, writes stdin as `call_stdin` requests arrive, and forwards each
non-empty chunk and the settlement as `call_event` frames. Its `cleared` reply
reaches the connection before its first event, because both are messages from
the waiter to the connection.

The waiter is linked to its connection, and every path by which a connection
stops (`closed` (`client/remote/untrusted_gateway.gleam:814`), an ended or
broken socket) kills the connection's tunnel waiters first, because a normal
stop does not propagate through a link. A waiter killed inside
`broker.clear_call`, which waits out a congested pool in the caller's own
process, dies at once. If the broker had already dispatched, the dispatcher's
watch cancels the child; if not, the executor refuses a dispatch whose `events`
owner is dead. This is the reverse of a `run`'s waiter, which outlives its
connection so that the call's outcome reaches the ledger for the re-send.

Over the tunnel, `BrokerUnavailable` does not prove that the command never
started: a call killed with its connection, or withdrawn while clearing, may
have started and been cancelled. No caller re-runs on that refusal.
`goalcheck.admitted` (`client/goalcheck.gleam:279`) retries only
`OutstandingCapReached`, and `hookrunner` and `run_git` report the refusal.

### Bounds on what an executor sends

A violation is logged and closes the connection. The tunnelled entries end as
for a dropped connection, and runs and requests are re-sent as 109 describes.

| An executor sends | Response |
|---|---|
| a frame over `max_frame_bytes` | the socket refuses it (109) |
| a frame whose JSON holds more than `max_frame_values` (1,048,576) values | violation |
| more `output` bytes on one stream than the spec's `requirements.limits.output_bytes` | violation |
| an event or a `cleared` the table above calls a violation | violation |

`max_frame_values` is the bound for 109's decoded-breadth risk (finding F5 of
the design note). It applies to every frame through `decode_envelope`
(`client/remote/untrusted_codec.gleam:225`) and to a fetched outcome through
`decode_outcome_bytes` (`client/remote/untrusted_codec.gleam:279`), which reads
up to `max_outcome_bytes` (96 MiB) inside the link. A fetched outcome that the
bounded parse refuses is answered to its asker as lost (`fetched`
(`client/remote/untrusted_link.gleam:1403`)), which is no violation. An honest
gateway counts a response's values where `replied`
(`client/remote/untrusted_gateway.gleam:760`) checks `fits`, and sends a
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

### Hooks on an untrusted executor

A hook that runs on an untrusted executor answers whatever the executor wants:
its settings bytes are checked against the trust record on the orchestrator,
but the script a hook command runs is in the executor's workspace and the
outcome comes back over the link. `hookrunner.Context` gains `site`, `Here` or
`Tunnelled`, which `with_imported_hooks` sets from the placement, and
`hookserve` serves a `Tunnelled` context under these rules.

1. **No user-level source.** `hookserve.gather` reads `~/.claude/settings.json`
   on the orchestrator, and `first_sight` (`client/hookserve.gleam:498`) trusts
   it with no record. Served through the tunnel, each of its commands would be
   sent to the executor as the spec's `argv` (`["sh", "-c", command]`, so any
   URL or token written inline in a command), with `HOME` naming the operator's
   home (`hook_environment` (`client/serve.gleam:402`)) and the orchestrator's
   `transcript_path` in every payload; the scripts those commands name are not on
   the guest, so the hooks cannot work there. A `Tunnelled` context serves no
   `UserSettings` source and logs one line naming the file it skipped.
2. **A hook sees only the executor's tools.** `hookserve.tool_gate`
   (`client/hookserve.gleam:551`) and `hookserve.tool_feedback`
   (`client/hookserve.gleam:666`) ask no tunnelled hook about a call whose tool
   is not in `tool_placement.workspace_names`. A `PreToolUse` or `PostToolUse`
   payload otherwise sends the executor the arguments of calls that ran on the
   orchestrator (notes, peer messages), which 109 never sends, and a guard on
   such a tool protects nothing when the executor writes its verdict.
3. **No rewrite.** In `hookserve.cleared`, a `Rewrite` from a tunnelled hook is a
   refusal naming the hook, not a call to `recleared`
   (`client/hookserve.gleam:1117`). A second clearance on guest-chosen arguments
   can reach an operator's approval prompt, and 109 rules out asking the
   operator about a call with arguments the executor describes.
4. **No compaction note.** `compaction_note` (`client/hookserve.gleam:705`)
   returns `None` for a tunnelled hook. The note is placed at the end of the
   summarizer's input without a fence, and the summary then replaces history
   durably, so executor text would outlive the compaction as the session's own
   account of itself.
5. **Bounded text.** A tunnelled `Stop` continuation's reason, an `Ask` reason
   and a `PostToolUse` context pass through `hookdecisions.capped`
   (`client/hookdecisions.gleam:519`), 10,000 characters, as a deny, feedback
   and an injection already do. The cap is applied in `hookserve` for a
   tunnelled context only, so a local hook's text is unchanged.

What remains is accepted. A deny, an exit 2 or an `ask` refuses one call, which
is denial of service. `updatedToolOutput` changes the result of a call the
executor ran anyway. `SessionStart` context reaches the model as untrusted text,
as the census's guidance files do. A `Stop` continuation costs a model turn on
the orchestrator's provider key and is capped at `stop_block_cap`
(`client/hookserve.gleam:745`), eight per operation. A hook refused for a bound,
or lost to a dropped connection, gives no decision, as a hook whose clearance
fails on a local plane does today.

**What runs in practice.** With rule 1, the sources a tunnelled session can
serve are the project's two settings files, and `first_sight` serves those only
with a trust record, which no command writes yet. `LoomInline` has no loader
that produces entries, and plugins are not located. So when the tunnel lands, no
hook runs through it unless an operator writes a trust record by hand; the hook
work in the slices below makes the tunnel safe for the day a trust command
exists, and delivers no hook a user can run before then.

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

### Compatibility

A version 4 executor and a version 5 orchestrator, or the reverse, refuse each
other at the handshake, and every session on that executor is refused, tools
included. Today the link reads only the peer's `protocol.version` from a
mismatched `welcome` and refuses with `VersionMismatch(supported: theirs)`
(`greeted` (`client/remote/untrusted_link.gleam:1077`)), whose text names
protocol versions; on a wire-only mismatch it reads "the executor speaks
protocol version 7 and this orchestrator does not". The wire slice logs both
wire and both protocol numbers at every mismatch, and when the protocol numbers
agree it refuses with `Unreachable` naming both wire numbers.

`loom vm up` replaces a guest root built from other artifacts than the host's
manifest in place (`root_step` (`client/vm_spec.gleam:1161`)), so the next `up`
or `ensure` after a release removes the mismatch; under a `dev` manifest the
root is kept and `up --fresh` is the remedy. A pod deployment upgrades its
orchestrator and its executors together.

## Threat model

Everything in 109's threat model stands. This proposal adds, for the sessions
placed on a hostile executor:

**What it can do.** Return any outcome for a tunnelled call; answer every hook
about its own tools as it likes (deny, context and continuations within the
cap, a rewritten result); report a false goal check, a false worktree board, a
false baseline and a false peer view; hold an entry until the clearance wait
passes or, once cleared, for the spec's wall and three seconds, which with 8
entries per binding refuses that session's later hooks and observations for as
long.

**What it cannot do.** Start a call: only the orchestrator sends `clear_call`.
Run a call twice: nothing is re-sent. Keep a child running after the
orchestrator's connection is gone, in a compliant gateway; a hostile one can
keep its own processes running in any case. Widen the plane's base policy or
add a grant through a spec. Deliver more output than the orchestrator's cap, or
make the link hold more than those bytes. Hold an entry past the link's wall
timer. Receive the operator's user-level hook commands or home path, see the
arguments of a call that ran on the orchestrator, rewrite any call, or place a
compaction note. Make a frame or a fetched outcome decode to more than
`max_frame_values` values.

**Residual risks.**

- The executor sees the hook payloads of its own tools (their arguments, the
  session id, the orchestrator's transcript path), the goal check command and
  the Git commands. All but the transcript path describe work it already holds;
  the path is a file name on the orchestrator and grants nothing.
- A hook's verdicts about the executor's own tools carry no assurance. An
  operator who relies on a `PreToolUse` guard must not rely on it for a session
  on an untrusted executor.

## What it costs

About 1,900 lines of product code and 1,000 of tests: the seam (about 170, with
`git_identity`), the codec (about 520, most of it `ExecResult`, `ExecFailure`
and `broker.Refusal`), the link's tunnel table, door, buffer and wall timer
(about 450), the gateway's waiter and the book's record (about 320), the hook
rules (about 120), the value bound in `core/json` and its two uses (about 80),
and the bridge's attach change.

Each executor costs a second process and a second atom. Each output chunk costs
a frame, and a hook's payload crosses the link as stdin, grown by a third as
base64. On an untrusted executor, user-level hooks do not run, hooks see only
the executor's tools and cannot rewrite a call or note a compaction. A version
4 executor and a version 5 orchestrator no longer work together.

### Not carried after this

- Remote evolution (109's slice 4). The link still sets the census to
  `Uncompiled`.
- The executor's node report of 085, which the machines view asks over
  distribution.
- `broker.abort` and `abort_step` through the plane's `broker`. Hooks and goal
  checks clear under attribution-only operations that nothing aborts.
- Project hooks in practice, until a command writes trust records.
- The 109 residual risk of a remembered "for this session" grant from an
  escalation over the link.

## Slices

Each slice lands alone, in this order, and each exit is a check that fails
without the slice. The default flip of the design note's slice 4 waits for
slice 5.

1. **The seam.** `workspace_plane.ClearCall`, `WorkspacePlane.clear_call`, and
   `hookrunner.Context`, `worktree_diff.Wiring` and `git_identity.run` taking
   it. **Exit**: a new case in `hookrunner_test` and one in `worktree_diff_test`
   drive the caller through a fake `ClearCall` that records the spec and answers
   a scripted settlement, and `git_identity`'s test runs unchanged in substance;
   `make check` is green.
2. **The hook rules.** `hookrunner.Context.site` and the five rules in
   `hookserve`, pure and reached only by a `Tunnelled` context, which nothing
   in production builds yet. **Exit**: `hookserve_test`, with a constructed
   `Tunnelled` context, shows a `UserSettings` source skipped with its log line,
   a tunnelled hook not asked about a tool outside `workspace_names`, a
   tunnelled `Rewrite` refused without a second clearance, no compaction note,
   and a 20,000-character `Stop` reason capped; and a `Here` context still
   rewrites and keeps its text uncapped.
3. **Wire 5, the codec and the value bound.** The new items in
   `untrusted_wire`, their codec, the bounded parse in `core/json` used by
   `decode_envelope` and `decode_outcome_bytes`, the gateway's value count
   beside `fits`, and the version mismatch's log and refusal text. Its gateway
   answers every `clear_call` with `cleared(Error(BrokerUnavailable))` until
   slice 4 lands. **Exit**: `remote/untrusted_codec_test` round-trips every new
   item and every `ExecFailure` and `broker.Refusal` variant, refuses a spec
   with a `grants` member and each oversized field, and extends the kind
   matrices so only the diagonal decodes; `core/json_test` parses a document of
   `max_frame_values` values and refuses one more, on both targets;
   `remote/untrusted_link_test` refuses a 1,048,577-value frame and answers a
   fetched outcome over the bound as lost, and its wire-only mismatch names both
   wire numbers; `remote/untrusted_gateway_test` answers a `clear_call` with
   `BrokerUnavailable`.
4. **The tunnel.** The door and `untrusted_link.tunnel`, the call table, buffer
   and wall timer, the gateway's waiter and the book's record, and
   `workspace.build` setting `clear_call` for an untrusted placement. Goal
   checks, Git and hooks (under slice 2's rules) all reach it. **Exit**:
   `remote/untrusted_link_test` has the hostile executor send events for an id
   never issued, for a `run`'s id, for a call still `Clearing`, a `cleared` for
   a `Running` call, and output past the cap, each closing the connection while
   the link survives and a `Running` asker hears `ExecutionLost(RelayDown)`; it
   drops a late `cleared` and a second `settled` without a violation; it drops
   the connection under a `Running` and a `Clearing` call and asserts nothing is
   re-sent; it never settles a call and asserts the wall timer settles it lost
   at wall plus three seconds; it kills an asker, cancels, and withdraws, each
   sending one `cancel`; it refuses a `Clear` with no connection, with no
   binding, and a ninth on one binding. `remote/untrusted_gateway_test` with a
   real broker and helper: a dropped connection cancels the child, including one
   whose waiter is still clearing against a full pool; `cancel` kills the
   waiter; a command printing past its cap settles with
   `ExecResult.stdout_truncated` set and no violation; a plane whose base holds
   a writable-only root runs a `read_policy` Git call; a spec whose base is
   wider than the plane's, sent with `ProceedNarrowed`, runs under the plane's
   base; a binding the orchestrator does not hold is refused.
   `remote/untrusted_end_to_end_test` runs a goal check, a baseline probe, a
   worktree diff after a jailed edit, a peer observation, and a project hook
   under a trust record the test writes, through the link into a real plane.
5. **The microVM step and the record.** A step of `daemon_shipped_microvm_test`
   on a guest made with `--link untrusted`: the session's baseline is a
   revision, a jailed `bash` edit shows in the Changes tab against it, and a
   goal check passes. A pointer addendum on 109, and the "Untrusted executors"
   section of `packages/client/CLAUDE.md`. **Exit**: the step passes on a host
   with the microVM tier and fails on the tree before slice 4; `make doc-check`
   passes.

## Decisions for the owner

1. **Is a version 4 executor refused outright, rather than served without the
   tunnel?** Recommendation: refuse. Refused, a stale guest's sessions do not
   open until `loom vm up` upgrades its root; served, they open with tools and
   without a Changes tab, goal checks or hooks.
2. **Does a session on an untrusted executor serve no user-level hook source?**
   Recommendation: serve none, with one logged line. Either way the operator's
   `~/.claude` hooks do not work in a `--vm` session; served, their command
   strings and home path are also sent to the guest.
3. **Do hooks on an untrusted executor see only the executor's tools?**
   Recommendation: yes. A user's `PreToolUse` or `PostToolUse` hook on a tool
   that runs on the host does not fire in such a session; otherwise it fires,
   with an answer the guest writes.
4. **Is a tunnelled `Rewrite` refused, rather than read as `Proceed`?**
   Recommendation: refuse. The user sees the call refused with the hook named;
   read as `Proceed`, the call runs with its unrewritten arguments and no
   message.
5. **Is a tunnelled `PreCompact` note dropped?** Recommendation: drop it. The
   compaction summary of such a session lacks the hook's note; kept, guest text
   becomes part of the session's durable history.
6. **Does a session that stored `Unavailable` keep it?** Recommendation: keep
   it. Such a session's Changes tab shows its working tree and, in place of its
   commits, the stored reason; probed again, it shows commits since the moment
   of the probe as if the session had started then.
7. **Are the hook rules and the hook wiring built now, with the tunnel, though
   no hook runs through it until a trust command exists?** Recommendation:
   build them now. The rules are about 120 lines of pure code, and the tunnel
   reaches hooks through the same seam as everything else, so leaving hooks out
   needs a branch of its own to keep them refused and a second change to remove
   it. Users see no difference until a trust command lands; deferred, hooks in a
   `--vm` session stay refused after it lands, until this work is done.

## Review and disposition

One independent, read-only adversarial review, 2026-11-16, of the first draft
against the code at 206f18fa8, reporting findings only. Each finding was checked
in the code before it was taken; the two HIGH findings were also checked
separately by the coordinator of the work.

| Severity | Finding | Disposition | Where it landed |
|---|---|---|---|
| HIGH | An honest helper sends an empty chunk with `truncated` when a stream reaches its cap exactly (`pump`), which the draft called a violation; `truncated` was dropped without saying what is delivered | Accepted. The waiter forwards no empty chunk, `truncated` and `total_bytes` are not carried, callers read truncation from the result; the empty-chunk rule is removed | "Frames", "Bounds", slice 4's gateway test |
| HIGH | User-level hook commands, the operator's home and the transcript path would be sent to the executor (`first_sight` trusts `UserSettings` with no record) | Accepted with change: rule 1, a decision, and a statement of which sources can run in practice | "Hooks on an untrusted executor", decisions 2 and 7 |
| MEDIUM | The meet against the plane's base drops writable-only roots for `read_policy` specs | Accepted. The meet is taken against the plane's base with writable roots counted readable | "Authority on the executor", slice 4 |
| MEDIUM | The state table left orderings open: a late `cleared`, a held call that never sent, cancel while clearing, an unbound session, the function's own wait ending | Accepted with change. `Withdrawn` and holding are cut, issued-and-gone frames are dropped, an unbound session is refused, and `Withdraw` closes the last case; every ordering has one row | "A tunnelled call on the orchestrator" |
| MEDIUM (simplify) | `cancel` with two meanings | Accepted. No caller waits for the executor's account after a cancel, so `cancel` kills the waiter and the link delivers `ExecutionLost(RelayDown)` | "Frames", the table |
| MEDIUM (simplify) | Holding a `clear_call` for the next connection | Accepted. Refused unless the connection is open; "sent" defined | "What was considered", the table |
| MEDIUM | A waiter blocked in `clear_call` cannot see its connection drop; `BrokerUnavailable` may follow a start | Accepted. The waiter is linked and killed with its connection, and the text says what the refusal does not prove; no caller re-runs on it | "The executor side" |
| MEDIUM | Callers' waits are idle windows a hostile executor renews with one-byte chunks | Accepted with change. A wall timer in the link, and output buffered to settlement, which also removes the per-chunk memory cost | "A tunnelled call on the orchestrator", decision 7 of the draft removed |
| MEDIUM | F5 is not bounded for a fetched outcome, and an honest response over the bound would loop on re-send | Accepted. The bounded parse covers `decode_outcome_bytes`, and the gateway sends an over-count response as `Oversized` | "Bounds" |
| MEDIUM | The hook enumeration omits `PreCompact`, and `Stop`, `Ask` and context text are uncapped | Accepted. Rules 4 and 5, capped for tunnelled hooks only | "Hooks on an untrusted executor", decision 5 |
| MEDIUM | The version mismatch names one protocol number, not the wire numbers | Accepted. The sentence states what the code does, and slice 3 logs and names both wire numbers | "Compatibility", slice 3 |
| LOW | `git_identity.run` is a third reader of `worktree_diff.Wiring`; slice 1's exit passed without the slice | Accepted | "The seam", slice 1 |
| LOW | Tool payloads carry arguments, not results | Accepted | rule 2 |
| LOW | Every 109 session on an untrusted pod also stored `Unavailable` | Accepted | "A baseline stored before the tunnel" |
| LOW | Refusal text stored unclipped in `session/git-start`; the real memory ceiling of buffered output | Accepted. Clipped to 512; buffering in the link makes the ceiling the bytes | "Goal checks, the diff...", "A tunnelled call on the orchestrator" |
| LOW | The codec's size refusals, the record-before-reply ordering, and a test that named a refusal as a run | Accepted | "Frames", "Authority on the executor", slice 4 |
| (slices) | Hook rules before the tunnel; the wire slice's gateway answers `BrokerUnavailable` | Accepted | "Slices" |
