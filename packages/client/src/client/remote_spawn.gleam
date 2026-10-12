//// The vocabulary of a subagent that runs on another orchestrator
//// (protocol-change/084, slice S1).
////
//// A parent session on one orchestrator, the laptop, asks another, the box, to
//// start a child, to report on it, and to stop the children of a run that
//// ended. Those three questions are constructors of the orchestrator port's
//// `Message` (`client/remote/orchestrator_port`), and this module holds the
//// plain data they carry and the answers they get. It has no process in it and
//// does no I/O, the way `client/session_move` holds the vocabulary of a session
//// move: both orchestrators compile the same module, and a value built here
//// crosses the pinned distribution connection as an ordinary term. Nothing in a
//// value is a closure, a port or an atom built from a peer's input.
////
//// ## Who is asking
////
//// A message names the parent as `Parent`, a session and a strand on the
//// spawning orchestrator, and nothing in it names the spawning orchestrator
//// itself. The receiver takes that from the connection: the node of the process
//// that asked, which `Origin` records beside the parent. Among pinned peers a
//// claimed origin is not proven by the connection (the design note, section 5),
//// so the node is the receiver's best account of the sender and not a
//// credential, and the spawn policy that reads it bounds an honest peer.
////
//// ## Refusals
////
//// `SpawnRefusal` is a definitive answer: the receiver looked and said no, and
//// the sender reads it as an ordinary in-band refusal. Silence is the other
//// failure, which the port's asker reports as unreachable and which this module
//// has no value for, because it is the absence of an answer.
////
//// ## The spawner's terms
////
//// The receiver judges a message against the `[spawners.<name>]` table of its
//// sender (`client/spawners`). The Agency (`client/agency`) has no use for that
//// table's placements and profiles, so the figures it needs travel as `Terms`,
//// plain data. The functions below are the pure half of taking a message to the
//// Agency: `agent_request` turns a `Request` into the Agency's own
//// `SpawnRequest` under the terms, `clamp_tools` narrows the parent's tools to
//// the ceiling, and `refusal_of` turns the Agency's refusals back into this
//// module's.
////
//// ## Flow
////
//// `agent_request` → `clamp_tools` → `refusal_of`
////
//// 1. `agent_request` judges the deadline and the tools a request names against
////    the terms, and builds the Agency's request.
//// 2. `clamp_tools` leaves the parent's tools that the ceiling also holds, which
////    is the set the child's tools may narrow.
//// 3. `refusal_of` renders an Agency refusal as the refusal the sender reads.

import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import tools/agent.{
  type Handle, type Minter, type Outcome, type Refusal, type ResultSchema,
  type TerminalResult,
}

/// A session and a strand on the spawning orchestrator. The strand is the
/// parent of the children the message concerns, and the receiver renders it as
/// the reserved reference `^{strand}` in their lineage, never as a strand of its
/// own.
pub type Parent {
  Parent(
    /// The canonical identity of the parent session.
    session: String,
    /// The parent strand's name within that session.
    strand: String,
  )
}

/// Who a message is from, as the receiver can tell: the spawning
/// orchestrator's node and the parent it speaks for.
pub type Origin {
  Origin(
    /// The full node name of the process that asked, such as
    /// `laptop@100.64.0.5`.
    node: String,
    /// The parent session and strand the message names.
    parent: Parent,
  )
}

/// The parent's planned tool call that is minting a child. It is the same
/// coordinate a local spawn derives the child's name from, so a resend of the
/// same call site derives the same name and the receiver adopts the child it
/// already made instead of making a second one.
pub type CallSite {
  CallSite(
    /// The parent's operation that planned the call.
    operation: OpId,
    /// The step of that operation that holds the call.
    step_id: String,
    /// The planned call's own index within its step.
    source_index: Int,
    /// Who inside the call is minting: the call itself, or a code-mode program
    /// on its n-th spawn.
    minter: Minter,
  )
}

/// Whether a child outlives the run of the parent that spawned it.
pub type Detach {
  /// The parent's run owns the child: when the run ends, the child is stopped.
  Attached

  /// The child outlives the run, bounded only by its deadline and by the
  /// receiver's retention sweep.
  Detached
}

/// What the parent asked `agent_spawn` for, less what the receiver derives.
///
/// Constructor invariants: `result_schema` was parsed on the parent, so a
/// malformed one never travels, and `within_ms` is a duration, never an instant,
/// because the two orchestrators' clocks are unrelated.
pub type Request {
  Request(
    /// What the child is for, which the receiver slugs into the child's name.
    purpose: String,
    /// The child's brief.
    brief: String,
    /// A catalogue name on the receiver, or `None` for its profile's subagent
    /// route.
    model: Option(String),
    /// A narrowing of the tools the child holds, or `None` for no narrowing.
    tools: Option(List(String)),
    /// The deadline the parent asked for, relative to when the child starts, or
    /// `None` for the spawner's default.
    within_ms: Option(Int),
    /// The shape of result the parent demands of the child.
    result_schema: Option(ResultSchema),
    /// Whether the child outlives the parent's run.
    detach: Detach,
  )
}

/// A child that was started, or that an earlier identical spawn had already
/// started.
pub type Spawned {
  Spawned(
    /// The child's strand and the operation that runs it.
    handle: Handle,
    /// The tools the child holds after the request, the parent's own set and the
    /// spawner's ceiling have each narrowed them.
    tools: List(String),
    /// The child's catalogue name on the receiver.
    model: String,
    /// The provider model identifier behind that name.
    model_id: String,
    /// How long the child may still run, as a duration on the receiver's
    /// clock.
    remaining_ms: Int,
  )
}

/// The tokens and the dollar cost of one child's run, summed over the run and
/// priced by the receiver's gateway. The sender records it and never reprices
/// it.
pub type ChildUsage {
  ChildUsage(
    /// Uncached input tokens.
    input: Int,
    /// Generated tokens.
    output: Int,
    /// Input tokens served from the provider cache.
    cache_read: Int,
    /// Input tokens written to the provider cache.
    cache_write: Int,
    /// The cost in dollars.
    cost: Float,
  )
}

/// One handle's position when a join returned.
pub type Joined {
  /// The child's operation settled.
  Ready(
    /// The child's strand and operation.
    handle: Handle,
    /// How the operation ended.
    outcome: Outcome,
    /// The child's final assistant text, empty when it ended without one.
    report: String,
    /// The verdict on the structured result the spawn asked for.
    result: TerminalResult,
    /// The child's blackboard cells.
    notes: List(#(String, JsonValue)),
    /// What the run cost.
    usage: ChildUsage,
  )

  /// The window ended first. Not an error: the parent may ask again.
  Pending(
    /// The child's strand and operation.
    handle: Handle,
    /// How long the receiver waited.
    waited_ms: Int,
  )
}

/// The limit a `CapReached` refusal names. Each is the key of the cap, so the
/// refusal tells the model which setting stopped it.
pub type Cap {
  /// The spawner's `max_depth`.
  MaxDepth

  /// The delegate Agency's `fan_out`: live children of one parent.
  FanOut

  /// The delegate Agency's `session_strands`: live children of one delegate
  /// session.
  SessionStrands

  /// The spawner's `max_sessions`: delegate sessions it holds.
  MaxSessions
}

/// Why the receiver declined a message. Every variant is a definitive answer,
/// and none is retried against another orchestrator.
pub type SpawnRefusal {
  /// No `[spawners.<name>]` names the node the message came from. A daemon with
  /// no `[spawners]` table at all gives this to every message.
  UnknownSpawner(
    /// The node the message came from.
    node: String,
  )

  /// The parent's run had already ended, so a child would have no one to reap
  /// it.
  ParentRunEnded

  /// A cap was reached.
  CapReached(
    /// Which cap.
    cap: Cap,
    /// Its value.
    limit: Int,
  )

  /// A tool in the request is outside the spawner's ceiling.
  ToolOutsideCeiling(
    /// The tool's name.
    tool: String,
  )

  /// An argument is invalid for this spawner, such as a deadline above its
  /// `max_within_s`.
  InvalidArgument(
    /// What is wrong, in words for the parent's model.
    reason: String,
  )

  /// The derived child name is taken by a child another call site made.
  NameAlreadyMinted

  /// The receiver's store failed.
  StoreFailure(
    /// What failed.
    reason: String,
  )
}

/// The longest one join waits on the receiver, in milliseconds. A sender may ask
/// for more and is answered as if it had asked for this, which keeps one join
/// under the 30 second ceiling of `agent_wait` and the connection's reply
/// deadline.
pub const join_cap_ms = 25_000

/// What the spawner's table says that the Agency needs, as plain data. All
/// durations are milliseconds, converted from the table's seconds by the host.
pub type Terms {
  Terms(
    /// The tool ceiling: no child holds a tool outside it.
    ceiling: List(String),
    /// The deepest child allowed. A child of a parent at depth `d` is at depth
    /// `d + 1`, which may not exceed this.
    max_depth: Int,
    /// The longest deadline a spawn may ask for.
    max_within_ms: Int,
    /// The deadline a spawn gets when it asks for none. At most `max_within_ms`.
    default_within_ms: Int,
  )
}

/// A parent on another orchestrator, as the delegate session's Agency sees it:
/// who it is, how deep it stands and what it may call, under which terms. The
/// Agency has no strand of its own to read these from, since the parent is not
/// a strand of the delegate session.
pub type Delegation {
  Delegation(
    /// The parent session and strand on the spawning orchestrator.
    parent: Parent,
    /// The parent's depth there: zero for the strand a human talks to.
    depth: Int,
    /// The tools the parent holds, already clamped to the terms' ceiling.
    parent_tools: List(String),
    /// What the spawner's table allows.
    terms: Terms,
  )
}

/// Turns a request into the Agency's own, under the terms.
///
/// The deadline is always finite on the receiver's clock: absent means the
/// terms' default, and a value that is not positive or is above the cap is
/// refused and not clamped, so a sender never believes a child may run longer
/// than it can. A tool the request names outside the ceiling is
/// `ToolOutsideCeiling`; whether the parent holds it is the Agency's question.
/// The context is always fresh, since copying the parent's conversation would
/// ship a transcript to another machine.
///
/// ## Examples
///
/// ```gleam
/// // remote_spawn.agent_request(request, terms)
/// // -> Ok(SpawnRequest(within_ms: Some(1_800_000), ..)) for a request with no deadline
/// ```
pub fn agent_request(
  request: Request,
  terms: Terms,
) -> Result(agent.SpawnRequest, SpawnRefusal) {
  use within_ms <- result.try(case request.within_ms {
    None -> Ok(terms.default_within_ms)
    Some(asked) if asked <= 0 ->
      Error(InvalidArgument(reason: "within_ms must be positive"))
    Some(asked) if asked > terms.max_within_ms ->
      Error(InvalidArgument(
        reason: "within_ms is above this spawner's max_within_s",
      ))
    Some(asked) -> Ok(asked)
  })
  use Nil <- result.try(case request.tools {
    None -> Ok(Nil)
    Some(names) ->
      case list.find(names, fn(name) { !list.contains(terms.ceiling, name) }) {
        Ok(outside) -> Error(ToolOutsideCeiling(tool: outside))
        Error(Nil) -> Ok(Nil)
      }
  })
  Ok(agent.SpawnRequest(
    purpose: request.purpose,
    brief: request.brief,
    model: request.model,
    tools: request.tools,
    within_ms: Some(within_ms),
    result_schema: request.result_schema,
    context: agent.Fresh,
    detach: case request.detach {
      Attached -> False
      Detached -> True
    },
    on: None,
  ))
}

/// The parent's tools that the ceiling also holds. A child's tools are narrowed
/// from this set and so can never include a tool the ceiling excludes, whatever
/// the parent holds.
///
/// ## Examples
///
/// ```gleam
/// assert remote_spawn.clamp_tools(["bash", "peer_send"], terms) == ["bash"]
/// ```
pub fn clamp_tools(parent_tools: List(String), terms: Terms) -> List(String) {
  list.filter(parent_tools, list.contains(terms.ceiling, _))
}

/// Renders a refusal of the Agency as the refusal the sender reads.
///
/// `fan_out` and `session_strands` are the two limits behind the Agency's one
/// cap refusal, which carries only the number it hit. When the two are equal the
/// answer is `FanOut`: that check runs first, and the number is right either
/// way.
///
/// ## Examples
///
/// ```gleam
/// assert remote_spawn.refusal_of(agent.ParentRunEnded("^main"), 8, 16)
///   == remote_spawn.ParentRunEnded
/// ```
pub fn refusal_of(
  refusal: Refusal,
  fan_out fan_out: Int,
  session_strands session_strands: Int,
) -> SpawnRefusal {
  case refusal {
    agent.DepthCapReached(depth:) -> CapReached(cap: MaxDepth, limit: depth)
    agent.FanOutCapReached(cap:, ..) if cap == fan_out ->
      CapReached(cap: FanOut, limit: cap)
    agent.FanOutCapReached(cap:, ..) if cap == session_strands ->
      CapReached(cap: SessionStrands, limit: cap)
    agent.FanOutCapReached(cap:, ..) -> CapReached(cap: FanOut, limit: cap)
    agent.ParentRunEnded(..) -> ParentRunEnded
    agent.NameAlreadyMinted(..) -> NameAlreadyMinted
    agent.InvalidArgument(reason:) -> InvalidArgument(reason:)
    agent.UnknownTool(name:) ->
      InvalidArgument(reason: "the parent does not hold the tool " <> name)
    agent.NotADescendant(strand:) ->
      InvalidArgument(reason: strand <> " is not a child of this parent")
    agent.PlaneFailed(reason:) -> StoreFailure(reason:)
    agent.AgencyUnavailable ->
      StoreFailure(reason: "the delegate session's Agency is not running")
    agent.MalformedHandle(..)
    | agent.NotAddressable(..)
    | agent.ResultSchemaUnmet(..)
    | agent.ToolNotHeld(..)
    | agent.RemoteRefused(..)
    | agent.RemoteSilent(..) -> StoreFailure(reason: agent.describe(refusal))
  }
}
