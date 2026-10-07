import broker/exec
import broker/framing
import broker/support/bench_host
import broker/support/fake_helper
import core/msgpack
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import weft
import weft/poll

// Whether the helper's hello announces a bwrap jail. It is the one fact the
// retirement verdict reads after a kill, so every kill path is run under both.
type Jail {
  Bwrap
  NoBwrap
}

// Where the helper was when it died, which is the other fact the retirement
// verdict reads: a helper that had no jail yet, or whose last jail was already
// killed, leaves nothing running whatever the platform, and only one with a
// live execution depends on bwrap.
type Died {
  InHandshake
  WhileIdle
  WhileRunning
}

fn hello_features(jail: Jail) -> List(String) {
  case jail {
    Bwrap -> ["bwrap"]
    NoBwrap -> []
  }
}

// The wire is deliberately silent until the test supplies native exit. A
// transport-close notification is independent from that exit witness.
fn controlled() -> #(
  exec.Helper,
  process.Subject(BitArray),
  process.Subject(Nil),
) {
  controlled_with(NoBwrap, fn(config) { config })
}

fn controlled_with(
  jail: Jail,
  tune: fn(exec.HelperConfig) -> exec.HelperConfig,
) -> #(exec.Helper, process.Subject(BitArray), process.Subject(Nil)) {
  let sent = process.new_subject()
  let closed = process.new_subject()
  let helper = open_controlled(sent, closed, jail, tune)
  let assert Ok(_) = process.receive(sent, 1000)
    as "broker hello precedes shutdown"
  #(helper, sent, closed)
}

// The same helper over subjects the caller already owns, which is what a
// pool's spawner needs: it runs inside the pool actor, and a subject made
// there cannot be received on by the test.
fn open_controlled(
  sent: process.Subject(BitArray),
  closed: process.Subject(Nil),
  jail: Jail,
  tune: fn(exec.HelperConfig) -> exec.HelperConfig,
) -> exec.Helper {
  let transport =
    exec.ChannelTransport(
      send: fn(bytes) { process.send(sent, bytes) },
      close: fn() { process.send(closed, Nil) },
    )
  ready_controlled_with(transport, hello_features(jail), tune)
}

fn ready_controlled(transport: exec.Transport) -> exec.Helper {
  ready_controlled_with(transport, [], fn(config) { config })
}

// A helper whose hello announces `features`, with `tune` free to shorten the
// deadlines a test wants to see fire. The heartbeat is off unless `tune`
// turns it on, because a probe nobody answers would kill the helper unasked.
fn ready_controlled_with(
  transport: exec.Transport,
  features: List(String),
  tune: fn(exec.HelperConfig) -> exec.HelperConfig,
) -> exec.Helper {
  let config = exec.default_config(transport)
  let assert Ok(helper) =
    exec.start(tune(exec.HelperConfig(..config, heartbeat_interval_ms: 0)))
    as "helper starts"
  let assert Ok(hello) =
    framing.encode(framing.Frame(
      id: 1,
      body: framing.Hello(
        proto: framing.exec_protocol_version,
        peer: "exec-helper",
        features:,
      ),
    ))
    as "hello encodes"
  process.send(exec.wire(helper), exec.WireBytes(hello))
  assert exec.await_ready(helper, waiting: 1000) == Ok(features)
  helper
}

pub fn shutdown_requires_native_exit_without_closing_port_test() {
  let #(helper, sent, closed) = controlled()
  assert exec.close(helper, waiting: 20) == Error(exec.RetirementPending)
  let assert Ok(bytes) = process.receive(sent, 1000) as "shutdown was written"
  let framing.Pushed(inbound:, fault:, ..) =
    framing.push(framing.deframer(), bytes)
  assert fault == None
  let assert [framing.Known(framing.Frame(body: framing.Shutdown, ..))] =
    inbound
    as "empty shutdown frame"
  assert process.receive(closed, 0) == Error(Nil)
  assert process.is_alive(exec.pid(helper))

  // Only the selected exit-status event permits the BEAM actor to retire.
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert exec.close(helper, waiting: 1000) == Ok(Nil)
  assert !process.is_alive(exec.pid(helper))
}

// A nonzero status after the shutdown frame proves the process is gone and
// nothing about its jail, because the helper was asked to join it and did
// not say that it had.
pub fn nonzero_exit_after_shutdown_is_not_orderly_retirement_test() {
  let #(helper, _, _) = controlled()
  assert exec.close(helper, waiting: 20) == Error(exec.RetirementPending)
  process.send(exec.wire(helper), exec.WireClosed(137))
  assert exec.close(helper, waiting: 1000) == Error(exec.RetirementExit(137))
  assert process.is_alive(exec.pid(helper))
}

// A helper that dies unasked while idle leaves no jail running: `Settle`
// killed the last one before the exec_exit that made it idle was written.
// So its exit retires it on any platform, whatever the status.
pub fn unasked_death_while_idle_retires_on_any_platform_test() {
  use jail <- each_jail
  let #(helper, _, _) = controlled_with(jail, fn(config) { config })
  process.send(exec.wire(helper), exec.WireClosed(139))
  assert exec.close(helper, waiting: 1000) == Ok(Nil)
  assert !process.is_alive(exec.pid(helper))
}

// A helper that dies unasked mid-execution is judged exactly as a killed one
// is: under bwrap its jail dies with it, and without bwrap nothing says so.
pub fn unasked_death_while_running_follows_the_jail_test() {
  use jail <- each_jail
  let #(helper, _, _) = controlled_with(jail, fn(config) { config })
  let events = process.new_subject()
  assert exec.run(helper, request(), events:, waiting: 1000) == Ok(Nil)
  process.send(exec.wire(helper), exec.WireClosed(139))
  assert process.receive(events, 1000)
    == Ok(exec.Failed(exec.ChannelClosed(139)))
  expect_verdict(helper, WhileRunning, jail, 139)
}

pub fn dead_beam_actor_is_not_native_retirement_test() {
  let #(helper, _, _) = controlled()
  process.unlink(exec.pid(helper))
  process.kill(exec.pid(helper))
  assert exec.close(helper, waiting: 1000) == Error(exec.RetirementOwnerGone)
}

pub fn pool_joins_idle_and_borrowed_helper_owners_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 2, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  let assert Ok(idle) = exec.checkout(pool, waiting: 1000) as "first checkout"
  let assert Ok(borrowed) = exec.checkout(pool, waiting: 1000)
    as "second checkout"
  exec.checkin(pool, idle)
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
  assert !process.is_alive(exec.pid(idle))
  assert !process.is_alive(exec.pid(borrowed))
  assert !process.is_alive(exec.pool_pid(pool))
}

pub fn pool_retains_helper_after_checkout_caller_times_out_test() {
  let spawned = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      process.sleep(50)
      let helper = fake_helper.start_helper(fake_helper.EchoArgv)
      process.send(spawned, helper)
      Ok(helper)
    })
    as "pool starts"
  assert exec.checkout(pool, waiting: 5) == Error(exec.PoolUnavailable)
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
  let assert Ok(helper) = process.receive(spawned, 1000)
    as "late helper was registered"
  assert !process.is_alive(exec.pid(helper))
}

pub fn pool_timeout_keeps_custody_until_native_exit_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      let helper =
        ready_controlled(
          exec.ChannelTransport(send: fn(_) { Nil }, close: fn() { Nil }),
        )
      Ok(helper)
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "helper borrowed"
  assert exec.close_pool(pool, waiting: 20) == Error(exec.RetirementPending)
  assert exec.checkout(pool, waiting: 1000) == Error(exec.PoolUnavailable)
  assert process.is_alive(exec.pool_pid(pool))
  assert process.is_alive(exec.pid(helper))
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

/// A nonzero native exit proves the OS process is gone but attests
/// nothing about its jail's descendants, so the slot stays occupied and
/// `close_pool` keeps reporting the unclean verdict. What the refusal
/// must not do is look like congestion: nothing transitions out of
/// `Unconfirmed`, so a borrower told `AllBusy(1)` here would nap out its
/// whole clearance budget, once per call, for the life of the session.
/// A count of zero is the pool saying waiting cannot help.
pub fn pool_native_failure_retains_capacity_test() {
  let #(pool, events) = unjailed_pool(size: 1)
  let helper = start_running(pool, events)
  process.send(exec.wire(helper), exec.WireClosed(137))
  exec.checkin(pool, helper)
  assert_hopeless(pool)

  // A status that proves the process gone and the jail nothing is the
  // other kind of unconfirmed cleanup, and keeps its reason.
  let assert Ok(custody) = exec.pool_custody(pool, waiting: 1000)
  let assert [view] = custody.helpers
  assert view.custody == exec.CleanupUnconfirmed(exec.RetirementExit(137))
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementExit(137))
}

/// The count is the *lendable* remainder, not "any entry is unconfirmed":
/// a borrower still holding the pool's other helper will check it back
/// in, so that refusal is ordinary congestion and waiting is the right
/// answer to it.
pub fn pool_reports_the_helpers_that_can_still_return_test() {
  let #(pool, events) = unjailed_pool(size: 2)
  let dying = start_running(pool, events)
  let assert Ok(_held) = exec.checkout(pool, waiting: 1000) as "second checkout"
  process.send(exec.wire(dying), exec.WireClosed(137))
  exec.checkin(pool, dying)
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case exec.checkout(pool, waiting: 1000) {
        Error(exec.AllBusy(size: 1)) -> poll.Done(Nil)
        Error(exec.AllBusy(size: 2)) -> poll.Retry
        other -> poll.Fail(other)
      }
    })
    as "the borrowed helper is still counted as able to return"
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementExit(137))
}

// A pool of helpers that announce no bwrap, so that a death with a live
// execution is the case the verdict cannot excuse. The events subject is the
// test's, and outlives every execution it is handed to.
fn unjailed_pool(
  size size: Int,
) -> #(exec.Pool, process.Subject(exec.ExecEvent)) {
  let sent = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size:, spawn: fn() {
      Ok(open_controlled(sent, closed, NoBwrap, fn(config) { config }))
    })
    as "pool starts"
  #(pool, process.new_subject())
}

// Borrows a helper and leaves it running an execution that never ends.
fn start_running(
  pool: exec.Pool,
  events: process.Subject(exec.ExecEvent),
) -> exec.Helper {
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "helper borrowed"
  assert exec.run(helper, request(), events:, waiting: 1000) == Ok(Nil)
  helper
}

// Waits for the pool to finish recording a retirement failure and then
// pins the refusal it settles on. The verdict travels as a message from
// the helper to the pool, so a checkout issued in the same breath can
// still be handled ahead of it; the property under test is the state the
// pool converges to and stays in, not the microsecond it gets there.
fn assert_hopeless(pool: exec.Pool) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case exec.checkout(pool, waiting: 1000) {
        Error(exec.AllBusy(size: 0)) -> poll.Done(Nil)
        Error(exec.AllBusy(size: 1)) -> poll.Retry
        other -> poll.Fail(other)
      }
    })
    as "a pool with nothing left to lend refuses without promising more"
  Nil
}

pub fn shutdown_body_requires_an_empty_map_test() {
  let payload =
    msgpack.MapValue([
      #(msgpack.StringValue("v"), msgpack.IntValue(1)),
      #(msgpack.StringValue("id"), msgpack.IntValue(0)),
      #(msgpack.StringValue("kind"), msgpack.StringValue("shutdown")),
      #(
        msgpack.StringValue("body"),
        msgpack.MapValue([
          #(msgpack.StringValue("unexpected"), msgpack.IntValue(1)),
        ]),
      ),
    ])
  let assert Ok(bytes) = msgpack.encode(payload) as "payload encodes"
  let assert Error(_) = framing.decode_payload(bytes)
    as "shutdown rejects fields"
}

pub fn prepared_helper_has_no_acquisition_before_begin_test() {
  let acquired = process.new_subject()
  let config =
    exec.default_config(
      exec.DeferredTransport(fn() {
        process.send(acquired, Nil)
        Ok(exec.ChannelTransport(send: fn(_) { Nil }, close: fn() { Nil }))
      }),
    )
  let assert Ok(helper) = exec.prepare(config) as "parked owner starts"
  assert process.receive(acquired, 0) == Error(Nil)
  exec.begin(helper)
  exec.begin(helper)
  assert process.receive(acquired, 1000) == Ok(Nil)
  let assert Ok(hello) =
    framing.encode(framing.Frame(
      id: 1,
      body: framing.Hello(
        proto: framing.exec_protocol_version,
        peer: "exec-helper",
        features: [],
      ),
    ))
    as "hello encodes"
  process.send(exec.wire(helper), exec.WireBytes(hello))
  assert exec.await_ready(helper, waiting: 1000) == Ok([])
  assert process.receive(acquired, 0) == Error(Nil)
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert exec.close(helper, waiting: 1000) == Ok(Nil)
}

pub fn prepared_helper_close_never_acquires_transport_test() {
  let acquired = process.new_subject()
  let config =
    exec.default_config(
      exec.DeferredTransport(fn() {
        process.send(acquired, Nil)
        Error("must not acquire")
      }),
    )
  let assert Ok(helper) = exec.prepare(config) as "parked owner starts"
  assert exec.close(helper, waiting: 1000) == Ok(Nil)
  assert process.receive(acquired, 0) == Error(Nil)
  assert !process.is_alive(exec.pid(helper))
}

pub fn prepared_helper_stops_when_preparer_exits_normally_test() {
  let acquired = process.new_subject()
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let finish = process.new_subject()
      let config =
        exec.default_config(
          exec.DeferredTransport(fn() {
            process.send(acquired, Nil)
            Error("must not acquire")
          }),
        )
      let assert Ok(helper) = exec.prepare(config) as "parked owner starts"
      process.send(ready, #(helper, finish))
      let assert Ok(Nil) = process.receive(finish, 1000)
        as "test releases the preparer"
      Nil
    })
  let assert Ok(#(helper, finish)) = process.receive(ready, 1000)
    as "preparer publishes its parked helper"
  let monitor = process.monitor(exec.pid(helper))
  process.send(finish, Nil)
  assert_helper_stopped(monitor)
  assert process.receive(acquired, 0) == Error(Nil)

  // Only the live owner can attest that no transport was acquired. Its
  // normal exit is a lifetime bound, not a replacement retirement witness.
  assert exec.close(helper, waiting: 1000) == Error(exec.RetirementOwnerGone)
}

pub fn active_helper_parent_exit_is_not_retirement_proof_test() {
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let finish = process.new_subject()
      let #(helper, _, _) = controlled()
      process.send(ready, #(helper, finish))
      let assert Ok(Nil) = process.receive(finish, 1000)
        as "test releases the active helper's parent"
      Nil
    })
  let assert Ok(#(helper, finish)) = process.receive(ready, 1000)
    as "parent publishes its active helper"
  let monitor = process.monitor(exec.pid(helper))
  process.send(finish, Nil)
  assert_helper_stopped(monitor)
  assert exec.close(helper, waiting: 1000) == Error(exec.RetirementOwnerGone)
}

fn assert_helper_stopped(monitor: process.Monitor) -> Nil {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "helper follows its preparer's normal exit"
  Nil
}

pub fn prepared_pool_acquisition_failure_has_no_native_resource_test() {
  let owners = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      let config =
        exec.default_config(
          exec.DeferredTransport(fn() {
            Error("acquisition refused before opening any port")
          }),
        )
      let assert Ok(helper) = exec.prepare(config) as "parked owner starts"
      process.send(owners, helper)
      Ok(helper)
    })
    as "pool starts"
  assert exec.checkout(pool, waiting: 1000)
    == Error(exec.SpawnFailed(exec.HandshakeFailed(exec.SendFailed)))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
  let assert Ok(helper) = process.receive(owners, 1000)
    as "prepared helper was inventoried"
  assert !process.is_alive(exec.pid(helper))
}

pub fn prepared_pool_handshake_failure_keeps_acquired_owner_test() {
  let owners = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      let config =
        exec.default_config(
          exec.ChannelTransport(send: fn(_) { Nil }, close: fn() { Nil }),
        )
      let assert Ok(helper) =
        exec.prepare(exec.HelperConfig(..config, handshake_timeout_ms: 20))
        as "parked owner starts"
      process.send(owners, helper)
      Ok(helper)
    })
    as "pool starts"
  assert exec.checkout(pool, waiting: 1000)
    == Error(exec.SpawnFailed(exec.HandshakeFailed(exec.HandshakeTimeout)))
  let assert Ok(helper) = process.receive(owners, 1000)
    as "failed owner is retained"

  // The handshake deadline killed the helper and kept its port, so the
  // slot stays held while the exit is awaited. The status arrives, and a
  // helper that never accepted a hello had no jail to leave behind: its
  // exit retires it, and the pool lends the slot again.
  assert exec.close_pool(pool, waiting: 20) == Error(exec.RetirementPending)
  process.send(exec.wire(helper), exec.WireClosed(137))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
  assert !process.is_alive(exec.pid(helper))
}

pub fn pool_helper_actor_death_is_unconfirmed_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "helper borrowed"
  process.kill(exec.pid(helper))
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementOwnerGone)
  assert process.is_alive(exec.pool_pid(pool))
}

pub fn pool_actor_death_is_unconfirmed_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  process.unlink(exec.pool_pid(pool))
  process.kill(exec.pool_pid(pool))
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementOwnerGone)
}

pub fn duplicate_checkin_does_not_lend_one_helper_twice_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "helper borrowed"
  exec.checkin(pool, helper)
  exec.checkin(pool, helper)
  let assert Ok(_) = exec.checkout(pool, waiting: 1000)
    as "one checkin makes one slot available"
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

// --- the witnessed kill ---------------------------------------------------

fn request() -> exec.ExecRequest {
  exec.ExecRequest(
    argv: ["/bin/sleep", "300"],
    env: [],
    cwd: "/",
    policy: None,
    token: <<0:size(31)-unit(8), 7>>,
    demand: exec.BestEffort,
  )
}

// Everything every kill path owes, from the moment the machine has killed
// the helper. The kill was delivered (a channel's `close` is the whole of its
// kill) but the exit status has not arrived, so the machine is waiting for
// it rather than giving up: a caller's timeout answers `RetirementPending`
// and leaves the custody alone. Then the port reports the SIGKILL status, and
// the verdict is the one `expect_verdict` names for where the helper died.
fn settle_kill(
  helper: exec.Helper,
  closed: process.Subject(Nil),
  jail: Jail,
  died: Died,
) -> Nil {
  assert process.receive(closed, 1000) == Ok(Nil)
  assert exec.close(helper, waiting: 20) == Error(exec.RetirementPending)
  assert process.is_alive(exec.pid(helper))
  process.send(exec.wire(helper), exec.WireClosed(137))
  expect_verdict(helper, died, jail, 137)
}

// The retirement verdict once the exit status has been supplied. A helper
// that died before it accepted a hello, or while idle, left no jail, so its
// exit retires it everywhere. One that died with an execution live is
// retired only if its hello advertised bwrap, where the jail dies with it.
fn expect_verdict(
  helper: exec.Helper,
  died: Died,
  jail: Jail,
  status: Int,
) -> Nil {
  case died, jail {
    WhileRunning, NoBwrap -> {
      assert exec.close(helper, waiting: 1000)
        == Error(exec.RetirementExit(status))
      assert process.is_alive(exec.pid(helper))
    }
    InHandshake, _ | WhileIdle, _ | WhileRunning, Bwrap -> {
      assert exec.close(helper, waiting: 1000) == Ok(Nil)
      assert !process.is_alive(exec.pid(helper))
    }
  }
}

fn each_jail(check: fn(Jail) -> Nil) -> Nil {
  list.each([Bwrap, NoBwrap], check)
}

pub fn cancel_escalation_kill_keeps_its_witness_test() {
  use jail <- each_jail
  let #(helper, _, closed) =
    controlled_with(jail, fn(config) {
      exec.HelperConfig(..config, cancel_grace_ms: 30)
    })
  let events = process.new_subject()
  assert exec.run(helper, request(), events:, waiting: 1000) == Ok(Nil)
  exec.cancel(helper)

  // The execution still settles in band, and the helper keeps the failure it
  // died with: the exit status that follows is the proof, not the story.
  assert process.receive(events, 1000) == Ok(exec.Failed(exec.CancelEscalated))
  assert exec.status(helper, waiting: 1000)
    == exec.StatusDead(exec.CancelEscalated)
  settle_kill(helper, closed, jail, WhileRunning)

  // A helper that outlives its verdict has still not forgotten why it died.
  case jail {
    Bwrap -> Nil
    NoBwrap -> {
      assert exec.status(helper, waiting: 1000)
        == exec.StatusDead(exec.CancelEscalated)
    }
  }
}

pub fn handshake_deadline_kill_retires_a_helper_with_no_jail_test() {
  let sent = process.new_subject()
  let closed = process.new_subject()
  let config =
    exec.default_config(
      exec.ChannelTransport(
        send: fn(bytes) { process.send(sent, bytes) },
        close: fn() { process.send(closed, Nil) },
      ),
    )
  let assert Ok(helper) =
    exec.start(
      exec.HelperConfig(
        ..config,
        handshake_timeout_ms: 30,
        heartbeat_interval_ms: 0,
      ),
    )
    as "helper starts"
  assert exec.await_ready(helper, waiting: 1000) == Error(exec.HandshakeTimeout)

  // No hello arrived, so no features did, and none were needed: the helper
  // had been sent nothing to run, so there is no jail for its death to leave.
  settle_kill(helper, closed, NoBwrap, InHandshake)
}

pub fn version_mismatch_kill_retires_a_helper_with_no_jail_test() {
  let sent = process.new_subject()
  let closed = process.new_subject()
  let config =
    exec.default_config(
      exec.ChannelTransport(
        send: fn(bytes) { process.send(sent, bytes) },
        close: fn() { process.send(closed, Nil) },
      ),
    )
  let assert Ok(helper) =
    exec.start(exec.HelperConfig(..config, heartbeat_interval_ms: 0))
    as "helper starts"
  let assert Ok(hello) =
    framing.encode(framing.Frame(
      id: 1,
      body: framing.Hello(
        proto: framing.exec_protocol_version + 1,
        peer: "exec-helper",
        features: ["bwrap"],
      ),
    ))
    as "hello encodes"
  process.send(exec.wire(helper), exec.WireBytes(hello))
  let assert Error(exec.ProtocolVersionMismatch(..)) =
    exec.await_ready(helper, waiting: 1000)

  // The hello was refused, so nothing was ever dispatched to the helper and
  // what it advertised does not matter.
  settle_kill(helper, closed, NoBwrap, InHandshake)
}

pub fn heartbeat_miss_kill_retires_an_idle_helper_test() {
  use jail <- each_jail
  let #(helper, _, closed) =
    controlled_with(jail, fn(config) {
      exec.HelperConfig(..config, heartbeat_interval_ms: 20)
    })

  // Nothing echoes the probe, so the second tick finds the first outstanding.
  assert process.receive(closed, 1000) == Ok(Nil)
  let assert exec.StatusDead(exec.HeartbeatMissed) =
    exec.status(helper, waiting: 1000)
  process.send(exec.wire(helper), exec.WireClosed(137))
  expect_verdict(helper, WhileIdle, jail, 137)
}

pub fn channel_fault_kill_retires_an_idle_helper_test() {
  use jail <- each_jail
  let #(helper, _, closed) = controlled_with(jail, fn(config) { config })
  process.send(exec.wire(helper), exec.WireBytes(<<0, 0, 0, 1, 0xc1>>))
  settle_kill(helper, closed, jail, WhileIdle)
}

pub fn channel_fault_kill_with_a_live_execution_needs_bwrap_test() {
  use jail <- each_jail
  let #(helper, _, closed) = controlled_with(jail, fn(config) { config })
  let events = process.new_subject()
  assert exec.run(helper, request(), events:, waiting: 1000) == Ok(Nil)
  process.send(exec.wire(helper), exec.WireBytes(<<0, 0, 0, 1, 0xc1>>))
  let assert Ok(exec.Failed(exec.ChannelFault(_))) =
    process.receive(events, 1000)
  settle_kill(helper, closed, jail, WhileRunning)
}

pub fn protocol_violation_kill_retires_an_idle_helper_test() {
  use jail <- each_jail
  let #(helper, _, closed) = controlled_with(jail, fn(config) { config })
  let assert Ok(cancel) =
    framing.encode(framing.Frame(id: 9, body: framing.Cancel))
    as "cancel encodes"

  // A cancel never flows from a helper to the broker.
  process.send(exec.wire(helper), exec.WireBytes(cancel))
  settle_kill(helper, closed, jail, WhileIdle)
}

// A kill that is not followed by an exit must not strand its caller: the
// deadline the caller passed bounds the wait, and the helper stays owned.
pub fn killed_helper_that_never_reports_exit_answers_pending_test() {
  let #(helper, _, closed) = controlled_with(Bwrap, fn(config) { config })
  process.send(exec.wire(helper), exec.WireBytes(<<0, 0, 0, 1, 0xc1>>))
  assert process.receive(closed, 1000) == Ok(Nil)
  assert exec.close(helper, waiting: 20) == Error(exec.RetirementPending)
  assert exec.close(helper, waiting: 20) == Error(exec.RetirementPending)
  assert process.is_alive(exec.pid(helper))
}

// A kill whose SIGKILL does not land produces no exit status, and the port
// is still retained, so nothing else would ever end the wait. The witness
// timeout does: the caller that was parked on the retirement is answered
// that the proof is lost, which is the only thing the broker can honestly
// say, and the verdict stays lost afterwards.
pub fn killed_helper_whose_exit_never_comes_loses_its_proof_test() {
  let #(helper, _, closed) =
    controlled_with(Bwrap, fn(config) {
      exec.HelperConfig(..config, kill_witness_ms: 50)
    })
  process.send(exec.wire(helper), exec.WireBytes(<<0, 0, 0, 1, 0xc1>>))
  assert process.receive(closed, 1000) == Ok(Nil)
  assert exec.close(helper, waiting: 2000) == Error(exec.RetirementProofLost)

  // A status that turns up after the give-up repairs nothing.
  process.send(exec.wire(helper), exec.WireClosed(137))
  assert exec.close(helper, waiting: 1000) == Error(exec.RetirementProofLost)
  assert process.is_alive(exec.pid(helper))
}

// Hands out 0, 1, 2... to whoever asks. The pool's spawner runs inside the
// pool actor, which cannot receive on a subject the test owns, so the count
// lives in a process of its own.
fn ticket_counter() -> process.Subject(process.Subject(Int)) {
  let handoff = process.new_subject()
  process.spawn_unlinked(fn() {
    let requests = process.new_subject()
    process.send(handoff, requests)
    count_tickets(requests, 0)
  })
  let assert Ok(requests) = process.receive(handoff, 1000)
    as "the ticket counter starts"
  requests
}

fn count_tickets(
  requests: process.Subject(process.Subject(Int)),
  next: Int,
) -> Nil {
  let reply = process.receive_forever(requests)
  process.send(reply, next)
  count_tickets(requests, next + 1)
}

fn take_ticket(requests: process.Subject(process.Subject(Int))) -> Int {
  process.call(requests, waiting: 1000, sending: fn(reply) { reply })
}

// The pool frees a killed helper's slot through the path it already had: the
// helper is checked in dead, retired, and removed once its owner exits, and
// the slot lends again. Before the kill was witnessed this ended in
// `Unconfirmed(RetirementProofLost)` and the pool shrank by one for good.
pub fn pool_recovers_the_slot_of_a_killed_bwrap_helper_test() {
  let tickets = ticket_counter()
  let sent = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      let helper = case take_ticket(tickets) {
        // The first helper is the one the test kills.
        0 ->
          open_controlled(sent, closed, Bwrap, fn(config) {
            exec.HelperConfig(..config, cancel_grace_ms: 30)
          })
        _later -> fake_helper.start_helper(fake_helper.EchoArgv)
      }
      Ok(helper)
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "the helper to be killed"
  let events = process.new_subject()
  assert exec.run(helper, request(), events:, waiting: 1000) == Ok(Nil)
  exec.cancel(helper)
  assert process.receive(events, 1000) == Ok(exec.Failed(exec.CancelEscalated))
  assert process.receive(closed, 1000) == Ok(Nil)

  // Dead and awaiting its exit, so it is retired and not lent. The slot
  // stays held until the status arrives.
  exec.checkin(pool, helper)
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  process.send(exec.wire(helper), exec.WireClosed(137))
  let assert poll.Answered(replacement) =
    poll.until(within: 2000, every: 5, attempt: fn() {
      case exec.checkout(pool, waiting: 1000) {
        Ok(next) -> poll.Done(next)
        Error(exec.AllBusy(..)) -> poll.Retry
        Error(other) -> poll.Fail(other)
      }
    })
    as "the killed helper's slot lends a replacement"
  assert exec.pid(replacement) != exec.pid(helper)
  assert !process.is_alive(exec.pid(helper))
  exec.checkin(pool, replacement)
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

// Without bwrap the same kill leaves the slot held, and says why.
pub fn pool_keeps_the_slot_of_a_killed_unjailed_helper_test() {
  let sent = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      Ok(
        open_controlled(sent, closed, NoBwrap, fn(config) {
          exec.HelperConfig(..config, cancel_grace_ms: 30)
        }),
      )
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "the helper to be killed"
  let events = process.new_subject()
  assert exec.run(helper, request(), events:, waiting: 1000) == Ok(Nil)
  exec.cancel(helper)
  assert process.receive(events, 1000) == Ok(exec.Failed(exec.CancelEscalated))
  assert process.receive(closed, 1000) == Ok(Nil)
  exec.checkin(pool, helper)
  process.send(exec.wire(helper), exec.WireClosed(137))
  assert_hopeless(pool)
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementExit(137))
}

// The pool-level face of the same give-up. Without the timeout the entry
// stays `Draining` for ever, which `lendable_again` counts as a slot that
// will return, so callers would wait on capacity that never comes. With it
// the slot ends `Unconfirmed`, which the pool reads as permanent.
pub fn pool_slot_of_a_kill_with_no_exit_ends_unconfirmed_test() {
  let sent = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      Ok(
        open_controlled(sent, closed, Bwrap, fn(config) {
          exec.HelperConfig(..config, cancel_grace_ms: 30, kill_witness_ms: 50)
        }),
      )
    })
    as "pool starts"
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "the helper to be killed"
  let events = process.new_subject()
  assert exec.run(helper, request(), events:, waiting: 1000) == Ok(Nil)
  exec.cancel(helper)
  assert process.receive(events, 1000) == Ok(exec.Failed(exec.CancelEscalated))
  assert process.receive(closed, 1000) == Ok(Nil)

  // No `WireClosed` is ever sent: the kill produced no status.
  exec.checkin(pool, helper)
  assert_hopeless(pool)
  let assert Ok(census) = exec.pool_census(pool, waiting: 1000)
  assert census.unconfirmed == 1
  assert census.draining == 0

  // The custody view names the same fact in the evidence vocabulary: the
  // proof is lost, and the view says so rather than "unconfirmed" alone.
  let assert Ok(custody) = exec.pool_custody(pool, waiting: 1000)
  let assert [view] = custody.helpers
  assert view.custody == exec.ProofLost
  assert view.lending == exec.Withdrawn
  assert exec.close_pool(pool, waiting: 1000) == Error(exec.RetirementProofLost)
}

// Targeted observers bind to one originally inventoried borrow. The controlled
// wire lets native proof and the original owner monitor be held independently.
fn targeted_pool() -> #(exec.Pool, exec.Helper, process.Subject(BitArray)) {
  let sent = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(pool) =
    exec.start_pool(1, fn() {
      Ok(open_controlled(sent, closed, NoBwrap, fn(config) { config }))
    })
    as "Original controlled pool."
  let assert Ok(helper) = exec.checkout(pool, waiting: 1000)
    as "Exact original borrow."
  let assert Ok(_) = process.receive(sent, 1000) as "Original hello written."
  #(pool, helper, sent)
}

pub fn targeted_retirement_requires_native_and_original_owner_boundaries_test() {
  let #(pool, helper, sent) = targeted_pool()
  let retired = process.new_subject()

  // A different live inventory cannot observe this original borrow, even when
  // the supplied helper is itself valid and still owned by its actual pool.
  let assert Ok(foreign) =
    exec.start_pool(1, fn() { Error(exec.PortOpenFailed) })
    as "Foreign original pool, with no native effects."
  assert exec.prepare_borrowed_retirement(foreign, helper, fn(result) {
      process.send(retired, result)
    })
    == Error(exec.RetirementProofLost)
  assert process.receive(retired, 0) == Error(Nil)
  assert exec.close_pool(foreign, waiting: 1000) == Ok(Nil)

  let assert Ok(original) =
    exec.prepare_borrowed_retirement(pool, helper, fn(result) {
      process.send(retired, result)
    })
    as "Observer installed before effects."
  exec.retire_borrowed(original)
  let assert Ok(_) = process.receive(sent, 1000) as "Original shutdown written."
  assert process.receive(retired, 0) == Error(Nil)
  let assert Ok(census) = exec.pool_census(pool, waiting: 1000)
    as "Original inventory remains held."
  assert census.draining == 1
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))

  // The pool is paused before the native event. The helper processes that event
  // and answers status, then is paused before the pool can send ForgetRetired.
  bench_host.suspend(exec.pool_pid(pool))
  process.send(exec.wire(helper), exec.WireClosed(0))
  let assert exec.StatusDead(_) = exec.status(helper, waiting: 1000)
    as "Native exit processed by the original helper."
  bench_host.suspend(exec.pid(helper))
  bench_host.resume(exec.pool_pid(pool))
  let assert poll.Answered(Nil) =
    poll.until(1000, 5, fn() {
      case exec.pool_census(pool, waiting: 1000) {
        Ok(exec.PoolCensus(retiring: 1, ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "Native boundary reached while owner Down remains held."
  assert process.is_alive(exec.pid(helper))
  assert process.receive(retired, 0) == Error(Nil)
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))

  bench_host.resume(exec.pid(helper))
  assert process.receive(retired, 1000) == Ok(Ok(Nil))
  assert !process.is_alive(exec.pid(helper))
  exec.retire_borrowed(original)
  assert exec.prepare_borrowed_retirement(pool, helper, fn(result) {
      process.send(retired, result)
    })
    == Error(exec.RetirementProofLost)
  assert process.receive(retired, 0) == Error(Nil)
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}

pub fn targeted_retirement_keeps_original_observer_across_scope_close_test() {
  let #(pool, helper, sent) = targeted_pool()
  let retired = process.new_subject()
  let assert Ok(original) =
    exec.prepare_borrowed_retirement(pool, helper, fn(result) {
      process.send(retired, result)
    })
    as "One original observer."
  assert exec.prepare_borrowed_retirement(pool, helper, fn(result) {
      process.send(retired, result)
    })
    == Error(exec.RetirementProofLost)
  let pool_monitor = process.monitor(exec.pool_pid(pool))
  exec.stop_pool(pool)
  exec.retire_borrowed(original)
  let assert Ok(_) = process.receive(sent, 1000)
    as "Scope withdraws same helper."
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert process.receive(retired, 1000) == Ok(Ok(Nil))
  assert process.receive(retired, 0) == Error(Nil)
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(pool_monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "Original pool closes normally after exact retirement."
}

pub fn targeted_registration_lost_reply_withdraws_without_dispatch_permission_test() {
  let #(pool, helper, sent) = targeted_pool()
  let retired = process.new_subject()
  bench_host.suspend(exec.pool_pid(pool))
  let answer =
    weft.new([
      fn() {
        Ok(
          exec.prepare_borrowed_retirement(pool, helper, fn(result) {
            process.send(retired, result)
          }),
        )
      },
    ])
    |> weft.deadline(2000)
    |> weft.start
  let assert [weft.Completed(_, Error(exec.RetirementPending))] = answer
    as "Lost registration reply grants no original door or dispatch."
  assert process.receive(retired, 0) == Error(Nil)
  bench_host.resume(exec.pool_pid(pool))
  let assert Ok(_) = process.receive(sent, 1000)
    as "Same lost-reply door withdraws borrow."
  assert exec.checkout(pool, waiting: 1000) == Error(exec.AllBusy(1))
  process.send(exec.wire(helper), exec.WireClosed(0))
  assert process.receive(retired, 1000) == Ok(Ok(Nil))
  assert exec.close_pool(pool, waiting: 1000) == Ok(Nil)
}
