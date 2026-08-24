//// The M2 jailed end-to-end acceptance (spec Part 4): a prompt drives
//// real tool calls through the production wiring — the real provider
//// gateway over a scripted SSE transport, the real ToolBroker over the
//// real Go `loom-exec` helper, and the real tool registry — ending in a
//// final answer, with the durable transcript, the usage ledger, and the
//// on-disk workspace all provably correct. Feature-detected: when the
//// Go toolchain is missing the tests print a skip reason and pass.
////
//// Two scenarios:
////
//// - **Happy path** (four settlements, three tool turns): bash writes
////   `notes.txt` inside the jail, `fs_read` returns its hashline
////   anchors, `fs_edit` applies an anchored replace, and a text answer
////   completes the run. Asserts the byte-exact edited file, the full
////   transcript shape (real exit codes and the helper's honest
////   enforcement report in the tool details), the ledger total against
////   the scripted usage, and a clean close/reopen with an intact
////   transcript.
//// - **Crash rider** (the pi §0.5 scenario live): the whole tree is
////   killed while a jailed `replay: Never` bash call is provably
////   mid-execution; on reboot the interrupted call settles as the
////   synthetic interrupted result under its reserved id and the run
////   completes with the remaining script.

import client/wiring
import core/clock
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import machine/operation
import runtime/api
import session/session.{type Session}
import simplifile
import storage/storage
import support/jail
import support/rig
import support/script
import tools/hashline

pub fn jailed_end_to_end_test() {
  case jail.build_helper() {
    Error(reason) -> io.println("SKIP jailed_end_to_end: " <> reason)
    Ok(helper_path) -> run_happy(helper_path)
  }
}

pub fn crash_mid_tool_recovers_test() {
  case jail.build_helper() {
    Error(reason) -> io.println("SKIP crash_mid_tool_recovers: " <> reason)
    Ok(helper_path) -> run_crash(helper_path)
  }
}

// --- the happy path -------------------------------------------------------

// The byte-exact file the jailed bash write produces, and the content
// after the anchored edit replaces line 2 with two lines.
const notes_before_edit = "alpha\nbeta\n"

const notes_after_edit = "alpha\nbeta improved\ngamma\n"

const answer_text = "The notes file now ends with gamma."

fn happy_turns() -> List(script.Turn) {
  // The edit is scripted against the anchors the bash write must
  // produce; the intervening fs_read turn proves the anchors the script
  // relies on are exactly what the tool reports.
  let beta = hashline.anchor("beta")
  [
    script.ToolUseTurn(
      call_id: "call_bash_1",
      tool: "bash",
      arguments: bash_args("printf 'alpha\\nbeta\\n' > notes.txt"),
      input_tokens: 100,
      output_tokens: 5,
    ),
    script.ToolUseTurn(
      call_id: "call_read_1",
      tool: "fs_read",
      arguments: json.Object([#("path", json.String("notes.txt"))]),
      input_tokens: 110,
      output_tokens: 6,
    ),
    script.ToolUseTurn(
      call_id: "call_edit_1",
      tool: "fs_edit",
      arguments: json.Object([
        #("path", json.String("notes.txt")),
        // The digest binds the plan to the exact pre-image the bash
        // write produces, so a replayed edit cannot apply twice.
        #("digest", json.String(hashline.digest(notes_before_edit))),
        #(
          "hunks",
          json.Array([
            json.Object([
              #("op", json.String("replace")),
              #("from", anchor_ref(2, beta)),
              #("to", anchor_ref(2, beta)),
              #(
                "lines",
                json.Array([
                  json.String("beta improved"),
                  json.String("gamma"),
                ]),
              ),
            ]),
          ]),
        ),
      ]),
      input_tokens: 120,
      output_tokens: 7,
    ),
    script.AnswerTurn(text: answer_text, input_tokens: 130, output_tokens: 8),
  ]
}

fn run_happy(helper_path: String) -> Nil {
  let rig_jail =
    jail.start(
      name: "happy",
      helper_path:,
      pool_size: 2,
      // Behind the wiring clock's era: budget deadlines computed there
      // must still be in this broker clock's future.
      clock: clock.stepping(from: 1_700_000_000_000, by: 7),
    )
  let turns = happy_turns()
  let effects =
    wiring.build_effects(rig.config(rig_jail, rig.scripted_gateway(turns)))
  let options = api.default_options(rig.configuration())
  let assert Ok(sess) = open_session(rig_jail.session_path, "e2e-happy")
  let assert Ok(runtime) = api.open(sess, effects, options)
  let assert Ok(op) =
    api.prompt(runtime, [user("Write notes.txt, then refine it.")])
  let assert Ok(outcome) = api.await_result(runtime, op, within_ms: 120_000)
    as "the happy run must reach a terminal result"
  let assert operation.RunLastResult(
    outcome: operation.RunCompleted(..),
    final_assistant: Some(_),
    ..,
  ) = outcome

  // The jailed bash write plus the anchored edit, byte-exact on disk.
  let assert Ok(content) = simplifile.read(rig_jail.workspace <> "/notes.txt")
  assert content == notes_after_edit

  // The durable transcript: three tool turns and the final answer, with
  // real results throughout.
  let messages = projected(sess)
  let assert [
    message.UserMessage(..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "bash",
      tool_call_id: "call_bash_1",
      is_error: False,
      details: Some(bash_details),
      ..,
    ),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "fs_read",
      tool_call_id: "call_read_1",
      is_error: False,
      content: read_content,
      ..,
    ),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "fs_edit",
      tool_call_id: "call_edit_1",
      is_error: False,
      content: edit_content,
      ..,
    ),
    message.AssistantMessage(
      stop_reason: message.Stop,
      content: final_content,
      ..,
    ),
  ] = messages

  // The bash details carry the helper's real exit report and its honest
  // enforcement ground truth (degraded in this container — no bwrap).
  assert int_field(bash_details, "exit_code") == Ok(0)
  assert int_field(bash_details, "signal") == Ok(0)
  let assert Ok(json.Bool(degraded)) = field(bash_details, "degraded")
  let assert Ok(json.Array(enforcement)) = field(bash_details, "enforcement")
  io.println(
    "e2e enforcement matrix: degraded="
    <> string.inspect(degraded)
    <> " applied="
    <> string.inspect(
      list.filter_map(enforcement, fn(layer) {
        case layer {
          json.String(name) -> Ok(name)
          _ -> Error(Nil)
        }
      }),
    ),
  )

  // The read result rendered the exact anchors the scripted edit used.
  let read_text = first_text(read_content)
  assert string.contains(
    read_text,
    "1:" <> hashline.anchor("alpha") <> "|alpha",
  )
  assert string.contains(read_text, "2:" <> hashline.anchor("beta") <> "|beta")
  assert string.contains(first_text(edit_content), "applied 1 hunk(s)")
  assert answer_of(final_content) == answer_text

  // The ledger equals the scripted usage exactly.
  assert ledger_total(sess) == script.total_usage(turns)

  // Clean close, then reopen from the file with the transcript intact.
  let fingerprints = list.map(messages, fingerprint)
  let assert Ok(Nil) = api.close(runtime)
  let assert Ok(reopened) = open_session(rig_jail.session_path, "e2e-happy-2")
  let assert Ok(runtime2) = api.open(reopened, effects, options)
  assert list.map(projected(reopened), fingerprint) == fingerprints
  let assert Ok(Nil) = api.close(runtime2)
  jail.stop(rig_jail)
}

// --- the crash rider (pi §0.5, live) --------------------------------------

fn run_crash(helper_path: String) -> Nil {
  let rig_jail =
    jail.start(
      name: "crash",
      helper_path:,
      pool_size: 1,
      // Behind the wiring clock's era, as in the happy path.
      clock: clock.stepping(from: 1_700_000_000_000, by: 7),
    )
  let turns = [
    script.ToolUseTurn(
      call_id: "call_bash_c1",
      tool: "bash",
      arguments: bash_args(": > started.marker && sleep 30"),
      input_tokens: 50,
      output_tokens: 5,
    ),
    script.AnswerTurn(
      text: "Recovered and finished the run.",
      input_tokens: 60,
      output_tokens: 6,
    ),
  ]
  let effects =
    wiring.build_effects(rig.config(rig_jail, rig.scripted_gateway(turns)))
  let options = api.default_options(rig.configuration())
  let assert Ok(sess) = open_session(rig_jail.session_path, "e2e-crash")
  let assert Ok(runtime) = api.open(sess, effects, options)
  let assert Ok(op) = api.prompt(runtime, [user("Run the long task.")])

  // Wait until the jailed command is provably mid-execution (its marker
  // exists), so the kill lands with the tool intent durable and the
  // external effect genuinely in flight.
  assert wait_for_file(rig_jail.workspace <> "/started.marker", 30_000)
    as "the jailed bash command must start before the kill"

  // The whole-tree kill: close kills the supervision tree (durable
  // state stops at a commit boundary) and releases the lease. The
  // hanging bash keeps running in its jail — exactly the pi §0.5 crash
  // position for a `replay: Never` tool.
  let assert Ok(Nil) = api.close(runtime)

  // Reboot from the file: recovery finds the effect-pending call with
  // no live continuation, `replay: Never` forbids re-execution, and the
  // synthetic interrupted result settles under the reserved id; the
  // remaining script then completes the run.
  let assert Ok(reopened) = open_session(rig_jail.session_path, "e2e-crash-2")
  let assert Ok(runtime2) = api.open(reopened, effects, options)
  let assert Ok(outcome) = api.await_result(runtime2, op, within_ms: 60_000)
    as "the recovered run must reach a terminal result"
  let assert operation.RunLastResult(outcome: operation.RunCompleted(..), ..) =
    outcome

  let messages = projected(reopened)
  let assert [
    message.UserMessage(..),
    message.AssistantMessage(stop_reason: message.ToolUse, ..),
    message.ToolResultMessage(
      tool_name: "bash",
      tool_call_id: "call_bash_c1",
      is_error: True,
      content: interrupted_content,
      ..,
    ),
    message.AssistantMessage(
      stop_reason: message.Stop,
      content: final_content,
      ..,
    ),
  ] = messages
  assert string.contains(first_text(interrupted_content), "interrupted")
  assert answer_of(final_content) == "Recovered and finished the run."

  // Both settlements committed usage exactly once each, crash included.
  assert ledger_total(reopened) == script.total_usage(turns)

  let assert Ok(Nil) = api.close(runtime2)
  jail.stop(rig_jail)
}

// --- fixtures and helpers -------------------------------------------------

fn bash_args(command: String) -> JsonValue {
  json.Object([
    #("command", json.String(command)),
    #("timeout_ms", json.Int(30_000)),
  ])
}

fn anchor_ref(line: Int, anchor: String) -> JsonValue {
  json.Object([#("line", json.Int(line)), #("anchor", json.String(anchor))])
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

fn open_session(
  path: String,
  owner: String,
) -> Result(Session, session.OpenError) {
  session.open_sqlite(
    path:,
    owner:,
    lease_ttl_ms: 60_000,
    clock: clock.stepping(from: 1_700_000_300_000, by: 11),
  )
}

fn projected(sess: Session) -> List(message.AgentMessage) {
  let leaf = case session.strand_leaf(sess, "main") {
    Ok(Some(session.Cell(value: leaf, ..))) -> leaf
    _ -> None
  }
  let assert Ok(messages) = session.project_context(sess, leaf)
    as "the projection must read cleanly"
  messages
}

fn ledger_total(sess: Session) -> Int {
  let assert Ok(rows) = storage.scan_usage(sess.store, storage.usage_scan())
    as "the ledger must read cleanly"
  list.fold(rows, 0, fn(total, row) { total + row.usage.total_tokens })
}

fn wait_for_file(path: String, remaining_ms: Int) -> Bool {
  case simplifile.is_file(path) {
    Ok(True) -> True
    _ ->
      case remaining_ms <= 0 {
        True -> False
        False -> {
          process.sleep(20)
          wait_for_file(path, remaining_ms - 20)
        }
      }
  }
}

fn first_text(content: List(message.ToolResultBlock)) -> String {
  case content {
    [message.ToolResultText(text:, ..), ..] -> text
    _ -> ""
  }
}

fn answer_of(content: List(message.AssistantBlock)) -> String {
  case content {
    [message.AssistantText(text:, ..), ..] -> text
    _ -> ""
  }
}

// A structural fingerprint (roles, stop kinds, call ids, texts) — never
// minted ids or timestamps, which legitimately differ across reopens.
fn fingerprint(msg: message.AgentMessage) -> String {
  case msg {
    message.UserMessage(content:, ..) ->
      "user:"
      <> string.join(
        list.map(content, fn(block) {
          case block {
            message.UserText(text:, ..) -> text
            message.UserImage(..) -> "<image>"
          }
        }),
        "|",
      )
    message.AssistantMessage(content:, stop_reason:, ..) ->
      "assistant:"
      <> string.inspect(stop_reason)
      <> ":"
      <> string.join(
        list.map(content, fn(block) {
          case block {
            message.AssistantText(text:, ..) -> text
            message.AssistantThinking(..) -> "<thinking>"
            message.AssistantToolCall(call:) ->
              "call(" <> call.id <> ")" <> call.name
          }
        }),
        "|",
      )
    message.ToolResultMessage(tool_name:, tool_call_id:, is_error:, ..) ->
      "tool:"
      <> tool_name
      <> ":"
      <> tool_call_id
      <> ":"
      <> string.inspect(is_error)
    message.CustomMessage(schema:, ..) -> "custom:" <> schema
  }
}

fn field(details: JsonValue, key: String) -> Result(JsonValue, Nil) {
  case details {
    json.Object(fields:) ->
      list.find_map(fields, fn(entry) {
        case entry.0 == key {
          True -> Ok(entry.1)
          False -> Error(Nil)
        }
      })
    _ -> Error(Nil)
  }
}

fn int_field(details: JsonValue, key: String) -> Result(Int, Nil) {
  case field(details, key) {
    Ok(json.Int(value)) -> Ok(value)
    _ -> Error(Nil)
  }
}
