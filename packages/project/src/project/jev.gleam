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
//// the gate's stored strength. A listed ticket is never one that the engine
//// would refuse for an inferred trigger, so that label does not exist.
////
//// ## Flow
////
//// `listing` → `request` → the daemon sends it → `accept` → `decide`
////
//// 1. `listing` picks the tickets the request may offer.
//// 2. `request` builds the questions and the object Jev reads as its state.
//// 3. `accept` checks the model name the response reports and returns the
////    answers as integer basis points.
//// 4. `decide` combines the answers under fixed bars and one configured bar.
//// 5. `still_offered` names the candidates the engine still holds as offered,
////    which are the ones the model router receives.
////
//// The design is in docs/design-notes/project-jev-routing.md.

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
  type Strength, type TicketId, type TriggerId, Explicit, Inferred,
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

/// What a request asked, and so what its answers can mean.
pub type Shape {
  Shape(
    /// The trigger's strength, fixed by the gate when it arrived.
    strength: Strength,
    /// The tickets offered, in the order the labels number them.
    tickets: List(Listed),
    /// What each catalogue agent is for, in the operator's words and in the
    /// order the labels number them.
    agents: List(String),
  )
}

/// The text of one request.
pub type Message {
  Message(
    /// The trigger's text. A request carries at most
    /// `max_message_codepoints` of it.
    text: String,
    /// A fixed phrase for where the message came from, never a login.
    source: String,
  )
}

/// A Choice answer in basis points, over labels numbered from zero.
pub type Ranked {
  Ranked(
    /// The index of the label Jev selected.
    selected: Int,
    /// Jev's confidence in the selection.
    confidence: Int,
    /// The probability of every label, in request order.
    shares: List(#(Int, Int)),
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
    which_ticket: Option(Ranked),
    /// Why it asks for no work: index 0 is `off_topic`, 1 is `nothing_to_do`.
    decline_reason: Option(Ranked),
    /// Which catalogue agent fits new work.
    agent: Option(Ranked),
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

/// The one bar an operator sets, in basis points: how sure Jev must be to
/// attach a message to an existing ticket. The other bars are fixed here and
/// belong to the request-shape version that the pin carries.
pub type Bars {
  Bars(
    /// The least probability for attaching to a listed ticket.
    attach: Int,
  )
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

// --- the listing -------------------------------------------------------------

/// The tickets a request about a trigger of `strength` may offer.
///
/// These are the tickets whose mandate stands (no person's stop), newest
/// opened first, at most `max_listed`. For an inferred trigger a ticket with
/// an explicit mandate is left out, which is the test `intake.takes` applies,
/// so Jev cannot pick a ticket the engine would refuse.
///
/// ## Examples
///
/// ```gleam
/// // jev.listing(state.start(config), Inferred) == []
/// ```
pub fn listing(current: State, strength: Strength) -> List(Listed) {
  state.tickets_oldest_first(current)
  |> list.reverse
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
    state.Granted, Explicit, _ -> True
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

/// Rotate a list so that it starts `by` places later, wrapping around. The
/// verdict's three trials are three rotations of the ticket order, because
/// Jev leans toward the first option of a Choice.
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
  Which(Ranked)
  Reason(Ranked)
  Agent(Ranked)
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
  let inferred = shape.strength == Inferred
  let listed = shape.tickets != []
  [
    case inferred {
      True -> [asks_question()]
      False -> []
    },
    [clear_question()],
    case listed {
      True -> [continues_question()]
      False -> []
    },
  ]
  |> list.flatten
}

/// The Choices this shape asks.
fn choice_batches(shape: Shape) -> Result(List(Batch(Answer)), RequestError) {
  let inferred = shape.strength == Inferred

  // One ticket gives the Choice nothing to choose between, so it is not
  // asked, and that ticket is the target.
  use which <- result.try(case shape.tickets {
    [_, _, ..] -> which_question(shape.tickets) |> result.map(fn(b) { [b] })
    _ -> Ok([])
  })

  // Only an inferred trigger can be declined, so only it is asked why not.
  use reason <- result.try(case inferred {
    True -> reason_question() |> result.map(fn(b) { [b] })
    False -> Ok([])
  })

  // One agent is used without a question, for the same reason.
  use agent <- result.map(case shape.agents {
    [_, _, ..] -> agent_question(shape.agents) |> result.map(fn(b) { [b] })
    _ -> Ok([])
  })

  list.flatten([which, reason, agent])
}

/// The `state` object. A request about a message sees only these fields.
fn state_of(shape: Shape, message: Message) -> Content {
  let base = [
    #("message", json.string(cap_message(message.text))),
    #("source", json.string(message.source)),
  ]

  // The Noul about tickets sees only `state`, so the tickets are in it.
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
      #(ticket_label(index), description(entry))
    }),
  )
}

/// A ticket's description: its stage, and its title when it has one to show.
fn description(entry: Listed) -> Json {
  // A ticket whose title is a stranger's has the stage word alone.
  let title = case entry.title {
    Some(text) -> [#("title", json.string(text))]
    None -> []
  }

  json.object([#("stage", json.string(entry.stage)), ..title])
}

/// The first `max_message_codepoints` code points of a message.
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

/// Which listed ticket does it continue?
fn which_question(
  tickets: List(Listed),
) -> Result(Batch(Answer), RequestError) {
  list.index_map(tickets, fn(entry, index) {
    question.Alternative(ticket_label(index), index, Some(describe(entry)))
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

/// An alternative's description for a ticket.
fn describe(entry: Listed) -> Content {
  // The same rule as in the state object: a title only when one is shown.
  let title = case entry.title {
    Some(text) -> [#("title", json.string(text))]
    None -> []
  }

  content.Object([#("stage", json.string(entry.stage)), ..title])
}

/// Why does it ask for no work?
fn reason_question() -> Result(Batch(Answer), RequestError) {
  question.choice(content.Text("If state.message asks for no work, why not?"), [
    question.Alternative(
      "off_topic",
      0,
      Some(content.Text("The message is not about this project.")),
    ),
    question.Alternative(
      "nothing_to_do",
      1,
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

/// A decoded Choice as basis points over the labels' indexes.
fn ranked(choice: question.Choice(Int)) -> Ranked {
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
/// // jev.decide(shape, jev.Bars(attach: 8000), answers) -> jev.New(None)
/// ```
pub fn decide(shape: Shape, bars: Bars, answers: Answers) -> Decision {
  case answers.clear_alone < clear_least {
    True -> Fallback(LowClarity)
    False -> combine(shape, bars, answers)
  }
}

/// Whether the message passes the bar for being work. An explicit trigger is
/// work by definition, and an inferred one must ask for it surely enough.
fn asks_for_work(shape: Shape, answers: Answers) -> Bool {
  case shape.strength, answers.asks_for_work {
    Explicit, _ -> True
    Inferred, Some(value) -> value >= asks_at_least
    Inferred, None -> False
  }
}

/// The rule after the clarity check.
fn combine(shape: Shape, bars: Bars, answers: Answers) -> Decision {
  let inferred = shape.strength == Inferred
  let asks = answers.asks_for_work
  let continues = answers.continues
  let listed = shape.tickets != []

  // The message continues a listed ticket when the Noul is sure enough.
  let continuing = case continues {
    Some(value) -> listed && value >= bars.attach
    None -> False
  }

  let asking = asks_for_work(shape, answers)

  // The two Nouls decide between an attach, a contradiction and the rest.
  case continuing, asking {
    // The message continues a ticket and, if inferred, asks for work.
    True, True -> attach(shape, bars, answers)

    // The message continues a ticket and says it asks for no work. The two
    // answers disagree, so neither is acted on.
    True, False -> Fallback(LowProbability)

    False, _ ->
      // An inferred message that asks for no work is declined, and anything
      // else is new work if it passes that test's own bar.
      case inferred, asks {
        True, Some(value) if value <= asks_at_most -> decline(answers)
        _, _ -> new_work(shape, answers)
      }
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
fn chosen(
  tickets: List(Listed),
  which: Option(Ranked),
  bar: Int,
) -> Option(Listed) {
  case tickets, which {
    [only], _ -> Some(only)
    [_, _, ..], Some(ranked) ->
      case share_of(ranked, ranked.selected) >= bar {
        True -> at(tickets, ranked.selected)
        False -> None
      }
    _, _ -> None
  }
}

/// The element at an index, if the list has one.
fn at(items: List(a), index: Int) -> Option(a) {
  case index >= 0 {
    True -> items |> list.drop(index) |> list.first |> option.from_result
    False -> None
  }
}

/// A label's probability in a Choice answer, or zero for a label it lacks.
fn share_of(ranked: Ranked, index: Int) -> Int {
  case list.key_find(ranked.shares, index) {
    Ok(value) -> value
    Error(Nil) -> 0
  }
}

/// A decline, with the reason Jev gives.
fn decline(answers: Answers) -> Decision {
  case answers.decline_reason {
    Some(Ranked(selected: 0, ..)) -> Decline(OffTopic)
    Some(Ranked(selected: 1, ..)) -> Decline(NothingToDo)
    _ -> Fallback(LowProbability)
  }
}

/// New work, when the message continues nothing listed and, if inferred, asks
/// for work.
fn new_work(shape: Shape, answers: Answers) -> Decision {
  // The message is apart from the tickets when none is listed or the Noul is
  // low.
  let apart = case shape.tickets, answers.continues {
    [], _ -> True
    _, Some(value) -> value <= continues_at_most
    _, None -> False
  }

  // Both the separation and, for an inferred trigger, the ask must hold.
  case apart && asks_for_work(shape, answers) {
    True -> New(agent: agent_of(shape.agents, answers.agent))
    False -> Fallback(LowProbability)
  }
}

/// The catalogue index of the agent that takes new work. A catalogue of one is
/// used without a question, and a selection below the confidence bar means the
/// default.
fn agent_of(agents: List(String), asked: Option(Ranked)) -> Option(Int) {
  case agents, asked {
    [], _ -> None
    [_], _ -> Some(0)
    [_, _, ..], Some(ranked) ->
      // The selection counts only when the Choice is confident and names an
      // agent that exists.
      case
        ranked.confidence >= agent_confidence_least
        && option.is_some(at(agents, ranked.selected))
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
