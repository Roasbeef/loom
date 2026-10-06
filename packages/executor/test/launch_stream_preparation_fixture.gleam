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
import executor/remote/launch_service as launch
import executor/remote/native
import executor/remote/resource_journal as j
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/crypto
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
  let _path = path
  let assert Ok(root) = envoy.get("LOOM_TEST_SCRATCH")
    as "Parent-provisioned short scratch."
  root
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
  // The durable fixture and physical paths remain available after uncertain close.
  // Historical native completion alone never authorizes their removal.
  Nil
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
  let a = original(f, 3, "whole:tools")
  let assert Ok(whole.Observed(j.Unknown(None), j.CompilePending)) =
    submit(f, a)
    as "Claim handoff precedes physical preparation."
  let locations = prepared(f, a)
  let #(actual, dispatch, owner, owner_pid) = cleared(f, a, locations)
  let hash = digest(actual)
  let k = key(a, 8)
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
  _number: Int,
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
      fresh_launch_id(),
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

/// Prepares a real compiled producer and original Launch listener for transport.
///
/// ## Examples
/// `with_prepared(fn(service, key, paths) { Nil })` retains physical custody.
pub fn with_prepared(
  run: fn(launch.Service, command.ServiceKey, #(String, String, String)) -> Nil,
) {
  fixture(fn(f) {
    let #(producer, artifact) = produce(f)
    assert simplifile.create_directory_all(channel(f.path)) == Ok(Nil)
    let assert Ok(config) = launch.configure(f.resources, f.service, 1)
      as "Concrete Launch configuration."
    let assert Ok(owner) = launch.start(config)
      as "Original active entry owner."
    let token = <<0:size(256)>>
    let original = launch_original(f, producer, artifact, token, 7)
    let assert Ok(launch.Observed(j.Unknown(None), j.LaunchPending)) =
      place(owner, original, token)
      as "Original Claim transferred."
    let ready = launch_prepared(f, original)
    run(owner, original.key, resources.launch_paths(ready))
    // Cancellation uses its own finite metadata lane. A busy original lane is
    // retried only for observation; it cannot authorize native resource cleanup.
    let observed =
      poll.until(5000, 10, fn() {
        case launch_ask(owner, launch.Query(original.key)) {
          Error(launch.Capacity) -> poll.Retry
          answer -> poll.Done(answer)
        }
      })
    let assert poll.Answered(Ok(launch.Observed(_, j.LaunchPending))) = observed
      as "Historical Query remains pending without native settlement."
    let monitor = process.monitor(launch.pid(owner))
    let closed = launch.close(owner)
    assert closed == Ok(Nil) || closed == Error(launch.Uncertain)
    let assert Ok(process.ProcessDown(_, _, process.Normal)) =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive(1000)
      as "Original local Launch owner joined despite unresolved native custody."
    Nil
  })
}

fn fresh_launch_id() -> ids.EntryId {
  let suffix =
    crypto.strong_random_bytes(6) |> bit_array.base16_encode |> string.lowercase
  let assert Ok(id) = ids.parse_entry_id("00000000-0000-7000-8000-" <> suffix)
    as "Independent fixture attempt identity."
  id
}
