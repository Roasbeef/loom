//// Capture is admitted once and returns fixed facts with provenance outside
//// the four tables. SQL text never appears on this harness-side door.

import broker/budget
import broker/exec
import broker/framing
import broker/policy
import codemode/identity
import codemode/observation
import codemode/satellite
import core/clock
import core/ids
import core/msgpack as m
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import lsp/observation as o
import lsp/query

fn map(fields: List(#(String, m.MsgPackValue))) -> m.MsgPackValue {
  m.MapValue(list.map(fields, fn(pair) { #(m.StringValue(pair.0), pair.1) }))
}

fn request(value: m.MsgPackValue) -> satellite.CapRequest {
  let #(op, _) = ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 1))
  satellite.CapRequest(
    cap: "lsp.snapshot",
    args: value,
    identity: identity.run_phase(identity.for_execution(
      op_id: op,
      step_id: "test",
      budget: budget.Budget(4, 1000),
    )),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [],
    cwd: "/work",
    ordinal: 0,
  )
}

fn scope() {
  map([
    #("server", m.StringValue("gleam")),
    #("root", m.StringValue("/work")),
    #("outlines", m.ArrayValue([m.StringValue("src/app.gleam")])),
    #(
      "targets",
      m.ArrayValue([
        map([
          #("symbol", m.StringValue("main")),
          #("path", m.StringValue("src/app.gleam")),
          #("line", m.IntValue(7)),
        ]),
      ]),
    ),
  ])
}

pub fn capture_is_scoped_and_preserves_metadata_test() {
  let seen = process.new_subject()
  let control = o.Control(deadline_ms: 1000, now: fn() { 10 })
  let door =
    o.Door(collect: fn(asked, actual_control) {
      process.send(seen, #(asked, actual_control.deadline_ms))
      Ok(o.Batch(
        requested: asked,
        root: "/work",
        generation: "sha256:generation",
        started_ms: 10,
        finished_ms: 20,
        outlined: ["/work/src/app.gleam"],
        documents: [o.Document("/work/src/app.gleam", "sha256:file", None)],
        symbols: [],
        targets: [],
        references: [],
        counts: o.Counts(2, 3, 1, 100),
      ))
    })
  let router =
    observation.routing(door, control, over: satellite.default_router)
  let assert Ok(satellite.ScopedService(serve)) = router(request(scope()))
    as "capture requires scoped service custody"
  assert process.receive(seen, 0) == Error(Nil)
  let assert framing.CapOk(answer) = serve()
    as "a complete batch becomes an observation"
  let assert Ok(#(asked, deadline)) = process.receive(seen, 100)
    as "collection ran exactly once"
  assert asked.targets
    == [query.SymbolQuery("main", Some("src/app.gleam"), Some(7))]
  assert deadline == 1000
  assert answer
    == map([
      #("server", m.StringValue("gleam")),
      #("root", m.StringValue("/work")),
      #("generation", m.StringValue("sha256:generation")),
      #("started_ms", m.IntValue(10)),
      #("finished_ms", m.IntValue(20)),
      #("outlined", m.ArrayValue([m.StringValue("/work/src/app.gleam")])),
      #(
        "asked_targets",
        m.ArrayValue([
          map([
            #("symbol", m.StringValue("main")),
            #("path", m.StringValue("src/app.gleam")),
            #("line", m.IntValue(7)),
          ]),
        ]),
      ),
      #("requests", m.IntValue(2)),
      #("withheld", m.IntValue(3)),
      #("facts", m.IntValue(1)),
      #("fact_bytes", m.IntValue(100)),
      #(
        "documents",
        m.ArrayValue([
          m.ArrayValue([
            m.StringValue("/work/src/app.gleam"),
            m.StringValue("sha256:file"),
            m.NilValue,
          ]),
        ]),
      ),
      #("symbols", m.ArrayValue([])),
      #("targets", m.ArrayValue([])),
      #("references", m.ArrayValue([])),
    ])
}

pub fn malformed_capture_spends_no_server_request_test() {
  let door =
    o.Door(collect: fn(_, _) {
      panic as "malformed capture must not reach collector"
    })
  let router =
    observation.routing(
      door,
      o.Control(1000, fn() { 0 }),
      over: satellite.default_router,
    )
  let assert Error(denial) = router(request(m.NilValue))
    as "a malformed capture is denied during admission"
  assert denial.code == "invalid_argument"
  assert observation.ceilings()
    == [satellite.CapCeiling("lsp.snapshot", 4, "snapshot_ceiling")]
}
