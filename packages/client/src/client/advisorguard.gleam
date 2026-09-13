//// The advisor's emission policy as pure data: what one `advise` verdict
//// becomes, and the small amount of history that decision needs.
////
//// The advisor is a model, and a model asked to review every run of
//// another model will repeat itself and will reach for the loudest
//// channel it has. Two failure modes follow, and both are about the
//// primary rather than about the advisor. A `block` is delivered through
//// `api.send_to_strand`, so an advisor that blocks on consecutive runs
//// steers the primary at every checkpoint and the primary never finishes
//// a thought of its own. And advice the primary was already given costs a
//// second interruption for no new information, because the advisor cannot
//// see that it said the same thing two runs ago: its feed carries the
//// primary's transcript, not its own answers.
////
//// So the bound is enforced here rather than in the advisor's
//// instructions. A prompt asking a model to restrain itself is a request;
//// a cooldown counted in primary runs and a ring of delivered digests is
//// a decision the harness makes and the model is told about afterwards,
//// in the tool result it gets back. That is the same split the broker
//// draws between what a model may ask for and what it is granted.
////
//// ## Why this module holds no process and no cell
////
//// The advisor actor owns the durable cell and the sending; what is here
//// is the decision function and its codec. Two properties rest on that
//// split. The decision is a pure function of a state, a policy and a
//// verdict, so every rule above is asserted by a test with no scheduler
//// in the loop, and the actor applies only the decisions this module
//// returns. And the state outlives the actor: the actor is restartable
//// and its memory is not, so a delivered block that exists only in a
//// process heap is a cooldown that a crash silently lifts.
////
//// ## What a restart is allowed to forget
////
//// `decode` reads an absent field as the empty guard's value for it, so a
//// cell written by an older build decodes to a guard that has forgotten
//// part of its history rather than to an error. That trade is right for
//// this state and for no other: forgetting costs one duplicate block,
//// while refusing would leave the advisor's feed dead for the rest of the
//// session over bookkeeping that nothing depends on. A field that is
//// *present* and mistyped is still an error, because that is a writer
//// disagreeing with this decoder rather than a writer that had not
//// written yet.

import core/json.{type JsonValue}
import gleam/bit_array
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/blob

/// What the advisor asked for on one `advise` call.
pub type Verdict {
  /// The primary is on track and nothing is emitted. The expected common
  /// case, and the only verdict that leaves the guard untouched.
  Quiet

  /// Advice that can wait for the primary's next prompt. It joins the
  /// pending queue and is folded into the next run start; it never wakes
  /// the primary and never starts a run.
  Nudge(text: String)

  /// Advice the advisor believes the primary needs now. Delivery steers a
  /// mid-run primary at its next checkpoint and starts a fresh run on an
  /// idle one, which is why this is the verdict the guard rations.
  Block(text: String)
}

/// The bounds `decide` enforces.
///
/// One record rather than four arguments, because the actor reads these
/// from configuration and a test varies one field against the shipped
/// values rather than restating all four.
pub type Policy {
  Policy(
    /// Primary runs of silence owed after a delivered block. A `Block`
    /// asked for inside that window is queued as a nudge instead.
    block_cooldown_runs: Int,
    /// How many delivered digests are remembered. The ring is what keeps
    /// the duplicate check bounded, and ageing out is deliberate: advice
    /// the primary ignored for this many runs is worth saying again.
    recent_ring: Int,
    /// The most nudges that may wait for the next run start.
    pending_cap: Int,
    /// The most bytes those nudges may total. The count cap alone does
    /// not bound what the next run start folds in, because one nudge can
    /// be a page.
    pending_bytes: Int,
  )
}

/// The shipped bounds: two runs of silence after a block, a ring of
/// thirty-two digests, and at most eight nudges or four kilobytes waiting
/// for the next run start.
pub const default_policy = Policy(
  block_cooldown_runs: 2,
  recent_ring: 32,
  pending_cap: 8,
  pending_bytes: 4096,
)

/// The guard's memory: everything `decide` needs beyond the verdict in
/// front of it.
///
/// Opaque because two of the four fields are invariants rather than data.
/// `last_block_run` indexes the same run count `runs` carries, so a value
/// past `runs` would make the elapsed arithmetic negative and the cooldown
/// would never expire; `pending` is ordered oldest first and is drained
/// whole. Every guard in existence therefore comes from `new`, from
/// `decode` — which re-checks both — or from one of the transitions here.
pub opaque type Guard {
  Guard(
    runs: Int,
    last_block_run: Option(Int),
    recent: List(String),
    pending: List(String),
  )
}

/// What one verdict became. The actor renders this back to the advisor as
/// the `advise` tool result, and acts on it: `Deliver` is the only
/// variant that sends anything to the primary now, and `Queued` and
/// `Downgraded` are already recorded in the guard the call returned.
pub type Decision {
  /// A block that cleared the cooldown. The actor frames this text and
  /// sends it to the primary.
  Deliver(text: String)

  /// A nudge that fit the queue. It is folded into the primary's next run
  /// start, not sent.
  Queued(text: String)

  /// A block asked for inside the cooldown window, queued as a nudge
  /// instead. The reason is model-facing prose saying when the last block
  /// landed and how long the window is, so the advisor learns the rule
  /// from the result rather than from its instructions.
  Downgraded(text: String, reason: String)

  /// Nothing was emitted or queued: the advice repeats something already
  /// delivered, the queue is full, or the text was empty. The reason is
  /// model-facing prose.
  Dropped(reason: String)

  /// `Quiet`. Nothing happened and nothing was recorded.
  Silent
}

// The model-facing reasons that do not vary. They are constants rather
// than inline literals because the actor's tool result and this module's
// tests must not drift apart on the wording the advisor reads.

const duplicate_reason = "the advisor already delivered this advice"

const empty_reason = "empty advice"

const queue_full_reason = "the nudge queue is full; it drains at the primary's next run start"

const decode_where = "client/advisorguard.decode"

// Which channel a piece of advice is being judged for. A two-variant type
// rather than a flag, so `judge` names the question at every call site.
type Kind {
  AsNudge
  AsBlock
}

/// A guard that has seen nothing: no runs, no delivered block, an empty
/// ring and an empty queue. What a session with no stored cell starts
/// from.
///
/// ## Examples
///
/// ```gleam
/// assert advisorguard.runs(advisorguard.new()) == 0
/// ```
///
/// ```gleam
/// assert advisorguard.pending(advisorguard.new()) == []
/// ```
///
pub fn new() -> Guard {
  Guard(runs: 0, last_block_run: None, recent: [], pending: [])
}

/// How many primary runs this guard has seen. The clock the cooldown is
/// measured on, exposed because the actor writes it into its own
/// diagnostics and the tests assert on it.
///
/// ## Examples
///
/// ```gleam
/// assert advisorguard.runs(advisorguard.primary_run_ended(advisorguard.new()))
///   == 1
/// ```
///
pub fn runs(guard: Guard) -> Int {
  guard.runs
}

/// The nudges waiting for the primary's next run start, oldest first.
/// Reading them does not drain them; `take_pending` does.
///
/// ## Examples
///
/// ```gleam
/// assert advisorguard.pending(advisorguard.new()) == []
/// ```
///
pub fn pending(guard: Guard) -> List(String) {
  guard.pending
}

/// Advances the run clock by one.
///
/// Called from the primary's run-end hook, which is the only event that
/// moves the cooldown along. The advisor's own runs do not count: the
/// window exists to give the primary room between interruptions, and
/// measuring it in advisor turns would let a chatty advisor shorten its
/// own cooldown.
///
/// ## Examples
///
/// ```gleam
/// assert advisorguard.runs(advisorguard.primary_run_ended(advisorguard.new()))
///   == 1
/// ```
///
pub fn primary_run_ended(guard: Guard) -> Guard {
  Guard(..guard, runs: guard.runs + 1)
}

/// Decides what one verdict becomes and returns the guard that recorded
/// it.
///
/// The returned guard is the only one the caller may keep: a `Deliver`
/// starts the cooldown, and a `Queued` or `Downgraded` has already joined
/// the pending queue, so discarding it would deliver the advice twice.
///
/// ## Examples
///
/// ```gleam
/// let #(decision, _guard) =
///   advisorguard.decide(
///     advisorguard.new(),
///     advisorguard.default_policy,
///     advisorguard.Quiet,
///   )
/// assert decision == advisorguard.Silent
/// ```
///
/// ```gleam
/// let #(decision, _guard) =
///   advisorguard.decide(
///     advisorguard.new(),
///     advisorguard.default_policy,
///     advisorguard.Block(text: "the migration has no down step"),
///   )
/// assert decision
///   == advisorguard.Deliver(text: "the migration has no down step")
/// ```
///
pub fn decide(
  guard: Guard,
  policy: Policy,
  verdict: Verdict,
) -> #(Decision, Guard) {
  case verdict {
    // The one verdict that records nothing. A reviewed slice the advisor
    // had no comment on must not age the ring or move the cooldown, or a
    // quiet advisor would slowly erase its own history.
    Quiet -> #(Silent, guard)

    Nudge(text:) -> judge(guard, policy, text, AsNudge)

    Block(text:) -> judge(guard, policy, text, AsBlock)
  }
}

/// Drains the pending nudges, returning them oldest first.
///
/// Called from the primary's run-start hook, which folds them into one
/// fenced message. Draining does not clear the ring: advice that was
/// queued was also remembered, and repeating it after it has been read is
/// the duplicate the ring exists to stop.
///
/// ## Examples
///
/// ```gleam
/// assert advisorguard.take_pending(advisorguard.new())
///   == #([], advisorguard.new())
/// ```
///
pub fn take_pending(guard: Guard) -> #(List(String), Guard) {
  #(guard.pending, Guard(..guard, pending: []))
}

// --- the decision ---------------------------------------------------------

// Everything both emitting verdicts are held to, in the order the design
// states it: empty text, then the duplicate ring, then the channel's own
// rule.
fn judge(
  guard: Guard,
  policy: Policy,
  text: String,
  kind: Kind,
) -> #(Decision, Guard) {
  let normalized = normalize(text)

  // Emptiness is checked before the ring, and the order is not
  // observable: empty advice is never queued and never delivered, so its
  // digest cannot have reached `recent` for the ring to match on.
  use <- bool.lazy_guard(when: normalized == "", return: fn() {
    #(Dropped(reason: empty_reason), guard)
  })

  let fingerprint = digest(normalized)

  // One ring for both channels. An advisor that repeats a delivered block
  // as a nudge is saying the same thing in a quieter voice, and the
  // primary has already read it once.
  use <- bool.lazy_guard(
    when: list.contains(guard.recent, fingerprint),
    return: fn() { #(Dropped(reason: duplicate_reason), guard) },
  )

  case kind {
    AsNudge -> enqueue(guard, policy, text, fingerprint, Queued)

    AsBlock -> judge_block(guard, policy, text, fingerprint)
  }
}

// The cooldown, which is the whole of the block channel's rule.
fn judge_block(
  guard: Guard,
  policy: Policy,
  text: String,
  fingerprint: String,
) -> #(Decision, Guard) {
  case cooldown_elapsed(guard, policy) {
    // Outside the window. The delivery is recorded against the current
    // run before the actor sends, so a crash between here and the send
    // costs a lost block rather than an unbounded one: the cell already
    // says a block landed.
    None -> #(
      Deliver(text:),
      Guard(
        ..guard,
        last_block_run: Some(guard.runs),
        recent: remember(guard.recent, fingerprint, policy),
      ),
    )

    // Inside it. The block becomes a nudge rather than nothing, because
    // the advisor's judgement that something is wrong is worth keeping
    // even when its judgement about urgency is overridden.
    Some(elapsed) ->
      enqueue(guard, policy, text, fingerprint, fn(queued) {
        Downgraded(text: queued, reason: downgrade_reason(elapsed, policy))
      })
  }
}

// The pending queue's two caps, and the one place advice joins it.
//
// `accepted` builds the decision for the accepted case, which is what
// lets a nudge and a downgraded block share this path: they differ only
// in what the advisor is told, never in what happens to the text.
fn enqueue(
  guard: Guard,
  policy: Policy,
  text: String,
  fingerprint: String,
  accepted: fn(String) -> Decision,
) -> #(Decision, Guard) {
  case fits(guard.pending, text, policy) {
    False -> #(Dropped(reason: queue_full_reason), guard)

    // The text is queued exactly as the advisor wrote it. Normalization
    // decides identity only; folding the lowercased, whitespace-collapsed
    // form into the primary's prompt would hand it mangled prose.
    True -> #(
      accepted(text),
      Guard(
        ..guard,
        pending: list.append(guard.pending, [text]),
        recent: remember(guard.recent, fingerprint, policy),
      ),
    )
  }
}

// How many primary runs have passed since the last delivered block, when
// that is still inside the window. `None` means the block channel is
// open, either because nothing has been delivered or because the window
// has expired.
fn cooldown_elapsed(guard: Guard, policy: Policy) -> Option(Int) {
  case guard.last_block_run {
    None -> None

    Some(run) -> {
      let elapsed = guard.runs - run
      case elapsed < policy.block_cooldown_runs {
        True -> Some(elapsed)
        False -> None
      }
    }
  }
}

// Whether one more nudge fits under both caps.
fn fits(queue: List(String), addition: String, policy: Policy) -> Bool {
  has_room(queue, policy.pending_cap)
  && total_bytes(queue) + string.byte_size(addition) <= policy.pending_bytes
}

// The count cap, asked with `list.drop` rather than with a count: the
// question is settled after `cap` elements and `list.length` would walk
// the whole queue to answer it (lint R5). A cap of zero or less is
// answered without touching the queue at all, which is what keeps a
// misconfigured cap from admitting a first nudge.
fn has_room(queue: List(String), cap: Int) -> Bool {
  cap > 0 && list.drop(queue, cap - 1) == []
}

// Bytes rather than characters, because the cap exists to bound what the
// next run start folds into a prompt and a prompt is charged in bytes.
fn total_bytes(queue: List(String)) -> Int {
  list.fold(queue, 0, fn(sum, text) { sum + string.byte_size(text) })
}

// Newest first, trimmed to the ring. `list.take` is the trim rather than
// a length check for R5's reason, and it also gives the degenerate ring
// of zero the right answer: nothing is remembered and every repeat is
// sayable again.
fn remember(
  recent: List(String),
  fingerprint: String,
  policy: Policy,
) -> List(String) {
  list.take([fingerprint, ..recent], policy.recent_ring)
}

// --- the reasons the advisor reads ----------------------------------------

fn downgrade_reason(elapsed: Int, policy: Policy) -> String {
  ago_phrase(elapsed)
  <> " and the cooldown is "
  <> runs_phrase(policy.block_cooldown_runs)
  <> "; this advice was queued as a nudge for the primary's next run start"
}

fn ago_phrase(elapsed: Int) -> String {
  case elapsed {
    0 -> "a block was already delivered during this run"
    _ -> "a block was delivered " <> runs_phrase(elapsed) <> " ago"
  }
}

fn runs_phrase(count: Int) -> String {
  case count {
    1 -> "1 run"
    _ -> int.to_string(count) <> " runs"
  }
}

// --- identity -------------------------------------------------------------

// The form two pieces of advice are compared in: lowercased, with every
// run of whitespace collapsed to one space and the ends trimmed. A model
// asked twice about the same concern rarely produces the same bytes, and
// case and wrapping are exactly the differences that carry no meaning.
fn normalize(text: String) -> String {
  text
  |> string.lowercase
  |> string.to_graphemes
  |> list.map(space_or_self)
  |> string.concat
  |> string.split(on: " ")
  |> list.filter(fn(word) { word != "" })
  |> string.join(with: " ")
}

// Whitespace is decided on the codepoint rather than on a list of escape
// literals, so tabs, newlines, form feeds and the C0 controls a pasted
// transcript can carry all collapse the same way.
fn space_or_self(grapheme: String) -> String {
  case string.to_utf_codepoints(grapheme) {
    [codepoint] ->
      case string.utf_codepoint_to_int(codepoint) <= 0x20 {
        True -> " "
        False -> grapheme
      }

    // A cluster of several codepoints is a letter carrying marks or an
    // emoji sequence. Neither is whitespace, and neither may be split.
    _ -> grapheme
  }
}

// The `sha256-` label comes off and 128 bits are kept, exactly as
// `escalate.action_digest` does it: the tree has one SHA-256, the label
// is a constant prefix that would make every truncation alike, and a
// session's advice set cannot collide in 128 bits.
fn digest(normalized: String) -> String {
  let reference = blob.ref_for(bit_array.from_string(normalized))
  string.slice(reference, at_index: 7, length: 32)
}

// --- the cell -------------------------------------------------------------

/// Encodes the guard as its stored fact payload.
///
/// ## Examples
///
/// ```gleam
/// // advisorguard.decode(advisorguard.encode(guard)) == Ok(guard)
/// ```
///
pub fn encode(guard: Guard) -> JsonValue {
  json.Object([
    #("runs", json.Int(guard.runs)),
    #("lastBlockRun", encode_run(guard.last_block_run)),
    #("recent", json.Array(list.map(guard.recent, json.String))),
    #("pending", json.Array(list.map(guard.pending, json.String))),
  ])
}

// A field that is always present and sometimes null rather than a field
// that is sometimes absent. Absence already means "an older writer left
// this out" in this codec, so a guard that has genuinely delivered no
// block must say so in a way that cannot be confused with that.
fn encode_run(run: Option(Int)) -> JsonValue {
  case run {
    None -> json.Null
    Some(value) -> json.Int(value)
  }
}

/// Decodes a stored guard. Total: every malformed payload is an `Error`
/// naming the field that broke, never a crash and never a half-read
/// guard.
///
/// An absent cell — `Null` — and an empty object both decode to `new()`,
/// as does any object whose fields are all absent, because an absent
/// field takes the empty guard's value for it. See the module doc for why
/// this decoder is lenient about absence and strict about type.
///
/// ## Examples
///
/// ```gleam
/// assert advisorguard.decode(json.Null) == Ok(advisorguard.new())
/// ```
///
/// ```gleam
/// // advisorguard.decode(json.String("x")) -> Error("client/advisorguard.decode: …")
/// ```
///
pub fn decode(value: JsonValue) -> Result(Guard, String) {
  use fields <- result.try(object_fields(value))
  use stored_runs <- result.try(optional_int(fields, "runs"))
  use stored_block <- result.try(optional_run(fields, "lastBlockRun"))
  use recent <- result.try(optional_strings(fields, "recent"))
  use queued <- result.try(optional_strings(fields, "pending"))
  use counted <- result.try(non_negative(stored_runs, "runs"))
  use last_block_run <- result.try(check_last_block(stored_block, counted))
  Ok(Guard(runs: counted, last_block_run:, recent:, pending: queued))
}

// `Null` is the shape a fact cell that was never written comes back as,
// so the actor hands whatever it read straight here instead of branching
// on absence before the call. Every other non-object is a writer that
// stored something else under this key.
fn object_fields(
  value: JsonValue,
) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields:) -> Ok(fields)

    json.Null -> Ok([])

    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..) ->
      Error(
        decode_where
        <> ": the payload must be an object, got "
        <> json.to_string(value),
      )
  }
}

fn optional_int(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Int, String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(0)
    Ok(json.Int(value:)) -> Ok(value)
    Ok(other) -> Error(field_error(key, "an integer", other))
  }
}

fn optional_run(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(Option(Int), String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok(None)
    Ok(json.Null) -> Ok(None)
    Ok(json.Int(value:)) -> Ok(Some(value))
    Ok(other) -> Error(field_error(key, "an integer or null", other))
  }
}

fn optional_strings(
  fields: List(#(String, JsonValue)),
  key: String,
) -> Result(List(String), String) {
  case list.key_find(fields, key) {
    Error(Nil) -> Ok([])
    Ok(json.Array(items:)) -> list.try_map(items, string_item(_, key))
    Ok(other) -> Error(field_error(key, "an array of strings", other))
  }
}

fn string_item(item: JsonValue, key: String) -> Result(String, String) {
  case item {
    json.String(value:) -> Ok(value)

    json.Object(..)
    | json.Array(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> Error(field_error(key, "an array of strings", item))
  }
}

fn non_negative(value: Int, key: String) -> Result(Int, String) {
  case value >= 0 {
    True -> Ok(value)
    False ->
      Error(
        decode_where
        <> ": "
        <> key
        <> " must not be negative, got "
        <> int.to_string(value),
      )
  }
}

// The one cross-field check, and the reason the type is opaque. A block
// recorded against a run the guard has not reached makes `runs - value`
// negative, and a negative elapsed is always below the cooldown, so the
// block channel would stay shut for the rest of the session. Refusing the
// cell costs one forgotten cooldown; accepting it costs the feature.
fn check_last_block(
  run: Option(Int),
  counted: Int,
) -> Result(Option(Int), String) {
  case run {
    None -> Ok(None)

    Some(value) if value < 0 ->
      Error(
        decode_where
        <> ": lastBlockRun must not be negative, got "
        <> int.to_string(value),
      )

    Some(value) if value > counted ->
      Error(
        decode_where
        <> ": lastBlockRun "
        <> int.to_string(value)
        <> " is past the run count "
        <> int.to_string(counted),
      )

    Some(value) -> Ok(Some(value))
  }
}

fn field_error(key: String, expected: String, got: JsonValue) -> String {
  decode_where
  <> ": "
  <> key
  <> " must be "
  <> expected
  <> ", got "
  <> json.to_string(got)
}
