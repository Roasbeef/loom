//// The sessions the operator's other orchestrators list, asked of them from this
//// one (protocol-change/085, the `sessions.elsewhere` control command).
////
//// A session is created on, and owned by, the orchestrator its client was
//// connected to. An operator with two orchestrators sees one daemon's sessions
//// in each client and has no way to tell that a session they cannot find is on
//// the other. This module is the read that answers it: it asks each configured
//// orchestrator for a page of what it would list to its own owner, and puts the
//// answers side by side with the orchestrator that gave each.
////
//// ## What a group says
////
//// Each configured orchestrator is a group. A group is `answered` with up to
//// `rows_per_group` rows and whether more follow, or `silent`. Silent means this
//// daemon did not hear a page from it, whether because it could not connect,
//// because the orchestrator did not answer in time, or because its catalogue could
//// not be read. It never means the orchestrator holds nothing; an orchestrator
//// that holds nothing answers an empty page. A silent group is one line in the
//// reply and in every client, and the next ask connects again.
////
//// ## The one rule about names
////
//// The daemon connects only to the orchestrators of its own configuration. The
//// request's `orchestrator` is a key of that table, resolved by `choose` before
//// anything is dialled, so a key that names nothing connects to nobody and the
//// command answers `not_found`. There is no cursor across groups: a client that
//// wants a group's next page names the group and the identity its last row had.
////
//// ## The bound on a reply
////
//// The terminal refuses a frame over 64 KiB, so the reply is kept at or under
//// `max_reply_bytes`, the bound `sessions.list` uses. When the rows would pass it
//// `fit` removes the last row of whichever group has the most, one at a time, so
//// a group with many long names does not leave the others empty. A group that
//// lost a row says it has `more`, because its next page begins after the last row
//// it shows.
////
//// ## Flow
////
//// `read` → `heard` → `choose` → `ask_all` → `fit` → `to_json`
////
//// 1. `read` is the whole command: it takes what `heard` gathered and renders
////    it. The owner's home calls `heard` itself and hands `for_page` the groups.
//// 2. `choose` resolves the request against the configured orchestrators.
//// 3. `ask_all` runs one weft run in which each chosen orchestrator is connected
////    to, for at most one second, and then asked, for at most one more, under a
////    three second deadline. Outcomes come back in the order of the groups.
//// 4. `fit` removes rows until the rendered reply is within its bound.
//// 5. `to_json` renders the groups as the body of the reply.

import client/deployment.{type Reach}
import client/listed_sessions.{type Page, Further, Last, Page}
import client/orchestrators.{type Orchestrator}
import core/json.{type JsonValue}
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import web_view/elsewhere as page
import weft

/// The most rows one group shows in one reply.
pub const rows_per_group = 20

/// How long one orchestrator is given to answer once connected.
pub const ask_ms = 1000

/// The bound on the whole fan-out. The two inner bounds sum to two seconds, so
/// the difference is slack for scheduling and not a sum.
pub const deadline_ms = 3000

/// The most bytes of the reply's body, which with its envelope stays under the
/// 60,000 bytes that `sessions.list` also keeps to.
pub const max_body_bytes = 59_700

/// What this daemon heard from one orchestrator.
pub type Heard {
  /// A page arrived.
  Answered(page: Page)

  /// Nothing arrived in time, or what arrived was a failed catalogue read.
  Silent
}

/// One configured orchestrator and what it said.
pub type Group {
  Group(
    /// The orchestrator, as this daemon's configuration names it.
    orchestrator: Orchestrator,
    /// What it said.
    heard: Heard,
  )
}

/// Asks the orchestrators the request chooses and renders what they say.
/// `orchestrator` is the configuration key of one group, with `after` the identity
/// its last shown row had; with neither, every group is asked for its first page.
/// `Error(Nil)` means the key names no configured orchestrator, and nothing was
/// dialled.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere.read(reach, [], Some("ghost"), None) == Error(Nil)
/// ```
pub fn read(
  reach: Reach,
  configured: List(Orchestrator),
  orchestrator: Option(String),
  after: Option(String),
) -> Result(JsonValue, Nil) {
  heard(reach, configured, orchestrator, after)
  |> result.map(fit(_, max_body_bytes))
  |> result.map(to_json)
}

/// The groups a request is about and what each said, before they are fitted to
/// a reply. The owner's home reads them this way, since a page keeps its own
/// bound on rows.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere.heard(reach, [], Some("ghost"), None) == Error(Nil)
/// ```
pub fn heard(
  reach: Reach,
  configured: List(Orchestrator),
  orchestrator: Option(String),
  after: Option(String),
) -> Result(List(Group), Nil) {
  use chosen <- result.map(choose(configured, orchestrator))
  ask_all(reach, chosen, option.unwrap(after, ""))
}

/// The groups as the owner's home may know them (`web_view/elsewhere`): the
/// configuration key, the address, and for each row the fixed state and the
/// text the home draws. The node of an orchestrator, and the node of an
/// executor, stay with the daemon, since nothing on the page uses them.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere.for_page([]) == page.Heard([])
/// ```
pub fn for_page(groups: List(Group)) -> page.Read {
  page.Heard(
    list.map(groups, fn(group) {
      page.Group(
        name: group.orchestrator.name,
        address: group.orchestrator.address,
        hearing: case group.heard {
          Silent -> page.Silent
          Answered(Page(rows:, more:)) ->
            page.Answered(rows: list.map(rows, page_row), more: case more {
              Further -> page.Further
              Last -> page.Last
            })
        },
      )
    }),
  )
}

fn page_row(row: listed_sessions.Row) -> page.Row {
  page.Row(
    session_id: row.session_id,
    workspace: row.workspace,
    name: row.name,
    status: case row.status {
      listed_sessions.Reserved -> page.Reserved
      listed_sessions.Saved -> page.Saved
      listed_sessions.Opening(..) -> page.Opening
      listed_sessions.Resident(..) -> page.Resident
      listed_sessions.Stopping(..) -> page.Stopping
      listed_sessions.RecoveryBlocked -> page.Blocked
    },
    executor: row.executor,
  )
}

/// The orchestrators a request is about: all of them, or the one whose key it
/// names. A key is looked up among the configured orchestrators and never turned
/// into a node name.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere.choose([], None) == Ok([])
/// assert elsewhere.choose([], Some("ghost")) == Error(Nil)
/// ```
pub fn choose(
  configured: List(Orchestrator),
  orchestrator: Option(String),
) -> Result(List(Orchestrator), Nil) {
  case orchestrator {
    None -> Ok(configured)
    Some(key) ->
      case list.filter(configured, fn(each) { each.name == key }) {
        [] -> Error(Nil)
        found -> Ok(found)
      }
  }
}

/// Connects to every chosen orchestrator at once, asks each connected one for a
/// page after `after`, and returns what each said in the order given.
///
/// The asks run in one weft run so that a slow orchestrator costs the reply at
/// most `deadline_ms`, and the run's deadline kills and joins any ask still
/// waiting. A task the deadline cut off, one that crashed and one that never
/// started told the daemon nothing, so each is `Silent` and not an empty page.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere.ask_all(deployment.alone("a@b"), [], "") == []
/// ```
pub fn ask_all(
  reach: Reach,
  chosen: List(Orchestrator),
  after: String,
) -> List(Group) {
  use <- bool.guard(when: chosen == [], return: [])
  chosen
  |> list.map(fn(each) {
    let node = each.node
    fn() {
      use Nil <- result.try(
        reach.dial(node, deployment.connect_ms) |> result.replace_error(Nil),
      )
      reach.sessions(node, after, rows_per_group, ask_ms)
    }
  })
  |> weft.new
  |> weft.limit(list.length(chosen))
  |> weft.deadline(deadline_ms)
  |> weft.start
  |> list.map2(chosen, fn(outcome, each) {
    Group(orchestrator: each, heard: hearing(outcome))
  })
}

fn hearing(outcome: weft.Outcome(Page, Nil)) -> Heard {
  case outcome {
    weft.Completed(value:, ..) -> Answered(bounded(value))
    weft.Failed(..)
    | weft.Crashed(..)
    | weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) -> Silent
  }
}

// A peer is asked for `rows_per_group` rows but is another daemon's code, so a
// page with more is cut to that many and marked as having more, which keeps the
// fit below it linear in a bounded number of rows.
fn bounded(page: Page) -> Page {
  case list.drop(page.rows, rows_per_group) {
    [] -> page
    [_, ..] -> Page(rows: list.take(page.rows, rows_per_group), more: Further)
  }
}

/// Removes rows until the body of the reply is no larger than `budget` bytes.
/// Each step removes the last row of the answered group with the most rows (the
/// later group when two tie) and marks that group as having more. A reply that
/// already fits is returned unchanged, and so is one with no rows left to remove.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere.fit([], 100) == []
/// ```
pub fn fit(groups: List(Group), budget: Int) -> List(Group) {
  let size = json.to_string(to_json(groups)) |> string.byte_size
  use <- bool.guard(when: size <= budget, return: groups)
  case fullest(groups) {
    Error(Nil) -> groups
    Ok(index) -> fit(shorten(groups, index), budget)
  }
}

// The index of the answered group with the most rows, the later one on a tie,
// or `Error(Nil)` when no group has a row.
fn fullest(groups: List(Group)) -> Result(Int, Nil) {
  list.index_map(groups, fn(group, index) { #(index, rows_in(group)) })
  |> list.filter(fn(entry) { entry.1 > 0 })
  |> list.fold(Error(Nil), fn(best, entry) {
    case best {
      Ok(#(_, most)) if entry.1 < most -> best
      Ok(_) | Error(Nil) -> Ok(entry)
    }
  })
  |> result.map(fn(best) { best.0 })
}

fn rows_in(group: Group) -> Int {
  case group.heard {
    Answered(Page(rows:, ..)) -> list.length(rows)
    Silent -> 0
  }
}

fn shorten(groups: List(Group), index: Int) -> List(Group) {
  list.index_map(groups, fn(group, at) {
    case at == index, group.heard {
      True, Answered(Page(rows:, ..)) ->
        Group(
          ..group,
          heard: Answered(Page(
            rows: list.take(rows, list.length(rows) - 1),
            more: Further,
          )),
        )
      True, Silent | False, _ -> group
    }
  })
}

/// Renders the groups as the body of a `sessions.elsewhere` reply. A group has
/// its configuration `name`, its `node`, `state` (`answered` or `silent`), the
/// `address` when its configuration has one, `more`, and its `sessions`. A
/// silent group has no sessions and no more.
///
/// ## Examples
///
/// ```gleam
/// assert elsewhere.to_json([]) == json.Object([#("orchestrators", json.Array([]))])
/// ```
pub fn to_json(groups: List(Group)) -> JsonValue {
  json.Object([#("orchestrators", json.Array(list.map(groups, group_json)))])
}

fn group_json(group: Group) -> JsonValue {
  let each = group.orchestrator
  let address = case each.address {
    Some(text) -> [#("address", json.String(text))]
    None -> []
  }
  let #(state, page) = case group.heard {
    Answered(page:) -> #("answered", page)
    Silent -> #("silent", Page(rows: [], more: Last))
  }
  json.Object(
    list.flatten([
      [
        #("name", json.String(each.name)),
        #("node", json.String(each.node)),
        #("state", json.String(state)),
      ],
      address,
      [
        #("more", json.Bool(page.more == Further)),
        #("sessions", json.Array(list.map(page.rows, listed_sessions.row_json))),
      ],
    ]),
  )
}
