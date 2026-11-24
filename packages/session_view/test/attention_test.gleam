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
    call: "call-1",
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

fn worked(key: String, failed: Int, items: List(turns.Item)) -> turns.Piece {
  turns.Work(
    key:,
    worked: turns.Worked(None, 0, 0, failed, None, turns.Finished),
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
    raised_at: None,
    call: None,
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

pub fn a_turn_with_failed_steps_lifts_once_under_its_own_key_test() {
  let piece = worked("7.0", 2, [step(turns.Done, [])])
  let assert [row] = attention.lift([piece], [])
  assert row.key == "7.0"
  assert row.kind == attention.FailedStep
  assert row.hold == attention.FoldsOnceOpened
  assert row.head == "2 steps failed"
}

// The divider keeps its count while the fold is closed and no step is loaded,
// which is when the rail used to show nothing.
pub fn a_closed_fold_with_no_steps_loaded_still_lifts_test() {
  let assert [row] = attention.lift([worked("7.0", 1, [])], [])
  assert row.head == "1 step failed"
  assert attention.lift([worked("7.0", 0, [step(turns.Failed, [])])], []) == []
}

// A turn whose divider names its last failed call lifts a head that says what
// failed, and adds the count only when more than one call failed.
pub fn a_failed_turn_names_its_last_failed_call_test() {
  let named = fn(failed) {
    turns.Work(
      key: "7.0",
      worked: turns.Worked(
        None,
        3,
        0,
        failed,
        Some("Run make check-web_view · exit 2"),
        turns.Finished,
      ),
      items: [],
      folding: turns.Folded,
      id: None,
    )
  }

  let assert [one] = attention.lift([named(1)], [])
  assert one.head == "Run make check-web_view · exit 2"

  let assert [two] = attention.lift([named(2)], [])
  assert two.head == "Run make check-web_view · exit 2 · 2 steps failed"
}

// A long failed command is cut to leave room, so the count still ends the head
// and the head stays within the limit.
pub fn a_long_failure_line_keeps_the_count_test() {
  let long = string.repeat("make check-web_view ", 20)
  let piece =
    turns.Work(
      key: "7.0",
      worked: turns.Worked(None, 3, 0, 12, Some(long), turns.Finished),
      items: [],
      folding: turns.Folded,
      id: None,
    )

  let assert [row] = attention.lift([piece], [])
  assert string.ends_with(row.head, " · 12 steps failed")
  assert string.length(row.head) <= attention.head_limit
  assert string.contains(row.head, "…")
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

// The outcome is one word every finished child shares, so the row carries the
// first line of what the child reported after it. A child that reported
// nothing keeps the word alone.
pub fn a_sub_agent_result_carries_the_first_line_of_its_report_test() {
  let assert [row] = attention.lift([returned("r1")], [])
  assert row.kind == attention.SubagentResult("sub:tests")
  assert row.head == "passed · report"
  assert row.hold == attention.FoldsOnceOpened

  let said = fn(report) {
    turns.Returned("r2", "sub:tests", "completed", report, turns.Primary)
  }
  let assert [long] =
    attention.lift([said("\n  \nFound 3 bugs in the lane.\nSecond line.")], [])
  assert long.head == "completed · Found 3 bugs in the lane."

  let assert [bare] = attention.lift([said(" \n ")], [])
  assert bare.head == "completed"
}

// A report is Markdown: a heading loses its marks, a rule is no line at all,
// and a report whose breaks arrived as the characters `\n` reads as lines.
pub fn a_result_head_reads_the_reports_words_not_its_marks_test() {
  let head = fn(report) {
    let piece =
      turns.Returned("r", "sub:tests", "completed", report, turns.Primary)
    let assert [row] = attention.lift([piece], [])
    row.head
  }
  assert head("# calc\nTiny calculator.") == "completed · calc"
  assert head("---\n\n## Summary\nbody") == "completed · Summary"
  assert head("# calc \\n Tiny calculator.") == "completed · calc"
  assert head("---\n***") == "completed"
}

fn failure(key: String, text: String) -> turns.Piece {
  plain(key, transcript_line.Failure, text)
}

// Retries of one provider error lift as one row under the first response's
// key, and the head says how many there were.
pub fn repeated_failed_responses_lift_as_one_row_test() {
  let same = "provider stream error (overloaded_error): try later"
  let rows =
    attention.lift(
      [failure("a", same), failure("b", same), failure("c", same)],
      [],
    )
  let assert [row] = rows
  assert row.key == "a"
  assert row.kind == attention.FailedTurn
  assert row.head == same <> " · 3 times"
}

// A different failure, or another row between two failures, starts a new row.
pub fn a_different_failure_or_another_row_between_keeps_rows_apart_test() {
  let rows =
    attention.lift(
      [
        failure("a", "stream error one"),
        failure("b", "stream error one"),
        failure("c", "stream error two"),
        peer("p"),
        failure("d", "stream error two"),
      ],
      [],
    )
  assert list.map(rows, fn(row) { row.key }) == ["d", "p", "c", "a"]
  assert list.map(rows, fn(row) { row.head })
    == [
      "stream error two",
      "messaged this session",
      "stream error two",
      "stream error one · 2 times",
    ]
}

// Sameness is the head the reader sees: two failures that differ only past the
// cut read the same, and the owner would see identical rows, so they are one
// row. This is the case of provider retries that differ in a request size.
pub fn failures_that_differ_only_after_the_cut_are_merged_test() {
  let prefix = string.repeat("x", 200)
  let assert [row] =
    attention.lift(
      [failure("a", prefix <> " one"), failure("b", prefix <> " two")],
      [],
    )
  assert row.key == "a"
  assert string.ends_with(row.head, " · 2 times")
}

// A piece that lifts no row and is not an answer, such as the bookkeeping that
// comes with a heartbeat, does not separate two failures.
pub fn bookkeeping_between_failures_does_not_separate_them_test() {
  let assert [row] =
    attention.lift(
      [
        failure("a", "same"),
        turns.Missed("m", "miss"),
        failure("b", "same"),
      ],
      [],
    )
  assert row.key == "a"
  assert row.head == "same · 2 times"
}

// An answer that did not fail, or the owner's own prompt, ends a run: the owner
// who has moved past a failure has not seen it come back.
pub fn an_answer_or_a_prompt_between_failures_separates_them_test() {
  let owner =
    turns.Prompt(block("o", transcript_line.User, "go on"), "owner", "Me", None)
  list.each(
    [plain("ok", transcript_line.Assistant, "done"), owner],
    fn(between) {
      let rows =
        attention.lift(
          [failure("a", "same"), between, failure("b", "same")],
          [],
        )
      assert list.map(rows, fn(row) { row.key }) == ["b", "a"]
      assert list.all(rows, fn(row) { row.head == "same" })
    },
  )

  // A step that worked ends it as well.
  let rows =
    attention.lift(
      [
        failure("a", "same"),
        worked("w", 0, [step(turns.Done, [])]),
        failure("b", "same"),
      ],
      [],
    )
  assert list.length(rows) == 2
}

// Two failures with no text read as nothing, so each stays a row of its own.
pub fn failures_with_no_text_are_not_counted_test() {
  let rows = attention.lift([failure("a", " "), failure("b", " ")], [])
  assert list.length(rows) == 2
}

// A long failure is cut to leave room for the count.
pub fn a_long_repeated_failure_keeps_the_count_test() {
  let long = string.repeat("provider said no ", 20)
  let assert [row] =
    attention.lift([failure("a", long), failure("b", long)], [])
  assert string.ends_with(row.head, " · 2 times")
  assert string.length(row.head) <= attention.head_limit
}

fn failure_texts(index: Int, kind: Int) -> turns.Piece {
  let key = "f" <> int.to_string(index)

  // Kinds 0 and 1 are failures that differ only past the cut, so they read the
  // same, and 2 is a different failure. 3 is a row of another kind, 4 a piece
  // that lifts no row and is not an answer, 5 an answer that did not fail and
  // 6 the owner's own prompt.
  case kind % 7 {
    0 -> failure(key, string.repeat("e", 150) <> "a")
    1 -> failure(key, string.repeat("e", 150) <> "b")
    2 -> failure(key, "other failure")
    3 -> peer(key)
    4 -> turns.Missed(key, "miss")
    5 -> plain(key, transcript_line.Assistant, "fine")
    _ ->
      turns.Prompt(
        block(key, transcript_line.User, "go on"),
        "owner",
        "Me",
        None,
      )
  }
}

// The runs the owner should see, from the kinds alone: each is the index of
// its first piece and how many failed responses it holds. This is the model
// the classifier is checked against, written as a plain fold.
fn model_runs(kinds: List(Int)) -> List(#(Int, Int)) {
  let #(runs, _) =
    list.index_fold(kinds, #([], None), fn(state, kind, index) {
      let #(runs, open) = state
      case kind % 7 {
        0 | 1 -> grow(runs, open, 0, index)
        2 -> grow(runs, open, 2, index)
        3 -> #([#(index, 1), ..runs], None)
        4 -> #(runs, open)
        _ -> #(runs, None)
      }
    })
  list.reverse(runs)
}

fn grow(
  runs: List(#(Int, Int)),
  open: option.Option(Int),
  reading: Int,
  index: Int,
) -> #(List(#(Int, Int)), option.Option(Int)) {
  case runs, open {
    [#(first, count), ..earlier], Some(now) if now == reading -> #(
      [#(first, count + 1), ..earlier],
      open,
    )
    _, _ -> #([#(index, 1), ..runs], Some(reading))
  }
}

// Collapsing never drops a distinct reading and never moves a key: the rows are
// the model's runs, each under its first key, and a run of more than one says
// its count. Taking the oldest pieces away, as a window that has not loaded
// them does, changes the key of at most the first run that remains.
pub fn collapsing_keeps_every_run_and_never_moves_a_key_test() {
  let config =
    qcheck.default_config()
    |> qcheck.with_test_count(300)
    |> qcheck.with_seed(qcheck.seed(sweep_seed))
  let generator =
    qcheck.generic_list(
      elements_from: qcheck.bounded_int(from: 0, to: 13),
      length_from: qcheck.bounded_int(0, 14),
    )

  qcheck.run(config, generator, fn(kinds) {
    let pieces =
      list.index_map(kinds, fn(kind, index) { failure_texts(index, kind) })
    let rows = attention.lift(pieces, []) |> list.reverse
    let expected = model_runs(kinds)

    assert list.map(rows, fn(row) { row.key })
      == list.map(expected, fn(run) { "f" <> int.to_string(run.0) })
    assert list.zip(rows, expected)
      |> list.all(fn(pair) {
        let #(row, #(_, count)) = pair
        count == 1
        || string.ends_with(row.head, " · " <> int.to_string(count) <> " times")
      })

    // A window that gains older pieces moves at most one key.
    let keys = list.map(rows, fn(row) { row.key })
    list.index_map(pieces, fn(_, index) { index })
    |> list.each(fn(dropped) {
      let later =
        attention.lift(list.drop(pieces, dropped), [])
        |> list.reverse
        |> list.map(fn(row) { row.key })
      assert list.all(list.drop(later, 1), fn(key) { list.contains(keys, key) })
    })
  })
}

pub fn a_peer_message_claims_nothing_about_relevance_test() {
  let assert [row] = attention.lift([peer("p1")], [])
  assert row.kind == attention.PeerMessage("sess-9", "main")
  assert row.head == "messaged this session"
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
    4 -> worked(key, 1, [step(turns.Done, [])])
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

// The session's own open records join the rail: an ask and a stuck strand are
// pinned after the approvals, a find folds once opened, and the order of the
// records is the host's.
pub fn open_records_are_pinned_or_folded_after_the_approvals_test() {
  let rows =
    attention.lift_all([], [], [
      attention.FindRecord("find-1", "bug", "No backoff."),
      attention.StuckRecord("sub:a"),
      attention.AskRecord("ask-1", "Which\nbranch?"),
    ])

  assert list.map(rows, fn(row) { row.key })
    == ["stuck:sub:a", "ask:ask-1", "find:find-1"]
  assert list.map(rows, fn(row) { row.hold })
    == [
      attention.PinnedUntilAnswered,
      attention.PinnedUntilAnswered,
      attention.FoldsOnceOpened,
    ]
  assert list.map(rows, fn(row) { row.head })
    == ["Stopped on a failed run", "Which branch?", "No backoff."]
  assert attention.ask_key("ask-1") == "ask:ask-1"
}

// With no records the rail is what it was.
pub fn lift_is_lift_all_without_records_test() {
  assert attention.lift([], []) == attention.lift_all([], [], [])
}
