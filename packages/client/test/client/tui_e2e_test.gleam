//// The real TUI against the real server, in a terminal (issue #7).
////
//// Every other end-to-end in this tree has a fake on one side. The
//// protocol conformance suite pins both implementations to one fixture
//// corpus; `packages/tui`'s own end-to-end drives the bubbletea model
//// against a Go fake gateway; `client/demo` drives the real gateway with
//// a Gleam client. A fake on both sides of a protocol proves the
//// fixture, not the protocol — so this one has a fake on *neither*:
////
////  - the server is `client/serve.boot`, the same boot `gleam run -m
////    client/serve` performs, on an ephemeral port with a real `mist`
////    listener, a real SQLite session and a real minted bearer token;
////  - the client is `bin/loom-tui`, built from `packages/tui` by this
////    test so the artifact under test cannot be stale, running under a
////    real terminal in `tmux` and driven only by keystrokes;
////  - only the *model* is scripted, through `Settings.gateway` — a
////    transport that answers with an Anthropic SSE transcript. No API
////    key is needed and nothing dials out.
////
//// What that buys is an assertion no other test can make: the words
//// typed into a terminal become a `prompt` command, a durable entry, a
//// provider request whose body carries them, an assistant entry, an
//// `entry` event, and finally pixels in a pane. The answer text is
//// *conditional on the request body* — the scripted transport answers
//// with the marker only when the typed prompt is in the request it was
//// handed — so the marker appearing in the pane is proof of the whole
//// round trip rather than of a fixture.
////
//// ## The failures this must be able to tell apart
////
//// A terminal test that can only time out is not worth having. Each
//// stage here fails in its own voice: `serve.boot` returning an error
//// is "the server never started"; `gateway.attached` staying at zero is
//// "the TUI never attached", reported with the TUI's own stderr; a
//// second, independent websocket subscribe that cannot see the assistant
//// entry is "the server never committed it", which separates a server
//// fault from a client one; and only after that does a bare pane read as
//// "the frames never reached the pane". The escalation stages add two
//// more: "the tool call never became a refusal" is separate from "the
//// refusal never reached the pane", which is separate again from the
//// record naming exactly which status it stopped at. Every one of them
//// dumps the pane.
////
//// ## The parked call, which is the point
////
//// Since a policy refusal parks only when someone is attached, the
//// *presence of a real client* is now semantically significant: a
//// headless session settles the same refusal in band. Nothing tested
//// that. Every approval anywhere else in this tree is an in-process
//// `api.approve_escalation`, and every parking test injects
//// `interactive` as `fn() { True }` or `fn() { False }` — so no test had
//// ever watched a decision travel from a keystroke, over a websocket,
//// into a call that was standing at a door waiting for it.
////
//// This one does, and the assertion is `Consumed` rather than
//// `Approved`. The distinction is the whole proof.
//// `api.approve_escalation`, which is what the `approve` frame reaches,
//// only ever writes `Approved`. The CAS to `Consumed` is performed by
//// `client/escalate`'s park loop, on the refused call's own effect
//// process, at the moment it composes the granted policy and re-clears.
//// So `Approved` alone would mean the frame arrived and nothing was
//// waiting for it, and `Consumed` means a call that had already been
//// refused woke up and spent an approval that came in over the wire.
//// Both mutations were run: making the session non-interactive stops at
//// `Approved`, and deleting the TUI's `approve` send stops at `Pending`.
////
//// Reaching it needed one seam. Under `serve.base_policy` no shipped
//// tool can provoke a refusal at all — it grants read of `/`, writes to
//// the workspace, and the four environment names `bash` passes — so the
//// base is now a `Settings` field rather than a call inside `boot`, and
//// this test serves `policy.workspace_default`, under which `bash`'s
//// one uncovered requirement is a legible single wanted grant.
////
//// ## What this still does not reach
////
//// The *jailed* half. The re-cleared call dispatches into a helper that
//// is not `loom-exec`, so it fails its hello handshake and settles in
//// band; nothing here proves an approved call goes on to run under a
//// widened sandbox. That is `make e2e`'s job, and it has a real helper.

import broker/exec
import broker/policy
import client/catalog
import client/codemode
import client/gateway as hub
import client/protocol
import client/serve
import core/clock
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/http
import provider/model
import provider/secret
import runtime/api
import runtime/escalation as runtime_escalation
import simplifile
import support/internal/ffi_proc
import support/internal/ffi_ws
import support/terminal.{type Terminal}

const root = "build/tui-e2e"

const session_id = "session"

/// What is typed into the terminal, and what the scripted transport
/// looks for in the provider request before it will answer with the
/// marker.
const prompt_text = "answer the terminal probe"

/// The one token whose presence in the pane can only be explained by the
/// whole round trip. Deliberately a single alphanumeric word: glamour
/// word-wraps the assistant block, and a phrase could be split.
const assistant_marker = "skein7f3a"

/// The prompt that makes the scripted model reach for `bash`, and so
/// walks a real tool call into a policy refusal it cannot clear.
const tool_prompt_text = "run the probe command"

/// The token the scripted model answers with once the refused call has
/// come back to it — proof the resumed call settled and the turn closed,
/// rather than the strand being left holding a call forever.
const tool_marker = "warp91c2"

/// What the approval prompt must render, verbatim, for the one narrowing
/// `bash` provokes against the narrowed base: `bash` needs to read `/`
/// (interpreters and system libraries live outside the workspace) and the
/// base grants only the workspace. `proto.Grant.Display` in the Go client
/// is what turns the grant into these words.
const wanted_display = "read access to /"

const cols = 110

const rows = 34

/// The whole budget: a cold `go build` of the TUI, a boot, and a drive
/// whose own waits already sum to about a minute of deadline. eunit's
/// unchosen default — 5 s, which gleeunit scales to 50 — falls during the
/// `go build` on a cold module cache and reports `Timeout` at a line
/// number, which says nothing about the terminal. 420 s is roughly 7x the
/// slowest observed run and still well inside CI's cap.
const test_timeout_seconds = 420

/// gleeunit runs eunit with `ScaleTimeouts(10)` and that scale multiplies
/// *every* timeout, including one a generator asks for — so the number
/// handed to eunit is the number wanted divided by ten. Stated rather than
/// folded into the constant because the arithmetic is the trap: a reader
/// who takes `Timeout(420, _)` at face value would be setting seventy
/// minutes. (`packages/codemode`'s end-to-end records the same trap; the
/// two suites cannot share a constant across packages.)
const gleeunit_timeout_scale = 10

/// eunit's test representation, built in Gleam rather than through FFI: a
/// Gleam constructor with fields compiles to a tagged Erlang tuple, so
/// this is literally `{timeout, Seconds, Body}` — which eunit reads back
/// from a zero-arity `*_test_` *generator*. The trailing underscore is
/// what makes a timeout reachable from a gleeunit suite at all; a plain
/// `*_test` takes the default and cannot ask for more.
pub type EunitTest {
  Timeout(seconds: Int, body: fn() -> Nil)
}

pub fn the_real_tui_drives_the_real_server_test_() -> EunitTest {
  Timeout(test_timeout_seconds / gleeunit_timeout_scale, fn() {
    case prerequisites() {
      // On *stderr*, not stdout. eunit rebinds the group leader and
      // captures a passing test's stdout, so a skip announced with
      // `io.println` is swallowed by the very run it needs to warn —
      // the design note's "suite that always passes", arriving as a
      // green tick on a host that never opened a terminal. stderr is
      // not captured and reaches the log either way.
      Error(reason) ->
        io.println_error("SKIP the_real_tui_drives_the_real_server: " <> reason)
      Ok(ready) -> drive(ready)
    }
  })
}

// --- prerequisites ---------------------------------------------------------

type Ready {
  Ready(tmux: String, tui_path: String, workdir: String)
}

// `tmux` is feature-detected and `go` builds the binary under test. The
// build is done here rather than depended upon (`make binaries`) on
// purpose: a prerequisite a developer must remember is a prerequisite
// `make check` will skip, and a skipped end-to-end is exactly the
// vacuous pass this test exists to replace.
fn prerequisites() -> Result(Ready, String) {
  use tmux <- result.try(terminal.available())
  use go <- result.try(
    ffi_proc.which("go")
    |> result.replace_error("go is not on PATH, so loom-tui cannot be built"),
  )
  use workdir <- result.try(
    simplifile.current_directory()
    |> result.replace_error("the working directory is unreadable"),
  )
  use tui_path <- result.try(build_tui(go, workdir))
  Ok(Ready(tmux:, tui_path:, workdir:))
}

fn build_tui(go: String, workdir: String) -> Result(String, String) {
  let out = workdir <> "/" <> root <> "/loom-tui"
  let assert Ok(Nil) = simplifile.create_directory_all(workdir <> "/" <> root)
    as "the end-to-end's build directory must exist"
  case
    ffi_proc.run(
      go,
      ["build", "-o", out, "./cmd/loom-tui"],
      in: workdir <> "/../tui",
    )
  {
    Error(reason) -> Error("go build could not be started: " <> reason)
    Ok(#(0, _output)) -> Ok(out)
    Ok(#(status, output)) ->
      Error(
        "go build of loom-tui exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(output),
      )
  }
}

// --- the drive -------------------------------------------------------------

fn drive(ready: Ready) -> Nil {
  let _stale = simplifile.delete(root <> "/session.db")
  let _stale = simplifile.delete(root <> "/session.db.token")
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "the workspace must exist"

  // 1. The server. A boot failure is its own failure, with its own
  //    message, before any terminal exists to blame.
  let assert Ok(booted) = serve.boot(settings())
    as "the server must boot on an ephemeral port"
  let addr = "ws://127.0.0.1:" <> int.to_string(booted.served.port) <> "/v1/ws"

  // Nobody is attached yet, and the hub says so. This is the question
  // `client/serve` puts to the escalation seam on every park poll.
  assert hub.attached(booted.gateway) == 0
    as "a server nobody has dialled must count no connections"

  // 2. The real binary, in a real terminal.
  let term = launch(ready, addr, booted.served.token)

  // 3. It attached — over a websocket, with the token from the file the
  //    boot minted. Until this holds nothing else is worth asserting.
  case wait_until(fn() { hub.attached(booted.gateway) > 0 }, 150) {
    True -> Nil
    False -> {
      let pane = result.unwrap(terminal.capture(term), "")
      terminal.stop(term)
      serve.shutdown(booted)
      give_up(terminal.framed(
        "the TUI never attached: the hub still counts 0 connections."
          <> tui_diagnosis(),
        pane,
      ))
    }
  }
  assert hub.attached(booted.gateway) == 1 as "exactly one client is attached"

  // 4. The snapshot painted. `main: idle` is the status bar's strand
  //    segment, and the strand list behind it came from the snapshot —
  //    so this is already protocol traffic on screen, not an echo of a
  //    flag the client was given.
  let _painted =
    must_show(term, "main: idle", 15_000, "the snapshot never painted")

  // 5. A turn, typed. The marker can only come back if the words
  //    reached the provider request, so this one assertion covers the
  //    whole path out and back.
  let assert Ok(Nil) = terminal.type_text(term, prompt_text)
    as "the prompt must be typed into the pane"
  let assert Ok(Nil) = terminal.press(term, "Enter")
    as "Enter must reach the pane"

  // The pane is asked first and the *server* is asked only if the pane
  // came up empty — which is what makes the failure legible without
  // hammering the listener with a subscribe every hundred milliseconds
  // on the way to a pass.
  //
  // "the marker, and no longer streaming" rather than just the marker:
  // the ephemeral `stream_delta` events carry no seq and reach the pane
  // by a different path from the durable `entry` that supersedes them,
  // so a client that painted the deltas and dropped every entry would
  // satisfy a bare marker check. Only a settled assistant entry clears
  // the strand's live stream.
  case terminal.settled(term, answered, within_ms: 20_000) {
    Ok(_answered) -> Nil
    Error(pane) -> {
      let served = string.contains(snapshot_text(booted), assistant_marker)
      terminal.stop(term)
      serve.shutdown(booted)
      give_up(terminal.framed(
        case served {
          True ->
            "the assistant entry never settled in the pane, though an "
            <> "independent websocket subscribe can see it: the `entry` "
            <> "event or its rendering is the fault."
          False ->
            "the server never committed the assistant reply: an independent "
            <> "websocket subscribe cannot see it either, so this is the "
            <> "server or the scripted provider, not the TUI."
        }
          <> tui_diagnosis(),
        pane,
      ))
    }
  }

  // And the protocol really carries it, witnessed by a second connection
  // that shares nothing with the TUI but the wire format.
  assert string.contains(snapshot_text(booted), assistant_marker)
    as "a fresh subscribe must serve the assistant entry the pane showed"

  // 6. A fork, through the palette. `main-fork` is the gateway's own
  //    name for it and arrives in a strands snapshot, so a tab bearing
  //    it is a server fact rather than an echo of what was typed.
  let assert Ok(Nil) = terminal.type_text(term, ":fork")
    as "the palette command must be typed"
  let assert Ok(Nil) = terminal.press(term, "Enter")
    as "Enter must reach the pane"
  let _forked =
    must_show(
      term,
      "main-fork",
      10_000,
      "the forked strand never reached the " <> "tab bar",
    )
  let assert Ok(strands) = api.strands(booted.runtime)
    as "the session must list its strands"
  assert list.contains(strands, "main-fork")
    as "the fork must be durable, not just drawn"

  // 7. A *parked* call, resumed by an approval that arrived over the
  //    wire. This is the assertion the whole test exists for, and the
  //    only one in the tree that closes the loop: every other approval
  //    anywhere is an in-process `api.approve_escalation`, and every
  //    parking test injects `interactive` as a constant.
  //
  //    The chain is: a scripted tool call → a policy refusal composed
  //    against a base that cannot cover it → a durable escalation record
  //    → *parking*, which happens only because `hub.attached` is nonzero,
  //    and it is nonzero because a real TUI is on the other end of a real
  //    socket → the wanted diff painted in a pane → `y` → an `approve`
  //    frame → the park loop's next poll spending it.
  let assert Ok(Nil) = terminal.type_text(term, tool_prompt_text)
    as "the tool prompt must be typed into the pane"
  let assert Ok(Nil) = terminal.press(term, "Enter")
    as "Enter must reach the pane"

  // The server raised a record, and it is call-*scoped* — which is what
  // distinguishes a refusal a live call is standing at from a record
  // raised out of band. Only a scoped record can be spent by the call
  // that provoked it.
  let record = case wait_for(fn() { pending(booted) }, 200) {
    Ok(record) -> record
    Error(Nil) -> {
      let pane = result.unwrap(terminal.capture(term), "")
      terminal.stop(term)
      serve.shutdown(booted)
      give_up(terminal.framed(
        "the scripted tool call never became a pending policy refusal: "
          <> "either the model's `bash` call never dispatched, or the "
          <> "composed base cleared it after all, so there was nothing "
          <> "for a human to decide"
          <> tui_diagnosis(),
        pane,
      ))
    }
  }
  assert record.scope != None
    as "a parked refusal's record must be scoped to the call that raised it"

  // The diff reached the pane, in the client's own words.
  let _prompted =
    must_show(
      term,
      wanted_display,
      15_000,
      "the refusal's wanted diff never reached the approval prompt",
    )

  // Still pending at the instant of the keystroke: the call is standing
  // at the door, not settled in band behind a record nobody can spend.
  assert status_of(booted, record.id) == Ok(runtime_escalation.Pending)
    as "the refusal must still be undecided when the approval is typed"

  let assert Ok(Nil) = terminal.press(term, "y")
    as "the approval keystroke must reach the pane"

  // `Consumed`, not `Approved`, is the whole point. `approve_escalation`
  // — what the `approve` frame reaches — only ever writes `Approved`;
  // the CAS to `Consumed` is performed by `client/escalate`'s park loop
  // on the parked call's own effect process, immediately before it
  // composes the grants into a policy and re-clears. So a record in
  // `Consumed` is proof that a call which had already been refused woke
  // up and spent an approval that came in over a websocket.
  let spent = fn() {
    status_of(booted, record.id) == Ok(runtime_escalation.Consumed)
  }
  case wait_until(spent, 300) {
    True -> Nil
    False -> {
      let pane = result.unwrap(terminal.capture(term), "")
      let reached = string.inspect(status_of(booted, record.id))
      terminal.stop(term)
      serve.shutdown(booted)
      give_up(terminal.framed(
        "the parked call never spent the approval: the record reached "
          <> reached
          <> " and stopped. `Approved` alone means the keystroke became an "
          <> "`approve` frame and the server recorded it, but the parked "
          <> "call never woke to consume it; anything else means the "
          <> "keystroke never reached the wire at all.",
        pane,
      ))
    }
  }

  // And the resumed call really settled: the scripted model was handed a
  // tool result and closed the turn, so the strand is not left holding a
  // call that no longer has a decision pending.
  let _settled =
    must_show(
      term,
      tool_marker,
      30_000,
      "the resumed call never came back to the model",
    )

  // 8. And leaving is observable too — the other half of the question
  //    the park loop re-asks on every poll.
  let assert Ok(Nil) = terminal.press(term, "C-c")
    as "the quit keystroke must reach the pane"
  case wait_until(fn() { hub.attached(booted.gateway) == 0 }, 150) {
    True -> Nil
    False -> {
      let pane = result.unwrap(terminal.capture(term), "")
      terminal.stop(term)
      serve.shutdown(booted)
      give_up(terminal.framed(
        "the hub still counts the client after it quit: a detach that is "
          <> "never noticed would park a call for a human who has gone",
        pane,
      ))
    }
  }

  terminal.stop(term)
  serve.shutdown(booted)
}

// --- the terminal ----------------------------------------------------------

const socket = "loom-tui-e2e"

const tmux_session = "loom"

// The pane runs a generated launcher rather than the binary directly, so
// the TUI's stderr lands in a file worth reading and its exit status
// outlives it. The trailing sleep holds the pane open after a crash: a
// dead pane tmux has already reaped has nothing left to capture.
fn launch(ready: Ready, addr: String, token: String) -> Terminal {
  let script = ready.workdir <> "/" <> root <> "/run-tui.sh"
  let _stale = simplifile.delete(root <> "/tui.status")
  let _stale = simplifile.delete(root <> "/tui.err")
  let assert Ok(Nil) =
    simplifile.write(
      script,
      "#!/bin/sh\n"
        <> "# Generated by client/tui_e2e_test. Not checked in.\n"
        <> "'"
        <> ready.tui_path
        <> "' --addr '"
        <> addr
        <> "' --session '"
        <> session_id
        <> "' --token '"
        <> token
        <> "' 2>'"
        <> ready.workdir
        <> "/"
        <> root
        <> "/tui.err'\n"
        <> "printf '%s\\n' \"$?\" > '"
        <> ready.workdir
        <> "/"
        <> root
        <> "/tui.status'\n"
        <> "sleep 120\n",
    )
    as "the launcher script must be written"
  let assert Ok(Nil) = simplifile.set_permissions_octal(script, 0o700)
    as "the launcher script must be executable"

  // A server left over from an interrupted run would refuse the session
  // name; killing first makes a re-run deterministic.
  let stale =
    terminal.Terminal(tmux: ready.tmux, socket:, session: tmux_session)
  terminal.stop(stale)
  let assert Ok(term) =
    terminal.start(
      tmux: ready.tmux,
      socket:,
      session: tmux_session,
      command: script,
      cols:,
      rows:,
    )
    as "tmux must start a session running the TUI"
  term
}

// Whatever the TUI said on the way down, for a failure message.
fn tui_diagnosis() -> String {
  let status = case simplifile.read(root <> "/tui.status") {
    Ok(status) -> " it exited " <> string.trim(status) <> "."
    Error(_absent) -> " it is still running."
  }
  let stderr = case simplifile.read(root <> "/tui.err") {
    Ok("") | Error(_absent) -> ""
    Ok(text) -> " stderr: " <> string.trim(text)
  }
  status <> stderr
}

// The pane once the assistant *entry* has landed: the marker present and
// the live stream gone, which happens only when a settled assistant
// entry supersedes it.
fn answered(pane: String) -> Bool {
  string.contains(pane, assistant_marker) && !string.contains(pane, "streaming")
}

fn must_show(
  term: Terminal,
  needle: String,
  within_ms: Int,
  what: String,
) -> String {
  case terminal.settled_on(term, needle, within_ms) {
    Ok(pane) -> pane
    Error(pane) -> {
      let alive = case terminal.alive(term) {
        True -> ""
        False -> " (the tmux session is gone)"
      }
      terminal.stop(term)
      give_up(terminal.framed(
        what <> ": never saw `" <> needle <> "`." <> alive <> tui_diagnosis(),
        pane,
      ))
    }
  }
}

// --- the server's own answer ------------------------------------------------

// A second, independent websocket connection subscribing from scratch:
// the honest answer to "does the *server* have it", asked without going
// through the client under test.
fn snapshot_text(booted: serve.Booted) -> String {
  let subscribe =
    protocol.encode_command(protocol.CommandEnvelope(
      id: 1,
      command: protocol.Subscribe(session: session_id, from_seq: None),
    ))
  ffi_ws.ws_roundtrip(
    "127.0.0.1",
    booted.served.port,
    booted.served.token,
    subscribe,
  )
  |> result.unwrap("")
}

// The one undecided refusal on the server, if there is one. Found by
// scanning rather than by a known id: a real record's id is a digest of
// `{strand, tool, wanted diff}` that `client/escalate` derives, so the
// test must read what the server minted instead of naming it in advance.
fn pending(booted: serve.Booted) -> Result(runtime_escalation.Escalation, Nil) {
  case api.escalations(booted.runtime) {
    Error(_unreadable) -> Error(Nil)
    Ok(records) ->
      list.find(records, fn(record) {
        record.status == runtime_escalation.Pending
      })
  }
}

fn status_of(
  booted: serve.Booted,
  id: String,
) -> Result(runtime_escalation.Status, Nil) {
  api.escalation(booted.runtime, id)
  |> result.map(fn(record) { record.status })
  |> result.replace_error(Nil)
}

fn wait_until(condition: fn() -> Bool, attempts: Int) -> Bool {
  case condition(), attempts <= 0 {
    True, _ -> True
    False, True -> False
    False, False -> {
      process.sleep(100)
      wait_until(condition, attempts - 1)
    }
  }
}

fn wait_for(produce: fn() -> Result(a, Nil), attempts: Int) -> Result(a, Nil) {
  case produce(), attempts <= 0 {
    Ok(value), _ -> Ok(value)
    Error(Nil), True -> Error(Nil)
    Error(Nil), False -> {
      process.sleep(100)
      wait_for(produce, attempts - 1)
    }
  }
}

// eunit truncates a panic message, and the pane is the whole point of
// the failure — so it is printed in full first and named again in the
// panic.
fn give_up(message: String) -> a {
  io.println("\n" <> message)
  panic as message
}

// --- the scripted model ----------------------------------------------------

// The answer is conditional on the request: the marker comes back only
// when the words typed into the terminal are in the body the provider
// was handed. That is what makes the marker in the pane a proof of the
// round trip rather than of a fixture.
fn scripted_transport() -> http.Transport {
  http.Transport(send_streaming: fn(request, subject) {
    process.send(
      subject,
      http.ResponseStatus(status: 200, headers: [
        #("content-type", "text/event-stream"),
      ]),
    )
    process.send(
      subject,
      http.ResponseChunk(chunk: bit_array.from_string(answer(request.body))),
    )
    process.send(subject, http.ResponseEnd)
  })
}

// The three answers, and the order they are tried in.
//
// Every request carries the *whole* conversation, so the newest turn is
// the one to match last-first: turn two's body still contains turn one's
// prompt, and turn three's still contains both. Matching `prompt_text`
// first would answer every turn with the first reply and the run would
// never move. So: a settled tool result means the refused call has come
// back and the turn should end; otherwise the newest typed prompt wins.
fn answer(body: String) -> String {
  case
    string.contains(body, "tool_result"),
    string.contains(body, tool_prompt_text),
    string.contains(body, prompt_text)
  {
    True, _, _ -> sse_transcript("the refused call came back " <> tool_marker)
    False, True, _ -> sse_tool_call()
    False, False, True ->
      sse_transcript("the scripted model answered " <> assistant_marker)
    False, False, False ->
      sse_transcript("the provider request did not carry the typed prompt")
  }
}

// A `bash` call the session base cannot clear. Nothing about the command
// matters — the refusal is decided by composing policies, before any
// jail is dispatched or any budget reserved — but it is worded so that a
// pane or a transcript showing it is self-explaining.
fn sse_tool_call() -> String {
  sse_event(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_tui_e2e_tool\","
      <> "\"model\":\"loom-1\",\"usage\":{\"input_tokens\":10,"
      <> "\"output_tokens\":1}}}",
  )
  <> sse_event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":"
      <> "{\"type\":\"tool_use\",\"id\":\"toolu_tui_e2e\",\"name\":\"bash\","
      <> "\"input\":{}}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":"
      <> "{\"type\":\"input_json_delta\",\"partial_json\":"
      <> "\"{\\\"command\\\":\\\"echo the-terminal-probe\\\"}\"}}",
  )
  <> sse_event(
    "content_block_stop",
    "{\"type\":\"content_block_stop\",\"index\":0}",
  )
  <> sse_event(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},"
      <> "\"usage\":{\"output_tokens\":9}}",
  )
  <> sse_event("message_stop", "{\"type\":\"message_stop\"}")
}

fn sse_transcript(text: String) -> String {
  sse_event(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_tui_e2e\","
      <> "\"model\":\"loom-1\",\"usage\":{\"input_tokens\":10,"
      <> "\"output_tokens\":1}}}",
  )
  <> sse_event(
    "content_block_start",
    "{\"type\":\"content_block_start\",\"index\":0,"
      <> "\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
  )
  <> sse_event(
    "content_block_delta",
    "{\"type\":\"content_block_delta\",\"index\":0,"
      <> "\"delta\":{\"type\":\"text_delta\",\"text\":\""
      <> text
      <> "\"}}",
  )
  <> sse_event(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},"
      <> "\"usage\":{\"output_tokens\":6}}",
  )
  <> sse_event("message_stop", "{\"type\":\"message_stop\"}")
}

fn sse_event(name: String, data: String) -> String {
  "event: " <> name <> "\ndata: " <> data <> "\n\n"
}

// --- the boot ---------------------------------------------------------------

fn scripted_catalog() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      catalog.CatalogModel(
        name: "acme",
        dialect: catalog.Anthropic,
        base_url: "https://acme.test",
        api_key_env: "ACME_KEY",
        model_id: "loom-1",
        context_window: 100_000,
        max_output_tokens: 4096,
        thinking: model.ThinkingOff,
      ),
    ],
    roles: [#(model.Main, ["acme"])],
    mcp_servers: [],
  )
}

// A repository-relative test path as the absolute one every policy path
// must be: the workspace becomes the base policy's writable root, and
// `serve.base_policy_fault` refuses a boot on a policy the jail could
// not accept.
fn absolute(path: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  here <> "/" <> path
}

fn settings() -> serve.Settings {
  serve.Settings(
    session_path: root <> "/session.db",
    bind_host: "127.0.0.1",
    bind_port: 0,
    token_path: root <> "/session.db.token",
    workspace: absolute(root) <> "/work",
    // *Narrower* than `serve.base_policy`, and that is the seam this
    // test needs. The shipped base grants read of `/`, which is exactly
    // what `bash` asks for — so under it no shipped tool can provoke a
    // policy refusal, nothing ever parks, and the escalation plane is
    // unreachable from a real server. `policy.workspace_default` grants
    // read of the workspace only, which leaves `bash`'s one requirement
    // uncovered and produces a single, legible wanted grant. This is a
    // real posture a cautious operator might serve, not a test hook.
    base_policy: policy.workspace_default(absolute(root) <> "/work"),
    // The re-cleared call does dispatch, and this is not a real helper,
    // so it fails its hello handshake and settles in band. That is
    // deliberate: the assertion is that the parked call *woke and spent
    // the approval*, which happens strictly before any jail is asked
    // for, and demanding a working `loom-exec` here would make the
    // highest-value assertion in this suite skip on hosts without one.
    helper_path: "/bin/sh",
    helper_pool_size: 2,
    session_id:,
    demand: exec.BestEffort,
    gateway: catalog.gateway(
      scripted_catalog(),
      transport: scripted_transport(),
      secrets: secret.from_list([#("ACME_KEY", "tui-e2e-key")]),
      clock: clock.fixed(at: 0),
    ),
    catalog: scripted_catalog(),
    system: Some("You are a scripted model in a terminal end-to-end."),
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    context_window: 100_000,
    max_output_tokens: 4096,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
    ),
    // No seed: this host must not go looking for a toolchain.
    codemode_seed: root <> "/no-such-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
  )
}
