//// Remote subagents against the shipped daemon: a laptop orchestrator and a box
//// orchestrator, two real `bin/loomd` processes that trust each other over TLS
//// distribution, and a laptop session whose model starts children on the box
//// (protocol-change/084, slice S5).
////
//// The deployment is provisioned the way an operator provisions one. A plan
//// names two orchestrators, `loom distribution provision` signs a membership
//// ledger and mints the credentials, and `install` merges each node's bundle
//// into its configuration. The fixture adds only what the bundle does not
//// carry: a model URL, and on the box the `[profiles.kid]` table and the
//// `[spawners.laptop]` table that lets the laptop's node start children there.
//// The laptop's row for the box comes from the ledger, so the fixture writes no
//// `[orchestrators.box]` table.
////
//// Both models are scripted HTTP peers on loopback. The laptop's script is the
//// parent model and the box's script is the model every child runs, so no
//// real model is called.
////
//// ## What it proves
////
//// `daemon_shipped_remote_subagents_test_`, one laptop session in two turns.
////
//// - A child started `on` the box with `agent_spawn` runs there, and
////   `agent_wait` joins it and returns the report the child wrote.
//// - Two more children are started in the same turn. The parent's turn then
////   ends with both running, and the first of them goes on writing its
////   heartbeat on the box after the turn has ended: a remote child is detached
////   and the run end sends nothing (design note, section 8.3).
//// - The second child has a three second deadline. Nobody waits on it, and its
////   heartbeat stops by itself: the box's deadline tick stopped it.
//// - A second turn joins both children with one `agent_wait`. The first reports
////   what it finished with and the second reports that its wall-clock budget
////   expired.
////
//// ## What it does not prove
////
//// The design asks of this slice that a child be stopped by a `RunEnded` and
//// that the failure cases (the laptop killed mid-spawn, the link cut mid-join,
//// the turn ended with the link down) leave every child reported once or still
//// running toward its deadline. The laptop sends no `RunEnded` in phase 1, so
//// the first has no sender to drive, and the P model
//// (`protocol/models/remote-subagents`) checks the fence against a modelled
//// sender. The failure cases are the model's `tcDrops`, `tcAbort` and
//// `tcRestart`; this fixture does not cut a link.
////
//// ## Running it
////
//// ```sh
//// make server-shipment
//// make sandbox && install -m 0755 packages/sandbox/loom-exec bin/loom-exec
//// export LOOM_BOOTSTRAP_E2E_SERVER=$PWD/bin/loomd
//// bash scripts/test.sh client --match 'client@daemon_shipped_remote_subagents_test:'
//// ```
////
//// Without the shipment, or on a host whose helper cannot enforce a policy, the
//// fixture declines under its label as the other shipped fixtures do.

import client/tui_e2e_test.{type EunitTest}
import core/json
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile
import support/ledger_deployment
import support/provider_http as provider
import support/remote_daemons
import support/remote_duo.{type Duo}
import support/remote_pair
import weft/poll

const skip_label = "shipped remote subagents"

// The parent's prompts and the texts it answers with.
const spawn_prompt = "start three children on the box"

const spawned_answer = "three children started"

const join_prompt = "join the other two"

const joined_answer = "both joined"

// What the first two children's models answer with.
const first_report = "child one report"

const second_report = "child two report"

// The second child writes a heartbeat once a second for fifteen seconds. The
// third writes one for as long as it runs. Both files are in the box's delegate
// workspace, which is the spawner's `directory`.
const second_shell =
  "i=0; while [ $i -lt 15 ]; do echo x >> beat2; i=$((i+1)); sleep 1; done; echo child two shell done"

const third_shell = "while true; do echo x >> beat3; sleep 1; done"

// The third child's deadline, in milliseconds. The box checks deadlines on a
// fifteen second tick, so the child is stopped some seconds later.
const third_within_ms = 3000

// How long a heartbeat may take to start, to stop, or to be seen growing.
const settle_ms = 60_000

/// Starts a laptop and a box from the shipment, runs three remote children
/// from a laptop session and checks what each of them did.
///
/// ## Examples
///
/// `bash scripts/test.sh client --match 'client@daemon_shipped_remote_subagents_test:'`.
pub fn daemon_shipped_remote_subagents_test_() -> EunitTest {
  remote_duo.shipped(skip_label, drive)
}

fn drive(duo: Duo) -> Nil {
  let work = duo.directory <> "/box-work"
  let assert Ok(Nil) = simplifile.create_directory_all(work)
    as "the box's delegate workspace is created"
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
            fn(laptop_url) { session(duo, work, laptop_url, box_url) },
          )
        let assert Ok(seen) = laptop_report
          as "the laptop's model saw exactly its script"
        check_results(seen)
      },
    )
  let assert Ok(_) = box_report as "the box's model saw exactly its script"
  Nil
}

// --- the deployment ----------------------------------------------------------

// Provisions a two-orchestrator ledger deployment, installs each bundle into
// its daemon's configuration, adds the tables the bundle does not carry, and
// returns the two Erlang node names.
fn deploy(duo: Duo, work: String, laptop_url: String, box_url: String) -> Nil {
  let suffix = remote_daemons.random_hex(4)
  let laptop_node = "loom_s5_laptop_" <> suffix <> "@127.0.0.1"
  let box_node = "loom_s5_box_" <> suffix <> "@127.0.0.1"
  let deployed =
    ledger_deployment.provision("subagents", plan(laptop_node, box_node))
  install(deployed, "laptop", duo.alpha)
  install(deployed, "box", duo.bravo)
  append(duo.alpha, remote_pair.models_without_glance(laptop_url))
  append(
    duo.bravo,
    string.join(
      [
        remote_pair.models_without_glance(box_url),
        "[profiles.kid.roles]",
        "main = [\"fixture\"]",
        "",
        "[spawners.laptop]",
        "node = \"" <> laptop_node <> "\"",
        "directory = \"" <> work <> "\"",
        "profile = \"kid\"",
        "max_within_s = 120",
        "default_within_s = 60",
        "retain_s = 3600",
        "",
      ],
      "\n",
    ),
  )
  remote_daemons.write_options(duo.alpha)
  remote_daemons.write_options(duo.bravo)
}

fn plan(laptop_node: String, box_node: String) -> String {
  string.join(
    [
      "[[node]]",
      "name = \"laptop\"",
      "role = \"orchestrator\"",
      "erlang_node = \"" <> laptop_node <> "\"",
      "",
      "[[node]]",
      "name = \"box\"",
      "role = \"orchestrator\"",
      "erlang_node = \"" <> box_node <> "\"",
      "",
    ],
    "\n",
  )
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

// The parent model. The handles are minted at runtime and appear only in the
// results of the spawns, so each later call reads them from there.
fn laptop_script() -> List(provider.Exchange) {
  [
    provider.ToolUseExchange(
      spawn_prompt,
      "spawn-one",
      "agent_spawn",
      spawn("report the first child's result", "first child", None),
    ),
    provider.ComputedExchange(provider.AwaitToolResult("spawn-one"), fn(seen) {
      provider.ReplyToolUse(
        "wait-one",
        "agent_wait",
        wait([handle_of(seen, "spawn-one")]),
      )
    }),
    provider.ComputedExchange(provider.AwaitToolResult("wait-one"), fn(_seen) {
      provider.ReplyToolUse(
        "spawn-two",
        "agent_spawn",
        spawn("run the second child's shell", "second child", None),
      )
    }),
    provider.ComputedExchange(provider.AwaitToolResult("spawn-two"), fn(_seen) {
      provider.ReplyToolUse(
        "spawn-three",
        "agent_spawn",
        spawn(
          "run the third child's shell",
          "third child",
          Some(third_within_ms),
        ),
      )
    }),
    provider.ComputedExchange(
      provider.AwaitToolResult("spawn-three"),
      fn(_seen) { provider.ReplyText(spawned_answer) },
    ),
    provider.ComputedExchange(provider.AwaitPrompt(join_prompt), fn(seen) {
      provider.ReplyToolUse(
        "wait-rest",
        "agent_wait",
        wait([
          handle_of(seen, "spawn-two"),
          handle_of(seen, "spawn-three"),
        ]),
      )
    }),
    provider.ComputedExchange(provider.AwaitToolResult("wait-rest"), fn(_seen) {
      provider.ReplyText(joined_answer)
    }),
  ]
}

// The model every child on the box runs. The children are started one after the
// other and each makes its first request before the next is started, so the
// order of the first three steps is the order the children were spawned in. The
// second child's shell runs for fifteen seconds, which is far longer than the
// third child's first request takes to arrive.
fn box_script() -> List(provider.Exchange) {
  [
    provider.ComputedExchange(provider.AwaitPromptPrefix(brief_head), fn(_seen) {
      provider.ReplyText(first_report)
    }),
    provider.ComputedExchange(provider.AwaitPromptPrefix(brief_head), fn(_seen) {
      provider.ReplyToolUse("shell-two", "bash", shell(second_shell))
    }),
    provider.ComputedExchange(provider.AwaitPromptPrefix(brief_head), fn(_seen) {
      provider.ReplyToolUse("shell-three", "bash", shell(third_shell))
    }),
    provider.ComputedExchange(provider.AwaitToolResult("shell-two"), fn(_seen) {
      provider.ReplyText(second_report)
    }),
  ]
}

// The opening of a framed brief, which every child's first message begins with.
const brief_head = "[task brief from "

fn spawn(
  brief: String,
  purpose: String,
  within_ms: Option(Int),
) -> json.JsonValue {
  json.Object(
    list.append(
      [
        #("purpose", json.String(purpose)),
        #("brief", json.String(brief)),
        #("on", json.String("box")),
      ],
      case within_ms {
        Some(ms) -> [#("within_ms", json.Int(ms))]
        None -> []
      },
    ),
  )
}

fn wait(handles: List(String)) -> json.JsonValue {
  json.Object([
    #("handles", json.Array(list.map(handles, json.String))),
    #("within_ms", json.Int(25_000)),
  ])
}

fn shell(command: String) -> json.JsonValue {
  json.Object([#("command", json.String(command))])
}

// The handle `agent_spawn` printed in the result for `call_id`.
fn handle_of(seen: List(provider.ObservedRequest), call_id: String) -> String {
  let text = remote_daemons.result_text(seen, call_id)
  let assert Ok(#(_, after)) = string.split_once(text, "Handle: ")
    as "the spawn result names its handle"
  let assert Ok(#(handle, _)) = string.split_once(after, " ")
    as "the handle ends at the next space"
  handle
}

// --- the session -------------------------------------------------------------

fn session(duo: Duo, work: String, laptop_url: String, box_url: String) -> Nil {
  deploy(duo, work, laptop_url, box_url)
  let environment = [#("LOOM_TEST_PROVIDER_KEY", provider.dummy_key)]
  let _box = remote_daemons.start_with_environment(duo.bravo, [], environment)
  let laptop = remote_daemons.start_with_environment(duo.alpha, [], environment)
  let control = remote_daemons.open_control(laptop)
  let #(session, settled) =
    remote_daemons.create_local_and_settle(
      control,
      1,
      "subagents",
      duo.alpha.workspace,
    )
  assert remote_daemons.settled_state(settled) == "resident"
  let terminal = remote_daemons.attach(laptop, session)

  // The first turn starts three children and joins the first. It ends with the
  // other two running.
  remote_daemons.say(terminal, spawn_prompt)
  remote_daemons.await_answers(terminal, [spawned_answer], settle_ms)

  // The turn is over. The second child is still running on the box, because a
  // run end sends it nothing: its heartbeat goes on growing.
  let at_turn_end = line_count(work <> "/beat2")
  let _grew = await_lines(work <> "/beat2", at_turn_end + 2)

  // The third child's deadline passes with nobody waiting on it, and the box's
  // tick aborts its run. The daemon logs the abort, and the second turn has not
  // started, so no join can have been the one that found it overdue.
  await_log(duo.bravo, ["operation.aborted", "third-child"])

  // The second turn joins the two children it did not wait for.
  remote_daemons.say(terminal, join_prompt)
  remote_daemons.await_answers(
    terminal,
    [spawned_answer, joined_answer],
    settle_ms,
  )
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

// --- the evidence ------------------------------------------------------------

// What the parent's model was shown by each join.
fn check_results(seen: List(provider.ObservedRequest)) -> Nil {
  let first = remote_daemons.result_text(seen, "wait-one")
  assert string.contains(first, first_report)
  assert string.contains(first, "completed")
  let rest = remote_daemons.result_text(seen, "wait-rest")
  assert string.contains(rest, second_report)
  assert string.contains(rest, "wall-clock budget expired")
  Nil
}
