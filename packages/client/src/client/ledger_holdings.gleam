//// What the orchestrators of a deployment hold, asked of them for the operator's
//// `revoke` (protocol-change/086, phase 2, and section 11.1 of the design note).
////
//// Removing a member from the ledger is safe to sign and sometimes unwise to
//// send. An orchestrator that owns sessions would leave them unreachable until
//// it is enrolled again, and an executor that sessions are placed on would fail
//// them as an executor that is down does. The ledger cannot see sessions, and a
//// veto at apply time would give two nodes different tables from one log, so the
//// check belongs to the operator's tool. The tool reaches one daemon, and this
//// module is what that daemon does to answer it.
////
//// ## Who is asked, and about what
////
//// The daemon asks each orchestrator it is linked to, and itself if it is one,
//// the one question the orchestrator port answers (`orchestrator_port.Holds`):
//// how many sessions its catalogue owns, and how many are placed on each
//// executor. One question serves both removals. The sessions of an orchestrator
//// that is to be revoked are the first number of that orchestrator's own answer.
//// The sessions placed on an executor that is to be revoked are what the
//// orchestrators that use it say they placed there, which is why the answer is
//// by orchestrator and the operator's tool adds them up (`client/ledger_operator`).
//// Asking the executor about its scopes would need a read of its execution
//// ledger, which only the executor host may open, and would fail exactly when the
//// executor is gone.
////
//// An orchestrator that does not answer is reported as silent and never as
//// holding nothing. A sleeping laptop is silent, and so is a lost one; the
//// operator's tool treats silence as unknown and asks for `--force`.
////
//// ## The catalogue read
////
//// `from_catalogue` is the daemon's side of `Holds`. It walks the active
//// registrations a page at a time, drops those whose custody says the session
//// was handed to another orchestrator, and counts the rest, per executor for
//// those placed on one. Its answer is a count the operator's tool trusts, so it
//// is exact or it is not given. A catalogue longer than `max_pages` pages is
//// unknown, and so is a daemon that placed sessions on more than
//// `orchestrator_port.max_placed` distinct executors: a partial tally would
//// read as "this many and no more", and an executor missing from it as "none
//// placed there". Unknown is silence, and the revoke it belongs to needs
//// `--force`.
////
//// ## Flow
////
//// `collect` → `targets` → `over_distribution` → `from_catalogue` →
//// `placements`
////
//// 1. `targets` lists the orchestrators to ask: this node, if it is an active
////    orchestrator, and each orchestrator its pin table lists.
//// 2. `collect` asks them all at once in one weft run under a deadline, so
////    one silent laptop costs the reply at most that long.
//// 3. `over_distribution` is the production `Asker`: it connects to the pinned
////    peer, or addresses its own port, and asks `Holds`.
//// 4. `from_catalogue` is what the port runs when the question arrives.
//// 5. `placements` is the same walk answering a different question, how many of
////    the sessions placed on each executor are resident, for the report a
////    daemon gives of itself (protocol-change/085).

import client/daemon/manager.{type Manager}
import client/distribution.{type Membership}
import client/distribution_plan.{Orchestrator}
import client/executors.{type Executor}
import client/membership_ledger.{type Ledger}
import client/node_report.{type Placement}
import client/orchestrators
import client/remote/address
import client/remote/orchestrator_port.{type Held, type Holder, Held, Placed}
import client/roster.{type Roster}
import client/session_directory
import gleam/dict.{type Dict}
import gleam/erlang/node
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/catalogue
import weft

/// How long the whole fan-out may take. The asks run at once, so this is the
/// longest a silent orchestrator can hold the reply. It is shorter than the
/// five seconds the control client waits for any reply (`host/access`), because
/// a reply that arrives after the client gave up reads as a failure to ask, and
/// the operator is meant to read "this orchestrator did not answer".
pub const deadline_ms = 4000

// How long an orchestrator is given to walk its catalogue and answer, once
// connected. Connecting is bounded by `session_directory.reached` at 1.5
// seconds, so a slow connection and a slow answer together end at the run's
// deadline and not after it.
const reply_ms = 3000

/// The most catalogue pages `from_catalogue` reads, of
/// `storage/catalogue.page_limit` registrations each.
pub const max_pages = 200

/// One orchestrator's answer to the operator's question.
pub type Answer {
  Answer(
    /// The orchestrator's name in the ledger.
    name: String,
    /// Its Erlang node name.
    node: String,
    /// What it holds, or `None` when it did not say: it was unreachable, it
    /// ran no port, the answer was late, or its catalogue could not be read.
    held: Option(Held),
  )
}

/// How one orchestrator is asked, by its node name. `Error(Nil)` is silence.
pub type Asker =
  fn(String) -> Result(Held, Nil)

/// An asker that gets no answer from anyone. A daemon that has not been given a
/// way to reach its peers reports every orchestrator as silent, and the
/// operator's tool then asks for `--force`.
///
/// ## Examples
///
/// ```gleam
/// assert ledger_holdings.silent("loom@hub.example") == Error(Nil)
/// ```
pub fn silent(_node: String) -> Result(Held, Nil) {
  Error(Nil)
}

/// The orchestrators a node at `local` asks: itself, if it is an active
/// orchestrator, and each orchestrator its pin table lists, as name and node,
/// ordered by name. A node the ledger does not list as a member asks nobody.
///
/// ## Examples
///
/// ```gleam
/// ledger_holdings.targets(ledger, "loom@hub.example")
/// // -> [#("hub", "loom@hub.example"), #("laptop", "loom@laptop.example")]
/// ```
pub fn targets(ledger: Ledger, local: String) -> List(#(String, String)) {
  case membership_ledger.member_at(ledger, local) {
    Error(Nil) -> []
    Ok(own) -> {
      let peers =
        membership_ledger.node_table(ledger, local)
        |> membership_ledger.peers
        |> list.filter(fn(peer) { peer.role == Orchestrator })
        |> list.map(fn(peer) { #(peer.name, peer.node) })
      let itself = case own.role {
        Orchestrator -> [#(own.name, own.node)]
        _ -> []
      }
      list.append(itself, peers)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
    }
  }
}

/// Asks every orchestrator `targets` names, at once, and returns an answer for
/// each in the order of the targets.
///
/// The asks run in one weft run so that a silent node costs the reply at most
/// `deadline_ms`, and the run's deadline kills and joins any ask still waiting.
/// A task the deadline cut off, one that crashed and one that never started told
/// the daemon nothing, so each is silence and not "nothing held".
///
/// ## Examples
///
/// ```gleam
/// ledger_holdings.collect(ledger, "loom@hub.example", ledger_holdings.silent)
/// // -> [Answer(name: "hub", node: "loom@hub.example", held: None)]
/// ```
pub fn collect(ledger: Ledger, local: String, ask: Asker) -> List(Answer) {
  let asked = targets(ledger, local)
  case asked {
    [] -> []
    _ -> {
      let outcomes =
        asked
        |> list.map(fn(target) { fn() { ask(target.1) } })
        |> weft.new
        |> weft.deadline(deadline_ms)
        |> weft.start
      list.map2(asked, outcomes, fn(target, outcome) {
        Answer(name: target.0, node: target.1, held: heard(outcome))
      })
    }
  }
}

fn heard(outcome: weft.Outcome(Held, Nil)) -> Option(Held) {
  case outcome {
    weft.Completed(value:, ..) -> Some(value)
    weft.Failed(..)
    | weft.Crashed(..)
    | weft.Abandoned(..)
    | weft.NeverStarted(..)
    | weft.DrainProofLost(..)
    | weft.CancellationUnconfirmed(..) -> None
  }
}

/// The production asker. It addresses this node's own port directly for the
/// node named `local`, which has no pin of its own, and connects to the pinned
/// peer of any other, as the session directory does. A peer the membership does
/// not know, a refused handshake, an unreachable host, a missing port and a late
/// answer are each silence.
///
/// ## Examples
///
/// ```gleam
/// ledger_holdings.over_distribution(membership, "loom@hub.example")
/// ```
pub fn over_distribution(membership: Membership, local: String) -> Asker {
  fn(peer_node) {
    use at <- result.try(case peer_node == local {
      True ->
        Ok(address.Address(node: node.self(), name: orchestrator_port.default()))
      False ->
        session_directory.reached(
          membership,
          orchestrators.plain(peer_node, peer_node),
        )
    })
    orchestrator_port.ask_holds(at, reply_ms)
  }
}

// --- the daemon's side of the question -------------------------------------------

// What a walk of the catalogue has counted.
type Tally {
  Tally(sessions: Int, by_executor: Dict(String, Counts))
}

// The sessions placed on one executor, and how many of them have a usable
// resident runtime.
type Counts {
  Counts(placed: Int, resident: Int)
}

/// What the port answers to `Holds`: the sessions this daemon's catalogue owns
/// and where they are placed. `listed` names the executors by node, because a
/// session records the name its owner's file gave the executor and the asker
/// reasons about nodes.
///
/// Archived sessions are not counted, as `sessions.list` does not show them. A
/// session whose custody is `Moved` was handed to another orchestrator and is
/// that orchestrator's. A session placed on an executor that no row lists now is
/// counted as a session and not as a placement, since it names no node. A
/// catalogue that cannot be read, one longer than `max_pages` pages and one with
/// sessions on more than `orchestrator_port.max_placed` executors are each
/// `Error(Nil)`.
///
/// ## Examples
///
/// ```gleam
/// // orchestrator_port.start_with(name, held, peer, describe, importer, spawns, ledger_holdings.from_catalogue(registry, executors))
/// ```
pub fn from_catalogue(
  registry: Manager(instance),
  listed: Roster(Executor),
) -> Holder {
  from_pages(registry, listed, max_pages)
}

/// The same with the bound on pages given, so that a test can reach it without
/// a catalogue of `max_pages` pages.
///
/// ## Examples
///
/// ```gleam
/// // ledger_holdings.from_pages(registry, executors, 1)()
/// ```
pub fn from_pages(
  registry: Manager(instance),
  listed: Roster(Executor),
  pages: Int,
) -> Holder {
  fn() {
    use tally <- result.try(count(registry, "", Tally(0, dict.new()), pages))
    use nodes <- result.map(placed_on(tally.by_executor, roster.rows(listed)))
    Held(
      sessions: tally.sessions,
      placed: list.map(nodes, fn(entry) {
        let #(executor_node, counts) = entry
        Placed(executor_node:, sessions: counts.placed)
      }),
    )
  }
}

/// How many sessions this daemon's catalogue has placed on each executor, and
/// how many of those have a usable resident runtime, for a node's report
/// (protocol-change/085). It is the walk `from_catalogue` makes, with the same
/// exclusions: archived sessions and sessions handed to another orchestrator are
/// not counted, and a session placed on an executor no row lists names no node.
///
/// `Error(Nil)` is not an empty list. A catalogue that cannot be read, one longer
/// than `max_pages` pages, and sessions on more executors than the port carries
/// (`orchestrator_port.max_placed`, which equals `node_report.max_placements`)
/// are each unknown, and the caller leaves the facts out rather than state a
/// partial count.
///
/// ## Examples
///
/// ```gleam
/// // ledger_holdings.placements(registry, executors)
/// // -> Ok([Placement("box@10.0.0.2", resident: 1, saved: 4)])
/// ```
pub fn placements(
  registry: Manager(instance),
  listed: Roster(Executor),
) -> Result(List(Placement), Nil) {
  use tally <- result.try(count(registry, "", Tally(0, dict.new()), max_pages))
  use nodes <- result.map(placed_on(tally.by_executor, roster.rows(listed)))
  list.map(nodes, fn(entry) {
    let counts = entry.1
    node_report.Placement(
      executor_node: entry.0,
      resident: counts.resident,
      saved: counts.placed - counts.resident,
    )
  })
}

// Reads the catalogue's pages in identity order, a page at a time, until one is
// empty. Each page's custody is read in one registry turn. After `pages_left`
// pages the walk stops, and it is complete only if the next page is empty: a
// page with registrations on it means the tally is short, which is unknown.
fn count(
  registry: Manager(instance),
  after: String,
  tally: Tally,
  pages_left: Int,
) -> Result(Tally, Nil) {
  case pages_left {
    0 ->
      case manager.page(registry, after:) {
        Ok(#(_revision, [])) -> Ok(tally)
        Ok(#(_revision, [_, ..])) | Error(_) -> Error(Nil)
      }
    _ ->
      case manager.page(registry, after:) {
        Error(_) -> Error(Nil)
        Ok(#(_revision, [])) -> Ok(tally)
        Ok(#(_revision, views)) -> {
          let ids = list.map(views, fn(view) { view.registration.id })
          use custodies <- result.try(
            manager.custodies(registry, ids) |> result.replace_error(Nil),
          )
          let owned =
            list.filter(views, fn(view) {
              !handed_away(custodies, view.registration.id)
            })
          let next = case list.last(ids) {
            Ok(last) -> last
            Error(Nil) -> after
          }
          count(registry, next, add(tally, owned), pages_left - 1)
        }
      }
  }
}

fn handed_away(
  custodies: List(#(String, catalogue.Custody)),
  id: String,
) -> Bool {
  case list.key_find(custodies, id) {
    Ok(catalogue.Moved(..)) -> True
    Ok(catalogue.Resident)
    | Ok(catalogue.Moving(..))
    | Ok(catalogue.Imported(..))
    | Error(Nil) -> False
  }
}

fn add(tally: Tally, owned: List(manager.View)) -> Tally {
  list.fold(owned, tally, fn(tally, view) {
    let resident = case view.status {
      manager.Resident(..) -> 1
      manager.Reserved
      | manager.Saved
      | manager.Opening(..)
      | manager.Stopping(..)
      | manager.RecoveryBlocked(..) -> 0
    }
    let placed = case view.registration.executor {
      "" -> tally.by_executor
      name ->
        dict.upsert(tally.by_executor, name, fn(seen) {
          let before = option.unwrap(seen, Counts(placed: 0, resident: 0))
          Counts(
            placed: before.placed + 1,
            resident: before.resident + resident,
          )
        })
    }
    Tally(sessions: tally.sessions + 1, by_executor: placed)
  })
}

// The placements by executor node: the names the file gave are looked up in the
// executors this daemon lists, two names for one node are added together, and
// the list is ordered by node. More nodes than the port carries is unknown, not
// the first of them, because the operator's tool reads a node missing from the
// list as a node with nothing placed on it.
fn placed_on(
  by_name: Dict(String, Counts),
  listed: List(Executor),
) -> Result(List(#(String, Counts)), Nil) {
  let by_node =
    dict.to_list(by_name)
    |> list.filter_map(fn(entry) {
      executors.find(listed, entry.0)
      |> result.map(fn(executor) { #(executor.node, entry.1) })
    })
    |> list.fold(dict.new(), fn(sums, entry) {
      dict.upsert(sums, entry.0, fn(seen) {
        let before = option.unwrap(seen, Counts(placed: 0, resident: 0))
        Counts(
          placed: before.placed + entry.1.placed,
          resident: before.resident + entry.1.resident,
        )
      })
    })
  case dict.size(by_node) > orchestrator_port.max_placed {
    True -> Error(Nil)
    False ->
      dict.to_list(by_node)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> Ok
  }
}
