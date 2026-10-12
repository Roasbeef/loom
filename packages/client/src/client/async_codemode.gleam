//// Code mode's detached execution surface, bound at session assembly.
////
//// Launch captures the exact request, including policy and approvals. The
//// worker receives a distinct broker step under the original operation and
//// a fixed deadline. Later interactions cannot change any of those terms.
////
//// A session whose workspace is on an executor keeps the same record and
//// service here, and runs the program there. `remote` is the service the
//// owner port serves to the executor's `code_mode` tool: its worker asks the
//// executor to run the program and waits for the value. `execution_routers`
//// is how the owner answers that program's own capability calls, bound to its
//// record as `launch` binds a local one.

import broker/broker
import broker/framing
import client/agency
import client/async_runs
import client/codemode
import client/owner_services.{type ExecutionTerms}
import client/remote/owner_port
import client/remote/protocol
import client/workflows
import codemode/internal/args
import codemode/satellite
import core/clock
import core/ids
import core/json
import core/msgpack
import gleam/int
import gleam/list
import gleam/option.{None, Some}
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
        interact: fn(strand, handle, interaction, within) {
          interact(service, strand, handle, interaction, within)
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
      launch: Some(async_execution.Launch(
        step: request.step_id,
        source_index: request.source_index,
      )),
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

  // Admission copies the worker into the service, then into its managed task.
  // The wrapper needs only its predecessor; retaining the original Config
  // here would duplicate every unrelated launch input at both boundaries.
  let wrap_router = config.wrap_router
  let config =
    codemode.Config(
      ..config,
      surface:,
      fixed_deadline: Some(record.deadline_ms),
      wrap_router: fn(bound, router) {
        let router = wrap_router(bound, router)
        let router = workflows.router(agents, custody, request, router)
        input_router(service, request.strand, id, router)
      },
    )
  let request = tool.Request(..request, step_id: record.step)
  async_runs.launch(service, record, fn() {
    codemode.execute(config, request) |> tool.execution_value
  })
}

// One interaction with an execution the strand owns, in the service's terms.
// A join is a check that waits; every other interaction answers at once.
fn interact(
  service: address.Address(async_runs.Message),
  strand: String,
  handle: String,
  interaction: tool.Interaction,
  within: Int,
) -> Result(json.JsonValue, String) {
  let #(action, wait) = case interaction {
    tool.Check -> #(async_runs.Check, 0)
    tool.Join -> #(async_runs.Check, int.max(0, within))
    tool.Cancel -> #(async_runs.Cancel, 0)
    tool.Send(value) -> #(async_runs.Send(value), 0)
    tool.SendTo(endpoint, value) -> #(async_runs.SendTo(endpoint, value), 0)
  }
  async_runs.interact(service, strand, handle, action, wait)
}

// --- executions on another node ---------------------------------------------------

/// The execution service a workspace on another node reaches through the
/// session's owner port (protocol-change/078, the addendum on background code
/// mode).
///
/// A launch claims the record here exactly as a local one does, with the
/// deadline on this machine's clock, and its worker is the host link's
/// `start`: the program runs on the executor while the worker waits for its
/// value, sending the start again after a dropped connection. An answer that
/// carries no value becomes the worker's failure, which the service records as
/// the execution's loss with that reason. Interactions are the local ones.
/// `standing` reads the record directly, for the owner port's reconciler.
///
/// ## Examples
///
/// ```gleam
/// // owner_port.Config(.., executions: async_codemode.remote(service,
/// //   runtime: agency.runtime_supplier(agency_config), clock:, session:))
/// ```
pub fn remote(
  service: address.Address(async_runs.Message),
  runtime runtime: fn() -> Result(api.Runtime, Nil),
  clock clock: clock.Clock,
  session session: String,
) -> owner_port.Executions {
  owner_port.Executions(
    launch: fn(terms, link) {
      launch_remote(service, clock, session, terms, link)
    },
    interact: fn(strand, handle, interaction, within) {
      interact(service, strand, handle, interaction, within)
    },
    standing: fn(key) { standing(runtime, key) },
  )
}

fn launch_remote(
  service: address.Address(async_runs.Message),
  clock: clock.Clock,
  session: String,
  terms: ExecutionTerms,
  link: owner_port.HostLink,
) -> Result(json.JsonValue, String) {
  let id =
    agent.call_site_digest(agent.Caller(
      strand: terms.strand,
      operation: terms.op_id,
      step_id: terms.launch_step,
      source_index: terms.source_index,
      minter: agent.ToolCall,
    ))
  let #(now, _) = clock.read(clock)
  let deadline_ms = now + terms.within_ms
  let record =
    async_execution.Execution(
      id:,
      strand: terms.strand,
      operation: terms.op_id,
      step: protocol.execution_step_prefix <> id,
      deadline_ms:,
      source: terms.source,
      seam: terms.seam,
      phase: async_execution.Starting,
      launch: Some(async_execution.Launch(
        step: terms.launch_step,
        source_index: terms.source_index,
      )),
    )
  let key = protocol.execution_key(session, terms.op_id, id)
  let start = link.start

  // The worker reads the clock when it sends, not when the launch was
  // claimed, so a start re-sent after a partition carries what is left.
  async_runs.launch_fallible(service, record, fn() {
    let #(sent_at, _) = clock.read(clock)
    case start(key, terms, deadline_ms - sent_at) {
      protocol.ExecutionFinished(value:) -> Ok(value)
      protocol.ExecutionLost ->
        Error(
          "the executor lost the execution: it restarted or stopped the "
          <> "program, which may have done part of its work",
        )
      protocol.ExecutionRefused(refusal:) ->
        Error(
          "the executor did not run the execution: "
          <> protocol.describe(refusal),
        )
    }
  })
}

// Where an execution's record stands. A record that cannot be read is taken
// as live, because the two things the answer decides, stopping the program and
// discarding its stored value, are both wrong to do on a guess; the next pass
// asks again.
fn standing(
  runtime: fn() -> Result(api.Runtime, Nil),
  key: protocol.Key,
) -> owner_port.Standing {
  let read = case protocol.execution_id(key) {
    // A tool call's key names no execution, so there is no record to want.
    Error(Nil) -> Ok(None)
    Ok(id) -> {
      use live <- result.try(runtime() |> result.replace_error(""))
      async_runs.record(live, id)
    }
  }
  case read {
    Error(_unreadable) -> owner_port.RecordLive
    Ok(None) -> owner_port.RecordClosed
    Ok(Some(found)) ->
      case found.phase {
        async_execution.Starting | async_execution.Running ->
          owner_port.RecordLive
        async_execution.Draining -> owner_port.RecordClosing
        async_execution.Finished(_) | async_execution.Lost(_) ->
          owner_port.RecordClosed
      }
  }
}

/// The routers a background program's owner-bound calls are answered by when
/// the program runs on another node: the execution's own mailbox and progress
/// channel, then its durable workflow steps, over `fallback`.
///
/// They are the routers `launch` composes into a local execution, bound to the
/// same record and custody, with the launching call's coordinates read from
/// the record instead of from a captured request.
///
/// ## Examples
///
/// ```gleam
/// // async_codemode.execution_routers(service, agents, custody, record, router)
/// ```
pub fn execution_routers(
  service: address.Address(async_runs.Message),
  agents: agency.Config,
  custody: api.AsyncCustody,
  launch: Launching,
  fallback: satellite.CapRouter,
) -> satellite.CapRouter {
  let stepped =
    workflows.router_for(
      agents,
      custody,
      agent.Caller(
        strand: launch.strand,
        operation: launch.operation,
        step_id: launch.step,
        source_index: launch.source_index,
        minter: agent.ToolCall,
      ),
      fallback,
    )
  input_router(service, launch.strand, launch.id, stepped)
}

/// The launching call of an execution, as `execution_routers` needs it.
pub type Launching {
  Launching(
    /// The execution's handle.
    id: String,
    /// The strand that launched it.
    strand: String,
    /// The launching operation.
    operation: ids.OpId,
    /// The launching call's planner step.
    step: String,
    /// The launching call's position in its step.
    source_index: Int,
  )
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

/// The capabilities the input router adds: the running execution's own
/// mailbox and progress channel to the run that owns it. Published so a
/// test can check that `codemode/tool_gate` has decided what each needs.
pub const serviced_caps = [
  "execution.receive", "execution.ready", "execution.receive_enveloped",
  "execution.progress", "execution.delivery",
]

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
        case
          after >= 0
          && within >= 0
          && within <= owner_services.max_receive_wait_ms
        {
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
      "execution.ready" -> {
        use endpoints <- result.try(args.string_array(request.args, "endpoints"))
        use idle <- result.try(args.int(request.args, "idle_within_ms"))
        case idle >= 1 && idle <= 300_000 {
          False ->
            Error(satellite.CapDenial(
              "invalid_argument",
              "ready requires an idle interval from 1 to 300000 ms",
            ))
          True ->
            served(service, strand, id, async_runs.Ready(endpoints, idle), 0)
        }
      }
      "execution.receive_enveloped" -> {
        use after <- result.try(args.int(request.args, "after"))
        use within <- result.try(args.int(request.args, "within_ms"))
        case
          after >= 0
          && within >= 0
          && within <= owner_services.max_receive_wait_ms
        {
          False ->
            Error(satellite.CapDenial(
              "invalid_argument",
              "receive requires a nonnegative cursor and a wait from 0 to 30000 ms",
            ))
          True ->
            served(
              service,
              strand,
              id,
              async_runs.ReceiveEnveloped(after),
              within,
            )
        }
      }
      "execution.progress" -> {
        use value <- result.try(args.field(request.args, "value"))
        served(
          service,
          strand,
          id,
          async_runs.Progress(tool.value_json(value)),
          0,
        )
      }
      "execution.delivery" -> {
        use sequence <- result.try(args.int(request.args, "sequence"))
        use endpoint <- result.try(args.string(request.args, "endpoint"))
        use delivered <- result.try(args.bool(request.args, "delivered"))
        use outcome <- result.try(case delivered {
          True -> Ok(async_runs.Delivered)
          False ->
            args.string(request.args, "reason")
            |> result.map(async_runs.Rejected)
        })
        served(
          service,
          strand,
          id,
          async_runs.Delivery(sequence:, endpoint:, outcome:),
          0,
        )
      }
      _ -> fallback(request)
    }
  }
}

fn served(
  service: address.Address(async_runs.Message),
  strand: String,
  id: String,
  action: async_runs.Action,
  within_ms: Int,
) -> Result(satellite.CapPlan, satellite.CapDenial) {
  Ok(
    satellite.ServedHere(fn() {
      case async_runs.interact(service, strand, id, action, within_ms) {
        Ok(value) -> framing.CapOk(json_value(value))
        Error(reason) -> framing.CapErr("execution_unavailable", reason)
      }
    }),
  )
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
