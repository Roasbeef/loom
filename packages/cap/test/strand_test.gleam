//// `cap/strand` and the structured values it carries: what a call puts
//// on the wire, what it makes of an answer, and which refusal name it
//// recovers from a broker code.
////
//// The refusal mapping is half of a contract whose other half is
//// `codemode/orchestration.refusal_code`. The two packages are the two
//// ends of one wire and share no dependency, so each pins its own side
//// and the round trip is proved by the orchestration sample, which really
//// crosses it.

import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/report
import cap/strand
import core/msgpack
import gleam/list
import gleam/option.{None, Some}
import gleeunit

pub fn main() -> Nil {
  gleeunit.main()
}

// A fake channel whose `call` is the given function, so marshalling and
// error mapping are tested without an actor or a socket.
fn install_fake(
  with call: fn(String, msgpack.MsgPackValue, Int) ->
    Result(msgpack.MsgPackValue, channel.CallError),
) -> Nil {
  dispatch.install(channel.Channel(call:))
}

fn map(entries: List(#(String, msgpack.MsgPackValue))) -> msgpack.MsgPackValue {
  wire.args(entries)
}

fn denied(
  code: String,
) -> fn(String, msgpack.MsgPackValue, Int) ->
  Result(msgpack.MsgPackValue, channel.CallError) {
  fn(_cap, _args, _deadline) { Error(channel.Denied(code, "because")) }
}

// --- what a spawn puts on the wire ----------------------------------------

pub fn a_spawn_carries_its_whole_assignment_test() {
  install_fake(with: fn(cap, args, _deadline) {
    assert cap == "strand.spawn"
    assert wire.string_field(args, "purpose") == Ok("review core")
    assert wire.string_field(args, "brief") == Ok("look for the symbol")
    assert wire.int_field(args, "within_ms") == Ok(5000)
    assert wire.bool_field(args, "detach") == Ok(True)
    assert wire.string_field(args, "context") == Ok("my_conversation")
    assert wire.array_field(args, "tools")
      == Ok([msgpack.StringValue("fs_read")])
    Ok(
      map([
        #("strand", msgpack.StringValue("sub:main/review-core-turn-1-0")),
        #("operation", msgpack.StringValue("op_1")),
      ]),
    )
  })
  let spawned =
    strand.assignment(purpose: "review core", brief: "look for the symbol")
    |> strand.within(5000)
    |> strand.detached
    |> strand.from_my_conversation
    |> strand.with_tools(["fs_read"])
    |> strand.spawn
  assert spawned
    == Ok(strand.Handle(
      strand: "sub:main/review-core-turn-1-0",
      operation: "op_1",
    ))
}

pub fn an_unset_assignment_sends_nothing_rather_than_a_default_test() {
  // The harness decides the default budget, the default provenance and
  // the default tool set; a program that named none must not be read as
  // having named one.
  install_fake(with: fn(_cap, args, _deadline) {
    assert wire.optional_field(args, "within_ms") == None
    assert wire.optional_field(args, "tools") == None
    assert wire.optional_field(args, "result_schema") == None
    assert wire.bool_field(args, "detach") == Ok(False)
    assert wire.string_field(args, "context") == Ok("fresh")
    Ok(
      map([
        #("strand", msgpack.StringValue("sub:main/a")),
        #("operation", msgpack.StringValue("op_1")),
      ]),
    )
  })
  let assert Ok(_handle) =
    strand.spawn(strand.assignment(purpose: "a", brief: "b"))
    as "a bare assignment must spawn"
}

pub fn a_result_shape_crosses_as_field_descriptors_test() {
  // Descriptors, not a schema document: the harness builds the schema
  // from these and runs it through its own parser, so a program cannot
  // state a constraint nothing will check.
  install_fake(with: fn(_cap, args, _deadline) {
    let assert Ok([first, second]) = wire.array_field(args, "result_schema")
      as "two declared fields"
    assert wire.string_field(first, "name") == Ok("hits")
    assert wire.string_field(first, "type") == Ok("integer")
    assert wire.bool_field(first, "required") == Ok(True)
    assert wire.string_field(second, "type") == Ok("array")
    let assert Ok(items) = wire.field(second, "items") as "an element type"
    assert wire.string_field(items, "type") == Ok("string")
    assert wire.bool_field(second, "required") == Ok(False)
    Ok(
      map([
        #("strand", msgpack.StringValue("sub:main/a")),
        #("operation", msgpack.StringValue("op_1")),
      ]),
    )
  })
  let assert Ok(_handle) =
    strand.assignment(purpose: "a", brief: "b")
    |> strand.expecting([
      strand.required("hits", strand.IntegerField),
      strand.optional("files", strand.ArrayField(items: strand.StringField)),
    ])
    |> strand.spawn
    as "a declared shape must spawn"
}

// --- what a join makes of an answer ---------------------------------------

pub fn a_join_decodes_every_shape_of_answer_test() {
  install_fake(with: fn(cap, args, deadline) {
    assert cap == "strand.wait"
    assert wire.int_field(args, "within_ms") == Ok(4000)
    // The channel waits past the join's own window, never inside it: the
    // harness answers `Pending` at the deadline rather than hanging.
    assert deadline == 4000 + strand.wait_margin_ms
    Ok(
      map([
        #(
          "waited",
          msgpack.ArrayValue([
            map([
              #("kind", msgpack.StringValue("ready")),
              #("strand", msgpack.StringValue("sub:main/a")),
              #("operation", msgpack.StringValue("op_1")),
              #("outcome", map([#("kind", msgpack.StringValue("completed"))])),
              #("report", msgpack.StringValue("done")),
              #(
                "result",
                map([
                  #("kind", msgpack.StringValue("given")),
                  #("value", map([#("hits", msgpack.IntValue(2))])),
                ]),
              ),
              #(
                "notes",
                msgpack.ArrayValue([
                  map([
                    #("key", msgpack.StringValue("k")),
                    #("value", msgpack.StringValue("v")),
                  ]),
                ]),
              ),
            ]),
            map([
              #("kind", msgpack.StringValue("pending")),
              #("strand", msgpack.StringValue("sub:main/b")),
              #("operation", msgpack.StringValue("op_2")),
              #("waited_ms", msgpack.IntValue(4000)),
            ]),
          ]),
        ),
      ]),
    )
  })
  let assert Ok([first, second]) =
    strand.wait(
      [
        strand.Handle(strand: "sub:main/a", operation: "op_1"),
        strand.Handle(strand: "sub:main/b", operation: "op_2"),
      ],
      within_ms: 4000,
    )
    as "the join must decode"
  let assert strand.Ready(handle:, outcome:, report:, result:, notes:) = first
    as "the first handle settled"
  assert handle == strand.Handle(strand: "sub:main/a", operation: "op_1")
  assert outcome == strand.Completed
  assert report == "done"
  assert result
    == strand.ResultGiven(
      value: report.object([
        #("hits", report.int(2)),
      ]),
    )
  assert notes == [#("k", report.string("v"))]
  assert second
    == strand.Pending(
      handle: strand.Handle(strand: "sub:main/b", operation: "op_2"),
      waited_ms: 4000,
    )
  // A program that only wants to know whether to come back again.
  assert strand.pending_count([first, second]) == 1
}

pub fn the_three_unhappy_result_verdicts_decode_test() {
  // Three facts, not one failure. A program that asked for a shape needs
  // to tell "nobody answered" from "the answer was wrong".
  assert decoded_result(map([#("kind", msgpack.StringValue("none"))]))
    == strand.NoResultAsked
  assert decoded_result(
      map([
        #("kind", msgpack.StringValue("absent")),
        #("schema", msgpack.StringValue("{...}")),
      ]),
    )
    == strand.ResultAbsent(schema: "{...}")
  assert decoded_result(
      map([
        #("kind", msgpack.StringValue("unusable")),
        #("schema", msgpack.StringValue("{...}")),
        #("received", msgpack.StringValue("prose")),
        #("reason", msgpack.StringValue("`hits` is not an integer")),
      ]),
    )
    == strand.ResultUnusable(
      schema: "{...}",
      received: report.string("prose"),
      reason: "`hits` is not an integer",
    )
}

fn decoded_result(result: msgpack.MsgPackValue) -> strand.TerminalResult {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #(
          "waited",
          msgpack.ArrayValue([
            map([
              #("kind", msgpack.StringValue("ready")),
              #("strand", msgpack.StringValue("sub:main/a")),
              #("operation", msgpack.StringValue("op_1")),
              #("outcome", map([#("kind", msgpack.StringValue("completed"))])),
              #("report", msgpack.StringValue("")),
              #("result", result),
              #("notes", msgpack.ArrayValue([])),
            ]),
          ]),
        ),
      ]),
    )
  })
  let assert Ok([strand.Ready(result: verdict, ..)]) =
    strand.wait(
      [strand.Handle(strand: "sub:main/a", operation: "op_1")],
      within_ms: 1,
    )
    as "one settled handle"
  verdict
}

pub fn a_failed_or_aborted_child_decodes_test() {
  assert decoded_outcome(
      map([
        #("kind", msgpack.StringValue("failed")),
        #("reason", msgpack.StringValue("the model gave up")),
      ]),
    )
    == strand.Failed(reason: "the model gave up")
  assert decoded_outcome(map([#("kind", msgpack.StringValue("aborted"))]))
    == strand.Aborted
}

fn decoded_outcome(outcome: msgpack.MsgPackValue) -> strand.Outcome {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #(
          "waited",
          msgpack.ArrayValue([
            map([
              #("kind", msgpack.StringValue("ready")),
              #("strand", msgpack.StringValue("sub:main/a")),
              #("operation", msgpack.StringValue("op_1")),
              #("outcome", outcome),
              #("report", msgpack.StringValue("")),
              #("result", map([#("kind", msgpack.StringValue("none"))])),
              #("notes", msgpack.ArrayValue([])),
            ]),
          ]),
        ),
      ]),
    )
  })
  let assert Ok([strand.Ready(outcome: settled, ..)]) =
    strand.wait(
      [strand.Handle(strand: "sub:main/a", operation: "op_1")],
      within_ms: 1,
    )
    as "one settled handle"
  settled
}

// --- addressing and the blackboard ----------------------------------------

pub fn a_send_reports_how_it_landed_test() {
  install_fake(with: fn(cap, args, _deadline) {
    assert cap == "strand.send"
    assert wire.string_field(args, "to") == Ok("main")
    assert wire.string_field(args, "text") == Ok("found it")
    Ok(
      map([
        #("kind", msgpack.StringValue("steered")),
        #("entry", msgpack.StringValue("ent_1")),
      ]),
    )
  })
  assert strand.send(to: "main", text: "found it")
    == Ok(strand.Steered(entry: "ent_1"))
}

pub fn a_note_and_a_notes_read_round_trip_test() {
  install_fake(with: fn(cap, args, _deadline) {
    case cap {
      "strand.note" -> {
        assert wire.string_field(args, "key") == Ok("found")
        assert wire.field(args, "value")
          == Ok(report.object([#("n", report.int(1))]))
        Ok(msgpack.NilValue)
      }
      _ ->
        Ok(
          map([
            #(
              "notes",
              msgpack.ArrayValue([
                map([
                  #("key", msgpack.StringValue("agent/main/found")),
                  #("value", msgpack.IntValue(1)),
                ]),
              ]),
            ),
          ]),
        )
    }
  })
  assert strand.note(
      key: "found",
      value: report.object([
        #("n", report.int(1)),
      ]),
    )
    == Ok(Nil)
  assert strand.notes(Some("found"))
    == Ok([#("agent/main/found", report.int(1))])
}

pub fn a_roster_decodes_a_peer_with_and_without_a_handle_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(
      map([
        #(
          "peers",
          msgpack.ArrayValue([
            map([
              #("strand", msgpack.StringValue("main")),
              #("relation", msgpack.StringValue("parent")),
              #("handle", msgpack.NilValue),
              #("outcome", msgpack.NilValue),
              #("tools", msgpack.ArrayValue([])),
            ]),
            map([
              #("strand", msgpack.StringValue("sub:main/a")),
              #("relation", msgpack.StringValue("child")),
              #(
                "handle",
                map([
                  #("strand", msgpack.StringValue("sub:main/a")),
                  #("operation", msgpack.StringValue("op_1")),
                ]),
              ),
              #("outcome", map([#("kind", msgpack.StringValue("completed"))])),
              #("tools", msgpack.ArrayValue([msgpack.StringValue("fs_read")])),
            ]),
          ]),
        ),
      ]),
    )
  })
  let assert Ok([parent, child]) = strand.roster() as "two peers"
  assert parent.relation == strand.ParentOf
  assert parent.handle == None
  assert parent.outcome == None
  assert child.relation == strand.ChildOf
  assert child.handle
    == Some(strand.Handle(strand: "sub:main/a", operation: "op_1"))
  assert child.outcome == Some(strand.Completed)
  assert child.tools == ["fs_read"]
}

// --- refusals -------------------------------------------------------------

pub fn every_refusal_code_recovers_its_name_test() {
  // The other half of `codemode/orchestration.refusal_code`. The two
  // packages share no dependency — they are the ends of one wire — so
  // each pins its own side and the sample crosses it for real.
  let cases = [
    #("strands_unavailable", strand.StrandsUnavailable("because")),
    #("malformed_handle", strand.MalformedHandle("because")),
    #("not_addressable", strand.NotAddressable("because")),
    #("not_a_descendant", strand.NotADescendant("because")),
    #("depth_cap", strand.DepthCapReached("because")),
    #("fan_out_cap", strand.FanOutCapReached("because")),
    #("unknown_tool", strand.UnknownTool("because")),
    #("invalid_argument", strand.InvalidArgument("because")),
    #("parent_run_ended", strand.ParentRunEnded("because")),
    #("result_schema_unmet", strand.ResultSchemaUnmet("because")),
    #("spawn_ceiling", strand.SpawnCeilingReached("because")),
  ]
  assert list.all(cases, fn(one) {
    install_fake(with: denied(one.0))
    strand.roster() == Error(one.1)
  })
}

pub fn an_unknown_code_arrives_as_itself_test() {
  // Not swallowed into a generic failure: a name this module has not
  // learned yet still reaches the program with its code intact.
  install_fake(with: denied("something_new"))
  assert strand.roster()
    == Error(strand.StrandRefused(code: "something_new", message: "because"))
}

pub fn a_broken_channel_is_not_a_refusal_test() {
  install_fake(with: fn(_cap, _args, _deadline) {
    Error(channel.Unreachable("the node is going down"))
  })
  assert strand.spawn(strand.assignment(purpose: "a", brief: "b"))
    == Error(strand.StrandUnavailable("the node is going down"))
}

pub fn a_malformed_answer_settles_in_band_test() {
  // The harness is trusted to be well-behaved; the decoders exist so that
  // a malformed answer is still a value the program reads rather than a
  // dead node.
  install_fake(with: fn(_cap, _args, _deadline) {
    Ok(map([#("strand", msgpack.IntValue(7))]))
  })
  let assert Error(strand.StrandUnavailable(reason:)) =
    strand.spawn(strand.assignment(purpose: "a", brief: "b"))
    as "a wrong-shaped answer must settle in band"
  assert reason != ""
}

// --- rendering ------------------------------------------------------------

pub fn a_handle_renders_the_way_the_harness_writes_it_test() {
  assert strand.handle_text(strand.Handle(strand: "sub:a", operation: "op_1"))
    == "sub:a#op_1"
}

pub fn a_refusal_and_a_join_render_for_a_report_test() {
  assert strand.error_text(strand.NotADescendant("nope"))
    == "not_a_descendant: nope"
  assert strand.waited_text(strand.Pending(
      handle: strand.Handle(strand: "sub:a", operation: "op_1"),
      waited_ms: 20,
    ))
    == "sub:a#op_1 pending after 20ms"
  assert strand.waited_text(
      strand.Ready(
        handle: strand.Handle(strand: "sub:a", operation: "op_1"),
        outcome: strand.Failed(reason: "gave up"),
        report: "",
        result: strand.NoResultAsked,
        notes: [],
      ),
    )
    == "sub:a#op_1 failed: gave up"
}

// --- structured values ----------------------------------------------------

pub fn a_program_can_build_and_read_a_structured_value_test() {
  // Without these a program could only ever return prose: the value type
  // lives in a module the vetting allowlist does not carry and the
  // hermetic build refuses to import.
  let value =
    report.object([
      #("name", report.string("core")),
      #("hits", report.int(2)),
      #("ratio", report.float(0.5)),
      #("clean", report.bool(False)),
      #("files", report.list([report.string("a"), report.string("b")])),
      #("note", report.null()),
    ])
  let assert Ok(name) = report.field(value, "name") as "a name field"
  assert report.as_string(name) == Ok("core")
  let assert Ok(hits) = report.field(value, "hits") as "a hits field"
  assert report.as_int(hits) == Ok(2)
  let assert Ok(clean) = report.field(value, "clean") as "a clean field"
  assert report.as_bool(clean) == Ok(False)
  let assert Ok(files) = report.field(value, "files") as "a files field"
  assert report.as_list(files) == Ok([report.string("a"), report.string("b")])
  assert report.field(value, "missing") == Error(Nil)
  assert report.field(report.int(1), "any") == Error(Nil)
}

pub fn a_reader_never_coerces_test() {
  // A float read as an integer is how a count becomes wrong, so it is an
  // error rather than a rounding.
  assert report.as_int(report.float(1.0)) == Error(Nil)
  assert report.as_string(report.int(1)) == Error(Nil)
  assert report.as_bool(report.string("true")) == Error(Nil)
  assert report.as_list(report.object([])) == Error(Nil)
  assert report.as_string(report.null()) == Error(Nil)
}

pub fn a_structured_outcome_marshals_the_way_the_host_reads_it_test() {
  let outcome = report.value(report.object([#("hits", report.int(3))]))
  assert report.to_msgpack(outcome)
    == msgpack.MapValue([
      #(msgpack.StringValue("ok"), msgpack.BoolValue(True)),
      #(
        msgpack.StringValue("value"),
        msgpack.MapValue([
          #(msgpack.StringValue("hits"), msgpack.IntValue(3)),
        ]),
      ),
    ])
}
