//// The resident side of `session.brief` (protocol-change/125): what a session
//// reports of its recent work, and the bounds that keep the reply small.
////
//// The window logic is tested over synthetic entries, so each rule has an
//// entry that proves it: the latest text is the newest assistant message that
//// has any, a step's outcome is what its result envelope said, a peer message
//// is a user message whose author is a peer after the time named, and the last
//// command is the newest `bash` call whose result carried an exit status. The
//// read itself runs against a real runtime.

import client/goalstate
import client/internal/ffi_os
import client/peer_mail
import client/session_brief
import core/accounting
import core/clock
import core/entry
import core/ids
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import session/session
import simplifile
import web_view/session_brief as wire

fn id(at: Int) -> ids.EntryId {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(at:), seed: at))
  id
}

fn assistant(at: Int, blocks: List(message.AssistantBlock)) -> entry.Entry {
  entry.MessageEntry(
    id: id(at),
    parent: None,
    seq: at,
    ts: at,
    message: message.AssistantMessage(
      content: blocks,
      api: "x",
      provider: "p",
      model: "m",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: accounting.zero_usage(),
      stop_reason: message.Stop,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: at,
    ),
    terminate: False,
  )
}

fn text(words: String) -> message.AssistantBlock {
  message.AssistantText(text: words, text_signature: None)
}

fn call(name: String, call_id: String, arguments: JsonValue) {
  message.AssistantToolCall(message.ToolCall(
    id: call_id,
    name:,
    arguments:,
    thought_signature: None,
    namespace: None,
  ))
}

fn result(
  at: Int,
  call_id: String,
  failed: Bool,
  details: option.Option(JsonValue),
) -> entry.Entry {
  entry.MessageEntry(
    id: id(at),
    parent: None,
    seq: at,
    ts: at,
    message: message.ToolResultMessage(
      tool_call_id: call_id,
      tool_name: "bash",
      content: [],
      details:,
      usage: None,
      added_tool_names: None,
      is_error: failed,
      timestamp: at,
    ),
    terminate: False,
  )
}

fn user(at: Int, words: String, origin) -> entry.Entry {
  entry.MessageEntry(
    id: id(at),
    parent: None,
    seq: at,
    ts: at,
    message: message.UserMessage(
      content: [message.UserText(text: words, text_signature: None)],
      timestamp: at,
      origin:,
    ),
    terminate: False,
  )
}

fn bash(command: String) -> JsonValue {
  json.Object([#("command", json.String(command))])
}

fn exited(code: Int) -> option.Option(JsonValue) {
  Some(json.Object([#("exit_code", json.Int(code))]))
}

pub fn the_latest_text_is_the_newest_assistant_message_that_has_any_test() {
  let newest_first = [
    assistant(30, [call("bash", "c1", bash("make"))]),
    assistant(20, [text("  Looking\n at it.  ")]),
    assistant(10, [text("Older.")]),
  ]
  let brief = session_brief.of_window(newest_first, 0)
  let assert Some(wire.Assistant(text:, at:)) = brief.assistant
  assert wire.untrusted_text(text) == "Looking\n at it."
  assert at == 20
}

pub fn a_step_is_worded_by_the_pages_own_words_and_its_result_test() {
  // Oldest first: a finished failing call, a finished one, and one still going.
  let newest_first = [
    assistant(50, [call("bash", "c3", bash("sleep 60"))]),
    result(41, "c2", False, exited(0)),
    assistant(40, [call("bash", "c2", bash("make check-core"))]),
    result(31, "c1", True, exited(2)),
    assistant(30, [call("bash", "c1", bash("make check-web_view"))]),
  ]
  let brief = session_brief.of_window(newest_first, 0)
  let assert [running, ok, failed] = brief.steps
  assert running.outcome == wire.Running
  assert wire.untrusted_text(running.words) == "Running sleep 60"
  assert ok.outcome == wire.Succeeded
  assert wire.untrusted_text(ok.words) == "Ran make check-core"
  assert failed.outcome == wire.Failed
  assert failed.at == 30
  assert wire.untrusted_text(failed.tool) == "bash"
}

pub fn at_most_four_steps_are_listed_newest_first_test() {
  let newest_first =
    list.map(list.reverse(upto(10)), fn(index) {
      assistant(index * 10, [
        call("bash", "c" <> int.to_string(index), bash("true")),
      ])
    })
  let brief = session_brief.of_window(newest_first, 0)
  assert list.map(brief.steps, fn(step) { step.at }) == [100, 90, 80, 70]
}

pub fn the_last_command_is_a_fact_with_its_exit_status_test() {
  let newest_first = [
    assistant(60, [call("fs_read", "c4", json.Object([]))]),
    result(51, "c3", False, None),
    assistant(50, [call("bash", "c3", bash("echo no status"))]),
    result(41, "c2", True, exited(2)),
    assistant(40, [call("bash", "c2", bash("make check-core"))]),
  ]
  let brief = session_brief.of_window(newest_first, 0)
  let assert Some(wire.Command(command:, exit:, at:)) = brief.command
  assert wire.untrusted_text(command) == "make check-core"
  assert exit == 2
  assert at == 40
}

pub fn only_peer_messages_after_the_time_named_are_listed_test() {
  let peer = fn(session, strand) { Some(message.PeerOrigin(session:, strand:)) }
  let newest_first = [
    user(90, "from a person", Some(message.Origin("p", "Pat"))),
    user(80, "newest peer", peer("s-2", "main")),
    user(70, "from a strand", Some(message.StrandOrigin("sub:main/x"))),
    user(60, "middle peer", peer("s-3", "main")),
    user(50, "old peer", peer("s-4", "main")),
  ]
  let brief = session_brief.of_window(newest_first, 55)
  let assert [first, second] = brief.peers
  assert first.session == "s-2"
  assert wire.untrusted_text(first.text) == "newest peer"
  assert first.at == 80
  assert second.session == "s-3"

  // Zero names no time, so the latest are listed, at most three.
  let all = session_brief.of_window(newest_first, 0)
  assert list.length(all.peers) == 3
}

pub fn every_text_and_list_is_bounded_test() {
  let long = string.repeat("é", 2000)
  let calls = [
    result(81, "c8", False, exited(0)),
    ..list.map(list.reverse(upto(8)), fn(index) {
      assistant(index * 10, [
        call("bash", "c" <> int.to_string(index), bash(long)),
      ])
    })
  ]
  let peers =
    list.map(upto(8), fn(index) {
      user(
        100 + index,
        long,
        Some(message.PeerOrigin(session: long, strand: long)),
      )
    })
  let brief =
    session_brief.of_window(
      list.flatten([[assistant(500, [text(long)])], calls, peers]),
      0,
    )
  let assert Some(wire.Assistant(text:, ..)) = brief.assistant
  assert string.byte_size(wire.untrusted_text(text)) <= wire.assistant_bytes
  assert list.length(brief.steps) <= wire.max_steps
  assert list.length(brief.peers) <= wire.max_peers
  list.each(brief.steps, fn(step) {
    assert string.byte_size(wire.untrusted_text(step.words)) <= wire.words_bytes
  })
  list.each(brief.peers, fn(peer) {
    assert string.byte_size(wire.untrusted_text(peer.text)) <= wire.peer_bytes
    assert string.byte_size(peer.session) <= wire.strand_bytes
  })
  let assert Some(wire.Command(command:, ..)) = brief.command
  assert string.byte_size(wire.untrusted_text(command)) <= wire.command_bytes
}

// A brief whose items escape badly is shed, strands first, until its encoding
// fits, and a brief that already fits is returned as it is.
pub fn a_brief_over_the_bound_sheds_its_strands_first_test() {
  let strand = fn(index) {
    wire.Strand(
      name: string.repeat("\u{1}", wire.strand_bytes) <> int.to_string(index),
      state: wire.Working,
      since: Some(index),
    )
  }
  let peer = fn(index) {
    wire.Peer(
      session: "s",
      strand: "main",
      at: index,
      text: wire.untrusted(string.repeat("\u{1}", wire.peer_bytes)),
    )
  }
  let bulky =
    wire.Brief(
      assistant: Some(wire.Assistant(
        text: wire.untrusted(string.repeat("\u{1}", wire.assistant_bytes)),
        at: 1,
      )),
      steps: [],
      strands: list.map(upto(wire.max_strands), strand),
      goal: None,
      peers: list.map(upto(wire.max_peers), peer),
      command: None,
    )
  let shed = session_brief.shed(bulky)
  assert string.byte_size(json.to_string(wire.to_json(shed)))
    <= wire.brief_bytes
  assert list.length(shed.strands) < wire.max_strands
  assert shed.peers == bulky.peers
  assert shed.assistant == bulky.assistant

  let small = wire.Brief(..bulky, strands: [], peers: [], assistant: None)
  assert session_brief.shed(small) == small
}

// --- against a real runtime --------------------------------------------------

const now = 1_790_000_000_000

fn open() -> api.Runtime {
  let directory =
    "build/session-brief-test-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(directory)
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the scratch directory is made"
  let time = clock.fixed(at: now)
  let assert Ok(opened) =
    session.open_sqlite(
      directory <> "/session.db",
      "session-brief-test",
      30_000,
      time,
    )
    as "the SQLite session must open"
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: [],
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

fn brief_of(runtime: api.Runtime, since: Int) -> wire.Brief {
  let assert Ok(reply) =
    peer_mail.handle(runtime, clock.fixed(0), peer_mail.SessionBrief(since))
    as "the resident answers its own brief"
  let assert Ok(brief) = wire.decode(reply) as "the reply decodes"
  brief
}

// An empty session has nothing to report, and the read does not fail on it.
pub fn an_empty_session_reports_nothing_test() {
  let runtime = open()
  let brief = brief_of(runtime, 0)
  assert brief.assistant == None
  assert brief.steps == []
  assert brief.peers == []
  assert brief.goal == None
  assert brief.command == None
  let assert Ok(Nil) = api.close(runtime)
}

// A peer message that starts a run is read back from the real store's branch,
// the strand is working since its operation began, and the goal cell is read
// with its budget.
pub fn a_peer_message_a_working_strand_and_a_goal_are_read_back_test() {
  let runtime = open()
  let peer =
    message.UserMessage(
      content: [
        message.UserText(text: "Does it need write?", text_signature: None),
      ],
      timestamp: now,
      origin: Some(message.PeerOrigin(session: "s-9", strand: "main")),
    )
  let assert Ok(operation) = api.prompt(runtime, [peer])
    as "the prompt is accepted"
  let goal =
    goalstate.new("land the migration", 400_000, now, accounted_from: 0)
  let assert Ok(Nil) =
    api.put_reserved_fact(runtime, "goal/state", goalstate.encode(goal))
    as "the goal is written"

  let brief = brief_of(runtime, 0)
  let assert [first] = brief.peers
  assert first.session == "s-9"
  assert first.strand == "main"
  assert wire.untrusted_text(first.text) == "Does it need write?"

  // A time after the message lists nothing.
  assert brief_of(runtime, first.at).peers == []

  let assert [
    wire.Strand(name: "main", state: wire.Working, since: Some(since)),
  ] = brief.strands
  assert since == ids.op_id_timestamp_ms(operation)
  let assert Some(wire.Goal(objective:, status:, tokens_used:, token_budget:)) =
    brief.goal
  assert objective == "land the migration"
  assert status == "active"
  assert tokens_used == 0
  assert token_budget == 400_000
  api.abort(runtime)
}

/// The integers from 1 to `n`.
fn upto(n: Int) -> List(Int) {
  list.index_map(list.repeat(Nil, n), fn(_, index) { index + 1 })
}
