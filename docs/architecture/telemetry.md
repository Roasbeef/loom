# Telemetry

The `telemetry` package is Loom's structured logging. Every line it writes
is one JSON object on one line, carrying the event's level, a stable event
name, whichever correlation slots are known (`session`, `strand`, `op`,
`step`), and the call site's own fields. It exists so an operator can
reconstruct what a server did, including which strand and which operation a
line belongs to when several strands run at once, without a secret ever
landing in the output.

The package is small: a `Logger` value that call sites receive by injection,
a correlation `Context` that the logger carries, a four-level policy,
typed fields with two redaction rules, and a formatter installed on Erlang's
`logger`. It is a leaf over `core`, so any impure package can depend on it.
It belongs to no single plane. The orchestration plane
([orchestration](orchestration.md)) is its main caller, and it writes
nothing durable, so it has no part in the durability plane
([durability](durability.md)). Telemetry is for people reading output. The
event bus ([events](events.md)) is for code reacting to commits; the last
section below compares the two.

## Observability only

Telemetry is observability only (spec §3.4). The conversation store and the
usage ledger are the record, and the ledger is the billing source of truth.
No log line may be read back, and none may be given authority over a
durable row.

The code holds to this through its shape rather than a check:

- **Nothing reads a record back.** A `Sink` is `fn(Record) -> Nil`, and the
  production sink hands the rendered line to `logger` and returns. The one
  sink that delivers records anywhere a program can receive them,
  `log.to_subject`, exists for tests.
- **A log call returns `Nil` and cannot fail.** The `Sink` contract says a
  sink runs on the calling process and must not fail or block, because a
  log call may not change what the caller does.
- **A record carries no timestamp.** `core`'s clock is threaded: reading it
  returns a new clock. A log call that read the session clock would consume
  steps from it and shift the ids minted afterwards, so a line written for
  observation would change what the system records. The context slots are
  plain strings rather than `core` id types for the same reason.
- **A missing logger is silent.** A package given no logger uses
  `log.discard()`, which emits nothing, so no library test needs a running
  `logger` or has to tolerate output it did not request.

## How a line is written

A call site holds a `Logger` and calls one of `log.debug`, `log.info`,
`log.warn` or `log.error` with an event name and a list of fields. From
there:

1. The logger compares the record's level with its threshold. A
   record below the threshold is dropped before anything is built.
2. The logger's sink receives a `Record`: level, event, the logger's
   context, and the fields.
3. The production sink (installed by `log.erlang`) calls `record.render`,
   which is pure Gleam. It puts `level` and `event` first, then the known
   context slots in fixed order, then the call site's fields in the order
   given. Every field passes through `field.scrub` on the way. When a key
   repeats, the first occurrence wins, so a caller's field cannot shadow a
   context slot.
4. The finished JSON string crosses the FFI boundary once, as a `logger`
   report under the single key `loom` (`telemetry_ffi:emit/2` calls
   `logger:log/3`).
5. The stock `default` handler receives the event, with `telemetry_ffi` as
   its formatter. For a `loom` report, `format/2` writes the line verbatim
   plus a newline.

Building the JSON in Gleam keeps rendering and redaction in pure code that
the tests can reach. The formatter has nothing left to decide about Loom's
own lines, and it deliberately does not scrub them again: a second pass
would redact the identifiers the call site marked as safe (see
[Fields and redaction](#fields-and-redaction)).

### Lines Loom did not write

Everything else that reaches `logger` is foreign: an OTP crash report, a
supervisor report, a `gen_server` termination, a third-party library. The
formatter flattens the message text to one line (newlines become spaces),
runs it through `telemetry@field:scrub_text/1`, and wraps it in the same
envelope with `"event":"erlang"` and the text under `msg`. The correlation
slots come from the emitting process's `logger` metadata, when it has any
(see the next section). If a foreign event cannot be rendered at all, the
formatter writes a fixed `unformattable log event` line instead of raising,
because `logger` removes a formatter that raises and every later line would
be lost with it.

OTP ships no JSON handler, so "JSON handler" here means the `default`
handler with Loom's formatter. Keeping the stock handler keeps `logger`'s
own supervision and overload protection.

## Correlation context

A `Context` has four optional slots: `session`, `strand`, `op` and `step`.
They become known at different depths, and a line written before a slot is
known must still be written, so each is an `Option(String)`. An unknown slot
is omitted from the line rather than written as `null`, so a grep for
`"op":"op-7"` cannot match a line that never had an operation.

### The context travels as a value

The context rides inside the `Logger` a call site holds. Narrowing returns
a new logger and leaves the wider one unchanged:

- `log.for_strand(logger, strand)` names the strand;
- `log.for_step(logger, op:, step:)` names an operation and a step within
  it;
- `log.scoped(logger, context)` overlays any slots the argument knows, and
  keeps the rest (`context.merge`).

`context.with_op` clears the step, because a step id only means something
inside the operation that minted it.

The reason for a value is how Loom runs effects. Erlang `logger`'s process
metadata belongs to one process and is not inherited across `spawn`, and
every provider request, tool run and parked call runs on a process the
strand driver spawned (the effect sandwich in
[orchestration](orchestration.md)). Metadata alone would lose the context at
exactly that boundary, and lose it silently: the lines would still appear,
uncorrelated. The process dictionary has the same problem and is invisible
to the type system. A logger captured by the spawn closure cannot be lost,
because the compiler requires the closure to capture it.

In the runtime the flow is:

1. The strand driver's initializer narrows the injected logger with
   `log.for_strand` (`runtime/strand_runtime`), so every driver line carries
   the strand.
2. Each effect is dispatched and settled under `step_logger`
   (`runtime/strand_runtime.gleam:683`), which calls `log.for_step` with the
   operation id and the token's step id. That logger is what the spawned
   effect process captures.
3. When an operation finishes, the drive loop writes `operation.settled`
   through `log.scoped` with the operation id.

### Metadata is the fallback for foreign lines

`log.adopt(logger)` stamps the same slots onto the calling process's
`logger` metadata, under the keys `loom_session`, `loom_strand`, `loom_op`
and `loom_step`. It merges with any metadata already there. Loom's own lines
never read it; the formatter reads it only when wrapping a foreign line.
The strand driver adopts its logger at start, and an effect process
adopts its step logger once admitted, before running its body. An OTP
crash report from either process therefore lands with the same
correlation as the work it belonged to. `log.process_context()` reads the stamp back, for a process that inherited
work without inheriting a logger.

### What is populated today

The strand, operation and step slots are populated along the runtime path
above. Nothing in the tree sets the `session` slot: no caller outside the
package uses `context.for_session` or `context.with_session`. The daemon
passes one unscoped logger to every session it assembles, and the one line
that names a session, `daemon.session_start_failed`, does so as an ordinary
`field.ident("session", ...)`. A reader correlating lines across sessions
in one daemon therefore has the strand and operation ids to go on, not a
session id.

## Levels

`telemetry/level` defines four levels, `Debug`, `Info`, `Warning` and
`Error`, which are exactly the Erlang `logger` atoms of those names. OTP's
other four (`emergency`, `alert`, `critical`, `notice`) are left out: a
harness whose failure domain is one host has no pager or severity routing
to feed, and an unused level is one that call sites guess at.

The module doc states the policy every call site follows:

| Level | Meaning | Examples from the tree |
|---|---|---|
| `error` | No automatic recovery remains; an operator must act. | `strand.halted`, `daemon.start_failed`, `daemon.session_start_failed` |
| `warning` | Degraded but still progressing. | `retry.armed`, `effect.exited`, `projection.pull_failed`, `mcp.unavailable` |
| `info` | At most one line per durable state change; the default threshold. | `strand.started`, `operation.settled`, `daemon.listening`, `codemode.ready` |
| `debug` | Per-step effect dispatch and settlement. Off by default. | `effect.dispatched`, `effect.settled`, `distill.source_read` |

An effect that fails and reports the failure in-band is the system working,
so it is not an `error`. `info` is sized so that a full run at that level
is readable by a person. It is never written per planning pass, because the
drive loop replans many times per step.

The threshold comes from the environment variable `LOOM_LOG_LEVEL`
(`handler.level_variable`). `handler.threshold_named` parses it
case-insensitively, accepting `warn` and `err` as abbreviations, and falls
back to `info` when the variable is unset or unrecognised. It does not
refuse to boot over a misspelled level. The threshold is applied twice with
the same value: the `Logger` checks it before building a record, and
`handler.install` sets `logger`'s primary level to it, which is what filters
foreign lines.

## Fields and redaction

A field is a key and a typed value. The value constructors are:

- `Text`, free text, built with `field.text`. Always shape-scrubbed.
- `Ident`, a Loom-minted identifier such as an entry id, op id, digest or
  strand name, built with `field.ident`. Exempt from the shape rule only.
- `Count` and `Flag`, a number and a boolean. Never scrubbed.
- `Redacted`, what the rules produce. It renders as `<redacted>`.

An event name is a stable dotted string such as `operation.opened`, never
interpolated text; the variable part belongs in fields, where redaction
reaches it and a consumer can index on it.

No log line may carry a token, an API key or a capability token (spec
§3.3.4). The package enforces this in `field.scrub`, which every field
passes through, rather than asking each author. There are two rules, a key
rule for credential-named fields and a shape rule for credential-shaped
tokens in free text, and the typed `Ident` exemption applies to the second
only. [effects](effects.md#secrets) describes both rules, the 32-character
threshold and why it matches the tokens this tree holds, and the test that
plants secrets and greps the rendered bytes. The same `scrub_text` function
scrubs foreign lines, so the rules have one implementation.

## Installation and where lines go

Only an entry point installs the handler. A library that installed one
would reconfigure the `logger` of whatever VM embedded it, which is why
`handler.install` sits alone in its own module. `install(threshold:)` puts
the formatter on the `default` handler, sets the primary level, and returns
the `log.erlang` logger the entry point then injects everywhere. It is
idempotent.

Two entry points install it today, both as their first act so that no
boot failure lands on OTP's default text formatter:

- `client/daemon/main`, the `loomd` server;
- `client/distill`, the standalone distillation command.

Each reads `LOOM_LOG_LEVEL`. The daemon hands the logger down through
session assembly (`client/serve`) into `runtime/api.Options.logger`, the
advisor, the rule and schedule scanners, the memory distillation pass, and
the extension hook bus.

`install` configures only the formatter, so lines go where the `default`
handler writes: the process's standard output. There is no log file, level
file or rotation inside the package. When the `loom` launcher starts
`loomd` itself, it appends the server's stdout and stderr to
`logs/<path-hash>.log` under the state root (`~/.loom` by default; see
the path table in [client](client.md)). The name is the first 24 hex digits
of the SHA-256 of the session database's path. Nothing rotates that file. If a
launched server fails to become ready, the launcher's error message
includes the recent tail of that log.

To debug, set `LOOM_LOG_LEVEL=debug` in the environment that starts
`loomd`, then read or `grep` the lines by event name or correlation slot,
for example `"strand":"main"` or `"op":"<op id>"`. Lines carry no
timestamp: records have none by design, and neither the formatter nor the
launcher's redirect adds one. Order in the file is the only time
information.

## Telemetry and the event bus

Both are lossy, neither is authoritative, and they serve different readers.

| | Telemetry | Event bus |
|---|---|---|
| Reader | A person, or a tool outside Loom | Code inside the node: projection drivers, the gateway, test hubs |
| Carries | A description of what happened, with correlation and fields | An id and a seq meaning "go look" (plus the display-only `Outputs` window) |
| Acted on | Never, by Loom | Yes: a subscriber pulls from the store when a hint arrives |
| Transport | Erlang `logger`, one JSON line per event | An OTP `pg` scope, plain sends |
| Loss costs | A gap in the operator's view | Latency until the next pull |

A bus event is a hint that makes a read model converge sooner; a log line is
never input to any Loom process. The two meet in one place:
`events/projection` has no reply channel for a pull that fails on the hint
path, so it reports the fault as a `projection.pull_failed` warning. That
line is for the operator. The projection's recovery comes from the next
hint or sync, not from the log.

## The OpenTelemetry seam

Spec §3.4 makes OpenTelemetry export optional. Because a `Sink` is
`fn(Record) -> Nil` and `log.tee` composes two sinks, an exporter could
attach without changes to this package, mapping the context slots onto
trace and span identity and `level.severity` onto its own scale. Nothing
about an export path is built or tested, and there is no configuration for
one.

## Coverage

Only `runtime`, `events` and `client` import the package. `broker`,
`provider`, `tools`, `codemode`, `cap` and `session` write no log lines.
Their failures surface to callers as values, and reach the log only when a
caller in one of the three logging packages writes a line about them.
Program output that a person or script reads, such as the startup banner
and a usage error for a mistyped flag, stays on stdout or stderr as plain
text by design.

## Where the code lives

| Path | What it holds |
|---|---|
| `telemetry/log.gleam` | `Logger` (opaque), `Sink`, `new`, `discard`, `erlang`, `to_subject`, `tee`; narrowing (`scoped`, `for_strand`, `for_step`); the four write functions; `adopt` and `process_context`. |
| `telemetry/context.gleam` | `Context` and its four slots, the `with_*` builders, `merge`, and `fields`. The module doc argues for a value over metadata. |
| `telemetry/level.gleam` | `Level`, `parse`, `permits`, `severity`. The module doc is the level policy. |
| `telemetry/field.gleam` | `Field`, `Value`, the constructors, and the redaction rules: `scrub`, `scrub_text`, `secret_key`, `secret_shaped`, `credential_run`. |
| `telemetry/record.gleam` | `Record`, `to_json`, `render`: the pure rendering to one JSON line, with duplicate keys resolved. |
| `telemetry/handler.gleam` | `install`, `threshold_named`, `level_variable`: the entry-point-only installation. |
| `telemetry/internal/ffi_logger.gleam` | The confined `logger` bindings: install, primary level, emit, stamp, read stamp. |
| `telemetry_ffi.erl` | The Erlang shim, including the handler's `format/2`. |

Each path is relative to `packages/telemetry/src/`. Callers that shape the
correlation are in `runtime/strand_runtime` (strand and step scoping,
`log.adopt` on the driver and each effect process); the installers are
`client/daemon/main` and `client/distill`.

Related documents:

- `packages/telemetry/CLAUDE.md` lists the package's invariants in brief.
- `docs/spec-gaps.md`, "From §3.4 (`telemetry`)", records the decisions
  behind the propagation rule, the levels, redaction, and the seam.
- `docs/architecture/effects.md`, "Secrets", covers where secrets may live
  and the redaction test.
