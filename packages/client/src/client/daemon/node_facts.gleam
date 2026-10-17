//// How a daemon assembles the report it gives of itself (protocol-change/085).
////
//// `client/node_report` is the vocabulary and `orchestrator_port` is the
//// question; this module is the answer's assembly. The daemon knows where each
//// fact lives: the executor host owns the ledger, the movers own the moves in
//// flight, the registry owns the catalogue, and the directory member owns its
//// cluster view. It hands this module one function for each and the identity
//// of the build, and `report` calls them.
////
//// ## The three kinds of fact are read at once
////
//// A peer asks within a deadline of its own. The executor's ledger read waits
//// on the host's turn, the orchestrator's walks a catalogue a page at a time,
//// and the directory's fences against its cluster, which can take seconds
//// without a quorum. Read one after another, a slow directory would cost the
//// asker the executor facts it could have had at once. `report` runs the three
//// in one weft run under a single deadline, and a read that crashed or did not
//// finish leaves its facts out and the others in. The asker then sees a node
//// that answered without them, which it can name, rather than silence about a
//// node that is up.
////
//// ## What "left out" means
////
//// A fact is `None` when the node has none of that kind, and also when its
//// source did not answer in time. A report does not say which. The asker
//// compares what it expected of the node (an executor it configured, a
//// directory it lists) with what the report holds, and an expected fact that
//// is missing is the finding.

import client/directory/member
import client/directory/store
import client/node_report.{
  type DirectoryFacts, type ExecutorFacts, type NodeReport,
  type OrchestratorFacts,
}
import client/remote/host.{type Snapshot}
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import gleam/list
import gleam/option.{type Option}
import storage/exec_ledger
import weft

// The deadline below is the real bound on a report. The waits inside each
// source (the executor's two seconds, the directory's budgets) are secondary:
// they let a source answer "I could not" in its own words before the deadline
// would kill it and leave its facts out altogether.

/// How long `report` waits for the three sources together. It is under the
/// time a peer waits for a report (`deployment.report_ms`, 2600), so the answer
/// reaches the peer with whatever was read, and not after the peer has stopped
/// listening. The margin is the transit and the assembly of the answer.
pub const read_ms = 2500

/// Where each fact comes from, supplied by the daemon.
pub type Sources {
  Sources(
    /// This node's full Erlang name.
    node: String,
    /// The build's version.
    build_version: String,
    /// The build's commit.
    build_commit: String,
    /// The daemon's epoch.
    epoch: String,
    /// The node's clock when the daemon's services started, in Unix
    /// milliseconds.
    started_ms: Int,
    /// The node's clock now.
    now_ms: fn() -> Int,
    /// The nodes this daemon lists as peers. Called once, not under the
    /// deadline: it reads configuration.
    peers: fn() -> List(String),
    /// The orchestrator facts, or `None` when this daemon is not an
    /// orchestrator or its catalogue could not be read.
    orchestrator: fn() -> Option(OrchestratorFacts),
    /// The executor facts, or `None` when this daemon serves no workspace or
    /// its host did not answer.
    executor: fn() -> Option(ExecutorFacts),
    /// The directory facts, or `None` when this daemon is not a member.
    directory: fn() -> Option(DirectoryFacts),
  )
}

// What one of the three reads came back with. The reads return different types
// and one weft run holds tasks of one type, so each result names its kind.
type Fact {
  Orchestrating(Option(OrchestratorFacts))
  Executing(Option(ExecutorFacts))
  Directing(Option(DirectoryFacts))
}

/// Builds the report: the node's identity and clock, its peers cut to
/// `node_report.max_peers`, and the facts the three sources return within
/// `read_ms`.
///
/// ## Examples
///
/// ```gleam
/// // node_facts.report(Sources(node: "loom@hub", ..))
/// // -> NodeReport(node: "loom@hub", orchestrator: Some(..), executor: None, ..)
/// ```
pub fn report(sources: Sources) -> NodeReport {
  let outcomes =
    [
      fn() { Ok(Orchestrating(sources.orchestrator())) },
      fn() { Ok(Executing(sources.executor())) },
      fn() { Ok(Directing(sources.directory())) },
    ]
    |> weft.new
    |> weft.deadline(read_ms)
    |> weft.start

  let base =
    node_report.NodeReport(
      ..node_report.bare(
        node: sources.node,
        build_version: sources.build_version,
        build_commit: sources.build_commit,
        epoch: sources.epoch,
        started_ms: sources.started_ms,
        now_ms: sources.now_ms(),
      ),
      peers: sources.peers(),
    )
  list.fold(outcomes, base, fn(report, outcome) {
    case outcome {
      weft.Completed(value: Orchestrating(facts), ..) ->
        node_report.NodeReport(..report, orchestrator: facts)
      weft.Completed(value: Executing(facts), ..) ->
        node_report.NodeReport(..report, executor: facts)
      weft.Completed(value: Directing(facts), ..) ->
        node_report.NodeReport(..report, directory: facts)

      // A read that failed, crashed or ran past the deadline says nothing, and
      // its facts stay out of the report.
      weft.Failed(..)
      | weft.Crashed(..)
      | weft.Abandoned(..)
      | weft.NeverStarted(..)
      | weft.DrainProofLost(..)
      | weft.CancellationUnconfirmed(..) -> report
    }
  })
}

/// How long the directory's cluster view may wait for Ra.
pub const status_ms = 500

/// How long the fence of the directory's copy check may wait. With the cluster
/// view above, a member with no leader answers in under two seconds, inside
/// `read_ms`.
pub const confirm_ms = 800

/// The directory facts, from the two reads a member makes: the cluster as it
/// sees it and a check that its own copy is current. The check failing is
/// `Unconfirmed` and not an absent fact, since a member that cannot reach a
/// leader is exactly the one whose report must say so. Each read carries its own
/// budget (`status_ms`, `confirm_ms`) so that both finish inside `read_ms`.
///
/// ## Examples
///
/// ```gleam
/// // node_facts.directory_facts(fn() { member.status_within(handle, status_ms) }, fn() { store.confirm_current(local, confirm_ms) })
/// ```
pub fn directory_facts(
  status: fn() -> member.Status,
  confirm: fn() -> Result(Nil, store.Unavailable),
) -> DirectoryFacts {
  node_report.DirectoryFacts(status: status(), copy: case confirm() {
    Ok(Nil) -> node_report.Current
    Error(store.Unavailable(..)) -> node_report.Unconfirmed
  })
}

/// The executor facts for a host snapshot: the ledger's counts renamed into the
/// report's vocabulary, the limits the host admits against, the machine's
/// platform and, from the latest attach census, its enforcement and toolchains.
///
/// `limits` is the value the host was configured with, so `scope_limit` and
/// `ledger_limit` are the ones admission is judged against and not a second
/// reading of the environment. `workspaces` are the registered names and never
/// their roots.
///
/// ## Examples
///
/// ```gleam
/// // node_facts.executor_facts(snapshot, exec_ledger.default_limits(), "linux/x86_64", ["proj"])
/// ```
pub fn executor_facts(
  snapshot: Snapshot(RemoteCensus),
  limits: exec_ledger.Limits,
  platform: String,
  workspaces: List(String),
) -> ExecutorFacts {
  let ledger = snapshot.ledger
  node_report.ExecutorFacts(
    protocol: protocol.version,
    scopes: node_report.ScopeCounts(
      open: ledger.scopes.open,
      closing: ledger.scopes.closing,
      closed_clean: ledger.scopes.closed_clean,
      closed_unknown: ledger.scopes.closed_unknown,
    ),
    scope_limit: limits.max_unclean_scopes,
    unclean: list.filter_map(ledger.unclean, unclean_scope),
    ledger_bytes: ledger.bytes,
    ledger_limit: limits.max_ledger_bytes,
    unacknowledged: ledger.unacknowledged,
    platform:,
    observed: option.map(snapshot.census, remote_census.observed),
    workspaces: list.take(workspaces, node_report.max_workspaces),
  )
}

// The ledger lists only scopes that block a reopen, so the two states below
// are the whole of it. An open or cleanly closed scope would be a fault in the
// summary, and a report does not carry a state it has no word for.
fn unclean_scope(
  scope: exec_ledger.UncleanScope,
) -> Result(node_report.UncleanScope, Nil) {
  case scope.state {
    exec_ledger.Closing ->
      Ok(node_report.UncleanScope(
        session: scope.session,
        state: node_report.Closing,
      ))
    exec_ledger.Closed(exec_ledger.UnknownCleanup(count:)) ->
      Ok(node_report.UncleanScope(
        session: scope.session,
        state: node_report.UnknownCleanup(count:),
      ))
    exec_ledger.Open | exec_ledger.Closed(exec_ledger.AllRetired) -> Error(Nil)
  }
}
