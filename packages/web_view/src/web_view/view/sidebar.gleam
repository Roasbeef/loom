//// The session sidebar: the principal's sessions, grouped by what each needs
//// from the person, each with a tag saying where its agent runs and where its
//// code lives (the placement revamp,
//// [`docs/design-notes/placement-revamp.md`](../../../../../docs/design-notes/placement-revamp.md)).
////
//// The sidebar draws a list the daemon's catalogue supplied
//// (`web_view/sessions`) and decides nothing. How the rows are grouped and
//// filtered is `web_view/listing`'s, and this module only draws it: the
//// daemon's name and a "New session" button at the top, a row of machine
//// filter pills when the sessions use more than one machine, the groups
//// "Needs you", "Working" and "Idle" and a folded "Saved" group, and a foot
//// with the pages that are not sessions. The same column is the home page's, a
//// session page's and the admin page's, so a person who learns it once finds it
//// where they go.
////
//// A page is bound to one session by its key, so opening another is a
//// navigation to a new page (protocol-change/051, the addendum on switching
//// sessions), and the row of a session that can be opened is a button whose one
//// handler sends the message its caller gave, naming that row's session. A row
//// is a button only where pressing it can work: a session that a process runs
//// and that is not the one on screen, or a saved one on a page that may resume
//// it (`view/resume`, protocol-change/065, the third pull request). The session
//// on screen is text, and so is a saved session elsewhere, so the sidebar never
//// offers a press the daemon would refuse or that would do nothing. While a
//// resume is out its row reads "opening" and every other saved row is text. The
//// session named by a button's message is the catalogue's identity, drawn when
//// the tree was, and never a value the browser sends.
////
//// The pills and the buttons at the top and foot send messages the server drew
//// into the tree. A pill's message carries the machine's name, and the page
//// accepts it only if `listing.chosen` finds a pill by that name in the list it
//// holds, so a forged name changes nothing.
////
//// The sidebar is the second child of the page's frame (`view/shell`), between
//// the top bar and the centre column, in the frame's `left` slot.
//// `component.sidebar_path` names its path, and the paths `component.older_path`
//// and `component.strip_path` name are those of regions after it, so it keeps
//// its place as `element.none()` when it is not drawn.
////
//// The running groups list the sessions a process runs. The saved ones sit
//// after them behind a quiet "N saved" line: the same rows, in a panel the
//// stylesheet hides until `<loom-saved>` (`web_client/saved`) opens it in the
//// browser. They stay in the document, so the session switcher, which reads the
//// sidebar's `.session-open` buttons, still lists them while they are folded,
//// and the session on screen is always listed above, saved or not. The line is a
//// button with no handler. The quiet rows past `listing.idle_shown` fold behind a
//// native `<details>`, which also needs no handler.
////
//// Every name is drawn as a text node, and a workspace's whole path as a
//// `title` attribute that Lustre escapes. The catalogue's fields are written by
//// the owner and the host and never by a session's agent, but nothing here is
//// built from transcript text either way. The session on screen is marked by
//// `aria-current` and a class, and a session with no name is named by its
//// identity's first eight characters, as the heading names it. The classes are
//// complete literals, so Tailwind finds them.
////
//// The session on screen draws the same activity dot as every other running
//// row, but its state comes from the page's own lane (strand statuses and
//// pending approvals) and not from the periodic activity read, so it never lags
//// the session it names (`component.session_activity`).
////
//// A row can also carry a small menu, which `view/archiving` fills: a press of
//// the dots opens it, a press of its Archive replaces the row with one question
//// and sends nothing until it is confirmed, and the session on screen explains in
//// a `title` why it has none. The page decides whether the action exists by what
//// it passes, so a page without the capability draws none of it.
////
//// ## Sessions of other orchestrators
////
//// The owner's home can also draw the sessions its daemon relays on other
//// orchestrators (protocol-change/094, `Relayed`): one section for each
//// orchestrator after the saved sessions, headed "On <name>", whose rows say the
//// session's state and where it runs, with the orchestrator's name as the agent.
//// A row is a button whose message names the orchestrator and the session the
//// server drew, and the page opens the relayed page only for a row it holds. An
//// orchestrator that stopped answering keeps its last rows, drawn quieter under
//// one line that says so (`relayed-side-note`). A session page draws none of it.
////
//// The module takes the groups the page holds and imports nothing from
//// `web_view/component`, which imports it.
////
//// ## Flow
////
//// `view` / `home` → `column` → `entry` → `lead`, and `relayed_sections` →
//// `relayed_section` → `relayed_row`
////
//// 1. `view` is a session page's sidebar and `home` the home's. Each memoizes on
////    what it draws and hands `column` the groups.
//// 2. `column` lays the column out: the top, the pills, a section for each state,
////    the saved region, the other orchestrators' sections and the foot.
//// 3. `entry` draws one session's row and `lead` its two lines.
//// 4. `relayed_sections` draws the sessions of the orchestrators the daemon relays
////    for, one `relayed_section` for each, and `relayed_row` one session of it.
////
//// ## Examples
////
//// ```gleam
//// // sidebar.view(component.session_groups(model), component.session_id(model), activity, page, open, resume, archiving)
//// ```

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import web_view/listing.{type Filter, type Row, type Rows}
import web_view/orchestrators.{type Listed}
import web_view/relayed as relayed_words
import web_view/sessions.{
  type Activity, type Entry, type Group, Blocked, FailedStart, Idle, Live,
  Moving, NeedsYou, Saved, Working,
}
import web_view/view/archiving.{type Archiving}
import web_view/view/resume.{type Resume}

/// What a row's word says for a running session the activity read has not named.
type Suffix {
  /// The home's answer to the activity read, by session identity: the word for a
  /// session the read named, and nothing for one it has not yet, so a row never
  /// says "running" in one column and "working" in another.
  Doing(Dict(String, Activity))

  /// The session page's answer to the same read: "running" for a session the read
  /// has not named, since the page has no other column to disagree with.
  Known(Dict(String, Activity))
}

/// Whether a pill is the one the list is narrowed to.
type Mark {
  /// The pill names the machine the list shows.
  Chosen

  /// The pill is another choice.
  Offered
}

/// Whether a running session's row is a button.
pub type Doors {
  /// A row of another running session opens it: the home and a session page,
  /// whose daemon can mint the ticket.
  RowsOpen

  /// A row says what a session is and does nothing when pressed: the admin page,
  /// which draws no way to another page and so mints no ticket
  /// (protocol-change/065, the fifth pull request).
  RowsShown
}

/// What the page supplies for the parts of the column that are not session
/// rows. Every message is fixed when the tree is drawn.
pub type Page(message) {
  Page(
    /// Whether another running session's row is a button.
    doors: Doors,
    /// The name of the daemon serving the page: the agent every session on the
    /// list runs on, until a page can list another orchestrator's. It is the
    /// operator's configuration, drawn as a text node.
    machine: String,
    /// The machine the list is narrowed to.
    filter: Filter,
    /// A pill's press, given the machine the pill names. The page checks the
    /// name against the pills it holds (`listing.chosen`).
    narrowing: fn(String) -> message,
    /// The "All" pill's press: show every session.
    widening: message,
    /// The "New session" button's message, or `None` where the page may not
    /// create sessions or draws the button elsewhere.
    starting: Option(message),
    /// The foot's "Admin" button's message, or `None` on a page that has no
    /// admin to open.
    administering: Option(message),
    /// The row menu's "Rename, move or delete" press, which shows the full list
    /// where those controls are, or `None` where there is no such list.
    managing: Option(message),
    /// The principal's display name for the foot, or an empty string.
    who: String,
  )
}

/// One orchestrator's sessions as the sidebar draws them.
pub type Section {
  Section(
    /// The `[orchestrators.<name>]` key, drawn as a text node.
    orchestrator: String,
    /// The sessions, in the order they are drawn.
    rows: List(Listed),
    /// What to say when the list is not current, or an empty string. It is words
    /// the page wrote from the key and a time, drawn as a text node.
    note: String,
  )
}

/// What the home adds to the column for the orchestrators it relays for.
pub type Relayed(message) {
  Relayed(
    /// One section for each orchestrator with something to show.
    sections: List(Section),
    /// A row's press, given the orchestrator's key and the session's identity.
    /// The page honours it only for a row it holds.
    open: fn(String, String) -> message,
  )
}

/// The sidebar a session page draws for `groups`, with the session named
/// `current` marked, `activity` what the daemon last said each running session
/// is doing (a session it has not named says "running"), `open` the message a
/// press of another live session's row sends given that session's identity,
/// `resume` what the page offers for a saved session's row, and `archiving`
/// what it offers for archiving a row.
///
/// With no group it is `element.none()`, so a page whose daemon listed nothing,
/// or could not, draws no empty column. The result is memoized on the groups,
/// the identity, the activity, the page's values and where the archive action
/// stands, so a page that re-read an unchanged list diffs nothing. `open` and the
/// other functions are not part of the memo's key, so a caller passes the same
/// functions every time, as a constructor is; the session whose resume is out
/// is, so its row changes when the resume starts and when it ends.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.view(component.session_groups(model), component.session_id(model), dict.new(), page, Opening, resume.Never, archiving.Never)
/// ```
pub fn view(
  groups: List(Group),
  current: String,
  activity: Dict(String, Activity),
  page: Page(message),
  open: fn(String) -> message,
  resume: Resume(message),
  archiving: Archiving(message),
) -> Element(message) {
  use <- element.memo([
    element.ref(groups),
    element.ref(current),
    element.ref(activity),
    element.ref(memoed(page)),
    element.ref(resume.pending(resume)),
    element.ref(archiving.stage(archiving)),
  ])

  // Dispatch on view state.
  case groups {
    [] -> element.none()
    [_, ..] ->
      column(
        groups,
        current,
        Known(activity),
        page,
        open,
        resume,
        archiving,
        None,
      )
  }
}

/// The sidebar the home page draws (protocol-change/065): the same column, with
/// no session on screen. Every running session's row is a button whose message is
/// `open` applied to that session's identity, and a saved session's row is what
/// `resume` says. Every handler is therefore beneath the sidebar's own path
/// (`home.sidebar_path`), which is the one place the home's socket admits a click
/// on this column.
///
/// A running session's dot follows the page's `activity` read ("needs you" in the
/// signal hue, "working", "idle"), the word the home's list says for the same
/// session, and says nothing while no answer has arrived. A saved row says
/// "saved", as it always did.
///
/// Unlike `view` it is drawn with no group at all, because the column holds the
/// "New session" button, and a daemon with no session yet is where a person
/// starts one.
///
/// `relayed` adds the sessions of the orchestrators the daemon relays for, after
/// the saved ones, and is the memo's key as the groups are.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.home(home.groups(model), dict.new(), page, Opening, resume.Never, archiving.Never, relayed)
/// ```
pub fn home(
  groups: List(Group),
  activity: Dict(String, Activity),
  page: Page(message),
  open: fn(String) -> message,
  resume: Resume(message),
  archiving: Archiving(message),
  relayed: Relayed(message),
) -> Element(message) {
  use <- element.memo([
    element.ref(groups),
    element.ref(activity),
    element.ref(memoed(page)),
    element.ref(resume.pending(resume)),
    element.ref(archiving.stage(archiving)),
    element.ref(relayed.sections),
  ])
  column(
    groups,
    "",
    Doing(activity),
    page,
    open,
    resume,
    archiving,
    Some(relayed),
  )
}

/// The parts of a page's values that decide what is drawn, which is everything
/// but its functions: the memo compares these and never a closure.
fn memoed(
  page: Page(message),
) -> #(
  Doors,
  String,
  Filter,
  Option(message),
  Option(message),
  Option(message),
  String,
) {
  #(
    page.doors,
    page.machine,
    page.filter,
    page.starting,
    page.administering,
    page.managing,
    page.who,
  )
}

/// The column itself: its title, the top (the daemon's name and "New session"),
/// the pills, one section for each group that has a running session, the folded
/// saved sessions and the foot. The sections sit in a scrolling region of their
/// own so the top and the foot stay in view.
fn column(
  groups: List(Group),
  current: String,
  suffix: Suffix,
  page: Page(message),
  open: fn(String) -> message,
  resume: Resume(message),
  archiving: Archiving(message),
  relayed: Option(Relayed(message)),
) -> Element(message) {
  let all = listing.entries(groups)
  let rows =
    listing.sorted(all, activity_of(suffix), page.machine, page.filter, current)
  let draw = entry(_, current, suffix, page, open, resume, archiving)

  html.aside(
    [
      attribute.class("sidebar"),
      attribute.aria_label("Sessions"),
      attribute.attribute("slot", "left"),
    ],
    [
      html.h2([attribute.class("sidebar-title")], [html.text("Sessions")]),
      top(page),
      pills(all, page),
      html.div([attribute.class("side-scroll")], [
        state("Needs you", "state-needs-you", rows.needs, draw),
        state("Working", "state-working", rows.working, draw),
        idle(rows, draw),
        saved_region(rows.saved, draw),
        relayed_sections(relayed),
      ]),
      foot(page),
    ],
  )
}

/// The orchestrators' sections as one child of the scrolling region, so the
/// region's other children keep their places whether or not there is anything to
/// draw here. A session page has none.
fn relayed_sections(relayed: Option(Relayed(message))) -> Element(message) {
  case relayed {
    Some(Relayed(sections: [_, ..] as sections, open:)) ->
      html.div(
        [attribute.class("relayed-side")],
        list.map(sections, relayed_section(_, open)),
      )
    Some(Relayed(sections: [], ..)) | None -> element.none()
  }
}

/// One orchestrator's section: its heading with the count, the line saying it is
/// not answering when it is not, and its rows. A section that is not current says
/// so in `relayed-side-quiet`, which the stylesheet draws quieter.
fn relayed_section(
  section: Section,
  open: fn(String, String) -> message,
) -> Element(message) {
  // Dispatch on relayed_section state.
  let stale = case section.note {
    "" -> []
    _ -> [attribute.class("relayed-side-quiet")]
  }

  // Dispatch on relayed_section state.
  let note = case section.note {
    "" -> []
    words -> [
      html.p([attribute.class("relayed-side-note")], [html.text(words)]),
    ]
  }

  html.section(
    [
      attribute.class("state-group"),
      attribute.class("relayed-side-group"),
      ..stale
    ],
    [
      html.h3([attribute.class("state-heading")], [
        html.text("On " <> section.orchestrator),
        ..case section.rows {
          [] -> []
          rows -> [
            html.span([attribute.class("group-count")], [
              html.text(int.to_string(list.length(rows))),
            ]),
          ]
        }
      ]),
      ..list.append(note, [
        keyed.ul(
          [attribute.class("sessions")],
          list.map(section.rows, fn(row) {
            #(
              section.orchestrator <> ":" <> row.session,
              relayed_row(section.orchestrator, row, open),
            )
          }),
        ),
      ])
    ],
  )
}

/// One of an orchestrator's sessions: a button, since the relayed page can be
/// opened, holding the same dot and two lines a local row has. The tag's agent is
/// the orchestrator, and its code is where the session's tools run there, the
/// whole folder path a `title`. Every string is a text node.
fn relayed_row(
  orchestrator: String,
  row: Listed,
  open: fn(String, String) -> message,
) -> Element(message) {
  // Dispatch on relayed_row state.
  let code = case row.code {
    listing.Folder(path:) -> [attribute.title(path)]
    listing.Registered(..) | listing.Pooled(..) -> []
  }

  let words = relayed_words.activity_words(row.activity)

  html.li([attribute.class("session"), attribute.class("relayed-side-row")], [
    html.button(
      [
        attribute.type_("button"),
        attribute.class("session-open"),
        attribute.title("Open this session on " <> orchestrator),
        event.on_click(open(orchestrator, row.session)),
      ],
      [
        residency(#(["live", relayed_class(row.activity)], "●", words)),
        html.span([attribute.class("session-text")], [
          html.span([attribute.class("session-name")], [
            html.text(orchestrators.label(row)),
          ]),
          html.span([attribute.class("session-tag")], [
            html.span([attribute.class("tag-agent")], [html.text(orchestrator)]),
            html.span(
              [attribute.class("tag-arrow"), attribute.aria_hidden(True)],
              [html.text(" → ")],
            ),
            html.span([attribute.class("tag-code"), ..code], [
              html.text(listing.code_words(row.code)),
            ]),
          ]),
        ]),
      ],
    ),
  ])
}

/// The class that colours a relayed row's dot: the same three as a local row's.
fn relayed_class(activity: relayed_words.Activity) -> String {
  case activity {
    relayed_words.NeedsYou -> "needs-you"
    relayed_words.Working -> "working"
    relayed_words.Idle -> "idle"
  }
}

// The activity a suffix carries, whichever page it is for.
fn activity_of(suffix: Suffix) -> Dict(String, Activity) {
  case suffix {
    Doing(activity) -> activity
    Known(activity) -> activity
  }
}

/// The column's head: the product's name beside the serving daemon's, so a
/// person with two pages open can tell them apart, and the "New session" button
/// where the page offers one.
fn top(page: Page(message)) -> Element(message) {
  // Dispatch on top state.
  let new = case page.starting {
    Some(press) -> [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("new-session"),
          event.on_click(press),
        ],
        [
          html.span([attribute.aria_hidden(True)], [html.text("+")]),
          html.text("New session"),
        ],
      ),
    ]
    None -> []
  }

  html.div([attribute.class("side-top")], [
    html.p([attribute.class("brand")], [
      html.span([], [html.text("Loom")]),
      html.span(
        [
          attribute.class("here"),
          attribute.title("The daemon serving this page"),
        ],
        [
          html.span(
            [attribute.class("dot-ok"), attribute.aria_hidden(True)],
            [],
          ),
          html.text(page.machine),
        ],
      ),
    ]),
    ..new
  ])
}

/// The machine pills, in a group named for what they do. With no pill to offer
/// there is nothing to draw, and a row of one choice would only be noise.
fn pills(all: List(Entry), page: Page(message)) -> Element(message) {
  case listing.pills(all, page.machine) {
    [] -> element.none()
    offered ->
      html.div(
        [
          attribute.class("filters"),
          attribute.role("group"),
          attribute.aria_label("Show sessions on"),
        ],
        [
          pill(
            "All",
            list.length(all),
            mark(page.filter, listing.Everywhere),
            page.widening,
          ),
          ..list.map(offered, fn(each) {
            pill(
              each.machine,
              each.count,
              mark(page.filter, listing.On(each.machine)),
              page.narrowing(each.machine),
            )
          })
        ],
      )
  }
}

// The words of a pill's `aria-pressed`.
fn pressed(mark: Mark) -> String {
  case mark {
    Chosen -> "true"
    Offered -> "false"
  }
}

// The mark of the pill that stands for `pill`, given the filter the list is under.
fn mark(filter: Filter, pill: Filter) -> Mark {
  case filter == pill {
    True -> Chosen
    False -> Offered
  }
}

/// One pill: a real button that says whether it is the chosen one, with the
/// count of sessions it shows after its label.
fn pill(
  label: String,
  count: Int,
  mark: Mark,
  press: message,
) -> Element(message) {
  html.button(
    [
      attribute.type_("button"),
      attribute.class("fp"),
      attribute.aria_pressed(pressed(mark)),
      event.on_click(press),
    ],
    [
      html.text(label),
      html.span([attribute.class("fp-count")], [html.text(int.to_string(count))]),
    ],
  )
}

/// One group of running rows: a heading with the count, then the rows. A group
/// with no row is nothing, so a person who has nothing waiting sees no empty
/// "Needs you".
fn state(
  title: String,
  class: String,
  rows: List(Row),
  draw: fn(Row) -> Element(message),
) -> Element(message) {
  case rows {
    [] -> element.none()
    [_, ..] ->
      html.section([attribute.class("state-group"), attribute.class(class)], [
        heading(title, rows),
        keyed_rows(rows, draw),
      ])
  }
}

/// The quiet running sessions: the newest few, and the rest behind a native
/// disclosure. The rows past the first few stay in the document either way, so
/// the switcher still lists them.
fn idle(rows: Rows, draw: fn(Row) -> Element(message)) -> Element(message) {
  case list.split(rows.idle, listing.idle_shown) {
    #([], _) -> element.none()
    #(shown, []) ->
      html.section(
        [attribute.class("state-group"), attribute.class("state-idle")],
        [
          heading("Idle", rows.idle),
          keyed_rows(shown, draw),
        ],
      )
    #(shown, more) ->
      html.section(
        [attribute.class("state-group"), attribute.class("state-idle")],
        [
          heading("Idle", rows.idle),
          keyed_rows(shown, draw),
          html.details([attribute.class("idle-more")], [
            html.summary([], [
              html.text("Show " <> int.to_string(list.length(more)) <> " more"),
            ]),
            keyed_rows(more, draw),
          ]),
        ],
      )
  }
}

/// A group's heading: its words and the number of rows it holds.
fn heading(title: String, rows: List(Row)) -> Element(message) {
  html.h3([attribute.class("state-heading")], [
    html.text(title),
    html.span([attribute.class("group-count")], [
      html.text(listing.count_words(rows)),
    ]),
  ])
}

/// The saved sessions: a quiet line that says how many there are, and under it
/// their rows. Both are always in the document, and the stylesheet hides the rows
/// until `<loom-saved>` reports that the person opened them, so the switcher,
/// which reads the sidebar's buttons, still finds a saved session while it is
/// hidden. The toggle carries the fixed `data-saved` mark and its `aria-expanded`,
/// which the element writes after this draws it closed. The count is a number,
/// the only text here.
fn saved_region(
  rows: List(Row),
  draw: fn(Row) -> Element(message),
) -> Element(message) {
  case rows {
    [] -> element.none()
    [_, ..] ->
      html.div([attribute.class("saved-region")], [
        element.element("loom-saved", [], [
          html.button(
            [
              attribute.type_("button"),
              attribute.class("saved-toggle"),
              attribute.attribute("data-saved", "toggle"),
              attribute.attribute("aria-expanded", "false"),
              attribute.title("Show or hide the saved sessions"),
            ],
            [html.text(toggle_words(rows))],
          ),
        ]),
        html.div([attribute.class("saved-panel")], [
          keyed_rows(rows, draw),
        ]),
      ])
  }
}

/// The words on the toggle. A blocked row is one nothing runs and a page cannot
/// open, and its own row says "needs attention", so the count names it that way
/// and "saved" counts only the sessions that can be resumed.
fn toggle_words(rows: List(Row)) -> String {
  let blocked =
    list.count(rows, fn(row) {
      case row.entry.residency {
        Blocked | FailedStart(_) -> True
        Live | Saved | Moving(_) -> False
      }
    })
  let saved = list.length(rows) - blocked

  // Dispatch on toggle_words state.
  case saved, blocked {
    _, 0 -> int.to_string(saved) <> " saved"
    0, _ -> int.to_string(blocked) <> " needs attention"
    _, _ ->
      int.to_string(saved)
      <> " saved · "
      <> int.to_string(blocked)
      <> " needs attention"
  }
}

/// The column's foot: the admin page where the page may open it, and who the
/// page is for. Both are the page's own values, drawn as text.
fn foot(page: Page(message)) -> Element(message) {
  // Dispatch on foot state.
  let admin = case page.administering {
    Some(press) -> [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("foot-admin"),
          event.on_click(press),
        ],
        [html.text("Admin")],
      ),
    ]
    None -> []
  }

  // Dispatch on foot state.
  let who = case page.who {
    "" -> []
    name -> [html.span([attribute.class("foot-who")], [html.text(name)])]
  }

  // Dispatch on foot state.
  case list.append(admin, who) {
    [] -> element.none()
    parts -> html.div([attribute.class("side-foot")], parts)
  }
}

/// One row. The session on screen is marked and is text. Another session that a
/// process runs is a button, since a page for it can be opened. A saved session
/// is what `view/resume` says: a button on a page that may ask the daemon to
/// resume it, the words "opening" while its resume is out, and text otherwise,
/// including for a session the daemon will not resume from a page. The second
/// line is the tag: the machine the agent runs on, an arrow, and where the code
/// lives, with the code's whole path as a `title`. A page that offers archiving
/// adds a small menu after the row's own button, and a row that is asking whether
/// to archive is that question and nothing else; the session on screen has no
/// menu, so it gives its reason as a `title`.
fn entry(
  row: Row,
  current: String,
  suffix: Suffix,
  page: Page(message),
  open: fn(String) -> message,
  resume: Resume(message),
  archiving: Archiving(message),
) -> Element(message) {
  let entry = row.entry
  let kind = resume.kind(resume, entry)
  let words = row_words(entry, kind, suffix)
  let lead = lead(row)
  let residency = residency(words)
  let parts = [residency, lead]

  // Render question, active row, or session button according to residency.
  case
    archiving.question(archiving, entry, turn(entry, suffix)),
    entry.id == current,
    entry.residency
  {
    // The row is asking whether to archive, so its words give way to the
    // question. The session on screen never asks: it has no archive action.
    Some(question), False, _ ->
      html.li([attribute.class("session"), attribute.class("confirming")], [
        question,
      ])

    _, True, _ ->
      html.li(
        [
          attribute.class("session"),
          attribute.class("current"),
          attribute.attribute("aria-current", "true"),
          ..archiving.current_title(archiving)
        ],
        parts,
      )

    _, False, Live if page.doors == RowsShown ->
      html.li(
        [attribute.class("session")],
        list.append(parts, [menu(archiving, entry, page)]),
      )

    _, False, Live ->
      html.li([attribute.class("session")], [
        html.button(
          [
            attribute.type_("button"),
            attribute.class("session-open"),
            attribute.title("Open this session"),
            event.on_click(open(entry.id)),
          ],
          parts,
        ),
        menu(archiving, entry, page),
      ])

    _, False, Saved
    | _, False, Blocked
    | _, False, FailedStart(_)
    | _, False, Moving(_)
    ->
      case kind {
        resume.Button(press:) ->
          html.li([attribute.class("session")], [
            html.button(
              [
                attribute.type_("button"),
                attribute.class("session-open"),
                attribute.title("Resume this session"),
                event.on_click(press),
              ],
              parts,
            ),
            menu(archiving, entry, page),
          ])
        resume.Text | resume.Opening ->
          html.li(
            [attribute.class("session")],
            list.append(parts, [menu(archiving, entry, page)]),
          )
      }
  }
}

/// The row's two lines: the name, and the tag under it. The name is the
/// catalogue's label as a text node, and the tag is the place's two halves as
/// text nodes, the code's whole path a `title`.
fn lead(row: Row) -> Element(message) {
  let entry = row.entry

  // Dispatch on lead state.
  let code = case row.place.code {
    listing.Folder(path:) -> [attribute.title(path)]
    listing.Registered(..) | listing.Pooled(..) -> []
  }

  html.span([attribute.class("session-text")], [
    html.span([attribute.class("session-name")], [
      html.text(sessions.label(entry)),
    ]),
    html.span([attribute.class("session-tag")], [
      html.span([attribute.class("tag-agent")], [html.text(row.place.agent)]),
      html.span([attribute.class("tag-arrow"), attribute.aria_hidden(True)], [
        html.text(" → "),
      ]),
      html.span([attribute.class("tag-code"), ..code], [
        html.text(listing.entry_words(entry, row.place)),
      ]),
    ]),
    ..subtitle(entry)
  ])
}

/// The first line of the session's first prompt, as a third quiet line when the
/// catalogue has one (protocol-change/067). It is a person's own words, so it is
/// a text node and nothing else: never an attribute, a class, a key or a title.
fn subtitle(entry: Entry) -> List(Element(message)) {
  case entry.subtitle {
    Some(words) -> [
      html.span([attribute.class("session-subtitle")], [html.text(words)]),
    ]
    None -> []
  }
}

/// The row's small menu: what the page offers for the row, behind a native
/// disclosure so it needs no handler. A row with nothing to offer has none, so
/// an observer's list carries no dots.
fn menu(
  archiving: Archiving(message),
  entry: Entry,
  page: Page(message),
) -> Element(message) {
  // Dispatch on menu state.
  let manage = case page.managing {
    Some(press) -> [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("row-manage"),
          event.on_click(press),
        ],
        [html.text("Rename, move or delete")],
      ),
    ]
    None -> []
  }

  // Dispatch on menu state.
  case list.append(archiving.button(archiving, entry), manage) {
    [] -> element.none()
    items ->
      html.details([attribute.class("row-menu")], [
        html.summary(
          [
            attribute.class("row-menu-toggle"),
            attribute.aria_label("More actions"),
          ],
          [html.text("⋯")],
        ),
        html.div([attribute.class("row-menu-body")], items),
      ])
  }
}

/// The dot and the word of a row: the classes that colour it, the glyph, and the
/// words an assistive technology reads in place of the colour.
fn residency(words: #(List(String), String, String)) -> Element(message) {
  html.span(
    [attribute.class("residency"), ..list.map(words.0, attribute.class)],
    [
      html.span([attribute.class("glyph"), attribute.aria_hidden(True)], [
        html.text(words.1),
      ]),
      html.span([attribute.class("residency-word")], [html.text(words.2)]),
    ],
  )
}

/// What a row's dot says: a running session by what it is doing, a saved one by
/// why it cannot be opened, and a resume that is out as "opening".
fn row_words(
  entry: Entry,
  kind: resume.Kind(message),
  suffix: Suffix,
) -> #(List(String), String, String) {
  case entry.residency, kind {
    Live, _ -> running(entry, suffix)
    Saved, resume.Opening -> #(["opening"], "…", "opening")
    Saved, _ -> #(["saved"], "○", "saved")

    // A row nothing runs and a page cannot open says so, in the words the home
    // table uses for it, rather than passing for a saved session that resumes.
    Blocked, _ -> #(["saved", "notable"], "○", "needs attention")
    FailedStart(_), _ -> #(["saved", "notable"], "○", "failed to start")

    // A session being handed to another orchestrator says where it goes. The
    // destination is the operator's own configuration, drawn as a text node.
    Moving(to), _ -> #(["saved", "notable"], "○", "moving to " <> to)
  }
}

/// Whether the row's session is inside a turn, by the activity read: working and
/// needing its operator are, and idle or unnamed is not. It only picks the
/// sentence of the archive question, and the stop itself is the server's.
fn turn(entry: Entry, suffix: Suffix) -> archiving.Turn {
  let known = dict.get(activity_of(suffix), entry.id)

  // Dispatch on turn state.
  case entry.residency, known {
    Live, Ok(Working) | Live, Ok(NeedsYou) -> archiving.MidTurn
    _, _ -> archiving.AtRest
  }
}

/// A running session's classes, glyph and word. On the home the word is the
/// activity read's answer, and a session the read has not named has none.
fn running(entry: Entry, suffix: Suffix) -> #(List(String), String, String) {
  case suffix {
    Doing(activity) ->
      case dict.get(activity, entry.id) {
        Ok(doing) -> doing_row(doing)
        Error(Nil) -> #(["live"], "●", "")
      }
    Known(activity) ->
      case dict.get(activity, entry.id) {
        Ok(doing) -> doing_row(doing)
        Error(Nil) -> #(["live"], "●", "running")
      }
  }
}

// The classes, glyph and word of a running session whose activity is known. The
// class names the dot's colour and motion in the stylesheet: working pulses in
// the accent, idle is quiet and still, needs-you is the signal hue, and failed
// is the danger hue and still, since nothing waits on the operator.
fn doing_row(doing: Activity) -> #(List(String), String, String) {
  #(["live", activity_class(doing)], "●", sessions.activity_words(doing))
}

/// Activity class helper.
fn activity_class(doing: Activity) -> String {
  case doing {
    NeedsYou -> "needs-you"
    sessions.Failed -> "failed"
    Working -> "working"
    Idle -> "idle"
  }
}

/// A group's rows, keyed by the session's identity. Each row carries handlers, and a
/// handler is named by its path, which is its key when it has one and its index
/// when it has not. The groups regroup as sessions change what they are doing, so an
/// unkeyed list would send a press that was in flight to whichever row had moved into
/// its place; keyed, it reaches the same session or nothing (`docs/lustre.md`).
/// An identity is the catalogue's canonical one and holds no separator.
fn keyed_rows(
  rows: List(Row),
  draw: fn(Row) -> Element(message),
) -> Element(message) {
  keyed.ul(
    [attribute.class("sessions")],
    list.map(rows, fn(row) { #(row.entry.id, draw(row)) }),
  )
}
