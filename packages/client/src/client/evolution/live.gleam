//// A session's serialized custody of promoted executable generations.
////
//// The mailbox is the activation boundary: one complete invocation or hook
//// fold finishes before replacement begins. Each generation keeps callable
//// schema, implementation, policy and hook bus in one immutable value.
//// Native retirement must succeed before a central selection is committed.
//// A failed witness retains custody and forbids additional staging.

import broker/internal/call
import client/evolution/record
import client/evolution/retirement
import client/evolution/store
import client/extension/archive
import client/extension/hooks
import core/clock.{type Clock}
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import runtime/effects
import tools/tool.{type Ctx, type Tool, type ToolOutcome}
import weft/actor

/// One complete prepared version and its native cleanup witness.
pub type Generation {
  Generation(
    /// The exact catalogue selection this version will implement.
    selection: record.Selection,
    /// The immutable callable declarations and implementations.
    tools: List(Tool),
    /// The promoted hooks, separate from installed native hooks.
    hooks: Option(hooks.Bus),
    /// Stops hosts and proves orderly dedicated executor/pool retirement.
    retire: retirement.Task,
    /// Revalidates current approval, revocation, selection and compatibility.
    validate: fn() -> Result(Nil, store.Refusal),
    /// Bounded native helper census for the dedicated generation plane.
    inventory: fn() -> Result(JsonValue, String),
  )
}

/// Only the native assembly can provide staging and adoption capabilities.
pub type Config {
  Config(
    /// Session clock used for queued request expiry.
    clock: Clock,
    /// Builds and starts one approved immutable candidate's isolated plane.
    stage: fn(record.Selection) -> Result(Generation, store.Refusal),
    /// Records the idempotent session adoption audit before publication.
    adopt: fn(record.Selection) -> Result(Nil, store.Refusal),
    /// Rebuilds the central committed selection after a crash or stale CAS.
    recover: fn() -> Result(Option(Generation), store.Refusal),
  )
}

/// A finite transition request; expiry survives mailbox queueing.
pub type Transition {
  Transition(
    /// Caller identity for resolving a lost acknowledgement.
    request_id: String,
    /// Absolute clock deadline after which publication is forbidden.
    expires_at: Int,
    /// Exact approved candidate and expected next generation.
    selection: record.Selection,
    /// Performs the catalogue approval/revocation/selection CAS.
    commit: fn() -> Result(record.Selection, store.Refusal),
  )
}

/// The generation actor's sealed message vocabulary.
pub opaque type Message {
  Activate(Transition, Subject(Result(record.Selection, store.Refusal)))
  Invoke(String, Int, String, Ctx, JsonValue, Int, Subject(ToolOutcome))
  Execute(
    String,
    Ctx,
    JsonValue,
    fn() -> Result(ToolOutcome, store.Refusal),
    Int,
    Subject(ToolOutcome),
  )
  Fold(fn(Option(Generation)) -> JsonValue, Int, Subject(JsonValue))
  Catalogue(Subject(Result(Option(Generation), store.Refusal)))
  Snapshot(
    fn() -> Result(archive.Tree, store.Refusal),
    Subject(Result(archive.Tree, store.Refusal)),
  )
  Evaluate(
    fn() -> Result(record.Evidence, store.Refusal),
    Subject(Result(record.Evidence, store.Refusal)),
  )
  Run(
    fn(Option(Generation)) -> effects.ToolOutcome,
    Int,
    Subject(effects.ToolOutcome),
  )
  Notice(fn(Option(Generation)) -> Nil)
  Retain(retirement.Task, Subject(Nil))
  Recover(Subject(Result(Nil, store.Refusal)))
  Close(Subject(Result(Nil, store.Refusal)))
}

/// An opaque subject; callers cannot bypass version or expiry checks.
pub opaque type Live {
  Live(subject: Subject(Message), clock: Clock)
}

type State {
  State(
    config: Config,
    active: Option(Generation),
    held: List(Generation),
    pending: List(retirement.Task),
  )
}

/// Starts with no executable generation and no helper allocation.
///
/// ## Examples
///
/// ```gleam
/// // live.start(config)
/// ```
///
pub fn start(config: Config) -> Result(Live, actor.StartError) {
  use started <- result.map(
    actor.new(State(config:, active: None, held: [], pending: []))
    |> actor.on_message(handle)
    |> actor.start,
  )
  Live(subject: started.data, clock: config.clock)
}

/// Stages, retires the predecessor, commits selection, audits and publishes.
///
/// ## Examples
///
/// ```gleam
/// // live.activate(owner, transition, waiting: 60_000)
/// ```
///
pub fn activate(
  owner: Live,
  transition: Transition,
  waiting waiting: Int,
) -> Result(record.Selection, store.Refusal) {
  call.try_call(owner.subject, waiting:, sending: fn(reply) {
    Activate(transition, reply)
  })
  |> result.replace_error(store.Busy)
  |> result.flatten
}

/// Returns the currently published generation, refusing stranded custody.
///
/// ## Examples
///
/// ```gleam
/// // live.catalogue(owner)
/// ```
///
pub fn catalogue(owner: Live) -> Result(Option(Generation), store.Refusal) {
  call.try_call(owner.subject, waiting: 1000, sending: Catalogue)
  |> result.replace_error(store.Busy)
  |> result.flatten
}

/// Invokes precisely the advertised immutable candidate and generation.
///
/// ## Examples
///
/// ```gleam
/// // live.invoke(owner, id, generation, name, ctx, args, 60_000)
/// ```
///
pub fn invoke(
  owner: Live,
  id: String,
  generation: Int,
  name: String,
  ctx: Ctx,
  args: JsonValue,
  waiting: Int,
) -> ToolOutcome {
  let #(now, _) = clock.read(owner.clock)
  call.try_call(owner.subject, waiting:, sending: fn(reply) {
    Invoke(id, generation, name, ctx, args, now + waiting, reply)
  })
  |> result.unwrap(tool.failure("Busy: the generation owner did not answer"))
}

/// Executes an entire hook fold on the owner's serialized timeline.
///
/// The fold captures only its predecessor slot and inputs, never an Effects
/// sibling record. Expired folds yield the caller's supplied fallback.
///
/// ## Examples
///
/// ```gleam
/// // live.fold(owner, fn(generation) { ... }, fallback, 60_000)
/// ```
///
pub fn fold(
  owner: Live,
  work: fn(Option(Generation)) -> JsonValue,
  fallback: JsonValue,
  waiting: Int,
) -> JsonValue {
  let #(now, _) = clock.read(owner.clock)
  call.try_call(owner.subject, waiting:, sending: fn(reply) {
    Fold(work, now + waiting, reply)
  })
  |> result.unwrap(fallback)
}

/// Runs a complete before-tool, invocation and after-tool fold under one owner.
///
/// ## Examples
///
/// ```gleam
/// // live.run(owner, work, 60_000)
/// ```
///
pub fn run(
  owner: Live,
  work: fn(Option(Generation)) -> effects.ToolOutcome,
  waiting: Int,
) -> effects.ToolOutcome {
  let #(now, _) = clock.read(owner.clock)
  call.try_call(owner.subject, waiting:, sending: fn(reply) {
    Run(work, now + waiting, reply)
  })
  |> result.unwrap(effects.ToolFailed("Busy: generation owner did not answer"))
}

/// Proves cleanup, retaining every unconfirmed generation for a later retry.
///
/// ## Examples
///
/// ```gleam
/// // live.close(owner, 30_000)
/// ```
///
pub fn close(owner: Live, waiting: Int) -> Result(Nil, store.Refusal) {
  call.try_call(owner.subject, waiting:, sending: Close)
  |> result.replace_error(store.Busy)
  |> result.flatten
  |> result.map_error(fn(error) {
    // The actor owns its replacement tasks. A caller retries through that
    // owner, rather than independently performing a copy of its obligations.
    store.CleanupUnconfirmed(
      store.describe(error),
      retirement.repeat(fn() {
        close(owner, waiting) |> result.map_error(store.describe)
      }),
    )
  })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Activate(transition, reply) -> {
      let #(next, answer) = changing(state, transition)
      process.send(reply, answer)
      actor.continue(next)
    }
    Snapshot(work, reply) -> {
      let answer = case state.held, state.pending {
        [], [] -> work()
        _, _ -> Error(store.Busy)
      }
      let next = case answer {
        Error(error) -> retained_refusal(state, error)
        Ok(_) -> state
      }
      process.send(reply, answer)
      actor.continue(next)
    }
    Evaluate(work, reply) -> {
      let answer = case state.held, state.pending {
        [], [] -> work()
        _, _ -> Error(store.Busy)
      }
      let next = case answer {
        Error(error) -> retained_refusal(state, error)
        Ok(_) -> state
      }
      process.send(reply, answer)
      actor.continue(next)
    }
    Execute(name, ctx, args, work, expires, reply) -> {
      let #(next, validation) = validate_active(state)
      let performed = case
        expired(next.config.clock, expires),
        next.held,
        next.pending
      {
        True, _, _ -> Error(store.Busy)
        False, [], [] ->
          execute_with(
            case validation {
              Ok(_) -> next.active
              Error(_) -> None
            },
            name,
            ctx,
            args,
            work,
          )
        False, _, _ -> Error(store.Busy)
      }
      let #(next, answer) = case performed {
        Ok(answer) -> #(next, answer)
        Error(error) -> #(
          retained_refusal(next, error),
          tool.failure(store.describe(error)),
        )
      }
      process.send(reply, answer)
      actor.continue(next)
    }
    Invoke(id, generation, name, ctx, args, expires, reply) -> {
      let #(next, validation) = validate_active(state)
      let answer = case
        expired(state.config.clock, expires),
        next.held,
        next.pending,
        validation
      {
        _, _, _, Error(error) -> tool.failure(store.describe(error))
        True, _, _, Ok(_) ->
          tool.failure("Busy: invocation expired before admission")
        False, [], [], Ok(_) ->
          invoked(next.active, id, generation, name, ctx, args)
        False, _, _, Ok(_) ->
          tool.failure("CleanupUnconfirmed: generation custody is retained")
      }
      process.send(reply, answer)
      actor.continue(next)
    }
    Fold(work, expires, reply) -> {
      let #(next, validation) = validate_active(state)
      case
        expired(next.config.clock, expires),
        next.held,
        next.pending,
        validation
      {
        False, [], [], Ok(_) -> process.send(reply, work(next.active))
        False, [], [], Error(_) -> process.send(reply, work(None))
        _, _, _, _ -> Nil
      }
      actor.continue(next)
    }
    Catalogue(reply) -> {
      let answer = case state.held, state.pending {
        [], [] -> Ok(state.active)
        _, [_, ..] | [_, ..], [] ->
          Error(cleanup_refusal("generation custody remains", state.held))
      }
      process.send(reply, answer)
      actor.continue(state)
    }
    Run(work, expires, reply) -> {
      let #(next, validation) = validate_active(state)
      let answer = case
        expired(next.config.clock, expires),
        next.held,
        next.pending,
        validation
      {
        False, [], [], Ok(_) -> work(next.active)
        False, [], [], Error(_) -> work(None)
        True, _, _, _ -> effects.ToolFailed("Busy: queued fold expired")
        False, _, _, _ ->
          effects.ToolFailed("CleanupUnconfirmed: retained native custody")
      }
      process.send(reply, answer)
      actor.continue(next)
    }
    Notice(work) -> {
      let #(next, validation) = validate_active(state)
      case next.held, next.pending, validation {
        [], [], Ok(_) -> work(next.active)
        _, _, _ -> Nil
      }
      actor.continue(next)
    }
    Retain(retire, reply) -> {
      process.send(reply, Nil)
      actor.continue(State(..state, pending: [retire, ..state.pending]))
    }
    Recover(reply) -> {
      let #(next, answer) = recovered(state)
      process.send(reply, answer)
      actor.continue(next)
    }
    Close(reply) -> {
      let held = list.append(state.held, active_list(state.active))
      let unconfirmed =
        list.filter_map(held, fn(generation) {
          case retirement.perform(generation.retire) {
            Ok(Nil) -> Error(Nil)
            Error(failed) -> Ok(Generation(..generation, retire: failed.retry))
          }
        })
      let pending =
        list.filter_map(state.pending, fn(retire) {
          case retirement.perform(retire) {
            Ok(Nil) -> Error(Nil)
            Error(failed) -> Ok(failed.retry)
          }
        })
      let answer = case unconfirmed, pending {
        [], [] -> Ok(Nil)
        _, [_, ..] | [_, ..], [] ->
          Error(cleanup_refusal(
            "native retirement did not confirm",
            unconfirmed,
          ))
      }
      process.send(reply, answer)
      case answer {
        Ok(Nil) -> actor.stop()
        Error(_) ->
          actor.continue(
            State(..state, active: None, held: unconfirmed, pending:),
          )
      }
    }
  }
}

fn changing(
  state: State,
  transition: Transition,
) -> #(State, Result(record.Selection, store.Refusal)) {
  case
    list.is_empty(state.held) && list.is_empty(state.pending),
    expired(state.config.clock, transition.expires_at)
  {
    False, _ -> #(
      state,
      Error(cleanup_refusal("retained generation forbids staging", state.held)),
    )
    True, True -> #(state, Error(store.Busy))
    True, False ->
      case state.active {
        Some(previous) if previous.selection.name != transition.selection.name -> #(
          state,
          Error(store.Bounds("one executable evolution slot per session")),
        )
        Some(_) | None ->
          staged(state, transition, state.config.stage(transition.selection))
      }
  }
}

fn staged(
  state: State,
  transition: Transition,
  staged: Result(Generation, store.Refusal),
) -> #(State, Result(record.Selection, store.Refusal)) {
  case staged {
    Error(reason) -> #(retained_refusal(state, reason), Error(reason))
    Ok(candidate) -> {
      case expired(state.config.clock, transition.expires_at) {
        True -> discard(state, candidate, store.Busy)
        False -> retiring(state, transition, candidate)
      }
    }
  }
}

fn retiring(
  state: State,
  transition: Transition,
  candidate: Generation,
) -> #(State, Result(record.Selection, store.Refusal)) {
  let retired = case state.active {
    None -> Ok(Nil)
    Some(previous) -> retirement.perform(previous.retire)
  }
  case retired {
    Error(failed) -> {
      let held =
        list.map(active_list(state.active), fn(previous) {
          Generation(..previous, retire: failed.retry)
        })

      // The predecessor is already retained in `held`. Its refusal transports
      // the witness to the caller without adding a second native obligation.
      discard_owned(
        State(..state, active: None, held:),
        candidate,
        cleanup_refusal(failed.reason, held),
      )
    }
    Ok(Nil) ->
      committed(
        State(..state, active: None),
        transition,
        candidate,
        case expired(state.config.clock, transition.expires_at) {
          True -> Error(store.Busy)
          False -> transition.commit()
        },
      )
  }
}

fn committed(
  state: State,
  transition: Transition,
  candidate: Generation,
  committed: Result(record.Selection, store.Refusal),
) -> #(State, Result(record.Selection, store.Refusal)) {
  case committed {
    Error(reason) -> recover_previous(discard(state, candidate, reason))
    Ok(selection) ->
      published(
        state,
        transition,
        candidate,
        selection,
        state.config.adopt(selection),
      )
  }
}

fn published(
  state: State,
  _transition: Transition,
  candidate: Generation,
  selection: record.Selection,
  audited: Result(Nil, store.Refusal),
) -> #(State, Result(record.Selection, store.Refusal)) {
  // Successful central CAS ends deadline admission. The committed selection
  // must complete its adoption even if that durable audit crosses the deadline.
  case audited {
    Error(reason) -> discard(state, candidate, reason)
    Ok(Nil) -> #(
      State(..state, active: Some(Generation(..candidate, selection:))),
      Ok(selection),
    )
  }
}

fn discard(
  state: State,
  candidate: Generation,
  reason: store.Refusal,
) -> #(State, Result(record.Selection, store.Refusal)) {
  discard_owned(retained_refusal(state, reason), candidate, reason)
}

// Internal generation custody stays in `held`; only a foreign refusal belongs
// in `pending`. Removing the prepared successor must preserve that distinction.
fn discard_owned(
  state: State,
  candidate: Generation,
  reason: store.Refusal,
) -> #(State, Result(record.Selection, store.Refusal)) {
  case retirement.perform(candidate.retire) {
    Ok(Nil) -> #(state, Error(reason))
    Error(cleanup) -> {
      let held = [Generation(..candidate, retire: cleanup.retry), ..state.held]
      #(State(..state, held:), Error(cleanup_refusal(cleanup.reason, held)))
    }
  }
}

fn invoked(
  active: Option(Generation),
  id: String,
  generation: Int,
  name: String,
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  case active {
    None -> tool.failure("NotApproved: no promoted generation is active")
    Some(current) -> invoke_exact(current, id, generation, name, ctx, args)
  }
}

fn invoke_exact(
  current: Generation,
  id: String,
  generation: Int,
  name: String,
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  case
    record.id_string(current.selection.candidate_id) == id
    && current.selection.generation == generation
  {
    False ->
      tool.failure("Stale: discover the current candidate and generation")
    True ->
      case list.find(current.tools, fn(one) { one.name == name }) {
        Error(Nil) ->
          tool.failure("Unknown: this candidate declares no such tool")
        Ok(declared) -> promoted_call(current, declared, ctx, args)
      }
  }
}

fn expired(clock: Clock, deadline: Int) -> Bool {
  let #(now, _) = clock.read(clock)
  now >= deadline
}

// Both hook phases use the same captured value as the callable. The generic
// invocation wrapper never reacquires the owner while this callback runs.
fn promoted_call(
  current: Generation,
  declared: Tool,
  ctx: Ctx,
  args: JsonValue,
) -> ToolOutcome {
  case current.hooks {
    None -> declared.run(ctx, args)
    Some(bus) ->
      gated_call(
        bus,
        declared,
        ctx,
        args,
        hooks.gate(bus, ctx.op_id, declared.name, args, ctx.source_index),
      )
  }
}

fn gated_call(
  bus: hooks.Bus,
  declared: Tool,
  ctx: Ctx,
  args: JsonValue,
  verdict: hooks.Verdict,
) -> ToolOutcome {
  case verdict {
    hooks.Block(extension:, reason:) ->
      tool.failure(extension <> " blocked " <> declared.name <> ": " <> reason)
    hooks.Allow -> {
      let outcome = declared.run(ctx, args)
      let reply = tool.to_result_message(outcome, "evolution", declared.name, 0)
      case hooks.fold_tool_result(bus, reply) {
        message.ToolResultMessage(content:, ..) ->
          tool.ToolOutcome(..outcome, content:)
        message.UserMessage(..)
        | message.AssistantMessage(..)
        | message.CustomMessage(..) -> outcome
      }
    }
  }
}

fn cleanup_refusal(reason: String, held: List(Generation)) -> store.Refusal {
  let task =
    list.fold(held, retirement.repeat(fn() { Ok(Nil) }), fn(task, generation) {
      retirement.sequence(task, generation.retire)
    })
  store.CleanupUnconfirmed(reason, task)
}

/// Retains a failed catalogue retirement capability before wording its error.
///
/// ## Examples
///
/// ```gleam
/// // live.retain(owner, refusal)
/// ```
///
pub fn retain(owner: Live, refusal: store.Refusal) -> Nil {
  case refusal {
    store.CleanupUnconfirmed(_, retire) -> {
      let _ =
        call.try_call(owner.subject, waiting: 1000, sending: fn(reply) {
          Retain(retire, reply)
        })
      Nil
    }
    _ordinary -> Nil
  }
}

/// Reconciles committed central selection and its audit before serving calls.
///
/// ## Examples
///
/// ```gleam
/// // live.recover(owner, 120_000)
/// ```
///
pub fn recover(owner: Live, waiting: Int) -> Result(Nil, store.Refusal) {
  call.try_call(owner.subject, waiting:, sending: Recover)
  |> result.replace_error(store.Busy)
  |> result.flatten
}

fn retained_refusal(state: State, refusal: store.Refusal) -> State {
  case refusal {
    store.CleanupUnconfirmed(_, retire) ->
      State(..state, pending: [retire, ..state.pending])
    _ordinary -> state
  }
}

fn recovered(state: State) -> #(State, Result(Nil, store.Refusal)) {
  case state.active, state.held, state.pending {
    Some(_), _, _ -> #(state, Ok(Nil))
    None, [], [] ->
      case state.config.recover() {
        Ok(active) -> #(State(..state, active:), Ok(Nil))
        Error(reason) -> #(retained_refusal(state, reason), Error(reason))
      }
    None, [_, ..], _ | None, [], [_, ..] -> #(
      state,
      Error(cleanup_refusal("retained custody forbids recovery", state.held)),
    )
  }
}

fn active_list(active: Option(Generation)) -> List(Generation) {
  case active {
    None -> []
    Some(generation) -> [generation]
  }
}

fn recover_previous(
  discarded: #(State, Result(record.Selection, store.Refusal)),
) -> #(State, Result(record.Selection, store.Refusal)) {
  let #(state, answer) = discarded
  let #(next, _) = recovered(state)
  #(next, answer)
}

/// Evaluates immutable author tests under the same bounded native custody.
///
/// ## Examples
///
/// `live.evaluate(owner, run_tests)` retains an uncertain cleanup before replying.
pub fn evaluate(
  owner: Live,
  work: fn() -> Result(record.Evidence, store.Refusal),
) -> Result(record.Evidence, store.Refusal) {
  call.try_call(owner.subject, waiting: 120_000, sending: Evaluate(work, _))
  |> result.replace_error(store.Busy)
  |> result.flatten
}

fn validate_active(state: State) -> #(State, Result(Nil, store.Refusal)) {
  case state.active {
    None -> #(state, Ok(Nil))
    Some(current) -> {
      let checked = current.validate()
      case checked {
        Error(error) -> #(retained_refusal(state, error), checked)
        Ok(_) -> #(state, checked)
      }
    }
  }
}

/// Queues a notify-only hook without blocking its strand driver.
/// The owner drains it synchronously before processing a later activation.
///
/// ## Examples
///
/// `live.notice(owner, notified)` preserves generation ordering.
pub fn notice(owner: Live, work: fn(Option(Generation)) -> Nil) -> Nil {
  process.send(owner.subject, Notice(work))
}

/// Detaches the generation owner after its cleanup capability is published.
///
/// ## Examples
///
/// `live.detach(owner)` transfers lifetime custody to the instance owner.
pub fn detach(owner: Live) -> Nil {
  case process.subject_owner(owner.subject) {
    Ok(pid) -> process.unlink(pid)
    Error(_) -> Nil
  }
}

/// Captures model-authored source under serialized native cleanup custody.
///
/// ## Examples
///
/// `live.snapshot(owner, capture)` refuses further allocation on lost retirement.
pub fn snapshot(
  owner: Live,
  work: fn() -> Result(archive.Tree, store.Refusal),
) -> Result(archive.Tree, store.Refusal) {
  call.try_call(owner.subject, waiting: 120_000, sending: Snapshot(work, _))
  |> result.replace_error(store.Busy)
  |> result.flatten
}

/// Executes a selected reusable program and its hooks in one generation fold.
///
/// ## Examples
///
/// `live.execute(owner, name, ctx, args, invoke)` preserves the captured hooks.
pub fn execute(
  owner: Live,
  name: String,
  ctx: Ctx,
  args: JsonValue,
  work: fn() -> Result(ToolOutcome, store.Refusal),
) -> ToolOutcome {
  let #(now, _) = clock.read(owner.clock)
  call.try_call(owner.subject, waiting: 120_000, sending: Execute(
    name,
    ctx,
    args,
    work,
    now + 120_000,
    _,
  ))
  |> result.unwrap(tool.failure("Busy: selected program did not settle"))
}

fn execute_with(
  active: Option(Generation),
  name: String,
  ctx: Ctx,
  args: JsonValue,
  work: fn() -> Result(ToolOutcome, store.Refusal),
) -> Result(ToolOutcome, store.Refusal) {
  case option.then(active, fn(current) { current.hooks }) {
    None -> work()
    Some(bus) -> {
      case hooks.gate(bus, ctx.op_id, name, args, ctx.source_index) {
        hooks.Block(extension:, reason:) ->
          Ok(tool.failure(extension <> " blocked " <> name <> ": " <> reason))
        hooks.Allow -> {
          use outcome <- result.try(work())
          let reply =
            tool.to_result_message(outcome, "evolution", name, ctx.source_index)
          case hooks.fold_tool_result(bus, reply) {
            message.ToolResultMessage(content:, ..) ->
              Ok(tool.ToolOutcome(..outcome, content:))
            message.UserMessage(..)
            | message.AssistantMessage(..)
            | message.CustomMessage(..) -> Ok(outcome)
          }
        }
      }
    }
  }
}
