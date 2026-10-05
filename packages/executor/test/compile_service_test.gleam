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
import executor/remote/native
import executor/remote/resource_journal as j
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import telemetry/log
import tools/fs
import weft/actor
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

pub fn original_continuation_prepares_and_real_broker_compiler_products_settle_test() {
  fixture(fn(f) {
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
    assert ask(f, whole.Acknowledge(a.key, j.retained_compile_digest(retained)))
      == Ok(whole.Observed(
        j.Prepared(resources.CompileReady(locations)),
        j.CompileRetained(retained, j.ReceiptAcknowledged),
      ))
    assert submit(f, a)
      == Ok(whole.Observed(
        j.Prepared(resources.CompileReady(locations)),
        j.CompileRetained(retained, j.ReceiptAcknowledged),
      ))
  })
}

pub fn recovered_reserved_and_cancelled_original_never_create_allocation_test() {
  fixture(fn(f) {
    let a = original(f, 3, "historical")
    assert j.reserve(f.resources, a) == Ok(j.Reserved)
    assert submit(f, a) == Ok(whole.Observed(j.Reserved, j.CompilePending))
    let assert Ok(root) = enrollment.compile_path(f.enrolled, a.key)
      as "Historical exact path."
    assert simplifile.is_directory(root) == Ok(False)
    let b = original(f, 5, "cancelled")
    assert ask(f, whole.Cancel(b))
      == Ok(whole.Cancelled(j.InputFenced(j.Unknown(None))))
    assert submit(f, b) == Ok(whole.Observed(j.Unknown(None), j.CompilePending))
    let assert Ok(root) = enrollment.compile_path(f.enrolled, b.key)
      as "Fenced original path."
    assert simplifile.is_directory(root) == Ok(False)
  })
}

pub fn allocation_collision_commits_before_failure_without_deleting_existing_data_test() {
  fixture(fn(f) {
    let a = original(f, 3, "collision")
    let assert Ok(root) = enrollment.compile_path(f.enrolled, a.key)
      as "Exact original allocation."
    assert simplifile.create_directory(root) == Ok(Nil)
    assert simplifile.write(root <> "/marker", "retained") == Ok(Nil)
    let assert Ok(_) = submit(f, a) as "Original live admission."
    let outcome =
      poll.until(within: 3000, every: 10, attempt: fn() {
        case j.inspect_compile(f.resources, a) {
          Ok(j.CompileRetained(retained, _)) -> poll.Done(retained)
          Ok(j.CompilePending) -> poll.Retry
          Error(error) -> poll.Fail(error)
        }
      })
    let assert poll.Answered(retained) = outcome
      as "Only original Preparing settles Before."
    let assert compile.Compiled(Error(compile.WorkspaceSetupFailed(_)), _) =
      completion.compiled(j.retained_compile_value(retained))
      as "Collision is a known preparation failure."
    assert simplifile.read(root <> "/marker") == Ok("retained")
    assert j.inspect(f.resources, a) == Ok(j.Unknown(None))
  })
}

pub fn caller_full_scope_role_and_generation_refuse_before_journal_test() {
  fixture(fn(f) {
    let a = original(f, 3, "identity")
    list.each(
      [
        whole.Caller(..caller(), role: wire.Executor),
        whole.Caller(..caller(), owner: "foreign"),
        whole.Caller(..caller(), generation: 2),
      ],
      fn(caller) {
        let reply = process.new_subject()
        whole.send_operation(
          f.whole,
          caller,
          whole.ChallengeRequest(a.key),
          reply,
        )
        assert process.receive(reply, 1000) == Ok(Error(whole.Invalid))
      },
    )
    assert j.inspect(f.resources, a) == Error(j.Missing)
  })
}

pub fn cancelled_ready_preserves_locations_and_refuses_first_native_admission_test() {
  fixture(fn(f) {
    let a = original(f, 3, "cancel:ready")
    let assert Ok(_) = submit(f, a) as "Original live admission."
    let locations = prepared(f, a)
    let assert Ok(whole.Cancelled(j.InputFenced(j.Unknown(Some(resources.CompileReady(
      found,
    )))))) = ask(f, whole.Cancel(a))
      as "Fence retains actual Ready before native lookup."
    assert found == locations
    let #(actual, cleared, owner, owner_pid) = cleared(f, a, locations)
    let refused =
      poll.until(within: 1000, every: 5, attempt: fn() {
        case
          routed(f, ref(a), wire.ChallengeRequest(key(a, 8), digest(actual)))
        {
          Error(service.Uncertain) -> poll.Done(Nil)
          Error(service.Capacity) -> poll.Retry
          _ -> poll.Fail(Nil)
        }
      })
    assert refused == poll.Answered(Nil)
    assert journal.payloads(f.journal, key(a, 8), digest(actual)) == Ok([])
    assert j.inspect_compile(f.resources, a) == Ok(j.CompilePending)
    cleared.settle(
      dispatch.Failed(exec.ExecutionLost(exec.RemoteOutcomeUncertain)),
    )
    stop_broker(owner, owner_pid)
  })
}

pub fn lost_ready_reply_is_historical_and_does_not_reprepare_test() {
  fixture(fn(f) {
    let a = original(f, 3, "lost:ready")
    let assert Ok(whole.Challenge(_, nonce, _)) =
      ask(f, whole.ChallengeRequest(a.key))
      as "Original ticket."
    let ignored = process.new_subject()
    whole.send_operation(
      f.whole,
      caller(),
      whole.Submit(a, nonce, 30_000),
      ignored,
    )
    let locations = prepared(f, a)
    let root = resources.compile_fields(locations).1
    assert simplifile.write(root <> "/marker", "first") == Ok(Nil)
    assert ask(f, whole.Query(a.key))
      == Ok(whole.Observed(
        j.Prepared(resources.CompileReady(locations)),
        j.CompilePending,
      ))
    assert ask(f, whole.Submit(a, nonce, 60_000))
      == Ok(whole.Observed(
        j.Prepared(resources.CompileReady(locations)),
        j.CompilePending,
      ))
    assert simplifile.read(root <> "/marker") == Ok("first")
    let assert Ok(_) = ask(f, whole.Cancel(a))
      as "Explicit fence closes this unassociated continuation."
    Nil
  })
}

pub fn malformed_input_and_effective_contract_refuse_before_resource_admission_test() {
  fixture(fn(f) {
    let a = original(f, 3, "source")
    let assert Ok(whole.Challenge(_, nonce, _)) =
      ask(f, whole.ChallengeRequest(a.key))
      as "Original ticket."
    assert ask(
        f,
        whole.Submit(j.Input(a.key, <<"malformed":utf8>>), nonce, 30_000),
      )
      == Error(whole.Invalid)
    assert j.inspect(f.resources, a) == Error(j.Missing)
    let facts = input.compile_facts(input_decode(a))
    let assert Ok(bad) =
      input.compile_input(
        f.enrolled,
        input.WorkspaceProgram,
        "import cap/strand\npub fn main() { Nil }",
        [],
        facts.dependencies,
        facts.policy_seed,
        facts.build_timeout_ms,
      )
      as "Shape-valid source exceeds effective host policy."
    let body = input.encode_compile(bad)
    let old = a.key
    let #(scope, op, step) = command.coordinates(old)
    let assert Ok(key) =
      command.service_key(
        command.parent(old),
        command.CompileService,
        scope,
        op,
        step,
        command.request_id(old),
        string.lowercase(bit_array.base16_encode(j.digest(body))),
        command.digests(old).1,
        command.digests(old).2,
      )
      as "Exact hostile source digest."
    let bad = j.Input(key, body)
    let assert Ok(whole.Challenge(_, nonce, _)) =
      ask(f, whole.ChallengeRequest(key))
      as "Body-specific ticket."
    assert ask(f, whole.Submit(bad, nonce, 30_000)) == Error(whole.Invalid)
    assert j.inspect(f.resources, bad) == Error(j.Missing)
    let assert Ok(_) = ask(f, whole.ChallengeRequest(a.key))
      as "Known source refusal restores only unused admission capacity."
    Nil
  })
}

fn input_decode(original: j.Input) -> input.CompileInput {
  let assert Ok(value) = input.decode_compile(original.body)
    as "Canonical fixture input."
  value
}

pub fn dead_exact_native_endpoint_fences_new_admission_test() {
  fixture(fn(f) {
    let a = original(f, 3, "dead:native")
    let monitor = process.monitor(service.pid(f.service))
    assert service.shutdown(f.service) == Ok(Nil)
    let assert Ok(_) =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive(1000)
      as "Exact native endpoint died."
    let observed =
      poll.until(within: 1000, every: 5, attempt: fn() {
        case ask(f, whole.ChallengeRequest(a.key)) {
          Error(whole.Closing) -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
    assert observed == poll.Answered(Nil)
    assert j.inspect(f.resources, a) == Error(j.Missing)
  })
}

type ClockRequest {
  ReadClock(reply: process.Subject(Int))
  SetClock(value: Int, reply: process.Subject(Nil))
  HoldWorker(
    reads: Int,
    exempt: List(process.Pid),
    seen: process.Subject(process.Pid),
    reply: process.Subject(Nil),
  )
  ResumeClock(reply: process.Subject(Nil))
  StopClock
}

type ClockHold {
  RunningClock
  HoldAfter(
    reads: Int,
    exempt: List(process.Pid),
    seen: process.Subject(process.Pid),
  )
  HeldClock(reply: process.Subject(Int))
}

fn clocked(run: fn(Fixture, process.Subject(ClockRequest)) -> Nil) -> Nil {
  let assert Ok(clock) =
    actor.new(#(100_000, RunningClock))
    |> actor.on_message(fn(state, message) {
      let #(now, held) = state
      case message {
        ReadClock(reply) -> clock_read(now, held, reply)
        SetClock(value, reply) -> {
          process.send(reply, Nil)
          actor.continue(#(value, held))
        }
        HoldWorker(reads, exempt, seen, reply) -> {
          process.send(reply, Nil)
          actor.continue(#(now, HoldAfter(reads, exempt, seen)))
        }
        ResumeClock(reply) -> {
          case held {
            HeldClock(waiter) -> process.send(waiter, now)
            RunningClock | HoldAfter(_, _, _) -> Nil
          }
          process.send(reply, Nil)
          actor.continue(#(now, RunningClock))
        }
        StopClock -> actor.stop()
      }
    })
    |> actor.start
    as "Trusted monotonic fixture clock."
  clock_fixture(fn() { process.call(clock.data, 1000, ReadClock) }, fn(f) {
    run(f, clock.data)
  })
  let monitor = process.monitor(clock.pid)
  process.send(clock.data, StopClock)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "Clock peer joined."
  Nil
}

fn clock_read(
  now: Int,
  held: ClockHold,
  reply: process.Subject(Int),
) -> actor.Next(#(Int, ClockHold), ClockRequest) {
  let assert Ok(caller) = process.subject_owner(reply)
    as "Typed clock ask retains its caller."
  case held {
    RunningClock | HeldClock(_) -> {
      process.send(reply, now)
      actor.continue(#(now, held))
    }
    HoldAfter(reads, exempt, seen) ->
      case list.contains(exempt, caller), reads {
        False, 1 -> {
          process.send(seen, caller)
          actor.continue(#(now, HeldClock(reply)))
        }
        False, _ -> {
          process.send(reply, now)
          actor.continue(#(now, HoldAfter(reads - 1, exempt, seen)))
        }
        True, _ -> {
          process.send(reply, now)
          actor.continue(#(now, held))
        }
      }
  }
}

pub fn ticket_expiry_and_ready_elapsed_cap_never_refresh_authority_test() {
  clocked(fn(f, clock) {
    let a = original(f, 3, "elapsed")
    let assert Ok(whole.Challenge(_, nonce, _)) =
      ask(f, whole.ChallengeRequest(a.key))
      as "Original issued ticket."
    assert process.call(clock, 1000, SetClock(101_000, _)) == Nil
    assert ask(f, whole.Submit(a, nonce, 30_000)) == Error(whole.Expired)
    assert j.inspect(f.resources, a) == Error(j.Missing)
    let assert Ok(_) = submit(f, a) as "New original finite challenge."
    let locations = prepared(f, a)
    assert process.call(clock, 1000, SetClock(131_001, _)) == Nil
    let outcome =
      poll.until(within: 1000, every: 10, attempt: fn() {
        case j.inspect(f.resources, a) {
          Ok(j.Unknown(Some(resources.CompileReady(found))))
            if found == locations
          -> poll.Done(Nil)
          _ -> poll.Retry
        }
      })
    assert outcome == poll.Answered(Nil)
    assert j.inspect_compile(f.resources, a) == Ok(j.CompilePending)
    assert ask(f, whole.ChallengeRequest(a.key)) == Error(whole.Closing)
  })
}

pub fn ambiguous_admission_commit_permanently_fences_capacity_even_without_row_test() {
  fixture(fn(f) {
    let assert Ok(db) = sqlight.open(f.path <> "/resources.sqlite")
      as "Independent real SQLite fault writer."
    assert sqlight.exec(
        "PRAGMA foreign_keys=ON; CREATE TABLE fail_parent(id INTEGER PRIMARY KEY); CREATE TABLE fail_child(id INTEGER REFERENCES fail_parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER lose_admit AFTER UPDATE ON resource_call WHEN NEW.phase=1 BEGIN INSERT INTO fail_child VALUES(1); END;",
        db,
      )
      == Ok(Nil)
    assert sqlight.close(db) == Ok(Nil)
    let a = original(f, 3, "ambiguous")
    assert submit(f, a) == Error(whole.Custody(j.Uncertain))
    let poisoned = j.inspect(f.resources, a)
    assert poisoned == Error(j.Closed) || poisoned == Error(j.Uncertain)
    let assert Ok(db) = sqlight.open(f.path <> "/resources.sqlite")
      as "Independent committed-row reader."
    assert sqlight.query(
        "SELECT count(*) FROM resource_call",
        db,
        [],
        decode.field(0, decode.int, decode.success),
      )
      == Ok([0])
    assert sqlight.close(db) == Ok(Nil)
    let b = original(f, 5, "later")
    assert ask(f, whole.ChallengeRequest(b.key)) == Error(whole.Closing)
    let assert Ok(root) = enrollment.compile_path(f.enrolled, a.key)
      as "Original exact path."
    assert simplifile.is_directory(root) == Ok(False)
  })
}

pub fn stopped_original_claim_handoff_cannot_create_directory_before_fence_reply_test() {
  clocked(fn(f, clock) {
    let seen = process.new_subject()
    assert process.call(clock, 1000, HoldWorker(
        2,
        [process.self(), whole.pid(f.whole), service.pid(f.service)],
        seen,
        _,
      ))
      == Nil
    let a = original(f, 3, "handoff")
    let assert Ok(whole.Challenge(_, nonce, _)) =
      ask(f, whole.ChallengeRequest(a.key))
      as "Original complete ticket."
    let original_reply = process.new_subject()
    whole.send_operation(
      f.whole,
      caller(),
      whole.Submit(a, nonce, 30_000),
      original_reply,
    )
    let assert Ok(worker) = process.receive(seen, 1000)
      as "Managed original worker paused after fresh Claim COMMIT."
    assert j.inspect(f.resources, a) == Ok(j.Unknown(None))
    let assert Ok(db) = sqlight.open(f.path <> "/resources.sqlite")
      as "Independent real fence barrier."
    assert sqlight.exec("BEGIN IMMEDIATE", db) == Ok(Nil)
    let cancelled = process.new_subject()
    whole.send_operation(f.whole, caller(), whole.Cancel(a), cancelled)

    // Query enters the same actor after Cancel, proving the Stopping transition
    // without a timer. Its metadata task is refused while the real fence is held.
    assert ask(f, whole.Query(a.key)) == Error(whole.Capacity)
    assert process.call(clock, 1000, ResumeClock) == Nil
    let assert Ok(root) = enrollment.compile_path(f.enrolled, a.key)
      as "Exact original allocation."
    let observed =
      poll.until(within: 1000, every: 5, attempt: fn() {
        case simplifile.is_directory(root), process.is_alive(worker) {
          Ok(True), _ -> poll.Done(True)
          Ok(False), False -> poll.Done(False)
          _, _ -> poll.Retry
        }
      })
    assert sqlight.exec("ROLLBACK", db) == Ok(Nil)
    assert sqlight.close(db) == Ok(Nil)
    assert observed == poll.Answered(False)
    let assert Ok(Ok(whole.Cancelled(j.InputFenced(j.Unknown(None))))) =
      process.receive(cancelled, 2000)
      as "Actual committed input fence after original handoff refusal."
    assert process.receive(original_reply, 1000) == Ok(Error(whole.Closing))
    assert simplifile.is_directory(root) == Ok(False)
  })
}

pub fn original_worker_death_before_claim_handoff_fences_input_and_capacity_test() {
  clocked(fn(f, clock) {
    let seen = process.new_subject()
    assert process.call(clock, 1000, HoldWorker(
        2,
        [process.self(), whole.pid(f.whole), service.pid(f.service)],
        seen,
        _,
      ))
      == Nil
    let a = original(f, 3, "worker:lost")
    let assert Ok(whole.Challenge(_, nonce, _)) =
      ask(f, whole.ChallengeRequest(a.key))
      as "Original ticket."
    let reply = process.new_subject()
    whole.send_operation(
      f.whole,
      caller(),
      whole.Submit(a, nonce, 30_000),
      reply,
    )
    let assert Ok(worker) = process.receive(seen, 1000)
      as "Original post-COMMIT worker is held before Claim handoff."
    let monitor = process.monitor(worker)
    process.kill(worker)
    let assert Ok(_) =
      process.new_selector()
      |> process.select_specific_monitor(monitor, fn(down) { down })
      |> process.selector_receive(1000)
      as "Actual managed worker death."
    assert process.receive(reply, 2000) == Ok(Error(whole.Uncertain))
    assert process.call(clock, 1000, ResumeClock) == Nil
    let b = original(f, 5, "worker:later")
    assert ask(f, whole.ChallengeRequest(b.key)) == Error(whole.Closing)
    let assert Ok(root) = enrollment.compile_path(f.enrolled, a.key)
      as "Original exact allocation."
    assert simplifile.is_directory(root) == Ok(False)
    assert j.inspect(f.resources, a) == Ok(j.Unknown(None))
  })
}

pub fn temporary_endpoint_kill_before_claim_handoff_drains_worker_and_recovers_history_only_test() {
  clocked(fn(f, clock) {
    let seen = process.new_subject()
    assert process.call(clock, 1000, HoldWorker(
        2,
        [process.self(), whole.pid(f.whole), service.pid(f.service)],
        seen,
        _,
      ))
      == Nil
    let a = original(f, 3, "endpoint:lost")
    let assert Ok(whole.Challenge(_, nonce, _)) =
      ask(f, whole.ChallengeRequest(a.key))
      as "Original ticket."
    let reply = process.new_subject()
    whole.send_operation(
      f.whole,
      caller(),
      whole.Submit(a, nonce, 30_000),
      reply,
    )
    let assert Ok(worker) = process.receive(seen, 1000)
      as "Original fresh Claim committed before actor handoff."
    let worker_monitor = process.monitor(worker)
    let endpoint_monitor = process.monitor(whole.pid(f.whole))
    process.kill(whole.pid(f.whole))
    let assert Ok(_) =
      process.new_selector()
      |> process.select_specific_monitor(endpoint_monitor, fn(down) { down })
      |> process.selector_receive(1000)
      as "Temporary endpoint died; listener must retire unresolved custody."
    let assert Ok(_) =
      process.new_selector()
      |> process.select_specific_monitor(worker_monitor, fn(down) { down })
      |> process.selector_receive(1000)
      as "Weft linked ownership drains the original worker."
    assert process.call(clock, 1000, ResumeClock) == Nil
    let assert Ok(recovered) =
      j.recover(f.path <> "/resources.sqlite", f.enrolled, limits(), f.journal)
      as "Independent endpoint reopens original evidence."
    assert j.admit_preparation(recovered, a) == Ok(j.Retained(j.Unknown(None)))
    assert j.retained_input(recovered, a.key) == Ok(a)
    assert j.inspect_compile(recovered, a) == Ok(j.CompilePending)
    let assert Ok(root) = enrollment.compile_path(f.enrolled, a.key)
      as "Original exact root."
    assert simplifile.is_directory(root) == Ok(False)
    assert j.release_endpoint(recovered) == Ok(Nil)
  })
}

pub fn bounded_header_tickets_and_foreign_key_nonce_refuse_without_reservation_test() {
  clocked(fn(f, clock) {
    let a = original(f, 3, "ticket:a")
    let b = original(f, 5, "ticket:b")
    let assert Ok(whole.Challenge(_, nonce, 1000)) =
      ask(f, whole.ChallengeRequest(a.key))
      as "Original full-key nonce."
    assert ask(f, whole.Submit(b, nonce, 30_000)) == Error(whole.Expired)
    assert j.inspect(f.resources, b) == Error(j.Missing)
    list.each(list.repeat(Nil, 31), fn(_) {
      let assert Ok(whole.Challenge(_, nonce, 1000)) =
        ask(f, whole.ChallengeRequest(a.key))
        as "Header-only ticket within finite bound."
      assert bit_array.byte_size(nonce) == 32
    })
    assert ask(f, whole.ChallengeRequest(a.key)) == Error(whole.Capacity)
    assert process.call(clock, 1000, SetClock(101_001, _)) == Nil
    let assert Ok(whole.Challenge(_, _, 1000)) =
      ask(f, whole.ChallengeRequest(a.key))
      as "Only expired header tickets release challenge capacity."
    assert j.inspect(f.resources, a) == Error(j.Missing)
  })
}

pub fn definite_metadata_missing_and_conflict_release_drained_capacity_test() {
  fixture(fn(f) {
    let retained = original(f, 3, "metadata:retained")
    assert j.reserve(f.resources, retained) == Ok(j.Reserved)
    let missing = original(f, 5, "metadata:missing")
    let conflicting = original(f, 5, "metadata:retained")

    // The same retained logical address with another original UUID is Conflict;
    // another address is Missing. Neither result hides an in-flight effect.
    list.each([#(missing, j.Missing), #(conflicting, j.Conflict)], fn(item) {
      let #(original, refused) = item
      assert ask(f, whole.Query(original.key)) == Error(whole.Custody(refused))
      let drained =
        poll.until(within: 1000, every: 5, attempt: fn() {
          case ask(f, whole.Query(retained.key)) {
            Ok(whole.Observed(j.Reserved, j.CompilePending)) -> poll.Done(Nil)
            Error(whole.Capacity) -> poll.Retry
            other -> poll.Fail(other)
          }
        })
      assert drained == poll.Answered(Nil)
      let assert Ok(whole.Challenge(found, _, 1000)) =
        ask(f, whole.ChallengeRequest(original.key))
        as "Definite metadata refusal preserves fresh admission."
      assert found == original.key
    })
  })
}

pub fn capacity_refused_cancel_preserves_original_held_claim_and_live_route_test() {
  clocked(fn(f, clock) {
    let seen = process.new_subject()
    assert process.call(clock, 1000, HoldWorker(
        4,
        [process.self(), whole.pid(f.whole), service.pid(f.service)],
        seen,
        _,
      ))
      == Nil
    let a = original(f, 3, "cancel:capacity")
    let assert Ok(whole.Challenge(_, nonce, _)) =
      ask(f, whole.ChallengeRequest(a.key))
      as "Original ticket."
    let original_reply = process.new_subject()
    whole.send_operation(
      f.whole,
      caller(),
      whole.Submit(a, nonce, 30_000),
      original_reply,
    )
    let assert Ok(worker) = process.receive(seen, 1000)
      as "Original worker is held after the actor accepted its Claim handoff."
    assert process.is_alive(worker)
    assert j.inspect(f.resources, a) == Ok(j.Unknown(None))
    let assert Ok(db) = sqlight.open(f.path <> "/resources.sqlite")
      as "Real writer barrier occupies a metadata task."
    assert sqlight.exec("BEGIN IMMEDIATE", db) == Ok(Nil)
    let metadata_reply = process.new_subject()
    whole.send_operation(f.whole, caller(), whole.Query(a.key), metadata_reply)

    // Mailbox order proves the Query occupies the one metadata slot before
    // Cancel. Refusal cannot orphan the original phase without a fence task.
    assert ask(f, whole.Query(a.key)) == Error(whole.Capacity)
    assert ask(f, whole.Cancel(a)) == Error(whole.Capacity)
    assert sqlight.exec("ROLLBACK", db) == Ok(Nil)
    assert sqlight.close(db) == Ok(Nil)
    assert process.receive(metadata_reply, 2000)
      == Ok(Ok(whole.Observed(j.Unknown(None), j.CompilePending)))
    assert process.call(clock, 1000, ResumeClock) == Nil
    let locations = prepared(f, a)
    let #(actual, cleared, owner, owner_pid) = cleared(f, a, locations)
    let challenge =
      poll.until(within: 1000, every: 5, attempt: fn() {
        case
          routed(f, ref(a), wire.ChallengeRequest(key(a, 8), digest(actual)))
        {
          Ok(wire.Challenge(_, _, _, _)) -> poll.Done(Nil)
          Error(service.Capacity) -> poll.Retry
          other -> poll.Fail(other)
        }
      })
    assert challenge == poll.Answered(Nil)
    let assert Ok(_) = ask(f, whole.Cancel(a))
      as "A later admitted Cancel commits the actual input fence."
    cleared.settle(
      dispatch.Failed(exec.ExecutionLost(exec.RemoteOutcomeUncertain)),
    )
    stop_broker(owner, owner_pid)
    Nil
  })
}

pub fn native_endpoint_accessor_preserves_exact_identity_across_same_scope_test() {
  fixture(fn(first) {
    fixture(fn(second) {
      assert whole.scope(first.whole) == whole.scope(second.whole)
      assert first.service != second.service
      assert whole.native_service(first.whole) == first.service
      assert whole.native_service(first.whole) != second.service
      assert whole.native_service(second.whole) == second.service
      assert whole.enrolled(first.whole) == first.enrolled
      assert whole.enrolled(second.whole) == second.enrolled
      assert whole.enrolled(first.whole) != second.enrolled
    })
  })
}
