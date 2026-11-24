//// The daemon requests behind the ask card.
////
//// Each function here runs inside a weft job (`tui/job_runner`) and returns
//// the outcome that `tui/ask_control` files into the board. `answer` runs on
//// the terminal's borrowed control connection, because the owner starts it.
//// `read_asks` is a poll, so the runner gives it a connection of its own and
//// closes it afterwards. These follow `tui/project_jobs`: a
//// refusal that the card shows in words is an outcome, and only a request that
//// did not complete is a failure of the job.
////
//// ## Flow
////
//// `read_asks` → `answer` → `send` → `ask`
////
//// 1. `read_asks` reads the session's attention feed row (the
////    sessions.attention command, protocol-change/120) and then reads in full,
////    with attention.read, the first asks the row lists. The row is cut to fit
////    a frame, so the reads give the questions, the options and the revision
////    an answer must name.
//// 2. `answer` sends the owner's answer with that revision (attention.answer,
////    protocol-change/128) through `send`, and reports the daemon's refusal as
////    data.
//// 3. `ask` is `send` for a request whose failure is only a sentence.
////
//// ## Why the feed and the reads are one job
////
//// The board polls on a tick. One job that makes the three requests in turn
//// finishes in a fraction of a second on its own connection and then rests,
//// where three jobs would each wait for a tick. The borrowed connection has one
//// outstanding request, which the picker and the peer and access screens wait
//// on, so a poll never uses it.

import core/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tui/ask_board
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/job

/// Reads a session's open asks: how many the feed counts for the owner, and the
/// first of them in full.
///
/// An ask that was answered or removed between the feed and its read is
/// refused `not_found` and is left out; the count still includes it until the
/// next read. Any other failure of a read fails the job, so the board keeps
/// what it drew, drafts included, and rests, rather than dropping an ask the
/// daemon still holds.
///
/// ## Examples
///
/// ```gleam
/// // ask_jobs.read_asks(host, "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn read_asks(
  host: daemon_selection.Host,
  session: String,
) -> Result(job.AsksRead, String) {
  use document <- result.try(ask(
    host,
    control_protocol.ReadAttentionFeed(session),
  ))
  use feed <- result.try(ask_board.decode_feed(document, session))
  use read <- result.map(
    feed.ids
    |> list.take(ask_board.drawn_limit)
    |> list.try_map(fn(id) {
      read_one(host, control_protocol.ReadAttentionRecord(session, id))
    }),
  )

  job.AsksRead(session:, count: feed.count, records: option.values(read))
}

/// One ask read in full: its document, or nothing when the daemon says the ask
/// is gone, or the failure in words.
fn read_one(
  host: daemon_selection.Host,
  request: control_protocol.AttentionRequest,
) -> Result(Option(json.JsonValue), String) {
  // Only a refusal that names the ask as absent is an omission.
  case send(host, request) {
    Ok(document) -> Ok(Some(document))
    Error(daemon.Refused("not_found", _)) -> Ok(None)
    Error(other) -> Error(daemon_selection.failure(other))
  }
}

/// Sends the owner's answer. The daemon's refusal comes back as the outcome,
/// and only a request that did not complete is an error.
///
/// ## Examples
///
/// ```gleam
/// // ask_jobs.answer(host, "0198c0de-0000-7000-8000-000000000001", "ask-3f9c01a2b4", 41, answer)
/// ```
pub fn answer(
  host: daemon_selection.Host,
  session: String,
  ask_id: String,
  revision: Int,
  answer: json.JsonValue,
) -> Result(job.ControlOutcome, String) {
  let request =
    control_protocol.AnswerAttentionAsk(
      session:,
      ask: ask_id,
      revision:,
      answer:,
    )

  // A refusal is the daemon's decision and the card words it; a request that
  // did not complete is a failure the person is told about elsewhere.
  case send(host, request) {
    Ok(document) ->
      Ok(job.AskAnswered(session, ask_id, Ok(delivery_of(document))))
    Error(daemon.Refused(code, message)) ->
      Ok(job.AskAnswered(
        session,
        ask_id,
        Error(job.AskRefusal(code:, message:)),
      ))
    Error(other) -> Error(daemon_selection.failure(other))
  }
}

/// The way the strand took the prompt, `admitted` or `queued`, or nothing when
/// the reply does not say.
fn delivery_of(document: json.JsonValue) -> String {
  case document {
    json.Object(fields) ->
      case list.key_find(fields, "delivery") {
        Ok(json.String(word)) -> word
        Ok(_) | Error(Nil) -> ""
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> ""
  }
}

/// One request, with a failure in words.
fn ask(
  host: daemon_selection.Host,
  request: control_protocol.AttentionRequest,
) -> Result(json.JsonValue, String) {
  send(host, request) |> result.map_error(daemon_selection.failure)
}

/// One request, keeping the failure as the daemon reported it.
fn send(
  host: daemon_selection.Host,
  request: control_protocol.AttentionRequest,
) -> Result(json.JsonValue, daemon.Failure) {
  use reply <- result.try(daemon.request(
    daemon_selection.control(host),
    control_protocol.AttentionCommand(request),
    5000,
  ))

  // Every other reply belongs to another command, and each is named so that a
  // new kind of reply is a compile error here and not a silent fall-through.
  case reply {
    control_protocol.AttentionReply(document) -> Ok(document)
    control_protocol.StatusReply(_)
    | control_protocol.SessionsReply(_)
    | control_protocol.SessionReply(_)
    | control_protocol.LifecycleReply(_)
    | control_protocol.DeletedReply(_)
    | control_protocol.MovedReply(..)
    | control_protocol.AbandonedReply(..)
    | control_protocol.PeersInspectionReply(_)
    | control_protocol.PeersMutationReply(_)
    | control_protocol.AccessListingReply(_)
    | control_protocol.AccessChangeReply(_)
    | control_protocol.DeploymentReply(_)
    | control_protocol.DirectoryReply(_)
    | control_protocol.ElsewhereReply(_)
    | control_protocol.ProjectsReply(_)
    | control_protocol.ActivityReply(_)
    | control_protocol.UiLinkReply(..)
    | control_protocol.ShutdownReply ->
      Error(daemon.Invalid(
        control_protocol.name(control_protocol.AttentionCommand(request))
        <> " returned an unexpected control reply",
      ))
  }
}
