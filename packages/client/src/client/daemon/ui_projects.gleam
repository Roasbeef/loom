//// The project reads and the answer behind the owner's home page
//// (protocol-change/106, the addendum on the web view).
////
//// The home page draws a Projects section and a ticket page. Their facts are
//// the ones the `projects.*` control commands serve, from the same actors, so a
//// ticket reads the same on the web page and in the terminal. This module is
//// the daemon's side of three page reads: every project's first board page, one
//// ticket, and an answer to a ticket's question. It returns the daemon's JSON
//// untouched, because decoding, ordering and wording belong to
//// `session_view/project_board`, which both surfaces share.
////
//// Nothing here decides who may ask. The socket hands a page this feed only when
//// the page is the owner's and was minted to operate
//// (`ui_socket.home_projects_capability`), and each read repeats the owner check
//// before it asks an actor (`ui_socket.projects_for`). A daemon that started no
//// project table has no feed at all, and its pages draw no section.
////
//// The board body is built here once, and the `projects.board` control command
//// uses the same function, so the two cannot drift apart.
////
//// ## Flow
////
//// `feed` → `boards` → `ticket_of` → `answered` → `closed` → `acted` → `proposal_for` → `made`
////
//// 1. `feed` is the daemon's offer to a page, or nothing when there is no
////    project table.
//// 2. `boards` reads each running project's first page, building each body
////    with `board_body`.
//// 3. `ticket_of` reads one ticket, and `answered`, `closed` and `acted` record
////    an answer, a close, and a stop or a retry, all named by ids the page took
////    from a board it holds.

import client/daemon/project_book
import client/daemon/project_host
import client/daemon/project_settings_wire
import client/daemon/project_start
import client/project_overrides
import client/project_proposal
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import web_view/creations
import web_view/projects

/// What the daemon reads and does for a page's projects.
pub type Feed {
  Feed(
    /// Every running project's first board page.
    boards: fn() -> projects.Read,
    /// One ticket of a project.
    ticket: fn(String, String) -> projects.TicketRead,
    /// An answer to a ticket's question, echoing the question's sequence number.
    answer: fn(String, String, Int, String) -> projects.Answer,
    /// A close of a ticket whose work the owner accepted.
    close: fn(String, String) -> projects.Closing,
    /// A stop of a ticket, which withdraws its mandate.
    stop: fn(String, String) -> projects.Acted,
    /// A request for a new worker on a stalled ticket.
    retry: fn(String, String) -> projects.Acted,
    /// The proposal for a folder the socket has already judged: what the table
    /// in `project_proposal` reads from the folder's own files. Nothing runs.
    propose: fn(String) -> projects.Proposal,
    /// A project for a folder the socket has already judged, with the check and
    /// setup the owner confirmed. A folder that has a project keeps it.
    create: fn(String, Option(String), Option(String)) -> projects.Creation,
    /// A project's settings in force.
    settings: fn(String) -> projects.SettingsRead,
    /// A change to a project's own settings at the revision the page read, with
    /// the URL the page named when it turns publishing on.
    set_settings: fn(
      String,
      Int,
      List(#(String, Option(List(String)))),
      Option(String),
    ) -> projects.SettingsWrite,
    /// The owner's request as an explicit trigger, keyed by a request id.
    post: fn(String, String, String) -> projects.Posted,
  )
}

/// The feed over a daemon's project table, or nothing when the daemon started
/// none.
///
/// ## Examples
///
/// ```gleam
/// assert ui_projects.feed(None) == None
/// ```
pub fn feed(control: Option(project_start.Control)) -> Option(Feed) {
  option.map(control, fn(held) {
    Feed(
      boards: fn() { boards(held) },
      ticket: fn(project, ticket) { ticket_of(held, project, ticket) },
      answer: fn(project, ticket, seq, text) {
        answered(held, project, ticket, seq, text)
      },
      close: fn(project, ticket) { closed(held, project, ticket) },
      stop: fn(project, ticket) {
        acted(held, project, ticket, project_host.stop_ticket)
      },
      retry: fn(project, ticket) {
        acted(held, project, ticket, project_host.retry)
      },
      settings: fn(project) { settings_of(held, project) },
      set_settings: fn(project, revision, changes, publish_to) {
        settings_written(held, project, revision, changes, publish_to)
      },
      post: fn(project, request, text) { posted(held, project, request, text) },
      propose: proposal_for,
      create: fn(workspace, check, setup) {
        made(held, workspace, check, setup)
      },
    )
  })
}

/// The `projects.board` reply body: the project, the ledger's newest sequence
/// number as `revision`, the page, the total, the tickets and the router's
/// queued replies. The control command and the page read the same body.
///
/// ## Examples
///
/// ```gleam
/// // ui_projects.board_body("p1", shown)
/// ```
pub fn board_body(project: String, shown: project_host.Board) -> JsonValue {
  json.Object([
    #("project", json.String(project)),
    #("revision", json.Int(shown.revision)),
    #("page", json.Int(shown.page)),
    #("total", json.Int(shown.total)),
    #("tickets", json.Array(shown.tickets)),
    #("replies", json.Array(shown.replies)),
    #("unrouted", json.Array(shown.unrouted)),
    #("would_have_done", json.Array(shown.would_have_done)),
    #("sources", json.Array(shown.sources)),
    #("decisions", json.Array(shown.decisions)),
    #("router", shown.router),
  ])
}

/// Every running project and its first page. A project whose actor does not
/// answer is left out of this read, and the page keeps what it last drew for it.
fn boards(control: project_start.Control) -> projects.Read {
  project_book.all(control.book)
  |> list.filter_map(fn(handle) {
    project_host.board(handle, 0)
    |> result.map(fn(shown) {
      projects.Listed(
        id: handle.project,
        workspace: handle.workspace,
        router_session: handle.router_session,
        board: board_body(handle.project, shown),
      )
    })
  })
  |> projects.Heard
}

/// One ticket, or why there is none.
fn ticket_of(
  control: project_start.Control,
  project: String,
  ticket: String,
) -> projects.TicketRead {
  case project_book.get(control.book, project) {
    Error(Nil) -> projects.TicketGone
    Ok(handle) ->
      case project_host.ticket(handle, ticket) {
        Ok(detail) -> projects.TicketHeard(detail)
        Error(Nil) -> projects.TicketGone
      }
  }
}

/// The actor's word on a close, as the page needs it: closed, or refused with
/// the code the control command would answer.
fn closed(
  control: project_start.Control,
  project: String,
  ticket: String,
) -> projects.Closing {
  case project_book.get(control.book, project) {
    Error(Nil) -> projects.NotClosed("not_found")
    Ok(handle) -> closing_of(project_host.close_ticket(handle, ticket, "owner"))
  }
}

/// The page's word for a close the actor judged. Silence is not a refusal: the
/// queued close may still commit, so a timeout is its own code and the page
/// says to read again.
///
/// ## Examples
///
/// ```gleam
/// assert ui_projects.closing_of(Error(project_host.not_answering))
///   == projects.NotClosed("unanswered")
/// ```
pub fn closing_of(settled: Result(Nil, String)) -> projects.Closing {
  case settled {
    Ok(Nil) -> projects.Closed
    Error(reason) if reason == project_host.not_answering ->
      projects.NotClosed("unanswered")
    Error(_) -> projects.NotClosed("bad_request")
  }
}

/// The actor's word on a stop or a retry, which take the same arguments and
/// answer the same way, as the page needs it: done, or refused with the code
/// the control command would answer.
fn acted(
  control: project_start.Control,
  project: String,
  ticket: String,
  act: fn(project_host.Handle, String, String) -> Result(Nil, String),
) -> projects.Acted {
  case project_book.get(control.book, project) {
    Error(Nil) -> projects.Declined("not_found")
    Ok(handle) -> acted_of(act(handle, ticket, "owner"))
  }
}

/// The page's word for a stop or a retry the actor judged. Silence is not a
/// refusal: the queued act may still commit, so a timeout is its own code and
/// the page says to read again.
///
/// ## Examples
///
/// ```gleam
/// assert ui_projects.acted_of(Error(project_host.not_answering))
///   == projects.Declined("unanswered")
/// ```
pub fn acted_of(settled: Result(Nil, String)) -> projects.Acted {
  case settled {
    Ok(Nil) -> projects.Acted
    Error(reason) if reason == project_host.not_answering ->
      projects.Declined("unanswered")
    Error(_) -> projects.Declined("bad_request")
  }
}

/// The actor's word on an answer, as the page needs it: recorded, or refused
/// with the code the control command would answer, so a stale answer is
/// `conflict` on both surfaces.
fn answered(
  control: project_start.Control,
  project: String,
  ticket: String,
  seq: Int,
  text: String,
) -> projects.Answer {
  case project_book.get(control.book, project) {
    Error(Nil) -> projects.Refused("not_found")
    Ok(handle) ->
      answer_of(project_host.answer(handle, ticket, seq, text, "owner"))
  }
}

/// The page's word for an answer the actor judged. A timeout is its own code,
/// since the queued answer may still be recorded.
///
/// ## Examples
///
/// ```gleam
/// assert ui_projects.answer_of(Error(project_host.NotAccepted(project_host.not_answering)))
///   == projects.Refused("unanswered")
/// ```
pub fn answer_of(
  settled: Result(Nil, project_host.AnswerFailure),
) -> projects.Answer {
  case settled {
    Ok(Nil) -> projects.Recorded
    Error(project_host.NoSuchTicket) -> projects.Refused("not_found")
    Error(project_host.StaleQuestion) -> projects.Refused("conflict")
    Error(project_host.NotAccepted(reason:))
      if reason == project_host.not_answering
    -> projects.Refused("unanswered")
    Error(project_host.NotAccepted(..)) -> projects.Refused("bad_request")
  }
}

/// The proposal for a folder, as the `projects.propose` command words it for a
/// project's workspace. The folder was judged by the socket, which is the one
/// place that decides which folders the owner's page may name.
fn proposal_for(workspace: String) -> projects.Proposal {
  project_proposal.read(workspace)
  |> project_proposal.propose
  |> project_settings_wire.proposals_json("", _)
  |> projects.Proposed
}

/// The project for a folder, and then the settings the owner confirmed. A folder
/// that already has a running project is reported as it is, with nothing made
/// and nothing written, because the commands the owner confirmed were proposed
/// for a new project and must not replace the ones a project already holds.
/// Otherwise the two are separate writes, as they are for `loom project init`,
/// so the project is reported as made when its settings were refused, with the
/// daemon's words. The name is the folder's, which is what the catalogue lists
/// the project by.
fn made(
  control: project_start.Control,
  workspace: String,
  check: Option(String),
  setup: Option(String),
) -> projects.Creation {
  let held =
    list.find(project_book.all(control.book), fn(handle) {
      handle.workspace == workspace
    })

  // A running project for the folder is reported and left alone; any other
  // folder is made, and only then are its confirmed commands stored.
  case held {
    Ok(handle) -> projects.Existing(handle.project)
    Error(Nil) ->
      // The control makes the project, or refuses in its own words.
      case control.create(workspace, creations.folder(workspace)) {
        Error(words) -> projects.MakeFailed(words)
        Ok(created) ->
          projects.Made(
            project: created.project,
            settled: settled(control, created.project, check, setup),
          )
      }
  }
}

/// Stores the confirmed commands for a project that now exists. Nothing
/// confirmed stores nothing. The revision is the one read just now, and a write
/// that finds it moved is refused as stale and reported in words.
fn settled(
  control: project_start.Control,
  project: String,
  check: Option(String),
  setup: Option(String),
) -> projects.Settled {
  let wanted =
    list.filter_map(
      [
        #(project_overrides.CheckKey, check),
        #(project_overrides.SetupKey, setup),
      ],
      fn(each) {
        option.to_result(each.1, Nil)
        |> result.map(fn(text) { #(each.0, text) })
      },
    )

  // Each command is checked by the rules the file is checked by, so the words
  // of a refusal are the file's.
  case
    list.try_map(wanted, fn(each) {
      project_overrides.parse(each.0, [each.1])
      |> result.map(project_overrides.Hold)
    })
  {
    Error(words) -> projects.SettingsRefused(words)
    Ok([]) -> projects.SettingsHeld
    Ok(changes) ->
      case store(control, project, changes) {
        Ok(Nil) -> projects.SettingsHeld
        Error(words) -> projects.SettingsRefused(words)
      }
  }
}

/// The write of the changes at the revision the project has now.
fn store(
  control: project_start.Control,
  project: String,
  changes: List(project_overrides.Change),
) -> Result(Nil, String) {
  use handle <- result.try(
    project_book.get(control.book, project)
    |> result.replace_error("the project is not running"),
  )
  use read <- result.try(project_host.settings(handle))
  project_host.change_settings(handle, read.revision, changes, None, "owner")
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(failure) {
    case failure {
      project_host.StaleSettings ->
        "the settings changed while the project was being made"
      project_host.RefusedSettings(words:) -> words
    }
  })
}

/// The settings in force, as `projects.settings` replies them.
fn settings_of(
  control: project_start.Control,
  project: String,
) -> projects.SettingsRead {
  let read = {
    use handle <- result.try(
      project_book.get(control.book, project) |> result.replace_error(Nil),
    )
    project_host.settings(handle) |> result.replace_error(Nil)
  }

  // The read answers with the daemon's body, or says it could not read.
  case read {
    Ok(view) ->
      projects.SettingsHeard(project_settings_wire.view_json(project, view))
    Error(Nil) -> projects.SettingsUnread
  }
}

/// A change to the project's own settings, as `projects.set_settings` takes it:
/// each value is checked by the rules the file is checked by, a stale revision
/// is `conflict`, and turning publishing on without naming its URL is refused
/// with the sentence that states the URL. A key with no words is given back to
/// `loom.toml`.
fn settings_written(
  control: project_start.Control,
  project: String,
  revision: Int,
  changes: List(#(String, Option(List(String)))),
  publish_to: Option(String),
) -> projects.SettingsWrite {
  case project_book.get(control.book, project) {
    Error(Nil) ->
      projects.SettingsDeclined("not_found", "That project is gone.")
    Ok(handle) ->
      case list.try_map(changes, setting_change) {
        Error(words) -> projects.SettingsDeclined("bad_request", words)
        Ok(parsed) ->
          case
            project_host.change_settings(
              handle,
              revision,
              parsed,
              publish_to,
              "owner",
            )
          {
            Ok(view) ->
              projects.SettingsStored(project_settings_wire.view_json(
                project,
                view,
              ))
            Error(project_host.StaleSettings) ->
              projects.SettingsDeclined(
                "conflict",
                "The settings changed since you read them. They are read again.",
              )
            Error(project_host.RefusedSettings(words:)) ->
              projects.SettingsDeclined("bad_request", words)
          }
      }
  }
}

/// One requested change as the settings code takes it, checked by the file's
/// own rules so the refusal is the file's.
fn setting_change(
  change: #(String, Option(List(String))),
) -> Result(project_overrides.Change, String) {
  use key <- result.try(project_overrides.key_from_word(change.0))

  // No words is a release, and words must pass the file's rules.
  case change.1 {
    None -> Ok(project_overrides.Release(key))
    Some(words) ->
      project_overrides.parse(key, words) |> result.map(project_overrides.Hold)
  }
}

/// The owner's request from the composer, recorded as an explicit trigger. The
/// request id is the idempotency key, so a repeat of one is `Reposted`.
fn posted(
  control: project_start.Control,
  project: String,
  request: String,
  text: String,
) -> projects.Posted {
  case project_book.get(control.book, project) {
    Error(Nil) -> projects.NotPosted("not_found")
    Ok(handle) ->
      case project_host.post(handle, request, text) {
        Ok(project_host.Posted(trigger)) -> projects.Posted(trigger)
        Ok(project_host.Repeated(trigger)) -> projects.Reposted(trigger)
        Error(_) -> projects.NotPosted("bad_request")
      }
  }
}
