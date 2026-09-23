# Prompt assembly

Every generation request Loom sends carries three things: a tool array, a
system prompt, and the strand's projected conversation. This document covers
how the first two are built and kept byte-identical for the life of a
session, and how the per-run and per-request content that rides in the
conversation is attached. The pieces are the pure `prompt` package (a pack
format and its renderer), `client/system_prompt` (the I/O that feeds the
renderer and pins its output), the discovery of project instruction files,
the skill catalogue, and the Anthropic adapter's prompt-cache breakpoints.

All of this sits on the boundary between the orchestration plane and the
model. The system prompt is fixed at session open and stored durably; the
per-run content is committed as ordinary conversation entries; the provider
adapters translate the result into each API's wire shape. Neighbouring
documents own the details this one links to:
[orchestration](orchestration.md) for strands, operations and the driver,
[models](models.md) for provider dialects and request routing,
[compaction](compaction.md) for what replaces history at a checkpoint,
[memory](memory.md) for the distilled memory digest, and
[client](client.md#skill-discovery-and-activation) with
[skills](../skills.md) for the operator's view of skills.

## What one request carries

On the Anthropic Messages API a request renders in the order `tools`, then
`system`, then `messages`, and the provider caches by exact byte prefix over
that order. The layout follows from that fact: the parts that never
change go first and must not move, and everything that changes goes last.

| Region | Source | Changes |
|---|---|---|
| Tool array | The strand's active tool names, sorted, looked up in the session's tool registry | When the operator changes a strand's active tools, or a restart changes a tool's definition |
| System prompt | The session's pinned string, rendered once from a prompt pack | Once per session, except for an explicit override or a changed enforcement demand |
| Messages | The strand's durable branch, projected from the newest compaction onward, plus run-start injections (durable) and the `context` hook's output (transient) | Every turn |

`wiring.provider_request` builds this provider-neutral `ProviderRequest`
from the pinned string in `wiring.Config.system`, the strand configuration's
`active_tool_names`, and the projected context. Every strand of a session,
including subagents and the advisor, sends the same system string. What
differs per strand is its tool array and its messages.

## Packs: prompt text as data

The words a model reads live in a *pack*, not in Gleam source. A pack is a
UTF-8 text file of named, ordered sections, each a template with
`{placeholder}` holes. Keeping the text out of the code lets an operator or
a prompt optimizer swap, mutate and score a prompt without a release: point
`LOOM_PROMPT_PACK` at another file and restart.

The format has three directives, each a line starting with `%%` in column
zero:

```text
%% loom-prompt-pack 1
%% version loom-default-8
%% # a comment
%% section environment
Workspace root: {workspace}
```

The header names the format version and must come first. `%% version`
names the pack itself; the harness records it so that a cache miss can be
traced to a prompt change. `%% section <name>` opens a section, and every
following line up to the next directive is kept verbatim with no escaping,
because prompt prose is full of quotes, braces and backslashes. An unknown
directive is a decode error rather than prose, so a typo in a directive
cannot silently become part of the prompt.

A section whose name starts with `_` is a *fragment*. `render` never emits
a fragment on its own; a placeholder in another section selects one based
on the environment. This is how the `sandbox` section says one thing on a
fully enforced host and another on a degraded one while every alternative
wording stays in the pack.

### The environment

`render` takes a decoded `Pack` and an `Environment`, and nothing else. The
`Environment` is opaque and has one constructor, `pack.environment`, with
nine fields: workspace, platform, shell, tool names, the available-tools
snippets, an `Enforcement` posture, a `NetworkPosture`, protected paths,
and optional repository guidance. None of them is numeric. A millisecond, a
token count and a cost all arrive as integers, and any of them would make
the rendered bytes differ between two boots of the same session.

The constructor normalizes every list: entries are trimmed, empties are
dropped, and the result is sorted and de-duplicated, so two callers that
discovered the same set in different orders get the same bytes. The one
exception is `available_tools`, which is trimmed and de-duplicated but not
sorted. Its order is the registry's registration order (the core tools
first, then what hosts added), which is fixed for a session and is the
order a reader expects. Sorting it would hide an unstable registry rather
than fix one.

`Enforcement` has four values (`FullyEnforced`, `PlatformEnforced`,
`DegradedRefusing`, `BestEffort`), and each one selects its own sandbox
fragment. The value comes from the only two facts the harness has at
session open: the enforcement demand the server was started with, and the
coarse `degraded` flag a helper advertises in its handshake. `NetworkPosture`
mirrors the broker's network policy (`NetworkBlocked`,
`NetworkProxied(allow)`, `NetworkOpen`) without the proxy address, because
the address changes nothing the agent does. See [effects](effects.md) for
what these postures mean at the kernel.

### Rendering

`render` (`prompt/pack.gleam:885`) walks each non-fragment section once.
Bindings come in two tiers. Literal bindings are strings taken straight
from the environment, such as `{workspace}` or `{network_allow}`. Selected
bindings, such as `{enforcement}` or `{repository_guidance}`, name a
fragment chosen by the environment, and that fragment is filled against the
literal tier only, one level deep.

Two properties of the substitution matter for safety. A substituted value
is written to the output and never scanned again, so an `AGENTS.md`
containing the literal text `{shell}` renders as `{shell}`. And because
fragments resolve one level deep, no pack and no injected file can drive
expansion in a loop. `pack.fill`, the package's only other substitution
entry point, uses the same function.

`render` is total. An unknown placeholder renders empty, a brace that does
not open a placeholder survives literally, a missing section is absent, and
a section that renders to nothing is dropped. The output is then
normalized: one blank line between sections, runs of blank lines collapsed,
trailing whitespace removed from every line. An editor that leaves a
trailing space in a pack therefore does not change the rendered bytes.

### Checking a pack

`decode` checks syntax only. It returns a `CorruptionReport` naming the
line for a missing header, a bad or duplicate section name, or stray prose
before the first section. Completeness is a separate question, answered by
`pack.problems`: which canonical sections and required fragments are
missing, and which placeholders no binding provides.

`pack.severity` splits problems in two. A placeholder nothing binds, or a
missing fragment, is `Corrupting`: the pack refers to something it does not
carry, and the gap is invisible in the output. A missing canonical section
is `Shaping`: the pack is smaller than the default, which may be exactly
what a mutation intended. `pack.assess` returns both lists at once, so an
optimizer can discard corrupt variants and still score deliberate
omissions. A pack that `assess` calls corrupting still decodes and still
renders; severity refines the report and never reaches back into the
parser.

### The default pack

`prompt/default.source` is the pack Loom ships, as a string constant
decoded through the same `pack.decode` as any operator pack. Its canonical
sections, in order, are `identity`, `tool_discipline`, `available_tools`,
`delegation`, `conduct`, `environment`, `sandbox` and
`repository_guidance`. Four of them (`identity`, `tool_discipline`,
`delegation`, `conduct`) contain no placeholders, so they are identical for
every session on a given build; a test holds them that way. The rest vary
only by host, workspace and the operator's home directory.

The pack's comments set the editorial rule: every sentence is paid for on
every request of every strand for the whole session, so a sentence belongs
there only if it changes what the agent does. The `delegation` section, for
example, carries only the policy the `agent_*` tool schemas cannot express
(batch the spawns and wait on the batch, waits are descendant-only, a
child's answer is its last assistant message). The schemas themselves are
already on the wire and are not repeated.

## Why `prompt` is a pure package

`prompt` is one of the three packages (with `core` and `machine`) that hold
no `@external` of any target and do not depend on `gleam_erlang` or
`gleam_otp`; lint rule R6 gates this. Its only dependencies are `core` and
`gleam_stdlib`. For this subsystem that constraint does three concrete
things.

First, it makes byte stability a property of the dependency graph rather
than of reviewer vigilance. There is no clock, random source, file read or
git call reachable from `render`, so the rendered string is a function of
exactly the `Pack` and the `Environment`, and the `Environment` has no
field a volatile value could hide in. Adding a placeholder means adding a
name to `binding_names`, a field to `Environment` and a binding, three
visible edits in one module.

Second, the renderer and the pack checks can be property-tested without
starting a process or touching a filesystem.

Third, the package stays compilable to the JavaScript target, so a tool
that mutates and scores packs can decode, check and render them outside the
harness VM. Everything that needs I/O (reading the pack file, probing the
helper, reading instruction files, writing the pin) lives in
`client/system_prompt` and `client/serve`.

## Assembling and pinning the system prompt

`client/system_prompt` is the I/O half of `prompt`. It reads a pack,
gathers every environment field from a real source, renders once, and pins
the result into the session store so that every later boot of the same
session sends exactly the bytes the first one did.

A boot chooses its prompt from three sources, in this order
(`assemble`, `client/system_prompt.gleam:449`):

1. `LOOM_SYSTEM_PROMPT`, a literal prompt that bypasses the pack entirely.
   A value that is empty or whitespace counts as unset.
2. The pinned cell from an earlier boot, if it was rendered for the current
   enforcement demand.
3. A fresh render of the pack named by `LOOM_PROMPT_PACK`, or of the
   shipped default when that variable is unset.

The render is passed as a thunk, so a resumed session with a valid pin
reads no pack file, reads no instruction file, and does not borrow a helper
to ask whether the host is degraded.

The pin exists because the inputs to a render are fixed at session open but
their sources are not. The agent can edit `AGENTS.md`, an operator can
restart with different flags, a kernel can change under a reboot. Rendering
again on resume would move the bytes and pay a full cache write on every
strand. So the assembled text is written once and read thereafter.

The pin lives under the reserved fact key `prompt/system`, and its
provenance (origin, pack version and pack digest) under `prompt/pack`.
Reserved keys are writable only through `api.put_reserved_fact`; the
model-reachable `put_fact` refuses them. The provenance cell is diagnostic
and never read back for behaviour.

One input is allowed to invalidate the pin: the enforcement demand. The
pinned value is a record of the text and the demand it was rendered for
(`full`, `platform` or `best-effort`), and `pinned_for` returns no pin when
the demand has changed, or when the cell holds the older bare-string form.
The boot then renders once more and records the new pair. This costs one
cache write, and it is paid deliberately: a prompt that promised full
confinement on a host now running best-effort would describe the sandbox
wrongly. Text and demand share one register, so no partial commit can pair
one demand's words with another demand.

### Boot order

The pin has to satisfy an ordering constraint inside `client/serve`.
`wiring.Config.system` must hold the string before `api.open`, and
`api.open` is what starts the storage writer. So the boot:

1. reads the pinned cell straight from the session store with `pinned_for`,
   which is legal because nothing owns the store yet;
2. calls `assemble`, rendering only if needed;
3. passes the text into `wiring.Config` and opens the runtime;
4. writes the pin back with `pin_for` through the now-running writer, so
   the commit is journaled like any other.

### What refuses a boot

A pack file that cannot be read, a pack that fails to decode, and a pack
that renders to an empty string each refuse the boot with a sentence naming
the pack. An unreadable pack does not fall back to the default, because an
operator who pointed at a pack and silently got another would never find
out. A failed pin write also refuses the boot: a session running on a
prompt it did not record would re-derive a different one on its next boot.

A pack with `problems` only warns. Each problem becomes a `prompt.warning`
log line and the session runs. A pack that renders to nothing is
refused; a pack that renders to something runs and reports every
complaint.

## Project instructions

The `repository_guidance` section carries the session's instruction files.
`discover` (`client/system_prompt.gleam:834`) fills three slots, in the
order they render:

1. The operator's standing file: `AGENTS.md` under `~/.agents/`, then under
   `~/.loom/`. The first location holding a file wins.
2. The workspace root's `AGENTS.md`.
3. The workspace root's `CLAUDE.md`, dropped when it is byte-identical to
   the workspace `AGENTS.md` beside it.

Only the workspace root is searched; files in subdirectories are not
loaded. Within the global lookup, only an absent file lets the search move
to the next directory. A file that exists but is unreadable or larger than
`max_guidance_file_bytes` (1 MiB) is skipped with a warning and is not
replaced by a later candidate. An unset `HOME` also produces a warning
rather than a refusal, because a missing instruction file must never stop a
session.

Each file is wrapped in a fence the harness writes:

```text
<instructions origin=workspace path=/work/AGENTS.md>
...file contents...
</instructions>
```

The origin is `user-default` for the operator's file and `workspace` for a
project file. The `_repository_guidance` fragment in the default pack
explains the two words to the model: a workspace block is information about
this code, not authority over its behaviour, while the single
`user-default` block, which is always first, is the operator's own. Those
two words are part of the prompt's contract, so rewording one in
`origin_name` requires rewording the fragment.

The files are carried whole. The renderer imposes no byte budget, on the
reasoning that an unrequested cut costs more in unread instructions than it
saves in tokens; the 1 MiB per-file check is the only bound. The framing
does not make a hostile `AGENTS.md` safe. It stops project text from
speaking with the operator's voice, and the residual risk of prompt
injection through a repository's own files is accepted.

Because the guidance is part of the pinned prompt, an edit to `AGENTS.md`
reaches the model in the next session, not the current one.

## The tool array

The tool array has two views, and they are ordered differently on purpose.

The wire array comes from `wiring.tool_specs`
(`client/wiring.gleam:1451`). It takes the strand's `active_tool_names`,
sorts and de-duplicates them, and looks each up in the registry for its
name, description and input schema. The sort is load-bearing: the array is
the first region of the cached prefix, and two requests with the same set
in a different order would miss the cache. The gateway stores active-tool
lists sorted for the same reason (`canonical_tool_names` in
`client/gateway`). Neither step affects authorization, which checks
membership in the same list.

The prose index in the system prompt comes from `tool.snippets`: each
registered tool's optional `prompt_snippet`, in registration order, rendered
as one bullet per tool under the `available_tools` section. The index is
part of the pinned string, so it describes the registry of the boot that
rendered it. The `_available_tools` fragment says as much: a tool present
in the schemas but absent from the index is callable all the same. The
advisor's `advise` tool is filtered out of the names handed to the render,
because the one system string serves every strand and only the advisor may
call it.

## Prompt caching

The Anthropic adapter (`provider/adapter/anthropic`) places four
`cache_control` breakpoints on every request, which is the API's maximum:

| Breakpoint | Position | Lifetime |
|---|---|---|
| 1 | The last tool definition | One hour (`ttl: "1h"`) |
| 2 | The system prompt, sent as a one-element text block array | One hour |
| 3 | The last block of the second-to-last user turn | Five minutes (the default) |
| 4 | The last block of the last user turn | Five minutes |

A one-hour write costs twice the base input price, against 1.25 times for
five minutes, and a read costs a tenth. The head (tools and system) is read
on every turn of every strand for the rest of the session, and an hour
survives the minutes a person spends reading a diff between turns, so the
reads that follow repay the higher write price. The head gets two
breakpoints rather than one because tools render first: if the system
prompt changes, the tool array still reads from its own entry.

The tail breakpoints sit on the final two user turns. Turns alternate roles
after merging, so the user turn marked last on one request is the turn
marked second-to-last on the next, and that breakpoint lands on the same
bytes in both requests. The API walks back at most 20 blocks from a
breakpoint looking for an entry, and one agentic turn of parallel tool calls
can exceed that, so an exact position matters. The API also requires every
one-hour breakpoint to precede every five-minute one, which the head-then-tail
layout satisfies.

The other dialects place no breakpoints. OpenAI-compatible Chat
Completions, Responses and Gemini cache automatically by prefix on the
server, so the same byte-stability rules still decide whether a request
reads from the cache. See [models](models.md#dialects-and-the-adapter-seam).

### What must stay stable

For the head to stay warm across turns, these must not change during a
session:

- the strand's active tool set, and every active tool's description and
  schema (the `load_skill` description includes the skill index, so the
  skill catalogue is part of this);
- the pinned system string, which in turn fixes the pack, the host facts,
  the enforcement posture and the instruction files as of the first boot.

Anything volatile (a timestamp, a digest of mutable notes, a reminder about
remaining context) goes into the messages, after the head. A precise history
rewrite or a compaction changes bytes at some position in the messages;
breakpoints at or after that position miss once and are rewritten, while the
head still reads.

## Content attached per run and per request

Nothing volatile enters the system prompt. Instead, two hook slots in
`runtime/effects.Hooks` add content to the messages.

**Run-start injections** (`run_start`) are messages returned when a run is
accepted. The planner commits them as durable entries on the strand's
branch before the first generation, so they become part of the history
that later requests carry unchanged. Several layers wrap the slot, each
appending after the one before it, in this order:

1. the strand's notes digest from `client/notes`, up to 4,096 bytes;
2. the distilled memory digest from `client/memory`, read from its sidecar
   file at each run start (see
   [memory](memory.md#when-a-new-digest-becomes-visible));
3. any advisor nudges queued for the primary strand
   ([advisor](advisor.md));
4. extension `before_agent_start` answers, fenced and attributed to the
   extension ([extensions](extensions.md));
5. context from imported Claude-format `SessionStart` hooks
   (`client/hookserve`, [hooks-compat](hooks-compat.md)).

Each layer wraps rather than replaces the slot, because
`hooks.with_run_start` sets it outright and a builder that set it would
drop the layers installed before it.

**The `context` hook** transforms the projected messages for one request
immediately before dispatch. Its output is never committed, so a crash
before the request settles re-projects and re-runs it. Loom's own use is the
near-limit reminder from `client/checkpoint`, appended when the context is
within a reserve of the compaction point, so the model writes its notes
while the messages they describe are still present. The advisor layer
prepends its standing brief to the advisor strand's own requests, at the
front of the messages so the brief does not move with the conversation.
Extensions fold over the result last.

Two more paths reach the conversation without either slot. A triggered
project rule (`client/rulescan`) joins the strand's open run as a steer
item when model output first contains one of its trigger strings. And a
user message with a recorded author or peer origin is projected with a
one-line attribution label ahead of its content (`core/origin`). The label
is attribution text, not a credential.

After a compaction, the projection starts from the checkpoint the model's
own notes produced, followed by the retained tail; see
[compaction](compaction.md). The checkpoint replaces history in the
messages and never touches the system prompt or the tool array.

## Skills

A skill is a Markdown document with YAML frontmatter, following the Agent
Skills format. `host/skill` discovers them once per session runtime from
`~/.agents/skills`, `~/.agents/skill`, `~/.claude/skills` and
`~/.Claude/skills`, resolving real paths so that aliases of one directory
contribute one entry. Each document is read whole, up to 64 KiB, and kept
in memory; a later edit to the file does not change what an already
captured skill loads. Two frontmatter flags set who may select a skill:
`user-invocable: false` hides it from slash commands, and
`disable-model-invocation: true` makes it explicit-only.

A skill enters context by one of two paths, and neither uses the system
prompt:

- **Model selection.** `client/skill_tool` registers `load_skill` when at
  least one skill is model-selectable. Its description lists each such
  skill as `name: description`, and its `name` argument is an enum of those
  names. Calling it returns the expanded document as an ordinary tool
  result. The tool reads nothing from disk at call time; its sandbox
  requirements grant no readable roots.
- **Slash invocation.** `skills.expand_message` runs in the gateway before
  a prompt or steer is admitted. When the leading text block begins with
  `/name`, a known user-invocable skill replaces that block with its
  expansion, keeping the other blocks and the message's author. Unknown
  slash text passes through unchanged; a known hidden skill is refused.

Both paths call `skill.expand`, which prefixes the invocation and the
document's path, substitutes the literal `$ARGUMENTS`, and refuses a result
over 256 KiB. Shell snippets and referenced scripts in the document stay
text; the model acts on them, if at all, through its ordinary tools and
permissions.

The skill index lives in the `load_skill` tool definition, so it is part of
the cached tool array. A new session runtime with a changed catalogue
renders a different array and pays one head write. See
[client](client.md#skill-discovery-and-activation) for the terminal's
completion list and [skills](../skills.md) for authoring.

## Invariants and failure behaviour

- **The system string is fixed for the session.** It changes only through
  `LOOM_SYSTEM_PROMPT` or a changed enforcement demand, and each change is
  pinned before any strand runs on it.
- **`render` depends on two values.** It reads the `Pack` and the
  `Environment` and nothing else, and the `Environment` has no numeric
  field.
- **Substituted text is inert.** No value is scanned for placeholders after
  substitution, and fragments resolve one level deep.
- **Decoding is total and strict about syntax; completeness only warns.** A
  corrupt pack refuses the boot, an empty render refuses the boot, and an
  incomplete pack runs with warnings.
- **Instruction files are data with a declared origin.** At most one block
  is `user-default`, and it is always first.
- **The wire tool array is sorted; the prose index keeps registration
  order.** The first serves the cache, the second serves a reader.
- **Volatile content goes in the messages.** Run-start injections are
  durable entries; `context` output is transient and re-derived after a
  crash.
- **The pinned prompt's tool index can be older than the registry.** It
  reflects the first boot, and the prompt states that the tool schemas,
  not the index, are authoritative.

## Where the code lives

| Path | What it owns |
|---|---|
| `prompt/pack.gleam` | The pack format: `decode`, `encode`, `Environment` and its constructor, `render`, `problems`, `severity`, `assess`, `fill`, and the FNV-1a `fingerprint` used as the pack digest. |
| `prompt/default.gleam` | The shipped default pack as a string constant. |
| `client/system_prompt.gleam` | Pack loading, the `Host` to `Environment` mapping, `assemble`, the `prompt/system` and `prompt/pack` pins, and instruction-file discovery and fencing. |
| `client/serve.gleam` | Boot order: registry construction, `render_prompt`, reading the pin before `api.open` and writing it after, and the composition of the run-start layers. |
| `client/wiring.gleam` | `provider_request`, `tool_specs`, and the near-limit reminder on the `context` hook. |
| `client/notes.gleam`, `client/memory.gleam` | The notes and memory digests injected at run start. |
| `client/extension/hooks.gleam`, `client/hookserve.gleam` | Extension and imported-hook run-start injections and `context` folds. |
| `client/rulescan.gleam`, `client/rules.gleam` | Triggered project rules, injected as steer items. |
| `host/skill.gleam` | Skill discovery, frontmatter parsing, and `expand`. |
| `client/skill_tool.gleam` | The `load_skill` tool. |
| `client/skills.gleam` | Slash-command expansion and the paged skill metadata read. |
| `client/context_view.gleam` | The `/context` estimate of system prompt, tool definitions and messages. |
| `tools/tool.gleam` | `names` (sorted) and `snippets` (registration order). |
| `provider/adapter/anthropic.gleam` | Wire encoding, the four cache breakpoints, and the caching rationale. |
| `runtime/effects.gleam` | The `Hooks` record, including the `run_start` and `context` slots. |

Each path is relative to its package's source root:
`prompt/pack.gleam` is `packages/prompt/src/prompt/pack.gleam`. The design
behind the pack and its stability contract is Part B of
[agent comms and the system prompt](../design-notes/agent-comms-and-system-prompt.md).
