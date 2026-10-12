//// The reap's route to the broker: a send by address reaches the sweep.

import client/effect_abort
import core/clock
import core/ids
import gleam/erlang/process
import gleam/otp/static_supervisor as sup
import support/addresses

pub fn a_send_by_address_runs_the_sweep_with_that_operation_test() {
  let swept = process.new_subject()
  let name = addresses.new()
  let assert Ok(services) =
    sup.new(sup.OneForOne)
    |> sup.add(
      effect_abort.supervised(name, fn(operation) {
        process.send(swept, operation)
      }),
    )
    |> sup.start
    as "the sweep actor must start"
  process.unlink(services.pid)
  let assert Ok(_owner) = wait_for(name, 50) as "the sweep actor must register"
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 7))
  effect_abort.abort(name)(operation)
  assert process.receive(swept, 1000) == Ok(operation)
}

pub fn a_send_with_no_actor_is_dropped_test() {
  let name = addresses.new()
  let #(operation, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 7))
  assert effect_abort.abort(name)(operation) == Nil
}

fn wait_for(name, tries: Int) {
  case addresses.owner(name), tries {
    Ok(owner), _ -> Ok(owner)
    Error(Nil), 0 -> Error(Nil)
    Error(Nil), _ -> {
      process.sleep(10)
      wait_for(name, tries - 1)
    }
  }
}
