//// The logging seam: what a call site holds, and what a host injects
//// into it.
////
//// A `Logger` is a value carrying three things — where records go
//// (`Sink`), how much is emitted (`Level`), and the correlation
//// context every record it writes inherits. Spec §0.2's injection
//// conventions apply: a package never reaches for a global logger, it
//// receives one, and a test injects a capturing sink and asserts on
//// records instead of scraping stdout. A package handed nothing uses
//// `discard`, which emits nothing at all, so logging can never be the
//// reason a library needs a running VM.
////
//// The context-propagation decision — a value, not the logger's
//// metadata, not the process dictionary — is argued in
//// `telemetry/context`. The level policy is in `telemetry/level`. Both
//// are load-bearing enough to live next to the types they constrain
//// rather than in a report nobody reads twice.
////
//// ## The OpenTelemetry seam
////
//// §3.4 makes OTel export optional, and this is where it would attach:
//// a `Sink` is `fn(Record) -> Nil`, an exporter is a sink, and `tee`
//// composes two. A span exporter would map `Record`'s four context
//// slots onto its own identity — `session` as the trace, `op` as a
//// span, `step` as a child — and `level.severity` onto its severity
//// number. Nothing in this package needs to change to admit one, which
//// is the whole point of leaving it a seam: no dependency, no build,
//// no unused configuration surface, and no pretence that an export
//// path has been tested.
////
//// What is deliberately *not* here: nothing reads a record back.
//// Telemetry is observability only (§3.4) — the conversation store and
//// the usage ledger are the record, and no sink may be given authority
//// over a ledger row.

import gleam/erlang/process.{type Subject}
import telemetry/context.{type Context}
import telemetry/field.{type Field}
import telemetry/internal/ffi_logger
import telemetry/level.{type Level}
import telemetry/record.{type Record, Record}

/// Where records go. A sink runs on the calling process and must not
/// fail or block: a log call is not allowed to change what the caller
/// does.
pub type Sink =
  fn(Record) -> Nil

/// A logger, as injected.
///
/// Opaque because two of its three fields are invariants rather than
/// data: the threshold must be consulted *before* the sink is called
/// (so a filtered-out record costs nothing to build), and the context
/// may only ever be narrowed through `scoped`, never replaced wholesale
/// by a caller who would then drop the session it inherited.
pub opaque type Logger {
  Logger(sink: Sink, threshold: Level, context: Context)
}

/// A logger over an injected sink.
///
/// ## Examples
///
/// ```gleam
/// log.new(sink: log.to_subject(inbox), threshold: level.Debug)
/// ```
///
pub fn new(sink sink: Sink, threshold threshold: Level) -> Logger {
  Logger(sink:, threshold:, context: context.anonymous)
}

/// A logger that emits nothing. The default a package uses when its
/// host injected none, and the right thing in a pure unit test.
///
/// ## Examples
///
/// ```gleam
/// log.debug(log.discard(), "drive.planned", [])
/// ```
///
pub fn discard() -> Logger {
  Logger(
    sink: fn(_) { Nil },
    threshold: level.Error,
    context: context.anonymous,
  )
}

/// A logger writing through Erlang `logger` — what a booted server
/// injects. The handler must already be installed (`telemetry/handler`)
/// or the VM's default formatter will render the line as an Erlang
/// report instead of JSON.
///
/// ## Examples
///
/// ```gleam
/// log.erlang(threshold: level.Info)
/// ```
///
pub fn erlang(threshold threshold: Level) -> Logger {
  new(sink: emit, threshold:)
}

/// A sink that sends every record to a subject — the capturing sink a
/// test injects. Safe across processes: an effect process spawned with
/// a logger built this way delivers into the same inbox.
///
/// ## Examples
///
/// ```gleam
/// let inbox = process.new_subject()
/// log.new(sink: log.to_subject(inbox), threshold: level.Debug)
/// ```
///
pub fn to_subject(subject: Subject(Record)) -> Sink {
  fn(entry) { process.send(subject, entry) }
}

/// Fans one record out to two sinks. The composition an OpenTelemetry
/// exporter would attach through.
///
/// ## Examples
///
/// ```gleam
/// log.tee(log.to_subject(inbox), exporter)
/// ```
///
pub fn tee(first: Sink, second: Sink) -> Sink {
  fn(entry) {
    first(entry)
    second(entry)
  }
}

/// The logger's threshold.
///
/// ## Examples
///
/// ```gleam
/// assert log.threshold(log.discard()) == level.Error
/// ```
///
pub fn threshold(logger: Logger) -> Level {
  logger.threshold
}

/// The context every record this logger writes will carry.
///
/// ## Examples
///
/// ```gleam
/// assert log.context(log.discard()) == context.anonymous
/// ```
///
pub fn context(logger: Logger) -> Context {
  logger.context
}

/// Narrows the logger's context: every slot the argument names wins,
/// every slot it leaves unknown is kept. Returns a new logger — the
/// wider one is unchanged, which is what lets a driver hand a
/// step-scoped logger to an effect while keeping its own.
///
/// ## Examples
///
/// ```gleam
/// log.scoped(logger, context.anonymous |> context.with_strand("main"))
/// ```
///
pub fn scoped(logger: Logger, context: Context) -> Logger {
  Logger(..logger, context: context.merge(logger.context, context))
}

/// Narrows to a strand.
///
/// ## Examples
///
/// ```gleam
/// log.for_strand(logger, "reviewer")
/// ```
///
pub fn for_strand(logger: Logger, strand: String) -> Logger {
  Logger(..logger, context: context.with_strand(logger.context, strand))
}

/// Narrows to one step of one operation — the scope an effect process
/// is spawned under.
///
/// ## Examples
///
/// ```gleam
/// log.for_step(logger, op: "op-3", step: "step-1")
/// ```
///
pub fn for_step(logger: Logger, op op: String, step step: String) -> Logger {
  let scoped =
    logger.context
    |> context.with_op(op)
    |> context.with_step(step)
  Logger(..logger, context: scoped)
}

/// Stamps this logger's context onto the *calling* process's `logger`
/// metadata. Call it once at the top of a spawned body, in addition to
/// carrying the logger itself: it does nothing for our own lines and
/// everything for the ones we do not author — an OTP crash report from
/// an effect process lands with the same `{session, strand, op, step}`
/// as the effect it belonged to.
///
/// ## Examples
///
/// ```gleam
/// // process.spawn(fn() { log.adopt(logger) ... })
/// ```
///
pub fn adopt(logger: Logger) -> Nil {
  let slots = logger.context
  ffi_logger.stamp(slots.session, slots.strand, slots.op, slots.step)
}

/// The context stamped on the calling process, or `context.anonymous`
/// if none was. Useful to a process that inherited work without also
/// inheriting a logger.
///
/// ## Examples
///
/// ```gleam
/// // log.process_context()
/// ```
///
pub fn process_context() -> Context {
  let #(session, strand, op, step) = ffi_logger.stamped()
  context.Context(session:, strand:, op:, step:)
}

/// Writes a `debug` record: per-step effect dispatch and settlement.
/// Off unless the threshold was lowered.
///
/// ## Examples
///
/// ```gleam
/// log.debug(logger, "effect.dispatched", [field.text("kind", "tool")])
/// ```
///
pub fn debug(logger: Logger, event: String, fields: List(Field)) -> Nil {
  write(logger, level.Debug, event, fields)
}

/// Writes an `info` record: one line per durable state change.
///
/// ## Examples
///
/// ```gleam
/// log.info(logger, "operation.opened", [])
/// ```
///
pub fn info(logger: Logger, event: String, fields: List(Field)) -> Nil {
  write(logger, level.Info, event, fields)
}

/// Writes a `warning` record: degraded, still progressing.
///
/// ## Examples
///
/// ```gleam
/// log.warn(logger, "provider.retry", [field.count("attempt", 2)])
/// ```
///
pub fn warn(logger: Logger, event: String, fields: List(Field)) -> Nil {
  write(logger, level.Warning, event, fields)
}

/// Writes an `error` record: no automatic recovery remains.
///
/// ## Examples
///
/// ```gleam
/// log.error(logger, "commit.faulted", [field.text("reason", reason)])
/// ```
///
pub fn error(logger: Logger, event: String, fields: List(Field)) -> Nil {
  write(logger, level.Error, event, fields)
}

fn write(
  logger: Logger,
  level: Level,
  event: String,
  fields: List(Field),
) -> Nil {
  case level.permits(threshold: logger.threshold, level:) {
    False -> Nil
    True ->
      logger.sink(Record(level:, event:, context: logger.context, fields:))
  }
}

// The one impure sink: render here, in Gleam, and hand the finished
// line across the boundary. Redaction therefore happens in tested pure
// code, and the formatter has nothing left to decide.
fn emit(entry: Record) -> Nil {
  ffi_logger.emit(entry.level, record.render(entry))
}
