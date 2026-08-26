//// Queue admission, queue cancellation, and abort — pi harness spec
//// §3.11 and §4.6's durable half, transcribed.
////
//// Every queued admission mints the item's entry id and writes its
//// payload once into `pending.entry/{id}`; queue lists carry only the id.
//// The first abort commits `cancel_requested`, moving steer/follow-up
//// ids into the drained lists without deleting their payloads — they die
//// only in the terminal transaction.

import core/ids.{type EntryId, type Seq}
import core/tx.{type Tx, Tx}
import gleam/bool
import gleam/list
import machine/internal/build
import machine/operation.{
  type Control, type Inbox, type Operation, type OperationState,
  type PendingEntry, CancelRequested, CompactionState, Inbox, NavigationState,
  RunState, Running,
}
import machine/strand.{type StrandState, StrandState}

/// A computed queue admission: the reserved entry id, the next operation
/// state, and the one transaction that makes both true.
pub type QueuePlan {
  QueuePlan(entry: EntryId, next: OperationState, tx: Tx)
}

/// Why a queue admission was refused (nothing written).
pub type QueueReject {
  /// Steer and follow-up require an open run with running control.
  NoActiveRun
}

/// Enqueues a steer item onto an open run (allowed while suspended on a
/// deferred response; refused under `cancel_requested`).
///
/// ## Examples
///
/// ```gleam
/// // queue.enqueue_steer(op, run_state, seq, generator, payload)
/// //   == Ok(QueuePlan(..)) for a running run.
/// ```
///
pub fn enqueue_steer(
  op: Operation,
  state: OperationState,
  op_state_seq: Seq,
  generator: ids.Generator,
  payload: PendingEntry,
) -> Result(QueuePlan, QueueReject) {
  use inbox_update <- with_running_run(state)
  let #(entry, _generator) = ids.mint_entry(generator)
  let next =
    inbox_update(fn(inbox) {
      Inbox(..inbox, steer: list.append(inbox.steer, [entry]))
    })
  Ok(QueuePlan(
    entry:,
    next:,
    tx: Tx(
      writes: [
        build.set_pending(entry, payload),
        build.set_op_state(op.id, next),
      ],
      expected: [build.expect_op_state(op.id, op_state_seq)],
    ),
  ))
}

/// Enqueues a follow-up item onto an open run. Same admission rules as
/// steer.
///
/// ## Examples
///
/// ```gleam
/// // queue.enqueue_follow_up(op, run_state, seq, generator, payload)
/// ```
///
pub fn enqueue_follow_up(
  op: Operation,
  state: OperationState,
  op_state_seq: Seq,
  generator: ids.Generator,
  payload: PendingEntry,
) -> Result(QueuePlan, QueueReject) {
  use inbox_update <- with_running_run(state)
  let #(entry, _generator) = ids.mint_entry(generator)
  let next =
    inbox_update(fn(inbox) {
      Inbox(..inbox, follow_up: list.append(inbox.follow_up, [entry]))
    })
  Ok(QueuePlan(
    entry:,
    next:,
    tx: Tx(
      writes: [
        build.set_pending(entry, payload),
        build.set_op_state(op.id, next),
      ],
      expected: [build.expect_op_state(op.id, op_state_seq)],
    ),
  ))
}

/// Enqueues a deferred tree write onto an open run. Admitted in every run
/// control state — including suspended and cancelling — and applied
/// during reconciliation, so the write survives abort.
///
/// ## Examples
///
/// ```gleam
/// // queue.enqueue_write(op, run_state, seq, generator, payload)
/// ```
///
pub fn enqueue_write(
  op: Operation,
  state: OperationState,
  op_state_seq: Seq,
  generator: ids.Generator,
  payload: PendingEntry,
) -> Result(QueuePlan, QueueReject) {
  case state {
    RunState(control:, settings:, phase:, inbox:, latest_assistant:) -> {
      let #(entry, _generator) = ids.mint_entry(generator)
      let next =
        RunState(
          control:,
          settings:,
          phase:,
          inbox: Inbox(..inbox, writes: list.append(inbox.writes, [entry])),
          latest_assistant:,
        )
      Ok(QueuePlan(
        entry:,
        next:,
        tx: Tx(
          writes: [
            build.set_pending(entry, payload),
            build.set_op_state(op.id, next),
          ],
          expected: [build.expect_op_state(op.id, op_state_seq)],
        ),
      ))
    }
    CompactionState(..) | NavigationState(..) -> Error(NoActiveRun)
  }
}

/// Enqueues a next-run item — strand-owned, admitted in any state, never
/// starting a run.
///
/// ## Examples
///
/// ```gleam
/// // queue.enqueue_next_run("main", strand_state, seq, generator, payload)
/// ```
///
pub fn enqueue_next_run(
  strand_name: String,
  state: StrandState,
  strand_state_seq: Seq,
  generator: ids.Generator,
  payload: PendingEntry,
) -> #(EntryId, StrandState, Tx) {
  let #(entry, _generator) = ids.mint_entry(generator)
  let next =
    StrandState(
      ..state,
      pending_next_run: list.append(state.pending_next_run, [entry]),
    )
  #(
    entry,
    next,
    Tx(
      writes: [
        build.set_pending(entry, payload),
        build.set_strand_state(strand_name, next),
      ],
      expected: [build.expect_strand_state(strand_name, strand_state_seq)],
    ),
  )
}

/// The queue-cancellation verdict (pi §3.11 triage). `NotPending` covers
/// both "already consumed" and "never existed / already cancelled" —
/// distinguishing them needs an entry-existence check the caller owns.
pub type CancelOutcome {
  /// The id was pending: the plan removes it and deletes its payload.
  CancelledQueued(next: OperationState, tx: Tx)
  /// The id is in no queue list.
  NotPending
}

/// Cancels a queued run-inbox item by id.
///
/// ## Examples
///
/// ```gleam
/// // queue.cancel_queued(op, run_state, seq, id)
/// ```
///
pub fn cancel_queued(
  op: Operation,
  state: OperationState,
  op_state_seq: Seq,
  entry: EntryId,
) -> CancelOutcome {
  case state {
    RunState(control:, settings:, phase:, inbox:, latest_assistant:) -> {
      let in_queue =
        list.contains(inbox.steer, entry)
        || list.contains(inbox.follow_up, entry)
        || list.contains(inbox.writes, entry)
      use <- bool.guard(when: !in_queue, return: NotPending)
      let without = fn(items) { list.filter(items, fn(item) { item != entry }) }
      let next =
        RunState(
          control:,
          settings:,
          phase:,
          inbox: Inbox(
            steer: without(inbox.steer),
            follow_up: without(inbox.follow_up),
            writes: without(inbox.writes),
          ),
          latest_assistant:,
        )
      CancelledQueued(
        next:,
        tx: Tx(
          writes: [build.set_op_state(op.id, next), build.delete_pending(entry)],
          expected: [build.expect_op_state(op.id, op_state_seq)],
        ),
      )
    }
    CompactionState(..) | NavigationState(..) -> NotPending
  }
}

/// The strand-level next-run cancellation verdict.
pub type CancelNextRunOutcome {
  /// The id was pending: the plan removes it and deletes its payload.
  CancelledNextRun(next: StrandState, tx: Tx)
  /// The id is not in `pending_next_run`.
  NextRunNotPending
}

/// Cancels a pending next-run item by id.
///
/// ## Examples
///
/// ```gleam
/// // queue.cancel_next_run("main", strand_state, seq, id)
/// ```
///
pub fn cancel_next_run(
  strand_name: String,
  state: StrandState,
  strand_state_seq: Seq,
  entry: EntryId,
) -> CancelNextRunOutcome {
  case list.contains(state.pending_next_run, entry) {
    False -> NextRunNotPending
    True -> {
      let next =
        StrandState(
          ..state,
          pending_next_run: list.filter(state.pending_next_run, fn(item) {
            item != entry
          }),
        )
      CancelledNextRun(
        next:,
        tx: Tx(
          writes: [
            build.set_strand_state(strand_name, next),
            build.delete_pending(entry),
          ],
          expected: [build.expect_strand_state(strand_name, strand_state_seq)],
        ),
      )
    }
  }
}

/// The abort-request verdict.
pub type AbortOutcome {
  /// The first abort: commit the marker. For runs, steer and follow-up
  /// ids move into the drained lists (their payloads survive; `drained_*`
  /// name them for dereferenced reporting).
  AbortPlanned(
    next: OperationState,
    tx: Tx,
    drained_steer: List(EntryId),
    drained_follow_up: List(EntryId),
  )
  /// Cancellation was already durable; the same marker and drained
  /// payloads are reused.
  AbortAlreadyRequested(
    drained_steer: List(EntryId),
    drained_follow_up: List(EntryId),
  )
}

/// Requests durable cancellation of an open operation (pi §3.11's first
/// abort row, §4.6). Idempotent: a repeat returns the existing drained
/// ids without a write.
///
/// ## Examples
///
/// ```gleam
/// // queue.request_abort(op, state, seq, now)
/// ```
///
pub fn request_abort(
  op: Operation,
  state: OperationState,
  op_state_seq: Seq,
  now: Int,
) -> AbortOutcome {
  // `control` shares name, position, and type across every operation-state
  // variant, so it reads without first matching the variant — one
  // already-requested check for all three, instead of one per variant.
  case state.control {
    CancelRequested(drained_steer:, drained_follow_up:, ..) ->
      AbortAlreadyRequested(drained_steer:, drained_follow_up:)
    Running -> abort_running(op, state, op_state_seq, now)
  }
}

/// The first abort for each operation kind: a run's abort captures its
/// still-queued steer and follow-up ids into the marker (they survive the
/// drain; only the terminal transaction deletes them); a standalone
/// compaction or navigation drains nothing of its own.
fn abort_running(
  op: Operation,
  state: OperationState,
  op_state_seq: Seq,
  now: Int,
) -> AbortOutcome {
  case state {
    RunState(settings:, phase:, inbox:, latest_assistant:, ..) -> {
      let next =
        RunState(
          control: CancelRequested(
            requested_at: now,
            drained_steer: inbox.steer,
            drained_follow_up: inbox.follow_up,
          ),
          settings:,
          phase:,
          inbox: Inbox(..inbox, steer: [], follow_up: []),
          latest_assistant:,
        )
      AbortPlanned(
        next:,
        tx: abort_tx(op, op_state_seq, next),
        drained_steer: inbox.steer,
        drained_follow_up: inbox.follow_up,
      )
    }
    CompactionState(custom_instructions:, structural:, ..) -> {
      let next =
        CompactionState(
          control: cancelled(now),
          custom_instructions:,
          structural:,
        )
      AbortPlanned(
        next:,
        tx: abort_tx(op, op_state_seq, next),
        drained_steer: [],
        drained_follow_up: [],
      )
    }
    NavigationState(navigation:, ..) -> {
      let next = NavigationState(control: cancelled(now), navigation:)
      AbortPlanned(
        next:,
        tx: abort_tx(op, op_state_seq, next),
        drained_steer: [],
        drained_follow_up: [],
      )
    }
  }
}

fn cancelled(now: Int) -> Control {
  CancelRequested(requested_at: now, drained_steer: [], drained_follow_up: [])
}

fn abort_tx(op: Operation, op_state_seq: Seq, next: OperationState) -> Tx {
  Tx(writes: [build.set_op_state(op.id, next)], expected: [
    build.expect_op_state(op.id, op_state_seq),
  ])
}

/// A running-run guard shared by steer and follow-up admission: yields an
/// inbox rebuilder for the open run or refuses.
fn with_running_run(
  state: OperationState,
  continue: fn(fn(fn(Inbox) -> Inbox) -> OperationState) ->
    Result(QueuePlan, QueueReject),
) -> Result(QueuePlan, QueueReject) {
  case state {
    RunState(control: Running, settings:, phase:, inbox:, latest_assistant:) ->
      continue(fn(update) {
        RunState(
          control: Running,
          settings:,
          phase:,
          inbox: update(inbox),
          latest_assistant:,
        )
      })
    RunState(control: CancelRequested(..), ..)
    | CompactionState(..)
    | NavigationState(..) -> Error(NoActiveRun)
  }
}

/// Steer/follow-up payloads dereferenced for abort reporting: the caller
/// maps drained ids through its pending payloads. Provided here so the
/// reporting rule (§4.6) has one implementation.
///
/// ## Examples
///
/// ```gleam
/// // queue.drained_payloads(ids, lookup) keeps only resolvable ids.
/// ```
///
pub fn drained_payloads(
  drained: List(EntryId),
  lookup: fn(EntryId) -> Result(PendingEntry, Nil),
) -> List(PendingEntry) {
  list.filter_map(drained, lookup)
}
