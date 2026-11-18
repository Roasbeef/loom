//// The page's decoder for a `sessions.attention` row (protocol-change/120). It
//// is total: whatever the daemon sent, it answers a row or no row, and a damaged
//// item costs only itself.

import core/attention
import core/attention_answer
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{None, Some}
import web_view/attention_feed.{Ask, Find, Row, Section, Stuck}
import web_view/composer

fn section(count: Int, items: List(JsonValue)) -> JsonValue {
  json.Object([#("count", json.Int(count)), #("items", json.Array(items))])
}

fn ask_item() -> JsonValue {
  json.Object([
    #("id", json.String("ask-3f9c01a2b4")),
    #("strand", json.String("main")),
    #("created_at", json.Int(10)),
    #("head", json.String("Which branch?")),
    #("questions", json.Int(2)),
  ])
}

fn row(fields: List(#(String, JsonValue))) -> JsonValue {
  json.Object(
    list.fold(
      fields,
      [
        #("state", json.String("ok")),
        #("asks", section(0, [])),
        #("finds", section(0, [])),
        #("stuck", section(0, [])),
      ],
      fn(base, entry) { list.key_set(base, entry.0, entry.1) },
    ),
  )
}

pub fn a_full_row_decodes_test() {
  let wire =
    json.Object([
      #("state", json.String("ok")),
      #("waiting_since", json.Int(10)),
      #("asks", section(2, [ask_item()])),
      #(
        "finds",
        section(1, [
          json.Object([
            #("id", json.String("find-77d0a1c9e2")),
            #("strand", json.String("sub:main/a")),
            #("kind", json.String("question")),
            #("created_at", json.Int(11)),
            #("head", json.String("Why?")),
            #("path", json.String("src/a.gleam")),
            #("line", json.Int(3)),
          ]),
        ]),
      ),
      #(
        "stuck",
        section(1, [json.Object([#("strand", json.String("sub:main/b"))])]),
      ),
    ])
  assert attention_feed.decode_row(wire)
    == Ok(Row(
      waiting_since: Some(10),
      asks: Section(2, [Ask("ask-3f9c01a2b4", "main", 10, "Which branch?", 2)]),
      finds: Section(1, [
        Find(
          "find-77d0a1c9e2",
          "sub:main/a",
          attention.Wondering,
          11,
          "Why?",
          Some("src/a.gleam"),
          Some(3),
        ),
      ]),
      stuck: Section(1, [Stuck("sub:main/b", None)]),
    ))
}

pub fn a_row_that_is_not_ok_is_no_row_test() {
  assert attention_feed.decode_row(
      json.Object([#("state", json.String("unknown"))]),
    )
    == Error(Nil)
  assert attention_feed.decode_row(json.Null) == Error(Nil)
  assert attention_feed.decode_row(json.Object([])) == Error(Nil)
  assert attention_feed.decode_row(row([#("state", json.String("later"))]))
    == Error(Nil)
}

pub fn a_damaged_section_makes_the_row_no_row_test() {
  assert attention_feed.decode_row(
      json.Object([
        #("state", json.String("ok")),
        #("asks", json.String("x")),
        #("finds", section(0, [])),
        #("stuck", section(0, [])),
      ]),
    )
    == Error(Nil)
  assert attention_feed.decode_row(
      json.Object([
        #("state", json.String("ok")),
        #("asks", json.Object([#("count", json.Int(-1))])),
        #("finds", section(0, [])),
        #("stuck", section(0, [])),
      ]),
    )
    == Error(Nil)
}

pub fn a_damaged_item_costs_only_itself_and_the_count_stays_honest_test() {
  let wire =
    json.Object([
      #("state", json.String("ok")),
      #("asks", section(1, [ask_item(), json.String("junk")])),
      #(
        "finds",
        section(5, [
          json.Object([
            #("id", json.String("find-0000000001")),
            #("strand", json.String("main")),
            #("kind", json.String("praise")),
            #("created_at", json.Int(1)),
            #("head", json.String("x")),
          ]),
        ]),
      ),
      #("stuck", section(0, [])),
    ])
  let assert Ok(decoded) = attention_feed.decode_row(wire) as "a row"
  assert list.length(decoded.asks.items) == 1

  // A count below its items is raised to them; a count above stays.
  assert decoded.asks.count == 1
  assert decoded.finds.count == 5
  assert decoded.finds.items == []
}

pub fn a_line_without_a_path_is_dropped_test() {
  let wire =
    row([
      #(
        "finds",
        section(1, [
          json.Object([
            #("id", json.String("find-0000000002")),
            #("strand", json.String("main")),
            #("kind", json.String("bug")),
            #("created_at", json.Int(1)),
            #("head", json.String("x")),
            #("line", json.Int(9)),
          ]),
        ]),
      ),
    ])
  let assert Ok(decoded) = attention_feed.decode_row(wire) as "a row"
  let assert [find] = decoded.finds.items
  assert find.path == None
  assert find.line == None
}

// The daemon checks an answer's whole prompt against the bound the home
// composer already enforces. `core` may not import the composer, so the number
// is stated in both places and this pins them together.
pub fn the_answer_prompt_bound_is_the_composers_test() {
  assert attention_answer.max_prompt_bytes == composer.prompt_limit
}
