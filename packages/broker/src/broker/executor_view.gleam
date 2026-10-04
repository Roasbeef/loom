//// What an operator may see of the executor service: a bounded snapshot,
//// the counters and latency summaries behind it, and the names the
//// telemetry lines use.
////
//// The service is one serial process that knows which executions a session
//// has running. When it is stuck, the questions are always the same: what is
//// live and for how long, who holds each helper, how did the last executions
//// end, and is the pool still able to lend. This module is the vocabulary of
//// the answer, and it is pure: the service keeps a `Books` value and calls
//// the functions here at the moments an execution starts, is refused or
//// settles, and `executor.snapshot` renders a `Snapshot` from them.
////
//// ## Bounded by construction
////
//// Nothing here grows with the session. Live rows are at most the pool size,
//// because a row exists only while the service holds a helper for it.
//// History is two rings of at most `ring_size` entries, the last settled
//// executions and the last latency samples per series, and everything else
//// is a counter. The ring is newest first and trimmed on every push, so its
//// cost is a constant and nothing needs an eviction pass.
////
//// ## Never exposed
////
//// No type in this module can hold a secret, because none has a field that
//// could. Where the service reads a type that can (the pool's refusal),
//// it maps to a variant-only type here before the snapshot is built. There is no argv, environment, working directory, policy,
//// capability token or output byte anywhere in a `Snapshot`: a live row is
//// described by counters and enums, and a failure by the *name* of its
//// constructor, never its payload (`RefusedByHelper` carries a helper's
//// message, and the name drops it). The guarantee is the shape of the types,
//// and `executor_test` pins it by planting a marker in a request and
//// searching the rendered snapshot.
////
//// ## Latency summaries
////
//// A summary is p50, p95 and max over the last `ring_size` samples of one
//// series, computed when the snapshot is asked for and not on every sample.
//// Percentiles are the nearest-rank values of the retained samples, which
//// is honest at this size and needs no histogram.

import broker/dispatch
import broker/exec
import broker/execution
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// How many settled executions the `recent` ring keeps, and how many
/// samples each latency series keeps.
pub const ring_size = 64

/// The service's lifecycle phase as an observer sees it.
pub type ServicePhase {
  /// Taking executions.
  Serving

  /// Admissions are closed and live executions are being drained.
  Closing

  /// The close finished but the pool could not show every helper retired,
  /// so the service stays alive holding custody.
  Closed
}

/// How an execution ended, in terms that carry no payload.
pub type Outcome {
  /// The helper reported an exit, with this process exit code.
  Completed(code: Int)

  /// The execution settled as an in-band failure. `kind` is the failure's
  /// constructor name and nothing of its payload.
  Failed(kind: String)

  /// The machinery that would have reported the execution was lost.
  Lost(cause: exec.LossCause)
}

/// Whether the service has granted a live row's settlement.
pub type RowStatus {
  /// Nobody has been given leave to report a verdict.
  Running

  /// The relay was granted leave and the broker has not yet released the
  /// row. A row that stays here is a broker that has not processed a
  /// settlement.
  Granted(outcome: Outcome)
}

/// One execution the service holds.
pub type LiveView {
  LiveView(
    /// The execution's identity.
    id: dispatch.ExecutionId,
    /// Whether its settlement has been granted.
    status: RowStatus,
    /// The relay's mode as of its last progress report.
    mode: execution.Mode,
    /// Whether and why a cancel was asked, as of the same report.
    cancel: execution.CancelState,
    /// What the relay has forwarded so far, as of the same report. The
    /// counters lag a running execution by up to `relay.progress_chunks`
    /// chunks.
    output: execution.Output,
    /// When the execution started, in the session clock's milliseconds.
    started_at: Int,
    /// The wall deadline in the session clock's milliseconds, `0` for none.
    deadline_ms: Int,
    /// The enforcement the request demanded.
    demand: exec.EnforcementDemand,
    /// The pid of the helper actor running it.
    helper: Pid,
    /// That helper's spawn ordinal in the pool, when the pool still lists
    /// it. With `helper` it is the helper's generation.
    helper_ordinal: Option(Int),
    /// Milliseconds since the service started the execution, on a monotonic
    /// clock.
    age_ms: Int,
  )
}

/// One settled execution, as the `recent` ring keeps it.
pub type Settled {
  Settled(
    /// The execution's identity.
    id: dispatch.ExecutionId,
    /// How it ended.
    outcome: Outcome,
    /// Start to settlement, on a monotonic clock.
    duration_ms: Int,
    /// Bytes of stdout forwarded.
    stdout_bytes: Int,
    /// Bytes of stderr forwarded.
    stderr_bytes: Int,
    /// Whether the helper reported truncation.
    truncated: execution.Truncation,
    /// Whether and why a cancel was asked.
    cancel: execution.CancelState,
  )
}

/// The most recent execution that did not complete.
pub type Failure {
  Failure(
    /// The execution's identity.
    id: dispatch.ExecutionId,
    /// How it ended; never `Completed`.
    outcome: Outcome,
    /// When it settled, in the session clock's milliseconds.
    at_ms: Int,
  )
}

/// p50, p95 and max over the retained samples of one series.
pub type LatencySummary {
  LatencySummary(
    /// How many samples the figures are over, at most `ring_size`.
    samples: Int,
    /// The median, `0` with no samples.
    p50_ms: Int,
    /// The 95th percentile by nearest rank, `0` with no samples.
    p95_ms: Int,
    /// The largest retained sample, `0` with no samples.
    max_ms: Int,
  )
}

/// The service's counters and latency summaries.
pub type Metrics {
  Metrics(
    /// Executions the service started.
    started: Int,
    /// Settlements whose outcome was `Completed`.
    completed: Int,
    /// Settlements whose outcome was `Failed`.
    failed: Int,
    /// Settlements whose outcome was `Lost`.
    lost: Int,
    /// Starts refused because every pool slot was busy. This is the
    /// executor's congestion signal: it has no queue, so a full pool is
    /// refused and not waited for, and this counts the refusals.
    all_busy: Int,
    /// Starts refused because the pool or the closing service was
    /// unavailable.
    pool_unavailable: Int,
    /// Starts refused because a helper could not be spawned.
    spawn_failed: Int,
    /// Starts the dispatcher could not carry out at all: a taken sequence
    /// number or a relay that did not initialise.
    not_started: Int,
    /// Output bytes forwarded across all settled executions.
    output_bytes: Int,
    /// Settled executions whose output was truncated.
    truncated: Int,
    /// Time inside `start`, for the starts that succeeded.
    launch: LatencySummary,
    /// Start to settlement.
    execution: LatencySummary,
    /// First cancel to settlement, for executions that were cancelled.
    cancel_to_settle: LatencySummary,
  )
}

/// Why the pool gave no custody view, by name only. The pool's own refusal,
/// `exec.CheckoutError`, can carry a helper's message (`RefusedByHelper`) or
/// an unencodable policy, so the snapshot never holds it: the service maps
/// it to one of these at the boundary and the payload stops there.
pub type CustodyUnavailable {
  /// Every helper was lent out.
  PoolBusy

  /// The pool did not answer, or was not alive to be asked.
  PoolNotAnswering

  /// The pool tried to spawn a helper and could not. Why is in the pool's
  /// own log, not here.
  PoolSpawnFailed
}

/// What the service knows about itself, which is everything in a `Snapshot`
/// except the pool's custody. The service answers it from its own books in
/// one step and never asks the pool anything, so a pool that is slow to
/// answer cannot hold up a settlement. The observer then reads the pool's
/// custody in its own process and joins the two with `completed`.
pub type Observation {
  Observation(
    /// The service's incarnation.
    incarnation: Int,
    /// Where the service is in its lifecycle.
    phase: ServicePhase,
    /// Every execution the service holds, in start order, with
    /// `helper_ordinal` still `None`: only the pool knows an ordinal.
    live: List(LiveView),
    /// The counters and latency summaries.
    metrics: Metrics,
    /// The last `ring_size` settled executions, newest first.
    recent: List(Settled),
    /// The most recent settlement that was not `Completed`.
    last_failure: Option(Failure),
  )
}

/// Everything an observer is given about the service. The service's own
/// fields describe one instant, and the pool's custody was read a moment
/// after it, in the observer's process, so a helper that was released in
/// between is simply absent from the custody and its row has no ordinal.
pub type Snapshot {
  Snapshot(
    /// The service's incarnation.
    incarnation: Int,
    /// Where the service is in its lifecycle.
    phase: ServicePhase,
    /// Every execution the service holds, in start order. At most the pool
    /// size.
    live: List(LiveView),
    /// The pool's census and a view of each helper, or why it gave none.
    pool: Result(exec.PoolCustody, CustodyUnavailable),
    /// The counters and latency summaries.
    metrics: Metrics,
    /// The last `ring_size` settled executions, newest first.
    recent: List(Settled),
    /// The most recent settlement that was not `Completed`.
    last_failure: Option(Failure),
  )
}

/// Joins what the service said of itself with what the pool said of its
/// helpers. Each live row takes its helper's spawn ordinal from the custody
/// when the pool still lists that helper, and none otherwise: the row was
/// read before the custody, so a helper released in between is gone from the
/// pool's list.
///
/// ## Examples
///
/// ```gleam
/// // executor_view.completed(observation, pool: Error(PoolNotAnswering))
/// //   gives a snapshot whose rows have `helper_ordinal: None`
/// ```
pub fn completed(
  observation: Observation,
  pool pool: Result(exec.PoolCustody, CustodyUnavailable),
) -> Snapshot {
  let live =
    list.map(observation.live, fn(row) {
      let ordinal = case pool {
        Ok(custody) ->
          list.find(custody.helpers, fn(view) { view.pid == row.helper })
          |> result.map(fn(view) { view.ordinal })
          |> option.from_result
        Error(_) -> None
      }
      LiveView(..row, helper_ordinal: ordinal)
    })
  Snapshot(
    incarnation: observation.incarnation,
    phase: observation.phase,
    live:,
    pool:,
    metrics: observation.metrics,
    recent: observation.recent,
    last_failure: observation.last_failure,
  )
}

/// Reduces the pool's refusal to a name. The refusal can carry a helper's
/// message, so nothing past this function holds it.
///
/// ## Examples
///
/// ```gleam
/// assert executor_view.custody_unavailable(exec.PoolUnavailable)
///   == executor_view.PoolNotAnswering
/// ```
pub fn custody_unavailable(refusal: exec.CheckoutError) -> CustodyUnavailable {
  case refusal {
    exec.AllBusy(..) -> PoolBusy
    exec.PoolUnavailable -> PoolNotAnswering
    exec.SpawnFailed(..) -> PoolSpawnFailed
  }
}

/// The service's running totals. Opaque so that the rings can only be
/// pushed through functions that trim them.
pub opaque type Books {
  Books(
    started: Int,
    completed: Int,
    failed: Int,
    lost: Int,
    all_busy: Int,
    pool_unavailable: Int,
    spawn_failed: Int,
    not_started: Int,
    output_bytes: Int,
    truncated: Int,
    launch: List(Int),
    execution: List(Int),
    cancel_to_settle: List(Int),
    recent: List(Settled),
    last_failure: Option(Failure),
  )
}

/// Books with nothing recorded.
///
/// ## Examples
///
/// ```gleam
/// assert executor_view.metrics(executor_view.new()).started == 0
/// ```
///
pub fn new() -> Books {
  Books(
    started: 0,
    completed: 0,
    failed: 0,
    lost: 0,
    all_busy: 0,
    pool_unavailable: 0,
    spawn_failed: 0,
    not_started: 0,
    output_bytes: 0,
    truncated: 0,
    launch: [],
    execution: [],
    cancel_to_settle: [],
    recent: [],
    last_failure: None,
  )
}

/// Records a start that succeeded and the time it took inside `start`.
///
/// ## Examples
///
/// ```gleam
/// let books = executor_view.record_start(executor_view.new(), launch_ms: 12)
/// assert executor_view.metrics(books).started == 1
/// ```
///
pub fn record_start(books: Books, launch_ms launch_ms: Int) -> Books {
  Books(
    ..books,
    started: books.started + 1,
    launch: push(books.launch, launch_ms),
  )
}

/// Records a start that was refused, by the reason it was refused.
///
/// ## Examples
///
/// ```gleam
/// let books =
///   executor_view.record_refusal(
///     executor_view.new(),
///     dispatch.NoHelper(exec.AllBusy(size: 2)),
///   )
/// assert executor_view.metrics(books).all_busy == 1
/// ```
///
pub fn record_refusal(books: Books, refusal: dispatch.StartRefusal) -> Books {
  case refusal {
    dispatch.NotStarted -> Books(..books, not_started: books.not_started + 1)
    dispatch.NoHelper(error: exec.AllBusy(..)) ->
      Books(..books, all_busy: books.all_busy + 1)
    dispatch.NoHelper(error: exec.PoolUnavailable) ->
      Books(..books, pool_unavailable: books.pool_unavailable + 1)
    dispatch.NoHelper(error: exec.SpawnFailed(..)) ->
      Books(..books, spawn_failed: books.spawn_failed + 1)
  }
}

/// Records one settlement: the outcome counter, the output totals, the
/// latency samples, the `recent` ring and, for a failure, `last_failure`.
/// `cancel_ms` is the first cancel to the settlement, and is `None` for an
/// execution nobody cancelled. `at_ms` is the session clock's reading.
///
/// ## Examples
///
/// ```gleam
/// let books =
///   executor_view.record_settlement(
///     executor_view.new(),
///     settled,
///     cancel_ms: None,
///     at_ms: 1000,
///   )
/// assert executor_view.metrics(books).completed == 1
/// ```
///
pub fn record_settlement(
  books: Books,
  settled: Settled,
  cancel_ms cancel_ms: Option(Int),
  at_ms at_ms: Int,
) -> Books {
  let counted = case settled.outcome {
    Completed(..) -> Books(..books, completed: books.completed + 1)
    Failed(..) -> Books(..books, failed: books.failed + 1)
    Lost(..) -> Books(..books, lost: books.lost + 1)
  }
  let last_failure = case settled.outcome {
    Completed(..) -> books.last_failure
    Failed(..) | Lost(..) ->
      Some(Failure(id: settled.id, outcome: settled.outcome, at_ms:))
  }
  let cancelled = case cancel_ms {
    Some(ms) -> push(books.cancel_to_settle, ms)
    None -> books.cancel_to_settle
  }
  Books(
    ..counted,
    output_bytes: books.output_bytes
      + settled.stdout_bytes
      + settled.stderr_bytes,
    truncated: case settled.truncated {
      execution.Truncated -> books.truncated + 1
      execution.Whole -> books.truncated
    },
    execution: push(books.execution, settled.duration_ms),
    cancel_to_settle: cancelled,
    recent: push(books.recent, settled),
    last_failure:,
  )
}

/// The counters and, computed now, the latency summaries.
///
/// ## Examples
///
/// ```gleam
/// let metrics = executor_view.metrics(executor_view.new())
/// assert metrics.launch.samples == 0
/// ```
///
pub fn metrics(books: Books) -> Metrics {
  Metrics(
    started: books.started,
    completed: books.completed,
    failed: books.failed,
    lost: books.lost,
    all_busy: books.all_busy,
    pool_unavailable: books.pool_unavailable,
    spawn_failed: books.spawn_failed,
    not_started: books.not_started,
    output_bytes: books.output_bytes,
    truncated: books.truncated,
    launch: summarise(books.launch),
    execution: summarise(books.execution),
    cancel_to_settle: summarise(books.cancel_to_settle),
  )
}

/// The last settled executions, newest first.
///
/// ## Examples
///
/// ```gleam
/// assert executor_view.recent(executor_view.new()) == []
/// ```
///
pub fn recent(books: Books) -> List(Settled) {
  books.recent
}

/// The most recent settlement that was not `Completed`.
///
/// ## Examples
///
/// ```gleam
/// assert executor_view.last_failure(executor_view.new()) == None
/// ```
///
pub fn last_failure(books: Books) -> Option(Failure) {
  books.last_failure
}

/// p50, p95 and max over the samples, which the caller keeps at most
/// `ring_size` long.
///
/// ## Examples
///
/// ```gleam
/// let summary = executor_view.summarise([5, 1, 3])
/// assert summary.p50_ms == 3
/// assert summary.max_ms == 5
/// ```
///
pub fn summarise(samples: List(Int)) -> LatencySummary {
  let sorted = list.sort(samples, int.compare)
  let count = list.length(sorted)
  LatencySummary(
    samples: count,
    p50_ms: nearest_rank(sorted, count, 50),
    p95_ms: nearest_rank(sorted, count, 95),
    max_ms: nearest_rank(sorted, count, 100),
  )
}

// The nearest-rank percentile of ascending samples: the value at rank
// ceil(percent * count / 100), counted from one. An empty series has no
// rank and answers zero, which the `samples` count disambiguates.
fn nearest_rank(sorted: List(Int), count: Int, percent: Int) -> Int {
  case count {
    0 -> 0
    _ -> {
      let rank = { percent * count + 99 } / 100
      case list.drop(sorted, int.max(rank - 1, 0)) {
        [value, ..] -> value
        [] -> 0
      }
    }
  }
}

// Newest first, trimmed to the ring on every push so the bound is never
// something a reader has to trust a caller to enforce.
fn push(ring: List(a), entry: a) -> List(a) {
  list.take([entry, ..ring], ring_size)
}

/// The outcome of a terminal verdict: the exit code of a completion, the
/// name of a failure, the cause of a loss.
///
/// ## Examples
///
/// ```gleam
/// assert executor_view.outcome_of(dispatch.Failed(exec.CancelEscalated))
///   == executor_view.Failed("CancelEscalated")
/// ```
///
pub fn outcome_of(terminal: dispatch.Terminal) -> Outcome {
  case terminal {
    dispatch.Completed(result:) -> Completed(code: result.code)
    dispatch.Failed(failure: exec.ExecutionLost(cause:)) -> Lost(cause:)
    dispatch.Failed(failure:) -> Failed(kind: failure_kind(failure))
  }
}

/// The constructor name of a failure, with none of its payload. Every
/// constructor is written out, so a new failure is a compile error here and
/// cannot reach a log or a snapshot under a name nobody chose.
///
/// ## Examples
///
/// ```gleam
/// assert executor_view.failure_kind(exec.HelperBusy) == "HelperBusy"
/// ```
///
pub fn failure_kind(failure: exec.ExecFailure) -> String {
  case failure {
    exec.NotReady -> "NotReady"
    exec.HandshakeTimeout -> "HandshakeTimeout"
    exec.HelperBusy -> "HelperBusy"
    exec.DegradedHelper(..) -> "DegradedHelper"
    exec.DegradedExecution(..) -> "DegradedExecution"
    exec.RefusedByHelper(..) -> "RefusedByHelper"
    exec.ChannelFault(..) -> "ChannelFault"
    exec.ChannelClosed(..) -> "ChannelClosed"
    exec.ProtocolViolation(..) -> "ProtocolViolation"
    exec.ProtocolVersionMismatch(..) -> "ProtocolVersionMismatch"
    exec.SendFailed -> "SendFailed"
    exec.CancelEscalated -> "CancelEscalated"
    exec.HeartbeatMissed -> "HeartbeatMissed"
    exec.HelperUnresponsive -> "HelperUnresponsive"
    exec.ExecutionLost(..) -> "ExecutionLost"
  }
}

/// The class of an outcome as a word, for a counter's name or a log field.
///
/// ## Examples
///
/// ```gleam
/// assert executor_view.outcome_class(executor_view.Completed(0)) == "completed"
/// ```
///
pub fn outcome_class(outcome: Outcome) -> String {
  case outcome {
    Completed(..) -> "completed"
    Failed(..) -> "failed"
    Lost(..) -> "lost"
  }
}

/// The detail of an outcome as a word: a completion's exit code, a failure's
/// kind or a loss's cause.
///
/// ## Examples
///
/// ```gleam
/// assert executor_view.outcome_detail(executor_view.Lost(exec.RelayDown))
///   == "RelayDown"
/// ```
///
pub fn outcome_detail(outcome: Outcome) -> String {
  case outcome {
    Completed(code:) -> int.to_string(code)
    Failed(kind:) -> kind
    Lost(cause: exec.HelperActorDown) -> "HelperActorDown"
    Lost(cause: exec.RelayDown) -> "RelayDown"
    Lost(cause: exec.RemoteOutcomeUncertain) -> "RemoteOutcomeUncertain"
    Lost(cause: exec.ExecutorClosing) -> "ExecutorClosing"
  }
}

/// A cancel cause as a word.
///
/// ## Examples
///
/// ```gleam
/// assert executor_view.cancel_name(execution.NotAsked) == "none"
/// ```
///
pub fn cancel_name(cancel: execution.CancelState) -> String {
  case cancel {
    execution.NotAsked -> "none"
    execution.Asked(cause: execution.ByBroker) -> "broker"
    execution.Asked(cause: execution.CallerGone) -> "caller_gone"
    execution.Asked(cause: execution.WallDeadline) -> "wall_deadline"
  }
}

/// An execution identity as one token, `incarnation.seq`, for a log field.
///
/// ## Examples
///
/// ```gleam
/// let id = dispatch.execution_id(incarnation: 2, seq: 7)
/// assert executor_view.id_label(id) == "2.7"
/// ```
///
pub fn id_label(id: dispatch.ExecutionId) -> String {
  int.to_string(dispatch.incarnation(id))
  <> "."
  <> int.to_string(dispatch.seq(id))
}
