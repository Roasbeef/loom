//// Code mode's detached execution surface, bound at session assembly.
////
//// Launch captures the exact request, including policy and approvals. The
//// worker receives a distinct broker step under the original operation and
//// a fixed deadline. Later interactions cannot change any of those terms.

import broker/broker
import broker/framing
import client/agency
import client/async_runs
import client/codemode
import client/workflows
import codemode/internal/args
import codemode/satellite
import core/clock
import core/ids
import core/json
import core/msgpack
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import runtime/api
import runtime/async_execution
import tools/agent
import tools/codemode as tool
import weft/registry as address

/// Supplies sync execution and the session's async handle operations.
///
/// ## Examples
///
/// ```gleam
/// // async_codemode.seam(config, service, agency_config)
/// ```
pub fn seam(
  config: codemode.Config,
  service: address.Address(async_runs.Message),
  agents: agency.Config,
) -> tool.CodeMode {
  let sync = codemode.seam(config)
  tool.CodeMode(
    ..sync,
    background: Some(
      tool.Background(
        launch: fn(request) { launch(config, service, agents, request) },
        interact: fn(strand, handle, action, within) {
          let #(action, wait) = case action {
            tool.Check -> #(async_runs.Check, 0)
            tool.Join -> #(async_runs.Check, int.max(0, within))
            tool.Cancel -> #(async_runs.Cancel, 0)
            tool.Send(value) -> #(async_runs.Send(value), 0)
          }
          async_runs.interact(service, strand, handle, action, wait)
        },
      ),
    ),
  )
}

fn launch(
  config: codemode.Config,
  service: address.Address(async_runs.Message),
  agents: agency.Config,
  request: tool.Request,
) -> Result(json.JsonValue, String) {
  let id =
    agent.call_site_digest(agent.Caller(
      strand: request.strand,
      operation: request.op_id,
      step_id: request.step_id,
      source_index: request.source_index,
      minter: agent.ToolCall,
    ))
  let #(now, _) = clock.read(config.clock)
  let record =
    async_execution.Execution(
      id:,
      strand: request.strand,
      operation: request.op_id,
      step: "async/" <> id,
      deadline_ms: now + request.within_ms,
      source: request.source,
      seam: tool.seam_name(request.seam),
      phase: async_execution.Starting,
    )
  let custody = api.AsyncCustody(request.strand, request.op_id, id, api.Owned)
  let execution_agency = agency.async_seam(agents, custody)
  let surface = case config.surface {
    codemode.Workspace -> codemode.Workspace
    codemode.Orchestration(spawn_ceiling:, ..) ->
      codemode.Orchestration(execution_agency, spawn_ceiling)
    codemode.Both(spawn_ceiling:, ..) ->
      codemode.Both(spawn_ceiling:, agency: execution_agency)
  }
  let config =
    codemode.Config(
      ..config,
      surface:,
      fixed_deadline: Some(record.deadline_ms),
      wrap_router: fn(bound, router) {
        let router = config.wrap_router(bound, router)
        let router = case request.seam {
          tool.OrchestrationSeam ->
            workflows.router(agents, custody, request, router)
          tool.WorkspaceSeam -> router
        }
        input_router(service, request.strand, id, router)
      },
    )
  let request = tool.Request(..request, step_id: record.step)
  async_runs.launch(service, record, fn() {
    codemode.execute(config, request) |> tool.execution_value
  })
}

/// The broker cancellation closure used by the session service.
///
/// ## Examples
///
/// ```gleam
/// // async_codemode.abort(broker)
/// ```
pub fn abort(broker: broker.Broker) -> fn(ids.OpId, String) -> Nil {
  fn(operation, step) { broker.abort_step(broker, operation, step) }
}

fn input_router(
  service: address.Address(async_runs.Message),
  strand: String,
  id: String,
  fallback: satellite.CapRouter,
) -> satellite.CapRouter {
  fn(request: satellite.CapRequest) {
    case request.cap {
      "execution.receive" -> {
        use after <- result.try(args.int(request.args, "after"))
        use within <- result.try(args.int(request.args, "within_ms"))
        case after >= 0 && within >= 0 && within <= 30_000 {
          False ->
            Error(satellite.CapDenial(
              "invalid_argument",
              "receive requires a nonnegative cursor and a wait from 0 to 30000 ms",
            ))
          True ->
            Ok(
              satellite.ServedHere(fn() {
                case
                  async_runs.interact(
                    service,
                    strand,
                    id,
                    async_runs.Receive(after),
                    within,
                  )
                {
                  Ok(value) -> framing.CapOk(json_value(value))
                  Error(reason) ->
                    framing.CapErr("execution_unavailable", reason)
                }
              }),
            )
        }
      }
      _ -> fallback(request)
    }
  }
}

fn json_value(value: json.JsonValue) -> msgpack.MsgPackValue {
  case value {
    json.Null -> msgpack.NilValue
    json.Bool(value) -> msgpack.BoolValue(value)
    json.Int(value) -> msgpack.IntValue(value)
    json.Float(value) -> msgpack.FloatValue(value)
    json.String(value) -> msgpack.StringValue(value)
    json.Array(values) -> msgpack.ArrayValue(list.map(values, json_value))
    json.Object(fields) ->
      msgpack.MapValue(
        list.map(fields, fn(field) {
          #(msgpack.StringValue(field.0), json_value(field.1))
        }),
      )
  }
}
