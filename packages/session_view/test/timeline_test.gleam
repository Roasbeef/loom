//// The timeline cut closes spans at landmarks the records show, and no
//// decision looks ahead. The example tests pin what each landmark does. The
//// properties run the shipped `cut` over generated strands and hold it to the
//// laws the design rests on: every record lands in exactly one span, spans
//// are in order, a prefix's cards are a prefix of the whole's, and a record
//// the cut does not know changes nothing.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/usage_evidence
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import qcheck
import session_view/timeline.{Asked, Compacted, Prompted, Ran, Reported, Worked}

const sweep_seed = 20_261_124

// The integers from `from` to `to`, inclusive, oldest first.
fn upto(from: Int, to: Int) -> List(Int) {
  int.range(from:, to: to + 1, with: [], run: fn(found, n) { [n, ..found] })
  |> list.reverse
}

// A record before it is given a place in the strand.
type Body {
  Msg(message.AgentMessage)
  Compact(Int)
  Custom
}

fn id(seq: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), seq)).0
}

fn place(bodies: List(Body)) -> List(entry.Entry) {
  list.index_map(bodies, fn(body, index) {
    let seq = index + 1
    let at = seq * 1000

    case body {
      Msg(sent) -> entry.MessageEntry(id(seq), None, seq, at, sent, False)
      Compact(tokens) ->
        entry.CompactionEntry(
          id(seq),
          None,
          seq,
          at,
          "notes",
          [],
          tokens,
          False,
          None,
        )
      Custom -> entry.CustomEntry(id(seq), None, seq, at, "x", None)
    }
  })
}

fn prompt(text: String) -> Body {
  Msg(message.UserMessage([message.UserText(text, None)], 0, None))
}

fn peer() -> Body {
  Msg(message.UserMessage(
    [message.UserText("hello", None)],
    0,
    Some(message.PeerOrigin("s", "main")),
  ))
}

fn response(content: List(message.AssistantBlock)) -> Body {
  Msg(message.AssistantMessage(
    content,
    "test",
    "test",
    "test",
    None,
    None,
    None,
    message.Usage(
      0,
      0,
      0,
      0,
      None,
      None,
      0,
      message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
      usage_evidence.none(),
    ),
    message.Stop,
    None,
    None,
    None,
    None,
    0,
  ))
}

fn answer(text: String) -> Body {
  response([message.AssistantText(text, None)])
}

fn call(name: String, call_id: String, arguments: json.JsonValue) -> Body {
  response([
    message.AssistantToolCall(message.ToolCall(
      call_id,
      name,
      arguments,
      None,
      None,
    )),
  ])
}

fn finished(
  name: String,
  call_id: String,
  details: json.JsonValue,
  is_error: Bool,
) -> Body {
  Msg(message.ToolResultMessage(
    call_id,
    name,
    [message.ToolResultText("ok", None)],
    Some(details),
    None,
    None,
    is_error,
    0,
  ))
}

fn read_step(n: Int) -> List(Body) {
  let call_id = "r" <> int.to_string(n)

  [
    call("fs_read", call_id, json.Object([#("path", json.String("a.gleam"))])),
    finished("fs_read", call_id, json.Object([]), False),
  ]
}

fn edit_step(n: Int, path: String) -> List(Body) {
  let call_id = "e" <> int.to_string(n)
  let diff = json.String("@@ -1 +1,3 @@\n-old\n+new\n+more\n+most")

  [
    call("fs_edit", call_id, json.Object([#("path", json.String(path))])),
    finished(
      "fs_edit",
      call_id,
      json.Object([#("path", json.String(path)), #("diff", diff)]),
      False,
    ),
  ]
}

fn bash_step(n: Int, command: String, exit: Int) -> List(Body) {
  let call_id = "b" <> int.to_string(n)

  [
    call("bash", call_id, json.Object([#("command", json.String(command))])),
    finished(
      "bash",
      call_id,
      json.Object([#("exit_code", json.Int(exit))]),
      False,
    ),
  ]
}

fn kinds(cut: timeline.Cut) -> List(timeline.Kind) {
  list.map(cut.cards, fn(card) { card.kind })
}

// A prompt, three reads and an answer: the work closes at the answer, and the
// prompt and the answer are cards of their own.
pub fn a_turn_is_a_prompt_its_work_and_an_answer_test() {
  let records =
    place(
      list.flatten([
        [prompt("fix the replay")],
        read_step(1),
        read_step(2),
        read_step(3),
        [answer("done")],
      ]),
    )
  let cut = timeline.cut(records, 40)

  assert kinds(cut) == [Prompted, Worked, timeline.Answered]
  assert cut.open == None

  let assert [first, work, last] = cut.cards

  assert first.facts.excerpt == Some("fix the replay")
  assert work.facts.steps == 3
  assert work.facts.reads == 3
  assert last.facts.excerpt == Some("done")
  assert first.from_seq == 1 && first.to_seq == 1 && first.turn_seq == 1
  assert work.from_seq == 2 && work.to_seq == 7
}

// An edit followed by a command that exited zero closes the span as a command
// card carrying the reduced command, and the span names the file.
pub fn a_command_after_edits_closes_the_span_test() {
  let records =
    place(
      list.flatten([
        [prompt("go")],
        read_step(1),
        edit_step(2, "src/a.gleam"),
        bash_step(3, "cd p && make check-storage -j4", 0),
      ]),
    )
  let cut = timeline.cut(records, 40)

  assert kinds(cut) == [Prompted, Ran]

  let assert [_, ran] = cut.cards

  assert ran.facts.command == Some(timeline.Command("make check-storage", 0))
  assert ran.facts.files == [timeline.FileFact("src/a.gleam", 3, 1)]
  assert ran.facts.files_total == 1
}

// A failed command closes the span and counts as a failed call. A command of
// exit zero with no file written does not close it.
pub fn a_failed_command_closes_and_a_quiet_one_does_not_test() {
  let failed =
    place(
      list.flatten([
        read_step(1),
        read_step(2),
        bash_step(3, "make check", 2),
      ]),
    )
  let quiet =
    place(
      list.flatten([
        read_step(1),
        read_step(2),
        bash_step(3, "make check", 0),
      ]),
    )

  assert kinds(timeline.cut(failed, 40)) == [Ran]
  assert {
      timeline.cut(failed, 40).cards |> list.map(fn(c) { c.facts.failed })
    }
    == [1]
  assert kinds(timeline.cut(quiet, 40)) == []
}

// A command of too few steps joins the next span instead of closing.
pub fn a_landmark_of_too_few_steps_joins_the_next_span_test() {
  let records = place(bash_step(1, "make", 1))

  assert kinds(timeline.cut(records, 40)) == []
}

// The step limit closes a span, and an ask closes it at once.
pub fn the_step_limit_and_an_ask_close_a_span_test() {
  let limited = place(list.flatten(list.map(upto(1, 9), read_step)))
  let asked =
    place(
      list.flatten([
        read_step(1),
        [call("ask", "a1", json.Object([]))],
      ]),
    )

  assert kinds(timeline.cut(limited, 4)) == [Worked, Worked]
  assert kinds(timeline.cut(asked, 40)) == [Asked]
}

// A compaction is a card of its own and keeps its token count.
pub fn a_compaction_is_its_own_card_test() {
  let records =
    place(list.flatten([read_step(1), [Compact(9000)], read_step(2)]))
  let cut = timeline.cut(records, 40)

  assert kinds(cut) == [Worked, Compacted]
  assert cut.open != None

  let assert [_, compaction] = cut.cards

  assert compaction.facts.tokens_before == Some(9000)
}

// A sub-agent's result closes a span of three steps, and a peer's message is
// counted and not a prompt.
pub fn a_result_closes_and_a_peer_is_a_count_test() {
  let records =
    place(
      list.flatten([
        read_step(1),
        [peer()],
        read_step(2),
        [call("agent_wait", "w1", json.Object([]))],
        [finished("agent_wait", "w1", json.Object([]), False)],
      ]),
    )
  let cut = timeline.cut(records, 40)

  assert kinds(cut) == [Reported]

  let assert [card] = cut.cards

  assert card.facts.peers == 1
}

// A command is reduced to its executable and subcommand and never keeps a
// tail, so a header or a token in an argument is not kept.
pub fn a_command_is_reduced_to_executable_and_subcommand_test() {
  assert timeline.reduced("curl -H 'Authorization: Bearer x' https://a")
    == "curl"
  assert timeline.reduced("FOO=1 git commit -m msg") == "git commit"
  assert timeline.reduced("cd p && make check") == "make check"
  assert timeline.reduced("make ./build") == "make"
}

fn bodies_of(ops: List(Int)) -> List(Body) {
  list.index_map(ops, fn(op, index) { op_bodies(op, index) })
  |> list.flatten
}

fn op_bodies(op: Int, n: Int) -> List(Body) {
  case op {
    0 -> [prompt("p" <> int.to_string(n))]
    1 -> [answer("a" <> int.to_string(n))]
    2 -> read_step(n)
    3 -> edit_step(n, "f" <> int.to_string(n % 3))
    4 -> bash_step(n, "make", 0)
    5 -> bash_step(n, "make", 1)
    6 -> [Compact(n)]
    7 -> [call("ask", "k" <> int.to_string(n), json.Object([]))]
    8 -> [peer()]
    _ -> [Custom]
  }
}

fn generator() {
  qcheck.generic_list(
    elements_from: qcheck.bounded_int(from: 0, to: 9),
    length_from: qcheck.bounded_int(0, 60),
  )
}

fn config() {
  qcheck.default_config()
  |> qcheck.with_test_count(300)
  |> qcheck.with_seed(qcheck.seed(sweep_seed))
}

// Every record lands in exactly one span: the cards and the open span, in
// order, cover the sequences one through n with no gap and no overlap.
pub fn every_record_is_in_exactly_one_span_test() {
  qcheck.run(config(), generator(), fn(ops) {
    let records = place(bodies_of(ops))
    let cut = timeline.cut(records, 5)
    let spans = case cut.open {
      Some(open) -> list.append(cut.cards, [open])
      None -> cut.cards
    }
    let starts = list.map(spans, fn(card) { card.from_seq })
    let ends = list.map(spans, fn(card) { card.to_seq })

    assert list.all(spans, fn(card) { card.from_seq <= card.to_seq })
    assert list.drop(starts, 1)
      == list.map(ends, fn(end) { end + 1 })
      |> list.take(int.max(0, list.length(spans) - 1))

    case spans {
      [] -> {
        assert records == []
      }
      [first, ..] -> {
        assert first.from_seq == 1
        assert list.last(ends) == Ok(list.length(records))
      }
    }
  })
}

// The cards of any prefix of the records are a prefix of the cards of the
// whole: no later record changes a card that has closed.
pub fn the_cut_of_a_prefix_is_a_prefix_of_the_cut_test() {
  qcheck.run(config(), generator(), fn(ops) {
    let records = place(bodies_of(ops))
    let whole = timeline.cut(records, 5).cards

    upto(0, list.length(records))
    |> list.each(fn(size) {
      let part = timeline.cut(list.take(records, size), 5).cards

      assert list.take(whole, list.length(part)) == part
    })
  })
}

// A record the cut does not know joins the open span and changes no card.
pub fn an_unknown_record_changes_no_card_test() {
  qcheck.run(config(), generator(), fn(ops) {
    let bodies = bodies_of(ops)
    let plain = timeline.cut(place(bodies), 5).cards
    let extended = timeline.cut(place(list.append(bodies, [Custom])), 5).cards

    assert plain == extended
  })
}

// A command or a result closes a span of at least `least_steps` steps and
// never fewer, whatever the strand does.
pub fn landmark_cards_hold_enough_steps_test() {
  qcheck.run(config(), generator(), fn(ops) {
    let cut = timeline.cut(place(bodies_of(ops)), 5)

    assert list.all(cut.cards, fn(card) {
      case card.kind {
        Ran | Reported -> card.facts.steps >= timeline.least_steps
        Prompted | Worked | Asked | Compacted | timeline.Answered -> True
      }
    })
  })
}

// The strand stops closing landmark cards once it holds `card_cap` of them,
// and only a turn's own edges close after.
pub fn the_card_cap_stops_landmark_cards_test() {
  let many =
    upto(1, 600)
    |> list.flat_map(fn(n) {
      list.flatten([
        read_step(n * 10),
        read_step(n * 10 + 1),
        read_step(n * 10 + 2),
        bash_step(n * 10 + 3, "make", 1),
      ])
    })
  let cut = timeline.cut(place(many), 40)

  assert list.length(cut.cards) == timeline.card_cap
}
