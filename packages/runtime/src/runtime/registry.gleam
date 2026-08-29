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
//// The production session tree keeps effect-generation reapers in the
//// earlier, non-restartable `runtime/internal/drain_registry`; they cannot
//// safely share this actor's restart boundary. `ClaimReaper` remains here as
//// a compatibility surface for direct users, but the supervisor deliberately
//// does not route ownership barriers through it.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
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
  ClaimReaper(strand: String, reaper: Pid, reply_with: Subject(List(Pid)))
}

type State {
  State(
    names: Dict(String, Name(strand_runtime.Message)),
    reapers: Dict(String, List(Pid)),
  )
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
  actor.new(State(names: dict.new(), reapers: dict.new()))
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
          actor.continue(
            State(..state, names: dict.insert(state.names, strand, fresh)),
          )
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
    ClaimReaper(strand:, reaper:, reply_with:) -> {
      let previous =
        dict.get(state.reapers, strand)
        |> result.unwrap([])
        |> list.filter(process.is_alive)
      process.send(reply_with, previous)
      actor.continue(
        State(
          ..state,
          reapers: dict.insert(state.reapers, strand, [reaper, ..previous]),
        ),
      )
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

/// Registers a new incarnation's reaper and returns every earlier reaper that
/// is still draining. The registry keeps the whole live chain rather than only
/// the newest pid, so a replacement that itself fails during startup cannot
/// hide an older generation from the next retry.
pub fn claim_reaper(
  registry: Subject(Message),
  strand: String,
  reaper: Pid,
) -> List(Pid) {
  process.call_forever(registry, ClaimReaper(strand, reaper, _))
}
