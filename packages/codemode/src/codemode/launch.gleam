//// Production local satellite placement: foreground whole Launch and the
//// persistent `codemode/satellite.Launcher` both create a real jailed `erl`
//// node on the far end of a real AF_UNIX capability socket (design §6.3 "Layer two: the
//// satellite node", `docs/architecture/code-mode.md`).
////
//// The host's module doc states the contract; this module realizes it,
//// in this order:
////
//// 1. **Refuse before anything exists.** The launch composes the session
////    base with the node's requirements *itself*, purely, and refuses
////    in-band when the base cannot host a satellite — no socket is
////    created, no node is dispatched, and the message names the exact
////    shortfall. The dispatch then also carries `RefuseNarrowed`, so a
////    broker that composes differently refuses rather than running a
////    weaker jail than the one this module checked.
//// 2. **Cap socket first.** An AF_UNIX *stream* listener is created at
////    `cap_socket_path` before the node is launched, so the satellite's
////    `gen_tcp:connect` cannot lose a race with it.
//// 3. **Then the node**, dispatched through the physical runner under the
////    *same* `{op_id, step_id}` the host uses. That is what makes
////    `broker.abort_step` on the host's deadline actually kill it.
////
//// Foreground `foreground_launcher` owns one resource state machine plus leaf
//// reader/writer owners under a weft drain run. It returns a paused typed channel.
//// The reader charges a four-byte declaration before exact bounded body reads;
//// the writer admits the host's exact already-charged reservation before delivery.
//// Original socket close uses zero linger, independently of a blocked writer,
//// and actual joins remain separate from native settlement and report evidence.
////
//// # Persistent compatibility: two processes, one ordering guarantee
////
//// The socket is served by two unlinked processes. The **reader** accepts
//// the connection, owns it, and blocks in `recv`, pushing every chunk to
//// `LaunchSpec.wire` as `WireBytes` and, at end of stream, exactly one
//// `WireClosed`. The **writer** holds the outbound side: it buffers frames
//// the host emits before the satellite connected, flushes them on attach,
//// and closes both sockets on teardown.
////
//// Splitting them buys the ordering the host depends on. Every inbound
//// byte and the close both come from the reader, in stream order, and
//// `gen_tcp:recv` yields buffered data before it reports the peer gone —
//// so a satellite that writes its terminal `outcome` frame and exits can
//// never have its death overtake its result. The node's own exit status
//// travels a different path (the exec settlement), and is therefore used
//// only to *enrich* the reason on a close the reader already observed,
//// never to announce one.
////
//// # What the policy states about reachability, and what it still assumes
////
//// A node needs four regions inside its jail: the cap socket, which it
//// must `connect(2)`; the token file, which it must read; the `.beam`
//// directory the hermetic build wrote; and the toolchain the emulator
//// itself comes from, which is an ERTS install tree and not just the
//// `erl` binary. The last of those used to be stated nowhere at all.
////
//// **The toolchain and the build seed are explicit mounts**
//// (`protocol-change/004`). `node_requirements` puts the list the host
//// derived from its located toolchain into the policy's `mounts` field,
//// each entry read-only and `MountRequired`, and `client/serve` puts the
//// same list into the session base. Mounts compose as the meet by path, so
//// a base that does not carry one produces a `NarrowedMount` and this
//// module refuses the launch naming the path. That refusal is the point:
//// the prefix is derived by a heuristic over where `erl` was found
//// (`client/codemode.install_prefix`), and a wrong prefix must be a
//// sentence an operator can act on rather than a node that boots into a
//// jail with no ERTS tree.
////
//// **The socket, the token and `beam_dir` are readable roots**, and are
//// checked against the composed policy by `path_reachable`. They are not
//// mounts because they are per-execution paths: a session base is built
//// before any of them exists, so it could not carry the same entries, and
//// a requirement the base cannot match refuses every launch. Under
//// `protocol-change/020` the region that covers them is the workspace
//// mount the base derives from the admission record, which is a statement
//// the base makes rather than one this module can.
////
//// **What is still assumed is the system view.** Until 020 lands the
//// helper binds the whole host filesystem read-only, so `/usr`, `/lib`,
//// `/etc` and the shell are reachable without anybody naming them, and
//// three kernel facts make the socket work: `sb_permission` exempts
//// sockets from `EROFS`, so `connect(2)` on a read-only mount succeeds;
//// Landlock's filesystem rights do not govern connecting to an existing
//// socket; and the network-off seccomp filter denies only non-`AF_UNIX`
//// socket creation. When 020 replaces that base view, the system roots
//// become a per-OS constant in the helper and nothing in this module
//// changes.
////
//// Two things no vocabulary makes reachable, which this module therefore
//// refuses rather than discovers at runtime: a cap socket or token under a
//// `protected` path (bwrap shadows it with a read-only tmpfs) and, when
//// scratch is a tmpfs, one under `/tmp` (the helper mounts the scratch
//// tmpfs there, hiding whatever the host had). Both make the path
//// unreachable inside the jail while looking perfectly fine outside it. A
//// mount cannot rescue either: `broker/policy.validate` refuses a mount
//// that overlaps a `protected` entry, because the two platforms would
//// order the pair in opposite directions.
////
//// ## Flow
////
//// Foreground: `foreground_launcher` → `foreground_launch` → `foreground_owned`
//// → `foreground_step` → `read_reserved_frame` / `foreground_write_step` →
//// `begin_original_close` → `finish_original_close` → `publish_original_close`.
//// `foreground_refusal` and `foreground_requirements` preserve pure local approval
//// projection. `prepare_original_connection` keeps inbound delivery paused until
//// original custody installation; `offer_original` rejects copied reservations.
//// `foreground_node` keeps actual native settlement separate from child drains.
////
//// Persistent compatibility:
////
//// `launcher` → `launch` → `start_channel` → `start_reader` → `spawn_node` →
//// `run_node` → `collect_node_result` → `destroy`
////
//// 1. `launcher` closes over the config and hands persistent hosting a function
////    from `LaunchSpec` to a `CapConnection`.
//// 2. `launch` refuses before anything exists: `check_budget`,
////    `composed_policy` and `path_reachable` all run before `ffi_unix.listen`
////    creates the cap socket.
//// 3. `start_channel` spawns the writer (`writer_main`) and waits for its
////    outbox; `start_reader` then spawns the reader (`reader_main`), which
////    accepts the one connection and feeds `read_loop`.
//// 4. `start_reader` also starts the reporter and the janitor, and calls
////    `spawn_node`, which builds the broker call with `node_call` from
////    `node_requirements`, `node_argv` and `node_env`.
//// 5. `run_node` clears the call through the injected physical runner;
////    `report_refused` or `collect_node_result` tells the reporter how the node
////    ended, and the exit text only enriches a close the reader already saw.
//// 6. `destroy` is the connection's teardown: it aborts the step, and
////    `await_report` waits for the settlement so the helper is back in the pool
////    before the host moves on.

import broker/broker.{type CallSpec}
import broker/budget.{type Budget}
import broker/exec.{type EnforcementDemand} as broker_exec
import broker/policy.{type Grant, type Mount, type Narrowing, type SandboxPolicy}
import codemode/compile.{type Artifact}
import codemode/enforcement.{type Report}
import codemode/identity
import codemode/internal/ffi_unix.{type Listener, type Socket}
import codemode/native_command
import codemode/physical
import codemode/run_channel
import codemode/satellite.{type CapConnection, type LaunchSpec}
import core/clock.{type Clock}
import core/remote_tool
import filepath
import gleam/bit_array
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tools/tool.{type Collected}
import weft
import weft/poll
import weft/state_machine as sm

/// The environment variable naming the cap socket. Mirrors
/// `cap/runtime.sock_env`; the host does not depend on the `cap` package
/// (it must never link model-facing code), so the name is restated here
/// and pinned by a test against the boot contract.
pub const sock_env = native_command.sock_env

/// The environment variable naming the private cap-token file. Mirrors
/// `cap/runtime.token_env`; see `sock_env`.
pub const token_env = native_command.token_env

/// Where the Go helper mounts a `ScratchTmpfs` policy's scratch area
/// (`jail.ScratchMount`). A cap socket under this path is invisible inside
/// the jail, so the launcher refuses one.
pub const scratch_mount = "/tmp"

// How long a handoff from a freshly spawned socket process may take.
const handoff_timeout_ms = 2000

// One accept poll. The accept is sliced so the reader can notice, between
// slices, that the node died before it ever reached the socket.
const accept_poll_ms = 200

// Slack over the wall deadline before the node's collector gives up.
const settle_margin_ms = 10_000

// How long the reader waits, after end of stream, for the node's own exit
// status to arrive and sharpen the close reason.
const exit_reason_wait_ms = 2000

// How long `destroy` waits for the node's own settlement, and with it the
// helper's enforcement report.
//
// `destroy` aborts first, so by the time it waits the node is either
// already gone (the program returned and the node exited) or being killed.
// A cancelled execution still answers with `exec_exit`, but only after the
// helper's TERM-then-KILL ladder; the broker's relay gives that ladder a
// 5s grace and then settles the call itself as `CancelEscalated`.
//
// This wait must outlast that grace, and the number is chosen for a
// reason beyond patience: whichever of the two expires first decides what
// the report *says*. Giving up first would answer "nobody reported in
// time", which is a statement about this timer; waiting for the broker
// answers "the helper was killed before it could report", which is a
// statement about the node. The second is the truth, and a report that
// describes a race rather than a jail is the failure this whole path was
// built to remove (issue #5). Still bounded either way: a broker that
// never settles at all costs this once.
const node_report_wait_ms = 6000

// The satellite node itself holds one outstanding effect for the whole
// execution, so a pooled budget of one would starve every `cap_call`.
const minimum_outstanding = 2

// A cross-platform margin under Linux's 108-byte and macOS's 104-byte
// `sun_path` limits. Client-side workspace preparation uses the same budget.
const max_socket_path_bytes = 100

/// Everything the production launcher needs beyond the `LaunchSpec`.
pub type LaunchConfig {
  LaunchConfig(
    /// The physical clearance and step teardown adapter.
    runner: physical.Runner,
    /// Reads the wall clock to size the node's own deadline.
    clock: Clock,
    /// Absolute path to the `erl` executable.
    erl_path: String,
    /// The host-derived regions a node must have inside its jail: the
    /// toolchain install prefixes and the build seed, stated as explicit
    /// mounts. The host holds this list because only the host knows where
    /// it found a toolchain; see `node_requirements`.
    host_mounts: List(Mount),
    /// Enforcement strictness demanded of the jailed node.
    demand: EnforcementDemand,
    /// How long to wait for the satellite to connect back.
    accept_timeout_ms: Int,
  )
}

/// Local foreground placement, supplied only to the selected local adapter.
/// The generic whole-Launch request carries neither of these physical paths.
pub type ForegroundLaunchConfig {
  ForegroundLaunchConfig(
    /// Original physical clearance, toolchain, clock and accept configuration.
    local: LaunchConfig,
    /// Exact original local token placement expected from its private writer.
    token_path: String,
    /// Exact original local Unix listener placement.
    cap_socket_path: String,
    /// Creates the private original token and returns that same configured path.
    write_token_file: fn(BitArray) -> Result(String, String),
    /// Removes the original local token after actual resource teardown.
    unlink_token_file: fn(String) -> Nil,
  )
}

/// Builds the production `satellite.Launcher`.
///
/// The returned function serves persistent hosting: it creates the cap socket,
/// dispatches the jailed node, and hands back the
/// `CapConnection` the host writes frames to and destroys the node with.
/// Executor artifacts are refused before local resource creation.
///
/// ## Examples
///
/// ```gleam
/// let launch_node = launch.launcher(local_config)
/// // launch_node(spec) returns the channel or a structured refusal.
/// ```
pub fn launcher(config: LaunchConfig) -> satellite.Launcher {
  fn(spec) { launch(config, spec) }
}

/// Derives local node requirements without writing token/listener resources.
/// A remote artifact refuses before any local path can become an effect.
///
/// ## Examples
///
/// ```gleam
/// // launch.foreground_requirements(local_config, original_request, now_ms)
/// ```
pub fn foreground_requirements(
  config: ForegroundLaunchConfig,
  request: run_channel.LaunchRequest,
  now_ms: Int,
) -> Result(SandboxPolicy, String) {
  let #(artifact, phase, base, _demand, env, _cwd) =
    run_channel.execution(request)
  use beam_dir <- result.try(local_beam_dir(artifact))
  let remaining_ms =
    int.max(identity.pooled_budget(phase).deadline_ms - now_ms, 0)
  Ok(
    native_command.node_requirements(native_command.NodeAccess(
      beam_dir:,
      socket_path: config.cap_socket_path,
      token_path: config.token_path,
      base:,
      mounts: config.local.host_mounts,
      env:,
      wall_s: bound_wall(
        base.limits.wall_s,
        int.max({ remaining_ms + 999 } / 1000, 1),
      ),
    )),
  )
}

/// Preserves approval-widening refusal checks without inventing owner paths.
/// This pure projection precedes all local token, listener and native effects.
///
/// ## Examples
///
/// ```gleam
/// // launch.foreground_refusal(local_config, original_request, now_ms)
/// ```
pub fn foreground_refusal(
  config: ForegroundLaunchConfig,
  request: run_channel.LaunchRequest,
  now_ms: Int,
) -> Result(Nil, String) {
  let #(_artifact, phase, base, _demand, _env, _cwd) =
    run_channel.execution(request)
  use Nil <- result.try(check_budget(identity.pooled_budget(phase)))
  use Nil <- result.try(
    case identity.pooled_budget(phase).deadline_ms > now_ms {
      True -> Ok(Nil)
      False -> Error("the original Launch deadline has expired")
    },
  )
  use requirements <- result.try(foreground_requirements(
    config,
    request,
    now_ms,
  ))
  use effective <- result.try(composed_policy(
    base,
    requirements,
    identity.grants(phase),
  ))
  use Nil <- result.try(path_reachable(
    effective,
    config.cap_socket_path,
    "the cap socket",
  ))
  use Nil <- result.try(path_reachable(
    effective,
    config.token_path,
    "the cap token file",
  ))
  case socket_path_bytes(config.cap_socket_path) <= max_socket_path_bytes {
    True -> Ok(Nil)
    False ->
      Error("the original cap socket path exceeds the 100-byte local limit")
  }
}

/// Builds the original local whole-Launch adapter; persistent hosts keep `launcher`.
/// The selected adapter owns token/listener/native preparation and real drains.
///
/// ## Examples
///
/// ```gleam
/// let whole_launch = launch.foreground_launcher(local_foreground_config)
/// // whole_launch(original_request) returns a paused, owned connection.
/// ```
pub fn foreground_launcher(
  config: ForegroundLaunchConfig,
) -> run_channel.Launcher {
  fn(request) { foreground_launch(config, request) }
}

// All placement/authority checks precede the first original physical resource.
fn foreground_launch(
  config: ForegroundLaunchConfig,
  request: run_channel.LaunchRequest,
) -> Result(run_channel.Connection, run_channel.LaunchFailure) {
  let #(now, _clock) = clock.read(config.local.clock)
  use Nil <- result.try(
    foreground_refusal(config, request, now)
    |> result.map_error(fn(reason) {
      run_channel.LaunchRefused(reason, run_channel.ResourcesReleased)
    }),
  )
  use requirements <- result.try(
    foreground_requirements(config, request, now)
    |> result.map_error(fn(reason) {
      run_channel.LaunchRefused(reason, run_channel.ResourcesReleased)
    }),
  )
  use Nil <- result.try(
    private_directory(directory_of(config.cap_socket_path))
    |> result.map_error(fn(reason) {
      run_channel.LaunchRefused(reason, run_channel.ResourcesReleased)
    }),
  )
  use token_path <- result.try(
    config.write_token_file(run_channel.token(request))
    |> result.map_error(fn(reason) {
      // The trusted writer is synchronous and confined to configured placement.
      // A failed permission/write step may already have created that exact file.
      config.unlink_token_file(config.token_path)
      run_channel.LaunchRefused(reason, run_channel.ResourcesReleased)
    }),
  )
  case token_path == config.token_path {
    False -> {
      config.unlink_token_file(token_path)
      Error(run_channel.LaunchRefused(
        "the token writer changed original placement",
        run_channel.ResourcesReleased,
      ))
    }
    True ->
      case ffi_unix.listen(config.cap_socket_path) {
        Error(reason) -> {
          config.unlink_token_file(token_path)
          Error(run_channel.LaunchRefused(reason, run_channel.ResourcesReleased))
        }
        Ok(listener) ->
          foreground_owned(config, request, requirements, listener, now)
      }
  }
}

// The owner serializes copied reservations and independently closes a blocked
// writer's socket. Its close result remains available for duplicate observations.
type ForegroundPhase {
  OriginalOpen
  OriginalClosing
  OriginalClosed(result: run_channel.CloseResult)
}

type ForegroundEvent {
  PrepareConnection(reply: Subject(run_channel.Connection))
  ActivateOriginal(reply: Subject(Result(Nil, run_channel.ChannelFailure)))
  OfferOriginal(
    reservation: run_channel.Reservation,
    payload: run_channel.Payload,
    reply: Subject(Result(Nil, run_channel.ChannelFailure)),
  )
  SocketAccepted(socket: Socket)
  WriterConsumed(frame: run_channel.FrameRef)
  NativeCleared(handle: physical.RunningCall)
  NativeSettled(node: Report, resources: run_channel.ResourceDrain)
  OriginalClose(reply: Subject(run_channel.CloseResult))
  HostDied
  OriginalDeadline
  CleanupDeadline
  CheckCleanup
  ReleaseObservation
  Children(event: weft.Pulled(Nil, Nil))
}

type ForegroundOwned {
  ForegroundOwned(
    config: ForegroundLaunchConfig,
    request: run_channel.LaunchRequest,
    listener: Listener,
    incarnation: run_channel.Incarnation,
    commands: Subject(ForegroundEvent),
    reader: Subject(ForegroundRead),
    writer: Subject(ForegroundWrite),
    socket: Option(Socket),
    outbound: run_channel.Window,
    native: Option(physical.RunningCall),
    settlement: Option(#(Report, run_channel.ResourceDrain)),
    joined: Option(run_channel.TransportDrain),
    close_reply: Option(Subject(run_channel.CloseResult)),
  )
}

fn foreground_owned(
  config: ForegroundLaunchConfig,
  request: run_channel.LaunchRequest,
  requirements: SandboxPolicy,
  listener: Listener,
  now: Int,
) -> Result(run_channel.Connection, run_channel.LaunchFailure) {
  let incarnation = run_channel.new_incarnation()
  let #(host, _) = run_channel.endpoint(run_channel.host(request))
  let #(_artifact, phase, _base, _demand, _env, _cwd) =
    run_channel.execution(request)
  let lifetime = int.max(identity.pooled_budget(phase).deadline_ms - now, 0)
  let started =
    sm.new_with_initialiser(handoff_timeout_ms, fn(commands) {
      let monitor = process.monitor(host)
      let drains = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(commands)
        |> process.select_map(drains, Children)
        |> process.select_specific_monitor(monitor, fn(_) { HostDied })
      use reader <- result.try(start_foreground_reader(
        listener,
        config.local.accept_timeout_ms,
        lifetime,
        request,
        incarnation,
        commands,
      ))
      use writer <- result.try(
        start_foreground_writer(request, incarnation, commands)
        |> result.map_error(fn(reason) {
          // This reader is still paused and owns no accepted body/native work.
          // Its stop prevents a failed sibling start from leaving an idle leaf.
          process.send(reader.data, ReadStop)
          reason
        }),
      )
      let reader_cancel = fn() {
        ffi_unix.close_listener(listener)
        process.send(reader.data, ReadStop)
      }
      let writer_cancel = fn() { process.send(writer.data, WriteStop) }
      let tasks = [
        weft.prepared_leaf(
          owner: reader.pid,
          cancel: reader_cancel,
          begin: fn() { Ok(Nil) },
        ),
        weft.prepared_leaf(
          owner: writer.pid,
          cancel: writer_cancel,
          begin: fn() { Ok(Nil) },
        ),
        weft.task(fn() {
          foreground_node(
            config,
            request,
            requirements,
            commands,
            lifetime + settle_margin_ms,
          )
          Ok(Nil)
        }),
      ]
      let _scope =
        weft.new_prepared(tasks)
        |> weft.deadline(lifetime + settle_margin_ms)
        |> weft.cancel_grace(node_report_wait_ms)
        |> weft.start_relayed(to: drains)
      let outbound =
        run_channel.prepare_direction(incarnation, run_channel.ToNode)
      let owned =
        ForegroundOwned(
          config:,
          request:,
          listener:,
          incarnation:,
          reader: reader.data,
          writer: writer.data,
          commands:,
          socket: None,
          outbound:,
          native: None,
          settlement: None,
          joined: None,
          close_reply: None,
        )
      sm.initialised(OriginalOpen, owned)
      |> sm.selecting(selector)
      |> sm.returning(commands)
      |> Ok
    })
    |> sm.on_event(foreground_step)
    |> sm.on_enter(foreground_enter)
    |> sm.unlinked
    |> sm.start
  case started {
    Error(_) -> {
      ffi_unix.close_listener(listener)
      Error(run_channel.LaunchOutcomeUnknown(
        "original preparation owner did not initialise",
      ))
    }
    Ok(owner) -> {
      let reply = process.new_subject()
      process.send(owner.data, PrepareConnection(reply))
      case process.receive(reply, handoff_timeout_ms) {
        Ok(connection) -> Ok(connection)
        Error(Nil) ->
          Error(run_channel.LaunchOutcomeUnknown(
            "original prepared connection was not observed",
          ))
      }
    }
  }
}

// Entering open arms the original authority, while closing gets only cleanup
// observation time. Neither transition renews a launch or capability deadline.
fn foreground_enter(
  _previous: ForegroundPhase,
  phase: ForegroundPhase,
  owned: ForegroundOwned,
) -> sm.Enter(ForegroundPhase, ForegroundOwned, ForegroundEvent) {
  case phase {
    OriginalOpen -> {
      let #(_artifact, identity, _base, _demand, _env, _cwd) =
        run_channel.execution(owned.request)
      let #(now, _clock) = clock.read(owned.config.local.clock)
      sm.keep(owned)
      |> sm.with_state_timeout(
        after: int.max(identity.pooled_budget(identity).deadline_ms - now, 0),
        sending: OriginalDeadline,
      )
    }
    OriginalClosing ->
      sm.keep(owned)
      |> sm.with_state_timeout(
        after: settle_margin_ms + node_report_wait_ms,
        sending: CleanupDeadline,
      )
    OriginalClosed(_) ->
      sm.keep(owned)
      |> sm.with_state_timeout(
        after: node_report_wait_ms,
        sending: ReleaseObservation,
      )
  }
}

fn foreground_step(
  phase: ForegroundPhase,
  owned: ForegroundOwned,
  event: ForegroundEvent,
) -> sm.Next(ForegroundPhase, ForegroundOwned, ForegroundEvent) {
  case phase, event {
    OriginalOpen, PrepareConnection(reply) ->
      prepare_original_connection(owned, reply)
    OriginalOpen, ActivateOriginal(reply) -> activate_original(owned, reply)
    OriginalOpen, OfferOriginal(reservation, payload, reply) ->
      offer_original(owned, reservation, payload, reply)
    OriginalOpen, SocketAccepted(socket) -> {
      process.send(owned.writer, WriteAttach(socket))
      sm.keep(ForegroundOwned(..owned, socket: Some(socket)))
    }
    OriginalClosing, SocketAccepted(socket)
    | OriginalClosed(_), SocketAccepted(socket)
    -> {
      ffi_unix.close_now(socket)
      sm.keep(owned)
    }
    OriginalOpen, WriterConsumed(frame) ->
      original_writer_consumed(owned, frame)
    OriginalClosing, WriterConsumed(_) | OriginalClosed(_), WriterConsumed(_) ->
      sm.keep(owned)
    OriginalOpen, NativeCleared(handle) ->
      sm.keep(ForegroundOwned(..owned, native: Some(handle)))
    OriginalClosing, NativeCleared(handle)
    | OriginalClosed(_), NativeCleared(handle)
    -> {
      handle.cancel()
      sm.keep(ForegroundOwned(..owned, native: Some(handle)))
    }
    OriginalOpen, NativeSettled(node, resources) ->
      sm.keep(ForegroundOwned(..owned, settlement: Some(#(node, resources))))
    OriginalClosing, NativeSettled(node, resources) ->
      finish_original_close(
        ForegroundOwned(..owned, settlement: Some(#(node, resources))),
      )
    OriginalClosed(_), NativeSettled(..) -> sm.keep(owned)
    OriginalOpen, Children(event) -> sm.keep(record_children(owned, event))
    OriginalClosing, Children(event) ->
      finish_original_close(record_children(owned, event))
    OriginalClosed(_), Children(_) -> sm.keep(owned)
    OriginalOpen, OriginalClose(reply) ->
      begin_original_close(owned, Some(reply))
    OriginalClosing, OriginalClose(_) -> sm.keep(owned) |> sm.postpone
    OriginalClosed(result), OriginalClose(reply) -> {
      process.send(reply, result)
      sm.keep(owned)
    }
    OriginalOpen, HostDied | OriginalOpen, OriginalDeadline ->
      begin_original_close(owned, None)
    OriginalClosing, HostDied
    | OriginalClosed(_), HostDied
    | OriginalClosing, OriginalDeadline
    | OriginalClosed(_), OriginalDeadline
    -> sm.keep(owned)
    OriginalClosing, CheckCleanup -> finish_original_close(owned)
    OriginalOpen, CheckCleanup | OriginalClosed(_), CheckCleanup ->
      sm.keep(owned)
    OriginalClosing, CleanupDeadline -> publish_original_close(owned)
    OriginalOpen, CleanupDeadline | OriginalClosed(_), CleanupDeadline ->
      sm.keep(owned)
    OriginalClosed(_), ReleaseObservation -> sm.stop()
    OriginalOpen, ReleaseObservation | OriginalClosing, ReleaseObservation ->
      sm.keep(owned)
    OriginalClosing, PrepareConnection(_)
    | OriginalClosed(_), PrepareConnection(_)
    -> sm.keep(owned)
    OriginalClosing, ActivateOriginal(reply)
    | OriginalClosed(_), ActivateOriginal(reply)
    -> {
      process.send(reply, Error(run_channel.ChannelRetired))
      sm.keep(owned)
    }
    OriginalClosing, OfferOriginal(_, _, reply)
    | OriginalClosed(_), OfferOriginal(_, _, reply)
    -> {
      process.send(reply, Error(run_channel.ChannelRetired))
      sm.keep(owned)
    }
  }
}

fn prepare_original_connection(
  owned: ForegroundOwned,
  reply: Subject(run_channel.Connection),
) -> sm.Next(ForegroundPhase, ForegroundOwned, ForegroundEvent) {
  let active =
    run_channel.activate_direction(owned.outbound)
    |> result.try(run_channel.write_grant)
  case active {
    Error(_) -> begin_original_close(owned, None)
    Ok(grant) -> {
      let commands = owned.commands
      let connection =
        run_channel.Connection(
          incarnation: owned.incarnation,
          initial_write_grant: grant,
          offer: fn(reservation, payload) {
            let reply = process.new_subject()
            process.send(commands, OfferOriginal(reservation, payload, reply))
            process.receive(reply, handoff_timeout_ms)
            |> result.unwrap(
              Error(run_channel.TransportFailed(
                "writer admission was not observed",
              )),
            )
          },
          activate: fn() {
            let reply = process.new_subject()
            process.send(commands, ActivateOriginal(reply))
            process.receive(reply, handoff_timeout_ms)
            |> result.unwrap(
              Error(run_channel.TransportFailed("activation was not observed")),
            )
          },
          close: fn() {
            let reply = process.new_subject()
            process.send(commands, OriginalClose(reply))
            process.receive(
              reply,
              settle_margin_ms + node_report_wait_ms + handoff_timeout_ms,
            )
            |> result.unwrap(run_channel.CloseResult(
              node: enforcement.Unreported(
                "original cleanup observation was lost",
              ),
              transport: run_channel.TransportUnresolved(
                "original joins were not observed",
              ),
              resources: run_channel.ResourcesUnresolved(
                "original resource release was not observed",
              ),
            ))
          },
        )
      process.send(reply, connection)
      sm.keep(owned)
    }
  }
}

fn activate_original(
  owned: ForegroundOwned,
  reply: Subject(Result(Nil, run_channel.ChannelFailure)),
) -> sm.Next(ForegroundPhase, ForegroundOwned, ForegroundEvent) {
  case run_channel.activate_direction(owned.outbound) {
    Error(error) -> {
      process.send(reply, Error(error))
      sm.keep(owned)
    }
    Ok(outbound) -> {
      process.send(owned.reader, ReadActivate)
      process.send(reply, Ok(Nil))
      sm.keep(ForegroundOwned(..owned, outbound:))
    }
  }
}

// The adapter spends its independent mirror before publishing to the writer.
// Exact reservation equality rejects copied callbacks after first admission.
fn offer_original(
  owned: ForegroundOwned,
  reservation: run_channel.Reservation,
  payload: run_channel.Payload,
  reply: Subject(Result(Nil, run_channel.ChannelFailure)),
) -> sm.Next(ForegroundPhase, ForegroundOwned, ForegroundEvent) {
  let #(_frame, length) = run_channel.reservation(reservation)
  let checked = {
    use #(reserved, original) <- result.try(run_channel.reserve_frame(
      owned.outbound,
      length,
    ))
    use Nil <- result.try(case original == reservation {
      True -> Ok(Nil)
      False -> Error(run_channel.StaleReservation)
    })
    use _payload <- result.try(run_channel.finish_payload(
      reservation,
      run_channel.payload(payload),
    ))
    run_channel.publish_frame(reserved, reservation)
  }
  case checked {
    Error(error) -> {
      process.send(reply, Error(error))
      case error {
        run_channel.AllowanceExhausted -> begin_original_close(owned, None)
        run_channel.InvalidFrame
        | run_channel.WindowUnavailable
        | run_channel.ChannelRetired
        | run_channel.StaleReservation
        | run_channel.TransportFailed(_) -> sm.keep(owned)
      }
    }
    Ok(outbound) -> {
      process.send(owned.writer, WriteFrame(reservation, payload))
      process.send(reply, Ok(Nil))
      sm.keep(ForegroundOwned(..owned, outbound:))
    }
  }
}

fn original_writer_consumed(
  owned: ForegroundOwned,
  frame: run_channel.FrameRef,
) -> sm.Next(ForegroundPhase, ForegroundOwned, ForegroundEvent) {
  let #(outbound, consumed) =
    run_channel.consume_frame(owned.outbound, frame, run_channel.Continue)
  case consumed {
    run_channel.Ignored -> sm.keep(owned)
    run_channel.Consumed -> {
      let #(_host, events) =
        run_channel.endpoint(run_channel.host(owned.request))
      process.send(events, run_channel.WriteConsumed(frame))
      sm.keep(ForegroundOwned(..owned, outbound:))
    }
  }
}

// Socket closure is independent of either blocked child's mailbox. Closing
// the listener also wakes accept; no native or resource proof is inferred.
fn begin_original_close(
  owned: ForegroundOwned,
  reply: Option(Subject(run_channel.CloseResult)),
) -> sm.Next(ForegroundPhase, ForegroundOwned, ForegroundEvent) {
  let #(_artifact, phase, _base, _demand, _env, _cwd) =
    run_channel.execution(owned.request)
  owned.config.local.runner.abort_step(
    identity.op_id(phase),
    identity.step_id(phase),
  )
  option.map(owned.native, fn(handle) { handle.cancel() })
  option.map(owned.socket, ffi_unix.close_now)
  ffi_unix.close_listener(owned.listener)
  process.send(owned.reader, ReadStop)
  process.send(owned.writer, WriteStop)
  sm.transition(
    to: OriginalClosing,
    data: ForegroundOwned(
      ..owned,
      outbound: run_channel.retire_direction(owned.outbound),
      close_reply: reply,
    ),
  )
  |> sm.then_handle(CheckCleanup)
}

fn record_children(
  owned: ForegroundOwned,
  event: weft.Pulled(Nil, Nil),
) -> ForegroundOwned {
  case event {
    weft.AllDelivered ->
      case owned.joined {
        Some(run_channel.TransportUnresolved(_)) -> owned
        None | Some(run_channel.TransportJoined) ->
          ForegroundOwned(..owned, joined: Some(run_channel.TransportJoined))
      }
    weft.RunLost(_) ->
      ForegroundOwned(
        ..owned,
        joined: Some(run_channel.TransportUnresolved(
          "original child scope was lost",
        )),
      )
    weft.PulledOutcome(weft.Completed(..)) | weft.NotYet -> owned
    weft.PulledOutcome(_) ->
      ForegroundOwned(
        ..owned,
        joined: Some(run_channel.TransportUnresolved(
          "an original child did not settle normally",
        )),
      )
  }
}

fn finish_original_close(
  owned: ForegroundOwned,
) -> sm.Next(ForegroundPhase, ForegroundOwned, ForegroundEvent) {
  case owned.joined, owned.settlement {
    Some(_), Some(_) -> publish_original_close(owned)
    None, _ | Some(_), None -> sm.keep(owned)
  }
}

fn publish_original_close(
  owned: ForegroundOwned,
) -> sm.Next(ForegroundPhase, ForegroundOwned, ForegroundEvent) {
  let #(node, resources) =
    option.unwrap(owned.settlement, #(
      enforcement.Unreported("original native settlement was not observed"),
      run_channel.ResourcesUnresolved(
        "original native settlement was not observed",
      ),
    ))
  let transport =
    option.unwrap(
      owned.joined,
      run_channel.TransportUnresolved("original children were not joined"),
    )
  let resources = case resources, transport {
    run_channel.ResourcesReleased, run_channel.TransportJoined -> {
      unlink(owned.config.cap_socket_path)
      owned.config.unlink_token_file(owned.config.token_path)
      run_channel.ResourcesReleased
    }
    run_channel.ResourcesReleased, run_channel.TransportUnresolved(reason) ->
      run_channel.ResourcesUnresolved(reason)
    run_channel.ResourcesUnresolved(_), _ -> resources
  }
  let closed = run_channel.CloseResult(node:, transport:, resources:)
  option.map(owned.close_reply, fn(reply) { process.send(reply, closed) })
  sm.transition(
    to: OriginalClosed(closed),
    data: ForegroundOwned(..owned, close_reply: None),
  )
}

// The node collector retains actual settlement separately from enforcement.
// A lost/failed observation never turns into physical release through DOWN.
fn foreground_node(
  config: ForegroundLaunchConfig,
  request: run_channel.LaunchRequest,
  requirements: SandboxPolicy,
  commands: Subject(ForegroundEvent),
  waiting: Int,
) -> Nil {
  let #(artifact, phase, base, demand, env, cwd) =
    run_channel.execution(request)
  let wire = process.new_subject()
  let spec =
    satellite.LaunchSpec(
      artifact:,
      token_path: config.token_path,
      cap_socket_path: config.cap_socket_path,
      identity: phase,
      base_policy: base,
      env:,
      cwd:,
      wire:,
    )
  let prepared = {
    use origin <- result.try(identity.command_origin(phase))
    use call <- result.try(node_call(
      LaunchConfig(..config.local, demand:),
      spec,
      requirements,
    ))
    Ok(#(origin, call))
  }
  case prepared {
    Error(reason) ->
      process.send(
        commands,
        NativeSettled(
          enforcement.Unreported(reason),
          run_channel.ResourcesReleased,
        ),
      )
    Ok(#(origin, call)) ->
      foreground_collect(config, origin, call, commands, waiting)
  }
}

// Only original native settlement can supply this resource disposition.
fn foreground_collect(
  config: ForegroundLaunchConfig,
  origin: Option(remote_tool.ChildOrigin),
  call: CallSpec,
  commands: Subject(ForegroundEvent),
  waiting: Int,
) -> Nil {
  let events = process.new_subject()
  case config.local.runner.clear(origin, call, events) {
    Error(refusal) ->
      process.send(
        commands,
        NativeSettled(
          enforcement.Unreported(refusal_text(refusal)),
          foreground_refusal_resources(refusal),
        ),
      )
    Ok(handle) -> {
      process.send(commands, NativeCleared(handle))
      case tool.collect_events(events, waiting:) {
        Error(Nil) ->
          process.send(
            commands,
            NativeSettled(
              enforcement.Unreported("no original native settlement"),
              run_channel.ResourcesUnresolved("no original native settlement"),
            ),
          )
        Ok(collected) -> {
          let resources = case collected.outcome {
            broker.CallExited(_)
            | broker.CallFailed(broker_exec.DegradedExecution(_)) ->
              run_channel.ResourcesReleased
            broker.CallFailed(_) ->
              run_channel.ResourcesUnresolved(
                "native failure did not prove original physical release",
              )
          }
          process.send(
            commands,
            NativeSettled(enforcement.of_call(collected.outcome), resources),
          )
        }
      }
    }
  }
}

// A lost clearance reply may leave the original ClearCall queued in the broker.
// Its asynchronous abort is not a joined native observation, so original files
// remain in custody even though this observer can finish and transport can join.
fn foreground_refusal_resources(
  refusal: broker.Refusal,
) -> run_channel.ResourceDrain {
  case refusal {
    broker.BrokerUnavailable ->
      run_channel.ResourcesUnresolved(
        "original native clearance was not observed",
      )
    broker.PolicyRefused(_)
    | broker.InvalidPolicy(_)
    | broker.BudgetRefused(_)
    | broker.MintRefused(_)
    | broker.NoHelper(_)
    | broker.OperationAborted -> run_channel.ResourcesReleased
  }
}

// One passive reader, with exact chunks and no pre-activation body buffer.
type ForegroundReadPhase {
  ReadPrepared
  ReadHeader
  ReadHeld
}

type ForegroundRead {
  ReadActivate
  ReadNext
  ReadConsumed(
    frame: run_channel.FrameRef,
    disposition: run_channel.Consumption,
  )
  ReadStop
}

type ForegroundReader {
  ForegroundReader(
    listener: Listener,
    socket: Option(Socket),
    accept_ms: Int,
    authority_ms: Int,
    events: Subject(run_channel.Event),
    owner: Subject(ForegroundEvent),
    commands: Subject(ForegroundRead),
    window: run_channel.Window,
    incarnation: run_channel.Incarnation,
  )
}

fn start_foreground_reader(
  listener: Listener,
  accept_ms: Int,
  authority_ms: Int,
  request: run_channel.LaunchRequest,
  incarnation: run_channel.Incarnation,
  owner: Subject(ForegroundEvent),
) -> Result(sm.Started(Subject(ForegroundRead)), String) {
  let #(_host, events) = run_channel.endpoint(run_channel.host(request))
  sm.new_with_initialiser(handoff_timeout_ms, fn(commands) {
    sm.initialised(
      ReadPrepared,
      ForegroundReader(
        listener:,
        socket: None,
        accept_ms:,
        authority_ms:,
        events:,
        owner:,
        commands:,
        window: run_channel.prepare_direction(incarnation, run_channel.ToHost),
        incarnation:,
      ),
    )
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.on_event(foreground_read_step)
  // Passive OTP recv waits for the original socket's EXIT on independent
  // close. Trapping that port signal wakes the blocked read instead of
  // silently ignoring a normal port exit until its authority timeout.
  |> sm.trapping_exits(True)
  |> sm.unlinked
  |> sm.start
  |> result.map_error(fn(_) { "original reader did not initialise" })
}

fn foreground_read_step(
  phase: ForegroundReadPhase,
  reader: ForegroundReader,
  event: ForegroundRead,
) -> sm.Next(ForegroundReadPhase, ForegroundReader, ForegroundRead) {
  case phase, event {
    ReadPrepared, ReadActivate -> {
      let accepted =
        ffi_unix.accept(
          reader.listener,
          int.min(reader.accept_ms, reader.authority_ms),
        )
      case accepted, run_channel.activate_direction(reader.window) {
        Ok(socket), Ok(window) -> {
          process.send(reader.owner, SocketAccepted(socket))
          sm.transition(
            to: ReadHeader,
            data: ForegroundReader(..reader, socket: Some(socket), window:),
          )
          |> sm.then_handle(ReadNext)
        }
        Error(error), _ ->
          reader_fault(reader, case error {
            ffi_unix.AcceptTimeout -> "the original satellite did not connect"
            ffi_unix.AcceptFailed(reason) -> reason
          })
        Ok(socket), Error(_) -> {
          ffi_unix.close_now(socket)
          reader_fault(reader, "original reader activation failed")
        }
      }
    }
    ReadHeader, ReadNext -> read_reserved_frame(reader)
    ReadHeld, ReadConsumed(frame, disposition) -> {
      let #(window, consumed) =
        run_channel.consume_frame(reader.window, frame, disposition)
      case consumed, disposition {
        run_channel.Ignored, _ -> sm.keep(reader)
        run_channel.Consumed, run_channel.Final -> sm.stop()
        run_channel.Consumed, run_channel.Continue ->
          sm.transition(
            to: ReadHeader,
            data: ForegroundReader(..reader, window:),
          )
          |> sm.then_handle(ReadNext)
      }
    }
    _, ReadStop -> sm.stop()
    ReadPrepared, ReadNext
    | ReadHeld, ReadNext
    | ReadHeader, ReadActivate
    | ReadHeld, ReadActivate
    | ReadPrepared, ReadConsumed(..)
    | ReadHeader, ReadConsumed(..)
    -> sm.keep(reader)
  }
}

// The fixed four-byte declaration charges the lifetime before any body read.
fn read_reserved_frame(
  reader: ForegroundReader,
) -> sm.Next(ForegroundReadPhase, ForegroundReader, ForegroundRead) {
  case reader.socket {
    None -> reader_fault(reader, "original reader has no accepted socket")
    Some(socket) -> {
      let read = {
        use prefix <- result.try(ffi_unix.recv_exact(
          socket,
          4,
          reader.authority_ms,
        ))
        use length <- result.try(case prefix {
          <<size:32>> ->
            run_channel.payload_length(size)
            |> result.map_error(fn(_) {
              "frame declaration exceeds original bound"
            })
          _ -> Error("invalid exact frame prefix")
        })
        use #(window, reservation) <- result.try(
          run_channel.reserve_frame(reader.window, length)
          |> result.map_error(fn(_) { "inbound lifetime allowance exhausted" }),
        )
        use bytes <- result.try(
          read_exact_body(
            socket,
            run_channel.length_bytes(length),
            reader.authority_ms,
            [],
          ),
        )
        use payload <- result.try(
          run_channel.finish_payload(reservation, bytes)
          |> result.map_error(fn(_) { "frame body length changed" }),
        )
        use window <- result.try(
          run_channel.publish_frame(window, reservation)
          |> result.map_error(fn(_) { "original frame reservation was lost" }),
        )
        Ok(#(window, reservation, payload))
      }
      case read {
        Error(reason) -> reader_fault(reader, reason)
        Ok(#(window, reservation, payload)) -> {
          let #(frame, _) = run_channel.reservation(reservation)
          let commands = reader.commands
          let delivery =
            run_channel.delivery(reservation, payload, fn(disposition) {
              process.send(commands, ReadConsumed(frame, disposition))
            })
          case delivery {
            Error(_) -> reader_fault(reader, "original delivery failed")
            Ok(delivery) -> {
              process.send(reader.events, run_channel.Frame(delivery))
              sm.transition(
                to: ReadHeld,
                data: ForegroundReader(..reader, window:),
              )
            }
          }
        }
      }
    }
  }
}

// This is a bounded data fold, at most 257 exact chunks, not a phase loop.
fn read_exact_body(
  socket: Socket,
  remaining: Int,
  timeout_ms: Int,
  chunks: List(BitArray),
) -> Result(BitArray, String) {
  case remaining {
    0 -> Ok(bit_array.concat(list.reverse(chunks)))
    _ -> {
      let count = int.min(remaining, run_channel.max_chunk_bytes)
      use bytes <- result.try(ffi_unix.recv_exact(socket, count, timeout_ms))
      read_exact_body(socket, remaining - count, timeout_ms, [bytes, ..chunks])
    }
  }
}

fn reader_fault(
  reader: ForegroundReader,
  reason: String,
) -> sm.Next(ForegroundReadPhase, ForegroundReader, ForegroundRead) {
  let incarnation = reader.incarnation
  process.send(reader.events, run_channel.Fault(incarnation, reason))
  option.map(reader.socket, ffi_unix.close_now)
  sm.stop()
}

// One writer process; the owner admits exact reservations before its mailbox.
type ForegroundWrite {
  WriteAttach(socket: Socket)
  WriteFrame(reservation: run_channel.Reservation, payload: run_channel.Payload)
  WriteStop
}

type ForegroundWriter {
  ForegroundWriter(
    socket: Option(Socket),
    events: Subject(run_channel.Event),
    owner: Subject(ForegroundEvent),
    incarnation: run_channel.Incarnation,
  )
}

fn start_foreground_writer(
  request: run_channel.LaunchRequest,
  incarnation: run_channel.Incarnation,
  owner: Subject(ForegroundEvent),
) -> Result(sm.Started(Subject(ForegroundWrite)), String) {
  let #(_host, events) = run_channel.endpoint(run_channel.host(request))
  sm.new_with_initialiser(handoff_timeout_ms, fn(commands) {
    sm.initialised(
      Nil,
      ForegroundWriter(socket: None, events:, owner:, incarnation:),
    )
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.on_event(foreground_write_step)
  |> sm.unlinked
  |> sm.start
  |> result.map_error(fn(_) { "original writer did not initialise" })
}

fn foreground_write_step(
  _phase: Nil,
  writer: ForegroundWriter,
  event: ForegroundWrite,
) -> sm.Next(Nil, ForegroundWriter, ForegroundWrite) {
  case event {
    WriteAttach(socket) ->
      sm.keep(ForegroundWriter(..writer, socket: Some(socket)))
    WriteStop -> sm.stop()
    WriteFrame(reservation, payload) -> {
      let wrote = case writer.socket {
        None -> Error("the original writer has no socket")
        Some(socket) ->
          write_exact_chunks(socket, run_channel.wire_bytes(payload))
      }
      case wrote {
        Error(reason) -> {
          process.send(
            writer.events,
            run_channel.Fault(writer.incarnation, reason),
          )
          sm.stop()
        }
        Ok(Nil) -> {
          let #(frame, _length) = run_channel.reservation(reservation)
          process.send(writer.owner, WriterConsumed(frame))
          sm.keep(writer)
        }
      }
    }
  }
}

fn write_exact_chunks(socket: Socket, bytes: BitArray) -> Result(Nil, String) {
  let chunk_bytes = run_channel.max_chunk_bytes
  case bytes {
    <<>> -> Ok(Nil)
    <<chunk:bytes-size(chunk_bytes), rest:bits>> -> {
      use Nil <- result.try(ffi_unix.send(socket, chunk))
      write_exact_chunks(socket, rest)
    }
    _ -> ffi_unix.send(socket, bytes)
  }
}

fn launch(
  config: LaunchConfig,
  spec: LaunchSpec,
) -> Result(CapConnection, String) {
  use _ <- result.try(check_budget(identity.pooled_budget(spec.identity)))
  let #(now, _clock) = clock.read(config.clock)
  use requirements <- result.try(node_requirements(
    spec,
    host_mounts: config.host_mounts,
    now_ms: now,
  ))
  use effective <- result.try(composed_policy(
    spec.base_policy,
    requirements,
    identity.grants(spec.identity),
  ))
  use _ <- result.try(path_reachable(
    effective,
    spec.cap_socket_path,
    "the cap socket",
  ))
  use _ <- result.try(path_reachable(
    effective,
    spec.token_path,
    "the cap token file",
  ))
  use _ <- result.try(private_directory(directory_of(spec.cap_socket_path)))

  // The kernel truncates nothing and rejects instead: an AF_UNIX bind
  // address longer than the platform's sun_path limit fails with einval,
  // which reads as a kernel fault when the real problem is a workspace
  // (or test scratch) sitting too deep. Name it before listen can see it.
  // The budget mirrors client/codemode's guard, chosen once so both layers
  // tell the same story.
  use _ <- result.try(
    case socket_path_bytes(spec.cap_socket_path) > max_socket_path_bytes {
      False -> Ok(Nil)
      True ->
        Error(
          "the cap socket would be "
          <> spec.cap_socket_path
          <> ", which is longer than the 100 bytes a unix socket path may "
          <> "have; run the session from a shallower workspace",
        )
    },
  )
  use listener <- result.try(
    result.map_error(ffi_unix.listen(spec.cap_socket_path), fn(reason) {
      "could not listen on the cap socket: " <> reason
    }),
  )
  start_channel(config, spec, requirements, listener, now)
}

// Everything from here on owns a live listener, so every failure path
// closes it and unlinks the socket file rather than returning.
fn start_channel(
  config: LaunchConfig,
  spec: LaunchSpec,
  requirements: SandboxPolicy,
  listener: Listener,
  now: Int,
) -> Result(CapConnection, String) {
  let writer_handoff = process.new_subject()
  let _writer =
    process.spawn_unlinked(fn() { writer_main(listener, writer_handoff) })
  case process.receive(writer_handoff, handoff_timeout_ms) {
    Error(Nil) -> {
      ffi_unix.close_listener(listener)
      unlink(spec.cap_socket_path)
      Error("the cap-socket writer did not start")
    }
    Ok(outbox) ->
      start_reader(config, spec, requirements, listener, outbox, now)
  }
}

fn start_reader(
  config: LaunchConfig,
  spec: LaunchSpec,
  requirements: SandboxPolicy,
  listener: Listener,
  outbox: Subject(Out),
  now: Int,
) -> Result(CapConnection, String) {
  let reader_handoff = process.new_subject()
  let _reader =
    process.spawn_unlinked(fn() {
      reader_main(
        listener,
        outbox,
        spec.wire,
        config.accept_timeout_ms,
        reader_handoff,
      )
    })
  case process.receive(reader_handoff, handoff_timeout_ms) {
    Error(Nil) -> {
      process.send(outbox, Shutdown)
      unlink(spec.cap_socket_path)
      Error("the cap-socket reader did not start")
    }
    Ok(exits) -> {
      let settlement = start_reporter()
      spawn_node(config, spec, requirements, exits, settlement, now)
      start_janitor(config, spec, outbox, settlement)
      Ok(
        satellite.CapConnection(
          send: fn(bytes) { process.send(outbox, Emit(bytes:)) },
          destroy: fn() { destroy(config, spec, outbox, settlement) },
        ),
      )
    }
  }
}

// Destroying the satellite: abort the run phase's own step (which revokes
// its tokens and kills the node and every executor it fanned out), collect
// what the kernel enforced on the node, close both ends of the socket, and
// unlink the socket file. Idempotent — the host calls it once on every exit
// path, and `satellite.hand_over` may call it instead.
//
// The abort is what makes the report *reachable* rather than what loses
// it: a node that has already exited has already settled, and a node still
// running settles because the abort cancels it, which the helper answers
// with an `exec_exit` carrying the same report. So destroy aborts, then
// waits (bounded) for the settlement, and hands the report to the caller —
// which is the host, about to report the execution's outcome (issue #5).
//
// The sweep is `abort_step` rather than `abort` because a teardown reaps
// its own batch and must not reap what the program asked to outlive it. A
// background job the program started clears under `{op_id, "job/" <> id}`,
// a sibling step of the same operation, and an operation-wide abort
// cancelled its helper the moment the program returned — the record read
// `Lost(HelperLoss)` against a design note that promises a job keeps
// running under its own token. An operator's `abort` of the operation
// still reaches that job (`client/gateway.abort`), which is the semantics
// the shared operation was chosen for.
//
// The step being swept is the tool *batch's*, since that is what
// `tool.Ctx` carries and what the run phase's identity is minted from. So
// a sibling call of the same batch — a foreground `bash`, a second
// program — is still reaped here, as it was under the operation-wide
// abort this replaced. What the narrowing buys is the sibling *step*, and
// the job is the only caller that has one.
fn destroy(
  config: LaunchConfig,
  spec: LaunchSpec,
  outbox: Subject(Out),
  settlement: Subject(Settlement),
) -> Report {
  config.runner.abort_step(
    identity.op_id(spec.identity),
    identity.step_id(spec.identity),
  )
  let report = await_report(settlement)
  process.send(outbox, Shutdown)
  unlink(spec.cap_socket_path)
  report
}

// --- the node's enforcement report ---------------------------------------

// The node's lifecycle, held for whoever destroys the connection.
//
// A plain subject would not do: the collector, the host actor, and the
// janitor are three different processes, and a subject is received on only
// by its owner. This is a tiny holder machine instead — a
// `weft/state_machine`, so the states below are an ADT every event is
// dispatched against exhaustively rather than a tuple of loop arguments.
// It does two things no shared mailbox could:
//
// - It **remembers** the one settlement the collector produced, so a
//   second `destroy` — the janitor's, after the host's — is answered from
//   memory rather than left waiting for a settlement that already
//   happened.
// - It **orders teardown against the clearance**. `destroy` may run before
//   the node's `clear_call` has even returned, and an `abort` that arrives
//   first cancels nothing: the node would then run on to its jail's wall
//   limit, and no settlement — so no report — would ever arrive. The
//   holder knows both events, so it cancels whichever arrives second and
//   the node settles either way.
type Settlement {
  /// The node's clearance succeeded; this is the handle to cancel it by.
  Cleared(handle: physical.RunningCall)

  /// The node settled, and this is what its helper reported.
  Settled(report: Report)

  /// Someone is tearing the node down and wants its report.
  Ask(reply: Subject(Report))
}

// Where the node has got to, from the holder's point of view.
//
// This is the machine's *state*, and only this: what cancels the holder's
// lingering deadline is a change of state, and what replays a postponed
// `Ask` is a change of state. The teardown fact stays in `Holder` because
// changing it must neither cancel the lingering deadline nor replay asks.
type NodeState {
  /// The clearance has not come back yet.
  Pending

  /// Cleared and running under this handle.
  Running(handle: physical.RunningCall)

  /// Settled, with the report to hand out.
  Done(report: Report)
}

// Whether teardown has reached the holder yet.
//
// An `Ask` is the teardown: nobody asks for the report except a `destroy`
// on its way out. Two named variants rather than a bare flag, because the
// two arms that read it read it for opposite reasons — the clearance
// cancels a node nobody wants any more, and the settlement arms the
// deadline that ends a holder nobody will ask again.
type Teardown {
  /// No `destroy` has been through; the execution still owns the node.
  Intact

  /// A `destroy` has been through, so the node is on its way out.
  TornDown
}

// What the holder carries across its states, unchanged by any of them.
type Holder {
  Holder(
    /// Whether a `destroy` has already asked for the report.
    teardown: Teardown,
  )
}

// Every event the holder handles.
//
// The machine's message type is wider than the settlement protocol, so
// that `Linger` exists at all: the holder's own deadline is not something
// a sender could produce, and wrapping keeps it that way. The subject
// handed out is a `Subject(Settlement)` mapped into this, so no process
// outside the holder can forge a deadline it never armed.
type Held {
  /// One settlement, from the collector or from a `destroy`.
  Incoming(settlement: Settlement)

  /// The lingering deadline on `Done` expired; nobody else is coming.
  Linger
}

// The holder is deliberately **unlinked** from whoever launched the
// satellite: it has to outlive the host so the janitor's second `destroy`
// is answered from memory rather than left waiting on a settlement that
// already happened. weft's `unlinked` is that arrangement made a setting.
//
// The subject the machine returns is the one it built for itself, not the
// default weft would have given it: the default carries the machine's own
// `Held`, and what every sender in this module holds is a
// `Subject(Settlement)`.
fn start_reporter() -> Subject(Settlement) {
  let started =
    sm.new_with_initialiser(handoff_timeout_ms, fn(_default) {
      let inbox = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select_map(inbox, Incoming)
      sm.initialised(Pending, Holder(teardown: Intact))
      |> sm.selecting(selector)
      |> sm.returning(inbox)
      |> Ok
    })
    |> sm.on_event(reporter_step)
    |> sm.unlinked
    |> sm.start
  case started {
    Ok(machine) -> machine.data

    // A holder that would not start is a report nobody can collect; the
    // ask then times out and says so, which is the honest answer.
    Error(_error) -> process.new_subject()
  }
}

// One event, in one state.
//
// The pairs are exhaustive by construction: a fourth `Settlement` or a
// fourth node state is a compile error here rather than a message the
// holder silently drops.
fn reporter_step(
  node: NodeState,
  holder: Holder,
  event: Held,
) -> sm.Next(NodeState, Holder, Held) {
  case node, event {
    // An ask before the clearance has come back needs no pending list:
    // weft holds the event and replays it on the transition to `Done`, in
    // arrival order, where the arm below answers it. The teardown fact is
    // recorded first because the `Cleared` arm reads it to decide whether
    // the node it just learned about is already unwanted.
    Pending, Incoming(Ask(..)) -> mark_torn_down(holder) |> sm.postpone

    // Teardown while the node runs. The cancel goes out *before* the ask
    // is postponed because it is what makes the settlement the ask waits
    // for ever arrive: the helper answers a cancel with an `exec_exit`
    // carrying the same enforcement report.
    Running(handle:), Incoming(Ask(..)) -> {
      handle.cancel()
      mark_torn_down(holder) |> sm.postpone
    }

    // The report is in hand, so the ask is answered from memory. Arming
    // the deadline again here is what re-starts it for the next asker:
    // `keep` is not a state change, so the timeout survives, and arming
    // replaces the pending one rather than adding a second.
    Done(report:), Incoming(Ask(reply:)) -> {
      process.send(reply, report)
      linger(mark_torn_down(holder))
    }

    // Teardown got here first, so its cancel had nothing to name. Now it
    // does.
    Pending, Incoming(Cleared(handle:)) -> {
      case holder.teardown {
        Intact -> Nil
        TornDown -> handle.cancel()
      }
      sm.transition(to: Running(handle:), data: holder)
    }

    // A clearance is sent exactly once, by the one process that made the
    // call, and can only find the holder `Pending`: `Running` is the state
    // it produces itself and `Done` is downstream of it. Unreachable by
    // construction.
    Running(..), Incoming(Cleared(..)) | Done(..), Incoming(Cleared(..)) ->
      sm.keep(holder)

    // The node settled. Every ask postponed while it ran is replayed by
    // this transition, ahead of the mailbox and in arrival order, and each
    // is answered by the `Done` arm above — which is exactly what the
    // holder's old hand-kept `waiting` list did. The deadline is armed
    // only when teardown has already been through; a holder nobody has
    // asked yet still has an execution to serve and must not time out.
    Pending, Incoming(Settled(report:))
    | Running(..), Incoming(Settled(report:))
    -> {
      let settled = sm.transition(to: Done(report:), data: holder)
      case holder.teardown {
        Intact -> settled
        TornDown -> linger(settled)
      }
    }

    // Likewise settled twice: the collector sends one settlement and then
    // stops collecting. Unreachable by construction.
    Done(..), Incoming(Settled(..)) -> sm.keep(holder)

    // The second `destroy` never came. The report has been handed over and
    // the execution is over, so the holder ends here rather than outliving
    // every execution the session ever ran.
    Done(..), Linger -> sm.stop()

    // The deadline is armed only on `Done`, which the holder never leaves,
    // so no fire can reach these two states — weft's timer book drops a
    // fire that raced its own cancellation rather than delivering it.
    Pending, Linger | Running(..), Linger -> sm.keep(holder)
  }
}

// Record that a `destroy` has been through, without moving the node on: an
// ask says the execution is over whatever state the node itself reached.
fn mark_torn_down(_holder: Holder) -> sm.Next(NodeState, Holder, Held) {
  sm.keep(Holder(teardown: TornDown))
}

// Arm the holder's last deadline.
//
// Once the node has settled, the report has been handed over, and teardown
// has been through, the only event still worth waiting for is a second
// `destroy` — the janitor's, right behind the host's. A *state* timeout is
// what bounds that wait honestly: it belongs to `Done`, which the holder
// never leaves, so the holder ends when the deadline expires instead of
// lingering for the life of the session.
fn linger(
  step: sm.Next(NodeState, Holder, Held),
) -> sm.Next(NodeState, Holder, Held) {
  sm.with_state_timeout(step, after: node_report_wait_ms, sending: Linger)
}

fn await_report(settlement: Subject(Settlement)) -> Report {
  let reply = process.new_subject()
  process.send(settlement, Ask(reply:))
  case process.receive(reply, node_report_wait_ms) {
    Ok(report) -> report
    Error(Nil) ->
      enforcement.Unreported(
        "its helper did not report within "
        <> int.to_string(node_report_wait_ms)
        <> "ms of teardown",
      )
  }
}

// The safety net for a host that never gets to clean up.
//
// The host's own teardown runs *inside* the host actor, so a host killed
// from outside — a supervisor shutdown, a kill signal — takes its `destroy`
// with it and leaves the node running, the socket bound, and the token file
// on disk (M4 triage CH-F3(b)). This mirrors the broker's fd-3 janitor: an
// unlinked process monitoring the actor, running the same teardown when it
// dies, however it died.
//
// `LaunchSpec.wire` is owned by the host actor, so its owner *is* the pid to
// watch. Running on an ordinary teardown too is harmless: abort is
// idempotent, the writer is already gone, and the unlinks are no-ops.
fn start_janitor(
  config: LaunchConfig,
  spec: LaunchSpec,
  outbox: Subject(Out),
  settlement: Subject(Settlement),
) -> Nil {
  case process.subject_owner(spec.wire) {
    Error(Nil) -> Nil
    Ok(host) -> {
      process.spawn_unlinked(fn() {
        run_janitor(config, spec, outbox, settlement, host)
      })
      Nil
    }
  }
}

fn run_janitor(
  config: LaunchConfig,
  spec: LaunchSpec,
  outbox: Subject(Out),
  settlement: Subject(Settlement),
  host: Pid,
) -> Nil {
  let monitor = process.monitor(host)
  let down =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_down) { Nil })
  let _ = process.selector_receive_forever(down)

  // Nobody is left to carry the report: the host that would have reported
  // the outcome is the process that just died.
  let _report = destroy(config, spec, outbox, settlement)

  // The token file is the host's to unlink, and a killed host will not do
  // it. A leaked token is not a disclosure — its directory is mode 0700 —
  // but it is a leak.
  unlink(spec.token_path)
}

// --- the writer process ---------------------------------------------------

// The outbound side of the cap socket.
type Out {
  /// The reader accepted a connection; adopt it and flush what buffered.
  Attach(socket: Socket)

  /// One encoded frame from the host.
  Emit(bytes: BitArray)

  /// Teardown: close the connection and the listener.
  Shutdown
}

fn writer_main(listener: Listener, handoff: Subject(Subject(Out))) -> Nil {
  let outbox = process.new_subject()
  process.send(handoff, outbox)
  writer_loop(listener, outbox, None, [])
}

fn writer_loop(
  listener: Listener,
  outbox: Subject(Out),
  socket: Option(Socket),
  pending: List(BitArray),
) -> Nil {
  case process.receive_forever(outbox) {
    Attach(socket: attached) -> {
      list.each(list.reverse(pending), fn(bytes) { write(attached, bytes) })
      writer_loop(listener, outbox, Some(attached), [])
    }
    Emit(bytes:) ->
      case socket {
        // Frames the host emitted before the satellite connected buffer
        // here rather than being dropped; the host's own `pending_out`
        // covers only what it emits before `Connected`.
        None -> writer_loop(listener, outbox, socket, [bytes, ..pending])
        Some(open) -> {
          write(open, bytes)
          writer_loop(listener, outbox, socket, pending)
        }
      }
    Shutdown -> {
      case socket {
        Some(open) -> ffi_unix.close(open)
        None -> Nil
      }
      ffi_unix.close_listener(listener)
    }
  }
}

// A failed write is the channel dying, which the reader reports as a close;
// there is nothing useful to do with the error here.
fn write(socket: Socket, bytes: BitArray) -> Nil {
  let _ = ffi_unix.send(socket, bytes)
  Nil
}

// --- the reader process ---------------------------------------------------

fn reader_main(
  listener: Listener,
  outbox: Subject(Out),
  wire: Subject(satellite.WireIn),
  accept_timeout_ms: Int,
  handoff: Subject(Subject(String)),
) -> Nil {
  let exits = process.new_subject()
  process.send(handoff, exits)
  accept_loop(listener, outbox, wire, exits, accept_timeout_ms)
}

// Polls the accept so a node that died before connecting is noticed as a
// death rather than as a timeout. `poll.until` owns the wall-clock budget
// and the sleep between attempts; there is deliberately almost none of
// the latter (`every: 1`) because the real wait already happens inside
// `accept_attempt`, which blocks in the FFI call for one slice at a time.
fn accept_loop(
  listener: Listener,
  outbox: Subject(Out),
  wire: Subject(satellite.WireIn),
  exits: Subject(String),
  accept_timeout_ms: Int,
) -> Nil {
  case
    poll.until(within: accept_timeout_ms, every: 1, attempt: fn() {
      accept_attempt(listener, exits)
    })
  {
    poll.Answered(socket) -> {
      process.send(outbox, Attach(socket:))
      read_loop(socket, wire, exits)
    }
    poll.Failed(reason) -> close_wire(wire, reason)
    poll.Expired ->
      close_wire(wire, "the satellite never connected to the cap socket")
  }
}

// One slice of the accept poll. The node's own exit is checked *before*
// the accept, non-blockingly, so a node that died between slices is
// reported as a death on the very next attempt rather than waiting out
// the rest of the budget only to time out — the distinction
// `retry_or_give_up` used to draw by giving up early is drawn here by
// answering `Fail` instead of `Retry`. Finding nothing yet blocks in
// `ffi_unix.accept` for up to `accept_poll_ms`, which is what stands in
// for the sleep between polls.
fn accept_attempt(
  listener: Listener,
  exits: Subject(String),
) -> poll.Attempt(Socket, String) {
  case process.receive(exits, 0) {
    Ok(reason) -> poll.Fail(reason)
    Error(Nil) ->
      case ffi_unix.accept(listener, accept_poll_ms) {
        Ok(socket) -> poll.Done(socket)
        Error(ffi_unix.AcceptTimeout) -> poll.Retry
        Error(ffi_unix.AcceptFailed(reason:)) ->
          poll.Fail(
            "the cap socket faulted before the satellite connected: " <> reason,
          )
      }
  }
}

fn read_loop(
  socket: Socket,
  wire: Subject(satellite.WireIn),
  exits: Subject(String),
) -> Nil {
  case ffi_unix.recv(socket) {
    Ok(bytes) -> {
      process.send(wire, satellite.WireBytes(data: bytes))
      read_loop(socket, wire, exits)
    }

    // End of stream. The node's own exit status says far more than "the
    // peer closed", so wait briefly for it before reporting.
    Error(reason) ->
      case process.receive(exits, exit_reason_wait_ms) {
        Ok(diagnosis) -> close_wire(wire, diagnosis)
        Error(Nil) -> close_wire(wire, reason)
      }
  }
}

fn close_wire(wire: Subject(satellite.WireIn), reason: String) -> Nil {
  process.send(wire, satellite.WireClosed(reason:))
}

// --- the node ------------------------------------------------------------

// Dispatches the jailed `erl` and collects its settlement off the host's
// timeline, reporting the outcome to the reader as a close reason.
fn spawn_node(
  config: LaunchConfig,
  spec: LaunchSpec,
  requirements: SandboxPolicy,
  exits: Subject(String),
  settlement: Subject(Settlement),
  now: Int,
) -> Nil {
  let deadline_ms = identity.pooled_budget(spec.identity).deadline_ms
  let waiting = int.max(deadline_ms - now, 0) + settle_margin_ms
  process.spawn_unlinked(fn() {
    let prepared = {
      use origin <- result.try(identity.command_origin(spec.identity))
      use call <- result.try(node_call(config, spec, requirements))
      Ok(#(origin, call))
    }
    case prepared {
      Ok(#(origin, call)) ->
        run_node(config, origin, call, exits, settlement, waiting)
      Error(reason) -> {
        process.send(settlement, Settled(enforcement.Unreported(reason)))
        process.send(exits, reason)
      }
    }
  })
  Nil
}

fn run_node(
  config: LaunchConfig,
  origin: Option(remote_tool.ChildOrigin),
  call: CallSpec,
  exits: Subject(String),
  settlement: Subject(Settlement),
  waiting: Int,
) -> Nil {
  let events = process.new_subject()
  case config.runner.clear(origin, call, events) {
    Error(refusal) -> report_refused(exits, settlement, refusal)
    Ok(handle) -> {
      process.send(settlement, Cleared(handle:))
      collect_node_result(exits, settlement, events, waiting)
    }
  }
}

fn report_refused(
  exits: Subject(String),
  settlement: Subject(Settlement),
  refusal: broker.Refusal,
) -> Nil {
  process.send(
    settlement,
    Settled(report: enforcement.Unreported("it was refused before it ran")),
  )
  process.send(
    exits,
    "the satellite node was refused before launch: " <> refusal_text(refusal),
  )
}

fn collect_node_result(
  exits: Subject(String),
  settlement: Subject(Settlement),
  events: Subject(broker.CallEvent),
  waiting: Int,
) -> Nil {
  case tool.collect_events(events, waiting:) {
    Ok(collected) -> {
      process.send(
        settlement,
        Settled(report: enforcement.of_call(collected.outcome)),
      )
      process.send(exits, exit_text(collected))
    }
    Error(Nil) -> {
      process.send(
        settlement,
        Settled(report: enforcement.Unreported(
          "it produced no settlement, so its helper never reported",
        )),
      )
      process.send(exits, "the satellite node produced no settlement")
    }
  }
}

/// The clearance that launches the node: the same `{op_id, step_id}` the
/// host services cap calls under, so `broker.abort_step` reaches it, and the
/// same approved grants `launch` already composed the effective policy
/// with.
///
/// Both come off the run phase's identity. Reading them from one place
/// is what keeps this call and the composition check below in agreement:
/// a node cleared under grants the pre-check did not apply would be
/// running in a jail nobody checked, and one cleared without grants the
/// pre-check did apply would be refused by the broker for a shortfall the
/// launch had already satisfied.
///
/// ## Examples
///
/// ```gleam
/// let call = launch.node_call(local_config, local_spec, requirements)
/// // Executor artifacts return Error before a local command exists.
/// ```
pub fn node_call(
  config: LaunchConfig,
  spec: LaunchSpec,
  requirements: SandboxPolicy,
) -> Result(CallSpec, String) {
  use argv <- result.try(node_argv(config.erl_path, spec.artifact))
  Ok(broker.CallSpec(
    op_id: identity.op_id(spec.identity),
    step_id: identity.step_id(spec.identity),
    base_policy: spec.base_policy,
    requirements:,
    grants: identity.grants(spec.identity),
    // The launch already composed and checked this policy; refusing a
    // narrowing here means the broker disagreed, and a satellite in a
    // weaker jail than the one that was checked must not run.
    response: broker.RefuseNarrowed,
    demand: config.demand,
    argv:,
    env: node_env(spec),
    cwd: spec.cwd,
    budget: identity.pooled_budget(spec.identity),
  ))
}

/// The node's argv: distribution off, no epmd, no node name, booting the
/// artifact's generated entry.
///
/// `-s init stop` closes the node once the entry returns — `-run` alone
/// leaves a `-noshell` node idling until its deadline, and the whole point
/// is that the node dies with the program. An executor artifact is refused
/// rather than encoded as a local `-pa` argument.
///
/// ## Examples
///
/// ```gleam
/// let local = compile.Artifact("/b", "/b/ebin", "entry", "hash")
/// let assert Ok(argv) = launch.node_argv("/usr/bin/erl", local)
/// assert list.contains(argv, "/b/ebin")
/// ```
pub fn node_argv(
  erl_path: String,
  artifact: Artifact,
) -> Result(List(String), String) {
  use beam_dir <- result.try(local_beam_dir(artifact))
  Ok(native_command.node_argv(
    erl_path,
    beam_dir,
    compile.artifact_entry(artifact),
  ))
}

/// The node's environment: the two cap-channel handles the boot runtime
/// reads, plus whatever the execution's policy already permits.
///
/// Allowlist-constructed, never inherited, and the two handles are set
/// here — a caller's `env` cannot shadow them into pointing a satellite at
/// somebody else's socket or token.
pub fn node_env(spec: LaunchSpec) -> List(#(String, String)) {
  native_command.node_env(spec.cap_socket_path, spec.token_path, spec.env)
}

/// What the jailed node requires of the session base: the toolchain and
/// the build seed mounted read-only, the socket, token and `.beam`
/// directories readable, the network off, the two cap handles in the
/// environment allowlist, and a wall limit no longer than what is left of
/// the pooled deadline.
///
/// Nothing here widens the base — composition takes the meet — so a base
/// that cannot cover one of these produces a narrowing, which the launch
/// reports as an in-band refusal.
///
/// `host_mounts` is an argument rather than a field of the spec because
/// only the host knows where it found a toolchain, and because the *same*
/// list has to reach the session base: a mount survives the meet only when
/// both sides carry it, so a base built from a different list would strip
/// the toolchain out of the policy the node runs under.
///
/// **Why the socket, the token and `beam_dir` are still roots and not
/// mounts.** All three are per-execution paths: the socket and token live
/// under an execution directory this launch just made, and `beam_dir` is
/// where the hermetic build put its output. A session base is built once,
/// before any of them exist, so it cannot name them; requiring them as
/// mounts would narrow every launch. Under `protocol-change/020` they are
/// covered by the workspace mount the base derives from the admission
/// record, which is a statement the base makes and this function does not.
/// No local requirements can be derived from an executor artifact reference.
///
/// ## Examples
///
/// ```gleam
/// let requirements = launch.node_requirements(local_spec, [], now)
/// // A remote artifact produces Error before any physical effect.
/// ```
pub fn node_requirements(
  spec: LaunchSpec,
  host_mounts host_mounts: List(Mount),
  now_ms now_ms: Int,
) -> Result(SandboxPolicy, String) {
  use beam_dir <- result.try(local_beam_dir(spec.artifact))
  Ok(
    native_command.node_requirements(native_command.NodeAccess(
      beam_dir:,
      socket_path: spec.cap_socket_path,
      token_path: spec.token_path,
      base: spec.base_policy,
      mounts: host_mounts,
      env: spec.env,
      wall_s: bound_wall(
        spec.base_policy.limits.wall_s,
        remaining_seconds(spec, now_ms),
      ),
    )),
  )
}

// A remote artifact has an issued identity, never a local filesystem path.
// Reject it before policy construction, socket creation or physical clearance.
fn local_beam_dir(artifact: Artifact) -> Result(String, String) {
  case artifact {
    compile.Artifact(beam_dir:, ..) -> Ok(beam_dir)
    compile.ExecutorArtifact(..) ->
      Error("the local launcher cannot resolve an executor artifact")
  }
}

// Seconds left of the pooled wall deadline, rounded up and never zero —
// zero means "no limit" on the wire, which is the opposite of what an
// exhausted deadline should say.
fn remaining_seconds(spec: LaunchSpec, now_ms: Int) -> Int {
  let deadline_ms = identity.pooled_budget(spec.identity).deadline_ms
  int.max({ int.max(deadline_ms - now_ms, 0) + 999 } / 1000, 1)
}

// A base wall of zero is "no limit", so the deadline is the only bound;
// otherwise take the tighter of the two.
fn bound_wall(base_wall_s: Int, remaining_s: Int) -> Int {
  case base_wall_s {
    0 -> remaining_s
    other -> int.min(other, remaining_s)
  }
}

// --- policy checks -------------------------------------------------------

fn check_budget(pooled: Budget) -> Result(Nil, String) {
  case pooled.max_outstanding >= minimum_outstanding {
    True -> Ok(Nil)
    False ->
      Error(
        "the pooled budget allows "
        <> int.to_string(pooled.max_outstanding)
        <> " outstanding effects; the satellite node itself holds one, so a "
        <> "code-mode execution needs at least "
        <> int.to_string(minimum_outstanding),
      )
  }
}

// The effective policy the node will actually run under, or the reason
// the session base cannot host one.
//
// This is the launch policy composition — the site an approval has to
// reach for a widened re-run to mean anything. `base ⊕ requirements ⊕
// grants` is the broker's own rule; running it here first is a pre-check,
// so that a base which cannot host a node is refused in band with the
// exact shortfall named rather than dying somewhere inside a jail. The
// grants are therefore not decoration: without them the pre-check would
// refuse a launch the broker would then have cleared, and the approval
// would be spent on a call this function had already turned away.
//
// Grants only ever widen, so the reachability checks that run on the
// result of this stay sound: a path the unwidened policy covered is still
// covered, and one it did not may now be, which is the whole point.
fn composed_policy(
  base: SandboxPolicy,
  requirements: SandboxPolicy,
  grants: List(Grant),
) -> Result(SandboxPolicy, String) {
  let #(effective, narrowings) = policy.compose(base:, requirements:, grants:)
  case narrowings {
    [] -> Ok(effective)
    shortfalls ->
      Error(
        "the session base cannot host a satellite node: "
        <> string.join(list.map(shortfalls, narrowing_text), "; "),
      )
  }
}

/// Whether `path` is actually reachable inside a jail built from `policy`.
///
/// The three ways it is not, none of which the policy vocabulary can state
/// positively: the path is relative (the wire requires absolute paths);
/// it sits under a `protected` entry, which bwrap shadows; or it sits
/// under the scratch tmpfs mount, which hides whatever the host had there.
/// A path no root covers is reported too — under today's ro-bound host
/// root it would still be readable, but relying on that is exactly the
/// implicitness this check exists to remove.
pub fn path_reachable(
  effective: SandboxPolicy,
  path: String,
  what: String,
) -> Result(Nil, String) {
  use _ <- result.try(refuse_relative(path, what))
  use _ <- result.try(refuse_protected(effective, path, what))
  use _ <- result.try(refuse_scratch_shadow(effective, path, what))
  refuse_uncovered(effective, path, what)
}

// The wire requires absolute paths; a relative one would be resolved
// against the jail's cwd, which is not where the host put anything.
fn refuse_relative(path: String, what: String) -> Result(Nil, String) {
  case string.starts_with(path, "/") {
    True -> Ok(Nil)
    False -> Error(what <> " path " <> path <> " is not absolute")
  }
}

// bwrap shadows a protected path: an existing file with a read-only bind
// of itself, a directory or a missing path with an empty read-only tmpfs.
fn refuse_protected(
  effective: SandboxPolicy,
  path: String,
  what: String,
) -> Result(Nil, String) {
  case
    list.find(effective.protected, fn(root) { policy.covers(root:, path:) })
  {
    Error(Nil) -> Ok(Nil)
    Ok(root) ->
      Error(
        what
        <> " at "
        <> path
        <> " is under the protected path "
        <> root
        <> ", which the jail masks",
      )
  }
}

// A tmpfs scratch is mounted over `scratch_mount`, so whatever the host
// had under it is simply not in the jail's filesystem.
fn refuse_scratch_shadow(
  effective: SandboxPolicy,
  path: String,
  what: String,
) -> Result(Nil, String) {
  case
    effective.scratch == policy.ScratchTmpfs
    && policy.covers(root: scratch_mount, path:)
  {
    False -> Ok(Nil)
    True ->
      Error(
        what
        <> " at "
        <> path
        <> " is under "
        <> scratch_mount
        <> ", which the jail replaces with the scratch tmpfs",
      )
  }
}

// Under today's ro-bound host root an uncovered path would still be
// readable, but relying on that is exactly the implicitness these checks
// exist to remove.
fn refuse_uncovered(
  effective: SandboxPolicy,
  path: String,
  what: String,
) -> Result(Nil, String) {
  let directory = directory_of(path)
  let roots = list.append(effective.readable_roots, effective.writable_roots)
  case list.any(roots, fn(root) { policy.covers(root:, path: directory) }) {
    True -> Ok(Nil)
    False ->
      Error(
        what <> " at " <> path <> " is under no root the composed policy admits",
      )
  }
}

fn directory_of(path: String) -> String {
  filepath.directory_name(path)
}

// --- filesystem ----------------------------------------------------------

// The cap socket lives in its own mode-0700 directory, so nothing else on
// the host can even reach the socket to connect to it. Mirrors the token
// file's discipline in `satellite.private_token_writer`.
fn private_directory(directory: String) -> Result(Nil, String) {
  use _ <- result.try(
    simplifile.create_directory_all(directory)
    |> file_error("create the cap socket directory"),
  )
  simplifile.set_permissions_octal(for_file_at: directory, to: 0o700)
  |> file_error("lock down the cap socket directory")
}

fn unlink(path: String) -> Nil {
  let _ = simplifile.delete(path)
  Nil
}

fn file_error(
  outcome: Result(a, simplifile.FileError),
  what: String,
) -> Result(a, String) {
  result.map_error(outcome, fn(error) {
    "could not " <> what <> ": " <> simplifile.describe_error(error)
  })
}

// --- diagnostics ---------------------------------------------------------

// How the node ended, as the close reason the host reports when no
// terminal `outcome` frame arrived first.
fn exit_text(collected: Collected) -> String {
  case collected.outcome {
    broker.CallExited(result:) ->
      case result.timed_out {
        True -> "the satellite node hit its wall limit and was killed"
        False ->
          "the satellite node exited with code "
          <> int.to_string(result.code)
          <> stderr_tail(collected)
      }
    broker.CallFailed(failure:) ->
      "the satellite node failed: " <> tool.exec_failure_text(failure)
  }
}

// A node that died on a boot error says why on stderr; carrying a little
// of it turns "the satellite is gone" into something actionable.
fn stderr_tail(collected: Collected) -> String {
  case bit_array_text(collected.stderr) {
    "" -> ""
    text -> ": " <> string.slice(string.trim(text), at_index: 0, length: 400)
  }
}

// The socket path's UTF-8 length in bytes — what the kernel's sun_path
// limit actually counts, not the character count.
fn socket_path_bytes(path: String) -> Int {
  bit_array.byte_size(<<path:utf8>>)
}

fn bit_array_text(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) -> ""
  }
}

fn refusal_text(refusal: broker.Refusal) -> String {
  case refusal {
    broker.PolicyRefused(denial:) -> "policy refused: " <> denial.reason
    broker.InvalidPolicy(error: _) -> "the composed policy is invalid"
    broker.BudgetRefused(refusal: _) -> "the pooled budget refused it"
    broker.MintRefused(error: _) -> "the broker could not mint a token"
    broker.NoHelper(error: _) -> "no sandbox helper was available"
    broker.OperationAborted -> "the operation was aborted"
    broker.BrokerUnavailable -> "the tool broker is unavailable"
  }
}

fn narrowing_text(narrowing: Narrowing) -> String {
  case narrowing {
    policy.NarrowedWritableRoot(path:) -> "writable root " <> path
    policy.NarrowedReadableRoot(path:) -> "readable root " <> path
    policy.NarrowedNetwork(wanted: _, granted: _) -> "network policy"
    policy.NarrowedEnv(name:) -> "environment variable " <> name
    policy.NarrowedLimit(field: _, wanted:, granted:) ->
      "limit "
      <> int.to_string(wanted)
      <> " (granted "
      <> int.to_string(granted)
      <> ")"
    policy.NarrowedScratch(wanted: _) -> "scratch area"

    // Named by path rather than by the whole mount, because this text
    // reaches an operator reading a refusal and the path is the part
    // they would act on. There is no grant that adds a mount, so this
    // narrowing is the end of the matter for the session.
    policy.NarrowedMount(wanted:) ->
      "mount " <> wanted.path <> ", which the session base does not carry"
  }
}
