//// How a daemon assembles its report (protocol-change/085): the three sources
//// are read at once under one deadline, a source that fails or runs late leaves
//// its facts out and nothing else, and the executor facts are the host's ledger
//// counts in the report's own words.

import client/daemon/node_facts.{Sources}
import client/directory/member
import client/directory/store
import client/node_report
import client/remote/host
import client/remote/protocol
import client/remote/remote_census.{type RemoteCensus}
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import host/bootstrap
import storage/exec_ledger

fn directory() -> node_report.DirectoryFacts {
  node_report.DirectoryFacts(
    status: member.Status(
      members: ["alpha@10.0.0.1"],
      joining: member.Joined,
      ra: Error(store.Unavailable("no quorum in time")),
      applied_index: 7,
    ),
    copy: node_report.Current,
  )
}

fn orchestrator() -> node_report.OrchestratorFacts {
  node_report.OrchestratorFacts(
    capacity: 8,
    occupied: 1,
    resident: 1,
    imports: node_report.Receiving,
    executor_nodes: [],
    placements: [],
    moves: [],
  )
}

fn executor() -> node_report.ExecutorFacts {
  node_facts.executor_facts(
    host.Snapshot(
      ledger: exec_ledger.Summary(
        scopes: exec_ledger.ScopeCounts(
          open: 0,
          closing: 0,
          closed_clean: 0,
          closed_unknown: 0,
        ),
        unclean: [],
        bytes: 0,
        unacknowledged: 0,
      ),
      census: None,
    ),
    exec_ledger.default_limits(),
    "linux/x86_64",
    ["proj"],
  )
}

fn sources() -> node_facts.Sources {
  Sources(
    node: "alpha@10.0.0.1",
    build_version: "0.3.0",
    build_commit: "abc123",
    epoch: "epoch-1",
    started_ms: 1000,
    now_ms: fn() { 9000 },
    peers: fn() { ["bravo@10.0.0.3"] },
    orchestrator: fn() { Some(orchestrator()) },
    executor: fn() { Some(executor()) },
    directory: fn() { Some(directory()) },
  )
}

pub fn every_source_that_answers_lands_in_the_report_test() {
  let report = node_facts.report(sources())
  assert report.node == "alpha@10.0.0.1"
  assert report.build_version == "0.3.0"
  assert report.build_commit == "abc123"
  assert report.epoch == "epoch-1"
  assert report.started_ms == 1000
  assert report.now_ms == 9000
  assert report.peers == ["bravo@10.0.0.3"]
  assert report.orchestrator == Some(orchestrator())
  assert report.executor == Some(executor())
  assert report.directory == Some(directory())
}

pub fn a_node_with_no_executor_or_directory_says_so_by_omission_test() {
  let report =
    node_facts.report(
      Sources(..sources(), executor: fn() { None }, directory: fn() { None }),
    )
  assert report.orchestrator == Some(orchestrator())
  assert report.executor == None
  assert report.directory == None
}

pub fn a_source_that_crashes_leaves_only_its_own_facts_out_test() {
  let report =
    node_facts.report(
      Sources(..sources(), directory: fn() { panic as "the member is gone" }),
    )
  assert report.directory == None
  assert report.orchestrator == Some(orchestrator())
  assert report.executor == Some(executor())
}

pub fn a_source_past_the_deadline_leaves_only_its_own_facts_out_test() {
  let started = bootstrap.monotonic_time_ms()
  let report =
    node_facts.report(
      Sources(..sources(), orchestrator: fn() {
        process.sleep(node_facts.read_ms + 3000)
        Some(orchestrator())
      }),
    )
  let waited = bootstrap.monotonic_time_ms() - started

  // The report is ready at the deadline with the sources that answered.
  assert report.orchestrator == None
  assert report.executor == Some(executor())
  assert waited < node_facts.read_ms + 1500
}

// --- the executor's facts --------------------------------------------------------

fn snapshot(
  unclean: List(exec_ledger.UncleanScope),
) -> host.Snapshot(RemoteCensus) {
  host.Snapshot(
    ledger: exec_ledger.Summary(
      scopes: exec_ledger.ScopeCounts(
        open: 2,
        closing: 1,
        closed_clean: 3,
        closed_unknown: 1,
      ),
      unclean:,
      bytes: 4096,
      unacknowledged: 5,
    ),
    census: None,
  )
}

pub fn the_ledgers_counts_become_the_reports_facts_test() {
  let limits =
    exec_ledger.Limits(max_unclean_scopes: 4, max_ledger_bytes: 1_000_000)
  let facts =
    node_facts.executor_facts(
      snapshot([
        exec_ledger.UncleanScope(session: "closing", state: exec_ledger.Closing),
        exec_ledger.UncleanScope(
          session: "lost",
          state: exec_ledger.Closed(exec_ledger.UnknownCleanup(2)),
        ),
      ]),
      limits,
      "macos/arm64",
      ["proj", "docs"],
    )
  assert facts
    == node_report.ExecutorFacts(
      protocol: protocol.version,
      scopes: node_report.ScopeCounts(
        open: 2,
        closing: 1,
        closed_clean: 3,
        closed_unknown: 1,
      ),
      scope_limit: 4,
      unclean: [
        node_report.UncleanScope(session: "closing", state: node_report.Closing),
        node_report.UncleanScope(
          session: "lost",
          state: node_report.UnknownCleanup(count: 2),
        ),
      ],
      ledger_bytes: 4096,
      ledger_limit: 1_000_000,
      unacknowledged: 5,
      platform: "macos/arm64",
      observed: None,
      workspaces: ["proj", "docs"],
    )
}

pub fn a_state_the_report_has_no_word_for_is_not_listed_test() {
  let facts =
    node_facts.executor_facts(
      snapshot([
        exec_ledger.UncleanScope(session: "open", state: exec_ledger.Open),
        exec_ledger.UncleanScope(
          session: "clean",
          state: exec_ledger.Closed(exec_ledger.AllRetired),
        ),
      ]),
      exec_ledger.default_limits(),
      "linux/x86_64",
      [],
    )
  assert facts.unclean == []
}

pub fn workspaces_are_cut_to_the_reports_bound_test() {
  let names = list.repeat("w", node_report.max_workspaces + 3)
  let facts =
    node_facts.executor_facts(
      snapshot([]),
      exec_ledger.default_limits(),
      "linux/x86_64",
      names,
    )
  assert list.length(facts.workspaces) == node_report.max_workspaces
}

// --- the directory's facts -------------------------------------------------------

fn lonely_status() -> member.Status {
  member.Status(
    members: ["alpha@10.0.0.1", "bravo@10.0.0.3"],
    joining: member.Joined,
    ra: Error(store.Unavailable("no answer in time")),
    applied_index: 7,
  )
}

pub fn a_member_that_cannot_confirm_its_copy_reports_it_unconfirmed_test() {
  // With no leader neither read finishes: Ra gives no membership and the fence
  // gives no answer. The member still reports, and says so.
  let facts =
    node_facts.directory_facts(lonely_status, fn() {
      Error(store.Unavailable("no quorum in time"))
    })
  assert facts.copy == node_report.Unconfirmed
  assert facts.status == lonely_status()
}

pub fn a_member_that_confirms_its_copy_reports_it_current_test() {
  let facts = node_facts.directory_facts(lonely_status, fn() { Ok(Nil) })
  assert facts.copy == node_report.Current
}

pub fn a_stopped_store_answers_both_reads_inside_the_reports_deadline_test() {
  // The budgets the report gives the two reads add up to less than the
  // deadline it runs them under, so a member with no quorum is reported
  // `Unconfirmed` and not dropped when the deadline kills its task.
  assert node_facts.status_ms + { node_facts.confirm_ms * 3 / 2 } + 300
    < node_facts.read_ms
  let started = bootstrap.monotonic_time_ms()
  let assert Error(store.Unavailable(..)) =
    store.confirm_current("alpha@10.0.0.1", node_facts.confirm_ms)
  let assert Error(store.Unavailable(..)) =
    store.membership_within(node_facts.status_ms)
  assert bootstrap.monotonic_time_ms() - started < node_facts.read_ms
}
