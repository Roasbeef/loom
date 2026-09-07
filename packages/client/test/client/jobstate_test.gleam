//// The background job state machine and its durable codec, tested the
//// way a pure machine can be: enumerated rather than supervised.
////
//// Three kinds of test, and the split is deliberate. The **table** names
//// every `(state, event)` pair the machine can be asked about and writes
//// the answer down, so changing the relation shows up as a diff in a
//// table rather than as a green run. The **properties** fold seeded
//// random event scripts and assert the five things that must hold of
//// every run — identity is immutable, terminal is absorbing, an exit
//// report always terminates, an `Exited` really did end of its own
//// accord, the first stop's cause survives — because a table is only as
//// exhaustive as its author and a fold reaches orders the author did not
//// think of. The **codec** tests round-trip generated
//// records and then feed the decoder a catalogue of malformed payloads,
//// each of which must come back as a corruption report rather than a
//// crash or a half-read record.
////
//// Randomness follows core's seeded-generator pattern (a SplitMix-style
//// draw threaded explicitly), so a failing case reproduces from its seed.

import broker/exec.{type ExecResult, ExecResult}
import client/jobstate.{
  type JobEvent, type JobRecord, type JobState, AlreadyTerminal, ByDeadline,
  ByOperationAbort, ByOwner, BySessionStop, Draining, ExitReported, Exited,
  HelperAccepted, HelperLoss, JobRecord, JobSpec, KillRequested, Killed, Lost,
  OwnerRestart, RunnerLost, Running, Starting, VmRestart,
}
import core/clock
import core/ids
import core/json
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string

// --- fixtures -------------------------------------------------------------

// One `ExecResult` standing for "the helper reported an end". The table
// tests never look inside it; the codec tests generate varied ones.
fn settled() -> ExecResult {
  ExecResult(
    code: 0,
    signal: 0,
    stdout_bytes: 12,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: ["landlock", "seccomp"],
    degraded: False,
    wall_ms: 40,
    timed_out: False,
    cancelled: False,
  )
}

// The same report with the helper's own witness that it climbed the
// ladder, and with its wall timer having fired first. Both are ends the
// actor never asked for, which is what the attribution arms read: a
// timed-out run is cancelled too, because the helper's timer stops the
// payload the same way a cancel does.
fn cancelled() -> ExecResult {
  ExecResult(..settled(), cancelled: True)
}

fn timed_out() -> ExecResult {
  ExecResult(..settled(), timed_out: True, cancelled: True)
}

// The ref a runner would have sealed for a finished job's output. Nothing
// here resolves it: this module names the ref and the blob store owns it.
fn a_ref() -> String {
  "sha256-9c1f2ad4"
}

// The same record with a ref sealed for one stream and nothing for the
// other, which is the asymmetric shape the stored form has to carry: a
// job that printed to stdout and nothing to stderr.
fn spilled(job: JobRecord) -> JobRecord {
  JobRecord(
    ..job,
    spill: jobstate.JobSpill(stdout_ref: Some(a_ref()), stderr_ref: None),
  )
}

fn an_op() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: 1000), seed: 9)
  let #(id, _generator) = ids.mint_op(generator)
  id
}

// A record in the given state, with every identity field fixed. Every
// test that asserts "only the state moved" compares against this shape.
fn record(state: JobState) -> JobRecord {
  let assert Ok(id) = jobstate.parse_job_id("01JQ8XZ") as "a legal job id"
  JobRecord(
    id:,
    owner: "main",
    started_by: an_op(),
    spec: JobSpec(
      argv: ["bash", "-lc", "tail -f build.log"],
      cwd: "/workspace",
      requested_wall_ms: 1_800_000,
    ),
    started_at_ms: 1000,
    deadline_ms: 601_000,
    state:,
    spill: jobstate.no_spill(),
  )
}

fn causes() -> List(jobstate.KillCause) {
  [ByOwner, ByDeadline, BySessionStop, ByOperationAbort]
}

fn reasons() -> List(jobstate.LossReason) {
  [VmRestart, OwnerRestart, HelperLoss]
}

// --- the key namespace ----------------------------------------------------

// The id is opaque because the key shape depends on it: `job/<id>` has
// exactly two segments, and an id carrying a separator would make a
// prefix aimed at one job reach another's subtree.
pub fn a_job_id_may_not_carry_a_separator_test() {
  assert jobstate.parse_job_id("") == Error(Nil)
  assert jobstate.parse_job_id("build/1") == Error(Nil)
  assert jobstate.parse_job_id("/") == Error(Nil)

  let assert Ok(id) = jobstate.parse_job_id("01JQ8XZ") as "a legal id"
  assert jobstate.job_id_to_string(id) == "01JQ8XZ"
}

// `job_id_of_key` is the total inverse of `job_key`, which is what lets a
// prefix scan recover an id without a second account of the key's shape.
pub fn a_job_key_round_trips_through_its_id_test() {
  let assert Ok(id) = jobstate.parse_job_id("01JQ8XZ") as "a legal id"
  assert jobstate.job_key(id) == "job/01JQ8XZ"
  assert jobstate.job_id_of_key(jobstate.job_key(id)) == Ok(id)
  assert jobstate.key_prefix == "job/"
}

// A key outside the namespace, and a key inside it whose tail could not
// have been minted, are both refused — the second is the one that matters,
// since a stored `job/a/b` would decode into an id that no longer names
// its own cell.
pub fn a_key_outside_the_namespace_is_not_a_job_test() {
  assert jobstate.job_id_of_key("agent/main/note") == Error(Nil)
  assert jobstate.job_id_of_key("jobs/1") == Error(Nil)
  assert jobstate.job_id_of_key("job/") == Error(Nil)
  assert jobstate.job_id_of_key("job/a/b") == Error(Nil)
}

// --- the transition table -------------------------------------------------

// Every `(state, event)` pair at the shape level, with its answer written
// down rather than computed. Twenty-four of the rows are the shape — six
// states against four events — and five more are the attribution arms,
// because an exit report against a live state has three answers rather
// than one and the difference between them is who a poll names. The
// causes and reasons are otherwise exercised separately below, because
// multiplying them into this table would hide the shape it exists to show.
pub fn the_transition_table_is_exhaustive_test() {
  let result = settled()
  let rows = [
    // `Starting` accepts everything. The two that skip `Running` are the
    // interesting ones: a stop asked for before the helper accepted still
    // drains, because the clearance has already happened; and an exit
    // report is taken as ground truth, because refusing it would leave a
    // `Starting` cell behind for a process that is gone.
    #(Starting, HelperAccepted, Ok(Running)),
    #(Starting, KillRequested(by: ByDeadline), Ok(Draining(by: ByDeadline))),
    #(Starting, ExitReported(result:), Ok(Exited(result:))),
    // An end the actor never asked for is attributed from the report,
    // because the report is the only witness there is: the helper's wall
    // timer can fire before the actor's, and `broker.abort` cancels the
    // helper with no hook the actor could have heard first.
    #(
      Starting,
      ExitReported(result: cancelled()),
      Ok(Killed(by: ByOperationAbort, result: cancelled())),
    ),
    #(
      Starting,
      ExitReported(result: timed_out()),
      Ok(Killed(by: ByDeadline, result: timed_out())),
    ),
    #(Starting, RunnerLost(reason: HelperLoss), Ok(Lost(reason: HelperLoss))),
    // `Running` holds the one illegal live pair. A second acceptance is
    // not a race — the runner sends it once, on the relay's own channel —
    // so it means one job dispatched two runs.
    #(Running, HelperAccepted, Error(jobstate.AcceptedTwice(state: Running))),
    #(Running, KillRequested(by: ByDeadline), Ok(Draining(by: ByDeadline))),
    #(Running, ExitReported(result:), Ok(Exited(result:))),
    #(
      Running,
      ExitReported(result: cancelled()),
      Ok(Killed(by: ByOperationAbort, result: cancelled())),
    ),
    #(
      Running,
      ExitReported(result: timed_out()),
      Ok(Killed(by: ByDeadline, result: timed_out())),
    ),
    #(Running, RunnerLost(reason: HelperLoss), Ok(Lost(reason: HelperLoss))),
    // `Draining` absorbs both of the events that would be surprising
    // elsewhere, and the first stop's cause is the one that survives: an
    // acceptance in flight when the kill landed changes nothing, and a
    // second stop request must not let a later party overwrite who asked.
    #(Draining(by: ByOwner), HelperAccepted, Ok(Draining(by: ByOwner))),
    #(
      Draining(by: ByOwner),
      KillRequested(by: ByDeadline),
      Ok(Draining(by: ByOwner)),
    ),
    #(
      Draining(by: ByOwner),
      ExitReported(result:),
      Ok(Killed(by: ByOwner, result:)),
    ),
    // The deduction is for a job nobody told the actor about. A draining
    // job was told, so the cause the stop named wins over the one the
    // report would suggest — an owner's `job_kill` is not relabelled an
    // abort because the helper cancelled the payload on its way out.
    #(
      Draining(by: ByOwner),
      ExitReported(result: cancelled()),
      Ok(Killed(by: ByOwner, result: cancelled())),
    ),
    #(
      Draining(by: ByOwner),
      RunnerLost(reason: HelperLoss),
      Ok(Lost(reason: HelperLoss)),
    ),
    // The three terminal states refuse everything, including a second
    // copy of the event that made them terminal.
    #(
      Exited(result:),
      HelperAccepted,
      Error(AlreadyTerminal(state: Exited(result:), event: HelperAccepted)),
    ),
    #(
      Exited(result:),
      KillRequested(by: ByOwner),
      Error(AlreadyTerminal(
        state: Exited(result:),
        event: KillRequested(by: ByOwner),
      )),
    ),
    #(
      Exited(result:),
      ExitReported(result:),
      Error(AlreadyTerminal(
        state: Exited(result:),
        event: ExitReported(result:),
      )),
    ),
    #(
      Exited(result:),
      RunnerLost(reason: VmRestart),
      Error(AlreadyTerminal(
        state: Exited(result:),
        event: RunnerLost(reason: VmRestart),
      )),
    ),
    #(
      Killed(by: ByOwner, result:),
      HelperAccepted,
      Error(AlreadyTerminal(
        state: Killed(by: ByOwner, result:),
        event: HelperAccepted,
      )),
    ),
    #(
      Killed(by: ByOwner, result:),
      KillRequested(by: ByOwner),
      Error(AlreadyTerminal(
        state: Killed(by: ByOwner, result:),
        event: KillRequested(by: ByOwner),
      )),
    ),
    #(
      Killed(by: ByOwner, result:),
      ExitReported(result:),
      Error(AlreadyTerminal(
        state: Killed(by: ByOwner, result:),
        event: ExitReported(result:),
      )),
    ),
    #(
      Killed(by: ByOwner, result:),
      RunnerLost(reason: VmRestart),
      Error(AlreadyTerminal(
        state: Killed(by: ByOwner, result:),
        event: RunnerLost(reason: VmRestart),
      )),
    ),
    #(
      Lost(reason: VmRestart),
      HelperAccepted,
      Error(AlreadyTerminal(
        state: Lost(reason: VmRestart),
        event: HelperAccepted,
      )),
    ),
    #(
      Lost(reason: VmRestart),
      KillRequested(by: ByOwner),
      Error(AlreadyTerminal(
        state: Lost(reason: VmRestart),
        event: KillRequested(by: ByOwner),
      )),
    ),
    #(
      Lost(reason: VmRestart),
      ExitReported(result:),
      Error(AlreadyTerminal(
        state: Lost(reason: VmRestart),
        event: ExitReported(result:),
      )),
    ),
    #(
      Lost(reason: VmRestart),
      RunnerLost(reason: VmRestart),
      Error(AlreadyTerminal(
        state: Lost(reason: VmRestart),
        event: RunnerLost(reason: VmRestart),
      )),
    ),
  ]

  // Twenty-nine is the count the table is exhaustive at: twenty-four
  // shape rows, six states against four events, and five attribution
  // rows. A new state or a new event fails this line before it fails an
  // assertion, which is the point of asserting it.
  assert list.length(rows) == 29

  list.each(rows, fn(row) {
    let #(state, event, expected) = row
    let stepped = jobstate.step(record(state), event)
    assert stepped == map_state(expected)
  })
}

// Lifts a table row's expected `JobState` into the expected `JobRecord`,
// which is where "only the state moved" is asserted for every row at
// once: the comparison is against `record(..)` rebuilt from scratch, so
// any other field the machine touched shows up as an inequality.
fn map_state(
  expected: Result(JobState, jobstate.IllegalTransition),
) -> Result(JobRecord, jobstate.IllegalTransition) {
  case expected {
    Ok(state) -> Ok(record(state))
    Error(illegal) -> Error(illegal)
  }
}

// The stop's cause is the record's, not the exit report's: the helper's
// `exec_exit` says only *that* it climbed the ladder, never at whose
// asking, so every cause has to survive draining intact.
pub fn every_kill_cause_survives_to_the_terminal_state_test() {
  list.each(causes(), fn(cause) {
    let assert Ok(draining) =
      jobstate.step(record(Starting), KillRequested(by: cause))
      as "a stop request must always drain"
    assert draining.state == Draining(by: cause)

    let assert Ok(killed) =
      jobstate.step(draining, ExitReported(result: settled()))
      as "a draining job must settle as killed"
    assert killed.state == Killed(by: cause, result: settled())
  })
}

// `is_terminal` is the split every sweep and listing asks through, so it
// is asserted against the variants directly rather than through `step`.
pub fn is_terminal_names_exactly_the_three_terminal_states_test() {
  assert !jobstate.is_terminal(Starting)
  assert !jobstate.is_terminal(Running)
  assert !jobstate.is_terminal(Draining(by: ByOwner))
  assert jobstate.is_terminal(Exited(result: settled()))
  assert jobstate.is_terminal(Killed(by: ByOwner, result: settled()))
  assert jobstate.is_terminal(Lost(reason: VmRestart))
}

// --- properties over seeded event scripts ---------------------------------

// Four properties over two hundred random event scripts each, folded
// through `step`.
//
// The fold keeps the record whenever a step is refused, which is exactly
// what the actor does with an illegal transition, so the script continues
// past a refusal instead of stopping at the first one — and that is what
// reaches the orders a hand-written table does not.
pub fn random_scripts_preserve_every_invariant_test() {
  list.each(range(from: 1, to: 200), fn(n) {
    let #(events, _seed) = gen_events(seed(n), 12)
    check_script(record(Starting), events)
  })
}

// One script, one invariant check per step. Written as a loop rather than
// a fold because each step compares the record before against the record
// after, which an accumulator would have to carry anyway.
fn check_script(before: JobRecord, events: List(JobEvent)) -> Nil {
  case events {
    [] -> Nil

    [event, ..rest] -> {
      let after = apply(before, event)

      // Identity is immutable. Nothing but `state` may move, so a
      // transition can never rewrite whose job this is, which operation
      // an abort would reach it through, or when its deadline falls.
      assert after.id == before.id
      assert after.owner == before.owner
      assert after.started_by == before.started_by
      assert after.spec == before.spec
      assert after.started_at_ms == before.started_at_ms
      assert after.deadline_ms == before.deadline_ms

      // Terminal is absorbing. A terminal record is what the restart
      // sweep skips and what a poll reports as final, so no event may
      // move one — the step is refused and the record is unchanged.
      assert !jobstate.is_terminal(before.state) || after == before

      // An exit report from a live state always terminates. This is the
      // property that makes "every job eventually has an answer" true:
      // the helper's report is the one event that can never leave a job
      // waiting for another.
      assert jobstate.is_terminal(before.state)
        || !is_exit(event)
        || jobstate.is_terminal(after.state)

      // `Exited` means the job ended of its own accord, and the helper's
      // own flags are what make that check-able rather than merely
      // documented: a report carrying `cancelled` or `timed_out` is
      // attributed to `Killed`, so a poll reading `Exited` as "finished"
      // is never reading a job a deadline or an abort stopped.
      assert !exited_under_duress(after.state)

      check_script(after, rest)
    }
  }
}

// The actor's own handling of a refusal, stated once: keep the record.
fn apply(current: JobRecord, event: JobEvent) -> JobRecord {
  case jobstate.step(current, event) {
    Ok(next) -> next
    Error(_illegal) -> current
  }
}

// Whether a state is an `Exited` carrying the helper's own witness that
// the run did not end of its own accord — the shape the attribution arms
// exist to make unreachable.
fn exited_under_duress(state: JobState) -> Bool {
  case state {
    Exited(result:) -> result.cancelled || result.timed_out

    Starting | Running | Draining(..) | Killed(..) | Lost(..) -> False
  }
}

fn is_exit(event: JobEvent) -> Bool {
  case event {
    ExitReported(..) -> True
    HelperAccepted | KillRequested(..) | RunnerLost(..) -> False
  }
}

// A stop always reaches a terminal state, whatever arrives in between.
// The exit report is the only event that settles a draining job, and the
// cause the *first* stop named is the one the terminal state carries — so
// a session-stop sweep racing an owner's own `job_kill` cannot erase who
// asked.
pub fn a_stop_settles_under_the_first_cause_that_asked_test() {
  list.each(range(from: 1, to: 100), fn(n) {
    let #(first, seed) = gen_cause(seed(n))
    let #(noise, _seed) = gen_events(seed, 6)

    let assert Ok(draining) =
      jobstate.step(record(Running), KillRequested(by: first))
      as "a running job must drain on a stop request"

    // Only stop requests and acceptances are replayed here: a loss or an
    // exit in the noise would legitimately settle the job before the
    // report arrives, which is a different property.
    let quiet = list.filter(noise, is_stop_or_acceptance)
    let drained = list.fold(quiet, draining, apply)
    assert drained.state == Draining(by: first)

    let assert Ok(killed) =
      jobstate.step(drained, ExitReported(result: settled()))
      as "the helper's report settles a draining job"
    assert killed.state == Killed(by: first, result: settled())
  })
}

fn is_stop_or_acceptance(event: JobEvent) -> Bool {
  case event {
    HelperAccepted | KillRequested(..) -> True
    ExitReported(..) | RunnerLost(..) -> False
  }
}

// --- the codec ------------------------------------------------------------

// Round-trip over two hundred generated records: every state shape, every
// cause, every reason, and an `ExecResult` whose eleven fields are drawn
// independently so a codec that dropped or transposed one is caught.
pub fn every_generated_record_round_trips_test() {
  let records =
    list.map(range(from: 1, to: 200), fn(n) {
      let #(record, _seed) = gen_record(seed(n))
      record
    })
  list.each(records, fn(record) {
    assert jobstate.decode(jobstate.encode(record)) == Ok(record)
  })

  // The draw is asserted as well as used. A round trip over two hundred
  // records that all happened to be `Starting` would pass while testing
  // one sixth of the codec, and a degenerate generator is exactly the
  // failure a property test cannot report about itself.
  let phases = list.unique(list.map(records, phase_of))
  assert list.sort(phases, string.compare)
    == ["draining", "exited", "killed", "lost", "running", "starting"]
}

// The phase tag of a record's stored form, which is what the coverage
// assertion above counts.
fn phase_of(record: JobRecord) -> String {
  let assert json.Object(fields) = jobstate.encode(record)
    as "a record encodes as an object"
  let assert Ok(json.Object(state)) = list.key_find(fields, "state")
    as "the state is an object"
  let assert Ok(json.String(phase)) = list.key_find(state, "phase")
    as "the state names a phase"
  phase
}

// The round trip is exact and not merely equal-looking: the stored form
// is an object with the fields named here, so a reader of a cell by hand
// (or a later build) knows what it is looking at.
pub fn the_stored_form_is_the_documented_object_test() {
  let stored =
    jobstate.encode(spilled(record(Killed(by: ByDeadline, result: settled()))))
  let assert json.Object(fields) = stored as "a record encodes as an object"
  let names = list.map(fields, fn(field) { field.0 })
  assert names
    == [
      "id",
      "owner",
      "startedBy",
      "spec",
      "startedAtMs",
      "deadlineMs",
      "state",
      "spill",
    ]

  let assert Ok(json.Object(state)) = list.key_find(fields, "state")
    as "the state is an object"
  assert list.key_find(state, "phase") == Ok(json.String("killed"))
  assert list.key_find(state, "by") == Ok(json.String("deadline"))

  // Each stream's ref is a field that is always there and sometimes null,
  // never a field that comes and goes: an absent one would leave every
  // later reader an absent-means-nothing arm it could not tell from a
  // writer that forgot.
  let assert Ok(json.Object(spill)) = list.key_find(fields, "spill")
    as "the spill is an object"
  assert list.key_find(spill, "stdoutRef") == Ok(json.String(a_ref()))
  assert list.key_find(spill, "stderrRef") == Ok(json.Null)

  let empty = jobstate.encode(record(Exited(result: settled())))
  let assert json.Object(exited) = empty as "a record is an object"
  let assert Ok(json.Object(spill)) = list.key_find(exited, "spill")
    as "the spill is an object"
  assert list.key_find(spill, "stdoutRef") == Ok(json.Null)
  assert list.key_find(spill, "stderrRef") == Ok(json.Null)
}

// Every malformed payload is a corruption report naming the field that
// broke, never a crash and never a half-read record.
//
// The catalogue is written as `#(what is wrong, the payload)` so a
// failure names the case rather than a subscript. `decode` has no lenient
// arm on purpose: guessing terminal hides a running process from the
// restart sweep, and guessing live keeps a dead job in every listing
// forever, so both directions of a guess are harmful.
pub fn every_malformed_payload_is_a_corruption_report_test() {
  let good = jobstate.encode(record(Running))
  let assert json.Object(fields) = good as "the fixture encodes as an object"

  let broken = [
    #("not an object at all", json.Null),
    #("an array where an object belongs", json.Array([])),
    #("a missing id", without(fields, "id")),
    #("a missing owner", without(fields, "owner")),
    #("a missing operation", without(fields, "startedBy")),
    #("a missing spec", without(fields, "spec")),
    #("a missing start instant", without(fields, "startedAtMs")),
    #("a missing deadline", without(fields, "deadlineMs")),
    #("a missing state", without(fields, "state")),
    #(
      "an id that could not have been minted",
      replace(fields, "id", json.String("a/b")),
    ),
    #("an empty id", replace(fields, "id", json.String(""))),
    #("an id that is not a string", replace(fields, "id", json.Int(7))),
    #(
      "an operation that is not a uuid",
      replace(fields, "startedBy", json.String("nope")),
    ),
    #(
      "a start instant that is not an integer",
      replace(fields, "startedAtMs", json.String("1000")),
    ),
    #(
      "a spec that is not an object",
      replace(fields, "spec", json.String("bash")),
    ),
    #("a spec with no argv", replace(fields, "spec", json.Object([]))),
    #(
      "an argv holding a non-string",
      replace(
        fields,
        "spec",
        json.Object([
          #("argv", json.Array([json.Int(1)])),
          #("cwd", json.String("/workspace")),
          #("requestedWallMs", json.Int(1)),
        ]),
      ),
    ),
    #("a state that is not an object", replace(fields, "state", json.Null)),
    #("a state with no phase", replace(fields, "state", json.Object([]))),
    #("an unknown phase", phase([#("phase", json.String("paused"))], fields)),
    #(
      "a draining state with no cause",
      phase([#("phase", json.String("draining"))], fields),
    ),
    #(
      "an unknown cause",
      phase(
        [#("phase", json.String("draining")), #("by", json.String("nobody"))],
        fields,
      ),
    ),
    #(
      "a lost state with no reason",
      phase([#("phase", json.String("lost"))], fields),
    ),
    #(
      "an unknown reason",
      phase(
        [#("phase", json.String("lost")), #("reason", json.String("bored"))],
        fields,
      ),
    ),
    #(
      "an exited state with no result",
      phase([#("phase", json.String("exited"))], fields),
    ),
    #(
      "a killed state with a cause but no result",
      phase(
        [#("phase", json.String("killed")), #("by", json.String("owner"))],
        fields,
      ),
    ),
    // A record with no spill field at all, and one whose stream ref is
    // neither a ref nor null. Both are refused rather than read as "this
    // job printed nothing", which is the guess a decoder would have to
    // make forever if the field were ever allowed to be absent.
    #("a record with no spill", without(fields, "spill")),
    #(
      "a stream ref that is neither a ref nor null",
      replace(fields, "spill", json.Object([#("stdoutRef", json.Int(7))])),
    ),
    #(
      "a result missing cancelled",
      phase(
        [
          #("phase", json.String("exited")),
          #("result", result_without("cancelled")),
        ],
        fields,
      ),
    ),
    #(
      "a result whose cancelled is not a boolean",
      phase(
        [
          #("phase", json.String("exited")),
          #("result", result_replacing("cancelled", json.Int(1))),
        ],
        fields,
      ),
    ),
  ]

  list.each(broken, fn(case_) {
    let #(what, payload) = case_
    case jobstate.decode(payload) {
      Error(_report) -> Nil
      Ok(_record) -> panic as { "decoded a payload with " <> what }
    }
  })
}

// Three of those cases again, pinned to the field their report blames.
//
// The catalogue above asks only that a malformed payload comes back as an
// error, which a decoder that answered `on: "payload"` for everything
// would satisfy while telling an operator nothing about which cell broke.
// One case per level says the path is real: a top-level field, the phase
// tag inside the state, and a stream's ref inside the spill.
pub fn a_corruption_report_names_the_field_that_broke_test() {
  let good = jobstate.encode(record(Running))
  let assert json.Object(fields) = good as "the fixture encodes as an object"

  let blamed = [
    #(replace(fields, "id", json.String("a/b")), "id"),
    #(phase([#("phase", json.String("paused"))], fields), "state.phase"),
    #(
      replace(fields, "spill", json.Object([#("stdoutRef", json.Int(7))])),
      "spill.stdoutRef",
    ),
  ]

  list.each(blamed, fn(row) {
    let #(payload, subject) = row
    let assert Error(report) = jobstate.decode(payload)
      as "a malformed payload is a corruption report"
    assert report.subject == subject
  })
}

// The same fixture as `settled()` in stored form, minus or with one field
// changed — the two shapes the result-level malformed cases need.
fn result_without(key: String) -> json.JsonValue {
  let assert json.Object(fields) = stored_result() as "a result is an object"
  json.Object(list.filter(fields, fn(field) { field.0 != key }))
}

fn result_replacing(key: String, value: json.JsonValue) -> json.JsonValue {
  let assert json.Object(fields) = stored_result() as "a result is an object"
  json.Object(
    list.map(fields, fn(field) {
      case field.0 == key {
        True -> #(key, value)
        False -> field
      }
    }),
  )
}

fn stored_result() -> json.JsonValue {
  let stored = jobstate.encode(record(Exited(result: settled())))
  let assert json.Object(fields) = stored as "a record is an object"
  let assert Ok(json.Object(state)) = list.key_find(fields, "state")
    as "the state is an object"
  let assert Ok(result) = list.key_find(state, "result")
    as "an exited state carries a result"
  result
}

fn without(
  fields: List(#(String, json.JsonValue)),
  key: String,
) -> json.JsonValue {
  json.Object(list.filter(fields, fn(field) { field.0 != key }))
}

fn replace(
  fields: List(#(String, json.JsonValue)),
  key: String,
  value: json.JsonValue,
) -> json.JsonValue {
  json.Object(
    list.map(fields, fn(field) {
      case field.0 == key {
        True -> #(key, value)
        False -> field
      }
    }),
  )
}

fn phase(
  state: List(#(String, json.JsonValue)),
  fields: List(#(String, json.JsonValue)),
) -> json.JsonValue {
  replace(fields, "state", json.Object(state))
}

// --- seeded generation ----------------------------------------------------
//
// core's `test/support/generate` is not a dependency of this package, so
// the SplitMix64 draw is repeated here — the same arrangement
// `machine/property_test` made for the same reason.

type Seed {
  Seed(state: Int)
}

const mask_64 = 0xFFFFFFFFFFFFFFFF

fn seed(n: Int) -> Seed {
  Seed(state: int.bitwise_and(n, mask_64))
}

// An inclusive integer range as a list, which is how each property test
// says how many scripts it draws.
fn range(from start: Int, to stop: Int) -> List(Int) {
  int.range(from: start, to: stop + 1, with: [], run: fn(acc, n) { [n, ..acc] })
  |> list.reverse
}

fn next(seed: Seed) -> #(Int, Seed) {
  let state = int.bitwise_and(seed.state + 0x9E3779B97F4A7C15, mask_64)
  let z = state
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 30))
        * 0xBF58476D1CE4E5B9,
      mask_64,
    )
  let z =
    int.bitwise_and(
      int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 27))
        * 0x94D049BB133111EB,
      mask_64,
    )
  let z = int.bitwise_exclusive_or(z, int.bitwise_shift_right(z, 31))
  #(z, Seed(state:))
}

fn int_between(seed: Seed, min: Int, max: Int) -> #(Int, Seed) {
  let #(raw, seed) = next(seed)
  #(min + raw % { max - min + 1 }, seed)
}

fn bool(seed: Seed) -> #(Bool, Seed) {
  let #(n, seed) = int_between(seed, 0, 1)
  #(n == 1, seed)
}

// Draws one of a non-empty list. The fallback is the head, which is
// unreachable because the index is drawn inside the list's own bounds.
fn one_of(seed: Seed, options: List(a), fallback: a) -> #(a, Seed) {
  let #(index, seed) = int_between(seed, 0, list.length(options) - 1)
  case list.drop(options, index) {
    [chosen, ..] -> #(chosen, seed)
    [] -> #(fallback, seed)
  }
}

fn gen_cause(seed: Seed) -> #(jobstate.KillCause, Seed) {
  one_of(seed, causes(), ByOwner)
}

fn gen_reason(seed: Seed) -> #(jobstate.LossReason, Seed) {
  one_of(seed, reasons(), VmRestart)
}

fn gen_event(seed: Seed) -> #(JobEvent, Seed) {
  let #(pick, seed) = int_between(seed, 0, 3)
  case pick {
    0 -> #(HelperAccepted, seed)

    1 -> {
      let #(cause, seed) = gen_cause(seed)
      #(KillRequested(by: cause), seed)
    }

    2 -> {
      let #(result, seed) = gen_result(seed)
      #(ExitReported(result:), seed)
    }

    _ -> {
      let #(reason, seed) = gen_reason(seed)
      #(RunnerLost(reason:), seed)
    }
  }
}

fn gen_events(seed: Seed, count: Int) -> #(List(JobEvent), Seed) {
  gen_events_loop(seed, count, [])
}

fn gen_events_loop(
  seed: Seed,
  count: Int,
  acc: List(JobEvent),
) -> #(List(JobEvent), Seed) {
  case count <= 0 {
    True -> #(list.reverse(acc), seed)
    False -> {
      let #(event, seed) = gen_event(seed)
      gen_events_loop(seed, count - 1, [event, ..acc])
    }
  }
}

fn gen_result(seed: Seed) -> #(ExecResult, Seed) {
  let #(code, seed) = int_between(seed, 0, 255)
  let #(signal, seed) = int_between(seed, 0, 15)
  let #(stdout_bytes, seed) = int_between(seed, 0, 1_000_000)
  let #(stderr_bytes, seed) = int_between(seed, 0, 1_000_000)
  let #(stdout_truncated, seed) = bool(seed)
  let #(stderr_truncated, seed) = bool(seed)
  let #(enforcement, seed) = gen_enforcement(seed)
  let #(degraded, seed) = bool(seed)
  let #(wall_ms, seed) = int_between(seed, 0, 3_600_000)
  let #(timed_out, seed) = bool(seed)
  let #(cancelled, seed) = bool(seed)
  #(
    ExecResult(
      code:,
      signal:,
      stdout_bytes:,
      stderr_bytes:,
      stdout_truncated:,
      stderr_truncated:,
      enforcement:,
      degraded:,
      wall_ms:,
      timed_out:,
      cancelled:,
    ),
    seed,
  )
}

// The enforcement list is drawn including the empty case, because an
// empty array and an absent field are different facts about a run and the
// codec must not confuse them.
fn gen_enforcement(seed: Seed) -> #(List(String), Seed) {
  let layers = ["bwrap", "landlock", "seccomp", "skip:darwin-process-lifecycle"]
  let #(take, seed) = int_between(seed, 0, list.length(layers))
  #(list.take(layers, take), seed)
}

fn gen_state(seed: Seed) -> #(JobState, Seed) {
  let #(pick, seed) = int_between(seed, 0, 5)
  case pick {
    0 -> #(Starting, seed)

    1 -> #(Running, seed)

    2 -> {
      let #(cause, seed) = gen_cause(seed)
      #(Draining(by: cause), seed)
    }

    3 -> {
      let #(result, seed) = gen_result(seed)
      #(Exited(result:), seed)
    }

    4 -> {
      let #(cause, seed) = gen_cause(seed)
      let #(result, seed) = gen_result(seed)
      #(Killed(by: cause, result:), seed)
    }

    _ -> {
      let #(reason, seed) = gen_reason(seed)
      #(Lost(reason:), seed)
    }
  }
}

fn gen_record(seed: Seed) -> #(JobRecord, Seed) {
  let #(state, seed) = gen_state(seed)
  let #(owner, seed) = one_of(seed, ["main", "sub:main/reviewer-1"], "main")
  let #(argc, seed) = int_between(seed, 1, 4)
  let #(started_at_ms, seed) = int_between(seed, 0, 2_000_000_000)
  let #(wall, seed) = int_between(seed, 1000, 3_600_000)
  let #(tail, seed) = int_between(seed, 0, 999_999)
  let #(spill, seed) = gen_spill(seed)

  let assert Ok(id) = jobstate.parse_job_id("01JQ" <> int.to_string(tail))
    as "a generated id carries no separator"
  #(
    JobRecord(
      id:,
      owner:,
      started_by: an_op(),
      spec: JobSpec(
        argv: list.take(["bash", "-lc", "make check", "--"], argc),
        cwd: "/workspace",
        requested_wall_ms: wall,
      ),
      started_at_ms:,
      deadline_ms: started_at_ms + wall,
      state:,
      spill:,
    ),
    seed,
  )
}

// A spill in each of its three shapes: nothing stored, one stream
// stored, both. The refs are the codec's subject rather than real
// content addresses; what the round trip has to preserve is which
// streams are present, and a null told apart from a string.
fn gen_spill(seed: Seed) -> #(jobstate.JobSpill, Seed) {
  let #(shape, seed) = int_between(seed, 0, 2)
  let #(nonce, seed) = int_between(seed, 0, 999_999)
  let out = Some("sha256-o" <> int.to_string(nonce))
  let err = Some("sha256-e" <> int.to_string(nonce))
  case shape {
    0 -> #(jobstate.no_spill(), seed)
    1 -> #(jobstate.JobSpill(stdout_ref: out, stderr_ref: None), seed)
    _both -> #(jobstate.JobSpill(stdout_ref: out, stderr_ref: err), seed)
  }
}
