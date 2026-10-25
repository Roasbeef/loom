//// Round trips for `cap/evolution`: the exact capability name and
//// arguments each stub puts on the wire, and the refusal-code mapping.
////
//// The router that answers these names is `codemode/evolution`, tested in
//// the codemode package. `cap` and `codemode` share no dependency, so each
//// suite pins the same literals and a key renamed on one side only fails
//// one of the two.

import cap/evolution
import cap/internal/channel
import cap/internal/dispatch
import cap/internal/wire
import cap/report
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process
import gleam/option.{Some}

// A fake channel answering every call with `reply`, handing back a reader
// for the capability name and arguments it was given.
fn answering(
  reply: MsgPackValue,
) -> fn() -> Result(#(String, MsgPackValue), Nil) {
  let sent = process.new_subject()
  dispatch.install(
    channel.Channel(call: fn(cap, args, _deadline) {
      process.send(sent, #(cap, args))
      Ok(reply)
    }),
  )
  fn() { process.receive(sent, 100) }
}

pub fn propose_sends_required_fields_and_omits_absent_ones_test() {
  let sent = answering(report.object([#("candidate_id", report.string("c1"))]))
  let assert Ok(_) =
    evolution.propose(evolution.proposal(
      "skills/tally",
      "tally",
      evolution.Program,
    ))
  assert sent()
    == Ok(#(
      "evolution.propose",
      wire.args([
        #("directory", wire.string("skills/tally")),
        #("name", wire.string("tally")),
        #("kind", wire.string("program")),
      ]),
    ))
}

pub fn propose_sends_every_optional_field_that_is_set_test() {
  let sent = answering(report.null())
  let assert Ok(_) =
    evolution.propose(
      evolution.Proposal(
        ..evolution.proposal("ext/echo", "echo", evolution.Extension),
        test_entry: Some("check"),
        description: Some("Echoes."),
        input_schema: Some("{}"),
      ),
    )
  let assert Ok(#("evolution.propose", args)) = sent()
  assert args
    == wire.args([
      #("directory", wire.string("ext/echo")),
      #("name", wire.string("echo")),
      #("kind", wire.string("extension")),
      #("test_entry", wire.string("check")),
      #("description", wire.string("Echoes.")),
      #("input_schema", wire.string("{}")),
    ])
}

pub fn compare_sends_every_limit_with_one_sample_by_default_test() {
  let sent = answering(report.null())
  let assert Ok(_) = evolution.compare("c1", "ts1", evolution.native_limits())
  let assert Ok(#("evolution.test", args)) = sent()
  assert args == compare_args(1)
}

// A program asks for two samples and the wire carries exactly that number;
// the host's door, not this stub, enforces the cap of three
// (`model_door.samples`), so the stub sends what it was given.
pub fn cap_limits_carry_samples_test() {
  let sent = answering(report.null())
  let assert Ok(_) =
    evolution.compare(
      "c1",
      "ts1",
      evolution.Limits(..evolution.native_limits(), samples: 2),
    )
  let assert Ok(#("evolution.test", args)) = sent()
  assert args == compare_args(2)
}

fn compare_args(samples: Int) -> MsgPackValue {
  wire.args([
    #("candidate_id", wire.string("c1")),
    #("taskset_id", wire.string("ts1")),
    #(
      "limits",
      wire.args([
        #("trials", wire.int(20)),
        #("turns", wire.int(100)),
        #("tokens", wire.int(1_000_000)),
        #("dollars", report.float(2.0)),
        #("output_bytes", wire.int(65_536)),
        #("wall_ms", wire.int(480_000)),
        #("samples", wire.int(samples)),
      ]),
    ),
  ])
}

pub fn inspect_names_the_target_and_the_offset_test() {
  let sent = answering(report.null())
  let assert Ok(_) = evolution.inspect(evolution.EvidenceBytes("e1"), 4096)
  assert sent()
    == Ok(#(
      "evolution.inspect",
      wire.args([
        #("evidence_id", wire.string("e1")),
        #("offset_bytes", wire.int(4096)),
      ]),
    ))
}

pub fn invoke_passes_the_arguments_value_through_unchanged_test() {
  let arguments = report.object([#("path", report.string("a.csv"))])
  let sent = answering(report.null())
  let assert Ok(_) = evolution.invoke("c1", 3, "tally", arguments)
  assert sent()
    == Ok(#(
      "evolution.invoke",
      wire.args([
        #("candidate_id", wire.string("c1")),
        #("generation", wire.int(3)),
        #("tool", wire.string("tally")),
        #("arguments", arguments),
      ]),
    ))
}

pub fn catalogue_and_trace_send_their_bounds_test() {
  let sent = answering(report.null())
  let assert Ok(_) = evolution.catalogue(0, 8, 4)
  assert sent()
    == Ok(#(
      "evolution.catalogue",
      wire.args([
        #("offset", wire.int(0)),
        #("candidate_offset", wire.int(8)),
        #("count", wire.int(4)),
      ]),
    ))
  let assert Ok(_) = evolution.trace(12)
  assert sent()
    == Ok(#("evolution.trace", wire.args([#("limit", wire.int(12))])))
}

pub fn a_denied_call_keeps_its_code_and_sentence_test() {
  dispatch.install(
    channel.Channel(call: fn(_cap, _args, _deadline) {
      Error(channel.Denied(
        code: "evolution_refused",
        message: "Stale: the selected generation moved",
      ))
    }),
  )
  assert evolution.test_candidate("c1")
    == Error(evolution.EvolutionDenied(
      code: "evolution_refused",
      message: "Stale: the selected generation moved",
    ))
  assert evolution.error_text(evolution.EvolutionDenied("a", "b")) == "a: b"
}
