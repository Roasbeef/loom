//// The sessions one orchestrator lists to its own owner, as plain data
//// (protocol-change/085, the orchestrator port's `Sessions`).
////
//// An operator who runs several orchestrators sees only the sessions of the
//// one daemon the client is connected to. `sessions.elsewhere` asks each of the
//// others for a page of what it would list, and this module is the vocabulary
//// the question and the answer share: a `Row` is one session's metadata, a
//// `Page` is some rows and whether more follow.
////
//// ## Why this is a module of its own
////
//// The orchestrator port carries a `Page` between two daemons as a term, and the
//// control reply renders it to JSON for a client. Both the port and the
//// daemon's read import these types, and neither may import the other, so they
//// sit below both. The module is pure: it holds no catalogue and no connection,
//// and the daemon builds rows from its own registry where the registry is.
////
//// ## What a row is
////
//// A row has the members of a `sessions.list` record, in the same meaning, and
//// renders to the same JSON, so a client reads a foreign row with the decoder it
//// has for a local one. It adds one optional member, `executor_node`: the
//// `executor` of a row is a key of the answering daemon's own `[executors]`
//// table, and a reader that wants to attribute the row to a machine needs the
//// node, which is the one name both daemons agree on.
////
//// A page leaves out archived sessions and every session whose custody is
//// `moving` or `moved`, so no identity is listed by two orchestrators. The
//// helper pool's census is deliberately not part of a row.
////
//// ## Flow
////
//// `clamp_limit` → `row_json` → `status_json` → `unlisted`
////
//// 1. `clamp_limit` keeps an asker's page size between one and 100 rows.
//// 2. `row_json` renders a row as a record of the sessions.list reply.
//// 3. `status_json` renders the status member of a row.
//// 4. `unlisted` is the `Listing` of a daemon that cannot ask a peer.

import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}

/// The most rows a daemon answers in one page, whatever the asker requested.
pub const max_limit = 100

/// Where a session is in its life, as `sessions.list` states it.
pub type ListedStatus {
  /// A creation reserved the identity and was never reconciled, so only a
  /// retry of that creation can finish it.
  Reserved

  /// No runtime is held for the session.
  Saved

  /// A builder owns this opening operation.
  Opening(operation: String)

  /// The session is resident with this incarnation.
  Resident(incarnation: String)

  /// Cleanup of the session's runtime is pending.
  Stopping(operation: String)

  /// Cleanup lost its proof or failed. The reason stays on the answering
  /// daemon, which is the only one that can act on it.
  RecoveryBlocked
}

/// One session of a page.
pub type Row {
  Row(
    /// The canonical session identity.
    session_id: String,
    /// The workspace, as the answering daemon names it. It is a path on that
    /// machine, shown to the asking owner, who is the same operator.
    workspace: String,
    /// The display name.
    name: String,
    /// When the session was created, in Unix milliseconds.
    created_at: Int,
    /// The session's lifecycle state on the answering daemon.
    status: ListedStatus,
    /// The subtitle, when the session has one.
    subtitle: Option(String),
    /// The key of the answering daemon's `[executors]` row that holds the
    /// session's work, when it is placed on one.
    executor: Option(String),
    /// The key of the answering daemon's `[pools]` row, when it is in one.
    pool: Option(String),
    /// The node of that executor, when the answering daemon's table lists it.
    /// It lets a reader attribute the row to a machine without assuming that
    /// two orchestrators call one executor by one key.
    executor_node: Option(String),
  )
}

/// Whether rows follow the ones a page holds.
pub type More {
  /// The page reached the end of what the daemon lists.
  Last

  /// At least one more row follows. The asker continues after the last row's
  /// identity.
  Further
}

/// Some rows, in identity order, and whether more follow.
pub type Page {
  Page(rows: List(Row), more: More)
}

/// How a daemon asks a peer orchestrator for a page of its sessions, given the
/// peer's node name, the identity the page follows, the most rows wanted and the
/// time to wait in milliseconds. `Error(Nil)` is silence: the peer was not
/// reached, did not answer in time, or could not read its catalogue. It is held
/// as a function so that a test can supply the answers.
pub type Listing =
  fn(String, String, Int, Int) -> Result(Page, Nil)

/// The listing of a daemon with no way to ask a peer: every peer is silent.
///
/// ## Examples
///
/// ```gleam
/// assert listed_sessions.unlisted("alpha@10.0.0.1", "", 20, 1000) == Error(Nil)
/// ```
pub fn unlisted(
  _node: String,
  _after: String,
  _limit: Int,
  _within_ms: Int,
) -> Result(Page, Nil) {
  Error(Nil)
}

/// A page with nothing on it, which is what a daemon with no catalogue answers.
///
/// ## Examples
///
/// ```gleam
/// assert listed_sessions.empty() == listed_sessions.Page([], listed_sessions.Last)
/// ```
pub fn empty() -> Page {
  Page(rows: [], more: Last)
}

/// Keeps a requested page size between one row and `max_limit` rows.
///
/// ## Examples
///
/// ```gleam
/// assert listed_sessions.clamp_limit(0) == 1
/// assert listed_sessions.clamp_limit(5000) == 100
/// ```
pub fn clamp_limit(limit: Int) -> Int {
  case limit {
    below if below < 1 -> 1
    above if above > max_limit -> max_limit
    within -> within
  }
}

/// Renders a row as a `sessions.list` record, with `executor_node` after the
/// members that record has. A member the row does not have is left out.
///
/// ## Examples
///
/// ```gleam
/// // listed_sessions.row_json(row)
/// ```
pub fn row_json(row: Row) -> JsonValue {
  json.Object(
    list.flatten([
      [
        #("session_id", json.String(row.session_id)),
        #("workspace", json.String(row.workspace)),
        #("name", json.String(row.name)),
        #("created_at", json.Int(row.created_at)),
        #("status", status_json(row.status)),
      ],
      present("subtitle", row.subtitle),
      present("executor", row.executor),
      present("pool", row.pool),
      present("executor_node", row.executor_node),
    ]),
  )
}

/// Renders the status member of a row as `sessions.list` does: a `state` word,
/// and the operation or incarnation for the states that have one.
///
/// ## Examples
///
/// ```gleam
/// assert listed_sessions.status_json(listed_sessions.Saved)
///   == json.Object([#("state", json.String("saved"))])
/// ```
pub fn status_json(status: ListedStatus) -> JsonValue {
  case status {
    Reserved -> state("reserved", [])
    Saved -> state("saved", [])
    Opening(operation:) ->
      state("opening", [#("operation", json.String(operation))])
    Resident(incarnation:) ->
      state("resident", [#("incarnation", json.String(incarnation))])
    Stopping(operation:) ->
      state("stopping", [#("operation", json.String(operation))])
    RecoveryBlocked -> state("recovery_blocked", [])
  }
}

fn state(word: String, more: List(#(String, JsonValue))) -> JsonValue {
  json.Object([#("state", json.String(word)), ..more])
}

fn present(key: String, value: Option(String)) -> List(#(String, JsonValue)) {
  case value {
    Some(text) -> [#(key, json.String(text))]
    None -> []
  }
}
