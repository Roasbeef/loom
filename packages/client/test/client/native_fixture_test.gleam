//// Native fixture cleanup must precede success and failure reporting.
////
//// A detached sleep process exercises the same paused launch, durable birth
//// fence and process-group retirement as a real daemon, without a model or
//// sandbox dependency. The outer observer always retires its own process after
//// sampling absence, so a broken cleanup regression does not leak a child.

import gleam/erlang/process
import host/bootstrap as native
import host/endpoint
import support/native_fixture
import support/remote_daemons
import weft

type Body {
  Succeeds
  Crashes
  TimesOut
}

pub fn a_successful_fixture_retires_its_native_process_test() {
  let outcomes = witness(Succeeds)
  assert outcomes == [weft.Completed(0, 42)]
}

pub fn an_assertion_failure_retires_before_it_is_reported_test() {
  let outcomes = witness(Crashes)
  let assert [weft.Crashed(0, _)] = outcomes
    as "cleanup preserves an assertion failure"
}

pub fn a_body_deadline_retires_before_it_is_reported_test() {
  let outcomes = witness(TimesOut)
  let assert [weft.Crashed(0, _)] = outcomes
    as "the cancelled body remains a failed fixture"
}

fn witness(mode: Body) -> List(weft.Outcome(Int, Nil)) {
  let observed = process.new_subject()
  let outcomes =
    weft.new([
      fn() {
        let value = {
          use directory <- native_fixture.with_directory("native-owner", 5000)
          let #(paths, fence) = detached(directory)
          process.send(observed, #(paths, fence))

          // A deadline and an assertion must traverse the same teardown as a
          // successful body, while retaining their failed fixture outcome.
          case mode {
            Succeeds -> 42
            Crashes -> fail(mode)
            TimesOut -> {
              process.sleep_forever()
              0
            }
          }
        }
        Ok(value)
      },
    ])
    |> weft.deadline(20_000)
    |> weft.start
  let assert Ok(#(paths, fence)) = process.receive(observed, 1000)
    as "the managed body published its native ownership"
  let departed = endpoint.is_present(fence)

  // This fallback keeps the negative control from becoming another leak.
  // Read the observation before cleanup, then assert it after safe retirement.
  remote_daemons.retire(paths)
  assert departed == Ok(False)
  outcomes
}

fn detached(directory: String) -> #(endpoint.Paths, endpoint.Fence) {
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "the fixture's native state is private"
  let assert Ok(#(child, pid)) =
    native.spawn_server("/bin/sleep", ["60"], directory, paths.log)
    as "a real native child waits behind the launch barrier"
  let assert Ok(fence) = endpoint.observe(pid)
    as "native ownership is a birth identity rather than a PID alone"
  let assert Ok(Nil) = endpoint.write(paths, endpoint.Starting(fence))
    as "ownership is durable before the child is released"
  let assert Ok(Nil) = native.release_server_process(child)
    as "the wrapper releases its detached native child"
  native.close_server_process(child)
  let assert Ok(True) = endpoint.is_present(fence)
    as "the child is live before the fixture body finishes"
  #(paths, fence)
}

fn fail(mode: Body) -> Int {
  let assert Succeeds = mode as "intentional fixture assertion failure"
  0
}
