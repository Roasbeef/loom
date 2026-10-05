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
//// words, `resident · working · created 2h ago` for a session a process runs
//// and `saved · 2h ago` for one on disk. The glyph is decoration; the words
//// carry every difference, so none rests on a colour. A resident session's
//// activity word is the daemon's own read (`sessions.Activity`), asked off the
//// page's runtime and handed over as a state word; a session the read has not
//// answered for shows only that it is resident.
////
//// A running session's row is a button (protocol-change/065, the second pull
//// request) whose one handler sends the caller's message naming that row's
//// session; the stylesheet stretches it over the whole row, tints the row on
//// hover and draws a chevron at its right edge, so the row reads as one
//// target. A saved session's row is a button only on a page that may resume it
//// (`view/resume`, protocol-change/065, the third pull request), and text
//// otherwise; while a resume is out its row says "opening". The message names
//// the catalogue's identity, drawn when the tree was, and never a value the
//// browser sends: the home's socket admits a click only beneath this view's
//// own path (`home.table_path`), and the daemon checks the principal's
//// membership again before it mints a ticket.
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

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/renames.{type Control}
import web_view/sessions.{
  type Activity, type Entry, type Group, Blocked, Idle, Live, NeedsYou, Saved,
  Working,
}
import web_view/view/create.{type Create}
import web_view/view/heading
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
/// the key, and so is the control's state. `offer` is what the page offers for
/// making a session (`view/create`): under each workspace's heading a button, and
/// below it the form when that workspace's is open. Its state is in the key, so a
/// group changes when its form opens, closes or starts waiting.
///
/// ## Examples
///
/// ```gleam
/// // home_table.view(home.groups(model), dict.new(), now, Opening, resume.Never, Never, create.Never)
/// ```
pub fn view(
  groups: List(Group),
  activity: Dict(String, Activity),
  now: Int,
  open: fn(String) -> message,
  resume: Resume(message),
  rename: Rename(message),
  offer: Create(message),
) -> Element(message) {
  use <- element.memo([
    element.ref(groups),
    element.ref(activity),
    element.ref(now),
    element.ref(resume.pending(resume)),
    element.ref(open_form(rename)),
    element.ref(create.state(offer)),
  ])
  html.section([attribute.class("home-sessions")], [
    html.h2([attribute.class("home-heading")], [html.text("Sessions")]),
    ..case groups {
      [] -> [
        html.p([attribute.class("home-empty")], [
          html.text(
            "You hold no sessions yet. A session you start or are invited to appears here.",
          ),
        ]),
      ]
      [_, ..] ->
        list.map(groups, group(_, activity, now, open, resume, rename, offer))
    }
  ])
}

// One workspace: its heading and the list of its sessions.
fn group(
  group: Group,
  activity: Dict(String, Activity),
  now: Int,
  open: fn(String) -> message,
  resume: Resume(message),
  rename: Rename(message),
  offer: Create(message),
) -> Element(message) {
  html.section([attribute.class("home-group")], [
    html.div([attribute.class("home-group-head")], [
      html.h3(
        [attribute.class("home-workspace"), attribute.title(group.workspace)],
        [
          html.text(heading.shorten_path(group.workspace)),
          html.span([attribute.class("home-count")], [
            html.text(int.to_string(list.length(group.entries))),
          ]),
        ],
      ),
      create.button(offer, group.workspace),
    ]),
    create.form(offer, group.workspace),
    html.ul(
      [attribute.class("home-list")],
      list.map(group.entries, fn(entry) {
        row(entry, dict.get(activity, entry.id), now, open, resume, rename)
      }),
    ),
  ])
}

// What a row says about its session's process: the class that hues its glyph,
// the glyph, the word for where the session lives, and the activity word once
// the daemon has said one. The activity is kept apart from the state because the
// quiet line draws it in a span of its own, which is the only part of the line
// a needs-you row tints.
type Standing {
  Standing(
    class: String,
    glyph: String,
    state: String,
    activity: Option(String),
  )
}

// A running session is "resident" and, once the daemon has said, what it is
// doing; a session on disk is "saved", and one whose open is out "opening".
fn standing(
  entry: Entry,
  activity: Result(Activity, Nil),
  kind: resume.Kind(message),
) -> Standing {
  case entry.residency, kind {
    Live, _ ->
      case activity {
        Ok(doing) ->
          Standing(
            activity_class(doing),
            "●",
            "resident",
            Some(sessions.activity_words(doing)),
          )
        Error(Nil) -> Standing("live", "●", "resident", None)
      }
    Saved, resume.Opening -> Standing("opening", "…", "opening", None)
    Saved, _ | Blocked, _ -> Standing("saved", "○", "saved", None)
  }
}

// The class a glyph's hue and motion follow, a complete literal.
fn activity_class(activity: Activity) -> String {
  case activity {
    NeedsYou -> "needs-you"
    Working -> "working"
    Idle -> "idle"
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
// a page that may rename, a second button follows it, after the item so that the
// item's own path is the same on every page; the row whose form is open is the
// form and nothing else.
fn row(
  entry: Entry,
  activity: Result(Activity, Nil),
  now: Int,
  open: fn(String) -> message,
  resume: Resume(message),
  rename: Rename(message),
) -> Element(message) {
  let kind = resume.kind(resume, entry)
  let standing = standing(entry, activity, kind)
  let body = [
    html.span([attribute.class("home-glyph"), attribute.aria_hidden(True)], [
      html.text(standing.glyph),
    ]),
    html.span([attribute.class("home-text")], [
      html.span([attribute.class("home-name")], [
        html.text(sessions.label(entry)),
      ]),
      html.span([attribute.class("home-sub")], quiet_line(standing, entry, now)),
    ]),
  ]
  let item = case entry.residency, kind {
    Live, _ -> pressable("Open this session", open(entry.id), body)
    Saved, resume.Button(press:) ->
      pressable("Resume this session", press, body)
    Saved, _ | Blocked, _ -> html.div([attribute.class("home-item")], body)
  }
  case rename {
    Never ->
      html.li([attribute.class("home-row"), attribute.class(standing.class)], [
        item,
      ])
    Offered(open: Some(Open(session:, control:)), cancel:, submit:, ..)
      if session == entry.id
    ->
      html.li(
        [
          attribute.class("home-row"),
          attribute.class(standing.class),
          attribute.class("editing"),
        ],
        [editing(entry, control, cancel, submit(entry.id))],
      )
    Offered(edit:, ..) ->
      html.li(
        [
          attribute.class("home-row"),
          attribute.class(standing.class),
          attribute.class("renamable"),
        ],
        [
          item,
          html.button(
            [
              attribute.type_("button"),
              attribute.class("home-rename"),
              attribute.title("Rename this session"),
              event.on_click(edit(entry.id)),
            ],
            [html.text("Rename")],
          ),
        ],
      )
  }
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
      html.p([attribute.class("home-rename-lead")], [
        html.text("Rename "),
        html.span([attribute.attribute(rename_view.name_marker, "")], [
          html.text(sessions.label(entry)),
        ]),
      ]),
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
fn quiet_line(
  standing: Standing,
  entry: Entry,
  now: Int,
) -> List(Element(message)) {
  let lead = case standing.activity {
    Some(doing) -> [
      html.text(standing.state <> " · "),
      html.span([attribute.class("home-activity")], [html.text(doing)]),
    ]
    None -> [html.text(standing.state)]
  }
  case entry.subtitle {
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
    list.append(body, [
      html.span([attribute.class("home-chevron"), attribute.aria_hidden(True)], [
        html.text("›"),
      ]),
    ]),
  )
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
