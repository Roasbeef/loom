//// A session registered on an executor, assembled whole.
////
//// The conversation half is the real assembly: SQLite writer, runtime,
//// services and prompt. The executor is the real host and ledger in this VM
//// with a fake plane, so a model call that names a workspace tool crosses the
//// whole path (clearance, routing, authority, surface, host, ledger) and
//// comes back as a staged result. What these tests add over the unit tests is
//// that the pieces are wired into one session: the right tool goes to the
//// right half, the prompt is built from the census, the registered name is
//// never touched on this machine's disk, and close and reopen move the
//// incarnation.

import broker/broker
import client/catalog
import client/extension/installed
import client/internal/instance_host as host
import client/internal/instance_owner as custody
import client/owned_assembly_test
import client/remote/protocol
import client/remote/scope
import client/remote/workspace
import client/serve
import client/system_prompt
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import provider/http
import provider/secret
import runtime/api
import session/session
import simplifile
import storage/storage
import support/provider as provider_test
import support/remote_fixtures as fixtures
import support/remote_orchestrator as rig
import telemetry/log

const registered_name = "registered-checkout-never-on-this-host"

fn identity(seed: Int) -> ids.SessionId {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(at: 1), seed: seed))
  id
}

fn sse(kind: String, value: json.JsonValue) -> String {
  "event: " <> kind <> "\ndata: " <> json.to_string(value) <> "\n\n"
}

// A model that calls `fs_read` (a workspace tool), then `context_remaining` (an
// owner tool), then ends the turn. It decides from how many tool results the
// request already carries.
fn script(request: http.HttpRequest, events) -> Nil {
  process.send(
    events,
    http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
  )
  let results = list.length(string.split(request.body, "\"tool_result\"")) - 1
  let start =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
  let #(content, reason) = case results {
    0 -> #(
      call("call_fs", "fs_read", json.Object([#("path", json.String("a"))])),
      "tool_use",
    )
    1 -> #(call("call_ctx", "context_remaining", json.Object([])), "tool_use")
    _ -> #(
      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"done\"}}\n\n",
      "end_turn",
    )
  }
  let ending =
    "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
    <> sse(
      "message_delta",
      json.Object([
        #("type", json.String("message_delta")),
        #("delta", json.Object([#("stop_reason", json.String(reason))])),
        #("usage", json.Object([#("output_tokens", json.Int(1))])),
      ]),
    )
    <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
  process.send(
    events,
    http.ResponseChunk(bit_array.from_string(start <> content <> ending)),
  )
  process.send(events, http.ResponseEnd)
}

fn call(id: String, name: String, input: json.JsonValue) -> String {
  sse(
    "content_block_start",
    json.Object([
      #("type", json.String("content_block_start")),
      #("index", json.Int(0)),
      #(
        "content_block",
        json.Object([
          #("type", json.String("tool_use")),
          #("id", json.String(id)),
          #("name", json.String(name)),
          #("input", json.Object([])),
        ]),
      ),
    ]),
  )
  <> sse(
    "content_block_delta",
    json.Object([
      #("type", json.String("content_block_delta")),
      #("index", json.Int(0)),
      #(
        "delta",
        json.Object([
          #("type", json.String("input_json_delta")),
          #("partial_json", json.String(json.to_string(input))),
        ]),
      ),
    ]),
  )
}

// The assembly fixture's settings, made to describe a registered workspace: a
// name that is not a directory, no helper on this machine, the prompt pack
// rendered, and an operator guidance file in a home of its own.
fn settings() -> serve.Settings {
  let base = owned_assembly_test.settings()
  let root = filepath.directory_name(base.session_path)
  let home = root <> "/home"
  let assert Ok(Nil) = simplifile.create_directory_all(home <> "/.agents")
  let assert Ok(Nil) =
    simplifile.write(home <> "/.agents/AGENTS.md", "USER-GUIDANCE-MARKER")
  serve.Settings(
    ..base,
    workspace: registered_name,
    helper_path: "",
    system: None,
    home: Some(home),
    session_id: "registered-session",
    gateway: catalog.gateway(
      base.catalog,
      transport: provider_test.transport(script),
      secrets: secret.from_list([#("UNUSED", "fixture-only")]),
      clock: clock.fixed(at: 0),
    ),
  )
}

fn opened(
  settings: serve.Settings,
  id: ids.SessionId,
  placement: workspace.Placement,
) {
  let results = process.new_subject()
  let assert Ok(prepared) =
    host.prepare(
      build: fn(owner) {
        serve.assemble_registered(
          settings,
          id,
          log.discard(),
          owner,
          None,
          placement,
        )
      },
      fatal: serve.instance_children,
      results:,
      faults: process.new_subject(),
      failures: process.new_subject(),
      label: fn() { Nil },
    )
    as "manager prepares ownership before beginning assembly"
  host.begin(prepared)
  #(prepared, results)
}

fn assembled(settings, id, placement) {
  let #(prepared, results) = opened(settings, id, placement)
  let assert Ok(Ok(instance)) = process.receive(results, 10_000)
    as "the registered session assembles"
  #(prepared, instance)
}

fn standard_executor() {
  let #(probe, executor, _attempts) = observed_executor()
  #(probe, executor)
}

// An executor whose broker is real and counts the clearances asked of it.
fn observed_executor() {
  let probe = fixtures.probe(fixtures.Open)
  let attempts = fixtures.marks()
  let executor_broker = rig.refusing_broker(attempts)
  let executor =
    rig.start(rig.factory(
      probe,
      rig.census_over(rig.standard_tools(), broker.subject(executor_broker)),
      protocol.AllRetired,
    ))
  #(probe, executor, attempts)
}

pub fn a_registered_session_opens_without_touching_its_name_here_test() {
  let settings = settings()
  let #(probe, executor) = standard_executor()

  let #(prepared, instance) =
    assembled(settings, identity(1), rig.placement(executor))

  // Nothing was made, probed or canonicalized for the registered name, and no
  // helper pool exists on this machine.
  assert simplifile.is_directory(registered_name) == Ok(False)
  assert simplifile.is_file(registered_name) == Ok(False)
  assert instance.pool == None
  assert instance.executor == None
  assert instance.plane.census.workspace == rig.executor_root
  assert instance.plane.fatal == []
  assert list.length(fixtures.builds(probe)) == 1
  assert scope.read(instance.runtime.session)
    == Ok(Some(scope.Scope(1, None, Some(rig.executor_name))))

  assert host.close(prepared, within_ms: 10_000) == custody.Closed
  rig.stop(executor)
}

pub fn the_baseline_git_observation_runs_on_the_executors_broker_test() {
  // The session records its starting revision while it assembles, through the
  // broker handle built over the census's subject. The executor's broker is
  // the only one with a pool behind it, so a clearance attempt there is the
  // proof that the observation did not run on this machine.
  let settings = settings()
  let #(_probe, executor, attempts) = observed_executor()

  let #(prepared, _instance) =
    assembled(settings, identity(6), rig.placement(executor))

  assert fixtures.marked(attempts) != []
  assert host.close(prepared, within_ms: 10_000) == custody.Closed
  rig.stop(executor)
}

pub fn the_prompt_is_built_from_the_census_in_its_order_test() {
  let settings = settings()
  let #(_probe, executor) = standard_executor()

  let #(prepared, instance) =
    assembled(settings, identity(2), rig.placement(executor))
  let text = instance.prompt.text

  // The operator's guidance is read here and the workspace's arrives in the
  // census, in the order a local session renders them.
  assert string.contains(text, "USER-GUIDANCE-MARKER")
  assert string.contains(text, "EXECUTOR-GUIDANCE-MARKER")
  assert position(text, "USER-GUIDANCE-MARKER")
    < position(text, "EXECUTOR-GUIDANCE-MARKER")

  // The census facts reach the environment block, and the workspace tools
  // appear in the executor's registration order.
  assert string.contains(text, rig.executor_root)
  assert position(text, "Use bash for the fixture.")
    < position(text, "Use fs_read for the fixture.")
  assert instance.prompt.origin == system_prompt.Shipped

  assert host.close(prepared, within_ms: 10_000) == custody.Closed
  rig.stop(executor)
}

fn position(text: String, needle: String) -> Int {
  case string.split_once(text, needle) {
    Ok(#(before, _)) -> string.length(before)
    Error(Nil) -> -1
  }
}

pub fn a_workspace_call_runs_on_the_executor_and_an_owner_call_runs_here_test() {
  let settings = settings()
  let #(probe, executor) = standard_executor()
  let #(prepared, instance) =
    assembled(settings, identity(3), rig.placement(executor))

  let assert Ok(op) = api.prompt(instance.runtime, [user("read it")])
  let assert Ok(_) = api.await_result(instance.runtime, op, within_ms: 60_000)

  // The workspace tool crossed to the executor exactly once, and its outcome
  // was staged in the conversation. The owner tool never left this VM.
  assert fixtures.run_count(probe, "call_fs") == 1
  assert fixtures.run_count(probe, "call_ctx") == 0
  let results = tool_results(instance)
  let assert Ok(fs_text) = list.key_find(results, "call_fs")
  assert fs_text == "ran:fs_read"
  let assert Ok(ctx_text) = list.key_find(results, "call_ctx")
  assert !string.contains(ctx_text, "ran:")

  assert host.close(prepared, within_ms: 10_000) == custody.Closed
  rig.stop(executor)
}

pub fn closing_records_the_outcome_and_the_next_open_attaches_higher_test() {
  let settings = settings()
  let #(probe, executor) = standard_executor()
  let #(prepared, _instance) =
    assembled(settings, identity(4), rig.placement(executor))

  assert host.close(prepared, within_ms: 10_000) == custody.Closed

  // The close went through the executor and its outcome is in the store.
  assert fixtures.closes(probe) == 1
  let assert Ok(#(reopened, retire)) =
    session.open_sqlite_owned(
      path: settings.session_path,
      owner: "inspector",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 1),
    )
  assert scope.read(reopened)
    == Ok(
      Some(scope.Scope(1, Some(protocol.AllRetired), Some(rig.executor_name))),
    )
  assert retire() == Ok(Nil)

  // The session opens again: the executor reopens its scope one higher.
  let #(second, instance) =
    assembled(settings, identity(4), rig.placement(executor))
  assert scope.read(instance.runtime.session)
    == Ok(Some(scope.Scope(2, None, Some(rig.executor_name))))
  assert list.length(fixtures.builds(probe)) == 2
  assert host.close(second, within_ms: 10_000) == custody.Closed
  rig.stop(executor)
}

pub fn an_unreachable_executor_fails_the_open_with_its_prefix_test() {
  let settings = settings()
  let #(_probe, executor) = standard_executor()
  let down =
    rig.placement_of(
      [
        rig.candidate_over(
          rig.executor_name,
          workspace.Reach(..rig.reach(executor), connect: fn() {
            Error("the peer refused the handshake")
          }),
        ),
      ],
      fn(_name) { Nil },
    )

  let #(prepared, results) = opened(settings, identity(5), down)
  let assert Ok(Error(reason)) = process.receive(results, 10_000)

  assert reason == "executor_unavailable: the peer refused the handshake"
  assert simplifile.is_directory(registered_name) == Ok(False)
  let _ = host.close(prepared, within_ms: 10_000)
  rig.stop(executor)
}

pub fn installed_extensions_are_refused_for_a_workspace_on_an_executor_test() {
  assert serve.remote_extension_refusals([]) == []
  let notices =
    serve.remote_extension_refusals([
      installed_refused("alpha"),
      installed_refused("beta"),
    ])
  assert list.length(notices) == 2
  assert list.all(notices, string.contains(_, "not available"))
}

fn installed_refused(name: String) {
  installed.Refused(name:, reason: "unused")
}

// --- reading the conversation back --------------------------------------------

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
    origin: None,
  )
}

// Every tool result in the session, by call id, as its first text block.
fn tool_results(instance: serve.Instance) -> List(#(String, String)) {
  let assert Ok(entries) =
    storage.scan_entries(
      instance.runtime.session.store,
      storage.entry_scan() |> storage.entry_limit(100),
    )
    as "the small session reads its own entries"
  list.filter_map(entries, fn(item) {
    case item {
      entry.MessageEntry(
        message: message.ToolResultMessage(
          tool_call_id: id,
          content: [message.ToolResultText(text:, ..), ..],
          ..,
        ),
        ..,
      ) -> Ok(#(id, text))
      _ -> Error(Nil)
    }
  })
}
