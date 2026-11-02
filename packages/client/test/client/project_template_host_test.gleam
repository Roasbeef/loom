//// The template's lifecycle in the project actor: preparing, ready, failed and
//// base check red, and what each does to a ticket that wants a worker.
////
//// The actor, the ledger and the engine are real. The build is a fake port that
//// records what it was asked and answers from a script, so each test says which
//// builds ran and with what. The builds themselves, against a real sandbox, are
//// `project_template_test`.

import client/daemon/project_host
import client/internal/ffi_os
import client/project_template
import core/json
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import project/model
import simplifile
import support/project_ports
import tools/project as tools
import weft/poll

type Seen {
  Built(current: option.Option(String))
  Started(key: String)
}

// What the fake build answers next, read afresh on every call so a test can
// change it, and whether it waits to be released first.
type Script {
  Script(
    answer: fn(project_template.Request) -> project_template.Outcome,
    gate: Gate,
  )
}

// Whether a build waits to be released before it answers.
type Gate {
  Open
  Closed
}

fn built(
  commit: String,
) -> fn(project_template.Request) -> project_template.Outcome {
  fn(_) { project_template.Built(commit) }
}

fn failing(
  stage: project_template.Stage,
  output: String,
) -> fn(project_template.Request) -> project_template.Outcome {
  fn(_) { project_template.Failed(project_template.Failure(stage, output)) }
}

// A script holder: a process that answers who asks with the current script, and
// takes a new one. A test changes what the next build sees by sending it.
type Holder =
  Subject(Message)

type Message {
  Read(reply: Subject(Script))
  Set(Script)
}

fn hold(first: Script) -> Holder {
  let made = process.new_subject()
  process.spawn_unlinked(fn() {
    let inbox = process.new_subject()
    process.send(made, inbox)
    serve(inbox, first)
  })
  let assert Ok(inbox) = process.receive(made, 1000) as "the holder starts"
  inbox
}

fn serve(inbox: Holder, current: Script) -> Nil {
  case process.receive_forever(inbox) {
    Read(reply) -> {
      process.send(reply, current)
      serve(inbox, current)
    }
    Set(next) -> serve(inbox, next)
  }
}

// Waits until the script's gate is open, polling the holder, for at most
// `polls` times 50 ms.
fn wait_open(holder: Holder, polls: Int) -> Nil {
  case current(holder).gate, polls {
    Open, _ | Closed, 0 -> Nil
    Closed, _ -> {
      process.sleep(50)
      wait_open(holder, polls - 1)
    }
  }
}

fn current(holder: Holder) -> Script {
  process.call(holder, 1000, Read)
}

fn directory(name: String) -> String {
  let path =
    "build/project-template-host-"
    <> name
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let _removed = simplifile.delete(path)
  let assert Ok(Nil) = bootstrap.ensure_private_directory("build")
    as "the build directory exists"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(path)
    as "the scratch directory is made"
  path
}

fn policy() -> project_host.Policy {
  project_host.Policy(
    ..project_host.idle_policy,
    check: Some("make check"),
    setup: Some("make deps"),
    check_wall_ms: 5000,
    setup_wall_ms: 5000,
  )
}

// A config over a ledger in `path`, whose fakes report to `seen` and whose
// build follows `holder`. `tick_ms` and `clock` are the test's to choose.
fn config(
  path: String,
  seen: Subject(Seen),
  holder: Holder,
  tick_ms: Int,
  clock: fn() -> Int,
  policy: project_host.Policy,
) -> project_host.Config {
  let ports =
    project_host.Ports(
      ..project_ports.inert(),
      now_ms: clock,
      start_session: fn(request: project_host.StartRequest) {
        process.send(seen, Started(request.key))
        Ok("session-" <> request.key)
      },
      build_template: fn(request: project_template.Request) {
        process.send(seen, Built(request.current))
        wait_open(holder, 600)
        current(holder).answer(request)
      },
    )
  project_host.Config(
    project: "p1",
    workspace: "/work/repo",
    router_session: "router-1",
    ledger_path: path <> "/ledger.db",
    max_workers: 2,
    tick_ms:,
    router_turn_ms: 3_600_000,
    policy:,
    ports: fn() { ports },
  )
}

fn quiet_config(
  path: String,
  seen: Subject(Seen),
  holder: Holder,
) -> project_host.Config {
  config(path, seen, holder, 3_600_000, ffi_os.system_time_ms, policy())
}

fn start(config: project_host.Config) -> project_host.Handle {
  let assert Ok(handle) = project_host.start(config) as "the actor starts"
  handle
}

fn stop(handle: project_host.Handle) -> Nil {
  let assert Ok(pid) = process.subject_owner(handle.commands)
    as "the actor has an owner"
  process.unlink(pid)
  process.kill(pid)
  process.sleep(50)
}

fn accept(trigger: String) -> tools.Item {
  tools.Item(
    trigger: model.TriggerId(trigger),
    action: tools.Accept(model.title("work on " <> trigger)),
    holds: [],
    related: [],
    prior_hand_back: None,
  )
}

// Posts a ticket and has the router accept it, so the engine asks for a worker.
fn want_worker(handle: project_host.Handle, trigger: String) -> Nil {
  let assert Ok(_) = project_host.post(handle, trigger, "fix " <> trigger)
  let assert Ok([tools.Applied]) = project_host.route(handle, [accept(trigger)])
  Nil
}

fn sources(handle: project_host.Handle) -> String {
  let assert Ok(shown) = project_host.board(handle, 0) as "the board reads"
  json.to_string(json.Array(shown.sources))
}

fn tickets(handle: project_host.Handle) -> String {
  let assert Ok(shown) = project_host.board(handle, 0) as "the board reads"
  json.to_string(json.Array(shown.tickets))
}

// Waits, for less than the 50 s EUnit allows a test, until `read` contains
// `wanted`, so a miss fails this test and does not cancel the rest.
fn eventually(read: fn() -> String, wanted: String) -> Bool {
  case
    poll.until(within: 20_000, every: 25, attempt: fn() {
      case string.contains(read(), wanted) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  {
    poll.Answered(Nil) -> True
    poll.Expired | poll.Failed(_) -> False
  }
}

// Whether `wanted` shows up in what the fakes saw within `ms`.
fn saw(seen: Subject(Seen), wanted: Seen, ms: Int) -> Bool {
  case process.receive(seen, ms) {
    Ok(one) if one == wanted -> True
    Ok(_) -> saw(seen, wanted, ms)
    Error(Nil) -> False
  }
}

fn quiet(seen: Subject(Seen)) -> Bool {
  case process.receive(seen, 300) {
    Ok(Started(_)) -> False
    Ok(Built(_)) -> quiet(seen)
    Error(Nil) -> True
  }
}

// --- the tests ---------------------------------------------------------------------

pub fn a_ticket_waits_while_the_template_is_prepared_and_nothing_fails_test() {
  let path = directory("waits")
  let holder = hold(Script(answer: built("abc1234abc12"), gate: Closed))
  let seen = process.new_subject()
  let handle = start(quiet_config(path, seen, holder))

  // The first build is queued at boot and held at its gate.
  assert saw(seen, Built(None), 5000)
  assert eventually(fn() { sources(handle) }, "\"preparing\"")
  want_worker(handle, "a")

  // The ticket is queued and no worker starts, for as long as the build runs.
  assert quiet(seen)
  assert eventually(fn() { tickets(handle) }, "queued")
  assert !string.contains(tickets(handle), "failed")

  // The build finishes: the ticket gets its worker, and the board says ready
  // at the commit.
  process.send(holder, Set(Script(answer: built("abc1234abc12"), gate: Open)))
  assert saw(seen, Started("project:p1:t-a:1"), 10_000)
  assert eventually(fn() { sources(handle) }, "\"ready\"")
  assert string.contains(sources(handle), "abc1234abc12")
  assert string.contains(sources(handle), "\"note\":\"\"")
  stop(handle)
}

pub fn a_failed_setup_starts_no_worker_and_the_board_says_it_is_the_setup_test() {
  let path = directory("setup-fails")
  let holder =
    hold(Script(
      answer: failing(project_template.Setup, "exit status 2\nno such module"),
      gate: Open,
    ))
  let seen = process.new_subject()
  let handle = start(quiet_config(path, seen, holder))
  want_worker(handle, "a")

  assert eventually(fn() { sources(handle) }, "\"failed\"")
  let board = sources(handle)
  assert string.contains(board, "The project's setup failed")
  assert string.contains(board, "not any ticket")
  assert string.contains(board, "exit status 2")

  // The output is on the row, bounded by the build, and no worker started.
  assert string.contains(board, "no such module")
  assert quiet(seen)
  assert string.contains(tickets(handle), "queued")

  // A person retries through the existing retry command, naming the setup. The
  // build now succeeds, and the waiting ticket gets its worker.
  process.send(holder, Set(Script(answer: built("abc1234abc12"), gate: Open)))
  let assert Ok(Nil) = project_host.retry(handle, "setup", "owner")
  assert saw(seen, Started("project:p1:t-a:1"), 10_000)
  assert eventually(fn() { sources(handle) }, "\"ready\"")
  stop(handle)
}

pub fn a_red_base_check_starts_no_worker_and_says_the_check_is_red_test() {
  let path = directory("base-red")
  let holder =
    hold(Script(
      answer: failing(project_template.BaseCheck, "exit status 1\nFAIL: base"),
      gate: Open,
    ))
  let seen = process.new_subject()
  let handle = start(quiet_config(path, seen, holder))
  want_worker(handle, "a")

  assert eventually(fn() { sources(handle) }, "\"base_check_red\"")
  let board = sources(handle)
  assert string.contains(board, "red on the clean base")
  assert string.contains(board, "FAIL: base")
  assert quiet(seen)
  stop(handle)
}

pub fn a_retry_with_nothing_to_retry_is_refused_in_words_test() {
  let path = directory("no-setup")
  let holder = hold(Script(answer: built("abc1234"), gate: Open))
  let seen = process.new_subject()
  let bare =
    project_host.Config(
      ..quiet_config(path, seen, holder),
      policy: project_host.idle_policy,
    )
  let handle = start(bare)

  // A project with no setup has no template row on its board, and a retry of
  // the setup says there is none.
  assert sources(handle) == "[]"
  let assert Error(why) = project_host.retry(handle, "setup", "owner")
  assert string.contains(why, "no setup")

  // And its worker starts at once, as it did before templates.
  want_worker(handle, "a")
  assert saw(seen, Started("project:p1:t-a:1"), 10_000)
  stop(handle)
}

pub fn a_failed_rebuild_keeps_the_last_good_template_and_workers_still_start_test() {
  let path = directory("rebuild-fails")
  let holder = hold(Script(answer: built("abc1234abc12"), gate: Open))
  let seen = process.new_subject()
  let handle = start(quiet_config(path, seen, holder))
  assert eventually(fn() { sources(handle) }, "\"ready\"")

  // The next build fails. The template that is in use stays, the board shows
  // a note about the rebuild, and a new ticket still gets a worker.
  process.send(
    holder,
    Set(Script(
      answer: failing(project_template.Setup, "exit status 1\nnetwork down"),
      gate: Open,
    )),
  )
  let assert Ok(Nil) = project_host.retry(handle, "setup", "owner")
  assert eventually(fn() { sources(handle) }, "rebuild")
  let board = sources(handle)
  assert string.contains(board, "\"state\":\"ready\"")
  assert string.contains(board, "abc1234abc12")
  assert string.contains(board, "network down")
  want_worker(handle, "b")
  assert saw(seen, Started("project:p1:t-b:1"), 10_000)
  stop(handle)
}

pub fn a_crash_during_preparation_redoes_it_and_no_worker_starts_early_test() {
  let path = directory("crash")
  let holder = hold(Script(answer: built("abc1234abc12"), gate: Closed))
  let seen = process.new_subject()
  let handle = start(quiet_config(path, seen, holder))
  assert saw(seen, Built(None), 5000)
  want_worker(handle, "a")

  // The actor dies with the build half done, and nothing started.
  stop(handle)
  assert quiet(seen)

  // A new actor over the same ledger finds the ticket queued and the build
  // row still there, and does the build again from the top.
  process.send(holder, Set(Script(answer: built("abc1234abc12"), gate: Open)))
  let again = start(quiet_config(path, seen, holder))
  assert saw(seen, Built(None), 10_000)
  assert saw(seen, Started("project:p1:t-a:1"), 10_000)
  assert eventually(fn() { sources(again) }, "\"ready\"")
  stop(again)
}

pub fn a_ready_template_is_remembered_across_a_restart_and_not_rebuilt_test() {
  let path = directory("restart")
  let holder = hold(Script(answer: built("abc1234abc12"), gate: Open))
  let seen = process.new_subject()
  let first = start(quiet_config(path, seen, holder))
  assert eventually(fn() { sources(first) }, "\"ready\"")
  stop(first)

  // The restart replays the record: the template is ready at once, so a worker
  // is not kept waiting for a build that finds nothing to do. The look at the
  // base that follows is told the commit it may skip.
  process.send(
    holder,
    Set(Script(
      answer: fn(request) {
        case request.current {
          Some(commit) -> project_template.Unchanged(commit)
          None -> project_template.Built("abc1234abc12")
        }
      },
      gate: Open,
    )),
  )
  let second = start(quiet_config(path, seen, holder))
  assert string.contains(sources(second), "\"ready\"")
  want_worker(second, "a")
  assert saw(seen, Started("project:p1:t-a:1"), 10_000)
  stop(second)
}

pub fn a_base_that_moves_is_rebuilt_at_the_next_look_test() {
  let path = directory("moves")
  let holder = hold(Script(answer: built("aaaaaaa11111"), gate: Open))
  let seen = process.new_subject()

  // A clock that jumps a hundred seconds a read, so the ten minutes between
  // looks pass in a few ticks.
  let handle =
    start(config(path, seen, holder, 20, project_ports.racing_clock(), policy()))
  assert eventually(fn() { sources(handle) }, "aaaaaaa11111")
  process.send(
    holder,
    Set(Script(
      answer: fn(request) {
        case request.current {
          Some("aaaaaaa11111") -> project_template.Built("bbbbbbb22222")
          Some(commit) -> project_template.Unchanged(commit)
          None -> project_template.Built("bbbbbbb22222")
        }
      },
      gate: Open,
    )),
  )

  // The next look found the base at a new commit and rebuilt, being told the
  // commit the template stood at.
  assert saw(seen, Built(Some("aaaaaaa11111")), 20_000)
  assert eventually(fn() { sources(handle) }, "bbbbbbb22222")
  stop(handle)
}
