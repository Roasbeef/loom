# tools

## Purpose

The core tool set and the behaviour every tool implements: `bash` and
`grep` through the broker's jailed executor, `fs_read` / `fs_write` /
`fs_edit` harness-side with hashline anchoring and workspace path
discipline, plus content-addressed blob overflow for large output. WP-I.
Tool failures are data, never crashes.

## Key Types

- `tools/tool.Tool` — the record every tool is: `name`, `description`,
  `schema`, `replay` (`ReplaySafety`), `execution_mode`, `requirements`
  (a function from workspace root to `SandboxPolicy`), and
  `run: fn(Ctx, JsonValue) -> ToolOutcome`.
- `tools/tool.Ctx` — every seam a tool may touch: workspace root, op and
  step ids, base policy and grants, enforcement demand, the constructed
  env, the clock, a `FileSystem` record of functions, `blob_root`, and
  `clear_call` — the broker seam every jailed execution flows through.
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
- **Depended on by**: `conformance` (the wiring adapter builds the registry
  and dispatches through it).
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
  workspace readable, nothing writable, network off. `RefuseNarrowed` means
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

## Deep Docs

- [docs/architecture/effects.md](../../docs/architecture/effects.md) —
  "Tools with correctness teeth", and the plane this package sits in.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From WP-I (`tools`)": the
  anchor hash choice, `execution_mode`, workspace-relative requirements,
  the `fs_read` overflow exemption, harness-side filesystem tools, blob-ref
  readability, the timeout ceiling, ripgrep-missing detection.
- [packages/broker/CLAUDE.md](../broker/CLAUDE.md) — the door every jailed
  call goes through.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc graph.
