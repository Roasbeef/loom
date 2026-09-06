//// The opening request and the resident builder have different lifetimes.
//// These tests exercise that boundary with deterministic cleanup capabilities;
//// real assembly and native retirement have separate integration coverage.

import client/internal/instance_host as host
import client/internal/instance_owner as custody
import gleam/erlang/process

pub fn prepared_host_does_no_work_and_begins_only_once_test() {
  let results = process.new_subject()
  let faults = process.new_subject()
  let failures = process.new_subject()
  let acquired = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(prepared) =
    host.prepare(
      build: fn(owner) {
        let assert Ok(Nil) =
          custody.publish(owner, custody.Storage, fn() {
            process.send(closed, Nil)
            Ok(Nil)
          })
          as "storage cleanup published before assembly completes"
        process.send(acquired, Nil)
        Ok("instance")
      },
      fatal: fn(_) { [] },
      results:,
      faults:,
      failures:,
    )
    as "host prepared without effects"
  assert process.receive(acquired, 20) == Error(Nil)
  host.begin(prepared)
  host.begin(prepared)
  assert process.receive(results, 1000) == Ok(Ok("instance"))
  assert process.receive(acquired, 1000) == Ok(Nil)
  assert process.receive(acquired, 20) == Error(Nil)
  assert process.is_alive(host.builder(prepared))
  assert host.close(prepared, within_ms: 1000) == custody.Closed
  assert process.receive(closed, 1000) == Ok(Nil)
  assert process.receive(failures, 0) == Error(Nil)
}

pub fn opening_job_return_does_not_close_the_instance_test() {
  let results = process.new_subject()
  let faults = process.new_subject()
  let failures = process.new_subject()
  let assert Ok(instance) =
    host.prepare(
      build: fn(_) { Ok("resident") },
      fatal: fn(_) { [] },
      results:,
      faults:,
      failures:,
    )
    as "registry creates and retains custody before dispatching an open"
  let job = process.spawn_unlinked(fn() { host.begin(instance) })
  let job_down = process.monitor(job)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(job_down, fn(down) { down })
    |> process.selector_receive(1000)
    as "opening request has returned"

  assert process.receive(results, 1000) == Ok(Ok("resident"))
  assert process.is_alive(host.builder(instance))
  assert host.close(instance, within_ms: 1000) == custody.Closed
}

pub fn raw_builder_kill_still_runs_published_cleanup_test() {
  let results = process.new_subject()
  let faults = process.new_subject()
  let failures = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(instance) =
    host.prepare(
      build: fn(owner) {
        let assert Ok(Nil) =
          custody.publish(owner, custody.Namespace, fn() {
            process.send(closed, Nil)
            Ok(Nil)
          })
          as "cleanup outlives the builder"
        Ok(Nil)
      },
      fatal: fn(_) { [] },
      results:,
      faults:,
      failures:,
    )
    as "host prepared"
  let watch = process.monitor(host.owner(instance))
  host.begin(instance)
  assert process.receive(results, 1000) == Ok(Ok(Nil))
  process.kill(host.builder(instance))
  assert process.receive(closed, 1000) == Ok(Nil)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "builder KILL did not kill its cleanup witness"
}

pub fn failed_assembly_reports_before_eventual_cleanup_test() {
  let results = process.new_subject()
  let faults = process.new_subject()
  let failures = process.new_subject()
  let draining = process.new_subject()
  let assert Ok(instance) =
    host.prepare(
      build: fn(owner) {
        let assert Ok(Nil) =
          custody.publish(owner, custody.Storage, fn() {
            let release = process.new_subject()
            process.send(draining, release)
            process.receive_forever(release)
            Ok(Nil)
          })
          as "partial acquisition was published"
        Error("later acquisition failed")
      },
      fatal: fn(_value: Nil) { [] },
      results:,
      faults:,
      failures:,
    )
    as "host prepared"
  let watch = process.monitor(host.owner(instance))
  host.begin(instance)
  assert process.receive(results, 1000) == Ok(Error("later acquisition failed"))
  let assert Ok(release) = process.receive(draining, 1000) as "cleanup started"
  assert host.close(instance, within_ms: 20) == custody.StillClosing
  process.send(release, Nil)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "failed open retained its reservation through cleanup"
}
