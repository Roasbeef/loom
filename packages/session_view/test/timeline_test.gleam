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
import gleam/string
import qcheck
import session_view/composer
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
      exit != 0,
    ),
  ]
}

// A bash result whose error flag disagrees with its status, as another tool's
// or an old record's might.
fn bash_unflagged(n: Int, command: String, exit: Int) -> List(Body) {
  let call_id = "u" <> int.to_string(n)

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

fn wait_step(n: Int, details: json.JsonValue) -> List(Body) {
  let call_id = "w" <> int.to_string(n)

  [
    call("agent_wait", call_id, json.Object([])),
    finished("agent_wait", call_id, details, False),
  ]
}

fn spawn_step(n: Int, purpose: String) -> List(Body) {
  let call_id = "s" <> int.to_string(n)

  [
    call(
      "agent_spawn",
      call_id,
      json.Object([#("purpose", json.String(purpose))]),
    ),
    finished("agent_spawn", call_id, json.Object([]), False),
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
    9 -> wait_step(n, json.Object([#("pending", json.Bool(n % 2 == 0))]))
    10 -> spawn_step(n, "child")
    11 -> [
      finished("fs_read", "orphan" <> int.to_string(n), json.Object([]), False),
    ]
    12 -> list.append(read_step(n), edit_step(n + 1000, "g"))
    _ -> [Custom]
  }
}

fn generator() {
  qcheck.generic_list(
    elements_from: qcheck.bounded_int(from: 0, to: 13),
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

// A failed bash is one failed call whether its result carries the error flag, as
// the tool sets it, or only a nonzero status.
pub fn a_failed_command_counts_once_test() {
  let flagged =
    place(list.flatten([read_step(1), read_step(2), bash_step(3, "make", 2)]))
  let unflagged =
    place(
      list.flatten([read_step(1), read_step(2), bash_unflagged(3, "make", 2)]),
    )

  assert failed_of(timeline.cut(flagged, 40)) == [1]
  assert failed_of(timeline.cut(unflagged, 40)) == [1]
}

fn failed_of(cut: timeline.Cut) -> List(Int) {
  list.map(cut.cards, fn(card) { card.facts.failed })
}

// A sub-agent's result closes a span of three steps, and a wait that ran out its
// deadline with children still working does not.
pub fn a_pending_wait_is_not_a_result_test() {
  let ready =
    place(
      list.flatten([
        read_step(1),
        read_step(2),
        wait_step(3, json.Object([#("pending", json.Bool(False))])),
      ]),
    )
  let pending =
    place(
      list.flatten([
        read_step(1),
        read_step(2),
        wait_step(3, json.Object([#("pending", json.Bool(True))])),
      ]),
    )

  assert kinds(timeline.cut(ready, 40)) == [Reported]
  assert kinds(timeline.cut(pending, 40)) == []
}

// The memory context the daemon attaches to a run is not a prompt, so it starts
// no turn, and a sibling strand's message is a count like a peer's.
pub fn harness_messages_start_no_turn_test() {
  let memory =
    composer.memory_attribution_lead
    <> "sessions.\n\n```loom-memory\n- (fact) a\n```"
  let records = place([prompt(memory), prompt("a real question")])
  let cut = timeline.cut(records, 40)

  assert kinds(cut) == [Prompted]

  let assert [card] = cut.cards

  assert card.turn_seq == 2
  assert card.facts.excerpt == Some("a real question")
}

pub fn a_sibling_strands_message_is_a_count_test() {
  let sibling =
    Msg(message.UserMessage(
      [message.UserText("hi", None)],
      0,
      Some(message.StrandOrigin("sub")),
    ))
  let cut = timeline.cut(place([sibling]), 40)

  assert cut.cards == []
  assert option.map(cut.open, fn(card) { card.facts.peers }) == Some(1)
}

// A card names at most six files and three sub-agents, keeps a prompt to 160
// bytes at a character boundary, and keeps the end of a long path.
pub fn a_card_is_bounded_in_what_it_names_test() {
  let many_files =
    list.flatten(
      list.map(upto(1, 9), fn(n) { edit_step(n, "dir/f" <> int.to_string(n)) }),
    )
  let children =
    list.flatten(
      list.map(upto(1, 5), fn(n) { spawn_step(n, "child " <> int.to_string(n)) }),
    )
  let long = string.repeat("é", 200)
  let records =
    place(
      list.flatten([
        [prompt(long)],
        many_files,
        children,
        edit_step(20, string.repeat("d/", 400) <> "end.gleam"),
        bash_step(21, "make", 1),
      ]),
    )
  let cut = timeline.cut(records, 100)
  let assert [first, work] = cut.cards

  assert string.byte_size(option.unwrap(first.facts.excerpt, "")) <= 160
  assert string.ends_with(option.unwrap(first.facts.excerpt, ""), "…")
  assert list.length(work.facts.files) == 6
  assert work.facts.files_total == 10
  assert list.length(work.facts.spawned) == 3

  let assert Ok(path) = list.find(work.facts.files, fn(_) { True })
  assert string.byte_size(path.path) <= 400
}

// Reduced commands keep the executable and a subcommand, and nothing that could
// be a token, whatever the shape of the line.
pub fn a_reduced_command_never_keeps_a_secret_test() {
  assert timeline.reduced("export GITHUB_TOKEN=ghp_abc123") == "export"
  assert timeline.reduced("env API_KEY=sk-abc make deploy") == "make deploy"
  assert timeline.reduced("echo ghp_abc123 | gh auth login --with-token")
    == "echo"
  assert timeline.reduced("curl --user a:b https://x") == "curl"
  assert timeline.reduced("git push origin main") == "git push"
  assert timeline.reduced("X=1 Y=2 make check-storage") == "make check-storage"
  assert timeline.reduced("set -e\nexport A=b") == "set"
  assert timeline.reduced("") == ""
}

// Prompts and answers do not use up the cap on bounded cards.
pub fn the_cap_counts_only_bounded_cards_test() {
  let turns =
    list.flat_map(upto(1, 450), fn(n) {
      list.flatten([
        [prompt("p")],
        read_step(n * 10),
        read_step(n * 10 + 1),
        read_step(n * 10 + 2),
        bash_step(n * 10 + 3, "make", 1),
        [answer("a")],
      ])
    })
  let cut = timeline.cut(place(turns), 40)
  let commands = list.count(kinds(cut), fn(kind) { kind == Ran })

  assert commands == timeline.card_cap
  assert list.count(kinds(cut), fn(kind) { kind == Prompted }) == 450
}

// A span of no step is taken into the card that follows it and makes none.
pub fn a_span_of_no_step_makes_no_card_test() {
  let cut = timeline.cut(place([peer(), peer(), answer("done")]), 40)

  assert kinds(cut) == [timeline.Answered]
}

// An unknown record anywhere in a strand changes no card's kind or facts, only
// the sequences the cards cover.
pub fn an_unknown_record_anywhere_changes_no_facts_test() {
  qcheck.run(config(), generator(), fn(ops) {
    let bodies = bodies_of(ops)
    let plain = facts_of(timeline.cut(place(bodies), 5))

    list.each(upto(0, list.length(bodies)), fn(at) {
      let extended =
        list.flatten([list.take(bodies, at), [Custom], list.drop(bodies, at)])

      assert facts_of(timeline.cut(place(extended), 5)) == plain
    })
  })
}

fn facts_of(cut: timeline.Cut) -> List(#(timeline.Kind, timeline.Facts)) {
  list.map(cut.cards, fn(card) { #(card.kind, card.facts) })
}
