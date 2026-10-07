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
//// lists (at most `sessions.activity_limit`): the daemon asks each session from a task
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
//// navigates to, or a refusal worded in a note beside the row. A pressed row,
//// running or saved, shows `Opening…` from the press until the page leaves
//// (`Model.opening`, `Model.resuming`), and while one is out the page asks for
//// no other, so a second press asks nothing. Every name and path is a catalogue field, drawn as a text
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
//// disabled and a second submit asks nothing. The workspace of that form is the
//// catalogue's text carried by the message the tree was drawn with, never a
//// field the browser fills, and the daemon checks again that the owner holds a
//// session in it or remembers it.
////
//// A folder that holds no session is the one place the browser's own text names
//// a workspace (protocol-change/074). After the lists, a section
//// (`view/folders`) holds a "New session in another folder" button
//// (`OpeningElsewhere`) whose form adds a path field to the same name and box.
//// Submitting it (`CreatingElsewhere`) asks `Start.create` for a `Typed` place,
//// and the daemon decides whether the text names a usable folder inside the
//// owner's home directory. The section also lists the folders the daemon
//// remembers that no group shows, each with the usual form (`Choosing`) and a
//// "Forget this folder" button (`Forgetting`), through `Start.folders`: it reads
//// the list after every list read and answers `FoldersRead`, and forgets by the
//// identity the daemon gave the entry, so a press names an entry that was drawn
//// and never a path. A typed path is never drawn back, in text or an attribute.
////
//// The owner's fresh home can also stop, archive and delete a session from its
//// row (`Start.manage`, protocol-change/065's addendum on session actions): Stop
//// on a running row, Archive and Delete on a saved one (`view/home_table`,
//// `web_view/actions`). The daemon decides who has `Start.manage` (the owner's
//// operating page that a `loom ui` exchange opened, as the Admin button is),
//// and a page without it draws nothing and ignores the messages. Archive asks at
//// once. Delete is two presses, the second a Delete in the row's own
//// confirmation (`Confirming`), and the daemon is asked only after it. Stop is
//// one press on an idle row and two on a row the page last read as working or
//// needing the person, whose confirmation is `StopConfirmed`: the page decides
//// from its own activity read (`Model.activity`) and never from the press, so a
//// forged press for a busy row only opens the confirmation, and a forged
//// confirmation for a row that is not confirming is ignored. The request is the
//// daemon's own task (`Working`), the answer arrives as `ActionAnswered`, and
//// the page then reads its list again so the row is gone or changed. What the
//// page says about it is a `Note` beside the row (`view/home_table`): quiet and
//// fading for a completed action, in the danger colour and staying for a
//// refusal, and the list never moves.
////
//// The page also lists the browsers signed in as its principal and lets the
//// person end them (protocol-change/065, the eighth pull request). Each list
//// that is read starts a read of the principal's sign-ins (`Start.signins`), an
//// answer from the same registry, which the page draws in the account panel
//// (the person's name in the bar opens it; `view/home_bar`, `view/signins`) as
//// one row for each login: a fingerprint, when it was made, when it was last
//// used and when it ends, with the one this page belongs to marked
//// (`Start.login`). A row's "Sign out" and the "Sign out everywhere" button ask
//// the daemon (`Start.sign_out`, `Start.sign_out_all`), which ends the login's
//// row and with it every page that login minted, at that page's next frame, and
//// answers `Revoked`; the page then reads its list again. A page a `loom ui`
//// exchange opened (a fresh home) is also handed `Start.device`, which asks the
//// daemon for a link that signs in another device and shows it once; a home the
//// bookmark resumed has none and draws no control, and the daemon refuses the
//// request from one. While a link is on show the panel opens by itself, so the
//// link is on screen. A page opened by a remembered login draws the bookmark,
//// with a copy button, in the same panel (`Start.bookmark`). The panel is the
//// centre's third child, where it always was, and the stylesheet floats it under
//// the bar, so the centre's body is the session list and nothing else. The sign-in rows' messages name a fingerprint the
//// server drew into the tree, so the browser's event names only the path it
//// fired at and never a login, and the daemon answers only for the principal's
//// own.
////
//// The same panel holds a "Your name" control (protocol-change/065, the tenth
//// pull request), a small form that changes the principal's own display name.
//// `Start.rename_self` is `Some` for every page minted to operate and asks the
//// daemon to rename the page's principal, which the daemon decides again from
//// the grant it holds; a read-only link has none and draws no form. A submit is
//// `NameSubmitted`, and the daemon's answer is `NameAnswered`: the bar and the
//// control's lead then draw the name the catalogue stored. Every read also asks
//// `Start.who` for the principal's name, so a name the owner changed from the
//// admin page reaches an open home at its next read (`NameRead`).
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
////    `Choosing`, `Creating`, `Renaming`, `StopRequested`, `ArchiveRequested`,
////    `StopConfirmed`, `DeleteConfirmed`, `AdminRequested`, `SigningOut`, `SigningOutAll`,
////    `AddingDevice` or `NameSubmitted`, each of which asks the daemon through
////    its own `Start` field and leaves the answer to the effect's message.
//// 5. `view` draws the groups through `shell_sidebar`, the offers
////    (`resume_offer`, `rename_offer`, `manage_offer`, `create_offer`,
////    `admin_offer`), the
////    sign-ins; the last press's note is drawn by the table, beside the row it
////    is about.
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
//// | form | a workspace's button | "another folder" | the form is submitted | the daemon answers | Cancel |
//// | --- | --- | --- | --- | --- | --- |
//// | `Idle` | `Composing` that workspace | `Elsewhere` | asks nothing | nothing to answer | stays `Idle` |
//// | `Composing(w)` | moves to the pressed workspace | `Elsewhere` | asks the daemon if it is `w`'s form, then `Waiting(w)` | nothing to answer | `Idle` |
//// | `Waiting(w)` | asks nothing | asks nothing | asks nothing | departs and `Idle`, or says why and `Composing(w)`, or `Idle` for a session made and not opened | stays `Waiting(w)` |
//// | `Elsewhere` | `Composing` that workspace | stays `Elsewhere` | asks the daemon for the typed path, then `Sending` | nothing to answer | `Idle` |
//// | `Sending` | asks nothing | asks nothing | asks nothing | departs and `Idle`, or says why and `Elsewhere`, or `Idle` for a session made and not opened | stays `Sending` |

import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/event
import lustre/server_component
import web_view/actions
import web_view/creations.{type Sharing}
import web_view/ending.{type Ending}
import web_view/names
import web_view/renames
import web_view/sessions.{
  type Activity, type Entry, type Group, Live, NeedsYou, Working,
}
import web_view/signins.{type Signin}
import web_view/view/archiving
import web_view/view/create.{type Create}
import web_view/view/ended
import web_view/view/folders as folders_view
import web_view/view/heading
import web_view/view/home_bar
import web_view/view/home_table.{type Note}
import web_view/view/notice
import web_view/view/resume.{type Resume}
import web_view/view/shell
import web_view/view/sidebar
import web_view/view/signins as signins_view
import web_view/view/switch
import web_view/view/your_name

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

/// The Lustre event path of the sign-ins region on the home page, which is the
/// account panel the person's name in the bar opens: the centre
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

/// The most remembered folders the page keeps from a read. It mirrors
/// `catalogue.recent_folder_limit`, the catalogue's own bound, which this package
/// cannot import from `storage`; the two are kept equal by hand.
pub const recent_limit = 10

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
    /// Starts the read of the principal's sessions and returns at once: the
    /// daemon's task calls the function it is given with the listing, and
    /// that call is dispatched as `Refreshed` (on open and every `refresh_ms`)
    /// or `Answered` (after an action). The read is registry calls of up to
    /// five seconds each, and a runtime that made them itself held every
    /// click and patch behind them (protocol-change/051: the runtime never
    /// blocks).
    sessions: fn(fn(Listing) -> Nil) -> Nil,
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
    /// Asks the daemon to create a session in a place (a workspace the page
    /// drew, or a folder the owner typed, protocol-change/074) with the typed
    /// name and sharing, and mint a ticket for its page
    /// (protocol-change/065, the fourth pull request). It is `Some` only for the
    /// owner's page minted to operate, and then it is the page's whole offer: a
    /// page with `None` draws no control and ignores every creation message. It
    /// must return at once, and the answer goes to the function it is given,
    /// from the daemon's own task, as `Created`'s message. The daemon checks the
    /// page, its ceiling, the principal and the workspace again, whatever this
    /// page said.
    create: Option(
      fn(
        creations.Place,
        String,
        Sharing,
        Option(String),
        fn(creations.Answer) -> Nil,
      ) -> Nil,
    ),
    /// The model profile names the daemon's configuration defines, as the daemon
    /// read them when the page opened (protocol-change/076). The new-session
    /// forms offer them beside the default roles, and a creation carries one
    /// only if it is in this list. It is `[]` unless `create` is `Some`, and
    /// then the forms draw no select. The daemon checks the profile against its
    /// configuration again when the creation runs, whatever this page said.
    profiles: List(String),
    /// Reads and edits the owner's recent folders (protocol-change/074). It is
    /// `Some` exactly where `create` is, and a page with `None` lists no folder
    /// and ignores the messages. The daemon checks the page, its ceiling and the
    /// owner again whenever either runs, whatever this page said.
    folders: Option(Folders),
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
    /// Asks the daemon to stop, archive or delete the named session, for the
    /// owner's fresh home (protocol-change/065, the addendum on session
    /// actions): the daemon checks that the page is open and fresh and was
    /// minted to operate, that its credential still authenticates as the
    /// daemon's owner, that the identity is a canonical session identity, and
    /// then makes the registry's own owner-checked change. It must return at
    /// once, as `resume` must: the answer goes to the function it is given,
    /// from the daemon's own task, as `ActionAnswered`'s message. It is `None`
    /// unless the page is the owner's operating home that a `loom ui` exchange
    /// opened, and the daemon checks that again when it runs.
    manage: Option(fn(actions.Action, String, fn(actions.Answer) -> Nil) -> Nil),
    /// Starts the read of the principal's sign-ins, with the page's own
    /// credential, which the registry authenticates again, and returns at
    /// once; the daemon's task delivers the listing, dispatched as
    /// `SigninsRead`. It is asked after each list that was not `Closed`.
    signins: fn(fn(signins.Listing) -> Nil) -> Nil,
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
    /// Reads the principal's display name as the catalogue holds it now, with the
    /// page's own credential, which the registry authenticates again. It
    /// starts the read and returns at once; the daemon's task delivers the
    /// name, dispatched as `NameRead`, after each list that was not `Closed`.
    /// It is `None` when the registry did not answer, and the page keeps the
    /// name it has.
    who: fn(fn(Option(String)) -> Nil) -> Nil,
    /// Asks the daemon to change the page's principal's display name to the
    /// typed text (protocol-change/065, the tenth pull request): the daemon
    /// checks that the page is open and was minted to operate, that its
    /// credential still authenticates as the principal it was admitted for and
    /// that the text is a name a display name may be, and then makes the
    /// registry's rename of that principal and no other. It is `Some` for every
    /// page minted to operate, and a page with `None` draws no control and
    /// ignores the message. It must return at once, and the answer goes to the
    /// function it is given, from the daemon's own task, as `NameAnswered`'s
    /// message.
    rename_self: Option(fn(String, fn(names.Answer) -> Nil) -> Nil),
  )
}

/// What the daemon lets the owner's page do with its recent folders
/// (protocol-change/074). Each function returns at once and answers from the
/// daemon's own task, with the list as it then stands, which arrives as
/// `FoldersRead`.
pub type Folders {
  Folders(
    /// Starts the read of the remembered folders, newest first, that a session
    /// may still be started in. It is asked after each list that was not
    /// `Closed`, so a folder remembered from the terminal or another device
    /// reaches an open page at its next read.
    recent: fn(fn(List(creations.Recent)) -> Nil) -> Nil,
    /// Forgets the entry with this identity and answers the list that remains.
    /// An identity that is gone changes nothing.
    forget: fn(Int, fn(List(creations.Recent)) -> Nil) -> Nil,
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
    /// How many list reads have been started, which numbers the next. An
    /// answer carries the number of the read it answers, and one whose number
    /// is not the latest was overtaken by a newer read and is dropped: a
    /// timer's read still in flight when an action read again would otherwise
    /// put the row the action removed back on the page until the next tick.
    reads: Int,
    /// The ticket exchange the daemon minted for the session the person
    /// chose, which `<loom-switch>` navigates to. It stays until the next
    /// press replaces it: the ticket is single use and lives 60 seconds.
    departure: Option(String),
    /// What the page last said about a press, in the daemon's fixed words, and
    /// where it goes: a completed action, or why one could not be done. It is
    /// drawn beside the row or heading it is about and never moves the list.
    note: Option(Note),
    /// The running session whose open is out, if one is. It is set when a press
    /// asks the daemon, so its row can say `Opening…`, and a second press while
    /// it is set asks nothing. A ticket leaves it set, since the page is about
    /// to navigate away; only a refusal clears it.
    opening: Option(String),
    /// The saved session whose resume is out, if one is. It is set when a press
    /// asks the daemon and, like `opening`, cleared only by a refusal, so a
    /// second press while it is set asks nothing.
    resuming: Option(String),
    /// Where the person is in making a session: no form, a form open under one
    /// workspace, or that workspace's creation out. Only a page with
    /// `Start.create` leaves `Idle`.
    creating: create.State,
    /// The owner's remembered folders as the last read gave them, newest first.
    /// The view draws those that no group already shows.
    recent: List(creations.Recent),
    /// Which row's rename form is open, and where it stands.
    edit: Edit,
    /// Which row is waiting on the owner's second press of Delete or on the
    /// daemon's answer to a stop, archive or delete.
    acting: actions.Stage,
    /// The principal's sign-ins as the last read gave them.
    signins: List(Signin),
    /// Where a device link stands.
    link: Link,
    /// What the page last said about a sign-out, in fixed words.
    signin_notice: Option(String),
    /// The principal's display name as the page last knew it: the name it was
    /// started with, then whatever a read or an answer to its own rename gave.
    name: String,
    /// Where the "Your name" control stands.
    naming: names.Control,
    /// How many times the name has changed on the page, which keys the control's
    /// form so it opens on the new name.
    named: Int,
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

  /// The answer to the timer's read, on open and at each interval, numbered
  /// by the read it answers. The sign-ins and the name are read after it, and
  /// the timer is armed from it, so the next interval starts after the read.
  /// An answer a newer read overtook is dropped and arms the timer alone. It
  /// is the effect's own message, dispatched from the daemon's task.
  Refreshed(serial: Int, listing: Listing)

  /// The answer to a read made after an action, numbered by the read it
  /// answers, which arms no timer: the interval already running fires on its
  /// own. An answer a newer read overtook is dropped.
  Answered(serial: Int, listing: Listing)

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
  /// workspace is the one the form was drawn under; the name, the sharing and
  /// the profile are what the browser's event listed
  /// (`view/create.fields_with_profile`), and the profile is one of
  /// `Start.profiles` or `None` for the default roles. The page asks only for
  /// the form that is open, and only once.
  Creating(
    workspace: String,
    name: String,
    sharing: Sharing,
    profile: Option(String),
  )

  /// The "New session in another folder" button was pressed: open its form. A
  /// page with no `Start.create` ignores it.
  OpeningElsewhere

  /// The form for another folder was submitted: ask the daemon to create the
  /// session in the typed path. The path, the name, the sharing and the profile
  /// are what the browser's event listed (`view/create.typed_fields_with_profile`),
  /// and the path is the browser's text and nothing else is: the daemon decides
  /// whether it names a folder the owner may use. The page asks only for the form
  /// that is open, and only once.
  CreatingElsewhere(
    path: String,
    name: String,
    sharing: Sharing,
    profile: Option(String),
  )

  /// A remembered folder's "Forget this folder" was pressed. The identity is the
  /// daemon's, fixed when the tree was drawn, so a press names an entry that was
  /// drawn and never a path.
  Forgetting(id: Int)

  /// A read of the remembered folders, or the answer to a forget, arrived. It is
  /// the effect's own message, dispatched from the daemon's task, and no
  /// handler carries it.
  FoldersRead(rows: List(creations.Recent))

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

  /// A running row's Stop was pressed. The identity is the catalogue's, fixed
  /// when the tree was drawn, and the daemon decides whether the page's
  /// principal may stop it.
  StopRequested(session: String)

  /// A saved row's Archive was pressed.
  ArchiveRequested(session: String)

  /// A saved row's Delete was pressed: the row asks once more before anything
  /// is sent.
  DeleteRequested(session: String)

  /// The confirmation's Stop was pressed. It acts only for the row that is
  /// confirming a stop.
  StopConfirmed(session: String)

  /// The confirmation's Delete was pressed. It acts only for the row that is
  /// confirming a delete.
  DeleteConfirmed(session: String)

  /// A sidebar row's archive button was pressed (`view/archiving`): the page
  /// opens that row's question and sends nothing. Which action the question is
  /// for is the row's residency in the page's own list, never the message.
  SidebarArchiveAsked(session: String)

  /// The sidebar's question was confirmed. It acts only for the row that is
  /// asking, and only for the action that question was opened for, so a stale
  /// click cannot answer the table's Stop or Delete question.
  SidebarArchiveConfirmed(session: String)

  /// The confirmation's Cancel was pressed: the row is as it was.
  ConfirmCancelled

  /// The daemon answered a request to stop, archive or delete. It is the
  /// effect's own message, dispatched from the daemon's task, and no handler
  /// carries it, so a browser cannot put an outcome in the page that the daemon
  /// did not reach.
  ActionAnswered(answer: actions.Answer)

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

  /// A read of the principal's display name answered. It is the effect's own
  /// message, and no handler carries it. `None` is a registry that did not
  /// answer, and leaves the name the page has.
  NameRead(name: Option(String))

  /// The "Your name" form was submitted with this text. The text is the
  /// browser's and nothing else is: whose name it is, whether the page may and
  /// whether the text is a name are all the daemon's to decide.
  NameSubmitted(name: String)

  /// The daemon answered a request to rename the page's principal. It is the
  /// effect's own message, dispatched from the daemon's task, and no handler
  /// carries it, so a browser cannot put a name in the page that the daemon did
  /// not store.
  NameAnswered(answer: names.Answer)
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
    reads: 0,
    departure: None,
    note: None,
    opening: None,
    resuming: None,
    creating: create.Idle,
    recent: [],
    edit: NotEditing,
    acting: actions.Calm,
    signins: [],
    link: NoLink,
    signin_notice: None,
    name: start.name,
    naming: names.Ready,
    named: 0,
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
    TimerReady(timer:) -> refreshing(Model(..model, timer: Some(timer)))

    // An ended page is not asked again, so its timer is left to lapse.
    Ticked ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> refreshing(model)
      }

    // A list that answered starts the read of what its running sessions are
    // doing. The read is the daemon's own task and returns at once, so the
    // list is drawn now and the activity words arrive with `Observed`. An
    // answer a newer read overtook is older than what the page will draw
    // next, so it is dropped.
    Answered(serial:, listing:) ->
      case serial == model.reads {
        True -> {
          let model = answered(model, listing)
          #(model, observing(model))
        }
        False -> #(model, effect.none())
      }

    // The timer's read answered: the list is drawn, the sign-ins and the name
    // are read with it, and the timer is armed for the next read. An answer a
    // newer read overtook is dropped, and still arms the timer: the cadence
    // is the timer's read's to keep, whatever its answer was worth.
    Refreshed(serial:, listing:) ->
      case serial == model.reads {
        True -> {
          let model = answered(model, listing)
          #(model, effect.batch([observing(model), following(model, listing)]))
        }
        False -> #(model, arming(model))
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
    // refuse. Neither does a page that is already opening a session, so the
    // second press of an impatient person asks nothing.
    Opening(session:) ->
      case model.status, model.opening, model.resuming {
        Ended(_), _, _ | _, Some(_), _ | _, _, Some(_) -> #(
          model,
          effect.none(),
        )
        Connecting, None, None | Connected, None, None -> #(
          Model(..model, note: None, opening: Some(session)),
          asking(model.start.open, session),
        )
      }

    // A saved row's press asks the daemon to resume it, from the daemon's own
    // task so the runtime stays free. A page that may not operate, one that
    // ended, and one whose resume is already out ask nothing; the row of such
    // a page has no handler, so these arms are the second layer.
    Resuming(session:) ->
      case model.start.ceiling, model.status, model.resuming {
        OperatorCeiling, Connected, None if model.opening == None -> #(
          Model(..model, note: None, resuming: Some(session)),
          resuming(model.start.resume, session),
        )
        OperatorCeiling, Connected, Some(_)
        | OperatorCeiling, Connected, None
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
        | Some(_), Connected, create.Elsewhere
        -> #(
          Model(..model, creating: create.Composing(workspace), note: None),
          effect.none(),
        )
        Some(_), Connected, create.Waiting(_)
        | Some(_), Connected, create.Sending
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
        create.Composing(_) | create.Elsewhere -> #(
          Model(..model, creating: create.Idle),
          effect.none(),
        )
        create.Idle | create.Waiting(_) | create.Sending -> #(
          model,
          effect.none(),
        )
      }

    // The button opens the form for a typed folder, if the page may create and
    // no creation is out. It closes a workspace's open form, as another
    // workspace's button does.
    OpeningElsewhere ->
      case model.start.create, model.status, model.creating {
        Some(_), Connected, create.Idle
        | Some(_), Connected, create.Composing(_)
        | Some(_), Connected, create.Elsewhere
        -> #(
          Model(..model, creating: create.Elsewhere, note: None),
          effect.none(),
        )
        Some(_), Connected, create.Waiting(_)
        | Some(_), Connected, create.Sending
        | Some(_), Connecting, _
        | Some(_), Ended(_), _
        | None, _, _
        -> #(model, effect.none())
      }

    // The typed folder's submit is honoured only for its form while it is open,
    // as a workspace's is. The path is the browser's text, so the daemon is
    // the one that decides what it names.
    CreatingElsewhere(path:, name:, sharing:, profile:) ->
      case model.start.create, model.status, model.creating {
        Some(ask), Connected, create.Elsewhere ->
          case offered_profile(model, profile) {
            True -> #(
              Model(..model, creating: create.Sending, note: None),
              creation(ask, creations.Typed(path), name, sharing, profile),
            )
            False -> #(model, effect.none())
          }
        Some(_), _, _ | None, _, _ -> #(model, effect.none())
      }

    // A forget asks the daemon from its own task, on a page that was handed the
    // capability and is connected. The identity is one the tree drew.
    Forgetting(id:) ->
      case model.start.folders, model.status {
        Some(Folders(forget:, ..)), Connected -> #(
          Model(..model, note: None),
          forgetting(forget, id),
        )
        Some(_), Connecting | Some(_), Ended(_) | None, _ -> #(
          model,
          effect.none(),
        )
      }

    // A read of the remembered folders replaces the page's own, on a page that
    // lists them.
    FoldersRead(rows:) ->
      case model.start.folders {
        Some(_) -> #(
          Model(..model, recent: list.take(rows, recent_limit)),
          effect.none(),
        )
        None -> #(model, effect.none())
      }

    // A submit asks the daemon from its own task so the runtime stays free. It is
    // honoured only for the form that is open, so a second submit while the
    // first is out, a submit for a form that is not drawn, and a page that may
    // not create ask nothing. These arms are the second layer: the daemon
    // refuses the same requests from the grant it holds.
    Creating(workspace:, name:, sharing:, profile:) ->
      case model.start.create, model.status, model.creating {
        Some(ask), Connected, create.Composing(open) if open == workspace ->
          case offered_profile(model, profile) {
            True -> #(
              Model(..model, creating: create.Waiting(workspace), note: None),
              creation(ask, creations.Drawn(workspace), name, sharing, profile),
            )
            False -> #(model, effect.none())
          }
        Some(_), _, _ | None, _, _ -> #(model, effect.none())
      }

    // A ticket departs for the new session. A refusal says why in the daemon's
    // fixed words and puts the form back, except for a session that was created
    // and did not open, which exists and shows in the list at the next read.
    Created(answer:) ->
      case answer {
        creations.Ticketed(path:) -> #(
          Model(..model, departure: Some(path), creating: create.Idle),
          effect.none(),
        )
        creations.Declined(reason:) -> #(
          Model(
            ..model,
            note: Some(refusal(
              refused_at(model),
              creations.reason_words(reason),
            )),
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
          Model(..model, note: None),
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
          Model(
            ..model,
            note: Some(refusal(home_table.Page, sessions.reason_words(reason))),
          ),
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

    // Archive asks at once, from Calm or while another row is confirming, which
    // it replaces. The identity is the one the row was drawn with, and the
    // daemon checks it and the page's standing again.
    ArchiveRequested(session:) -> start_action(model, actions.Archive, session)

    // Stop asks at once for a row that is not busy. For a row the page last read
    // as working or waiting for the person, the press only opens the row's
    // confirmation, and sends nothing. What the page read decides it, and the
    // press carries nothing but the identity.
    StopRequested(session:) ->
      case busy(model, session) {
        Busy -> confirm_first(model, actions.Stop, session)
        Quiet -> start_action(model, actions.Stop, session)
      }

    // Delete's first press opens that row's confirmation. It sends nothing.
    DeleteRequested(session:) -> confirm_first(model, actions.Delete, session)

    // The second press asks, and only for the row that is confirming that
    // action, so a press for any other row, for the other action, or with no
    // confirmation open, asks nothing.
    StopConfirmed(session:) -> confirmed(model, actions.Stop, session)
    DeleteConfirmed(session:) -> confirmed(model, actions.Delete, session)

    // The sidebar's archive button opens its question for the action the row's
    // residency gives, a stop first for a running one. A row the page does not
    // list asks nothing.
    SidebarArchiveAsked(session:) ->
      case sidebar_action(model, session) {
        Ok(action) -> confirm_first(model, action, session)
        Error(Nil) -> #(model, effect.none())
      }

    // Its confirmation asks for the action the open question is for, and only
    // when that question is the sidebar's.
    SidebarArchiveConfirmed(session:) -> sidebar_confirmed(model, session)

    ConfirmCancelled ->
      case model.acting {
        actions.Confirming(..) -> #(
          Model(..model, acting: actions.Calm),
          effect.none(),
        )
        actions.Calm | actions.Working(..) -> #(model, effect.none())
      }

    // The answer ends the request, says what happened in a note beside the row,
    // and reads the list again, so the row is gone or changed in what the page
    // draws. An answer that arrives when no request is out was not asked for and
    // is dropped.
    ActionAnswered(answer:) ->
      case model.acting, answer {
        actions.Working(session:, ..), actions.Done(action:) ->
          reading(
            Model(
              ..model,
              acting: actions.Calm,
              note: Some(beside(
                model,
                session,
                notice.Said(actions.done_words(action)),
              )),
            ),
          )
        actions.Working(session:, ..), actions.Declined(reason:) ->
          reading(
            Model(
              ..model,
              acting: actions.Calm,
              note: Some(beside(
                model,
                session,
                notice.Refused(actions.reason_words(reason)),
              )),
            ),
          )
        actions.Calm, _ | actions.Confirming(..), _ -> #(model, effect.none())
      }

    // The answer: a stored name replaces the row's in the page's own state at
    // once, the daemon's own word for it, and the next read confirms it; a
    // refusal is worded in the open form, in the reason's fixed words. An answer
    // that arrives when no request is out was not asked for and is dropped.
    RenameAnswered(answer:) ->
      case model.edit, answer {
        Editing(session, renames.Asking), renames.Renamed(name:) -> {
          let groups = renamed(model.groups, session, name)
          let model = Model(..model, edit: NotEditing, groups:)
          #(
            Model(
              ..model,
              note: Some(beside(model, session, notice.Said("Renamed."))),
            ),
            effect.none(),
          )
        }
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

    // A name the read found replaces the page's, and the form is keyed anew so it
    // opens on it. A read the registry did not answer leaves the name.
    NameRead(name: Some(read)) if read != model.name -> #(
      Model(..model, name: read, named: model.named + 1),
      effect.none(),
    )
    NameRead(name: Some(_)) | NameRead(name: None) -> #(model, effect.none())

    // A submit asks the daemon from the daemon's own task so the runtime stays
    // free. A page with no capability, one that is not connected and one whose
    // request is already out ask nothing; these arms are the second layer, since
    // the form of such a page has no handler and the daemon refuses the same
    // request from the grant it holds.
    NameSubmitted(name:) ->
      case model.start.rename_self, model.status, model.naming {
        Some(ask), Connected, names.Ready
        | Some(ask), Connected, names.Done
        | Some(ask), Connected, names.Refused(..)
        -> #(Model(..model, naming: names.Asking), renaming_self(ask, name))
        Some(_), Connected, names.Asking
        | Some(_), Connecting, _
        | Some(_), Ended(_), _
        | None, _, _
        -> #(model, effect.none())
      }

    // The answer: the name the catalogue stored replaces the page's and keys a
    // new form, and a refusal is the reason's fixed words. An answer that
    // arrives when no request is out was not asked for and is dropped.
    NameAnswered(answer:) ->
      case model.naming, answer {
        names.Asking, names.Renamed(name:) -> #(
          Model(..model, name:, naming: names.Done, named: model.named + 1),
          effect.none(),
        )
        names.Asking, names.Declined(reason:) -> #(
          Model(..model, naming: names.Refused(reason)),
          effect.none(),
        )
        names.Ready, _ | names.Done, _ | names.Refused(..), _ -> #(
          model,
          effect.none(),
        )
      }

    // The answer: a ticket becomes the address `<loom-switch>` navigates to, and
    // the row keeps saying `Opening…` until the page goes, since the browser
    // needs a moment to follow the ticket. A refusal is a note beside the row,
    // in the reason's fixed words, and the row is pressable again.
    Linked(answer:) ->
      case answer {
        sessions.Ticketed(path:) -> #(
          Model(..model, departure: Some(path)),
          effect.none(),
        )
        sessions.Declined(reason:) -> {
          let pressed = case model.opening, model.resuming {
            Some(session), _ | None, Some(session) -> Some(session)
            None, None -> None
          }
          #(
            Model(
              ..model,
              note: Some(case pressed {
                Some(session) ->
                  beside(
                    model,
                    session,
                    notice.Refused(sessions.reason_words(reason)),
                  )
                None -> refusal(home_table.Page, sessions.reason_words(reason))
              }),
              opening: None,
              resuming: None,
            ),
            effect.none(),
          )
        }
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

// Starts the daemon's task that renames the page's principal and returns at
// once; the task's answer arrives later as `NameAnswered`, dispatched from the
// task's own process.
fn renaming_self(
  ask: fn(String, fn(names.Answer) -> Nil) -> Nil,
  name: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  ask(name, fn(answer) { dispatch(NameAnswered(answer)) })
}

// Reads the principal's sign-ins again, after one changed.
fn reading_signins(model: Model) -> Effect(Msg) {
  use dispatch <- effect.from
  model.start.signins(fn(read) { dispatch(SigninsRead(read)) })
}

// Starts the daemon's task that mints an admin ticket and returns at once; the
// answer arrives later as `AdminLinked`, dispatched from the task's own process.
fn opening_admin(ask: fn(fn(sessions.Answer) -> Nil) -> Nil) -> Effect(Msg) {
  use dispatch <- effect.from
  ask(fn(answer) { dispatch(AdminLinked(answer)) })
}

// Stop and Archive: asks the daemon from its own task, for a page that was
// handed the capability and is connected, and while no other request is out. A
// confirmation that is open on another row is closed by the press.
fn start_action(
  model: Model,
  action: actions.Action,
  session: String,
) -> #(Model, Effect(Msg)) {
  case opening_now(model, session) {
    True -> #(model, effect.none())
    False ->
      case model.start.manage, model.status, model.acting {
        Some(ask), Connected, actions.Calm
        | Some(ask), Connected, actions.Confirming(..)
        -> #(
          Model(..model, acting: actions.Working(session, action), note: None),
          managing(ask, action, session),
        )
        Some(_), Connected, actions.Working(..)
        | Some(_), Connecting, _
        | Some(_), Ended(_), _
        | None, _, _
        -> #(model, effect.none())
      }
  }
}

// The action the sidebar's archive button means for a listed session, or none
// for one the page does not list.
fn sidebar_action(
  model: Model,
  session: String,
) -> Result(actions.Action, Nil) {
  list.find_map(model.groups, fn(group) {
    list.find(group.entries, fn(entry) { entry.id == session })
  })
  |> result.map(archiving.action)
}

// The sidebar's confirmation: it asks for the action the open question is for,
// and only when that question is the sidebar's.
fn sidebar_confirmed(model: Model, session: String) -> #(Model, Effect(Msg)) {
  case archiving.confirmed(model.acting, session) {
    Ok(action) -> confirmed(model, action, session)
    Error(Nil) -> #(model, effect.none())
  }
}

// Whether the session is the one whose open or resume is out. Its row draws no
// actions, and a press for it is ignored here as the second layer.
fn opening_now(model: Model, session: String) -> Bool {
  model.opening == Some(session) || model.resuming == Some(session)
}

// Whether the page last read a session as busy: working on a turn, or waiting
// for the person. A session the read has not answered for is not busy, since
// nothing says it is.
type Busyness {
  Busy
  Quiet
}

fn busy(model: Model, session: String) -> Busyness {
  case dict.get(model.activity, session) {
    Ok(Working) | Ok(NeedsYou) -> Busy
    Ok(sessions.Idle) | Ok(sessions.Failed) | Error(Nil) -> Quiet
  }
}

// The first press of an action that asks twice: it opens that row's
// confirmation and sends nothing. It replaces a confirmation open on another
// row, and does nothing while a request is out.
fn confirm_first(
  model: Model,
  action: actions.Action,
  session: String,
) -> #(Model, Effect(Msg)) {
  use <- bool.guard(opening_now(model, session), #(model, effect.none()))
  case model.start.manage, model.status, model.acting {
    Some(_), Connected, actions.Calm
    | Some(_), Connected, actions.Confirming(..)
    -> #(
      Model(..model, acting: actions.Confirming(session, action), note: None),
      effect.none(),
    )
    Some(_), Connected, actions.Working(..)
    | Some(_), Connecting, _
    | Some(_), Ended(_), _
    | None, _, _
    -> #(model, effect.none())
  }
}

// The second press: it asks the daemon, and only for the row that is confirming
// this action. Any other press asks nothing, which is what makes a forged
// confirmation harmless.
fn confirmed(
  model: Model,
  action: actions.Action,
  session: String,
) -> #(Model, Effect(Msg)) {
  case model.start.manage, model.status, model.acting {
    Some(ask), Connected, actions.Confirming(open, asked)
      if open == session && asked == action
    -> #(
      Model(..model, acting: actions.Working(session, action), note: None),
      managing(ask, action, session),
    )
    Some(_), _, _ | None, _, _ -> #(model, effect.none())
  }
}

// A note about a session, placed beside its row. The place carries the
// session's workspace and name as the page has them now, so that the note can
// still be drawn, naming the session, after the row is gone.
fn beside(model: Model, session: String, said: notice.Notice) -> Note {
  let place =
    list.find_map(model.groups, fn(group) {
      list.find(group.entries, fn(entry) { entry.id == session })
      |> result.map(fn(entry) {
        home_table.Session(session, group.workspace, sessions.label(entry))
      })
    })
  home_table.Note(place: result.unwrap(place, home_table.Page), notice: said)
}

// A refusal, which stays until the next press, at a place.
fn refusal(place: home_table.Place, words: String) -> Note {
  home_table.Note(place:, notice: notice.Refused(words))
}

// Starts the daemon's task for one action and returns at once; the answer
// arrives later as `ActionAnswered`, dispatched from the task's own process.
fn managing(
  ask: fn(actions.Action, String, fn(actions.Answer) -> Nil) -> Nil,
  action: actions.Action,
  session: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  ask(action, session, fn(answer) { dispatch(ActionAnswered(answer)) })
}

// Starts a read of the list now, after an action changed it, without arming
// the timer: the interval already running will fire on its own. The read is
// numbered, so an older read still in flight is dropped when it answers.
fn reading(model: Model) -> #(Model, Effect(Msg)) {
  let serial = model.reads + 1
  let model = Model(..model, reads: serial)
  let effect = {
    use dispatch <- effect.from
    model.start.sessions(fn(listing) { dispatch(Answered(serial, listing)) })
  }
  #(model, effect)
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
  ask: fn(
    creations.Place,
    String,
    Sharing,
    Option(String),
    fn(creations.Answer) -> Nil,
  ) -> Nil,
  place: creations.Place,
  name: String,
  sharing: Sharing,
  profile: Option(String),
) -> Effect(Msg) {
  use dispatch <- effect.from
  ask(place, name, sharing, profile, fn(answer) { dispatch(Created(answer)) })
}

// Whether a submitted profile is one the page offered: the default roles always
// are, and a name only if the daemon listed it when the page opened. The form's
// decoder already resolves a position in this list, so a submit that fails this
// check did not come from a form the page drew.
fn offered_profile(model: Model, profile: Option(String)) -> Bool {
  case profile {
    None -> True
    Some(name) -> list.contains(model.start.profiles, name)
  }
}

// Starts the daemon's task that forgets one folder and returns at once; the list
// that remains arrives later as `FoldersRead`, dispatched from the task.
fn forgetting(
  forget: fn(Int, fn(List(creations.Recent)) -> Nil) -> Nil,
  id: Int,
) -> Effect(Msg) {
  use dispatch <- effect.from
  forget(id, fn(rows) { dispatch(FoldersRead(rows)) })
}

// Where a refused creation's words are drawn: beside the workspace's heading
// when the form was open under a group the page draws, in the section for
// folders that hold no session when it was open there or for a typed path, and
// under the page's heading otherwise.
fn refused_at(model: Model) -> home_table.Place {
  case create.open_for(model.creating), model.creating {
    Some(workspace), _ ->
      case list.any(model.groups, fn(group) { group.workspace == workspace }) {
        True -> home_table.Workspace(workspace)
        False -> home_table.Elsewhere
      }
    None, create.Sending | None, create.Elsewhere -> home_table.Elsewhere
    None, create.Idle | None, create.Composing(_) | None, create.Waiting(_) ->
      home_table.Page
  }
}

// Where the form stands after a refusal: open again under the workspace it was
// for, so the person can correct it, unless the session was made and did not
// open, which leaves nothing to correct.
fn reopened(state: create.State, reason: creations.Reason) -> create.State {
  case state, reason {
    create.Waiting(_), creations.NotOpened -> create.Idle
    create.Waiting(workspace), _ -> create.Composing(workspace)
    create.Sending, creations.NotOpened -> create.Idle
    create.Sending, _ -> create.Elsewhere
    create.Idle, _ | create.Composing(_), _ | create.Elsewhere, _ -> state
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
    |> list.take(sessions.activity_limit)
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

// Starts the timer's read, numbered. The daemon's task delivers the list,
// which lands as `Refreshed`; the reads that follow it and the arming of the
// timer wait for that answer, so the interval starts after the read, as it
// did when the read was made here.
fn refreshing(model: Model) -> #(Model, Effect(Msg)) {
  let serial = model.reads + 1
  let model = Model(..model, reads: serial)
  let effect = {
    use dispatch <- effect.from
    model.start.sessions(fn(listing) { dispatch(Refreshed(serial, listing)) })
  }
  #(model, effect)
}

// Arms the timer for the next read, when the runtime has made it.
fn arming(model: Model) -> Effect(Msg) {
  case model.timer {
    None -> effect.none()
    Some(timer) -> {
      use _ <- effect.from
      let _ = process.send_after(timer, model.start.refresh_ms, Nil)
      Nil
    }
  }
}

// What follows the timer's read: the sign-ins and the name are read with the
// list, so a login that ended since the last read leaves the page at the same
// pace a session does, and the timer is armed for the next read. A read that
// answered `Closed` asks nothing more and arms nothing: that page has ended,
// so the read is its last.
fn following(model: Model, listing: Listing) -> Effect(Msg) {
  case listing {
    Closed(..) -> effect.none()
    Listed(_) | Unread ->
      effect.batch([
        {
          use dispatch <- effect.from
          model.start.signins(fn(read) { dispatch(SigninsRead(read)) })
          model.start.who(fn(name) { dispatch(NameRead(name)) })
          case model.start.folders {
            Some(Folders(recent:, ..)) ->
              recent(fn(rows) { dispatch(FoldersRead(rows)) })
            None -> Nil
          }
        },
        arming(model),
      ])
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
        groups: sessions.grouped(list.take(entries, sessions.listed_limit)),
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
/// How many list reads the page has started. An answer carries the number
/// of the read it answers (`Refreshed`, `Answered`), and only the latest
/// read's answer is drawn.
///
/// ## Examples
///
/// ```gleam
/// // home.update(model, home.Answered(home.reads(model), home.Unread))
/// ```
pub fn reads(model: Model) -> Int {
  model.reads
}

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
/// bar names the page and the principal (a button that opens the account panel),
/// says so when the page is a read-only link, and carries the notice of a page
/// that ended.
///
/// The centre's children are, in order, the notice of the last press (an
/// empty node when there is none, so the list keeps its path), the lists
/// (`table_path`), the account panel (`signins_path`), which the stylesheet
/// floats under the bar and shows only while the name's button has it open, and
/// the hidden `<loom-switch>` element, last so that no admitted path moves with
/// it.
///
/// ## Examples
///
/// ```gleam
/// // element.to_string(home.view(model))
/// ```
pub fn view(model: Model) -> Element(Msg) {
  shell.view(
    shell.Home,
    home_bar.with(
      title: "Home",
      who: home_bar.account(
        model.name,
        ceiling_words(model.start.ceiling),
        account_panel(model),
      ),
      status: status_words(model.status),
      tone: status_tone(model.status),
      notice: ended.home(ended_ending(model.status)),
      trailing: admin_offer(model),
    ),
    shell_sidebar(model),
    [
      // The empty node keeps the table at `table_path`.
      element.none(),
      home_table.view(
        model.groups,
        model.activity,
        model.now,
        Opening,
        resume_offer(model),
        rename_offer(model),
        manage_offer(model),
        create_offer(model),
        folders_offer(model),
        model.opening,
        model.note,
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
        your_name.view(model.name, name_offer(model)),
      ),
      switch.view(model.departure),
      switch.switcher(),
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

// What the table offers for acting on a row: the buttons on a page whose daemon
// handed it the capability, and nothing otherwise.
fn manage_offer(model: Model) -> home_table.Manage(Msg) {
  case model.start.manage {
    None ->
      case model.start.rename {
        // The owner's operating page always has rename, and a fresh one also has
        // manage, so this is the owner's home that a bookmark resumed. A
        // member's home and a read-only link have no rename and say nothing.
        Some(_) -> home_table.Withheld
        None -> home_table.Unmanaged
      }
    Some(_) ->
      home_table.Managed(
        stop: StopRequested,
        archive: ArchiveRequested,
        delete: DeleteRequested,
        confirm_stop: StopConfirmed,
        confirm_delete: DeleteConfirmed,
        cancel: ConfirmCancelled,
        stage: model.acting,
      )
  }
}

// What the sidebar offers for archiving a row: the quiet button and its
// question on a page whose daemon handed it the same capability as the table's
// buttons, and nothing otherwise.
fn archive_offer(model: Model) -> archiving.Archiving(Msg) {
  case model.start.manage {
    None -> archiving.Never
    Some(_) ->
      archiving.Offered(
        ask: SidebarArchiveAsked,
        confirm: SidebarArchiveConfirmed,
        cancel: ConfirmCancelled,
        stage: model.acting,
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

// What the account panel offers for renaming the page's principal: the form on a
// page the daemon handed `Start.rename_self`, and nothing otherwise.
fn name_offer(model: Model) -> your_name.Offer(Msg) {
  case model.start.rename_self {
    None -> your_name.Withheld
    Some(_) -> your_name.Offered(model.naming, model.named, naming_submit())
  }
}

// The form's submit as the message that carries the one text field the form has.
// Any other field, a repeated one or a missing one refuses the event, as the
// row's rename form does.
fn naming_submit() -> attribute.Attribute(Msg) {
  event.on("submit", named_text()) |> event.prevent_default
}

fn named_text() -> decode.Decoder(Msg) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )
  case fields {
    [#("text", name)] -> decode.success(NameSubmitted(name))
    _ -> decode.failure(NameSubmitted(""), "name form")
  }
}

// What the sign-ins region offers for a device link: the control on a page the
// daemon handed `Start.device`, and nothing otherwise. The one page that has
// nothing and ought to say why is the owner's home that a bookmark resumed. The
// page can tell it from the others by what the daemon handed it: the owner's
// operating page has `Start.rename`, and a fresh one also has `Start.manage`,
// which a resumed one lacks (`client/daemon/ui_socket.manage_for`). A member's
// home and a read-only link have no `Start.rename`, and their rows are the same
// as before.
fn device_offer(model: Model) -> signins_view.Device(Msg) {
  case model.start.device {
    None ->
      case model.start.rename, model.start.manage {
        Some(_), None -> signins_view.Resumed
        Some(_), Some(_) | None, _ -> signins_view.Never
      }
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
    Some(_) ->
      create.Offered(
        Choosing,
        Creating,
        Cancelled,
        OpeningElsewhere,
        CreatingElsewhere,
        model.creating,
        model.start.profiles,
      )
    None -> create.Never
  }
}

// What the page offers for folders that hold no session: the section on a page
// that may create, with the remembered folders no group already shows, which are
// the ones a person could not otherwise reach without typing them again. A page
// that has read nothing yet draws nothing, so the control does not appear before
// the page knows its standing.
fn folders_offer(model: Model) -> folders_view.Folders(Msg) {
  case model.start.create, model.status {
    Some(_), Connected ->
      folders_view.Shown(
        recent: list.filter(model.recent, fn(entry) {
          !list.any(model.groups, fn(group) { group.workspace == entry.path })
        }),
        forget: Forgetting,
      )
    Some(_), Connecting | Some(_), Ended(_) | None, _ -> folders_view.Hidden
  }
}

// The sidebar's column, or the frame's word that there is none.
fn shell_sidebar(model: Model) -> shell.Sidebar(Msg) {
  case model.groups {
    [] -> shell.Unlisted
    [_, ..] as groups ->
      shell.Listed(sidebar.home(
        groups,
        model.activity,
        Opening,
        resume_offer(model),
        archive_offer(model),
      ))
  }
}

// What the bar says of the page's ceiling: nothing for an operating page, which
// may do all its principal may and is the normal case, and "read-only link" for
// the one a person hands to someone who may only watch. The ceiling is a cap and
// not a role, so it is never worded as one: the person's role is on each row.
fn ceiling_words(ceiling: Ceiling) -> String {
  case ceiling {
    OperatorCeiling -> ""
    ObserverCeiling -> "read-only link"
  }
}

// The account panel opens by itself while a device link is on show, so the link
// is on screen when it arrives, and is the person's to open otherwise.
fn account_panel(model: Model) -> home_bar.Panel {
  case model.link {
    ShownLink(_) -> home_bar.Open
    NoLink | AskingLink | RefusedLink(_) -> home_bar.Closed
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
