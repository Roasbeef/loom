//// A session moves from one orchestrator to another, against the shipped daemon
//// (issue #697, protocol-change/078, phase 5): three real `bin/loomd` processes,
//// two orchestrators and one executor, that trust each other over TLS
//// distribution.
////
//// `alpha` and `bravo` each list the other under `[orchestrators.<name>]` and
//// the executor under `[executors.box]`, and the executor registers the checkout
//// `repo` and trusts both. A session is created on `alpha`, takes a turn that
//// writes a file and starts a background job on the executor, and is then handed
//// to `bravo` with `sessions.move`. The model is a scripted Anthropic peer on
//// loopback, shared by both orchestrators.
////
//// ## What it proves
////
//// `daemon_shipped_remote_move_test_`, one move with nothing going wrong.
////
//// - The reply names the move. `sessions.get` on `alpha` reports `moving` and
////   then `moved`, naming `bravo`, and `alpha` refuses to open the session with
////   `not_owner` naming `bravo`.
//// - `alpha`'s file is set aside as `<id>.db.moved` and its original is gone.
////   `bravo` holds the session, saved, and no other file of it.
//// - The executor's scope for the session was closed `all_retired` at
////   incarnation one before the copy was cut, and the background job's process
////   is gone, so the file it appended to stops growing.
//// - `bravo` opens the session, the executor attaches it at incarnation two, a
////   `bash` call there reads the file the first incarnation wrote, and a stop
////   closes incarnation two the same way.
////
//// `daemon_shipped_remote_move_crash_test_`, the source lost at each step.
////
//// - `LOOM_MOVE_CRASH_AFTER=<step>` halts `alpha`'s VM the moment the named step
////   of the move is durable: `intent`, `close`, `cut`, `send`, `activate` and
////   `retire`. The variable is test-only and no operator sets it.
//// - `alpha` is started again with no variable set and finishes the move on its
////   own, from the `moving` row it finds. Nobody asks it to.
//// - Every session then ends in the same place as the first test: `bravo` opens
////   it at incarnation two and a tool runs there, `alpha` answers `not_owner`,
////   and the executor holds one scope for it.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// export LOOM_TEST_PROVIDER_KEY=loom-provider-fixture-key
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_move_test:'
//// ```
////
//// Without the variable the tests print a skip line and pass. They need
//// `openssl`, `erl` and `epmd` on `PATH`, the sandbox helper beside the launcher,
//// and permission to listen on loopback. The directory is under `/var/tmp` and
//// short, because a daemon binds unix sockets below its state root and the jail
//// replaces `/tmp`. The coordinator retires every daemon by its recorded
//// identity outside the bounded body, so a failed assertion leaves none behind.

import broker/token
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as native
import simplifile
import storage/exec_ledger
import support/enforcement
import support/provider_http as provider
import support/remote_daemons.{type Control, type Layout, type Running, Trust}
import support/tui_driver
import tui/daemon
import weft

const skip_label = "shipped remote move"

// The executor's name for its checkout, and the name a session uses for it.
const workspace_name = "repo"

// The orchestrators' name for the executor, an `[executors.<name>]` key.
const executor_name = "box"

// The orchestrators' names for each other, `[orchestrators.<name>]` keys.
const source_name = "alpha"

const target_name = "bravo"

// How long a terminal waits for a turn to end, and how many half-second polls
// a move gets to finish. A move closes a scope, cuts and sends a file and
// activates a session, and a crashed source starts again before it can.
const turn_ms = 120_000

const move_polls = 240

/// One move with nothing going wrong, start to finish.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_move_test:'`.
pub fn daemon_shipped_remote_move_test_() -> EunitTest {
  shipped(60, 540_000, one_clean_move)
}

/// The source halted after each of the six steps and started again.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_move_test:'`.
pub fn daemon_shipped_remote_move_crash_test_() -> EunitTest {
  shipped(150, 1_380_000, every_step_lost)
}

// --- the fixture -----------------------------------------------------------------

type Trio {
  Trio(
    directory: String,
    source: Layout,
    target: Layout,
    executor: Layout,
    checkout: String,
  )
}

type Keys {
  Keys(
    authority: remote_daemons.Authority,
    source: remote_daemons.Identity,
    target: remote_daemons.Identity,
    executor: remote_daemons.Identity,
  )
}

// Gates the test on the host and runs `body` against a fresh trio. The EUnit
// timeout is `seconds`, which the runner scales by ten, and the body's own
// deadline is `body_ms`, so a hung body fails with a message and not at the
// runner's limit.
fn shipped(seconds: Int, body_ms: Int, body: fn(Trio) -> Nil) -> EunitTest {
  Timeout(seconds, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP " <> skip_label <> ": LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) ->
        case enforcement.probe(server, skip_label) {
          enforcement.EnforcementAbsent -> Nil
          enforcement.EnforcementLive -> fixture(body_ms, body)
        }
    }
  })
}

fn fixture(body_ms: Int, body: fn(Trio) -> Nil) -> Nil {
  let directory =
    "/var/tmp/loom-mv-"
    <> string.lowercase(bit_array.base16_encode(token.production_entropy()(4)))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the fixture's state stays private"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemons receive absolute paths"
  let prepared =
    Trio(
      directory:,
      source: remote_daemons.layout(directory, "alpha"),
      target: remote_daemons.layout(directory, "bravo"),
      executor: remote_daemons.layout(directory, "executor"),
      checkout: directory <> "/executor-checkout",
    )
  io.println_error(skip_label <> " fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        body(prepared)
        Ok(Nil)
      },
    ])
    |> weft.deadline(body_ms)
    |> weft.start

  // Native cleanup runs outside the body's deadline and before the outcome is
  // read, so a body that failed mid-drive still retires every daemon. A daemon
  // that already halted has no process left to retire, which `retire` accepts.
  list.each([prepared.source, prepared.target, prepared.executor], fn(l) {
    remote_daemons.retire(l.paths)
  })
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped move body completes before native teardown"
  let _removed = simplifile.delete_all([prepared.directory])
  Nil
}

fn provision(prepared: Trio) -> Keys {
  let secrets = prepared.directory <> "/credentials"
  let assert Ok(Nil) = native.ensure_private_directory(secrets)
    as "the credentials directory is private"
  let authority = remote_daemons.mint_authority(secrets)
  let suffix = remote_daemons.random_hex(4)
  let name = fn(role) { "loom_e2e_" <> role <> "_" <> suffix <> "@127.0.0.1" }
  let keys =
    Keys(
      authority:,
      source: remote_daemons.issue(
        authority,
        secrets,
        "alpha",
        name("alpha"),
        prepared.source.home,
      ),
      target: remote_daemons.issue(
        authority,
        secrets,
        "bravo",
        name("bravo"),
        prepared.target.home,
      ),
      executor: remote_daemons.issue(
        authority,
        secrets,
        "executor",
        name("exec"),
        prepared.executor.home,
      ),
    )
  let cookie = "loom-e2e-cookie-" <> remote_daemons.random_hex(16)
  list.each([keys.source, keys.target, keys.executor], fn(identity) {
    remote_daemons.write_cookie(identity, cookie)
  })
  keys
}

// Each orchestrator lists the other and the executor, and the executor trusts
// both. Both orchestrators' models are the scripted provider at `url`.
fn configure(prepared: Trio, keys: Keys, url: String) -> Nil {
  let table = fn(identity, peers) {
    remote_daemons.distribution_table(identity, keys.authority, peers)
  }
  let trust = fn(identity: remote_daemons.Identity) {
    Trust(identity.node, identity.pin)
  }
  let write = fn(layout: Layout, text) {
    let assert Ok(Nil) = simplifile.write(layout.config, text)
      as "the daemon configuration is written"
    remote_daemons.write_options(layout)
  }
  write(
    prepared.executor,
    string.join(
      [
        remote_daemons.model_table("http://127.0.0.1:9"),
        table(keys.executor, [trust(keys.source), trust(keys.target)]),
        remote_daemons.workspace_table(workspace_name, prepared.checkout),
      ],
      "\n",
    ),
  )
  write(
    prepared.source,
    string.join(
      [
        remote_daemons.model_table(url),
        table(keys.source, [trust(keys.target), trust(keys.executor)]),
        remote_daemons.executor_table(executor_name, keys.executor.node),
        remote_daemons.orchestrator_table(target_name, keys.target.node, None),
      ],
      "\n",
    ),
  )
  write(
    prepared.target,
    string.join(
      [
        remote_daemons.model_table(url),
        table(keys.target, [trust(keys.source), trust(keys.executor)]),
        remote_daemons.executor_table(executor_name, keys.executor.node),
        remote_daemons.orchestrator_table(
          source_name,
          keys.source.node,
          Some("wss://alpha.example.test:8443/v2/control"),
        ),
      ],
      "\n",
    ),
  )
}

fn make_checkout(prepared: Trio) -> Nil {
  let assert Ok(Nil) = simplifile.create_directory_all(prepared.checkout)
    as "the executor checkout is created"
  Nil
}

// --- the scripted model --------------------------------------------------------

// The note a session writes, and the file a background job appends to, both
// named for the session's label so the sessions of one fixture do not meet.
fn note(label: String) -> String {
  "note-" <> label <> ".txt"
}

fn note_text(label: String) -> String {
  "written before the move of " <> label <> "\n"
}

fn beat(label: String) -> String {
  "beat-" <> label <> ".log"
}

fn write_prompt(label: String) -> String {
  "write the note " <> label
}

fn read_prompt(label: String) -> String {
  "read the note " <> label
}

fn started(label: String) -> String {
  "started " <> label
}

fn finished(label: String) -> String {
  "moved " <> label <> " done"
}

// The first turn writes the note and starts a job that appends to a file every
// fifth of a second until it is stopped, then answers. The second, after the
// move and on the other orchestrator, reads the note back through `bash`.
fn script(label: String) -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      write_prompt(label),
      "write-" <> label,
      "fs_write",
      json.Object([
        #("path", json.String(note(label))),
        #("content", json.String(note_text(label))),
      ]),
    ),
    provider.ComputedExchange(
      provider.AwaitToolResult("write-" <> label),
      fn(_seen) {
        provider.ReplyToolUse(
          "beat-" <> label,
          "bash",
          json.Object([
            #(
              "command",
              json.String(
                "while true; do echo tick >> "
                <> beat(label)
                <> "; sleep 0.2; done",
              ),
            ),
            #("mode", json.String("background")),
          ]),
        )
      },
    ),
    provider.ComputedExchange(
      provider.AwaitToolResult("beat-" <> label),
      fn(_seen) { provider.ReplyText(started(label)) },
    ),
    provider.ToolUseExchange(
      read_prompt(label),
      "read-" <> label,
      "bash",
      json.Object([#("command", json.String("cat -- " <> note(label)))]),
    ),
    provider.ComputedExchange(
      provider.AwaitToolResult("read-" <> label),
      fn(_seen) { provider.ReplyText(finished(label)) },
    ),
  ]
}

// --- what a session does on each side --------------------------------------------

// Creates a session on `source`, runs the first turn, and waits until the
// background job is writing on the executor. Returns the session.
fn begun(
  prepared: Trio,
  source: Running,
  control: Control,
  label: String,
) -> String {
  let #(session, settled) =
    remote_daemons.create_and_settle(
      control,
      1,
      "e2e-" <> label,
      executor_name,
      workspace_name,
    )
  assert remote_daemons.settled_state(settled) == "resident"
  let terminal = remote_daemons.attach(source, session)
  remote_daemons.say(terminal, write_prompt(label))
  remote_daemons.await_answers(terminal, [started(label)], turn_ms)
  tui_driver.stop(terminal)
  await_lines(prepared.checkout <> "/" <> beat(label), 3)
  session
}

// Opens the moved session on `target`, runs the second turn there, and checks
// what the executor kept: the incarnation the session attached at, and how the
// scope ended once it was stopped.
fn continued(
  prepared: Trio,
  target: Running,
  control: Control,
  label: String,
  session: String,
  ids: Int,
) -> Nil {
  // The session is the target's, saved, and the orchestrator that gave it up is
  // the one it names as its origin.
  let record = remote_daemons.session_record(control, ids + 1, session)
  assert remote_daemons.field(record, "session_id") == json.String(session)
  assert remote_daemons.field(record, "name")
    == json.String("registered e2e-" <> label)

  // Closed at incarnation one before the copy was cut, and nothing since.
  let before = executor_scope(prepared, session)
  assert before.incarnation == 1
  assert before.state == exec_ledger.Closed(exec_ledger.AllRetired)
  assert before.workspace == workspace_name

  let settled = remote_daemons.reopen_session(control, ids + 10, session)
  assert remote_daemons.settled_state(settled) == "resident"
  let terminal = remote_daemons.attach(target, session)
  remote_daemons.say(terminal, read_prompt(label))
  remote_daemons.await_answers(
    terminal,
    [started(label), finished(label)],
    turn_ms,
  )
  tui_driver.stop(terminal)

  // The target attached at the next incarnation, and its scope is open.
  let during = executor_scope(prepared, session)
  assert during.incarnation == 2
  assert during.state == exec_ledger.Open

  remote_daemons.stop_session(target, control, ids + 2500, session)
  let after = executor_scope(prepared, session)
  assert after.incarnation == 2
  assert after.state == exec_ledger.Closed(exec_ledger.AllRetired)
}

fn executor_scope(prepared: Trio, session: String) -> exec_ledger.Scope {
  remote_daemons.executor_scope(
    prepared.executor,
    prepared.directory <> "/ledger-copies",
    session,
  )
}

// What the source is left with once the move ended: a tombstone that names the
// new owner, no file under the session's name and one set aside, and a refusal
// to open.
fn gave_up(source: Running, control: Control, session: String) -> Nil {
  let moved = remote_daemons.await_moved(control, 500, session, move_polls)
  assert moved == json.Object([#("to", json.String(target_name))])

  let sessions = source.layout.paths.root <> "/sessions/" <> session <> ".db"
  assert simplifile.is_file(sessions) == Ok(False)
  assert simplifile.is_file(sessions <> ".moved") == Ok(True)

  // A forced open is refused by the tombstone and names the new owner, with
  // the address the source's own configuration holds for it. Nothing is asked
  // of the other orchestrator, and no session is opened.
  let refused =
    remote_daemons.command(
      control,
      1000,
      "sessions.open",
      json.Object([
        #("session_id", json.String(session)),
        #("epoch", json.String(control.epoch)),
      ]),
    )
  assert remote_daemons.field(refused, "event") == json.String("error")
  let body = remote_daemons.field(refused, "body")
  assert remote_daemons.field(body, "code") == json.String("not_owner")
  assert remote_daemons.field(body, "orchestrator") == json.String(target_name)
}

// The target holds the session as its own: the file is under its sessions
// directory, and the source has not kept a copy under that name.
fn took(target: Running, session: String) -> Nil {
  let held = target.layout.paths.root <> "/sessions/" <> session <> ".db"
  assert simplifile.is_file(held) == Ok(True)
}

// --- one clean move -----------------------------------------------------------------

fn one_clean_move(prepared: Trio) -> Nil {
  let keys = provision(prepared)
  make_checkout(prepared)
  let label = "clean"
  let #(Nil, report) =
    provider.with_server(script(label), fn(url) {
      configure(prepared, keys, url)

      // The executor starts first so the daemons which dial it find it up.
      let _executor = remote_daemons.start(prepared.executor)
      let source = remote_daemons.start(prepared.source)
      let target = remote_daemons.start(prepared.target)
      let control = remote_daemons.open_control(source)
      let session = begun(prepared, source, control, label)

      // The move is accepted and named, and the daemon carries it out.
      let accepted =
        remote_daemons.begin_move(control, 400, session, target_name, 30_000)
      let assert Some(reply) = accepted as "the daemon answers the move"
      assert remote_daemons.field(reply, "event")
        == json.String("sessions.move")
      let body = remote_daemons.field(reply, "body")
      assert remote_daemons.field(body, "to") == json.String(target_name)
      assert remote_daemons.field(body, "state") == json.String("moving")
      let assert json.String(_op) = remote_daemons.field(body, "op")
        as "the reply names the move"
      gave_up(source, control, session)
      took(target, session)

      // The background job's process was ended with the scope. Its file stops
      // growing, since a job that outlived the close would add a line every
      // fifth of a second.
      assert_beat_stopped(prepared.checkout <> "/" <> beat(label))
      let target_control = remote_daemons.open_control(target)
      continued(prepared, target, target_control, label, session, 0)
      list.each([source, target], fn(running) {
        daemon.close(running.connected.control)
      })
    })
  let assert Ok(requests) = report
    as "the provider saw exactly the scripted conversation"
  assert string.contains(
    remote_daemons.result_text(requests, "read-" <> label),
    string.trim(note_text(label)),
  )
}

// --- the source lost at each step ------------------------------------------------------

fn every_step_lost(prepared: Trio) -> Nil {
  let keys = provision(prepared)
  make_checkout(prepared)
  let steps = ["intent", "close", "cut", "send", "activate", "retire"]

  // The scripted provider takes a short script, so each step has a provider of
  // its own, and the orchestrators are started against its address. The
  // executor outlives them all, which is what a deployment looks like: the
  // orchestrators come and go around the machine that holds the scopes.
  configure(prepared, keys, "http://127.0.0.1:9")
  let _executor = remote_daemons.start(prepared.executor)
  list.index_map(steps, fn(step, index) {
    let #(Nil, report) =
      provider.with_server(script(step), fn(url) {
        configure(prepared, keys, url)
        let target = remote_daemons.start(prepared.target)
        let target_control = remote_daemons.open_control(target)
        lost_after(prepared, target, target_control, step, index * 5000)
        daemon.close(target.connected.control)
        remote_daemons.retire(prepared.target.paths)
      })
    let assert Ok(requests) = report
      as "the provider saw exactly the scripted conversation"
    assert string.contains(
      remote_daemons.result_text(requests, "read-" <> step),
      string.trim(note_text(step)),
    )
  })
  Nil
}

// One session: begun on a source that will halt after `step`, moved, and finished
// by a source that starts again with nothing set. The session ends on the target
// at the next incarnation.
fn lost_after(
  prepared: Trio,
  target: Running,
  target_control: Control,
  step: String,
  ids: Int,
) -> Nil {
  io.println_error(skip_label <> ": halting the source after " <> step)
  let halting =
    remote_daemons.start_with_environment(prepared.source, [], [
      #("LOOM_MOVE_CRASH_AFTER", step),
    ])
  let control = remote_daemons.open_control(halting)
  let session = begun(prepared, halting, control, step)

  // The source halts itself the moment the step is durable. For the first step
  // that can be before the reply is written, so the reply is not required.
  let _reply =
    remote_daemons.begin_move(control, 400, session, target_name, 15_000)
  remote_daemons.await_departure(prepared.source)
  daemon.close(halting.connected.control)

  // Nothing was lost: the session has one owner, and it is the source, which
  // is gone. The target has not been handed anything it could serve yet, except
  // for the steps after the activation.
  let restarted = remote_daemons.start(prepared.source)
  let restarted_control = remote_daemons.open_control(restarted)
  gave_up(restarted, restarted_control, session)
  took(target, session)
  assert_beat_stopped(prepared.checkout <> "/" <> beat(step))
  continued(prepared, target, target_control, step, session, ids)
  daemon.close(restarted.connected.control)

  // The next step starts a source with its own variable, so this one is retired.
  remote_daemons.retire(prepared.source.paths)
}

// --- the job ---------------------------------------------------------------------------

fn await_lines(path: String, count: Int) -> Nil {
  let assert Ok(Nil) = wait_for_lines(path, count, 600)
    as { path <> " grows while its job runs" }
  Nil
}

fn wait_for_lines(path: String, count: Int, polls: Int) -> Result(Nil, Nil) {
  case line_count(path) >= count, polls {
    True, _ -> Ok(Nil)
    False, 0 -> Error(Nil)
    False, _ -> {
      process.sleep(50)
      wait_for_lines(path, count, polls - 1)
    }
  }
}

fn line_count(path: String) -> Int {
  case simplifile.read(path) {
    Ok(text) -> list.length(string.split(text, "\n")) - 1
    Error(_) -> 0
  }
}

// A job that outlived its scope would add a line every fifth of a second, so a
// quiet second is five missed lines.
fn assert_beat_stopped(path: String) -> Nil {
  let before = line_count(path)
  process.sleep(1000)
  assert line_count(path) == before
}
