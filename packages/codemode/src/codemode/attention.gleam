//// The attention door: `attention.ask` and `attention.notice` for a program,
//// answered by the same closures the `ask` and `notice` tools use
//// (protocol-change/119).
////
//// ## Flow
////
//// `routing` → `ask_plan` or `notice_plan` → the door's closure → `CapOk`
////
//// 1. `routing` wraps a host router. The caller's identity is the admitted
////    execution's, never a field of the payload.
//// 2. A plan decodes the arguments with the tool's own decoder
////    (`tools/attention.ask_request`), so a program's call and a model's
////    call are refused in the same words.
//// 3. The plan is served here: the door's closure records the ask or find and
////    answers its id, which the plan returns as `{id}`.
////
//// ## An ask from a program does not end the turn
////
//// The tool ends its run with `TerminateRun`. A program's `attention.ask`
//// records the ask and returns its id and nothing more, and the `code_mode`
//// call's outcome stays `ContinueRun`, as it is for every outcome. Ending the
//// run when one inner call asked would change the termination of every
//// program for one capability, and a program may record an ask and still have
//// work to finish in the same execution. The capability's description tells
//// the model to end its turn after the program returns.
////
//// ## One implementation
////
//// The door holds the closures the tools hold, so the bound checks, the
//// strand check and the record writes have one implementation, as
//// `notes.put` shares `agent_note`'s closure.

import broker/framing
import codemode/identity
import codemode/internal/args
import codemode/internal/json_value
import codemode/satellite.{
  type CapDenial, type CapPlan, type CapRequest, type CapRouter,
}
import core/msgpack
import gleam/result
import tools/agent.{type Caller}
import tools/attention.{type AskRequest, type NoticeRequest, type Refusal}

/// The two recording closures, which are the tools' own.
pub type Door {
  Door(
    /// Records an ask under the authenticated caller and answers its id.
    ask: fn(Caller, AskRequest) -> Result(String, Refusal),
    /// Records a find under the authenticated caller and answers its id.
    notice: fn(Caller, NoticeRequest) -> Result(String, Refusal),
  )
}

/// Capability names actually answered by this door.
pub const serviced_caps = ["attention.ask", "attention.notice"]

/// The most asks one execution may make.
pub const max_asks = 8

/// The most notices one execution may make.
pub const max_notices = 32

/// Bounds each capability per execution, so a program that loops cannot fill
/// the inbox in one run.
///
/// ## Examples
///
/// ```gleam
/// assert list.length(attention.ceilings()) == 2
/// ```
pub fn ceilings() -> List(satellite.CapCeiling) {
  [
    satellite.CapCeiling(
      cap: "attention.ask",
      admissions: max_asks,
      code: "admission_ceiling",
    ),
    satellite.CapCeiling(
      cap: "attention.notice",
      admissions: max_notices,
      code: "admission_ceiling",
    ),
  ]
}

/// Adds only the attention operations to a host router. The strand and source
/// index are host-owned tool-call coordinates; the request supplies the
/// admitted operation and step. Unknown capabilities remain the underlying
/// router's.
///
/// ## Examples
///
/// ```gleam
/// // attention.routing(door, "main", 0, over: satellite.default_router)
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

    // Dispatch the capability to its plan; every other name is the router's.
    case request.cap {
      "attention.ask" -> ask_plan(door, caller, request)
      "attention.notice" -> notice_plan(door, caller, request)
      _ -> router(request)
    }
  }
}

/// Plans an `attention.ask` call, refusing arguments the tool would refuse.
fn ask_plan(
  door: Door,
  caller: Caller,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use held <- result.try(
    json_value.to_json(request.args) |> result.map_error(args.invalid),
  )
  use asked <- result.try(
    attention.ask_request(held) |> result.map_error(args.invalid),
  )
  Ok(satellite.ServedHere(fn() { answered(door.ask(caller, asked)) }))
}

/// Plans an `attention.notice` call, refusing arguments the tool would refuse.
fn notice_plan(
  door: Door,
  caller: Caller,
  request: CapRequest,
) -> Result(CapPlan, CapDenial) {
  use held <- result.try(
    json_value.to_json(request.args) |> result.map_error(args.invalid),
  )
  use noticed <- result.try(
    attention.notice_request(held) |> result.map_error(args.invalid),
  )
  Ok(satellite.ServedHere(fn() { answered(door.notice(caller, noticed)) }))
}

/// The wire reply: `{id}` for a recorded record, or the refusal's code and
/// the words the tool would give.
fn answered(recorded: Result(String, Refusal)) -> framing.CapOutcome {
  case recorded {
    Ok(id) ->
      framing.CapOk(
        msgpack.MapValue([
          #(msgpack.StringValue("id"), msgpack.StringValue(id)),
        ]),
      )
    Error(refusal) ->
      framing.CapErr(
        code: attention.refusal_code(refusal),
        message: attention.describe(refusal),
      )
  }
}
