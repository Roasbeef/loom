//// These controls use actual owner custody and host SHA-256, without a satellite
//// fixture or an invented report door. `fixture` retains a canonical two-chunk
//// report through the original trusted runner. `request` deliberately uses a
//// different operation and step, so historical read authority comes only from
//// the assembly's owner/session pair. `stop` joins the original SQLite actor.
//// Framing width controls include the length prefix and the actual CapResult
//// fields; quota controls describe assembly, not a real satellite quota replay.

import broker/budget
import broker/exec
import broker/framing
import broker/policy
import client/remote/custodian
import client/remote/report_router as router
import client/remote/tool_custody
import codemode/identity
import codemode/satellite
import core/clock
import core/ids
import core/json
import core/message
import core/msgpack as mp
import core/report_value as rv
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import machine/operation
import runtime/effects
import simplifile
import storage/owner_custody as custody
import weft/registry

type Fixture {
  Fixture(
    owner: custodian.Handle,
    pid: process.Pid,
    reference: rv.ReportRef,
    report: rv.CompleteReport,
  )
}

pub fn actual_owner_reads_two_exact_chunks_from_different_invocation_test() {
  let f = fixture()
  let route = router.routing(f.owner, session(77), over: denied)
  let first = read(route, f.reference, 0)
  let second = read(route, f.reference, router.chunk_bytes)
  assert bit_array.byte_size(first) == router.chunk_bytes
  assert bit_array.byte_size(second) > 0
  assert <<first:bits, second:bits>> == rv.bytes(f.report)

  // Closed request order is irrelevant, but the response has one canonical shape.
  let reversed =
    mp.MapValue([
      #(mp.StringValue("offset"), mp.IntValue(0)),
      #(
        mp.StringValue("reference"),
        mp.StringValue(rv.ref_to_string(f.reference)),
      ),
    ])
  assert served(route, reversed) == served(route, input(f.reference, 0))
  stop(f)
}

pub fn exact_session_authority_and_missing_identity_never_delegate_test() {
  let f = fixture()
  let seen = process.new_subject()
  let route =
    router.routing(f.owner, session(78), over: fn(request) {
      process.send(seen, request)
      denied(request)
    })
  let assert Error(_) = route(request(router.capability, input(f.reference, 0)))
    as "A URI from another authenticated session cannot create authority."
  assert process.receive(seen, 0) == Error(Nil)

  // Same-session syntax cannot substitute another digest, length or original entry.
  let route =
    router.routing(f.owner, session(77), over: fn(request) {
      process.send(seen, request)
      denied(request)
    })
  let assert Ok(changed) =
    rv.reference(
      session(77),
      rv.ref_result_entry(f.reference),
      string.repeat("a", 64),
      rv.ref_byte_length(f.reference),
    )
    as "A syntactically valid wrong digest remains data, not authority."
  let assert framing.CapErr(..) = served(route, input(changed, 0))
    as "Actual stored digest mismatch is refused without fallback."
  let assert Ok(wrong_length) =
    rv.reference(
      session(77),
      rv.ref_result_entry(f.reference),
      rv.ref_digest(f.reference),
      rv.ref_byte_length(f.reference) + 1,
    )
    as "Changing the declared length does not change original custody."
  let assert framing.CapErr(..) = served(route, input(wrong_length, 0))
    as "Actual retained length mismatch is refused without fallback."

  // An absent original entry is a terminal known-capability refusal.
  let entry = ids.mint_entry(ids.generator(clock.fixed(3000), 50)).0
  let assert Ok(missing) =
    rv.reference(
      session(77),
      entry,
      rv.ref_digest(f.reference),
      rv.ref_byte_length(f.reference),
    )
    as "A different original entry is syntactically valid."
  let assert framing.CapErr(..) = served(route, input(missing, 0))
    as "Actual missing report is refused without fallback."
  assert process.receive(seen, 0) == Error(Nil)
  stop(f)
}

pub fn closed_arguments_reference_and_offset_bounds_refuse_before_read_test() {
  let f = fixture()
  let seen = process.new_subject()
  let route =
    router.routing(f.owner, session(77), over: fn(request) {
      process.send(seen, request)
      denied(request)
    })
  let text = mp.StringValue(rv.ref_to_string(f.reference))
  let invalid = [
    mp.NilValue,
    mp.MapValue([]),
    mp.MapValue([#(mp.StringValue("reference"), text)]),
    mp.MapValue([
      #(mp.StringValue("reference"), text),
      #(mp.StringValue("reference"), text),
    ]),
    mp.MapValue([
      #(mp.StringValue("reference"), text),
      #(mp.StringValue("offset"), mp.IntValue(0)),
      #(mp.StringValue("session"), mp.StringValue("forged")),
    ]),
    mp.MapValue([
      #(mp.StringValue("reference"), mp.BinaryValue(<<>>)),
      #(mp.StringValue("offset"), mp.IntValue(0)),
    ]),
    mp.MapValue([
      #(mp.StringValue("reference"), text),
      #(mp.StringValue("offset"), mp.StringValue("0")),
    ]),
    mp.MapValue([
      #(mp.StringValue("reference"), mp.StringValue("file:///owner.db")),
      #(mp.StringValue("offset"), mp.IntValue(0)),
    ]),
    mp.MapValue([
      #(mp.StringValue("reference"), mp.StringValue(string.repeat("x", 161))),
      #(mp.StringValue("offset"), mp.IntValue(0)),
    ]),
  ]
  list.each(invalid, fn(value) {
    let assert Error(_) = route(request(router.capability, value))
      as "Known malformed requests never reach custody or fallback."
  })

  list.each(
    [-1, 1, 65_535, rv.ref_byte_length(f.reference), 18_446_744_073_709_551_615],
    fn(offset) {
      let assert Error(_) =
        route(request(router.capability, input(f.reference, offset)))
        as "Only aligned in-range offsets are admitted."
    },
  )
  assert process.receive(seen, 0) == Error(Nil)
  stop(f)
}

pub fn unknown_capability_preserves_complete_original_request_test() {
  let f = fixture()
  let seen = process.new_subject()
  let original = request("workspace.read", mp.StringValue("unchanged"))
  let route =
    router.routing(f.owner, session(77), over: fn(request) {
      process.send(seen, request)
      denied(request)
    })
  assert route(original) == denied(original)
  assert process.receive(seen, 0) == Ok(original)
  stop(f)
}

pub fn closed_owner_read_has_fixed_bounded_diagnostic_test() {
  let f = fixture()
  let route = router.routing(f.owner, session(77), over: denied)
  stop(f)
  assert served(route, input(f.reference, 0))
    == framing.CapErr(
      "unavailable",
      "Original owner report read is unavailable.",
    )
}

pub fn actual_reply_encoded_envelope_covers_every_u64_width_test() {
  let f = fixture()
  let route = router.routing(f.owner, session(77), over: denied)
  let outcome = served(route, input(f.reference, 0))
  list.each(
    [
      0,
      127,
      128,
      255,
      256,
      65_535,
      65_536,
      4_294_967_295,
      4_294_967_296,
      9_223_372_036_854_775_807,
      9_223_372_036_854_775_808,
      18_446_744_073_709_551_615,
    ],
    fn(id) {
      let assert Ok(bytes) =
        framing.encode(framing.Frame(id, framing.CapResult(outcome, None)))
        as "Every admitted u64 width has the actual complete response envelope."
      assert bit_array.byte_size(bytes) <= router.encoded_bytes
      let assert <<length:size(32), payload:bits>> = bytes
        as "The check includes the four-byte wire length prefix."
      assert length == bit_array.byte_size(payload)
    },
  )

  let assert Error(_) =
    framing.encode(framing.Frame(
      18_446_744_073_709_551_616,
      framing.CapResult(outcome, None),
    ))
    as "The integer encoder refuses the first value above u64."
  let assert Error(_) =
    framing.encode(framing.Frame(-1, framing.CapResult(outcome, None)))
    as "Framing refuses negative IDs."
  stop(f)
}

pub fn maximal_closed_reply_fields_fit_the_512_byte_allowance_test() {
  let value =
    mp.MapValue([
      #(mp.StringValue("reference"), mp.StringValue(string.repeat("r", 160))),
      #(mp.StringValue("offset"), mp.IntValue(18_446_744_073_709_551_615)),
      #(
        mp.StringValue("bytes"),
        mp.BinaryValue(bit_array.from_string(string.repeat("x", 65_536))),
      ),
    ])
  let assert Ok(bytes) =
    framing.encode(framing.Frame(
      18_446_744_073_709_551_615,
      framing.CapResult(framing.CapOk(value), None),
    ))
    as "Even maximal field widths include the prefix, envelope and complete response body."
  assert bit_array.byte_size(bytes) <= router.encoded_bytes
}

pub fn global_ceiling_and_exact_aggregate_bound_test() {
  assert router.ceilings()
    == [satellite.CapCeiling("report.result_chunk", 261, "admission_ceiling")]
  assert router.encoded_bytes == router.chunk_bytes + 512
  assert router.aggregate_bytes == router.encoded_bytes * 261
  assert router.aggregate_bytes == 17_238_528
  assert router.reference_bytes == 160
}

fn read(
  route: satellite.CapRouter,
  reference: rv.ReportRef,
  offset: Int,
) -> BitArray {
  let assert framing.CapOk(mp.MapValue([
    #(mp.StringValue("reference"), mp.StringValue(text)),
    #(mp.StringValue("offset"), mp.IntValue(actual_offset)),
    #(mp.StringValue("bytes"), mp.BinaryValue(bytes)),
  ])) = served(route, input(reference, offset))
    as "The actual successful reply contains exactly the closed three fields."
  assert text == rv.ref_to_string(reference)
  assert actual_offset == offset
  bytes
}

fn served(
  route: satellite.CapRouter,
  args: mp.MsgPackValue,
) -> framing.CapOutcome {
  let assert Ok(satellite.ScopedService(serve)) =
    route(request(router.capability, args))
    as "Reads retain the satellite's original managed lifetime and deadline seam."
  serve()
}

fn input(reference: rv.ReportRef, offset: Int) -> mp.MsgPackValue {
  mp.MapValue([
    #(mp.StringValue("reference"), mp.StringValue(rv.ref_to_string(reference))),
    #(mp.StringValue("offset"), mp.IntValue(offset)),
  ])
}

fn request(cap: String, args: mp.MsgPackValue) -> satellite.CapRequest {
  satellite.CapRequest(
    cap,
    args,
    identity.run_phase(identity.for_execution(
      ids.mint_op(ids.generator(clock.fixed(9000), 9)).0,
      "historical-reader",
      budget.Budget(4, 9_000_000),
    )),
    policy.workspace_default("/work"),
    exec.BestEffort,
    [],
    "/work",
    7,
  )
}

fn denied(
  _: satellite.CapRequest,
) -> Result(satellite.CapPlan, satellite.CapDenial) {
  Error(satellite.CapDenial("fallback", "Original fallback."))
}

fn session(seed: Int) -> ids.SessionId {
  ids.mint_session(ids.generator(clock.fixed(1000), seed)).0
}

fn fixture() -> Fixture {
  let receipt = process.new_subject()
  let assert Ok(metadata) =
    rv.metadata(
      "sha256-" <> string.repeat("b", 64),
      rv.Enforcement(
        rv.Unreported("not observed"),
        rv.Unreported("not observed"),
      ),
      rv.CallLog(0, 0, 0, 0, 0, 0, []),
    )
    as "Closed owner metadata validates."
  let assert Ok(report) =
    rv.from_outcome(
      rv.Completed(mp.StringValue(string.repeat("x", 70_000))),
      metadata,
    )
    as "Canonical actual report spans two fixed slices."

  // The fixture owns one durable database and one concrete custodian.
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    "build/report-router-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(path) == Ok(Nil)
  let assert Ok(limits) = custody.limits(8, 32, 32_000_000, 262_144)
    as "Actual report reservation is bounded."
  let assert Ok(config) =
    custodian.config_with_reports(
      path <> "/owner.db",
      session(77),
      limits,
      1,
      5000,
      fn(owner, key, _) {
        let assert Ok(reference) = custodian.retain_report(owner, key, report)
          as "Original complete report commits before its final reference."
        process.send(receipt, reference)
        effects.ToolCompleted(
          message.ToolResultMessage(
            "call",
            "code_mode",
            [message.ToolResultText("preview", None)],
            Some(
              json.Object([
                #("kind", json.String("code_mode_report_v1")),
                #("reference", json.String(rv.ref_to_string(reference))),
              ]),
            ),
            None,
            None,
            False,
            1000,
          ),
          False,
        )
      },
      bootstrap.sha256,
    )
    as "Actual host SHA-256 is injected by trusted assembly."
  let assert Ok(names) = registry.start() as "One original address registry."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config)
    as "Actual owner publishes validated history."

  // Only the trusted original runner commits the report and matching final.
  let run =
    effects.ToolRun(
      ids.mint_op(ids.generator(clock.fixed(1000), 77)).0,
      "reports",
      0,
      ids.mint_entry(ids.generator(clock.fixed(1001), 10)).0,
      "main",
      message.ToolCall("call", "code_mode", json.Object([]), None, None),
      json.Object([]),
      operation.ReplayNever,
      [],
    )
  let assert Ok(input) =
    tool_custody.invocation(session(77), <<"scope":utf8>>, run)
    as "Original immutable request constructor."
  let assert Ok(_) =
    custodian.execute_with_profile(
      owner,
      input.key,
      input.arguments,
      input.request,
      run,
      custody.CodeModeReportV1,
    )
    as "Actual final association commits before historical reads."
  let assert Ok(reference) = process.receive(receipt, 1000)
    as "Original committed reference."
  Fixture(owner, started.pid, reference, report)
}

fn stop(f: Fixture) -> Nil {
  let monitor = process.monitor(f.pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "Original owner is joined; this is no native retirement proof."
  Nil
}
