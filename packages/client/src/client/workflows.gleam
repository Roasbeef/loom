//// Background orchestration's durable named child-step capability.
////
//// The router binds sender and current execution custody from the launching
//// tool call. The program supplies names and input data, never an owner or a
//// previous operation identity. The Agency serializes intent and admission.

import broker/framing
import client/agency
import client/workflow_ledger
import codemode/internal/args
import codemode/orchestration
import codemode/satellite
import core/ids
import core/msgpack
import gleam/result
import gleam/string
import runtime/api
import tools/agent
import tools/blob
import tools/codemode

/// Wraps only the background orchestration router with durable child steps.
///
/// ## Examples
///
/// ```gleam
/// // workflows.router(agents, custody, launch, fallback)
/// ```
pub fn router(
  agents: agency.Config,
  custody: api.AsyncCustody,
  launch: codemode.Request,
  fallback: satellite.CapRouter,
) -> satellite.CapRouter {
  fn(request: satellite.CapRequest) {
    case request.cap {
      "workflow.step" if request.ordinal >= 32 ->
        Error(satellite.CapDenial(
          "admission_ceiling",
          "workflow step ceiling reached",
        ))
      "workflow.step" -> {
        use run <- result.try(args.string(request.args, "run"))
        use version <- result.try(args.string(request.args, "version"))
        use input <- result.try(args.string(request.args, "input"))
        use name <- result.try(args.string(request.args, "name"))
        use assignment <- result.try(args.field(request.args, "assignment"))
        use decoded <- result.try(orchestration.decode_spawn(assignment))
        use encoded <- result.try(
          msgpack.encode(assignment)
          |> result.map_error(fn(_) {
            args.invalid("invalid workflow assignment")
          }),
        )
        let step =
          workflow_ledger.Step(run, version, input, name, blob.ref_for(encoded))
        let caller =
          agent.Caller(
            launch.strand,
            launch.op_id,
            launch.step_id,
            launch.source_index,
            agent.Program(request.ordinal),
          )
        Ok(
          satellite.ServedHere(fn() {
            case agency.workflow_child(agents, caller, step, decoded, custody) {
              Error(refusal) ->
                framing.CapErr("workflow_refused", string.inspect(refusal))
              Ok(spawned) ->
                framing.CapOk(
                  msgpack.MapValue([
                    #(
                      msgpack.StringValue("strand"),
                      msgpack.StringValue(spawned.handle.strand),
                    ),
                    #(
                      msgpack.StringValue("operation"),
                      msgpack.StringValue(ids.op_id_to_string(
                        spawned.handle.operation,
                      )),
                    ),
                  ]),
                )
            }
          }),
        )
      }
      _ -> fallback(request)
    }
  }
}
