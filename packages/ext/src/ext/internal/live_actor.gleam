//// One weft actor owns a live extension's current JSON state and callbacks.
//// Its PID and inbox survive every compatible migration. Authored callbacks
//// run as bounded weft tasks, so refusal, crash and deadline preserve the
//// state owner and its last successfully decoded state document.

import cap/runtime
import ext/internal/ffi_live_definition
import ext/live
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import weft/actor
import weft/upgrade

/// The fixed trusted message boundary around authored callback execution.
type Message {
  Invoke(runtime.Asked, Subject(runtime.Answer))
  Inspect(Subject(Snapshot))
}

/// A bounded compensation bundle for one unpublished transition.
pub type Snapshot {
  Snapshot(
    /// The latest admitted state, never a historical rollback snapshot.
    state: String,
    /// The exact callbacks that serve this state schema.
    definition: live.Definition,
    /// The state schema identity.
    version: String,
    /// The effect-free current migration implementation.
    migration: String,
  )
}

type State {
  State(snapshot: Snapshot, inbox: Subject(Message), max_state_bytes: Int)
}

/// A satellite-private handle; authored callbacks never receive it.
pub opaque type Handle {
  Handle(pid: Pid, inbox: Subject(Message))
}

/// Starts the component once, before its first invocation.
///
/// ## Examples
///
/// ```gleam
/// // live_actor.start(definition, "v1", migration, 65536, 1000)
/// ```
///
pub fn start(
  definition: live.Definition,
  version: String,
  migration: String,
  max_state_bytes: Int,
  within: Int,
) -> Result(Handle, String) {
  use initial <- result.try(state_document(
    definition.initial_state,
    max_state_bytes,
  ))
  let started =
    actor.new_with_initialiser(within, fn(inbox) {
      Ok(
        actor.initialised(State(
          snapshot: Snapshot(initial, definition, version, migration),
          inbox:,
          max_state_bytes:,
        ))
        |> actor.returning(inbox),
      )
    })
    |> actor.on_message(handle)
    |> actor.with_upgrade(within: int.max(1, within / 4), migrate: change)
    |> actor.start
  case started {
    Ok(started) -> Ok(Handle(started.pid, started.data))
    Error(_) -> Error("stateful extension actor could not start")
  }
}

/// Returns the stable target process identity to the native controller.
///
/// ## Examples
///
/// ```gleam
/// // live_actor.pid(handle)
/// ```
///
pub fn pid(component: Handle) -> Pid {
  component.pid
}

/// Invokes the current callback against the populated state.
///
/// ## Examples
///
/// ```gleam
/// // live_actor.invoke(component, asked)
/// ```
///
pub fn invoke(component: Handle, asked: runtime.Asked) -> runtime.Answer {
  actor.call(component.inbox, asked.deadline_ms + 1000, fn(reply) {
    Invoke(asked, reply)
  })
}

/// Captures only the current bounded transition compensation bundle.
///
/// ## Examples
///
/// ```gleam
/// // live_actor.inspect(component, 1000)
/// ```
///
pub fn inspect(component: Handle, within: Int) -> Snapshot {
  actor.call(component.inbox, within, Inspect)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Inspect(reply) -> {
      process.send(reply, state.snapshot)
      actor.continue(state)
    }
    Invoke(asked, reply) -> {
      let current = state.snapshot.state
      let callback = state.snapshot.definition.on_message
      let maximum = state.max_state_bytes
      let computed =
        upgrade.prepare(asked.deadline_ms, fn() {
          use proposed <- result.try(callback(current, asked))

          // Validation shares the callback deadline, so malformed or expensive
          // documents cannot reach the state owner or escape its task budget.
          use admitted <- result.try(state_document(proposed.0, maximum))
          Ok(#(admitted, proposed.1))
        })
      let #(next, answer) = settle(state, computed)
      process.send(reply, answer)
      actor.continue(next)
    }
  }
}

fn settle(
  state: State,
  computed: Result(#(String, runtime.Answer), String),
) -> #(State, runtime.Answer) {
  case computed {
    Error(reason) -> #(state, runtime.Refused("live_callback_failed", reason))
    Ok(#(text, answer)) -> #(
      State(..state, snapshot: Snapshot(..state.snapshot, state: text)),
      answer,
    )
  }
}

fn change(
  request: upgrade.Request,
  state: State,
) -> Result(actor.Migration(State, Message), String) {
  use proposed <- result.try(ffi_live_definition.change(request.extra))
  use text <- result.try(case proposed.restore {
    Some(snapshot) -> Ok(snapshot)
    None ->
      ffi_live_definition.migrate(
        proposed.migration,
        state.snapshot.version,
        state.snapshot.state,
      )
  })
  use canonical <- result.try(state_document(text, state.max_state_bytes))
  let snapshot =
    Snapshot(
      canonical,
      proposed.definition,
      proposed.version,
      proposed.migration,
    )
  Ok(actor.Migration(
    state: State(..state, snapshot:),
    on_message: handle,
    on_shutdown: None,
    selector: process.new_selector() |> process.select(state.inbox),
    migrate: change,
  ))
}

/// Validates JSON and bounds its UTF-8 document before state admission.
///
/// ## Examples
///
/// ```gleam
/// assert live_actor.state_document("not json", 65536) |> result.is_error
/// ```
///
pub fn state_document(text: String, maximum: Int) -> Result(String, String) {
  use Nil <- result.try(case string.byte_size(text) <= maximum && maximum > 0 {
    True -> Ok(Nil)
    False -> Error("live state exceeds its native byte bound")
  })
  use _ <- result.try(
    json.parse(text, decode.dynamic)
    |> result.replace_error("live state is not a JSON document"),
  )
  Ok(text)
}
