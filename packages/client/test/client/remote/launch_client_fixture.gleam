//// Real original Fresh owner, Compile and Launch over two TLS BEAM runtimes.
//// Native helper retirement is deliberately not inferred from cap Final.

import broker/broker
import broker/budget
import broker/enrollment
import broker/exec
import broker/executor as local
import broker/framing
import broker/policy
import broker/token
import client/remote/compile_client as client
import client/remote/custodian
import client/remote/dispatch_binding
import client/remote/launch_client
import client/remote/launch_receipt
import client/remote/tool_custody
import codemode/compile
import codemode/enforcement
import codemode/identity as phase
import codemode/run_channel
import codemode/satellite
import codemode/service_input as input
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
import executor/remote/compile_service as whole
import executor/remote/dispatcher
import executor/remote/distribution
import executor/remote/identity
import executor/remote/journal
import executor/remote/launch_completion
import executor/remote/launch_service
import executor/remote/launch_wire as launch_protocol
import executor/remote/resource_journal as resources
import executor/remote/service
import executor/remote/wire
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import gleam/time/timestamp
import host/bootstrap
import machine/operation
import runtime/effects
import simplifile
import storage/owner_custody as custody
import support/internal/ffi_launch_scope
import support/internal/ffi_proc
import telemetry/log
import tools/fs
import weft
import weft/poll
import weft/registry

type ExecutorSide {
  ExecutorSide(
    enrolled: enrollment.SessionEnrollment,
    native_book: journal.Journal,
    resource_book: resources.Journal,
    native_service: service.Service,
    whole_service: whole.Service,
    launch_service: launch_service.Service,
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

fn channel(path: String) -> String {
  simplifile.read(path <> "/channel-root") |> required
}

// Each control exclusively allocates a short canonical root before either node
// starts. Associated native uncertainty keeps that root after the fixture ends.
fn allocate_channel(here: String, candidate: Int) -> String {
  let build =
    resolve_channel_parent(
      here,
      bootstrap.getenv("LOOM_TEST_SCRATCH") |> option.from_result,
    )
  let allocated =
    poll.fold_until(
      within: 2000,
      every: poll.Fixed(1),
      clock: poll.monotonic(),
      from: candidate % 1296,
      attempt: fn(index) {
        let path = build <> "/k" <> int.to_base36(index)
        case simplifile.create_directory(path) {
          Ok(Nil) -> poll.Settled(path)
          Error(simplifile.Eexist) -> poll.Pending({ index + 1 } % 1296)
          Error(error) -> poll.Broken(error)
        }
      },
    )
  let assert poll.Answer(path) = allocated
    as "Original short socket root is exclusively allocated."
  path
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
    env_allow: ["PATH", "TMPDIR", "LOOM_CAP_SOCK", "LOOM_CAP_TOKEN_FILE"],
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
      here <> "/../../../../build/codemode-seed",
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

fn required(value: Result(a, e)) -> a {
  let assert Ok(value) = value as "Fixture requires exact checked data."
  value
}

fn join(monitor: process.Monitor) -> Nil {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(3000)
    as "Exact component joined."
  Nil
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
    "{ok,_}=application:ensure_all_started(client),'client@remote@launch_client_fixture':"
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
  assert string.contains(output, "LAUNCH_EXECUTOR_COMPLETE")
  assert process.receive(reports, 2000) == Ok(weft.AllDelivered)
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
  let launch_config =
    launch_service.configure(resource_book, native_service, 1) |> required
  let launch_owner = launch_service.start(launch_config) |> required
  ExecutorSide(
    enrolled,
    native_book,
    resource_book,
    native_service,
    whole_service,
    launch_owner,
  )
}

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
  let registration =
    transport.attach_launch(registration, side.launch_service) |> required
  let server =
    transport.start(
      transport.configure_server([registration], 30_000) |> required,
    )
    |> required
  assert simplifile.write(path <> "/executor.ready", "ready") == Ok(Nil)
  wait_file(path <> "/owner.done", 285_000)
  case mode {
    0 -> Nil
    1 -> Nil
    _ -> panic as "Only live or historical fixed executor setup is admitted."
  }
  let monitor = process.monitor(transport.pid(server))
  transport.stop(server)
  join(monitor)
  let _ = launch_service.close(side.launch_service)
  let closed = whole.close(side.whole_service)
  assert closed == Ok(Nil) || closed == Error(whole.Uncertain)
  assert service.shutdown(side.native_service) == Ok(Nil)
  assert resources.release_endpoint(side.resource_book) == Ok(Nil)
  assert journal.release(side.native_book) == Ok(Nil)
  io.println("LAUNCH_EXECUTOR_COMPLETE")
}

pub fn run_owner(provisioned: String, path: String, control: Int) -> Nil {
  let fixture = distribution_fixture.read_provisioned(provisioned) |> required
  let membership = distribution.start(fixture.owner_config) |> required
  let peer = distribution.peer(membership, fixture.executor_name) |> required
  joined_owner(fixture, peer, path, control)
  io.println("LAUNCH_OWNER_COMPLETE")
}

pub fn live_control(control: Int) -> Nil {
  let here = simplifile.current_directory() |> required
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let root =
    here
    <> "/build/launch-client-"
    <> int.to_string(seconds)
    <> "-"
    <> int.to_string(nanos)
  let fixture =
    distribution_fixture.provision(root, "launch_consumer") |> required
  assert distribution_fixture.write_provisioned(
      fixture,
      root <> "/fixture.term",
    )
    == Ok(Nil)
  let path = root <> "/service"
  assert simplifile.create_directory_all(path <> "/work") == Ok(Nil)
  assert simplifile.create_directory_all(path <> "/build") == Ok(Nil)
  let socket_root = allocate_channel(here, nanos)
  assert simplifile.write(
      here
        <> "/build/launch-channel-"
        <> int.to_string(seconds)
        <> "-"
        <> int.to_string(nanos)
        <> ".txt",
      socket_root,
    )
    == Ok(Nil)
  io.println("Original Launch scratch: " <> socket_root)
  assert simplifile.write(path <> "/channel-root", socket_root) == Ok(Nil)
  assert simplifile.write(path <> "/work/witness", "original-response")
    == Ok(Nil)
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
  assert string.contains(output, "LAUNCH_OWNER_COMPLETE")

  // Original journals and custody paths remain available after unresolved
  // associated retirement; successful observations are not deletion witnesses.
  assert simplifile.write(root <> "/fixture.control.done", "observed")
    == Ok(Nil)
}

fn fresh_id() -> ids.EntryId {
  let #(seconds, nanos) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  ids.mint_entry(ids.generator(
    clock.fixed(seconds * 1000 + nanos / 1_000_000),
    nanos,
  )).0
}

fn joined_owner(
  fixture: distribution_fixture.Provisioned,
  peer: distribution.Peer,
  path: String,
  control: Int,
) -> Nil {
  let enrolled = enrolled(path)
  let reports = start_executor_node(fixture, path, 0)
  wait_file(path <> "/executor.ready", 15_000)
  let endpoint = transport.Config(peer, "owner", "linux", scope(), 1, 2500)
  let witness = process.new_subject()
  let cap_witness = process.new_subject()
  let broker_witness = process.new_subject()
  let names = registry.start() |> required
  let owner_config =
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
        let binding =
          dispatch_binding.new(
            pinned,
            endpoint,
            fn(request) {
              Ok(wire.Prepared(
                request.context.step,
                registration(),
                wire.Finite(270_000),
                request.request,
                wire.Logs,
              ))
            },
            fresh_id,
            poll.monotonic().now,
            23,
            270_000,
            fn(_) {
              let _ = custodian.fatal_fence(pinned, parent)
              Nil
            },
          )
          |> required
        let configuration =
          dispatch_binding.with_commands(binding, enrolled) |> required
        let receiving = configuration.receive
        let configuration =
          dispatcher.Config(
            ..configuration,
            receive: fn(origin, key, digest, outputs, terminal) {
              let outcome = receiving(origin, key, digest, outputs, terminal)
              let _ =
                simplifile.write(path <> "/native.receive", case outcome {
                  Ok(Nil) -> "committed"
                  Error(Nil) -> "refused"
                })
              outcome
            },
            uncertain: fn(_, _) {
              let _ = simplifile.write(path <> "/native.uncertain", "uncertain")
              Nil
            },
          )
        let entropy = token.production_entropy()
        let original_broker =
          broker.start_dispatching(
            fn(count) {
              case
                control == 5
                && simplifile.is_file(path <> "/owner.compile.completed")
                == Ok(True)
              {
                True -> <<>>
                False -> entropy(count)
              }
            },
            original_clock,
            dispatcher.dispatcher(configuration),
          )
          |> required
        process.send(broker_witness, original_broker)
        let seed =
          policy.SandboxPolicy(
            ..base(path),
            network: policy.NetworkFull,
            limits: policy.Limits(..base(path).limits, wall_s: 0),
          )
        let compiler =
          client.new(
            pinned,
            enrolled,
            original_broker,
            endpoint,
            fn() { id(20) },
            original_clock,
            poll.monotonic().now,
            client.Facts(
              input.WorkspaceProgram,
              seed,
              180_000,
              5000,
              [],
              owner_limits(),
            ),
          )
          |> required
        let launch =
          launch_client.new(
            pinned,
            enrolled,
            original_broker,
            endpoint,
            fn() { id(30) },
            original_clock,
            poll.monotonic().now,
            launch_client.Facts(owner_limits(), 5000),
          )
          |> required
        let #(unix, _) = clock.read(original_clock)
        let managed =
          phase.for_managed_execution(
            parent,
            budget: budget.Budget(1, unix + 270_000),
          )
        let source =
          "import cap/fs\nimport cap/report\nimport gleam/result\npub fn main() -> report.Outcome { report.text(fs.read(\"witness\") |> result.unwrap(\"missing\")) }"
        let assert vet.Passed(vetted) =
          vet.vet(source, vet_policy.workspace_effects())
          as "Actual trusted owner vetting before Compile."
        assert simplifile.write(path <> "/owner.compile.started", "started")
          == Ok(Nil)
        let compiled =
          client.service(compiler).compile(compile.CompileRequest(
            vetted,
            compile.default_dependencies(),
            [],
            phase.build_phase(managed),
          ))
        assert simplifile.write(path <> "/owner.compile.completed", "completed")
          == Ok(Nil)
        let assert Ok(artifact) = compiled.result
          as "Actual executor-issued Compile artifact."
        let run =
          satellite.run(
            artifact,
            phase.run_phase(managed),
            original_broker,
            satellite.RunConfig(
              seed,
              exec.PlatformEnforcement,
              [],
              ".",
              token.production_entropy(),
              original_clock,
              fn(request) {
                assert request.cap == "fs.read"
                Ok(
                  satellite.ServedHere(fn() {
                    process.send(cap_witness, request.args)
                    framing.CapOk(
                      mp.MapValue([
                        #(
                          mp.StringValue("contents"),
                          mp.StringValue(
                            simplifile.read(path <> "/work/witness") |> required,
                          ),
                        ),
                      ]),
                    )
                  }),
                )
              },
              satellite.no_precheck,
              [],
              5000,
            ),
            fn(request) {
              assert simplifile.write(
                  path <> "/owner.launch.started",
                  "started",
                )
                == Ok(Nil)
              case control {
                6 -> broker.stop(original_broker)
                8 -> {
                  assert ffi_launch_scope.suspend_broker(
                      broker.pid(original_broker) |> required,
                    )
                    == Ok(Nil)
                  Nil
                }
                _ -> Nil
              }
              let submitted = case control {
                2 | 3 | 4 -> changed_artifact(request, control)
                _ -> request
              }
              let connection = launch_client.launcher(launch)(submitted)
              case control {
                2 | 3 | 4 -> {
                  let assert Error(run_channel.LaunchRefused(
                    _,
                    run_channel.ResourcesReleased,
                  )) = connection
                    as "Producer or enrollment mismatch refuses before any Launch effects."
                  let origin =
                    remote_tool.tool_child(parent, remote_tool.Launch)
                    |> required
                  assert custodian.child(pinned, origin)
                    == Error(custody.Missing)
                  assert simplifile.read_directory(channel(path)) == Ok([])
                }
                5 -> {
                  let assert Error(run_channel.LaunchRefused(_, _)) = connection
                    as "Actual Broker mint refusal is a definite before-native refusal."
                  Nil
                }
                6 | 8 -> {
                  let assert Error(run_channel.LaunchOutcomeUnknown(_)) =
                    connection
                    as "BrokerUnavailable cannot invent definite before-native refusal."
                  Nil
                }
                _ -> Nil
              }
              case control, connection {
                1, Ok(original) -> {
                  let companion =
                    ffi_launch_scope.companion(original.close) |> required
                  let monitor = process.monitor(companion)
                  let assert poll.Answered(Nil) =
                    poll.until(within: 3000, every: 1, attempt: fn() {
                      case ffi_launch_scope.kill_scope(companion) {
                        Ok(Nil) -> poll.Done(Nil)
                        Error(Nil) -> poll.Retry
                      }
                    })
                    as "Bounded stacks witness the original linked native scope."

                  let selector =
                    process.new_selector()
                    |> process.select_specific_monitor(monitor, fn(_) { Nil })
                  assert process.selector_receive(selector, 2000) == Ok(Nil)
                  let closed = original.close()
                  let assert enforcement.Unreported(_) = closed.node
                    as "A lost native observer cannot invent a Broker report."
                  let assert run_channel.TransportUnresolved(_) =
                    closed.transport
                    as "A dead original close owner cannot invent a transport join."
                  let assert run_channel.ResourcesUnresolved(_) =
                    closed.resources
                    as "Actual scope loss cannot retire original native resources."
                  Nil
                }
                _, _ -> Nil
              }
              assert simplifile.write(
                  path <> "/owner.launch.returned",
                  "returned",
                )
                == Ok(Nil)
              connection
            },
          )
        assert simplifile.write(path <> "/owner.run.returned", "returned")
          == Ok(Nil)
        case control {
          0 -> {
            assert run.outcome
              == Ok(satellite.Completed(mp.StringValue("original-response")))
            let assert satellite.LaunchResourcesUnresolved(_) = run.custody
              as "Actual Final and native settlement do not prove helper retirement."
            let origin =
              remote_tool.tool_child(parent, remote_tool.Launch) |> required
            let recovered = launch_client.recover(launch, origin) |> required
            let assert launch_client.Completed(key, completion, _) = recovered
              as "Original outer completion is durable."
            let ref =
              command.command_ref(key, command.SatelliteCommand) |> required
            let retained_native =
              custodian.command_child(pinned, ref) |> required
            let assert option.Some(receipt) = retained_native.2
              as "Final's original step abort cannot discard the native receipt."
            let assert option.Some(actual) =
              launch_completion.native_association(completion)
              as "The outer result retains the exact associated native execution."
            assert launch_receipt.terminal(custody.bytes(receipt))
              == Ok(actual.terminal)
            assert launch_client.recover(launch, origin) == Ok(recovered)
            assert custodian.command_child(pinned, ref) == Ok(retained_native)
          }
          2 | 3 | 4 -> {
            let assert Error(satellite.LaunchRejected(_)) = run.outcome
              as "Rejected original producer never executes the satellite."
            assert run.custody == satellite.NoLaunchResources
          }
          5 -> {
            let assert Error(satellite.LaunchRejected(_)) = run.outcome
              as "Definite original Broker refusal never executes native Launch."
            let origin =
              remote_tool.tool_child(parent, remote_tool.Launch) |> required
            let recovered = launch_client.recover(launch, origin) |> required
            let assert launch_client.Completed(key, complete, _) = recovered
              as "Definite original refusal retains a closed outer completion."
            assert launch_completion.native_association(complete) == option.None
            let ref =
              command.command_ref(key, command.SatelliteCommand) |> required
            assert custodian.command_child(pinned, ref)
              == Error(custody.Missing)
          }
          6 | 8 -> Nil
          _ -> {
            let assert satellite.LaunchResourcesUnresolved(_) = run.custody
              as "Scope loss remains unresolved after the original actor dies."
            let origin =
              remote_tool.tool_child(parent, remote_tool.Launch) |> required
            let original = custodian.child(pinned, origin) |> required
            let outbound =
              launch_protocol.decode_input(enrolled, original.1) |> required
            assert original.2 == option.None
            let ref =
              command.command_ref(outbound.key, command.SatelliteCommand)
              |> required
            let native = custodian.command_child(pinned, ref) |> required
            assert native.2 == option.None
            let _ = retained_executor(endpoint, enrolled, outbound)
            assert custodian.child(pinned, origin) == Ok(original)
            assert custodian.command_child(pinned, ref) == Ok(native)
          }
        }
        process.send(witness, #(run, parent, original_broker))
        broker.stop(original_broker)
        final(original, compiled)
      },
    )
    |> required
  let owner = custodian.new(names, owner_config)
  let started = custodian.start(owner, owner_config) |> required
  let original = original_run()
  let invocation =
    tool_custody.invocation(
      ids.parse_session_id(identity.scope_fields(scope()).0) |> required,
      <<"original launch administrative context":utf8>>,
      original,
    )
    |> required
  let execution =
    custodian.execute(
      owner,
      invocation.key,
      invocation.arguments,
      invocation.request,
      original,
    )
  case control, execution {
    6, Error(custody.Unavailable(_)) | 8, Error(custody.Unavailable(_)) -> Nil
    _, Ok(_) -> Nil
    _, Error(_) ->
      panic as "Original managed execution reaches its expected custody state."
  }
  let original_broker = process.receive(broker_witness, 2000) |> required
  case control {
    8 -> {
      assert ffi_launch_scope.resume_broker(
          broker.pid(original_broker) |> required,
        )
        == Ok(Nil)
      Nil
    }
    _ -> Nil
  }
  let parent = invocation.key
  case control {
    6 | 8 -> {
      let origin =
        remote_tool.tool_child(parent, remote_tool.Launch) |> required
      let held = custodian.child(owner, origin) |> required
      assert held.2 == option.None
      let historical =
        launch_client.new(
          owner,
          enrolled,
          original_broker,
          endpoint,
          fn() { panic as "Unknown clearance history cannot mint." },
          clock.fixed(0),
          poll.monotonic().now,
          launch_client.Facts(owner_limits(), 5000),
        )
        |> required
      case launch_client.recover(historical, origin) {
        Ok(launch_client.Pending(_, _)) | Error(launch_client.Uncertain) -> Nil
        _ ->
          panic as "Unavailable clearance cannot retain a definite refusal completion."
      }
    }
    _ -> Nil
  }
  let assert Ok(_) = case control {
    0 -> process.receive(cap_witness, 2000) |> result.replace(Nil)
    _ -> Ok(Nil)
  }
    as "Authenticated actual satellite capability request reached its original owner."
  case control {
    6 | 8 -> Nil
    _ -> {
      let _ = process.receive(witness, 2000) |> required
      Nil
    }
  }
  let monitor = process.monitor(started.pid)
  assert custodian.stop(owner) == Ok(Nil)
  join(monitor)
  case control {
    1 -> {
      let reopened = custodian.new(names, owner_config)
      let restarted = custodian.start(reopened, owner_config) |> required
      let origin =
        remote_tool.tool_child(parent, remote_tool.Launch) |> required
      let before = custodian.child(reopened, origin) |> required
      assert before.2 == option.None
      let outbound =
        launch_protocol.decode_input(enrolled, before.1) |> required
      let ref =
        command.command_ref(outbound.key, command.SatelliteCommand) |> required
      let native = custodian.command_child(reopened, ref) |> required
      assert native.2 == option.None
      let observed = retained_executor(endpoint, enrolled, outbound)
      let historical =
        launch_client.new(
          reopened,
          enrolled,
          original_broker,
          endpoint,
          fn() {
            panic as "Historical observation cannot mint another identity."
          },
          clock.fixed(0),
          poll.monotonic().now,
          launch_client.Facts(owner_limits(), 5000),
        )
        |> required
      let recovered = launch_client.recover(historical, origin) |> required
      let assert launch_client.Completed(
        key,
        exact,
        launch_client.ExecutorAcknowledged,
      ) = recovered
        as "Restart collects exact native and outer originals without live authority."
      assert key == outbound.key
      assert exact == observed
      let retained = custodian.command_child(reopened, ref) |> required
      assert retained.0 == native.0
      assert retained.1 == native.1
      let assert option.Some(receipt) = retained.2
        as "Original missing native receipt survives restart recovery."
      let assert option.Some(associated) =
        launch_completion.native_association(exact)
        as "Associated native evidence remains historical."
      assert launch_receipt.terminal(custody.bytes(receipt))
        == Ok(associated.terminal)
      assert launch_client.recover(historical, origin) == Ok(recovered)
      let watch = process.monitor(restarted.pid)
      assert custodian.stop(reopened) == Ok(Nil)
      join(watch)
    }
    _ -> Nil
  }
  assert simplifile.write(path <> "/owner.done", "done") == Ok(Nil)
  executor_finished(reports)
}

// This original endpoint read is a witness only; it never commits or ACKs owner
// receipts, so the restart control starts with both owner receipt slots absent.
fn retained_executor(
  endpoint: transport.Config,
  enrolled: enrollment.SessionEnrollment,
  original: resources.Input,
) -> launch_completion.LaunchCompletion {
  let bytes = launch_protocol.encode_input(enrolled, original) |> required
  let answered =
    poll.until(within: endpoint.within_ms, every: 25, attempt: fn() {
      let reply = {
        use #(metadata, content) <- result.try(
          transport.launch_exchange(endpoint, launch_protocol.Query, bytes)
          |> result.replace_error(Nil),
        )
        launch_protocol.decode_reply(enrolled, original, metadata, content)
        |> result.replace_error(Nil)
      }
      case reply {
        Ok(launch_protocol.Observed(
          _,
          launch_protocol.Retained(complete, _, _, _),
        )) -> poll.Done(complete)
        _ -> poll.Retry
      }
    })
  let assert poll.Answered(completion) = answered
    as "Executor originals are retained while owner receipts remain absent."
  completion
}

// Valid Artifact syntax cannot substitute another producer, manifest or scope.
fn changed_artifact(
  request: run_channel.LaunchRequest,
  control: Int,
) -> run_channel.LaunchRequest {
  let #(artifact, identity, seed, demand, env, cwd) =
    run_channel.execution(request)
  let altered = case artifact {
    compile.ExecutorArtifact(..) ->
      case control {
        2 ->
          compile.ExecutorArtifact(
            ..artifact,
            manifest_hash: string.repeat("f", 64),
          )
        3 ->
          compile.ExecutorArtifact(
            ..artifact,
            request_id: ids.entry_id_to_string(id(99)),
          )
        _ ->
          compile.ExecutorArtifact(
            ..artifact,
            scope: workspace.scope_from_fields(
                "00000000-0000-7000-8000-000000000001",
                "checkout",
                "linux",
                3,
                7,
              )
              |> required,
          )
      }
    compile.Artifact(..) ->
      panic as "The physical producer issues a remote artifact."
  }
  run_channel.request(
    altered,
    identity,
    seed,
    demand,
    env,
    cwd,
    run_channel.token(request),
    run_channel.host(request),
  )
  |> required
}

// Normal checkouts use their own build directory; isolated validation pins an
// explicit short canonical parent without relying on worktree ancestry.
fn resolve_channel_parent(
  here: String,
  override: option.Option(String),
) -> String {
  let parent = case override {
    option.Some(parent) -> parent
    option.None -> here <> "/../../build"
  }
  bootstrap.canonical_directory(parent) |> required
}

pub fn channel_parent_control() -> Nil {
  let here = simplifile.current_directory() |> required
  assert simplifile.create_directory_all(here <> "/../../build") == Ok(Nil)
  let parent =
    resolve_channel_parent(
      here,
      bootstrap.getenv("LOOM_TEST_SCRATCH") |> option.from_result,
    )
  let ordinary =
    bootstrap.canonical_directory(here <> "/../../build") |> required
  assert resolve_channel_parent(here, option.None) == ordinary
  assert resolve_channel_parent(
      "/unrelated/worktree/packages/client",
      option.Some(parent),
    )
    == parent
}
