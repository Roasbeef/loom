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
//// once, and the registry's own call bounds a slow one. Opening a saved
//// session is allowed to take longer, so it does not run there: `Start.resume`
//// starts the daemon's own task and returns at once, and the task delivers its
//// answer as a message when it finishes, so the page keeps drawing while a
//// session starts.
////
//// What each running session is doing is not in the catalogue. Every list that
//// answers starts a second read, `Start.activity`, for the running sessions it
//// lists (at most `activity_limit`): the daemon asks each session from a task
//// of its own, under the deadline `sessions.activity` has (protocol-change/050),
//// and hands back one state word for each as `Observed`. The page draws the
//// list first and the words when they arrive, and a session the daemon could
//// not ask keeps a row that says only that it is resident. The runtime never
//// waits for it: `activity` returns at once, as `resume` does.
////
//// The component draws a list and takes two inputs (protocol-change/065, the
//// second and third pull requests): the press of a running session's row, in
//// the table or in the sidebar, and, on a page minted to operate, the press of
//// a saved session's row. Their messages are `Opening` and `Resuming`, whose
//// session is the catalogue's identity drawn into the tree by the server, so
//// the browser's event names only the path it fired at and never a session.
//// The daemon's socket admits a click beneath `table_path` or `sidebar_path`
//// and drops every other frame (`client/daemon/ui_socket.home_accepts`), and
//// `Start.open` and `Start.resume` make the daemon check the principal's
//// membership, and for a resume its role, again before it mints a ticket. The
//// answer is a ticket's address, which the hidden `<loom-switch>` element
//// navigates to, or a refusal worded in the page's notice. While one resume is
//// out the page holds its session and asks for no other, so a second press
//// asks nothing. Every name and path is a catalogue field, drawn as a text
//// node (`view/home_table`, `view/sidebar`). The page names the principal and
//// the most the page may do in its top bar, so a person who holds two homes
//// can tell them apart.
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
////
//// A resume is a second, smaller machine inside `Connected`:
////
//// | resume | a saved row is pressed | the daemon answers | the page ends |
//// | --- | --- | --- | --- |
//// | none out | starts one, if the page may operate | nothing to answer | stays none |
//// | one out | asks nothing | clears it, then departs or says why | clears it |

import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import lustre/server_component
import web_view/ending.{type Ending}
import web_view/renames
import web_view/sessions.{type Activity, type Entry, type Group, Live}
import web_view/view/ended
import web_view/view/heading
import web_view/view/home_bar
import web_view/view/home_table
import web_view/view/resume.{type Resume}
import web_view/view/shell
import web_view/view/sidebar
import web_view/view/switch

/// The Lustre event path of the sidebar on the home page: it is the second
/// child of the page's frame (`view/shell`), as on a session's page
/// (`component.sidebar_path`). Every handler beneath it is one running
/// session's row, which asks the daemon for a ticket to open that session. The
/// home's socket admits a click beneath this path and beneath `table_path` and
/// no other event; `home_test` fails if the view moves either region.
pub const sidebar_path = "0\t1"

/// The Lustre event path of the sessions lists on the home page: the centre
/// column is the third child of the frame, and the table's section is the
/// centre's second child, after the notice's place. Every handler beneath it is
/// one running session's name, which asks the daemon for a ticket to open that
/// session.
pub const table_path = "0\t2\t1"

/// How long the page's list stands before it is read again, in milliseconds.
/// The list changes when a session is created, renamed, archived or opened,
/// which is rare, and a read is a catalogue query. It is the same interval the
/// session page's sidebar keeps (`component.sessions_refresh_ms`).
pub const refresh_ms = 30_000

/// The most running sessions one activity read names. It is the daemon's own
/// bound on `sessions.activity` (protocol-change/050): each answer is one
/// row of at most 2,400 bytes under one 2,000 ms deadline, and the reply holds
/// 24. A principal with more running sessions than this sees the activity of
/// the first ones in the order the page draws them, and the rest show only
/// that they are resident.
pub const activity_limit = 24

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
    /// Asks the daemon for a ticket to open the named session: the daemon
    /// checks that the page is open, that its principal holds the session and
    /// that a process runs it, and mints a ticket with the page's own ceiling
    /// and deadline. It runs in the component's process when a row is
    /// pressed, and it must not run long: the page's runtime waits for it.
    open: fn(String) -> sessions.Answer,
    /// Asks the daemon to resume the named saved session and mint a ticket for
    /// it: the daemon checks the page, its ceiling and the principal's role in
    /// the session, opens it, waits for it to become resident and mints. It
    /// must return at once, and the answer goes to the function it is given,
    /// from the daemon's own task, as `Linked`'s message. A page whose ceiling
    /// is the observer's never calls it, and the daemon refuses if one did.
    resume: fn(String, fn(sessions.Answer) -> Nil) -> Nil,
    /// The wall-clock time in Unix milliseconds, which the rows' ages are
    /// counted from. It is read once for each list, in the component's
    /// process, and must return at once.
    now: fn() -> Int,
    /// Asks the daemon what the named running sessions are doing, at most
    /// `activity_limit` of them, all of which the page's own list holds. It
    /// must return at once, as `resume` must: the daemon asks each session from
    /// a task of its own, under its own deadline, and the answer goes to the
    /// function it is given, from that task, as `Observed`'s message. A session
    /// the daemon could not ask, or that was slow to answer, is left out of the
    /// answer, and its row says nothing about what it is doing.
    activity: fn(List(String), fn(List(#(String, Activity))) -> Nil) -> Nil,
    /// Asks the daemon to rename the named session, for the owner's page that
    /// submitted a row's rename form (protocol-change/066): the daemon checks
    /// that the page is open and was minted to operate, that its credential
    /// still authenticates as the daemon's owner, that the identity is a
    /// session its catalogue holds and that the name is one a display name may
    /// be, and then makes the registry's owner-checked rename. It must return
    /// at once, as `resume` must: the answer goes to the function it is given,
    /// from the daemon's own task, as `RenameAnswered`'s message. It is `None`
    /// unless the page's principal is the daemon's owner on a page minted to
    /// operate, and the daemon checks that again when it runs.
    rename: Option(fn(String, String, fn(renames.Answer) -> Nil) -> Nil),
  )
}

/// What the rename control is doing on the page. It is the page's own state and
/// nothing the daemon records.
pub type Edit {
  /// No row's rename form is open.
  NotEditing

  /// The form of one row is open, and the control says where it stands:
  /// `Ready` waits for a name, `Asking` has a request with the daemon, and
  /// `Refused` words why the last one stored nothing. Only one row is open at a
  /// time, so opening another closes this one.
  Editing(session: String, control: renames.Control)
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
    /// What the daemon last said each running session is doing, by identity.
    /// An answer replaces it whole, so a session that stopped running leaves it
    /// at the next one.
    activity: Dict(String, Activity),
    /// The time the last list was read, in Unix milliseconds, which the rows'
    /// ages are counted from.
    now: Int,
    status: Status,
    /// The refresh timer's subject, known once the runtime has made it.
    timer: Option(Subject(Nil)),
    /// The ticket exchange the daemon minted for the session the person
    /// chose, which `<loom-switch>` navigates to. It stays until the next
    /// press replaces it: the ticket is single use and lives 60 seconds.
    departure: Option(String),
    /// What the page last said about a press, in the daemon's fixed words: that
    /// it is opening a session, or why it could not.
    notice: Option(String),
    /// The saved session whose resume is out, if one is. It is set when a press
    /// asks the daemon and cleared by the answer, so a second press while it is
    /// set asks nothing.
    resuming: Option(String),
    /// Which row's rename form is open, and where it stands.
    edit: Edit,
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

  /// The daemon's answer to the activity read a list started: one state for
  /// each session it could ask. It is the effect's own message, dispatched from
  /// the daemon's task, and no handler carries it.
  Observed(rows: List(#(String, Activity)))

  /// A running session's row was pressed: ask the daemon for a ticket to open
  /// it. The identity is the catalogue's, fixed when the tree was drawn, and
  /// the daemon decides whether the page's principal may have it.
  Opening(session: String)

  /// A saved session's row was pressed: ask the daemon to resume it. Only a
  /// page minted to operate draws the row as a button, and the daemon checks
  /// the page's ceiling and the principal's role again. The identity is the
  /// catalogue's, fixed when the tree was drawn.
  Resuming(session: String)

  /// The daemon answered a request to open or resume a session. It is the
  /// effect's own message, dispatched from the component's process or from the
  /// daemon's task, and no handler carries it, so a browser cannot send one.
  Linked(answer: sessions.Answer)

  /// A row's Rename button was pressed: open that row's form. Only an owner's
  /// page draws the button, and the daemon checks again when a name is sent. The
  /// identity is the catalogue's, fixed when the tree was drawn.
  EditRequested(session: String)

  /// The open form's Cancel button was pressed: close it.
  EditCancelled

  /// A row's rename form was submitted with this text. The identity is the
  /// catalogue's, fixed when the tree was drawn, and the text is the browser's
  /// and nothing else is: the daemon decides whether the page's principal may
  /// rename and whether the name is one a display name may be.
  Renaming(session: String, name: String)

  /// The daemon answered a request to rename. It is the effect's own message,
  /// dispatched from the daemon's task, and no handler carries it, so a browser
  /// cannot put a name in the page that the daemon did not store.
  RenameAnswered(answer: renames.Answer)
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
  Model(
    start:,
    groups: [],
    activity: dict.new(),
    now: 0,
    status: Connecting,
    timer: None,
    departure: None,
    notice: None,
    resuming: None,
    edit: NotEditing,
  )
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

    // A list that answered starts the read of what its running sessions are
    // doing. The read is the daemon's own task and returns at once, so the
    // list is drawn now and the activity words arrive with `Observed`.
    Answered(listing:) -> {
      let model = answered(model, listing)
      #(model, observing(model))
    }

    // An ended page keeps the activity it last drew, as it keeps its list.
    Observed(rows:) ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> #(
          Model(..model, activity: dict.from_list(rows)),
          effect.none(),
        )
      }

    // A press asks the daemon in the component's own process. An ended page
    // asks nothing: its principal's access is gone, and the daemon would
    // refuse.
    Opening(session:) ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> #(
          Model(..model, notice: Some("Asking to open it.")),
          asking(model.start.open, session),
        )
      }

    // A saved row's press asks the daemon to resume it, from the daemon's own
    // task so the runtime stays free. A page that may not operate, one that
    // ended, and one whose resume is already out ask nothing; the row of such
    // a page has no handler, so these arms are the second layer.
    Resuming(session:) ->
      case model.start.ceiling, model.status, model.resuming {
        OperatorCeiling, Connected, None -> #(
          Model(
            ..model,
            notice: Some("Opening that session. It may take a moment."),
            resuming: Some(session),
          ),
          resuming(model.start.resume, session),
        )
        OperatorCeiling, Connected, Some(_)
        | OperatorCeiling, Connecting, _
        | OperatorCeiling, Ended(_), _
        | ObserverCeiling, _, _
        -> #(model, effect.none())
      }

    // The rename form of one row opens, on a page that may rename. Opening a
    // form while a request is out would hide that request's answer, so it is
    // ignored until the request ends.
    EditRequested(session:) ->
      case model.start.rename, model.status, model.edit {
        Some(_), Connected, NotEditing
        | Some(_), Connected, Editing(_, renames.Ready)
        | Some(_), Connected, Editing(_, renames.Refused(..))
        | Some(_), Connected, Editing(_, renames.Done)
        | Some(_), Connected, Editing(_, renames.Withheld)
        -> #(
          Model(..model, edit: Editing(session, renames.Ready)),
          effect.none(),
        )
        Some(_), Connected, Editing(_, renames.Asking)
        | Some(_), Connecting, _
        | Some(_), Ended(_), _
        | None, _, _
        -> #(model, effect.none())
      }

    EditCancelled ->
      case model.edit {
        Editing(_, renames.Asking) | NotEditing -> #(model, effect.none())
        Editing(_, renames.Ready)
        | Editing(_, renames.Refused(..))
        | Editing(_, renames.Done)
        | Editing(_, renames.Withheld) -> #(
          Model(..model, edit: NotEditing),
          effect.none(),
        )
      }

    // A submit asks the daemon from the daemon's own task, so the runtime stays
    // free while the registry answers. It asks only for the row whose form is
    // open, and only once: a second submit while the request is out asks
    // nothing, and a page with no capability asks nothing at all.
    Renaming(session:, name:) ->
      case model.start.rename, model.edit {
        Some(ask), Editing(open, renames.Ready) if open == session -> #(
          Model(..model, edit: Editing(session, renames.Asking)),
          renaming(ask, session, name),
        )
        Some(ask), Editing(open, renames.Refused(..)) if open == session -> #(
          Model(..model, edit: Editing(session, renames.Asking)),
          renaming(ask, session, name),
        )
        Some(_), Editing(..) | Some(_), NotEditing | None, _ -> #(
          model,
          effect.none(),
        )
      }

    // The answer: a stored name replaces the row's in the page's own state at
    // once, the daemon's own word for it, and the next read confirms it; a
    // refusal is worded in the open form, in the reason's fixed words. An answer
    // that arrives when no request is out was not asked for and is dropped.
    RenameAnswered(answer:) ->
      case model.edit, answer {
        Editing(session, renames.Asking), renames.Renamed(name:) -> #(
          Model(
            ..model,
            edit: NotEditing,
            notice: Some("Renamed."),
            groups: renamed(model.groups, session, name),
          ),
          effect.none(),
        )
        Editing(session, renames.Asking), renames.Declined(reason:) -> #(
          Model(..model, edit: Editing(session, renames.Refused(reason))),
          effect.none(),
        )
        Editing(..), _ | NotEditing, _ -> #(model, effect.none())
      }

    // The answer: a ticket becomes the address `<loom-switch>` navigates to,
    // and a refusal is the page's notice in the reason's fixed words. Either
    // way no resume is out any longer.
    Linked(answer:) ->
      case answer {
        sessions.Ticketed(path:) -> #(
          Model(
            ..model,
            departure: Some(path),
            notice: Some("Opening that session."),
            resuming: None,
          ),
          effect.none(),
        )
        sessions.Declined(reason:) -> #(
          Model(
            ..model,
            notice: Some(sessions.reason_words(reason)),
            resuming: None,
          ),
          effect.none(),
        )
      }
  }
}

// Starts the daemon's rename task and returns at once; the task's answer
// arrives later as `RenameAnswered`, dispatched from the task's own process.
fn renaming(
  rename: fn(String, String, fn(renames.Answer) -> Nil) -> Nil,
  session: String,
  name: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  rename(session, name, fn(answer) { dispatch(RenameAnswered(answer)) })
}

// The groups with one session's name replaced.
fn renamed(groups: List(Group), session: String, name: String) -> List(Group) {
  list.map(groups, fn(group) {
    sessions.Group(
      ..group,
      entries: list.map(group.entries, fn(entry) {
        case entry.id == session {
          True -> sessions.Entry(..entry, name:)
          False -> entry
        }
      }),
    )
  })
}

// Starts the daemon's task and returns at once; the task's answer arrives
// later as `Linked`, dispatched from the task's own process. Lustre's dispatch
// sends to the runtime's mailbox, so it is safe to call from there.
fn resuming(
  resume: fn(String, fn(sessions.Answer) -> Nil) -> Nil,
  session: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  resume(session, fn(answer) { dispatch(Linked(answer)) })
}

// Starts the activity read for the running sessions the page lists, in the
// order it draws them and no more than `activity_limit`, and returns at once;
// the answer arrives later as `Observed`, dispatched from the daemon's task as
// `Linked` is. A page with no running session asks nothing, and a page that
// ended asks nothing more.
fn observing(model: Model) -> Effect(Msg) {
  let running =
    list.flat_map(model.groups, fn(group) { group.entries })
    |> list.filter(fn(entry) { entry.residency == Live })
    |> list.take(activity_limit)
    |> list.map(fn(entry) { entry.id })
  case running, model.status {
    [], _ | _, Ended(_) | _, Connecting -> effect.none()
    [_, ..], Connected -> {
      use dispatch <- effect.from
      model.start.activity(running, fn(rows) { dispatch(Observed(rows)) })
    }
  }
}

// The daemon's answer, in the component's process, as a message.
fn asking(open: fn(String) -> sessions.Answer, session: String) -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(Linked(open(session)))
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
        now: model.start.now(),
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
/// in the sidebar and as lists in the centre, and no strand panel. Its top
/// bar names the page, the principal and the most the page may do, and carries
/// the notice of a page that ended.
///
/// The centre's children are, in order, the notice of the last press (an
/// empty node when there is none, so the list keeps its path), the lists
/// (`table_path`), and the hidden `<loom-switch>` element, last so that no
/// admitted path moves with it.
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
      tone: status_tone(model.status),
      notice: ended.home(ended_ending(model.status)),
    ),
    shell_sidebar(model),
    [
      press_notice(model.notice),
      home_table.view(
        model.groups,
        model.activity,
        model.now,
        Opening,
        resume_offer(model),
        rename_offer(model),
      ),
      switch.view(model.departure),
    ],
    element.none(),
    0,
    "",
  )
}

// What the page offers for a saved row: a button on a page minted to operate,
// with the session whose resume is out, and text otherwise.
fn resume_offer(model: Model) -> Resume(Msg) {
  case model.start.ceiling {
    OperatorCeiling -> resume.Offered(Resuming, model.resuming)
    ObserverCeiling -> resume.Never
  }
}

// What the table offers for renaming a row: a button on a page whose daemon
// handed it the capability, and nothing otherwise.
fn rename_offer(model: Model) -> home_table.Rename(Msg) {
  case model.start.rename {
    None -> home_table.Never
    Some(_) ->
      home_table.Offered(
        edit: EditRequested,
        cancel: EditCancelled,
        submit: submitting,
        open: case model.edit {
          NotEditing -> None
          Editing(session:, control:) ->
            Some(home_table.Open(session:, control:))
        },
      )
  }
}

// A row's form submit as the message that names the session the server drew
// into the tree and carries the one text field the form has. Any other field, a
// repeated one or a missing one refuses the event, as the control forms do.
fn submitting(session: String) -> attribute.Attribute(Msg) {
  event.on("submit", written(session)) |> event.prevent_default
}

fn written(session: String) -> decode.Decoder(Msg) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )
  case fields {
    [#("text", name)] -> decode.success(Renaming(session, name))
    _ -> decode.failure(Renaming(session, ""), "rename form")
  }
}

fn form_field() -> decode.Decoder(#(String, String)) {
  use name <- decode.field(0, decode.string)
  use value <- decode.field(1, decode.string)
  decode.success(#(name, value))
}

// The sidebar's column, or the frame's word that there is none.
fn shell_sidebar(model: Model) -> shell.Sidebar(Msg) {
  case model.groups {
    [] -> shell.Unlisted
    [_, ..] as groups ->
      shell.Listed(sidebar.home(groups, Opening, resume_offer(model)))
  }
}

// The words of the last press, or the empty node that keeps the table's place.
fn press_notice(notice: Option(String)) -> Element(Msg) {
  case notice {
    None -> element.none()
    Some(words) ->
      html.p([attribute.class("home-notice"), attribute.role("status")], [
        html.text(words),
      ])
  }
}

fn ceiling_words(ceiling: Ceiling) -> String {
  case ceiling {
    OperatorCeiling -> "operator"
    ObserverCeiling -> "read-only"
  }
}

// The pill's colour follows the standing, as a session page's does.
fn status_tone(status: Status) -> heading.Tone {
  case status {
    Connecting -> heading.Pending
    Connected -> heading.Live
    Ended(_) -> heading.Closed
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
