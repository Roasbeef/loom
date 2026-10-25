//// The machine for a workspace on an executor: every operation of the
//// `machine.Machine` seam sent to the executor as one of protocol-change/098's
//// messages (protocol version 5).
////
//// A session registered on an executor keeps its conversation, its evolution
//// catalogue and its approvals on the orchestrator, and its workspace, its
//// compiler and its satellites on the executor. `machine/local` is the machine
//// for the case where both are one VM. This module is the same record for the
//// case where they are not, so the live owner, the hook fold and the doors
//// above the seam run unchanged and cannot tell which machine they hold.
////
//// The catalogue never crosses. Each operation that needs an approval reads it
//// here, with the catalogue the caller passes, and sends the executor plain
//// data: a candidate, a selection and the coordinates of the door call. The
//// executor builds, runs and answers; the orchestrator records the evidence,
//// raises the refusals, and decides when a generation may serve.
////
//// ## Messages and patience
////
//// | Operation | Message | Waits |
//// | --- | --- | --- |
//// | `snapshot` | `EvolutionSnapshot` | until the executor answers |
//// | `evaluate` | `EvolutionEvaluate` | until the executor answers |
//// | `stage` | `EvolutionStage` | until the executor answers |
//// | a promoted tool, `run_program` | `EvolutionRun` | until the executor answers |
//// | the hook bus | `EvolutionHook` | the hook's deadline plus a margin |
//// | an in-place upgrade | `EvolutionTransition` | until the executor answers |
//// | `inventory` | `EvolutionInventory` | a bounded time |
//// | `retire` | `EvolutionRetire` | a bounded time |
////
//// A message that waits until the executor answers is sent again after the
//// connection is repaired (`surface.ask`), so each of them is one the host
//// answers the same way twice: a read, a keyed call, or a step it treats as
//// idempotent. A retire is bounded, and a retire the executor does not answer
//// counts as done for custody, because the scope's close settles whatever the
//// executor still holds. Only `UnknownCleanup` is a retire that failed.
////
//// ## What a generation is here
////
//// `stage` answers a `live.Generation` whose fields are built over messages.
//// Each tool's `run` sends one `EvolutionRun` and nothing else but the read of
//// the call's stored authority, which the executor needs and only this side
//// holds. The hook bus is started here over an invoker that sends
//// `EvolutionHook`. `validate` reads this side's catalogue. `retire` closes the
//// bus and then retires the generation's handle.
////
//// A generation that admits an in-place successor (`protocol.InPlace`) gets a
//// `live.Stateful` mode whose `prepare`, `publish` and `abort` send the three
//// `TransitionStep`s. The successor serves under a handle of its own, so it
//// gets a bus of its own, started at prepare time; the predecessor's bus is
//// closed when the publish is confirmed. A successor's `retire` also retires
//// the handle it was prepared from and closes that bus, because the live owner
//// drops the predecessor without retiring it once the successor is published,
//// and a successor that was never published must still stop the predecessor's
//// resources.
////
//// ## Superseded generations
////
//// A stage names the generations it superseded. They are already stopped, and
//// each is a retire obligation. `stage` sends all the retires at once, since
//// they do not depend on one another, and returns before any failed one is
//// retried: a retire that could not be confirmed becomes a task folded into the
//// new generation's `retire`, so custody keeps the retry.
////
//// ## Flow
////
//// `new` → `stage` → `generation_of` → `over_bus` → `mode_of` → `prepare`
////
//// 1. `new` builds the `machine.Machine` over this module's functions and the
////    link to the executor.
//// 2. `stage` checks the catalogue's approval, sends `EvolutionStage`, and
////    retires what the stage superseded (`retire_superseded`).
//// 3. `generation_of` starts the hook bus (`start_bus`) and `over_bus` builds
////    the `live.Generation` over it.
//// 4. `mode_of` chooses replacement or an in-place upgrade, and `prepare` builds
////    the successor generation the same way.
//// 5. `evaluate`, `snapshot` and `run_program` are the checks that run beside a
////    generation.

import client/evolution/evaluate
import client/evolution/live
import client/evolution/machine.{type Machine}
import client/evolution/record
import client/evolution/retirement
import client/evolution/store
import client/executor_evolution
import client/extension/archive
import client/extension/hooks
import client/remote/protocol.{type Handle}
import client/remote/remote_census.{type RemoteCensus}
import client/remote/surface
import client/wiring.{type Authority}
import core/json.{type JsonValue}
import core/message
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/effects
import telemetry/log.{type Logger}
import tools/tool
import weft

/// Everything the machine needs to reach one session's evolution plane on its
/// executor.
///
/// The surface is the one the session attached with, so every message carries
/// the open's incarnation and token and a dead open's message is refused by the
/// host. The link holds no catalogue: each operation that needs one is given it,
/// as it is for the local machine.
pub type Link {
  Link(
    /// The orchestrator session, which keys the executor's scope.
    session: String,
    /// The configured name of the executor that holds the session, which names
    /// the workspace in the catalogue's scopes.
    executor: String,
    /// The attached surface the messages are sent through.
    surface: surface.Surface(RemoteCensus),
    /// The compile identity the executor reported in its census. The
    /// catalogue is opened under it.
    identity: record.Identity,
    /// Reads the session's stored authority: the directory additions and the
    /// standing grants. The executor revalidates it against its own
    /// filesystem, and it is the only carrier of grants, because a tool
    /// context holds only the grants of consumed approvals.
    authority: fn() -> Result(Authority, String),
    /// How long a retire or an inventory keeps repairing a broken connection
    /// before it gives up. A retire that is not answered in time counts as done,
    /// because the scope's close settles it. `default_patience_ms` is the
    /// production value; a test shortens it.
    patience_ms: Int,
    /// The logger the hook bus of a generation reports to.
    logger: Logger,
  )
}

/// The patience a production link has for a retire or an inventory.
pub const default_patience_ms = 60_000

/// What a hook's own deadline is extended by before the wait for the executor's
/// answer gives up, so the satellite's deadline fires first and the caller hears
/// `Deadline` rather than a lost link.
const hook_margin_ms = 20_000

/// The generation the live owner is told about, and what it was prepared from.
type Slot {
  Slot(
    /// The handle the executor knows the generation by.
    handle: Handle,
    /// The extension's manifest name; hook refusals are attributed to it.
    name: String,
    /// The hook events the manifest declared.
    events: List(String),
    /// The exact catalogue selection the generation implements.
    selection: record.Selection,
    /// The declared tools; their `run` is built from these.
    tools: List(tool.Described),
    /// Whether the generation admits an in-place successor.
    activation: protocol.Activation,
    /// The generation this one was prepared from, for an in-place successor.
    from: Option(Lineage),
  )
}

/// What an in-place successor keeps of the generation it replaces.
type Lineage {
  Lineage(
    /// The predecessor's handle, which the successor's retire retires as well.
    handle: Handle,
    /// The predecessor's hook bus, which the successor closes when it is
    /// published or retired.
    bus: hooks.Bus,
  )
}

/// Builds the machine for a workspace on the executor `link` reaches.
///
/// `identity` answers what the executor's census said; every other operation
/// sends a message. None of them reads the executor's state, so a machine can be
/// built before the catalogue is opened under the identity it reports.
///
/// ## Examples
///
/// ```gleam
/// // let machine = remote.new(link)
/// // machine.stage(catalogue, selection)
/// ```
///
pub fn new(link: Link) -> Machine {
  let identity = link.identity
  machine.Machine(
    identity: fn() { Ok(identity) },
    snapshot: fn(ctx, directory) { snapshot(link, ctx, directory) },
    evaluate: fn(catalogue, ctx, id) { evaluate(link, catalogue, ctx, id) },
    stage: fn(catalogue, selection) { stage(link, catalogue, selection) },
    run_program: fn(catalogue, selection, ctx, input) {
      run_program(link, catalogue, selection, ctx, input)
    },
  )
}

// --- sending ------------------------------------------------------------------

/// Sends one message and waits for its reply for as long as it takes.
///
/// The caller builds the message around the attach fence and the reply subject
/// this function supplies, so the incarnation and token are read in one place.
fn send(
  link: Link,
  make: fn(Int, BitArray, Subject(reply)) -> protocol.HostMessage(RemoteCensus),
) -> reply {
  let held = link.surface
  let incarnation = surface.incarnation(held)
  let token = surface.token(held)
  surface.ask(held, fn(reply) { make(incarnation, token, reply) })
}

/// Sends one message and waits for its reply, giving up once repairing the
/// connection has failed for `ms` milliseconds.
fn send_within(
  link: Link,
  ms: Int,
  make: fn(Int, BitArray, Subject(reply)) -> protocol.HostMessage(RemoteCensus),
) -> Result(reply, Nil) {
  let held = link.surface
  let incarnation = surface.incarnation(held)
  let token = surface.token(held)
  surface.ask_within(held, ms, fn(reply) { make(incarnation, token, reply) })
}

/// The coordinates of the door call `ctx` belongs to: its ledger key, its strand
/// and the session's stored authority.
fn coordinates(
  link: Link,
  ctx: tool.Ctx,
) -> Result(protocol.Coordinates, store.Refusal) {
  use authority <- result.map(
    link.authority() |> result.map_error(store.Unavailable),
  )
  protocol.coordinates_of(link.session, ctx, authority)
}

/// A refusal the executor gave, in the vocabulary of the catalogue's callers.
///
/// A stage for a generation the executor already passed is `Stale`, which the
/// model is told to answer by discovering the current candidate and generation.
/// Every other refusal has no equivalent in the store's vocabulary, so its
/// reason is kept whole as an unavailable dependency.
fn refused(refusal: protocol.Refusal) -> store.Refusal {
  case refusal {
    protocol.StaleGeneration(..) -> store.Stale

    protocol.StaleToken
    | protocol.StaleIncarnation(..)
    | protocol.ScopeNotOpen
    | protocol.ScopeClosing
    | protocol.UncleanClose(..)
    | protocol.CapacityExhausted(..)
    | protocol.BudgetExhausted(..)
    | protocol.VersionMismatch(..)
    | protocol.WorkspaceMismatch(..)
    | protocol.NoSuchScope
    | protocol.NoPlane(..)
    | protocol.PlaneBuilding
    | protocol.WorktreeFailed(..)
    | protocol.UnknownHandle
    | protocol.AlreadyPublished
    | protocol.NoEvolution(..)
    | protocol.Invalid(..)
    | protocol.ExecutorFault(..)
    | protocol.Unreachable(..) -> store.Unavailable(protocol.describe(refusal))
  }
}

// --- checks beside a generation -------------------------------------------------

/// Captures a candidate's source from `directory` of the executor's workspace.
///
/// The executor resolves the directory under its own workspace, so this side
/// checks nothing about it. A snapshot reads and changes nothing, so it is sent
/// again after a repair.
fn snapshot(
  link: Link,
  ctx: tool.Ctx,
  directory: String,
) -> Result(archive.Tree, store.Refusal) {
  use at <- result.try(coordinates(link, ctx))
  send(link, fn(incarnation, token, reply) {
    protocol.EvolutionSnapshot(
      incarnation:,
      token:,
      coordinates: at,
      directory:,
      reply:,
    )
  })
  |> result.map_error(refused)
}

/// Runs a candidate's author tests on the executor and answers the report.
///
/// The candidate is read here, with the catalogue, and a candidate admitted
/// under another identity is `Changed` before anything is sent. The executor
/// keeps nothing, so a lost answer is a report the check could not give: it is
/// recorded as inconclusive, with the text that says the check may have run.
fn evaluate(
  link: Link,
  catalogue: store.Store,
  ctx: tool.Ctx,
  id: record.CandidateId,
) -> Result(evaluate.Report, store.Refusal) {
  use candidate <- result.try(store.read_candidate(catalogue, id))
  use Nil <- result.try(evaluate.current(catalogue, candidate))
  use at <- result.try(coordinates(link, ctx))
  let answer =
    send(link, fn(incarnation, token, reply) {
      protocol.EvolutionEvaluate(
        incarnation:,
        token:,
        coordinates: at,
        candidate:,
        reply:,
      )
    })
  report_of(answer)
}

/// The report an `EvolutionEvaluate` answer holds, or the refusal it is.
fn report_of(
  answer: protocol.ExecutionAnswer,
) -> Result(evaluate.Report, store.Refusal) {
  case answer {
    protocol.ExecutionFinished(value:) ->
      case executor_evolution.decode_report(value) {
        Ok(Ok(report)) -> Ok(report)
        Ok(Error(reason)) -> Error(store.Unavailable(reason))

        // A value nothing on the executor's side wrote is a lost answer.
        Error(_unreadable) -> lost_report()
      }

    protocol.ExecutionLost -> lost_report()

    protocol.ExecutionRefused(refusal:) -> Error(refused(refusal))
  }
}

/// The report for a check whose answer is gone: inconclusive, because the check
/// may have passed or failed.
fn lost_report() -> Result(evaluate.Report, store.Refusal) {
  evaluate.report_of(Error(store.Unavailable(protocol.unknown_outcome_text)))
}

/// Runs the exact program the selection names, once, on the executor.
///
/// The selection is checked against the catalogue and must name a program, as
/// the local machine requires. The executor compiles the program for this call
/// and never stages it, so the whole candidate is sent.
fn run_program(
  link: Link,
  catalogue: store.Store,
  selection: record.Selection,
  ctx: tool.Ctx,
  input: JsonValue,
) -> Result(tool.ToolOutcome, store.Refusal) {
  use candidate <- result.try(store.authorized(catalogue, selection))

  // Only a program is compiled for each call; an extension is staged and a
  // prompt profile is never executable.
  use Nil <- result.try(case candidate.kind {
    record.Program -> Ok(Nil)
    record.Extension | record.Prompt -> Error(store.Authority("not a program"))
  })

  use at <- result.map(coordinates(link, ctx))
  run_target(link, at, protocol.Program(candidate:), input)
}

/// Sends one `EvolutionRun` and reads its answer as the outcome a tool returns.
///
/// This is the only message a promoted tool's call sends. The call is keyed by
/// its coordinates, so a send repeated after a repair joins the call in
/// progress or reads its stored outcome and nothing runs twice.
fn run_target(
  link: Link,
  at: protocol.Coordinates,
  target: protocol.Target,
  args: JsonValue,
) -> tool.ToolOutcome {
  send(link, fn(incarnation, token, reply) {
    protocol.EvolutionRun(
      incarnation:,
      token:,
      coordinates: at,
      target:,
      args:,
      reply:,
    )
  })
  |> outcome_of
}

/// The tool outcome an `EvolutionRun` answer is.
///
/// A lost outcome says plainly that the call may have run, because the model's
/// next move depends on it. A result message that is not a tool result is a
/// peer answering with another shape, and is a failure rather than a guess.
fn outcome_of(answer: protocol.RunAnswer) -> tool.ToolOutcome {
  case answer {
    protocol.RunFinished(outcome: effects.ToolCompleted(
      result:,
      terminate: True,
    )) -> read_result(result, tool.TerminateRun)

    protocol.RunFinished(outcome: effects.ToolCompleted(
      result:,
      terminate: False,
    )) -> read_result(result, tool.ContinueRun)

    protocol.RunFinished(outcome: effects.ToolFailed(reason:)) ->
      tool.failure(reason)

    protocol.RunLost -> tool.failure(protocol.unknown_outcome_text)

    protocol.RunRefused(refusal:) -> tool.failure(protocol.describe(refusal))
  }
}

/// The outcome a finished result message holds.
fn read_result(
  result: message.AgentMessage,
  terminate: tool.Terminate,
) -> tool.ToolOutcome {
  tool.from_result_message(result, terminate)
  |> result.lazy_unwrap(fn() {
    tool.failure(
      "the executor answered with a result that is not a tool result",
    )
  })
}

// --- staging --------------------------------------------------------------------

/// Builds and starts an approved selection on the executor.
///
/// The approval is read here, before anything is sent. When the executor
/// answers, every generation the stage superseded is retired before this
/// returns (`retire_superseded`), and the retires that did not confirm ride on
/// the new generation's own `retire`.
fn stage(
  link: Link,
  catalogue: store.Store,
  selection: record.Selection,
) -> Result(live.Generation, store.Refusal) {
  use candidate <- result.try(store.approved(catalogue, selection))
  use staged <- result.try(
    send(link, fn(incarnation, token, reply) {
      protocol.EvolutionStage(
        session: link.session,
        incarnation:,
        token:,
        selection:,
        candidate:,
        reply:,
      )
    })
    |> result.map_error(refused),
  )
  let unconfirmed = retire_superseded(link, staged.superseded)
  let slot =
    Slot(
      handle: staged.handle,
      name: staged.name,
      events: staged.hooks,
      selection:,
      tools: staged.tools,
      activation: staged.activation,
      from: None,
    )
  generation_of(link, catalogue, slot, unconfirmed)
}

/// Starts the orchestrator's half of a staged generation.
///
/// A bus that cannot start retires the generation and what the stage superseded
/// before the refusal is surfaced, so the caller owes no cleanup either way.
fn generation_of(
  link: Link,
  catalogue: store.Store,
  slot: Slot,
  unconfirmed: List(retirement.Task),
) -> Result(live.Generation, store.Refusal) {
  let cleanup = retire_task(link, [], [slot.handle], unconfirmed)
  use bus <- result.try(start_bus(link, slot, cleanup))
  Ok(over_bus(link, catalogue, bus, slot, unconfirmed))
}

/// Starts the hook bus of one generation over an invoker that sends
/// `EvolutionHook` to the generation's handle.
///
/// When the bus cannot start, `cleanup` runs and the refusal says whether it
/// confirmed.
fn start_bus(
  link: Link,
  slot: Slot,
  cleanup: retirement.Task,
) -> Result(hooks.Bus, store.Refusal) {
  let handle = slot.handle
  let subscribed =
    hooks.Extension(
      name: slot.name,
      events: slot.events,
      invoke: fn(_name, event, payload, within) {
        hook(link, hook_margin_ms, handle, event, payload, within)
      },
    )

  // A bus that does not start has served nothing, but the generation behind it
  // is running on the executor, so its cleanup decides what the caller hears.
  case hooks.start([subscribed], link.logger) {
    Ok(bus) -> Ok(bus)
    Error(error) -> failed(cleanup, store.Unavailable(string.inspect(error)))
  }
}

/// Delivers one hook event to the generation named by `handle`.
///
/// The hook's own deadline is sent unchanged, since it is a remaining duration
/// and not a time, and the wait outlasts it by `margin_ms`. A host that cannot be
/// reached skips this one event with `Refused`, because the extension may be
/// running and the link may come back; `Gone` drops the handler for the rest of
/// the session, so it is kept for the host's own terminal refusals.
@internal
pub fn hook(
  link: Link,
  margin_ms: Int,
  handle: Handle,
  event: String,
  payload: MsgPackValue,
  within: Int,
) -> Result(MsgPackValue, hooks.HookFailure) {
  let answered =
    send_within(link, within + margin_ms, fn(incarnation, token, reply) {
      protocol.EvolutionHook(
        session: link.session,
        incarnation:,
        token:,
        handle:,
        event:,
        payload:,
        within_ms: within,
        reply:,
      )
    })

  // Not hearing from the executor in time is not a crash of the extension.
  case answered {
    Ok(answer) -> answer
    Error(Nil) -> Error(hooks.Refused("the executor could not be reached"))
  }
}

/// The generation for a staged slot over a bus that is already running.
fn over_bus(
  link: Link,
  catalogue: store.Store,
  bus: hooks.Bus,
  slot: Slot,
  unconfirmed: List(retirement.Task),
) -> live.Generation {
  let selection = slot.selection
  let handle = slot.handle
  live.Generation(
    selection:,
    mode: mode_of(link, catalogue, bus, slot),
    inventory: fn() { inventory(link, handle) },
    tools: list.map(slot.tools, fn(declared) {
      tool.from_described(declared, run: fn(ctx, args) {
        run_promoted(link, handle, declared.name, ctx, args)
      })
    }),
    hooks: Some(bus),
    validate: fn() {
      store.authorized(catalogue, selection) |> result.replace(Nil)
    },
    retire: retirement_of(link, bus, slot, unconfirmed),
  )
}

/// Runs one tool of a staged generation.
///
/// The call reads the stored authority and sends one `EvolutionRun`; nothing
/// else crosses the link.
fn run_promoted(
  link: Link,
  handle: Handle,
  name: String,
  ctx: tool.Ctx,
  args: JsonValue,
) -> tool.ToolOutcome {
  case coordinates(link, ctx) {
    Ok(at) -> run_target(link, at, protocol.Promoted(handle:, tool: name), args)
    Error(refusal) -> tool.failure(store.describe(refusal))
  }
}

/// The helper census of the generation named by `handle`.
fn inventory(link: Link, handle: Handle) -> Result(JsonValue, String) {
  let answered =
    send_within(link, link.patience_ms, fn(incarnation, _token, reply) {
      protocol.EvolutionInventory(
        session: link.session,
        incarnation:,
        handle:,
        reply:,
      )
    })

  // An inventory is a read, so an executor that cannot be reached is a report
  // that none could be made.
  case answered {
    Ok(Ok(census)) -> Ok(census)
    Ok(Error(refusal)) -> Error(protocol.describe(refusal))
    Error(Nil) -> Error("the executor could not be reached")
  }
}

// --- in-place upgrade -----------------------------------------------------------

/// Replacement only, unless the executor said the generation admits an in-place
/// successor.
fn mode_of(
  link: Link,
  catalogue: store.Store,
  bus: hooks.Bus,
  slot: Slot,
) -> live.Mode {
  case slot.activation {
    protocol.Replacement -> live.ReplacementOnly

    protocol.InPlace ->
      live.Stateful(prepare: fn(selection) {
        prepare(link, catalogue, bus, slot, selection)
      })
  }
}

/// Builds the successor of `slot` beside it, for a selection the catalogue has
/// approved.
///
/// The successor's approval is read before the executor is asked to compile
/// anything. A prepare that succeeded and whose bus cannot start is aborted
/// before the refusal is surfaced.
fn prepare(
  link: Link,
  catalogue: store.Store,
  bus: hooks.Bus,
  slot: Slot,
  selection: record.Selection,
) -> Result(live.PreparedUpgrade, store.Refusal) {
  let from = slot.handle
  use candidate <- result.try(store.approved(catalogue, selection))
  use prepared <- result.try(
    transition(link, protocol.Prepare(from, selection, candidate))
    |> result.map_error(refused)
    |> result.try(prepared_of),
  )
  let successor =
    Slot(
      ..slot,
      handle: prepared.successor,
      selection:,
      tools: prepared.tools,
      from: Some(Lineage(handle: from, bus:)),
    )
  upgrade_of(link, catalogue, bus, from, successor)
}

/// The prepared upgrade for a successor the executor has built and holds
/// unpublished.
///
/// The successor gets a bus of its own, since hooks reach the generation that
/// serves by its handle. If the bus cannot start, the transition is aborted
/// before the refusal is surfaced, so the executor is not left holding a
/// successor nobody will publish. `publish` closes the predecessor's bus and
/// `abort` closes the successor's, so whichever way the upgrade ends exactly one
/// bus remains.
fn upgrade_of(
  link: Link,
  catalogue: store.Store,
  bus: hooks.Bus,
  from: Handle,
  successor: Slot,
) -> Result(live.PreparedUpgrade, store.Refusal) {
  let held = successor.handle
  let cleanup =
    retirement.repeat(fn() {
      abort_step(link, from, held) |> result.map_error(store.describe)
    })
  use next <- result.map(start_bus(link, successor, cleanup))
  live.PreparedUpgrade(
    generation: over_bus(link, catalogue, next, successor, []),
    publish: fn() { publish(link, from, held, bus) },
    abort: fn() {
      use Nil <- result.map(abort_step(link, from, held))
      hooks.close(next)
    },
  )
}

/// The prepared successor an answer holds, or the refusal a different answer is.
fn prepared_of(
  answer: protocol.TransitionAnswer,
) -> Result(protocol.Prepared, store.Refusal) {
  case answer {
    protocol.TransitionPrepared(prepared:) -> Ok(prepared)

    protocol.TransitionPublished | protocol.TransitionAborted ->
      Error(store.Unavailable(
        "the executor answered a prepare with another step of the upgrade",
      ))
  }
}

/// Makes the successor the serving generation, and closes the bus of the
/// generation it replaced once the executor confirms.
///
/// A successor the executor no longer holds ended the migration: it was
/// aborted, replaced, or lost with an executor restart. That is a refusal the
/// live owner retains, and the next open stages the selection afresh.
fn publish(
  link: Link,
  from: Handle,
  successor: Handle,
  older: hooks.Bus,
) -> Result(Nil, store.Refusal) {
  // The predecessor's bus is closed only once the executor says the successor
  // serves, since until then the predecessor's hooks still reach a live
  // extension.
  case transition(link, protocol.Publish(from, successor)) {
    Ok(protocol.TransitionPublished) -> {
      hooks.close(older)
      Ok(Nil)
    }

    Ok(protocol.TransitionPrepared(..)) | Ok(protocol.TransitionAborted) ->
      Error(store.Unavailable(
        "the executor answered a publish with another step of the upgrade",
      ))

    Error(protocol.UnknownHandle) ->
      Error(store.Unavailable(
        "migration lost: the executor no longer holds the prepared successor",
      ))

    Error(refusal) -> Error(refused(refusal))
  }
}

/// Discards an unpublished successor.
///
/// An abort of a transition the executor does not hold does nothing, so a retry
/// after a lost reply is safe. An abort after the publish is refused, because the
/// successor already serves.
fn abort_step(
  link: Link,
  from: Handle,
  successor: Handle,
) -> Result(Nil, store.Refusal) {
  case transition(link, protocol.Abort(from, successor)) {
    Ok(protocol.TransitionAborted) -> Ok(Nil)

    Ok(protocol.TransitionPrepared(..)) | Ok(protocol.TransitionPublished) ->
      Error(store.Unavailable(
        "the executor answered an abort with another step of the upgrade",
      ))

    Error(refusal) -> Error(refused(refusal))
  }
}

/// Sends one step of an upgrade and waits for the executor's answer.
fn transition(
  link: Link,
  step: protocol.TransitionStep,
) -> Result(protocol.TransitionAnswer, protocol.Refusal) {
  send(link, fn(incarnation, token, reply) {
    protocol.EvolutionTransition(
      session: link.session,
      incarnation:,
      token:,
      step:,
      reply:,
    )
  })
}

// --- retirement -----------------------------------------------------------------

/// What retiring a generation takes: its bus, then its handle, and the handle
/// and bus of the generation it was prepared from.
fn retirement_of(
  link: Link,
  bus: hooks.Bus,
  slot: Slot,
  unconfirmed: List(retirement.Task),
) -> retirement.Task {
  let handle = slot.handle

  // An in-place successor also owns what its predecessor started, since the
  // live owner never retires the predecessor once the successor is published.
  let #(buses, handles) = case slot.from {
    None -> #([bus], [handle])
    Some(Lineage(handle: older_handle, bus: older)) -> #([bus, older], [
      handle,
      older_handle,
    ])
  }

  retire_task(link, buses, handles, unconfirmed)
}

/// Closes the buses, then retires each handle and runs the retries of earlier
/// obligations, attempting all of them and keeping only what failed.
fn retire_task(
  link: Link,
  buses: List(hooks.Bus),
  handles: List(Handle),
  unconfirmed: List(retirement.Task),
) -> retirement.Task {
  retirement.sequence(
    retirement.repeat(fn() {
      list.each(buses, hooks.close)
      Ok(Nil)
    }),
    retirement.join(list.append(
      list.map(handles, fn(handle) { retire_again(link, handle) }),
      unconfirmed,
    )),
  )
}

/// A task that retires `handle` and can be run again after a failure.
fn retire_again(link: Link, handle: Handle) -> retirement.Task {
  retirement.repeat(fn() { retire_remote(link, handle) })
}

/// Retires every superseded generation at once and answers a task for each one
/// that did not confirm.
///
/// The retires do not depend on one another, so they are sent together and the
/// stage waits for the slowest instead of the sum.
fn retire_superseded(
  link: Link,
  handles: List(Handle),
) -> List(retirement.Task) {
  // Nothing superseded means nothing to ask the executor.
  case handles {
    [] -> []

    _ -> {
      let confirmed =
        weft.map(handles, limit: list.length(handles), with: fn(handle) {
          retire_remote(link, handle) |> result.replace(handle)
        })
        |> weft.values

      // A retire that crashed or failed is not in `confirmed`, and is retried.
      list.filter(handles, fn(handle) { !list.contains(confirmed, handle) })
      |> list.map(retire_again(link, _))
    }
  }
}

/// Asks the executor to retire one generation.
///
/// `AllRetired` and an executor that cannot be reached are both `Ok`, since the
/// scope's close settles what the executor still holds and a partition at
/// session close must not leave the evolution custody held. `UnknownCleanup` and
/// a refusal are failures, and keep the retry.
fn retire_remote(link: Link, handle: Handle) -> Result(Nil, String) {
  let answered =
    send_within(link, link.patience_ms, fn(incarnation, token, reply) {
      protocol.EvolutionRetire(
        session: link.session,
        incarnation:,
        token:,
        handle:,
        reply:,
      )
    })

  // Only an answer can say that a generation's resources are not gone.
  case answered {
    Ok(Ok(protocol.AllRetired)) -> Ok(Nil)

    Ok(Ok(protocol.UnknownCleanup(count:))) ->
      Error(
        "the executor could not prove "
        <> int.to_string(count)
        <> " children of the generation are gone",
      )

    Ok(Error(refusal)) -> Error(protocol.describe(refusal))

    Error(Nil) -> Ok(Nil)
  }
}

/// Performs a cleanup and surfaces `reason` once it is confirmed, or the
/// unconfirmed cleanup with its retry when it is not.
fn failed(
  cleanup: retirement.Task,
  reason: store.Refusal,
) -> Result(a, store.Refusal) {
  case retirement.perform(cleanup) {
    Ok(Nil) -> Error(reason)

    Error(unconfirmed) ->
      Error(store.CleanupUnconfirmed(unconfirmed.reason, unconfirmed.retry))
  }
}
