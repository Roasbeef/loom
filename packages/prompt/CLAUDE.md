# prompt

## Purpose

The system prompt as swappable data. A **pack** is a file of named,
ordered sections carrying `{placeholder}` holes; this package decodes one
with a total decoder and renders it against a typed `Environment` into
the one string a session sends as `system` on every request. Prompt
*words* belong in a pack, never in Gleam source — that is what lets them
be mutated, scored and replaced without a recompile. Reading the pack
file, populating the `Environment`, and pinning the rendered string are
all outside this package: it performs no I/O.

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
  list field. Workspace, platform, shell, tools, enforcement, network
  posture, protected paths, repository guidance. Nothing else, and
  nothing numeric.
- `prompt/pack.Enforcement` — `FullyEnforced` / `DegradedRefusing` /
  `BestEffort`. Behavioural posture, not a layer inventory; see
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
- `prompt/default.source` — the pack Loom ships with, as pack source.
  There is no helper returning an unwrapped `Pack`; producing one would
  need a crash-ladder construct, and the harness has to handle a failed
  decode for an operator-supplied pack anyway.

## The pack format

`%%` in column zero makes a line a directive; every other line is body
text of the open section, kept verbatim with no escaping of any kind.
Three directives exist: `%% loom-prompt-pack <n>` (format version,
required, first), `%% version <id>` (the pack's identity, required,
once, before the first section), `%% section <name>` (`[a-z0-9_]+`).
A directive whose content begins with `#` is a comment; any other
unrecognized directive is corruption. The cost of that strictness is
that a body line may not begin with `%%`.

The default pack carries the six sections the design settled on —
`identity`, `tool_discipline`, `conduct`, `environment`, `sandbox`,
`repository_guidance` — plus the fragments the last two select between.

## Relationships

- **Depends on**: `core` (`core/corruption.CorruptionReport`, the one
  error type every total decoder returns) and `gleam_stdlib`. Nothing
  else, ever — see Invariants.
- **Depended on by**: nothing yet. `client` is the intended consumer:
  it reads the pack file, builds the `Environment` from the workspace,
  the helper's hello and the composed sandbox policy, renders once at
  session open, and pins the result.
- **FFI**: none, and there must not be any. There is no
  `internal/ffi_*` module here.

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
  characters and no pack can drive expansion in a loop.
- **The sandbox section states posture behaviourally, never a layer
  inventory.** Naming which kernel layers a host does or does not
  enforce hands an injection payload a map of the holes for something it
  could read as ground truth from one shell command anyway, and tells a
  cooperative agent nothing it can act on.
- **The enforcement line is present on every host.** Its presence
  everywhere is what makes its variation meaningful.
- **A degraded host's sentence names a host failure, not a policy
  denial.** Under `FullEnforcement` — the production default — a
  degraded helper means every jailed execution is refused, before
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
  hostile `CLAUDE.md` safe; it stops one speaking with the operator's
  voice, and the residual risk is accepted and named.
- **`decode` accepts more than `problems` approves.** Keep it that way:
  syntax is the decoder's business, completeness is the harness's
  decision.

## Deep Docs

- [docs/design-notes/agent-comms-and-system-prompt.md](../../docs/design-notes/agent-comms-and-system-prompt.md)
  — Part B: the design this package implements, including the stability
  contract and the alternatives rejected.
- [docs/review/m5-agent-comms-judgment.md](../../docs/review/m5-agent-comms-judgment.md)
  — claim 4 and change item 5, which overrode the design's sandbox
  reasoning and are what the wording here follows.
- [docs/architecture/orchestration.md](../../docs/architecture/orchestration.md)
  — the plane the rendered prompt is consumed in.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc
  graph.
