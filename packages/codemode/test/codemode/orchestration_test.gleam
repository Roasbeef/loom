//// The orchestration router: what a `strand.*` frame becomes, what the
//// Agency is asked, what comes back, and what the seam refuses.
////
//// These drive `orchestration.router` directly, against a scripted
//// Agency, because everything worth proving here is *carriage* — the
//// arguments a call arrives with, the caller it is judged as, the shape
//// of the answer, and the name a refusal keeps. The authorization model
//// itself is `client/agency`'s and is tested against a live runtime on
//// that side, including through this very router
//// (`client/test/client/codemode_test.gleam`).
////
//// The spawn-admission ceiling is at the bottom, driven through the real
//// satellite host and a real in-process peer, because the ceiling is the
//// host's and a test of the router alone could not see it.

import broker/broker
import broker/budget
import broker/exec
import broker/framing
import broker/policy
import broker/token
import codemode/compile
import codemode/identity.{type PhaseIdentity}
import codemode/orchestration
import codemode/satellite
import core/clock
import core/ids
import core/json
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option
import gleam/string
import simplifile
import support/fake_agency.{type Seen}
import support/fake_helper
import support/satellite_peer.{type PeerCtx}
import tools/agent

const t = 1_700_000_000_000

const step = "turn-4:tools"

fn op_id() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: t), seed: 23)
  let #(op, _generator) = ids.mint_op(generator)
  op
}

fn phase() -> PhaseIdentity {
  identity.run_phase(identity.for_execution(
    op_id: op_id(),
    step_id: step,
    budget: budget.Budget(max_outstanding: 8, deadline_ms: t + 60_000),
  ))
}

fn request(
  cap: String,
  args: MsgPackValue,
  ordinal: Int,
) -> satellite.CapRequest {
  satellite.CapRequest(
    cap:,
    args:,
    identity: phase(),
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
    cwd: "/work",
    ordinal:,
  )
}

fn seam(agency: agent.Agency) -> orchestration.Orchestration {
  orchestration.Orchestration(agency:, strand: "main")
}

// Routes one call and runs the plan it produced, which is what the host's
// worker process does.
fn serviced(
  agency: agent.Agency,
  cap: String,
  args: MsgPackValue,
  ordinal: Int,
) -> framing.CapOutcome {
  let assert Ok(satellite.ServedHere(serve:)) =
    orchestration.router(seam(agency))(request(cap, args, ordinal))
    as "an orchestration call must be served in the harness, never cleared"
  serve()
}

// The `{code, message}` a program reads, from whichever of the two
// refusal points produced it: the router refusing a call outright, or the
// served plan carrying back an Agency refusal. The host renders both into
// the same `cap_result`, so a program cannot tell them apart and neither
// does this helper.
fn refused_by(
  agency: agent.Agency,
  cap: String,
  args: MsgPackValue,
) -> #(String, String) {
  case orchestration.router(seam(agency))(request(cap, args, 0)) {
    Error(denial) -> #(denial.code, denial.message)
    Ok(satellite.ServedHere(serve:)) -> {
      let assert framing.CapErr(code:, message:) = serve()
        as "this call must be refused"
      #(code, message)
    }
    Ok(satellite.ClearedCall(..)) ->
      panic as "an orchestration call must never be a jailed clearance"
  }
}

fn map(entries: List(#(String, MsgPackValue))) -> MsgPackValue {
  msgpack.MapValue(
    list.map(entries, fn(entry) { #(msgpack.StringValue(entry.0), entry.1) }),
  )
}

fn text(value: String) -> MsgPackValue {
  msgpack.StringValue(value)
}

fn spawn_args(purpose: String) -> MsgPackValue {
  map([
    #("purpose", text(purpose)),
    #("brief", text("do the thing")),
    #("within_ms", msgpack.NilValue),
    #("detach", msgpack.BoolValue(False)),
    #("context", text("fresh")),
    #("tools", msgpack.NilValue),
    #("result_schema", msgpack.NilValue),
  ])
}

fn recorder() -> Subject(Seen) {
  process.new_subject()
}

fn field(value: MsgPackValue, key: String) -> MsgPackValue {
  let assert msgpack.MapValue(entries:) = value as "expected a map"
  let assert Ok(found) =
    list.find_map(entries, fn(entry) {
      case entry.0 == msgpack.StringValue(key) {
        True -> Ok(entry.1)
        False -> Error(Nil)
      }
    })
    as { "expected a field " <> key }
  found
}

// --- the caller a call is judged as ---------------------------------------

pub fn a_call_is_judged_as_the_dispatching_strand_test() {
  // The strand comes from the host's own request, never from the
  // program: it is the identity the whole addressing rule is stated
  // against.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let _outcome = serviced(agency, "strand.spawn", spawn_args("review core"), 0)
  let assert [fake_agency.SawSpawn(caller:, request: spawned)] =
    fake_agency.drain(seen)
    as "the spawn must reach the Agency"
  assert caller.strand == "main"
  assert spawned.purpose == "review core"
}

pub fn the_operation_is_the_threaded_one_test() {
  // Not a coordinate this router invents: the operation and the step both
  // come off the `PhaseIdentity` the host derived from the execution's one
  // `ExecIdentity`.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let _outcome = serviced(agency, "strand.spawn", spawn_args("review core"), 0)
  let assert [fake_agency.SawSpawn(caller:, ..)] = fake_agency.drain(seen)
    as "the spawn must reach the Agency"
  assert caller.operation == op_id()
  assert string.starts_with(caller.step_id, step)
}

pub fn a_programs_call_site_is_its_own_test() {
  // The derived suffix is what keeps a program's children from colliding
  // with the children of an `agent_spawn` in the same step, which would
  // otherwise share the step *and* the index and so mint one name twice.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let _outcome = serviced(agency, "strand.spawn", spawn_args("review core"), 0)
  let assert [fake_agency.SawSpawn(caller:, ..)] = fake_agency.drain(seen)
    as "the spawn must reach the Agency"
  assert caller.step_id == step <> orchestration.program_step_suffix
  assert caller.step_id != step
}

pub fn each_spawn_gets_its_own_source_index_test() {
  // The reason the ordinal exists at all. A child's name is minted from
  // the caller's coordinates and the purpose, so two spawns in one
  // program sharing an index would mint one name twice and the second
  // would reconcile onto the first child — a silent wrong answer.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let _first = serviced(agency, "strand.spawn", spawn_args("review"), 0)
  let _second = serviced(agency, "strand.spawn", spawn_args("review"), 1)
  let assert [
    fake_agency.SawSpawn(caller: first, request: one),
    fake_agency.SawSpawn(caller: second, request: two),
  ] = fake_agency.drain(seen)
    as "both spawns must reach the Agency"
  assert first.source_index == 0
  assert second.source_index == 1
  // Same purpose, same step, and still two distinct children.
  assert one.purpose == two.purpose
  assert fake_agency.minted(first, one) != fake_agency.minted(second, two)
}

// --- what crosses, and what comes back ------------------------------------

pub fn a_spawn_answers_with_a_durable_handle_test() {
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let assert framing.CapOk(value:) =
    serviced(agency, "strand.spawn", spawn_args("review core"), 0)
    as "an admitted spawn must answer"
  assert field(value, "strand")
    == text("sub:main/review-core-turn-4-tools-program-0")
  assert field(value, "operation")
    == text(ids.op_id_to_string(fake_agency.op_id(0)))
}

pub fn a_join_carries_one_answer_per_handle_in_order_test() {
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let handles =
    msgpack.ArrayValue([
      map([#("strand", text("sub:main/a")), #("operation", text(op_text(1)))]),
      map([#("strand", text("sub:main/b")), #("operation", text(op_text(2)))]),
    ])
  let assert framing.CapOk(value:) =
    serviced(
      agency,
      "strand.wait",
      map([#("handles", handles), #("within_ms", msgpack.IntValue(9000))]),
      0,
    )
    as "a join must answer"
  let assert msgpack.ArrayValue(items: answers) = field(value, "waited")
    as "the join must answer with a list"
  assert list.length(answers) == 2
  let assert [first, second] = answers as "two answers"
  assert field(first, "strand") == text("sub:main/a")
  assert field(second, "strand") == text("sub:main/b")
  assert field(first, "kind") == text("ready")
  assert field(field(first, "outcome"), "kind") == text("completed")
  // The join's deadline is the program's, forwarded rather than replaced.
  let assert [fake_agency.SawWait(within_ms:, ..)] = fake_agency.drain(seen)
    as "the join must reach the Agency"
  assert within_ms == 9000
}

pub fn a_structured_result_crosses_as_structure_test() {
  // The whole point of the result contract on this seam: a program
  // branches on typed fields, so a `ResultGiven` must arrive as a value
  // and not as prose about a value.
  let seen = recorder()
  let given =
    agent.ResultGiven(
      value: json.Object([
        #("package", json.String("packages/core")),
        #("hits", json.Int(2)),
      ]),
    )
  let agency =
    fake_agency.admitting(seen, fn(handle) {
      fake_agency.completed_with(handle, given)
    })
  let assert framing.CapOk(value:) =
    serviced(
      agency,
      "strand.wait",
      map([
        #(
          "handles",
          msgpack.ArrayValue([
            map([
              #("strand", text("sub:main/a")),
              #("operation", text(op_text(1))),
            ]),
          ]),
        ),
        #("within_ms", msgpack.IntValue(1000)),
      ]),
      0,
    )
    as "a join must answer"
  let assert msgpack.ArrayValue(items: [answer]) = field(value, "waited")
    as "one answer"
  let result = field(answer, "result")
  assert field(result, "kind") == text("given")
  assert field(field(result, "value"), "hits") == msgpack.IntValue(2)
  assert field(field(result, "value"), "package") == text("packages/core")
}

pub fn a_declared_result_shape_becomes_a_real_schema_test() {
  // The program sends field descriptors and the *harness* builds the
  // schema, so a program cannot state a constraint that would be quoted
  // into a child's brief without anything checking it.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let schema =
    msgpack.ArrayValue([
      map([
        #("name", text("hits")),
        #("type", text("integer")),
        #("items", msgpack.NilValue),
        #("required", msgpack.BoolValue(True)),
      ]),
      map([
        #("name", text("files")),
        #("type", text("array")),
        #(
          "items",
          map([#("type", text("string")), #("items", msgpack.NilValue)]),
        ),
        #("required", msgpack.BoolValue(False)),
      ]),
    ])
  let args =
    map([
      #("purpose", text("review core")),
      #("brief", text("do the thing")),
      #("within_ms", msgpack.IntValue(1000)),
      #("detach", msgpack.BoolValue(True)),
      #("context", text("my_conversation")),
      #("tools", msgpack.ArrayValue([text("fs_read")])),
      #("result_schema", schema),
    ])
  let _outcome = serviced(agency, "strand.spawn", args, 0)
  let assert [fake_agency.SawSpawn(request: spawned, ..)] =
    fake_agency.drain(seen)
    as "the spawn must reach the Agency"
  let assert option.Some(parsed) = spawned.result_schema
    as "the declared shape must reach the Agency as a schema"
  assert list.map(agent.result_fields(parsed), fn(one) { one.name })
    == ["hits", "files"]
  assert list.map(agent.result_fields(parsed), fn(one) { one.expects })
    == [agent.IntegerField, agent.ArrayField(items: agent.StringField)]
  assert list.map(agent.result_fields(parsed), fn(one) { one.required })
    == [True, False]
  // The rest of the request crossed too, rather than being defaulted.
  assert spawned.within_ms == option.Some(1000)
  assert spawned.detach
  assert spawned.context == agent.MyConversation
  assert spawned.tools == option.Some(["fs_read"])
}

pub fn a_note_crosses_as_json_test() {
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let assert framing.CapOk(..) =
    serviced(
      agency,
      "strand.note",
      map([
        #("key", text("found")),
        #(
          "value",
          map([#("n", msgpack.IntValue(3)), #("ok", msgpack.BoolValue(True))]),
        ),
      ]),
      0,
    )
    as "a note must be accepted"
  let assert [fake_agency.SawNote(key:, value:, ..)] = fake_agency.drain(seen)
    as "the note must reach the Agency"
  assert key == "found"
  assert value == json.Object([#("n", json.Int(3)), #("ok", json.Bool(True))])
}

pub fn a_roster_and_a_notes_read_answer_test() {
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let assert framing.CapOk(value: peers) =
    serviced(agency, "strand.roster", map([]), 0)
    as "a roster read must answer"
  let assert msgpack.ArrayValue(items: [peer]) = field(peers, "peers")
    as "one peer"
  assert field(peer, "strand") == text("main")
  assert field(peer, "relation") == text("parent")
  assert field(peer, "handle") == msgpack.NilValue
  let assert framing.CapOk(value: notes) =
    serviced(agency, "strand.notes", map([#("prefix", msgpack.NilValue)]), 0)
    as "a notes read must answer"
  let assert msgpack.ArrayValue(items: [note]) = field(notes, "notes")
    as "one note"
  assert field(note, "key") == text("agent/main/note")
  assert field(note, "value") == text("kept")
  let assert [_roster, fake_agency.SawNotes(prefix:, ..)] =
    fake_agency.drain(seen)
    as "both reads must reach the Agency"
  assert prefix == option.None
}

// --- refusals keep their names --------------------------------------------

pub fn every_agency_refusal_keeps_its_name_test() {
  // The exit criterion: a call outside the program's own lineage is
  // refused under the name the tools already refuse under. The mapping is
  // exhaustive over `agent.Refusal`, and it is half of a contract whose
  // other half is `cap/strand.map_error`.
  let cases = [
    #(agent.AgencyUnavailable, "strands_unavailable"),
    #(agent.MalformedHandle(text: "x"), "malformed_handle"),
    #(agent.NotAddressable(strand: "sub:other/one"), "not_addressable"),
    #(agent.NotADescendant(strand: "sub:other/one"), "not_a_descendant"),
    #(agent.DepthCapReached(depth: 1), "depth_cap"),
    #(agent.FanOutCapReached(live: 8, cap: 8), "fan_out_cap"),
    #(agent.UnknownTool(name: "bash"), "unknown_tool"),
    #(agent.InvalidArgument(reason: "no"), "invalid_argument"),
    #(agent.ParentRunEnded(strand: "main"), "parent_run_ended"),
    #(agent.PlaneFailed(reason: "down"), "plane_failed"),
  ]
  assert list.all(cases, fn(one) { orchestration.refusal_code(one.0) == one.1 })
}

pub fn a_refusal_travels_with_the_harnesss_own_words_test() {
  let refusal = agent.NotADescendant(strand: "sub:other/one")
  let #(code, message) =
    refused_by(
      fake_agency.refusing(refusal),
      "strand.wait",
      map([
        #("handles", msgpack.ArrayValue([])),
        #("within_ms", msgpack.IntValue(1000)),
      ]),
    )
  assert code == "not_a_descendant"
  // Not a sentence this module wrote: the Agency's own, so a program
  // reads what a model reads.
  assert message == agent.describe(refusal)
  assert string.contains(message, "sub:other/one")
}

pub fn a_send_outside_the_lineage_is_refused_test() {
  let refusal = agent.NotAddressable(strand: "sub:elsewhere/one")
  let #(code, message) =
    refused_by(
      fake_agency.refusing(refusal),
      "strand.send",
      map([
        #("to", text("sub:elsewhere/one")),
        #("text", text("hello")),
      ]),
    )
  assert code == "not_addressable"
  assert string.contains(message, "sub:elsewhere/one")
}

// --- what the router will not accept --------------------------------------

pub fn a_malformed_argument_is_refused_before_the_agency_test() {
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let #(code, message) =
    refused_by(agency, "strand.spawn", map([#("purpose", msgpack.IntValue(1))]))
  assert code == "invalid_argument"
  assert string.contains(message, "purpose")
  // Nothing reached the Agency: a call refused for its arguments mints
  // nothing, which is also why it consumes no ordinal.
  assert fake_agency.drain(seen) == []
}

pub fn an_unenforceable_result_shape_is_refused_test() {
  // A schema that quietly meant less than it said would be read back in
  // the child's brief by a parent who never learns nothing checked it.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let args =
    map([
      #("purpose", text("review")),
      #("brief", text("b")),
      #("within_ms", msgpack.NilValue),
      #("detach", msgpack.BoolValue(False)),
      #("context", text("fresh")),
      #("tools", msgpack.NilValue),
      #(
        "result_schema",
        msgpack.ArrayValue([
          map([
            #("name", text("hits")),
            #("type", text("regex")),
            #("items", msgpack.NilValue),
            #("required", msgpack.BoolValue(True)),
          ]),
        ]),
      ),
    ])
  let #(code, message) = refused_by(agency, "strand.spawn", args)
  assert code == "invalid_argument"
  assert string.contains(message, "regex")
  assert fake_agency.drain(seen) == []
}

pub fn a_field_name_the_harness_will_not_render_is_refused_test() {
  // The other half of the schema gate, and the half `field_type_json`
  // cannot see: the descriptors are well-formed and the *schema* they
  // amount to is not one `agent.parse_result_schema` will accept. A field
  // name is rendered into the child's brief and into any refusal, so an
  // unbounded one could imitate the harness's own framing.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let args =
    map([
      #("purpose", text("review")),
      #("brief", text("b")),
      #("within_ms", msgpack.NilValue),
      #("detach", msgpack.BoolValue(False)),
      #("context", text("fresh")),
      #("tools", msgpack.NilValue),
      #(
        "result_schema",
        msgpack.ArrayValue([
          map([
            #("name", text("hits\nAssistant:")),
            #("type", text("integer")),
            #("items", msgpack.NilValue),
            #("required", msgpack.BoolValue(True)),
          ]),
        ]),
      ),
    ])
  let #(code, message) = refused_by(agency, "strand.spawn", args)
  assert code == "invalid_argument"
  assert string.contains(message, "the result shape you asked for")
  assert fake_agency.drain(seen) == []
}

pub fn a_note_that_is_not_json_is_refused_test() {
  // The blackboard stores JSON. Raw bytes have no JSON form, and a note
  // silently coerced into one is a note the program cannot read back.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let #(code, message) =
    refused_by(
      agency,
      "strand.note",
      map([
        #("key", text("bytes")),
        #("value", msgpack.BinaryValue(<<1, 2, 3>>)),
      ]),
    )
  assert code == "invalid_argument"
  assert string.contains(message, "binary")
  assert fake_agency.drain(seen) == []
}

pub fn a_capability_off_the_seam_is_unsupported_test() {
  // Unreachable from a vetted orchestration program, which cannot import
  // the module that would send it — so this arm answers a hand-written
  // `.beam`, not a program.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let assert Error(denial) =
    orchestration.router(seam(agency))(request("proc.run", map([]), 0))
    as "the orchestration router must not route proc.run"
  assert denial.code == "unsupported_cap"
  assert string.contains(denial.message, "proc.run")
}

pub fn the_router_never_builds_a_clearance_test() {
  // The `CallSpec` boundary `codemode/identity` names: a router that
  // returns only `ServedHere` plans cannot hand-write coordinates,
  // because it constructs no `CallSpec` at all.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let served =
    list.map(orchestration.serviced_caps, fn(cap) {
      case orchestration.router(seam(agency))(request(cap, arguments(cap), 0)) {
        Ok(satellite.ServedHere(..)) -> True
        Ok(satellite.ClearedCall(..)) -> False
        Error(_denial) -> False
      }
    })
  assert served == [True, True, True, True, True, True]
}

// Well-formed arguments for each capability, so the plan-shape check
// above is about the plan and not about a decoding failure.
fn arguments(cap: String) -> MsgPackValue {
  case cap {
    "strand.spawn" -> spawn_args("review")
    "strand.wait" ->
      map([
        #("handles", msgpack.ArrayValue([])),
        #("within_ms", msgpack.IntValue(1000)),
      ])
    "strand.send" -> map([#("to", text("main")), #("text", text("hi"))])
    "strand.note" -> map([#("key", text("k")), #("value", text("v"))])
    "strand.notes" -> map([#("prefix", msgpack.NilValue)])
    _ -> map([])
  }
}

fn op_text(seed: Int) -> String {
  ids.op_id_to_string(fake_agency.op_id(seed))
}

// --- the spawn-admission ceiling ------------------------------------------
//
// Driven through the real host, because the ceiling is the host's: one
// host is stood up per execution and holds the one identity a caller may
// mint, so a tally kept beside it is keyed to that execution by
// construction. A peer loops `strand.spawn` past the ceiling and reports
// what it was told.

const ceiling = 3

pub fn a_loop_past_the_spawn_ceiling_is_refused_at_the_ceiling_test() {
  let dir = fresh_dir("ceiling")
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let assert Ok(codes) = run_peer(dir, agency, spawning_peer)
    as "the ceiling peer must report"
  // Exactly `ceiling` admissions, then a refusal — at the ceiling, not
  // before it and not one call late.
  assert list.length(codes) == ceiling + 1
  assert list.take(codes, ceiling) == list.repeat("ok", ceiling)
  assert list.drop(codes, ceiling) == ["spawn_ceiling"]
  // And the Agency saw exactly the admitted ones: a refused call never
  // reached the messaging plane at all.
  assert list.length(fake_agency.drain(seen)) == ceiling
}

pub fn the_ceiling_refusal_names_the_ceiling_test() {
  let dir = fresh_dir("ceiling-message")
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let assert Ok(messages) = run_peer(dir, agency, refused_message_peer)
    as "the ceiling peer must report"
  let assert [message] = messages as "one refusal message"
  assert string.contains(message, int.to_string(ceiling))
  assert string.contains(message, "strand.spawn")
  // A program told only "refused" would loop; one told "too many at
  // once" would join and retry forever. It is told which.
  assert string.contains(message, "lifetime")
  let _drained = fake_agency.drain(seen)
  Nil
}

// A peer that spawns until it is refused, reporting the code of every
// answer in order.
fn spawning_peer(ctx: PeerCtx) -> Nil {
  let codes =
    list.map(attempts(), fn(id) {
      satellite_peer.send_cap_call(
        ctx,
        ctx.token,
        id,
        "strand.spawn",
        spawn_args("review " <> int.to_string(id)),
      )
      answer_code(ctx, id)
    })
  satellite_peer.send_outcome(
    ctx,
    msgpack.ArrayValue(list.map(codes, msgpack.StringValue)),
  )
}

// The same loop, reporting the *message* of the one refusal instead.
fn refused_message_peer(ctx: PeerCtx) -> Nil {
  let messages =
    list.filter_map(attempts(), fn(id) {
      satellite_peer.send_cap_call(
        ctx,
        ctx.token,
        id,
        "strand.spawn",
        spawn_args("review " <> int.to_string(id)),
      )
      case answer(ctx, id) {
        Ok(framing.CapErr(code: _, message:)) -> Ok(message)
        Ok(framing.CapOk(..)) | Error(Nil) -> Error(Nil)
      }
    })
  satellite_peer.send_outcome(
    ctx,
    msgpack.ArrayValue(list.map(messages, msgpack.StringValue)),
  )
}

// One more attempt than the ceiling admits, so the last one is the
// refusal the tests are about.
fn attempts() -> List(Int) {
  // `int.range` counts towards `to` without reaching it, so counting down
  // from the ceiling and prepending yields `[0, …, ceiling]` — one more
  // attempt than the ceiling admits.
  int.range(from: ceiling, to: -1, with: [], run: list.prepend)
}

fn answer_code(ctx: PeerCtx, id: Int) -> String {
  case answer(ctx, id) {
    Ok(framing.CapOk(..)) -> "ok"
    Ok(framing.CapErr(code:, message: _)) -> code
    Error(Nil) -> "no answer"
  }
}

// The one `cap_result` for call `id`. The peers here send one call and
// wait for its answer before sending the next, so each answer is a whole
// frame of its own and a fresh deframer per wait is enough.
fn answer(ctx: PeerCtx, id: Int) -> Result(framing.CapOutcome, Nil) {
  case satellite_peer.collect_results(ctx, 1, 3000) {
    [#(answered, outcome)] if answered == id -> Ok(outcome)
    _other -> Error(Nil)
  }
}

// Runs one peer against a real satellite host under the orchestration
// router and the ceiling, and reads the string list it reported.
fn run_peer(
  dir: String,
  agency: agent.Agency,
  script: fn(PeerCtx) -> Nil,
) -> Result(List(String), String) {
  let assert Ok(broker_actor) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        checkout: fn() { Ok(fake_helper.start_helper(fake_helper.EchoNow)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker must start"
  let run =
    satellite.run(
      compile.Artifact(
        build_root: dir,
        beam_dir: dir <> "/ebin",
        entry_module: "loom_satellite",
        manifest_hash: "test",
      ),
      phase(),
      broker_actor,
      satellite.SatelliteConfig(
        base_policy: policy.workspace_default("/work"),
        demand: exec.BestEffort,
        env: [#("PATH", "/usr/bin")],
        cwd: "/work",
        cap_socket_path: dir <> "/sock",
        entropy: token.production_entropy(),
        clock: clock.fixed(at: t),
        write_token_file: satellite.private_token_writer(dir),
        unlink_token_file: satellite.unlink_token_file,
        router: orchestration.router(seam(agency)),
        ceilings: orchestration.ceilings(ceiling),
        call_timeout_ms: 3000,
      ),
      satellite_peer.launcher(script),
    )
  broker.stop(broker_actor)
  case run.outcome {
    Error(_error) -> Error("the satellite did not report an outcome")
    Ok(satellite.Errored(message:, details: _)) -> Error(message)
    Ok(satellite.Completed(value: msgpack.ArrayValue(items:))) ->
      Ok(
        list.filter_map(items, fn(item) {
          case item {
            msgpack.StringValue(reported) -> Ok(reported)
            _other -> Error(Nil)
          }
        }),
      )
    Ok(satellite.Completed(value: _other)) ->
      Error("the peer reported something other than a list")
  }
}

fn fresh_dir(name: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  let dir = here <> "/build/cmtest/orchestration-" <> name
  let _cleared = simplifile.delete(dir)
  let assert Ok(Nil) = simplifile.create_directory_all(dir)
    as "the test directory must be creatable"
  dir
}
