//// Internal write/expectation builders shared by acceptance, the queue
//// helpers, and the planner.
////
//// Everything here is pure construction of `core/tx` values: register
//// writes carrying encoded machine payloads, entry inserts with
//// storage-assigned fields left as placeholders, and the deterministic
//// register keys pi's spec derives from ids (`{op}:{step}:{index}`,
//// `{op}:{task}`).

import core/entry.{UsageRow}
import core/ids.{type EntryId, type OpId, type Seq, type UsageId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage, type Usage, Usage, UsageCost}
import core/register.{type RegisterNs}
import core/tx.{type SeqExpectation, type Write, Expect}
import gleam/int
import gleam/option.{type Option, None, Some}
import machine/codec
import machine/operation.{
  type LastResult, type Operation, type OperationState, type PendingEntry,
  type StructuralPreparation,
}
import machine/strand.{type StrandState}

// --- keys ----------------------------------------------------------------

/// The `op.*` register key for an operation.
pub fn op_key(operation: OpId) -> String {
  ids.op_id_to_string(operation)
}

/// The `op.tool_args` key: `{op}:{step}:{index}`.
pub fn tool_args_key(operation: OpId, step_id: String, index: Int) -> String {
  ids.op_id_to_string(operation)
  <> ":"
  <> step_id
  <> ":"
  <> int.to_string(index)
}

/// The `op.preparation` key: `{op}:{task}`.
pub fn preparation_key(operation: OpId, task_id: String) -> String {
  ids.op_id_to_string(operation) <> ":" <> task_id
}

/// The `pending.entry` key for a reserved entry id.
pub fn pending_key(entry: EntryId) -> String {
  ids.entry_id_to_string(entry)
}

// --- register writes ------------------------------------------------------

fn set(ns: RegisterNs, key: String, payload: JsonValue) -> Write {
  tx.SetRegister(ns:, key:, value: register.value(payload))
}

/// Sets `op.state/{op}` to the encoded state — the durable program
/// counter write present in every transition.
pub fn set_op_state(operation: OpId, state: OperationState) -> Write {
  set(register.OpState, op_key(operation), codec.encode_state(state))
}

/// Sets the write-once `op.meta/{op}`.
pub fn set_op_meta(operation: Operation) -> Write {
  set(register.OpMeta, op_key(operation.id), codec.encode_operation(operation))
}

/// Sets the write-once `op.preparation/{op}:{task}`.
pub fn set_preparation(
  operation: OpId,
  task_id: String,
  preparation: StructuralPreparation,
) -> Write {
  set(
    register.OpPreparation,
    preparation_key(operation, task_id),
    codec.encode_preparation(preparation),
  )
}

/// Sets the write-once `op.tool_args/{op}:{step}:{index}`.
pub fn set_tool_args(
  operation: OpId,
  step_id: String,
  index: Int,
  arguments: JsonValue,
) -> Write {
  set(register.OpToolArgs, tool_args_key(operation, step_id, index), arguments)
}

/// Sets `pending.entry/{id}`.
pub fn set_pending(entry: EntryId, pending: PendingEntry) -> Write {
  set(
    register.PendingEntry,
    pending_key(entry),
    codec.encode_pending_entry(pending),
  )
}

/// Deletes `pending.entry/{id}`.
pub fn delete_pending(entry: EntryId) -> Write {
  tx.DeleteRegister(ns: register.PendingEntry, key: pending_key(entry))
}

/// Sets `strand.leaf/{strand}`.
pub fn set_leaf(strand_name: String, leaf: Option(EntryId)) -> Write {
  tx.SetRegister(
    ns: register.StrandLeaf,
    key: strand_name,
    value: register.leaf_value(leaf),
  )
}

/// Sets `strand.state/{strand}`.
pub fn set_strand_state(strand_name: String, state: StrandState) -> Write {
  set(register.StrandState, strand_name, codec.encode_strand_state(state))
}

/// Sets `strand.last_result/{strand}` — written only by terminal
/// transactions.
pub fn set_last_result(strand_name: String, result: LastResult) -> Write {
  set(register.StrandLastResult, strand_name, codec.encode_last_result(result))
}

/// Deletes `op.meta/{op}` (terminal cleanup).
pub fn delete_op_meta(operation: OpId) -> Write {
  tx.DeleteRegister(ns: register.OpMeta, key: op_key(operation))
}

/// Deletes `op.state/{op}` (terminal cleanup).
pub fn delete_op_state(operation: OpId) -> Write {
  tx.DeleteRegister(ns: register.OpState, key: op_key(operation))
}

/// Deletes one `op.tool_args` register by its full key.
pub fn delete_tool_args_key(key: String) -> Write {
  tx.DeleteRegister(ns: register.OpToolArgs, key:)
}

/// Deletes one `op.preparation` register by its full key.
pub fn delete_preparation_key(key: String) -> Write {
  tx.DeleteRegister(ns: register.OpPreparation, key:)
}

/// Sets `fact.label/{entry}` — navigation label publication.
pub fn set_entry_label(entry: EntryId, label: String) -> Write {
  set(register.FactLabel, ids.entry_id_to_string(entry), json.String(label))
}

// --- expectations ---------------------------------------------------------

/// Expects `op.state/{op}` at the seq the planner read.
pub fn expect_op_state(operation: OpId, seq: Seq) -> SeqExpectation {
  Expect(ns: register.OpState, key: op_key(operation), seq: Some(seq))
}

/// Expects `op.state/{op}` (and `op.meta`) to not exist yet — acceptance.
pub fn expect_op_absent(operation: OpId) -> List(SeqExpectation) {
  [
    Expect(ns: register.OpMeta, key: op_key(operation), seq: None),
    Expect(ns: register.OpState, key: op_key(operation), seq: None),
  ]
}

/// Expects `strand.state/{strand}` at the seq the planner read.
pub fn expect_strand_state(strand_name: String, seq: Seq) -> SeqExpectation {
  Expect(ns: register.StrandState, key: strand_name, seq: Some(seq))
}

/// Expects `strand.config/{strand}` at the seq the snapshot was taken
/// from.
pub fn expect_configuration(strand_name: String, seq: Seq) -> SeqExpectation {
  Expect(ns: register.StrandConfig, key: strand_name, seq: Some(seq))
}

// --- entries --------------------------------------------------------------

/// Builds a message-entry insert. `seq` and `ts` are placeholders —
/// storage assigns both at commit.
pub fn message_entry(
  id: EntryId,
  parent: Option(EntryId),
  message: AgentMessage,
  terminate: Bool,
) -> Write {
  tx.InsertEntry(entry.MessageEntry(
    id:,
    parent:,
    seq: 0,
    ts: 0,
    message:,
    terminate:,
  ))
}

/// Builds a custom-entry insert.
pub fn custom_entry(
  id: EntryId,
  parent: Option(EntryId),
  custom_type: String,
  data: Option(JsonValue),
) -> Write {
  tx.InsertEntry(entry.CustomEntry(
    id:,
    parent:,
    seq: 0,
    ts: 0,
    custom_type:,
    data:,
  ))
}

/// Builds a compaction-entry insert.
pub fn compaction_entry(
  id: EntryId,
  parent: Option(EntryId),
  summary: String,
  retained_tail: List(AgentMessage),
  tokens_before: Int,
  from_hook: Bool,
  usage: Option(Usage),
) -> Write {
  tx.InsertEntry(entry.CompactionEntry(
    id:,
    parent:,
    seq: 0,
    ts: 0,
    summary:,
    retained_tail:,
    tokens_before:,
    from_hook:,
    usage:,
  ))
}

/// Builds a branch-summary-entry insert.
pub fn branch_summary_entry(
  id: EntryId,
  parent: Option(EntryId),
  from_id: EntryId,
  summary: String,
  from_hook: Bool,
  usage: Option(Usage),
) -> Write {
  tx.InsertEntry(entry.BranchSummaryEntry(
    id:,
    parent:,
    seq: 0,
    ts: 0,
    from_id: Some(from_id),
    summary:,
    from_hook:,
    usage:,
  ))
}

/// Builds a usage-row insert. `seq` is a placeholder.
pub fn usage_row(
  id: UsageId,
  entry_id: Option(EntryId),
  usage: Usage,
) -> Write {
  tx.InsertUsage(UsageRow(
    id:,
    seq: 0,
    entry_id:,
    adjustment: False,
    usage:,
    details: None,
  ))
}

/// A zero usage value, for synthetic settlements.
pub fn zero_usage() -> Usage {
  Usage(
    input: 0,
    output: 0,
    cache_read: 0,
    cache_write: 0,
    cache_write_1h: None,
    reasoning: None,
    total_tokens: 0,
    cost: UsageCost(
      input: 0.0,
      output: 0.0,
      cache_read: 0.0,
      cache_write: 0.0,
      total: 0.0,
    ),
  )
}
