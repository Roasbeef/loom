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
//// until every registered reaper is Down. Its normal exit is the positive
//// acknowledgement; a missing ledger or any abnormal exit fails shutdown
//// closed and cannot authorize writer-lease release.
////
//// ```text
//// old driver Down -> old reaper drains -----------+
////                                                  |
//// new driver -> claim(new reaper) -> wait(old) ----+-> recovery begins
////                                                  |
//// root shutdown -----------------> ledger waits ---+-> lease may close
//// ```

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Name, type Pid, type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result

/// Messages understood by the drain ledger. Callers use `claim` rather than
/// constructing messages directly.
pub opaque type Message {
  /// Publishes a reaper and opens its reply after prior generations drain.
  Claim(strand: String, reaper: Pid, reply_with: Subject(List(Pid)))

  /// Adjudicates whether a reaper proved drain or destroyed its proof.
  ReaperDown(process.Down)

  /// Begins root shutdown without discarding any still-live generation.
  ParentExit(process.ExitMessage)
}

type State {
  State(
    chains: Dict(String, List(Pid)),
    waiters: List(ClaimWaiter),
    closing: Bool,
  )
}

// A claim waits on the ledger's original monitors rather than re-monitoring
// predecessor PIDs after the snapshot. Only this actor can distinguish a
// clean Down from `noproc` after the process identity has disappeared.
type ClaimWaiter {
  ClaimWaiter(predecessors: List(Pid), reply_with: Subject(List(Pid)))
}

/// Starts the drain ledger under its stable, session-local name.
///
/// The ledger traps its supervisor's shutdown exit. Once closing, it accepts
/// no unsafe shortcut: it exits only after all monitored reapers have exited.
///
/// ## Examples
///
/// ```gleam
/// let name = process.new_name(prefix: "loom_drains")
/// drain_registry.start(name)
/// // -> Ok(subject)
/// ```
///
pub fn start(name: Name(Message)) -> actor.StartResult(Subject(Message)) {
  actor.new_with_initialiser(1000, fn(subject) {
    process.trap_exits(True)
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(ReaperDown)
      |> process.select_trapped_exits(ParentExit)
    actor.initialised(State(chains: dict.new(), waiters: [], closing: False))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.named(name)
  |> actor.on_message(handle)
  |> actor.start
}

/// Describes the drain ledger as the root's unbounded shutdown barrier.
///
/// The session supervisor marks this specification significant and temporary.
/// An unexpected ledger exit therefore stops the session instead of replacing
/// the ledger with an empty ownership history.
///
/// ## Examples
///
/// ```gleam
/// let child =
///   drain_registry.supervised(process.new_name(prefix: "loom_drains"))
/// // Add `child` before every restartable session component.
/// ```
///
pub fn supervised(name: Name(Message)) -> ChildSpecification(Subject(Message)) {
  supervision.supervisor(fn() { start(name) })
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Claim(strand:, reaper:, reply_with:) -> {
      // The ledger's original monitor owns the exit reason. Filtering by
      // is_alive here would turn a dead-but-unadjudicated reaper into an empty
      // predecessor set and let recovery overtake its still-draining children.
      let previous = dict.get(state.chains, strand) |> result.unwrap([])
      let _monitor = process.monitor(reaper)
      let chains = dict.insert(state.chains, strand, [reaper, ..previous])
      case previous {
        [] -> {
          // Install the monitor before releasing the caller. A fast normal
          // exit then queues a Down which this actor adjudicates against the
          // state returned from this same turn.
          process.send(reply_with, [])
          continue_or_stop(State(..state, chains:))
        }
        [_, ..] ->
          // Returning predecessor PIDs would ask the replacement to install
          // late monitors. If a predecessor has already exited, that loses
          // its reason as `noproc`; retain the reply until our original
          // monitors have proved every member of this exact snapshot clean.
          continue_or_stop(
            State(..state, chains:, waiters: [
              ClaimWaiter(previous, reply_with),
              ..state.waiters
            ]),
          )
      }
    }
    ReaperDown(process.ProcessDown(pid:, reason: process.Normal, ..)) -> {
      let waiters = acknowledge_departure(state.waiters, pid)
      continue_or_stop(
        State(..state, chains: forget(state.chains, pid), waiters:),
      )
    }
    ReaperDown(process.ProcessDown(reason: process.Killed, ..))
    | ReaperDown(process.ProcessDown(reason: process.Abnormal(_), ..)) -> {
      // No replacement process can reconstruct the killed reaper's ownership
      // set. This actor traps its supervisor's exit, so actor.stop_abnormal
      // would trap its own reason and then return normally. An untrappable
      // kill preserves the outward failure fact: the significant child stops
      // the session and close cannot release the lease.
      process.kill(process.self())
      actor.stop()
    }
    ReaperDown(process.PortDown(..)) -> actor.continue(state)
    ParentExit(_exit) -> continue_or_stop(State(..state, closing: True))
  }
}

fn acknowledge_departure(
  waiters: List(ClaimWaiter),
  departed: Pid,
) -> List(ClaimWaiter) {
  list.filter_map(waiters, fn(waiter) {
    let ClaimWaiter(predecessors:, reply_with:) = waiter
    let predecessors =
      list.filter(predecessors, fn(reaper) { reaper != departed })
    case predecessors {
      [] -> {
        // An empty reply is the snapshot-specific acknowledgement: every PID
        // the claim observed has supplied a Normal Down to its original
        // ledger monitor.
        process.send(reply_with, [])
        Error(Nil)
      }
      [_, ..] -> Ok(ClaimWaiter(predecessors:, reply_with:))
    }
  })
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
  // Entries remain authoritative until their original monitor supplies a
  // Normal Down. A dead PID still present here is pending adjudication, not an
  // empty generation.
  let reapers_remain =
    dict.values(state.chains)
    |> list.any(fn(reapers) { !list.is_empty(reapers) })
  case state.closing && !reapers_remain {
    True -> actor.stop()
    False -> actor.continue(state)
  }
}

/// Publishes one incarnation's reaper and returns after every predecessor in
/// that claim's snapshot has proved normal drain to the ledger's original
/// monitors. The publish and snapshot are one actor turn, so two replacements
/// cannot both mistake themselves for the only generation.
///
/// A successful ledger call returns an empty list because no predecessor in
/// its snapshot remains unadjudicated. The list-shaped result preserves the
/// injected test seam; the new reaper is recorded before this function returns.
///
/// ## Examples
///
/// ```gleam
/// let previous = drain_registry.claim(ledger, "main", new_reaper)
/// // `previous` is empty once the ledger-authored barrier opens.
/// ```
///
pub fn claim(
  ledger: Subject(Message),
  strand: String,
  reaper: Pid,
) -> List(Pid) {
  process.call_forever(ledger, Claim(strand, reaper, _))
}
