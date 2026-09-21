//// Batching must preserve custody and stop before exceeding its live-child bound.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/report
import cap/strand
import core/msgpack
import gleam/erlang/process
import gleam/int
import gleam/list

fn assignments(count: Int) -> List(strand.Assignment) {
  list.index_map(list.repeat(Nil, count), fn(_, i) {
    strand.assignment(purpose: int.to_string(i), brief: "work")
  })
}

fn handle(name: String) -> strand.Handle {
  strand.Handle(strand: name, operation: "op-" <> name)
}

fn handle_value(name: String) -> report.Value {
  report.object([
    #("strand", report.string(name)),
    #("operation", report.string("op-" <> name)),
  ])
}

fn ready(value: report.Value) -> report.Value {
  let assert Ok(name) = wire.string_field(value, "strand")
    as "fixture handle has a strand"
  let assert Ok(op) = wire.string_field(value, "operation")
    as "fixture handle has an operation"
  report.object([
    #("kind", report.string("ready")),
    #("strand", report.string(name)),
    #("operation", report.string(op)),
    #("outcome", report.object([#("kind", report.string("completed"))])),
    #("report", report.string("done")),
    #("result", report.object([#("kind", report.string("none"))])),
    #("notes", report.list([])),
  ])
}

fn install(
  events: process.Subject(String),
  spawn_failure: String,
  join_kind: String,
) {
  dispatch.install(
    channel.Channel(call: fn(cap, args, _) {
      case cap {
        "strand.spawn" -> {
          let assert Ok(name) = wire.string_field(args, "purpose")
            as "spawn has a purpose"
          process.send(events, "spawn:" <> name)
          case name == spawn_failure {
            True -> Error(channel.Denied("fan_out_cap", "full"))
            False -> Ok(handle_value(name))
          }
        }
        "strand.wait" -> {
          let assert Ok(handles) = wire.array_field(args, "handles")
            as "join has handles"
          process.send(events, "wait:" <> int.to_string(list.length(handles)))
          case join_kind {
            "error" -> Error(channel.Unreachable("gone"))
            "mismatch" -> Ok(report.object([#("waited", report.list([]))]))
            "pending" ->
              Ok(
                report.object([
                  #(
                    "waited",
                    report.list(
                      list.map(handles, fn(value) {
                        let assert msgpack.MapValue(fields) = value
                          as "handle is an object"
                        msgpack.MapValue(
                          list.append(fields, [
                            #(
                              msgpack.StringValue("kind"),
                              report.string("pending"),
                            ),
                            #(msgpack.StringValue("waited_ms"), report.int(1)),
                          ]),
                        )
                      }),
                    ),
                  ),
                ]),
              )
            _ ->
              Ok(
                report.object([
                  #("waited", report.list(list.map(handles, ready))),
                ]),
              )
          }
        }
        _ -> panic as "map only spawns and joins"
      }
    }),
  )
}

fn events(events: process.Subject(String), count: Int) -> List(String) {
  list.map(list.repeat(Nil, count), fn(_) {
    let assert Ok(event) = process.receive(events, 100)
      as "expected an admission or join"
    event
  })
}

pub fn batches_preserve_order_and_release_slots_before_more_spawns_test() {
  let log = process.new_subject()
  install(log, "none", "ready")
  let assert Ok(mapped) =
    strand.map(assignments(5), max_concurrency: 2, within_ms: 10)
    as "valid map succeeds"
  assert events(log, 8)
    == [
      "spawn:0",
      "spawn:1",
      "wait:2",
      "spawn:2",
      "spawn:3",
      "wait:2",
      "spawn:4",
      "wait:1",
    ]
  assert list.index_map(mapped, fn(item, i) {
      let assert strand.Joined(strand.Ready(handle: actual, ..)) = item
        as "each child settled"
      actual == handle(int.to_string(i))
    })
    == [True, True, True, True, True]
}

pub fn pending_children_stop_admission_and_keep_unstarted_assignments_test() {
  let log = process.new_subject()
  install(log, "none", "pending")
  let assert Ok([
    strand.Joined(strand.Pending(handle: a, ..)),
    strand.Joined(strand.Pending(handle: b, ..)),
    strand.NotStarted(last),
  ]) = strand.map(assignments(3), max_concurrency: 2, within_ms: 1)
    as "pending batch retains both handles and remaining work"
  assert a == handle("0")
  assert b == handle("1")
  assert last == strand.assignment(purpose: "2", brief: "work")
  assert events(log, 3) == ["spawn:0", "spawn:1", "wait:2"]
  assert process.receive(log, 0) == Error(Nil)
}

pub fn a_later_spawn_failure_does_not_discard_previously_admitted_children_test() {
  let log = process.new_subject()
  install(log, "1", "ready")
  let assert Ok([
    strand.Joined(strand.Ready(handle: child, ..)),
    strand.SpawnFailed(_),
    strand.NotStarted(last),
  ]) = strand.map(assignments(3), max_concurrency: 3, within_ms: 10)
    as "earlier children are joined after a failed admission"
  assert child == handle("0")
  assert last == strand.assignment(purpose: "2", brief: "work")
  assert events(log, 3) == ["spawn:0", "spawn:1", "wait:1"]
}

pub fn failed_or_malformed_joins_preserve_all_handles_test() {
  list.each(["error", "mismatch"], fn(kind) {
    let log = process.new_subject()
    install(log, "none", kind)
    let assert Ok([
      strand.JoinFailed(a, _),
      strand.JoinFailed(b, _),
      strand.NotStarted(_),
    ]) = strand.map(assignments(3), max_concurrency: 2, within_ms: 10)
      as "join failures retain handles and stop further admission"
    assert a == handle("0")
    assert b == handle("1")
    assert events(log, 3) == ["spawn:0", "spawn:1", "wait:2"]
  })
}

pub fn invalid_map_options_and_empty_work_do_not_call_the_host_test() {
  dispatch.install(
    channel.Channel(call: fn(_, _, _) { panic as "no host calls expected" }),
  )
  list.each([#(0, 1), #(33, 1), #(1, -1)], fn(options) {
    let assert Error(strand.InvalidArgument(_)) =
      strand.map(
        assignments(1),
        max_concurrency: options.0,
        within_ms: options.1,
      )
      as "invalid bounds are refused before admission"
  })
  assert strand.map([], max_concurrency: 1, within_ms: 0) == Ok([])
}
