//// The session sidebar: the principal's sessions, grouped by workspace and
//// newest first, on the operator's page only.
////
//// The sidebar draws a list the daemon's catalogue supplied
//// (`web_view/sessions`) and decides nothing. A page is bound to one session
//// by its key, so opening another is a navigation to a new page
//// (protocol-change/051, the addendum on switching sessions), and the row of a
//// session that can be opened is a button whose one handler sends the
//// message its caller gave, naming that row's session. A row is a button only
//// where pressing it can work: a session that a process runs and that is not
//// the one on screen, or a saved one on a page that may resume it
//// (`view/resume`, protocol-change/065, the third pull request). The session
//// on screen is text, and so is a saved session elsewhere, so the sidebar
//// never offers a press the daemon would refuse or that would do nothing.
//// While a resume is out its row reads "opening" and every other saved row is
//// text. The session named by a button's message is the catalogue's
//// identity, drawn when the tree was, and never a value the browser sends.
////
//// The sidebar is the second child of the page's frame (`view/shell`),
//// between the top bar and the centre column, in the frame's `left` slot.
//// `component.sidebar_path` names its path, and the paths `component.older_path`
//// and `component.strip_path` name are those of regions after it, so it keeps
//// its place as `element.none()` when it is not drawn.
////
//// Each project is a section with its own label, the project's directory name
//// (`sessions.titles`) with its whole path as a `title`, which the stylesheet
//// draws as a small eyebrow above the group and separates from the next group by
//// a hairline. The list's own heading, "Sessions", is in the page for
//// assistive technology and is not drawn. A session in a git worktree says
//// which one in the quiet line under its name, with the worktree's path as that
//// name's `title`.
////
//// The sidebar lists the sessions a process runs. The saved ones sit after the
//// groups behind a quiet "N saved" line: the same groups, in a panel the
//// stylesheet hides until `<loom-saved>` (`web_client/saved`) opens it in the
//// browser. They stay in the document, so the session switcher, which reads the
//// sidebar's `.session-open` buttons, still lists them while they are folded,
//// and the session on screen is always listed above, saved or not. The line is
//// a button with no handler, so the sidebar's pinned path and the paths after
//// it are where they were.
////
//// Every name is drawn as a text node, and a workspace's whole path as a
//// `title` attribute that Lustre escapes. The catalogue's fields are written
//// by the owner and the host and never by a session's agent, but nothing here
//// is built from transcript text either way. The session on screen is marked
//// by `aria-current` and a class, and a session with no name is named by its
//// identity's first eight characters, as the heading names it. The classes
//// are complete literals, so Tailwind finds them.
////
//// The session on screen draws the same activity word and dot as every other
//// running row, but its state comes from the page's own lane (strand statuses
//// and pending approvals) and not from the periodic activity read, so it never
//// lags the session it names (`component.session_activity`). The strands'
//// own state is the Strands panel's to draw, not this column's.
////
//// Above the first group sits a `nav` slot for the app's navigation. A
//// session page leaves it `element.none()`, which still holds its place, so
//// the groups keep their positions whatever the slot holds.
////
//// The home page draws the same column through `home` (protocol-change/065):
//// a "Home" entry in the `nav` slot, marked as the page on screen, and a row
//// for every session. No row is the current one on the home, so each running
//// session's row is a button that sends the caller's message and each saved
//// session's is text. The column, the groups and the row's words are written
//// once, and the two pages differ only in the nav entry and which
//// session is current.
////
//// A row can also carry a quiet archive button, which `view/archiving` draws
//// beside the row's own button and the stylesheet shows on hover and on focus.
//// A press replaces the row with one question and sends nothing until it is
//// confirmed, and the session on screen explains in a `title` why it has none.
//// The page decides whether the action exists by what it passes, so a page
//// without the capability draws none of it.
////
//// The module takes `sessions.Group`s and the current identity, and imports
//// nothing from `web_view/component`, which imports it.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import web_view/sessions.{
  type Activity, type Entry, type Group, Blocked, Idle, Live, NeedsYou, Saved,
  Working,
}
import web_view/view/archiving.{type Archiving}
import web_view/view/resume.{type Resume}

/// What a running session's row says after its glyph.
type Suffix {
  /// The home's answer to the activity read, by session identity: "needs you",
  /// "working" or "idle" for a session the read named, and nothing for one it
  /// has not yet, so a row never says "running" in one column and "working" in
  /// another.
  Doing(Dict(String, Activity))

  /// The session page's answer to the same read: the word and dot the home
  /// draws for a session the read named, and "running" for one it has not yet,
  /// since the page has no other column to disagree with.
  Known(Dict(String, Activity))
}

/// The sidebar for `groups`, with the session named `current` marked, the
/// `activity` what the daemon last said each
/// running session is doing (the home's read, asked from a task; a session it
/// has not named says "running"), `open` the message a press of another
/// live session's row sends, given that session's identity, and `resume` what
/// the page offers for a saved session's row, and `archiving` what it offers
/// for archiving a row (`view/archiving`).
///
/// With no group it is `element.none()`, so a page whose daemon listed
/// nothing, or could not, draws no empty column. The result is memoized on
/// the groups, the identity, the activity and where the archive action
/// stands, so a page that re-read an unchanged
/// list diffs nothing. `open` and the resume's `press` are not part of the
/// memo's key, so a caller passes the same functions every time, as a
/// constructor is; the session whose resume is out is, so its row changes when
/// the resume starts and when it ends.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.view(component.session_groups(model), component.session_id(model), [], dict.new(), Opening, resume.Never, archiving.Never)
/// ```
pub fn view(
  groups: List(Group),
  current: String,
  activity: Dict(String, Activity),
  open: fn(String) -> message,
  resume: Resume(message),
  archiving: Archiving(message),
) -> Element(message) {
  use <- element.memo([
    element.ref(groups),
    element.ref(current),
    element.ref(activity),
    element.ref(resume.pending(resume)),
    element.ref(archiving.stage(archiving)),
  ])
  column(
    groups,
    element.none(),
    current,
    Known(activity),
    open,
    resume,
    archiving,
  )
}

/// The sidebar the home page draws (protocol-change/065): the same groups, with
/// a "Home" entry in the navigation slot marked as the page on screen. No row
/// names a session as current, so every running session's row is a button
/// whose message is `open` applied to that session's identity, and a saved
/// session's row is what `resume` says. The "Home" entry is text. Every handler is therefore
/// beneath the sidebar's own path (`home.sidebar_path`), which is the one place
/// the home's socket admits a click on this column.
///
/// A running session's row says what the page's `activity` read answered for it
/// ("needs you" in the signal hue, "working", "idle"), the word the home's list
/// says for the same session, and nothing while no answer has arrived. A saved
/// row says "saved", as it always did.
///
/// With no group it is `element.none()`, as `view` is. `open` and the
/// resume's `press` are not part of the memo's key, as in `view`; `archiving`'s
/// stage is.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.home(home.groups(model), dict.new(), Opening, resume.Never, archiving.Never)
/// ```
pub fn home(
  groups: List(Group),
  activity: Dict(String, Activity),
  open: fn(String) -> message,
  resume: Resume(message),
  archiving: Archiving(message),
) -> Element(message) {
  use <- element.memo([
    element.ref(groups),
    element.ref(activity),
    element.ref(resume.pending(resume)),
    element.ref(archiving.stage(archiving)),
  ])
  let lead =
    html.p(
      [
        attribute.class("sidebar-home"),
        attribute.attribute("aria-current", "page"),
      ],
      [house(), html.text("Home")],
    )
  column(groups, lead, "", Doing(activity), open, resume, archiving)
}

// The house glyph of the "Home" entry: a fixed outline, decoration only, drawn
// with the entry's own colour. It holds no text and no value from the page.
fn house() -> Element(message) {
  svg.svg(
    [
      attribute.class("nav-glyph"),
      attribute.attribute("viewBox", "0 0 16 16"),
      attribute.aria_hidden(True),
    ],
    [
      svg.path([
        attribute.attribute(
          "d",
          "M2 7.5 8 2.5l6 5M3.5 6.5v7h3.2v-4h2.6v4h3.2v-7",
        ),
      ]),
    ],
  )
}

// The column itself: its title, the navigation slot, one section per project
// that has a running session, and, when any session is saved, the quiet
// "N saved" line with the saved sessions behind it. The slot is always one
// child, so the groups sit at the same index on both pages. With no group at
// all it is nothing.
fn column(
  groups: List(Group),
  nav: Element(message),
  current: String,
  suffix: Suffix,
  open: fn(String) -> message,
  resume: Resume(message),
  archiving: Archiving(message),
) -> Element(message) {
  case groups {
    [] -> element.none()
    [_, ..] -> {
      // The headings are chosen across every project, saved or not, so a
      // project reads the same above the fold and below it.
      let titles = sessions.titles(groups)
      let #(running, saved) = partition(groups, current)
      let draw = group(_, titles, current, suffix, open, resume, archiving)
      html.aside(
        [
          attribute.class("sidebar"),
          attribute.aria_label("Sessions"),
          attribute.attribute("slot", "left"),
        ],
        [
          html.h2([attribute.class("sidebar-title")], [html.text("Sessions")]),
          nav,
          ..list.append(
            list.map(running, draw),
            saved_region(saved, list.map(saved, draw)),
          )
        ],
      )
    }
  }
}

// The groups split into the sessions the sidebar lists and the saved ones it
// keeps behind its toggle. A saved session that is the page on screen stays in
// the list, so the person always sees where they are. A project with nothing on
// one side has no group on it.
fn partition(
  groups: List(Group),
  current: String,
) -> #(List(Group), List(Group)) {
  let #(running, saved) =
    list.map(groups, fn(group) {
      let #(kept, away) =
        list.partition(group.entries, fn(entry) {
          entry.id == current || is_running(entry)
        })
      #(
        sessions.Group(..group, entries: kept),
        sessions.Group(..group, entries: away),
      )
    })
    |> list.unzip

  #(
    list.filter(running, fn(group) { group.entries != [] }),
    list.filter(saved, fn(group) { group.entries != [] }),
  )
}

fn is_running(entry: Entry) -> Bool {
  case entry.residency {
    Live -> True
    Saved | Blocked -> False
  }
}

// The saved sessions: a quiet line that says how many there are, and under it
// their groups. Both are always in the document, and the stylesheet hides the
// groups until `<loom-saved>` reports that the person opened them, so the
// switcher, which reads the sidebar's buttons, still finds a saved session
// while it is hidden. The toggle carries the fixed `data-saved` mark and its
// `aria-expanded`, which the element writes after this draws it closed. The
// count is a number, the only text here.
fn saved_region(
  groups: List(Group),
  sections: List(Element(message)),
) -> List(Element(message)) {
  case groups {
    [] -> []
    [_, ..] -> {
      let total =
        list.fold(groups, 0, fn(sum, group) { sum + list.length(group.entries) })
      [
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
              [html.text(int.to_string(total) <> " saved")],
            ),
          ]),
          html.div([attribute.class("saved-panel")], sections),
        ]),
      ]
    }
  }
}

fn group(
  group: Group,
  titles: Dict(String, String),
  current: String,
  suffix: Suffix,
  open: fn(String) -> message,
  resume: Resume(message),
  archiving: Archiving(message),
) -> Element(message) {
  let title = result.unwrap(dict.get(titles, group.project), group.project)

  html.section([attribute.class("workspace-group")], [
    html.h3([attribute.class("workspace"), attribute.title(group.project)], [
      html.text(title),
      html.span([attribute.class("group-count")], [
        html.text(int.to_string(list.length(group.entries))),
      ]),
    ]),
    html.ul(
      [attribute.class("sessions")],
      list.map(group.entries, entry(_, current, suffix, open, resume, archiving)),
    ),
  ])
}

// One row. The session on screen is marked and is text. Another session that
// a process runs is a button, since a page for it can be opened. A saved
// session is what `view/resume` says: a button on a page that may ask the
// daemon to resume it, the words "opening" while its resume is out, and text
// otherwise, including for a session the daemon will not resume from a page.
// A session with a subtitle draws it in a quiet line under its name
// (protocol-change/067), as a text node: the subtitle is a person's own prompt,
// so it is never an attribute, a class or a title. A session in a git worktree
// leads that line with the worktree's name. A row with neither is the two words
// it always was. A page that offers archiving adds a quiet button after the
// row's own button, which `view/archiving` draws, and a row that is asking
// whether to archive is that question and nothing else; the session on screen
// has no button, so it gives its reason as a `title`.
fn entry(
  entry: Entry,
  current: String,
  suffix: Suffix,
  open: fn(String) -> message,
  resume: Resume(message),
  archiving: Archiving(message),
) -> Element(message) {
  let kind = resume.kind(resume, entry)
  let residency = case entry.residency, kind {
    Live, _ -> running(entry, suffix)
    Saved, resume.Opening -> #(["opening"], "…", "opening")
    Saved, _ | Blocked, _ -> #(["saved"], "○", "saved")
  }
  let name =
    html.span([attribute.class("session-name")], [
      html.text(sessions.label(entry)),
    ])

  // The quiet line under the name: the worktree the session runs in, when it
  // is not the project's own checkout, then the subtitle. The worktree is its
  // directory name with the whole path as a `title`, which is the host's text
  // and never a session's. The subtitle is a text node and nothing else.
  let tree = case sessions.worktree(entry) {
    Some(directory) -> [
      html.span(
        [attribute.class("session-tree"), attribute.title(entry.workspace)],
        [html.text(directory)],
      ),
    ]
    None -> []
  }
  let quiet = case entry.subtitle, tree {
    Some(subtitle), [] -> [html.text(subtitle)]
    Some(subtitle), _ -> list.append(tree, [html.text(" · " <> subtitle)])
    None, _ -> tree
  }
  let lead = case quiet {
    [] -> name
    [_, ..] ->
      html.span([attribute.class("session-text")], [
        name,
        html.span([attribute.class("session-subtitle")], quiet),
      ])
  }
  let residency =
    html.span(
      [attribute.class("residency"), ..list.map(residency.0, attribute.class)],
      [
        html.span([attribute.class("glyph"), attribute.aria_hidden(True)], [
          html.text(residency.1),
        ]),
        html.text(residency.2),
      ],
    )
  let words = [lead, residency]

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
        [lead, residency],
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
          words,
        ),
        ..archiving.button(archiving, entry)
      ])

    _, False, Saved | _, False, Blocked ->
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
              words,
            ),
            ..archiving.button(archiving, entry)
          ])
        resume.Text | resume.Opening ->
          html.li(
            [attribute.class("session")],
            list.append(words, archiving.button(archiving, entry)),
          )
      }
  }
}

// Whether the row's session is inside a turn, by the activity read: working
// and needing its operator are, and idle or unnamed is not. It only picks the
// sentence of the archive question, and the stop itself is the server's.
fn turn(entry: Entry, suffix: Suffix) -> archiving.Turn {
  let known = case suffix {
    Doing(activity) -> dict.get(activity, entry.id)
    Known(activity) -> dict.get(activity, entry.id)
  }
  case entry.residency, known {
    Live, Ok(Working) | Live, Ok(NeedsYou) -> archiving.MidTurn
    _, _ -> archiving.AtRest
  }
}

// A running session's classes, glyph and word. On the home the word is the
// activity read's answer, and a session the read has not named has none.
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
// the accent, idle is quiet and still, needs-you is the signal hue, and
// failed is the danger hue and still, since nothing waits on the operator.
fn doing_row(doing: Activity) -> #(List(String), String, String) {
  #(["live", activity_class(doing)], "●", sessions.activity_words(doing))
}

fn activity_class(doing: Activity) -> String {
  case doing {
    NeedsYou -> "needs-you"
    sessions.Failed -> "failed"
    Working -> "working"
    Idle -> "idle"
  }
}
