//// The session's background jobs: one actor that owns every job's
//// durable record and its ceiling, and one runner process per job that
//// owns the jailed execution, its output and its stdin.
////
//// A background job is a jailed process the harness started on a model's
//// behalf that is allowed to outlive the tool call which started it,
//// bounded by a wall deadline fixed at start, owned by a strand, and
//// killable through the same TERM-then-KILL ladder a foreground call
//// has. `client/jobstate` is the state space and the durable codec, and
//// holds no process; this module is everything that needs one.
////
//// ## Why the runner and not the actor calls the broker
////
//// Two clauses of the broker's contract force it, and both are about
//// *which process* asks.
////
//// `broker.clear_call` waits out a full helper pool in the caller's own
//// process, for as long as the caller's clearance budget allows. An actor
//// blocked there could not answer a poll about a job that is already
//// running, so a congested pool would make every existing job unreadable
//// until a helper came free.
////
//// And the broker's per-call relay monitors the process that owns the
//// events subject, cancelling the execution when it dies. That watch is
//// the only thing that stops a job outliving the harness that wanted it,
//// so the owner of that subject has to be a process whose life is exactly
//// the job's — which the session-lived actor is not, and a per-job runner
//// is.
////
//// The runner therefore holds the events subject, the two rolling tails
//// and the staging files, and the actor holds the record, the ceiling and
//// the closures that cancel and write stdin. A poll of a live job is a
//// monitored call from the actor into its runner; a poll of a finished
//// one is answered from the tails the runner handed back with its final
//// report.
////
//// ## Why the terminal fact is written after the weft outcome
////
//// Each runner is one task of its own `weft` run, relayed into this
//// actor's mailbox, and the terminal state is committed only when that
//// outcome arrives. A weft outcome is reported once the worker has
//// exited, so the scope's exit is the drain proof and "this job is
//// finished" is never written ahead of the process actually being gone.
//// Reading the settlement off the runner's own message and committing
//// there would be a durable claim about a jailed process made by
//// something that had not yet watched it go.
////
//// The run carries a plain task rather than a managed one, and that is a
//// departure from the design note worth naming. A managed task exists to
//// witness owners a worker *discovers* while it runs; this worker
//// discovers none. Everything that outlives it — the helper's execution —
//// is reached through the broker, whose relay is already watching this
//// very worker, and whose pid the clearance seam deliberately does not
//// hand out. A ledger with nothing to adopt is machinery with no job.
////
//// ## What a restart costs, and why it lives in the restartable tier
////
//// The actor sits beside `client/extension/hosts` in `client/serve`'s
//// restartable services tier, bound to a reclaimable `weft/registry`
//// address so a replacement answers at the same address and no caller
//// caches a subject. A restart kills every runner it owned, which kills
//// every job: the runners are linked to it, the broker's relays see their
//// callers die and climb the ladder, and the replacement's first act —
//// before it serves a single request — is to sweep `job/*` and commit
//// `Lost` for everything it finds still live.
////
//// The replacement then holds every record that sweep decoded, detached
//// and with two empty tails, so a model polling the job the restart
//// killed is told `Lost` rather than `NotFound`. Answering from memory is
//// what makes that one sentence: `NotFound` is reserved for "no such job,
//// or somebody else's", and a job the harness lost is neither.
////
//// That sweep reports `VmRestart` for both of the cases it covers, and
//// the distinction `jobstate.OwnerRestart` names is deliberately not
//// drawn. Telling "the first start of this session's actor" from "a
//// supervisor restarted it" needs state that survives the actor and dies
//// with the VM, which is a durable cell or a second process — machinery
//// bought for a word in a message nobody branches on. `OwnerRestart`
//// stays in the vocabulary for the day something needs to act on the
//// difference.
////
//// ## The deadline, and who enforces it
////
//// The wall deadline is fixed at start and never renewed, and four
//// parties agree on it because they all read the same number: the
//// capability token, the broker relay's receive deadline, the helper's
//// own wall timer, and the budget ledger. The relay cancels the execution
//// at that instant on its own, so the deadline needs no timer here to be
//// *enforced*. What it needs a clock for is *attribution*: an execution
//// the relay cancelled settles like any other, and only the party that
//// asked can say the job was killed by its deadline rather than having
//// exited. The runner therefore bounds its own fold at the deadline, asks
//// the actor to note `Draining(ByDeadline)` when it passes, and carries
//// the same cause in its final report — so the attribution holds whether
//// or not the notice reached the mailbox before the outcome did. The
//// notice is noted **in memory only**: one durable write per settlement
//// is the rule, the report is about to make that write, and a poll during
//// the ladder reads the actor's own state rather than the store. Two
//// different senders reach this actor and nothing orders them against
//// each other.
////
//// ## The ledger identity
////
//// A job clears under `{op_id, "job/" <> id}` rather than under the batch
//// that started it, so each job gets its own ledger at
//// `max_outstanding: 1` and its own deadline. `docs/adr/005` records why
//// in its second addendum: a detached job is not part of a batch's
//// parallel width, and `bash` opens the batch's ledger at a cap of one.
//// The operation half is kept because it is what `broker.abort`
//// addresses — aborting the operation that *started* a job kills it,
//// which is what an operator asking for that means, and aborting a later
//// one does not, because detachment is what the model asked for.

import broker/broker.{type CallEvent, type CallSpec}
import broker/budget
import broker/exec.{type EnforcementDemand}
import broker/framing
import broker/policy.{type SandboxPolicy}
import client/internal/timebase
import client/jobstate.{
  type JobId, type JobRecord, type JobSpill, type JobState, type KillCause,
}
import core/clock.{type Clock}
import core/ids.{type OpId}
import core/json.{type JsonValue}
import gleam/bool
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Selector, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision
import gleam/result
import gleam/string
import runtime/api.{type Runtime}
import simplifile
import tom
import tools/bash
import tools/blob
import tools/fs
import tools/tail.{type Tail}
import tools/tool
import weft
import weft/actor
import weft/poll
import weft/registry as address

// --- the bounds this module is the only enforcer of -----------------------

/// How many non-terminal jobs one strand may hold at once.
///
/// Per strand and with no session-wide limit in this cut. A running job
/// occupies one jailed helper for its whole life, and the pool is four to
/// sixteen processes, so sixteen strands each holding four would exhaust
/// the largest pool — the arithmetic is recorded rather than pretended
/// away, and a dedicated job pool is the follow-up if real use shows the
/// shared one starving.
pub const max_jobs_per_strand = 4

/// The longest wall a job gets when its caller names none, and the
/// ceiling a larger request is clamped to unless `[jobs].max_wall` raises
/// it.
///
/// A default is met with the session policy's own `limits.wall_s` before
/// it becomes a deadline, so a workspace granting ten minutes starts a
/// job with no timeout at ten minutes rather than having its clearance
/// refused for asking for an hour. `granted_wall` has the argument.
pub const default_wall_ms = 3_600_000

/// How many bytes of each stream the rolling tail retains.
pub const tail_bytes = 8192

/// How long past a job's wall deadline the runner keeps folding before it
/// gives up on ever seeing a settlement.
///
/// The broker's own relay grace plus the helper's cancel ladder, the same
/// arithmetic `tools/bash.settle_grace_ms` makes for a foreground call, so
/// a job always outwaits a broker that is still settling honestly.
pub const settle_grace_ms = 10_000

/// How long a session stop waits for the jobs it just cancelled to settle.
///
/// Comfortably inside `client/serve.service_grace_ms`, because this runs
/// on the actor's own shutdown path and a supervisor that ran out of
/// patience kills it outright. A job that has not settled by then keeps
/// its durable `Draining(BySessionStop)`, and the next boot's sweep turns
/// that into `Lost(VmRestart)` — which is the truth, since nobody ever
/// observed its end.
pub const stop_grace_ms = 3000

/// How long the actor waits on a runner it asked for output.
///
/// Short, because a runner answers from its own fold loop with no I/O in
/// between; a runner that does not answer inside this is one blocked in a
/// clearance, and a poll that reported an empty tail beats an actor that
/// stopped serving every other job to wait for it.
pub const runner_ask_ms = 1000

/// The operator's `[jobs]` table, resolved.
///
/// One field today, which is deliberate rather than provisional: the
/// ceiling and the tail size are harness arithmetic an operator has no
/// stake in, and the wall is the one number a workspace running a dev
/// server for a day genuinely has to raise.
pub type JobsPolicy {
  JobsPolicy(
    /// The ceiling a requested wall is clamped to, in milliseconds. Never
    /// below `default_wall_ms`: the table raises the clamp and cannot
    /// lower it, because a lower operator ceiling is what the session's
    /// own sandbox policy already expresses, and expressing it twice
    /// would let the two disagree.
    max_wall_ms: Int,
  )
}

/// The policy a host with no `[jobs]` table serves.
pub const default_policy = JobsPolicy(max_wall_ms: default_wall_ms)

// --- what a caller asks for, and what it hears back -----------------------

/// One request to start a job.
pub type Request {
  Request(
    /// The shell command, run exactly as `bash -lc` runs a foreground one.
    command: String,
    /// The wall the caller asked for, in milliseconds, or `None` for the
    /// default. Clamped to the operator's ceiling, never widened; a
    /// `None` is additionally met with the session policy's own wall, so
    /// a job that named no timeout is admitted under the policy as it
    /// stands rather than refused for asking for the whole hour.
    wall_ms: Option(Int),
  )
}

/// A job that is running, and the terms it is running under.
pub type Started {
  Started(
    id: JobId,
    /// The absolute instant the job's wall expires at, on the session's
    /// own time base.
    deadline_ms: Int,
    /// The wall actually granted: what the caller asked for clamped by
    /// the operator's ceiling, or — for a caller that asked for nothing —
    /// the default hour met with the session policy's own wall. Either
    /// way the caller is told what it got rather than left to assume.
    wall_ms: Int,
  )
}

/// Where a poll left off in each stream.
pub type Cursors {
  Cursors(stdout: Int, stderr: Int)
}

/// A poll of one job.
pub type Polled {
  Polled(
    id: JobId,
    state: JobState,
    /// How long the job has been alive, in milliseconds.
    age_ms: Int,
    deadline_ms: Int,
    /// What each stream carried after the cursor the poll asked with, and
    /// where to carry on from. `tools/tail`'s own answer, passed
    /// straight through: a record of the same three fields here would be
    /// a second name for one type and a place for the two to drift.
    stdout: tail.Since,
    stderr: tail.Since,
    /// The content addresses of the whole streams, once the job has
    /// finished. Empty while it runs.
    spill: JobSpill,
  )
}

/// One row of a strand's job listing.
pub type Listed {
  Listed(id: JobId, state: JobState, age_ms: Int, deadline_ms: Int)
}

/// Why a request produced no answer.
pub type Refusal {
  /// The strand already holds `max_jobs_per_strand` live jobs. Refused in
  /// band and loudly, the way the orchestration seam refuses a spawn
  /// ceiling: a model that keeps starting jobs has to be told it is at
  /// the limit rather than watching them silently not run.
  CeilingReached(limit: Int)

  /// No job by that id belongs to the asking strand. Deliberately one
  /// answer for two facts — there is no such job, and there is one and it
  /// is somebody else's — because a strand guessing at a sibling's ids
  /// must not learn from the answer which of its guesses were real.
  NotFound(id: String)

  /// The request could not be honoured as asked.
  Invalid(reason: String)

  /// The clearance refused the job before anything ran. The words are the
  /// broker's own, because this is the same refusal a foreground `bash`
  /// would have shown for the same command under the same policy.
  ClearanceRefused(reason: String)

  /// Nothing was decided: the runtime holder is not up, the actor is not
  /// running, or a durable commit could not be made.
  Unavailable(reason: String)
}

// --- the spill seam -------------------------------------------------------

/// The staging-and-promotion seam a job's whole output travels through.
///
/// A record of closures rather than direct calls, for the reason
/// `tools/tool.FileSystem` is one: everything here is I/O against a
/// directory, and a test that wants to prove a spill landed
/// content-addressed past the cap should not need a real filesystem to do
/// it. `blob_spill` is the production filling.
///
/// The split between `append` and `store` is the whole point.
/// `tools/blob.bound` is one-shot and content-addressed over a *complete*
/// body, which a running job does not have, so output is appended to a
/// per-job staging file while the job runs and handed to the
/// content-addressed writer only once. A model never reads a staging
/// file: it reads the tail while the job runs and the ref once it ends.
pub type Spill {
  Spill(
    /// Appends to one job's staging file, creating it if it is not there.
    append: fn(String, BitArray) -> Result(Nil, String),
    /// Reads a staging file whole, for promotion.
    read: fn(String) -> Result(BitArray, String),
    /// Removes a staging file. Absence is success: the caller's intent is
    /// that the file be gone.
    remove: fn(String) -> Result(Nil, String),
    /// Every staging file the store currently holds, as absolute paths.
    /// The restart sweep's only input, since a fresh actor owns no jobs
    /// and every staging file it can see is therefore an orphan.
    staged: fn() -> Result(List(String), String),
    /// Writes a complete body to its content address and hands back the
    /// `sha256-` ref. `tag` makes one write's own staging name unique,
    /// exactly as `tools/blob.temp_path` requires.
    store: fn(String, BitArray) -> Result(String, String),
  )
}

/// The production spill over one blob root.
///
/// The staging files live in the blob root itself so the promotion's
/// rename stays within one filesystem and is therefore atomic, and they
/// carry the same hidden `.`-prefixed `.tmp`-suffixed shape
/// `tools/blob.temp_path` already uses, so a reader walking the store can
/// tell staged bytes from an address at a glance.
///
/// ## Examples
///
/// ```gleam
/// // jobs.blob_spill("/session/.blobs")
/// ```
///
pub fn blob_spill(root root: String) -> Spill {
  let filesystem = fs.real_filesystem()
  Spill(
    append: fn(path, bytes) {
      case simplifile.append_bits(path, bytes) {
        Ok(Nil) -> Ok(Nil)
        Error(error) -> Error(simplifile.describe_error(error))
      }
    },
    read: fn(path) {
      case simplifile.read_bits(path) {
        Ok(bytes) -> Ok(bytes)
        Error(error) -> Error(simplifile.describe_error(error))
      }
    },
    remove: fn(path) {
      case simplifile.delete(path) {
        Ok(Nil) | Error(simplifile.Enoent) -> Ok(Nil)
        Error(error) -> Error(simplifile.describe_error(error))
      }
    },
    staged: fn() {
      case simplifile.read_directory(root) {
        Error(simplifile.Enoent) -> Ok([])
        Error(error) -> Error(simplifile.describe_error(error))
        Ok(names) ->
          names
          |> list.filter(is_staging_name)
          |> list.map(fn(name) { root <> "/" <> name })
          |> Ok
      }
    },
    store: fn(tag, bytes) {
      let ref = blob.ref_for(bytes)
      let path = blob.ref_path(root, ref)
      use Nil <- result.try(
        filesystem.create_directory_all(root)
        |> result.map_error(string.inspect),
      )
      use present <- result.try(
        filesystem.is_file(path) |> result.map_error(string.inspect),
      )
      use <- bool.guard(when: present, return: Ok(ref))
      blob.write_addressed(
        filesystem:,
        path:,
        temporary: blob.temp_path(root, ref, tag),
        bytes:,
      )
      |> result.map(fn(_nil) { ref })
      |> result.map_error(string.inspect)
    },
  )
}

/// The staging file one job's one stream accumulates into.
///
/// ## Examples
///
/// ```gleam
/// // jobs.staging_path("/blobs", id, framing.Stdout)
/// //   == "/blobs/.job-01JQ8XZ.stdout.tmp"
/// ```
///
pub fn staging_path(
  root root: String,
  id id: JobId,
  stream stream: framing.OutputStream,
) -> String {
  root
  <> "/"
  <> staging_prefix
  <> jobstate.job_id_to_string(id)
  <> "."
  <> stream_name(stream)
  <> staging_suffix
}

const staging_prefix = ".job-"

const staging_suffix = ".tmp"

fn stream_name(stream: framing.OutputStream) -> String {
  case stream {
    framing.Stdout -> "stdout"
    framing.Stderr -> "stderr"
  }
}

fn is_staging_name(name: String) -> Bool {
  string.starts_with(name, staging_prefix)
  && string.ends_with(name, staging_suffix)
}

// --- the operator's table -------------------------------------------------

/// Reads the `[jobs]` table out of a `loom.toml`.
///
/// Separate from every other parser over the same file for the reason
/// `client/schedule.parse_policy` is: a document with no `[jobs]` table at
/// all still has a policy, and it is this one.
///
/// ## Examples
///
/// ```gleam
/// assert jobs.parse_policy("") == Ok(jobs.default_policy)
/// ```
///
/// ```gleam
/// assert jobs.parse_policy("[jobs]\nmax_wall = 86400\n")
///   == Ok(jobs.JobsPolicy(max_wall_ms: 86_400_000))
/// ```
///
pub fn parse_policy(text: String) -> Result(JobsPolicy, String) {
  use document <- result.try(
    tom.parse(text)
    |> result.map_error(fn(error) {
      "the configuration is not valid TOML: " <> string.inspect(error)
    }),
  )
  case dict.get(document, "jobs") {
    Error(Nil) -> Ok(default_policy)
    Ok(tom.Table(fields)) -> policy_table(fields)
    Ok(_other) -> Error("[jobs] must be a table")
  }
}

fn policy_table(fields: Dict(String, tom.Toml)) -> Result(JobsPolicy, String) {
  use Nil <- result.try(known_keys(dict.keys(fields), ["max_wall"]))
  case dict.get(fields, "max_wall") {
    Error(Nil) -> Ok(default_policy)

    // Seconds, because a workspace raising this is thinking in hours and
    // a day is `86400` rather than a number with seven zeroes on it. The
    // clamp only ever goes up: a host that wants shorter jailed
    // executions says so in its sandbox policy's own wall, which every
    // job composes against anyway, and two ceilings that could disagree
    // is a worse arrangement than one.
    Ok(tom.Int(seconds)) if seconds > 0 ->
      Ok(JobsPolicy(max_wall_ms: int.max(seconds * 1000, default_wall_ms)))

    Ok(_other) ->
      Error(
        "jobs.max_wall must be a positive whole number of seconds: it raises "
        <> "the ceiling a background job's wall is clamped to, which "
        <> "defaults to an hour, and it cannot lower it",
      )
  }
}

fn known_keys(
  present: List(String),
  allowed: List(String),
) -> Result(Nil, String) {
  case list.filter(present, fn(key) { !list.contains(allowed, key) }) {
    [] -> Ok(Nil)
    [unknown, ..] -> Error("the [jobs] table has no `" <> unknown <> "` key")
  }
}

// --- wiring ---------------------------------------------------------------

/// Everything the actor needs from its host, as one value rather than a
/// growing parameter list.
pub type Wiring {
  Wiring(
    /// Borrows the live runtime. A function rather than the runtime
    /// itself for the reason `client/scheduleseam.Wiring` states: the
    /// seam is built before `api.open` has returned one, so a closure
    /// over the runtime would be a value cycle. `Error(Nil)` becomes an
    /// in-band `Unavailable`, never a crash.
    runtime: fn() -> Result(Runtime, Nil),
    policy: JobsPolicy,
    /// The session's own time base. Every instant a job records and every
    /// wait a poll makes is read through this, so a simulated session
    /// runs on its logical clock.
    clock: Clock,
    /// The seed for this actor's id generator. Read once at start, from
    /// the host's injected entropy.
    seed: Int,
    /// The workspace a job's jail is rooted at.
    workspace: String,
    /// The session base policy a job's requirements compose onto.
    base_policy: SandboxPolicy,
    /// Enforcement strictness for a job's jailed execution.
    demand: EnforcementDemand,
    /// The allowlist-constructed child environment.
    env: List(#(String, String)),
    /// The broker seam, exactly `tools/tool.Ctx.clear_call`. Called from
    /// the runner's own process, which is what binds the relay's
    /// caller-watch to the job rather than to this actor.
    clear_call: fn(CallSpec, Subject(CallEvent)) ->
      Result(tool.RunningCall, broker.Refusal),
    /// How long a clearance may spend waiting out a congested pool.
    clearance_ms: Int,
    spill: Spill,
    /// Where staging files live. The blob root, so a promotion's rename
    /// stays inside one filesystem.
    blob_root: String,
  )
}

// --- messages -------------------------------------------------------------

/// What the actor is asked. Opaque: every caller reaches it through
/// `client/jobseam`, so there is one place that decides what a wedged or
/// absent actor answers.
pub opaque type Message {
  Start(
    strand: String,
    operation: OpId,
    request: Request,
    reply_with: Subject(Result(Started, Refusal)),
  )

  PollOne(
    strand: String,
    id: JobId,
    cursors: Cursors,
    reply_with: Subject(Result(Polled, Refusal)),
  )

  ListAll(strand: String, reply_with: Subject(Result(List(Listed), Refusal)))

  LiveJobs(strand: String, reply_with: Subject(Result(JsonValue, Refusal)))

  Kill(strand: String, id: JobId, reply_with: Subject(Result(Nil, Refusal)))

  Write(
    strand: String,
    id: JobId,
    data: BitArray,
    end: StdinEnd,
    reply_with: Subject(Result(Nil, Refusal)),
  )

  /// The runner's clearance returned, one way or the other. `Ok` carries
  /// the closures that cancel the execution and write to its stdin; both
  /// are plain sends into the broker, so the actor may hold and call them
  /// from its own process.
  Clearance(id: JobId, outcome: Result(Control, broker.Refusal))

  /// The runner's wall deadline passed. Attribution only: the broker's
  /// relay is already cancelling, and this is what makes a poll during
  /// the ladder read `Draining(ByDeadline)` rather than `Running`.
  DeadlinePassed(id: JobId)

  /// One runner's weft outcome. The drain proof, and the only thing that
  /// may write a terminal state.
  Reported(id: JobId, pulled: weft.Pulled(Settlement, RunnerFault))

  /// The restart sweep, injected before the mailbox is ever read.
  Reap
}

/// Whether a write to a job's stdin closes it.
///
/// A two-variant type rather than the `Bool` the broker's own `stdin`
/// takes, because `send(id, data, True)` names nothing at a call site. The
/// polarity is converted once, at the broker boundary.
pub type StdinEnd {
  /// Close the child's stdin after this chunk. Nothing may be written
  /// afterwards, which is what makes a pipeline reading stdin terminate.
  CloseStdin

  /// Leave stdin open. The difference between watching a log and driving
  /// a REPL, and the reason a background job does not close stdin the way
  /// a foreground `bash` call does.
  KeepStdinOpen
}

/// The closures a cleared job is steered by. Held by the actor, minted by
/// the runner, and all of them plain sends into the broker.
pub opaque type Control {
  Control(
    cancel: fn() -> Nil,
    stdin: fn(BitArray, Bool) -> Nil,
    /// Where the runner answers questions about its output.
    asks: Subject(Ask),
  )
}

/// What the actor asks a live runner.
pub opaque type Ask {
  /// Hand back both tails as they stand. The runner owns them, so this is
  /// the only way to read a running job's output.
  Tails(reply_with: Subject(Streams))
}

/// Both of one job's rolling tails.
type Streams {
  Streams(stdout: Tail, stderr: Tail)
}

/// What a runner hands back when its work is over.
///
/// `stopped_by` is how attribution survives the two senders that reach
/// this actor: the runner names the cause it observed, so a settlement
/// that overtook the deadline notice is still recorded as a kill rather
/// than as an ordinary exit.
type Settlement {
  Settlement(
    outcome: broker.CallOutcome,
    stopped_by: Option(KillCause),
    spill: JobSpill,
    streams: Streams,
  )
}

/// Why a runner produced no settlement.
type RunnerFault {
  /// The clearance refused before anything ran.
  Refused(refusal: broker.Refusal)

  /// The runner outwaited the deadline and the whole settle grace without
  /// the broker delivering the settlement it promised.
  NeverSettled
}

// --- state ----------------------------------------------------------------

/// Whether a job still has a runner, and what that runner has published.
///
/// Three states rather than a record of options, so "a job with tails and
/// a live runner" and "a job with a cancel closure but no runner" are not
/// values anything has to be written to tolerate.
type Custody {
  /// A runner is alive and its clearance has not returned. There is
  /// nothing to cancel and no output to read, and the caller that asked
  /// for the job is still waiting on `reply_with`.
  Dispatching(
    reports: Subject(weft.Pulled(Settlement, RunnerFault)),
    reply_with: Subject(Result(Started, Refusal)),
  )

  /// A runner is alive and the helper accepted the run.
  Attached(
    reports: Subject(weft.Pulled(Settlement, RunnerFault)),
    control: Control,
  )

  /// No runner. The tails it left behind are the whole of what a poll can
  /// still show, which is why a settled job's output does not vanish the
  /// moment its process does.
  Detached(streams: Streams)
}

type Held {
  Held(record: JobRecord, custody: Custody)
}

type State {
  State(
    wiring: Wiring,
    self: Subject(Message),
    generator: ids.Generator,
    jobs: Dict(JobId, Held),
    /// The report channels of runners whose outcome has been taken but
    /// whose relay has not yet said its last word.
    ///
    /// A relay sends the outcome and then `AllDelivered`, and taking the
    /// outcome is exactly what ends a job's custody — so a selector built
    /// from the live set alone would stop carrying that channel one
    /// message too early and leave the second message unmatched in the
    /// mailbox for the rest of the session. This is the one ledger that
    /// outlives the custody, and it outlives the *record* too, which is
    /// what covers a refused start whose cell is deleted outright.
    last_words: Dict(JobId, Subject(weft.Pulled(Settlement, RunnerFault))),
  )
}

// --- starting -------------------------------------------------------------

/// Starts the session's jobs actor at `name`.
///
/// Starts no job and reaps every one it finds: the sweep runs as an
/// injected `continuing` message, so it is complete before the first
/// request is served and no poll can ever see a record this incarnation
/// was going to declare `Lost`.
///
/// ## Examples
///
/// ```gleam
/// // jobs.start(name, wiring)
/// ```
///
pub fn start(
  name: address.Address(Message),
  wiring: Wiring,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let state =
      State(
        wiring:,
        self: subject,
        generator: ids.generator(wiring.clock, seed: wiring.seed),
        jobs: dict.new(),
        last_words: dict.new(),
      )
    actor.initialised(state)
    |> actor.selecting(process.new_selector() |> process.select(subject))
    |> actor.returning(subject)
    |> actor.continuing(Reap)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.addressed(name)
  |> actor.trapping_exits(True)
  |> actor.on_shutdown(fn(state, _reason) {
    let _stopped = stop_every_job(state)
    Nil
  })
  |> actor.start
}

/// The actor as a supervisor's child, which is how a session wires it.
///
/// A restart costs every job the session was running, recorded as `Lost`
/// by the replacement's sweep. That is why it belongs in the restartable
/// services tier rather than among the children whose death is fatal: a
/// lost job is a job the model is told about on its next poll, and a
/// session that ended because a job's bookkeeping crashed would be a much
/// worse trade.
pub fn supervised(
  name: address.Address(Message),
  wiring: Wiring,
) -> supervision.ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(name, wiring) })
}

// --- the door's four operations, keyed on the caller's strand -------------

/// Admits one job for `strand` under `operation`.
///
/// Blocks until the clearance has returned one way or the other, which is
/// what lets a policy refusal reach the caller in the words a foreground
/// `bash` would have used. After that the job is detached and every later
/// question about it is a poll.
///
/// ## Examples
///
/// ```gleam
/// // jobs.start_job(name, "main", operation, jobs.Request("tail -f log", None))
/// ```
///
pub fn start_job(
  name: address.Address(Message),
  strand strand: String,
  operation operation: OpId,
  request request: Request,
  waiting waiting: Int,
) -> Result(Started, Refusal) {
  ask(name, waiting, fn(reply) {
    Start(strand:, operation:, request:, reply_with: reply)
  })
}

/// One job's state and whatever it has printed since the cursors.
///
/// ## Examples
///
/// ```gleam
/// // jobs.poll_job(name, "main", id, jobs.Cursors(0, 0))
/// ```
///
pub fn poll_job(
  name: address.Address(Message),
  strand strand: String,
  id id: JobId,
  cursors cursors: Cursors,
  waiting waiting: Int,
) -> Result(Polled, Refusal) {
  ask(name, waiting, fn(reply) {
    PollOne(strand:, id:, cursors:, reply_with: reply)
  })
}

/// Every job the strand owns, live and finished.
pub fn list_jobs(
  name: address.Address(Message),
  strand strand: String,
  waiting waiting: Int,
) -> Result(List(Listed), Refusal) {
  ask(name, waiting, fn(reply) { ListAll(strand:, reply_with: reply) })
}

/// Reads at most four live jobs without scanning durable job history.
///
/// ## Examples
///
/// ```gleam
/// // jobs.live_jobs(name, "main", waiting: 1000)
/// ```
pub fn live_jobs(
  name: address.Address(Message),
  strand: String,
  waiting waiting: Int,
) -> Result(JsonValue, Refusal) {
  ask(name, waiting, fn(reply) { LiveJobs(strand:, reply_with: reply) })
}

/// Asks the broker to stop one job. Needs no approval: a strand may
/// always stop what it started.
///
/// Returns once the ladder has been asked for, not once it has finished.
/// The job's terminal state and its `cancelled` flag arrive on the next
/// poll, because only the helper can witness that it climbed.
pub fn kill_job(
  name: address.Address(Message),
  strand strand: String,
  id id: JobId,
  waiting waiting: Int,
) -> Result(Nil, Refusal) {
  ask(name, waiting, fn(reply) { Kill(strand:, id:, reply_with: reply) })
}

/// Writes to one job's stdin, optionally closing it.
pub fn write_stdin(
  name: address.Address(Message),
  strand strand: String,
  id id: JobId,
  data data: BitArray,
  end end: StdinEnd,
  waiting waiting: Int,
) -> Result(Nil, Refusal) {
  ask(name, waiting, fn(reply) {
    Write(strand:, id:, data:, end:, reply_with: reply)
  })
}

/// Polls one job until it is terminal or `within_ms` runs out, on the
/// session's own time base.
///
/// A job still running when the budget expires is a **successful** answer
/// carrying its live state, not a failure — the "pending is an answer"
/// rule `client/agency`'s wait already follows, and the reason a model
/// that wants to block on a job can. Only a refusal ends the wait early.
///
/// The loop runs in the caller's own process, which is what keeps a model
/// waiting thirty seconds on one job from stopping the actor answering
/// about any other.
///
/// ## Examples
///
/// ```gleam
/// // jobs.await_job(name, "main", id, cursors, within_ms: 30_000,
/// //   every: poll.Doubling(from: 25, to: 250), rest: process.sleep)
/// ```
///
pub fn await_job(
  name: address.Address(Message),
  strand strand: String,
  id id: JobId,
  cursors cursors: Cursors,
  clock clock: Clock,
  within_ms within_ms: Int,
  every every: poll.Interval,
  rest rest: fn(Int) -> Nil,
  waiting waiting: Int,
) -> Result(Polled, Refusal) {
  let verdict =
    poll.fold_until(
      clock: timebase.on(clock, rest),
      within: int.max(within_ms, 0),
      every:,
      from: None,
      attempt: fn(_last) {
        case poll_job(name, strand:, id:, cursors:, waiting:) {
          Error(refusal) -> poll.Broken(refusal)
          Ok(polled) ->
            case jobstate.is_terminal(polled.state) {
              True -> poll.Settled(polled)
              False -> poll.Pending(Some(polled))
            }
        }
      },
    )
  case verdict {
    poll.Answer(polled) -> Ok(polled)
    poll.Failure(refusal) -> Error(refusal)
    poll.RanOut(Some(polled)) -> Ok(polled)

    // Unreachable: `fold_until` makes at least one attempt, and every
    // attempt either settles, fails, or hands back a `Some`. The arm is
    // written out because that is what makes it checkable, and it answers
    // with the one thing that is certainly true — nothing was learned.
    poll.RanOut(None) ->
      Error(Unavailable(reason: "the jobs actor was never asked"))
  }
}

// One question to the actor, degrading an absent or wedged one to an
// in-band refusal rather than to the caller's death. `process.call` exits
// its caller on a timeout or a dead callee, and every caller here is a
// strand effect process holding a verdict the model is meant to read.
fn ask(
  name: address.Address(Message),
  timeout_ms: Int,
  build: fn(Subject(Result(answer, Refusal))) -> Message,
) -> Result(answer, Refusal) {
  let absent = Unavailable(reason: "the session runs no background jobs actor")
  case address.lookup(name) {
    Error(Nil) -> Error(absent)
    Ok(subject) -> {
      use pid <- result.try(
        process.subject_owner(subject) |> result.replace_error(absent),
      )
      let reply = process.new_subject()
      let monitor = process.monitor(pid)
      let selector =
        process.new_selector()
        |> process.select_map(reply, Answered)
        |> process.select_specific_monitor(monitor, ActorDied)
      process.send(subject, build(reply))
      let answer = case process.selector_receive(selector, timeout_ms) {
        Ok(Answered(answer:)) -> answer
        Ok(ActorDied(..)) ->
          Error(Unavailable(reason: "the jobs actor died mid-request"))
        Error(Nil) ->
          Error(Unavailable(reason: "the jobs actor did not answer in time"))
      }
      process.demonitor_process(monitor)
      answer
    }
  }
}

// What a caller of `ask` selects on.
type Asked(answer) {
  Answered(answer: Result(answer, Refusal))
  ActorDied(down: process.Down)
}

// --- the actor ------------------------------------------------------------

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Reap -> actor.continue(reap(state))

    Start(strand:, operation:, request:, reply_with:) ->
      admit(state, strand, operation, request, reply_with)

    PollOne(strand:, id:, cursors:, reply_with:) -> {
      process.send(reply_with, polled(state, strand, id, cursors))
      actor.continue(state)
    }

    LiveJobs(strand:, reply_with:) -> {
      let #(now, _clock) = clock.read(state.wiring.clock)
      process.send(reply_with, Ok(live_board(state.jobs, strand, now)))
      actor.continue(state)
    }
    ListAll(strand:, reply_with:) -> {
      process.send(reply_with, Ok(listing(state, strand)))
      actor.continue(state)
    }

    Kill(strand:, id:, reply_with:) ->
      requested_kill(state, strand, id, reply_with)

    Write(strand:, id:, data:, end:, reply_with:) -> {
      process.send(reply_with, write_to_stdin(state, strand, id, data, end))
      actor.continue(state)
    }

    Clearance(id:, outcome:) -> cleared(state, id, outcome)

    DeadlinePassed(id:) -> actor.continue(deadline_passed(state, id))

    Reported(id:, pulled:) -> reported(state, id, pulled)
  }
}

// Every `continue` that could have changed the live set goes through here,
// because the selector carries one entry per live runner and a stale one
// would either drop a settlement or select on a subject nobody writes to.
fn resume(state: State) -> actor.Next(State, Message) {
  actor.continue(state) |> actor.with_selector(selector(state))
}

// The actor's own subject, one mapped entry per live runner's report
// channel, and one per relay that still owes its last word.
//
// One channel per job rather than one shared one, because `weft.Pulled`
// names the task's index within its own run and nothing else: with one
// task per run every outcome would arrive as index zero, and a settlement
// could not be matched back to the job that produced it. Closing the id
// into the mapping function is what carries it.
//
// The two folds are the same mapping over two ledgers because a job's
// report channel outlives its custody by exactly one message. Dropping it
// with the custody would leave that message unselectable, and an
// unselectable message is never removed: it is scanned past by every
// receive the actor makes for the rest of the session.
fn selector(state: State) -> Selector(Message) {
  let live =
    dict.fold(
      state.jobs,
      process.new_selector() |> process.select(state.self),
      fn(built, id, held) {
        case held.custody {
          Detached(..) -> built
          Dispatching(reports:, ..) | Attached(reports:, ..) ->
            reporting(built, id, reports)
        }
      },
    )
  dict.fold(state.last_words, live, reporting)
}

fn reporting(
  built: Selector(Message),
  id: JobId,
  reports: Subject(weft.Pulled(Settlement, RunnerFault)),
) -> Selector(Message) {
  process.select_map(built, reports, fn(pulled) { Reported(id:, pulled:) })
}

// --- admission ------------------------------------------------------------

// The whole of what admission enforces, in the order the enforcement has
// to happen.
//
// The ceiling is counted before anything is minted, the wall is clamped
// before the record says what it is, and the durable cell is claimed
// *before* the clearance — the effect sandwich applied to a spawn, so a
// crash in the window leaves a `Starting` cell a later sweep can find
// rather than a jailed process nobody recorded.
//
// The claim is an expect-absent compare-and-set, so a minted id that
// somehow collided with a live one loses rather than overwriting it. That
// cannot happen from one generator, and the claim is what makes the
// sentence true rather than probable.
fn admit(
  state: State,
  strand: String,
  operation: OpId,
  request: Request,
  reply_with: Subject(Result(Started, Refusal)),
) -> actor.Next(State, Message) {
  case admitted(state, strand, operation, request, reply_with) {
    Error(refusal) -> {
      process.send(reply_with, Error(refusal))
      actor.continue(state)
    }
    Ok(state) -> resume(state)
  }
}

fn admitted(
  state: State,
  strand: String,
  operation: OpId,
  request: Request,
  reply_with: Subject(Result(Started, Refusal)),
) -> Result(State, Refusal) {
  use runtime <- result.try(borrow(state))
  use Nil <- result.try(room_for_one_more(state, strand))
  let #(now, _clock) = clock.read(state.wiring.clock)
  let wall_ms = granted_wall(state.wiring, request.wall_ms)
  use #(id, generator) <- result.try(mint(state.generator))
  let record =
    jobstate.JobRecord(
      id:,
      owner: strand,
      started_by: operation,
      spec: jobstate.JobSpec(
        argv: argv(request.command),
        cwd: state.wiring.workspace,
        requested_wall_ms: option.unwrap(request.wall_ms, default_wall_ms),
      ),
      started_at_ms: now,
      deadline_ms: now + wall_ms,
      state: jobstate.Starting,
      spill: jobstate.no_spill(),
    )
  use Nil <- result.try(claim(runtime, record))

  // The clearance happens on the runner, so the caller's reply subject is
  // parked in the job's custody until the runner has said whether there
  // is a job at all. Everything below this line is bookkeeping the caller
  // never waits on.
  let reports = process.new_subject()
  let _relay = spawn_runner(state, record, wall_ms, reports)
  let held = Held(record:, custody: Dispatching(reports:, reply_with:))
  Ok(State(..state, generator:, jobs: dict.insert(state.jobs, id, held)))
}

fn borrow(state: State) -> Result(Runtime, Refusal) {
  case state.wiring.runtime() {
    Error(Nil) ->
      Error(Unavailable(reason: "the session runtime is not available"))
    Ok(runtime) -> Ok(runtime)
  }
}

// "Are there this many or more" needs only the elements up to the bound
// rather than a full walk to count them — lint R5, and the idiom
// `client/scheduleseam.room_for_one_more` uses for its own ceiling.
fn room_for_one_more(state: State, strand: String) -> Result(Nil, Refusal) {
  let live =
    dict.values(state.jobs)
    |> list.filter(fn(held) {
      held.record.owner == strand && !jobstate.is_terminal(held.record.state)
    })
  case list.drop(live, max_jobs_per_strand - 1) {
    [] -> Ok(Nil)
    [_at_the_limit, ..] -> Error(CeilingReached(limit: max_jobs_per_strand))
  }
}

// What a caller asked for, clamped by the operator's ceiling — or, when
// it asked for nothing, the longest wall the session policy already
// grants.
//
// The two halves answer to different parties, which is why they are not
// one clamp.
//
// An **explicit** request is clamped rather than refused, for the reason
// `client/schedule.wake_under` caps rather than vetoes: a job that asked
// for two hours on an hour's ceiling gets an hour and is told so in
// `Started.wall_ms`. What the operator's ceiling cannot do is widen the
// session's own `limits.wall_s`, so a caller that still asks for more
// than the policy allows meets `RefuseNarrowed` at the clearance and is
// refused in the broker's own words — exactly what a foreground `bash`
// asking for a longer timeout than the policy grants is told, and what
// gives an escalation a narrowing to offer a grant against.
//
// A **default** has no such caller to escalate for. Asking for the whole
// hour against a policy granting ten minutes would make every job
// started without a timeout a policy refusal, which is a session-wide
// outage dressed as a verdict about one command. So the default is the
// meet of the hour and what the policy grants, admitted as the policy
// stands, and `Started.wall_ms` says which of the two it was.
fn granted_wall(wiring: Wiring, requested: Option(Int)) -> Int {
  case requested {
    Some(asked) -> int.clamp(asked, min: 1, max: wiring.policy.max_wall_ms)

    None -> meet_wall(default_wall_ms, wiring.base_policy.limits.wall_s * 1000)
  }
}

// The narrower of two walls in milliseconds, with zero meaning
// unlimited.
//
// `broker/policy.meet_limit`'s own lattice, read in the units this
// module counts in: a session policy with no wall at all is the top of
// it and leaves the hour standing.
fn meet_wall(ours: Int, theirs: Int) -> Int {
  use <- bool.guard(when: theirs <= 0, return: ours)
  int.min(ours, theirs)
}

// A fresh job id from the session's own generator.
//
// The `EntryId` wrapper is discarded at once: what is wanted is the
// UUIDv7 text, and `jobstate.JobId` is the type that carries it from here
// on. Reaching for the generator rather than for entropy directly is the
// tree's rule about identity being injected, and it is what makes a
// simulated session's job ids reproducible.
fn mint(generator: ids.Generator) -> Result(#(JobId, ids.Generator), Refusal) {
  let #(minted, generator) = ids.mint_entry(generator)
  case jobstate.parse_job_id(ids.entry_id_to_string(minted)) {
    Ok(id) -> Ok(#(id, generator))

    // Unreachable: a UUID's canonical text is thirty-six characters of
    // hexadecimal and hyphens, so it is neither empty nor does it carry
    // a separator. Refused rather than crashed all the same — a minting
    // that started producing ids this namespace cannot hold should stop
    // one caller, not take every other job's bookkeeping with it.
    Error(Nil) ->
      Error(Unavailable(reason: "a job id could not be minted for this key"))
  }
}

fn argv(command: String) -> List(String) {
  // Foreground and background commands use the same environment and exit
  // semantics. Login startup would replace the session's discovered PATH.
  ["bash", "-o", "pipefail", "-c", command]
}

// The cell's absence is the claim. `expected: None` commits only while
// nothing is there, so the id belongs to whichever writer lands first and
// a loser is told rather than silently replacing a live job's record.
fn claim(runtime: Runtime, record: JobRecord) -> Result(Nil, Refusal) {
  api.put_reserved_fact_expecting(
    runtime,
    jobstate.job_key(record.id),
    jobstate.encode(record),
    expected: None,
  )
  |> result.replace(Nil)
  |> result.map_error(commit_refused)
}

// Why a commit did not land.
//
// `SessionStolen` is the arm the tree words specially everywhere it
// appears: the writer lease is gone, which means this process is no
// longer the session's and the answer is to reopen, never to retry. So
// nothing here retries anything — every commit in this module is made
// once and its failure is reported.
fn commit_refused(error: api.ApiError) -> Refusal {
  case error {
    api.FactConflict(..) ->
      Unavailable(reason: "another writer holds this job's record")

    api.SessionStolen(held_by:) ->
      Unavailable(
        reason: "this session's writer lease was taken"
        <> case held_by {
          None -> ""
          Some(holder) -> " by " <> holder
        },
      )

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
    | api.EscalationWrongStatus(..) ->
      Unavailable(reason: string.inspect(error))
  }
}

// --- the runner -----------------------------------------------------------

// One job's run, relayed into this actor's mailbox.
//
// The deadline is the whole run's backstop rather than the job's own
// clock: the runner bounds its fold at the job deadline itself, and this
// covers the one wait the fold does not — a clearance spending the
// caller's budget on a congested pool. Its expiry kills the worker, whose
// death the broker's relay sees and answers with the cancel ladder, so
// even a wedged clearance cannot leave a jailed process behind.
fn spawn_runner(
  state: State,
  record: JobRecord,
  wall_ms: Int,
  reports: Subject(weft.Pulled(Settlement, RunnerFault)),
) -> Pid {
  let wiring = state.wiring
  let home = state.self
  let backstop = wiring.clearance_ms + wall_ms + settle_grace_ms
  weft.new([fn() { run(wiring, record, home) }])
  |> weft.deadline(backstop)
  |> weft.start_relayed(to: reports)
}

// Everything one runner does, in one process: clear, publish, fold,
// promote, report.
fn run(
  wiring: Wiring,
  record: JobRecord,
  home: Subject(Message),
) -> Result(Settlement, RunnerFault) {
  let events = process.new_subject()
  let asks = process.new_subject()
  let #(now, _clock) = clock.read(wiring.clock)
  let spec = call_spec(wiring, record, now)
  case wiring.clear_call(spec, events) {
    Error(refusal) -> {
      process.send(home, Clearance(id: record.id, outcome: Error(refusal)))
      Error(Refused(refusal:))
    }

    // The clearance returned, so a jailed process exists and there is
    // something to cancel. Publishing the controls before the first fold
    // is what makes a kill that arrives in the very next millisecond
    // reach the ladder instead of a job the actor cannot address.
    Ok(call) -> {
      let control = Control(cancel: call.cancel, stdin: call.stdin, asks:)
      process.send(home, Clearance(id: record.id, outcome: Ok(control)))
      fold(
        Runner(
          wiring:,
          home:,
          id: record.id,
          events:,
          asks:,
          until: record.deadline_ms,
          phase: Streaming,
          stopped_by: None,
          streams: no_streams(),
          staged: [],
        ),
      )
    }
  }
}

// Whether the runner is still inside the job's wall or inside the grace
// it allows the cancel ladder afterwards.
type Phase {
  Streaming
  Draining
}

type Runner {
  Runner(
    wiring: Wiring,
    home: Subject(Message),
    id: JobId,
    events: Subject(CallEvent),
    asks: Subject(Ask),
    /// The absolute instant this phase's receive stops waiting at.
    until: Int,
    phase: Phase,
    stopped_by: Option(KillCause),
    streams: Streams,
    /// Which streams have staged at least one byte, so promotion only
    /// reads files that exist.
    staged: List(framing.OutputStream),
  )
}

// What wakes a runner: the broker spoke, or the actor asked a question.
type Wake {
  FromCall(event: CallEvent)
  FromActor(ask: Ask)
}

fn fold(runner: Runner) -> Result(Settlement, RunnerFault) {
  let #(now, _clock) = clock.read(runner.wiring.clock)
  let selector =
    process.new_selector()
    |> process.select_map(runner.events, FromCall)
    |> process.select_map(runner.asks, FromActor)

  // One millisecond past the remaining window, so a window that has
  // already closed still takes exactly one receive rather than none: a
  // zero timeout would spin the phase change against a settlement already
  // sitting in the mailbox.
  let window = int.max(runner.until - now, 0) + 1
  case process.selector_receive(selector, window) {
    Ok(FromCall(broker.CallOutput(stream:, data:, total_bytes: _, truncated: _))) ->
      fold(absorb(runner, stream, data))

    Ok(FromCall(broker.CallSettled(outcome:))) -> finish(runner, outcome)

    Ok(FromActor(Tails(reply_with:))) -> {
      process.send(reply_with, runner.streams)
      fold(runner)
    }

    Error(Nil) -> expired(runner, now)
  }
}

// One chunk, into the tail a poll reads and into the file the spill is
// promoted from.
//
// A staging write that fails is dropped rather than faulting the job: the
// tail is unaffected, the helper's own byte counts still reach the
// terminal record, and a job whose disk is full is better answered with a
// missing spill ref than killed. The stream is only marked staged when a
// write actually landed, so promotion never reads a file that is not
// there.
fn absorb(
  runner: Runner,
  stream: framing.OutputStream,
  data: BitArray,
) -> Runner {
  let streams = case stream {
    framing.Stdout ->
      Streams(..runner.streams, stdout: tail.push(runner.streams.stdout, data))
    framing.Stderr ->
      Streams(..runner.streams, stderr: tail.push(runner.streams.stderr, data))
  }
  let path = staging_path(root: runner.wiring.blob_root, id: runner.id, stream:)
  let staged = case runner.wiring.spill.append(path, data) {
    Error(_unwritable) -> runner.staged
    Ok(Nil) -> remembering(runner.staged, stream)
  }
  Runner(..runner, streams:, staged:)
}

// The staged set, with this stream in it.
//
// A set of at most two, so the guard is what keeps it one: prepending on
// every successful append made the list one entry per *chunk*, which a
// `tail -f` emitting a line at a time turns into tens of thousands of
// entries over an hour — each one paid for again by the `list.contains`
// that promotion does.
fn remembering(
  staged: List(framing.OutputStream),
  stream: framing.OutputStream,
) -> List(framing.OutputStream) {
  case list.contains(staged, stream) {
    True -> staged
    False -> [stream, ..staged]
  }
}

// The wall deadline, and then the end of the grace it allows.
//
// The notice to the actor is attribution and nothing else: the broker's
// relay reached the same instant on the same number and is already
// climbing the ladder. What the notice buys is a poll during those few
// seconds reading `Draining(ByDeadline)` rather than `Running`, and the
// cause is carried in the final report as well so the record is right
// even if the two messages arrive out of order.
fn expired(runner: Runner, now: Int) -> Result(Settlement, RunnerFault) {
  case runner.phase {
    Streaming -> {
      process.send(runner.home, DeadlinePassed(id: runner.id))
      fold(
        Runner(
          ..runner,
          phase: Draining,
          until: now + settle_grace_ms,
          stopped_by: Some(jobstate.ByDeadline),
        ),
      )
    }

    // The broker promises exactly one settlement per cleared call and
    // this one outwaited the deadline, the helper's ladder and the
    // relay's own grace without producing it. Nothing further will
    // arrive, and saying so is what lets the actor record the job as
    // lost rather than leaving it live forever.
    Draining -> Error(NeverSettled)
  }
}

// The settlement, plus the promotion that turns two staging files into
// two content addresses.
//
// The promotion happens here, on the runner, rather than in the actor,
// because the runner is the process that owns the staging files and the
// actor must not read a file for every job that ends. Its result rides
// back inside the weft outcome, which is what lets the terminal fact
// carry the refs in the same commit as the terminal state.
fn finish(
  runner: Runner,
  outcome: broker.CallOutcome,
) -> Result(Settlement, RunnerFault) {
  Ok(Settlement(
    outcome:,
    stopped_by: runner.stopped_by,
    spill: promote(runner),
    streams: runner.streams,
  ))
}

fn promote(runner: Runner) -> JobSpill {
  jobstate.JobSpill(
    stdout_ref: promote_stream(runner, framing.Stdout),
    stderr_ref: promote_stream(runner, framing.Stderr),
  )
}

// One stream's staging file, read whole, written to its content address,
// and unlinked.
//
// Unlinked last and unconditionally: a staging file that outlived its job
// is bytes nothing will ever read again, and the next boot's sweep would
// have to remove it anyway. A promotion that failed at any step answers
// `None`, which the record's own doc distinguishes from "nothing to read"
// only by the helper's byte counts beside it.
fn promote_stream(
  runner: Runner,
  stream: framing.OutputStream,
) -> Option(String) {
  use <- bool.guard(when: !list.contains(runner.staged, stream), return: None)
  let path = staging_path(root: runner.wiring.blob_root, id: runner.id, stream:)
  let spill = runner.wiring.spill
  let tag = jobstate.job_id_to_string(runner.id) <> "-" <> stream_name(stream)
  let stored =
    spill.read(path) |> result.try(fn(bytes) { spill.store(tag, bytes) })
  let _removed = spill.remove(path)
  option.from_result(stored)
}

// The clearance one job asks for, built exactly the way `tools/bash`
// builds a foreground one and differing in three places, each of them the
// design's own decision.
//
// The step id is the job's own key rather than the model batch's turn, so
// each job opens its own ledger at a cap of one — `docs/adr/005`'s second
// addendum.
//
// The wall is the job's rather than `bash`'s ten-minute clamp, and the
// same number reaches the token, the relay, the helper's timer and the
// ledger because all four read this one record. That is also why
// `granted_wall` meets a *default* against the base policy before it ever
// becomes a deadline: `response` below is `RefuseNarrowed`, so a wall the
// base does not grant is refused here rather than quietly clamped.
//
// And no escalation grants are carried: the approval that admitted the
// starting call bound to that call's arguments, and a detached job has no
// later call to spend a grant on.
fn call_spec(wiring: Wiring, record: JobRecord, now: Int) -> CallSpec {
  let base_requirements =
    tool.asking_base_network(
      bash.requirements(wiring.workspace),
      wiring.base_policy,
    )
  let wall_ms = int.max(record.deadline_ms - now, 1)
  let wall_s = { wall_ms + 999 } / 1000

  // The shell asks for every root the session base already grants, the
  // workspace alone being too narrow for a linked git worktree; the meet
  // means asking for the base's own roots can never widen past it.
  //
  // The readable roots and the mounts are asked for on the same argument
  // as the writable ones, and a detached job needs them for the same
  // reason a foreground shell does (`tools/bash.call_spec`). Under
  // `protocol-change/020` the session base states which regions outside
  // the workspace a jail may reach, and `bash.requirements` names none of
  // them; mounts compose by exact path, so a job that asked for none
  // would run with no toolchain bound at all.
  let requirements =
    policy.SandboxPolicy(
      ..base_requirements,
      writable_roots: list.unique(list.append(
        base_requirements.writable_roots,
        wiring.base_policy.writable_roots,
      )),
      readable_roots: list.unique(list.append(
        base_requirements.readable_roots,
        wiring.base_policy.readable_roots,
      )),
      mounts: wiring.base_policy.mounts,
      env_allow: list.map(wiring.env, fn(pair) { pair.0 }),
      limits: policy.Limits(..base_requirements.limits, wall_s:),
    )
  broker.CallSpec(
    op_id: record.started_by,
    step_id: jobstate.job_key(record.id),
    base_policy: wiring.base_policy,
    requirements:,
    grants: [],
    response: broker.RefuseNarrowed,
    demand: wiring.demand,
    argv: record.spec.argv,
    env: wiring.env,
    cwd: record.spec.cwd,
    budget: budget.Budget(max_outstanding: 1, deadline_ms: record.deadline_ms),
  )
}

// --- what the runner reports ----------------------------------------------

// The clearance's verdict, which is also the starting caller's answer.
//
// A refusal removes the cell rather than leaving a terminal record
// behind, and the distinction is worth stating: the effect sandwich's
// `Starting` cell exists so a *crash* in the clearance window leaves
// evidence, and a refusal is not a crash. Nothing ran, nothing can have
// escaped, and a job that never existed should not hold a ceiling slot or
// appear in a listing for the rest of the session. A delete that fails
// leaves the cell `Starting` for the next boot's sweep, which is the
// honest fallback.
fn cleared(
  state: State,
  id: JobId,
  outcome: Result(Control, broker.Refusal),
) -> actor.Next(State, Message) {
  case dict.get(state.jobs, id), outcome {
    Error(Nil), _outcome -> actor.continue(state)

    // The cell goes before the caller is told, and the order is the
    // whole of what makes the refusal honest. A caller that had its
    // answer while the record was still being deleted could read the
    // store — or start its replacement job — and find a `Starting` cell
    // for a job that never ran, which is exactly the ghost the delete
    // exists to prevent.
    Ok(held), Error(refusal) -> {
      let _dropped = discard(state, id)
      answer_starter(
        held,
        Error(ClearanceRefused(reason: refusal_text(refusal))),
      )

      // The runner is about to report the refusal and then finish, and
      // deleting the cell takes its custody with it — so the channel is
      // parked before the record goes, or those two messages would have
      // nothing left to select them.
      let state = awaiting_last_word(state, id)
      resume(State(..state, jobs: dict.delete(state.jobs, id)))
    }

    Ok(held), Ok(control) -> {
      answer_starter(held, Ok(started_of(held.record)))
      accepted(state, held, control)
    }
  }
}

// A stop asked for while the clearance was still in flight leaves the
// record `Draining` and nothing to cancel. This is where that job's
// ladder finally starts: the acceptance the state machine already accepts
// as an ordinary race arrives, and the cancel goes out with it.
fn accepted(
  state: State,
  held: Held,
  control: Control,
) -> actor.Next(State, Message) {
  case held.custody, held.record.state {
    Dispatching(reports:, ..), jobstate.Draining(..) -> {
      control.cancel()
      keep(state, Held(..held, custody: Attached(reports:, control:)))
    }

    Dispatching(reports:, ..), _live ->
      commit_event(
        State(
          ..state,
          jobs: dict.insert(
            state.jobs,
            held.record.id,
            Held(..held, custody: Attached(reports:, control:)),
          ),
        ),
        held.record.id,
        jobstate.HelperAccepted,
      )

    // A second clearance for one job cannot happen: one runner is spawned
    // per admitted record and it clears once. Absorbing rather than
    // faulting keeps the actor serving every other job, and the state
    // machine would refuse the transition anyway.
    Attached(..), _state | Detached(..), _state -> actor.continue(state)
  }
}

fn keep(state: State, held: Held) -> actor.Next(State, Message) {
  resume(State(..state, jobs: dict.insert(state.jobs, held.record.id, held)))
}

// The terms a job is running under, read back off its own record.
//
// The wall is derived rather than carried because the record is the one
// place it lives: the token, the relay, the helper's timer and the ledger
// all read the same two instants, and so does the caller's answer.
fn started_of(record: JobRecord) -> Started {
  Started(
    id: record.id,
    deadline_ms: record.deadline_ms,
    wall_ms: record.deadline_ms - record.started_at_ms,
  )
}

fn answer_starter(held: Held, answer: Result(Started, Refusal)) -> Nil {
  case held.custody {
    Dispatching(reply_with:, ..) -> process.send(reply_with, answer)

    // Nobody is waiting: the clearance already answered once.
    Attached(..) | Detached(..) -> Nil
  }
}

// The deadline notice. Idempotent by construction — `Draining` absorbs a
// second stop request and keeps the first cause — so a job an owner
// killed a moment before its wall expired stays attributed to the owner.
fn deadline_passed(state: State, id: JobId) -> State {
  case dict.get(state.jobs, id) {
    Error(Nil) -> state
    Ok(held) ->
      case jobstate.is_terminal(held.record.state) {
        True -> state
        False ->
          apply(state, held, jobstate.KillRequested(by: jobstate.ByDeadline))
      }
  }
}

// The drain proof, and the only place a terminal state is written.
//
// Seven `weft.Outcome` variants and four `Pulled` shapes are all written
// out, because that is what makes the account checkable. They collapse
// into three answers: a settlement the helper reported, a refusal that
// left nothing running, and every way of losing custody without either.
fn reported(
  state: State,
  id: JobId,
  pulled: weft.Pulled(Settlement, RunnerFault),
) -> actor.Next(State, Message) {
  case pulled {
    // Taking the outcome ends the custody, so the channel it arrived on
    // moves to `last_words` in the same step — otherwise the
    // `AllDelivered` behind it would have nothing left to select it.
    weft.PulledOutcome(outcome:) ->
      settle(awaiting_last_word(state, id), id, outcome)

    // The relay's own end of the conversation. It says nothing about the
    // job — the outcome, if there was one, already arrived — and this is
    // the one place a report channel is dropped.
    weft.AllDelivered -> resume(said_last_word(state, id))

    // The answer to a demand the relay has not yet been able to fill.
    // Nothing has ended, so nothing is dropped.
    weft.NotYet -> actor.continue(state)

    // The scope died without delivering. Whatever the runner was doing,
    // nobody can now say what became of the job, and the relay that would
    // have said `AllDelivered` is gone with it.
    weft.RunLost(reason: _) ->
      lost(said_last_word(state, id), id, jobstate.HelperLoss)
  }
}

// A finished runner's report channel, moved out of its custody and into
// the last words still owed.
//
// Called before the outcome is acted on, because acting on it is what
// detaches the custody — and in the refusal path, where the record is
// deleted outright, this ledger is the only thing left holding the
// channel. A job with no custody to take one from is left alone: it is
// either already here or was never a runner's.
fn awaiting_last_word(state: State, id: JobId) -> State {
  case dict.get(state.jobs, id) {
    Error(Nil) -> state
    Ok(held) ->
      case held.custody {
        Detached(..) -> state
        Dispatching(reports:, ..) | Attached(reports:, ..) ->
          State(..state, last_words: dict.insert(state.last_words, id, reports))
      }
  }
}

fn said_last_word(state: State, id: JobId) -> State {
  State(..state, last_words: dict.delete(state.last_words, id))
}

fn settle(
  state: State,
  id: JobId,
  outcome: weft.Outcome(Settlement, RunnerFault),
) -> actor.Next(State, Message) {
  case outcome {
    weft.Completed(value: settlement, ..) -> settled(state, id, settlement)

    // The clearance refused, and the starting caller has already been
    // told in the broker's own words. The record went with it.
    weft.Failed(error: Refused(..), ..) -> actor.continue(state)

    weft.Failed(error: NeverSettled, ..) -> lost(state, id, jobstate.HelperLoss)

    weft.Crashed(..) -> lost(state, id, jobstate.HelperLoss)

    // The run's backstop deadline fired, or something cancelled the
    // scope. The worker died holding the events subject, so the broker's
    // relay has already cancelled the execution — but nobody observed its
    // end, which is exactly what `Lost` says and `Killed` would not.
    weft.Abandoned(..) -> lost(state, id, jobstate.HelperLoss)

    weft.NeverStarted(..) -> lost(state, id, jobstate.HelperLoss)

    // Neither is producible by a plain task; the arms exist so that a run
    // which later grows an owner fails exhaustiveness here rather than
    // disappearing into a catch-all.
    weft.DrainProofLost(..) -> lost(state, id, jobstate.HelperLoss)

    weft.CancellationUnconfirmed(..) -> lost(state, id, jobstate.HelperLoss)
  }
}

fn settled(
  state: State,
  id: JobId,
  settlement: Settlement,
) -> actor.Next(State, Message) {
  resume(record_settlement(state, id, settlement))
}

// The settlement, attributed and committed. One function, because the
// ordinary path and the session-stop drain must write the same record for
// the same report; only the way they were reached differs.
//
// Attribution comes first, so a job the helper reports as cancelled ends
// as `Killed(by:)` rather than as an ordinary exit. The cause the runner
// observed wins; a record already `Draining` keeps the cause that put it
// there; and an exit reporting `cancelled` under neither is the
// operation's own abort having reached the helper.
fn record_settlement(state: State, id: JobId, settlement: Settlement) -> State {
  case dict.get(state.jobs, id) {
    Error(Nil) -> state
    Ok(held) -> {
      let state = case attribution(held.record.state, settlement) {
        None -> state
        Some(cause) -> apply(state, held, jobstate.KillRequested(by: cause))
      }

      // A settlement that overtook the clearance — two senders, and
      // nothing orders them — leaves a starter waiting on a job that has
      // in fact run and finished. It is told so here, because detaching
      // is what takes its reply subject away.
      answer_starter(held, Ok(started_of(held.record)))
      let state = detach(state, id, Detached(streams: settlement.streams))
      case settlement.outcome {
        broker.CallExited(result:) ->
          commit(
            state,
            id,
            jobstate.ExitReported(result:),
            Some(settlement.spill),
          )

        // A settled failure carries no helper report at all, so there is
        // no `ExecResult` to record and nothing was witnessed ending.
        broker.CallFailed(failure: _) ->
          commit(
            state,
            id,
            jobstate.RunnerLost(reason: jobstate.HelperLoss),
            Some(settlement.spill),
          )
      }
    }
  }
}

fn detach(state: State, id: JobId, custody: Custody) -> State {
  case dict.get(state.jobs, id) {
    Error(Nil) -> state
    Ok(held) ->
      State(..state, jobs: dict.insert(state.jobs, id, Held(..held, custody:)))
  }
}

// Who stopped a job, when the settlement is the first thing to say it was
// stopped at all.
fn attribution(state: JobState, settlement: Settlement) -> Option(KillCause) {
  case settlement.stopped_by, state, settlement.outcome {
    // The runner watched its own deadline pass, which is the one cause a
    // record can be missing when the settlement lands.
    Some(cause), _state, _outcome -> Some(cause)

    // Somebody already asked, and the first asker is the one a reader of
    // the terminal state needs named.
    None, jobstate.Draining(..), _outcome -> None

    // The helper says it climbed the ladder and nothing here asked it
    // to, so `broker.abort` of the operation that started this job
    // reached it. That is the abort semantics the operation binding buys
    // and the only remaining explanation.
    None, _state, broker.CallExited(result:) ->
      case result.cancelled {
        True -> Some(jobstate.ByOperationAbort)
        False -> None
      }

    // A failure carries no helper report, so there is nothing to
    // attribute; the record becomes `Lost` rather than `Killed`.
    None, _state, broker.CallFailed(failure: _) -> None
  }
}

fn lost(
  state: State,
  id: JobId,
  reason: jobstate.LossReason,
) -> actor.Next(State, Message) {
  resume(record_loss(state, id, reason))
}

fn record_loss(state: State, id: JobId, reason: jobstate.LossReason) -> State {
  case dict.get(state.jobs, id) {
    Error(Nil) -> state
    Ok(held) -> {
      // The starter, if the clearance never returned to answer it. A
      // runner that died inside `run` — before it could send `Clearance`
      // either way — reaches this actor only as a weft outcome, and
      // nothing else is left that knows a caller is waiting. Without this
      // that caller sits out its whole budget and is told the actor did
      // not answer in time, which is both slow and untrue.
      answer_starter(
        held,
        Error(Unavailable(
          reason: "the runner died before the clearance answered",
        )),
      )
      let state = detach(state, id, detached_of(held.custody))
      commit(state, id, jobstate.RunnerLost(reason:), None)
    }
  }
}

// A job whose runner is gone keeps whatever tails were last handed over,
// and a job that never got that far keeps two empty ones. Either way the
// custody says there is nothing left to ask.
fn detached_of(custody: Custody) -> Custody {
  case custody {
    Detached(streams:) -> Detached(streams:)
    Dispatching(..) | Attached(..) -> Detached(streams: no_streams())
  }
}

// Two empty tails: what a job whose runner never published any has to
// show, and what a poll of it therefore reads.
fn no_streams() -> Streams {
  Streams(
    stdout: tail.new(capacity: tail_bytes),
    stderr: tail.new(capacity: tail_bytes),
  )
}

// --- transitions and commits ----------------------------------------------

// One event applied in memory only. Used where a durable write would be
// wasted because a second event is about to land in the same handler.
fn apply(state: State, held: Held, event: jobstate.JobEvent) -> State {
  case jobstate.step(held.record, event) {
    Error(_illegal) -> state
    Ok(record) ->
      State(
        ..state,
        jobs: dict.insert(state.jobs, record.id, Held(..held, record:)),
      )
  }
}

// One event applied and committed, with the spill written in the same
// commit as the state it belongs to.
//
// An illegal transition is dropped rather than faulting the actor: the
// machine's two refusals both mean a caller's model of the job disagrees
// with the record's, and every path into this function has already
// checked the one thing it can — that the record is not terminal — so a
// refusal here is a race that resolved the other way.
fn commit(
  state: State,
  id: JobId,
  event: jobstate.JobEvent,
  spill: Option(JobSpill),
) -> State {
  case dict.get(state.jobs, id) {
    Error(Nil) -> state
    Ok(held) ->
      case jobstate.step(held.record, event) {
        Error(_illegal) -> state
        Ok(stepped) -> {
          let record = case spill {
            None -> stepped
            Some(spill) -> jobstate.JobRecord(..stepped, spill:)
          }
          let _written = persist(state, record)
          State(
            ..state,
            jobs: dict.insert(state.jobs, id, Held(..held, record:)),
          )
        }
      }
  }
}

fn commit_event(
  state: State,
  id: JobId,
  event: jobstate.JobEvent,
) -> actor.Next(State, Message) {
  resume(commit(state, id, event, None))
}

// The cell, overwritten.
//
// Blind rather than a compare-and-set, and that is safe for one reason
// worth naming: this actor is the only writer of a `job/<id>` cell after
// admission claimed it, the key is reserved so no model-supplied `put_fact`
// can name it, and every write here is made from the actor's own single
// thread of control. What a CAS would defend against is a second writer,
// and there is not one.
fn persist(state: State, record: JobRecord) -> Result(Nil, Refusal) {
  use runtime <- result.try(borrow(state))
  api.put_reserved_fact(
    runtime,
    jobstate.job_key(record.id),
    jobstate.encode(record),
  )
  |> result.map_error(commit_refused)
}

fn discard(state: State, id: JobId) -> Result(Nil, Refusal) {
  use runtime <- result.try(borrow(state))
  api.delete_reserved_fact(runtime, jobstate.job_key(id))
  |> result.map_error(commit_refused)
}

// --- polling, listing, killing, writing -----------------------------------

// A job the asking strand does not own is `NotFound`, and so is one that
// does not exist. See the refusal's own doc for why the two are one
// answer.
fn owned(state: State, strand: String, id: JobId) -> Result(Held, Refusal) {
  case dict.get(state.jobs, id) {
    Error(Nil) -> Error(NotFound(id: jobstate.job_id_to_string(id)))
    Ok(held) ->
      case held.record.owner == strand {
        True -> Ok(held)
        False -> Error(NotFound(id: jobstate.job_id_to_string(id)))
      }
  }
}

fn polled(
  state: State,
  strand: String,
  id: JobId,
  cursors: Cursors,
) -> Result(Polled, Refusal) {
  use held <- result.try(owned(state, strand, id))
  let streams = streams_of(held.custody)
  let #(now, _clock) = clock.read(state.wiring.clock)
  Ok(Polled(
    id:,
    state: held.record.state,
    age_ms: now - held.record.started_at_ms,
    deadline_ms: held.record.deadline_ms,
    stdout: tail.since(streams.stdout, cursors.stdout),
    stderr: tail.since(streams.stderr, cursors.stderr),
    spill: held.record.spill,
  ))
}

// A live job's output lives in its runner, so reading it is a question
// asked of another process.
//
// The ask is monitored and bounded rather than a bare send-and-wait: a
// runner that died between the last message and this one would otherwise
// hold the actor for the whole timeout and then answer nothing, and every
// other job's poll would wait behind it. A runner that cannot answer is
// reported as having printed nothing since the cursor, which is true of
// what this actor knows.
fn streams_of(custody: Custody) -> Streams {
  case custody {
    Detached(streams:) -> streams

    Dispatching(..) -> no_streams()

    Attached(control:, ..) ->
      case ask_runner(control) {
        Ok(streams) -> streams
        Error(Nil) -> no_streams()
      }
  }
}

fn ask_runner(control: Control) -> Result(Streams, Nil) {
  use runner <- result.try(process.subject_owner(control.asks))
  let reply = process.new_subject()
  let monitor = process.monitor(runner)
  let selector =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_down) { Error(Nil) })
  process.send(control.asks, Tails(reply_with: reply))
  let answer =
    process.selector_receive(selector, runner_ask_ms)
    |> result.unwrap(Error(Nil))
  process.demonitor_process(monitor)
  answer
}

// Only admitted live records become rows. The fold visits the actor's existing
// dictionary but holds at most four records; it never queries durable history.
fn live_board(
  records: Dict(JobId, Held),
  strand: String,
  now: Int,
) -> JsonValue {
  let #(total, rows) =
    dict.fold(records, #(0, []), fn(acc, _id, held) {
      case
        held.record.owner == strand && !jobstate.is_terminal(held.record.state)
      {
        False -> acc
        True -> {
          let rows = case acc.0 < max_jobs_per_strand {
            True -> [live_row(held.record, now), ..acc.1]
            False -> acc.1
          }
          #(acc.0 + 1, rows)
        }
      }
    })
  json.Object([
    #("strand", json.String(strand)),
    #("observed_at_ms", json.Int(now)),
    #("jobs", json.Array(list.reverse(rows))),
    #("total", json.Int(total)),
    #("omitted", json.Int(int.max(total - max_jobs_per_strand, 0))),
  ])
}

fn live_row(record: JobRecord, now: Int) -> JsonValue {
  let phase = case record.state {
    jobstate.Starting -> "starting"
    jobstate.Running -> "running"
    jobstate.Draining(..) -> "draining"
    jobstate.Exited(..) | jobstate.Killed(..) | jobstate.Lost(..) -> "terminal"
  }
  json.Object([
    #("id", json.String(jobstate.job_id_to_string(record.id))),
    #("state", json.String(phase)),
    #("started_by", json.String(ids.op_id_to_string(record.started_by))),
    #("command_excerpt", json.String(command_excerpt(record.spec.argv))),
    #("age_ms", json.Int(int.max(now - record.started_at_ms, 0))),
    #("deadline_ms", json.Int(record.deadline_ms)),
  ])
}

// Stop before joining an arbitrarily large argv. Each grapheme is admitted
// only while its bytes fit, so terminal display gets a UTF-8-safe prefix.
fn command_excerpt(argv: List(String)) -> String {
  argv
  |> list.fold_until(#(512, []), fn(acc, arg) {
    case acc.0 <= 0 {
      True -> list.Stop(acc)
      False -> {
        let text = string.slice(arg, 0, acc.0)
        let #(remaining, parts) =
          string.to_graphemes(text)
          |> list.fold_until(acc, fn(acc, grapheme) {
            case string.byte_size(grapheme) <= acc.0 {
              True ->
                list.Continue(
                  #(acc.0 - string.byte_size(grapheme), [grapheme, ..acc.1]),
                )
              False -> list.Stop(#(0, acc.1))
            }
          })
        case remaining > 0 {
          True -> list.Continue(#(remaining - 1, [" ", ..parts]))
          False -> list.Stop(#(remaining, parts))
        }
      }
    }
  })
  |> fn(acc) { acc.1 }
  |> list.reverse
  |> string.concat
  |> string.trim_end
}

fn listing(state: State, strand: String) -> List(Listed) {
  let #(now, _clock) = clock.read(state.wiring.clock)
  dict.values(state.jobs)
  |> list.filter(fn(held) { held.record.owner == strand })
  |> list.map(fn(held) {
    Listed(
      id: held.record.id,
      state: held.record.state,
      age_ms: now - held.record.started_at_ms,
      deadline_ms: held.record.deadline_ms,
    )
  })
}

// The cancel ladder, asked for and recorded.
//
// The cancel goes out before the state is written, because the write is
// the slow half and a model that asked twice must not have the second ask
// answered from a record the first one had not finished committing. Both
// are idempotent — the broker's cancel by contract, the machine's
// `Draining` by construction — so the order costs nothing and buys the
// ladder a head start.
fn requested_kill(
  state: State,
  strand: String,
  id: JobId,
  reply_with: Subject(Result(Nil, Refusal)),
) -> actor.Next(State, Message) {
  case owned(state, strand, id) {
    Error(refusal) -> {
      process.send(reply_with, Error(refusal))
      actor.continue(state)
    }
    Ok(held) ->
      case jobstate.is_terminal(held.record.state) {
        // Stopping something that has already stopped is what the caller
        // wanted, so it is an answer rather than a refusal.
        True -> {
          process.send(reply_with, Ok(Nil))
          actor.continue(state)
        }
        False -> {
          cancel(held.custody)
          process.send(reply_with, Ok(Nil))
          commit_event(state, id, jobstate.KillRequested(by: jobstate.ByOwner))
        }
      }
  }
}

fn cancel(custody: Custody) -> Nil {
  case custody {
    Attached(control:, ..) -> control.cancel()

    // Nothing has been cleared yet, so there is nothing to cancel. The
    // record is `Draining` from here, and the runner's own acceptance
    // report is where the ladder actually starts.
    Dispatching(..) | Detached(..) -> Nil
  }
}

fn write_to_stdin(
  state: State,
  strand: String,
  id: JobId,
  data: BitArray,
  end: StdinEnd,
) -> Result(Nil, Refusal) {
  use held <- result.try(owned(state, strand, id))
  case held.custody {
    Attached(control:, ..) -> {
      control.stdin(data, closes(end))
      Ok(Nil)
    }

    Dispatching(..) ->
      Error(Invalid(reason: "this job has not started running yet"))

    Detached(..) -> Error(Invalid(reason: "this job has finished"))
  }
}

// The broker's `stdin` takes the wire's own boolean, so the polarity is
// converted here and nowhere else.
fn closes(end: StdinEnd) -> Bool {
  case end {
    CloseStdin -> True
    KeepStdinOpen -> False
  }
}

// --- the restart sweep ----------------------------------------------------

// Every job the store still calls live, declared lost, and every staging
// file removed.
//
// A job's process is a child of a helper, the helper is a child of the
// daemon VM, and nothing in this design survives the VM — so recovery
// never re-adopts. This runs before the first request is served, which is
// what stops a poll ever seeing a record this incarnation was about to
// declare lost.
//
// A cell that will not decode is left exactly as it is. Rewriting one
// would mean guessing at a job's owner and state, and both guesses are
// harmful in the same direction the codec's own doc names: nothing here
// invents a record it could not read.
//
// What the sweep reads it also *keeps*. A record declared lost that stayed
// only in the store would answer a poll `NotFound` — the sentence reserved
// for "there is no such job, or it is somebody else's" — and would be
// missing from a listing, so the model whose job the restart killed would
// be told the job never existed rather than that it was lost. Every record
// the sweep decoded is therefore held detached, with two empty tails,
// which is exactly what a job whose runner is gone has left to show.
fn reap(state: State) -> State {
  case state.wiring.runtime() {
    Error(Nil) -> state
    Ok(runtime) -> {
      let swept = sweep(runtime) |> result.unwrap([])

      // This incarnation owns no job, so every staging file the store
      // holds belongs to one that is gone.
      let _unlinked = unlink_orphans(state)
      State(..state, jobs: list.fold(swept, state.jobs, remember))
    }
  }
}

// One swept record, held as a job with nothing left to ask.
//
// Every one of these is terminal — the sweep either found it so or made it
// so — which is what keeps them out of `room_for_one_more`'s count and
// makes them answerable from `state.jobs` alone.
fn remember(jobs: Dict(JobId, Held), record: JobRecord) -> Dict(JobId, Held) {
  dict.insert(
    jobs,
    record.id,
    Held(record:, custody: Detached(streams: no_streams())),
  )
}

// Every job the store still holds a record for, as this incarnation now
// believes it stands: the ones already terminal unchanged, and the ones
// still live declared lost and written back.
//
// A record whose `Lost` could not be written is dropped rather than kept,
// because holding it would answer a poll with a state the store does not
// carry — and the next boot's sweep will meet the same cell and try again.
fn sweep(runtime: Runtime) -> Result(List(JobRecord), Refusal) {
  use cells <- result.try(
    api.reserved_facts(runtime, prefix: jobstate.key_prefix)
    |> result.map_error(commit_refused),
  )
  Ok(
    list.filter_map(cells, fn(cell) {
      let #(_key, payload) = cell
      case jobstate.decode(payload) {
        Error(_corrupt) -> Error(Nil)
        Ok(record) ->
          case jobstate.is_terminal(record.state) {
            True -> Ok(record)
            False -> reap_one(runtime, record)
          }
      }
    }),
  )
}

fn reap_one(runtime: Runtime, record: JobRecord) -> Result(JobRecord, Nil) {
  use lost <- result.try(
    jobstate.step(record, jobstate.RunnerLost(reason: jobstate.VmRestart))
    |> result.replace_error(Nil),
  )
  api.put_reserved_fact(
    runtime,
    jobstate.job_key(lost.id),
    jobstate.encode(lost),
  )
  |> result.replace(lost)
  |> result.replace_error(Nil)
}

fn unlink_orphans(state: State) -> Result(Nil, String) {
  use paths <- result.try(state.wiring.spill.staged())
  list.each(paths, fn(path) {
    let _removed = state.wiring.spill.remove(path)
    Nil
  })
  Ok(Nil)
}

// --- session stop ---------------------------------------------------------

// Every live job cancelled, then a bounded wait for the ladder.
//
// There is one way in and it is `on_shutdown`: the supervisor's `shutdown`
// exit reaches an actor that traps exits, weft runs this before the
// process goes, and the ordered `Part` teardown puts `Services` ahead of
// `Broker` and `Helpers` — so the cancels sent here still have a broker to
// travel through and helpers to reach. There is deliberately no message
// asking for the same thing: a second door onto teardown would be a second
// thing to keep true, and nothing outside the supervisor has cause to
// stop this actor's jobs without stopping the actor.
//
// The wait happens inside this handler, receiving on the very subjects the
// actor's own selector carries, because there is no way to process the
// mailbox from inside a handler and no reason to want one: nothing else
// this actor could do while shutting down is worth serving. A job that has
// not settled when the grace runs out keeps its durable
// `Draining(BySessionStop)`, and the next boot's sweep turns that into
// `Lost(VmRestart)` — which is the truth, because nobody watched it end.
fn stop_every_job(state: State) -> State {
  let state =
    dict.fold(state.jobs, state, fn(carried, id, held) {
      case jobstate.is_terminal(held.record.state) {
        True -> carried
        False -> {
          cancel(held.custody)
          commit(
            carried,
            id,
            jobstate.KillRequested(by: jobstate.BySessionStop),
            None,
          )
        }
      }
    })
  let #(now, _clock) = clock.read(state.wiring.clock)
  drain(state, now + stop_grace_ms)
}

fn drain(state: State, until: Int) -> State {
  use <- bool.guard(when: !any_live(state), return: state)
  let #(now, _clock) = clock.read(state.wiring.clock)
  let window = until - now
  use <- bool.guard(when: window <= 0, return: state)
  case process.selector_receive(selector(state), window) {
    Error(Nil) -> state

    // Only a settlement moves the drain along; everything else in the
    // mailbox belongs to a session that is closing and is dropped with
    // it, which is what the supervisor's shutdown means.
    Ok(Reported(id:, pulled:)) -> drain(drained(state, id, pulled), until)

    Ok(Clearance(id:, outcome:)) ->
      drain(drained_clearance(state, id, outcome), until)

    Ok(Start(reply_with:, ..)) -> {
      process.send(
        reply_with,
        Error(Unavailable(reason: "this session is stopping")),
      )
      drain(state, until)
    }

    Ok(Reap)
    | Ok(PollOne(..))
    | Ok(ListAll(..))
    | Ok(LiveJobs(..))
    | Ok(Kill(..))
    | Ok(Write(..))
    | Ok(DeadlinePassed(..)) -> drain(state, until)
  }
}

fn any_live(state: State) -> Bool {
  dict.values(state.jobs)
  |> list.any(fn(held) { !jobstate.is_terminal(held.record.state) })
}

// A settlement during the drain, applied for its durable effect only:
// `actor.Next` cannot be built here, so the two report handlers are
// re-entered for their state and their commits.
fn drained(
  state: State,
  id: JobId,
  pulled: weft.Pulled(Settlement, RunnerFault),
) -> State {
  case pulled {
    weft.PulledOutcome(outcome: weft.Completed(value: settlement, ..)) ->
      record_settlement(awaiting_last_word(state, id), id, settlement)

    weft.PulledOutcome(..) ->
      record_loss(awaiting_last_word(state, id), id, jobstate.HelperLoss)

    // The relay's last word, which arrives behind the outcome the drain
    // has already recorded. Nothing about the job, so nothing is written:
    // it only stops the drain selecting on a channel that is finished.
    weft.AllDelivered -> said_last_word(state, id)

    weft.RunLost(..) ->
      record_loss(said_last_word(state, id), id, jobstate.HelperLoss)

    // The relay never pushes this — it pulls with no timeout — but the
    // arm is written so a change to that pulling fails exhaustiveness
    // here rather than declaring a live job lost.
    weft.NotYet -> state
  }
}

// A clearance that returned while the session was stopping. The job was
// already asked to stop, so the controls are taken only to cancel with
// them.
fn drained_clearance(
  state: State,
  id: JobId,
  outcome: Result(Control, broker.Refusal),
) -> State {
  case dict.get(state.jobs, id), outcome {
    Error(Nil), _outcome -> state

    Ok(held), Error(_refusal) -> {
      answer_starter(
        held,
        Error(Unavailable(reason: "this session is stopping")),
      )
      let _dropped = discard(state, id)
      State(..state, jobs: dict.delete(state.jobs, id))
    }

    Ok(held), Ok(control) -> {
      answer_starter(
        held,
        Error(Unavailable(reason: "this session is stopping")),
      )
      control.cancel()
      case held.custody {
        Dispatching(reports:, ..) ->
          State(
            ..state,
            jobs: dict.insert(
              state.jobs,
              id,
              Held(..held, custody: Attached(reports:, control:)),
            ),
          )
        Attached(..) | Detached(..) -> state
      }
    }
  }
}

// --- rendering ------------------------------------------------------------

// A broker refusal in the words a model reads. The refusals a job can
// meet are exactly the ones a foreground `bash` can, so the wording is
// `tools/tool.refusal_outcome`'s vocabulary rather than a second account
// of the same failures.
fn refusal_text(refusal: broker.Refusal) -> String {
  case refusal {
    broker.PolicyRefused(denial:) ->
      "sandbox policy refused the job: " <> denial.reason
    broker.InvalidPolicy(error:) ->
      "sandbox policy invalid: " <> string.inspect(error)
    broker.BudgetRefused(refusal:) ->
      "execution budget refused the job: " <> string.inspect(refusal)
    broker.MintRefused(error: _) ->
      "the broker could not mint a capability token"
    broker.NoHelper(error:) ->
      "no sandbox helper available: " <> string.inspect(error)
    broker.OperationAborted ->
      "the operation that asked for this job was aborted"
    broker.BrokerUnavailable -> "the broker did not answer"
  }
}
