//// `loom run -p` against the shipped daemon: the falsifier of issue #492's
//// headless client, run in-process through `run.conduct` so the report is
//// data and not a line to scrape.
////
//// Two drives, each a real `bin/loomd` launched through the isolated
//// launcher (`shipped_server`, an empty private home) and a finite loopback
//// provider. A scripted answer must end `completed` with the session id, the
//// usage and a jail label that is always present. A provider that never
//// finishes its response must end `timeout` at the deadline, after which the
//// daemon must report the session saved: stopped, not left resident.
////
//// The third falsifier, a missing daemon exiting 3, needs no daemon and
//// lives in the tui package's `run_test`.

import client/tui_e2e_test.{type EunitTest, Timeout}
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None}
import gleam/string
import host/bootstrap as native
import simplifile
import support/internal/ffi_daemon_socket as tcp
import support/internal/ffi_ws as socket
import support/provider_http
import support/shipped_server
import tui/bootstrap
import tui/daemon
import tui/daemon/protocol
import tui/placement
import tui/run

fn workspace(label: String, provider_url: String) -> #(String, String) {
  let directory =
    "build/loom-run-"
    <> label
    <> "-"
    <> int.to_string(native.current_process_id())
    <> "-"
    <> int.to_string(native.system_time_ms())
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "fixture state lives below a private directory"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the daemon receives absolute fixture paths"
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
  #(directory, filepath.join(directory, "fixture.toml"))
}

fn request(
  server: String,
  directory: String,
  config: String,
  timeout_ms: Int,
  prompt: String,
) -> run.Request {
  run.Request(
    options: bootstrap.Options(
      filepath.join(directory, "workspace"),
      "",
      server,
      filepath.join(directory, "state"),
      config,
      "",
      placement.OnThisHost,
    ),
    prompt:,
    timeout_ms:,
    model: None,
    retention: run.StopAtExit,
  )
}

pub fn a_scripted_answer_completes_with_a_labelled_jail_test_() -> EunitTest {
  Timeout(15, fn() {
    case shipped_server.from_environment() {
      Error(Nil) ->
        io.println_error("SKIP loom run: LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(server) -> {
        let #(conducted, report) =
          provider_http.with_server(
            [provider_http.Exchange("hello", "hi there")],
            fn(url) {
              let #(directory, config) = workspace("done", url)
              run.conduct(request(server, directory, config, 60_000, "hello"))
            },
          )
        let assert Ok(_) = report as "the scripted provider answered once"
        let assert run.Ran(done) = conducted
          as "a daemon, a session and a verdict"

        assert done.verdict == run.Completed
        assert run.exit_code(done.verdict) == 0
        assert done.session_id != ""
        assert done.usage != None
        assert done.turns >= 1
        let line = run.render(done)
        assert !string.contains(line, "\n")
        assert string.contains(line, "\"jail\":{\"posture\":\"")
        assert string.contains(line, "\"session_id\":\"" <> done.session_id)
      }
    }
  })
}

pub fn a_stalled_provider_times_out_and_the_session_is_stopped_test_() -> EunitTest {
  Timeout(15, fn() {
    case shipped_server.from_environment() {
      Error(Nil) ->
        io.println_error("SKIP loom run: LOOM_BOOTSTRAP_E2E_SERVER is unset")
      Ok(server) -> {
        let port = process.new_subject()
        let peer = process.spawn_unlinked(fn() { stall(port) })
        let assert Ok(port) = process.receive(port, 5000)
          as "the stalling provider published its port"
        let url = "http://127.0.0.1:" <> int.to_string(port)
        let #(directory, config) = workspace("stall", url)
        let asked = request(server, directory, config, 2000, "hello")
        let conducted = run.conduct(asked)
        process.kill(peer)

        let assert run.Ran(done) = conducted
          as "the deadline ends the run with a report"
        assert done.verdict == run.TimedOut
        assert run.exit_code(done.verdict) == 124
        assert saved(asked, done.session_id)
      }
    }
  })
}

// A provider that begins a response and then never finishes it, for as long
// as the client keeps the connection. It exists because the run must end on
// its own deadline: nothing the provider does can end it first. The process
// is killed by the test, which closes its sockets with it.
fn stall(port: process.Subject(Int)) -> Nil {
  let assert Ok(listener) =
    socket.tcp_listen(0, [socket.Binary, socket.Active(False)])
    as "the stalling provider owns a listener"
  let assert Ok(bound) = socket.tcp_port(listener)
    as "the listener has a bound port"
  process.send(port, bound)
  hold(listener)
}

fn hold(listener: socket.Socket) -> Nil {
  let assert Ok(peer) = socket.tcp_accept(listener, 120_000)
    as "the run's provider request connects"
  let head =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
  let assert Ok(Nil) = tcp.send(peer, bit_array.from_string(head))
    as "the response head is written"
  let _ = socket.tcp_receive(peer, 0, 120_000)
  hold(listener)
}

// The daemon's own account of the session after the command returned.
fn saved(asked: run.Request, session: String) -> Bool {
  let assert Ok(connected) =
    bootstrap.resolve_daemon(asked.options, process.self(), 40_000)
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
