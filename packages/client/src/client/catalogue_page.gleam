//// The daemon's side of `Sessions`: one page of the catalogue, as the owner's
//// listing would show it, with the sessions another orchestrator serves left
//// out (protocol-change/085).
////
//// `sessions.elsewhere` on one orchestrator asks every other orchestrator for a
//// page of its sessions. The answering daemon reads its own catalogue and says
//// what `sessions.list` would, minus the rows the asker must not see twice. A
//// session whose custody is `moving` is mid-hand-off, and one that is `moved`
//// is only a tombstone naming its new owner; either would appear on both
//// orchestrators, so neither is listed. Archived sessions are not listed because
//// `sessions.list` does not list them.
////
//// ## How a page is read
////
//// The catalogue's own pages are cut by identity, and a cut may fall among rows
//// this module drops. The walk therefore reads catalogue pages until it holds one
//// more row than the asker wanted, or the catalogue ends. The extra row is
//// what tells `Further` from `Last`: a page that ends exactly at the end of the
//// catalogue is `Last`, and one that merely ran out of room is not. The asker
//// continues after the last row it received, so a row dropped between two pages
//// is dropped again and never shows up late.
////
//// ## What the walk gives up on
////
//// A catalogue that cannot be read is `Error(Nil)`, never an empty page, so the
//// asker reports the orchestrator as silent rather than as holding nothing. The
//// walk reads at most `ledger_holdings.max_pages` catalogue pages for one page
//// of rows. If it has read that many and holds no row, it cannot say where the
//// next row is and answers `Error(Nil)`; if it holds some, it answers them with
//// `Further`, because it did not reach the end.
////
//// ## Flow
////
//// `from_catalogue` → `walk` → `row_of`
////
//// 1. `from_catalogue` is the closure the orchestrator port runs. It reads the
////    executor table once, since a row names an executor by key and the asker
////    wants its node.
//// 2. `walk` reads catalogue pages, drops the handed-away sessions of each, and
////    stops when it has enough rows.
//// 3. `row_of` projects one registration and its live status onto a row.

import client/daemon/manager.{type Manager}
import client/executors.{type Executor}
import client/ledger_holdings
import client/listed_sessions.{type Page, type Row, Further, Last, Page, Row}
import client/roster.{type Roster}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import storage/catalogue

/// What the port answers to `Sessions`: the page of rows after an identity,
/// given as a function of the identity and the number of rows wanted.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.Reads(report:, sessions: catalogue_page.from_catalogue(registry, executors))
/// ```
pub fn from_catalogue(
  registry: Manager(instance),
  listed: Roster(Executor),
) -> fn(String, Int) -> Result(Page, Nil) {
  fn(after, limit) {
    let known = roster.rows(listed)
    walk(registry, known, after, limit, ledger_holdings.max_pages, [])
  }
}

// Reads catalogue pages from `after` until `gathered` holds `limit + 1` rows or
// the catalogue ends. `gathered` is in identity order. The extra row is dropped
// from the answer and only decides `more`.
fn walk(
  registry: Manager(instance),
  known: List(Executor),
  after: String,
  limit: Int,
  pages_left: Int,
  gathered: List(Row),
) -> Result(Page, Nil) {
  case pages_left, gathered {
    0, [] -> Error(Nil)
    0, [_, ..] -> Ok(Page(rows: list.take(gathered, limit), more: Further))
    _, _ -> {
      use #(_revision, views) <- result.try(
        manager.page(registry, after:) |> result.replace_error(Nil),
      )
      case list.last(views) {
        Error(Nil) -> Ok(Page(rows: list.take(gathered, limit), more: Last))
        Ok(last) -> {
          let ids = list.map(views, fn(view) { view.registration.id })
          use custodies <- result.try(
            manager.custodies(registry, ids) |> result.replace_error(Nil),
          )
          let kept =
            list.filter(views, fn(view) {
              served_here(custodies, view.registration.id)
            })
            |> list.map(row_of(known, _))
          let so_far = list.append(gathered, kept)
          case list.drop(so_far, limit) != [] {
            True -> Ok(Page(rows: list.take(so_far, limit), more: Further))
            False ->
              walk(
                registry,
                known,
                last.registration.id,
                limit,
                pages_left - 1,
                so_far,
              )
          }
        }
      }
    }
  }
}

// Whether this catalogue is the one that serves the session now. A session that
// is moving or has moved is also listed by, or is about to be the business of,
// another orchestrator.
fn served_here(
  custodies: List(#(String, catalogue.Custody)),
  id: String,
) -> Bool {
  case list.key_find(custodies, id) {
    Ok(catalogue.Moving(..)) | Ok(catalogue.Moved(..)) -> False
    Ok(catalogue.Resident) | Ok(catalogue.Imported(..)) | Error(Nil) -> True
  }
}

// One registration and its live status as a row. The empty text of a catalogue
// column is "none", and the executor's node comes from this daemon's own table,
// so a key it does not list leaves the node out.
fn row_of(known: List(Executor), view: manager.View) -> Row {
  let registration = view.registration
  Row(
    session_id: registration.id,
    workspace: registration.workspace,
    name: registration.name,
    created_at: registration.created_at,
    status: status_of(view.status),
    subtitle: registration.subtitle,
    executor: named(registration.executor),
    pool: named(registration.pool),
    executor_node: case executors.find(known, registration.executor) {
      Ok(executor) -> Some(executor.node)
      Error(Nil) -> None
    },
  )
}

fn named(name: String) -> Option(String) {
  case name {
    "" -> None
    present -> Some(present)
  }
}

fn status_of(status: manager.Status) -> listed_sessions.ListedStatus {
  case status {
    manager.Reserved -> listed_sessions.Reserved
    manager.Saved -> listed_sessions.Saved
    manager.Opening(operation:) -> listed_sessions.Opening(operation:)
    manager.Resident(incarnation:) -> listed_sessions.Resident(incarnation:)
    manager.Stopping(operation:) -> listed_sessions.Stopping(operation:)
    manager.RecoveryBlocked(..) -> listed_sessions.RecoveryBlocked
  }
}
