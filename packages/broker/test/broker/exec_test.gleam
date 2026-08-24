import broker/exec
import broker/framing
import broker/support/fake_helper
import gleam/erlang/process
import gleam/list
import gleam/option.{None}

fn request(demand: exec.EnforcementDemand) -> exec.ExecRequest {
  exec.ExecRequest(
    argv: ["/bin/echo", "hello"],
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    policy: None,
    token: token_bytes(),
    demand:,
  )
}

fn token_bytes() -> BitArray {
  <<0:size(31)-unit(8), 7>>
}

pub fn handshake_and_features_test() {
  let helper = fake_helper.start_helper(fake_helper.EchoArgv)
  let assert exec.StatusReady(features) = exec.status(helper, waiting: 1000)
  assert features == ["rlimits", "pgroup", "bwrap", "landlock", "seccomp"]
  exec.shutdown(helper)
}

pub fn echo_run_streams_output_and_exit_test() {
  let helper = fake_helper.start_helper(fake_helper.EchoArgv)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.FullEnforcement), events:, waiting: 1000)
  let assert Ok(exec.Output(
    stream: framing.Stdout,
    data: <<"/bin/echo hello\n":utf8>>,
    total_bytes: 16,
    truncated: False,
  )) = process.receive(events, 1000)
  let assert Ok(exec.Exited(result)) = process.receive(events, 1000)
  assert result.code == 0
  assert result.degraded == False
  exec.shutdown(helper)
}

pub fn one_exec_at_a_time_test() {
  let helper = fake_helper.start_helper(fake_helper.SleepUntilCancel)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  // A second dispatch on the same helper is refused broker-side.
  let second = process.new_subject()
  assert exec.run(
      helper,
      request(exec.BestEffort),
      events: second,
      waiting: 1000,
    )
    == Error(exec.HelperBusy)
  // After cancel settles the first, the helper is usable again.
  exec.cancel(helper)
  let assert Ok(exec.Exited(result)) = process.receive(events, 1000)
  assert result.signal == 15
  exec.shutdown(helper)
}

pub fn helper_busy_error_settles_in_band_test() {
  let helper = fake_helper.start_helper(fake_helper.AlwaysBusy)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  let assert Ok(exec.Failed(exec.RefusedByHelper(code: "busy", message: _))) =
    process.receive(events, 1000)
  exec.shutdown(helper)
}

pub fn stdin_roundtrip_test() {
  let helper = fake_helper.start_helper(fake_helper.StdinEcho)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  exec.stdin(helper, data: <<"first ">>, eof: False)
  exec.stdin(helper, data: <<"second">>, eof: True)
  let assert Ok(exec.Output(data: <<"first second":utf8>>, ..)) =
    process.receive(events, 1000)
  let assert Ok(exec.Exited(_)) = process.receive(events, 1000)
  exec.shutdown(helper)
}

pub fn truncation_reported_test() {
  let helper = fake_helper.start_helper(fake_helper.Truncating)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  let assert Ok(exec.Output(truncated: True, ..)) =
    process.receive(events, 1000)
  let assert Ok(exec.Exited(result)) = process.receive(events, 1000)
  assert result.stdout_truncated == True
  exec.shutdown(helper)
}

pub fn degraded_helper_refused_on_full_enforcement_test() {
  let helper = fake_helper.start_helper(fake_helper.Degraded)
  let events = process.new_subject()
  // FullEnforcement refuses at dispatch, from the hello features.
  let assert Error(exec.DegradedHelper(features)) =
    exec.run(helper, request(exec.FullEnforcement), events:, waiting: 1000)
  assert features == ["rlimits", "pgroup", "degraded"]
  // BestEffort accepts and the honest report reaches the caller.
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  let assert Ok(exec.Output(..)) = process.receive(events, 1000)
  let assert Ok(exec.Exited(result)) = process.receive(events, 1000)
  assert result.degraded == True
  exec.shutdown(helper)
}

pub fn degraded_exit_ground_truth_checked_test() {
  // The helper's hello looked healthy; the per-exec enforcement report
  // is degraded. FullEnforcement must fail the execution.
  let helper = fake_helper.start_helper(fake_helper.LyingDegraded)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.FullEnforcement), events:, waiting: 1000)
  let assert Ok(exec.Output(..)) = process.receive(events, 1000)
  let assert Ok(exec.Failed(exec.DegradedExecution(result))) =
    process.receive(events, 1000)
  assert result.degraded == True
  exec.shutdown(helper)
}

pub fn skip_entry_fails_full_enforcement_test() {
  // The exec_exit keeps `degraded: False` but the enforcement list
  // carries a `skip:` entry — the structured list is the ground truth
  // and FullEnforcement must refuse on it, not trust the bool.
  let helper = fake_helper.start_helper(fake_helper.SkippedLayer)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.FullEnforcement), events:, waiting: 1000)
  let assert Ok(exec.Output(..)) = process.receive(events, 1000)
  let assert Ok(exec.Failed(exec.DegradedExecution(result))) =
    process.receive(events, 1000)
  assert result.degraded == False
  assert list.contains(
    result.enforcement,
    "skip:landlock: unavailable in this test",
  )
  exec.shutdown(helper)
}

pub fn skip_entry_accepted_on_best_effort_test() {
  // BestEffort still accepts the run; the honest report reaches the
  // caller for its own inspection.
  let helper = fake_helper.start_helper(fake_helper.SkippedLayer)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  let assert Ok(exec.Output(..)) = process.receive(events, 1000)
  let assert Ok(exec.Exited(result)) = process.receive(events, 1000)
  assert result.degraded == False
  exec.shutdown(helper)
}

pub fn watch_cleanup_runs_on_brutal_kill_test() {
  // The janitor fires however the watched process dies — here a
  // brutal kill that skips every graceful path.
  let cleaned = process.new_subject()
  let victim = process.spawn_unlinked(fn() { process.sleep(10_000) })
  exec.watch_cleanup(victim, fn() { process.send(cleaned, Nil) })
  process.kill(victim)
  let assert Ok(Nil) = process.receive(cleaned, 1000)
}

pub fn watch_cleanup_runs_when_already_dead_test() {
  // Watching a process that died before the monitor was set still
  // fires the cleanup (the DOWN arrives with reason noproc).
  let cleaned = process.new_subject()
  let victim = process.spawn_unlinked(fn() { Nil })
  process.sleep(50)
  exec.watch_cleanup(victim, fn() { process.send(cleaned, Nil) })
  let assert Ok(Nil) = process.receive(cleaned, 1000)
}

pub fn cancel_escalates_when_ignored_test() {
  let helper =
    fake_helper.start_helper_configured(
      fake_helper.IgnoreCancel,
      cancel_grace_ms: 150,
      heartbeat_interval_ms: 0,
    )
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  exec.cancel(helper)
  // The fake ignores cancel; the broker-side deadline kills the helper
  // and settles the execution in-band.
  let assert Ok(exec.Failed(exec.CancelEscalated)) =
    process.receive(events, 2000)
  let assert exec.StatusDead(exec.CancelEscalated) =
    exec.status(helper, waiting: 1000)
  exec.shutdown(helper)
}

pub fn cancel_is_idempotent_test() {
  let helper = fake_helper.start_helper(fake_helper.SleepUntilCancel)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  exec.cancel(helper)
  exec.cancel(helper)
  exec.cancel(helper)
  let assert Ok(exec.Exited(result)) = process.receive(events, 1000)
  assert result.signal == 15
  // No stray second settlement arrives.
  assert process.receive(events, 100) == Error(Nil)
  exec.shutdown(helper)
}

pub fn malformed_frame_closes_channel_in_band_test() {
  let helper = fake_helper.start_helper(fake_helper.MalformedOnExec)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  // Spec §3.3 invariant 6: malformed frame -> channel close + in-band
  // effect failure, never a crash.
  let assert Ok(exec.Failed(exec.ChannelFault(framing.CorruptFrame(_)))) =
    process.receive(events, 1000)
  let assert exec.StatusDead(_) = exec.status(helper, waiting: 1000)
  exec.shutdown(helper)
}

pub fn handshake_timeout_reported_test() {
  let #(transport, inbox) = fake_helper.start(fake_helper.NoHello)
  let config =
    exec.HelperConfig(
      transport:,
      handshake_timeout_ms: 150,
      cancel_grace_ms: 400,
      heartbeat_interval_ms: 0,
    )
  let assert Ok(helper) = exec.start(config)
  process.send(inbox, fake_helper.Attach(wire: exec.wire(helper)))
  assert exec.await_ready(helper, waiting: 2000) == Error(exec.HandshakeTimeout)
  exec.shutdown(helper)
}

pub fn wrong_proto_kills_handshake_test() {
  let #(transport, inbox) = fake_helper.start(fake_helper.WrongProto)
  let config =
    exec.HelperConfig(
      transport:,
      handshake_timeout_ms: 1000,
      cancel_grace_ms: 400,
      heartbeat_interval_ms: 0,
    )
  let assert Ok(helper) = exec.start(config)
  process.send(inbox, fake_helper.Attach(wire: exec.wire(helper)))
  // The envelope version is fine, so the frame decodes; the hello
  // body's proto mismatch is a protocol violation that kills the
  // handshake in-band.
  let assert Error(exec.ProtocolViolation(kind: "hello")) =
    exec.await_ready(helper, waiting: 2000)
  exec.shutdown(helper)
}

pub fn heartbeat_roundtrip_test() {
  let helper = fake_helper.start_helper(fake_helper.EchoArgv)
  assert exec.heartbeat(helper, waiting: 1000) == Ok(Nil)
  assert exec.heartbeat(helper, waiting: 1000) == Ok(Nil)
  exec.shutdown(helper)
}

pub fn channel_close_settles_running_exec_test() {
  let helper = fake_helper.start_helper(fake_helper.SleepUntilCancel)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  // Simulate the helper process dying mid-execution.
  process.send(exec.wire(helper), exec.WireClosed(status: 137))
  let assert Ok(exec.Failed(exec.ChannelClosed(status: 137))) =
    process.receive(events, 1000)
  exec.shutdown(helper)
}

// --- the pool -----------------------------------------------------------

pub fn pool_checkout_checkin_cycle_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 2, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
  let assert Ok(first) = exec.checkout(pool, waiting: 2000)
  let assert Ok(second) = exec.checkout(pool, waiting: 2000)
  // Capacity exhausted: the third checkout is refused, not queued.
  assert exec.checkout(pool, waiting: 2000) == Error(exec.AllBusy(size: 2))
  // Checkin frees a slot for the next checkout.
  exec.checkin(pool, first)
  let assert Ok(_third) = exec.checkout(pool, waiting: 2000)
  exec.checkin(pool, second)
  exec.stop_pool(pool)
}

pub fn pool_retires_dead_helpers_and_respawns_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      Ok(fake_helper.start_helper(fake_helper.EchoArgv))
    })
  let assert Ok(helper) = exec.checkout(pool, waiting: 2000)
  // The helper dies while lent out (channel gone).
  process.send(exec.wire(helper), exec.WireClosed(status: 1))
  let assert Ok(_) = process_settle(helper)
  exec.checkin(pool, helper)
  // The dead helper was retired; capacity respawns a fresh one.
  let assert Ok(fresh) = exec.checkout(pool, waiting: 2000)
  let assert exec.StatusReady(_) = exec.status(fresh, waiting: 1000)
  exec.checkin(pool, fresh)
  exec.stop_pool(pool)
}

// Waits until the helper actor has processed the death notification.
fn process_settle(helper: exec.Helper) -> Result(Nil, Nil) {
  case exec.status(helper, waiting: 1000) {
    exec.StatusDead(_) -> Ok(Nil)
    _ -> {
      process.sleep(20)
      process_settle(helper)
    }
  }
}

pub fn pool_spawn_failure_surfaces_test() {
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() { Error(exec.PortOpenFailed) })
  assert exec.checkout(pool, waiting: 2000)
    == Error(exec.SpawnFailed(error: exec.PortOpenFailed))
  exec.stop_pool(pool)
}

pub fn run_on_dead_helper_refused_test() {
  let helper = fake_helper.start_helper(fake_helper.EchoArgv)
  process.send(exec.wire(helper), exec.WireClosed(status: 9))
  let assert Ok(_) = process_settle(helper)
  let events = process.new_subject()
  let assert Error(exec.ChannelClosed(status: 9)) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  exec.shutdown(helper)
}

pub fn idle_heartbeat_keeps_helper_alive_test() {
  let helper =
    fake_helper.start_helper_configured(
      fake_helper.EchoArgv,
      cancel_grace_ms: 400,
      heartbeat_interval_ms: 80,
    )
  // Several tick intervals pass; the fake echoes each probe, so the
  // helper stays ready.
  process.sleep(400)
  let assert exec.StatusReady(_) = exec.status(helper, waiting: 1000)
  exec.shutdown(helper)
}

pub fn missed_heartbeat_declares_helper_dead_test() {
  let helper =
    fake_helper.start_helper_configured(
      fake_helper.DeafHeartbeat,
      cancel_grace_ms: 400,
      heartbeat_interval_ms: 80,
    )
  // The first tick goes unanswered; the second tick finds it
  // outstanding and declares the helper dead.
  process.sleep(400)
  let assert exec.StatusDead(exec.HeartbeatMissed) =
    exec.status(helper, waiting: 1000)
  exec.shutdown(helper)
}
