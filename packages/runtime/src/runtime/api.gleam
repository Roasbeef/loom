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
import core/ids.{type EntryId, type OpId, type Seq}
import core/json.{type JsonValue}
import core/message.{type AgentMessage}
import core/register
import core/tx.{type CommitError}
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import machine/acceptance.{type RejectReason, AcceptCtx, AcceptRun, StrandBusy}
import machine/codec
import machine/operation.{
  type LastResult, type NormalizedRetryPolicy, type Operation,
  type OperationState, type RunSettings, CompactionSettings, ConsumeAll,
  NormalizedRetryPolicy, PendingMessage, RunSettings, Sequential,
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

/// A live session runtime: the supervision tree plus what the operations
/// need. `strand` is the strand this handle currently addresses
/// (`on_strand` rebinds it).
pub type Runtime {
  Runtime(
    tree: SessionTree,
    session: Session,
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
  )
}

/// Sensible defaults: strand `"main"`, sequential tools, consume-all
/// queues, compaction off, three attempts with a 100 ms base backoff, a
/// 200 ms checkpoint poll, and a conservative restart tolerance.
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
      tool_execution: Sequential,
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
  case session.ensure_strand(session, options.strand, options.configuration) {
    Error(error) -> Error(describe_session_error(error))
    Ok(Nil) -> {
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
          ),
          tolerance: options.tolerance,
          subagent: options.subagent,
          subagent_tolerance: options.subagent_tolerance,
        )
      case supervisor.start(config) {
        Ok(tree) ->
          Ok(Runtime(
            tree:,
            session:,
            effects:,
            strand: options.strand,
            settings: options.settings,
          ))
        Error(error) -> Error(describe_start_error(error))
      }
    }
  }
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
    case acceptance.accept_prompt(AcceptRun(prompts:), ctx) {
      Error(reason) -> Ok(Done(Error(AcceptRejected(reason:))))
      Ok(acceptance.AcceptancePlan(operation:, state: _, tx: plan_tx)) ->
        case writer.commit(w, plan_tx) {
          Ok(_) -> Ok(Done(Ok(operation.id)))
          Error(tx.StaleExpectation(..)) -> Ok(Retry)
          Error(error) -> Ok(Done(Error(CommitFailed(error:))))
        }
    }
  })
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
  enqueue(runtime, message, queue.enqueue_steer)
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
  use entry <- result.map(enqueue(runtime, message, queue.enqueue_follow_up))
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
        case
          admit(op, op_state, op_state_seq, generator, PendingMessage(message:))
        {
          Error(reason) -> Ok(Done(Error(QueueRejected(reason:))))
          Ok(queue.QueuePlan(entry:, next: _, tx: plan_tx)) ->
            case writer.commit(w, plan_tx) {
              Ok(_) -> Ok(Done(Ok(entry)))
              Error(tx.StaleExpectation(..)) -> Ok(Retry)
              Error(error) -> Ok(Done(Error(CommitFailed(error:))))
            }
        }
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
  case live_strand_subject(runtime) {
    Ok(subject) -> strand_runtime.nudge(subject)
    // No driver registered (mid-restart): loss is harmless — the
    // checkpoint poll finds the durable work.
    Error(Nil) -> Nil
  }
}

// The addressed strand's driver subject, only while a live process is
// registered under its name: sending into an unregistered name would
// crash the sender, and every message the api rings is loss-tolerant.
fn live_strand_subject(
  runtime: Runtime,
) -> Result(Subject(strand_runtime.Message), Nil) {
  case supervisor.strand_subject(runtime.tree, runtime.strand) {
    Error(Nil) -> Error(Nil)
    Ok(subject) ->
      case process.subject_owner(subject) {
        Ok(pid) ->
          case process.is_alive(pid) {
            True -> Ok(subject)
            False -> Error(Nil)
          }
        Error(Nil) -> Error(Nil)
      }
  }
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
  case live_strand_subject(runtime) {
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
/// The lease release does not depend on the shutdown succeeding: a tree
/// that will not stop inside `close_grace_ms` is killed and the handle
/// is closed regardless, because a session locked out for a whole lease
/// TTL is the worse failure. Callable from any process, and idempotent.
///
/// ## Examples
///
/// ```gleam
/// // api.close(runtime)
/// ```
///
pub fn close(runtime: Runtime) -> Result(Nil, storage.StorageError) {
  supervisor.shutdown(runtime.tree, grace_ms: close_grace_ms)
  session.close(runtime.session)
}

/// How long `close` lets the session tree stop before killing it. Five
/// seconds is the OTP worker default, and every child in the tree is a
/// plain actor that dies on the shutdown signal at once — the grace is
/// headroom for a busy scheduler, not an expected wait.
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
  case operation_result(runtime, operation) {
    Some(last) -> Ok(last)
    None ->
      case session.last_result(runtime.session, runtime.strand) {
        Ok(Some(session.Cell(value: last, ..))) ->
          case result_operation(last) == operation {
            True -> Ok(last)
            False -> await_result_wait(runtime, operation, timeout_ms)
          }
        _ -> await_result_wait(runtime, operation, timeout_ms)
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

fn await_result_wait(
  runtime: Runtime,
  operation: OpId,
  timeout_ms: Int,
) -> Result(LastResult, Nil) {
  case timeout_ms <= 0 {
    True -> Error(Nil)
    False -> {
      process.sleep(10)
      await_result(runtime, operation, within_ms: timeout_ms - 10)
    }
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
  use Nil <- result.try(
    supervisor.start_strand(runtime.tree, name)
    |> result.map_error(fn(error) {
      StartFailed(reason: describe_start_error(error))
    }),
  )
  let subagent = on_strand(runtime, name)
  case accept_quietly(subagent, brief) {
    Error(error) -> Error(BriefRejected(error:))
    Ok(operation) -> {
      nudge(subagent)
      Ok(operation)
    }
  }
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
    Some(entry) ->
      case writer.get_entries(writer_subject(runtime), [entry]) {
        Error(error) -> Error(SeedFailed(reason: describe_storage(error)))
        Ok(found) ->
          case dict.has_key(found, entry) {
            True -> Ok(Nil)
            False -> Error(UnknownForkPoint(entry:))
          }
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
  send_attempts(on_strand(runtime, target), message, 4)
}

fn send_attempts(
  target: Runtime,
  message: AgentMessage,
  attempts: Int,
) -> Result(Delivery, ApiError) {
  case attempts <= 0 {
    True -> Error(RaceLost)
    False ->
      case steer_quietly(target, message) {
        Ok(entry) -> {
          nudge(target)
          Ok(Steered(entry:))
        }
        Error(QueueRejected(reason: queue.NoActiveRun)) ->
          case accept_quietly(target, [message]) {
            Ok(operation) -> {
              nudge(target)
              Ok(Started(operation:))
            }
            // A run opened between the steer refusal and the accept:
            // try the steer again.
            Error(AcceptRejected(reason: StrandBusy)) ->
              send_attempts(target, message, attempts - 1)
            Error(error) -> Error(error)
          }
        Error(error) -> Error(error)
      }
  }
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

/// Writes one `fact.custom` cell — the shared, transactional multi-agent
/// blackboard. Keys under the reserved prefixes — see
/// `reserved_fact_key` — are refused, so no fact can forge an approval
/// record, shadow a terminal result, rewrite a parent edge in the lineage
/// ledger, or overwrite the pinned system prompt.
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
    Error(error) -> Error(CommitFailed(error:))
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
  case
    writer.list_registers(writer_subject(runtime), register.FactCustom, prefix)
  {
    Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
    Ok(cells) ->
      cells
      |> list.filter_map(fn(pair) {
        let #(key, storage.Register(value:, ..)) = pair
        case reserved_fact_key(key) {
          True -> Error(Nil)
          False -> Ok(#(key, value.payload))
        }
      })
      |> Ok
  }
}

/// The reserved `fact.custom` key prefix the assembled system prompt is
/// pinned under. Nothing in this package writes it — the prompt pack is
/// another package's work — but it is reserved here, and reserved now,
/// because the blackboard tool that could otherwise rewrite the
/// operator's channel ships in the same wave. A reservation that lands
/// after the tool that needs it is not a reservation.
pub const prompt_fact_prefix = "prompt/"

/// Whether a `fact.custom` key falls in a reserved, runtime-owned corner
/// of the namespace. Reserved keys are refused to `put_fact` and hidden
/// from `facts`; harness code reaches them through `put_reserved_fact`
/// and `reserved_facts`.
///
/// The four corners, and what each would let a forged write do:
/// `escalation/` — manufacture an approval and widen a denied call;
/// `operation-result/` — shadow an operation's terminal result and lie to
/// every waiter; `lineage/` — rewrite a parent edge, which is the single
/// assumption the wait graph's acyclicity rests on; `prompt/` — rewrite
/// the operator's channel.
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
  case reserved_fact_key(prefix) {
    False -> Error(UnreservedFactKey(key: prefix))
    True ->
      case
        writer.list_registers(
          writer_subject(runtime),
          register.FactCustom,
          Some(prefix),
        )
      {
        Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
        Ok(cells) ->
          cells
          |> list.map(fn(pair) {
            let #(key, storage.Register(value:, ..)) = pair
            #(key, value.payload)
          })
          |> Ok
      }
  }
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
  commit_raised(runtime, id, escalation.raised(id, denial, Some(scope)))
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
  commit_raised(runtime, id, escalation.raised(id, denial, None))
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
    Error(error) -> Error(CommitFailed(error:))
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
  case
    writer.list_registers(
      writer_subject(runtime),
      register.FactCustom,
      Some(escalation.key_prefix),
    )
  {
    Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
    Ok(cells) ->
      cells
      |> list.try_map(fn(pair) {
        let #(_key, storage.Register(value:, ..)) = pair
        case escalation.decode(value.payload) {
          Ok(record) -> Ok(record)
          Error(report) -> Error(ReadFailed(reason: report.boundary))
        }
      })
  }
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
    case escalation.may_become(record.status, to) {
      False ->
        Ok(Done(Error(EscalationWrongStatus(id:, status: record.status))))
      True -> {
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
            expected: [
              tx.Expect(ns: register.FactCustom, key:, seq: Some(seq)),
            ],
          )
        case writer.commit(writer_subject(runtime), plan_tx) {
          Ok(_) -> Ok(Done(Ok(next)))
          Error(tx.StaleExpectation(..)) -> Ok(Retry)
          Error(error) -> Ok(Done(Error(CommitFailed(error:))))
        }
      }
    }
  })
}

fn read_escalation(
  runtime: Runtime,
  id: String,
) -> Result(#(Seq, Escalation), ApiError) {
  let key = escalation.register_key(id)
  case writer.get_register(writer_subject(runtime), register.FactCustom, key) {
    Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
    Ok(None) -> Error(EscalationNotFound(id:))
    Ok(Some(storage.Register(value:, seq:))) ->
      case escalation.decode(value.payload) {
        Ok(record) -> Ok(#(seq, record))
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

fn retry_admission(
  attempts: Int,
  attempt: fn() -> Attempt(value),
) -> Result(value, ApiError) {
  case attempts <= 0 {
    True -> Error(RaceLost)
    False ->
      case attempt() {
        Done(outcome) -> outcome
        Retry -> retry_admission(attempts - 1, attempt)
      }
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
  case writer.get_register(w, register.StrandLeaf, runtime.strand) {
    Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
    Ok(None) -> Ok(#(None, None))
    Ok(Some(storage.Register(value:, seq:))) ->
      case register.read_leaf(value) {
        Ok(leaf) -> Ok(#(Some(seq), leaf))
        Error(report) -> Error(ReadFailed(reason: report.boundary))
      }
  }
}

fn read_pending(
  runtime: Runtime,
) -> Result(dict.Dict(String, operation.PendingEntry), ApiError) {
  let w = writer_subject(runtime)
  case writer.list_registers(w, register.PendingEntry, None) {
    Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
    Ok(cells) ->
      cells
      |> list.try_map(fn(pair) {
        let #(key, storage.Register(value:, ..)) = pair
        case codec.decode_pending_entry(value.payload) {
          Ok(pending) -> Ok(#(key, pending))
          Error(report) -> Error(ReadFailed(reason: report.boundary))
        }
      })
      |> result.map(dict.from_list)
  }
}

fn read_decoded(
  runtime: Runtime,
  ns: register.RegisterNs,
  key: String,
  decode: fn(json.JsonValue) -> Result(payload, corruption_report),
) -> Result(Option(#(Int, payload)), String) {
  let w = writer_subject(runtime)
  case writer.get_register(w, ns, key) {
    Error(error) -> Error(describe_storage(error))
    Ok(None) -> Ok(None)
    Ok(Some(storage.Register(value:, seq:))) ->
      case decode(value.payload) {
        Ok(payload) -> Ok(Some(#(seq, payload)))
        Error(_report) ->
          Error("a stored register payload failed to decode: " <> key)
      }
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
