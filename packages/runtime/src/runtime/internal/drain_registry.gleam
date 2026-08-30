//// The live effect-generation ledger and shutdown barrier.
////
//// A strand replacement may begin only after every older incarnation's
//// reaper has exited. That ordering fact cannot live in the restartable
//// strand-name registry: a rest-for-one restart would erase the very PIDs
//// whose deaths the replacement must observe. This actor therefore sits
//// before that boundary and owns the volatile reaper chains.
////
//// The same ledger closes the whole-session race. Reapers deliberately
//// outlive their drivers while cooperative provider cancellation drains. On
//// supervisor shutdown this actor traps its parent's exit and remains alive
//// until every registered reaper is Down. OTP treats it as a supervisor child
//// solely to grant that drain an unbounded shutdown interval. Consequently
//// the root cannot die, and `api.close` cannot release the writer lease, while
//// an old provider subtree is still live.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result

/// Messages understood by the drain ledger. Callers use `claim` rather than
/// constructing messages directly.
pub opaque type Message {
  Claim(strand: String, reaper: Pid, reply_with: Subject(List(Pid)))
  ReaperDown(process.Down)
  ParentExit(process.ExitMessage)
}

type State {
  State(chains: Dict(String, List(Pid)), closing: Bool)
}

/// Starts the drain ledger under its stable, session-local name.
pub fn start(name: Name(Message)) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    process.trap_exits(True)
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(ReaperDown)
      |> process.select_trapped_exits(ParentExit)
    actor.initialised(State(chains: dict.new(), closing: False))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// Describes the drain ledger as the root's unbounded shutdown barrier.
pub fn supervised(name: Name(Message)) -> ChildSpecification(Subject(Message)) {
  supervision.supervisor(fn() { start(name) })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Claim(strand:, reaper:, reply_with:) -> {
      let previous =
        dict.get(state.chains, strand)
        |> result.unwrap([])
        |> list.filter(process.is_alive)
      process.send(reply_with, previous)
      let chains = case process.is_alive(reaper) {
        True -> {
          let _monitor = process.monitor(reaper)
          dict.insert(state.chains, strand, [reaper, ..previous])
        }
        False -> dict.insert(state.chains, strand, previous)
      }
      continue_or_stop(State(..state, chains:))
    }
    ReaperDown(process.ProcessDown(pid:, ..)) ->
      continue_or_stop(State(..state, chains: forget(state.chains, pid)))
    ReaperDown(process.PortDown(..)) -> actor.continue(state)
    ParentExit(_exit) -> continue_or_stop(State(..state, closing: True))
  }
}

fn forget(
  chains: Dict(String, List(Pid)),
  departed: Pid,
) -> Dict(String, List(Pid)) {
  dict.map_values(chains, fn(_strand, reapers) {
    list.filter(reapers, fn(reaper) { reaper != departed })
  })
}

fn continue_or_stop(state: State) -> actor.Next(State, Message) {
  let reapers_remain =
    dict.values(state.chains)
    |> list.any(fn(reapers) { list.any(reapers, process.is_alive) })
  case state.closing && !reapers_remain {
    True -> actor.stop()
    False -> actor.continue(state)
  }
}

/// Publishes one incarnation's reaper and returns every predecessor that is
/// still alive. The publish and read are one actor turn, so two replacements
/// cannot both mistake themselves for the only generation.
pub fn claim(
  ledger: Subject(Message),
  strand: String,
  reaper: Pid,
) -> List(Pid) {
  process.call_forever(ledger, Claim(strand, reaper, _))
}
