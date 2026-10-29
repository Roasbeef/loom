//// `loom acp` against the shipped daemon: the end-to-end falsifier of issue
//// #1026's Agent Client Protocol server.
////
//// Each test launches the real `bin/loomd` through the isolated launcher
//// (`shipped_server`, an empty private home), a finite loopback provider, and
//// the real `acp/server.serve` loop in-process. The ACP client is this file:
//// it sends JSON-RPC lines into the server's transport and reads the frames
//// the server writes, exactly as an editor or Harbor's runner would over a
//// pipe, except that the pipe is a pair of subjects so no subprocess is
//// needed. Nothing between the transport and the daemon is faked: sessions are
//// created through the control socket, driven through the credited lane, and
//// stopped at the end.
////
//// What is pinned here, and why each is its own test:
////
//// - a text turn: the answer arrives exactly once whether it streamed or
////   committed, the usage and stop reason come back, and the session is
////   saved, not left resident, after the client hangs up;
//// - a tool call lifecycle and a permission round trip, allow and deny;
//// - a cancel in the middle of a stalled response;
//// - `session/load` replaying a saved transcript;
//// - frames the server must refuse without dying: garbage, oversized, an
////   unknown method, a missing `initialize`;
//// - the workspace gate and the two refused extensions.

import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json.{type JsonValue}
import filepath
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap as native
import simplifile
import support/internal/ffi_daemon_socket as tcp
import support/internal/ffi_ws as socket
import support/native_fixture
import support/provider_http
import support/shipped_server
import tui/acp/rpc
import tui/acp/server
import tui/bootstrap
import tui/daemon
import tui/daemon/protocol
import tui/placement

// How long the harness waits for the next frame before calling the server
// wedged. It is a failsafe on waits that otherwise end on an event.
const frame_wait_ms = 45_000

/// The fixture's directories: its root, the catalogue, and the workspace.
type Fixture {
  Fixture(directory: String, config: String, workspace: String)
}

fn fixture(directory: String, provider_url: String) -> Fixture {
  let assert Ok(Nil) =
    simplifile.create_directory_all(directory <> "/workspace")
    as "the session workspace exists"
  let assert Ok(Nil) =
    simplifile.write(
      directory <> "/fixture.toml",
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
        <> provider_url
        <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n",
    )
    as "the catalogue selects the loopback provider"
  Fixture(
    directory:,
    config: filepath.join(directory, "fixture.toml"),
    workspace: filepath.join(directory, "workspace"),
  )
}

fn config_for(shipped: String, fixture: Fixture) -> server.Config {
  server.Config(
    options: bootstrap.Options(
      fixture.workspace,
      "",
      shipped,
      filepath.join(fixture.directory, "state"),
      fixture.config,
      "",
      placement.OnThisHost,
    ),
    roots: [fixture.workspace],
    names: [],
    version: "test",
  )
}

// --- the scripted ACP client -------------------------------------------------

/// One running server and the two subjects standing in for its pipes.
type Client {
  Client(
    stdin: Subject(Pipe),
    stdout: Subject(String),
    done: Subject(Int),
    config: server.Config,
  )
}

/// What the pipe's owner is told: a line pushed in, or a reader asking for one.
type Pipe {
  Push(line: Option(String))
  Pull(reader: Subject(Option(String)))
}

/// Starts the process that owns the standard-input queue.
///
/// A subject can be received from only by the process that created it, and the
/// server reads its input from a reader process of its own, not from the test.
/// So the queue lives in a process that both sides address by message: the test
/// pushes lines, the reader pulls them, and `None` is end of input.
fn start_pipe() -> Subject(Pipe) {
  let ready = process.new_subject()
  let _owner =
    process.spawn_unlinked(fn() {
      let inbox = process.new_subject()
      process.send(ready, inbox)
      pump(inbox, [], None)
    })
  let assert Ok(inbox) = process.receive(ready, 5000)
    as "the pipe owner published its inbox"
  inbox
}

fn pump(
  inbox: Subject(Pipe),
  queue: List(Option(String)),
  waiting: Option(Subject(Option(String))),
) -> Nil {
  case queue, waiting {
    [line, ..rest], Some(reader) -> {
      process.send(reader, line)
      pump(inbox, rest, None)
    }
    _, _ ->
      case process.receive_forever(inbox) {
        Push(line) -> pump(inbox, list.append(queue, [line]), waiting)
        Pull(reader) -> pump(inbox, queue, Some(reader))
      }
  }
}

/// Starts the real server loop with subjects for standard input and output.
fn launch(config: server.Config) -> Client {
  let stdin = start_pipe()
  let stdout = process.new_subject()
  let done = process.new_subject()
  let transport =
    server.Transport(
      read_line: fn() {
        let reply = process.new_subject()
        process.send(stdin, Pull(reply))
        case process.receive_forever(reply) {
          Some(line) -> Ok(line)
          None -> Error(Nil)
        }
      },
      write_line: fn(frame) { process.send(stdout, frame) },
    )
  let _server =
    process.spawn_unlinked(fn() {
      process.send(done, server.serve(config, transport))
    })
  Client(stdin:, stdout:, done:, config:)
}

/// Sends one line to the server.
fn send(client: Client, line: String) -> Nil {
  process.send(client.stdin, Push(Some(line)))
}

/// Sends a request and a notification in the client's role.
fn call(client: Client, id: Int, method: String, params: JsonValue) -> Nil {
  send(client, rpc.encode_request(rpc.NumberId(id), method, params))
}

fn notify(client: Client, method: String, params: JsonValue) -> Nil {
  send(client, rpc.encode_notification(method, params))
}

/// Reads and decodes the next frame the server wrote.
fn next_frame(client: Client) -> JsonValue {
  let assert Ok(line) = process.receive(client.stdout, frame_wait_ms)
    as "the server wrote a frame within the failsafe"
  let assert Ok(frame) = json.parse(line)
    as "every frame the server writes is JSON"
  assert !string.contains(line, "\n")
  frame
}

fn member(value: JsonValue, name: String) -> JsonValue {
  let assert json.Object(fields) = value as "an object was expected"
  let assert Ok(found) = list.key_find(fields, name)
    as { "the member " <> name <> " is present" }
  found
}

fn has(value: JsonValue, name: String) -> Bool {
  case value {
    json.Object(fields) -> list.key_find(fields, name) != Error(Nil)
    _ -> False
  }
}

fn text_of(value: JsonValue) -> String {
  let assert json.String(text) = value as "a string was expected"
  text
}

/// What reading up to a response collected on the way.
type Exchange {
  Exchange(
    /// The `update` object of every `session/update`, in arrival order.
    updates: List(JsonValue),
    /// The params of every permission request the server made.
    asked: List(JsonValue),
    /// The response frame to the awaited id.
    response: JsonValue,
  )
}

/// Reads frames until the response to `id`, answering permission requests.
///
/// `answer` receives each `session/request_permission` params and returns
/// the result the client sends back, so a test chooses allow, deny or
/// dismissal without writing the loop again.
fn await(
  client: Client,
  id: Int,
  answer: fn(JsonValue) -> JsonValue,
) -> Exchange {
  collect(client, id, answer, Exchange([], [], json.Null))
}

fn collect(
  client: Client,
  id: Int,
  answer: fn(JsonValue) -> JsonValue,
  so_far: Exchange,
) -> Exchange {
  let frame = next_frame(client)

  // Which kind of frame this is decides what the client does with it.
  case has(frame, "method"), has(frame, "id") {
    True, True -> {
      assert member(frame, "method")
        == json.String("session/request_permission")
      let params = member(frame, "params")
      let reply = answer(params)
      let assert json.Int(request_id) = member(frame, "id")
        as "the server's request id is a number"
      send(client, rpc.encode_result(rpc.NumberId(request_id), reply))
      collect(
        client,
        id,
        answer,
        Exchange(..so_far, asked: list.append(so_far.asked, [params])),
      )
    }
    True, False -> {
      assert member(frame, "method") == json.String("session/update")
      let update = member(member(frame, "params"), "update")
      collect(
        client,
        id,
        answer,
        Exchange(..so_far, updates: list.append(so_far.updates, [update])),
      )
    }
    False, _ -> {
      assert member(frame, "id") == json.Int(id)
      Exchange(..so_far, response: frame)
    }
  }
}

fn refuse_everything(_params: JsonValue) -> JsonValue {
  panic as "no permission request was expected"
}

fn selecting(option_id: String) -> fn(JsonValue) -> JsonValue {
  fn(_params) {
    json.Object([
      #(
        "outcome",
        json.Object([
          #("outcome", json.String("selected")),
          #("optionId", json.String(option_id)),
        ]),
      ),
    ])
  }
}

fn initialize(client: Client) -> Nil {
  call(
    client,
    1,
    "initialize",
    json.Object([
      #("protocolVersion", json.Int(1)),
      #("clientCapabilities", json.Object([])),
    ]),
  )
  let done = await(client, 1, refuse_everything)
  assert member(member(done.response, "result"), "protocolVersion")
    == json.Int(1)
}

fn new_session(client: Client, id: Int, cwd: String) -> String {
  call(
    client,
    id,
    "session/new",
    json.Object([#("cwd", json.String(cwd)), #("mcpServers", json.Array([]))]),
  )
  let done = await(client, id, refuse_everything)
  text_of(member(member(done.response, "result"), "sessionId"))
}

fn prompt(client: Client, id: Int, session: String, text: String) -> Nil {
  call(
    client,
    id,
    "session/prompt",
    json.Object([
      #("sessionId", json.String(session)),
      #(
        "prompt",
        json.Array([
          json.Object([
            #("type", json.String("text")),
            #("text", json.String(text)),
          ]),
        ]),
      ),
    ]),
  )
}

/// Hangs up and waits for the server to retire its sessions and return.
fn hang_up(client: Client) -> Int {
  process.send(client.stdin, Push(None))
  let assert Ok(status) = process.receive(client.done, 60_000)
    as "the server retires its sessions and returns"
  status
}

/// Every `agent_message_chunk` text among the updates, joined.
fn spoken(updates: List(JsonValue)) -> String {
  updates
  |> list.filter(fn(update) {
    member(update, "sessionUpdate") == json.String("agent_message_chunk")
  })
  |> list.map(fn(update) { text_of(member(member(update, "content"), "text")) })
  |> string.join("")
}

fn kinds(updates: List(JsonValue)) -> List(String) {
  list.map(updates, fn(update) { text_of(member(update, "sessionUpdate")) })
}

/// The daemon's own account of whether a session was left saved.
fn saved(config: server.Config, session: String) -> Bool {
  let assert Ok(connected) =
    bootstrap.resolve_daemon(config.options, process.self(), 40_000)
    as "the daemon is still reachable"
  let reply =
    daemon.request(connected.control, protocol.GetSession(session), 5000)
  daemon.close(connected.control)

  case reply {
    Ok(protocol.SessionReply(protocol.Session(status: protocol.Saved, ..))) ->
      True
    _ -> False
  }
}

/// Whether the daemon holds the session resident right now.
fn resident(config: server.Config, session: String) -> Bool {
  let assert Ok(connected) =
    bootstrap.resolve_daemon(config.options, process.self(), 40_000)
    as "the daemon is still reachable"
  let reply =
    daemon.request(connected.control, protocol.GetSession(session), 5000)
  daemon.close(connected.control)

  case reply {
    Ok(protocol.SessionReply(protocol.Session(status: protocol.Resident(_), ..))) ->
      True
    _ -> False
  }
}

/// A `session/load` request for `session`, naming `cwd`.
fn load(client: Client, id: Int, session: String, cwd: String) -> Exchange {
  call(
    client,
    id,
    "session/load",
    json.Object([
      #("sessionId", json.String(session)),
      #("cwd", json.String(cwd)),
      #("mcpServers", json.Array([])),
    ]),
  )
  await(client, id, refuse_everything)
}

fn error_code_of(done: Exchange) -> Int {
  let assert json.Int(code) = member(member(done.response, "error"), "code")
    as "the response is an error with a numeric code"
  code
}

fn skip(reason: String) -> Nil {
  io.println_error("SKIP loom acp: " <> reason)
}

// --- the tests ---------------------------------------------------------------

pub fn a_text_turn_answers_once_reports_usage_and_leaves_the_session_saved_test_() -> EunitTest {
  Timeout(90, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory("loom-acp-text", 720_000)
        let #(outcome, report) =
          provider_http.with_server(
            [provider_http.Exchange("hello", "hi there")],
            fn(url) {
              let fixture = fixture(directory, url)
              let config = config_for(shipped, fixture)
              let client = launch(config)
              initialize(client)
              let session = new_session(client, 2, fixture.workspace)
              prompt(client, 3, session, "hello")
              let turn = await(client, 3, refuse_everything)
              let status = hang_up(client)
              #(config, session, turn, status)
            },
          )
        let assert Ok(_) = report as "the scripted provider answered once"
        let #(config, session, turn, status) = outcome

        assert status == 0
        assert spoken(turn.updates) == "hi there"
        let result = member(turn.response, "result")
        assert member(result, "stopReason") == json.String("end_turn")
        assert has(member(result, "usage"), "inputTokens")
        assert list.contains(kinds(turn.updates), "usage_update")
        assert saved(config, session)
      }
    }
  })
}

// A write outside the session's workspace, which the broker cannot clear
// without a grant. `fs_write` documents "outside session access requires
// approval", so the call escalates; the fixture never needs the write to
// succeed, only to be asked about. The path is absolute, below the package's
// build directory and outside every workspace the fixtures create.
fn outside_path(label: String) -> String {
  let assert Ok(build) = native.canonical_directory("build")
    as "the package build directory exists"
  build <> "/loom-acp-outside/" <> label <> ".txt"
}

fn gated_script(label: String) -> List(provider_http.Exchange) {
  [
    provider_http.ToolUseExchange(
      "run it",
      "c-perm",
      "fs_write",
      json.Object([
        #("path", json.String(outside_path(label))),
        #("content", json.String("ACP-APPROVED\n")),
      ]),
    ),
    provider_http.ComputedExchange(
      provider_http.AwaitAnyToolResult("c-perm"),
      fn(_) { provider_http.ReplyText("settled") },
    ),
  ]
}

/// The tool-call updates for one call id, in order, as `#(kind, status)`.
fn lifecycle(
  updates: List(JsonValue),
  call_id: String,
) -> List(#(String, String)) {
  updates
  |> list.filter(fn(update) {
    has(update, "toolCallId")
    && member(update, "toolCallId") == json.String(call_id)
  })
  |> list.map(fn(update) {
    #(
      text_of(member(update, "sessionUpdate")),
      text_of(member(update, "status")),
    )
  })
}

pub fn a_paced_answer_streams_in_pieces_and_is_not_repeated_when_it_commits_test_() -> EunitTest {
  Timeout(90, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory(
          "loom-acp-paced",
          720_000,
        )
        let answer = "streamed in several pieces so fragments arrive live"
        let #(turn, report) =
          provider_http.with_server(
            [
              provider_http.PacedExchange(
                "hello",
                answer,
                provider_http.Paced(gap_ms: 150),
              ),
            ],
            fn(url) {
              let fixture = fixture(directory, url)
              let client = launch(config_for(shipped, fixture))
              initialize(client)
              let session = new_session(client, 2, fixture.workspace)
              prompt(client, 3, session, "hello")
              let turn = await(client, 3, refuse_everything)
              let _ = hang_up(client)
              turn
            },
          )
        let assert Ok(_) = report as "the scripted provider answered once"

        // Pushed fragments and the committed message carry the same words;
        // the client must see them once, and see them as more than one piece.
        assert spoken(turn.updates) == answer
        let pieces =
          list.count(kinds(turn.updates), fn(kind) {
            kind == "agent_message_chunk"
          })
        assert pieces > 1
      }
    }
  })
}

pub fn an_approved_tool_call_runs_through_a_permission_round_trip_test_() -> EunitTest {
  Timeout(120, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory(
          "loom-acp-allow",
          960_000,
        )
        let #(outcome, report) =
          provider_http.with_server_for(
            gated_script("allow"),
            provider_http.AlsoFailed,
            110_000,
            fn(url) {
              let fixture = fixture(directory, url)
              let client = launch(config_for(shipped, fixture))
              initialize(client)
              let session = new_session(client, 2, fixture.workspace)
              prompt(client, 3, session, "run it")
              let turn = await(client, 3, selecting("allow"))
              let status = hang_up(client)
              #(turn, status)
            },
          )
        let assert Ok(_) = report as "the scripted provider answered twice"
        let #(turn, status) = outcome

        assert status == 0
        let assert [ask] = turn.asked
        let call = member(ask, "toolCall")
        assert string.starts_with(
          text_of(member(call, "toolCallId")),
          "escalation-",
        )
        let offered =
          list.map(
            case member(ask, "options") {
              json.Array(options) -> options
              _ -> []
            },
            fn(option) { text_of(member(option, "optionId")) },
          )
        assert list.contains(offered, "allow")
        assert list.contains(offered, "reject")

        // The call is announced pending, then finishes one way or the other:
        // after a grant the helper may run it or the host may lack a jail
        // layer, and this test is about consent ordering, not confinement.
        let steps = lifecycle(turn.updates, "c-perm")
        let assert [#("tool_call", "pending"), ..rest] = steps
        let assert Ok(#(_, last)) = list.last(rest)
        assert list.contains(["completed", "failed"], last)
        assert spoken(turn.updates) == "settled"
        assert member(member(turn.response, "result"), "stopReason")
          == json.String("end_turn")
      }
    }
  })
}

pub fn a_denied_tool_call_fails_and_the_turn_still_ends_test_() -> EunitTest {
  Timeout(120, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory("loom-acp-deny", 960_000)
        let #(outcome, report) =
          provider_http.with_server_for(
            gated_script("deny"),
            provider_http.AlsoFailed,
            110_000,
            fn(url) {
              let fixture = fixture(directory, url)
              let client = launch(config_for(shipped, fixture))
              initialize(client)
              let session = new_session(client, 2, fixture.workspace)
              prompt(client, 3, session, "run it")
              let turn = await(client, 3, selecting("reject"))
              let status = hang_up(client)
              #(turn, status)
            },
          )
        let assert Ok(_) = report as "the scripted provider answered twice"
        let #(turn, status) = outcome

        assert status == 0
        assert list.length(turn.asked) == 1
        let steps = lifecycle(turn.updates, "c-perm")
        let assert Ok(#(_, last)) = list.last(steps)
        assert last == "failed"
        assert spoken(turn.updates) == "settled"
      }
    }
  })
}

pub fn a_cancel_during_a_stalled_response_ends_the_turn_cancelled_test_() -> EunitTest {
  Timeout(120, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory(
          "loom-acp-cancel",
          960_000,
        )
        let port = process.new_subject()
        let accepted = process.new_subject()
        let peer = process.spawn_unlinked(fn() { stall(port, accepted) })
        let assert Ok(port) = process.receive(port, 5000)
          as "the stalling provider published its port"
        let fixture =
          fixture(directory, "http://127.0.0.1:" <> int.to_string(port))
        let config = config_for(shipped, fixture)
        let client = launch(config)
        initialize(client)
        let session = new_session(client, 2, fixture.workspace)

        // The provider accepts the request and then says nothing, so the run
        // is provably in flight when the cancel arrives.
        prompt(client, 3, session, "hello")
        process.sleep(2500)
        notify(
          client,
          "session/cancel",
          json.Object([#("sessionId", json.String(session))]),
        )
        let turn = await(client, 3, refuse_everything)

        // The provider accepted the request, so the run was in flight and the
        // reply could only come from an abort that was actually sent: the
        // stalled response never ends by itself.
        let assert Ok(Nil) = process.receive(accepted, 1000)
          as "the run reached the provider before the cancel"
        let status = hang_up(client)
        process.kill(peer)

        assert status == 0
        assert member(member(turn.response, "result"), "stopReason")
          == json.String("cancelled")
        assert saved(config, session)
      }
    }
  })
}

pub fn a_saved_session_loads_and_replays_its_transcript_test_() -> EunitTest {
  Timeout(120, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory("loom-acp-load", 960_000)
        let #(outcome, report) =
          provider_http.with_server(
            [provider_http.Exchange("hello", "hi there")],
            fn(url) {
              let fixture = fixture(directory, url)
              let config = config_for(shipped, fixture)

              // The first connection makes the session, runs a turn and hangs
              // up, which leaves the session saved.
              let first = launch(config)
              initialize(first)
              let session = new_session(first, 2, fixture.workspace)
              prompt(first, 3, session, "hello")
              let _ = await(first, 3, refuse_everything)
              let _ = hang_up(first)

              // A second connection resumes it by id.
              let second = launch(config)
              initialize(second)
              call(
                second,
                2,
                "session/load",
                json.Object([
                  #("sessionId", json.String(session)),
                  #("cwd", json.String(fixture.workspace)),
                  #("mcpServers", json.Array([])),
                ]),
              )
              let loaded = await(second, 2, refuse_everything)

              // Waking a parked session makes it resident; it is this
              // connection's to stop again when the connection ends.
              let held = resident(config, session)
              let status = hang_up(second)
              #(session, loaded, status, config, held)
            },
          )
        let assert Ok(_) = report as "the scripted provider answered once"
        let #(session, loaded, status, config, held) = outcome
        assert held

        assert status == 0
        assert !has(member(loaded.response, "result"), "sessionId")
        let replayed = kinds(loaded.updates)
        assert list.contains(replayed, "user_message_chunk")
        assert spoken(loaded.updates) == "hi there"
        assert saved(config, session)
      }
    }
  })
}

pub fn a_session_reports_its_models_and_switches_by_catalogue_name_test_() -> EunitTest {
  Timeout(90, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory(
          "loom-acp-models",
          720_000,
        )
        let #(outcome, report) =
          provider_http.with_server([], fn(url) {
            let fixture = fixture(directory, url)
            let client = launch(config_for(shipped, fixture))
            initialize(client)
            call(
              client,
              2,
              "session/new",
              json.Object([
                #("cwd", json.String(fixture.workspace)),
                #("mcpServers", json.Array([])),
              ]),
            )
            let created = await(client, 2, refuse_everything)
            let session =
              text_of(member(member(created.response, "result"), "sessionId"))
            call(
              client,
              3,
              "session/set_model",
              json.Object([
                #("sessionId", json.String(session)),
                #("modelId", json.String("fixture")),
              ]),
            )
            let switched = await(client, 3, refuse_everything)
            call(
              client,
              4,
              "session/set_model",
              json.Object([
                #("sessionId", json.String(session)),
                #("modelId", json.String("no-such-model")),
              ]),
            )
            let refused = await(client, 4, refuse_everything)

            // The same switch through the option form current SDKs use.
            call(
              client,
              5,
              "session/set_config_option",
              json.Object([
                #("sessionId", json.String(session)),
                #("configId", json.String("model")),
                #("value", json.String("fixture")),
              ]),
            )
            let optioned = await(client, 5, refuse_everything)
            call(
              client,
              6,
              "session/set_config_option",
              json.Object([
                #("sessionId", json.String(session)),
                #("configId", json.String("thinking")),
                #("value", json.String("high")),
              ]),
            )
            let unknown = await(client, 6, refuse_everything)
            let status = hang_up(client)
            #(created, switched, refused, optioned, unknown, status)
          })
        let assert Ok(_) = report as "the provider was never asked"
        let #(created, switched, refused, optioned, unknown, status) = outcome

        assert status == 0
        let models = member(member(created.response, "result"), "models")
        assert member(models, "currentModelId") == json.String("fixture")
        assert member(switched.response, "result") == json.Object([])
        assert member(member(refused.response, "error"), "code")
          == json.Int(rpc.invalid_params)

        // The catalogue is also offered as a select option of category model.
        let assert json.Array([option]) =
          member(member(created.response, "result"), "configOptions")
        assert member(option, "category") == json.String("model")
        assert member(option, "currentValue") == json.String("fixture")
        let assert json.Array([current]) =
          member(member(optioned.response, "result"), "configOptions")
        assert member(current, "currentValue") == json.String("fixture")
        assert member(member(unknown.response, "error"), "code")
          == json.Int(rpc.invalid_params)
      }
    }
  })
}

pub fn a_session_found_resident_is_left_resident_when_the_loader_hangs_up_test_() -> EunitTest {
  Timeout(120, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory(
          "loom-acp-shared",
          960_000,
        )
        let #(outcome, report) =
          provider_http.with_server([], fn(url) {
            let fixture = fixture(directory, url)
            let config = config_for(shipped, fixture)

            // The first connection makes the session and keeps it.
            let owner = launch(config)
            initialize(owner)
            let session = new_session(owner, 2, fixture.workspace)

            // A second connection loads it while it is resident, then leaves.
            let visitor = launch(config)
            initialize(visitor)
            let loaded = load(visitor, 2, session, fixture.workspace)
            let _ = hang_up(visitor)
            let still_resident = resident(config, session)

            let _ = hang_up(owner)
            #(loaded, still_resident, saved(config, session))
          })
        let assert Ok(_) = report as "the provider was never asked"
        let #(loaded, still_resident, saved_at_end) = outcome

        assert has(loaded.response, "result")
        assert still_resident
        assert saved_at_end
      }
    }
  })
}

pub fn a_load_outside_the_roots_is_refused_before_the_session_is_woken_test_() -> EunitTest {
  Timeout(120, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory(
          "loom-acp-outside",
          960_000,
        )
        let #(outcome, report) =
          provider_http.with_server([], fn(url) {
            let fixture = fixture(directory, url)
            let config = config_for(shipped, fixture)
            let first = launch(config)
            initialize(first)
            let session = new_session(first, 2, fixture.workspace)
            let _ = hang_up(first)

            // A server whose only root is elsewhere must refuse the load
            // without ever opening the parked session.
            let elsewhere =
              offline_config(
                "build/loom-acp-elsewhere-"
                <> int.to_string(native.system_time_ms()),
              )
            let second = launch(server.Config(..config, roots: elsewhere.roots))
            initialize(second)
            let refused = load(second, 2, session, fixture.workspace)
            let woken = resident(config, session)
            let _ = hang_up(second)
            #(refused, woken, saved(config, session))
          })
        let assert Ok(_) = report as "the provider was never asked"
        let #(refused, woken, saved_at_end) = outcome

        assert error_code_of(refused) == rpc.invalid_params
        assert !woken
        assert saved_at_end
      }
    }
  })
}

pub fn a_load_naming_another_cwd_is_reported_not_ignored_test_() -> EunitTest {
  Timeout(120, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory("loom-acp-cwd", 960_000)
        let #(outcome, report) =
          provider_http.with_server([], fn(url) {
            let fixture = fixture(directory, url)
            let config =
              server.Config(..config_for(shipped, fixture), roots: [
                fixture.directory,
              ])
            let first = launch(config)
            initialize(first)
            let session = new_session(first, 2, fixture.workspace)
            let _ = hang_up(first)

            // The directory is inside a root but is not the session's own.
            let second = launch(config)
            initialize(second)
            let refused = load(second, 2, session, fixture.directory)
            let woken = resident(config, session)
            let _ = hang_up(second)
            #(refused, woken)
          })
        let assert Ok(_) = report as "the provider was never asked"
        let #(refused, woken) = outcome

        assert error_code_of(refused) == rpc.invalid_params
        assert !woken
      }
    }
  })
}

pub fn loading_a_session_this_connection_already_holds_is_refused_test_() -> EunitTest {
  Timeout(120, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory(
          "loom-acp-twice",
          960_000,
        )
        let #(outcome, report) =
          provider_http.with_server([], fn(url) {
            let fixture = fixture(directory, url)
            let config = config_for(shipped, fixture)
            let client = launch(config)
            initialize(client)
            let session = new_session(client, 2, fixture.workspace)
            let again = load(client, 3, session, fixture.workspace)
            let _ = hang_up(client)
            #(again, saved(config, session))
          })
        let assert Ok(_) = report as "the provider was never asked"
        let #(again, saved_at_end) = outcome

        assert error_code_of(again) == rpc.invalid_params
        // The first attach kept its custody, so ending the connection saved it.
        assert saved_at_end
      }
    }
  })
}

pub fn several_sessions_are_stopped_together_when_the_client_hangs_up_test_() -> EunitTest {
  Timeout(120, fn() {
    case shipped_server.from_environment() {
      Error(Nil) -> skip("LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(shipped) -> {
        use directory <- native_fixture.with_directory("loom-acp-many", 960_000)
        let #(outcome, report) =
          provider_http.with_server([], fn(url) {
            let fixture = fixture(directory, url)
            let config = config_for(shipped, fixture)
            let client = launch(config)
            initialize(client)
            let one = new_session(client, 2, fixture.workspace)
            let two = new_session(client, 3, fixture.workspace)
            let while_attached = #(resident(config, one), resident(config, two))
            let _ = hang_up(client)
            #(while_attached, saved(config, one), saved(config, two))
          })
        let assert Ok(_) = report as "the provider was never asked"
        let #(while_attached, first_saved, second_saved) = outcome

        assert while_attached == #(True, True)
        assert first_saved
        assert second_saved
      }
    }
  })
}

// --- frames the server must refuse without dying -----------------------------

/// A config for tests that never reach the daemon: nothing here starts one.
fn offline_config(directory: String) -> server.Config {
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the offline fixture has a private directory"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the offline fixture uses absolute paths"
  server.Config(
    options: bootstrap.Options(
      directory,
      "",
      "/nonexistent/loomd",
      filepath.join(directory, "state"),
      "",
      "",
      placement.OnThisHost,
    ),
    roots: [directory],
    names: [],
    version: "test",
  )
}

fn error_code(frame: JsonValue) -> Int {
  let assert json.Int(code) = member(member(frame, "error"), "code")
    as "an error response carries a numeric code"
  code
}

pub fn malformed_and_premature_frames_are_refused_and_the_server_lives_test() {
  let root = "build/loom-acp-offline-" <> int.to_string(native.system_time_ms())
  let config = offline_config(root)
  let client = launch(config)

  // Not JSON at all: -32700, addressed to a null id.
  send(client, "this is not json")
  let garbage = next_frame(client)
  assert error_code(garbage) == rpc.parse_error
  assert member(garbage, "id") == json.Null

  // Valid JSON but not a frame: -32600.
  send(client, "[1,2,3]")
  assert error_code(next_frame(client)) == rpc.invalid_request

  // A request before `initialize` is out of order, and says so by its own id.
  call(client, 7, "session/new", json.Object([#("cwd", json.String("/x"))]))
  let early = next_frame(client)
  assert error_code(early) == rpc.invalid_request
  assert member(early, "id") == json.Int(7)

  // After initialize, the server still answers; an unknown method is -32601.
  initialize(client)
  call(client, 8, "fs/teleport", json.Object([]))
  let unknown = next_frame(client)
  assert error_code(unknown) == rpc.method_not_found
  assert member(unknown, "id") == json.Int(8)

  // Known method, wrong params: -32602 under the request's id.
  call(client, 9, "session/prompt", json.Object([]))
  assert error_code(next_frame(client)) == rpc.invalid_params

  // An unknown session is a missing resource, not a crash.
  call(
    client,
    10,
    "session/prompt",
    json.Object([
      #("sessionId", json.String("nope")),
      #(
        "prompt",
        json.Array([
          json.Object([
            #("type", json.String("text")),
            #("text", json.String("hi")),
          ]),
        ]),
      ),
    ]),
  )
  assert error_code(next_frame(client)) == rpc.resource_not_found

  // A notification that is unknown is dropped without an answer, so the next
  // frame is the answer to the request sent after it.
  notify(client, "session/dance", json.Object([]))
  call(
    client,
    11,
    "authenticate",
    json.Object([#("methodId", json.String("x"))]),
  )
  let auth = next_frame(client)
  assert member(auth, "id") == json.Int(11)
  assert error_code(auth) == rpc.invalid_params

  assert hang_up(client) == 0
}

pub fn an_oversized_frame_is_refused_and_the_next_frame_still_works_test() {
  let root = "build/loom-acp-big-" <> int.to_string(native.system_time_ms())
  let client = launch(offline_config(root))
  let padding = string.repeat("a", rpc.max_frame_bytes)

  send(
    client,
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"pad\":\""
      <> padding
      <> "\"}}",
  )
  let refused = next_frame(client)
  assert error_code(refused) == rpc.invalid_request
  assert member(refused, "id") == json.Null

  initialize(client)
  assert hang_up(client) == 0
}

pub fn a_version_the_server_cannot_speak_fails_initialize_not_the_process_test() {
  let root = "build/loom-acp-ver-" <> int.to_string(native.system_time_ms())
  let client = launch(offline_config(root))

  call(
    client,
    1,
    "initialize",
    json.Object([#("protocolVersion", json.Int(0))]),
  )
  assert error_code(next_frame(client)) == rpc.invalid_params

  // A newer client is answered with the version this server speaks.
  call(
    client,
    2,
    "initialize",
    json.Object([#("protocolVersion", json.Int(7))]),
  )
  let answered = next_frame(client)
  assert member(member(answered, "result"), "protocolVersion") == json.Int(1)
  assert hang_up(client) == 0
}

pub fn the_workspace_gate_and_the_refused_extensions_stop_a_session_before_it_exists_test() {
  let root = "build/loom-acp-gate-" <> int.to_string(native.system_time_ms())
  let config = offline_config(root)
  let client = launch(config)
  initialize(client)
  let inside = config.roots

  // A path outside every operator root is refused, and no daemon is asked.
  call(client, 2, "session/new", json.Object([#("cwd", json.String("/"))]))
  assert error_code(next_frame(client)) == rpc.invalid_params

  // So is a relative path, and a path that does not exist.
  call(client, 3, "session/new", json.Object([#("cwd", json.String("repo"))]))
  assert error_code(next_frame(client)) == rpc.invalid_params
  let missing = case inside {
    [first, ..] -> first <> "/missing"
    [] -> "/missing"
  }
  call(client, 4, "session/new", json.Object([#("cwd", json.String(missing))]))
  assert error_code(next_frame(client)) == rpc.invalid_params

  // A per-session MCP server is named in a refusal, not silently dropped.
  let servers =
    json.Array([
      json.Object([
        #("name", json.String("lint")),
        #("command", json.String("lint-mcp")),
      ]),
    ])
  call(
    client,
    5,
    "session/new",
    json.Object([
      #("cwd", json.String(missing)),
      #("mcpServers", servers),
    ]),
  )
  let mcp = next_frame(client)
  assert error_code(mcp) == rpc.invalid_params
  assert string.contains(
    text_of(member(member(mcp, "error"), "message")),
    "lint",
  )

  // The guidance opt-out cannot be honoured yet, so it is refused too.
  call(
    client,
    6,
    "session/new",
    json.Object([
      #("cwd", json.String(missing)),
      #(
        "_meta",
        json.Object([
          #("loom", json.Object([#("project_instructions", json.Bool(False))])),
        ]),
      ),
    ]),
  )
  let guidance = next_frame(client)
  assert error_code(guidance) == rpc.invalid_params
  assert string.contains(
    text_of(member(member(guidance, "error"), "message")),
    "project_instructions",
  )

  // A registered workspace the operator did not list is refused, too.
  call(
    client,
    7,
    "session/new",
    json.Object([
      #("cwd", json.String(missing)),
      #(
        "_meta",
        json.Object([
          #(
            "loom",
            json.Object([
              #("workspace", json.String("repo")),
              #("executor", json.String("builder")),
            ]),
          ),
        ]),
      ),
    ]),
  )
  assert error_code(next_frame(client)) == rpc.invalid_params

  assert hang_up(client) == 0
}

// A provider that begins a response and then never finishes it, for as long
// as the client keeps the connection, so a run is provably in flight. It is
// killed by the test, which closes its sockets with it.
fn stall(port: Subject(Int), accepted: Subject(Nil)) -> Nil {
  let assert Ok(listener) =
    socket.tcp_listen(0, [socket.Binary, socket.Active(False)])
    as "the stalling provider owns a listener"
  let assert Ok(bound) = socket.tcp_port(listener)
    as "the listener has a bound port"
  process.send(port, bound)
  hold(listener, accepted)
}

fn hold(listener: socket.Socket, accepted: Subject(Nil)) -> Nil {
  let assert Ok(peer) = socket.tcp_accept(listener, 120_000)
    as "the run's provider request connects"
  process.send(accepted, Nil)
  let head =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
  let assert Ok(Nil) = tcp.send(peer, bit_array.from_string(head))
    as "the response head is written"
  let _ = socket.tcp_receive(peer, 0, 120_000)
  hold(listener, accepted)
}
