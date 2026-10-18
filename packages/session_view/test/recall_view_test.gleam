//// How a `history_search` call and its hits read: the summary row's query and
//// filters, the hit rows a result lists, and the total decoder that keeps a
//// malformed record from reaching either.

import core/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import session_view/notes_view
import session_view/recall_view.{Hit}

const session = "019a3c1e-5b7d-7c3e-9a10-2f4b6c8d0e1f"

const entry = "019a3c1e-aaaa-7bbb-8ccc-0123456789ab"

fn hit_json(snippet: String) -> json.JsonValue {
  json.Object([
    #("session", json.String(session)),
    #("entry", json.String(entry)),
    #("kind", json.String("assistant")),
    #("ts", json.Int(1_760_140_800_000)),
    #("snippet", json.String(snippet)),
  ])
}

fn details(hits: List(json.JsonValue)) -> json.JsonValue {
  json.Object([
    #("hits", json.Array(hits)),
    #("hit_count", json.Int(0)),
    #("scope", json.String("repository")),
    #("limit", json.Int(10)),
  ])
}

pub fn a_search_records_its_hits_in_order_test() {
  assert recall_view.hits(details([hit_json("one"), hit_json("two")]))
    == Some([
      Hit(session, entry, "assistant", 1_760_140_800_000, "one"),
      Hit(session, entry, "assistant", 1_760_140_800_000, "two"),
    ])
  assert recall_view.hits(details([])) == Some([])
}

pub fn an_old_index_row_has_no_kind_or_time_test() {
  let bare =
    json.Object([
      #("session", json.String(session)),
      #("entry", json.String(entry)),
      #("snippet", json.String("old")),
    ])
  assert recall_view.hits(details([bare]))
    == Some([Hit(session, entry, "", 0, "old")])
  assert recall_view.hit_rows(
      [Hit(session, entry, "", 0, "old")],
      notes_view.Complete,
    )
    == ["019a3c1e · 456789ab · unknown kind · unknown date · old"]
}

pub fn details_that_are_not_a_search_record_decode_to_nothing_test() {
  assert recall_view.hits(json.String("oops")) == None
  assert recall_view.hits(json.Object([])) == None
  assert recall_view.hits(json.Object([#("hits", json.Int(3))])) == None

  // One bad hit spoils the record, so a count is never smaller than the
  // tool's own.
  assert recall_view.hits(details([hit_json("fine"), json.String("bad")]))
    == None
  assert recall_view.hits(
      details([json.Object([#("session", json.String(session))])]),
    )
    == None
}

pub fn a_result_row_names_where_a_hit_came_from_test() {
  assert recall_view.hit_rows(
      [Hit(session, entry, "assistant", 1_760_140_800_000, "deploy the thing")],
      notes_view.Complete,
    )
    == ["019a3c1e · 456789ab · assistant · 2025-10-11 · deploy the thing"]
}

pub fn a_snippet_is_one_line_and_cut_when_long_test() {
  let rows =
    recall_view.hit_rows(
      [Hit(session, entry, "user", 1, "a\nb " <> string.repeat("x", 300))],
      notes_view.Excerpt,
    )
  let assert [row] = rows as "one hit, one row"
  assert string.contains(row, "a b xxx")
  assert string.ends_with(row, "…")
  assert !string.contains(row, "\n")
}

pub fn a_collapsed_result_keeps_three_hits_and_counts_the_rest_test() {
  let hits = [
    Hit(session, entry, "user", 1, "a"),
    Hit(session, entry, "user", 1, "b"),
    Hit(session, entry, "user", 1, "c"),
    Hit(session, entry, "user", 1, "d"),
    Hit(session, entry, "user", 1, "e"),
  ]
  let assert [_, _, _, more] = recall_view.hit_rows(hits, notes_view.Excerpt)
    as "three hits and the count of the rest"
  assert more == "… 2 more · Ctrl+g shows all"
  assert list.length(recall_view.hit_rows(hits, notes_view.Complete)) == 5
}

pub fn counts_read_as_a_reader_says_them_test() {
  assert recall_view.count_text(0) == "no hits"
  assert recall_view.count_text(1) == "1 hit"
  assert recall_view.count_text(7) == "7 hits"
}

pub fn an_entry_is_named_by_its_tail_not_its_timestamp_test() {
  assert recall_view.short_session(session) == "019a3c1e"
  assert recall_view.short_entry(entry) == "456789ab"
  assert recall_view.short_session("local") == "local"
  assert recall_view.short_entry("not-a-uuid") == "not-a-uuid"
}

pub fn the_summary_names_the_query_and_its_filters_test() {
  assert recall_view.call_summary(
      json.Object([
        #("query", json.String("deploy")),
        #("kind", json.String("assistant")),
        #("before", json.String(entry)),
        #("scope", json.String("session")),
      ]),
    )
    == Some(
      "history_search · \"deploy\" · kind assistant · before 456789ab · scope session",
    )
  assert recall_view.call_summary(json.Object([#("query", json.String("a b"))]))
    == Some("history_search · \"a b\"")
}

pub fn a_search_with_no_query_browses_recent_entries_test() {
  assert recall_view.call_summary(json.Object([]))
    == Some("history_search · recent entries")
  assert recall_view.call_summary(json.Object([#("query", json.String("  "))]))
    == Some("history_search · recent entries")
}

pub fn a_read_names_its_entry_and_its_neighbours_test() {
  assert recall_view.call_summary(
      json.Object([
        #("action", json.String("read")),
        #("session", json.String(session)),
        #("entry", json.String(entry)),
        #("around", json.Int(2)),
      ]),
    )
    == Some("history_search · read 019a3c1e · 456789ab · around 2")
}

pub fn arguments_that_name_nothing_usable_have_no_summary_test() {
  assert recall_view.call_summary(json.String("x")) == None
  assert recall_view.call_summary(
      json.Object([#("action", json.String("read"))]),
    )
    == None
  assert recall_view.call_summary(
      json.Object([#("action", json.String("delete"))]),
    )
    == None
}

pub fn a_long_query_is_cut_on_one_line_test() {
  let assert Some(summary) =
    recall_view.call_summary(
      json.Object([#("query", json.String("a\n" <> string.repeat("w", 200)))]),
    )
    as "a query is enough for a summary"
  assert string.ends_with(summary, "…\"")
  assert !string.contains(summary, "\n")
}

pub fn utc_dates_are_calendar_dates_test() {
  assert recall_view.utc_date(1_760_140_800_000) == "2025-10-11"
  assert recall_view.utc_date(1) == "1970-01-01"
  assert recall_view.utc_date(951_782_400_000) == "2000-02-29"
  assert recall_view.utc_date(1_709_164_800_000) == "2024-02-29"
  assert recall_view.utc_date(0) == "unknown date"
  assert recall_view.utc_date(-5) == "unknown date"
}
