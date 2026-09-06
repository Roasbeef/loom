//// The strand-incarnation registry: one small actor mapping strand names to
//// reclaimable process addresses.
////
//// Reference addresses are minted once per strand and survive every restart
//// below the registry: the strand factory asks `ensure` when it starts a
//// driver, so a crashed driver's replacement registers under the *same*
//// address and stays addressable, and doorbells resolve through
//// `lookup` at ring time rather than caching pids. The registry precedes the
//// writer and strand factories, so it outlives their crashes. Its own restart
//// creates a fresh reference namespace and the booter repopulates it from
//// durable strand records, while the earlier drain ledger stays intact.
//// The two strand factories publish their current typed handles here before
//// the booter runs. A replacement overwrites its predecessor's handle; no
//// factory needs a permanent process-name atom.
////
//// Effect-generation reapers live in the earlier, non-restartable
//// `runtime/internal/drain_registry`; they cannot safely share this actor's
//// restart boundary. Keeping the concerns separate also prevents a process
//// liveness check from being mistaken for proof that descendants drained.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/otp/factory_supervisor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import runtime/strand_runtime
import weft/actor
import weft/registry as address

/// The two factory slots, ordered by their supervision restart boundaries.
pub type FactoryKind {
  /// The factory for principal strands, whose failure also restarts subagents.
  Primary

  /// The separately budgeted factory for model-spawned strands.
  Subagent
}

/// One factory incarnation, published by its supervisor's start callback.
pub type Factory {
  Factory(
    /// The process whose liveness makes this handle usable.
    pid: Pid,
    /// The opaque OTP handle returned by starting that same process.
    handle: factory_supervisor.Supervisor(
      String,
      Subject(strand_runtime.Message),
    ),
  )
}

/// Messages understood by the registry. Opaque: callers use the wrapper
/// functions below.
pub opaque type Message {
  Ensure(
    strand: String,
    reply_with: Subject(address.Address(strand_runtime.Message)),
  )
  Lookup(
    strand: String,
    reply_with: Subject(Result(address.Address(strand_runtime.Message), Nil)),
  )
  Known(reply_with: Subject(List(String)))
  PublishFactory(kind: FactoryKind, factory: Factory, reply_with: Subject(Nil))
  LookupFactory(kind: FactoryKind, reply_with: Subject(Result(Factory, Nil)))
}

type State {
  State(
    namespace: address.Registry,
    names: Dict(String, address.Address(strand_runtime.Message)),
    factories: Dict(FactoryKind, Factory),
  )
}

/// Starts a registry bound to its reclaimable service address.
///
/// ## Examples
///
/// ```gleam
/// // registry.start(name)
/// ```
///
pub fn start(
  name: address.Address(Message),
) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(inbox) {
    // The reference namespace shares this registry's restart boundary, not
    // the earlier drain ledger's. Losing routing cannot erase effect custody.
    use namespace <- result.try(address.start())
    actor.initialised(State(
      namespace:,
      names: dict.new(),
      factories: dict.new(),
    ))
    |> actor.returning(inbox)
    |> Ok
  })
  |> actor.addressed(name)
  |> actor.on_message(handle)
  |> actor.on_shutdown(fn(state, _reason) {
    let _stopped = address.stop(state.namespace)
    Nil
  })
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
pub fn supervised(
  name: address.Address(Message),
) -> ChildSpecification(Subject(Message)) {
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
          let fresh = address.new_address(state.namespace)
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
    PublishFactory(kind:, factory:, reply_with:) -> {
      process.send(reply_with, Nil)
      actor.continue(
        State(..state, factories: dict.insert(state.factories, kind, factory)),
      )
    }
    LookupFactory(kind:, reply_with:) -> {
      process.send(reply_with, dict.get(state.factories, kind))
      actor.continue(state)
    }
  }
}

/// The stable reference address for a strand, minting one on first use.
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
) -> address.Address(strand_runtime.Message) {
  process.call_forever(registry, Ensure(strand, _))
}

/// The strand's reference address, if one was ever minted.
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
) -> Result(address.Address(strand_runtime.Message), Nil) {
  process.call_forever(registry, Lookup(strand, _))
}

/// Every strand name the registry has minted an address for, sorted.
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

/// Publishes a factory incarnation before its start callback acknowledges.
/// Only the root supervisor publishes these handles, so replacement writes
/// follow child-start order rather than racing independent publishers.
///
/// ## Examples
///
/// ```gleam
/// // registry.publish_factory(inbox, Primary, Factory(started.pid, started.data))
/// ```
pub fn publish_factory(
  registry: Subject(Message),
  kind: FactoryKind,
  factory: Factory,
) -> Nil {
  process.call_forever(registry, PublishFactory(kind, factory, _))
}

/// Resolves the current live factory. A dead predecessor is unavailable until
/// the root publishes its replacement; callers must resolve again after that
/// restart rather than retaining the previous incarnation's handle.
///
/// ## Examples
///
/// ```gleam
/// // registry.factory(inbox, Subagent)
/// ```
pub fn factory(
  registry: Subject(Message),
  kind: FactoryKind,
) -> Result(Factory, Nil) {
  use factory <- result.try(
    process.call_forever(registry, LookupFactory(kind, _)),
  )
  case process.is_alive(factory.pid) {
    True -> Ok(factory)
    False -> Error(Nil)
  }
}
