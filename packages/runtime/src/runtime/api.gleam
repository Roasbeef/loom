//// The session-facing operations: open/recover, prompt, steer,
//// follow-up, abort, close — plus the multi-strand surface (create a
//// subagent strand, send between strands, await another strand's
//// result), the `fact.*` blackboard, and durable escalation decisions.
////
//// Every admission here is a durable commit through the StorageWriter
//// plus an ephemeral doorbell (design §4.6): the payload travels in the
//// commit, the `Nudge` only wakes the strand early. The `_quietly`
//// variants commit without ringing the doorbell — schedulers (and the
//// doorbell-drop tests) rely on the strand's periodic checkpoint poll
//// finding the work anyway; a lost nudge costs latency, never data.
////
//// A `Runtime` addresses one strand at a time (`Runtime.strand`);
//// `on_strand` rebinds the same tree to a sibling strand, so every
//// operation here works for subagents too. Subagents are strands
//// (design §4.2): same tree, own leaf register, own durable
//// configuration; `create_strand` seeds those registers (fork-in-place
//// at a chosen entry), starts the driver under the existing
//// StrandSupervisor, and accepts a task-brief run. Inter-strand
//// messaging is the queue machinery: `send_to_strand` durably enqueues a
//// steer onto the target's open run — or accepts a fresh run when the
//// target is idle — then rings its doorbell.
////
//// Abort is routed through the strand driver so the durable
//// `cancel_requested` marker serializes with the strand's own
//// transitions and live effects are cancelled by their owner; it is
//// idempotent and fire-and-forget (poll `await_result` for the aborted
//// terminal result).
////
//// Close is a controlled crash (pi §4.7): kill the tree — commits are
//// atomic in the storage actor, so durable state stops at a commit
//// boundary — then close the storage handle, releasing the SQLite
//// writer lease. No cancellation or terminal state is written; reopening
//// the session recovers every open operation on every strand (the
//// strand booter reads the strand set from the `strand.*` registers).

import core/clock
import core/ids.{type EntryId, type OpId, type Seq, type SessionId}
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import core/register
import core/tx.{type CommitError}
import gleam/bool
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import machine/acceptance.{
  type RejectReason, AcceptCompaction, AcceptCtx, AcceptNavigation, AcceptRun,
  StrandBusy,
}
import machine/codec
import machine/operation.{
  type LastResult, type NormalizedRetryPolicy, type Operation,
  type OperationState, type RunSettings, type StructuralPreparation,
  CompactionSettings, ConsumeAll, NormalizedRetryPolicy, Parallel,
  PendingMessage, RunSettings,
}
import machine/queue
import machine/strand.{type StrandConfiguration, type StrandState}
import runtime/effects.{type Effects}
import runtime/escalation.{type Escalation}
import runtime/lineage
import runtime/strand_runtime
import runtime/supervisor.{type SessionTree, type Tolerance, Tolerance}
import runtime/writer
import session/session.{type Session}
import storage/storage
import telemetry/log.{type Logger}
import weft/poll

/// One blackboard cell as a compare-and-set caller sees it: the stored
/// value and the seq of the write that put it there, which is what
/// `put_fact_expecting` asserts against.
pub type FactCell {
  FactCell(value: JsonValue, seq: Seq)
}

/// One durable escalation record as a compare-and-set caller sees it:
/// the decoded record and the seq of the write that put it there, which
/// is what `consume_escalation_at` asserts against.
pub type EscalationCell {
  EscalationCell(record: Escalation, seq: Seq)
}

/// A live session runtime: the supervision tree plus what the operations
/// need. `strand` is the strand this handle currently addresses
/// (`on_strand` rebinds it).
pub type Runtime {
  Runtime(
    tree: SessionTree,
    session: Session,
    session_id: SessionId,
    effects: Effects,
    strand: String,
    settings: RunSettings,
  )
}

/// Options for `open`.
///
/// Constructor invariants: `configuration` seeds the primary strand on
/// first open; `settings` is the run-settings snapshot captured into
/// accepted runs; `after_commit` and `subscribers` instrument the writer
/// (see `runtime/writer`); `poll_interval_ms` is every strand's
/// checkpoint-poll period; `subagent` names, by strand name alone, the
/// strands that belong under the tree's second strand factory, so a
/// model-spawned strand in a crash loop cannot reboot the strand a human
/// is talking to (`runtime/supervisor`), and `subagent_tolerance` is that
/// factory's own restart budget.
pub type Options {
  Options(
    strand: String,
    configuration: StrandConfiguration,
    settings: RunSettings,
    retry_policy: NormalizedRetryPolicy,
    stream_options: JsonValue,
    poll_interval_ms: Int,
    tolerance: Tolerance,
    subagent: fn(String) -> Bool,
    subagent_tolerance: Tolerance,
    after_commit: fn(Int) -> Nil,
    subscribers: List(Subject(writer.Event)),
    /// Where this session's strands log. Injected per §0.2 so a test
    /// captures records instead of emitting them; `log.discard()` is
    /// the default, so a runtime nobody configured is silent.
    logger: Logger,
  )
}

/// Sensible defaults: strand `"main"`, parallel tools, consume-all
/// queues, compaction off, three attempts with a 100 ms base backoff, a
/// 200 ms checkpoint poll, and a conservative restart tolerance.
///
/// `tool_execution: Parallel` is the default because a batch the model
/// issued as one batch is a batch it expects to run as one: under
/// `Sequential` a fan-out of five reads is five round trips through the
/// jail, in source order, for no correctness the parallel path does not
/// already provide. Overlap is still gated twice below this setting —
/// an `Exclusive` tool runs alone (`runtime/strand_runtime.tool_may_start`)
/// and the broker pools one budget ledger per `{op_id, step_id}` — and
/// tree materialization stays source-ordered whatever order effects
/// settle in. A host that wants the old behaviour sets `Sequential`
/// here, or the session sets the `tool_execution` config key.
///
/// ## Examples
///
/// ```gleam
/// // api.default_options(configuration)
/// ```
///
pub fn default_options(configuration: StrandConfiguration) -> Options {
  Options(
    strand: "main",
    configuration:,
    settings: RunSettings(
      compaction: CompactionSettings(
        enabled: False,
        reserve_tokens: 0,
        keep_recent_tokens: 0,
      ),
      steering_mode: ConsumeAll,
      follow_up_mode: ConsumeAll,
      tool_execution: Parallel,
    ),
    retry_policy: NormalizedRetryPolicy(max_attempts: 3, base_delay_ms: 100),
    stream_options: json.Object([]),
    poll_interval_ms: 200,
    tolerance: Tolerance(intensity: 5, period: 5),
    // No strand is a subagent unless a host says so: the runtime cannot
    // tell a model-spawned strand from an operator-spawned one, and the
    // ledger that can is one layer up.
    subagent: fn(_) { False },
    subagent_tolerance: Tolerance(intensity: 5, period: 5),
    after_commit: fn(_) { Nil },
    subscribers: [],
    // Silent until a host injects a real one. A library that logged by
    // default would make every embedding test noisy and would install
    // no handler to render it.
    logger: log.discard(),
  )
}

/// Why an api operation failed.
pub type ApiError {
  /// Acceptance refused the request; nothing was written.
  AcceptRejected(reason: RejectReason)

  /// Queue admission refused (no active run); nothing was written.
  QueueRejected(reason: queue.QueueReject)

  /// A storage read or decode failed.
  ReadFailed(reason: String)

  /// The admission commit failed.
  CommitFailed(error: CommitError)

  /// Another writer holds this session's write lease, so nothing this
  /// runtime commits can land. `held_by` names the thief when the
  /// backend could see it, and is `None` when the lease row was cleared
  /// out from under the writer instead of taken.
  ///
  /// Deliberately not a `CommitFailed`: the remedy is to stop and
  /// reopen the session (the open path re-acquires or refuses loudly),
  /// never to retry, and a caller that cannot tell theft from a full
  /// disk cannot choose between them.
  SessionStolen(held_by: Option(String))

  /// The admission kept losing its seq race against the strand.
  RaceLost

  /// A fact write named a key under a reserved prefix.
  ReservedFactKey(key: String)

  /// A privileged fact operation named a key outside every reserved
  /// prefix. The two write paths are disjoint on purpose: an ordinary
  /// fact belongs to `put_fact`.
  UnreservedFactKey(key: String)

  /// An escalation with this id is already recorded.
  EscalationExists(id: String)

  /// No escalation with this id is recorded.
  EscalationNotFound(id: String)

  /// The escalation's current status does not permit the transition.
  EscalationWrongStatus(id: String, status: escalation.Status)

  /// A compare-and-set fact write lost: the cell is no longer at the seq
  /// the caller read it at, so somebody else wrote it in between. The
  /// remedy is to read again and decide again, which is the whole point
  /// of having asked.
  FactConflict(key: String)
}

/// Opens (or recovers) a session runtime: seeds the primary strand's
/// registers if this is a fresh session, then boots the supervision
/// tree, whose strand booter starts a driver for *every* strand the
/// store knows — main and subagents alike. Restored open operations
/// resume driving immediately on all of them — open and recover are the
/// same call.
///
/// ## Examples
///
/// ```gleam
/// // api.open(session, effects, api.default_options(configuration))
/// ```
///
pub fn open(
  session: Session,
  effects: Effects,
  options: Options,
) -> Result(Runtime, String) {
  use Nil <- result.try(
    session.ensure_strand(session, options.strand, options.configuration)
    |> result.map_error(describe_session_error),
  )

  // The session's own name, minted here because this is the one place
  // every session — file-backed, in-memory, forked or fresh — passes
  // through on its way up (`protocol-change/008`). Idempotent: a session
  // that already carries one hands it back and mints nothing.
  let #(now, _clock) = clock.read(effects.clock)
  use #(session_id, _generator) <- result.try(
    session.ensure_id(
      session,
      ids.generator(clock.fixed(at: now), seed: effects.entropy()),
    )
    |> result.map_error(describe_session_error),
  )
  let config =
    supervisor.Config(
      writer_options: writer.Options(
        session:,
        after_commit: options.after_commit,
        subscribers: options.subscribers,
      ),
      strand_options: strand_runtime.Options(
        // Replaced by supervisor.start with the real writer name.
        writer: process.new_name(prefix: "loom_writer_placeholder"),
        strand: options.strand,
        effects:,
        stream_options: options.stream_options,
        retry_policy: options.retry_policy,
        poll_interval_ms: options.poll_interval_ms,
        claim_reaper: fn(_strand, _reaper) { [] },
        logger: options.logger,
      ),
      tolerance: options.tolerance,
      subagent: options.subagent,
      subagent_tolerance: options.subagent_tolerance,
    )
  use tree <- result.try(
    supervisor.start(config) |> result.map_error(describe_start_error),
  )
  Ok(Runtime(
    tree:,
    session:,
    session_id:,
    effects:,
    strand: options.strand,
    settings: options.settings,
  ))
}

/// This session's canonical id (`protocol-change/008`), minted by `open`
/// on a session that had none and read back on every later open. It is
/// what the event bus keys by and what a forked session records as its
/// parent; the client protocol's session *name* is a separate,
/// caller-facing thing.
///
/// ## Examples
///
/// ```gleam
/// // ids.session_id_to_string(api.session_id(runtime))
/// ```
///
pub fn session_id(runtime: Runtime) -> SessionId {
  runtime.session_id
}

/// The same runtime handle addressing a sibling strand: every operation
/// on the returned handle (prompt, steer, abort, await_result, ...)
/// targets `strand`.
///
/// ## Examples
///
/// ```gleam
/// // api.steer(api.on_strand(runtime, "sub:1"), message)
/// ```
///
pub fn on_strand(runtime: Runtime, strand: String) -> Runtime {
  Runtime(..runtime, strand:)
}

/// Accepts a prompt and rings the doorbell: the ordinary way to start a
/// run.
///
/// ## Examples
///
/// ```gleam
/// // api.prompt(runtime, [user_message])
/// ```
///
pub fn prompt(
  runtime: Runtime,
  prompts: List(AgentMessage),
) -> Result(OpId, ApiError) {
  use operation <- result.map(accept_quietly(runtime, prompts))
  nudge(runtime)
  operation
}

/// Accepts a prompt without ringing the doorbell. The run is durably
/// open; the strand's next checkpoint poll picks it up. For schedulers
/// and doorbell-loss testing.
///
/// ## Examples
///
/// ```gleam
/// // api.accept_quietly(runtime, [user_message])
/// ```
///
pub fn accept_quietly(
  runtime: Runtime,
  prompts: List(AgentMessage),
) -> Result(OpId, ApiError) {
  accept_request(runtime, AcceptRun(prompts:), None)
}

/// Accepts a fresh run and stakes a reserved claim in one transaction:
/// either the idle strand opens *and* the mark cell lands, or neither
/// does.
///
/// The same argument as `steer_marking`, applied to the other admission
/// door: an injector that must act at most once cannot make "the run
/// opened" and "the claim is spent" two separate commits, because
/// whichever one lands first leaves a window where a crash — or a
/// concurrent retry — repeats or loses the injection. Folding the mark
/// into the acceptance's own transaction removes that window; a
/// restarted caller that re-derives the same decision meets
/// `FactConflict` instead of opening a second run.
///
/// This is a building block, not the primary entry point: it does not
/// attempt a steer first, so `send_to_strand_marking` — the steer-then-
/// accept reconciliation — is the door most callers want; call this
/// directly only when the caller already knows the strand is idle. It
/// guards the reserved-key requirement itself, like `steer_marking`,
/// rather than trusting a caller to have checked: cheap here, and a
/// building block is exactly the shape that gets a second caller later
/// who forgets to.
///
/// ## Examples
///
/// ```gleam
/// // api.accept_quietly_marking(runtime, [user_message],
/// //   api.Mark(key: "rule/fired/main/x", value: json.Null))
/// ```
///
pub fn accept_quietly_marking(
  runtime: Runtime,
  prompts: List(AgentMessage),
  mark: Mark,
) -> Result(OpId, ApiError) {
  use <- bool.guard(
    when: !reserved_fact_key(mark.key),
    return: Error(UnreservedFactKey(key: mark.key)),
  )
  accept_request(runtime, AcceptRun(prompts:), Some(mark))
}

/// Accepts a standalone compaction and rings the doorbell. `preparation`
/// is the same builder the threshold and overflow hooks use
/// (`runtime/hooks.preparation`), run against the strand's current
/// projection, so a manual compaction cuts exactly where an automatic
/// one would.
///
/// ## Examples
///
/// ```gleam
/// // api.compact(runtime, custom_instructions: None, preparation: prep)
/// ```
///
pub fn compact(
  runtime: Runtime,
  custom_instructions custom_instructions: Option(String),
  preparation preparation: Option(StructuralPreparation),
) -> Result(OpId, ApiError) {
  accept_request(
    runtime,
    AcceptCompaction(custom_instructions:, preparation:),
    None,
  )
}

/// Accepts a navigation request and rings the doorbell: moves the
/// strand's leaf to `to` (the root when `None`), optionally summarizing
/// the span the move skips over. Whether `to` names a real entry is
/// answered here — `machine/acceptance` cannot read the tree — so no
/// caller needs its own tree lookup to build the request.
///
/// ## Examples
///
/// ```gleam
/// // api.navigate(runtime, to: Some(target), summarize: False, label: None,
/// //   custom_instructions: None, preparation: None)
/// ```
///
pub fn navigate(
  runtime: Runtime,
  to to: Option(EntryId),
  summarize summarize: Bool,
  label label: Option(String),
  custom_instructions custom_instructions: Option(String),
  preparation preparation: Option(StructuralPreparation),
) -> Result(OpId, ApiError) {
  use target_known <- result.try(target_exists(runtime, to))
  accept_request(
    runtime,
    AcceptNavigation(
      target: to,
      summarize:,
      label:,
      custom_instructions:,
      preparation:,
      target_known:,
    ),
    None,
  )
}

// The retry-admission body shared by every acceptance: read the
// serialization line (strand state, leaf, pending queue), build the
// request's plan against it, commit, and reload-and-retry on nothing but
// a lost seq race. `accept_quietly`, `compact`, and `navigate` differ
// only in which `AcceptRequest` they hand this; `accept_quietly_marking`
// is the one caller that hands a `Some(mark)` — the rest pass `None`,
// under which `marked`/`commit_admission` degrade to the plain
// `commit_or_retry` this always did.
fn accept_request(
  runtime: Runtime,
  request: acceptance.AcceptRequest,
  mark: Option(Mark),
) -> Result(OpId, ApiError) {
  retry_admission(4, fn() {
    use <- attempt
    let w = writer_subject(runtime)
    use #(strand_state_seq, strand_state) <- result.try(read_strand_state(
      runtime,
    ))
    use #(leaf_seq, leaf) <- result.try(read_leaf(runtime))
    use pending <- result.try(read_pending(runtime))
    let #(now, generator) = mint_context(runtime)
    let ctx =
      AcceptCtx(
        strand: runtime.strand,
        now:,
        generator:,
        strand_state:,
        strand_state_seq:,
        leaf:,
        leaf_seq:,
        settings: runtime.settings,
        pending:,
      )
    use acceptance.AcceptancePlan(operation:, state: _, tx: plan_tx) <- or_rejected(
      acceptance.accept_prompt(request, ctx),
      fn(reason) { AcceptRejected(reason:) },
    )
    commit_admission(
      writer.commit(w, marked(plan_tx, mark)),
      mark,
      on_ok: operation.id,
    )
  })
}

// Whether a non-null navigation target exists in the tree. `None` (the
// root) is always known — `accept_navigation` only consults `target_known`
// when `target` is `Some` — so this never has to ask the store for it.
fn target_exists(
  runtime: Runtime,
  target: Option(EntryId),
) -> Result(Bool, ApiError) {
  case target {
    None -> Ok(True)
    Some(entry) ->
      writer.get_entries(writer_subject(runtime), [entry])
      |> result.map(dict.has_key(_, entry))
      |> result.map_error(fn(error) {
        ReadFailed(reason: describe_storage(error))
      })
  }
}

/// Enqueues a steer item onto the open run and rings the doorbell.
///
/// ## Examples
///
/// ```gleam
/// // api.steer(runtime, user_message)
/// ```
///
pub fn steer(
  runtime: Runtime,
  message: AgentMessage,
) -> Result(EntryId, ApiError) {
  use entry <- result.map(steer_quietly(runtime, message))
  nudge(runtime)
  entry
}

/// Enqueues a steer item without the doorbell: the strand's own commits
/// (via stale expectations) or its checkpoint poll pick it up.
///
/// ## Examples
///
/// ```gleam
/// // api.steer_quietly(runtime, user_message)
/// ```
///
pub fn steer_quietly(
  runtime: Runtime,
  message: AgentMessage,
) -> Result(EntryId, ApiError) {
  enqueue(runtime, message, queue.enqueue_steer, None)
}

/// A reserved `fact.custom` cell written in the *same transaction* as a
/// queue admission, expected absent — a write-once claim.
///
/// Constructor invariants: `key` is under a reserved prefix
/// (`reserved_fact_key`), which `steer_marking` refuses otherwise. The
/// absent-expectation is the type's whole meaning: a mark guarded on a
/// seq the caller read — claim-if-unmoved rather than claim-if-first —
/// is a generalization nothing wants yet, cut rather than shipped
/// untested.
pub type Mark {
  Mark(key: String, value: JsonValue)
}

/// Enqueues a steer item and stakes a reserved claim in one transaction:
/// either the strand's open run gains the item *and* the mark cell
/// lands, or neither does.
///
/// This is the door a harness-side injector needs and `steer_quietly`
/// cannot give it. An injector that must act at most once — per strand,
/// per rule, per anything it can name a cell for — has to make "the
/// message is queued" and "the claim is spent" one durable fact, because
/// the two orders fail in opposite directions: marking first loses the
/// injection to a crash in between, and queueing first double-injects
/// after one. Folding the mark into the admission's own transaction
/// removes that window rather than narrowing it, and a restarted
/// injector that re-derives the same decision meets `FactConflict`
/// instead of queueing a second copy.
///
/// The mark's expectation is told apart from the operation-state seq the
/// admission ladder exists to retry: a lost race against the strand
/// reloads and tries again, while a mark that moved answers
/// `FactConflict` at once — somebody already did this, and no retry
/// changes that.
///
/// Quiet by design, like `steer_quietly`: an injector has no user
/// waiting on latency, and the strand's own commits and its checkpoint
/// poll find the item anyway.
///
/// ## Examples
///
/// ```gleam
/// // api.steer_marking(runtime, fenced_text,
/// //   mark: api.Mark(key: "rule/fired/main/x", value: json.Null))
/// ```
///
pub fn steer_marking(
  runtime: Runtime,
  message: AgentMessage,
  mark mark: Mark,
) -> Result(EntryId, ApiError) {
  use <- bool.guard(
    when: !reserved_fact_key(mark.key),
    return: Error(UnreservedFactKey(key: mark.key)),
  )
  enqueue(runtime, message, queue.enqueue_steer, Some(mark))
}

/// Enqueues a follow-up item onto the open run and rings the doorbell.
///
/// ## Examples
///
/// ```gleam
/// // api.follow_up(runtime, user_message)
/// ```
///
pub fn follow_up(
  runtime: Runtime,
  message: AgentMessage,
) -> Result(EntryId, ApiError) {
  use entry <- result.map(enqueue(
    runtime,
    message,
    queue.enqueue_follow_up,
    None,
  ))
  nudge(runtime)
  entry
}

fn enqueue(
  runtime: Runtime,
  message: AgentMessage,
  admit: fn(
    Operation,
    OperationState,
    Int,
    ids.Generator,
    operation.PendingEntry,
  ) -> Result(queue.QueuePlan, queue.QueueReject),
  mark: Option(Mark),
) -> Result(EntryId, ApiError) {
  retry_admission(4, fn() {
    use <- attempt
    let w = writer_subject(runtime)
    use #(_seq, strand_state) <- result.try(read_strand_state(runtime))
    case strand_state.current_operation {
      None -> Ok(Done(Error(QueueRejected(reason: queue.NoActiveRun))))
      Some(op_id) -> {
        use op <- result.try(read_op_meta(runtime, op_id))
        use #(op_state_seq, op_state) <- result.try(read_op_state(
          runtime,
          op_id,
        ))
        let #(_now, generator) = mint_context(runtime)
        use queue.QueuePlan(entry:, next: _, tx: plan_tx) <- or_rejected(
          admit(op, op_state, op_state_seq, generator, PendingMessage(message:)),
          fn(reason) { QueueRejected(reason:) },
        )

        // Only a lost seq race reloads. Every other refusal — a stolen
        // lease above all — finishes the admission: `retry_admission`
        // decrements only on `Retry`, so a `Done` here is what keeps the
        // ladder from spending its four attempts against a fence that
        // will refuse all four and then reporting `RaceLost`, which
        // would name the wrong cause. A mark's own expectation is the
        // one stale expectation that is *not* a race (see
        // `commit_admission`).
        commit_admission(
          writer.commit(w, marked(plan_tx, mark)),
          mark,
          on_ok: entry,
        )
      }
    }
  })
}

/// Rings the addressed strand's doorbell.
///
/// ## Examples
///
/// ```gleam
/// // api.nudge(runtime)
/// ```
///
pub fn nudge(runtime: Runtime) -> Nil {
  case addressed_strand_subject(runtime) {
    Ok(subject) -> strand_runtime.nudge(subject)

    // No driver registered (mid-restart): loss is harmless — the
    // checkpoint poll finds the durable work.
    Error(Nil) -> Nil
  }
}

// The stable subject is useful even while its process is restarting. The
// strand wrapper resolves it once at delivery and drops a missing name, so
// this lookup does not make a racy liveness promise of its own.
fn addressed_strand_subject(
  runtime: Runtime,
) -> Result(Subject(strand_runtime.Message), Nil) {
  supervisor.strand_subject(runtime.tree, runtime.strand)
}

/// Requests durable cancellation of the addressed strand's open
/// operation and cancels its live effects. Fire-and-forget and
/// idempotent; poll `await_result` for the aborted terminal outcome.
///
/// ## Examples
///
/// ```gleam
/// // api.abort(runtime)
/// ```
///
pub fn abort(runtime: Runtime) -> Nil {
  case addressed_strand_subject(runtime) {
    Ok(subject) -> strand_runtime.request_abort(subject)

    // No live driver (mid-restart): nothing can serialize the marker
    // right now; as with a pre-commit crash, the caller re-requests
    // (pi §4.6).
    Error(Nil) -> Nil
  }
}

/// Closes the runtime: shuts the tree down the way OTP shuts a
/// supervision tree down — strand drivers first, the writer they commit
/// through after them, everything with reason `shutdown` rather than
/// `kill` — and then closes the storage handle, releasing the writer
/// lease. Durable state stops at a commit boundary either way, because
/// commits are atomic in the storage actor; what the orderly stop adds
/// is that no strand is still running when its writer goes, and that a
/// close asked for logs no crash report.
///
/// Lease release depends on the shutdown barrier. Provider reapers may
/// deliberately outlive strand drivers while a native request drains, so
/// `close` monitors the live drain ledger before stopping the root and accepts
/// only its clean termination after every reaper is gone. A missing or
/// abnormally dead ledger returns `BackendFault` and deliberately leaves the
/// lease held. Reopening beside an unconfirmed old request would be a worse
/// failure than delayed recovery through the lease TTL.
///
/// ## Examples
///
/// ```gleam
/// // api.close(runtime)
/// ```
///
pub fn close(runtime: Runtime) -> Result(Nil, storage.StorageError) {
  use _nil <- result.try(
    supervisor.shutdown(runtime.tree, grace_ms: close_grace_ms)
    |> result.map_error(fn(_nil) {
      storage.BackendFault(
        reason: "runtime drain ledger stopped without a clean acknowledgement",
      )
    }),
  )
  session.close(runtime.session)
}

/// How long `close` lets the root acknowledge its `sys:terminate` request.
/// Provider drain after that handshake is deliberately unbounded: the writer
/// lease is not released until the teardown witness is conclusive.
pub const close_grace_ms = 5000

/// Polls (reading the session store directly, so it survives tree
/// restarts) until the named operation's terminal result is recorded,
/// returning it. `Error(Nil)` on timeout.
///
/// The wait is keyed by the *operation*, not by the strand's latest
/// result: the terminal transaction records the outcome under the
/// operation-keyed `operation-result/{op}` fact atomically with
/// `strand.last_result`, so a child that has already started (or even
/// finished) a second run cannot make the first result unobservable —
/// latest-wins overwrites the strand register, never the operation's
/// own row. The strand register is still consulted as a fallback for
/// sessions recorded before the operation-keyed row existed.
///
/// ## Examples
///
/// ```gleam
/// // api.await_result(runtime, operation, within_ms: 5000)
/// ```
///
pub fn await_result(
  runtime: Runtime,
  operation: OpId,
  within_ms timeout_ms: Int,
) -> Result(LastResult, Nil) {
  // A bounded poll in the caller's own process: the result is durable
  // state, not a message, so there is nothing to select on. The first
  // attempt is immediate and a last one is made at the deadline, so a
  // result that lands exactly as the budget runs out is still found.
  let outcome =
    poll.until(within: timeout_ms, every: 10, attempt: fn() {
      case settled_result(runtime, operation) {
        Some(last) -> poll.Done(last)
        None -> poll.Retry
      }
    })
  case outcome {
    poll.Answered(last) -> Ok(last)
    poll.Expired -> Error(Nil)

    // The probe never fails outright; the arm is exhaustiveness.
    poll.Failed(Nil) -> Error(Nil)
  }
}

// The operation's terminal record, if it has landed: the operation-keyed
// fact first, then the strand's last-result cell as a fallback, and only
// when that cell names this very operation. The fallback is not a
// substitute — an eager read would run it even when the operation-keyed
// fact already answered — so it stays behind the first miss.
fn settled_result(runtime: Runtime, operation: OpId) -> Option(LastResult) {
  case operation_result(runtime, operation) {
    Some(last) -> Some(last)
    None ->
      case session.last_result(runtime.session, runtime.strand) {
        Ok(Some(session.Cell(value: last, ..))) ->
          case result_operation(last) == operation {
            True -> Some(last)
            False -> None
          }
        _ -> None
      }
  }
}

// The operation-keyed terminal record, read straight from the session
// store (like the fallback register) so the await survives tree
// restarts. An unreadable or undecodable row reads as absent — the
// caller keeps polling and times out rather than faulting, exactly as a
// missing result behaves.
fn operation_result(runtime: Runtime, op: OpId) -> Option(LastResult) {
  let key = operation.result_fact_key(op)
  case storage.get_register(runtime.session.store, register.FactCustom, key) {
    Ok(Some(storage.Register(value:, ..))) ->
      case codec.decode_last_result(value.payload) {
        Ok(last) -> Some(last)
        Error(_report) -> None
      }
    _ -> None
  }
}

// --- multi-strand operations ----------------------------------------------

/// Why `create_strand` failed.
pub type CreateStrandError {
  /// A strand with this name already has registers in the store.
  StrandExists(name: String)

  /// The fork-point entry does not exist in the tree.
  UnknownForkPoint(entry: EntryId)

  /// Seeding the strand's registers failed.
  SeedFailed(reason: String)

  /// The strand driver could not be started.
  StartFailed(reason: String)

  /// The strand exists and its driver runs, but the task brief was not
  /// accepted.
  BriefRejected(error: ApiError)
}

/// Creates a named subagent strand: seeds its three registers durably —
/// its own model identity in `strand.config`, its own leaf register
/// seeded `at` the given entry (fork-in-place: same tree, own cursor;
/// `None` starts at the root) — starts its driver under the existing
/// StrandSupervisor, accepts `brief` as the strand's first prompt run,
/// and rings its doorbell. Returns the brief run's operation id, which
/// `await_strand_result` can wait on.
///
/// Because the registers are seeded before anything runs, recovery
/// restores the strand on every subsequent (re)boot of the tree.
///
/// ## Examples
///
/// ```gleam
/// // api.create_strand(runtime, named: "sub:1", configuration: sub_config,
/// //   at: Some(leaf), brief: [task_brief_message])
/// ```
///
pub fn create_strand(
  runtime: Runtime,
  named name: String,
  configuration configuration: StrandConfiguration,
  at fork_point: Option(EntryId),
  brief brief: List(AgentMessage),
) -> Result(OpId, CreateStrandError) {
  use Nil <- result.try(validate_fork_point(runtime, fork_point))
  use Nil <- result.try(seed_strand(runtime, name, configuration, fork_point))
  adopt_strand(runtime, named: name, brief:)
}

/// Seeds a named strand's three registers and starts its driver, exactly
/// as `create_strand` does, but accepts no brief: the strand exists and
/// sits idle until something prompts it. The `fork`/`create_strand`
/// protocol commands make strands this way — a human names or forks a
/// strand and prompts it afterward, on its own schedule.
///
/// Because no run is accepted here, `BriefRejected` can never be this
/// call's error; it still appears in `CreateStrandError` because the type
/// is shared with `create_strand`.
///
/// ## Examples
///
/// ```gleam
/// // api.create_idle_strand(runtime, named: "sub:1", configuration: config,
/// //   at: Some(fork_point))
/// ```
///
pub fn create_idle_strand(
  runtime: Runtime,
  named name: String,
  configuration configuration: StrandConfiguration,
  at fork_point: Option(EntryId),
) -> Result(Nil, CreateStrandError) {
  use Nil <- result.try(validate_fork_point(runtime, fork_point))
  use Nil <- result.try(seed_strand(runtime, name, configuration, fork_point))
  start_driver(runtime, name)
}

/// Starts the driver for an **already-seeded** strand and accepts `brief`
/// as a run on it — the second half of `create_strand`, on its own.
///
/// It exists because `create_strand` is two commits, not one: the seed
/// claims the three registers, and the brief is a separate accepted run.
/// A crash in between leaves a strand whose name is permanently claimed,
/// whose `strand.state.current_operation` is `None`, which has no
/// `last_result`, and which the booter faithfully restarts on every
/// reboot — forever, doing nothing. Nothing in `create_strand` can
/// recover that state, because re-seeding is refused as `StrandExists`.
/// This is the arm that finishes the job: `accept_quietly` brings its own
/// CAS retry ladder, so it is safe against a driver that may be
/// mid-anything, and starting a driver that is already alive is a no-op.
///
/// ## Examples
///
/// ```gleam
/// // api.adopt_strand(runtime, named: "sub:1", brief: [task_brief])
/// ```
///
pub fn adopt_strand(
  runtime: Runtime,
  named name: String,
  brief brief: List(AgentMessage),
) -> Result(OpId, CreateStrandError) {
  use Nil <- result.try(start_driver(runtime, name))
  let subagent = on_strand(runtime, name)
  case accept_quietly(subagent, brief) {
    Error(error) -> Error(BriefRejected(error:))
    Ok(operation) -> {
      nudge(subagent)
      Ok(operation)
    }
  }
}

// The driver-start half `adopt_strand` and `create_idle_strand` share:
// start (or find already alive) the named strand's driver under the
// existing StrandSupervisor.
fn start_driver(
  runtime: Runtime,
  name: String,
) -> Result(Nil, CreateStrandError) {
  supervisor.start_strand(runtime.tree, name)
  |> result.map_error(fn(error) {
    StartFailed(reason: describe_start_error(error))
  })
}

/// The operation a terminal result belongs to.
///
/// ## Examples
///
/// ```gleam
/// // api.result_operation(last) == operation
/// ```
///
pub fn result_operation(last: LastResult) -> OpId {
  case last {
    operation.RunLastResult(operation:, ..) -> operation
    operation.CompactionLastResult(operation:, ..) -> operation
    operation.NavigationLastResult(operation:, ..) -> operation
  }
}

fn validate_fork_point(
  runtime: Runtime,
  fork_point: Option(EntryId),
) -> Result(Nil, CreateStrandError) {
  case fork_point {
    None -> Ok(Nil)
    Some(entry) -> {
      use found <- result.try(
        writer.get_entries(writer_subject(runtime), [entry])
        |> result.map_error(fn(error) {
          SeedFailed(reason: describe_storage(error))
        }),
      )
      use <- bool.guard(when: dict.has_key(found, entry), return: Ok(Nil))
      Error(UnknownForkPoint(entry:))
    }
  }
}

fn seed_strand(
  runtime: Runtime,
  name: String,
  configuration: StrandConfiguration,
  fork_point: Option(EntryId),
) -> Result(Nil, CreateStrandError) {
  let seed =
    tx.Tx(
      writes: [
        tx.SetRegister(
          ns: register.StrandConfig,
          key: name,
          value: register.value(codec.encode_configuration(configuration)),
        ),
        tx.SetRegister(
          ns: register.StrandLeaf,
          key: name,
          value: register.leaf_value(fork_point),
        ),
        tx.SetRegister(
          ns: register.StrandState,
          key: name,
          value: register.value(
            codec.encode_strand_state(
              strand.StrandState(current_operation: None, pending_next_run: []),
            ),
          ),
        ),
      ],
      expected: [
        tx.Expect(ns: register.StrandConfig, key: name, seq: None),
        tx.Expect(ns: register.StrandLeaf, key: name, seq: None),
        tx.Expect(ns: register.StrandState, key: name, seq: None),
      ],
    )
  case writer.commit(writer_subject(runtime), seed) {
    Ok(_) -> Ok(Nil)
    Error(tx.StaleExpectation(..)) -> Error(StrandExists(name:))
    Error(tx.Corruption(report:)) -> Error(SeedFailed(reason: report.boundary))
    Error(tx.Faulted(reason:)) -> Error(SeedFailed(reason:))

    // `CreateStrandError` already flattens every backend refusal into a
    // reason, and its one consumer renders it as text; the distinction
    // that has to survive as a value is the one at the admission
    // surface, where a caller can act on it.
    Error(tx.LeaseLost(held_by:)) ->
      Error(SeedFailed(reason: tx.describe_lease_loss(held_by)))
  }
}

/// How a `send_to_strand` payload landed on the target.
pub type Delivery {
  /// The target had an open run: the message is a durable steer item on
  /// its queue.
  Steered(entry: EntryId)

  /// The target was idle: the message was accepted as a fresh run.
  Started(operation: OpId)
}

/// Sends a message to another strand, per the inter-agent doctrine
/// (design §4.6): the payload travels as a durable queue admission on
/// the target — a steer onto its open run, or a fresh accepted run when
/// it is idle — and the doorbell is only an ephemeral nudge whose loss
/// costs latency, never data. Peer-to-peer conversation is mutual
/// `send_to_strand`; request/reply is `create_strand` + the child's
/// terminal result via `await_strand_result`.
///
/// ## Examples
///
/// ```gleam
/// // api.send_to_strand(runtime, to: "main", message: findings)
/// ```
///
pub fn send_to_strand(
  runtime: Runtime,
  to target: String,
  message message: AgentMessage,
) -> Result(Delivery, ApiError) {
  send_attempts(on_strand(runtime, target), message, None, 4)
}

fn send_attempts(
  target: Runtime,
  message: AgentMessage,
  mark: Option(Mark),
  attempts: Int,
) -> Result(Delivery, ApiError) {
  use <- bool.guard(when: attempts <= 0, return: Error(RaceLost))
  case enqueue(target, message, queue.enqueue_steer, mark) {
    Ok(entry) -> {
      nudge(target)
      Ok(Steered(entry:))
    }
    Error(QueueRejected(reason: queue.NoActiveRun)) ->
      case accept_request(target, AcceptRun(prompts: [message]), mark) {
        Ok(operation) -> {
          nudge(target)
          Ok(Started(operation:))
        }

        // A run opened between the steer refusal and the accept: try
        // the steer again.
        Error(AcceptRejected(reason: StrandBusy)) ->
          send_attempts(target, message, mark, attempts - 1)
        Error(error) -> Error(error)
      }
    Error(error) -> Error(error)
  }
}

/// Sends a message to another strand carrying one write-once claim, so
/// whichever admission door it lands through — a steer onto an open run
/// or a fresh run on an idle strand — the mark spends atomically with
/// it. The same `send_attempts` as `send_to_strand`, with the mark
/// threaded into both doors it tries, so the steer-versus-accept
/// reconciliation exists once; the difference is entirely in *why* a
/// caller reaches for it — see `steer_marking`'s doc comment for the
/// write-once argument this applies to whichever path the message
/// actually takes.
///
/// ## Examples
///
/// ```gleam
/// // api.send_to_strand_marking(runtime, to: "main", message: findings,
/// //   mark: api.Mark(key: "rule/fired/main/x", value: json.Null))
/// ```
///
pub fn send_to_strand_marking(
  runtime: Runtime,
  to target: String,
  message message: AgentMessage,
  mark mark: Mark,
) -> Result(Delivery, ApiError) {
  use <- bool.guard(
    when: !reserved_fact_key(mark.key),
    return: Error(UnreservedFactKey(key: mark.key)),
  )
  send_attempts(on_strand(runtime, target), message, Some(mark), 4)
}

/// Awaits another strand's terminal result for `operation` — the parent
/// half of the request/reply pattern (design §4.6): the child's terminal
/// `strand.last_result` is durable, so this survives tree restarts.
///
/// ## Examples
///
/// ```gleam
/// // api.await_strand_result(runtime, "sub:1", op, within_ms: 5000)
/// ```
///
pub fn await_strand_result(
  runtime: Runtime,
  strand strand_name: String,
  operation operation: OpId,
  within_ms timeout_ms: Int,
) -> Result(LastResult, Nil) {
  await_result(on_strand(runtime, strand_name), operation, timeout_ms)
}

/// Every strand the store knows, sorted by name.
///
/// ## Examples
///
/// ```gleam
/// // api.strands(runtime) == Ok(["main", "sub:1", "sub:2"])
/// ```
///
pub fn strands(runtime: Runtime) -> Result(List(String), ApiError) {
  case
    writer.list_registers(writer_subject(runtime), register.StrandConfig, None)
  {
    Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
    Ok(cells) ->
      cells
      |> list.map(fn(pair) { pair.0 })
      |> list.sort(string.compare)
      |> Ok
  }
}

// --- the blackboard (design §4.6) ------------------------------------------

/// Writes one `fact.custom` cell — the shared multi-agent blackboard.
/// Keys under the reserved prefixes — see `reserved_fact_key` — are
/// refused, so no fact can forge an approval record, shadow a terminal
/// result, rewrite a parent edge in the lineage ledger, or overwrite the
/// pinned system prompt.
///
/// **This write is last-write-wins.** The single write is atomic and
/// journalled like any other, and that is the whole of what it
/// guarantees: two strands writing the same key overwrite each other
/// silently, and a read-modify-write — a reviewer appending to a list a
/// second reviewer is also appending to — loses one of them. It is the
/// right shape for a cell one writer owns, which is what the `agent/`
/// namespacing behind `agent_note` makes of it. A caller that needs the
/// concurrent case wants `fact_cell` and `put_fact_expecting`, which are
/// the same write with the seq it read asserted.
///
/// Registers are durable state, not a communication medium: pair a fact
/// write with a `send_to_strand` (or rely on the reader's checkpoint)
/// when the reader must act on it.
///
/// ## Examples
///
/// ```gleam
/// // api.put_fact(runtime, "review/findings", json.String("auth.gleam:42"))
/// ```
///
pub fn put_fact(
  runtime: Runtime,
  key: String,
  value: JsonValue,
) -> Result(Nil, ApiError) {
  case reserved_fact_key(key) {
    True -> Error(ReservedFactKey(key:))
    False -> commit_fact(runtime, key, value)
  }
}

/// One `fact.custom` cell with the seq of the write that put it there —
/// the read half of a compare-and-set. `None` is an absent cell, which
/// is a legitimate expectation rather than a failure: a writer that
/// means "only if nobody has written this yet" passes it straight to
/// `put_fact_expecting`.
///
/// ## Examples
///
/// ```gleam
/// // api.fact_cell(runtime, "review/findings")
/// ```
///
pub fn fact_cell(
  runtime: Runtime,
  key: String,
) -> Result(Option(FactCell), ApiError) {
  case writer.get_register(writer_subject(runtime), register.FactCustom, key) {
    Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
    Ok(None) -> Ok(None)
    Ok(Some(storage.Register(value:, seq:))) ->
      Ok(Some(FactCell(value: value.payload, seq:)))
  }
}

/// Writes one `fact.custom` cell only if it is still at the seq the
/// caller read — the compare-and-set `put_fact` is not, and the only way
/// a read-modify-write over a shared cell is expressible.
///
/// `expected` is what `fact_cell` returned: `Some(seq)` for a cell read
/// at that seq, `None` for a cell that must still be absent. A cell that
/// moved in between answers `FactConflict`, and the caller reads again
/// and decides again — a refusal it can act on, rather than a write it
/// never learns it lost. On success the new seq comes back, so a caller
/// holding a cell through several updates never has to re-read to
/// continue.
///
/// Reserved keys are refused here exactly as they are in `put_fact`:
/// this is the same door with an expectation on it, not a wider one.
///
/// ## Examples
///
/// ```gleam
/// // api.put_fact_expecting(runtime, "review/findings", value, expected: None)
/// ```
///
pub fn put_fact_expecting(
  runtime: Runtime,
  key: String,
  value: JsonValue,
  expected expected: Option(Seq),
) -> Result(Seq, ApiError) {
  use <- bool.guard(
    when: reserved_fact_key(key),
    return: Error(ReservedFactKey(key:)),
  )
  commit_fact_expecting(runtime, key, value, expected)
}

// The compare-and-set fact commit both expecting doors share. As with
// `commit_fact`, the reservation check is the caller's, and it is the
// only thing that differs between `put_fact_expecting` and
// `put_reserved_fact_expecting`.
fn commit_fact_expecting(
  runtime: Runtime,
  key: String,
  value: JsonValue,
  expected: Option(Seq),
) -> Result(Seq, ApiError) {
  let plan_tx =
    tx.Tx(
      writes: [
        tx.SetRegister(
          ns: register.FactCustom,
          key:,
          value: register.value(value),
        ),
      ],
      expected: [tx.Expect(ns: register.FactCustom, key:, seq: expected)],
    )
  case writer.commit(writer_subject(runtime), plan_tx) {
    Ok(tx.CommitResult(first_seq:, ..)) -> Ok(first_seq)
    Error(tx.StaleExpectation(..)) -> Error(FactConflict(key:))
    Error(error) -> Error(commit_failure(error))
  }
}

// The blind last-write-wins fact commit both write paths share; the
// reservation check is the caller's, and it is the only thing that
// differs between them.
fn commit_fact(
  runtime: Runtime,
  key: String,
  value: JsonValue,
) -> Result(Nil, ApiError) {
  let plan_tx =
    tx.Tx(
      writes: [
        tx.SetRegister(
          ns: register.FactCustom,
          key:,
          value: register.value(value),
        ),
      ],
      expected: [],
    )
  case writer.commit(writer_subject(runtime), plan_tx) {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(commit_failure(error))
  }
}

/// Reads one `fact.custom` cell.
///
/// ## Examples
///
/// ```gleam
/// // api.fact(runtime, "review/findings")
/// ```
///
pub fn fact(
  runtime: Runtime,
  key: String,
) -> Result(Option(JsonValue), ApiError) {
  case writer.get_register(writer_subject(runtime), register.FactCustom, key) {
    Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
    Ok(None) -> Ok(None)
    Ok(Some(storage.Register(value:, ..))) -> Ok(Some(value.payload))
  }
}

/// Lists `fact.custom` cells under an optional key prefix, excluding
/// every reserved record (`reserved_fact_key`). Harness code that owns a
/// reserved namespace reads it with `reserved_facts` instead.
///
/// ## Examples
///
/// ```gleam
/// // api.facts(runtime, prefix: Some("review/"))
/// ```
///
pub fn facts(
  runtime: Runtime,
  prefix prefix: Option(String),
) -> Result(List(#(String, JsonValue)), ApiError) {
  use cells <- result.try(
    writer.list_registers(writer_subject(runtime), register.FactCustom, prefix)
    |> result.map_error(fn(error) {
      ReadFailed(reason: describe_storage(error))
    }),
  )
  Ok(
    list.filter_map(cells, fn(pair) {
      let #(key, storage.Register(value:, ..)) = pair
      use <- bool.guard(when: reserved_fact_key(key), return: Error(Nil))
      Ok(#(key, value.payload))
    }),
  )
}

/// The reserved `fact.custom` key prefix the assembled system prompt is
/// pinned under. Nothing in this package writes it — the prompt pack is
/// another package's work — but it is reserved here, and reserved now,
/// because the blackboard tool that could otherwise rewrite the
/// operator's channel ships in the same wave. A reservation that lands
/// after the tool that needs it is not a reservation.
pub const prompt_fact_prefix = "prompt/"

/// The reserved `fact.custom` key prefix a session's own canonical
/// identity lives under — `session/id` and `session/parent`
/// (`protocol-change/008`). Reserved for the same reason as the others:
/// the id is what the event bus keys by and what a forked session records
/// as its parent, so a model-supplied `put_fact` that could rewrite it
/// could re-point a session's whole event stream.
pub const session_fact_prefix = "session/"

/// The reserved `fact.custom` key prefix triggered project rules keep
/// their durable state under: one write-once fired-mark per
/// `{strand, rule}`, and one scan-cursor checkpoint per strand
/// (`client/rules` builds both keys). The rule *text* is never here —
/// rules are operator configuration read from `loom.toml`, and the only
/// thing that has to survive a crash is what already fired.
///
/// `rule/` rather than anything near the model-writable `agent/`, for
/// the reason `lineage/` is not either: a fired-mark a model could write
/// would let it silence a project rule before the scanner ever fires it,
/// and a fired-mark it could *delete* would let it re-arm one into an
/// injection loop. Neither is reachable — `put_fact` refuses the prefix
/// and `facts` hides it — so the mark means what the scanner wrote.
pub const rule_fact_prefix = "rule/"

/// The reserved `fact.custom` key prefix scheduled heartbeats keep their
/// durable state under. Two corners of it, disjoint by a second path
/// segment (`client/schedule` builds both keys): `schedule/fired/…`, one
/// write-once fired-mark per `{strand, schedule, occurrence}`, which is
/// the only thing an operator's `[[schedule]]` needs to survive a crash
/// or a restart; and `schedule/config/…`, one cell per schedule the
/// model created for itself through the tool seam, claimed on its
/// absence and deleted outright when it is cancelled. An operator's
/// schedules are never
/// stored — they are read from `loom.toml` at boot, exactly as rules
/// are.
///
/// Disjoint from `rule_fact_prefix` on purpose, per the same reasoning
/// that keeps `lineage/` two letters from the model-writable `agent/`
/// rather than folded into an existing prefix: a namespace holding a
/// security-relevant write-once mark earns its own corner rather than
/// sharing one with a mechanically similar but distinct feature, so
/// neither can be mistaken for the other's key shape. What a forged write
/// here would let a model do is the same shape of harm `rule/` guards
/// against: mark an occurrence as already fired so a heartbeat the
/// operator configured never fires (and, for a `wake = true` schedule,
/// never wakes the strand it was meant to check on).
pub const schedule_fact_prefix = "schedule/"

/// The reserved `fact.custom` key prefix an installed extension's durable
/// memory lives under: one latest-wins cell per `ext/<extension>/<key>`,
/// written and read through the `ext.remember` and `ext.recall` arms of
/// the extension seam (`client/extension/memory`).
///
/// The whole prefix is reserved rather than one corner of it, and the
/// extension's own name is the second segment, so the seam — which binds
/// that segment from the install record and never from the request — is
/// the only thing that can say which subtree a call touches. Two
/// properties follow, and neither survives leaving the namespace
/// model-writable. A model that could `put_fact` here could **forge** an
/// extension's memory: an extension that remembers "this operator
/// approved the wide policy" and reads it back next turn would read what
/// the model wrote. And a model that could `facts` here could **read**
/// one: an extension's memory is deliberately never sent to the model
/// unless the extension injects it, which a listing that included these
/// cells would quietly undo.
///
/// One extension cannot reach another's subtree for the same reason the
/// model cannot reach either: the key a cell is written under is composed
/// on the harness side from the installed record's name.
pub const ext_fact_prefix = "ext/"

/// Whether a `fact.custom` key falls in a reserved, runtime-owned corner
/// of the namespace. Reserved keys are refused to `put_fact` and hidden
/// from `facts`; harness code reaches them through `put_reserved_fact`
/// and `reserved_facts`.
///
/// The eight corners, and what each would let a forged write do:
/// `escalation/` — manufacture an approval and widen a denied call;
/// `operation-result/` — shadow an operation's terminal result and lie to
/// every waiter; `lineage/` — rewrite a parent edge, which is the single
/// assumption the wait graph's acyclicity rests on; `prompt/` — rewrite
/// the operator's channel; `session/` — re-point the session's own
/// identity, and with it every stream keyed by it; `rule/` — mark an
/// operator's project rule as already fired, so it never fires;
/// `schedule/` — mark a scheduled heartbeat's occurrence as already
/// fired, so it never fires either; `ext/` — forge or read an installed
/// extension's durable memory, which is the one durable thing an
/// out-of-tree extension owns.
///
/// ## Examples
///
/// ```gleam
/// assert api.reserved_fact_key("lineage/sub:1")
/// ```
///
/// ```gleam
/// assert !api.reserved_fact_key("agent/main/finding")
/// ```
///
pub fn reserved_fact_key(key: String) -> Bool {
  string.starts_with(key, escalation.key_prefix)
  || string.starts_with(key, operation.result_fact_prefix)
  || string.starts_with(key, lineage.key_prefix)
  || string.starts_with(key, prompt_fact_prefix)
  || string.starts_with(key, session_fact_prefix)
  || string.starts_with(key, rule_fact_prefix)
  || string.starts_with(key, schedule_fact_prefix)
  || string.starts_with(key, ext_fact_prefix)
}

/// Writes one cell under a reserved prefix — the harness-only companion
/// to `put_fact`, which refuses exactly these keys.
///
/// The two paths are deliberately disjoint rather than one path with a
/// flag: `put_fact` is reachable from a model-supplied key and must never
/// name a reserved cell, while this one is reachable only from harness
/// code that constructs the key itself, and refuses anything *outside*
/// the reserved namespace so it can never be pressed into service as a
/// general write. A caller that wants an ordinary fact wants `put_fact`.
///
/// Like `put_fact` this is a blind last-write-wins overwrite; a caller
/// that needs a compare-and-set (a status transition, a counter) must use
/// the writer directly, as the escalation records do.
///
/// ## Examples
///
/// ```gleam
/// // api.put_reserved_fact(runtime, lineage.register_key(child), payload)
/// ```
///
pub fn put_reserved_fact(
  runtime: Runtime,
  key: String,
  value: JsonValue,
) -> Result(Nil, ApiError) {
  case reserved_fact_key(key) {
    False -> Error(UnreservedFactKey(key:))
    True -> commit_fact(runtime, key, value)
  }
}

/// Writes one reserved `fact.custom` cell only if it is still at the seq
/// the caller read — `put_fact_expecting`'s compare-and-set, on the
/// harness-only side of the reservation.
///
/// `expected` is what `fact_cell` returned, or `None` for a cell that
/// must still be absent. That second form is the one this door exists
/// for. A harness component that mints a durable record under a reserved
/// prefix — a model-created schedule's config cell, say — and must never
/// silently replace one that already exists needs "write only if nobody
/// has" to be one commit rather than a read followed by a blind write:
/// two callers racing through the gap between those two would both see
/// absence and both write, and the second would erase the first without
/// either learning it (issue #162). A cell that moved answers
/// `FactConflict`, exactly as the unreserved door does.
///
/// Unreserved keys are refused, as they are to `put_reserved_fact`: the
/// two write paths stay disjoint so neither can be pressed into service
/// as the other.
///
/// ## Examples
///
/// ```gleam
/// // api.put_reserved_fact_expecting(runtime, config_key, payload,
/// //   expected: None)
/// ```
///
pub fn put_reserved_fact_expecting(
  runtime: Runtime,
  key: String,
  value: JsonValue,
  expected expected: Option(Seq),
) -> Result(Seq, ApiError) {
  use <- bool.guard(
    when: !reserved_fact_key(key),
    return: Error(UnreservedFactKey(key:)),
  )
  commit_fact_expecting(runtime, key, value, expected)
}

/// Deletes one reserved `fact.custom` cell. Deleting a cell that is
/// already absent succeeds: the caller's intent — that the cell not exist
/// — is met either way, which is also what `core/tx.DeleteRegister`
/// promises.
///
/// The one delete door on the blackboard, and reserved-only on purpose.
/// An unreserved fact is a last-write-wins cell a model owns, and nothing
/// a model can reach should be able to make a record vanish rather than
/// change. A harness component that owns a reserved namespace, by
/// contrast, needs to retire a record without leaving a tombstone that
/// every later scan of the prefix has to read and discard (issue #164).
///
/// ## Examples
///
/// ```gleam
/// // api.delete_reserved_fact(runtime, config_key)
/// ```
///
pub fn delete_reserved_fact(
  runtime: Runtime,
  key: String,
) -> Result(Nil, ApiError) {
  use <- bool.guard(
    when: !reserved_fact_key(key),
    return: Error(UnreservedFactKey(key:)),
  )
  let plan_tx =
    tx.Tx(
      writes: [tx.DeleteRegister(ns: register.FactCustom, key:)],
      expected: [],
    )
  case writer.commit(writer_subject(runtime), plan_tx) {
    Ok(_) -> Ok(Nil)
    Error(error) -> Error(commit_failure(error))
  }
}

/// Deletes every reserved `fact.custom` cell under one prefix in a single
/// transaction, and answers how many there were.
///
/// `delete_reserved_fact` retires one record; this retires a *set* of
/// them, which is a different operation and not a loop over the first
/// one. A harness component that owns a namespace sometimes has to
/// retire everything a subject wrote there — every fired-mark of a
/// cancelled schedule, every durable trace of a strand whose run has
/// ended — and doing that one commit at a time leaves the set half
/// retired for as long as the loop takes, which is a state no reader of
/// the prefix is written to expect. One `core/tx.Tx` of
/// `DeleteRegister` writes lands all of them or none.
///
/// The count is the answer rather than `Nil` because "how much was
/// there" is the only observation a caller can make afterwards: the
/// cells are gone, so a caller that wants to log or assert what it
/// retired has nothing left to count. Zero is an ordinary answer and
/// commits nothing at all.
///
/// The prefix must itself be reserved, exactly as `reserved_facts`
/// requires, so this can never be pressed into service as a bulk delete
/// over the model-writable blackboard — where a delete door does not
/// exist at all, and deliberately (see `delete_reserved_fact`).
///
/// **A prefix is a path, and the caller owns that discipline.** This
/// door deletes what the store matches, so a prefix that stops mid-
/// segment reaches a differently-named neighbour: `schedule/fired/main`
/// would take `mainly`'s marks too. Callers here pass prefixes ending in
/// the separator (`client/schedule.strand_prefixes` is the worked
/// example) rather than relying on a check this door cannot make, since
/// only the namespace's owner knows where its segments end.
///
/// ## Examples
///
/// ```gleam
/// // api.delete_reserved_prefix(runtime, prefix: "schedule/fired/main/hb/")
/// // -> Ok(3)
/// ```
///
pub fn delete_reserved_prefix(
  runtime: Runtime,
  prefix prefix: String,
) -> Result(Int, ApiError) {
  use cells <- result.try(reserved_facts(runtime, prefix:))

  // Nothing there is success, and committing an empty transaction to
  // say so would journal a row for a decision that changed nothing.
  use <- bool.guard(when: cells == [], return: Ok(0))
  let writes =
    list.map(cells, fn(pair) {
      let #(key, _value) = pair
      tx.DeleteRegister(ns: register.FactCustom, key:)
    })
  case writer.commit(writer_subject(runtime), tx.Tx(writes:, expected: [])) {
    Ok(_result) -> Ok(list.length(cells))
    Error(error) -> Error(commit_failure(error))
  }
}

/// Lists `fact.custom` cells under one reserved prefix — the harness-only
/// read path for a namespace `facts` filters out.
///
/// Reserving a prefix hides it from `facts` as well as refusing it to
/// `put_fact`, so the ledger a reservation protects would otherwise be
/// unreadable by the very code that owns it. The singular `fact` read
/// never consulted the reservation and still does not; this is its
/// listing counterpart. `prefix` must itself be reserved, so no caller
/// can list the whole namespace through this door.
///
/// ## Examples
///
/// ```gleam
/// // api.reserved_facts(runtime, prefix: lineage.key_prefix)
/// ```
///
pub fn reserved_facts(
  runtime: Runtime,
  prefix prefix: String,
) -> Result(List(#(String, JsonValue)), ApiError) {
  use <- bool.guard(
    when: !reserved_fact_key(prefix),
    return: Error(UnreservedFactKey(key: prefix)),
  )
  use cells <- result.try(
    writer.list_registers(
      writer_subject(runtime),
      register.FactCustom,
      Some(prefix),
    )
    |> result.map_error(fn(error) {
      ReadFailed(reason: describe_storage(error))
    }),
  )
  Ok(
    list.map(cells, fn(pair) {
      let #(key, storage.Register(value:, ..)) = pair
      #(key, value.payload)
    }),
  )
}

/// The addressed strand's current leaf entry, or `None` when it sits at
/// the root of the tree. The fork point `create_strand` needs when a
/// child is to start from the caller's own conversation rather than
/// fresh.
///
/// ## Examples
///
/// ```gleam
/// // api.leaf(runtime) == Ok(option.Some(entry))
/// ```
///
pub fn leaf(runtime: Runtime) -> Result(Option(EntryId), ApiError) {
  read_leaf(runtime)
  |> result.map(fn(cell) { cell.1 })
}

// --- durable escalations (design §5.3) --------------------------------------

/// Records a raised escalation durably (status pending), attributed to
/// the exact call the denial was raised for. The denial is the broker's
/// structured denial as JSON — reason, source, and the wanted policy
/// diff — and `scope` is the call identity (`{operation, strand, step,
/// source index, call id}`) an approval will be spent on: the driver's
/// clearance path loads a grant only for the clearance whose coordinates
/// match, so approving this escalation can never widen any other call.
/// The record must be durable before the denial is surfaced for
/// decision; the gateway (WP-L) drives approve/deny.
///
/// The record names no *action*, so nothing inherits its approval on a
/// later claim and `client/escalate` will not spend it: a caller that
/// means "one re-execution of this exact call" wants `claim_escalation`,
/// which carries what the call would run. This door stays for hosts that
/// re-execute the denied action themselves, having never left it.
///
/// ## Examples
///
/// ```gleam
/// // api.raise_escalation_for(runtime, "esc-1", denial_json, scope)
/// ```
///
pub fn raise_escalation_for(
  runtime: Runtime,
  id: String,
  denial: JsonValue,
  scope scope: escalation.CallScope,
) -> Result(Nil, ApiError) {
  commit_raised(
    runtime,
    id,
    escalation.raised(id, denial, action: None, scope: Some(scope)),
  )
}

/// Records a raised escalation *and* attaches this call's claim to it —
/// the door the parking path (`client/escalate`) raises through.
///
/// The difference from `raise_escalation_for` is what happens when the
/// record is already there, which under a deterministic record id is the
/// ordinary case rather than the exception. `raise_escalation_for` is
/// write-once and answers `EscalationExists`; this one takes the claim
/// over under a CAS, so the record follows the live call:
///
/// - a **pending** record moves its scope and refreshes its stored
///   denial, action and preview — one row and one prompt for a want
///   however many times it is asked, showing what the call in hand wants
///   and what it would run;
/// - an **approved** record whose bound action is the claimant's moves
///   its scope and keeps its grants, which is what makes an approval
///   spendable at all: a model that read an in-band refusal retries
///   under a call id the provider minted after the human decided, and a
///   scope frozen to the first attempt names a call that will never come
///   back;
/// - an **approved** record bound to a *different* action re-opens as a
///   fresh pending question with no grants (#65). One record is one
///   want, and a want is not an action: the same strand, tool and policy
///   diff digest identically whatever command is behind them, so
///   inheriting on the id alone would spend a human's yes about one
///   command on another. Design §5.3 grants one re-execution of the
///   *denied action*;
/// - a **rejected** or **consumed** record re-opens as pending with no
///   grants — a new question, needing a new answer, so one approval is
///   still worth exactly one widened execution and one denial is a
///   decision about one call rather than a verdict the session cannot
///   revisit.
///
/// Every re-opening costs a human an answer, so `max_asks` bounds how
/// many questions one row may ever put. Past it the claim comes back
/// `Exhausted` with nothing written and the record left terminal, and
/// the caller settles in band — which is what the model would have seen
/// anyway.
///
/// What the claim never does is widen the record: the id is a digest of
/// `{strand, tool, wanted diff}`, so only a call wanting the same thing
/// on the same strand through the same tool can ever reach it; the
/// action must match on top of that for an approval to be inherited; and
/// the grants a claimant spends are the ones the human chose, not its
/// own. The action itself is opaque here — the runtime stores and
/// compares the string the client computed, never a tool's arguments.
///
/// ## Examples
///
/// ```gleam
/// // api.claim_escalation(rt, "esc-1", denial, action, scope, max_asks: 3)
/// ```
///
pub fn claim_escalation(
  runtime: Runtime,
  id: String,
  denial: JsonValue,
  action action: escalation.Action,
  scope scope: escalation.CallScope,
  max_asks max_asks: Int,
) -> Result(escalation.Claim, ApiError) {
  let key = escalation.register_key(id)
  retry_admission(4, fn() {
    use <- attempt
    use found <- result.try(read_escalation_cell(runtime, id))
    let #(expected, claim) = case found {
      None -> #(
        None,
        escalation.Claimed(escalation.raised(
          id,
          denial,
          action: Some(action),
          scope: Some(scope),
        )),
      )
      Some(#(seq, record)) -> #(
        Some(seq),
        escalation.claimed(record, denial, action, scope, max_asks:),
      )
    }
    case claim {
      // Nothing to commit: the row keeps the state it is in, and the
      // absence of a write is the whole of the refusal.
      escalation.Exhausted(_record) -> Ok(Done(Ok(claim)))
      escalation.Claimed(next) -> {
        let plan_tx =
          tx.Tx(
            writes: [
              tx.SetRegister(
                ns: register.FactCustom,
                key:,
                value: register.value(escalation.encode(next)),
              ),
            ],
            expected: [tx.Expect(ns: register.FactCustom, key:, seq: expected)],
          )
        commit_or_retry(
          writer.commit(writer_subject(runtime), plan_tx),
          on_ok: claim,
        )
      }
    }
  })
}

/// Whether the session holds fewer than `cap` durable escalation
/// records — asked of the register keys, decoding none of them, and
/// answered without counting past the bound.
///
/// The bounded question behind a bounded escalation set: a raiser asks
/// it before filing a record it has not filed before, so the set a tool
/// clearance and a gateway pull each scan cannot grow to the patience of
/// whoever is provoking the refusals. A *count* would be the wrong
/// question — it walks every key to answer a comparison that needs only
/// the first `cap` of them.
///
/// ## Examples
///
/// ```gleam
/// // api.escalations_below(runtime, 256) == Ok(True)
/// ```
///
pub fn escalations_below(runtime: Runtime, cap: Int) -> Result(Bool, ApiError) {
  writer.list_registers(
    writer_subject(runtime),
    register.FactCustom,
    Some(escalation.key_prefix),
  )
  |> result.map(fn(cells) { cap > 0 && list.drop(cells, cap - 1) == [] })
  |> result.map_error(fn(error) { ReadFailed(reason: describe_storage(error)) })
}

/// Records a raised escalation with no call attribution. Deliberately
/// narrow: an unscoped approval is *never* loaded by any tool clearance
/// — nothing in the session widens from it silently — and can only be
/// spent through an explicit `consume_escalation` by a host that
/// re-executes the denied action itself. Prefer `raise_escalation_for`
/// whenever the denied call's coordinates are known.
///
/// ## Examples
///
/// ```gleam
/// // api.raise_escalation(runtime, "esc-1", denial_json)
/// ```
///
pub fn raise_escalation(
  runtime: Runtime,
  id: String,
  denial: JsonValue,
) -> Result(Nil, ApiError) {
  commit_raised(
    runtime,
    id,
    escalation.raised(id, denial, action: None, scope: None),
  )
}

fn commit_raised(
  runtime: Runtime,
  id: String,
  record: Escalation,
) -> Result(Nil, ApiError) {
  let key = escalation.register_key(id)
  let plan_tx =
    tx.Tx(
      writes: [
        tx.SetRegister(
          ns: register.FactCustom,
          key:,
          value: register.value(escalation.encode(record)),
        ),
      ],
      expected: [tx.Expect(ns: register.FactCustom, key:, seq: None)],
    )
  case writer.commit(writer_subject(runtime), plan_tx) {
    Ok(_) -> Ok(Nil)
    Error(tx.StaleExpectation(..)) -> Error(EscalationExists(id:))
    Error(error) -> Error(commit_failure(error))
  }
}

/// Every durable escalation record, in key order.
///
/// ## Examples
///
/// ```gleam
/// // api.escalations(runtime)
/// ```
///
pub fn escalations(runtime: Runtime) -> Result(List(Escalation), ApiError) {
  use cells <- result.try(
    writer.list_registers(
      writer_subject(runtime),
      register.FactCustom,
      Some(escalation.key_prefix),
    )
    |> result.map_error(fn(error) {
      ReadFailed(reason: describe_storage(error))
    }),
  )
  list.try_map(cells, fn(pair) {
    let #(_key, storage.Register(value:, ..)) = pair
    escalation.decode(value.payload)
    |> result.map_error(fn(report) { ReadFailed(reason: report.boundary) })
  })
}

/// One durable escalation record by id.
///
/// The bounded point lookup the parking path polls on: a park re-reads
/// exactly the record it raised, once per slice, rather than listing and
/// decoding the whole reserved prefix to find it.
///
/// ## Examples
///
/// ```gleam
/// // api.escalation(runtime, "esc-1")
/// ```
///
pub fn escalation(
  runtime: Runtime,
  id: String,
) -> Result(Escalation, ApiError) {
  read_escalation(runtime, id)
  |> result.map(fn(found) { found.1 })
}

/// One durable escalation record with the seq of the write that put it
/// there — the read half of a compare-and-set, exactly as `fact_cell`
/// is for the blackboard.
///
/// A caller that *decides something* from a record it read must consume
/// at the seq it read, or its decision is about a record that may have
/// moved. That is the whole of #68: the parking path checks the scope
/// and the bound action against the record in hand, so a claim landing
/// between that check and the consume has to lose the commit rather than
/// pass unseen.
///
/// ## Examples
///
/// ```gleam
/// // api.escalation_cell(runtime, "esc-1")
/// ```
///
pub fn escalation_cell(
  runtime: Runtime,
  id: String,
) -> Result(EscalationCell, ApiError) {
  read_escalation(runtime, id)
  |> result.map(fn(found) {
    let #(seq, record) = found
    EscalationCell(record:, seq:)
  })
}

/// Approves a pending escalation with exactly these grants (a subset of
/// the denial's wanted diff — validated by the broker layer that raised
/// it). The clearance of the exact call the escalation was raised for —
/// and only that call — consumes the approval and carries the grants
/// into the re-execution (`ClearanceQuery.grants` → tool `Ctx.grants`):
/// one re-execution per approval, consumed by CAS *before* the grants
/// are used, so a lost race or a crash spends the approval without a
/// widened execution, never the reverse.
///
/// ## Examples
///
/// ```gleam
/// // api.approve_escalation(runtime, "esc-1", grants)
/// ```
///
pub fn approve_escalation(
  runtime: Runtime,
  id: String,
  grants: List(JsonValue),
) -> Result(Nil, ApiError) {
  decide_escalation(runtime, id, escalation.Approved, fn(record) {
    escalation.approve(record, grants)
  })
}

/// Rejects a pending escalation. No re-execution will run under its
/// wanted grants.
///
/// ## Examples
///
/// ```gleam
/// // api.deny_escalation(runtime, "esc-1")
/// ```
///
pub fn deny_escalation(runtime: Runtime, id: String) -> Result(Nil, ApiError) {
  decide_escalation(runtime, id, escalation.Rejected, escalation.reject)
}

/// Explicitly consumes an approved escalation, returning its grants —
/// for callers that re-execute outside the strand's own clearance path
/// (and the only way an *unscoped* approval can ever be spent). The
/// ordinary path is implicit: the driver consumes a scoped approval at
/// the clearance of exactly the call it was raised for, before the
/// grants are used.
///
/// This door reads the record fresh and consumes whatever it finds
/// approved, which is right for a host that holds no earlier read to
/// guard: there is no seq it could assert. A caller that decided
/// *anything* from a record it read — that its scope names this call,
/// that its action is the one in hand — must consume through
/// `consume_escalation_at` instead, so a claim landing in between loses
/// the commit rather than passing unseen.
///
/// ## Examples
///
/// ```gleam
/// // api.consume_escalation(runtime, "esc-1")
/// ```
///
pub fn consume_escalation(
  runtime: Runtime,
  id: String,
) -> Result(List(JsonValue), ApiError) {
  use record <- result.try(decide_escalation_value(
    runtime,
    id,
    escalation.Consumed,
    escalation.consume,
  ))
  Ok(record.grants)
}

/// Consumes exactly the approved escalation the caller read, CAS-guarded
/// by the seq it read it at, returning its grants (#68).
///
/// `escalate.spend` checks a record's scope and its bound action before
/// it commits, and those checks are statements about the record in the
/// cell — so the commit has to be one too. A record that moved in
/// between answers `EscalationWrongStatus` or loses the seq race and
/// finishes as `RaceLost`; either way the caller settles the call in
/// band rather than running under grants a check no longer covers. It is
/// the shape `strand_runtime.consume_escalations` has always had at the
/// driver's own clearance.
///
/// ## Examples
///
/// ```gleam
/// // api.consume_escalation_at(runtime, cell)
/// ```
///
pub fn consume_escalation_at(
  runtime: Runtime,
  cell: EscalationCell,
) -> Result(List(JsonValue), ApiError) {
  let EscalationCell(record:, seq:) = cell
  let id = record.id
  use <- bool.guard(
    when: !escalation.may_become(record.status, escalation.Consumed),
    return: Error(EscalationWrongStatus(id:, status: record.status)),
  )
  let key = escalation.register_key(id)
  let consumed = escalation.consume(record)
  let plan_tx =
    tx.Tx(
      writes: [
        tx.SetRegister(
          ns: register.FactCustom,
          key:,
          value: register.value(escalation.encode(consumed)),
        ),
      ],
      expected: [tx.Expect(ns: register.FactCustom, key:, seq: Some(seq))],
    )
  case writer.commit(writer_subject(runtime), plan_tx) {
    Ok(_) -> Ok(consumed.grants)

    // The record moved under the decision that named it. Not a retry:
    // re-reading would consume a record the caller never checked.
    Error(tx.StaleExpectation(..)) -> Error(RaceLost)
    Error(error) -> Error(commit_failure(error))
  }
}

fn decide_escalation(
  runtime: Runtime,
  id: String,
  to: escalation.Status,
  change: fn(Escalation) -> Escalation,
) -> Result(Nil, ApiError) {
  decide_escalation_value(runtime, id, to, change)
  |> result.map(fn(_record) { Nil })
}

fn decide_escalation_value(
  runtime: Runtime,
  id: String,
  to: escalation.Status,
  change: fn(Escalation) -> Escalation,
) -> Result(Escalation, ApiError) {
  retry_admission(4, fn() {
    use <- attempt
    use #(seq, record) <- result.try(read_escalation(runtime, id))
    use <- bool.guard(
      when: !escalation.may_become(record.status, to),
      return: Ok(Done(Error(EscalationWrongStatus(id:, status: record.status)))),
    )
    let key = escalation.register_key(id)
    let next = change(record)
    let plan_tx =
      tx.Tx(
        writes: [
          tx.SetRegister(
            ns: register.FactCustom,
            key:,
            value: register.value(escalation.encode(next)),
          ),
        ],
        expected: [tx.Expect(ns: register.FactCustom, key:, seq: Some(seq))],
      )
    commit_or_retry(
      writer.commit(writer_subject(runtime), plan_tx),
      on_ok: next,
    )
  })
}

fn read_escalation(
  runtime: Runtime,
  id: String,
) -> Result(#(Seq, Escalation), ApiError) {
  use found <- result.try(read_escalation_cell(runtime, id))
  option.to_result(found, EscalationNotFound(id:))
}

// The same read for the one caller that treats "no record yet" as a
// state rather than a fault: a claim writes the record when it is
// absent and takes it over when it is not.
fn read_escalation_cell(
  runtime: Runtime,
  id: String,
) -> Result(Option(#(Seq, Escalation)), ApiError) {
  let key = escalation.register_key(id)
  case writer.get_register(writer_subject(runtime), register.FactCustom, key) {
    Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
    Ok(None) -> Ok(None)
    Ok(Some(storage.Register(value:, seq:))) ->
      case escalation.decode(value.payload) {
        Ok(record) -> Ok(Some(#(seq, record)))
        Error(report) -> Error(ReadFailed(reason: report.boundary))
      }
  }
}

// --- admission plumbing ---------------------------------------------------

// One admission attempt either finishes or asks for a reload-and-retry
// (a lost seq race against the strand's own commits).
type Attempt(value) {
  Done(Result(value, ApiError))
  Retry
}

// Classifies a commit failure for a caller. Only one of them is a
// condition rather than a fault: a lost lease means another writer owns
// this session, so nothing this runtime commits can ever land and the
// remedy is to reopen (or stop), never to reload and retry. Everything
// else stays an undifferentiated `CommitFailed` on purpose — a caller
// that cannot act differently on a full disk than on a corrupt page
// gains nothing from being told which it was, and the reason string is
// there for the human.
fn commit_failure(error: CommitError) -> ApiError {
  case error {
    tx.LeaseLost(held_by:) -> SessionStolen(held_by:)
    tx.StaleExpectation(..) | tx.Corruption(..) | tx.Faulted(..) ->
      CommitFailed(error:)
  }
}

fn retry_admission(
  attempts: Int,
  attempt: fn() -> Attempt(value),
) -> Result(value, ApiError) {
  use <- bool.guard(when: attempts <= 0, return: Error(RaceLost))
  case attempt() {
    Done(outcome) -> outcome
    Retry -> retry_admission(attempts - 1, attempt)
  }
}

// Adapts a `Result`-chained attempt body: an early `ApiError` finishes
// the attempt.
fn attempt(body: fn() -> Result(Attempt(value), ApiError)) -> Attempt(value) {
  case body() {
    Ok(outcome) -> outcome
    Error(error) -> Done(Error(error))
  }
}

// Binds a step whose failure is a domain rejection rather than an
// admission fault: renders it as a *finished* attempt instead of
// propagating a bare `Result` error, so the rejection reaches the caller
// as `Done(Error(..))` rather than aborting the ladder. Mirrors
// `machine/planner`'s `or_fault` and `tools/tool`'s `or_outcome` for this
// package's `Attempt`-chained admission bodies.
fn or_rejected(
  result: Result(a, e),
  to_reason: fn(e) -> ApiError,
  then: fn(a) -> Result(Attempt(value), ApiError),
) -> Result(Attempt(value), ApiError) {
  case result {
    Ok(value) -> then(value)
    Error(error) -> Ok(Done(Error(to_reason(error))))
  }
}

// Maps a plan's commit outcome onto the admission ladder: success
// finishes the attempt with `on_ok`, a lost seq race
// (`tx.StaleExpectation`) asks `retry_admission` for another attempt, and
// any other refusal — a stolen lease above all — also finishes the
// attempt, because `retry_admission` decrements only on `Retry` and
// spending the ladder's attempts against a fence that refuses all of
// them would report `RaceLost` and name the wrong cause.
fn commit_or_retry(
  result: Result(tx.CommitResult, CommitError),
  on_ok on_ok: value,
) -> Result(Attempt(value), ApiError) {
  case result {
    Ok(_) -> Ok(Done(Ok(on_ok)))
    Error(tx.StaleExpectation(..)) -> Ok(Retry)
    Error(error) -> Ok(Done(Error(commit_failure(error))))
  }
}

// The admission plan with a `Mark` folded in: one more write and one
// more expectation, committed all-or-none with the admission itself.
// The expectation goes *first* so a storage backend that reports the
// earliest failing expectation names the mark rather than the operation
// state — the two are told apart below, and naming the interesting one
// first costs nothing.
fn marked(plan: tx.Tx, mark: Option(Mark)) -> tx.Tx {
  case mark {
    None -> plan
    Some(Mark(key:, value:)) ->
      tx.Tx(
        writes: list.append(plan.writes, [
          tx.SetRegister(
            ns: register.FactCustom,
            key:,
            value: register.value(value),
          ),
        ]),
        expected: [
          tx.Expect(ns: register.FactCustom, key:, seq: None),
          ..plan.expected
        ],
      )
  }
}

// `commit_or_retry`, with one refusal pulled out of the retry ladder: a
// stale expectation on the *mark's* cell is not a race against the
// strand, it is the answer to the question the mark asked. Retrying it
// would spend four attempts reloading operation state that was never
// the problem and then report `RaceLost`, which names the wrong cause —
// the same mistake the lease branch was written to avoid.
fn commit_admission(
  result: Result(tx.CommitResult, CommitError),
  mark: Option(Mark),
  on_ok on_ok: value,
) -> Result(Attempt(value), ApiError) {
  case conflicted_key(result, mark) {
    Some(key) -> Ok(Done(Error(FactConflict(key:))))
    None -> commit_or_retry(result, on_ok:)
  }
}

// The mark's key, when this commit failed on the mark's own expectation.
fn conflicted_key(
  result: Result(tx.CommitResult, CommitError),
  mark: Option(Mark),
) -> Option(String) {
  case result, mark {
    Error(tx.StaleExpectation(failed:)), Some(Mark(key:, ..)) ->
      case failed {
        tx.Expect(ns: register.FactCustom, key: failed_key, seq: _)
          if failed_key == key
        -> Some(key)
        tx.Expect(..) -> None
      }
    Error(tx.StaleExpectation(..)), None
    | Error(tx.Corruption(..)), Some(_)
    | Error(tx.Corruption(..)), None
    | Error(tx.Faulted(..)), Some(_)
    | Error(tx.Faulted(..)), None
    | Error(tx.LeaseLost(..)), Some(_)
    | Error(tx.LeaseLost(..)), None
    | Ok(_), Some(_)
    | Ok(_), None
    -> None
  }
}

// `use`-shaped read helpers that short-circuit an attempt.
fn read_strand_state(
  runtime: Runtime,
) -> Result(#(Int, StrandState), ApiError) {
  read_decoded(
    runtime,
    register.StrandState,
    runtime.strand,
    codec.decode_strand_state,
  )
  |> require("strand.state is missing for strand " <> runtime.strand)
}

fn read_op_meta(runtime: Runtime, op_id: OpId) -> Result(Operation, ApiError) {
  read_decoded(
    runtime,
    register.OpMeta,
    ids.op_id_to_string(op_id),
    codec.decode_operation,
  )
  |> require("op.meta is missing for the open operation")
  |> result.map(fn(cell) { cell.1 })
}

fn read_op_state(
  runtime: Runtime,
  op_id: OpId,
) -> Result(#(Int, OperationState), ApiError) {
  read_decoded(
    runtime,
    register.OpState,
    ids.op_id_to_string(op_id),
    codec.decode_state,
  )
  |> require("op.state is missing for the open operation")
}

fn require(
  read: Result(Option(value), String),
  missing: String,
) -> Result(value, ApiError) {
  case read {
    Ok(Some(value)) -> Ok(value)
    Ok(None) -> Error(ReadFailed(reason: missing))
    Error(reason) -> Error(ReadFailed(reason:))
  }
}

// The strand's leaf with the seq it was read at: `#(None, None)` when
// the register does not exist yet (an unseeded strand cannot accept, but
// the acceptance CAS then expects absence, which is still correct).
fn read_leaf(
  runtime: Runtime,
) -> Result(#(Option(Seq), Option(EntryId)), ApiError) {
  let w = writer_subject(runtime)
  use cell <- result.try(
    writer.get_register(w, register.StrandLeaf, runtime.strand)
    |> result.map_error(fn(error) {
      ReadFailed(reason: describe_storage(error))
    }),
  )
  case cell {
    None -> Ok(#(None, None))
    Some(storage.Register(value:, seq:)) ->
      register.read_leaf(value)
      |> result.map(fn(leaf) { #(Some(seq), leaf) })
      |> result.map_error(fn(report) { ReadFailed(reason: report.boundary) })
  }
}

fn read_pending(
  runtime: Runtime,
) -> Result(dict.Dict(String, operation.PendingEntry), ApiError) {
  let w = writer_subject(runtime)
  use cells <- result.try(
    writer.list_registers(w, register.PendingEntry, None)
    |> result.map_error(fn(error) {
      ReadFailed(reason: describe_storage(error))
    }),
  )
  cells
  |> list.try_map(fn(pair) {
    let #(key, storage.Register(value:, ..)) = pair
    codec.decode_pending_entry(value.payload)
    |> result.map(fn(pending) { #(key, pending) })
    |> result.map_error(fn(report) { ReadFailed(reason: report.boundary) })
  })
  |> result.map(dict.from_list)
}

fn read_decoded(
  runtime: Runtime,
  ns: register.RegisterNs,
  key: String,
  decode: fn(json.JsonValue) -> Result(payload, corruption_report),
) -> Result(Option(#(Int, payload)), String) {
  let w = writer_subject(runtime)
  use cell <- result.try(
    writer.get_register(w, ns, key) |> result.map_error(describe_storage),
  )
  case cell {
    None -> Ok(None)
    Some(storage.Register(value:, seq:)) ->
      // The message is built only on the decode failure. Concatenating
      // it eagerly would run on every successful register read, and
      // this is the drive loop's read path.
      decode(value.payload)
      |> result.map(fn(payload) { Some(#(seq, payload)) })
      |> result.map_error(fn(_) {
        "a stored register payload failed to decode: " <> key
      })
  }
}

fn mint_context(runtime: Runtime) -> #(Int, ids.Generator) {
  let #(now, _clock) = clock.read(runtime.effects.clock)
  #(now, ids.generator(clock.fixed(at: now), seed: runtime.effects.entropy()))
}

fn writer_subject(runtime: Runtime) -> Subject(writer.Message) {
  process.named_subject(runtime.tree.writer)
}

fn describe_storage(error: storage.StorageError) -> String {
  case error {
    storage.CorruptRow(report:) -> "corrupt row at " <> report.boundary
    storage.UnknownEntry(id:) -> "unknown entry " <> ids.entry_id_to_string(id)
    storage.BackendFault(reason:) -> reason
    storage.HandleClosed -> "storage handle closed"
  }
}

fn describe_session_error(error: session.SessionError) -> String {
  case error {
    session.StoreFailure(error:) -> describe_storage(error)
    session.SessionCorrupt(report:) -> "corrupt session at " <> report.boundary
  }
}

fn describe_start_error(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "supervision tree start timed out"
    actor.InitFailed(reason) -> "supervision tree start failed: " <> reason
    actor.InitExited(_) -> "supervision tree initialiser exited"
  }
}
