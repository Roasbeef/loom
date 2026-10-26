//// Tests for the ATIF exporter: step numbering, the join between calls and
//// results, the thinking exclusion, metric totals, the copy-then-read edge and
//// the credential rule.

import core/clock
import core/entry.{type Entry, type UsageRow, MessageEntry, UsageRow}
import core/ids.{type EntryId}
import core/json
import core/message.{
  type AssistantBlock, type Usage, AssistantMessage, AssistantText,
  AssistantThinking, AssistantToolCall, Stop, ToolCall, ToolResultMessage,
  ToolResultText, ToolUse, Usage, UsageCost, UserMessage, UserText,
}
import core/tx.{InsertEntry, InsertUsage, Tx}
import core/usage_evidence
import eval/atif
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import simplifile
import storage/sqlite
import storage/storage

const seed = 3

fn generator(seed: Int) -> ids.Generator {
  ids.generator(clock.stepping(from: 1000, by: 1), seed:)
}

// Mints n entry ids.
fn entry_ids(count: Int) -> List(EntryId) {
  list.repeat(Nil, count)
  |> list.fold(#([], generator(seed)), fn(state, _) {
    let #(made, gen) = state
    let #(id, gen) = ids.mint_entry(gen)
    #([id, ..made], gen)
  })
  |> fn(state) { list.reverse(state.0) }
}

fn user(id: EntryId, text: String) -> Entry {
  MessageEntry(
    id:,
    parent: None,
    seq: 0,
    ts: 0,
    message: UserMessage(
      content: [UserText(text:, text_signature: None)],
      timestamp: 0,
      origin: None,
    ),
    terminate: False,
  )
}

fn answer(id: EntryId, content: List(AssistantBlock)) -> Entry {
  MessageEntry(
    id:,
    parent: None,
    seq: 0,
    ts: 0,
    message: AssistantMessage(
      content:,
      api: "api",
      provider: "provider",
      model: "model-x",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: usage(1, 1),
      stop_reason: case content {
        [AssistantToolCall(..), ..] -> ToolUse
        _ -> Stop
      },
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: 0,
    ),
    terminate: False,
  )
}

fn call(id: String, arguments: json.JsonValue) -> AssistantBlock {
  AssistantToolCall(ToolCall(
    id:,
    name: "shell",
    arguments:,
    thought_signature: None,
    namespace: None,
  ))
}

fn result(id: EntryId, call_id: String, text: String) -> Entry {
  MessageEntry(
    id:,
    parent: None,
    seq: 0,
    ts: 0,
    message: ToolResultMessage(
      tool_call_id: call_id,
      tool_name: "shell",
      content: [ToolResultText(text:, text_signature: None)],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: 0,
    ),
    terminate: False,
  )
}

fn usage(input: Int, output: Int) -> Usage {
  Usage(
    input:,
    output:,
    cache_read: 10,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: input + output + 10,
    cost: UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.5,
    ),
    evidence: usage_evidence.priced_api(),
  )
}

fn row(
  id: ids.UsageId,
  tied: option.Option(EntryId),
  adjustment: Bool,
  value: Usage,
) -> UsageRow {
  UsageRow(
    id:,
    seq: 0,
    entry_id: tied,
    adjustment:,
    usage: value,
    details: None,
  )
}

fn usage_ids(count: Int) -> List(ids.UsageId) {
  list.repeat(Nil, count)
  |> list.fold(#([], generator(seed + 1)), fn(state, _) {
    let #(made, gen) = state
    let #(id, gen) = ids.mint_usage(gen)
    #([id, ..made], gen)
  })
  |> fn(state) { list.reverse(state.0) }
}

fn ids_of(trajectory: atif.Trajectory) -> List(Int) {
  list.map(trajectory.steps, fn(step) { step.id })
}

pub fn atif_steps_are_contiguous_test() {
  let assert [a, b, c, d, e] = entry_ids(5)
  let compaction =
    entry.CompactionEntry(
      id: e,
      parent: None,
      seq: 0,
      ts: 0,
      summary: "s",
      retained_tail: [],
      tokens_before: 1,
      from_hook: False,
      usage: None,
    )
  let entries = [
    user(a, "go"),
    answer(b, [call("c1", json.Object([]))]),
    result(c, "c1", "out"),
    compaction,
    answer(d, [AssistantText("done", None)]),
  ]

  let trajectory = atif.from_entries(entries, [], "model-x")

  assert ids_of(trajectory) == [1, 2, 3]

  let prefixed = atif.with_system_prompt(trajectory, "be brief")

  assert ids_of(prefixed) == [1, 2, 3, 4]
  assert list.map(prefixed.steps, fn(step) { step.source })
    == [
      atif.SystemSource,
      atif.UserSource,
      atif.AgentSource,
      atif.AgentSource,
    ]
}

pub fn tool_results_join_by_call_id_test() {
  let assert [a, b, c, d, e, f] = entry_ids(6)
  let entries = [
    user(a, "go"),
    answer(b, [call("c1", json.Object([])), call("c2", json.Object([]))]),
    result(c, "c2", "second"),
    result(d, "c1", "first"),
    answer(e, [call("c3", json.Object([]))]),
    result(f, "orphan", "nobody asked"),
    result(f, "c3", "third"),
  ]

  let trajectory = atif.from_entries(entries, [], "m")
  let assert [_, issuer, later] = trajectory.steps

  assert issuer.observation
    == [
      atif.Observed("c2", "second"),
      atif.Observed("c1", "first"),
    ]
  assert later.observation == [atif.Observed("c3", "third")]
  assert list.length(issuer.tool_calls) == 2
}

pub fn thinking_is_never_exported_test() {
  let assert [a, b] = entry_ids(2)
  let entries = [
    user(a, "go"),
    answer(b, [
      AssistantThinking("private reasoning", Some("SIGNATURE-BLOB"), False),
      AssistantText("visible", None),
    ]),
  ]

  let text =
    atif.from_entries(entries, [], "m")
    |> atif.to_json
    |> json.to_string

  assert string.contains(text, "visible")
  assert !string.contains(text, "private reasoning")
  assert !string.contains(text, "SIGNATURE-BLOB")
}

pub fn final_metrics_sum_usage_test() {
  let assert [a, b, c] = entry_ids(3)
  let assert [u1, u2, u3] = usage_ids(3)
  let entries = [
    user(a, "go"),
    answer(b, [call("c1", json.Object([]))]),
    result(c, "c1", "out"),
  ]
  let rows = [
    row(u1, Some(b), False, usage(100, 20)),
    row(u2, Some(c), False, usage(5, 0)),
    row(u3, Some(b), True, usage(1, 1)),
  ]

  let trajectory = atif.from_entries(entries, rows, "m")
  let assert [_, agent, ..] = trajectory.steps

  // Each row adds 10 cache-read tokens to its prompt side and 0.5 dollars.
  assert trajectory.final_metrics
    == atif.Metrics(
      prompt_tokens: 110 + 15 + 11,
      completion_tokens: 21,
      cached_tokens: 30,
      cost_usd: 1.5,
    )
  assert agent.metrics
    == Some(atif.Metrics(
      prompt_tokens: 110,
      completion_tokens: 20,
      cached_tokens: 10,
      cost_usd: 0.5,
    ))
}

pub fn atif_from_session_db_reads_a_copy_test() {
  let directory = "build/atif-test/copy"
  let _ = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let path = directory <> "/session.db"
  let assert [a, b, c] = entry_ids(3)
  let assert [u1] = usage_ids(1)
  let b_entry = answer(b, [call("c1", json.Object([]))])
  let assert Ok(store) =
    sqlite.open(sqlite.config(path:, owner: "writer"), clock.fixed(at: 10_000))
  let assert Ok(_) =
    storage.commit(
      store,
      Tx(
        writes: [
          InsertEntry(user(a, "go")),
          InsertEntry(set_parent(b_entry, a)),
          InsertEntry(set_parent(result(c, "c1", "out"), b)),
          InsertUsage(row(u1, Some(b), False, usage(7, 3))),
        ],
        expected: [],
      ),
    )

  // The writer is still open, so the file carries its live lease.
  let assert Ok(before) = simplifile.read_bits(path)
  let assert Ok(info_before) = simplifile.file_info(path)

  let assert Ok(trajectory) = atif.from_session_db(path)

  let assert Ok(after) = simplifile.read_bits(path)
  let assert Ok(info_after) = simplifile.file_info(path)
  let assert Ok(names) = simplifile.read_directory(directory)

  assert ids_of(trajectory) == [1, 2]
  assert trajectory.model_name == "model-x"
  assert after == before
  assert info_after.mtime_seconds == info_before.mtime_seconds
  assert list.all(names, fn(name) { !string.contains(name, ".atif-") })

  // The original's lease is still the writer's.
  let assert Error(sqlite.LeaseHeld(owner: "writer", ..)) =
    sqlite.open(
      sqlite.config(path:, owner: "intruder"),
      clock.fixed(at: 10_001),
    )
  let assert Ok(Nil) = storage.close(store)
}

fn set_parent(entry: Entry, parent: EntryId) -> Entry {
  case entry {
    MessageEntry(..) -> MessageEntry(..entry, parent: Some(parent))
    _ -> entry
  }
}

pub fn secrets_scrubbed_but_hashes_kept_test() {
  let hash = "3f9a1c2b4d5e6f708192a3b4c5d6e7f801234567"
  let test_name =
    "machine@failure_test.threshold_summary_failure_past_the_ladder_test"
  let assert [a, b, c] = entry_ids(3)
  let entries = [
    user(a, "key sk-ant123abc and commit " <> hash),
    answer(b, [
      AssistantText("use Bearer tok_123 for " <> test_name, None),
      call("c1", json.Object([#("token", json.String("ghp_secretvalue"))])),
    ]),
    result(c, "c1", "task-force github_pat_11AAA done"),
  ]

  let text =
    atif.from_entries(entries, [], "m") |> atif.to_json |> json.to_string

  assert string.contains(text, hash)
  assert string.contains(text, test_name)
  assert string.contains(text, "task-force")
  assert string.contains(text, "Bearer <redacted>")
  assert !string.contains(text, "sk-ant123abc")
  assert !string.contains(text, "tok_123")
  assert !string.contains(text, "ghp_secretvalue")
  assert !string.contains(text, "github_pat_11AAA")
  assert dict.size(dict.new()) == 0
}
