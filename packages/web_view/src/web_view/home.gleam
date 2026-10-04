//// The home page's server component (protocol-change/065): the sessions the
//// page's principal holds, grouped by workspace, drawn inside the same frame
//// as a session's page and bound to no session.
////
//// A home has no lane, no gateway and no relay. Its one fact is a list of
//// catalogue entries, which the daemon reads as the page's principal and
//// hands over through `Start.sessions`: when the page opens, and again every
//// `Start.refresh_ms` after. Each read is also the page's check that it may
//// still be served. A read that answers `Closed` says the page's UI session
//// ended or its credential no longer authenticates, and the page draws why
//// and asks for nothing more. That is how a revoked credential's home ends,
//// at its next read, as a session's page ends at its next frame.
////
//// Like the sidebar's read, the home's runs in the component's own process
//// and the runtime waits for it. A catalogue page is a query that returns at
//// once, and the registry's own call bounds a slow one. A read that is
//// allowed to take longer, opening a saved session, will run in its own
//// process when that arrives, since the page cannot be frozen behind it.
////
//// The component draws a list and takes no input. Its view attaches no
//// handler, its message type holds no command and the daemon's socket drops
//// every browser frame (`client/daemon/ui_socket.home_accepts`), so nothing a
//// browser sends reaches `update`. Every name and path is a catalogue field,
//// drawn as a text node (`view/home_table`, `view/sidebar`). The page names
//// the principal and the most the page may do in its top bar, so a person who
//// holds two homes can tell them apart.
////
//// ## Transitions
////
//// <!-- transitions: home.Status -->
////
//// | state | a read lists | a read is unreadable | a read is closed | the interval passes |
//// | --- | --- | --- | --- | --- |
//// | `Connecting` | `Connected` with the list | stays `Connecting`, nothing drawn | `Ended` | asks again |
//// | `Connected` | stays `Connected` with the new list | stays `Connected` with the last list | `Ended` | asks again |
//// | `Ended` | stays `Ended` | stays `Ended` | stays `Ended` | asks nothing |

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/server_component
import web_view/ending.{type Ending}
import web_view/sessions.{type Entry, type Group}
import web_view/view/ended
import web_view/view/home_bar
import web_view/view/home_table
import web_view/view/shell
import web_view/view/sidebar

/// How long the page's list stands before it is read again, in milliseconds.
/// The list changes when a session is created, renamed, archived or opened,
/// which is rare, and a read is a catalogue query. It is the same interval the
/// session page's sidebar keeps (`component.sessions_refresh_ms`).
pub const refresh_ms = 30_000

/// The most the page was minted to do. The daemon's link carries it and the
/// top bar says it in fixed words; it decides nothing on this page, which only
/// lists.
pub type Ceiling {
  /// The page was minted for an operator's use.
  OperatorCeiling

  /// The page was minted to read.
  ObserverCeiling
}

/// What one read of the principal's sessions gave.
pub type Listing {
  /// The sessions the principal may see now, in the catalogue's order.
  Listed(entries: List(Entry))

  /// The registry did not answer. The page keeps the list it has and draws
  /// nothing about it, since a slow registry is no reason to say anything.
  Unread

  /// The page can no longer be served, and why. The page draws the ending and
  /// does not ask again.
  Closed(ending: Ending)
}

/// What the daemon supplies when it starts the component.
pub type Start {
  Start(
    /// The principal's display name, a catalogue field, for the top bar.
    name: String,
    /// What the page was minted to do.
    ceiling: Ceiling,
    /// The interval between reads, in milliseconds. Production passes
    /// `refresh_ms`; a test passes a short one.
    refresh_ms: Int,
    /// Reads the principal's sessions. It runs in the component's own process,
    /// when the page opens and every `refresh_ms` after, and it must not run
    /// long: the page's runtime waits for it.
    sessions: fn() -> Listing,
  )
}

/// What the page says about its own standing.
pub type Status {
  /// No read has answered yet.
  Connecting

  /// A read listed the sessions, and nothing since has ended the page.
  Connected

  /// A read said the page can no longer be served. The top bar words it with
  /// `ending`.
  Ended(ending: Ending)
}

/// The component's state: what it was started with, the groups it draws and
/// where it stands, and the subject its refresh timer fires on.
pub opaque type Model {
  Model(
    start: Start,
    /// The entries of the last list, grouped for the sidebar and the table.
    /// It is built when a read lists, so a render regroups nothing.
    groups: List(Group),
    status: Status,
    /// The refresh timer's subject, known once the runtime has made it.
    timer: Option(Subject(Nil)),
  )
}

/// Everything the component can be told. None is a browser's: each is sent by
/// an effect the component ran, or by its own timer.
pub type Msg {
  /// The runtime made the refresh timer's subject. The first read and the
  /// first arming follow.
  TimerReady(timer: Subject(Nil))

  /// The refresh interval passed.
  Ticked

  /// The answer to a read.
  Answered(listing: Listing)
}

/// The application the daemon's socket starts, one per home page.
///
/// ## Examples
///
/// ```gleam
/// // lustre.start_server_component(home.app(), start)
/// ```
pub fn app() -> lustre.App(Start, Model, Msg) {
  lustre.application(init, update, view)
}

/// A component for `start`, before its timer exists: `init` without its
/// effects, for a test that drives it through `update`.
///
/// ## Examples
///
/// ```gleam
/// // let model = home.new(start)
/// ```
pub fn new(start: Start) -> Model {
  Model(start:, groups: [], status: Connecting, timer: None)
}

/// The component's first state and the one subscription it runs for its life:
/// the refresh timer, whose subject the runtime makes.
///
/// ## Examples
///
/// ```gleam
/// // lustre.application(home.init, home.update, home.view)
/// ```
pub fn init(start: Start) -> #(Model, Effect(Msg)) {
  #(new(start), wire())
}

// Creates the timer's subject and selects it, in the component's own process,
// which owns both. The subject is handed to `update` so it can arm it.
fn wire() -> Effect(Msg) {
  use dispatch, timer <- server_component.select
  dispatch(TimerReady(timer))
  process.new_selector()
  |> process.select_map(timer, fn(_) { Ticked })
}

/// Applies one message.
///
/// Wiring the timer and every tick do the same two things, in the same order:
/// read the list, then arm the timer for the next read. A page that ended arms
/// nothing, so the last read is the last.
///
/// ## Examples
///
/// ```gleam
/// // let #(model, effect) = home.update(model, home.Ticked)
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    TimerReady(timer:) -> {
      let model = Model(..model, timer: Some(timer))
      #(model, refreshing(model))
    }

    // An ended page is not asked again, so its timer is left to lapse.
    Ticked ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> #(model, refreshing(model))
      }

    Answered(listing:) -> #(answered(model, listing), effect.none())
  }
}

// The read, and then the arming of the timer for the next one. Both are
// one effect so that the read is made before the interval starts. A read that
// answers `Closed` arms nothing: that page has ended, so the read is its last.
fn refreshing(model: Model) -> Effect(Msg) {
  use dispatch <- effect.from
  let listing = model.start.sessions()
  dispatch(Answered(listing))

  case listing, model.timer {
    Closed(..), _ -> Nil
    _, None -> Nil
    _, Some(timer) -> {
      let _ = process.send_after(timer, model.start.refresh_ms, Nil)
      Nil
    }
  }
}

// What a read changes. A list replaces the groups, so a session that is gone
// is gone from the page, and a closed page keeps the last list it drew with
// the notice beside it, as a session's page keeps its last capture.
fn answered(model: Model, listing: Listing) -> Model {
  case listing {
    Listed(entries:) ->
      Model(
        ..model,
        groups: sessions.grouped(list.take(entries, sessions.listed_limit), ""),
        status: Connected,
      )
    Unread -> model
    Closed(ending:) -> Model(..model, status: Ended(ending:))
  }
}

/// The groups the page draws: the principal's sessions by workspace, newest
/// first. A page that has read nothing has none.
///
/// ## Examples
///
/// ```gleam
/// assert home.groups(home.new(start)) == []
/// ```
pub fn groups(model: Model) -> List(Group) {
  model.groups
}

/// Where the page stands.
///
/// ## Examples
///
/// ```gleam
/// assert home.status(home.new(start)) == home.Connecting
/// ```
pub fn status(model: Model) -> Status {
  model.status
}

/// The page: the frame a session's page draws, with the principal's sessions
/// in the sidebar and as tables in the centre, and no strand panel. Its top
/// bar names the page, the principal and the most the page may do, and carries
/// the notice of a page that ended.
///
/// ## Examples
///
/// ```gleam
/// // element.to_string(home.view(model))
/// ```
pub fn view(model: Model) -> Element(Msg) {
  shell.view(
    shell.Home,
    home_bar.view(
      name: model.start.name,
      ceiling: ceiling_words(model.start.ceiling),
      status: status_words(model.status),
      notice: ended.home(ended_ending(model.status)),
    ),
    shell_sidebar(model.groups),
    [home_table.view(model.groups)],
    element.none(),
    0,
    "",
  )
}

// The sidebar's column, or the frame's word that there is none.
fn shell_sidebar(groups: List(Group)) -> shell.Sidebar(Msg) {
  case groups {
    [] -> shell.Unlisted
    [_, ..] -> shell.Listed(sidebar.home(groups))
  }
}

fn ceiling_words(ceiling: Ceiling) -> String {
  case ceiling {
    OperatorCeiling -> "operator"
    ObserverCeiling -> "read-only"
  }
}

fn status_words(status: Status) -> String {
  case status {
    Connecting -> "connecting"
    Connected -> "connected"
    Ended(_) -> "disconnected"
  }
}

// The ending a page that ended draws a notice for.
fn ended_ending(status: Status) -> Option(Ending) {
  case status {
    Connecting | Connected -> None
    Ended(ending:) -> Some(ending)
  }
}
