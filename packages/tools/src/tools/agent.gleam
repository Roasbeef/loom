//// The `agent_*` tools: how a model starts, addresses, and joins other
//// agents.
////
//// Six tools, one family, each a thin shell over one **Agency** call.
//// The Agency is the messaging plane's single door, the way
//// `Ctx.clear_call` is the outside world's: a record of closures declared
//// here in plain data and filled in by whoever can see a live runtime
//// (`client/agency` in production, a fake in tests). `tools` depends on
//// `core` and `broker` and on neither `runtime` nor `machine`, so every
//// type crossing the seam is mirrored here rather than imported — the
//// same arrangement `effects.ToolOutcome` uses to mirror the broker's
//// `CallOutcome` without a broker dependency.
////
//// ## Why a tool and not a capability
////
//// A `cap/strand` capability would run inside the satellite, which
//// executes untrusted model-written Gleam. A tool runs in the harness:
//// trusted code, policy-checked, able to commit durably. The messaging
//// doctrine requires the commit — a payload that changes what the
//// recipient does travels through the store, never a mailbox — and it was
//// designed assuming trusted writers. Handing a jailed program a
//// messaging capability imports an untrusted writer into a plane built
//// for trusted ones. Handing the *model* a messaging tool does not,
//// because the harness still decides what the call does with the
//// arguments it was given. Every refusal below is therefore enforced by
//// the Agency, never requested in a prompt.
////
//// ## What the model is never allowed to say
////
//// Three things the model does not get to supply, each closing a class of
//// attack rather than a single bug:
////
//// - **Its own identity.** Every Agency call is judged against
////   `Ctx.strand`, which the driver set from its own durable name. A model
////   cannot claim to be another strand, so the addressing rule below is
////   enforceable at all.
//// - **A strand name.** `agent_spawn` takes a *purpose*; the Agency mints
////   `sub:{parent}/{slug}-{step}-{index}` from the purpose and the call's
////   own durable coordinates. Minting kills name-squatting, sibling
////   collisions, and shadowing an operator's convention at once — and the
////   determinism is what makes a replayed spawn reach for the same name
////   and reconcile rather than mint a second child.
//// - **A blackboard prefix.** `agent_note` writes under
////   `agent/{caller}/` and cannot escape it; `agent_notes` reads under
////   `agent/` and nothing else. The reserved corners of the fact
////   namespace — escalations, operation results, the lineage ledger, the
////   pinned system prompt — are refused by the runtime one layer further
////   down, so a forged approval record needs two independent failures.
////
//// ## The addressing rule, and why a blocking wait is safe
////
//// > A strand may wait only on a descendant, and may address only its
//// > parent or a descendant.
////
//// Spawning builds a forest — every strand has at most one parent, fixed
//// at spawn and unforgeable — so wait edges point strictly from parent to
//// child and a cycle cannot be drawn. Child-to-parent traffic exists but
//// rides `agent_send`, which never waits. `agent_wait` therefore blocks
//// the *operation's* progress and nothing else: the driver answers
//// `Continue` while a tool effect is live and goes on serving `Nudge`,
//// `Abort` and `PollTick`, the tool body runs on its own spawned process
//// rather than on the driver or the writer, and abort kills a blocked
//// waiter outright.
////
//// Two residual costs, stated rather than hidden. A human steering the
//// waiting strand is queued, not dropped — the steer commits and drains
//// at the next checkpoint, which is after the batch the strand is inside
//// — which is why the deadline is capped and why abort remains the
//// immediate exit. And a child cannot get an answer from its parent while
//// the parent is inside `agent_wait`: the ask-my-parent pattern is
//// unavailable exactly when a child wants it. That is a designed-in hole,
//// not a deadlock; see `send` for the other half of it.
////
//// ## Waiting is per call, not per child
////
//// `agent_wait` takes an **array** of handles and the Agency waits them
//// all against **one** deadline. This is load-bearing, not a convenience,
//// and it stayed load-bearing when `tool_execution: Parallel` became the
//// shipped default. The tool's `Concurrent` declaration does now bite —
//// eight one-handle waits in one batch genuinely overlap — but three
//// things the setting cannot change are why the array is still the unit:
////
//// - **The setting is not a guarantee.** `tool_execution` is a run
////   setting a host or a session may set back to `sequential` (the
////   gateway's config key), and under it eight one-handle waits are
////   eight serial deadline windows again. A fan-out story that only
////   holds on the default is one that breaks when someone turns the
////   default off.
//// - **A batch is only as parallel as its most exclusive member.** One
////   `bash`, `fs_write` or `code_mode` beside the waits fences the whole
////   batch (`runtime/strand_runtime.tool_may_start`), and the serial
////   windows come back inside a session that never changed a setting.
//// - **Overlap is not free where it does happen.** Eight waits are eight
////   effect processes, eight intent commits and eight settlements to
////   reconcile, each against a deadline of its own. One call is one
////   intent, one settlement, and one deadline for the whole set — which
////   is also the only shape in which "wait for the batch" is a single
////   durable fact.
////
//// So the mode makes the degenerate case cheaper; it does not carry the
//// fan-out story, and nothing here rests on it.

import broker/policy.{type SandboxPolicy}
import core/ids.{type EntryId, type OpId}
import core/json.{type JsonValue}
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/tool.{type Ctx, type Tool, type ToolOutcome}

/// The tool names this family registers, in registry order.
pub const tool_names = [
  "agent_note", "agent_notes", "agent_roster", "agent_send", "agent_spawn",
  "agent_wait",
]

/// The name of the tool that starts a child. Named as a constant because
/// the depth cap is enforced structurally by leaving it out of a child's
/// active set — a tool the model cannot see is one it never tries.
pub const spawn_tool_name = "agent_spawn"

/// The model-writable blackboard prefix. Every `agent_note` key is forced
/// under `agent/{caller}/` and every `agent_notes` read under `agent/`.
pub const blackboard_prefix = "agent/"

/// Longest slug minted from a `purpose`, in characters. A strand name is
/// a key in three register namespaces and half of a handle's text; a
/// model that pastes a paragraph as its purpose gets a bounded name.
pub const max_slug_length = 24

/// Most handles one `agent_wait` call may name. The wait is one loop over
/// one deadline, so this bounds the store traffic per iteration rather
/// than the wall-clock cost.
pub const max_handles = 32

// --- what crosses the seam -------------------------------------------------

/// Who is calling, in the driver's own durable coordinates.
///
/// Constructor invariants: every field comes from `Ctx`, which the driver
/// built from its own state — `strand` is the dispatching driver's name
/// and the identity every authorization decision is made against, and
/// `{operation, step_id, source_index}` are the persisted coordinates a
/// replayed call arrives under, which is what makes a minted child name
/// stable across replay.
pub type Caller {
  Caller(strand: String, operation: OpId, step_id: String, source_index: Int)
}

/// A durable reference to one child operation. It survives restart and
/// compaction because it names nothing process-local.
///
/// Constructor invariants: `strand` is the child's minted name and
/// `operation` the brief run the spawn accepted. Rendered to the model as
/// `{strand}#{operation}` and parsed back totally.
pub type Handle {
  Handle(strand: String, operation: OpId)
}

/// Where a child's context starts.
pub type Provenance {
  /// At the root of the tree: the child reads its brief and nothing else.
  Fresh
  /// At the caller's current leaf, copying the caller's entire
  /// conversation into the child's context window.
  MyConversation
}

/// One `agent_spawn` request, decoded.
///
/// Constructor invariants: `purpose` is model text the Agency slugs into
/// part of a name and never uses verbatim as a key; `tools`, when present,
/// may only *narrow* the caller's own active set; `within_ms`, when
/// present, is a relative budget the Agency converts to an absolute
/// deadline at spawn.
pub type SpawnRequest {
  SpawnRequest(
    purpose: String,
    brief: String,
    tools: Option(List(String)),
    within_ms: Option(Int),
    context: Provenance,
    detach: Bool,
  )
}

/// What a spawn produced.
pub type Spawned {
  Spawned(handle: Handle, strand: String, tools: List(String))
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

/// One handle's position when a wait returned.
pub type Waited {
  /// The operation settled; `report` is the child's final assistant text,
  /// empty when the child ended without one (a failure, an abort, or a
  /// run completed by terminated tools), and `notes` are its blackboard
  /// cells.
  Ready(
    handle: Handle,
    outcome: Outcome,
    report: String,
    notes: List(#(String, JsonValue)),
  )
  /// The deadline expired first. Not an error: call again, or do other
  /// work and come back.
  Pending(handle: Handle, waited_ms: Int)
}

/// How a `send` payload landed — mirrors `runtime/api.Delivery`, which
/// `tools` cannot import.
pub type Delivery {
  /// The target had an open run: the message is a durable steer on it.
  Steered(entry: EntryId)
  /// The target was idle: the message was accepted as a fresh run.
  Started(operation: OpId)
}

/// How a peer stands in relation to the caller.
pub type Relation {
  /// The strand that spawned the caller.
  ParentOf
  /// A strand the caller spawned.
  ChildOf
}

/// One entry in the caller's roster: a durable read of the lineage
/// ledger, not of process state, so it is correct across restarts —
/// which is the whole point, because compaction can erase every handle
/// from a model's context and this is then the only way back.
pub type Peer {
  Peer(
    strand: String,
    relation: Relation,
    handle: Option(Handle),
    outcome: Option(Outcome),
    tools: List(String),
  )
}

/// Why an Agency call was refused. Every one settles as an ordinary
/// in-band `is_error` result: a refusal is something for the model to
/// read and act on, never a harness fault.
pub type Refusal {
  /// This host wired no messaging plane, or its holder is not up yet.
  AgencyUnavailable
  /// The handle text did not parse.
  MalformedHandle(text: String)
  /// The named strand is not the caller's parent and not a descendant of
  /// it. Also the answer for a strand with no lineage cell at all: "no
  /// lineage fact" means "not a descendant", never "unknown, allow".
  NotAddressable(strand: String)
  /// A wait named a strand that is not a descendant of the caller. Waits
  /// are strictly downward — that is what makes the wait graph acyclic.
  NotADescendant(strand: String)
  /// The caller is already at the spawning depth cap.
  DepthCapReached(depth: Int)
  /// The caller, or the session, already has as many live strands as it
  /// may have.
  FanOutCapReached(live: Int, cap: Int)
  /// The spawn asked for a tool the caller does not itself hold. A child
  /// may narrow its parent's set, never widen it.
  UnknownTool(name: String)
  /// An argument was unusable — an empty purpose, an unusable one, too
  /// many handles, a blackboard key outside the allowed shape.
  InvalidArgument(reason: String)
  /// A send upward would have *started* a run rather than steered one:
  /// the parent has finished and nobody is watching it. Reporting into a
  /// finished parent burns tokens with no human present, which is the
  /// exact property auto-enqueued results were rejected over.
  ParentRunEnded(strand: String)
  /// The durable plane refused or failed — a commit, a read, a decode.
  PlaneFailed(reason: String)
}

/// The messaging seam: everything a tool may do to another strand.
/// Production wiring fills it with closures reaching a live runtime
/// through a named process; tests fill it with a fake and the tools
/// cannot tell the difference.
///
/// Constructor invariants: every closure is total — it returns a
/// `Refusal`, it does not crash — and every one is judged against the
/// `Caller` it is handed rather than against anything in its other
/// arguments. `wait` waits *all* the handles it is given against one
/// deadline and answers one `Waited` per handle, in argument order.
/// `max_wait_ms` is the ceiling `wait` clamps its budget to, and is
/// published here so the tool's own schema can state the real number.
pub type Agency {
  Agency(
    /// Mints a child strand, seeds it, and accepts its brief.
    spawn: fn(Caller, SpawnRequest) -> Result(Spawned, Refusal),
    /// Delivers one attributed message to an addressable peer.
    send: fn(Caller, String, String) -> Result(Delivery, Refusal),
    /// Waits, up to one shared deadline, for descendants' operations.
    wait: fn(Caller, List(Handle), Int) -> Result(List(Waited), Refusal),
    /// Writes one blackboard cell under the caller's own namespace.
    note: fn(Caller, String, JsonValue) -> Result(Nil, Refusal),
    /// Reads blackboard cells under an `agent/`-relative key prefix.
    notes: fn(Caller, Option(String)) ->
      Result(List(#(String, JsonValue)), Refusal),
    /// The caller's parent and live descendants, from durable state.
    roster: fn(Caller) -> Result(List(Peer), Refusal),
    /// The ceiling a wait's budget is clamped to, in milliseconds.
    max_wait_ms: Int,
  )
}

// --- handles ---------------------------------------------------------------

/// Renders a handle as the text the model sees and hands back.
///
/// ## Examples
///
/// ```gleam
/// // agent.handle_to_string(handle) == "sub:main/reviewer-1#op_01J…"
/// ```
///
pub fn handle_to_string(handle: Handle) -> String {
  handle.strand <> "#" <> ids.op_id_to_string(handle.operation)
}

/// Parses a handle back. Total: a model will hand back something mangled
/// sooner or later, and that must be a refusal rather than a crash.
///
/// The split is on the **last** `#`, because a minted slug rejects `#`
/// but an operator-created strand name is not required to.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_) = agent.parse_handle("not a handle")
/// ```
///
pub fn parse_handle(text: String) -> Result(Handle, Refusal) {
  case list.reverse(string.split(text, "#")) {
    [operation_text, first, ..rest] ->
      handle_from_parts(text, operation_text, first, rest)
    _ -> Error(MalformedHandle(text:))
  }
}

// The strand half is everything before the last `#`, rejoined — a
// minted slug never contains one, but an operator-created strand name
// is not required to avoid it.
fn handle_from_parts(
  text: String,
  operation_text: String,
  first: String,
  rest: List(String),
) -> Result(Handle, Refusal) {
  use operation <- result.try(
    ids.parse_op_id(operation_text)
    |> result.replace_error(MalformedHandle(text:)),
  )
  case string.join(list.reverse([first, ..rest]), "#") {
    "" -> Error(MalformedHandle(text:))
    strand -> Ok(Handle(strand:, operation:))
  }
}

/// Slugs a model-supplied purpose into the name-safe fragment a minted
/// strand name embeds: lowercase, `[a-z0-9-]` only, runs of anything else
/// collapsed to one `-`, trimmed of leading and trailing `-`, and capped
/// at `max_slug_length`. `Error(Nil)` when nothing usable survives.
///
/// `/` and `#` are rejected by construction, which is what keeps a handle
/// unambiguously splittable and keeps a name from claiming a path shape
/// it did not earn.
///
/// ## Examples
///
/// ```gleam
/// assert agent.slug("Review the auth code") == Ok("review-the-auth-code")
/// ```
///
/// ```gleam
/// assert agent.slug("main/../#") == Ok("main")
/// ```
///
/// ```gleam
/// assert agent.slug("///") == Error(Nil)
/// ```
///
pub fn slug(purpose: String) -> Result(String, Nil) {
  let slugged =
    purpose
    |> string.lowercase
    |> string.to_graphemes
    |> list.map(fn(character) {
      case is_slug_character(character) {
        True -> character
        False -> "-"
      }
    })
    |> string.concat
    |> collapse_dashes
    |> string.slice(at_index: 0, length: max_slug_length)
    |> trim_dashes
  case slugged {
    "" -> Error(Nil)
    text -> Ok(text)
  }
}

fn is_slug_character(character: String) -> Bool {
  case character {
    "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "-" -> True
    _ -> False
  }
}

fn collapse_dashes(text: String) -> String {
  case string.contains(text, "--") {
    True -> collapse_dashes(string.replace(text, "--", "-"))
    False -> text
  }
}

fn trim_dashes(text: String) -> String {
  case text {
    "-" <> rest -> trim_dashes(rest)
    _ ->
      case string.ends_with(text, "-") {
        True ->
          trim_dashes(string.slice(
            text,
            at_index: 0,
            length: string.length(text) - 1,
          ))
        False -> text
      }
  }
}

/// A refusal as one line of model-facing prose.
///
/// ## Examples
///
/// ```gleam
/// assert agent.describe(agent.AgencyUnavailable)
///   == "this session has no messaging plane; agent tools are unavailable"
/// ```
///
pub fn describe(refusal: Refusal) -> String {
  case refusal {
    AgencyUnavailable ->
      "this session has no messaging plane; agent tools are unavailable"
    MalformedHandle(text:) ->
      "`" <> text <> "` is not a handle; use one agent_spawn returned"
    NotAddressable(strand:) ->
      "you may address only your parent and your own descendants; `"
      <> strand
      <> "` is neither"
    NotADescendant(strand:) ->
      "you may wait only on your own descendants; `" <> strand <> "` is not one"
    DepthCapReached(depth:) ->
      "spawning is capped at depth "
      <> int.to_string(depth)
      <> "; do this work yourself"
    FanOutCapReached(live:, cap:) ->
      "you already have "
      <> int.to_string(live)
      <> " live agents and the cap is "
      <> int.to_string(cap)
      <> "; wait for one to finish"
    UnknownTool(name:) ->
      "you cannot give a child the tool `"
      <> name
      <> "`, which you do not hold yourself"
    InvalidArgument(reason:) -> "invalid arguments: " <> reason
    ParentRunEnded(strand:) ->
      "`"
      <> strand
      <> "` has finished its run; a message now would start a new one with "
      <> "nobody watching, so it was not delivered. Put this in your own "
      <> "final answer instead"
    PlaneFailed(reason:) -> "the messaging plane failed: " <> reason
  }
}

// --- the tools -------------------------------------------------------------

/// The six agent tools over one Agency.
///
/// Registration is gated on an Agency existing at all, rather than on an
/// `Option` inside `Ctx`, and the reason is arithmetic: the wire tool
/// array is built from the *registry*, sits at the very front of the
/// provider's cached byte prefix, and is paid for on every request of
/// every strand forever. A host with no messaging plane would otherwise
/// ship six tool definitions the model can only ever be refused on.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(list.append(core_tools, agent.tools(agency)))
/// ```
///
pub fn tools(agency: Agency) -> List(Tool) {
  [
    note_tool(agency),
    notes_tool(agency),
    roster_tool(agency),
    send_tool(agency),
    spawn_tool(agency),
    wait_tool(agency),
  ]
}

/// The `agent_spawn` tool: start a child strand on a brief.
///
/// `replay: Safe` is earned, not assumed. The child's name derives from
/// `{operation, step, source index}`, all persisted in the intent, so a
/// replayed spawn reaches for the same name; `create_strand` answers
/// "exists", and the Agency reconciles onto the child that is already
/// there. Nothing runs twice — the same promise the effect sandwich makes
/// everywhere else, obtained the same way: mint the identifier before the
/// effect, not after.
pub fn spawn_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: spawn_tool_name,
    description: "Start a subagent on a task brief and get a handle back. "
      <> "The child is a strand in this session with its own context; it "
      <> "sees only the brief you write, so write a complete one. Join it "
      <> "with agent_wait.",
    schema: tool.object_schema(
      [
        #(
          "purpose",
          tool.string_property(
            "two or three words naming the job; becomes part of the child's "
            <> "name",
          ),
        ),
        #(
          "brief",
          tool.string_property(
            "the complete task. The child starts with no other context",
          ),
        ),
        #(
          "tools",
          tool.string_array_property(
            "a subset of your own tools (you cannot grant what you do not "
            <> "hold). Defaults to your set minus agent_spawn",
          ),
        ),
        #(
          "within_ms",
          tool.integer_property(
            "wall-clock budget; the child is aborted when it expires",
          ),
        ),
        #(
          "context",
          tool.enum_property(
            ["fresh", "my_conversation"],
            "fresh (default) starts the child at the root of the tree. "
              <> "my_conversation forks at your current leaf, copying your "
              <> "entire conversation into the child's context window",
          ),
        ),
        #(
          "detach",
          tool.boolean_property(
            "default false: the child is aborted when your run ends",
          ),
        ),
      ],
      ["purpose", "brief"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_spawn(agency, ctx, args) },
  )
}

fn run_spawn(agency: Agency, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use purpose <- tool.with_arg(tool.required_string(args, "purpose"))
  use brief <- tool.with_arg(tool.required_string(args, "brief"))
  use tools <- tool.with_arg(tool.optional_string_list(args, "tools"))
  use within_ms <- tool.with_arg(tool.optional_int(args, "within_ms"))
  use context <- tool.with_arg(decode_provenance(args))
  use detach <- tool.with_arg(tool.optional_bool(args, "detach"))
  let request =
    SpawnRequest(
      purpose:,
      brief:,
      tools:,
      within_ms:,
      context:,
      detach: option.unwrap(detach, False),
    )
  case agency.spawn(caller(ctx), request) {
    Error(refusal) -> refusal_outcome(refusal)
    Ok(spawned) ->
      tool.success(
        "started `"
        <> spawned.strand
        <> "` with tools ["
        <> string.join(spawned.tools, ", ")
        <> "]. Handle: "
        <> handle_to_string(spawned.handle),
      )
      |> tool.with_details(
        json.Object([
          #("handle", json.String(handle_to_string(spawned.handle))),
          #("strand", json.String(spawned.strand)),
          #("tools", json.Array(list.map(spawned.tools, json.String))),
        ]),
      )
  }
}

fn decode_provenance(args: JsonValue) -> Result(Provenance, String) {
  case tool.optional_string(args, "context") {
    Error(reason) -> Error(reason)
    Ok(None) -> Ok(Fresh)
    Ok(Some("fresh")) -> Ok(Fresh)
    Ok(Some("my_conversation")) -> Ok(MyConversation)
    Ok(Some(other)) ->
      Error("`context` must be fresh or my_conversation, not `" <> other <> "`")
  }
}

/// The `agent_wait` tool: block, bounded, for descendants' results.
///
/// One call, one deadline, however many handles — see the module doc for
/// why the array is the unit of waiting rather than the tool call.
pub fn wait_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: "agent_wait",
    description: "Wait for subagents to finish. Give it every handle you "
      <> "want to join in one call: they are waited together against one "
      <> "deadline, not one after another. A handle that has not settled "
      <> "when the deadline expires comes back pending, which is an answer, "
      <> "not a failure — call again or do other work first.",
    schema: tool.object_schema(
      [
        #(
          "handles",
          tool.string_array_property("handles returned by agent_spawn"),
        ),
        #(
          "within_ms",
          tool.integer_property(
            "how long to wait, for the whole set; clamped to "
            <> int.to_string(agency.max_wait_ms),
          ),
        ),
      ],
      ["handles"],
    ),
    replay: tool.Safe,
    // Honest: the tool only reads. Under the shipped `Parallel` default
    // this is consulted for real, so single-handle waits in one batch do
    // overlap — but the fan-out story still does not rest on it, because
    // an `Exclusive` sibling fences the batch and a session may set
    // `sequential` back. See the module doc.
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_wait(agency, ctx, args) },
  )
}

fn run_wait(agency: Agency, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use texts <- tool.with_arg(tool.optional_string_list(args, "handles"))
  use within_ms <- tool.with_arg(tool.optional_int(args, "within_ms"))
  let texts = option.unwrap(texts, [])
  use <- bool.guard(
    when: texts == [],
    return: tool.failure("invalid arguments: `handles` must not be empty"),
  )
  // `texts` is model-supplied and not otherwise bounded, so a caller
  // that lists far more than `max_handles` handles must not force a walk
  // of the whole array just to say so — `list.drop` stops at the bound.
  use <- bool.guard(
    when: list.drop(texts, max_handles) != [],
    return: tool.failure(
      "invalid arguments: at most "
      <> int.to_string(max_handles)
      <> " handles per call",
    ),
  )
  use handles <- tool.or_outcome(
    list.try_map(texts, parse_handle),
    refusal_outcome,
  )
  use waited <- tool.or_outcome(
    agency.wait(
      caller(ctx),
      handles,
      option.unwrap(within_ms, agency.max_wait_ms),
    ),
    refusal_outcome,
  )
  tool.success(string.join(list.map(waited, waited_text), "\n\n"))
  |> tool.with_details(
    json.Object([
      #("results", json.Array(list.map(waited, waited_json))),
      #("pending", json.Bool(list.any(waited, is_pending))),
    ]),
  )
}

fn is_pending(waited: Waited) -> Bool {
  case waited {
    Pending(..) -> True
    Ready(..) -> False
  }
}

fn waited_text(waited: Waited) -> String {
  case waited {
    Pending(handle:, waited_ms:) ->
      "["
      <> handle.strand
      <> " still working after "
      <> int.to_string(waited_ms)
      <> "ms]"
    Ready(handle:, outcome:, report:, notes:) ->
      "["
      <> handle.strand
      <> " "
      <> outcome_text(outcome)
      <> "]\n"
      <> report_text(report)
      <> notes_suffix(notes)
  }
}

// A `Ready` handle's report, or the explanation for having none — a
// failure, an abort, or a run terminated by its own tools all end
// without a final answer.
fn report_text(report: String) -> String {
  case report {
    "" -> "(no report: the run ended without a final answer)"
    text -> text
  }
}

// The trailing `[notes] key=value, ...` line, empty when the child
// wrote none.
fn notes_suffix(notes: List(#(String, JsonValue))) -> String {
  case notes {
    [] -> ""
    cells ->
      "\n[notes] "
      <> string.join(
        list.map(cells, fn(cell) { cell.0 <> "=" <> json.to_string(cell.1) }),
        ", ",
      )
  }
}

fn outcome_text(outcome: Outcome) -> String {
  case outcome {
    Completed -> "completed"
    Failed(reason:) -> "failed: " <> reason
    Aborted -> "aborted"
  }
}

fn waited_json(waited: Waited) -> JsonValue {
  case waited {
    Pending(handle:, waited_ms:) ->
      json.Object([
        #("handle", json.String(handle_to_string(handle))),
        #("strand", json.String(handle.strand)),
        #("state", json.String("pending")),
        #("waited_ms", json.Int(waited_ms)),
      ])
    Ready(handle:, outcome:, report:, notes:) ->
      json.Object([
        #("handle", json.String(handle_to_string(handle))),
        #("strand", json.String(handle.strand)),
        #("state", json.String("ready")),
        #("outcome", outcome_json(outcome)),
        #("report", json.String(report)),
        #("notes", json.Object(notes)),
      ])
  }
}

fn outcome_json(outcome: Outcome) -> JsonValue {
  case outcome {
    Completed -> json.String("completed")
    Failed(reason:) -> json.String("failed: " <> reason)
    Aborted -> json.String("aborted")
  }
}

/// The `agent_send` tool: deliver one message to an addressable peer.
///
/// `replay: Never` — a send mints a fresh entry id per admission, so a
/// replay would deliver the message twice. A crash mid-send yields the
/// synthetic interrupted result carrying the explicit warning that the
/// call's outcome is unknown; the model can consult `agent_roster` or
/// simply say it again.
pub fn send_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: "agent_send",
    description: "Send a message to your parent or to one of your "
      <> "subagents. It arrives as a durable message on their next "
      <> "checkpoint; this does not wait for a reply.",
    schema: tool.object_schema(
      [
        #(
          "to",
          tool.string_property(
            "the strand name of your parent or a " <> "subagent of yours",
          ),
        ),
        #("message", tool.string_property("what to tell them")),
      ],
      ["to", "message"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_send(agency, ctx, args) },
  )
}

fn run_send(agency: Agency, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use to <- tool.with_arg(tool.required_string(args, "to"))
  use message <- tool.with_arg(tool.required_string(args, "message"))
  use delivery <- tool.or_outcome(
    agency.send(caller(ctx), to, message),
    refusal_outcome,
  )
  case delivery {
    Steered(entry:) -> steered_outcome(to, entry)
    Started(operation:) -> started_outcome(to, operation)
  }
}

fn steered_outcome(to: String, entry: EntryId) -> ToolOutcome {
  tool.success("delivered to `" <> to <> "` on its open run")
  |> tool.with_details(
    json.Object([
      #("delivery", json.String("steered")),
      #("entry", json.String(ids.entry_id_to_string(entry))),
    ]),
  )
}

fn started_outcome(to: String, operation: OpId) -> ToolOutcome {
  tool.success("delivered to `" <> to <> "`, which started a run on it")
  |> tool.with_details(
    json.Object([
      #("delivery", json.String("started")),
      #("operation", json.String(ids.op_id_to_string(operation))),
    ]),
  )
}

/// The `agent_note` tool: write one blackboard cell.
pub fn note_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: "agent_note",
    description: "Write one cell to the shared blackboard, under your own "
      <> "namespace. Other agents in this session can read it with "
      <> "agent_notes; the write itself notifies nobody.",
    schema: tool.object_schema(
      [
        #(
          "key",
          tool.string_property(
            "a short key, letters, digits, `.`, " <> "`-`, `_` and `/`",
          ),
        ),
        #("value", tool.any_property("any JSON value")),
      ],
      ["key", "value"],
    ),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_note(agency, ctx, args) },
  )
}

fn run_note(agency: Agency, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use key <- tool.with_arg(tool.required_string(args, "key"))
  use value <- tool.with_arg(tool.optional_value(args, "value"))
  use value <- tool.with_arg(option.to_result(value, "`value` is required"))
  use Nil <- tool.or_outcome(
    agency.note(caller(ctx), key, value),
    refusal_outcome,
  )
  tool.success("noted " <> blackboard_prefix <> ctx.strand <> "/" <> key)
}

/// The `agent_notes` tool: read blackboard cells by prefix.
pub fn notes_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: "agent_notes",
    description: "Read the shared blackboard. Omit the prefix to read every "
      <> "agent's notes in this session; pass one to narrow (for example "
      <> "another agent's strand name).",
    schema: tool.object_schema(
      [
        #(
          "prefix",
          tool.string_property(
            "a key prefix, relative to the shared agent namespace",
          ),
        ),
      ],
      [],
    ),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_notes(agency, ctx, args) },
  )
}

fn run_notes(agency: Agency, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use prefix <- tool.with_arg(tool.optional_string(args, "prefix"))
  case agency.notes(caller(ctx), prefix) {
    Error(refusal) -> refusal_outcome(refusal)
    Ok([]) -> tool.success("no notes")
    Ok(cells) ->
      tool.success(string.join(
        list.map(cells, fn(cell) { cell.0 <> " = " <> json.to_string(cell.1) }),
        "\n",
      ))
      |> tool.with_details(json.Object([#("notes", json.Object(cells))]))
  }
}

/// The `agent_roster` tool: who the caller's parent and children are.
///
/// It exists because compaction can erase every handle from the model's
/// context, and a durable read of who is running is then the only way
/// back.
pub fn roster_tool(agency: Agency) -> Tool {
  tool.Tool(
    name: "agent_roster",
    description: "List your parent and your subagents, with their handles "
      <> "and whether they have finished. Use this when you have lost a "
      <> "handle.",
    schema: tool.object_schema([], []),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, _args) { run_roster(agency, ctx) },
  )
}

fn run_roster(agency: Agency, ctx: Ctx) -> ToolOutcome {
  case agency.roster(caller(ctx)) {
    Error(refusal) -> refusal_outcome(refusal)
    Ok([]) -> tool.success("no parent and no subagents")
    Ok(peers) ->
      tool.success(string.join(list.map(peers, peer_text), "\n"))
      |> tool.with_details(
        json.Object([#("peers", json.Array(list.map(peers, peer_json)))]),
      )
  }
}

fn peer_text(peer: Peer) -> String {
  relation_text(peer.relation)
  <> " "
  <> peer.strand
  <> case peer.handle {
    None -> ""
    Some(handle) -> " (" <> handle_to_string(handle) <> ")"
  }
  <> case peer.outcome {
    None -> " — working"
    Some(outcome) -> " — " <> outcome_text(outcome)
  }
}

fn relation_text(relation: Relation) -> String {
  case relation {
    ParentOf -> "parent"
    ChildOf -> "child"
  }
}

fn peer_json(peer: Peer) -> JsonValue {
  json.Object([
    #("strand", json.String(peer.strand)),
    #("relation", json.String(relation_text(peer.relation))),
    #("handle", case peer.handle {
      None -> json.Null
      Some(handle) -> json.String(handle_to_string(handle))
    }),
    #("outcome", case peer.outcome {
      None -> json.Null
      Some(outcome) -> outcome_json(outcome)
    }),
    #("tools", json.Array(list.map(peer.tools, json.String))),
  ])
}

// --- shared plumbing -------------------------------------------------------

/// The caller identity for a tool context — every field from the driver,
/// none from the model.
///
/// ## Examples
///
/// ```gleam
/// // agent.caller(ctx).strand == ctx.strand
/// ```
///
pub fn caller(ctx: Ctx) -> Caller {
  Caller(
    strand: ctx.strand,
    operation: ctx.op_id,
    step_id: ctx.step_id,
    source_index: ctx.source_index,
  )
}

/// A refusal rendered as the in-band error result the model reads.
///
/// ## Examples
///
/// ```gleam
/// assert agent.refusal_outcome(agent.AgencyUnavailable).is_error
/// ```
///
pub fn refusal_outcome(refusal: Refusal) -> ToolOutcome {
  tool.failure(describe(refusal))
  |> tool.with_details(
    json.Object([
      #("error", json.String("agency_refused")),
      #("reason", json.String(describe(refusal))),
    ]),
  )
}

// The agent tools touch no filesystem and spawn no process, so they ask
// the broker for nothing at all and compose with any session base.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}
