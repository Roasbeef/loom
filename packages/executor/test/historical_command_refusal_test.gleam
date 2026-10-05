//// Actual TLS BEAM command refusals discharge only definite drained metadata.
//// Missing and conflicting historical originals never grant command authority.
//// `fixture` retains original enrollment; `toolchain_root` resolves fixed executables.
//// `registration` and `limits` are administrative bounds, never peer authority.
//// Fixed independent OS roles reuse both lanes and the one metadata slot before
//// a valid original operation. Real journals, helper and whole Compile are retained.

import argv
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
import core/json
import core/remote_tool
import core/workspace
import distribution_fixture as provision
import envoy
import executor
import executor/remote/admission
import executor/remote/beam_endpoint as endpoint
import executor/remote/compile_service as whole
import executor/remote/compile_wire
import executor/remote/distribution
import executor/remote/identity
import executor/remote/journal
import executor/remote/resource_journal as j
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/otp/system
import gleam/string
import gleam/time/timestamp
import simplifile
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

  // Canonical original bytes bind the complete service identity and physical step.
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

  // Whole Compile derives the same original native and resource endpoints.
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

  // Only the original fixture owner closes its actors and releases journal handles.
  run(Fixture(path, enrolled, resources, book, server, whole))
  let closed = whole.close(whole)
  assert closed == Ok(Nil) || closed == Error(whole.Uncertain)
  case process.is_alive(service.pid(server)) {
    True -> {
      assert service.shutdown(server) == Ok(Nil)
    }
    False -> Nil
  }

  // The final journal-loss control already joined the actual resource endpoint.
  let released = j.release_endpoint(resources)
  assert released == Ok(Nil) || released == Error(j.Closed)
  assert journal.release(book) == Ok(Nil)
  assert simplifile.delete(path) == Ok(Nil)
}

fn mark(root: String, name: String) -> Nil {
  assert simplifile.write(root <> "/" <> name, "ready") == Ok(Nil)
}

fn await(root: String, name: String) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(10_000, 10, fn() {
      case simplifile.is_file(root <> "/" <> name) {
        Ok(True) -> poll.Done(Nil)
        Ok(False) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "The other actual OS role reaches its finite barrier."
  Nil
}

fn metadata_drained(f: Fixture, server: endpoint.Server) -> Nil {
  // A network answer does not prove metadata drain. Stock sys readback checks
  // that the original actor consumed AllDelivered and returned its sole slot.
  let assert poll.Answered(Nil) =
    poll.until(3000, 10, fn() {
      let assert Ok(metadata) =
        decode.run(
          system.get_state(whole.pid(f.whole)),
          decode.at([5], decode.dict(decode.int, decode.dynamic)),
        )
      let assert Ok(gate) =
        decode.run(
          system.get_state(whole.pid(f.whole)),
          decode.at([8], atom.decoder()),
        )
      case
        dict.size(metadata) == 0
        && atom.to_string(gate) == "serving"
        && endpoint.inspect(server) == Ok(endpoint.Capacity(1, 4, 2))
      {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "Definite refusal restores metadata and both credit lanes after actual drain."
  Nil
}

fn inputs() -> #(String, provision.Provisioned) {
  let assert [root, ..] = argv.load().arguments as "Fixed role root."
  let assert Ok(configured) = provision.read_provisioned(root <> "/tls.term")
  #(root, configured)
}

/// Executor role owns the real journals and verifies original metadata drain.
///
/// ## Examples
/// `run_executor()` is the fixed TLS fixture entrypoint.
pub fn run_executor() {
  let #(root, configured) = inputs()
  let assert Ok(membership) = distribution.start(configured.executor_config)
  let assert Ok(owner) = distribution.peer(membership, configured.owner_name)
  fixture(fn(f) {
    let retained = original(f, 3, "history")
    let missing = original(f, 5, "missing")
    let conflicting = original(f, 5, "history")
    let valid = original(f, 6, "new-original")
    let assert Ok(_) = j.reserve(f.resources, retained)
    let assert Ok(_) = j.reserve(f.resources, valid)
    list.each([#("missing", missing), #("conflicting", conflicting)], fn(pair) {
      assert simplifile.write(
          root <> "/" <> pair.0 <> ".json",
          json.to_string(command.encode_ref(ref(pair.1))),
        )
        == Ok(Nil)
    })

    // Publish all immutable owner payloads before the final ready barrier.
    let assert Ok(bytes) = compile_wire.encode_input(f.enrolled, valid)
    assert simplifile.write_bits(root <> "/valid-input.bytes", bytes) == Ok(Nil)
    let assert Ok(preparation) = j.inspect(f.resources, valid)
    let assert Ok(completed) = j.inspect_compile(f.resources, valid)
    let assert Ok(#(expected, None)) =
      compile_wire.encode_reply(
        valid.key,
        Ok(whole.Observed(preparation, completed)),
      )
    assert simplifile.write_bits(root <> "/valid-reply.bytes", expected)
      == Ok(Nil)

    // One concrete registered row uses the production endpoint's original six credits.
    let assert Ok(row) =
      endpoint.compile_registration(owner, f.whole, None, process.self())
    let assert Ok(config) = endpoint.configure_server([row], 5000)
    let assert Ok(server) = endpoint.start(config)
    mark(root, "ready")
    list.each([1, 2, 3, 4], fn(number) {
      await(root, "refused-" <> int.to_string(number))
      metadata_drained(f, server)
      mark(root, "drained-" <> int.to_string(number))
    })

    // The valid readback and fresh header follow all four original metadata drains.
    await(root, "valid-finished")
    metadata_drained(f, server)

    // A dead actual journal is uncertainty, never definite historical absence.
    assert j.release_endpoint(f.resources) == Ok(Nil)
    assert service.command_context(f.service, f.resources, ref(valid))
      == Error(service.Uncertain)
    mark(root, "journal-uncertain")

    // Uncertainty ends this fixture without reopening or replacing any original actor.
    await(root, "owner-done")
    let down = process.monitor(endpoint.pid(server))
    endpoint.stop(server)
    let assert Ok(_) =
      process.new_selector()
      |> process.select_specific_monitor(down, fn(value) { value })
      |> process.selector_receive(3000)
      as "Actual endpoint joins; this is not native retirement evidence."
    Nil
  })
  mark(root, "executor-done")
  io.println("HISTORICAL_REFUSAL_EXECUTOR_COMPLETED")
}

/// Owner routes immutable historical originals through the actual TLS endpoint.
///
/// ## Examples
/// `run_owner()` checks both lanes and exact subsequent metadata readback.
pub fn run_owner() {
  let #(root, configured) = inputs()
  let assert Ok(membership) = distribution.start(configured.owner_config)
  let assert Ok(peer) = distribution.peer(membership, configured.executor_name)
  let config = endpoint.Config(peer, "owner", "linux", scope(), 1, 5000)
  await(root, "ready")

  // The ready marker follows complete original payload publication by the executor.
  let refs =
    list.map(["missing", "conflicting"], fn(name) {
      let assert Ok(text) = simplifile.read(root <> "/" <> name <> ".json")
      let assert Ok(value) = json.parse(text)
      let assert Ok(ref) = command.decode_ref(value)
      ref
    })
  let assert [missing, conflicting] = refs
  let assert Ok(op) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
  let assert Ok(request) = identity.request_id(ids.entry_id_to_string(id(9)))
  let key = identity.request_key(scope(), op, request)
  let assert Ok(digest) = identity.digest(<<1:size(256)>>)

  // Query uses control credits; Challenge uses data credits without granting a Claim.
  let cases = [
    #(missing, wire.Query(key, digest, 0)),
    #(conflicting, wire.Query(key, digest, 0)),
    #(missing, wire.ChallengeRequest(key, digest)),
    #(conflicting, wire.ChallengeRequest(key, digest)),
  ]
  let _ =
    list.fold(cases, 1, fn(number, pair) {
      assert endpoint.exchange_command(config, pair.0, pair.1)
        == Ok(wire.Rejected(1))
        as "Missing/conflicting original has a definite identity refusal."
      mark(root, "refused-" <> int.to_string(number))
      await(root, "drained-" <> int.to_string(number))
      number + 1
    })

  // Compare the entire successful metadata reply with the original executor bytes.
  let assert Ok(bytes) = simplifile.read_bits(root <> "/valid-input.bytes")
  let assert Ok(expected) = simplifile.read_bits(root <> "/valid-reply.bytes")
  assert endpoint.compile_exchange(config, compile_wire.Query, bytes)
    == Ok(#(expected, None))
    as "New valid original reuses the drained metadata slot and control lane."
  let assert Ok(#(challenge, None)) =
    endpoint.compile_exchange(config, compile_wire.ChallengeRequest, bytes)
    as "Fresh header admission still uses the restored data lane."
  assert challenge != expected

  // The original resource actor loss permanently fences further command routing.
  mark(root, "valid-finished")
  await(root, "journal-uncertain")
  assert endpoint.exchange_command(config, missing, wire.Query(key, digest, 0))
    == Ok(wire.Rejected(2))
    as "Actual journal loss permanently fences further metadata routing."
  mark(root, "owner-done")
  await(root, "executor-done")
  io.println("HISTORICAL_REFUSAL_OWNER_COMPLETED")
}

/// Both actual OS role exits and explicit completion witnesses are required.
///
/// ## Examples
/// `historical_refusal_restores_metadata_and_tls_beam_credits_test()`.
pub fn historical_refusal_restores_metadata_and_tls_beam_credits_test() {
  let assert Ok(here) = simplifile.current_directory()
  let #(seconds, nanos) =
    timestamp.system_time()
    |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/historical-refusal-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let assert Ok(configured) = provision.provision(root, "historical")
  assert provision.write_provisioned(configured, root <> "/tls.term") == Ok(Nil)

  // Two bounded OS runners must retain separate exits and completion witnesses.
  let roles = [
    #(
      configured.executor_config,
      configured.executor_options,
      "historical_command_refusal_test:run_executor(),halt(0).",
      "executor",
    ),
    #(
      configured.owner_config,
      configured.owner_options,
      "historical_command_refusal_test:run_owner(),halt(0).",
      "owner",
    ),
  ]
  let run =
    weft.new_prepared(
      list.map(roles, fn(role) {
        weft.managed(fn(_) {
          let answer =
            provision.run_node(
              provision.current_executable(),
              list.append(provision.node_arguments(role.1), [
                "-noshell",
                "-eval",
                role.2,
                "-extra",
                root,
              ]),
              here,
              distribution.bootstrap_home(role.0),
            )
          case answer {
            Ok(#(_, output)) -> {
              assert simplifile.write(root <> "/" <> role.3 <> ".log", output)
                == Ok(Nil)
            }
            Error(error) -> {
              assert simplifile.write(root <> "/" <> role.3 <> ".log", error)
                == Ok(Nil)
            }
          }
          answer
        })
      }),
    )
    |> weft.deadline(40_000)
    |> weft.start

  // Managed completion alone is insufficient without each actual OS exit and witness.
  let assert [executor, owner] = weft.values(run)
    as "Both bounded role runners return their actual outcomes."
  list.each([executor, owner], fn(value) {
    assert value.0 == 0 as value.1
  })
  assert string.contains(executor.1, "HISTORICAL_REFUSAL_EXECUTOR_COMPLETED")
  assert string.contains(owner.1, "HISTORICAL_REFUSAL_OWNER_COMPLETED")
  assert simplifile.delete(root) == Ok(Nil)
}
