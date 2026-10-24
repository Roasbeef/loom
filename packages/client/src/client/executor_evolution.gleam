//// The executor's evolution plane: one actor for each scope that stages,
//// serves, migrates, retires and inventories the generations of a promoted
//// extension, and evaluates and snapshots candidates, on this machine
//// (protocol-change/098).
////
//// A local session keeps its generations in `client/evolution/live`, which
//// runs inside the session's own VM. A session on an executor has no such
//// process, and the orchestrator that holds its catalogue cannot hold the
//// satellite, the helper pool or the jail a generation runs in. This module is
//// the executor's half: it holds what a stage builds, answers the six requests
//// that change no call row (`protocol.EvolutionRequest`), and gives the host
//// the two keyed calls (`host.Evolution`) that do. Until the orchestrator is
//// wired to it, the only way to reach it is the raw protocol messages.
////
//// ## One slot, and who is in it
////
//// A session has one executable slot, so the actor keeps at most one *serving*
//// generation. A generation that stopped serving because a newer one took the
//// slot, or because a migration published its successor, stays in `retiring`
//// until the orchestrator asks to retire it, so its in-flight calls can finish.
//// A stage joins what already exists before it builds anything: a stage for the
//// serving `(candidate, generation)` answers its handle, which is what a
//// re-send after a lost reply and a stage from a restarted runtime both need,
//// and a stage for the pair being staged joins the waiters. A stage for a
//// generation no newer than one the slot already holds is `StaleGeneration`,
//// because a selection's generation only increases and such a message is a dead
//// runtime's, arriving late under a token that is still current. A prepared
//// successor is held beside the serving generation and serves nothing until it
//// is published; a stage or a prepare never joins one, and either aborts an
//// unpublished one before it builds.
////
//// ## Why a stage runs in an owner, not in a short task
////
//// A generation is built from processes that trap exits and shut down when
//// their starter exits, whatever the reason: the helper pool, the broker, the
//// satellite's host. A stage that ran in an ordinary worker would hand the
//// actor a generation whose pool died as the worker returned. So the stage runs
//// in a weft task that is the generation's *owner*: it builds the generation,
//// reports it to the actor, and then stays alive, parked, until the actor
//// releases it. A release is sent only after the generation's `retire` task
//// confirmed that everything is stopped, so the owner's exit is the last event
//// of the generation, and the weft run's scope is the witness that it drained.
//// The actor performs a generation's `retire` itself, in its own turn, because
//// the closures behind it only message processes that are not the owner.
////
//// A prepare is different: it compiles into the running generation's own host
//// and plane and starts nothing of its own, so a short task is enough. So are
//// the snapshot, the hook and the inventory, each of which answers on the reply
//// subject its request carries from inside its task. The actor keeps answering
//// meanwhile, which is why a slow satellite does not hold a run of the serving
//// generation.
////
//// ## Closing is terminal
////
//// `retire_all` is what the scope's custody runs. It moves the actor to
//// `Closing`, from which every stage, prepare, hook, snapshot, inventory, run
//// and evaluate is refused (`NoEvolution`). A stage or a prepare already in
//// flight is awaited, not killed: killing an owner would cut its resources off
//// without a witness, and each task is bounded by its own deadlines. Whatever
//// the stage built is retired the moment it is reported, and its waiters are
//// told the plane is retired. Only when nothing is in flight does the actor
//// retire the serving and retiring generations and the retry witnesses of
//// stages that failed with an unconfirmed cleanup, answer the first failure it
//// met, and move to `Closed`. A second `retire_all` retries what failed. The
//// actor lingers a minute after `Closed` so that a request the host passed to
//// it just before the close is still answered, then stops.
////
//// <!-- transitions: executor_evolution.Phase -->
//// | Phase | Meaning | Leaves when |
//// | --- | --- | --- |
//// | `Open` | Serves every request. | `retire_all` arrives. |
//// | `Closing` | Refuses every request but a retire, and waits for the stage, prepare and snapshot in flight. | The last of them is delivered, and the sweep has answered the waiters. |
//// | `Closed` | Holds nothing, or only a retry for a failed cleanup, and refuses every request but a retire. | The actor stops after a quiet minute. |
////
//// ## What the machine supplies
////
//// The actor is written over an `Engine`, the five functions of the machine it
//// needs, so its rules are tested with counting closures and no jail. `engine_of`
//// builds the real one over a `local.Config`: it rebuilds a `tool.Ctx` from the
//// call's `Coordinates` through `wiring.context_for`, which revalidates the
//// stored authority against this machine's filesystem before it widens
//// anything, and then calls the catalogue-free core of `machine/local`.
////
//// ## Flow
////
//// `start` → `start_over` → `handle` → `stage` → `begin_stage` → `own` →
//// `built_by` → `finish_stage` → `retire_everything` → `settle` → `sweep`
////
//// 1. `start` builds the real `Engine` and starts the actor over it
////    (`start_over`).
//// 2. `handle` dispatches one message. `stage` judges a stage request against
////    the slot and, when it must build, `begin_stage` starts the owner task
////    that runs `own`.
//// 3. `own` builds the generation, reports it, and parks. `built_by` receives
////    the report and `finish_stage` puts the generation in the slot and answers
////    every waiter.
//// 4. `retire_everything` is the custody's `retire_all`. It waits, through
////    `settle`, until nothing is in flight, and `sweep` retires what the actor
////    holds.

import broker/internal/call
import client/escalate
import client/evolution/candidate as capture
import client/evolution/evaluate
import client/evolution/identity as compile_identity
import client/evolution/machine/local
import client/evolution/record
import client/evolution/retirement
import client/evolution/staged
import client/evolution/store
import client/extension/archive
import client/extension/hooks
import client/remote/host
import client/remote/protocol.{type Handle, type Refusal}
import client/wiring
import core/ids
import core/json.{type JsonValue}
import core/message
import core/msgpack.{type MsgPackValue}
import gleam/crypto
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import harness/tool_table
import machine/operation
import runtime/effects
import telemetry/field
import telemetry/log.{type Logger}
import tools/tool
import weft
import weft/actor

/// What the actor needs from the machine, as five functions.
///
/// Each answers in the terms of the machine seam and none touches a catalogue:
/// the orchestrator has already read the candidate and checked the selection,
/// and sends the candidate over the wire. A test builds an engine of counting
/// closures; `engine_of` builds the one an executor runs.
pub type Engine {
  Engine(
    /// Builds one approved candidate under a selection. It runs in the
    /// generation's owner task, so every process it starts is owned by that
    /// task for the generation's life.
    stage: fn(record.Selection, record.Candidate) ->
      Result(staged.Staged, store.Refusal),
    /// Captures a candidate's source from `directory` of the workspace.
    snapshot: fn(protocol.Coordinates, String) ->
      Result(archive.Tree, store.Refusal),
    /// Runs a candidate's author tests and answers the report.
    evaluate: fn(protocol.Coordinates, record.Candidate) ->
      Result(evaluate.Report, store.Refusal),
    /// Runs a program candidate once and answers the outcome the host stores.
    program: fn(protocol.Coordinates, record.Candidate, JsonValue) ->
      effects.ToolOutcome,
    /// Runs one tool of a serving generation and answers the outcome the host
    /// stores.
    promoted: fn(protocol.Coordinates, tool.Tool, JsonValue) ->
      effects.ToolOutcome,
  )
}

/// What `start` needs to build the real engine for one scope.
pub type Config {
  Config(
    /// The machine's own configuration: code-mode host, base policy, memory
    /// door, secrets, scratch and plane opener.
    local: local.Config,
    /// The scope's workspace as a tool context needs it. Only the fields a
    /// context reads are used; the registry is never consulted, because an
    /// evolution call never dispatches through it.
    view: wiring.WorkspaceView,
    /// What a policy refusal raised by a check turns into.
    refused: fn(escalate.Refused) -> escalate.Decision,
    /// The scope's logger.
    logger: Logger,
  )
}

/// One scope's evolution actor, held by whoever started it.
pub opaque type Executor {
  Executor(requests: Subject(Message), engine: Engine)
}

/// Whether the actor still serves.
type Phase {
  /// Serves every request.
  Open

  /// `retire_all` has been asked. The waiters are told when the sweep is done.
  Closing(waiters: List(Subject(Result(Nil, String))))

  /// The sweep ran. Only retries of what it could not confirm remain.
  Closed
}

/// What a message to the actor can be.
type Message {
  /// One of the six requests that change no call row.
  Serve(protocol.EvolutionRequest)

  /// Finds a tool of the serving generation for a promoted run, and checks the
  /// plane is open.
  Lookup(
    handle: Handle,
    name: String,
    reply: Subject(Result(tool.Tool, Refusal)),
  )

  /// Asks whether the plane is open, for an evaluate or a program run.
  Admit(reply: Subject(Result(Nil, Refusal)))

  /// The custody's retirement of the whole plane.
  RetireAll(reply: Subject(Result(Nil, String)))

  /// A generation's owner reports what the stage built, and the subject that
  /// releases it.
  OwnerReported(
    handle: Handle,
    built: Result(staged.Staged, store.Refusal),
    release: Subject(Release),
  )

  /// One of the actor's weft runs delivered an event.
  Delivered(ticket: Int, event: weft.Pulled(Answer, Failure))

  /// The actor was quiet for a while.
  Expire
}

/// The one command an owner takes: exit, because everything it owns is stopped.
type Release {
  Release
}

/// What a weft task of the actor returns.
type Answer {
  /// The task ended after doing its work. Its result went to its own reply.
  Exited

  /// A prepare built a successor.
  Readied(staged.PreparedStaged)
}

/// Why a weft task did not return an answer.
type Failure {
  /// The machine refused.
  Stored(store.Refusal)

  /// The task ended without answering.
  Fault(String)
}

/// What a running weft run is for, and what to do if it ends without its answer.
type Purpose {
  /// A generation's owner, named by the handle its stage was given.
  Owner(lineage: Handle)

  /// The prepare of a successor.
  Prepare

  /// A snapshot, which opens a plane of its own. `fail` answers the request.
  Capture(fail: fn(String) -> Nil)

  /// A hook or an inventory. `fail` answers the request.
  Quick(fail: fn(String) -> Nil)

  /// The task delivered its outcome; only the run's closing message remains.
  Spent
}

/// One weft run the actor started and has not heard the end of.
type Running {
  Running(
    /// Names the run in `Delivered`.
    ticket: Int,
    /// What the run is for.
    purpose: Purpose,
    /// Where the run's relay delivers.
    results: Subject(weft.Pulled(Answer, Failure)),
  )
}

/// One generation the executor holds.
type Generation {
  Generation(
    /// The handle the orchestrator knows it by.
    handle: Handle,
    /// The handle of the stage that began its lineage. A published successor
    /// shares its predecessor's owner, so the lineage names the owner.
    lineage: Handle,
    /// The value the stage built.
    built: staged.Staged,
    /// Releases the owner once `built.retire` has confirmed. A predecessor that
    /// a publish superseded holds none: its successor holds the shared owner.
    owner: Option(Subject(Release)),
  )
}

/// A stage in flight.
type Staging {
  Staging(
    /// The handle the stage will answer.
    handle: Handle,
    /// The selection being staged.
    selection: record.Selection,
    /// Everyone to answer when it ends.
    waiters: List(Subject(Result(protocol.Staged, Refusal))),
  )
}

/// A prepare in flight.
type Preparing {
  Preparing(
    /// The serving generation it prepares from.
    predecessor: Handle,
    /// The handle the successor will answer.
    successor: Handle,
    /// Whom to answer.
    reply: Subject(Result(protocol.TransitionAnswer, Refusal)),
  )
}

/// How far a prepared successor has got.
type Step {
  /// Built and waiting.
  Unpublished

  /// Made the serving generation. Kept so that a repeated publish answers again
  /// and an abort is refused.
  Published
}

/// The prepared successor of a serving generation.
type Held {
  Held(
    /// The generation it was prepared from.
    predecessor: Handle,
    /// The successor's handle.
    successor: Handle,
    /// The successor's value and its two closures.
    prepared: staged.PreparedStaged,
    /// How far it has got.
    step: Step,
  )
}

/// The retry witness of a failed stage whose cleanup was not confirmed, and the
/// owner that still holds what it started.
type Leftover {
  Leftover(retire: retirement.Task, owner: Option(Subject(Release)))
}

/// What the actor holds.
type State {
  State(
    engine: Engine,
    logger: Logger,
    /// The actor's own subject, selected beside every run's.
    inbox: Subject(Message),
    /// Sixteen strong random bytes drawn when the actor started, so a handle of
    /// an earlier start can never name a generation of this one.
    boot: BitArray,
    /// The ordinal of the next handle.
    next: Int,
    phase: Phase,
    serving: Option(Generation),
    staging: Option(Staging),
    preparing: Option(Preparing),
    held: Option(Held),
    /// Generations that stopped serving and wait for their retire.
    retiring: List(Generation),
    leftovers: List(Leftover),
    /// The weft runs in flight.
    runs: List(Running),
    /// The ticket of the next run.
    ticket: Int,
  )
}

/// What the slot says about a stage request.
type Verdict {
  /// The serving generation is exactly this one.
  Joins(Generation)

  /// This pair is being staged.
  Waits

  /// The request cannot be served.
  Refuses(Refusal)

  /// Nothing in the slot answers it: build.
  Starts
}

/// How long a closed actor lingers for a request the host passed to it before
/// the close.
const linger_ms = 60_000

/// How long a caller waits for the actor to answer an admission or a lookup.
const ask_ms = 5000

/// How long the custody waits for the retirement. A stage in flight is awaited,
/// and it is bounded by the deadlines of its own build.
const retire_wait_ms = 600_000

/// Slack added to a hook's own deadline before its run is cut.
const hook_slack_ms = 30_000

/// Builds the real engine for one scope and starts the actor over it.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(executor) = executor_evolution.start(config)
/// ```
pub fn start(config: Config) -> Result(Executor, String) {
  start_over(engine_of(config), config.logger)
}

/// Starts the actor over any engine. The actor starts unlinked, because the
/// process that builds a scope is short-lived and the plane lives as long as
/// the scope; its end is `retire_all`, then a quiet minute.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(executor) = executor_evolution.start_over(engine, log.discard())
/// ```
pub fn start_over(engine: Engine, logger: Logger) -> Result(Executor, String) {
  let boot = crypto.strong_random_bytes(16)
  actor.new_with_initialiser(5000, fn(inbox) {
    actor.initialised(State(
      engine:,
      logger:,
      inbox:,
      boot:,
      next: 1,
      phase: Open,
      serving: None,
      staging: None,
      preparing: None,
      held: None,
      retiring: [],
      leftovers: [],
      runs: [],
      ticket: 0,
    ))
    |> actor.selecting(process.new_selector() |> process.select(inbox))
    |> actor.returning(inbox)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.idle_timeout(linger_ms, Expire)
  |> actor.unlinked
  |> actor.start
  |> result.map(fn(started) { Executor(requests: started.data, engine:) })
  |> result.map_error(string.inspect)
}

/// What the host calls for this scope's evolution messages.
///
/// `serve` hands a request to the actor, which answers on the subject the
/// request carries. `evaluate` and `run` run in the host's own job process and
/// check with the actor first, so a closed plane refuses them; a promoted run
/// takes its tool from the serving generation and runs it in the caller, where
/// the host can kill it.
///
/// ## Examples
///
/// ```gleam
/// // host.Plane(.., evolution: Some(executor_evolution.plane(executor)))
/// ```
pub fn plane(executor: Executor) -> host.Evolution {
  host.Evolution(
    evaluate: fn(coordinates, candidate) {
      evaluated(executor, coordinates, candidate)
    },
    run: fn(coordinates, target, args) {
      ran(executor, coordinates, target, args)
    },
    serve: fn(request) { process.send(executor.requests, Serve(request)) },
  )
}

/// Retires the plane: the scope's custody runs this, and it is terminal.
///
/// The answer waits for a stage, a prepare or a snapshot in flight, retires
/// every generation and every retry witness the actor holds, and is `Ok` only
/// when all of them confirmed. A failure names the first reason and keeps the
/// retries, which a second call performs again. An actor that is not running
/// holds nothing it can prove stopped, so that is an error too.
///
/// ## Examples
///
/// ```gleam
/// // executor_evolution.retire_all(executor)
/// ```
pub fn retire_all(executor: Executor) -> Result(Nil, String) {
  call.try_call(executor.requests, waiting: retire_wait_ms, sending: RetireAll)
  |> result.map_error(fn(_unreachable) {
    "the evolution plane did not answer its retirement"
  })
  |> result.flatten
}

/// The compile identity this machine would stamp on a candidate, which the
/// census carries so the orchestrator opens its catalogue under it.
///
/// ## Examples
///
/// ```gleam
/// // executor_evolution.identity(local_config)
/// ```
pub fn identity(config: local.Config) -> Result(record.Identity, String) {
  compile_identity.current(config.host)
}

/// The check's report, or the reason it was refused, as the JSON the host
/// stores for an `EvolutionEvaluate`.
///
/// A report is `{"status": "reported", "verdict", "reason", "observation"}`
/// where `verdict` is `passed`, `failed` or `inconclusive` and `reason` is the
/// inconclusive verdict's. A refusal is `{"status": "refused", "reason"}`. The
/// observation is the bounded JSON text the evaluator already produced, so the
/// whole stays well under the execution reservation.
///
/// ## Examples
///
/// ```gleam
/// assert executor_evolution.report_json(Error(store.Busy))
///   == json.Object([
///     #("status", json.String("refused")),
///     #("reason", json.String("catalogue busy")),
///   ])
/// ```
pub fn report_json(
  answer: Result(evaluate.Report, store.Refusal),
) -> JsonValue {
  case answer {
    Ok(evaluate.Report(verdict:, observation:)) -> {
      let #(name, reason) = case verdict {
        record.Passed -> #("passed", "")
        record.Failed -> #("failed", "")
        record.Inconclusive(reason:) -> #("inconclusive", reason)
      }
      json.Object([
        #("status", json.String("reported")),
        #("verdict", json.String(name)),
        #("reason", json.String(reason)),
        #("observation", json.String(observation)),
      ])
    }
    Error(refusal) ->
      json.Object([
        #("status", json.String("refused")),
        #("reason", json.String(store.describe(refusal))),
      ])
  }
}

/// Reads the JSON `report_json` wrote: `Ok(Ok(report))` for a report,
/// `Ok(Error(reason))` for a refusal the machine gave, and `Error(why)` for a
/// value that is neither, which the orchestrator treats as a lost answer.
///
/// ## Examples
///
/// ```gleam
/// assert executor_evolution.decode_report(executor_evolution.report_json(
///     Ok(evaluate.Report(record.Passed, "{}")),
///   ))
///   == Ok(Ok(evaluate.Report(record.Passed, "{}")))
/// ```
pub fn decode_report(
  value: JsonValue,
) -> Result(Result(evaluate.Report, String), String) {
  case value {
    json.Object(fields) -> {
      use status <- result.try(text_field(fields, "status"))
      case status {
        "reported" -> {
          use verdict <- result.try(text_field(fields, "verdict"))
          use reason <- result.try(text_field(fields, "reason"))
          use observation <- result.try(text_field(fields, "observation"))
          use verdict <- result.try(case verdict {
            "passed" -> Ok(record.Passed)
            "failed" -> Ok(record.Failed)
            "inconclusive" -> Ok(record.Inconclusive(reason:))
            other -> Error("unknown verdict `" <> other <> "`")
          })
          Ok(Ok(evaluate.Report(verdict:, observation:)))
        }
        "refused" -> {
          use reason <- result.try(text_field(fields, "reason"))
          Ok(Error(reason))
        }
        other -> Error("unknown status `" <> other <> "`")
      }
    }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error("the report is not a JSON object")
  }
}

/// One string field of a report object, or why it is missing.
fn text_field(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  case list.key_find(fields, name) {
    Ok(json.String(text)) -> Ok(text)
    Ok(json.Object(_))
    | Ok(json.Array(_))
    | Ok(json.Int(_))
    | Ok(json.Float(_))
    | Ok(json.Bool(_))
    | Ok(json.Null)
    | Error(Nil) -> Error("the report has no text field `" <> name <> "`")
  }
}

// --- the real engine ------------------------------------------------------------

/// The engine an executor runs: the machine's catalogue-free core over a tool
/// context rebuilt from the call's coordinates.
///
/// ## Examples
///
/// ```gleam
/// // executor_evolution.start_over(executor_evolution.engine_of(config), logger)
/// ```
pub fn engine_of(config: Config) -> Engine {
  let clock = config.view.clock
  Engine(
    stage: fn(selection, candidate) {
      local.stage_candidate(config.local, candidate, selection)
    },
    snapshot: fn(coordinates, directory) {
      use #(ctx, _run) <- result.try(
        context_for(config, coordinates, "evolution_snapshot", json.Null)
        |> result.map_error(store.Authority),
      )
      use path <- result.try(capture.source_path(ctx, directory, []))
      local.snapshot(config.local, ctx, path)
    },
    evaluate: fn(coordinates, candidate) {
      use #(ctx, _run) <- result.try(
        context_for(config, coordinates, "evolution_test", json.Null)
        |> result.map_error(store.Authority),
      )
      local.evaluate_candidate_of(config.local, ctx, candidate)
    },
    program: fn(coordinates, candidate, args) {
      case context_for(config, coordinates, "evolution_program", args) {
        Error(reason) -> effects.ToolFailed(reason:)
        Ok(#(ctx, run)) ->
          case local.invoke_program_of(config.local, candidate, ctx, args) {
            Ok(outcome) -> tool_table.finished(outcome, run, clock)
            Error(refusal) ->
              tool_table.finished(
                tool.failure(store.describe(refusal)),
                run,
                clock,
              )
          }
      }
    },
    promoted: fn(coordinates, declared, args) {
      case context_for(config, coordinates, declared.name, args) {
        Error(reason) -> effects.ToolFailed(reason:)
        Ok(#(ctx, run)) ->
          tool_table.finished(declared.run(ctx, args), run, clock)
      }
    },
  )
}

/// The tool context an evolution call runs under, and the `ToolRun` that names
/// it. The orchestrator's door call has no `ToolRun` of its own here, so one is
/// synthesised from the call's key: its call id is `evolution/<step>/<index>`,
/// which no model-made call can carry, and its grants are empty because the
/// stored `Authority` is the only carrier. `context_for` revalidates that
/// authority against this machine's filesystem before it widens the policy. A
/// check has no rolling output tail on an executor, because the door call's id
/// is not on the wire.
fn context_for(
  config: Config,
  coordinates: protocol.Coordinates,
  name: String,
  arguments: JsonValue,
) -> Result(#(tool.Ctx, effects.ToolRun), String) {
  let key = coordinates.key
  use op <- result.try(
    ids.parse_op_id(key.op)
    |> result.map_error(fn(_report) { "the call's operation id is malformed" }),
  )
  let run =
    effects.ToolRun(
      operation: op,
      step_id: key.step,
      source_index: key.source_index,
      strand: coordinates.strand,
      call: message.ToolCall(
        id: "evolution/" <> key.step <> "/" <> int.to_string(key.source_index),
        name:,
        arguments:,
        thought_signature: None,
        namespace: None,
      ),
      arguments:,
      replay: operation.ReplayNever,
      grants: [],
    )
  use ctx <- result.try(wiring.context_for(
    config.view,
    config.refused,
    fn(_run) { tool.ignore_output() },
    run,
    coordinates.authority,
  ))
  Ok(#(ctx, run))
}

// --- the host's two keyed calls ---------------------------------------------------

/// A check, answered as the JSON the host stores. A closed plane answers a
/// refusal in the same shape, so the orchestrator reads one vocabulary.
fn evaluated(
  executor: Executor,
  coordinates: protocol.Coordinates,
  candidate: record.Candidate,
) -> JsonValue {
  case ask(executor, Admit) {
    Ok(Nil) -> report_json(executor.engine.evaluate(coordinates, candidate))
    Error(refusal) ->
      report_json(Error(store.Unavailable(protocol.describe(refusal))))
  }
}

/// A promoted tool or a program, run in the host's job process. A promoted run
/// takes its tool from the serving generation first, which is where a stale
/// handle and a closed plane are refused.
fn ran(
  executor: Executor,
  coordinates: protocol.Coordinates,
  target: protocol.Target,
  args: JsonValue,
) -> effects.ToolOutcome {
  case target {
    protocol.Promoted(handle:, tool: name) ->
      case ask(executor, Lookup(handle, name, _)) {
        Ok(declared) -> executor.engine.promoted(coordinates, declared, args)
        Error(refusal) -> effects.ToolFailed(reason: protocol.describe(refusal))
      }
    protocol.Program(candidate:) ->
      case ask(executor, Admit) {
        Ok(Nil) -> executor.engine.program(coordinates, candidate, args)
        Error(refusal) -> effects.ToolFailed(reason: protocol.describe(refusal))
      }
  }
}

/// One bounded question to the actor. An actor that is gone answers like a
/// closed one, because nothing it held can be served.
fn ask(
  executor: Executor,
  sending: fn(Subject(Result(a, Refusal))) -> Message,
) -> Result(a, Refusal) {
  call.try_call(executor.requests, waiting: ask_ms, sending:)
  |> result.map_error(fn(_unreachable) { retired() })
  |> result.flatten
}

/// The refusal every request but a retire meets once the plane is closed.
fn retired() -> Refusal {
  protocol.NoEvolution("the scope's evolution plane has been retired")
}

// --- the actor ----------------------------------------------------------------------

/// Dispatches one message.
fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Serve(request) -> serve(state, request)
    Lookup(handle:, name:, reply:) -> lookup(state, handle, name, reply)
    Admit(reply:) -> {
      process.send(reply, admitted(state))
      proceed(state)
    }
    RetireAll(reply:) -> retire_everything(state, reply)
    OwnerReported(handle:, built:, release:) ->
      built_by(state, handle, built, release)
    Delivered(ticket:, event:) -> delivered(state, ticket, event)
    Expire -> expire(state)
  }
}

/// Keeps the actor and selects from the runs it holds. Every handler ends here,
/// so the selector always names exactly the runs in `state.runs`.
fn proceed(state: State) -> actor.Next(State, Message) {
  actor.continue(state)
  |> actor.with_selector(selector_of(state))
}

/// The selector for the actor's inbox and the subject of every run in flight.
fn selector_of(state: State) -> process.Selector(Message) {
  list.fold(
    state.runs,
    process.new_selector() |> process.select(state.inbox),
    fn(selector, running) {
      process.select_map(selector, running.results, fn(event) {
        Delivered(running.ticket, event)
      })
    },
  )
}

/// A quiet closed actor has nothing left to answer, and its end cancels the
/// runs it still holds through the links of their relays. An open actor stays.
fn expire(state: State) -> actor.Next(State, Message) {
  case state.phase {
    Closed -> actor.stop()
    Open | Closing(_) -> proceed(state)
  }
}

/// Continues only while the plane is open; otherwise `refuse` answers the
/// request and nothing else changes.
fn when_open(
  state: State,
  refuse: fn() -> Nil,
  then: fn() -> actor.Next(State, Message),
) -> actor.Next(State, Message) {
  case state.phase {
    Open -> then()
    Closing(_) | Closed -> {
      refuse()
      proceed(state)
    }
  }
}

/// Whether an evaluate or a program run may start: only while the plane is open.
fn admitted(state: State) -> Result(Nil, Refusal) {
  case state.phase {
    Open -> Ok(Nil)
    Closing(_) | Closed -> Error(retired())
  }
}

/// The six requests the host hands over once the fence has passed.
fn serve(
  state: State,
  request: protocol.EvolutionRequest,
) -> actor.Next(State, Message) {
  case request {
    protocol.SnapshotRequest(coordinates:, directory:, reply:) ->
      snapshot(state, coordinates, directory, reply)
    protocol.StageRequest(selection:, candidate:, reply:) ->
      stage(state, selection, candidate, reply)
    protocol.HookRequest(handle:, event:, payload:, within_ms:, reply:) ->
      hook(state, handle, event, payload, within_ms, reply)
    protocol.TransitionRequest(step:, reply:) -> transition(state, step, reply)
    protocol.RetireRequest(handle:, reply:) -> retire(state, handle, reply)
    protocol.InventoryRequest(handle:, reply:) ->
      inventory(state, handle, reply)
  }
}

/// A promoted run asks here for its tool, so that a handle that is not serving
/// and a closed plane are refused before anything runs.
fn lookup(
  state: State,
  handle: Handle,
  name: String,
  reply: Subject(Result(tool.Tool, Refusal)),
) -> actor.Next(State, Message) {
  let found = case state.phase, state.serving {
    Open, Some(generation) if generation.handle == handle ->
      list.find(generation.built.tools, fn(declared) { declared.name == name })
      |> result.map_error(fn(_missing) {
        protocol.Invalid(
          "the generation declares no tool named `" <> name <> "`",
        )
      })
    Open, Some(_) | Open, None -> Error(protocol.UnknownHandle)
    Closing(_), _ | Closed, _ -> Error(retired())
  }
  process.send(reply, found)
  proceed(state)
}

// --- stage ----------------------------------------------------------------------------

/// A stage request. The slot judges it first: a stage joins the generation or
/// the stage it names, or is refused, before anything is built.
fn stage(
  state: State,
  selection: record.Selection,
  candidate: record.Candidate,
  reply: Subject(Result(protocol.Staged, Refusal)),
) -> actor.Next(State, Message) {
  use <- when_open(state, fn() { process.send(reply, Error(retired())) })
  case judge(state, selection) {
    Joins(generation) -> {
      let superseded = list.map(state.retiring, fn(old) { old.handle })
      process.send(reply, Ok(reply_of(generation, superseded)))
      proceed(state)
    }

    Waits -> proceed(wait_for_stage(state, reply))

    Refuses(refusal) -> {
      process.send(reply, Error(refusal))
      proceed(state)
    }

    Starts -> begin_stage(state, selection, candidate, reply)
  }
}

/// What the slot says about a stage for `selection`.
fn judge(state: State, selection: record.Selection) -> Verdict {
  case serving_pair(state, selection), state.staging {
    // The serving generation is exactly this one: a re-send after a lost reply,
    // or a stage from a runtime that restarted inside the open.
    Ok(serving), _ -> Joins(serving)

    Error(Nil), Some(staging) ->
      case same_pair(staging.selection, selection) {
        // This pair is already being staged.
        True -> Waits

        // Another pair is being staged: one slot, one stage at a time.
        False -> Refuses(contested(staging.selection, selection))
      }

    Error(Nil), None -> judge_idle(state, selection)
  }
}

/// The serving generation, when it is the pair asked for.
fn serving_pair(
  state: State,
  selection: record.Selection,
) -> Result(Generation, Nil) {
  case state.serving {
    Some(serving) ->
      case same_pair(serving.built.selection, selection) {
        True -> Ok(serving)
        False -> Error(Nil)
      }
    None -> Error(Nil)
  }
}

/// The verdict for a stage when none is in flight: refused as stale, refused
/// while an in-place successor is being prepared, or started.
fn judge_idle(state: State, selection: record.Selection) -> Verdict {
  let held = newest_generation(state)
  case selection.generation <= held, state.preparing {
    // A generation only increases, so this is a dead runtime's message arriving
    // late under a token that is still current. Serving it would put two
    // generations in the slot.
    True, _ -> Refuses(protocol.StaleGeneration(serving: held))
    False, Some(_) ->
      Refuses(protocol.ExecutorFault(
        "an in-place successor is being prepared; stage again once it settles",
      ))
    False, None -> Starts
  }
}

/// The refusal for a stage asked while a different pair is being staged.
fn contested(staging: record.Selection, asked: record.Selection) -> Refusal {
  case asked.generation <= staging.generation {
    True -> protocol.StaleGeneration(serving: staging.generation)
    False ->
      protocol.ExecutorFault(
        "a stage for generation "
        <> int.to_string(staging.generation)
        <> " is in flight; stage again once it settles",
      )
  }
}

/// Whether two selections name the same candidate at the same generation.
fn same_pair(held: record.Selection, asked: record.Selection) -> Bool {
  held.candidate_id == asked.candidate_id && held.generation == asked.generation
}

/// The newest generation the slot holds in any form: serving, or stopped and
/// waiting for its retire. A prepared successor is not counted, because it has
/// not been selected.
fn newest_generation(state: State) -> Int {
  let generations = case state.serving {
    Some(serving) -> [serving, ..state.retiring]
    None -> state.retiring
  }
  list.fold(generations, 0, fn(newest, generation) {
    int.max(newest, generation.built.selection.generation)
  })
}

/// Adds a waiter to the stage in flight, so a second request for the same
/// pair is answered by the one build.
fn wait_for_stage(
  state: State,
  reply: Subject(Result(protocol.Staged, Refusal)),
) -> State {
  case state.staging {
    Some(staging) ->
      State(
        ..state,
        staging: Some(Staging(..staging, waiters: [reply, ..staging.waiters])),
      )

    // `judge` answered `Waits` only for a stage in flight, so this cannot be
    // reached; the waiter is answered rather than left without a reply.
    None -> {
      process.send(reply, Error(retired()))
      state
    }
  }
}

/// What the orchestrator is told about a generation: everything it needs to
/// build the `live.Generation` over messages.
fn reply_of(
  generation: Generation,
  superseded: List(Handle),
) -> protocol.Staged {
  let built = generation.built
  protocol.Staged(
    handle: generation.handle,
    name: built.name,
    tools: list.map(built.tools, tool.describe),
    hooks: built.events,
    activation: case built.upgrade {
      Some(_) -> protocol.InPlace
      None -> protocol.Replacement
    },
    superseded:,
  )
}

/// Starts the owner of a new generation. An unpublished successor is aborted
/// first, because it is a successor of a generation this stage will supersede,
/// and a stage never joins one.
fn begin_stage(
  state: State,
  selection: record.Selection,
  candidate: record.Candidate,
  reply: Subject(Result(protocol.Staged, Refusal)),
) -> actor.Next(State, Message) {
  let state = abandon_held(state)
  let handle = protocol.Handle(boot: state.boot, ordinal: state.next)
  let engine = state.engine
  let inbox = state.inbox
  let owner =
    weft.task(fn() { own(engine, inbox, handle, selection, candidate) })
  let state =
    State(
      ..state,
      next: state.next + 1,
      staging: Some(Staging(handle:, selection:, waiters: [reply])),
    )
  proceed(launch(state, Owner(lineage: handle), owner, None))
}

/// A generation's owner. The stage runs here so that everything it starts is
/// owned by this process, and the process then parks until it is released: its
/// exit is the last event of the generation, and the weft run's scope is the
/// witness that it drained. The report goes first, so the actor never waits on
/// the release to learn the result. A stage that failed parks as well, because a
/// failure whose cleanup was unconfirmed leaves resources that this process
/// still owns, and the actor releases it as soon as nothing needs it.
fn own(
  engine: Engine,
  inbox: Subject(Message),
  handle: Handle,
  selection: record.Selection,
  candidate: record.Candidate,
) -> Result(Answer, Failure) {
  let release = process.new_subject()
  process.send(
    inbox,
    OwnerReported(handle:, built: engine.stage(selection, candidate), release:),
  )
  let Release = process.receive_forever(release)
  Ok(Exited)
}

/// The owner's report. The stage it answers is normally the one in flight; a
/// report that finds no such stage arrived after the stage was abandoned, and
/// what it built is kept to be retired.
fn built_by(
  state: State,
  handle: Handle,
  built: Result(staged.Staged, store.Refusal),
  release: Subject(Release),
) -> actor.Next(State, Message) {
  case state.staging {
    Some(staging) if staging.handle == handle ->
      proceed(finish_stage(
        State(..state, staging: None),
        staging,
        built,
        release,
      ))

    Some(_) | None -> proceed(keep_orphan(state, handle, built, release))
  }
}

/// Ends a stage: in the slot when it succeeded and the plane is open, retired
/// when the plane closed meanwhile, and a refusal when it failed. Every waiter
/// is answered.
fn finish_stage(
  state: State,
  staging: Staging,
  built: Result(staged.Staged, store.Refusal),
  release: Subject(Release),
) -> State {
  case state.phase, built {
    Open, Ok(built) -> {
      let generation =
        Generation(
          handle: staging.handle,
          lineage: staging.handle,
          built:,
          owner: Some(release),
        )
      let state = take_slot(state, generation)
      let superseded = list.map(state.retiring, fn(old) { old.handle })
      reply_all(staging.waiters, Ok(reply_of(generation, superseded)))
      state
    }

    Open, Error(refusal) -> {
      reply_all(staging.waiters, Error(fault_of(refusal)))
      forfeit(state, refusal, Some(release))
    }

    // The plane closed while the stage ran. What was built never served, and
    // is retired by the sweep with everything else.
    Closing(_), Ok(built) | Closed, Ok(built) -> {
      reply_all(staging.waiters, Error(retired()))
      settle(
        State(..state, retiring: [
          Generation(
            handle: staging.handle,
            lineage: staging.handle,
            built:,
            owner: Some(release),
          ),
          ..state.retiring
        ]),
      )
    }

    Closing(_), Error(refusal) | Closed, Error(refusal) -> {
      reply_all(staging.waiters, Error(retired()))
      settle(forfeit(state, refusal, Some(release)))
    }
  }
}

/// The new generation takes the slot. The one that served stops serving and
/// waits for its retire, so its calls in flight can finish.
fn take_slot(state: State, generation: Generation) -> State {
  let retiring = case state.serving {
    Some(old) -> [old, ..state.retiring]
    None -> state.retiring
  }
  State(..state, serving: Some(generation), retiring:)
}

/// A report with no stage to answer. A built generation waits in `retiring`,
/// where the orchestrator's retire or the close finds it; a failure is settled
/// as any other.
fn keep_orphan(
  state: State,
  handle: Handle,
  built: Result(staged.Staged, store.Refusal),
  release: Subject(Release),
) -> State {
  case built {
    Ok(built) ->
      State(..state, retiring: [
        Generation(handle:, lineage: handle, built:, owner: Some(release)),
        ..state.retiring
      ])
    Error(refusal) -> forfeit(state, refusal, Some(release))
  }
}

/// A failed build or prepare. When its cleanup was not confirmed, its retry
/// witness is kept, and the owner that still holds what it started is not
/// released until the retry succeeds. Every other refusal released nothing.
fn forfeit(
  state: State,
  refusal: store.Refusal,
  owner: Option(Subject(Release)),
) -> State {
  case refusal {
    store.CleanupUnconfirmed(_, retry) ->
      State(..state, leftovers: [Leftover(retry, owner), ..state.leftovers])

    store.Busy
    | store.Corrupt(..)
    | store.Unknown
    | store.Stale
    | store.NotApproved
    | store.Changed
    | store.Bounds(..)
    | store.Authority(..)
    | store.TestFailed(..)
    | store.Unavailable(..) -> {
      release_owner(owner)
      state
    }
  }
}

/// Releases a generation's owner, which then exits and ends its weft run.
fn release_owner(owner: Option(Subject(Release))) -> Nil {
  case owner {
    Some(subject) -> process.send(subject, Release)
    None -> Nil
  }
}

/// Sends one answer to every waiter of a stage or a close.
fn reply_all(waiters: List(Subject(a)), value: a) -> Nil {
  list.each(waiters, fn(waiter) { process.send(waiter, value) })
}

/// The refusal a machine failure becomes on the wire. An argument or an
/// authority the machine would never accept is `Invalid`; anything else is the
/// executor failing to complete the operation.
fn fault_of(refusal: store.Refusal) -> Refusal {
  let reason = store.describe(refusal)
  case refusal {
    store.Bounds(..) | store.Authority(..) -> protocol.Invalid(reason:)

    store.Busy
    | store.Corrupt(..)
    | store.Unknown
    | store.Stale
    | store.NotApproved
    | store.Changed
    | store.TestFailed(..)
    | store.CleanupUnconfirmed(..)
    | store.Unavailable(..) -> protocol.ExecutorFault(reason:)
  }
}

// --- the in-place upgrade ---------------------------------------------------------------

/// One step of a migration.
fn transition(
  state: State,
  step: protocol.TransitionStep,
  reply: Subject(Result(protocol.TransitionAnswer, Refusal)),
) -> actor.Next(State, Message) {
  case step {
    protocol.Prepare(handle:, selection:, candidate:) ->
      prepare(state, handle, selection, candidate, reply)
    protocol.Publish(handle:, successor:) ->
      publish(state, handle, successor, reply)
    protocol.Abort(handle:, successor:) ->
      abort(state, handle, successor, reply)
  }
}

/// Builds a successor beside the serving generation. It never joins an earlier
/// successor, whose state may be older than the generation's: an unpublished one
/// is aborted, and the successor is prepared from what the generation holds now.
fn prepare(
  state: State,
  handle: Handle,
  selection: record.Selection,
  candidate: record.Candidate,
  reply: Subject(Result(protocol.TransitionAnswer, Refusal)),
) -> actor.Next(State, Message) {
  use <- when_open(state, fn() { process.send(reply, Error(retired())) })
  case state.serving, state.staging, state.preparing {
    Some(serving), None, None if serving.handle == handle ->
      case serving.built.upgrade {
        Some(upgrade) ->
          begin_prepare(state, handle, upgrade, selection, candidate, reply)
        None -> {
          process.send(
            reply,
            Error(protocol.Invalid(
              "the generation does not admit an in-place successor",
            )),
          )
          proceed(state)
        }
      }

    Some(serving), _, _ if serving.handle == handle -> {
      process.send(
        reply,
        Error(protocol.ExecutorFault(
          "a stage or a prepare is in flight; prepare again once it settles",
        )),
      )
      proceed(state)
    }

    Some(_), _, _ | None, _, _ -> {
      process.send(reply, Error(protocol.UnknownHandle))
      proceed(state)
    }
  }
}

/// Starts the task that prepares a successor from the serving generation.
fn begin_prepare(
  state: State,
  predecessor: Handle,
  upgrade: staged.Upgrade,
  selection: record.Selection,
  candidate: record.Candidate,
  reply: Subject(Result(protocol.TransitionAnswer, Refusal)),
) -> actor.Next(State, Message) {
  let state = abandon_held(state)
  let successor = protocol.Handle(boot: state.boot, ordinal: state.next)
  let work =
    weft.task(fn() {
      upgrade.prepare(selection, candidate)
      |> result.map(Readied)
      |> result.map_error(Stored)
    })
  let state =
    State(
      ..state,
      next: state.next + 1,
      preparing: Some(Preparing(predecessor:, successor:, reply:)),
    )
  proceed(launch(state, Prepare, work, None))
}

/// A prepare ended. The successor is held when the generation it was prepared
/// from still serves and the plane is open; otherwise it is aborted, which only
/// compensates the live callbacks, because a successor shares its predecessor's
/// host and plane and owns nothing of its own to retire.
fn prepared(state: State, answered: Result(Answer, Failure)) -> State {
  case state.preparing {
    None -> state
    Some(preparing) -> {
      let state = State(..state, preparing: None)
      case answered {
        Ok(Readied(ready)) -> accept_prepared(state, preparing, ready)
        Ok(Exited) -> {
          process.send(
            preparing.reply,
            Error(protocol.ExecutorFault(
              "the prepare ended without a successor",
            )),
          )
          settle(state)
        }
        Error(Stored(refusal)) -> {
          process.send(preparing.reply, Error(fault_of(refusal)))
          settle(forfeit(state, refusal, None))
        }
        Error(Fault(reason)) -> {
          process.send(preparing.reply, Error(protocol.ExecutorFault(reason)))
          settle(state)
        }
      }
    }
  }
}

/// Holds a prepared successor when it is still wanted, and aborts it otherwise.
fn accept_prepared(
  state: State,
  preparing: Preparing,
  ready: staged.PreparedStaged,
) -> State {
  let still_serving = case state.serving {
    Some(serving) -> serving.handle == preparing.predecessor
    None -> False
  }
  case state.phase, still_serving {
    Open, True -> {
      process.send(
        preparing.reply,
        Ok(
          protocol.TransitionPrepared(protocol.Prepared(
            successor: preparing.successor,
            tools: list.map(ready.successor.tools, tool.describe),
          )),
        ),
      )
      State(
        ..state,
        held: Some(Held(
          predecessor: preparing.predecessor,
          successor: preparing.successor,
          prepared: ready,
          step: Unpublished,
        )),
      )
    }

    Open, False -> {
      discard_prepared(state, ready)
      process.send(preparing.reply, Error(protocol.UnknownHandle))
      state
    }

    Closing(_), _ | Closed, _ -> {
      discard_prepared(state, ready)
      process.send(preparing.reply, Error(retired()))
      settle(state)
    }
  }
}

/// Aborts a successor that will not be published, which only compensates the
/// live callbacks and logs a failure.
fn discard_prepared(state: State, ready: staged.PreparedStaged) -> Nil {
  case ready.abort() {
    Ok(Nil) -> Nil
    Error(refusal) ->
      log.warn(state.logger, "executor.evolution_abort_failed", [
        field.text(key: "reason", value: store.describe(refusal)),
      ])
  }
}

/// Aborts a successor that was never published, and forgets it. A published
/// one is kept, because a repeated publish still has to be answered.
fn abandon_held(state: State) -> State {
  case state.held {
    Some(Held(step: Unpublished, prepared: ready, ..)) -> {
      discard_prepared(state, ready)
      State(..state, held: None)
    }
    Some(Held(step: Published, ..)) | None -> state
  }
}

/// Makes the held successor the serving generation. The migration is applied
/// once: a second publish of the same pair answers again and does nothing.
fn publish(
  state: State,
  handle: Handle,
  successor: Handle,
  reply: Subject(Result(protocol.TransitionAnswer, Refusal)),
) -> actor.Next(State, Message) {
  use <- when_open(state, fn() { process.send(reply, Error(retired())) })
  case state.held {
    Some(held) if held.predecessor == handle && held.successor == successor ->
      case held.step {
        Published -> {
          process.send(reply, Ok(protocol.TransitionPublished))
          proceed(state)
        }
        Unpublished -> proceed(publish_held(state, held, reply))
      }

    // Aborted, replaced, or lost with a restart: the migration ended.
    Some(_) | None -> {
      process.send(reply, Error(protocol.UnknownHandle))
      proceed(state)
    }
  }
}

/// Runs the publish in the actor's own turn. The generation's satellite pauses
/// its callbacks for the migration, so requests that wait behind it would wait
/// on the satellite anyway.
fn publish_held(
  state: State,
  held: Held,
  reply: Subject(Result(protocol.TransitionAnswer, Refusal)),
) -> State {
  case state.serving {
    Some(serving) if serving.handle == held.predecessor ->
      case held.prepared.publish() {
        Ok(Nil) -> {
          process.send(reply, Ok(protocol.TransitionPublished))
          migrate(state, serving, held)
        }
        Error(refusal) -> {
          process.send(reply, Error(fault_of(refusal)))
          state
        }
      }

    // The generation was retired while its successor waited.
    Some(_) | None -> {
      process.send(reply, Error(protocol.UnknownHandle))
      abandon_held(state)
    }
  }
}

/// The successor serves and inherits the owner. The predecessor stays until it
/// is retired, with a retire that does nothing: it shares its successor's host
/// and plane, so stopping those is the successor's retire alone.
fn migrate(state: State, predecessor: Generation, held: Held) -> State {
  let successor =
    Generation(
      handle: held.successor,
      lineage: predecessor.lineage,
      built: held.prepared.successor,
      owner: predecessor.owner,
    )
  let alias =
    Generation(
      handle: predecessor.handle,
      lineage: predecessor.lineage,
      built: staged.Staged(..predecessor.built, retire: retirement.done()),
      owner: None,
    )
  State(
    ..state,
    serving: Some(successor),
    retiring: [alias, ..state.retiring],
    held: Some(Held(..held, step: Published)),
  )
}

/// Discards a successor that was not published. An abort of a transition the
/// plane does not hold has nothing to compensate; an abort after a publish is
/// refused, because the successor already serves.
fn abort(
  state: State,
  handle: Handle,
  successor: Handle,
  reply: Subject(Result(protocol.TransitionAnswer, Refusal)),
) -> actor.Next(State, Message) {
  use <- when_open(state, fn() { process.send(reply, Error(retired())) })
  case state.held {
    Some(held) if held.predecessor == handle && held.successor == successor ->
      case held.step {
        Published -> {
          process.send(reply, Error(protocol.AlreadyPublished))
          proceed(state)
        }
        Unpublished ->
          case held.prepared.abort() {
            Ok(Nil) -> {
              process.send(reply, Ok(protocol.TransitionAborted))
              proceed(State(..state, held: None))
            }
            Error(refusal) -> {
              process.send(reply, Error(fault_of(refusal)))
              proceed(state)
            }
          }
      }

    Some(_) | None -> {
      process.send(reply, Ok(protocol.TransitionAborted))
      proceed(state)
    }
  }
}

// --- retire ----------------------------------------------------------------------------------

/// Stops and removes one generation. A handle the plane does not hold has
/// nothing left to stop, so a retry after a lost reply is safe. A retirement the
/// generation's task could not confirm leaves the generation in place with the
/// task's own continuation, so a second retire finishes it. A retire is served
/// in every phase: after the close there is simply nothing to find.
fn retire(
  state: State,
  handle: Handle,
  reply: Subject(Result(protocol.CloseOutcome, Refusal)),
) -> actor.Next(State, Message) {
  let state = demote(state, handle)
  case list.partition(state.retiring, fn(each) { each.handle == handle }) {
    #([generation, ..], rest) ->
      case retire_one(generation) {
        Ok(Nil) -> {
          process.send(reply, Ok(protocol.AllRetired))
          proceed(State(..state, retiring: rest))
        }
        Error(#(kept, _reason)) -> {
          process.send(reply, Ok(protocol.UnknownCleanup(count: 1)))
          proceed(State(..state, retiring: [kept, ..rest]))
        }
      }

    #([], _) -> {
      process.send(reply, Ok(protocol.AllRetired))
      proceed(drop_successor(state, handle))
    }
  }
}

/// A serving generation that is retired stops serving first, and the successor
/// prepared from it goes with it.
fn demote(state: State, handle: Handle) -> State {
  case state.serving {
    Some(serving) if serving.handle == handle ->
      abandon_held(
        State(..state, serving: None, retiring: [serving, ..state.retiring]),
      )
    Some(_) | None -> state
  }
}

/// A retire that names an unpublished successor discards it. The successor owns
/// no resource of its own, so there is nothing else to stop.
fn drop_successor(state: State, handle: Handle) -> State {
  case state.held {
    Some(held) if held.successor == handle -> abandon_held(state)
    Some(_) | None -> state
  }
}

/// Performs a generation's retire. A confirmed one releases the owner, whose
/// exit is the end of the generation; a refused one answers the generation again
/// with the retry that remains.
fn retire_one(generation: Generation) -> Result(Nil, #(Generation, String)) {
  case retirement.perform(generation.built.retire) {
    Ok(Nil) -> {
      release_owner(generation.owner)
      Ok(Nil)
    }
    Error(failure) ->
      Error(#(
        Generation(
          ..generation,
          built: staged.Staged(..generation.built, retire: failure.retry),
        ),
        failure.reason,
      ))
  }
}

// --- hook, inventory and snapshot ------------------------------------------------------

/// Delivers one hook event, in a task of its own so that a slow satellite does
/// not hold the actor. The task answers on the request's subject; a task that
/// ends without answering is a crashed handler.
fn hook(
  state: State,
  handle: Handle,
  event: String,
  payload: MsgPackValue,
  within_ms: Int,
  reply: Subject(Result(MsgPackValue, hooks.HookFailure)),
) -> actor.Next(State, Message) {
  use <- when_open(state, fn() { process.send(reply, Error(hooks.Gone)) })
  case state.serving {
    Some(serving) if serving.handle == handle -> {
      let invoke = serving.built.invoke
      let work =
        weft.task(fn() {
          process.send(reply, invoke(event, payload, within_ms))
          Ok(Exited)
        })
      let fail = fn(reason) {
        process.send(reply, Error(hooks.Crashed(reason)))
      }
      proceed(launch(state, Quick(fail:), work, Some(within_ms + hook_slack_ms)))
    }

    // A generation that no longer serves has no extension left to answer.
    Some(_) | None -> {
      process.send(reply, Error(hooks.Gone))
      proceed(state)
    }
  }
}

/// The generation's helper census, from the serving generation or one that
/// stopped serving and has not been retired.
fn inventory(
  state: State,
  handle: Handle,
  reply: Subject(Result(JsonValue, Refusal)),
) -> actor.Next(State, Message) {
  use <- when_open(state, fn() { process.send(reply, Error(retired())) })
  let held = case state.serving {
    Some(serving) -> [serving, ..state.retiring]
    None -> state.retiring
  }
  case list.find(held, fn(generation) { generation.handle == handle }) {
    Ok(generation) -> {
      let census = generation.built.inventory
      let work =
        weft.task(fn() {
          process.send(
            reply,
            census() |> result.map_error(protocol.ExecutorFault),
          )
          Ok(Exited)
        })
      let fail = fn(reason) {
        process.send(reply, Error(protocol.ExecutorFault(reason)))
      }
      proceed(launch(state, Quick(fail:), work, None))
    }

    Error(Nil) -> {
      process.send(reply, Error(protocol.UnknownHandle))
      proceed(state)
    }
  }
}

/// Captures a candidate's source. The snapshot opens a plane of its own and
/// retires it before it answers, so it is a short task; a close waits for it.
fn snapshot(
  state: State,
  coordinates: protocol.Coordinates,
  directory: String,
  reply: Subject(Result(archive.Tree, Refusal)),
) -> actor.Next(State, Message) {
  use <- when_open(state, fn() { process.send(reply, Error(retired())) })
  let engine = state.engine
  let work =
    weft.task(fn() {
      process.send(
        reply,
        engine.snapshot(coordinates, directory) |> result.map_error(fault_of),
      )
      Ok(Exited)
    })
  let fail = fn(reason) {
    process.send(reply, Error(protocol.ExecutorFault(reason)))
  }
  proceed(launch(state, Capture(fail:), work, None))
}

// --- weft runs --------------------------------------------------------------------------------

/// Starts one weft run of one task and records it. The run's relay delivers into
/// a subject of its own, which the actor selects beside its inbox, so an
/// outcome can be told from another run's by its ticket. `within` bounds the run
/// when the task has a deadline of its own to respect; an owner has none, because
/// its life is the generation's.
fn launch(
  state: State,
  purpose: Purpose,
  task: weft.PreparedTask(Answer, Failure),
  within: Option(Int),
) -> State {
  let results = process.new_subject()
  let run = weft.new_prepared([task]) |> weft.limit(1)
  let bounded = case within {
    Some(ms) -> weft.deadline(run, ms)
    None -> run
  }
  let _relay = weft.start_relayed(bounded, to: results)
  State(..state, ticket: state.ticket + 1, runs: [
    Running(ticket: state.ticket, purpose:, results:),
    ..state.runs
  ])
}

/// A run delivered something. An outcome is the task's end and is handled by
/// what the run was for. The closing message, `AllDelivered` or `RunLost`, only
/// ends the run's record; a run lost before it delivered an outcome ended
/// without its answer.
fn delivered(
  state: State,
  ticket: Int,
  event: weft.Pulled(Answer, Failure),
) -> actor.Next(State, Message) {
  case list.find(state.runs, fn(running) { running.ticket == ticket }) {
    Error(Nil) -> proceed(state)
    Ok(running) ->
      case event {
        weft.PulledOutcome(outcome) ->
          proceed(ended(state, running, answer_of(outcome)))
        weft.AllDelivered -> proceed(forget(state, ticket))
        weft.RunLost(..) ->
          proceed(forget(
            ended(state, running, Error(Fault("the run's witness was lost"))),
            ticket,
          ))
        weft.NotYet -> proceed(state)
      }
  }
}

/// Every weft outcome, as a result. A task that did not return was cancelled,
/// crashed or lost its drain witness, and the answer says which.
fn answer_of(
  outcome: weft.Outcome(Answer, Failure),
) -> Result(Answer, Failure) {
  case outcome {
    weft.Completed(_, answer) -> Ok(answer)
    weft.Failed(_, failure) -> Error(failure)
    weft.Crashed(..) -> Error(Fault("the task crashed"))
    weft.Abandoned(..) | weft.NeverStarted(..) ->
      Error(Fault("the task was cancelled"))
    weft.DrainProofLost(..) | weft.CancellationUnconfirmed(..) ->
      Error(Fault("the task's drain proof was lost"))
  }
}

/// Drops the record of a run whose relay has said its last.
fn forget(state: State, ticket: Int) -> State {
  State(
    ..state,
    runs: list.filter(state.runs, fn(running) { running.ticket != ticket }),
  )
}

/// The task's end, by what the run was for. The run is marked spent first, so
/// the closing message that follows an outcome cannot end it twice.
fn ended(
  state: State,
  running: Running,
  answered: Result(Answer, Failure),
) -> State {
  let state =
    State(
      ..state,
      runs: list.map(state.runs, fn(each) {
        case each.ticket == running.ticket {
          True -> Running(..each, purpose: Spent)
          False -> each
        }
      }),
    )
  case running.purpose {
    Owner(lineage:) -> owner_ended(state, lineage, answered)
    Prepare -> prepared(state, answered)
    Capture(fail:) -> settle(answer_quick(state, fail, answered))
    Quick(fail:) -> answer_quick(state, fail, answered)
    Spent -> state
  }
}

/// A snapshot, hook or inventory task answered on its own subject. Only a task
/// that ended without doing so has anything left to say.
fn answer_quick(
  state: State,
  fail: fn(String) -> Nil,
  answered: Result(Answer, Failure),
) -> State {
  case answered {
    Ok(Exited) | Ok(Readied(_)) -> state
    Error(Stored(refusal)) -> {
      fail(store.describe(refusal))
      state
    }
    Error(Fault(reason)) -> {
      fail(reason)
      state
    }
  }
}

/// An owner's task ended. After a release that is the end of the generation. An
/// owner that ended before it was released died, and what it owned died with it
/// through its links: the generation is dropped and the stage, if any, is
/// answered, because nothing it built can serve.
fn owner_ended(
  state: State,
  lineage: Handle,
  answered: Result(Answer, Failure),
) -> State {
  case answered {
    Ok(Exited) | Ok(Readied(_)) -> state
    Error(Stored(_)) | Error(Fault(_)) -> {
      log.warn(state.logger, "executor.evolution_owner_lost", [
        field.count(key: "ordinal", value: lineage.ordinal),
      ])
      lose(state, lineage)
    }
  }
}

/// Forgets everything of a lineage whose owner is gone, answering a stage in
/// flight for it.
fn lose(state: State, lineage: Handle) -> State {
  let state = case state.staging {
    Some(staging) if staging.handle == lineage -> {
      reply_all(
        staging.waiters,
        Error(protocol.ExecutorFault("the stage ended without a generation")),
      )
      settle(State(..state, staging: None))
    }
    Some(_) | None -> state
  }

  // A successor held for a generation that is gone has nothing to take over.
  let #(serving, held) = case state.serving {
    Some(generation) if generation.lineage == lineage -> #(None, None)
    Some(_) | None -> #(state.serving, state.held)
  }
  State(
    ..state,
    serving:,
    held:,
    retiring: list.filter(state.retiring, fn(generation) {
      generation.lineage != lineage
    }),
  )
}

// --- closing ----------------------------------------------------------------------------------

/// The custody's retirement. The first call closes the plane to every request
/// and waits for the work in flight; a call that finds it closing waits with
/// the rest; a call after the close performs again what the last one could not.
fn retire_everything(
  state: State,
  reply: Subject(Result(Nil, String)),
) -> actor.Next(State, Message) {
  case state.phase {
    Open ->
      proceed(settle(
        State(..abandon_held(state), phase: Closing(waiters: [reply])),
      ))

    Closing(waiters) ->
      proceed(State(..state, phase: Closing(waiters: [reply, ..waiters])))

    Closed -> {
      let #(state, outcome) = sweep(state)
      process.send(reply, outcome)
      proceed(state)
    }
  }
}

/// Whether something is still in flight that could build a generation or open a
/// plane the sweep would miss.
fn busy(state: State) -> Bool {
  option.is_some(state.staging)
  || option.is_some(state.preparing)
  || list.any(state.runs, fn(running) {
    case running.purpose {
      Capture(_) -> True
      Owner(_) | Prepare | Quick(_) | Spent -> False
    }
  })
}

/// Finishes a close that was waiting for work in flight. Every handler that
/// ends such work calls it, and it acts only on a closing plane with nothing
/// left in flight.
fn settle(state: State) -> State {
  case state.phase, busy(state) {
    Closing(waiters), False -> {
      let #(swept, outcome) = sweep(state)
      reply_all(waiters, outcome)
      State(..swept, phase: Closed)
    }
    Closing(_), True | Open, _ | Closed, _ -> state
  }
}

/// Retires everything the actor holds: the serving generation, the ones that
/// stopped serving, and the retry witnesses of failed stages. A failure does not
/// skip the rest, since stopping is the safe direction whatever happened before.
/// What could not be confirmed stays, with its retry, for a second call.
fn sweep(state: State) -> #(State, Result(Nil, String)) {
  // The serving generation goes first, then the ones that stopped serving.
  let held = case state.serving {
    Some(serving) -> [serving, ..state.retiring]
    None -> state.retiring
  }
  let #(kept, generation_failures) =
    list.fold(held, #([], []), fn(account, generation) {
      case retire_one(generation) {
        Ok(Nil) -> account
        Error(#(left, reason)) -> #([left, ..account.0], [reason, ..account.1])
      }
    })

  // A failed stage's retry witness is performed whether or not a generation
  // refused, and the owner it kept alive is released only when it succeeds.
  let #(left, leftover_failures) =
    list.fold(state.leftovers, #([], []), fn(account, leftover) {
      case retirement.perform(leftover.retire) {
        Ok(Nil) -> {
          release_owner(leftover.owner)
          account
        }
        Error(failure) -> #(
          [Leftover(..leftover, retire: failure.retry), ..account.0],
          [failure.reason, ..account.1],
        )
      }
    })

  // The answer names the first failure, and what failed stays for a retry.
  let outcome = case list.append(generation_failures, leftover_failures) {
    [] -> Ok(Nil)
    [first, ..] -> Error(first)
  }
  #(State(..state, serving: None, retiring: kept, leftovers: left), outcome)
}
