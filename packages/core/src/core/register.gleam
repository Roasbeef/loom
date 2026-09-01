//// Register namespaces and the generic register value.
////
//// Registers are the only mutable store: namespaced typed cells addressed
//// by `(namespace, key)`. The namespace set is closed — `RegisterNs` below
//// transcribes the frozen contract in the implementation spec Part 1.1 —
//// and each namespace forces the type of the values stored under it.
////
//// The *rich* value types the namespaces force (`StrandConfiguration`,
//// `StrandState`, `Operation`, `OperationState`, …) belong to the
//// `machine` package: they are orchestration vocabulary, and `core` must
//// not depend on it. So `core` defines `RegisterValue` as a thin tagged
//// wrapper around the encoded payload — a `Json` value — which is what
//// storage persists and returns. Storage stays generic over payloads;
//// `machine` owns the codecs from `RegisterValue` payloads to its rich
//// types, using the same total-decoder discipline as every other
//// durability boundary. The one payload shape `core` itself understands is
//// the `StrandLeaf` namespace's `Option(EntryId)`, for which convenience
//// constructors are provided here.

import core/corruption.{type CorruptionReport}
import core/ids.{type EntryId}
import core/json.{type JsonValue}
import gleam/option.{type Option, None, Some}

/// The closed set of register namespaces. Adding a namespace is an
/// interface change and requires a protocol-change proposal.
///
/// Each constructor documents its key shape and the value type it forces
/// (rich types live in `machine`; `core` sees their encoded payloads).
pub type RegisterNs {
  /// Key: strand name → `Option(EntryId)`, the strand's current leaf.
  StrandLeaf

  /// Key: strand name → `StrandConfiguration`.
  StrandConfig

  /// Key: strand name → `StrandState`.
  StrandState

  /// Key: strand name → the strand's last terminal result. Never a
  /// recovery input.
  StrandLastResult

  /// Key: operation id → `Operation`. Write-once.
  OpMeta

  /// Key: operation id → `OperationState`, the durable program counter.
  OpState

  /// Key: `op:step:idx` → `Json` tool arguments. Write-once.
  OpToolArgs

  /// Key: `op:task` → `StructuralPreparation`. Write-once.
  OpPreparation

  /// Key: reserved entry id → `PendingEntry`.
  PendingEntry

  /// Shared blackboard: fact names.
  FactName

  /// Shared blackboard: fact labels.
  FactLabel

  /// Shared blackboard: application-defined facts.
  FactCustom
}

/// A register cell's stored value: the encoded payload as tagged `Json`.
///
/// Constructor invariants: `payload` is the complete encoded value for the
/// cell's namespace; interpreting it is the owning package's job
/// (`machine` for orchestration namespaces), through a total decoder.
pub type RegisterValue {
  RegisterValue(payload: JsonValue)
}

/// Wraps an encoded payload as a register value. Identical to the
/// constructor; provided so call sites pipe naturally.
///
/// ## Examples
///
/// ```gleam
/// assert register.value(json.Int(1)) == register.RegisterValue(json.Int(1))
/// ```
///
pub fn value(payload: JsonValue) -> RegisterValue {
  RegisterValue(payload:)
}

/// Encodes a `StrandLeaf` payload: `Some(id)` becomes the id's canonical
/// text, `None` becomes `Json` null.
///
/// ## Examples
///
/// ```gleam
/// assert register.leaf_value(None) == register.RegisterValue(json.Null)
/// ```
///
pub fn leaf_value(leaf: Option(EntryId)) -> RegisterValue {
  case leaf {
    Some(id) -> RegisterValue(payload: json.String(ids.entry_id_to_string(id)))
    None -> RegisterValue(payload: json.Null)
  }
}

/// Decodes a `StrandLeaf` payload back to `Option(EntryId)`. Total: any
/// payload that is neither null nor a valid id string is corruption.
///
/// ## Examples
///
/// ```gleam
/// assert register.read_leaf(register.leaf_value(None)) == Ok(None)
/// ```
///
pub fn read_leaf(
  value: RegisterValue,
) -> Result(Option(EntryId), CorruptionReport) {
  case value.payload {
    json.Null -> Ok(None)
    json.String(text) ->
      case ids.parse_entry_id(text) {
        Ok(id) -> Ok(Some(id))
        Error(report) -> Error(report)
      }
    other ->
      Error(corruption.report(
        at: "core/register.read_leaf",
        on: "strand.leaf payload",
        expected: "null or an entry id string",
        context: json.to_string(other),
      ))
  }
}

/// The persisted name of a namespace, used as the storage key prefix and
/// wire form.
///
/// ## Examples
///
/// ```gleam
/// assert register.ns_to_string(register.OpState) == "op.state"
/// ```
///
pub fn ns_to_string(ns: RegisterNs) -> String {
  case ns {
    StrandLeaf -> "strand.leaf"
    StrandConfig -> "strand.config"
    StrandState -> "strand.state"
    StrandLastResult -> "strand.last_result"
    OpMeta -> "op.meta"
    OpState -> "op.state"
    OpToolArgs -> "op.tool_args"
    OpPreparation -> "op.preparation"
    PendingEntry -> "pending.entry"
    FactName -> "fact.name"
    FactLabel -> "fact.label"
    FactCustom -> "fact.custom"
  }
}

/// Parses a persisted namespace name. Total: unknown names are corruption —
/// the namespace set is closed.
///
/// ## Examples
///
/// ```gleam
/// assert register.parse_ns("strand.leaf") == Ok(register.StrandLeaf)
/// ```
///
/// ```gleam
/// let assert Error(_report) = register.parse_ns("strand.unknown")
/// ```
///
pub fn parse_ns(text: String) -> Result(RegisterNs, CorruptionReport) {
  case text {
    "strand.leaf" -> Ok(StrandLeaf)
    "strand.config" -> Ok(StrandConfig)
    "strand.state" -> Ok(StrandState)
    "strand.last_result" -> Ok(StrandLastResult)
    "op.meta" -> Ok(OpMeta)
    "op.state" -> Ok(OpState)
    "op.tool_args" -> Ok(OpToolArgs)
    "op.preparation" -> Ok(OpPreparation)
    "pending.entry" -> Ok(PendingEntry)
    "fact.name" -> Ok(FactName)
    "fact.label" -> Ok(FactLabel)
    "fact.custom" -> Ok(FactCustom)
    _ ->
      Error(corruption.report(
        at: "core/register.parse_ns",
        on: "register namespace",
        expected: "one of the closed namespace names",
        context: text,
      ))
  }
}
