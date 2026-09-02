//// The `schedule_*` tools: the model's own door onto scheduled
//// heartbeats.
////
//// # Why this door exists at all, and what it deliberately cannot do
////
//// A scheduled heartbeat fires text into a strand's context on a timer,
//// with nobody necessarily present. That made the first version of the
//// feature operator-only — `[[schedule]]` in `loom.toml`, restart to
//// change — on the argument that a model which can schedule its own
//// future wake-ups can extend its own liveness and spend unsupervised.
////
//// That argument is sound, but it is really two arguments of different
//// strength, and separating them is what makes this door possible. A
//// schedule that may *wake* an idle strand is the sharp case: it keeps a
//// session working after everyone has gone home. A schedule that may
//// only *steer a run already open* cannot do that at all — it holds when
//// the strand is idle, exactly as a triggered project rule does, so the
//// session still ends when the work in flight ends. What is left is the
//// milder concern that a model spends budget on its own reminders, which
//// the mandatory `Expiry` on every recurring schedule already bounds.
////
//// So the operator keeps the say, at one knob with three positions
//// (`client/schedule.Policy`): `off` registers none of these tools at
//// all; `steer` registers them with `wake` forced false, and **is the
//// default**; `wake` registers them with `wake` available — see that
//// type's doc for why waking is the operator's to opt into. The model
//// never sees the knob — under `steer` a request for `wake` is honoured
//// as far as the operator allowed and the result says which it got,
//// rather than refusing and inviting a retry loop against a wall that
//// will not move.
////
//// Two further things this door does not do, both deliberate. A
//// model-created schedule always targets the strand that created it:
//// there is no `target` argument, so no strand can schedule work onto
//// another strand's context. And there is no way to create one on behalf
//// of a subagent — the case the design note names as the motivating one
//// for `wake` — because that needs a lineage check this package cannot
//// perform and an ownership argument nobody has written down yet.
////
//// # A seam of closures, like `remember`
////
//// `tools` depends on `core` and `broker` and nothing else, which is
//// what keeps a tool definition a value rather than a subsystem. So the
//// durable side is a closure the host fills in
//// (`client/scheduleseam.seam`): the host owns the runtime, the reserved
//// `schedule/config/…` namespace these cells live in, the policy, and
//// the ceiling. This module owns the model-facing surface: the argument
//// schema, the wording, and the shape of a refusal.
////
//// Every bound is therefore enforced on the far side of the seam and
//// merely *stated* here, in the descriptions, from constants the host
//// imports. That is the same arrangement `remember` uses, for the same
//// reason: a check on this side would be a second definition of a limit,
//// and a second definition drifts.
////
//// # Replay and batching
////
//// `replay: Never` for `schedule_create` and `schedule_cancel` — both
//// write a durable cell, and a replayed call would write it twice. The
//// second write is idempotent in effect for `cancel` and would silently
//// replace a schedule for `create`, which is exactly the kind of quiet
//// difference a crash should not produce. `schedule_list` reads nothing
//// durable and is `Safe`.
////
//// `execution_mode: Exclusive` for the two writers, because two of them
//// in one batch race for the same ceiling count and one would be refused
//// in band for no reason a model could act on.

import broker/policy.{type SandboxPolicy}
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import tools/tool.{type Ctx, type Tool, type ToolOutcome}

/// The bounds this door states to the model, supplied by the host.
///
/// The numbers themselves live in `client/schedule`, because that module
/// is where they are *enforced* — on the far side of the seam, along with
/// every other bound. Passing them in rather than restating them here is
/// what keeps the description a model reads and the limit a call meets
/// from being two facts that can disagree. `remember` reaches the same
/// end by the opposite route (it defines its caps and the host imports
/// them); either works, and the direction is decided by which side owns
/// the check.
pub type Limits {
  Limits(
    /// The tightest recurring interval, in seconds.
    min_interval_seconds: Int,
    /// How many times a recurring schedule fires before expiring on its
    /// own, absent anything tighter.
    default_max_fires: Int,
    /// How many model-created schedules one session holds at once.
    max_schedules: Int,
  )
}

/// The creation tool's name.
pub const create_tool_name = "schedule_create"

/// The listing tool's name.
pub const list_tool_name = "schedule_list"

/// The cancellation tool's name.
pub const cancel_tool_name = "schedule_cancel"

/// What a schedule is allowed to do to a strand that is idle when it
/// fires.
///
/// `tools` depends on `core` and `broker` and nothing else, so this is
/// the door's own name for the distinction rather than a shared one.
/// `client/schedule` holds the same two states on the durable side and
/// `client/scheduleseam` translates between them, exactly as it already
/// does for `Refusal`. The model still writes `wake: true` and still
/// reads a JSON boolean back; the type is what the Gleam on this side of
/// that wire works in.
pub type Wake {
  /// The schedule may start a fresh run when the strand is idle.
  WakesIdle

  /// The schedule steers a run that is already open and holds when the
  /// strand is idle. This is what an operator's `steer` policy caps
  /// every request to, however the model asked.
  SteersOnly
}

/// One schedule as the model sees it: enough to decide whether to cancel
/// it, and nothing about the durable machinery underneath.
pub type Listed {
  Listed(
    /// The name the model gave it, which is also how it cancels it.
    name: String,
    /// A rendered description of when it fires — `"every 300s"` or a UTC
    /// instant — built by the seam, which owns the timing vocabulary.
    when: String,
    /// Whether this schedule may start a fresh run on an idle strand.
    wake: Wake,
    /// How many times it has fired so far.
    fired: Int,
    /// The text it injects.
    body: String,
  )
}

/// Why a schedule could not be created or cancelled.
pub type Refusal {
  /// The arguments describe no schedule this build would accept. Carries
  /// the seam's own worded reason, which names the bound that was missed.
  Invalid(reason: String)

  /// This session already holds `limit` model-created schedules.
  CeilingReached(limit: Int)

  /// A schedule of this name already exists on this strand. Creation
  /// never silently replaces: the model cancels and creates again, so
  /// that replacing one is a thing it decided rather than a thing it did
  /// by reusing a name.
  NameTaken(name: String)

  /// No schedule of this name exists on this strand to cancel.
  NotFound(name: String)

  /// The durable store could not be read or written.
  Unavailable(reason: String)
}

/// The scheduling seam: everything these tools may ask of the session.
///
/// Constructor invariants: every function is total — it returns a
/// `Refusal`, it does not crash — and the seam owns every bound the
/// module doc names, including the policy's say over `wake` and the
/// ceiling on how many schedules one session holds. `create` is given
/// the model's `wake` request as asked and returns what it actually got,
/// which is what lets the tool tell the model the truth under a `steer`
/// policy without refusing the call.
pub type Schedules {
  Schedules(
    create: fn(Ctx, Request) -> Result(Created, Refusal),
    list: fn(Ctx) -> Result(List(Listed), Refusal),
    cancel: fn(Ctx, String) -> Result(Nil, Refusal),
  )
}

/// One creation request, already split into the two shapes a schedule can
/// take but not yet validated — the seam holds it to the bounds.
pub type Request {
  Request(
    name: String,
    /// A recurring interval in seconds, or a one-shot UTC instant. The
    /// tool refuses to build a `Request` that names neither or both, so
    /// the seam never sees that case.
    timing: RequestedTiming,
    wake: Wake,
    body: String,
  )
}

/// The timing half of a creation request.
pub type RequestedTiming {
  /// Fire every `seconds`, until `max_fires` or the default expiry.
  Every(seconds: Int)

  /// Fire once, at this RFC3339 UTC instant, as the model wrote it. The
  /// seam parses it, because the seam owns the one RFC3339 parser.
  At(instant: String)
}

/// What a creation actually produced, which may differ from what was
/// asked for in exactly one way.
pub type Created {
  Created(
    name: String,
    when: String,
    /// What `wake` ended up being. Under a `steer` policy this is
    /// `SteersOnly` however the model asked, and the tool says so in the
    /// result.
    wake: Wake,
  )
}

/// The three scheduling tools over one seam.
///
/// A list rather than three exported functions, so a host cannot register
/// the writer without the reader: a model that can create a schedule and
/// not list it has no way to discover what it already has.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(list.append(base, schedule.tools(seam)))
/// ```
///
pub fn tools(schedules: Schedules, limits: Limits) -> List(Tool) {
  [create_tool(schedules, limits), list_tool(schedules), cancel_tool(schedules)]
}

fn create_tool(schedules: Schedules, limits: Limits) -> Tool {
  tool.Tool(
    name: create_tool_name,
    description: "Schedule a heartbeat: text that will be injected back "
      <> "into your own context later, on a timer, whether or not anyone is "
      <> "watching. Use it to check back on long-running work, to poll "
      <> "something that changes on its own, or to leave yourself a "
      <> "reminder at a fixed time. Give either `every_seconds` for a "
      <> "recurring heartbeat (at least "
      <> int.to_string(limits.min_interval_seconds)
      <> "s apart) or `at` for a one-shot UTC instant, never both. A "
      <> "recurring schedule always expires on its own — after "
      <> int.to_string(limits.default_max_fires)
      <> " fires or a week, whichever comes first — so it cannot run "
      <> "forever. The schedule fires onto this strand only, and this "
      <> "session holds at most "
      <> int.to_string(limits.max_schedules)
      <> " of them at a time; cancel one you no longer need with "
      <> cancel_tool_name
      <> ". Write the body as an instruction to your future self, which "
      <> "will read it with none of this moment's context.",
    schema: tool.object_schema(
      [
        #(
          "name",
          tool.string_property(
            "a short handle for this schedule, unique among yours; you "
            <> "cancel it by this name later",
          ),
        ),
        #(
          "body",
          tool.string_property(
            "the instruction to inject when it fires, written so it still "
            <> "makes sense to a reader with none of this conversation's "
            <> "context",
          ),
        ),
        #(
          "every_seconds",
          tool.integer_property(
            "for a recurring heartbeat: how many seconds between fires, at "
            <> "least "
            <> int.to_string(limits.min_interval_seconds)
            <> ". Give this or `at`, not both",
          ),
        ),
        #(
          "at",
          tool.string_property(
            "for a one-shot: the UTC instant to fire at, RFC3339, for "
            <> "example \"2026-09-01T09:00:00Z\". Give this or "
            <> "`every_seconds`, not both",
          ),
        ),
        #(
          "wake",
          tool.boolean_property(
            "whether this schedule may start a fresh run when the strand is "
            <> "idle, rather than waiting for one to be open. Defaults to "
            <> "false. The operator may have disabled waking, in which case "
            <> "the schedule is still created and the result says it will "
            <> "only steer",
          ),
        ),
      ],
      ["name", "body"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_create(schedules, ctx, args) },
  )
}

fn run_create(schedules: Schedules, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use name <- tool.with_arg(tool.required_string(args, "name"))
  use body <- tool.with_arg(tool.required_string(args, "body"))
  use every <- tool.with_arg(tool.optional_int(args, "every_seconds"))
  use at <- tool.with_arg(tool.optional_string(args, "at"))
  use wanted <- tool.with_arg(requested_wake(args))
  use timing <- tool.with_arg(requested_timing(every, at))
  use created <- tool.or_outcome(
    schedules.create(ctx, Request(name:, timing:, wake: wanted, body:)),
    refusal_outcome,
  )
  created_outcome(created, asked_for_wake: wanted)
}

// The model writes an ordinary JSON boolean and may leave the argument
// out entirely. Absent reads as the milder of the two states, so a model
// that never considered waking never gets it — the same default the
// description states and the operator's TOML uses. The argument is read
// here rather than converted from an already-decoded `Option`, so the
// JSON spelling and the state it names stay in one place.
fn requested_wake(args: JsonValue) -> Result(Wake, String) {
  case tool.optional_bool(args, "wake") {
    Error(reason) -> Error(reason)
    Ok(Some(True)) -> Ok(WakesIdle)
    Ok(Some(False)) | Ok(None) -> Ok(SteersOnly)
  }
}

// Exactly one of the two timing arguments, decided here rather than at
// the seam so the refusal names the two argument spellings the model
// actually wrote rather than the internal vocabulary they map onto.
fn requested_timing(
  every: Option(Int),
  at: Option(String),
) -> Result(RequestedTiming, String) {
  case every, at {
    Some(_seconds), Some(_instant) ->
      Error(
        "give either every_seconds or at, not both: a schedule is either a "
        <> "recurring heartbeat or a one-shot",
      )
    None, None ->
      Error(
        "give one of every_seconds (a recurring heartbeat) or at (a "
        <> "one-shot UTC instant)",
      )
    Some(seconds), None -> Ok(Every(seconds:))
    None, Some(instant) -> Ok(At(instant:))
  }
}

fn created_outcome(
  created: Created,
  asked_for_wake wanted: Wake,
) -> ToolOutcome {
  // The one case where what happened differs from what was asked: the
  // operator's policy allows steering only. Saying so plainly, once, is
  // what stops a model retrying the same call expecting a different
  // answer.
  let note = case wanted, created.wake {
    WakesIdle, SteersOnly ->
      " This session's operator has not enabled waking, so it will steer a "
      <> "run that is already open and hold when the strand is idle."

    WakesIdle, WakesIdle | SteersOnly, WakesIdle | SteersOnly, SteersOnly -> ""
  }
  tool.success(
    "scheduled \""
    <> created.name
    <> "\", firing "
    <> created.when
    <> "."
    <> note,
  )
  |> tool.with_details(
    json.Object([
      #("name", json.String(created.name)),
      #("when", json.String(created.when)),
      #("wake", json.Bool(wake_flag(created.wake))),
    ]),
  )
}

fn list_tool(schedules: Schedules) -> Tool {
  tool.Tool(
    name: list_tool_name,
    description: "List the heartbeats you have scheduled on this strand, "
      <> "with how often each fires, how many times it has fired, and what "
      <> "it injects. Schedules the operator configured are not listed: "
      <> "those are not yours to cancel.",
    schema: tool.object_schema([], []),
    replay: tool.Safe,
    execution_mode: tool.Concurrent,
    requirements: empty_requirements,
    run: fn(ctx, _args) { run_list(schedules, ctx) },
  )
}

fn run_list(schedules: Schedules, ctx: Ctx) -> ToolOutcome {
  use listed <- tool.or_outcome(schedules.list(ctx), refusal_outcome)
  case listed {
    [] ->
      tool.success("no schedules on this strand.")
      |> tool.with_details(json.Object([#("schedules", json.Array([]))]))
    schedules ->
      tool.success(
        schedules
        |> list.map(describe_listed)
        |> string.join("\n"),
      )
      |> tool.with_details(
        json.Object([
          #("schedules", json.Array(list.map(schedules, listed_json))),
        ]),
      )
  }
}

// The result JSON keeps `wake` a boolean on both tools, because that is
// the shape the model has already been shown and the shape a code-mode
// program's `cap/schedule` decoder already reads. The type stops here.
fn wake_flag(wake: Wake) -> Bool {
  case wake {
    WakesIdle -> True
    SteersOnly -> False
  }
}

fn describe_listed(listed: Listed) -> String {
  let waking = case listed.wake {
    WakesIdle -> ", wakes an idle strand"
    SteersOnly -> ", steers an open run only"
  }
  "\""
  <> listed.name
  <> "\" — "
  <> listed.when
  <> waking
  <> ", fired "
  <> int.to_string(listed.fired)
  <> " time(s): "
  <> listed.body
}

fn listed_json(listed: Listed) -> JsonValue {
  json.Object([
    #("name", json.String(listed.name)),
    #("when", json.String(listed.when)),
    #("wake", json.Bool(wake_flag(listed.wake))),
    #("fired", json.Int(listed.fired)),
    #("body", json.String(listed.body)),
  ])
}

fn cancel_tool(schedules: Schedules) -> Tool {
  tool.Tool(
    name: cancel_tool_name,
    description: "Cancel one heartbeat you scheduled on this strand, by "
      <> "name. It will not fire again. Schedules the operator configured "
      <> "cannot be cancelled this way.",
    schema: tool.object_schema(
      [
        #(
          "name",
          tool.string_property(
            "the name you gave the schedule when you " <> "created it",
          ),
        ),
      ],
      ["name"],
    ),
    replay: tool.Never,
    execution_mode: tool.Exclusive,
    requirements: empty_requirements,
    run: fn(ctx, args) { run_cancel(schedules, ctx, args) },
  )
}

fn run_cancel(schedules: Schedules, ctx: Ctx, args: JsonValue) -> ToolOutcome {
  use name <- tool.with_arg(tool.required_string(args, "name"))
  use Nil <- tool.or_outcome(schedules.cancel(ctx, name), refusal_outcome)
  tool.success("cancelled \"" <> name <> "\". It will not fire again.")
  |> tool.with_details(
    json.Object([
      #("cancelled", json.Bool(True)),
      #("name", json.String(name)),
    ]),
  )
}

/// Renders a seam refusal as the in-band failure the model reads.
///
/// ## Examples
///
/// ```gleam
/// // schedule.refusal_outcome(schedule.NotFound(name: "poll")).is_error
/// ```
///
pub fn refusal_outcome(refusal: Refusal) -> ToolOutcome {
  tool.failure(describe(refusal))
  |> tool.with_details(
    json.Object([
      #("error", json.String(refusal_code(refusal))),
      #("reason", json.String(describe(refusal))),
    ]),
  )
}

fn refusal_code(refusal: Refusal) -> String {
  case refusal {
    Invalid(..) -> "invalid_schedule"
    CeilingReached(..) -> "schedule_limit_reached"
    NameTaken(..) -> "schedule_name_taken"
    NotFound(..) -> "schedule_not_found"
    Unavailable(..) -> "schedules_unavailable"
  }
}

/// The worded reason one refusal carries, for a caller rendering it
/// somewhere other than a `ToolOutcome` — `client/codemode` maps these
/// onto the code-mode capability vocabulary and needs the sentence
/// without the tool-result wrapper around it.
///
/// ## Examples
///
/// ```gleam
/// // schedule.refusal_reason(schedule.NotFound(name: "poll"))
/// ```
///
pub fn refusal_reason(refusal: Refusal) -> String {
  describe(refusal)
}

fn describe(refusal: Refusal) -> String {
  case refusal {
    Invalid(reason:) -> reason
    CeilingReached(limit:) ->
      "this session already holds its limit of "
      <> int.to_string(limit)
      <> " schedules. Cancel one you no longer need with "
      <> cancel_tool_name
      <> " before creating another."
    NameTaken(name:) ->
      "a schedule named \""
      <> name
      <> "\" already exists on this strand. Cancel it first, or choose "
      <> "another name — creating never silently replaces one."
    NotFound(name:) ->
      "no schedule named \""
      <> name
      <> "\" on this strand. "
      <> list_tool_name
      <> " shows the ones you can cancel."
    Unavailable(reason:) ->
      "the schedule store could not be reached (" <> reason <> ")."
  }
}

// The scheduling door touches no file and runs nothing jailed: it asks
// the host to write one durable cell. So it asks for nothing, exactly as
// `remember` does.
fn empty_requirements(workspace: String) -> SandboxPolicy {
  let base = tool.read_requirements(workspace)
  policy.SandboxPolicy(..base, readable_roots: [])
}
