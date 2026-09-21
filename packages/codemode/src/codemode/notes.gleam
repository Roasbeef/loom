//// The shared notes door exposes durable data without agent lifecycle authority.
//// Caller identity comes from the admitted execution, never from its payload.
//// Agency owns key validation, namespaces, persistence, and result contracts.
//// Reads use its prefix scan but exact lookups filter by the complete key.
//// Each read form has a finite quota: get, list, and virtual reads together
//// admit at most 192 scans per execution. Existing strand aliases retain
//// their separate quotas on hosts that offer orchestration.

import broker/framing
import codemode/identity
import codemode/internal/args
import codemode/internal/json_value
import codemode/orchestration
import codemode/satellite.{
  type CapDenial, type CapPlan, type CapRequest, type CapRouter,
}
import core/json.{type JsonValue}
import core/msgpack
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/agent.{type Caller, type Refusal}

/// Only the two existing blackboard operations; no spawn or send authority.
pub type Door {
  Door(
    /// Writes under the authenticated caller's own namespace.
    put: fn(Caller, String, JsonValue) -> Result(Nil, Refusal),
    /// Reads session blackboard cells, returning full agent/ keys.
    scan: fn(Caller, Option(String)) ->
      Result(List(#(String, JsonValue)), Refusal),
  )
}

/// Capability names actually answered by this door.
pub const serviced_caps = ["notes.put", "notes.get", "notes.list", "notes.read"]

/// Maximum encoded JSON bytes in a stored value or list reply. The fixed
/// exact-read envelope is outside this bound. Larger products belong in
/// artifacts or workspace files, with a small note referencing them.
pub const max_bytes = 1_048_576

/// Bounds durable writes and all three prefix-scan entry points.
///
/// ## Examples
///
/// ```gleam
/// list.length(notes.ceilings()) == 4
/// ```
pub fn ceilings() -> List(satellite.CapCeiling) {
  list.map(
    [
      #("notes.put", 256),
      #("notes.get", 64),
      #("notes.list", 64),
      #("notes.read", 64),
    ],
    fn(entry) {
      satellite.CapCeiling(
        cap: entry.0,
        admissions: entry.1,
        code: "admission_ceiling",
      )
    },
  )
}

/// Adds only notes operations to a host router. The strand and source index
/// are host-owned tool-call coordinates; the request supplies the admitted
/// operation and step. Unknown capabilities remain the underlying router's.
///
/// ## Examples
///
/// ```gleam
/// // notes.routing(door, "main", 0, over: satellite.default_router)
/// ```
pub fn routing(
  door: Door,
  strand: String,
  source_index: Int,
  over router: CapRouter,
) -> CapRouter {
  fn(request: CapRequest) {
    let caller =
      agent.Caller(
        strand:,
        operation: identity.op_id(request.identity),
        step_id: identity.step_id(request.identity),
        source_index:,
        minter: agent.Program(ordinal: request.ordinal),
      )
    case request.cap {
      "notes.put" -> put_plan(door, caller, request)
      "notes.get" -> get_plan(door, caller, request)
      "notes.list" -> list_plan(door, caller, request)
      "notes.read" -> read_plan(door, caller, request)
      _ -> router(request)
    }
  }
}

fn put_plan(
  door: Door,
  caller: Caller,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use key <- result.try(args.string(request.args, "key"))
  use held <- result.try(args.field(request.args, "value"))
  use value <- result.try(
    json_value.to_json(held) |> result.map_error(args.invalid),
  )

  // The inbound msgpack decoder already rejects duplicate keys and bounds
  // nesting before routing. Conversion above refuses the two remaining
  // non-JSON shapes: binary values and objects with non-text keys.
  use _text <- result.try(bounded_text(value))
  Ok(
    satellite.ServedHere(fn() {
      case door.put(caller, key, value) {
        Ok(Nil) -> framing.CapOk(msgpack.NilValue)
        Error(refusal) -> refused(refusal)
      }
    }),
  )
}

fn get_plan(
  door: Door,
  caller: Caller,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use key <- result.try(args.string(request.args, "key"))
  Ok(
    satellite.ServedHere(fn() {
      case exact(door, caller, key) {
        Error(refusal) -> refused(refusal)
        Ok(None) -> answer(json.Object([#("found", json.Bool(False))]))
        Ok(Some(value)) -> found_answer(value)
      }
    }),
  )
}

fn list_plan(
  door: Door,
  caller: Caller,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use held <- result.try(args.field(request.args, "prefix"))
  use prefix <- result.try(case held {
    msgpack.NilValue -> Ok(None)
    msgpack.StringValue(text) -> Ok(Some(text))
    _ -> Error(args.invalid("prefix must be text or null"))
  })
  Ok(
    satellite.ServedHere(fn() {
      case door.scan(caller, prefix) {
        Error(refusal) -> refused(refusal)
        Ok(cells) ->
          answer(
            json.Object([
              #(
                "notes",
                json.Array(
                  list.map(cells, fn(cell) {
                    json.Object([
                      #("key", json.String(string.drop_start(cell.0, 6))),
                      #("value", cell.1),
                    ])
                  }),
                ),
              ),
            ]),
          )
      }
    }),
  )
}

fn read_plan(
  door: Door,
  caller: Caller,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use key <- result.try(args.string(request.args, "key"))
  Ok(
    satellite.ServedHere(fn() {
      case exact(door, caller, key) {
        Error(refusal) -> refused(refusal)
        Ok(None) ->
          framing.CapErr(
            code: "not_found",
            message: "No note at note://" <> key,
          )
        Ok(Some(value)) -> virtual_answer(value)
      }
    }),
  )
}

fn exact(
  door: Door,
  caller: Caller,
  key: String,
) -> Result(Option(JsonValue), Refusal) {
  use cells <- result.try(door.scan(caller, Some(key)))
  Ok(
    list.key_find(cells, agent.blackboard_prefix <> key)
    |> result.map(Some)
    |> result.unwrap(None),
  )
}

fn bounded_text(value: JsonValue) -> Result(String, CapDenial) {
  let text = json.to_string(value)
  case bit_array.byte_size(bit_array.from_string(text)) <= max_bytes {
    True -> Ok(text)
    False ->
      Error(satellite.CapDenial(
        code: "note_too_large",
        message: "Notes accept at most 1 MiB of JSON per value or list reply; use report.emit or a workspace file for larger data.",
      ))
  }
}

fn answer(value: JsonValue) -> framing.CapOutcome {
  case bounded_text(value) {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(_text) -> framing.CapOk(json_value.of_json(value))
  }
}

fn refused(refusal: Refusal) -> framing.CapOutcome {
  framing.CapErr(
    code: orchestration.refusal_code(refusal),
    message: agent.describe(refusal),
  )
}

// The virtual projection has the same byte bound as structured reads, but
// returns JSON text in the filesystem facade's existing contents envelope.
fn virtual_answer(value: JsonValue) -> framing.CapOutcome {
  case bounded_text(value) {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(text) ->
      framing.CapOk(
        msgpack.MapValue([
          #(msgpack.StringValue("contents"), msgpack.StringValue(text)),
        ]),
      )
  }
}

// Bound the stored value, excluding the fixed reply envelope, so a value
// accepted at the write limit remains readable through the structured API.
fn found_answer(value: JsonValue) -> framing.CapOutcome {
  case bounded_text(value) {
    Error(denial) -> framing.CapErr(code: denial.code, message: denial.message)
    Ok(_text) ->
      framing.CapOk(
        json_value.of_json(
          json.Object([
            #("found", json.Bool(True)),
            #("value", value),
          ]),
        ),
      )
  }
}
