//// The live rail's classifier: which lane pieces and register rows it lifts,
//// how it holds, keys and words them, and in what order.
////
//// The unit tests build each kind from the real constructors. The property
//// test generates lanes and registers and checks the laws a view relies on:
//// a pending review lifts exactly once, a decided one never, keys are
//// unique, and the pinned rows precede the insights and partition the list.

import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/set
import gleam/string
import qcheck
import session_view/approval
import session_view/attention
import session_view/step_words
import session_view/transcript_line
import session_view/transcript_lines
import session_view/turns

const sweep_seed = 20_261_118

fn block(key: String, speaker: transcript_line.Speaker, text: String) {
  transcript_lines.Block(key, transcript_lines.FromNotice, [
    #(key <> ":0", transcript_line.Line(speaker, text)),
  ])
}

fn plain(key: String, speaker: transcript_line.Speaker, text: String) {
  turns.Plain(block(key, speaker, text), dict.new(), None)
}

fn step(
  standing: turns.Standing,
  detail: List(transcript_line.Line),
) -> turns.Item {
  turns.Step(
    key: "ignored",
    standing:,
    words: step_words.Words("Run", step_words.Mono("make check"), None),
    detail:,
    full: [],
    images: [],
    since: None,
    result_source: None,
    program: None,
  )
}

fn work(key: String, items: List(turns.Item)) -> turns.Piece {
  turns.Work(
    key:,
    worked: turns.Worked(None, 0, 0, 0, turns.Finished),
    items:,
    folding: turns.Folded,
    id: None,
  )
}

fn review(
  id: String,
  status: approval.Status,
  tool: String,
) -> approval.Review {
  approval.Review(
    id:,
    seq: 1,
    status:,
    tool:,
    preview: "{\"command\":\"make check\"}",
    origin: None,
    permission: approval.Exact("digest", []),
    strand: None,
    remote: None,
  )
}

fn returned(key: String) -> turns.Piece {
  turns.Returned(key, "sub:tests", "passed", "report", turns.Primary)
}

fn peer(key: String) -> turns.Piece {
  turns.Peer(key, "sess-9", "main", "text")
}

pub fn a_pending_approval_is_pinned_with_its_tool_and_preview_test() {
  let assert [row] =
    attention.lift([], [review("e1", approval.Pending, "bash")])
  assert row.key == "approval:e1"
  assert row.kind == attention.ApprovalPending("bash")
  assert row.hold == attention.PinnedUntilAnswered
  assert row.head == "run a command · Run \"make check\""
}

pub fn a_decided_approval_is_not_lifted_test() {
  let decided = [
    review("a", approval.Approved, "bash"),
    review("b", approval.Rejected, "bash"),
    review("c", approval.Consumed, "bash"),
  ]
  assert attention.lift([], decided) == []
}

pub fn a_failed_step_lifts_once_per_step_with_an_indexed_key_test() {
  let piece =
    work("7.0", [
      step(turns.Done, []),
      step(turns.Failed, []),
      step(turns.Pending, []),
      step(turns.Failed, []),
    ])
  let rows = attention.lift([piece], [])
  assert list.map(rows, fn(row) { row.key }) == ["7.0#3", "7.0#1"]
  assert list.all(rows, fn(row) { row.kind == attention.FailedStep })
  assert list.all(rows, fn(row) { row.hold == attention.FoldsOnceOpened })
  assert list.map(rows, fn(row) { row.head })
    == ["Run make check", "Run make check"]
}

pub fn a_program_failure_lifts_its_step_even_when_it_reads_as_done_test() {
  let failure = transcript_line.Line(transcript_line.ProgramFailure, "boom")
  let rows = attention.lift([work("8.0", [step(turns.Done, [failure])])], [])
  assert list.map(rows, fn(row) { row.kind }) == [attention.FailedStep]
}

pub fn a_failed_response_is_a_failed_turn_test() {
  let rows =
    attention.lift([plain("9.0", transcript_line.Failure, "model gave up")], [])
  let assert [row] = rows
  assert row.key == "9.0"
  assert row.kind == attention.FailedTurn
  assert row.head == "model gave up"
}

pub fn an_ordinary_answer_is_not_lifted_test() {
  assert attention.lift([plain("1.0", transcript_line.Assistant, "hi")], [])
    == []
}

pub fn a_refused_spawn_is_a_failed_turn_and_a_running_one_is_not_test() {
  let spawn = fn(standing, refusal) {
    turns.Spawned(
      "s",
      Some("sub:a"),
      "write docs",
      turns.Primary,
      standing,
      refusal,
    )
  }
  let rows = attention.lift([spawn(turns.Failed, Some("no budget"))], [])
  let assert [row] = rows
  assert row.kind == attention.FailedTurn
  assert row.head == "Spawn of sub:a failed · no budget"
  assert attention.lift(
      [spawn(turns.Pending, None), spawn(turns.Done, None)],
      [],
    )
    == []
}

pub fn a_sub_agent_result_names_the_child_and_outcome_test() {
  let assert [row] = attention.lift([returned("r1")], [])
  assert row.kind == attention.SubagentResult("sub:tests")
  assert row.head == "sub:tests · passed"
  assert row.hold == attention.FoldsOnceOpened
}

pub fn a_peer_message_claims_nothing_about_relevance_test() {
  let assert [row] = attention.lift([peer("p1")], [])
  assert row.kind == attention.PeerMessage("sess-9", "main")
  assert row.head == "sess-9 · main messaged this session"
  let lower = string.lowercase(row.head)
  assert !string.contains(lower, "relevant")
  assert !string.contains(lower, "unanswered")
  assert !string.contains(lower, "about")
}

pub fn a_long_head_is_cut_on_a_grapheme_boundary_test() {
  let long = string.repeat("e\u{0301}", 300)
  let assert [row] =
    attention.lift([plain("3.0", transcript_line.Failure, long)], [])
  let graphemes = string.to_graphemes(row.head)
  assert list.length(graphemes) == attention.head_limit
  assert list.last(graphemes) == Ok("…")
  assert list.take(graphemes, 119) == list.repeat("e\u{0301}", 119)
}

pub fn a_head_is_one_line_test() {
  let assert [row] =
    attention.lift([plain("4.0", transcript_line.Failure, "a\n\n b\tc")], [])
  assert row.head == "a b c"
}

pub fn pinned_rows_come_first_then_insights_newest_first_test() {
  let rows =
    attention.lift([returned("old"), peer("mid"), returned("new")], [
      review("x", approval.Pending, "bash"),
      review("y", approval.Pending, "fs_write"),
    ])
  assert list.map(rows, fn(row) { row.key })
    == ["approval:x", "approval:y", "new", "mid", "old"]
  assert list.map(attention.pinned(rows), fn(row) { row.key })
    == ["approval:x", "approval:y"]
  assert list.map(attention.insights(rows), fn(row) { row.key })
    == ["new", "mid", "old"]
}

fn piece_for(index: Int, kind: Int) -> turns.Piece {
  let key = "k" <> int.to_string(index)
  case kind % 7 {
    0 -> returned(key)
    1 -> peer(key)
    2 -> plain(key, transcript_line.Failure, "failed")
    3 -> plain(key, transcript_line.Assistant, "fine")
    4 -> work(key, [step(turns.Failed, []), step(turns.Done, [])])
    5 -> turns.Missed(key, "miss")
    _ -> turns.Spawned(key, None, "p", turns.Primary, turns.Failed, None)
  }
}

fn review_for(index: Int, status: Int) -> approval.Review {
  let state = case status % 4 {
    0 -> approval.Pending
    1 -> approval.Approved
    2 -> approval.Rejected
    _ -> approval.Consumed
  }
  review("r" <> int.to_string(index), state, "bash")
}

pub fn the_rail_laws_hold_over_generated_lanes_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(300)
    |> qcheck.with_seed(qcheck.seed(sweep_seed))
  let ints = qcheck.bounded_int(from: 0, to: 20)
  let generator =
    qcheck.tuple2(
      qcheck.generic_list(
        elements_from: ints,
        length_from: qcheck.bounded_int(0, 12),
      ),
      qcheck.generic_list(
        elements_from: ints,
        length_from: qcheck.bounded_int(0, 8),
      ),
    )

  qcheck.run(config, generator, fn(generated) {
    let #(kinds, statuses) = generated
    let pieces =
      list.index_map(kinds, fn(kind, index) { piece_for(index, kind) })
    let approvals =
      list.index_map(statuses, fn(status, index) { review_for(index, status) })
    let rows = attention.lift(pieces, approvals)

    let pending =
      approvals
      |> list.filter(fn(each) { each.status == approval.Pending })
      |> list.map(fn(each) { "approval:" <> each.id })
    let pinned = attention.pinned(rows)
    let insights = attention.insights(rows)
    let keys = list.map(rows, fn(row) { row.key })

    // Every pending review lifts once, and nothing else is pinned.
    assert list.map(pinned, fn(row) { row.key }) == pending

    // Keys are unique.
    assert set.size(set.from_list(keys)) == list.length(keys)

    // The two groups partition the list, pinned first.
    assert list.append(pinned, insights) == rows
    assert list.all(insights, fn(row) { row.hold == attention.FoldsOnceOpened })
    assert list.all(rows, fn(row) {
      string.length(row.head) <= attention.head_limit
    })
  })
}
