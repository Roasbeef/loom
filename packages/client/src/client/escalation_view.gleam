//// A durable escalation record as the protocol carries it.
////
//// The gateway shows a record to its operators as an event, as a snapshot row and
//// as the record a refused approval hands back. A delegate session shows the same
//// record to its parent's operator over the orchestrator port
//// (protocol-change/089). All of them go through `view`, the single place the
//// durable shape and the wire shape are bridged, so they can never disagree about
//// one record.
////
//// ## Flow
////
//// `view` → `attribution` → `status_name` → `denial`
////
//// 1. `view` builds the wire record from a durable one and the register `seq` it
////    was read at.
//// 2. `attribution` reads the operation and strand off the record's own scope.
//// 3. `status_name` words the status, and `denial` the stored denial.

import broker/escalation as broker_escalation
import client/grants
import client/protocol
import core/ids
import core/json.{type JsonValue}
import gleam/option.{type Option, None, Some}
import runtime/escalation as runtime_escalation

/// One durable record as the protocol carries it.
///
/// The denial rides only on a pending record: on any other status there is
/// nothing left to decide, and a client that showed the diff again would be
/// inviting an answer to a closed question. The record has no placement, which is
/// a fact about the parent's view of a child elsewhere and is added there.
///
/// ## Examples
///
/// ```gleam
/// // escalation_view.view(cell.record, cell.seq).status == "pending"
/// ```
pub fn view(
  record: runtime_escalation.Escalation,
  seq: Int,
) -> protocol.EscalationRecord {
  let #(op, strand) = attribution(record)
  protocol.EscalationRecord(
    escalation_id: record.id,
    seq:,
    origin: record.origin,
    op:,
    strand:,
    status: status_name(record.status),
    tool: option.unwrap(record.tool, ""),
    action: option.unwrap(record.action, ""),
    preview: option.unwrap(record.preview, ""),
    asked: record.asked,
    denial: case record.status {
      runtime_escalation.Pending -> denial(record.denial)
      runtime_escalation.Approved
      | runtime_escalation.Rejected
      | runtime_escalation.Consumed -> None
    },
    placement: None,
    admitted: None,
  )
}

/// The operation and strand a record names, off its own `CallScope`. A record
/// that names no call is the only thing that answers empty.
///
/// ## Examples
///
/// ```gleam
/// assert escalation_view.attribution(record_without_scope) == #("", "")
/// ```
pub fn attribution(record: runtime_escalation.Escalation) -> #(String, String) {
  case record.scope {
    None -> #("", "")
    Some(scope) -> #(ids.op_id_to_string(scope.operation), scope.strand)
  }
}

/// A status as the wire spells it.
///
/// ## Examples
///
/// ```gleam
/// assert escalation_view.status_name(runtime_escalation.Pending) == "pending"
/// ```
pub fn status_name(status: runtime_escalation.Status) -> String {
  case status {
    runtime_escalation.Pending -> "pending"
    runtime_escalation.Approved -> "approved"
    runtime_escalation.Rejected -> "rejected"
    runtime_escalation.Consumed -> "consumed"
  }
}

/// A stored denial as the protocol carries it, or `None` when it will not decode.
///
/// ## Examples
///
/// ```gleam
/// assert escalation_view.denial(json.Null) == option.None
/// ```
pub fn denial(stored: JsonValue) -> Option(protocol.Denial) {
  case grants.decode_denial(stored) {
    Error(_) -> None
    Ok(decoded) ->
      Some(protocol.Denial(
        reason: decoded.reason,
        source: case decoded.source {
          broker_escalation.PolicyDenial -> "policy"
          broker_escalation.ExecutionDenial(enforcement: _) -> "execution"
        },
        enforcement: None,
        wanted: decoded.wanted,
      ))
  }
}
