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
//// The component draws a list and takes three inputs (protocol-change/065, the
//// second, third and fourth pull requests): the press of a running session's
//// row, in the table or in the sidebar, on a page minted to operate the press of
//// a saved session's row, and on the owner's such page the form that creates a
//// session (`Start.create`, below). Their messages are `Opening` and `Resuming`, whose
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
//// Creating a session is the owner's act. `Start.create` is `Some` only for the
//// owner's page minted to operate (the daemon decides, in
//// `ui_socket.home_create_capability`), and a page without it draws nothing and ignores
//// the messages. With it, each workspace's heading has a "New session" button
//// (`Choosing`) that opens one form under it: a name, a checkbox, Create and
//// Cancel (`view/create`). Submitting it (`Creating`) asks the daemon through
//// `Start.create`, which starts the daemon's own task and returns, and the
//// answer arrives as `Created`: a ticket departs for the new session through the
//// same hidden `<loom-switch>` a switch uses, and a refusal is the reason's
//// fixed words (`creations.reason_words`). While one creation is out the form is
//// disabled and a second submit asks nothing. The workspace is the catalogue's
//// text carried by the message the tree was drawn with, never a field the
//// browser fills, and the daemon checks again that the owner already holds a
//// session in it.
////
//// The page also lists the browsers signed in as its principal and lets the
//// person end them (protocol-change/065, the eighth pull request). Each list
//// that is read starts a read of the principal's sign-ins (`Start.signins`), an
//// answer from the same registry, which the page draws below the sessions as
//// one row for each login: a fingerprint, when it was made, when it was last
//// used and when it ends, with the one this page belongs to marked
//// (`Start.login`). A row's "Sign out" and the "Sign out everywhere" button ask
//// the daemon (`Start.sign_out`, `Start.sign_out_all`), which ends the login's
//// row and with it every page that login minted, at that page's next frame, and
//// answers `Revoked`; the page then reads its list again. A page a `loom ui`
//// exchange opened (a fresh home) is also handed `Start.device`, which asks the
//// daemon for a link that signs in another device and shows it once; a home the
//// bookmark resumed has none and draws no control, and the daemon refuses the
//// request from one. A page opened by a remembered login draws the bookmark as
//// text (`Start.bookmark`). The sign-in rows' messages name a fingerprint the
//// server drew into the tree, so the browser's event names only the path it
//// fired at and never a login, and the daemon answers only for the principal's
//// own.
////
//// The owner's page also draws an "Admin" button in its top bar
//// (protocol-change/065, the fifth pull request). `Start.admin` is `Some` only
//// for the owner's page minted to operate and opened by a `loom ui` exchange (the
//// daemon decides, in `ui_socket.home_admin_capability`), and a page without it
//// draws nothing and ignores the message. Pressing it (`AdminRequested`) starts
//// the daemon's own task, which mints a ticket for an admin page, and the answer
//// arrives as `AdminLinked`: the ticket's address departs through the same
//// hidden `<loom-switch>`, or a refusal is the reason's fixed words.
////
//// ## Flow
////
//// `app` → `init` → `update` → `refreshing` → `answered` → `view`
////
//// 1. `init` starts the component and `wire` makes the refresh timer; the
////    timer's subject arrives as `TimerReady`, and `update` answers it, and
////    every `Ticked` after it, with `refreshing`.
//// 2. `refreshing` asks `Start.sessions` for the list and `Start.signins` for
////    the sign-ins, hands the answers to `answered` and `SigninsRead`, and arms
////    the timer for the next read.
//// 3. `answered` replaces the groups, and `observing` starts the activity read
////    for the running sessions it listed.
//// 4. A press is a message `update` handles, one of `Opening`, `Resuming`,
////    `Choosing`, `Creating`, `Renaming`, `AdminRequested`, `SigningOut`,
////    `SigningOutAll` or `AddingDevice`, each of which asks the daemon through
////    its own `Start` field and leaves the answer to the effect's message.
//// 5. `view` draws the groups through `shell_sidebar`, the offers
////    (`resume_offer`, `rename_offer`, `create_offer`, `admin_offer`), the
////    sign-ins and `press_notice`.
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
////
//// A creation is a third, in `Connected` and only on a page with `Start.create`:
////
//// | form | a workspace's button | the form is submitted | the daemon answers | Cancel |
//// | --- | --- | --- | --- | --- |
//// | `Idle` | `Composing` that workspace | asks nothing | nothing to answer | stays `Idle` |
//// | `Composing(w)` | moves to the pressed workspace | asks the daemon if it is `w`'s form, then `Waiting(w)` | nothing to answer | `Idle` |
//// | `Waiting(w)` | asks nothing | asks nothing | departs and `Idle`, or says why and `Composing(w)`, or `Idle` for a session made and not opened | stays `Waiting(w)` |

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
import web_view/creations.{type Sharing}
import web_view/ending.{type Ending}
import web_view/renames
import web_view/sessions.{type Activity, type Entry, type Group, Live}
import web_view/signins.{type Signin}
import web_view/view/create.{type Create}
import web_view/view/ended
import web_view/view/heading
import web_view/view/home_bar
import web_view/view/home_table
import web_view/view/resume.{type Resume}
import web_view/view/shell
import web_view/view/sidebar
import web_view/view/signins as signins_view
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

/// The Lustre event path of the sign-ins region on the home page: the centre
/// column's third child, after the sessions. Every handler beneath it is one of
/// the page's own sign-in controls: a row's "Sign out", "Sign out everywhere",
/// and on a fresh home "Sign in another device" and its "Done". The home's
/// socket admits a click beneath it for every home, whatever its ceiling, and
/// `home_test` fails if the view moves the region.
pub const signins_path = "0\t2\t2"

/// The Lustre event path of the "Admin" button on the owner's home: the top bar
/// is the first child of the frame, and the button is the bar's sixth child,
/// after the brand, the title, the principal, the status and the notice's place
/// (`view/home_bar`). It is the only handler in the bar, and the home's socket
/// admits a click at exactly this path and only for the owner's home that was
/// handed the capability (`client/daemon/ui_socket.home_admin_accepts`).
/// `home_test` fails if the view moves it.
pub const admin_path = "0\t0\t5"

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
    /// Asks the daemon to create a session in the named workspace with the
    /// typed name and sharing, and mint a ticket for its page
    /// (protocol-change/065, the fourth pull request). It is `Some` only for the
    /// owner's page minted to operate, and then it is the page's whole offer: a
    /// page with `None` draws no control and ignores every creation message. It
    /// must return at once, and the answer goes to the function it is given,
    /// from the daemon's own task, as `Created`'s message. The daemon checks the
    /// page, its ceiling, the principal and the workspace again, whatever this
    /// page said.
    create: Option(
      fn(String, String, Sharing, fn(creations.Answer) -> Nil) -> Nil,
    ),
    /// Asks the daemon to rename the named session, for the owner's page that
    /// submitted a row's rename form (protocol-change/067): the daemon checks
    /// that the page is open and was minted to operate, that its credential
    /// still authenticates as the daemon's owner, that the identity is a
    /// session its catalogue holds and that the name is one a display name may
    /// be, and then makes the registry's owner-checked rename. It must return
    /// at once, as `resume` must: the answer goes to the function it is given,
    /// from the daemon's own task, as `RenameAnswered`'s message. It is `None`
    /// unless the page's principal is the daemon's owner on a page minted to
    /// operate, and the daemon checks that again when it runs.
    rename: Option(fn(String, String, fn(renames.Answer) -> Nil) -> Nil),
    /// Reads the principal's sign-ins, with the page's own credential, which the
    /// registry authenticates again. It runs in the component's process with the
    /// list's read, and must not run long.
    signins: fn() -> signins.Listing,
    /// The fingerprint of the browser login this page belongs to, if it does,
    /// which the list marks as "This browser".
    login: Option(String),
    /// The address the person keeps to come back, when the page was opened by a
    /// remembered login: the daemon's address and the login's bookmark path.
    bookmark: Option(String),
    /// Ends one of the principal's own sign-ins, named by fingerprint: the daemon
    /// checks the page, then asks the registry, which finds the login among the
    /// principal's own and no other. It runs in the component's process when a
    /// press asks, and must not run long.
    sign_out: fn(String) -> signins.Answer,
    /// Ends every sign-in of the principal.
    sign_out_all: fn() -> signins.Answer,
    /// Asks the daemon for a link that signs in another device. It is `Some`
    /// only for a page a `loom ui` exchange opened, and the daemon checks that
    /// again, and the credential's allowance, whatever this page said.
    device: Option(fn() -> signins.Answer),
    /// Asks the daemon to mint a ticket for the admin page
    /// (protocol-change/065, the fifth pull request). It is `Some` only for the
    /// owner's page minted to operate and opened by a `loom ui` exchange, and
    /// then it is the page's whole offer: a page with `None` draws no button and
    /// ignores the message. It must return at once, and the answer goes to the
    /// function it is given, from the daemon's own task, as `AdminLinked`'s
    /// message. The daemon checks the page, its ceiling, the credential and the
    /// owner again, whatever this page said.
    admin: Option(fn(fn(sessions.Answer) -> Nil) -> Nil),
  )
}

/// Where a device link stands on the page.
pub type Link {
  /// No link has been asked for, or the last one was dismissed.
  NoLink

  /// A request is with the daemon.
  AskingLink

  /// A link was made, which the page shows once. It is the whole address.
  ShownLink(address: String)

  /// The last request was refused, in the reason's fixed words.
  RefusedLink(words: String)
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
    /// Where the person is in making a session: no form, a form open under one
    /// workspace, or that workspace's creation out. Only a page with
    /// `Start.create` leaves `Idle`.
    creating: create.State,
    /// Which row's rename form is open, and where it stands.
    edit: Edit,
    /// The principal's sign-ins as the last read gave them.
    signins: List(Signin),
    /// Where a device link stands.
    link: Link,
    /// What the page last said about a sign-out, in fixed words.
    signin_notice: Option(String),
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

  /// The "New session" button under this workspace was pressed: open its form.
  /// The workspace is the catalogue's text, fixed when the tree was drawn. A page
  /// with no `Start.create` ignores it.
  Choosing(workspace: String)

  /// The form's Cancel was pressed: close it.
  Cancelled

  /// The open form was submitted: ask the daemon to create the session. The
  /// workspace is the one the form was drawn under; the name and the sharing are
  /// what the browser's event listed (`view/create.fields`). The page asks only
  /// for the form that is open, and only once.
  Creating(workspace: String, name: String, sharing: Sharing)

  /// The daemon answered a request to create a session. It is the effect's own
  /// message, dispatched from the daemon's task, and no handler carries it, so
  /// a browser cannot send one.
  Created(answer: creations.Answer)

  /// The "Admin" button was pressed: ask the daemon for a ticket to an admin
  /// page. A page with no `Start.admin` ignores it.
  AdminRequested

  /// The daemon answered a request for an admin page. It is the effect's own
  /// message, dispatched from the daemon's task, and no handler carries it, so
  /// a browser cannot send one.
  AdminLinked(answer: sessions.Answer)

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

  /// A read of the principal's sign-ins answered. It is the effect's own
  /// message, and no handler carries it.
  SigninsRead(listing: signins.Listing)

  /// A row's "Sign out" was pressed. The fingerprint is the daemon's, fixed
  /// when the tree was drawn; the daemon finds it among the principal's own
  /// sign-ins and no others.
  SigningOut(fingerprint: String)

  /// "Sign out everywhere" was pressed.
  SigningOutAll

  /// The daemon answered a request to sign one browser out or all of them. It
  /// is the effect's own message, and no handler carries it.
  SignedOut(answer: signins.Answer, scope: SignOutScope)

  /// "Sign in another device" was pressed: ask the daemon for a link.
  AddingDevice

  /// The daemon answered the request for a link. It is the effect's own
  /// message, and no handler carries it, so a browser cannot put a link in the
  /// page that the daemon did not make.
  DeviceAnswered(answer: signins.Answer)

  /// The shown link's "Done" was pressed: hide it.
  DeviceDone
}

/// Which sign-outs the daemon answered, so the page's words say which.
pub type SignOutScope {
  /// One browser.
  OneBrowser

  /// Every browser.
  EveryBrowser
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
    creating: create.Idle,
    edit: NotEditing,
    signins: [],
    link: NoLink,
    signin_notice: None,
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

    // The button opens the form under its workspace, if the page may create and
    // no creation is out. Another workspace's button moves the form.
    Choosing(workspace:) ->
      case model.start.create, model.status, model.creating {
        Some(_), Connected, create.Idle
        | Some(_), Connected, create.Composing(_)
        -> #(
          Model(..model, creating: create.Composing(workspace), notice: None),
          effect.none(),
        )
        Some(_), Connected, create.Waiting(_)
        | Some(_), Connecting, _
        | Some(_), Ended(_), _
        | None, _, _
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

    Cancelled ->
      case model.creating {
        create.Composing(_) -> #(
          Model(..model, creating: create.Idle),
          effect.none(),
        )
        create.Idle | create.Waiting(_) -> #(model, effect.none())
      }

    // A submit asks the daemon from its own task so the runtime stays free. It is
    // honoured only for the form that is open, so a second submit while the
    // first is out, a submit for a form that is not drawn, and a page that may
    // not create ask nothing. These arms are the second layer: the daemon
    // refuses the same requests from the grant it holds.
    Creating(workspace:, name:, sharing:) ->
      case model.start.create, model.status, model.creating {
        Some(ask), Connected, create.Composing(open) if open == workspace -> #(
          Model(
            ..model,
            creating: create.Waiting(workspace),
            notice: Some("Creating the session. It may take a moment."),
          ),
          creation(ask, workspace, name, sharing),
        )
        Some(_), _, _ | None, _, _ -> #(model, effect.none())
      }

    // A ticket departs for the new session. A refusal says why in the daemon's
    // fixed words and puts the form back, except for a session that was created
    // and did not open, which exists and shows in the list at the next read.
    Created(answer:) ->
      case answer {
        creations.Ticketed(path:) -> #(
          Model(
            ..model,
            departure: Some(path),
            notice: Some("Opening the new session."),
            creating: create.Idle,
          ),
          effect.none(),
        )
        creations.Declined(reason:) -> #(
          Model(
            ..model,
            notice: Some(creations.reason_words(reason)),
            creating: reopened(model.creating, reason),
          ),
          effect.none(),
        )
      }

    // The button asks the daemon from its own task so the runtime stays free,
    // on a page that was handed the capability and is connected. The page that
    // has none draws no button, so this arm is the second layer.
    AdminRequested ->
      case model.start.admin, model.status {
        Some(ask), Connected -> #(
          Model(..model, notice: Some("Opening the admin page.")),
          opening_admin(ask),
        )
        Some(_), Connecting | Some(_), Ended(_) | None, _ -> #(
          model,
          effect.none(),
        )
      }

    // A ticket departs for the admin page, or the reason is the notice.
    AdminLinked(answer:) ->
      case answer {
        sessions.Ticketed(path:) -> #(
          Model(..model, departure: Some(path)),
          effect.none(),
        )
        sessions.Declined(reason:) -> #(
          Model(..model, notice: Some(sessions.reason_words(reason))),
          effect.none(),
        )
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

    // The sign-ins a read gave replace the page's own, and a read the registry
    // did not answer leaves them.
    SigninsRead(listing:) ->
      case listing {
        signins.Listed(rows:) -> #(
          Model(..model, signins: list.take(rows, signins.listed_limit)),
          effect.none(),
        )
        signins.Unread -> #(model, effect.none())
      }

    // A sign-out asks the daemon in the component's own process, for a page
    // that is connected. A page that ended asks nothing: its principal's access
    // is gone, and the daemon would refuse.
    SigningOut(fingerprint:) ->
      case model.status {
        Connected -> #(
          model,
          signing_out(fn() { model.start.sign_out(fingerprint) }, OneBrowser),
        )
        Connecting | Ended(_) -> #(model, effect.none())
      }
    SigningOutAll ->
      case model.status {
        Connected -> #(
          model,
          signing_out(model.start.sign_out_all, EveryBrowser),
        )
        Connecting | Ended(_) -> #(model, effect.none())
      }

    // The answer: the sign-in is gone, so the list is read again and the page
    // says so; a refusal is the reason's fixed words.
    SignedOut(answer:, scope:) ->
      case answer {
        signins.Revoked -> #(
          Model(
            ..model,
            signin_notice: Some(case scope {
              OneBrowser -> "Signed that browser out."
              EveryBrowser -> "Signed every browser out."
            }),
          ),
          reading_signins(model),
        )
        signins.Linked(_) -> #(model, effect.none())
        signins.Declined(reason:) -> #(
          Model(..model, signin_notice: Some(signins.reason_words(reason))),
          reading_signins(model),
        )
      }

    // The button asks for a link, if the page may make one and none is out. A
    // page with no capability, one that ended, and one whose request is already
    // out ask nothing; these arms are the second layer, since the daemon refuses
    // the same request from the grant it holds.
    AddingDevice ->
      case model.start.device, model.status, model.link {
        Some(ask), Connected, NoLink
        | Some(ask), Connected, ShownLink(_)
        | Some(ask), Connected, RefusedLink(_)
        -> #(
          Model(..model, link: AskingLink, signin_notice: None),
          asking_device(ask),
        )
        Some(_), Connected, AskingLink
        | Some(_), Connecting, _
        | Some(_), Ended(_), _
        | None, _, _
        -> #(model, effect.none())
      }
    DeviceAnswered(answer:) ->
      case model.link, answer {
        AskingLink, signins.Linked(address:) -> #(
          Model(..model, link: ShownLink(address)),
          reading_signins(model),
        )
        AskingLink, signins.Declined(reason:) -> #(
          Model(..model, link: RefusedLink(signins.reason_words(reason))),
          effect.none(),
        )
        AskingLink, signins.Revoked
        | NoLink, _
        | ShownLink(_), _
        | RefusedLink(_), _
        -> #(model, effect.none())
      }
    DeviceDone -> #(Model(..model, link: NoLink), effect.none())

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

// Asks the daemon to end sign-ins in the component's own process, and hands the
// answer back with the scope it was for. The registry call is bounded.
fn signing_out(
  ask: fn() -> signins.Answer,
  scope: SignOutScope,
) -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(SignedOut(ask(), scope))
}

// Asks the daemon for a device link in the component's own process.
fn asking_device(ask: fn() -> signins.Answer) -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(DeviceAnswered(ask()))
}

// Reads the principal's sign-ins again, after one changed.
fn reading_signins(model: Model) -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(SigninsRead(model.start.signins()))
}

// Starts the daemon's task that mints an admin ticket and returns at once; the
// answer arrives later as `AdminLinked`, dispatched from the task's own process.
fn opening_admin(ask: fn(fn(sessions.Answer) -> Nil) -> Nil) -> Effect(Msg) {
  use dispatch <- effect.from
  ask(fn(answer) { dispatch(AdminLinked(answer)) })
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

// Starts the daemon's creation task and returns at once; the answer arrives
// later as `Created`, dispatched from the task's own process.
fn creation(
  ask: fn(String, String, Sharing, fn(creations.Answer) -> Nil) -> Nil,
  workspace: String,
  name: String,
  sharing: Sharing,
) -> Effect(Msg) {
  use dispatch <- effect.from
  ask(workspace, name, sharing, fn(answer) { dispatch(Created(answer)) })
}

// Where the form stands after a refusal: open again under the workspace it was
// for, so the person can correct it, unless the session was made and did not
// open, which leaves nothing to correct.
fn reopened(state: create.State, reason: creations.Reason) -> create.State {
  case state, reason {
    create.Waiting(_), creations.NotOpened -> create.Idle
    create.Waiting(workspace), _ -> create.Composing(workspace)
    create.Idle, _ | create.Composing(_), _ -> state
  }
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

  // The sign-ins are read with the list, so a login that ended since the last
  // read leaves the page at the same pace a session does. A page whose read was
  // closed asks nothing more.
  case listing {
    Closed(..) -> Nil
    Listed(_) | Unread -> dispatch(SigninsRead(model.start.signins()))
  }

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
      title: "Home",
      name: model.start.name,
      ceiling: ceiling_words(model.start.ceiling),
      status: status_words(model.status),
      tone: status_tone(model.status),
      notice: ended.home(ended_ending(model.status)),
      trailing: admin_offer(model),
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
        create_offer(model),
      ),
      signins_view.view(
        model.signins,
        model.now,
        model.start.login,
        model.start.bookmark,
        SigningOut,
        SigningOutAll,
        device_offer(model),
        model.signin_notice,
      ),
      switch.view(model.departure),
    ],
    element.none(),
    0,
    "",
  )
}

// What the bar offers for opening the admin page: a button on the page whose
// daemon handed it the capability while it is connected, and an empty node
// otherwise, so the bar keeps its children.
fn admin_offer(model: Model) -> Element(Msg) {
  case model.start.admin, model.status {
    Some(_), Connected -> home_bar.admin(AdminRequested)
    Some(_), Connecting | Some(_), Ended(_) | None, _ -> element.none()
  }
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

// What the sign-ins region offers for a device link: the control on a page the
// daemon handed `Start.device`, and nothing otherwise.
fn device_offer(model: Model) -> signins_view.Device(Msg) {
  case model.start.device {
    None -> signins_view.Never
    Some(_) ->
      signins_view.Offered(
        press: AddingDevice,
        done: DeviceDone,
        shown: case model.link {
          ShownLink(address:) -> Some(address)
          NoLink | AskingLink | RefusedLink(_) -> None
        },
        asking: case model.link {
          AskingLink -> signins_view.Waiting
          NoLink | ShownLink(_) | RefusedLink(_) -> signins_view.Idle
        },
        refused: case model.link {
          RefusedLink(words:) -> Some(words)
          NoLink | AskingLink | ShownLink(_) -> None
        },
      )
  }
}

// What the page offers for making a session: the owner's operating page has
// `Start.create`, and every other page draws nothing.
fn create_offer(model: Model) -> Create(Msg) {
  case model.start.create {
    Some(_) -> create.Offered(Choosing, Creating, Cancelled, model.creating)
    None -> create.Never
  }
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
