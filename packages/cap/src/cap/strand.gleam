//// `cap/strand` starts, joins, and addresses other agents from inside a
//// code-mode program.
////
//// The default host admits this module in both workspace and orchestration
//// mode. A program can inspect files, run tools, and start child strands in
//// one jailed execution. An explicitly effect-only host has no Agency
//// custody and rejects this import (`codemode/vet/policy`). Every call is
//// still judged against the current strand's lineage and resource limits.
////
//// ## Flow
////
//// `assignment` → `spawn` → `wait` → `map` (batches of `admit_batch` and `join_batch`)
////
//// 1. `assignment` and the `with_*` builders describe one child; nothing
////    leaves the satellite until `spawn` runs.
//// 2. `spawn` sends `assignment_value` through `dispatch.call` and decodes
////    the admitted child with `decode_handle`.
//// 3. `wait` joins a list of handles against one shared deadline, slicing
////    windows through `wait_slice`, and decodes one `Waited` each with
////    `decode_waited`.
//// 4. `map` bounds the fan-out: `map_batches` admits a batch with
////    `admit_batch`, joins it with `join_batch`, and stops admitting as soon
////    as `batch_settled` says a child is unresolved.
//// 5. `send`, `note`, `notes` and `roster` address the rest of the
////    lineage; each is one `dispatch.call` whose refusal `map_error` turns
////    into a `StrandError`.
//// 6. `error_text`, `waited_text` and `handle_text` render the results for a
////    program that prints them.
////
//// # Why this exists at all
////
//// Every fan-out a model performs today is N `agent_spawn` calls plus an
//// `agent_wait`: each a tool call, each a turn, each occupying context,
//// and the plan exists only as a sequence of decisions rather than as an
//// artifact anyone can read, diff, or re-run. A program moves the loop
//// out of the conversation. The join stays exactly where it was — a list
//// of handles against one shared deadline — because that is already the
//// right shape.
////
//// Rule Zero (`docs/loom-design.md` §1.3) is what makes it a capability
//// rather than an interpreter: model-influenced execution never runs in
//// the harness VM, so an orchestration *script* has to run outside it,
//// which means it needs a channel back to the broker — and that channel
//// is this module. Rule Zero forbids running the orchestrator in the
//// harness; it does not forbid model-influenced code from *causing* a
//// harness commit, which every tool call already does.
////
//// # What is reused rather than invented
////
//// Every function here is an RPC stub whose call is serviced by the same
//// `client/agency` closures the `agent_*` tools call, judged against the
//// same `Caller` — the strand the program's own `code_mode` call was
//// dispatched on, which the harness supplies and no program can state.
//// So the authorization model is the tools': a strand may wait only on a
//// descendant and address only its parent or a descendant, the depth and
//// fan-out caps are counted from the durable lineage ledger, and every
//// refusal below carries one of the names those rules already refuse
//// under.
////
//// # The one rule that is new
////
//// `agent_spawn` is throttled by turn cost — the model pays a provider
//// round trip per spawn, so the economics bound the fan-out. **A loop
//// pays nothing.** Replacing the turn with a loop removes an implicit
//// throttle, so the seam adds an explicit one: a hard ceiling on
//// admissions per execution, refused in band *at* the ceiling. It is a
//// lifetime bound on admissions, not a live-children bound;
//// `FanOutCapReached` is still what answers a program that asks for more
//// children at once than its strand may have.
////
//// The same argument covers every call that mints something outliving
//// the execution, so four of the six are capped and two are not:
////
//// | call | ceiling | why |
//// |---|---|---|
//// | `spawn` | 32 | a child strand, durable |
//// | `send` | 128 | a durable commit, and to an idle child it starts a run |
//// | `note` | 256 | a durable register update under a chosen key |
//// | `notes` | 64 | a full prefix scan of the session's agent namespaces |
//// | `wait` | none | its cost is time, which the clamp and the deadline bind |
//// | `roster` | none | bounded by `session_strands`, a structural constant |
////
//// A spawn refused at its ceiling is `SpawnCeilingReached`; the other
//// three are `AdmissionCeilingReached`, whose message names the
//// capability and the number. **`note` and `notes` are one decision.**
//// A note/notes loop is quadratic in harness work, and the quadratic
//// needs both factors unbounded — capping either alone leaves it. Relax
//// one and you have relaxed both.
////
//// # What a satellite's death does and does not mean
////
//// The satellite is torn down when `main` returns, so a spawn this
//// program never joins is a spawn whose result cannot reach *this
//// program*. It is not lost: the child's terminal transaction writes its
//// result durably, and the parent strand collects it on a later turn
//// through the ordinary `agent_wait`. By the same token a message a child
//// sends after the program has returned reaches the *strand*, not the
//// program: under the two-channel doctrine a payload travels in a commit
//// and only the wake signal is ephemeral, so it is drained at the
//// parent's next checkpoint rather than dropped.

import cap/internal/channel.{type CallError, Denied, Unreachable}
import cap/internal/dispatch
import cap/internal/wire
import cap/report.{type Value}
import core/ids
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A validated durable operation identity, shared with the harness.
pub type OpId =
  ids.OpId

/// A validated durable entry identity, shared with the harness.
pub type EntryId =
  ids.EntryId

/// Parses a UUIDv7 operation identity without importing harness modules.
///
/// ## Examples
///
/// ```gleam
/// assert strand.parse_op_id("invalid") == Error("invalid operation UUIDv7")
/// ```
pub fn parse_op_id(text: String) -> Result(OpId, String) {
  ids.parse_op_id(text) |> result.replace_error("invalid operation UUIDv7")
}

/// Renders an operation identity in its canonical wire form.
///
/// ## Examples
///
/// ```gleam
/// // strand.op_id_to_string(handle.operation)
/// ```
pub fn op_id_to_string(id: OpId) -> String {
  ids.op_id_to_string(id)
}

/// Parses a UUIDv7 entry identity from a saved reference.
///
/// ## Examples
///
/// ```gleam
/// assert strand.parse_entry_id("invalid") == Error("invalid entry UUIDv7")
/// ```
pub fn parse_entry_id(text: String) -> Result(EntryId, String) {
  ids.parse_entry_id(text) |> result.replace_error("invalid entry UUIDv7")
}

/// Renders an entry identity in its canonical wire form.
///
/// ## Examples
///
/// ```gleam
/// // strand.entry_id_to_string(entry)
/// ```
pub fn entry_id_to_string(id: EntryId) -> String {
  ids.entry_id_to_string(id)
}

/// How much longer than the requested join window this module will wait
/// on the channel before calling the harness unreachable.
///
/// The harness clamps a join to its own ceiling and answers `Pending`
/// rather than hanging, so this margin covers the round trip and the
/// clamp, never the wait itself.
pub const wait_margin_ms = 10_000

/// The maximum duration in milliseconds of a single join request sent to
/// the harness. The shipped host clamps each `strand.wait` capability
/// call to its own `max_wait_ms` ceiling (30 s), so `wait` slices longer
/// requested windows into requests of at most this duration. A host
/// whose ceiling sits lower than this slice is still accounted
/// honestly — the slicing loop measures each slice by the host's own
/// reported `waited_ms`, not by the slice it requested — so this bound
/// governs only how many requests are made, never how time is counted.
pub const max_wait_slice_ms = 30_000

// --- what a call answers with --------------------------------------------

/// A durable reference to one child operation, as `spawn` minted it. It
/// names nothing process-local, so it survives a restart.
pub type Handle {
  Handle(
    /// The child strand named by the host.
    strand: String,
    /// The specific durable run, validated before the handle is returned.
    operation: OpId,
  )
}

/// Where a child's context starts.
pub type Provenance {
  /// At the root: the child reads its brief and nothing else.
  Fresh

  /// At the calling strand's current leaf, copying its whole conversation
  /// into the child's context window.
  MyConversation
}

/// The closed set of types a declared result field may have — the same
/// vocabulary the harness enforces, and no wider. A schema the harness
/// cannot check is refused rather than accepted and ignored, so there is
/// deliberately no way to spell a pattern, an enum, or a bound.
pub type FieldType {
  /// Text.
  StringField

  /// A whole number.
  IntegerField

  /// Any number, whole or not.
  NumberField

  /// A boolean.
  BooleanField

  /// An object, its own fields undescribed.
  ObjectField

  /// A list of `items`.
  ArrayField(items: FieldType)

  /// Anything at all, `null` included.
  AnyField
}

/// Whether the child's result must contain a declared field.
pub type Requirement {
  /// A result without the field fails its declared schema.
  Required

  /// The field may be absent, but a present value must match its type.
  Optional
}

/// One field of the result shape a spawn demands of its child.
pub type Field {
  Field(
    /// The result object key.
    name: String,
    /// The value type the host checks when the key is present.
    expects: FieldType,
    /// Whether absence violates the declared result schema.
    required: Requirement,
  )
}

/// A field the child must report.
///
/// ## Examples
///
/// ```gleam
/// assert strand.required("count", strand.IntegerField).required == strand.Required
/// ```
///
pub fn required(name: String, expects: FieldType) -> Field {
  Field(name:, expects:, required: Required)
}

/// A field the child may report.
///
/// ## Examples
///
/// ```gleam
/// assert strand.optional("note", strand.StringField).required == strand.Optional
/// ```
///
pub fn optional(name: String, expects: FieldType) -> Field {
  Field(name:, expects:, required: Optional)
}

/// How a child's operation ended.
pub type Outcome {
  /// The run finished normally.
  Completed

  /// The run failed terminally.
  Failed(reason: String)

  /// The run was aborted — deadline, reap, or operator.
  Aborted
}

/// The verdict on the structured result a spawn asked for.
///
/// Four facts, three of which are not failures, so a program branches on
/// what it actually got rather than on a `Result` that flattens "nobody
/// asked" into "nobody answered".
pub type TerminalResult {
  /// The spawn declared no result shape.
  NoResultAsked

  /// The child recorded a result and it matched the declared shape.
  ResultGiven(value: Value)

  /// A shape was asked for and the child's run ended without recording
  /// one.
  ResultAbsent(schema: String)

  /// A result is there and does not match. `reason` names the field, the
  /// type wanted and the type found.
  ResultUnusable(schema: String, received: Value, reason: String)
}

/// One handle's position when a join returned.
pub type Waited {
  /// The operation settled. `report` is the child's final assistant text,
  /// `result` the verdict on the shape the spawn demanded, and `notes`
  /// its blackboard cells.
  Ready(
    handle: Handle,
    outcome: Outcome,
    report: String,
    result: TerminalResult,
    notes: List(#(String, Value)),
  )

  /// The deadline expired first. An answer, not a failure: join again, or
  /// do other work and come back.
  Pending(handle: Handle, waited_ms: Int)
}

/// How a `send` payload landed.
pub type Delivery {
  /// The target had an open run: the message is a durable steer on it.
  Steered(
    /// The committed pending-message identity.
    entry: EntryId,
  )

  /// The target was idle: the message was accepted as a fresh run.
  Started(
    /// The newly admitted durable run.
    operation: OpId,
  )
}

/// How a peer stands in relation to the calling strand.
pub type Relation {
  /// The strand that spawned the caller.
  ParentOf

  /// A strand the caller spawned.
  ChildOf
}

/// One entry in the roster: a durable read of the lineage ledger, not of
/// process state, so it is still correct after a restart and after
/// compaction has erased every handle from a model's context.
pub type Peer {
  Peer(
    strand: String,
    relation: Relation,
    handle: Option(Handle),
    outcome: Option(Outcome),
    tools: List(String),
  )
}

/// Why a call was refused.
///
/// Every variant but the last three is one of the harness's own refusal
/// names, carrying the harness's own sentence verbatim: the authorization
/// model this seam runs under is `client/agency`'s, reused rather than
/// re-derived, and a refusal renamed on the way out would be a second
/// vocabulary for one decision. `message` is not decoration — it names
/// the strand, the cap, or the field that the name alone does not.
pub type StrandError {
  /// This host wired no messaging plane, or its holder is not up yet.
  StrandsUnavailable(message: String)

  /// A handle did not parse.
  MalformedHandle(message: String)

  /// The named strand is not the caller's parent and not a descendant of
  /// it. Also the answer for a strand with no lineage cell at all: "no
  /// lineage fact" means "not a descendant", never "unknown, allow".
  NotAddressable(message: String)

  /// A join named a strand that is not a descendant of the caller. Joins
  /// are strictly downward — that is what keeps the wait graph acyclic.
  NotADescendant(message: String)

  /// The calling strand is already at the spawning depth cap.
  DepthCapReached(message: String)

  /// The caller, or the session, already has as many live strands as it
  /// may have.
  FanOutCapReached(message: String)

  /// The spawn asked for a tool the calling strand does not itself hold.
  /// A child may narrow its parent's set, never widen it.
  UnknownTool(message: String)

  /// An argument was unusable — an empty purpose, too many handles, a
  /// blackboard key outside the allowed shape, a result shape the
  /// harness cannot enforce.
  InvalidArgument(message: String)

  /// The name this spawn derives is already a child's, minted by a
  /// different call. Reconciliation hands an existing child back on a
  /// name match, but only to the caller that minted it; anything else
  /// would be an ownership transfer. Nothing was started — spawn again
  /// under a different purpose.
  NameAlreadyMinted(message: String)

  /// A send upward would have *started* a run rather than steered one:
  /// the parent has finished and nobody is watching it.
  ParentRunEnded(message: String)

  /// A note did not match the result shape this strand's own spawn
  /// demanded of it.
  ResultSchemaUnmet(message: String)

  /// The durable plane refused or failed underneath the call — a commit,
  /// a read, a decode. Not the program's mistake and not a bound it hit:
  /// the harness could not carry out a call it had no objection to.
  PlaneFailed(message: String)

  /// This execution has admitted as many spawns as it may. The seam's own
  /// ceiling; see the module doc for why a loop needs one where a turn
  /// did not.
  SpawnCeilingReached(message: String)

  /// This execution has admitted as many calls of some *other* capped
  /// capability — `send`, `note` or `notes` — as it may. One variant for
  /// the three because the answer to all three is the same, stop looping,
  /// and the message names which capability, what the number was, and
  /// that the bound is for the execution's whole lifetime. Retrying, or
  /// waiting first, will not free one.
  AdmissionCeilingReached(message: String)

  /// Any other in-band refusal, its code preserved.
  StrandRefused(code: String, message: String)

  /// The host answered, but its payload did not satisfy this API.
  StrandResultMalformed(reason: String)

  /// The capability channel could not carry the call.
  StrandUnavailable(reason: String)
}

// --- spawning --------------------------------------------------------------

/// One assignment, built up before it is spawned.
///
/// Opaque, so a non-empty purpose and brief hold by construction and the
/// wire shape stays this module's to change. Build it with `assignment`
/// and narrow it with the pipeable steps below.
pub opaque type Assignment {
  Assignment(
    purpose: String,
    brief: String,
    model: Option(String),
    within_ms: Option(Int),
    detach: Bool,
    context: Provenance,
    tools: Option(List(String)),
    result_schema: List(Field),
  )
}

/// An assignment: what the child is for, and what it is being told.
///
/// `purpose` is what the child's minted name is derived from, so two
/// spawns in one program that share a purpose are two spawns the harness
/// cannot tell apart — give each one its own.
///
/// ## Examples
///
/// ```gleam
/// // strand.assignment(purpose: "review core", brief: "look for …")
/// ```
///
pub fn assignment(purpose purpose: String, brief brief: String) -> Assignment {
  Assignment(
    purpose:,
    brief:,
    model: None,
    within_ms: None,
    detach: False,
    context: Fresh,
    tools: None,
    result_schema: [],
  )
}

/// Selects a configured model by catalogue name for the child's first run.
///
/// The host refuses unknown names before creating a child. Without this step,
/// the assignment uses the host's subagent route or inherits the parent model.
/// The chosen entry also supplies the child's initial thinking level.
///
/// ## Examples
///
/// ```gleam
/// // strand.assignment(purpose: "review", brief: "Check the change")
/// // |> strand.with_model("reviewer")
/// // |> strand.spawn
/// ```
pub fn with_model(assignment: Assignment, name: String) -> Assignment {
  Assignment(..assignment, model: Some(name))
}

/// Gives the child a wall budget of its own, in milliseconds.
pub fn within(assignment: Assignment, milliseconds: Int) -> Assignment {
  Assignment(..assignment, within_ms: Some(milliseconds))
}

/// Detaches the child, so the calling strand's run end does not reap it.
pub fn detached(assignment: Assignment) -> Assignment {
  Assignment(..assignment, detach: True)
}

/// Starts the child at the calling strand's own leaf, copying its whole
/// conversation, rather than at the root with only its brief.
pub fn from_my_conversation(assignment: Assignment) -> Assignment {
  Assignment(..assignment, context: MyConversation)
}

/// Narrows the child's tool set. It may only ever narrow the calling
/// strand's own set; naming a tool the caller does not hold is
/// `UnknownTool`.
pub fn with_tools(assignment: Assignment, names: List(String)) -> Assignment {
  Assignment(..assignment, tools: Some(names))
}

/// Demands a result shape of the child, which the harness holds it to on
/// its own terminal write — so a program that joins can branch on typed
/// fields instead of parsing prose.
///
/// ## Examples
///
/// ```gleam
/// // strand.assignment(purpose: p, brief: b)
/// // |> strand.expecting([strand.required("count", strand.IntegerField)])
/// ```
///
pub fn expecting(assignment: Assignment, fields: List(Field)) -> Assignment {
  Assignment(..assignment, result_schema: fields)
}

/// Starts a child strand and returns a durable handle to its brief run.
///
/// Returns as soon as the harness has admitted the child; the work
/// happens on the child's own strand, and `wait` is how a program learns
/// what it produced.
///
/// Capability: `strand.spawn`.
pub fn spawn(assignment: Assignment) -> Result(Handle, StrandError) {
  let args = assignment_value(assignment)
  use value <- result.try(
    dispatch.call("strand.spawn", args) |> result.map_error(map_error),
  )
  decode_handle(value) |> result.map_error(malformed("strand.spawn"))
}

// --- joining ---------------------------------------------------------------

/// Waits for every handle against **one** shared deadline and answers one
/// `Waited` per handle, in the order given.
///
/// One deadline rather than one per handle is the whole point: joining
/// eight children costs one window, not eight. A handle whose operation
/// has not settled by then comes back `Pending`, which is an answer — the
/// program may join again, or go on and let the parent strand collect the
/// result on a later turn.
///
/// The harness clamps any single join request to its own `max_wait_ms`
/// ceiling (30 s). Rather than ending the join at its ceiling, `wait`
/// re-issues the join on the still-pending handles until they settle or
/// the requested window is spent, so a program that asks for
/// `within_ms: 880_000` actually waits up to that window. A `Pending`
/// answer's `waited_ms` accumulates across those slices, so it still
/// reports time against the program's whole window.
///
/// Capability: `strand.wait`.
pub fn wait(
  handles: List(Handle),
  within_ms within_ms: Int,
) -> Result(List(Waited), StrandError) {
  case handles {
    [] -> Ok([])
    _ -> do_wait(handles, handles, within_ms, dict.new(), 0)
  }
}

// Slices a long join across multiple capability calls of at most 30 s each
// until all handles settle or the caller's requested deadline has expired.
fn do_wait(
  original_handles: List(Handle),
  pending_handles: List(Handle),
  remaining_ms: Int,
  settled: Dict(String, Waited),
  total_waited_ms: Int,
) -> Result(List(Waited), StrandError) {
  case pending_handles {
    [] -> Ok(assemble_waited(original_handles, settled))

    _ -> {
      let slice_ms = case remaining_ms > max_wait_slice_ms {
        True -> max_wait_slice_ms
        False -> int.max(0, remaining_ms)
      }

      use waited <- result.try(wait_slice(pending_handles, slice_ms))

      step_wait(
        original_handles,
        pending_handles,
        waited,
        remaining_ms,
        settled,
        total_waited_ms,
        slice_ms,
      )
    }
  }
}

// Processes the result of a single wait slice, advancing the accumulated
// waited time and deciding whether to poll again or conclude the join.
fn step_wait(
  original_handles: List(Handle),
  pending_handles: List(Handle),
  waited: List(Waited),
  remaining_ms: Int,
  settled: Dict(String, Waited),
  total_waited_ms: Int,
  slice_ms: Int,
) -> Result(List(Waited), StrandError) {
  let returned_handles = list.map(waited, fn(item) { item.handle })

  // A host answer that names handles this call did not ask for is a
  // malformed result, not an unreachable plane: the honest variant is the
  // one a program can branch on, and `join_batch` relies on the same
  // check through `wait`.
  case returned_handles == pending_handles {
    False -> Error(StrandResultMalformed("wait returned mismatched handles"))

    True -> {
      let new_settled =
        update_settled(waited, settled, total_waited_ms, slice_ms)
      let still_pending = filter_pending(pending_handles, new_settled)

      case still_pending {
        [] -> Ok(assemble_waited(original_handles, new_settled))

        _ -> {
          let slice_waited = slice_elapsed(waited, slice_ms)

          case slice_waited <= 0 || remaining_ms <= slice_waited {
            True -> Ok(assemble_waited(original_handles, new_settled))

            False ->
              do_wait(
                original_handles,
                still_pending,
                remaining_ms - slice_waited,
                new_settled,
                total_waited_ms + slice_waited,
              )
          }
        }
      }
    }
  }
}

// Performs one bounded capability call to the harness.
fn wait_slice(
  handles: List(Handle),
  within_ms: Int,
) -> Result(List(Waited), StrandError) {
  let args =
    wire.args([
      #("handles", encode_handles(handles)),
      #("within_ms", wire.int(within_ms)),
    ])

  use value <- result.try(
    dispatch.call_within("strand.wait", args, within_ms + wait_margin_ms)
    |> result.map_error(map_error),
  )
  wire.array_of(value, "waited", of: decode_waited)
  |> result.map_error(malformed("strand.wait"))
}

// Merges newly observed slice results into the settled map, accumulating
// elapsed wait time for any handles that remain pending.
//
// The host's per-slice `waited_ms` is the measure, taken as reported:
// the agency computes it from its own clock as the time the wait loop
// actually ran, so a host whose ceiling sits below the slice this
// module requested is still accounted by what elapsed, never by the
// request. Zero is reported honestly by a zero-window probe and taken
// at face value — nothing was charged and nothing elapsed.
fn update_settled(
  waited: List(Waited),
  settled: Dict(String, Waited),
  total_waited_ms: Int,
  _slice_ms: Int,
) -> Dict(String, Waited) {
  list.fold(waited, settled, fn(acc, item) {
    case item {
      Ready(..) -> dict.insert(acc, handle_text(item.handle), item)

      Pending(handle:, waited_ms:) ->
        dict.insert(
          acc,
          handle_text(handle),
          Pending(handle:, waited_ms: total_waited_ms + waited_ms),
        )
    }
  })
}

// Identifies which handles from the slice still need further waiting.
fn filter_pending(
  pending_handles: List(Handle),
  settled: Dict(String, Waited),
) -> List(Handle) {
  list.filter(pending_handles, fn(h) {
    case dict.get(settled, handle_text(h)) {
      Ok(Ready(..)) -> False
      _ -> True
    }
  })
}

// How much wall time this slice consumed, from the host's own reports:
// the largest pending `waited_ms` is what the agency's clock measured
// for this slice, whatever ceiling actually fired. Zero is a real
// answer — a zero-window probe reports it — and `step_wait` treats a
// zero-length slice as the join's end rather than looping on it.
fn slice_elapsed(waited: List(Waited), _slice_ms: Int) -> Int {
  list.fold(waited, 0, fn(acc, item) {
    case item {
      Pending(waited_ms:, ..) -> int.max(acc, waited_ms)
      Ready(..) -> acc
    }
  })
}

// Reassembles the final waited list in the caller's original handle order.
fn assemble_waited(
  original_handles: List(Handle),
  settled: Dict(String, Waited),
) -> List(Waited) {
  list.filter_map(original_handles, fn(h) { dict.get(settled, handle_text(h)) })
}

// --- addressing ------------------------------------------------------------

/// Delivers one attributed message to the calling strand's parent or to
/// one of its descendants.
///
/// The payload travels in a commit and only the wake signal is
/// ephemeral, so a message to a strand that is not running now is drained
/// at its next checkpoint rather than lost.
///
/// An active run consumes steering after its complete current tool batch and
/// before the next generation. Inspection does not require waiting for that
/// checkpoint: `cap/peer.inbox` reads caller-owned pending inputs, and
/// `cap/peer.history` reads materialized inputs. Acceptance is not a read receipt.
///
/// ## Examples
///
/// ```gleam
/// // strand.send(to: "main", text: "Review ready.")
/// ```
///
/// Capability: `strand.send`.
pub fn send(to to: String, text text: String) -> Result(Delivery, StrandError) {
  let args = wire.args([#("to", wire.string(to)), #("text", wire.string(text))])
  use value <- result.try(
    dispatch.call("strand.send", args) |> result.map_error(map_error),
  )
  decode_delivery(value) |> result.map_error(malformed("strand.send"))
}

/// Writes one blackboard cell under the calling strand's own namespace.
/// The key is forced under that namespace by the harness, so a program
/// cannot address another strand's notes or a reserved cell.
///
/// Capability: `strand.note`.
pub fn note(key key: String, value value: Value) -> Result(Nil, StrandError) {
  let args = wire.args([#("key", wire.string(key)), #("value", value)])
  dispatch.call("strand.note", args)
  |> result.replace(Nil)
  |> result.map_error(map_error)
}

/// Reads blackboard cells under a key prefix, relative to the shared
/// blackboard namespace. `None` reads the whole blackboard.
///
/// Capability: `strand.notes`.
pub fn notes(
  prefix: Option(String),
) -> Result(List(#(String, Value)), StrandError) {
  let args = wire.args([#("prefix", optional_string(prefix))])
  use value <- result.try(
    dispatch.call("strand.notes", args) |> result.map_error(map_error),
  )
  wire.array_of(value, "notes", of: decode_note)
  |> result.map_error(malformed("strand.notes"))
}

/// The calling strand's parent and its live descendants, read from the
/// durable lineage ledger.
///
/// Capability: `strand.roster`.
pub fn roster() -> Result(List(Peer), StrandError) {
  use value <- result.try(
    dispatch.call("strand.roster", wire.args([]))
    |> result.map_error(map_error),
  )
  wire.array_of(value, "peers", of: decode_peer)
  |> result.map_error(malformed("strand.roster"))
}

// --- encoding --------------------------------------------------------------

fn provenance_name(context: Provenance) -> String {
  case context {
    Fresh -> "fresh"
    MyConversation -> "my_conversation"
  }
}

fn optional_int(value: Option(Int)) -> Value {
  case value {
    None -> report.null()
    Some(number) -> wire.int(number)
  }
}

fn optional_string(value: Option(String)) -> Value {
  case value {
    None -> report.null()
    Some(text) -> wire.string(text)
  }
}

fn optional_strings(value: Option(List(String))) -> Value {
  case value {
    None -> report.null()
    Some(names) -> wire.string_array(names)
  }
}

// The declared shape crosses as a list of field descriptors, not as a
// schema document. The harness builds the schema itself from these and
// runs it through its own total parser, so a program cannot smuggle a
// constraint the harness would render into a child's brief without ever
// checking (`tools/agent.parse_result_schema`).
fn encode_schema(fields: List(Field)) -> Value {
  // Nothing asked for is *nothing*, not an empty list: a program that
  // declared no shape and one that declared an empty one would otherwise
  // be the same frame, and the harness's `NoResultAsked` verdict exists
  // to keep them apart.
  use <- unless_empty(fields)
  report.list(
    list.map(fields, fn(field) {
      wire.args([
        #("name", wire.string(field.name)),
        #("type", wire.string(field_type_name(field.expects))),
        #("items", encode_items(field.expects)),
        #("required", wire.bool(field.required == Required)),
      ])
    }),
  )
}

// `use <- unless_empty(fields)` — answers `null` for an empty list and
// otherwise runs the continuation. A tiny combinator rather than a
// `case`, so the encoder below reads as one expression.
fn unless_empty(fields: List(Field), then: fn() -> Value) -> Value {
  case fields {
    [] -> report.null()
    [_, ..] -> then()
  }
}

fn field_type_name(expects: FieldType) -> String {
  case expects {
    StringField -> "string"
    IntegerField -> "integer"
    NumberField -> "number"
    BooleanField -> "boolean"
    ObjectField -> "object"
    ArrayField(items: _) -> "array"
    AnyField -> "any"
  }
}

// An array's element type nests, so it is carried as a nested descriptor
// rather than flattened into the type name.
fn encode_items(expects: FieldType) -> Value {
  case expects {
    ArrayField(items:) ->
      wire.args([
        #("type", wire.string(field_type_name(items))),
        #("items", encode_items(items)),
      ])
    StringField
    | IntegerField
    | NumberField
    | BooleanField
    | ObjectField
    | AnyField -> report.null()
  }
}

fn encode_handles(handles: List(Handle)) -> Value {
  report.list(
    list.map(handles, fn(handle) {
      wire.args([
        #("strand", wire.string(handle.strand)),
        #("operation", wire.string(op_id_to_string(handle.operation))),
      ])
    }),
  )
}

// --- decoding --------------------------------------------------------------
//
// Every decoder here is total over the wire's value type: a field of the
// wrong shape is a `String` fault this module turns into
// `StrandResultMalformed`, never a crash. The harness is trusted to be
// well-behaved; the decoders exist because a malformed answer must still
// settle in band (design §9).

fn malformed(cap: String) -> fn(String) -> StrandError {
  fn(reason) { StrandResultMalformed("bad " <> cap <> " result: " <> reason) }
}

fn decode_handle(value: Value) -> Result(Handle, String) {
  use strand <- result.try(wire.string_field(value, "strand"))
  use operation_text <- result.try(wire.string_field(value, "operation"))
  use operation <- result.try(parse_op_id(operation_text))
  Ok(Handle(strand:, operation:))
}

fn decode_waited(value: Value) -> Result(Waited, String) {
  use kind <- result.try(wire.string_field(value, "kind"))
  use handle <- result.try(decode_handle(value))
  case kind {
    "pending" -> {
      use waited_ms <- result.try(wire.int_field(value, "waited_ms"))
      Ok(Pending(handle:, waited_ms:))
    }
    "ready" -> {
      use outcome <- result.try(decode_outcome_field(value, "outcome"))
      use report <- result.try(wire.string_field(value, "report"))
      use result <- result.try(decode_terminal_result(value))
      use notes <- result.try(wire.array_of(value, "notes", of: decode_note))
      Ok(Ready(handle:, outcome:, report:, result:, notes:))
    }
    other -> Error("unknown waited kind " <> other)
  }
}

fn decode_outcome_field(value: Value, key: String) -> Result(Outcome, String) {
  use found <- result.try(wire.field(value, key))
  decode_outcome(found)
}

fn decode_outcome(value: Value) -> Result(Outcome, String) {
  use kind <- result.try(wire.string_field(value, "kind"))
  case kind {
    "completed" -> Ok(Completed)
    "aborted" -> Ok(Aborted)
    "failed" -> {
      use reason <- result.try(wire.string_field(value, "reason"))
      Ok(Failed(reason:))
    }
    other -> Error("unknown outcome kind " <> other)
  }
}

fn decode_terminal_result(value: Value) -> Result(TerminalResult, String) {
  use found <- result.try(wire.field(value, "result"))
  use kind <- result.try(wire.string_field(found, "kind"))
  case kind {
    "none" -> Ok(NoResultAsked)
    "given" -> {
      use given <- result.try(wire.field(found, "value"))
      Ok(ResultGiven(value: given))
    }
    "absent" -> {
      use schema <- result.try(wire.string_field(found, "schema"))
      Ok(ResultAbsent(schema:))
    }
    "unusable" -> {
      use schema <- result.try(wire.string_field(found, "schema"))
      use received <- result.try(wire.field(found, "received"))
      use reason <- result.try(wire.string_field(found, "reason"))
      Ok(ResultUnusable(schema:, received:, reason:))
    }
    other -> Error("unknown result kind " <> other)
  }
}

fn decode_note(value: Value) -> Result(#(String, Value), String) {
  use key <- result.try(wire.string_field(value, "key"))
  use held <- result.try(wire.field(value, "value"))
  Ok(#(key, held))
}

fn decode_delivery(value: Value) -> Result(Delivery, String) {
  use kind <- result.try(wire.string_field(value, "kind"))
  case kind {
    "steered" -> {
      use entry_text <- result.try(wire.string_field(value, "entry"))
      use entry <- result.try(parse_entry_id(entry_text))
      Ok(Steered(entry:))
    }
    "started" -> {
      use operation_text <- result.try(wire.string_field(value, "operation"))
      use operation <- result.try(parse_op_id(operation_text))
      Ok(Started(operation:))
    }
    other -> Error("unknown delivery kind " <> other)
  }
}

fn decode_peer(value: Value) -> Result(Peer, String) {
  use strand <- result.try(wire.string_field(value, "strand"))
  use relation <- result.try(decode_relation(value))
  use handle <- result.try(case wire.optional_field(value, "handle") {
    None -> Ok(None)
    Some(found) -> decode_handle(found) |> result.map(Some)
  })
  use outcome <- result.try(case wire.optional_field(value, "outcome") {
    None -> Ok(None)
    Some(found) -> decode_outcome(found) |> result.map(Some)
  })
  use tools <- result.try(decode_tools(value))
  Ok(Peer(strand:, relation:, handle:, outcome:, tools:))
}

fn decode_relation(value: Value) -> Result(Relation, String) {
  use relation <- result.try(wire.string_field(value, "relation"))
  case relation {
    "parent" -> Ok(ParentOf)
    "child" -> Ok(ChildOf)
    other -> Error("unknown relation " <> other)
  }
}

fn decode_tools(value: Value) -> Result(List(String), String) {
  wire.array_of(value, "tools", of: fn(item) {
    report.as_string(item) |> result.replace_error("a tool name is not text")
  })
}

// --- refusals --------------------------------------------------------------

// The harness's own refusal name, recovered from the broker's in-band
// code. An unrecognized code is not swallowed: it comes back as
// `StrandRefused` carrying the code verbatim, so a name this module has
// not learned yet still reaches the program as itself.
fn map_error(error: CallError) -> StrandError {
  case error {
    Unreachable(reason:) -> StrandUnavailable(reason:)
    Denied(code:, message:) ->
      case code {
        "strands_unavailable" -> StrandsUnavailable(message:)
        "malformed_handle" -> MalformedHandle(message:)
        "not_addressable" -> NotAddressable(message:)
        "not_a_descendant" -> NotADescendant(message:)
        "depth_cap" -> DepthCapReached(message:)
        "fan_out_cap" -> FanOutCapReached(message:)
        "unknown_tool" -> UnknownTool(message:)
        "invalid_argument" -> InvalidArgument(message:)
        "name_already_minted" -> NameAlreadyMinted(message:)
        "parent_run_ended" -> ParentRunEnded(message:)
        "result_schema_unmet" -> ResultSchemaUnmet(message:)
        "plane_failed" -> PlaneFailed(message:)
        "spawn_ceiling" -> SpawnCeilingReached(message:)
        "admission_ceiling" -> AdmissionCeilingReached(message:)
        _ -> StrandRefused(code:, message:)
      }
  }
}

/// A one-line rendering of a refusal, for a program building a report out
/// of what went wrong rather than branching on it.
///
/// ## Examples
///
/// ```gleam
/// assert strand.error_text(strand.NotADescendant("x")) == "not_a_descendant: x"
/// ```
///
pub fn error_text(error: StrandError) -> String {
  case error {
    StrandsUnavailable(message:) -> "strands_unavailable: " <> message
    MalformedHandle(message:) -> "malformed_handle: " <> message
    NotAddressable(message:) -> "not_addressable: " <> message
    NotADescendant(message:) -> "not_a_descendant: " <> message
    DepthCapReached(message:) -> "depth_cap: " <> message
    FanOutCapReached(message:) -> "fan_out_cap: " <> message
    UnknownTool(message:) -> "unknown_tool: " <> message
    InvalidArgument(message:) -> "invalid_argument: " <> message
    NameAlreadyMinted(message:) -> "name_already_minted: " <> message
    ParentRunEnded(message:) -> "parent_run_ended: " <> message
    ResultSchemaUnmet(message:) -> "result_schema_unmet: " <> message
    PlaneFailed(message:) -> "plane_failed: " <> message
    SpawnCeilingReached(message:) -> "spawn_ceiling: " <> message
    AdmissionCeilingReached(message:) -> "admission_ceiling: " <> message
    StrandRefused(code:, message:) -> code <> ": " <> message
    StrandResultMalformed(reason:) -> "malformed_result: " <> reason
    StrandUnavailable(reason:) -> "unavailable: " <> reason
  }
}

/// A handle rendered as the text the harness and the model both use,
/// `{strand}#{operation}`.
///
/// ## Examples
///
/// ```gleam
/// let text = "00000000-0000-7000-8000-000000000001"
/// let assert Ok(operation) = strand.parse_op_id(text)
/// assert strand.handle_text(strand.Handle("sub:a", operation)) == "sub:a#" <> text
/// ```
///
pub fn handle_text(handle: Handle) -> String {
  handle.strand <> "#" <> op_id_to_string(handle.operation)
}

/// How long a join actually waited, summed over the handles still
/// pending — a program pacing itself against its own deadline needs the
/// number and would otherwise fold it out of `Waited` by hand.
///
/// ## Examples
///
/// ```gleam
/// assert strand.pending_count([]) == 0
/// ```
///
pub fn pending_count(waited: List(Waited)) -> Int {
  list.fold(waited, 0, fn(count, one) {
    case one {
      Pending(..) -> count + 1
      Ready(..) -> count
    }
  })
}

/// A one-line rendering of one joined handle, for the same reason
/// `error_text` exists: a program that reduces a fan-out to a report
/// should not have to spell the vocabulary out itself.
///
/// ## Examples
///
/// ```gleam
/// // strand.waited_text(ready) == "sub:a#op_1 completed"
/// ```
///
pub fn waited_text(one: Waited) -> String {
  case one {
    Pending(handle:, waited_ms:) ->
      handle_text(handle)
      <> " pending after "
      <> int.to_string(waited_ms)
      <> "ms"
    Ready(handle:, outcome:, ..) ->
      handle_text(handle) <> " " <> outcome_text(outcome)
  }
}

fn outcome_text(outcome: Outcome) -> String {
  case outcome {
    Completed -> "completed"
    Failed(reason:) -> "failed: " <> reason
    Aborted -> "aborted"
  }
}

/// Encodes the same assignment for ordinary and durable named child steps.
///
/// ## Examples
///
/// ```gleam
/// // strand.assignment_value(assignment)
/// ```
@internal
pub fn assignment_value(assignment: Assignment) -> Value {
  wire.args([
    #("purpose", wire.string(assignment.purpose)),
    #("brief", wire.string(assignment.brief)),
    #("model", optional_string(assignment.model)),
    #("within_ms", optional_int(assignment.within_ms)),
    #("detach", wire.bool(assignment.detach)),
    #("context", wire.string(provenance_name(assignment.context))),
    #("tools", optional_strings(assignment.tools)),
    #("result_schema", encode_schema(assignment.result_schema)),
  ])
}

/// Decodes a handle returned by the harness's child admission paths.
///
/// ## Examples
///
/// ```gleam
/// // strand.read_handle(value)
/// ```
@internal
pub fn read_handle(value: Value) -> Result(Handle, String) {
  decode_handle(value)
}

/// One assignment's result from a bounded map, in input order.
pub type Mapped {
  /// Admission failed. The helper stops admitting further assignments.
  SpawnFailed(error: StrandError)

  /// A child was admitted and its join answered, possibly still Pending.
  Joined(waited: Waited)

  /// A child was admitted but the join failed. Keep its handle for a later wait.
  JoinFailed(handle: Handle, error: StrandError)

  /// The helper stopped before admitting this assignment. It can be retried.
  NotStarted(assignment: Assignment)
}

/// Runs assignments in batches of at most `max_concurrency` children.
/// Returns one entry per assignment in input order, retaining every known handle.
/// The concurrency bound covers children started by this call, not other work
/// already running on the parent. Each batch shares one `within_ms` join window;
/// the host's execution deadline remains the outer bound for the entire call.
///
/// A pending child, failed admission, or failed join stops further admissions.
/// Remaining assignments are NotStarted; admitted children are not cancelled.
/// Ready children with Failed/Aborted outcomes or unusable results remain explicit
/// Joined entries and do not prevent the next batch from starting.
///
/// ## Examples
///
/// ```gleam
/// // strand.map(assignments, max_concurrency: 3, within_ms: 30_000)
/// // Match every Joined, SpawnFailed, JoinFailed, and NotStarted result.
/// ```
pub fn map(
  assignments: List(Assignment),
  max_concurrency max_concurrency: Int,
  within_ms within_ms: Int,
) -> Result(List(Mapped), StrandError) {
  case max_concurrency >= 1 && max_concurrency <= 32 && within_ms >= 0 {
    False ->
      Error(InvalidArgument(
        "map requires concurrency 1..32 and a nonnegative join window",
      ))
    True -> Ok(map_batches(assignments, max_concurrency, within_ms, []))
  }
}

// A completed batch releases all its child slots. Any unresolved child stops
// admission, so a timeout can never silently turn the bound into extra fan-out.
fn map_batches(
  assignments: List(Assignment),
  width: Int,
  within_ms: Int,
  reversed: List(Mapped),
) -> List(Mapped) {
  case assignments {
    [] -> list.reverse(reversed)
    [_, ..] -> {
      let #(admitted, remaining) = admit_batch(assignments, width, [])
      let joined = join_batch(admitted, within_ms)
      let reversed =
        list.fold(joined, reversed, fn(acc, item) { [item, ..acc] })
      case list.all(joined, batch_settled) {
        True -> map_batches(remaining, width, within_ms, reversed)
        False ->
          list.append(list.reverse(reversed), list.map(remaining, NotStarted))
      }
    }
  }
}

// Stop on the first refused or uncertain admission. Keeping earlier handles is
// essential: an error in a later spawn does not roll back children already born.
fn admit_batch(
  assignments: List(Assignment),
  slots: Int,
  reversed: List(Result(Handle, StrandError)),
) -> #(List(Result(Handle, StrandError)), List(Assignment)) {
  case slots, assignments {
    0, _ | _, [] -> #(list.reverse(reversed), assignments)
    _, [assignment, ..remaining] -> {
      let admitted = spawn(assignment)
      case admitted {
        Ok(_) -> admit_batch(remaining, slots - 1, [admitted, ..reversed])
        Error(_) -> #(list.reverse([admitted, ..reversed]), remaining)
      }
    }
  }
}

fn join_batch(
  admitted: List(Result(Handle, StrandError)),
  within_ms: Int,
) -> List(Mapped) {
  let handles = list.filter_map(admitted, fn(item) { item })
  let joined = case handles {
    [] -> Ok([])
    [_, ..] -> wait(handles, within_ms:)
  }

  // A mismatched answer surfaces as `wait`'s own `StrandResultMalformed`
  // error — `step_wait` checks it before any list reaches this arm — so
  // there is no second mismatch check to repeat here; `joined` carries
  // either a settled-or-pending list or that error.
  case joined {
    Error(error) ->
      list.map(admitted, fn(item) {
        case item {
          Ok(handle) -> JoinFailed(handle, error)
          Error(error) -> SpawnFailed(error)
        }
      })
    Ok(waited) ->
      list.append(
        list.map(waited, Joined),
        list.filter_map(admitted, fn(item) {
          case item {
            Ok(_) -> Error(Nil)
            Error(error) -> Ok(SpawnFailed(error))
          }
        }),
      )
  }
}

fn batch_settled(item: Mapped) -> Bool {
  case item {
    Joined(Ready(..)) -> True
    Joined(Pending(..)) | SpawnFailed(..) | JoinFailed(..) | NotStarted(..) ->
      False
  }
}
