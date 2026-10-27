# The Agent Client Protocol server

`loom acp` makes Loom an [Agent Client Protocol](https://agentclientprotocol.com)
agent. An editor (Zed), an orchestrator, or a benchmark harness launches it as
a subprocess and speaks JSON-RPC 2.0 to it, one frame per line, on standard
input and output. The command translates that conversation into the same
session protocol the terminal and `loom run -p` already speak. It adds no
runtime: durability, approvals, budgets and placement stay where they are, and
a tool call still goes through the broker into the jail. ACP changes who is
asked, never what is allowed.

The issue is [#1026](https://github.com/Roasbeef/loom/issues/1026). It names
two directions. This page is the first: Loom as an ACP *agent*. Loom as an ACP
*client*, a strand whose model is `codex-acp` or `claude-code-acp` held under
the broker's clearance and budget, is a separate design and is not built here.

## Position in the system

`loom acp` is a client of the daemon, in the sense [the client
plane](client.md) uses the word. It sits outside the three planes, on the far
side of the gateway, exactly where [the terminal](terminal.md) sits:

```
ACP client (Zed, Harbor, an orchestrator)
   │  JSON-RPC lines on stdin/stdout
loom acp   ── tui/acp/server ── one process, one inbox
   │   one credited session lane per ACP session (session_view/session_channel)
   │  authenticated WebSockets, loopback only
loomd      ── gateway ── runtime ── broker ── jail
```

Rule Zero is untouched. Nothing the model influences runs in `loom acp`: the
process decodes frames, relays text and forwards decisions. It holds no model
credential and opens no listener. It authenticates to the daemon with the owner
credential from the state root, through the same discovery and launch ladder
(`run.reach_daemon`) that `loom sessions` and `loom run` use, and it starts the
daemon if none is running.

## Modules

| Module | What it owns |
|---|---|
| `tui/acp/rpc` | The JSON-RPC 2.0 boundary. One line decodes once into `Call`, `Notification` or `Reply`, or into a `Refusal` carrying the error object owed. Total: a 4 MiB bound is checked before parsing, duplicate keys and deep nesting are refusals, and ids are admitted only as integers or strings. |
| `tui/acp/schema` | ACP's vocabulary as closed types. Decodes each client method's params (`request`, `notification`, `permission_choice`) with a precise `invalid_params` message, and builds every result and `session/update` payload the server sends. |
| `tui/acp/translate` | Pure projection of Loom data into ACP: entries to updates, the live stream reconciled with the committed message, an escalation to a permission request and the answer back to a decision, a run's end to a stop reason, cumulative usage to a turn's tokens. |
| `tui/acp/session` | One ACP session over one lane, as a pure reducer. Each entry point takes an event and a clock reading and returns the next session and the `Action`s to perform. Owns the command queue, the turn state machine, cancellation and permission custody. |
| `tui/acp/workspace` | The gate between a client's `cwd` and a bound workspace. |
| `tui/acp/server` | The process: the stdin reader, the single inbox, daemon access, session custody, id allocation for permission requests, and the retirement of sessions at end of input. |

`tui.gleam` routes the verb (`Acp`, `AcpRefused`; `acp` is one of the
`hoisting_verbs`, so `loom --server X acp` works) and `ffi_terminal.
read_protocol_line` is the one new external, for the reason given under
[Standard input](#standard-input).

## The process

A single loop owns standard output, so frames never interleave. Its inbox
receives three things: lines from a reader process that blocks on standard
input, events from each session socket (tagged with the session they belong to
by `connection.connect_tagged`, so one `Subject` is enough and no selector is
rebuilt as sessions come and go), and silence, which is the cue to tick every
lane. The wait is bounded by the soonest lane deadline and never exceeds a
quarter second.

The reader is a hand-written process rather than a weft one because there is
nothing for weft to do: a console read has no deadline to bound and no work to
reap, and the process ends at end of input. Every other shape in this package
that weft covers (the deadline-bounded stop of a session) reuses `run.stop`,
which already goes through `weft/poll`.

### Standard input

`io:get_line` takes its encoding from the VM's locale, which in a container
with no locale is latin1, and would turn every non-ASCII prompt into mojibake.
`tui_ffi:read_protocol_line` sets the device to binary Unicode before every read
(setting it once is not enough: a chunk that held an undecodable byte makes the
console driver fall back to Latin-1, and only setting it again restores Unicode
for later chunks), so a line comes back as a binary and never as a character
list. A line with an undecodable byte arrives as Latin-1 text, which is not
JSON, so the protocol layer answers with a `-32700` and the connection
survives one bad frame. Valid text that shares a chunk with the bad line can
arrive garbled; text in later chunks is unaffected. A read error ends the input
rather than being retried, so a broken device cannot spin. No package in the
tree reads a console line at all, which is why this is an external.

The 4 MiB frame bound is enforced when the line is decoded, which is after the
line has been read: Erlang's console reader cannot bound a line before it
returns. The peer is the process that launched this command, so the exposure is
the one every child process has to its parent; it is not a network surface.

## Method mapping

| ACP | Loom |
|---|---|
| `initialize` | Version negotiation (the server speaks 1; a client asking for 0 is refused, a newer one is answered with 1). Advertises `loadSession`, `promptCapabilities` `image` and `embeddedContext` (not `audio`), `mcpCapabilities` all false, no auth methods, and `agentInfo` `loom` with the build version. Nothing else is accepted before it. |
| `authenticate` | Refused with `invalid_params`: no methods are advertised, because the credential is the owner token the command already holds. |
| `session/new` | Workspace gate, then `CreateSession` on the control socket under a one-shot key, open, a session socket, `session_channel.start`, the model-catalogue read, and only then the result. The response carries `sessionId`, `models` and `configOptions` (below). |
| `session/load` | `GetSession` (to learn whether it is parked), `OpenSession`, attach, replay the retained window as `session/update`, then the result. |
| `session/prompt` | `prompt_content` on the `main` strand, one turn. Answered when the strand's terminal `last_result` appears; see [A turn](#a-turn). |
| `session/cancel` (notification) | `abort` on `main`; see [Cancellation](#cancellation). |
| `session/set_model` | `set_config` with `model_name` on `main`. Answers `{}`. |
| `session/set_config_option` | Option `model` only, as `set_config`. Answers `{configOptions}`. A boolean value or another option id is `invalid_params`. |
| `session/request_permission` (server to client) | An `escalation` register cell that is pending; answered by `approve`, `approve` with session scope, or `deny`. |
| `session/update` (server to client) | See below. |
| anything else | `-32601` for a request; a notification of an unknown method is dropped, as JSON-RPC requires. |

`fs/*` and `terminal/*` are client capabilities the server never calls: Loom
runs its own jailed tools in the workspace on the daemon's side, and routing
file access through a client would put a model-influenced path outside the
jail's reach. A client advertising those capabilities loses nothing.

`session/set_mode`, `session/list`, `session/close` and the other optional
methods are not advertised and answer `-32601`.

### What a session shows

`session/update` is built from the durable conversation and the live stream:

| Loom | ACP |
|---|---|
| `stream_delta` kind `text` | `agent_message_chunk` |
| `stream_delta` kind `thinking` | `agent_thought_chunk` |
| `stream_delta`, other kinds (tool-argument streaming) | nothing |
| assistant entry, text and thinking blocks | the same chunks, minus what the live stream already showed |
| assistant entry, tool call | `tool_call`, status `pending`, `rawInput` the model's arguments, `kind` from the tool name, a one-line `title` |
| `tool_output` tail | `tool_call_update` `in_progress`, only once the call has been announced |
| tool-result entry | `tool_call_update` `completed` or `failed`, `content` the text, `rawOutput` `{output, is_error}` |
| user entry | nothing live; `user_message_chunk` when replaying a loaded session |
| compaction, branch summary, custom entries | nothing |
| session usage and context | `usage_update`, once per turn, before the reply |
| redacted thinking | never forwarded |

The live stream and the committed message carry the same words, so the server
keeps what it has streamed and compares it with each committed block by
content (`translate.reconcile`): a block the stream covered is not repeated, a
block it only began is completed with the remainder, a stream that ran on into
the next request is consumed block by block, and text that diverged is shown
whole. The comparison is by content rather than by count so that a cut-off
stream, a retried request and a provider that streams nothing at all all come
out right.

Only the `main` strand's output is forwarded. A sub-agent's activity is not,
but its pending escalations are, because a request that blocks the run must be
visible.

### A turn

The daemon acknowledges that a prompt was *accepted*; the run ends later, as a
durable `strand.last_result`. The turn remembers the operation id of the result
present when the prompt was sent and ends on the first run result with a
different one (the rule `loom run -p` uses for one turn, extended to many).
`RunCompleted` is `end_turn`, `RunAborted` is `cancelled`, `RunFailed` is a
JSON-RPC `-32603` carrying the error code, except that a turn the client
asked to cancel is always answered `cancelled`, whichever way the run ended.
Only a turn the daemon has acknowledged can be ended by a result: a result
seen while the prompt is still unacknowledged may belong to a run someone else
started on a shared session. (Binding to the exact operation id the daemon
assigns to our prompt would be stricter still; the acknowledgement does not
carry it.) A compaction or navigation result
ends no turn.

After the result, the turn reads the daemon's context figures once so the
reply can be preceded by a `usage_update` whose `used` and `size` are real
(`used` is tokens in context, `size` the window, `cost` the session's
cumulative dollars). If that read does not answer in three seconds the reply
goes out without it. The prompt response itself carries `usage` for the turn
(`inputTokens`, `outputTokens`, `totalTokens`, `thoughtTokens`,
`cachedReadTokens`, `cachedWriteTokens`) computed from the session's cumulative
usage before and after.

The lane admits one mutation at a time, so commands (prompt, abort, a decision,
a model switch) wait in a queue and leave one by one. An abort cannot overtake
the prompt it cancels.

### Cancellation

`session/cancel` during a turn marks the turn cancelled and queues an `abort`.
If the prompt has not yet been handed to the daemon it is withdrawn and the
turn is answered `cancelled` immediately. A run that finishes normally before
the abort lands is still answered `cancelled`, because ACP defines the reply to
a cancelled prompt and not a race between the two. Pending permission requests
are abandoned: a reply to one that is no longer pending is dropped.

### Permission requests

Every pending `escalation` register cell becomes one
`session/request_permission`, once. The options are what the daemon can honour
for that record, by the terminal's own rules (`approval.rememberable`):

| optionId | kind | daemon command |
|---|---|---|
| `allow` | `allow_once` | `approve` with the displayed grants and the cell's sequence |
| `allow_session` | `allow_always` | `approve` with `scope: session`, offered only when the whole grant set is rememberable |
| `reject` | `reject_once` | `deny` |

A record the daemon cannot encode an approval for offers `reject` alone. The
answer is read against the options offered for *that* request: `allow_session`
sent for a request that did not offer it is a refusal, and a decision whose
approval cannot be encoded is sent as a denial rather than dropped, so the
parked run is never left waiting. Any answer that is not an offered allow
option is a refusal, including a
dismissal (`outcome: cancelled`), an option id the server never offered, a
reply that does not decode and a JSON-RPC error. An unreadable answer never
widens authority. The record is re-read from the latest cut when the answer
arrives, so the compare-and-swap sequence is current; a request that is no
longer pending is dropped.

The request's `toolCall.toolCallId` is `escalation-<id>`: the record names the
action but not the provider's call id. `rawInput` carries the tool, the
strand, the action digest and the authority lines the terminal shows.

## Workspaces

ACP's `cwd` is a host path chosen by the client. A Loom session binds a
workspace the operator controls. `tui/acp/workspace` decides:

- The operator names roots with `--workspace-root <dir>` (repeatable). With
  none, the `--workspace` directory, or else the process directory, is the only
  root. Roots are canonicalised once at start; a root that cannot be resolved
  fails the launch with status 2 before any frame is read.
- A `cwd` must be absolute, is resolved through the filesystem (links and `..`
  included), and must lie at or below a root, compared by whole path segments
  (`/work/app-evil` is not below `/work/app`). Otherwise `session/new` is
  `invalid_params` and no daemon is asked.
- A workspace registered on an executor is selected by name with
  `_meta.loom.workspace` plus exactly one of `_meta.loom.executor` and
  `_meta.loom.pool`. It is a name, never a path, and `cwd` is then ignored.
  It reaches a machine the operator configured, so it is admitted only when
  the operator listed it with `--workspace-name <name>` (repeatable); none is
  admitted by default. The daemon then validates the name against its
  configuration.
- `session/load` applies the same gate to the loaded session's own workspace
  when that is an absolute path, and requires the request's `cwd` to be that
  workspace: a mismatch is `invalid_params`, not ignored. Both checks, and the
  duplicate check below, run against the daemon's registration *before* the
  session is opened, because opening a parked session makes it resident.
- Loading a session this connection already holds is `invalid_params`.

The server never synthesises a workspace from a client string.

A Harbor-style launch (`cwd` equal to the process directory, no flags) needs no
configuration: the default root is the directory the command was started in.

## `_meta.loom` keys

Read from `_meta.loom` on `session/new` and `session/load`. A member of the
wrong type is `invalid_params`, never ignored.

| Key | Type | Meaning |
|---|---|---|
| `workspace` | string | A registered workspace name (needs `executor` or `pool`). |
| `executor` | string | The `[executors.<name>]` serving it. |
| `pool` | string | The `[pools.<name>]` to pick an executor from. Exclusive with `executor`. |
| `profile` | string | A `[profiles.<name>]` model profile for the new session. |
| `model` | string | A catalogue model name to switch `main` to before the catalogue is read, so the response already names it current. A name the daemon refuses fails the `session/new`. |
| `project_instructions` | boolean | `false` is **refused** today; see below. |

There are no extension methods.

## Models

The catalogue is offered both ways because ACP clients disagree about how to
learn it:

- `models: {currentModelId, availableModels: [{modelId, name}]}` with
  `session/set_model`, the original form Zed and older SDKs use;
- `configOptions: [{id: "model", category: "model", type: "select",
  currentValue, options: [{value, name}]}]` with `session/set_config_option`,
  which current SDKs, and so Harbor's runner, use.

`modelId` and `value` are the catalogue *names* (what `set_config` takes);
`name` is the provider's model id. The current model is the one the switch
named, else the catalogue entry whose provider id matches the strand's
configuration, else the one routed to `main`.

## Lifetime

Sessions this connection created, and sessions `session/load` found parked on
disk, are stopped when the client closes standard input: `run.stop` sends
`StopSession` and waits under `weft/poll` for the daemon to report the session
`Saved`, the same proof `loom run` waits for. Nothing a connection started
outlives it. A session `session/load` found already resident is detached and
left as it was found. `session/load` of a saved session therefore works across
connections, which the end-to-end test exercises.

Retirement is concurrent and bounded: every session is stopped at once, each
over a control connection of its own (the daemon answers one request per
control connection), under one 15 second deadline, because a client's runtime
closes standard input and then terminates the process after a short grace.
A session still stopping at the deadline stays the daemon's.

Only an orderly end of input retires sessions. SIGKILL, and a SIGTERM that
lands before the pipe closes, give the process no chance to stop them, and
they stay resident in the daemon until stopped with `loom sessions` or the
daemon's own lifecycle. There is no signal handler or janitor: catching the
signal would need another external, and the resident sessions are inert (the
daemon accounts for them like any other) rather than running work.

## Not supported, and why

Two members of the issue are **refused** rather than half honoured, because
each exists to isolate a session and accepting it silently would hand the
client a guarantee that is not there.

- **Per-session MCP servers** (`session/new.mcpServers`). The daemon has no
  per-session tool registration; MCP servers are static `[mcp.*]` configuration.
  Attaching one to a single session, as direct tools, cleared by the broker and
  torn down with the session, needs a new daemon command and a
  `protocol-change/NNN.md` for it. A non-empty list is `invalid_params`
  naming the servers. `mcpCapabilities` advertises no transports.
- **The guidance opt-out** (`_meta.loom.project_instructions = false`). The
  daemon assembles `AGENTS.md` and `CLAUDE.md` into the system prompt when a
  session starts, and has no per-session switch. A security-review consumer
  treats repository text as evidence, so silently loading it would be the worst
  failure; the flag is `invalid_params` until the daemon can honour it.

Smaller limits:

- `session/load` replays the retained window (the daemon's snapshot holds the
  newest 100 records), not the full history.
- Audio prompt content is `invalid_params`; an embedded non-image binary
  resource is too.
- `session/set_mode`, `session/list`, `session/close`, `session/fork` and
  `session/resume` are not offered.
- The server does not call `fs/*` or `terminal/*` (see above).

## Compatibility with Harbor's ACP runner

Harbor's generic ACP agent runs `acp_runner.py` inside the task environment,
built on the `agent-client-protocol` Python SDK. The runner's use of the
protocol, and where Loom meets it:

| Runner behaviour | Needs from the agent | Loom |
|---|---|---|
| spawns the registry launcher with the task directory as `cwd` | a stdio ACP agent started in that directory | `loom acp`; the default root is the directory it starts in |
| `initialize` with protocol version 1, `fs` and `terminal` capabilities | a well-formed result with `agentInfo` optional | yes; the capabilities are accepted and not used |
| reads `authMethods`; authenticates only for an env-var method | none advertised is fine | none advertised |
| `session/new {cwd, mcpServers}` (servers from `HARBOR_ACP_MCP_SERVERS_JSON`, empty by default) | `sessionId` | yes; **a non-empty `mcpServers` list is refused** |
| optional model selection: legacy `session/set_model` if `models` is advertised, else `session/set_config_option` for a `model` select option | one of the two | both |
| `session/prompt` with one text block | `stopReason`; `usage` (`inputTokens`, `outputTokens`, `cachedReadTokens`) is read for the trajectory | yes |
| `session/update` stream | `agent_message_chunk`, `agent_thought_chunk`, `tool_call`, `tool_call_update` (with `toolCallId`, `rawInput`, `rawOutput`, `content`, `status`), `usage_update` (`cost.amount` is read) | all sent |
| `session/request_permission` | the client answers `allow_once`/`allow_always` or `cancelled` | requested; both answers handled |
| end of the run | the runner closes the agent's stdin and kills it | stdin EOF stops the sessions and exits 0 |

This was exercised with the runner itself: `acp_runner.py` from the Harbor
checkout, unmodified, driving `loom acp` over a real pipe with SDK 0.12.1
against a scripted provider (instruction, streamed answer, `usage`,
`usage_update`, model selection through `configOptions`). The sessions it
created were left `saved`.

## Tests

- `tui/test/acp_rpc_test`, `acp_schema_test`, `acp_translate_test`,
  `acp_workspace_test`, `acp_command_test`, `acp_stdin_test`: codec round trips and refusals,
  every decoder and encoder, the stream reconciliation, the permission
  mapping, the workspace gate, the command line.
- `client/test/client/loom_acp_test`: the real `acp/server.serve` loop against
  the shipped daemon and a scripted provider, driven by a scripted ACP client.
  A text turn (answer once, usage, session left saved), a paced answer that
  streams in pieces and is not repeated, a permission round trip allowed and
  denied, a cancel during a stalled response, `session/load` replay, model
  listing and both switch forms, malformed, premature, oversized and
  unknown-method frames, an unsupported protocol version, and the workspace and
  extension refusals. The tests that reach the daemon skip with a message on
  stderr when `LOOM_BOOTSTRAP_E2E_SERVER` is unset; the tests of refused
  frames, versions and workspaces need no daemon and always run.
