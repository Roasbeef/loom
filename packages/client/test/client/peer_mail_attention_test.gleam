//// The `AttentionFeed` endpoint command (protocol-change/120): the row a
//// resident computes for `sessions.attention`.
////
//// A page counts only what a row says it read, so the row has to be right and
//// has to fit. These tests read the row from a real runtime and a real store,
//// through `peer_mail.handle`, the call the Agency actor makes, and pin the
//// bounds over generated record sets from a fixed qcheck seed.

import client/advisor
import client/attention
import client/attention_feed
import client/internal/ffi_os
import client/peer_mail
import core/attention as records
import core/clock
import core/ids
import core/json.{type JsonValue}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/stream
import qcheck
import runtime/api
import runtime/effects
import session/session
import simplifile
import tools/agent
import tools/attention as tool_attention

const now = 1_790_000_000_000

const seed = 20_261_118

// --- the rig ---------------------------------------------------------------

fn open() -> api.Runtime {
  let directory =
    "build/peer-mail-attention-test-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the scratch directory is made"
  let time = clock.fixed(at: now)
  let assert Ok(opened) =
    session.open_sqlite(
      directory <> "/session.db",
      "peer-mail-attention-test",
      30_000,
      time,
    )
    as "the SQLite session must open"
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: ["ask", "notice"],
    )
  let assert Ok(runtime) =
    api.open(
      opened,
      effects.Effects(
        clock: time,
        entropy: ffi_os.unique_positive_integer,
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(
          timeout_ms: 60_000,
          request: fn(_spec) {
            stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
          },
        ),
        tools: effects.ToolSurface(
          clear: fn(_query) {
            effects.ClearanceRefused(reason: "no tools in this harness")
          },
          run: fn(_run) { effects.ToolFailed(reason: "no tools") },
          replay_still_safe: fn(_name) { False },
          execution_mode: fn(_name) { effects.ExclusiveExecution },
          recover: None,
        ),
        hooks: effects.default_hooks(),
      ),
      api.default_options(configuration),
    )
    as "the runtime must open"
  runtime
}

fn wiring(runtime: api.Runtime, at: Int) -> attention.Wiring {
  attention.Wiring(
    runtime: fn() { Ok(runtime) },
    clock: clock.fixed(at:),
    entropy: ffi_os.unique_positive_integer,
  )
}

fn operation_id() -> ids.OpId {
  let #(id, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  id
}

fn caller(strand: String) -> agent.Caller {
  agent.Caller(
    strand:,
    operation: operation_id(),
    step_id: "step-1",
    source_index: 3,
    minter: agent.ToolCall,
  )
}

fn ask_request(
  prompt: String,
  to: Option(String),
) -> tool_attention.AskRequest {
  tool_attention.AskRequest(to:, why: None, questions: [
    records.Question(key: "q1", prompt:, kind: records.Confirm, options: []),
    records.Question(
      key: "q2",
      prompt: "A second question.",
      kind: records.Confirm,
      options: [],
    ),
  ])
}

fn notice_request(
  text: String,
  path: Option(String),
  line: Option(Int),
) -> tool_attention.NoticeRequest {
  tool_attention.NoticeRequest(kind: records.Bug, text:, path:, line:)
}

fn feed(runtime: api.Runtime) -> JsonValue {
  let assert Ok(row) =
    peer_mail.handle(runtime, clock.fixed(0), peer_mail.AttentionFeed)
    as "the resident answers its own feed"
  assert string.byte_size(json.to_string(row)) <= attention_feed.row_bytes
  row
}

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "an object"
  let assert Ok(found) = list.key_find(fields, key) as "the field is present"
  found
}

fn absent(value: JsonValue, key: String) -> Bool {
  let assert json.Object(fields) = value as "an object"
  list.key_find(fields, key) == Error(Nil)
}

fn count(row: JsonValue, section: String) -> JsonValue {
  field(field(row, section), "count")
}

fn items(row: JsonValue, section: String) -> List(JsonValue) {
  let assert json.Array(found) = field(field(row, section), "items")
    as "the items are an array"
  found
}

// --- what a row says -------------------------------------------------------

pub fn an_empty_session_has_nothing_to_report_test() {
  let runtime = open()
  let row = feed(runtime)
  assert field(row, "state") == json.String("ok")
  assert absent(row, "waiting_since")
  assert count(row, "asks") == json.Int(0)
  assert count(row, "finds") == json.Int(0)
  assert count(row, "stuck") == json.Int(0)
  assert items(row, "asks") == []
  let assert Ok(Nil) = api.close(runtime)
}

pub fn open_asks_and_finds_are_listed_and_settled_ones_are_not_test() {
  let runtime = open()
  let assert Ok(open_id) =
    attention.ask(
      wiring(runtime, now),
      caller("sub:main/audit-1a2b"),
      ask_request("Which branch should the fix target?", None),
    )
  let assert Ok(find_id) =
    attention.notice(
      wiring(runtime, now + 5),
      caller("main"),
      notice_request(
        "The retry loop never backs off.",
        Some("src/retry.gleam"),
        Some(88),
      ),
    )

  // One answered ask and one closed find are settled and not in the row.
  let answered =
    records.Ask(
      header: records.Header(
        id: "ask-00000000aa",
        created_at: 1,
        routing: records.ToOwner,
        anchor: records.Anchor(operation_id(), "s", 0),
        strand: "main",
        parents: [],
      ),
      why: None,
      questions: [records.Question("q1", "Old?", records.Confirm, [])],
      state: records.Answered(
        at: now,
        answer: records.Answer([#("q1", records.Yes)], by: "owner"),
      ),
    )
  let closed =
    records.Find(
      header: records.Header(
        id: "find-00000000bb",
        created_at: 1,
        routing: records.ToOwner,
        anchor: records.Anchor(operation_id(), "s", 0),
        strand: "main",
        parents: [],
      ),
      kind: records.Idea,
      text: "Old idea.",
      path: None,
      line: None,
      state: records.Closed(at: now, closure: records.Fixed, by: "owner"),
    )
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      records.ask_key(answered.header.id),
      records.encode_ask(answered),
    )
  let assert Ok(Nil) =
    api.put_reserved_fact(
      runtime,
      records.find_key(closed.header.id),
      records.encode_find(closed),
    )

  let row = feed(runtime)
  assert field(row, "waiting_since") == json.Int(now)
  assert count(row, "asks") == json.Int(1)
  assert items(row, "asks")
    == [
      json.Object([
        #("id", json.String(open_id)),
        #("strand", json.String("sub:main/audit-1a2b")),
        #("created_at", json.Int(now)),
        #("head", json.String("Which branch should the fix target?")),
        #("questions", json.Int(2)),
      ]),
    ]
  assert count(row, "finds") == json.Int(1)
  assert items(row, "finds")
    == [
      json.Object([
        #("id", json.String(find_id)),
        #("strand", json.String("main")),
        #("kind", json.String("bug")),
        #("created_at", json.Int(now + 5)),
        #("head", json.String("The retry loop never backs off.")),
        #("path", json.String("src/retry.gleam")),
        #("line", json.Int(88)),
      ]),
    ]
  let assert Ok(Nil) = api.close(runtime)
}

pub fn an_ask_routed_to_a_strand_is_neither_listed_nor_counted_test() {
  let runtime = open()
  let assert Ok(_) =
    attention.ask(
      wiring(runtime, now),
      caller("sub:main/a"),
      ask_request("For the main strand.", Some("main")),
    )
  let row = feed(runtime)
  assert count(row, "asks") == json.Int(0)
  assert absent(row, "waiting_since")
  let assert Ok(Nil) = api.close(runtime)
}

pub fn waiting_since_is_the_oldest_ask_for_the_owner_test() {
  let runtime = open()
  let assert Ok(_) =
    attention.ask(
      wiring(runtime, now + 900),
      caller("main"),
      ask_request("B", None),
    )
  let assert Ok(_) =
    attention.ask(
      wiring(runtime, now + 100),
      caller("main"),
      ask_request("A", None),
    )
  let row = feed(runtime)
  assert field(row, "waiting_since") == json.Int(now + 100)

  // Newest first, so the shedding order can take from the end.
  let assert [newest, older] = items(row, "asks")
  assert field(newest, "created_at") == json.Int(now + 900)
  assert field(older, "created_at") == json.Int(now + 100)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn an_approval_alone_gives_no_waiting_since_test() {
  let runtime = open()
  let assert Ok(Nil) = api.raise_escalation(runtime, "esc-1", json.Object([]))
    as "an approval is raised"
  let row = feed(runtime)
  assert absent(row, "waiting_since")
  assert count(row, "asks") == json.Int(0)
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_long_head_is_cut_on_a_grapheme_boundary_test() {
  let runtime = open()
  let prompt = string.repeat("é日👍🏽", 60)
  let assert Ok(_) =
    attention.ask(
      wiring(runtime, now),
      caller("main"),
      ask_request(prompt, None),
    )
  let row = feed(runtime)
  let assert [item] = items(row, "asks")
  let assert json.String(head) = field(item, "head") as "the head is text"
  assert string.byte_size(head) <= attention_feed.head_bytes
  assert string.ends_with(head, "…")

  // Every grapheme before the ellipsis is one of the whole ones put in.
  let whole = string.to_graphemes("é日👍🏽")
  assert list.all(string.to_graphemes(string.drop_end(head, 1)), fn(grapheme) {
    list.contains(whole, grapheme)
  })
  let assert Ok(Nil) = api.close(runtime)
}

pub fn a_find_without_a_path_carries_no_line_and_a_long_path_none_test() {
  let runtime = open()
  let assert Ok(_) =
    attention.notice(
      wiring(runtime, now),
      caller("main"),
      notice_request("No path.", None, None),
    )
  let long_path = string.repeat("a", 170) <> ".gleam"
  let assert Ok(_) =
    attention.notice(
      wiring(runtime, now + 1),
      caller("main"),
      notice_request("Long path.", Some(long_path), Some(3)),
    )
  let row = feed(runtime)
  let assert [long, plain] = items(row, "finds")
  assert absent(long, "path")
  assert absent(long, "line")
  assert absent(plain, "path")
  assert absent(plain, "line")
  let assert Ok(Nil) = api.close(runtime)
}

// --- stuck strands ---------------------------------------------------------

fn entry(at: Int) -> ids.EntryId {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(at:), seed: 3))
  id
}

fn failed(leaf: Option(ids.EntryId)) -> operation.LastResult {
  operation.RunLastResult(
    operation: operation_id(),
    leaf:,
    outcome: operation.RunFailed(operation.OperationError(
      "provider",
      "overloaded",
      None,
    )),
    final_assistant: None,
  )
}

pub fn a_failed_idle_strand_is_stuck_with_the_time_of_its_leaf_test() {
  let results = [
    #("sub:main/audit-1a2b", failed(Some(entry(1_790_000_002_000)))),
  ]
  assert attention_feed.stuck_strands([], results)
    == [
      attention_feed.Stuck(
        strand: "sub:main/audit-1a2b",
        failed_at: Some(1_790_000_002_000),
      ),
    ]
}

pub fn a_result_with_no_leaf_gives_no_failed_at_test() {
  assert attention_feed.stuck_strands([], [#("sub:main/a", failed(None))])
    == [attention_feed.Stuck(strand: "sub:main/a", failed_at: None)]
}

pub fn only_a_failed_run_of_a_non_main_idle_strand_is_stuck_test() {
  let completed =
    operation.RunLastResult(
      operation: operation_id(),
      leaf: None,
      outcome: operation.RunCompleted(operation.CompletedByAssistant),
      final_assistant: None,
    )
  let aborted =
    operation.RunLastResult(
      operation: operation_id(),
      leaf: None,
      outcome: operation.RunAborted,
      final_assistant: None,
    )
  let compaction =
    operation.CompactionLastResult(
      operation: operation_id(),
      leaf: None,
      outcome: operation.StructuralFailed(operation.OperationError(
        "provider",
        "x",
        None,
      )),
    )
  let results = [
    // main is the session's own state word, and the advisor is the harness's.
    #("main", failed(None)),
    #("advisor", failed(None)),
    // A run that began since has a current operation, and a later result of
    // another kind overwrote the failure.
    #("sub:main/running", failed(None)),
    #("sub:main/retried", completed),
    #("sub:main/aborted", aborted),
    #("sub:main/compacted", compaction),
    #("sub:main/stuck", failed(None)),
  ]
  let states = [#("sub:main/running", Some(operation_id()))]
  let assert [attention_feed.Stuck(strand: "sub:main/stuck", ..)] =
    attention_feed.stuck_strands(states, results)
}

pub fn the_reserved_strand_names_are_the_advisors_test() {
  assert attention_feed.primary_strand == advisor.primary
  assert attention_feed.advisor_strand == advisor.strand
}

// --- the bounds ------------------------------------------------------------

fn ask_of(index: Int, head: String) -> records.Ask {
  records.Ask(
    header: records.Header(
      id: records.mint_ask_id(index),
      created_at: 1000 + index,
      routing: records.ToOwner,
      anchor: records.Anchor(operation_id(), "s", 0),
      strand: "sub:main/" <> string.repeat("é", 70) <> int.to_string(index),
      parents: [],
    ),
    why: None,
    questions: [records.Question("q1", head, records.Confirm, [])],
    state: records.AskOpen,
  )
}

fn find_of(index: Int, head: String) -> records.Find {
  records.Find(
    header: records.Header(
      id: records.mint_find_id(index),
      created_at: 2000 + index,
      routing: records.ToOwner,
      anchor: records.Anchor(operation_id(), "s", 0),
      strand: "sub:main/" <> string.repeat("é", 70) <> int.to_string(index),
      parents: [],
    ),
    kind: records.Risk,
    text: head,
    path: Some(string.repeat("p/", 80)),
    line: Some(index + 1),
    state: records.FindOpen,
  )
}

fn stuck_of(index: Int) -> attention_feed.Stuck {
  attention_feed.Stuck(
    strand: "sub:main/" <> string.repeat("日", 40) <> int.to_string(index),
    failed_at: case index % 3 {
      0 -> None
      _ -> Some(3000 + index)
    },
  )
}

fn row_for(
  asks: Int,
  finds: Int,
  stuck: Int,
  head: String,
) -> attention_feed.Row {
  attention_feed.row_of(
    list.map(upto(asks), ask_of(_, head)),
    list.map(upto(finds), find_of(_, head)),
    list.map(upto(stuck), stuck_of),
  )
}

/// The integers from 1 to `n`.
fn upto(n: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, n), fn(_, index) { index + 1 })
}

fn encoded_bytes(row: attention_feed.Row) -> Int {
  string.byte_size(json.to_string(attention_feed.encode(row)))
}

pub fn a_generated_row_fits_and_never_loses_a_count_test() {
  qcheck.default_config()
  |> qcheck.with_test_count(60)
  |> qcheck.with_seed(qcheck.seed(seed))
  |> qcheck.run(
    qcheck.tuple3(
      qcheck.bounded_int(0, 32),
      qcheck.bounded_int(0, 128),
      qcheck.bounded_int(0, 30),
    ),
    fn(drawn) {
      let #(asks, finds, stuck) = drawn
      let head = string.repeat("é\"日\\👍🏽", 40)
      let full = row_for(asks, finds, stuck, head)
      let shed = attention_feed.shed(full)

      // However much the session holds, the row fits.
      assert encoded_bytes(shed) <= attention_feed.row_bytes

      // A count is never reduced, and items are never added.
      assert shed.asks.count == asks
      assert shed.finds.count == finds
      assert shed.stuck.count == stuck
      assert list.length(shed.asks.items) <= asks
      assert list.length(shed.finds.items) <= finds
      assert list.length(shed.stuck.items) <= stuck

      // The shedding order: a later list lost an item only once every earlier
      // one was empty, and what is kept is the newest.
      case list.length(shed.asks.items) < asks {
        True -> {
          assert shed.finds.items == []
          assert shed.stuck.items == []
        }
        False -> Nil
      }
      case list.length(shed.stuck.items) < stuck {
        True -> {
          assert shed.finds.items == []
        }
        False -> Nil
      }
      assert shed.finds.items
        == list.take(full.finds.items, list.length(shed.finds.items))
      assert shed.asks.items
        == list.take(full.asks.items, list.length(shed.asks.items))
    },
  )
}

pub fn a_row_that_already_fits_is_untouched_test() {
  let row = row_for(2, 3, 1, "short")
  assert attention_feed.shed(row) == row
}

pub fn the_oldest_finds_go_first_and_the_oldest_asks_last_test() {
  let full = row_for(32, 128, 30, string.repeat("x", 120))
  let shed = attention_feed.shed(full)
  assert shed.finds.items == []
  assert shed.stuck.items == []

  // Asks are the last to lose anything, and lose their oldest.
  let kept = list.length(shed.asks.items)
  assert kept < 32
  let assert [newest, ..] = shed.asks.items
  assert newest.created_at == 1032
  assert shed.waiting_since == Some(1001)
}

pub fn a_session_full_of_open_finds_still_reports_a_row_that_fits_test() {
  let runtime = open()
  let wired = wiring(runtime, now)
  list.each(upto(128), fn(index) {
    let assert Ok(_) =
      attention.notice(
        wired,
        caller("sub:main/" <> int.to_string(index)),
        notice_request(
          string.repeat("A long find. ", 30),
          Some("src/some/deeply/nested/path/file.gleam"),
          Some(index),
        ),
      )
  })
  let row = feed(runtime)
  assert count(row, "finds") == json.Int(128)
  assert list.length(items(row, "finds")) < 128
  let assert Ok(Nil) = api.close(runtime)
}
