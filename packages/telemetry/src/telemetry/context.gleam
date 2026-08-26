//// The correlation context spec §3.4 names: `{session, strand, op,
//// step}` on every line.
////
//// ## Why a value, and not the logger's metadata
////
//// Three ways to carry this were available, and the choice is the whole
//// value of the work — a multi-strand harness with interleaved strands
//// makes an uncorrelated log actively worse than none, because it reads
//// as one coherent story that never happened.
////
//// - **Erlang `logger`'s process metadata.** Per-process, and *not*
////   inherited across `spawn`. Loom's effect sandwich is nothing but
////   spawns: every provider request, every tool run, every parked call
////   happens on a fresh process the strand driver started
////   (`runtime/strand_runtime.spawn_effect`). Metadata alone would
////   therefore lose the context at exactly the boundary where it
////   matters, and lose it silently — the lines still appear, just
////   uncorrelated.
//// - **The process dictionary.** The same non-inheritance, plus it is
////   invisible to the type system, untestable without standing up a
////   real process, and it makes a log call's meaning depend on
////   ambient mutable state — the opposite of §0.2's injection
////   conventions.
//// - **An explicit value.** A `Context` is data. It costs a field on a
////   record the caller already holds, it is pure to construct and
////   compare, and it cannot be lost across a spawn: the closure the
////   driver hands to `spawn` has to capture the logger, and the
////   compiler enforces that capture.
////
//// So the context is an explicit value, carried by the `Logger` that
//// each site already receives by injection. That is the rule.
////
//// The one concession to metadata is additive, not an alternative:
//// `telemetry/log.adopt` stamps the same context into `logger`'s
//// process metadata at the top of a spawned body. That does nothing
//// for our own lines — they already carry it — and everything for the
//// lines we do not author: an OTP crash report or a third-party
//// library logging from an effect process lands correlated instead of
//// orphaned. Metadata is the fallback for foreign output; the value is
//// the mechanism.
////
//// ## What the four slots hold
////
//// All four are optional, because they become known at different
//// depths and a line emitted before one is known must still be
//// emitted. `session` is fixed for the life of a server process;
//// `strand` is fixed for the life of a driver; `op` and `step` change
//// as the driver walks an operation. Strings rather than the `core`
//// id types, so that this package stays a leaf and nothing about a
//// log line can perturb id minting.

import gleam/list
import gleam/option.{type Option, None, Some}
import telemetry/field.{type Field}

/// The `{session, strand, op, step}` correlation context.
///
/// Constructor invariants: every slot is `None` until known, never a
/// placeholder string — `telemetry/record` omits an unknown slot from
/// the rendered line rather than writing null, so a grep for
/// `"op":"op-7"` cannot match a line that never had an operation.
pub type Context {
  Context(
    session: Option(String),
    strand: Option(String),
    op: Option(String),
    step: Option(String),
  )
}

/// The context of a line that knows nothing yet — boot, before a
/// session is open.
pub const anonymous = Context(session: None, strand: None, op: None, step: None)

/// A context knowing only its session.
///
/// ## Examples
///
/// ```gleam
/// context.for_session("01924f7e-3c1a-7abc-8def-0123456789ab")
/// ```
///
pub fn for_session(id: String) -> Context {
  Context(..anonymous, session: Some(id))
}

/// Names the session.
///
/// ## Examples
///
/// ```gleam
/// context.anonymous |> context.with_session("sess-1")
/// ```
///
pub fn with_session(context: Context, id: String) -> Context {
  Context(..context, session: Some(id))
}

/// Names the strand.
///
/// ## Examples
///
/// ```gleam
/// context.for_session("sess-1") |> context.with_strand("main")
/// ```
///
pub fn with_strand(context: Context, strand: String) -> Context {
  Context(..context, strand: Some(strand))
}

/// Names the operation, and clears any step: a step id is only
/// meaningful within the operation that minted it, so carrying one
/// across an operation change would correlate two unrelated lines.
///
/// ## Examples
///
/// ```gleam
/// context.anonymous |> context.with_op("op-7")
/// ```
///
pub fn with_op(context: Context, op: String) -> Context {
  Context(..context, op: Some(op), step: None)
}

/// Names the step within the operation already in the context.
///
/// ## Examples
///
/// ```gleam
/// context.anonymous |> context.with_op("op-7") |> context.with_step("s-2")
/// ```
///
pub fn with_step(context: Context, step: String) -> Context {
  Context(..context, step: Some(step))
}

/// Overlays `over` onto `base`: every slot `over` knows wins, every
/// slot it does not is kept from `base`. This is how a scoped logger
/// narrows without discarding what the wider one established.
///
/// ## Examples
///
/// ```gleam
/// // merge(for_session("s"), anonymous |> with_strand("main"))
/// // -> session "s", strand "main"
/// ```
///
pub fn merge(base: Context, over: Context) -> Context {
  Context(
    session: option.or(over.session, base.session),
    strand: option.or(over.strand, base.strand),
    op: option.or(over.op, base.op),
    step: option.or(over.step, base.step),
  )
}

/// The context as log fields, in the fixed order `session`, `strand`,
/// `op`, `step`, with unknown slots omitted. Identifiers, so the shape
/// rule does not mistake a long session id for a credential.
///
/// ## Examples
///
/// ```gleam
/// // context.fields(for_session("s-1"))
/// // -> [field.Field(key: "session", value: field.Ident("s-1"))]
/// ```
///
pub fn fields(context: Context) -> List(Field) {
  [
    #("session", context.session),
    #("strand", context.strand),
    #("op", context.op),
    #("step", context.step),
  ]
  |> option_fields([])
}

fn option_fields(
  slots: List(#(String, Option(String))),
  acc: List(Field),
) -> List(Field) {
  case slots {
    [] -> list.reverse(acc)
    [#(_, None), ..rest] -> option_fields(rest, acc)
    [#(key, Some(value)), ..rest] ->
      option_fields(rest, [field.ident(key:, value:), ..acc])
  }
}
