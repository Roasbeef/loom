//// A language server run inside the jail, and the wire the harness speaks
//// to it over (ADR-013 §1).
////
//// A language server runs project code in effect: build scripts, macros,
//// a toolchain the model can edit. Rule Zero therefore puts it in the jail,
//// and the broker's ordinary jailed exec is enough to hold it there. The
//// JSON-RPC bytes ride inside `exec_stdin` and `exec_out` like any command's
//// input and output, so this module needs no new frame, no helper change and
//// no FFI. What makes it different from a command is only that it lives for
//// the session: it is cleared once, the way an extension host is, and it
//// stays until it exits.
////
//// The module has two halves, and they are separable on purpose.
////
//// **The policy** (`policy_for`) is pure over its inputs. It turns one
//// `[lsp.<name>]` table, the project root a file was found in, and the
//// session's base into the lease base and the requirements the clearance is
//// judged under. The lease base is the session's own, with the three
//// per-command limits zeroed (`broker/policy.session_lease`, `OutputIsWire`)
//// and widened by exactly what the operator wrote in `loom.toml` — the extra
//// roots, the environment names, and the mount the server's own executable
//// needs. Nothing the model supplies widens it, and in particular the
//// project root does not: a root the session base cannot already reach is
//// refused, never granted. The requirements then ask for the root (writable
//// only for `ProjectWritable`), those extra roots, a private scratch
//// directory for `TMPDIR`, the network off, and unlimited wall, CPU and
//// output. The zeros are written into the requirements literally rather
//// than derived from the base, so a base that kept a cap is a narrowing
//// `RefuseNarrowed` refuses rather than a lease that silently dies of it
//// hours in.
////
//// **The transport** (`transport`) is a `mcp/transport.ChannelTransport`
//// whose `connect` starts a relay process. The relay acquires a helper
//// lease (`client/lsp/leases`), clears the call, and turns broker events
//// into transport events: stdout chunks become `TransportData`, the
//// settlement becomes `TransportClosed` carrying the exit and the tail of
//// the server's stderr. A truncated stdout chunk is fatal, because the
//// stream is no longer JSON-RPC once bytes are missing from it. Stderr is a
//// log, drained into a bounded ring and never fatal.
////
//// The relay is a `weft/state_machine`. Its phases are the lease's life:
//// `Clearing` until the broker answers, `Relaying` while the server runs,
//// `Closing` once the client has sent stdin EOF, `Aborting` once the grace
//// for a polite exit has run out and the step has been aborted, and
//// `Draining` when the client has already been told the wire is gone but
//// the helper has not settled yet. The two graces are state timeouts, so
//// leaving the state cancels them and a fire that raced the settlement is
//// dropped rather than mistaken for a hung server. Writes and a close sent
//// before the clearance answers are postponed, not lost.
////
//// Identity: every language server of a session clears under one
//// attribution-only operation (`operation`), minted the way the extension
//// hooks' is, so an operator's abort of a model run does not reach it, and
//// each server gets its own step, `lsp/<server>/<root-digest>`, so
//// `broker.abort_step` stops exactly one server. The budget is one
//// outstanding execution and a deadline twelve hours out, the lease's real
//// bound now that the helper's own wall is zero.

import broker/broker.{type CallEvent, type CallSpec}
import broker/budget
import broker/exec
import broker/framing
import broker/policy.{type Mount, type Narrowing, type SandboxPolicy}
import client/catalog.{type LspServer}
import client/codemode.{type Toolchain}
import client/internal/ffi_os
import client/lsp/leases
import core/clock.{type Clock}
import core/ids.{type OpId}
import filepath
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import mcp/transport
import simplifile
import tools/tool.{type RunningCall}
import weft/state_machine as sm

// --- identity -------------------------------------------------------------

/// How long one language server may live before its pooled budget deadline
/// ends it: twelve hours, the extension hosts' `host_lifetime_ms`.
///
/// With `wall_s` at zero the helper no longer kills the server at a number
/// sized for one command, so this is the lease's only bound. It is far
/// longer than a working session and far shorter than forever, which is the
/// property wanted; a server that reaches it settles and is restarted on
/// next use.
pub const lease_lifetime_ms = 43_200_000

/// Mints the one attribution-only operation every language server of a
/// session clears under.
///
/// Its own operation rather than a borrowed one, for the reason the
/// extension hooks have theirs: an operator's `broker.abort` of a model run
/// must not take a server down that no model run owns, and a server's
/// effects are attributable to "the language servers" rather than to
/// whichever run first asked for one. Nobody sees this operation as a
/// running step, so nobody aborts it by accident; session end aborts it
/// deliberately.
///
/// ## Examples
///
/// ```gleam
/// // let lsp_op = jail.operation(clock, seed: entropy_seed)
/// ```
///
pub fn operation(clock: Clock, seed seed: Int) -> OpId {
  let #(op_id, _generator) = ids.mint_op(ids.generator(clock, seed:))
  op_id
}

/// The step one server clears under: `lsp/<server>/<root-digest>`.
///
/// The digest is the first sixteen hex characters of the root's SHA-256.
/// It names a path rather than authenticating anything; what it buys is a
/// step id of fixed length whatever the root is, and one step per
/// `{server, root}`, so `broker.abort_step` stops exactly the server it
/// names and its pooled ledger is never shared with another project's.
///
/// ## Examples
///
/// ```gleam
/// // jail.step_id("gleam", "/work") == "lsp/gleam/1f3a…"
/// ```
///
pub fn step_id(server: String, root: String) -> String {
  "lsp/" <> server <> "/" <> root_digest(root)
}

fn root_digest(root: String) -> String {
  bootstrap.sha256(bit_array.from_string(root))
  |> bit_array.base16_encode
  |> string.lowercase
  |> string.slice(at_index: 0, length: 16)
}

/// The server's private scratch directory: beneath the code-mode work
/// directory of the workspace, one per `{server, root}`.
///
/// Under the workspace because the session base already makes that
/// writable, so the lease writes nowhere new; under `.codemode` so the
/// operator's tree gains no dot-directory of its own; per root so two
/// projects' temporary files never meet. `TMPDIR` is pinned to its `tmp`
/// child because the jail replaces `/tmp` with a tmpfs of its own, and a
/// server that wrote there would lose it between restarts at best.
///
/// ## Examples
///
/// ```gleam
/// // jail.scratch_directory("/work", "gleam", "/work")
/// //   == "/work/.codemode/lsp/gleam-1f3a…"
/// ```
///
pub fn scratch_directory(
  workspace: String,
  server: String,
  root: String,
) -> String {
  workspace
  <> "/"
  <> codemode.work_directory
  <> "/lsp/"
  <> server
  <> "-"
  <> root_digest(root)
}

// --- locating the executable ----------------------------------------------

/// Whether the server's executable is an ordinary file or a link, measured
/// once when it is located. The answer decides which region is mounted.
pub type ExecutableFile {
  /// An ordinary file: its own directory is all the jail needs.
  PlainExecutable

  /// A symbolic link. Nothing here can read a link's target without FFI,
  /// so the install prefix is mounted as well, which holds both ends of a
  /// relative link such as Homebrew's `bin/x -> ../Cellar/x/1.0/bin/x`.
  LinkedExecutable
}

/// The server's executable, resolved to an absolute path.
pub type Executable {
  Executable(
    /// The absolute path the jail will run.
    path: String,
    /// Whether that path is a link, which widens the mounted region.
    file: ExecutableFile,
  )
}

/// Resolves a server's `command` head to the executable the jail runs.
///
/// Three shapes, in order. An absolute path is taken as written and must be
/// a file. The bare name `gleam`, when code mode located a toolchain, is
/// that toolchain's `gleam`: the copy this server shipped beside, or the one
/// `client/codemode.discover` settled on, so the compiler that analyses the
/// project is the one that builds its programs. Any other bare name is
/// looked up on the daemon's `PATH`, the lookup `client/codemode.locate`
/// falls back to. A relative path with a slash in it is refused, because it
/// would resolve against whatever directory the daemon was started in.
///
/// ## Examples
///
/// ```gleam
/// // jail.locate(server, None) == Ok(Executable("/usr/local/bin/gleam", PlainExecutable))
/// ```
///
pub fn locate(
  server: LspServer,
  toolchain: Option(Toolchain),
) -> Result(Executable, String) {
  use head <- result.try(case server.command {
    [head, ..] -> Ok(head)
    [] -> Error("lsp." <> server.name <> " has an empty command")
  })
  use path <- result.try(executable_path(server.name, head, toolchain))
  let file = case simplifile.is_symlink(path) {
    Ok(True) -> LinkedExecutable
    Ok(False) | Error(_unreadable) -> PlainExecutable
  }
  Ok(Executable(path:, file:))
}

// The three shapes `locate` documents. A bare `gleam` with no toolchain is
// an ordinary PATH lookup: code mode may be absent while `gleam lsp` still
// works, and refusing it there would be refusing a server over a feature
// it does not use.
fn executable_path(
  name: String,
  head: String,
  toolchain: Option(Toolchain),
) -> Result(String, String) {
  case string.starts_with(head, "/"), string.contains(head, "/"), toolchain {
    True, _, _ ->
      case simplifile.is_file(head) {
        Ok(True) -> Ok(head)
        Ok(False) | Error(_) ->
          Error("lsp." <> name <> "'s command " <> head <> " is not a file")
      }
    False, True, _ ->
      Error(
        "lsp."
        <> name
        <> "'s command "
        <> head
        <> " is a relative path; write an absolute path or a bare name "
        <> "looked up on PATH",
      )
    False, False, Some(found) if head == "gleam" -> Ok(found.gleam_path)
    False, False, _ ->
      ffi_os.find_executable(head)
      |> result.map_error(fn(_nil) {
        "lsp." <> name <> "'s command " <> head <> " is not on PATH"
      })
  }
}

/// The host regions the jail must bind for `executable` to run: its own
/// directory, and for a link its install prefix as well.
///
/// The directory rather than the prefix, for the reason code mode mounts
/// `gleam` that way: a developer install puts binaries in `~/.cargo/bin`,
/// `~/.local/bin` or `~/go/bin`, and mounting the prefix read-only would put
/// `~/.cargo/credentials.toml` inside every server's jail. That is also the
/// answer for `gopls` and its kind: `~/go/bin/gopls` mounts `~/go/bin`, and
/// the module cache and the Go toolchain it shells out to are the operator's
/// to list as `readable` roots in the server's table — they are that
/// server's needs, not a property of where its binary happens to live. A
/// link falls back to the prefix (`client/codemode.install_prefix`), which
/// holds a relative link's target; an absolute link out of the prefix is
/// not covered, and the jail refuses it by naming the path.
///
/// ## Examples
///
/// ```gleam
/// assert jail.regions(jail.Executable("/usr/local/bin/gleam", jail.PlainExecutable))
///   == ["/usr/local/bin"]
/// ```
///
pub fn regions(executable: Executable) -> List(String) {
  let directory = filepath.directory_name(executable.path)
  case executable.file {
    PlainExecutable -> [directory]
    LinkedExecutable -> {
      let prefix = codemode.install_prefix(executable.path)
      case policy.covers(root: prefix, path: directory) {
        True -> [prefix]
        False -> [directory, prefix]
      }
    }
  }
}

// --- the policy -----------------------------------------------------------

/// Where one server runs: the table it was configured by, the project root
/// it serves, the workspace whose scratch it borrows, its executable, and
/// the daemon's own `HOME`.
pub type Placement {
  Placement(
    /// The `[lsp.<name>]` table.
    server: LspServer,
    /// The project root the server is started in: the nearest ancestor of
    /// a file holding one of the server's `root_markers`. Absolute.
    root: String,
    /// The session's workspace, under which the scratch directory lives.
    workspace: String,
    /// The located executable (`locate`).
    executable: Executable,
    /// The daemon's own `HOME` (`client/serve.home_directory`), never a
    /// jailed session's. It expands the table's `~/` roots and is the
    /// server's `HOME`, so `gopls` finds its default caches where the
    /// operator's configuration says they are.
    home: Option(String),
  )
}

/// Everything one clearance needs, derived from a `Placement`.
pub type Jail {
  Jail(
    /// The lease base: the session base as a session lease, widened by the
    /// operator's table and nothing else.
    base: SandboxPolicy,
    /// What the server requires of that base.
    requirements: SandboxPolicy,
    /// The server's argv, executable first and absolute.
    argv: List(String),
    /// The server's environment, constructed rather than inherited.
    env: List(#(String, String)),
    /// The working directory: the project root.
    cwd: String,
    /// The server's private scratch directory; `TMPDIR` is its `tmp`.
    scratch: String,
    /// `lsp/<server>/<root-digest>`.
    step_id: String,
    /// Configured `env` names the daemon's environment does not set. They
    /// are skipped rather than refused, the `[tools] env` posture, and
    /// handed back so the caller can say so once.
    unset: List(String),
  )
}

/// Builds the lease base and the requirements for one server, and checks
/// that one covers the other before anything is spawned.
///
/// `reading` is the daemon's environment (`provider/secret.lookup` over the
/// session's store in production), read for `PATH` and for each configured
/// `env` name. The `Error` is a worded refusal naming what does not fit:
/// a relative root, an unresolvable `~/`, or a narrowing — most usefully a
/// project root outside what the session may reach, which this refuses
/// rather than grants.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(jail) = jail.policy_for(placement, session_base, reading: env)
/// // jail.requirements.network == policy.NetworkOff
/// ```
///
pub fn policy_for(
  placement: Placement,
  session_base: SandboxPolicy,
  reading reading: fn(String) -> Result(String, Nil),
) -> Result(Jail, String) {
  let server = placement.server
  let root = placement.root
  use Nil <- result.try(absolute_root(server.name, root))
  use readable <- result.try(expanded(server.readable, placement.home))
  use writable <- result.try(expanded(server.writable, placement.home))
  let scratch = scratch_directory(placement.workspace, server.name, root)
  let #(env, unset) = environment(placement, scratch, reading)
  let names = list.map(env, fn(pair) { pair.0 })

  // The lease base: the session's base with the per-command limits zeroed,
  // then widened by what the operator's table names — its extra roots, its
  // environment names, and the executable's region. The project root and
  // the scratch directory are deliberately not added: both must already be
  // reachable from the session, and composition refuses them otherwise.
  let lease = policy.session_lease(session_base, policy.OutputIsWire)
  let #(mounts, wanted) =
    admitted_mounts(lease.mounts, regions(placement.executable))
  let base =
    policy.SandboxPolicy(
      ..lease,
      readable_roots: list.unique(
        list.flatten([lease.readable_roots, readable, writable]),
      ),
      writable_roots: list.unique(list.append(lease.writable_roots, writable)),
      env_allow: list.unique(list.append(lease.env_allow, names)),
      mounts:,
    )

  // What the server asks for. The limits are written out rather than
  // inherited from the base, so a base that kept any of the three caps is
  // a narrowing and the lease is refused up front rather than killed at
  // the cap some hours in.
  let requirements =
    policy.SandboxPolicy(
      ..base,
      writable_roots: list.unique(
        list.flatten([project_writes(server, root), [scratch], writable]),
      ),
      readable_roots: list.unique(
        list.flatten([[root, scratch], readable, writable]),
      ),
      network: policy.NetworkOff,
      limits: policy.Limits(..base.limits, wall_s: 0, cpu_s: 0, output_bytes: 0),
      env_allow: names,
      mounts: wanted,
    )

  use Nil <- result.try(covered(server.name, base, requirements))
  let argv = case server.command {
    [_head, ..rest] -> [placement.executable.path, ..rest]
    [] -> [placement.executable.path]
  }
  Ok(Jail(
    base:,
    requirements:,
    argv:,
    env:,
    cwd: root,
    scratch:,
    step_id: step_id(server.name, root),
    unset:,
  ))
}

// The one question the project's access decides.
fn project_writes(server: LspServer, root: String) -> List(String) {
  case server.project {
    catalog.ProjectWritable -> [root]
    catalog.ProjectReadOnly -> []
  }
}

fn absolute_root(name: String, root: String) -> Result(Nil, String) {
  case string.starts_with(root, "/") {
    True -> Ok(Nil)
    False ->
      Error("lsp." <> name <> " was given a relative project root: " <> root)
  }
}

fn expanded(
  paths: List(catalog.LspPath),
  home: Option(String),
) -> Result(List(String), String) {
  list.try_map(paths, catalog.expand_lsp_path(_, home))
}

// Mounts are met by exact path, so a region the lease base already binds —
// the toolchain mounts code mode put on the session base, say — is asked
// for under the base's own path, and only a region nothing covers is added
// to the base. Adding a nested second bind of a region already bound would
// be two binds the emitters have to agree on the order of, for nothing.
// Returns the base's mounts and the requirements' mounts.
fn admitted_mounts(
  have: List(Mount),
  regions: List(String),
) -> #(List(Mount), List(Mount)) {
  let #(added, wanted) =
    list.fold(regions, #([], []), fn(acc, region) {
      let #(added, wanted) = acc
      case list.find(have, fn(mount) { policy.covers(mount.path, region) }) {
        Ok(existing) -> #(added, [read_only(existing.path), ..wanted])
        Error(Nil) -> #([read_only(region), ..added], [
          read_only(region),
          ..wanted
        ])
      }
    })
  #(list.append(have, list.reverse(added)), list.unique(list.reverse(wanted)))
}

// A server's executable region is required: a wrong derivation must
// refuse the lease naming the path, not start a jail with no binary in it.
fn read_only(path: String) -> Mount {
  policy.Mount(
    path:,
    access: policy.MountReadOnly,
    requirement: policy.MountRequired,
  )
}

// The server's environment, and the configured names the daemon does not
// set. PATH leads with the executable's own directory so a server that
// re-executes itself finds itself, then follows the daemon's PATH, which is
// where an operator's `go` or `cargo` is; a PATH entry names a place to
// look and grants nothing, since reach is the policy's.
fn environment(
  placement: Placement,
  scratch: String,
  reading: fn(String) -> Result(String, Nil),
) -> #(List(#(String, String)), List(String)) {
  let path =
    [
      filepath.directory_name(placement.executable.path),
      ..string.split(
        result.unwrap(reading("PATH"), "/usr/local/bin:/usr/bin:/bin"),
        ":",
      )
    ]
    |> list.filter(fn(entry) { entry != "" })
    |> list.unique
    |> string.join(":")
  let home = case placement.home {
    Some(home) -> [#("HOME", home)]
    None -> []
  }
  let owned =
    list.flatten([
      [#("PATH", path)],
      home,
      [#("TMPDIR", scratch <> "/tmp")],
    ])
  let #(present, unset) =
    list.fold(placement.server.env, #([], []), fn(acc, name) {
      case reading(name) {
        Ok(value) -> #([#(name, value), ..acc.0], acc.1)
        Error(Nil) -> #(acc.0, [name, ..acc.1])
      }
    })
  #(list.append(owned, list.reverse(present)), list.reverse(unset))
}

// Composes the two exactly as the broker will, so a lease that would be
// refused at clearance is refused here, in words, before a directory is
// made or a lease counted.
fn covered(
  name: String,
  base: SandboxPolicy,
  requirements: SandboxPolicy,
) -> Result(Nil, String) {
  let #(composed, narrowings) = policy.compose(base:, requirements:, grants: [])
  case narrowings {
    [] ->
      policy.validate(composed)
      |> result.map_error(fn(error) {
        "lsp."
        <> name
        <> "'s jail is not a valid policy: "
        <> string.inspect(error)
      })
    _ ->
      Error(
        "lsp."
        <> name
        <> " needs more than this session grants: "
        <> string.join(list.map(narrowings, narrowing_text), "; "),
      )
  }
}

/// One narrowing as the clause a refusal lists.
///
/// ## Examples
///
/// ```gleam
/// assert jail.narrowing_text(policy.NarrowedWritableRoot("/elsewhere"))
///   == "write /elsewhere"
/// ```
///
pub fn narrowing_text(narrowing: Narrowing) -> String {
  case narrowing {
    policy.NarrowedWritableRoot(path:) -> "write " <> path
    policy.NarrowedReadableRoot(path:) -> "read " <> path
    policy.NarrowedNetwork(wanted: _, granted: _) -> "a wider network"
    policy.NarrowedEnv(name:) -> "the environment name " <> name
    policy.NarrowedLimit(field:, wanted:, granted:) ->
      policy.limit_field_name(field)
      <> " of "
      <> int.to_string(wanted)
      <> " (the base caps it at "
      <> int.to_string(granted)
      <> ")"
    policy.NarrowedScratch(wanted: _) -> "a host scratch directory"
    policy.NarrowedMount(wanted:) -> "a mount of " <> wanted.path
  }
}

/// The clearance one server runs under: the jail, the lease's operation
/// and step, one outstanding execution and a budget deadline
/// `lease_lifetime_ms` after `now_ms`, platform enforcement, and
/// `RefuseNarrowed`, because nothing about a jailed server is best-effort.
///
/// ## Examples
///
/// ```gleam
/// // jail.call_spec(built, lsp_op, now_ms: 0).budget.max_outstanding == 1
/// ```
///
pub fn call_spec(jail: Jail, op_id: OpId, now_ms now_ms: Int) -> CallSpec {
  broker.CallSpec(
    op_id:,
    step_id: jail.step_id,
    base_policy: jail.base,
    requirements: jail.requirements,
    grants: [],
    response: broker.RefuseNarrowed,
    // Full enforcement always fails on Darwin; platform enforcement is
    // strict on Linux and admits only the reported Darwin gaps.
    demand: exec.PlatformEnforcement,
    argv: jail.argv,
    env: jail.env,
    cwd: jail.cwd,
    budget: budget.Budget(
      max_outstanding: 1,
      deadline_ms: now_ms + lease_lifetime_ms,
    ),
  )
}

// --- the transport --------------------------------------------------------

/// How long the relay waits at each step it does not control.
pub type Timing {
  Timing(
    /// The wait for the lease counter's answer.
    lease_wait_ms: Int,
    /// After stdin EOF, how long a server has to exit on its own before its
    /// step is aborted.
    close_grace_ms: Int,
    /// After an abort, how long the relay waits for the broker's settlement
    /// before it gives up on hearing one. The broker's own relay drains for
    /// its grace plus the helper's cancel ladder, so this sits above both.
    settle_grace_ms: Int,
  )
}

/// The waits production uses: a second for the lease, two seconds for a
/// polite exit, ten for the settlement after an abort.
///
/// ## Examples
///
/// ```gleam
/// assert jail.default_timing().close_grace_ms == 2000
/// ```
///
pub fn default_timing() -> Timing {
  Timing(lease_wait_ms: 1000, close_grace_ms: 2000, settle_grace_ms: 10_000)
}

/// Everything a relay needs to start one server: how to clear it, how to
/// abort its step, the lease counter, the clearance itself, the scratch
/// directory to prepare, and the waits.
///
/// `run` and `abort` are closures so a test drives the relay with a fake
/// broker; `launch` builds the production pair.
pub type Launch {
  Launch(
    /// Clears and dispatches the call: `tools/tool.broker_runner`.
    run: fn(CallSpec, Subject(CallEvent)) -> Result(RunningCall, broker.Refusal),
    /// Aborts this server's step: `broker.abort_step` for its
    /// `{op_id, step_id}`.
    abort: fn() -> Nil,
    /// The session's helper-lease counter.
    leases: leases.Leases,
    /// The clearance.
    spec: CallSpec,
    /// The scratch directory whose `tmp` child is created before clearing.
    scratch: String,
    /// The waits.
    timing: Timing,
  )
}

/// How long a clearance may wait out a full helper pool before refusing.
pub const clearance_wait_ms = 30_000

/// The production launch for one jail: the broker's runner and step abort,
/// under `op_id`, with the budget deadline read from `clock` now.
///
/// ## Examples
///
/// ```gleam
/// // jail.transport(jail.launch(broker, counter, built, lsp_op, clock))
/// ```
///
pub fn launch(
  broker_actor: broker.Broker,
  counter: leases.Leases,
  jail: Jail,
  op_id: OpId,
  clock: Clock,
) -> Launch {
  let #(now, _clock) = clock.read(clock)
  let spec = call_spec(jail, op_id, now_ms: now)
  Launch(
    run: tool.broker_runner(broker: broker_actor, waiting: clearance_wait_ms),
    abort: fn() {
      broker.abort_step(broker_actor, op_id, step_id: jail.step_id)
    },
    leases: counter,
    spec:,
    scratch: jail.scratch,
    timing: default_timing(),
  )
}

/// The transport a language-server client actor is started over.
///
/// `connect` runs in the client actor's own process: it starts the relay,
/// unlinked so neither takes the other down, with the actor as the owner
/// the relay monitors. `send` hands the relay one framed message and
/// answers `Error(Nil)` once the relay is gone; `close` asks it to stop
/// the server. Exactly one `TransportClosed` reaches the actor, and
/// nothing after it.
///
/// ## Examples
///
/// ```gleam
/// // lsp_client.start(jail.transport(jail.launch(..)), ..)
/// ```
///
pub fn transport(launch: Launch) -> transport.Transport {
  transport.ChannelTransport(connect: fn(inbound) { connect(launch, inbound) })
}

fn connect(
  launch: Launch,
  inbound: Subject(transport.TransportEvent),
) -> transport.Connection {
  let owner = process.self()
  case start_relay(launch, inbound, owner) {
    // A relay that would not start is a server that will not start, and the
    // actor learns that the one way it learns everything about the wire.
    Error(reason) -> {
      process.send(inbound, transport.TransportClosed(reason:))
      transport.Connection(send: fn(_line) { Error(Nil) }, close: fn() { Nil })
    }
    Ok(started) ->
      transport.Connection(
        send: fn(line) {
          case process.is_alive(started.pid) {
            True -> {
              process.send(
                started.data,
                Write(bytes: bit_array.from_string(line)),
              )
              Ok(Nil)
            }
            False -> Error(Nil)
          }
        },
        close: fn() { process.send(started.data, Close) },
      )
  }
}

// What moves the relay. `Clear` is its own first message; `Write` and
// `Close` come from the client actor; `FromCall` is the broker; `OwnerDown`
// is the client actor's monitor; the two graces are its state timeouts.
type Signal {
  Clear
  Write(bytes: BitArray)
  Close
  FromCall(event: CallEvent)
  OwnerDown
  CloseGraceElapsed
  SettleGraceElapsed
}

// The relay's phases. A phase's payload never changes while the relay is in
// it (docs/weft.md rule 1): everything that moves per event is in `Relay`.
type Phase {
  // Waiting for the lease and the clearance. Writes and a close are
  // postponed until the server exists.
  Clearing

  // The server runs; `call` is its stdin and cancel.
  Relaying(call: RunningCall)

  // The client closed stdin and the server has `close_grace_ms` to exit.
  Closing(call: RunningCall)

  // The grace ran out and the step was aborted; the settlement is owed.
  Aborting

  // The client has already been told the wire is gone (a truncated stdout,
  // or its own death); the relay stays only to see the helper settle, so
  // the lease is returned when the helper actually is.
  Draining
}

// Everything that moves per event.
type Relay {
  Relay(
    launch: Launch,
    inbound: Subject(transport.TransportEvent),
    events: Subject(CallEvent),
    lease: Option(leases.Lease),
    stderr: BitArray,
  )
}

/// How many bytes of the server's stderr the relay keeps: the last 8 KiB,
/// enough for the panic or the refusal a restart message wants to quote.
pub const stderr_ring_bytes = 8192

fn start_relay(
  launch: Launch,
  inbound: Subject(transport.TransportEvent),
  owner: process.Pid,
) -> Result(sm.Started(Subject(Signal)), String) {
  sm.new_with_initialiser(1000, fn(subject) {
    let events = process.new_subject()
    let watch = process.monitor(owner)

    // Three sources: the client actor's commands, the broker's events on a
    // subject this process owns (the broker watches its owner, so the
    // relay's death cancels the server), and the client actor's death.
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_map(events, FromCall)
      |> process.select_specific_monitor(watch, fn(_down) { OwnerDown })
    sm.initialised(
      Clearing,
      Relay(launch:, inbound:, events:, lease: None, stderr: <<>>),
    )
    |> sm.selecting(selector)
    |> sm.returning(subject)
    |> sm.continuing(Clear)
    |> Ok
  })
  |> sm.on_event(handle)
  |> sm.unlinked
  |> sm.start
  |> result.map_error(fn(error) {
    "the language server's relay would not start: " <> string.inspect(error)
  })
}

fn handle(
  phase: Phase,
  relay: Relay,
  signal: Signal,
) -> sm.Next(Phase, Relay, Signal) {
  case phase, signal {
    // The one clearance. Everything before it waits for it.
    Clearing, Clear -> clear(relay)
    Clearing, Write(_) | Clearing, Close -> sm.keep(relay) |> sm.postpone

    // Nothing was dispatched, so there is nothing to cancel and nobody to
    // tell.
    Clearing, OwnerDown -> finish(relay)

    // Unreachable before a call exists: no events subject has been handed
    // to the broker, and no grace is armed in this phase.
    Clearing, FromCall(_)
    | Clearing, CloseGraceElapsed
    | Clearing, SettleGraceElapsed
    -> sm.keep(relay)

    Relaying(call), Write(bytes:) -> {
      call.stdin(bytes, False)
      sm.keep(relay)
    }

    // EOF on stdin is the server's cue to exit; the abort is the backstop
    // if it does not.
    Relaying(call), Close -> {
      call.stdin(<<>>, True)
      sm.transition(to: Closing(call), data: relay)
      |> sm.with_state_timeout(
        after: relay.launch.timing.close_grace_ms,
        sending: CloseGraceElapsed,
      )
    }

    Relaying(_), FromCall(event) -> output(relay, event)
    Relaying(_), OwnerDown -> orphaned(relay)
    Relaying(_), CloseGraceElapsed | Relaying(_), SettleGraceElapsed ->
      sm.keep(relay)

    // A write after close has no reader left to answer it.
    Closing(_), Write(_) | Closing(_), Close -> sm.keep(relay)
    Closing(_), FromCall(event) -> output(relay, event)
    Closing(_), OwnerDown -> orphaned(relay)

    // The server ignored its EOF. Abort the step and wait for the broker's
    // word that the helper is back.
    Closing(_), CloseGraceElapsed -> {
      relay.launch.abort()
      sm.transition(to: Aborting, data: relay)
      |> sm.with_state_timeout(
        after: relay.launch.timing.settle_grace_ms,
        sending: SettleGraceElapsed,
      )
    }
    Closing(_), SettleGraceElapsed -> sm.keep(relay)

    Aborting, Write(_) | Aborting, Close | Aborting, CloseGraceElapsed ->
      sm.keep(relay)
    Aborting, FromCall(event) -> output(relay, event)
    Aborting, OwnerDown -> drain(relay)

    // The broker never settled. Its relay guarantees a settlement within
    // its grace, so this is a broker that is gone; say so and stop.
    Aborting, SettleGraceElapsed -> {
      tell(
        relay,
        "the language server did not settle after its step was aborted",
      )
      finish(relay)
    }

    // The client has its answer. Only the settlement matters now.
    Draining, FromCall(broker.CallSettled(_)) -> finish(relay)
    Draining, SettleGraceElapsed -> finish(relay)
    Draining, FromCall(broker.CallOutput(..))
    | Draining, Write(_)
    | Draining, Close
    | Draining, OwnerDown
    | Draining, CloseGraceElapsed
    | Draining, Clear
    -> sm.keep(relay)

    // `Clear` is injected once, at start, and handled in `Clearing`.
    Relaying(_), Clear | Closing(_), Clear | Aborting, Clear -> sm.keep(relay)
  }
}

// Takes the lease, prepares the scratch directory, and clears the call. A
// refusal at any step is the one `TransportClosed` the client gets, and the
// lease — if one was taken — goes back first.
fn clear(relay: Relay) -> sm.Next(Phase, Relay, Signal) {
  let launch = relay.launch
  let acquired =
    leases.acquire(
      launch.leases,
      holder: process.self(),
      waiting: launch.timing.lease_wait_ms,
    )
  case acquired {
    Error(refusal) -> {
      tell(relay, "no_server: " <> leases.refusal_text(refusal))
      finish(relay)
    }
    Ok(lease) -> {
      let relay = Relay(..relay, lease: Some(lease))
      case dispatch(relay) {
        Ok(call) -> sm.transition(to: Relaying(call), data: relay)
        Error(reason) -> {
          tell(relay, reason)
          finish(relay)
        }
      }
    }
  }
}

fn dispatch(relay: Relay) -> Result(RunningCall, String) {
  let launch = relay.launch
  let tmp = launch.scratch <> "/tmp"
  use Nil <- result.try(
    simplifile.create_directory_all(tmp)
    |> result.map_error(fn(error) {
      "the language server's scratch directory "
      <> tmp
      <> " could not be made: "
      <> simplifile.describe_error(error)
    }),
  )
  launch.run(launch.spec, relay.events)
  |> result.map_error(refusal_text)
}

/// A clearance refusal as the reason a `TransportClosed` carries.
///
/// ## Examples
///
/// ```gleam
/// assert jail.refusal_text(broker.BrokerUnavailable)
///   == "the language server was not started: the broker did not answer"
/// ```
///
pub fn refusal_text(refusal: broker.Refusal) -> String {
  "the language server was not started: "
  <> case refusal {
    broker.PolicyRefused(denial:) -> "the sandbox refused it: " <> denial.reason
    broker.InvalidPolicy(error:) ->
      "its policy is invalid: " <> string.inspect(error)
    broker.BudgetRefused(refusal:) ->
      "its budget was refused: " <> string.inspect(refusal)
    broker.MintRefused(error: _) -> "no capability token could be minted"
    broker.NoHelper(error:) ->
      "no sandbox helper was available: " <> string.inspect(error)
    broker.OperationAborted -> "the language servers' operation was aborted"
    broker.BrokerUnavailable -> "the broker did not answer"
  }
}

// One broker event while the client is still listening. Stdout is the
// wire; stderr is a log; the settlement is the end.
fn output(relay: Relay, event: CallEvent) -> sm.Next(Phase, Relay, Signal) {
  case event {
    broker.CallOutput(stream: framing.Stdout, data:, total_bytes: _, truncated:) ->
      case truncated {
        False -> {
          process.send(relay.inbound, transport.TransportData(bytes: data))
          sm.keep(relay)
        }

        // Bytes are missing from the stream, so no later frame can be
        // trusted to start where its header says. The client hears it now;
        // the relay aborts the step and stays to see the helper settle.
        True -> {
          tell(
            relay,
            "stdout truncated: the server's output was cut at the helper's "
              <> "cap, so its JSON-RPC stream is no longer framed",
          )
          relay.launch.abort()
          drain(relay)
        }
      }

    broker.CallOutput(
      stream: framing.Stderr,
      data:,
      total_bytes: _,
      truncated: _,
    ) -> sm.keep(Relay(..relay, stderr: ring(relay.stderr, data)))

    broker.CallSettled(outcome:) -> {
      tell(relay, settled_text(outcome, relay.stderr))
      finish(relay)
    }
  }
}

// The client actor died with the server running: nobody is left to tell,
// so the step is aborted and the relay waits for the helper to come back
// before it returns the lease.
fn orphaned(relay: Relay) -> sm.Next(Phase, Relay, Signal) {
  relay.launch.abort()
  drain(relay)
}

fn drain(relay: Relay) -> sm.Next(Phase, Relay, Signal) {
  sm.transition(to: Draining, data: relay)
  |> sm.with_state_timeout(
    after: relay.launch.timing.settle_grace_ms,
    sending: SettleGraceElapsed,
  )
}

// The lease is released here, explicitly, the moment the helper is known to
// be back (or will never be heard from). The counter's monitor on this
// process would release it anyway; this is the prompt path.
fn finish(relay: Relay) -> sm.Next(Phase, Relay, Signal) {
  case relay.lease {
    Some(lease) -> leases.release(lease)
    None -> Nil
  }
  sm.stop()
}

fn tell(relay: Relay, reason: String) -> Nil {
  process.send(relay.inbound, transport.TransportClosed(reason:))
}

// Keeps the last `stderr_ring_bytes` of the stream.
fn ring(held: BitArray, data: BitArray) -> BitArray {
  let joined = bit_array.append(held, data)
  let size = bit_array.byte_size(joined)
  case size > stderr_ring_bytes {
    False -> joined
    True ->
      bit_array.slice(joined, size - stderr_ring_bytes, stderr_ring_bytes)
      |> result.unwrap(joined)
  }
}

/// How a settled server ended, as the reason its `TransportClosed` carries:
/// the exit code or the failure, then the tail of its stderr.
///
/// ## Examples
///
/// ```gleam
/// // jail.settled_text(broker.CallExited(result), <<"panic: boom":utf8>>)
/// // == "the language server exited with code 2; its stderr ended: panic: boom"
/// ```
///
pub fn settled_text(outcome: broker.CallOutcome, stderr: BitArray) -> String {
  let ending = case outcome {
    broker.CallExited(result:) ->
      "the language server exited with code "
      <> int.to_string(result.code)
      <> case result.timed_out {
        True -> ", killed at its lease deadline"
        False -> ""
      }
    broker.CallFailed(failure:) ->
      "the language server's execution failed: "
      <> tool.exec_failure_text(failure)
      <> missing_layers(failure)
  }
  case string.trim(stderr_text(stderr)) {
    "" -> ending
    tail -> ending <> "; its stderr ended: " <> tail
  }
}

// A degraded settlement names the layers the helper could not apply, in
// the helper's own words, because "ran without the demanded enforcement"
// alone tells an operator nothing about which kernel feature to look for.
// Every other failure has said everything it knows already.
fn missing_layers(failure: exec.ExecFailure) -> String {
  case failure {
    exec.DegradedExecution(result:) ->
      case list.filter(result.enforcement, string.starts_with(_, "skip:")) {
        [] -> ""
        skipped -> " (" <> string.join(skipped, ", ") <> ")"
      }
    exec.DegradedHelper(features:) -> " (" <> string.join(features, " ") <> ")"
    exec.NotReady
    | exec.HandshakeTimeout
    | exec.HelperBusy
    | exec.RefusedByHelper(..)
    | exec.ChannelFault(..)
    | exec.ChannelClosed(..)
    | exec.ProtocolViolation(..)
    | exec.ProtocolVersionMismatch(..)
    | exec.SendFailed
    | exec.CancelEscalated
    | exec.HeartbeatMissed
    | exec.HelperUnresponsive -> ""
  }
}

// The ring was cut at a byte count, so it may open part-way through a
// character. Leading continuation bytes are dropped until the rest reads
// as text; stderr that is not text at all is described rather than quoted.
fn stderr_text(bytes: BitArray) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) -> text
    Error(Nil) ->
      case bytes {
        <<byte, rest:bytes>> if byte >= 0x80 && byte < 0xc0 -> stderr_text(rest)
        _ ->
          int.to_string(bit_array.byte_size(bytes))
          <> " bytes of stderr that are not UTF-8"
      }
  }
}
