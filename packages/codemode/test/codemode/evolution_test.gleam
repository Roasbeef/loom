//// The evolution router claims exactly its six names, forwards the decoded
//// arguments to the right door, and words a refusal under one code.

import broker/budget
import broker/exec
import broker/framing
import broker/policy
import codemode/evolution
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/json
import core/msgpack
import gleam/erlang/process
import gleam/list

const t = 1_700_000_000_000

fn request(cap: String, args: msgpack.MsgPackValue) -> satellite.CapRequest {
  let generator = ids.generator(clock.fixed(at: t), seed: 31)
  let #(op, _generator) = ids.mint_op(generator)
  satellite.CapRequest(
    cap:,
    args:,
    identity: identity.run_phase(identity.for_execution(
      op_id: op,
      step_id: "turn-1:tools",
      budget: budget.Budget(max_outstanding: 8, deadline_ms: t + 60_000),
    )),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [],
    cwd: "/work",
    ordinal: 0,
  )
}

// A door whose every operation answers with its own name, so a test reads
// which closure the router chose from the reply alone.
fn echoing() -> evolution.Door {
  let named = fn(name: String) {
    fn(ordinal, arguments) {
      Ok(
        json.Object([
          #("door", json.String(name)),
          #("ordinal", json.Int(ordinal)),
          #("args", arguments),
        ]),
      )
    }
  }
  evolution.Door(
    propose: named("propose"),
    test_candidate: named("test"),
    inspect: named("inspect"),
    catalogue: named("catalogue"),
    invoke: named("invoke"),
    trace: named("trace"),
  )
}

fn unrouted(_request: satellite.CapRequest) {
  Error(satellite.CapDenial(code: "inner", message: "inner router reached"))
}

fn served(
  router: satellite.CapRouter,
  cap: String,
  args: msgpack.MsgPackValue,
) -> framing.CapOutcome {
  let assert Ok(satellite.ServedHere(serve)) = router(request(cap, args))
  serve()
}

fn text_args(key: String, value: String) -> msgpack.MsgPackValue {
  msgpack.MapValue([#(msgpack.StringValue(key), msgpack.StringValue(value))])
}

pub fn every_serviced_name_reaches_its_own_door_test() {
  let router = evolution.routing(echoing(), over: unrouted)
  let expected = [
    #("evolution.propose", "propose"),
    #("evolution.test", "test"),
    #("evolution.inspect", "inspect"),
    #("evolution.catalogue", "catalogue"),
    #("evolution.invoke", "invoke"),
    #("evolution.trace", "trace"),
  ]
  assert list.map(expected, fn(entry) { entry.0 }) == evolution.serviced_caps
  list.each(expected, fn(entry) {
    let assert framing.CapOk(msgpack.MapValue(fields)) =
      served(router, entry.0, text_args("candidate_id", "abc"))
    assert list.key_find(
        list.map(fields, fn(field) {
          let assert #(msgpack.StringValue(key), value) = field
          #(key, value)
        }),
        "door",
      )
      == Ok(msgpack.StringValue(entry.1))
  })
}

pub fn a_name_outside_the_six_falls_through_test() {
  let router = evolution.routing(echoing(), over: unrouted)
  assert router(request("fs.read", msgpack.MapValue([])))
    == Error(satellite.CapDenial(code: "inner", message: "inner router reached"))
}

pub fn a_refusal_travels_under_one_code_with_the_door_sentence_test() {
  let refusing =
    evolution.Door(..echoing(), invoke: fn(_ordinal, _arguments) {
      Error("Stale: the selected generation moved")
    })
  let router = evolution.routing(refusing, over: unrouted)
  assert served(router, "evolution.invoke", msgpack.MapValue([]))
    == framing.CapErr(
      code: evolution.refused_code,
      message: "Stale: the selected generation moved",
    )
}

pub fn binary_arguments_are_refused_before_any_door_runs_test() {
  let entered = process.new_subject()
  let watching =
    evolution.Door(..echoing(), propose: fn(_ordinal, _arguments) {
      process.send(entered, Nil)
      Ok(json.Null)
    })
  let router = evolution.routing(watching, over: unrouted)
  let args =
    msgpack.MapValue([
      #(msgpack.StringValue("name"), msgpack.BinaryValue(<<1, 2>>)),
    ])
  let assert Error(satellite.CapDenial(code: "invalid_argument", ..)) =
    router(request("evolution.propose", args))
  assert process.receive(entered, 0) == Error(Nil)
}

pub fn the_calls_ordinal_reaches_its_door_test() {
  let router = evolution.routing(echoing(), over: unrouted)
  let call =
    satellite.CapRequest(
      ..request("evolution.invoke", msgpack.MapValue([])),
      ordinal: 7,
    )
  let assert Ok(satellite.ServedHere(serve)) = router(call)
  let assert framing.CapOk(msgpack.MapValue(fields)) = serve()
  assert list.contains(fields, #(
    msgpack.StringValue("ordinal"),
    msgpack.IntValue(7),
  ))
}

pub fn each_name_has_a_ceiling_test() {
  assert list.map(evolution.ceilings(), fn(ceiling) { ceiling.cap })
    == evolution.serviced_caps
}
