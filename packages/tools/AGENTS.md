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

And `history_search`, through which a model asks the repository's
full-text index what it once knew. Same shape, same reason: `events`
owns the index and depends on nothing here, so the tool is a shell over
a **History** record of closures declared here and filled by
`client/history`. What this side owns is the model's half — the schema,
the limit clamp, the empty-query refusal, and the fence that keeps
another session's text quoted as data.

And `remember`, the model's one door into the repository's durable
memory. Same shape again, and the same reason twice over: `client/memory`
owns the memory session file, and the two caps that matter — redaction
through `telemetry/field.scrub_text`, and a lifetime ceiling held in a
durable counter — are things this package can neither perform nor read.
So the tool is a shell over a **Memory** record of one closure, and the
constants it states in its description (`max_note_chars`, `max_notes`)
are the single definition the far side enforces. There is no tool to read
memory back: recall of memory is a digest the host injects at run start,
so there is no read door to poison and no argument that could name one.

And `code_mode`, through which a model submits a *program* instead of a
call. It has the same shape as the agent family and the same reason for
it: `codemode` already depends on this package — its capability router
renders a `tool.Collected` — so the edge cannot run the other way. The
whole
pipeline — vet, hermetic compile, jailed satellite — sits behind a
**CodeMode** record of closures declared here and filled by
`client/codemode`. What this side owns is the model's half of the
contract: the schema, the clamped budget, the resolution of which of the
host's seams a submission is judged against, the capability prelude's
public signatures rendered into the description so a model does not author
blind, and the rendering that turns a vetting rejection, a compile error, a
dead satellite or a program's own reported failure into something a model
can repair from.

## Key Types

- `tools/tool.Tool` — the record every tool is: `name`, `description`,
  `prompt_snippet`, `schema`, `replay` (`ReplaySafety`),
  `execution_mode`, `requirements` (a function from workspace root to
  `SandboxPolicy`), and `run: fn(Ctx, JsonValue) -> ToolOutcome`.
  `prompt_snippet` is pi's `promptSnippet`: one line for the system
  prompt's available-tools index, and `None` omits the tool from that
  index without making it any less callable — the wire tool array is the
  authoritative definition and the index is prose.
- `tools/tool.Ctx` — every seam a tool may touch: workspace root, the
  driver's own coordinates (`strand`, `op_id`, `step_id`,
  `source_index`), base policy and grants, enforcement demand, the
  constructed env, the clock, a `FileSystem` record of functions
  (`read`, `write`, `create_directory_all`, `is_file`, `read_link`, and
  `rename` — the last for the atomic staging the blob store needs),
  `blob_root`, `clear_call` — the broker seam every jailed execution
  flows through — and `raise_refusal`, the other door onto the same
  escalation plane.
- `tools/tool.{RaisedRefusal, Escalated, no_raise}` — the raise seam a
  tool knocks on when it met a policy refusal somewhere `clear_call` is
  not. `RaisedRefusal` carries the broker's structured `Denial` (whose
  `wanted` is the diff an approval may grant) and the refused work's own
  budget deadline; `Escalated` is `Settle` or `Resume(grants:)`, the
  mirror of `client/escalate.Decision` that `tools` cannot import;
  `no_raise()` is the seam for a host with no escalation plane. It exists
  for `code_mode`, whose clearances happen inside the code-mode pipeline
  and so never pass `clear_call` (#97).
- `tools/agent.Agency` — the messaging seam: `spawn`, `send`, `wait`,
  `note`, `notes`, `roster`, plus the published `max_wait_ms` the wait
  tool's schema states. Every closure takes a `Caller` first and is
  judged against it.
- `tools/agent.{Caller, Handle, SpawnRequest, Provenance, Spawned,
  Waited, Outcome, Peer, Relation, Delivery, Refusal}` — the vocabulary
  crossing that seam. `Delivery` mirrors `runtime/api.Delivery` (which
  `tools` cannot import) the way `effects.ToolOutcome` mirrors the
  broker's `CallOutcome`.
- `tools/agent.{ResultSchema, ResultField, FieldType, Mismatch,
  TerminalResult}` plus `{parse_result_schema, render_result_schema,
  result_fields, validate_result, describe_mismatch, type_name,
  field_type_name}` — the result contract: the shape a parent may demand
  of a child, and the verdict a join hands back beside the prose report.
  A schema is the subset of JSON Schema `tool.object_schema` already
  emits — an object of named properties with one closed-set type each —
  and nothing wider; `parse_result_schema` is total and refuses what this
  harness cannot enforce rather than accepting it and ignoring it.
- `tools/agent.{slug, handle_to_string, parse_handle}` — the name and
  handle grammar: `[a-z0-9-]`, capped, `/` and `#` rejected, and a total
  parse back from `{strand}#{operation}`.
- `tools/agent.{Minter, minting_step, call_site_digest}` — who, inside
  one planned tool call, minted a child. `ToolCall` is a model's own
  `agent_spawn`; `Program(ordinal:)` is a code-mode program on its
  `ordinal`-th spawn admission, which is a fact `{operation, step_id,
  source_index}` has nowhere to put. `minting_step` is the step a spawn
  is *recorded* under and reconciled against, and `call_site_digest` is
  the constant-width, model-proof half of a minted child's name.
- `tools/codemode.CodeMode` — the code-mode seam: `execute`, plus the
  published `seams`, `default_within_ms` and `max_within_ms` the tool's
  description and schema state, so the sentence the model is charged for
  on every request cannot drift from the policy the program is judged
  against.
- `tools/codemode.{Seam, SeamOffer, Seams}` plus `{seam_name, offered,
  one_seam}` — which allowlist a submission is judged against.
  `Seam` mirrors `codemode/vet/policy.Seam` (`WorkspaceSeam`,
  `OrchestrationSeam`); a `SeamOffer` is one seam's published
  `allowed_imports`, `serviced_caps` and `extra_surfaces`; `Seams` is
  what this host serves, as a named `default` plus `alternates`, so a
  host can never offer none and an unnamed submission never has an
  ambiguous seam. `extra_surfaces` is the one part of the description a
  *host* supplies rather than the committed artifact: a `cap/mcp/<server>`
  façade is generated from one host's configured server (issue #106), so
  it cannot be in `tools/prelude`, and it renders after the committed
  blocks under the same seam's heading.
- `tools/codemode.{PolicyRefusal, Execution.refusal}` — whether policy
  composition stopped this execution before it ran, and whether an
  approval could overturn it. `NothingRefused` or `RunRefused(denial:,
  deadline_ms:)`, and a *peer* of the enforcement report rather than a
  field inside it, for the reason `codemode`'s `widening` is one.
- `tools/codemode.{Request, Execution, ExecResult, Outcome, Rejection,
  Rule, Location, CompileFailure, RunFailure, Enforcement, Report}` — the
  vocabulary crossing that seam, mirroring `codemode/vet`,
  `codemode/compile`, `codemode/satellite` and `cap/report` rather than
  importing them. `Request.seam` is the resolved seam the execution is
  judged and routed under. `RunFailure` is the one deliberate narrowing:
  eight `satellite.RunError` variants become the four that read
  differently to a model, with the pipeline's reason text carried
  verbatim.
- `tools/prelude.surfaces` — **generated** (`make gen-prelude`): every
  capability-prelude module paired with its public surface — `pub type`
  declarations with their constructors, `pub const`, `pub fn` signatures,
  each under the prelude's own `///` docs — rendered from `gleam export
  package-interface` over `packages/cap`. Unfiltered by design;
  `tools/codemode` selects from it through a seam's `allowed_imports`.
- `tools/history.{History, Hit, Scope, Refusal, tool, tool_name,
  clamp_limit, min_limit, max_limit, default_limit, fence}` — the recall
  seam and the `history_search` tool over it. `History.search` takes a
  trimmed query, an already-clamped limit and a `Scope`
  (`Repository` | `ThisSession`) and answers hits or a `Refusal`
  (`IndexUnavailable` | `IndexRefused`). The tool never names a session:
  `ThisSession` means the *host's*, because a model that could name one
  could read a session it was never given.
- `tools/schedule.{Schedules, Limits, Request, RequestedTiming, Created,
  Listed, Wake, Refusal, tools, create_tool_name, list_tool_name,
  cancel_tool_name, refusal_outcome, refusal_reason}` — the model's own
  door onto scheduled heartbeats, a value over a seam the host fills
  (`client/scheduleseam`), exactly as `remember` is. Three tools, exported
  as one list so a host cannot register the writer without the reader.
  `Limits` is passed **in** rather than defined here — the reverse of
  `remember`'s caps — because these bounds are enforced on the far side
  of the seam, and the direction is decided by which side owns the check.
  `Request.wake` is what the model asked for and `Created.wake` is what
  the operator's policy granted, which is the whole reason `create`
  returns a record rather than `Nil`: under a `steer` policy the call
  succeeds and the result says it will only steer, rather than refusing
  and teaching the model to retry against a wall that will not move.
  Both are `Wake` (`WakesIdle | SteersOnly`), this door's own name for a
  distinction `client/schedule` holds under the same two names on the
  durable side — `tools` may not import it, so `client/scheduleseam`
  translates, exactly as it does for `Refusal`. The model still writes
  `wake: true` and still reads a JSON boolean back.
  `Refusal` gives each reason its own code because a model can act on the
  difference; `refusal_reason` exposes the sentence without the
  `ToolOutcome` wrapper, which is what `client/codemode` maps onto the
  code-mode capability vocabulary. Both writers are `Never`/`Exclusive`:
  a replayed create would silently replace a schedule the model believes
  it already has, and two in one batch would race for the same ceiling.
- `tools/remember.{Memory, Refusal, tool, tool_name, note_type,
  entry_types, max_note_chars, max_notes, refusal_outcome,
  says_something}` — the memory door and the `remember` tool over it.
  `Memory.remember` takes the model's text untrimmed and answers `Nil` or
  a `Refusal` (`MemoryBusy` | `MemoryUnavailable` | `NoteTooLong` |
  `CeilingReached` | `NothingToRemember`); `MemoryBusy` is what a caller
  gets while a distillation run holds the memory session's writer lease,
  and it is a refusal to say again later, not a fault. `note_type` is the
  only type this door can produce and `entry_types` exists so the
  disjointness test against `client/memory.pipeline_types` intersects two
  lists rather than comparing two spellings.
- `tools/tool.ToolOutcome` — text plus `is_error` plus optional typed
  `details`, mirroring pi's `ToolResultMessage.isError` (pi §3.8), plus
  `terminate`.
- `tools/tool.Terminate` (`ContinueRun` | `TerminateRun`) — whether the
  run ends once this call's batch settles. `success`, `failure` and
  `with_details` all answer `ContinueRun`, so ending a run is something
  a tool says rather than something it falls into;
  `client/wiring.run_tool` converts the answer into the `Bool` on
  `effects.ToolCompleted`, which is the one place the two vocabularies
  touch. No built-in answers `TerminateRun`.
- `tools/tool.Registry` — opaque name → `Tool` lookup; `dispatch` is
  total. It remembers registration order as well as the table:
  `names` is sorted (the provider cache's byte prefix), while
  `registered` and `snippets` read in the order tools were registered,
  which is the order the prompt's index prints.
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
  and `client/contributions` registers all four families; `client/history` fills
  the `history.History` record and `client/memory` fills the
  `remember.Memory` record),
  `conformance` (the wiring/e2e suites drive the same adapter).
- **Generated from**: `packages/cap`, at build time and not as a
  dependency edge — `scripts/gen-prelude.sh` runs `gleam export
  package-interface` there and writes `tools/prelude`. Nothing in this
  package imports `cap`, and nothing at runtime shells out; the artifact
  is committed and `scripts/gen-prelude.sh --check` (inside `make check`)
  fails the build when it and its inputs part company.
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
  workspace readable, nothing writable, network off; `history_search`
  asks for **nothing at all** — no readable root, no writable root, no
  network — because it starts no jailed process and touches no path: the
  index is read harness-side through the seam, and `remember` asks for
  nothing for the same reason; `code_mode` asks
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
- **`protected` is enforced harness-side too, on the resolved path, and
  no grant lifts it.** The base policy's never-writable list is masked by
  bwrap for a *jailed* process, and the `fs_*` tools meet no jail — so
  `fs_write` and `fs_edit` share one `resolve_for_write`, which applies
  `resolve_real` and then refuses a target at or under any
  `ctx.base_policy.protected` entry. The order is the property: a
  workspace-internal symlink onto `.git/config` is only visible as such
  once resolved. Containment alone left `.git/hooks/post-checkout`
  writable by the model's own tool, which is code execution outside the
  jail on the next checkout, and would have handed a vetted code-mode
  loop more filesystem authority than its own jailed `proc.run` (issue
  #105). Matching is by path component (`.gitx` is not under `.git`),
  the same predicate `broker/policy.covered_by` and
  `codemode/launch.covers` use, and it is applied to the entry's lexical
  *and* resolved forms so a symlinked workspace root cannot separate the
  two enforcement points. Grants are deliberately not consulted:
  `policy.Grant` has no variant for `protected` and `apply_grant` never
  writes the field. The refusal is in band as `PathError.ProtectedPath`,
  opening `permission denied:` and naming the entry that matched, with
  `details.error = "protected_path"`. Reads are untouched — an
  asymmetry with the jail, which masks a protected path out of view
  entirely — and stated in `resolve_for_write`'s doc rather than
  glossed.
- **A `protected` list the jail would refuse fails the harness closed
  too.** A non-absolute entry cannot be applied: `normalize` roots it at
  `/`, where it covers nothing under any workspace, so a list written as
  `protected: [".git"]` used to protect nothing while reading as though
  it did. The jail refuses the same value loudly —
  `broker/policy.validate` answers `RelativePath` and the clearance
  never happens — and a harness that quietly permitted what the jail
  refuses is the worse half of that pair. So `resolve_writable` checks
  absoluteness *before* it resolves anything and refuses the write as
  `PathError.ProtectionMisconfigured`, in band, naming the entry, with
  `details.error = "protection_misconfigured"`. It refuses **any** path,
  not just the one the entry meant to cover: what a misconfigured list
  intended is exactly what cannot be recovered from it. Reads stay
  untouched, the same asymmetry the entry above has.
  `client/serve.base_policy_fault` closes the other end, refusing the
  boot outright, so the in-band refusal is the backstop rather than the
  operator's first notice.
- **One whole-file write behind both doors.** `fs.write_whole` creates
  missing parents and then writes, and both `fs_write` and the code-mode
  bridge's `fs.write` closure call it — so `new_dir/file.txt` means the
  same thing whichever door a write came through. Two doors onto one
  workspace disagreeing about that is a difference discoverable only by
  hitting it.
- **A blob is established by a rename, never by a write.** Content
  addressing is only worth something if nothing can be reached under an
  address but the content it names, and a torn direct write leaves
  exactly that — a partial file whose SHA-256 name vouches for the whole
  of it, believed by every later reader. So `blob.write_addressed`
  stages the bytes under `blob.temp_path` in the blob root (same
  filesystem, so `rename(2)` is atomic) and renames them into place; a
  crash between the two leaves a stray `.tmp` nothing reads. The staging
  name carries a tag unique to one write — the tool call's own
  `{op_id, step_id, source_index}` here, random bytes for
  `client/codemode`'s `report.emit` — because two concurrent first
  writes of identical bytes are precisely the pair an address cannot
  separate, and on a shared staging name they interleave.
- **Replay safety is declared per tool and load-bearing.** `bash` is
  `Never` — an arbitrary external effect must yield a synthetic interrupted
  result on crash, never a re-execution. `grep`, `fs_read`, `fs_write`, and
  `fs_edit` are `Safe`: a read, a read, an idempotent write, and a
  digest-bound edit respectively. `history_search` is `Safe` too, and
  needs no budget headroom with it: it clears nothing through the
  broker, so a batch of them shares no ledger to be refused out of.
  `remember` is `Never`: it mints a fresh entry id per admission, so a
  replay would write the note twice and spend two of the lifetime
  ceiling's slots. The synthetic interrupted result is the right answer —
  saying it again is cheap.
- **`execution_mode` is a scheduling constraint**: `Exclusive` for bash,
  write, edit, and `remember` (they may mutate something shared — for
  `remember`, the memory session, whose writer lease two calls in one
  batch would fight over for no reason a caller could see);
  `Concurrent` for read and grep. A `Concurrent` tool's own declared
  budget must agree with that tag: the broker pools `max_outstanding`
  per `{op_id, step_id}` — the whole batch, not one call's fan-out
  (`docs/adr/005-budget-pooling-granularity.md`) — so a `Concurrent`
  tool sharing a batch with itself
  needs headroom above `1` in that same ledger, or a second concurrent
  call is refused `OutstandingCapReached` for no reason a caller can see
  (issue #50; `grep.max_concurrent_searches` is the one declared to
  date).
- **A search result is quoted history, and the fence is the mechanism.**
  `history_search` hits are text some model wrote, possibly in another
  session months ago, on its way into *this* model's context. The
  rendering fences them, says above the fence that nothing inside it is
  addressed to the reader, and breaks any backtick run in a snippet that
  could close the fence early. A snippet that could close it would make
  everything after it read as the harness talking.
- **A model cannot choose what memory it writes.** `remember` takes one
  string and no type: the host writes `memory/note` and nothing else,
  which is half of the disjointness the distillation pipeline's own types
  rest on. A model can never forge a "consolidated" fact, and the
  pipeline's parser refuses `note:` from the other direction.
- **The limit clamp is the tool's, not the index's.** A limit reaches SQL
  `LIMIT ?`, and SQLite reads a *negative* limit as unbounded — the
  opposite of `storage`'s convention, where a non-positive limit returns
  nothing. `clamp_limit` is what stops a limit computed by subtraction
  from pulling the whole repository index into a context.
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
- **A minted name's discriminating half has a constant width and no
  model input.** A child's name is `sub:{parent}/{slug}-{digest}`: the
  slug is the purpose, bounded, and decorative, while the digest is
  sixteen hex characters over `{operation, minting step, source index}`
  and is the whole of who owns the child. The split is what closes two
  ways of colliding two minters onto one name. A discriminator appended
  to a *slugged* field is erased by that field's cap — a production step
  id is a 36-character UUID and the slug cap is 24, which is exactly how
  a `-program` step suffix came to reach no name at all — and a
  constant-width field has no cap left to be truncated against. And a
  discriminator sharing a field with model text can be steered by
  choosing the text, which is why the digest takes none. Lengthening the
  slug cap fixes neither; `agency_test`'s
  `a_step_slug_cannot_carry_a_discriminator_test` is the arithmetic.
- **A model never supplies its own identity, a strand name, or a
  blackboard prefix.** `agent.caller` is built from `Ctx` alone, so a
  model that names another strand in its arguments does not become it;
  `agent_spawn` takes a *purpose* and the Agency mints
  `sub:{parent}/{slug}-{digest}` from the call's own durable
  coordinates; `agent_note` writes under `agent/{caller}/` and
  `agent_notes` reads under `agent/`. Each closes a class rather than a
  case: identity forgery, name squatting, and namespace escape.
- **The unit of waiting is the call, not the handle.** `agent_wait` takes
  an array and the Agency waits it against one deadline. Declaring the
  tool `Concurrent` is honest — it only reads — and under the shipped
  `tool_execution: Parallel` it is consulted for real, so single-handle
  waits in one batch do overlap. The array is still the unit, for three
  reasons the setting cannot touch: a session may set `tool_execution`
  back to `sequential` through the gateway config key; one `Exclusive`
  sibling (`bash`, `fs_write`, `code_mode`) fences the whole batch and
  brings the serial deadline windows back; and eight waits are eight
  effect processes with eight intents, settlements and deadlines to
  reconcile where the array needs one of each. Overlap makes the
  degenerate case cheaper — it does not carry the fan-out story, and no
  invariant here rests on it.
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
- **The description carries the prelude's signatures, and they are
  filtered through the allowlist rather than through the package.** A
  model writing a program has no autocomplete and no language server: it
  authors blind and learns a signature from a `CompileFailed` round trip
  carrying a whole hermetic build. So every module a seam admits is
  rendered into the description in full, statically — nothing is added to
  the tool array and nothing varies between turns, because tool bytes are
  the byte prefix of the provider's cached region and a surface that
  changes per turn does not cost a cache write, it costs the cache
  (issue #36). `gleam export package-interface` reports eleven modules
  and the two seams admit ten between them: `cap/runtime` is on neither,
  so `surface_text` runs each `SeamOffer.allowed_imports` over
  `prelude.surfaces` and not the other way round. Advertising a module
  vetting will reject is the same class of lie as classifying a
  submission by reading its imports. The signatures follow the same
  per-seam split as the import lists — shared modules stated once, each
  seam naming only what it adds — so an orchestration-only host pays for
  `cap/strand` and `cap/report` and for none of the other nine. Measured
  against the shipped allowlists, the whole description is 17,678 bytes
  for a workspace-only host, 15,205 for an orchestration-only one, and
  28,818 for a host serving both; about half of that is the `pub type`
  declarations, which are not optional because a program that cannot name
  `proc.Output`'s `stdout` field cannot read the output it paid for.
- **A code-mode result never implies a jail that was not applied.** The
  seam hands back an `Enforcement` naming *both* jailed stages — the
  hermetic build and the satellite node — as a record rather than a
  list, so neither can go unmentioned. Each is either `Enforced`, whose
  applied and `skipped` layers are separate fields so a layer the kernel
  did not provide can never render as one it did, or `Unreported` with
  the reason there is no report. A vetting rejection reports both stages
  as unreported *saying vetting refused the program*, which is a
  different statement from silence (issue #5).
- **A refusal is a repair brief.** Every violation vetting found is
  listed in one pass with its rule, its offending construct, its byte
  span where one exists, the **seam** it was judged against and that
  seam's allowlist; compiler diagnostics cross verbatim. One round trip
  per rule is exactly what in-band repair exists to avoid. Parse failures
  report the unexpected token and byte offset without teaching a dialect
  workaround: the Glance floor and codemode corpus now pin the submitted
  constructs that the shipped compiler accepts.
- **A submission is judged against exactly one seam, and it is the one
  it named.** `CodeMode.seams` is what this host serves; the shell
  resolves the call's `seam` argument against it, defaults an unnamed
  submission to `seams.default`, and refuses an unserved or unknown name
  in band naming what is on offer — never reinterpreting it as the other
  seam, which in one direction is a refusal the model cannot act on and
  in the other a widening nobody chose. Nothing classifies a submission
  by reading its imports: the description would then be a claim about a
  decision already taken.
- **The choice costs nothing where there is no choice.** The `seam`
  property appears in the schema and the second import list in the
  description only when this host serves more than one seam, and where
  it does, the seams' shared imports are stated once rather than
  duplicated. Tool bytes render ahead of the system prompt and are the
  byte prefix of the provider's cached region, so every word is paid on
  every request of every strand for the life of the session — but the
  lists stay *in* the description rather than being deferred to the
  rejection, because a model that has to guess an import surface pays a
  whole wasted submission in output tokens, which is the dearer side of
  that ledger.
- **A result contract is a lower bound, refused loudly at both ends.** A
  spawn may carry a `result_schema`; the child records the matching value
  as an ordinary `agent_note` under `result_note_key`, and `Waited.Ready`
  carries the verdict as a `TerminalResult` beside the prose `report` —
  never instead of it, because prose is what a human and a reading model
  want and typed JSON is what a program branching on `found.files` wants.
  Three properties are load-bearing. A malformed schema is refused in the
  shell, before the Agency is called, so the parent learns about its own
  mistake in the turn it made it rather than after joining a child that
  could never satisfy it. A mismatch always names both sides — the
  schema in full and what actually arrived — because a refusal that says
  only "did not match" costs the reader a round trip to learn what it
  could have been told. And `NoResultAsked` is its own variant rather
  than an empty `Result`, so a spawn that named no schema renders exactly
  the text and exactly the details object it rendered before contracts
  existed. Surplus fields in a result are not a failure: the contract
  says what the child owes, not all it may say.
- **A code-mode policy refusal is raised once, for the whole execution,
  and only from the run phase.** The shell asks `Ctx.raise_refusal` at
  most once per call and re-executes at most once on a `Resume`; a second
  refusal stands in band. Per-clearance would park inside a live
  satellite — the program's own capability call times out long before a
  human answers, the pooled wall deadline runs down while they decide,
  and the node holds one outstanding effect throughout — and, worse for
  consent, would ask a human about a `cap_call` no client rendered, since
  an approval binds to the *tool call's* arguments (#65) and a
  `code_mode` call's arguments are the program. The other two clearance
  points raise nothing: the hermetic build composes with this execution's
  grants already dropped, so no approval can widen it, and a capability
  call refused inside a *running* program is refused after effects have
  happened, which is precisely what `replay: tool.Never` says must never
  be repeated. Both are argued where the value is built
  (`client/codemode`).
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
