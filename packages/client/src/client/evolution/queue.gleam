//// The operator door queues a bounded live transition and returns immediately.
////
//// Staging and native retirement can take minutes; the gateway's synchronous
//// command deadline cannot own that work. One native actor retains one managed
//// job while callers poll by request identity. Retries compare a native canonical
//// signature and return the original status. A different payload cannot reuse
//// that identity. The live generation owner retains cleanup refusal capabilities;
//// the queue keeps only bounded public receipts and never executable authority.

import broker/internal/call
import client/evolution/live
import client/evolution/record
import client/evolution/store
import core/clock.{type Clock}
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import weft
import weft/actor

/// The public bounded receipt, containing no native commit or retirement closure.
pub type Status {
  /// The native queue accepted this exact request.
  Queued(request_id: String)

  /// Staging is running under the admitted absolute deadline.
  Running(request_id: String)

  /// Native selection, adoption and publication finished.
  Completed(selection: record.Selection)

  /// A named refusal or managed-job failure ended this request.
  Failed(reason: String)
}

/// How far an unfinished transition has got.
pub type Phase {
  /// Accepted, and not yet running.
  Accepted

  /// Staging is running under its deadline.
  Staging
}

/// One transition the queue has accepted and not yet finished.
///
/// The queue runs one job at a time, so a listing holds at most one of these.
/// It is a list so that a queue which one day runs two does not change the
/// shape a reader depends on.
pub type Waiting {
  Waiting(
    /// The operator's request identity.
    request_id: String,
    /// Whether staging has begun. A finished job is not waiting.
    phase: Phase,
    /// The candidate the transition would select.
    candidate_id: record.CandidateId,
    /// The absolute clock deadline after which publication is forbidden.
    expires_at: Int,
  )
}

/// The queue's narrow native address and original retirement identity.
pub opaque type Queue {
  Queue(pid: Pid, requests: Subject(Message))
}

/// One retained deduplication receipt.
type Receipt {
  Receipt(request_id: String, signature: String, status: Status)
}

/// One job remains occupied until weft acknowledges that its relay is drained.
type Job {
  Job(
    receipt: Receipt,
    cancel: weft.Cancel,
    candidate_id: record.CandidateId,
    expires_at: Int,
  )
}

/// Queue state and messages sit above all handlers so their custody is visible.
type State {
  State(
    owner: live.Live,
    clock: Clock,
    outcomes: Subject(weft.Pulled(record.Selection, String)),
    // Tells the host that a request reached a terminal state. It runs inside
    // the queue's own turn, after the receipt has changed, so a reader the
    // notification wakes finds the terminal status.
    changed: fn() -> Nil,
    active: Option(Job),
    receipts: List(Receipt),
    closing: Option(Subject(Result(Nil, String))),
  )
}

type Message {
  Enqueue(live.Transition, String, Subject(Result(Status, String)))
  Poll(String, Subject(Result(Option(Status), String)))
  Listing(Subject(List(Waiting)))
  Delivered(weft.Pulled(record.Selection, String))
  Closing(Subject(Result(Nil, String)))
}

/// Starts an idle queue; no helper or task exists until native admission.
///
/// ## Examples
///
/// ```gleam
/// // queue.start(live_owner, clock)
/// ```
pub fn start(owner: live.Live, clock: Clock) -> Result(Queue, String) {
  start_notifying(owner, clock, fn() { Nil })
}

/// Starts an idle queue that calls `changed` each time a request ends.
///
/// The commit that makes a selection durable runs inside the managed job, so
/// the call comes after the commit. It also comes after the receipt moved to
/// its terminal status, which is what a reader woken by it will look for.
///
/// ## Examples
///
/// ```gleam
/// // queue.start_notifying(live_owner, clock, fn() { publish_hint() })
/// ```
pub fn start_notifying(
  owner: live.Live,
  clock: Clock,
  changed: fn() -> Nil,
) -> Result(Queue, String) {
  actor.new_with_initialiser(5000, fn(subject) {
    let outcomes = process.new_subject()
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(outcomes, Delivered)
    actor.initialised(State(
      owner:,
      clock:,
      outcomes:,
      changed:,
      active: None,
      receipts: [],
      closing: None,
    ))
    |> actor.selecting(selector)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.on_shutdown(fn(state, _) {
    case state.active {
      None -> Nil
      Some(job) -> weft.cancel(job.cancel)
    }
  })
  |> actor.start
  |> result.map(fn(started) { Queue(started.pid, started.data) })
  |> result.map_error(string.inspect)
}

/// Enqueues one authenticated transition, deduplicated by its native signature.
/// A request must have a positive deadline no more than 120 seconds away.
///
/// ## Examples
///
/// ```gleam
/// // queue.enqueue(queue, transition, canonical_signature)
/// ```
pub fn enqueue(
  queue: Queue,
  transition: live.Transition,
  signature: String,
) -> Result(Status, String) {
  call.try_call(queue.requests, waiting: 5000, sending: Enqueue(
    transition,
    signature,
    _,
  ))
  |> result.map_error(fn(_) { "the live transition queue is unavailable" })
  |> result.flatten
}

/// Reads the current or retained terminal receipt without waiting for staging.
///
/// ## Examples
///
/// ```gleam
/// // queue.poll(queue, request_id)
/// ```
pub fn poll(
  queue: Queue,
  request_id: String,
) -> Result(Option(Status), String) {
  call.try_call(queue.requests, waiting: 5000, sending: Poll(request_id, _))
  |> result.map_error(fn(_) { "the live transition queue is unavailable" })
  |> result.flatten
}

/// Lists the transitions that are accepted and not finished.
///
/// ## Examples
///
/// ```gleam
/// // queue.pending(queue)
/// ```
pub fn pending(queue: Queue) -> Result(List(Waiting), String) {
  call.try_call(queue.requests, waiting: 5000, sending: Listing)
  |> result.map_error(fn(_) { "the live transition queue is unavailable" })
}

/// Drains the pending managed job and waits for its acknowledgement before exit.
/// Live generation custody is closed separately, after this queue has drained.
///
/// ## Examples
///
/// ```gleam
/// // queue.close(queue)
/// ```
pub fn close(queue: Queue) -> Result(Nil, String) {
  call.try_call(queue.requests, waiting: 125_000, sending: Closing)
  |> result.map_error(fn(_) { "the live transition queue did not drain" })
  |> result.flatten
}

/// Transfers the startup link after the native custody owner has retained close.
/// A session request builder may exit normally without taking the queue with it.
/// The caller must retain retirement before invoking this publication boundary.
///
/// ## Examples
///
/// ```gleam
/// // queue.detach(queue)
/// ```
pub fn detach(queue: Queue) -> Nil {
  process.unlink(queue.pid)
}

/// Handles message dispatch for the evolution transition queue actor.
fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  // Match transition queue protocol command.
  case message {
    Enqueue(transition, signature, reply) -> {
      let #(status, state) = admit(state, transition, signature)
      process.send(reply, status)
      actor.continue(state)
    }
    Poll(id, reply) -> {
      process.send(
        reply,
        Ok(option.map(receipt(state, id), fn(receipt) { receipt.status })),
      )
      actor.continue(state)
    }
    Listing(reply) -> {
      process.send(reply, waiting(state))
      actor.continue(state)
    }
    Delivered(event) -> delivered(state, event)
    Closing(reply) ->
      case state.active {
        None -> {
          process.send(reply, Ok(Nil))
          actor.stop()
        }
        Some(_job) -> {
          // Record pending reply if queue is not already draining.
          case state.closing {
            None -> actor.continue(State(..state, closing: Some(reply)))
            Some(_) -> {
              process.send(
                reply,
                Error("the transition queue is already draining"),
              )
              actor.continue(state)
            }
          }
        }
      }
  }
}

/// Admits a transition request or returns existing receipt if matching signature.
fn admit(
  state: State,
  transition: live.Transition,
  signature: String,
) -> #(Result(Status, String), State) {
  case receipt(state, transition.request_id) {
    Some(receipt) if receipt.signature == signature -> #(
      Ok(receipt.status),
      state,
    )
    Some(_) -> #(
      Error(
        "Changed: request identity already binds different transition inputs",
      ),
      state,
    )
    None -> start_job(state, transition, signature)
  }
}

/// Validates arguments and spawns background managed worker for the transition job.
fn start_job(
  state: State,
  transition: live.Transition,
  signature: String,
) -> #(Result(Status, String), State) {
  let #(now, clock) = clock.read(state.clock)
  let state = State(..state, clock:)
  let waiting = transition.expires_at - now

  // Verify that active slots are free and request parameters are bounded.
  case
    state.active,
    state.closing,
    transition.request_id != ""
    && bytes(transition.request_id) <= 256
    && signature != ""
    && bytes(signature) <= 8192
    && waiting > 0
    && waiting <= 120_000
  {
    None, None, True -> {
      let cancel = weft.cancel_signal()
      let owner = state.owner
      let run =
        weft.new_prepared([
          weft.managed(fn(_ledger) {
            case live.activate(owner, transition, waiting: waiting + 1000) {
              Ok(selection) -> Ok(selection)
              Error(refusal) -> {
                // Live retained any retirement capability before answering.
                // Adding it again would retry one original witness twice.
                Error(string.slice(store.describe(refusal), 0, 1024))
              }
            }
          }),
        ])
        |> weft.limit(1)
        |> weft.cancel_with(cancel)
        |> weft.deadline(waiting + 1500)
      let _relay = weft.start_relayed(run, to: state.outcomes)
      let receipt =
        Receipt(
          transition.request_id,
          signature,
          Running(transition.request_id),
        )
      #(
        Ok(Queued(transition.request_id)),
        State(
          ..state,
          active: Some(Job(
            receipt:,
            cancel:,
            candidate_id: transition.selection.candidate_id,
            expires_at: transition.expires_at,
          )),
        ),
      )
    }
    Some(_), _, _ -> #(
      Error("Busy: one live transition is already pending"),
      state,
    )
    _, Some(_), _ -> #(Error("Busy: the transition queue is draining"), state)
    None, None, False -> #(
      Error("Bounds: invalid request identity, signature or absolute deadline"),
      state,
    )
  }
}

/// Returns the list of transition jobs currently accepted or staging in the queue.
fn waiting(state: State) -> List(Waiting) {
  case state.active {
    Some(job) ->
      case job.receipt.status {
        Queued(_) -> [waiting_job(job, Accepted)]
        Running(_) -> [waiting_job(job, Staging)]
        Completed(_) | Failed(_) -> []
      }
    None -> []
  }
}

/// Constructs a waiting record for an active queued or running job.
fn waiting_job(job: Job, phase: Phase) -> Waiting {
  Waiting(
    request_id: job.receipt.request_id,
    phase:,
    candidate_id: job.candidate_id,
    expires_at: job.expires_at,
  )
}

/// Finds receipt by request identifier in active job or historical receipts.
fn receipt(state: State, id: String) -> Option(Receipt) {
  case state.active {
    Some(job) if job.receipt.request_id == id -> Some(job.receipt)
    None | Some(_) ->
      list.find(state.receipts, fn(receipt) { receipt.request_id == id })
      |> option.from_result
  }
}

/// Handles completion, failure, or cancellation event delivered from background worker.
fn delivered(
  state: State,
  event: weft.Pulled(record.Selection, String),
) -> actor.Next(State, Message) {
  // Match pulled worker lifecycle outcome.
  case event {
    weft.PulledOutcome(outcome) -> {
      // Convert weft worker result into evolution job status.
      let status = case outcome {
        weft.Completed(_, selection) -> Completed(selection)
        weft.Failed(_, reason) -> Failed(reason)
        weft.Crashed(..) -> Failed("the managed transition worker crashed")
        weft.Abandoned(..) | weft.NeverStarted(..) ->
          Failed("the managed transition was cancelled")
        weft.DrainProofLost(..) | weft.CancellationUnconfirmed(..) ->
          Failed("managed transition retirement is unconfirmed")
      }

      // Update active job status if job is still resident in state.
      case state.active {
        None -> actor.continue(state)
        Some(job) -> {
          let next =
            State(
              ..state,
              active: Some(Job(..job, receipt: Receipt(..job.receipt, status:))),
            )
          state.changed()
          actor.continue(next)
        }
      }
    }
    weft.AllDelivered -> finished(state)
    weft.RunLost(..) -> {
      // Mark active job failed when drain witness is lost.
      let state = case state.active {
        None -> state
        Some(job) ->
          State(
            ..state,
            active: Some(
              Job(
                ..job,
                receipt: Receipt(
                  ..job.receipt,
                  status: Failed(
                    "the managed transition's drain witness was lost",
                  ),
                ),
              ),
            ),
          )
      }

      // A lost drain witness ends the request as surely as an outcome does.
      state.changed()
      finished(state)
    }
    weft.NotYet -> actor.continue(state)
  }
}

/// Finalizes finished job into receipts history and resolves closing request if pending.
fn finished(state: State) -> actor.Next(State, Message) {
  // Archive active job receipt into history bounded to 512 entries.
  let receipts = case state.active {
    None -> state.receipts
    Some(job) -> list.take([job.receipt, ..state.receipts], 512)
  }

  // Close actor if queue closing reply was requested.
  case state.closing {
    Some(reply) -> {
      process.send(reply, Ok(Nil))
      actor.stop()
    }
    None -> actor.continue(State(..state, active: None, receipts:))
  }
}

fn bytes(text: String) -> Int {
  bit_array.byte_size(bit_array.from_string(text))
}
