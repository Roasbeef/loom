//// The parent session's durable record of children that run on another
//// orchestrator (protocol-change/084, slice S3).
////
//// A local child is a strand of the parent's own session, so the Agency learns
//// what it needs from that strand's registers. A remote child has no strand
//// here. What the parent holds instead is two kinds of record, both in its own
//// session store under reserved prefixes (`runtime/api.remote_child_fact_prefix`
//// and `remote_ended_fact_prefix`), and this module is their vocabulary and the
//// rules for moving them.
////
//// ## The stub
////
//// `remote-child/{call site digest}` is written before the first `Spawn` is
//// sent, and it holds the whole request. That is what lets a drainer resend the
//// `Spawn` without the model, routes every retry of the call site to the same
//// orchestrator, and means a failure of the other orchestrator never turns into
//// a local spawn. The stub is itself the pending row: while it is `Requested`
//// the spawn is owed, and nothing else records that. Peer mail's outbox rows have
//// a fixed shape and an hour's time to live, and neither fits (the design note,
//// section 8.4), so these rows are their own facts.
////
//// A stub moves forward only: `Requested` becomes `Spawned` when the
//// orchestrator answers with a handle, or `Refused` when it says no; `Spawned`
//// becomes `Settled` when a join reports the child finished. Every step is a
//// compare-and-set that refuses to move a stub that has already left the state
//// the step starts from, because two writers can race here by design: the
//// effect process that asked and the drainer that resends it both hear the same
//// answer, and a late `Spawned` must not undo a `Settled`.
////
//// The lineage cell of a remote child is written with the `Spawned` step,
//// before the stub, so that by the time anything shows the model a handle the
//// addressing rule already holds the child as a descendant.
////
//// ## The run-end row
////
//// `remote-ended/{operation}/{orchestrator}` is the pending row for a run end.
//// It is written once per orchestrator that holds a live, attached child or
//// stub of the ended operation, `Pending` until the orchestrator answers
//// `RunEnded` and `Told` after. A detached child is not reaped by a run end and
//// so writes no row.
////
//// ## Flow
////
//// `admit` → `spawned` | `refused` | `discard` → `settled` → `owe_run_end` → `tell`
////
//// 1. `admit` writes the stub for a call site, or hands back the one a replay
////    or an earlier attempt already wrote.
//// 2. `spawned` and `refused` apply the orchestrator's answer to a `Requested`
////    stub; `discard` removes a stub whose spawn was refused where the model
////    heard it.
//// 3. `settled` records a join's report on a `Spawned` stub.
//// 4. `owe_run_end` writes the rows a finished run owes, and `tell` sends one to
////    its orchestrator and marks it delivered (`told`) on any answer.

import client/peer_mail
import client/remote_reach.{type Reach}
import client/remote_spawn.{type ChildUsage, type Parent}
import core/corruption
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import runtime/api
import runtime/lineage
import tools/agent.{type Handle, type Outcome}

/// How many times a step re-reads and retries after losing a compare-and-set.
/// Two writers race here, so one retry is the usual worst case; the bound only
/// keeps a corrupt cell from looping.
const step_attempts = 4

/// A child as the parent's session records it.
pub type Stub {
  Stub(
    /// The `[orchestrators.<name>]` the child runs on.
    orchestrator: String,
    /// The parent strand that asked, in this session.
    strand: String,
    /// The parent's planned call, which the receiving orchestrator derives the
    /// child's name from.
    site: remote_spawn.CallSite,
    /// The parent's depth, which the receiving spawner's `max_depth` is checked
    /// against.
    depth: Int,
    /// The tools the parent held when it asked.
    parent_tools: List(String),
    /// What the parent asked for.
    request: remote_spawn.Request,
    /// The strand name the child has on the other orchestrator, derived from the
    /// call site. It is what the roster calls a child that has no handle yet.
    name: String,
    /// How far the spawn has got.
    state: State,
  )
}

/// How far a spawn has got.
pub type State {
  /// The `Spawn` is owed: it was sent or is about to be, and no answer has been
  /// recorded. The child may exist.
  Requested

  /// The orchestrator started the child, or adopted the one this call site had
  /// already started.
  Spawned(placed: Placed)

  /// A join reported the child's run finished.
  Settled(placed: Placed, outcome: Outcome, usage: ChildUsage)

  /// The orchestrator refused the spawn and created nothing. The reason is its
  /// own, worded for the model.
  Refused(reason: String)
}

/// What the orchestrator answered when it started a child.
pub type Placed {
  Placed(
    /// The child's strand and the operation that runs it.
    handle: Handle,
    /// The tools the child holds.
    tools: List(String),
    /// The child's catalogue name on the other orchestrator.
    model: String,
    /// The provider model identifier behind that name.
    model_id: String,
    /// When the child's deadline falls, as an instant on this session's clock.
    /// The other orchestrator reports a duration and clocks never cross as
    /// instants, so this is the time left at the moment of the answer added to
    /// the time the answer was read, which makes it a display value.
    deadline_ms: Int,
  )
}

/// A stub with the key it is stored under.
pub type Kept {
  Kept(key: String, stub: Stub)
}

/// Whether the stub the caller asked for was already there.
pub type Admission {
  /// The stub was written now.
  Fresh

  /// A stub for this call site already existed, and is what a replay or an
  /// earlier attempt wrote.
  Existing(stub: Stub)
}

/// Where a run-end row stands.
pub type Telling {
  /// The orchestrator has not yet answered `RunEnded`.
  Pending

  /// It answered, with a count or a refusal; either way it needs no more.
  Told
}

/// A run end owed to one orchestrator.
pub type Ended {
  Ended(
    /// The parent's operation that ended.
    operation: OpId,
    /// The orchestrator that holds children of that operation.
    orchestrator: String,
    /// The parent strand that ran the operation.
    strand: String,
    /// Whether the orchestrator has been told.
    telling: Telling,
  )
}

/// The key of the stub for one call site, from `agent.call_site_digest`.
///
/// ## Examples
///
/// ```gleam
/// assert remote_child.stub_key("7b1c0a4e2d95f318") == "remote-child/7b1c0a4e2d95f318"
/// ```
pub fn stub_key(digest: String) -> String {
  api.remote_child_fact_prefix <> digest
}

/// The key of the run-end row for one operation and orchestrator.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.ended_key(operation, "box") == "remote-ended/{operation}/box"
/// ```
pub fn ended_key(operation: OpId, orchestrator: String) -> String {
  api.remote_ended_fact_prefix
  <> ids.op_id_to_string(operation)
  <> "/"
  <> orchestrator
}

/// Whether a stub still counts against the fan-out caps: its child is, or may
/// be, running. A stub whose remote has not answered counts, which errs toward
/// refusing a spawn.
///
/// ## Examples
///
/// ```gleam
/// assert remote_child.is_live(stub_in_state(remote_child.Requested))
/// ```
pub fn is_live(stub: Stub) -> Bool {
  case stub.state {
    Requested | Spawned(..) -> True
    Settled(..) | Refused(..) -> False
  }
}

/// The parent a message about this stub names, given the session it is in.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.parent_of(stub, "0198c0de-0000-7000-8000-000000000001")
/// ```
pub fn parent_of(stub: Stub, session: String) -> Parent {
  remote_spawn.Parent(session:, strand: stub.strand)
}

// --- the records ------------------------------------------------------------

/// Writes the stub for a call site unless one is there.
///
/// The write expects the cell to be absent, so two attempts that race through
/// the gap cannot both write: the loser reads what the winner wrote and returns
/// it as `Existing`. A replayed `agent_spawn` and the first attempt that was
/// interrupted both arrive here and both get the same stub.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.admit(runtime, remote_child.stub_key(digest), stub) == Ok(remote_child.Fresh)
/// ```
pub fn admit(
  runtime: api.Runtime,
  key: String,
  stub: Stub,
) -> Result(Admission, String) {
  case
    api.put_reserved_fact_expecting(runtime, key, encode(stub), expected: None)
  {
    Ok(_) -> Ok(Fresh)
    Error(api.FactConflict(..)) -> {
      use found <- result.try(read(runtime, key))
      case found {
        Some(#(existing, _seq)) -> Ok(Existing(existing))
        None -> Error("the remote child stub moved under the write")
      }
    }
    Error(error) -> Error(describe(error))
  }
}

/// Reads one stub.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.find(runtime, remote_child.stub_key(digest))
/// ```
pub fn find(runtime: api.Runtime, key: String) -> Result(Option(Stub), String) {
  read(runtime, key) |> result.map(option.map(_, fn(found) { found.0 }))
}

/// Every stub the session holds, with its key. A cell that does not decode is
/// left out: the listing feeds the fan-out count and the roster, and a corrupt
/// cell is a loss of information that no read can repair, while a listing that
/// faulted on it would refuse every spawn and every roster for the rest of the
/// session.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.all(runtime) == Ok([remote_child.Kept(key, stub)])
/// ```
pub fn all(runtime: api.Runtime) -> Result(List(Kept), String) {
  use cells <- result.map(
    api.reserved_facts(runtime, prefix: api.remote_child_fact_prefix)
    |> result.map_error(describe),
  )
  list.filter_map(cells, fn(pair) {
    decode(pair.1) |> result.map(Kept(pair.0, _)) |> result.replace_error(Nil)
  })
}

/// Records the orchestrator's answer to a `Spawn`: the child exists.
///
/// The lineage cell is written first, so that no one is shown the handle before
/// the addressing rule holds the child as a descendant, and the stub moves to
/// `Spawned` second. A stub that is no longer `Requested` is returned as it is:
/// a second writer got the same answer first, or the child has since settled.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.spawned(runtime, key, stub, answer, now)
/// ```
pub fn spawned(
  runtime: api.Runtime,
  key: String,
  stub: Stub,
  answer: remote_spawn.Spawned,
  now: Int,
) -> Result(Stub, String) {
  let placed =
    Placed(
      handle: answer.handle,
      tools: answer.tools,
      model: answer.model,
      model_id: answer.model_id,
      deadline_ms: now + answer.remaining_ms,
    )
  use Nil <- result.try(
    api.put_reserved_fact(
      runtime,
      lineage.register_key(placed.handle.strand),
      lineage.encode(lineage_cell(stub, placed)),
    )
    |> result.map_error(describe),
  )
  advance(runtime, key, fn(state) {
    case state {
      Requested -> Some(Spawned(placed))
      Spawned(..) | Settled(..) | Refused(..) -> None
    }
  })
}

/// Records the orchestrator's refusal of a `Spawn`, for a spawn nobody is
/// waiting on: the drainer learned it after the model had been told the
/// orchestrator did not answer. The stub stays, in `Refused`, so the roster can
/// show the reason, and it stops counting against the caps.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.refused(runtime, key, stub, "the cap max_sessions is 4")
/// ```
pub fn refused(
  runtime: api.Runtime,
  key: String,
  reason: String,
) -> Result(Stub, String) {
  advance(runtime, key, fn(state) {
    case state {
      Requested -> Some(Refused(reason))
      Spawned(..) | Settled(..) | Refused(..) -> None
    }
  })
}

/// Removes a stub whose spawn was refused where the model heard it. Nothing was
/// created, nothing is owed, and the refusal is in the model's own result, so the
/// stub has no reader left.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.discard(runtime, key)
/// ```
pub fn discard(runtime: api.Runtime, key: String) -> Result(Nil, String) {
  api.delete_reserved_fact(runtime, key) |> result.map_error(describe)
}

/// Records a join's report that a child finished, with what it cost. The cost is
/// the other orchestrator's own pricing and is kept as reported.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.settled(runtime, key, outcome, usage)
/// ```
pub fn settled(
  runtime: api.Runtime,
  key: String,
  outcome: Outcome,
  usage: ChildUsage,
) -> Result(Stub, String) {
  advance(runtime, key, fn(state) {
    case state {
      Spawned(placed) -> Some(Settled(placed:, outcome:, usage:))
      Requested | Settled(..) | Refused(..) -> None
    }
  })
}

// A step from one state, as a single compare-and-set. The stub is read with the
// seq it was written at, the step names the state to move to (or `None` when it
// does not apply to where the stub stands), and the write expects that seq. A
// stub that is no longer where the step starts is returned unchanged. A lost
// race re-reads and decides again, so the loser of two writers that heard the
// same answer ends by agreeing with the winner.
fn advance(
  runtime: api.Runtime,
  key: String,
  next: fn(State) -> Option(State),
) -> Result(Stub, String) {
  advance_attempts(runtime, key, next, step_attempts)
}

fn advance_attempts(
  runtime: api.Runtime,
  key: String,
  next: fn(State) -> Option(State),
  attempts: Int,
) -> Result(Stub, String) {
  use found <- result.try(read(runtime, key))
  case found {
    None -> Error("the remote child stub is missing")
    Some(#(stub, seq)) ->
      case next(stub.state) {
        None -> Ok(stub)
        Some(state) ->
          store(runtime, key, Stub(..stub, state:), seq, next, attempts)
      }
  }
}

// The write half of a step. Losing the compare-and-set re-enters the step with
// one attempt fewer, and the re-read decides whether the step still applies.
fn store(
  runtime: api.Runtime,
  key: String,
  moved: Stub,
  seq: Int,
  next: fn(State) -> Option(State),
  attempts: Int,
) -> Result(Stub, String) {
  case
    api.put_reserved_fact_expecting(
      runtime,
      key,
      encode(moved),
      expected: Some(seq),
    )
  {
    Ok(_) -> Ok(moved)
    Error(api.FactConflict(..)) if attempts > 1 ->
      advance_attempts(runtime, key, next, attempts - 1)
    Error(error) -> Error(describe(error))
  }
}

fn read(
  runtime: api.Runtime,
  key: String,
) -> Result(Option(#(Stub, Int)), String) {
  use cell <- result.try(
    api.fact_cell(runtime, key) |> result.map_error(describe),
  )
  case cell {
    None -> Ok(None)
    Some(api.FactCell(value:, seq:)) ->
      decode(value) |> result.map(fn(stub) { Some(#(stub, seq)) })
  }
}

// The lineage cell a remote child is held under. It records the edge from the
// parent strand to a child that has no strand here, so that addressing, waiting
// and the roster see it as the parent's descendant, and `orchestrator` marks it
// as a cell nothing may ask the local strand registers about.
fn lineage_cell(stub: Stub, placed: Placed) -> lineage.Lineage {
  lineage.Lineage(
    strand: placed.handle.strand,
    parent: stub.strand,
    depth: stub.depth + 1,
    minted_by: lineage.CallSite(
      operation: stub.site.operation,
      step_id: minting_step(stub),
      source_index: stub.site.source_index,
    ),
    brief: placed.handle.operation,
    tools: placed.tools,
    default_within_ms: None,
    deadline: Some(placed.deadline_ms),
    detached: stub.request.detach == remote_spawn.Detached,
    reaped: False,
    orchestrator: Some(stub.orchestrator),
  )
}

// The step id the lineage ledger records for this call site, which carries a
// code-mode program's ordinal the same way a local spawn's does.
fn minting_step(stub: Stub) -> String {
  agent.minting_step(agent.Caller(
    strand: stub.strand,
    operation: stub.site.operation,
    step_id: stub.site.step_id,
    source_index: stub.site.source_index,
    minter: stub.site.minter,
  ))
}

// --- the run-end rows -------------------------------------------------------

/// Writes the rows that the end of a parent's run owes, and returns the ones that
/// are pending afterwards.
///
/// One row is owed to each orchestrator that holds a child of the operation the
/// run owns and that may still be live: a `Requested` or `Spawned` stub that is
/// not detached. A detached child outlives the run and is bounded by its
/// deadline, so it owes nothing. A row that already exists is not rewritten, so a
/// run that is reported twice owes once, and a row already `Told` is not
/// returned. The rows come back in the order of the orchestrators' names, which
/// is the order they are told in.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.owe_run_end(runtime, operation) == Ok([Ended(operation, "box", "main", Pending)])
/// ```
pub fn owe_run_end(
  runtime: api.Runtime,
  operation: OpId,
) -> Result(List(Ended), String) {
  use kept <- result.try(all(runtime))
  kept
  |> list.filter(fn(entry) { owes(entry.stub, operation) })
  |> list.map(fn(entry) { #(entry.stub.orchestrator, entry.stub.strand) })
  |> list.unique
  |> list.sort(fn(a, b) { string.compare(a.0 <> "/" <> a.1, b.0 <> "/" <> b.1) })
  |> list.try_map(fn(owed) {
    write_ended(
      runtime,
      Ended(operation:, orchestrator: owed.0, strand: owed.1, telling: Pending),
    )
  })
  |> result.map(list.filter(_, fn(row) { row.telling == Pending }))
}

// Whether a run end must reach the stub's orchestrator for this operation.
fn owes(stub: Stub, operation: OpId) -> Bool {
  stub.site.operation == operation
  && stub.request.detach == remote_spawn.Attached
  && is_live(stub)
}

// Writes a row unless one is there, and answers the row that stands. The write
// expects the cell to be absent, so a second report of the same run end finds
// the first row and does not reset a row that was already told.
fn write_ended(runtime: api.Runtime, row: Ended) -> Result(Ended, String) {
  let key = ended_key(row.operation, row.orchestrator)
  case
    api.put_reserved_fact_expecting(
      runtime,
      key,
      encode_ended(row),
      expected: None,
    )
  {
    Ok(_) -> Ok(row)
    Error(api.FactConflict(..)) -> {
      use cell <- result.try(
        api.fact_cell(runtime, key) |> result.map_error(describe),
      )
      case cell {
        Some(api.FactCell(value:, ..)) -> decode_ended(value)
        None -> Error("the run-end row moved under the write")
      }
    }
    Error(error) -> Error(describe(error))
  }
}

/// The run-end rows that have not been told, in key order.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.owed_run_ends(runtime) == Ok([remote_child.Ended(operation, "box", "main", remote_child.Pending)])
/// ```
pub fn owed_run_ends(runtime: api.Runtime) -> Result(List(Ended), String) {
  use cells <- result.map(
    api.reserved_facts(runtime, prefix: api.remote_ended_fact_prefix)
    |> result.map_error(describe),
  )
  list.filter_map(cells, fn(pair) {
    case decode_ended(pair.1) {
      Ok(Ended(telling: Pending, ..) as row) -> Ok(row)
      Ok(Ended(telling: Told, ..)) | Error(_) -> Error(Nil)
    }
  })
}

/// Marks a run-end row delivered. The orchestrator's answer, a count of children
/// stopped or a refusal, both end the row: a count of zero means the children had
/// already settled, and a refusal means the orchestrator will never act on it.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.told(runtime, ended) == Ok(Nil)
/// ```
pub fn told(runtime: api.Runtime, row: Ended) -> Result(Nil, String) {
  api.put_reserved_fact(
    runtime,
    ended_key(row.operation, row.orchestrator),
    encode_ended(Ended(..row, telling: Told)),
  )
  |> result.map_error(describe)
}

/// What came of telling an orchestrator that a run ended.
pub type Reply {
  /// The orchestrator answered, with a count or a refusal, and the row is told.
  Answered

  /// Nobody answered, or the row could not be recorded as told. It stays
  /// pending.
  Silent
}

/// Tells an orchestrator that a run ended, once, and marks the row told on any
/// answer.
///
/// The parent's reaper calls this the moment it writes the row, so the children
/// stop without waiting for the drainer's next tick, and the drainer
/// (`client/remote_drain`) calls it for every row that call left pending. A
/// refusal ends the row as an answer does: the orchestrator looked and will never
/// act on it, such as one that no longer lists this machine as a spawner. A
/// repeat is harmless, since the orchestrator stops nothing more the second time.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.tell(runtime, reach, ended) == remote_child.Answered
/// ```
pub fn tell(runtime: api.Runtime, reach: Reach, row: Ended) -> Reply {
  let parent = remote_reach.parent(reach, row.strand)
  case reach.run_ended(row.orchestrator, parent, row.operation) {
    Ok(_) | Error(peer_mail.Refused(..)) ->
      case told(runtime, row) {
        Ok(Nil) -> Answered
        Error(_) -> Silent
      }
    Error(peer_mail.Unreachable) -> Silent
  }
}

// --- the codec --------------------------------------------------------------

fn describe(error: api.ApiError) -> String {
  case error {
    api.ReadFailed(reason:) -> reason
    api.FactConflict(key:) -> "the fact `" <> key <> "` moved under the write"
    api.SessionStolen(..) -> "another writer holds this session; reopen it"
    api.RuntimeUnavailable -> "the target writer is restarting; try again"
    api.ReservedFactKey(key:) | api.UnreservedFactKey(key:) ->
      "the key `" <> key <> "` is not usable here"
    api.AcceptRejected(..)
    | api.QueueRejected(..)
    | api.CommitFailed(..)
    | api.RaceLost
    | api.EscalationExists(..)
    | api.EscalationNotFound(..)
    | api.EscalationWrongStatus(..) -> "the session store refused the write"
  }
}

/// A stub's payload, the value of its cell.
///
/// ## Examples
///
/// ```gleam
/// // remote_child.decode(remote_child.encode(stub)) == Ok(stub)
/// ```
pub fn encode(stub: Stub) -> JsonValue {
  json.Object(list.append(
    [
      #("orchestrator", json.String(stub.orchestrator)),
      #("strand", json.String(stub.strand)),
      #("site", encode_site(stub.site)),
      #("depth", json.Int(stub.depth)),
      #("parentTools", strings(stub.parent_tools)),
      #("request", encode_request(stub.request)),
      #("name", json.String(stub.name)),
    ],
    encode_state(stub.state),
  ))
}

fn encode_state(state: State) -> List(#(String, JsonValue)) {
  case state {
    Requested -> [#("state", json.String("requested"))]
    Spawned(placed:) -> [
      #("state", json.String("spawned")),
      #("placed", encode_placed(placed)),
    ]
    Settled(placed:, outcome:, usage:) -> [
      #("state", json.String("settled")),
      #("placed", encode_placed(placed)),
      #("outcome", encode_outcome(outcome)),
      #("usage", encode_usage(usage)),
    ]
    Refused(reason:) -> [
      #("state", json.String("refused")),
      #("reason", json.String(reason)),
    ]
  }
}

fn encode_site(site: remote_spawn.CallSite) -> JsonValue {
  json.Object([
    #("operation", json.String(ids.op_id_to_string(site.operation))),
    #("stepId", json.String(site.step_id)),
    #("sourceIndex", json.Int(site.source_index)),
    #("minter", case site.minter {
      agent.ToolCall -> json.Object([#("kind", json.String("tool"))])
      agent.Program(ordinal:) ->
        json.Object([
          #("kind", json.String("program")),
          #("ordinal", json.Int(ordinal)),
        ])
    }),
  ])
}

fn encode_request(request: remote_spawn.Request) -> JsonValue {
  json.Object([
    #("purpose", json.String(request.purpose)),
    #("brief", json.String(request.brief)),
    #("model", optional(request.model, json.String)),
    #("tools", optional(request.tools, strings)),
    #("withinMs", optional(request.within_ms, json.Int)),
    #(
      "resultSchema",
      optional(request.result_schema, agent.render_result_schema),
    ),
    #("detach", json.Bool(request.detach == remote_spawn.Detached)),
  ])
}

fn encode_placed(placed: Placed) -> JsonValue {
  json.Object([
    #("strand", json.String(placed.handle.strand)),
    #("operation", json.String(ids.op_id_to_string(placed.handle.operation))),
    #("tools", strings(placed.tools)),
    #("model", json.String(placed.model)),
    #("modelId", json.String(placed.model_id)),
    #("deadlineMs", json.Int(placed.deadline_ms)),
  ])
}

fn encode_outcome(outcome: Outcome) -> JsonValue {
  json.Object(case outcome {
    agent.Completed -> [#("kind", json.String("completed"))]
    agent.Failed(reason:) -> [
      #("kind", json.String("failed")),
      #("reason", json.String(reason)),
    ]
    agent.Aborted -> [#("kind", json.String("aborted"))]
    agent.BudgetExpired -> [#("kind", json.String("budget_expired"))]
    agent.ParentFinished -> [#("kind", json.String("parent_finished"))]
  })
}

fn encode_usage(usage: ChildUsage) -> JsonValue {
  json.Object([
    #("input", json.Int(usage.input)),
    #("output", json.Int(usage.output)),
    #("cacheRead", json.Int(usage.cache_read)),
    #("cacheWrite", json.Int(usage.cache_write)),
    #("cost", json.Float(usage.cost)),
  ])
}

fn encode_ended(row: Ended) -> JsonValue {
  json.Object([
    #("operation", json.String(ids.op_id_to_string(row.operation))),
    #("orchestrator", json.String(row.orchestrator)),
    #("strand", json.String(row.strand)),
    #("state", case row.telling {
      Pending -> json.String("pending")
      Told -> json.String("told")
    }),
  ])
}

fn strings(values: List(String)) -> JsonValue {
  json.Array(list.map(values, json.String))
}

fn optional(value: Option(a), render: fn(a) -> JsonValue) -> JsonValue {
  case value {
    Some(present) -> render(present)
    None -> json.Null
  }
}

/// Decodes a stub's payload. Total: anything malformed is an error that names
/// what was wrong, never a crash.
///
/// ## Examples
///
/// ```gleam
/// assert remote_child.decode(json.Null)
///   == Error("expected a remote child stub, got null")
/// ```
pub fn decode(value: JsonValue) -> Result(Stub, String) {
  use fields <- result.try(object(value, "a remote child stub"))
  use orchestrator <- result.try(text(fields, "orchestrator"))
  use strand <- result.try(text(fields, "strand"))
  use site <- result.try(member(fields, "site") |> result.try(decode_site))
  use depth <- result.try(number(fields, "depth"))
  use parent_tools <- result.try(texts(fields, "parentTools"))
  use request <- result.try(
    member(fields, "request") |> result.try(decode_request),
  )
  use name <- result.try(text(fields, "name"))
  use state <- result.try(decode_state(fields))
  Ok(Stub(
    orchestrator:,
    strand:,
    site:,
    depth:,
    parent_tools:,
    request:,
    name:,
    state:,
  ))
}

fn decode_state(fields: List(#(String, JsonValue))) -> Result(State, String) {
  use word <- result.try(text(fields, "state"))
  case word {
    "requested" -> Ok(Requested)
    "spawned" -> {
      use placed <- result.map(
        member(fields, "placed") |> result.try(decode_placed),
      )
      Spawned(placed)
    }
    "settled" -> {
      use placed <- result.try(
        member(fields, "placed") |> result.try(decode_placed),
      )
      use outcome <- result.try(
        member(fields, "outcome") |> result.try(decode_outcome),
      )
      use usage <- result.map(
        member(fields, "usage") |> result.try(decode_usage),
      )
      Settled(placed:, outcome:, usage:)
    }
    "refused" -> text(fields, "reason") |> result.map(Refused)
    other -> Error("unknown remote child state `" <> other <> "`")
  }
}

fn decode_site(value: JsonValue) -> Result(remote_spawn.CallSite, String) {
  use fields <- result.try(object(value, "a call site"))
  use operation <- result.try(operation_id(fields, "operation"))
  use step_id <- result.try(text(fields, "stepId"))
  use source_index <- result.try(number(fields, "sourceIndex"))
  use minter <- result.try(
    member(fields, "minter")
    |> result.try(object(_, "a minter"))
    |> result.try(decode_minter),
  )
  Ok(remote_spawn.CallSite(operation:, step_id:, source_index:, minter:))
}

fn decode_minter(
  fields: List(#(String, JsonValue)),
) -> Result(agent.Minter, String) {
  use kind <- result.try(text(fields, "kind"))
  case kind {
    "tool" -> Ok(agent.ToolCall)
    "program" -> number(fields, "ordinal") |> result.map(agent.Program)
    other -> Error("unknown minter `" <> other <> "`")
  }
}

fn decode_request(value: JsonValue) -> Result(remote_spawn.Request, String) {
  use fields <- result.try(object(value, "a spawn request"))
  use purpose <- result.try(text(fields, "purpose"))
  use brief <- result.try(text(fields, "brief"))
  use model <- result.try(maybe(fields, "model", expect_text))
  use tools <- result.try(maybe(fields, "tools", expect_texts))
  use within_ms <- result.try(maybe(fields, "withinMs", expect_number))
  use result_schema <- result.try(maybe(
    fields,
    "resultSchema",
    agent.parse_result_schema,
  ))
  use detach <- result.try(case list.key_find(fields, "detach") {
    Ok(json.Bool(True)) -> Ok(remote_spawn.Detached)
    Ok(json.Bool(False)) -> Ok(remote_spawn.Attached)
    Ok(_) | Error(Nil) -> Error("expected `detach` to be a boolean")
  })
  Ok(remote_spawn.Request(
    purpose:,
    brief:,
    model:,
    tools:,
    within_ms:,
    result_schema:,
    detach:,
  ))
}

fn decode_placed(value: JsonValue) -> Result(Placed, String) {
  use fields <- result.try(object(value, "a placed child"))
  use strand <- result.try(text(fields, "strand"))
  use operation <- result.try(operation_id(fields, "operation"))
  use tools <- result.try(texts(fields, "tools"))
  use model <- result.try(text(fields, "model"))
  use model_id <- result.try(text(fields, "modelId"))
  use deadline_ms <- result.try(number(fields, "deadlineMs"))
  Ok(Placed(
    handle: agent.Handle(strand:, operation:),
    tools:,
    model:,
    model_id:,
    deadline_ms:,
  ))
}

fn decode_outcome(value: JsonValue) -> Result(Outcome, String) {
  use fields <- result.try(object(value, "an outcome"))
  use kind <- result.try(text(fields, "kind"))
  case kind {
    "completed" -> Ok(agent.Completed)
    "failed" -> text(fields, "reason") |> result.map(agent.Failed)
    "aborted" -> Ok(agent.Aborted)
    "budget_expired" -> Ok(agent.BudgetExpired)
    "parent_finished" -> Ok(agent.ParentFinished)
    other -> Error("unknown outcome `" <> other <> "`")
  }
}

fn decode_usage(value: JsonValue) -> Result(ChildUsage, String) {
  use fields <- result.try(object(value, "a usage"))
  use input <- result.try(number(fields, "input"))
  use output <- result.try(number(fields, "output"))
  use cache_read <- result.try(number(fields, "cacheRead"))
  use cache_write <- result.try(number(fields, "cacheWrite"))
  use cost <- result.try(case list.key_find(fields, "cost") {
    Ok(json.Float(cost)) -> Ok(cost)
    Ok(json.Int(cost)) -> Ok(int.to_float(cost))
    Ok(_) | Error(Nil) -> Error("expected `cost` to be a number")
  })
  Ok(remote_spawn.ChildUsage(input:, output:, cache_read:, cache_write:, cost:))
}

fn decode_ended(value: JsonValue) -> Result(Ended, String) {
  use fields <- result.try(object(value, "a run-end row"))
  use operation <- result.try(operation_id(fields, "operation"))
  use orchestrator <- result.try(text(fields, "orchestrator"))
  use strand <- result.try(text(fields, "strand"))
  use word <- result.try(text(fields, "state"))
  use telling <- result.try(case word {
    "pending" -> Ok(Pending)
    "told" -> Ok(Told)
    other -> Error("unknown run-end state `" <> other <> "`")
  })
  Ok(Ended(operation:, orchestrator:, strand:, telling:))
}

fn object(
  value: JsonValue,
  what: String,
) -> Result(List(#(String, JsonValue)), String) {
  case value {
    json.Object(fields) -> Ok(fields)
    other -> Error("expected " <> what <> ", got " <> json.to_string(other))
  }
}

fn member(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(JsonValue, String) {
  list.key_find(fields, name)
  |> result.replace_error("missing `" <> name <> "`")
}

fn text(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(String, String) {
  member(fields, name) |> result.try(expect_text)
}

fn number(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(Int, String) {
  member(fields, name) |> result.try(expect_number)
}

fn texts(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(List(String), String) {
  member(fields, name) |> result.try(expect_texts)
}

fn operation_id(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Result(OpId, String) {
  use raw <- result.try(text(fields, name))
  ids.parse_op_id(raw)
  |> result.map_error(fn(report) { corruption.describe(report) })
}

fn expect_text(value: JsonValue) -> Result(String, String) {
  case value {
    json.String(text) -> Ok(text)
    other -> Error("expected text, got " <> json.to_string(other))
  }
}

fn expect_number(value: JsonValue) -> Result(Int, String) {
  case value {
    json.Int(number) -> Ok(number)
    other -> Error("expected an integer, got " <> json.to_string(other))
  }
}

fn expect_texts(value: JsonValue) -> Result(List(String), String) {
  case value {
    json.Array(items) -> list.try_map(items, expect_text)
    other -> Error("expected a list of text, got " <> json.to_string(other))
  }
}

// A member that may be null or absent, decoded when it is present.
fn maybe(
  fields: List(#(String, JsonValue)),
  name: String,
  read_one: fn(JsonValue) -> Result(a, String),
) -> Result(Option(a), String) {
  case list.key_find(fields, name) {
    Error(Nil) | Ok(json.Null) -> Ok(None)
    Ok(present) -> read_one(present) |> result.map(Some)
  }
}
