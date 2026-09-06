//// Domain cadence over the production owned pipeline and real SQLite memory.
//// Resolver gates control admission without replacing the managed task. Each
//// gate has a finite deadline, and every test stops or monitors its worker.

import client/distill
import client/distillpass
import client/memory
import core/clock
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/supervision
import provider/gateway
import provider/http
import provider/model
import provider/secret
import simplifile
import support/provider
import weft/registry as address

/// A burst creates one follow-up, after the prior waiters and witness retire.
pub fn domain_cadence_parked_stop_opens_nothing_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let options = config(name, arrivals, "parked")
  let assert Ok(_) = distillpass.prepare_domain(options)
    as "domain must prepare without starting a pass"
  assert distillpass.active_witness(name, waiting_ms: 1000) == Ok(None)
  assert process.receive(arrivals, 0) == Error(Nil)
  assert distillpass.stop_domain(name, waiting_ms: 1000) == Ok(Nil)
  assert simplifile.is_file(options.pipeline.memory_path) == Ok(False)
  assert address.stop(names) == Ok(Nil)
}

/// Quiesce waits through the coalesced pass; ordinary Await still answers first.
pub fn domain_cadence_quiesce_waits_follow_up_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let assert Ok(worker) =
    distillpass.prepare_domain(config(name, arrivals, "quiesce"))
    as "domain must prepare"
  distillpass.begin_domain(worker.data)
  let assert Ok(first) = process.receive(arrivals, 1000)
    as "published domain may begin"
  distillpass.begin_domain(worker.data)
  assert distillpass.trigger(name, waiting_ms: 1000) == Ok(Nil)
  assert process.receive(arrivals, 0) == Error(Nil)
  let current = process.new_subject()
  let finished = process.new_subject()
  assert distillpass.request_domain_settled(name, current) == Ok(Nil)
  assert distillpass.request_quiesce(name, finished) == Ok(Nil)
  assert distillpass.trigger(name, waiting_ms: 1000) != Ok(Nil)
  process.send(first, Ok([]))
  let assert Ok(second) = process.receive(arrivals, 1000)
    as "the already-coalesced pass must still run"
  let assert Ok(distillpass.Completed(_)) = process.receive(current, 1000)
    as "ordinary Await observes the first completed pass"
  assert process.receive(finished, 20) == Error(Nil)
  process.send(second, Ok([]))
  let assert Ok(distillpass.Completed(_)) = process.receive(finished, 1000)
    as "quiesce answers only after the follow-up retires"
  assert process.is_alive(worker.pid)
  distillpass.begin_domain(worker.data)
  assert distillpass.active_witness(name, waiting_ms: 1000) == Ok(None)
  assert process.receive(arrivals, 0) == Error(Nil)
  assert distillpass.stop_domain(name, waiting_ms: 1000) == Ok(Nil)
  assert address.stop(names) == Ok(Nil)
}

/// A resume lifts a settled domain's fence, and the cadence schedules again.
///
/// This is the revival the registry performs when a new session opens in a
/// workspace whose last one closed: without the resume the worker stays in
/// `Quiescing`, where it refuses every trigger and every hint, so the reopened
/// workspace runs no distillation for the rest of the domain's life.
pub fn domain_cadence_resume_unfences_a_settled_domain_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let assert Ok(_) =
    distillpass.start_domain(config(name, arrivals, "resume-settled"))
    as "domain must start"
  let assert Ok(first) = process.receive(arrivals, 1000)
    as "first admission must run immediately"
  process.send(first, Ok([]))
  let assert Ok(distillpass.Completed(_)) =
    distillpass.domain_settled(name, waiting_ms: 1000)
    as "the first pass must settle before the fence"

  // Nothing is coalesced behind this fence, so it is answered from the settled
  // account at once and leaves the worker refusing further work.
  let fenced = process.new_subject()
  assert distillpass.request_quiesce(name, fenced) == Ok(Nil)
  let assert Ok(distillpass.Completed(_)) = process.receive(fenced, 1000)
    as "a quiesce with nothing owed answers from the settled account"
  assert distillpass.trigger(name, waiting_ms: 1000)
    == Error("domain worker is stopping")

  assert distillpass.request_resume(name) == Ok(Nil)
  assert distillpass.trigger(name, waiting_ms: 1000) == Ok(Nil)
  let assert Ok(second) = process.receive(arrivals, 2000)
    as "a resumed domain admits a scheduled pass again"
  process.send(second, Ok([]))
  let assert Ok(distillpass.Completed(_)) =
    distillpass.domain_settled(name, waiting_ms: 1000)
    as "the resumed pass must complete"
  assert distillpass.stop_domain(name, waiting_ms: 1000) == Ok(Nil)
  assert address.stop(names) == Ok(Nil)
}

/// A fence answered after a revival must not fence the resumed domain again.
///
/// The hazard this pins: a quiesce that arrives during a pass is owed an
/// answer, and that answer lands after the registry has already handed the
/// services back. If answering re-applied the fence, the resumed domain would
/// look open to the registry and be closed to every hint the registry sends.
pub fn domain_cadence_resume_survives_a_late_quiesce_answer_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let assert Ok(_) =
    distillpass.start_domain(config(name, arrivals, "resume-stale"))
    as "domain must start"
  let assert Ok(first) = process.receive(arrivals, 1000)
    as "first admission must run immediately"

  // The fence lands while the pass is parked, so its answer is owed rather
  // than sent, and the revival happens in the gap.
  let fenced = process.new_subject()
  assert distillpass.request_quiesce(name, fenced) == Ok(Nil)
  assert distillpass.trigger(name, waiting_ms: 1000)
    == Error("domain worker is stopping")
  assert distillpass.request_resume(name) == Ok(Nil)
  assert distillpass.trigger(name, waiting_ms: 1000) == Ok(Nil)

  process.send(first, Ok([]))
  let assert Ok(second) = process.receive(arrivals, 2000)
    as "the resumed domain runs the pass the revived session asked for"
  assert process.receive(fenced, 0) == Error(Nil)
  process.send(second, Ok([]))
  assert process.receive(fenced, 100) == Error(Nil)
    as "the resume withdrew the fence, so its subject is never answered"

  // The withdrawn fence must leave admission exactly where the resume put it.
  assert distillpass.trigger(name, waiting_ms: 1000) == Ok(Nil)
  let assert Ok(third) = process.receive(arrivals, 2000)
    as "a resumed domain still schedules after its stale fence is answered"
  process.send(third, Ok([]))
  let assert Ok(distillpass.Completed(_)) =
    distillpass.domain_settled(name, waiting_ms: 1000)
    as "the pass after the late answer must complete"
  assert distillpass.stop_domain(name, waiting_ms: 1000) == Ok(Nil)
  assert address.stop(names) == Ok(Nil)
}

/// A resume withdraws the fence it lifts, so a workspace that closes and
/// reopens many times during one pass leaves one parked reply, and the fence
/// standing at settle time is the only one answered.
pub fn domain_cadence_repeated_fences_park_one_reply_per_caller_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let assert Ok(_) =
    distillpass.start_domain(config(name, arrivals, "resume-repeat"))
    as "domain must start"
  let assert Ok(first) = process.receive(arrivals, 1000)
    as "first admission must run immediately"

  // Five close-and-reopen cycles while the pass is parked, then the fence
  // that finally stands, all on the registry's one subject for the slot.
  let fenced = process.new_subject()
  list.each(list.repeat(Nil, 5), fn(_) {
    assert distillpass.request_quiesce(name, fenced) == Ok(Nil)
    assert distillpass.request_resume(name) == Ok(Nil)
  })
  assert distillpass.request_quiesce(name, fenced) == Ok(Nil)

  process.send(first, Ok([]))
  let assert Ok(distillpass.Completed(_)) = process.receive(fenced, 1000)
    as "the standing fence is answered once nothing more is owed"
  assert process.receive(fenced, 100) == Error(Nil)
    as "the withdrawn fences left no parked replies behind"
  assert distillpass.stop_domain(name, waiting_ms: 1000) == Ok(Nil)
  assert address.stop(names) == Ok(Nil)
}

/// A fence withdrawn by a resume is never answered, so the registry that
/// listens on a fresh subject after revival cannot take an older fence's
/// account for the one it issued afterwards.
pub fn domain_cadence_withdrawn_fence_is_never_answered_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let assert Ok(_) =
    distillpass.start_domain(config(name, arrivals, "resume-withdraw"))
    as "domain must start"
  let assert Ok(first) = process.receive(arrivals, 1000)
    as "first admission must run immediately"

  let withdrawn = process.new_subject()
  assert distillpass.request_quiesce(name, withdrawn) == Ok(Nil)
  assert distillpass.request_resume(name) == Ok(Nil)
  let standing = process.new_subject()
  assert distillpass.request_quiesce(name, standing) == Ok(Nil)

  process.send(first, Ok([]))
  let assert Ok(distillpass.Completed(_)) = process.receive(standing, 1000)
    as "the fence issued after revival is the one answered"
  assert process.receive(withdrawn, 100) == Error(Nil)
    as "the fence the resume withdrew receives no account"
  assert distillpass.stop_domain(name, waiting_ms: 1000) == Ok(Nil)
  assert address.stop(names) == Ok(Nil)
}

/// Retirement is not withdrawable, so a resume during a stop changes nothing.
pub fn domain_cadence_resume_cannot_withdraw_a_stop_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let started = process.new_subject()
  let cancelled = process.new_subject()
  let options = held_provider_config(name, started, cancelled, "resume-stop")
  let assert Ok(worker) = distillpass.start_domain(options)
    as "domain must start"
  let original = process.monitor(worker.pid)
  let assert Ok(#(_owner, release)) = process.receive(started, 1000)
    as "the original provider owner must begin"
  assert distillpass.stop_domain(name, waiting_ms: 20)
    == Error("domain retirement remains unconfirmed")
  assert process.receive(cancelled, 1000) == Ok(Nil)

  // The stop has already asked the cancellation witness to exit, so this
  // admission is final and the resume must leave it alone.
  assert distillpass.request_resume(name) == Ok(Nil)
  assert distillpass.trigger(name, waiting_ms: 1000)
    == Error("domain worker is stopping")

  // And the retirement the stop began still completes.
  process.send(release, Nil)
  assert down(original, 2000) == Ok(process.Normal)
  assert address.stop(names) == Ok(Nil)
}

/// A burst creates one follow-up, after the prior waiters and witness retire.
pub fn domain_cadence_coalesces_and_replies_before_follow_up_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let assert Ok(_) = distillpass.start_domain(config(name, arrivals, "burst"))
    as "domain must start"
  let assert Ok(first) = process.receive(arrivals, 1000)
    as "first admission must run immediately"
  int.range(1, 20, Nil, fn(_, _) {
    assert distillpass.trigger(name, waiting_ms: 1000) == Ok(Nil)
  })
  let answer = process.new_subject()
  assert distillpass.request_domain_settled(name, answer) == Ok(Nil)

  // Same-sender ordering makes this reply a barrier after the await request.
  let assert Ok(Some(witness)) =
    distillpass.active_witness(name, waiting_ms: 1000)
    as "active pass must own its cancellation witness"
  let watch = process.monitor(witness)
  assert process.receive(answer, 0) == Error(Nil)
  process.send(first, Ok([]))
  let assert Ok(second) = process.receive(arrivals, 1000)
    as "the coalesced follow-up must resolve fresh sources"

  // The second resolver stays parked, so a reply cannot belong to its pass.
  let assert Ok(distillpass.Completed(report)) = process.receive(answer, 0)
    as "postponed waiters must receive the completed pass before follow-up"
  assert report.sources == 0
  assert !process.is_alive(witness)
  assert down(watch, 1000) == Ok(process.Normal)
  process.send(second, Ok([]))
  let assert Ok(distillpass.Completed(_)) =
    distillpass.domain_settled(name, waiting_ms: 1000)
    as "the second pass must finish"
  assert process.receive(arrivals, 0) == Error(Nil)
  assert distillpass.stop_domain(name, waiting_ms: 1000) == Ok(Nil)
  assert address.stop(names) == Ok(Nil)
}

/// A failed pass discards old triggers, but a later explicit trigger may retry.
pub fn domain_cadence_failure_discards_pending_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let assert Ok(_) = distillpass.start_domain(config(name, arrivals, "failure"))
    as "domain must start"
  let assert Ok(first) = process.receive(arrivals, 1000)
    as "first resolver must arrive"
  assert distillpass.trigger(name, waiting_ms: 1000) == Ok(Nil)
  process.send(first, Error("catalogue unavailable"))
  assert distillpass.domain_settled(name, waiting_ms: 1000)
    == Ok(distillpass.Refused("catalogue unavailable"))
  assert process.receive(arrivals, 50) == Error(Nil)
  assert distillpass.trigger(name, waiting_ms: 1000) == Ok(Nil)
  let assert Ok(second) = process.receive(arrivals, 1000)
    as "a later explicit trigger must resolve again"
  process.send(second, Ok([]))
  let assert Ok(distillpass.Completed(_)) =
    distillpass.domain_settled(name, waiting_ms: 1000)
    as "explicit retry must complete"
  assert distillpass.stop_domain(name, waiting_ms: 1000) == Ok(Nil)
  assert address.stop(names) == Ok(Nil)
}

/// Stopping an active resolver cancels the original run and retires its witness.
pub fn domain_cadence_stop_active_resolver_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let assert Ok(_) = distillpass.start_domain(config(name, arrivals, "stop"))
    as "domain must start"
  let assert Ok(_gate) = process.receive(arrivals, 1000)
    as "resolver must be active"
  let answer = process.new_subject()
  assert distillpass.request_domain_settled(name, answer) == Ok(Nil)
  let assert Ok(Some(witness)) =
    distillpass.active_witness(name, waiting_ms: 1000)
    as "active witness must be observable"
  let watch = process.monitor(witness)
  assert distillpass.trigger(name, waiting_ms: 1000) == Ok(Nil)
  assert distillpass.stop_domain(name, waiting_ms: 2000) == Ok(Nil)
  assert process.receive(answer, 1000)
    == Ok(distillpass.Refused("domain shutdown cancelled the pass"))
  assert down(watch, 1000) == Ok(process.Normal)
  assert process.receive(arrivals, 0) == Error(Nil)
  assert address.stop(names) == Ok(Nil)
}

/// An unexpectedly dead worker cannot leave its linked cancellation witness.
pub fn domain_cadence_worker_death_retires_witness_test() {
  process.trap_exits(True)
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let assert Ok(worker) =
    distillpass.start_domain(config(name, arrivals, "death"))
    as "domain must start"
  let assert Ok(_gate) = process.receive(arrivals, 1000)
    as "resolver must be active"
  let assert Ok(Some(witness)) =
    distillpass.active_witness(name, waiting_ms: 1000)
    as "active witness must be observable"
  let watch = process.monitor(witness)
  process.kill(worker.pid)
  let assert Ok(_reason) = down(watch, 1000)
    as "worker death must not leave a live cancellation witness"
  assert distillpass.trigger(name, waiting_ms: 1000) != Ok(Nil)
  assert address.stop(names) == Ok(Nil)
  process.trap_exits(False)
}

/// Opt-out and expired commands refuse before starting or queuing work.
pub fn domain_cadence_opt_out_and_expired_calls_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let arrivals = process.new_subject()
  let base = config(name, arrivals, "off")
  assert distillpass.supervised_domain(base).restart == supervision.Temporary
  let off = distillpass.DomainConfig(..base, options: distillpass.no_pass())
  let assert Error(_) = distillpass.start_domain(off)
    as "opt-out must refuse before a task starts"
  assert process.receive(arrivals, 0) == Error(Nil)
  assert distillpass.trigger(name, waiting_ms: 0) != Ok(Nil)
  assert distillpass.domain_settled(name, waiting_ms: 0)
    == Error("domain call deadline expired")
  assert distillpass.stop_domain(name, waiting_ms: 0)
    == Error("domain stop deadline expired")
  assert address.stop(names) == Ok(Nil)
}

/// Witness death requests cancellation; it does not retire an active provider.
pub fn domain_cadence_stop_waits_original_provider_test() {
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let started = process.new_subject()
  let cancelled = process.new_subject()
  let options = held_provider_config(name, started, cancelled, "provider-stop")
  let assert Ok(worker) = distillpass.start_domain(options)
    as "domain must start"
  let original = process.monitor(worker.pid)
  let assert Ok(#(owner, release)) = process.receive(started, 1000)
    as "the original provider owner must begin"
  let assert Ok(Some(witness)) =
    distillpass.active_witness(name, waiting_ms: 1000)
    as "active witness must be present"
  let watch = process.monitor(witness)
  assert distillpass.stop_domain(name, waiting_ms: 20)
    == Error("domain retirement remains unconfirmed")
  assert process.receive(cancelled, 1000) == Ok(Nil)
  assert down(watch, 1000) == Ok(process.Normal)
  assert process.is_alive(owner)
  let assert Error(_) = distillpass.domain_settled(name, waiting_ms: 20)
    as "witness retirement must not settle the still-owned provider"
  assert down(original, 0) == Error(Nil)

  // The already admitted stop completes only after the original owner retires.
  process.send(release, Nil)
  assert down(original, 2000) == Ok(process.Normal)
  assert !process.is_alive(owner)
  assert address.stop(names) == Ok(Nil)
}

/// Lost original transport proof blocks rearming even after terminal delivery.
pub fn domain_cadence_provider_proof_loss_is_permanent_test() {
  process.trap_exits(True)
  let assert Ok(names) = address.start() as "registry must start"
  let name = address.new_address(names)
  let started = process.new_subject()
  let cancelled = process.new_subject()
  let options = held_provider_config(name, started, cancelled, "proof-loss")
  let assert Ok(worker) = distillpass.start_domain(options)
    as "domain must start"
  let assert Ok(#(owner, _release)) = process.receive(started, 1000)
    as "the original provider owner must begin"
  assert distillpass.trigger(name, waiting_ms: 1000) == Ok(Nil)
  process.kill(owner)
  let assert Ok(distillpass.Refused(reason)) =
    distillpass.domain_settled(name, waiting_ms: 2000)
    as "original transport death must refuse the pass"
  assert distillpass.trigger(name, waiting_ms: 1000) == Error(reason)
  assert distillpass.stop_domain(name, waiting_ms: 1000) == Error(reason)
  assert process.is_alive(worker.pid)
  assert process.receive(started, 50) == Error(Nil)
  assert distillpass.trigger(name, waiting_ms: 1000) == Error(reason)

  // Test cleanup kills the blocked owner; it does not call that retirement.
  let watch = process.monitor(worker.pid)
  process.kill(worker.pid)
  let assert Ok(_) = down(watch, 1000) as "blocked test worker must exit"
  assert address.stop(names) == Ok(Nil)
  process.trap_exits(False)
}

// A real Gateway owns a scripted BEAM transport, not a socket or native process.
fn held_provider_config(name, started, cancelled, lane) {
  let arrivals = process.new_subject()
  let base = config(name, arrivals, lane)
  let notes =
    memory.remember_seam(
      base.pipeline.memory_path,
      clock: clock.fixed(at: 1000),
      entropy: fn() { 99 },
    )
  assert notes.remember("the user prefers tabs") == Ok(Nil)
  let transport =
    http.Transport(prepare_streaming: fn(_request, _events) {
      let ready = process.new_subject()
      let owner =
        process.spawn_unlinked(fn() {
          let release = process.new_subject()
          process.send(ready, release)
          let assert Ok(Nil) = process.receive(release, 3000)
            as "scripted transport has a finite release deadline"
        })
      let assert Ok(release) = process.receive(ready, 1000)
        as "scripted transport must park"
      Ok(
        http.PreparedRequest(
          running: http.RunningRequest(owner:, cancel: fn() {
            process.send(cancelled, Nil)
          }),
          begin: fn() { process.send(started, #(owner, release)) },
        ),
      )
    })
  let routed =
    gateway.new(
      transport:,
      secrets: secret.from_list([#("ACME_KEY", "unit-test-key")]),
      clock: clock.fixed(at: 1000),
    )
    |> gateway.add_provider(gateway.AnthropicProvider(
      name: "acme",
      base_url: "https://acme.invalid",
      api_key_secret: "ACME_KEY",
    ))
    |> gateway.route(model.Main, [
      model.ResolvedModel(
        provider: "acme",
        model_id: "loom-1",
        thinking: model.ThinkingOff,
        context_window: 100_000,
        max_output_tokens: 4096,
      ),
    ])
  distillpass.DomainConfig(
    ..base,
    sources: fn() { Ok([]) },
    gateway: routed,
    request_timeout_ms: 2000,
  )
}

fn down(watch: process.Monitor, waiting: Int) {
  process.new_selector()
  |> process.select_specific_monitor(watch, fn(event) { event.reason })
  |> process.selector_receive(waiting)
}

/// Supplies a finite resolver barrier for joined domain ownership fixtures.
///
/// ## Examples
///
/// ```gleam
/// // config(name, arrivals, "manager-close")
/// ```
@internal
pub fn config(name, arrivals, lane) {
  let assert Ok(here) = simplifile.current_directory()
    as "test working directory must resolve"
  let root = here <> "/build/test_db/domain-cadence-" <> lane
  let _stale = simplifile.delete(root)
  let assert Ok(Nil) = simplifile.create_directory_all(root)
    as "test root must be creatable"
  distillpass.DomainConfig(
    name:,
    pipeline: distill.config_for(
      root,
      distill.no_distiller(),
      clock: clock.fixed(at: 1000),
      entropy: fn() { 42 },
    ),
    sources: fn() {
      let gate = process.new_subject()
      process.send(arrivals, gate)
      case process.receive(gate, 3000) {
        Ok(answer) -> answer
        Error(Nil) -> Error("test resolver gate expired")
      }
    },
    gateway: gateway.new(
      transport: provider.silent(),
      secrets: secret.from_list([]),
      clock: clock.fixed(at: 1000),
    ),
    target: model.ForRole(model.Main, None),
    request_timeout_ms: 1000,
    options: distillpass.Options(distillpass.DistillsOnBoot, wall_ms: 4000),
  )
}
