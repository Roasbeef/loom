//// The gate that makes a workspace quiet while it is captured
//// (protocol-change/107, "Open: Quiescence at a spawn").
////
//// `client/repository_snapshot` captures a workspace as it is and cannot check
//// that nothing is writing to it, so a caller has to have drained it. A spawn that
//// sends the parent's workspace happens inside a parent turn, and the parent's
//// session can have other tool calls writing the same files. Within one strand the
//// scheduler already covers this, because `agent_spawn` is an `Exclusive` tool and
//// starts only when none of that strand's other calls is running. It does not cover
//// the session's other strands, which run their own tools in the same workspace,
//// and a snapshot that mixes two writes is the failure the capture was written to
//// refuse. This gate covers them: every workspace-side tool call of the session
//// runs inside `shared`, and a capture runs inside `exclusive`.
////
//// ## What it blocks, and for how long
////
//// A capture asks for the workspace and waits for the calls in flight to finish,
//// at most `drain_ms`. From the moment it asks, no new workspace tool call starts:
//// each waits at the gate, at most `entry_wait_ms`, and is answered in band as a
//// failure the model can read and retry if it waits longer. When the workspace is
//// quiet the capture runs holding the gate, at most `hold_ms`. Nothing waits
//// forever at any step. A drain that does not finish in time reopens the gate and
//// refuses the capture with `NotQuiet`. A capture that outlives its hold is cut
//// loose: the gate reopens at the deadline, and when the capture comes back to
//// release, the answer is `Lapsed`, so its result, which may have mixed two
//// writes, is discarded and the spawn is refused instead of sent. A caller that
//// dies while holding or waiting is released by its monitor.
////
//// A background process a tool left running (`bash` with `&`, a code-mode
//// execution) is outside the gate by nature: it is not a tool call in flight.
//// Capture documents that, and so does the spawn.
////
//// ## Flow
////
//// `at` → `supervised` → `shared` → `exclusive` → `handle`
////
//// 1. `at` finds a session's gate by its address, and `supervised` is the child
////    the session's service tree starts there. The machine is `Open`, `Draining`
////    or `Held`.
//// 2. `shared` is what a tool call runs inside: it enters, does its work and
////    leaves. A call that cannot enter in time is `Busy`.
//// 3. `exclusive` is what a capture runs inside: it asks to close, waits for the
////    drain, does its work and reopens.
//// 4. `handle` is the machine. Entries that arrive while the gate is closed are
////    postponed and replayed when it reopens, each judged again against the
////    deadline its caller gave.

import client/internal/ffi_os
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/list
import gleam/otp/supervision
import gleam/result
import gleam/string
import host/bootstrap
import weft/registry.{type Address}
import weft/state_machine as sm

/// The longest a capture waits for the calls in flight to finish, in
/// milliseconds.
pub const drain_ms = 30_000

/// The longest a capture may hold the gate, in milliseconds. It is above the
/// capture's own deadline (`client/state_capture.capture_within_ms`) by the time
/// a state takes to reach the orchestrator's store from an executor.
pub const hold_ms = 330_000

/// The longest a tool call waits at a closed gate, in milliseconds. It is the
/// longest a capture can keep the gate closed, so a call that waits this long
/// has been held up by a capture that lapsed.
pub const entry_wait_ms = 340_000

/// Why a tool call did not run.
pub type Busy {
  /// The gate stayed closed for the whole wait, or did not answer.
  Busy
}

/// Why a capture did not run, or why its result cannot be used.
pub type Refusal {
  /// The calls in flight did not finish within the drain, so the workspace was
  /// not quiet. The gate reopened and nothing was captured.
  NotQuiet

  /// The capture held the gate past its deadline and the gate reopened under it,
  /// so what it read may span two writes. Its result is discarded.
  Lapsed

  /// The gate did not answer in time.
  Unavailable
}

/// The gate of one session's workspace, found by its address. Every call
/// resolves the address again, so a gate the supervisor restarted is the one a
/// later call reaches, and a gate that is not there lets the work through.
pub opaque type Gate {
  Gate(address: Address(Message))
}

// The three phases. `Draining` and `Held` carry the epoch of the capture they
// belong to, so a timer armed for one capture can never be taken for another's.
type Phase {
  Open
  Draining(epoch: Int)
  Held(epoch: Int)
}

/// What the gate is sent. Callers never build one: `shared` and `exclusive`
/// send them, and the type is public only so a supervisor can name the gate's
/// address.
pub opaque type Message {
  Enter(entry: Int, who: Pid, deadline: Int, reply: Subject(Admitted))
  Leave(entry: Int)
  Close(
    ticket: Int,
    who: Pid,
    drain: Int,
    hold: Int,
    deadline: Int,
    reply: Subject(Closing),
  )
  Reopen(ticket: Int, reply: Subject(Reopened))
  DrainTimedOut
  HoldTimedOut
  Down(process.Down)
}

type Admitted {
  Admitted
}

type Closing {
  Closed
  NoQuiet
}

type Reopened {
  Intact
  Lost
}

// The calls in flight, each with the monitor that frees it if its process dies,
// and the capture that has asked, with its own.
type Data {
  Data(holders: List(Holder), asking: Dict(Int, Capture), lapsed: List(Int))
}

type Holder {
  Holder(entry: Int, monitor: Monitor)
}

type Capture {
  Capture(who: Monitor, drain: Int, hold: Int, reply: Subject(Closing))
}

/// The gate at an address. It does not start anything: the session's supervisor
/// starts the gate under the address (`supervised`), and a call made before that
/// or after the gate is gone is not held up by it.
///
/// ## Examples
///
/// ```gleam
/// let gate = workspace_gate.at(address)
/// ```
pub fn at(address: Address(Message)) -> Gate {
  Gate(address:)
}

/// The gate as a supervised child, open, registered under `address`. It is
/// supervised by the session's service tree, so it lives and dies with the
/// session it serves, and a gate that crashed comes back open: no capture is
/// holding it, because a capture holds it only while its own process waits.
///
/// ## Examples
///
/// ```gleam
/// sup.add(builder, workspace_gate.supervised(address))
/// ```
pub fn supervised(
  address: Address(Message),
) -> supervision.ChildSpecification(Subject(Message)) {
  machine(address) |> sm.supervised
}

/// Starts a gate under `address`, linked to the caller, and answers the handle
/// to it. A test that has no supervisor starts one this way.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(gate) = workspace_gate.start_at(address)
/// ```
pub fn start_at(address: Address(Message)) -> Result(Gate, String) {
  machine(address)
  |> sm.start
  |> result.map(fn(_started) { Gate(address:) })
  |> result.map_error(fn(error) {
    "the workspace gate did not start: " <> string.inspect(error)
  })
}

/// The builder of the gate's machine, open, with nothing in flight.
fn machine(
  address: Address(Message),
) -> sm.Builder(Phase, Data, Message, Subject(Message)) {
  sm.new_with_initialiser(1000, fn(inbox) {
    let selector =
      process.new_selector()
      |> process.select(inbox)
      |> process.select_monitors(Down)
    let data = Data(holders: [], asking: dict.new(), lapsed: [])
    sm.initialised(Open, data)
    |> sm.selecting(selector)
    |> sm.returning(inbox)
    |> Ok
  })
  |> sm.on_event(handle)
  |> sm.addressed(address)
}

/// Runs a tool call's work inside the gate.
///
/// The call enters, waiting at a closed gate for at most `within_ms`, runs
/// `work` in the caller's own process, and leaves. A gate that is gone lets the
/// work run, because a session whose gate died has no capture to protect and the
/// call must not fail on a mechanism it did not ask for.
///
/// ## Examples
///
/// ```gleam
/// workspace_gate.shared(gate, workspace_gate.entry_wait_ms, fn() { run_the_tool() })
/// ```
pub fn shared(gate: Gate, within_ms: Int, work: fn() -> a) -> Result(a, Busy) {
  case registry.lookup(gate.address) {
    // A session with no gate running has no capture to wait for.
    Error(Nil) -> Ok(work())
    Ok(inbox) -> {
      let entry = ffi_os.unique_positive_integer()
      let deadline = bootstrap.monotonic_time_ms() + within_ms
      let reply = process.new_subject()
      process.send(inbox, Enter(entry:, who: process.self(), deadline:, reply:))

      // The gate answers once it admits the call, which is at once while it is
      // open. A gate that is gone answers with its death.
      case answered(inbox, reply, within_ms) {
        Heard(Admitted) -> {
          let value = work()
          process.send(inbox, Leave(entry:))
          Ok(value)
        }
        GateGone -> Ok(work())

        // An answer that lands after the wait is a call nobody runs, and
        // leaving frees whatever the gate admitted for it.
        Silent -> {
          process.send(inbox, Leave(entry:))
          Error(Busy)
        }
      }
    }
  }
}

// What a wait on the gate found.
type Heard(a) {
  Heard(a)
  GateGone
  Silent
}

/// Waits for the gate's answer, its death, or the end of the wait, whichever
/// comes first.
fn answered(
  inbox: Subject(Message),
  reply: Subject(a),
  within_ms: Int,
) -> Heard(a) {
  // The inbox of a gate that lives has an owner to watch.
  let watch = case process.subject_owner(inbox) {
    Ok(pid) -> process.monitor(pid)
    Error(Nil) -> process.monitor(process.self())
  }

  let heard =
    process.new_selector()
    |> process.select_map(reply, Heard)
    |> process.select_specific_monitor(watch, fn(_down) { GateGone })
    |> process.selector_receive(within_ms)
  process.demonitor_process(watch)

  // The answer, the gate's death, or silence.
  case heard {
    Ok(found) -> found
    Error(Nil) -> Silent
  }
}

/// Runs a capture's work with the workspace quiet.
///
/// The gate closes to new calls, waits up to `drain_ms` for the calls in flight,
/// and runs `work` in the caller's own process with the gate held for at most
/// `hold_ms`. The answer is the work's result when the gate was held to the end,
/// `NotQuiet` when the drain ran out, and `Lapsed` when the hold ran out under the
/// work. In the last case the work ran and its result is dropped.
///
/// ## Examples
///
/// ```gleam
/// workspace_gate.exclusive(gate, workspace_gate.drain_ms, workspace_gate.hold_ms, fn() { capture() })
/// ```
pub fn exclusive(
  gate: Gate,
  drain: Int,
  hold: Int,
  work: fn() -> a,
) -> Result(a, Refusal) {
  case registry.lookup(gate.address) {
    Error(Nil) -> Error(Unavailable)
    Ok(inbox) -> closed_for(inbox, drain, hold, work)
  }
}

/// Asks the gate to close, and runs the work when it has.
fn closed_for(
  inbox: Subject(Message),
  drain: Int,
  hold: Int,
  work: fn() -> a,
) -> Result(a, Refusal) {
  let ticket = ffi_os.unique_positive_integer()
  let deadline = bootstrap.monotonic_time_ms() + drain + settle_ms
  let reply = process.new_subject()
  process.send(
    inbox,
    Close(ticket:, who: process.self(), drain:, hold:, deadline:, reply:),
  )

  // The drain is bounded by the gate's own timer, so this wait adds only the
  // time to answer.
  case answered(inbox, reply, drain + settle_ms) {
    GateGone -> Error(Unavailable)

    // A request the gate may still hold is withdrawn, so it cannot close the
    // gate later for a caller that has gone.
    Silent -> {
      process.send(inbox, Reopen(ticket:, reply: process.new_subject()))
      Error(Unavailable)
    }
    Heard(NoQuiet) -> Error(NotQuiet)
    Heard(Closed) -> {
      let value = work()
      reopened(inbox, ticket, value)
    }
  }
}

// How long past a deadline a caller waits for the gate's answer.
const settle_ms = 5000

/// Releases the gate and answers the work's value only if the hold was intact.
fn reopened(
  inbox: Subject(Message),
  ticket: Int,
  value: a,
) -> Result(a, Refusal) {
  let reply = process.new_subject()
  process.send(inbox, Reopen(ticket:, reply:))

  // A gate that does not answer cannot say the hold was intact.
  case answered(inbox, reply, settle_ms) {
    Heard(Intact) -> Ok(value)
    Heard(Lost) -> Error(Lapsed)
    GateGone | Silent -> Error(Unavailable)
  }
}

// --- the machine ------------------------------------------------------------

/// Handles one event in the current phase.
fn handle(
  phase: Phase,
  data: Data,
  event: Message,
) -> sm.Next(Phase, Data, Message) {
  case phase, event {
    // A call is admitted while the gate is open, and only if its caller is
    // still waiting for the answer.
    Open, Enter(entry:, who:, deadline:, reply:) ->
      admitted(data, entry, who, deadline, reply)
    Draining(..), Enter(..) | Held(..), Enter(..) ->
      sm.keep(data) |> sm.postpone

    _, Leave(entry:) -> left(phase, data, entry)

    // A capture that asks while the gate is open starts the drain, and one that
    // asks while another holds it waits for its turn.
    Open, Close(ticket:, who:, drain:, hold:, deadline:, reply:) ->
      closing(data, ticket, who, drain, hold, deadline, reply)
    Draining(..), Close(..) | Held(..), Close(..) ->
      sm.keep(data) |> sm.postpone

    Held(epoch: held), Reopen(ticket:, reply:) ->
      reopening(data, held, ticket, reply)
    Open, Reopen(ticket:, reply:) -> {
      // The hold ran out and the gate reopened under the capture, or a request
      // was withdrawn before it was ever held.
      process.send(reply, answer_for(data, ticket))
      sm.keep(
        Data(
          ..data,
          lapsed: list.filter(data.lapsed, fn(each) { each != ticket }),
        ),
      )
    }
    Draining(..), Reopen(reply:, ..) -> {
      // A capture only reopens after it was told the gate closed, so this
      // is a stale reopen from an earlier capture.
      process.send(reply, Lost)
      sm.keep(data)
    }

    Draining(epoch:), DrainTimedOut -> timed_out_draining(data, epoch)
    Open, DrainTimedOut | Held(..), DrainTimedOut -> sm.keep(data)

    Held(epoch:), HoldTimedOut -> {
      let data = Data(..data, lapsed: [epoch, ..data.lapsed])
      sm.transition(to: Open, data: finished(data, epoch))
    }
    Open, HoldTimedOut | Draining(..), HoldTimedOut -> sm.keep(data)

    _, Down(down) -> gone(phase, data, down)
  }
}

/// Admits a call that is still waiting for the answer, and drops one whose
/// caller has given up, which is how a postponed entry that outlived its wait is
/// kept from holding the gate.
fn admitted(
  data: Data,
  entry: Int,
  who: Pid,
  deadline: Int,
  reply: Subject(Admitted),
) -> sm.Next(Phase, Data, Message) {
  // A caller past its deadline has stopped waiting, and is not admitted.
  case bootstrap.monotonic_time_ms() > deadline {
    True -> sm.keep(data)
    False -> {
      let monitor = process.monitor(who)
      process.send(reply, Admitted)
      sm.keep(Data(..data, holders: [Holder(entry:, monitor:), ..data.holders]))
    }
  }
}

/// A call left, or its caller gave up. If a capture was waiting for the last of
/// them, the gate is held for it now.
fn left(phase: Phase, data: Data, entry: Int) -> sm.Next(Phase, Data, Message) {
  let #(leaving, staying) =
    list.partition(data.holders, fn(holder) { holder.entry == entry })
  list.each(leaving, fn(holder) { process.demonitor_process(holder.monitor) })
  let data = Data(..data, holders: staying)
  quiet(phase, data)
}

/// Moves a draining gate to held when nothing is in flight any more.
fn quiet(phase: Phase, data: Data) -> sm.Next(Phase, Data, Message) {
  case phase, data.holders {
    Draining(epoch:), [] -> held(data, epoch)
    Draining(..), [_, ..] | Open, _ | Held(..), _ -> sm.keep(data)
  }
}

/// Starts a capture's drain, or holds the gate at once if nothing is in flight.
/// A request whose caller has stopped waiting is dropped, which is how one that
/// waited behind another capture is kept from closing the gate for nobody.
fn closing(
  data: Data,
  ticket: Int,
  who: Pid,
  drain: Int,
  hold: Int,
  deadline: Int,
  reply: Subject(Closing),
) -> sm.Next(Phase, Data, Message) {
  // A request past its deadline has a caller that is gone, and is dropped.
  case bootstrap.monotonic_time_ms() > deadline {
    True -> sm.keep(data)
    False -> {
      let capture = Capture(who: process.monitor(who), drain:, hold:, reply:)
      let data = Data(..data, asking: dict.insert(data.asking, ticket, capture))

      // A gate with nothing in flight is held without a drain.
      case data.holders {
        [] -> held(data, ticket)
        [_, ..] ->
          sm.transition(to: Draining(epoch: ticket), data:)
          |> sm.with_state_timeout(after: drain, sending: DrainTimedOut)
      }
    }
  }
}

/// Holds the gate for the capture of `epoch` and tells it so.
fn held(data: Data, epoch: Int) -> sm.Next(Phase, Data, Message) {
  // A capture that is no longer asking has nothing to be told.
  case dict.get(data.asking, epoch) {
    Error(Nil) -> sm.transition(to: Open, data:)
    Ok(capture) -> {
      process.send(capture.reply, Closed)
      sm.transition(to: Held(epoch:), data:)
      |> sm.with_state_timeout(after: capture.hold, sending: HoldTimedOut)
    }
  }
}

/// The drain ran out: the capture is refused and the gate reopens, which replays
/// the calls that waited.
fn timed_out_draining(data: Data, epoch: Int) -> sm.Next(Phase, Data, Message) {
  // The capture that asked is told the workspace did not go quiet.
  case dict.get(data.asking, epoch) {
    Ok(capture) -> process.send(capture.reply, NoQuiet)
    Error(Nil) -> Nil
  }

  sm.transition(to: Open, data: finished(data, epoch))
}

/// A capture releases the gate it holds. The answer is whether the hold lasted.
fn reopening(
  data: Data,
  held: Int,
  ticket: Int,
  reply: Subject(Reopened),
) -> sm.Next(Phase, Data, Message) {
  // Only the capture that holds the gate releases it.
  case held == ticket {
    True -> {
      process.send(reply, Intact)
      sm.transition(to: Open, data: finished(data, ticket))
    }
    False -> {
      process.send(reply, Lost)
      sm.keep(data)
    }
  }
}

/// What a reopen that finds the gate open is told: the hold lapsed if it is on
/// record, and a repeat of a release that already happened is nothing lost.
fn answer_for(data: Data, ticket: Int) -> Reopened {
  case list.contains(data.lapsed, ticket) {
    True -> Lost
    False -> Intact
  }
}

/// Forgets a capture that has ended and stops watching its caller.
fn finished(data: Data, epoch: Int) -> Data {
  // The capture's caller is no longer watched.
  case dict.get(data.asking, epoch) {
    Ok(capture) -> process.demonitor_process(capture.who)
    Error(Nil) -> Nil
  }

  Data(..data, asking: dict.delete(data.asking, epoch))
}

/// A process the gate monitors died: its owner ends the gate, a call in flight
/// is freed, and a capture that died holding or waiting releases the gate.
fn gone(
  phase: Phase,
  data: Data,
  down: process.Down,
) -> sm.Next(Phase, Data, Message) {
  let #(freed, staying) =
    list.partition(data.holders, fn(holder) { holder.monitor == down.monitor })
  let dead_capture =
    dict.to_list(data.asking)
    |> list.find(fn(entry) { { entry.1 }.who == down.monitor })
  let data = Data(..data, holders: staying)

  // The capture's owner died: nothing will release the gate for it.
  case dead_capture, phase {
    Ok(#(epoch, _)), Draining(epoch: current)
    | Ok(#(epoch, _)), Held(epoch: current)
      if epoch == current
    -> sm.transition(to: Open, data: finished(data, epoch))
    Ok(#(epoch, _)), _ -> sm.keep(finished(data, epoch))
    Error(Nil), _ ->
      case freed {
        [] -> sm.keep(data)
        [_, ..] -> quiet(phase, data)
      }
  }
}
