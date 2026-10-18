//// Remote subagents two levels deep against the shipped daemon: a laptop, a box
//// and a third orchestrator, three real `bin/loomd` processes that trust each
//// other over TLS distribution (protocol-change/084, phase 4, slice S13).
////
//// The deployment is provisioned as `daemon_shipped_remote_subagents_test`'s
//// is, with a third orchestrator in the plan. The fixture adds the tables the
//// bundles do not carry. On the box, `[spawners.laptop]` allows a depth of two
//// and lists `third` in `spawn_on`. On the third orchestrator, `[spawners.box]`
//// lets the box's node start children there. Every orchestrator's rows for the
//// other two come from the ledger.
////
//// Each daemon's model is a scripted HTTP peer on loopback. The laptop's script
//// is the parent, the box's is the child, and the third's is the grandchild.
////
//// ## What it proves
////
//// `daemon_shipped_remote_depth_test_`, one laptop session in one turn.
////
//// - The laptop's parent starts a child `on` the box. The child holds
////   `agent_spawn`, because the spawner's depth allows it and the default
////   ceiling then holds the tool, and it starts a grandchild `on` the third
////   orchestrator. The grandchild runs there and writes a heartbeat.
//// - The child also runs until it is stopped. The laptop session is then stopped
////   and deleted with both running. The laptop's release drainer tells the box,
////   the box stops the child and owes the third orchestrator a release for its
////   delegate session, and the box's own release drainer tells the third
////   orchestrator, which stops the grandchild: its abort is logged, its heartbeat
////   goes quiet, and the third orchestrator's delegate session for the box is
////   deleted.
////
//// ## What it does not prove
////
//// The depth refusals, the narrowing to `spawn_on` and the deadline clamp are
//// unit tests (`agency_test`, `spawners_test`); here every request is within
//// the limits. A release that is lost or repeated on either hop is checked by
//// the P model (`tcDepth`).
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_depth_test:'
//// ```
////
//// Without the shipment, or on a host whose helper cannot enforce a policy, the
//// fixture declines under its label as the other shipped fixtures do.

import client/tui_e2e_test.{type EunitTest}
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import simplifile
import support/ledger_deployment
import support/provider_http as provider
import support/remote_daemons
import support/remote_duo.{type Duo}
import support/remote_pair
import weft/poll

const skip_label = "shipped remote depth"

const spawn_prompt = "start a child on the box that starts its own"

const spawned_answer = "the child is started"

// The child runs until it is stopped, and so does the grandchild. Each writes a
// heartbeat in its own delegate workspace.
const child_shell = "while true; do echo x >> beat-child; sleep 1; done"

const grandchild_shell = "while true; do echo x >> beat-grand; sleep 1; done"

// How long a heartbeat may take to start, to stop, or to be seen growing.
const settle_ms = 60_000

// The opening of a framed brief, which every child's first message begins with.
const brief_head = "[task brief from "

/// Starts a laptop, a box and a third orchestrator from the shipment, has a
/// laptop session start a child on the box that starts a grandchild on the
/// third, and checks that deleting the laptop session stops both.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_depth_test:'`.
pub fn daemon_shipped_remote_depth_test_() -> EunitTest {
  remote_duo.shipped(skip_label, drive)
}

fn drive(duo: Duo) -> Nil {
  let box_work = duo.directory <> "/box-work"
  let third_work = duo.directory <> "/third-work"
  let assert Ok(Nil) = simplifile.create_directory_all(box_work)
    as "the box's delegate workspace is created"
  let assert Ok(Nil) = simplifile.create_directory_all(third_work)
    as "the third orchestrator's delegate workspace is created"
  let #(Nil, third_report) =
    provider.with_server_for(
      third_script(),
      provider.OnlySuccessful,
      900_000,
      fn(third_url) {
        let #(Nil, box_report) =
          provider.with_server_for(
            box_script(),
            provider.OnlySuccessful,
            900_000,
            fn(box_url) {
              let #(Nil, laptop_report) =
                provider.with_server_for(
                  laptop_script(),
                  provider.OnlySuccessful,
                  900_000,
                  fn(laptop_url) {
                    session(
                      duo,
                      Urls(laptop: laptop_url, box: box_url, third: third_url),
                      box_work,
                      third_work,
                    )
                  },
                )
              let assert Ok(_) = laptop_report
                as "the laptop's model saw exactly its script"
              Nil
            },
          )
        let assert Ok(seen) = box_report
          as "the box's model saw exactly its script"

        // The child was told its grandchild started on the third orchestrator.
        let started = remote_daemons.result_text(seen, "spawn-grand")
        assert string.contains(started, "Handle: ")
        Nil
      },
    )
  let assert Ok(_) = third_report
    as "the third orchestrator's model saw exactly its script"
  Nil
}

// The model URLs of the three daemons.
type Urls {
  Urls(laptop: String, box: String, third: String)
}

// --- the deployment ----------------------------------------------------------

// Provisions a three-orchestrator ledger deployment, installs each bundle, and
// adds the tables the bundles do not carry: the models, and the spawner tables
// that let the laptop start children on the box and the box on the third.
fn deploy(duo: Duo, urls: Urls, box_work: String, third_work: String) -> Nil {
  let suffix = remote_daemons.random_hex(4)
  let laptop_node = "loom_s13_laptop_" <> suffix <> "@127.0.0.1"
  let box_node = "loom_s13_box_" <> suffix <> "@127.0.0.1"
  let third_node = "loom_s13_third_" <> suffix <> "@127.0.0.1"
  let deployed =
    ledger_deployment.provision(
      "depth",
      plan([
        #("laptop", laptop_node),
        #("box", box_node),
        #("third", third_node),
      ]),
    )
  install(deployed, "laptop", duo.alpha)
  install(deployed, "box", duo.bravo)
  install(deployed, "third", duo.executor)
  append(duo.alpha, remote_pair.models_without_glance(urls.laptop))
  append(
    duo.bravo,
    string.join(
      [
        remote_pair.models_without_glance(urls.box),
        "[profiles.kid.roles]",
        "main = [\"fixture\"]",
        "",
        "[spawners.laptop]",
        "node = \"" <> laptop_node <> "\"",
        "directory = \"" <> box_work <> "\"",
        "profile = \"kid\"",
        "max_depth = 2",
        "spawn_on = [\"third\"]",
        "max_within_s = 600",
        "default_within_s = 300",
        "retain_s = 3600",
        "",
      ],
      "\n",
    ),
  )
  append(
    duo.executor,
    string.join(
      [
        remote_pair.models_without_glance(urls.third),
        "[profiles.kid.roles]",
        "main = [\"fixture\"]",
        "",
        "[spawners.box]",
        "node = \"" <> box_node <> "\"",
        "directory = \"" <> third_work <> "\"",
        "profile = \"kid\"",
        "max_depth = 2",
        "max_within_s = 600",
        "default_within_s = 300",
        "retain_s = 3600",
        "",
      ],
      "\n",
    ),
  )
  remote_daemons.write_options(duo.alpha)
  remote_daemons.write_options(duo.bravo)
  remote_daemons.write_options(duo.executor)
}

fn plan(nodes: List(#(String, String))) -> String {
  nodes
  |> list.map(fn(pair) {
    string.join(
      [
        "[[node]]",
        "name = \"" <> pair.0 <> "\"",
        "role = \"orchestrator\"",
        "erlang_node = \"" <> pair.1 <> "\"",
        "",
      ],
      "\n",
    )
  })
  |> string.join("\n")
}

fn install(
  deployed: ledger_deployment.Deployed,
  name: String,
  layout: remote_daemons.Layout,
) -> Nil {
  let assert Ok(_) =
    ledger_deployment.run([
      "install",
      deployed.out <> "/" <> name <> ".loombundle",
      "--home",
      layout.home,
      "--config",
      layout.config,
    ])
    as "the bundle installs into the daemon's configuration"
  Nil
}

// The installed configuration plus the tables the fixture owns.
fn append(layout: remote_daemons.Layout, tables: String) -> Nil {
  let assert Ok(installed) = simplifile.read(layout.config)
    as "the installed configuration is readable"
  let assert Ok(Nil) =
    simplifile.write(layout.config, installed <> "\n" <> tables)
    as "the fixture's tables are appended"
  Nil
}

// --- the scripts -------------------------------------------------------------

// The parent model starts one child on the box and ends its turn.
fn laptop_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      spawn_prompt,
      "spawn-child",
      "agent_spawn",
      spawn(
        "start a grandchild on third, then run your shell",
        "box child",
        "box",
      ),
    ),
    provider.ComputedExchange(
      provider.AwaitToolResult("spawn-child"),
      fn(_seen) { provider.ReplyText(spawned_answer) },
    ),
  ]
}

// The child on the box starts a grandchild on the third orchestrator, then runs
// a shell that does not end.
fn box_script() -> List(provider.Exchange) {
  [
    provider.ComputedExchange(provider.AwaitPromptPrefix(brief_head), fn(_seen) {
      provider.ReplyToolUse(
        "spawn-grand",
        "agent_spawn",
        spawn("run the grandchild's shell", "grand child", "third"),
      )
    }),
    provider.ComputedExchange(
      provider.AwaitToolResult("spawn-grand"),
      fn(_seen) {
        provider.ReplyToolUse("shell-child", "bash", shell(child_shell))
      },
    ),
  ]
}

// The grandchild on the third orchestrator runs a shell that does not end.
fn third_script() -> List(provider.Exchange) {
  [
    provider.ComputedExchange(provider.AwaitPromptPrefix(brief_head), fn(_seen) {
      provider.ReplyToolUse("shell-grand", "bash", shell(grandchild_shell))
    }),
  ]
}

fn spawn(brief: String, purpose: String, on: String) -> json.JsonValue {
  json.Object([
    #("purpose", json.String(purpose)),
    #("brief", json.String(brief)),
    #("on", json.String(on)),
  ])
}

fn shell(command: String) -> json.JsonValue {
  json.Object([#("command", json.String(command))])
}

// --- the session -------------------------------------------------------------

fn session(duo: Duo, urls: Urls, box_work: String, third_work: String) -> Nil {
  deploy(duo, urls, box_work, third_work)
  let environment = [#("LOOM_TEST_PROVIDER_KEY", provider.dummy_key)]
  let third =
    remote_daemons.start_with_environment(duo.executor, [], environment)
  let box = remote_daemons.start_with_environment(duo.bravo, [], environment)
  let laptop = remote_daemons.start_with_environment(duo.alpha, [], environment)
  let control = remote_daemons.open_control(laptop)
  let #(session, settled) =
    remote_daemons.create_local_and_settle(
      control,
      1,
      "depth",
      duo.alpha.workspace,
    )
  assert remote_daemons.settled_state(settled) == "resident"
  let terminal = remote_daemons.attach(laptop, session)

  // One turn starts the child on the box. The child starts the grandchild on
  // the third orchestrator, and both heartbeats grow.
  remote_daemons.say(terminal, spawn_prompt)
  remote_daemons.await_answers(terminal, [spawned_answer], settle_ms)
  let _child = await_lines(box_work <> "/beat-child", 2)
  let _grandchild = await_lines(third_work <> "/beat-grand", 2)
  let box_control = remote_daemons.open_control(box)
  let third_control = remote_daemons.open_control(third)
  assert delegate_sessions(box_control, 70, session) != []
  assert delegate_sessions(third_control, 80, "delegate box ") != []

  // The owner deletes the laptop session with both running. The release reaches
  // the box, whose own release rows reach the third orchestrator.
  remote_daemons.stop_session(laptop, control, 60, session)
  let deleted =
    remote_daemons.command(
      control,
      61,
      "sessions.delete",
      json.Object([
        #("session_id", json.String(session)),
        #("epoch", json.String(control.epoch)),
      ]),
    )
  assert remote_daemons.field(deleted, "event")
    == json.String("sessions.delete")
  await_log(duo.bravo, ["operation.aborted", "box-child"])
  let _quiet = await_quiet(box_work <> "/beat-child")
  await_no_delegate_session(box_control, 71, session)
  await_log(duo.executor, ["operation.aborted", "grand-child"])
  let _quiet = await_quiet(third_work <> "/beat-grand")
  await_no_delegate_session(third_control, 81, "delegate box ")
  Nil
}

// The names of a daemon's sessions whose name holds `fragment`. The registry
// names a delegate session after its spawner and its parent.
fn delegate_sessions(
  control: remote_daemons.Control,
  id: Int,
  fragment: String,
) -> List(String) {
  let listed =
    remote_daemons.command(
      control,
      id,
      "sessions.list",
      json.Object([#("after", json.String(""))]),
    )
  let assert json.Array(sessions) =
    remote_daemons.field(remote_daemons.field(listed, "body"), "sessions")
    as "the daemon lists its sessions"
  sessions
  |> list.filter_map(fn(record) {
    case remote_daemons.field(record, "name") {
      json.String(name) ->
        case string.contains(name, fragment) {
          True -> Ok(name)
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

// Waits until the daemon no longer lists a session whose name holds `fragment`.
fn await_no_delegate_session(
  control: remote_daemons.Control,
  id: Int,
  fragment: String,
) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: settle_ms, every: 500, attempt: fn() {
      case delegate_sessions(control, id, fragment) {
        [] -> poll.Done(Nil)
        [_, ..] -> poll.Retry
      }
    })
    as { "the delegate session for " <> fragment <> " was deleted" }
  Nil
}

// Waits until the file has at least `lines` lines and returns the count.
fn await_lines(path: String, lines: Int) -> Int {
  let assert poll.Answered(count) =
    poll.until(within: settle_ms, every: 500, attempt: fn() {
      case line_count(path) >= lines {
        True -> poll.Done(line_count(path))
        False -> poll.Retry
      }
    })
    as { path <> " reached " <> int.to_string(lines) <> " lines" }
  count
}

// Waits until the file stops growing: two counts, three seconds apart, agree.
// A heartbeat ticking once a second cannot hold still for that long.
fn await_quiet(path: String) -> Int {
  let assert poll.Answered(count) =
    poll.until(within: settle_ms, every: 500, attempt: fn() {
      let before = line_count(path)
      process.sleep(3000)
      case line_count(path) == before {
        True -> poll.Done(before)
        False -> poll.Retry
      }
    })
    as { path <> " stopped growing after the abort" }
  count
}

// Waits until a line of the daemon's log holds every one of `needles`.
fn await_log(layout: remote_daemons.Layout, needles: List(String)) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: settle_ms, every: 500, attempt: fn() {
      case simplifile.read(layout.paths.log) {
        Ok(text) ->
          case list.any(string.split(text, "\n"), holds_all(_, needles)) {
            True -> poll.Done(Nil)
            False -> poll.Retry
          }
        Error(_) -> poll.Retry
      }
    })
    as { "the daemon logged " <> string.join(needles, " ") }
  Nil
}

fn holds_all(line: String, needles: List(String)) -> Bool {
  list.all(needles, string.contains(line, _))
}

fn line_count(path: String) -> Int {
  case simplifile.read(path) {
    Ok(text) ->
      text
      |> string.split("\n")
      |> list.filter(fn(line) { line != "" })
      |> list.length
    Error(_) -> 0
  }
}
