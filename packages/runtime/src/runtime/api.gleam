//// The session-facing operations: open/recover, prompt, steer,
//// follow-up, abort, close.
////
//// Every admission here is a durable commit through the StorageWriter
//// plus an ephemeral doorbell (design §4.6): the payload travels in the
//// commit, the `Nudge` only wakes the strand early. The `_quietly`
//// variants commit without ringing the doorbell — schedulers (and the
//// doorbell-drop tests) rely on the strand's periodic checkpoint poll
//// finding the work anyway; a lost nudge costs latency, never data.
////
//// Abort is routed through the strand driver so the durable
//// `cancel_requested` marker serializes with the strand's own
//// transitions and live effects are cancelled by their owner; it is
//// idempotent and fire-and-forget (poll `await_idle` for the aborted
//// terminal result).
////
//// Close is a controlled crash (pi §4.7): kill the tree — commits are
//// atomic in the storage actor, so durable state stops at a commit
//// boundary — then close the storage handle, releasing the SQLite
//// writer lease. No cancellation or terminal state is written; reopening
//// the session recovers the open operation.

import core/clock
import core/ids.{type EntryId, type OpId}
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
import machine/acceptance.{type RejectReason, AcceptCtx, AcceptRun}
import machine/codec
import machine/operation.{
  type LastResult, type NormalizedRetryPolicy, type Operation,
  type OperationState, type RunSettings, CompactionSettings, ConsumeAll,
  NormalizedRetryPolicy, PendingMessage, RunSettings, Sequential,
}
import machine/queue
import machine/strand.{type StrandConfiguration, type StrandState}
import runtime/effects.{type Effects}
import runtime/strand_runtime
import runtime/supervisor.{type SessionTree, type Tolerance, Tolerance}
import runtime/writer
import session/session.{type Session}
import storage/storage

/// A live session runtime: the supervision tree plus what the operations
/// need.
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
/// Constructor invariants: `configuration` seeds the strand on first
/// open; `settings` is the run-settings snapshot captured into accepted
/// runs; `after_commit` and `subscribers` instrument the writer (see
/// `runtime/writer`); `poll_interval_ms` is the strand's checkpoint-poll
/// period.
pub type Options {
  Options(
    strand: String,
    configuration: StrandConfiguration,
    settings: RunSettings,
    retry_policy: NormalizedRetryPolicy,
    stream_options: JsonValue,
    poll_interval_ms: Int,
    tolerance: Tolerance,
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
}

/// Opens (or recovers) a session runtime: seeds the strand's registers if
/// this is a fresh session, then boots the supervision tree. A restored
/// open operation resumes driving immediately — open and recover are the
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
    use leaf <- result.try(read_leaf(runtime))
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

/// Rings the strand's doorbell.
///
/// ## Examples
///
/// ```gleam
/// // api.nudge(runtime)
/// ```
///
pub fn nudge(runtime: Runtime) -> Nil {
  strand_runtime.nudge(process.named_subject(runtime.tree.strand))
}

/// Requests durable cancellation of the open operation and cancels live
/// effects. Fire-and-forget and idempotent; poll `await_result` for the
/// aborted terminal outcome.
///
/// ## Examples
///
/// ```gleam
/// // api.abort(runtime)
/// ```
///
pub fn abort(runtime: Runtime) -> Nil {
  strand_runtime.request_abort(process.named_subject(runtime.tree.strand))
}

/// Closes the runtime: kills the tree (a controlled crash — durable
/// state stops at a commit boundary) and closes the storage handle,
/// releasing the writer lease. The session can be reopened from its file
/// and will recover any open operation.
///
/// ## Examples
///
/// ```gleam
/// // api.close(runtime)
/// ```
///
pub fn close(runtime: Runtime) -> Result(Nil, storage.StorageError) {
  process.kill(runtime.tree.supervisor)
  wait_for_death(runtime.tree.supervisor, 100)
  session.close(runtime.session)
}

fn wait_for_death(pid: process.Pid, attempts: Int) -> Nil {
  case attempts <= 0 || !process.is_alive(pid) {
    True -> Nil
    False -> {
      process.sleep(5)
      wait_for_death(pid, attempts - 1)
    }
  }
}

/// Polls (reading the session store directly, so it survives tree
/// restarts) until the named operation's terminal result is recorded,
/// returning it. `Error(Nil)` on timeout.
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
  case session.last_result(runtime.session, runtime.strand) {
    Ok(Some(session.Cell(value: last, ..))) ->
      case result_operation(last) == operation {
        True -> Ok(last)
        False -> await_result_wait(runtime, operation, timeout_ms)
      }
    _ -> await_result_wait(runtime, operation, timeout_ms)
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

fn result_operation(last: LastResult) -> OpId {
  case last {
    operation.RunLastResult(operation:, ..) -> operation
    operation.CompactionLastResult(operation:, ..) -> operation
    operation.NavigationLastResult(operation:, ..) -> operation
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

fn read_leaf(runtime: Runtime) -> Result(Option(EntryId), ApiError) {
  let w = writer_subject(runtime)
  case writer.get_register(w, register.StrandLeaf, runtime.strand) {
    Error(error) -> Error(ReadFailed(reason: describe_storage(error)))
    Ok(None) -> Ok(None)
    Ok(Some(storage.Register(value:, ..))) ->
      case register.read_leaf(value) {
        Ok(leaf) -> Ok(leaf)
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
