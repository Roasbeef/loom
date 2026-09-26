//// Recipient-owned peer grants and idempotent durable message admission.
////
//// The host invokes this module through the Agency's small endpoint. A send
//// carries authenticated source metadata as data, never a Runtime borrowed
//// from another session. The recipient's grant sequence and receipt absence
//// are compared in the same writer transaction as the delivered prompt.

import core/clock
import core/entry
import core/glance
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import core/message
import core/origin
import core/register
import core/tx
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/codec
import machine/operation
import runtime/api
import runtime/escalation
import runtime/lineage
import runtime/writer
import session/session
import storage/storage
import tools/blob

/// Waking an idle recipient is an independent operator permission.
pub type Wake {
  /// Delivery is allowed only while the target has an active run.
  BusyOnly

  /// Delivery may start a new run on the explicitly exported strand.
  MayWake
}

/// One directional, exact-strand communication grant.
pub type Grant {
  Grant(
    /// Canonical session identity bound by the sending harness.
    source_session: String,
    /// Exact sending strand, with no wildcard interpretation.
    source_strand: String,
    /// Exact recipient strand explicitly exported by the operator.
    target_strand: String,
    /// Whether admission may wake an idle strand.
    wake: Wake,
  )
}

/// Harness-supplied provenance retained in the atomic receipt.
pub type Source {
  Source(
    /// Canonical sending session identity.
    session: String,
    /// Authenticated sending strand identity.
    strand: String,
    /// Operator-owned display metadata, never parsed as authority.
    metadata: JsonValue,
  )
}

/// Commands reachable only through a harness-owned endpoint.
pub type Command {
  /// Owner-authorized grant replacement.
  Allow(grant: Grant)

  /// Owner-authorized grant removal.
  Revoke(grant: Grant)

  /// Records an outgoing link after recipient authorization is durable.
  Link(source_strand: String, target_session: String, target_strand: String)

  /// Removes discovery before recipient revocation.
  Unlink(source_strand: String, target_session: String, target_strand: String)

  /// Returns this strand's explicit outgoing links.
  Links(source_strand: String)

  /// Returns incoming grants to one exact recipient strand for owner inspection.
  Grants(target_strand: String)

  /// Commits the message and request identity together.
  Deliver(source: Source, target: String, message_id: String, text: String)

  /// Lists only strands this source is authorized to address.
  Describe(strand: String, description: String)
  Activity(strand: String)
  Roster(source_session: String, source_strand: String)

  /// Summarizes the whole session for the owner's cross-session view
  /// (`protocol-change/050`). It reads and never writes, and its answer is
  /// bounded to `overview_row_bytes` whatever the session holds.
  Overview
}

/// A small endpoint; its closure captures an address, never a runtime graph.
pub type Endpoint {
  Endpoint(
    /// Canonical resident identity, checked after directory lookup.
    session: String,
    /// One bounded request to the recipient's Agency actor.
    call: fn(Command) -> Result(JsonValue, String),
  )
}

const grant_prefix = "client/peers/grant/"

const link_prefix = "client/peers/link/"

/// Maximum number of outgoing links recorded for one source strand.
pub const outgoing_link_limit = 64

/// The encoded size an `Overview` answer never exceeds. The daemon adds a
/// session identity to each answer and places up to 24 of them in one
/// 60,000-byte reply, so this bound is what lets that reply fit without a
/// page cursor.
pub const overview_row_bytes = 2300

// The per-field bounds `protocol-change/050` names. Each is applied with
// `glance.clip`, which cuts on a grapheme boundary.
const overview_message_bytes = 280

const overview_model_bytes = 64

const overview_strand_bytes = 96

const overview_title_bytes = 60

const overview_summary_bytes = 160

const overview_glances = 4

const receipt_prefix = "client/peers/receipt/"

fn digest(value: JsonValue) -> String {
  blob.ref_for(<<json.to_string(value):utf8>>)
}

fn grant_key(grant: Grant) -> String {
  grant_prefix
  <> digest(
    json.Array([
      json.String(grant.source_session),
      json.String(grant.source_strand),
      json.String(grant.target_strand),
    ]),
  )
}

fn grant_value(grant: Grant) -> JsonValue {
  json.Object([
    #("source_session", json.String(grant.source_session)),
    #("source_strand", json.String(grant.source_strand)),
    #("target_strand", json.String(grant.target_strand)),
    #(
      "wake",
      json.String(case grant.wake {
        BusyOnly -> "busy_only"
        MayWake -> "may_wake"
      }),
    ),
  ])
}

fn link_value(source: String, session: String, target: String) -> JsonValue {
  json.Object([
    #("source_strand", json.String(source)),
    #("session", json.String(session)),
    #("strand", json.String(target)),
  ])
}

fn outgoing_links(
  runtime: api.Runtime,
  source: String,
) -> Result(List(#(String, JsonValue)), String) {
  use links <- result.try(
    api.reserved_facts(runtime, link_prefix)
    |> result.map_error(string.inspect),
  )
  Ok(
    list.filter(links, fn(pair) { text(pair.1, "source_strand") == Ok(source) }),
  )
}

/// Executes one endpoint command in the recipient's serialized Agency actor.
///
/// ## Examples
///
/// ```gleam
/// // peer_mail.handle(runtime, clock, command)
/// ```
pub fn handle(
  runtime: api.Runtime,
  clock: clock.Clock,
  command: Command,
) -> Result(JsonValue, String) {
  case command {
    Allow(grant) -> {
      use config <- result.try(
        session.strand_configuration(runtime.session, grant.target_strand)
        |> result.map_error(string.inspect),
      )
      use _ <- result.try(option.to_result(
        config,
        "recipient strand does not exist",
      ))
      api.put_reserved_fact(runtime, grant_key(grant), grant_value(grant))
      |> result.replace(json.Null)
      |> result.map_error(string.inspect)
    }
    Revoke(grant) ->
      api.delete_reserved_fact(runtime, grant_key(grant))
      |> result.replace(json.Null)
      |> result.map_error(string.inspect)
    Link(source, session, target) -> {
      let value = link_value(source, session, target)
      let key = link_prefix <> digest(value)
      use links <- result.try(outgoing_links(runtime, source))
      use Nil <- result.try(case list.any(links, fn(pair) { pair.0 == key }) {
        True -> Ok(Nil)
        False ->
          case list.length(links) < outgoing_link_limit {
            True -> Ok(Nil)
            False -> Error("peer roster exceeds the 64-link bound")
          }
      })
      api.put_reserved_fact(runtime, key, value)
      |> result.replace(json.Null)
      |> result.map_error(string.inspect)
    }
    Unlink(source, session, target) ->
      api.delete_reserved_fact(
        runtime,
        link_prefix <> digest(link_value(source, session, target)),
      )
      |> result.replace(json.Null)
      |> result.map_error(string.inspect)
    Links(source) -> {
      use links <- result.try(outgoing_links(runtime, source))
      Ok(json.Array(list.map(links, fn(pair) { pair.1 })))
    }
    Grants(target) -> {
      use grants <- result.try(
        api.reserved_facts(runtime, grant_prefix)
        |> result.map_error(string.inspect),
      )
      use grants <- result.try(
        list.try_map(grants, fn(pair) { decode_grant(pair.1) }),
      )
      Ok(
        grants
        |> list.filter(fn(grant) { grant.target_strand == target })
        |> list.map(grant_value)
        |> json.Array,
      )
    }
    Deliver(source, target, id, body) ->
      deliver(runtime, clock, source, target, id, body)
    Describe(strand, description) -> {
      case string.byte_size(description) <= 2048 {
        False -> Error("self-description exceeds 2048 bytes")
        True ->
          api.put_reserved_fact(
            runtime,
            "client/peers/description/" <> strand,
            json.String(description),
          )
          |> result.replace(json.Null)
          |> result.map_error(string.inspect)
      }
    }
    Activity(strand) -> activity(runtime, strand)
    Roster(source_session, source_strand) ->
      roster(runtime, source_session, source_strand)
    Overview -> overview(runtime)
  }
}

fn deliver(
  runtime: api.Runtime,
  clock: clock.Clock,
  source: Source,
  target: String,
  id: String,
  body: String,
) -> Result(JsonValue, String) {
  use Nil <- result.try(
    case
      string.byte_size(id) > 0
      && string.byte_size(id) <= 128
      && string.byte_size(body) <= 32_768
    {
      True -> Ok(Nil)
      False -> Error("message id or body exceeds its bound")
    },
  )
  let key = grant_key(Grant(source.session, source.strand, target, BusyOnly))
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(string.inspect),
  )
  use cell <- result.try(option.to_result(cell, "no directional peer grant"))
  use grant <- result.try(decode_grant(cell.value))
  use Nil <- result.try(
    case
      grant.source_session == source.session
      && grant.source_strand == source.strand
      && grant.target_strand == target
    {
      True -> Ok(Nil)
      False -> Error("peer grant identity mismatch")
    },
  )
  let request =
    json.Object([
      #("source_session", json.String(source.session)),
      #("source_strand", json.String(source.strand)),
      #("target_strand", json.String(target)),
      #("message_id", json.String(id)),
      #("body", json.String(body)),
    ])
  let receipt_key =
    receipt_prefix
    <> digest(
      json.Array([
        json.String(source.session),
        json.String(source.strand),
        json.String(id),
      ]),
    )
  let receipt =
    json.Object([
      #("request", request),
      #("source", source.metadata),
      #("admitted", json.Bool(True)),
    ])
  use existing <- result.try(
    api.fact(runtime, receipt_key) |> result.map_error(string.inspect),
  )
  case existing {
    Some(existing) -> same_receipt(existing, request)
    None -> {
      let #(now, _) = clock.read(clock)
      use peer_origin <- result.try(
        origin.validate_peer(source.session, source.strand)
        |> result.map_error(fn(_) { "invalid peer source identity" }),
      )
      let payload =
        message.UserMessage(
          content: [message.UserText(body, None)],
          timestamp: now,
          origin: Some(peer_origin),
        )
      let mark =
        api.GuardedMark(receipt_key, receipt, [
          tx.Expect(register.FactCustom, key, Some(cell.seq)),
        ])
      let accepted = case grant.wake {
        BusyOnly ->
          api.steer_marking(api.on_strand(runtime, target), payload, mark)
          |> result.replace(Nil)
        MayWake ->
          api.send_to_strand_marking(runtime, target, payload, mark)
          |> result.replace(Nil)
      }
      case accepted {
        Ok(Nil) -> {
          api.nudge(api.on_strand(runtime, target))
          Ok(receipt)
        }
        Error(api.FactConflict(_)) -> {
          use existing <- result.try(
            api.fact(runtime, receipt_key) |> result.map_error(string.inspect),
          )
          use existing <- result.try(option.to_result(
            existing,
            "peer grant changed during admission",
          ))
          same_receipt(existing, request)
        }
        Error(error) -> Error(string.inspect(error))
      }
    }
  }
}

fn same_receipt(
  receipt: JsonValue,
  request: JsonValue,
) -> Result(JsonValue, String) {
  case field(receipt, "request") == Ok(request) {
    True -> Ok(receipt)
    False ->
      Error("message id was already used for different content or target")
  }
}

fn roster(
  runtime: api.Runtime,
  source: String,
  strand: String,
) -> Result(JsonValue, String) {
  use grants <- result.try(
    api.reserved_facts(runtime, grant_prefix)
    |> result.map_error(string.inspect),
  )
  use grants <- result.try(
    list.try_map(grants, fn(pair) { decode_grant(pair.1) }),
  )
  let targets =
    list.filter(grants, fn(grant) {
      grant.source_session == source && grant.source_strand == strand
    })
  use rows <- result.try(
    list.try_map(targets, fn(grant) {
      use state <- result.try(
        session.strand_state(runtime.session, grant.target_strand)
        |> result.map_error(string.inspect),
      )
      use state <- result.try(option.to_result(
        state,
        "recipient strand does not exist",
      ))
      use cell <- result.try(
        api.fact(runtime, lineage.register_key(grant.target_strand))
        |> result.map_error(string.inspect),
      )
      let parent = case cell {
        Some(value) ->
          case lineage.decode(value) {
            Ok(cell) -> json.String(cell.parent)
            Error(_) -> json.Null
          }
        None -> json.Null
      }
      use observed <- result.try(activity(runtime, grant.target_strand))
      Ok(
        json.Object([
          #("activity", observed),
          #("strand", json.String(grant.target_strand)),
          #("parent", parent),
          #("current_operation", case state.value.current_operation {
            None -> json.Null
            Some(op) -> json.String(ids.op_id_to_string(op))
          }),
          #(
            "wake",
            json.String(case grant.wake {
              BusyOnly -> "busy_only"
              MayWake -> "may_wake"
            }),
          ),
        ]),
      )
    }),
  )
  Ok(json.Array(rows))
}

fn decode_grant(value: JsonValue) -> Result(Grant, String) {
  use source_session <- result.try(text(value, "source_session"))
  use source_strand <- result.try(text(value, "source_strand"))
  use target_strand <- result.try(text(value, "target_strand"))
  use wake <- result.try(text(value, "wake"))
  use wake <- result.try(case wake {
    "busy_only" -> Ok(BusyOnly)
    "may_wake" -> Ok(MayWake)
    _ -> Error("invalid peer wake permission")
  })
  Ok(Grant(source_session:, source_strand:, target_strand:, wake:))
}

fn field(value: JsonValue, key: String) -> Result(JsonValue, String) {
  case value {
    json.Object(fields) ->
      list.key_find(fields, key)
      |> result.map_error(fn(_) { "missing peer field " <> key })
    _ -> Error("expected peer object")
  }
}

fn text(value: JsonValue, key: String) -> Result(String, String) {
  use value <- result.try(field(value, key))
  case value {
    json.String(value) -> Ok(value)
    _ -> Error("expected peer text field " <> key)
  }
}

fn activity(runtime: api.Runtime, strand: String) -> Result(JsonValue, String) {
  use state <- result.try(
    session.strand_state(runtime.session, strand)
    |> result.map_error(string.inspect),
  )
  use state <- result.try(option.to_result(state, "strand does not exist"))
  use terminal <- result.try(
    session.last_result(runtime.session, strand)
    |> result.map_error(string.inspect),
  )
  use description <- result.try(
    api.fact(runtime, "client/peers/description/" <> strand)
    |> result.map_error(string.inspect),
  )
  use git <- result.try(
    api.fact(runtime, "client/peers/git-observation")
    |> result.map_error(string.inspect),
  )
  Ok(
    json.Object([
      #("strand", json.String(strand)),
      #("state_commit_sequence", json.Int(state.seq)),
      #("current_operation", case state.value.current_operation {
        Some(op) -> json.String(ids.op_id_to_string(op))
        None -> json.Null
      }),
      #("last_terminal", case terminal {
        None -> json.Null
        Some(last) ->
          json.Object([
            #("commit_sequence", json.Int(last.seq)),
            #(
              "operation",
              json.String(ids.op_id_to_string(api.result_operation(last.value))),
            ),
            #("outcome", json.String(string.inspect(last.value))),
          ])
      }),
      #(
        "model_claim",
        json.Object([
          #("author", json.String("model")),
          #("description", option.unwrap(description, json.Null)),
        ]),
      ),
      #("git_observation", option.unwrap(git, json.Null)),
    ]),
  )
}

// One session's activity, as the owner's session picker shows it. Every
// read here is a single register, one entry, or one prefix listing, so the
// Agency actor answering it is held for a fixed number of store calls
// rather than a walk over the conversation.
fn overview(runtime: api.Runtime) -> Result(JsonValue, String) {
  use states <- result.try(strand_operations(runtime))
  use escalations <- result.try(
    api.escalations(runtime) |> result.map_error(string.inspect),
  )
  use last <- result.try(
    session.last_result(runtime.session, "main")
    |> result.map_error(string.inspect),
  )
  use configuration <- result.try(
    session.strand_configuration(runtime.session, "main")
    |> result.map_error(string.inspect),
  )
  use glances <- result.try(current_glances(runtime, states))
  let last = option.map(last, fn(cell) { cell.value })
  let approvals =
    list.count(escalations, fn(record) { record.status == escalation.Pending })
  let working = list.count(states, fn(pair) { option.is_some(pair.1) })

  // A failed main run asks for the operator only once main has stopped: a
  // main already running its next operation has moved past the failure.
  let main_running = case list.key_find(states, "main") {
    Ok(Some(_)) -> True
    Ok(None) | Error(Nil) -> False
  }
  let failed = case last {
    Some(operation.RunLastResult(outcome: operation.RunFailed(_), ..)) -> True
    Some(operation.RunLastResult(..))
    | Some(operation.CompactionLastResult(..))
    | Some(operation.NavigationLastResult(..))
    | None -> False
  }
  let state = case approvals > 0 || { failed && !main_running }, working > 0 {
    True, _ -> "needs_you"
    False, True -> "working"
    False, False -> "idle"
  }
  let model = case configuration {
    Some(cell) ->
      json.String(glance.clip(cell.value.model.model_id, overview_model_bytes))
    None -> json.Null
  }
  let base = [
    #("state", json.String(state)),
    #("strands", json.Int(list.length(states))),
    #("working", json.Int(working)),
    #("approvals", json.Int(approvals)),
    #("last_outcome", last_outcome(last)),
    #("model", model),
  ]
  Ok(fit_overview(base, final_message(runtime, last), glances))
}

// Every strand's current operation, from one listing of the strand-state
// namespace rather than one read per strand name.
fn strand_operations(
  runtime: api.Runtime,
) -> Result(List(#(String, Option(OpId))), String) {
  use cells <- result.try(
    writer.list_registers(runtime.tree.writer, register.StrandState, None)
    |> result.map_error(string.inspect),
  )
  list.try_map(cells, fn(pair) {
    let #(strand, storage.Register(value:, ..)) = pair
    codec.decode_strand_state(value.payload)
    |> result.map(fn(state) { #(strand, state.current_operation) })
    |> result.map_error(string.inspect)
  })
}

// The glances a reader may still show, newest first. `core/glance` says a
// glance describes one operation and is shown only while that operation is
// its strand's current one, so a cell left behind by a finished task is
// dropped here rather than reported as present work.
fn current_glances(
  runtime: api.Runtime,
  states: List(#(String, Option(OpId))),
) -> Result(List(JsonValue), String) {
  use cells <- result.try(
    api.reserved_facts(runtime, prefix: glance.key_prefix)
    |> result.map_error(string.inspect),
  )
  let current =
    states
    |> list.filter_map(fn(pair) {
      case pair.1 {
        Some(op) -> Ok(#(pair.0, ids.op_id_to_string(op)))
        None -> Error(Nil)
      }
    })
    |> dict.from_list
  cells
  |> list.filter_map(fn(pair) {
    use strand <- result.try(glance.strand_of(pair.0))
    use cell <- result.try(glance.decode(pair.1) |> result.replace_error(Nil))
    case dict.get(current, strand) == Ok(cell.operation) {
      True -> Ok(#(strand, cell))
      False -> Error(Nil)
    }
  })
  |> list.sort(fn(left, right) { int.compare({ right.1 }.at, { left.1 }.at) })
  |> list.take(overview_glances)
  |> list.map(glance_line)
  |> Ok
}

fn glance_line(pair: #(String, glance.Glance)) -> JsonValue {
  let #(strand, cell) = pair
  json.Object([
    #("strand", json.String(glance.clip(strand, overview_strand_bytes))),
    #("title", json.String(glance.clip(cell.title, overview_title_bytes))),
    #("summary", json.String(glance.clip(cell.summary, overview_summary_bytes))),
  ])
}

fn last_outcome(last: Option(operation.LastResult)) -> JsonValue {
  case last {
    Some(operation.RunLastResult(outcome: operation.RunCompleted(_), ..)) ->
      json.String("completed")
    Some(operation.RunLastResult(outcome: operation.RunFailed(_), ..)) ->
      json.String("failed")
    Some(operation.RunLastResult(outcome: operation.RunAborted, ..)) ->
      json.String("aborted")

    // A compaction or navigation is not a run, so it has no outcome the
    // picker could show as the session's last result.
    Some(operation.CompactionLastResult(..))
    | Some(operation.NavigationLastResult(..))
    | None -> json.Null
  }
}

// The final assistant text of main's last run. `LastResult` holds only the
// entry id, so this is one point read of that entry; a run with no final
// answer, or an entry with no text, reports null.
fn final_message(
  runtime: api.Runtime,
  last: Option(operation.LastResult),
) -> JsonValue {
  case last {
    Some(operation.RunLastResult(final_assistant: Some(id), ..)) ->
      // Clipping collapses whitespace first, so a message of only
      // whitespace is null here rather than an empty string.
      case glance.clip(assistant_text(runtime, id), overview_message_bytes) {
        "" -> json.Null
        text -> json.String(text)
      }
    Some(operation.RunLastResult(final_assistant: None, ..))
    | Some(operation.CompactionLastResult(..))
    | Some(operation.NavigationLastResult(..))
    | None -> json.Null
  }
}

fn assistant_text(runtime: api.Runtime, id: EntryId) -> String {
  case writer.get_entries(runtime.tree.writer, [id]) {
    Error(_) -> ""
    Ok(found) ->
      case dict.get(found, id) {
        Ok(entry.MessageEntry(
          message: message.AssistantMessage(content:, ..),
          ..,
        )) ->
          content
          |> list.filter_map(fn(block) {
            case block {
              message.AssistantText(text:, ..) -> Ok(text)
              _ -> Error(Nil)
            }
          })
          |> string.join(" ")
        _ -> ""
      }
  }
}

// Each field is clipped, but JSON escaping can still grow a clipped string
// several times over, so the encoded row is measured. An oversized row sheds
// its oldest glance first, then the final message. What remains is counts,
// fixed names, and a model clipped to 64 bytes, which fits even escaped.
fn fit_overview(
  base: List(#(String, JsonValue)),
  message: JsonValue,
  glances: List(JsonValue),
) -> JsonValue {
  let row =
    json.Object(
      list.append(base, [
        #("last_message", message),
        #("glances", json.Array(glances)),
      ]),
    )
  let fits = string.byte_size(json.to_string(row)) <= overview_row_bytes
  case fits, glances, message {
    True, _, _ -> row
    False, [_, ..], _ ->
      fit_overview(base, message, list.take(glances, list.length(glances) - 1))
    False, [], json.Null -> row
    False, [], _ -> fit_overview(base, json.Null, [])
  }
}
