# tools

## Purpose

The core tool set and the behaviour every tool implements: `bash` and
`grep` through the broker's jailed executor, `fs_read` / `fs_write` /
`fs_edit` harness-side with hashline anchoring and workspace path
discipline, plus content-addressed blob overflow for large output. WP-I.
Tool failures are data, never crashes.

Also the `agent_*` family — `agent_spawn`, `agent_wait`, `agent_send`,
`agent_note`, `agent_notes`, `agent_roster` — the six shells through
which a model reaches the messaging plane. They are shells only: each is
a thin wrapper over one call on the **Agency**, a record of closures
declared here and filled by whoever can see a live runtime
(`client/agency` in production). Everything with teeth — the addressing
rule, the caps, the deadline, the lineage ledger — lives on the far side
of that seam.

And `code_mode`, through which a model submits a *program* instead of a
call. It has the same shape as the agent family and the same reason for
it: `codemode` already depends on this package — its capability router
renders a `tool.Collected` — so the edge cannot run the other way. The
whole
pipeline — vet, hermetic compile, jailed satellite — sits behind a
**CodeMode** record of closures declared here and filled by
`client/codemode`. What this side owns is the model's half of the
contract: the schema, the clamped budget, and the rendering that turns a
vetting rejection, a compile error, a dead satellite or a program's own
reported failure into something a model can repair from.

## Key Types

- `tools/tool.Tool` — the record every tool is: `name`, `description`,
  `schema`, `replay` (`ReplaySafety`), `execution_mode`, `requirements`
  (a function from workspace root to `SandboxPolicy`), and
  `run: fn(Ctx, JsonValue) -> ToolOutcome`.
- `tools/tool.Ctx` — every seam a tool may touch: workspace root, the
  driver's own coordinates (`strand`, `op_id`, `step_id`,
  `source_index`), base policy and grants, enforcement demand, the
  constructed env, the clock, a `FileSystem` record of functions,
  `blob_root`, and `clear_call` — the broker seam every jailed execution
  flows through.
- `tools/agent.Agency` — the messaging seam: `spawn`, `send`, `wait`,
  `note`, `notes`, `roster`, plus the published `max_wait_ms` the wait
  tool's schema states. Every closure takes a `Caller` first and is
  judged against it.
- `tools/agent.{Caller, Handle, SpawnRequest, Provenance, Spawned,
  Waited, Outcome, Peer, Relation, Delivery, Refusal}` — the vocabulary
  crossing that seam. `Delivery` mirrors `runtime/api.Delivery` (which
  `tools` cannot import) the way `effects.ToolOutcome` mirrors the
  broker's `CallOutcome`.
- `tools/agent.{slug, handle_to_string, parse_handle}` — the name and
  handle grammar: `[a-z0-9-]`, capped, `/` and `#` rejected, and a total
  parse back from `{strand}#{operation}`.
- `tools/codemode.CodeMode` — the code-mode seam: `execute`, plus the
  published `allowed_imports`, `serviced_caps`, `default_within_ms` and
  `max_within_ms` the tool's description and schema state, so the
  sentence the model is charged for on every request cannot drift from
  the policy the program is judged against.
- `tools/codemode.{Request, Execution, ExecResult, Outcome, Rejection,
  Rule, Location, CompileFailure, RunFailure, Enforcement}` — the
  vocabulary crossing that seam, mirroring `codemode/vet`,
  `codemode/compile`, `codemode/satellite` and `cap/report` rather than
  importing them. `RunFailure` is the one deliberate narrowing: eight
  `satellite.RunError` variants become the four that read differently to
  a model, with the pipeline's reason text carried verbatim.
- `tools/tool.ToolOutcome` — text plus `is_error` plus optional typed
  `details`, mirroring pi's `ToolResultMessage.isError` (pi §3.8).
- `tools/tool.Registry` — opaque name → `Tool` lookup; `dispatch` is total.
- `tools/hashline.{AnchoredLine, Ref, Hunk, Plan, Stale, ApplyError}` — the
  pure anchor/window/plan core.
- `tools/blob.Bounded` — the overflow decision plus `{ref, size,
  head_excerpt, tail_excerpt}` details.

## Relationships

- **Depends on**: `core` (json, messages, ids, clock), `broker` (policy
  vocabulary, `clear_call`, `exec` failure shapes, framing output streams —
  the spec DAG's `I → G`), `simplifile` (the production `FileSystem`),
  `gleam_erlang` (subjects for streamed call events).
- **Depended on by**: `codemode` (the capability router renders a
  `tool.Collected` into a `cap_result`, which is why `tools` cannot
  import it back and `tools/codemode` mirrors its vocabulary instead),
  `client` (`client/wiring` builds the per-call `Ctx`
  and dispatches through the registry; `client/agency` fills the
  `agent.Agency` record, `client/codemode` fills the `CodeMode` record,
  and `client/serve` registers both families),
  `conformance` (the wiring/e2e suites drive the same adapter).
- **FFI**: `tools/internal/ffi_hash` — SHA-256 for blob content addressing.
  `tools/internal/ffi_path` — `read_link`, the lstat-level primitive
  workspace containment is built on. Both backed by `tools_ffi.erl`.

## Traffic

- **Actor messages**: none of its own. Jailed tools open a
  `Subject(broker.CallEvent)` and consume `CallOutput` chunks followed by
  one `CallSettled(CallExited | CallFailed)`; `tool.collect_events`
  gathers the stream respecting the helper's truncation flags.
- **Commits / registers**: none. Tools produce `ToolOutcome` values; the
  runtime commits the resulting result entries.
- **Wire**: indirect — `CallSpec` → broker → `exec_start` frames; the
  helper's `exec_out` / `exec_exit` come back as `CallOutput` /
  `CallExited`. `grep` additionally parses ripgrep's `--json` event stream
  into `Match` values.
- **Policy**: each tool declares `requirements(workspace)`. `bash` asks
  workspace write, system paths readable, network **off**; `grep` asks
  workspace readable, nothing writable, network off; `code_mode` asks
  workspace write and the whole filesystem readable (the Gleam and Erlang
  toolchains live outside it), and declaratively only — it clears nothing
  through `Ctx.clear_call`, because the build and the node are cleared
  inside the pipeline against their own far narrower requirements. `RefuseNarrowed` means
  an uncovered requirement settles in-band as a structured policy refusal
  carrying the exact wanted grants, ready for the escalation flow.

## Invariants

- **Tools never crash the strand.** Bad arguments, a policy refusal, a dead
  helper, a stale anchor, an unknown tool name — every one comes back as a
  structured `is_error` result the model can read. Dispatching an unknown
  name yields the in-band unavailable-tool error with `details` omitted:
  the harness must not invent a value for a tool's typed details contract.
- **Hashline plans are digest-bound; re-apply always rejects.** Per-line
  anchors alone cannot make "apply at most once" true — after a delete, an
  identical sibling line can shift into the removed position and its anchor
  still matches. So a `Plan` carries the digest of the exact content it was
  computed against and `apply` rejects any other content. A crash replay
  therefore either repeats an edit that never landed or fails in-band as
  stale; it cannot double-apply. The cost is deliberate: a concurrent edit
  far from every hunk also rejects, buying one replan round trip for the
  impossibility of silent double-application.
- **Anchors depend only on line content** — first 8 hex of FNV-1a 64 over
  the line's UTF-8 bytes, `anchor_version` 1, package-internal and never
  stored durably. Unrelated edits never change a line's anchor, though they
  may change its number, which is why refs carry both and both are checked.
  The digest is the full 16 hex plus the byte length, so a
  pre-image/post-image collision needs equal FNV-64 *and* equal length.
- **Path discipline is the sole boundary for the filesystem tools.**
  `fs_*` run in the harness and never pass through the broker or the kernel
  jail. `resolve_real` resolves symlinks component by component (at most
  `max_link_follows` = 40) and the resolved path must land under the
  equally-resolved workspace root, so neither `..` nor a symlink planted
  inside the workspace reaches outside it.
- **Replay safety is declared per tool and load-bearing.** `bash` is
  `Never` — an arbitrary external effect must yield a synthetic interrupted
  result on crash, never a re-execution. `grep`, `fs_read`, `fs_write`, and
  `fs_edit` are `Safe`: a read, a read, an idempotent write, and a
  digest-bound edit respectively.
- **`execution_mode` is a scheduling constraint**: `Exclusive` for bash,
  write, and edit (they may mutate the workspace); `Concurrent` for read
  and grep.
- **Blob writes are idempotent by construction.** Content addressing
  (SHA-256) puts the same bytes at the same ref, so replaying a `Safe` tool
  or re-running an identical command never duplicates storage. Output past
  `overflow_threshold_bytes` (64 KiB) carries `{ref, size, head_excerpt,
  tail_excerpt}` at `excerpt_bytes` (2 KiB) each.
- **`fs_read` is exempt from blob overflow.** Windowed reads are its
  bounding mechanism, and anchors inside an elided blob would defeat
  hashline editing. Bash and grep output do overflow.
- **Environments are allowlist-constructed, never inherited.** `Ctx.env`
  carries what the caller built; the helper drops anything absent from the
  policy's `env_allow` even if the broker sent it.
- **Timeouts are clamped tool-side** — `default_timeout_ms` 120 s,
  `max_timeout_ms` 600 s for bash; 60 s for grep.
- **A model never supplies its own identity, a strand name, or a
  blackboard prefix.** `agent.caller` is built from `Ctx` alone, so a
  model that names another strand in its arguments does not become it;
  `agent_spawn` takes a *purpose* and the Agency mints
  `sub:{parent}/{slug}-{step}-{index}` from the call's own durable
  coordinates; `agent_note` writes under `agent/{caller}/` and
  `agent_notes` reads under `agent/`. Each closes a class rather than a
  case: identity forgery, name squatting, and namespace escape.
- **The unit of waiting is the call, not the handle.** `agent_wait` takes
  an array and the Agency waits it against one deadline. Declaring the
  tool `Concurrent` is honest — it only reads — but `Exclusive` /
  `Concurrent` is consulted only under `tool_execution: Parallel`, which
  is not the shipped default, so nothing about a fan-out story may rest
  on it.
- **The agent tools ask the broker for nothing.** Their `requirements`
  are the empty policy: no writable roots, no readable roots, no env,
  network off. They touch no filesystem and spawn no process, so they
  compose with any session base.
- **`code_mode` is `ReplayNever` and `Exclusive`, and both are
  load-bearing.** A program's capability calls are arbitrary external
  effects with neither a minted identifier to reconcile onto (as
  `agent_spawn` has) nor a digest-bound pre-image (as `fs_edit` has), so
  a crash mid-execution must synthesize an interrupted result rather
  than run the program again. `Exclusive` is not only about workspace
  mutation: the broker pools budget per `{op_id, step_id}`, so a
  concurrent call in the same step would open that ledger with *its*
  budget — and a satellite needs two outstanding effects to exist at
  all.
- **A code-mode result never implies a jail that was not applied.** The
  seam hands back one enforcement report per stage that produced one,
  and the rendering names a degraded stage as degraded and an absent
  report as absent. A vetting rejection carries no sandbox field at all,
  because nothing ran.
- **A refusal is a repair brief.** Every violation vetting found is
  listed in one pass with its rule, its offending construct, its byte
  span where one exists, and the allowlist it was judged against;
  compiler diagnostics cross verbatim. One round trip per rule is
  exactly what in-band repair exists to avoid.
- **`agent_send` is `ReplayNever`; the rest are `ReplaySafe`.** A send
  mints a fresh entry id per admission, so a replay would deliver twice;
  a spawn's name derives from persisted coordinates, so a replay
  reconciles onto the same child.

## Deep Docs

- [docs/architecture/code-mode.md](../../docs/architecture/code-mode.md) —
  the pipeline behind `code_mode`, and what each of its layers confines.
- [packages/codemode/CLAUDE.md](../codemode/CLAUDE.md) — the far side of
  the code-mode seam.
- [docs/architecture/effects.md](../../docs/architecture/effects.md) —
  "Tools with correctness teeth", and the plane this package sits in.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-I (`tools`)": the
  anchor hash choice, `execution_mode`, workspace-relative requirements,
  the `fs_read` overflow exemption, harness-side filesystem tools, blob-ref
  readability, the timeout ceiling, ripgrep-missing detection.
- [packages/broker/CLAUDE.md](../broker/CLAUDE.md) — the door every jailed
  call goes through.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
