//// The session's language-server manager: the one process that knows which
//// server is running, and the `lsp/query.Door` every surface asks through
//// (ADR-013 §§1, 3–6).
////
//// # Why the work is split the way it is
////
//// ADR-013 §1 records that the jailed exec path has no backpressure: the
//// relay forwards every stdout chunk as a message and stdin is a cast. So
//// nothing that owns a mailbox on that path may block, and the manager is
//// built around that rule rather than around convenience.
////
//// - **The manager actor** (`Manager`) holds only small state: which
////   server is running (or starting), the callers waiting for a start,
////   and the paths the running server holds open, so a restart can re-open
////   them. It never reads disk, never talks to a server, and never waits.
//// - **A keeper** is one short-lived-then-long-lived process per server
////   start. It waits for the previous server's keeper to finish stopping,
////   runs the enforcement probe, starts the `lsp/client` actor — whose
////   owner it therefore is — re-opens the documents the dead server held,
////   and reports. Then it holds the client until told to release it, or
////   until the client dies. A start takes seconds; it takes them here,
////   where nobody's mailbox is waiting, and every caller who asked in the
////   meantime is a waiter in the manager's state, answered at once when
////   the keeper reports. One start, however many callers.
//// - **The door's closures run in the caller's process.** They ask the
////   manager for the live client, then do the disk reads, the pull-resync,
////   the requests and the conversion to `Site`s themselves. A slow query
////   holds up only the caller who asked it.
////
//// # One server per session
////
//// A query about a file another `{server, root}` owns evicts the running
//// server: its keeper is told to stop it gracefully, and the new keeper
//// waits for that keeper's exit before it starts anything, so two servers
//// never hold the session's helper leases at once. A server that dies is
//// not restarted by the manager; the next query starts it again (lazily),
//// its documents are re-opened from the manager's record, and the answer
//// that paid for the start says so with `Warmth.Started`.
////
//// # The server's view is kept honest in the caller
////
//// Before every query the caller re-reads every document the server holds
//// open and sends a full-text `didChange` for each whose text moved and a
//// `didClose` for each that vanished (ADR-013 §3, "Pull"); the client holds
//// at most 64 open. After a write, `after_write` pushes the new text and
//// waits, bounded, for settled diagnostics.
////
//// # What a server names is gated before the harness reads it
////
//// The jail bounds what a server can read, never which paths it can put in
//// an answer, and the door's reads run in the caller, unjailed. So every
//// path out of an answer — a definition, a reference, a call edge, a
//// published diagnostic, a rename's `WorkspaceEdit` — becomes a `Named`
//// through one gate (`resolve.admit`): `Admitted` when its real location
//// lies under the server's root and under no protected path, `Withheld`
//// otherwise. A withheld file is shown at the server's coordinates with no
//// line text, is never opened on the server (`resync` gates again, being
//// the one place a document is opened), and refuses a rename whole. Without
//// it a hostile project's server could name `~/.loom/owner.token` and have
//// the harness print its first line, or have `references` send any
//// harness-readable file into the jail.
////
//// # The query that starts a server waits for its load
////
//// A server may answer while it loads its project, and `rust-analyzer`
//// does, with empty results rather than errors: a `definition` of `[]`, a
//// rename that edits one file of two. So the query that paid for a start
//// asks the client whether the server is `ready` — whether its work-done
//// progress has gone quiet for `Timing.quiet_ms`, a window that exists
//// because a server may not have begun reporting yet when `initialized`
//// is sent. A server still busy at `Timing.ready_ms` is answered
//// `Unavailable`, worded as a server still loading, and left running.
////
//// A warm query never waits. The measured empty answers were a load-time
//// problem; a warm server re-indexing after an edit answers from its
//// previous state, which is what every editor's client sees too. And a
//// server that begins a token and never ends it would otherwise stall
//// every query for the whole deadline: this way it costs the one "still
//// loading" answer at start, and the next query, warm, proceeds.
//// Diagnostics never wait either: settlement has its own rules and bound,
//// and reports an unsettled block honestly.
////
//// # A silent server costs one deadline, not one per request
////
//// Resolving a bare name asks `definition` once per search hit, and
//// `references` asks `documentSymbol` once per referenced file. The first
//// request of such a batch that times out, or finds the server gone, ends
//// it: the bare name answers `Unavailable`, and the remaining references
//// keep no container.
////
//// # Enforcement is proven before a server starts
////
//// The production backend (`jailed`) clears a trivial probe under exactly
//// the server's policy and the session's enforcement demand before it
//// clears the server itself, and starts the server only if the probe
//// settles undegraded (ADR-013 §1). A server lives for hours; the helper
//// reports what it enforced only in an exit report, and a lease must not
//// learn that it ran unjailed at the end of its life.

import broker/broker.{type CallEvent, type CallSpec}
import broker/budget
import broker/exec
import broker/policy.{type SandboxPolicy}
import client/codemode.{type Toolchain}
import client/lsp/jail
import client/lsp/leases
import client/lsp/profile.{type LspServer, type Places}
import client/lsp/resolve.{type Identity, type Owned, type Symbol}
import core/clock.{type Clock}
import core/ids.{type OpId}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision
import gleam/result
import gleam/string
import lsp/client as lsp
import lsp/protocol.{type Location}
import lsp/query.{
  type Diagnostics, type QueryError, type Served, type Site, type SymbolQuery,
  type Warmth, Served,
}
import lsp/range.{type Position, type TextEdit}
import lsp/text
import mcp/call
import mcp/transport.{type Transport}
import simplifile
import tools/grep
import tools/tool.{type RunningCall}
import weft/registry as address
import weft/state_machine as sm

// --- configuration ---------------------------------------------------------

/// Every bound the manager and its door keep, in milliseconds.
pub type Timing {
  Timing(
    /// The budget for one server start: the whole `initialize` round
    /// trip, which includes a project load (`gopls` answered its first
    /// query 1.8 s cold; `gleam lsp` compiles the project).
    start_ms: Int,
    /// The deadline of one request to the server.
    request_ms: Int,
    /// ADR-013 §3's bound on settled diagnostics.
    settle_ms: Int,
    /// The shutdown grace an evicted or released server gets.
    stop_grace_ms: Int,
    /// How long a new keeper waits for the previous one to finish
    /// stopping before it starts anyway.
    previous_ms: Int,
    /// The bound on the enforcement probe and on one symbol search, each
    /// from clearance to settlement.
    exec_ms: Int,
    /// The longest the query that started a server waits for its
    /// work-done progress to go quiet (`lsp/client.ready`) before it is
    /// answered `Unavailable`. A cold `rust-analyzer` went quiet 3.75 s
    /// after its handshake on a two-file crate, jailed; a real workspace
    /// loads for far longer. Warm queries never wait.
    ready_ms: Int,
    /// The quiet window that query waits, with no progress active, before
    /// it asks: a server may begin reporting its load only after
    /// `initialized` is sent.
    quiet_ms: Int,
  )
}

/// The production bounds: a minute to start, five seconds a request, the
/// ADR's 1.5 s settlement, two seconds of shutdown grace, ten seconds for
/// the probe and for a search, a minute for a server to finish loading,
/// and a 300 ms quiet window after a start.
///
/// ## Examples
///
/// ```gleam
/// assert manager.default_timing().settle_ms == 1500
/// ```
///
pub fn default_timing() -> Timing {
  Timing(
    start_ms: 60_000,
    request_ms: 5000,
    settle_ms: 1500,
    stop_grace_ms: 2000,
    previous_ms: 2000 + lsp.retire_ms + 2000,
    exec_ms: 10_000,
    ready_ms: 60_000,
    quiet_ms: 300,
  )
}

/// One bounded word search for an identifier, over one directory, limited
/// to one server's file extensions (ADR-013 §5, a bare symbol).
pub type Search {
  Search(
    /// The server whose extensions and jail the search uses.
    server: LspServer,
    /// The absolute directory searched.
    root: String,
    /// The identifier, matched as a whole word, literally.
    identifier: String,
  )
}

/// One line a search matched.
pub type Hit {
  Hit(
    /// The absolute path of the file.
    path: String,
    /// The 1-based line number.
    line: Int,
  )
}

/// The most hits a search keeps, and the most distinct files they may
/// fall in. Each kept hit costs one `definition` request, so these bound
/// the door's worst case to a few hundred warm-server milliseconds.
pub const max_search_hits = 200

/// See `max_search_hits`.
pub const max_search_files = 50

/// The effects the manager cannot perform itself — starting a server's
/// transport and searching a tree — and the session's protected paths,
/// which travel with them because they are the session base policy's, and
/// that policy is what the production backend is built from. Closures, so
/// a test drives the manager with a fake language server and an
/// in-process search, and production supplies `jailed`.
pub type Backend {
  Backend(
    /// Builds the transport one server is started over. Runs in the
    /// keeper, so it may block — the production one clears the
    /// enforcement probe first. The `Error` is the refusal's wording.
    connect: fn(Identity) -> Result(Transport, String),
    /// Runs one bounded word search, answering the matched lines.
    search: fn(Search) -> Result(List(Hit), String),
    /// The session base policy's `protected` list, absolute. No path a
    /// server names is read under one of these (`resolve.admit`).
    protected: List(String),
  )
}

/// Everything one manager needs.
///
/// Constructor invariants: `workspace` is absolute; `servers` is the
/// catalogue's `[lsp.<name>]` list, whose extensions no two servers
/// share.
pub type Config {
  Config(
    /// The session's workspace root.
    workspace: String,
    /// The configured servers.
    servers: List(LspServer),
    /// The effects.
    backend: Backend,
    /// The bounds.
    timing: Timing,
  )
}

// --- the production backend ------------------------------------------------

/// What the jailed backend needs from the session: where the server runs,
/// what the session grants, the enforcement it demands, and the broker
/// seams a clearance goes through.
pub type Jailed {
  Jailed(
    /// The session's workspace root.
    workspace: String,
    /// The session's base policy (the one `bash` clears under).
    session_base: SandboxPolicy,
    /// The session's enforcement demand, `settings.demand` — the same one
    /// `bash` uses. The server, its probe and every search clear under it.
    demand: exec.EnforcementDemand,
    /// Code mode's located toolchain, which is the `gleam` a bare `gleam`
    /// command means (`jail.locate`).
    toolchain: Option(Toolchain),
    /// The daemon's own `HOME` and cache directory, which expand a
    /// table's `~/` and `<cache>/` roots.
    places: Places,
    /// The daemon's environment, read for `PATH` and the configured names.
    reading: fn(String) -> Result(String, Nil),
    /// Clears and dispatches one call: `tool.broker_runner` in production.
    run: fn(CallSpec, Subject(CallEvent)) -> Result(RunningCall, broker.Refusal),
    /// Aborts one step of the language servers' operation:
    /// `broker.abort_step(broker, op_id, step_id: _)` in production.
    abort_step: fn(String) -> Nil,
    /// The session's helper-lease counter.
    leases: leases.Leases,
    /// The language servers' attribution operation (`jail.operation`).
    op_id: OpId,
    /// The session's clock, for budget deadlines.
    clock: Clock,
    /// The probe's and each search's bound.
    exec_ms: Int,
  )
}

/// The production backend: every server and every search runs in the jail
/// under the session's demand, and a server starts only after the probe
/// proves the jail enforced what was demanded.
///
/// ## Examples
///
/// ```gleam
/// // manager.jailed(manager.Jailed(workspace:, session_base:, demand:
/// //   settings.demand, run: tool.broker_runner(broker:, waiting:
/// //   jail.clearance_wait_ms), ..))
/// ```
///
pub fn jailed(jailed: Jailed) -> Backend {
  Backend(
    connect: connect_jailed(jailed, _),
    search: search_jailed(jailed, _),
    protected: jailed.session_base.protected,
  )
}

/// The command the enforcement probe runs: the jail's own shell, exiting
/// at once. `/bin/sh` is what every jailed command already runs under
/// (`client/serve.shell_path`), and the helper's system view binds `/bin`
/// on every Linux layout; a server's own `--version` flag is not
/// universal, and a probe must not depend on the thing it vets.
pub const probe_argv = ["/bin/sh", "-c", "exit 0"]

/// Builds one server's jail, proves enforcement with the probe, and
/// answers the transport the client is started over.
///
/// ## Examples
///
/// ```gleam
/// // manager.connect_jailed(jailed, Identity(gleam, "/work/app"))
/// // -> Ok(transport.ChannelTransport(..))
/// ```
///
pub fn connect_jailed(
  jailed: Jailed,
  identity: Identity,
) -> Result(Transport, String) {
  use built <- result.try(jail_for(jailed, identity.server, identity.root))
  let #(now, _clock) = clock.read(jailed.clock)
  use Nil <- result.try(probe(
    jailed.run,
    built,
    jailed.demand,
    jailed.op_id,
    now_ms: now,
    waiting: jailed.exec_ms,
  ))

  // The probe just proved this demand holds under this policy, so the
  // lease clears under the same demand and nothing weaker or stronger.
  let spec =
    jail.call_spec(built, jailed.op_id, now_ms: now, demand: jailed.demand)
  Ok(
    jail.transport(jail.Launch(
      run: jailed.run,
      abort: fn() { jailed.abort_step(built.step_id) },
      leases: jailed.leases,
      spec:,
      scratch: built.scratch,
      timing: jail.default_timing(),
    )),
  )
}

// Locates the executable and composes the jail. The scratch directory's
// `tmp` is made here too: the probe and a search clear under a policy that
// binds it, and the relay makes it only for the server itself.
fn jail_for(
  jailed: Jailed,
  server: LspServer,
  root: String,
) -> Result(jail.Jail, String) {
  use executable <- result.try(jail.locate(server, jailed.toolchain))
  let placement =
    jail.Placement(
      server:,
      root:,
      workspace: jailed.workspace,
      executable:,
      places: jailed.places,
    )
  use built <- result.try(jail.policy_for(
    placement,
    jailed.session_base,
    reading: jailed.reading,
  ))
  use Nil <- result.try(
    simplifile.create_directory_all(built.scratch <> "/tmp")
    |> result.map_error(fn(error) {
      "the language server's scratch directory could not be made: "
      <> simplifile.describe_error(error)
    }),
  )
  Ok(built)
}

/// Clears `probe_argv` under exactly the server's policy and `demand`, and
/// answers `Ok` only if it exited cleanly under that demand.
///
/// Under `PlatformEnforcement` a helper that could not apply a layer
/// settles the probe as `DegradedExecution` or `DegradedHelper`, and the
/// refusal names the layers it skipped. Under `BestEffort` the helper
/// reports but never refuses, so whatever runs is accepted — which is what
/// that demand means. The probe has its own step (`<step>/probe`), so it
/// never counts against the lease's one outstanding execution.
///
/// ## Examples
///
/// ```gleam
/// // manager.probe(run, built, exec.PlatformEnforcement, op, now_ms: 0, waiting: 10_000)
/// // -> Error("… could not enforce … (skip:cgroup)")
/// ```
///
pub fn probe(
  run: fn(CallSpec, Subject(CallEvent)) -> Result(RunningCall, broker.Refusal),
  built: jail.Jail,
  demand: exec.EnforcementDemand,
  op_id: OpId,
  now_ms now_ms: Int,
  waiting waiting: Int,
) -> Result(Nil, String) {
  let spec =
    broker.CallSpec(
      ..jail.call_spec(built, op_id, now_ms:, demand:),
      step_id: built.step_id <> "/probe",
      argv: probe_argv,
      budget: budget.Budget(max_outstanding: 1, deadline_ms: now_ms + waiting),
    )
  let events = process.new_subject()
  use running <- result.try(
    run(spec, events) |> result.map_error(jail.refusal_text),
  )
  running.stdin(<<>>, True)
  case tool.collect_events(events, waiting:) {
    Error(Nil) -> {
      running.cancel()
      Error(
        "the language server was not started: its enforcement probe did not "
        <> "settle within "
        <> int.to_string(waiting)
        <> " ms",
      )
    }
    Ok(collected) -> judged(collected.outcome)
  }
}

// The probe's verdict. Only a clean exit under the demand passes; every
// failure names what went wrong, and a degraded one names the layers the
// helper reported it skipped, which is what an operator has to go and fix.
fn judged(outcome: broker.CallOutcome) -> Result(Nil, String) {
  case outcome {
    broker.CallExited(result:) if result.code == 0 -> Ok(Nil)
    broker.CallExited(result:) ->
      Error(
        "the language server was not started: its enforcement probe exited "
        <> "with code "
        <> int.to_string(result.code),
      )
    broker.CallFailed(failure:) ->
      Error(
        "the language server was not started: the jail could not enforce "
        <> "the demanded policy ("
        <> tool.exec_failure_text(failure)
        <> skipped_layers(failure)
        <> ")",
      )
  }
}

fn skipped_layers(failure: exec.ExecFailure) -> String {
  case failure {
    exec.DegradedExecution(result:) ->
      case list.filter(result.enforcement, string.starts_with(_, "skip:")) {
        [] -> ""
        skipped -> "; skipped " <> string.join(skipped, ", ")
      }
    exec.DegradedHelper(features:) ->
      "; the helper reported " <> string.join(features, " ")
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

/// How many matching lines one file may contribute to a search, so one
/// file full of calls cannot spend the whole hit budget.
const max_hits_per_file = 4

/// Runs `rg` in the jail — the server's jail with the project read-only,
/// under the session's demand — as a literal whole-word search restricted
/// to the server's extensions, and answers at most `max_search_hits` hits
/// in at most `max_search_files` files.
///
/// ## Examples
///
/// ```gleam
/// // manager.search_jailed(jailed, Search(gleam, "/work/app", "greet"))
/// // -> Ok([Hit("/work/app/src/app.gleam", 3)])
/// ```
///
pub fn search_jailed(
  jailed: Jailed,
  search: Search,
) -> Result(List(Hit), String) {
  let server =
    profile.LspServer(..search.server, project: profile.ProjectReadOnly)
  use built <- result.try(jail_for(jailed, server, search.root))
  let #(now, _clock) = clock.read(jailed.clock)
  let argv =
    list.flatten([
      [
        "rg",
        "--json",
        "--word-regexp",
        "--fixed-strings",
        "--max-count",
        int.to_string(max_hits_per_file),
      ],
      list.flat_map(search.server.extensions, fn(extension) {
        ["--glob", "*" <> extension]
      }),
      ["--", search.identifier, search.root],
    ])

  // The lease's zeros would let a search run and print without bound; a
  // search is a command, so it gets a command's caps. Both are narrower
  // than the lease base's zeros, so composition narrows nothing.
  let requirements =
    policy.SandboxPolicy(
      ..built.requirements,
      limits: policy.Limits(
        ..built.requirements.limits,
        wall_s: int.max(jailed.exec_ms / 1000, 1),
        output_bytes: 4_194_304,
      ),
    )
  let spec =
    broker.CallSpec(
      ..jail.call_spec(built, jailed.op_id, now_ms: now, demand: jailed.demand),
      step_id: built.step_id <> "/search",
      requirements:,
      argv:,
      budget: budget.Budget(
        max_outstanding: 4,
        deadline_ms: now + jailed.exec_ms,
      ),
    )
  let events = process.new_subject()
  use running <- result.try(
    jailed.run(spec, events) |> result.map_error(jail.refusal_text),
  )
  running.stdin(<<>>, True)
  use collected <- result.try(
    tool.collect_events(events, waiting: jailed.exec_ms)
    |> result.map_error(fn(_nil) {
      running.cancel()
      "the symbol search did not settle within its bound"
    }),
  )
  search_result(collected)
}

// Why a bare name could not be searched for when ripgrep is missing, and
// the form of the question that needs no search at all.
const rg_missing = "finding a bare name searches the project with ripgrep (rg), "
  <> "which is not installed where the sandbox can run it; give the `path` "
  <> "(and the 1-based `line`) of a file that mentions the symbol, and the "
  <> "language server is asked directly"

// ripgrep exits 0 with matches and 1 without; anything else is its own
// error, which it wrote to stderr. 126 and 127 are the helper's own codes
// for a program it could not resolve or run inside the jail: ripgrep is
// not installed where the jail can see it, which a bare name cannot work
// around but a named file can, so that is what the answer says.
fn search_result(collected: tool.Collected) -> Result(List(Hit), String) {
  case collected.outcome {
    broker.CallExited(result:) if result.code == 126 || result.code == 127 ->
      Error(rg_missing)
    broker.CallExited(result:) if result.code == 0 || result.code == 1 ->
      bit_array.to_string(collected.stdout)
      |> result.unwrap("")
      |> grep.parse_matches
      |> list.map(fn(match) { Hit(path: match.path, line: match.line) })
      |> bounded_hits
      |> Ok
    broker.CallExited(result:) ->
      Error(
        "the symbol search failed with code "
        <> int.to_string(result.code)
        <> ": "
        <> string.trim(result.unwrap(bit_array.to_string(collected.stderr), "")),
      )
    broker.CallFailed(failure: exec.RefusedByHelper(code: "spawn_failed", ..)) ->
      Error(rg_missing)
    broker.CallFailed(failure:) ->
      Error("the symbol search failed: " <> tool.exec_failure_text(failure))
  }
}

/// Keeps at most `max_hits_per_file` hits per file, `max_search_files`
/// files and `max_search_hits` hits, in the order found.
///
/// ## Examples
///
/// ```gleam
/// // manager.bounded_hits(hits) |> list.length <= manager.max_search_hits
/// ```
///
pub fn bounded_hits(hits: List(Hit)) -> List(Hit) {
  let #(kept, _counts) =
    list.fold(hits, #([], dict.new()), fn(acc, hit) {
      let #(kept, counts) = acc
      let seen = dict.get(counts, hit.path)
      let admitted = case seen {
        Ok(count) -> count < max_hits_per_file
        Error(Nil) -> dict.size(counts) < max_search_files
      }
      case admitted {
        False -> acc
        True -> #(
          [hit, ..kept],
          dict.insert(counts, hit.path, result.unwrap(seen, 0) + 1),
        )
      }
    })
  list.reverse(kept) |> list.take(max_search_hits)
}

// --- the manager actor -------------------------------------------------------

/// A handle on a manager. Sendable; the door's closures carry it.
///
/// It reaches the manager through `reach` rather than holding one subject,
/// because the session runs its manager as a supervised child under a
/// reclaimable address (`supervised`): a replacement answers on a fresh
/// inbox, and a handle that had captured the first one would talk to a
/// corpse for the rest of the session. `start` answers a handle whose
/// `reach` is that one incarnation's subject, which is what a test wants.
pub opaque type Manager {
  Manager(
    reach: fn() -> Result(Subject(Msg), Nil),
    config: Config,
    workspaces: List(String),
  )
}

/// What a caller is handed for one query: the live client, and whether
/// this query paid for starting it.
type Granted {
  Granted(client: lsp.Client, warmth: Warmth)
}

/// What the manager knows without waiting: the server it last ran, and
/// its client if it is serving now.
type Peeked {
  Peeked(identity: Option(Identity), client: Option(lsp.Client))
}

/// The manager's message set. Opaque: only this module sends it, and it is
/// public only so a host can mint the `weft/registry` address a supervised
/// manager binds (`supervised`).
pub opaque type Msg {
  // A caller wants the server for `identity`, started if need be.
  Acquire(identity: Identity, reply: Subject(Result(Granted, QueryError)))

  // A caller wants to know what is running, without starting anything.
  Peek(reply: Subject(Peeked))

  // A caller opened these documents on the server for `identity`.
  Opened(identity: Identity, paths: List(String))

  // A keeper's start finished.
  KeeperReady(keeper: Pid, outcome: Result(lsp.Client, String))

  // A monitored keeper exited.
  KeeperDown(pid: Pid, reason: process.ExitReason)

  // A port monitor fired; the manager monitors none, so this is noise.
  StrayDown

  // The session is ending. The reply names the keeper still stopping a
  // server, if any, so `stop` can wait for its exit in the caller.
  Shutdown(reply: Subject(Option(Pid)))
}

// A running keeper: its pid for the monitor, its subject for `Release`.
type Keeper {
  Keeper(pid: Pid, subject: Subject(KeeperMsg))
}

// What the manager is doing. The payloads never change while in a phase
// (docs/weft.md rule 1); the waiters and the open-path record move per
// event and live in `Data`.
type Phase {
  // No server is running. The next `Acquire` starts one.
  Idle

  // A keeper is starting `identity`. Acquisitions for it wait; for any
  // other identity they are postponed until this start settles, so a
  // start is never evicted half-way.
  Starting(identity: Identity, keeper: Keeper)

  // `client` serves `identity`, held by `keeper`.
  Running(identity: Identity, client: lsp.Client, keeper: Keeper)
}

type Data {
  Data(
    config: Config,
    // The manager's own subject, which each keeper reports to.
    self: Subject(Msg),
    waiters: List(Subject(Result(Granted, QueryError))),
    // The identity last started, kept after its death so a restart knows
    // which documents to re-open.
    last: Option(Identity),
    // The documents `last`'s server holds open, most recent first, at most
    // `lsp.max_open_documents`.
    opened: List(String),
  )
}

/// Starts a manager over `config`. The manager is linked to the caller,
/// and the handle reaches exactly this incarnation.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(manager) = manager.start(config)
/// // let door = manager.door(manager)
/// ```
///
pub fn start(config: Config) -> Result(Manager, String) {
  builder(config)
  |> sm.start
  |> result.map(fn(started) {
    let subject = started.data
    handle_for(fn() { Ok(subject) }, config)
  })
  |> result.map_error(fn(error) {
    "the language-server manager would not start: " <> string.inspect(error)
  })
}

/// The manager as a child of the session's service supervisor, bound to
/// `name` so the handle `addressed` builds reaches whichever incarnation
/// is current.
///
/// Transient: a manager that crashes is replaced, while one that `stop`
/// ended is not. A replacement starts `Idle` with no record of what the
/// dead one ran. That costs nothing a query cannot rebuild: the dead
/// manager's keepers saw it go and stopped their servers (a keeper
/// monitors its manager), and the next query starts a server again, cold.
///
/// ## Examples
///
/// ```gleam
/// // let name = address.new_address(namespace)
/// // sup.add(tree, manager.supervised(name, config))
/// // let door = manager.door(manager.addressed(name, config))
/// ```
///
pub fn supervised(
  name: address.Address(Msg),
  config: Config,
) -> supervision.ChildSpecification(Subject(Msg)) {
  builder(config)
  |> sm.addressed(name)
  |> sm.supervised
  |> supervision.restart(supervision.Transient)
}

/// The handle on the manager `supervised` binds to `name`. It may be built
/// before the manager starts: every exchange resolves the address when it
/// is made, and a manager that is not running answers `Unavailable`.
///
/// ## Examples
///
/// ```gleam
/// // let door = manager.door(manager.addressed(name, config))
/// ```
///
pub fn addressed(name: address.Address(Msg), config: Config) -> Manager {
  handle_for(fn() { address.lookup(name) }, config)
}

fn handle_for(
  reach: fn() -> Result(Subject(Msg), Nil),
  config: Config,
) -> Manager {
  Manager(
    reach:,
    config:,
    workspaces: list.unique([
      resolve.workspace_real(config.workspace),
      config.workspace,
    ]),
  )
}

// The one builder `start` and `supervised` share, so a supervised manager
// is exactly the machine a test starts.
fn builder(config: Config) -> sm.Builder(Phase, Data, Msg, Subject(Msg)) {
  sm.new_with_initialiser(1000, fn(commands) {
    // Keepers are monitored as they are started, so one selector arm for
    // every DOWN covers all of them.
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_monitors(fn(down) {
        case down {
          process.ProcessDown(pid:, reason:, monitor: _) ->
            KeeperDown(pid:, reason:)
          process.PortDown(..) -> StrayDown
        }
      })
    sm.initialised(
      Idle,
      Data(config:, self: commands, waiters: [], last: None, opened: []),
    )
    |> sm.selecting(selector)
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.on_event(handle)
}

/// Stops the manager and the server it runs, and waits — bounded by
/// `Timing.previous_ms`, the same bound an evicting keeper waits for its
/// predecessor — for the server's keeper to finish stopping it
/// gracefully: `shutdown`, `exit`, stdin EOF, and the relay's release of
/// the helper lease once the broker settles the execution. The wait runs
/// here in the caller, never in the manager. The language servers'
/// operation abort at session end is the backstop for a server that
/// outlives the bound (ADR-013 §1). A manager that is not running is
/// already stopped.
///
/// ## Examples
///
/// ```gleam
/// // manager.stop(manager)
/// ```
///
pub fn stop(manager: Manager) -> Nil {
  case ask(manager, waiting: 5000, sending: Shutdown) {
    Ok(Some(keeper)) -> {
      let watch = process.monitor(keeper)
      let _gone =
        process.new_selector()
        |> process.select_specific_monitor(watch, fn(_down) { Nil })
        |> process.selector_receive(manager.config.timing.previous_ms)
      process.demonitor_process(watch)
    }
    Ok(None) | Error(_fault) -> Nil
  }
}

// One exchange with whichever incarnation the handle reaches now. An
// address with nobody bound to it is the dead callee a monitored call
// would report, because to the caller the two are the same absence.
fn ask(
  manager: Manager,
  waiting waiting: Int,
  sending make: fn(Subject(reply)) -> Msg,
) -> Result(reply, call.CallFault) {
  case manager.reach() {
    Ok(subject) -> call.try_call(subject, waiting:, sending: make)
    Error(Nil) -> Error(call.CalleeGone)
  }
}

// A cast to the current incarnation; lost, harmlessly, if there is none.
fn tell(manager: Manager, message: Msg) -> Nil {
  case manager.reach() {
    Ok(subject) -> process.send(subject, message)
    Error(Nil) -> Nil
  }
}

fn handle(phase: Phase, data: Data, msg: Msg) -> sm.Next(Phase, Data, Msg) {
  case phase, msg {
    Idle, Acquire(identity:, reply:) -> begin(data, identity, None, reply)

    // Another caller for the start in progress joins its waiters: one
    // start, however many ask.
    Starting(identity: starting, keeper: _), Acquire(identity:, reply:) ->
      case resolve.same(starting, identity) {
        True -> sm.keep(Data(..data, waiters: [reply, ..data.waiters]))
        False -> sm.keep(data) |> sm.postpone
      }

    // A different project evicts the running server. Its keeper stops it
    // after this handler returns; the new keeper waits for that keeper's
    // exit, so the handler itself waits for nothing.
    Running(identity: running, client:, keeper:), Acquire(identity:, reply:) ->
      case resolve.same(running, identity) {
        True -> {
          process.send(reply, Ok(Granted(client:, warmth: query.Warm)))
          sm.keep(data)
        }
        False -> {
          process.send(keeper.subject, Release)
          begin(data, identity, Some(keeper.pid), reply)
        }
      }

    Idle, Peek(reply:) -> {
      process.send(reply, Peeked(identity: data.last, client: None))
      sm.keep(data)
    }
    Starting(identity:, keeper: _), Peek(reply:) -> {
      process.send(reply, Peeked(identity: Some(identity), client: None))
      sm.keep(data)
    }
    Running(identity:, client:, keeper: _), Peek(reply:) -> {
      process.send(
        reply,
        Peeked(identity: Some(identity), client: Some(client)),
      )
      sm.keep(data)
    }

    Idle, Opened(identity:, paths:)
    | Starting(..), Opened(identity:, paths:)
    | Running(..), Opened(identity:, paths:)
    -> sm.keep(opened(data, identity, paths))

    // The start settled. Every waiter hears the same answer, and a
    // postponed acquisition for another project replays on the way out.
    Starting(identity:, keeper:), KeeperReady(keeper: pid, outcome:)
      if pid == keeper.pid
    -> settle_start(data, identity, keeper, outcome)
    Starting(..), KeeperReady(..)
    | Idle, KeeperReady(..)
    | Running(..), KeeperReady(..)
    -> sm.keep(data)

    // A keeper that dies before reporting took its start with it.
    Starting(identity: _, keeper:), KeeperDown(pid:, reason:)
      if pid == keeper.pid
    -> {
      answer(
        data.waiters,
        Error(query.Unavailable(
          reason: "the language server's starter died: "
          <> string.inspect(reason),
        )),
      )
      sm.transition(to: Idle, data: Data(..data, waiters: []))
    }

    // The running server's keeper exits when its client dies. Nothing is
    // restarted here; the next query starts it again and re-opens
    // `opened`, which is kept for exactly that.
    Running(identity: _, client: _, keeper:), KeeperDown(pid:, reason: _)
      if pid == keeper.pid
    -> sm.transition(to: Idle, data:)

    // An evicted keeper finishing its stop, or a failed start's keeper
    // exiting after its report: neither is the current one.
    Idle, KeeperDown(..)
    | Starting(..), KeeperDown(..)
    | Running(..), KeeperDown(..)
    -> sm.keep(data)

    Idle, StrayDown | Starting(..), StrayDown | Running(..), StrayDown ->
      sm.keep(data)

    Idle, Shutdown(reply:) -> {
      process.send(reply, None)
      sm.stop()
    }
    Starting(identity: _, keeper:), Shutdown(reply:)
    | Running(identity: _, client: _, keeper:), Shutdown(reply:)
    -> {
      process.send(keeper.subject, Release)
      answer(
        data.waiters,
        Error(query.Unavailable(reason: "the session is ending")),
      )
      process.send(reply, Some(keeper.pid))
      sm.stop()
    }
  }
}

// Starts a keeper for `identity`. `previous` is the keeper just told to
// release, whose exit the new one waits for. A restart of the identity
// last run re-opens its documents; a different identity starts clean.
fn begin(
  data: Data,
  identity: Identity,
  previous: Option(Pid),
  reply: Subject(Result(Granted, QueryError)),
) -> sm.Next(Phase, Data, Msg) {
  let reopen = case data.last {
    Some(last) ->
      case resolve.same(last, identity) {
        True -> data.opened
        False -> []
      }
    None -> []
  }
  let data = Data(..data, last: Some(identity), opened: reopen)
  case start_keeper(data.config, data.self, identity, previous, reopen) {
    Ok(keeper) -> {
      process.monitor(keeper.pid)
      sm.transition(
        to: Starting(identity:, keeper:),
        data: Data(..data, waiters: [reply]),
      )
    }
    Error(reason) -> {
      process.send(reply, Error(query.NoServer(reason:)))
      sm.transition(to: Idle, data:)
    }
  }
}

fn settle_start(
  data: Data,
  identity: Identity,
  keeper: Keeper,
  outcome: Result(lsp.Client, String),
) -> sm.Next(Phase, Data, Msg) {
  let data_after = Data(..data, waiters: [])
  case outcome {
    Ok(client) -> {
      let warmth = query.Started(server: identity.server.name)
      answer(data.waiters, Ok(Granted(client:, warmth:)))
      sm.transition(to: Running(identity:, client:, keeper:), data: data_after)
    }
    Error(reason) -> {
      answer(data.waiters, Error(query.NoServer(reason:)))
      sm.transition(to: Idle, data: data_after)
    }
  }
}

fn answer(
  waiters: List(Subject(Result(Granted, QueryError))),
  outcome: Result(Granted, QueryError),
) -> Nil {
  list.each(waiters, process.send(_, outcome))
}

// Records documents opened on `identity`'s server, most recent first. A
// report about an identity that is no longer the last one is stale.
fn opened(data: Data, identity: Identity, paths: List(String)) -> Data {
  case data.last {
    Some(last) ->
      case resolve.same(last, identity) {
        True ->
          Data(
            ..data,
            opened: list.append(paths, data.opened)
              |> list.unique
              |> list.take(lsp.max_open_documents),
          )
        False -> data
      }
    None -> data
  }
}

// --- the keeper --------------------------------------------------------------

// What moves a keeper. `Begin` is injected at start; `PreviousGone` is the
// previous keeper's DOWN or the bound on waiting for it; `Release` is the
// manager's; the two DOWNs are the monitors.
type KeeperMsg {
  Begin
  PreviousGone
  Release
  ClientDown
  ManagerDown
}

// A keeper's life. The start runs inside the `Begin` handler of
// `Beginning`: the keeper serves nobody while it starts, and a `Release`
// that arrives meanwhile simply waits in its mailbox.
type KeeperPhase {
  // Waiting for the evicted server's keeper to exit.
  AwaitingPrevious

  // About to start the server.
  Beginning

  // Holding the running client.
  Holding(client: lsp.Client)
}

type Keeping {
  Keeping(
    config: Config,
    identity: Identity,
    reopen: List(String),
    manager: Subject(Msg),
    commands: Subject(KeeperMsg),
    manager_watch: process.Monitor,
  )
}

fn start_keeper(
  config: Config,
  manager: Subject(Msg),
  identity: Identity,
  previous: Option(Pid),
  reopen: List(String),
) -> Result(Keeper, String) {
  let manager_pid = process.self()
  sm.new_with_initialiser(1000, fn(commands) {
    let manager_watch = process.monitor(manager_pid)
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_specific_monitor(manager_watch, fn(_down) {
        ManagerDown
      })
    let #(phase, selector) = case previous {
      Some(pid) -> #(
        AwaitingPrevious,
        process.select_specific_monitor(selector, process.monitor(pid), fn(_) {
          PreviousGone
        }),
      )
      None -> #(Beginning, selector)
    }
    let keeping =
      Keeping(config:, identity:, reopen:, manager:, commands:, manager_watch:)
    sm.initialised(phase, keeping)
    |> sm.selecting(selector)
    |> sm.returning(commands)
    |> sm.continuing(Begin)
    |> Ok
  })
  |> sm.on_event(keep_server)
  |> sm.unlinked
  |> sm.start
  |> result.map(fn(started) { Keeper(pid: started.pid, subject: started.data) })
  |> result.map_error(fn(error) {
    "the language server's keeper would not start: " <> string.inspect(error)
  })
}

fn keep_server(
  phase: KeeperPhase,
  keeping: Keeping,
  msg: KeeperMsg,
) -> sm.Next(KeeperPhase, Keeping, KeeperMsg) {
  case phase, msg {
    // The previous server gets a bounded while to stop; past it the start
    // goes ahead and the lease cap is what refuses an overlap.
    AwaitingPrevious, Begin ->
      sm.keep(keeping)
      |> sm.with_state_timeout(
        after: keeping.config.timing.previous_ms,
        sending: PreviousGone,
      )
    AwaitingPrevious, PreviousGone ->
      sm.transition(to: Beginning, data: keeping) |> sm.then_handle(Begin)
    AwaitingPrevious, Release | Beginning, Release ->
      sm.keep(keeping) |> sm.postpone
    AwaitingPrevious, ManagerDown | Beginning, ManagerDown -> sm.stop()

    Beginning, Begin -> started(keeping, begin_server(keeping))

    // Unreachable: the previous keeper's monitor belongs to
    // `AwaitingPrevious`, and no client exists before `Holding`.
    Beginning, PreviousGone
    | AwaitingPrevious, ClientDown
    | Beginning, ClientDown
    -> sm.keep(keeping)

    Holding(client:), Release | Holding(client:), ManagerDown -> {
      let _report = lsp.stop(client, keeping.config.timing.stop_grace_ms)
      sm.stop()
    }

    // The client died: its server exited or its transport faulted. The
    // keeper's exit is how the manager learns it.
    Holding(_), ClientDown -> sm.stop()
    Holding(_), Begin | Holding(_), PreviousGone -> sm.keep(keeping)
  }
}

// Reports the start and moves to holding the client, now watched.
fn started(
  keeping: Keeping,
  outcome: Result(lsp.Client, String),
) -> sm.Next(KeeperPhase, Keeping, KeeperMsg) {
  process.send(keeping.manager, KeeperReady(keeper: process.self(), outcome:))
  case outcome {
    Error(_reason) -> sm.stop()
    Ok(client) -> {
      let selector =
        process.new_selector()
        |> process.select(keeping.commands)
        |> process.select_specific_monitor(keeping.manager_watch, fn(_) {
          ManagerDown
        })
        |> process.select_specific_monitor(
          process.monitor(lsp.pid(client)),
          fn(_) { ClientDown },
        )
      sm.transition(to: Holding(client:), data: keeping)
      |> sm.with_selector(selector)
    }
  }
}

// The start itself: the backend's transport (the probe runs in there),
// the client's handshake, then the documents the dead server held.
fn begin_server(keeping: Keeping) -> Result(lsp.Client, String) {
  let identity = keeping.identity
  let config = keeping.config
  use transport <- result.try(config.backend.connect(identity))
  let options =
    lsp.Options(
      ..lsp.options(
        server: identity.server.name,
        root: identity.root,
        language_id: identity.server.language_id,
      ),
      initialize_ms: config.timing.start_ms,
      request_ms: config.timing.request_ms,
    )
  use client <- result.try(
    lsp.start(transport, options) |> result.map_error(start_error_text),
  )

  // A restart re-sends what the dead server held, read now. A document
  // that has vanished is simply not re-opened.
  let reopened =
    list.filter_map(keeping.reopen, fn(path) {
      resolve.read_text(path)
      |> result.map(lsp.Change(path:, text: _))
      |> result.replace_error(Nil)
    })
  let _ = case reopened {
    [] -> Ok(Nil)
    ops -> lsp.sync(client, ops)
  }
  Ok(client)
}

fn start_error_text(error: lsp.StartError) -> String {
  case error {
    lsp.BadRoot(root:) -> "the project root " <> root <> " is not absolute"
    lsp.TransportRefused(reason:) -> reason
    lsp.HandshakeFailed(error:) -> handshake_text(error)
    lsp.EncodingUnsupported(encoding:) ->
      "the server chose position encoding "
      <> encoding
      <> ", and only UTF-16 is supported"
  }
}

fn handshake_text(error: lsp.RequestError) -> String {
  "the server's initialize handshake failed: "
  <> case error {
    lsp.Unavailable(reason:) -> reason
    lsp.TimedOut(after_ms:) ->
      "no answer within " <> int.to_string(after_ms) <> " ms"
    lsp.ServerError(code: _, message:) -> message
    lsp.Malformed(reason:) -> reason
    lsp.Unsupported(feature:) -> lsp.feature_method(feature)
    lsp.InvalidPath(path:) -> path
    lsp.EditRefused(kind:, uri:) -> kind <> " " <> uri
  }
}

// --- the door ----------------------------------------------------------------

/// The door every surface asks through, over this manager. Every closure
/// runs in its caller's process and is bounded by the manager's `Timing`.
///
/// `after_write` never starts a server. An edit's result must not wait
/// out a handshake and a full compile, and an edit in one project must not
/// evict the server another project's queries are using; so a write to a
/// file whose server is not the one running answers `None`, exactly as a
/// file no server owns does, and the next query about it starts the
/// server — which then reads the file from disk as it stands.
///
/// ## Examples
///
/// ```gleam
/// // let door = manager.door(manager)
/// // door.definition(query.SymbolQuery("greet", None, None))
/// ```
///
pub fn door(manager: Manager) -> query.Door {
  query.Door(
    definition: definition(manager, _),
    references: references(manager, _),
    hover: hover(manager, _),
    outline: outline(manager, _),
    calls: fn(asked, direction) { calls(manager, asked, direction) },
    diagnostics: diagnostics(manager, _),
    prepare_rename: fn(asked, new_name) {
      prepare_rename(manager, asked, new_name)
    },
    after_write: after_write(manager, _),
  )
}

// One query's hold on the server: the client, whose it is, and whether
// this query started it.
type Session {
  Session(
    manager: Manager,
    client: lsp.Client,
    identity: Identity,
    warmth: Warmth,
  )
}

// A resolved question: the file and position the server is asked at.
type Target {
  Target(session: Session, path: String, at: Position)
}

fn definition(
  manager: Manager,
  asked: SymbolQuery,
) -> Result(Served(List(Site)), QueryError) {
  use target <- result.try(target(manager, asked))
  let session = target.session
  use locations <- result.try(
    lsp.definition(session.client, target.path, target.at, request_ms(session))
    |> result.map_error(request_error(session, _)),
  )
  Ok(Served(value: sites(session, locations), warmth: session.warmth))
}

fn references(
  manager: Manager,
  asked: SymbolQuery,
) -> Result(Served(List(query.Reference)), QueryError) {
  use target <- result.try(target(manager, asked))
  let session = target.session
  use locations <- result.try(
    lsp.references(session.client, target.path, target.at, request_ms(session))
    |> result.map_error(request_error(session, _)),
  )

  let named =
    list.map(locations, fn(location) {
      #(location, named_uri(session, location.uri))
    })

  // A container comes from the referenced file's outline, and `gleam lsp`
  // outlines only documents it holds open, so the referencing files are
  // opened first — at most half the client's open bound, so one wide
  // answer cannot evict everything else the server holds. A file past
  // that, or one the server cannot outline, keeps its references with no
  // container rather than losing them. Only admitted files are opened: a
  // file the gate withheld is never read, so never sent into the jail.
  let referencing =
    list.filter_map(named, fn(entry) { admitted(entry.1) })
    |> list.unique
    |> list.take(lsp.max_open_documents / 2)
  use Nil <- result.try(resync(session, referencing))
  let files =
    outlines(session, list.unique(list.map(named, fn(entry) { entry.1 })))
  let found =
    list.map(named, fn(entry) {
      let #(location, named) = entry
      let #(content, symbols) =
        dict.get(files, named.path) |> result.unwrap(#("", None))
      query.Reference(
        site: resolve.site(
          content,
          shown(manager, named.path),
          location.range.start,
        ),
        container: option.then(symbols, resolve.container(
          _,
          location.range.start,
        )),
      )
    })
  Ok(Served(value: found, warmth: session.warmth))
}

// Whether a failed request leaves the server worth asking the next one of
// a batch. A deadline that lapsed, or a server that went away, will lapse
// again for every request after it: a batch that went on asking would
// hold its caller for the batch's length times the deadline.
type Onward {
  KeepAsking
  StopAsking
}

fn onward(error: lsp.RequestError) -> Onward {
  case error {
    lsp.TimedOut(..) | lsp.Unavailable(..) | lsp.Unsupported(..) -> StopAsking
    lsp.ServerError(..)
    | lsp.Malformed(..)
    | lsp.InvalidPath(..)
    | lsp.EditRefused(..) -> KeepAsking
  }
}

// Each referenced file read and outlined once, however many references it
// holds, keyed by its gated path. A withheld file has no text and is not
// outlined. The first request that times out stops the outlining, and
// every file after it keeps its references with no container: references
// are worth answering without containers, and a slow server must not cost
// the caller one deadline per file.
fn outlines(
  session: Session,
  files: List(Named),
) -> Dict(String, #(String, Option(protocol.DocumentSymbols))) {
  let #(outlined, _onward) =
    list.fold(files, #(dict.new(), KeepAsking), fn(acc, named) {
      let #(outlined, onward) = acc
      let #(symbols, onward) = case named, onward {
        Admitted(path:), KeepAsking -> outline_of(session, path)
        Admitted(_), StopAsking | Withheld(_), _ -> #(None, onward)
      }
      #(
        dict.insert(outlined, named.path, #(named_text(named), symbols)),
        onward,
      )
    })
  outlined
}

fn outline_of(
  session: Session,
  path: String,
) -> #(Option(protocol.DocumentSymbols), Onward) {
  case lsp.document_symbol(session.client, path, request_ms(session)) {
    Ok(symbols) -> #(Some(symbols), KeepAsking)
    Error(error) -> #(None, onward(error))
  }
}

fn hover(
  manager: Manager,
  asked: SymbolQuery,
) -> Result(Served(query.Hover), QueryError) {
  use target <- result.try(target(manager, asked))
  let session = target.session
  use answer <- result.try(
    lsp.hover(session.client, target.path, target.at, request_ms(session))
    |> result.map_error(request_error(session, _)),
  )
  case answer {
    None -> Error(query.NotFound(query: asked))
    Some(found) -> {
      let at = case found.range {
        Some(span) -> span.start
        None -> target.at
      }

      // A bare name may have resolved to a definition the gate withholds,
      // so the target's text is read through it like any server answer.
      let named = named_path(session, target.path)
      let site = resolve.site(named_text(named), shown(manager, named.path), at)
      Ok(Served(
        value: query.Hover(site:, contents: found.contents),
        warmth: session.warmth,
      ))
    }
  }
}

fn outline(
  manager: Manager,
  path: String,
) -> Result(Served(List(query.SymbolEntry)), QueryError) {
  use #(session, owned) <- result.try(session_for(manager, path))
  use symbols <- result.try(
    lsp.document_symbol(session.client, owned.path, request_ms(session))
    |> result.map_error(request_error(session, _)),
  )
  let content = result.unwrap(resolve.read_text(owned.path), "")
  Ok(Served(
    value: resolve.outline(symbols, content, shown(manager, owned.path)),
    warmth: session.warmth,
  ))
}

fn calls(
  manager: Manager,
  asked: SymbolQuery,
  direction: query.CallDirection,
) -> Result(Served(List(query.Call)), QueryError) {
  use target <- result.try(target(manager, asked))
  let session = target.session
  let deadline = request_ms(session)
  use items <- result.try(
    lsp.prepare_call_hierarchy(session.client, target.path, target.at, deadline)
    |> result.map_error(request_error(session, _)),
  )
  use item <- result.try(
    list.first(items) |> result.replace_error(query.NotFound(query: asked)),
  )

  // Each edge is the other end and the file its call sites lie in, which
  // for an outgoing call is the asked symbol's own.
  let asked_edges = case direction {
    query.Incoming ->
      lsp.incoming_calls(session.client, item, deadline)
      |> result.map(
        list.map(_, fn(edge) {
          Edge(
            other: edge.from,
            other_file: named_uri(session, edge.from.uri),
            calls_in: named_uri(session, edge.from.uri),
            ranges: edge.from_ranges,
          )
        }),
      )
    query.Outgoing ->
      lsp.outgoing_calls(session.client, item, deadline)
      |> result.map(
        list.map(_, fn(edge) {
          Edge(
            other: edge.to,
            other_file: named_uri(session, edge.to.uri),
            calls_in: named_uri(session, item.uri),
            ranges: edge.from_ranges,
          )
        }),
      )
  }
  use edges <- result.try(
    asked_edges |> result.map_error(request_error(session, _)),
  )
  let texts =
    texts_for(
      list.flat_map(edges, fn(edge) { [edge.other_file, edge.calls_in] }),
    )
  Ok(Served(
    value: list.map(edges, call_edge(manager, texts, _)),
    warmth: session.warmth,
  ))
}

// One call-hierarchy edge with both of its files through the gate.
type Edge {
  Edge(
    other: protocol.CallHierarchyItem,
    other_file: Named,
    calls_in: Named,
    ranges: List(range.Range),
  )
}

// One edge in the door's form: the other end's name and definition, and
// the call sites, each against the text `texts` holds for its file.
fn call_edge(
  manager: Manager,
  texts: Dict(String, String),
  edge: Edge,
) -> query.Call {
  let text_of = fn(named: Named) {
    dict.get(texts, named.path) |> result.unwrap("")
  }
  query.Call(
    name: edge.other.name,
    site: resolve.site(
      text_of(edge.other_file),
      shown(manager, edge.other_file.path),
      edge.other.selection_range.start,
    ),
    at: list.map(edge.ranges, fn(span) {
      resolve.site(
        text_of(edge.calls_in),
        shown(manager, edge.calls_in.path),
        span.start,
      )
    }),
  )
}

fn diagnostics(
  manager: Manager,
  path: Option(String),
) -> Result(Served(Diagnostics), QueryError) {
  case path {
    Some(path) -> {
      use #(session, owned) <- result.try(synced_for(manager, path))
      settled(manager, session, [owned.path])
    }

    // Every open document is what "all of them" can mean: the server was
    // told about exactly those, and publishes about what they break.
    None -> {
      use identity <- result.try(option.to_result(
        peek(manager).identity,
        query.NoServer(
          reason: "no language server has been started in this session; "
          <> "name a file to choose one",
        ),
      ))
      use session <- result.try(acquire(manager, identity))
      use Nil <- result.try(resync(session, []))
      use open <- result.try(
        lsp.open_paths(session.client)
        |> result.map_error(request_error(session, _)),
      )
      settled(manager, session, open)
    }
  }
}

// Settles `paths` and converts what was published. With nothing to
// settle, the stored publications are reported, but never as settled:
// nothing was changed, so nothing proves they are current.
fn settled(
  manager: Manager,
  session: Session,
  paths: List(String),
) -> Result(Served(Diagnostics), QueryError) {
  case paths {
    [] -> {
      use stored <- result.try(
        lsp.diagnostics(session.client, None)
        |> result.map_error(request_error(session, _)),
      )
      Ok(Served(
        value: query.Unsettled(seen: converted(
          manager,
          session.identity,
          stored,
        )),
        warmth: session.warmth,
      ))
    }
    _ -> {
      use settlement <- result.try(
        lsp.settle(session.client, paths, settle_ms(session))
        |> result.map_error(request_error(session, _)),
      )
      Ok(Served(
        value: from_settlement(manager, session.identity, settlement),
        warmth: session.warmth,
      ))
    }
  }
}

fn from_settlement(
  manager: Manager,
  identity: Identity,
  settlement: lsp.Settlement,
) -> Diagnostics {
  let found = converted(manager, identity, settlement.published)
  case settlement.outcome {
    lsp.Settled -> query.Settled(diagnostics: found)
    lsp.DeadlineExpired -> query.Unsettled(seen: found)
  }
}

// A server publishes about whatever paths it likes, so each goes through
// the gate: a withheld file's diagnostics keep their coordinates and the
// server's message, and lose only the line text the harness would have
// read for them.
fn converted(
  manager: Manager,
  identity: Identity,
  published: List(#(String, List(protocol.ServerDiagnostic))),
) -> List(query.Diagnostic) {
  list.flat_map(published, fn(entry) {
    let #(path, found) = entry
    let named = gate(manager, identity, path)
    let content = named_text(named)
    let path_shown = shown(manager, named.path)
    list.map(found, fn(diagnostic) {
      query.Diagnostic(
        site: resolve.site(content, path_shown, diagnostic.range.start),
        severity: diagnostic.severity,
        message: diagnostic.message,
      )
    })
  })
}

fn prepare_rename(
  manager: Manager,
  asked: SymbolQuery,
  new_name: String,
) -> Result(Served(List(query.FileEdit)), QueryError) {
  use target <- result.try(target(manager, asked))
  let session = target.session
  let identifier = symbol_for(session.identity.server, asked.symbol).identifier
  use old <- result.try(renamed_identifier(target, identifier))
  use edit <- result.try(
    lsp.rename(
      session.client,
      target.path,
      target.at,
      new_name,
      request_ms(session),
    )
    |> result.map_error(request_error(session, _)),
  )

  // A URI may appear in more than one entry of the answer; each file is
  // applied once, with every edit that falls in it, against the exact text
  // the server computed them on.
  let grouped =
    list.fold(edit.documents, #([], dict.new()), fn(acc, document) {
      let #(order, edits) = acc
      let order = case dict.has_key(edits, document.uri) {
        True -> order
        False -> [document.uri, ..order]
      }
      let held = result.unwrap(dict.get(edits, document.uri), [])
      #(
        order,
        dict.insert(edits, document.uri, list.append(held, document.edits)),
      )
    })
  let #(order, edits) = grouped
  use files <- result.try(
    list.reverse(order)
    |> list.try_map(fn(uri) {
      file_edit(
        manager,
        session,
        uri,
        result.unwrap(dict.get(edits, uri), []),
        old,
      )
    }),
  )
  Ok(Served(value: files, warmth: session.warmth))
}

// The identifier every edit must select. `prepareRename` is asked when
// the server offers it: its refusal is the server's own words, and its
// placeholder, when it gives one, is the name as the server sees it.
fn renamed_identifier(
  target: Target,
  identifier: String,
) -> Result(String, QueryError) {
  let session = target.session
  use capabilities <- result.try(
    lsp.capabilities(session.client)
    |> result.map_error(request_error(session, _)),
  )
  case protocol.supports(capabilities, protocol.PrepareRenameFeature) {
    protocol.NotProvided -> Ok(identifier)
    protocol.Provided -> {
      use prepared <- result.try(
        lsp.prepare_rename(
          session.client,
          target.path,
          target.at,
          request_ms(session),
        )
        |> result.map_error(request_error(session, _)),
      )
      case prepared {
        protocol.CanRename(range: _, placeholder: Some(placeholder)) ->
          Ok(placeholder)
        protocol.CanRename(range: _, placeholder: None)
        | protocol.CanRenameDefault -> Ok(identifier)
        protocol.CannotRename ->
          Error(query.ServerRefused(
            message: identifier <> " cannot be renamed here",
          ))
      }
    }
  }
}

// One file's share of a rename. The base is the text the server holds for
// an open document — which the pull just made the disk's — and the disk
// otherwise. Every edit must select exactly the old identifier in it, or
// the answer was computed against some other text and is refused whole.
// A file the gate withholds refuses the whole rename before anything is
// read: a rename the model cannot see all of is not one it can land.
fn file_edit(
  manager: Manager,
  session: Session,
  uri: String,
  edits: List(TextEdit),
  old: String,
) -> Result(query.FileEdit, QueryError) {
  use path <- result.try(case named_uri(session, uri) {
    Admitted(path:) -> Ok(path)
    Withheld(path:) ->
      Error(query.ServerRefused(
        message: "the rename would edit "
        <> shown(manager, path)
        <> ", which is outside lsp."
        <> session.identity.server.name
        <> "'s project root "
        <> shown(manager, session.identity.root)
        <> " or protected; nothing was read or changed",
      ))
  })
  let held = case lsp.synced_text(session.client, path) {
    Ok(Some(held)) -> Ok(held)
    Ok(None) | Error(_) -> resolve.read_text(path)
  }
  use base <- result.try(
    held |> result.map_error(fn(reason) { query.Unavailable(reason:) }),
  )
  let refused = fn(fault) {
    query.ServerRefused(
      message: "the rename's edits for "
      <> shown(manager, path)
      <> " do not apply: "
      <> text.describe(fault),
    )
  }
  use Nil <- result.try(
    text.check_selects(base, edits, old) |> result.map_error(refused),
  )
  use edited <- result.try(text.apply(base, edits) |> result.map_error(refused))
  Ok(query.FileEdit(
    path: shown(manager, path),
    base:,
    edited:,
    edits: list.length(edits),
  ))
}

fn after_write(manager: Manager, path: String) -> Option(Diagnostics) {
  case resolve.owner(manager.config.servers, manager.config.workspace, path) {
    Error(_unowned) -> None
    Ok(owned) -> {
      let peeked = peek(manager)
      case peeked.identity, peeked.client {
        Some(identity), Some(client) ->
          case resolve.same(identity, owned.identity) {
            True -> Some(pushed(manager, identity, client, owned.path))
            False -> None
          }
        Some(_), None | None, Some(_) | None, None -> None
      }
    }
  }
}

// ADR-013 §3's push: the new text, then a bounded wait for settlement. A
// failure is an unsettled block, never a clean one.
fn pushed(
  manager: Manager,
  identity: Identity,
  client: lsp.Client,
  path: String,
) -> Diagnostics {
  let settlement = {
    use content <- result.try(
      resolve.read_text(path) |> result.replace_error(Nil),
    )
    use Nil <- result.try(
      lsp.sync(client, [lsp.Change(path:, text: content)])
      |> result.replace_error(Nil),
    )
    tell(manager, Opened(identity:, paths: [path]))
    lsp.settle(client, [path], manager.config.timing.settle_ms)
    |> result.replace_error(Nil)
  }
  case settlement {
    Ok(settlement) -> from_settlement(manager, identity, settlement)
    Error(Nil) -> query.Unsettled(seen: [])
  }
}

// --- resolving the question ----------------------------------------------------

// The server and the file a path-scoped question is about, with the
// server's view of every open document brought up to the disk and the
// file itself opened.
fn session_for(
  manager: Manager,
  path: String,
) -> Result(#(Session, Owned), QueryError) {
  use #(session, owned) <- result.try(synced_for(manager, path))
  use Nil <- result.try(readied(session))
  Ok(#(session, owned))
}

// `session_for` without the readiness wait, for diagnostics: settlement
// is bounded by its own rules and deadline, and an unsettled block is an
// honest answer where an empty query result is not.
fn synced_for(
  manager: Manager,
  path: String,
) -> Result(#(Session, Owned), QueryError) {
  use owned <- result.try(owned(manager, path))
  use session <- result.try(acquire(manager, owned.identity))
  use Nil <- result.try(resync(session, [owned.path]))
  Ok(#(session, owned))
}

// The query that paid for a start waits for the load it started: a quiet
// window, since the server may begin reporting only after `initialized`,
// then the end of every token it reported. It follows the pull, so the
// documents the query opened are part of that load. A warm query passes
// at once without asking, so a token a server never ends costs one
// "still loading" answer at start rather than a deadline on every query.
fn readied(session: Session) -> Result(Nil, QueryError) {
  case session.warmth {
    query.Warm -> Ok(Nil)
    query.Started(..) -> {
      let timing = session.manager.config.timing
      let readiness =
        lsp.ready(
          session.client,
          quiet_ms: timing.quiet_ms,
          deadline_ms: timing.ready_ms,
        )
      case readiness {
        Ok(lsp.Quiet) -> Ok(Nil)
        Ok(lsp.StillBusy(titles:)) ->
          Error(query.Unavailable(reason: still_loading(titles)))
        Error(error) -> Error(request_error(session, error))
      }
    }
  }
}

// A server still loading at the deadline, worded for the model: what it
// is doing, when there is a title to say, and that asking again is the
// remedy.
fn still_loading(titles: List(String)) -> String {
  let doing = case titles {
    [] -> ""
    _ -> " (" <> string.join(titles, ", ") <> ")"
  }
  "the language server is still loading" <> doing <> "; ask again in a moment"
}

fn owned(manager: Manager, path: String) -> Result(Owned, QueryError) {
  resolve.owner(manager.config.servers, manager.config.workspace, path)
  |> result.map_error(fn(unowned) {
    case unowned {
      resolve.NoOwner(reason:) | resolve.Refused(reason:) ->
        query.NoServer(reason:)
    }
  })
}

// Turns a question into a position, by the three rules ADR-013 §5 names:
// a line narrows to the first boundary occurrence on it, a path alone to
// the file's outline, and a bare name to a search of the server's root.
//
// How the symbol splits is the owning server's to say (its
// `qualifier_separators`), so it is split only once a server is known:
// after the path's owner is found, or, for a bare name, per server as
// the search visits each one.
fn target(manager: Manager, asked: SymbolQuery) -> Result(Target, QueryError) {
  case asked.path, asked.line {
    Some(path), Some(line) -> on_line(manager, asked, path, line)
    Some(path), None -> in_outline(manager, asked, path)
    None, Some(_) | None, None -> anywhere(manager, asked)
  }
}

// The model's symbol as `server` spells a qualified name.
fn symbol_for(server: LspServer, written: String) -> Symbol {
  resolve.split_symbol(written, server.qualifier_separators)
}

fn on_line(
  manager: Manager,
  asked: SymbolQuery,
  path: String,
  line: Int,
) -> Result(Target, QueryError) {
  use #(session, owned) <- result.try(session_for(manager, path))
  let symbol = symbol_for(session.identity.server, asked.symbol)
  use at <- result.try(
    resolve.read_text(owned.path)
    |> result.replace_error(Nil)
    |> result.try(fn(content) {
      text.symbol_position(content, line, symbol.identifier)
      |> result.replace_error(Nil)
    })
    |> result.replace_error(query.NotFound(query: asked)),
  )
  Ok(Target(session:, path: owned.path, at:))
}

fn in_outline(
  manager: Manager,
  asked: SymbolQuery,
  path: String,
) -> Result(Target, QueryError) {
  use #(session, owned) <- result.try(session_for(manager, path))
  let server = session.identity.server
  let symbol = symbol_for(server, asked.symbol)
  use symbols <- result.try(
    lsp.document_symbol(session.client, owned.path, request_ms(session))
    |> result.map_error(request_error(session, _)),
  )
  let content = result.unwrap(resolve.read_text(owned.path), "")
  let found =
    resolve.named(
      symbols,
      symbol.identifier,
      symbol.qualifier,
      server.module_case,
      root: session.identity.root,
      path: owned.path,
    )
    |> list.map(fn(entry) { refine(content, entry.1, symbol.identifier) })
    |> list.unique
  case found {
    [] -> Error(query.NotFound(query: asked))
    [at] -> Ok(Target(session:, path: owned.path, at:))
    many ->
      Error(
        query.Ambiguous(
          candidates: list.map(many, resolve.site(
            content,
            shown(manager, owned.path),
            _,
          )),
        ),
      )
  }
}

// One definition a bare name resolved to, at its identifier.
type Definition {
  Definition(path: String, at: Position)
}

fn anywhere(
  manager: Manager,
  asked: SymbolQuery,
) -> Result(Target, QueryError) {
  use #(identity, hits) <- result.try(searched(manager, asked))
  use session <- result.try(acquire(manager, identity))
  let symbol = symbol_for(identity.server, asked.symbol)

  // The hit files are opened with the pull. `gleam lsp` answers nothing
  // about a document it does not hold open (measured: an empty
  // `definition` for every hit), and the search already bounded them to
  // fewer files than the client keeps open.
  use Nil <- result.try(resync(
    session,
    list.unique(list.map(hits, fn(hit) { hit.path })),
  ))
  use Nil <- result.try(readied(session))
  use found <- result.try(definitions(session, hits, symbol.identifier))

  // The qualifier narrows definitions, never hits: `probe.greet` is
  // written at call sites in files that are not `probe`, and each of them
  // leads to the one definition that is.
  let found = case symbol.qualifier {
    None -> found
    Some(qualifier) ->
      list.filter(found, fn(definition) {
        resolve.satisfies(
          identity.root,
          definition.path,
          qualifier,
          identity.server.module_case,
        )
      })
  }
  case found {
    [] -> Error(query.NotFound(query: asked))
    [one] -> Ok(Target(session:, path: one.path, at: one.at))
    many ->
      Error(
        query.Ambiguous(
          candidates: list.map(many, fn(definition) {
            let named = named_path(session, definition.path)
            resolve.site(
              named_text(named),
              shown(manager, named.path),
              definition.at,
            )
          }),
        ),
      )
  }
}

// Where to search, and what was found. With a server already chosen, its
// root; with none yet, the whole workspace for each configured server,
// and the hits then say which project the name lives in. Hits in two
// projects are two answers, and the model narrows with a path. Each
// server searches for the identifier its own separators leave, since
// `util::greet` is `greet` to a `::` server and the unsplit
// `util::greet` to a `.` one.
fn searched(
  manager: Manager,
  asked: SymbolQuery,
) -> Result(#(Identity, List(Hit)), QueryError) {
  let search = manager.config.backend.search
  case peek(manager).identity {
    Some(identity) -> {
      use hits <- result.try(
        search(Search(
          server: identity.server,
          root: identity.root,
          identifier: symbol_for(identity.server, asked.symbol).identifier,
        ))
        |> result.map_error(fn(reason) { query.Unavailable(reason:) }),
      )
      Ok(#(identity, hits))
    }
    None -> {
      use hits <- result.try(
        list.try_map(manager.config.servers, fn(server) {
          search(Search(
            server:,
            root: manager.config.workspace,
            identifier: symbol_for(server, asked.symbol).identifier,
          ))
        })
        |> result.map(list.flatten)
        |> result.map_error(fn(reason) { query.Unavailable(reason:) }),
      )
      by_project(manager, asked, hits)
    }
  }
}

// Groups workspace-wide hits by the project that owns them.
fn by_project(
  manager: Manager,
  asked: SymbolQuery,
  hits: List(Hit),
) -> Result(#(Identity, List(Hit)), QueryError) {
  let owned =
    list.filter_map(hits, fn(hit) {
      owned(manager, hit.path)
      |> result.map(fn(owned) {
        #(owned.identity, Hit(path: owned.path, line: hit.line))
      })
      |> result.replace_error(Nil)
    })
  let projects =
    list.fold(owned, [], fn(projects, entry) {
      case
        list.any(projects, fn(known: #(Identity, Hit)) {
          resolve.same(known.0, entry.0)
        })
      {
        True -> projects
        False -> [entry, ..projects]
      }
    })
  case list.reverse(projects) {
    [] -> Error(query.NotFound(query: asked))
    [#(identity, _first)] ->
      Ok(#(
        identity,
        list.filter_map(owned, fn(entry) {
          case resolve.same(entry.0, identity) {
            True -> Ok(entry.1)
            False -> Error(Nil)
          }
        }),
      ))
    several ->
      Error(
        query.Ambiguous(
          candidates: list.map(several, fn(entry) {
            let hit = entry.1
            let content = result.unwrap(resolve.read_text(hit.path), "")
            let at =
              text.symbol_position(
                content,
                hit.line,
                symbol_for(entry.0.server, asked.symbol).identifier,
              )
              |> result.unwrap(range.Position(line: hit.line - 1, character: 0))
            resolve.site(content, shown(manager, hit.path), at)
          }),
        ),
      )
  }
}

// Asks the server where each hit's occurrence is defined, and keeps the
// distinct definitions. A hit inside a string or a comment resolves to
// nothing and falls out, as does one the server refuses; a server that
// does not offer `definition` at all is answered as such rather than as
// "not found".
//
// A server that stops answering stops the search, and the question is
// answered `Unavailable` rather than with the definitions found so far:
// up to `max_search_hits` requests each waiting out its own deadline
// would hold the caller for many minutes, and a partial answer to a bare
// name would read as the whole of it — a `NotFound`, or a single
// definition taken for the only one.
fn definitions(
  session: Session,
  hits: List(Hit),
  identifier: String,
) -> Result(List(Definition), QueryError) {
  let hits =
    list.map(hits, fn(hit) { #(named_path(session, hit.path), hit.line) })
  let texts = texts_for(list.map(hits, fn(hit) { hit.0 }))
  use found <- result.try(
    list.try_fold(hits, [], fn(found, hit) {
      let #(named, line) = hit
      let content = dict.get(texts, named.path) |> result.unwrap("")

      // A withheld hit has no text, so no position, and is never asked
      // about: the fold passes it by here.
      case text.symbol_position(content, line, identifier) {
        Error(_absent) -> Ok(found)
        Ok(at) -> defined_at(session, named.path, at, found)
      }
    }),
  )
  let found = list.reverse(found)
  let files = list.map(found, fn(location) { named_uri(session, location.uri) })
  let texts = texts_for(files)
  list.zip(found, files)
  |> list.map(fn(entry) {
    let #(location, named) = entry
    let content = dict.get(texts, named.path) |> result.unwrap("")
    Definition(
      path: named.path,
      at: refine(content, location.range.start, identifier),
    )
  })
  |> list.unique
  |> Ok
}

// One hit's `definition` request, its locations joining `found`.
fn defined_at(
  session: Session,
  path: String,
  at: Position,
  found: List(Location),
) -> Result(List(Location), QueryError) {
  case lsp.definition(session.client, path, at, request_ms(session)) {
    Ok(locations) -> Ok(list.append(locations, found))
    Error(error) ->
      case onward(error) {
        KeepAsking -> Ok(found)
        StopAsking -> Error(search_cut(session, error))
      }
  }
}

// A bare-name search the server stopped answering, in the door's words.
// An unsupported request keeps its own answer; anything else says the
// search was cut, so the model knows a path-scoped question may still
// get through.
fn search_cut(session: Session, error: lsp.RequestError) -> QueryError {
  case request_error(session, error) {
    query.Unavailable(reason:) ->
      query.Unavailable(
        reason: reason
        <> "; resolving the bare name stopped there, and a question "
        <> "naming the file and line asks the server once",
      )
    other -> other
  }
}

// A server may report a definition at the start of its declaration
// (`pub fn …`) rather than at its name. Asked at that position, the next
// request would be about the keyword; so a position that is not already
// on an occurrence of the identifier moves to the first occurrence on its
// line, when there is one.
fn refine(content: String, at: Position, identifier: String) -> Position {
  case text.to_site(content, "", at) {
    Error(_fault) -> at
    Ok(site) ->
      case list.contains(text.occurrences(site.text, identifier), site.column) {
        True -> at
        False ->
          text.symbol_position(content, site.line, identifier)
          |> result.unwrap(at)
      }
  }
}

// --- the caller's side of the manager -------------------------------------------

// The live client for `identity`, starting it if need be. The wait covers
// the previous server's stop, the probe and the handshake; a start that
// overruns it is still in progress, and the next query may find it done.
fn acquire(
  manager: Manager,
  identity: Identity,
) -> Result(Session, QueryError) {
  let timing = manager.config.timing
  let waiting = timing.previous_ms + timing.exec_ms * 2 + timing.start_ms + 1000
  case ask(manager, waiting:, sending: Acquire(identity, _)) {
    Ok(Ok(granted)) ->
      Ok(Session(
        manager:,
        client: granted.client,
        identity:,
        warmth: granted.warmth,
      ))
    Ok(Error(error)) -> Error(error)
    Error(call.NoReply) ->
      Error(query.Unavailable(
        reason: "lsp."
        <> identity.server.name
        <> " did not start within "
        <> int.to_string(waiting / 1000)
        <> " s",
      ))
    Error(call.CalleeGone) ->
      Error(query.Unavailable(
        reason: "the session's language-server manager is not running",
      ))
  }
}

fn peek(manager: Manager) -> Peeked {
  ask(manager, waiting: 5000, sending: Peek)
  |> result.unwrap(Peeked(identity: None, client: None))
}

// ADR-013 §3's pull: every document the server holds open is re-read, and
// changed or closed to match the disk, before the question is asked; the
// files in `also` are opened with it. One `sync`, so the server sees the
// whole correction before the request that follows it.
fn resync(session: Session, also: List(String)) -> Result(Nil, QueryError) {
  use open <- result.try(
    lsp.open_paths(session.client)
    |> result.map_error(request_error(session, _)),
  )
  let pulled = list.filter_map(open, pulled(session.client, _))

  // The one place a document is opened on the server, so the gate stands
  // here too: whatever a caller passes, a file the gate withholds is
  // never read, never sent into the jail, and never recorded for a
  // restart to re-open.
  let also =
    list.filter_map(also, fn(path) { admitted(named_path(session, path)) })
  let opening =
    list.filter_map(also, fn(path) {
      case list.contains(open, path) {
        True -> Error(Nil)
        False ->
          resolve.read_text(path)
          |> result.map(lsp.Change(path:, text: _))
          |> result.replace_error(Nil)
      }
    })
  let ops = list.append(pulled, opening)
  use Nil <- result.try(case ops {
    [] -> Ok(Nil)
    _ ->
      lsp.sync(session.client, ops)
      |> result.map_error(request_error(session, _))
  })
  case also {
    [] -> Nil
    _ -> tell(session.manager, Opened(identity: session.identity, paths: also))
  }
  Ok(Nil)
}

// One open document against the disk: unchanged is nothing to send, moved
// is a full-text change, and unreadable — deleted, grown past the guard,
// no longer text — is a close, after which the server reads it itself.
fn pulled(client: lsp.Client, path: String) -> Result(lsp.DocOp, Nil) {
  case resolve.read_text(path) {
    Error(_gone) -> Ok(lsp.Close(path:))
    Ok(content) ->
      case lsp.synced_text(client, path) {
        Ok(Some(held)) if held == content -> Error(Nil)
        Ok(Some(_moved)) | Ok(None) | Error(_) ->
          Ok(lsp.Change(path:, text: content))
      }
  }
}

// --- conversions -----------------------------------------------------------------

fn sites(session: Session, locations: List(Location)) -> List(Site) {
  let files =
    list.map(locations, fn(location) { named_uri(session, location.uri) })
  let texts = texts_for(files)
  list.zip(locations, files)
  |> list.map(fn(entry) {
    let #(location, named) = entry
    resolve.site(
      dict.get(texts, named.path) |> result.unwrap(""),
      shown(session.manager, named.path),
      location.range.start,
    )
  })
}

// --- the gate on what a server names ------------------------------------------

// A path a language server named, judged once, before anything reads it.
// The jail bounds what the server can read, never which paths it can
// emit, and every read below runs in the harness, unjailed; so a path
// out of a server's answer reaches `resolve.read_text` only as
// `Admitted`.
type Named {
  // Its real location is under the server's root and under no protected
  // path. `path` is that real location: the one to read, open and show.
  Admitted(path: String)

  // Anything else: outside the root, protected, unresolvable, or a URI
  // that does not decode. `path` is as the server named it, which is
  // shown with the answer's raw coordinates and never read.
  Withheld(path: String)
}

fn gate(manager: Manager, identity: Identity, path: String) -> Named {
  case
    resolve.admit(
      root: identity.root,
      protected: manager.config.backend.protected,
      path:,
    )
  {
    Ok(real) -> Admitted(path: real)
    Error(_reason) -> Withheld(path:)
  }
}

fn named_path(session: Session, path: String) -> Named {
  gate(session.manager, session.identity, path)
}

// A server URI through the gate. Decoding is strict
// (`protocol.uri_to_path`); a URI that does not decode names no file the
// harness can place, and is shown as the server wrote it, which names the
// file better than dropping the answer would.
fn named_uri(session: Session, uri: String) -> Named {
  case protocol.uri_to_path(uri) {
    Ok(path) -> named_path(session, path)
    Error(_undecodable) -> Withheld(path: uri)
  }
}

fn admitted(named: Named) -> Result(String, Nil) {
  case named {
    Admitted(path:) -> Ok(path)
    Withheld(path: _) -> Error(Nil)
  }
}

// The text the door may show for a named file: the file's own when it is
// admitted and readable, and none otherwise.
fn named_text(named: Named) -> String {
  case named {
    Admitted(path:) -> resolve.read_text(path) |> result.unwrap("")
    Withheld(path: _) -> ""
  }
}

// Every named file's text, read once however many sites fall in it, keyed
// by the gated path.
fn texts_for(files: List(Named)) -> Dict(String, String) {
  list.unique(files)
  |> list.map(fn(named) { #(named.path, named_text(named)) })
  |> dict.from_list
}

fn shown(manager: Manager, path: String) -> String {
  resolve.display(manager.workspaces, path)
}

fn request_ms(session: Session) -> Int {
  session.manager.config.timing.request_ms
}

fn settle_ms(session: Session) -> Int {
  session.manager.config.timing.settle_ms
}

// The client's refusal in the door's vocabulary.
fn request_error(session: Session, error: lsp.RequestError) -> QueryError {
  case error {
    lsp.Unsupported(feature:) ->
      query.Unsupported(
        server: session.identity.server.name,
        request: lsp.feature_method(feature),
      )
    lsp.ServerError(code: _, message:) -> query.ServerRefused(message:)
    lsp.TimedOut(after_ms:) ->
      query.Unavailable(
        reason: "lsp."
        <> session.identity.server.name
        <> " did not answer within "
        <> int.to_string(after_ms)
        <> " ms",
      )
    lsp.Unavailable(reason:) -> query.Unavailable(reason:)
    lsp.Malformed(reason:) ->
      query.Unavailable(reason: "the server's answer was malformed: " <> reason)
    lsp.InvalidPath(path:) -> query.NoServer(reason: path <> " has no file URI")
    lsp.EditRefused(kind:, uri:) ->
      query.ServerRefused(
        message: "the rename would "
        <> kind
        <> " "
        <> uri
        <> ", and only text edits can be landed",
      )
  }
}
