//// The vocabulary of a spawner's page driving top-level sessions on this
//// orchestrator, between two orchestrators (protocol-change/094).
////
//// A laptop's page can start a session whose agent runs on the box, list the
//// sessions it started there, page one's transcript, message it, stop its run,
//// archive it, and decide its requests. The eight messages that carry those
//// asks are the orchestrator port's `Placements`, `TopCreate`, `TopSessions`,
//// `TopHistory`, `TopSend`, `TopStop`, `TopArchive` and `TopResolve`
//// (`client/remote/orchestrator_port`). This module holds the plain data they
//// carry and the answers they get. It has no process in it and does no I/O, as
//// `client/remote_spawn` has none, so both orchestrators compile the same module
//// and a value built here crosses the pinned connection as an ordinary term.
////
//// ## What crosses as JSON, and why
////
//// Three answers are bounded pages of text from another machine: the offers a
//// composer draws (`Offers`), the list of sessions (`SessionsPage`), and a
//// transcript page (`session_view/remote_transcript`). Each is encoded to a
//// `JsonValue` by the box, which can then measure it against its byte bound,
//// and decoded by the laptop with a total decoder that checks every bound and
//// every closed word again. A page that fails the decoder is refused whole and
//// never drawn in part, because the box's text is not the laptop's to trust.
////
//// ## The page rule
////
//// A page of sessions is at most 64 rows and 64 KiB. A row is whole or absent:
//// its requests are never split across pages. A row therefore has its own
//// bound, `max_row_bytes`, and `fit_requests` keeps the oldest requests that
//// fit under it, so even a session with a thousand pending requests is a row
//// that can be sent. The rest are counted in `more`.
////
//// ## Flow
////
//// `describe_refusal` → `retryable` → `encode_offers` → `decode_offers` →
//// `fit_requests` → `page_of` → `encode_page` → `decode_page`
////
//// 1. `describe_refusal` words a refusal for the person at the page, and
////    `retryable` says whether the same message may succeed on a later try.
//// 2. `encode_offers` and `decode_offers` are the two ends of a `Placements`
////    answer.
//// 3. `fit_requests` cuts a session's pending requests to the row bound, and
////    `page_of` cuts a list of rows to the page bound.
//// 4. `encode_page` and `decode_page` are the two ends of a `TopSessions`
////    answer.

import client/protocol.{type EscalationRecord}
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/remote_agent.{type RemoteAgent}

/// The most entries one `Placements` answer lists, folders, executors, pools,
/// profiles and models together.
pub const max_offers = 256

/// The most workspace names one executor or pool lists.
pub const max_workspaces = 64

/// The most rows one `TopSessions` page holds.
pub const max_rows = 64

/// The most bytes one encoded `TopSessions` page holds.
pub const max_page_bytes = 65_536

/// The most bytes one encoded row holds, so that a row is always small enough
/// to be a page by itself.
pub const max_row_bytes = 24_576

/// The most pending requests one row carries. The rest are counted in `more`.
pub const max_row_requests = 8

/// The most remote children one row carries.
pub const max_row_children = 16

/// The most bytes of one name, path or label that the decoder accepts.
pub const max_text_bytes = 512

/// Where a relayed session's tools run, as the page chose it.
pub type Placement {
  /// A folder on the orchestrator that holds the session.
  Folder(
    /// The folder's absolute path there.
    path: String,
  )

  /// A workspace registered on one of its executors.
  Workspace(
    /// The `[executors.<name>]` key there.
    executor: String,
    /// The workspace name registered on that executor.
    name: String,
  )

  /// A workspace on any member of one of its pools.
  Pooled(
    /// The `[pools.<name>]` key there.
    pool: String,
    /// The workspace name the pool's executors register.
    name: String,
  )
}

/// Which of its two caps a spawner's `top_level` table reached.
pub type Cap {
  /// `max_sessions`: relayed sessions that are not archived.
  MaxSessions

  /// `max_per_hour`: creations over a rolling hour.
  MaxPerHour
}

/// What a table can offer and a request can name.
pub type Offered {
  /// A folder.
  OfferedFolder

  /// An executor.
  OfferedExecutor

  /// A pool.
  OfferedPool

  /// A profile.
  OfferedProfile

  /// A model.
  OfferedModel
}

/// Why the orchestrator would not do what a message asked, or could not yet.
pub type Refusal {
  /// No `[spawners.<name>]` names the node the message came from.
  UnknownSpawner(
    /// The node the message came from.
    node: String,
  )

  /// The spawner has no `top_level` table, so none of these messages is served.
  TopLevelOff

  /// The request names something the table does not offer, or that this
  /// orchestrator does not have.
  NotOffered(
    /// What kind of thing it is.
    what: Offered,
    /// The name the request gave.
    name: String,
  )

  /// A cap of the table was reached, and nothing was written.
  CapReached(
    /// Which cap.
    cap: Cap,
    /// Its value.
    limit: Int,
  )

  /// The session was not started by this spawner, or does not exist.
  NotRelayed

  /// An argument is invalid, such as a folder the folder checks refuse or text
  /// above its bound.
  InvalidArgument(
    /// What is wrong, in words for the person.
    reason: String,
  )

  /// The session did not open in the receiver's budget, or was reserved and its
  /// store not yet made. Asking again later with the same identities can
  /// succeed.
  NotYetOpen(
    /// What the registry said.
    reason: String,
  )

  /// The receiver's store failed. Asking again can succeed.
  StoreFailure(
    /// What failed.
    reason: String,
  )
}

/// Words a refusal for the person at the page.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.describe_refusal(remote_top.CapReached(remote_top.MaxSessions, 8))
///   == "the orchestrator already holds 8 of your sessions (max_sessions)"
/// ```
pub fn describe_refusal(refusal: Refusal) -> String {
  // This match resolves refusal before the surrounding protocol step continues.
  // This match resolves refusal before the enclosing validation continues.
  case refusal {
    UnknownSpawner(node:) ->
      "this orchestrator has no [spawners.<name>] for the node " <> node
    TopLevelOff ->
      "this orchestrator does not let your orchestrator start sessions "
      <> "(its spawner table has no top_level table)"
    NotOffered(what:, name:) ->
      "this orchestrator does not offer "
      <> offered_word(what)
      <> " "
      <> name
      <> " to your orchestrator"
    CapReached(cap: MaxSessions, limit:) ->
      "the orchestrator already holds "
      <> int.to_string(limit)
      <> " of your sessions (max_sessions)"
    CapReached(cap: MaxPerHour, limit:) ->
      "your orchestrator has started "
      <> int.to_string(limit)
      <> " sessions there in the last hour (max_per_hour)"
    NotRelayed -> "that session was not started by your orchestrator"
    InvalidArgument(reason:) -> reason
    NotYetOpen(reason:) -> reason
    StoreFailure(reason:) -> reason
  }
}

/// Offered word keeps this client operation’s decoding or state decision in one place.
fn offered_word(what: Offered) -> String {
  // This match resolves what before the surrounding protocol step continues.
  // This match resolves what before the enclosing validation continues.
  case what {
    OfferedFolder -> "the folder"
    OfferedExecutor -> "the executor"
    OfferedPool -> "the pool"
    OfferedProfile -> "the profile"
    OfferedModel -> "the model"
  }
}

/// Whether the same message may succeed on a later try. `NotYetOpen` and
/// `StoreFailure` say the receiver could not do it now and that nothing
/// changed; every other refusal is definitive, and sending it again changes
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.retryable(remote_top.StoreFailure("busy"))
/// assert !remote_top.retryable(remote_top.NotRelayed)
/// ```
pub fn retryable(refusal: Refusal) -> Bool {
  // This match resolves refusal before the surrounding protocol step continues.
  // This match resolves refusal before the enclosing validation continues.
  case refusal {
    NotYetOpen(..) | StoreFailure(..) -> True
    UnknownSpawner(..)
    | TopLevelOff
    | NotOffered(..)
    | CapReached(..)
    | NotRelayed
    | InvalidArgument(..) -> False
  }
}

// --- the offers a composer draws -----------------------------------------------

/// A folder the orchestrator remembers.
pub type FolderOffer {
  FolderOffer(
    /// The absolute path there.
    path: String,
    /// The label its own page draws, the last segment of the path.
    label: String,
  )
}

/// How ready an executor is to take a session, as its own page words it.
pub type ExecutorState {
  /// A session can be placed on it.
  Ready

  /// It answered with a reason a person should know before choosing it.
  Degraded

  /// Every scope it admits is held.
  Full

  /// It did not answer.
  Down
}

/// An executor a page may pick.
pub type ExecutorOffer {
  ExecutorOffer(
    /// The `[executors.<name>]` key there.
    name: String,
    /// How ready it is.
    state: ExecutorState,
    /// How many more scopes it admits, when it reported.
    free_scopes: Option(Int),
    /// The workspace names it registered, at most `max_workspaces`.
    workspaces: List(String),
  )
}

/// A pool a page may pick.
pub type PoolOffer {
  PoolOffer(
    /// The `[pools.<name>]` key there.
    name: String,
    /// How many of its executors can take a session now.
    ready: Int,
    /// The workspace names every ready executor registered, at most
    /// `max_workspaces`.
    workspaces: List(String),
  )
}

/// What the orchestrator offers one spawner's page: the answer to `Placements`.
pub type Offers {
  Offers(
    /// The folders it remembers, when the table allows folders.
    folders: List(FolderOffer),
    /// The executors the table lists.
    executors: List(ExecutorOffer),
    /// The pools the table lists.
    pools: List(PoolOffer),
    /// The profiles a session may start with.
    profiles: List(String),
    /// The models of its catalogue.
    models: List(String),
  )
}

/// The offers of an orchestrator that offers nothing.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.no_offers().profiles == []
/// ```
pub fn no_offers() -> Offers {
  Offers(folders: [], executors: [], pools: [], profiles: [], models: [])
}

/// How many entries the offers list, which `max_offers` bounds.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.entries(remote_top.no_offers()) == 0
/// ```
pub fn entries(offers: Offers) -> Int {
  list.length(offers.folders)
  + list.length(offers.executors)
  + list.length(offers.pools)
  + list.length(offers.profiles)
  + list.length(offers.models)
}

/// Cuts the offers to `max_offers` entries, keeping the lists in the order
/// folders, executors, pools, profiles, models, and cuts each workspace list
/// to `max_workspaces`. The box applies this before it encodes, so that a large
/// configuration is an answer and not a refusal.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.bounded(remote_top.no_offers()) == remote_top.no_offers()
/// ```
pub fn bounded(offers: Offers) -> Offers {
  // Text the laptop's decoder would refuse is left out, so one over-long name
  // cannot make the whole answer unreadable.
  let offers =
    Offers(
      folders: list.filter(offers.folders, fn(folder) {
        fits(folder.path) && fits(folder.label)
      }),
      executors: list.filter(offers.executors, fn(offer) { fits(offer.name) })
        |> list.map(fn(offer) {
          ExecutorOffer(
            ..offer,
            workspaces: list.filter(offer.workspaces, fits),
          )
        }),
      pools: list.filter(offers.pools, fn(offer) { fits(offer.name) })
        |> list.map(fn(offer) {
          PoolOffer(..offer, workspaces: list.filter(offer.workspaces, fits))
        }),
      profiles: list.filter(offers.profiles, fits),
      models: list.filter(offers.models, fits),
    )
  let folders = list.take(offers.folders, max_offers)
  let room = max_offers - list.length(folders)

  // Each list takes what room is left, and each workspace list is cut to its
  // own bound whatever room there is.
  let executors =
    list.take(offers.executors, room)
    |> list.map(fn(offer) {
      ExecutorOffer(
        ..offer,
        workspaces: list.take(offer.workspaces, max_workspaces),
      )
    })
  let room = room - list.length(executors)
  let pools =
    list.take(offers.pools, room)
    |> list.map(fn(offer) {
      PoolOffer(
        ..offer,
        workspaces: list.take(offer.workspaces, max_workspaces),
      )
    })
  let room = room - list.length(pools)

  // The names that are left are the cheapest to cut, so they come last.
  let profiles = list.take(offers.profiles, room)
  let room = room - list.length(profiles)
  Offers(
    folders:,
    executors:,
    pools:,
    profiles:,
    models: list.take(offers.models, room),
  )
}

/// Whether a text is within what the laptop's decoder accepts.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.fits("work")
/// ```
pub fn fits(text: String) -> Bool {
  string.byte_size(text) <= max_text_bytes
}

/// A text cut to `max_text_bytes`, on a character boundary. A text that fits is
/// returned as it is.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.clip("work") == "work"
/// ```
pub fn clip(text: String) -> String {
  // This match resolves fits(text) before the surrounding protocol step continues.
  // This match resolves fits(text) before the enclosing validation continues.
  case fits(text) {
    True -> text
    False -> string.drop_end(text, string.byte_size(text) - max_text_bytes)
  }
}

/// The offers as the wire object.
///
/// ## Examples
///
/// ```gleam
/// // remote_top.encode_offers(remote_top.no_offers())
/// // == {"folders": [], "executors": [], "pools": [], "profiles": [], "models": []}
/// ```
pub fn encode_offers(offers: Offers) -> JsonValue {
  json.Object([
    #(
      "folders",
      json.Array(
        list.map(offers.folders, fn(folder) {
          json.Object([
            #("path", json.String(folder.path)),
            #("label", json.String(folder.label)),
          ])
        }),
      ),
    ),
    #(
      "executors",
      json.Array(
        list.map(offers.executors, fn(offer) {
          json.Object([
            #("name", json.String(offer.name)),
            #("state", json.String(state_word(offer.state))),
            #("free_scopes", optional_int(offer.free_scopes)),
            #("workspaces", strings(offer.workspaces)),
          ])
        }),
      ),
    ),
    #(
      "pools",
      json.Array(
        list.map(offers.pools, fn(offer) {
          json.Object([
            #("name", json.String(offer.name)),
            #("ready", json.Int(offer.ready)),
            #("workspaces", strings(offer.workspaces)),
          ])
        }),
      ),
    ),
    #("profiles", strings(offers.profiles)),
    #("models", strings(offers.models)),
  ])
}

/// State word keeps this client operation’s decoding or state decision in one place.
fn state_word(state: ExecutorState) -> String {
  // This match resolves state before the surrounding protocol step continues.
  // This match resolves state before the enclosing validation continues.
  case state {
    Ready -> "ready"
    Degraded -> "degraded"
    Full -> "full"
    Down -> "down"
  }
}

/// State of keeps this client operation’s decoding or state decision in one place.
fn state_of(word: String) -> Result(ExecutorState, String) {
  // This match resolves word before the surrounding protocol step continues.
  // This match resolves word before the enclosing validation continues.
  case word {
    "ready" -> Ok(Ready)
    "degraded" -> Ok(Degraded)
    "full" -> Ok(Full)
    "down" -> Ok(Down)
    _ -> Error("state is not a known executor state")
  }
}

/// Reads an answer to `Placements`. Every bound is checked: the entries are at
/// most `max_offers`, each name is within `max_text_bytes`, each workspace list
/// is within `max_workspaces`, and a state outside its closed set is refused.
/// The error names the field. Nothing is returned in part.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.decode_offers(remote_top.encode_offers(remote_top.no_offers()))
///   == Ok(remote_top.no_offers())
/// ```
pub fn decode_offers(value: JsonValue) -> Result(Offers, String) {
  use fields <- result.try(object(value, "offers"))
  use folders <- result.try(
    list_of(fields, "folders", max_offers, fn(item) {
      use folder <- result.try(object(item, "a folder"))
      use path <- result.try(text_of(folder, "path"))
      use label <- result.map(text_of(folder, "label"))
      FolderOffer(path:, label:)
    }),
  )
  use executors <- result.try(
    list_of(fields, "executors", max_offers, fn(item) {
      use offer <- result.try(object(item, "an executor"))
      use name <- result.try(text_of(offer, "name"))
      use word <- result.try(text_of(offer, "state"))
      use state <- result.try(state_of(word))
      use free_scopes <- result.try(optional_count(offer, "free_scopes"))
      use workspaces <- result.map(texts_of(offer, "workspaces", max_workspaces))
      ExecutorOffer(name:, state:, free_scopes:, workspaces:)
    }),
  )
  use pools <- result.try(
    list_of(fields, "pools", max_offers, fn(item) {
      use offer <- result.try(object(item, "a pool"))
      use name <- result.try(text_of(offer, "name"))
      use ready <- result.try(count_of(offer, "ready"))
      use workspaces <- result.map(texts_of(offer, "workspaces", max_workspaces))
      PoolOffer(name:, ready:, workspaces:)
    }),
  )

  // Decode profiles, models, and enforce maximum aggregate offer count.
  use profiles <- result.try(texts_of(fields, "profiles", max_offers))
  use models <- result.try(texts_of(fields, "models", max_offers))
  let offers = Offers(folders:, executors:, pools:, profiles:, models:)

  // This match resolves entries(offers) <= max_offers before the surrounding protocol step continues.
  // This match resolves entries(offers) <= max_offers before the enclosing validation continues.
  case entries(offers) <= max_offers {
    True -> Ok(offers)
    False -> Error("offers hold too many entries")
  }
}

// --- the rows of a page of sessions ----------------------------------------------

/// What a relayed session is doing, as the box words it for a sidebar.
pub type Activity {
  /// A request is pending, or the last run failed and nothing has run since.
  NeedsYou

  /// A strand is running.
  Working

  /// Nothing is running and nothing is asked.
  Idle

  /// The owner archived the session.
  Archived
}

/// One relayed session of a page.
pub type Row {
  Row(
    /// This orchestrator's identity for the session.
    session_id: String,
    /// The request id the create carried, so that the spawner can reconcile a
    /// create whose answer it never received.
    request_id: String,
    /// The session's display name.
    name: String,
    /// Where its tools run.
    placement: Placement,
    /// What it is doing.
    activity: Activity,
    /// When the session last changed, in Unix milliseconds on the box's clock.
    updated_at: Int,
    /// The oldest pending requests by `seq`, at most `max_row_requests`, in the
    /// protocol's own record shape with `admitted` set from the approval
    /// ceiling and `placement` empty (the laptop names the orchestrator).
    requests: List(EscalationRecord),
    /// How many pending requests are not in `requests`.
    more: Int,
    /// The session's own children on other orchestrators, as the session's
    /// stubs state them.
    children: List(RemoteAgent),
  )
}

/// Whether rows follow the ones a page holds.
pub type More {
  /// The page reached the end of what the spawner holds.
  Last

  /// At least one more row follows. The asker continues after the last row's
  /// session identity.
  Further
}

/// Some rows, newest first, and whether more follow.
pub type SessionsPage {
  SessionsPage(rows: List(Row), more: More)
}

/// A page with no rows.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.empty_page() == remote_top.SessionsPage([], remote_top.Last)
/// ```
pub fn empty_page() -> SessionsPage {
  SessionsPage(rows: [], more: Last)
}

/// A pending request's size on the wire, in bytes.
fn request_bytes(record: EscalationRecord) -> Int {
  string.byte_size(json.to_string(protocol.encode_escalation(record)))
}

/// Cuts a session's pending requests to what one row can carry: the oldest by
/// `seq`, at most `max_row_requests`, and as many as fit with the rest of the
/// row under `max_row_bytes`. `rest_bytes` is the encoded size of the row
/// without its requests. The answer is the requests kept and how many were not.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.fit_requests([], 100) == #([], 0)
/// ```
pub fn fit_requests(
  pending: List(EscalationRecord),
  rest_bytes: Int,
) -> #(List(EscalationRecord), Int) {
  let ordered = list.sort(pending, fn(a, b) { int.compare(a.seq, b.seq) })
  let kept = keep(list.take(ordered, max_row_requests), rest_bytes, [])
  #(kept, list.length(pending) - list.length(kept))
}

/// Keep keeps this client operation’s decoding or state decision in one place.
fn keep(
  candidates: List(EscalationRecord),
  used: Int,
  kept: List(EscalationRecord),
) -> List(EscalationRecord) {
  // This match resolves candidates before the surrounding protocol step continues.
  // This match resolves candidates before the enclosing validation continues.
  case candidates {
    [] -> list.reverse(kept)
    [next, ..rest] -> {
      // One byte for the comma that separates a request from the next.
      let used = used + request_bytes(next) + 1

      // This match resolves used <= max_row_bytes before the surrounding protocol step continues.
      case used <= max_row_bytes {
        True -> keep(rest, used, [next, ..kept])
        False -> list.reverse(kept)
      }
    }
  }
}

/// Cuts rows to one page: at most `max_rows`, and at most `max_page_bytes` once
/// encoded. A row is kept whole or left out, so the page ends at the first row
/// that does not fit, and `Further` says rows follow. `more` is whether the
/// caller already knows of rows after these.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.page_of([], remote_top.Last) == remote_top.empty_page()
/// ```
pub fn page_of(rows: List(Row), more: More) -> SessionsPage {
  let #(kept, cut) = take_rows(rows, 0, [])

  // This match resolves cut, more before the surrounding protocol step continues.
  // This match resolves cut, more before the enclosing validation continues.
  case cut, more {
    True, _ | _, Further -> SessionsPage(rows: kept, more: Further)
    False, Last -> SessionsPage(rows: kept, more: Last)
  }
}

// Rows in order while they fit. The byte count is of the rows alone; the page
// object around them is small and `max_page_bytes` leaves it room by being
// compared against a figure that includes a comma for each row.
/// Take rows keeps this client operation’s decoding or state decision in one place.
fn take_rows(
  rows: List(Row),
  used: Int,
  kept: List(Row),
) -> #(List(Row), Bool) {
  // This match resolves rows before the surrounding protocol step continues.
  // This match resolves rows before the enclosing validation continues.
  case rows {
    [] -> #(list.reverse(kept), False)
    [next, ..rest] -> {
      let size = string.byte_size(json.to_string(encode_row(next))) + 1
      let fits =
        list.length(kept) < max_rows && used + size + 64 <= max_page_bytes

      // This match resolves fits before the surrounding protocol step continues.
      case fits {
        True -> take_rows(rest, used + size, [next, ..kept])
        False -> #(list.reverse(kept), True)
      }
    }
  }
}

/// A page as the wire object.
///
/// ## Examples
///
/// ```gleam
/// // remote_top.encode_page(remote_top.empty_page()) == {"rows": [], "more": "last"}
/// ```
pub fn encode_page(page: SessionsPage) -> JsonValue {
  json.Object([
    #("rows", json.Array(list.map(page.rows, encode_row))),
    #("more", json.String(more_word(page.more))),
  ])
}

/// More word keeps this client operation’s decoding or state decision in one place.
fn more_word(more: More) -> String {
  // This match resolves more before the surrounding protocol step continues.
  // This match resolves more before the enclosing validation continues.
  case more {
    Last -> "last"
    Further -> "further"
  }
}

/// One row as its wire object.
///
/// ## Examples
///
/// ```gleam
/// // remote_top.encode_row(row)
/// ```
pub fn encode_row(row: Row) -> JsonValue {
  json.Object([
    #("session_id", json.String(clip(row.session_id))),
    #("request_id", json.String(clip(row.request_id))),
    #("name", json.String(clip(row.name))),
    #("placement", encode_placement(clipped(row.placement))),
    #("activity", json.String(activity_word(row.activity))),
    #("updated_at", json.Int(row.updated_at)),
    #(
      "requests",
      json.Array(list.map(row.requests, protocol.encode_escalation)),
    ),
    #("more", json.Int(row.more)),
    #("children", json.Array(list.map(row.children, remote_agent.encode))),
  ])
}

/// Activity word keeps this client operation’s decoding or state decision in one place.
fn activity_word(activity: Activity) -> String {
  // This match resolves activity before the surrounding protocol step continues.
  // This match resolves activity before the enclosing validation continues.
  case activity {
    NeedsYou -> "needs_you"
    Working -> "working"
    Idle -> "idle"
    Archived -> "archived"
  }
}

/// Activity of keeps this client operation’s decoding or state decision in one place.
fn activity_of(word: String) -> Result(Activity, String) {
  // This match resolves word before the surrounding protocol step continues.
  // This match resolves word before the enclosing validation continues.
  case word {
    "needs_you" -> Ok(NeedsYou)
    "working" -> Ok(Working)
    "idle" -> Ok(Idle)
    "archived" -> Ok(Archived)
    _ -> Error("activity is not a known activity")
  }
}

// A placement whose texts are cut to what the laptop accepts. A row is
// information, and a path too long to send is shown cut and not allowed to make
// the whole page unreadable.
/// Clipped keeps this client operation’s decoding or state decision in one place.
fn clipped(placement: Placement) -> Placement {
  // This match resolves placement before the surrounding protocol step continues.
  // This match resolves placement before the enclosing validation continues.
  case placement {
    Folder(path:) -> Folder(path: clip(path))
    Workspace(executor:, name:) ->
      Workspace(executor: clip(executor), name: clip(name))
    Pooled(pool:, name:) -> Pooled(pool: clip(pool), name: clip(name))
  }
}

/// A placement as its wire object.
///
/// ## Examples
///
/// ```gleam
/// // remote_top.encode_placement(remote_top.Folder("/srv/work"))
/// // == {"kind": "folder", "path": "/srv/work"}
/// ```
pub fn encode_placement(placement: Placement) -> JsonValue {
  // This match resolves placement before the surrounding protocol step continues.
  // This match resolves placement before the enclosing validation continues.
  case placement {
    Folder(path:) ->
      json.Object([
        #("kind", json.String("folder")),
        #("path", json.String(path)),
      ])
    Workspace(executor:, name:) ->
      json.Object([
        #("kind", json.String("workspace")),
        #("executor", json.String(executor)),
        #("name", json.String(name)),
      ])
    Pooled(pool:, name:) ->
      json.Object([
        #("kind", json.String("pooled")),
        #("pool", json.String(pool)),
        #("name", json.String(name)),
      ])
  }
}

/// Reads a placement.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.decode_placement(remote_top.encode_placement(remote_top.Folder("/w")))
///   == Ok(remote_top.Folder("/w"))
/// ```
pub fn decode_placement(value: JsonValue) -> Result(Placement, String) {
  use fields <- result.try(object(value, "placement"))
  use kind <- result.try(text_of(fields, "kind"))

  // This match resolves kind before the surrounding protocol step continues.
  // This match resolves kind before the enclosing validation continues.
  case kind {
    "folder" -> text_of(fields, "path") |> result.map(Folder)
    "workspace" -> {
      use executor <- result.try(text_of(fields, "executor"))
      use name <- result.map(text_of(fields, "name"))
      Workspace(executor:, name:)
    }
    "pooled" -> {
      use pool <- result.try(text_of(fields, "pool"))
      use name <- result.map(text_of(fields, "name"))
      Pooled(pool:, name:)
    }
    _ -> Error("placement kind is not known")
  }
}

/// Reads an answer to `TopSessions`. The rows are at most `max_rows`, the
/// encoded page is at most `max_page_bytes`, a row has at most
/// `max_row_requests` requests and `max_row_children` children, every text is
/// within `max_text_bytes`, and each request is read by the protocol's own
/// total decoder. A word outside its closed set is refused, and so is a page
/// that does not decode in full. The error names the field.
///
/// ## Examples
///
/// ```gleam
/// assert remote_top.decode_page(remote_top.encode_page(remote_top.empty_page()))
///   == Ok(remote_top.empty_page())
/// ```
pub fn decode_page(value: JsonValue) -> Result(SessionsPage, String) {
  // This branch enforces the decode page boundary before the next operation.
  use Nil <- result.try(
    // This match resolves string.byte_size(json.to_string(value)) <= max_page_bytes before the surrounding protocol step continues.
    // This match resolves string.byte_size(json.to_string(value)) <= max_page_bytes before the enclosing validation continues.
    case string.byte_size(json.to_string(value)) <= max_page_bytes {
      True -> Ok(Nil)
      False -> Error("page is larger than a page may be")
    },
  )

  use fields <- result.try(object(value, "page"))
  use rows <- result.try(list_of(fields, "rows", max_rows, decode_row))
  use word <- result.try(text_of(fields, "more"))

  // This match resolves word before the enclosing validation continues.
  use more <- result.map(case word {
    "last" -> Ok(Last)
    "further" -> Ok(Further)
    _ -> Error("more is not a known word")
  })

  SessionsPage(rows:, more:)
}

/// Reads one row.
///
/// ## Examples
///
/// ```gleam
/// // remote_top.decode_row(remote_top.encode_row(row)) == Ok(row)
/// ```
pub fn decode_row(value: JsonValue) -> Result(Row, String) {
  use fields <- result.try(object(value, "a row"))
  use session_id <- result.try(text_of(fields, "session_id"))
  use request_id <- result.try(text_of(fields, "request_id"))
  use name <- result.try(text_of(fields, "name"))

  // This match resolves list.key_find(fields, "placement") before the enclosing validation continues.
  use placement <- result.try(case list.key_find(fields, "placement") {
    Ok(found) -> decode_placement(found)
    Error(Nil) -> Error("placement is missing")
  })

  use word <- result.try(text_of(fields, "activity"))
  use activity <- result.try(activity_of(word))
  use updated_at <- result.try(count_of(fields, "updated_at"))
  use requests <- result.try(list_of(
    fields,
    "requests",
    max_row_requests,
    protocol.decode_escalation,
  ))
  use more <- result.try(count_of(fields, "more"))
  use children <- result.try(list_of(
    fields,
    "children",
    max_row_children,
    remote_agent.decode,
  ))
  Ok(Row(
    session_id:,
    request_id:,
    name:,
    placement:,
    activity:,
    updated_at:,
    requests:,
    more:,
    children:,
  ))
}

// --- total reading helpers ---------------------------------------------------------

type Fields =
  List(#(String, JsonValue))

/// Object keeps this client operation’s decoding or state decision in one place.
fn object(value: JsonValue, place: String) -> Result(Fields, String) {
  // This match resolves value before the surrounding protocol step continues.
  // This match resolves value before the enclosing validation continues.
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(place <> " is not an object")
  }
}

/// Text of keeps this client operation’s decoding or state decision in one place.
fn text_of(fields: Fields, key: String) -> Result(String, String) {
  // This match resolves list.key_find(fields, key) before the surrounding protocol step continues.
  // This match resolves list.key_find(fields, key) before the enclosing validation continues.
  case list.key_find(fields, key) {
    Ok(json.String(text)) ->
      // This match resolves string.byte_size(text) <= max_text_bytes before the surrounding protocol step continues.
      case string.byte_size(text) <= max_text_bytes {
        True -> Ok(text)
        False -> Error(key <> " is longer than a page allows")
      }
    _ -> Error(key <> " is not a string")
  }
}

/// Count of keeps this client operation’s decoding or state decision in one place.
fn count_of(fields: Fields, key: String) -> Result(Int, String) {
  // This match resolves list.key_find(fields, key) before the surrounding protocol step continues.
  // This match resolves list.key_find(fields, key) before the enclosing validation continues.
  case list.key_find(fields, key) {
    Ok(json.Int(number)) if number >= 0 -> Ok(number)
    Ok(json.Int(_)) -> Error(key <> " is a negative count")
    _ -> Error(key <> " is not an integer")
  }
}

/// Optional count keeps this client operation’s decoding or state decision in one place.
fn optional_count(fields: Fields, key: String) -> Result(Option(Int), String) {
  // This match resolves list.key_find(fields, key) before the surrounding protocol step continues.
  // This match resolves list.key_find(fields, key) before the enclosing validation continues.
  case list.key_find(fields, key) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(_) -> count_of(fields, key) |> result.map(Some)
  }
}

/// Texts of keeps this client operation’s decoding or state decision in one place.
fn texts_of(
  fields: Fields,
  key: String,
  most: Int,
) -> Result(List(String), String) {
  list_of(fields, key, most, fn(item) {
    // This match resolves item before the surrounding protocol step continues.
    // This match resolves item before the enclosing validation continues.
    case item {
      json.String(text) ->
        // This match resolves string.byte_size(text) <= max_text_bytes before the surrounding protocol step continues.
        case string.byte_size(text) <= max_text_bytes {
          True -> Ok(text)
          False -> Error(key <> " holds text longer than a page allows")
        }
      _ -> Error(key <> " holds something that is not a string")
    }
  })
}

/// List of keeps this client operation’s decoding or state decision in one place.
fn list_of(
  fields: Fields,
  key: String,
  most: Int,
  item: fn(JsonValue) -> Result(a, String),
) -> Result(List(a), String) {
  // This match resolves list.key_find(fields, key) before the surrounding protocol step continues.
  // This match resolves list.key_find(fields, key) before the enclosing validation continues.
  case list.key_find(fields, key) {
    Ok(json.Array(items)) ->
      // This match resolves list.drop(items, most) before the surrounding protocol step continues.
      case list.drop(items, most) {
        [] -> list.try_map(items, item)
        [_, ..] -> Error(key <> " holds too many entries")
      }
    _ -> Error(key <> " is not an array")
  }
}

/// Strings keeps this client operation’s decoding or state decision in one place.
fn strings(items: List(String)) -> JsonValue {
  json.Array(list.map(items, json.String))
}

/// Optional int keeps this client operation’s decoding or state decision in one place.
fn optional_int(value: Option(Int)) -> JsonValue {
  // This match resolves value before the surrounding protocol step continues.
  // This match resolves value before the enclosing validation continues.
  case value {
    Some(number) -> json.Int(number)
    None -> json.Null
  }
}
