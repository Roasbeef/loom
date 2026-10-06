//// The home page's centre: the principal's sessions as one list for each
//// workspace, with whether a process runs each, what it is doing, and when it
//// was created.
////
//// The sidebar beside it lists the same sessions in a row's width; this is
//// where there is room for the detail a sidebar row cannot hold. The groups
//// are `sessions.grouped`'s, so the workspaces and the sessions in them are in
//// the order the sidebar draws them. A workspace is a heading with its
//// shortened path and a count, and each session under it is one list item:
//// a glyph in the row's hue, the session's name, and under it a quiet line of
//// words, `working · created 2h ago` for a session a process runs and
//// `saved · 2h ago` for one on disk. The glyph is decoration; the words carry
//// every difference, so none rests on a colour. A running session's activity
//// word is the daemon's own read (`sessions.Activity`), asked off the page's
//// runtime and handed over as a state word, and it stands in for the word
//// "running", which would only repeat it; a session the read has not answered
//// for says `running`.
////
//// A running session's row is a button (protocol-change/065, the second pull
//// request) whose one handler sends the caller's message naming that row's
//// session; the stylesheet stretches it over the whole row, tints the row on
//// hover and draws a chevron at its right edge, so the row reads as one
//// target. A saved session's row is a button only on a page that may resume it
//// (`view/resume`, protocol-change/065, the third pull request), and text
//// otherwise. A row that was pressed and is waiting on the daemon (an open or a
//// resume) dims, shows a spinner where its chevron was and says `Opening…`
//// in place of its words, and a second press asks nothing (`home.update`). The message names
//// the catalogue's identity, drawn when the tree was, and never a value the
//// browser sends: the home's socket admits a click only beneath this view's
//// own path (`home.table_path`), and the daemon checks the principal's
//// membership again before it mints a ticket.
////
//// The owner's fresh home also offers each row the actions that fit it
//// (`Manage`, protocol-change/065's addendum on session actions): a running
//// session can be stopped, and a saved one archived or deleted. They are quiet
//// buttons beside Rename in one `home-acts` group, after the row's own button,
//// so the row's own path is the same on every page. Archive asks the daemon at
//// once, and so does Stop on an idle row. Delete takes a second step in the
//// row: the row's words are replaced by "Delete this session? This cannot be
//// undone." with Delete and Cancel, the same in-place pattern as the rename
//// form, and Stop takes the same step, in a neutral tint and the words "Stop
//// this session mid-turn?", on a row that is working or waiting for the person
//// (the page decides, from the activity it read: `home.update`). While a
//// request for a row is out its buttons are disabled.
////
//// What the page last said about an action is a `Note`, and it never moves the
//// list. A completed action is a quiet line that fades (`view/notice`): in the
//// row it acted on, after the row's own words, or, when the row is gone (an
//// archived or deleted session), in its workspace's heading line, naming the
//// session (`docs sweep archived.`). A refusal stays, in the danger colour, in
//// the same place. A note that belongs to no row or workspace the page draws
//// is the one line under the page's heading.
////
//// Every name and path is the catalogue's, written by the owner and the host
//// and never by a session's agent, and is drawn as a text node. A workspace's
//// whole path is the heading's `title`. The creation time is the catalogue's
//// Unix milliseconds shown as an age, with the exact UTC minute in the `time`
//// element's `title`, built here from integers, so no value the browser or a
//// session supplied reaches a `datetime` attribute. The classes are complete
//// literals, so Tailwind finds them.
////
//// The module takes `sessions.Group`s and imports nothing from
//// `web_view/home`, which imports it.
////
//// ## Flow
////
//// `view` → `landing` → `group` → `row` → `offered` → `acts` → `confirming`
////
//// 1. `view` is the memoized section: the heading, the page's note, a
////    `group` for each workspace, the section for folders that hold no session
////    (`view/folders`), and `withheld_line` after them.
//// 2. `landing` decides where the page's last note is drawn, so it never moves
////    the list.
//// 3. `group` draws a workspace's heading and its rows, and `row` draws one
////    session, from its `standing` and, for the row's words, `described`.
//// 4. `offered` and `acts` choose the buttons a row carries from the page's
////    `Manage`, and `act` draws each one.
//// 5. `confirming` replaces a row for the second step of a Stop or a Delete,
////    and `editing` replaces it for a rename.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import web_view/actions.{type Stage}
import web_view/renames.{type Control}
import web_view/sessions.{
  type Activity, type Entry, type Group, Blocked, Idle, Live, NeedsYou, Saved,
  Working,
}
import web_view/view/archiving
import web_view/view/create.{type Create}
import web_view/view/folders.{type Folders} as folders_view
import web_view/view/heading
import web_view/view/notice.{type Notice}
import web_view/view/rename as rename_view
import web_view/view/resume.{type Resume}

/// What the table offers for renaming a session (protocol-change/067).
pub type Rename(message) {
  /// No control is drawn: the page's principal is not the daemon's owner, or
  /// the page was not minted to operate.
  Never

  /// Each row has a Rename button, and the one row named by `open` has its form
  /// in place of its words. `edit` is the message the button sends given the
  /// row's identity, `cancel` is the form's Cancel button, and `submit` builds
  /// the form's submit handler for a row's identity. The identities are the
  /// catalogue's, drawn into the tree by the server, so a browser's event never
  /// names a session.
  Offered(
    edit: fn(String) -> message,
    cancel: message,
    submit: fn(String) -> Attribute(message),
    open: Option(Open),
  )
}

/// The row whose rename form is open, and where the control stands.
pub type Open {
  Open(session: String, control: Control)
}

/// What the table offers for stopping, archiving and deleting a session
/// (protocol-change/065, the addendum on session actions).
pub type Manage(message) {
  /// No control is drawn: the page is not an owner's operating home, so it has
  /// none to explain.
  Unmanaged

  /// No control is drawn, and one quiet sentence says why: the page is the
  /// owner's home but a bookmark opened it, so Admin, Stop, Archive and Delete
  /// are on the home that `loom ui` opens and not here. The sentence is the
  /// section's last child, so no row's path moves for it.
  Withheld

  /// Each running row has a Stop button, and each saved row an Archive and a
  /// Delete. `stop` and `archive` are the messages those two send given the
  /// row's identity, and `delete` opens the row's confirmation. `confirm_stop`
  /// and `confirm_delete` are the confirmations' own buttons, and `cancel` is
  /// their Cancel. `stage` is where the page stands: the one row that is
  /// confirming or waiting on the daemon. The identities are the catalogue's,
  /// drawn into the tree by the server, so a browser's event never names a
  /// session.
  Managed(
    stop: fn(String) -> message,
    archive: fn(String) -> message,
    delete: fn(String) -> message,
    confirm_stop: fn(String) -> message,
    confirm_delete: fn(String) -> message,
    cancel: message,
    stage: Stage,
  )
}

/// Where a note is meant to be drawn.
pub type Place {
  /// Beside one session: its row if the page still draws it, else its
  /// workspace's heading line. `label` is the session's name as the row showed
  /// it, so the heading's line can name it once the row is gone.
  Session(id: String, workspace: String, label: String)

  /// Beside a workspace's heading, for what was done to the workspace (a
  /// refused creation).
  Workspace(path: String)

  /// In the section for folders that hold no session (`view/folders`), for what
  /// was done there: a refused creation in a typed or a remembered folder.
  Elsewhere

  /// Under the page's heading, for what belongs to no row.
  Page
}

/// What the page last said about a press: the words, whether they stay, and
/// where they go. The words are fixed by the page, never a session's, except
/// `Place`'s label, a catalogue name drawn as a text node.
pub type Note {
  Note(place: Place, notice: Notice)
}

// A note once the page has found where it lands, which depends on what the
// list holds now.
type Landing {
  InRow(session: String, notice: Notice)
  InHeading(workspace: String, notice: Notice)
  InFolders(notice: Notice)
  Under(notice: Notice)
}

/// The centre column's content: a heading, and one list for each group, or a
/// line that says there is nothing to list. `activity` is what the daemon last
/// said each running session is doing, by identity, and `now` is the instant in
/// Unix milliseconds the ages are counted from. `open` is the message a press
/// of a running session's row sends, given that session's identity, and
/// `resume` is what the page offers for a saved session's row. The result is
/// memoized on the groups, the activity, the instant and the session whose
/// resume is out, so a refresh that brings back what is drawn diffs nothing;
/// `open` and the resume's `press` are not part of the key, so a caller passes
/// the same functions every time, as a constructor is. `rename` is what the page
/// offers for renaming a row (`Rename`); the row whose form is open is part of
/// the key, and so is the control's state. `manage` is what the page offers for
/// acting on a row (`Manage`), and its stage is part of the key. `opening` is the
/// session whose open the daemon has not answered, and `note` is what the page
/// last said (`Note`); both are part of the key. `offer` is what the page offers for
/// making a session (`view/create`): under each workspace's heading a button, and
/// below it the form when that workspace's is open. Its state is in the key, so a
/// group changes when its form opens, closes or starts waiting. `folders` is the
/// section after the lists for folders that hold no session (`view/folders`); its
/// list and the page's last note are part of the key.
///
/// ## Examples
///
/// ```gleam
/// // home_table.view(home.groups(model), dict.new(), now, Opening, resume.Never, Never, Unmanaged, create.Never, folders.Hidden, None, None)
/// ```
pub fn view(
  groups: List(Group),
  activity: Dict(String, Activity),
  now: Int,
  open: fn(String) -> message,
  resume: Resume(message),
  rename: Rename(message),
  manage: Manage(message),
  offer: Create(message),
  folders: Folders(message),
  opening: Option(String),
  note: Option(Note),
) -> Element(message) {
  use <- element.memo([
    element.ref(groups),
    element.ref(activity),
    element.ref(now),
    element.ref(resume.pending(resume)),
    element.ref(open_form(rename)),
    element.ref(stage(manage)),
    element.ref(explains(manage)),
    element.ref(create.state(offer)),
    element.ref(folders_view.listed(folders)),
    element.ref(opening),
    element.ref(note),
  ])
  let landing = landing(groups, note)
  html.section([attribute.class("home-sessions")], [
    html.h2([attribute.class("home-heading")], [html.text("Sessions")]),
    case landing {
      Some(Under(notice:)) -> notice.line(notice)
      Some(InRow(..)) | Some(InHeading(..)) | Some(InFolders(..)) | None ->
        element.none()
    },
    ..list.append(
      case groups {
        [] -> [
          html.p([attribute.class("home-empty")], [
            html.text(
              "You hold no sessions yet. A session you start or are invited to appears here.",
            ),
          ]),
        ]
        [_, ..] ->
          list.map(groups, group(
            _,
            sessions.titles(groups),
            activity,
            now,
            open,
            resume,
            rename,
            manage,
            offer,
            opening,
            landing,
          ))
      },
      [
        folders_view.view(folders, offer, case landing {
          Some(InFolders(notice:)) -> Some(notice)
          Some(InRow(..)) | Some(InHeading(..)) | Some(Under(..)) | None -> None
        }),
        ..withheld_line(manage)
      ],
    )
  ])
}

// The sentence that says why a bookmark's home has no Admin, Stop, Archive or
// Delete, or nothing on a page that has no such question. It follows the lists,
// so it moves no row's path.
fn withheld_line(manage: Manage(message)) -> List(Element(message)) {
  case manage {
    Withheld -> [
      html.p([attribute.class("home-withheld")], [
        html.text(
          "This page was opened from a bookmark, so Admin, Stop, Archive "
          <> "and Delete are only on the home page that loom ui opens.",
        ),
      ]),
    ]
    Unmanaged | Managed(..) -> []
  }
}

// One project: its heading and the list of its sessions. The heading is the
// project's directory name, qualified when two projects share one
// (`sessions.titles`), and the project's whole path is its `title`.
fn group(
  group: Group,
  titles: Dict(String, String),
  activity: Dict(String, Activity),
  now: Int,
  open: fn(String) -> message,
  resume: Resume(message),
  rename: Rename(message),
  manage: Manage(message),
  offer: Create(message),
  opening: Option(String),
  landing: Option(Landing),
) -> Element(message) {
  html.section([attribute.class("home-group")], [
    html.div([attribute.class("home-group-head")], [
      html.h3(
        [attribute.class("home-workspace"), attribute.title(group.project)],
        [
          html.text(result.unwrap(
            dict.get(titles, group.project),
            heading.shorten_path(group.project),
          )),
          html.span([attribute.class("home-count")], [
            html.text(int.to_string(list.length(group.entries))),
          ]),
        ],
      ),
      case landing {
        Some(InHeading(workspace:, notice:)) if workspace == group.workspace ->
          notice.line(notice)
        Some(InHeading(..))
        | Some(InRow(..))
        | Some(InFolders(..))
        | Some(Under(..))
        | None -> element.none()
      },
      create.button(offer, group.workspace),
    ]),
    create.form(offer, group.workspace),

    // Rows are keyed by the session's identity, a daemon value and never model
    // text. A handler's path then names its session and not a position, so a
    // press in flight when a row above is archived cannot land on the row that
    // moved up into its place.
    keyed.ul(
      [attribute.class("home-list")],
      list.map(group.entries, fn(entry) {
        #(
          entry.id,
          row(
            entry,
            dict.get(activity, entry.id),
            now,
            open,
            resume,
            rename,
            manage,
            opening,
            landing,
          ),
        )
      }),
    ),
  ])
}

// What a row says about its session's process: the class that hues its glyph,
// the glyph, and the words of where the session lives and what it is doing.
type Standing {
  Standing(class: String, glyph: String, state: State)
}

// A running session says what it is doing once the daemon has said, and
// "running" until then. The activity word stands in for "running" and does not
// follow it, since a session that is working is running. A session on disk is
// "saved", one whose open the daemon has not answered says "Opening…" and
// nothing else, and one the daemon will not open from a page (`Blocked`) says
// "needs attention" and carries a title that says why.
type State {
  Running(activity: Option(String))
  Stored
  Attention
  Waking
}

// The title of a blocked row's words. It is a fixed sentence for the closed
// `Blocked` reason and never the daemon's text (protocol-change/051).
const attention_title =
  "This session was never finished, or its recovery stopped. Nothing is running it and a page cannot open it. You can archive or delete it."

fn standing(
  entry: Entry,
  activity: Result(Activity, Nil),
  kind: resume.Kind(message),
  opening: Option(String),
) -> Standing {
  case entry.residency, kind, opening {
    Live, _, Some(pressed) if pressed == entry.id ->
      Standing("opening", "…", Waking)
    Live, _, _ ->
      case activity {
        Ok(doing) ->
          Standing(
            activity_class(doing),
            "●",
            Running(Some(sessions.activity_words(doing))),
          )
        Error(Nil) -> Standing("live", "●", Running(None))
      }
    Saved, resume.Opening, _ -> Standing("opening", "…", Waking)
    Saved, _, _ -> Standing("saved", "○", Stored)
    Blocked, _, _ -> Standing("saved", "○", Attention)
  }
}

// The class a glyph's hue and motion follow, a complete literal.
fn activity_class(activity: Activity) -> String {
  case activity {
    NeedsYou -> "needs-you"
    sessions.Failed -> "failed"
    Working -> "working"
    Idle -> "idle"
  }
}

// Where the page stands in acting on a row, for the memo's key.
fn stage(manage: Manage(message)) -> Stage {
  case manage {
    Unmanaged | Withheld -> actions.Calm
    Managed(stage:, ..) -> stage
  }
}

// Whether the page draws the sentence that says why there are no controls, for
// the memo's key: `stage` is calm for both of the pages that draw none.
fn explains(manage: Manage(message)) -> Bool {
  case manage {
    Withheld -> True
    Unmanaged | Managed(..) -> False
  }
}

// The form that is open, for the memo's key: the page's own state, which is
// the row's identity and the control's word.
fn open_form(rename: Rename(message)) -> Option(Open) {
  case rename {
    Never -> None
    Offered(open:, ..) -> open
  }
}

// One session's list item. The whole item is one button when a press can open
// it and one block of text when not, so the words read the same either way. On
// a page that may rename or act on a row, a group of quiet buttons follows it,
// after the item so that the item's own path is the same on every page. The row
// whose rename form is open is the form and nothing else, and so is the row
// whose delete is waiting on its second press.
fn row(
  entry: Entry,
  activity: Result(Activity, Nil),
  now: Int,
  open: fn(String) -> message,
  resume: Resume(message),
  rename: Rename(message),
  manage: Manage(message),
  opening: Option(String),
  landing: Option(Landing),
) -> Element(message) {
  let kind = resume.kind(resume, entry)
  let standing = standing(entry, activity, kind, opening)
  let note = case landing {
    Some(InRow(session:, notice:)) if session == entry.id -> Some(notice)
    Some(InRow(..))
    | Some(InHeading(..))
    | Some(InFolders(..))
    | Some(Under(..))
    | None -> None
  }
  let body = [
    html.span([attribute.class("home-glyph"), attribute.aria_hidden(True)], [
      html.text(standing.glyph),
    ]),
    html.span([attribute.class("home-text")], [
      html.span([attribute.class("home-name")], [
        html.text(sessions.label(entry)),
      ]),
      html.span(
        [attribute.class("home-sub")],
        quiet_line(standing, entry, now, note),
      ),
    ]),
  ]
  let item = case entry.residency, kind {
    Live, _ -> pressable("Open this session", open(entry.id), body)
    Saved, resume.Button(press:) ->
      pressable("Resume this session", press, body)

    // A saved row whose resume is out is not a button, but it draws the chevron,
    // which the stylesheet turns into a spinner, so it reads like a pressed
    // running row.
    Saved, resume.Opening ->
      html.div([attribute.class("home-item")], list.append(body, [chevron()]))
    Saved, _ | Blocked, _ -> html.div([attribute.class("home-item")], body)
  }
  let classes = [attribute.class("home-row"), attribute.class(standing.class)]
  let manage = in_row(manage)
  case rename, manage {
    Offered(open: Some(Open(session:, control:)), cancel:, submit:, ..), _
      if session == entry.id
    ->
      html.li([attribute.class("editing"), ..classes], [
        editing(entry, control, cancel, submit(entry.id)),
      ])
    _,
      Managed(
        stage: actions.Confirming(session:, action:),
        confirm_stop:,
        confirm_delete:,
        cancel:,
        ..,
      )
      if session == entry.id
    ->
      html.li(
        [
          attribute.class("confirming"),
          attribute.class(confirm_class(action)),
          ..classes
        ],
        [
          confirming(
            entry,
            action,
            case action {
              actions.Delete -> confirm_delete(entry.id)
              actions.Stop | actions.Archive | actions.StopArchive ->
                confirm_stop(entry.id)
            },
            cancel,
          ),
        ],
      )
    _, _ ->
      case offered(standing, entry, rename, manage) {
        [] -> html.li(classes, [item])
        [_, ..] as buttons ->
          html.li(
            [
              attribute.class("actionable"),
              attribute.class("acts-" <> int.to_string(list.length(buttons))),
              ..case rename {
                Never -> classes
                Offered(..) -> [attribute.class("renamable"), ..classes]
              }
            ],
            [item, html.div([attribute.class("home-acts")], buttons)],
          )
      }
  }
}

// The buttons a row draws. A row waiting on the daemon offers none of its own,
// so Stop and Rename cannot be pressed while its open is out.
fn offered(
  standing: Standing,
  entry: Entry,
  rename: Rename(message),
  manage: Manage(message),
) -> List(Element(message)) {
  case standing.state {
    Waking -> []
    Running(_) | Stored | Attention -> acts(entry, rename, manage)
  }
}

// The quiet buttons a row carries, in the order they are drawn: Rename where
// the page may rename, then the actions that fit the row's state. A running row
// can only be stopped, since the registry refuses to archive or delete what a
// process holds; a saved one can be archived or deleted, and a blocked one
// too, since nothing runs it. While a request for this row is out the buttons
// are disabled, though the handlers stay, because the component is the layer
// that ignores a second press.
fn acts(
  entry: Entry,
  rename: Rename(message),
  manage: Manage(message),
) -> List(Element(message)) {
  let renaming = case rename {
    Never -> []
    Offered(edit:, ..) -> [
      act("home-rename", "Rename this session", "Rename", edit(entry.id), []),
    ]
  }
  let working = case manage {
    Managed(stage: actions.Working(session:, ..), ..) if session == entry.id -> [
      attribute.disabled(True),
    ]
    _ -> []
  }
  let managing = case manage, entry.residency {
    Unmanaged, _ | Withheld, _ -> []
    Managed(stop:, ..), Live -> [
      act("home-act", "Stop this session", "Stop", stop(entry.id), working),
    ]

    // A blocked row is on disk and nothing runs it, so it can be archived or
    // deleted like a saved one, and a stop has nothing to end. An unreconciled
    // creation holds no registry slot, so the registry takes both. A session
    // whose recovery stopped does hold one: the registry refuses it as busy
    // and the row says so, because releasing a slot whose holder is still
    // alive could let a second writer open the same database.
    Managed(archive:, delete:, ..), Saved
    | Managed(archive:, delete:, ..), Blocked
    -> [
      act(
        "home-act",
        "Archive this session: hide it and keep its history",
        "Archive",
        archive(entry.id),
        working,
      ),
      act(
        "home-act home-act-delete",
        "Delete this session",
        "Delete",
        delete(entry.id),
        working,
      ),
    ]
  }
  list.append(renaming, managing)
}

// One quiet button of the group.
fn act(
  class: String,
  title: String,
  label: String,
  press: message,
  more: List(Attribute(message)),
) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class(class),
      attribute.title(title),
      event.on_click(press),
      ..more
    ],
    [html.text(label)],
  )
}

// The class that tints a confirmation: toward the danger hue for a delete,
// which cannot be undone, and neutral for a stop, which can.
fn confirm_class(action: actions.Action) -> String {
  case action {
    actions.Delete -> "confirm-delete"
    actions.Stop | actions.Archive | actions.StopArchive -> "confirm-stop"
  }
}

// What the row itself sees of the page's stage. Stop and Delete ask in the
// row; the sidebar's Archive and Stop-and-archive ask in the sidebar
// (`view/archiving`), so for the row the page is calm while one of those asks,
// and the same state never draws the question twice.
fn in_row(manage: Manage(message)) -> Manage(message) {
  case manage {
    Managed(stage: actions.Confirming(action:, ..), ..) as managed ->
      case archiving.confirms(action) {
        True -> Managed(..managed, stage: actions.Calm)
        False -> manage
      }
    Managed(..) | Unmanaged | Withheld -> manage
  }
}

// The row's second step before an action that cannot be taken back or that
// cuts a turn short: one question in fixed words, the session's name beneath it
// as a text node so the person sees which row they are about to act on, a
// button that sends the request and a Cancel that puts the row back.
fn confirming(
  entry: Entry,
  action: actions.Action,
  confirm: message,
  cancel: message,
) -> Element(message) {
  let #(label, lead, button, class) = case action {
    actions.Delete -> #(
      "Delete this session",
      "Delete this session? This cannot be undone.",
      "Delete",
      "home-confirm-go home-confirm-delete",
    )
    actions.Stop | actions.Archive | actions.StopArchive -> #(
      "Stop this session",
      "Stop this session mid-turn?",
      "Stop",
      "home-confirm-go",
    )
  }
  html.div(
    [
      attribute.class("home-confirm"),
      attribute.role("alertdialog"),
      attribute.aria_label(label),
    ],
    [
      html.div([attribute.class("home-confirm-text")], [
        html.p([attribute.class("home-confirm-lead")], [html.text(lead)]),
        html.p([attribute.class("home-confirm-name")], [
          html.text(sessions.label(entry)),
        ]),
      ]),
      html.div([attribute.class("home-confirm-actions")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class(class),
            event.on_click(confirm),
          ],
          [html.text(button)],
        ),
        html.button([attribute.type_("button"), event.on_click(cancel)], [
          html.text("Cancel"),
        ]),
      ]),
    ],
  )
}

// A row's rename form, in place of the row's words. The session's current name
// is a text node in the lead, and never the field's `value` or `placeholder`,
// which are attributes; `<loom-rename>` copies it into the field in the browser
// when the form opens (`view/rename.field`). The field is uncontrolled, and the one submit sends its
// text under the name `text`; Cancel is a button that closes the form. While a
// request is out the buttons are disabled, though the handlers stay, because the
// component is the layer that ignores a second one. A refusal is in the reason's
// fixed words.
fn editing(
  entry: Entry,
  control: Control,
  cancel: message,
  submit: Attribute(message),
) -> Element(message) {
  let asking = case control {
    renames.Asking -> [attribute.disabled(True)]
    renames.Withheld | renames.Ready | renames.Done | renames.Refused(..) -> []
  }
  html.form(
    [
      attribute.class("home-rename-form"),
      attribute.aria_label("Rename this session"),
      attribute.attribute(rename_view.scope_marker, ""),
      submit,
    ],
    [
      html.p([attribute.class("home-rename-lead")], case entry.name {
        // An unnamed session's label is a fallback built from its identity, and
        // it is not a name: left unmarked, the field opens empty rather than
        // offering the fallback to be saved as one.
        "" -> [html.text("Rename " <> sessions.label(entry))]
        name -> [
          html.text("Rename "),
          html.span([attribute.attribute(rename_view.name_marker, "")], [
            html.text(name),
          ]),
        ]
      }),
      html.div([attribute.class("home-rename-fields")], [
        rename_view.field(),
        html.button([attribute.type_("submit"), ..asking], [
          html.text("Rename"),
        ]),
        html.button(
          [attribute.type_("button"), event.on_click(cancel), ..asking],
          [html.text("Cancel")],
        ),
      ]),
      status(control),
    ],
  )
}

// The status line: empty except after a refusal, so the form's children keep
// their places.
fn status(control: Control) -> Element(message) {
  case control {
    renames.Refused(reason:) ->
      html.p(
        [
          attribute.class("rename-status"),
          attribute.class("refused"),
          attribute.role("status"),
        ],
        [html.text(renames.reason_words(reason))],
      )
    renames.Withheld | renames.Ready | renames.Asking | renames.Done ->
      html.p([attribute.class("rename-status"), attribute.role("status")], [])
  }
}

// The quiet line under the name. A session with a subtitle leads with it, then
// the standing's words, and says no age: the subtitle is what tells sessions of
// one workspace apart (protocol-change/067), and the creation time stays in the
// session's own page. Any other session reads as it always did: the standing's
// words joined by a middle dot, then the age, where a running session's says it
// was created and a saved one's is the bare age, since "saved" already says
// what it is. The activity word is its own `home-activity` span, so a row that
// needs the person can tint that one word and leave the subtitle in the quiet
// colour: a sixty-character prompt in the signal colour reads as an error. The
// subtitle is a person's own prompt, so it is a text node and nothing else.
//
// A row waiting on the daemon says "Opening…" and nothing else. A note for the
// row, if there is one, ends the line after a middle dot, in the same line so
// the row's height never changes when it appears or fades.
fn quiet_line(
  standing: Standing,
  entry: Entry,
  now: Int,
  note: Option(Notice),
) -> List(Element(message)) {
  let line = case standing.state {
    Waking -> [html.text("Opening…")]
    Running(_) | Stored | Attention -> described(standing, entry, now)
  }
  case note {
    Some(notice) -> list.append(line, [inline(notice)])
    None -> line
  }
}

// The standing's words, the person's role, and the subtitle or the age.
fn described(
  standing: Standing,
  entry: Entry,
  now: Int,
) -> List(Element(message)) {
  let lead = case standing.state {
    Running(Some(doing)) -> [
      html.span([attribute.class("home-activity")], [html.text(doing)]),
    ]
    Running(None) -> [html.text("running")]
    Stored | Waking -> [html.text("saved")]
    Attention -> [
      html.span([attribute.title(attention_title)], [
        html.text("needs attention"),
      ]),
    ]
  }

  // The person's role in this session ends the standing's words, after the
  // activity: a member reads "idle · observer", and the owner's rows, which have
  // no role, read as they did.
  let lead = case entry.role {
    Some(role) ->
      list.append(lead, [html.text(" · " <> sessions.role_words(role))])
    None -> lead
  }
  let words = case entry.subtitle {
    Some(subtitle) -> [
      html.span([attribute.class("home-subtitle")], [html.text(subtitle)]),
      html.text(" · "),
      ..lead
    ]
    None -> {
      let age = created(entry.created_at, sessions.ago(now, entry.created_at))
      case entry.residency {
        Live -> list.append(lead, [html.text(" · created "), age])
        Saved | Blocked -> list.append(lead, [html.text(" · "), age])
      }
    }
  }

  // A session in a git worktree leads its quiet line with the worktree's
  // directory name, and the whole path is that word's title. The path is the
  // host's own, never a session's.
  case sessions.worktree(entry) {
    Some(tree) -> [
      html.span(
        [attribute.class("home-tree"), attribute.title(entry.workspace)],
        [html.text(tree)],
      ),
      html.text(" · "),
      ..words
    ]
    None -> words
  }
}

// A note's words as a span ending the row's quiet line, with the middle dot that
// joins it to the words before it inside the span, so the dot fades with a said
// note and does not outlast it. A refused note stays in the danger colour
// (`view/notice`), and neither draws a handler.
fn inline(notice: Notice) -> Element(message) {
  case notice {
    notice.Said(words:) ->
      html.span([attribute.class("home-note"), attribute.role("status")], [
        html.text(" · " <> words),
      ])
    notice.Refused(words:) ->
      html.span(
        [
          attribute.class("home-note"),
          attribute.class("refused"),
          attribute.role("status"),
        ],
        [html.text(" · " <> words)],
      )

    // A grant allowance is the admin page's, and the home never words a
    // refusal of one, so a throttled notice has nothing to say in a row.
    notice.Throttled(..) -> element.none()
  }
}

// Where the page's note lands, given what it lists now. A note beside a session
// goes in that session's row, or in its workspace's heading when the row is gone
// (an archived or a deleted session), naming the session there. A note beside a
// workspace goes in its heading. A note about a folder that holds no session
// goes in that section's head. Anything else, or a workspace the page no longer
// draws, goes under the page's heading.
fn landing(groups: List(Group), note: Option(Note)) -> Option(Landing) {
  case note {
    None -> None
    Some(Note(place: Page, notice:)) -> Some(Under(notice))
    Some(Note(place: Elsewhere, notice:)) -> Some(InFolders(notice))
    Some(Note(place: Workspace(path:), notice:)) ->
      Some(in_heading(groups, path, notice))
    Some(Note(place: Session(id:, workspace:, label:), notice:)) -> {
      let held =
        list.any(groups, fn(group) {
          list.any(group.entries, fn(entry) { entry.id == id })
        })
      case held {
        True -> Some(InRow(id, notice))
        False -> Some(in_heading(groups, workspace, named(label, notice)))
      }
    }
  }
}

fn in_heading(groups: List(Group), path: String, notice: Notice) -> Landing {
  case list.any(groups, fn(group) { group.workspace == path }) {
    True -> InHeading(path, notice)
    False -> Under(notice)
  }
}

// A note's words with the session's name in front, for a place that is not the
// session's own row: "docs sweep archived." and "docs sweep: <the refusal>".
fn named(label: String, notice: Notice) -> Notice {
  case notice {
    notice.Said(words:) -> notice.Said(label <> " " <> string.lowercase(words))
    notice.Refused(words:) -> notice.Refused(label <> ": " <> words)

    // The admin page's grant refusal carries no words to put a name in front
    // of, and the home never makes one.
    notice.Throttled(..) -> notice
  }
}

// The row as one button, which the stylesheet stretches over the whole item,
// with a chevron at its right edge that says it opens.
fn pressable(
  title: String,
  press: message,
  body: List(Element(message)),
) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("home-open"),
      attribute.title(title),
      event.on_click(press),
    ],
    list.append(body, [chevron()]),
  )
}

// The mark at a row's right edge that says it opens.
fn chevron() -> Element(message) {
  html.span([attribute.class("home-chevron"), attribute.aria_hidden(True)], [
    html.text("›"),
  ])
}

// The age as a `<time>` whose `datetime` is the creation minute in UTC and
// whose `title` is the same minute in words.
fn created(at: Int, age: String) -> Element(message) {
  let #(date, clock) = utc(at)
  html.time(
    [
      attribute.attribute("datetime", date <> "T" <> clock <> "Z"),
      attribute.title(date <> " " <> clock <> " UTC"),
    ],
    [html.text(age)],
  )
}

/// A Unix time in milliseconds as a UTC date, `YYYY-MM-DD`, and a time of day
/// to the minute, `HH:MM`. A time before the epoch is shown as the epoch,
/// since the catalogue records creations and none is earlier.
///
/// ## Examples
///
/// ```gleam
/// assert home_table.utc(1_790_000_000_000) == #("2026-09-21", "14:13")
/// ```
pub fn utc(milliseconds: Int) -> #(String, String) {
  let seconds = int.max(milliseconds, 0) / 1000
  let days = seconds / 86_400
  let minutes = seconds % 86_400 / 60
  let #(year, month, day) = civil(days)
  #(
    pad(year, 4) <> "-" <> pad(month, 2) <> "-" <> pad(day, 2),
    pad(minutes / 60, 2) <> ":" <> pad(minutes % 60, 2),
  )
}

// The proleptic Gregorian date of a day count since 1970-01-01. This is
// Howard Hinnant's `civil_from_days`: the days are shifted to begin on
// 0000-03-01, so a leap day is the last day of a year, and counted in
// 400-year eras of 146,097 days.
fn civil(days: Int) -> #(Int, Int, Int) {
  let shifted = days + 719_468
  let era = shifted / 146_097
  let day_of_era = shifted % 146_097

  // The year within the era, correcting for the century years that are not
  // leap years.
  let year_of_era =
    {
      day_of_era
      - day_of_era
      / 1460
      + day_of_era
      / 36_524
      - day_of_era
      / 146_096
    }
    / 365

  // The day within the March-first year, and the month and day it falls in,
  // counting March as month zero.
  let day_of_year =
    day_of_era - { 365 * year_of_era + year_of_era / 4 - year_of_era / 100 }
  let month_index = { 5 * day_of_year + 2 } / 153
  let day = day_of_year - { 153 * month_index + 2 } / 5 + 1
  let month = case month_index < 10 {
    True -> month_index + 3
    False -> month_index - 9
  }
  let year = year_of_era + era * 400
  case month <= 2 {
    True -> #(year + 1, month, day)
    False -> #(year, month, day)
  }
}

// A number written with at least `width` digits.
fn pad(number: Int, width: Int) -> String {
  string.pad_start(int.to_string(number), width, "0")
}
