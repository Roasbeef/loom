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
//// (`view/folders`) holds one "New session" button (`OpeningElsewhere`) whose
//// form adds a path field to the same name and box, and, where the daemon has
//// executors or pools, a "Runs on" choice of machines (`ChoosingHere`,
//// `ChoosingPlace`).
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
//// A saved row on an executor can also be moved to another orchestrator
//// (protocol-change/085, the addendum on Move and Abandon). Move is the one
//// action that reads first: its press asks the daemon which orchestrators could
//// take the session (`actions.Destinations`), and the answer replaces the row's
//// words with a button for each that could and a line for each that could not
//// (`actions.Choosing`, `MoveChosen`). A destination opens the question Delete
//// opens, and the daemon is asked to move only after that second press
//// (`MoveConfirmed`). Each step acts only for the stage the one before it left,
//// the daemon checks only that the destination is a configured orchestrator, and a moved row reads "moving to"
//// the destination at the next list.
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
//// The owner's operating page also lists the sessions on the daemon's other
//// orchestrators (protocol-change/085). `Start.elsewhere` is `Some` exactly
//// where `create` is, and with it each list that answers starts a read of the
//// first page of every other orchestrator, numbered by `Model.elsewhere_reads`
//// and delivered as `ElsewhereRead`. The page draws them in a group after
//// "Other folders" (`view/elsewhere`). A row is information and not a door: its
//// "Where" button (`Locating`, honoured only for a row the page holds, checked
//// by `holds_row`) opens a detail under the row with the launch that reaches the
//// session where it lives, in a `<loom-copy>` box, and a group's "Show more"
//// (`ShowingMore`) asks for the page after the last row the page holds for it
//// (`next_cursor`), which arrives as `MoreRead` and is joined onto the group
//// (`joined`) only if no newer read has replaced the rows. Both are clicks
//// beneath `table_path`, which the owner's socket already admits, so the group
//// adds no event class, scope or route. A press names the orchestrator and the
//// session the server drew into the tree, `paging` asks the daemon from its own
//// task, and `still_there` closes a detail whose row a later read removed. A
//// refresh keeps the pages already fetched when its first page is unchanged
//// (`refreshed`, `kept`) and answers `MoreRead` only for the group whose press is
//// out (`elsewhere_reads` numbers the reads).
//// `elsewhere_offer` is what the view is given.
////
//// The owner's operating page can also be opened on one session of another
//// orchestrator (protocol-change/094). The daemon then hands the component
//// `Start.visiting`, and the centre is that session (`Pane`'s `Relayed`,
//// `view/relayed_session`) while the sidebar, the account panel and every ticket
//// stay the home's. The session lives on the other orchestrator, so the page
//// keeps nothing of it: `relay_reading` asks the daemon, from its own task, for
//// the session's row and newest transcript page when the page opens and every
//// `Visit.refresh_ms` after, and `relayed_session.heard` replaces what the page
//// holds. A reply, a stop, an archive and a decision are presses the state judges
//// against the row it holds (`relayed_session.update`), after which `relaying`
//// asks the daemon through the matching `Visit` function and the answer lands as
//// `RelaySent`, `RelayStopped`, `RelayArchived` or `RelayDecided`. Each answer is
//// followed by a read of the orchestrator. Every string of the session is text
//// from another machine and is drawn as a text node.
////
//// The same page can start a session on another orchestrator and list the ones it
//// started there (protocol-change/094). `Start.orchestrators` is `Some` exactly
//// where `create` is and the daemon is configured with an orchestrator. The page
//// then holds one `orchestrators.Machine` for each. The composer's Agent chip
//// draws them (`offers` builds the lists the composer judges a choice against,
//// from this daemon's or from the chosen orchestrator's offers), and opening the
//// Agent chip, or the Code chip on an orchestrator, asks the daemon to read the
//// offers again (`reading_offers`). A start on an orchestrator asks the daemon to
//// create there (`founding`), and the answer departs for the relayed page, whose
//// address is built here from the page's key and a session the daemon named
//// (`Founded`). The sidebar lists each orchestrator's sessions, read on a timer of
//// their own (`side_reading`): a machine with a read out is not asked again, so a
//// silent box costs one call at a time, and its last rows stay, marked, until it
//// answers. A press on one of its rows (`OpeningRelayed`) is honoured only for a
//// row the page holds.
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
////    `StopConfirmed`, `DeleteConfirmed`, `MoveRequested`, `MoveChosen`,
////    `MoveConfirmed`, `AdminRequested`, `SigningOut`, `SigningOutAll`,
////    `AddingDevice` or `NameSubmitted`, each of which asks the daemon through
////    its own `Start` field and leaves the answer to the effect's message.
//// 5. On a relayed session's page, `relay_reading` starts each read of the
////    orchestrator, `relay_heard` applies it, and `relaying` and `relay_asking`
////    turn a press into the daemon's call.
//// 6. On a page with orchestrators, `side_reading` starts the sidebar's reads and
////    `reading_offers` the composer's, and `founding` creates a session.
//// 7. `view` draws the groups through `shell_sidebar`, the offers
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
//// | form | a workspace's button | "New session" | the form is submitted | the daemon answers | Cancel |
//// | --- | --- | --- | --- | --- | --- |
//// | `Idle` | `Composing` that workspace | `Elsewhere` | asks nothing | nothing to answer | stays `Idle` |
//// | `Composing(w)` | moves to the pressed workspace | `Elsewhere` | asks the daemon if it is `w`'s form, then `Waiting(w)` | nothing to answer | `Idle` |
//// | `Waiting(w)` | asks nothing | asks nothing | asks nothing | departs and `Idle`, or says why and `Composing(w)`, or `Idle` for a session made and not opened | stays `Waiting(w)` |
//// | `Elsewhere` | `Composing` that workspace | stays `Elsewhere` | asks the daemon for the typed or remembered folder on this machine, then `Sending` | nothing to answer | `Idle` |
//// | `Sending` | asks nothing | asks nothing | asks nothing | departs and `Idle`, or says why and `Elsewhere`, or `Idle` for a session made and not opened | stays `Sending` |
////
//// Where the daemon has executors or pools (protocol-change/078, 085) the same
//// form opens with a "Runs on" choice, and the choice is a fourth set of states,
//// `Chosen` and `Dispatching`. `Elsewhere` is the choice of this machine and the
//// default. Opening the form starts the read of the placements, so the executors
//// and pools are drawn at once from names and take the state the daemon found a
//// moment before when the read answers. Choosing an executor or a pool moves to
//// `Chosen` with the placement it was drawn for, which swaps the folder field for
//// the workspaces that place registered, and choosing this machine moves back to
//// `Elsewhere`. A choice the page did not draw, and a state the daemon gave it,
//// never refuse a choice: the state is advice, and the daemon decides again when
//// the session opens. A submit asks the daemon for the chosen placement and moves
//// to `Dispatching`, which behaves as `Sending` does: it asks nothing, and the
//// answer departs and returns to `Idle`, says why and returns to `Chosen`, or
//// returns to `Idle` for a session made and not opened. Cancel returns to `Idle`
//// from `Elsewhere` and `Chosen`.

import core/agency_limits
import core/attention
import core/json.{type JsonValue}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import lustre/server_component
import session_view/move_candidates
import session_view/operator
import session_view/project_board as board
import web_view/actions
import web_view/answer_rule
import web_view/approval_evidence
import web_view/attention_feed
import web_view/attention_rule
import web_view/brief_rule
import web_view/composer
import web_view/creations.{type Sharing}
import web_view/elsewhere
import web_view/ending.{type Ending}
import web_view/folder_browse
import web_view/inbox_rule
import web_view/item_pane
import web_view/landing_rule
import web_view/listing
import web_view/names
import web_view/orchestrators
import web_view/page
import web_view/passkeys.{type Passkey}
import web_view/placements
import web_view/projects as feed
import web_view/relayed
import web_view/relayed_session
import web_view/renames
import web_view/review_feed
import web_view/review_pane
import web_view/review_scan_rule
import web_view/review_stage_rule
import web_view/saved_attention.{type Saved}
import web_view/session_brief
import web_view/sessions.{
  type Activity, type Entry, type Group, Live, NeedsYou, Working,
}
import web_view/signins.{type Signin}
import web_view/thread_send
import web_view/thread_words
import web_view/ticket_rule
import web_view/view/archiving
import web_view/view/attention_thread
import web_view/view/brief_view
import web_view/view/create.{type Create}
import web_view/view/elsewhere as elsewhere_view
import web_view/view/ended
import web_view/view/folders as folders_view
import web_view/view/heading
import web_view/view/home_bar
import web_view/view/home_table.{type Note}
import web_view/view/inbox as inbox_view
import web_view/view/inbox_parts
import web_view/view/new_session
import web_view/view/notice
import web_view/view/passkeys as passkeys_view
import web_view/view/projects as projects_view
import web_view/view/relayed_session as relayed_view
import web_view/view/resume.{type Resume}
import web_view/view/review_thread as review_view
import web_view/view/shell
import web_view/view/sidebar
import web_view/view/signins as signins_view
import web_view/view/switch
import web_view/view/ticket_thread
import web_view/view/your_name
import web_view/watch_rule

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

/// The Lustre event path of the Projects section on the owner's home
/// (protocol-change/106, the addendum on the web view): the centre's first
/// child, above the body at `table_path`. Every handler beneath it is one
/// ticket's button, which opens that ticket's page. The home's socket admits a
/// click beneath it for the owner's operating page only, and
/// `home_test` and `projects_home_test` fail if the view moves the region.
pub const projects_path = "0\t2\t0"

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
    activity: fn(List(String), fn(List(#(String, sessions.Report))) -> Nil) ->
      Nil,
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
        creations.Roles,
        agency_limits.AgencyLimits,
        String,
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
    /// The model keys the daemon's configuration defines, as the daemon read
    /// them when the page opened (protocol-change/080). The forms offer them
    /// beside the default model, and a creation carries one only if it is in
    /// this list. It is `[]` unless `create` is `Some`. Only the key is given:
    /// nothing else of a `[models.<key>]` entry is ever sent to a page. The
    /// daemon checks the key against its configuration again when the creation
    /// runs, whatever this page said.
    models: List(String),
    /// The executor names the daemon's configuration defines, as the daemon
    /// knew them when the page opened (protocol-change/078). The section for
    /// folders offers a panel for a workspace registered on one of them or in
    /// one of `pools`, and a creation carries an executor only if it is in this
    /// list. It is `[]` unless `create` is `Some`. The daemon checks the
    /// executor against its configuration again when the creation runs,
    /// whatever this page said.
    executors: List(String),
    /// The pool names the daemon's configuration defines, as it knew them when
    /// the page opened (protocol-change/085), told and checked as `executors`
    /// are. It is `[]` unless `create` is `Some`. With `executors` it decides
    /// whether the panel is offered at all.
    pools: List(String),
    /// The asking daemon's own name, which the new-session form words as "this
    /// machine" beside the executors and pools. It is a configuration value
    /// (the daemon's node name) and is drawn as a text node.
    machine: String,
    /// Starts the read of the placements: the daemon connects to its executors,
    /// which takes up to a few seconds, and hands the function it is given what
    /// it found, once. It must return at once, as `resume` must, and run the
    /// read in the daemon's own task, never in this component's runtime; the
    /// answer is dispatched as `PlacementsRead`. The page asks when the panel
    /// opens and draws the cards from names alone until the answer arrives, so a
    /// slow or failed read costs the person nothing but the states. A page with
    /// no `create` is never asked.
    placements: fn(fn(placements.Read) -> Nil) -> Nil,
    /// Reads and edits the owner's recent folders (protocol-change/074). It is
    /// `Some` exactly where `create` is, and a page with `None` lists no folder
    /// and ignores the messages. The daemon checks the page, its ceiling and the
    /// owner again whenever either runs, whatever this page said.
    folders: Option(Folders),
    /// Reads the sessions the owner's other orchestrators list
    /// (protocol-change/085). It is `Some` exactly where `create` is, and a page
    /// with `None` draws no group and ignores the messages. The daemon checks the
    /// page, its ceiling and the owner again whenever a read runs, whatever this
    /// page said.
    elsewhere: Option(Elsewhere),
    /// Reads the owner's projects and answers a ticket's question
    /// (protocol-change/106, the addendum on the web view). It is `Some` exactly
    /// where `create` is, and a page with `None` draws no Projects section and
    /// ignores the messages. The daemon checks the page, its ceiling and the
    /// owner again whenever a read or an answer runs, whatever this page said.
    projects: Option(Projects),
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
    /// Asks the daemon to send a message to the named session on its main
    /// strand, as a prompt or a steer, for the owner's operating home
    /// (protocol-change/118): the daemon checks that the page is open and was
    /// minted to operate, that its credential still authenticates as the
    /// daemon's owner, that the principal holds the session and that it is
    /// running, and then sends as the message is sent from the session's own
    /// page. It must return at once, as `resume` must: the answer goes to the
    /// function it is given, from the daemon's own task, as `ThreadAnswered`'s
    /// message. It is `None` unless the page's principal is the daemon's owner on
    /// a page minted to operate, and then the inbox draws no message field and
    /// ignores the messages. The daemon checks that again when it runs.
    thread_send: Option(
      fn(String, String, operator.Delivery, fn(thread_send.Answer) -> Nil) ->
        Nil,
    ),
    /// Reads the attention feed for the inbox's threads, and acts on it for
    /// the owner's operating page (protocol-change/120). `None` on a page that
    /// reads no feed, which then draws the inbox as it was before asks.
    attention: Option(Attention),
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
    /// The principal's passkeys (protocol-change/127): the read, the removal and,
    /// on a fresh home, the address of the registration page. It is `Some` only
    /// for the owner's operating page, and a page with `None` draws no passkeys
    /// region and ignores the messages. The daemon checks the page, its ceiling
    /// and the owner again, whatever this page said.
    passkeys: Option(Passkeys),
    /// The session of another orchestrator this page was opened to show
    /// (protocol-change/094). It is `Some` only on the relayed session page of
    /// the owner's operating page, which the daemon decides before it starts the
    /// component, and then the centre is that session (`Relayed`). Every other
    /// page has `None`, draws no relayed centre and ignores its messages.
    visiting: Option(Visit),
    /// The orchestrators this daemon relays for (protocol-change/094). It is
    /// `Some` only on the owner's operating page of a daemon configured with at
    /// least one, and then the Agent chip lists them and the sidebar lists their
    /// sessions. Every other page has `None`, draws neither and ignores their
    /// messages.
    orchestrators: Option(Orchestrators),
  )
}

/// What the daemon lets the owner's page ask of the orchestrators it relays for
/// (protocol-change/094). Each function returns at once and answers from the
/// daemon's own task, which is a weft run that dies with the page, and each
/// answer is bounded by the relay's own call timeouts, so a box that does not
/// answer costs its own reads and no other orchestrator's. The daemon judges every
/// call again from a fresh read of the orchestrator, whatever this page said.
pub type Orchestrators {
  Orchestrators(
    /// The page's own key, which the relayed pages' addresses are built under.
    /// The daemon checked it when it opened the socket.
    key: String,
    /// The `[orchestrators.<name>]` keys, in configuration order.
    names: List(String),
    /// The interval between reads of the orchestrators' session lists, in
    /// milliseconds. Production passes `relay_refresh_ms`; a test passes a short
    /// one.
    refresh_ms: Int,
    /// Starts the read of what the named orchestrator offers a new session and
    /// hands the function it is given what it found, once.
    offers: fn(String, fn(orchestrators.OffersRead) -> Nil) -> Nil,
    /// Starts the read of the sessions the named orchestrator lists for this page
    /// and hands the function it is given what it found, once.
    sessions: fn(String, fn(orchestrators.ListRead) -> Nil) -> Nil,
    /// Asks the named orchestrator to create a session in a place with a profile
    /// and model, and then sends it the first message when there is one. The place
    /// is one the composer drew from the orchestrator's offers.
    create: fn(
      String,
      creations.Place,
      creations.Roles,
      String,
      fn(orchestrators.Founding) -> Nil,
    ) -> Nil,
  )
}

/// What the daemon lets the relayed session page do (protocol-change/094). Each
/// function returns at once and answers from the daemon's own task, which is a
/// weft run that dies with the page, and the answer arrives as the message the
/// page named. The daemon asks the orchestrator through the relay, which dials it
/// on demand, and judges every call again from a fresh read of the orchestrator,
/// whatever this page said.
pub type Visit {
  Visit(
    /// The orchestrator's `[orchestrators.<name>]` key, which the router checked.
    orchestrator: String,
    /// The session's identity there, which the router checked.
    session: String,
    /// The interval between reads of the orchestrator, in milliseconds.
    /// Production passes `relay_refresh_ms`; a test passes a short one.
    refresh_ms: Int,
    /// Why this page is the transcript and not the live session page, which
    /// its heading says (protocol-change/108).
    fallback: relayed.Fallback,
    /// Starts the read of the session's row and its newest transcript page and
    /// hands the function it is given what it found, once.
    read: fn(fn(relayed.Read) -> Nil) -> Nil,
    /// Delivers a reply to the session's main strand.
    send: fn(String, fn(relayed.Outcome) -> Nil) -> Nil,
    /// Stops the session's current run.
    stop: fn(fn(relayed.Outcome) -> Nil) -> Nil,
    /// Archives the session.
    archive: fn(fn(relayed.Outcome) -> Nil) -> Nil,
    /// Decides a request, named by the identity and the revision the card was
    /// drawn with.
    decide: fn(String, Int, relayed.Choice, fn(relayed.Outcome) -> Nil) -> Nil,
  )
}

/// How long the relayed session page stands before it reads the orchestrator
/// again, in milliseconds. A request the session raises reaches the page this
/// much later at most (protocol-change/094, "When the link drops").
pub const relay_refresh_ms = 5000

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
    /// Starts the read of one directory below the owner's home for the composer's
    /// folder picker (protocol-change/132). The argument is the page's own trail,
    /// built from a listing the daemon gave it, and the answer is a bounded
    /// listing or a refusal in fixed words, dispatched as `FolderBrowsed`. The
    /// daemon resolves the trail against the home it reads itself, refuses any
    /// that leaves it, and checks the page and the owner again, whatever this page
    /// said.
    browse: fn(List(String), fn(folder_browse.Answer) -> Nil) -> Nil,
  )
}

/// What the daemon lets the owner's page read of its other orchestrators
/// (protocol-change/085). Each function returns at once and answers from the
/// daemon's own task, which is a weft run that dies with the page, and the answer
/// arrives as `ElsewhereRead` or `MoreRead`.
pub type Elsewhere {
  Elsewhere(
    /// Starts the read of the first page of every other orchestrator, once. It is
    /// asked after each list that was not `Closed`, so a session created on
    /// another orchestrator reaches an open page at its next read, and the
    /// daemon bounds the whole read at three seconds.
    groups: fn(fn(elsewhere.Read) -> Nil) -> Nil,
    /// Starts the read of the page of one orchestrator that follows the session
    /// it is given, and answers a `Heard` holding that one group. Both are
    /// values the page took from a group it holds.
    next: fn(String, String, fn(elsewhere.Read) -> Nil) -> Nil,
  )
}

/// What the daemon lets the owner's page do with its projects
/// (protocol-change/106). Each function returns at once and answers from the
/// daemon's own task, which is a weft run that dies with the page, and the answer
/// arrives as `BoardsRead`, `TicketRead` or `AnswerSettled`.
pub type Projects {
  Projects(
    /// Starts the read of every project's first board page. It is asked after
    /// each list that was not `Closed`, so a ticket that needs the owner reaches
    /// an open page at its next read.
    boards: fn(fn(feed.Read) -> Nil) -> Nil,
    /// Starts the read of one ticket, named by the project's id and the ticket's,
    /// both values the page took from a board it holds.
    ticket: fn(String, String, fn(feed.TicketRead) -> Nil) -> Nil,
    /// Sends an answer to a ticket's question: the project, the ticket, the
    /// question's sequence number as the form was drawn with it, and the text.
    /// The daemon refuses an answer whose number is no longer the open question's.
    answer: fn(String, String, Int, String, fn(feed.Answer) -> Nil) -> Nil,
    /// Closes a ticket whose work the owner accepted: the project, the ticket and
    /// the function the daemon's word goes to. The daemon keeps the ticket's
    /// mandate, so a later message can resume it.
    close: fn(String, String, fn(feed.Closing) -> Nil) -> Nil,
    /// Stops a ticket, withdrawing its mandate: the project, the ticket and the
    /// function the daemon's word goes to. Only a ticket thread on the inbox
    /// sends it.
    stop: fn(String, String, fn(feed.Acted) -> Nil) -> Nil,
    /// Asks for a new worker on a stalled ticket, with the same arguments.
    retry: fn(String, String, fn(feed.Acted) -> Nil) -> Nil,
  )
}

/// What the inbox reads of the attention feed, and, for the owner's operating
/// page alone, how it acts on what it reads (protocol-change/120). Every
/// function returns at once and answers from the daemon's own task, which is a
/// weft run that dies with the page, as `Projects` does.
pub type Attention {
  Attention(
    /// Starts the read of the feed rows of the named running sessions, at most
    /// `sessions.activity_limit` of them, all of which the page's own list
    /// holds. The answer is dispatched as `FeedRead`. A session the daemon
    /// could not read, or whose row did not decode, is left out, and the page
    /// counts it as not checked.
    feed: fn(List(String), fn(List(#(String, attention_feed.Row))) -> Nil) ->
      Nil,
    /// Starts the read of the catalogue's summary rows for the named saved
    /// sessions (protocol-change/122). The answer is dispatched as `SavedRead`.
    saved: fn(List(String), fn(List(Saved)) -> Nil) -> Nil,
    /// Starts the read of one record in full: the session, the record's
    /// identifier and the function the daemon's word goes to. A refusal is the
    /// daemon's fixed words.
    record: fn(String, String, fn(Result(item_pane.Record, String)) -> Nil) ->
      Nil,
    /// Starts the read of a running session's pending approvals as evidence, and
    /// returns at once. The answer is the daemon's reading, or its fixed words
    /// for why there is none, and arrives as `ApprovalsRead`. It reads and
    /// never decides.
    approvals: fn(String, fn(Result(approval_evidence.Evidence, String)) -> Nil) ->
      Nil,
    /// Starts the read of a running session's brief (protocol-change/125) and
    /// returns at once: the session, the time after which peer messages are
    /// wanted (Unix milliseconds, zero for the latest) and the function the
    /// daemon's answer goes to. The answer is its reading or its fixed words and
    /// arrives as `BriefRead`. It reads and never writes, and the daemon spends
    /// the credential's brief allowance for it.
    brief: fn(String, Int, fn(Result(session_brief.Brief, String)) -> Nil) ->
      Nil,
    /// Starts the read of a running session's worktree as a review
    /// (protocol-change/123) and returns at once. The answer is the daemon's
    /// review or its fixed words for why there is none, and arrives as
    /// `ReviewScanned` or `ReviewRead`. It is `None` on a page whose ceiling is an
    /// observer's, because the daemon refuses an observer the tree's bytes, and
    /// then the inbox has no "To review" group and draws no review pane.
    review: Option(
      fn(String, fn(Result(review_feed.Review, String)) -> Nil) -> Nil,
    ),
    /// How long the page waits after the daemon refuses a read for the
    /// credential's allowance before it reads again, in milliseconds: the
    /// allowance's window and a margin (`ui_sessions.worktree_read_window_ms`),
    /// so the allowance has refilled when the read is asked again.
    review_pause_ms: Int,
    /// How the page acts, or nothing for a page that may not: only the daemon's
    /// owner on a page minted to operate is handed it, and the daemon decides
    /// again each time one of its functions runs.
    act: Option(Act),
  )
}

/// What the owner's operating page may do to an attention record.
pub type Act {
  Act(
    /// Answers an ask: the session, the ask, the revision the page read it at
    /// and the wire object of the form. The daemon delivers one prompt to the
    /// asking strand and then settles the record
    /// (`client/daemon/attention_door.answer`).
    answer: fn(String, String, Int, JsonValue, fn(ActOutcome) -> Nil) -> Nil,
    /// Closes a find: the session, the find, the revision and the way.
    close: fn(String, String, Int, attention.Closure, fn(ActOutcome) -> Nil) ->
      Nil,
    /// Dismisses a stuck strand's failure (protocol-change/131): the session, the
    /// strand and the operation of the failed run the page read from its feed
    /// row. The daemon refuses a failure the strand no longer holds.
    dismiss_stuck: fn(String, String, String, fn(ActOutcome) -> Nil) -> Nil,
    /// Sends a prompt or a steer to a named strand of a session, as a message
    /// typed on the session's own page is sent.
    strand: fn(
      String,
      String,
      String,
      operator.Delivery,
      fn(thread_send.Answer) -> Nil,
    ) -> Nil,
  )
}

/// What the daemon said of an answer or a close. The words are the daemon's
/// own fixed words: they name a question key at most and never text a person
/// typed or a session wrote, so the page draws them as they are.
pub type ActOutcome {
  /// The record was settled.
  Succeeded(words: String)

  /// It was not, or not entirely. The words say what happened and what did not.
  Failed(words: String)
}

/// What the daemon hands the owner's operating home to manage passkeys with
/// (protocol-change/127).
pub type Passkeys {
  Passkeys(
    /// Starts the read of the owner's passkeys, with the page's own credential,
    /// which the registry authenticates again, and returns at once; the daemon's
    /// task delivers the listing, dispatched as `PasskeysRead`.
    read: fn(fn(passkeys.Listing) -> Nil) -> Nil,
    /// Removes one of the owner's passkeys, named by fingerprint: the daemon
    /// checks the page, then asks the registry, which finds the passkey among
    /// the owner's own and no other. It runs in the component's process when a
    /// press asks, and must not run long.
    remove: fn(String) -> passkeys.Answer,
    /// The address of the registration page, which is `Some` only for a page a
    /// `loom ui` exchange opened. The daemon refuses a registration from any
    /// other page whatever this says.
    add: Option(String),
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
    /// What the daemon last said each running session is doing, last said and
    /// reports about its strands, by identity: the same answer `activity` is
    /// derived from, kept whole for the inbox. It is replaced whole with
    /// `activity`, and everything in it that a session wrote is untrusted text.
    reports: Dict(String, sessions.Report),
    /// The session whose thread the inbox's reading pane shows, and how it came
    /// to. The default is fixed when the first read that has a thread settles
    /// (`settled_selection`), so a later read never moves the pane under the
    /// person's reading or typing. A choice that left the list falls back to the
    /// first thread (`inbox_rule.selection`).
    selected: Selection,
    /// How many threads the person has pressed, which keys the element that
    /// scrolls the reading pane into view, so each press does.
    presses: Int,
    /// The keys of the threads the person has opened since the page loaded, for
    /// the filled and hollow dot of each row (`view/inbox_parts.Reading`). It is
    /// the page's own state: it is not saved, the daemon is told nothing of it,
    /// and opening a thread never takes it out of the list.
    opened: Set(String),
    /// The rail folder the inbox's list is narrowed to. It is the page's own
    /// state: it is not saved and the daemon is told nothing of it, and a folder
    /// whose group has emptied draws as `Everything` (`shown_folder`).
    folder: inbox_rule.Folder,
    /// The last report of the selected thread, kept apart from `reports` so a
    /// read that omits it does not blank the pane while its session is still
    /// listed. It is drawn for that thread, and so counted in the group header
    /// that holds it and listed in the thread list; the headline's count, the
    /// states and the landing are counted from the fresh read alone.
    shown: Option(#(String, sessions.Report)),
    /// Which centre the page shows, decided once. It is `Awaiting` until the
    /// first round of reads is complete (`round`), then the inbox or the
    /// composer by the landing rule, and no later read changes it: a read that
    /// is missed or late must not replace a pane or a composer the person is
    /// using. After that only the person's clicks change it.
    centre_choice: CentreChoice,
    /// Which first reads the page is still owed and which have answered. The
    /// centre is decided when the last one answers (`landing_rule`), whatever
    /// order they came in.
    round: landing_rule.Round,
    /// What the inbox's outbox says: nothing sent, a message out to a session,
    /// or the daemon's answer to the last one (`thread_send.Outbox`). There is
    /// one outbox, so a second message waits for the first's answer.
    outbox: thread_send.Outbox,
    /// How many messages the daemon has delivered, which keys each thread's
    /// message box: a delivered message leaves an empty box, and a refused one
    /// leaves the draft as the person typed it.
    delivered: Int,
    /// The feed rows of the running sessions, by identity, replaced whole by
    /// each read. A session that is missing is not checked.
    feed: Dict(String, attention_feed.Row),
    /// The catalogue's summary rows of the saved sessions, by identity.
    saved: Dict(String, Saved),
    /// The approval evidence read for the sessions whose thread was shown, by
    /// session, replaced by each read.
    evidence: Dict(String, approval_evidence.Seen),
    /// The brief of each session whose thread was shown, by session, replaced by
    /// each read (protocol-change/125).
    briefs: Dict(String, session_brief.Seen),
    /// The last brief read the page started of each session, which
    /// `brief_rule.due` counts the next read from.
    brief_reads: Dict(String, brief_rule.Read),
    /// The time each held brief's read named as the start of the peer messages
    /// it wanted, so a thread draws them only under a label they fit
    /// (`brief_rule.shown`).
    brief_since: Dict(String, Int),
    /// The open item thread and what is staged in it.
    item: item_pane.State,
    /// How many item threads have been opened, which keys their forms so each
    /// open starts empty.
    item_presses: Int,
    /// What the page knows of each idle session's worktree, by identity, which
    /// decides who is "To review" (`web_view/review_scan_rule`). It holds a
    /// verdict for each session and never a review.
    reviews: Dict(String, review_scan_rule.Seen),
    /// The open review thread: its review, what is staged and where a Send
    /// stands.
    review: review_pane.State,
    /// How many review threads have been opened, which keys their forms so each
    /// open starts empty.
    review_presses: Int,
    /// The timer that starts the scan again after the allowance refused a read,
    /// known once the runtime has made it.
    review_timer: Option(Subject(Nil)),
    /// Whether that timer is already set. One is outstanding at most, so a run
    /// of refusals sets it once.
    review_rearm: Rearm,
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
    /// The cards the panel for a registered workspace draws: the names the page
    /// was given, and what the daemon reported about each once a read answered.
    cards: placements.Cards,
    /// How many placement reads have been started, which numbers the next, as
    /// `reads` does for the list: an answer that a newer read overtook is
    /// dropped, so a slow read cannot put an older state on a card.
    place_reads: Int,
    /// The owner's remembered folders as the last read gave them, newest first.
    /// The view draws those that no group already shows.
    recent: List(creations.Recent),
    /// The other orchestrators' sessions as the last read gave them, in the
    /// order the daemon's configuration lists the orchestrators. An answer
    /// replaces it whole, and a "Show more" page is joined onto one group.
    elsewhere: List(elsewhere.Group),
    /// How many reads of the other orchestrators have been started, which numbers
    /// the next as `reads` does for the list: an answer a newer read overtook is
    /// dropped, so a slow read cannot put older rows on the page.
    elsewhere_reads: Int,
    /// The row whose "Where" detail is open, as the orchestrator's key and the
    /// session. Both are values of a group the page holds.
    located: Option(elsewhere_view.Detail),
    /// The orchestrator whose "Show more" is out, if one is, which disables its
    /// button so a second press asks nothing.
    paging: Option(String),
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
    /// The owner's passkeys as the last read gave them.
    passkeys: List(Passkey),
    /// The passkey whose "Remove" was pressed once and now waits for "Confirm".
    passkey_asked: Option(String),
    /// What the page last said about a passkey, in fixed words.
    passkey_notice: Option(String),
    /// The principal's display name as the page last knew it: the name it was
    /// started with, then whatever a read or an answer to its own rename gave.
    name: String,
    /// Where the "Your name" control stands.
    naming: names.Control,
    /// How many times the name has changed on the page, which keys the control's
    /// form so it opens on the new name.
    named: Int,
    /// Which centre the page shows: the composer or the list.
    pane: Pane,
    /// The composer's state. It is idle on a page with no `Start.create`.
    compose: composer.State,
    /// The machine the sidebar's list is narrowed to.
    filter: listing.Filter,
    /// The relay's refresh timer, known once the runtime has made it.
    relay_timer: Option(Subject(Nil)),
    /// How many reads of the orchestrator have been started, which numbers the
    /// next as `reads` does for the list.
    relay_reads: Int,
    /// What the page holds of each orchestrator the daemon relays for: what it
    /// offers and the sessions it lists. Empty on a page with no
    /// `Start.orchestrators`.
    machines: List(orchestrators.Machine),
    /// The sidebar's refresh timer for the orchestrators' lists, known once the
    /// runtime has made it.
    side_timer: Option(Subject(Nil)),
    /// The projects as the last read gave them, decoded. An answer replaces it
    /// whole, and an answer that changes nothing leaves the model as it was.
    boards: List(feed.Loaded),
    /// How many reads of the boards have been started, which numbers the next as
    /// `reads` does for the list: an answer a newer read overtook is dropped.
    board_reads: Int,
    /// The project ticket whose thread the inbox's pane shows, if one is open.
    /// It is never open together with an attention item's thread.
    ticket: Option(ticket_rule.Opened),
  )
}

/// A ticket the centre is showing: where it is, what the last read of it said,
/// and where its answer stands.
pub type OpenTicket {
  OpenTicket(
    /// The project's id, a value of a board the page holds.
    project: String,
    /// The ticket's id, a value of that board.
    ticket: String,
    /// The last read of the ticket; none until one has answered.
    detail: Option(board.Detail),
    /// Whether an answer is out.
    asking: projects_view.Asking,
    /// What the page last said about the answer.
    notice: Option(projects_view.Note),
    /// How many answers have been recorded, which keys the answer box.
    answered: Int,
  )
}

/// Whether the page has decided its centre. The decision is made once per page
/// load, when the last read of the first round has answered (`landing_rule`):
/// the inbox when anything across the round's reads waits or runs, the composer
/// otherwise. After that the person's clicks are the only thing that change it.
///
/// | state | the round's last read answers | a later read answers | the person presses |
/// | --- | --- | --- | --- |
/// | `Awaiting` | `Decided` by what the round gathered | stays `Awaiting` until the round closes | `Decided` as pressed |
/// | `Decided` | stays as it is | stays as it is | `Decided` as pressed |
pub type CentreChoice {
  /// The round of first reads is not complete, so the page shows the composer
  /// or the list.
  Awaiting

  /// The centre is decided.
  Decided(centre: Centre)
}

/// The centre the page shows in the body of its middle column, when no ticket's
/// page or relayed session has taken it over.
pub type Centre {
  /// The attention inbox (`view/inbox`).
  InboxCentre

  /// The new-session composer.
  FormCentre

  /// The full session list.
  ListCentre
}

/// The thread the inbox's reading pane shows and how it came to be shown.
pub type Selection {
  /// No thread has been shown yet.
  Unchosen

  /// The page showed the first thread of the first group, and keeps it until
  /// the person presses another or the session leaves the list. On a narrow
  /// screen the pane stays hidden for it.
  Defaulted(session: String)

  /// The person pressed its row.
  Pressed(session: String)
}

/// Which centre the home shows. The composer is where a session is started and
/// is the owner's default; the list is the page that held every control before
/// the sidebar took over listing, and stays reachable for the controls that have
/// not moved (rename, move, delete, the remembered folders, the other
/// orchestrators' sessions).
pub type Pane {
  /// A ticket of a project (`view/projects`): why it was allowed, its question
  /// with an answer box, and a link to the worker's session.
  Ticketed(ticket: OpenTicket)

  /// The new-session composer (`view/new_session`).
  NewSession

  /// The sessions grouped by project, with the earlier forms
  /// (`view/home_table`).
  SessionList

  /// One session of another orchestrator (`view/relayed_session`), on the page
  /// the daemon opened for it. Only a page with `Start.visiting` is in it, and
  /// the pane holds the session's state: leaving the pane drops it, and the
  /// page then reads the orchestrator no more.
  Relayed(state: relayed_session.State)
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
  Observed(rows: List(#(String, sessions.Report)))

  /// A thread in the inbox was pressed: show its reading pane. The identity is
  /// the catalogue's, fixed when the tree was drawn, and the page honours it
  /// only for a session its last read still reports (`inbox_rule.selection`).
  InboxOpened(session: String)

  /// The person pressed a button on an inbox thread's message field: send the
  /// draft to the session as `delivery`. The session is the thread the form was
  /// drawn for, fixed when the tree was drawn, and the page honours it only for
  /// a running session its last read reports; the daemon decides whether the
  /// principal holds it.
  ThreadSubmitted(session: String, text: String, delivery: operator.Delivery)

  /// The daemon answered a send. It is the effect's own message, dispatched
  /// from the daemon's task.
  ThreadAnswered(session: String, answer: thread_send.Answer)

  /// The feed rows the daemon read for the running sessions.
  FeedRead(rows: List(#(String, attention_feed.Row)))

  /// The catalogue's summary rows the daemon read for the saved sessions.
  SavedRead(rows: List(Saved))

  /// The daemon's answer to the read of a session's brief. `since` is the time
  /// the read asked peer messages after.
  BriefRead(
    session: String,
    since: Int,
    read: Result(session_brief.Brief, String),
  )

  /// The daemon's answer to the read of a session's approval evidence.
  ApprovalsRead(
    session: String,
    read: Result(approval_evidence.Evidence, String),
  )

  /// An item's row was pressed: open its thread. The key is drawn into the
  /// handler by the server, and the page honours it only for an item its last
  /// read still holds.
  ItemPicked(key: attention_rule.Key)

  /// The daemon's answer to the read of an item's record.
  RecordRead(key: attention_rule.Key, read: Result(item_pane.Record, String))

  /// The ask's form was submitted: check it and stage the answer.
  ItemStaged(fields: List(#(String, String)))

  /// The note form was submitted: stage the message.
  ItemNoted(text: String)

  /// Take back everything staged.
  ItemCleared

  /// Send what is staged.
  ItemSent

  /// A find's close button was pressed.
  ItemClosed(closure: attention.Closure)

  /// Retry was pressed on a stuck strand.
  ItemRetried

  /// Dismiss was pressed on a stuck strand.
  ItemDismissed

  /// The daemon's word on an answer or a close.
  ItemActed(key: attention_rule.Key, outcome: ActOutcome)

  /// The daemon's word on a message to a strand that followed an answer or was
  /// sent alone.
  ItemNoteAnswered(key: attention_rule.Key, answer: thread_send.Answer)

  /// The daemon's word on a retry.
  ItemRetryAnswered(key: attention_rule.Key, answer: thread_send.Answer)

  /// The daemon's answer to the read that decides whether a finished session is
  /// "To review". The message is the session's last message when the read began.
  ReviewScanned(
    session: String,
    message: String,
    read: Result(review_feed.Review, String),
  )

  /// The runtime made the timer that starts the review scan again after the
  /// allowance refused a read.
  ReviewTimerReady(timer: Subject(Nil))

  /// The scan's timer fired: read the next due session.
  ReviewTicked

  /// The daemon's answer to the read of the open review thread's worktree.
  ReviewRead(session: String, read: Result(review_feed.Review, String))

  /// The daemon's answer to the read of a find's record, for its revision.
  ReviewFindRead(find: String, read: Result(item_pane.Record, String))

  /// A verdict button was pressed.
  ReviewVerdictChosen(verdict: review_stage_rule.Verdict)

  /// A file's comment form was submitted: the file's path, drawn into the
  /// handler by the server, and the text.
  ReviewCommented(path: String, text: String)

  /// A find's form was submitted: the find, the way to close it and a note.
  ReviewFindStaged(find: String, closure: attention.Closure, note: String)

  /// Take back everything staged in the review.
  ReviewCleared

  /// Send what the review staged.
  ReviewSent

  /// The daemon's word on a find close that a review's Send asked for.
  ReviewClosed(
    find: String,
    closure: attention.Closure,
    outcome: review_pane.Outcome,
  )

  /// The gateway's word on the prompt a review's Send delivered.
  ReviewPrompted(answer: thread_send.Answer)

  /// A project ticket's row was pressed: open its thread. The address is drawn
  /// into the handler by the server, and the page honours it only for a ticket
  /// its last board read still holds.
  TicketThreadPicked(key: ticket_rule.Key)

  /// A read of the open ticket thread's ticket arrived. It is the effect's own
  /// message.
  TicketThreadRead(key: ticket_rule.Key, read: feed.TicketRead)

  /// A control on the open ticket thread was pressed. The control was drawn into
  /// the handler, and the page honours it only when the ticket's daemon-listed
  /// actions still hold it.
  TicketControlPressed(control: ticket_rule.Control)

  /// The thread's answer form was submitted, with the question's sequence number
  /// it was drawn with and the text.
  TicketAnswerSent(seq: Int, text: String)

  /// The confirmation of a Stop or a Close was pressed: do what was asked. The
  /// ticket and the act were drawn into the handler, and the page honours the
  /// press only when both are still what it asked about.
  TicketActConfirmed(key: ticket_rule.Key, control: ticket_rule.Control)

  /// The confirmation's "Keep" was pressed: take the question back.
  TicketActKept

  /// The daemon's word on a ticket act. It is the effect's own message.
  TicketActSettled(
    key: ticket_rule.Key,
    control: ticket_rule.Control,
    outcome: feed.Acted,
  )

  /// The person pressed "Inbox" on the composer or the list: show the centre the
  /// page lands on, which is the inbox while something waits or runs.
  ShowingInbox

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
  /// the roles are what the browser's event listed
  /// (`view/create.fields_with_roles`), and the profile and the model in the
  /// roles are each one of `Start.profiles` and `Start.models` or `None` for
  /// the default. The page asks only for the form that is open, and only once.
  Creating(
    workspace: String,
    name: String,
    sharing: Sharing,
    roles: creations.Roles,
  )

  /// The "New session" button of the folders section was pressed: open the one
  /// form for a new session, with this machine chosen, and start the read of the
  /// placements when the daemon has executors or pools. A page with no
  /// `Start.create` ignores it.
  OpeningElsewhere

  /// The form for another folder was submitted: ask the daemon to create the
  /// session in the typed path. The path, the name, the sharing and the roles
  /// are what the browser's event listed (`view/create.typed_fields_with_roles`),
  /// and the path is the browser's text and nothing else is: the daemon decides
  /// whether it names a folder the owner may use. The page asks only for the form
  /// that is open, and only once.
  CreatingElsewhere(
    path: String,
    name: String,
    sharing: Sharing,
    roles: creations.Roles,
  )

  /// The "Runs on" choice of this machine was pressed: the form asks for a
  /// folder on the daemon serving the page. It carries no text, so a browser
  /// names nothing, and the page honours it while the form is open and no
  /// creation is out.
  ChoosingHere

  /// A card's Choose button was pressed. The placement is the one the card was
  /// drawn for, built by the server from the names it was given, so the browser
  /// names no text. The page honours it only for a card it drew and while the
  /// form is open and no creation is out.
  ChoosingPlace(choice: placements.Choice)

  /// The daemon's answer to the read of the placements, numbered by the read it
  /// answers. An answer a newer read overtook is dropped. It is the effect's own
  /// message, dispatched from the daemon's task, and no handler carries it, so
  /// a browser cannot put a state on a card.
  PlacementsRead(serial: Int, read: placements.Read)

  /// The form for a registered workspace was submitted: ask the daemon to create
  /// the session at the chosen placement. The placement is the one a card chose
  /// (`ChoosingPlace`), held by the page and never a field of the form, and the
  /// workspace, the session name and the roles are what the browser's event
  /// listed (`view/create.remote_fields_with_roles`): the workspace is one the
  /// chosen place reported, and the profile and the model are each one of
  /// `Start.profiles` and `Start.models` or `None`. The daemon judges all of
  /// them, and the placement, again. The page asks only for
  /// the form that is open, and only once.
  CreatingRemote(workspace: String, name: String, roles: creations.Roles)

  /// A remembered folder's "Forget this folder" was pressed. The identity is the
  /// daemon's, fixed when the tree was drawn, so a press names an entry that was
  /// drawn and never a path.
  Forgetting(id: Int)

  /// A read of the remembered folders, or the answer to a forget, arrived. It is
  /// the effect's own message, dispatched from the daemon's task, and no
  /// handler carries it.
  FoldersRead(rows: List(creations.Recent))

  /// A read of one directory for the folder picker arrived, with the trail it
  /// answers. It is the effect's own message, dispatched from the daemon's task,
  /// and no handler carries it; the composer applies it only if it is still
  /// waiting for that trail.
  FolderBrowsed(trail: List(String), answer: folder_browse.Answer)

  /// A read of the other orchestrators' first pages arrived, numbered by the read
  /// it answers. It is the effect's own message, dispatched from the daemon's
  /// task, and no handler carries it, so a browser cannot put a row on the page.
  ElsewhereRead(serial: Int, read: elsewhere.Read)

  /// A read of the projects' boards arrived, numbered by the read it answers. It
  /// is the effect's own message, dispatched from the daemon's task, and no
  /// handler carries it, so a browser cannot put a ticket on the page.
  BoardsRead(serial: Int, read: feed.Read)

  /// A ticket's button was pressed: show its page. The project and the ticket are
  /// the board's, fixed when the tree was drawn, and the page honours the press
  /// only for a pair it holds.
  OpeningTicket(project: String, ticket: String)

  /// A read of the open ticket arrived. It is the effect's own message.
  TicketRead(project: String, ticket: String, read: feed.TicketRead)

  /// The ticket page's Back button was pressed.
  ClosingTicket

  /// The answer form was submitted: the question's sequence number the form was
  /// drawn with, and the one text field the browser supplies.
  Answering(seq: Int, text: String)

  /// The daemon answered an answer. It is the effect's own message.
  AnswerSettled(project: String, ticket: String, answer: feed.Answer)

  /// The ticket page's "Close ticket" was pressed: the owner accepts the work.
  ClosingWork

  /// The daemon's word on a close. It is the effect's own message.
  CloseSettled(project: String, ticket: String, closing: feed.Closing)

  /// A row's "Where" was pressed: open its detail. The orchestrator's key and
  /// the session are the group's and the row's, fixed when the tree was drawn,
  /// and the page honours the press only for a pair it holds.
  Locating(group: String, session: String)

  /// The detail's "Close" was pressed.
  Located

  /// A group's "Show more" was pressed: ask for its next page. The key is the
  /// group's, fixed when the tree was drawn, and the cursor is the last row the
  /// page holds for it and never a value the browser sent.
  ShowingMore(group: String)

  /// The next page of one orchestrator arrived. It is the effect's own message,
  /// dispatched from the daemon's task, and no handler carries it.
  MoreRead(group: String, serial: Int, read: elsewhere.Read)

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

  /// A saved row's Move was pressed: the page asks the daemon which
  /// orchestrators could take the session, which changes nothing.
  MoveRequested(session: String)

  /// One of the row's destinations was pressed. It opens the confirmation, and
  /// only for a row that is choosing and a destination that row was offered,
  /// so a forged press names nothing the daemon did not say.
  MoveChosen(session: String, to: String)

  /// The confirmation's Move was pressed. It acts only for the row that is
  /// confirming a move, and for the destination that confirmation names.
  MoveConfirmed(session: String)

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

  /// A read of the owner's passkeys answered. It is the effect's own message,
  /// and no handler carries it.
  PasskeysRead(listing: passkeys.Listing)

  /// A passkey's "Remove" was pressed. It asks nothing: the row then offers
  /// "Confirm". The fingerprint is the daemon's, fixed when the tree was drawn.
  PasskeyAsked(fingerprint: String)

  /// A passkey's "Confirm" was pressed: ask the daemon to remove it.
  PasskeyConfirmed(fingerprint: String)

  /// A passkey's "Cancel" was pressed: keep it.
  PasskeyKept

  /// The daemon answered a request to remove a passkey. It is the effect's own
  /// message, and no handler carries it, so a browser cannot put an outcome in
  /// the page that the daemon did not reach.
  PasskeyAnswered(answer: passkeys.Answer)

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

  /// A press in the new-session composer. The message carries a value the server
  /// drew or text the composer bounds and judges (`composer.update`); the page
  /// checks it against the lists it holds, so a forged one changes nothing. A
  /// page with no `Start.create` ignores it.
  Composed(message: composer.Msg)

  /// The sidebar's "New session" button: show the composer. A page with no
  /// `Start.create` ignores it.
  ShowingNew

  /// The link to the full session list, or a row menu's "Rename, move or
  /// delete": show the list.
  ShowingList

  /// A sidebar machine pill: narrow the list to the machine the pill names. The
  /// name is the one the server drew, and the page honours it only if the list it
  /// holds still offers a pill by that name (`listing.chosen`).
  Narrowing(machine: String)

  /// The sidebar's "All" pill: show every session.
  Widening

  /// A rail folder: narrow the inbox's list to its group. The folder is the one
  /// the server drew the button for, and the page honours it only for a folder
  /// its last reads still list (`shown_folder`). It changes what the page draws
  /// and sends the daemon nothing.
  FolderPicked(folder: inbox_rule.Folder)

  /// The reading pane's back control on a narrow screen: show the list. It
  /// closes the open thread's pane, so a thread's own state is dropped as a press
  /// on another thread drops it.
  InboxClosed

  /// The runtime made the relay's refresh timer. The first read of the
  /// orchestrator follows, on a page that has `Start.visiting`.
  RelayTimerReady(timer: Subject(Nil))

  /// The relay's refresh interval passed.
  RelayTicked

  /// The answer to the timer's read of the orchestrator, numbered by the read it
  /// answers. The timer is armed from it, so the next interval starts after the
  /// read. An answer a newer read overtook is dropped and arms the timer alone.
  /// It is the effect's own message, dispatched from the daemon's task.
  RelayRefreshed(serial: Int, read: relayed.Read)

  /// The answer to a read made after a press, numbered as `RelayRefreshed` is. It
  /// arms no timer: the interval already running fires on its own.
  RelayAnswered(serial: Int, read: relayed.Read)

  /// A press on the relayed session's centre. The message carries a value the
  /// server drew into the tree or the reply text the person typed, and the page
  /// judges it against the row it holds (`relayed_session.update`), so a forged
  /// one changes nothing. A page with no `Start.visiting` ignores it.
  Relaying(press: relayed_session.Msg)

  /// The daemon answered a reply. It is the effect's own message, dispatched from
  /// the daemon's task, and no handler carries it, so a browser cannot put an
  /// outcome on the page that the daemon did not reach.
  RelaySent(outcome: relayed.Outcome)

  /// The daemon answered a stop, as `RelaySent` is.
  RelayStopped(outcome: relayed.Outcome)

  /// The daemon answered an archive, as `RelaySent` is.
  RelayArchived(outcome: relayed.Outcome)

  /// The daemon answered a decision, as `RelaySent` is.
  RelayDecided(outcome: relayed.Outcome)

  /// The runtime made the timer of the sidebar's orchestrator reads. The first
  /// read follows.
  SideTimerReady(timer: Subject(Nil))

  /// The interval of the sidebar's orchestrator reads passed.
  SideTicked

  /// An orchestrator's list answered. It is the effect's own message, dispatched
  /// from the daemon's task, and no handler carries it.
  SideListed(orchestrator: String, read: orchestrators.ListRead)

  /// An orchestrator's offers answered the read numbered `serial`. An answer a
  /// newer read overtook is dropped. It is the effect's own message.
  OffersAnswered(
    orchestrator: String,
    serial: Int,
    read: orchestrators.OffersRead,
  )

  /// An orchestrator answered a create. It is the effect's own message,
  /// dispatched from the daemon's task, and no handler carries it.
  Founded(orchestrator: String, founding: orchestrators.Founding)

  /// A row of an orchestrator's sessions in the sidebar was pressed. The message
  /// names the orchestrator and the session the server drew into the tree, and the
  /// page honours it only for a row it holds.
  OpeningRelayed(orchestrator: String, session: String)
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
    reports: dict.new(),
    selected: Unchosen,
    presses: 0,
    opened: set.new(),
    folder: inbox_rule.Everything,
    shown: None,
    centre_choice: Awaiting,
    round: landing_rule.open(case start.projects {
      Some(_) -> landing_rule.Due
      None -> landing_rule.NotDue
    }),
    outbox: thread_send.Unsent,
    delivered: 0,
    feed: dict.new(),
    saved: dict.new(),
    evidence: dict.new(),
    briefs: dict.new(),
    brief_reads: dict.new(),
    brief_since: dict.new(),
    item: item_pane.closed(),
    item_presses: 0,
    reviews: dict.new(),
    review: review_pane.closed(),
    review_presses: 0,
    review_timer: None,
    review_rearm: Unscheduled,
    now: 0,
    status: Connecting,
    timer: None,
    reads: 0,
    departure: None,
    note: None,
    opening: None,
    resuming: None,
    creating: create.Idle,
    cards: placements.listed(start.executors, start.pools),
    place_reads: 0,
    recent: [],
    elsewhere: [],
    elsewhere_reads: 0,
    located: None,
    paging: None,
    edit: NotEditing,
    acting: actions.Calm,
    signins: [],
    link: NoLink,
    signin_notice: None,
    passkeys: [],
    passkey_asked: None,
    passkey_notice: None,
    name: start.name,
    naming: names.Ready,
    named: 0,
    pane: case start.visiting, start.create {
      Some(visit), _ ->
        Relayed(
          relayed_session.open(visit.orchestrator, visit.session)
          |> relayed_session.falling_back(visit.fallback),
        )
      None, Some(_) -> NewSession
      None, None -> SessionList
    },
    compose: composer.new(),
    filter: listing.Everywhere,
    relay_timer: None,
    relay_reads: 0,
    machines: case start.orchestrators {
      Some(held) -> orchestrators.new(held.names)
      None -> []
    },
    side_timer: None,
    boards: [],
    board_reads: 0,
    ticket: None,
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
//
// The relay's timer is a second subject of the same process. A page that shows
// no relayed session never arms it, so for the home it is two messages at start
// and nothing after. The sidebar's orchestrator reads have a third, which a page
// with no orchestrator never arms either.
/// Initializes the server component message timer selector effects.
fn wire() -> Effect(Msg) {
  use dispatch, timer <- server_component.select
  let relay_timer = process.new_subject()
  let side_timer = process.new_subject()
  let review_timer = process.new_subject()
  dispatch(TimerReady(timer))
  dispatch(RelayTimerReady(relay_timer))
  dispatch(SideTimerReady(side_timer))
  dispatch(ReviewTimerReady(review_timer))
  process.new_selector()
  |> process.select_map(timer, fn(_) { Ticked })
  |> process.select_map(relay_timer, fn(_) { RelayTicked })
  |> process.select_map(side_timer, fn(_) { SideTicked })
  |> process.select_map(review_timer, fn(_) { ReviewTicked })
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
          let #(model, reads) =
            approving(answered(model, listing), brief_rule.Refreshed)
          #(model, effect.batch([observing(model), attending(model), reads]))
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
          let model =
            Model(
              ..model,
              elsewhere_reads: model.elsewhere_reads + 1,
              board_reads: model.board_reads + 1,
            )
          let #(model, reads) = approving(model, brief_rule.Refreshed)
          #(
            model,
            effect.batch([
              observing(model),
              attending(model),
              reads,
              following(model, listing),
            ]),
          )
        }
        False -> #(model, arming(model))
      }

    // An ended page keeps the activity it last drew, as it keeps its list.
    Observed(rows:) ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> {
          let next = observed(model, rows)
          let #(reviewed, reading) = reviewing(next)
          let #(reviewed, reads) = approving(reviewed, brief_rule.Refreshed)
          #(reviewed, effect.batch([reads, reading]))
        }
      }

    // The sidebar's own presses. The pills change what the sidebar lists and ask
    // nothing of the daemon, and a name no pill carries is not a filter.
    Narrowing(machine:) ->
      case
        listing.chosen(
          listing.entries(model.groups),
          model.start.machine,
          machine,
        )
      {
        Ok(filter) -> #(Model(..model, filter:), effect.none())
        Error(Nil) -> #(model, effect.none())
      }

    Widening -> #(Model(..model, filter: listing.Everywhere), effect.none())

    // A folder narrows the inbox's list and brings the inbox to the centre: the
    // rail draws the folders on every centre, so a press from the composer, the
    // list, a ticket or a relayed session is the way back. A press for a folder
    // the page does not list changes nothing.
    FolderPicked(folder:) ->
      case
        folder == inbox_rule.Everything
        || list.any(folder_counts(model), fn(entry) { entry.0 == folder })
      {
        True -> #(
          Model(
            ..model,
            folder:,
            pane: inbox_pane(model),
            centre_choice: Decided(InboxCentre),
          ),
          effect.none(),
        )
        False -> #(model, effect.none())
      }

    // The way back from a pane on a narrow screen: the list is the page again,
    // with the default thread behind it, and nothing of the closed thread is
    // kept.
    InboxClosed -> #(
      Model(
        ..model,
        selected: Unchosen,
        item: item_pane.closed(),
        ticket: None,
        review: review_pane.closed(),
      )
        |> fn(closed) { Model(..closed, selected: settled_selection(closed)) },
      effect.none(),
    )

    // The relayed session page reads the orchestrator when its timer exists and
    // on every interval after, for as long as the page is served. A page with no
    // relayed session has nothing to read.
    RelayTimerReady(timer:) ->
      relay_reading(Model(..model, relay_timer: Some(timer)), RelayRefreshed)

    RelayTicked ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> relay_reading(model, RelayRefreshed)
      }

    // The timer's read answered: the row and the transcript are replaced, and
    // the timer is armed for the next read. An answer a newer read overtook is
    // dropped and still arms the timer, as the list's does.
    RelayRefreshed(serial:, read:) ->
      case serial == model.relay_reads {
        True -> #(relay_heard(model, read), relay_arming(model))
        False -> #(model, relay_arming(model))
      }

    RelayAnswered(serial:, read:) ->
      case serial == model.relay_reads {
        True -> #(relay_heard(model, read), effect.none())
        False -> #(model, effect.none())
      }

    Relaying(press:) -> relaying(model, press)

    // Each answer is applied to the page's state and followed by a read of the
    // orchestrator, so the transcript shows the message that landed, the run
    // that stopped, or the request that was decided without waiting for the
    // interval, and an outcome that is not known is settled by what the box says.
    RelaySent(outcome:) ->
      relay_after(model, fn(state) { relayed_session.replied(state, outcome) })

    RelayStopped(outcome:) ->
      relay_after(model, fn(state) { relayed_session.stopped(state, outcome) })

    RelayArchived(outcome:) ->
      relay_after(model, fn(state) { relayed_session.archived(state, outcome) })

    RelayDecided(outcome:) ->
      relay_after(model, fn(state) { relayed_session.decided(state, outcome) })

    // The sidebar lists each orchestrator's sessions. The first read follows the
    // timer's creation and one follows each interval, for as long as the page is
    // served. A page with no orchestrator has nothing to read.
    SideTimerReady(timer:) ->
      side_reading(Model(..model, side_timer: Some(timer)))

    ReviewTimerReady(timer:) -> #(
      Model(..model, review_timer: Some(timer)),
      effect.none(),
    )

    // The timer fires once for a run of refusals, and the scan goes on from the
    // session the refusal left unread.
    ReviewTicked ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected ->
          reviewing(Model(..model, review_rearm: Unscheduled))
      }

    SideTicked ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> side_reading(model)
      }

    // One orchestrator's list answered, whatever the answer was: the rows are
    // replaced, or kept and marked silent. Only that machine changes.
    SideListed(orchestrator:, read:) -> #(
      Model(
        ..model,
        machines: orchestrators.listing_heard(
          model.machines,
          orchestrator,
          read,
          model.start.now(),
        ),
      ),
      effect.none(),
    )

    OffersAnswered(orchestrator:, serial:, read:) -> #(
      Model(
        ..model,
        machines: orchestrators.offers_heard(
          model.machines,
          orchestrator,
          serial,
          read,
        ),
      ),
      effect.none(),
    )

    // A row's press departs for its relayed page, whose address is built here from
    // the page's key and a row the page holds: nothing the browser sent is in it.
    OpeningRelayed(orchestrator:, session:) ->
      case
        model.start.orchestrators,
        orchestrators.held_row(model.machines, orchestrator, session),
        model.status
      {
        Some(held), Ok(_), Connected | Some(held), Ok(_), Connecting -> #(
          Model(
            ..model,
            departure: Some(page.relayed_path(held.key, orchestrator, session)),
          ),
          effect.none(),
        )
        _, _, _ -> #(model, effect.none())
      }

    // An orchestrator answered a create. A session that was made departs for its
    // relayed page, or, when its first message did not arrive, is offered with the
    // words saying so. A refusal puts the form back.
    Founded(orchestrator:, founding:) -> founded(model, orchestrator, founding)

    InboxOpened(session:) -> {
      let next =
        Model(
          ..model,
          selected: Pressed(session),
          presses: model.presses + 1,
          opened: set.insert(model.opened, session),
          item: item_pane.closed(),
          review: case model.review.loaded, model.review.session {
            review_pane.Unavailable(_), Some(held) if held == session ->
              review_pane.closed()
            _, _ -> model.review
          },
          ticket: None,
        )
      let #(reviewed, reading) = reviewing(next)
      let #(reviewed, reads) = approving(reviewed, brief_rule.Opened)
      #(reviewed, effect.batch([reads, reading]))
    }

    // A send asks the daemon in a task of its own. A draft with nothing in it
    // or over the bound, a session the inbox does not draw, a page
    // that is not connected and a send already out ask nothing. Past that the
    // daemon is the authority: it checks the page and the session again.
    ThreadSubmitted(session:, text:, delivery:) ->
      case model.start.thread_send, model.status, model.outbox {
        Some(send), Connected, thread_send.Unsent
        | Some(send), Connected, thread_send.Settled(..)
        ->
          case
            thread_send.sendable(text),
            list.any(drawn_threads(model), fn(thread) { thread.id == session })
          {
            True, True -> #(
              Model(..model, outbox: thread_send.Sending(session, delivery)),
              {
                use dispatch <- effect.from
                send(session, text, delivery, fn(answer) {
                  dispatch(ThreadAnswered(session, answer))
                })
              },
            )
            True, False | False, _ -> #(model, effect.none())
          }
        Some(_), Connected, thread_send.Sending(..)
        | Some(_), Connecting, _
        | Some(_), Ended(_), _
        | None, _, _
        -> #(model, effect.none())
      }

    // The daemon's word on a send. A refusal keeps the draft and says why in
    // fixed words. A delivered message leaves an empty box and changes what the
    // session is doing, so the page asks for a fresh read at once and the
    // buttons follow the new state rather than waiting for the next list.
    ThreadAnswered(session:, answer:) -> {
      // The answer does not carry the delivery, so it is the one the outbox
      // recorded when the send went out; a stray answer reads as a prompt.
      let sent = case model.outbox {
        thread_send.Sending(out, delivery) if out == session -> delivery
        thread_send.Sending(..)
        | thread_send.Settled(..)
        | thread_send.Unsent -> operator.Prompt
      }

      // A delivery changes the session's state and asks for a fresh read; a
      // refusal changes nothing about it.
      case answer {
        thread_send.Delivered(_) -> {
          let next =
            Model(
              ..model,
              outbox: thread_send.Settled(session, sent, answer),
              delivered: model.delivered + 1,
            )
          #(next, observing(next))
        }
        thread_send.Refused(_) -> #(
          Model(..model, outbox: thread_send.Settled(session, sent, answer)),
          effect.none(),
        )
      }
    }

    // The feed's rows replace the last ones whole, so an answered ask and a
    // closed find leave the list at the next read. A page that ended keeps the
    // rows it last drew, as it keeps its list.
    FeedRead(rows:) ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> #(
          arrived(
            Model(..model, feed: dict.from_list(rows)),
            landing_rule.FeedSource,
          ),
          effect.none(),
        )
      }

    // The catalogue's summaries replace the last ones whole. They can arrive
    // when nothing runs, after a restart, and a summary that counts something
    // is part of what the first round decides the centre by.
    SavedRead(rows:) ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> #(
          arrived(
            Model(
              ..model,
              saved: dict.from_list(
                list.map(rows, fn(row) { #(row.session_id, row) }),
              ),
            ),
            landing_rule.SummarySource,
          ),
          effect.none(),
        )
      }

    // The brief replaces what the page held for that session, kept for each
    // session whose thread was shown and so bounded by the sessions viewed. A
    // refusal leaves a brief the page already holds, since the daemon allows six
    // reads in four seconds and a refused read says nothing about what the
    // session did.
    BriefRead(session:, since:, read:) ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected ->
          case read, dict.get(model.briefs, session) {
            Ok(brief), _ -> #(
              Model(
                ..model,
                briefs: dict.insert(
                  model.briefs,
                  session,
                  session_brief.Seen(brief),
                ),
                brief_since: dict.insert(model.brief_since, session, since),
              ),
              effect.none(),
            )
            Error(words), Error(Nil)
            | Error(words), Ok(session_brief.Unseen(_))
            -> #(
              Model(
                ..model,
                briefs: dict.insert(
                  model.briefs,
                  session,
                  session_brief.Unseen(words),
                ),
              ),
              effect.none(),
            )
            Error(_), Ok(session_brief.Seen(_)) -> #(model, effect.none())
          }
      }

    // The evidence replaces what the page held for that session. It is kept
    // for each session whose thread was shown, so it is bounded by the sessions
    // the page has viewed. A thread whose brief waited for the evidence reads it
    // now, and one whose read asked after another time reads again.
    ApprovalsRead(session:, read:) ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected ->
          briefing(
            Model(
              ..model,
              evidence: dict.insert(model.evidence, session, case read {
                Ok(evidence) -> approval_evidence.Seen(evidence)
                Error(words) -> approval_evidence.Unseen(words)
              }),
            ),
            brief_rule.Refreshed,
          )
      }

    // A scan's answer is kept as what it found and the review is dropped. A
    // read that found something starts the next due session at once. A refusal
    // does not: the daemon allows two reads in four seconds, so the reads that
    // follow a refusal would be refused too, and the next list or activity read
    // starts them again once the allowance has refilled.
    ReviewScanned(session:, message:, read:) ->
      case model.status {
        Ended(_) -> #(model, effect.none())
        Connecting | Connected -> {
          let next =
            Model(
              ..model,
              reviews: review_scan_rule.answered(
                model.reviews,
                session,
                message,
                read,
              ),
            )

          // A read that answered goes on to the next session, and a refusal stops.
          case read {
            Ok(_) -> reviewing(next)
            Error(words) -> {
              let #(opened, open, _) = opening_review(next)
              let #(armed, arm) = rearming(opened, words)
              #(armed, effect.batch([open, arm]))
            }
          }
        }
      }

    // The pane's own read of the tree is a fresh scan of it, so a successful one
    // also settles the session's classification: a tree the owner made clean
    // leaves "To review" once opened. A failed read says nothing of the tree
    // and leaves the classification as it was.
    ReviewRead(session:, read:) -> #(
      Model(
        ..model,
        review: review_pane.loaded(model.review, session, read),
        reviews: case read, model.review.session, model.review.read_for {
          Ok(_), Some(open), Some(message) if open == session ->
            review_scan_rule.answered(model.reviews, session, message, read)
          Ok(_), _, _ | Error(_), _, _ -> model.reviews
        },
      ),
      effect.none(),
    )

    // A find's revision is what a close names, so a close is staged only once
    // the record was read.
    ReviewFindRead(find:, read:) -> #(
      Model(
        ..model,
        review: review_pane.revision_read(
          model.review,
          find,
          result.try(read, fn(record) {
            case record {
              item_pane.FindRecord(revision:, ..) -> Ok(revision)
              item_pane.AskRecord(..) -> Error("That record is not a find.")
            }
          }),
        ),
      ),
      effect.none(),
    )

    // A page that may not act ignores every staging message, and the daemon
    // refuses the frames such a page could not have sent.
    ReviewVerdictChosen(verdict:) ->
      staged_review(model, review_pane.verdict(model.review, verdict))

    ReviewCommented(path:, text:) ->
      staged_review(model, review_pane.comment(model.review, path, text))

    ReviewFindStaged(find:, closure:, note:) ->
      staged_review(
        model,
        review_pane.find_action(model.review, find, closure, note),
      )

    ReviewCleared -> staged_review(model, review_pane.cleared(model.review))

    ReviewSent ->
      case acting(model), model.status {
        Some(act), Connected -> {
          let #(state, step) = review_pane.send(model.review)
          #(
            Model(..model, review: state),
            review_asking(act, model.review.session, step),
          )
        }
        _, _ -> #(model, effect.none())
      }

    ReviewClosed(find:, closure:, outcome:) ->
      case acting(model) {
        Some(act) -> {
          let #(state, step) =
            review_pane.closed_with(model.review, find, closure, outcome)
          let next = Model(..model, review: state)

          // A close the daemon refused dropped its revision, so the find is
          // read again now and not at the next refresh.
          let #(reopened, reopen, _) = opening_review(next)
          #(
            reopened,
            effect.batch([
              review_asking(act, model.review.session, step),
              attending(reopened),
              reopen,
            ]),
          )
        }
        None -> #(model, effect.none())
      }

    // A delivery empties the staging, and the browser keeps what was typed in
    // a form it still has, so the open count rises with it: the forms are
    // keyed by that count, and a form with a new key is a form with no text.
    ReviewPrompted(answer:) -> {
      let next =
        Model(
          ..model,
          review: review_pane.prompted(model.review, answer),
          review_presses: case answer {
            thread_send.Delivered(_) -> model.review_presses + 1
            thread_send.Refused(_) -> model.review_presses
          },
        )

      // "Send & next" moves to the thread that follows in "To review" once the
      // send was delivered, and stays on the receipt when none follows or the
      // send was refused. Opening the next thread is a press on its row.
      case answer, following_review(next, model.review.session) {
        thread_send.Delivered(_), Some(following) ->
          update(next, InboxOpened(following))
        _, _ -> #(next, attending(next))
      }
    }

    // An item's press opens its thread, for an item the last read still holds.
    // Its record is read by the daemon in a task of its own.
    ItemPicked(key:) ->
      case
        model.start.attention,
        attention_rule.find_item(current_items(model), key)
      {
        Some(reads), Some(_) -> {
          let #(state, reading) = item_pane.pick(model.item, key)
          let #(next, brief) =
            briefing(
              Model(
                ..model,
                item: state,
                item_presses: model.item_presses + 1,
                opened: set.insert(model.opened, attention_rule.opened_key(key)),
                ticket: None,
              ),
              brief_rule.Opened,
            )

          #(
            next,
            effect.batch([
              case reading {
                item_pane.ReadRecord -> {
                  use dispatch <- effect.from
                  reads.record(key.session, key.id, fn(read) {
                    dispatch(RecordRead(key, read))
                  })
                }
                item_pane.SkipRead -> effect.none()
              },
              brief,
            ]),
          )
        }
        Some(_), None | None, _ -> #(model, effect.none())
      }

    RecordRead(key:, read:) -> #(
      Model(..model, item: item_pane.loaded(model.item, key, read)),
      effect.none(),
    )

    // The form is checked here by the daemon's own rule and staged, and nothing
    // is sent. A page that may not act ignores it.
    ItemStaged(fields:) ->
      case acting(model), model.item.key, model.item.loaded {
        Some(_),
          Some(key),
          item_pane.Loaded(item_pane.AskRecord(ask:, revision:))
        ->
          case answer_rule.stage(key.session, ask, revision, fields) {
            Ok(staged) -> #(
              Model(..model, item: item_pane.staged_answer(model.item, staged)),
              effect.none(),
            )
            Error(problem) -> #(
              Model(..model, item: item_pane.refused(model.item, problem)),
              effect.none(),
            )
          }
        Some(_), Some(_), item_pane.Loaded(item_pane.FindRecord(..))
        | Some(_), Some(_), item_pane.NoRecord
        | Some(_), Some(_), item_pane.Loading
        | Some(_), Some(_), item_pane.Unavailable(_)
        | Some(_), None, _
        | None, _, _
        -> #(model, effect.none())
      }

    ItemNoted(text:) ->
      case acting(model) {
        Some(_) -> #(
          Model(..model, item: item_pane.staged_note(model.item, text)),
          effect.none(),
        )
        None -> #(model, effect.none())
      }

    ItemCleared ->
      case acting(model) {
        Some(_) -> #(
          Model(..model, item: item_pane.unstaged(model.item)),
          effect.none(),
        )
        None -> #(model, effect.none())
      }

    ItemSent -> sending_item(model)

    // A find's close names the revision the page read it at, so a find that
    // moved since is refused by the daemon and not closed.
    ItemClosed(closure:) ->
      case
        acting(model),
        model.item.key,
        model.item.loaded,
        model.item.progress
      {
        Some(act),
          Some(key),
          item_pane.Loaded(item_pane.FindRecord(revision:, ..)),
          item_pane.Resting
        | Some(act),
          Some(key),
          item_pane.Loaded(item_pane.FindRecord(revision:, ..)),
          item_pane.Settled(_)
        -> #(Model(..model, item: item_pane.sending(model.item)), {
          use dispatch <- effect.from
          act.close(key.session, key.id, revision, closure, fn(outcome) {
            dispatch(ItemActed(key, outcome))
          })
        })
        _, _, _, _ -> #(model, effect.none())
      }

    // Retry prompts the stuck strand itself, through the same path a message
    // typed on the session's page takes.
    ItemRetried ->
      case acting(model), model.item.key, model.item.progress {
        Some(act), Some(key), item_pane.Resting
        | Some(act), Some(key), item_pane.Settled(_)
        ->
          case key.sort {
            attention_rule.StuckSort -> #(
              Model(..model, item: item_pane.sending(model.item)),
              {
                use dispatch <- effect.from
                act.strand(
                  key.session,
                  key.id,
                  retry_words,
                  operator.Prompt,
                  fn(answer) { dispatch(ItemRetryAnswered(key, answer)) },
                )
              },
            )
            attention_rule.AskSort | attention_rule.FindSort -> #(
              model,
              effect.none(),
            )
          }
        _, _, _ -> #(model, effect.none())
      }

    // Dismiss names the failed run the page's last feed read held for the strand,
    // so a strand that failed again since is refused by the daemon and not
    // dismissed unseen. The daemon's word comes back as an answer's does.
    ItemDismissed ->
      case acting(model), model.item.key, model.item.progress {
        Some(act), Some(key), item_pane.Resting
        | Some(act), Some(key), item_pane.Settled(_)
        -> dismissing(model, act, key)
        _, _, _ -> #(model, effect.none())
      }

    // The daemon's word on an answer or a close. A success is followed by the
    // staged note, which goes to the strand once the answer is settled; a
    // refusal leaves the outbox for the owner to fix and send again.
    ItemActed(key:, outcome:) ->
      case model.item.key == Some(key), acting(model), outcome {
        // The only act on a stuck strand's thread that reaches this arm is a
        // dismissal. A staged note is a message to the strand, and sending it
        // would run the strand the owner just set aside, so it stays staged.
        True, Some(_), Succeeded(words:)
          if key.sort == attention_rule.StuckSort
        -> {
          let next =
            Model(
              ..model,
              item: item_pane.settled(model.item, words, item_pane.Nothing),
            )
          #(next, attending(next))
        }

        True, Some(act), Succeeded(words:) ->
          case item_pane.after_answer(model.item, strand_of(model, key)) {
            item_pane.NoteStep(session:, strand:, text:) -> #(
              Model(
                ..model,
                item: item_pane.sending(item_pane.settled(
                  model.item,
                  words,
                  item_pane.TheAnswer,
                )),
              ),
              noting(act, key, session, strand, text),
            )
            item_pane.AnswerStep(_) | item_pane.NothingStaged -> {
              let next =
                Model(
                  ..model,
                  item: item_pane.settled(
                    model.item,
                    words,
                    item_pane.Everything,
                  ),
                )
              #(next, attending(next))
            }
          }
        True, Some(_), Failed(words:) -> #(
          Model(
            ..model,
            item: item_pane.settled(model.item, words, item_pane.Nothing),
          ),
          effect.none(),
        )
        True, None, _ | False, _, _ -> #(model, effect.none())
      }

    ItemNoteAnswered(key:, answer:) ->
      case model.item.key == Some(key) {
        True -> {
          let words =
            thread_send.answer_words(answer, operator.Prompt, "the strand")

          // A delivery asks for a fresh read, and a refusal changes nothing the page holds.
          case answer {
            thread_send.Delivered(_) -> {
              let next =
                Model(
                  ..model,
                  item: item_pane.settled(
                    model.item,
                    words,
                    item_pane.Everything,
                  ),
                )
              #(next, attending(next))
            }
            thread_send.Refused(_) -> #(
              Model(
                ..model,
                item: item_pane.settled(model.item, words, item_pane.Nothing),
              ),
              effect.none(),
            )
          }
        }
        False -> #(model, effect.none())
      }

    ItemRetryAnswered(key:, answer:) ->
      case model.item.key == Some(key) {
        True -> {
          let next =
            Model(
              ..model,
              item: item_pane.settled(
                model.item,
                thread_send.answer_words(answer, operator.Prompt, "the strand"),
                item_pane.Nothing,
              ),
            )
          #(next, attending(next))
        }
        False -> #(model, effect.none())
      }

    // A ticket row opens its thread for a ticket the last board read still holds
    // as waiting on a person, and reads the ticket in full. The attention item
    // thread closes, since one pane shows one thread.
    TicketThreadPicked(key:) ->
      case
        model.start.projects,
        list.any(ticket_rule.waiting(model.boards), fn(each) { each.key == key })
      {
        Some(_), True ->
          reading_ticket_thread(
            Model(
              ..model,
              item: item_pane.closed(),
              opened: set.insert(model.opened, ticket_rule.opened_key(key)),
              ticket: Some(thread_reopened(model.ticket, key)),
            ),
            key,
          )
        Some(_), False | None, _ -> #(model, effect.none())
      }

    // A read keeps its detail for the thread that asked, and a ticket the
    // project no longer holds closes the thread.
    TicketThreadRead(key:, read:) ->
      case model.ticket {
        Some(opened) if opened.key == key ->
          ticket_thread_heard(model, opened, read)
        Some(_) | None -> #(model, effect.none())
      }

    TicketControlPressed(control:) -> ticket_pressed(model, control, "")

    TicketAnswerSent(seq:, text:) -> ticket_answered(model, seq, text)

    // The confirmation sends the act it asked about, if the daemon still lists
    // it for the ticket.
    TicketActConfirmed(key:, control:) -> ticket_confirmed(model, key, control)

    TicketActKept ->
      case model.ticket {
        Some(opened) -> #(
          Model(..model, ticket: Some(ticket_rule.cancelled(opened))),
          effect.none(),
        )
        None -> #(model, effect.none())
      }

    // The daemon's word on an act becomes the pane's notice, and the ticket and
    // the boards are read again so the pane and the list show what the daemon now
    // holds.
    TicketActSettled(key:, control:, outcome:) ->
      case model.ticket {
        Some(opened) if opened.key == key -> {
          let next =
            Model(
              ..model,
              ticket: Some(ticket_rule.settled(opened, control, outcome)),
            )
          let #(next, reading) = reading_ticket_thread(next, key)
          let #(next, boards) = reading_boards(next)

          #(next, effect.batch([reading, boards]))
        }
        Some(_) | None -> #(model, effect.none())
      }

    ShowingInbox -> #(
      Model(..model, centre_choice: Decided(InboxCentre)),
      effect.none(),
    )

    ShowingList -> #(
      Model(..model, pane: SessionList, centre_choice: Decided(ListCentre)),
      effect.none(),
    )

    ShowingNew ->
      case model.start.create {
        Some(_) -> #(
          Model(
            ..model,
            pane: NewSession,
            note: None,
            centre_choice: Decided(FormCentre),
          ),
          effect.none(),
        )
        None -> #(model, effect.none())
      }

    Composed(message:) ->
      composing(Model(..model, centre_choice: Decided(FormCentre)), message)

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
        | Some(_), Connected, create.Chosen(_)
        -> #(
          Model(..model, creating: create.Composing(workspace), note: None),
          effect.none(),
        )
        Some(_), Connected, create.Waiting(_)
        | Some(_), Connected, create.Sending
        | Some(_), Connected, create.Dispatching(_)
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
        create.Composing(_) | create.Elsewhere | create.Chosen(_) -> #(
          Model(..model, creating: create.Idle),
          effect.none(),
        )
        create.Idle
        | create.Waiting(_)
        | create.Sending
        | create.Dispatching(_) -> #(model, effect.none())
      }

    // The button opens the one form for a new session, if the page may create
    // and no creation is out. It closes a workspace's open form, as another
    // workspace's button does, and it starts the read of the placements when the
    // daemon has any: the cards are drawn at once from the names, and the read's
    // answer adds the states. A form that is already open is not read again, so
    // pressing the button twice asks the daemon once; closing the form and
    // opening it again reads afresh, which is how a person refreshes the states.
    OpeningElsewhere ->
      case model.start.create, model.status, model.creating {
        Some(_), Connected, create.Idle
        | Some(_), Connected, create.Composing(_)
        ->
          case placements.any(model.cards) {
            True -> reading_places(model)
            False -> #(
              Model(..model, creating: create.Elsewhere, note: None),
              effect.none(),
            )
          }
        Some(_), Connected, create.Elsewhere
        | Some(_), Connected, create.Chosen(_)
        | Some(_), Connected, create.Waiting(_)
        | Some(_), Connected, create.Sending
        | Some(_), Connected, create.Dispatching(_)
        | Some(_), Connecting, _
        | Some(_), Ended(_), _
        | None, _, _
        -> #(model, effect.none())
      }

    // The choice of this machine, if the form is open on an executor or a pool
    // and no creation is out.
    ChoosingHere ->
      case model.start.create, model.status, model.creating {
        Some(_), Connected, create.Chosen(_) -> #(
          Model(..model, creating: create.Elsewhere, note: None),
          effect.none(),
        )
        Some(_), _, _ | None, _, _ -> #(model, effect.none())
      }

    // A card's button chooses its placement, if the panel is open and no
    // creation is out, and only for a card the page drew: the choice is built by
    // the server from the names it holds, so a choice outside the cards did not
    // come from a button the page drew. Choosing another card moves the choice.
    // The state on the card is not consulted, because it is advice.
    ChoosingPlace(choice:) ->
      case model.start.create, model.status, model.creating {
        Some(_), Connected, create.Elsewhere
        | Some(_), Connected, create.Chosen(_)
        ->
          case placements.offers(model.cards, choice) {
            True -> #(
              Model(..model, creating: create.Chosen(choice), note: None),
              effect.none(),
            )
            False -> #(model, effect.none())
          }
        Some(_), _, _ | None, _, _ -> #(model, effect.none())
      }

    // The read of the placements answers: the cards take the daemon's report, or
    // keep their names and say the read gave nothing. An answer a newer read
    // overtook is dropped, and so is one for a page with no creation to offer.
    PlacementsRead(serial:, read:) ->
      case serial == model.place_reads, model.start.create {
        True, Some(_) -> #(
          Model(..model, cards: placements.after(read)),
          effect.none(),
        )
        True, None | False, _ -> #(model, effect.none())
      }

    // The registered form's submit is honoured only for its form while it is
    // open, as the others are, and only at the placement a card chose. The
    // placement is the page's own state, set by a button the server drew, so a
    // submit carries only what a person typed. The session is always shareable:
    // the daemon makes a session on an executor or in a pool session-only,
    // because its workspace aggregate is keyed by a path on the daemon's host.
    CreatingRemote(workspace:, name:, roles:) ->
      case model.start.create, model.status, model.creating {
        Some(ask), Connected, create.Chosen(choice) ->
          case
            offered_roles(model, roles)
            && offered_workspace(model, choice, workspace)
          {
            True -> #(
              Model(..model, creating: create.Dispatching(choice), note: None),
              creating(
                ask,
                registered_place(choice, workspace),
                name,
                creations.Shareable,
                roles,
                agency_limits.empty,
                "",
              ),
            )
            False -> #(model, effect.none())
          }
        Some(_), _, _ | None, _, _ -> #(model, effect.none())
      }

    // The typed folder's submit is honoured only for its form while it is open,
    // as a workspace's is. The path is the browser's text, so the daemon is
    // the one that decides what it names.
    CreatingElsewhere(path:, name:, sharing:, roles:) ->
      case model.start.create, model.status, model.creating {
        Some(ask), Connected, create.Elsewhere ->
          case offered_roles(model, roles) {
            True -> #(
              Model(..model, creating: create.Sending, note: None),
              creating(
                ask,
                creations.Typed(path),
                name,
                sharing,
                roles,
                agency_limits.empty,
                "",
              ),
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

    // A listing for the folder picker. The composer drops an answer that is not
    // for the trail it waits on, so a slow answer never overwrites a newer press.
    FolderBrowsed(trail:, answer:) ->
      case model.start.folders {
        Some(_) -> #(
          Model(
            ..model,
            compose: composer.browsed(model.compose, trail, answer),
          ),
          effect.none(),
        )
        None -> #(model, effect.none())
      }

    // The projects' boards. An answer a newer read overtook is dropped, and so is
    // one for a page that lists no projects; a read that could not ask keeps the
    // boards the page has. A board with the revision the page already holds
    // changes nothing, so the model is returned as it was and nothing is drawn
    // again. A new one replaces the boards and, if a ticket is open, asks for the
    // ticket again, because the board moved.
    BoardsRead(serial:, read:) ->
      case serial == model.board_reads, model.start.projects, read {
        True, Some(_), feed.Heard(projects: listed) ->
          boards_heard(model, feed.decode(listed))

        // A read that told nothing, or that a newer one overtook, still ends the
        // wait for the first board, so the round is not held open for ever.
        True, Some(_), feed.Unread | False, Some(_), _ -> #(
          arrived(model, landing_rule.BoardsSource),
          effect.none(),
        )
        True, None, _ | False, None, _ -> #(model, effect.none())
      }

    // A ticket's button opens its page, on a page that lists projects and only
    // for a pair the page holds. A press for a pair a read has since removed
    // opens nothing.
    OpeningTicket(project:, ticket:) ->
      case
        model.start.projects,
        model.status,
        feed.find(model.boards, project, ticket)
      {
        Some(_), Connected, Ok(_) ->
          reading_ticket(
            Model(
              ..model,
              pane: Ticketed(OpenTicket(
                project:,
                ticket:,
                detail: None,
                asking: projects_view.Ready,
                notice: None,
                answered: 0,
              )),
              note: None,
            ),
            project,
            ticket,
          )
        Some(_), Connected, Error(Nil)
        | Some(_), Connecting, _
        | Some(_), Ended(_), _
        | None, _, _
        -> #(model, effect.none())
      }

    // A ticket read keeps its detail for the page that asked, and a ticket the
    // project no longer holds sends the person back to where they came from.
    TicketRead(project:, ticket:, read:) ->
      case model.pane {
        Ticketed(open) if open.project == project && open.ticket == ticket ->
          ticket_heard(model, open, read)
        Ticketed(_) | NewSession | SessionList | Relayed(_) -> #(
          model,
          effect.none(),
        )
      }

    ClosingTicket -> #(Model(..model, pane: resting_pane(model)), effect.none())

    // The form sends the sequence number it was drawn with and the text. An
    // empty answer asks nothing, an answer past the box's limit is refused here
    // in words, and a page already sending one asks nothing. The sequence number
    // is not checked against the page's current question, because the daemon is
    // the authority: an answer to a question that has since changed is refused
    // there and the page says so.
    Answering(seq:, text:) ->
      case model.pane, model.start.projects, model.status {
        Ticketed(open), Some(Projects(answer:, ..)), Connected ->
          answering(model, open, answer, seq, text)
        Ticketed(_), Some(_), Connecting
        | Ticketed(_), Some(_), Ended(_)
        | Ticketed(_), None, _
        | NewSession, _, _
        | SessionList, _, _
        | Relayed(_), _, _
        -> #(model, effect.none())
      }

    // The close button asks the daemon once, and the box is busy until it
    // answers. Only a connected page with the capability asks.
    ClosingWork ->
      case model.pane, model.start.projects, model.status {
        Ticketed(open), Some(Projects(close:, ..)), Connected ->
          closing(model, open, close)
        Ticketed(_), Some(_), Connecting
        | Ticketed(_), Some(_), Ended(_)
        | Ticketed(_), None, _
        | NewSession, _, _
        | SessionList, _, _
        | Relayed(_), _, _
        -> #(model, effect.none())
      }

    // The daemon's word on a close, and then the read that shows the ticket as
    // it now stands.
    CloseSettled(project:, ticket:, closing:) ->
      case model.pane {
        Ticketed(open) if open.project == project && open.ticket == ticket ->
          close_settled(model, open, closing)
        Ticketed(_) | NewSession | SessionList | Relayed(_) -> #(
          model,
          effect.none(),
        )
      }

    // The daemon's word on an answer. A recorded one leaves an empty box, and a
    // refusal keeps the text and says why in words. Either way the ticket is read
    // again, so the page shows the question the daemon now has.
    AnswerSettled(project:, ticket:, answer:) ->
      case model.pane {
        Ticketed(open) if open.project == project && open.ticket == ticket ->
          settled(model, open, answer)
        Ticketed(_) | NewSession | SessionList | Relayed(_) -> #(
          model,
          effect.none(),
        )
      }

    // The first pages of the other orchestrators. An answer a newer read
    // overtook is dropped, and so is one for a page that lists none; a read that
    // could not ask keeps the rows the page has. A read that lists keeps the
    // pages "Show more" fetched when the first page is unchanged (`refreshed`),
    // and clears the page that was out, since its answer follows rows this read
    // may have replaced.
    ElsewhereRead(serial:, read:) ->
      case serial == model.elsewhere_reads, model.start.elsewhere, read {
        True, Some(_), elsewhere.Heard(groups:) -> {
          let groups = refreshed(model.elsewhere, groups)
          #(
            Model(
              ..model,
              elsewhere: groups,
              located: still_there(model, groups),
              paging: None,
            ),
            effect.none(),
          )
        }
        True, Some(_), elsewhere.Unread | True, None, _ | False, _, _ -> #(
          model,
          effect.none(),
        )
      }

    // "Where" opens the detail of a row the page holds, and only on a page that
    // lists the group. A press for a pair the page does not hold, such as one
    // that was drawn before a read replaced the rows, opens nothing.
    Locating(group:, session:) ->
      case model.start.elsewhere, holds_row(model.elsewhere, group, session) {
        Some(_), True -> #(
          Model(..model, located: Some(elsewhere_view.Detail(group:, session:))),
          effect.none(),
        )
        Some(_), False | None, _ -> #(model, effect.none())
      }

    Located -> #(Model(..model, located: None), effect.none())

    // "Show more" asks for the page after the last row the page holds for that
    // group, and only while the group has more and no page is out. The cursor is
    // read from the page's own rows, so a forged press names nothing but a group.
    ShowingMore(group:) ->
      case model.start.elsewhere, model.status, model.paging {
        Some(Elsewhere(next:, ..)), Connected, None ->
          case next_cursor(model.elsewhere, group) {
            Ok(after) -> #(
              Model(..model, paging: Some(group)),
              paging(next, group, after, model.elsewhere_reads),
            )
            Error(Nil) -> #(model, effect.none())
          }
        Some(_), _, _ | None, _, _ -> #(model, effect.none())
      }

    // The next page joins the group it was asked for, if the read that asked is
    // still the latest. A newer first-page read replaced the rows, so a page that
    // followed the old ones is dropped rather than joined to different rows.
    MoreRead(group:, serial:, read:) ->
      case
        model.start.elsewhere,
        serial == model.elsewhere_reads,
        model.paging == Some(group)
      {
        Some(_), True, True -> #(
          Model(
            ..model,
            elsewhere: joined(model.elsewhere, group, read),
            paging: None,
          ),
          effect.none(),
        )
        Some(_), _, _ | None, _, _ -> #(model, effect.none())
      }

    // A submit asks the daemon from its own task so the runtime stays free. It is
    // honoured only for the form that is open, so a second submit while the
    // first is out, a submit for a form that is not drawn, and a page that may
    // not create ask nothing. These arms are the second layer: the daemon
    // refuses the same requests from the grant it holds.
    Creating(workspace:, name:, sharing:, roles:) ->
      case model.start.create, model.status, model.creating {
        Some(ask), Connected, create.Composing(open) if open == workspace ->
          case offered_roles(model, roles) {
            True -> #(
              Model(..model, creating: create.Waiting(workspace), note: None),
              creating(
                ask,
                creations.Drawn(workspace),
                name,
                sharing,
                roles,
                agency_limits.empty,
                "",
              ),
            )
            False -> #(model, effect.none())
          }
        Some(_), _, _ | None, _, _ -> #(model, effect.none())
      }

    // A ticket departs for the new session. A refusal says why in the daemon's
    // fixed words and puts the form back. A creation that was accepted and did
    // not start says why in the owner's own startup reason, which only an
    // owner's page can hold, and either puts the form back for a retry when the
    // daemon released the reservation or closes it when the session was kept.
    Created(answer:) ->
      case answer {
        creations.Ticketed(path:) -> #(
          Model(
            ..model,
            departure: Some(path),
            creating: create.Idle,
            compose: composer.settled(model.compose),
          ),
          effect.none(),
        )
        creations.Declined(reason:) -> #(
          Model(
            ..model,
            note: Some(refusal(
              refused_at(model),
              creations.reason_words(reason),
            )),
            creating: reopened(model.creating, Correctable),
            compose: composer.refused(
              model.compose,
              creations.reason_words(reason),
            ),
          ),
          effect.none(),
        )
        creations.Unsent(path:) -> #(
          Model(..model, compose: composer.unsent(model.compose, path)),
          effect.none(),
        )
        creations.Unstarted(why:, remains:) -> #(
          Model(
            ..model,
            note: Some(refusal(
              refused_at(model),
              creations.unstarted_words(why, remains),
            )),
            creating: reopened(model.creating, case remains {
              creations.Dropped -> Correctable
              creations.InList -> Kept
            }),
            compose: composer.refused(
              model.compose,
              creations.unstarted_words(why, remains),
            ),
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

    // Move reads before it asks. The first press only asks the daemon which
    // orchestrators could take the session, and the answer opens the row's
    // chooser. A destination opens the confirmation, and the confirmation's
    // press is the one that asks the daemon to move. Each step acts only for
    // the stage the one before it left, so a forged press changes nothing.
    MoveRequested(session:) ->
      start_action(model, actions.Destinations, session)
    MoveChosen(session:, to:) -> chosen(model, session, to)
    MoveConfirmed(session:) -> move_confirmed(model, session)

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
        actions.Confirming(..) | actions.Choosing(..) -> #(
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
        // The read of destinations opens the row's chooser and changes nothing
        // on disk, so the list is not read again.
        actions.Working(session:, action: actions.Destinations),
          actions.Heard(candidates:)
        -> #(
          Model(
            ..model,
            acting: actions.Choosing(session, candidates),
            note: None,
          ),
          effect.none(),
        )
        actions.Working(..), actions.Heard(..) -> #(
          Model(..model, acting: actions.Calm),
          effect.none(),
        )
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
        actions.Calm, _ | actions.Confirming(..), _ | actions.Choosing(..), _ -> #(
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

    // The passkeys a read gave replace the page's own, and a read the registry
    // did not answer leaves them. A pending confirmation for a passkey that is no
    // longer listed is dropped, so "Confirm" never names a row that is gone.
    PasskeysRead(listing:) ->
      case listing {
        passkeys.Listed(rows:) -> #(listed_passkeys(model, rows), effect.none())
        passkeys.Unread -> #(model, effect.none())
      }

    // The first press only asks for a second. A page with no passkey capability
    // and one that ended ask nothing, as the daemon would refuse.
    PasskeyAsked(fingerprint:) ->
      case model.start.passkeys, model.status {
        Some(_), Connected -> #(
          Model(..model, passkey_asked: Some(fingerprint), passkey_notice: None),
          effect.none(),
        )
        Some(_), Connecting | Some(_), Ended(_) | None, _ -> #(
          model,
          effect.none(),
        )
      }

    // The second press asks the daemon, and only for the row that was asked
    // about: a "Confirm" for any other fingerprint does nothing.
    PasskeyConfirmed(fingerprint:) ->
      case model.start.passkeys, model.status, model.passkey_asked {
        Some(Passkeys(remove:, ..)), Connected, Some(asked)
          if asked == fingerprint
        -> #(
          Model(..model, passkey_asked: None),
          removing_passkey(fn() { remove(fingerprint) }),
        )
        _, _, _ -> #(model, effect.none())
      }
    PasskeyKept -> #(Model(..model, passkey_asked: None), effect.none())
    PasskeyAnswered(answer:) ->
      case answer {
        passkeys.Removed -> #(
          Model(
            ..model,
            passkey_notice: Some(
              "Removed that passkey. Browsers it signed in stay signed in until you sign them out.",
            ),
          ),
          reading_passkeys(model),
        )
        passkeys.Declined(reason:) -> #(
          Model(..model, passkey_notice: Some(passkeys.reason_words(reason))),
          reading_passkeys(model),
        )
      }

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
          // Identify which session opening or resuming action was declined.
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

/// Asks the daemon to end sign-ins in the component's own process, and hands the
/// answer back with the scope it was for. The registry call is bounded.
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

/// Starts the daemon's task that renames the page's principal and returns at
/// once; the task's answer arrives later as `NameAnswered`, dispatched from the
/// task's own process.
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

// Asks the daemon to remove a passkey in the component's own process.
fn removing_passkey(ask: fn() -> passkeys.Answer) -> Effect(Msg) {
  use dispatch <- effect.from
  dispatch(PasskeyAnswered(ask()))
}

/// The page with the passkeys a read gave, at most `passkeys.listed_limit` of
/// them. A pending confirmation for a passkey that is no longer listed is
/// dropped, so "Confirm" never names a row that is gone.
fn listed_passkeys(model: Model, rows: List(Passkey)) -> Model {
  let rows = list.take(rows, passkeys.listed_limit)
  let still_listed = fn(fingerprint) {
    list.any(rows, fn(row) { row.fingerprint == fingerprint })
  }

  // Only a confirmation whose row survived the read is kept.
  let asked = case model.passkey_asked {
    Some(fingerprint) ->
      case still_listed(fingerprint) {
        True -> model.passkey_asked
        False -> None
      }
    None -> None
  }

  Model(..model, passkeys: rows, passkey_asked: asked)
}

/// Reads the owner's passkeys again, after one was removed.
fn reading_passkeys(model: Model) -> Effect(Msg) {
  use dispatch <- effect.from

  // A page with no passkey capability has nothing to read.
  case model.start.passkeys {
    Some(Passkeys(read:, ..)) ->
      read(fn(listing) { dispatch(PasskeysRead(listing)) })
    None -> Nil
  }
}

// Starts the daemon's task that mints an admin ticket and returns at once; the
// answer arrives later as `AdminLinked`, dispatched from the task's own process.
fn opening_admin(ask: fn(fn(sessions.Answer) -> Nil) -> Nil) -> Effect(Msg) {
  use dispatch <- effect.from
  ask(fn(answer) { dispatch(AdminLinked(answer)) })
}

/// Stop and Archive: asks the daemon from its own task, for a page that was
/// handed the capability and is connected, and while no other request is out. A
/// confirmation that is open on another row is closed by the press.
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
        | Some(ask), Connected, actions.Choosing(..)
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

/// The action the sidebar's archive button means for a listed session, or none
/// for one the page does not list.
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

/// The first press of an action that asks twice: it opens that row's
/// confirmation and sends nothing. It replaces a confirmation open on another
/// row, and does nothing while a request is out.
fn confirm_first(
  model: Model,
  action: actions.Action,
  session: String,
) -> #(Model, Effect(Msg)) {
  use <- bool.lazy_guard(opening_now(model, session), fn() {
    #(model, effect.none())
  })

  // Check if management actions can be confirmed given current connection status.
  case model.start.manage, model.status, model.acting {
    Some(_), Connected, actions.Calm
    | Some(_), Connected, actions.Confirming(..)
    | Some(_), Connected, actions.Choosing(..)
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

/// The second press: it asks the daemon, and only for the row that is confirming
/// this action. Any other press asks nothing, which is what makes a forged
/// confirmation harmless.
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

/// A destination of the row's chooser was pressed: it opens that row's
/// confirmation for a move to it, and sends nothing. It acts only for the row
/// that is choosing and a destination that row was offered as eligible, which is
/// what makes a forged press harmless.
fn chosen(model: Model, session: String, to: String) -> #(Model, Effect(Msg)) {
  case model.start.manage, model.status, model.acting {
    Some(_), Connected, actions.Choosing(session: open, candidates:)
      if open == session
    ->
      case list.contains(move_candidates.eligible(candidates), to) {
        True -> #(
          Model(
            ..model,
            acting: actions.Confirming(session, actions.Move(to)),
            note: None,
          ),
          effect.none(),
        )
        False -> #(model, effect.none())
      }
    Some(_), _, _ | None, _, _ -> #(model, effect.none())
  }
}

/// The move confirmation's press: it asks the daemon to move, and only for the
/// row that is confirming a move, to the destination that confirmation names.
fn move_confirmed(model: Model, session: String) -> #(Model, Effect(Msg)) {
  case model.start.manage, model.status, model.acting {
    Some(ask),
      Connected,
      actions.Confirming(session: open, action: actions.Move(to:))
      if open == session
    -> #(
      Model(
        ..model,
        acting: actions.Working(session, actions.Move(to)),
        note: None,
      ),
      managing(ask, actions.Move(to), session),
    )
    Some(_), _, _ | None, _, _ -> #(model, effect.none())
  }
}

/// A note about a session, placed beside its row. The place carries the
/// session's workspace and name as the page has them now, so that the note can
/// still be drawn, naming the session, after the row is gone.
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

/// Starts the daemon's task for one action and returns at once; the answer
/// arrives later as `ActionAnswered`, dispatched from the task's own process.
fn managing(
  ask: fn(actions.Action, String, fn(actions.Answer) -> Nil) -> Nil,
  action: actions.Action,
  session: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  ask(action, session, fn(answer) { dispatch(ActionAnswered(answer)) })
}

/// Starts a read of the list now, after an action changed it, without arming
/// the timer: the interval already running will fire on its own. The read is
/// numbered, so an older read still in flight is dropped when it answers.
fn reading(model: Model) -> #(Model, Effect(Msg)) {
  let serial = model.reads + 1
  let model = Model(..model, reads: serial)
  let effect = {
    use dispatch <- effect.from
    model.start.sessions(fn(listing) { dispatch(Answered(serial, listing)) })
  }
  #(model, effect)
}

/// Starts the daemon's rename task and returns at once; the task's answer
/// arrives later as `RenameAnswered`, dispatched from the task's own process.
fn renaming(
  rename: fn(String, String, fn(renames.Answer) -> Nil) -> Nil,
  session: String,
  name: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  rename(session, name, fn(answer) { dispatch(RenameAnswered(answer)) })
}

/// The groups with one session's name replaced.
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

/// Starts the daemon's task and returns at once; the task's answer arrives
/// later as `Linked`, dispatched from the task's own process. Lustre's dispatch
/// sends to the runtime's mailbox, so it is safe to call from there.
fn resuming(
  resume: fn(String, fn(sessions.Answer) -> Nil) -> Nil,
  session: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  resume(session, fn(answer) { dispatch(Linked(answer)) })
}

/// Opens the form with this machine chosen and starts the read of the
/// placements, numbered so that only the newest answer is kept. The cards stay as
/// they were but are marked as being checked, so a state from an earlier read is
/// never drawn as though it were current.
fn reading_places(model: Model) -> #(Model, Effect(Msg)) {
  let serial = model.place_reads + 1
  #(
    Model(
      ..model,
      creating: create.Elsewhere,
      note: None,
      cards: placements.Cards(..model.cards, readiness: placements.Checking),
      place_reads: serial,
    ),
    placing(model.start.placements, serial),
  )
}

// A message from the composer. The composer applies it against the lists this
// page draws from and says what is owed: nothing, a fresh read of the placements
// (the Code list opened), or a creation, which is asked of the daemon from its own
// task as the old form's is. A page with no `Start.create`, or one not yet
// connected, asks nothing.
/// Handles interactions within the new session creation composer widget.
fn composing(model: Model, message: composer.Msg) -> #(Model, Effect(Msg)) {
  // Verify creation capability is available and page is connected.
  case model.start.create, model.status {
    Some(ask), Connected -> {
      let entries = listing.entries(model.groups)
      let #(compose, intent) =
        composer.update(
          model.compose,
          message,
          offers(model, entries),
          recents(model, entries),
        )
      let model = Model(..model, compose:) |> after_agent(model.compose.agent)

      // Translate composer update intent into home page side effects.
      case intent {
        composer.Stay -> #(model, effect.none())
        composer.ReadPlacements -> reading_cards(model)
        composer.Browse(trail:) -> browsing(model, trail)
        composer.ReadAgents -> reading_offers(model, names_of(model))
        composer.ReadOn(orchestrator:) -> reading_offers(model, [orchestrator])
        composer.CreateOn(orchestrator:, place:, prompt:, roles:) ->
          founding(model, orchestrator, place, roles, prompt)
        composer.Create(place:, name:, prompt:, roles:, agency:) -> #(
          Model(..model, note: None),
          creating(ask, place, name, creations.Private, roles, agency, prompt),
        )
        composer.Depart(path:) -> #(
          Model(..model, departure: Some(path)),
          effect.none(),
        )
      }
    }
    Some(_), Connecting | Some(_), Ended(_) | None, _ -> #(model, effect.none())
  }
}

// The lists the composer's choices are checked against. With this daemon as the
// agent they are the folders the page draws, the executors and pools with what
// the daemon last reported, and the profiles and models the daemon read when the
// page opened. With another orchestrator as the agent they are what that
// orchestrator last offered, and nothing until it has: a choice is then offered
// by no list, so a start asks nothing.
/// Evaluates selectable offers and choices presented by the composer.
fn offers(model: Model, entries: List(Entry)) -> composer.Offers {
  let agents = agent_rows(model)
  let here = model.start.machine

  // Determine choices based on selected agent destination.
  case model.compose.agent {
    composer.Here ->
      composer.Offers(
        machine: here,
        folders: composer.folders_offered(entries, model.recent),
        cards: model.cards,
        profiles: model.start.profiles,
        models: model.start.models,
        agent: composer.Here,
        here:,
        agents:,
        typing: composer.MayType,
      )
    composer.Orchestrator(name:) as agent ->
      case orchestrators.standing(model.machines, name) {
        orchestrators.Offering(offers: held) ->
          composer.Offers(
            machine: name,
            folders: held.folders,
            cards: held.cards,
            profiles: held.profiles,
            models: held.models,
            agent:,
            here:,
            agents:,
            typing: composer.MayNotType,
          )
        orchestrators.Asking | orchestrators.Refusing(_) ->
          composer.Offers(
            machine: name,
            folders: [],
            cards: placements.listed([], []),
            profiles: [],
            models: [],
            agent:,
            here:,
            agents:,
            typing: composer.MayNotType,
          )
      }
  }
}

// The Agent chip's rows: this daemon, then each orchestrator in configuration
/// Renders candidate target machines offering session agent hosting.
fn agent_rows(model: Model) -> List(composer.Candidate) {
  let here =
    composer.Candidate(
      agent: composer.Here,
      name: model.start.machine,
      standing: composer.Choosable("The daemon serving this page"),
    )

  [
    here,
    ..list.map(model.machines, fn(machine) {
      composer.Candidate(
        agent: composer.Orchestrator(machine.orchestrator),
        name: machine.orchestrator,
        standing: case machine.offer {
          orchestrators.Offering(_) ->
            composer.Choosable(orchestrators.busy_words(machine.rows))
          orchestrators.Asking -> composer.Checking
          orchestrators.Refusing(why:) -> composer.Unavailable(why)
        },
      )
    })
  ]
}

// The places "Start again where you worked" lists: this daemon's recent places
// while it is the agent, and none for another orchestrator, whose places the page
// does not keep.
fn recents(model: Model, entries: List(Entry)) -> List(composer.Recent) {
  case model.compose.agent {
    composer.Here -> composer.recents(entries, model.start.machine)
    composer.Orchestrator(_) -> []
  }
}

/// After the agent changed, the code, profile and model choices are judged
/// against the new machine's offers and kept only where it offers them
/// (`composer.kept`). A message that left the agent as it was changes nothing.
fn after_agent(model: Model, before: composer.Agent) -> Model {
  case model.compose.agent == before {
    True -> model
    False ->
      Model(
        ..model,
        compose: composer.kept(
          model.compose,
          offers(model, listing.entries(model.groups)),
        ),
      )
  }
}

// The keys of the orchestrators the page holds.
fn names_of(model: Model) -> List(String) {
  list.map(model.machines, fn(machine) { machine.orchestrator })
}

// Starts a read of each named orchestrator's offers and returns at once; each
// answer arrives as `OffersAnswered`, numbered by the read it answers. A name
// the page does not hold is not asked, and a page with no orchestrators asks
// nobody.
/// Starts reading orchestrator available tool offers in the background.
fn reading_offers(model: Model, names: List(String)) -> #(Model, Effect(Msg)) {
  // Check if orchestrator client integration is configured.
  case model.start.orchestrators {
    None -> #(model, effect.none())
    Some(held) -> {
      let #(machines, asked) =
        list.fold(names, #(model.machines, []), fn(so_far, name) {
          let #(machines, asked) = so_far

          // Ask each target machine for its latest offers.
          case orchestrators.ask_offers(machines, name) {
            #(machines, Ok(serial)) -> #(machines, [#(name, serial), ..asked])
            #(machines, Error(Nil)) -> #(machines, asked)
          }
        })

      let reads =
        list.map(asked, fn(each) {
          use dispatch <- effect.from
          held.offers(each.0, fn(read) {
            dispatch(OffersAnswered(each.0, each.1, read))
          })
        })

      #(Model(..model, machines:), effect.batch(reads))
    }
  }
}

// Starts the daemon's create on an orchestrator and returns at once; the answer
// arrives as `Founded`. The composer judged the place and the roles against the
/// Submits a request to create a session on a remote orchestrator.
fn founding(
  model: Model,
  orchestrator: String,
  place: creations.Place,
  roles: creations.Roles,
  prompt: String,
) -> #(Model, Effect(Msg)) {
  case model.start.orchestrators {
    Some(held) -> #(Model(..model, note: None), {
      use dispatch <- effect.from
      held.create(orchestrator, place, roles, prompt, fn(founding) {
        dispatch(Founded(orchestrator, founding))
      })
    })
    None -> #(
      Model(
        ..model,
        compose: composer.refused(
          model.compose,
          "This page cannot start a session on another machine.",
        ),
      ),
      effect.none(),
    )
  }
}

/// Handles remote orchestrator response after session founding creation attempt.
fn founded(
  model: Model,
  orchestrator: String,
  founding: orchestrators.Founding,
) -> #(Model, Effect(Msg)) {
  case model.start.orchestrators, founding {
    Some(held), orchestrators.Founded(session:) -> #(
      Model(
        ..model,
        departure: Some(page.relayed_path(held.key, orchestrator, session)),
        compose: composer.settled(model.compose),
      ),
      effect.none(),
    )
    Some(held), orchestrators.Unsent(session:) -> #(
      Model(
        ..model,
        compose: composer.unsent(
          model.compose,
          page.relayed_path(held.key, orchestrator, session),
        ),
      ),
      effect.none(),
    )
    _, orchestrators.Refused(why:) -> #(
      Model(..model, compose: composer.refused(model.compose, why)),
      effect.none(),
    )
    None, orchestrators.Founded(_) | None, orchestrators.Unsent(_) -> #(
      model,
      effect.none(),
    )
  }
}

// Starts a read of the list of each orchestrator that has none out and arms the
// timer for the next interval, on a page that holds orchestrators and has not
// ended. The interval is fixed and does not wait for the answers: a machine whose
// read is still out is skipped (`orchestrators.begin_listing`), so a slow box is
// asked one call at a time and a fast one is not held up by it.
/// Initiates periodic refresh read of remote orchestrator session listings.
fn side_reading(model: Model) -> #(Model, Effect(Msg)) {
  // Verify orchestrator service capability and connection status.
  case model.start.orchestrators, model.status {
    Some(held), Connecting | Some(held), Connected -> {
      let #(machines, owed) = orchestrators.begin_listing(model.machines)
      let reads =
        list.map(owed, fn(name) {
          use dispatch <- effect.from
          held.sessions(name, fn(read) { dispatch(SideListed(name, read)) })
        })

      // Arm timer if sidebar timer subject is registered.
      let arming = case model.side_timer {
        Some(timer) -> [
          {
            use _ <- effect.from
            let _ = process.send_after(timer, held.refresh_ms, Nil)
            Nil
          },
        ]
        None -> []
      }

      #(Model(..model, machines:), effect.batch(list.append(reads, arming)))
    }
    _, _ -> #(model, effect.none())
  }
}

/// Marks placement cards as checking and initiates placement options query.
fn reading_cards(model: Model) -> #(Model, Effect(Msg)) {
  let serial = model.place_reads + 1
  #(
    Model(
      ..model,
      cards: placements.Cards(..model.cards, readiness: placements.Checking),
      place_reads: serial,
    ),
    placing(model.start.placements, serial),
  )
}

/// Starts the daemon's read of the placements and returns at once; the answer
/// arrives later as `PlacementsRead`, dispatched from the daemon's own task.
fn placing(
  read: fn(fn(placements.Read) -> Nil) -> Nil,
  serial: Int,
) -> Effect(Msg) {
  use dispatch <- effect.from
  read(fn(answer) { dispatch(PlacementsRead(serial, answer)) })
}

/// Where a registered creation asks for its session: an executor's workspace, or
/// the same name registered on the executors of a pool.
fn registered_place(
  choice: placements.Choice,
  workspace: String,
) -> creations.Place {
  case choice {
    placements.OnExecutor(name:) -> creations.Registered(name, workspace)
    placements.InPool(name:) -> creations.Pooled(name, workspace)
  }
}

/// Starts the daemon's creation task and returns at once; the answer arrives
/// later as `Created`, dispatched from the task's own process. `prompt` is the
/// session's first message: empty sends none, and anything else is sent to the new
/// session once it is open. The older forms carry none.
fn creating(
  ask: fn(
    creations.Place,
    String,
    Sharing,
    creations.Roles,
    agency_limits.AgencyLimits,
    String,
    fn(creations.Answer) -> Nil,
  ) -> Nil,
  place: creations.Place,
  name: String,
  sharing: Sharing,
  roles: creations.Roles,
  agency: agency_limits.AgencyLimits,
  prompt: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  ask(place, name, sharing, roles, agency, prompt, fn(answer) {
    dispatch(Created(answer))
  })
}

// Whether submitted roles are ones the page offered: the default is always
// offered, and a profile name or a model key only if the daemon listed it when
// the page opened. The form's decoder already resolves a position in each list,
// so a submit that fails this check did not come from a form the page drew.
fn offered_roles(model: Model, roles: creations.Roles) -> Bool {
  offered(model.start.profiles, roles.profile)
  && offered(model.start.models, roles.model)
}

// Whether a submitted workspace is one the form could have sent for the place
// chosen. When the daemon listed the workspaces the place registers, the form
// drew a select, so only a listed name can come from it. When it listed none
// the form drew a text field, so any text that names a workspace can, and the
// daemon decides whether the executor serves it.
/// Verifies that a target workspace path is valid for the selected placement option.
fn offered_workspace(
  model: Model,
  choice: placements.Choice,
  workspace: String,
) -> Bool {
  case placements.workspaces(model.cards, choice) {
    [] -> result.is_ok(creations.registered_name(workspace))
    listed -> list.contains(listed, workspace)
  }
}

fn offered(listed: List(String), chosen: Option(String)) -> Bool {
  case chosen {
    None -> True
    Some(text) -> list.contains(listed, text)
  }
}

/// Asks the daemon to list one directory for the folder picker. A page with no
/// `Folders` capability cannot ask, so the picker closes instead of waiting for an
/// answer that will not come.
fn browsing(model: Model, trail: List(String)) -> #(Model, Effect(Msg)) {
  case model.start.folders {
    Some(Folders(browse:, ..)) -> #(Model(..model, note: None), {
      use dispatch <- effect.from
      browse(trail, fn(answer) { dispatch(FolderBrowsed(trail, answer)) })
    })
    None -> #(
      Model(
        ..model,
        compose: composer.State(..model.compose, browser: composer.Closed),
      ),
      effect.none(),
    )
  }
}

/// Starts the daemon's task that forgets one folder and returns at once; the list
/// that remains arrives later as `FoldersRead`, dispatched from the task.
fn forgetting(
  forget: fn(Int, fn(List(creations.Recent)) -> Nil) -> Nil,
  id: Int,
) -> Effect(Msg) {
  use dispatch <- effect.from
  forget(id, fn(rows) { dispatch(FoldersRead(rows)) })
}

/// Where a refused creation's words are drawn: beside the workspace's heading
/// when the form was open under a group the page draws, in the section for
/// folders that hold no session when it was open there or for a typed path, and
/// under the page's heading otherwise.
fn refused_at(model: Model) -> home_table.Place {
  case create.open_for(model.creating), model.creating {
    Some(workspace), _ ->
      case list.any(model.groups, fn(group) { group.workspace == workspace }) {
        True -> home_table.Workspace(workspace)
        False -> home_table.Elsewhere
      }
    None, create.Sending
    | None, create.Elsewhere
    | None, create.Chosen(_)
    | None, create.Dispatching(_)
    -> home_table.Elsewhere
    None, create.Idle | None, create.Composing(_) | None, create.Waiting(_) ->
      home_table.Page
  }
}

// What an answer leaves the person to do with the form.
type Outcome {
  // Nothing exists, so the form comes back for a correction.
  Correctable

  // The session exists in the list, so there is nothing to correct.
  Kept
}

/// Where the form stands after a refusal: open again under the workspace it was
/// for, so the person can correct it, unless the session was made and kept,
/// which leaves nothing to correct.
fn reopened(state: create.State, outcome: Outcome) -> create.State {
  case state, outcome {
    create.Waiting(_), Kept
    | create.Sending, Kept
    | create.Dispatching(_), Kept
    -> create.Idle
    create.Waiting(workspace), Correctable -> create.Composing(workspace)
    create.Sending, Correctable -> create.Elsewhere
    create.Dispatching(choice), Correctable -> create.Chosen(choice)
    create.Idle, _
    | create.Composing(_), _
    | create.Elsewhere, _
    | create.Chosen(_), _
    -> state
  }
}

// Starts the activity read for the running sessions the page lists, in the
// order it draws them and no more than `activity_limit`, and returns at once;
// the answer arrives later as `Observed`, dispatched from the daemon's task as
// `Linked` is. A page with no running session asks nothing, and a page that
// ended asks nothing more.
/// Triggers background observation reads for active sessions across all groups.
fn observing(model: Model) -> Effect(Msg) {
  let running =
    list.flat_map(model.groups, fn(group) { group.entries })
    |> list.filter(fn(entry) { entry.residency == Live })
    |> list.take(sessions.activity_limit)
    |> list.map(fn(entry) { entry.id })

  // Request activity metrics if there are running sessions and page is connected.
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

// Starts a numbered read of the orchestrator for the relayed session and
// returns at once; the daemon's task delivers what it found as the message
// `answer` builds. A page with no relayed session asks nothing.
/// Initiates a numbered read of active relayed session from remote orchestrator.
fn relay_reading(
  model: Model,
  answer: fn(Int, relayed.Read) -> Msg,
) -> #(Model, Effect(Msg)) {
  // Check if session visit capability is configured and currently active.
  case model.start.visiting, model.pane {
    Some(visit), Relayed(_) -> {
      let serial = model.relay_reads + 1
      let model = Model(..model, relay_reads: serial)
      let reading = {
        use dispatch <- effect.from
        visit.read(fn(read) { dispatch(answer(serial, read)) })
      }

      #(model, reading)
    }
    Some(_), NewSession
    | Some(_), SessionList
    | Some(_), Ticketed(_)
    | None, _
    -> #(model, effect.none())
  }
}

// Arms the relay's timer for the next read, when the runtime has made it and
// the page can still be served.
/// Arms the periodic refresh timer for the active relayed session.
fn relay_arming(model: Model) -> Effect(Msg) {
  // Check timer subject and visiting connection status.
  case model.relay_timer, model.start.visiting, model.pane, model.status {
    Some(timer), Some(visit), Relayed(_), Connecting
    | Some(timer), Some(visit), Relayed(_), Connected
    -> {
      use _ <- effect.from
      let _ = process.send_after(timer, visit.refresh_ms, Nil)
      Nil
    }
    _, _, _, _ -> effect.none()
  }
}

/// What a read of the orchestrator changes: the relayed session's state takes it,
/// stamped with this daemon's clock.
fn relay_heard(model: Model, read: relayed.Read) -> Model {
  case model.pane {
    Relayed(state) ->
      Model(
        ..model,
        pane: Relayed(relayed_session.heard(state, read, model.start.now())),
      )
    NewSession | SessionList | Ticketed(_) -> model
  }
}

// A press on the relayed session's centre. An ended page asks nothing: its
// principal's access is gone and the daemon would refuse. Otherwise the state
// judges the press against the row it holds and says what the page owes the
// daemon, which is asked from the daemon's own task.
/// Handles user interactions on the relayed session interface pane.
fn relaying(model: Model, press: relayed_session.Msg) -> #(Model, Effect(Msg)) {
  // Validate visiting session availability.
  case model.start.visiting, model.pane, model.status {
    Some(visit), Relayed(state), Connecting
    | Some(visit), Relayed(state), Connected
    -> {
      let #(state, intent) = relayed_session.update(state, press)

      #(Model(..model, pane: Relayed(state)), relay_asking(visit, intent))
    }
    _, _, _ -> #(model, effect.none())
  }
}

// The daemon's call for what the page owes. Each answer comes back as the
// message of its own kind.
/// Dispatches actionable intents on the relayed session to the host daemon.
fn relay_asking(visit: Visit, intent: relayed_session.Intent) -> Effect(Msg) {
  // Execute corresponding daemon call for intent.
  case intent {
    relayed_session.Stay -> effect.none()
    relayed_session.SendReply(text:) -> {
      use dispatch <- effect.from
      visit.send(text, fn(outcome) { dispatch(RelaySent(outcome)) })
    }
    relayed_session.StopRun -> {
      use dispatch <- effect.from
      visit.stop(fn(outcome) { dispatch(RelayStopped(outcome)) })
    }
    relayed_session.ArchiveSession -> {
      use dispatch <- effect.from
      visit.archive(fn(outcome) { dispatch(RelayArchived(outcome)) })
    }
    relayed_session.Decide(escalation:, seq:, choice:) -> {
      use dispatch <- effect.from
      visit.decide(escalation, seq, choice, fn(outcome) {
        dispatch(RelayDecided(outcome))
      })
    }
  }
}

/// Applies an answer to the relayed session's state and reads the orchestrator
/// again.
fn relay_after(
  model: Model,
  apply: fn(relayed_session.State) -> relayed_session.State,
) -> #(Model, Effect(Msg)) {
  case model.pane {
    Relayed(state) ->
      relay_reading(Model(..model, pane: Relayed(apply(state))), RelayAnswered)
    NewSession | SessionList | Ticketed(_) -> #(model, effect.none())
  }
}

/// Starts the timer's read, numbered. The daemon's task delivers the list,
/// which lands as `Refreshed`; the reads that follow it and the arming of the
/// timer wait for that answer, so the interval starts after the read, as it
/// did when the read was made here.
fn refreshing(model: Model) -> #(Model, Effect(Msg)) {
  let serial = model.reads + 1
  let model = Model(..model, reads: serial)
  let effect = {
    use dispatch <- effect.from
    model.start.sessions(fn(listing) { dispatch(Refreshed(serial, listing)) })
  }
  #(model, effect)
}

/// Starts the read of the open ticket thread's ticket from the daemon's own
/// task.
fn reading_ticket_thread(
  model: Model,
  key: ticket_rule.Key,
) -> #(Model, Effect(Msg)) {
  case model.start.projects {
    Some(Projects(ticket: read, ..)) -> #(model, {
      use dispatch <- effect.from
      read(key.project, key.ticket, fn(heard) {
        dispatch(TicketThreadRead(key, heard))
      })
    })
    None -> #(model, effect.none())
  }
}

/// Starts a read of the projects' boards, so the list shows what an act changed
/// without waiting for the next timer.
fn reading_boards(model: Model) -> #(Model, Effect(Msg)) {
  // A page with no projects capability has no board to read.
  case model.start.projects {
    Some(Projects(boards:, ..)) -> {
      // The serial is bumped as a list read bumps it, so a read this one
      // overtakes is dropped.
      let serial = model.board_reads + 1

      #(Model(..model, board_reads: serial), {
        use dispatch <- effect.from
        boards(fn(read) { dispatch(BoardsRead(serial, read)) })
      })
    }
    None -> #(model, effect.none())
  }
}

/// What a read of the open ticket thread's ticket changes. A detail that does
/// not decode is said in words and keeps what the pane had, and a ticket the
/// project no longer holds closes the thread.
fn ticket_thread_heard(
  model: Model,
  opened: ticket_rule.Opened,
  read: feed.TicketRead,
) -> #(Model, Effect(Msg)) {
  case read {
    feed.TicketHeard(detail: document) ->
      case board.decode_detail(document) {
        Ok(detail) -> #(
          Model(
            ..model,
            ticket: Some(ticket_rule.reconciled(
              ticket_rule.heard(opened, detail),
              ticket_standing(model),
            )),
          ),
          effect.none(),
        )
        Error(_) -> #(
          Model(..model, ticket: Some(ticket_rule.unreadable(opened))),
          effect.none(),
        )
      }
    feed.TicketGone -> #(Model(..model, ticket: None), effect.none())
    feed.TicketUnread -> #(model, effect.none())
  }
}

/// What the page may do to a ticket: operate when the page holds the projects
/// capability at the owner's Operator ceiling, which `closable` requires too.
/// Any other page draws the thread and no control.
fn ticket_standing(model: Model) -> ticket_rule.Standing {
  case model.start.projects, model.start.ceiling {
    Some(_), OperatorCeiling -> ticket_rule.Operating
    Some(_), ObserverCeiling | None, _ -> ticket_rule.Watching
  }
}

/// The ticket the open thread draws now: its last read, or the board's row.
fn open_ticket(model: Model) -> Option(#(ticket_rule.Opened, board.Ticket)) {
  case model.ticket {
    Some(opened) ->
      case ticket_rule.current(opened, model.boards) {
        Some(ticket) -> Some(#(opened, ticket))
        None -> None
      }
    None -> None
  }
}

/// A press on a control, with the text of an answer when the control is one and
/// empty otherwise. The authority is derived again here, at the press: the page
/// must be connected and hold the capability at the Operator ceiling, and the
/// control must be one the daemon lists for the ticket as it now stands. A press
/// that fails either asks nothing.
fn ticket_pressed(
  model: Model,
  control: ticket_rule.Control,
  text: String,
) -> #(Model, Effect(Msg)) {
  // The open ticket, the page's connection and its standing together say whether
  // this page may act at all; only then is the control itself judged.
  case open_ticket(model), model.status, ticket_standing(model) {
    Some(#(opened, ticket)), Connected, ticket_rule.Operating ->
      case ticket_rule.allowed(ticket, ticket_rule.Operating, control) {
        True -> ticket_stepped(model, ticket_rule.press(opened, control), text)
        False -> #(model, effect.none())
      }
    Some(_), Connected, ticket_rule.Watching
    | Some(_), Connecting, _
    | Some(_), Ended(_), _
    | None, _, _
    -> #(model, effect.none())
  }
}

/// What the rule made of a press: a confirmation to draw, an act to send, or
/// nothing.
fn ticket_stepped(
  model: Model,
  step: ticket_rule.Press,
  text: String,
) -> #(Model, Effect(Msg)) {
  case step {
    ticket_rule.Confirming(next) -> #(
      Model(..model, ticket: Some(next)),
      effect.none(),
    )
    ticket_rule.Send(next, sent) -> ticket_acted(model, next, sent, text)
    ticket_rule.Nothing -> #(model, effect.none())
  }
}

/// The thread to show for a press on a row: the one already open when the row
/// is its own, so a re-press keeps what is out and only reads again, and a new
/// one otherwise.
fn thread_reopened(
  held: Option(ticket_rule.Opened),
  key: ticket_rule.Key,
) -> ticket_rule.Opened {
  case held {
    Some(opened) if opened.key == key -> opened
    Some(_) | None -> ticket_rule.open(key)
  }
}

/// The press on a confirmation. It goes through the same gate as a press on a
/// control: the page must be connected and operate, the thread must be the one
/// the confirmation was drawn for, and the act must still be listed for the
/// ticket as it now stands. A confirmation that fails any of these sends
/// nothing.
fn ticket_confirmed(
  model: Model,
  key: ticket_rule.Key,
  control: ticket_rule.Control,
) -> #(Model, Effect(Msg)) {
  // The open ticket, the page's connection and its standing say whether this
  // page may act at all; only then is the confirmation itself judged.
  case open_ticket(model), model.status, ticket_standing(model) {
    Some(#(opened, ticket)), Connected, ticket_rule.Operating ->
      case
        opened.key == key
        && opened.confirm == ticket_rule.Asked(control)
        && ticket_rule.allowed(ticket, ticket_rule.Operating, control)
      {
        True ->
          case ticket_rule.confirmed(opened) {
            ticket_rule.Send(next, sent) -> ticket_acted(model, next, sent, "")
            ticket_rule.Confirming(_) | ticket_rule.Nothing -> #(
              model,
              effect.none(),
            )
          }
        False -> #(model, effect.none())
      }
    Some(_), Connected, ticket_rule.Watching
    | Some(_), Connecting, _
    | Some(_), Ended(_), _
    | None, _, _
    -> #(model, effect.none())
  }
}

/// An answer from the thread's form. An empty answer asks nothing, and one past
/// the box's limit is refused here in words. Past that the daemon is the
/// authority: an answer to a question that has since changed is refused there.
fn ticket_answered(
  model: Model,
  seq: Int,
  text: String,
) -> #(Model, Effect(Msg)) {
  // The box's own limits are judged before the press is.
  case string.trim(text), string.length(text) > ticket_thread.answer_limit {
    "", _ -> #(model, effect.none())
    _, True -> #(
      Model(
        ..model,
        ticket: option.map(model.ticket, fn(opened) {
          ticket_rule.Opened(
            ..opened,
            notice: Some(ticket_rule.Refused(
              "That answer is longer than the box allows.",
            )),
          )
        }),
      ),
      effect.none(),
    )
    _, False -> ticket_pressed(model, ticket_rule.Answer(seq), text)
  }
}

/// Sends the act through the capability the page holds, from the daemon's own
/// task, and answers `TicketActSettled`. The text is the answer's and is empty
/// for any other act.
fn ticket_acted(
  model: Model,
  opened: ticket_rule.Opened,
  control: ticket_rule.Control,
  text: String,
) -> #(Model, Effect(Msg)) {
  let model = Model(..model, ticket: Some(opened))
  let key = opened.key

  // A page with no projects capability has nothing to send through.
  case model.start.projects {
    Some(Projects(answer:, close:, stop:, retry:, ..)) -> #(model, {
      use dispatch <- effect.from
      let settle = fn(outcome) {
        dispatch(TicketActSettled(key, control, outcome))
      }

      // Each act goes through its own capability, and each answer is read into
      // the rule's one outcome.
      case control {
        ticket_rule.Answer(seq) ->
          answer(key.project, key.ticket, seq, text, fn(told) {
            settle(case told {
              feed.Recorded -> feed.Acted
              feed.Refused(code:) -> feed.Declined(code)
            })
          })
        ticket_rule.Close ->
          close(key.project, key.ticket, fn(told) {
            settle(case told {
              feed.Closed -> feed.Acted
              feed.NotClosed(code:) -> feed.Declined(code)
            })
          })
        ticket_rule.Retry -> retry(key.project, key.ticket, settle)
        ticket_rule.Stop -> stop(key.project, key.ticket, settle)
      }
    })
    None -> #(model, effect.none())
  }
}

/// The boards a read gave. A board set equal to the one held changes nothing; a
/// new one replaces it, and an open ticket is read again when its project's board
/// has moved past the revision its detail was read at.
fn boards_heard(
  model: Model,
  boards: List(feed.Loaded),
) -> #(Model, Effect(Msg)) {
  // Equal boards mean the revision did not move, because a revision is part of
  // what a decoded board holds.
  case boards == model.boards {
    True -> #(arrived(model, landing_rule.BoardsSource), effect.none())
    False -> {
      // The boards are stored before the round hears of them, so a ticket they
      // hold is part of what the round decides by.
      let model = arrived(Model(..model, boards:), landing_rule.BoardsSource)

      // A ticket page is refreshed only when it is open and stale, so a board
      // that moved elsewhere costs the open page nothing. The same holds for
      // the inbox's ticket thread.
      case model.pane, model.ticket {
        Ticketed(open), _ ->
          case ticket_is_stale(boards, open) {
            True -> reading_ticket(model, open.project, open.ticket)
            False -> #(model, effect.none())
          }
        NewSession, Some(opened)
        | SessionList, Some(opened)
        | Relayed(_), Some(opened)
        ->
          case ticket_rule.stale(opened, boards) {
            True -> reading_ticket_thread(model, opened.key)
            False -> #(model, effect.none())
          }
        NewSession, None | SessionList, None | Relayed(_), None -> #(
          model,
          effect.none(),
        )
      }
    }
  }
}

/// Whether the open ticket's detail is missing or older than its project's board.
fn ticket_is_stale(boards: List(feed.Loaded), open: OpenTicket) -> Bool {
  case open.detail {
    None -> True
    Some(detail) ->
      case list.find(boards, fn(each) { each.id == open.project }) {
        Ok(feed.Loaded(board: Some(held), ..)) ->
          detail.revision < held.revision
        Ok(feed.Loaded(board: None, ..)) | Error(Nil) -> False
      }
  }
}

/// Starts the read of one ticket from the daemon's own task.
fn reading_ticket(
  model: Model,
  project: String,
  ticket: String,
) -> #(Model, Effect(Msg)) {
  case model.start.projects {
    Some(Projects(ticket: read, ..)) -> #(model, {
      use dispatch <- effect.from
      read(project, ticket, fn(heard) {
        dispatch(TicketRead(project, ticket, heard))
      })
    })
    None -> #(model, effect.none())
  }
}

/// What a ticket read changes on the open page.
fn ticket_heard(
  model: Model,
  open: OpenTicket,
  read: feed.TicketRead,
) -> #(Model, Effect(Msg)) {
  case read {
    feed.TicketHeard(detail: document) ->
      case board.decode_detail(document) {
        Ok(detail) -> #(
          Model(
            ..model,
            pane: Ticketed(OpenTicket(..open, detail: Some(detail))),
          ),
          effect.none(),
        )
        Error(_) -> #(
          Model(
            ..model,
            pane: Ticketed(
              OpenTicket(
                ..open,
                notice: Some(projects_view.Refusal(
                  "This ticket could not be read.",
                )),
              ),
            ),
          ),
          effect.none(),
        )
      }
    feed.TicketGone -> #(
      Model(..model, pane: resting_pane(model)),
      effect.none(),
    )
    feed.TicketUnread -> #(model, effect.none())
  }
}

/// The pane under the inbox when a folder is pressed. The composer and the list
/// keep their state beneath the inbox; a ticket's page and a relayed session
/// are the centre's whole subject, so leaving for the inbox closes them as their
/// own way back does.
fn inbox_pane(model: Model) -> Pane {
  case model.pane {
    Ticketed(_) | Relayed(_) -> resting_pane(model)
    NewSession | SessionList -> model.pane
  }
}

/// The centre the page returns to when a ticket page closes: the composer for the
/// owner's operating page, and the list otherwise.
fn resting_pane(model: Model) -> Pane {
  case model.start.create {
    Some(_) -> NewSession
    None -> SessionList
  }
}

/// Sends an answer, or says why it will not be sent.
fn answering(
  model: Model,
  open: OpenTicket,
  answer: fn(String, String, Int, String, fn(feed.Answer) -> Nil) -> Nil,
  seq: Int,
  text: String,
) -> #(Model, Effect(Msg)) {
  // Only an idle box with something in it, within the limit, asks the daemon.
  case
    open.asking,
    string.trim(text),
    string.length(text) > projects_view.answer_limit
  {
    projects_view.Sending, _, _ | projects_view.Ready, "", _ -> #(
      model,
      effect.none(),
    )
    projects_view.Ready, _, True -> #(
      Model(
        ..model,
        pane: Ticketed(
          OpenTicket(
            ..open,
            notice: Some(projects_view.Refusal(
              "That answer is longer than the box allows.",
            )),
          ),
        ),
      ),
      effect.none(),
    )
    projects_view.Ready, _, False -> #(
      Model(
        ..model,
        pane: Ticketed(
          OpenTicket(..open, asking: projects_view.Sending, notice: None),
        ),
      ),
      {
        use dispatch <- effect.from
        answer(open.project, open.ticket, seq, text, fn(outcome) {
          dispatch(AnswerSettled(open.project, open.ticket, outcome))
        })
      },
    )
  }
}

/// Sends a close, unless one is already out.
fn closing(
  model: Model,
  open: OpenTicket,
  close: fn(String, String, fn(feed.Closing) -> Nil) -> Nil,
) -> #(Model, Effect(Msg)) {
  // A page already closing asks nothing more.
  case open.asking {
    projects_view.Sending -> #(model, effect.none())
    projects_view.Ready -> #(
      Model(
        ..model,
        pane: Ticketed(
          OpenTicket(..open, asking: projects_view.Sending, notice: None),
        ),
      ),
      {
        use dispatch <- effect.from
        close(open.project, open.ticket, fn(outcome) {
          dispatch(CloseSettled(open.project, open.ticket, outcome))
        })
      },
    )
  }
}

/// What the daemon's word on a close changes, and the read that follows it.
fn close_settled(
  model: Model,
  open: OpenTicket,
  closing: feed.Closing,
) -> #(Model, Effect(Msg)) {
  // Either way the daemon has judged the close, so the page is ready again.
  let next = case closing {
    feed.Closed ->
      OpenTicket(
        ..open,
        asking: projects_view.Ready,
        notice: Some(projects_view.Told("Ticket closed.")),
      )
    feed.NotClosed(code:) ->
      OpenTicket(
        ..open,
        asking: projects_view.Ready,
        notice: Some(projects_view.Refusal(board.close_refusal_words(code))),
      )
  }

  reading_ticket(
    Model(..model, pane: Ticketed(next)),
    open.project,
    open.ticket,
  )
}

/// What the daemon's word on an answer changes, and the read that follows it.
fn settled(
  model: Model,
  open: OpenTicket,
  answer: feed.Answer,
) -> #(Model, Effect(Msg)) {
  // A recorded answer leaves an empty box and a refused one keeps the text, and
  // both leave the box ready for the next, since the daemon has judged this one.
  let next = case answer {
    feed.Recorded ->
      OpenTicket(
        ..open,
        asking: projects_view.Ready,
        notice: Some(projects_view.Told("Answer queued for the worker.")),
        answered: open.answered + 1,
      )
    feed.Refused(code:) ->
      OpenTicket(
        ..open,
        asking: projects_view.Ready,
        notice: Some(projects_view.Refusal(board.answer_refusal_words(code))),
      )
  }

  reading_ticket(
    Model(..model, pane: Ticketed(next)),
    open.project,
    open.ticket,
  )
}

// Arms the timer for the next read, when the runtime has made it.
/// Arms the periodic refresh timer for local sessions list.
fn arming(model: Model) -> Effect(Msg) {
  // Verify timer subject is available.
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
/// Handles following background queries after listing refresh answers.
fn following(model: Model, listing: Listing) -> Effect(Msg) {
  // Match listing state to trigger secondary reads.
  case listing {
    Closed(..) -> effect.none()
    Listed(_) | Unread ->
      effect.batch([
        {
          use dispatch <- effect.from
          model.start.signins(fn(read) { dispatch(SigninsRead(read)) })
          model.start.who(fn(name) { dispatch(NameRead(name)) })

          // The owner's passkeys are read with the list, when the page has them.
          case model.start.passkeys {
            Some(Passkeys(read:, ..)) ->
              read(fn(listing) { dispatch(PasskeysRead(listing)) })
            None -> Nil
          }

          // Refresh folders list if available.
          case model.start.folders {
            Some(Folders(recent:, ..)) ->
              recent(fn(rows) { dispatch(FoldersRead(rows)) })
            None -> Nil
          }

          // Refresh remote orchestrators if available.
          case model.start.elsewhere {
            Some(Elsewhere(groups:, ..)) -> {
              let serial = model.elsewhere_reads
              groups(fn(read) { dispatch(ElsewhereRead(serial, read)) })
            }
            None -> Nil
          }

          // Refresh the projects' boards if the page lists them.
          case model.start.projects {
            Some(Projects(boards:, ..)) -> {
              let serial = model.board_reads
              boards(fn(read) { dispatch(BoardsRead(serial, read)) })
            }
            None -> Nil
          }
        },
        arming(model),
      ])
  }
}

/// What a read changes. A list replaces the groups, so a session that is gone
/// is gone from the page, and a closed page keeps the last list it drew with
/// the notice beside it, as a session's page keeps its last capture.
fn answered(model: Model, listing: Listing) -> Model {
  // Only a list that was read changes the groups; an unread one changes
  // nothing and a closed page keeps what it drew.
  case listing {
    Listed(entries:) -> {
      let listed =
        Model(
          ..model,
          groups: sessions.grouped(list.take(entries, sessions.listed_limit)),
          now: model.start.now(),
          status: Connected,
        )

      // The list says which of the reads that follow it the page will ask, and
      // the round waits for those and decides when the last has answered.
      let #(round, close) =
        landing_rule.listed(
          listed.round,
          activity: activity_reading(listed),
          summary: summary_reading(listed),
          feed: feed_reading(listed),
        )

      concluded(Model(..listed, round:), close)
    }

    // A list that could not be read is no answer to wait on: the reads that
    // depend on it cannot be known to be due, and the timer reads again. The
    // round stays open, so the first list that is read decides with the rest.
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

/// How many reads of the other orchestrators the page has started. An answer
/// carries the number of the read it answers (`ElsewhereRead`, `MoreRead`).
///
/// ## Examples
///
/// ```gleam
/// // home.update(model, home.ElsewhereRead(home.elsewhere_reads(model), read))
/// ```
pub fn elsewhere_reads(model: Model) -> Int {
  model.elsewhere_reads
}

/// How many reads of the projects' boards the page has started, which numbers
/// the next. A test uses it to answer the read the page last asked for.
///
/// ## Examples
///
/// ```gleam
/// // home.update(model, home.BoardsRead(home.board_reads(model), read))
/// ```
pub fn board_reads(model: Model) -> Int {
  model.board_reads
}

/// Returns the grouped sessions list currently held in model state.
///
/// ## Examples
///
/// ```gleam
/// assert home.groups(model) == []
/// ```
pub fn groups(model: Model) -> List(Group) {
  model.groups
}

/// How many reads of the orchestrator the relayed session page has started. An
/// answer carries the number of the read it answers.
///
/// ## Examples
///
/// ```gleam
/// assert home.relay_reads(home.new(start)) == 0
/// ```
pub fn relay_reads(model: Model) -> Int {
  model.relay_reads
}

/// Which centre the page shows.
///
/// ## Examples
///
/// ```gleam
/// assert home.pane(home.new(start)) == home.SessionList
/// ```
pub fn pane(model: Model) -> Pane {
  model.pane
}

/// The composer's state: which agent and which code the person chose.
///
/// ## Examples
///
/// ```gleam
/// assert home.composer_state(home.new(start)).agent == composer.Here
/// ```
pub fn composer_state(model: Model) -> composer.State {
  model.compose
}

/// What the page holds of each orchestrator the daemon relays for, in
/// configuration order. A page with no orchestrators holds none.
///
/// ## Examples
///
/// ```gleam
/// assert home.machines(home.new(start)) == []
/// ```
pub fn machines(model: Model) -> List(orchestrators.Machine) {
  model.machines
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
      title: case model.pane, landed_inbox(model) {
        NewSession, True | SessionList, True -> "Inbox"
        NewSession, False -> "New session"
        SessionList, False -> "Sessions"
        Ticketed(_), _ -> "Ticket"
        Relayed(_), _ -> "Session"
      },
      who: home_bar.account(
        model.name,
        ceiling_words(model.start.ceiling),
        account_panel(model),
      ),
      status: status_words(model.status),
      tone: status_tone(model.status),
      notice: ended.home(ended_ending(model.status)),
      trailing: admin_offer(model),
      needing: case landed_inbox(model) {
        True -> needing_count(model)
        False -> 0
      },
    ),
    shell_sidebar(model),
    [
      // The first child keeps the centre's body at `table_path`. It is the strip
      // that says the daemon lists a peer orchestrator, or an empty node, and the
      // composer has no use for it.
      centre_head(model),
      centre_body(model),
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
        passkeys_view.view(passkey_offer(model)),
      ),
      switch.view(model.departure),
      switch.switcher(),
    ],
    element.none(),
    0,
    0,
    None,
    "",
    list.length(listing.waiting(listing.entries(model.groups), model.activity)),
  )
}

/// The centre's first child, which sits above the body: the Projects section on
/// the owner's page when it has one to draw, with the strip that says the daemon
/// lists a peer orchestrator, and the strip alone, or nothing, otherwise. A page
/// without projects draws exactly what it drew before this section existed. The
/// section's buttons are beneath `projects_path`, which only the owner's socket
/// admits.
fn centre_head(model: Model) -> Element(Msg) {
  // The peer strip belongs to the list alone, as it did before the section.
  let strip = case model.pane {
    NewSession | Relayed(_) | Ticketed(_) -> element.none()
    SessionList -> elsewhere_view.strip(elsewhere_offer(model))
  }

  // The section is drawn above the composer and the list and not above a
  // ticket's page or a relayed session, which are the centre's whole subject.
  case projects_offer(model), model.pane {
    projects_view.Hidden, _ -> strip
    projects_view.Shown(..), Ticketed(_)
    | projects_view.Shown(..), Relayed(_)
    -> strip
    offer, NewSession | offer, SessionList ->
      html.div([attribute.class("home-head")], [
        projects_view.section(offer),
        strip,
      ])
  }
}

/// What the page offers for projects: the section on a page with
/// `Start.projects` that has read at least one project, and nothing otherwise.
fn projects_offer(model: Model) -> projects_view.Offer(Msg) {
  case model.start.projects, model.boards {
    Some(_), [_, ..] ->
      projects_view.Shown(
        projects: model.boards,
        now: model.now,
        open: OpeningTicket,
      )
    Some(_), [] | None, _ -> projects_view.Hidden
  }
}

/// The open ticket's page, with the press that opens its worker's session when
/// the page holds that session's row.
fn ticket_page(model: Model, open: OpenTicket) -> Element(Msg) {
  let held = feed.find(model.boards, open.project, open.ticket)

  // The ticket read is newer than the board's row for it, so it wins when it has
  // answered; before that the board's row draws the page.
  let current = case open.detail, held {
    Some(detail), _ -> Ok(detail.ticket)
    None, Ok(found) -> Ok(found)
    None, Error(Nil) -> Error(Nil)
  }

  // A ticket neither source holds is not drawn as a page; the person is told and
  // offered the way back.
  case current {
    Error(Nil) ->
      html.p([attribute.class("home-empty")], [
        html.text("This ticket is not on the board."),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("home-new"),
            event.on_click(ClosingTicket),
          ],
          [html.text("Back")],
        ),
      ])
    Ok(ticket) ->
      projects_view.ticket_page(projects_view.Page(
        ticket:,
        detail: open.detail,
        now: model.now,
        asking: open.asking,
        notice: open.notice,
        answered: open.answered,
        back: ClosingTicket,
        answer: Answering,
        close: closable(ticket, model),
        worker: option.then(ticket.session, worker_press(model, _)),
      ))
  }
}

/// The press that closes a ticket, when the page may ask the daemon and the
/// daemon lists a close for the ticket. The daemon's list is the engine's own
/// rule, so no button could only be refused.
fn closable(ticket: board.Ticket, model: Model) -> Option(Msg) {
  case
    board.offers(ticket, board.CanClose),
    model.start.projects,
    model.start.ceiling
  {
    True, Some(_), OperatorCeiling -> Some(ClosingWork)
    True, Some(_), ObserverCeiling | True, None, _ | False, _, _ -> None
  }
}

/// The press that opens a worker's session: the row's own press when the page
/// holds the row, so a running session opens and a saved one resumes. A
/// session the lists do not hold is the project's own, and the ticket still
/// reaches it: a resume for an operating page, which opens a running session
/// as well, and an open for an observing one. A saved session an observer
/// cannot resume has no button.
fn worker_press(model: Model, session: String) -> Option(Msg) {
  case
    list.find(listing.entries(model.groups), fn(each) { each.id == session })
  {
    Ok(sessions.Entry(residency: Live, ..)) -> Some(Opening(session))
    Ok(sessions.Entry(residency: sessions.Saved, ..)) ->
      case model.start.ceiling {
        OperatorCeiling -> Some(Resuming(session))
        ObserverCeiling -> None
      }

    // The list does not hold the row: a worker's session is the project's, and
    // the lists leave it out. The ticket page still reaches it, and the daemon
    // judges the press as it judges any other.
    Ok(_) | Error(Nil) ->
      case model.start.ceiling {
        OperatorCeiling -> Some(Resuming(session))
        ObserverCeiling -> Some(Opening(session))
      }
  }
}

/// The centre's second child, which is the one region the socket admits a click,
/// a submit and a typed search beneath: the composer for the owner while the pane
/// is the new session's, and the list otherwise. Both sit at `table_path`, so the
/// admission is the same for both and no path moves.
fn centre_body(model: Model) -> Element(Msg) {
  case landed_inbox(model) {
    True -> inbox_page(model)
    False -> centre_pane(model)
  }
}

/// The running sessions the page lists that the daemon's last activity read
/// answered for, as the inbox's threads. A report for a session the page's own
/// list does not hold is not drawn: the list is what the daemon authorized, and
/// a saved session has no report to read.
fn inbox_threads(model: Model) -> List(inbox_rule.Thread) {
  list.filter_map(listing.entries(model.groups), fn(entry) {
    case entry.residency {
      Live ->
        dict.get(model.reports, entry.id)
        |> result.map(thread_of(entry, _))
      sessions.Saved
      | sessions.Blocked
      | sessions.FailedStart(_)
      | sessions.Moving(_) -> Error(Nil)
    }
  })
}

/// One session as the inbox draws it, from its catalogue row and a report.
fn thread_of(entry: Entry, report: sessions.Report) -> inbox_rule.Thread {
  inbox_rule.Thread(
    id: entry.id,
    name: sessions.label(entry),
    workspace: entry.workspace,
    report:,
  )
}

/// The threads the inbox draws: the fresh read's, and the selected thread's kept
/// report when the fresh read omits it. Only the groups and the reading pane
/// use it; counts and the landing use `inbox_threads`.
fn drawn_threads(model: Model) -> List(inbox_rule.Thread) {
  let fresh = inbox_threads(model)

  // The kept report stands in only for a thread the fresh read left out.
  case model.shown {
    Some(#(id, report)) ->
      case list.any(fresh, fn(thread) { thread.id == id }) {
        True -> fresh
        False ->
          case
            list.find(listing.entries(model.groups), fn(entry) {
              entry.id == id && entry.residency == Live
            })
          {
            Ok(entry) -> list.append(fresh, [thread_of(entry, report)])
            Error(Nil) -> fresh
          }
      }
    None -> fresh
  }
}

/// Whether a catalogue summary is coming: the page reads the feed and its list
/// holds a saved session, which is the one kind the page reads a summary for.
/// A list with no running session leaves the centre undecided while one is due,
/// because after a restart that summary is what says whether something waits.
fn summary_due(model: Model) -> Bool {
  case model.start.attention {
    Some(_) ->
      list.any(listing.entries(model.groups), fn(entry) {
        entry.residency == sessions.Saved
      })
    None -> False
  }
}

/// The activity read the list started: due when the list holds a running
/// session, because `observing` asks nothing for a page with none.
fn activity_reading(model: Model) -> landing_rule.Reading {
  case running_sessions(model) {
    0 -> landing_rule.NotDue
    _ -> landing_rule.Due
  }
}

/// The summary read the list started, due as `summary_due` says.
fn summary_reading(model: Model) -> landing_rule.Reading {
  case summary_due(model) {
    True -> landing_rule.Due
    False -> landing_rule.NotDue
  }
}

/// The feed read the list started: due when the page reads the feed and the list
/// holds a running session, since `attending` asks the feed for those alone.
fn feed_reading(model: Model) -> landing_rule.Reading {
  case model.start.attention, running_sessions(model) {
    None, _ | Some(_), 0 -> landing_rule.NotDue
    Some(_), _ -> landing_rule.Due
  }
}

/// Whether the inbox has anything to show: a thread drawn from a report, or an
/// ask, stuck strand or find from the feed or the catalogue.
fn inbox_has_content(model: Model) -> Bool {
  drawn_threads(model) != [] || something_waits(model)
}

/// What the first round has gathered, as the landing rule reads it: the reports
/// of the running sessions, and what waits in the feed, the catalogue and the
/// boards. Something waiting in the feed or the catalogue lands on the inbox even
/// when no session runs, which is a restart with an approval pending.
fn picture(model: Model) -> landing_rule.Picture {
  let tally = attention_rule.tally(standings(model))

  landing_rule.Picture(
    reports: list.map(inbox_threads(model), fn(thread) { thread.report }),
    needing: tally.needing,
    finds: tally.finds,
    tickets: waiting_tickets(model),
  )
}

/// The model once a first-round read has answered: the round records it and,
/// if it was the last one due, the centre is decided by what the round gathered.
/// A read that answers when the round is complete, or after the person chose a
/// centre, changes no centre.
fn arrived(model: Model, source: landing_rule.Source) -> Model {
  let #(round, close) = landing_rule.answer(model.round, source)

  concluded(Model(..model, round:), close)
}

/// The model once a round has taken an answer. Only the answer that closes the
/// round decides, and only for a page whose centre is still `Awaiting`.
fn concluded(model: Model, close: landing_rule.Close) -> Model {
  case close, model.centre_choice {
    landing_rule.Closes, Awaiting ->
      Model(
        ..model,
        centre_choice: Decided(case landing_rule.landing(picture(model)) {
          inbox_rule.Inbox -> InboxCentre
          inbox_rule.Form -> FormCentre
        }),
      )
    landing_rule.Closes, Decided(_) | landing_rule.Continues, _ -> model
  }
}

/// Applies the daemon's answer to the activity read. The reports, and so the
/// states and the headline's count, are the fresh answer alone. The one
/// exception is the thread the pane shows, whose last report is kept in `shown`
/// when one read leaves it out and its session is still listed, since a slow
/// session is not a gone one. The answer takes part in the first round (`arrived`)
/// and fixes the default thread (`settled_selection`); no later answer changes
/// the centre.
fn observed(model: Model, rows: List(#(String, sessions.Report))) -> Model {
  let fresh = dict.from_list(rows)
  let read =
    Model(
      ..model,
      activity: dict.map_values(fresh, fn(_, report) { report.activity }),
      reports: fresh,
      shown: shown_report(model, fresh),
    )

  let settled = Model(..read, selected: settled_selection(read))

  arrived(settled, landing_rule.ActivitySource)
}

/// The report to keep for the selected thread: its fresh one, or else the one
/// kept before while its session is still a running row of the page's list.
fn shown_report(
  model: Model,
  fresh: Dict(String, sessions.Report),
) -> Option(#(String, sessions.Report)) {
  case selected_session(model.selected) {
    None -> None
    Some(id) ->
      case dict.get(fresh, id) {
        Ok(report) -> Some(#(id, report))
        Error(Nil) ->
          case still_running(model, id) {
            True -> previous_report(model, id)
            False -> None
          }
      }
  }
}

/// The last report the page held for `id`: the previous read's, or the one
/// kept for it already.
fn previous_report(
  model: Model,
  id: String,
) -> Option(#(String, sessions.Report)) {
  case dict.get(model.reports, id), model.shown {
    Ok(report), _ -> Some(#(id, report))
    Error(Nil), Some(#(held, _) as kept) if held == id -> Some(kept)
    Error(Nil), Some(_) | Error(Nil), None -> None
  }
}

/// Whether the page's own list still shows `id` as a running session.
fn still_running(model: Model, id: String) -> Bool {
  list.any(listing.entries(model.groups), fn(entry) {
    entry.id == id && entry.residency == Live
  })
}

/// The session a selection names, if it names one.
fn selected_session(selection: Selection) -> Option(String) {
  case selection {
    Unchosen -> None
    Defaulted(session:) | Pressed(session:) -> Some(session)
  }
}

/// The selection after a read: a pressed or defaulted thread that is still
/// listed stands, and anything else becomes the first thread as a default, or
/// nothing when there is none. A default is therefore fixed at the first read
/// that has a thread, and a thread that later outranks it does not move it.
fn settled_selection(model: Model) -> Selection {
  let groups = model_groups(model)
  let chosen = inbox_rule.selection(groups, selected_session(model.selected))

  // A press that still stands stays a press; any other thread shown is a
  // default, so the narrow screen can keep its pane hidden.
  case chosen, model.selected {
    Some(id), Pressed(held) if held == id -> Pressed(id)
    Some(id), _ -> Defaulted(id)
    None, _ -> Unchosen
  }
}

/// Whether the centre is the inbox: the pane is the composer's or the list's
/// and the centre was decided to be the inbox. A ticket's page and a relayed
/// session are the centre's whole subject.
fn landed_inbox(model: Model) -> Bool {
  case model.pane, model.centre_choice {
    NewSession, Decided(InboxCentre) | SessionList, Decided(InboxCentre) -> True
    Ticketed(_), _
    | Relayed(_), _
    | NewSession, Awaiting
    | SessionList, Awaiting
    | NewSession, Decided(FormCentre)
    | SessionList, Decided(FormCentre)
    | NewSession, Decided(ListCentre)
    | SessionList, Decided(ListCentre)
    -> False
  }
}

/// Whether the feed or the catalogue says something waits, an approval, an ask,
/// a stuck strand or a find. A session that runs does not count by running.
fn something_waits(model: Model) -> Bool {
  let tally = attention_rule.tally(standings(model))
  tally.needing + tally.finds + waiting_tickets(model) > 0
}

/// How many project tickets the last board read holds as waiting on a person.
/// They count toward landing on the inbox, as an ask does.
fn waiting_tickets(model: Model) -> Int {
  list.length(ticket_rule.waiting(model.boards))
}

/// The running session whose thread the pane shows when its activity says an
/// approval is pending, which is the one session whose evidence the page reads.
fn approval_session(model: Model) -> Option(String) {
  let groups = model_groups(model)
  let shown = inbox_rule.selection(groups, selected_session(model.selected))

  // Only a thread whose activity word is an approval has evidence to read.
  case shown {
    Some(id) ->
      case dict.get(model.reports, id) {
        Ok(sessions.Report(activity: NeedsYou, ..)) -> Some(id)
        Ok(_) | Error(Nil) -> None
      }
    None -> None
  }
}

/// Starts the reads of the shown session that its thread draws: its pending
/// approvals and its brief. Both return at once and answer later. The model
/// comes back with the time the brief read was started, which the next read
/// counts from.
fn approving(
  model: Model,
  trigger: brief_rule.Trigger,
) -> #(Model, Effect(Msg)) {
  let #(model, brief) = briefing(model, trigger)
  #(model, effect.batch([approval_read(model), brief]))
}

/// The session whose brief the open thread's pane draws, or nothing when the
/// pane has none to draw. An ask's pane draws the coordinator and where the
/// session stopped, and a session's thread draws its approval's peer messages,
/// its latest message and steps, or its review's last command. A stuck strand,
/// a find, a ticket, a failed run and a session with nothing to say draw no
/// brief, so none is read for them, and no thread that is not open is read.
fn brief_session(model: Model) -> Option(String) {
  // An open item thread decides first, then an open ticket, then the session
  // thread the list shows.
  case model.item.key, model.ticket {
    Some(key), _ ->
      case attention_rule.find_item(current_items(model), key) {
        Some(attention_rule.AskItem(session:, ..)) -> Some(session)
        Some(attention_rule.FindItem(..))
        | Some(attention_rule.StuckItem(..))
        | None -> None
      }
    None, Some(_) -> None
    None, None -> {
      let groups = model_groups(model)
      let shown = inbox_rule.selection(groups, selected_session(model.selected))

      // A session thread draws a brief for every kind but a failed or settled one.
      case option.map(shown, dict.get(model.reports, _)) {
        Some(Ok(report)) ->
          case inbox_rule.kind(report) {
            inbox_rule.Failed | inbox_rule.Settled -> None
            inbox_rule.ApprovalPending | inbox_rule.Idle | inbox_rule.Working ->
              shown
          }
        Some(Error(Nil)) | None -> None
      }
    }
  }
}

/// Whether a session's thread is an approval whose evidence the page has not
/// received. Its brief waits for the evidence, because the time its peer
/// messages are counted from is the approval's raise time.
fn evidence_awaited(model: Model, session: String) -> Bool {
  case dict.get(model.reports, session), dict.get(model.evidence, session) {
    Ok(sessions.Report(activity: NeedsYou, ..)), Error(Nil) -> True
    _, _ -> False
  }
}

/// Starts the read of the open thread's session's brief and returns at once; the
/// answer arrives later as `BriefRead`. The time after which peer messages are
/// wanted is the raise time of the session's oldest pending approval, so a
/// session whose approval evidence has not arrived waits for it: a read made
/// before it would carry messages the thread's label does not describe. A page
/// that reads no feed, one that has not connected or has ended, and a thread
/// that has no brief to draw ask nothing, and so does a thread whose last read
/// is too recent (`brief_rule.due`).
fn briefing(
  model: Model,
  trigger: brief_rule.Trigger,
) -> #(Model, Effect(Msg)) {
  // Only a connected page that reads the feed, with a thread open that has a
  // brief to draw, reads one.
  case model.start.attention, model.status, brief_session(model) {
    Some(reads), Connected, Some(session) -> {
      let since = brief_since(model, session)
      let now = model.start.now()
      let last = option.from_result(dict.get(model.brief_reads, session))

      // The read waits for the evidence and for its own turn.
      case
        evidence_awaited(model, session),
        brief_rule.due(last, now, since, trigger)
      {
        False, True -> #(
          Model(
            ..model,
            brief_reads: dict.insert(
              model.brief_reads,
              session,
              brief_rule.Read(started: now, since:),
            ),
          ),
          effect.from(fn(dispatch) {
            reads.brief(session, since, fn(read) {
              dispatch(BriefRead(session, since, read))
            })
          }),
        )
        True, _ | False, False -> #(model, effect.none())
      }
    }
    Some(_), Connected, _
    | Some(_), Connecting, _
    | Some(_), Ended(_), _
    | None, _, _
    -> #(model, effect.none())
  }
}

/// The time after which a session's peer messages are wanted: the oldest raise
/// time among the pending approvals the page holds for it, or zero. An approvals
/// read that failed or has not answered says nothing, so the time of the last
/// brief read stands: a flapping read would otherwise swing the time to zero and
/// back, and each swing would ask for another brief before `brief_rule.due`'s
/// pacing allowed it.
fn brief_since(model: Model, session: String) -> Int {
  case dict.get(model.evidence, session) {
    Ok(approval_evidence.Seen(evidence:)) ->
      approval_evidence.oldest_raised(evidence) |> option.unwrap(0)
    Ok(approval_evidence.Unseen(_)) | Error(Nil) ->
      case dict.get(model.brief_reads, session) {
        Ok(brief_rule.Read(since:, ..)) -> since
        Error(Nil) -> 0
      }
  }
}

/// Starts the read of the shown session's pending approvals and returns at
/// once; the answer arrives later as `ApprovalsRead`. A page that reads no
/// feed, one that has not connected or has ended, and a thread with no approval
/// ask nothing.
fn approval_read(model: Model) -> Effect(Msg) {
  // A page that reads the feed and shows an approval's thread asks for its
  // evidence once it has connected.
  case model.start.attention, model.status, approval_session(model) {
    Some(reads), Connected, Some(session) -> {
      use dispatch <- effect.from
      reads.approvals(session, fn(read) {
        dispatch(ApprovalsRead(session, read))
      })
    }
    Some(_), Connected, None
    | Some(_), Connecting, _
    | Some(_), Ended(_), _
    | None, _, _
    -> effect.none()
  }
}

/// The words a Retry sends the stuck strand. They are the page's own, fixed, and
/// the live rail's Retry sends the same ones (`thread_send.retry_prompt`).
const retry_words = thread_send.retry_prompt

/// What the page may do to an attention record, or nothing for a page that
/// reads the feed and may not act: an observer's, a member's.
fn acting(model: Model) -> Option(Act) {
  case model.start.attention {
    Some(reads) -> reads.act
    None -> None
  }
}

/// Dismisses the open stuck strand's failure, naming the failed run the page's
/// last feed read held for it. A thread that is not a stuck strand's, a strand the
/// read no longer holds and a row that names no failed run ask nothing, because
/// the daemon needs the operation to tell the failure the owner read from one
/// that happened since (protocol-change/131).
fn dismissing(
  model: Model,
  act: Act,
  key: attention_rule.Key,
) -> #(Model, Effect(Msg)) {
  // Only a stuck strand's thread has a failure to dismiss.
  let held = case key.sort {
    attention_rule.StuckSort ->
      case attention_rule.find_item(current_items(model), key) {
        Some(attention_rule.StuckItem(stuck:, ..)) -> stuck.operation
        Some(attention_rule.AskItem(..)) | Some(attention_rule.FindItem(..)) ->
          None
        None -> None
      }
    attention_rule.AskSort | attention_rule.FindSort -> None
  }

  // The press is asked of the daemon only with the failed run in hand.
  case held {
    Some(operation) -> #(Model(..model, item: item_pane.sending(model.item)), {
      use dispatch <- effect.from
      act.dismiss_stuck(key.session, key.id, operation, fn(outcome) {
        dispatch(ItemActed(key, outcome))
      })
    })
    None -> #(model, effect.none())
  }
}

/// Every item the last feed read holds, for the sessions the page's list still
/// holds as running. The rows are taken in the order of the session identity so
/// two renders of one read agree.
fn current_items(model: Model) -> List(attention_rule.Item) {
  let running =
    list.filter_map(listing.entries(model.groups), fn(entry) {
      case entry.residency {
        Live -> Ok(entry.id)
        sessions.Saved
        | sessions.Blocked
        | sessions.FailedStart(_)
        | sessions.Moving(_) -> Error(Nil)
      }
    })

  model.feed
  |> dict.to_list
  |> list.filter(fn(entry) { list.contains(running, entry.0) })
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> attention_rule.items
}

/// The strand a thread's messages go to: the strand that wrote the record, read
/// from the record when the page has it and from the feed's row otherwise, and
/// the strand itself for a stuck one. `main` is the fallback, and the gateway
/// answers a strand that does not exist as `UnknownStrand`.
fn strand_of(model: Model, key: attention_rule.Key) -> String {
  case model.item.loaded, key.sort {
    item_pane.Loaded(item_pane.AskRecord(ask:, ..)), _ -> ask.header.strand
    item_pane.Loaded(item_pane.FindRecord(find:, ..)), _ -> find.header.strand
    item_pane.NoRecord, attention_rule.StuckSort
    | item_pane.Loading, attention_rule.StuckSort
    | item_pane.Unavailable(_), attention_rule.StuckSort
    -> key.id
    item_pane.NoRecord, _
    | item_pane.Loading, _
    | item_pane.Unavailable(_), _
    ->
      case attention_rule.find_item(current_items(model), key) {
        Some(attention_rule.AskItem(ask:, ..)) -> ask.strand
        Some(attention_rule.FindItem(find:, ..)) -> find.strand
        Some(attention_rule.StuckItem(stuck:, ..)) -> stuck.strand
        None -> "main"
      }
  }
}

/// Sends what is staged, one step at a time: the answer first, and the note
/// when the answer is settled. A page that may not act, one that is not
/// connected and a send already out ask nothing.
fn sending_item(model: Model) -> #(Model, Effect(Msg)) {
  case acting(model), model.item.key, model.status, model.item.progress {
    Some(act), Some(key), Connected, item_pane.Resting
    | Some(act), Some(key), Connected, item_pane.Settled(_)
    ->
      case item_pane.first_step(model.item, strand_of(model, key)) {
        item_pane.AnswerStep(staged) -> #(
          Model(..model, item: item_pane.sending(model.item)),
          {
            use dispatch <- effect.from
            act.answer(
              staged.session,
              staged.ask,
              staged.revision,
              staged.wire,
              fn(outcome) { dispatch(ItemActed(key, outcome)) },
            )
          },
        )
        item_pane.NoteStep(session:, strand:, text:) -> #(
          Model(..model, item: item_pane.sending(model.item)),
          noting(act, key, session, strand, text),
        )
        item_pane.NothingStaged -> #(model, effect.none())
      }
    _, _, _, _ -> #(model, effect.none())
  }
}

/// The effect that messages a strand with a staged note, whose answer is
/// `ItemNoteAnswered`.
fn noting(
  act: Act,
  key: attention_rule.Key,
  session: String,
  strand: String,
  text: String,
) -> Effect(Msg) {
  use dispatch <- effect.from
  act.strand(session, strand, text, operator.Prompt, fn(answer) {
    dispatch(ItemNoteAnswered(key, answer))
  })
}

/// Starts the attention reads for the sessions the page lists and returns at
/// once: the feed rows of the running ones, in the order the page draws them and
/// no more than `activity_limit`, and the catalogue's summaries of the saved
/// ones. Each answer arrives later as `FeedRead` or `SavedRead`, dispatched
/// from the daemon's task. A page without the capability, and one that has not
/// connected or has ended, asks nothing.
fn attending(model: Model) -> Effect(Msg) {
  // A page that cannot read, one that has not connected and one that ended ask nothing.
  case model.start.attention, model.status {
    Some(reads), Connected -> {
      let entries = listing.entries(model.groups)
      let live =
        entries
        |> list.filter(fn(entry) { entry.residency == Live })
        |> list.take(sessions.activity_limit)
        |> list.map(fn(entry) { entry.id })
      let saved =
        entries
        |> list.filter(fn(entry) { entry.residency == sessions.Saved })
        |> list.take(sessions.listed_limit)
        |> list.map(fn(entry) { entry.id })

      effect.batch([
        case live {
          [] -> effect.none()
          [_, ..] -> {
            use dispatch <- effect.from
            reads.feed(live, fn(rows) { dispatch(FeedRead(rows)) })
          }
        },
        case saved {
          [] -> effect.none()
          [_, ..] -> {
            use dispatch <- effect.from
            reads.saved(saved, fn(rows) { dispatch(SavedRead(rows)) })
          }
        },
      ])
    }
    Some(_), Connecting | Some(_), Ended(_) | None, _ -> effect.none()
  }
}

/// What each listed session is known by, for the headline's count: a running
/// session by its feed row and its activity word, a saved one by the
/// catalogue's summary. A session whose custody is moving, blocked or failed
/// to start is left out, because its records are not the page's to read.
fn standings(model: Model) -> List(attention_rule.Standing) {
  list.filter_map(listing.entries(model.groups), fn(entry) {
    // A running session reads its row, a saved one its summary, and the rest are not the page's to count.
    case entry.residency {
      Live -> {
        // An approval is pending when the session's own activity word says so.
        let approval = case dict.get(model.reports, entry.id) {
          Ok(sessions.Report(activity: NeedsYou, ..)) -> attention_rule.Pending
          Ok(_) | Error(Nil) -> attention_rule.NotPending
        }

        // A running session whose row was not read is counted as not checked.
        case dict.get(model.feed, entry.id) {
          Ok(row) -> Ok(attention_rule.Running(approval:, row:))
          Error(Nil) -> Ok(attention_rule.RunningUnread(approval:))
        }
      }
      sessions.Saved ->
        case dict.get(model.saved, entry.id) {
          Ok(saved) -> Ok(attention_rule.SavedCounted(saved:))
          Error(Nil) -> Ok(attention_rule.SavedUnread)
        }
      sessions.Blocked | sessions.FailedStart(_) | sessions.Moving(_) ->
        Error(Nil)
    }
  })
}

/// The line any refusal leaves on the saved row it was placed on, and nothing
/// for any other row. The table draws the same note beside its own row, which
/// is not on screen in the inbox.
fn saved_refusal(model: Model, session: String) -> Option(Element(Msg)) {
  case model.note {
    Some(home_table.Note(
      place: home_table.Session(id:, ..),
      notice: notice.Refused(words:),
    ))
      if id == session
    -> Some(notice.line(notice.Refused(words)))
    Some(_) | None -> None
  }
}

/// The saved sessions the catalogue has a summary for, as the rows the inbox
/// draws for them, in the order the list shows the sessions.
fn saved_threads(model: Model) -> List(attention_rule.SavedThread) {
  list.filter_map(listing.entries(model.groups), fn(entry) {
    case entry.residency, dict.get(model.saved, entry.id) {
      sessions.Saved, Ok(saved) ->
        Ok(attention_rule.SavedThread(
          session: entry.id,
          name: sessions.label(entry),
          saved:,
        ))
      sessions.Saved, Error(Nil)
      | Live, _
      | sessions.Blocked, _
      | sessions.FailedStart(_), _
      | sessions.Moving(_), _
      -> Error(Nil)
    }
  })
}

/// The inbox's attention threads: the rows that wait on the owner, the finds
/// and the open thread's pane. Nothing on a page that reads no feed.
fn attention_threads(model: Model) -> Option(inbox_view.Threads(Msg)) {
  // A page with no feed capability draws no threads.
  case model.start.attention {
    None -> None
    Some(reads) -> {
      let items = current_items(model)
      let now = model.now
      let selected = model.item.key
      let row = fn(item) {
        attention_thread.row(
          item,
          now,
          selected,
          model.opened,
          ItemPicked,
          session_name(model, _),
        )
      }

      // A saved session's summary is counted in the headline, so each one that
      // holds something open is a row the person can act on, after the live ones.
      let saved = saved_threads(model)
      let offer =
        attention_thread.SavedOffer(
          resume: case model.start.ceiling {
            OperatorCeiling -> Some(Resuming)
            ObserverCeiling -> None
          },
          resuming: model.resuming,
          said: fn(session) { saved_refusal(model, session) },
        )
      let saved_row = fn(side) {
        fn(thread) { attention_thread.saved_row(thread, side, now, offer) }
      }

      Some(
        inbox_view.Threads(
          needs: list.append(
            list.map(attention_rule.needs_you(items), row),
            list.map(
              attention_rule.saved_needing(saved),
              saved_row(attention_thread.SavedNeeding),
            ),
          ),
          tickets: [],
          reviews: [],
          finds: list.append(
            list.map(attention_rule.finds(items), row),
            list.map(
              attention_rule.saved_finding(saved),
              saved_row(attention_thread.SavedFinding),
            ),
          ),
          titles: list.filter_map(dict.to_list(model.evidence), fn(entry) {
            attention_thread.approval_title(entry.1)
            |> option.map(fn(nodes) { #(entry.0, nodes) })
            |> option.to_result(Nil)
          }),
          evidence: list.map(dict.to_list(model.evidence), fn(entry) {
            #(entry.0, attention_thread.evidence(entry.1))
          }),
          pane: case model.item.key {
            None -> None
            Some(key) ->
              Some(
                attention_thread.pane(attention_thread.Offer(
                  now: model.now,
                  state: model.item,
                  item: attention_rule.find_item(items, key),
                  presses: model.item_presses,
                  acting: case reads.act {
                    Some(_) ->
                      Some(attention_thread.Acting(
                        stage: ItemStaged,
                        note: ItemNoted,
                        unstage: ItemCleared,
                        send: ItemSent,
                        close: ItemClosed,
                        retry: ItemRetried,
                        dismiss: ItemDismissed,
                      ))
                    None -> None
                  },
                  open: Opening,
                  back: InboxClosed,
                  session_name: session_name(model, key.session),
                  brief: shown_brief(model, key.session),
                )),
              )
          },
        ),
      )
    }
  }
}

/// The inbox's threads with the project tickets that wait on a person added.
/// Their rows follow the attention rows in Needs you, and the open ticket's pane
/// takes the reading pane, which no attention item's pane shares: opening one
/// closes the other.
fn with_tickets(
  model: Model,
  base: Option(inbox_view.Threads(Msg)),
) -> Option(inbox_view.Threads(Msg)) {
  let waiting = ticket_rule.waiting(model.boards)
  let shown = open_ticket(model)

  // A page with neither feed nor tickets has no threads; any other draws the
  // feed's, with tickets added.
  case base, waiting, shown {
    None, [], None -> None
    Some(held), _, _ -> Some(ticketed(model, held, waiting, shown))
    None, _, _ ->
      Some(ticketed(
        model,
        inbox_view.Threads(
          needs: [],
          tickets: [],
          reviews: [],
          finds: [],
          pane: None,
          titles: [],
          evidence: [],
        ),
        waiting,
        shown,
      ))
  }
}

/// The threads of `held` with the ticket rows appended to what needs the owner,
/// and the open ticket's pane drawn in place of the pane `held` has, if one is
/// open.
fn ticketed(
  model: Model,
  held: inbox_view.Threads(Msg),
  waiting: List(ticket_rule.Waiting),
  shown: Option(#(ticket_rule.Opened, board.Ticket)),
) -> inbox_view.Threads(Msg) {
  let selected = option.map(model.ticket, fn(opened) { opened.key })
  let standing = ticket_standing(model)

  inbox_view.Threads(
    ..held,
    tickets: list.map(
      ticket_rule.in_lane(waiting, ticket_rule.Answering),
      fn(each) {
        ticket_thread.row(
          each,
          model.now,
          selected,
          model.opened,
          TicketThreadPicked,
        )
      },
    ),
    reviews: list.map(
      ticket_rule.in_lane(waiting, ticket_rule.Reviewing),
      fn(each) {
        ticket_thread.row(
          each,
          model.now,
          selected,
          model.opened,
          TicketThreadPicked,
        )
      },
    ),
    pane: case shown {
      Some(#(opened, ticket)) ->
        Some(
          ticket_thread.pane(ticket_thread.Offer(
            now: model.now,
            opened:,
            ticket:,
            standing:,
            controls: ticket_rule.controls(ticket, standing),
            press: TicketControlPressed,
            answer: TicketAnswerSent,
            confirm: TicketActConfirmed,
            keep: TicketActKept,
            back: InboxClosed,
            check: None,
          )),
        )
      None -> held.pane
    },
  )
}

/// The inbox, drawn from the page's reports. Its buttons send messages the home
/// already has: a thread's press shows it (`InboxOpened`), and the open buttons
/// send what a list row's press sends (`Opening`), so there is one way to open a
/// session from here and the socket admits no new event.
fn inbox_page(model: Model) -> Element(Msg) {
  let groups = model_groups(model)
  let chosen = inbox_rule.selection(groups, selected_session(model.selected))

  inbox_view.view(
    inbox_view.Offer(
      folder: shown_folder(model),
      groups:,
      selected: case chosen {
        Some(id) if model.selected == Pressed(id) -> Some(inbox_view.Pressed(id))
        Some(id) -> Some(inbox_view.Default(id))
        None -> None
      },
      opening: model.opening,
      pick: InboxOpened,
      open: Opening,
      back: InboxClosed,
      all_sessions: ShowingList,
      new_session: case model.start.create {
        Some(_) -> Some(ShowingNew)
        None -> None
      },
      presses: model.presses,
      opened: model.opened,
      field: case model.start.thread_send {
        Some(_) ->
          Some(inbox_view.Field(
            outbox: model.outbox,
            delivered: model.delivered,
            submit: ThreadSubmitted,
          ))
        None -> None
      },
      attention: with_tickets(model, attention_threads(model)),
      review: review_offer(model),
      checking: checking_ids(model),
      sized: sized_reviews(model),
      dated: dated_threads(model),
      briefs: fn(session) { shown_brief(model, session) },
      name_of: session_name(model, _),
      ask_of: fn(session) { ask_press(model, session) },
    ),
  )
}

/// What the page knows of when each session's thread began. An approval's age is
/// counted from the raise time of its oldest pending approval, and says
/// `waiting since` that time; a finished session's from the time of its last
/// message, and says `finished`; a working session's from the start of the turn
/// now running, and says how long it has gone on. A session whose data holds no
/// such time has no entry, and the row and the pane draw none: the page never
/// words an age the record lacks.
fn dated_threads(model: Model) -> List(#(String, inbox_view.Dated)) {
  let now = model.now

  list.filter_map(inbox_threads(model), fn(thread) {
    case inbox_rule.kind(thread.report) {
      inbox_rule.ApprovalPending ->
        case dict.get(model.evidence, thread.id) {
          Ok(approval_evidence.Seen(evidence:)) ->
            case approval_evidence.oldest_raised(evidence) {
              Some(raised) ->
                Ok(#(
                  thread.id,
                  inbox_view.Dated(
                    age: Some(aged(now - raised)),
                    moment: Some(inbox_parts.Moment("waiting since", raised)),
                    state: None,
                  ),
                ))
              None -> Error(Nil)
            }
          Ok(approval_evidence.Unseen(_)) | Error(Nil) -> Error(Nil)
        }
      inbox_rule.Idle ->
        case thread.report.last_message_at {
          Some(at) ->
            Ok(#(
              thread.id,
              inbox_view.Dated(
                age: Some(aged(now - at)),
                moment: Some(inbox_parts.Moment("finished", at)),
                state: None,
              ),
            ))
          None -> Error(Nil)
        }
      inbox_rule.Working ->
        case thread.report.turn_started_at {
          Some(started) ->
            Ok(#(
              thread.id,
              inbox_view.Dated(
                age: Some(aged(now - started)),
                moment: None,
                state: Some(
                  "working, " <> thread_words.turn_words(started, now),
                ),
              ),
            ))
          None -> Error(Nil)
        }
      inbox_rule.Failed | inbox_rule.Settled -> Error(Nil)
    }
  })
}

/// A wait as a row's age: its short words, marked when it is an hour or more.
fn aged(wait: Int) -> inbox_parts.Age {
  inbox_parts.Age(
    words: thread_words.short_age(wait),
    standing: case thread_words.overdue(wait) {
      True -> inbox_parts.Overdue
      False -> inbox_parts.Ordinary
    },
  )
}

/// The brief a thread draws for a session: what the page holds of it, with the
/// peer messages kept only for an approval whose brief was read after that
/// approval's raise time (`brief_rule.shown`).
fn shown_brief(model: Model, session: String) -> Option(session_brief.Brief) {
  // The raise time is the oldest pending approval's, when the page has read one.
  let raised = case dict.get(model.evidence, session) {
    Ok(approval_evidence.Seen(evidence:)) ->
      approval_evidence.oldest_raised(evidence)
    Ok(approval_evidence.Unseen(_)) | Error(Nil) -> None
  }

  brief_rule.shown(
    option.from_result(dict.get(model.briefs, session)),
    option.from_result(dict.get(model.brief_since, session)),
    raised,
  )
}

/// The press that opens a session's own open ask, when the last feed read holds
/// one.
fn ask_press(model: Model, session: String) -> Option(Msg) {
  list.find_map(current_items(model), fn(item) {
    case item {
      attention_rule.AskItem(session: owner, ..) if owner == session ->
        Ok(ItemPicked(attention_rule.key_of(item)))
      attention_rule.AskItem(..)
      | attention_rule.FindItem(..)
      | attention_rule.StuckItem(..) -> Error(Nil)
    }
  })
  |> option.from_result
}

/// The session whose thread follows `current` in "To review", or nothing when
/// `current` is the last one or is not listed there. It is what "Send & next"
/// moves to.
fn following_review(model: Model, current: Option(String)) -> Option(String) {
  case list.key_find(model_groups(model), inbox_rule.ToReview), current {
    Ok(threads), Some(session) ->
      threads
      |> list.map(fn(thread) { thread.id })
      |> list.drop_while(fn(id) { id != session })
      |> list.drop(1)
      |> list.first
      |> option.from_result
    Error(Nil), _ | _, None -> None
  }
}

/// The inbox's groups: the threads of the last reads, with the idle sessions
/// whose worktree holds changes under "To review", and without the quiet
/// sessions that have a row in the attention feed, which the feed draws.
fn model_groups(
  model: Model,
) -> List(#(inbox_rule.Group, List(inbox_rule.Thread))) {
  inbox_rule.grouped_with(
    drawn_threads(model),
    reviewing_ids(model),
    list.map(current_items(model), attention_rule.session_of),
  )
}

/// The idle sessions with a last message, as their identity and that message,
/// in the order the page lists them: the sessions whose tree could be reviewed.
fn scan_candidates(model: Model) -> List(#(String, String)) {
  list.filter_map(inbox_threads(model), fn(thread) {
    case inbox_rule.kind(thread.report), thread.report.last_message {
      inbox_rule.Idle, Some(message) -> Ok(#(thread.id, message))
      inbox_rule.Idle, None
      | inbox_rule.ApprovalPending, _
      | inbox_rule.Failed, _
      | inbox_rule.Working, _
      | inbox_rule.Settled, _
      -> Error(Nil)
    }
  })
}

/// The sessions listed under "To review": the idle ones with a last message
/// whose tree is not known to be clean. A page that cannot read a worktree has
/// no such group, so it lists none, whatever the sessions hold.
fn reviewing_ids(model: Model) -> List(String) {
  case review_reader(model) {
    Some(_) -> review_scan_rule.to_review(scan_candidates(model), model.reviews)
    None -> []
  }
}

/// The sessions under "To review" whose tree has not been read at the message
/// they say now, which their rows word as being checked.
fn checking_ids(model: Model) -> List(String) {
  case review_reader(model) {
    Some(_) -> review_scan_rule.checking(scan_candidates(model), model.reviews)
    None -> []
  }
}

/// The head of each "To review" row whose tree was read at the session's current
/// message: the change's size from that read and the number of finds the
/// attention feed holds for the session. A session not read at its current
/// message has none, so its row keeps the head of its message.
fn sized_reviews(model: Model) -> List(#(String, String)) {
  list.filter_map(scan_candidates(model), fn(candidate) {
    let #(session, message) = candidate

    // Only a read at the message now shown has a size worth saying.
    case review_scan_rule.stat_of(model.reviews, session, message) {
      Some(stat) -> {
        // The finds are the feed's, which may not have been read yet: then
        // the row says the size alone.
        let finds = case dict.get(model.feed, session) {
          Ok(row) -> list.length(row.finds.items)
          Error(Nil) -> 0
        }

        Ok(#(session, review_scan_rule.stat_words(stat, finds)))
      }
      None -> Error(Nil)
    }
  })
}

/// How the page reads a worktree, or nothing for a page that may not: an
/// observer's has no review.
fn review_reader(
  model: Model,
) -> Option(fn(String, fn(Result(review_feed.Review, String)) -> Nil) -> Nil) {
  case model.start.attention {
    Some(reads) -> reads.review
    None -> None
  }
}

/// Starts the read that decides the next idle session, when one is due and none
/// is out. A page that cannot read a worktree, and one that is not connected,
/// read none.
fn scanning(model: Model) -> #(Model, Effect(Msg)) {
  case review_reader(model), model.status {
    Some(read), Connected ->
      case
        review_scan_rule.due(scan_candidates(model), model.reviews, model.now)
      {
        Some(#(session, message)) -> #(
          Model(
            ..model,
            reviews: review_scan_rule.started(
              model.reviews,
              session,
              message,
              model.now,
            ),
          ),
          {
            use dispatch <- effect.from
            read(session, fn(result) {
              dispatch(ReviewScanned(session, message, result))
            })
          },
        )
        None -> #(model, effect.none())
      }
    Some(_), Connecting
    | Some(_), Ended(_)
    | None, Connecting
    | None, Connected
    | None, Ended(_)
    -> #(model, effect.none())
  }
}

/// Opens the review thread of the session the pane shows when it is "To
/// review" and the review held is not for it, or is for an older message, and
/// starts the reads: the worktree and the record of each of its finds. A Send
/// that is out keeps its review, and a thread already open is not read again.
fn opening_review(model: Model) -> #(Model, Effect(Msg), OpenRead) {
  let shown =
    inbox_rule.selection(model_groups(model), selected_session(model.selected))

  // The message the shown session last said, which its review is read for.
  let message = case shown {
    Some(id) ->
      case dict.get(model.reports, id) {
        Ok(report) -> Some(option.unwrap(report.last_message, ""))
        Error(Nil) -> None
      }
    None -> None
  }

  // A Send that is out keeps its review where it is, and so does the receipt of
  // one that settled, until the agent next speaks. Both are
  // `ReviewClosed` and `ReviewPrompted`'s only way to find the session: they
  // carry none, and the Sending guard is what makes them safe, since a close or
  // a prompt that answers while no Send is out changes nothing.
  let sending = case model.review.progress {
    review_pane.Sending(..) -> True
    review_pane.Resting | review_pane.Settled(_) -> False
  }

  // A page that may read, a shown thread that is To review and no Send out open the review.
  case review_reader(model), model.start.attention, shown, message, sending {
    Some(read), Some(reads), Some(id), Some(said), False ->
      case list.contains(reviewing_ids(model), id) {
        False -> #(model, effect.none(), NoFreshRead)
        True -> {
          let fresh =
            model.review.session != Some(id)
            || model.review.read_for != Some(said)

          // A review that is not yet this session's, or is for an older message, is opened afresh.
          let held = case fresh {
            True -> review_pane.opened(id, said)
            False -> model.review
          }

          let #(asked, finds) =
            review_pane.ask_revisions(held, session_finds(model, id))
          let next =
            Model(..model, review: asked, review_presses: case fresh {
              True -> model.review_presses + 1
              False -> model.review_presses
            })

          #(
            next,
            effect.batch([
              case fresh {
                True -> {
                  use dispatch <- effect.from
                  read(id, fn(result) { dispatch(ReviewRead(id, result)) })
                }
                False -> effect.none()
              },
              ..list.map(finds, fn(find) {
                use dispatch <- effect.from
                reads.record(id, find, fn(result) {
                  dispatch(ReviewFindRead(find, result))
                })
              })
            ]),
            case fresh {
              True -> FreshRead
              False -> NoFreshRead
            },
          )
        }
      }
    _, _, _, _, _ -> #(model, effect.none(), NoFreshRead)
  }
}

/// Whether the scan's re-arm timer is set.
type Rearm {
  /// No timer is set.
  Unscheduled

  /// One is set, and no other is until it fires.
  Scheduled
}

/// Sets the timer that starts the scan again, once, after the daemon refused a
/// read for the credential's allowance. Any other failure waits for the next
/// list or activity read, since a pause does not mend it. A page whose timer the
/// runtime has not made, and one with a timer already set, set none.
fn rearming(model: Model, words: String) -> #(Model, Effect(Msg)) {
  // Only a refusal for the allowance is mended by waiting.
  case
    words == review_scan_rule.busy_words,
    model.review_timer,
    model.review_rearm
  {
    True, Some(timer), Unscheduled -> #(
      Model(..model, review_rearm: Scheduled),
      {
        use _ <- effect.from
        let _ =
          process.send_after(
            timer,
            option.map(model.start.attention, fn(reads) {
              reads.review_pause_ms
            })
              |> option.unwrap(0),
            Nil,
          )
        Nil
      },
    )
    True, _, _ | False, _, _ -> #(model, effect.none())
  }
}

/// Whether `opening_review` started the read of the open thread's worktree.
type OpenRead {
  /// It did, so the daemon's allowance is spent on it and a scan waits.
  FreshRead

  /// It did not.
  NoFreshRead
}

/// An opening and then a scan, for a model whose reads or selection changed. The
/// opening goes first, and a fresh read of the open thread keeps the scan from
/// starting beside it: the two would draw on the same allowance, and the one
/// that lost would be the thread the person is looking at.
fn reviewing(model: Model) -> #(Model, Effect(Msg)) {
  let #(opened, open, read) = opening_review(model)

  // A fresh open read holds the scan back, and otherwise the scan goes on.
  case read {
    FreshRead -> #(opened, open)
    NoFreshRead -> {
      let #(scanned, scan) = scanning(opened)
      #(scanned, effect.batch([open, scan]))
    }
  }
}

/// The identifiers of a session's open finds, as the feed last read them.
fn session_finds(model: Model, session: String) -> List(String) {
  case dict.get(model.feed, session) {
    Ok(row) -> list.map(row.finds.items, fn(find) { find.id })
    Error(Nil) -> []
  }
}

/// A staging the pane made, kept only by a page that may act.
fn staged_review(
  model: Model,
  state: review_pane.State,
) -> #(Model, Effect(Msg)) {
  case acting(model) {
    Some(_) -> #(Model(..model, review: state), effect.none())
    None -> #(model, effect.none())
  }
}

/// The effect a step of a review's Send asks: a find close at its revision, the
/// prompt to the session's main strand, or nothing when the send ended.
fn review_asking(
  act: Act,
  session: Option(String),
  step: review_pane.Step,
) -> Effect(Msg) {
  // A step is a find close, the prompt, or nothing more to ask.
  case session, step {
    Some(held), review_pane.CloseStep(find:, revision:, closure:) -> {
      use dispatch <- effect.from
      act.close(held, find, revision, closure, fn(outcome) {
        dispatch(
          ReviewClosed(find, closure, case outcome {
            Succeeded(words:) -> review_pane.Done(words)
            Failed(words:) -> review_pane.Refused(words)
          }),
        )
      })
    }
    Some(held), review_pane.PromptStep(text:) -> {
      use dispatch <- effect.from
      act.strand(held, "main", text, operator.Prompt, fn(answer) {
        dispatch(ReviewPrompted(answer))
      })
    }
    None, _ | Some(_), review_pane.Halted -> effect.none()
  }
}

/// Whether the open review is still drawn: its session is To review, or a Send
/// is out for it, or a Send has settled and the session has not spoken since. A
/// session that goes back to work on the prompt keeps its receipt, since its
/// last message stays what it was while the turn runs, and the receipt goes when
/// the agent next speaks: the hunks and the staging belong to what it said
/// before.
fn review_listed(model: Model, session: String) -> Bool {
  case model.review.progress {
    review_pane.Sending(..) -> True
    review_pane.Settled(_) ->
      case dict.get(model.reports, session) {
        Ok(report) ->
          Some(option.unwrap(report.last_message, "")) == model.review.read_for
        Error(Nil) -> False
      }
    review_pane.Resting -> list.contains(reviewing_ids(model), session)
  }
}

/// The open review's pane, for the session whose thread is "To review" and
/// open, on a page that may read a worktree. A page that may act is handed the
/// controls; one that may only read draws the files and the finds alone.
fn review_offer(model: Model) -> Option(inbox_view.Reviewed(Msg)) {
  case review_reader(model), model.review.session {
    Some(_), Some(session) ->
      case review_listed(model, session) {
        False -> None
        True ->
          Some(reviewed_with(
            session,
            review_view.pane(review_view.Offer(
              state: model.review,
              name: case
                list.find(inbox_threads(model), fn(thread) {
                  thread.id == session
                })
              {
                Ok(thread) -> thread.name
                Error(Nil) -> "this session"
              },
              finds: case dict.get(model.feed, session) {
                Ok(row) -> row.finds.items
                Error(Nil) -> []
              },
              presses: model.review_presses,
              acting: case acting(model) {
                Some(_) ->
                  Some(review_view.Acting(
                    verdict: ReviewVerdictChosen,
                    comment: ReviewCommented,
                    find: ReviewFindStaged,
                    unstage: ReviewCleared,
                    send: ReviewSent,
                  ))
                None -> None
              },
              command: case shown_brief(model, session) {
                Some(read) -> read.command
                None -> None
              },
              message: review_message(model, session),
            )),
          ))
      }
    _, _ -> None
  }
}

/// The agent's message under its label, for the review's pane, which draws it
/// between the counts and the verdict. It is the brief's latest message when the
/// page read one, which keeps the message's line breaks, and otherwise the last
/// finished message the overview carries. Nothing when the session said none.
fn review_message(model: Model, session: String) -> Element(Msg) {
  // A brief with no words in it says nothing, so the overview's message is the
  // fallback.
  let read = case shown_brief(model, session) {
    Some(brief) ->
      case brief.assistant {
        Some(assistant) ->
          case string.trim(session_brief.untrusted_text(assistant.text)) {
            "" -> None
            _ -> Some(brief)
          }
        None -> None
      }
    None -> None
  }

  // The brief's message is drawn when there is one, the overview's last message
  // is the fallback, and a session that said nothing draws nothing.
  case read, dict.get(model.reports, session) {
    Some(brief), _ ->
      html.div([attribute.class("inbox-said")], [brief_view.latest(brief)])
    None, Ok(sessions.Report(last_message: Some(text), last_message_at: at, ..))
    ->
      case string.trim(text) {
        "" -> element.none()
        _ ->
          html.div([attribute.class("inbox-said")], [
            brief_view.finished(text, at),
          ])
      }
    None, Ok(_) | None, Error(Nil) -> element.none()
  }
}

/// The review pane's three parts in the shape the inbox places them.
fn reviewed_with(
  session: String,
  drawn: review_view.Drawn(Msg),
) -> inbox_view.Reviewed(Msg) {
  inbox_view.Reviewed(
    session:,
    title: drawn.title,
    body: drawn.body,
    bar: drawn.bar,
  )
}

/// A session's name as the inbox words it: the catalogue's label for a session
/// the page lists, and the first eight characters of its identity otherwise.
fn session_name(model: Model, session: String) -> String {
  case
    list.find(listing.entries(model.groups), fn(entry) { entry.id == session })
  {
    Ok(entry) -> sessions.label(entry)
    Error(Nil) -> "Session " <> string.slice(session, 0, 8)
  }
}

/// The message the "Inbox" control sends: whenever the inbox has a thread to
/// show and the centre is not the inbox. The centre is never switched for the
/// person, so this is the way back from the composer or the list. A page with no
/// thread has no inbox to return to.
fn inbox_return(model: Model) -> Option(Msg) {
  case model.pane, landed_inbox(model), inbox_has_content(model) {
    NewSession, False, True | SessionList, False, True -> Some(ShowingInbox)
    NewSession, _, _
    | SessionList, _, _
    | Ticketed(_), _, _
    | Relayed(_), _, _
    -> None
  }
}

/// How many running sessions the page lists, which the inbox's headline counts
/// its answers against.
fn running_sessions(model: Model) -> Int {
  list.count(listing.entries(model.groups), fn(entry) {
    case entry.residency {
      Live -> True
      sessions.Saved
      | sessions.Blocked
      | sessions.FailedStart(_)
      | sessions.Moving(_) -> False
    }
  })
}

/// The centre's body when the inbox is not it: the composer, a ticket's page,
/// a relayed session or the list.
fn centre_pane(model: Model) -> Element(Msg) {
  case model.pane, model.start.create {
    NewSession, Some(_) -> new_session.view(new_pane(model))
    Ticketed(open), _ -> ticket_page(model, open)
    Relayed(state), _ -> relayed_view.view(state, relayed_presses())
    NewSession, None | SessionList, _ ->
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
        elsewhere_offer(model),
        model.opening,
        model.note,
        inbox_return(model),
      )
  }
}

/// What the relayed session's buttons send: the messages the page judges against
/// the row it holds before it asks the daemon for anything.
fn relayed_presses() -> relayed_view.Presses(Msg) {
  relayed_view.Presses(
    replied: fn(text) { Relaying(relayed_session.Replied(text)) },
    stopped: Relaying(relayed_session.Stopped),
    archive_asked: Relaying(relayed_session.ArchiveAsked),
    archive_confirmed: Relaying(relayed_session.ArchiveConfirmed),
    archive_cancelled: Relaying(relayed_session.ArchiveCancelled),
    decided: fn(escalation, seq, choice) {
      Relaying(relayed_session.Decided(escalation, seq, choice))
    },
  )
}

/// What the composer draws from: its state, the lists the page offers, the
/// target in force, the recent places and the sessions waiting on the person.
fn new_pane(model: Model) -> new_session.Pane(Msg) {
  let entries = listing.entries(model.groups)
  let offered = offers(model, entries)
  let recent = recents(model, entries)

  new_session.Pane(
    state: model.compose,
    offers: offered,
    target: composer.chosen(model.compose, offered, recent),
    recent:,
    waiting: listing.waiting(entries, model.activity),
    history: case entries {
      [] -> new_session.NoSessions
      [_, ..] -> new_session.HasSessions
    },
    presses: new_session.Presses(
      toggle: fn(chip) { Composed(composer.Toggled(chip)) },
      agent: fn(agent) { Composed(composer.ChoseAgent(agent)) },
      dismiss: Composed(composer.Dismissed),
      choose: fn(target) { Composed(composer.ChoseTarget(target)) },
      profile: fn(profile) { Composed(composer.ChoseProfile(profile)) },
      model: fn(model) { Composed(composer.ChoseModel(model)) },
      search: fn(text) { Composed(composer.Searched(text)) },
      browse: Composed(composer.OpenedBrowser),
      descend: fn(index) { Composed(composer.Descended(index)) },
      ascend: fn(depth) { Composed(composer.Ascended(depth)) },
      pick: Composed(composer.ChosePicked),
      leave_browser: Composed(composer.ClosedBrowser),
      start: fn(name, typed) { Composed(composer.Started(name, typed)) },
      toggle_limits: Composed(composer.ToggledLimits),
      start_with_limits: fn(name, typed, limits) {
        Composed(composer.StartedWithLimits(name, typed, limits))
      },
      open: Opening,
      depart: Composed(composer.OpenedUnsent),
      listing: ShowingList,
    ),
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

/// What the table offers for renaming a row: a button on a page whose daemon
/// handed it the capability, and nothing otherwise.
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

/// What the table offers for acting on a row: the buttons on a page whose daemon
/// handed it the capability, and nothing otherwise.
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
        move: MoveRequested,
        choose: MoveChosen,
        confirm_move: MoveConfirmed,
      )
  }
}

/// What the sidebar offers for archiving a row: the quiet button and its
/// question on a page whose daemon handed it the same capability as the table's
/// buttons, and nothing otherwise.
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

/// Decodes session rename submission from formData payload.
fn written(session: String) -> decode.Decoder(Msg) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // Extract name text field from form submission.
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

/// Decodes principal rename submission from formData payload.
fn named_text() -> decode.Decoder(Msg) {
  use fields <- decode.subfield(
    ["detail", "formData"],
    decode.list(form_field()),
  )

  // Extract name text field from form submission.
  case fields {
    [#("text", name)] -> decode.success(NameSubmitted(name))
    _ -> decode.failure(NameSubmitted(""), "name form")
  }
}

/// What the passkeys region offers: nothing on a page the daemon handed no
/// capability, and otherwise the owner's list, "Remove" with its second press and,
/// when the daemon handed an address, "Add a passkey".
fn passkey_offer(model: Model) -> passkeys_view.Offer(Msg) {
  case model.start.passkeys {
    None -> passkeys_view.Hidden
    Some(Passkeys(add:, ..)) ->
      passkeys_view.Shown(
        rows: model.passkeys,
        now: model.now,
        add:,
        ask: PasskeyAsked,
        confirm: PasskeyConfirmed,
        cancel: PasskeyKept,
        asked: model.passkey_asked,
        notice: model.passkey_notice,
      )
  }
}

/// What the sign-ins region offers for a device link: the control on a page the
/// daemon handed `Start.device`, and nothing otherwise. The one page that has
/// nothing and ought to say why is the owner's home that a bookmark resumed. The
/// page can tell it from the others by what the daemon handed it: the owner's
/// operating page has `Start.rename`, and a fresh one also has `Start.manage`,
/// which a resumed one lacks (`client/daemon/ui_socket.manage_for`). A member's
/// home and a read-only link have no `Start.rename`, and their rows are the same
/// as before.
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

/// What the page offers for making a session: the owner's operating page has
/// `Start.create`, and every other page draws nothing.
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
        model.start.models,
        ChoosingHere,
        ChoosingPlace,
        CreatingRemote,
        model.start.machine,
        model.cards,
      )
    None -> create.Never
  }
}

/// What the page offers for folders that hold no session: the section on a page
/// that may create, with the remembered folders no group already shows, which are
/// the ones a person could not otherwise reach without typing them again. A page
/// that has read nothing yet draws nothing, so the control does not appear before
/// the page knows its standing.
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

/// What the page offers for the other orchestrators' sessions: the group on a
/// page the daemon handed the capability, once it is connected, so the group does
/// not appear before the page knows its standing. A page with no such capability
/// draws nothing.
fn elsewhere_offer(model: Model) -> elsewhere_view.Elsewhere(Msg) {
  case model.start.elsewhere, model.status {
    Some(_), Connected ->
      elsewhere_view.Shown(
        groups: model.elsewhere,
        open: model.located,
        asking: model.paging,
        where: Locating,
        close: Located,
        more: ShowingMore,
      )
    Some(_), Connecting | Some(_), Ended(_) | None, _ -> elsewhere_view.Hidden
  }
}

/// Returns whether a target session row is found in the named orchestrator group.
fn holds_row(
  groups: List(elsewhere.Group),
  group: String,
  session: String,
) -> Bool {
  list.any(groups, fn(each) {
    case each.name == group, each.hearing {
      True, elsewhere.Answered(rows:, ..) ->
        list.any(rows, fn(row) { row.session_id == session })
      True, elsewhere.Silent | False, _ -> False
    }
  })
}

/// The groups a first-page read gave, with the pages "Show more" fetched kept
/// where they still follow it. A group whose held rows extend past the new first
/// page and begin with exactly the rows the new page lists, in order, keeps its
/// tail and takes the fresh first rows; any other group is replaced.
fn refreshed(
  held: List(elsewhere.Group),
  fresh: List(elsewhere.Group),
) -> List(elsewhere.Group) {
  list.map(fresh, fn(group) {
    case list.find(held, fn(each) { each.name == group.name }) {
      Ok(before) ->
        elsewhere.Group(..group, hearing: kept(before.hearing, group.hearing))
      Error(Nil) -> group
    }
  })
}

/// Merges retained paged rows with fresh head items if prefixes match.
fn kept(
  held: elsewhere.Hearing,
  fresh: elsewhere.Hearing,
) -> elsewhere.Hearing {
  // Match hearing states of previous and fresh reads.
  case held, fresh {
    elsewhere.Answered(rows: before, more:), elsewhere.Answered(rows: first, ..)
    -> {
      let same =
        list.map(list.take(before, list.length(first)), fn(row) {
          row.session_id
        })
        == list.map(first, fn(row) { row.session_id })

      // Append older trailing rows if first page matches identically.
      case same, first, list.drop(before, list.length(first)) {
        True, [_, ..], [_, ..] as tail ->
          elsewhere.Answered(rows: list.append(first, tail), more:)
        True, _, _ | False, _, _ -> fresh
      }
    }
    elsewhere.Answered(..), elsewhere.Silent | elsewhere.Silent, _ -> fresh
  }
}

/// Retains opened detail state if session remains present in updated groups.
fn still_there(
  model: Model,
  groups: List(elsewhere.Group),
) -> Option(elsewhere_view.Detail) {
  case model.located {
    Some(elsewhere_view.Detail(group:, session:)) ->
      case holds_row(groups, group, session) {
        True -> model.located
        False -> None
      }
    None -> None
  }
}

// The identity the next page of a group follows: the last row the page holds,
// when the group has more. A group that is silent, has no more, or is not held
// has none to ask for.
/// Determines cursor identity for fetching next page of group rows.
fn next_cursor(
  groups: List(elsewhere.Group),
  group: String,
) -> Result(String, Nil) {
  use found <- result.try(list.find(groups, fn(each) { each.name == group }))

  // Check if group has further pages available.
  case found.hearing {
    elsewhere.Answered(rows:, more: elsewhere.Further) ->
      list.last(rows) |> result.map(fn(row) { row.session_id })
    elsewhere.Answered(more: elsewhere.Last, ..) | elsewhere.Silent ->
      Error(Nil)
  }
}

/// Joins the page that arrived onto the group it was asked for. A read that could
/// not ask, or that does not hold the group, leaves the rows alone.
fn joined(
  groups: List(elsewhere.Group),
  group: String,
  read: elsewhere.Read,
) -> List(elsewhere.Group) {
  case read {
    elsewhere.Unread -> groups
    elsewhere.Heard(groups: pages) ->
      case list.find(pages, fn(page) { page.name == group }) {
        Error(Nil) -> groups
        Ok(page) ->
          list.map(groups, fn(each) {
            case each.name == group {
              True ->
                elsewhere.Group(
                  ..each,
                  hearing: elsewhere.append(each.hearing, page.hearing),
                )
              False -> each
            }
          })
      }
  }
}

/// Starts the daemon's read of one orchestrator's next page and returns at once;
/// the answer arrives later as `MoreRead`, dispatched from the daemon's task.
fn paging(
  next: fn(String, String, fn(elsewhere.Read) -> Nil) -> Nil,
  group: String,
  after: String,
  serial: Int,
) -> Effect(Msg) {
  use dispatch <- effect.from
  next(group, after, fn(read) { dispatch(MoreRead(group, serial, read)) })
}

/// The sidebar's column, or the frame's word that there is none. The owner's page
/// always has one, since its "New session" button is where a session starts and a
/// daemon with no session yet is where a person starts the first.
fn shell_sidebar(model: Model) -> shell.Sidebar(Msg) {
  case model.groups, model.start.create {
    [], None -> shell.Unlisted
    groups, _ ->
      shell.Listed(sidebar.home(
        groups,
        model.activity,
        sidebar_page(model),
        Opening,
        resume_offer(model),
        archive_offer(model),
        relayed_rows(model),
        rail_folders(model),
      ))
  }
}

/// The rail's folders, drawn on the home page whatever its centre is, so the
/// inbox is one press away from the composer, the list, a ticket and a relayed
/// session as it is from a session's page. "Everything, by need" is always
/// first, and each group that holds a thread follows with its count. The note
/// says how many sessions the counts read. A folder is marked as the one the
/// list is narrowed to only while the inbox is the centre, since otherwise no
/// folder is on screen.
fn rail_folders(model: Model) -> sidebar.Folders(Msg) {
  let tally = attention_rule.tally(standings(model))

  // The counts looked at saved sessions only where a catalogue summary
  // supplied some.
  let saved = case model.start.attention, tally.from_catalogue {
    Some(_), found if found > 0 -> inbox_rule.SavedFromCatalogue
    _, _ -> inbox_rule.SavedUnchecked
  }

  sidebar.Folders(
    items: [
      #(inbox_rule.Everything, Some(0)),
      ..list.map(folder_counts(model), fn(entry) { #(entry.0, Some(entry.1)) })
    ],
    current: case landed_inbox(model) {
      True -> Some(shown_folder(model))
      False -> None
    },
    pick: Some(FolderPicked),
    note: inbox_rule.count_note(list.length(inbox_threads(model)), saved),
    running: running_sessions(model),
  )
}

/// The folders with something in them and their counts, in the rail's order. A
/// count is the number of rows the group's band draws, so a folder and its band
/// agree: "Needs you" holds the asks, stuck strands, saved sessions' needs, the
/// sessions with an approval pending and the tickets that wait on an answer. "To
/// review" holds the finished sessions and the tickets whose work waits to be
/// read (`ticket_rule.lane`).
fn folder_counts(model: Model) -> List(#(inbox_rule.Folder, Int)) {
  let groups = model_groups(model)
  let in_group = fn(which) {
    case list.key_find(groups, which) {
      Ok(found) -> list.length(found)
      Error(Nil) -> 0
    }
  }

  // The reads the counts are made from: the feed's items, the saved sessions'
  // summaries and the tickets that wait on a person.
  let items = current_items(model)
  let saved = saved_threads(model)
  let tickets = waiting_tickets(model)
  let reading =
    list.length(ticket_rule.in_lane(
      ticket_rule.waiting(model.boards),
      ticket_rule.Reviewing,
    ))
  let needing =
    in_group(inbox_rule.NeedsYou)
    + list.length(attention_rule.needs_you(items))
    + list.length(attention_rule.saved_needing(saved))
    + tickets
    - reading
  let finds =
    list.length(attention_rule.finds(items))
    + list.length(attention_rule.saved_finding(saved))

  list.filter(
    [
      #(inbox_rule.Needing, needing),
      #(inbox_rule.Reviewing, in_group(inbox_rule.ToReview) + reading),
      #(inbox_rule.Finding, finds),
      #(inbox_rule.Updating, in_group(inbox_rule.Updates)),
      #(inbox_rule.Projecting, tickets),
    ],
    fn(entry) { entry.1 > 0 },
  )
}

/// How many things wait on the owner, as the top bar's pill counts them: the
/// "Needs you" folder's count.
fn needing_count(model: Model) -> Int {
  case list.key_find(folder_counts(model), inbox_rule.Needing) {
    Ok(count) -> count
    Error(Nil) -> 0
  }
}

/// The folder the list is narrowed to: the chosen one while its group holds
/// something, and `Everything` once it has emptied, so a list never draws as
/// blank under a folder the rail no longer offers.
fn shown_folder(model: Model) -> inbox_rule.Folder {
  case list.any(folder_counts(model), fn(entry) { entry.0 == model.folder }) {
    True -> model.folder
    False -> inbox_rule.Everything
  }
}

// The sessions of the orchestrators in the sidebar: one section for each machine
// that has rows or has been found silent, with the words saying so when its list
// is not current. A machine nothing was heard from, or that lists none, draws
// nothing.
/// Compiles sidebar relayed sessions sections for remote orchestrators.
fn relayed_rows(model: Model) -> sidebar.Relayed(Msg) {
  let now = model.now

  sidebar.Relayed(
    sections: list.filter_map(model.machines, fn(machine) {
      let note =
        orchestrators.reach_words(machine.orchestrator, machine.reach, now)

      // Omit machine if it lists no sessions and carries no reach notice.
      case machine.rows, note {
        [], "" -> Error(Nil)
        rows, _ ->
          Ok(sidebar.Section(
            orchestrator: machine.orchestrator,
            rows: orchestrators.ordered(rows),
            note:,
          ))
      }
    }),
    open: OpeningRelayed,
  )
}

/// What the sidebar's top and foot offer: "New session" and the row menus'
/// "Rename, move or delete" on the page that may create and manage, and "Admin"
/// where the daemon handed the page the capability.
fn sidebar_page(model: Model) -> sidebar.Page(Msg) {
  sidebar.Page(
    doors: sidebar.RowsOpen,
    machine: model.start.machine,
    filter: model.filter,
    narrowing: Narrowing,
    widening: Widening,
    starting: case model.start.create {
      Some(_) -> Some(ShowingNew)
      None -> None
    },
    administering: case model.start.admin, model.status {
      Some(_), Connected -> Some(AdminRequested)
      Some(_), Connecting | Some(_), Ended(_) | None, _ -> None
    },
    managing: case model.start.manage, model.start.rename {
      None, None -> None
      Some(_), _ | _, Some(_) -> Some(ShowingList)
    },
    who: model.name,
    watching: watching(model),
  )
}

/// The second line of each running session's row in the rail, in the words of
/// `watch_rule`: its activity, how many records the live rail pins for it, an
/// open ask, a tree waiting to be read, and its project. The pinned count is the
/// feed row's asks and stuck strands and one for a pending approval.
fn watching(model: Model) -> Dict(String, String) {
  let reviewing = reviewing_ids(model)

  listing.entries(model.groups)
  |> list.filter_map(fn(entry) {
    // Only a session a process runs has a line; the rest are not "Watch live".
    case entry.residency {
      Live -> {
        let activity = dict.get(model.activity, entry.id) |> option.from_result

        // A running session whose feed row was not read pins nothing.
        let #(asks, stuck) = case dict.get(model.feed, entry.id) {
          Ok(row) -> #(row.asks.count, row.stuck.count)
          Error(Nil) -> #(0, 0)
        }

        // A pending approval is pinned in the rail like an ask.
        let approval = case activity {
          Some(NeedsYou) -> 1
          Some(_) | None -> 0
        }

        Ok(#(
          entry.id,
          watch_rule.words(watch_rule.Facts(
            activity:,
            pinned: asks + stuck + approval,
            asks:,
            review: case list.contains(reviewing, entry.id) {
              True -> watch_rule.ToRead
              False -> watch_rule.NothingToRead
            },
            project: option.map(entry.project, creations.folder),
          )),
        ))
      }
      sessions.Saved
      | sessions.Blocked
      | sessions.FailedStart(_)
      | sessions.Moving(_) -> Error(Nil)
    }
  })
  |> dict.from_list
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

/// The pill's colour follows the standing, as a session page's does.
fn status_tone(status: Status) -> heading.Tone {
  case status {
    Connecting -> heading.Pending
    Connected -> heading.Live
    Ended(_) -> heading.Closed
  }
}

/// Formats connection status label in words.
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
