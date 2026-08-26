# telemetry

## Purpose

Spec §3.4, and nothing else: structured logs through Erlang `logger`
with a JSON handler, carrying `{session, strand, op, step}` on every
line. A leaf package over `core` alone, so every impure package can
depend on it and none of them inherits anything but the standard
library. It holds three decisions the rest of the tree is expected to
follow — how correlation context travels, what is logged at which
level, and the rule that no log line may carry a secret — and it
enforces the third rather than asking for it.

Telemetry is observability only. Nothing here reads a record back and
nothing here may be given authority over a durable row: the
conversation store and the usage ledger stay the record, and the ledger
stays the billing source of truth (§3.4).

## Key Types

- `telemetry/level.Level` — `Debug | Info | Warning | Error`, exactly
  the four Erlang `logger` atoms of those names, so a value crosses to
  `logger:log/3` unchanged. `name`, `parse` (total, case-insensitive,
  takes `warn`/`err`), `permits(threshold:, level:)`, and `severity`
  for a sink that maps onto its own scale. The **level policy** is the
  module doc; read it before adding a call site.
- `telemetry/context.Context` — the four optional correlation slots.
  `for_session`, `with_session`/`with_strand`/`with_op`/`with_step`,
  `merge` (the argument's known slots win), and `fields`, which renders
  them as `Ident` fields in a fixed order. `with_op` clears the step: a
  step id is only meaningful inside the operation that minted it.
- `telemetry/field.{Field, Value}` — `Text | Ident | Count | Flag |
  Redacted`, plus the constructors `text`/`ident`/`count`/`flag`.
  `Ident` is the typed opt-out from the value-shape redaction rule and
  means "I know this is a loom-minted identifier"; it is not an opt-out
  from the key rule.
- `telemetry/field.{scrub, scrub_text, secret_key, secret_shaped,
  redacted_marker, credential_run}` — the redaction rules as pure,
  separately testable functions. `scrub_text` is also what the Erlang
  formatter calls back into for foreign lines.
- `telemetry/record.{Record, to_json, render}` — one event and its
  rendering to one line of JSON. Pure and total; `render` applies both
  redaction rules and resolves duplicate keys (first wins).
- `telemetry/log.{Logger, Sink, new, discard, erlang, to_subject, tee}`
  — the injected seam. `Logger` is opaque: threshold and context are
  invariants, not data a caller may replace wholesale.
- `telemetry/log.{scoped, for_strand, for_step, context, threshold}` —
  narrowing, which returns a new logger and never mutates the wider
  one.
- `telemetry/log.{debug, info, warn, error}` — the four call sites.
- `telemetry/log.{adopt, process_context}` — the metadata half of the
  propagation decision: stamp this process's `logger` metadata so lines
  we do *not* author land correlated, and read it back.
- `telemetry/handler.{install, threshold_named, level_variable}` — the
  boot-time installation an entry point (and only an entry point) calls,
  and the `LOOM_LOG_LEVEL` resolution behind it.

## Relationships

- **Depends on**: `core` (for `core/json`'s total serializer — the
  rendered line is a `JsonValue`, so escaping and duplicate-key
  handling are the house implementation rather than a second one) and
  `gleam_erlang` (`Subject`, for the capturing sink). Nothing else.
- **Depended on by**: `runtime` (the drive loop and every effect it
  spawns), `client` (the boot, the entry point's two channels, and the
  logger it injects into `api.Options`), `events` (the projection
  driver's pull faults).
- **FFI**: `telemetry/internal/ffi_logger` over `telemetry_ffi.erl` —
  `logger:update_handler_config/3`, `logger:set_primary_config/2`,
  `logger:log/3`, `logger:set_process_metadata/1`,
  `logger:get_process_metadata/0`, plus the handler's `format/2`.
  Nothing in the shim decides what a line says; `format/2`'s one
  judgement call is delegated back to `telemetry@field:scrub_text/1` so
  the redaction rules have exactly one implementation.

## Traffic

- **Actor messages**: none. This package starts no process. The one
  sink that sends anything is `to_subject`, which is a plain
  `process.send` into a caller-owned subject and exists for tests.
- **Commits**: none, ever. See Purpose.
- **Registers**: none.
- **Wire**: one JSON object per line on the `default` handler's stream.
  Ours are rendered by `record.render`; foreign lines (OTP crash
  reports, third-party libraries) are wrapped by the formatter into the
  same envelope with `"event":"erlang"`, flattened to one line, and
  scrubbed whole.

## Invariants

- **Correlation travels as a value, not as ambient state.** Erlang
  `logger`'s process metadata is not inherited across `spawn`, and
  loom's effect sandwich is nothing but spawns — every provider
  request, tool run and parked call happens on a process the strand
  driver started. A metadata-only design would therefore lose the
  context exactly where interleaved strands make it matter, and lose it
  *silently*: the lines still appear, just uncorrelated. So the context
  rides in the `Logger` the spawn closure captures, and the compiler
  enforces the capture. The process dictionary was rejected for the
  same non-inheritance plus invisibility to the type system.
- **Metadata is the fallback for foreign output, never the mechanism.**
  `log.adopt` stamps the same context onto the spawned process so an
  OTP crash report from an effect process is not orphaned. Our own
  lines never read it.
- **No log line carries a token, an API key, or a capability token**
  (spec §3.3.4, `docs/architecture/effects.md`). Two independent rules,
  because either alone has a known hole: a **key rule** replaces any
  field whose key names a credential, whatever it holds, and a **shape
  rule** replaces any token in free text that carries a vendor prefix
  or is an unbroken run of at least `credential_run` credential-alphabet
  characters. Only the offending token is replaced, so a scrubbed line
  is still a diagnostic. `telemetry/redaction_test` plants a provider
  key, a 64-hex clearance token and a 43-character channel token under
  both a denylisted and an innocent key and greps the rendered bytes.
- **The shape rule's exemption is typed.** 32 unbroken characters is
  also what a digest looks like, so `Ident` opts a value out — and only
  out of the shape rule. Every exemption is therefore a deliberate,
  greppable act by an author who knew what the value was, and no
  exemption can hide a value whose key already said "credential".
- **Rendering is pure.** `record.render` touches no clock, no process
  and no handler, which is what makes the redaction rule testable by
  grepping bytes. The JSON is built in Gleam and handed to `logger` as
  a finished line, so the formatter has nothing left to decide about
  our own lines — and deliberately does not re-scrub them, which would
  redact the identifiers `Ident` exempted.
- **A record carries no timestamp.** §0.2 makes time an injected
  `Clock`, and `core`'s clock is threaded: a log call that read it
  would consume steps and shift the ids minted afterwards, so a line
  written for observation would change what the system durably records.
  The handler stamps `logger`'s own time instead.
- **A logger is injected, never reached for.** A package that was given
  none uses `discard()`, which emits nothing, so logging can never be
  the reason a library test needs a running VM or tolerates output it
  did not ask for.
- **Only an entry point installs a handler.** A library that installed
  one would silently reconfigure the VM of whatever embedded it, which
  is why `install` lives in its own module with one function.
- **OpenTelemetry is a seam, not a build.** A `Sink` is
  `fn(Record) -> Nil` and `tee` composes two, so an exporter attaches
  without changing anything here. Nothing about an export path has been
  built or tested, and no configuration surface pretends otherwise.

## Deep Docs

- [docs/loom-implementation-spec.md](../../docs/loom-implementation-spec.md)
  — §3.4 (what this package exists for), §3.3.4 (the secret invariant it
  enforces), §0.2 (injection, FFI confinement, purity layering).
- [docs/architecture/effects.md](../../docs/architecture/effects.md) —
  where secrets are allowed to be, and why logs are not on the list.
- [docs/spec-gaps.md](../../docs/spec-gaps.md) — "From §3.4
  (`telemetry`)": the propagation decision, the level policy, the
  redaction rules, and what was left as a seam.
- [Root CLAUDE.md](../../CLAUDE.md) — repo ground rules and the doc
  graph.
