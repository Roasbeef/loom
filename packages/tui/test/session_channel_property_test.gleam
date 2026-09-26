//// Model-based property tests over the terminal's session channel.
////
//// `tui/session_channel` is a pure transition system: every write and close
//// it decides on is queued as an output, and nothing touches a socket until
//// `perform`. So a test can drive the shipped transitions over generated
//// schedules of submissions, well-formed and faulty server replies, pushed
//// frames, clock ticks, retirement and close, and check after every step
//// that the outputs and updates keep the rules the module documents. The
//// lane under test is the one the terminal runs, so the check cannot drift
//// from it.
////
//// The oracle never reads the channel's state. It rebuilds what a daemon
//// would know from the frames the lane wrote: which request is outstanding,
//// which snapshot fragment the lane was granted, which mutations crossed the
//// wire. The updates are then held to that account. The generated server
//// answers whatever request is outstanding, so a schedule is a list of
//// abstract events whose meaning depends on the state each one arrives in.
//// Any sub-list of a schedule is therefore another valid schedule, and a
//// failure shrinks by deleting events.
////
//// Time is part of the schedule. The lane reads no clock: every transition
//// is passed the oracle's `now`, which starts at zero and moves only on a
//// generated tick, so the refresh and deadline rules are checked against
//// the same readings the lane was given.
////
//// The rules checked after every step, by tag:
////
//// - I1: a correlated command is written only while no request awaits its
////   reply. The one exception, a `snapshot_next` inside a transfer, is
////   modelled: the fragment reply releases the wire and grants the credit.
//// - I2: request identities strictly increase, so none is reused.
//// - I3: a mutation crosses the wire at most once. A lane that fails while
////   it awaits the reply reports `UnknownOutcome` for exactly that identity,
////   once, and resends nothing.
//// - I4: a waiting mutation is later written once or reported
////   `DefinitelyNotSent` once, never both, and never neither by the time a
////   failure or retirement closes the lane.
//// - I5: nothing is written after the close, there is one close, and a
////   closed lane is inert.
//// - I6: one `snapshot_next` per granted fragment, naming exactly the
////   granted transfer and index, written in the step that granted it.
//// - I7: a reply whose `reply_to` is stale or mismatched produces no
////   presentation update and closes the lane.
//// - I8: a pushed frame allocates no identity, spends no credit and cannot
////   fail the lane. A commit notice may start a catch-up, which is a new
////   request, and only from an idle lane whose cut is below the notice.
//// - L1: a well-formed answer never fails the lane and yields exactly its
////   own presentation update, with the capture reason the module documents.
//// - L2: a notice at or above the cut, received while a request was in
////   flight, is captured by the lane's next ready transition.
//// - L3: an idle lane with a cut issues its catch-up once 250 ms have
////   passed since it went idle.
//// - L4: an in-flight request fails the lane on the first tick at or past
////   its deadline (10 s for a command, 30 s for a capture, not extended by
////   credits), and not before.
//// - L5: admission follows ADR-010.
////
//// Two obligations are narrower than a reader might expect, because the
//// module documents them that way. `close` is the quit path and is
//// documented as not being retirement, so it reports neither
//// `UnknownOutcome` nor `DefinitelyNotSent`; only failure and `retire` owe
//// those reports. And `has_unsent` and `cancel_unsent` concern mutations
//// only, so a waiting read or lookup is dropped silently on failure.
////
//// Randomness follows core's seeded SplitMix64 generator
//// (`packages/core/test/support/generate.gleam`), so a failure reproduces
//// from its seed. The failure report prints the seed, the step, the
//// shortest failing prefix and a schedule shrunk by deleting events.

import core/codec
import core/json
import core/message
import gleam/bit_array
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import tui/connection
import tui/protocol
import tui/session_channel.{type Channel}
import tui/session_wire
import tui/snapshot
import tui_test/pushed

// --- seeded randomness (core's test/support/generate pattern) -------------

type Seed {
  Seed(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

fn next(seed: Seed) -> #(Int, Seed) {
  let state = int.bitwise_and(seed.state + 0x9E3779B97F4A7C15, mask_64)
  let z = state
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  let z = int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
  #(z, Seed(state:))
}

fn int_between(seed: Seed, min: Int, max: Int) -> #(Int, Seed) {
  let #(raw, seed) = next(seed)
  #(min + raw % { max - min + 1 }, seed)
}

// --- schedules --------------------------------------------------------------

/// One thing that happens to the lane. An event names an intent, not a
/// frame: `Answer` means "the server answers whatever is outstanding",
/// which is decided when the event runs. That is what keeps every
/// sub-list of a schedule meaningful.
type Event {
  /// The operator submits a prompt, a mutation with a unique label.
  SubmitPrompt

  /// A read command the channel classifies as `Read`.
  SubmitRead(name: String)

  /// An exact escalation lookup through `session_channel.lookup`.
  Lookup

  /// An older-page read through `session_channel.history`.
  History

  /// The server's well-formed answer to the outstanding request.
  Answer(choice: Int)

  /// A correlated `error` for the outstanding request.
  Refuse

  /// A correlated frame naming the wrong request.
  Stale(offset: Int, body: StaleBody)

  /// A frame that does not decode.
  Garbage

  /// The transport reports the socket closed.
  Disconnect

  /// A commit notice after the server's head advanced by `advance`.
  Notice(advance: Int)

  /// A commit notice for a sequence below the lane's cut.
  OldNotice

  /// A pushed provider fragment.
  Delta

  /// A pushed usage observation.
  Usage

  /// The clock advances by `ms`, then the lane ticks.
  Tick(ms: Int)

  /// The attachment is replaced.
  Retire

  /// The terminal quits.
  Close

  /// Escape cancels an unsent command.
  CancelUnsent
}

/// What a stale reply would have said had it been correlated.
type StaleBody {
  StaleOutcome
  StaleModels
  StaleEnd
}

/// The authenticated role the server grants, fixed for one run because an
/// attachment's identity cannot change on an existing socket.
type Role {
  Operator
  Observer
}

// Weights are per thousand. Faults and endings are rare so that most
// schedules run long enough to reach deferred notices, waiting commands
// and deadlines before the lane closes: a correlated error is fatal
// whenever the lane is capturing, which is often, so even it stays at one
// percent. The tick sizes straddle the 250 ms refresh and the 10 s and
// 30 s deadlines.
fn event_for(roll: Int, detail: Int) -> Event {
  case roll {
    n if n < 130 -> SubmitPrompt
    n if n < 190 -> SubmitRead(read_name(detail))
    n if n < 220 -> Lookup
    n if n < 250 -> History
    n if n < 591 -> Answer(detail % 3)
    n if n < 601 -> Refuse
    n if n < 611 -> Stale(stale_offset(detail), stale_body(detail))
    n if n < 614 -> Garbage
    n if n < 617 -> Disconnect
    n if n < 710 -> Notice(detail % 4)
    n if n < 740 -> OldNotice
    n if n < 780 -> Delta
    n if n < 810 -> Usage
    n if n < 964 -> Tick(tick_ms(detail))
    n if n < 967 -> Retire
    n if n < 970 -> Close
    _ -> CancelUnsent
  }
}

fn read_name(detail: Int) -> String {
  case detail % 2 {
    0 -> "models"
    _ -> "schedules"
  }
}

fn stale_offset(detail: Int) -> Int {
  case detail % 6 {
    0 -> -2
    1 -> -1
    2 -> 0
    3 -> 1
    4 -> 2
    _ -> 5
  }
}

// The body is drawn from the digits the offset does not use, so every
// offset meets every body.
fn stale_body(detail: Int) -> StaleBody {
  case detail / 6 % 3 {
    0 -> StaleOutcome
    1 -> StaleModels
    _ -> StaleEnd
  }
}

fn tick_ms(detail: Int) -> Int {
  case detail {
    n if n < 78 -> 20 + n * 4
    n if n < 98 -> 1000 + { n - 78 } * 550
    n -> 30_000 + { n - 98 } * 500
  }
}

fn schedule(seed_value: Int) -> #(Role, List(Event)) {
  let seed = Seed(int.bitwise_and(seed_value * 0x2545F4914F6CDD1D, mask_64))
  let #(role, seed) = int_between(seed, 0, 9)
  let #(length, seed) = int_between(seed, 20, 80)
  let #(events, _) =
    list.fold(list.repeat(Nil, length), #([], seed), fn(acc, _) {
      let #(events, seed) = acc
      let #(roll, seed) = int_between(seed, 0, 999)
      let #(detail, seed) = int_between(seed, 0, 99)
      #([event_for(roll, detail), ..events], seed)
    })
  let role = case role {
    0 -> Observer
    _ -> Operator
  }
  #(role, list.reverse(events))
}

// --- the oracle -------------------------------------------------------------

/// Which cut a transfer delivers, and so which update its end must yield.
type Window {
  Recent
  CatchUp(trigger: session_channel.Capture)
  OlderPage
  Escalations(ids: List(String))
}

/// The server's side of one credited transfer.
type Transfer {
  Transfer(id: String, window: Window, next_seq: Int)
}

type Kind {
  Mutation(label: String)
  Read
}

/// The one request the server owes an answer, as the written frames say.
type Awaiting {
  Idle

  /// A subscribe, catch-up, history or lookup awaiting its begin.
  Opening(id: Int, window: Window)

  /// A `snapshot_next` awaiting fragment `index` of `transfer`.
  Fragment(id: Int, transfer: Transfer, index: Int)

  /// A command awaiting its outcome or presentation.
  Command(id: Int, name: String, kind: Kind)
}

/// A fragment the lane has been granted and must credit in the same step.
type Grant {
  NoGrant
  Granted(transfer: Transfer, index: Int)
}

/// The one local command the lane holds without having written it.
type Queued {
  NothingQueued
  QueuedMutation(label: String)
  QueuedRead(name: String)
  QueuedLookup
}

type Lane {
  Open
  Shut
}

/// Whether a notice received mid-request is still owed a capture.
type Owed {
  NothingOwed
  CaptureOwed
}

/// One request the lane wrote during the current step.
type Written {
  Written(id: Int, command: String, label: String)
}

type Oracle {
  Oracle(
    socket: connection.Connection,
    role: Role,
    now: Int,
    /// The server's durable head; commit notices advance it.
    head: Int,
    lane: Lane,
    awaiting: Awaiting,
    deadline: Int,
    last_id: Int,
    grant: Grant,
    /// `next_seq` of the last conversation cut the lane completed.
    cut: Option(Int),
    idle_since: Int,
    queued: Queued,
    /// Labels of every mutation that crossed the wire.
    crossed: List(String),
    owed: Owed,
    /// What a catch-up written in this step is for.
    cause: session_channel.Capture,
    written: List(Written),
    counter: Int,
    /// Which interesting states the run reached, for the coverage check.
    reached: Set(String),
  )
}

/// Which presentation update a step must produce, if any.
type Expect {
  Quiet
  Captures(window: Window)
  Acknowledges(name: String, status: String)
  Answers(name: String)
  Refuses(name: String, id: Int)
  Notices(seq: Int)
  Streams
  Observes
}

/// What a submission was expected to do under ADR-010.
type Admission {
  WritesNow
  WaitsBehind
  NotSent
}

type Failure {
  Failure(step: Int, message: String)
}

fn reach(oracle: Oracle, what: String) -> Oracle {
  Oracle(..oracle, reached: set.insert(oracle.reached, what))
}

// --- one step ---------------------------------------------------------------

// Every step ends here: the outputs are read in order against the wire
// account, then the updates against the local account, then the closure
// and idle obligations. `before` is the oracle as the event found it and
// `fed` is the same oracle after the server's side of the event, which for
// an answer means the outstanding request has been released.
fn settle(
  before: Oracle,
  fed: Oracle,
  event: Event,
  channel: Channel,
  updates: List(session_channel.Update),
  expect: Expect,
) -> Result(#(Channel, Oracle), String) {
  let #(channel, outputs) = session_channel.take_outputs(channel)
  use oracle <- result.try(list.try_fold(
    outputs,
    Oracle(..fed, written: []),
    observe,
  ))
  use oracle <- result.try(
    list.try_fold(updates, oracle, fn(oracle, update) {
      account(before, oracle, update)
    }),
  )
  use Nil <- result.try(presentations(event, updates, expect))
  use oracle <- result.try(closure(before, oracle, event, updates))
  use oracle <- result.try(afterwards(before, oracle))
  Ok(#(channel, oracle))
}

fn observe(
  oracle: Oracle,
  output: session_channel.Out,
) -> Result(Oracle, String) {
  case output {
    session_channel.Shut(socket) -> {
      use <- bool.guard(
        socket != oracle.socket,
        Error("I5 a close names a socket this lane does not own"),
      )
      case oracle.lane {
        Shut -> Error("I5 the lane queued a second close")
        Open -> Ok(Oracle(..oracle, lane: Shut))
      }
    }
    session_channel.Transmit(socket, frame) ->
      transmitted(oracle, socket, frame)
  }
}

fn transmitted(
  oracle: Oracle,
  socket: connection.Connection,
  frame: String,
) -> Result(Oracle, String) {
  use <- bool.guard(
    socket != oracle.socket,
    Error("I5 a frame names a socket this lane does not own"),
  )
  use <- bool.lazy_guard(oracle.lane == Shut, fn() {
    Error("I5 a frame was written after the close: " <> frame)
  })
  use request <- result.try(parse_request(frame))
  use <- bool.lazy_guard(request.id <= oracle.last_id, fn() {
    Error(
      "I2 request "
      <> int.to_string(request.id)
      <> " does not exceed the last identity "
      <> int.to_string(oracle.last_id),
    )
  })
  let oracle =
    Oracle(..oracle, last_id: request.id, written: [
      Written(request.id, request.command, request.label),
      ..oracle.written
    ])
  case oracle.grant {
    Granted(transfer, index) -> credited(oracle, request, transfer, index)
    NoGrant -> issued(oracle, request)
  }
}

// A fragment reply released the wire and granted exactly one credit, so the
// next frame must be that credit and nothing else.
fn credited(
  oracle: Oracle,
  request: Request,
  transfer: Transfer,
  index: Int,
) -> Result(Oracle, String) {
  use <- bool.lazy_guard(request.command != "snapshot_next", fn() {
    Error(
      "I6 the lane wrote "
      <> request.command
      <> " while it owed the credit for fragment "
      <> int.to_string(index)
      <> " of "
      <> transfer.id,
    )
  })
  use snapshot_id <- result.try(string_field(request.body, "snapshot_id"))
  use granted <- result.try(int_field(request.body, "index"))
  use <- bool.lazy_guard(snapshot_id != transfer.id || granted != index, fn() {
    Error(
      "I6 the credit names "
      <> snapshot_id
      <> "#"
      <> int.to_string(granted)
      <> " but the lane was granted "
      <> transfer.id
      <> "#"
      <> int.to_string(index),
    )
  })
  Ok(
    Oracle(
      ..oracle,
      grant: NoGrant,
      awaiting: Fragment(request.id, transfer, index),
    ),
  )
}

fn issued(oracle: Oracle, request: Request) -> Result(Oracle, String) {
  use <- bool.guard(
    request.command == "snapshot_next",
    Error("I6 the lane credited a fragment it was not granted"),
  )
  use <- bool.lazy_guard(oracle.awaiting != Idle, fn() {
    Error(
      "I1 request "
      <> int.to_string(request.id)
      <> " ("
      <> request.command
      <> ") was written while "
      <> describe_awaiting(oracle.awaiting)
      <> " awaits its reply",
    )
  })
  case request.command {
    "subscribe" -> Ok(opening(oracle, request, Recent, 30_000))
    "catch_up" -> caught_up(oracle, request)
    "history" -> Ok(opening(oracle, request, OlderPage, 10_000))
    "escalations_get" -> {
      use ids <- result.try(string_list_field(request.body, "ids"))
      Ok(opening(oracle, request, Escalations(ids), 10_000))
    }
    "prompt" -> mutation_written(oracle, request)
    "models" | "schedules" -> Ok(commanded(oracle, request, Read))
    other -> Error("I1 the lane wrote an unexpected command: " <> other)
  }
}

fn opening(
  oracle: Oracle,
  request: Request,
  window: Window,
  budget: Int,
) -> Oracle {
  Oracle(
    ..oracle,
    awaiting: Opening(request.id, window),
    deadline: oracle.now + budget,
  )
}

// A catch-up always names the cut the lane holds, and it is the capture a
// deferred notice was owed, whichever path issued it.
fn caught_up(oracle: Oracle, request: Request) -> Result(Oracle, String) {
  use from_seq <- result.try(int_field(request.body, "from_seq"))
  use <- bool.lazy_guard(oracle.cut != Some(from_seq), fn() {
    Error(
      "L2 a catch-up from "
      <> int.to_string(from_seq)
      <> " does not name the lane's cut "
      <> string.inspect(oracle.cut),
    )
  })
  let oracle = case oracle.owed, oracle.cause {
    CaptureOwed, session_channel.Notified -> reach(oracle, "deferred notice")
    CaptureOwed, _ | NothingOwed, _ -> oracle
  }
  let oracle = reach(oracle, "catch-up")
  let oracle = opening(oracle, request, CatchUp(oracle.cause), 30_000)
  Ok(Oracle(..oracle, owed: NothingOwed))
}

fn mutation_written(
  oracle: Oracle,
  request: Request,
) -> Result(Oracle, String) {
  use <- bool.lazy_guard(list.contains(oracle.crossed, request.label), fn() {
    Error("I3 mutation " <> request.label <> " crossed the wire a second time")
  })
  let oracle = Oracle(..oracle, crossed: [request.label, ..oracle.crossed])
  Ok(commanded(reach(oracle, "mutation sent"), request, Mutation(request.label)))
}

fn commanded(oracle: Oracle, request: Request, kind: Kind) -> Oracle {
  Oracle(
    ..oracle,
    awaiting: Command(request.id, request.command, kind),
    deadline: oracle.now + 10_000,
  )
}

// The local account: what the lane reports about submissions and outcomes
// must agree with what it wrote in the same step.
fn account(
  before: Oracle,
  oracle: Oracle,
  update: session_channel.Update,
) -> Result(Oracle, String) {
  case update {
    session_channel.Submission(session_channel.Sent(name, id)) ->
      released(oracle, name, id)
    session_channel.Submission(session_channel.DefinitelyNotSent(_)) ->
      withdrawn(oracle)
    session_channel.Submission(session_channel.Waiting(_)) ->
      Error("I4 Waiting was reported as an update; it is only a disposition")
    session_channel.UnknownOutcome(name, id) ->
      unknown(before, oracle, name, id)
    session_channel.Failed(_) ->
      case before.lane, oracle.lane {
        Open, Shut -> Ok(oracle)
        Open, Open | Shut, _ ->
          Error(
            "I5 Failed was reported but the lane did not close in this step",
          )
      }
    session_channel.Captured(..)
    | session_channel.HistoryPage(..)
    | session_channel.LookedUp(..)
    | session_channel.Auxiliary(_)
    | session_channel.RequestRefused(..)
    | session_channel.Streamed(..)
    | session_channel.ToolStreamed(..)
    | session_channel.Noticed(_)
    | session_channel.Acknowledged(..) -> Ok(oracle)
  }
}

fn released(oracle: Oracle, name: String, id: Int) -> Result(Oracle, String) {
  let expected = case oracle.queued {
    NothingQueued -> Error("I4 Submission(Sent) with no command waiting")
    QueuedMutation(label) -> Ok(#("prompt", label))
    QueuedRead(read) -> Ok(#(read, ""))
    QueuedLookup -> Ok(#("escalations_get", ""))
  }
  use #(command, label) <- result.try(expected)
  use <- bool.lazy_guard(
    name != command || !list.contains(oracle.written, Written(id, name, label)),
    fn() {
      Error(
        "I4 Submission(Sent("
        <> name
        <> ", "
        <> int.to_string(id)
        <> ")) does not match a frame written in this step for the waiting "
        <> command,
      )
    },
  )
  Ok(reach(Oracle(..oracle, queued: NothingQueued), "waiting command sent"))
}

fn withdrawn(oracle: Oracle) -> Result(Oracle, String) {
  case oracle.queued {
    QueuedMutation(label) -> {
      use <- bool.lazy_guard(list.contains(oracle.crossed, label), fn() {
        Error("I4 mutation " <> label <> " was withdrawn after it was written")
      })
      Ok(reach(Oracle(..oracle, queued: NothingQueued), "waiting withdrawn"))
    }
    NothingQueued | QueuedRead(_) | QueuedLookup ->
      Error("I4 DefinitelyNotSent was reported with no mutation waiting")
  }
}

fn unknown(
  before: Oracle,
  oracle: Oracle,
  name: String,
  id: Int,
) -> Result(Oracle, String) {
  case before.awaiting, oracle.lane {
    Command(awaited, command, Mutation(_)), Shut
      if awaited == id && command == name
    -> Ok(reach(oracle, "unknown outcome"))
    _, _ ->
      Error(
        "I3 UnknownOutcome("
        <> name
        <> ", "
        <> int.to_string(id)
        <> ") while "
        <> describe_awaiting(before.awaiting)
        <> " was outstanding and the lane is "
        <> string.inspect(oracle.lane),
      )
  }
}

// Every update other than a submission, an unknown outcome or a failure is
// something the terminal paints. A step may produce only the one its event
// earns, which is how a stale reply is shown to paint nothing.
fn presentations(
  event: Event,
  updates: List(session_channel.Update),
  expect: Expect,
) -> Result(Nil, String) {
  let shown = list.filter(updates, is_presentation)
  let matched = case expect, shown {
    Quiet, [] -> True
    Captures(window), [update] -> captures(window, update)
    Acknowledges(name, status), [session_channel.Acknowledged(n, s)] ->
      n == name && s == status
    Answers(_), [session_channel.Auxiliary(protocol.ModelsSnapshot(_))]
    | Answers(_), [session_channel.Auxiliary(protocol.SchedulesSnapshot(_))]
    -> True
    Refuses(name, id), [session_channel.RequestRefused(n, i, _, _)] ->
      n == name && i == id
    Notices(seq), [session_channel.Noticed(s)] -> s == seq
    Streams, [session_channel.Streamed(..)] -> True
    Observes, [session_channel.Auxiliary(protocol.UsageChanged(..))] -> True
    _, _ -> False
  }
  use <- bool.guard(matched, Ok(Nil))
  Error(
    tag_of(event)
    <> " expected "
    <> string.inspect(expect)
    <> " but the step reported "
    <> string.inspect(shown),
  )
}

fn captures(window: Window, update: session_channel.Update) -> Bool {
  case window, update {
    Recent, session_channel.Captured(trigger:, ..) ->
      trigger == session_channel.Requested
    CatchUp(expected), session_channel.Captured(trigger:, ..) ->
      trigger == expected
    OlderPage, session_channel.HistoryPage(..) -> True
    Escalations(_), session_channel.LookedUp(..) -> True
    _, _ -> False
  }
}

fn is_presentation(update: session_channel.Update) -> Bool {
  case update {
    session_channel.Submission(_)
    | session_channel.UnknownOutcome(..)
    | session_channel.Failed(_) -> False
    session_channel.Captured(..)
    | session_channel.HistoryPage(..)
    | session_channel.LookedUp(..)
    | session_channel.Auxiliary(_)
    | session_channel.RequestRefused(..)
    | session_channel.Streamed(..)
    | session_channel.ToolStreamed(..)
    | session_channel.Noticed(_)
    | session_channel.Acknowledged(..) -> True
  }
}

fn tag_of(event: Event) -> String {
  case event {
    Stale(..) -> "I7"
    Notice(_) | OldNotice | Delta | Usage -> "I8"
    SubmitPrompt | SubmitRead(_) | Lookup | History -> "L5"
    Answer(_)
    | Refuse
    | Garbage
    | Disconnect
    | Tick(_)
    | Retire
    | Close
    | CancelUnsent -> "L1"
  }
}

// A step that closes the lane owes its reports: one unknown outcome if a
// mutation was awaiting its reply, one failure unless the lane was retired,
// and a definite refusal for a waiting mutation. `close` owes none, because
// the module documents it as the quit path rather than a retirement.
fn closure(
  before: Oracle,
  oracle: Oracle,
  event: Event,
  updates: List(session_channel.Update),
) -> Result(Oracle, String) {
  case before.lane, oracle.lane {
    Open, Open -> Ok(oracle)
    Shut, Shut -> {
      use <- bool.lazy_guard(updates != [], fn() {
        Error("I5 a closed lane reported " <> string.inspect(updates))
      })
      Ok(oracle)
    }
    Shut, Open -> Error("I5 a closed lane reopened")
    Open, Shut -> closed(before, oracle, event, updates)
  }
}

fn closed(
  before: Oracle,
  oracle: Oracle,
  event: Event,
  updates: List(session_channel.Update),
) -> Result(Oracle, String) {
  let unknowns = list.count(updates, is_unknown)
  let failures = list.count(updates, is_failure)
  let #(owed_unknowns, owed_failures) = case event, before.awaiting {
    Close, _ -> #(0, 0)
    Retire, Command(_, _, Mutation(_)) -> #(1, 0)
    Retire, _ -> #(0, 0)
    _, Command(_, _, Mutation(_)) -> #(1, 1)
    _, _ -> #(0, 1)
  }
  use <- bool.lazy_guard(unknowns != owed_unknowns, fn() {
    Error(
      "I3 closing while "
      <> describe_awaiting(before.awaiting)
      <> " was outstanding reported "
      <> int.to_string(unknowns)
      <> " unknown outcomes, owed "
      <> int.to_string(owed_unknowns),
    )
  })
  use <- bool.lazy_guard(failures != owed_failures, fn() {
    Error(
      "I5 closing reported "
      <> int.to_string(failures)
      <> " failures, owed "
      <> int.to_string(owed_failures),
    )
  })
  use <- bool.lazy_guard(
    event != Close && is_queued_mutation(oracle.queued),
    fn() {
      Error(
        "I4 the lane closed with a waiting mutation neither written nor refused: "
        <> string.inspect(oracle.queued),
      )
    },
  )
  Ok(
    Oracle(
      ..oracle,
      awaiting: Idle,
      grant: NoGrant,
      queued: NothingQueued,
      owed: NothingOwed,
    ),
  )
}

fn is_unknown(update: session_channel.Update) -> Bool {
  case update {
    session_channel.UnknownOutcome(..) -> True
    _ -> False
  }
}

fn is_failure(update: session_channel.Update) -> Bool {
  case update {
    session_channel.Failed(_) -> True
    _ -> False
  }
}

fn is_queued_mutation(queued: Queued) -> Bool {
  case queued {
    QueuedMutation(_) -> True
    NothingQueued | QueuedRead(_) | QueuedLookup -> False
  }
}

// An open lane must have spent every credit it was granted, and must not sit
// idle while a notice is still owed a capture.
fn afterwards(before: Oracle, oracle: Oracle) -> Result(Oracle, String) {
  case oracle.lane {
    Shut -> Ok(oracle)
    Open -> {
      use <- bool.lazy_guard(oracle.grant != NoGrant, fn() {
        Error(
          "I6 the lane did not credit the fragment it was granted: "
          <> string.inspect(oracle.grant),
        )
      })
      use <- bool.guard(
        oracle.awaiting == Idle && oracle.owed == CaptureOwed,
        Error("L2 the lane went idle with a notice still owed a capture"),
      )
      let idle_since = case before.awaiting, oracle.awaiting {
        Idle, _ -> oracle.idle_since
        _, Idle -> oracle.now
        _, _ -> oracle.idle_since
      }
      Ok(Oracle(..oracle, idle_since:))
    }
  }
}

// --- events -----------------------------------------------------------------

fn apply(
  state: #(Channel, Oracle),
  event: Event,
) -> Result(#(Channel, Oracle), String) {
  let #(channel, oracle) = state
  let oracle = Oracle(..oracle, cause: session_channel.Notified)
  case event {
    SubmitPrompt -> submit_prompt(channel, oracle)
    SubmitRead(name) -> submit_read(channel, oracle, name)
    Lookup -> look_up(channel, oracle)
    History -> read_history(channel, oracle)
    Answer(choice) -> answer(channel, oracle, choice)
    Refuse -> refuse(channel, oracle)
    Stale(offset, body) -> stale(channel, oracle, event, offset, body)
    Garbage -> fault(channel, oracle, event, garbage())
    Disconnect -> fault(channel, oracle, event, disconnect())
    Notice(advance) -> {
      let head = oracle.head + advance
      notice(channel, Oracle(..oracle, head:), event, head)
    }
    OldNotice -> {
      let seq = case oracle.cut {
        Some(cut) -> cut - 1
        None -> 0
      }
      notice(channel, oracle, event, seq)
    }
    Delta -> volunteered(channel, oracle, event, delta(), Streams)
    Usage -> volunteered(channel, oracle, event, usage(oracle.head), Observes)
    Tick(ms) -> tick(channel, oracle, ms)
    Retire -> {
      let #(channel, updates) =
        session_channel.retire(channel, "attachment replaced")
      ends(channel, oracle, event, updates)
    }
    Close -> ends(channel, oracle, event, [])
    CancelUnsent -> cancel(channel, oracle)
  }
}

fn submit_prompt(
  channel: Channel,
  oracle: Oracle,
) -> Result(#(Channel, Oracle), String) {
  let label = "intent-" <> int.to_string(oracle.counter)
  let oracle = Oracle(..oracle, counter: oracle.counter + 1)
  let #(channel, disposition) =
    session_channel.submit(
      channel,
      protocol.prompt(1, "main", label),
      now: oracle.now,
    )
  use #(channel, after) <- result.try(settle(
    oracle,
    oracle,
    SubmitPrompt,
    channel,
    [],
    Quiet,
  ))
  let refused =
    oracle.lane == Shut
    || oracle.role == Observer
    || oracle.cut == None
    || oracle.queued != NothingQueued
    || awaiting_mutation(oracle.awaiting)
  let expected = admission(refused, oracle.awaiting)
  use after <- result.try(disposed(
    oracle,
    after,
    expected,
    disposition,
    Written(after.last_id, "prompt", label),
    QueuedMutation(label),
  ))
  Ok(#(channel, after))
}

fn submit_read(
  channel: Channel,
  oracle: Oracle,
  name: String,
) -> Result(#(Channel, Oracle), String) {
  let #(channel, disposition) =
    session_channel.submit(
      channel,
      session_wire.command(1, name, []),
      now: oracle.now,
    )
  let event = SubmitRead(name)
  use #(channel, after) <- result.try(settle(
    oracle,
    oracle,
    event,
    channel,
    [],
    Quiet,
  ))
  let refused = oracle.lane == Shut || oracle.queued != NothingQueued
  let expected = admission(refused, oracle.awaiting)
  use after <- result.try(disposed(
    oracle,
    after,
    expected,
    disposition,
    Written(after.last_id, name, ""),
    QueuedRead(name),
  ))
  Ok(#(channel, after))
}

fn admission(refused: Bool, awaiting: Awaiting) -> Admission {
  case refused, awaiting {
    True, _ -> NotSent
    False, Idle -> WritesNow
    False, _ -> WaitsBehind
  }
}

fn awaiting_mutation(awaiting: Awaiting) -> Bool {
  case awaiting {
    Command(_, _, Mutation(_)) -> True
    Idle | Opening(..) | Fragment(..) | Command(_, _, Read) -> False
  }
}

// ADR-010: a submission is written at once on an idle lane, waits behind an
// active request in the one local slot, or is refused definitely; waiting
// writes nothing and allocates nothing.
fn disposed(
  before: Oracle,
  after: Oracle,
  expected: Admission,
  disposition: session_channel.Disposition,
  written: Written,
  queued: Queued,
) -> Result(Oracle, String) {
  let outcome = case expected, disposition {
    WritesNow, session_channel.Sent(name, id) ->
      case
        name == written.command
        && id == written.id
        && after.written == [written]
      {
        True -> Ok(after)
        False -> Error("the Sent disposition does not match the written frame")
      }
    WaitsBehind, session_channel.Waiting(name) ->
      case name == written.command && after.written == [] {
        True -> Ok(reach(Oracle(..after, queued:), "waiting " <> name))
        False -> Error("a waiting command wrote a frame")
      }
    NotSent, session_channel.DefinitelyNotSent(_) ->
      case after.written == [] {
        True -> Ok(after)
        False -> Error("a refused command wrote a frame")
      }
    _, _ -> Error("the admission does not match ADR-010")
  }
  use message <- result.map_error(outcome)
  "L5 "
  <> message
  <> ": expected "
  <> string.inspect(expected)
  <> " for "
  <> written.command
  <> " while "
  <> describe_awaiting(before.awaiting)
  <> " was outstanding (queued "
  <> string.inspect(before.queued)
  <> ", cut "
  <> string.inspect(before.cut)
  <> "), got "
  <> string.inspect(disposition)
}

fn look_up(
  channel: Channel,
  oracle: Oracle,
) -> Result(#(Channel, Oracle), String) {
  let ids = ["esc-" <> int.to_string(oracle.counter)]
  let oracle = Oracle(..oracle, counter: oracle.counter + 1)
  let #(channel, admitted) = case
    session_channel.lookup(channel, ids, now: oracle.now)
  {
    Ok(channel) -> #(channel, Ok(Nil))
    Error(reason) -> #(channel, Error(reason))
  }
  use #(channel, after) <- result.try(settle(
    oracle,
    oracle,
    Lookup,
    channel,
    [],
    Quiet,
  ))
  let refused =
    oracle.lane == Shut || oracle.cut == None || oracle.queued != NothingQueued
  let expected = admission(refused, oracle.awaiting)
  use after <- result.try(read_admitted(
    oracle,
    after,
    expected,
    admitted,
    "escalations_get",
    QueuedLookup,
  ))
  Ok(#(channel, after))
}

fn read_history(
  channel: Channel,
  oracle: Oracle,
) -> Result(#(Channel, Oracle), String) {
  let #(channel, admitted) = case
    session_channel.history(channel, 0, 50, now: oracle.now)
  {
    Ok(channel) -> #(channel, Ok(Nil))
    Error(reason) -> #(channel, Error(reason))
  }
  use #(channel, after) <- result.try(settle(
    oracle,
    oracle,
    History,
    channel,
    [],
    Quiet,
  ))

  // History never waits: a busy lane leaves the request with its caller.
  let expected = case
    oracle.lane == Open
    && oracle.awaiting == Idle
    && oracle.queued == NothingQueued
    && oracle.cut != None
  {
    True -> WritesNow
    False -> NotSent
  }
  use after <- result.try(read_admitted(
    oracle,
    after,
    expected,
    admitted,
    "history",
    NothingQueued,
  ))
  Ok(#(channel, after))
}

fn read_admitted(
  before: Oracle,
  after: Oracle,
  expected: Admission,
  admitted: Result(Nil, String),
  command: String,
  queued: Queued,
) -> Result(Oracle, String) {
  let commands = list.map(after.written, fn(written) { written.command })
  case expected, admitted, commands {
    WritesNow, Ok(Nil), [written] if written == command -> Ok(after)
    WaitsBehind, Ok(Nil), [] ->
      Ok(reach(Oracle(..after, queued:), "waiting lookup"))
    NotSent, Error(_), [] -> Ok(after)
    _, _, _ ->
      Error(
        "L5 expected "
        <> string.inspect(expected)
        <> " for "
        <> command
        <> " while "
        <> describe_awaiting(before.awaiting)
        <> " was outstanding, got "
        <> string.inspect(admitted)
        <> " writing "
        <> string.inspect(commands),
      )
  }
}

// The server answers the one outstanding request, well formed. Whatever the
// request, the answer releases it, and the lane must not fail.
fn answer(
  channel: Channel,
  oracle: Oracle,
  choice: Int,
) -> Result(#(Channel, Oracle), String) {
  let event = Answer(choice)
  let released = Oracle(..oracle, awaiting: Idle)
  case oracle.lane, oracle.awaiting {
    Shut, _ -> {
      let frame = outcome_frame(oracle.last_id, "admitted")
      feed(channel, oracle, oracle, event, frame, Quiet)
    }
    Open, Idle -> Ok(#(channel, oracle))
    Open, Opening(id, window) -> {
      let transfer =
        Transfer("t" <> int.to_string(oracle.counter), window, oracle.head)
      let fed =
        Oracle(
          ..released,
          grant: Granted(transfer, 0),
          counter: oracle.counter + 1,
        )
      let frame = begin_frame(id, transfer, oracle.role)
      answered(channel, oracle, fed, event, frame, Quiet)
    }
    Open, Fragment(id, transfer, 0) -> {
      let fed = Oracle(..released, grant: Granted(transfer, 1))
      answered(channel, oracle, fed, event, chunk_frame(id, transfer), Quiet)
    }
    Open, Fragment(id, transfer, _) -> {
      let fed = case transfer.window {
        Recent | CatchUp(_) -> Oracle(..released, cut: Some(transfer.next_seq))
        OlderPage | Escalations(_) -> released
      }
      let frame = end_frame(id, transfer)
      answered(channel, oracle, fed, event, frame, Captures(transfer.window))
    }
    Open, Command(id, name, Mutation(_)) -> {
      let status = case choice {
        0 -> "admitted"
        1 -> "committed"
        _ -> "queued"
      }
      let frame = outcome_frame(id, status)
      let expect = Acknowledges(name, status)
      answered(channel, oracle, released, event, frame, expect)
    }
    Open, Command(id, name, Read) -> {
      let frame = read_frame(id, name)
      answered(channel, oracle, released, event, frame, Answers(name))
    }
  }
}

fn answered(
  channel: Channel,
  before: Oracle,
  fed: Oracle,
  event: Event,
  frame: connection.Message,
  expect: Expect,
) -> Result(#(Channel, Oracle), String) {
  use #(channel, after) <- result.try(feed(
    channel,
    before,
    fed,
    event,
    frame,
    expect,
  ))
  use <- bool.lazy_guard(after.lane == Shut, fn() {
    Error(
      "L1 a well-formed answer to "
      <> describe_awaiting(before.awaiting)
      <> " failed the lane",
    )
  })
  Ok(#(channel, after))
}

fn feed(
  channel: Channel,
  before: Oracle,
  fed: Oracle,
  event: Event,
  frame: connection.Message,
  expect: Expect,
) -> Result(#(Channel, Oracle), String) {
  let #(channel, updates) =
    session_channel.receive(channel, frame, now: fed.now)
  settle(before, fed, event, channel, updates, expect)
}

// A correlated error refuses a command, and a lookup or history read that
// is still awaiting its begin, and leaves the lane usable; both are
// `AwaitingReply` in the channel. Once the lane is capturing the
// conversation or receiving fragments, the same error is fatal, as
// `apply_reply` documents.
fn refuse(
  channel: Channel,
  oracle: Oracle,
) -> Result(#(Channel, Oracle), String) {
  case oracle.lane, oracle.awaiting {
    Shut, _ ->
      feed(channel, oracle, oracle, Refuse, error_frame(oracle.last_id), Quiet)
    Open, Idle -> Ok(#(channel, oracle))
    Open, Command(id, name, _) -> refused(channel, oracle, id, name)
    Open, Opening(id, OlderPage) -> refused(channel, oracle, id, "history")
    Open, Opening(id, Escalations(_)) ->
      refused(channel, oracle, id, "escalations_get")
    Open, Opening(id, Recent)
    | Open, Opening(id, CatchUp(_))
    | Open, Fragment(id, _, _)
    -> {
      let frame = error_frame(id)
      use #(channel, after) <- result.try(feed(
        channel,
        oracle,
        oracle,
        Refuse,
        frame,
        Quiet,
      ))
      use <- bool.guard(
        after.lane == Open,
        Error("L1 a correlated error inside a capture left the lane open"),
      )
      Ok(#(channel, after))
    }
  }
}

fn refused(
  channel: Channel,
  oracle: Oracle,
  id: Int,
  name: String,
) -> Result(#(Channel, Oracle), String) {
  let fed = Oracle(..oracle, awaiting: Idle)
  let frame = error_frame(id)
  let expect = Refuses(name, id)
  use #(channel, after) <- result.try(answered(
    channel,
    oracle,
    fed,
    Refuse,
    frame,
    expect,
  ))
  Ok(#(channel, reach(after, "request refused")))
}

// A reply naming the wrong request is a protocol violation in every phase:
// it paints nothing and closes the socket.
fn stale(
  channel: Channel,
  oracle: Oracle,
  event: Event,
  offset: Int,
  body: StaleBody,
) -> Result(#(Channel, Oracle), String) {
  // On an idle lane the likeliest stale reply is a second answer to the
  // request just finished, so non-negative offsets all name that one.
  let reply_to = case oracle.awaiting, offset {
    Idle, _ -> oracle.last_id + int.min(offset, 0)
    Opening(id, _), 0 | Fragment(id, _, _), 0 | Command(id, _, _), 0 -> id - 1
    Opening(id, _), _ | Fragment(id, _, _), _ | Command(id, _, _), _ ->
      id + offset
  }
  let oracle = case oracle.lane, oracle.awaiting, body {
    Open, Idle, StaleOutcome if reply_to == oracle.last_id ->
      reach(oracle, "duplicate outcome")
    _, _, _ -> oracle
  }
  let frame = stale_frame(reply_to, body, oracle.head)
  use #(channel, after) <- result.try(feed(
    channel,
    oracle,
    oracle,
    event,
    frame,
    Quiet,
  ))
  case oracle.lane, after.lane {
    Open, Open -> Error("I7 a stale reply left the lane open")
    Open, Shut -> Ok(#(channel, reach(after, "stale reply")))
    Shut, _ -> Ok(#(channel, after))
  }
}

fn fault(
  channel: Channel,
  oracle: Oracle,
  event: Event,
  frame: connection.Message,
) -> Result(#(Channel, Oracle), String) {
  use #(channel, after) <- result.try(feed(
    channel,
    oracle,
    oracle,
    event,
    frame,
    Quiet,
  ))
  case oracle.lane, after.lane {
    Open, Open -> Error("L1 a transport fault left the lane open")
    Open, Shut | Shut, _ -> Ok(#(channel, after))
  }
}

// A notice is reported whatever the lane does with it. It starts a catch-up
// at once only from an idle lane whose cut is at or below its sequence;
// in flight, it is owed to the next ready transition.
fn notice(
  channel: Channel,
  oracle: Oracle,
  event: Event,
  seq: Int,
) -> Result(#(Channel, Oracle), String) {
  let above = case oracle.cut {
    Some(cut) -> seq >= cut
    None -> False
  }
  let fed = case oracle.lane, oracle.awaiting, above {
    Open, Idle, _ | Open, _, False | Shut, _, _ -> oracle
    Open, _, True -> Oracle(..oracle, owed: CaptureOwed)
  }
  let expect = case oracle.lane {
    Open -> Notices(seq)
    Shut -> Quiet
  }
  let frame = pushed.notice("main", seq)
  use #(channel, after) <- result.try(feed(
    channel,
    oracle,
    fed,
    event,
    frame,
    expect,
  ))
  let issues = oracle.lane == Open && oracle.awaiting == Idle && above
  let commands = list.map(after.written, fn(written) { written.command })
  case after.lane, issues, commands {
    Open, True, ["catch_up"] | Open, False, [] | Shut, False, [] ->
      Ok(#(channel, after))
    _, _, _ ->
      Error(
        "I8 a notice at "
        <> int.to_string(seq)
        <> " (cut "
        <> string.inspect(oracle.cut)
        <> ", "
        <> describe_awaiting(oracle.awaiting)
        <> ") left the lane "
        <> string.inspect(after.lane)
        <> " writing "
        <> string.inspect(commands),
      )
  }
}

fn volunteered(
  channel: Channel,
  oracle: Oracle,
  event: Event,
  frame: connection.Message,
  expect: Expect,
) -> Result(#(Channel, Oracle), String) {
  let expect = case oracle.lane {
    Open -> expect
    Shut -> Quiet
  }
  use #(channel, after) <- result.try(feed(
    channel,
    oracle,
    oracle,
    event,
    frame,
    expect,
  ))
  case oracle.lane, after.lane, after.written {
    Open, Open, [] | Shut, Shut, [] -> Ok(#(channel, after))
    _, _, _ ->
      Error(
        "I8 a pushed frame left the lane "
        <> string.inspect(after.lane)
        <> " writing "
        <> string.inspect(after.written),
      )
  }
}

fn tick(
  channel: Channel,
  oracle: Oracle,
  ms: Int,
) -> Result(#(Channel, Oracle), String) {
  let now = oracle.now + ms
  let before = Oracle(..oracle, now:)
  let fed = Oracle(..before, cause: session_channel.Refreshed)
  let #(channel, updates) = session_channel.tick(channel, now:)
  use #(channel, after) <- result.try(settle(
    before,
    fed,
    Tick(ms),
    channel,
    updates,
    Quiet,
  ))
  let checked = case before.lane, before.awaiting {
    Shut, _ -> Ok(after)
    Open, Idle -> refreshed(before, after)
    Open, _ -> timed(before, after)
  }
  use after <- result.try(checked)
  Ok(#(channel, after))
}

// The refresh may come early, because a mutation's outcome makes the next
// catch-up due at once, but it may not come later than 250 ms after the
// lane went idle.
fn refreshed(before: Oracle, after: Oracle) -> Result(Oracle, String) {
  let due = before.cut != None && before.now >= before.idle_since + 250
  let commands = list.map(after.written, fn(written) { written.command })
  case after.lane, due, commands {
    Open, True, ["catch_up"] -> Ok(reach(after, "refresh"))
    Open, False, ["catch_up"] | Open, False, [] -> Ok(after)
    _, _, _ ->
      Error(
        "L3 an idle lane ticked at "
        <> int.to_string(before.now)
        <> " (idle since "
        <> int.to_string(before.idle_since)
        <> ") left the lane "
        <> string.inspect(after.lane)
        <> " writing "
        <> string.inspect(commands),
      )
  }
}

fn timed(before: Oracle, after: Oracle) -> Result(Oracle, String) {
  let expired = before.now >= before.deadline
  case expired, after.lane, after.written {
    True, Shut, [] -> Ok(reach(after, "deadline"))
    False, Open, [] -> Ok(after)
    _, _, _ ->
      Error(
        "L4 a tick at "
        <> int.to_string(before.now)
        <> " against the deadline "
        <> int.to_string(before.deadline)
        <> " of "
        <> describe_awaiting(before.awaiting)
        <> " left the lane "
        <> string.inspect(after.lane),
      )
  }
}

fn ends(
  channel: Channel,
  oracle: Oracle,
  event: Event,
  updates: List(session_channel.Update),
) -> Result(#(Channel, Oracle), String) {
  let channel = case event {
    Close -> session_channel.close(channel)
    _ -> channel
  }
  use #(channel, after) <- result.try(settle(
    oracle,
    oracle,
    event,
    channel,
    updates,
    Quiet,
  ))
  case oracle.lane, after.lane {
    Open, Open -> Error("L1 " <> describe(event) <> " left the lane open")
    Open, Shut | Shut, _ -> Ok(#(channel, after))
  }
}

// Escape cancels only an unsent mutation; a waiting read keeps its slot.
fn cancel(
  channel: Channel,
  oracle: Oracle,
) -> Result(#(Channel, Oracle), String) {
  let #(channel, updates) =
    session_channel.cancel_unsent(channel, "cancelled by Escape")
  use #(channel, after) <- result.try(settle(
    oracle,
    oracle,
    CancelUnsent,
    channel,
    updates,
    Quiet,
  ))
  case oracle.queued, updates, after.written {
    QueuedMutation(_),
      [session_channel.Submission(session_channel.DefinitelyNotSent(_))],
      []
    -> Ok(#(channel, after))
    NothingQueued, [], [] | QueuedRead(_), [], [] | QueuedLookup, [], [] ->
      Ok(#(channel, after))
    _, _, _ ->
      Error(
        "I4 cancelling with "
        <> string.inspect(oracle.queued)
        <> " waiting reported "
        <> string.inspect(updates),
      )
  }
}

// --- frames -----------------------------------------------------------------

fn expected() -> snapshot.Expected {
  snapshot.Expected("A", "epoch", "incarnation")
}

fn window_name(window: Window) -> String {
  case window {
    Recent -> "recent"
    CatchUp(_) -> "catch_up"
    OlderPage -> "history"
    Escalations(_) -> "escalations"
  }
}

fn role_name(role: Role) -> String {
  case role {
    Operator -> "operator"
    Observer -> "observer"
  }
}

fn begin_frame(id: Int, transfer: Transfer, role: Role) -> connection.Message {
  pushed.reply(
    id,
    "snapshot_begin",
    json.Object([
      #("snapshot_id", json.String(transfer.id)),
      #("session_id", json.String("A")),
      #("epoch", json.String("epoch")),
      #("incarnation", json.String("incarnation")),
      #("connection_id", json.String("connection")),
      #(
        "origin",
        json.Object([
          #("principal", json.String("alice")),
          #("name", json.String("Alice")),
        ]),
      ),
      #("role", json.String(role_name(role))),
      #("next_seq", json.Int(transfer.next_seq)),
      #("oldest_seq", json.Null),
      #("window", json.String(window_name(transfer.window))),
      #("complete_history", json.Bool(False)),
      #("record_bytes_limit", json.Int(snapshot.record_limit)),
      #("fragment_bytes_limit", json.Int(snapshot.piece_limit)),
    ]),
  )
}

// A lookup's metadata answers every requested identity as missing, which is
// the smallest reply `snapshot_view.lookup` accepts.
fn chunk_frame(id: Int, transfer: Transfer) -> connection.Message {
  let data = case transfer.window {
    Escalations(ids) ->
      json.to_string(
        json.Object([
          #("cells", json.Array([])),
          #("missing", json.Array(list.map(ids, json.String))),
        ]),
      )
    Recent | CatchUp(_) | OlderPage -> pushed.metadata()
  }
  pushed.reply(
    id,
    "snapshot_chunk",
    json.Object([
      #("snapshot_id", json.String(transfer.id)),
      #("index", json.Int(0)),
      #("kind", json.String("metadata")),
      #("record_id", json.String("metadata")),
      #("record_seq", json.Null),
      #("total_bytes", json.Int(string.byte_size(data))),
      #("offset", json.Int(0)),
      #(
        "data",
        json.String(bit_array.base64_encode(bit_array.from_string(data), True)),
      ),
    ]),
  )
}

fn end_frame(id: Int, transfer: Transfer) -> connection.Message {
  pushed.reply(
    id,
    "snapshot_end",
    json.Object([
      #("snapshot_id", json.String(transfer.id)),
      #("index", json.Int(1)),
      #("next_seq", json.Int(transfer.next_seq)),
      #("more_after", json.Null),
    ]),
  )
}

fn outcome_frame(id: Int, status: String) -> connection.Message {
  pushed.reply(
    id,
    "mutation_outcome",
    json.Object([#("status", json.String(status))]),
  )
}

fn read_frame(id: Int, name: String) -> connection.Message {
  pushed.reply(
    id,
    "snapshot",
    json.Object([#("mode", json.String(name)), #(name, json.Array([]))]),
  )
}

fn error_frame(id: Int) -> connection.Message {
  pushed.reply(
    id,
    "error",
    json.Object([
      #("code", json.String("refused")),
      #("message", json.String("not now")),
    ]),
  )
}

fn stale_frame(id: Int, body: StaleBody, head: Int) -> connection.Message {
  case body {
    StaleOutcome -> outcome_frame(id, "admitted")
    StaleModels -> read_frame(id, "models")
    StaleEnd -> end_frame(id, Transfer("t-stale", Recent, head))
  }
}

fn garbage() -> connection.Message {
  connection.Incoming("{\"v\":2,\"reply_to\":")
}

fn disconnect() -> connection.Message {
  connection.Closed("the daemon went away")
}

fn delta() -> connection.Message {
  pushed.delta("main", "op-1", "tok")
}

fn usage(seq: Int) -> connection.Message {
  let zero =
    message.Usage(
      0,
      0,
      0,
      0,
      None,
      None,
      0,
      message.UsageCost(0.0, 0.0, 0.0, 0.0, 0.0),
    )
  pushed.push([
    #("event", json.String("usage_observation")),
    #("seq", json.Int(seq)),
    #(
      "body",
      json.Object([
        #("strand", json.String("main")),
        #("usage", codec.encode_usage(zero)),
      ]),
    ),
  ])
}

// --- reading what the lane wrote --------------------------------------------

type Request {
  Request(
    id: Int,
    command: String,
    body: List(#(String, json.JsonValue)),
    label: String,
  )
}

fn parse_request(frame: String) -> Result(Request, String) {
  let not_a_command = "the lane wrote a frame that is not a command: " <> frame
  use value <- result.try(
    json.parse(frame) |> result.replace_error(not_a_command),
  )
  use fields <- result.try(case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error(not_a_command)
  })
  use id <- result.try(int_field(fields, "id"))
  use command <- result.try(string_field(fields, "cmd"))
  use body <- result.try(case list.key_find(fields, "body") {
    Ok(json.Object(body)) -> Ok(body)
    _ -> Error(not_a_command)
  })
  let label = case command {
    "prompt" -> string_field(body, "text") |> result.unwrap("")
    _ -> ""
  }
  Ok(Request(id:, command:, body:, label:))
}

fn int_field(
  fields: List(#(String, json.JsonValue)),
  key: String,
) -> Result(Int, String) {
  case list.key_find(fields, key) {
    Ok(json.Int(value)) -> Ok(value)
    _ -> Error("the lane wrote a frame without an integer " <> key)
  }
}

fn string_field(
  fields: List(#(String, json.JsonValue)),
  key: String,
) -> Result(String, String) {
  case list.key_find(fields, key) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("the lane wrote a frame without a string " <> key)
  }
}

fn string_list_field(
  fields: List(#(String, json.JsonValue)),
  key: String,
) -> Result(List(String), String) {
  let invalid = "the lane wrote a frame without a string list " <> key
  case list.key_find(fields, key) {
    Ok(json.Array(values)) ->
      list.try_map(values, fn(value) {
        case value {
          json.String(text) -> Ok(text)
          _ -> Error(invalid)
        }
      })
    _ -> Error(invalid)
  }
}

// --- running and shrinking --------------------------------------------------

// Runs one schedule from a fresh lane and ends it with a retirement, so that
// every obligation a closing lane owes is checked on every run. The step
// numbers count from one; the final retirement is step `length + 1`.
fn run(role: Role, events: List(Event)) -> Result(Set(String), Failure) {
  let owner: Subject(Dynamic) = process.new_subject()
  let socket = socket_on(owner)
  let channel = session_channel.start(socket, expected(), now: 0)
  let oracle =
    Oracle(
      socket:,
      role:,
      now: 0,
      head: 10,
      lane: Open,
      awaiting: Idle,
      deadline: 0,
      last_id: 0,
      grant: NoGrant,
      cut: None,
      idle_since: 0,
      queued: NothingQueued,
      crossed: [],
      owed: NothingOwed,
      cause: session_channel.Requested,
      written: [],
      counter: 0,
      reached: set.new(),
    )

  // The subscription is written at construction, before any event.
  let #(channel, outputs) = session_channel.take_outputs(channel)
  use oracle <- result.try(
    list.try_fold(outputs, oracle, observe)
    |> result.map_error(Failure(0, _)),
  )
  let steps = list.append(events, [Retire])
  use #(_, oracle) <- result.try(
    list.index_fold(steps, Ok(#(channel, oracle)), fn(state, event, index) {
      use state <- result.try(state)
      apply(state, event) |> result.map_error(Failure(index + 1, _))
    }),
  )

  // Nothing was performed: the stand-in socket's mailbox is still empty.
  use <- bool.guard(
    process.receive(owner, 0) != Error(Nil),
    Error(Failure(list.length(steps), "I5 a transition performed an output")),
  )
  Ok(oracle.reached)
}

fn check(seed_value: Int) -> Result(Set(String), String) {
  let #(role, events) = schedule(seed_value)
  use failure <- result.map_error(run(role, events))
  let prefix = list.take(events, failure.step)
  let tag = invariant(failure.message)
  let shrunk = shrink(role, prefix, tag, list.length(prefix) + 1)
  let shrunk_failure = case run(role, shrunk) {
    Error(found) -> found.message
    Ok(_) -> "the shrunk schedule passed"
  }
  "seed "
  <> int.to_string(seed_value)
  <> " ("
  <> role_name(role)
  <> ", "
  <> int.to_string(list.length(events))
  <> " events) failed at step "
  <> int.to_string(failure.step)
  <> ": "
  <> failure.message
  <> "\n  shortest failing prefix: "
  <> int.to_string(list.length(prefix))
  <> " events: "
  <> describe_all(prefix)
  <> "\n  shrunk to "
  <> int.to_string(list.length(shrunk))
  <> " events (then retire): "
  <> describe_all(shrunk)
  <> "\n  which fails with: "
  <> shrunk_failure
}

fn invariant(message: String) -> String {
  case string.split_once(message, " ") {
    Ok(#(tag, _)) -> tag
    Error(Nil) -> message
  }
}

// Deletes one event at a time, keeping each deletion after which the
// schedule still breaks the same rule, and repeats until a pass deletes
// nothing. The prefix it starts from already ends at the failing step.
fn shrink(
  role: Role,
  events: List(Event),
  tag: String,
  previous: Int,
) -> List(Event) {
  let length = list.length(events)
  use <- bool.guard(length >= previous, events)
  shrink(role, shrink_pass(role, events, tag, 0), tag, length)
}

fn shrink_pass(
  role: Role,
  events: List(Event),
  tag: String,
  index: Int,
) -> List(Event) {
  use <- bool.guard(index >= list.length(events), events)
  let candidate =
    list.append(list.take(events, index), list.drop(events, index + 1))
  let still_fails = case run(role, candidate) {
    Error(failure) -> invariant(failure.message) == tag
    Ok(_) -> False
  }
  case still_fails {
    True -> shrink_pass(role, candidate, tag, index)
    False -> shrink_pass(role, events, tag, index + 1)
  }
}

fn describe_all(events: List(Event)) -> String {
  list.map(events, describe) |> string.join(", ")
}

fn describe(event: Event) -> String {
  case event {
    SubmitPrompt -> "prompt"
    SubmitRead(name) -> "read(" <> name <> ")"
    Lookup -> "lookup"
    History -> "history"
    Answer(choice) -> "answer(" <> int.to_string(choice) <> ")"
    Refuse -> "refuse"
    Stale(offset, body) ->
      "stale(" <> int.to_string(offset) <> ", " <> string.inspect(body) <> ")"
    Garbage -> "garbage"
    Disconnect -> "disconnect"
    Notice(advance) -> "notice(+" <> int.to_string(advance) <> ")"
    OldNotice -> "old_notice"
    Delta -> "delta"
    Usage -> "usage"
    Tick(ms) -> "tick(" <> int.to_string(ms) <> ")"
    Retire -> "retire"
    Close -> "close"
    CancelUnsent -> "cancel_unsent"
  }
}

fn describe_awaiting(awaiting: Awaiting) -> String {
  case awaiting {
    Idle -> "nothing"
    Opening(id, window) ->
      window_name(window) <> " request " <> int.to_string(id)
    Fragment(id, transfer, index) ->
      "credit "
      <> int.to_string(id)
      <> " for "
      <> transfer.id
      <> "#"
      <> int.to_string(index)
    Command(id, name, _) -> name <> " request " <> int.to_string(id)
  }
}

// --- the property -----------------------------------------------------------

// Every state the rules above talk about must be reached somewhere in the
// run, or a passing property would say nothing about it.
const required = [
  "mutation sent", "waiting prompt", "waiting models", "waiting schedules",
  "waiting lookup", "waiting command sent", "waiting withdrawn",
  "unknown outcome", "deadline", "refresh", "catch-up", "deferred notice",
  "stale reply", "duplicate outcome", "request refused",
]

pub fn session_channel_keeps_its_invariants_over_generated_schedules_test() {
  let reached =
    int.range(from: 1, to: 501, with: set.new(), run: fn(reached, seed_value) {
      case check(seed_value) {
        Ok(found) -> set.union(reached, found)
        // EUnit clips a long panic message, so the whole report also goes
        // to standard error, which EUnit does not capture.
        Error(report) -> {
          io.println_error(report)
          panic as report
        }
      }
    })
  let missing = list.filter(required, fn(what) { !set.contains(reached, what) })
  assert missing == [] as "the generated schedules never reached every state"
}

@external(erlang, "effects_test_ffi", "socket_on")
fn socket_on(owner: Subject(Dynamic)) -> connection.Connection
