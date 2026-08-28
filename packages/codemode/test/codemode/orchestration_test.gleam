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
import codemode/artifact
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

// The step every request in this suite runs under, in the shape the
// planner mints one: a canonical thirty-six character UUIDv7, not a short
// literal. A twelve-character literal survives every slug cap in the tree
// intact, so a suite built on one cannot observe a truncation at all —
// and a truncation is what erased this seam's previous discriminator.
fn step() -> String {
  let #(entry, _generator) =
    ids.mint_entry(ids.generator(clock.fixed(at: t), seed: 23))
  ids.entry_id_to_string(entry)
}

fn op_id() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: t), seed: 23)
  let #(op, _generator) = ids.mint_op(generator)
  op
}

fn phase() -> PhaseIdentity {
  identity.run_phase(identity.for_execution(
    op_id: op_id(),
    step_id: step(),
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
  seam_at(agency, 0)
}

// The same seam for a `code_mode` call sitting at `source_index` in its
// own batch. Every call in a batch shares an operation and a step, so
// this is the only durable coordinate that tells two executions in one
// step apart — which is why the router carries it and why a test can vary
// it.
fn seam_at(
  agency: agent.Agency,
  source_index: Int,
) -> orchestration.Orchestration {
  orchestration.Orchestration(
    agency:,
    strand: "main",
    source_index:,
    // `report.emit` is `codemode/artifact`'s and is proved there and in
    // `workspace_test`; what this suite is about is `strand.*` carriage,
    // so the closure here answers a fixed address and the ceiling is the
    // shipped one.
    emit: fn(_artifact) { Ok(emitted_id) },
    emit_ceiling: artifact.default_emit_ceiling,
  )
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

// The same spawn as `spawn_args`, already decoded — for the tests that
// are about the name a caller derives rather than about carriage.
fn a_spawn_request(purpose: String) -> agent.SpawnRequest {
  agent.SpawnRequest(
    purpose:,
    brief: "do the thing",
    tools: option.None,
    within_ms: option.None,
    result_schema: option.None,
    context: agent.Fresh,
    detach: False,
  )
}

// A caller in the shape one arrives in, for a chosen minter and index.
fn a_caller(source_index: Int, minter: agent.Minter) -> agent.Caller {
  agent.Caller(
    strand: "main",
    operation: op_id(),
    step_id: step(),
    source_index:,
    minter:,
  )
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
  assert caller.step_id == step()
}

pub fn a_programs_call_site_says_a_program_made_it_test() {
  // What tells a program's spawn from the model's own `agent_spawn` in
  // the same step: the `Minter`, in its own field, where nothing
  // truncates it and nothing model-supplied shares a field with it. The
  // step and the source index are carried through untouched — the step is
  // the threaded identity's and the index is the dispatching `code_mode`
  // call's — so the router invents exactly one thing and it is this.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let _outcome = serviced(agency, "strand.spawn", spawn_args("review core"), 0)
  let assert [fake_agency.SawSpawn(caller:, ..)] = fake_agency.drain(seen)
    as "the spawn must reach the Agency"
  assert caller.minter == agent.Program(ordinal: 0)
  assert caller.step_id == step()
  assert caller.source_index == 0
}

pub fn a_program_and_an_agent_spawn_in_one_step_mint_two_names_test() {
  // Sequence 1. `tool.Exclusive` forbids a *concurrent* start and nothing
  // more, so one batch may hold an `agent_spawn` at source index 0 and a
  // `code_mode` call at index 1, back to back, under one step id. Give
  // them the same purpose and the same step and the only thing left to
  // separate their children is who minted them.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let _outcome = serviced(agency, "strand.spawn", spawn_args("review core"), 0)
  let assert [fake_agency.SawSpawn(caller: program, request:)] =
    fake_agency.drain(seen)
    as "the spawn must reach the Agency"
  // The model's own call, at the same step, the same index, the same
  // purpose, and the same operation — everything but the minter.
  let by_hand = a_caller(0, agent.ToolCall)
  assert by_hand.operation == program.operation
  assert by_hand.step_id == program.step_id
  assert by_hand.source_index == program.source_index
  assert fake_agency.minted(program, request)
    != fake_agency.minted(by_hand, request)
}

pub fn two_programs_in_one_step_mint_two_names_test() {
  // Sequence 2. Two `code_mode` calls in one batch share an operation and
  // a step, and each satellite host starts its own ordinal tally at zero
  // — so neither the step nor the ordinal separates them and a
  // discriminator derived from either would put both programs' first
  // children under one name. The dispatching source index is what is
  // left, which is why the seam carries it.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let assert Ok(satellite.ServedHere(serve: first)) =
    orchestration.router(seam_at(agency, 0))(request(
      "strand.spawn",
      spawn_args("review core"),
      0,
    ))
    as "the first program's spawn must be served here"
  let assert Ok(satellite.ServedHere(serve: second)) =
    orchestration.router(seam_at(agency, 1))(request(
      "strand.spawn",
      spawn_args("review core"),
      0,
    ))
    as "the second program's spawn must be served here"
  let _first = first()
  let _second = second()
  let assert [
    fake_agency.SawSpawn(caller: one, request: one_request),
    fake_agency.SawSpawn(caller: two, request: two_request),
  ] = fake_agency.drain(seen)
    as "both spawns must reach the Agency"
  assert one.step_id == two.step_id
  assert one.minter == two.minter
  assert one_request.purpose == two_request.purpose
  assert fake_agency.minted(one, one_request)
    != fake_agency.minted(two, two_request)
}

pub fn each_spawn_gets_its_own_ordinal_test() {
  // The reason the ordinal exists at all. A child's name is minted from
  // the caller's coordinates and the purpose, and a whole execution is
  // one tool call — so two spawns in one program sharing an ordinal would
  // mint one name twice and the second would reconcile onto the first
  // child, a silent wrong answer.
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let _first = serviced(agency, "strand.spawn", spawn_args("review"), 0)
  let _second = serviced(agency, "strand.spawn", spawn_args("review"), 1)
  let assert [
    fake_agency.SawSpawn(caller: first, request: one),
    fake_agency.SawSpawn(caller: second, request: two),
  ] = fake_agency.drain(seen)
    as "both spawns must reach the Agency"
  assert first.minter == agent.Program(ordinal: 0)
  assert second.minter == agent.Program(ordinal: 1)
  // The dispatching call's index is the *same* for both: it names the
  // execution, not the spawn.
  assert first.source_index == second.source_index
  // Same purpose, same step, and still two distinct children.
  assert one.purpose == two.purpose
  assert fake_agency.minted(first, one) != fake_agency.minted(second, two)
}

pub fn a_chosen_ordinal_reaches_no_agent_spawns_child_test() {
  // Sequence 3. A program picks its own ordinal by spawning throwaways
  // first, so it can land on any index an `agent_spawn` used in this
  // step. The ordinal is in `Minter` and the model's spawns are
  // `ToolCall`, so there is no ordinal to reach with: every index a
  // program can pay its way to derives a name no `agent_spawn` at that
  // index derives.
  let request = a_spawn_request("review core")
  let indices = [0, 1, 2, 3, 7]
  let chosen =
    list.map(indices, fn(ordinal) {
      fake_agency.minted(a_caller(0, agent.Program(ordinal:)), request).strand
    })
  let reachable =
    list.map(indices, fn(index) {
      fake_agency.minted(a_caller(index, agent.ToolCall), request).strand
    })
  assert list.all(chosen, fn(name) { !list.contains(reachable, name) })
  // And padding buys the program nothing against itself either: every
  // ordinal is its own child.
  assert list.length(list.unique(chosen)) == list.length(indices)
}

// --- what crosses, and what comes back ------------------------------------

pub fn a_spawn_answers_with_a_durable_handle_test() {
  let seen = recorder()
  let agency = fake_agency.admitting(seen, fake_agency.always_completed)
  let assert framing.CapOk(value:) =
    serviced(agency, "strand.spawn", spawn_args("review core"), 0)
    as "an admitted spawn must answer"
  assert field(value, "strand")
    == text(
      fake_agency.minted(
        a_caller(0, agent.Program(ordinal: 0)),
        a_spawn_request("review core"),
      ).strand,
    )
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
  assert served == [True, True, True, True, True, True, True]
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
    "report.emit" ->
      map([
        #("name", text("note.txt")),
        #("content_type", text("text/plain")),
        #("bytes", msgpack.BinaryValue(<<"hello":utf8>>)),
      ])
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

// --- the whole ceiling table -----------------------------------------------
//
// The spawn tests above run at a shrunk bound because what they prove is
// the mechanism: refused *at* the ceiling, never reaching the plane, and
// under the shipped `spawn_ceiling` name. What follows runs at the
// production numbers instead, because what it proves is the *table* —
// that each capped capability refuses at its own bound and says which.

// One row of `orchestration.ceilings`, as this suite asserts it.
type Capped {
  Capped(cap: String, bound: Int, code: String)
}

fn capped() -> List(Capped) {
  [
    Capped(
      cap: orchestration.spawn_cap,
      bound: orchestration.default_spawn_ceiling,
      code: "spawn_ceiling",
    ),
    Capped(
      cap: orchestration.send_cap,
      bound: orchestration.send_ceiling,
      code: "admission_ceiling",
    ),
    Capped(
      cap: orchestration.note_cap,
      bound: orchestration.note_ceiling,
      code: "admission_ceiling",
    ),
    Capped(
      cap: orchestration.notes_cap,
      bound: orchestration.notes_ceiling,
      code: "admission_ceiling",
    ),
    // `cap/report` is the one module both seams carry, so `report.emit`
    // is the one ceiling both seams declare — the same number and the
    // same code, from `codemode/artifact` rather than from either seam.
    Capped(
      cap: orchestration.emit_cap,
      bound: artifact.default_emit_ceiling,
      code: "admission_ceiling",
    ),
  ]
}

const emitted_id = "sha256-0000000000000000000000000000000000000000000000000000000000000000"

fn production_ceilings() -> List(satellite.CapCeiling) {
  orchestration.ceilings(
    orchestration.default_spawn_ceiling,
    emit_admissions: artifact.default_emit_ceiling,
  )
}

/// Each capped capability admits exactly its own number and then refuses,
/// under its own code, in a message that names the capability, the number
/// and the lifetime.
///
/// One test over the table rather than four hand-written ones: the defect
/// #88 records is that an argument covering six calls had been spent on
/// one, so what needs pinning is the *correspondence* between the table
/// and what the host does with it, row by row.
pub fn every_capped_capability_refuses_at_its_own_bound_test() {
  list.each(capped(), fn(row) {
    let seen = recorder()
    let agency = fake_agency.admitting(seen, fake_agency.always_completed)
    let assert Ok(reported) =
      run_peer_with(
        fresh_dir("bound-" <> row.cap),
        agency,
        production_ceilings(),
        looping_peer(row.cap, row.bound + 1),
      )
      as "the ceiling peer must report"
    // Admitted exactly `bound` times, then refused — at the ceiling, not
    // before it and not one call late.
    assert list.length(reported) == row.bound + 1
    assert list.take(reported, row.bound) == list.repeat("ok", row.bound)
    let assert [refusal] = list.drop(reported, row.bound)
      as "one refusal, at the bound"
    assert string.starts_with(refusal, row.code <> "\n")
    // A program told only "refused" retries forever, and one told "too
    // many at once" waits first and then retries forever. It is told the
    // capability, the number, and that the bound is for the execution's
    // whole life.
    assert string.contains(refusal, row.cap)
    assert string.contains(refusal, int.to_string(row.bound))
    assert string.contains(refusal, "lifetime")
    // And the Agency saw exactly the admitted ones: a refused call never
    // reached the messaging plane at all.
    //
    // `report.emit` is the row where "the plane" is a different plane:
    // it is serviced by `codemode/artifact`'s injected closure, not by
    // the Agency, so the Agency must see *none* of its admissions. That
    // asymmetry is the point of the row being in this table at all — it
    // proves the shared capability is ceilinged by the same host
    // mechanism while reaching somewhere else entirely.
    let reached_agency = list.length(fake_agency.drain(seen))
    let owed = case row.cap == orchestration.emit_cap {
      True -> 0
      False -> row.bound
    }
    assert reached_agency == owed
  })
}

/// `strand.wait` and `strand.roster` carry no ceiling, and the absence is
/// a decision rather than an oversight.
///
/// A wait's whole cost is time, which the Agency's own clamp and the
/// execution's wall deadline already bind; a roster reads a lineage whose
/// size is `session_strands`, a structural constant, so a loop over it
/// re-reads the same bounded thing. Driven past the *largest* ceiling in
/// the table, so a ceiling accidentally added to either would be caught
/// here rather than only in the row list above.
pub fn the_uncapped_calls_are_uncapped_test() {
  let attempts = orchestration.note_ceiling + 1
  list.each([orchestration.wait_cap, orchestration.roster_cap], fn(cap) {
    let seen = recorder()
    let agency = fake_agency.admitting(seen, fake_agency.always_completed)
    let assert Ok(reported) =
      run_peer_with(
        fresh_dir("uncapped-" <> cap),
        agency,
        production_ceilings(),
        looping_peer(cap, attempts),
      )
      as "the uncapped peer must report"
    assert reported == list.repeat("ok", attempts)
    assert list.length(fake_agency.drain(seen)) == attempts
  })
}

/// The table is exactly the calls that mint something outliving the
/// execution, in the numbers their own docs argue: four of the six
/// `strand.*` calls, plus the `report.emit` this seam shares with the
/// workspace one.
///
/// Pinned as a whole because the numbers are load-bearing together:
/// `note` and `notes` bound a quadratic between them, and relaxing either
/// alone puts the superlinear term back.
pub fn the_ceiling_table_is_the_calls_that_mint_test() {
  let rows =
    list.map(production_ceilings(), fn(entry) {
      Capped(cap: entry.cap, bound: entry.admissions, code: entry.code)
    })
  assert rows == capped()
  assert orchestration.note_ceiling == 256
  assert orchestration.notes_ceiling == 64
  // The two seams' ceiling codes are the same word, and they must stay
  // that way: `cap/report`'s `map_error` carries any code verbatim, so a
  // program at the emit ceiling on one seam and at the note ceiling on
  // the other reads one refusal vocabulary. The constants are restated
  // rather than shared, so this is the thing that holds them equal.
  assert artifact.emit_ceiling_code == orchestration.admission_ceiling_code
}

// A peer that calls one capability `attempts` times, reporting `"ok"` for
// each admission and `"{code}\n{message}"` for each refusal, in order.
fn looping_peer(cap: String, attempts: Int) -> fn(PeerCtx) -> Nil {
  fn(ctx: PeerCtx) {
    let reported =
      list.map(
        int.range(from: attempts - 1, to: -1, with: [], run: list.prepend),
        fn(id) {
          satellite_peer.send_cap_call(
            ctx,
            ctx.token,
            id,
            cap,
            looped_args(cap, id),
          )
          case answer(ctx, id) {
            Ok(framing.CapOk(..)) -> "ok"
            Ok(framing.CapErr(code:, message:)) -> code <> "\n" <> message
            Error(Nil) -> "no answer"
          }
        },
      )
    satellite_peer.send_outcome(
      ctx,
      msgpack.ArrayValue(list.map(reported, msgpack.StringValue)),
    )
  }
}

// Well-formed arguments for the `n`th call of `cap`. The varying part is
// deliberate where a repeat would be unrealistic: two spawns with one
// purpose derive one name, and two notes under one key are one register.
fn looped_args(cap: String, n: Int) -> MsgPackValue {
  let nth = int.to_string(n)
  case cap {
    "strand.spawn" -> spawn_args("review " <> nth)
    "strand.note" -> map([#("key", text("k" <> nth)), #("value", text("v"))])
    "strand.send" -> map([#("to", text("main")), #("text", text("hi " <> nth))])
    // The rest take no argument that a repeat would spoil, so they reuse
    // the plan-shape suite's own well-formed arguments.
    _other -> arguments(cap)
  }
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

// Runs one peer against a real satellite host under the small spawn
// ceiling this suite's first two tests use.
fn run_peer(
  dir: String,
  agency: agent.Agency,
  script: fn(PeerCtx) -> Nil,
) -> Result(List(String), String) {
  run_peer_with(
    dir,
    agency,
    orchestration.ceilings(
      ceiling,
      emit_admissions: artifact.default_emit_ceiling,
    ),
    script,
  )
}

// Runs one peer against a real satellite host under the orchestration
// router and the given ceilings, and reads the string list it reported.
fn run_peer_with(
  dir: String,
  agency: agent.Agency,
  ceilings: List(satellite.CapCeiling),
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
        ceilings:,
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
