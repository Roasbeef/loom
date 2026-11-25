//// The pure half of routing a trigger with Jev: the request to build, the
//// answers to decode, and the rule that turns the answers into a decision.
////
//// The model router is a session that reads a candidate and calls `route`.
//// This module is the other candidate for that job. Jev answers typed
//// questions about one message with probabilities and writes no text, so
//// everything it can say is a probability over labels this module supplied.
//// The module performs no I/O, reads no clock and holds no key. The daemon
//// sends the request and hands the response back, which lets every rule here
//// run under a property test with no process.
////
//// ## Why six questions and no catch-all option
////
//// Jev's Choice always returns its closest option, so an `other`, `unclear`,
//// `new` or `default` option competes for probability with the real ones.
//// The documented remedy is a companion Noul in the same request. A message
//// is therefore judged by three Nouls (does it ask for work, is it clear
//// alone, does it continue a listed ticket) and by Choices that are read only
//// when the matching Noul allows it: which ticket, which decline reason,
//// which agent. Each action then has its own bar, and a middle band falls
//// back to the model router.
////
//// ## What authority this module has
////
//// None. A decision names a ticket the request listed, or says new work, or
//// declines, or falls back. It cannot be a stop, and it cannot decline an
//// explicit trigger, because the request for one has no question to decline
//// with. Whatever it says still passes through `route.route`, which checks
//// the gate's stored strength. A `Shape` can be built only from the engine's
//// state and the trigger's strength, so the tickets it lists are always ones
//// the engine would accept for that strength, and the which-ticket Choice
//// answers with the ticket itself, so a decision cannot be paired with a
//// different list than the request carried.
////
//// ## Flow
////
//// `shape` → `request` → the daemon sends it → `accept` → `decide`
////
//// 1. `shape` lists the tickets the request may offer for a strength.
//// 2. `request` builds the questions and the object Jev reads as its state.
//// 3. `accept` checks the model name the response reports and returns the
////    answers as integer basis points.
//// 4. `decide` combines the answers under fixed bars and one configured bar.
//// 5. `still_offered` names the candidates the engine still holds as offered,
////    which are the ones the model router receives.
////
//// All probabilities here are integer basis points, rounded from the
//// service's floats, and every bar is compared after that rounding, which is
//// also what the ledger keeps. A value of 0.49995 therefore passes a bar of
//// 0.50, and one of 0.30004 counts as at most 0.30.
////
//// The design is in docs/design-notes/project-jev-routing.md.

import gleam/dict
import gleam/float
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import jevelin
import jevelin/batch.{type Batch}
import jevelin/content.{type Content}
import jevelin/probability
import jevelin/question
import project/model.{
  type Inputs, type Strength, type TicketId, type TriggerId, Explicit, Inferred,
}
import project/stage
import project/state.{type State}

// --- vocabulary --------------------------------------------------------------

/// The most tickets a request lists.
pub const max_listed = 40

/// The most code points of a message that a request carries.
pub const max_message_codepoints = 4096

/// The most characters of a model name that a response may report.
pub const max_model_characters = 64

/// A ticket the request offers, as the host built it from the state.
pub type Listed {
  Listed(
    /// The ticket.
    ticket: TicketId,
    /// The ticket's stage word, as the board shows it.
    stage: String,
    /// Whether the ticket is still open. An open ticket takes an attach and an
    /// ended one a resume.
    standing: Standing,
    /// The ticket's title, present only when its mandate is explicit. A title
    /// derived from an inferred trigger is a stranger's text, and a request
    /// about one stranger never carries another's.
    title: Option(String),
  )
}

/// Whether a listed ticket is still open.
pub type Standing {
  /// The ticket has no outcome, so it takes an attach.
  OpenTicket

  /// The ticket ended, so a message about it resumes it.
  EndedTicket
}

/// What a request asked, and so what its answers can mean. It is built only by
/// `shape`, from the engine's state and a strength, so a trigger of one
/// strength never carries the list built for the other.
pub opaque type Shape {
  Shape(
    /// The trigger's strength, fixed by the gate when it arrived.
    strength: Strength,
    /// The tickets offered, newest opened first.
    tickets: List(Listed),
    /// What each catalogue agent is for, in the operator's words and in the
    /// order the labels number them.
    agents: List(String),
  )
}

/// Where a message came from, in the gate's own vocabulary. It is rendered to a
/// fixed phrase, so the sender's login cannot reach a request.
pub type Source {
  /// The owner typed it in the composer.
  FromOwner

  /// A listed person addressed the agent.
  FromPersonAddressing

  /// A listed person spoke without addressing the agent.
  FromPersonNotAddressing

  /// A listed bot.
  FromBot

  /// A report of a failed check.
  FromCiFailure

  /// Anyone not listed.
  FromStranger
}

/// The text of one request.
pub type Message {
  Message(
    /// The trigger's text. A request carries at most
    /// `max_message_codepoints` of it.
    text: String,
    /// Where the message came from.
    source: Source,
  )
}

/// A Choice answer in basis points. `a` is the type of the options: a ticket,
/// a decline reason or an agent's index.
pub type Ranked(a) {
  Ranked(
    /// The option Jev selected.
    selected: a,
    /// Jev's confidence in the selection.
    confidence: Int,
    /// The probability of every option, in request order.
    shares: List(#(a, Int)),
  )
}

/// What a response said, in basis points (0 to 10000). A field is `None` when
/// its question was not asked.
pub type Answers {
  Answers(
    /// Whether the message asks for work.
    asks_for_work: Option(Int),
    /// Whether the message can be acted on without its thread.
    clear_alone: Int,
    /// Whether the message continues a listed ticket.
    continues: Option(Int),
    /// Which listed ticket it continues.
    which_ticket: Option(Ranked(TicketId)),
    /// Why it asks for no work.
    decline_reason: Option(Ranked(DeclineReason)),
    /// Which catalogue agent fits new work, by its index in the catalogue.
    agent: Option(Ranked(Int)),
  )
}

/// Why a message that asks for no work is declined.
pub type DeclineReason {
  /// The message is not about this project.
  OffTopic

  /// The message needs nothing done, such as an acknowledgement.
  NothingToDo
}

/// Why a trigger is left to the model router, in the words the ledger keeps.
pub type Why {
  /// The message cannot be acted on without reading its thread.
  LowClarity

  /// The answers fall between the bars, or contradict one another.
  LowProbability

  /// The service did not answer in time or at all.
  Unavailable

  /// The response was not a valid answer to this request.
  Invalid

  /// No key was available to ask with.
  NoKey

  /// The engine refused the decision, which changed nothing.
  Refused
}

/// What the answers come to.
pub type Decision {
  /// Attach the trigger to an open listed ticket.
  Attach(ticket: TicketId)

  /// Reopen an ended listed ticket with the trigger.
  Resume(ticket: TicketId)

  /// Open a ticket. `agent` is the index of the catalogue agent that takes it,
  /// or `None` for the `[roles]` default.
  New(agent: Option(Int))

  /// Drop an inferred trigger that asks for no work.
  Decline(reason: DeclineReason)

  /// Leave the trigger to the model router.
  Fallback(why: Why)
}

/// The one bar an operator sets: how sure Jev must be to attach a message to an
/// existing ticket. The other bars are fixed here and belong to the
/// request-shape version that the pin carries. It can be built only from a
/// percent above one half, since a lower bar would let a ticket with less than
/// even odds take the message.
pub opaque type Bars {
  Bars(
    /// The least probability for attaching to a listed ticket, in basis
    /// points.
    attach: Int,
  )
}

/// The bar for a percent from 51 to 100, and nothing for any other value.
///
/// ## Examples
///
/// ```gleam
/// assert jev.bars(80) |> result.map(jev.attach_points) == Ok(8000)
/// assert jev.bars(50) == Error(Nil)
/// ```
pub fn bars(percent: Int) -> Result(Bars, Nil) {
  case percent >= 51 && percent <= 100 {
    True -> Ok(Bars(attach: percent * 100))
    False -> Error(Nil)
  }
}

/// The attach bar in basis points.
///
/// ## Examples
///
/// ```gleam
/// assert jev.attach_points(jev.default_bars()) == 8000
/// ```
pub fn attach_points(bars: Bars) -> Int {
  bars.attach
}

/// The bar the configuration gives when it names none.
///
/// ## Examples
///
/// ```gleam
/// assert jev.attach_points(jev.default_bars()) == 8000
/// ```
pub fn default_bars() -> Bars {
  Bars(attach: 8000)
}

// --- the fixed bars ----------------------------------------------------------

/// A message less clear than this is left to the model router.
const clear_least = 5000

/// A message that asks for work with at most this probability asks for none.
const asks_at_most = 3000

/// New work and an inferred attach need the message to ask for work with at
/// least this probability.
const asks_at_least = 7000

/// A message that continues a ticket with at most this probability is new
/// work.
const continues_at_most = 3000

/// The agent Choice's confidence needed to use its selection.
const agent_confidence_least = 5000

/// The version of the request's wording and of the bars above. It is part of
/// the pin, so changing a question, a bar or the listing rule raises it.
pub const request_shape_version = 1

// --- the shape ---------------------------------------------------------------

/// What a request about a trigger of `strength` asks, given the engine's state
/// and the agent catalogue.
///
/// The tickets are those whose mandate stands (no person's stop), newest
/// opened first, at most `max_listed`. For an inferred trigger a ticket with an
/// explicit mandate is left out, which is the test `intake.takes` applies, so
/// Jev cannot pick a ticket the engine would refuse.
///
/// ## Examples
///
/// ```gleam
/// assert jev.tickets(jev.shape(state.start(config), Inferred, [])) == []
/// ```
pub fn shape(
  current: State,
  strength: Strength,
  agents: List(String),
) -> Shape {
  Shape(strength:, tickets: listing(current, strength), agents:)
}

/// The tickets a shape offers.
///
/// ## Examples
///
/// ```gleam
/// assert jev.tickets(jev.shape(state.start(config), Explicit, [])) == []
/// ```
pub fn tickets(shape: Shape) -> List(Listed) {
  shape.tickets
}

/// The strength a shape was built for.
///
/// ## Examples
///
/// ```gleam
/// assert jev.strength(jev.shape(state.start(config), Explicit, []))
///   == Explicit
/// ```
pub fn strength(shape: Shape) -> Strength {
  shape.strength
}

/// What each catalogue agent of a shape is for.
///
/// ## Examples
///
/// ```gleam
/// assert jev.agents(jev.shape(state.start(config), Explicit, ["a"])) == ["a"]
/// ```
pub fn agents(shape: Shape) -> List(String) {
  shape.agents
}

/// A shape whose tickets are rotated `by` places. The verdict's three trials
/// are three rotations of the ticket order, because Jev leans toward the first
/// option of a Choice.
///
/// ## Examples
///
/// ```gleam
/// // jev.rotate(shape, 1) lists the same tickets from the second
/// ```
pub fn rotate(shape: Shape, by: Int) -> Shape {
  Shape(..shape, tickets: rotated(shape.tickets, by))
}

/// The tickets a request about a trigger of `strength` may list.
fn listing(current: State, strength: Strength) -> List(Listed) {
  // The state keeps its tickets newest opened first.
  current.order
  |> list.filter_map(fn(id) { dict.get(current.tickets, id) })
  |> list.filter(fn(ticket) { offerable(ticket, strength) })
  |> list.take(max_listed)
  |> list.map(listed)
}

/// Whether a ticket may be offered for a trigger of this strength.
fn offerable(ticket: state.Ticket, strength: Strength) -> Bool {
  case ticket.authority, strength, ticket.mandate.strength {
    state.Withdrawn(_), _, _ -> False
    state.Granted, Inferred, Explicit -> False
    state.Granted, Inferred, Inferred -> True
    state.Granted, Explicit, Explicit -> True
    state.Granted, Explicit, Inferred -> True
  }
}

/// A ticket as the request describes it.
fn listed(ticket: state.Ticket) -> Listed {
  Listed(
    ticket: ticket.id,
    stage: stage.to_string(state.stage_of(ticket)),
    standing: case ticket.outcome {
      None -> OpenTicket
      Some(_) -> EndedTicket
    },
    title: case ticket.mandate.strength {
      Explicit -> Some(model.title_text(ticket.title))
      Inferred -> None
    },
  )
}

/// Rotate a list so that it starts `by` places later, wrapping around.
///
/// ## Examples
///
/// ```gleam
/// assert jev.rotated([1, 2, 3], 1) == [2, 3, 1]
/// ```
pub fn rotated(items: List(a), by: Int) -> List(a) {
  // An empty list has no position to shift to.
  case list.length(items) {
    0 -> items
    count -> {
      let shift = int.modulo(by, count) |> result.unwrap(0)
      let #(front, back) = list.split(items, shift)
      list.append(back, front)
    }
  }
}

/// Where a message came from, from the gate's inputs.
///
/// ## Examples
///
/// ```gleam
/// // jev.source_of(inputs) == jev.FromOwner for an owner's post
/// ```
pub fn source_of(inputs: Inputs) -> Source {
  case inputs.sender, inputs.addressing {
    model.Owner, _ -> FromOwner
    model.Person, model.Addressed -> FromPersonAddressing
    model.Person, model.Unaddressed -> FromPersonNotAddressing
    model.ListedBot, _ -> FromBot
    model.CiFailure, _ -> FromCiFailure
    model.Unlisted, _ -> FromStranger
  }
}

/// The fixed phrase a source is rendered to.
fn source_phrase(source: Source) -> String {
  case source {
    FromOwner -> "a post by the project's owner"
    FromPersonAddressing ->
      "a comment by a listed person, addressed to the agent"
    FromPersonNotAddressing ->
      "a comment by a listed person, not addressed to the agent"
    FromBot -> "a comment by a listed bot"
    FromCiFailure -> "a report of a failed check"
    FromStranger -> "a comment by someone not listed"
  }
}

// --- building the request ----------------------------------------------------

/// Why a request could not be built. Both cases are a bug of ours, never a
/// property of the message.
pub type RequestError {
  /// jevelin refused the model name or the batch.
  Evaluate(error: jevelin.BuildError)

  /// A question had no valid alternatives.
  Ask(error: question.BuildError)
}

/// One answer, before the batch is folded into `Answers`.
type Answer {
  Asks(Int)
  Clear(Int)
  Continues(Int)
  Which(Ranked(TicketId))
  Reason(Ranked(DeclineReason))
  Agent(Ranked(Int))
}

/// Build the one request for a message.
///
/// Which questions are asked follows the shape: an inferred trigger is asked
/// whether it asks for work and why not, and an explicit one is not, so there
/// is nothing to decline with. The which-ticket question needs two or more
/// tickets, since one gives no information, and the agent question needs two
/// or more agents for the same reason.
///
/// ## Examples
///
/// ```gleam
/// // jev.request(shape, message, "jev-1.14.0") -> Ok(request)
/// ```
pub fn request(
  shape: Shape,
  message: Message,
  model_name: String,
) -> Result(jevelin.Request(jevelin.Evaluation(Answers)), RequestError) {
  use choices <- result.try(choice_batches(shape))
  let asked =
    batch.all(list.append(noul_batches(shape), choices))
    |> batch.map(fold_answers)
  jevelin.evaluate_with_model(state_of(shape, message), model_name, asked)
  |> result.map_error(Evaluate)
}

/// Gather the answers of one response into a record.
fn fold_answers(answers: List(Answer)) -> Answers {
  let empty =
    Answers(
      asks_for_work: None,
      clear_alone: 0,
      continues: None,
      which_ticket: None,
      decline_reason: None,
      agent: None,
    )
  list.fold(answers, empty, fn(sofar, answer) {
    case answer {
      Asks(value) -> Answers(..sofar, asks_for_work: Some(value))
      Clear(value) -> Answers(..sofar, clear_alone: value)
      Continues(value) -> Answers(..sofar, continues: Some(value))
      Which(value) -> Answers(..sofar, which_ticket: Some(value))
      Reason(value) -> Answers(..sofar, decline_reason: Some(value))
      Agent(value) -> Answers(..sofar, agent: Some(value))
    }
  })
}

/// The Nouls this shape asks.
fn noul_batches(shape: Shape) -> List(Batch(Answer)) {
  // Only an inferred trigger is asked whether it asks for work.
  let asks = case shape.strength {
    Inferred -> [asks_question()]
    Explicit -> []
  }

  // The Noul about tickets needs tickets to be listed.
  let continues = case shape.tickets {
    [] -> []
    [_, ..] -> [continues_question()]
  }

  list.flatten([asks, [clear_question()], continues])
}

/// The Choices this shape asks.
fn choice_batches(shape: Shape) -> Result(List(Batch(Answer)), RequestError) {
  // One ticket gives the Choice nothing to choose between, so it is not
  // asked, and that ticket is the target.
  use which <- result.try(case shape.tickets {
    [_, _, ..] -> which_question(shape.tickets) |> result.map(fn(b) { [b] })
    _ -> Ok([])
  })

  // Only an inferred trigger can be declined, so only it is asked why not.
  use reason <- result.try(case shape.strength {
    Inferred -> reason_question() |> result.map(fn(b) { [b] })
    Explicit -> Ok([])
  })

  // One agent is used without a question, for the same reason.
  use agent <- result.map(case shape.agents {
    [_, _, ..] -> agent_question(shape.agents) |> result.map(fn(b) { [b] })
    _ -> Ok([])
  })

  list.flatten([which, reason, agent])
}

/// The state object. A question sees only these fields.
fn state_of(shape: Shape, message: Message) -> Content {
  let base = [
    #("message", json.string(cap_message(message.text))),
    #("source", json.string(source_phrase(message.source))),
  ]

  // The Noul about tickets sees only the state, so the tickets are in it.
  let tickets = case shape.tickets {
    [] -> []
    listed -> [#("tickets", tickets_json(listed))]
  }

  content.Object(list.append(base, tickets))
}

/// The listed tickets as one object keyed by label.
fn tickets_json(listed: List(Listed)) -> Json {
  json.object(
    list.index_map(listed, fn(entry, index) {
      #(ticket_label(index), json.object(description_fields(entry)))
    }),
  )
}

/// The one template of a ticket's description: its stage, and its title when it
/// has one to show. A ticket whose title is a stranger's has the stage word
/// alone. The state object and the which-ticket options both use it, so the two
/// cannot drift, and the template is part of the pin.
fn description_fields(entry: Listed) -> List(#(String, Json)) {
  // A title is present only when the ticket has one to show.
  let title = case entry.title {
    Some(text) -> [#("title", json.string(text))]
    None -> []
  }

  [#("stage", json.string(entry.stage)), ..title]
}

/// The first `max_message_codepoints` code points of a message.
///
/// ## Examples
///
/// ```gleam
/// assert jev.cap_message("abc") == "abc"
/// assert string.length(jev.cap_message(string.repeat("x", 5000))) == 4096
/// ```
pub fn cap_message(text: String) -> String {
  text
  |> string.to_utf_codepoints
  |> list.take(max_message_codepoints)
  |> string.from_utf_codepoints
}

/// The label of the ticket at an index.
fn ticket_label(index: Int) -> String {
  "ticket_" <> int.to_string(index + 1)
}

/// The label of the agent at an index.
fn agent_label(index: Int) -> String {
  "agent_" <> int.to_string(index + 1)
}

/// Does the message ask for work?
fn asks_question() -> Batch(Answer) {
  question.noul_with_criteria(
    content.Text(
      "Does state.message ask for some work to be done on the project, "
      <> "as opposed to commenting, thanking, or talking about something else?",
    ),
    Some(content.Text(
      "The message asks for a change, a fix, an investigation or another "
      <> "piece of work.",
    )),
    Some(content.Text(
      "The message only comments, acknowledges, thanks, reports a status, or "
      <> "is about something else.",
    )),
  )
  |> batch.question("asks_for_work", _)
  |> batch.map(fn(p) { Asks(basis_points(p)) })
}

/// Can the message be acted on without its thread?
fn clear_question() -> Batch(Answer) {
  question.noul_with_criteria(
    content.Text(
      "Can state.message be acted on, or safely left alone, without reading "
      <> "the rest of its thread?",
    ),
    Some(content.Text("The message is complete in itself.")),
    Some(content.Text(
      "The message depends on earlier messages, a reference, or context that "
      <> "is not given.",
    )),
  )
  |> batch.question("clear_alone", _)
  |> batch.map(fn(p) { Clear(basis_points(p)) })
}

/// Does the message continue a listed ticket?
fn continues_question() -> Batch(Answer) {
  question.noul_with_criteria(
    content.Text(
      "Does state.message continue the work of one of the tickets in "
      <> "state.tickets, rather than ask for something new?",
    ),
    Some(content.Text(
      "The message is about the same work as one of the tickets: a follow-up, "
      <> "a correction, a result or a question about it.",
    )),
    Some(content.Text("The message is not about the work of any listed ticket.")),
  )
  |> batch.question("continues_listed_ticket", _)
  |> batch.map(fn(p) { Continues(basis_points(p)) })
}

/// Which listed ticket does it continue? The option's value is the ticket, so
/// the answer carries what it names.
fn which_question(
  tickets: List(Listed),
) -> Result(Batch(Answer), RequestError) {
  list.index_map(tickets, fn(entry, index) {
    question.Alternative(
      ticket_label(index),
      entry.ticket,
      Some(content.Object(description_fields(entry))),
    )
  })
  |> question.choice(
    content.Text(
      "If state.message continues one of the tickets in state.tickets, which "
      <> "one does it continue?",
    ),
    _,
  )
  |> result.map_error(Ask)
  |> result.map(fn(q) {
    batch.question("which_ticket", q)
    |> batch.map(fn(choice) { Which(ranked(choice)) })
  })
}

/// Why does it ask for no work?
fn reason_question() -> Result(Batch(Answer), RequestError) {
  question.choice(content.Text("If state.message asks for no work, why not?"), [
    question.Alternative(
      "off_topic",
      OffTopic,
      Some(content.Text("The message is not about this project.")),
    ),
    question.Alternative(
      "nothing_to_do",
      NothingToDo,
      Some(content.Text(
        "The message is about the project but needs nothing done.",
      )),
    ),
  ])
  |> result.map_error(Ask)
  |> result.map(fn(q) {
    batch.question("decline_reason", q)
    |> batch.map(fn(choice) { Reason(ranked(choice)) })
  })
}

/// Which agent fits new work?
fn agent_question(agents: List(String)) -> Result(Batch(Answer), RequestError) {
  list.index_map(agents, fn(use_for, index) {
    question.Alternative(
      agent_label(index),
      index,
      Some(content.Object([#("use_for", json.string(use_for))])),
    )
  })
  |> question.choice(
    content.Text(
      "If state.message were started as new work, which agent fits it best?",
    ),
    _,
  )
  |> result.map_error(Ask)
  |> result.map(fn(q) {
    batch.question("agent", q)
    |> batch.map(fn(choice) { Agent(ranked(choice)) })
  })
}

/// A probability in basis points, clamped to 0 through 10000.
fn basis_points(value: probability.Probability) -> Int {
  float.round(probability.value(value) *. 10_000.0)
  |> int.clamp(0, 10_000)
}

/// A decoded Choice as basis points over the options it was asked with.
fn ranked(choice: question.Choice(a)) -> Ranked(a) {
  Ranked(
    selected: choice.selected,
    confidence: basis_points(choice.confidence),
    shares: list.map(choice.probabilities, fn(entry) {
      #(entry.0, basis_points(entry.1))
    }),
  )
}

// --- accepting a response ----------------------------------------------------

/// A response that passed the checks of this module.
pub type Accepted {
  Accepted(
    /// The model that answered, validated.
    model: String,
    /// The answers.
    answers: Answers,
    /// Input tokens the service billed.
    input_tokens: Int,
    /// Output tokens, which the service does not charge for.
    output_tokens: Int,
  )
}

/// Check a decoded evaluation. jevelin has already refused unknown labels,
/// probabilities outside [0, 1], and missing or extra answers. What is left is
/// the one string in a response that is not a label, the model name: it is
/// kept in the ledger and shown on a page, so it must be at most
/// `max_model_characters` of letters, digits, dot, underscore and hyphen. Any
/// other name makes the whole response invalid, and nothing is decided from it.
///
/// ## Examples
///
/// ```gleam
/// // jev.accept(jevelin.Evaluation("jev-1.14.0", answers, usage)) -> Ok(_)
/// ```
pub fn accept(
  evaluation: jevelin.Evaluation(Answers),
) -> Result(Accepted, Why) {
  case valid_model(evaluation.model) {
    False -> Error(Invalid)
    True ->
      Ok(Accepted(
        model: evaluation.model,
        answers: evaluation.answers,
        input_tokens: evaluation.usage.input_tokens,
        output_tokens: evaluation.usage.output_tokens,
      ))
  }
}

/// Whether a reported model name is safe to keep and to show.
///
/// ## Examples
///
/// ```gleam
/// assert jev.valid_model("jev-1.14.0")
/// assert !jev.valid_model("jev 1.14")
/// ```
pub fn valid_model(name: String) -> Bool {
  let characters = string.to_graphemes(name)
  characters != []
  && list.drop(characters, max_model_characters) == []
  && list.all(characters, model_character)
}

/// Whether one character may appear in a model name.
fn model_character(character: String) -> Bool {
  // A character is one code point, and only the listed ranges are allowed.
  case string.to_utf_codepoints(character) {
    [single] -> {
      let code = string.utf_codepoint_to_int(single)
      { code >= 48 && code <= 57 }
      || { code >= 65 && code <= 90 }
      || { code >= 97 && code <= 122 }
      || code == 46
      || code == 95
      || code == 45
    }
    _ -> False
  }
}

// --- the decision ------------------------------------------------------------

/// Turn the answers to one request into a decision.
///
/// The rule is total: every combination of answers gives exactly one result,
/// and an answer that the shape asked for but the record lacks is a
/// `LowProbability` fallback and never a crash. In order:
///
/// 1. A message that is not clear alone falls back (`LowClarity`).
/// 2. It attaches to a listed ticket when it continues one with at least the
///    attach bar and, with two or more tickets listed, that ticket's own
///    probability is at least the bar. An inferred trigger also needs to ask
///    for work with at least `asks_at_least`, as new work does.
/// 3. An inferred trigger that asks for work with at most `asks_at_most` is
///    declined, unless it also continues a ticket, which contradicts it and
///    falls back.
/// 4. New work needs the message to continue no listed ticket (or none to be
///    listed) and, for an inferred trigger, to ask for work.
/// 5. Anything else falls back (`LowProbability`).
///
/// ## Examples
///
/// ```gleam
/// // jev.decide(shape, jev.default_bars(), answers) -> jev.New(None)
/// ```
pub fn decide(shape: Shape, bars: Bars, answers: Answers) -> Decision {
  case answers.clear_alone < clear_least {
    True -> Fallback(LowClarity)
    False -> combine(shape, bars, answers)
  }
}

/// The rule after the clarity check. The two strengths differ in what they may
/// do, so each has its own arms.
fn combine(shape: Shape, bars: Bars, answers: Answers) -> Decision {
  let continuing = continues_a_ticket(shape, bars, answers)

  // An explicit trigger is work by definition and is never declined, so it
  // attaches or opens new work.
  case shape.strength {
    Explicit ->
      case continuing {
        True -> attach(shape, bars, answers)
        False -> new_work(shape, answers)
      }

    Inferred -> inferred(shape, bars, answers)
  }
}

/// An inferred trigger must also show that it asks for work.
fn inferred(shape: Shape, bars: Bars, answers: Answers) -> Decision {
  // The asks-for-work Noul decides between acting, declining and falling back.
  case continues_a_ticket(shape, bars, answers), answers.asks_for_work {
    // It continues a ticket and surely asks for work.
    True, Some(asks) if asks >= asks_at_least -> attach(shape, bars, answers)

    // It continues a ticket and does not clearly ask for work, which includes
    // saying it asks for none. The answers disagree, so neither is acted on.
    True, Some(_) -> Fallback(LowProbability)
    True, None -> Fallback(LowProbability)

    // It continues nothing and surely asks for no work.
    False, Some(asks) if asks <= asks_at_most -> decline(answers)

    // It continues nothing and surely asks for work.
    False, Some(asks) if asks >= asks_at_least -> new_work(shape, answers)

    // It falls between the bars, or the question was not answered.
    False, Some(_) -> Fallback(LowProbability)
    False, None -> Fallback(LowProbability)
  }
}

/// Whether the message continues a listed ticket surely enough to attach.
fn continues_a_ticket(shape: Shape, bars: Bars, answers: Answers) -> Bool {
  case shape.tickets, answers.continues {
    [], _ -> False
    [_, ..], Some(value) -> value >= bars.attach
    [_, ..], None -> False
  }
}

/// Attach to, or resume, the ticket the answers select.
fn attach(shape: Shape, bars: Bars, answers: Answers) -> Decision {
  case chosen(shape.tickets, answers.which_ticket, bars.attach) {
    Some(entry) ->
      // An open ticket takes the message as an attachment, an ended one as a
      // reopening.
      case entry.standing {
        OpenTicket -> Attach(entry.ticket)
        EndedTicket -> Resume(entry.ticket)
      }

    None -> Fallback(LowProbability)
  }
}

/// The listed ticket the answers select, if they select it surely enough. With
/// one ticket listed the question is not asked and that ticket is the target.
/// The Choice answers with the ticket itself, so an answer naming a ticket that
/// this shape did not list finds nothing.
fn chosen(
  tickets: List(Listed),
  which: Option(Ranked(TicketId)),
  bar: Int,
) -> Option(Listed) {
  case tickets, which {
    [only], _ -> Some(only)
    [_, _, ..], Some(ranked) ->
      case share_of(ranked) >= bar {
        True ->
          list.find(tickets, fn(entry) { entry.ticket == ranked.selected })
          |> option.from_result
        False -> None
      }
    _, _ -> None
  }
}

/// The probability of the option a Choice selected, or zero if its shares do
/// not list it.
fn share_of(ranked: Ranked(a)) -> Int {
  list.key_find(ranked.shares, ranked.selected) |> result.unwrap(0)
}

/// A decline, with the reason Jev gives.
fn decline(answers: Answers) -> Decision {
  case answers.decline_reason {
    Some(Ranked(selected: OffTopic, ..)) -> Decline(OffTopic)
    Some(Ranked(selected: NothingToDo, ..)) -> Decline(NothingToDo)
    None -> Fallback(LowProbability)
  }
}

/// New work, when the message continues nothing listed.
fn new_work(shape: Shape, answers: Answers) -> Decision {
  // The message is apart from the tickets when none is listed or the Noul is
  // low.
  let apart = case shape.tickets, answers.continues {
    [], _ -> True
    [_, ..], Some(value) -> value <= continues_at_most
    [_, ..], None -> False
  }

  // New work opens a ticket with the agent the answers choose.
  case apart {
    True -> New(agent: agent_of(shape.agents, answers.agent))
    False -> Fallback(LowProbability)
  }
}

/// The catalogue index of the agent that takes new work. A catalogue of one is
/// used without a question, and a selection below the confidence bar means the
/// default.
fn agent_of(agents: List(String), asked: Option(Ranked(Int))) -> Option(Int) {
  case agents, asked {
    [], _ -> None
    [_], _ -> Some(0)
    [_, _, ..], Some(ranked) ->
      // The selection counts only when the Choice is confident and names an
      // agent that exists.
      case
        ranked.confidence >= agent_confidence_least
        && ranked.selected >= 0
        && list.drop(agents, ranked.selected) != []
      {
        True -> Some(ranked.selected)
        False -> None
      }
    [_, _, ..], None -> None
  }
}

// --- what the router still receives ------------------------------------------

/// The candidates of a batch that the engine still holds as offered. These are
/// the ones the model router receives after a Jev pass: whatever the reason
/// Jev did not settle a candidate, and whether or not it was tried.
///
/// ## Examples
///
/// ```gleam
/// // jev.still_offered(state, [a, b]) == [b] after `a` was accepted
/// ```
pub fn still_offered(
  current: State,
  batch: List(TriggerId),
) -> List(TriggerId) {
  list.filter(batch, fn(id) {
    case state.record(current, id) {
      Ok(stored) -> stored.fate == state.Offered
      Error(_) -> False
    }
  })
}

/// The word the ledger keeps for a fallback reason.
///
/// ## Examples
///
/// ```gleam
/// assert jev.why_word(jev.LowClarity) == "low_clarity"
/// ```
pub fn why_word(why: Why) -> String {
  case why {
    LowClarity -> "low_clarity"
    LowProbability -> "low_probability"
    Unavailable -> "unavailable"
    Invalid -> "invalid"
    NoKey -> "no_key"
    Refused -> "refused"
  }
}
