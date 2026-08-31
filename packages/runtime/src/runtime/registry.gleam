//// The strand-incarnation registry: one small actor mapping strand names to
//// stable process names.
////
//// Process names are minted once per strand and survive every restart
//// below the registry: the strand factory asks `ensure` when it starts a
//// driver, so a crashed driver's replacement registers under the *same*
//// process name and stays addressable, and doorbells resolve through
//// `lookup` at ring time rather than caching pids. The registry sits
//// first in the session tree's rest-for-one order, so it outlives writer
//// and strand crashes; only a whole-tree reboot (open, close) starts it
//// empty, and the strand booter then repopulates it from the store.
////
//// Effect-generation reapers live in the earlier, non-restartable
//// `runtime/internal/drain_registry`; they cannot safely share this actor's
//// restart boundary. Keeping the concerns separate also prevents a process
//// liveness check from being mistaken for proof that descendants drained.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/string
import runtime/strand_runtime

/// Messages understood by the registry. Opaque: callers use the wrapper
/// functions below.
pub opaque type Message {
  Ensure(strand: String, reply_with: Subject(Name(strand_runtime.Message)))
  Lookup(
    strand: String,
    reply_with: Subject(Result(Name(strand_runtime.Message), Nil)),
  )
  Known(reply_with: Subject(List(String)))
}

type State {
  State(names: Dict(String, Name(strand_runtime.Message)))
}

/// Starts a registry registered under `name`.
///
/// ## Examples
///
/// ```gleam
/// // registry.start(name)
/// ```
///
pub fn start(name: Name(Message)) -> actor.StartResult(Subject(Message)) {
  actor.new(State(names: dict.new()))
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// The registry as a supervision child.
///
/// ## Examples
///
/// ```gleam
/// // supervisor.add(builder, registry.supervised(name))
/// ```
///
pub fn supervised(name: Name(Message)) -> ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(name) })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Ensure(strand:, reply_with:) ->
      case dict.get(state.names, strand) {
        Ok(existing) -> {
          process.send(reply_with, existing)
          actor.continue(state)
        }
        Error(Nil) -> {
          let fresh = process.new_name(prefix: "loom_strand")
          process.send(reply_with, fresh)
          actor.continue(State(names: dict.insert(state.names, strand, fresh)))
        }
      }
    Lookup(strand:, reply_with:) -> {
      process.send(reply_with, dict.get(state.names, strand))
      actor.continue(state)
    }
    Known(reply_with:) -> {
      process.send(
        reply_with,
        list.sort(dict.keys(state.names), string.compare),
      )
      actor.continue(state)
    }
  }
}

/// The stable process name for a strand, minting one on first use.
///
/// ## Examples
///
/// ```gleam
/// // registry.ensure(subject, "sub:1")
/// ```
///
pub fn ensure(
  registry: Subject(Message),
  strand: String,
) -> Name(strand_runtime.Message) {
  process.call_forever(registry, Ensure(strand, _))
}

/// The strand's registered process name, if one was ever minted.
///
/// ## Examples
///
/// ```gleam
/// // registry.lookup(subject, "sub:1")
/// ```
///
pub fn lookup(
  registry: Subject(Message),
  strand: String,
) -> Result(Name(strand_runtime.Message), Nil) {
  process.call_forever(registry, Lookup(strand, _))
}

/// Every strand name the registry has minted a process name for, sorted.
///
/// ## Examples
///
/// ```gleam
/// // registry.known(subject)
/// ```
///
pub fn known(registry: Subject(Message)) -> List(String) {
  process.call_forever(registry, Known)
}
