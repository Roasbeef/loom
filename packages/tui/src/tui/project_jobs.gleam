//// The daemon requests behind the project board screen.
////
//// Each function here runs inside a weft control job (`tui/job_runner`), on the
//// terminal's borrowed control connection, and returns the outcome the shell
//// files back into the screen. They are separate from `job_runner` because
//// the board needs three small requests and one lookup, and none of them
//// touches the session catalogue.
////
//// A refusal that the screen shows in words, such as a stale answer, is an
//// outcome (`ProjectChanged` with a code) and not a job failure. A failure
//// means the request did not complete: the connection dropped, the daemon
//// timed out, or the daemon has no project table.
////
//// ## Flow
////
//// `read_board` → `read_ticket` → `change`
////
//// 1. `read_board` finds the project of a workspace through the daemon's
////    project list when it was not named, then reads its first board page.
//// 2. `read_ticket` reads one ticket with its assignments and inputs.
//// 3. `change` sends an answer or a retry and reports the daemon's refusal as
////    data.

import core/json
import gleam/option.{None, Some}
import gleam/result
import session_view/project_board
import tui/daemon
import tui/daemon/protocol as control_protocol
import tui/daemon/selection as daemon_selection
import tui/job

/// The words for a workspace with no project, which name the command that
/// makes one.
pub const no_project_words =
  "No project for this directory. Run `loom project init` here."

/// Reads a project's first board page.
///
/// ## Examples
///
/// ```gleam
/// // project_jobs.read_board(host, job.InWorkspace("/work/repo"))
/// ```
pub fn read_board(
  host: daemon_selection.Host,
  target: job.ProjectTarget,
) -> Result(job.ControlOutcome, String) {
  // A project already named by an earlier read is not looked up again; only
  // the first read of a workspace asks the daemon which project it belongs to.
  use project <- result.try(case target {
    job.ProjectId(id) -> Ok(id)
    job.InWorkspace(path) -> find_project(host, path)
  })

  use document <- result.map(
    ask(host, "projects.board", [#("project", json.String(project))]),
  )

  job.ProjectBoardLoaded(document)
}

/// Reads one ticket.
///
/// ## Examples
///
/// ```gleam
/// // project_jobs.read_ticket(host, "p1", "t-a")
/// ```
pub fn read_ticket(
  host: daemon_selection.Host,
  project: String,
  ticket: String,
) -> Result(job.ControlOutcome, String) {
  use document <- result.map(
    ask(host, "projects.ticket", [
      #("project", json.String(project)),
      #("ticket", json.String(ticket)),
    ]),
  )

  job.ProjectTicketLoaded(document)
}

/// Reads the triggers of one rule that want a label.
///
/// ## Examples
///
/// ```gleam
/// // project_jobs.read_labels(host, "p1", "ci")
/// ```
pub fn read_labels(
  host: daemon_selection.Host,
  project: String,
  rule: String,
) -> Result(job.ControlOutcome, String) {
  use document <- result.map(
    ask(host, "projects.labels", [
      #("project", json.String(project)),
      #("rule", json.String(rule)),
    ]),
  )

  job.ProjectLabelsLoaded(document)
}

/// Sends a person's change. The daemon's refusal comes back as the outcome's
/// code, and only a request that did not complete is an error.
///
/// ## Examples
///
/// ```gleam
/// // project_jobs.change(host, job.RetryTicket("p1", "t-a"))
/// ```
pub fn change(
  host: daemon_selection.Host,
  change: job.ProjectChange,
) -> Result(job.ControlOutcome, String) {
  // Each change names its wire command and carries the body that command takes.
  let #(name, fields) = case change {
    job.AnswerTicket(project:, ticket:, seq:, text:) -> #("projects.answer", [
      #("project", json.String(project)),
      #("ticket", json.String(ticket)),
      #("seq", json.Int(seq)),
      #("text", json.String(text)),
    ])
    job.CloseTicket(project:, ticket:) -> #("projects.close", [
      #("project", json.String(project)),
      #("ticket", json.String(ticket)),
    ])
    job.RetryTicket(project:, ticket:) -> #("projects.retry", [
      #("project", json.String(project)),
      #("ticket", json.String(ticket)),
    ])
    job.LabelTrigger(project:, trigger:, judgement:) -> #("projects.label", [
      #("project", json.String(project)),
      #("trigger", json.String(trigger)),
      #("label", json.String(project_board.judgement_word(judgement))),
    ])
  }

  // A refusal is an outcome the screen shows in words, such as an answer to a
  // question that has changed. Only a request that did not complete is a
  // failure of the job.
  case send(host, name, fields) {
    Ok(_) -> Ok(job.ProjectChanged(change, None))
    Error(daemon.Refused(code, _)) -> Ok(job.ProjectChanged(change, Some(code)))
    Error(other) -> Error(daemon_selection.failure(other))
  }
}

/// The project whose workspace is `path`, from the daemon's list.
fn find_project(
  host: daemon_selection.Host,
  path: String,
) -> Result(String, String) {
  use listed <- result.try(ask(host, "projects.list", []))

  project_board.project_for(listed, path)
  |> option.to_result(no_project_words)
}

/// One request, with a failure in words.
fn ask(
  host: daemon_selection.Host,
  name: String,
  fields: List(#(String, json.JsonValue)),
) -> Result(json.JsonValue, String) {
  send(host, name, fields) |> result.map_error(daemon_selection.failure)
}

/// One request, keeping the failure as the daemon reported it.
fn send(
  host: daemon_selection.Host,
  name: String,
  fields: List(#(String, json.JsonValue)),
) -> Result(json.JsonValue, daemon.Failure) {
  use reply <- result.try(daemon.request(
    daemon_selection.control(host),
    control_protocol.ProjectsCommand(name:, fields:),
    5000,
  ))

  // Every other reply belongs to another command, and each is named so that a
  // new kind of reply is a compile error here and not a silent fall-through.
  case reply {
    control_protocol.ProjectsReply(document) -> Ok(document)
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
    | control_protocol.ActivityReply(_)
    | control_protocol.UiLinkReply(..)
    | control_protocol.ShutdownReply ->
      Error(daemon.Invalid(name <> " returned an unexpected control reply"))
  }
}
