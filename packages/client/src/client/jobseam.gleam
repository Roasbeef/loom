//// The host side of the model-facing background-jobs door: the four
//// closures `tools/job` and `cap/job` call, and every bound they state
//// but do not check.
////
//// `tools` may depend on `core` and `broker` and nothing else, so a tool
//// that needs a session cannot reach one. Both model-facing surfaces are
//// therefore values over a seam of closures, and this module fills them
//// in — the same split `client/scheduleseam` fills for `tools/schedule`,
//// and it falls in the same place: the tool owns the schema, the wording
//// and the shape of a refusal, and the host owns everything durable and
//// everything enforced.
////
//// ## What this door is the only enforcer of
////
//// Four things, and none of them can honestly live on the other side.
////
//// **The ceiling.** Four non-terminal jobs per strand is a count of live
//// records, so answering "is there room" is a durable question only the
//// actor can answer, and refusing loudly is the only way a model learns
//// it has run out of helpers rather than watching a job silently not run.
////
//// **The wall clamp.** `[jobs].max_wall` comes from `loom.toml`, which
//// `tools` cannot read. A caller that asks for longer than the ceiling is
//// given the ceiling and *told what it got* in `Started.wall_ms`, rather
//// than refused — the same shape `client/schedule.wake_under` takes, and
//// for the same reason: refusing teaches a model to retry against a wall
//// that will not move.
////
//// **Ownership.** A job belongs to the strand that started it, and every
//// operation names its caller. A job the caller's strand does not own is
//// `NotFound`, in the same words as a job that does not exist, so a
//// strand guessing at a sibling's ids learns nothing from which guesses
//// were real.
////
//// **The fact writes.** Every `job/<id>` cell in the session is written
//// by the actor behind this door and by nothing else. The tool owns
//// nothing durable.
////
//// ## Why the ids are text here and typed on the other side
////
//// A model hands back the id string it was given, and a code-mode program
//// does the same. `client/jobstate.JobId` is opaque and refuses an id
//// that would break the `job/<id>` key shape, so this door is where a
//// string becomes one — once, at the boundary, with a worded refusal for
//// anything that is not an id at all. Nothing below this line ever sees
//// an unparsed id, and nothing above it ever holds a typed one.
////
//// ## Where the model's vocabulary is
////
//// Not here. The vocabulary of this door is `client/jobs`' own — the
//// actor's state space, its refusals, its cursors — and `tools/job`
//// states the same lifecycle in the words the tool array is described
//// in. `client/jobtools` is the translation between the two, exactly as
//// `client/scheduleseam` translates `schedule.Wake` to and from
//// `tools/schedule.Wake` rather than making one package depend on the
//// other. Its two entry points are the whole of what reads this door:
//// `jobtools.seam` fills the `job_*` tools, and
//// `jobtools.capability_door` fills the code-mode router's. The door's
//// *shape* is what is frozen here: five closures, keyed on the caller's
//// strand.

import client/jobs.{type Cursors, type Listed, type Polled, type Started}
import client/jobstate.{type JobId}
import core/clock.{type Clock}
import core/ids.{type OpId}
import gleam/erlang/process
import gleam/int
import gleam/option.{type Option}
import gleam/result
import weft/poll
import weft/registry as address

/// The ceiling one `job_poll` wait is clamped to.
///
/// The same thirty seconds `client/agency.default_config` clamps an
/// `agent_wait` to, and deliberately the same number rather than one of
/// this door's own: both hold a strand's operation open while they wait,
/// so the latency budget a model's batch is held to is the same budget,
/// and two ceilings that could drift apart would make the smaller one a
/// surprise.
pub const max_wait_ms = 30_000

/// How long the caller waits on the actor for a question that is not a
/// wait: a poll with no budget, a listing, a kill, a write.
///
/// Generous against an actor whose slowest answer is one monitored ask of
/// a runner, and short against a strand's own clearance window, so a
/// wedged actor is an in-band refusal rather than a stalled turn.
pub const ask_timeout_ms = 5000

/// How long a start may spend, which is the clearance's own budget plus
/// room for the actor to answer.
///
/// A start is synchronous over the clearance — the caller hears a policy
/// refusal in the broker's own words, exactly as a foreground `bash`
/// would — and `broker.clear_call` spends its whole budget waiting out a
/// congested helper pool. So this is the one door operation whose bound
/// is the broker's rather than the actor's.
pub const start_margin_ms = 5000

/// How long a poll rests between attempts while a job is still running.
///
/// Doubling rather than fixed, for `weft/poll`'s own reason: a wait that
/// ends quickly pays the small gap, and one that runs the full thirty
/// seconds settles at the large one rather than asking a hundred times a
/// second about a build that has minutes left.
pub const first_slice_ms = 25

/// The longest gap a poll's backoff reaches.
pub const max_slice_ms = 250

/// Everything the door needs from the host.
pub type Wiring {
  Wiring(
    /// Where the jobs actor answers. An address rather than a subject,
    /// for the reason every restartable service in this package is
    /// reached by one: the seam is built before the actor starts and a
    /// captured subject would go stale the first time it restarted.
    name: address.Address(jobs.Message),
    /// The session's own time base, so a simulated session's wait is
    /// stepped by its runner rather than by the operating system.
    clock: Clock,
    /// The sleep a wait rests through, injected so a test can count
    /// slices without taking them.
    rest: fn(Int) -> Nil,
    /// How long a clearance may spend waiting out a congested pool. Read
    /// from the same place the actor's own wiring reads it, so the two
    /// bounds on one start cannot disagree.
    clearance_ms: Int,
  )
}

/// The four operations, keyed on the caller's strand.
///
/// Keyed on the strand rather than on a `tools/tool.Ctx` because two
/// doors reach this store — the `job_*` tools and the `job.*` code-mode
/// capabilities — and a code-mode call has no `Ctx` to offer, only the
/// strand its execution belongs to. That strand is the whole of the
/// authority question here: it is who may start, who owns what is
/// started, and who may poll, kill and write.
///
/// ## Examples
///
/// ```gleam
/// // jobseam.door(wiring).poll("main", "01JQ8XZ", 0, jobs.Cursors(0, 0))
/// ```
///
pub type Door {
  Door(
    /// The caller's strand, the operation the job clears under, the
    /// command, and the wall it asked for in milliseconds — `None` for
    /// the default hour. Returns once the clearance has answered, so a
    /// policy refusal reaches the caller rather than the next poll.
    start: fn(String, OpId, String, Option(Int)) ->
      Result(Started, jobs.Refusal),
    /// The caller's strand, the job's id, how long to wait for it to
    /// finish in milliseconds, and where the last poll left off in each
    /// stream. A job still running when the wait expires is a successful
    /// answer carrying its live state.
    poll: fn(String, String, Int, Cursors) -> Result(Polled, jobs.Refusal),
    /// Every job the caller's strand owns, with its state and its age.
    /// The reason there is no separate listing operation on the model's
    /// side: a poll with no id is the listing.
    list: fn(String) -> Result(List(Listed), jobs.Refusal),
    /// Climbs the cancel ladder. Needs no approval: a strand may always
    /// stop what it started.
    kill: fn(String, String) -> Result(Nil, jobs.Refusal),
    /// Writes to the job's stdin, optionally closing it. Closing is what
    /// makes a pipeline reading stdin terminate; leaving it open is the
    /// difference between watching a log and driving a REPL.
    send: fn(String, String, BitArray, jobs.StdinEnd) ->
      Result(Nil, jobs.Refusal),
  )
}

/// The jobs door over one actor address.
///
/// ## Examples
///
/// ```gleam
/// // jobseam.door(jobseam.Wiring(name:, clock:, rest: process.sleep,
/// //   clearance_ms: 30_000))
/// ```
///
pub fn door(wiring: Wiring) -> Door {
  Door(
    start: fn(strand, operation, command, wall_ms) {
      jobs.start_job(
        wiring.name,
        strand:,
        operation:,
        request: jobs.Request(command:, wall_ms:),
        waiting: wiring.clearance_ms + start_margin_ms,
      )
    },
    poll: fn(strand, id, wait_ms, cursors) {
      use id <- result.try(parse(id))
      poll_for(wiring, strand, id, wait_ms, cursors)
    },
    list: fn(strand) {
      jobs.list_jobs(wiring.name, strand:, waiting: ask_timeout_ms)
    },
    kill: fn(strand, id) {
      use id <- result.try(parse(id))
      jobs.kill_job(wiring.name, strand:, id:, waiting: ask_timeout_ms)
    },
    send: fn(strand, id, data, end) {
      use id <- result.try(parse(id))
      jobs.write_stdin(
        wiring.name,
        strand:,
        id:,
        data:,
        end:,
        waiting: ask_timeout_ms,
      )
    },
  )
}

/// The seam a session with no jobs actor hands out: every operation
/// refuses in band, naming the reason.
///
/// Exists so a host that registers the tools without standing the actor
/// up — a test, or a build where the tier failed to start — answers a
/// model rather than exiting a strand's effect process.
///
/// ## Examples
///
/// ```gleam
/// // jobseam.none().kill("main", "01JQ8XZ")
/// //   -> Error(jobs.Unavailable(..))
/// ```
///
pub fn none() -> Door {
  let absent = jobs.Unavailable(reason: "this session runs no background jobs")
  Door(
    start: fn(_strand, _operation, _command, _wall) { Error(absent) },
    poll: fn(_strand, _id, _wait, _cursors) { Error(absent) },
    list: fn(_strand) { Error(absent) },
    kill: fn(_strand, _id) { Error(absent) },
    send: fn(_strand, _id, _data, _end) { Error(absent) },
  )
}

// A wait with no budget is one question; a wait with one is a `weft/poll`
// on the session's own clock, in the *caller's* process.
//
// In the caller's process is the load-bearing half. A model that asks to
// block for thirty seconds on one job must not stop the actor answering
// about any other, and an actor that performed the wait itself would do
// exactly that — the same reason `client/agency`'s join loop runs where
// it does rather than inside the Agency.
fn poll_for(
  wiring: Wiring,
  strand: String,
  id: JobId,
  wait_ms: Int,
  cursors: Cursors,
) -> Result(Polled, jobs.Refusal) {
  case wait_ms <= 0 {
    True ->
      jobs.poll_job(
        wiring.name,
        strand:,
        id:,
        cursors:,
        waiting: ask_timeout_ms,
      )
    False ->
      jobs.await_job(
        wiring.name,
        strand:,
        id:,
        cursors:,
        clock: wiring.clock,
        within_ms: int.clamp(wait_ms, min: 0, max: max_wait_ms),
        every: poll.Doubling(from: first_slice_ms, to: max_slice_ms),
        rest: wiring.rest,
        waiting: ask_timeout_ms,
      )
  }
}

// The one place a caller's text becomes a job id.
//
// An id that would break the `job/<id>` key shape is refused here rather
// than reaching a key builder, and the refusal is `Invalid` rather than
// `NotFound` because the two say different things to a model: one means
// "there is no job by that name", and this one means "that is not a name
// a job could have", which is a typo to fix rather than a job to stop
// looking for.
fn parse(id: String) -> Result(JobId, jobs.Refusal) {
  jobstate.parse_job_id(id)
  |> result.map_error(fn(_malformed) {
    jobs.Invalid(reason: "\"" <> id <> "\" is not a job id")
  })
}

/// The door's default resting function: the real sleep.
///
/// A named value rather than a literal at the wiring site, so a test that
/// wants to count slices substitutes one thing and a reader can see what
/// production passes.
///
/// ## Examples
///
/// ```gleam
/// // jobseam.Wiring(name:, clock:, rest: jobseam.real_rest(), clearance_ms:)
/// ```
///
pub fn real_rest() -> fn(Int) -> Nil {
  process.sleep
}
