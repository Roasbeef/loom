//// The live effect-generation ledger.
////
//// A strand replacement may begin only after every older incarnation's
//// reaper has exited. That ordering fact cannot live in the restartable
//// strand-name registry: a rest-for-one restart would erase the very pids
//// whose deaths the replacement must observe. This deliberately tiny actor
//// therefore sits before that boundary and owns only the volatile reaper
//// chains.
////
//// The actor is a significant temporary child. A later child's restart leaves
//// it alive; its own death stops the whole session tree rather than starting
//// an empty ledger and pretending older effects drained. A cold session open
//// starts a genuinely empty ledger because the previous tree, including all
//// of its reapers, is already gone.

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
}

type State =
  Dict(String, List(Pid))

/// Starts the drain ledger under its stable, session-local name.
pub fn start(name: Name(Message)) -> actor.StartResult(Subject(Message)) {
  actor.new(dict.new())
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// Describes the drain ledger as a supervision child.
pub fn supervised(name: Name(Message)) -> ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(name) })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let Claim(strand:, reaper:, reply_with:) = message
  let previous =
    dict.get(state, strand)
    |> result.unwrap([])
    |> list.filter(process.is_alive)
  process.send(reply_with, previous)
  actor.continue(dict.insert(state, strand, [reaper, ..previous]))
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
