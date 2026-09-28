# Design note: tool search, and whether code mode replaces it

Status: **note, not a work package.** Research only; nothing here is
built, and nothing here changes a frozen interface. It asks whether Loom
needs the mechanism Claude Code calls *tool search* — schemas fetched on
demand instead of loaded up front — and ends with three verdicts: one for
the model's own tool surface, one for code mode, and one for what the
deferred MCP work in `docs/spec-gaps.md` should become.

**Status, 2026-08-28: the MCP half is superseded; the tool-search half
stands.** Issue #106 decided and shipped what this note only proposed —
per-server generated `cap/mcp/<server>` modules, no registry entries and
no generic dispatcher — so read `docs/architecture/mcp.md` for the living
account of how a server reaches a model, and this note only for how the
question was arrived at. Two things below are stale on their face: the
MCP specification citations are pinned to revision 2025-06-18, which was
current when this was written and is now two revisions behind, and the
open questions about whether a generated module rebuilds cleanly inside a
vendored prelude have been answered by building it. The September 27 census revisits the verdict on search for Loom's own
surface. The distinction between module namespace as index and compiler
as oracle still holds. The signature-oracle gap is now closed by indexed
public types in the `code_mode` description and full declarations through
`fs_read cap://<module>`. The array census and illustrative pricing below
were refreshed on 2026-09-27; the MCP proposal sections remain the
historical argument.

External claims are sourced. Where I could not verify something, it is
marked, and the estimates are labelled as estimates rather than dressed
up as measurements.

## What tool search actually is

Tool search is a **server-side tool on the Messages API**. You put a
search tool in the `tools` array — `tool_search_tool_regex_20251119` or
`tool_search_tool_bm25_20251119` — and set `defer_loading: true` on the
tools that should not load up front. Claude's context starts with the
search tool and whatever you left non-deferred. When it needs something
else, it searches; the API returns matching tools as `tool_reference`
blocks and expands each into a full definition before Claude sees
it.[^ts-docs]

Three mechanics matter more than the headline, and two of them are easy
to get wrong from the summary alone.

**`defer_loading` controls context, not transmission.** The
documentation is explicit: "You still send every tool's full definition
in the `tools` array on every request, including the deferred ones. The
API needs them server-side to run the search and expand `tool_reference`
blocks."[^ts-docs] Deferral saves billed input tokens and model
attention. It saves no bandwidth, and it does not shrink the request a
harness has to build.

**Caching is preserved by exclusion, not by cleverness.** "Internally,
the API excludes deferred tools from the system-prompt prefix. When
Claude discovers a deferred tool through tool search, the API appends a
`tool_reference` block inline in the conversation, then expands it into
the full tool definition before passing it to Claude. The prefix is
untouched, so prompt caching is preserved."[^ts-docs] A discovered tool
becomes part of the *conversation*, which sits after the head in render
order, so the head's bytes never move. This is the property that makes
tool search different in kind from a harness swapping its own tool array
between turns — see the pricing section.

**A deferred tool cannot carry a cache breakpoint.** "A tool with
`defer_loading: true` can't also carry `cache_control`: the API returns a
400. Put the cache breakpoint on a non-deferred tool."[^ts-docs] At least
one tool must stay non-deferred, and the search tool itself must never be
deferred.

The problem it solves is stated in two halves. Context: "A typical
multiserver setup (GitHub, Slack, Sentry, Grafana, and Splunk) can
consume ~55k tokens in definitions before Claude does any work. Tool
search typically reduces this by over 85 percent." Accuracy: "Claude's
ability to pick the right tool degrades once you exceed 30–50 available
tools."[^ts-docs] The engineering post puts numbers on the accuracy half
— Opus 4 from 49% to 74%, Opus 4.5 from 79.5% to 88.1% on internal MCP
evaluations.[^atu] Those are Anthropic's own figures on Anthropic's own
evals; I have no independent measurement.

### What it costs

The obvious cost is a round trip: a search before the first call. The
interesting cost is the one the brief names — a search that misses is a
capability the model never learns it has, and it *fails silently*. "A
search that matches nothing returns a `tool_search_tool_search_result`
with an empty `tool_references` array, not an error."[^ts-docs] The
documentation's own troubleshooting entry is titled "Claude doesn't find
expected tools," and its advice is to write better descriptions and add
keywords.[^ts-docs] For the regex variant the model writes Python
`re.search()` patterns capped at 200 characters, which means retrieval
quality depends on a model-authored regex over prose nobody wrote for
retrieval.

So the trade is legible: tool search buys a small constant context cost
and better selection among many tools, and pays with a discovery step
whose recall is unmeasured and whose failure is indistinguishable from
"that capability does not exist." That asymmetry is what makes the
comparison with code mode interesting, because a compiler fails loudly.

The feature is not Anthropic-only. OpenAI's Responses API has
`defer_loading` and `tool_search` with both hosted and client-executed
variants, on gpt-5.4 and later.[^oai-ts] Whatever Loom eventually does
here, it is not betting on one vendor's idea.

## Anthropic's position on code execution with MCP

The engineering post *Code execution with MCP* argues the same problem
one step further.[^cem] Its diagnosis has two parts, and the second is
the one Loom's code mode was built for: tool definitions overload the
context window, **and** intermediate results flow through it. Its
example is attaching a meeting transcript to a Salesforce record, where
"the full call transcript flows through twice."

Its proposal is to present "MCP servers as code APIs rather than direct
tool calls" — a file tree of TypeScript modules, one directory per
server, one file per tool, executed in a sandbox. Discovery is by
filesystem: "Models are great at navigating filesystems. Presenting tools
as code on a filesystem allows models to read tool definitions
on-demand, rather than reading them all up-front." A `search_tools`
function with configurable detail levels is offered alongside. The
headline number is a token reduction "from 150,000 tokens to 2,000
tokens — a time and cost saving of 98.7%."

The post names its own cost plainly: "Running agent-generated code
requires a secure execution environment with appropriate sandboxing,
resource limits, and monitoring. These infrastructure requirements add
operational overhead and security considerations that direct tool calls
avoid."

### How Loom's code mode compares, as built

Loom built the expensive half. `docs/architecture/code-mode.md` describes
a shipped pipeline: a `glance`-based vetting lint with token-stream
backstops, a hermetic offline `gleam build --warnings-as-errors` inside a
network-off jail, and execution in a disposable satellite BEAM node whose
only reachable effect is one framed capability channel to the broker.
`make e2e-codemode` drives five scenarios through the real thing.

Three differences from the post's design are real, and only two of them
favour Loom.

**The language is typed and the harness's own.** The post's runtime is
TypeScript on a filesystem. Loom's is Gleam, chosen because pure Gleam
has no `eval`, no reflection, and no dynamic module lookup, so a
program's maximal capability set is the transitive closure of its imports
plus its own `@external` declarations. That is a property TypeScript
cannot offer, and it is the whole reason Loom can run model-written code
with a *source-level* check rather than only a sandbox. The type checker
doubles as the tool-argument validator: a mistyped capability call fails
at compile time, before a node spins up.

**The sandbox story is more than a caveat.** The post treats the secure
execution environment as an acknowledged cost. Loom treats it as the
product: Landlock, seccomp, cgroup v2, bubblewrap namespaces,
`no_new_privs`, rlimits, per-execution pooled budgets, real cancellation
that reaches the executor process group. `make selftest` reports which
layers the running kernel actually provides, and the end-to-end prints
whether network-off was *enforced* rather than merely observed. In the
development container it is not.

**Discovery is where Loom is behind, and this is the point of the
note.** The post's model browses a filesystem: it lists a directory to
learn a server exists, reads one file to learn a tool's signature, and
pays only for what it reads. Loom's model has no filesystem to browse at
authoring time. What it has is the `code_mode` tool description, which
today renders the allowlist inline:

```gleam
<> ". Imports are restricted to: "
<> string.join(list.sort(seam.allowed_imports, string.compare), ", ")
```

That is a flat list of module names in a tool description — structurally
the same shape as a flat list of tool definitions in a tool array, just
two orders of magnitude cheaper per entry, because a module name is
fifteen bytes and a tool schema is several hundred tokens. It scales much
further before it hurts. It does not scale forever, and it says nothing
about what is *inside* a module.

## What MCP's own protocol offers

Nothing, for scale. A client discovers tools with `tools/list`, which
returns full definitions — `name`, `title`, `description`, `inputSchema`,
optional `outputSchema` and `annotations` — with opaque cursor
pagination. Servers that declare the `listChanged` capability send
`notifications/tools/list_changed` when the set changes, and the client
re-lists.[^mcp-tools] There is no query parameter, no filter, no
server-side search, and no partial projection that would let a client ask
for names without schemas.

Pagination is not a solution to context pressure; it is a solution to
response size. A client that pages through 400 tools has 400 tool
definitions, and the question of what to do with them is entirely the
client's. Every scaling mechanism discussed in this note lives above the
protocol.

## Loom as built

**The all-plane built-in registry offers 22 tools at `868dfedd`.** Five
core tools (`bash`, `grep`, `fs_read`, `fs_write`, `fs_edit`), six `agent_*`
tools and `todo`, `code_mode`, `history_search`, `remember`, three
`schedule_*`, `context_remaining`, and three `job_*`. Optional planes are
registered only when the host supplies their seam; extensions can add
more. `client/contributions.built_in` owns this construction, and its
comment states the cost: a permanently refusing definition would be paid
for on every request of every strand for the life of the session.

**The registry offers lookup and dispatch, not search.**
`packages/tools/src/tools/tool.gleam` exposes `registry`, `lookup`,
`names`, `registered`, `declarations`, `snippets` and `dispatch`.
`names` returns sorted names; `lookup` returns a whole `Tool` including
its schema. There is no deferred load or tool-search operation.

**The wire array is built per strand and sorted for the cache.**
`wiring.tool_specs(config, active)` sorts by name, dedupes, drops
unregistered names, and renders each survivor as
`ToolSpec(name, description, input_schema)`. Its comment states the
reason: the array is a strict byte prefix of both cached head regions, so
two requests with the same active set in different orders would miss the
cache entirely. A strand's active set can be narrowed by `agent_spawn`'s
`tools` argument (which may only narrow the caller's own set) or rewritten
by `set_config`'s `active_tools`.

**`ToolSpec` has three fields and no `defer_loading`.** It lives in
`packages/provider/src/provider/model.gleam` and is consumed by both the
Anthropic and OpenAI adapters. Spec §1.5 freezes the gateway signature
rather than spelling out `ToolSpec`, so adding a field is a
package-local change rather than a frozen-interface break — but it is a
change both adapters must answer for, and the OpenAI adapter would need
its own decision about what deferral means there.

**MCP now reaches the model through code mode.** Configured servers
contribute generated `cap/mcp/<server>` surfaces rather than direct
registry entries; [the MCP architecture](../architecture/mcp.md) carries
the implementation. Those generated surfaces add bytes to `code_mode` on
that host and are excluded from the built-in census below.

**One asymmetry worth naming.** The system prompt carries the registry's
session-pinned index; the wire array carries the strand's *active* subset.
Narrowing the active set does not shrink the pinned prompt. The census
below measures the whole advertised built-in array, not one narrowed
strand's request or the system prompt behind it.

## Pricing a dynamic tool surface

`adapter/anthropic` spends all four available breakpoints on every
request, deterministically: two at the one-hour lifetime on the head (one
closing the tool array, one closing the system block) and two at the
five-minute lifetime on the last block of each of the final two user
turns. Reads cost about 0.1× base input; writes cost 1.25× at five
minutes and 2× at one hour.[^caching]

The arithmetic that matters is not the size of the tool array. It is
render order. Tools render first, so **a change to the tool array
invalidates the entire prefix** — the tool breakpoint, the system
breakpoint behind it, and both tail breakpoints behind that. The cost of
a moved tool array includes the conversation behind it, not just the
definitions: the old cache prefix is unavailable and the new prefix pays
the write premium.

### Measured array, estimated tokens

The 2026-09-27 census at `868dfedd8754e1b8a750add24227bd2b83fcd167`
constructs all seven optional planes through
`client/contributions.built_in`, sorts their 22 registered tools by name
as `wiring.tool_specs` does, and passes their real descriptions and schemas
through `provider/adapter/anthropic.build_request`. It extracts the
`tools` array, including the last tool's one-hour cache marker, and
serializes compact JSON with literal Unicode. No provider request is sent.

The fixture has no extensions, MCP servers or model names; Agency wait is
30 seconds, job poll is 30 seconds, schedule limits are `scheduleseam.limits()`, and code mode
has background launch enabled with the default 300000/900000 ms budgets.
It includes the host's notes and peer capabilities. All optional tool
planes remain present in each row so the difference measures only the
code-mode offer. These are construction fixtures, not three live daemons.

| Code-mode offer | Tools | UTF-8 bytes | Unicode characters | Estimated tokens (characters ÷ 4 to ÷ 3) |
|---|---:|---:|---:|---:|
| Explicit effect-only workspace host | 22 | 57,348 | 57,258 | 14.3K–19.1K |
| Orchestration mode alone, current full program surface | 22 | 66,754 | 66,646 | 16.7K–22.2K |
| Both current full program modes | 22 | 68,419 | 68,311 | 17.1K–22.8K |

The fixture is reproducible after building `packages/client`:

```sh
report_dir=$(mktemp -d)
escript scripts/measure_tool_surface.escript "$PWD" "$report_dir"
python3 scripts/measure_tool_surface.py "$report_dir"
```

The scripts retain the exact plane constructors, notes and peer additions,
serialized requests, array hashes and character estimator for this census.

The bytes and characters are measured. The token column is a **character
estimator, not a tokenizer or provider count**; JSON escaping and provider
rendering can change that count. To reproduce it, build `packages/client`,
construct the optional seam records without invoking their closures, use
`vet/policy.workspace_effects()` or `default()`, each widened with
`cap/notes`, for the import lists and
`client/codemode.seam_caps` for the full router vocabulary, then serialize
`anthropic.build_request`'s `tools` field. Record the plane configuration
with any new measurement: a host without jobs, schedules, a toolchain or
an extension has a different array.

The description grew deliberately. The earlier full-signature rendering
kept type declarations (then estimated at roughly 40% of that rendering)
because a program must be able to name and inspect a returned `proc.Output`.
The current rendering keeps the module index and public types, including
fields, variants and their documentation, in the standing description;
full functions, constants and docs are read through `fs_read cap://<module>`
in the conversation. In the both-mode fixture those module/type blocks
occupy 29,758 of the description's 36,823 characters (about 81%). That
measures the documented blocks, not bare declarations, so it does not
repeat the old 40% as a current figure.

`signature_sections` filters by each offer's allowlist and renders shared
modules once. A genuinely narrow orchestration offer pays only for its
imports; an effect-only workspace host omits `cap/strand` and
`cap/workflow`. The default server now admits the same full program surface
on both modes under [protocol 048](../../protocol-change/048-async-collaboration.md),
so selecting orchestration alone no longer avoids the workspace modules.
Adding the second full mode costs 1,665 characters in the array for
mode selection and guidance, rather than a second copy of the shared types. Per-offer filtering still bounds a custom
host's cost, and sharing prevents duplicate payment on the default host.

At an **illustrative base input rate of $5 per million tokens**, the
both-mode estimator gives $0.171–$0.228 for a one-hour tool-array write at
2×, versus $0.0085–$0.0114 for a read at 0.1×. These figures exclude the
system prompt and conversation and are not a current model-price quote.
For a measured token count `T` and input rate `R` dollars per million,
the corresponding costs are `2 × T × R / 1_000_000` and
`0.1 × T × R / 1_000_000`. The twenty-fold ratio survives the correction.

The larger cost is the conversation behind the array. At that same
illustrative rate, a hundred-thousand-token prefix costs five cents to
read from cache and fifty cents at base input, before write premiums.
**A tool surface that changes per turn costs the cache behind it.**

This is precisely why Anthropic's tool search puts discovered
definitions *inline in the conversation* rather than in the `tools`
array. It is also why `agent-comms-and-system-prompt.md` already
concluded that eight differently-equipped children pay the head write
eight times, and recommended one standard worker set instead. And it is
why any Loom-side scheme that mutates the rendered array between turns
is disqualified on arithmetic before anyone argues about its merits.

One further constraint, from the API rather than the arithmetic: Loom
hangs the head's one-hour breakpoint on the *last* tool definition. If
that tool were deferred, the request would be rejected with a 400. Adding
`defer_loading` to Loom would mean moving the head breakpoint to the last
non-deferred tool and keeping the deferred ones behind it — a small change
to `encode_tools`, but not a no-op, and one that must be got right or the
head silently stops caching.

## The tension: reaching an MCP tool without dissolving the bound

Code mode's security argument is one sentence: a program's maximal
capability set is the transitive closure of its imports plus its own
`@external` declarations. Vetting reads the import list and knows the
bound. So how does an MCP tool become reachable from a program?

First, a correction to how the problem is usually stated. A generic
`cap/tools.invoke(name, args)` does not falsify the theorem. Vetting
would still compute a correct upper bound on what the program can do —
the bound would just be *the whole registry, for every program*. The
theorem survives; its discriminating power collapses. That distinction
matters, because it tells you what the fallback actually is. With a
name-indexed dispatcher on the allowlist, the import list stops sorting
programs into capability classes and the broker's per-call policy check
becomes the only thing that discriminates. That is not "no security." It
is one layer instead of two, which is exactly the arrangement code mode
was built to avoid: "Escape from this design requires *both* a vetting
bypass and a kernel escape, which is the point of having two layers
rather than one strong one."

So the four options are not four mechanisms. They are four positions on
one dial — how finely the import list partitions capability — and the
broker sits underneath all of them.

### Generated per-server cap modules

Turn a server's `tools/list` into a typed Gleam module the program
imports: `import cap/mcp/github` gives `github.create_issue(repo, title)`
with real types. Vetting's allowlist admits `cap/mcp/github`; the program
that never imports it cannot call it.

The mechanics are cheaper than they first look. `vet/policy` is already a
value — `policy.new(names)` plus a pipeable `allow` — and the `CodeMode`
seam already carries its own `allowed_imports`, which is how the
orchestration note proposed two prelude sets over one pipeline. A build
root already gets a fresh clone of the vendored prelude, so the compile
service could
write generated modules into that clone before building. The seed's
dependency table is unchanged, so `seed.verify` still passes.

Three costs, in increasing order of seriousness.

*Build latency.* The seed ships `vendor/cap` pre-compiled. Adding source
files to the clone means Gleam recompiles the `cap` package on every
code-mode call, on top of the program itself. Code mode already pays a
compile per execution; this makes that compile bigger, and the size
scales with how many servers are configured rather than with what the
program imports.

*The bound is per server, not per tool.* `import cap/mcp/github` grants
all sixty of GitHub's tools. That is coarser than a per-tool grant. It is
also, I think, the right granularity — a human decides to trust a server,
not a tool — but it should be stated rather than discovered.

*Untrusted input becomes compiled source.* This is the one that belongs
in a scope document. `tools/list` output is attacker-controlled JSON from
a third-party process. Generating Gleam from it means a hostile server
gets to influence module names, function names, type names, and doc
comments in source the harness compiles and vetting's allowlist admits.
Loom's vetting is aimed at *model*-written source; nothing today vets
harness-generated source. The defenses exist and are already written —
the ASCII grammar gate in `vet/policy.is_legal_module_name`, the pinned
module name that closes prelude shadowing, `--warnings-as-errors` — but
they are aimed elsewhere, and pointing them at a code generator is work
with its own adversarial corpus.

### A discovery-only capability

A capability that lists servers and reads schemas but cannot invoke costs
nothing in capability terms, because reading a schema is not an effect.
The brief asks whether it is useful alone. It is not — but the question
is aimed at the wrong layer.

The need is at *authoring* time, and a `cap/*` module cannot serve it. By
the time a program is running, the model has already committed to a
program. A running program that discovers a tool it did not import cannot
call it, and a program that loops "discover, then invoke" is the generic
dispatcher wearing a costume.

Relocate it and it becomes the single most useful thing in this note. See
the next section.

### Demote the import list; let the broker be the bound

Ship `cap/tools.invoke(name, args)` and rely on per-call policy. This is
coherent, and it is what most harnesses do. It is wrong for Loom for a
reason specific to Loom: the broker's policy vocabulary is
`SandboxPolicyV1` — writable roots, readable roots, network, env, limits,
scratch. It describes *what a jailed process may touch*. It has no way to
say "this program may call GitHub but not Slack," because an MCP call is
not a filesystem path or a network CIDR. Making the broker the sole bound
for MCP would mean inventing a second policy vocabulary keyed on tool
identity — which is a protocol change to a frozen contract, and a
strictly larger piece of work than generating modules.

### Do nothing

The original twelve-tool census supported doing nothing. The current
22-tool fixture remains below the cited 30–50-tool selection range, but
its character estimator is above the cited 10K-token size threshold.[^ts-docs]
A provider token count and workload measurement now belong before a new
claim that Loom is below every trigger. Size alone does not establish that
a search round trip will improve those workloads.

The reason to reject it is not urgency. It is that WP-G item 9 as written
does not say what MCP exposure looks like, and the cheapest moment to
decide is before the adapter is built rather than after it has shipped a
tool per MCP tool and taught the registry to hold four hundred entries.

## Testing the hypothesis

The brief's hypothesis: code mode does not need tool search because the
compiler is the discovery mechanism — a program imports what it needs,
static types tell it what exists, giving discovery *with* a hard bound
where tool search gives discovery with none.

Half of that holds and half of it does not, and the failure is
instructive.

**What holds: the index is cheap, and the bound is real.** Code mode's
per-capability context cost is a module name. Tool search's is a name
plus enough description for a regex to hit. Loom could list two hundred
`cap/mcp/*` module names in the `code_mode` description for roughly the
token cost of *four* MCP tool schemas. And unlike a search result, an
import is an authorization: the model does not merely learn that
`cap/mcp/github` exists, it commits to it in a way vetting can read. That
is genuinely discovery-with-a-bound, and it is the strongest thing in
this note's favour.

**What does not hold: the compiler is not in the loop when the program is
written.** The model authors source blind and submits it. There is no
autocomplete, no hover, no `gleam lsp`. The compiler's knowledge of
`cap/mcp/github`'s signatures reaches the model only as a *rejection* —
`CompileFailed`, one round trip, with whatever Gleam's diagnostic says.
So the honest formulation is:

> The module namespace is the discovery index. The compiler is the
> schema oracle. The index is listed for free; the oracle is reachable
> only by being wrong first.

Against tool search that is a real trade rather than a win. Tool search
fails *silently and cheaply* — an empty result set, and a capability the
model concludes does not exist. Code mode fails *loudly and expensively*
— a compile error, a fixable one, and a wasted round trip that includes a
hermetic build. Loud beats silent for correctness. It loses badly on
latency, and it loses worse as the surface grows, because the model's
prior about what a generated module contains gets weaker the further the
module is from the hand-written prelude it has seen described.

**The gap has an obvious, cheap closure, and it is not a capability.**
Give the model a *harness tool* — one entry in the array, constant size
regardless of how many servers exist — that returns the public function
signatures of an allowlisted module. Call it `code_mode_signatures(module)`.

It is worth being precise about why this is not tool search wearing a
different hat, because it looks like it.

- What it returns is **documentation, not authority**. A tool-search
  result expands into a callable tool definition; Claude can call what it
  found. A signature listing grants nothing. The program still has to
  import the module, and vetting still reads the import list. Discovery
  and authorization stay separate, which is exactly the property the
  generic dispatcher destroys.
- Its **cost is constant**, and it sits in the head. One tool definition,
  written once, cached at the one-hour breakpoint for the life of the
  session. It never moves, so it never costs a cache write. The variable
  part — the signatures — arrives as a tool *result*, in the conversation,
  after every breakpoint. Structurally identical to where tool search
  puts its discovered definitions, and for the same reason.
- Its **failure mode is bounded**. The argument is a module name from a
  list the model was already given verbatim in the `code_mode`
  description. There is no regex, no recall problem, and no way to
  silently miss something that exists.

That is the answer the hypothesis was reaching for, one layer over from
where it was pointed: code mode does not need tool *search*, because the
namespace is already the index. It needs the other half — schema on
demand — and that half costs no capability at all.

## Verdicts

**Does Loom need tool search for the model's own tool surface? Re-measure
before deciding.** The original "no, and not soon" rested on an array
estimate the serialized census contradicts. The current character
estimator crosses the roughly 10K-token size trigger, while 22 tools stay
below the roughly thirty-tool count trigger cited here.[^ts-docs] Neither
is a measured accuracy result for Loom. Count the provider-rendered tokens
and compare discovery latency and task accuracy before adopting deferral.
The stable-prefix argument still holds: a harness that changes the array
per turn invalidates the cache regardless of how large the array is.

**Does code mode need anything? Yes: a signature oracle, not a search.**
`code_mode_signatures(module)` — or the same thing folded into the
`code_mode` schema as an optional mode — closes the one real gap between
Loom's discovery story and the filesystem browsing in Anthropic's
post,[^cem] and it closes it without touching the capability bound. It is
worth building *before* MCP, because it also pays for the nine `cap/*`
modules that already exist and whose signatures the model currently has
to guess at.

**Should WP-G item 9 change? Yes — it should split in two.** As written
it is one adapter: "spawn-in-sandbox, schema validation, provenance
tagging, layered on the same `clear_call` path." The transport half of
that is right and unchanged: an MCP server is a third-party binary, it
runs inside an executor sandbox like a language server, and the framing
already exists. The half that is missing is *exposure* — how a model
reaches an MCP tool — and leaving it unstated means it will default to
the obvious thing, which is one registry entry per MCP tool. That default
puts several hundred schemas ahead of the system prompt in the cached
head and several hundred names in a session-pinned prompt block, and then
requires tool search to undo the damage.

The item should say instead:

1. **Exposure defaults to code mode.** An MCP server becomes a generated
   `cap/mcp/{server}` module the vetting allowlist admits, not a set of
   registry entries. `docs/loom-design.md` §5.5 already says "prefer code
   mode over MCP round-trips where possible"; this is what that sentence
   means operationally.
2. **Direct registry exposure is an opt-in, per server, with a budget.**
   Some servers hold two tools a model wants on every turn. Those belong
   in the array. The mechanism should make the operator say so, and
   should refuse to let the array grow past a configured token ceiling
   rather than quietly costing a cache write.
3. **Code generation from `tools/list` is a named trust boundary with its
   own adversarial corpus**, in the same shape as
   `packages/codemode/test`'s vetting corpus: hostile tool names, hostile
   schemas, names that are not legal Gleam, names that collide after
   mangling, schemas that do not map to a total Gleam type.
4. **Signature discovery is a prerequisite, not a follow-up.** Generated
   modules the model cannot introspect are modules the model will call
   wrongly, once per compile round trip.

## What I would not build

- **A generic `cap/tools.invoke(name, args)`.** It does not break
  vetting's theorem; it makes the theorem's answer the same for every
  program, which is worse than breaking it because the loss is invisible.
- **A Loom-side tool-search tool that mutates the rendered tool array
  between turns.** The head is a byte prefix of everything. Any scheme
  that moves it costs the whole conversation's cache, every turn it
  moves. If Loom ever wants deferral, the only correct implementation is
  the provider's, where deferred definitions never enter the prefix and
  discovered ones land in the conversation.
- **A fifth cache breakpoint, or a re-layout to find one.**
  `agent-comms-and-system-prompt.md` already asked and answered this: all
  four are spent, and when two strands want different tool arrays the fix
  is to make the arrays identical, not to find a position.
- **Per-strand bespoke tool subsets as a scaling strategy.** Narrowing is
  already possible through `agent_spawn`'s `tools` and `set_config`'s
  `active_tools`, and it is right for *authority* — a child that cannot
  see `agent_spawn` cannot recurse. It is wrong for *context*, because
  every distinct set is a distinct cache prefix.
- **A `cap/*` discovery module.** Discovery is an authoring-time need and
  a capability is a runtime grant. Putting it in the prelude spends an
  import on something the program does not do.

## What I could not determine

- **The provider token count of the current array.** The census above
  serializes the real 22-tool definitions through the Anthropic adapter,
  but its token range is a character estimator. No tokenizer or provider
  token-count endpoint was used, and no workload accuracy comparison was
  run.
- **Whether tool search's recall has been measured against a known
  ground truth.** The published figures are end-to-end task accuracy on
  internal MCP evals,[^atu] which conflates retrieval quality with
  everything downstream of it. The silent-miss failure mode is documented
  as a troubleshooting entry, never as a rate.
- **Whether a generated `cap/mcp/*` module written into a build root's
  vendored prelude actually rebuilds cleanly.** The reasoning follows the
  seed's documented invariant — `seed.verify` compares dependency tables,
  which such a module does not change — but no build has been run, and
  Gleam's package-cache behaviour when a vendored package's sources move
  is exactly the class of thing `codemode/seed.gleam` exists because of.
- **Whether Gleam's internal-module convention would help.** The
  `gleam.toml` reference says internal modules "are not part of the
  public API" but that it "is technically possible to import and use"
  them.[^gleam-toml] `packages/cap/gleam.toml` sets no
  `internal_modules` key, so `cap/internal/*` is internal by default —
  by documentation convention, not by compiler enforcement. I found no
  evidence that Gleam errors or warns on a cross-package internal import,
  so the vetting allowlist remains the only enforcement, which is what
  the design already claims.
- **What OpenAI's deferral does to its own cache.** The docs assert it
  "preserves the model's prompt cache"; I did not verify the mechanism
  the way the Anthropic docs let me verify theirs.[^oai-ts]

[^ts-docs]: [Tool search tool](https://platform.claude.com/docs/en/agents-and-tools/tool-use/tool-search-tool), Claude platform documentation. Fetched 2026-08-25.
[^atu]: [Introducing advanced tool use on the Claude Developer Platform](https://www.anthropic.com/engineering/advanced-tool-use), Anthropic engineering.
[^cem]: [Code execution with MCP: building more efficient agents](https://www.anthropic.com/engineering/code-execution-with-mcp), Anthropic engineering.
[^mcp-tools]: [Model Context Protocol specification, 2025-06-18 — Tools](https://modelcontextprotocol.io/specification/2025-06-18/server/tools).
[^oai-ts]: [Tool search](https://developers.openai.com/api/docs/guides/tools-tool-search), OpenAI API documentation. Summarized from search results rather than fetched in full.
[^caching]: Multipliers from the Claude platform's prompt-caching documentation: reads ~0.1× base input, writes 1.25× at the five-minute lifetime and 2× at one hour. The same figures back the arithmetic already written into `adapter/anthropic`'s caching section.
[^gleam-toml]: [gleam.toml reference](https://gleam.run/documentation/gleam-toml-reference), `internal_modules`.
