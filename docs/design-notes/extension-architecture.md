# Extensions: out-of-tree capability that never touches the TCB

Status: ruling, built through phase 3 (see the status paragraph before
"Phase 5"). The two decisions that outlive one change are
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
openly where they do not. The table is the whole vocabulary: the seven
of phase 3, plus the two phase 4c added for the extension classes that
were otherwise unserveable — a compaction note and a usage
notification.

| Loom event | pi event | Fires | Handler may return |
|---|---|---|---|
| `session_start` | `session_start` | the session server booted the extension | nothing |
| `before_agent_start` | `before_agent_start` | a run was accepted, before planning | a fenced message to inject at run start, attributed to the extension (the `schedule/` and `rule/` precedent: whose text this is) |
| `context` | `context` | before each provider request | a transform of the message list, applied in load order, bounded by the token cap, over a *copy* |
| `tool_call` | `tool_call` | a tool call was planned, before dispatch | `Block(reason)`, which lands as the in-band refusal the model reads, or nothing. **Arguments are not mutable**: pi mutates `event.input` in place and re-validates nothing; Loom refuses that on purpose, since a hook that rewrites a call's arguments after vetting is the one thing the vetting cannot see |
| `tool_result` | `tool_result` | a tool settled, before the reply is committed | a transform of the reply content, chained; `is_error` cannot be cleared by a hook |
| `agent_end` | `agent_end` | a run reached a terminal state | nothing. **Diverges in phase 3**: the event carries the operation and no outcome word. It rides on `effects.Hooks.run_end`, which is handed an `OpId` and asked *before* the terminal transaction commits, so the harness does not yet know how the run ended; a word invented there would be one an author could not tell from a real one |
| `before_compact` | (none; pi has no compaction event) | the runtime decided to compact, before the summary generation starts | an optional note, appended to the summarizer's input fenced and attributed to the extension, bounded by the same token cap a `context` transform gets. **Never a veto**: the compaction is already decided and no answer stops it — see the divergence paragraph below |
| `usage` | (none; pi's tracing extensions read the provider) | one cost-ledger row was committed | nothing. Notify-only, carrying the row's numbers and coordinates and nothing else — no request, no response, no model text, and not the row's opaque `details`. Loom has no provider hooks by ruling, and this is what the tracing extensions (Braintrust, LangSmith, OTel, Langfuse) actually need from one |
| `agent_settled` | `agent_settled` | the run and every follow-up it queued are done | nothing. **Not produced in phase 3**: the harness has no signal for it. `api.await_strand_result` answers for one run, and the follow-up queue is planner-internal with no terminal edge to hang the event on. The bus carries the event and the manifest accepts the name, so a later producer costs one call; until then a declaration is logged `extension.hook.inert` at boot rather than left to look like it fired |

Divergences stated once: no `before_provider_headers`, `before_provider_request`
or `after_provider_response` (provider ownership is TCB); no `input`,
`user_bash`, `ui_prompt_*` or any `ctx.ui` **in the harness vocabulary**,
because those are the client's moments and the client is a separate
process over a frozen gateway (the client surface has its own ruling,
below); no `session_before_*` **cancellation** hooks (navigation and
compaction are durable-plane decisions; a veto from the jail on a commit
boundary needs an argument this note does not make). Phase 4c built the
non-vetoing half of that shape instead: `before_compact` fires once the
runtime has decided to compact, and the most an extension can do is add
an attributed note to the summarizer's input. That needs no veto
argument, and it is safe under the durable-state rule for the same
reason `context` is — the note is transient input to a request whose
consuming commit is the summary. There is deliberately no
`before_navigate` sibling: nothing has asked for one, and a hook with no
caller is a wire shape that rots. Also no
`registerProvider`, `setModel`, `setActiveTools` (routing and the tool
set are the operator's, through `loom.toml` and `set_config`).

### The rest of pi's surface, mapped

- `appendEntry` maps onto a reserved fact prefix, `ext/<name>/`, that the
  extension owns: durable, latest-wins cells the extension writes through
  `ext.remember`/`ext.recall`, never sent to the model unless the
  extension injects them. Same door as `schedule/config/…`.
- `registerTool` over a **built-in** name is refused, and the refusal is
  the boot-time collision `client/contributions` raises. pi extensions
  such as `hashline-edit` replace a built-in outright; here an install
  that silently redefined what the model's `fs_edit` call does would make
  every sandbox argument in this tree an argument about the wrong
  function, and nothing in the manifest an operator reads would say which
  one they got. The operator keeps the decision instead: a built-in named
  in `LOOM_DISABLE_TOOLS` is not registered at all, so its name is free
  and an extension's tool of that name is admitted with no collision to
  refuse. An active built-in still collides; a deactivated one yields.
  Deactivation reaches built-ins only, because deactivating a *peer*
  extension's tool would hand one extension's name to another by
  configuration.
- `sendMessage` maps onto a fenced, attributed injection through the
  session's own admission doors (`api.steer_marking`-shaped), which is
  how scheduled heartbeats already speak.
- `exec` is `cap/proc` under policy, which is what it should have been.
- `registerCommand`, `registerShortcut`, `registerFlag`, `input`,
  `user_bash`, `ui_prompt_*` and `ctx.ui` are the **client surface**, and
  it is a different surface area rather than a missing one. The TUI is
  its own process over the gateway, so an extension's client body would
  run there, in the operator's terminal and outside the harness VM: Rule
  Zero is not the question, keystroke custody is. That surface is ruled
  separately, once the harness surface below is built, with the manifest
  growing a `[client]` table under that ruling; the one constraint fixed
  now is that a client body is operator-installed only and never
  agent-authored, because the promotion ladder's on-ramp ends at the
  jail. Phases 1 to 4 decode no `[client]` table, and a manifest carrying
  one is refused as an unknown key until the ruling lands.
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
- `loom ext install <source>` fetches the tree into a staging directory,
  decodes the manifest, vets the source, compiles it against the
  toolchain the release already ships for code mode, and writes an
  **install record**: name, version, the resolved revision, the source
  tree digest, the allowlist and net policy it was vetted against, and
  the approval. Anything that fails is refused naming the layer, and the
  staging directory goes with it; the record is written last and the
  tree is renamed into place only once it exists. `loom ext list` and
  `loom ext remove <name>` complete the set. No hot install in phase 1:
  the session server reads the records at boot.
- `loom.toml` gains nothing per extension. The manifest is the source of
  truth and the install record is the approval. The one operator-side
  knob is the env variables the secret bindings name, which live in the
  server's environment exactly as `api_key_env` values do.

### Hardening the install

The install is the one network-bound step in the whole design, and it
runs as the operator on the host, outside any jail. So it gets the same
treatment Decision 2 gives the extension: **it needs a tree fetched, not
a git session**, and the fetch is made by the broker's HTTP client under
an install policy rather than by a git binary.

- **No git client.** `git clone` is a large, remotely driven attack
  surface (a hostile remote chooses the pack, the refs, the attributes,
  the submodules), and nothing in an install needs it. A source is one
  of: a local path, copied; an `https://` URL naming a `.tar.gz`; or an
  `https://github.com/<owner>/<repo>` URL, which resolves to the host's
  archive URL for the revision. `git://`, `ssh://`, scp-style and
  `file://` sources are refused by the decoder.
- **Pinned by content.** `--rev` names a commit, tag or branch; without
  it the default branch head is resolved once. Either way the record
  stores the resolved revision and the digest of the extracted tree,
  and every later load re-digests the tree against the record. A
  changed tree is refused until it is re-installed, so an install is
  content-addressed from the moment it is recorded, whatever the remote
  does afterwards.
- **The fetch is a policed request.** Host is the URL's host and
  nothing else, method `GET`, redirects followed only to the same host
  and at most twice (GitHub's archive redirect is one), a response cap
  of 32 MiB, one deadline for the whole transfer. This is Decision 2's
  policy shape with a fixed allowlist of one, served by the same
  client, so the extension path and the install path share one HTTP
  surface and one set of caps.
- **The archive is untrusted input.** Extraction is total: every entry
  must be a regular file or a directory under one top-level directory;
  symlinks, hard links, devices and absolute or `..` paths refuse the
  whole archive; names are confined to a printable subset with no
  control characters; there is a per-file cap, a total-bytes cap and an
  entry-count cap. Extraction writes into staging, never into the
  extension directory, and the digest is computed over the extracted
  tree, not the archive bytes.
- **A repository is not an installed extension.** What is installed is
  the extension's own tree — `src/**/*.gleam`, `schema/**`, `skills/**`,
  `extension.toml`, `gleam.toml`, `README*`, `LICENSE*` — and
  everything else the archive carries is **pruned before anything else
  happens**: `test/`, `.gitignore`, `.github/`, documentation, a
  `build/` directory, and Gleam's own resolved `manifest.toml`, which
  is regenerated rather than read. Pruned rather than refused, because
  every real Gleam repository has all of those and refusing one for
  having a test would refuse them all; the precedent is the `.git`
  directory a local install already walks past. The digest is taken
  over what survives, so it describes the *installed* tree and a later
  load compares like with like. One shape stays a refusal: a
  non-`.gleam` file under `src/`, which Gleam would compile and link —
  `@external` with the declaration moved out of the source the lint
  reads — and which pruning would silently drop.
- **The compile is offline and jailed.** The toolchain runs inside the
  same sandbox code mode builds in, with the network namespace empty:
  a `gleam.toml` that names any dependency beyond `loom_ext` and the
  standard library is refused before the build starts, the shipped
  cache is the only package source, the `gleam.toml` the build sees is
  generated rather than the author's, and a build that tries to reach
  out finds nothing to reach. Vetting runs on the source before the
  compiler sees it, so the compiler is never the first thing to touch a
  hostile file.

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

**What phase 2 built, where it decided something this ruling did not.**
The shape above is what landed (`client/extension/{policy,seam,dispatch}`,
and `serve.extension_contributions` for the boot). Four decisions were
taken along the way and are recorded here rather than in a commit
message:

- **An escalation approval does not widen an extension.** `tool.Ctx`
  carries the grants a human approved for the call being dispatched, and
  a `code_mode` call composes them onto its run phase. An extension does
  not. The operator approved *this extension* once, at install, having
  read a manifest; a grant approved mid-run would widen the jail past the
  terms of that approval, and the two approvals are not the same kind of
  yes.
- **A host with no code-mode toolchain registers no extension tools**,
  and logs why per extension. No `erl` means no satellite to boot, and a
  definition that can only ever fail still renders into the provider's
  cached byte prefix on every request — the argument that already gates
  `code_mode` itself.
- **Every policy refusal reaches the jail under one denial code.**
  `cap/net.map_error` sorts on the code alone, so the vocabulary an
  extension can branch on is "would this policy ever permit this
  request?" (`not_allowed`, or `network_off` for a manifest with no
  `[net]`, or `policy` for the per-execution ceiling) against "it was
  permitted and failed on the wire" (`net_failed`, which is `NetFailed`).
  The message names which refusal it was; the code is what stops a retry
  loop.
- **`redirects`, the request timeout and `trust` are the harness's, not
  the manifest's.** The ruling names the allowlist, the methods, the size
  cap, the request ceiling and the secret bindings as manifest keys, and
  those are exactly the five. An author who could set `trust` could pin a
  root of their own choosing, so it is not a key and will not become one.

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

**The hook bus is a `weft/event_manager`.** The harness side of phase 3
is an ordered list of extensions, each holding private state (its
satellite handle, its request budget, its failure count), receiving
every hook event in load order, with a broken one dropped and logged
while its siblings carry on. That is `gen_event`'s shape exactly, and
`weft/event_manager` is the typed binding of it: one handler per
installed extension, the state sealed in the handler's closure, the
`hook_call` round trip made from inside the handler under the cap-call
deadline, and `Failed` as the answer to a satellite that has died. The
notification events (`session_start`, `before_agent_start`, `agent_end`,
`agent_settled`) are `notify`; the gate (`tool_call`) is a `sync_notify`
whose event carries a reply subject, so the harness reads every verdict
after the fan-out returns and any `Block` wins. The two chained
transforms (`context`, `tool_result`) are not a fan-out, because each
handler must see its predecessor's output; they are a fold over the same
ordered list, written in the harness, and if a second consumer of a
chained fan-out appears weft grows the shape rather than Loom growing
a second bus. The manager's own limit applies and is the intended
semantics: a handler stalls the bus for as long as its round trip takes,
and the deadline bounds that.

## Phases and the acceptance test

1. **`loom_ext`, the manifest, vetting, install records, `loom ext`.**
   Exit: `loom ext install` of a fixture extension records an install; a
   hostile fixture (FFI, forbidden import, oversleep at load) is refused
   naming the layer that caught it; a hostile archive (symlink, `..`,
   oversize, off-host redirect, a `gleam.toml` naming a dependency) is
   refused at the fetch or the extraction, and no staging is left
   behind.
2. **Tool registration and jailed dispatch; broker-served `net.request`
   with allowlist, caps and secret bindings.** Exit: the web-search
   repository installs and the model calls `web_search` in a real drive;
   a request to a host outside the allowlist is refused in band; the API
   key is absent from the jail's environment and from every frame on the
   channel, asserted by an e2e that reads both.
3. **Persistent satellite, `hook_call`, and the hook bus** (protocol
   change). Exit: a tier-J `tool_call` gate from a fixture extension
   blocks a call and the refusal names the extension; `context`
   transforms a request within the cap; a hook that oversleeps is killed
   and reported in band; a satellite that dies mid-session is dropped
   from the bus with its reason logged and the run continues.
4. **Tier H: the loader, rollback, and the TCB freeze** (#32, #33). The
   loader compiles a tier-H body from vetted source under a
   harness-controlled module name, checks the compiled artifact's import
   table against the tier-H allowlist before loading it (the runtime
   half of #33's two mechanisms; the vetting lint is the compile-time
   half), runs it under a supervised, time-boxed wrapper, and rolls back
   to the previous artifact when a load or a first call fails. Exit: a
   fixture tier-H `context` hook loads, transforms, and is replaced
   without a restart; a body whose beam imports anything outside the
   allowlist is refused at load naming the module; the freeze test walks
   the TCB modules and shows none is reachable from a loaded body; a
   hook that oversleeps is killed by the wrapper and the extension is
   marked failed in its record.

All four phases are commissioned; phase 2 is the milestone the user
named and phase 4 exists so that the design does not say "never".

**Status, and one divergence this note did not anticipate.** Phases 1
and 2 are built and merged — #175, #177, #178, #179 and #182 for the
install pipeline, the manifest, the seam and `loom ext`, and #196 for
boot registration, jailed dispatch and the broker-served `net.request`.
Phase 2's exit criteria are met, the last of them by a real drive on
2026-09-02: `loom ext install
https://github.com/Roasbeef/loom-web-search` over codeload, and a Kimi K3
session that called `web_search` and answered from Brave's results with
`BRAVE_API_KEY` in the server's environment and nowhere else.
Phase 3 followed on 2026-09-03: #199 for the hook bus, the runtime slots
and the `[[hook]]` half of the manifest, and #200 for the persistent
satellite, the `hook_call` frame pair and the host registry, with the
e2e in `packages/client/test/client/extension_e2e_test.gleam` meeting
the phase's exit criteria over real jailed satellites.
`docs/architecture/extensions.md` is what the tree holds, section by
section. The divergence: this note adopted pi's rule that a tool without
a `prompt_snippet` is silently omitted from the available-tools section,
and the manifest decoder instead makes the field **required**, so a tool
that would be invisible is refused at install rather than installed and
quietly unlisted. A tool the model cannot see is a bug the author cannot
observe, and an install is the one moment where the author is still
present to read the refusal.

**Phase 5, named but not commissioned: LSP and DAP as extensions.** A
language server or a debug adapter is a long-lived JSON-RPC process over
stdio plus a small tool set (`lsp_definition`, `lsp_references`,
`lsp_diagnostics`; `dap_launch`, `dap_breakpoint`, `dap_continue`,
`dap_evaluate`), and nothing in it touches the TCB, so the extension
route is the better home for both than a core tool (#26). Phase 3's
persistent satellite is the piece that makes it possible: the server
process outlives one call as a child the extension starts from
`session_start` through `cap/proc`, in the jail, seeing only the
workspace roots and no network. What the plan does not yet contain is a
grant for binaries: the jail's readable roots would need the toolchain
and the policy would need to name which commands the extension may run,
a `[proc]` table in the manifest beside `[net]`, with the same
per-execution ceiling shape. `cap/lsp` exists today as an allowlisted
stub, and this route retires it.

Phases 1 and 2 touch `broker`
(serving `net.request`), `codemode` (a third seam and its router arm),
`client` (discovery, install records, the registry as a list, dispatch),
`tools` (the prelude digest gate, since `cap/net` grows a served surface),
and a new `packages/ext`; they touch no frozen Part-1 interface. The
promotion ladder's L1 skill store (#30) and L2 candidate pipeline (#31)
become the *agent-authored* on-ramp into the same manifest and the same
install record, rather than a parallel mechanism.
