//// Configuration edits through the proposal queue (protocol-change/091),
//// driven through any sequence of proposals, decisions, hand edits and
//// decisions from a session that loads another file (`statem`).
////
//// The system under test is the real queue over a real memory store and a
//// real configuration file. The model is empty; the oracle beside the queue
//// holds what the file was when each proposal was filed, and states the rules
//// of `client/proposals`' configuration section: the file changes only on an
//// approval, only while it is the text the proposal was judged against, always
//// to a text that loads and holds the proposed lines, always keeping its
//// permission bits, and never from a session that loads another file.

import client/memory
import client/proposals
import core/clock
import events/bus
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import qcheck
import simplifile
import statem
import telemetry/log
import tools/propose

/// The campaign's seed, run count and longest sequence.
const campaign_seed = 8017

const runs = 60

const longest = 24

const now_ms = 1_790_000_000_000

/// The permission bits the file starts with, which every write must keep.
const mode = 0o640

fn config() -> statem.Config {
  statem.default_config(seed: campaign_seed)
  |> statem.with_test_count(runs)
  |> statem.with_max_commands(longest)
}

// A configuration loads unless it holds the word `broken`, which stands for any
// text the session's own loader would refuse.
fn check(text: String) -> Result(Nil, String) {
  case string.contains(text, "broken") {
    True -> Error("refused")
    False -> Ok(Nil)
  }
}

// --- commands ----------------------------------------------------------------

type Edit {
  // Appends `key_<n> = 1`.
  Append(key: Int)

  // Replaces `key_<n> = 1` with `key_<n> = 2`, which needs the line once.
  Replace(key: Int)

  // Appends text the loader refuses.
  Break
}

type Command {
  Propose(edit: Edit)

  // Decides the proposal at this index of those filed, modulo their count.
  Approve(pick: Int)

  Reject(pick: Int)

  // The operator edits the file by hand.
  HandEdit

  // A session that loads another configuration tries to approve it.
  Foreign(pick: Int)
}

fn command() -> qcheck.Generator(Command) {
  let edit =
    qcheck.bounded_int(0, 6)
    |> qcheck.map(fn(pick) {
      case pick {
        0 | 1 | 2 -> Append(pick)
        3 | 4 | 5 -> Replace(pick - 3)
        _ -> Break
      }
    })
  let pick = qcheck.bounded_int(0, 7)
  qcheck.from_weighted_generators(#(40, qcheck.map(edit, Propose)), [
    #(30, qcheck.map(pick, Approve)),
    #(10, qcheck.map(pick, Reject)),
    #(10, qcheck.constant(HandEdit)),
    #(10, qcheck.map(pick, Foreign)),
  ])
}

fn submission(edit: Edit) -> propose.Submission {
  let #(old, new) = case edit {
    Append(key:) -> #("", line(key, 1))
    Replace(key:) -> #(line(key, 1), line(key, 2))
    Break -> #("", "broken = true")
  }
  propose.Submission(
    target: propose.Configuration,
    old:,
    new:,
    rationale: "it came up",
    source_entry: None,
  )
}

fn line(key: Int, value: Int) -> String {
  "key_" <> int.to_string(key) <> " = " <> int.to_string(value)
}

// --- the system under test -----------------------------------------------------

type Filed {
  Filed(id: String, base: String, new: String)
}

type Sut {
  Sut(
    root: String,
    path: String,
    ours: proposals.Wiring,
    theirs: proposals.Wiring,
    filed: List(Filed),
  )
}

fn new_sut() -> Sut {
  let assert Ok(here) = simplifile.current_directory() as "the cwd is known"
  let root =
    here
    <> "/build/config-proposals-"
    <> int.to_string(int.random(1_000_000_000))
  let assert Ok(Nil) = simplifile.create_directory_all(root) as "root is made"
  let path = root <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(path, "a = 0\n")
    as "the file is written"
  let assert Ok(Nil) = simplifile.set_permissions_octal(path, mode)
    as "the file's mode is set"
  Sut(
    root:,
    path:,
    ours: wiring(root, "ours", path),
    theirs: wiring(root, "theirs", root <> "/other.toml"),
    filed: [],
  )
}

fn wiring(root: String, session: String, path: String) -> proposals.Wiring {
  let entropy = fn() { int.random(1_000_000_000_000) }
  proposals.Wiring(
    store_path: root <> "/" <> memory.memory_file,
    rules_path: root <> "/loom-rules.md",
    session:,
    clock: clock.fixed(now_ms),
    entropy:,
    bus: bus.start(),
    logger: log.discard(),
    config: Some(proposals.ConfigFile(path:, check:)),
  )
}

fn file(sut: Sut) -> String {
  let assert Ok(text) = simplifile.read(sut.path) as "the file reads"
  text
}

fn execute(sut: Sut, command: Command) -> Result(Sut, statem.Violation) {
  let before = file(sut)
  case command {
    Propose(edit:) -> {
      let wanted = submission(edit)
      case proposals.submit(sut.ours, wanted), edit {
        Ok(_), Break -> violation("queued_unloadable", before)
        Ok(id), _ ->
          Ok(
            Sut(..sut, filed: [
              Filed(id:, base: before, new: wanted.new),
              ..sut.filed
            ]),
          )
        Error(_), _ -> unchanged(sut, before, "refusal_wrote")
      }
    }
    Approve(pick:) -> approve(sut, pick, before)
    Reject(pick:) ->
      case picked(sut, pick) {
        None -> Ok(sut)
        Some(row) -> {
          let _ = proposals.decide(sut.ours, row.id, proposals.Reject)
          unchanged(sut, before, "rejection_wrote")
        }
      }
    HandEdit -> {
      let assert Ok(Nil) = simplifile.write(sut.path, before <> "# edited\n")
        as "a hand edit lands"
      Ok(sut)
    }
    Foreign(pick:) ->
      case picked(sut, pick) {
        None -> Ok(sut)
        Some(row) ->
          case proposals.decide(sut.theirs, row.id, proposals.Approve) {
            Ok(proposals.Proposal(state: proposals.Approved, ..)) ->
              violation("foreign_approved", row.id)
            _ -> unchanged(sut, before, "foreign_wrote")
          }
      }
  }
}

// An approval writes only over the text the proposal was judged against, and
// what it writes loads, holds the proposed line and keeps the file's mode.
fn approve(
  sut: Sut,
  pick: Int,
  before: String,
) -> Result(Sut, statem.Violation) {
  case picked(sut, pick) {
    None -> Ok(sut)
    Some(row) ->
      case proposals.decide(sut.ours, row.id, proposals.Approve) {
        Ok(proposals.Proposal(state: proposals.Approved, ..)) -> {
          let after = file(sut)
          case
            before == row.base,
            check(after),
            string.contains(after, row.new)
          {
            False, _, _ -> violation("stale_written", after)
            _, Error(_), _ -> violation("unloadable_written", after)
            _, _, False -> violation("approved_not_written", after)
            True, Ok(Nil), True -> kept_mode(sut)
          }
        }
        Ok(proposals.Proposal(state: proposals.Stale, ..)) ->
          case before == row.base {
            True -> violation("current_called_stale", row.id)
            False -> unchanged(sut, before, "stale_wrote")
          }
        _ -> unchanged(sut, before, "undecided_wrote")
      }
  }
}

fn picked(sut: Sut, pick: Int) -> option.Option(Filed) {
  case sut.filed {
    [] -> None
    rows ->
      list.drop(list.reverse(rows), pick % list.length(rows))
      |> list.first
      |> option.from_result
  }
}

fn unchanged(
  sut: Sut,
  before: String,
  tag: String,
) -> Result(Sut, statem.Violation) {
  case file(sut) == before {
    True -> Ok(sut)
    False -> violation(tag, file(sut))
  }
}

fn kept_mode(sut: Sut) -> Result(Sut, statem.Violation) {
  let assert Ok(info) = simplifile.file_info(sut.path) as "the file stats"
  case simplifile.file_info_permissions_octal(info) == mode {
    True -> Ok(sut)
    False -> violation("mode_lost", int.to_base8(info.mode))
  }
}

fn violation(tag: String, detail: String) -> Result(a, statem.Violation) {
  Error(statem.Violation(tag:, detail:))
}

fn spec() -> statem.Spec(Nil, Command, Sut) {
  statem.Spec(
    initial: Nil,
    command: fn(_) { command() },
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(_, _) { Nil },
    new_sut:,
    execute: fn(sut, _, command) { execute(sut, command) },
    finish: fn(_, _) { Ok(Nil) },
    teardown: fn(sut) {
      let _ = simplifile.delete_all([sut.root])
      Nil
    },
  )
}

pub fn configuration_proposals_keep_their_rules_under_any_sequence_test() {
  case statem.check(spec(), config()) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, string.inspect)
  }
}

// Every rule's case is drawn: each command, and an approval following a hand
// edit, which is the only way a configuration proposal goes stale.
pub fn the_generator_reaches_every_case_test() {
  let lists =
    int.range(from: 0, to: runs, with: [], run: fn(all, run) {
      [statem.commands(spec(), config(), run), ..all]
    })
  let drawn = list.flatten(lists)
  let has = fn(match) { list.any(drawn, match) }
  assert has(fn(c) {
    case c {
      Propose(Break) -> True
      _ -> False
    }
  })
  assert has(fn(c) {
    case c {
      Propose(Replace(..)) -> True
      _ -> False
    }
  })
  assert has(fn(c) {
    case c {
      Reject(..) -> True
      _ -> False
    }
  })
  assert has(fn(c) {
    case c {
      Foreign(..) -> True
      _ -> False
    }
  })
  assert list.any(lists, fn(commands) {
    list.window_by_2(commands)
    |> list.any(fn(pair) {
      case pair {
        #(HandEdit, Approve(..)) -> True
        _ -> False
      }
    })
  })
}

// --- the refusals that need no sequence ------------------------------------------

pub fn a_session_with_no_configuration_refuses_a_configuration_edit_test() {
  let sut = new_sut()
  let wiring = proposals.Wiring(..sut.ours, config: None)
  assert proposals.submit(wiring, submission(Append(0)))
    == Error(propose.Invalid(
      "this session loads no configuration file, so it has none to edit",
    ))
  let _ = simplifile.delete_all([sut.root])
  Nil
}

pub fn a_configuration_behind_a_link_is_never_replaced_test() {
  let sut = new_sut()
  let linked = sut.root <> "/linked.toml"
  let assert Ok(Nil) = simplifile.create_symlink(sut.path, linked)
    as "the link is made"
  let wiring =
    proposals.Wiring(
      ..sut.ours,
      config: Some(proposals.ConfigFile(path: linked, check:)),
    )
  let assert Ok(id) = proposals.submit(wiring, submission(Append(0)))
    as "the edit queues"
  let assert Error(proposals.CannotApply(reason)) =
    proposals.decide(wiring, id, proposals.Approve)
    as "the approval refuses"
  assert string.contains(reason, "symbolic link")
  let assert Ok(info) = simplifile.link_info(linked) as "the link remains"
  assert simplifile.file_info_type(info) == simplifile.Symlink
  let _ = simplifile.delete_all([sut.root])
  Nil
}

pub fn a_stored_configuration_row_must_name_an_absolute_path_test() {
  let sut = new_sut()
  let assert Ok(id) = proposals.submit(sut.ours, submission(Append(1)))
    as "the edit queues"
  let assert Ok(listing) = proposals.listing(sut.ours) as "the queue reads"
  let assert [row] = listing.proposals as "one row"
  assert row.id == id
  assert row.kind == proposals.Config
  assert row.target == sut.path
  let encoded = proposals.encode(proposals.Proposal(..row, target: "loom.toml"))
  assert proposals.decode(encoded)
    == Error("`target` is not an absolute configuration path")
  let _ = simplifile.delete_all([sut.root])
  Nil
}
