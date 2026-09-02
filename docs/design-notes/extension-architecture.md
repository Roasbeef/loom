# Extensions: out-of-tree capability that never touches the TCB

Status: ruling, pre-code. The two decisions that outlive one change are
recorded as ADR-007; this note carries the argument, the vocabulary, the
manifest, and the phased plan. The acceptance test for the whole of it is
a new repository under roasbeef that implements web search as an
extension: an operator installs it, and the model has a `web_search` tool
whose API key never enters the jail and never enters `loom.toml`.

## The ask, restated

An extension is written in Gleam, later in JavaScript, lives in its own
repository, is installed by an operator without a Loom release, and is as
capable as a pi extension where the semantics agree: it registers tools
the model calls directly, and it observes and shapes the run through
hooks. Some extensions must run in the jail. It is deliberately **not** an
MCP server, because an MCP server is a tool surface with no hooks and no
say over the run, and **not** a core tool, because a core tool proves
nothing about extensibility. Design §7 called this L2 and L3 of the
promotion ladder; #32 and #100 are the issues; nothing of it is built
(`docs/design-notes/weft-adoption.md`'s successor survey, the re-baseline
of 2026-09-02, found zero extension symbols in the tree).

## What the tree already decides

Three rulings stand and this note does not reopen them.

- **Rule Zero and the frozen TCB.** No model-influenced code runs in the
  harness VM except through §7's compile-from-vetted-source path, and
  storage, the state machine, the broker and the sandbox drivers are not
  runtime-extensible (`docs/loom-design.md` §7; #33). Self-improvement
  grows the tool and hook surface only.
- **Vetting runs on source, and the harness compiles it.** We never load a
  `.beam` we did not compile. The same import and `@external` lint that
  guards L0 guards every rung above it, against a per-rung allowlist.
- **A shim for pi's TypeScript extensions is unavailable**, and the
  reason is our own vetting rather than the port boundary (#98). Porting
  is the route, and #100 asks that the vocabulary be shaped with pi's
  where the semantics genuinely match and diverge openly where they do
  not. The survey behind this note is in the session record; the parts
  that matter are reproduced below.

Two things the tree does not decide, and this note does: **where an
extension's code runs**, and **how an extension reaches the network**.

## Decision 1: two execution tiers, and the jailed one is the default

An installed extension has one manifest and up to two bodies.

**Tier J, the jailed body.** Runs in a satellite under the *extension
seam*: the workspace seam's capability modules, `cap/net` served for real
under Decision 2, and the small `ext` prelude that carries the typed
behaviours. This is §7's L2 prelude ("wider but still capability-stubbed")
made a permanent home rather than a waiting room. A tool call is one
execution of the extension's compiled source with the call's arguments; a
hook is one execution with the event; the capability channel is the only
way out, and the broker judges every effect per call exactly as it does
for a code-mode program. Nothing in the harness VM changes when a tier-J
extension installs. There is no TCB question to answer because nothing
crosses the boundary, and #33's freeze test is satisfied by construction.

**Tier H, the harness-resident body.** §7's L3: hot-loaded under a
harness-controlled module name, confined to the typed behaviours, only
after explicit approval recorded durably, only for a hook or projection
that must see harness state synchronously and cannot be expressed as a
tier-J callback. Tier H is where #32's loader and #33's two freeze
mechanisms apply in full, and it is deliberately the last phase.

The rule that makes this shippable: **a tool is always tier J, and a hook
is tier H only when it cannot be tier J.** Every hook in the vocabulary
below is expressible in the jail once the harness can call into a
satellite (Decision 3). A hook that runs in the jail costs nothing in TCB
exposure and is killed by the same deadline that kills a runaway program.
Tier H exists so that the design does not have to say "never", not
because anything planned needs it.

Why not the other way round, with hooks resident and tools jailed? Because
the hooks are where the risk is. A tool call is a request the model made
and the broker judges; a hook fires on the harness's own timeline with the
harness's own data in hand. Putting the more powerful surface behind the
stronger boundary is the same ordering `code-mode.md` applies to the
orchestration seam: which capabilities travel together is the point.

**JavaScript later, on the same seam.** The satellite protocol is msgpack
frames over an authenticated socket, and the channel does not care what
runs the frames. A JavaScript extension runtime is a second satellite
implementation speaking the same `cap_call`/`hook_call` frames under the
same token and the same policy, vetted by a JavaScript import lint against
the same allowlist. Nothing in Decisions 1 to 3 is Gleam-specific except
the compile step, which for JavaScript is a bundle step the harness also
performs itself.

## Decision 2: the network reaches an extension through the broker

`cap/net` exists and refuses everything, because the design's egress story
was a proxy sidecar that does not exist (`broker/policy.gleam`: proxy-mode
calls fail closed). A sidecar is the general answer for a jailed process
that opens sockets itself. An extension does not need to open sockets. It
needs an HTTP request made on its behalf and the response handed back. So
`net.request` is served the way `fs.read` is served: **the broker performs
the request on the host**, under a policy composed from the extension's
manifest and the operator's grant at install, and returns the response
over the capability channel. No socket ever exists in the jail. The jail's
network namespace stays empty, which is the property every sandbox layer
already enforces and the property the egress proxy was meant to preserve.

What the policy says, per extension:

- an **egress allowlist** of hosts, exact names, no wildcards in the first
  cut, and a request to any other host refused in band naming the list;
- the **methods** permitted, a **response size cap**, a **per-execution
  request ceiling** (the same lifetime-bound shape as the orchestration
  seam's spawn ceiling, for the same reason: a loop pays nothing);
- **secret bindings**: the manifest names an environment variable and the
  header it belongs in for a given host, and the broker injects the value
  when it makes the request. The extension's source never sees the key,
  the jail never holds it, and no frame on the channel carries it. This
  is stronger than pi's model, where the skill's script reads the key
  from the process environment, and it is the property the web-search
  test exists to prove.

`api_key_env` in `client/catalog` already established that a key's *name*
is configuration and its *value* is never in a file; secret bindings are
that rule applied one layer down, to a request the broker makes.

## The vocabulary, shaped against pi's

pi's `ExtensionAPI` has 38 `on(event, …)` overloads plus a registration
surface. The survey classified pi's 78 worked examples: 3 tools-only, 36
hooks-only, 7 tools-plus-hooks, 30 UI-dependent, 2 provider-owning. The
UI-dependent and provider-owning classes are not portable and this note
does not try: Loom's TUI is a separate client over a frozen gateway, and
provider ownership is core. What is left is the class #100 called the
interesting subset, and it is small enough to name every member.

### Tools

`ext.Tool`: `name`, `description`, `parameters` (a JSON schema, a file in
the repository, rendered to the model exactly as a built-in tool's is),
`prompt_snippet` (pi's `promptSnippet`: the one-line entry in the
available-tools section, without which pi omits a custom tool from that
section; Loom adopts the field and the omission rule), `execute`. Execute
takes the decoded arguments, an `ext.Ctx` (the strand, the execution's
deadline, a `report` sink for streaming partials, the same shape as
`cap/report`), and returns `Result(ext.Outcome, ext.Refusal)`. pi signals
a tool error by throwing; Loom returns it, because a refusal is a value
the model reads and a crash is a fault the harness reports. `Outcome`
carries content blocks and an optional `terminate`, adopted from pi's
`AgentToolResult`, whose meaning here is the existing `terminate` on a
tool reply.

### Hooks

Adopt pi's names where the moment and the handler's power match; diverge
openly where they do not. The table is the whole vocabulary of phase 3.

| Loom event | pi event | Fires | Handler may return |
|---|---|---|---|
| `session_start` | `session_start` | the session server booted the extension | nothing |
| `before_agent_start` | `before_agent_start` | a run was accepted, before planning | a fenced message to inject at run start, attributed to the extension (the `schedule/` and `rule/` precedent: whose text this is) |
| `context` | `context` | before each provider request | a transform of the message list, applied in load order, bounded by the token cap, over a *copy* |
| `tool_call` | `tool_call` | a tool call was planned, before dispatch | `Block(reason)`, which lands as the in-band refusal the model reads, or nothing. **Arguments are not mutable**: pi mutates `event.input` in place and re-validates nothing; Loom refuses that on purpose, since a hook that rewrites a call's arguments after vetting is the one thing the vetting cannot see |
| `tool_result` | `tool_result` | a tool settled, before the reply is committed | a transform of the reply content, chained; `is_error` cannot be cleared by a hook |
| `agent_end` | `agent_end` | a run reached a terminal state | nothing |
| `agent_settled` | `agent_settled` | the run and every follow-up it queued are done | nothing |

Divergences stated once: no `before_provider_headers`, `before_provider_request`
or `after_provider_response` (provider ownership is TCB); no `input`,
`user_bash`, `ui_prompt_*` or any `ctx.ui` (the client is a separate
process over a frozen gateway, and a projection surface, if one is ever
wanted, is a tier-H `ExtProjection` under its own ruling); no
`session_before_*` cancellation hooks in phase 3 (navigation and
compaction are durable-plane decisions; a veto from the jail on a commit
boundary needs an argument this note does not make); no
`registerProvider`, `setModel`, `setActiveTools` (routing and the tool
set are the operator's, through `loom.toml` and `set_config`).

### The rest of pi's surface, mapped

- `appendEntry` maps onto a reserved fact prefix, `ext/<name>/`, that the
  extension owns: durable, latest-wins cells the extension writes through
  `ext.remember`/`ext.recall`, never sent to the model unless the
  extension injects them. Same door as `schedule/config/…`.
- `sendMessage` maps onto a fenced, attributed injection through the
  session's own admission doors (`api.steer_marking`-shaped), which is
  how scheduled heartbeats already speak.
- `exec` is `cap/proc` under policy, which is what it should have been.
- `registerCommand`, `registerShortcut`, `registerFlag` are client
  concerns and are out.
- Skills: an extension may ship `skills/<name>/SKILL.md` in the Agent
  Skills format. The server surfaces name, description and location the
  way pi does, in the system prompt after the guidance files, and the
  model loads the body with `fs_read`. This is #139's playbook mechanism
  arriving as a side effect of extensions, and it should be tracked there.

## The manifest

`extension.toml` at the root of the extension repository:

```toml
[extension]
name = "web_search"            # [a-z][a-z0-9_]*; becomes the module prefix
version = "0.1.0"
description = "Search the web with Brave Search."
license = "MIT"                # a port of an MIT extension carries its notice here
tier = "jailed"                # the only value phase 1 accepts

[[tool]]
name = "web_search"
description = "…"
prompt_snippet = "web_search: search the web and read result pages"
parameters = "schema/web_search.json"
entry = "web_search/tool"      # the Gleam module implementing ext.Tool
timeout_ms = 20000

[[hook]]                       # phase 3
event = "tool_call"
entry = "web_search/gate"

[net]
hosts = ["api.search.brave.com"]
methods = ["GET"]
max_response_bytes = 1048576
requests_per_call = 4

[[net.secret]]
env = "BRAVE_API_KEY"          # the variable's *name*; the value is never in a file
host = "api.search.brave.com"
header = "X-Subscription-Token"
```

The Gleam side is an ordinary package whose `gleam.toml` depends on
`loom_ext` (new, small, published to hex: the `ext` prelude and the typed
behaviours) and on nothing vetting refuses. Vetting runs on every source
file in the package against the extension allowlist at install and again
at every load; a file that stops passing refuses the whole extension in
band naming the rejection. The manifest is a total decode; an unknown
key is a parse error, as it is for `loom.toml`.

## Discovery and install

Operator-driven and restart-to-change, the trust decision `client/catalog`
already makes for MCP servers, with one difference: the approval is
recorded rather than implied by editing a file.

- Extensions live under `~/.loom/extensions/<name>/` (operator-wide) or
  `<workspace>/.loom/extensions/<name>/` (per project). A workspace
  extension is listed and never loaded until the operator approves it,
  the posture `AGENTS.md` takes toward workspace files and pi takes with
  project trust.
- `loom ext install <git-url | path>` clones or copies into the operator
  directory, decodes the manifest, vets the source, compiles it against
  the toolchain the release already ships for code mode, and writes an
  **install record**: name, version, source digest, the allowlist and net
  policy it was vetted against, and the approval. Anything that fails
  vetting is refused naming the layer. `loom ext list` and
  `loom ext remove <name>` complete the set. No hot install in phase 1:
  the session server reads the records at boot.
- `loom.toml` gains nothing per extension. The manifest is the source of
  truth and the install record is the approval. The one operator-side
  knob is the env variables the secret bindings name, which live in the
  server's environment exactly as `api_key_env` values do.

## Tool registration and dispatch

At boot the server reads each install record, re-vets the source, and
registers each manifest tool in the tool registry with its schema,
description and prompt snippet. The registry seam becomes a list of
contributions rather than the fixed positional signature `registry(...)`
in `client/serve` has today; the re-baseline named that literal as one of
the closed seams, and this is the change that opens it. A call to an
extension tool becomes one execution: the host stands up a satellite with
the extension's compiled artifact, hands it the call's arguments and a
capability token bound to the extension's policy, and settles the outcome
as a tool reply. Latency is a satellite boot per call, which the hermetic
build cache already makes acceptable for code mode. A persistent
per-extension satellite (Decision 3) removes it later.

## Decision 3 (phase 3): a persistent extension satellite, and callbacks

Hooks need the harness to call into the extension: `tool_call` fires on
the harness's timeline. `cap_call` flows satellite → broker and the
protocol has no reverse direction (#98). Phase 3 adds one: a `hook_call`
frame harness → satellite over the same authenticated channel, answered
by `hook_result`, with the deadline discipline of a cap call, and a
satellite that lives for the session hosting the extension's actors (the
"satellite kept alive across calls" mode `code-mode.md` describes as not
built, whose reaping invariant already has its guard). With that, tier-J
hooks exist, tool calls stop paying a boot each, and tier H shrinks to
what genuinely needs harness state. This is a `protocol-change/` proposal,
not drift, and it is written before phase 3 starts.

## Phases and the acceptance test

1. **`loom_ext`, the manifest, vetting, install records, `loom ext`.**
   Exit: `loom ext install` of a fixture extension records an install; a
   hostile fixture (FFI, forbidden import, oversleep at load) is refused
   naming the layer that caught it.
2. **Tool registration and jailed dispatch; broker-served `net.request`
   with allowlist, caps and secret bindings.** Exit: the web-search
   repository installs and the model calls `web_search` in a real drive;
   a request to a host outside the allowlist is refused in band; the API
   key is absent from the jail's environment and from every frame on the
   channel, asserted by an e2e that reads both.
3. **Persistent satellite and `hook_call`** (protocol change). Exit: a
   tier-J `tool_call` gate from a fixture extension blocks a call and the
   refusal names the extension; `context` transforms a request within
   the cap; a hook that oversleeps is killed and reported in band.
4. **Tier H behaviours, hot load, rollback, TCB freeze** (#32, #33), only
   for what phase 3 cannot express.

Phase 2 is the milestone the user named. Phases 1 and 2 touch `broker`
(serving `net.request`), `codemode` (a third seam and its router arm),
`client` (discovery, install records, the registry as a list, dispatch),
`tools` (the prelude digest gate, since `cap/net` grows a served surface),
and a new `packages/ext`; they touch no frozen Part-1 interface. The
promotion ladder's L1 skill store (#30) and L2 candidate pipeline (#31)
become the *agent-authored* on-ramp into the same manifest and the same
install record, rather than a parallel mechanism.
