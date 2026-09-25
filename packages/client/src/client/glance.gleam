//// The glance loop: one state machine per session that keeps a short title
//// and a one-line "now" summary for every running sub-agent, written where
//// a connected terminal already looks.
////
//// # Why a harness loop
////
//// An operator watching several agents at once needs each reduced to a
//// line. Nothing in the transcript is that line — the raw material is a
//// strand's prompt, its tool calls and its latest text, all long and all
//// noisy — so a cheap model writes it. The model is the harness's, not
//// the agent's: the cell sits under the reserved `client/` prefix, which a
//// model cannot write, so an agent cannot describe itself to the operator
//// in words the harness did not choose. And every transcript capture
//// already carries the whole `client/` prefix (`gateway.snapshot_plan`), so
//// the terminal receives each glance with the cut it renders and no new
//// frame or protocol change was needed. `core/glance` owns the cell's
//// shape and codec.
////
//// # What it watches
////
//// The trigger is the cost ledger's notification, `effects.Hooks.usage`,
//// which fires once per committed provider response on every strand of
//// the session, after the commit — the slot the advisor's step counter
//// rides for the same reason. `hooks` wraps it with a cast carrying the
//// operation id and the row's context size, and nothing else happens on
//// the strand driver's process. This machine resolves the operation's
//// strand from `op.meta` and ignores the primary `main` strand and the
//// `advisor` strand: the terminal shows both from data it already has.
////
//// # When it asks
////
//// Pacing is `client/glancepace`, a pure function of (book, event, now):
//// a strand's first step in an operation is due at once, later refreshes
//// wait out `Pace.every_ms` and happen only if the strand stepped since
//// the last request began, each strand has at most one request out, the
//// session at most `Pace.concurrency`, and failures back off. Every plan
//// names the soonest instant anything becomes due, and this machine arms
//// one named timeout for it or cancels it when nothing is owed, so an
//// idle session holds no timer at all.
////
//// # How a request runs
////
//// Each request is a one-task `weft` run with a deadline, relayed into a
//// sink subject the machine creates for it and selects on only while the
//// request is out. The sink is the request's identity: whatever the run
//// ends in — an answer, a crash, the deadline — arrives on the sink that
//// names its strand, and the flight is cleared only on the run's last word
//// (`AllDelivered` or `RunLost`), so a strand is never launched twice while
//// anything it started is still alive. The task itself does every read,
//// the provider call and the write: it confirms the operation is still the
//// strand's live one, reads the prompt and the recent branch straight off
//// the session store, reuses the title already written for this operation
//// if there is one, asks the summarizer, and writes the cell through
//// `api.put_reserved_fact`. The machine's own process does no I/O.
////
//// # Failure
////
//// A summarizer that fails, times out or answers something
//// `client/glanceslice.parse` cannot read leaves the old cell exactly as
//// it was, is logged at warning level on the first failure of a streak
//// and at debug level after, and backs off. It never touches the strand
//// it describes: the only thing the loop writes is the glance cell, and
//// nothing the strand's run reads depends on it.
////
//// The cell is never deleted. There is one per strand, it is overwritten
//// by the next operation's first summary, and a reader shows it only while
//// its `operation` is still the strand's current one.

import client/advisor
import client/distill.{type Distiller}
import client/glancepace
import client/glanceslice
import client/notes
import core/clock.{type Clock}
import core/entry.{type Entry, type UsageRow}
import core/glance as glance_cell
import core/ids.{type EntryId, type OpId}
import core/register
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import machine/operation.{type Operation}
import provider/gateway as provider_gateway
import provider/model.{type RequestTarget}
import runtime/api.{type Runtime}
import runtime/effects
import session/session.{type Session}
import storage/storage
import telemetry/field
import telemetry/log.{type Logger}
import weft
import weft/actor
import weft/registry as address
import weft/state_machine as sm

// --- configuration -----------------------------------------------------------

/// How long the summarizer is given to answer one request, in
/// milliseconds. A glance is a label, so an answer slower than this is
/// not worth waiting for.
pub const request_timeout_ms = 30_000

/// The ceiling on the summarizer's answer, in tokens. Two short lines fit
/// in a fraction of it; the cap is what stops a chatty model spending a
/// long answer on every refresh.
pub const max_answer_tokens = 160

/// The weft deadline on one request's run. It sits above
/// `request_timeout_ms` because the summarizer bounds its own wait and
/// drains its own stream; this is the backstop for a task that is stuck
/// somewhere else, and it kills and joins the worker before the run
/// reports.
pub const request_deadline_ms = 45_000

/// How many entries of the strand's branch a request reads, newest first.
/// Enough to hold `glanceslice.max_calls` calls with their results between
/// them, and small enough that a long operation costs one bounded scan.
pub const branch_window = 64

/// The one name every arming of this machine's wake uses, so each plan's
/// arming supersedes the last and a superseded wake dies in weft's timer
/// book.
const wake_timer = "glance-wake"

/// Everything the loop needs from its host.
pub type Wiring {
  Wiring(
    /// The session store, read directly for `op.meta`, strand state, the
    /// branch and the existing cell. Reads through the writer queue
    /// behind commits, and a label must never delay a settlement.
    session: Session,
    /// The live runtime, borrowed per request for the one write. It cannot
    /// be held: the runtime contains the effects this loop's hook is
    /// composed into, so a captured runtime would be a value cycle.
    runtime: fn() -> Result(Runtime, Nil),
    /// The model seam. Production fills it with `summarizer`; a test fills
    /// it with a script.
    summarizer: Distiller,
    /// The time source for `glance.at` and the pacing arithmetic.
    clock: Clock,
    /// The pacing knobs, `glancepace.default_pace` in production.
    pace: glancepace.Pace,
    /// Where failures are reported.
    logger: Logger,
    /// The address this machine registers under, and the one the hook
    /// casts to.
    name: address.Address(Message),
  )
}

/// How a request's task ended when it returned rather than failed.
pub type Report {
  /// The glance cell was written.
  Written

  /// The operation was no longer the strand's live one, so nothing was
  /// asked and nothing was written.
  Gone
}

/// The machine's mailbox. Opaque: only the hook built by `hooks` and the
/// machine itself produce these.
pub opaque type Message {
  /// A strand committed a provider response. `context` is the row's
  /// context size, or `None` for a row that measures none.
  Stepped(operation: OpId, context: Option(Int))

  /// The wake the last plan asked for has come.
  Wake

  /// One request's run said something, on the sink that names `strand`.
  Relayed(strand: String, pulled: weft.Pulled(Report, String))
}

// The one state this machine is in. What moves between events is data —
// the book and the flights — and the one timer belongs to the machine
// rather than to a phase (`docs/weft.md` rule 8), which is the
// arrangement `client/schedulescan` uses for the same reason.
type Phase {
  Watching
}

type Data {
  Data(
    wiring: Wiring,
    inbox: Subject(Message),
    book: glancepace.Book,
    flights: Dict(String, Flight),
  )
}

// One request that is out. The sink is selected for exactly as long as
// the flight is booked, so nothing a relay sends can arrive unselected.
type Flight {
  Flight(
    operation: String,
    sink: Subject(weft.Pulled(Report, String)),
    landed: Landing,
  )
}

// A relay delivers the task's outcome and then the run's last word, as two
// messages from one sender. The outcome is held here until the last word
// arrives, because only the last word proves the worker has exited.
type Landing {
  Awaiting
  Landed(outcome: weft.Outcome(Report, String))
}

// --- routing -------------------------------------------------------------------

/// Which identity the summarizer's requests dispatch to: the `summarize`
/// role when the catalogue routes one, else `subagent`, else `main`, always
/// with thinking off.
///
/// The fallback is what gives a new user with no role table a working
/// glance: every catalogue routes `main`. It is dispatched as a role, so a
/// rate-limited head still falls to its own tail, and there is no durable
/// identity to honour because a glance is published as text rather than
/// as a response attributed to a model — the argument `distill.target`
/// makes for memory.
///
/// ## Examples
///
/// ```gleam
/// // glance.target(gateway)
/// //   == Ok(model.ForRole(model.Summarize, Some(model.ThinkingOff)))
/// ```
pub fn target(
  gateway: provider_gateway.Gateway,
) -> Result(RequestTarget, String) {
  [model.Summarize, model.Subagent, model.Main]
  |> list.find(fn(role) {
    result.is_ok(provider_gateway.resolve(gateway, role))
  })
  |> result.map(fn(role) {
    model.ForRole(role:, thinking: Some(model.ThinkingOff))
  })
  |> result.replace_error(
    "the catalogue routes no summarize, subagent or main model",
  )
}

/// The production summarizer over `target`, capped at
/// `max_answer_tokens` and bounded by `request_timeout_ms`.
///
/// ## Examples
///
/// ```gleam
/// // glance.summarizer(gateway)
/// ```
pub fn summarizer(
  gateway: provider_gateway.Gateway,
) -> Result(Distiller, String) {
  use dispatch <- result.map(target(gateway))
  distill.capped_gateway_distiller(
    gateway,
    dispatch,
    timeout_ms: request_timeout_ms,
    max_output_tokens: max_answer_tokens,
  )
}

// --- the hook ------------------------------------------------------------------

/// Wraps the usage slot so every committed provider response casts one
/// `Stepped` to the machine at `name`, then calls the inner slot.
///
/// The slot runs on the strand driver's own process, so the cast is the
/// whole of the work: no store read, no wait. It captures the name and
/// the inner slot, never the enclosing record, because the hooks are
/// copied into every strand driver. A send to an absent machine is
/// dropped; a lost step costs one refresh, and the strand's next step
/// offers it again.
///
/// ## Examples
///
/// ```gleam
/// // glance.hooks(built.hooks, glance_name)
/// ```
pub fn hooks(
  built: effects.Hooks,
  name: address.Address(Message),
) -> effects.Hooks {
  let metered = built.usage
  effects.Hooks(..built, usage: fn(operation, row) {
    let _sent =
      address.send(name, Stepped(operation:, context: context_of(row)))
    metered(operation, row)
  })
}

/// The context size one usage row measures: `input + cache_read +
/// cache_write + output`, the figure `core/glance.Glance.tokens` carries.
/// An adjustment row is a reconciliation delta rather than a measurement,
/// so it measures nothing.
///
/// ## Examples
///
/// ```gleam
/// // glance.context_of(row) == Some(136_000)
/// ```
pub fn context_of(row: UsageRow) -> Option(Int) {
  case row.adjustment {
    True -> None
    False ->
      Some(
        row.usage.input
        + row.usage.cache_read
        + row.usage.cache_write
        + row.usage.output,
      )
  }
}

// --- the machine ---------------------------------------------------------------

/// Starts the loop under `wiring.name`.
///
/// ## Examples
///
/// ```gleam
/// // glance.start(wiring)
/// ```
pub fn start(wiring: Wiring) -> actor.StartResult(Subject(Message)) {
  builder(wiring) |> sm.start
}

/// The loop as a supervision child, for the restartable service tier. A
/// restart forgets the book and the flights — each flight's run is linked
/// to the old machine and tears itself down with it — and loses nothing
/// else: titles live in the cells, and the next step on each strand books
/// it again.
///
/// ## Examples
///
/// ```gleam
/// // sup.add(builder, glance.supervised(wiring))
/// ```
pub fn supervised(wiring: Wiring) -> ChildSpecification(Subject(Message)) {
  sm.supervised(builder(wiring))
}

fn builder(
  wiring: Wiring,
) -> sm.Builder(Phase, Data, Message, Subject(Message)) {
  sm.new_with_initialiser(5000, fn(inbox) {
    sm.initialised(
      Watching,
      Data(wiring:, inbox:, book: glancepace.new(), flights: dict.new()),
    )
    |> sm.returning(inbox)
    |> Ok
  })
  |> sm.addressed(wiring.name)
  |> sm.on_event(handle)
}

fn handle(
  state: Phase,
  data: Data,
  message: Message,
) -> sm.Next(Phase, Data, Message) {
  case state, message {
    Watching, Stepped(operation:, context:) -> stepped(data, operation, context)
    Watching, Wake -> plan(data, glancepace.Tick)
    Watching, Relayed(strand:, pulled:) -> relayed(data, strand, pulled)
  }
}

// A step on a strand the terminal already covers, or on an operation whose
// metadata will not read, books nothing. The metadata read is what turns
// the hook's bare operation id into a strand, and it is done here rather
// than in the hook so the driver never waits on the store for a label.
fn stepped(
  data: Data,
  operation: OpId,
  context: Option(Int),
) -> sm.Next(Phase, Data, Message) {
  case notes.strand_of(data.wiring.session, operation) {
    Error(Nil) -> sm.keep(data)
    Ok(strand) ->
      case is_watched(strand) {
        False -> sm.keep(data)
        True ->
          plan(
            data,
            glancepace.Stepped(
              strand:,
              operation: ids.op_id_to_string(operation),
              context:,
            ),
          )
      }
  }
}

/// Whether the loop summarizes `strand`. Every strand but the primary
/// and the advisor, which the terminal describes from data it already
/// holds.
///
/// ## Examples
///
/// ```gleam
/// assert glance.is_watched("sub:main/audit-1a2b")
/// assert !glance.is_watched("main")
/// ```
pub fn is_watched(strand: String) -> Bool {
  strand != advisor.primary && strand != advisor.strand
}

// Every event ends here: the pure plan, its launches, then exactly one
// statement about the wake and a selector that matches the flights now
// booked. Rebuilding the selector on every plan is what keeps "selected
// while booked" true without tracking which event changed the flights.
fn plan(data: Data, event: glancepace.Event) -> sm.Next(Phase, Data, Message) {
  let #(now, _clock) = clock.read(data.wiring.clock)
  let planned = glancepace.step(data.book, event, now, data.wiring.pace)
  let data = list.fold(planned.launch, Data(..data, book: planned.book), launch)

  sm.keep(data)
  |> rearm(planned.wake, now)
  |> sm.with_selector(selector(data))
}

fn rearm(
  step: sm.Next(Phase, Data, Message),
  wake: Option(Int),
  now: Int,
) -> sm.Next(Phase, Data, Message) {
  case wake {
    None -> sm.cancel_timeout(step, name: wake_timer)
    Some(at) ->
      sm.with_named_timeout(
        step,
        name: wake_timer,
        after: int.max(at - now, 0),
        sending: Wake,
      )
  }
}

fn selector(data: Data) -> process.Selector(Message) {
  let own = process.new_selector() |> process.select(data.inbox)
  dict.fold(data.flights, own, fn(selector, strand, flight) {
    process.select_map(selector, flight.sink, fn(pulled) {
      Relayed(strand:, pulled:)
    })
  })
}

// The pacing guarantees a strand has at most one request out, so the
// insert below never replaces a flight that is still booked.
fn launch(data: Data, launch: glancepace.Launch) -> Data {
  let sink = process.new_subject()
  let wiring = data.wiring

  // The relay is linked to this machine and the scope to the relay, so a
  // machine that dies takes every request it started down with it.
  let _relay =
    weft.new([fn() { summarize(wiring, launch) }])
    |> weft.deadline(request_deadline_ms)
    |> weft.start_relayed(to: sink)

  let flight = Flight(operation: launch.operation, sink:, landed: Awaiting)
  Data(..data, flights: dict.insert(data.flights, launch.strand, flight))
}

fn relayed(
  data: Data,
  strand: String,
  pulled: weft.Pulled(Report, String),
) -> sm.Next(Phase, Data, Message) {
  case dict.get(data.flights, strand) {
    // A sink is selected only while its flight is booked, so a message on
    // one always finds it; this arm is totality.
    Error(Nil) -> sm.keep(data)

    Ok(flight) ->
      case pulled {
        weft.PulledOutcome(outcome:) -> {
          let flight = Flight(..flight, landed: Landed(outcome:))
          sm.keep(
            Data(..data, flights: dict.insert(data.flights, strand, flight)),
          )
        }

        // A relay forwards outcomes and the last word, never a pull that
        // found nothing.
        weft.NotYet -> sm.keep(data)
        weft.AllDelivered -> finished(data, strand, flight, None)
        weft.RunLost(reason:) ->
          finished(data, strand, flight, Some(string.inspect(reason)))
      }
  }
}

// The run's last word: the worker has exited, so the strand's slot is
// free. The report is logged before the plan, against the book as it was,
// because whether this is the first failure of a streak is a question
// about the failures counted before this one.
fn finished(
  data: Data,
  strand: String,
  flight: Flight,
  lost: Option(String),
) -> sm.Next(Phase, Data, Message) {
  let data = Data(..data, flights: dict.delete(data.flights, strand))
  let ending = ending_of(flight.landed, lost)
  report(data, strand, flight.operation, ending)

  let settled = case ending {
    Ok(Written) -> glancepace.Summarized
    Ok(Gone) -> glancepace.Ended
    Error(_reason) -> glancepace.Unusable
  }
  plan(
    data,
    glancepace.Settled(strand:, operation: flight.operation, ending: settled),
  )
}

// All seven outcomes are written out (`docs/weft.md` rule 9). A plain task
// never produces the last two; the arms are there so a run that grows an
// owner fails exhaustiveness rather than taking a catch-all.
fn ending_of(landed: Landing, lost: Option(String)) -> Result(Report, String) {
  case landed {
    Landed(weft.Completed(value:, ..)) -> Ok(value)
    Landed(weft.Failed(error:, ..)) -> Error(error)
    Landed(weft.Crashed(reason:, ..)) ->
      Error("the request crashed: " <> string.inspect(reason))
    Landed(weft.Abandoned(..)) ->
      Error("the request did not finish inside its deadline")
    Landed(weft.NeverStarted(..)) -> Error("the request never started")
    Landed(weft.DrainProofLost(reason:, ..)) ->
      Error("the request's drain proof was lost: " <> string.inspect(reason))
    Landed(weft.CancellationUnconfirmed(..)) ->
      Error("the request's cancellation was not confirmed")
    Awaiting ->
      Error(
        "the request ended without an outcome: "
        <> option.unwrap(lost, "the run finished"),
      )
  }
}

fn report(
  data: Data,
  strand: String,
  operation: String,
  ending: Result(Report, String),
) -> Nil {
  let fields = [
    field.text(key: "strand", value: strand),
    field.text(key: "operation", value: operation),
  ]
  case ending {
    Ok(Written) -> log.debug(data.wiring.logger, "glance.written", fields)
    Ok(Gone) -> log.debug(data.wiring.logger, "glance.operation_ended", fields)
    Error(reason) -> {
      let fields = [field.text(key: "reason", value: reason), ..fields]
      case streak(data.book, strand, operation) {
        0 -> log.warn(data.wiring.logger, "glance.unusable", fields)
        _later -> log.debug(data.wiring.logger, "glance.unusable", fields)
      }
    }
  }
}

// How many consecutive failures this operation had before the one being
// reported. A strand that has moved on to another operation starts a new
// streak.
fn streak(book: glancepace.Book, strand: String, operation: String) -> Int {
  case glancepace.track(book, strand) {
    Ok(track) if track.operation == operation -> track.failures
    Ok(_other) | Error(Nil) -> 0
  }
}

// --- one request -------------------------------------------------------------

// The whole of one request, on its own worker. Every step that can fail
// says so in words, because the words are what the loop logs; the one
// early success is an operation that is no longer live, which is not a
// failure and asks nothing.
fn summarize(
  wiring: Wiring,
  launch: glancepace.Launch,
) -> Result(Report, String) {
  let store = wiring.session
  use live <- result.try(live_operation(store, launch.strand))
  use <- bool.guard(when: live != Some(launch.operation), return: Ok(Gone))

  use meta <- result.try(operation_meta(store, launch.operation))
  use prompts <- result.try(prompt_entries(store, meta))
  use recent <- result.try(recent_entries(store, launch.strand, meta))
  let title = stored_title(store, launch.strand, launch.operation)
  let material = glanceslice.gather(prompts:, recent:, title:)

  use answer <- result.try(wiring.summarizer.ask(glanceslice.request(material)))
  use reply <- result.try(
    glanceslice.parse(answer.text, title)
    |> result.replace_error("the summarizer's answer was not usable"),
  )
  write(wiring, launch, reply)
}

fn write(
  wiring: Wiring,
  launch: glancepace.Launch,
  reply: glanceslice.Reply,
) -> Result(Report, String) {
  use runtime <- result.try(
    wiring.runtime() |> result.replace_error("the runtime is unavailable"),
  )
  let #(now, _clock) = clock.read(wiring.clock)
  let written =
    glance_cell.Glance(
      operation: launch.operation,
      title: reply.title,
      summary: reply.summary,
      at: now,
      tokens: launch.context,
    )

  api.put_reserved_fact(
    runtime,
    glance_cell.key(launch.strand),
    glance_cell.encode(written),
  )
  |> result.map(fn(_nil) { Written })
  |> result.map_error(fn(error) {
    "the glance cell did not commit: " <> string.inspect(error)
  })
}

fn live_operation(
  store: Session,
  strand: String,
) -> Result(Option(String), String) {
  case session.strand_state(store, strand) {
    Ok(Some(session.Cell(value: state, ..))) ->
      Ok(option.map(state.current_operation, ids.op_id_to_string))
    Ok(None) -> Ok(None)
    Error(error) ->
      Error("the strand state did not read: " <> string.inspect(error))
  }
}

fn operation_meta(
  store: Session,
  operation: String,
) -> Result(Operation, String) {
  use id <- result.try(
    ids.parse_op_id(operation)
    |> result.map_error(fn(_report) {
      "the operation id did not parse: " <> operation
    }),
  )
  case session.op_meta(store, id) {
    Ok(Some(session.Cell(value: meta, ..))) -> Ok(meta)
    Ok(None) -> Error("the operation has no metadata: " <> operation)
    Error(error) ->
      Error("the operation metadata did not read: " <> string.inspect(error))
  }
}

// The accepted prompt, in acceptance order. A compaction or navigation has
// no prompt, which leaves the request to the branch alone.
fn prompt_entries(
  store: Session,
  meta: Operation,
) -> Result(List(Entry), String) {
  case meta.intent {
    operation.RunIntent(prompt_entries: wanted) ->
      storage.get_entries(store.store, wanted)
      |> result.map(fn(found) {
        list.filter_map(wanted, fn(id) { dict.get(found, id) })
      })
      |> result.map_error(fn(error) {
        "the prompt entries did not read: " <> string.inspect(error)
      })
    operation.CompactionIntent(..) | operation.NavigationIntent(..) -> Ok([])
  }
}

// The strand's branch back to the operation's source leaf, newest first
// and at most `branch_window` entries. The stop is inclusive, so the
// source leaf itself — the last thing *before* this operation — is
// dropped when the scan reached it.
fn recent_entries(
  store: Session,
  strand: String,
  meta: Operation,
) -> Result(List(Entry), String) {
  use leaf <- result.try(strand_leaf(store, strand))
  case leaf {
    None -> Ok([])
    Some(leaf) -> {
      let scan =
        storage.branch_scan(from: leaf)
        |> storage.branch_limit(branch_window)
      let scan = case meta.source_leaf {
        Some(source) -> storage.branch_stop_at_id(scan, source)
        None -> scan
      }

      storage.scan_branch(store.store, scan)
      |> result.map(without(_, meta.source_leaf))
      |> result.map_error(fn(error) {
        "the branch did not read: " <> string.inspect(error)
      })
    }
  }
}

fn strand_leaf(
  store: Session,
  strand: String,
) -> Result(Option(EntryId), String) {
  case session.strand_leaf(store, strand) {
    Ok(Some(session.Cell(value: leaf, ..))) -> Ok(leaf)
    Ok(None) -> Ok(None)
    Error(error) ->
      Error("the strand leaf did not read: " <> string.inspect(error))
  }
}

fn without(rows: List(Entry), source: Option(EntryId)) -> List(Entry) {
  case source {
    None -> rows
    Some(source) -> list.filter(rows, fn(row) { row.id != source })
  }
}

// The title this operation's glance already carries. A cell that will not
// read, belongs to another operation or has no title asks for a fresh one,
// which costs a longer answer and nothing else.
fn stored_title(
  store: Session,
  strand: String,
  operation: String,
) -> glanceslice.Title {
  let stored =
    storage.get_register(
      store.store,
      register.FactCustom,
      glance_cell.key(strand),
    )
  case stored {
    Ok(Some(storage.Register(value:, ..))) ->
      case glance_cell.decode(value.payload) {
        Ok(found) if found.operation == operation && found.title != "" ->
          glanceslice.Titled(text: found.title)
        Ok(_other) | Error(_) -> glanceslice.Untitled
      }
    Ok(None) | Error(_) -> glanceslice.Untitled
  }
}
