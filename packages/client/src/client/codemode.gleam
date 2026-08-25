//// Code mode: `tools/codemode`'s seam, implemented over the real
//// pipeline.
////
//// `tools` cannot see `codemode` — `codemode` already depends on `tools`
//// for the `tool.Collected` its capability router renders — so the two
//// meet here, in the only package that depends on both. `tools/codemode`
//// declares a record of closures in plain data, this module fills it, and
//// the `code_mode` tool stays what a tool is in this codebase: a name, a
//// schema, and a total `run` that turns every failure into a structured
//// result the model can act on.
////
//// ## One execution, one identity, one budget
////
//// Everything a code-mode call does — the hermetic `gleam build`, the
//// jailed `erl`, and every capability call the running program makes —
//// is dispatched under the calling strand's own `{op_id, step_id}`. That
//// pair *is* the execution identity the broker pools budget under
//// (`packages/broker/CLAUDE.md`, "Budget is pooled per execution"), so
//// using it rather than a minted one has three consequences worth stating
//// plainly: the compile and the run draw on one ledger and one wall
//// deadline instead of two, `broker.abort` on the operation reaches the
//// build and the node alike, and a program that fans out buys parallelism
//// rather than extra resources.
////
//// The pooled cap must be at least two — the satellite node itself holds
//// one outstanding effect for its whole life, so a cap of one would starve
//// every `cap_call` the program makes; `launch` refuses such a budget in
//// band rather than hanging.
////
//// ## The two env names, and why they are added here
////
//// The boot runtime inside the satellite finds its socket and its token
//// through `LOOM_CAP_SOCK` and `LOOM_CAP_TOKEN_FILE`, which the launcher
//// sets itself and a caller's `env` cannot shadow. Policy composition
//// takes the meet, so an execution whose base policy does not *name* those
//// two variables composes them away and the node comes up unable to find
//// the channel it exists to speak on — reported honestly as a launch
//// refusal, but a dead feature all the same.
////
//// `execution_policy` therefore derives the base a code-mode execution
//// runs under from the session base by adding exactly those two names and
//// nothing else. Their values are the harness's own paths, minted per
//// execution and never model-supplied, so this widens what the launcher
//// may *state* rather than what a program may reach: the jail, the token
//// binding, and the broker's per-call policy check are all untouched. It
//// is written as one small named function precisely so it stays auditable
//// rather than diffusing into the wiring.
////
//// ## Where an execution's files live
////
//// Under `work_root`, one directory per `{op_id, step_id}` — named by a
//// short digest of that pair, for reasons `exec_root` explains — holding
//// the cloned build seed, the compiled `.beam` set, the cap socket, and
//// the private token file. Two properties fall out of the placement. It
//// is inside the workspace, so the session base already makes it writable
//// and no policy has to be widened to build there; and it is unique per
//// execution, so two strands running code mode at the same time cannot
//// share a build root. The directory is removed once the execution
//// settles — the seed clone is large and every build clones it fresh
//// anyway.

import broker/broker.{type Broker}
import broker/budget.{type Budget}
import broker/policy.{type SandboxPolicy}
import broker/token
import client/internal/ffi_os
import codemode/build
import codemode/codemode as pipeline
import codemode/compile
import codemode/launch
import codemode/satellite
import codemode/seed
import codemode/vet
import codemode/vet/policy as vet_policy
import core/clock.{type Clock}
import core/ids
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import simplifile
import tools/codemode as codemode_tool

/// The stage label for the hermetic build in an enforcement report.
pub const build_stage = "the hermetic build"

/// The stage label for the satellite node in an enforcement report.
pub const satellite_stage = "the satellite node"

/// How long to wait for one more enforcement report before concluding
/// that a stage produced none.
///
/// The build's report is always in the mailbox before `execute` returns —
/// the build is synchronous. The node's is not guaranteed: it is written
/// when the node's own execution settles, and a program that finishes
/// promptly has its node destroyed (which aborts the operation's calls)
/// before that settlement is always delivered. A short grace catches the
/// common case; a missing report is reported as missing rather than
/// assumed enforced.
pub const enforcement_grace_ms = 500

/// The smallest pooled outstanding-effect cap a satellite can live under:
/// the node holds one for its whole life, so anything less starves the
/// program's first capability call. `launch` enforces the same floor.
pub const minimum_outstanding = 2

/// Everything the production seam needs beyond one request.
///
/// Constructor invariants: `work_root` is an absolute directory inside the
/// workspace the sessions' base policy makes writable; `gleam_path`,
/// `erl_path` and `seed_root` are the located toolchain
/// (`discover`); `toolchain_path` is a `PATH` covering both executables,
/// because `gleam build` shells out to `erl`; `max_outstanding` is at
/// least `minimum_outstanding`; and `default_within_ms` is at most
/// `max_within_ms`.
pub type Config {
  Config(
    /// The running broker every jailed stage is dispatched through.
    broker: Broker,
    /// The session's one clock; deadlines here are absolute Unix ms.
    clock: Clock,
    /// Token entropy for the cap channel.
    entropy: fn(Int) -> BitArray,
    /// Where per-execution directories are created.
    work_root: String,
    /// The prepared build seed (`make codemode-seed`).
    seed_root: String,
    /// Absolute path to `gleam`.
    gleam_path: String,
    /// Absolute path to `erl`.
    erl_path: String,
    /// A `PATH` for the hermetic build, covering both executables.
    toolchain_path: String,
    /// The vetting allowlist submitted programs are judged against.
    vet_policy: vet_policy.VetPolicy,
    /// The pooled outstanding-effect cap for a whole execution.
    max_outstanding: Int,
    /// How long the hermetic build itself may take.
    build_timeout_ms: Int,
    /// How long to wait for the satellite to connect back.
    accept_timeout_ms: Int,
    /// How long to wait for one capability call's settlement.
    call_timeout_ms: Int,
    /// The wall budget used when a call names none.
    default_within_ms: Int,
    /// The ceiling a call's `within_ms` is clamped to.
    max_within_ms: Int,
  )
}

/// The pooled outstanding-effect cap one execution runs under. Above the
/// floor of two the satellite needs for itself, so a program can fan a few
/// capability calls out at once — sharing this cap and one deadline, which
/// is the point of pooling.
pub const default_outstanding = 6

/// The wall budget a `code_mode` call gets when it names none. A hermetic
/// build is tens of seconds before the program starts, so the default is
/// generous.
pub const default_within_ms = 300_000

/// The ceiling a call's `within_ms` is clamped to: where an operator would
/// rather abort than keep waiting.
pub const max_within_ms = 900_000

/// How long the hermetic build itself may take. Under `max_within_ms`, so
/// a build that hangs still leaves the execution's deadline to end it.
pub const default_build_timeout_ms = 180_000

/// How long to wait for a launched satellite to connect back to the cap
/// socket, and how long one capability call may take to settle.
pub const default_accept_timeout_ms = 30_000

/// How long one capability call may take to settle.
pub const default_call_timeout_ms = 120_000

/// Where an execution's directories are created, relative to the
/// workspace. Inside it, so the session base already makes it writable.
pub const work_directory = ".codemode"

/// The shipped configuration for a located toolchain: the vetting default,
/// the pooled budget, the timeouts, and a work root inside the workspace.
///
/// One place holds the numbers, so `serve` states none of them and a host
/// that wants different ones edits the record it is handed rather than
/// re-deriving the whole configuration.
///
/// ## Examples
///
/// ```gleam
/// // codemode.default_config(broker, clock, "/work", toolchain).work_root
/// //   == "/work/.codemode"
/// ```
///
pub fn default_config(
  broker broker: Broker,
  clock clock: Clock,
  workspace workspace: String,
  toolchain toolchain: Toolchain,
) -> Config {
  Config(
    broker:,
    clock:,
    entropy: token.production_entropy(),
    work_root: workspace <> "/" <> work_directory,
    seed_root: toolchain.seed_root,
    gleam_path: toolchain.gleam_path,
    erl_path: toolchain.erl_path,
    toolchain_path: toolchain_path(toolchain),
    vet_policy: vet_policy.default(),
    max_outstanding: default_outstanding,
    build_timeout_ms: default_build_timeout_ms,
    accept_timeout_ms: default_accept_timeout_ms,
    call_timeout_ms: default_call_timeout_ms,
    default_within_ms:,
    max_within_ms:,
  )
}

/// The located toolchain a code-mode execution needs on this host.
pub type Toolchain {
  Toolchain(gleam_path: String, erl_path: String, seed_root: String)
}

/// The capability names the shipped router actually services. Published
/// through the seam so the tool's description tells the model the truth
/// rather than a copy that can drift from `satellite.default_router`.
pub const serviced_caps = ["proc.run"]

// --- discovery -------------------------------------------------------------

/// Locates what this host needs to run code mode, or says what is missing.
///
/// Three questions, each answered against the host rather than assumed:
/// is `gleam` on `PATH`, is `erl`, and is there a prepared build seed at
/// `seed_root` whose dependency table is byte-identical to the one the
/// compile service generates. The last is `seed.verify`, and it is the
/// interesting one: a seed prepared from a different table resolved a
/// different dependency graph, so building against it would pin something
/// other than what the compile service says it pins.
///
/// A host that fails any of them registers no `code_mode` tool at all,
/// which is why this returns the reason: the boot prints it once rather
/// than shipping a tool that can only ever refuse.
///
/// ## Examples
///
/// ```gleam
/// // let assert Error(reason) = codemode.discover("/nowhere")
/// ```
///
pub fn discover(seed_root: String) -> Result(Toolchain, String) {
  use gleam_path <- result.try(executable("gleam"))
  use erl_path <- result.try(executable("erl"))
  use _verified <- result.try(seed.verify(
    seed_root,
    compile.default_dependencies(),
  ))
  Ok(Toolchain(gleam_path:, erl_path:, seed_root:))
}

fn executable(name: String) -> Result(String, String) {
  ffi_os.find_executable(name)
  |> result.replace_error(
    name <> " is not on PATH, so code-mode programs cannot be built or run",
  )
}

/// A `PATH` for the hermetic build, built from where the executables were
/// actually found rather than guessed. `gleam build` shells out to `erl`,
/// so both directories have to be on it.
///
/// ## Examples
///
/// ```gleam
/// // codemode.toolchain_path(found) == "/usr/local/bin:/usr/bin:/bin"
/// ```
///
pub fn toolchain_path(toolchain: Toolchain) -> String {
  [
    directory_of(toolchain.gleam_path),
    directory_of(toolchain.erl_path),
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
  ]
  |> list.unique
  |> string.join(":")
}

// --- the seam --------------------------------------------------------------

/// Builds the production seam: the closure `tools/codemode` calls, plus
/// the allowlist and the serviced capability names its description states.
///
/// ## Examples
///
/// ```gleam
/// // tool.registry(list.append(core, codemode_tool.tools(codemode.seam(config))))
/// ```
///
pub fn seam(config: Config) -> codemode_tool.CodeMode {
  codemode_tool.CodeMode(
    execute: fn(request) { execute(config, request) },
    allowed_imports: vet_policy.allowed_imports(config.vet_policy),
    serviced_caps:,
    default_within_ms: config.default_within_ms,
    max_within_ms: config.max_within_ms,
  )
}

/// Runs one submitted program end to end and reports what ran.
///
/// Total: every failure of every stage is a value in the `Execution` this
/// returns, including the two this module owns — a work directory that
/// cannot be created, and a report that never arrived.
///
/// ## Examples
///
/// ```gleam
/// // codemode.execute(config, request).result
/// ```
///
pub fn execute(
  config: Config,
  request: codemode_tool.Request,
) -> codemode_tool.Execution {
  let root = exec_root(config, request)
  let reports = process.new_subject()
  // The socket check first: it is pure, and failing it after creating the
  // directory would leave one behind for an execution that never ran.
  case check_socket_path(root) |> result.try(fn(_) { prepare_root(root) }) {
    Error(reason) ->
      codemode_tool.Execution(
        result: codemode_tool.CompileFailed(codemode_tool.WorkspaceSetupFailed(
          reason:,
        )),
        enforcement: [],
      )
    Ok(Nil) -> {
      let #(now, _clock) = clock.read(config.clock)
      let deadline_ms = now + request.within_ms
      let outcome =
        pipeline.execute(
          request.source,
          exec_config(config, request, root, deadline_ms, reports),
        )
      // The whole execution is over: the node is destroyed, the socket and
      // token are unlinked by the host's own teardown, and nothing but the
      // outcome outlives it. The seed clone is large and every build makes
      // a fresh one, so the directory goes too.
      let _removed = simplifile.delete(root)
      let result = translate(outcome)
      codemode_tool.Execution(result:, enforcement: case result {
        // Vetting refused the program: nothing was dispatched, so no
        // report can exist and waiting the grace for one would tax the
        // repair loop — the very loop that is meant to be cheap.
        codemode_tool.VetRejected(rejections: _) -> []
        _ran_or_tried -> drain(reports, [])
      })
    }
  }
}

// A fresh directory per execution. `delete` first because a directory left
// by a previous execution under the same coordinates — a replayed step, an
// interrupted run — must not have its stale contents join this build.
fn prepare_root(root: String) -> Result(Nil, String) {
  let _cleared = simplifile.delete(root)
  simplifile.create_directory_all(root)
  |> result.map_error(fn(error) {
    "could not create the code-mode work directory "
    <> root
    <> ": "
    <> simplifile.describe_error(error)
  })
}

// An AF_UNIX socket the kernel will not bind is worth catching here,
// where the workspace can be named in the answer, rather than as an
// `einval` from `listen` three stages later.
fn check_socket_path(root: String) -> Result(Nil, String) {
  let path = socket_path(root)
  case bit_array.byte_size(<<path:utf8>>) > max_socket_path_bytes {
    False -> Ok(Nil)
    True ->
      Error(
        "the code-mode cap socket would be "
        <> path
        <> ", which is longer than the "
        <> int.to_string(max_socket_path_bytes)
        <> " bytes a unix socket path may have; run the session from a "
        <> "shallower workspace",
      )
  }
}

/// This execution's own directory: the build root, the `.beam` set, the
/// cap socket, and the private token file all live under it.
///
/// The name is a 64-bit FNV-1a digest of `{op_id, step_id}` rendered as
/// sixteen hex characters, and its shortness is the point rather than an
/// aesthetic. The cap socket lives inside this directory and an AF_UNIX
/// path is capped at about 108 bytes by the kernel, so a directory named
/// for a full operation id and a step id spends forty-odd of them before
/// the workspace prefix is counted; a workspace a couple of levels deeper
/// then fails at `listen` with `einval`, which is a poor way to learn
/// about a path limit. A digest is unique per execution — all this name
/// has to be, since two strands running code mode at once must not share
/// a build root — and it cannot carry a separator, a dot segment or a
/// space out of the work root the way a step id could. The directory is
/// removed when the execution settles, and the artifact's `manifest_hash`
/// remains the durable fingerprint of what ran.
///
/// ## Examples
///
/// ```gleam
/// // codemode.exec_root(config, request) == "/work/.codemode/9f2b1c0ad3e45871"
/// ```
///
pub fn exec_root(config: Config, request: codemode_tool.Request) -> String {
  config.work_root
  <> "/"
  <> digest(ids.op_id_to_string(request.op_id) <> "\n" <> request.step_id)
}

/// The cap-channel socket for an execution rooted at `root`. One
/// character, for the same reason `exec_root` is a digest.
///
/// ## Examples
///
/// ```gleam
/// assert codemode.socket_path("/w/.codemode/9f2b") == "/w/.codemode/9f2b/s"
/// ```
///
pub fn socket_path(root: String) -> String {
  root <> "/s"
}

/// The longest cap-socket path this wiring will attempt.
///
/// The kernel's `sun_path` is 108 bytes including its terminator on Linux
/// and 104 on macOS; a few bytes of margin under the smaller of the two
/// turns an opaque `einval` from `listen` into a worded refusal that names
/// the real problem — the workspace sits too deep for a code-mode socket.
pub const max_socket_path_bytes = 100

// FNV-1a 64 over the key's codepoints, rendered as sixteen lowercase hex
// characters. A path-naming digest, not a security primitive: nothing is
// authenticated by it, and a collision would only mean two executions
// sharing a directory — which is why the key is the pair that is already
// unique per execution.
fn digest(key: String) -> String {
  key
  |> string.to_utf_codepoints
  |> list.fold(fnv_offset_basis, fn(hash, point) {
    let mixed =
      int.bitwise_exclusive_or(hash, string.utf_codepoint_to_int(point))
    int.bitwise_and(mixed * fnv_prime, mask_64)
  })
  |> int.to_base16
  |> string.lowercase
  |> string.pad_start(to: 16, with: "0")
}

const fnv_offset_basis = 14_695_981_039_346_656_037

const fnv_prime = 1_099_511_628_211

const mask_64 = 18_446_744_073_709_551_615

/// The pipeline configuration for one execution: the vetting policy, the
/// hermetic build, the pooled identity and budget, the satellite host, and
/// the production launcher.
///
/// Public because the identity threading is the property worth pinning in
/// a test: `exec_id` and the build's `{op_id, step_id}` are the caller's,
/// and both stages share one `Budget`.
///
/// ## Examples
///
/// ```gleam
/// // codemode.exec_config(config, request, root, deadline, reports).exec_id
/// //   == satellite.ExecId(op_id: request.op_id, step_id: request.step_id)
/// ```
///
pub fn exec_config(
  config: Config,
  request: codemode_tool.Request,
  root: String,
  deadline_ms: Int,
  reports: Subject(codemode_tool.Enforcement),
) -> pipeline.ExecConfig {
  let pooled = pooled_budget(config, deadline_ms)
  let base_policy = execution_policy(request.base_policy)
  pipeline.ExecConfig(
    vet_policy: config.vet_policy,
    compile: compile.CompileConfig(
      build_root: root,
      dependencies: compile.default_dependencies(),
      build: build.builder(build_config(config, request, deadline_ms, reports)),
    ),
    broker: config.broker,
    exec_id: satellite.ExecId(op_id: request.op_id, step_id: request.step_id),
    satellite: satellite.SatelliteConfig(
      base_policy:,
      budget: pooled,
      demand: request.demand,
      // The program's own children inherit the driver's constructed
      // environment, not the build's: what a program shells out to is the
      // agent's toolchain, the same one `bash` would reach.
      env: request.env,
      cwd: request.workspace,
      cap_socket_path: socket_path(root),
      entropy: config.entropy,
      clock: config.clock,
      write_token_file: satellite.private_token_writer(root <> "/token"),
      unlink_token_file: satellite.unlink_token_file,
      router: satellite.default_router,
      call_timeout_ms: config.call_timeout_ms,
    ),
    launch: launch.launcher(
      launch.LaunchConfig(
        broker: config.broker,
        clock: config.clock,
        erl_path: config.erl_path,
        demand: request.demand,
        accept_timeout_ms: config.accept_timeout_ms,
        enforcement: fn(entries, degraded) {
          process.send(
            reports,
            codemode_tool.Enforcement(satellite_stage, entries, degraded),
          )
        },
      ),
    ),
  )
}

/// The hermetic build's configuration, under the caller's own identity and
/// the same pooled budget the satellite runs on.
///
/// ## Examples
///
/// ```gleam
/// // codemode.build_config(config, request, deadline, reports).step_id
/// //   == request.step_id
/// ```
///
pub fn build_config(
  config: Config,
  request: codemode_tool.Request,
  deadline_ms: Int,
  reports: Subject(codemode_tool.Enforcement),
) -> build.BuildConfig {
  build.BuildConfig(
    broker: config.broker,
    op_id: request.op_id,
    step_id: request.step_id,
    seed_root: config.seed_root,
    gleam_path: config.gleam_path,
    base_policy: execution_policy(request.base_policy),
    // The Gleam and Erlang toolchains live outside the workspace; the
    // build root is the only thing it may write.
    toolchain_roots: ["/"],
    budget: pooled_budget(config, deadline_ms),
    demand: request.demand,
    env: [#("PATH", config.toolchain_path)],
    dependencies: compile.default_dependencies(),
    timeout_ms: config.build_timeout_ms,
    enforcement: fn(entries, degraded) {
      process.send(
        reports,
        codemode_tool.Enforcement(build_stage, entries, degraded),
      )
    },
  )
}

/// The one pooled budget the whole execution draws on: the build, the
/// node, and every capability call the program makes.
///
/// ## Examples
///
/// ```gleam
/// // codemode.pooled_budget(config, 9000).deadline_ms == 9000
/// ```
///
pub fn pooled_budget(config: Config, deadline_ms: Int) -> Budget {
  budget.Budget(
    max_outstanding: config.max_outstanding,
    deadline_ms: deadline_ms,
  )
}

/// The base policy a code-mode execution is judged against: the session's
/// own, plus the two cap-channel environment names and nothing else.
///
/// See the module doc for why the addition is necessary and what it does
/// not widen. Every other dimension — writable roots, readable roots,
/// protected paths, the network posture, the limits, the scratch — is the
/// session's, unchanged, and each jailed stage then narrows it further.
///
/// ## Examples
///
/// ```gleam
/// // codemode.execution_policy(base).writable_roots == base.writable_roots
/// ```
///
pub fn execution_policy(base: SandboxPolicy) -> SandboxPolicy {
  policy.SandboxPolicy(
    ..base,
    env_allow: list.unique(
      list.append(base.env_allow, [launch.sock_env, launch.token_env]),
    ),
  )
}

// --- translating the pipeline's vocabulary --------------------------------

/// One pipeline outcome in the vocabulary the tool speaks.
///
/// The narrowing is deliberate on one axis only: `satellite.RunError`'s
/// eight variants collapse to the four that read differently to a model —
/// you ran out of time, your program died, it never started, the channel
/// broke — with the pipeline's own reason text carried through verbatim so
/// nothing diagnostic is lost.
///
/// ## Examples
///
/// ```gleam
/// // codemode.translate(pipeline.RunFailed(satellite.DeadlineExceeded))
/// //   == codemode_tool.RunFailed(codemode_tool.DeadlineExceeded)
/// ```
///
pub fn translate(outcome: pipeline.ExecOutcome) -> codemode_tool.ExecResult {
  case outcome {
    pipeline.VetRejected(rejections:) ->
      codemode_tool.VetRejected(list.map(rejections, rejection))
    pipeline.CompileFailed(error:) ->
      codemode_tool.CompileFailed(compile_failure(error))
    pipeline.RunFailed(error:) -> codemode_tool.RunFailed(run_failure(error))
    pipeline.Ran(source: _, artifact:, outcome:) ->
      codemode_tool.Ran(
        outcome: program_outcome(outcome),
        manifest_hash: artifact.manifest_hash,
      )
  }
}

fn rejection(rejection: vet.Rejection) -> codemode_tool.Rejection {
  codemode_tool.Rejection(
    rule: case rejection.rule {
      vet.NoForeignInterface -> codemode_tool.NoForeignInterface
      vet.ImportNotAllowed -> codemode_tool.ImportNotAllowed
      vet.Unparseable -> codemode_tool.Unparseable
    },
    detail: rejection.detail,
    location: case rejection.location {
      vet.SourceSpan(start:, end:) -> codemode_tool.SourceSpan(start:, end:)
      vet.SourcePoint(byte_offset:) -> codemode_tool.SourcePoint(byte_offset:)
      vet.Unlocated -> codemode_tool.Unlocated
    },
  )
}

fn compile_failure(
  error: compile.CompileError,
) -> codemode_tool.CompileFailure {
  case error {
    compile.WorkspaceSetupFailed(reason:) ->
      codemode_tool.WorkspaceSetupFailed(reason:)
    compile.BuildRejected(diagnostics:) ->
      codemode_tool.BuildRejected(diagnostics:)
    compile.BuildUnavailable(reason:) -> codemode_tool.BuildUnavailable(reason:)
    compile.ArtifactIncomplete(reason:) ->
      codemode_tool.ArtifactIncomplete(reason:)
  }
}

fn run_failure(error: satellite.RunError) -> codemode_tool.RunFailure {
  case error {
    satellite.DeadlineExceeded -> codemode_tool.DeadlineExceeded
    satellite.SatelliteGone(reason:) -> codemode_tool.SatelliteGone(reason:)
    satellite.ChannelFaulted(reason:) -> codemode_tool.ChannelFaulted(reason:)
    satellite.OutcomeMalformed(reason:) ->
      codemode_tool.ChannelFaulted(
        reason: "malformed outcome frame: " <> reason,
      )
    satellite.TokenMintFailed(reason:) ->
      codemode_tool.StartFailed(
        reason: "the cap token would not mint: " <> reason,
      )
    satellite.TokenFileFailed(reason:) ->
      codemode_tool.StartFailed(
        reason: "the cap token file could not be written: " <> reason,
      )
    satellite.HostUnavailable(reason:) ->
      codemode_tool.StartFailed(reason: "the cap-channel host: " <> reason)
    satellite.LaunchRejected(reason:) -> codemode_tool.StartFailed(reason:)
  }
}

fn program_outcome(outcome: satellite.Outcome) -> codemode_tool.Outcome {
  case outcome {
    satellite.Completed(value:) -> codemode_tool.Completed(value:)
    satellite.Errored(message:, details:) ->
      codemode_tool.Errored(message:, details:)
  }
}

// --- what actually ran -----------------------------------------------------

// Drains the enforcement reports, waiting the grace once more after the
// last one. Every receive is bounded, so a stage that never reports costs
// one grace period and is then reported as unreported — which is the whole
// point: a result must never imply a jail that was not applied.
fn drain(
  reports: Subject(codemode_tool.Enforcement),
  seen: List(codemode_tool.Enforcement),
) -> List(codemode_tool.Enforcement) {
  case process.receive(reports, enforcement_grace_ms) {
    Ok(report) -> drain(reports, [report, ..seen])
    Error(Nil) -> list.reverse(seen)
  }
}

fn directory_of(path: String) -> String {
  case string.split(path, "/") {
    [_file] -> "."
    parts ->
      case list.reverse(parts) {
        [_file, ..rest] ->
          case string.join(list.reverse(rest), "/") {
            "" -> "/"
            directory -> directory
          }
        [] -> "."
      }
  }
}
