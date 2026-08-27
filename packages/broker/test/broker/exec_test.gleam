import broker/exec
import broker/framing
import broker/policy
import broker/support/fake_helper
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string

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

/// A helper that is alive but answers nothing is *wedged*, and the pool
/// retires it — it does not die of it. The readiness probe runs inside
/// the pool actor, so a probe that faulted on a timeout would take the
/// pool with it, and the broker after that: the broker borrows through
/// a `process.call` of its own, which panics when its callee dies. The
/// scaling argument for a sixteen-slot pool rests on a probe costing one
/// timeout per wedged helper and never being paid twice; that is only
/// true if the first timeout is survivable.
pub fn pool_retires_a_wedged_helper_rather_than_faulting_test() {
  let #(wedged, wedge) = fake_helper.start_wedgeable_helper(blocking_for: 4000)
  let first_spawn = one_shot()
  let assert Ok(pool) =
    exec.start_pool(size: 1, spawn: fn() {
      case first_spawn() {
        True -> Ok(wedged)
        False -> Ok(fake_helper.start_helper(fake_helper.EchoArgv))
      }
    })
  let assert Ok(borrowed) = exec.checkout(pool, waiting: 2000)
  assert exec.pid(borrowed) == exec.pid(wedged)
  // Close the wedge and let a heartbeat tick carry the actor into a
  // channel write it will not come back from inside the probe's window.
  fake_helper.close_wedge(wedge)
  process.sleep(200)
  exec.checkin(pool, borrowed)
  // The probe times out, the wedged helper is retired, and the slot
  // respawns. A pool that had faulted would take this `checkout` with
  // it instead of answering.
  let assert Ok(fresh) = exec.checkout(pool, waiting: 4000)
  assert exec.pid(fresh) != exec.pid(wedged)
  let assert exec.StatusReady(_) = exec.status(fresh, waiting: 1000)
  exec.checkin(pool, fresh)
  exec.stop_pool(pool)
}

type LatchMsg {
  Take(reply: process.Subject(Bool))
}

// A latch readable from any process: `True` the first time it is taken,
// `False` afterwards. The pool actor runs a test's `spawn` closure in
// its own process and cannot `receive` on a subject the test owns, so a
// one-shot needs a process of its own to live in.
fn one_shot() -> fn() -> Bool {
  let handoff = process.new_subject()
  process.spawn_unlinked(fn() {
    let inbox = process.new_subject()
    process.send(handoff, inbox)
    latch_loop(inbox, True)
  })
  let assert Ok(inbox) = process.receive(handoff, 1000)
  fn() { process.call(inbox, waiting: 1000, sending: Take) }
}

fn latch_loop(inbox: process.Subject(LatchMsg), fresh: Bool) -> Nil {
  let Take(reply:) = process.receive_forever(inbox)
  process.send(reply, fresh)
  latch_loop(inbox, False)
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

// The default ceiling is derived, not guessed: a scheduler count
// clamped into a range that is meaningful on a one-core CI box and
// still bounded on a build server.
pub fn default_pool_size_is_clamped_scheduler_count_test() {
  assert exec.pool_size_for(schedulers: 1) == exec.min_pool_size
  assert exec.pool_size_for(schedulers: 3) == exec.min_pool_size
  assert exec.pool_size_for(schedulers: 8) == 8
  assert exec.pool_size_for(schedulers: 96) == exec.max_pool_size
  // Whatever this node reports, the derivation still lands in range —
  // and never on the literal `2` the server used to hardcode.
  let live = exec.default_pool_size()
  assert live >= exec.min_pool_size
  assert live <= exec.max_pool_size
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

// The platform decision mirrors the helper's own `jail.PlatformFor`:
// Linux is WP-H phase 1 and the only jail that exists. Taking the OS
// name as an argument is the only way the macOS and Windows answers can
// be checked at all, since no such host has ever run this tree.
pub fn host_platform_for_names_the_unjailed_ones_test() {
  assert exec.host_platform_for("linux") == exec.JailedHost
  assert exec.host_platform_for("darwin") == exec.UnjailedHost("darwin")
  assert exec.host_platform_for("nt") == exec.UnjailedHost("nt")
  assert exec.host_platform_for("plan9") == exec.UnjailedHost("plan9")
}

// `--allow-unenforced` is for a platform with no jail, never for one
// whose kernel merely could not supply a layer. A jailed host that
// reported degraded enforcement must still reach the broker's own
// demand check rather than be waved through by a flag.
pub fn unenforced_args_only_on_an_unjailed_platform_test() {
  assert exec.unenforced_helper_args(exec.JailedHost) == []
  assert exec.unenforced_helper_args(exec.UnjailedHost("darwin"))
    == ["--allow-unenforced"]
}

// The skip reason a suite prints must carry the marker
// `.github/declared-skips` matches on, and must name the platform, so
// the census can tell a declared skip from an undeclared one and a
// reader can tell which host produced it.
pub fn unjailed_skip_reason_carries_the_declared_marker_test() {
  assert exec.unjailed_skip_reason(exec.JailedHost) == None
  let assert Some(reason) =
    exec.unjailed_skip_reason(exec.UnjailedHost("darwin"))
  assert string.contains(reason, exec.unjailed_skip_marker)
  assert string.contains(reason, "darwin")
  // The census greps `SKIP <name>: <reason>`; a colon before the first
  // one would split the line in the wrong place.
  assert !string.contains(exec.unjailed_skip_marker, ":")
}

// This host runs the suite, so its own answer must be the jailed one —
// otherwise every real-helper test below silently stopped running.
pub fn host_platform_here_is_jailed_test() {
  assert exec.host_platform() == exec.JailedHost
}

pub fn silent_layer_fails_full_enforcement_test() {
  // #54's meta-finding: stage 2 died before it could report, so the
  // helper sent `enforcement: ["bwrap"]` — no `skip:` anywhere, and the
  // old "no skip entries" test therefore accepted it as fully enforced.
  // A demand for full enforcement is a demand that every layer the
  // policy calls for says it was applied, so silence must refuse.
  let helper = fake_helper.start_helper(fake_helper.SilentStage2)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.FullEnforcement), events:, waiting: 1000)
  let assert Ok(exec.Output(..)) = process.receive(events, 1000)
  let assert Ok(exec.Failed(exec.DegradedExecution(result))) =
    process.receive(events, 1000)
  assert result.degraded == False
  assert result.enforcement == ["bwrap"]
  exec.shutdown(helper)
}

pub fn missing_seccomp_fails_full_enforcement_test() {
  // The layer set is derived from the policy: a network-off policy calls
  // for the seccomp network filter, so a report that never mentions it
  // is refused even though every entry present is an applied one.
  let helper = fake_helper.start_helper(fake_helper.NoSeccompEntry)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(
      helper,
      exec.ExecRequest(
        ..request(exec.FullEnforcement),
        policy: Some(network_off_policy()),
      ),
      events:,
      waiting: 1000,
    )
  let assert Ok(exec.Output(..)) = process.receive(events, 1000)
  let assert Ok(exec.Failed(exec.DegradedExecution(result))) =
    process.receive(events, 1000)
  assert !list.any(result.enforcement, string.starts_with(_, "skip:"))
  assert exec.unapplied_layers(
      result.enforcement,
      exec.required_layers(Some(network_off_policy())),
    )
    == ["seccomp-net"]
  exec.shutdown(helper)
}

fn network_off_policy() -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    writable_roots: ["/work"],
    readable_roots: [],
    protected: [],
    network: policy.NetworkOff,
    limits: policy.Limits(
      cpu_s: 0,
      wall_s: 0,
      mem_bytes: 0,
      pids: 0,
      fsize_bytes: 0,
      output_bytes: 0,
    ),
    env_allow: ["PATH"],
    scratch: policy.ScratchTmpfs,
  )
}

pub fn presence_refuses_nothing_the_skip_rule_already_refused_test() {
  // The worry the presence check invites: that demanding `landlock` and
  // `bwrap` turns every kernel that lacks them into a refusal where a
  // degraded run used to be legitimate. It does not, and this is the
  // shape of the argument.
  //
  // A host without Landlock reports it *honestly*, as `skip:landlock: …`,
  // and the skip rule — which predates #54 — already refuses that under
  // `FullEnforcement`. Presence is a second reason for the same verdict
  // on such a report, never a first reason for a new one.
  let honest = [
    "bwrap", "mounts:ro=1,rw=1,mask=0,scratch=tmpfs,plan=0000000000000000",
    "no-new-privs", "seccomp-net", "rlimits", "pgroup",
    "skip:landlock: unavailable in this test",
  ]
  assert list.any(honest, string.starts_with(_, "skip:"))

  // And the case presence exists for: a report with no skip at all,
  // which the old rule read as fully enforced because it had nothing to
  // object to. Here the skip rule is blind and presence is the only
  // thing that speaks.
  let silent = ["bwrap"]
  assert !list.any(silent, string.starts_with(_, "skip:"))
  assert exec.unapplied_layers(silent, exec.required_layers(None))
    == ["mounts", "landlock", "no-new-privs"]
}

pub fn best_effort_still_runs_a_silent_report_test() {
  // The other half of the same product question. Degraded-mode running
  // is legitimate and clearly labelled, and it is what the code-mode
  // path, `make e2e` and a laptop without bubblewrap all use. The
  // presence check lives entirely inside the `FullEnforcement` arm, so
  // `BestEffort` accepts even the silent report and hands the caller the
  // list to judge for itself.
  let helper = fake_helper.start_helper(fake_helper.SilentStage2)
  let events = process.new_subject()
  let assert Ok(Nil) =
    exec.run(helper, request(exec.BestEffort), events:, waiting: 1000)
  let assert Ok(exec.Output(..)) = process.receive(events, 1000)
  let assert Ok(exec.Exited(result)) = process.receive(events, 1000)
  assert result.enforcement == ["bwrap"]
  exec.shutdown(helper)
}
