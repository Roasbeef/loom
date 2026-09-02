//// `ext` — the typed behaviours an extension author writes against.
////
//// An extension is an out-of-tree Gleam package that an operator installs
//// with `loom ext install`. Its tools run in a jailed satellite node under
//// the *extension seam*, so nothing in this package reaches the harness
//// VM and nothing in it performs an effect of its own: every effect an
//// extension has goes out through `cap/*`, judged per call by the broker
//// (`docs/design-notes/extension-architecture.md`, Decision 1).
////
//// This module is therefore vocabulary and nothing else. It exists so the
//// contract between an extension author and the harness is a *type* the
//// compiler checks at install time, rather than a shape agreed in prose
//// and discovered at the first call. `ext/runtime` is the other half: it
//// turns a list of these `Tool`s into a satellite.
////
//// ## Why a refusal is a value
////
//// `Tool` returns `Result(Outcome, Refusal)` rather than signalling an
//// error by crashing. The two are not interchangeable here: a `Refusal`
//// is text the *model* reads and repairs on its next turn, and a crash is
//// a fault the *harness* reports and the model can do nothing with. An
//// extension that means "you passed me a city I do not know" wants the
//// first; only a genuine bug should produce the second, and the satellite
//// runtime turns one of those into an errored outcome anyway.
////
//// ## Why `terminate` is a type and not a `Bool`
////
//// A tool reply may end the run (`core/entry`'s `terminate`). Written as
//// a bare boolean in an `Outcome`, every reader has to carry the polarity
//// of the field's name; written as `ContinueRun | TerminateRun`, the call
//// site says which it means. That is the house rule on naked booleans,
//// and this is a record field where the domain has an obvious name.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import gleam/list
import gleam/result
import gleam/string

/// What a tool is told about the call it is serving.
///
/// `report` streams a partial result to the operator while the tool is
/// still running; it is the extension's view of `cap/report`, narrowed to
/// text because a partial is a progress note rather than an artifact. It
/// is a function value rather than a capability import so that a tool can
/// be exercised in the author's own tests without a channel.
pub type Ctx {
  Ctx(
    /// The strand the call belongs to.
    strand: String,
    /// Wall-clock milliseconds remaining when the call was handed over.
    /// A tool that cannot finish inside it should refuse rather than run
    /// past it: the satellite is killed at the deadline either way, and a
    /// refusal is a reply while a kill is a fault.
    deadline_ms: Int,
    /// Streams a partial result. Best-effort: a partial that could not be
    /// emitted does not fail the call.
    report: fn(String) -> Nil,
  )
}

/// One block of a tool's reply.
pub type Content {
  /// Plain text, rendered to the model as a built-in tool's text is.
  Text(text: String)

  /// Structured JSON. Carried to the harness as its serialization, so a
  /// value that cannot be rendered cannot be returned.
  Json(value: Json)
}

/// Whether the reply ends the run.
///
/// The two variants are the whole domain: this is `terminate` on a tool
/// reply (`core/entry`), which the planner reads to decide whether the
/// operation completes on the tool's word.
pub type Terminate {
  /// The run carries on after this reply. What almost every tool means.
  ContinueRun

  /// The run completes on this reply.
  TerminateRun
}

/// What a tool produced.
pub type Outcome {
  Outcome(
    /// The reply blocks, in order.
    content: List(Content),
    /// Whether the reply ends the run.
    terminate: Terminate,
  )
}

/// Why a tool declined to produce an outcome. The message is shown to the
/// model as an in-band error reply, so it should say what to do
/// differently rather than merely that something went wrong.
pub type Refusal {
  Refusal(message: String)
}

/// A tool: the decoded call arguments and the call's context in, an
/// outcome or a refusal out.
///
/// The arguments arrive as `Dynamic` rather than a typed record because
/// their shape is the manifest's `parameters` JSON schema, which the
/// harness knows and this package does not. `decode_args` is the intended
/// first line of any implementation.
pub type Tool =
  fn(Dynamic, Ctx) -> Result(Outcome, Refusal)

/// An outcome carrying one text block, which is what most tools return.
///
/// ## Examples
///
/// ```gleam
/// assert ext.text("done") == ext.Outcome([ext.Text("done")], ext.ContinueRun)
/// ```
///
pub fn text(body: String) -> Outcome {
  Outcome(content: [Text(text: body)], terminate: ContinueRun)
}

/// An outcome carrying one JSON block.
///
/// ## Examples
///
/// ```gleam
/// let outcome = ext.json(json.object([#("n", json.int(1))]))
/// assert outcome.terminate == ext.ContinueRun
/// ```
///
pub fn json(value: Json) -> Outcome {
  Outcome(content: [Json(value:)], terminate: ContinueRun)
}

/// A refusal carrying `message`.
///
/// ## Examples
///
/// ```gleam
/// assert ext.refuse("no such city") == Error(ext.Refusal("no such city"))
/// ```
///
pub fn refuse(message: String) -> Result(Outcome, Refusal) {
  Error(Refusal(message:))
}

/// Decodes a call's arguments, turning a decode failure into a `Refusal`
/// that names the fields that did not decode.
///
/// Naming the field is the whole point. The model reads the refusal and
/// retries, so "expected String at .city" is a repair instruction while
/// "bad arguments" is a dead end.
///
/// ## Examples
///
/// ```gleam
/// let decoder = {
///   use city <- decode.field("city", decode.string)
///   decode.success(city)
/// }
/// let assert Ok(city) = ext.decode_args(arguments, decoder)
/// ```
///
pub fn decode_args(
  arguments: Dynamic,
  decoder: Decoder(value),
) -> Result(value, Refusal) {
  decode.run(arguments, decoder)
  |> result.map_error(fn(errors) {
    Refusal(message: "the arguments did not decode: " <> describe(errors))
  })
}

// Renders decode errors as a comma-joined list of "expected X at .path"
// clauses. `decode.run` reports every failure it found, and all of them
// are useful to whoever has to fix the call, so none is dropped.
fn describe(errors: List(decode.DecodeError)) -> String {
  case errors {
    [] -> "no reason given"
    [_, ..] -> string.join(list.map(errors, describe_one), ", ")
  }
}

fn describe_one(error: decode.DecodeError) -> String {
  let decode.DecodeError(expected:, found:, path:) = error
  "expected "
  <> expected
  <> " but found "
  <> found
  <> " at ."
  <> string.join(path, ".")
}
