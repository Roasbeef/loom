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
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/sessions.{
  type Activity, type Entry, type Group, Blocked, Idle, Live, NeedsYou, Saved,
  Working,
}
import web_view/view/create.{type Create}
import web_view/view/heading
import web_view/view/resume.{type Resume}

/// The centre column's content: a heading, and one list for each group, or a
/// line that says there is nothing to list. `activity` is what the daemon last
/// said each running session is doing, by identity, and `now` is the instant in
/// Unix milliseconds the ages are counted from. `open` is the message a press
/// of a running session's row sends, given that session's identity, and
/// `resume` is what the page offers for a saved session's row. The result is
/// memoized on the groups, the activity, the instant and the session whose
/// resume is out, so a refresh that brings back what is drawn diffs nothing;
/// `open` and the resume's `press` are not part of the key, so a caller passes
/// the same functions every time, as a constructor is. `offer` is what the page
/// offers for making a session (`view/create`): under each workspace's heading a
/// button, and below it the form when that workspace's is open. Its state is in
/// the key, so a group changes when its form opens, closes or starts waiting.
///
/// ## Examples
///
/// ```gleam
/// // home_table.view(home.groups(model), dict.new(), now, Opening, resume.Never, create.Never)
/// ```
pub fn view(
  groups: List(Group),
  activity: Dict(String, Activity),
  now: Int,
  open: fn(String) -> message,
  resume: Resume(message),
  offer: Create(message),
) -> Element(message) {
  use <- element.memo([
    element.ref(groups),
    element.ref(activity),
    element.ref(now),
    element.ref(resume.pending(resume)),
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
      [_, ..] -> list.map(groups, group(_, activity, now, open, resume, offer))
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
        row(entry, dict.get(activity, entry.id), now, open, resume)
      }),
    ),
  ])
}

// What a row says about its session's process: the class that hues its glyph,
// the glyph, and the words of the quiet line before the age.
type Standing {
  Standing(class: String, glyph: String, words: List(String))
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
          Standing(activity_class(doing), "●", [
            "resident",
            sessions.activity_words(doing),
          ])
        Error(Nil) -> Standing("live", "●", ["resident"])
      }
    Saved, resume.Opening -> Standing("opening", "…", ["opening"])
    Saved, _ | Blocked, _ -> Standing("saved", "○", ["saved"])
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

// One session's list item. The whole item is one button when a press can open
// it and one block of text when not, so the words read the same either way.
fn row(
  entry: Entry,
  activity: Result(Activity, Nil),
  now: Int,
  open: fn(String) -> message,
  resume: Resume(message),
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
  html.li([attribute.class("home-row"), attribute.class(standing.class)], [
    case entry.residency, kind {
      Live, _ -> pressable("Open this session", open(entry.id), body)
      Saved, resume.Button(press:) ->
        pressable("Resume this session", press, body)
      Saved, _ | Blocked, _ -> html.div([attribute.class("home-item")], body)
    },
  ])
}

// The quiet line under the name: the standing's words joined by a middle dot,
// then the age. A running session's age says it was created; a saved one's is
// the bare age, since "saved" already says what it is.
fn quiet_line(
  standing: Standing,
  entry: Entry,
  now: Int,
) -> List(Element(message)) {
  let lead = string.join(standing.words, " · ")
  let age = created(entry.created_at, sessions.ago(now, entry.created_at))
  case entry.residency {
    Live -> [html.text(lead <> " · created "), age]
    Saved | Blocked -> [html.text(lead <> " · "), age]
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
