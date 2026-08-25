//// The production satellite launcher — the `codemode/satellite.Launcher`
//// that turns a `LaunchSpec` into a real jailed `erl` node on the far end
//// of a real AF_UNIX capability socket (design §6.3 "Layer two: the
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
//// 3. **Then the node**, dispatched through `broker.clear_call` under the
////    *same* `{op_id, step_id}` the host uses. That is what makes
////    `broker.abort` on the host's deadline actually kill it.
////
//// # Two processes, one ordering guarantee
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
//// # What `SandboxPolicyV1` can and cannot say about reachability
////
//// The node needs two host paths inside the jail: the cap socket, which it
//// must `connect(2)`, and the token file, which it must read. The frozen
//// policy vocabulary (spec Part 1.4) has no "bind this path" verb, so this
//// module expresses both as `readable_roots` entries and *checks* the
//// composed policy actually covers them. What makes that sufficient today
//// is the helper's base view — bwrap ro-binds the whole host filesystem
//// read-only — plus three kernel facts: `sb_permission` exempts sockets
//// from `EROFS`, so `connect(2)` on a read-only mount succeeds; Landlock's
//// filesystem rights do not govern connecting to an existing socket; and
//// the network-off seccomp filter denies only non-`AF_UNIX` socket
//// creation.
////
//// Two things the policy type genuinely cannot express, and which this
//// module therefore refuses rather than discovers at runtime: a cap socket
//// or token under a `protected` path (bwrap shadows it with a read-only
//// tmpfs) and, when scratch is a tmpfs, one under `/tmp` (the helper mounts
//// the scratch tmpfs there, hiding whatever the host had). Both make the
//// path unreachable inside the jail while looking perfectly fine outside
//// it. See `protocol-change/004-sandbox-policy-explicit-mounts.md` for the
//// vocabulary that would state this positively instead.

import broker/broker.{type Broker, type CallSpec}
import broker/budget.{type Budget}
import broker/exec.{type EnforcementDemand}
import broker/policy.{type Narrowing, type SandboxPolicy}
import codemode/compile.{type Artifact}
import codemode/internal/ffi_unix.{type Listener, type Socket}
import codemode/satellite.{type CapConnection, type LaunchSpec}
import core/clock.{type Clock}
import filepath
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import tools/tool.{type Collected}

/// The environment variable naming the cap socket. Mirrors
/// `cap/runtime.sock_env`; the host does not depend on the `cap` package
/// (it must never link model-facing code), so the name is restated here
/// and pinned by a test against the boot contract.
pub const sock_env = "LOOM_CAP_SOCK"

/// The environment variable naming the private cap-token file. Mirrors
/// `cap/runtime.token_env`; see `sock_env`.
pub const token_env = "LOOM_CAP_TOKEN_FILE"

/// Where the Go helper mounts a `ScratchTmpfs` policy's scratch area
/// (`jail.ScratchMount`). A cap socket under this path is invisible inside
/// the jail, so the launcher refuses one.
pub const scratch_mount = "/tmp"

// How long a handoff from a freshly spawned socket process may take.
const handoff_timeout_ms = 2000

// One accept poll. The accept is sliced so the reader can notice, between
// slices, that the node died before it ever reached the socket.
const accept_poll_ms = 200

// How long the synchronous `clear_call` for the node itself may take.
const clear_timeout_ms = 5000

// Slack over the wall deadline before the node's collector gives up.
const settle_margin_ms = 10_000

// How long the reader waits, after end of stream, for the node's own exit
// status to arrive and sharpen the close reason.
const exit_reason_wait_ms = 2000

// The satellite node itself holds one outstanding effect for the whole
// execution, so a pooled budget of one would starve every `cap_call`.
const minimum_outstanding = 2

/// Everything the production launcher needs beyond the `LaunchSpec`.
pub type LaunchConfig {
  LaunchConfig(
    /// The running broker. The node is dispatched through it, and
    /// `destroy` aborts through it.
    broker: Broker,
    /// Reads the wall clock to size the node's own deadline.
    clock: Clock,
    /// Absolute path to the `erl` executable.
    erl_path: String,
    /// Enforcement strictness demanded of the jailed node.
    demand: EnforcementDemand,
    /// How long to wait for the satellite to connect back.
    accept_timeout_ms: Int,
    /// Receives the node's enforcement report (`entries`, `degraded`) once
    /// it settles, so a caller can say out loud which layers the running
    /// kernel actually provided. `fn(_, _) { Nil }` to ignore it.
    enforcement: fn(List(String), Bool) -> Nil,
  )
}

/// Builds the production `satellite.Launcher`.
///
/// The returned function is what `satellite.run` calls: it creates the
/// cap socket, dispatches the jailed node, and hands back the
/// `CapConnection` the host writes frames to and destroys the node with.
pub fn launcher(config: LaunchConfig) -> satellite.Launcher {
  fn(spec) { launch(config, spec) }
}

fn launch(
  config: LaunchConfig,
  spec: LaunchSpec,
) -> Result(CapConnection, String) {
  use _ <- result.try(check_budget(spec.budget))
  let #(now, _clock) = clock.read(config.clock)
  let requirements = node_requirements(spec, now)
  use effective <- result.try(composed_policy(spec.base_policy, requirements))
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
    Ok(outbox) -> {
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
          spawn_node(config, spec, requirements, exits, now)
          start_janitor(config, spec, outbox)
          Ok(
            satellite.CapConnection(
              send: fn(bytes) { process.send(outbox, Emit(bytes:)) },
              destroy: fn() { destroy(config, spec, outbox) },
            ),
          )
        }
      }
    }
  }
}

// Destroying the satellite: abort the operation (which revokes its tokens
// and kills the node and every executor it fanned out), close both ends of
// the socket, and unlink the socket file. Idempotent — the host calls it
// once on every exit path, and `satellite.hand_over` may call it instead.
fn destroy(
  config: LaunchConfig,
  spec: LaunchSpec,
  outbox: Subject(Out),
) -> Nil {
  broker.abort(config.broker, spec.op_id)
  process.send(outbox, Shutdown)
  unlink(spec.cap_socket_path)
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
) -> Nil {
  case process.subject_owner(spec.wire) {
    Error(Nil) -> Nil
    Ok(host) -> {
      let _pid =
        process.spawn_unlinked(fn() {
          let monitor = process.monitor(host)
          let down =
            process.new_selector()
            |> process.select_specific_monitor(monitor, fn(_down) { Nil })
          let _ = process.selector_receive_forever(down)
          destroy(config, spec, outbox)
          // The token file is the host's to unlink, and a killed host will
          // not do it. A leaked token is not a disclosure — its directory is
          // mode 0700 — but it is a leak.
          unlink(spec.token_path)
        })
      Nil
    }
  }
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
// death rather than as a timeout.
fn accept_loop(
  listener: Listener,
  outbox: Subject(Out),
  wire: Subject(satellite.WireIn),
  exits: Subject(String),
  remaining: Int,
) -> Nil {
  case process.receive(exits, 0) {
    Ok(reason) -> close_wire(wire, reason)
    Error(Nil) -> {
      let slice = int.min(accept_poll_ms, int.max(remaining, 0))
      case ffi_unix.accept(listener, slice) {
        Ok(socket) -> {
          process.send(outbox, Attach(socket:))
          read_loop(socket, wire, exits)
        }
        Error(ffi_unix.AcceptTimeout) ->
          case remaining - slice > 0 {
            True ->
              accept_loop(listener, outbox, wire, exits, remaining - slice)
            False ->
              close_wire(
                wire,
                "the satellite never connected to the cap socket",
              )
          }
        Error(ffi_unix.AcceptFailed(reason:)) ->
          close_wire(
            wire,
            "the cap socket faulted before the satellite connected: " <> reason,
          )
      }
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
  now: Int,
) -> Nil {
  let call = node_call(config, spec, requirements)
  let waiting = int.max(spec.budget.deadline_ms - now, 0) + settle_margin_ms
  let _pid =
    process.spawn_unlinked(fn() {
      let events = process.new_subject()
      case
        broker.clear_call(
          config.broker,
          call,
          events:,
          waiting: clear_timeout_ms,
        )
      {
        Error(refusal) ->
          process.send(
            exits,
            "the satellite node was refused before launch: "
              <> refusal_text(refusal),
          )
        Ok(_handle) ->
          case tool.collect_events(events, waiting:) {
            Ok(collected) -> {
              report_enforcement(config, collected)
              process.send(exits, exit_text(collected))
            }
            Error(Nil) ->
              process.send(exits, "the satellite node produced no settlement")
          }
      }
    })
  Nil
}

/// The clearance that launches the node: the same `{op_id, step_id}` the
/// host services cap calls under, so `broker.abort` reaches it.
pub fn node_call(
  config: LaunchConfig,
  spec: LaunchSpec,
  requirements: SandboxPolicy,
) -> CallSpec {
  broker.CallSpec(
    op_id: spec.op_id,
    step_id: spec.step_id,
    base_policy: spec.base_policy,
    requirements:,
    grants: [],
    // The launch already composed and checked this policy; refusing a
    // narrowing here means the broker disagreed, and a satellite in a
    // weaker jail than the one that was checked must not run.
    response: broker.RefuseNarrowed,
    demand: config.demand,
    argv: node_argv(config.erl_path, spec.artifact),
    env: node_env(spec),
    cwd: spec.cwd,
    budget: spec.budget,
  )
}

/// The node's argv: distribution off, no epmd, no node name, booting the
/// artifact's generated entry.
///
/// `-s init stop` closes the node once the entry returns — `-run` alone
/// leaves a `-noshell` node idling until its deadline, and the whole point
/// is that the node dies with the program.
pub fn node_argv(erl_path: String, artifact: Artifact) -> List(String) {
  [
    erl_path,
    "-noshell",
    "-boot",
    "no_dot_erlang",
    "-pa",
    artifact.beam_dir,
    "-proto_dist",
    "none",
    "-start_epmd",
    "false",
    "-run",
    artifact.entry_module,
    "main",
    "-s",
    "init",
    "stop",
  ]
}

/// The node's environment: the two cap-channel handles the boot runtime
/// reads, plus whatever the execution's policy already permits.
///
/// Allowlist-constructed, never inherited, and the two handles are set
/// here — a caller's `env` cannot shadow them into pointing a satellite at
/// somebody else's socket or token.
pub fn node_env(spec: LaunchSpec) -> List(#(String, String)) {
  let permitted =
    list.filter(spec.env, fn(pair) { pair.0 != sock_env && pair.0 != token_env })
  [
    #(sock_env, spec.cap_socket_path),
    #(token_env, spec.token_path),
    ..permitted
  ]
}

/// What the jailed node requires of the session base: the socket, token,
/// and `.beam` directories readable, the network off, the two cap handles
/// in the environment allowlist, and a wall limit no longer than what is
/// left of the pooled deadline.
///
/// Nothing here widens the base — composition takes the meet — so a base
/// that cannot cover one of these produces a narrowing, which the launch
/// reports as an in-band refusal.
pub fn node_requirements(spec: LaunchSpec, now_ms: Int) -> SandboxPolicy {
  let wanted = [
    directory_of(spec.cap_socket_path),
    directory_of(spec.token_path),
    spec.artifact.beam_dir,
  ]
  let base = spec.base_policy
  policy.SandboxPolicy(
    ..base,
    readable_roots: list.unique(list.append(base.readable_roots, wanted)),
    network: policy.NetworkOff,
    limits: policy.Limits(
      ..base.limits,
      wall_s: bound_wall(base.limits.wall_s, remaining_seconds(spec, now_ms)),
    ),
    env_allow: list.map(node_env(spec), fn(pair) { pair.0 }),
  )
}

// Seconds left of the pooled wall deadline, rounded up and never zero —
// zero means "no limit" on the wire, which is the opposite of what an
// exhausted deadline should say.
fn remaining_seconds(spec: LaunchSpec, now_ms: Int) -> Int {
  int.max({ int.max(spec.budget.deadline_ms - now_ms, 0) + 999 } / 1000, 1)
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

fn composed_policy(
  base: SandboxPolicy,
  requirements: SandboxPolicy,
) -> Result(SandboxPolicy, String) {
  let #(effective, narrowings) =
    policy.compose(base:, requirements:, grants: [])
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
  case list.find(effective.protected, fn(root) { covers(root, path) }) {
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
  case effective.scratch == policy.ScratchTmpfs && covers(scratch_mount, path) {
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
  case list.any(roots, fn(root) { covers(root, directory) }) {
    True -> Ok(Nil)
    False ->
      Error(
        what <> " at " <> path <> " is under no root the composed policy admits",
      )
  }
}

// Prefix-aware root coverage, matching the broker's own composition rule:
// `/work` covers `/work/sub` but not `/workspace`.
fn covers(root: String, path: String) -> Bool {
  root == "/" || root == path || string.starts_with(path, root <> "/")
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

fn report_enforcement(config: LaunchConfig, collected: Collected) -> Nil {
  case collected.outcome {
    broker.CallExited(result:) ->
      config.enforcement(result.enforcement, result.degraded)
    broker.CallFailed(failure: _) -> Nil
  }
}

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
  }
}
