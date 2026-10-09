//// The functions a session's workspace calls back into its owner through.
////
//// A session has two halves. The owner holds the conversation: the durable
//// store, the writer lease, the escalation records, the messaging plane and
//// every client connection. The workspace holds the checkout: the broker,
//// the helper pool, the tools that run against files, the background jobs
//// and the language servers. On one machine the halves share a VM, and the
//// workspace used to reach the owner by holding whatever it needed: a
//// borrowed `api.Runtime`, an `Agency` record of closures, a `FactHandle`.
//// Each of those is a local process address or a closure, so none of them
//// can cross to another node.
////
//// `OwnerServices` is the single place the workspace's owner-bound needs
//// are written down, as plain functions over plain data. Workspace code
//// takes the record (or a subset of it) instead of a runtime. Locally
//// every function calls straight through to what it replaced, so nothing
//// observable changes. A workspace on another node is given the same
//// record whose functions send messages, and the code on that side does
//// not change.
////
//// ## What each function is for
////
//// - `escalate` decides a policy refusal: it raises the durable record,
////   waits for a human when one is attached, and answers with the grants to
////   re-run under or a settled refusal.
//// - `facts` reads and writes two reserved namespaces of the session store
////   and nothing else. See `FactAccess`.
//// - `output` is where a running tool's rolling output tail is shown. It is
////   a lossy cast: a dropped tail costs a terminal a frame.
//// - `capability` answers a code-mode capability call whose state lives on
////   the owner (`strand.*`, `notes.*`, `schedule.*`, `peer.*`, `mcp.*`).
//// - `holds` asks whether a strand's tool list admits a tool, for the
////   per-call check a code-mode program is held to.
//// - `notify`, `strand_activity` and `wake` are the three things the
////   background-jobs actor says to a strand: the completion notice, a read
////   of whether the strand has an open run, and the idle heartbeat.
////
//// ## Why facts are fenced to two prefixes
////
//// Fact access is the one function group that could widen into a general
//// store door, so it is fenced where it is built rather than where it is
//// used. `client/working_directory/` holds a strand's remembered cwd and
//// `job/` holds the background-job records. Every other key, reserved or
//// not, is refused with `NotServed`, and the refusal is the same on both
//// placements.
////
//// ## What the fence does not do
////
//// The fence is scope hygiene. It keeps the workspace's code from reading or
//// writing session state it has no use for, and it keeps a bug there from
//// doing so by accident. It is not a security boundary against the node on
//// the other side. An executor is a trusted Erlang peer: it holds the
//// distribution cookie and a pinned certificate, and the owner port takes the
//// strand from the message. `notify`, `wake` and `capability` therefore act
//// on any strand of the session the executor names, and nothing in this
//// record stops an executor that has been compromised from doing so. The
//// protection against a hostile executor is the trust the operator places in
//// the machine (`docs/design-notes/distributed-runtime.md`), not this record.

import broker/framing.{type CapOutcome}
import client/escalate
import client/jobstate
import client/notice
import codemode/satellite.{type CapDenial}
import codemode/vet/policy as vet_policy
import core/ids.{type OpId, type Seq}
import core/json.{type JsonValue}
import core/msgpack.{type MsgPackValue}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import runtime/api
import runtime/effects
import tools/agent
import tools/tool

/// Everything the workspace reaches the owner for. Each field is a plain
/// function so that a placement can back it with a message.
pub type OwnerServices {
  OwnerServices(
    /// Decides one policy refusal. The workspace re-clears once when the
    /// answer is `Resume`.
    escalate: fn(escalate.Refused) -> escalate.Decision,
    /// The two reserved fact namespaces the workspace may touch.
    facts: FactAccess,
    /// The observer for one run's output tail. Resolved once per run, then
    /// called after every chunk.
    output: fn(effects.ToolRun) -> fn(tool.OutputTail) -> Nil,
    /// Answers one owner-bound code-mode capability call.
    capability: fn(OwnerCapCall) -> Result(CapOutcome, CapDenial),
    /// Whether a strand's active tool list holds the named tool.
    holds: fn(agent.Caller, String) -> Result(Nil, agent.Refusal),
    /// Sends a completion notice for `work` to a strand.
    notify: fn(String, notice.Work, String) -> Result(notice.Delivered, String),
    /// Whether a strand has an open run, read from its durable state.
    strand_activity: fn(String) -> Result(notice.Activity, String),
    /// Starts a run on an idle strand with the given text.
    wake: fn(String, String) -> Result(Nil, String),
  )
}

/// The slice of `OwnerServices` the background-jobs actor uses. It is a
/// subset, taken with `jobs_owner`, so the actor cannot reach for a
/// capability it has no business with.
pub type JobsOwner {
  JobsOwner(
    /// The `job/` records.
    facts: FactAccess,
    /// The completion notice.
    notify: fn(String, notice.Work, String) -> Result(notice.Delivered, String),
    /// Whether the owning strand is busy, for the idle clock.
    strand_activity: fn(String) -> Result(notice.Activity, String),
    /// The idle heartbeat.
    wake: fn(String, String) -> Result(Nil, String),
  )
}

/// The reserved fact namespaces the workspace may touch, as five plain
/// operations.
///
/// Keys outside the served prefixes are refused by every operation. The
/// compare-and-set `put` and the blind `put_blind` are separate because the
/// two have different races: `put` is for a cell more than one writer
/// could claim, `put_blind` for one whose only writer is the caller.
pub type FactAccess {
  FactAccess(
    /// The cell at a key, or `None` when it is absent.
    cell: fn(String) -> Result(Option(api.FactCell), FactFault),
    /// Writes a cell only if it is still at the sequence the caller read;
    /// `None` means it must still be absent. Answers the new sequence.
    put: fn(String, JsonValue, Option(Seq)) -> Result(Seq, FactFault),
    /// Overwrites a cell without comparing.
    put_blind: fn(String, JsonValue) -> Result(Nil, FactFault),
    /// Removes a cell. Removing an absent cell succeeds.
    delete: fn(String) -> Result(Nil, FactFault),
    /// Every cell under a served prefix, with its key.
    list: fn(String) -> Result(List(#(String, JsonValue)), FactFault),
  )
}

/// Why a fact operation did not happen. The cases are distinct because
/// callers answer them differently: a lost race is retried or reported, a
/// stolen lease means the session is no longer this process's, and an
/// absent store is not an error at all for a service which is starting up
/// or shutting down.
pub type FactFault {
  /// The owner's store could not be reached: no writer is bound yet, or
  /// the holder is gone. Nothing was attempted.
  StoreAbsent

  /// A compare-and-set lost: the cell moved since the caller read it.
  Conflict

  /// The writer lease is gone, so nothing this session commits can land.
  /// The remedy is to reopen the session, never to retry. `held_by` names
  /// the thief when the backend could see it.
  LeaseStolen(held_by: Option(String))

  /// The operation failed for any other reason. `detail` is the rendered
  /// cause, for a message a person reads.
  Failed(detail: String)

  /// The key is outside the namespaces this access serves. Nothing was
  /// attempted.
  NotServed(key: String)
}

/// One owner-bound code-mode capability call, as plain data.
///
/// It carries the coordinates the owner's routers derive from: the strand
/// is the authenticated caller, never an argument, and the operation, step
/// and source index name the call so a spawn is idempotent. `cap` and `args`
/// are the capability name and its marshalled arguments.
pub type OwnerCapCall {
  OwnerCapCall(
    /// The strand whose driver dispatched the `code_mode` call.
    strand: String,
    /// The pooled operation id.
    op_id: OpId,
    /// The pooled step id.
    step_id: String,
    /// The tool call's index within its step.
    source_index: Int,
    /// The seam the program was vetted and routed under.
    seam: vet_policy.Seam,
    /// The capability name, such as `strand.spawn`.
    cap: String,
    /// The marshalled arguments.
    args: MsgPackValue,
    /// This call's index among the calls of this capability in the
    /// execution, counting from zero.
    ordinal: Int,
  )
}

/// The reserved namespace a strand's remembered working directory lives in.
///
/// Owned here rather than by `client/working_directory` because this module
/// is what decides which prefixes are served, and the module which uses a
/// prefix imports this one.
pub const working_directory_prefix = "client/working_directory/"

/// The namespaces `FactAccess` serves, and the only ones.
///
/// ## Examples
///
/// ```gleam
/// assert owner_services.served_prefixes()
///   == ["client/working_directory/", "job/"]
/// ```
///
pub fn served_prefixes() -> List(String) {
  [working_directory_prefix, jobstate.key_prefix]
}

/// Takes the background-jobs slice of the owner's services.
///
/// ## Examples
///
/// ```gleam
/// // owner_services.jobs_owner(services).facts
/// ```
///
pub fn jobs_owner(services: OwnerServices) -> JobsOwner {
  JobsOwner(
    facts: services.facts,
    notify: services.notify,
    strand_activity: services.strand_activity,
    wake: services.wake,
  )
}

/// Fact access over a live runtime held in this VM.
///
/// `handle` serves the two operations a projected `FactHandle` can do
/// (`cell`, `put`), so a caller which keeps only the handle's supplier does
/// not retain the rest of the session. The other three need the whole
/// runtime and take `runtime`. Either supplier answering `Error(Nil)`
/// becomes `StoreAbsent`.
///
/// The access is fenced to `served_prefixes` before it touches either
/// supplier, so a key outside them never reaches the store.
///
/// ## Examples
///
/// ```gleam
/// // owner_services.local_facts(
/// //   handle: agency.fact_supplier(config),
/// //   runtime: agency.runtime_supplier(config),
/// // )
/// ```
///
pub fn local_facts(
  handle handle: fn() -> Result(api.FactHandle, Nil),
  runtime runtime: fn() -> Result(api.Runtime, Nil),
) -> FactAccess {
  FactAccess(
    cell: served(fn(key) {
      use facts <- result.try(absent_unless(handle()))
      api.fact_cell_with(facts, key) |> result.map_error(fault)
    }),
    put: fn(key, value, expected) {
      use <- fenced(key)
      use facts <- result.try(absent_unless(handle()))
      api.put_reserved_fact_expecting_with(facts, key, value, expected:)
      |> result.map_error(fault)
    },
    put_blind: fn(key, value) {
      use <- fenced(key)
      use live <- result.try(absent_unless(runtime()))
      api.put_reserved_fact(live, key, value) |> result.map_error(fault)
    },
    delete: served(fn(key) {
      use live <- result.try(absent_unless(runtime()))
      api.delete_reserved_fact(live, key) |> result.map_error(fault)
    }),
    list: fn(prefix) {
      use <- fenced(prefix)
      use live <- result.try(absent_unless(runtime()))
      api.reserved_facts(live, prefix:) |> result.map_error(fault)
    },
  )
}

// A single-key operation behind the fence. The fence is a function of the
// key alone, so every operation applies it before it reads anything.
fn served(
  operation: fn(String) -> Result(a, FactFault),
) -> fn(String) -> Result(a, FactFault) {
  fn(key) {
    use <- fenced(key)
    operation(key)
  }
}

// The fence itself: continue only when the key is under a served prefix.
fn fenced(
  key: String,
  continue: fn() -> Result(a, FactFault),
) -> Result(a, FactFault) {
  case list.any(served_prefixes(), string.starts_with(key, _)) {
    True -> continue()
    False -> Error(NotServed(key:))
  }
}

// A supplier answering `Error(Nil)` means no writer is bound; it is the
// only way a fact operation reports that the store is absent.
fn absent_unless(supplied: Result(a, Nil)) -> Result(a, FactFault) {
  result.replace_error(supplied, StoreAbsent)
}

// The api's failure vocabulary reduced to the three outcomes callers act on.
// Everything else keeps the api's own rendering, so a message built from it
// reads exactly as it did when the callers matched on `ApiError`. Every
// variant is named so that a new one forces a decision here rather than
// falling into `Failed`.
fn fault(error: api.ApiError) -> FactFault {
  case error {
    api.FactConflict(..) -> Conflict

    api.SessionStolen(held_by:) -> LeaseStolen(held_by:)

    api.RuntimeUnavailable
    | api.AcceptRejected(..)
    | api.QueueRejected(..)
    | api.ReadFailed(..)
    | api.CommitFailed(..)
    | api.RaceLost
    | api.ReservedFactKey(..)
    | api.UnreservedFactKey(..)
    | api.EscalationExists(..)
    | api.EscalationNotFound(..)
    | api.EscalationWrongStatus(..) -> Failed(detail: string.inspect(error))
  }
}

/// The notification half of the owner's services over a runtime held in
/// this VM: the completion notice, the activity read and the heartbeat.
///
/// A runtime which cannot be borrowed answers every call with the same
/// error text, which callers drop or report as they did before.
///
/// ## Examples
///
/// ```gleam
/// // let jobs = owner_services.local_jobs_owner(handle:, runtime:)
/// ```
///
pub fn local_jobs_owner(
  handle handle: fn() -> Result(api.FactHandle, Nil),
  runtime runtime: fn() -> Result(api.Runtime, Nil),
) -> JobsOwner {
  JobsOwner(
    facts: local_facts(handle:, runtime:),
    notify: fn(strand, work, text) {
      use live <- result.try(borrowed(runtime))
      notice.deliver(live, strand, work, text)
    },
    strand_activity: fn(strand) {
      use live <- result.try(borrowed(runtime))
      notice.activity(live, strand)
    },
    wake: fn(strand, text) {
      use live <- result.try(borrowed(runtime))
      notice.beat(live, strand, text)
    },
  )
}

fn borrowed(
  runtime: fn() -> Result(api.Runtime, Nil),
) -> Result(api.Runtime, String) {
  result.replace_error(runtime(), unavailable)
}

/// The text a call answers when the owner's runtime cannot be borrowed.
pub const unavailable = "the session runtime is not available"

/// A complete local `OwnerServices`: the jobs half over a borrowed runtime
/// and the four functions which come from elsewhere in the session
/// assembly. Nothing here is new behaviour; it only names, in one record,
/// what the workspace already reached for.
///
/// ## Examples
///
/// ```gleam
/// // owner_services.local(handle:, runtime:, escalate:, output:, capability:,
/// //   holds:)
/// ```
///
pub fn local(
  handle handle: fn() -> Result(api.FactHandle, Nil),
  runtime runtime: fn() -> Result(api.Runtime, Nil),
  escalate escalate: fn(escalate.Refused) -> escalate.Decision,
  output output: fn(effects.ToolRun) -> fn(tool.OutputTail) -> Nil,
  capability capability: fn(OwnerCapCall) -> Result(CapOutcome, CapDenial),
  holds holds: fn(agent.Caller, String) -> Result(Nil, agent.Refusal),
) -> OwnerServices {
  let jobs = local_jobs_owner(handle:, runtime:)
  OwnerServices(
    escalate:,
    facts: jobs.facts,
    output:,
    capability:,
    holds:,
    notify: jobs.notify,
    strand_activity: jobs.strand_activity,
    wake: jobs.wake,
  )
}

/// The capability answer for a host which has none to give: every owner
/// call is refused in band, naming why. Used where a session is assembled
/// without code mode.
///
/// ## Examples
///
/// ```gleam
/// // owner_services.no_capability(call) -> Error(CapDenial(..))
/// ```
///
pub fn no_capability(call: OwnerCapCall) -> Result(CapOutcome, CapDenial) {
  Error(satellite.CapDenial(
    code: "unsupported_cap",
    message: "this host serves no owner capability `" <> call.cap <> "`",
  ))
}
