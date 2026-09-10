//// Presentation is reconstructed from one completed metadata cut and raw tree.
////
//// Strand membership follows each captured leaf's parent chain. A missing
//// parent ends the loaded projection; unrelated global records are never
//// assigned to main as a fallback. Configuration, attribution and presence
//// are decoded together so a metadata-only catch-up changes one coherent view.

import core/codec
import core/entry.{type Entry}
import core/ids
import core/json
import core/message.{type Origin, type Usage}
import core/origin
import core/register
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/codec as machine_codec
import machine/operation
import machine/strand
import tui/protocol
import tui/snapshot

/// One authenticated presence row, not a source of local mutation authority.
pub type Peer {
  Peer(
    /// Identity of this attachment, distinct from principal identity.
    connection_id: String,
    /// Historical display identity supplied by the host.
    origin: Origin,
    /// This peer's role; only the local attachment governs local controls.
    role: snapshot.Role,
  )
}

/// One complete strand configuration and its attribution from the same cut.
pub type Configuration {
  Configuration(
    /// Effective durable provider/model and reasoning choices.
    configuration: strand.StrandConfiguration,
    /// Human who made the latest configuration change, when recorded.
    origin: Option(Origin),
  )
}

/// Shared queue/execution preferences, with their durable author.
pub type RunSettings {
  RunSettings(
    /// Host-validated queue policy name.
    queue_mode: String,
    /// Host-validated tool execution mode name.
    tool_execution: String,
    /// None denotes a host default rather than an attributed mutation.
    origin: Option(Origin),
  )
}

/// A standalone, potentially discontinuous preview, never an ordered delta.
pub type Preview {
  Preview(
    /// Deduplicates this observation across metadata cuts.
    revision: Int,
    /// Operation identity which may be mapped to a captured strand state.
    operation: String,
    /// Request identity shared with live deltas; empty for old recordings.
    generation: String,
    /// The fragment's actual content kind, so thinking is never an answer.
    kind: String,
    /// At most 24KiB; replaces the previous preview rather than appending.
    text: String,
  )
}

/// Typed presentation state derived without runtime or server dependencies.
pub type View {
  View(
    /// Complete captured strand set.
    strands: List(protocol.Strand),
    /// Leaves define ancestry, not a guessed owner field on entries.
    leaves: Dict(String, Option(ids.EntryId)),
    /// Effective configurations keyed by strand.
    configurations: Dict(String, Configuration),
    /// Current operation identities keyed by strand.
    operations: Dict(String, String),
    /// Cumulative usage replaces the previous cut's total.
    usage: Usage,
    /// Shared settings from durable client/run_settings, or host fallback.
    settings: RunSettings,
    /// All currently authenticated session attachments.
    peers: List(Peer),
    /// Mutable cells retained for bounded approval projection.
    cells: List(Cell),
    /// Latest optional transient observation.
    preview: Option(Preview),
    /// Authoritative host queue; absent only in older protocol recordings.
    pending_inputs: Option(List(PendingInput)),
    /// Actual host registration and discovery diagnostics, when supplied.
    tools: Option(ToolAvailability),
  )
}

/// Tool registration is distinct from a strand's enabled subset.
pub type ToolAvailability {
  ToolAvailability(
    /// Names in the registry which dispatches this session's tool calls.
    registered: List(String),
    /// Why the host could not register code mode, or disabled it explicitly.
    code_mode_issue: Option(String),
  )
}

/// One host-owned input awaiting admission to an operation.
pub type PendingInput {
  PendingInput(
    /// Unique connection and request identity, independent of message text.
    id: String,
    /// The strand whose queue owns this item.
    strand: String,
    /// Steering precedes ordinary turns within the captured queue order.
    kind: InputKind,
    /// A bounded display excerpt; the host retains the full submitted content.
    text: String,
    /// Revision required when requesting a conditional replacement.
    revision: Int,
    /// Older hosts cannot authorize editing by omission.
    editing: Editing,
  )
}

/// Editability is an explicit server assertion for this attachment.
pub type Editing {
  /// The host permits this attachment to request a replacement.
  Editable

  /// The item is visible without replacement authority.
  ReadOnly
}

/// The scheduling intent attached to a human submission.
pub type InputKind {
  /// Preempt current work and run before ordinary queued turns.
  Steer

  /// Run after the current operation and earlier queued input.
  Queue
}

/// One bounded mutable register cell from the captured cut.
pub type Cell {
  Cell(
    /// Closed register namespace, validated through core/register.
    namespace: register.RegisterNs,
    /// Host-selected register key.
    key: String,
    /// Durable compare-and-swap sequence for this exact payload.
    seq: Int,
    /// Raw register payload, not a second RegisterValue wrapper.
    value: json.JsonValue,
  )
}

/// A loaded branch suffix and the exact parent which is not locally loaded.
pub type Branch {
  Branch(
    /// Newest-first loaded ancestors of the selected captured leaf.
    records: List(protocol.EntryRecord),
    /// A missing or oversized parent remains explicit.
    unloaded: Option(String),
  )
}

/// Decodes a coherent metadata document only after snapshot_end validation.
///
/// ## Examples
///
/// ```gleam
/// // snapshot_view.decode(captured)
/// ```
pub fn decode(captured: snapshot.Captured) -> Result(View, String) {
  use fields <- result.try(object(captured.metadata))
  use cells <- result.try(captured_cells(captured))
  use _message_count <- result.try(number(fields, "message_count"))
  use usage_value <- result.try(field(fields, "usage"))
  use usage <- result.try(
    codec.decode_usage(usage_value)
    |> result.replace_error("invalid captured usage"),
  )

  decode_view(fields, cells, usage)
}

fn captured_cells(captured: snapshot.Captured) {
  use fields <- result.try(object(captured.metadata))
  use raw_cells <- result.try(array(fields, "cells"))
  use <- bool.guard(
    list.drop(raw_cells, 1024) != [],
    Error("too many captured cells"),
  )
  use cells <- result.try(list.try_map(raw_cells, decode_cell))
  use Nil <- result.try(unique_cells(cells))
  use <- bool.guard(
    list.any(cells, fn(cell) { cell.seq >= captured.next_seq }),
    Error("captured register is outside its cut"),
  )
  Ok(cells)
}

fn decode_view(fields, cells, usage) {
  // The mutable server default is read from this same cut, never from a
  // separate config response which could race its attribution cell. The
  // key is `runtime/api.run_settings_key`, spelled out here because the
  // terminal does not depend on the runtime package; a change there must
  // be mirrored by hand.
  let settings_value = case
    find(cells, register.FactCustom, "client/run_settings")
  {
    Ok(cell) -> Ok(cell.value)
    Error(Nil) -> field(fields, "host_run_settings")
  }
  use settings <- result.try(settings_value |> result.try(decode_settings))
  use raw_peers <- result.try(array(fields, "peers"))
  use <- bool.guard(
    list.drop(raw_peers, 64) != [],
    Error("too many captured peers"),
  )
  use peers <- result.try(list.try_map(raw_peers, decode_peer))
  use <- bool.guard(
    dict.size(
      dict.from_list(list.map(peers, fn(peer) { #(peer.connection_id, Nil) })),
    )
      != list.length(peers),
    Error("duplicate captured attachment"),
  )
  use strands <- result.try(
    list.try_map(
      list.filter(cells, fn(cell) { cell.namespace == register.StrandConfig }),
      fn(cell) { decode_strand(cells, cell) },
    ),
  )
  use preview <- result.try(decode_preview(fields))
  use pending <- result.try(decode_pending(fields))
  use tools <- result.try(decode_tools(fields))
  Ok(View(
    list.map(strands, fn(row) { row.0 }),
    dict.from_list(list.map(strands, fn(row) { #(row.0.id, row.1) })),
    dict.from_list(list.map(strands, fn(row) { #(row.0.id, row.2) })),
    dict.from_list(
      list.filter_map(strands, fn(row) {
        row.3 |> option.to_result(Nil) |> result.map(fn(op) { #(row.0.id, op) })
      }),
    ),
    usage,
    settings,
    peers,
    cells,
    preview,
    pending,
    tools,
  ))
}

fn decode_tools(fields) {
  case list.key_find(fields, "tool_availability") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(value) -> {
      use fields <- result.try(object(value))
      use names <- result.try(array(fields, "registered"))
      use <- bool.guard(
        list.drop(names, 1024) != [],
        Error("too many registered tools"),
      )
      use registered <- result.try(
        list.try_map(names, fn(value) {
          case value {
            json.String(name) -> Ok(name)
            _ -> Error("invalid registered tool name")
          }
        }),
      )
      use reason <- result.try(field(fields, "code_mode_issue"))
      case reason {
        json.Null -> Ok(Some(ToolAvailability(registered, None)))
        json.String(reason) ->
          Ok(Some(ToolAvailability(registered, Some(reason))))
        _ -> Error("invalid code mode diagnostic")
      }
    }
  }
}

fn decode_pending(fields) {
  case list.key_find(fields, "pending_inputs") {
    Error(Nil) -> Ok(None)
    Ok(_) -> {
      use raw <- result.try(array(fields, "pending_inputs"))
      use <- bool.guard(
        list.drop(raw, 2048) != [],
        Error("too many pending inputs"),
      )
      use rows <- result.try(list.try_map(raw, decode_pending_input))
      let identities = list.map(rows, fn(row) { #(row.id, Nil) })
      use <- bool.guard(
        dict.size(dict.from_list(identities)) != list.length(rows),
        Error("duplicate pending input identity"),
      )
      Ok(Some(rows))
    }
  }
}

fn decode_pending_input(value) {
  use fields <- result.try(object(value))
  use id <- result.try(text(fields, "id"))
  use strand <- result.try(text(fields, "strand"))
  use content <- result.try(text(fields, "text"))
  use kind <- result.try(text(fields, "kind"))
  use <- bool.guard(
    id == "" || strand == "" || string.byte_size(content) > 512,
    Error("invalid pending input extent"),
  )
  use revision <- result.try(case list.key_find(fields, "revision") {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    Error(Nil) -> Ok(0)
    _ -> Error("invalid pending input revision")
  })
  use editing <- result.try(case list.key_find(fields, "editable") {
    Ok(json.Bool(True)) -> Ok(Editable)
    Ok(json.Bool(False)) | Error(Nil) -> Ok(ReadOnly)
    _ -> Error("invalid pending input editability")
  })
  case kind {
    "steer" -> Ok(PendingInput(id, strand, Steer, content, revision, editing))
    "queue" -> Ok(PendingInput(id, strand, Queue, content, revision, editing))
    _ -> Error("invalid pending input kind")
  }
}

/// Decodes only requested exact escalation keys, including explicit absences.
///
/// The result cannot replace strand/configuration metadata or the history
/// cursor. Every requested key must occur once as either a cell or missing.
///
/// ## Examples
///
/// ```gleam
/// // snapshot_view.lookup(captured, ["approval-id"])
/// ```
pub fn lookup(
  captured: snapshot.Captured,
  requested: List(String),
) -> Result(#(List(Cell), List(String)), String) {
  use <- bool.guard(
    captured.window.items != []
      || list.drop(requested, 8) != []
      || requested == [],
    Error("invalid exact lookup extent"),
  )
  use cells <- result.try(captured_cells(captured))
  use fields <- result.try(object(captured.metadata))
  use missing <- result.try(
    array(fields, "missing")
    |> result.try(fn(values) {
      list.try_map(values, fn(value) {
        case value {
          json.String(id) -> Ok(id)
          _ -> Error("invalid missing escalation identity")
        }
      })
    }),
  )
  use <- bool.guard(
    list.any(cells, fn(cell) {
      cell.namespace != register.FactCustom
      || !list.any(requested, fn(id) { cell.key == "escalation/" <> id })
    }),
    Error("lookup returned an unrequested register"),
  )
  let found = list.map(cells, fn(cell) { string.drop_start(cell.key, 11) })
  let answered = list.append(found, missing)
  use <- bool.guard(
    list.length(answered) != list.length(requested)
      || list.any(answered, fn(id) { !list.contains(requested, id) })
      || dict.size(dict.from_list(list.map(answered, fn(id) { #(id, Nil) })))
      != list.length(requested),
    Error("lookup omitted, duplicated or invented a requested identity"),
  )
  Ok(#(cells, missing))
}

fn decode_cell(value) {
  use fields <- result.try(object(value))
  use namespace <- result.try(
    text(fields, "namespace")
    |> result.try(fn(value) {
      register.parse_ns(value)
      |> result.replace_error("invalid captured namespace")
    }),
  )
  use key <- result.try(text(fields, "key"))
  use seq <- result.try(number(fields, "seq"))
  use value <- result.try(field(fields, "value"))
  Ok(Cell(namespace, key, seq, value))
}

fn unique_cells(cells: List(Cell)) {
  list.try_fold(cells, dict.new(), fn(seen, cell) {
    let identity = #(cell.namespace, cell.key)
    case dict.has_key(seen, identity) {
      True -> Error("duplicate captured register")
      False -> Ok(dict.insert(seen, identity, Nil))
    }
  })
  |> result.replace(Nil)
}

fn decode_strand(cells: List(Cell), config: Cell) {
  use configuration <- result.try(
    machine_codec.decode_configuration(config.value)
    |> result.replace_error("invalid captured strand configuration"),
  )
  use leaf_cell <- result.try(
    find(cells, register.StrandLeaf, config.key)
    |> result.replace_error("configured strand omitted its leaf"),
  )
  use leaf <- result.try(
    register.read_leaf(register.RegisterValue(leaf_cell.value))
    |> result.replace_error("invalid captured strand leaf"),
  )
  use state_cell <- result.try(
    find(cells, register.StrandState, config.key)
    |> result.replace_error("configured strand omitted its state"),
  )
  use state <- result.try(
    machine_codec.decode_strand_state(state_cell.value)
    |> result.replace_error("invalid captured strand state"),
  )
  use phase <- result.try(operation_phase(cells, state.current_operation))
  use author <- result.try(configuration_origin(cells, config.key))
  Ok(#(
    protocol.Strand(config.key, Some(config.key), phase),
    leaf,
    Configuration(configuration, author),
    option.map(state.current_operation, ids.op_id_to_string),
  ))
}

fn operation_phase(cells, current) {
  case current {
    None -> Ok(None)
    Some(id) -> {
      use cell <- result.try(
        find(cells, register.OpState, ids.op_id_to_string(id))
        |> result.replace_error("captured live operation omitted its state"),
      )
      use state <- result.try(
        machine_codec.decode_state(cell.value)
        |> result.replace_error("invalid captured operation state"),
      )
      Ok(Some(phase_name(state)))
    }
  }
}

fn phase_name(state) {
  case state {
    operation.CompactionState(..) -> "compacting"
    operation.NavigationState(..) -> "navigating"
    operation.RunState(phase:, ..) ->
      case phase {
        operation.Starting -> "starting"
        operation.Checkpoint(_) -> "checkpoint"
        operation.Assistant(_) -> "assistant"
        operation.Tools(_) -> "tools"
        operation.Compacting(..) -> "compacting"
        operation.AwaitingDeferred(_) -> "awaiting_deferred"
        operation.FailureDrain(..) -> "failure_drain"
      }
  }
}

fn configuration_origin(cells, strand) {
  case find(cells, register.FactCustom, "client/config_origin/" <> strand) {
    Error(Nil) -> Ok(None)
    Ok(cell) -> {
      use fields <- result.try(object(cell.value))
      origin.decode_field(fields)
      |> result.replace_error("invalid captured configuration origin")
    }
  }
}

fn decode_settings(value) {
  use fields <- result.try(object(value))
  use queue <- result.try(text(fields, "queue_mode"))
  use tools <- result.try(text(fields, "tool_execution"))
  use <- bool.guard(
    !list.contains(["consume_all", "one_at_a_time"], queue)
      || !list.contains(["parallel", "sequential"], tools),
    Error("unknown shared run settings mode"),
  )
  use author <- result.try(
    origin.decode_field(fields)
    |> result.replace_error("invalid shared settings origin"),
  )
  Ok(RunSettings(queue, tools, author))
}

fn decode_peer(value) {
  use fields <- result.try(object(value))
  use connection <- result.try(text(fields, "connection_id"))
  use <- bool.guard(
    connection == "" || string.byte_size(connection) > 256,
    Error("invalid presence connection identity"),
  )
  use author <- result.try(
    origin.decode_field(fields)
    |> result.replace_error("invalid presence origin")
    |> result.try(fn(author) {
      option.to_result(author, "missing presence origin")
    }),
  )
  use role <- result.try(text(fields, "role"))
  case role {
    "owner" -> Ok(Peer(connection, author, snapshot.Owner))
    "operator" -> Ok(Peer(connection, author, snapshot.Operator))
    "observer" -> Ok(Peer(connection, author, snapshot.Observer))
    _ -> Error("invalid presence role")
  }
}

fn decode_preview(fields) {
  case list.key_find(fields, "stream_preview") {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(value) -> {
      use fields <- result.try(object(value))
      use revision <- result.try(number(fields, "revision"))
      use operation <- result.try(text(fields, "operation"))
      use generation <- result.try(optional_text(fields, "generation", ""))
      use kind <- result.try(optional_text(fields, "kind", "text"))
      use text <- result.try(text(fields, "text"))
      use discontinuous <- result.try(field(fields, "discontinuous"))
      use <- bool.guard(
        string.byte_size(text) > snapshot.piece_limit
          || discontinuous != json.Bool(True),
        Error("invalid bounded stream preview"),
      )
      use <- bool.guard(
        !list.contains(["text", "thinking", "tool_call"], kind),
        Error("invalid stream preview kind"),
      )
      Ok(Some(Preview(revision, operation, generation, kind, text)))
    }
  }
}

fn optional_text(fields, name, fallback) {
  case list.key_find(fields, name) {
    Error(Nil) -> Ok(fallback)
    Ok(_) -> text(fields, name)
  }
}

/// Projects only known ancestors of the selected strand's captured leaf.
///
/// ## Examples
///
/// ```gleam
/// // snapshot_view.branch(view, captured.window, "main")
/// ```
pub fn branch(view: View, window: snapshot.Window, strand: String) -> Branch {
  let entries =
    dict.from_list(
      list.filter_map(window.items, fn(item) {
        case item {
          snapshot.Loaded(entry, _) -> Ok(#(entry.id, entry))
          snapshot.Unloaded(..) -> Error(Nil)
        }
      }),
    )
  case dict.get(view.leaves, strand) {
    Error(Nil) -> Branch([], Some("strand is not present in the captured cut"))
    Ok(leaf) -> walk(entries, leaf, strand, [], 100)
  }
}

fn walk(
  entries: Dict(ids.EntryId, Entry),
  leaf: Option(ids.EntryId),
  strand,
  rows,
  remaining,
) {
  case leaf, remaining {
    None, _ -> Branch(list.reverse(rows), None)
    Some(id), 0 -> Branch(list.reverse(rows), Some(ids.entry_id_to_string(id)))
    Some(id), _ ->
      case dict.get(entries, id) {
        Error(Nil) ->
          Branch(list.reverse(rows), Some(ids.entry_id_to_string(id)))
        Ok(entry) ->
          walk(
            dict.delete(entries, id),
            entry.parent,
            strand,
            [protocol.EntryRecord(strand, entry), ..rows],
            remaining - 1,
          )
      }
  }
}

fn find(cells: List(Cell), namespace, key) {
  list.find(cells, fn(cell) { cell.namespace == namespace && cell.key == key })
}

fn object(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected metadata object")
  }
}

fn field(fields, name) {
  list.key_find(fields, name) |> result.replace_error("missing metadata field")
}

fn text(fields, name) {
  use value <- result.try(field(fields, name))
  case value {
    json.String(text) -> Ok(text)
    json.Object(_)
    | json.Array(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected metadata string")
  }
}

fn number(fields, name) {
  use value <- result.try(field(fields, name))
  case value {
    json.Int(number) if number >= 0 -> Ok(number)
    json.Int(_)
    | json.Object(_)
    | json.Array(_)
    | json.String(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected nonnegative metadata integer")
  }
}

fn array(fields, name) {
  use value <- result.try(field(fields, name))
  case value {
    json.Array(items) -> Ok(items)
    json.Int(_)
    | json.Object(_)
    | json.String(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("expected metadata array")
  }
}

/// Reports whether this cut proves that the exact operation has retired.
///
/// Last results are durable and name their operation, unlike an idle strand
/// sampled before a newer request began. The latest result may supersede an
/// older one, so absence is not retirement evidence.
///
/// ## Examples
///
/// ```gleam
/// assert snapshot_view.has_result(view, "main", "unobserved") == False
/// ```
pub fn has_result(view: View, strand: String, current: String) -> Bool {
  let result =
    view.cells
    |> list.find(fn(cell) {
      cell.namespace == register.StrandLastResult && cell.key == strand
    })
    |> result.try(fn(cell) {
      machine_codec.decode_last_result(cell.value) |> result.replace_error(Nil)
    })
  case result {
    Ok(operation.RunLastResult(operation: id, ..))
    | Ok(operation.CompactionLastResult(operation: id, ..))
    | Ok(operation.NavigationLastResult(operation: id, ..)) ->
      ids.op_id_to_string(id) == current
    Error(Nil) -> False
  }
}
