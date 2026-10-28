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
//// `daemon_shipped_remote_subagents_test_`, one laptop session in three turns.
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
//// - A turn starts a child that mails its parent with `agent_send` to `^main`
////   while the parent's turn is open in an `agent_wait`. The mail is a row in the
////   box's delegate session, the box sends it over the connection the laptop
////   keeps up, and the text arrives in the parent's run as a message from the
////   child (protocol-change/084, slice S9).
//// - A child's `bash` is refused by the box's sandbox because it asks to write
////   outside the delegate workspace. The box's spawner sets an approval ceiling
////   that admits that directory, so the refused call parks, the laptop's terminal
////   shows the question as `<child> @ box`, and the operator allows it once:
////   the call resumes and writes (protocol-change/089, slice S11). A second child
////   asks for the same directory again, which shows that the once approval was
////   spent, and the operator allows it for the session. A third child, started
////   afterwards, makes the same kind of call and runs without any question.
//// - While children run, the parent's agent strip lists them as
////   `<child> @ box` from the stubs the box's progress keeps
////   (protocol-change/090). The box's `[spawners.laptop]` names no
////   `transcript`, so a `/peek` at a child is refused there under the default
////   and the terminal says the transcript is unavailable.
//// - The box is then killed and restarted with `transcript = "visible"`. The
////   killed daemon's writer lease is still on the delegate session's file, so
////   the box answers the next spawn `NotYetOpen` until it expires; the laptop
////   treats that as silence and resends, and the fourth child starts once the
////   session opens. A `/peek` at it then reads a page of its branch from the
////   box, framed as a remote transcript.
//// - A last turn starts a fourth child that runs until it is stopped. The
////   laptop session is then stopped and deleted with that child running. The
////   laptop's release drainer tells the box (`Release`), and the box stops the
////   child (`operation.aborted` in its log, and its heartbeat goes quiet) and
////   deletes the delegate session, whose row is gone from the box's list.
////
//// ## What it does not prove
////
//// The failure cases the design lists (the laptop killed mid-spawn, the link
//// cut mid-join, the turn ended with the link down) leave every child reported
//// once or still running toward its deadline. They are covered by the P model
//// (`protocol/models/remote-subagents`) as `tcDrops`, `tcAbort` and
//// `tcRestart`, and not by this fixture, which does not cut a link. The same
//// holds for a `Release` that is lost, sent twice or overtakes its `Spawn`: the
//// model checks those, and the unit tests check the box's half.
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
import client/tui_v2_test
import core/json
import etui/backend
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap
import session_view/approval
import simplifile
import support/ledger_deployment
import support/provider_http as provider
import support/remote_daemons
import support/remote_duo.{type Duo}
import support/remote_pair
import support/tui_driver
import weft/poll

const skip_label = "shipped remote subagents"

// The parent's prompts and the texts it answers with.
const spawn_prompt = "start three children on the box"

const spawned_answer = "three children started"

const join_prompt = "join the other two"

const joined_answer = "both joined"

const upward_prompt = "start a child that mails you"

const upward_answer = "the child's mail arrived"

// What the mailing child sends its parent, and what it reports afterwards.
const upward_text = "ping from the box child"

const upward_report = "upward child report"

const once_prompt = "start a child that needs a directory"

const once_answer = "the directory child started"

const session_prompt = "start a second child that needs the directory"

const session_answer = "the second directory child started"

const sibling_prompt = "start a third child that needs the directory"

const sibling_answer = "the third directory child started"

const fourth_prompt = "start a fourth child that keeps running"

const fourth_answer = "fourth child started"

// What the first two children's models answer with.
const first_report = "child one report"

const second_report = "child two report"

// The second child writes a heartbeat once a second for fifteen seconds. The
// third writes one for as long as it runs. Both files are in the box's delegate
// workspace, which is the spawner's `directory`.
const second_shell =
  "i=0; while [ $i -lt 15 ]; do echo x >> beat2; i=$((i+1)); sleep 1; done; echo child two shell done"

const third_shell = "while true; do echo x >> beat3; sleep 1; done"

// The fourth child runs until the release stops it.
const fourth_shell = "while true; do echo x >> beat4; sleep 1; done"

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

  // The directory the box's approval ceiling admits and the children ask for. It
  // is outside the delegate workspace, so the sandbox refuses a write to it, and
  // it is canonical, because the tool asks for the canonical path and the ceiling
  // compares text.
  let assert Ok(Nil) =
    simplifile.create_directory_all(duo.directory <> "/box-granted")
    as "the granted directory is created"
  let assert Ok(granted) =
    bootstrap.canonical_directory(duo.directory <> "/box-granted")
    as "the granted directory is canonical"
  let #(Nil, box_report) =
    provider.with_server_for(
      box_script(granted),
      provider.OnlySuccessful,
      900_000,
      fn(box_url) {
        let #(Nil, laptop_report) =
          provider.with_server_for(
            laptop_script(),
            provider.AlsoFailed,
            900_000,
            fn(laptop_url) { session(duo, work, granted, laptop_url, box_url) },
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
fn deploy(
  duo: Duo,
  work: String,
  granted: String,
  laptop_url: String,
  box_url: String,
) -> Nil {
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
        retain_line,
        "",
        "[spawners.laptop.approval_ceiling]",
        "writable_roots = [\"" <> granted <> "\"]",
        "",
      ],
      "\n",
    ),
  )
  remote_daemons.write_options(duo.alpha)
  remote_daemons.write_options(duo.bravo)
}

// The last line of the box's spawner table, which the restart extends with
// `transcript = "visible"`.
const retain_line = "retain_s = 3600"

// Lets the laptop read its children's transcripts on the box from the next
// start of the box daemon: the spawner table gains `transcript = "visible"`.
fn make_transcripts_visible(layout: remote_daemons.Layout) -> Nil {
  let assert Ok(text) = simplifile.read(layout.config)
    as "the box's configuration is readable"
  let assert Ok(#(before, after)) = string.split_once(text, retain_line)
    as "the box's spawner table is in its configuration"
  let assert Ok(Nil) =
    simplifile.write(
      layout.config,
      before <> retain_line <> "\ntranscript = \"visible\"" <> after,
    )
    as "the box's spawner table now shows transcripts"
  Nil
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
    provider.ComputedExchange(provider.AwaitPrompt(upward_prompt), fn(_seen) {
      provider.ReplyToolUse(
        "spawn-up",
        "agent_spawn",
        spawn("send your parent a note, then finish", "upward child", None),
      )
    }),
    provider.ComputedExchange(provider.AwaitToolResult("spawn-up"), fn(seen) {
      provider.ReplyToolUse(
        "wait-up",
        "agent_wait",
        wait([handle_of(seen, "spawn-up")]),
      )
    }),

    // The mail was steered into the open run while the wait was in flight, so it
    // rides in the user turn that carries the wait's result; `check_results`
    // looks for it in that request.
    provider.ComputedExchange(provider.AwaitToolResult("wait-up"), fn(_seen) {
      provider.ReplyText(upward_answer)
    }),
    provider.ComputedExchange(provider.AwaitPrompt(once_prompt), fn(_seen) {
      provider.ReplyToolUse(
        "spawn-once",
        "agent_spawn",
        spawn("write into the granted directory", "directory child", None),
      )
    }),
    provider.ComputedExchange(provider.AwaitToolResult("spawn-once"), fn(_seen) {
      provider.ReplyText(once_answer)
    }),
    provider.ComputedExchange(provider.AwaitPrompt(session_prompt), fn(_seen) {
      provider.ReplyToolUse(
        "spawn-session",
        "agent_spawn",
        spawn(
          "write into the granted directory again",
          "second directory child",
          None,
        ),
      )
    }),
    provider.ComputedExchange(
      provider.AwaitToolResult("spawn-session"),
      fn(_seen) { provider.ReplyText(session_answer) },
    ),
    provider.ComputedExchange(provider.AwaitPrompt(sibling_prompt), fn(_seen) {
      provider.ReplyToolUse(
        "spawn-sibling",
        "agent_spawn",
        spawn(
          "write into the granted directory a third time",
          "third directory child",
          None,
        ),
      )
    }),
    provider.ComputedExchange(
      provider.AwaitToolResult("spawn-sibling"),
      fn(_seen) { provider.ReplyText(sibling_answer) },
    ),
    provider.ComputedExchange(provider.AwaitPrompt(fourth_prompt), fn(_seen) {
      provider.ReplyToolUse(
        "spawn-four",
        "agent_spawn",
        spawn("run the fourth child's shell", "fourth child", None),
      )
    }),
    // The box was killed and restarted just before this spawn, so it may be
    // answered at once or, while the dead daemon's lease is on the delegate
    // session's file, reported as not answered in time and resent by the
    // laptop's drainer. Either result is followed by the same text.
    provider.ComputedExchange(
      provider.AwaitAnyToolResult("spawn-four"),
      fn(_seen) { provider.ReplyText(fourth_answer) },
    ),
  ]
}

// The model every child on the box runs. The children are started one after the
// other and each makes its first request before the next is started, so the
// order of the first three steps is the order the children were spawned in. The
// second child's shell runs for fifteen seconds, which is far longer than the
// third child's first request takes to arrive.
fn box_script(granted: String) -> List(provider.Exchange) {
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
    provider.ComputedExchange(provider.AwaitPromptPrefix(brief_head), fn(_seen) {
      provider.ReplyToolUse(
        "send-up",
        "agent_send",
        json.Object([
          #("to", json.String("^main")),
          #("message", json.String(upward_text)),
        ]),
      )
    }),

    // The child stays alive a moment after it sends. The row rings the box's
    // drainer, which sends at once; and a child that finished before the mail left
    // would still be asked about until the box reports nothing undelivered.
    provider.ComputedExchange(provider.AwaitToolResult("send-up"), fn(_seen) {
      provider.ReplyToolUse("nap", "bash", shell("sleep 3"))
    }),
    provider.ComputedExchange(provider.AwaitToolResult("nap"), fn(_seen) {
      provider.ReplyText(upward_report)
    }),
    provider.ComputedExchange(provider.AwaitPromptPrefix(brief_head), fn(_seen) {
      provider.ReplyToolUse("grant-once", "bash", granting(granted, "once"))
    }),
    provider.ComputedExchange(provider.AwaitToolResult("grant-once"), fn(_seen) {
      provider.ReplyText("directory child report")
    }),
    provider.ComputedExchange(provider.AwaitPromptPrefix(brief_head), fn(_seen) {
      provider.ReplyToolUse(
        "grant-session",
        "bash",
        granting(granted, "session"),
      )
    }),
    provider.ComputedExchange(
      provider.AwaitToolResult("grant-session"),
      fn(_seen) { provider.ReplyText("second directory child report") },
    ),
    provider.ComputedExchange(provider.AwaitPromptPrefix(brief_head), fn(_seen) {
      provider.ReplyToolUse(
        "grant-sibling",
        "bash",
        granting(granted, "sibling"),
      )
    }),
    provider.ComputedExchange(
      provider.AwaitToolResult("grant-sibling"),
      fn(_seen) { provider.ReplyText("third directory child report") },
    ),
    provider.ComputedExchange(provider.AwaitPromptPrefix(brief_head), fn(_seen) {
      provider.ReplyToolUse("shell-four", "bash", shell(fourth_shell))
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

// A `bash` call that appends `label` to a marker in the granted directory and
// declares that directory writable. The delegate workspace does not allow it, so
// the call is refused until a grant for the directory is in force.
fn granting(granted: String, label: String) -> json.JsonValue {
  json.Object([
    #(
      "command",
      json.String("printf '" <> label <> "\\n' >> " <> granted <> "/marker"),
    ),
    #(
      "permissions",
      json.Object([
        #("writable_roots", json.Array([json.String(granted)])),
      ]),
    ),
  ])
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

fn session(
  duo: Duo,
  work: String,
  granted: String,
  laptop_url: String,
  box_url: String,
) -> Nil {
  deploy(duo, work, granted, laptop_url, box_url)
  let environment = [#("LOOM_TEST_PROVIDER_KEY", provider.dummy_key)]
  let _first_box =
    remote_daemons.start_with_environment(duo.bravo, [], environment)
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

  // The parent's strip lists the running child, placed on the box. The row
  // comes from the stub the laptop keeps, pushed to the terminal when it
  // changes (protocol-change/090).
  await_frame(terminal, "second-child @ box")

  // The box's spawner table names no `transcript`, so the child's transcript
  // stays on the box: the peek is refused there, and the terminal says so.
  remote_daemons.say(terminal, "/peek second-child")
  await_frame(terminal, "[transcript of sub:^main/second-child-")
  await_frame(terminal, "Transcript unavailable")
  remote_daemons.say(terminal, "/peek close")

  // The third child's deadline passes with nobody waiting on it, and the box's
  // tick aborts its run. The daemon logs the abort, and the second turn has not
  // started, so no join can have been the one that found it overdue.
  await_log(duo.bravo, ["operation.aborted", "third-child"])

  // The abort must also reach the child's shell. A default-mode `bash` runs as
  // a job under the jobs actor, which the runtime's own abort does not stop;
  // before the reap told the broker, this file went on growing until the job's
  // one hour deadline. The heartbeat is once a second, so a count that holds
  // for three seconds means the process group is gone.
  let _quiet = await_quiet(work <> "/beat3")

  // The second turn joins the two children it did not wait for.
  remote_daemons.say(terminal, join_prompt)
  remote_daemons.await_answers(
    terminal,
    [spawned_answer, joined_answer],
    settle_ms,
  )

  // The mailing turn: the child sends `^main` a note while the parent waits for
  // it, and the note arrives in the parent's run.
  remote_daemons.say(terminal, upward_prompt)
  remote_daemons.await_answers(
    terminal,
    [spawned_answer, joined_answer, upward_answer],
    settle_ms,
  )

  // A child's `bash` asks to write outside the delegate workspace. The box's
  // sandbox refuses it, the spawner's ceiling admits the directory, and the
  // refusal parks while the laptop is connected. The laptop's terminal shows the
  // question as `<child> @ box`, and the operator allows it once.
  let marker = granted <> "/marker"
  let answers = [spawned_answer, joined_answer, upward_answer]
  remote_daemons.say(terminal, once_prompt)
  remote_daemons.await_answers(
    terminal,
    list.append(answers, [once_answer]),
    settle_ms,
  )
  let asked = await_question(terminal)
  assert string.contains(asked, "directory-child @ box")
  decide(terminal, "1")
  let _wrote = await_lines(marker, 1)
  await_no_question(terminal)

  // The once approval was spent by that one call, so a second child that asks
  // for the same directory is asked about again. The operator allows it for the
  // session this time.
  remote_daemons.say(terminal, session_prompt)
  remote_daemons.await_answers(
    terminal,
    list.append(answers, [once_answer, session_answer]),
    settle_ms,
  )
  let _asked_again = await_question(terminal)
  decide(terminal, "2")
  let _wrote_again = await_lines(marker, 2)
  await_no_question(terminal)

  // A third child, started afterwards, makes the same kind of call. The grant is
  // standing in the delegate session, so the call runs and nobody is asked.
  remote_daemons.say(terminal, sibling_prompt)
  remote_daemons.await_answers(
    terminal,
    list.append(answers, [once_answer, session_answer, sibling_answer]),
    settle_ms,
  )
  let _wrote_a_third = await_lines(marker, 3)
  await_no_question(terminal)

  // The marker proves shell progress, not durable terminal completion. Wait
  // until the sibling settles before crashing the box, so recovery cannot feed
  // an interrupted tool result to the success-only provider script.
  await_log(duo.bravo, ["operation.settled", "third-directory-child"])

  // The box's owner now lets the laptop read its children's transcripts. The
  // setting is read when the daemon starts, so the box is killed and started
  // again with it. No child is running there. The dead daemon's writer lease
  // stays on the delegate session's file until it expires, so the next spawn is
  // answered `NotYetOpen` until then, and the laptop resends it.
  remote_daemons.crash(duo.bravo)
  make_transcripts_visible(duo.bravo)
  let box = remote_daemons.start_with_environment(duo.bravo, [], environment)

  // The last turn starts a child that has no end of its own. Its heartbeat
  // grows on the box, and the box holds a delegate session for this parent.
  remote_daemons.say(terminal, fourth_prompt)
  remote_daemons.await_answers(
    terminal,
    [
      spawned_answer,
      joined_answer,
      upward_answer,
      once_answer,
      session_answer,
      sibling_answer,
      fourth_answer,
    ],
    settle_ms,
  )
  let _running = await_lines_within(work <> "/beat4", 2, 2 * settle_ms)

  // The box now shows its children's transcripts to this spawner, so a peek at
  // the running child reads a page of its branch from the box, framed as a
  // remote transcript: the brief the parent gave it and the shell it called.
  await_frame(terminal, "fourth-child @ box")

  // The complete page needs room for both framing lines. At 80 by 24 the
  // lower pane clips the header once loading finishes, so observing it there
  // depends on sampling the transient loading frame before the page arrives.
  let _ = tui_driver.play(terminal, [backend.Resize(120, 40)])
  remote_daemons.say(terminal, "/peek fourth-child")
  await_frame(terminal, "[transcript of sub:^main/fourth-child-")
  await_frame(terminal, "asked: run the fourth child")
  await_frame(terminal, "tool: bash")
  await_frame(terminal, "[end transcript.")
  remote_daemons.say(terminal, "/peek close")
  let box_control = remote_daemons.open_control(box)
  assert delegate_sessions(box_control, 70, session) != []

  // The owner deletes the laptop session with the child still running. The
  // delete leaves a release row for the box, and the laptop's drainer sends it
  // at its next pass. The box stops the child and deletes the session that held
  // it: the abort is logged, the heartbeat goes quiet, and the delegate session
  // leaves the box's list.
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
  await_log(duo.bravo, ["operation.aborted", "fourth-child"])
  let _quiet = await_quiet(work <> "/beat4")
  await_no_delegate_session(box_control, session)
  Nil
}

// Waits until the laptop's terminal holds a pending question that a child on
// the box raised, and returns who is asking, as the card words it.
fn await_question(terminal: process.Subject(tui_driver.Message)) -> String {
  let sample =
    tui_v2_test.await_within(
      terminal,
      fn(sample) { asking(sample) != [] },
      settle_ms,
    )
  let assert [asked, ..] = asking(sample)
    as "the terminal holds a question from a child on the box"
  asked
}

// The askers of the pending questions that children on other orchestrators
// raised, as the card words them.
fn asking(sample: tui_driver.Sample) -> List(String) {
  sample.model.shared.approvals
  |> list.filter(fn(review) { review.status == approval.Pending })
  |> list.filter_map(fn(review) {
    option.to_result(approval.asker(review), Nil)
  })
}

// Selects a choice on the open dialog by its number and confirms it.
fn decide(
  terminal: process.Subject(tui_driver.Message),
  choice: String,
) -> Nil {
  let _ =
    tui_driver.play(terminal, [
      backend.KeyPress(choice),
      backend.KeyPress("enter"),
    ])
  Nil
}

// Waits until the terminal holds no pending question, which is how a decided
// question leaves it: the box sends the decided state and the card clears.
fn await_no_question(terminal: process.Subject(tui_driver.Message)) -> Nil {
  let _ =
    tui_v2_test.await_within(
      terminal,
      fn(sample) {
        !list.any(sample.model.shared.approvals, fn(review) {
          review.status == approval.Pending
        })
      },
      settle_ms,
    )
  Nil
}

// The names of the box's sessions that serve the laptop session `parent`. The
// registry names a delegate session after its spawner and its parent.
fn delegate_sessions(
  control: remote_daemons.Control,
  id: Int,
  parent: String,
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
    as "the box lists its sessions"
  sessions
  |> list.filter_map(fn(record) {
    case remote_daemons.field(record, "name") {
      json.String(name) ->
        case string.contains(name, parent) {
          True -> Ok(name)
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

// Waits until the box no longer lists a delegate session for `parent`.
fn await_no_delegate_session(
  control: remote_daemons.Control,
  parent: String,
) -> Nil {
  let assert poll.Answered(Nil) =
    poll.until(within: settle_ms, every: 500, attempt: fn() {
      case delegate_sessions(control, 71, parent) {
        [] -> poll.Done(Nil)
        [_, ..] -> poll.Retry
      }
    })
    as "the box deleted the delegate session after the release"
  Nil
}

// Waits until the terminal's frame shows `needle`.
fn await_frame(terminal, needle: String) -> Nil {
  let _ =
    tui_v2_test.await_within(
      terminal,
      fn(sample: tui_driver.Sample) { string.contains(sample.frame, needle) },
      settle_ms,
    )
  Nil
}

// Waits until the file has at least `lines` lines and returns the count.
fn await_lines(path: String, lines: Int) -> Int {
  await_lines_within(path, lines, settle_ms)
}

// `await_lines` with a bound of its own. The fourth child starts only once the
// killed box's lease has expired, which can take a minute after the kill.
fn await_lines_within(path: String, lines: Int, within: Int) -> Int {
  let assert poll.Answered(count) =
    poll.until(within:, every: 500, attempt: fn() {
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

// --- the evidence ------------------------------------------------------------

// What the parent's model was shown by each join.
fn check_results(seen: List(provider.ObservedRequest)) -> Nil {
  let first = remote_daemons.result_text(seen, "wait-one")
  assert string.contains(first, first_report)
  assert string.contains(first, "completed")
  let rest = remote_daemons.result_text(seen, "wait-rest")
  assert string.contains(rest, second_report)
  assert string.contains(rest, "wall-clock budget expired")

  // The child's mail reached the parent's run, in the request that carried the
  // wait's result, framed as a message from the child.
  let carrying =
    list.filter(seen, fn(request) {
      request.latest
      == provider.SuccessfulToolResult(
        "wait-up",
        remote_daemons.result_text(seen, "wait-up"),
      )
    })
  assert list.any(carrying, fn(request) {
    string.contains(json.to_string(request.body), upward_text)
  })
  Nil
}
