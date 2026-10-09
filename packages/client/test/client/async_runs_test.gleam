//// Host-side async execution contracts at the durable boundary.
////
//// These tests keep the satellite out of the fixture. They exercise the
//// session-owned service directly so readiness, admission, progress, idle
//// closure, and cumulative limits are proved independently of compilation.

import client/agency
import client/async_codemode
import client/async_runs
import client/notice
import client/owner_services
import client/remote/owner_port
import client/remote/protocol
import core/clock.{type Clock}
import core/ids
import core/json
import core/message
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/async_execution
import runtime/effects
import session/session
import support/addresses
import support/owner_probe
import tools/directory_access
import weft/actor
import weft/poll
import weft/registry as address

type TimeMessage {
  ReadTime(reply: Subject(Int))
  Advance(by: Int)
}

type Harness {
  Harness(runtime: api.Runtime, clock: Clock, time: Subject(TimeMessage))
}

pub fn send_requires_ready_and_an_exact_endpoint_test() {
  let harness = start_harness()
  let #(name, service, record) = start_execution(harness, "a1")

  let assert Error(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.SendTo("control", json.Int(1)),
      0,
    )
    as "setup must finish before input admission"
  assert async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Ready(["control"], 30_000),
      0,
    )
    == Ok(json.Null)
  let assert Error(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.SendTo("other", json.Int(1)),
      0,
    )
    as "an unregistered endpoint must be refused"
  assert async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.SendTo("control", json.Int(2)),
      0,
    )
    == Ok(json.Int(1))
  assert async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.ReceiveEnveloped(0),
      0,
    )
    == Ok(
      json.Object([
        #("sequence", json.Int(1)),
        #("endpoint", json.String("control")),
        #("value", json.Int(2)),
      ]),
    )
  let assert Ok(Nil) =
    api.put_reserved_fact(
      harness.runtime,
      async_execution.abort_key(record.operation),
      json.Null,
    )
  let assert Error(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.SendTo("control", json.Int(3)),
      0,
    )
    as "a visible operation fence must refuse journal admission"

  stop(service)
  close_harness(harness)
}

pub fn progress_coalesces_and_delivery_keeps_only_the_latest_test() {
  let harness = start_harness()
  let #(name, service, record) = start_execution(harness, "a2")
  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Ready(["control"], 30_000),
      0,
    )

  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Progress(json.String("first")),
      0,
    )
  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Progress(json.String("latest")),
      0,
    )
  advance(harness.time, 101)
  let assert Ok(checked) =
    async_runs.interact(name, "main", record.id, async_runs.Check, 0)
  let assert json.Object(fields) = checked
  let assert Ok(json.Object(progress)) = list.key_find(fields, "progress")
  assert list.key_find(progress, "sequence") == Ok(json.Int(2))
  assert list.key_find(progress, "updated_ms")
    == Ok(json.Int(now(harness.time)))
  assert list.key_find(progress, "value") == Ok(json.String("latest"))
  let assert Ok(json.Object(ack)) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Progress(json.String("pending again")),
      0,
    )
  assert list.key_find(ack, "sequence") == Ok(json.Int(2))
    as "a publication inside 100 ms must remain coalesced"
  advance(harness.time, 100)
  let assert Ok(json.Object(fields)) =
    async_runs.interact(name, "main", record.id, async_runs.Check, 0)
  let assert Ok(json.Object(progress)) = list.key_find(fields, "progress")
  assert list.key_find(progress, "sequence") == Ok(json.Int(3))
  assert list.key_find(progress, "value") == Ok(json.String("pending again"))

  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Delivery(
        sequence: 1,
        endpoint: "control",
        outcome: async_runs.Rejected("bad payload"),
      ),
      0,
    )
  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Delivery(
        sequence: 2,
        endpoint: "control",
        outcome: async_runs.Delivered,
      ),
      0,
    )
  let assert Ok(json.Object(fields)) =
    async_runs.interact(name, "main", record.id, async_runs.Check, 0)
  let assert Ok(json.Object(delivery)) =
    list.key_find(fields, "latest_delivery")
  assert list.key_find(delivery, "sequence") == Ok(json.Int(2))
  assert list.key_find(delivery, "status") == Ok(json.String("delivered"))

  stop(service)
  close_harness(harness)
}

pub fn typed_idle_expiry_closes_admission_and_cancels_the_worker_test() {
  let harness = start_harness()
  let aborted = process.new_subject()
  let workers = process.new_subject()
  let #(name, service, record) =
    start_execution_observed(
      harness,
      "a3",
      fn(operation, step) { process.send(aborted, #(operation, step)) },
      Some(workers),
    )
  let assert Ok(worker) = process.receive(workers, 1000)
  let worker_down = process.monitor(worker)
  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Ready(["control"], 10),
      0,
    )
  advance(harness.time, 11)

  assert async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.ReceiveEnveloped(0),
      0,
    )
    == Ok(json.Object([#("idle", json.Bool(True))]))
  let assert Error(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.SendTo("control", json.Int(1)),
      0,
    )
    as "idle expiry must fence later sends"
  assert process.receive(aborted, 1000) == Ok(#(record.operation, record.step))
    as "idle expiry must abort the original broker step before teardown"
  let assert Ok(value) =
    async_runs.interact(name, "main", record.id, async_runs.Check, 2000)
    as "the cancelled worker must drain to its durable idle outcome"
  let assert Ok(done) = async_execution.decode(value)
  assert done.phase == async_execution.Lost("execution idle timeout")
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(worker_down, fn(down) { down })
    |> process.selector_receive(1000)
    as "the idle worker must be down before service teardown"

  stop(service)
  close_harness(harness)
}

pub fn only_successful_delivery_resets_the_typed_idle_interval_test() {
  let harness = start_harness()
  let #(name, service, record) = start_execution(harness, "a4")
  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Ready(["control"], 10),
      0,
    )
  advance(harness.time, 9)
  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Progress(json.String("still working")),
      0,
    )
  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Delivery(
        sequence: 1,
        endpoint: "control",
        outcome: async_runs.Rejected("bad payload"),
      ),
      0,
    )
  advance(harness.time, 2)
  assert async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.ReceiveEnveloped(0),
      0,
    )
    == Ok(json.Object([#("idle", json.Bool(True))]))
  stop(service)

  let #(name, service, record) = start_execution(harness, "a5")
  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Ready(["control"], 10),
      0,
    )
  advance(harness.time, 9)
  let assert Ok(_) =
    async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.Delivery(
        sequence: 1,
        endpoint: "control",
        outcome: async_runs.Delivered,
      ),
      0,
    )
  advance(harness.time, 9)
  assert async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.ReceiveEnveloped(0),
      0,
    )
    == Ok(json.Null)
  advance(harness.time, 2)
  assert async_runs.interact(
      name,
      "main",
      record.id,
      async_runs.ReceiveEnveloped(0),
      0,
    )
    == Ok(json.Object([#("idle", json.Bool(True))]))
  stop(service)
  close_harness(harness)
}

pub fn the_service_labels_itself_with_its_session_test() {
  let harness = start_harness()
  let assert Ok(service) =
    async_runs.start(
      addresses.new(),
      async_runs.Wiring(
        runtime: harness.runtime,
        clock: harness.clock,
        abort: fn(_, _) { Nil },
        heartbeat_ms: 0,
        surviving_value: async_runs.no_value_survives,
      ),
    )
  let session = ids.session_id_to_string(api.session_id(harness.runtime))
  assert owner_probe.label_of(service.pid)
    == Some(#([#("session", session)], "async_runs"))
  stop(service.pid)
  close_harness(harness)
}

pub fn cumulative_launch_limit_survives_settlement_and_retry_test() {
  let harness = start_harness()
  let name = addresses.new()
  let assert Ok(service) =
    async_runs.start(
      name,
      async_runs.Wiring(
        runtime: harness.runtime,
        clock: harness.clock,
        abort: fn(_, _) { Nil },
        heartbeat_ms: 0,
        surviving_value: async_runs.no_value_survives,
      ),
    )
  let #(operation, _) = ids.mint_op(ids.generator(harness.clock, seed: 23))
  let records = launch_records(harness, operation, 1, [])
  list.each(records, fn(record) {
    let assert Ok(_) = async_runs.launch(name, record, fn() { json.Null })
      as "each launch through the cumulative ceiling must be admitted"
    let assert Ok(value) =
      async_runs.interact(name, "main", record.id, async_runs.Check, 2000)
      as "settlement must free the live slot"
    let assert Ok(done) = async_execution.decode(value)
    assert async_execution.terminal(done.phase)
  })
  stop(service.pid)
  let recovered_name = addresses.new()
  let assert Ok(recovered_service) =
    async_runs.start(
      recovered_name,
      async_runs.Wiring(
        runtime: harness.runtime,
        clock: harness.clock,
        abort: fn(_, _) { Nil },
        heartbeat_ms: 0,
        surviving_value: async_runs.no_value_survives,
      ),
    )
  let assert Ok(first) = list.first(records)
  let assert Ok(_) =
    async_runs.launch(recovered_name, first, fn() {
      panic as "a same-handle retry must not replay work"
    })
    as "same-handle retry remains inspectable after recovery at the ceiling"
  let overflow = execution_record(harness, operation, "33")
  let assert Error(_) =
    async_runs.launch(recovered_name, overflow, fn() { json.Null })
    as "recovered settled executions still consume the cumulative budget"

  stop(recovered_service.pid)
  close_harness(harness)
}

pub fn admitted_background_lifetimes_can_overlap_test() {
  let harness = start_harness()
  let #(name, service, first) = start_execution(harness, "b1")
  let second = execution_record(harness, first.operation, "b2")
  let assert Ok(_) =
    async_runs.launch(name, second, fn() {
      process.sleep_forever()
      json.Null
    })

  let assert Ok(first_value) =
    async_runs.interact(name, "main", first.id, async_runs.Check, 0)
  let assert Ok(second_value) =
    async_runs.interact(name, "main", second.id, async_runs.Check, 0)
  let assert Ok(first_record) = async_execution.decode(first_value)
  let assert Ok(second_record) = async_execution.decode(second_value)
  assert first_record.phase == async_execution.Running
  assert second_record.phase == async_execution.Running

  stop(service)
  close_harness(harness)
}

fn launch_records(
  harness: Harness,
  operation: ids.OpId,
  next: Int,
  records: List(async_execution.Execution),
) -> List(async_execution.Execution) {
  case next > 32 {
    True -> list.reverse(records)
    False ->
      launch_records(harness, operation, next + 1, [
        execution_record(harness, operation, int.to_string(next)),
        ..records
      ])
  }
}

fn start_execution(
  harness: Harness,
  id: String,
) -> #(
  address.Address(async_runs.Message),
  process.Pid,
  async_execution.Execution,
) {
  start_execution_observed(harness, id, fn(_, _) { Nil }, None)
}

fn start_execution_observed(
  harness: Harness,
  id: String,
  abort: fn(ids.OpId, String) -> Nil,
  workers: Option(Subject(process.Pid)),
) -> #(
  address.Address(async_runs.Message),
  process.Pid,
  async_execution.Execution,
) {
  let name = addresses.new()
  let assert Ok(service) =
    async_runs.start(
      name,
      async_runs.Wiring(
        runtime: harness.runtime,
        clock: harness.clock,
        abort:,
        heartbeat_ms: 0,
        surviving_value: async_runs.no_value_survives,
      ),
    )
  let #(operation, _) = ids.mint_op(ids.generator(harness.clock, seed: 19))
  let record = execution_record(harness, operation, id)
  let assert Ok(_) =
    async_runs.launch(name, record, fn() {
      case workers {
        Some(workers) -> process.send(workers, process.self())
        None -> Nil
      }
      process.sleep_forever()
      json.Null
    })
  #(name, service.pid, record)
}

fn execution_record(
  harness: Harness,
  operation: ids.OpId,
  id: String,
) -> async_execution.Execution {
  async_execution.Execution(
    id:,
    strand: "main",
    operation:,
    step: "async/" <> id,
    deadline_ms: now(harness.time) + 60_000,
    source: "test program",
    seam: "workspace",
    phase: async_execution.Starting,
    launch: option.None,
  )
}

fn start_harness() -> Harness {
  let assert Ok(timer) =
    actor.new(1_756_000_000_000)
    |> actor.on_message(fn(time, message: TimeMessage) {
      case message {
        ReadTime(reply) -> {
          process.send(reply, time)
          actor.continue(time)
        }
        Advance(by) -> actor.continue(time + by)
      }
    })
    |> actor.start
  let clock = clock.from_function(fn() { now(timer.data) })
  let assert Ok(sess) = session.open_memory(clock)
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: ["code_mode"],
    )
  let base = api.default_options(configuration)
  let assert Ok(runtime) =
    api.open(
      sess,
      effects.Effects(
        clock:,
        entropy: fn() { 7_000_000 },
        timers: effects.real_timers(),
        provider: effects.ProviderSurface(timeout_ms: 60_000, request: fn(_) {
          stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
        }),
        tools: effects.ToolSurface(
          clear: fn(_) {
            effects.ClearanceRefused(reason: "no tools in this harness")
          },
          run: fn(_) { effects.ToolFailed(reason: "no tools") },
          replay_still_safe: fn(_) { False },
          execution_mode: fn(_) { effects.ExclusiveExecution },
          recover: None,
        ),
        hooks: effects.default_hooks(),
      ),
      api.Options(
        ..base,
        poll_interval_ms: 25,
        idle_poll_interval_ms: 25,
        subagent: agency.is_subagent,
      ),
    )
  Harness(runtime:, clock:, time: timer.data)
}

fn now(time: Subject(TimeMessage)) -> Int {
  process.call(time, waiting: 1000, sending: ReadTime)
}

fn advance(time: Subject(TimeMessage), by: Int) -> Nil {
  process.send(time, Advance(by:))
}

fn stop(pid: process.Pid) -> Nil {
  process.unlink(pid)
  process.kill(pid)
}

fn close_harness(harness: Harness) -> Nil {
  let assert Ok(Nil) = api.close(harness.runtime)
  let assert Ok(timer) = process.subject_owner(harness.time)
  process.unlink(timer)
  process.kill(timer)
}

// --- telling the launcher -------------------------------------------------
//
// A settled execution's end is sent to the strand that launched it, unless
// somebody chose that end. These tests read the reserved mark the notice
// spends in the same transaction as its admission, and the launcher's
// projected context, which is what the model reads.

fn launch(
  harness: Harness,
  id: String,
  heartbeat_ms: Int,
  work: fn() -> json.JsonValue,
) -> #(address.Address(async_runs.Message), process.Pid) {
  let name = addresses.new()
  let assert Ok(service) =
    async_runs.start(
      name,
      async_runs.Wiring(
        runtime: harness.runtime,
        clock: harness.clock,
        abort: fn(_, _) { Nil },
        heartbeat_ms:,
        surviving_value: async_runs.no_value_survives,
      ),
    )
  let #(operation, _) = ids.mint_op(ids.generator(harness.clock, seed: 23))
  let record =
    async_execution.Execution(
      ..execution_record(harness, operation, id),
      deadline_ms: now(harness.time) + 3_600_000,
    )
  let assert Ok(_) = async_runs.launch(name, record, work)
  #(name, service.pid)
}

// Whether the completion notice for `id` was delivered: the mark lands in
// the admission's own commit, so its presence is the delivery.
fn notified(harness: Harness, id: String) -> Bool {
  case api.fact(harness.runtime, notice.key(notice.Execution(id:))) {
    Ok(Some(_mark)) -> True
    Ok(None) | Error(_) -> False
  }
}

// The service settles an execution on its own 100 ms sweep, so a test
// waits on what that sweep writes rather than on a guessed interval.
fn await_phase(
  harness: Harness,
  id: String,
  attempts: Int,
) -> async_execution.Phase {
  let phase = case api.fact(harness.runtime, async_execution.key(id)) {
    Ok(Some(cell)) ->
      case async_execution.decode(cell) {
        Ok(record) -> record.phase
        Error(_) -> async_execution.Starting
      }
    Ok(None) | Error(_) -> async_execution.Starting
  }
  case phase, attempts <= 0 {
    async_execution.Finished(_), _ | async_execution.Lost(_), _ | _, True ->
      phase
    _, False -> {
      process.sleep(20)
      await_phase(harness, id, attempts - 1)
    }
  }
}

// Waits for the completion notice's mark rather than for the phase that
// precedes it: the sweep saves the terminal record before it tells the
// launcher, so the two are written by one process in that order but are
// not one observation for a reader in another process.
fn await_notified(harness: Harness, id: String) -> Bool {
  case
    poll.until(within: 15_000, every: 20, attempt: fn() {
      case notified(harness, id) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  {
    poll.Answered(Nil) -> True
    _ -> False
  }
}

fn context_text(harness: Harness, strand: String) -> String {
  let leaf = case session.strand_leaf(harness.runtime.session, strand) {
    Ok(Some(session.Cell(value: leaf, ..))) -> leaf
    Ok(None) | Error(_reason) -> None
  }
  case session.project_context(harness.runtime.session, leaf) {
    Ok(messages) -> messages |> list.map(user_text) |> string.join("\n")
    Error(_reason) -> ""
  }
}

fn user_text(item: message.AgentMessage) -> String {
  case item {
    message.UserMessage(content:, ..) ->
      content
      |> list.filter_map(fn(block) {
        case block {
          message.UserText(text:, ..) -> Ok(text)
          message.UserImage(..) -> Error(Nil)
        }
      })
      |> string.join("\n")
    _other -> ""
  }
}

pub fn a_finished_execution_is_sent_to_its_launcher_test() {
  let harness = start_harness()
  let #(_name, service) =
    launch(harness, "f1", 0, fn() { json.String("review complete") })
  assert await_notified(harness, "f1") as "the launcher must be told"

  // The sweep saves the terminal phase and only then delivers the notice,
  // so another process can read `Finished` before the mark exists. The
  // mark is the event under test, and it lands in the admission's own
  // commit, so the projected context below is readable once it is there.
  let assert async_execution.Finished(_) = await_phase(harness, "f1", 0)
    as "the execution must be recorded finished"
  let text = context_text(harness, "main")
  assert string.contains(text, "[loom] async code-mode execution f1 finished")
  assert string.contains(text, "review complete")
  stop(service)
  close_harness(harness)
}

pub fn a_cancelled_execution_is_not_announced_test() {
  // The owner asked for the end, so it is nothing the owner does not know.
  let harness = start_harness()
  let #(name, service) =
    launch(harness, "c1", 0, fn() {
      process.sleep_forever()
      json.Null
    })
  let assert Ok(_) =
    async_runs.interact(name, "main", "c1", async_runs.Cancel, 0)
    as "the owner may cancel its execution"
  let assert async_execution.Lost(_) = await_phase(harness, "c1", 150)
    as "a cancelled execution is recorded lost"
  assert !notified(harness, "c1")
  stop(service)
  close_harness(harness)
}

pub fn an_idle_launcher_of_a_live_execution_is_woken_test() {
  // The first sample starts the owner's idle stretch and schedules the
  // next a minute on; advancing the clock past it makes the second sample
  // find a whole interval gone.
  let harness = start_harness()
  let #(_name, service) =
    launch(harness, "b1", 1, fn() {
      process.sleep_forever()
      json.Null
    })
  process.sleep(250)
  assert !string.contains(context_text(harness, "main"), "idle heartbeat")
  advance(harness.time, notice.heartbeat_tick_ms + 1)
  let text = await_context(harness, "idle heartbeat", 100)
  assert string.contains(text, "[loom] idle heartbeat")
  assert string.contains(text, "async execution b1")
  stop(service)
  close_harness(harness)
}

// Each retry moves the clock another sample interval on, so the next
// sweep samples again and a first sample that landed late costs one more
// retry rather than a missed heartbeat.
fn await_context(harness: Harness, needle: String, attempts: Int) -> String {
  let text = context_text(harness, "main")
  case string.contains(text, needle) || attempts <= 0 {
    True -> text
    False -> {
      advance(harness.time, notice.heartbeat_tick_ms + 1)
      process.sleep(150)
      await_context(harness, needle, attempts - 1)
    }
  }
}

// --- executions whose program runs on another node ---------------------------------

fn service_with(
  harness: Harness,
  abort: fn(ids.OpId, String) -> Nil,
  surviving_value: fn(async_execution.Execution) -> Result(json.JsonValue, Nil),
) -> #(address.Address(async_runs.Message), process.Pid) {
  let name = addresses.new()
  let assert Ok(service) =
    async_runs.start(
      name,
      async_runs.Wiring(
        runtime: harness.runtime,
        clock: harness.clock,
        abort:,
        heartbeat_ms: 0,
        surviving_value:,
      ),
    )
  #(name, service.pid)
}

fn phase_of(harness: Harness, id: String) -> async_execution.Phase {
  let assert Ok(Some(record)) = async_runs.record(harness.runtime, id)
    as "the record is readable"
  record.phase
}

fn settles(harness: Harness, id: String, phase: async_execution.Phase) -> Bool {
  poll.until(within: 5000, every: 20, attempt: fn() {
    case async_runs.record(harness.runtime, id) {
      Ok(Some(record)) if record.phase == phase -> poll.Done(Nil)
      _ -> poll.Retry
    }
  })
  == poll.Answered(Nil)
}

pub fn a_worker_that_knows_why_it_failed_records_that_reason_test() {
  let harness = start_harness()
  let #(name, pid) =
    service_with(harness, fn(_, _) { Nil }, async_runs.no_value_survives)
  let #(operation, _) = ids.mint_op(ids.generator(harness.clock, seed: 41))
  let record = execution_record(harness, operation, "c1")
  let assert Ok(_) =
    async_runs.launch_fallible(name, record, fn() {
      Error("the executor restarted")
    })
  assert settles(harness, "c1", async_execution.Lost("the executor restarted"))
  stop(pid)
}

pub fn recovery_keeps_a_value_that_outlived_the_service_test() {
  let harness = start_harness()
  let #(operation, _) = ids.mint_op(ids.generator(harness.clock, seed: 43))
  let record =
    async_execution.Execution(
      ..execution_record(harness, operation, "c2"),
      phase: async_execution.Running,
    )
  let assert Ok(_) =
    api.put_reserved_fact(
      harness.runtime,
      async_execution.key(record.id),
      async_execution.encode(record),
    )
  let aborted = process.new_subject()
  let #(_name, pid) =
    service_with(
      harness,
      fn(operation, step) { process.send(aborted, #(operation, step)) },
      fn(found) {
        case found.id {
          "c2" -> Ok(json.String("finished on the executor"))
          _ -> Error(Nil)
        }
      },
    )

  // The program finished on the executor before the old service could hear
  // it. Its stored value is the result, and nothing is stopped.
  assert settles(
    harness,
    "c2",
    async_execution.Finished(json.String("finished on the executor")),
  )
  assert process.receive(aborted, 100) == Error(Nil)
  stop(pid)
}

pub fn recovery_without_a_value_records_the_loss_and_stops_the_program_test() {
  let harness = start_harness()
  let #(operation, _) = ids.mint_op(ids.generator(harness.clock, seed: 47))
  let record =
    async_execution.Execution(
      ..execution_record(harness, operation, "c3"),
      phase: async_execution.Running,
    )
  let assert Ok(_) =
    api.put_reserved_fact(
      harness.runtime,
      async_execution.key(record.id),
      async_execution.encode(record),
    )
  let aborted = process.new_subject()
  let #(_name, pid) =
    service_with(
      harness,
      fn(operation, step) { process.send(aborted, #(operation, step)) },
      async_runs.no_value_survives,
    )
  assert settles(
    harness,
    "c3",
    async_execution.Lost("execution service restarted"),
  )
  assert process.receive(aborted, 1000) == Ok(#(operation, "async/c3"))
  stop(pid)
}

pub fn a_draining_record_is_lost_on_recovery_even_if_a_value_survives_test() {
  let harness = start_harness()
  let #(operation, _) = ids.mint_op(ids.generator(harness.clock, seed: 53))
  let record =
    async_execution.Execution(
      ..execution_record(harness, operation, "c4"),
      phase: async_execution.Draining,
    )
  let assert Ok(_) =
    api.put_reserved_fact(
      harness.runtime,
      async_execution.key(record.id),
      async_execution.encode(record),
    )

  // A draining record had been told to stop; a value the program stored after
  // that does not undo the decision.
  let #(_name, pid) =
    service_with(harness, fn(_, _) { Nil }, fn(_found) {
      Ok(json.String("too late"))
    })
  assert settles(
    harness,
    "c4",
    async_execution.Lost("execution service restarted"),
  )
  assert phase_of(harness, "c4")
    == async_execution.Lost("execution service restarted")
  stop(pid)
}

// A host link that answers a start as `answer` says, and records what it was
// asked.
fn link_answering(
  answer: fn(protocol.Key, Int) -> protocol.ExecutionAnswer,
  asked: Subject(#(protocol.Key, Int)),
) -> owner_port.HostLink {
  owner_port.HostLink(
    list: fn() { Error("not asked") },
    ack: fn(_key) { Nil },
    start: fn(key, _terms, remaining_ms) {
      process.send(asked, #(key, remaining_ms))
      answer(key, remaining_ms)
    },
    stop: fn(_key) { Nil },
    query: fn(_key) { Error("not asked") },
  )
}

fn remote_terms(
  harness: Harness,
) -> #(ids.OpId, owner_services.ExecutionTerms) {
  let #(operation, _) = ids.mint_op(ids.generator(harness.clock, seed: 59))
  #(
    operation,
    owner_services.ExecutionTerms(
      strand: "main",
      op_id: operation,
      launch_step: "turn-4:tools",
      source_index: 1,
      source: "pub fn main() { Nil }",
      seam: "orchestration",
      within_ms: 60_000,
      access: directory_access.none(),
      grants: [],
    ),
  )
}

pub fn a_remote_launch_claims_the_record_and_its_worker_starts_the_program_test() {
  let harness = start_harness()
  let #(name, pid) =
    service_with(harness, fn(_, _) { Nil }, async_runs.no_value_survives)
  let executions =
    async_codemode.remote(
      name,
      runtime: fn() { Ok(harness.runtime) },
      clock: harness.clock,
      session: "s1",
    )
  let asked = process.new_subject()
  let link =
    link_answering(
      fn(_key, _remaining) {
        protocol.ExecutionFinished(json.String("the program's value"))
      },
      asked,
    )
  let #(operation, terms) = remote_terms(harness)
  let assert Ok(handle) = executions.launch(terms, link)
    as "the launch is claimed"
  let assert Ok(json.String(id)) = field_of(handle, "id")
    as "the handle names the execution"

  // The record carries the launching call, and its worker started the program
  // under the execution's own key with the time the record allows.
  let assert Ok(Some(record)) = async_runs.record(harness.runtime, id)
  assert record.launch
    == Some(async_execution.Launch(step: "turn-4:tools", source_index: 1))
  let assert Ok(#(key, remaining)) = process.receive(asked, 5000)
    as "the worker sent the start"
  assert key == protocol.execution_key("s1", operation, id)
  assert remaining > 0 && remaining <= 60_000
  assert settles(
    harness,
    id,
    async_execution.Finished(json.String("the program's value")),
  )

  // The reconciler now reads the record as closed, so the row may go.
  assert executions.standing(key) == owner_port.RecordClosed
  stop(pid)
}

pub fn a_remote_execution_the_executor_lost_is_recorded_lost_test() {
  let harness = start_harness()
  let #(name, pid) =
    service_with(harness, fn(_, _) { Nil }, async_runs.no_value_survives)
  let executions =
    async_codemode.remote(
      name,
      runtime: fn() { Ok(harness.runtime) },
      clock: harness.clock,
      session: "s1",
    )
  let link =
    link_answering(
      fn(_key, _remaining) { protocol.ExecutionLost },
      process.new_subject(),
    )
  let #(_operation, terms) = remote_terms(harness)
  let assert Ok(handle) = executions.launch(terms, link)
  let assert Ok(json.String(id)) = field_of(handle, "id")
  assert poll.until(within: 5000, every: 20, attempt: fn() {
      case phase_of(harness, id) {
        async_execution.Lost(reason) ->
          case string.contains(reason, "may have done part of its work") {
            True -> poll.Done(Nil)
            False -> poll.Fail(reason)
          }
        _ -> poll.Retry
      }
    })
    == poll.Answered(Nil)
  stop(pid)
}

pub fn a_running_remote_execution_stands_live_and_an_unknown_key_closed_test() {
  let harness = start_harness()
  let #(name, pid) =
    service_with(harness, fn(_, _) { Nil }, async_runs.no_value_survives)
  let executions =
    async_codemode.remote(
      name,
      runtime: fn() { Ok(harness.runtime) },
      clock: harness.clock,
      session: "s1",
    )
  let held = process.new_subject()
  let link =
    link_answering(
      fn(_key, _remaining) {
        let release = process.new_subject()
        process.send(held, release)
        let _waited = process.receive(release, 30_000)
        protocol.ExecutionFinished(json.Null)
      },
      process.new_subject(),
    )
  let #(operation, terms) = remote_terms(harness)
  let assert Ok(handle) = executions.launch(terms, link)
  let assert Ok(json.String(id)) = field_of(handle, "id")
  let assert Ok(release) = process.receive(held, 5000)
  let key = protocol.execution_key("s1", operation, id)
  assert executions.standing(key) == owner_port.RecordLive
  assert executions.standing(protocol.execution_key("s1", operation, "ffff"))
    == owner_port.RecordClosed
  assert executions.standing(protocol.Key("s1", "op", "turn-1:tools", 0))
    == owner_port.RecordClosed
  process.send(release, Nil)
  stop(pid)
}

fn field_of(
  value: json.JsonValue,
  name: String,
) -> Result(json.JsonValue, Nil) {
  case value {
    json.Object(fields) -> list.key_find(fields, name)
    _ -> Error(Nil)
  }
}
