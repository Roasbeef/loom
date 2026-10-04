//// The home page's centre: the principal's sessions as one table for each
//// workspace, with whether a process runs each and when it was created.
////
//// The sidebar beside it lists the same sessions in a row's width; this is
//// where there is room for the detail a sidebar row cannot hold. The groups
//// are `sessions.grouped`'s, so the workspaces and the sessions in them are in
//// the order the sidebar draws them. A session a process runs is marked
//// "resident" and a session on disk "saved", in words as well as a glyph, so
//// the difference does not rest on a colour.
////
//// A row is text. Nothing here has a handler, so a press means nothing and
//// the page's socket takes no browser frame at all; opening a session from the
//// home is a later change (protocol-change/065, the second pull request),
//// which will add a button to the row and nothing else.
////
//// Every name and path is the catalogue's, written by the owner and the host
//// and never by a session's agent, and is drawn as a text node. A workspace's
//// whole path is the table's caption. The creation time is the catalogue's
//// Unix milliseconds shown as UTC, built here from integers, so no value the
//// browser or a session supplied reaches a `datetime` attribute. The classes
//// are complete literals, so Tailwind finds them.
////
//// The module takes `sessions.Group`s and imports nothing from
//// `web_view/home`, which imports it.

import gleam/int
import gleam/list
import gleam/string
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import web_view/sessions.{type Entry, type Group, Live, Saved}

/// The centre column's content: a heading, and one table for each group, or
/// a line that says there is nothing to list. The result is memoized on the
/// groups, so a refresh that brings back the list already drawn diffs
/// nothing.
///
/// ## Examples
///
/// ```gleam
/// // home_table.view(home.groups(model))
/// ```
pub fn view(groups: List(Group)) -> Element(message) {
  use <- element.memo([element.ref(groups)])
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
      [_, ..] -> list.map(groups, group)
    }
  ])
}

fn group(group: Group) -> Element(message) {
  html.table([attribute.class("home-table")], [
    html.caption([attribute.class("home-workspace")], [
      html.text(group.workspace),
    ]),
    html.thead([], [
      html.tr([], [
        html.th([attribute.scope("col")], [html.text("Name")]),
        html.th([attribute.scope("col")], [html.text("State")]),
        html.th([attribute.scope("col")], [html.text("Created")]),
      ]),
    ]),
    html.tbody([], list.map(group.entries, row)),
  ])
}

fn row(entry: Entry) -> Element(message) {
  let residency = case entry.residency {
    Live -> #("live", "●", "resident")
    Saved -> #("saved", "○", "saved")
  }
  html.tr([], [
    html.td([attribute.class("home-name")], [html.text(sessions.label(entry))]),
    html.td([], [
      html.span([attribute.class("residency"), attribute.class(residency.0)], [
        html.span([attribute.class("glyph"), attribute.aria_hidden(True)], [
          html.text(residency.1),
        ]),
        html.text(residency.2),
      ]),
    ]),
    html.td([attribute.class("home-created")], [created(entry.created_at)]),
  ])
}

// The creation time as a `<time>` whose text and `datetime` are the same
// minute in UTC.
fn created(at: Int) -> Element(message) {
  let #(date, clock) = utc(at)
  html.time([attribute.attribute("datetime", date <> "T" <> clock <> "Z")], [
    html.text(date <> " " <> clock <> " UTC"),
  ])
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
