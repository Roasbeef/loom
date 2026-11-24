//// A bounded brief of one running session's recent work, as Home holds it
//// (protocol-change/125).
////
//// Home's inbox says what needs a person. It cannot say what a session is
//// doing, what it last said, or which of its strands are still going, because
//// the activity row carries two clipped strings and the feed carries
//// identities. The daemon answers `session.brief` with this: the latest
//// assistant text, a few recent tool steps, the strand roster, the goal's
//// budget, the peer messages that arrived after a time the page names, and the
//// last command with its exit status. This module is the types, the one total
//// decoder from that reply and the encoder the daemon answers with, so the two
//// halves of the wire are written in one place and a round trip tests them
//// together. It draws nothing and performs no I/O.
////
//// ## Flow
////
//// `decode` → `member` → `items` → `step`, `strand`, `peer`
////
//// 1. `decode` reads the object the reply holds under its brief member.
//// 2. `member` reads a section that is one object and `items` one that is a list,
////    each alone, so one damaged section is absent and the rest still draws. A
////    list keeps the items that decode, through `step`, `strand` and `peer`.
//// 3. `to_json` is the inverse, used by the resident that builds the brief.
////
//// ## What is model text
////
//// The assistant's words, a step's words, a peer's message and the last
//// command are text that a model or another session wrote. They are wrapped in
//// `Untrusted`, so a page must say `untrusted_text` to read one, and it draws
//// it as a text node under a label that says whose words they are. The wire
//// carries `"trust": "untrusted"` beside each so a reader of the JSON sees the
//// same mark. Strand names and the goal's objective are bounded text a page
//// draws as text nodes too. Every time is Unix milliseconds, and the page
//// formats it.

import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// The most recent tool steps a brief lists.
pub const max_steps = 4

/// The most strands a brief lists.
pub const max_strands = 12

/// The most peer messages a brief lists.
pub const max_peers = 3

/// The longest assistant text, in bytes. The text keeps its newlines and is cut
/// at a block boundary (`block_clip`), so the page can draw it as Markdown.
pub const assistant_bytes = 1600

/// The longest words of one step, in bytes.
pub const words_bytes = 120

/// The longest tool name, in bytes.
pub const tool_bytes = 64

/// The longest strand name, in bytes.
pub const strand_bytes = 96

/// The longest goal objective, in bytes.
pub const objective_bytes = 200

/// The longest peer message, in bytes.
pub const peer_bytes = 280

/// The longest command, in bytes.
pub const command_bytes = 200

/// The encoded size a brief never exceeds, in bytes. The daemon sheds the
/// strands, then the peers, then the steps until a brief fits, and the reply
/// is checked against the 60,000-byte frame as well.
pub const brief_bytes = 20_000

/// Text a model or another session wrote. It is a type of its own so that no
/// page reads it by accident: the words are behind `untrusted_text`, and a page
/// draws them as a text node, never as markup, an attribute, a key or a path.
pub opaque type Untrusted {
  Untrusted(text: String)
}

/// The assistant's latest text, which may belong to a turn that is still
/// running.
pub type Assistant {
  Assistant(
    /// The words, cut to `assistant_bytes` at a block boundary.
    text: Untrusted,
    /// When the entry holding them was written.
    at: Int,
  )
}

/// How a step stands.
pub type Outcome {
  /// The call has no result yet.
  Running

  /// The call's result reported success. It is not a claim about what the
  /// command meant.
  Succeeded

  /// The call's result reported a failure.
  Failed
}

/// One recent tool step, newest first in a brief.
pub type Step {
  Step(
    /// When the response that asked for the call was written.
    at: Int,
    /// The tool's name, cut to `tool_bytes`. The model chooses the name of a call
    /// it makes, so it is model text.
    tool: Untrusted,
    /// The step's words as one line, such as `Ran make check-core` or
    /// `Edit calc.py +3 −1`, cut to `words_bytes`.
    words: Untrusted,
    /// How the step stands.
    outcome: Outcome,
  )
}

/// What a strand is doing.
pub type State {
  /// A run is open on the strand.
  Working

  /// Nothing is running and the last run did not fail.
  Idle

  /// Nothing is running and the last run failed.
  Stopped
}

/// One strand of the session.
pub type Strand {
  Strand(
    /// The strand's name, cut to `strand_bytes`.
    name: String,
    /// What it is doing.
    state: State,
    /// When it last changed state: the start of its open run for a working
    /// strand and the time of its last entry for another. Absent when there is
    /// nothing to read.
    since: Option(Int),
  )
}

/// The session's goal and what it has spent.
pub type Goal {
  Goal(
    /// The operator's objective, cut to `objective_bytes`.
    objective: String,
    /// `active`, `paused`, `limited` or `complete`.
    status: String,
    /// Tokens accounted to the goal so far.
    tokens_used: Int,
    /// The goal's token budget.
    token_budget: Int,
  )
}

/// One peer message the session received.
pub type Peer {
  Peer(
    /// The sending session's identity.
    session: String,
    /// The sending strand.
    strand: String,
    /// When the message was recorded.
    at: Int,
    /// The message, cut to `peer_bytes`.
    text: Untrusted,
  )
}

/// The last shell command the main strand ran and how it ended. A page words it
/// as a fact, "last command: X, exit N", and never as the result of a check.
pub type Command {
  Command(
    /// The command line as the call gave it, cut to `command_bytes`.
    command: Untrusted,
    /// The exit status the result reported.
    exit: Int,
    /// When the response that asked for the call was written.
    at: Int,
  )
}

/// One session's brief.
pub type Brief {
  Brief(
    /// The latest assistant text, or nothing before the first.
    assistant: Option(Assistant),
    /// The recent steps, newest first, at most `max_steps`.
    steps: List(Step),
    /// The strands, at most `max_strands`.
    strands: List(Strand),
    /// The goal, when the session has one.
    goal: Option(Goal),
    /// The peer messages after the time the read named, newest first, at most
    /// `max_peers`.
    peers: List(Peer),
    /// The last shell command, when one ran.
    command: Option(Command),
  )
}

/// What the page has of a session's brief.
pub type Seen {
  /// The daemon answered with this brief.
  Seen(brief: Brief)

  /// The daemon refused or did not answer. The words are its fixed ones.
  Unseen(words: String)
}

/// Marks text as written by a model or another session.
///
/// ## Examples
///
/// ```gleam
/// assert session_brief.untrusted_text(session_brief.untrusted("hi")) == "hi"
/// ```
pub fn untrusted(text: String) -> Untrusted {
  Untrusted(text:)
}

/// The text inside an `Untrusted`, for the one place that draws it as a text
/// node under a label that says whose words they are.
///
/// ## Examples
///
/// ```gleam
/// assert session_brief.untrusted_text(session_brief.untrusted("hi")) == "hi"
/// ```
pub fn untrusted_text(words: Untrusted) -> String {
  words.text
}

/// The brief of a reply `{"brief": {...}}`, or nothing for a reply that is not
/// one. A damaged section is left out and the others are kept.
///
/// ## Examples
///
/// ```gleam
/// assert session_brief.decode(json.Null) == Error(Nil)
/// ```
pub fn decode(value: JsonValue) -> Result(Brief, Nil) {
  use fields <- result.try(object(value))
  use inner <- result.try(list.key_find(fields, "brief"))
  use inner <- result.map(object(inner))

  Brief(
    assistant: member(inner, "assistant", assistant),
    steps: items(inner, "steps", step),
    strands: items(inner, "strands", strand),
    goal: member(inner, "goal", goal),
    peers: items(inner, "peers", peer),
    command: member(inner, "command", command),
  )
}

/// The reply a resident answers with: `{"brief": {...}}`. Absent sections are
/// left out.
///
/// ## Examples
///
/// ```gleam
/// assert session_brief.decode(session_brief.to_json(brief)) == Ok(brief)
/// ```
pub fn to_json(brief: Brief) -> JsonValue {
  json.Object([
    #(
      "brief",
      json.Object(
        list.flatten([
          case brief.assistant {
            Some(Assistant(text:, at:)) -> [
              #(
                "assistant",
                json.Object([
                  #("text", json.String(untrusted_text(text))),
                  #("trust", json.String("untrusted")),
                  #("at", json.Int(at)),
                ]),
              ),
            ]
            None -> []
          },
          [#("steps", json.Array(list.map(brief.steps, step_json)))],
          [#("strands", json.Array(list.map(brief.strands, strand_json)))],
          case brief.goal {
            Some(goal) -> [#("goal", goal_json(goal))]
            None -> []
          },
          [#("peers", json.Array(list.map(brief.peers, peer_json)))],
          case brief.command {
            Some(command) -> [#("command", command_json(command))]
            None -> []
          },
        ]),
      ),
    ),
  ])
}

// --- reading ----------------------------------------------------------------

/// A section that is one object, or nothing when it is missing or damaged.
fn member(
  fields: List(#(String, JsonValue)),
  name: String,
  read: fn(List(#(String, JsonValue))) -> Result(item, Nil),
) -> Option(item) {
  list.key_find(fields, name)
  |> result.try(object)
  |> result.try(read)
  |> option.from_result
}

/// A section that is a list of objects, keeping the items that read.
fn items(
  fields: List(#(String, JsonValue)),
  name: String,
  read: fn(List(#(String, JsonValue))) -> Result(item, Nil),
) -> List(item) {
  case list.key_find(fields, name) {
    Ok(json.Array(raw)) ->
      list.filter_map(raw, fn(value) { object(value) |> result.try(read) })
    Ok(_) | Error(Nil) -> []
  }
}

/// The assistant's text and its time.
fn assistant(fields: List(#(String, JsonValue))) -> Result(Assistant, Nil) {
  use text <- result.try(text(fields, "text"))
  use at <- result.map(time(fields, "at"))
  Assistant(text: untrusted(text), at:)
}

/// One step.
fn step(fields: List(#(String, JsonValue))) -> Result(Step, Nil) {
  use at <- result.try(time(fields, "at"))
  use tool <- result.try(text(fields, "tool"))
  use words <- result.try(text(fields, "words"))
  use outcome <- result.map(text(fields, "outcome") |> result.try(outcome_of))
  Step(at:, tool: untrusted(tool), words: untrusted(words), outcome:)
}

/// The outcome a word names, or nothing for a word this page does not know.
fn outcome_of(word: String) -> Result(Outcome, Nil) {
  case word {
    "running" -> Ok(Running)
    "succeeded" -> Ok(Succeeded)
    "failed" -> Ok(Failed)
    _ -> Error(Nil)
  }
}

/// The word of an outcome.
fn outcome_word(outcome: Outcome) -> String {
  case outcome {
    Running -> "running"
    Succeeded -> "succeeded"
    Failed -> "failed"
  }
}

/// One strand.
fn strand(fields: List(#(String, JsonValue))) -> Result(Strand, Nil) {
  use name <- result.try(text(fields, "name"))
  use state <- result.map(text(fields, "state") |> result.try(state_of))
  Strand(name:, state:, since: option.from_result(time(fields, "since")))
}

/// The state a word names, or nothing for a word this page does not know.
fn state_of(word: String) -> Result(State, Nil) {
  case word {
    "working" -> Ok(Working)
    "idle" -> Ok(Idle)
    "stopped" -> Ok(Stopped)
    _ -> Error(Nil)
  }
}

/// The word of a state.
fn state_word(state: State) -> String {
  case state {
    Working -> "working"
    Idle -> "idle"
    Stopped -> "stopped"
  }
}

/// The goal.
fn goal(fields: List(#(String, JsonValue))) -> Result(Goal, Nil) {
  use objective <- result.try(text(fields, "objective"))
  use status <- result.try(text(fields, "status"))
  use tokens_used <- result.try(time(fields, "tokens_used"))
  use token_budget <- result.map(time(fields, "token_budget"))
  Goal(objective:, status:, tokens_used:, token_budget:)
}

/// One peer message.
fn peer(fields: List(#(String, JsonValue))) -> Result(Peer, Nil) {
  use session <- result.try(text(fields, "session"))
  use strand <- result.try(text(fields, "strand"))
  use at <- result.try(time(fields, "at"))
  use words <- result.map(text(fields, "text"))
  Peer(session:, strand:, at:, text: untrusted(words))
}

/// The last command.
fn command(fields: List(#(String, JsonValue))) -> Result(Command, Nil) {
  use words <- result.try(text(fields, "command"))

  // The exit status is a whole number the result reported, and anything else is no command.
  use exit <- result.try(case list.key_find(fields, "exit") {
    Ok(json.Int(code)) -> Ok(code)
    Ok(_) | Error(Nil) -> Error(Nil)
  })

  use at <- result.map(time(fields, "at"))
  Command(command: untrusted(words), exit:, at:)
}

/// The fields of an object.
fn object(value: JsonValue) -> Result(List(#(String, JsonValue)), Nil) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}

/// A string field.
fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, Nil) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

/// A whole non-negative number: a time or a count.
fn time(fields: List(#(String, JsonValue)), name: String) -> Result(Int, Nil) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    Ok(_) | Error(Nil) -> Error(Nil)
  }
}

// --- writing ----------------------------------------------------------------

/// One step as the wire carries it.
fn step_json(step: Step) -> JsonValue {
  json.Object([
    #("at", json.Int(step.at)),
    #("tool", json.String(untrusted_text(step.tool))),
    #("words", json.String(untrusted_text(step.words))),
    #("trust", json.String("untrusted")),
    #("outcome", json.String(outcome_word(step.outcome))),
  ])
}

/// One strand as the wire carries it, with `since` only when it has one.
fn strand_json(strand: Strand) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("name", json.String(strand.name)),
        #("state", json.String(state_word(strand.state))),
      ],
      case strand.since {
        Some(at) -> [#("since", json.Int(at))]
        None -> []
      },
    ]),
  )
}

/// The goal as the wire carries it.
fn goal_json(goal: Goal) -> JsonValue {
  json.Object([
    #("objective", json.String(goal.objective)),
    #("status", json.String(goal.status)),
    #("tokens_used", json.Int(goal.tokens_used)),
    #("token_budget", json.Int(goal.token_budget)),
  ])
}

/// One peer message as the wire carries it.
fn peer_json(peer: Peer) -> JsonValue {
  json.Object([
    #("session", json.String(peer.session)),
    #("strand", json.String(peer.strand)),
    #("at", json.Int(peer.at)),
    #("text", json.String(untrusted_text(peer.text))),
    #("trust", json.String("untrusted")),
  ])
}

/// The last command as the wire carries it.
fn command_json(command: Command) -> JsonValue {
  json.Object([
    #("command", json.String(untrusted_text(command.command))),
    #("trust", json.String("untrusted")),
    #("exit", json.Int(command.exit)),
    #("at", json.Int(command.at)),
  ])
}
