//// The configuration watcher, driven through any sequence of saves, removals,
//// oversized files and reads (`statem`).
////
//// The system under test is a real watcher over a real file, stepped by hand
//// with `config_watch.tick`, and its notices are counted on a subject. The model
//// is empty: every command is admissible, and the oracle sits beside the
//// watcher because it states its rule over what the reads saw. The rule is the
//// module's: a notice comes exactly when two reads in a row agree on a text that
//// passes the check and differs from the text the session has, and never twice
//// for one text.

import client/config_watch
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import qcheck
import simplifile
import statem
import telemetry/log

/// The seed of the campaign, how many runs it makes and the longest sequence.
const campaign_seed = 6091

const runs = 120

const longest = 40

fn config() -> statem.Config {
  statem.default_config(seed: campaign_seed)
  |> statem.with_test_count(runs)
  |> statem.with_max_commands(longest)
}

// --- commands ----------------------------------------------------------------

// What a file can hold, as the watcher reads it. Texts 0 and 1 pass the check
// and texts 2 and 3 fail it, so a sequence can change between two good texts,
// break the file, and mend it again.
type Content {
  Text(index: Int)
  Missing
  TooBig
}

type Command {
  Tick

  Write(index: Int)

  Remove

  Oversize
}

// A read is the simplest command, so a failure shrinks toward fewer saves.
fn command() -> qcheck.Generator(Command) {
  qcheck.from_weighted_generators(#(50, qcheck.constant(Tick)), [
    #(35, qcheck.map(qcheck.bounded_int(0, 3), Write)),
    #(8, qcheck.constant(Remove)),
    #(7, qcheck.constant(Oversize)),
  ])
}

fn text_of(index: Int) -> String {
  case index < 2 {
    True -> "ok " <> int.to_string(index)
    False -> "bad " <> int.to_string(index)
  }
}

fn check(text: String) -> Result(Nil, String) {
  case string.starts_with(text, "ok ") {
    True -> Ok(Nil)
    False -> Error("refused")
  }
}

// --- the oracle --------------------------------------------------------------

type Oracle {
  Oracle(
    // What the file holds now.
    file: Content,
    // What the last read saw, and how many reads in a row saw it.
    last_read: Option(Content),
    streak: Int,
    // The text the session has: the baseline, then each text it was told of.
    applied: Option(Int),
  )
}

fn begin() -> Oracle {
  Oracle(file: Text(0), last_read: None, streak: 0, applied: Some(0))
}

// The file after a command that changes it, and, for a read, whether the rule
// owes a notice. Pure, so the census below walks it with nothing executed.
fn expect(oracle: Oracle, command: Command) -> #(Oracle, Int) {
  case command {
    Write(index:) -> #(Oracle(..oracle, file: Text(index)), 0)
    Remove -> #(Oracle(..oracle, file: Missing), 0)
    Oversize -> #(Oracle(..oracle, file: TooBig), 0)
    Tick -> read(oracle)
  }
}

fn read(oracle: Oracle) -> #(Oracle, Int) {
  let streak = case oracle.last_read == Some(oracle.file) {
    True -> oracle.streak + 1
    False -> 1
  }
  let read = Oracle(..oracle, last_read: Some(oracle.file), streak:)
  case oracle.file {
    Text(index:) if streak >= 2 && index < 2 ->
      case Some(index) == oracle.applied {
        True -> #(read, 0)
        False -> #(Oracle(..read, applied: Some(index)), 1)
      }
    Text(..) | Missing | TooBig -> #(read, 0)
  }
}

// --- the system under test -----------------------------------------------------

type Sut {
  Sut(
    path: String,
    pid: process.Pid,
    watcher: Subject(config_watch.Message),
    notices: Subject(Nil),
    oracle: Oracle,
  )
}

fn new_sut() -> Sut {
  let directory =
    "build/config_watch_test/" <> int.to_string(int.random(1_000_000_000))
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "the scratch directory is made"
  let path = directory <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(path, text_of(0))
    as "the session's file is written"
  let assert Ok(baseline) = config_watch.fingerprint(path)
    as "the baseline reads"
  let notices = process.new_subject()
  let assert Ok(started) =
    config_watch.start_unticked(
      config_watch.Source(path:, baseline: Some(baseline), check:),
      fn() { process.send(notices, Nil) },
      log.discard(),
    )
    as "the watcher starts"
  Sut(path:, pid: started.pid, watcher: started.data, notices:, oracle: begin())
}

fn execute(sut: Sut, command: Command) -> Result(Sut, statem.Violation) {
  let #(oracle, owed) = expect(sut.oracle, command)
  case command {
    Write(index:) -> {
      let assert Ok(Nil) = simplifile.write(sut.path, text_of(index))
        as "a save lands"
      Ok(Sut(..sut, oracle:))
    }
    Remove -> {
      // A second removal finds nothing to remove, which is still a removal.
      let _ = simplifile.delete(sut.path)
      Ok(Sut(..sut, oracle:))
    }
    Oversize -> {
      let assert Ok(Nil) =
        simplifile.write(
          sut.path,
          string.repeat("x", config_watch.max_file_bytes + 1),
        )
        as "an oversized save lands"
      Ok(Sut(..sut, oracle:))
    }
    Tick -> {
      config_watch.tick(sut.watcher)
      judge(sut, oracle, owed, drain(sut.notices, 0))
    }
  }
}

// The specific rules come before the count, so a failure is named for the rule
// it broke rather than as a disagreement with the oracle.
fn judge(
  sut: Sut,
  oracle: Oracle,
  owed: Int,
  told: Int,
) -> Result(Sut, statem.Violation) {
  let file = string.inspect(sut.oracle.file)
  case told, owed, sut.oracle.file {
    1, _, Text(index:) if index >= 2 ->
      Error(statem.Violation("refused_text_notified", file))
    1, _, Missing | 1, _, TooBig ->
      Error(statem.Violation("unreadable_notified", file))
    1, 0, _ ->
      case oracle.streak < 2 {
        True -> Error(statem.Violation("unsettled_notified", file))
        False -> Error(statem.Violation("unchanged_notified", file))
      }
    0, 1, _ -> Error(statem.Violation("missed_notice", file))
    told, owed, _ if told == owed -> Ok(Sut(..sut, oracle:))
    _, _, _ ->
      Error(statem.Violation(
        "notice_count",
        int.to_string(told) <> " notices for " <> file,
      ))
  }
}

fn drain(notices: Subject(Nil), count: Int) -> Int {
  case process.receive(notices, within: 0) {
    Ok(Nil) -> drain(notices, count + 1)
    Error(Nil) -> count
  }
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
      process.unlink(sut.pid)
      process.kill(sut.pid)
      let _ = simplifile.delete(sut.path)
      Nil
    },
  )
}

pub fn the_watcher_notifies_exactly_on_settled_good_changes_test() {
  case statem.check(spec(), config()) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, string.inspect)
  }
}

// Every rule is reached: each command kind is drawn, a notice is owed, a
// refused text settles, and an unreadable file is read after a good one.
pub fn the_generator_reaches_every_case_test() {
  let reached =
    int.range(from: 0, to: runs, with: [], run: fn(all, run) { [run, ..all] })
    |> list.flat_map(fn(run) {
      let commands = statem.commands(spec(), config(), run)
      let #(_, seen) =
        list.fold(commands, #(begin(), []), fn(acc, command) {
          let #(oracle, seen) = acc
          let #(next, owed) = expect(oracle, command)
          let refused_settled = case command, next.file, next.streak {
            Tick, Text(index:), streak if index >= 2 && streak >= 2 -> [
              "refused_settled",
            ]
            _, _, _ -> []
          }
          let notice = case owed {
            1 -> ["notice"]
            _ -> []
          }
          #(
            next,
            list.flatten([[kind(command)], notice, refused_settled, seen]),
          )
        })
      seen
    })
  list.each(
    ["tick", "write", "remove", "oversize", "notice", "refused_settled"],
    fn(wanted) {
      assert list.contains(reached, wanted) as wanted
    },
  )
}

fn kind(command: Command) -> String {
  case command {
    Tick -> "tick"
    Write(..) -> "write"
    Remove -> "remove"
    Oversize -> "oversize"
  }
}
