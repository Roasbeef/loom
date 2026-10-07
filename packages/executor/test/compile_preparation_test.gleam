//// Whole Compile actor controls own real journals, source preparation and helper.
//// The actor-local fixture preserves real Broker clearance and a managed parent;
//// it does not claim ordinary-tool or registered separate-host acceptance.

import broker/budget
import broker/enrollment
import broker/exec
import broker/executor as local
import broker/policy
import codemode/compile
import codemode/identity as phase
import codemode/service_input as input
import codemode/vet/policy as vet_policy
import core/command
import core/ids
import core/remote_tool
import core/workspace
import envoy
import executor
import executor/remote/admission
import executor/remote/compile_preparation as preparation
import executor/remote/compile_service as whole
import executor/remote/identity
import executor/remote/journal
import executor/remote/resource_journal as j
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import simplifile
import sqlight
import telemetry/log
import tools/fs
import weft
import weft/poll

type Fixture {
  Fixture(
    path: String,
    enrolled: enrollment.SessionEnrollment,
    resources: j.Journal,
    journal: journal.Journal,
    service: service.Service,
    whole: whole.Service,
    checkpoints: process.Subject(preparation.Checkpoint),
    config: whole.Config,
  )
}

fn native_executor(
  path: String,
  before_checkout: fn() -> Nil,
) -> local.Executor {
  let assert Ok(here) = simplifile.current_directory() as "Helper fixture root."
  let helper = here <> "/../sandbox/loom-exec"
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

// OTP 29 on Linux allocates a 64 MiB JIT memfd before compiling source.
// RLIMIT_FSIZE covers that memory-backed file as well as disk output.
fn base(path: String) -> policy.SandboxPolicy {
  policy.SandboxPolicy(
    ..executor.base_policy(path),
    writable_roots: [path <> "/work", path <> "/build", channel(path)],
    protected: [],
    limits: policy.Limits(30, 30, 536_870_912, 64, 67_108_864, 262_144),
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

fn registration() -> identity.Digest {
  let assert Ok(bytes) = bit_array.base16_decode(string.repeat("b", 64))
    as "Exact digest spelling."
  let assert Ok(hash) = identity.digest(bytes) as "Administrative digest."
  hash
}

fn limits() -> j.Limits {
  let assert Ok(limits) = j.limits(16, 30_000_000)
    as "Explicit fixture capacity."
  limits
}

// This deliberately empty immutable seed makes actual preparation fail after
// exclusive mkdir and source writes. Positive compiler controls use the normal
// production seed separately after the coordinated real-helper slot is released.
fn seed_root() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "Private executor root."
  let path = here <> "/build/original-empty-seed"
  assert simplifile.create_directory_all(path) == Ok(Nil)
  path
}

fn fixture(boundaries: List(preparation.Boundary)) -> Fixture {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let assert Ok(here) = simplifile.current_directory()
    as "Private test directory."
  let path =
    here
    <> "/build/original-prep-"
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
    as "Real original resource writer."
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
      poll.monotonic().now,
    ))
    as "Original actual native service."
  let assert Ok(contract) =
    input.trusted_contract(
      enrolled,
      input.WorkspaceProgram,
      vet_policy.workspace_effects(),
      [],
    )
    as "Trusted effective policy."
  let assert Ok(config) = whole.configure(resources, server, contract, 1)
    as "Pinned original assembly."
  let checkpoints = process.new_subject()
  let probe = preparation.probe(checkpoints, boundaries)
  let assert Ok(whole) = whole.start_original_observed(config, Some(probe))
    as "Original permanent Compile actor."
  // The test owns the actual permanent host relationship, independent of finite asks.
  process.unlink(whole.pid(whole))
  Fixture(path, enrolled, resources, book, server, whole, checkpoints, config)
}

fn cleanup(f: Fixture) -> Nil {
  case process.is_alive(whole.pid(f.whole)) {
    True -> discard(whole.pid(f.whole))
    False -> Nil
  }
  case process.is_alive(service.pid(f.service)) {
    True -> {
      assert service.shutdown(f.service) == Ok(Nil)
    }
    False -> Nil
  }
  assert j.release_endpoint(f.resources) == Ok(Nil)
  assert journal.release(f.journal) == Ok(Nil)
  assert simplifile.delete(f.path) == Ok(Nil)
}

fn discard(pid: process.Pid) -> Nil {
  let watch = process.monitor(pid)
  process.unlink(pid)
  process.send_exit(pid)
  joined(watch)
}

fn joined(watch: process.Monitor) -> Nil {
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(2000)
    as "Actual original actor Normal, independently of an ACK."
  Nil
}

fn checkpoint(f: Fixture) -> preparation.Checkpoint {
  let assert Ok(value) = process.receive(f.checkpoints, 3000)
    as "The original actor reached the named installed-state boundary."
  value
}

fn root(f: Fixture, original: j.Input) -> String {
  let assert Ok(path) = enrollment.compile_path(f.enrolled, original.key)
    as "Exact immutable original allocation."
  path
}

fn failed(f: Fixture, original: j.Input) -> Nil {
  let assert poll.Answered(_) =
    poll.until(3000, 10, fn() {
      case j.inspect_compile(f.resources, original) {
        Ok(j.CompileRetained(value, _)) -> poll.Done(value)
        Ok(j.CompilePending) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "The actual known Before-native preparation result committed."
  Nil
}

fn close(f: Fixture) -> whole.CompileResourcesProof {
  let assert Ok(continuations) = whole.close_original(f.whole)
    as "Only original aggregate outcomes and joins quiesce this actor."
  assert whole.validate_close_original(f.whole, continuations) |> result.is_ok
  assert process.is_alive(whole.pid(f.whole))
  let native_watch = process.monitor(service.pid(f.service))
  let assert Ok(native) = service.shutdown_original(f.service)
    as "Actual original pool/native closure precedes deletion."
  joined(native_watch)
  let watch = process.monitor(whole.pid(f.whole))
  let assert Ok(proof) = whole.close_preparations(f.whole, native)
    as "Actual physical deletion, release COMMIT/readback and original owner joins."
  joined(watch)
  assert whole.validate_preparations(f.whole, proof) |> result.is_ok
  proof
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

pub fn original_partial_layout_retains_then_native_safe_release_commits_test() {
  let f = fixture([])
  let original = original(f, 3, "partial")
  assert submit(f, original) |> result.is_ok
  failed(f, original)
  assert simplifile.is_directory(root(f, original)) == Ok(True)
  assert j.inspect(f.resources, original) == Ok(j.Unknown(None))
  let _ = close(f)
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  assert j.inspect(f.resources, original) == Ok(j.Released(None))
  cleanup(f)
}

pub fn preexisting_allocation_canary_is_never_owned_or_deleted_test() {
  let f = fixture([])
  let original = original(f, 3, "canary")
  let root = root(f, original)
  assert simplifile.create_directory(root) == Ok(Nil)
  assert simplifile.write(root <> "/canary", "original bytes") == Ok(Nil)
  assert submit(f, original) |> result.is_ok
  failed(f, original)
  let _ = close(f)
  assert simplifile.read(root <> "/canary") == Ok("original bytes")
  assert j.inspect(f.resources, original) == Ok(j.Released(None))
  cleanup(f)
}

pub fn original_parent_death_before_begin_ack_never_acquires_test() {
  let f = fixture([preparation.BeginPermit])
  let original = original(f, 3, "pre-begin")
  assert submit(f, original) |> result.is_ok
  let assert preparation.BeforeBeginPermit(owner, permit) = checkpoint(f)
    as "Original owner is parked before Begin authority."
  let down = process.monitor(owner)
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  discard(whole.pid(f.whole))
  joined(down)
  process.send(permit, Nil)
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  assert j.inspect(f.resources, original) == Ok(j.Unknown(None))
  cleanup(f)
}

pub fn acquired_directory_survives_parent_death_without_release_authority_test() {
  let f = fixture([preparation.DirectoryAcquired])
  let original = original(f, 3, "post-mkdir")
  assert submit(f, original) |> result.is_ok
  let assert preparation.AcquiredDirectory(owner, permit) = checkpoint(f)
    as "Actual mkdir ownership was installed before layout."
  let down = process.monitor(owner)
  let root = root(f, original)
  assert simplifile.is_directory(root) == Ok(True)
  assert simplifile.is_directory(root <> "/src") == Ok(False)
  discard(whole.pid(f.whole))
  joined(down)
  process.send(permit, Nil)
  assert simplifile.is_directory(root) == Ok(True)
  assert j.inspect(f.resources, original) == Ok(j.Unknown(None))
  cleanup(f)
}

pub fn original_aggregate_parent_death_before_work_permit_has_no_sql_effect_test() {
  let f = fixture([preparation.RunPermit])
  let original = original(f, 3, "pre-work")
  let reply = process.new_subject()
  let assert Ok(whole.Challenge(_, nonce, _)) =
    ask(f, whole.ChallengeRequest(original.key))
    as "Original challenge."
  whole.send_operation(
    f.whole,
    caller(),
    whole.Submit(original, nonce, 30_000),
    reply,
  )
  let assert preparation.BeforeRunPermit(preparation.ActiveRun, scope, permit) =
    checkpoint(f)
    as "Actual aggregate monitor/state precede permission."
  let down = process.monitor(scope)
  discard(whole.pid(f.whole))
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(down, fn(down) { down })
    |> process.selector_receive(2000)
    as "Actual aggregate parent-loss cancellation finished."
  process.send(permit, Nil)
  assert j.inspect(f.resources, original) == Error(j.Missing)
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  cleanup(f)
}

pub fn abnormal_original_aggregate_fences_service_without_killing_it_test() {
  let f = fixture([preparation.RunPermit])
  let original = original(f, 3, "scope-loss")
  let reply = process.new_subject()
  let assert Ok(whole.Challenge(_, nonce, _)) =
    ask(f, whole.ChallengeRequest(original.key))
    as "Original challenge."
  whole.send_operation(
    f.whole,
    caller(),
    whole.Submit(original, nonce, 30_000),
    reply,
  )
  let assert preparation.BeforeRunPermit(preparation.ActiveRun, scope, permit) =
    checkpoint(f)
    as "Installed original aggregate is physically held before work."
  let down = process.monitor(scope)
  process.kill(scope)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(down, fn(down) { down })
    |> process.selector_receive(1000)
    as "The actual original aggregate failed abnormally."
  let assert Ok(Error(whole.Uncertain)) = process.receive(reply, 2000)
    as "Original observation becomes sticky uncertainty."
  assert process.is_alive(whole.pid(f.whole))
  process.send(permit, Nil)
  assert j.inspect(f.resources, original) == Error(j.Missing)
  cleanup(f)
}

pub fn release_ack_does_not_replace_actual_original_owner_normal_test() {
  let f = fixture([preparation.OwnerExit])
  let original = original(f, 3, "exit-held")
  assert submit(f, original) |> result.is_ok
  failed(f, original)
  let assert Ok(_) = whole.close_original(f.whole)
    as "Original finite continuations joined."
  let native_watch = process.monitor(service.pid(f.service))
  let assert Ok(native) = service.shutdown_original(f.service)
    as "Actual original native safety."
  joined(native_watch)
  let service = f.whole
  let run =
    weft.new_prepared([
      weft.managed(fn(_) { whole.close_preparations(service, native) }),
    ])
    |> weft.deadline(3000)
    |> weft.start_detached
  let assert preparation.BeforeOwnerExit(owner, permit) = checkpoint(f)
    as "Actual release ACK sent, original Normal remains physically held."
  let down = process.monitor(owner)
  assert j.inspect(f.resources, original) == Ok(j.Released(None))
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  assert weft.pull(run, 0) == weft.NotYet
  process.send(permit, Nil)
  joined(down)
  let assert weft.PulledOutcome(weft.Completed(_, proof)) = weft.pull(run, 2000)
    as "Only actual owner Normal releases the full result."
  assert whole.validate_preparations(f.whole, proof) |> result.is_ok
  assert weft.pull(run, 1000) == weft.AllDelivered
  cleanup(f)
}

pub fn historical_reservation_grants_no_preparation_owner_test() {
  let f = fixture([preparation.BeginPermit, preparation.DirectoryAcquired])
  let original = original(f, 3, "history")
  assert j.reserve(f.resources, original) == Ok(j.Reserved)
  assert submit(f, original) == Ok(whole.Observed(j.Reserved, j.CompilePending))
  let _ = close(f)
  assert process.receive(f.checkpoints, 0) == Error(Nil)
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  assert j.inspect(f.resources, original) == Ok(j.Reserved)
  cleanup(f)
}

fn admitted(f: Fixture, original: j.Input) -> input.AdmittedCompile {
  let assert Ok(decoded) = input.decode_compile(original.body)
    as "Exact original source."
  let assert Ok(contract) =
    input.trusted_contract(
      f.enrolled,
      input.WorkspaceProgram,
      vet_policy.workspace_effects(),
      [],
    )
    as "Actual immutable source contract."
  let assert Ok(admitted) = input.admit_compile(original.key, contract, decoded)
    as "Exact admitted original data."
  admitted
}

pub fn finite_prepare_observer_loss_preserves_actual_permanent_owner_test() {
  let f = fixture([])
  let original = original(f, 3, "observer-loss")
  let assert Ok(j.FreshClaim(claim)) =
    j.admit_preparation(f.resources, original)
    as "One actual atomic first admission."
  let assert Ok(owner) =
    preparation.park_observed(
      f.resources,
      f.service,
      original,
      Some(preparation.probe(f.checkpoints, [preparation.DirectoryAcquired])),
    )
    as "Test process is the actual retained permanent parent of this primitive."
  let admitted = admitted(f, original)
  let deadline = poll.monotonic().now() + 3000
  let run =
    weft.new_prepared([
      weft.managed(fn(_) {
        preparation.prepare(owner, admitted, claim, deadline)
      }),
    ])
    |> weft.deadline(3000)
    |> weft.start_detached
  let assert preparation.AcquiredDirectory(pid, permit) = checkpoint(f)
    as "Actual exclusive mkdir retained before writes."
  assert pid == preparation.pid(owner)
  weft.cancel_detached(run)
  let assert weft.PulledOutcome(weft.Abandoned(0)) = weft.pull(run, 1000)
    as "Only the finite waiting caller cancelled."
  assert weft.pull(run, 1000) == weft.AllDelivered
  assert process.is_alive(pid)
  assert simplifile.is_directory(root(f, original)) == Ok(True)
  process.send(permit, Nil)
  // Native safety, not observation loss, authorizes this exact owner's cleanup.
  let watch = process.monitor(service.pid(f.service))
  let assert Ok(native) = service.shutdown_original(f.service)
    as "Actual unused native pool closes."
  joined(watch)
  let assert Ok(proof) = preparation.release(owner, native, deadline)
    as "The original retained owner can clean after its observer died."
  assert preparation.validate_release(owner, proof) |> result.is_ok
  assert j.inspect(f.resources, original) == Ok(j.Released(None))
  cleanup(f)
}

pub fn original_release_sql_failure_cannot_be_upgraded_from_path_absence_test() {
  let f = fixture([])
  let original = original(f, 3, "release-refused")
  let assert Ok(j.FreshClaim(claim)) =
    j.admit_preparation(f.resources, original)
    as "One exact actual admission."
  let assert Ok(owner) = preparation.park(f.resources, f.service, original)
    as "Retained original primitive."
  let deadline = poll.monotonic().now() + 3000
  let assert Error(preparation.Preparation(_)) =
    preparation.prepare(owner, admitted(f, original), claim, deadline)
    as "Real deliberately empty seed fails after source writes."
  let assert Ok(db) = sqlight.open(f.path <> "/resources.sqlite")
    as "External SQL fixture mutates only the checked release RETURNING."
  assert sqlight.exec(
      "CREATE TRIGGER refuse_original_release BEFORE UPDATE OF phase ON resource_call WHEN NEW.phase=4 BEGIN SELECT RAISE(IGNORE); END",
      db,
    )
    == Ok(Nil)
  assert sqlight.close(db) == Ok(Nil)
  let watch = process.monitor(service.pid(f.service))
  let assert Ok(native) = service.shutdown_original(f.service)
    as "Actual unused original pool closes."
  joined(watch)
  let book_down = process.monitor(j.pid(f.resources))
  let assert Error(_) = preparation.release(owner, native, deadline)
    as "Failed actual SQL release cannot construct original proof."
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  // The failed legacy DAL turn stops asynchronously; consume its original DOWN
  // before inspecting closed history rather than asserting a racy call result.
  joined(book_down)
  assert j.inspect(f.resources, original) == Error(j.Closed)
  let assert Ok(readback) = sqlight.open(f.path <> "/resources.sqlite")
    as "Read durable history only after original DAL connection retired."
  let assert Ok([1]) =
    sqlight.query(
      "SELECT phase FROM resource_call WHERE input_digest=?",
      readback,
      [sqlight.blob(j.digest(original.body))],
      decode.field(0, decode.int, decode.success),
    )
    as "Ignored release SQL did not commit Released; path absence cannot upgrade phase 1."
  assert sqlight.close(readback) == Ok(Nil)
  assert process.is_alive(preparation.pid(owner))
  discard(preparation.pid(owner))
  cleanup(f)
}

pub fn actual_locked_release_retains_uncertainty_until_original_sql_result_test() {
  let f = fixture([])
  let original = original(f, 3, "release-busy")
  let assert Ok(j.FreshClaim(claim)) =
    j.admit_preparation(f.resources, original)
    as "One original admission."
  let assert Ok(owner) = preparation.park(f.resources, f.service, original)
    as "Actual original owner."
  let deadline = poll.monotonic().now() + 8000
  let assert Error(preparation.Preparation(_)) =
    preparation.prepare(owner, admitted(f, original), claim, deadline)
    as "Actual partial layout is owned."
  let watch = process.monitor(service.pid(f.service))
  let assert Ok(native) = service.shutdown_original(f.service)
    as "Actual original native safety."
  joined(watch)
  let assert Ok(lock) = sqlight.open(f.path <> "/resources.sqlite")
    as "Independent actual SQL lock."
  assert sqlight.exec("BEGIN IMMEDIATE", lock) == Ok(Nil)
  let run =
    weft.new_prepared([
      weft.managed(fn(_) { preparation.release(owner, native, deadline) }),
    ])
    |> weft.deadline(8000)
    |> weft.start_detached
  // Keep the lock held through the original DAL's real 5000-ms busy timeout.
  // Custody(Uncertain) can arise here only after the actual release SQL turn.
  let assert weft.PulledOutcome(weft.Failed(0, preparation.Custody(j.Uncertain))) =
    weft.pull(run, 6000)
    as "Exact original SQL release failed while the external lock remained held."
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  let assert Ok([1]) =
    sqlight.query(
      "SELECT phase FROM resource_call WHERE input_digest=?",
      lock,
      [sqlight.blob(j.digest(original.body))],
      decode.field(0, decode.int, decode.success),
    )
    as "Original held-lock transaction still observes phase 1."
  assert sqlight.exec("ROLLBACK", lock) == Ok(Nil)
  assert sqlight.close(lock) == Ok(Nil)
  assert weft.pull(run, 1000) == weft.AllDelivered
  assert process.is_alive(preparation.pid(owner))
  assert preparation.release(owner, native, deadline) |> result.is_error
  discard(preparation.pid(owner))
  cleanup(f)
}

pub fn foreign_original_native_proof_cannot_remove_owned_allocation_test() {
  let f = fixture([])
  let original = original(f, 3, "foreign-native")
  let assert Ok(j.FreshClaim(claim)) =
    j.admit_preparation(f.resources, original)
    as "Exact atomic first admission."
  let assert Ok(owner) = preparation.park(f.resources, f.service, original)
    as "One retained original owner."
  let deadline = poll.monotonic().now() + 3000
  let assert Error(preparation.Preparation(_)) =
    preparation.prepare(owner, admitted(f, original), claim, deadline)
    as "Actual partial source layout remains owned."
  let assert Ok(replacement) = service.start(service.configuration(f.service))
    as "Same configuration does not create the same original Service identity."
  let watch = process.monitor(service.pid(replacement))
  let assert Ok(foreign) = service.shutdown_original(replacement)
    as "This real unused native pool closes under a different Service."
  joined(watch)
  assert preparation.release(owner, foreign, deadline)
    == Error(preparation.Invalid)
  assert simplifile.is_directory(root(f, original)) == Ok(True)
  assert j.inspect(f.resources, original) == Ok(j.Unknown(None))
  discard(preparation.pid(owner))
  discard(service.pid(f.service))
  cleanup(f)
}

pub fn copied_owner_cannot_repeat_an_admitted_preparation_test() {
  let f = fixture([])
  let original = original(f, 3, "copy")
  let assert Ok(j.FreshClaim(claim)) =
    j.admit_preparation(f.resources, original)
    as "Actual original first admission."
  let assert Ok(owner) = preparation.park(f.resources, f.service, original)
    as "One original physical owner."
  let deadline = poll.monotonic().now() + 3000
  let admitted = admitted(f, original)
  let assert Error(preparation.Preparation(_)) =
    preparation.prepare(owner, admitted, claim, deadline)
    as "Real seed refusal after original acquisition."
  assert simplifile.write(root(f, original) <> "/canary", "retained") == Ok(Nil)
  assert preparation.prepare(owner, admitted, claim, deadline)
    == Error(preparation.Invalid)
  assert simplifile.read(root(f, original) <> "/canary") == Ok("retained")
  let watch = process.monitor(service.pid(f.service))
  let assert Ok(native) = service.shutdown_original(f.service)
    as "Actual original unused pool closes."
  joined(watch)
  let assert Ok(_) = preparation.release(owner, native, deadline)
    as "One exact original physical cleanup."
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  assert preparation.release(owner, native, deadline)
    == Error(preparation.Uncertain)
  cleanup(f)
}

pub fn direct_original_owner_cannot_delete_a_preexisting_canary_test() {
  let f = fixture([])
  let original = original(f, 3, "direct-canary")
  let root = root(f, original)
  assert simplifile.create_directory(root) == Ok(Nil)
  assert simplifile.write(root <> "/canary", "existing bytes") == Ok(Nil)
  let assert Ok(j.FreshClaim(claim)) =
    j.admit_preparation(f.resources, original)
    as "Actual original admission."
  let assert Ok(owner) = preparation.park(f.resources, f.service, original)
    as "Actual one-use owner."
  let deadline = poll.monotonic().now() + 3000
  let assert Error(preparation.Preparation(compile.WorkspaceSetupFailed(_))) =
    preparation.prepare(owner, admitted(f, original), claim, deadline)
    as "Exclusive mkdir refused the preexisting allocation."
  let watch = process.monitor(service.pid(f.service))
  let assert Ok(native) = service.shutdown_original(f.service)
    as "Actual original unused pool closes."
  joined(watch)
  let assert Ok(_) = preparation.release(owner, native, deadline)
    as "NoDirectory release commits without deleting the conflicting path."
  assert simplifile.read(root <> "/canary") == Ok("existing bytes")
  assert j.inspect(f.resources, original) == Ok(j.Released(None))
  cleanup(f)
}

pub fn original_native_loss_before_prepare_refuses_without_acquisition_test() {
  let f = fixture([])
  let original = original(f, 3, "native-before")
  let assert Ok(j.FreshClaim(claim)) =
    j.admit_preparation(f.resources, original)
    as "One exact admission."
  let assert Ok(owner) = preparation.park(f.resources, f.service, original)
    as "Resource-free original owner before native loss."
  let watch = process.monitor(service.pid(f.service))
  let assert Ok(native) = service.shutdown_original(f.service)
    as "Actual native closes before preparation."
  joined(watch)
  let deadline = poll.monotonic().now() + 3000
  assert preparation.prepare(owner, admitted(f, original), claim, deadline)
    == Error(preparation.Uncertain)
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  let assert Ok(_) = preparation.release(owner, native, deadline)
    as "NoDirectory can retire only under its actual original native proof."
  assert j.inspect(f.resources, original) == Ok(j.Released(None))
  cleanup(f)
}

pub fn expired_original_deadline_never_acquires_or_renews_release_test() {
  let f = fixture([])
  let original = original(f, 3, "expired")
  let assert Ok(j.FreshClaim(claim)) =
    j.admit_preparation(f.resources, original)
    as "Actual original admission."
  let assert Ok(owner) = preparation.park(f.resources, f.service, original)
    as "Original parked owner."
  let expired = poll.monotonic().now()
  assert preparation.prepare(owner, admitted(f, original), claim, expired)
    == Error(preparation.Expired)
  assert simplifile.is_directory(root(f, original)) == Ok(False)
  let watch = process.monitor(service.pid(f.service))
  let assert Ok(native) = service.shutdown_original(f.service)
    as "Actual native closes."
  joined(watch)
  assert preparation.release(owner, native, expired)
    == Error(preparation.Expired)
  assert j.inspect(f.resources, original) == Ok(j.Unknown(None))
  assert process.is_alive(preparation.pid(owner))
  discard(preparation.pid(owner))
  cleanup(f)
}

pub fn abnormal_original_owner_loss_ends_compile_fresh_custody_test() {
  let f = fixture([preparation.BeginPermit])
  let initial = original(f, 3, "owner-abnormal")
  assert submit(f, initial) |> result.is_ok
  let assert preparation.BeforeBeginPermit(owner, _) = checkpoint(f)
    as "Actual original physical owner remains resource-free before Begin."
  let compile_down = process.monitor(whole.pid(f.whole))
  let owner_down = process.monitor(owner)
  process.kill(owner)
  let assert Ok(process.ProcessDown(reason: process.Killed, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(owner_down, fn(down) { down })
    |> process.selector_receive(1000)
    as "Actual original physical owner died abnormally."
  let assert Ok(process.ProcessDown(reason: process.Abnormal(_), ..)) =
    process.new_selector()
    |> process.select_specific_monitor(compile_down, fn(down) { down })
    |> process.selector_receive(1000)
    as "The permanent Compile endpoint loses fresh custody with its real original owner."
  let other = original(f, 5, "other-after-loss")
  assert whole.close_original(f.whole) == Error(whole.Uncertain)
  assert j.inspect(f.resources, other) == Error(j.Missing)
  assert simplifile.is_directory(root(f, initial)) == Ok(False)
  assert simplifile.is_directory(root(f, other)) == Ok(False)
  cleanup(f)
}
