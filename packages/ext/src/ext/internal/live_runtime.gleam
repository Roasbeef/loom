//// A satellite-private controller keeps native publication separate from state
//// migration. PREPARE holds the target suspended; COMMIT resumes its new state,
//// while ABORT or the deadline compensates an unpublished transition. Ordinary
//// callers get no state snapshot, process handle, or code-loading operation.

import cap/report
import cap/runtime
import ext/internal/ffi_live_code
import ext/internal/ffi_live_definition
import ext/internal/ffi_live_sys
import ext/internal/live_actor
import ext/internal/live_types
import ext/live
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import weft/actor
import weft/upgrade

/// The generated entry's bounded immutable contract.
pub type Config {
  Config(
    /// The initial state schema.
    version: String,
    /// The unchanged message boundary.
    boundary: String,
    /// Original vetted authored module names, shared by the two slots.
    modules: List(String),
    /// Initial fixed-slot pure migration module's BEAM name.
    migration: String,
    /// Maximum suspension including native publication.
    pause_ms: Int,
    /// State size bound enforced on every callback and migration.
    max_state_bytes: Int,
  )
}

/// Trusted system-operation capabilities; authored source cannot import this module.
@internal
pub type Sys {
  Sys(
    /// Suspends the retained state owner.
    suspend: fn(Pid, Int) -> Result(Nil, String),
    /// Changes or compensates the retained owner while suspended.
    change: fn(Pid, live_types.Change, Int) -> Result(Nil, String),
    /// Confirms resumption before relinquishing transition custody.
    resume: fn(Pid, Int) -> Result(Nil, String),
  )
}

/// Trusted controller handle, never transported across the authored boundary.
@internal
pub opaque type Controller {
  Controller(pid: Pid, inbox: Subject(Message), component: live_actor.Handle)
}

type Message {
  Ask(runtime.Asked, Subject(runtime.Answer))
  Expire
}

type Decision {
  Publish
  Compensate
}

type Preparation {
  Cleaning
  Prepared

  Resuming(Decision)
}

type Pending {
  Pending(
    id: String,
    previous: live_actor.Snapshot,
    expires_at: Int,
    version: String,
    slot: String,
    preparation: Preparation,
  )
}

type State {
  State(
    config: Config,
    sys: Sys,
    component: live_actor.Handle,
    pending: Option(Pending),
    last: String,
    last_status: String,
    slot: String,
  )
}

/// Starts the two trusted actors and the existing capability serving loop.
///
/// ## Examples
///
/// ```gleam
/// // live_runtime.serving(config, entry.definition())
/// ```
///
pub fn serving(config: Config, definition: live.Definition) -> Nil {
  case start(config, definition) {
    Error(_) -> Nil
    Ok(controller) -> runtime.serve(fn(asked) { ask(controller, asked) })
  }
}

/// Starts the production controller with standard OTP system operations.
///
/// ## Examples
///
/// `start(config, definition)` retains one state owner across upgrades.
@internal
pub fn start(
  config: Config,
  definition: live.Definition,
) -> Result(Controller, String) {
  start_with_sys(
    config,
    definition,
    Sys(ffi_live_sys.suspend, ffi_live_sys.change, ffi_live_sys.resume),
  )
}

/// Starts the same controller with trusted operation capabilities.
///
/// ## Examples
///
/// `start_with_sys(config, definition, sys)` tests lost acknowledgements.
@internal
pub fn start_with_sys(
  config: Config,
  definition: live.Definition,
  sys: Sys,
) -> Result(Controller, String) {
  use component <- result.try(live_actor.start(
    definition,
    config.version,
    config.migration,
    config.max_state_bytes,
    config.pause_ms,
  ))
  case
    actor.new(State(config, sys, component, None, "", "", "a"))
    |> actor.on_message(handle)
    |> actor.periodic(every: 10, sending: Expire)
    |> actor.start
  {
    Ok(started) -> Ok(Controller(started.pid, started.data, component))
    Error(_) -> Error("live transition controller could not start")
  }
}

/// Sends a trusted invocation through the production controller.
///
/// ## Examples
///
/// `ask(controller, asked)` shares the serving loop's dispatch boundary.
@internal
pub fn ask(controller: Controller, asked: runtime.Asked) -> runtime.Answer {
  actor.call(controller.inbox, asked.deadline_ms + 1000, fn(reply) {
    Ask(asked, reply)
  })
}

/// Returns the trusted component handle for controller supervision and tests.
///
/// ## Examples
///
/// `component(controller)` identifies the retained state owner.
@internal
pub fn component(controller: Controller) -> live_actor.Handle {
  controller.component
}

/// Returns the original trusted controller identity for owner retirement.
///
/// ## Examples
///
/// `pid(controller)` identifies the controller separately from its state actor.
@internal
pub fn pid(controller: Controller) -> Pid {
  controller.pid
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let state = expire(state)
  case message {
    Expire -> actor.continue(state)
    Ask(asked, reply) -> {
      let #(next, answer) = answer(state, asked)
      process.send(reply, answer)
      actor.continue(next)
    }
  }
}

fn answer(state: State, asked: runtime.Asked) -> #(State, runtime.Answer) {
  case asked.invocation {
    runtime.Event("__loom_live_prepare") -> prepared(state, asked.args)
    runtime.Event("__loom_live_commit") -> completed(state, asked.args, Publish)
    runtime.Event("__loom_live_abort") ->
      completed(state, asked.args, Compensate)
    runtime.Event("__loom_live_status") -> #(state, status(state))
    _ -> {
      case state.pending {
        Some(_) -> #(
          state,
          refused("live transition awaits native publication"),
        )
        None -> #(state, live_actor.invoke(state.component, asked))
      }
    }
  }
}

fn prepared(state: State, args: report.Value) -> #(State, runtime.Answer) {
  case state.pending {
    Some(pending) -> {
      case text(args, "transition") == Ok(pending.id) {
        True -> {
          case pending.preparation {
            Prepared | Resuming(Publish) -> #(state, status(state))
            Cleaning | Resuming(Compensate) -> #(
              state,
              refused("live preparation cleanup is pending"),
            )
          }
        }
        False -> #(state, refused("another live transition is prepared"))
      }
    }
    None -> {
      case prepare(state, args) {
        Ok(#(next, outcome)) -> {
          case outcome {
            Ok(Nil) -> #(next, status(next))
            Error(reason) -> #(next, refused(reason))
          }
        }
        Error(reason) -> #(state, refused(reason))
      }
    }
  }
}

fn prepare(
  state: State,
  args: report.Value,
) -> Result(#(State, Result(Nil, String)), String) {
  use id <- result.try(text(args, "transition"))
  use Nil <- result.try(case state.pending {
    None -> Ok(Nil)
    Some(_) -> Error("another live transition is prepared")
  })
  use from <- result.try(text(args, "from"))
  use boundary <- result.try(text(args, "boundary"))
  use version <- result.try(text(args, "version"))
  use slot <- result.try(text(args, "slot"))
  use entry <- result.try(text(args, "entry"))
  use migration <- result.try(text(args, "migration"))
  let expected =
    list.map(state.config.modules, fn(module) { beam_name(slot, module) })
  use Nil <- result.try(
    case
      boundary == state.config.boundary
      && slot != state.slot
      && { slot == "a" || slot == "b" }
      && list.contains(expected, entry)
      && list.contains(expected, migration)
    {
      True -> Ok(Nil)
      False ->
        Error("live contract or fixed implementation slot is incompatible")
    },
  )
  use modules <- result.try(compiled_modules(args))
  use Nil <- result.try(ffi_live_code.retire(expected))
  use baseline <- result.try(
    report.field(args, "atom_baseline")
    |> result.replace_error("native atom baseline is absent"),
  )
  use baseline <- result.try(
    report.as_list(baseline)
    |> result.replace_error("native atom baseline is malformed"),
  )
  use baseline <- result.try(
    list.try_map(baseline, fn(value) {
      report.as_string(value)
      |> result.replace_error("native atom baseline contains a non-string")
    }),
  )
  use Nil <- result.try(ffi_live_code.load(modules, expected, baseline))
  use definition <- result.try(
    upgrade.prepare(state.config.pause_ms, fn() {
      ffi_live_definition.definition(entry)
    }),
  )
  use previous <- result.try(
    upgrade.prepare(state.config.pause_ms, fn() {
      Ok(live_actor.inspect(state.component, state.config.pause_ms))
    }),
  )
  use Nil <- result.try(case previous.version == from {
    True -> Ok(Nil)
    False -> Error("live state version changed before preparation")
  })
  let expires_at = ffi_live_sys.now() + state.config.pause_ms

  // Custody precedes the first suspend signal. A timeout can leave that signal
  // queued, so the controller must retain the snapshot until compensation and
  // resume are acknowledged by the same state owner.
  let pending = Pending(id, previous, expires_at, version, slot, Cleaning)
  let owned = State(..state, pending: Some(pending))
  let changed = {
    use Nil <- result.try(state.sys.suspend(
      live_actor.pid(state.component),
      state.config.pause_ms,
    ))
    state.sys.change(
      live_actor.pid(state.component),
      live_types.Change(definition, version, migration, None),
      state.config.pause_ms,
    )
  }
  case changed {
    Ok(Nil) ->
      Ok(#(
        State(..owned, pending: Some(Pending(..pending, preparation: Prepared))),
        Ok(Nil),
      ))
    Error(reason) -> {
      // Failed acknowledgements do not prove that queued operations did not
      // execute. Retrying compensation keeps ordinary invocations excluded.
      let cleanup = finish(owned, pending, Compensate)
      let next = case cleanup {
        Ok(next) -> next
        Error(#(next, _)) -> next
      }
      Ok(#(next, Error(reason)))
    }
  }
}

fn completed(
  state: State,
  args: report.Value,
  commit: Decision,
) -> #(State, runtime.Answer) {
  case text(args, "transition") {
    Error(reason) -> #(state, refused(reason))
    Ok(id) -> {
      case state.pending {
        None -> #(state, status(state))
        Some(pending) if pending.id == id -> {
          case finish(state, pending, commit) {
            Ok(next) -> #(next, status(next))
            Error(#(next, reason)) -> #(next, refused(reason))
          }
        }
        Some(_) -> #(state, refused("transition identity does not match"))
      }
    }
  }
}

fn finish(
  state: State,
  pending: Pending,
  requested: Decision,
) -> Result(State, #(State, String)) {
  let decision = case pending.preparation {
    Resuming(decision) -> decision
    Cleaning | Prepared -> requested
  }
  let changed = case pending.preparation, decision {
    Resuming(_), _ -> Ok(Nil)
    Cleaning, Publish -> Error("live preparation cleanup is pending")
    Prepared, Publish -> Ok(Nil)
    Cleaning, Compensate | Prepared, Compensate ->
      state.sys.change(
        live_actor.pid(state.component),
        live_types.Change(
          pending.previous.definition,
          pending.previous.version,
          pending.previous.migration,
          Some(pending.previous.state),
        ),
        state.config.pause_ms,
      )
  }
  use Nil <- result.try(
    result.map_error(changed, fn(reason) { #(state, reason) }),
  )

  // Once change is acknowledged, a missing resume reply cannot authorize a
  // second change. The actor may already be running and processing queued work.
  let owned =
    State(
      ..state,
      pending: Some(Pending(..pending, preparation: Resuming(decision))),
    )
  use Nil <- result.try(
    state.sys.resume(live_actor.pid(state.component), state.config.pause_ms)
    |> result.map_error(fn(reason) { #(owned, reason) }),
  )
  let slot = case decision {
    Publish -> pending.slot
    Compensate -> state.slot
  }
  let last_status = case decision {
    Publish -> "committed"
    Compensate -> "aborted"
  }
  let config = case decision {
    Publish -> Config(..state.config, version: pending.version)
    Compensate -> state.config
  }
  Ok(
    State(
      ..state,
      config:,
      pending: None,
      last: pending.id,
      last_status:,
      slot:,
    ),
  )
}

fn expire(state: State) -> State {
  let now = ffi_live_sys.now()
  case state.pending {
    Some(pending) if pending.expires_at <= now ->
      case finish(state, pending, Compensate) {
        Ok(next) -> next
        Error(#(next, _)) -> next
      }
    _ -> state
  }
}

fn status(state: State) -> runtime.Answer {
  runtime.Answered(
    report.object([
      #(
        "pending",
        report.string(case state.pending {
          Some(pending) -> pending.id
          None -> ""
        }),
      ),
      #("last", report.string(state.last)),
      #("last_status", report.string(state.last_status)),
      #("version", report.string(state.config.version)),
      #("slot", report.string(state.slot)),
      #(
        "state_pid",
        report.string(string.inspect(live_actor.pid(state.component))),
      ),
    ]),
  )
}

fn refused(reason: String) -> runtime.Answer {
  runtime.Refused("live_upgrade_refused", reason)
}

fn text(args: report.Value, key: String) -> Result(String, String) {
  use value <- result.try(
    report.field(args, key)
    |> result.replace_error("missing live control field: " <> key),
  )
  report.as_string(value)
  |> result.replace_error("invalid live control field: " <> key)
}

fn compiled_modules(
  args: report.Value,
) -> Result(List(#(String, BitArray, String)), String) {
  use value <- result.try(
    report.field(args, "modules")
    |> result.replace_error("live compiler module set is absent"),
  )
  use values <- result.try(
    report.as_list(value)
    |> result.replace_error("live compiler modules are not a list"),
  )
  list.try_map(values, fn(value) {
    use name <- result.try(text(value, "name"))
    use bytes <- result.try(
      report.field(value, "bytes")
      |> result.replace_error("compiled bytes are absent"),
    )
    use bytes <- result.try(
      report.as_bytes(bytes)
      |> result.replace_error("compiled bytes are not binary"),
    )
    use digest <- result.try(text(value, "digest"))
    Ok(#(name, bytes, digest))
  })
}

fn beam_name(slot: String, module: String) -> String {
  "loom_live_" <> slot <> "@" <> string.replace(module, "/", "@")
}
