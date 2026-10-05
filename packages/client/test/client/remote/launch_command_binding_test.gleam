//// Original owner custody admits SatelliteCommand only beneath retained Launch.
//// These controls use real SQLite/custodian, production enrollment, canonical
//// Compile completion and native receipt codecs, and one real Broker clearance.
//// `fixture` owns the original database actor; `retain_producer` publishes its
//// original Compile input, cleared native bytes, terminal receipt and completion.
//// `launch` links exact artifact and enrollment paths without creating resources.
//// No compiler, socket, satellite or executor host is physically started here.
////
//// ## Flow
////
//// `fixture` → `retain_producer` → `launch` → `retain_launch` → `configured`
//// supplies exact original authority; `rejected_before_prepare` proves absence
//// of a native slot on refusal, and `stop` joins the concrete owner actor.

import broker/broker
import broker/budget
import broker/command as offer
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/policy
import broker/token
import client/remote/command_binding as binding
import client/remote/custodian
import codemode/compile
import codemode/service_command
import codemode/service_input as input
import codemode/service_resources as resources
import core/clock
import core/command
import core/ids
import core/remote_tool
import core/workspace
import executor
import executor/remote/compile_completion as completion
import executor/remote/dispatcher
import executor/remote/identity
import executor/remote/native
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import storage/owner_custody as custody
import weft/poll
import weft/registry

type Fixture {
  Fixture(owner: custodian.Handle, pid: process.Pid)
}

type Producer {
  Producer(
    key: command.ServiceKey,
    original: input.CompileInput,
    result: completion.CompileCompletion,
    proposal: offer.CommandOffer,
    prepared: wire.Prepared,
    native_key: identity.RequestKey,
    terminal: BitArray,
  )
}

type Launch {
  Launch(
    key: command.ServiceKey,
    original: input.LaunchInput,
    proposal: offer.CommandOffer,
  )
}

fn session_id(number: Int) -> ids.SessionId {
  ids.mint_session(ids.generator(clock.fixed(1000), number)).0
}

fn operation(number: Int) -> ids.OpId {
  ids.mint_op(ids.generator(clock.fixed(1000), number)).0
}

fn request_id(number: Int) -> ids.EntryId {
  ids.mint_entry(ids.generator(clock.fixed(1000), number)).0
}

fn scope() -> identity.Scope {
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "Workspace label."
  let assert Ok(executor) = identity.executor_id("linux") as "Executor label."
  let assert Ok(epoch) = identity.epoch(1) as "Original epochs."
  identity.scope(session_id(1), workspace, executor, epoch, epoch)
}

fn parent(index: Int) -> remote_tool.ToolKey {
  let assert Ok(key) =
    remote_tool.key(
      session_id(1),
      operation(2),
      "parent:tools",
      index,
      string.repeat("a", 64),
      request_id(index + 3),
    )
    as "Complete distinct original parent."
  key
}

fn limits() -> custody.Limits {
  let assert Ok(value) = custody.limits(4, 64, 16_777_216, 2_097_152)
    as "Finite custody ceilings."
  value
}

fn base() -> policy.SandboxPolicy {
  let original = executor.base_policy("/executor/work")
  policy.SandboxPolicy(
    ..original,
    writable_roots: ["/executor"],
    readable_roots: ["/"],
    network: policy.NetworkFull,
    limits: policy.Limits(..original.limits, wall_s: 180),
    env_allow: ["PATH", "TMPDIR", "LOOM_CAP_SOCK", "LOOM_CAP_TOKEN_FILE"],
  )
}

fn enrolled() -> enrollment.SessionEnrollment {
  let assert Ok(full_scope) =
    workspace.scope_from_fields(
      ids.session_id_to_string(session_id(1)),
      "checkout",
      "linux",
      1,
      1,
    )
    as "Complete matching scope."
  let assert Ok(value) =
    enrollment.new(
      enrollment.NativeFacts(
        full_scope,
        ["/"],
        base(),
        exec.PlatformEnforcement,
      ),
      enrollment.CodeModeFacts(
        "/executor/work",
        "/executor/alloc/build",
        "/executor/alloc/channel",
        "/tc/bin/gleam",
        "/otp/bin/erl",
        "/seed",
        ["/tc", "/otp"],
        [],
        "/tc/bin",
      ),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Pinned original enrollment."
  value
}

fn original() -> input.CompileInput {
  let assert Ok(value) =
    input.compile_input(
      enrolled(),
      input.WorkspaceProgram,
      "pub fn main() { Nil }\n",
      [],
      compile.default_dependencies(),
      base(),
      180_000,
    )
    as "Canonical original source."
  value
}

fn hash(bytes: BitArray) -> String {
  let assert Ok(value) = wire.digest(bytes) as "Canonical SHA-256 evidence."
  string.lowercase(bit_array.base16_encode(identity.digest_bytes(value)))
}

pub fn original_success_and_exact_duplicate_keep_uuid_prepared_and_receipt_test() {
  let f = fixture()
  let p = producer(0)
  retain_producer(f, p, Some(p.result), input.encode_compile(p.original))
  let held = launch(p, artifact(p.result))
  retain_launch(f, held, held.proposal, input.encode_launch(held.original))
  let actual = prepared(held.proposal)
  let request = dispatched(held.proposal, actual)

  // Only after both durable inputs exist may a cleared command reserve its UUID.
  let original = configured(f, actual, request_id(60))
  let assert Ok(dispatcher.CommandReserved(key, value, ref)) =
    binding.reserve(original, request)
    as "Only original successful Compile and exact Launch template admit native custody."
  assert value == actual
  assert ref == offer.reference(held.proposal)
  assert identity.key_fields(key).1 == ids.entry_id_to_string(request_id(60))

  // A new candidate cannot replace the original UUID or any cleared byte.
  assert binding.reserve(configured(f, actual, request_id(61)), request)
    == Ok(dispatcher.CommandReserved(key, actual, ref))
  let assert Ok(#(id, bytes, None)) = custodian.command_child(f.owner, ref)
    as "Original complete native envelope remains durable."
  assert id == request_id(60)
  assert wire.decode_prepared(custody.bytes(bytes)) == Ok(actual)
  let assert Ok(digest) = wire.prepared_digest(actual)
    as "Actual Prepared digest."
  let outputs = [<<"first":utf8>>, <<"second":utf8>>]
  let origin = command.native_origin(ref)

  assert binding.cancel(original, origin) == Ok(Nil)
  assert binding.reserve(original, request) == Error(custody.Frozen)
  assert binding.receive(original, origin, key, digest, outputs, <<
      "native terminal":utf8,
    >>)
    == Ok(Nil)
  assert binding.receive(original, origin, key, digest, list.reverse(outputs), <<
      "native terminal":utf8,
    >>)
    == Error(custody.Conflict)
  let assert Ok(#(_, _, Some(receipt))) = custodian.command_child(f.owner, ref)
    as "A cancelled Launch retains ordered late native receipt independently."
  assert custodian.receipt(outputs, <<"native terminal":utf8>>)
    == Ok(custody.bytes(receipt))
  stop(f)
}

pub fn missing_failed_foreign_and_noncanonical_compile_completion_refuse_before_prepare_test() {
  let p = producer(0)
  let held = launch(p, artifact(p.result))
  let assert Ok(failed) =
    completion.failed_before_native(
      enrolled(),
      p.key,
      compile.BuildUnavailable("original refusal"),
    )
    as "A genuine failed producer cannot launch its nominal artifact."
  let foreign = producer(1)
  let assert Ok(failed_bytes) = completion.encode(failed)
    as "Canonical failed completion."
  let assert Ok(foreign_bytes) = completion.encode(foreign.result)
    as "Canonical foreign completion."
  let assert Ok(good_bytes) = completion.encode(p.result)
    as "Canonical original completion."
  list.each(
    [
      None,
      Some(failed_bytes),
      Some(foreign_bytes),
      Some(<<good_bytes:bits, 0>>),
    ],
    fn(bytes) {
      let f = fixture()
      retain_producer(f, p, None, input.encode_compile(p.original))
      case bytes {
        None -> Nil
        Some(value) -> {
          assert custodian.receive_child(
              f.owner,
              service_origin(p.key),
              command.request_id(p.key),
              value,
            )
            == Ok(Nil)
        }
      }
      retain_launch(f, held, held.proposal, input.encode_launch(held.original))
      rejected_before_prepare(f, held.proposal)
      stop(f)
    },
  )
}

pub fn stale_artifact_and_changed_producer_input_refuse_before_prepare_test() {
  let p = producer(0)
  let assert compile.ExecutorArtifact(a, b, c, d, e, id, g, h, _) =
    artifact(p.result)
    as "Only an executor-issued artifact can reach Launch input."
  let stale =
    compile.ExecutorArtifact(
      a,
      b,
      c,
      d,
      e,
      id,
      g,
      h,
      "sha256-" <> string.repeat("e", 64),
    )
  let held = launch(p, stale)

  // A valid stale artifact reaches the real owner comparison.
  let f = fixture()
  retain_producer(f, p, Some(p.result), input.encode_compile(p.original))
  retain_launch(f, held, held.proposal, input.encode_launch(held.original))
  rejected_before_prepare(f, held.proposal)
  stop(f)

  // A retained success does not excuse body substitution under its producer key.
  let f = fixture()
  let changed =
    input.CompileFacts(
      ..input.compile_facts(p.original),
      source: "pub fn main() { 1 }\n",
    )
  let assert Ok(changed) =
    input.compile_input(
      changed.enrolled,
      changed.seam,
      changed.source,
      changed.generated,
      changed.dependencies,
      changed.policy_seed,
      changed.build_timeout_ms,
    )
    as "Shape-valid different producer source."
  retain_producer(f, p, Some(p.result), input.encode_compile(changed))
  let held = launch(p, artifact(p.result))
  retain_launch(f, held, held.proposal, input.encode_launch(held.original))
  rejected_before_prepare(f, held.proposal)
  stop(f)
}

pub fn changed_channel_token_paths_and_complete_resource_mappings_refuse_test() {
  let p = producer(0)
  let held = launch(p, artifact(p.result))
  let data = offer.data(held.proposal)
  let changed_env =
    list.map(data.env, fn(pair) {
      case pair.0 {
        "LOOM_CAP_TOKEN_FILE" -> #(
          pair.0,
          "/executor/alloc/channel/foreign/token",
        )
        "LOOM_CAP_SOCK" -> #(pair.0, "/executor/alloc/channel/foreign/socket")
        _ -> pair
      }
    })
  let assert Ok(changed_handles) =
    offer.offer(
      offer.reference(held.proposal),
      offer.mappings(held.proposal),
      offer.CommandData(..data, env: changed_env),
    )
    as "Canonical offer carries wrong channel handles."
  let changed_mappings =
    list.map(offer.mappings(held.proposal), fn(mapping) {
      case mapping {
        offer.RegionMapping(offer.Channel, _) ->
          offer.RegionMapping(offer.Channel, "/executor/alloc/channel/foreign")
        other -> other
      }
    })
  let assert Ok(changed_paths) =
    offer.offer(offer.reference(held.proposal), changed_mappings, data)
    as "Canonical resource mapping substitution."
  list.each([changed_handles, changed_paths], fn(proposal) {
    let f = fixture()
    retain_producer(f, p, Some(p.result), input.encode_compile(p.original))
    retain_launch(f, held, proposal, input.encode_launch(held.original))
    rejected_before_prepare(f, proposal)
    stop(f)
  })
}

pub fn changed_token_commitment_body_context_and_callback_token_refuse_test() {
  let p = producer(0)
  let held = launch(p, artifact(p.result))
  let f = fixture()
  retain_producer(f, p, Some(p.result), input.encode_compile(p.original))
  let facts = input.launch_facts(held.original)
  let assert Ok(changed) =
    input.launch_input(
      enrolled(),
      p.key,
      facts.artifact,
      facts.env,
      facts.cwd,
      facts.policy_seed,
      string.repeat("d", 64),
    )
    as "A different cap-token commitment is valid data but changes original input."

  // A valid different commitment cannot substitute under the original digest.
  retain_launch(f, held, held.proposal, input.encode_launch(changed))
  rejected_before_prepare(f, held.proposal)
  stop(f)

  // Complete native context and the Broker's actual token remain indivisible.
  let f = fixture()
  retain_producer(f, p, Some(p.result), input.encode_compile(p.original))
  retain_launch(f, held, held.proposal, input.encode_launch(held.original))
  let actual = prepared(held.proposal)
  let request = dispatched(held.proposal, actual)
  let foreign_step =
    dispatch.Dispatch(
      ..request,
      context: dispatch.CallContext(..request.context, step: "foreign:run"),
    )
  let foreign_op =
    dispatch.Dispatch(
      ..request,
      context: dispatch.CallContext(..request.context, operation: operation(3)),
    )
  list.each([foreign_step, foreign_op], fn(request) {
    let assert Error(_) = binding.reserve(guarded(f), request)
      as "Wrong original context refuses before callbacks."
  })

  // Callback materialization cannot replace the actual Broker token.
  let changed =
    wire.Prepared(
      ..actual,
      request: exec.ExecRequest(..actual.request, token: <<10:size(256)>>),
    )
  assert binding.reserve(configured(f, changed, request_id(60)), request)
    == Error(custody.Conflict)
  assert custodian.command_child(f.owner, offer.reference(held.proposal))
    == Error(custody.Missing)
  stop(f)
}

pub fn wrong_parent_scope_and_cleared_command_drift_never_gain_native_slot_test() {
  let p = producer(0)
  let held = launch(p, artifact(p.result))
  let data = offer.data(held.proposal)
  let assert Ok(run_step) = workspace.step("physical:run")
    as "Original bounded run step."
  let assert Ok(wrong_parent) =
    command.service_key(
      parent(1),
      command.LaunchService,
      enrollment.native_facts(enrolled()).scope,
      operation(2),
      run_step,
      request_id(30),
      hash(input.encode_launch(held.original)),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "A complete different parent can carry a syntactically canonical stored input."
  let assert Ok(wrong_ref) =
    command.command_ref(wrong_parent, command.SatelliteCommand)
    as "Closed native role under changed parent."
  let assert Ok(changed) =
    offer.offer(wrong_ref, offer.mappings(held.proposal), data)
    as "Changed full parent preserves an otherwise shape-valid proposal."

  // The same data under another complete parent does not link the producer.
  let f = fixture()
  retain_producer(f, p, Some(p.result), input.encode_compile(p.original))
  retain_launch(
    f,
    Launch(wrong_parent, held.original, changed),
    changed,
    input.encode_launch(held.original),
  )
  rejected_before_prepare(f, changed)
  stop(f)

  // Cleared native fields may narrow policy, but cannot alter the launch command.
  let f = fixture()
  retain_producer(f, p, Some(p.result), input.encode_compile(p.original))
  retain_launch(f, held, held.proposal, input.encode_launch(held.original))
  let actual = prepared(held.proposal)
  let requests = [
    exec.ExecRequest(..actual.request, argv: ["/otp/bin/erl", "-name", "unsafe"]),
    exec.ExecRequest(..actual.request, env: list.reverse(actual.request.env)),
    exec.ExecRequest(..actual.request, cwd: "/executor/work/foreign"),
    exec.ExecRequest(
      ..actual.request,
      policy: Some(
        policy.SandboxPolicy(..data.requirements, network: policy.NetworkFull),
      ),
    ),
  ]
  list.each(requests, fn(request) {
    let changed = wire.Prepared(..actual, request: request)
    let assert Error(_) =
      binding.reserve(
        configured(f, changed, request_id(60)),
        dispatched(held.proposal, changed),
      )
      as "Changed cleared command or widened policy cannot enter custody."
  })
  assert custodian.command_child(f.owner, offer.reference(held.proposal))
    == Error(custody.Missing)
  stop(f)
}

pub fn fresh_narrower_launch_policy_and_foreign_scope_refusal_test() {
  let f = fixture()
  let p = producer(0)
  retain_producer(f, p, Some(p.result), input.encode_compile(p.original))
  let held = launch(p, artifact(p.result))
  retain_launch(f, held, held.proposal, input.encode_launch(held.original))
  let actual = prepared(held.proposal)
  let requirements = offer.data(held.proposal).requirements

  // The actual cleared policy may be narrower; no template replaces its bytes.
  let narrower =
    policy.SandboxPolicy(
      ..requirements,
      protected: ["/executor/work/private", ..requirements.protected],
      limits: policy.Limits(..requirements.limits, wall_s: 1),
    )
  let actual =
    wire.Prepared(
      ..actual,
      request: exec.ExecRequest(..actual.request, policy: Some(narrower)),
    )
  let assert Ok(dispatcher.CommandReserved(_, retained, _)) =
    binding.reserve(
      configured(f, actual, request_id(60)),
      dispatched(held.proposal, actual),
    )
    as "First admission retains the actual narrower policy."
  assert retained.request.policy == Some(narrower)
  let assert Ok(workspace) = identity.workspace_id("checkout")
    as "Original workspace."
  let assert Ok(executor) = identity.executor_id("linux")
    as "Original executor."
  let assert Ok(epoch) = identity.epoch(1) as "Original authority epoch."
  let assert Ok(stale) = identity.epoch(2)
    as "A foreign authority epoch is data."

  // A complete but foreign epoch refuses before any prepare or UUID callback.
  let foreign = identity.scope(session_id(1), workspace, executor, epoch, stale)
  let assert Error(custody.Conflict) =
    binding.new(
      f.owner,
      enrolled(),
      foreign,
      fn(_) { panic as "No foreign-scope preparation." },
      fn() { panic as "No foreign-scope UUID." },
    )
    as "Pinned enrollment prevents context substitution."
  stop(f)
}

pub fn original_broker_dispatch_preserves_actual_token_demand_deadline_and_narrowing_test() {
  let f = fixture()
  let p = producer(0)
  retain_producer(f, p, Some(p.result), input.encode_compile(p.original))
  let held = launch(p, artifact(p.result))
  retain_launch(f, held, held.proposal, input.encode_launch(held.original))

  // The real Broker supplies the actual token and original Dispatch context.
  let observed = process.new_subject()
  let assert Ok(original) =
    broker.start_dispatching(
      token.production_entropy(),
      clock.from_function(poll.monotonic().now),
      dispatch.Dispatcher(fn(request) {
        let template = prepared(held.proposal)
        let actual = wire.Prepared(..template, request: request.request)
        let result =
          binding.reserve(configured(f, actual, request_id(60)), request)
        process.send(observed, #(request, actual, result))
        Error(dispatch.NotStarted)
      }),
    )
    as "One real original Broker clears the exact satellite command."
  let data = offer.data(held.proposal)
  let deadline = poll.monotonic().now() + 30_000
  let events = process.new_subject()
  let spec =
    broker.CallSpec(
      operation(2),
      "physical:run",
      base(),
      data.requirements,
      [],
      broker.RefuseNarrowed,
      exec.PlatformEnforcement,
      data.argv,
      data.env,
      data.cwd,
      budget.Budget(3, deadline),
    )

  // This fixture captures a real clearance but explicitly starts no physical work.
  let assert Error(_) =
    broker.clear_call_from(
      original,
      command.native_origin(offer.reference(held.proposal)),
      spec,
      events: events,
      waiting: 2000,
    )
    as "Fixture dispatch explicitly declines physical startup after real clearance and custody."
  let assert Ok(#(
    request,
    actual,
    Ok(dispatcher.CommandReserved(_, retained, _)),
  )) = process.receive(observed, 2000)
    as "Actual Broker Dispatch entered exact owner Launch command custody."
  assert retained == actual
  assert request.request == actual.request
  assert bit_array.byte_size(actual.request.token) == 32
  assert actual.request.demand == exec.PlatformEnforcement
  assert request.deadline_ms == deadline

  // Durable parent provenance keeps the original run coordinates and deadline.
  assert request.context.operation == operation(2)
  assert request.context.step == "physical:run"
  assert request.context.origin
    == Some(command.native_origin(offer.reference(held.proposal)))

  // The original token and narrowed cleared policy survive an exact retry.
  let requirements = data.requirements
  let narrower =
    policy.SandboxPolicy(
      ..requirements,
      protected: ["/executor/work/private", ..requirements.protected],
      limits: policy.Limits(..requirements.limits, wall_s: 1),
    )
  let narrowed =
    wire.Prepared(
      ..actual,
      request: exec.ExecRequest(..actual.request, policy: Some(narrower)),
    )
  let changed_request = dispatch.Dispatch(..request, request: narrowed.request)
  let assert Error(_) =
    binding.reserve(configured(f, narrowed, request_id(61)), changed_request)
    as "A retry cannot replace already retained actual policy, even with a narrower one."
  broker.stop(original)
  stop(f)
}

fn fixture() -> Fixture {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let path =
    "build/launch-command-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(path) == Ok(Nil)
  let assert Ok(store) =
    custody.open(path <> "/owner.db", session_id(1), limits())
    as "Actual original owner SQLite."
  let assert Ok(bytes) = custody.payload(limits(), <<"original parent":utf8>>)
    as "Bounded parent request."
  assert custody.admit_fresh(store, parent(0), bytes, bytes)
    == Ok(custody.Fresh)
  assert custody.admit_fresh(store, parent(1), bytes, bytes)
    == Ok(custody.Fresh)
  assert custody.close(store) == Ok(Nil)

  // Only reopening validated original history publishes the address.
  let assert Ok(config) =
    custodian.config(
      path <> "/owner.db",
      session_id(1),
      limits(),
      1,
      5000,
      fn(_, _, _) { panic as "No tool body in this fixture." },
    )
    as "Original configured custody actor."
  let assert Ok(names) = registry.start() as "Private original registry."
  let owner = custodian.new(names, config)
  let assert Ok(started) = custodian.start(owner, config)
    as "Actual original custody publication."
  Fixture(owner, started.pid)
}

fn producer(index: Int) -> Producer {
  let assert Ok(step) = workspace.step("physical:build")
    as "Original Build coordinates."
  let assert Ok(key) =
    command.service_key(
      parent(index),
      command.CompileService,
      enrollment.native_facts(enrolled()).scope,
      operation(2),
      step,
      request_id(index + 20),
      hash(input.encode_compile(original())),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Full original Compile key."

  // Production location and command constructors preserve the exact allocation.
  let assert Ok(root) = enrollment.compile_path(enrolled(), key)
    as "Exact producer allocation."
  let assert Ok(locations) =
    resources.admit_compile_locations(enrolled(), key, root)
    as "Historical location equality."
  let assert Ok(expected) =
    service_command.compile_from_input(
      enrolled(),
      key,
      original(),
      locations,
      2,
    )
    as "Production compiler template."
  let proposal = service_command.offer(expected)
  let actual = prepared(proposal)
  let assert Ok(id) =
    identity.request_id(ids.entry_id_to_string(request_id(50 + index)))
    as "Original native UUID."
  let native_key = identity.request_key(scope(), operation(2), id)
  let assert Ok(digest) = wire.prepared_digest(actual)
    as "Digest of exact original native bytes."

  // The closed completion derives its report and executor artifact from this
  // original terminal and association. No physical compiler is claimed here.
  let assert Ok(terminal) =
    native.encode_terminal(
      dispatch.Completed(exec.ExecResult(
        0,
        0,
        0,
        0,
        False,
        False,
        ["fixture: bounded native settlement"],
        False,
        1,
        False,
        False,
      )),
    )
    as "Complete canonical original native terminal."
  let assert Ok(result) =
    completion.successful(
      enrolled(),
      key,
      locations,
      native_key,
      digest,
      terminal,
      compile.BuildProducts(
        root <> "/ebin",
        "sha256-" <> string.repeat("f", 64),
      ),
    )
    as "Production completion derives exact successful artifact and enforcement."
  Producer(key, original(), result, proposal, actual, native_key, terminal)
}

fn artifact(value: completion.CompileCompletion) -> compile.Artifact {
  let assert Ok(value) = completion.compiled(value).result
    as "Original producer succeeds."
  value
}

fn launch(p: Producer, artifact: compile.Artifact) -> Launch {
  let assert Ok(cwd) = workspace.relative_path(".")
    as "Literal executor-relative cwd."
  let assert Ok(original) =
    input.launch_input(
      enrolled(),
      p.key,
      artifact,
      [#("PATH", "/tc/bin"), #("TMPDIR", "/executor/work/tmp")],
      cwd,
      base(),
      string.repeat("a", 64),
    )
    as "Canonical original Launch input includes token commitment."
  let assert Ok(step) = workspace.step("physical:run")
    as "Run differs from original Build physical step."
  let assert Ok(key) =
    command.service_key(
      command.parent(p.key),
      command.LaunchService,
      enrollment.native_facts(enrolled()).scope,
      operation(2),
      step,
      request_id(30),
      hash(input.encode_launch(original)),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Full Launch key under the original managed parent."
  let assert Ok(paths) = enrollment.launch_paths(enrolled(), key)
    as "Original enrollment-derived channel allocation."
  let assert Ok(ready) =
    resources.admit_launch_resources(
      enrolled(),
      key,
      p.key,
      paths.0,
      paths.1,
      paths.2,
    )
    as "Location equality grants no live resource lease."

  // A stale manifest still has a valid bounded shape, allowing the actual binding
  // to compare it with retained success rather than relying on fixture rejection.
  let assert Ok(admitted) =
    input.admit_launch(
      key,
      enrolled(),
      original,
      p.key,
      compile.Compiled(Ok(artifact), completion.compiled(p.result).enforcement),
    )
    as "Fixture offers a shape-valid purported artifact for owner revalidation."
  let assert Ok(expected) =
    service_command.launch(enrolled(), admitted, ready, 2)
    as "Production satellite template."
  Launch(key, original, service_command.offer(expected))
}

fn retain_producer(
  f: Fixture,
  p: Producer,
  result: Option(completion.CompileCompletion),
  body: BitArray,
) -> Nil {
  let assert Ok(original) =
    custodian.reserve_service_child(f.owner, p.key, body)
    as "Original Compile input commits."
  retain_offer(f, original, p.proposal)
  let assert Ok(bytes) = wire.encode_prepared(p.prepared)
    as "Exact canonical producer native request."
  let assert Ok(offer_bytes) = offer.encode(p.proposal)
    as "Canonical retained producer offer."
  let assert Ok(payload) =
    custody.command_offer_payload(
      limits(),
      offer.reference(p.proposal),
      hash(offer_bytes),
      offer_bytes,
    )
    as "Existing original immutable native offer."
  let assert Ok(_) =
    custodian.reserve_command_child(
      f.owner,
      payload,
      request_id(50 + remote_tool.source_index(command.parent(p.key))),
      bytes,
    )
    as "Actual original owner native reservation."
  let assert Ok(receipt) = custodian.receipt([], p.terminal)
    as "Complete ordered original native receipt."
  assert custodian.receive_child(
      f.owner,
      command.native_origin(offer.reference(p.proposal)),
      request_id(50 + remote_tool.source_index(command.parent(p.key))),
      receipt,
    )
    == Ok(Nil)

  // Outer completion is a separate durable publication after native receipt.
  case result {
    None -> Nil
    Some(value) -> {
      let assert Ok(bytes) = completion.encode(value)
        as "Canonical original outer completion."
      assert custodian.receive_child(
          f.owner,
          service_origin(p.key),
          command.request_id(p.key),
          bytes,
        )
        == Ok(Nil)
    }
  }
}

fn retain_launch(
  f: Fixture,
  held: Launch,
  proposal: offer.CommandOffer,
  body: BitArray,
) -> Nil {
  let assert Ok(original) =
    custodian.reserve_service_child(f.owner, held.key, body)
    as "Original Launch request commits before offer."
  retain_offer(f, original, proposal)
}

fn retain_offer(
  f: Fixture,
  original: custody.ServiceRequest,
  proposal: offer.CommandOffer,
) -> Nil {
  let assert Ok(bytes) = offer.encode(proposal)
    as "Canonical immutable offer bytes."
  let assert Ok(payload) =
    custody.command_offer_payload(
      limits(),
      offer.reference(proposal),
      hash(bytes),
      bytes,
    )
    as "Bounded original offer."
  assert custodian.admit_offer(f.owner, original, payload) == Ok(custody.Fresh)
}

fn service_origin(key: command.ServiceKey) -> remote_tool.ChildOrigin {
  command.service_origin(key)
}

fn prepared(proposal: offer.CommandOffer) -> wire.Prepared {
  let data = offer.data(proposal)
  let assert Ok(bytes) = bit_array.base16_decode(string.repeat("b", 64))
    as "Original registration digest."
  let assert Ok(registration) = identity.digest(bytes)
    as "Fixed-width registration."
  wire.Prepared(
    workspace.step_string(
      command.coordinates(command.service(offer.reference(proposal))).2,
    ),
    registration,
    wire.Finite(180_000),
    exec.ExecRequest(
      data.argv,
      data.env,
      data.cwd,
      Some(data.requirements),
      <<9:size(256)>>,
      exec.PlatformEnforcement,
    ),
    wire.Logs,
  )
}

fn dispatched(
  proposal: offer.CommandOffer,
  actual: wire.Prepared,
) -> dispatch.Dispatch {
  let #(_, op, step) =
    command.coordinates(command.service(offer.reference(proposal)))
  dispatch.Dispatch(
    dispatch.CallContext(
      op,
      workspace.step_string(step),
      Some(command.native_origin(offer.reference(proposal))),
    ),
    actual.request,
    11,
    6000,
    clock.fixed(1000),
    None,
    fn(_) { Nil },
    fn(_) { Nil },
  )
}

fn configured(
  f: Fixture,
  actual: wire.Prepared,
  id: ids.EntryId,
) -> binding.Binding {
  let assert Ok(value) =
    binding.new(f.owner, enrolled(), scope(), fn(_) { Ok(actual) }, fn() { id })
    as "Pinned original local capabilities."
  value
}

fn guarded(f: Fixture) -> binding.Binding {
  let assert Ok(value) =
    binding.new(
      f.owner,
      enrolled(),
      scope(),
      fn(_) { panic as "Refusal must precede actual preparation." },
      fn() { panic as "Refusal must precede UUID candidate." },
    )
    as "Wrong evidence grants no downstream callback authority."
  value
}

fn rejected_before_prepare(f: Fixture, proposal: offer.CommandOffer) -> Nil {
  let assert Error(_) =
    binding.reserve(guarded(f), dispatched(proposal, prepared(proposal)))
    as "Original evidence mismatch is a definite pre-reservation refusal."
  assert custodian.command_child(f.owner, offer.reference(proposal))
    == Error(custody.Missing)
}

fn stop(f: Fixture) -> Nil {
  let monitor = process.monitor(f.pid)
  assert custodian.stop(f.owner) == Ok(Nil)
  let assert Ok(process.ProcessDown(_, _, process.Normal)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "Original SQLite actor exits normally and is joined."
  Nil
}
