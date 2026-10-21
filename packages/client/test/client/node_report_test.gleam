//// The report a daemon gives about itself (protocol-change/085): the whole
//// vocabulary survives its JSON rendering unchanged, and a reading that breaks
//// a bound is refused with the field named.

import client/directory/member
import client/directory/store
import client/executors
import client/internal/ffi_khepri
import client/node_report.{
  type NodeReport, Closing, DirectoryFacts, ExecutorFacts, MoveFacts, NodeReport,
  NotReceiving, OrchestratorFacts, Placement, Receiving, Running, ScopeCounts,
  UncleanScope, Unconfirmed, UnknownCleanup, Waiting,
}
import core/json

import gleam/list
import gleam/option.{None, Some}
import gleam/string

fn executor() -> node_report.ExecutorFacts {
  ExecutorFacts(
    protocol: 3,
    scopes: ScopeCounts(open: 2, closing: 1, closed_clean: 4, closed_unknown: 1),
    scope_limit: 16,
    unclean: [
      UncleanScope(session: "s-closing", state: Closing),
      UncleanScope(session: "s-lost", state: UnknownCleanup(count: 3)),
    ],
    ledger_bytes: 4096,
    ledger_limit: 536_870_912,
    unacknowledged: 5,
    platform: "linux/x86_64",
    observed: Some(
      executors.Observed(
        platform: "linux/x86_64",
        enforcement: executors.Degraded,
        toolchains: ["codemode", "gleam"],
      ),
    ),
    workspaces: ["proj", "docs"],
    worktrees: option.None,
  )
}

fn orchestrator() -> node_report.OrchestratorFacts {
  OrchestratorFacts(
    capacity: 8,
    occupied: 3,
    resident: 2,
    imports: Receiving,
    executor_nodes: ["box@10.0.0.2"],
    placements: [
      Placement(executor_node: "box@10.0.0.2", resident: 1, saved: 4),
    ],
    moves: [
      MoveFacts(
        session: "s1",
        op: "op1",
        to_node: "bravo@10.0.0.3",
        phase: Waiting,
        stalled_ms: Some(9000),
        reason: Some("the receiver did not answer"),
      ),
      MoveFacts(
        session: "s2",
        op: "op2",
        to_node: "bravo@10.0.0.3",
        phase: Running,
        stalled_ms: None,
        reason: None,
      ),
    ],
  )
}

fn directory(
  ra: Result(store.Membership, store.Unavailable),
) -> node_report.DirectoryFacts {
  DirectoryFacts(
    status: member.Status(
      members: ["alpha@10.0.0.1", "bravo@10.0.0.3"],
      joining: member.Rejoining,
      ra:,
      applied_index: 41,
    ),
    copy: Unconfirmed,
  )
}

fn full() -> NodeReport {
  NodeReport(
    ..node_report.bare(
      "alpha@10.0.0.1",
      "0.3.0",
      "abc123",
      "epoch-1",
      1000,
      9000,
    ),
    peers: ["bravo@10.0.0.3", "box@10.0.0.2"],
    orchestrator: Some(orchestrator()),
    executor: Some(executor()),
    directory: Some(
      directory(
        Ok(
          store.Membership(
            members: [
              #("alpha@10.0.0.1", ffi_khepri.Voter),
              #("bravo@10.0.0.3", ffi_khepri.Promoting),
              #("charlie@10.0.0.4", ffi_khepri.NonVoter),
            ],
            leader: Some("alpha@10.0.0.1"),
            up: ["alpha@10.0.0.1"],
          ),
        ),
      ),
    ),
  )
}

fn through_text(report: NodeReport) -> Result(NodeReport, String) {
  case json.parse(json.to_string(node_report.to_json(report))) {
    Ok(value) -> node_report.decode(value)
    Error(_) -> Error("the rendered report did not parse")
  }
}

pub fn a_full_report_survives_its_rendering_test() {
  assert through_text(full()) == Ok(full())
}

pub fn a_worktree_census_survives_its_rendering_and_an_absent_one_reads_as_none_test() {
  let facts =
    node_report.ExecutorFacts(
      ..executor(),
      worktrees: Some(node_report.WorktreeFacts(
        workspaces: ["proj"],
        present: 2,
        kept: 1,
        branches_left: 7,
        unrecorded: 3,
      )),
    )
  let report = NodeReport(..full(), executor: Some(facts))
  assert through_text(report) == Ok(report)

  // An executor with no worktree workspace omits the member, and a reader
  // takes that as none.
  let assert json.Object(fields) = node_report.executor_json(executor())
  assert list.key_find(fields, "worktrees") == Error(Nil)
  assert node_report.decode_executor(node_report.executor_json(executor()))
    == Ok(executor())
}

pub fn a_worktree_count_that_is_negative_is_refused_test() {
  let facts =
    node_report.ExecutorFacts(
      ..executor(),
      worktrees: Some(node_report.WorktreeFacts(
        workspaces: [],
        present: -1,
        kept: 0,
        branches_left: 0,
        unrecorded: 0,
      )),
    )
  let assert Error(reason) =
    node_report.decode_executor(node_report.executor_json(facts))
  assert string.contains(reason, "present")
}

pub fn an_executor_only_node_has_no_orchestrator_facts_test() {
  let report = NodeReport(..full(), orchestrator: None, directory: None)
  assert through_text(report) == Ok(report)
  let assert json.Object(fields) = node_report.to_json(report)
  assert list.key_find(fields, "orchestrator") == Error(Nil)
  assert list.key_find(fields, "executor") != Error(Nil)
}

pub fn a_directory_that_cannot_say_keeps_its_reason_test() {
  let report =
    NodeReport(
      ..full(),
      directory: Some(directory(Error(store.Unavailable("no quorum in time")))),
    )
  assert through_text(report) == Ok(report)
}

pub fn an_unreported_node_has_only_its_identity_test() {
  let report = node_report.bare("alpha@10.0.0.1", "0.3.0", "abc", "e", 0, 1)
  assert through_text(report) == Ok(report)
  assert report.peers == []
}

// --- bounds ----------------------------------------------------------------------

fn field_set(
  report: NodeReport,
  key: String,
  value: json.JsonValue,
) -> json.JsonValue {
  let assert json.Object(fields) = node_report.to_json(report)
  json.Object([#(key, value), ..list.key_pop(fields, key) |> keep_rest])
}

fn keep_rest(
  popped: Result(#(json.JsonValue, List(#(String, json.JsonValue))), Nil),
) -> List(#(String, json.JsonValue)) {
  case popped {
    Ok(#(_old, rest)) -> rest
    Error(Nil) -> []
  }
}

pub fn a_negative_count_is_refused_with_the_field_named_test() {
  let value = field_set(full(), "started_ms", json.Int(-1))
  assert node_report.decode(value) == Error("started_ms is a negative count")
}

pub fn a_missing_field_is_refused_test() {
  let assert json.Object(fields) = node_report.to_json(full())
  let value = json.Object(list.filter(fields, fn(entry) { entry.0 != "epoch" }))
  assert node_report.decode(value) == Error("epoch is not a string")
}

pub fn too_many_peers_are_refused_test() {
  let peers = list.repeat(json.String("n"), node_report.max_peers + 1)
  let value = field_set(full(), "peers", json.Array(peers))
  assert node_report.decode(value) == Error("peers holds too many entries")
}

pub fn text_past_its_bound_is_refused_test() {
  let value =
    field_set(
      full(),
      "node",
      json.String(string.repeat("n", node_report.max_text_bytes + 1)),
    )
  assert node_report.decode(value)
    == Error("node is longer than the report allows")
}

pub fn a_word_outside_its_set_is_refused_test() {
  let value =
    field_set(
      full(),
      "orchestrator",
      node_report.orchestrator_json(orchestrator())
        |> replace_field("imports", json.String("sometimes")),
    )
  assert node_report.decode(value)
    == Error("imports is not receiving or not_receiving")
}

fn replace_field(
  value: json.JsonValue,
  key: String,
  replacement: json.JsonValue,
) -> json.JsonValue {
  let assert json.Object(fields) = value
  json.Object(
    list.map(fields, fn(entry) {
      case entry.0 == key {
        True -> #(key, replacement)
        False -> entry
      }
    }),
  )
}

pub fn a_directory_with_both_ra_and_unavailable_is_refused_test() {
  let value =
    node_report.directory_json(directory(Error(store.Unavailable("x"))))
  let assert json.Object(fields) = value
  let both = json.Object([#("ra", json.Object([])), ..fields])
  assert node_report.decode_directory(both)
    == Error("directory holds neither or both of ra and unavailable")
}

pub fn an_unknown_cleanup_without_a_count_is_refused_test() {
  let value =
    json.Object([
      #("session", json.String("s")),
      #("state", json.String("unknown_cleanup")),
    ])
  let report_value =
    node_report.executor_json(executor())
    |> replace_field("unclean", json.Array([value]))
  assert node_report.decode_executor(report_value)
    == Error("count is not an integer")
}

// --- reasons ---------------------------------------------------------------------

pub fn a_short_reason_is_kept_whole_test() {
  assert node_report.cut_reason("peer did not answer") == "peer did not answer"
}

pub fn a_long_reason_is_cut_to_its_bound_test() {
  let cut = node_report.cut_reason(string.repeat("a", 500))
  assert string.length(cut) == node_report.max_reason_bytes
}

pub fn a_cut_never_splits_a_character_test() {
  // Each character is three bytes, so 200 bytes holds 66 of them and the 67th
  // is dropped whole.
  let cut = node_report.cut_reason(string.repeat("\u{20AC}", 100))
  assert string.length(cut) == 66
  assert string.to_utf_codepoints(cut) |> list.length == 66
}

pub fn a_reason_past_the_bound_is_refused_on_reading_test() {
  let move =
    node_report.move_json(MoveFacts(
      session: "s",
      op: "o",
      to_node: "b",
      phase: Waiting,
      stalled_ms: Some(1),
      reason: Some(string.repeat("r", node_report.max_reason_bytes + 1)),
    ))
  assert node_report.decode_move(move)
    == Error("reason is longer than the reason bound")
}

pub fn imports_words_round_trip_test() {
  let facts = OrchestratorFacts(..orchestrator(), imports: NotReceiving)
  assert node_report.decode_orchestrator(node_report.orchestrator_json(facts))
    == Ok(facts)
}
