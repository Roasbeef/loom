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
//// # Onto itself, or onto something it spawned
////
//// A schedule has an owner and a target, and this door lets a caller
//// name the second. `target` defaults to the calling strand — the
//// ordinary heartbeat, and every schedule this door could create before
//// — and may otherwise name a strand the caller *spawned*. The host
//// decides that from the durable lineage ledger, which is the only
//// place the answer exists; a target that is neither the caller nor a
//// descendant of it is refused as `Invalid`, and no strand can put text
//// into an unrelated strand's context.
////
//// The point of the argument is the case the design ruling named as the
//// motivating one for `wake` and could not reach: a parent watching a
//// subagent it started, with nobody present. What it costs is one more
//// thing to say plainly to the model — `list` and `cancel` are keyed on
//// the **owner**, so a caller sees and retires the schedules it made
//// wherever they fire, and never another strand's.
////
//// Waking is the one thing a target changes. A schedule onto a subagent
//// never wakes it, whatever the operator's policy says and whatever the
//// call asked for: a subagent has exactly one run, and starting a fresh
//// one after its task has ended would extend a child's life outside the
//// spawn budget its parent was held to. Such a schedule steers the
//// child's open run and holds when there is none, and the result says
//// so, exactly as it already does under a `steer` policy.
////
//// # Four timings, and why two of them are not conveniences
////
//// A schedule fires on a fixed interval, on a five-field cron
//// expression, at a UTC instant, or a fixed while from now. The first
//// and third are what this door shipped with; the other two are here
//// because each of the originals leaves something a model cannot say.
////
//// `in_seconds` exists because **the model has no clock**. Loom's system
//// prompt carries neither the date nor the time, deliberately, so a
//// model asked to check back in three quarters of an hour cannot compute
//// the RFC3339 instant `at` wants — it can only guess, and a guess is
//// either refused as unparseable or accepted and fired at the wrong
//// time. That made the model-facing one-shot unusable in practice for
//// the case it is most wanted in. The seam resolves `in_seconds` against
//// the session's own injected clock, which is the side of the seam that
//// has one.
////
//// `cron` exists because an interval cannot express a *phase*. The
//// interval grid is aligned to the epoch, so `every_seconds: 86400` is
//// always 00:00 UTC and there is no argument that moves it; "09:00 on
//// weekdays" and "the first of the month" are not multiples of anything.
//// Everything about the expression is UTC and the grammar is the
//// standard five fields and nothing more — the description says so, at
//// length, because a model that assumes local time or reaches for `L`
//// gets a refusal it cannot debug from the outside.
////
//// `max_fires` and `expires_after_s` are the third addition and the
//// smallest: a model could not previously ask for a *shorter* bound than
//// the defaults. They narrow and never widen — the host holds them to
//// the same ceilings a `[[schedule]]` table is held to — and they are
//// refused beside a one-shot, which fires once by construction.
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
//// write durable state, and a replayed call would act on it twice. The
//// host claims a config cell on its absence, so a replayed `create` whose
//// first attempt landed is refused as `NameTaken` rather than replacing
//// anything; what replay still cannot make honest is a `create` whose
//// name was cancelled between the two attempts, which would be admitted
//// as a fresh schedule the model believes it already has. `cancel`
//// deletes the cell *and* the schedule's record of what it has fired, so
//// a name is genuinely free afterwards; a second deletion is a no-op in
//// effect but a `NotFound` in answer. Neither is a quiet difference a
//// crash should produce, so neither replays. `schedule_list` reads
//// nothing durable and is `Safe`.
////
//// `execution_mode: Exclusive` for the two writers, because two of them
//// in one batch race for the same ceiling count and one would be refused
//// in band for no reason a model could act on.
////
//// One consequence of `in_seconds` worth stating beside replay: it is
//// resolved to an absolute instant *when the call runs*, so a replayed
//// `create` would resolve it again, later, and mean a different time.
//// `replay: Never` already covers that, and the name claim already
//// refuses the second attempt, but the shape is worth naming — a
//// relative timing is the one argument whose meaning depends on when it
//// was read.

import broker/policy.{type SandboxPolicy}
import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
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
    /// The furthest ahead a relative one-shot (`in_seconds`) may be
    /// asked for, in seconds.
    max_in_seconds: Int,
    /// The largest `max_fires` a request may narrow itself to. It is
    /// also the default, so this number is a ceiling a caller can only
    /// come in under.
    max_max_fires: Int,
    /// The largest `expires_after_s` a request may narrow itself to,
    /// which is likewise the default and therefore a ceiling.
    max_expires_after_s: Int,
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
    /// The strand it fires onto: the caller's own, or one the caller
    /// spawned. Two schedules the same caller owns may share a name
    /// across different targets, so a row without this is ambiguous and
    /// a cancellation built from it would be a guess.
    target: String,
    /// A rendered description of when it fires — `"every 300s, at most
    /// 1000 times"`, a cron expression, or a UTC instant — built by the
    /// seam, which owns the timing vocabulary.
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

  /// A schedule of this name already fires onto the target. Creation
  /// never silently replaces: the model cancels and creates again, so
  /// that replacing one is a thing it decided rather than a thing it did
  /// by reusing a name.
  NameTaken(name: String)

  /// The caller owns no schedule of this name on that target. A name
  /// another strand owns answers the same way: a caller learns what is
  /// its own to cancel and nothing about anyone else's.
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
    cancel: fn(Ctx, String, Option(String)) -> Result(Nil, Refusal),
  )
}

/// One creation request, already split into the two shapes a schedule can
/// take but not yet validated — the seam holds it to the bounds.
pub type Request {
  Request(
    name: String,
    /// The strand this schedule should fire onto, or `None` for the
    /// caller's own. The seam admits only the caller itself or a strand
    /// the caller spawned; nothing on this side of it can tell those
    /// apart, which is why the argument travels as the model wrote it.
    target: Option(String),
    /// Which of the four shapes a schedule may take this request asked
    /// for. The tool refuses to build a `Request` naming none or more
    /// than one, so the seam never sees that case.
    timing: RequestedTiming,
    /// How many fires this schedule should be held to, or `None` for the
    /// default. Only meaningful beside a recurring timing; the tool
    /// refuses it beside a one-shot, and the seam holds it to the same
    /// ceiling a `[[schedule]]` table is held to.
    max_fires: Option(Int),
    /// How long this schedule should live, in seconds, or `None` for the
    /// default. Bounded exactly as `max_fires` is, and refused beside a
    /// one-shot for the same reason.
    expires_after_s: Option(Int),
    wake: Wake,
    body: String,
  )
}

/// The timing half of a creation request: two recurring shapes and two
/// one-shots.
///
/// Two of each rather than one, and the pairs exist for opposite
/// reasons. `Cron` says something `Every` cannot say at all — a phase or
/// a calendar shape, "09:00 on weekdays" rather than "every 86400
/// seconds", which on an epoch-aligned grid is always midnight UTC.
/// `In` says exactly what `At` says and says it in the vocabulary a
/// model actually has: Loom's system prompt carries no clock and no
/// date, so a model asked to check back in three quarters of an hour
/// cannot compute the instant `At` wants.
pub type RequestedTiming {
  /// Fire every `seconds`, until the expiry bounds end it.
  Every(seconds: Int)

  /// Fire once, at this RFC3339 UTC instant, as the model wrote it. The
  /// seam parses it, because the seam owns the one RFC3339 parser.
  At(instant: String)

  /// Fire on this five-field cron expression as the model wrote it,
  /// read against a clock `utc_offset` hours and minutes from UTC.
  ///
  /// The seam parses both, for the reason it parses `At`: one grammar,
  /// one parser, one set of refusals. `utc_offset` is `None` for plain
  /// UTC, which is what a request that names no offset means and what
  /// every request meant before the argument existed.
  Cron(expression: String, utc_offset: Option(String))

  /// Fire once, `seconds` from now. The seam resolves it against the
  /// session's own clock, which is the whole point — see the type doc.
  In(seconds: Int)
}

/// What a creation actually produced, which may differ from what was
/// asked for in exactly one way.
pub type Created {
  Created(
    name: String,
    /// The strand it will fire onto, resolved: the caller's own when the
    /// request named none. Echoed because a confirmation that does not
    /// say where a heartbeat lands is one a caller cannot check.
    target: String,
    when: String,
    /// What `wake` ended up being. Under a `steer` policy this is
    /// `SteersOnly` however the model asked, and so is every schedule
    /// onto a subagent whatever the policy — the tool says which in the
    /// result rather than refusing the call.
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
    description: "Schedule a heartbeat: text that will be injected into a "
      <> "strand's context later — your own, by default — on a timer, "
      <> "whether or not anyone is watching. Use it to check back on long-running work, to poll "
      <> "something that changes on its own, or to leave yourself a "
      <> "reminder at a fixed time. Give exactly one of four timings, "
      <> "never two: `in_seconds` for a one-shot a fixed while from now, "
      <> "`every_seconds` for a recurring heartbeat (at least "
      <> int.to_string(limits.min_interval_seconds)
      <> "s apart), `cron` for a recurring heartbeat on a calendar, or "
      <> "`at` for a one-shot at a UTC instant. **Prefer `in_seconds` "
      <> "for anything relative**: you are not told the current date or "
      <> "time, so you cannot work out the instant `at` wants, and "
      <> "`in_seconds` is how you say \"in 45 minutes\" (2700) without "
      <> "one. Use `cron` when the time of day matters — `every_seconds` "
      <> "is a grid aligned to the epoch, so a daily interval always "
      <> "lands at 00:00 UTC and only `cron` can ask for 09:00 on "
      <> "weekdays. `cron` is read in UTC unless `utc_offset` gives it a "
      <> "fixed offset — that is an offset and not a timezone, so it does "
      <> "not follow daylight saving. A recurring schedule always expires on its own — "
      <> "after "
      <> int.to_string(limits.default_max_fires)
      <> " fires or a week, whichever comes first — so it cannot run "
      <> "forever; `max_fires` and `expires_after_s` narrow that, and "
      <> "cannot widen it. This session holds at most "
      <> int.to_string(limits.max_schedules)
      <> " of them at a time; cancel one you no longer need with "
      <> cancel_tool_name
      <> ". Write the body as an instruction to your future self, which "
      <> "will read it with none of this moment's context. It fires onto "
      <> "this strand unless you name a `target`, which may only be a "
      <> "strand you spawned — a heartbeat onto one of those steers its "
      <> "open run and never starts a new one.",
    prompt_snippet: Some(
      "`schedule_create` has text injected back into your own context "
      <> "later, on a timer.",
    ),
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
          "in_seconds",
          tool.integer_property(
            "for a one-shot a fixed while from now: how many seconds to "
            <> "wait, 1 to "
            <> int.to_string(limits.max_in_seconds)
            <> " (seven days). This exists because you have no clock — "
            <> "nothing tells you the current date or time, so this is the "
            <> "only way you can ask for \"in half an hour\" (1800). Give "
            <> "exactly one timing",
          ),
        ),
        #(
          "every_seconds",
          tool.integer_property(
            "for a recurring heartbeat: how many seconds between fires, at "
            <> "least "
            <> int.to_string(limits.min_interval_seconds)
            <> ". The grid is aligned to the epoch, so a daily interval "
            <> "fires at 00:00 UTC — use `cron` if the time of day "
            <> "matters. Give exactly one timing",
          ),
        ),
        #(
          "cron",
          tool.string_property(
            "for a recurring heartbeat on a calendar: a standard "
            <> "five-field cron expression, `minute hour day-of-month "
            <> "month day-of-week`, for example \"0 9 * * 1-5\" for 09:00 "
            <> "on weekdays. Every field takes `*`, a number, a range "
            <> "`a-b`, a step `*/n` or `a-b/n`, or a comma-separated list "
            <> "of those; day-of-week is 0-7 with 0 and 7 both Sunday. "
            <> "The fields are read in **UTC** unless `utc_offset` says "
            <> "otherwise, and that offset is a fixed number of hours and "
            <> "minutes rather than a zone: nothing here follows "
            <> "daylight-saving changes. There is no seconds field, month and "
            <> "day names such as JAN or MON are not understood, and "
            <> "neither are the extensions L, W, ? and #. When both day "
            <> "fields are restricted they are ORed, not ANDed, which is "
            <> "standard cron and surprising: \"0 9 1 * 1\" fires on the "
            <> "first of the month AND on every Monday. Give exactly one "
            <> "timing",
          ),
        ),
        #(
          "utc_offset",
          tool.string_property(
            "beside `cron` only: read the expression's fields against a "
            <> "clock this far from UTC, written `[+-]HH:MM` — "
            <> "\"+02:00\", \"-05:30\". Use it when somebody asked for a "
            <> "time in their own clock: `cron` \"0 9 * * 1-5\" with "
            <> "`utc_offset` \"+02:00\" is 09:00 in a UTC+02:00 country, "
            <> "which is 07:00 UTC. Omit it and the expression is plain "
            <> "UTC. It is a **fixed offset and not a timezone**: Loom "
            <> "carries no timezone database, nothing here follows "
            <> "daylight-saving changes, and a schedule written with the "
            <> "summer offset will fire an hour out all winter. Write the "
            <> "offset in force now, and say in the body which clock the "
            <> "schedule was set for. Refused beside `every_seconds`, `at` "
            <> "or `in_seconds`",
          ),
        ),
        #(
          "at",
          tool.string_property(
            "for a one-shot at a known instant: the UTC instant to fire "
            <> "at, RFC3339, for example \"2026-09-01T09:00:00Z\". You are "
            <> "not told the current time, so use `in_seconds` for "
            <> "anything relative and keep this for an instant you were "
            <> "actually given. Give exactly one timing",
          ),
        ),
        #(
          "max_fires",
          tool.integer_property(
            "for a recurring heartbeat only: end it after this many "
            <> "fires, 1 to "
            <> int.to_string(limits.max_max_fires)
            <> ". Defaults to the ceiling, so this can only narrow the "
            <> "schedule, never extend it. Refused beside `at` or "
            <> "`in_seconds`, which fire once by construction",
          ),
        ),
        #(
          "expires_after_s",
          tool.integer_property(
            "for a recurring heartbeat only: end it this many seconds "
            <> "after it is created, 1 to "
            <> int.to_string(limits.max_expires_after_s)
            <> " (seven days). Defaults to the ceiling, so this can only "
            <> "narrow the schedule. Whichever of this and `max_fires` is "
            <> "reached first ends it. Refused beside `at` or `in_seconds`",
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
        #(
          "target",
          tool.string_property(
            "which strand the heartbeat fires onto. Defaults to this one. "
            <> "The only other strand you may name is one you spawned; a "
            <> "schedule onto it steers its open run, never wakes it, and "
            <> "ends when its work does. You still own it: it is yours to "
            <> "list and cancel",
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
  use wanted <- tool.with_arg(requested_wake(args))
  use target <- tool.with_arg(tool.optional_string(args, "target"))
  use timing <- tool.with_arg(requested_timing(args))
  use max_fires <- tool.with_arg(tool.optional_int(args, "max_fires"))
  use expires_after_s <- tool.with_arg(tool.optional_int(
    args,
    "expires_after_s",
  ))
  use Nil <- tool.with_arg(licensed_bounds(timing, max_fires, expires_after_s))

  let request =
    Request(
      name:,
      target:,
      timing:,
      max_fires:,
      expires_after_s:,
      wake: wanted,
      body:,
    )
  use created <- tool.or_outcome(
    schedules.create(ctx, request),
    refusal_outcome,
  )
  created_outcome(created, ctx, asked_for_wake: wanted)
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

// Exactly one of the four timing arguments, decided here rather than at
// the seam so the refusal names the argument spellings the model actually
// wrote rather than the internal vocabulary they map onto.
//
// The arguments are read into one list of what was present, so "exactly
// one" is a question about that list's length. With four spellings a
// case over the cross product would be sixteen arms saying three things,
// and a fifth timing would make it thirty-two.
fn requested_timing(args: JsonValue) -> Result(RequestedTiming, String) {
  use every <- result.try(tool.optional_int(args, "every_seconds"))
  use at <- result.try(tool.optional_string(args, "at"))
  use expression <- result.try(tool.optional_string(args, "cron"))
  use in_seconds <- result.try(tool.optional_int(args, "in_seconds"))
  use utc_offset <- result.try(tool.optional_string(args, "utc_offset"))

  let named =
    [
      option.map(in_seconds, In),
      option.map(every, Every),
      option.map(expression, fn(text) { Cron(expression: text, utc_offset:) }),
      option.map(at, At),
    ]
    |> option.values

  case named {
    [only] -> licensed_offset(only, utc_offset)

    [] ->
      Error(
        "give one of in_seconds (a one-shot that many seconds from now), "
        <> "every_seconds (a recurring heartbeat), cron (a recurring "
        <> "heartbeat on a five-field UTC calendar expression) or at (a "
        <> "one-shot at an RFC3339 UTC instant)",
      )

    [_first, _second, ..] ->
      Error(
        "give exactly one of in_seconds, every_seconds, cron or at — you "
        <> "gave "
        <> string.join(list.map(named, timing_argument), " and ")
        <> ": a schedule fires on one timing, never two",
      )
  }
}

// `utc_offset` shifts the clock a calendar expression's fields are read
// against, so beside any other timing it is a mistake about what the
// argument does rather than a redundancy to drop.
//
// It is refused here rather than at the seam for the reason the timing
// count is: the seam sees a `Timing` that has already forgotten which
// spellings arrived, and a model told "utc_offset does not apply" needs
// to know that what it applied the offset to was its own `every_seconds`.
fn licensed_offset(
  timing: RequestedTiming,
  utc_offset: Option(String),
) -> Result(RequestedTiming, String) {
  case timing, utc_offset {
    Cron(..), _offset | Every(..), None | At(..), None | In(..), None ->
      Ok(timing)

    Every(..), Some(_offset) | At(..), Some(_offset) | In(..), Some(_offset) ->
      Error(
        "utc_offset is only valid beside cron: it shifts the clock a "
        <> "calendar expression's fields are read against, and "
        <> timing_argument(timing)
        <> " names no fields. An every_seconds grid is aligned to the "
        <> "epoch, and an at instant already carries its own offset.",
      )
  }
}

// Which argument one timing arrived as, for a refusal that has to name
// the spelling the model wrote rather than the variant it became.
fn timing_argument(timing: RequestedTiming) -> String {
  case timing {
    Every(..) -> "every_seconds"
    Cron(..) -> "cron"
    At(..) -> "at"
    In(..) -> "in_seconds"
  }
}

// The two expiry arguments only mean something beside a *recurring*
// timing, so a one-shot carrying one is a contradiction refused here
// rather than quietly dropped.
//
// It is refused at the tool and not at the seam for the reason the
// timing count is: the seam sees a `Timing` that has already forgotten
// which spellings arrived, and a model told "max_fires is not valid
// here" needs to know that "here" was its own `at`.
fn licensed_bounds(
  timing: RequestedTiming,
  max_fires: Option(Int),
  expires_after_s: Option(Int),
) -> Result(Nil, String) {
  case recurrence_of(timing), max_fires, expires_after_s {
    Recurring, _fires, _window -> Ok(Nil)
    OneOccurrence, None, None -> Ok(Nil)

    OneOccurrence, Some(_fires), _window | OneOccurrence, None, Some(_window) ->
      Error(
        "max_fires and expires_after_s are only valid beside every_seconds "
        <> "or cron: "
        <> timing_argument(timing)
        <> " fires exactly once by construction, so there is nothing for "
        <> "either bound to end",
      )
  }
}

// Whether a timing produces a series or a single fire, which is the one
// thing the bounds care about.
type Recurrence {
  Recurring
  OneOccurrence
}

fn recurrence_of(timing: RequestedTiming) -> Recurrence {
  case timing {
    Every(..) | Cron(..) -> Recurring
    At(..) | In(..) -> OneOccurrence
  }
}

fn created_outcome(
  created: Created,
  ctx: Ctx,
  asked_for_wake wanted: Wake,
) -> ToolOutcome {
  // The one case where what happened differs from what was asked, and
  // it has two causes the model cannot tell apart from here: an operator
  // policy that allows steering only, or a target that is a subagent and
  // therefore never woken. Saying plainly that it will steer is what
  // stops a retry expecting a different answer; which of the two reasons
  // it was is the host's business and changes nothing the model can do.
  let note = case wanted, created.wake {
    WakesIdle, SteersOnly ->
      " Waking was not granted for this schedule, so it will steer a run "
      <> "that is already open and hold when the strand is idle."

    WakesIdle, WakesIdle | SteersOnly, WakesIdle | SteersOnly, SteersOnly -> ""
  }

  // Where it fires is named only when it is somewhere other than here.
  // The common heartbeat is onto the caller's own strand, and a
  // confirmation that says so every time trains a reader to skip the
  // clause that matters on the rare call.
  let onto = case created.target == ctx.strand {
    True -> ""
    False -> " onto " <> created.target
  }
  tool.success(
    "scheduled \""
    <> created.name
    <> "\""
    <> onto
    <> ", firing "
    <> created.when
    <> "."
    <> note,
  )
  |> tool.with_details(
    json.Object([
      #("name", json.String(created.name)),
      #("target", json.String(created.target)),
      #("when", json.String(created.when)),
      #("wake", json.Bool(wake_flag(created.wake))),
    ]),
  )
}

fn list_tool(schedules: Schedules) -> Tool {
  tool.Tool(
    name: list_tool_name,
    description: "List the heartbeats you have scheduled — this strand's "
      <> "own and any you set onto a strand you spawned — with which "
      <> "strand each fires onto, how often, how many times it has fired, "
      <> "and what it injects. Schedules the operator configured are not "
      <> "listed: those are not yours to cancel.",
    prompt_snippet: Some(
      "`schedule_list` lists the heartbeats you scheduled on this strand.",
    ),
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
      tool.success("you have no schedules.")
      |> tool.with_details(json.Object([#("schedules", json.Array([]))]))
    schedules ->
      tool.success(
        schedules
        |> list.map(fn(row) { describe_listed(row, ctx) })
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

fn describe_listed(listed: Listed, ctx: Ctx) -> String {
  let waking = case listed.wake {
    WakesIdle -> ", wakes an idle strand"
    SteersOnly -> ", steers an open run only"
  }

  // Same rule as a creation's confirmation: name the target only when it
  // is not the strand doing the reading.
  let onto = case listed.target == ctx.strand {
    True -> ""
    False -> " onto " <> listed.target
  }
  "\""
  <> listed.name
  <> "\""
  <> onto
  <> " — "
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
    #("target", json.String(listed.target)),
    #("when", json.String(listed.when)),
    #("wake", json.Bool(wake_flag(listed.wake))),
    #("fired", json.Int(listed.fired)),
    #("body", json.String(listed.body)),
  ])
}

fn cancel_tool(schedules: Schedules) -> Tool {
  tool.Tool(
    name: cancel_tool_name,
    description: "Cancel one heartbeat you scheduled, by name. It will "
      <> "not fire again, and its record of past fires is cleared with it, "
      <> "so the name is free to use again. Name the `target` too if you "
      <> "set it onto a strand you spawned. Only schedules you created can "
      <> "be cancelled: not another strand's, and not the operator's.",
    prompt_snippet: Some(
      "`schedule_cancel` cancels one heartbeat you scheduled, by name.",
    ),
    schema: tool.object_schema(
      [
        #(
          "name",
          tool.string_property(
            "the name you gave the schedule when you " <> "created it",
          ),
        ),
        #(
          "target",
          tool.string_property(
            "the strand it fires onto, if that is not this one — "
            <> list_tool_name
            <> " shows it. Defaults to this strand",
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
  use target <- tool.with_arg(tool.optional_string(args, "target"))
  use Nil <- tool.or_outcome(
    schedules.cancel(ctx, name, target),
    refusal_outcome,
  )
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
      <> "\" already fires onto that strand. Cancel it first, or choose "
      <> "another name — creating never silently replaces one."
    NotFound(name:) ->
      "you have no schedule named \""
      <> name
      <> "\" on that strand. "
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
