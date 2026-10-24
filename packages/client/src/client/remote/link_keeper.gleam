//// The link keeper: keeps the distribution connection to one remote
//// orchestrator up while a parent session has a child running there
//// (protocol-change/084, phase 2).
////
//// Everything a parent sends to a remote orchestrator dials on demand
//// (`client/remote/remote_spawner`), so a parent never needed a connection to
//// stay up. Phase 2 adds messages the remote originates: a child's mail to its
//// parent and its progress. The remote never dials, because a laptop behind
//// a NAT has no address it could reach, so those messages can only be sent
//// over a connection the laptop made. This machine makes sure there is one
//// whenever someone upstairs is waiting for a message: it reconnects every two
//// seconds while it holds, and it holds only while a session says it has a child
//// there. A node that stays down is tried less often, up to every thirty
//// seconds, and a look that finds it up goes back to two.
////
//// ## One keeper for each orchestrator, in the daemon
////
//// A distribution connection belongs to the node, not to a session, so the
//// keeper is a daemon-level service, one for each `[orchestrators.<name>]`, in
//// the tier that holds the orchestrator port. A session reaches it by a
//// `weft/registry` address, which survives a restart of the keeper.
////
//// ## Votes, and why there is no table of them on disk
////
//// A session's remote drainer votes `Hold` for an orchestrator on every pass
//// that finds a `Requested` or running `Spawned` stub for it, and `Drop` when
//// a pass finds nothing owed (`client/remote_drain`). The pass runs at session
//// open and every five seconds while a child runs, so a daemon that restarted
//// has its votes again within one pass, and nothing here is persisted. The
//// keeper also monitors the process that voted. A session that closes takes
//// its drainer with it, and the keeper drops the vote when the monitor fires,
//// so a session cannot leave the keeper holding for ever by dying.
////
//// ## Flow
////
//// `start` → `builder` → `entered` → `handle` → `hold` | `drop`
////
//// 1. `start` (or `supervised`) builds the machine and `entered` arms or
////    cancels its one periodic beat on each way into a phase.
//// 2. `handle` applies a vote, a beat or the death of a voter. A beat asks
////    `Link.connected` and calls `Link.connect` only when the answer is no.
//// 3. `hold` and `drop` are the voting calls. They send from the calling
////    process, which is the voter the keeper monitors.
////
//// <!-- transitions: link_keeper.Phase -->
////
//// | state | Hold | Drop | Beat | a voter dies |
//// | --- | --- | --- | --- | --- |
//// | `Idle` | `Holding`, the beat armed | ignored | ignored, a stale fire | ignored |
//// | `Holding` | vote recorded | vote removed; `Idle` when none is left | connects if the node is not connected, and waits longer if it still is not | its votes are removed; `Idle` when none is left |
////
//// The votes live in the machine's data and not in the `Holding` state. A
//// state value that changed with every vote would be a state change, and every
//// state change re-arms the beat, so a session that voted every five seconds
//// would keep postponing the reconnect it was waiting for.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Down, type Monitor, type Pid, type Subject}
import gleam/int
import gleam/otp/supervision.{type ChildSpecification}
import weft/actor
import weft/registry as address
import weft/state_machine as sm
import weft/timer

/// How often a holding keeper looks at the connection, in milliseconds, while the
/// connection is up or has just come back.
pub const beat_ms = 2000

/// The longest the keeper waits between looks while the node stays down, in
/// milliseconds. Each look that finds the node still down after a connect doubles
/// the wait up to this, so a box that is off costs a connect timeout every thirty
/// seconds and not every two, and a look that finds the node up resets it.
pub const max_beat_ms = 30_000

// The one name the beat is armed under. Arming a name replaces whatever was
// armed under it, so there is never more than one live chain. The beat is a
// one-shot that each look re-arms, because its delay changes.
const beat_timer = "link-keeper-beat"

/// What the keeper does about the connection, as functions so that a test
/// plays the network. The daemon fills them from the orchestrator's pinned peer
/// (`client/distribution`).
pub type Link {
  Link(
    /// Whether the node is connected now. It reads the connection set and dials
    /// nothing.
    connected: fn() -> Bool,
    /// Connects to the node, bounded by a deadline of its own, and says nothing
    /// of the result: the next beat asks `connected` again.
    connect: fn() -> Nil,
  )
}

/// What the keeper is made of.
pub type Options {
  Options(
    /// The connection it keeps.
    link: Link,
    /// The timer source its beat is armed on, `effects.real_timers().after` in
    /// the daemon and a test's fake wheel in a test.
    after: fn(Int, fn() -> Nil) -> Nil,
  )
}

/// The daemon's keepers by the name of the `[orchestrators.<name>]` each one
/// keeps. An orchestrator enrolled after the daemon started has no keeper until
/// the next start, and a vote for it is dropped.
pub type Keepers =
  Dict(String, address.Address(Message))

/// The keeper's mailbox. A caller does not build one: `hold` and `drop` do.
pub opaque type Message {
  Vote(session: String, voter: Pid)
  Withdraw(session: String)
  Beat
  VoterDown(Down)
}

/// Whether the keeper is working.
type Phase {
  /// No session has a child on this orchestrator, and no timer is armed.
  Idle

  /// At least one session has, and the beat is armed.
  Holding
}

// One session's vote, and the monitor on the process that cast it.
type Voter {
  Voter(pid: Pid, monitor: Monitor)
}

// What the machine carries: the connection it keeps and the votes, by session.
type State {
  State(link: Link, voters: Dict(String, Voter), delay_ms: Int)
}

/// Starts a keeper under `name`, linked to the caller.
///
/// ## Examples
///
/// ```gleam
/// // link_keeper.start(options, name)
/// ```
pub fn start(
  options: Options,
  name: address.Address(Message),
) -> actor.StartResult(Subject(Message)) {
  builder(options, name) |> sm.start
}

/// The keeper as a supervision child, in the daemon's restartable service
/// tier. A restart begins `Idle` with no votes, and the next pass of every
/// session that has a child there votes again.
///
/// ## Examples
///
/// ```gleam
/// // sup.add(builder, link_keeper.supervised(options, name))
/// ```
pub fn supervised(
  options: Options,
  name: address.Address(Message),
) -> ChildSpecification(Subject(Message)) {
  sm.supervised(builder(options, name))
}

/// Votes that `session` has a child on this keeper's orchestrator. The calling
/// process is the voter, and the keeper drops the vote if it dies. A vote to a
/// keeper that is restarting is lost, which costs nothing: the voter's next
/// pass votes again.
///
/// ## Examples
///
/// ```gleam
/// // link_keeper.hold(keeper, "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn hold(keeper: address.Address(Message), session: String) -> Nil {
  let _sent = address.send(keeper, Vote(session:, voter: process.self()))
  Nil
}

/// Withdraws `session`'s vote.
///
/// ## Examples
///
/// ```gleam
/// // link_keeper.drop(keeper, "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn drop(keeper: address.Address(Message), session: String) -> Nil {
  let _sent = address.send(keeper, Withdraw(session:))
  Nil
}

// The machine `start` and `supervised` both describe.
/// Builder keeps this client operation’s decoding or state decision in one place.
fn builder(
  options: Options,
  name: address.Address(Message),
) -> sm.Builder(Phase, State, Message, Subject(Message)) {
  sm.new_with_initialiser(5000, fn(subject) {
    // A voter's death arrives as an ordinary message, so the selector takes the
    // machine's own subject and every monitor the machine installs.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(VoterDown)
    sm.initialised(
      Idle,
      State(link: options.link, voters: dict.new(), delay_ms: beat_ms),
    )
    |> sm.selecting(selector)
    |> sm.returning(subject)
    |> Ok
  })
  |> sm.with_timer_source(timer.Injected(after: options.after))
  |> sm.addressed(name)
  |> sm.on_enter(entered)
  |> sm.on_event(handle)
}

// Arms the beat on the way into `Holding` and cancels it on the way out.
// Cancelling also drops a beat that is already in flight, so a keeper that went
// idle never connects on a late fire.
/// Entered keeps this client operation’s decoding or state decision in one place.
fn entered(
  from: Phase,
  to: Phase,
  data: State,
) -> sm.Enter(Phase, State, Message) {
  // This match resolves from, to before the surrounding protocol step continues.
  // This match resolves from, to before the enclosing validation continues.
  case from, to {
    Idle, Holding ->
      sm.keep(State(..data, delay_ms: beat_ms))
      |> sm.with_named_timeout(name: beat_timer, after: beat_ms, sending: Beat)
    Holding, Idle -> sm.keep(data) |> sm.cancel_timeout(name: beat_timer)
    Idle, Idle | Holding, Holding -> sm.keep(data)
  }
}

/// Handle keeps this client operation’s decoding or state decision in one place.
fn handle(
  phase: Phase,
  data: State,
  message: Message,
) -> sm.Next(Phase, State, Message) {
  // This match resolves phase, message before the surrounding protocol step continues.
  // This match resolves phase, message before the enclosing validation continues.
  case phase, message {
    // A vote opens the machine. A second vote from the same session replaces the
    // first, so a drainer that restarted under a new process is monitored
    // afresh.
    Idle, Vote(session:, voter:) | Holding, Vote(session:, voter:) ->
      sm.transition(to: Holding, data: voted(data, session, voter))

    Idle, Withdraw(..) -> sm.keep(data)
    Holding, Withdraw(session:) -> settled(data |> without(session))

    // The beat is the whole of the keeper's work: ask whether the node is
    // connected, and connect only if it is not. A fire that arrives after the
    // machine went idle is a stale one.
    Idle, Beat -> sm.keep(data)
    Holding, Beat -> {
      let delay_ms = next_delay(data)
      sm.keep(State(..data, delay_ms:))
      |> sm.with_named_timeout(name: beat_timer, after: delay_ms, sending: Beat)
    }

    Idle, VoterDown(down) | Holding, VoterDown(down) ->
      settled(data |> without_dead(down))
  }
}

// Looks at the connection and connects if it is down, and answers the wait
// before the next look: the base beat when the node is up or the connect brought
// it back, and twice the last wait, to `max_beat_ms`, when it is still down.
/// Next delay keeps this client operation’s decoding or state decision in one place.
fn next_delay(data: State) -> Int {
  // This match resolves data.link.connected() before the surrounding protocol step continues.
  // This match resolves data.link.connected() before the enclosing validation continues.
  case data.link.connected() {
    True -> beat_ms
    False -> {
      data.link.connect()

      // This match resolves data.link.connected() before the surrounding protocol step continues.
      case data.link.connected() {
        True -> beat_ms
        False -> int.min(max_beat_ms, data.delay_ms * 2)
      }
    }
  }
}

// Records a vote, replacing and demonitoring the session's earlier one.
/// Voted keeps this client operation’s decoding or state decision in one place.
fn voted(data: State, session: String, pid: Pid) -> State {
  let cleared = without(data, session)
  State(
    ..cleared,
    voters: dict.insert(
      cleared.voters,
      session,
      Voter(pid:, monitor: process.monitor(pid)),
    ),
  )
}

// Removes a session's vote and the monitor that came with it.
/// Without keeps this client operation’s decoding or state decision in one place.
fn without(data: State, session: String) -> State {
  // This match resolves dict.get(data.voters, session) before the surrounding protocol step continues.
  // This match resolves dict.get(data.voters, session) before the enclosing validation continues.
  case dict.get(data.voters, session) {
    Ok(voter) -> {
      process.demonitor_process(voter.monitor)
      State(..data, voters: dict.delete(data.voters, session))
    }
    Error(Nil) -> data
  }
}

// Removes every vote the dead process cast. A monitor that fires is spent, so
// there is nothing to demonitor.
/// Without dead keeps this client operation’s decoding or state decision in one place.
fn without_dead(data: State, down: Down) -> State {
  // This match resolves down before the enclosing validation continues.
  let dead = case down {
    process.ProcessDown(monitor:, ..) | process.PortDown(monitor:, ..) ->
      monitor
  }

  State(
    ..data,
    voters: dict.filter(data.voters, fn(_session, voter) {
      voter.monitor != dead
    }),
  )
}

// `Holding` while any vote is left, and `Idle` when none is.
/// Settled keeps this client operation’s decoding or state decision in one place.
fn settled(data: State) -> sm.Next(Phase, State, Message) {
  // This match resolves dict.is_empty(data.voters) before the surrounding protocol step continues.
  // This match resolves dict.is_empty(data.voters) before the enclosing validation continues.
  case dict.is_empty(data.voters) {
    True -> sm.transition(to: Idle, data:)
    False -> sm.transition(to: Holding, data:)
  }
}
