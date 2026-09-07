//// The background jobs actor against a scripted broker: what admission
//// refuses, what the deadline and the cancel ladder record, what a poll
//// sees, where the spill lands, and what a restart declares lost.
////
//// The posture is the tree's usual one for an actor test — a real
//// runtime over a memory session, a real actor, a real weft runner per
//// job, and only the effect surface scripted. What is faked is exactly
//// the broker: `Wiring.clear_call` is the seam `client/serve` fills with
//// `tools/tool.broker_runner`, so a fake here substitutes for a helper
//// pool and for nothing else. A test drives a job by telling the fake to
//// emit output, to settle, or to refuse the clearance outright, and reads
//// back what the durable record says.
////
//// The spill is faked for the same reason and no further: a dictionary
//// of paths in one actor, with `tools/blob.ref_for` doing the real
//// content addressing, so "the spill landed content-addressed" is an
//// assertion about the ref and not about a filesystem.
////
//// Two clocks appear and the difference matters. Admission and the
//// record's instants read a **counting** clock, so a test's timestamps
//// are reproducible. The one test that has to make a real deadline expire
//// reads the **wall** clock instead, because a runner's fold bounds a
//// real `receive` on the number that clock gives it, and a logical clock
//// would ask for a window nothing could measure.
////
//// ## The mutation checks
////
//// Five removals, each run against the whole suite, recorded here so the
//// next reader can repeat them rather than trust this paragraph.
////
//// | Removed | Fails |
//// |---|---|
//// | `room_for_one_more`'s `CeilingReached` | `the_fifth_job_on_one_strand_is_refused_test` |
//// | `commit`'s call to `persist` | `an_exit_is_recorded_with_its_result_test`, `the_spill_lands_content_addressed_past_the_cap_test`, `a_terminal_record_survives_a_restart_unchanged_test`, `a_session_stop_kills_every_live_job_test` |
//// | `cancel`'s `control.cancel()` | `a_kill_climbs_the_ladder_test`, `a_session_stop_kills_every_live_job_test` |
//// | `sweep`'s `reap_one` | `a_restart_declares_a_running_job_lost_test` |
//// | `expired`'s `DeadlinePassed` send and its `stopped_by` | `a_deadline_kills_with_its_own_cause_test` |
////
//// The fifth is the deadline's whole mechanism: without the notice and
//// the cause the runner carries in its report, a job the relay cancelled
//// at its wall settles as an ordinary exit and nothing names the
//// deadline. It is also the row that says what is *not* covered —
//// removing the run's backstop `weft.deadline` fails nothing, because no
//// test makes a clearance hang long enough to reach it.
////
//// Two of the five catch more than one test, and that is worth saying
//// rather than trimming the tests until the table is diagonal. `persist`
//// is the *only* durable write on the commit path, so every assertion
//// about what the store holds after a job ends rests on it; and the
//// cancel is reached by two callers, the owner's `job_kill` and the
//// session stop, which are two different reasons for the same ladder.
//// What the checks establish is that none of the five is dead weight, and
//// the narrowest test in each row is the one that names the mechanism.
////
//// Removing `persist` also, on the first run, failed
//// `a_refused_clearance_reaches_the_starting_caller_test` — which turned
//// out to have nothing to do with the mutation and everything to do with
//// an ordering flaw it shook loose: the actor answered the starting
//// caller *before* deleting the record of the job that never ran, so a
//// caller could read a `Starting` cell for it. The delete moved ahead of
//// the answer, and that is the mutation check paying for itself.

import broker/broker
import broker/exec.{type ExecResult, ExecResult}
import broker/framing
import broker/policy
import broker/token
import client/internal/ffi_os
import client/jobs
import client/jobstate.{type JobId}
import client/serve
import core/clock.{type Clock}
import core/ids
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api.{type Runtime}
import runtime/effects
import session/session
import support/addresses
import tools/blob
import tools/tool
import weft/actor
import weft/poll
import weft/registry as address

// --- the scripted broker --------------------------------------------------
//
// One actor standing in for the whole helper pool. Every clearance
// registers under its `CallSpec`'s step id — which is the job's own
// `job/<id>` key, so a test holding a `Started` can address the execution
// behind it — and the test then plays the helper's part by hand: emit a
// chunk, settle, or watch the cancels arrive.

type FakeBroker {
  FakeBroker(subject: Subject(FakeMessage))
}

type Execution {
  Execution(
    events: Subject(broker.CallEvent),
    cancels: Int,
    stdin: List(#(BitArray, Bool)),
  )
}

type FakeState {
  FakeState(
    self: Subject(FakeMessage),
    /// Live and settled executions, keyed by the step id the clearance
    /// carried.
    executions: Dict(String, Execution),
    /// The steps cleared so far, newest first.
    cleared: List(String),
    /// What the next clearance answers. `None` admits it.
    refusing: Option(broker.Refusal),
    /// Every `CallSpec` seen, newest first, so a test can assert what a
    /// job asked the broker for without reaching into the actor.
    specs: List(broker.CallSpec),
  )
}

type FakeMessage {
  Clear(
    spec: broker.CallSpec,
    events: Subject(broker.CallEvent),
    reply: Subject(Result(tool.RunningCall, broker.Refusal)),
  )
  Cancelled(step: String)
  Wrote(step: String, data: BitArray, eof: Bool)
  Emit(step: String, stream: framing.OutputStream, data: BitArray)
  Settle(step: String, outcome: broker.CallOutcome)
  RefuseNext(refusal: Option(broker.Refusal))
  Cancels(step: String, reply: Subject(Int))
  Stdins(step: String, reply: Subject(List(#(BitArray, Bool))))
  ClearedSteps(reply: Subject(List(String)))
  Specs(reply: Subject(List(broker.CallSpec)))
}

fn start_fake_broker() -> FakeBroker {
  let assert Ok(started) =
    actor.new_with_initialiser(1000, fn(subject) {
      actor.initialised(
        FakeState(
          self: subject,
          executions: dict.new(),
          cleared: [],
          refusing: None,
          specs: [],
        ),
      )
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle_fake)
    |> actor.start
    as "the fake broker must start"
  FakeBroker(subject: started.data)
}

fn handle_fake(
  state: FakeState,
  message: FakeMessage,
) -> actor.Next(FakeState, FakeMessage) {
  case message {
    Clear(spec:, events:, reply:) -> {
      let state = FakeState(..state, specs: [spec, ..state.specs])
      case state.refusing {
        Some(refusal) -> {
          process.send(reply, Error(refusal))
          actor.continue(FakeState(..state, refusing: None))
        }
        None -> {
          let step = spec.step_id
          process.send(reply, Ok(running_call(state.self, step)))
          actor.continue(
            FakeState(
              ..state,
              executions: dict.insert(
                state.executions,
                step,
                Execution(events:, cancels: 0, stdin: []),
              ),
              cleared: [step, ..state.cleared],
            ),
          )
        }
      }
    }

    Cancelled(step:) ->
      actor.continue(
        update(state, step, fn(execution) {
          Execution(..execution, cancels: execution.cancels + 1)
        }),
      )

    Wrote(step:, data:, eof:) ->
      actor.continue(
        update(state, step, fn(execution) {
          Execution(..execution, stdin: [#(data, eof), ..execution.stdin])
        }),
      )

    Emit(step:, stream:, data:) -> {
      case dict.get(state.executions, step) {
        Error(Nil) -> Nil
        Ok(execution) ->
          process.send(
            execution.events,
            broker.CallOutput(
              stream:,
              data:,
              total_bytes: bit_array.byte_size(data),
              truncated: False,
            ),
          )
      }
      actor.continue(state)
    }

    Settle(step:, outcome:) -> {
      case dict.get(state.executions, step) {
        Error(Nil) -> Nil
        Ok(execution) ->
          process.send(execution.events, broker.CallSettled(outcome:))
      }
      actor.continue(state)
    }

    RefuseNext(refusal:) ->
      actor.continue(FakeState(..state, refusing: refusal))

    Cancels(step:, reply:) -> {
      let count = case dict.get(state.executions, step) {
        Error(Nil) -> 0
        Ok(execution) -> execution.cancels
      }
      process.send(reply, count)
      actor.continue(state)
    }

    Stdins(step:, reply:) -> {
      let written = case dict.get(state.executions, step) {
        Error(Nil) -> []
        Ok(execution) -> list.reverse(execution.stdin)
      }
      process.send(reply, written)
      actor.continue(state)
    }

    ClearedSteps(reply:) -> {
      process.send(reply, list.reverse(state.cleared))
      actor.continue(state)
    }

    Specs(reply:) -> {
      process.send(reply, list.reverse(state.specs))
      actor.continue(state)
    }
  }
}

// The two closures the broker hands a caller, routed back into this actor
// so a test can count what a job asked for.
fn running_call(self: Subject(FakeMessage), step: String) -> tool.RunningCall {
  tool.RunningCall(
    stdin: fn(data, eof) { process.send(self, Wrote(step:, data:, eof:)) },
    cancel: fn() { process.send(self, Cancelled(step:)) },
  )
}

fn update(
  state: FakeState,
  step: String,
  change: fn(Execution) -> Execution,
) -> FakeState {
  case dict.get(state.executions, step) {
    Error(Nil) -> state
    Ok(execution) ->
      FakeState(
        ..state,
        executions: dict.insert(state.executions, step, change(execution)),
      )
  }
}

fn clear_seam(
  fake: FakeBroker,
) -> fn(broker.CallSpec, Subject(broker.CallEvent)) ->
  Result(tool.RunningCall, broker.Refusal) {
  fn(spec, events) {
    process.call(fake.subject, waiting: 5000, sending: fn(reply) {
      Clear(spec:, events:, reply:)
    })
  }
}

// --- the scripted spill ---------------------------------------------------
//
// Staging files as a dictionary, promotion through the real
// `tools/blob.ref_for`. What the tests need from it is that appends
// accumulate, that a promotion produces the content address of the whole
// stream, and that the staging entry is gone afterwards.

type FakeSpill {
  FakeSpill(subject: Subject(SpillMessage))
}

type SpillState {
  SpillState(staged: Dict(String, BitArray), stored: Dict(String, BitArray))
}

type SpillMessage {
  Append(path: String, data: BitArray, reply: Subject(Result(Nil, String)))
  Read(path: String, reply: Subject(Result(BitArray, String)))
  Remove(path: String, reply: Subject(Result(Nil, String)))
  Staged(reply: Subject(Result(List(String), String)))
  Store(data: BitArray, reply: Subject(Result(String, String)))
  StoredBody(ref: String, reply: Subject(Result(BitArray, String)))
  Plant(path: String, data: BitArray, reply: Subject(Nil))
}

fn start_fake_spill() -> FakeSpill {
  let assert Ok(started) =
    actor.new(SpillState(staged: dict.new(), stored: dict.new()))
    |> actor.on_message(handle_spill)
    |> actor.start
    as "the fake spill must start"
  FakeSpill(subject: started.data)
}

fn handle_spill(
  state: SpillState,
  message: SpillMessage,
) -> actor.Next(SpillState, SpillMessage) {
  case message {
    Append(path:, data:, reply:) -> {
      let existing = dict.get(state.staged, path) |> result.unwrap(<<>>)
      process.send(reply, Ok(Nil))
      actor.continue(
        SpillState(
          ..state,
          staged: dict.insert(
            state.staged,
            path,
            bit_array.append(existing, data),
          ),
        ),
      )
    }

    Read(path:, reply:) -> {
      let answer = case dict.get(state.staged, path) {
        Ok(bytes) -> Ok(bytes)
        Error(Nil) -> Error("no such staging file: " <> path)
      }
      process.send(reply, answer)
      actor.continue(state)
    }

    Remove(path:, reply:) -> {
      process.send(reply, Ok(Nil))
      actor.continue(
        SpillState(..state, staged: dict.delete(state.staged, path)),
      )
    }

    Staged(reply:) -> {
      process.send(reply, Ok(dict.keys(state.staged)))
      actor.continue(state)
    }

    Store(data:, reply:) -> {
      let ref = blob.ref_for(data)
      process.send(reply, Ok(ref))
      actor.continue(
        SpillState(..state, stored: dict.insert(state.stored, ref, data)),
      )
    }

    StoredBody(ref:, reply:) -> {
      let answer = case dict.get(state.stored, ref) {
        Ok(bytes) -> Ok(bytes)
        Error(Nil) -> Error("nothing stored at " <> ref)
      }
      process.send(reply, answer)
      actor.continue(state)
    }

    Plant(path:, data:, reply:) -> {
      process.send(reply, Nil)
      actor.continue(
        SpillState(..state, staged: dict.insert(state.staged, path, data)),
      )
    }
  }
}

fn spill_seam(fake: FakeSpill) -> jobs.Spill {
  jobs.Spill(
    append: fn(path, data) {
      process.call(fake.subject, waiting: 5000, sending: fn(reply) {
        Append(path:, data:, reply:)
      })
    },
    read: fn(path) {
      process.call(fake.subject, waiting: 5000, sending: fn(reply) {
        Read(path:, reply:)
      })
    },
    remove: fn(path) {
      process.call(fake.subject, waiting: 5000, sending: fn(reply) {
        Remove(path:, reply:)
      })
    },
    staged: fn() { process.call(fake.subject, waiting: 5000, sending: Staged) },
    store: fn(_tag, data) {
      process.call(fake.subject, waiting: 5000, sending: fn(reply) {
        Store(data:, reply:)
      })
    },
  )
}

// --- the harness ----------------------------------------------------------

type Harness {
  Harness(
    name: address.Address(jobs.Message),
    fake: FakeBroker,
    spill: FakeSpill,
    runtime: Runtime,
    operation: ids.OpId,
    /// The actor's own process. Two tests address it rather than its
    /// subject: one reads its mailbox, the other shuts it down the way a
    /// supervisor does.
    pid: process.Pid,
  )
}

// A session, a runtime and a jobs actor over the counting clock.
//
// The clock steps a whole millisecond per read, which keeps every
// recorded instant distinct and every wall in these tests comfortably
// longer than the handful of reads a test makes — so nothing expires by
// accident and the one test that *wants* an expiry has to ask for it.
fn start_harness() -> Harness {
  start_harness_on(counting_clock(1_756_000_000_000, 1))
}

fn start_harness_on(clock: Clock) -> Harness {
  let runtime = open_runtime(clock)
  let fake = start_fake_broker()
  let spill = start_fake_spill()
  let name = addresses.new()
  let assert Ok(started) =
    jobs.start(name, fake_wiring(runtime, fake, spill, clock))
    as "the jobs actor must start"
  Harness(name:, fake:, spill:, runtime:, operation: an_op(), pid: started.pid)
}

// The wiring every test but the policy pair uses: the scripted broker,
// and the restrictive workspace default as the session base.
fn fake_wiring(
  runtime: Runtime,
  fake: FakeBroker,
  spill: FakeSpill,
  clock: Clock,
) -> jobs.Wiring {
  wiring(
    runtime,
    spill,
    clock,
    clear_seam(fake),
    5000,
    policy.workspace_default("/workspace"),
  )
}

fn wiring(
  runtime: Runtime,
  spill: FakeSpill,
  clock: Clock,
  clear: fn(broker.CallSpec, Subject(broker.CallEvent)) ->
    Result(tool.RunningCall, broker.Refusal),
  clearance_ms: Int,
  base: policy.SandboxPolicy,
) -> jobs.Wiring {
  jobs.Wiring(
    runtime: fn() { Ok(runtime) },
    policy: jobs.default_policy,
    clock:,
    seed: 42,
    workspace: "/workspace",
    base_policy: base,
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin:/bin")],
    clear_call: clear,
    clearance_ms:,
    spill: spill_seam(spill),
    blob_root: "/blobs",
  )
}

fn open_runtime(clock: Clock) -> Runtime {
  let assert Ok(opened) = session.open_memory(clock)
    as "the memory session must open"
  let assert Ok(runtime) =
    api.open(
      opened,
      effects.Effects(
        clock:,
        entropy: fn() { 7 },
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(timeout_ms: 1000, request: fn(_spec) {
          stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
        }),
        // Nothing here dispatches a tool: a job's execution goes through
        // the broker seam above, never through the driver's tool surface.
        tools: effects.ToolSurface(
          clear: fn(_query) {
            effects.ClearanceRefused(reason: "no tool plane in this harness")
          },
          run: fn(_run) {
            effects.ToolFailed(reason: "no tool plane in this harness")
          },
          replay_still_safe: fn(_name) { False },
          execution_mode: fn(_name) { effects.ExclusiveExecution },
        ),
        hooks: effects.default_hooks(),
      ),
      api.default_options(configuration()),
    )
    as "the runtime must open"
  runtime
}

fn configuration() -> machine_strand.StrandConfiguration {
  machine_strand.StrandConfiguration(
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    thinking_level: machine_strand.ThinkingOff,
    active_tool_names: [],
  )
}

fn an_op() -> ids.OpId {
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 1000), seed: 9))
  operation
}

// --- clocks ---------------------------------------------------------------

type CounterMessage {
  Next(reply: Subject(Int))
}

fn counting_clock(from: Int, by: Int) -> Clock {
  let assert Ok(started) =
    actor.new(from)
    |> actor.on_message(fn(now, message) {
      let Next(reply:) = message
      process.send(reply, now)
      actor.continue(now + by)
    })
    |> actor.start
    as "the counting clock must start"
  clock.from_function(fn() {
    process.call(started.data, waiting: 1000, sending: Next)
  })
}

// The operating system's own clock. The deadline test needs it because a
// runner turns `deadline - now` into a real `receive` window, and a
// logical clock's milliseconds are not milliseconds anybody can wait.
fn wall_clock() -> Clock {
  clock.from_function(ffi_os.system_time_ms)
}

// --- driving the fake -----------------------------------------------------

fn step_of(started: jobs.Started) -> String {
  jobstate.job_key(started.id)
}

fn emit(harness: Harness, started: jobs.Started, text: String) -> Nil {
  process.send(
    harness.fake.subject,
    Emit(
      step: step_of(started),
      stream: framing.Stdout,
      data: bit_array.from_string(text),
    ),
  )
}

fn emit_bytes(harness: Harness, started: jobs.Started, data: BitArray) -> Nil {
  process.send(
    harness.fake.subject,
    Emit(step: step_of(started), stream: framing.Stdout, data:),
  )
}

fn settle_with(
  harness: Harness,
  started: jobs.Started,
  result: ExecResult,
) -> Nil {
  process.send(
    harness.fake.subject,
    Settle(step: step_of(started), outcome: broker.CallExited(result:)),
  )
}

fn cancels(harness: Harness, started: jobs.Started) -> Int {
  process.call(harness.fake.subject, waiting: 5000, sending: fn(reply) {
    Cancels(step: step_of(started), reply:)
  })
}

fn stdins(harness: Harness, started: jobs.Started) -> List(#(BitArray, Bool)) {
  process.call(harness.fake.subject, waiting: 5000, sending: fn(reply) {
    Stdins(step: step_of(started), reply:)
  })
}

fn cleared_steps(harness: Harness) -> List(String) {
  process.call(harness.fake.subject, waiting: 5000, sending: ClearedSteps)
}

fn specs(harness: Harness) -> List(broker.CallSpec) {
  process.call(harness.fake.subject, waiting: 5000, sending: Specs)
}

fn refuse_next(harness: Harness, refusal: broker.Refusal) -> Nil {
  process.send(harness.fake.subject, RefuseNext(refusal: Some(refusal)))
}

fn stored_body(harness: Harness, ref: String) -> Result(BitArray, String) {
  process.call(harness.spill.subject, waiting: 5000, sending: fn(reply) {
    StoredBody(ref:, reply:)
  })
}

fn staged_paths(harness: Harness) -> List(String) {
  let assert Ok(paths) =
    process.call(harness.spill.subject, waiting: 5000, sending: Staged)
    as "the fake spill always lists"
  paths
}

fn plant_staging(harness: Harness, path: String, text: String) -> Nil {
  process.call(harness.spill.subject, waiting: 5000, sending: fn(reply) {
    Plant(path:, data: bit_array.from_string(text), reply:)
  })
}

// --- driving the door -----------------------------------------------------

fn start_job(
  harness: Harness,
  strand: String,
  command: String,
) -> jobs.Started {
  let assert Ok(started) = started_or_refused(harness, strand, command, None)
    as "this job must be admitted"
  started
}

fn started_or_refused(
  harness: Harness,
  strand: String,
  command: String,
  wall_ms: Option(Int),
) -> Result(jobs.Started, jobs.Refusal) {
  jobs.start_job(
    harness.name,
    strand:,
    operation: harness.operation,
    request: jobs.Request(command:, wall_ms:),
    waiting: 10_000,
  )
}

fn poll(
  harness: Harness,
  strand: String,
  started: jobs.Started,
) -> jobs.Polled {
  poll_from(harness, strand, started.id, jobs.Cursors(stdout: 0, stderr: 0))
}

fn poll_from(
  harness: Harness,
  strand: String,
  id: JobId,
  cursors: jobs.Cursors,
) -> jobs.Polled {
  let assert Ok(polled) =
    jobs.poll_job(harness.name, strand:, id:, cursors:, waiting: 5000)
    as "this job must be pollable"
  polled
}

// The actor answers one poll after the event under test, and that is the
// barrier: the actor is a single thread of control, so an answer to a
// question asked *after* a message was sent proves the message was
// handled. Every "wait for the record to move" below is this and nothing
// more — no sleeps, no retries on a timer.
fn settled_state(
  harness: Harness,
  strand: String,
  started: jobs.Started,
) -> jobstate.JobState {
  await_state(harness, strand, started, 200)
}

fn await_state(
  harness: Harness,
  strand: String,
  started: jobs.Started,
  attempts: Int,
) -> jobstate.JobState {
  let polled = poll(harness, strand, started)
  case jobstate.is_terminal(polled.state) || attempts <= 0 {
    True -> polled.state
    False -> {
      process.sleep(5)
      await_state(harness, strand, started, attempts - 1)
    }
  }
}

// A chunk travels fake broker -> runner while this test travels
// test -> actor -> runner, and nothing orders those two against each
// other. So the barrier is the observation itself: poll until at least
// `bytes` of the stream have been seen, bounded, rather than sleeping a
// guessed interval and hoping.
fn await_output(
  harness: Harness,
  strand: String,
  started: jobs.Started,
  bytes: Int,
  attempts: Int,
) -> jobs.Polled {
  let polled = poll(harness, strand, started)
  let seen = bit_array.byte_size(polled.stdout.bytes) + polled.stdout.dropped
  case seen >= bytes || attempts <= 0 {
    True -> polled
    False -> {
      process.sleep(5)
      await_output(harness, strand, started, bytes, attempts - 1)
    }
  }
}

// How many messages are sitting in one process's mailbox.
//
// The only assertion that can see an *unselectable* message, which is
// what a report channel dropped one message too early leaves behind: the
// actor keeps answering, so no timing or ordering observation would ever
// show it. `packages/storage/test/storage/snapshot_test` reaches for
// `erlang:process_info` the same way and for the same reason — a test-only
// external, in a test file, measuring the runtime rather than asking the
// code under test to describe itself.
fn mailbox_length(pid: process.Pid) -> Int {
  let assert Ok(size) =
    decode.run(
      process_info(pid, atom.create("message_queue_len")),
      decode.at([1], decode.int),
    )
    as "the live actor reports its queue length"
  size
}

@external(erlang, "erlang", "process_info")
fn process_info(pid: process.Pid, item: atom.Atom) -> Dynamic

fn record_in_store(harness: Harness, id: JobId) -> jobstate.JobRecord {
  let assert Ok(cells) =
    api.reserved_facts(harness.runtime, prefix: jobstate.key_prefix)
    as "the job namespace must be readable"
  let assert Ok(payload) = list.key_find(cells, jobstate.job_key(id))
    as "this job must have a durable record"
  let assert Ok(record) = jobstate.decode(payload)
    as "a record this build wrote must decode"
  record
}

fn exited(code: Int) -> ExecResult {
  ExecResult(
    code:,
    signal: 0,
    stdout_bytes: 0,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: [],
    degraded: False,
    wall_ms: 5,
    timed_out: False,
    cancelled: False,
  )
}

fn cancelled_result() -> ExecResult {
  ExecResult(..exited(143), cancelled: True)
}

// --- admission ------------------------------------------------------------

pub fn a_job_clears_under_its_own_ledger_identity_test() {
  // ADR-005's second addendum, asserted rather than described: the step
  // id is the job's own key and not the batch's turn, the ledger opens
  // at a cap of one, and the budget deadline is the job's wall.
  let harness = start_harness()
  let started = start_job(harness, "main", "tail -f build.log")
  let assert [spec] = specs(harness) as "exactly one clearance"
  assert spec.step_id == jobstate.job_key(started.id)
  assert spec.op_id == harness.operation
  assert spec.budget.max_outstanding == 1
  assert spec.budget.deadline_ms == started.deadline_ms
  assert spec.argv == ["bash", "-lc", "tail -f build.log"]
  assert spec.response == broker.RefuseNarrowed
}

pub fn the_fifth_job_on_one_strand_is_refused_test() {
  // The ceiling is per strand, so a second strand still admits while the
  // first is full. Both halves matter: a session-wide count would refuse
  // the sibling too, and no count at all would admit the fifth.
  let harness = start_harness()
  let _first = start_job(harness, "main", "one")
  let _second = start_job(harness, "main", "two")
  let _third = start_job(harness, "main", "three")
  let _fourth = start_job(harness, "main", "four")

  assert started_or_refused(harness, "main", "five", None)
    == Error(jobs.CeilingReached(limit: 4))

  let sibling = started_or_refused(harness, "sub:main/worker", "one", None)
  assert result.is_ok(sibling)
}

pub fn a_finished_job_frees_its_ceiling_slot_test() {
  let harness = start_harness()
  let first = start_job(harness, "main", "one")
  let _second = start_job(harness, "main", "two")
  let _third = start_job(harness, "main", "three")
  let _fourth = start_job(harness, "main", "four")

  settle_with(harness, first, exited(0))
  let assert jobstate.Exited(..) = settled_state(harness, "main", first)
    as "the first job must finish"

  let after = started_or_refused(harness, "main", "five", None)
  assert result.is_ok(after)
}

pub fn a_requested_wall_is_clamped_to_the_ceiling_test() {
  // Clamped and *reported*, never refused: the caller is told what it got
  // rather than left to assume it got what it asked for.
  let harness = start_harness()
  let assert Ok(started) =
    started_or_refused(harness, "main", "sleep 99", Some(9_999_999_999))
    as "an over-long wall is clamped, not refused"
  assert started.wall_ms == jobs.default_wall_ms
}

pub fn a_default_wall_is_met_with_the_session_policys_own_test() {
  // The hour is a ceiling, not a demand. This harness's session base is
  // the restrictive workspace default, whose wall is ten minutes, so a
  // job started with no timeout is given ten minutes and asks the broker
  // for exactly that — which is what keeps it on the admitted side of a
  // `RefuseNarrowed` composition.
  let base = policy.workspace_default("/workspace")
  assert base.limits.wall_s * 1000 < jobs.default_wall_ms

  let harness = start_harness()
  let started = start_job(harness, "main", "tail -f build.log")
  assert started.wall_ms == base.limits.wall_s * 1000

  let assert [spec] = specs(harness) as "exactly one clearance"
  assert spec.requirements.limits.wall_s == base.limits.wall_s
}

pub fn the_real_policy_admits_a_default_and_refuses_a_longer_wall_test() {
  // The scripted broker composes no policy, so nothing else in this file
  // can see the meet the real one performs. `serve.base_policy` is what
  // a session hands this actor and its wall is ten minutes, so the two
  // halves of `granted_wall` land on opposite sides of the composition.
  let name = start_over_a_real_broker()

  // A default start gets past `policy.compose` and is refused only for
  // want of a helper. That is a different sentence from a policy
  // refusal, and telling the two apart is the whole of this test.
  let assert Error(jobs.ClearanceRefused(reason: admitted)) =
    start_over(name, None)
    as "an empty pool refuses every start it admits"
  assert string.contains(admitted, "no sandbox helper")

  // An explicit hour is more than the policy grants, so the composition
  // narrows it and `RefuseNarrowed` refuses before the pool is ever
  // asked — in the broker's own words, carrying the narrowing an
  // escalation would offer a grant against.
  let assert Error(jobs.ClearanceRefused(reason: refused)) =
    start_over(name, Some(jobs.default_wall_ms))
    as "an hour exceeds a ten-minute policy"
  assert string.contains(refused, "exceed the session policy")
}

fn start_over(
  name: address.Address(jobs.Message),
  wall_ms: Option(Int),
) -> Result(jobs.Started, jobs.Refusal) {
  jobs.start_job(
    name,
    strand: "main",
    operation: an_op(),
    request: jobs.Request(command: "tail -f build.log", wall_ms:),
    waiting: 10_000,
  )
}

// A jobs actor whose clearance goes through a *real* broker composing
// the session's real base policy.
//
// The helper pool is empty on purpose, and `AllBusy(size: 0)` is a
// hopeless pool rather than a congested one, so a clearance the policy
// admits comes straight back as `NoHelper`. Nothing here has to run a
// command: what the test needs to distinguish is which side of
// `policy.compose` a start lands on, and the two sides have different
// words.
fn start_over_a_real_broker() -> address.Address(jobs.Message) {
  let clock = counting_clock(1_756_000_000_000, 1)
  let runtime = open_runtime(clock)
  let spill = start_fake_spill()
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 1_756_000_000_000),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the real broker must start"

  let name = addresses.new()
  let assert Ok(_started) =
    jobs.start(
      name,
      wiring(
        runtime,
        spill,
        clock,
        tool.broker_runner(broker: broker_actor, waiting: 1000),
        1000,
        serve.base_policy("/workspace"),
      ),
    )
    as "the jobs actor must start"
  name
}

pub fn a_refused_clearance_reaches_the_starting_caller_test() {
  // The start is synchronous over the clearance, so a policy refusal
  // arrives in the broker's own words instead of on some later poll —
  // and the record goes with it, because nothing ran.
  let harness = start_harness()
  refuse_next(harness, broker.BrokerUnavailable)
  let answer = started_or_refused(harness, "main", "make", None)
  let assert Error(jobs.ClearanceRefused(reason:)) = answer
    as "a refused clearance is a refusal to the caller"
  assert string.contains(reason, "broker")

  let assert Ok(cells) =
    api.reserved_facts(harness.runtime, prefix: jobstate.key_prefix)
    as "the job namespace must be readable"
  assert cells == []

  // And the slot it briefly held is free again.
  assert result.is_ok(started_or_refused(harness, "main", "make", None))
}

pub fn a_starter_whose_runner_died_first_is_answered_test() {
  // The clearance runs on the runner, so a starting caller's reply
  // subject waits inside the job's custody until the runner has said
  // whether there is a job at all. A runner that dies before it can say
  // anything leaves nobody holding that promise: the weft outcome is the
  // only thing that reaches the actor, and it records the job lost.
  //
  // Answering there is what makes the refusal true and prompt. Without
  // it the caller waits out its whole budget and is told the actor did
  // not answer in time — a sentence about the actor, which is alive and
  // serving, rather than about the job.
  let clock = counting_clock(1_756_000_000_000, 1)
  let runtime = open_runtime(clock)
  let spill = start_fake_spill()
  let name = addresses.new()
  let assert Ok(_started) =
    jobs.start(
      name,
      wiring(
        runtime,
        spill,
        clock,
        fn(_spec, _events) { panic as "this runner dies before it clears" },
        5000,
        policy.workspace_default("/workspace"),
      ),
    )
    as "the jobs actor must start"

  let assert Error(jobs.Unavailable(reason:)) =
    jobs.start_job(
      name,
      strand: "main",
      operation: an_op(),
      request: jobs.Request(command: "sleep 999", wall_ms: None),
      waiting: 5000,
    )
    as "a start whose runner died is refused rather than left hanging"
  assert string.contains(reason, "the runner died before the clearance")
}

// --- output ---------------------------------------------------------------

pub fn a_poll_reports_what_arrived_since_the_cursor_test() {
  let harness = start_harness()
  let started = start_job(harness, "main", "tail -f build.log")

  emit(harness, started, "first line\n")
  let first = await_output(harness, "main", started, 11, 200)
  assert first.stdout.bytes == <<"first line\n":utf8>>
  assert first.stdout.dropped == 0

  emit(harness, started, "second line\n")
  let _both = await_output(harness, "main", started, 23, 200)
  let second =
    poll_from(
      harness,
      "main",
      started.id,
      jobs.Cursors(stdout: first.stdout.cursor, stderr: 0),
    )
  assert second.stdout.bytes == <<"second line\n":utf8>>
  assert second.stdout.cursor > first.stdout.cursor
}

pub fn the_tail_stays_bounded_under_a_flood_test() {
  // Twice the retained window in one chunk: the poll answers with the
  // window and says how much went past it, rather than growing to hold a
  // `tail -f` for a session.
  let harness = start_harness()
  let started = start_job(harness, "main", "yes")
  let flood = repeat_bytes(<<"0123456789abcdef":utf8>>, 1024)
  emit_bytes(harness, started, flood)

  let polled =
    await_output(harness, "main", started, bit_array.byte_size(flood), 200)
  assert bit_array.byte_size(polled.stdout.bytes) == jobs.tail_bytes
  assert polled.stdout.dropped == bit_array.byte_size(flood) - jobs.tail_bytes
  assert polled.stdout.cursor == bit_array.byte_size(flood)
}

pub fn the_spill_lands_content_addressed_past_the_cap_test() {
  // What the tail could not keep is still readable: the whole stream is
  // promoted to its content address and the ref rides in the terminal
  // fact, in the same commit as the terminal state.
  let harness = start_harness()
  let started = start_job(harness, "main", "yes")
  let flood = repeat_bytes(<<"0123456789abcdef":utf8>>, 1024)
  emit_bytes(harness, started, flood)

  // The poll is the barrier: a poll that has seen the chunk is served
  // from the runner's own tail, which the runner filled in the same step
  // it appended to the staging file — so the settlement below cannot
  // overtake the write it promotes.
  let _seen =
    await_output(harness, "main", started, bit_array.byte_size(flood), 200)
  settle_with(harness, started, exited(0))
  let assert jobstate.Exited(..) = settled_state(harness, "main", started)
    as "the job must finish"

  let record = record_in_store(harness, started.id)
  let assert Some(ref) = record.spill.stdout_ref as "stdout must have spilled"
  assert ref == blob.ref_for(flood)
  assert stored_body(harness, ref) == Ok(flood)
  assert record.spill.stderr_ref == None

  // The staging file is gone; the address is the only copy left.
  assert staged_paths(harness) == []
}

// --- settlement -----------------------------------------------------------

pub fn an_exit_is_recorded_with_its_result_test() {
  let harness = start_harness()
  let started = start_job(harness, "main", "make check")
  settle_with(harness, started, exited(2))

  let assert jobstate.Exited(result:) = settled_state(harness, "main", started)
    as "an ordinary end is an exit"
  assert result.code == 2

  // And durably, not only in the actor's memory.
  let record = record_in_store(harness, started.id)
  let assert jobstate.Exited(result: stored) = record.state
    as "the terminal state is committed"
  assert stored.code == 2
}

pub fn a_kill_climbs_the_ladder_test() {
  // Three things in order: the cancel reaches the broker, the record
  // reads `Draining(ByOwner)` while the ladder climbs, and the eventual
  // settlement becomes `Killed(ByOwner)` carrying the helper's own
  // `cancelled` witness.
  let harness = start_harness()
  let started = start_job(harness, "main", "sleep 999")
  assert cancels(harness, started) == 0

  let assert Ok(Nil) =
    jobs.kill_job(harness.name, strand: "main", id: started.id, waiting: 5000)
    as "the owner may always stop what it started"
  assert cancels(harness, started) == 1
  assert poll(harness, "main", started).state
    == jobstate.Draining(by: jobstate.ByOwner)

  settle_with(harness, started, cancelled_result())
  let assert jobstate.Killed(by:, result:) =
    settled_state(harness, "main", started)
    as "a stopped job is killed, not exited"
  assert by == jobstate.ByOwner
  assert result.cancelled
}

pub fn an_unasked_cancellation_is_the_operations_abort_test() {
  // The helper says it climbed the ladder and nothing here asked it to,
  // so `broker.abort` of the operation that started this job reached it.
  // That is the abort semantics the operation half of the ledger key
  // buys, and the only remaining explanation.
  let harness = start_harness()
  let started = start_job(harness, "main", "sleep 999")
  settle_with(harness, started, cancelled_result())

  let assert jobstate.Killed(by:, ..) = settled_state(harness, "main", started)
    as "an unasked cancellation is still a kill"
  assert by == jobstate.ByOperationAbort
}

pub fn a_deadline_kills_with_its_own_cause_test() {
  // The one test on the wall clock: a runner turns `deadline - now` into
  // a real receive window, so the deadline has to be real time.
  let harness = start_harness_on(wall_clock())
  let assert Ok(started) =
    started_or_refused(harness, "main", "sleep 999", Some(60))
    as "a short wall is admitted"

  // The runner's fold expires, tells the actor, and the record enters
  // `Draining(ByDeadline)` before the helper has answered anything.
  let drained = await_draining(harness, "main", started, 200)
  assert drained == jobstate.Draining(by: jobstate.ByDeadline)

  // The broker's relay cancels on the same number; the helper's report
  // is what says it climbed.
  settle_with(harness, started, cancelled_result())
  let assert jobstate.Killed(by:, result:) =
    settled_state(harness, "main", started)
    as "a job past its wall is killed by its deadline"
  assert by == jobstate.ByDeadline
  assert result.cancelled
}

fn await_draining(
  harness: Harness,
  strand: String,
  started: jobs.Started,
  attempts: Int,
) -> jobstate.JobState {
  let polled = poll(harness, strand, started)
  case polled.state, attempts <= 0 {
    jobstate.Draining(..), _more -> polled.state
    _live, True -> polled.state
    _live, False -> {
      process.sleep(5)
      await_draining(harness, strand, started, attempts - 1)
    }
  }
}

// --- the relay's last word ------------------------------------------------

pub fn a_finished_runners_last_word_is_selected_test() {
  // Every relay sends its outcome and then `AllDelivered`. Taking the
  // outcome is what detaches the job's custody, so a selector rebuilt from
  // the live set alone stops carrying that channel one message too early
  // and the second message is never matched by any receive — and an
  // unmatched message is never removed, only scanned past, for the rest of
  // the session.
  //
  // Nothing about the actor's answers can see this: it keeps answering
  // either way. So the assertion is the mailbox itself, after enough
  // finished jobs that a leak and an in-flight message cannot be confused.
  let harness = start_harness()
  list.repeat(Nil, 50)
  |> list.each(fn(_nth) {
    let started = start_job(harness, "main", "echo tick")
    settle_with(harness, started, exited(0))
    let assert jobstate.Exited(..) = settled_state(harness, "main", started)
      as "each job must finish before the next one starts"
  })

  // At most the last job's own `AllDelivered` may still be in flight; the
  // forty-nine before it were selected and consumed.
  assert mailbox_length(harness.pid) <= 2
}

// --- waiting --------------------------------------------------------------

pub fn a_wait_returns_pending_while_the_job_runs_test() {
  // Pending is a success, not a failure: a model that wants to block on a
  // job gets its live state back when the budget runs out, and the
  // terminal one when it does not.
  let harness = start_harness()
  let started = start_job(harness, "main", "sleep 999")
  let cursors = jobs.Cursors(stdout: 0, stderr: 0)
  let assert Ok(pending) =
    jobs.await_job(
      harness.name,
      strand: "main",
      id: started.id,
      cursors:,
      clock: wall_clock(),
      within_ms: 40,
      every: poll.Fixed(ms: 5),
      rest: process.sleep,
      waiting: 5000,
    )
    as "a still-running job is a successful answer"
  assert pending.state == jobstate.Running
  assert !jobstate.is_terminal(pending.state)

  settle_with(harness, started, exited(0))
  let assert Ok(finished) =
    jobs.await_job(
      harness.name,
      strand: "main",
      id: started.id,
      cursors:,
      clock: wall_clock(),
      within_ms: 2000,
      every: poll.Fixed(ms: 5),
      rest: process.sleep,
      waiting: 5000,
    )
    as "a finished job ends the wait"
  let assert jobstate.Exited(..) = finished.state as "and it is terminal"
}

// --- stdin ----------------------------------------------------------------

pub fn stdin_stays_open_until_it_is_closed_test() {
  // The difference between watching a log and driving a REPL: a
  // background job's stdin is not closed the moment it starts, the way a
  // foreground `bash` call's is.
  let harness = start_harness()
  let started = start_job(harness, "main", "cat")

  let assert Ok(Nil) =
    jobs.write_stdin(
      harness.name,
      strand: "main",
      id: started.id,
      data: <<"one\n":utf8>>,
      end: jobs.KeepStdinOpen,
      waiting: 5000,
    )
    as "a live job accepts stdin"
  let assert Ok(Nil) =
    jobs.write_stdin(
      harness.name,
      strand: "main",
      id: started.id,
      data: <<"two\n":utf8>>,
      end: jobs.CloseStdin,
      waiting: 5000,
    )
    as "and closing it is the caller's decision"
  assert stdins(harness, started)
    == [#(<<"one\n":utf8>>, False), #(<<"two\n":utf8>>, True)]
}

// --- ownership ------------------------------------------------------------

pub fn another_strands_job_is_not_found_test() {
  // One answer for two facts, so a strand guessing at a sibling's ids
  // learns nothing from which guesses were real.
  let harness = start_harness()
  let started = start_job(harness, "main", "sleep 999")
  let text = jobstate.job_id_to_string(started.id)

  assert jobs.poll_job(
      harness.name,
      strand: "sub:main/worker",
      id: started.id,
      cursors: jobs.Cursors(stdout: 0, stderr: 0),
      waiting: 5000,
    )
    == Error(jobs.NotFound(id: text))
  assert jobs.kill_job(
      harness.name,
      strand: "sub:main/worker",
      id: started.id,
      waiting: 5000,
    )
    == Error(jobs.NotFound(id: text))
  assert cancels(harness, started) == 0
}

pub fn a_listing_shows_only_the_callers_own_jobs_test() {
  let harness = start_harness()
  let _mine = start_job(harness, "main", "one")
  let _theirs = start_job(harness, "sub:main/worker", "two")

  let assert Ok(listed) =
    jobs.list_jobs(harness.name, strand: "main", waiting: 5000)
    as "a listing must answer"
  assert list.length(listed) == 1
}

// --- restart --------------------------------------------------------------

pub fn a_restart_declares_a_running_job_lost_test() {
  // Nothing in this design survives the VM, so recovery never re-adopts:
  // it sweeps `job/*` and records every live job as lost before it
  // serves one request. Never a respawn — the fake broker sees no second
  // clearance — and never a silent drop.
  let harness = start_harness()
  let started = start_job(harness, "main", "tail -f build.log")
  assert cleared_steps(harness) == [jobstate.job_key(started.id)]

  // A staging file with no live job, planted the way a lost runner would
  // have left one behind.
  plant_staging(harness, "/blobs/.job-orphan.stdout.tmp", "half a log")

  let second = addresses.new()
  let assert Ok(_replacement) =
    jobs.start(
      second,
      fake_wiring(
        harness.runtime,
        harness.fake,
        harness.spill,
        counting_clock(1_756_000_100_000, 1),
      ),
    )
    as "the replacement actor must start"

  // The sweep is an injected `continuing`, which weft guarantees runs
  // before any external message — so a listing answered by the
  // replacement is proof the sweep is already complete. `start`
  // returning is not: the acknowledgement is released before the
  // injected queue drains.
  let assert Ok(listed) = jobs.list_jobs(second, strand: "main", waiting: 5000)
    as "the replacement must answer, which proves it swept first"

  // The store first, because the sweep's whole job is the durable record
  // and everything below is read back from it.
  let record = record_in_store(harness, started.id)
  assert record.state == jobstate.Lost(reason: jobstate.VmRestart)
  assert cleared_steps(harness) == [jobstate.job_key(started.id)]
  assert staged_paths(harness) == []

  // And the same answer through the door, which is the only one a model
  // ever gets. A sweep that wrote the store and kept nothing would answer
  // this poll `NotFound` — the sentence for a job that never existed —
  // and would leave the listing empty.
  let assert Ok(polled) =
    jobs.poll_job(
      second,
      strand: "main",
      id: started.id,
      cursors: jobs.Cursors(0, 0),
      waiting: 5000,
    )
    as "a job the restart reaped is still this strand's to poll"
  assert polled.state == jobstate.Lost(reason: jobstate.VmRestart)
  assert list.map(listed, fn(row) { row.id }) == [started.id]
}

pub fn a_terminal_record_survives_a_restart_unchanged_test() {
  // The sweep skips what is already terminal, so a job that exited before
  // the restart keeps its result rather than being relabelled lost.
  let harness = start_harness()
  let started = start_job(harness, "main", "make check")
  settle_with(harness, started, exited(7))
  let assert jobstate.Exited(..) = settled_state(harness, "main", started)
    as "the job must finish first"

  let second = addresses.new()
  let assert Ok(_replacement) =
    jobs.start(
      second,
      fake_wiring(
        harness.runtime,
        harness.fake,
        harness.spill,
        counting_clock(1_756_000_100_000, 1),
      ),
    )
    as "the replacement actor must start"

  // The sweep is an injected `continuing`, which weft guarantees runs
  // before any external message — so a listing answered by the
  // replacement is proof the sweep is already complete. `start`
  // returning is not: the acknowledgement is released before the
  // injected queue drains.
  let assert Ok(_listed) = jobs.list_jobs(second, strand: "main", waiting: 5000)
    as "the replacement must answer, which proves it swept first"

  let assert jobstate.Exited(result:) =
    record_in_store(harness, started.id).state
    as "a terminal record is not swept"
  assert result.code == 7
}

// --- session stop ---------------------------------------------------------

pub fn a_session_stop_kills_every_live_job_test() {
  // The teardown this exercises is the only one there is: a supervisor's
  // `shutdown` exit reaching an actor that traps exits, which weft turns
  // into `on_shutdown`. There is no message asking for the same thing, so
  // a test that sent one would be proving a path production never takes.
  let harness = start_harness()
  let first = start_job(harness, "main", "sleep 999")
  let second = start_job(harness, "sub:main/worker", "sleep 999")

  // Trapping is what keeps this process alive: the actor exits with the
  // reason it was shut down with, and the link would otherwise carry that
  // straight into the test. The monitor is the barrier at the end.
  process.trap_exits(True)
  let gone = process.monitor(harness.pid)
  process.send_abnormal_exit(harness.pid, "shutdown")

  // The shutdown cancels and then waits, so the settlements have
  // somewhere to land. Waiting for the cancel to be *observed* is the
  // barrier here: the cancel travels actor -> fake broker while this test
  // travels test -> fake broker, and nothing orders the two.
  assert await_cancel(harness, first, 200) == 1
  assert await_cancel(harness, second, 200) == 1

  // A job that settles inside the grace is `Killed(BySessionStop)`, and
  // the actor's own death is the proof that its drain has finished and
  // every commit it was going to make has been made.
  settle_with(harness, first, cancelled_result())
  settle_with(harness, second, cancelled_result())
  let assert Ok(_down) =
    process.selector_receive(
      process.new_selector()
        |> process.select_specific_monitor(gone, fn(down) { down }),
      5000,
    )
    as "the actor must finish its drain and go"
  process.trap_exits(False)

  let assert jobstate.Killed(by: first_cause, ..) =
    record_in_store(harness, first.id).state
    as "a job cancelled by the session stop is killed"
  assert first_cause == jobstate.BySessionStop

  let assert jobstate.Killed(by: second_cause, ..) =
    record_in_store(harness, second.id).state
    as "and so is every other strand's"
  assert second_cause == jobstate.BySessionStop
}

fn await_cancel(harness: Harness, started: jobs.Started, attempts: Int) -> Int {
  let seen = cancels(harness, started)
  case seen > 0 || attempts <= 0 {
    True -> seen
    False -> {
      process.sleep(5)
      await_cancel(harness, started, attempts - 1)
    }
  }
}

// --- the operator's table -------------------------------------------------

pub fn the_jobs_table_raises_the_wall_ceiling_test() {
  assert jobs.parse_policy("") == Ok(jobs.default_policy)
  assert jobs.parse_policy("[jobs]\nmax_wall = 86400\n")
    == Ok(jobs.JobsPolicy(max_wall_ms: 86_400_000))

  // The clamp only ever goes up: a shorter ceiling is what the session's
  // own sandbox policy already expresses, and two of them could disagree.
  assert jobs.parse_policy("[jobs]\nmax_wall = 60\n") == Ok(jobs.default_policy)
}

pub fn an_unknown_jobs_key_is_refused_test() {
  let assert Error(reason) = jobs.parse_policy("[jobs]\nmax_walls = 10\n")
    as "a typo is a refusal, not a default"
  assert string.contains(reason, "max_walls")
}

// --- helpers --------------------------------------------------------------

fn repeat_bytes(chunk: BitArray, times: Int) -> BitArray {
  list.repeat(chunk, times) |> bit_array.concat
}
