# Reaching microVM guests over the untrusted link

**Status**: proposal, 2026-11-13. It needs the owner's ruling, because it
supersedes the link that ADR-022's first 2026-11-01 addendum settled (the
orchestrator dials the guest executor over TLS Erlang distribution) and the
owner's 2026-11-01 ruling in the developer-path addendum that the local daemon
becomes a loopback-bound distribution member. Nothing here is built.
**Builds on**: ADR-022 and its addenda, protocol-change/106 (the loopback
listener), 109 (untrusted executors), 110 (placed blobs and large outcomes),
111 (the host code-mode seam).
**Keeps**: the one-flag product surface the owner ruled on 2026-11-13: `loom
--vm` sets up, boots or resumes the workspace's guest and opens the session in
it, one guest per workspace, each guest a standing `loom-vm run` process outside
the daemon.

## Summary

A guest started by `loom vm up` is today a trusted Erlang distribution peer of
the host daemon. Whoever controls the guest's `loom` user can run code in the
host daemon as the developer. This note proposes that `loom vm up` (and the
`ensure` verb under `loom --vm`) reach the guest over protocol-change/109's
untrusted link instead: the guest daemon gets `[executor_listener]` and no
`[distribution]`, the host daemon gets `[executor_link]` once and one
`[executors.<name>] trust = "untrusted"` row per guest, and no cookie, ledger,
authority key or epmd entry is involved.

The link as built carries tool calls, foreground and background code mode,
state transport, placed blobs and every owner callback. It does not carry the
commands that non-tool callers run through the executor's broker: the Changes
tab and the session's Git baseline, goal checks, project hooks and the peer
view of the worktree. Those are 109's unbuilt slice 3, sized below at about
2,400 lines with tests. Because the session's Git baseline is probed once, at
the first open, and stored, a guest session opened before slice 3 lands keeps
no baseline for its life. The plan therefore lands slice 3 before the
untrusted link becomes the default.

Two further pieces are needed that 109 did not have to build: a running daemon
learning about a new guest without a restart (an owner-only `executors.reload`
control command, protocol-change/115), and a stable address per guest (a
loopback port reserved once and recorded beside the guest).

## 1. Threat model

### What each party holds today

| Party | Runs as | Holds |
|---|---|---|
| Host daemon (`loomd`) | developer | provider keys, every session store, the hook trust record, approvals, clearance; its `[distribution]` key and the home's `.erlang.cookie`; in a minted guest's deployment, the orchestrator bundle under `<vm home>/<name>/orch/` |
| `loom-vm` launcher | developer | the libkrun VMM, the hosted network stack and its egress policy, the GitHub credential proxy with the developer's token in memory, the host loopback forward and the guest's epmd registration (`--publish`) |
| Guest `loomd` | `loom` in the guest | the executor's TLS key and certificate, the CA certificate and the cookie, staged at `/srv/loom-node/creds/{cert,key}.pem` and `/srv/loom-node/home/.erlang.cookie` (`client/vm_cli.gleam:2830` (`stage_node`)); the ledger file in ledger mode; the workspace copies; the state disk |
| Jailed tool process | `loom`, under `loom-exec` | the workspace copy, the network the policy allows (with GitHub access, the proxy's placeholder token); the node key and cookie are masked by `node_credentials` (`client/executor_plane.gleam:323`) |

### What each party holds under the proposal

| Party | Holds |
|---|---|
| Host daemon | as today, minus any `[distribution]` table the guest put there; plus the link CA, the orchestrator's link leaf and key under `<vm home>/link/` |
| `loom-vm` launcher | as today, with `--forward HOST:GUEST` in place of `--publish`, so no epmd registration |
| Guest `loomd` | its link leaf and key, the CA certificate, the orchestrator's pin in `[executor_listener].orchestrators`; no cookie, no `[distribution]`, no ledger |
| Jailed tool process | as today; the link key must be masked too (finding F1 below) |

### What each attacker position reaches

| Attacker | Today | Under the proposal |
|---|---|---|
| (a) Model code in the guest's jail | The workspace, the allowed network, and with GitHub access on, authenticated GitHub requests through the proxy with the developer's token. The cookie and node key are masked. Reaching more needs a jail escape to (b). | The same. The link key is not masked as built (F1); with it masked, nothing new. |
| (b) The `loom` user in the guest, outside the jail | Everything below. It owns the cookie and key files (`loom-guest-executor` chowns the node directory to `loom`). The orchestrator dials the guest's forwarded port, and a distribution connection is symmetric once up: the guest node, or a replacement node the attacker starts with the same name, cookie and certificate, can `rpc:call` the host daemon. The verification of 2026-11-13 showed that the three staged files alone are enough: a plain `erl` node holding them got the host user's name back from `rpc:call(Orch, os, cmd, ["id -un"])`. Result: code on the host as the developer. | 109's "What it can do" list, for the sessions placed on that guest only: return any outcome, read every call's arguments and stored authority, read the operator's Git identity and the MCP façades, make the binding's callbacks within `admitted`'s checks, launch background programs during a `code_mode` call, deny service. No code on the host: no distribution connection exists and the frames are JSON decoded totally. |
| (c) Guest root or a guest kernel exploit | Everything (b) has, plus the VMM's device surface: the virtio-fs root share, virtio-net into the hosted stack, the state disk. An escape lands in the `loom-vm` process as the developer (ADR-022, Consequences). | Unchanged VMM surface. The host daemon's exposure becomes OTP `ssl` and `core/json.parse` on frames the guest sends, instead of the distribution protocol. |

The link removes the path from (b) to the host daemon. It does not change the
VMM surface of (c), which is ADR-022's accepted cost of libkrun, and it does not
change what the GitHub proxy grants: any guest process that reaches the proxy
uses the developer's token for the GitHub hosts, by the owner's ruling in the
developer-path addendum.

### What a hostile executor can still do to the orchestrator under 109

The link's checks are in `client/remote/untrusted_link.gleam:1576` (`admitted`):
the binding must be one this link minted and has not retired, the id must be
fresh, and the callback must be about work the link is carrying
(`client/remote/untrusted_link.gleam:1649` (`about_work`)). An escalation must
describe a `run` in flight exactly, arguments included. A capability or
`Holds` must sit at a `run` or an outstanding background `start`. A launch and
an interaction need a `code_mode` run in flight. Host-seam capabilities need
the session's `code_mode` call in flight specifically
(`client/remote/untrusted_link.gleam:1618` (`from_a_program`)). Facts, notices,
wakes, strand activity, the MCP plan and the Git identity need only the binding
(`client/remote/untrusted_link.gleam:1721` (`McpPlanCall`)), because background
jobs send them after their call ended; the owner port fences them to the
session's reserved fact prefixes. Bounds are 64 callbacks per binding and 1024
per link.

So a hostile guest can, for its own sessions: write the reserved facts, notify
and wake the session's strands at any time, and, while a `code_mode` call or a
background program of the session is live, call `strand.*`, `notes.*`,
`schedule.*` and `peer.*` as that strand, which includes reading the strand's
notes and sending peer messages. The residual risks 109 lists apply unchanged,
and two matter more here than for a review pod, because the orchestrator is
the developer's own daemon holding every session:

- One 32 MiB frame of small integers decodes to several hundred megabytes of
  terms (109, "One frame's decoded size"), and the decoder bounds no count.
- A grant an operator approves "for this session" after an escalation from the
  guest is remembered on the orchestrator and applies to the session's later
  calls wherever they run (109, "The grant an escalation asks for is the
  executor's").

### What the orchestrator sends the guest

| Sent | When |
|---|---|
| Each call's `ToolRun` (tool name, arguments) and its stored `Authority` (directory additions, standing grants) | every `run` |
| Session id, workspace name, incarnation, attach token, binding | every attach |
| The commit author's name and email | `AskGitIdentity` |
| The MCP façades and the host seam's plan | `AskMcpPlan` |
| Reserved fact values, notices' answers, capability outcomes (notes content, peer replies) | callback answers |
| Repository states and placed blobs | when the orchestrator moves a state or places a blob (107, 110) |

Never sent: provider keys, the session store, the system prompt, the
conversation outside tool arguments, the hook trust record, approvals,
clearance.

### Is anything in the guest still a secret?

Only the guest's link key, and it is worth little. With it an attacker can
answer as the guest to an orchestrator that dials it, but the host daemon
dials `127.0.0.1:<port>` on the host, which guest processes cannot bind. It
should still be masked from the jail (F1) because the cost is one list entry
and a pod deployment of 109, where the address is a network name, gains more
from it. The workspace copy is what model code works on anyway, and the
GitHub token never enters the guest.

## 2. Feature parity

The table is derived from the code: what the link carries is `untrusted_wire`'s
`Request` and `Callback` types, and what it refuses comes from the refusing
broker the link puts in the census
(`client/remote/untrusted_link.gleam:552` (`refusing_broker`)), which every
non-tool caller reaches through `broker.over`
(`client/remote/workspace.gleam:691` (`broker.over`)), and from the evolution
census the link sets to `Uncompiled`.

| Capability | Today, over distribution | Over the untrusted link as built | Missing |
|---|---|---|---|
| `fs_*`, `bash`, search tools, `lsp_*` tools | works (`Run`) | works (`RunRequest`) | nothing |
| Code mode, foreground | works | works: `run` plus capability callbacks; host modules through 111's seam | nothing |
| Code mode, background programs | works | works (109 slice 2: `StartExecutionRequest`, launch and interact callbacks) | nothing |
| `cap/lsp`, `cap/search` inside a program | works (in the executor's satellite) | works; `untrusted_host_codemode_test` drives both | nothing |
| Background jobs and their notices | works | works: `NotifyCall`, `WakeCall`, `StrandActivityCall` need only the binding; `live_jobs` reads the orchestrator's own store | nothing |
| MCP, orchestrator-run servers | works | works: `McpPlanCall`, then capability callbacks during a program | nothing |
| MCP, the guest's own `[mcp.<name>]` | works | works (the census's `mcp` statuses cross) | nothing |
| Extensions discovered in the workspace | not offered for a remote workspace (`client/serve.gleam:4367` (`There`)) | same | same as today |
| Extensions' owner-bound calls | works | works (capability callbacks under `about_work`) | nothing |
| Project hooks | works: `hookrunner` clears each command through the census broker (`clear_call` at `client/hookrunner.gleam:250`, wired by `hookrunner.Context` at `client/serve.gleam:299`) | refused: every hook run is `RunError.Refused` | slice 3 |
| Goal checks | works (`client/serve.gleam:6924` (`goal_check_wiring`)) | refused | slice 3 |
| Changes tab (worktree diff) | works (`client/serve.gleam:4746` (`observe_worktree`)) | refused; the tab shows the broker's refusal | slice 3 |
| Session Git baseline | works: probed once at the first open (`client/serve.gleam:4735` (`prepare`)) | probed through the refusing broker and stored as `Unavailable` for the session's life (`start` at `client/session_git.gleam:59`, `starting_revision` at `client/worktree_diff.gleam:298`) | slice 3, and a session opened before it never recovers its baseline |
| Peer view of the worktree (multiplayer) | works (`worktree_diff.peer_observation`) | refused | slice 3 |
| Agent spawn, `fresh` or `my_conversation` | works (orchestrator side) | works | nothing |
| Agent spawn, `my_workspace` | refused for any workspace on an executor (`client/serve.gleam:3499` (`remote_workspace_refusal`)) | same | same as today (107's relay) |
| State transport (107) | works | works, pulled piece by piece (`untrusted_state_test`) | nothing |
| Placed blobs, outcomes over 32 MiB (110) | works | works | nothing |
| Remote evolution | works when the guest's census says `Compiles` | refused: the link sets `Uncompiled` | 109 slice 4 |
| Operator directory additions | refused for any remote workspace (`client/remote/workspace.gleam:694` (`resolve_directory`)) | same | same as today |
| Permission grants and escalations | works | works; `escalate` must describe the call in flight exactly; the residual risk above applies | nothing |
| Git author identity | works (`AskGitIdentity`) | works (`GitIdentityCall`) | nothing |
| Working-directory facts in the prompt | works (census) | works (the wire census carries `workspace_plane.Census` and `PromptFacts`) | nothing |
| The executor's node report (085) | asked over distribution (`client/deployment.gleam:681` (`learn`)) | not carried | a later slice, if the machines view needs guest facts |
| `loom vm sync` | host-side `git fetch` from the guest root | unchanged | nothing |
| GitHub credential proxy | in `loom-vm` | unchanged | nothing |

The migration is a regression in exactly four places, all of them slice 3:
hooks, goal checks, the Changes tab with its baseline, and the peer worktree
view. Evolution is a fifth for a guest that had a code-mode toolchain, and is
109's slice 4.

## 3. What `loom vm up` and `ensure` would do instead

### The PKI

`up` mints the link credentials once per vm home with the existing PKI
functions,
`authority` (`client_pki_ffi.erl:28`) and
`issue` (`client_pki_ffi.erl:44`), which give the authority 3650 days and a
leaf 1825 days (`client_pki_ffi.erl:23` (`AUTHORITY_DAYS`)).

| File | Made | Lives |
|---|---|---|
| `<vm home>/link/ca.pem`, `ca.key` | first `up` in the vm home | host only, `0600` key |
| `<vm home>/link/orchestrator.pem`, `orchestrator.key` | first `up` | host only |
| `<vm home>/<name>/link/executor.pem`, `executor.key` | first `up` of that guest | host copy, staged into `root/srv/loom-node/creds/{cert,key}.pem` with the CA certificate as `ca.pem` |

One authority and one orchestrator leaf serve every guest of the vm home,
because the orchestrator has one `[executor_link]` table
(`client/untrusted_config.gleam:68` (`from_document`)). The CA key is kept, not
dropped as provisioning drops a distribution authority's: with pins on both
sides a leaf the CA signs is useless unless its pin is also configured, so the
key buys an attacker nothing and lets a later guest be issued without a new
authority. Pins are `client_pki_ffi.erl:65` (`pin`), the SHA-256 of the leaf's
DER, written as 64 lower-case hex digits (`client/untrusted_config.gleam:244`
(`pin_of`)). The SAN of a link leaf is unused, since the link checks PKIX and
the pin but no host name.

Rotation is by re-issue. A guest leaf is re-issued by `up --fresh` or a later
`vm rotate`: restage the files, rewrite the row's `pin`, reload. The
orchestrator leaf is re-issued only if its key is suspected: every guest's
`orchestrators` list is rewritten and each guest restarts, because the
listener reads its configuration at boot. Neither is needed inside five years.

`<vm home>/link/` sits under `~/.loom/vm`, which every jail on the host masks
(`client/workspace_policy.gleam:1811` (`node_home_masks`)). A `LOOM_VM_HOME`
elsewhere is unmasked, as the authority directory already is.

### The orchestrator side

`up` writes, into the configuration the daemon reads:

```toml
[executor_link]
ca = "<vm home>/link/ca.pem"
certificate = "<vm home>/link/orchestrator.pem"
key = "<vm home>/link/orchestrator.key"

[executors.<name>]
trust = "untrusted"
address = "127.0.0.1:<recorded port>"
pin = "<guest leaf pin>"
```

`[executor_link]` is written once and left alone after. A file whose
`[executor_link]` names other files is refused, as `RefuseExisting` refuses a
foreign deployment today, because the guest's leaf would not chain to that CA.
The row is replaced when the port or pin changes and removed by `rm`.

What the daemon needs, read from the code:

- `executors.from_document` reads the row: `trust`, `address` and `pin`, and
  refuses `node` on an untrusted row (`client/executors.gleam:332`
  (`reach_of`)). An untrusted row needs no `[distribution]` table, because
  only trusted rows are checked against peers (`client/executors.gleam:234`
  (`trusted_peers`)). So a laptop that is already a ledger deployment, like the
  owner's, takes the row beside its ledger rows: `ledger_rows.executor_roster`
  passes written rows through (`client/ledger_rows.gleam:145`
  (`executor_roster`)). No `key_elsewhere` refusal can arise.
- `untrusted_settings` refuses an untrusted row without `[executor_link]`
  (`client/daemon/main.gleam:1141` (`untrusted_settings`)).
- `start_untrusted_links` starts one link per untrusted row, at boot only
  (`client/daemon/main.gleam:1230` (`start_untrusted_links`)), registered under
  `untrusted_link.name_for(name)`.
- `remote/workspace.candidate` sends an untrusted row to the link's name and
  never needs distribution (`client/remote/workspace.gleam:732` (`candidate`),
  `client/remote/workspace.gleam:887` (`untrusted_candidate`)).

### The guest side

`vm_spec.guest_config` stops calling `distribution_bundle.config_tables`
(`client/vm_spec.gleam:2498` (`guest_config`)) and writes instead:

```toml
[executor_listener]
listen = "0.0.0.0:4370"
ca = "/srv/loom-node/creds/ca.pem"
certificate = "/srv/loom-node/creds/cert.pem"
key = "/srv/loom-node/creds/key.pem"
orchestrators = ["<orchestrator leaf pin>"]
```

beside the `[workspaces.*]`, `[tools]` and placeholder model tables it writes
today. The daemon refuses `[distribution]` beside `[executor_listener]`
(`client/untrusted_config.gleam:72` (`from_document`)), so the guest is never a
peer by construction. `stage_node` writes no `home/.erlang.cookie` and no
ledger. The listener binds every interface inside the guest so the forward
reaches it; a guest process that connects without the orchestrator's key fails
the handshake.

`vm_spec.launch_arguments` passes `--forward <recorded port>:4370` in place of
`--publish NAME:HOST:GUEST` (`client/vm_spec.gleam:2611` (`--publish`)). The
launcher already has the flag (`cmd/loom-vm/main.go:156` (`forward`)).

The guest image's `loom-guest-executor` changes in about ten lines: it renders no
distribution options file, it no longer `chmod`s a cookie (which, under
`set -eu`, would fail when the file is absent), and it reports
`LOOM-EXECUTOR-READY` when the log holds `daemon.untrusted_listener` and
`daemon.executor_serving` instead of waiting for an epmd registration. The
guest image is release-locked to the host already, so this ships with the
release that changes `up`.

## 4. The two hard parts

### (a) A running daemon learning about a new guest

The daemon reads `[executors.*]` and `[executor_link]` once at start and never
rereads them (`client/daemon/main.gleam:278` (`untrusted`)); links start only
there (`client/daemon/main.gleam:4665` (`start_untrusted`)). No daemon-wide
configuration reload exists: `limits` validates its keys again on a catalogue
reload and never rebinds (`client/daemon/limits.gleam:138` (`listen_address`)),
and `gateway`'s reload is a session's model catalogue. What does exist is the
mechanism ledger mode uses for rows that change while the daemon runs, a
`Roster` read at each use (`client/roster.gleam:51` (`reading`)), and the
precedent of an owner-only control command that changes rows without a
restart, `ledger.append`, whose owner check is in
`ledger_command` (`client/daemon/server.gleam:3724`).

Three options:

| Option | Cost | Verdict |
|---|---|---|
| Owner-only control command `executors.reload`: the daemon rereads its configuration file, takes `[executor_link]` and the untrusted rows from it, starts a link per new row, restarts the link of a row whose address or pin changed, stops the link of a removed row, and answers which trusted-row or other changes still need a restart | one control command (a protocol change), one `weft/actor` that owns the untrusted rows and their link pids, `executor_roster` reading through it, about 300 lines and 300 of tests | **chosen** |
| A narrower `executors.link {name, address, pin}` that carries the row in the message | the same actor, plus the row now exists in two places (the file and the daemon's memory), which a restart resolves by the file alone | rejected: the file stays the record with `reload` |
| The daemon watches `loom.toml` | a poll loop through `weft/poll`, a debounce, and edits a user makes by hand taking effect at an arbitrary moment; no authentication beyond file permissions | rejected |

`reload` changes only the untrusted rows and `[executor_link]`, because those
are the only rows whose consumer (a link) can be started and stopped without
touching sessions on other executors. A link whose row changed is stopped and
started again under the same name; its sessions' bindings retire with it and
the surface's repair loop reattaches them, which is the path a dead link takes
today. A side effect worth having: a link that crashed (links are not
restarted, `client/daemon/main.gleam:1173` (`start_untrusted`)) comes back on
the next `reload`.

`up` and `ensure` write the file first, then send `reload` if a daemon is
running. When none is, the next `loom` starts one that reads the file. Either
way no daemon is stopped, which removes `vm_spec.daemon_step` and the stop
step (`client/vm_spec.gleam:3201` (`daemon_step`)).

A new control command is a change to the client control protocol, so this
needs **protocol-change/115**.

### (b) A stable address

The row names `host:port`, and `boot` reserves a fresh loopback port on every
boot today (`client/vm_cli.gleam:2554` (`reserve_loopback_port`)), which epmd
made harmless.

| Option | Daemon restart | Port taken while the guest is down | Cost |
|---|---|---|---|
| Reserve once per guest, record in `<vm home>/<name>/link-port`, reuse on every boot | the row in the file still names the port | `up` probes the recorded port just before launch; if it is taken, it reserves another, rewrites the row and sends `reload`. A stranger listening on the old port in the meantime fails the pin check, so the link never talks to it | about 60 lines, one pure decision tested in `vm_cli_test` |
| A Unix socket | stable path | none | the forward is a host TCP port (`machine/machine.go:116` (`Forward`)), and both `untrusted_config.host_port` and `ffi_tls_stream.connect` take a host and a port (`client/internal/ffi_tls_stream.gleam:152` (`connect`)): a launcher change, an FFI change and a configuration grammar change |
| The launcher publishes its port in a file the link reads on each dial | stable | none | a new `[executors.<name>]` key, the link rereading a file per dial, and a second record of the address beside the row |

**Chosen: a port reserved once per guest and recorded.** The port changes only
when something else took it while the guest was down, which is rare, and the
reload command makes that case cheap. The pin makes a collision safe.

## 5. Slice 3, sized

### How non-tool callers reach the broker today

Each non-tool caller gets the plane's `broker.Broker`: for a remote session it
is `broker.over(census.broker, executor_clock)`
(`client/remote/workspace.gleam:691` (`broker.over`)), and over distribution
`census.broker` is the executor plane's broker subject
(`client/remote/remote_census.gleam:42` (`broker`)). The callers then call
`broker.clear_call`, `broker.stdin` and `broker.cancel` directly:
`hookrunner.run`, whose
`clear_call` (`client/hookrunner.gleam:250`) clears each hook command,
`worktree_diff`'s Git runner, which serves the Changes tab, the baseline and the
peer view, and goal checks through `tool.broker_runner`
(`tools/tool.gleam:1222` (`broker_runner`)). `broker.Msg` is opaque
(`broker/broker.gleam:259` (`Msg`)), so nothing outside the broker package can
stand in for the actor; `broker.over` only wraps a subject
(`broker/broker.gleam:746` (`over`)).

### Steps

1. **A runner seam in `client`.** Give `hookrunner.Context`, `worktree_diff.Wiring`
   and the peer observation a `clear_call` function of `tool.broker_runner`'s
   shape (`fn(CallSpec, Subject(CallEvent)) -> Result(RunningCall, Refusal)`)
   in place of the `Broker`, as goal checks already take. Local and trusted
   placements pass `tool.broker_runner(plane.broker, ..)`; behaviour is
   unchanged. Files: `hookrunner.gleam`, `worktree_diff.gleam`, `serve.gleam`,
   `workspace_plane.gleam`. About 150 lines of change, covered by the existing
   hook, diff and goal tests.
2. **Wire, version 5.** `ClearCallRequest(binding, spec)` answered by
   `Cleared(Result(call, Refusal))`; `CallStdinRequest(call, data, eof)` and
   `CallCancelRequest(call)` with no reply; and one new executor-to-orchestrator
   frame, `CallEvent(call, event)`, ending with exactly one `CallSettled`.
   Files: `untrusted_wire.gleam`. About 150 lines.
3. **Codec.** `CallSpec` (the sandbox policy codec exists), `Refusal`,
   `CallEvent`, `CallOutcome` with `ExecResult` and `ExecFailure`. Files:
   `untrusted_codec.gleam`. About 500 lines.
4. **Link.** A call table keyed by call id with each asker monitored. An
   asker's death sends `CallCancelRequest`. A dropped connection settles every
   open call as `CallFailed` and does not re-send, because a hook or a check
   that ran twice is wrong where a tool call is idempotent by key. The link
   counts output bytes against the spec's own output limit and settles a call
   that passes it, so the executor cannot stream without bound; events for an
   unknown or settled call, or a second `CallSettled`, are protocol violations.
   At most eight open calls per binding. A runner built from the link replaces
   the refusing broker for untrusted placements. Files: `untrusted_link.gleam`,
   `remote/workspace.gleam`. About 350 lines.
5. **Gateway.** The executor side already sees the host's `Attached(census)`
   before it encodes it, and the census holds the plane's broker subject; the
   book records it per binding. A `ClearCallRequest` runs `broker.clear_call`
   on that broker in the request's waiter and forwards each event as a frame.
   Files: `untrusted_gateway.gleam`, `untrusted_bridge.gleam`. About 300 lines.
6. **Hook output from a guest cannot approve.** A hook that ran on an
   untrusted executor is read with its "allow" decisions ignored, so it can
   deny or ask but never skip an orchestrator-side approval. Files:
   `hookwire.gleam` or `hookdecisions.gleam`. About 40 lines.
7. **Tests.** Codec round-trips and the kind matrix; `untrusted_link_test` with
   the hostile executor sending events for unknown calls, after settlement, past
   the output limit and for another binding's call; `untrusted_gateway_test`
   with a real broker; `untrusted_end_to_end_test` running a hook, a goal
   check, a baseline and a diff through the link into a real plane. About 800
   lines.

Total: about 1,600 lines of product code and 800 of tests, the size of 109's
slice 2. It needs its own proposal (**protocol-change/116**), as 110 and 111
were separate proposals over the same link, with an addendum on 109 pointing to
it.

### What a `loom --vm` session needs on day one

The Changes tab and its baseline are what a developer looks at after a turn,
so they are day-one needs. Goal checks matter only to `/goal` users and hooks
only to projects that have them. All four ride one tunnel, so building it once
serves all of them. Because the baseline is stored at the first open, slice 3
must land before guests use the link by default, or every guest session opened
in between shows no Changes tab for its life.

A cheaper route for the diff was considered and rejected. A `loom vm sync`
fetch gives the host the guest's commits but not its working tree, which is
most of what the Changes tab shows. Running the host's own sandboxed Git over
the guest's copy on the virtio-fs root would show the working tree, but it is
host Git over repository state the guest writes, which the standing guest's
invariants forbid ("Nothing the host runs after a guest has booted uses a
directory inside `root/` as Git's working directory", `packages/client/CLAUDE.md`),
and it serves only VM guests, not pods.

## 6. Migration and compatibility

A guest minted or joined in distribution mode has `deploy/` bundles, a
`[distribution]` table and an `[executors.<name>]` trusted row (or a ledger row)
for it in `loom.toml`, a cookie and node key in its root, and, when minted, a
sealed authority key under `<vm home>/authority/<id>/`.

| Option | Cost | Risk |
|---|---|---|
| Convert in place | needs the teardown code (`plan_teardown`, revoke through the sealed key) to run one last time inside `up`, plus deleting creds from a guest-written root | the most code, for a feature about two weeks old with few guests |
| Keep the old path working forever | all of today's mint, join and teardown machinery stays | the exposure this note exists to remove stays on every old guest |
| Refuse and name the way on | a resumed `up` on a guest with `deploy/` refuses, naming `loom vm sync` (to keep work), `loom vm rm <name> --yes` (which already removes the tables, the cookie when it is the guest's, the authority directory and the membership) and `loom vm up` | the guest's root and state disk are rebuilt |

**Recommended: refuse and name the way on.** `rm` keeps its distribution
teardown for one release so old guests can be removed, then it goes with the
rest.

Deleted once the migration is complete:

| Module | What goes | Lines, roughly |
|---|---|---|
| `client/vm_cli.gleam` | `deployment`, `begin`, `join`, `sealed_authority`, the ledger helpers, `provision`, `seal_authority`, `write_bundles`, `config_of`'s deployment half, `enroll`, `install`, from `deployment` (`client/vm_cli.gleam:824`) to about line 1520; `stage_ledger`; the daemon observation and stop step (`stop_daemon` and its neighbours, about lines 2615 to 2790); `epmd_line`; the revoke and cookie half of `rm` | 1,250 |
| `client/vm_spec.gleam` | `deployment_plan`, `DeploymentState` and the join decisions (`client/vm_spec.gleam:2118` (`DeploymentState`) to about line 2036); `with_loopback_listener`; `daemon_step` and its types; `registered_port`; `read_enrolment`, the cookie state and `plan_teardown` (`client/vm_spec.gleam:4423` (`plan_teardown`)) | 800 |
| `test/client/vm_cli_test.gleam` | about 35 of its 155 tests: node names, epmd, loopback listener, deployment state, enrolment, ledger staging, authority sealing, revoke, cookie and teardown | 600 |
| `test/client/daemon_shipped_microvm_test.gleam` | the ledger and authority assertions, the idle-daemon stop step, the second-guest refusal | 250 |

Added: the PKI mint and staging, the row install and removal, the recorded
port, about 400 lines with tests. `distribution_provision` and
`distribution_install` stay, since `loom distribution` uses them.

## 7. What does not change

- The launcher, `packages/vmm`, apart from `up` passing `--forward` instead of
  `--publish`; both flags exist.
- The guest image, apart from `loom-guest-executor`'s readiness and cookie
  lines (Section 3).
- The GitHub credential proxy and its placeholder.
- `--allow` and `--provision`, the allowlist file and the provisioning plan.
- Root upgrade in place (`root_step`, `build_next_root`, `swap_roots`).
- `sync` in both directions, `logs`, `list`, and `rm` minus the revoke and
  cookie handling.
- The one-flag surface on `vm/one-flag`: the guest name derived from the
  workspace path, the recorded `--github` mode, setup on a stale manifest.
  `ensure` calls the new `up` and then `reload`.

## 8. Slice plan

Each slice ships alone and is listed in merge order.

1. **One guest over the link, opt in.** `loom vm up --link untrusted` (hidden
   until slice 4) mints the link PKI, stages the guest's leaf and an
   `[executor_listener]` configuration, writes `[executor_link]` and the
   untrusted row, reserves and records the port, and boots with `--forward`.
   The guest script's readiness change ships in the same release. Masks the
   `[executor_listener]` key in the executor's jails (F1). No daemon reload yet:
   the daemon reads the rows at its next start, which the test arranges as
   today's test does. **Exit**: a step in `daemon_shipped_microvm_test` boots a
   guest this way, starts an orchestrator on the configuration `up` wrote, and
   a scripted `bash` call settles `resident` and runs on the guest's kernel;
   the guest root holds no `.erlang.cookie`; `epmd -names` on the host lists no
   guest; a jailed read of the listener key fails. Needs no protocol change
   (109's tables) and no ADR addendum (opt in).
2. **Live registration and the stable port.** `executors.reload`, the actor
   that owns untrusted rows and links, `executor_roster` reading through it,
   and `up` sending `reload` when a daemon runs. **Exit**: with a daemon
   running, `vm up` of a second guest serves a session with no restart; the
   daemon restarted reaches both; `vm_cli_test` covers the taken-port decision.
   Needs **protocol-change/115**. Built: the daemon side, then the clients
   (`vm_link.reload_report`, `vm_cli.reload_daemon`), under
   protocol-change/115.
3. **The broker tunnel (109 slice 3).** Section 5. **Exit**: the
   `untrusted_end_to_end_test` cases of step 7, and the microVM step of slice 1
   extended so the Changes tab shows the jailed call's edit against a recorded
   baseline and a goal check passes. Needs **protocol-change/116** and a
   pointer addendum on 109.
4. **The untrusted link becomes the default.** `up` and `ensure` use it with no
   flag; a resumed distribution guest is refused naming `sync`, `rm` and `up`;
   `microvm.md` and the client package docs are rewritten. **Exit**:
   `daemon_shipped_microvm_test` runs only the untrusted path, including the
   daily verbs, and `make doc-check` passes. Needs the **ADR-022 addendum**
   below.
5. **Delete the distribution path from `loom vm`.** Section 6's deletions,
   after one release. **Exit**: `make check` green, about 2,000 product lines
   and 850 test lines removed.

The one-flag work lands on top of slice 4 or rebases onto it; its surface does
not change.

## 9. Draft ADR-022 addendum

> ## Addendum, 2026-11-xx: guests are untrusted executors
>
> *The owner ruled on this date. D1 to D7 are unchanged. This supersedes the
> link of the first 2026-11-01 addendum, the ruling in the developer-path
> addendum that the local daemon becomes a distribution member, and the
> 2026-11-02 addendum on minting and joining in ledger mode.*
>
> **Decision.** `loom vm up` reaches a guest over protocol-change/109's
> untrusted link. The guest daemon has `[executor_listener]` and never
> `[distribution]`; the host daemon has one `[executor_link]` per vm home and
> one `trust = "untrusted"` row per guest, whose address is a host loopback
> port reserved once per guest and recorded beside it, forwarded by `loom-vm
> run --forward`. One link authority and one orchestrator leaf per vm home live
> under `<vm home>/link/`; each guest has its own leaf, and both sides pin.
> A running daemon learns of a new guest through the owner-only
> `executors.reload` (protocol-change/115). No cookie, epmd registration,
> ledger, authority key or daemon restart is involved.
>
> **Why.** Over distribution, the guest's `loom` user holds the executor's
> cookie and key, and the distribution connection the orchestrator dials is
> symmetric, so a jail escape in the guest ran code in the host daemon as the
> developer. That was verified on 2026-11-13 against the nightly of ebae32cf2.
> The tier exists to contain kernel exploits, and distribution cannot express a
> partly trusted peer (109, "Harden distribution"). The link also removes the
> join's need for the authority key and a running daemon, and the first guest's
> need for a daemon restart.
>
> **What it costs.** The guest is no longer a deployment member: sessions on it
> cannot be moved between orchestrators by the ledger, and remote evolution on
> a guest waits for 109's slice 4. Non-tool callers ride the broker tunnel of
> protocol-change/116. Every reply pays a JSON encode and a total decode, and
> bytes grow by a third as base64. A guest made over distribution is not
> resumed: `up` names `vm sync`, `vm rm` and `up`. The libkrun VMM escape of the
> Consequences section is unchanged: a guest kernel exploit that escapes the
> VMM still lands in `loom-vm` as the developer.

## 10. Open questions for the owner

1. **Supersede the 2026-11-01 rulings for the microVM tier?** The local daemon
   stops being a distribution member for guests, and the ledger join goes.
   Recommendation: yes; the exposure is a host code-execution path from inside
   the tier meant to contain kernel exploits.
2. **Migration: refuse and name `sync`, `rm` and `up`, or convert in place?**
   Recommendation: refuse. Few guests exist, and conversion needs the teardown
   code this change deletes.
3. **Is the broker tunnel a gate on making the link the default?**
   Recommendation: yes. The baseline is stored once per session, so a guest
   session opened before it lands has no Changes tab for its life.
4. **`executors.reload` (reread the file) or `executors.link` (carry the
   row)?** Recommendation: `reload`, so the file stays the only record and a
   restart and a reload agree.
5. **Keep a `--trusted` escape for guests, for remote evolution?**
   Recommendation: no. Evolution on a guest waits for 109's slice 4; keeping
   both paths keeps all of the machinery Section 6 deletes.

## Findings in 109's implementation that matter for a guest

- **F1. The listener key is not masked from the executor's jails.**
  `executor_plane.node_credentials` masks the `[distribution]` key and cookie
  and returns nothing for a daemon with no `[distribution]`
  (`client/executor_plane.gleam:323` (`node_credentials`)); nothing masks
  `[executor_listener].key`. Model code under the default host read scope can
  read it. Low impact on a guest (Section 1), more on a pod reached by network
  name. Fixed in slice 1.
- **F2. A session's Git baseline is stored as unavailable for its life.**
  Through the refusing broker, the first open records `Unavailable`
  (`client/session_git.gleam:59` (`start`)), and later opens decode the stored
  value instead of probing again. Slice 3 fixes new sessions only.
- **F3. No test starts the daemon with both tables.** The link, gateway, host
  and plane are tested together in process (`untrusted_end_to_end_test`,
  `untrusted_state_test`, `untrusted_host_codemode_test`), but
  `daemon/main.start_untrusted` with `[executor_link]` on one daemon and
  `[executor_listener]` on another is not; `daemon_executor_test` passes
  `untrusted_config.none`. Slice 1's microVM step is the first such test.
- **F4. Hook decisions from an untrusted executor are trusted as written.**
  Not reachable today, since hooks are refused there, but slice 3 would make
  a guest's hook output an input to orchestrator-side approval decisions.
  Slice 3 step 6 reads such output as deny or ask only.
- **F5. One frame's decoded size is unbounded in breadth** (109's own residual
  risk). For a guest the orchestrator is the developer's whole daemon, so a
  count of values in `core/json.parse`'s use on the link is worth adding before
  the default flips. Not in the slice plan; recorded here.

## Feasibility probe

Run on macOS 27.2 (arm64) at 024afdadf, with `LOOM_TEST_TIMEOUT_SECONDS=600
bash scripts/test.sh client --match <module>`:

| Module | Result | Needed |
|---|---|---|
| `untrusted_end_to_end_test` | 9 of 9 pass: attach with census, a call and its outcome, an escalation mid-call, the asker's death aborting the call, a 40 MiB outcome, a placed blob, blob claims returned on close, a background program and its stop | nothing beyond the build; the first attempt hit a Hex rate limit and passed when retried |
| `untrusted_state_test` | passes: a repository the executor never saw is placed whole and then by its delta, through the link into a real plane | `make sandbox` (without it the plane's Git refuses with `NoHelper`) |
| `untrusted_host_codemode_test` | passes: a program vetted, compiled and run in a real executor plane's jail behind the gateway calls `cap/search`, `cap/lsp` and the host seam over the link | `make sandbox` and `make codemode-seed` (without the seed it prints `SKIP`) |

Each test runs both ends on one node with certificates minted by
`client_pki_ffi`, real TLS over loopback, and no distribution peer. They show
the link carries a real tool call into a real executor plane. They do not start
two daemons from configuration (F3).
