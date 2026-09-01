//// A cancellation-transparent wrapper around one provider stream.
////
//// `prepare` returns a minimal custodian while its guard remains parked. Once
//// the caller has published that owner, the begin permit lets the guard adopt
//// an observer and the inner stream before starting either one. The guard
//// remains the inner request's direct consumer, while the second process runs
//// only the synchronous observer callback. This continuity is the important
//// part: a guard crash cannot discard the inner `StreamHandle`, and an
//// observer crash cannot erase the witness that still owns cancellation.
////
//// Explicit cancellation enters through the guard. It is handed to the inner
//// owner, then the guard waits one fixed grace for the owner-authored
//// terminal. The grace belongs to the cancelling state rather than to a
//// scheduled message, so a stream of late deltas cannot extend teardown
//// indefinitely. If no terminal arrives, the guard reports
//// `CancellationUnconfirmed`; the custodian nevertheless remains alive until
//// the guard, observer, and inner owner drain. Its public pid is therefore a
//// transitive teardown acknowledgement rather than another working actor.
//// The synchronous `wrap` facade waits only until the inner owner is adopted,
//// preserving the older promise that cancellation is usable when it returns.
////
//// ## The guard is a `weft/state_machine`
////
//// `Parked → Forwarding → Cancelling → Proving*`. `Parked` is the wait for
//// the begin permit; `Forwarding` and `Cancelling` are the two ways a stream
//// can be live; and the three `Proving` states are the ways this relay ends —
//// `ProvingTerminal` holds the terminal the observer has already seen,
//// `ProvingFailure` bounds the drain wait after the relay's own worker
//// failed, and `Proving` waits out an answer that has already been sent, or
//// deliberately withheld. Those six are the `Phase` type, the machine's
//// *state*. Its *data* is `Awaiting` before the permit and `Relaying` after
//// it, which is what keeps the parked guard from carrying a stream-shaped
//// record full of nothing.
////
//// The split is what makes both of the relay's deadlines structural rather
//// than armed and re-checked by hand. The cancellation grace is a **state
//// timeout** on `Cancelling`, so it dies with the state that armed it and no
//// settle site has to remember to cancel a timer; every step that keeps the
//// machine cancelling is a `keep` or a transition to the same state, neither
//// of which restarts it, which is precisely the "one fixed proof deadline"
//// the protocol requires of a boundary being flooded with late deltas. The
//// request deadline is an **event timeout**, re-armed by each forwarding step
//// that leaves the guard waiting on the inner stream, so it measures the
//// quiet before the next provider event exactly as the old per-receive
//// timeout did.
////
//// ## The permit widens the guard's mailbox
////
//// A parked guard can hear three things: the begin permit, a cancellation,
//// and its consumer's death. The stream's own channels — the inner events
//// subject, the observer's acknowledgement, the observer and drain monitors —
//// do not exist yet, because each is created by the work the permit
//// authorises, in this process. So `Parked` selects the three, and the same
//// step that transitions to `Forwarding` or `Cancelling` replaces the
//// selector with the full relay one (`state_machine.with_selector`). The
//// permit's subject is deliberately dropped on the way through: one permit is
//// granted per prepared stream, and a second could only be noise.
////
//// ## Why observation is data rather than a sub-state
////
//// One event is with the observer at a time, and inner events that arrive
//// behind it wait. weft's `postpone` is the usual way to write that, but it
//// replays only on a change of *state*, and a change of state out of
//// `Cancelling` would void the grace this module is required to keep fixed.
//// So the outstanding observation and the events queued behind it live in
//// `Relay`, where they can move without disturbing a deadline.
////
//// ## Why the inner owner is monitored directly
////
//// `stream.watch_drain` returns an opaque witness whose monitor cannot be
//// folded into a selector, and a handler that blocked in `await_drain` would
//// stop the guard serving cancellation. The guard therefore installs the
//// monitor itself, before `begin` for the same reason `watch_drain` insists
//// on it: a monitor installed after the owner has exited can report only
//// `noproc` and cannot tell drain from lost proof.

import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import provider/custodian
import provider/stream
import runtime/effects
import weft/state_machine as sm

const start_timeout_ms = 5000

const cancel_grace_ms = 1500

/// The guard's cooperative stop capability, held by its custodian.
///
/// One variant, because one thing can be asked of a guard from outside: the
/// cancellation grace that used to arrive on this subject is now the
/// cancelling state's own timeout.
type Control {
  Cancel
}

type BeginPermit {
  BeginPermit(owner: custodian.Custodian, acknowledged: Subject(Nil))
}

/// The invariants of one relay, carried into the guard process so that the
/// parked state holds what the permit will need rather than eight positional
/// arguments' worth of it.
type Startup {
  Startup(
    surface: effects.ProviderSurface,
    spec: effects.RequestSpec,
    observe: fn(stream.StreamEvent) -> Nil,
    consumer: Pid,
    outer: Subject(stream.StreamEvent),
  )
}

type ObserverMessage {
  Observe(stream.StreamEvent, acknowledged: Subject(Nil))
}

type ObserverEvent {
  ObserverCommand(ObserverMessage)
  ObserverCreatorDown(process.Down)
}

/// The observer process as the guard addresses it: the subject events are
/// handed over on, and the monitor that reports its death.
type Observer {
  Observer(control: Subject(ObserverMessage), monitor: Monitor)
}

/// Every event the guard machine handles.
///
/// The two deadlines are separate messages rather than one, because they mean
/// different things to a reader: `CancelExpired` is an owner that never
/// answered a cancellation, `DrainExpired` is an owner that never retired.
type Msg {
  /// The caller published the custodian and released the guard.
  Begin(permit: BeginPermit)

  /// One event from the inner provider stream.
  Inner(event: stream.StreamEvent)

  /// The observer finished the event it was handed.
  Observed

  /// The custodian asked this worker to stop.
  CancelRequested

  /// The cancellation grace elapsed with no owner-authored terminal.
  CancelExpired

  /// The bounded drain wait after a worker failure elapsed.
  DrainExpired

  /// No inner event arrived within the request deadline.
  RequestExpired

  /// The consumer this stream exists for died.
  ConsumerDown

  /// The observer process died.
  ObserverDown

  /// The inner owner exited, carrying its proof or the loss of it.
  InnerRetired(proof: DrainProof)
}

/// What an inner owner's exit proved.
///
/// A transitive owner speaks for work beneath it, so only a normal exit
/// carries the proof; anything else leaves the descendants unaccounted for.
type DrainProof {
  InnerDrained
  InnerProofLost
}

/// The guard's watch on the inner owner.
///
/// A monitor fires once, so an exit seen while the stream was still
/// forwarding must be remembered: a later wait for a `Down` that has already
/// been delivered would never end.
type Drain {
  WatchingInner(monitor: Monitor)
  InnerAlreadyRetired(proof: DrainProof)
}

/// What the observer is holding, and what is queued behind it.
///
/// The guard hands the observer one event at a time so that the callback sees
/// the stream in order, which is what makes "a terminal observer runs before
/// the same terminal is forwarded" a property of the queue rather than of a
/// promise.
type Observation {
  Idle
  Observing(event: stream.StreamEvent, queued: List(stream.StreamEvent))
}

/// Where the guard is in the relayed stream's lifetime: the machine's *state*
/// in `weft/state_machine`'s sense, which is what makes both of this relay's
/// deadlines structural instead of guarded by hand.
///
/// **A state's payload must not change while the machine is in it.** A state
/// timeout is cancelled by a move to a state that compares *unequal*, and a
/// `transition` to an equal value is not a move at all — so re-entering
/// `Cancelling` with a mutated payload would silently restart the grace this
/// protocol fixes, and re-entering it with an equal one is a no-op that looks
/// like a move. Only `ProvingTerminal` carries anything, and it is fixed at
/// the moment that state is entered. Everything that moves per event is in
/// `Data`.
type Phase {
  /// The custodian has been published and the guard is waiting for the permit
  /// that releases it. Nothing has been started, so a cancellation or a dead
  /// consumer ends the guard here with nothing to tear down.
  Parked

  /// The inner stream is running. Entering this state arms the request
  /// deadline, and every step that leaves the guard waiting on the stream
  /// arms it again.
  Forwarding

  /// Cancellation has been handed to the inner owner. Entering this state
  /// arms the one grace the owner has to answer with a terminal.
  Cancelling

  /// The relay's own worker failed and the inner owner has been cancelled.
  /// Entering this state arms the bounded wait for its drain.
  ProvingFailure

  /// The relay's answer has been sent, or deliberately withheld, and only the
  /// inner owner's exit is still outstanding.
  Proving

  /// The terminal the observer has already seen, held until the inner owner's
  /// exit proves the subtree drained.
  ProvingTerminal(event: stream.StreamEvent)
}

/// Everything the guard carries *across* states.
///
/// Two variants rather than one record with empty fields: before the permit
/// there is no stream, no observer and no drain to watch, and a parked guard
/// holding `None` in five places would be a record inviting each reader to
/// re-derive which phase it is in. The transition that opens the stream is
/// the same expression that replaces `Awaiting` with `Relaying`, so the two
/// halves cannot drift apart.
///
/// The split from `Phase` is weft's, and it is load-bearing rather than tidy:
/// data may change on every event without disturbing a state timeout, while a
/// change of state cancels one. So the outstanding observation, the queue
/// behind it and the inner owner's drain proof all live here — putting any of
/// them in the state would make an ordinary late delta cancel the
/// cancellation grace.
type Data {
  /// Parked: the permit has not arrived, so this is what granting it will
  /// need — including the two channels the parked selector already covers.
  Awaiting(
    startup: Startup,
    control: Subject(Control),
    consumer_monitor: Monitor,
  )

  /// The stream exists and the guard is relaying it.
  Relaying(relay: Relay)
}

/// One live relayed stream.
type Relay {
  Relay(
    inner: stream.StreamHandle,
    observer: Subject(ObserverMessage),
    observations: Subject(Nil),
    outer: Subject(stream.StreamEvent),
    consumer: Pid,
    request_timeout_ms: Int,
    drain: Drain,
    observation: Observation,
  )
}

// This private type gives each liveness check the meaning needed by the relay:
// whether forwarding remains useful, rather than merely exposing a raw Boolean.
type ConsumerLiveness {
  ConsumerAlive
  ConsumerGone
}

/// Wraps one provider request with a synchronous event observer.
///
/// The observer must return promptly and must not receive from the stream.
/// Cancellation remains owned by the inner request owner; this wrapper carries
/// its capability and terminal acknowledgement across the composition boundary.
///
/// ## Examples
///
/// ```gleam
/// let wrapped = provider_relay.wrap(surface, request, fn(event) {
///   summaries.record(event)
/// })
/// // wrapped.owner stays alive until the inner provider subtree drains.
/// ```
///
pub fn wrap(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
  observe: fn(stream.StreamEvent) -> Nil,
) -> stream.StreamHandle {
  prepare(surface, spec, observe)
  |> stream.start_prepared
}

/// Prepares an observed provider request without starting its inner stream.
///
/// The returned owner covers the relay guard and observer. A caller must
/// publish that owner before invoking `begin`, which in turn lets the guard
/// prepare, adopt, and only then start the inner provider request.
///
/// ## Examples
///
/// ```gleam
/// let prepared = provider_relay.prepare(surface, request, observe)
/// let handle = stream.start_prepared(prepared)
/// ```
///
pub fn prepare(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
  observe: fn(stream.StreamEvent) -> Nil,
) -> stream.PreparedStream {
  let consumer = process.self()
  let outer = process.new_subject()
  let startup = Startup(surface:, spec:, observe:, consumer:, outer:)
  case start_guard(startup) {
    Ok(started) -> published(started, outer, consumer)

    // A guard that died on the way up and one that never answered are
    // different facts, and the caller reads them as the in-band failure the
    // old handshake reported for each.
    Error(actor.InitTimeout) ->
      failed_prepared(outer, "provider relay guard did not start in time")

    Error(actor.InitFailed(_reason)) | Error(actor.InitExited(_reason)) ->
      failed_prepared(outer, "provider relay guard exited")
  }
}

// Starts the guard machine, parked.
//
// **Unlinked on purpose.** A weft machine is normally linked to whatever
// started it, and this one is started by the very consumer it serves: a
// crashing guard must reach that consumer as the custodian's monitored `Down`,
// never as an exit signal that kills it. The consumer's own death reaches the
// guard the same way, through the monitor installed below.
//
// The initialiser does nothing but create the guard's two channels and watch
// its consumer, so `start`'s timeout is the old start bound rather than a
// deadline over the provider's startup: everything that can block waits for
// the permit, in the machine's first state.
fn start_guard(
  startup: Startup,
) -> Result(
  sm.Started(#(Subject(Control), Subject(BeginPermit))),
  sm.StartError,
) {
  sm.new_with_initialiser(start_timeout_ms, fn(_default) {
    let control = process.new_subject()
    let begin = process.new_subject()
    let consumer_monitor = process.monitor(startup.consumer)
    let parked =
      process.new_selector()
      |> process.select_map(begin, Begin)
      |> process.select_map(control, fn(_cancel) { CancelRequested })
      |> process.select_specific_monitor(consumer_monitor, fn(_down) {
        ConsumerDown
      })
    sm.initialised(Parked, Awaiting(startup:, control:, consumer_monitor:))
    |> sm.selecting(parked)
    |> sm.returning(#(control, begin))
    |> Ok
  })
  |> sm.on_event(handle)
  |> sm.on_enter(entered)
  |> sm.unlinked
  |> sm.start
}

// Wraps a started guard in the public custodian and the prepared handle.
fn published(
  started: sm.Started(#(Subject(Control), Subject(BeginPermit))),
  outer: Subject(stream.StreamEvent),
  consumer: Pid,
) -> stream.PreparedStream {
  let #(control, begin) = started.data
  let owner = custodian.start(started.pid, control, Cancel, consumer)
  stream.PreparedStream(
    handle: stream.owned(
      events: outer,
      owner: custodian.owner(owner),
      cancel: fn() { custodian.cancel(owner) },
    ),
    begin: fn() { begin_guard(begin, owner, started.pid) },
  )
}

// The compatibility `request` facade returns the prepared handle immediately
// after invoking this callback. Waiting for the guard's acknowledgement keeps
// that return equivalent to the old contract: an immediate cancellation can
// already reach the adopted inner stream.
fn begin_guard(
  begin: Subject(BeginPermit),
  owner: custodian.Custodian,
  guard: Pid,
) -> Nil {
  let acknowledged = process.new_subject()
  let monitor = process.monitor(guard)
  process.send(begin, BeginPermit(owner:, acknowledged:))
  let _started =
    process.new_selector()
    |> process.select_map(acknowledged, fn(_nil) { Nil })
    |> process.select_specific_monitor(monitor, fn(_down) { Nil })
    |> process.selector_receive(within: start_timeout_ms)
  process.demonitor_process(monitor)
  Nil
}

fn failed_prepared(
  outer: Subject(stream.StreamEvent),
  reason: String,
) -> stream.PreparedStream {
  process.send(
    outer,
    stream.Failed(error: stream.TransportFailed(reason: reason)),
  )
  stream.PreparedStream(
    handle: stream.immediate(events: outer, cancel: fn() { Nil }),
    begin: fn() { Nil },
  )
}

/// One event, in one state, against the data that state holds.
///
/// Writing the matrix out is the point of the port: adding a state, a data
/// variant or a message makes the compiler name every combination nobody has
/// thought about, where the hand-rolled guard answered several of them with a
/// re-check the author had to remember — a `CancelExpired` arm in the
/// forwarding loop whose only job was to notice it was stale, and a deadline
/// that had to be scheduled at three separate call sites.
fn handle(phase: Phase, data: Data, message: Msg) -> sm.Next(Phase, Data, Msg) {
  case phase, data, message {
    // The custodian is published, so the observer and the inner stream can be
    // started and adopted under it.
    Parked, Awaiting(startup:, control:, consumer_monitor:), Begin(permit:) ->
      admit(startup, control, consumer_monitor, permit)

    // Cancellation or consumer death before the permit ends the guard where
    // it stands. Nothing has been started, so there is nothing to tear down
    // and nothing to say.
    Parked, Awaiting(..), CancelRequested
    | Parked, Awaiting(..), ConsumerDown
    -> sm.stop()

    // Unreachable by construction: a parked guard selects the permit, the
    // control subject and its consumer's monitor, and nothing else exists to
    // send it anything. The stream's channels are created by the permit.
    Parked, Awaiting(..), Inner(..)
    | Parked, Awaiting(..), Observed
    | Parked, Awaiting(..), CancelExpired
    | Parked, Awaiting(..), DrainExpired
    | Parked, Awaiting(..), RequestExpired
    | Parked, Awaiting(..), ObserverDown
    | Parked, Awaiting(..), InnerRetired(..)
    -> sm.keep(data)

    // An inner event joins the observation queue in every live state; the
    // observer sees the stream in order and the guard forwards nothing it has
    // not seen first.
    Forwarding, Relaying(relay:), Inner(event:)
    | Cancelling, Relaying(relay:), Inner(event:)
    -> sm.keep(Relaying(observe(relay, event)))

    Forwarding, Relaying(relay:), Observed -> forwarded(relay)

    // Cancellation goes inward first, and the transition is what arms the one
    // grace the owner has to answer it.
    Forwarding, Relaying(relay:), CancelRequested -> {
      stream.cancel(relay.inner)
      sm.transition(to: Cancelling, data: data)
    }

    // A worker that cannot finish the job and a stream that has gone quiet
    // are the same fact to the inner owner: cancel it and wait, bounded, for
    // the proof.
    Forwarding, Relaying(relay:), RequestExpired
    | Forwarding, Relaying(relay:), ObserverDown
    -> fail_and_drain(relay)

    // Consumer death closes the observation boundary before cancellation can
    // produce a terminal event. This keeps wrapper-local side effects, such as
    // summary recording, from outliving the consumer that requested them.
    Forwarding, Relaying(relay:), ConsumerDown
    | Cancelling, Relaying(relay:), ConsumerDown
    -> abandon(relay)

    // The owner exited while its events were still being relayed. A monitor
    // fires once, so the proof is recorded rather than acted on: a later wait
    // for a `Down` already delivered would never end.
    //
    // The request deadline is re-armed because this event cancelled it, as
    // every event does, and a stream whose owner has gone is exactly the one
    // that must not be waited on forever. The old loop never saw this Down at
    // all and kept the deadline it was already inside.
    Forwarding, Relaying(relay:), InnerRetired(proof:) ->
      keep_forwarding(Relay(..relay, drain: InnerAlreadyRetired(proof:)))

    // The cancellation grace is a state timeout and no event disturbs it, so
    // the cancelling side records the same proof and nothing else.
    Cancelling, Relaying(relay:), InnerRetired(proof:) ->
      sm.keep(Relaying(Relay(..relay, drain: InnerAlreadyRetired(proof:))))

    Cancelling, Relaying(relay:), Observed -> cancelling_observed(relay)

    // Idempotent, and deliberately a `keep`: a second cancellation must not
    // restart the grace the first one armed.
    Cancelling, Relaying(..), CancelRequested -> sm.keep(data)

    // The owner neither answered the cancellation nor died inside its grace,
    // and an observer that died mid-cancellation can no longer let a terminal
    // past. Only the request owner may claim that cancellation won its race,
    // so this boundary says exactly that it does not know.
    Cancelling, Relaying(relay:), CancelExpired
    | Cancelling, Relaying(relay:), ObserverDown
    -> unconfirmed(relay)

    // The relay's own answer is sent; only the subtree's exit is outstanding.
    ProvingFailure, Relaying(relay:), InnerRetired(proof: InnerDrained) -> {
      process.send(
        relay.outer,
        stream.Failed(error: stream.TransportFailed(
          reason: "provider relay worker stopped before a terminal response",
        )),
      )
      sm.stop()
    }

    ProvingFailure, Relaying(relay:), InnerRetired(proof: InnerProofLost) -> {
      process.send(relay.outer, stream.Failed(error: stream.DrainProofLost))
      lost_proof()
    }

    // The bounded wait is spent. The unconfirmed answer goes out now, and the
    // guard still waits — without a deadline — for the exit that its custodian
    // is waiting for too.
    ProvingFailure, Relaying(relay:), DrainExpired -> {
      process.send(
        relay.outer,
        stream.Failed(error: stream.CancellationUnconfirmed),
      )
      sm.transition(to: Proving, data: data)
    }

    Proving, Relaying(..), InnerRetired(proof: InnerDrained) -> sm.stop()
    Proving, Relaying(..), InnerRetired(proof: InnerProofLost) -> lost_proof()

    // A terminal is forwarded only once the subtree it came from has drained,
    // and never at all when the proof of that drain was lost.
    ProvingTerminal(event:), Relaying(relay:), InnerRetired(proof: InnerDrained)
    -> {
      deliver(relay, event)
      sm.stop()
    }

    ProvingTerminal(..), Relaying(..), InnerRetired(proof: InnerProofLost) ->
      lost_proof()

    // Unreachable by construction. The permit's subject leaves the selector
    // with the park; the request deadline is an event timeout armed only while
    // forwarding, and the event that leaves that state cancels it; each drain
    // deadline is a state timeout on the state that armed it, so a fire that
    // raced the move out is dropped by weft's timer book before it reaches
    // this handler. The arms exist because the matrix is exhaustive, not
    // because the cases can arise.
    Forwarding, Relaying(..), Begin(..)
    | Forwarding, Relaying(..), CancelExpired
    | Forwarding, Relaying(..), DrainExpired
    | Cancelling, Relaying(..), Begin(..)
    | Cancelling, Relaying(..), RequestExpired
    | Cancelling, Relaying(..), DrainExpired
    | ProvingFailure, Relaying(..), Begin(..)
    | ProvingFailure, Relaying(..), CancelExpired
    | ProvingFailure, Relaying(..), RequestExpired
    | Proving, Relaying(..), Begin(..)
    | Proving, Relaying(..), CancelExpired
    | Proving, Relaying(..), DrainExpired
    | Proving, Relaying(..), RequestExpired
    | ProvingTerminal(..), Relaying(..), Begin(..)
    | ProvingTerminal(..), Relaying(..), CancelExpired
    | ProvingTerminal(..), Relaying(..), DrainExpired
    | ProvingTerminal(..), Relaying(..), RequestExpired
    -> sm.keep(data)

    // Everything a settled relay can still be told. Late deltas, an
    // acknowledgement for an observation nobody is waiting on, a repeated
    // cancellation, and the deaths of the two processes this guard no longer
    // needs: the answer is already decided, and the only thing still
    // outstanding is the inner owner's exit.
    ProvingFailure, Relaying(..), Inner(..)
    | ProvingFailure, Relaying(..), Observed
    | ProvingFailure, Relaying(..), CancelRequested
    | ProvingFailure, Relaying(..), ConsumerDown
    | ProvingFailure, Relaying(..), ObserverDown
    | Proving, Relaying(..), Inner(..)
    | Proving, Relaying(..), Observed
    | Proving, Relaying(..), CancelRequested
    | Proving, Relaying(..), ConsumerDown
    | Proving, Relaying(..), ObserverDown
    | ProvingTerminal(..), Relaying(..), Inner(..)
    | ProvingTerminal(..), Relaying(..), Observed
    | ProvingTerminal(..), Relaying(..), CancelRequested
    | ProvingTerminal(..), Relaying(..), ConsumerDown
    | ProvingTerminal(..), Relaying(..), ObserverDown
    -> sm.keep(data)

    // A state and a data variant that do not belong together. The permit's
    // step is the only thing that moves the machine off `Parked`, and it is
    // the same expression that replaces `Awaiting` with `Relaying`, so the
    // two are set together and cannot drift apart.
    Parked, Relaying(..), _message
    | Forwarding, Awaiting(..), _message
    | Cancelling, Awaiting(..), _message
    | ProvingFailure, Awaiting(..), _message
    | Proving, Awaiting(..), _message
    | ProvingTerminal(..), Awaiting(..), _message
    -> sm.keep(data)
  }
}

// Brings up the observer under a granted permit.
fn admit(
  startup: Startup,
  control: Subject(Control),
  consumer_monitor: Monitor,
  permit: BeginPermit,
) -> sm.Next(Phase, Data, Msg) {
  let BeginPermit(owner:, acknowledged:) = permit

  // Publish the observer before the inner request begins. Cancellation can
  // reach the public custodian as soon as `wrap` returns; if it wins this
  // startup race, an owner-authored terminal must still pass through the
  // observer before it reaches the caller.
  let #(observer_pid, observer) =
    start_observer(startup.observe, process.self())
  case custodian.adopt_leaf(owner, observer_pid, fn() { Nil }) {
    False -> {
      // Rejection leaves startup with the guard. Stopping normally drops the
      // creator monitor, so the still-parked observer follows without
      // manufacturing an abnormal child exit.
      process.send(acknowledged, Nil)
      sm.stop()
    }
    True ->
      open_inner(
        startup,
        control,
        consumer_monitor,
        observer,
        owner,
        acknowledged,
      )
  }
}

// Prepares the inner request, publishes its owner, and hands the machine the
// stream it will spend the rest of its life on.
//
// The events subject the provider surface creates belongs to this process,
// which is the machine, and cannot be named any earlier than this: that is
// what `with_selector` is for. The drain monitor is installed between
// preparation and adoption, before any path can call `begin`, because an
// owner watched only after it exited reports `noproc` — which proves death
// and cannot prove clean drain.
fn open_inner(
  startup: Startup,
  control: Subject(Control),
  consumer_monitor: Monitor,
  observer: Observer,
  owner: custodian.Custodian,
  acknowledged: Subject(Nil),
) -> sm.Next(Phase, Data, Msg) {
  let stream.PreparedStream(handle: inner, begin: begin_inner) =
    effects.prepare_provider(startup.surface, startup.spec)
  let drain = watch_inner(inner)
  let observations = process.new_subject()
  let relay =
    Relay(
      inner:,
      observer: observer.control,
      observations:,
      outer: startup.outer,
      consumer: startup.consumer,
      request_timeout_ms: effects.provider_timeout_ms(startup.surface) + 100,
      drain:,
      observation: Idle,
    )
  let selector =
    relay_selector(
      inner,
      control,
      observations,
      consumer_monitor,
      observer.monitor,
      drain,
    )

  case custodian.adopt(owner, inner.owner, inner.cancel) {
    False -> {
      process.send(acknowledged, Nil)
      stream.cancel(inner)

      // Start-time cancellation enters the ordinary cancelling state, so it
      // gets that state's single deadline rather than one of its own. An idle
      // timeout would let each late delta silently renew the grace period.
      sm.transition(to: Cancelling, data: Relaying(relay))
      |> sm.with_selector(selector)
    }
    True -> {
      begin_inner()
      process.send(acknowledged, Nil)
      sm.transition(to: Forwarding, data: Relaying(relay))
      |> sm.with_selector(selector)
    }
  }
}

// Every source a live guard selects on. Four of them — the inner stream, the
// observer's acknowledgement, the observer's monitor and the inner owner's —
// exist only because the permit arrived, which is why this selector replaces
// the parked one rather than being built beside it. The permit's own subject
// is not carried over: one is granted per prepared stream.
fn relay_selector(
  inner: stream.StreamHandle,
  control: Subject(Control),
  observations: Subject(Nil),
  consumer_monitor: Monitor,
  observer_monitor: Monitor,
  drain: Drain,
) -> process.Selector(Msg) {
  process.new_selector()
  |> process.select_map(inner.events, Inner)
  |> process.select_map(control, fn(_cancel) { CancelRequested })
  |> process.select_map(observations, fn(_acknowledged) { Observed })
  |> process.select_specific_monitor(consumer_monitor, fn(_down) {
    ConsumerDown
  })
  |> process.select_specific_monitor(observer_monitor, fn(_down) {
    ObserverDown
  })
  |> select_drain(drain)
}

fn select_drain(
  selector: process.Selector(Msg),
  drain: Drain,
) -> process.Selector(Msg) {
  case drain {
    WatchingInner(monitor:) ->
      process.select_specific_monitor(selector, monitor, fn(down) {
        InnerRetired(proof: drain_proof(down))
      })

    // An immediate handle owns nothing asynchronous, so there is no exit to
    // watch for and nothing to add to the selector.
    InnerAlreadyRetired(..) -> selector
  }
}

// Installs the original drain monitor, or records that there is nothing to
// wait for. `stream.watch_drain` answers `Drained` for an ownerless handle
// without waiting, and so does this.
fn watch_inner(inner: stream.StreamHandle) -> Drain {
  case inner.owner {
    Some(owner) -> WatchingInner(monitor: process.monitor(owner))
    None -> InnerAlreadyRetired(proof: InnerDrained)
  }
}

// A transitive owner speaks for work beneath it. Only its normal Down permits
// this relay to retire normally; otherwise the relay must preserve the lost
// proof as an abnormal exit for its own custodian.
fn drain_proof(down: process.Down) -> DrainProof {
  case down {
    process.ProcessDown(reason:, ..) ->
      case reason {
        process.Normal -> InnerDrained
        process.Killed | process.Abnormal(_) -> InnerProofLost
      }
    process.PortDown(..) -> InnerProofLost
  }
}

fn start_observer(
  observe: fn(stream.StreamEvent) -> Nil,
  creator: Pid,
) -> #(Pid, Observer) {
  let ready = process.new_subject()
  let observer =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      process.send(ready, control)
      observer_loop(control, observe, process.monitor(creator))
    })
  let control = process.receive_forever(ready)
  #(observer, Observer(control:, monitor: process.monitor(observer)))
}

fn observer_loop(
  control: Subject(ObserverMessage),
  observe: fn(stream.StreamEvent) -> Nil,
  creator_monitor: Monitor,
) -> Nil {
  let event =
    process.new_selector()
    |> process.select_map(control, ObserverCommand)
    |> process.select_specific_monitor(creator_monitor, ObserverCreatorDown)
    |> process.selector_receive_forever()
  case event {
    ObserverCommand(Observe(event, acknowledged:)) -> {
      observe(event)
      process.send(acknowledged, Nil)
      observer_loop(control, observe, creator_monitor)
    }

    // Before adoption, the guard is the observer's only reachable owner.
    // After adoption, the same edge closes the leaf promptly while the public
    // custodian still adjudicates whether the guard itself drained normally.
    ObserverCreatorDown(_down) -> process.demonitor_process(creator_monitor)
  }
}

/// The deadline each state owns, armed by every path into it — including the
/// initial entry, which weft makes for the starting state on the far side of
/// the start acknowledgement.
///
/// Arming here rather than at the transition sites is what deletes the
/// bookkeeping the hand-rolled guard needed: three call sites scheduled the
/// cancellation grace with `process.send_after`, and the forwarding loop
/// carried an arm whose only job was to notice a fire it no longer cared
/// about. A state timeout is cancelled by the move out of the state that
/// armed it, so the guards are deleted rather than relocated.
///
/// The proving states additionally inject the retirement they are waiting for
/// when there is nothing to wait for: an immediate handle owns no
/// asynchronous work, and an owner that exited while the stream was still
/// forwarding has already delivered its only `Down`.
fn entered(_from: Phase, to: Phase, data: Data) -> sm.Enter(Phase, Data, Msg) {
  case to, data {
    Forwarding, Relaying(relay:) ->
      sm.keep(data)
      |> sm.with_event_timeout(
        after: relay.request_timeout_ms,
        sending: RequestExpired,
      )

    Cancelling, Relaying(..) ->
      sm.keep(data)
      |> sm.with_state_timeout(after: cancel_grace_ms, sending: CancelExpired)

    ProvingFailure, Relaying(relay:) ->
      already_retired(relay)
      |> sm.with_state_timeout(after: cancel_grace_ms, sending: DrainExpired)

    Proving, Relaying(relay:) | ProvingTerminal(..), Relaying(relay:) ->
      already_retired(relay)

    // Parking arms nothing: a guard nobody has released is waiting on its
    // caller, and this protocol puts no deadline on that.
    Parked, Awaiting(..) -> sm.keep(data)

    // A state and a data variant that do not belong together, for the reason
    // the event matrix gives.
    Parked, Relaying(..)
    | Forwarding, Awaiting(..)
    | Cancelling, Awaiting(..)
    | ProvingFailure, Awaiting(..)
    | Proving, Awaiting(..)
    | ProvingTerminal(..), Awaiting(..)
    -> sm.keep(data)
  }
}

fn already_retired(relay: Relay) -> sm.Enter(Phase, Data, Msg) {
  case relay.drain {
    WatchingInner(..) -> sm.keep(Relaying(relay))
    InnerAlreadyRetired(proof:) ->
      sm.keep(Relaying(relay)) |> sm.then_handle(InnerRetired(proof:))
  }
}

// Hands one event to the observer, or queues it behind the one already there.
//
// The queue is what a `postpone` would be in a module with no fixed deadline
// to protect: weft replays a postponed event only on a change of state, and
// the change of state that would replay it is exactly the one that would void
// the cancellation grace.
fn observe(relay: Relay, event: stream.StreamEvent) -> Relay {
  case relay.observation {
    Idle -> {
      process.send(
        relay.observer,
        Observe(event, acknowledged: relay.observations),
      )
      Relay(..relay, observation: Observing(event:, queued: []))
    }

    Observing(event: outstanding, queued:) ->
      Relay(
        ..relay,
        observation: Observing(
          event: outstanding,
          queued: list.append(queued, [event]),
        ),
      )
  }
}

// Dispatches the next queued event, or leaves the observer idle.
fn advance(relay: Relay, queued: List(stream.StreamEvent)) -> Relay {
  case queued {
    [] -> Relay(..relay, observation: Idle)
    [next, ..rest] -> {
      process.send(
        relay.observer,
        Observe(next, acknowledged: relay.observations),
      )
      Relay(..relay, observation: Observing(event: next, queued: rest))
    }
  }
}

// The observer finished an event the guard is still forwarding.
fn forwarded(relay: Relay) -> sm.Next(Phase, Data, Msg) {
  case relay.observation {
    // Unreachable: an acknowledgement answers an observation, and one is
    // outstanding for as long as the guard can be told about it.
    Idle -> sm.keep(Relaying(relay))

    Observing(event:, queued:) -> forward_observed(relay, event, queued)
  }
}

// Decide liveness and event shape together. Besides keeping the state
// transition visible in one place, this prevents another liveness check from
// enclosing the entire event protocol and hiding its terminal arm.
fn forward_observed(
  relay: Relay,
  event: stream.StreamEvent,
  queued: List(stream.StreamEvent),
) -> sm.Next(Phase, Data, Msg) {
  case consumer_liveness(relay.consumer), event {
    ConsumerGone, stream.Delta(..)
    | ConsumerGone, stream.Settled(..)
    | ConsumerGone, stream.Failed(..)
    -> abandon(relay)

    ConsumerAlive, stream.Delta(..) -> {
      process.send(relay.outer, event)
      keep_forwarding(advance(relay, queued))
    }

    // A terminal ends the relay, so nothing behind it in the queue is ever
    // handed over: the guard is now waiting on the subtree, not on the
    // stream.
    ConsumerAlive, stream.Settled(..) | ConsumerAlive, stream.Failed(..) ->
      sm.transition(
        to: ProvingTerminal(event:),
        data: Relaying(Relay(..relay, observation: Idle)),
      )
  }
}

// The observer finished an event that arrived after cancellation.
//
// Every arm here is a `keep` or a transition out, never a transition back
// into `Cancelling`: the grace is that state's own timeout, and re-entering
// the state would restart it, which is the whole of what a flood of late
// deltas would otherwise buy the inner owner.
fn cancelling_observed(relay: Relay) -> sm.Next(Phase, Data, Msg) {
  case relay.observation {
    // Unreachable, for the reason `forwarded` gives.
    Idle -> sm.keep(Relaying(relay))

    Observing(event:, queued:) -> cancelling_event(relay, event, queued)
  }
}

fn cancelling_event(
  relay: Relay,
  event: stream.StreamEvent,
  queued: List(stream.StreamEvent),
) -> sm.Next(Phase, Data, Msg) {
  case event {
    // A delta after cancellation is observed and discarded: the consumer is
    // owed one terminal, and this is not it.
    stream.Delta(..) -> sm.keep(Relaying(advance(relay, queued)))

    stream.Settled(..) | stream.Failed(..) ->
      sm.transition(
        to: ProvingTerminal(event:),
        data: Relaying(Relay(..relay, observation: Idle)),
      )
  }
}

// Stays in `Forwarding`, re-arming the request deadline when the guard is
// once again waiting on the inner stream rather than on the observer.
//
// The old loop measured the same interval: an unbounded receive while an
// observation was outstanding, and the request timeout on the receive that
// followed it.
fn keep_forwarding(relay: Relay) -> sm.Next(Phase, Data, Msg) {
  case relay.observation {
    Idle ->
      sm.keep(Relaying(relay))
      |> sm.with_event_timeout(
        after: relay.request_timeout_ms,
        sending: RequestExpired,
      )

    Observing(..) -> sm.keep(Relaying(relay))
  }
}

// The relay's own worker failed. The inner owner is cancelled and the guard
// waits, bounded, for the proof that it stopped.
fn fail_and_drain(relay: Relay) -> sm.Next(Phase, Data, Msg) {
  stream.cancel(relay.inner)
  sm.transition(to: ProvingFailure, data: Relaying(relay))
}

// Nobody is left to tell. The inner owner is cancelled and the guard waits
// for its exit, emitting nothing at all.
fn abandon(relay: Relay) -> sm.Next(Phase, Data, Msg) {
  stream.cancel(relay.inner)
  sm.transition(to: Proving, data: Relaying(relay))
}

// Cancellation crossed this boundary and was never acknowledged.
fn unconfirmed(relay: Relay) -> sm.Next(Phase, Data, Msg) {
  process.send(
    relay.outer,
    stream.Failed(error: stream.CancellationUnconfirmed),
  )
  stream.cancel(relay.inner)
  sm.transition(to: Proving, data: Relaying(relay))
}

// Retiring normally here would let the outer custodian certify a subtree
// whose transitive owner died abnormally, so the guard carries the loss into
// its own exit reason instead.
fn lost_proof() -> sm.Next(Phase, Data, Msg) {
  sm.stop_abnormal("the inner provider owner exited without proof of drain")
}

// Forwards a terminal the observer has already seen.
//
// The liveness check is the same one the forwarding path made before the
// drain wait, asked again on the far side of it: the consumer may have died
// while the subtree was retiring, and a wrapper must not be the thing that
// keeps its answer alive.
fn deliver(relay: Relay, event: stream.StreamEvent) -> Nil {
  case consumer_liveness(relay.consumer) {
    ConsumerAlive -> process.send(relay.outer, event)
    ConsumerGone -> Nil
  }
}

fn consumer_liveness(consumer: Pid) -> ConsumerLiveness {
  case process.is_alive(consumer) {
    True -> ConsumerAlive
    False -> ConsumerGone
  }
}
