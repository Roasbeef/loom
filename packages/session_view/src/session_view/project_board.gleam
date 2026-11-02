//// The project board: the daemon's `projects.board` and `projects.ticket`
//// replies, decoded totally, and the words both hosts use for them
//// (protocol-change/106).
////
//// A project is a set of tickets. Most of them need nobody, and the board
//// exists for the few that need a person: a question a worker asked, a branch
//// waiting for review, an input that never reached its worker, a worker that
//// reported itself blocked or failed. This module orders tickets so those come
//// first, groups them by the stage word the daemon sent, and says why each
//// ticket was allowed to exist in plain sentences. The terminal's board
//// screen and the web view's Projects section both draw from it, so the order
//// and the words cannot differ between them.
////
//// Three rules from the protocol govern the decoders.
////
//// - A stage is the daemon's spelling and is never derived here. A stage this
////   client does not know, as a newer daemon may send, is kept as text and
////   drawn as text. It counts as needing a person when it is spelled
////   `person/...`, because that prefix is the protocol's own marker.
//// - An absent field is unknown and is never zero. A ticket with no
////   `opened_ms` has no age, and the words say so; a ticket with no title is
////   drawn as untitled rather than with an empty line.
//// - Every string is external text. A title or a question can come from a
////   message anyone could write. The decoders pass each one through
////   `text_hygiene` once, so a terminal escape sequence or a control character
////   cannot reach a screen, and a host draws the result as text. Markup needs
////   no special handling here, because neither host interprets text as markup.
////
//// A row the decoders cannot address, one with no usable `id`, is counted in
//// `Board.unreadable` and left out. Dropping it silently would hide a ticket,
//// and keeping it would offer a command that names nothing.
////
//// ## Flow
////
//// `decode_board` → `ordered` → `groups` → `health_words`
////
//// 1. `decode_board` reads the board reply into a `Board`, and
////    `decode_detail` reads the ticket reply into a `Detail`.
//// 2. `ordered` puts needs-a-person tickets first, by stage urgency, newest
////    first within a stage.
//// 3. `groups` splits the ordered tickets into runs of one stage word, which
////    is what a host draws as headings.
//// 4. `health_words` is the one line a healthy board shows, and
////    `mandate_words` and `age_words` are the sentences a row and a detail
////    page add.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import session_view/text_hygiene

/// How long a host that shows the board waits before reading it again, in
/// milliseconds. The daemon pushes nothing about projects, so a poll and the
/// board's `revision` are how an open screen learns of a change.
pub const refresh_ms = 5000

/// The most characters of an id this client accepts. The daemon's own ids are
/// far shorter, and the bound keeps a hostile one out of a URL or a command.
const id_limit = 128

/// A ticket's stage, in the daemon's own spelling.
pub type Stage {
  /// An input never reached the worker. `person/delivery`.
  PersonDelivery

  /// The worker asked a question. `person/answer`.
  PersonAnswer

  /// The work waits for a person's review. `person/review`.
  PersonReview

  /// The worker reported itself blocked. `person/blocked`.
  PersonBlocked

  /// The worker reported failure. `person/failed`.
  PersonFailed

  /// Waiting for a session. `queued`.
  Queued

  /// Nothing is running and nothing is wanted. `idle`.
  Idle

  /// A worker is on it. `working`.
  Working

  /// The ticket ended. `ended/<outcome>`.
  Ended(
    /// The outcome word after `ended/`, such as `merged`.
    outcome: String,
  )

  /// A stage this client does not know, kept as the daemon sent it.
  UnknownStage(
    /// The stage word, made safe to draw.
    word: String,
  )
}

/// Something the daemon says a person can do with a ticket now. The daemon
/// lists these from the engine's own rules, so a client shows a control for
/// each one listed and derives none of them from the stage.
pub type Action {
  /// Answer the worker's open question.
  CanAnswer

  /// Accept the work and close the ticket.
  CanClose

  /// Ask for a new worker.
  CanRetry

  /// Publish the ticket's head.
  CanPublish

  /// Withdraw the ticket's mandate.
  CanStop

  /// An action this client does not know, kept as the daemon sent it. No
  /// control is drawn for it.
  UnknownAction(
    /// The action word, made safe to draw.
    word: String,
  )
}

/// Why a ticket was allowed to exist, as the daemon recorded it.
pub type Mandate {
  Mandate(
    /// `explicit` or `inferred`, or the daemon's word for a strength this
    /// client does not know.
    strength: String,
    /// How the mandate arose: `composer`, `addressed`, `follow_up`,
    /// `overheard`, `automation`, `rule`, or a word this client does not know.
    via: String,
    /// The source of the message, such as `composer` or `github`.
    source: String,
    /// The actor who wrote it.
    actor: String,
    /// The policy version it was judged under.
    policy_version: String,
  )
}

/// A worker's question for a person. The answer echoes `seq`.
pub type Question {
  Question(
    /// The question's sequence number. An answer to any other is refused.
    seq: Int,
    /// What the worker asked, as text.
    text: String,
    /// The options the worker offered, possibly none.
    options: List(String),
  )
}

/// One ticket as the board and the detail both carry it.
pub type Ticket {
  Ticket(
    /// The ticket's id, which commands name.
    id: String,
    /// The capped title, or none when the daemon sent none.
    title: Option(String),
    /// The daemon's stage.
    stage: Stage,
    /// The worker's session id, once one is bound.
    session: Option(String),
    /// Why it was allowed, or none when the daemon did not say.
    mandate: Option(Mandate),
    /// When the opening message arrived, in Unix milliseconds. None is
    /// unknown, which is not the same as zero.
    opened_ms: Option(Int),
    /// The open question, if any.
    question: Option(Question),
    /// The pull request address, once there is one.
    pull_request: Option(String),
    /// Why the daemon ended the worker's attempt as failed, when the worker
    /// never reported, in the daemon's words.
    failure: Option(String),
    /// What a person can do with the ticket now, as the daemon listed it. A
    /// daemon that sends none offers none.
    actions: List(Action),
  )
}

/// A page of the board.
pub type Board {
  Board(
    /// The project's id.
    project: String,
    /// The ledger's newest sequence number. A new board with the same
    /// revision as the last one changes nothing a person can see.
    revision: Int,
    /// All tickets in the project, which may exceed the page.
    total: Int,
    /// The tickets on this page, in the order they arrived.
    tickets: List(Ticket),
    /// Rows this client could not address and left out.
    unreadable: Int,
    /// What `observe` rules recorded as work they would have done, newest
    /// first. The owner reads these to judge a rule before it acts.
    would: List(Would),
    /// The configured rules with their modes and where each stands on its
    /// verdict, in the order the owner wrote them.
    rules: List(Rule),
  )
}

/// One configured rule: its mode and where its verdict stands. A rule may
/// run on its own only with a current passing verdict.
pub type Rule {
  Rule(
    /// The rule's name.
    name: String,
    /// `off`, `observe`, `auto`, or a word this client does not know.
    mode: String,
    /// `none`, `failing`, `stale`, `current`, or a word this client does not
    /// know.
    verdict: String,
    /// The daemon's sentence about the verdict, which says what a pass
    /// claims.
    words: String,
    /// The triggers a person has labelled for the rule.
    labelled: Int,
    /// The labels a verdict needs.
    needed: Int,
  )
}

/// What the owner decided about a recorded trigger.
pub type Judgement {
  /// The project should have taken it on as work.
  ShouldTake

  /// The project should not have.
  ShouldNotTake
}

/// The word `projects.label` takes for a judgement.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.judgement_word(project_board.ShouldTake) == "accept"
/// ```
pub fn judgement_word(judgement: Judgement) -> String {
  case judgement {
    ShouldTake -> "accept"
    ShouldNotTake -> "reject"
  }
}

/// A recorded trigger waiting for a person's label.
pub type Candidate {
  Candidate(
    /// The trigger's id.
    trigger: String,
    /// Who wrote it.
    actor: String,
    /// The start of its text, on one line.
    text: String,
    /// What the project did with it: `took`, `declined`, `not_asked`, or a
    /// word this client does not know.
    recorded: String,
  )
}

/// The triggers of one rule that want a label.
pub type Labels {
  Labels(
    /// The rule.
    rule: String,
    /// The triggers already labelled.
    labelled: Int,
    /// The labels a verdict needs.
    needed: Int,
    /// The triggers to label, newest first.
    candidates: List(Candidate),
  )
}

/// One inferred message that a rule in `observe` mode recorded as accepted
/// work and did nothing about.
pub type Would {
  Would(
    /// The message's id.
    trigger: String,
    /// The rule that matched it.
    rule: String,
    /// Who wrote it.
    actor: String,
    /// The start of its text, on one line.
    text: String,
    /// Where it can be read, as the daemon built the address from the
    /// project's remote. It is drawn as text and never made into a link by a
    /// client, like a pull request's address.
    link: Option(String),
  )
}

/// The most characters of a message a "would have done" row shows.
pub const would_text_limit = 160

/// Where an input stands with the worker.
pub type Delivery {
  /// The worker received it.
  Delivered

  /// It is queued until a session exists.
  Waiting

  /// It never reached the worker.
  Failed

  /// The gate did not admit it, so it was recorded and never delivered.
  Recorded

  /// A state this client does not know, as the daemon named it.
  UnknownDelivery(
    /// The word, made safe to draw.
    word: String,
  )
}

/// One message on a ticket's thread.
pub type Input {
  Input(
    /// The message's id.
    trigger: String,
    /// Where it stands with the worker.
    delivery: Delivery,
    /// Its source, when the ledger holds one.
    source: Option(String),
    /// Its actor, when the ledger holds one.
    actor: Option(String),
    /// Its text, when the ledger holds it. None is unknown, not empty.
    text: Option(String),
  )
}

/// One worker session bound to a ticket over time.
pub type Assignment {
  Assignment(
    /// One-based sequence number within the ticket.
    seq: Int,
    /// The session id, none until the host binds one.
    session: Option(String),
    /// `pending`, `running`, `done/exited`, `done/crashed`, or a word this
    /// client does not know.
    status: String,
  )
}

/// A ticket with its assignments and inputs.
pub type Detail {
  Detail(
    /// The project's id.
    project: String,
    /// The ledger's newest sequence number when it was read.
    revision: Int,
    /// The ticket.
    ticket: Ticket,
    /// Its assignments, newest first.
    assignments: List(Assignment),
    /// Its inputs, oldest first.
    inputs: List(Input),
  )
}

/// A group of tickets that share a stage word.
pub type Group {
  Group(
    /// The word to draw as the heading.
    word: String,
    /// Whether the stage is one that needs a person.
    needs: Attention,
    /// The tickets, in board order.
    tickets: List(Ticket),
  )
}

/// Whether a stage needs a person.
pub type Attention {
  /// A person has to act.
  NeedsPerson

  /// Nobody has to act.
  NeedsNobody
}

/// The stage a wire word names. A word this client does not know is kept.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.parse_stage("person/answer") == project_board.PersonAnswer
/// assert project_board.parse_stage("ended/merged")
///   == project_board.Ended("merged")
/// ```
pub fn parse_stage(word: String) -> Stage {
  case word {
    "person/delivery" -> PersonDelivery
    "person/answer" -> PersonAnswer
    "person/review" -> PersonReview
    "person/blocked" -> PersonBlocked
    "person/failed" -> PersonFailed
    "queued" -> Queued
    "idle" -> Idle
    "working" -> Working
    _ ->
      case string.split_once(word, "ended/") {
        Ok(#("", outcome)) -> Ended(text_hygiene.single_line(outcome))
        Ok(_) | Error(Nil) -> UnknownStage(text_hygiene.single_line(word))
      }
  }
}

/// The short word a row shows for a stage.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.stage_word(project_board.PersonAnswer) == "answer"
/// assert project_board.stage_word(project_board.Ended("merged")) == "ended: merged"
/// ```
pub fn stage_word(stage: Stage) -> String {
  case stage {
    PersonDelivery -> "delivery"
    PersonAnswer -> "answer"
    PersonReview -> "review"
    PersonBlocked -> "blocked"
    PersonFailed -> "failed"
    Queued -> "queued"
    Idle -> "idle"
    Working -> "working"
    Ended(outcome) -> "ended: " <> outcome
    UnknownStage(word) ->
      case word {
        "" -> "unknown"
        _ -> word
      }
  }
}

/// Whether a stage needs a person. A stage this client does not know needs a
/// person when the daemon spelled it `person/...`.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.attention(project_board.PersonReview)
///   == project_board.NeedsPerson
/// assert project_board.attention(project_board.UnknownStage("person/triage"))
///   == project_board.NeedsPerson
/// assert project_board.attention(project_board.Working)
///   == project_board.NeedsNobody
/// ```
pub fn attention(stage: Stage) -> Attention {
  case stage {
    PersonDelivery
    | PersonAnswer
    | PersonReview
    | PersonBlocked
    | PersonFailed -> NeedsPerson
    Queued | Idle | Working | Ended(_) -> NeedsNobody
    UnknownStage(word) ->
      case string.starts_with(word, "person/") {
        True -> NeedsPerson
        False -> NeedsNobody
      }
  }
}

/// Decodes a `projects.board` body. A body that is not an object with a
/// `project` and a `revision` is an error; a row inside it that cannot be
/// addressed is counted in `unreadable` and left out.
///
/// ## Examples
///
/// ```gleam
/// let body = json.Object([
///   #("project", json.String("p1")),
///   #("revision", json.Int(3)),
///   #("total", json.Int(0)),
///   #("tickets", json.Array([])),
/// ])
/// assert project_board.decode_board(body) |> result.is_ok
/// ```
pub fn decode_board(value: JsonValue) -> Result(Board, String) {
  case value {
    json.Object(fields) -> board_of(fields)
    _ -> Error("the board was not an object")
  }
}

/// Decodes a `projects.ticket` body.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.decode_detail(json.Null) |> result.is_error
/// ```
pub fn decode_detail(value: JsonValue) -> Result(Detail, String) {
  case value {
    json.Object(fields) -> detail_of(fields)
    _ -> Error("the ticket was not an object")
  }
}

/// The id of the project whose workspace is `workspace`, from a
/// `projects.list` body, or nothing when there is none.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.project_for(json.Null, "/work") == None
/// ```
pub fn project_for(listed: JsonValue, workspace: String) -> Option(String) {
  case listed {
    json.Object(fields) ->
      case list.key_find(fields, "projects") {
        Ok(json.Array(rows)) ->
          list.find_map(rows, fn(row) { project_row(row, workspace) })
          |> option.from_result
        Ok(_) | Error(Nil) -> None
      }
    _ -> None
  }
}

/// The tickets in the order a person reads them: needs-a-person stages first,
/// most urgent first, then the rest. Within a stage the newest ticket comes
/// first, and a ticket with no known age comes after those that have one.
///
/// ## Examples
///
/// ```gleam
/// // project_board.ordered(board.tickets)
/// ```
pub fn ordered(tickets: List(Ticket)) -> List(Ticket) {
  list.sort(tickets, fn(a, b) {
    case int.compare(rank(a.stage), rank(b.stage)) {
      order.Eq -> newest_first(a, b)
      other -> other
    }
  })
}

/// Splits ordered tickets into runs that share a stage word, which is what a
/// host draws as headings. A group needs a person when its stage does.
///
/// ## Examples
///
/// ```gleam
/// // project_board.groups(project_board.ordered(board.tickets))
/// ```
pub fn groups(tickets: List(Ticket)) -> List(Group) {
  list.chunk(tickets, fn(ticket) { stage_word(ticket.stage) })
  |> list.filter_map(fn(run) {
    case run {
      [first, ..] ->
        Ok(Group(
          word: stage_word(first.stage),
          needs: attention(first.stage),
          tickets: run,
        ))
      [] -> Error(Nil)
    }
  })
}

/// The tickets that need a person, in reading order.
///
/// ## Examples
///
/// ```gleam
/// // project_board.needing(board)
/// ```
pub fn needing(board: Board) -> List(Ticket) {
  ordered(board.tickets)
  |> list.filter(fn(ticket) { attention(ticket.stage) == NeedsPerson })
}

/// The one line a board shows for the tickets that need nobody: that nothing
/// needs the person, and how many tickets are in each quiet stage. When the
/// board has more tickets than the page, it says so, because the rest were not
/// read.
///
/// ## Examples
///
/// ```gleam
/// // project_board.health_words(board)
/// // "Nothing needs you. 2 working, 1 queued."
/// ```
pub fn health_words(board: Board) -> String {
  let needing = list.length(needing(board))

  // The first sentence is the answer to the owner's question, and it comes
  // first whether or not anything is wrong.
  let lead = case needing {
    0 -> "Nothing needs you."
    1 -> "1 ticket needs you."
    count -> int.to_string(count) <> " tickets need you."
  }

  let quiet =
    ordered(board.tickets)
    |> list.filter(fn(ticket) { attention(ticket.stage) == NeedsNobody })
    |> groups
    |> list.map(fn(group) {
      int.to_string(list.length(group.tickets)) <> " " <> group.word
    })

  // A board with no quiet tickets has nothing to count after the sentence.
  let counts = case quiet {
    [] -> ""
    _ -> " " <> string.join(quiet, ", ") <> "."
  }

  lead <> counts <> beyond_words(board)
}

/// A sentence saying how much of the project this page does not show, or
/// nothing when the page holds every ticket the board counted.
fn beyond_words(board: Board) -> String {
  let shown = list.length(board.tickets) + board.unreadable

  // The daemon's total can exceed the page, because a board is paged and a
  // client reads the first page, and the sentence says the rest was not read.
  case board.total > shown {
    True ->
      " Showing "
      <> int.to_string(shown)
      <> " of "
      <> int.to_string(board.total)
      <> " tickets."
    False -> ""
  }
}

/// A ticket's title for a row, or the words for a ticket the daemon gave none.
///
/// ## Examples
///
/// ```gleam
/// // project_board.title_words(ticket)
/// ```
pub fn title_words(ticket: Ticket) -> String {
  case ticket.title {
    Some(title) if title != "" -> title
    Some(_) | None -> "(untitled)"
  }
}

/// How long ago a ticket's opening message arrived, in the largest whole unit,
/// or a question mark when the daemon did not say. A clock that reads earlier
/// than the message is shown as `now`, never as a negative age.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.age_words(Some(0), 7_200_000) == "2h"
/// assert project_board.age_words(None, 7_200_000) == "?"
/// ```
pub fn age_words(opened_ms: Option(Int), now_ms: Int) -> String {
  // An age the daemon did not send is unknown, which is not zero seconds.
  case opened_ms {
    None -> "?"
    Some(opened) -> {
      let seconds = int.max(0, now_ms - opened) / 1000

      // The largest whole unit is shown, so a row's age is two or three
      // characters wide.
      case seconds {
        s if s < 60 -> "now"
        s if s < 3600 -> int.to_string(s / 60) <> "m"
        s if s < 86_400 -> int.to_string(s / 3600) <> "h"
        s -> int.to_string(s / 86_400) <> "d"
      }
    }
  }
}

/// When a ticket was opened, as a phrase that reads whole: `opened 5m ago`,
/// `opened just now` for the first minute, and `opened at an unknown time` when
/// the daemon did not say. A caller that joined `opened`, the age and `ago`
/// itself drew `opened now ago`.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.opened_words(Some(0), 30_000) == "opened just now"
/// assert project_board.opened_words(Some(0), 300_000) == "opened 5m ago"
/// ```
pub fn opened_words(opened_ms: Option(Int), now_ms: Int) -> String {
  case opened_ms, age_words(opened_ms, now_ms) {
    None, _ -> "opened at an unknown time"
    Some(_), "now" -> "opened just now"
    Some(_), age -> "opened " <> age <> " ago"
  }
}

/// Why the ticket was allowed, in a sentence. The words state the basis the
/// daemon recorded and nothing more; a basis this client does not know is
/// shown as the daemon's word, never guessed.
///
/// ## Examples
///
/// ```gleam
/// let mandate = project_board.Mandate("explicit", "composer", "composer", "owner", "v1")
/// assert project_board.mandate_words(Some(mandate))
///   == "You asked for it in the composer. Policy v1."
/// ```
pub fn mandate_words(mandate: Option(Mandate)) -> String {
  case mandate {
    None -> "The daemon did not say why this ticket was allowed."
    Some(found) -> basis_words(found) <> policy_words(found)
  }
}

/// The words for a refused `projects.answer`, given the daemon's error code.
/// A stale answer says that the question changed and that nothing was
/// recorded, because that is the one refusal a person caused by being slow.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.answer_refusal_words("conflict")
///   == "The question changed while you were typing. Nothing was recorded; read the new question and answer again."
/// ```
pub fn answer_refusal_words(code: String) -> String {
  case code {
    "conflict" ->
      "The question changed while you were typing. Nothing was recorded; read the new question and answer again."
    "not_found" -> "That ticket no longer exists."
    "forbidden" -> "Only the owner can answer a project's questions."
    _ ->
      "The daemon refused the answer ("
      <> text_hygiene.single_line(code)
      <> ")."
  }
}

/// The words for a refused close. Every code is the daemon's, so only the ones
/// a client can act on are worded, and any other is shown made safe.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.close_refusal_words("not_found")
///   == "That ticket no longer exists."
/// ```
pub fn close_refusal_words(code: String) -> String {
  case code {
    "not_found" -> "That ticket no longer exists."
    "forbidden" -> "Only the owner can close a project's ticket."
    "bad_request" ->
      "That ticket cannot be closed: it has ended or was stopped."
    _ ->
      "The daemon refused the close (" <> text_hygiene.single_line(code) <> ")."
  }
}

/// The words for a delivery state.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.delivery_words(project_board.Failed)
///   == "did not reach the worker"
/// ```
pub fn delivery_words(delivery: Delivery) -> String {
  case delivery {
    Delivered -> "delivered"
    Waiting -> "waiting for a session"
    Failed -> "did not reach the worker"
    Recorded -> "recorded, not delivered"
    UnknownDelivery(word) -> word
  }
}

// --- decoding ----------------------------------------------------------------

/// Builds a board from the fields of a body.
fn board_of(fields: List(#(String, JsonValue))) -> Result(Board, String) {
  // A board with no project or no revision cannot be compared with the one
  // already shown, so it is an error and not a board at revision zero.
  case text_in(fields, "project"), int_in(fields, "revision") {
    Some(project), Some(revision) -> {
      // A missing or malformed ticket list is an empty board, and the rows that
      // do not decode are counted below rather than dropped without a trace.
      let rows = case list.key_find(fields, "tickets") {
        Ok(json.Array(rows)) -> rows
        Ok(_) | Error(Nil) -> []
      }

      let tickets = list.filter_map(rows, ticket_row)
      Ok(Board(
        project: text_hygiene.single_line(project),
        revision:,
        total: option.lazy_unwrap(int_in(fields, "total"), fn() {
          list.length(rows)
        }),
        tickets:,
        unreadable: list.length(rows) - list.length(tickets),
        would: rows_in(fields, "would_have_done", would_row),
        rules: rules_in(fields),
      ))
    }
    None, _ -> Error("the board named no project")
    _, None -> Error("the board carried no revision")
  }
}

/// Builds a detail from the fields of a body.
fn detail_of(fields: List(#(String, JsonValue))) -> Result(Detail, String) {
  case
    text_in(fields, "project"),
    int_in(fields, "revision"),
    list.key_find(fields, "ticket")
  {
    Some(project), Some(revision), Ok(raw) ->
      case ticket_row(raw) {
        Ok(ticket) ->
          Ok(Detail(
            project: text_hygiene.single_line(project),
            revision:,
            ticket:,
            assignments: rows_in(fields, "assignments", assignment_row),
            inputs: rows_in(fields, "inputs", input_row),
          ))
        Error(Nil) -> Error("the ticket could not be addressed")
      }
    None, _, _ -> Error("the ticket named no project")
    _, None, _ -> Error("the ticket carried no revision")
    _, _, Error(Nil) -> Error("the reply carried no ticket")
  }
}

/// The rows of an array field that decode, in order. A row that does not is
/// left out.
fn rows_in(
  fields: List(#(String, JsonValue)),
  key: String,
  decode: fn(JsonValue) -> Result(row, Nil),
) -> List(row) {
  case list.key_find(fields, key) {
    Ok(json.Array(rows)) -> list.filter_map(rows, decode)
    Ok(_) | Error(Nil) -> []
  }
}

/// One ticket record. It needs an id it can address, and nothing else.
fn ticket_row(value: JsonValue) -> Result(Ticket, Nil) {
  use fields <- result.try(fields_of(value))
  use id <- result.map(addressable_id(fields))

  Ticket(
    id:,
    title: option.map(text_in(fields, "title"), text_hygiene.single_line),
    stage: stage_in(fields),
    session: option.map(text_in(fields, "session"), text_hygiene.single_line),
    mandate: mandate_in(fields),
    opened_ms: int_in(fields, "opened_ms"),
    question: question_in(fields),
    pull_request: option.map(
      text_in(fields, "pull_request"),
      text_hygiene.single_line,
    ),
    failure: option.map(text_in(fields, "failure"), text_hygiene.single_line),
    actions: actions_in(fields),
  )
}

/// The actions a ticket lists. A field that is missing or is not a list of
/// words lists none.
fn actions_in(fields: List(#(String, JsonValue))) -> List(Action) {
  case list.key_find(fields, "actions") {
    Ok(json.Array(words)) ->
      list.filter_map(words, fn(each) {
        case each {
          json.String(word) -> Ok(parse_action(word))
          json.Array(_)
          | json.Object(_)
          | json.Int(_)
          | json.Float(_)
          | json.Bool(_)
          | json.Null -> Error(Nil)
        }
      })
    Ok(_) | Error(Nil) -> []
  }
}

/// Reads an action word.
///
/// ## Examples
///
/// ```gleam
/// assert project_board.parse_action("close") == project_board.CanClose
/// ```
pub fn parse_action(word: String) -> Action {
  case word {
    "answer" -> CanAnswer
    "close" -> CanClose
    "retry" -> CanRetry
    "publish" -> CanPublish
    "stop" -> CanStop
    other -> UnknownAction(text_hygiene.single_line(other))
  }
}

/// Whether the daemon lists an action for the ticket.
///
/// ## Examples
///
/// ```gleam
/// // project_board.offers(ticket, project_board.CanClose)
/// ```
pub fn offers(ticket: Ticket, wanted: Action) -> Bool {
  list.contains(ticket.actions, wanted)
}

/// The fields of a value that is an object.
fn fields_of(value: JsonValue) -> Result(List(#(String, JsonValue)), Nil) {
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

/// The `id` of a record, when it is one this client will address.
fn addressable_id(fields: List(#(String, JsonValue))) -> Result(String, Nil) {
  case text_in(fields, "id") {
    Some(id) ->
      case addressable(id) {
        True -> Ok(id)
        False -> Error(Nil)
      }
    None -> Error(Nil)
  }
}

/// The stage of a record. A record with none has a stage no client knows, and
/// is drawn as unknown.
fn stage_in(fields: List(#(String, JsonValue))) -> Stage {
  case text_in(fields, "stage") {
    Some(word) -> parse_stage(word)
    None -> UnknownStage("")
  }
}

/// Whether an id is one this client will put in a command or an address: not
/// empty, not long, and made of the characters the daemon's own ids use.
fn addressable(id: String) -> Bool {
  id != ""
  && string.drop_start(id, id_limit) == ""
  && list.all(string.to_graphemes(id), fn(grapheme) {
    string.contains(
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:",
      grapheme,
    )
  })
}

/// The mandate of a ticket record, when it has one that is an object.
fn mandate_in(fields: List(#(String, JsonValue))) -> Option(Mandate) {
  case list.key_find(fields, "mandate") {
    Ok(json.Object(inner)) ->
      Some(Mandate(
        strength: safe_in(inner, "strength"),
        via: safe_in(inner, "via"),
        source: safe_in(inner, "source"),
        actor: safe_in(inner, "actor"),
        policy_version: safe_in(inner, "policy_version"),
      ))
    Ok(_) | Error(Nil) -> None
  }
}

/// The open question of a ticket record. A question with no usable sequence
/// number cannot be answered, so it is treated as no question.
fn question_in(fields: List(#(String, JsonValue))) -> Option(Question) {
  case list.key_find(fields, "question") {
    Ok(json.Object(inner)) ->
      option.map(int_in(inner, "seq"), fn(seq) {
        Question(
          seq:,
          text: text_hygiene.multiline(option.unwrap(text_in(inner, "text"), "")),
          options: options_in(inner),
        )
      })
    Ok(_) | Error(Nil) -> None
  }
}

/// The options a worker offered, keeping the ones that are text.
fn options_in(question: List(#(String, JsonValue))) -> List(String) {
  case list.key_find(question, "options") {
    Ok(json.Array(options)) ->
      list.filter_map(options, fn(each) {
        case each {
          json.String(word) -> Ok(text_hygiene.single_line(word))
          json.Object(_)
          | json.Array(_)
          | json.Int(_)
          | json.Float(_)
          | json.Bool(_)
          | json.Null -> Error(Nil)
        }
      })
    Ok(_) | Error(Nil) -> []
  }
}

/// One assignment row.
fn assignment_row(value: JsonValue) -> Result(Assignment, Nil) {
  case value {
    json.Object(fields) ->
      case int_in(fields, "seq") {
        Some(seq) ->
          Ok(Assignment(
            seq:,
            session: option.map(
              text_in(fields, "session"),
              text_hygiene.single_line,
            ),
            status: safe_in(fields, "status"),
          ))
        None -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The words of a "would have done" row: the rule that matched, who wrote the
/// message and where it starts. Both hosts draw this line.
///
/// ## Examples
///
/// ```gleam
/// let each = project_board.Would("gh-c-1", "ci", "alice", "CI failure", None)
/// assert project_board.would_words(each) == "ci: alice: CI failure"
/// ```
pub fn would_words(each: Would) -> String {
  each.rule <> ": " <> each.actor <> ": " <> each.text
}

/// One "would have done" row. It needs a trigger id to show, and nothing else.
fn would_row(value: JsonValue) -> Result(Would, Nil) {
  use fields <- result.try(fields_of(value))
  use trigger <- result.map(option.to_result(text_in(fields, "trigger"), Nil))
  Would(
    trigger: text_hygiene.single_line(trigger),
    rule: safe_in(fields, "rule"),
    actor: safe_in(fields, "actor"),
    text: text_hygiene.single_line(safe_in(fields, "text"))
      |> string.slice(0, would_text_limit),
    link: option.map(text_in(fields, "link"), text_hygiene.single_line),
  )
}

/// The rules of every source on the board, in the order sent. A source or a
/// rule that does not decode is left out.
fn rules_in(fields: List(#(String, JsonValue))) -> List(Rule) {
  rows_in(fields, "sources", source_rules)
  |> list.flatten
}

fn source_rules(value: JsonValue) -> Result(List(Rule), Nil) {
  use fields <- result.map(fields_of(value))
  rows_in(fields, "rules", rule_row)
}

/// One rule of a source. It needs a name to be shown, and every other field
/// has a plain default, so a daemon that sends less still draws the rule.
fn rule_row(value: JsonValue) -> Result(Rule, Nil) {
  use fields <- result.try(fields_of(value))
  use name <- result.map(option.to_result(text_in(fields, "name"), Nil))

  // The verdict object is absent from a daemon that predates it, and then the
  // rule shows no verdict rather than a guess.
  let verdict = case list.key_find(fields, "verdict") {
    Ok(json.Object(inner)) -> inner
    Ok(_) | Error(Nil) -> []
  }

  Rule(
    name: text_hygiene.single_line(name),
    mode: safe_in(fields, "mode"),
    verdict: safe_in(verdict, "state"),
    words: safe_in(verdict, "words"),
    labelled: option.unwrap(int_in(verdict, "labelled"), 0),
    needed: option.unwrap(int_in(verdict, "needed"), 0),
  )
}

/// Reads the reply of `projects.labels`.
///
/// ## Examples
///
/// ```gleam
/// let labels = project_board.decode_labels(reply)
/// ```
pub fn decode_labels(value: JsonValue) -> Result(Labels, String) {
  // A reply that is not an object, or that names no rule, cannot be filed
  // against the page being labelled.
  case value {
    json.Object(fields) ->
      case text_in(fields, "rule") {
        None -> Error("the labels named no rule")
        Some(rule) ->
          Ok(Labels(
            rule: text_hygiene.single_line(rule),
            labelled: option.unwrap(int_in(fields, "labelled"), 0),
            needed: option.unwrap(int_in(fields, "needed"), 0),
            candidates: rows_in(fields, "triggers", candidate_row),
          ))
      }
    _ -> Error("the labels were not an object")
  }
}

/// One trigger waiting for a label. It needs an id to be judged, and its text
/// is cut to one line, so a hostile message cannot take over the screen.
fn candidate_row(value: JsonValue) -> Result(Candidate, Nil) {
  use fields <- result.try(fields_of(value))
  use trigger <- result.map(option.to_result(text_in(fields, "trigger"), Nil))
  Candidate(
    trigger: text_hygiene.single_line(trigger),
    actor: safe_in(fields, "actor"),
    text: text_hygiene.single_line(safe_in(fields, "text"))
      |> string.slice(0, would_text_limit),
    recorded: safe_in(fields, "recorded"),
  )
}

/// A rule's line on the board: its name and mode, then where its verdict
/// stands and the labelled count against what is needed. The sentence a pass
/// makes is the daemon's, in `Rule.words`.
///
/// ## Examples
///
/// ```gleam
/// let each = project_board.Rule("ci", "observe", "none", "No verdict yet.", 12, 30)
/// assert project_board.rule_words(each)
///   == "ci: observe, no verdict, 12 of 30 labelled"
/// ```
pub fn rule_words(each: Rule) -> String {
  each.name
  <> ": "
  <> each.mode
  <> ", "
  <> verdict_words(each.verdict)
  <> ", "
  <> int.to_string(each.labelled)
  <> " of "
  <> int.to_string(each.needed)
  <> " labelled"
}

/// A verdict state in words. A state this client does not know is shown as the
/// daemon's word, never guessed.
fn verdict_words(state: String) -> String {
  case state {
    "none" -> "no verdict"
    "failing" -> "verdict failing"
    "stale" -> "verdict stale"
    "current" -> "verdict passing"
    other -> "verdict " <> other
  }
}

/// One input row.
fn input_row(value: JsonValue) -> Result(Input, Nil) {
  case value {
    json.Object(fields) ->
      case text_in(fields, "trigger") {
        Some(trigger) ->
          Ok(Input(
            trigger: text_hygiene.single_line(trigger),
            delivery: delivery_in(fields),
            source: option.map(
              text_in(fields, "source"),
              text_hygiene.single_line,
            ),
            actor: option.map(
              text_in(fields, "actor"),
              text_hygiene.single_line,
            ),
            text: option.map(text_in(fields, "text"), text_hygiene.multiline),
          ))
        None -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// The delivery word of an input row.
fn delivery_in(fields: List(#(String, JsonValue))) -> Delivery {
  case text_in(fields, "delivery") {
    Some("delivered") -> Delivered
    Some("waiting") -> Waiting
    Some("failed") -> Failed
    Some("recorded") -> Recorded
    Some(other) -> UnknownDelivery(text_hygiene.single_line(other))
    None -> UnknownDelivery("unknown")
  }
}

/// The id of a `projects.list` row whose workspace is the one asked for.
fn project_row(row: JsonValue, workspace: String) -> Result(String, Nil) {
  case row {
    json.Object(fields) ->
      case text_in(fields, "workspace"), text_in(fields, "id") {
        Some(found), Some(id) if found == workspace -> Ok(id)
        _, _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// A text field, or none when it is absent or not text.
fn text_in(fields: List(#(String, JsonValue)), key: String) -> Option(String) {
  case list.key_find(fields, key) {
    Ok(json.String(text)) -> Some(text)
    Ok(_) | Error(Nil) -> None
  }
}

/// A text field made safe to draw; empty when it is absent, for the fields
/// whose absence a sentence already covers.
fn safe_in(fields: List(#(String, JsonValue)), key: String) -> String {
  case text_in(fields, key) {
    Some(text) -> text_hygiene.single_line(text)
    None -> ""
  }
}

/// An integer field, or none when it is absent or not an integer.
fn int_in(fields: List(#(String, JsonValue)), key: String) -> Option(Int) {
  case list.key_find(fields, key) {
    Ok(json.Int(number)) -> Some(number)
    Ok(_) | Error(Nil) -> None
  }
}

// --- ordering ----------------------------------------------------------------

/// How urgent a stage is, lower first. The person stages follow the order of
/// the design note's table, a person stage this client does not know follows
/// the ones it does, and then the quiet stages.
fn rank(stage: Stage) -> Int {
  case stage {
    PersonDelivery -> 0
    PersonAnswer -> 1
    PersonReview -> 2
    PersonBlocked -> 3
    PersonFailed -> 4
    UnknownStage(_) ->
      case attention(stage) {
        NeedsPerson -> 5
        NeedsNobody -> 10
      }
    Queued -> 6
    Idle -> 7
    Working -> 8
    Ended(_) -> 9
  }
}

/// Newest first by the time the opening message arrived; a ticket with no
/// known time comes after those with one, and ties break on the id so the
/// order never depends on the order the daemon sent.
fn newest_first(a: Ticket, b: Ticket) -> order.Order {
  case a.opened_ms, b.opened_ms {
    Some(x), Some(y) ->
      case int.compare(y, x) {
        order.Eq -> string.compare(a.id, b.id)
        other -> other
      }
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> string.compare(a.id, b.id)
  }
}

// --- words -------------------------------------------------------------------

/// The sentence for how the mandate arose.
fn basis_words(mandate: Mandate) -> String {
  let who = named(mandate.actor, "someone")
  let place = named(mandate.source, "a source")

  // Each basis the daemon names has a sentence of its own. A basis this
  // client does not know is quoted as the daemon sent it and never guessed at.
  case mandate.via {
    "composer" -> "You asked for it in the composer."
    "addressed" -> who <> " addressed the project on " <> place <> "."
    "follow_up" -> who <> " followed up on " <> place <> "."
    "overheard" ->
      "The router inferred it from a message by "
      <> who
      <> " on "
      <> place
      <> " that was not addressed to the project."
    "automation" -> "An automation on " <> place <> " fired it."
    "rule" -> "A rule on " <> place <> " allowed it."
    "" -> "The daemon did not say how it was allowed."
    other -> "Allowed by a basis this client does not know (" <> other <> ")."
  }
}

/// The policy version, as a trailing sentence when the daemon sent one.
fn policy_words(mandate: Mandate) -> String {
  case mandate.policy_version {
    "" -> ""
    version -> " Policy " <> version <> "."
  }
}

/// A name for a sentence, or a fallback word when the daemon sent none.
fn named(name: String, fallback: String) -> String {
  case name {
    "" -> fallback
    _ -> name
  }
}
