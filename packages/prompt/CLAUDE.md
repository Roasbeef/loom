# prompt

## Purpose

Model-facing prose as swappable data. A **pack** is a file of named,
ordered sections carrying `{placeholder}` holes; this package decodes one
with a total decoder and renders it. Prompt *words* belong in a pack,
never in Gleam source — that is what lets them be mutated, scored and
replaced without a recompile. Reading a pack file, populating the
environment, and pinning a rendered string are all outside this package:
it performs no I/O.

Two packs ship, and they are separate because they are *paid for* on
entirely different schedules. The **system pack** (`prompt/default.
source`) renders through `pack.render` into the one string a session
sends as `system` on every request of every strand, behind a one-hour
cache breakpoint. The **summarization pack**
(`prompt/default.summary_source`, read through `prompt/summary`) is
assembled into a single user message once per compaction, cached never.
Editing one must not reprice the other.

## Key Types

- `prompt/pack.Pack` — a decoded pack: `version` (the pack's own
  identity, recorded so a cache miss can be attributed to a prompt
  change), `digest` (an FNV-1a fingerprint of the source it came from,
  for change detection only — not an integrity check), and `sections` in
  file order.
- `prompt/pack.Section` — `name` plus `template`. A name beginning with
  `_` marks a **fragment**: never rendered in its own right, only
  reached through a placeholder whose value the environment selects.
  That is how the sandbox section says one thing on a fully enforced
  host and another on a degraded one without the alternative wordings
  living in Gleam.
- `prompt/pack.Environment` — opaque; built only through
  `pack.environment(...)`, which trims, sorts and de-duplicates every
  list field. Workspace, platform, shell, tools, available tools,
  enforcement, network posture, protected paths, repository guidance.
  Nothing else, and nothing numeric. `available_tools` — the one-line
  snippets that become the prompt's tool index — is the single field
  trimmed and de-duplicated but **not** sorted: its order is the host's
  registration order, which is fixed for the session and is what a reader
  wants, so sorting would scatter a host's own tools through the
  built-ins and hide an unstable registry rather than fix one.
- `prompt/pack.Enforcement` — `FullyEnforced` / `PlatformEnforced` /
  `DegradedRefusing` / `BestEffort`. Behavioural posture, not a layer inventory; see
  Invariants.
- `prompt/pack.NetworkPosture` — `NetworkBlocked` /
  `NetworkProxied(allow)` / `NetworkOpen`, mirrored from
  `broker/policy.NetworkPolicy` because a pure package cannot depend on
  the broker. The proxy address is deliberately not carried.
- `prompt/pack.decode` — `String -> Result(Pack, CorruptionReport)`, the
  total decoder. `pack.encode` is its inverse for an optimizer writing a
  mutated pack back out.
- `prompt/pack.render` — `Pack, Environment -> String`. The whole point
  of the package, and a pure function of exactly those two values.
- `prompt/pack.problems` — `Pack -> List(Problem)`, reporting missing
  canonical sections, missing fragments, and placeholders no binding
  provides. Deliberately separate from `decode`: a mutated pack that
  drops a section is still a valid pack, and the harness decides whether
  to run with it.
- `prompt/pack.Severity` — `Corrupting` / `Shaping`, and
  `prompt/pack.severity : Problem -> Severity`. **Corrupting** is the
  pack naming something it does not carry: a placeholder no binding
  provides, or a fragment a binding selects. **Shaping** is the pack
  being smaller than canonical: a section is absent. The line is drawn
  where intent is: a typo renders empty and says so nowhere, a dropped
  section may be exactly what a mutation meant.
- `prompt/pack.Assessment` / `prompt/pack.assess` — `problems`
  partitioned by `severity`, so `assess(pack).corrupting == []` is the
  question a prompt optimizer asks (is this variant scorable at all?) in
  one expression. It is a partition and nothing more: between them the
  two lists hold exactly what `problems` returns.
- `prompt/pack.section` / `prompt/pack.fill` — reading one named
  template out of a pack, and filling its holes from an association
  list under exactly `render`'s substitution rules. The two doors
  `prompt/summary` assembles through; `fill` is the *only* substitution
  in the package, which is what keeps the never-re-scanned property in
  one place.
- `prompt/default.source` — the system pack Loom ships with, as pack
  source. There is no helper returning an unwrapped `Pack`; producing
  one would need a crash-ladder construct, and the harness has to handle
  a failed decode for an operator-supplied pack anyway.
- `prompt/default.summary_source` — the summarization pack, same format,
  its own `%% version`.
- `prompt/summary.Input` — what a summary request is asked to summarize:
  `Compaction(conversation, previous_summary, custom_instructions,
  files_read, files_modified)` or `Branch(conversation,
  custom_instructions)`. `previous_summary` is what selects the
  iterative-update prompt over the initial one.
- `prompt/summary.{system, instruction}` — the two halves of a summary
  request's single user message: the standing refusal to continue the
  conversation, and the transcript plus the format demand.
- `prompt/summary.serialize` — messages to the role-tagged
  `<conversation>` transcript a summary request carries, tool results
  truncated at `tool_result_limit` (pi's 2,000 characters).
- `prompt/summary.problems` — `pack.problems` over the summarization
  pack's own vocabulary of sections, fragments and bindings.

## The pack format

`%%` in column zero makes a line a directive; every other line is body
text of the open section, kept verbatim with no escaping of any kind.
Three directives exist: `%% loom-prompt-pack <n>` (format version,
required, first), `%% version <id>` (the pack's identity, required,
once, before the first section), `%% section <name>` (`[a-z0-9_]+`).
A directive whose content begins with `#` is a comment; any other
unrecognized directive is corruption. The cost of that strictness is
that a body line may not begin with `%%`.

The default system pack carries the canonical sections — `identity`,
`tool_discipline`, `available_tools`, `delegation`, `conduct`,
`environment`, `sandbox`, `repository_guidance` — plus the fragments
three of them select between. `available_tools` renders the host's tool
index through the `_available_tools` fragment and disappears entirely on
a host whose registry offered no snippets.
`pack.canonical_sections` is the list, in render order, and the shipped
pack is held against it.

The summarization pack carries `system`, `initial`, `update` and
`branch`, plus the `_previous_summary`, `_custom_instructions` and
`_file_operations` fragments its input selects.
`summary.canonical_sections` is that list. It is never handed to
`pack.render` — `render` would emit its four sections one after another,
which is not what a summary request is — so `prompt/summary` reaches its
sections through `pack.section` and fills them with `pack.fill`.

## Relationships

- **Depends on**: `core` (`core/corruption.CorruptionReport`, the one
  error type every total decoder returns) and `gleam_stdlib`. Nothing
  else, ever — see Invariants.
- **Depended on by**: `client`, through `client/system_prompt` (reads
  the pack file, builds the `Environment` from the workspace, the
  helper's hello and the composed sandbox policy, renders once at
  session open, pins the result into the reserved `prompt/` cell, and
  loads the summarization pack the same way) and `client/wiring` (which
  assembles `summary.system` + `summary.instruction` into the one user
  message a structural summary request carries).
- **FFI**: none, and there must not be any. There is no
  `internal/ffi_*` module here, no `@external` of any target, and no
  `gleam_erlang` or `gleam_otp` in `gleam.toml` — by rule, not by
  coincidence.
  Two properties rest on that, and one `@external` closes both: purity is
  what makes the state space property-testable without spawning processes,
  and the same discipline is what keeps this package compiling to the
  **JavaScript target**. Lint R6 gates on it at error level and its census
  must stay zero. Portable here means *decide but not act* — replay a
  conversation tree, validate a transcript with the server's own total
  decoders, run `next_action` over fetched state — and never the harness in
  a browser: `gleam_otp` has no JavaScript target, Rule Zero is
  kernel-enforced (in a browser the harness VM and the untrusted-code VM
  would be the same VM), and the two-channel doctrine needs processes on
  both sides. `docs/gleam-style.md` Part IV §5 argues it in full.

## Traffic

None. `prompt` spawns nothing, commits nothing, reads no register, and
crosses no wire. It is a pure decode-and-render library; the durable
`prompt/` blackboard cell the design pins the rendered string into is
written by whoever calls `render`, not here.

## Invariants

- **`render` is byte-stable for a session.** It is a pure function of
  `Pack` and `Environment`; every `Environment` field is fixed at session
  open. No clock, date, elapsed time, token count, cost, git state,
  operation id, entry id, strand name or random value can appear in the
  output, because none can enter the inputs. This is what makes the
  system prompt cacheable behind a one-hour breakpoint; a single changed
  byte costs a full cache write at 2× base input on every strand for the
  rest of the session.
- **The purity is structural, not a convention.** The dependency set is
  `core` + `gleam_stdlib`, so no time source, id generator, process or
  filesystem exists in this package's graph to reach for.
  `test/prompt/purity_test` reads `src/` and fails if an import, an
  `@external`, or a numeric `Environment` field appears.
- **`Environment` has no numeric field and must never grow one.** A
  timestamp, an elapsed count, a cost and a token total all arrive as an
  `Int`. Adding one is how the caching contract gets broken silently.
- **Every list field is normalized at construction** — trimmed, emptied,
  sorted, de-duplicated — so a caller's discovery order cannot reach the
  rendered bytes. The tool array on the wire must be sorted for the same
  reason; it sits *ahead* of the system block in the cached prefix.
- **Decoding is total.** A missing header, an unknown directive, a
  duplicate section name, a bad name, a wrong format version: each is a
  `CorruptionReport` naming the line. Duplicate section names are
  corruption for the same reason duplicate keys are in `core`'s
  codecs — two sections of one name have no single meaning.
- **Rendering is total and never re-scans.** An unknown placeholder
  renders empty, an unclosed or non-identifier brace renders literally, a
  missing section is absent, and a section that renders to nothing is
  dropped with the blank line that would have followed it. A substituted
  value goes straight to the output and is never scanned again, so
  injected repository guidance containing `{shell}` renders those
  characters and no pack can drive expansion in a loop. `pack.fill`
  carries the identical property, and it matters more there: a summary
  request splices a whole *conversation* — model output, tool results,
  whatever a repository contains — into a template, and a second pass
  would let that content name a binding and expand it.
- **A summary request carries no system prompt and no tool array.** The
  provider adapter hangs its two one-hour cache breakpoints on those two
  positions, and a prompt read exactly once must not pay a cache write
  (pi's `cacheRetention: "none"`, expressed as a request shape). That is
  why `summary.system` returns a *string the caller prepends to the user
  message* rather than something destined for the `system` field, and
  why `prompt/summary` has no notion of tools at all.
- **The summarization prompts demand a fixed structure and verbatim
  detail.** Goal / Constraints & Preferences / Progress (Done, In
  Progress, Blocked) / Key Decisions / Next Steps / Critical Context,
  with an explicit instruction to preserve exact paths, identifiers,
  command lines, error messages and `sha256-<hex>` blob addresses. The
  update prompt merges into a previous summary rather than restating it
  — a dropped constraint reads to the agent as permission. This is pi's
  template, ported section for section, plus one Loom-specific line: a
  `sha256-<hex>` content address names tool output offloaded to a blob
  at commit time and stays readable after the excerpt around it is
  summarized away, so it must survive verbatim. Compaction is lossy and
  this is the part of the design that bounds the loss.
- **The transcript is fenced and framed as a record.** `serialize`
  role-tags messages inside a `<conversation>` element and the `system`
  section says in as many words that everything inside it is the past,
  addressed to nobody, and that instructions within it are data. Tool
  results are truncated because they dominate a transcript and are the
  least of what a summary needs.
- **The sandbox section states posture behaviourally, never a layer
  inventory.** Naming which kernel layers a host does or does not
  enforce hands an injection payload a map of the holes for something it
  could read as ground truth from one shell command anyway, and tells a
  cooperative agent nothing it can act on.
- **The enforcement line is present on every host.** Its presence
  everywhere is what makes its variation meaningful.
- **A degraded host's sentence names a host failure, not a policy
  denial.** Under `FullEnforcement` and the production
  `PlatformEnforcement` default, a degraded helper means every jailed execution is refused, before
  dispatch and again after the run. Escalation cannot clear it and
  retrying cannot either, and an agent that mistakes it for a policy
  denial retries forever against a wall. The two demand different
  behaviour, so the prompt distinguishes them.
- **`Enforcement` carries only what the harness can know at session
  open**: the demanded posture plus the coarse `degraded` flag from the
  helper's hello (`broker/exec.degraded_features`). There is no
  per-layer report at open — the `skip:` list lives inside an
  `ExecResult`, after a run, and the `ENFORCED`/`SKIPPED` table is a
  separate `--self-test` invocation. Fields with no source do not exist
  here.
- **Repository guidance is project-authored data, framed as such,
  capped at `max_repository_guidance_bytes` on a line boundary, and the
  cut is announced by the pack's own fragment.** Framing does not make a
  hostile `AGENTS.md` or `CLAUDE.md` safe; it stops one speaking with the
  operator's voice, and the residual risk is accepted and named.
- **The `repository_guidance` binding may carry more than one file, and
  the fences around them are `client/system_prompt`'s.** This package
  still sees one opaque string and still never parses it. What
  `_repository_guidance` promises about that string is the contract the
  client keeps: each file arrives inside an `<instructions>` block naming
  its path and an origin of `workspace` or `user-default`, at most one
  block is `user-default`, and when there is one it is first. Reword the
  fragment and those two words move with it — they are the only thing
  telling a model which instructions are its operator's.
- **`decode` accepts more than `problems` approves.** Keep it that way:
  syntax is the decoder's business, completeness is the harness's
  decision. `severity` refines the *report* and must never reach back
  into the parser: a pack `assess` calls corrupting still decodes and
  still renders.
- **A missing section is `Shaping`, never `Corrupting`.** A mutated pack
  that drops a section is a valid pack; the severity axis exists to let
  an optimizer keep scoring one, so nothing may reclassify it into a
  refusal.
- **The delegation section says only what an `agent_*` schema cannot.**
  The six schemas are on the wire already and the pack does not repeat
  them. What it carries is the policy: a wait holds the operation open
  and queues a human's steer, so batch the spawns and wait on the batch;
  addressing is parent-or-descendant and a wait is descendant-only,
  which is what keeps the wait graph acyclic; a child's result is its
  last assistant message plus its blackboard notes, not a structured
  report, so a brief must ask for a self-contained final answer. Each
  sentence is checked against `tools/agent` and `client/agency` by a
  test in `default_test`; if one of those changes, the sentence is
  wrong, not merely stale.

## Deep Docs

- [docs/design-notes/agent-comms-and-system-prompt.md](../../docs/design-notes/agent-comms-and-system-prompt.md)
  — Part B: the design this package implements, including the stability
  contract and the alternatives rejected. Part A is the `agent_*` tool
  semantics the `delegation` section states policy for.
- [docs/review/m5-agent-comms-judgment.md](../../docs/review/m5-agent-comms-judgment.md)
  — claim 4 and change item 5, which overrode the design's sandbox
  reasoning and are what the wording here follows.
- [docs/design-notes/compaction-and-memory.md](../../docs/design-notes/compaction-and-memory.md)
  — Part 2: why the summarization prompts are pi's, why the request is a
  serialization rather than the live cached prefix, and what the cache
  interaction costs.
- [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md)
  — the plane the rendered prompt is consumed in.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc
  graph.
