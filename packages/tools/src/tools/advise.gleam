//// The `advise` tool: the one call an advisor strand answers a feed
//// with.
////
//// An advisor is a second strand that reads what the primary strand has
//// done and says whether it should carry on. It holds no authority of
//// its own: it cannot steer the primary, cannot queue text into the
//// primary's next run, and cannot write anything durable. Everything it
//// may do leaves through the single `Advice` closure declared here and
//// filled by whoever can see a live runtime — the same arrangement
//// `tools/agent`'s `Agency` and `tools/context`'s `Context` use, and for
//// the same reason: `tools` depends on neither `runtime` nor `client`,
//// so the vocabulary crossing the seam is declared here in plain data
//// and the host supplies the behaviour.
////
//// Two things the model does not get to supply. The first is its own
//// identity: `judge` is handed `Ctx.strand`, which the driver set from
//// its own durable name, so a verdict cannot be attributed to a strand
//// that did not produce it. The second is what a verdict costs. A
//// `Block` asks to interrupt the primary, and whether it actually does
//// is the emission guard's decision on the far side of the seam — a
//// block raised inside the cooldown window is downgraded to a nudge, and
//// advice the primary has already been given is dropped. The `Ack` is
//// that decision reported back, which is why the tool answers with what
//// happened rather than with an acknowledgement that it was asked.
////
//// What a caller may rely on: `run` is total. A malformed verdict and
//// text pair is an in-band error outcome the model can correct inside
//// the same run, a refusal from the seam is an in-band error outcome
//// carrying the host's own words, and every `Ack` is a success outcome
//// naming what the advice actually did.

import broker/policy.{type SandboxPolicy}
import core/json.{type JsonValue}
import gleam/option.{None}
import gleam/result
import tools/tool.{type Ctx, type Tool, type ToolOutcome}

/// The tool name, as a constant because the host registers it by name
/// and a test asserts on registration rather than on a spelling.
pub const name = "advise"

/// What the advisor concluded about the stretch of work it was fed.
///
/// The three points are ordered by what they cost the primary: nothing,
/// a paragraph at its next prompt, an interruption now. A verdict is a
/// request rather than an instruction — see `Ack` for what the harness
/// decided to do with it.
pub type Verdict {
  /// The primary is on track and there is nothing worth saying. Emits
  /// nothing at all.
  Quiet

  /// A nit, a reminder or a small correction that can wait. Folded into
  /// the start of the primary's next run rather than delivered now.
  Nudge(text: String)

  /// A wrong direction, a missed requirement or an unsafe step. Asks to
  /// reach the primary immediately, which steers an open run and starts
  /// one on an idle primary.
  Block(text: String)
}

/// What the harness did with a verdict, as the advisor is told.
///
/// The advisor needs the distinction because it decides what to say
/// next. A downgraded block that read as delivered would leave the
/// advisor believing the primary has already been stopped, and a dropped
/// duplicate that read as delivered would teach it to repeat itself.
pub type Ack {
  /// The block reached the primary. `how` says which way — the harness's
  /// own words, since only it knows whether the primary had a run open.
  Delivered(how: String)

  /// The nudge is held for the start of the primary's next run.
  Queued

  /// The block arrived inside the cooldown window and was queued as a
  /// nudge instead. `reason` says why.
  Downgraded(reason: String)

  /// Nothing was emitted: the advice repeated something the primary has
  /// already been given, or there was no room for it. `reason` says
  /// which.
  Dropped(reason: String)

  /// A `Quiet` verdict was recorded. Nothing was sent, which is the
  /// whole of what `Quiet` asks for.
  Acknowledged
}

/// The advisory seam: the single thing an advisor strand may do.
///
/// Constructor invariants: `judge` is total — it answers a `Result`, it
/// does not crash — and it is judged against the strand name it is
/// handed rather than against anything inside the verdict. The `String`
/// argument is that name, taken from `Ctx.strand`; the `Error` is
/// refusal text written for the model to read.
pub type Advice {
  Advice(judge: fn(String, Verdict) -> Result(Ack, String))
}

/// The `advise` tool over a filled seam.
///
/// `replay: Never`. Both emitting verdicts change state the primary can
/// see — a block is delivered as a fresh framed message, a nudge is held
/// for a run start — and the emission guard counts what it has emitted,
/// so re-executing a call that already landed would say the same thing a
/// second time or burn a cooldown the first call already paid for.
/// Recovery synthesizes the interrupted result instead, and the advisor
/// is fed again at the next run boundary anyway.
///
/// `execution_mode: Exclusive`, the mode `agent_send` takes: the call
/// mutates state shared with the primary, and two verdicts racing for
/// one cooldown window would make which of them was downgraded a matter
/// of scheduling.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry([advise.tool(advice)])
/// ```
///
pub fn tool(advice: Advice) -> Tool {
  tool.Tool(
    name: name,
    description: "Answer the stretch of work you were just shown with "
      <> "exactly one call of this tool. Use `quiet` when the primary agent "
      <> "is on track and nothing needs saying, and send no text with it. "
      <> "Use `nudge` for a nit, a reminder or a small correction that can "
      <> "wait until the primary's next prompt. Use `block` for a wrong "
      <> "direction, a missed requirement or an unsafe step: it interrupts "
      <> "the primary where it stands, so it is worth the interruption or "
      <> "it is a nudge. A block raised while an earlier block is still "
      <> "inside its cooldown is downgraded to a nudge, and advice the "
      <> "primary has already been given is dropped, so say a thing once. "
      <> "The result tells you which of those happened.",
    // No prose index line. The system prompt's available-tools index is
    // one string for the whole session, so a snippet here would tell the
    // primary about a tool it is never offered and about a reviewer it
    // has no business reasoning about. The advisor learns the tool from
    // its own brief, which is prepended to its requests alone.
    prompt_snippet: None,
    schema: tool.object_schema(
      [
        #(
          "verdict",
          tool.enum_property(
            ["quiet", "nudge", "block"],
            "quiet to say nothing, nudge to reach the primary at its next "
              <> "prompt, block to reach it now",
          ),
        ),
        #(
          "text",
          tool.string_property(
            "what to tell the primary; required for nudge and block, and "
            <> "omitted for quiet",
          ),
        ),
      ],
      ["verdict"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, arguments) { run(advice, ctx, arguments) },
  )
}

fn run(advice: Advice, ctx: Ctx, arguments: JsonValue) -> ToolOutcome {
  use verdict <- tool.with_arg(decode_verdict(arguments))

  // The strand name comes from the driver's own durable coordinates, so
  // the far side can judge a verdict without trusting anything the model
  // wrote.
  use ack <- tool.or_outcome(advice.judge(ctx.strand, verdict), tool.failure)
  tool.success(ack_text(ack))
}

/// Decodes the model's arguments into a `Verdict`.
///
/// Total, and exposed rather than private because both sides of the seam
/// have to agree on what the three words mean: the tool decodes with it
/// and the host pins the vocabulary against it.
///
/// The verdict and the text are decoded as one pair rather than as two
/// independent fields, because half the failures are disagreements
/// between them. A `nudge` with nothing to say has no advice in it, and
/// a `quiet` carrying text is a model that decided to say something and
/// then labelled it as saying nothing. Both are errors the model reads
/// and can correct within the same run.
///
/// ## Examples
///
/// ```gleam
/// let arguments = json.Object([#("verdict", json.String("quiet"))])
/// assert advise.decode_verdict(arguments) == Ok(advise.Quiet)
/// ```
///
/// ```gleam
/// let arguments = json.Object([#("verdict", json.String("nudge"))])
/// assert advise.decode_verdict(arguments)
///   == Error("`text` is required when verdict is nudge")
/// ```
///
pub fn decode_verdict(arguments: JsonValue) -> Result(Verdict, String) {
  // Every other JSON shape is named rather than swept into a catch-all,
  // so that a new variant reaches this decision through the compiler.
  use Nil <- result.try(case arguments {
    json.Object(..) -> Ok(Nil)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error("the arguments must be a JSON object")
  })
  use word <- result.try(tool.required_string(arguments, "verdict"))
  use text <- result.try(tool.optional_string(arguments, "text"))
  verdict_of(word, option.unwrap(text, ""))
}

// Absent text and empty text are one case on purpose: a model that sends
// `text: ""` with a nudge has said as little as one that omitted the
// field, and giving the two different answers would only teach it that
// the empty string is a way through.
fn verdict_of(word: String, text: String) -> Result(Verdict, String) {
  case word, text {
    "quiet", "" -> Ok(Quiet)
    "quiet", _said ->
      Error("`text` must be absent or empty when verdict is quiet")

    "nudge", "" -> Error("`text` is required when verdict is nudge")
    "nudge", said -> Ok(Nudge(text: said))

    "block", "" -> Error("`text` is required when verdict is block")
    "block", said -> Ok(Block(text: said))

    // `String` is open-ended, so this arm is a genuine default rather
    // than a flattened shape.
    other, _said ->
      Error(
        "`verdict` must be \"quiet\", \"nudge\" or \"block\", got \""
        <> other
        <> "\"",
      )
  }
}

// One line for the model, naming what the advice did rather than that it
// was accepted. `Delivered` and `Downgraded` carry the host's own words
// because only the host knows whether the primary had a run open and how
// much of the cooldown is left.
fn ack_text(ack: Ack) -> String {
  case ack {
    Delivered(how:) -> "block delivered: " <> how
    Queued -> "nudge queued for the primary's next run start"
    Downgraded(reason:) -> "block downgraded to a nudge: " <> reason
    Dropped(reason:) -> "nothing was emitted: " <> reason
    Acknowledged -> "quiet recorded; nothing was sent"
  }
}

// The advisor reaches no filesystem and starts no process — its whole
// effect is the seam — so it asks the broker for nothing at all and
// composes with any session base.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}
