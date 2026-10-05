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
//// Each workspace is a section with its own label, which the stylesheet draws
//// as a small eyebrow above the group and separates from the next group by a
//// hairline. The list's own heading, "Sessions", is in the page for
//// assistive technology and is not drawn.
////
//// Every name is drawn as a text node, and a workspace's whole path as a
//// `title` attribute that Lustre escapes. The catalogue's fields are written
//// by the owner and the host and never by a session's agent, but nothing here
//// is built from transcript text either way. The session on screen is marked
//// by `aria-current` and a class, and a session with no name is named by its
//// identity's first eight characters, as the heading names it. The classes
//// are complete literals, so Tailwind finds them.
////
//// The session on screen also carries one thin bar per live strand, in the
//// strand's hue, pulsing while the strand works. The bars are decoration
//// drawn from the strip the page already has (`bars`): no handler, no focus,
//// hidden from assistive technology, and drawn on the current row only, so a
//// page draws nothing about another session's strands.
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
//// once, and the two pages differ only in the nav entry, the strand bars and
//// which session is current.
////
//// The module takes `sessions.Group`s and the current identity, and imports
//// nothing from `web_view/component`, which imports it.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/svg
import lustre/event
import session_view/agent_view
import session_view/turns
import web_view/sessions.{
  type Activity, type Entry, type Group, Blocked, Live, NeedsYou, Saved,
}
import web_view/view/resume.{type Resume}
import web_view/view/strip

/// What a running session's row says after its glyph.
type Suffix {
  /// "resident", which is all a session page knows: it makes no activity read
  /// (protocol-change/050), so a second word would be a guess.
  Resident

  /// The home's answer to the activity read, by session identity: "needs you",
  /// "working" or "idle" for a session the read named, and nothing for one it
  /// has not yet, so a row never says "resident" in one column and "working" in
  /// another.
  Doing(Dict(String, Activity))
}

/// One live strand's bar on the current row: its hue and whether it is
/// working. It is reduced from the strip's chip, so the sidebar's memo is
/// keyed on what the sidebar draws and not on a ticking elapsed time.
pub type Bar {
  Bar(
    /// The strand's hue, from its position among the captured strands.
    hue: turns.Hue,
    /// Whether the bar pulses.
    pulse: Pulse,
  )
}

/// Whether a bar pulses.
pub type Pulse {
  /// The strand is working.
  Pulsing

  /// The strand is waiting, idle or has stopped: the bar is dim and still.
  Still
}

/// The bars for a strip: one per listed strand, then the advisor's, pulsing
/// for each strand that is working.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.view(groups, current, sidebar.bars(component.strip(model)), Opening)
/// ```
pub fn bars(strip: strip.Strip) -> List(Bar) {
  let chips = case strip.advisor {
    Some(advisor) -> list.append(strip.chips, [advisor])
    None -> strip.chips
  }

  list.map(chips, fn(chip) {
    Bar(hue: chip.hue, pulse: pulse(chip.line.status))
  })
}

fn pulse(status: agent_view.Status) -> Pulse {
  case status {
    agent_view.Working -> Pulsing
    agent_view.Waiting
    | agent_view.NeedsInput
    | agent_view.Finished
    | agent_view.Failed
    | agent_view.Halted
    | agent_view.Idle
    | agent_view.Unavailable -> Still
  }
}

/// The sidebar for `groups`, with the session named `current` marked, the
/// current session's strand `bars`, `open` the message a press of another
/// live session's row sends, given that session's identity, and `resume` what
/// the page offers for a saved session's row.
///
/// With no group it is `element.none()`, so a page whose daemon listed
/// nothing, or could not, draws no empty column. The result is memoized on
/// the groups, the identity and the bars, so a page that re-read an unchanged
/// list diffs nothing. `open` and the resume's `press` are not part of the
/// memo's key, so a caller passes the same functions every time, as a
/// constructor is; the session whose resume is out is, so its row changes when
/// the resume starts and when it ends.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.view(component.session_groups(model), component.session_id(model), [], Opening, resume.Never)
/// ```
pub fn view(
  groups: List(Group),
  current: String,
  bars: List(Bar),
  open: fn(String) -> message,
  resume: Resume(message),
) -> Element(message) {
  use <- element.memo([
    element.ref(groups),
    element.ref(current),
    element.ref(bars),
    element.ref(resume.pending(resume)),
  ])
  column(groups, element.none(), current, bars, Resident, open, resume)
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
/// resume's `press` are not part of the memo's key, as in `view`.
///
/// ## Examples
///
/// ```gleam
/// // sidebar.home(home.groups(model), dict.new(), Opening, resume.Never)
/// ```
pub fn home(
  groups: List(Group),
  activity: Dict(String, Activity),
  open: fn(String) -> message,
  resume: Resume(message),
) -> Element(message) {
  use <- element.memo([
    element.ref(groups),
    element.ref(activity),
    element.ref(resume.pending(resume)),
  ])
  let lead =
    html.p(
      [
        attribute.class("sidebar-home"),
        attribute.attribute("aria-current", "page"),
      ],
      [house(), html.text("Home")],
    )
  column(groups, lead, "", [], Doing(activity), open, resume)
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

// The column itself: its title, the navigation slot, and one section per
// group, or nothing when there is no group. The slot is always one child, so
// the groups sit at the same index on both pages.
fn column(
  groups: List(Group),
  nav: Element(message),
  current: String,
  bars: List(Bar),
  suffix: Suffix,
  open: fn(String) -> message,
  resume: Resume(message),
) -> Element(message) {
  case groups {
    [] -> element.none()
    [_, ..] ->
      html.aside(
        [
          attribute.class("sidebar"),
          attribute.aria_label("Sessions"),
          attribute.attribute("slot", "left"),
        ],
        [
          html.h2([attribute.class("sidebar-title")], [html.text("Sessions")]),
          nav,
          ..list.map(groups, group(_, current, bars, suffix, open, resume))
        ],
      )
  }
}

fn group(
  group: Group,
  current: String,
  bars: List(Bar),
  suffix: Suffix,
  open: fn(String) -> message,
  resume: Resume(message),
) -> Element(message) {
  html.section([attribute.class("workspace-group")], [
    html.h3([attribute.class("workspace"), attribute.title(group.workspace)], [
      html.text(basename(group.workspace)),
      html.span([attribute.class("group-count")], [
        html.text(int.to_string(list.length(group.entries))),
      ]),
    ]),
    html.ul(
      [attribute.class("sessions")],
      list.map(group.entries, entry(_, current, bars, suffix, open, resume)),
    ),
  ])
}

// One row. The session on screen is marked and is text. Another session that
// a process runs is a button, since a page for it can be opened. A saved
// session is what `view/resume` says: a button on a page that may ask the
// daemon to resume it, the words "opening" while its resume is out, and text
// otherwise, including for a session the daemon will not resume from a page.
// Only the session on screen draws strand bars, between its name and its
// residency. A session with a subtitle draws it in a quiet line under its name
// (protocol-change/067), as a text node: the subtitle is a person's own prompt,
// so it is never an attribute, a class or a title, and a row without one is
// the two words it always was.
fn entry(
  entry: Entry,
  current: String,
  bars: List(Bar),
  suffix: Suffix,
  open: fn(String) -> message,
  resume: Resume(message),
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
  let lead = case entry.subtitle {
    Some(subtitle) ->
      html.span([attribute.class("session-text")], [
        name,
        html.span([attribute.class("session-subtitle")], [html.text(subtitle)]),
      ])
    None -> name
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

  case entry.id == current, entry.residency {
    True, _ ->
      html.li(
        [
          attribute.class("session"),
          attribute.class("current"),
          attribute.attribute("aria-current", "true"),
        ],
        [lead, ..list.append(dots(bars), [residency])],
      )
    False, Live ->
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
      ])
    False, Saved | False, Blocked ->
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
          ])
        resume.Text | resume.Opening ->
          html.li([attribute.class("session")], words)
      }
  }
}

// A running session's classes, glyph and word. On the home the word is the
// activity read's answer, and a session the read has not named has none.
fn running(entry: Entry, suffix: Suffix) -> #(List(String), String, String) {
  case suffix {
    Resident -> #(["live"], "●", "resident")
    Doing(activity) ->
      case dict.get(activity, entry.id) {
        Ok(NeedsYou) -> #(
          ["live", "needs-you"],
          "●",
          sessions.activity_words(NeedsYou),
        )
        Ok(doing) -> #(["live"], "●", sessions.activity_words(doing))
        Error(Nil) -> #(["live"], "●", "")
      }
  }
}

// The bars' span, or nothing when no strand is listed. It is decoration:
// hidden from assistive technology, with no handler, so it cannot take focus
// or move a path.
fn dots(bars: List(Bar)) -> List(Element(message)) {
  case bars {
    [] -> []
    [_, ..] -> [
      html.span(
        [attribute.class("dots"), attribute.aria_hidden(True)],
        list.map(bars, bar),
      ),
    ]
  }
}

fn bar(bar: Bar) -> Element(message) {
  let classes = case bar.pulse {
    Pulsing -> [
      attribute.class("bar"),
      strip.hue_class(bar.hue),
      attribute.class("w"),
    ]
    Still -> [attribute.class("bar"), strip.hue_class(bar.hue)]
  }
  html.span(classes, [])
}

fn basename(path: String) -> String {
  string.split(path, "/")
  |> list.filter(fn(segment) { segment != "" })
  |> list.last
  |> result.unwrap(path)
}
