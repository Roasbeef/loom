# Tools

A tool is a named function the model may call by emitting a tool-call
block in its response. Loom's tool layer answers four questions: what a
tool is, which tools a session offers, what the model is shown about
them, and how one call travels from the model's response to a result
entry in the conversation tree. The `tools` package defines the tool
record, the registry, and the core tool set. `client/contributions`
builds a session's registry from the tools each plane contributes, and
`client/wiring` connects that registry to the runtime's effect seam and
to the provider request.

The tool layer sits on the effect plane (`effects.md`), and it is
entered from the orchestration plane (`orchestration.md`). The machine
plans a tool batch and the runtime wraps each call in the effect
sandwich, the intent-then-settle commit pair that keeps a crash from
repeating an effect. The tools themselves never commit anything. A tool
returns a value, and the runtime commits it. Some tools reach the kernel
jail through the broker; most run in the harness VM on model-supplied
arguments. The table in "The tool set" lists every tool and the document
that owns its internals.

## What a tool is

A tool is a record, `Tool` (`tools/tool.gleam:440`), with eight fields:

| Field | What it holds |
|---|---|
| `name` | The name the model calls. Unique within a registry. |
| `description` | The model-facing description, sent in the provider's tool array. |
| `prompt_snippet` | One optional line for the system prompt's available-tools index. |
| `schema` | A JSON Schema object for the arguments. |
| `replay` | `Safe` or `Never`: whether a crashed call may be re-executed on recovery. |
| `execution_mode` | `Exclusive` or `Concurrent`: whether the call may run beside others in its batch. |
| `requirements` | A function from the workspace root to a `SandboxPolicy`, stating what the tool needs. |
| `run` | `fn(Ctx, JsonValue) -> ToolOutcome`: executes one call. |

There is no separate decoder field. `run` receives the model's
arguments as raw JSON and decodes them itself, using the helpers in
`tools/tool` (`required_string`, `optional_int`, and the rest). The
`with_arg` combinator chains those decodes with `use`, and a decode
error becomes the ordinary outcome `invalid arguments: <reason>`. The
schema describes the arguments to the model; the decoding in `run`
enforces them. Most schemas are built with `object_schema`, which sets
`additionalProperties: false`.

`run` returns a `ToolOutcome`:

- `content`, a non-empty list of result blocks (text, or an image for
  `fs_read` of a PNG, JPEG, GIF, or WebP file);
- `details`, optional machine-readable JSON under the tool's own
  contract;
- `is_error`, which marks an in-band failure for the model to act on;
- `terminate`, `ContinueRun` or `TerminateRun`.

`success`, `failure`, and `with_details` construct outcomes, and all of
them set `terminate` to `ContinueRun`. No built-in tool answers
`TerminateRun`, so ending a run is something a tool must say
explicitly.

### The per-call context

`Ctx` (`tools/tool.gleam:234`) carries everything a tool's `run` may
touch. `client/wiring` builds a fresh one for every call. It holds:

- the workspace root and the blob-overflow directory;
- the call's durable coordinates: `strand`, `op_id`, `step_id`, and
  `source_index`;
- the session's base sandbox policy, the explicit directory additions,
  and the grants this call's clearance consumed;
- the enforcement demand and the allowlist-built environment for jailed
  children;
- an injected clock and a `FileSystem` record of functions;
- three seams: `clear_call`, which clears and starts one jailed
  execution through the broker; `raise_refusal`, which reports a policy
  refusal the tool met somewhere other than `clear_call`; and
  `observe_output`, which receives the rolling tail of a running
  execution's output.

The coordinates always come from the strand driver and never from the
model's arguments. The agent tools judge a call against `Ctx.strand`,
and they derive a spawned child's name from the other three
coordinates. A model that names another strand in its arguments
therefore cannot act as that strand, and a replayed spawn arrives under
the same coordinates and reconciles onto the same child.

Every effect goes through a seam, so tests substitute an in-memory
filesystem and a fake broker, and the tools run unchanged.

### Shells over seams

The `tools` package depends on `core`, `broker`, `gleam_erlang`, `gleam_regexp`,
and `simplifile`. It cannot import `client`, `runtime`, `events`, or
`codemode`, and several of those packages depend on `tools`. So a tool
that needs a live runtime, the search index, or the memory store is
written as a shell over a record of closures that `tools` declares and
`client` fills:

| Record | Declared in | Filled by | Tools over it |
|---|---|---|---|
| `Agency` | `tools/agent` | `client/agency` | `agent_*` |
| `Jobs` | `tools/job` | `client/jobtools` | `job_*`, and `bash` with `mode: "background"` |
| `History` | `tools/history` | `client/history` | `history_search` |
| `Memory` | `tools/remember` | `client/memory` | `remember` |
| `Schedules` | `tools/schedule` | `client/scheduleseam` | `schedule_*` |
| `Context` | `tools/context` | `client/checkpoint` | `context_remaining` |
| `Advice` | `tools/advise` | `client/advisor` | `advise` |
| `CodeMode` | `tools/codemode` | `client/codemode` | `code_mode` |

The division is the same for every row. The shell owns the model's half
of the contract: the schema, the description, argument decoding, and
the wording of each refusal. The far side owns everything durable and
everything enforced, such as caps, ceilings, lineage, and operator
policy. Where the description states a bound the far side enforces, the
number is passed in from that side, so the description and the check
cannot drift apart.

## Failures are results

A tool never crashes the strand. A bad argument, a policy refusal, a
missing helper, a stale hashline anchor, a busy memory store, and an
unknown tool name all come back as a `ToolOutcome` with `is_error` set,
which the runtime commits as an ordinary result entry. The model reads
the failure and chooses its next step, the same way it reads a
successful result.

The rule is enforced in four places, from the tool outward:

1. **Each tool's `run` is total.** Tools chain fallible steps with
   `with_arg` or `or_outcome`, whose error branch renders an outcome.
   House rule R4 forbids `panic` and `let assert` in source, so no
   decode can crash the process. Broker refusals and execution failures
   have standard renderings in `tools/tool` (`refusal_outcome`,
   `exec_failure_outcome`). A policy refusal carries the exact wanted
   grants in `details`, ready for the escalation flow.
2. **The registry's dispatch is total.** For an unknown name,
   `dispatch` (`tools/tool.gleam:643`) answers with text saying that
   tool is unavailable, `is_error` set, and no `details`. The
   registry does not invent a value for a tool's details contract.
3. **The wiring always answers `ToolCompleted`.** The function
   `run_tool` (`client/wiring.gleam:1548`) wraps whatever dispatch
   returned as a result message. A failure to read the session's
   directory access or standing permissions also becomes an in-band
   failure outcome.
4. **The runtime turns a dead worker into a result.** Each call runs in
   its own effect process. If that process exits without reporting, the
   strand driver settles the call as `ToolFailed`, and
   `tool_observation` (`runtime/strand_runtime.gleam:870`) converts that
   into a synthetic error result for the same call. Only
   provider effects halt the driver on an unreported exit; a tool never
   does.

Refusals are worded for the model because the provider adapters send
only the result content and, where the wire format has a slot for it,
the error flag. The Anthropic and Gemini adapters carry `is_error`; the
OpenAI Responses adapter, which has no such field, wraps the content in a
JSON envelope carrying `is_error`; the OpenAI chat adapter drops it. No adapter sends `details`, which stays
in the durable entry for clients and for the runtime. A fact the model
needs, such as the current file digest after a stale edit, must
therefore appear in the text.

## Building a session's registry

A registry, `tools/tool.Registry`, is an opaque name-to-tool table that
also records registration order. `names` returns the names sorted;
`registered` and `snippets` return tools in registration order. Within
one list passed to `tool.registry`, a repeated name keeps the later
definition at the earlier position.

Sessions do not call `tool.registry` directly. `client/serve` builds a
list of **contributions**, each a `Contribution(origin, tools)` whose
`Origin` is `BuiltIn` or `Extension(name)`, and hands the list to
`contributions.registry`.

### The built-in contribution

`built_in` (`client/contributions.gleam:172`) takes one `Option` per
plane and returns the host's own contribution in a fixed order:

1. the five core tools, `bash`, `grep`, `fs_read`, `fs_write`, and
   `fs_edit`;
2. the six `agent_*` tools, given an `Agency`;
3. `code_mode`, if the host has a code-mode toolchain;
4. `history_search`, if the search index opened;
5. `remember`, if the memory store opened;
6. the three `schedule_*` tools, if the operator's schedule policy
   admits model-created schedules;
7. `context_remaining`, given a `Context`;
8. the three `job_*` tools, given a `Jobs` door.

`client/serve` always supplies the `Agency`, `Context`, and `Jobs`
seams, so on a served session only code mode, search, memory, and
scheduling vary; the other `None` cases exist for tests and the demo
host. A plane that did not open contributes nothing, and the reason is
cost rather than tidiness. The tool array is part of every provider
request and sits at the front of the provider's cached prefix. A
definition that could only refuse would be paid for on every request of
every strand for the life of the session. `bash` is the one exception
to gating: it always takes a `Jobs` door, and with no jobs plane the
door is `job.unavailable()`, so `mode: "background"` is refused in band
rather than absent from the schema.

`client/serve` then appends three more contributions. Two carry the
`BuiltIn` origin: `load_skill` (if any skill allows model invocation)
with the three `peer_*` tools, and `advise` (if an advisor is
configured). The last is one `Extension(name)` contribution per
installed extension that discovery accepted; `extensions.md` §"Dispatch"
covers how discovery turns an install record into tools.

### Collisions and deactivation

`registry` (`client/contributions.gleam:282`) refuses a name that two
contributions both claim. The refusal is a `Collision` naming both
origins, and `client/serve` turns it into a boot failure. It is never a
warning and never "last registration wins". If an extension could
register `bash`, installing it would silently change what the model's
`bash` call does, and every sandbox argument about `bash` would
describe the wrong function. Shadowing a peer extension is refused for
the same reason: install order would decide which tool the model
reached. Extensions are appended after the built-ins so that the
collision message names the extension as the second claimant, the one
to remove.

An operator may free a built-in name. `deactivate` drops named tools
from every `BuiltIn` contribution before the registry is built, reading
the list from the server's configuration (`settings.deactivated_tools`).
An extension's tool of that name then registers with no collision.
Deactivation reaches built-ins only, and it is not a capability
control: dropping `fs_edit` removes the tool name, but `code_mode`
programs can still edit files through `cap/fs`. Narrowing what a
session may do is the base policy's job.

After a successful build, `client/serve` logs the registered names as
`server.tools`.

### MCP servers and code mode are not registered tools

An MCP server's tools never enter the registry. Each configured server
becomes one generated Gleam module, `cap/mcp/<server>`, which a
`code_mode` program imports and calls through the broker (`mcp.md`).
The tool description indexes the server's generated module under the seam
that offers it. `fs_read` at `cap://mcp/<server>` returns its declarations.

`code_mode` itself is one registered tool whose argument is a program.
Its description carries the module index and public types admitted by
each seam. The committed, generated `tools/prelude` also supplies full
signatures and documentation through `fs_read` at `cap://<module>`.
Both views use the host's offered-seam allowlists, and the description
is fixed for the session so that it does not move the cached prefix.
`code-mode.md` covers the pipeline behind the tool.

## What the model is shown

The registry is per session, but each strand calls only the tools in
its own durable configuration, `StrandConfiguration.active_tool_names`.
At session assembly, `client/serve` seeds the primary strand's list
with every registered name except `advise`, which only the advisor
strand is granted. A spawned child receives its parent's list,
narrowed to the tools the spawn requested, and loses `agent_spawn` at
the depth cap. An operator can replace a strand's list through the
gateway's `active_tools` configuration key. The gateway refuses any
unregistered name and stores the list sorted and deduplicated.

Two surfaces reach the model:

- **The tool array.** For each generation request,
  `tool_specs` (`client/wiring.gleam:1451`) sorts and deduplicates
  the captured `active_tool_names`, looks each name up in the
  registry, and renders a `ToolSpec(name, description, input_schema)`.
  Unregistered names are dropped. Each provider adapter serializes a
  `ToolSpec` in its own wire shape: `input_schema` for Anthropic,
  `parameters` inside a `function` object for OpenAI chat, `parameters`
  beside `"type": "function"` for OpenAI Responses, and
  `parametersJsonSchema` for Gemini.
- **The prompt index.** The system prompt lists each tool's
  `prompt_snippet` in registration order, so the five core tools come
  before the tools a host added. A tool without a snippet is absent
  from the index and still callable, because the tool array is the
  authoritative definition.

The sort in `tool_specs` exists for the provider's prompt cache. Tool
definitions render ahead of the system prompt and the messages. The
Anthropic adapter places a one-hour cache breakpoint on the last tool
definition and another on the system block, so the tool array is the
byte prefix of both cached regions. Two requests with the same active
set in different orders would render different bytes and miss the
cache on every turn. The sort does not affect authorization, which is
set membership.

For the same reason, a registry reaches a session once. The system
prompt is rendered at session creation and pinned, and the active list
is seeded at the same moment. Installing an extension changes what the
next session offers; a live session keeps the tool array and index it
was created with.

## One call, end to end

A tool call passes through the machine, the runtime, the wiring, the
tool, and, for jailed tools, the broker. `orchestration.md` §"The effect
sandwich" and §"One run, end to end" own the commit sequence; this list
shows where the tool layer enters it.

1. **Planning.** The machine settles the assistant response. When it
   carries tool-call blocks, the next state is a tool batch: one planned
   call per block, in source order, with every result entry id reserved
   up front.
2. **Clearance.** The strand driver consumes any approvals attributed to
   exactly this call, then asks the tool surface to clear it.
   `clear` (`client/wiring.gleam:1503`) refuses a name that is not in
   the strand's `active_tool_names` or not registered; the driver stages the
   refusal as an in-band error result. A cleared call carries the
   model's arguments unchanged and the registration's replay policy,
   which the intent commit persists. Clearance is not an execution
   grant: sandbox policy is composed later, inside the tool.
3. **Scheduling.** The driver's check
   `tool_may_start` (`runtime/strand_runtime.gleam:2751`) starts a
   call only if no `Exclusive` tool is running, and starts an
   `Exclusive` tool only when nothing else is running. The default
   `tool_execution` setting is `parallel`, so calls to `Concurrent`
   tools in one batch overlap; the gateway key `tool_execution:
   "sequential"` runs a batch one call at a time.
4. **Execution.** The driver spawns an effect process that calls
   `run_tool`. `run_tool` builds the `Ctx`, applies the session's
   approved directory additions and standing permissions to the base
   policy, and calls `tool.dispatch`.
5. **Inside the tool.** The tool decodes its arguments and does its
   work. A jailed tool builds a `CallSpec` from its `requirements` and
   calls `ctx.clear_call`. The broker composes those requirements with
   the session base (`effects.md` §"Composition and narrowing"), and
   the helper runs the command in the jail (`effects.md` §"The jail").
   The tool collects the `CallOutput` chunks and the one `CallSettled`,
   shows each chunk's rolling tail to `observe_output`, and renders the
   settlement. Output over 64 KiB is written to the blob store and
   replaced by a reference with head and tail excerpts.
6. **Settlement.** `run_tool` wraps the outcome as a
   `ToolResultMessage` and returns `ToolCompleted(result, terminate)`.
   The driver stages the result, and materialization places the staged
   results into the tree in source order.

A `PolicyRefused` from the broker can become a human decision without
the tool knowing. The `clear_call` seam that `client/wiring` hands the
tool records the refusal with the escalation plane. On an approval it
clears the same `CallSpec` once more with the approved grants appended.
A second refusal stands in band. `code_mode` clears its effects inside
its own pipeline, so it uses `raise_refusal` to request the same
decision, at most once per call.

## Replay safety and scheduling

`replay` is a statement about what re-executing a call does to the
world. It matters only when a crash lands inside the effect sandwich's
window. A `Never` call is never run again: recovery commits a synthetic
interrupted result under the reserved id. A `Safe` call is re-executed
with its persisted arguments, but only if the tool's current
registration still declares `Safe`, so withdrawing the declaration takes
effect at once. `client/wiring` answers that check from a
`Declarations` table, a projection of each name's `{replay,
execution_mode}` pair. The projection exists so that the closures
copied into every process of a session do not each carry a copy of the
whole registry.

The declarations follow from each tool's effects:

- `bash`, `code_mode`, `remember`, `agent_send`, `advise`,
  `schedule_create`, `schedule_cancel`, the `job_*` tools, and every
  extension tool are `Never`. Each either has an arbitrary external
  effect or mints a fresh identifier per call, so a replay would act
  twice.
- Every other tool is `Safe`. For `fs_read`, `grep`, `history_search`,
  and `context_remaining` the reason is that they only read.
- `fs_write` is `Safe` because writing the same bytes to the same path
  is idempotent. `fs_edit` is `Safe` because its plan is bound to the
  digest of the exact content it was computed against, so a replay after
  the edit landed is rejected as stale (`effects.md` §"Tools").
- `agent_spawn` is `Safe` because the child's name derives from the
  call's durable coordinates, so a replay reconciles onto the same
  child.

`execution_mode` is `Exclusive` for tools that may mutate shared state
(`bash`, `fs_write`, `fs_edit`, `code_mode`, `remember`, `agent_spawn`,
`agent_send`, the schedule writers, `advise`, extension tools) and
`Concurrent` for the rest. The broker pools execution budget per
`{op_id, step_id}`, which is the whole batch
(`docs/adr/005-budget-pooling-granularity.md`). A `Concurrent` tool that
clears through the broker must therefore declare enough outstanding
headroom for its siblings, or a second concurrent call is refused.
`grep.max_concurrent_searches` is that declaration for `grep`.

## Invariants

- **A tool's arguments never carry its identity.** The strand,
  operation, step, and source index come from the driver through `Ctx`.
  `agent_note` writes under `agent/{caller}/`, and `advise` is judged
  against `Ctx.strand`.
- **A tool asks for exactly what it needs.** `requirements` is composed
  with the session base by meet, so a tool cannot widen past the base.
  `bash` asks for the base's own writable roots, readable roots, and
  network rather than restating fixed ones, because a fixed request
  would narrow every call below what the operator configured.
- **Harness-side filesystem tools enforce their own containment.**
  `fs_*` do not pass through the jail, so they resolve every path
  against the real filesystem, refuse anything that lands outside the
  workspace, and refuse writes to `protected` paths after resolution.
  `effects.md` §"Tools" and `packages/tools/CLAUDE.md` give the details.
- **A blob address is established by rename.** The blob store writes the
  bytes under a temporary name in the same directory and renames them
  into place, so a crash cannot leave a partial file under a SHA-256
  name.
- **Foreground timeouts are clamped in the tool.** `bash` defaults to 120
  seconds with a 600-second ceiling; `grep` is capped at 60 seconds. A
  background job's wall is the jobs host's to grant.

## The tool set

The table lists every tool the tree registers. "Harness VM" means Loom's
own code runs in the harness on the model's arguments; no
model-authored code runs there, which is what Rule Zero requires.
"Jailed" means the effect runs in a kernel sandbox behind the broker.

| Tool | Purpose | Where it runs | Covered in depth |
|---|---|---|---|
| `bash` | Run a shell command in the workspace; with `mode: "background"`, start it as a job and return a job id. | Jailed (broker, helper) | `effects.md` §"Tools", §"The shell tools" |
| `grep` | Search the workspace with ripgrep (`rg --json`), returning structured matches. | Jailed (broker, helper) | `effects.md` §"Tools" |
| `fs_read` | Read a text file as hashline-anchored lines in a window, or an image file as an image block. | Harness VM | `effects.md` §"Tools" |
| `fs_write` | Write a whole file, creating parent directories. | Harness VM | `effects.md` §"Tools" |
| `fs_edit` | Apply hunks addressed by `{line, anchor}` pairs, bound to a file digest. | Harness VM | `effects.md` §"Tools" |
| `code_mode` | Submit a Gleam program; runs, launches, or interacts with a code-mode execution. | Shell in the harness; build and program jailed (hermetic build, satellite node) | `code-mode.md` |
| `agent_spawn`, `agent_wait`, `agent_send`, `agent_note`, `agent_notes`, `agent_roster` | Spawn child strands, wait on them, message them, and read and write the blackboard. | Harness VM | `messaging.md` |
| `job_poll`, `job_kill`, `job_send` | Read a background job's output, stop it, or write to its stdin. | Harness VM; the job's command runs jailed | `effects.md` §"Background jobs" |
| `history_search` | Search the repository's full-text index of past sessions, or read one entry. | Harness VM | `events.md` §"Search" |
| `remember` | Write one note into the repository's durable memory. | Harness VM | `memory.md` §"The `remember` door" |
| `context_remaining` | Report the calling strand's context window, usage, and next compaction boundary. | Harness VM | `compaction.md` §"Triggers and context introspection" |
| `schedule_create`, `schedule_list`, `schedule_cancel` | Create, list, and cancel the model's scheduled heartbeats. | Harness VM | `automation.md` §"Scheduled heartbeats" |
| `advise` | The advisor strand's verdict: `quiet`, `nudge`, or `block`, plus `continue` and `complete` for a goal feed. Active on the advisor strand only. | Harness VM | `advisor.md` |
| `load_skill` | Load a skill's instructions by name. | Harness VM | `docs/skills.md`; `client.md` §"Skill discovery and activation" |
| `peer_describe`, `peer_roster`, `peer_send` | Set this session's peer description, list linked sessions, and send to a peer. | Harness VM | `messaging.md` §"Explicit peers and background workflows" |
| Extension tools | Whatever an installed extension's manifest declares. | Jailed (the extension's satellite) | `extensions.md` |

Several modules in `packages/tools` sound like tools and are not. None
of them is registered:

- `tools/blob` is the overflow store that `bash`, `grep`, and
  `history_search` write large output to.
- `tools/tail` is the bounded rolling output window shared by the
  foreground collector and `client/jobs`.
- `tools/search` is the harness half of the `cap/search` capability,
  reached only from a `code_mode` program.
- `tools/hashline` is the pure anchor, plan, and apply core behind
  `fs_read` and `fs_edit`.

## Where the code lives

| Path | What it holds |
|---|---|
| `tools/tool.gleam` | `Tool`, `Ctx`, `ToolOutcome`, `Registry`, `Declarations`, `dispatch`, argument decoders, schema builders, requirement shapes, the broker seam, event collection, and the standard refusal renderings. |
| `tools/bash.gleam`, `tools/grep.gleam` | The two jailed core tools. |
| `tools/fs.gleam`, `tools/hashline.gleam` | The filesystem tools, path containment, and hashline anchoring. |
| `tools/blob.gleam`, `tools/tail.gleam` | Output overflow and the rolling output window. |
| `tools/permissions.gleam`, `tools/directory_access.gleam` | The optional `permissions` argument and explicit directory additions. |
| `tools/agent.gleam`, `tools/job.gleam`, `tools/history.gleam`, `tools/remember.gleam`, `tools/schedule.gleam`, `tools/context.gleam`, `tools/advise.gleam`, `tools/codemode.gleam` | The shells over host seams, one module per family. |
| `tools/prelude.gleam` | Generated public-type prefixes for the description and full capability declarations for `cap://` reads (`make gen-prelude`). |
| `client/contributions.gleam` | `Origin`, `Contribution`, `built_in`, `deactivate`, and the collision-checked `registry`. |
| `client/serve.gleam` | Session assembly: opens the planes, builds the contribution list and registry, seeds `active_tool_names`, renders the prompt index. |
| `client/wiring.gleam` | The effect seam's tool surface: `clear`, `run_tool`, `tool_context`, `tool_specs`, `replay_still_safe`, `execution_mode`, and the escalating broker runner. |
| `client/skill_tool.gleam`, `client/peers.gleam`, `client/extension/dispatch.gleam` | Tools defined outside `packages/tools`: `load_skill`, `peer_*`, and extension tools. |
| `client/gateway.gleam` | The `active_tools` and `tool_execution` configuration keys. |
| `runtime/effects.gleam` | `ToolSurface`, `ToolRun`, and the runtime's `ToolOutcome`. |
| `runtime/strand_runtime.gleam` | Effect-process spawning, batch scheduling, and the conversion of a dead tool worker into a synthetic result. |
| `provider/model.gleam`, `provider/adapter/` | `ToolSpec` and its per-provider serialization. |

Each path is relative to its package's source root: `tools/tool.gleam`
is `packages/tools/src/tools/tool.gleam`. `packages/tools/CLAUDE.md` is
the denser per-type reference for the `tools` package.
