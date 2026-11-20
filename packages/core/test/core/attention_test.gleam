//// The attention records' tests pin the stored shape, the total decoders, the
//// id and key conventions the writer and the readers share, and the pruning
//// rule. The round trip is checked on fixed values and, for an ask, over
//// generated ones from a fixed qcheck seed.

import core/attention.{
  Alternative, Anchor, Answer, Answered, Ask, AskOpen, Checklist, Closed,
  Confirm, Fill, Find, FindOpen, Header, Multiple, Plain, Question, Recommended,
}
import core/clock
import core/ids
import core/json
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import support/gen

const seed = 20_261_118

fn operation() -> ids.OpId {
  let #(id, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  id
}

fn header(id: String, routing: attention.Routing) -> attention.Header {
  Header(
    id:,
    created_at: 1_790_000_000_000,
    routing:,
    anchor: Anchor(operation: operation(), step_id: "step-1", source_index: 2),
    strand: "sub:main/audit-1a2b",
    parents: ["main"],
  )
}

fn questions() -> List(attention.Question) {
  [
    Question(key: "q1", prompt: "Retry the build?", kind: Confirm, options: []),
    Question(
      key: "q2",
      prompt: "Which branch?",
      kind: attention.Choice,
      options: [
        Alternative(
          label: "main",
          note: Some("Lands at once."),
          emphasis: Recommended,
        ),
        Alternative(label: "topic", note: None, emphasis: Plain),
      ],
    ),
    Question(
      key: "q3",
      prompt: "Which files?",
      kind: Multiple(min: 1, max: 2),
      options: [
        Alternative(label: "a.gleam", note: None, emphasis: Plain),
        Alternative(label: "b.gleam", note: None, emphasis: Plain),
      ],
    ),
    Question(
      key: "q4",
      prompt: "Where does it go?",
      kind: Fill(format: attention.FilePath),
      options: [],
    ),
  ]
}

fn open_ask() -> attention.Ask {
  Ask(
    header: header("ask-3f9c01a2b4", attention.ToOwner),
    why: Some("The build is red."),
    questions: questions(),
    state: AskOpen,
  )
}

fn answered_ask() -> attention.Ask {
  Ask(
    ..open_ask(),
    state: Answered(
      at: 1_790_000_100_000,
      answer: Answer(
        values: [
          #("q1", attention.Yes),
          #("q2", attention.Picked("topic")),
          #("q3", attention.PickedMany(["a.gleam", "b.gleam"])),
          #("q4", attention.Other("Do it in a branch instead.")),
        ],
        by: "owner",
      ),
    ),
  )
}

fn open_find() -> attention.Find {
  Find(
    header: header("find-0a1b2c3d4e", attention.ToOwner),
    kind: attention.Bug,
    text: "The retry loop never backs off.",
    path: Some("src/retry.gleam"),
    line: Some(41),
    state: FindOpen,
  )
}

pub fn an_open_ask_round_trips_test() {
  assert attention.decode_ask(attention.encode_ask(open_ask()))
    == Ok(open_ask())
}

pub fn an_answered_ask_round_trips_with_other_beside_its_null_test() {
  let stored = attention.encode_ask(answered_ask())
  assert attention.decode_ask(stored) == Ok(answered_ask())

  // The answer is the object the model reads: `null` where Other was used and
  // its text under `other`.
  let text = json.to_string(stored)
  assert string.contains(text, "\"q4\":null")
  assert string.contains(
    text,
    "\"other\":{\"q4\":\"Do it in a branch instead.\"}",
  )
}

pub fn a_strand_routed_ask_round_trips_test() {
  let ask =
    Ask(
      ..open_ask(),
      header: header("ask-0000000001", attention.ToStrand("main")),
    )
  assert attention.decode_ask(attention.encode_ask(ask)) == Ok(ask)
}

pub fn an_open_and_a_closed_find_round_trip_test() {
  assert attention.decode_find(attention.encode_find(open_find()))
    == Ok(open_find())
  let closed =
    Find(
      ..open_find(),
      path: None,
      line: None,
      state: Closed(at: 5, closure: attention.Filed, by: "owner"),
    )
  assert attention.decode_find(attention.encode_find(closed)) == Ok(closed)
}

pub fn every_find_kind_and_closure_round_trips_test() {
  list.each(
    [attention.Risk, attention.Idea, attention.Bug, attention.Wondering],
    fn(kind) {
      let find = Find(..open_find(), kind:)
      assert attention.decode_find(attention.encode_find(find)) == Ok(find)
      assert attention.parse_find_kind(attention.find_kind_name(kind))
        == Ok(kind)
    },
  )
  list.each(
    [attention.Fixed, attention.Filed, attention.Dismissed],
    fn(closure) {
      let find =
        Find(..open_find(), state: Closed(at: 9, closure:, by: "owner"))
      assert attention.decode_find(attention.encode_find(find)) == Ok(find)
    },
  )
}

pub fn a_generated_ask_round_trips_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(100)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(
    qcheck.tuple3(
      gen.small_string(),
      qcheck.bounded_int(0, 4),
      qcheck.bounded_int(0, 1_000_000),
    ),
    fn(drawn) {
      let #(text, kinds, entropy) = drawn
      let ask =
        Ask(
          header: header(attention.mint_ask_id(entropy), attention.ToOwner),
          why: Some(text),
          questions: list.index_map(
            list.take(questions(), kinds),
            fn(question, index) {
              Question(
                ..question,
                key: "q" <> int.to_string(index + 1),
                prompt: text,
              )
            },
          ),
          state: AskOpen,
        )
      assert attention.decode_ask(attention.encode_ask(ask)) == Ok(ask)
    },
  )
}

pub fn a_damaged_cell_decodes_to_an_error_test() {
  let assert Error(_) = attention.decode_ask(json.String("not an ask"))
  let assert Error(_) = attention.decode_ask(json.Object([]))
  let assert Error(_) = attention.decode_find(json.Null)

  // A find's cell is not an ask, whatever else it holds.
  let assert Error(_) = attention.decode_ask(attention.encode_find(open_find()))
  let assert Error(_) = attention.decode_find(attention.encode_ask(open_ask()))
}

pub fn a_record_with_an_unknown_kind_or_status_is_refused_test() {
  let assert json.Object(fields) = attention.encode_ask(open_ask())
  let with_status = fn(status) {
    json.Object(
      list.map(fields, fn(entry) {
        case entry.0 {
          "status" -> #("status", json.String(status))
          _ -> entry
        }
      }),
    )
  }
  assert attention.decode_ask(with_status("open")) == Ok(open_ask())
  let assert Error(_) = attention.decode_ask(with_status("closed"))
  let assert Error(_) = attention.decode_ask(with_status("pending"))

  // An answered ask has to carry its answer.
  let assert Error(_) = attention.decode_ask(with_status("answered"))
}

pub fn an_answer_to_a_question_the_ask_lacks_is_refused_test() {
  let assert json.Object(fields) = attention.encode_ask(answered_ask())
  let stray =
    json.Object(
      list.map(fields, fn(entry) {
        case entry.0 {
          "answer" -> #(
            "answer",
            json.Object([
              #("answers", json.Object([#("q9", json.Bool(True))])),
              #("other", json.Object([])),
              #("by", json.String("owner")),
            ]),
          )
          _ -> entry
        }
      }),
    )
  let assert Error(_) = attention.decode_ask(stray)
}

pub fn a_checklist_answer_may_be_empty_test() {
  let ask =
    Ask(
      ..open_ask(),
      questions: [
        Question(
          key: "q1",
          prompt: "Which of these?",
          kind: Checklist,
          options: [
            Alternative(label: "a", note: None, emphasis: Plain),
            Alternative(label: "b", note: None, emphasis: Plain),
          ],
        ),
      ],
      state: Answered(
        at: 2,
        answer: Answer(values: [#("q1", attention.PickedMany([]))], by: "owner"),
      ),
    )
  assert attention.decode_ask(attention.encode_ask(ask)) == Ok(ask)
}

pub fn ids_are_minted_from_forty_bits_and_checked_by_shape_test() {
  assert attention.mint_ask_id(255) == "ask-00000000ff"
  assert attention.mint_find_id(255) == "find-00000000ff"

  // Only the low forty bits are kept.
  assert attention.mint_ask_id(0x1_0000_0000_01) == "ask-0000000001"
  assert attention.is_ask_id("ask-0123456789")
  assert attention.is_find_id("find-abcdef0123")
  assert !attention.is_ask_id("ask-0123456789a")
  assert !attention.is_ask_id("ask-0123456G89")
  assert !attention.is_ask_id("ask-0123456ABC")
  assert !attention.is_ask_id("find-0123456789")
  assert !attention.is_find_id("find-../../x")
}

pub fn keys_name_the_reserved_cells_and_the_guard_is_not_an_id_test() {
  assert attention.ask_key("ask-0123456789") == "attention/ask/ask-0123456789"
  assert attention.find_key("find-0123456789")
    == "attention/find/find-0123456789"
  assert attention.guard_key(attention.ask_prefix) == "attention/ask/guard"
  assert !attention.is_ask_id("guard")
}

pub fn fill_formats_name_no_secret_test() {
  assert attention.parse_format("text") == Ok(attention.ShortText)
  assert attention.parse_format("long_text") == Ok(attention.LongText)
  assert attention.parse_format("path") == Ok(attention.FilePath)
  assert attention.parse_format("number") == Ok(attention.Number)
  assert attention.parse_format("url") == Ok(attention.Url)
  assert attention.parse_format("password") == Error(Nil)
  assert attention.parse_format("secret") == Error(Nil)
}

const day = 86_400_000

pub fn settled_records_are_pruned_by_age_test() {
  let now = 20 * day
  let rows = [
    attention.Settled("ask-0000000003", 19 * day),
    attention.Settled("ask-0000000001", 5 * day),
    attention.Settled("ask-0000000002", 12 * day),
  ]

  // Seven days old or more goes, oldest first; the fresh one stays.
  assert attention.retired(rows, now:) == ["ask-0000000001", "ask-0000000002"]
}

pub fn settled_records_are_pruned_by_count_test() {
  let now = 1000
  let rows =
    numbers(203)
    |> list.map(fn(n) { attention.Settled("ask-" <> ten(n), n) })
  assert attention.retired(rows, now:)
    == ["ask-" <> ten(1), "ask-" <> ten(2), "ask-" <> ten(3)]
}

pub fn pruning_takes_whichever_removes_more_test() {
  // Two hundred and one fresh rows exceed the count by one, and one row is
  // old: the union is the longer prefix, which is the old row alone ahead of
  // the count's single oldest.
  let now = 30 * day
  let fresh =
    numbers(201)
    |> list.map(fn(n) { attention.Settled("ask-" <> ten(n), 29 * day + n) })
  let old = attention.Settled("ask-" <> ten(900), 1 * day)
  let removed = attention.retired([old, ..fresh], now:)
  assert removed == ["ask-" <> ten(900), "ask-" <> ten(1)]
}

pub fn nothing_is_pruned_when_all_are_fresh_and_few_test() {
  assert attention.retired([attention.Settled("ask-0000000001", 5)], now: 6)
    == []
  assert attention.retired([], now: 6) == []
}

fn ten(n: Int) -> String {
  string.pad_start(int.to_string(n), to: 10, with: "0")
}

fn numbers(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, index) { index + 1 })
}
