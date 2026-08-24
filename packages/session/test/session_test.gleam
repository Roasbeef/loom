import core/clock
import core/entry.{CompactionEntry, CustomEntry, MessageEntry}
import core/ids
import core/json as core_json
import core/message.{
  AssistantMessage, AssistantText, ToolResultMessage, ToolResultText,
  UserMessage, UserText,
}
import core/register as core_register
import core/tx.{InsertEntry, SetRegister, Tx}
import gleam/option.{None, Some}
import gleeunit
import machine/strand.{
  ModelIdentity, StrandConfiguration, StrandState, ThinkingOff,
}
import session/session
import storage/storage

pub fn main() -> Nil {
  gleeunit.main()
}

fn configuration() -> strand.StrandConfiguration {
  StrandConfiguration(
    model: ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: ThinkingOff,
    active_tool_names: [],
  )
}

fn generator() -> ids.Generator {
  ids.generator(clock.fixed(at: 1000), seed: 7)
}

fn user(text: String) -> message.AgentMessage {
  UserMessage(content: [UserText(text:, text_signature: None)], timestamp: 0)
}

fn assistant(text: String, stop: message.StopReason) -> message.AgentMessage {
  AssistantMessage(
    content: [AssistantText(text:, text_signature: None)],
    api: "fake",
    provider: "acme",
    model: "loom-1",
    response_model: None,
    response_id: None,
    diagnostics: None,
    usage: message.Usage(
      input: 0,
      output: 0,
      cache_read: 0,
      cache_write: 0,
      cache_write_1h: None,
      reasoning: None,
      total_tokens: 0,
      cost: message.UsageCost(
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 0.0,
      ),
    ),
    stop_reason: stop,
    deferred: None,
    error_message: None,
    raw_stop_reason: None,
    end_turn: None,
    timestamp: 0,
  )
}

// --- pure projection ------------------------------------------------------

pub fn project_scan_empty_test() {
  assert session.project_scan([]) == []
}

pub fn project_scan_drops_error_aborted_deferred_test() {
  let generator = generator()
  let #(a, generator) = ids.mint_entry(generator)
  let #(b, generator) = ids.mint_entry(generator)
  let #(c, generator) = ids.mint_entry(generator)
  let #(d, generator) = ids.mint_entry(generator)
  let #(e, _generator) = ids.mint_entry(generator)
  // Newest-first scan order; oldest is the user prompt.
  let scanned = [
    MessageEntry(
      id: a,
      parent: Some(b),
      seq: 5,
      ts: 5,
      message: assistant("kept", message.Stop),
      terminate: False,
    ),
    MessageEntry(
      id: b,
      parent: Some(c),
      seq: 4,
      ts: 4,
      message: assistant("deferred", message.Deferred),
      terminate: False,
    ),
    MessageEntry(
      id: c,
      parent: Some(d),
      seq: 3,
      ts: 3,
      message: assistant("aborted", message.Aborted),
      terminate: False,
    ),
    MessageEntry(
      id: d,
      parent: Some(e),
      seq: 2,
      ts: 2,
      message: assistant("errored", message.Errored),
      terminate: False,
    ),
    MessageEntry(
      id: e,
      parent: None,
      seq: 1,
      ts: 1,
      message: user("hello"),
      terminate: False,
    ),
  ]
  assert session.project_scan(scanned)
    == [user("hello"), assistant("kept", message.Stop)]
}

pub fn project_scan_length_is_retained_test() {
  let #(a, _generator) = ids.mint_entry(generator())
  let scanned = [
    MessageEntry(
      id: a,
      parent: None,
      seq: 1,
      ts: 1,
      message: assistant("truncated", message.Length),
      terminate: False,
    ),
  ]
  assert session.project_scan(scanned)
    == [assistant("truncated", message.Length)]
}

pub fn project_scan_compaction_opens_context_test() {
  let generator = generator()
  let #(a, generator) = ids.mint_entry(generator)
  let #(b, _generator) = ids.mint_entry(generator)
  let retained = [user("tail message")]
  // Newest-first: the compaction terminated the scan, so it is last.
  let scanned = [
    MessageEntry(
      id: a,
      parent: Some(b),
      seq: 9,
      ts: 9,
      message: assistant("after", message.Stop),
      terminate: False,
    ),
    CompactionEntry(
      id: b,
      parent: None,
      seq: 8,
      ts: 8,
      summary: "everything so far",
      retained_tail: retained,
      tokens_before: 1234,
      from_hook: False,
      usage: None,
    ),
  ]
  assert session.project_scan(scanned)
    == [
      UserMessage(
        content: [
          UserText(text: "everything so far", text_signature: None),
        ],
        timestamp: 8,
      ),
      user("tail message"),
      assistant("after", message.Stop),
    ]
}

pub fn project_scan_skips_custom_entries_test() {
  let #(a, _generator) = ids.mint_entry(generator())
  let scanned = [
    CustomEntry(
      id: a,
      parent: None,
      seq: 1,
      ts: 1,
      custom_type: "note",
      data: None,
    ),
  ]
  assert session.project_scan(scanned) == []
}

pub fn project_scan_keeps_tool_results_test() {
  let #(a, _generator) = ids.mint_entry(generator())
  let result =
    ToolResultMessage(
      tool_call_id: "c1",
      tool_name: "read",
      content: [ToolResultText(text: "data", text_signature: None)],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: True,
      timestamp: 0,
    )
  let scanned = [
    MessageEntry(
      id: a,
      parent: None,
      seq: 1,
      ts: 1,
      message: result,
      terminate: False,
    ),
  ]
  // Tool results stay in context even when they are error results — only
  // assistant responses are dropped by the standard rule.
  assert session.project_scan(scanned) == [result]
}

// --- boot bookkeeping and typed access ------------------------------------

pub fn ensure_strand_seeds_once_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(sess, "main", configuration())
  let assert Ok(Some(session.Cell(value: config, ..))) =
    session.strand_configuration(sess, "main")
  assert config == configuration()
  let assert Ok(Some(session.Cell(value: state, seq: first_seq))) =
    session.strand_state(sess, "main")
  assert state == StrandState(current_operation: None, pending_next_run: [])
  let assert Ok(Some(session.Cell(value: leaf, ..))) =
    session.strand_leaf(sess, "main")
  assert leaf == None
  // A second ensure is a no-op: the state cell's seq is unchanged.
  let assert Ok(Nil) = session.ensure_strand(sess, "main", configuration())
  let assert Ok(Some(session.Cell(seq: second_seq, ..))) =
    session.strand_state(sess, "main")
  assert second_seq == first_seq
}

pub fn project_context_reads_the_branch_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let generator = generator()
  let #(a, generator) = ids.mint_entry(generator)
  let #(b, _generator) = ids.mint_entry(generator)
  let assert Ok(_) =
    storage.commit(
      sess.store,
      Tx(
        writes: [
          InsertEntry(entry: MessageEntry(
            id: a,
            parent: None,
            seq: 0,
            ts: 0,
            message: user("hello"),
            terminate: False,
          )),
          InsertEntry(entry: MessageEntry(
            id: b,
            parent: Some(a),
            seq: 0,
            ts: 0,
            message: assistant("answer", message.Stop),
            terminate: False,
          )),
        ],
        expected: [],
      ),
    )
  let assert Ok(projected) = session.project_context(sess, Some(b))
  assert projected == [user("hello"), assistant("answer", message.Stop)]
  let assert Ok(empty) = session.project_context(sess, None)
  assert empty == []
}

pub fn last_result_absent_on_fresh_strand_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(Nil) = session.ensure_strand(sess, "main", configuration())
  let assert Ok(None) = session.last_result(sess, "main")
  let assert Ok(None) = session.op_meta(sess, mint_op())
  let assert Ok(None) = session.op_state(sess, mint_op())
}

fn mint_op() -> ids.OpId {
  let #(op, _generator) = ids.mint_op(generator())
  op
}

pub fn register_keys_prefix_test() {
  let assert Ok(sess) = session.open_memory(clock.fixed(at: 1000))
  let assert Ok(_) =
    storage.commit(
      sess.store,
      Tx(
        writes: [
          SetRegister(
            ns: core_register_tool_args(),
            key: "op-a:s1:0",
            value: core_register_value(),
          ),
          SetRegister(
            ns: core_register_tool_args(),
            key: "op-b:s1:0",
            value: core_register_value(),
          ),
        ],
        expected: [],
      ),
    )
  let assert Ok(keys) =
    session.register_keys(sess, core_register_tool_args(), "op-a")
  assert keys == ["op-a:s1:0"]
}

fn core_register_tool_args() -> core_register.RegisterNs {
  core_register.OpToolArgs
}

fn core_register_value() -> core_register.RegisterValue {
  core_register.value(core_json.Object([]))
}
