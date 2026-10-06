//// Joined component acceptance uses an actual Fresh managed custodian body,
//// one original Broker and two independent TLS BEAM runtimes. The executor
//// runtime owns both service journals, the Compile actor and the OS compiler.
//// The fixture does not install a shipped registered-session deployment.
////
//// ## Flow
////
//// `original_broker_tls_compiler_native_receipt_outer_commit_then_ack_test`
//// joins actual effects. `historical_receipt` and `historical_evidence` retain
//// explicit journal history for closed receipt controls; `close_history` joins
//// every component. `refusal_lifecycle` compares pure refusal with ambiguous
//// original transmission under the existing durable managed-run admission fence.
//// `run_owner` and `run_executor` are fixed test administration roles. Historical
//// controls reopen committed databases on the executor and check receipts through
//// the concrete endpoint; they never transfer a local journal handle or Claim.
//// `beam_control` checks both subprocess exits and explicit final witnesses.

import broker/broker
import broker/budget
import broker/command as offer
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/executor as local
import broker/policy
import broker/token
import client/remote/compile_client as client
import client/remote/custodian
import client/remote/dispatch_binding
import client/remote/tool_custody
import codemode/build
import codemode/compile
import codemode/identity as phase
import codemode/service_command
import codemode/service_input as input
import codemode/service_resources as locations
import codemode/vet
import codemode/vet/policy as vet_policy
import core/clock
import core/command
import core/ids
import core/json
import core/message
import core/msgpack as mp
import core/remote_tool
import core/workspace
import distribution_fixture
import executor
import executor/remote/admission
import executor/remote/beam_endpoint as transport
import executor/remote/compile_completion as completion
import executor/remote/compile_service as whole
import executor/remote/compile_wire as executor_wire
import executor/remote/dispatcher
import executor/remote/distribution
import executor/remote/identity
import executor/remote/journal
import executor/remote/native
import executor/remote/payload
import executor/remote/resource_journal as resources
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import machine/operation
import runtime/effects
import simplifile
import storage/owner_custody as custody
import support/internal/ffi_proc
import telemetry/log
import tools/fs
import weft
import weft/poll
import weft/registry

fn native_executor(
  path: String,
  before_checkout: fn() -> Nil,
) -> local.Executor {
  let assert Ok(here) = simplifile.current_directory() as "Helper fixture root."
  let helper = here <> "/../sandbox/loom-exec"
  assert simplifile.is_file(helper) == Ok(True)
  assert simplifile.create_directory_all(path <> "/pool/tmp") == Ok(Nil)
  let spawn =
    exec.SpawnConfig(
      helper,
      "/bin/sh",
      executor.base_policy(path),
      [],
      path <> "/pool/tmp",
      3000,
      3000,
      0,
    )
  let assert Ok(pool) = exec.start_pool(1, fn() { exec.prepare_helper(spawn) })
    as "Real helper pool."
  let assert Ok(native) =
    local.start(local.ExecutorConfig(
      fn() {
        before_checkout()
        exec.checkout(pool, waiting: 3000)
      },
      fn(helper) { exec.checkin(pool, helper) },
      fn() { exec.pool_custody(pool, waiting: 1000) },
      fn(ms) { exec.close_pool(pool, waiting: ms) },
      23,
      log.discard(),
    ))
    as "Existing scoped native executor."
  native
}

fn enrolled(path: String) -> enrollment.SessionEnrollment {
  let base = base(path)
  let #(gleam_dir, gleam) = executable("gleam")
  let #(erl_dir, erl) = executable("erl")
  let system =
    list.filter(["/usr", "/bin", "/System"], fn(root) {
      simplifile.is_directory(root) == Ok(True)
    })
  let roots =
    list.unique([toolchain_root(gleam_dir), toolchain_root(erl_dir), ..system])
  let path_env =
    string.join(list.unique([gleam_dir, erl_dir, "/usr/bin", "/bin"]), ":")
  let assert Ok(enrolled) =
    enrollment.new(
      enrollment.NativeFacts(
        core_scope(),
        [path, channel(path)],
        base,
        exec.PlatformEnforcement,
      ),
      enrollment.CodeModeFacts(
        path <> "/work",
        path <> "/build",
        channel(path),
        gleam,
        erl,
        seed_root(),
        roots,
        [],
        path_env,
      ),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Exact fixture roots disjoint from immutable toolchains."
  enrolled
}

// The fixture pins actual executables from its trusted test process environment.
// It never accepts a peer-selected compiler or substitutes another executable.

fn executable(name: String) -> #(String, String) {
  let assert Ok(path) = ffi_proc.which(name)
    as "The real required toolchain is installed."
  let assert Ok(executable) = fs.resolve_real(fs.real_filesystem(), "/", path)
    as "Trusted toolchain symlinks are resolved before enrollment."
  let canonical_directory =
    string.join(
      list.reverse(list.drop(list.reverse(string.split(executable, "/")), 1)),
      "/",
    )
  #(canonical_directory, executable)
}

// Channel names stay within the socket-path ceiling; Compile never opens them.
// Its actual build allocation stays in the workspace, outside the jail's /tmp.

fn channel(path: String) -> String {
  let assert Ok(name) = list.last(string.split(path, "/"))
    as "Unique fixture name."
  let tmp = case simplifile.is_directory("/private/tmp") {
    Ok(True) -> "/private/tmp"
    _ -> "/tmp"
  }
  tmp <> "/" <> name <> "/ch"
}

fn toolchain_root(directory: String) -> String {
  case directory != "/bin" && string.ends_with(directory, "/bin") {
    True -> string.drop_end(directory, 4)
    False -> directory
  }
}

fn base(path: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..executor.base_policy(path),
    writable_roots: [path <> "/work", path <> "/build", channel(path)],
    protected: [],
    limits: policy.Limits(180, 180, 536_870_912, 64, 16_777_216, 262_144),
    env_allow: ["PATH", "TMPDIR"],
  )
}

fn core_scope() -> workspace.Scope {
  let assert Ok(scope) =
    workspace.scope_from_fields(
      "00000000-0000-7000-8000-000000000001",
      "checkout",
      "linux",
      2,
      7,
    )
    as "Full authority epochs."
  scope
}

fn scope() -> identity.Scope {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Session UUID."
  let assert Ok(name) = identity.workspace_id("checkout") as "Workspace label."
  let assert Ok(executor) = identity.executor_id("linux") as "Executor label."
  let assert Ok(session_epoch) = identity.epoch(2) as "Session authority epoch."
  let assert Ok(workspace_epoch) = identity.epoch(7)
    as "Workspace authority epoch."
  identity.scope(session, name, executor, session_epoch, workspace_epoch)
}

fn id(number: Int) -> ids.EntryId {
  let assert Ok(id) =
    ids.parse_entry_id(
      "00000000-0000-7000-8000-"
      <> string.pad_start(int.to_string(number), 12, "0"),
    )
    as "Stable original UUID."
  id
}

fn seed_root() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "Private executor tree."
  let assert Ok(root) =
    fs.resolve_real(
      fs.real_filesystem(),
      "/",
      here <> "/../../build/codemode-seed",
    )
    as "Canonical privately built production seed."
  root
}

fn registration() -> identity.Digest {
  let assert Ok(bytes) = bit_array.base16_decode(string.repeat("b", 64))
    as "Administrative SHA-256 spelling."
  let assert Ok(value) = identity.digest(bytes) as "Bounded digest."
  value
}

fn owner_limits() -> custody.Limits {
  let assert Ok(value) = custody.limits(4, 64, 67_108_864, 2_097_152)
    as "Original owner capacity."
  value
}

fn original_run() -> effects.ToolRun {
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Original operation."
  let source =
    "import cap/report\npub fn main() -> report.Outcome { report.text(\"done\") }"
  let args = json.Object([#("program", json.String(source))])
  effects.ToolRun(
    op,
    "consumer:tools",
    3,
    id(4),
    "main",
    message.ToolCall("original-code-mode", "code_mode", args, None, None),
    args,
    operation.ReplaySafe,
    [],
  )
}

fn final(
  original: effects.ToolRun,
  compiled: compile.Compiled,
) -> effects.ToolOutcome {
  effects.ToolCompleted(
    message.ToolResultMessage(
      original.call.id,
      original.call.name,
      [message.ToolResultText("whole Compile observed", None)],
      None,
      None,
      None,
      compiled.result |> is_failed,
      1000,
    ),
    False,
  )
}

fn is_failed(value: Result(a, e)) -> Bool {
  case value {
    Ok(_) -> False
    Error(_) -> True
  }
}

fn joined_owner(
  fixture: distribution_fixture.Provisioned,
  peer: distribution.Peer,
  path: String,
) -> Nil {
  let enrolled = enrolled(path)
  let reports = start_executor_node(fixture, path, 0)
  wait_file(path <> "/executor.ready", 15_000)
  let endpoint = transport.Config(peer, "owner", "linux", scope(), 1, 2500)
  let witness = process.new_subject()
  let prepared_witness = process.new_subject()
  let terminal_witness = process.new_subject()
  let assert Ok(names) = registry.start() as "Private owner actor address."
  let assert Ok(owner_config) =
    custodian.config(
      path <> "/owner.sqlite",
      ids.parse_session_id(identity.scope_fields(scope()).0) |> required,
      owner_limits(),
      1,
      290_000,
      fn(pinned, parent, original) {
        let original_clock =
          clock.from_function(fn() {
            let #(seconds, nanos) =
              timestamp.system_time()
              |> timestamp.to_unix_seconds_and_nanoseconds
            seconds * 1000 + nanos / 1_000_000
          })
        let assert Ok(binding) =
          dispatch_binding.new(
            pinned,
            endpoint,
            fn(request) {
              let actual =
                wire.Prepared(
                  request.context.step,
                  registration(),
                  wire.Finite(270_000),
                  request.request,
                  wire.Logs,
                )
              process.send(prepared_witness, actual)
              Ok(actual)
            },
            fn() { id(40) },
            poll.monotonic().now,
            23,
            270_000,
            fn(_) {
              let _ = custodian.fatal_fence(pinned, parent)
              Nil
            },
          )
          as "Pinned owner materializes only actual cleared Dispatch."
        let assert Ok(configuration) =
          dispatch_binding.with_commands(binding, enrolled)
          as "Closed Compile native binding."
        let concrete_dispatcher = dispatcher.dispatcher(configuration)
        let traced_dispatcher =
          dispatch.Dispatcher(fn(request) {
            concrete_dispatcher.start(
              dispatch.Dispatch(..request, settle: fn(terminal) {
                process.send(terminal_witness, terminal)
                request.settle(terminal)
              }),
            )
          })
        let assert Ok(original_broker) =
          broker.start_dispatching(
            token.production_entropy(),
            original_clock,
            traced_dispatcher,
          )
          as "Fixture's one original Broker exists before the consumer."
        let seed =
          policy.SandboxPolicy(
            ..base(path),
            network: policy.NetworkFull,
            limits: policy.Limits(..base(path).limits, wall_s: 0),
          )
        let facts =
          client.Facts(
            input.WorkspaceProgram,
            seed,
            180_000,
            5000,
            [],
            owner_limits(),
            vet_policy.workspace_effects(),
          )
        let assert Ok(config) =
          client.new(
            pinned,
            enrolled,
            original_broker,
            endpoint,
            fn() { id(20) },
            original_clock,
            poll.monotonic().now,
            facts,
          )
          as "Runner supplies its exact incarnation-pinned Handle."
        let #(unix, _) = clock.read(original_clock)
        let managed =
          phase.for_managed_execution(
            parent,
            budget: budget.Budget(1, unix + 270_000),
          )
        let source =
          "import cap/report\npub fn main() -> report.Outcome { report.text(\"done\") }"
        let assert vet.Passed(vetted) =
          vet.vet(source, vet_policy.workspace_effects())
          as "Actual owner vetting."
        let compiled =
          client.service(config).compile(compile.CompileRequest(
            compile.Original,
            vetted,
            compile.default_dependencies(),
            [],
            phase.build_phase(managed),
          ))
        process.send(witness, #(compiled, config, parent))
        broker.stop(original_broker)
        final(original, compiled)
      },
    )
    as "Existing custodian owns the Fresh managed body."
  let owner = custodian.new(names, owner_config)
  let assert Ok(started) = custodian.start(owner, owner_config)
    as "Original owner actor."
  let original = original_run()
  let assert Ok(invocation) =
    tool_custody.invocation(
      ids.parse_session_id(identity.scope_fields(scope()).0) |> required,
      <<"joined administrative context":utf8>>,
      original,
    )
    as "Complete original parent/effective arguments."
  let assert Ok(_) =
    custodian.execute(
      owner,
      invocation.key,
      invocation.arguments,
      invocation.request,
      original,
    )
    as "Only actual Fresh admission reaches the adapter."
  let assert Ok(#(compiled, consumer, parent)) = process.receive(witness, 2000)
    as "Actual compiler result returned from original body."
  let assert compile.Compiled(Ok(compile.ExecutorArtifact(..)), _) = compiled
    as "Real OS compiler succeeded."
  let assert Ok(dispatch.Completed(_)) = process.receive(terminal_witness, 2000)
    as "Actual native dispatcher settled compiler execution."
  let assert Ok(actual) = process.receive(prepared_witness, 2000)
    as "Actual Prepared followed original Broker clearance."
  let assert Some(actual_policy) = actual.request.policy
    as "Actual compiler policy was cleared."
  assert actual_policy.network == policy.NetworkOff
  assert actual_policy.limits.wall_s > 0
  assert actual_policy.limits.wall_s <= 180
  let assert Ok(origin) = remote_tool.tool_child(parent, remote_tool.Compile)
    as "Exact outer service origin."
  let assert Ok(#(_, envelope, Some(bytes))) = custodian.child(owner, origin)
    as "Exact owner completion COMMIT exists before returning."
  let assert Ok(original_input) = executor_input(enrolled, envelope)
    as "Same canonical whole identity."
  let completed =
    completion.decode(enrolled, original_input.key, bytes) |> required
  let assert Some(completion.NativeAssociation(_, digest, _)) =
    completion.native_association(completed)
    as "Real native association retained."
  assert wire.prepared_digest(actual) == Ok(digest)
  let assert Ok(ref) =
    command.command_ref(original_input.key, command.CompileCommand)
    as "Native and service custody remain distinct."
  let assert Ok(#(native_id, _, Some(_))) = custodian.command_child(owner, ref)
    as "Dispatcher's real ordered native receipt is committed."
  assert native_id == id(40)
  let root = enrollment.compile_path(enrolled, original_input.key) |> required
  assert build.fingerprint_directory(root <> "/ebin")
    == Ok(compile.artifact_hash(compiled.result |> required))
  let assert Ok(client.Completed(_, recovered, _)) =
    client.recover(consumer, origin)
    as "Historical readback never re-clears or mints."
  assert recovered == compiled

  // Exact subtree death closes fixture resources after all completion assertions.
  let owner_monitor = process.monitor(started.pid)
  assert custodian.stop(owner) == Ok(Nil)
  join(owner_monitor)
  assert simplifile.write_bits(path <> "/original.input", envelope) == Ok(Nil)
  assert simplifile.write_bits(path <> "/owner.completion", bytes) == Ok(Nil)
  assert simplifile.write(path <> "/owner.done", "done") == Ok(Nil)
  executor_finished(reports)
}

fn required(value: Result(a, e)) -> a {
  let assert Ok(value) = value as "Fixture requires exact checked data."
  value
}

fn executor_input(
  enrolled: enrollment.SessionEnrollment,
  bytes: BitArray,
) -> Result(resources.Input, executor_wire.Error) {
  executor_wire.decode_input(enrolled, bytes)
}

fn join(monitor: process.Monitor) -> Nil {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(3000)
    as "Exact component joined."
  Nil
}

// These controls exercise authenticated historical observation and actual journal
// readback. Their manually retained terminal is history, never an OS launch claim.
type History {
  History(
    path: String,
    owner: custodian.Handle,
    owner_pid: process.Pid,
    consumer: client.Config,
    broker: broker.Broker,
    endpoint: transport.Config,
    enrolled: enrollment.SessionEnrollment,
    reports: process.Subject(weft.Pulled(#(Int, String), String)),
    original: resources.Input,
    completion: completion.CompileCompletion,
  )
}

fn historical_receipt(
  fixture: distribution_fixture.Provisioned,
  peer: distribution.Peer,
  receipt: fn(BitArray) -> BitArray,
) -> History {
  historical_evidence(fixture, peer, receipt, fn(prepared) { prepared }, id(40))
}

fn historical_evidence(
  fixture: distribution_fixture.Provisioned,
  peer: distribution.Peer,
  receipt: fn(BitArray) -> BitArray,
  retained_prepared: fn(wire.Prepared) -> wire.Prepared,
  owner_request_id: ids.EntryId,
) -> History {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let assert Ok(here) = simplifile.current_directory() as "Private client tree."
  let path =
    here
    <> "/build/compile-receipt-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(path <> "/work") == Ok(Nil)
  assert simplifile.create_directory_all(path <> "/build") == Ok(Nil)
  let enrolled = enrolled(path)
  let parent =
    tool_custody.invocation(
      ids.parse_session_id(identity.scope_fields(scope()).0) |> required,
      <<"historical administrative context":utf8>>,
      original_run(),
    )
    |> required
  let store =
    custody.open(
      path <> "/owner.sqlite",
      remote_tool.session(parent.key),
      owner_limits(),
    )
    |> required
  let args = custody.payload(owner_limits(), parent.arguments) |> required
  let invocation = custody.payload(owner_limits(), parent.request) |> required
  assert custody.admit_fresh(store, parent.key, args, invocation)
    == Ok(custody.Fresh)
  assert custody.close(store) == Ok(Nil)
  let names = registry.start() |> required
  let owner_config =
    custodian.config(
      path <> "/owner.sqlite",
      remote_tool.session(parent.key),
      owner_limits(),
      1,
      5000,
      fn(_, _, _) { panic as "Historical controls never enter a fresh body." },
    )
    |> required
  let owner = custodian.new(names, owner_config)
  let owner_started = custodian.start(owner, owner_config) |> required
  let decoded =
    input.compile_input(
      enrolled,
      input.WorkspaceProgram,
      "import cap/report\npub fn main() -> report.Outcome { report.text(\"done\") }",
      [],
      compile.default_dependencies(),
      base(path),
      180_000,
    )
    |> required
  let body = input.encode_compile(decoded)
  let step = workspace.step("consumer:tools") |> required
  let key =
    command.service_key(
      parent.key,
      command.CompileService,
      core_scope(),
      original_run().operation,
      step,
      id(20),
      hash(body),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    |> required
  let original = resources.Input(key, body)
  let retained_input =
    custodian.reserve_service_child(owner, key, body) |> required
  let capacity = admission.capacity(16) |> required
  let native =
    journal.fresh(path <> "/native.sqlite", scope(), capacity) |> required
  let book =
    resources.fresh(
      path <> "/resources.sqlite",
      enrolled,
      resources.limits(16, 30_000_000) |> required,
      native,
    )
    |> required
  assert resources.reserve(book, original) == Ok(resources.Reserved)
  let assert Ok(resources.Claimed(claim)) =
    resources.claim_preparation(book, original)
    as "Original historical preparation."
  let ready =
    locations.admit_compile_locations(
      enrolled,
      key,
      enrollment.compile_path(enrolled, key) |> required,
    )
    |> required
  assert resources.commit_ready(claim, locations.CompileReady(ready))
    == Ok(resources.Prepared(locations.CompileReady(ready)))
  let expected =
    service_command.compile_from_input(enrolled, key, decoded, ready, 5)
    |> required
  let proposal = service_command.offer(expected)
  let proposal_bytes = offer.encode(proposal) |> required
  let retained_offer =
    custody.command_offer_payload(
      owner_limits(),
      offer.reference(proposal),
      hash(proposal_bytes),
      proposal_bytes,
    )
    |> required
  let _ =
    custodian.admit_offer(owner, retained_input, retained_offer) |> required
  let data = offer.data(proposal)
  let prepared =
    wire.Prepared(
      "consumer:tools",
      registration(),
      wire.Finite(180_000),
      exec.ExecRequest(
        data.argv,
        data.env,
        data.cwd,
        Some(data.requirements),
        <<0:size(256)>>,
        exec.PlatformEnforcement,
      ),
      wire.Logs,
    )
  let prepared_bytes = wire.encode_prepared(prepared) |> required
  let digest = wire.prepared_digest(prepared) |> required
  let native_id =
    identity.request_id(ids.entry_id_to_string(id(40))) |> required
  let native_key =
    identity.request_key(scope(), original_run().operation, native_id)
  assert journal.put_payload(
      native,
      native_key,
      digest,
      payload.Request(prepared_bytes),
    )
    == Ok(Nil)
  let _ = journal.admit(native, native_key, digest) |> required
  let ref = command.command_ref(key, command.CompileCommand) |> required
  assert resources.associate_native(book, original, ref, native_key, digest)
    == Ok(resources.Associated(ref, native_key, digest, prepared))
  let _ =
    journal.apply(native, native_key, digest, admission.AuthorizeLaunch)
    |> required
  let terminal =
    native.encode_terminal(
      dispatch.Completed(exec.ExecResult(
        1,
        0,
        100,
        200,
        False,
        False,
        ["seatbelt"],
        False,
        99,
        False,
        False,
      )),
    )
    |> required
  assert journal.put_payload(
      native,
      native_key,
      digest,
      payload.Terminal(terminal),
    )
    == Ok(Nil)
  let _ =
    journal.apply(
      native,
      native_key,
      digest,
      admission.ObserveTerminal(wire.digest(terminal) |> required),
    )
    |> required
  let value =
    completion.failed_native(
      enrolled,
      key,
      native_key,
      digest,
      terminal,
      compile.BuildRejected("retained compiler failure"),
    )
    |> required
  let _ = resources.commit_compile(book, original, value) |> required
  let _ =
    custodian.reserve_command_child(
      owner,
      retained_offer,
      owner_request_id,
      wire.encode_prepared(retained_prepared(prepared)) |> required,
    )
    |> required
  assert custodian.receive_child(
      owner,
      command.native_origin(ref),
      owner_request_id,
      receipt(terminal),
    )
    == Ok(Nil)
  // The independently booted executor reopens durable history. Releasing these
  // setup actors cannot turn retained rows into another live preparation claim.
  assert resources.release_endpoint(book) == Ok(Nil)
  assert journal.release(native) == Ok(Nil)
  let reports = start_executor_node(fixture, path, 1)
  wait_file(path <> "/executor.ready", 15_000)
  let endpoint = transport.Config(peer, "owner", "linux", scope(), 1, 2500)
  let original_broker =
    broker.start_dispatching(
      token.production_entropy(),
      clock.fixed(1000),
      dispatch.Dispatcher(fn(_) { panic as "Historical controls cannot clear." }),
    )
    |> required
  let consumer =
    client.new(
      owner,
      enrolled,
      original_broker,
      endpoint,
      fn() { panic as "Historical controls cannot mint." },
      clock.fixed(1000),
      poll.monotonic().now,
      client.Facts(
        input.WorkspaceProgram,
        base(path),
        180_000,
        5000,
        [],
        owner_limits(),
        vet_policy.workspace_effects(),
      ),
    )
    |> required
  History(
    path,
    owner,
    owner_started.pid,
    consumer,
    original_broker,
    endpoint,
    enrolled,
    reports,
    original,
    value,
  )
}

fn hash(bytes: BitArray) -> String {
  string.lowercase(
    bit_array.base16_encode(identity.digest_bytes(
      wire.digest(bytes) |> required,
    )),
  )
}

fn close_history(history: History) -> Nil {
  broker.stop(history.broker)
  let owner_monitor = process.monitor(history.owner_pid)
  assert custodian.stop(history.owner) == Ok(Nil)
  join(owner_monitor)
  assert simplifile.write(history.path <> "/owner.done", "done") == Ok(Nil)
  executor_finished(history.reports)
  assert simplifile.delete(history.path) == Ok(Nil)
}

fn maximum_ordered_receipt_exceeds_wire_profile_and_commits_before_ack(
  fixture: distribution_fixture.Provisioned,
  peer: distribution.Peer,
) {
  let history =
    historical_receipt(fixture, peer, fn(terminal) {
      let receipt =
        custodian.receipt(list.repeat(<<0:size(16_384 * 8)>>, 64), terminal)
        |> required
      assert bit_array.byte_size(receipt) > 262_144
      receipt
    })
  let origin = command.service_origin(history.original.key)
  assert client.recover(history.consumer, origin)
    == Ok(client.Completed(
      history.original.key,
      completion.compiled(history.completion),
      client.ExecutorAcknowledged,
    ))
  let bytes = completion.encode(history.completion) |> required
  let assert Ok(#(_, _, Some(retained))) =
    custodian.child(history.owner, origin)
    as "Owner completion committed before ACK."
  assert retained == bytes
  let assert Ok(executor_wire.Retained(_, _, _, resources.ReceiptAcknowledged)) =
    peer_completion(history)
    as "Same peer exact completion acknowledged."
  close_history(history)
}

fn malformed_ordered_receipts_refuse_outer_commit_and_ack(
  fixture: distribution_fixture.Provisioned,
  peer: distribution.Peer,
) {
  let candidates = [
    fn(_) { <<0x92, 0xdc, 65:16, 0xc4, 0>> },
    fn(t) {
      <<
        0x92,
        0x91,
        0xc5,
        16_385:16,
        0:size(
          16_385
          * 8
        ),
        0xc5,
        bit_array.byte_size(t):16,
        t:bits,
      >>
    },
    fn(_) { <<0x92, 0x90, 0xc5, 32_769:16, 0:size(32_769 * 8)>> },
    fn(_) { <<0x92, 0x91, 0x90, 0xc4, 0>> },
    fn(_) { <<0x92, 0x90, 0xa0>> },
    fn(t) { <<{ custodian.receipt([], t) |> required }:bits, 0>> },
    fn(t) { <<0x92, 0x90, 0xc5, { bit_array.byte_size(t) + 1 }:16, t:bits>> },
    fn(t) { <<0x92, 0xdc, 0:16, 0xc5, bit_array.byte_size(t):16, t:bits>> },
    fn(t) { <<0x92, 0x90, 0xc6, bit_array.byte_size(t):32, t:bits>> },
  ]
  list.each(candidates, fn(candidate) {
    let history = historical_receipt(fixture, peer, candidate)
    let origin = command.service_origin(history.original.key)
    let assert Error(client.Invalid(_)) =
      client.recover(history.consumer, origin)
      as "Closed ordered receipt refuses before outer COMMIT."
    let assert Ok(#(_, _, None)) = custodian.child(history.owner, origin)
      as "No rejected completion receipt retained."
    let assert Ok(executor_wire.Retained(_, _, _, resources.ReceiptPending)) =
      peer_completion(history)
      as "Rejected receipt cannot authorize outer ACK."
    close_history(history)
  })
}

fn native_uuid_prepared_digest_and_terminal_must_match_independent_custody(
  fixture: distribution_fixture.Provisioned,
  peer: distribution.Peer,
) {
  // One provisioned executor name has one runtime at a time. Each substitution
  // keeps the same assertions while its exact remote history is joined before
  // the next independent fixture reopens that configured administrative identity.
  let histories = [
    fn() {
      historical_receipt(fixture, peer, fn(_) {
        custodian.receipt([], <<"foreign native terminal":utf8>>) |> required
      })
    },
    fn() {
      historical_evidence(
        fixture,
        peer,
        fn(t) { custodian.receipt([], t) |> required },
        fn(prepared) { wire.Prepared(..prepared, step: "different:physical") },
        id(40),
      )
    },
    fn() {
      historical_evidence(
        fixture,
        peer,
        fn(t) { custodian.receipt([], t) |> required },
        fn(p) { p },
        id(41),
      )
    },
  ]
  list.each(histories, fn(create) {
    let history = create()
    let origin = command.service_origin(history.original.key)
    let assert Error(client.Invalid(_)) =
      client.recover(history.consumer, origin)
      as "Independent native equality refuses substituted evidence."
    let assert Ok(#(_, _, None)) = custodian.child(history.owner, origin)
      as "Foreign evidence cannot become outer receipt."
    let assert Ok(executor_wire.Retained(_, _, _, resources.ReceiptPending)) =
      peer_completion(history)
      as "Foreign evidence cannot acknowledge peer custody."
    close_history(history)
  })
}

fn owner_receipt_write_failure_prevents_outer_ack(
  fixture: distribution_fixture.Provisioned,
  peer: distribution.Peer,
) {
  let history =
    historical_receipt(fixture, peer, fn(t) {
      custodian.receipt([], t) |> required
    })
  let sqlite = ffi_proc.which("sqlite3") |> required
  let statement =
    "CREATE TRIGGER refuse_outer_receipt BEFORE UPDATE OF terminal ON owner_custody_children WHEN NEW.request_id = '00000000-0000-7000-8000-000000000020' BEGIN SELECT RAISE(ABORT, 'test owner receipt write failed'); END;"
  let assert Ok(#(0, _)) =
    ffi_proc.run(
      sqlite,
      [history.path <> "/owner.sqlite", statement],
      in: history.path,
    )
    as "Real owner write failure installed independently."
  let origin = command.service_origin(history.original.key)
  let assert Error(client.OwnerUnavailable(_)) =
    client.recover(history.consumer, origin)
    as "Actual owner write failure is not an acknowledged receipt."
  let assert Ok(executor_wire.Retained(_, _, _, resources.ReceiptPending)) =
    peer_completion(history)
    as "No outer ACK before durable owner COMMIT."
  close_history(history)
}

// Pure refusal and ambiguous transport loss share no phase flag in production.
// Only the latter enters the uncertainty-bearing observer and fences the run.
type Refusal {
  InvalidInput
  AmbiguousTransmission
}

fn refusal_lifecycle(peer: distribution.Peer, mode: Refusal) -> Nil {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let assert Ok(here) = simplifile.current_directory() as "Private client tree."
  let path =
    here
    <> "/build/compile-refusal-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(path <> "/work") == Ok(Nil)
  assert simplifile.create_directory_all(path <> "/build") == Ok(Nil)
  let enrolled = enrolled(path)
  let endpoint = transport.Config(peer, "owner", "linux", scope(), 1, 500)
  let names = registry.start() |> required
  let witness = process.new_subject()
  let config =
    custodian.config(
      path <> "/owner.sqlite",
      ids.parse_session_id(identity.scope_fields(scope()).0) |> required,
      owner_limits(),
      1,
      5000,
      fn(pinned, parent, original) {
        let original_clock = clock.fixed(1000)
        let broker =
          broker.start_dispatching(
            token.production_entropy(),
            original_clock,
            dispatch.Dispatcher(fn(_) {
              panic as "Neither refusal can clear native work."
            }),
          )
          |> required
        let consumer =
          client.new(
            pinned,
            enrolled,
            broker,
            endpoint,
            fn() { id(20) },
            original_clock,
            poll.monotonic().now,
            client.Facts(
              input.WorkspaceProgram,
              base(path),
              180_000,
              5000,
              [],
              owner_limits(),
              vet_policy.workspace_effects(),
            ),
          )
          |> required
        let assert vet.Passed(vetted) =
          vet.vet(
            "import cap/report\npub fn main() -> report.Outcome { report.text(\"done\") }",
            vet_policy.workspace_effects(),
          )
          as "Actual owner source vetting."
        let generated = case mode {
          InvalidInput -> [#("../outside.gleam", "pub fn main() { Nil }")]
          AmbiguousTransmission -> []
        }
        let managed =
          phase.for_managed_execution(parent, budget: budget.Budget(1, 61_000))
          |> phase.build_phase
        let compiled =
          client.service(consumer).compile(compile.CompileRequest(
            compile.Original,
            vetted,
            compile.default_dependencies(),
            generated,
            managed,
          ))
        process.send(witness, #(compiled, parent))
        broker.stop(broker)
        final(original, compiled)
      },
    )
    |> required
  let owner = custodian.new(names, config)
  let started = custodian.start(owner, config) |> required
  let original = original_run()
  let invocation =
    tool_custody.invocation(
      ids.parse_session_id(identity.scope_fields(scope()).0) |> required,
      <<"exact original context":utf8>>,
      original,
    )
    |> required
  let answer =
    custodian.execute(
      owner,
      invocation.key,
      invocation.arguments,
      invocation.request,
      original,
    )
  let assert Ok(#(
    compile.Compiled(Error(compile.BuildUnavailable(_)), _),
    parent,
  )) = process.receive(witness, 2000)
    as "Refusal returns bounded original evidence."
  let origin = remote_tool.tool_child(parent, remote_tool.Compile) |> required
  let next = effects.ToolRun(..original, source_index: 4, result_entry: id(5))
  let next_invocation =
    tool_custody.invocation(
      ids.parse_session_id(identity.scope_fields(scope()).0) |> required,
      <<"exact original context":utf8>>,
      next,
    )
    |> required
  case mode {
    InvalidInput -> {
      let assert Ok(_) = answer
        as "Pure refusal can durably finish and discharge."
      assert custodian.child(owner, origin) == Error(custody.Missing)
      let assert Ok(_) =
        custodian.execute(
          owner,
          next_invocation.key,
          next_invocation.arguments,
          next_invocation.request,
          next,
        )
        as "No sticky fence for a call which never asked custody or transport."
      Nil
    }
    AmbiguousTransmission -> {
      let assert Error(custody.Unavailable(_)) = answer
        as "Direct pinned fatal fence retains unresolved custody."
      let assert Ok(#(service_id, _, None)) = custodian.child(owner, origin)
        as "Input COMMIT preceded first failed transmission."
      assert service_id == id(20)
      assert custodian.execute(
          owner,
          next_invocation.key,
          next_invocation.arguments,
          next_invocation.request,
          next,
        )
        == Error(custody.Capacity)
      assert custodian.lookup(
          owner,
          next_invocation.key,
          next_invocation.arguments,
          next_invocation.request,
        )
        == Error(custody.Missing)
    }
  }
  let monitor = process.monitor(started.pid)
  assert custodian.stop(owner) == Ok(Nil)
  join(monitor)
  assert simplifile.delete(path) == Ok(Nil)
}

fn pure_input_refusal_does_not_fence_or_reserve_service(
  peer: distribution.Peer,
) {
  refusal_lifecycle(peer, InvalidInput)
}

fn ambiguous_original_transmission_retains_input_and_fences_new_admission(
  peer: distribution.Peer,
) {
  refusal_lifecycle(peer, AmbiguousTransmission)
}

// The finite node runners are test administration, not a transport callback or
// live authority API. Each starts public bootstrap locally and derives Peer from
// its own successful Membership before using the one fixed endpoint.

type ExecutorSide {
  ExecutorSide(
    enrolled: enrollment.SessionEnrollment,
    native_book: journal.Journal,
    resource_book: resources.Journal,
    native_service: service.Service,
    whole_service: whole.Service,
  )
}

fn executor_component(path: String, mode: Int) -> ExecutorSide {
  let enrolled = enrolled(path)
  let assert Ok(capacity) = admission.capacity(16) as "Finite native slots."
  let assert Ok(native_book) = case mode {
    0 -> journal.fresh(path <> "/native.sqlite", scope(), capacity)
    1 -> journal.recover(path <> "/native.sqlite", scope(), capacity)
    _ -> Error(journal.InvalidPath)
  }
    as "Actual native journal."
  let assert Ok(ceilings) = resources.limits(16, 30_000_000)
    as "Whole service reservation ceilings."
  let assert Ok(resource_book) = case mode {
    0 ->
      resources.fresh(
        path <> "/resources.sqlite",
        enrolled,
        ceilings,
        native_book,
      )
    1 ->
      resources.recover(
        path <> "/resources.sqlite",
        enrolled,
        ceilings,
        native_book,
      )
    _ -> Error(resources.InvalidLimits)
  }
    as "Actual resource journal."
  let native =
    native_executor(path, fn() {
      assert mode == 0 as "Historical TLS observation never executes a helper."
      Nil
    })
  let assert Ok(native_service) =
    service.start(service.Config(
      "owner",
      "linux",
      scope(),
      1,
      native_book,
      native,
      fn(_, prepared) {
        case prepared.registration == registration() {
          True -> Ok(Nil)
          False -> Error(Nil)
        }
      },
      poll.monotonic().now,
    ))
    as "Actual configured native service."
  let assert Ok(contract) =
    input.trusted_contract(
      enrolled,
      input.WorkspaceProgram,
      vet_policy.workspace_effects(),
      [],
    )
    as "Actual executor source contract."
  let assert Ok(whole_config) =
    whole.configure(resource_book, native_service, contract, 1)
    as "Original continuation assembly."
  let assert Ok(whole_service) = whole.start(whole_config)
    as "Actual Compile continuation."
  ExecutorSide(
    enrolled,
    native_book,
    resource_book,
    native_service,
    whole_service,
  )
}

/// Boots the fixed executor test role from original administrative provisioning.
/// Historical setup reopens committed evidence; live setup creates fresh journals.
///
/// ## Examples
///
/// ```gleam
/// compile_client_joined_test.run_executor(provisioned_file, service_path, 1)
/// // -> Nil after historical endpoint shutdown and the exact final witness.
/// ```
pub fn run_executor(provisioned: String, path: String, mode: Int) -> Nil {
  let fixture = distribution_fixture.read_provisioned(provisioned) |> required
  let membership = distribution.start(fixture.executor_config) |> required
  let owner = distribution.peer(membership, fixture.owner_name) |> required
  let side = executor_component(path, mode)
  let registration =
    transport.compile_registration(
      owner,
      side.whole_service,
      None,
      process.self(),
    )
    |> required
  let server =
    transport.start(
      transport.configure_server([registration], 30_000) |> required,
    )
    |> required
  assert simplifile.write(path <> "/executor.ready", "ready") == Ok(Nil)
  wait_file(path <> "/owner.done", 285_000)
  case mode {
    0 -> retained_executor_witness(side, path)
    1 -> Nil
    _ -> panic as "Only live or historical fixed executor setup is admitted."
  }
  let monitor = process.monitor(transport.pid(server))
  transport.stop(server)
  join(monitor)
  let closed = whole.close(side.whole_service)
  assert closed == Ok(Nil) || closed == Error(whole.Uncertain)
  assert service.shutdown(side.native_service) == Ok(Nil)
  assert resources.release_endpoint(side.resource_book) == Ok(Nil)
  assert journal.release(side.native_book) == Ok(Nil)
  io.println("COMPILE_EXECUTOR_COMPLETE")
}

fn retained_executor_witness(side: ExecutorSide, path: String) -> Nil {
  let envelope = simplifile.read_bits(path <> "/original.input") |> required
  let original = executor_input(side.enrolled, envelope) |> required
  let assert Ok(resources.CompileRetained(
    retained,
    resources.ReceiptAcknowledged,
  )) = resources.inspect_compile(side.resource_book, original)
    as "Peer outer ACK follows durable owner bytes."

  // The two journals must retain identical bytes, not merely matching decoded
  // identities. The owner writes this witness only after its durable readback.
  let owner_bytes =
    simplifile.read_bits(path <> "/owner.completion") |> required
  assert resources.retained_compile_bytes(retained) == owner_bytes
  let completed = resources.retained_compile_value(retained)
  let assert Some(completion.NativeAssociation(native_key, digest, _)) =
    completion.native_association(completed)
    as "Exact actual admitted native key."
  let payloads =
    journal.payloads(side.native_book, native_key, digest) |> required
  let authority =
    list.find_map(payloads, fn(item) {
      case item {
        payload.Authority(bytes) -> Ok(bytes)
        _ -> Error(Nil)
      }
    })
    |> required
  let request =
    list.find_map(payloads, fn(item) {
      case item {
        payload.Request(bytes) -> wire.decode_prepared(bytes)
        _ -> Error(wire.Invalid)
      }
    })
    |> required
  let assert Some(actual_policy) = request.request.policy
    as "Actual retained cleared compiler policy."
  assert wire.prepared_digest(request) == Ok(digest)
  let assert Ok(mp.ArrayValue([
    mp.IntValue(1),
    mp.IntValue(deadline),
    mp.IntValue(native_budget),
  ])) = wire.decode_value(authority)
    as "Actual retained finite Authority after Request and before Admit."
  assert deadline != 0 && native_budget >= actual_policy.limits.wall_s * 1000
  assert wire.encode_value(wire.decode_value(authority) |> required)
    == Ok(authority)
  io.println("ACTUAL_NATIVE_REQUEST_AUTHORITY_OUTER_ACK_RETAINED")
}

fn peer_completion(history: History) -> Result(executor_wire.Completion, Nil) {
  let bytes =
    executor_wire.encode_input(history.enrolled, history.original) |> required
  let #(metadata, content) =
    transport.compile_exchange(history.endpoint, executor_wire.Query, bytes)
    |> required
  let reply =
    executor_wire.decode_reply(
      history.enrolled,
      history.original.key,
      metadata,
      content,
    )
    |> required
  case reply {
    executor_wire.Observed(_, value) -> Ok(value)
    executor_wire.Challenge(_, _, _) | executor_wire.Cancelled(_) -> Error(Nil)
  }
}

fn wait_file(path: String, within: Int) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within:, every: 25, attempt: fn() {
      case simplifile.is_file(path) {
        Ok(True) -> poll.Done(Nil)
        Ok(False) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "The fixed node role reaches its exact readiness or finish witness."
  Nil
}

fn node_arguments(
  fixture: distribution_fixture.Provisioned,
  path: String,
  mode: Int,
  executor: Int,
) -> List(String) {
  let #(options, role) = case executor {
    1 -> #(fixture.executor_options, "run_executor")
    0 -> #(fixture.owner_options, "run_owner")
    _ -> panic as "Fixed node roles only."
  }
  let expression =
    "{ok,_}=application:ensure_all_started(client),'client@remote@compile_client_joined_test':"
    <> role
    <> "(<<\""
    <> fixture.directory
    <> "/fixture.term\">>,<<\""
    <> path
    <> "\">>,"
    <> int.to_string(mode)
    <> "),halt(0)."
  list.append(distribution_fixture.node_arguments(options), [
    "-noshell",
    "-eval",
    expression,
  ])
}

fn start_executor_node(
  fixture: distribution_fixture.Provisioned,
  path: String,
  mode: Int,
) -> process.Subject(weft.Pulled(#(Int, String), String)) {
  let reports = process.new_subject()
  let here = simplifile.current_directory() |> required
  let erl = distribution_fixture.current_executable()
  let _ =
    weft.new([
      fn() {
        distribution_fixture.run_node(
          erl,
          node_arguments(fixture, path, mode, 1),
          here,
          distribution.bootstrap_home(fixture.executor_config),
        )
      },
    ])
    |> weft.deadline(300_000)
    |> weft.start_relayed(to: reports)
  reports
}

fn executor_finished(
  reports: process.Subject(weft.Pulled(#(Int, String), String)),
) -> Nil {
  let assert Ok(weft.PulledOutcome(weft.Completed(_, #(exit, output)))) =
    process.receive(reports, 15_000)
    as "Independent executor finishes and joins its journals."
  io.println(output)
  assert exit == 0
  assert string.contains(output, "COMPILE_EXECUTOR_COMPLETE")
  assert process.receive(reports, 2000) == Ok(weft.AllDelivered)
}

/// Boots the original owner test role and selects one fixed consumer control.
/// The Peer derives locally from successful Membership before any exchange.
///
/// ## Examples
///
/// ```gleam
/// compile_client_joined_test.run_owner(provisioned_file, service_path, 0)
/// // -> Nil after real compiler custody and the exact final witness.
/// ```
pub fn run_owner(provisioned: String, path: String, control: Int) -> Nil {
  let fixture = distribution_fixture.read_provisioned(provisioned) |> required
  let membership = distribution.start(fixture.owner_config) |> required
  let peer = distribution.peer(membership, fixture.executor_name) |> required
  case control {
    0 -> joined_owner(fixture, peer, path)
    1 ->
      maximum_ordered_receipt_exceeds_wire_profile_and_commits_before_ack(
        fixture,
        peer,
      )
    2 -> malformed_ordered_receipts_refuse_outer_commit_and_ack(fixture, peer)
    3 ->
      native_uuid_prepared_digest_and_terminal_must_match_independent_custody(
        fixture,
        peer,
      )
    4 -> owner_receipt_write_failure_prevents_outer_ack(fixture, peer)
    5 -> pure_input_refusal_does_not_fence_or_reserve_service(peer)
    6 ->
      ambiguous_original_transmission_retains_input_and_fences_new_admission(
        peer,
      )
    _ -> panic as "Only the fixed original consumer controls are admitted."
  }
  io.println("COMPILE_OWNER_JOINED_COMPLETE")
}

fn beam_control(control: Int) -> Nil {
  let here = simplifile.current_directory() |> required
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/compile-beam-control-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let fixture =
    distribution_fixture.provision(root, "compile_joined") |> required
  assert distribution_fixture.write_provisioned(
      fixture,
      root <> "/fixture.term",
    )
    == Ok(Nil)
  let path = root <> "/service"
  assert simplifile.create_directory_all(path <> "/work") == Ok(Nil)
  assert simplifile.create_directory_all(path <> "/build") == Ok(Nil)
  let erl = distribution_fixture.current_executable()
  let assert [weft.Completed(_, #(exit, output))] =
    weft.new([
      fn() {
        distribution_fixture.run_node(
          erl,
          node_arguments(fixture, path, control, 0),
          here,
          distribution.bootstrap_home(fixture.owner_config),
        )
      },
    ])
    |> weft.deadline(300_000)
    |> weft.start
    as "Original owner node completes within the finite fixture bound."
  io.println(output)
  assert exit == 0
  assert string.contains(output, "COMPILE_OWNER_JOINED_COMPLETE")
  assert simplifile.delete(root) == Ok(Nil)
}

pub fn original_broker_tls_compiler_native_receipt_outer_commit_then_ack_test() {
  beam_control(0)
}

pub fn maximum_ordered_receipt_exceeds_wire_profile_and_commits_before_ack_test() {
  beam_control(1)
}

pub fn malformed_ordered_receipts_refuse_outer_commit_and_ack_test() {
  beam_control(2)
}

pub fn native_uuid_prepared_digest_and_terminal_must_match_independent_custody_test() {
  beam_control(3)
}

pub fn owner_receipt_write_failure_prevents_outer_ack_test() {
  beam_control(4)
}

pub fn pure_input_refusal_does_not_fence_or_reserve_service_test() {
  beam_control(5)
}

pub fn ambiguous_original_transmission_retains_input_and_fences_new_admission_test() {
  beam_control(6)
}
