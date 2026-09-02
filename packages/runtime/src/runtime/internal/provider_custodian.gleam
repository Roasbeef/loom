//// The runtime-owned provider boundary.
////
//// An immediate `ProviderSurface.request` returns a live `StreamHandle`.
//// Calling an asynchronous implementation through that shape leaves one bad
//// instruction window between the return and publication of the handle to the
//// incarnation reaper. If the worker dies there, recovery can begin while the
//// just-started request is still cancelling. Production therefore supplies a
//// `PreparedProviderSurface`, while the immediate shape remains for in-memory
//// fakes which own no external work.
////
//// `prepare` closes the window at both composition layers. A minimal custodian
//// is published while the request worker is parked. Only after the reaper
//// accepts that witness does `begin` let the worker prepare and adopt the
//// inner owner, then grant the inner begin permit.
//// The custodian executes no provider callback: if the worker dies, it retains
//// and cancels the adopted inner handle and retires only after the inner owner
//// does. The worker is linked to the provider effect because they are one
//// failure domain: an unexpected surface crash must fault the effect and let
//// recovery run behind the custodian, not become a fabricated provider
//// response. The whole boundary is a Gleam process protocol.
////
//// ## The request worker is a `weft/state_machine`
////
//// `Parked → Forwarding → Cancelling → Draining`, four states which are the
//// four things this worker can be doing: waiting for the permit that lets it
//// call the provider at all, relaying a live stream, waiting out the one
//// grace an owner gets to answer a cancellation, and waiting for the proof
//// that the inner subtree is gone.
////
//// The park is a real state rather than a stretch of initialisation because
//// a step can replace the machine's selector. `Parked` selects two subjects
//// and nothing else — the one-way permit and the custodian's stop capability
//// — and the step that leaves it installs the selector naming the inner
//// stream, both monitors and the same stop. The inner stream's events subject
//// does not exist until the permit has arrived, and it could not have been
//// made anywhere else: a subject is delivered to the process that created it,
//// and this worker must be that stream's only consumer.
////
//// The machine's *data* is `Awaiting` before the permit and `Serving` after
//// it, so the compiler is what says a parked worker holds no request and a
//// serving one holds no startup. Everything that moves per event — the inner
//// handle, the outer subject, the consumer and its monitor, and whether the
//// inner owner has already retired — is inside `Serving`, never in the state.
//// That is what makes the cancellation grace structural: it is a **state
//// timeout** on `Cancelling`, armed by the move in and cancelled by the move
//// out, and every step that keeps the machine cancelling is a `keep`, which
//// never re-arms one. A flood of late deltas therefore cannot buy the inner
//// owner another interval.
////
//// ## Why the inner owner is monitored directly
////
//// `stream.watch_drain` returns an opaque witness whose monitor cannot be
//// folded into a selector, and a handler that blocked in `await_drain` would
//// stop the worker serving cancellation. The worker therefore installs the
//// monitor itself, before `begin` for the same reason `watch_drain` insists
//// on it: a monitor installed after the owner has exited can report only
//// `noproc`, which proves death and cannot prove clean drain.
////
//// ## The publication order
////
//// ```text
//// prepare
////   |-- start the request worker, linked and parked
////   |-- spawn unlinked custodian around that worker
////   `-- return { handle: custodian, begin }
////
//// strand runtime
////   |-- publish handle.owner to the incarnation reaper
////   `-- call begin only after the reaper acknowledges it
//// ```
////
//// This order removes the interval in which provider work has started but the
//// reaper does not yet know what to cancel. The linked
//// worker preserves the old failure semantics; the unlinked custodian
//// preserves the new drain evidence. They are separate because one PID cannot
//// both propagate a provider crash and remain alive to witness its cleanup.

import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/option.{None, Some}
import provider/custodian
import provider/stream
import runtime/effects
import weft/state_machine as sm

const cancel_grace_ms = 2000

// The worker's initialiser makes two subjects and a selector and returns, so
// this bounds a startup that does no work rather than the park, which is now
// a state the machine sits in for as long as its caller takes to publish.
const start_timeout_ms = 5000

/// A provider handle whose request worker is parked until `begin` is invoked.
///
/// Constructing the value starts no provider work. The caller first publishes
/// `handle.owner` to its restart barrier, then invokes `begin` exactly once.
pub type Prepared {
  Prepared(
    /// The immediately publishable outer stream and drain witness.
    handle: stream.StreamHandle,
    /// The one-way permit which lets the parked worker call the provider.
    begin: fn() -> Nil,
  )
}

/// The two capabilities the worker hands back to `prepare` when it starts:
/// the one-way permit, and the cooperative stop its custodian holds.
type Handles {
  Handles(start: Subject(custodian.Custodian), stop: Subject(Nil))
}

/// Everything `prepare` decided, carried into the parked worker so that the
/// permit's handler reads as one sequence rather than as four fields fished
/// out of the machine's data.
type Startup {
  Startup(
    surface: effects.ProviderSurface,
    spec: effects.RequestSpec,
    consumer: Pid,
    outer: Subject(stream.StreamEvent),
  )
}

/// Every event the request worker handles.
type Msg {
  /// The permit, carrying the custodian the worker must adopt through.
  Begin(owner: custodian.Custodian)

  /// One event from the inner provider stream.
  Inner(event: stream.StreamEvent)

  /// The custodian asked this worker to stop.
  StopRequested

  /// The consumer this stream exists for died.
  ConsumerDown

  /// The cancellation grace elapsed with no owner-authored terminal.
  CancelExpired

  /// The inner owner exited, carrying its proof or the loss of it.
  InnerRetired(proof: DrainProof)
}

/// What an inner owner's exit proved.
///
/// A transitive owner speaks for work beneath it, so only a normal exit
/// carries the proof; anything else leaves the descendants unaccounted for.
/// This is `stream.DrainOutcome` minus the deadline: the worker's wait for
/// the exit is unbounded, so `TimedOut` has no representation here.
type DrainProof {
  InnerDrained
  InnerProofLost
}

/// The worker's watch on the inner owner.
///
/// A monitor fires once, so an exit seen while the stream was still
/// forwarding must be remembered: a later wait for a `Down` that has already
/// been delivered would never end.
type Drain {
  WatchingInner(monitor: Monitor)
  InnerAlreadyRetired(proof: DrainProof)
}

/// Where the worker is in one request's lifetime: the machine's *state* in
/// `weft/state_machine`'s sense, which is what makes the cancellation grace
/// structural instead of scheduled and re-checked by hand.
///
/// **A state's payload must not change while the machine is in it.** A state
/// timeout is cancelled by a move to a state that compares *unequal*, and a
/// `transition` to an equal value is not a move at all — so a state carrying
/// anything that moves per event could silently restart the grace this
/// protocol fixes. None of these four carries anything; everything that moves
/// is in `Data`.
type Phase {
  /// No provider call has been made. The worker holds the permit and the
  /// stop capability and selects nothing else.
  Parked

  /// The inner stream is running and its events are the consumer's.
  Forwarding

  /// Cancellation has been handed to the inner owner. Entering this state
  /// asks for it and arms the one grace the owner has to answer with a
  /// terminal.
  Cancelling

  /// The consumer's answer has been sent, or deliberately withheld, and only
  /// the inner owner's exit is still outstanding.
  Draining
}

/// Everything the worker carries *across* states.
///
/// The two variants are the two halves of this worker's life, and making
/// them a type rather than a record of optional fields is what lets the
/// event matrix state — and the compiler check — that a parked worker holds
/// no request and a serving one has no startup left to do.
type Data {
  /// Before the permit: what to ask the provider for, and the stop subject
  /// the post-permit selector must go on selecting.
  Awaiting(startup: Startup, stop: Subject(Nil))

  /// After the permit: one live request.
  Serving(request: Request)
}

/// One provider request as the worker relays it.
///
/// The drain proof lives here rather than in `Phase` — recorded in whatever
/// state it arrives in and acted on in `Draining` — because putting it in the
/// state would make an owner that retired early cancel the cancellation
/// grace.
type Request {
  Request(
    inner: stream.StreamHandle,
    outer: Subject(stream.StreamEvent),
    consumer: Pid,
    consumer_monitor: Monitor,
    drain: Drain,
  )
}

// This private type gives the liveness check the meaning needed here: whether
// forwarding remains useful, rather than merely exposing a raw Boolean.
type ConsumerLiveness {
  ConsumerAlive
  ConsumerGone
}

/// Prepares a parked runtime custodian around one provider request.
///
/// This function returns only after the worker and custodian exist, but before
/// the provider surface is prepared. The returned `begin` capability completes the
/// prepare/publish/begin protocol described in the module documentation.
///
/// ## Examples
///
/// ```gleam
/// let provider_custodian.Prepared(handle:, begin:) =
///   provider_custodian.prepare(surface, request)
/// publish_to_reaper(handle)
/// begin()
/// ```
///
pub fn prepare(
  surface: effects.ProviderSurface,
  spec: effects.RequestSpec,
) -> Prepared {
  let consumer = process.self()
  let outer = process.new_subject()
  let startup = Startup(surface:, spec:, consumer:, outer:)

  // A plain linked start, because the link is the point: the worker and this
  // effect are one failure domain, so an unexpected surface crash faults the
  // effect and lets recovery run behind the custodian rather than becoming a
  // fabricated provider response.
  let started =
    sm.new_with_initialiser(start_timeout_ms, fn(_default) {
      initialise(startup)
    })
    |> sm.on_event(handle)
    |> sm.on_enter(entered)
    |> sm.start

  case started {
    Ok(worker) -> published(worker, consumer, outer)

    // The initialiser makes two subjects and cannot fail, so this is a weft
    // start that died under us. Nothing has been asked of the provider, so
    // the failure is reportable in band rather than terminal.
    Error(_error) -> unstarted(outer)
  }
}

// Publishes the started worker to a custodian of its own, and returns the
// handle its caller will publish to the reaper.
fn published(
  worker: sm.Started(Handles),
  consumer: Pid,
  outer: Subject(stream.StreamEvent),
) -> Prepared {
  let Handles(start:, stop:) = worker.data
  let owner = custodian.start(worker.pid, stop, Nil, consumer)
  Prepared(
    handle: stream.owned(
      events: outer,
      owner: custodian.owner(owner),
      cancel: fn() { custodian.cancel(owner) },
    ),
    begin: fn() { process.send(start, owner) },
  )
}

// A worker that never started owns nothing to drain, so its handle is an
// immediate one carrying the failure the caller will read as its terminal.
fn unstarted(outer: Subject(stream.StreamEvent)) -> Prepared {
  process.send(
    outer,
    stream.Failed(error: stream.TransportFailed(
      reason: "the provider request worker did not start",
    )),
  )
  Prepared(
    handle: stream.immediate(events: outer, cancel: fn() { Nil }),
    begin: fn() { Nil },
  )
}

// Makes the worker's two capabilities and parks it on them.
//
// The stop capability exists before publication. Selecting it here lets a
// rejected reaper adoption retire the parked worker without ever crossing the
// provider seam.
fn initialise(
  startup: Startup,
) -> Result(sm.Initialised(Phase, Data, Msg, Handles), String) {
  let start = process.new_subject()
  let stop = process.new_subject()
  let parked =
    process.new_selector()
    |> process.select_map(start, Begin)
    |> process.select_map(stop, fn(_nil) { StopRequested })

  sm.initialised(Parked, Awaiting(startup:, stop:))
  |> sm.selecting(parked)
  |> sm.returning(Handles(start:, stop:))
  |> Ok
}

// --- The machine ----------------------------------------------------------

/// One event, in one state, against one shape of data.
///
/// Writing the matrix out is the point of the port: adding a state, a data
/// variant or a message makes the compiler name every combination nobody has
/// thought about, where the five mutually recursive loops this replaces
/// answered several of them by rebuilding a selector and hoping the arm they
/// left out could not arrive.
fn handle(phase: Phase, data: Data, message: Msg) -> sm.Next(Phase, Data, Msg) {
  case phase, data, message {
    // The reaper has accepted the custodian. Everything the provider seam
    // costs happens here, in the one handler that may cross it.
    Parked, Awaiting(startup:, stop:), Begin(owner:) ->
      admit(startup, stop, owner)

    // A publication the reaper refused. The worker retires without ever
    // having called the provider, which is the whole reason the park exists.
    Parked, Awaiting(..), StopRequested -> sm.stop()

    // A delta keeps the stream open; a terminal is the last thing the
    // consumer will be told, and only the inner owner's exit is outstanding
    // after it.
    Forwarding, Serving(request:), Inner(event:) -> {
      deliver(request, event)
      case event {
        stream.Delta(..) -> sm.keep(data)
        stream.Settled(..) | stream.Failed(..) ->
          sm.transition(to: Draining, data:)
      }
    }

    // Cancellation has two outcomes to report and one stronger fact to
    // preserve. A provider-authored terminal may still arrive during the
    // grace and is forwarded; otherwise the caller gets
    // `CancellationUnconfirmed`. Either way this worker does not exit until
    // the inner owner's exit proves the subtree is gone — which is why both
    // roads lead to `Draining` rather than to a stop.
    Forwarding, Serving(request:), StopRequested ->
      case consumer_liveness(request.consumer) {
        ConsumerAlive -> sm.transition(to: Cancelling, data:)
        ConsumerGone -> abandon(request, data)
      }

    // Once the consumer is dead, no process can use a terminal event.
    // Waiting for one would delay restart without preserving information, so
    // this path keeps only the stronger obligation: cancel, and prove the
    // inner owner is gone.
    Forwarding, Serving(request:), ConsumerDown
    | Cancelling, Serving(request:), ConsumerDown
    -> abandon(request, data)

    // The owner exited while its events were still being relayed. A monitor
    // fires once, so the proof is recorded rather than acted on: a later wait
    // for a `Down` already delivered would never end.
    Forwarding, Serving(request:), InnerRetired(proof:)
    | Cancelling, Serving(request:), InnerRetired(proof:)
    ->
      sm.keep(Serving(
        request: Request(..request, drain: InnerAlreadyRetired(proof:)),
      ))

    // The one terminal the cancellation race can still produce. It is the
    // owner's own answer, so it is forwarded exactly as an uncancelled
    // terminal would be.
    Cancelling, Serving(request:), Inner(event: stream.Settled(..) as terminal)
    | Cancelling, Serving(request:), Inner(event: stream.Failed(..) as terminal)
    -> {
      deliver(request, terminal)
      sm.transition(to: Draining, data:)
    }

    // A delta arriving after cancellation is dropped rather than forwarded:
    // the caller has already asked this stream to stop, and only an
    // owner-authored terminal still tells it anything.
    Cancelling, Serving(..), Inner(event: stream.Delta(..)) -> sm.keep(data)

    // Idempotent, and deliberately a `keep`: a second stop must not restart
    // the grace the first one armed. This is the whole of what the
    // hand-rolled loop bought by installing its deadline subject exactly once
    // and threading the same selector through every recursion.
    Cancelling, Serving(..), StopRequested -> sm.keep(data)

    // The owner neither answered the cancellation nor died inside its grace.
    // Only the request owner may claim that cancellation won its race with
    // settlement, so this boundary says exactly that it does not know.
    Cancelling, Serving(request:), CancelExpired -> unconfirmed(request, data)

    // The consumer has its answer and the subtree is gone. Retiring normally
    // is what lets the outer custodian certify a clean provider shutdown.
    Draining, Serving(request:), InnerRetired(proof: InnerDrained) -> {
      forget(request)
      sm.stop()
    }

    // This worker is itself a transitive child of the outer custodian.
    // Preserving an abnormal inner exit as an abnormal worker exit lets that
    // custodian report the lost proof instead of certifying a shutdown it
    // cannot see the bottom of, and carries the same fact across the link
    // into the provider effect.
    Draining, Serving(request:), InnerRetired(proof: InnerProofLost) -> {
      forget(request)
      sm.stop_abnormal("the inner provider owner exited without proof of drain")
    }

    // Everything a settled request can still be told. Late deltas and a late
    // terminal have no consumer left to reach, a repeated stop is already
    // being carried out, and the consumer's death changes nothing about the
    // one obligation still outstanding.
    Draining, Serving(..), Inner(..)
    | Draining, Serving(..), StopRequested
    | Draining, Serving(..), ConsumerDown
    -> sm.keep(data)

    // Unreachable through the selector rather than through the types. A
    // parked worker selects only the permit and the stop; a serving one no
    // longer selects the permit at all, because the step that granted it
    // replaced the selector; and the grace is a state timeout on
    // `Cancelling`, so a fire that raced the move out is dropped by weft's
    // timer book before it reaches this handler.
    Parked, Awaiting(..), Inner(..)
    | Parked, Awaiting(..), ConsumerDown
    | Parked, Awaiting(..), CancelExpired
    | Parked, Awaiting(..), InnerRetired(..)
    | Forwarding, Serving(..), Begin(..)
    | Forwarding, Serving(..), CancelExpired
    | Cancelling, Serving(..), Begin(..)
    | Draining, Serving(..), Begin(..)
    | Draining, Serving(..), CancelExpired
    -> sm.keep(data)

    // Unreachable through the data. The permit is what turns `Awaiting` into
    // `Serving`, and it is also what leaves `Parked`, so the two always move
    // together; these arms exist because the matrix is exhaustive, not
    // because a worker can hold the wrong half of its own life.
    Parked, Serving(..), Begin(..)
    | Parked, Serving(..), Inner(..)
    | Parked, Serving(..), StopRequested
    | Parked, Serving(..), ConsumerDown
    | Parked, Serving(..), CancelExpired
    | Parked, Serving(..), InnerRetired(..)
    | Forwarding, Awaiting(..), Begin(..)
    | Forwarding, Awaiting(..), Inner(..)
    | Forwarding, Awaiting(..), StopRequested
    | Forwarding, Awaiting(..), ConsumerDown
    | Forwarding, Awaiting(..), CancelExpired
    | Forwarding, Awaiting(..), InnerRetired(..)
    | Cancelling, Awaiting(..), Begin(..)
    | Cancelling, Awaiting(..), Inner(..)
    | Cancelling, Awaiting(..), StopRequested
    | Cancelling, Awaiting(..), ConsumerDown
    | Cancelling, Awaiting(..), CancelExpired
    | Cancelling, Awaiting(..), InnerRetired(..)
    | Draining, Awaiting(..), Begin(..)
    | Draining, Awaiting(..), Inner(..)
    | Draining, Awaiting(..), StopRequested
    | Draining, Awaiting(..), ConsumerDown
    | Draining, Awaiting(..), CancelExpired
    | Draining, Awaiting(..), InnerRetired(..)
    -> sm.keep(data)
  }
}

// Prepares the inner request under a granted permit, publishes its owner, and
// decides which state the worker's next event will be handled in.
//
// The drain monitor is installed between preparation and adoption, before any
// path can call `begin`: an owner watched only after it exited reports
// `noproc`, which proves death and cannot prove clean drain.
//
// The step replaces the selector because the inner stream's events subject
// was created two lines above, in this process, and could not have been named
// when the machine started.
fn admit(
  startup: Startup,
  stop: Subject(Nil),
  owner: custodian.Custodian,
) -> sm.Next(Phase, Data, Msg) {
  let stream.PreparedStream(handle: inner, begin: begin_inner) =
    effects.prepare_provider(startup.surface, startup.spec)
  let consumer_monitor = process.monitor(startup.consumer)
  let drain = watch_inner(inner)
  let serving =
    Serving(request: Request(
      inner:,
      outer: startup.outer,
      consumer: startup.consumer,
      consumer_monitor:,
      drain:,
    ))
  let selector = request_selector(inner, stop, consumer_monitor, drain)

  case custodian.adopt(owner, inner.owner, inner.cancel) {
    True -> {
      begin_inner()
      sm.transition(to: Forwarding, data: serving)
      |> sm.with_selector(selector)
    }

    // Prepared production work is still parked here, but legacy in-memory
    // surfaces may already carry a real terminal. Moving into the cancelling
    // state preserves that terminal without granting a begin permit to
    // asynchronous work, and gives it the same single grace as any other
    // cancellation — where a deadline armed per event would let late deltas
    // renew it.
    False ->
      sm.transition(to: Cancelling, data: serving)
      |> sm.with_selector(selector)
  }
}

/// The work each state owns, done by every path into it — including the
/// initial entry, which weft makes for the starting state on the far side of
/// the start acknowledgement.
///
/// Cancelling here rather than at the transition sites is what deletes the
/// bookkeeping the hand-rolled worker needed: two call sites asked the inner
/// stream to stop and one of them additionally scheduled the grace with
/// `send_after`, which the forwarding loop then had to be careful never to
/// re-arm. A state timeout is cancelled by the move out of the state that
/// armed it, so the guard is deleted rather than relocated.
fn entered(_from: Phase, to: Phase, data: Data) -> sm.Enter(Phase, Data, Msg) {
  case to, data {
    Cancelling, Serving(request:) -> {
      // Cancellation is fallible work, so it runs on this worker rather than
      // on the public witness. If it crashes, the custodian observes that
      // Down and invokes its retained copy on a disposable helper while
      // keeping the inner owner in the drain set.
      stream.cancel(request.inner)

      sm.keep(data)
      |> sm.with_state_timeout(after: cancel_grace_ms, sending: CancelExpired)
    }

    // Nothing more is owed to anyone; only the inner owner's exit is
    // outstanding. An immediate handle owns no asynchronous work, and an
    // owner that exited while events were still being forwarded has already
    // delivered its only `Down` — so both are answered by injecting the
    // retirement this state exists to wait for, rather than by waiting for a
    // message that will never arrive.
    Draining, Serving(request:) ->
      case request.drain {
        WatchingInner(..) -> sm.keep(data)
        InnerAlreadyRetired(proof:) ->
          sm.keep(data) |> sm.then_handle(InnerRetired(proof:))
      }

    // The park owns no deadline: the reaper's acceptance and the custodian's
    // stop capability are what end a worker that is going nowhere, and
    // forwarding owns none either — the effect holds the request deadline.
    // The remaining pairs cannot arise, for the reason the event matrix
    // gives.
    Parked, Awaiting(..)
    | Forwarding, Serving(..)
    | Parked, Serving(..)
    | Forwarding, Awaiting(..)
    | Cancelling, Awaiting(..)
    | Draining, Awaiting(..)
    -> sm.keep(data)
  }
}

// --- The worker's channels ------------------------------------------------

// The worker, rather than the custodian, receives provider events. This keeps
// parsing and terminal arbitration in the effect failure domain while the
// custodian remains a reliable witness if any of that work crashes.
//
// The permit is deliberately absent: it is one-way, and a selector that no
// longer names it is how the machine says a second `begin` reaches nobody.
fn request_selector(
  inner: stream.StreamHandle,
  stop: Subject(Nil),
  consumer_monitor: Monitor,
  drain: Drain,
) -> process.Selector(Msg) {
  process.new_selector()
  |> process.select_map(inner.events, Inner)
  |> process.select_map(stop, fn(_nil) { StopRequested })
  |> process.select_specific_monitor(consumer_monitor, fn(_down) {
    ConsumerDown
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

// A transitive owner speaks for work beneath it. Only its normal exit proves
// that every descendant drained; this is `stream`'s own adjudication, made
// where the `Down` is selected rather than waited for.
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

// --- Effects the handlers reach for ---------------------------------------

// Nobody is left to receive a terminal. The inner owner is cancelled and the
// worker waits for its exit, emitting nothing at all.
fn abandon(request: Request, data: Data) -> sm.Next(Phase, Data, Msg) {
  stream.cancel(request.inner)
  sm.transition(to: Draining, data:)
}

// Cancellation crossed this boundary and was never acknowledged.
fn unconfirmed(request: Request, data: Data) -> sm.Next(Phase, Data, Msg) {
  deliver(request, stream.Failed(error: stream.CancellationUnconfirmed))
  sm.transition(to: Draining, data:)
}

// A stream nobody can receive is not forwarded. The check is made per event
// rather than once, because the consumer may die between two of them and this
// worker must not be the thing that keeps its answer alive.
fn deliver(request: Request, event: stream.StreamEvent) -> Nil {
  case consumer_liveness(request.consumer) {
    ConsumerAlive -> process.send(request.outer, event)
    ConsumerGone -> Nil
  }
}

fn consumer_liveness(consumer: Pid) -> ConsumerLiveness {
  case process.is_alive(consumer) {
    True -> ConsumerAlive
    False -> ConsumerGone
  }
}

fn forget(request: Request) -> Nil {
  process.demonitor_process(request.consumer_monitor)
}
