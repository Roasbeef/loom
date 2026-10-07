//// Whole Compile actor controls own real journals, source preparation and helper.
//// The actor-local fixture preserves real Broker clearance and a managed parent;
//// it does not claim ordinary-tool or registered separate-host acceptance.

import broker/broker
import broker/budget
import broker/command as offer
import broker/dispatch
import broker/enrollment
import broker/exec
import broker/executor as local
import broker/policy
import broker/token
import codemode/build
import codemode/compile
import codemode/identity as phase
import codemode/run_channel
import codemode/service_command
import codemode/service_input as input
import codemode/service_resources as resources
import codemode/vet/policy as vet_policy
import core/clock
import core/command
import core/ids
import core/remote_tool
import core/workspace
import envoy
import executor
import executor/remote/admission
import executor/remote/compile_completion as completion
import executor/remote/compile_service as whole
import executor/remote/identity
import executor/remote/journal
import executor/remote/launch_completion
import executor/remote/launch_service as launch
import executor/remote/native
import executor/remote/resource_journal as j
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import telemetry/log
import tools/fs
import weft/poll

type Fixture {
  Fixture(
    path: String,
    enrolled: enrollment.SessionEnrollment,
    resources: j.Journal,
    journal: journal.Journal,
    service: service.Service,
    whole: whole.Service,
  )
}

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
  let assert Ok(path) = envoy.get("PATH") as "Test toolchain PATH is available."
  let assert Ok(directory) =
    list.find(string.split(path, ":"), fn(directory) {
      string.starts_with(directory, "/")
      && simplifile.is_file(directory <> "/" <> name) == Ok(True)
    })
    as "The real required toolchain is installed."
  let assert Ok(executable) =
    fs.resolve_real(fs.real_filesystem(), "/", directory <> "/" <> name)
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
    limits: policy.Limits(30, 30, 536_870_912, 64, 16_777_216, 262_144),
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

fn original(f: Fixture, number: Int, parent_step: String) -> j.Input {
  let assert Ok(session) =
    ids.parse_session_id("00000000-0000-7000-8000-000000000001")
    as "Managed session."
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
    as "Managed operation."
  let assert Ok(parent) =
    remote_tool.key(session, op, parent_step, 3, string.repeat("a", 64), id(4))
    as "Complete parent."
  let assert Ok(decoded) =
    input.compile_input(
      f.enrolled,
      input.WorkspaceProgram,
      "import cap/report\npub fn main() -> report.Outcome { report.text(\"done\") }",
      [],
      compile.default_dependencies(),
      base(f.path),
      30_000,
    )
    as "Bounded original Compile data."
  let bytes = input.encode_compile(decoded)
  let hash = string.lowercase(bit_array.base16_encode(j.digest(bytes)))
  let assert Ok(step) =
    workspace.step(
      phase.step_id(
        phase.build_phase(phase.for_managed_execution(
          parent,
          budget: budget.Budget(1, poll.monotonic().now() + 30_000),
        )),
      ),
    )
    as "Same physical coordinate across parents."
  let assert Ok(key) =
    command.service_key(
      parent,
      command.CompileService,
      core_scope(),
      op,
      step,
      id(number),
      hash,
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Complete original key."
  j.Input(key, bytes)
}

fn ref(original: j.Input) -> command.CommandRef {
  let assert Ok(ref) = command.command_ref(original.key, command.CompileCommand)
    as "Closed compile role."
  ref
}

fn key(original: j.Input, number: Int) -> identity.RequestKey {
  let assert Ok(request) =
    identity.request_id(ids.entry_id_to_string(id(number)))
    as "Native UUID is separate."
  identity.request_key(
    scope(),
    remote_tool.operation(command.parent(original.key)),
    request,
  )
}

fn registration() -> identity.Digest {
  let assert Ok(bytes) = bit_array.base16_decode(string.repeat("b", 64))
    as "Exact digest spelling."
  let assert Ok(hash) = identity.digest(bytes) as "Administrative digest."
  hash
}

fn digest(request: wire.Prepared) -> identity.Digest {
  let assert Ok(hash) = wire.prepared_digest(request)
    as "Exact full Prepared digest."
  hash
}

fn envelope(body: wire.Body) -> wire.Envelope {
  wire.Envelope(wire.Owner, "owner", "linux", 1, scope(), body)
}

fn limits() -> j.Limits {
  let assert Ok(limits) = j.limits(16, 30_000_000)
    as "Explicit fixture capacity."
  limits
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

fn fixture(run: fn(Fixture) -> Nil) -> Nil {
  clock_fixture(poll.monotonic().now, run)
}

fn clock_fixture(now: fn() -> Int, run: fn(Fixture) -> Nil) -> Nil {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let assert Ok(here) = simplifile.current_directory()
    as "Private test directory."
  let path =
    here
    <> "/build/whole-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  assert simplifile.create_directory_all(path <> "/build") == Ok(Nil)
  let enrolled = enrolled(path)
  let assert Ok(capacity) = admission.capacity(16) as "Finite native capacity."
  let assert Ok(book) =
    journal.fresh(path <> "/native.sqlite", scope(), capacity)
    as "Real native journal."
  let assert Ok(resources) =
    j.fresh(path <> "/resources.sqlite", enrolled, limits(), book)
    as "Real resource journal."
  let native = native_executor(path, fn() { Nil })
  let assert Ok(server) =
    service.start(service.Config(
      "owner",
      "linux",
      scope(),
      1,
      book,
      native,
      fn(_, prepared) {
        case prepared.registration == registration() {
          True -> Ok(Nil)
          False -> Error(Nil)
        }
      },
      now,
    ))
    as "One original native admission engine."
  let assert Ok(contract) =
    input.trusted_contract(
      enrolled,
      input.WorkspaceProgram,
      vet_policy.workspace_effects(),
      [],
    )
    as "Trusted actual effective source policy."
  let assert Ok(config) = whole.configure(resources, server, contract, 1)
    as "Pinned assembly."
  let assert Ok(whole) = whole.start(config) as "Temporary whole Compile actor."
  run(Fixture(path, enrolled, resources, book, server, whole))
  let closed = whole.close(whole)
  assert closed == Ok(Nil) || closed == Error(whole.Uncertain)
  case process.is_alive(service.pid(server)) {
    True -> {
      assert service.shutdown(server) == Ok(Nil)
    }
    False -> Nil
  }
  assert j.release_endpoint(resources) == Ok(Nil)
  assert journal.release(book) == Ok(Nil)
  assert simplifile.delete(path) == Ok(Nil)
}

fn caller() -> whole.Caller {
  whole.Caller(wire.Owner, "owner", "linux", 1, core_scope())
}

fn ask(
  f: Fixture,
  requested: whole.Operation,
) -> Result(whole.Reply, whole.Error) {
  let reply = process.new_subject()
  whole.send_operation(f.whole, caller(), requested, reply)
  process.receive(reply, 5000) |> gleam_result_unwrap
}

fn gleam_result_unwrap(
  reply: Result(Result(whole.Reply, whole.Error), Nil),
) -> Result(whole.Reply, whole.Error) {
  case reply {
    Ok(value) -> value
    Error(Nil) -> Error(whole.Uncertain)
  }
}

fn submit(f: Fixture, original: j.Input) -> Result(whole.Reply, whole.Error) {
  let assert Ok(whole.Challenge(_, nonce, 1000)) =
    ask(f, whole.ChallengeRequest(original.key))
    as "Original finite nonce."
  ask(f, whole.Submit(original, nonce, 30_000))
}

fn prepared(f: Fixture, original: j.Input) -> resources.CompileLocations {
  let outcome =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case j.inspect(f.resources, original) {
        Ok(j.Prepared(resources.CompileReady(locations))) ->
          poll.Done(locations)
        Ok(_) | Error(j.Missing) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
  let assert poll.Answered(locations) = outcome
    as "Original continuation committed actual Ready."
  locations
}

fn routed(
  f: Fixture,
  ref: command.CommandRef,
  body: wire.Body,
) -> Result(wire.Body, service.Error) {
  let assert Ok(envelope) = wire.command_envelope(ref, envelope(body))
    as "Complete command framing."
  let reply = process.new_subject()
  whole.send_command_exchange(f.whole, envelope, reply)
  let assert Ok(value) = process.receive(reply, 5000)
    as "Original final native response endpoint."
  value
}

fn cleared(
  f: Fixture,
  original: j.Input,
  locations: resources.CompileLocations,
) -> #(wire.Prepared, dispatch.Dispatch, broker.Broker, process.Pid) {
  let assert Ok(decoded) = input.decode_compile(original.body)
    as "Original bounded source."
  let assert Ok(expected) =
    service_command.compile_from_input(
      f.enrolled,
      original.key,
      decoded,
      locations,
      10,
    )
    as "Exact compiler wall selected after actual Ready."
  let data = offer.data(service_command.offer(expected))
  let observed = process.new_subject()
  let dispatcher =
    dispatch.Dispatcher(fn(request) {
      process.send(observed, #(request, process.self()))
      Ok(
        dispatch.Execution(
          dispatch.execution_id(19, request.seq),
          process.self(),
          fn() { Nil },
          fn(_, _) { Nil },
          fn() { Nil },
          fn() { Nil },
        ),
      )
    })
  let assert Ok(owner) =
    broker.start_dispatching(
      token.production_entropy(),
      clock.from_function(poll.monotonic().now),
      dispatcher,
    )
    as "Actual Broker performs composition, budget and token clearance."
  let managed =
    phase.for_managed_execution(
      command.parent(original.key),
      budget: budget.Budget(1, poll.monotonic().now() + 30_000),
    )
  let phase = phase.build_phase(managed)
  let assert Some(origin) = phase.command_origin(phase) |> result_unwrap
    as "Managed native child derives from actual parent."
  let spec =
    broker.CallSpec(
      phase.op_id(phase),
      phase.step_id(phase),
      data.requirements,
      data.requirements,
      [],
      broker.RefuseNarrowed,
      exec.PlatformEnforcement,
      data.argv,
      data.env,
      data.cwd,
      phase.pooled_budget(phase),
    )
  let events = process.new_subject()
  let assert Ok(_) =
    broker.clear_call_from(owner, origin, spec, events: events, waiting: 2000)
    as "Real original clearance succeeds."
  let assert Ok(#(request, owner_pid)) = process.receive(observed, 2000)
    as "Actual Dispatch carries cleared token, complete policy and original provenance."
  assert request.context.origin == Some(command.native_origin(ref(original)))
  assert request.context.step
    == workspace.step_string(command.coordinates(original.key).2)
  let prepared =
    wire.Prepared(
      request.context.step,
      registration(),
      wire.Finite(30_000),
      request.request,
      wire.Logs,
    )
  #(prepared, request, owner, owner_pid)
}

fn result_unwrap(
  value: Result(Option(remote_tool.ChildOrigin), String),
) -> Option(remote_tool.ChildOrigin) {
  let assert Ok(value) = value as "Valid managed child provenance."
  value
}

fn stop_broker(owner: broker.Broker, pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  broker.stop(owner)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "Actual Broker peer joined after explicit settlement."
  Nil
}

fn produce(f: Fixture) -> #(j.Input, compile.Artifact) {
  produce_original(f, original(f, 3, "whole:tools"), 8)
}

fn produce_original(
  f: Fixture,
  a: j.Input,
  native_number: Int,
) -> #(j.Input, compile.Artifact) {
  let assert Ok(whole.Observed(j.Unknown(None), j.CompilePending)) =
    submit(f, a)
    as "Claim handoff precedes physical preparation."
  let locations = prepared(f, a)
  let #(actual, dispatch, owner, owner_pid) = cleared(f, a, locations)
  let hash = digest(actual)
  let k = key(a, native_number)
  let assert Ok(wire.Challenge(_, _, nonce, _)) =
    routed(f, ref(a), wire.ChallengeRequest(k, hash))
    as "Actual original native challenge."
  let assert Ok(_) =
    routed(f, ref(a), wire.Submit(k, hash, actual, nonce, 20_000))
    as "Actual fixed compiler launch follows committed association."
  let completed =
    poll.until(within: 20_000, every: 20, attempt: fn() {
      case j.inspect_compile(f.resources, a) {
        Ok(j.CompileRetained(retained, _)) -> poll.Done(retained)
        Ok(j.CompilePending) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
  let assert poll.Answered(retained) = completed
    as "Whole continuation commits the actual compiler result."
  let result = completion.compiled(j.retained_compile_value(retained))
  let assert compile.Compiled(
    Ok(compile.ExecutorArtifact(manifest_hash: hash, ..)),
    _,
  ) = result
    as "Actual native compiler succeeded and produced an ExecutorArtifact."
  let root = resources.compile_fields(locations).1
  assert build.fingerprint_directory(root <> "/ebin") == Ok(hash)
  let assert Some(completion.NativeAssociation(_, _, terminal)) =
    completion.native_association(j.retained_compile_value(retained))
    as "Exact real terminal association."
  let assert Ok(dispatch.Completed(exit)) = native.decode_terminal(terminal)
    as "Real helper terminal."
  dispatch.settle(dispatch.Completed(exit))
  stop_broker(owner, owner_pid)

  let assert Ok(artifact) = result.result as "Actual retained artifact."
  #(a, artifact)
}

fn launch_original(
  f: Fixture,
  producer: j.Input,
  artifact: compile.Artifact,
  token: BitArray,
  number: Int,
) -> j.Input {
  let assert Ok(decoded) =
    input.launch_input(
      f.enrolled,
      producer.key,
      artifact,
      [],
      workspace.root(),
      base(f.path),
      string.lowercase(bit_array.base16_encode(j.digest(token))),
    )
    as "Original token commitment."
  let bytes = input.encode_launch(decoded)
  let #(scope, op, _) = command.coordinates(producer.key)
  let managed =
    phase.for_managed_execution(
      command.parent(producer.key),
      budget: budget.Budget(1, poll.monotonic().now() + 30_000),
    )
  let assert Ok(step) = workspace.step(phase.step_id(phase.run_phase(managed)))
    as "Physical Launch phase."
  let assert Ok(key) =
    command.service_key(
      command.parent(producer.key),
      command.LaunchService,
      scope,
      op,
      step,
      id(number),
      string.lowercase(bit_array.base16_encode(j.digest(bytes))),
      string.repeat("b", 64),
      string.repeat("c", 64),
    )
    as "Whole original Launch identity."
  j.Input(key, bytes)
}

fn launch_ask(
  owner: launch.Service,
  operation: launch.Operation,
) -> Result(launch.Reply, launch.Error) {
  let reply = process.new_subject()
  launch.send_operation(
    owner,
    launch.Caller(wire.Owner, "owner", "linux", 1, core_scope()),
    operation,
    reply,
  )
  process.receive(reply, 5000) |> result.unwrap(Error(launch.Uncertain))
}

fn place(
  owner: launch.Service,
  original: j.Input,
  token: BitArray,
) -> Result(launch.Reply, launch.Error) {
  let assert Ok(launch.Challenge(_, nonce, _)) =
    launch_ask(owner, launch.ChallengeRequest(original.key))
    as "Original Launch challenge."
  launch_ask(owner, launch.PlaceToken(original, nonce, 30_000, token))
}

fn launch_prepared(f: Fixture, original: j.Input) -> resources.LaunchResources {
  let observed =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case j.inspect(f.resources, original) {
        Ok(j.Prepared(resources.LaunchReady(ready))) -> poll.Done(ready)
        Ok(_) | Error(j.Missing) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
  let assert poll.Answered(ready) = observed
    as "Original listener and token precede Ready."
  ready
}

pub fn launch_token_producer_and_original_refusal_custody_test() {
  fixture(fn(f) {
    let #(producer, artifact) = produce(f)
    assert simplifile.create_directory_all(channel(f.path)) == Ok(Nil)
    let assert Ok(config) = launch.configure(f.resources, f.service, 1)
      as "Exact Launch assembly."
    let assert Ok(owner) = launch.start(config) as "Original Launch owner."
    let token = <<0:size(256)>>
    let original = launch_original(f, producer, artifact, token, 7)
    let assert Ok(paths) = enrollment.launch_paths(f.enrolled, original.key)
      as "Canonical channel paths."
    assert place(owner, original, <<1:size(256)>>) == Error(launch.Invalid)
    assert place(owner, original, <<0:size(248)>>) == Error(launch.Invalid)
    assert j.inspect(f.resources, original) == Error(j.Missing)
    assert simplifile.is_directory(paths.0) == Ok(False)
    let assert Ok(launch.Observed(j.Unknown(None), j.LaunchPending)) =
      place(owner, original, token)
      as "Actor Claim custody precedes effects."
    let ready = launch_prepared(f, original)
    assert resources.launch_paths(ready) == paths
    assert simplifile.read_bits(paths.2) == Ok(token)
    let assert Ok(launch.Observed(_, j.LaunchPending)) =
      place(owner, original, token)
      as "Duplicate placement is historical."
    assert simplifile.read_bits(paths.2) == Ok(token)
    let events = process.new_subject()
    let host = run_channel.host_endpoint(process.self(), events)
    let handoff = process.new_subject()
    let assert Ok(launch.Installed(deadline)) =
      launch.install_host(owner, original.key, host, handoff)
      as "Receipt carries only the original immutable deadline."
    assert deadline > poll.monotonic().now()
    assert launch.install_host(owner, original.key, host, handoff)
      == Error(launch.Invalid)
    assert process.receive(handoff, 0) == Error(Nil)
    let assert Ok(launch.Observed(_, j.LaunchRetained(retained, _))) =
      launch_ask(
        owner,
        launch.RefuseBeforeNative(original, "definite owner clearance refusal"),
      )
      as "Refusal atomically excludes every native association."
    assert launch_completion.observation(j.retained_launch_value(retained))
      == launch_completion.RefusedBeforeNative(
        "definite owner clearance refusal",
      )
    let gone =
      poll.until(within: 5000, every: 10, attempt: fn() {
        case simplifile.is_directory(paths.0) {
          Ok(False) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
    assert gone == poll.Answered(Nil)
    let assert Ok(launch.Observed(_, j.LaunchRetained(_, _))) =
      launch_ask(owner, launch.Query(original.key))
      as "Query retains history after physical cleanup."
    assert launch.install_host(owner, original.key, host, handoff)
      == Error(launch.Invalid)
    let _ = launch.close(owner)
    assert simplifile.delete(channel(f.path)) == Ok(Nil)
  })
}

pub fn mutated_producer_artifact_refuses_before_claim_token_or_listener_test() {
  fixture(fn(f) {
    let #(producer, artifact) = produce(f)
    assert simplifile.create_directory_all(channel(f.path)) == Ok(Nil)
    let assert Ok(config) = launch.configure(f.resources, f.service, 1)
      as "Exact Launch assembly."
    let assert Ok(owner) = launch.start(config) as "Original Launch owner."
    let token = <<0:size(256)>>
    let original = launch_original(f, producer, artifact, token, 7)
    let assert Ok(root) = enrollment.compile_path(f.enrolled, producer.key)
      as "Original producer allocation."
    assert simplifile.write_bits(root <> "/ebin/mutated.beam", <<1, 2, 3>>)
      == Ok(Nil)
    assert place(owner, original, token) == Error(launch.Invalid)
    assert j.inspect(f.resources, original) == Error(j.Missing)
    let assert Ok(paths) = enrollment.launch_paths(f.enrolled, original.key)
      as "Original channel allocation."
    assert simplifile.is_directory(paths.0) == Ok(False)
    assert simplifile.is_file(paths.2) == Ok(False)
    assert j.inspect_native(f.resources, original) == Error(j.Missing)
    let _ = launch.close(owner)
    assert simplifile.delete(channel(f.path)) == Ok(Nil)
  })
}

pub fn lost_admission_reply_and_cancel_keep_original_listener_identity_test() {
  fixture(fn(f) {
    let #(producer, artifact) = produce(f)
    assert simplifile.create_directory_all(channel(f.path)) == Ok(Nil)
    let assert Ok(config) = launch.configure(f.resources, f.service, 1)
      as "Exact Launch assembly."
    let assert Ok(owner) = launch.start(config) as "Original Launch owner."
    let token = <<0:size(256)>>
    let original = launch_original(f, producer, artifact, token, 7)
    let assert Ok(launch.Challenge(_, nonce, _)) =
      launch_ask(owner, launch.ChallengeRequest(original.key))
      as "Original single-use challenge."
    let lost = process.new_subject()
    launch.send_operation(
      owner,
      launch.Caller(wire.Owner, "owner", "linux", 1, core_scope()),
      launch.PlaceToken(original, nonce, 30_000, token),
      lost,
    )
    let ready = launch_prepared(f, original)
    let assert Ok(launch.Observed(j.Prepared(resources.LaunchReady(same)), _)) =
      launch_ask(owner, launch.Query(original.key))
      as "Lost reply recovers historical coordinates only."
    assert same == ready
    let paths = resources.launch_paths(ready)
    assert simplifile.read_bits(paths.2) == Ok(token)
    let assert Ok(launch.Observed(_, _)) = place(owner, original, token)
      as "Duplicate returns history, without recreating allocation."
    let assert Ok(launch.Cancelled(_)) =
      launch_ask(owner, launch.Cancel(original))
      as "Cancellation commits its original fence."
    assert launch.install_host(
        owner,
        original.key,
        run_channel.host_endpoint(process.self(), process.new_subject()),
        process.new_subject(),
      )
      == Error(launch.Invalid)
    let _ = launch.close(owner)
    assert simplifile.delete(channel(f.path)) == Ok(Nil)
  })
}

fn cleared_launch(
  f: Fixture,
  original: j.Input,
  locations: resources.LaunchResources,
) -> #(wire.Prepared, dispatch.Dispatch, broker.Broker, process.Pid) {
  let assert Ok(decoded) = input.decode_launch(original.body)
    as "Original bounded source."
  let facts = input.launch_facts(decoded)
  let assert Ok(producer) = j.retained_input(f.resources, facts.compiled_by)
    as "Exact original producer."
  let assert Ok(j.CompileRetained(retained, _)) =
    j.inspect_compile(f.resources, producer)
    as "Retained successful Compile."
  let assert Ok(admitted) =
    input.admit_launch(
      original.key,
      f.enrolled,
      decoded,
      producer.key,
      completion.compiled(j.retained_compile_value(retained)),
    )
    as "Exact closed Launch admission."
  let assert Ok(expected) =
    service_command.launch(f.enrolled, admitted, locations, 10)
    as "Original finite SatelliteCommand."
  let data = offer.data(service_command.offer(expected))
  let observed = process.new_subject()
  let dispatcher =
    dispatch.Dispatcher(fn(request) {
      process.send(observed, #(request, process.self()))
      Ok(
        dispatch.Execution(
          dispatch.execution_id(19, request.seq),
          process.self(),
          fn() { Nil },
          fn(_, _) { Nil },
          fn() { Nil },
          fn() { Nil },
        ),
      )
    })
  let assert Ok(owner) =
    broker.start_dispatching(
      token.production_entropy(),
      clock.from_function(poll.monotonic().now),
      dispatcher,
    )
    as "Actual Broker performs composition, budget and token clearance."
  let managed =
    phase.for_managed_execution(
      command.parent(original.key),
      budget: budget.Budget(1, poll.monotonic().now() + 30_000),
    )
  let phase = phase.run_phase(managed)
  let assert Some(origin) = phase.command_origin(phase) |> result_unwrap
    as "Managed native child derives from actual parent."
  let spec =
    broker.CallSpec(
      phase.op_id(phase),
      phase.step_id(phase),
      data.requirements,
      data.requirements,
      [],
      broker.RefuseNarrowed,
      exec.PlatformEnforcement,
      data.argv,
      data.env,
      data.cwd,
      phase.pooled_budget(phase),
    )
  let events = process.new_subject()
  let assert Ok(_) =
    broker.clear_call_from(owner, origin, spec, events: events, waiting: 2000)
    as "Real original clearance succeeds."
  let assert Ok(#(request, owner_pid)) = process.receive(observed, 2000)
    as "Actual Dispatch carries cleared token, complete policy and original provenance."
  assert request.context.origin
    == Some(command.native_origin(launch_ref(original)))
  assert request.context.step
    == workspace.step_string(command.coordinates(original.key).2)
  let prepared =
    wire.Prepared(
      request.context.step,
      registration(),
      wire.Finite(30_000),
      request.request,
      wire.Logs,
    )
  #(prepared, request, owner, owner_pid)
}

fn launch_ref(original: j.Input) -> command.CommandRef {
  let assert Ok(ref) =
    command.command_ref(original.key, command.SatelliteCommand)
    as "Launch physical purpose."
  ref
}

fn launch_routed(
  owner: launch.Service,
  ref: command.CommandRef,
  body: wire.Body,
) -> Result(wire.Body, service.Error) {
  let assert Ok(envelope) = wire.command_envelope(ref, envelope(body))
    as "Original authenticated command frame."
  let reply = process.new_subject()
  launch.send_command_exchange(owner, envelope, reply)
  process.receive(reply, 5000) |> result.unwrap(Error(service.Uncertain))
}

pub fn real_launch_command_uses_original_claim_and_retains_actual_native_terminal_test() {
  fixture(fn(f) {
    let #(producer, artifact) = produce(f)
    assert simplifile.create_directory_all(channel(f.path)) == Ok(Nil)
    let assert Ok(config) = launch.configure(f.resources, f.service, 1)
      as "Exact Launch assembly."
    let assert Ok(owner) = launch.start(config) as "Original Launch owner."
    let token = <<0:size(256)>>
    let original = launch_original(f, producer, artifact, token, 7)
    let assert Ok(launch.Observed(_, _)) = place(owner, original, token)
      as "Original Claim admitted before effects."
    let ready = launch_prepared(f, original)
    let #(actual, dispatch, broker, broker_pid) =
      cleared_launch(f, original, ready)
    let hash = digest(actual)
    let native_key = key(original, 10)
    let ref = launch_ref(original)
    let assert Ok(wire.Challenge(_, _, nonce, _)) =
      launch_routed(owner, ref, wire.ChallengeRequest(native_key, hash))
      as "Live Claim native challenge."
    let assert Ok(_) =
      launch_routed(
        owner,
        ref,
        wire.Submit(native_key, hash, actual, nonce, 20_000),
      )
      as "Existing native engine starts exact real SatelliteCommand."
    let assert Ok(j.Associated(_, same, digest, _)) =
      j.inspect_native(f.resources, original)
      as "Association COMMIT dominates original native dispatch."
    assert same == native_key
    assert digest == hash
    assert launch_ask(
        owner,
        launch.RefuseBeforeNative(original, "false refusal after association"),
      )
      == Error(launch.Custody(j.Conflict))
    let cancel =
      poll.until(within: 2000, every: 10, attempt: fn() {
        case launch_ask(owner, launch.Cancel(original)) {
          Ok(launch.Cancelled(_)) -> poll.Done(Nil)
          Error(launch.Capacity) -> poll.Retry
          answer -> poll.Fail(answer)
        }
      })
    assert cancel == poll.Answered(Nil)
    let observed =
      poll.until(within: 6000, every: 20, attempt: fn() {
        case j.inspect_launch(f.resources, original) {
          Ok(j.LaunchRetained(retained, _)) -> poll.Done(retained)
          Ok(j.LaunchPending) -> poll.Retry
          Error(error) -> poll.Fail(error)
        }
      })
    let assert poll.Answered(retained) = observed
      as "Observation-only cleanup allowance retains actual native terminal."
    let value = j.retained_launch_value(retained)
    let assert Some(launch_completion.NativeAssociation(
      exact,
      exact_digest,
      terminal,
    )) = launch_completion.native_association(value)
      as "Exact original native readback."
    assert exact == native_key
    assert exact_digest == hash
    let assert Ok(settled) = native.decode_terminal(terminal)
      as "Actual canonical native terminal."
    dispatch.settle(settled)
    stop_broker(broker, broker_pid)
    let _ = launch.close(owner)
    assert service.shutdown(f.service) == Ok(Nil)
    assert simplifile.delete(channel(f.path)) == Ok(Nil)
  })
}

pub fn authenticated_role_generation_and_finite_configuration_guard_test() {
  fixture(fn(f) {
    assert launch.configure(f.resources, f.service, 0)
      == Error(launch.InvalidConfiguration)
    assert launch.configure(f.resources, f.service, 5)
      == Error(launch.InvalidConfiguration)
    let assert Ok(config) = launch.configure(f.resources, f.service, 1)
      as "Finite exact local configuration."
    let assert Ok(owner) = launch.start(config) as "Original local service."
    let compiled = original(f, 3, "whole:roles")
    let #(scope, op, _) = command.coordinates(compiled.key)
    let assert Ok(step) = workspace.step("physical:run") as "Bounded step."
    let #(digest, enrollment, contract) = command.digests(compiled.key)
    let assert Ok(key) =
      command.service_key(
        command.parent(compiled.key),
        command.LaunchService,
        scope,
        op,
        step,
        id(7),
        digest,
        enrollment,
        contract,
      )
      as "Complete Launch header."
    list.each(
      [
        launch.Caller(wire.Executor, "owner", "linux", 1, core_scope()),
        launch.Caller(wire.Owner, "owner", "linux", 2, core_scope()),
        launch.Caller(wire.Owner, "foreign", "linux", 1, core_scope()),
      ],
      fn(caller) {
        let reply = process.new_subject()
        launch.send_operation(
          owner,
          caller,
          launch.ChallengeRequest(key),
          reply,
        )
        assert process.receive(reply, 1000) == Ok(Error(launch.Invalid))
      },
    )
    assert launch_ask(owner, launch.ChallengeRequest(compiled.key))
      == Error(launch.Invalid)
    let _ = launch.close(owner)
    Nil
  })
}

pub fn drained_historical_replay_releases_capacity_for_distinct_parent_phase_test() {
  fixture(fn(f) {
    let #(producer, artifact) = produce(f)
    let #(second_producer, second_artifact) =
      produce_original(f, original(f, 14, "next:tools"), 19)
    assert command.parent(producer.key) != command.parent(second_producer.key)
    assert simplifile.create_directory_all(channel(f.path)) == Ok(Nil)
    let assert Ok(config) = launch.configure(f.resources, f.service, 1)
      as "One live slot."
    let assert Ok(owner) = launch.start(config) as "Original owner."
    let token = <<0:size(256)>>
    let first = launch_original(f, producer, artifact, token, 17)
    let second = launch_original(f, second_producer, second_artifact, token, 18)
    assert command.coordinates(first.key).2 != command.coordinates(second.key).2
    let assert Ok(launch.Observed(_, _)) = place(owner, first, token)
      as "First original claim."
    let ready = launch_prepared(f, first)
    let paths = resources.launch_paths(ready)
    let assert Ok(launch.Observed(_, j.LaunchRetained(_, _))) =
      launch_ask(
        owner,
        launch.RefuseBeforeNative(first, "definite original refusal"),
      )
      as "Original closed history."
    let released =
      poll.until(within: 5000, every: 10, attempt: fn() {
        case simplifile.is_directory(paths.0) {
          Ok(False) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
    assert released == poll.Answered(Nil)

    // Directory deletion precedes the release COMMIT and active-entry removal.
    // This definite-refusal fixture retains Observing and its Claim until removal.
    let removed =
      poll.until(within: 5000, every: 10, attempt: fn() {
        case
          launch_ask(
            owner,
            launch.RefuseBeforeNative(first, "definite original refusal"),
          )
        {
          Error(launch.Invalid) -> poll.Done(Nil)
          Ok(launch.Observed(_, j.LaunchRetained(_, _)))
          | Error(launch.Capacity) -> poll.Retry
          unexpected -> poll.Fail(unexpected)
        }
      })
    let assert poll.Answered(Nil) = removed
      as "Original active Claim is absent before historical replay starts."

    // Replaying the retained original must join its observation-only task.
    let replay =
      poll.until(within: 5000, every: 10, attempt: fn() {
        case place_available(owner, first, token) {
          Ok(launch.Observed(_, j.LaunchRetained(_, _))) -> poll.Done(Nil)
          Error(launch.Capacity) -> poll.Retry
          value -> poll.Fail(value)
        }
      })
    let assert poll.Answered(Nil) = replay as "Retained replay without a Claim."
    assert simplifile.is_directory(paths.0) == Ok(False)
    let next =
      poll.until(within: 5000, every: 10, attempt: fn() {
        case place_available(owner, second, token) {
          Ok(value) -> poll.Done(value)
          Error(launch.Capacity) -> poll.Retry
          error -> poll.Fail(error)
        }
      })
    let assert poll.Answered(_) = next
      as "Historical observation releases drained capacity."
    let second_ready = launch_prepared(f, second)
    let second_paths = resources.launch_paths(second_ready)
    let assert Ok(launch.Observed(_, j.LaunchRetained(_, _))) =
      launch_ask(
        owner,
        launch.RefuseBeforeNative(second, "second original refusal"),
      )
      as "Distinct original closes."
    assert poll.until(within: 5000, every: 10, attempt: fn() {
        case simplifile.is_directory(second_paths.0) {
          Ok(False) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
      == poll.Answered(Nil)
    let _ = launch.close(owner)
    assert simplifile.delete(channel(f.path)) == Ok(Nil)
  })
}

fn place_available(
  owner: launch.Service,
  original: j.Input,
  token: BitArray,
) -> Result(launch.Reply, launch.Error) {
  use reply <- result.try(launch_ask(
    owner,
    launch.ChallengeRequest(original.key),
  ))
  let assert launch.Challenge(_, nonce, _) = reply
    as "Successful challenge has its exact reply role."
  launch_ask(owner, launch.PlaceToken(original, nonce, 30_000, token))
}
