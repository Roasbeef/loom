//// The real TUI against the real server, in a terminal (issue #7).
////
//// This fixture crosses the native executable and terminal boundary as well
//// as the real daemon's control and credited conversation routes:
////
////  - one daemon restores its private catalogue before the fixture explicitly
////    creates a session, then owns its real SQLite runtime and one v2 listener;
////  - the client is the native `tui` shipment, exported by this test
////    so the artifact under test cannot be stale, running under a real
////    terminal in `tmux` and driven only by keystrokes;
////  - only the *model* is scripted, through `Settings.gateway` — a
////    transport that answers with an Anthropic SSE transcript. No API
////    key is needed and nothing dials out.
////
//// What that buys is an assertion no other test can make: the words
//// typed into a terminal become a `prompt` command, a durable entry, a
//// provider request whose body carries them, an assistant entry, a completed
//// credited capture, and finally pixels in a pane. The answer text is
//// *conditional on the request body* — the scripted transport answers
//// with the marker only when the typed prompt is in the request it was
//// handed — so the marker appearing in the pane is proof of the whole
//// round trip rather than of a fixture. The same drive forks a strand and
//// observes a clean detach, so the native launcher's process boundary is in
//// the proof rather than only its model functions.
////
//// ## The failures this must be able to tell apart
////
//// A terminal test that can only time out is not worth having. Each
//// stage here fails in its own voice: daemon assembly returning an error
//// is "the server never started"; `gateway.attached` staying at zero is
//// "the TUI never attached", reported with the TUI's own stderr; a
//// second, independent websocket subscribe that cannot see the assistant
//// entry is "the server never committed it", which separates a server
//// fault from a client one; and only after that does a bare pane read as
//// "the frames never reached the pane". Every failure dumps the pane.
////
//// ## What this still does not reach
////
//// Nothing here proves an approved call runs under a widened sandbox; that
//// is `make e2e`'s job. Domain maintenance is explicitly inert in this scripted
//// fixture. The separate three-principal native-driver test covers exact
//// approval inspection, action/grant/sequence echo, winning author and observer
//// authority; this PTY fixture does not substitute for that evidence.

import broker/exec
import broker/policy
import client/catalog
import client/codemode
import client/daemon/domain as domain_service
import client/daemon/main as daemon_main
import client/daemon/manager
import client/daemon/root as daemon_root
import client/daemon/session_socket
import client/daemon_server_test as wire
import client/distillpass
import client/gateway as hub
import client/internal/ffi_os
import client/jobs
import client/schedule
import client/serve
import client/session_socket_test
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import etui/backend
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/http
import provider/model
import provider/secret
import runtime/api
import simplifile
import support/internal/ffi_proc
import support/internal/ffi_ws
import support/provider as provider_test
import support/terminal.{type Terminal}
import support/tui_driver
import telemetry/log
import tui/session_channel
import weft/poll

// A home directory that does not exist, so a server booted here never
// picks up the developer's own `~/.agents/AGENTS.md`. A home with no
// global default is silent, which is what keeps these assertions about
// the prompt pack and the workspace alone.
const empty_home = Some("build/no-operator-home")

const root = "build/tui-e2e"

/// What is typed into the terminal, and what the scripted transport
/// looks for in the provider request before it will answer with the
/// marker.
const prompt_text = "answer the terminal probe"

/// The one token whose presence in the pane can only be explained by the
/// whole round trip. Deliberately a single alphanumeric word: glamour
/// word-wraps the assistant block, and a phrase could be split.
const assistant_marker = "skein7f3a"

const second_prompt = "answer the terminal probe again"

const second_marker = "skein8b2c"

const cols = 110

const rows = 34

/// The whole budget: a cold native shipment export, a boot, and a drive
/// whose own waits already sum to about a minute of deadline. eunit's
/// unchosen default — 5 s, which gleeunit scales to 50 — falls during the
/// dependency build on a cold package cache and reports `Timeout` at a line
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
      Ok(tools) -> {
        // Once the required tools exist, compilation is part of the test, not
        // an optional prerequisite. The enclosing test deadline covers export.
        case build_tui(tools.gleam, tools.workdir) {
          Ok(tui_path) -> drive(Ready(tools.tmux, tui_path, tools.workdir))
          Error(reason) -> give_up(reason)
        }
      }
    }
  })
}

/// Two independent clients share the real server without a terminal binary.
///
/// This preserves the prompt-conditioned two-turn foundation. The separate
/// multiplayer and persisted fixtures cover principals, roles, configuration,
/// exact approvals and lazy session opening through the same daemon contracts.
pub fn two_virtual_tuis_share_one_real_session_test_() -> EunitTest {
  Timeout(60 / gleeunit_timeout_scale, virtual_drive)
}

fn virtual_drive() -> Nil {
  let test_root =
    "build/tui-pair-"
    <> int.to_string(ffi_os.system_time_ms())
    <> "-"
    <> int.to_string(ffi_os.unique_positive_integer())
  let assert Ok(Nil) = simplifile.create_directory_all(test_root <> "/work")
    as "the independent clients need an isolated workspace"
  let assert Ok(booted) = boot(settings_at(test_root))
    as "the server must boot for the virtual client pair"
  let address =
    "ws://127.0.0.1:" <> int.to_string(booted.served.port) <> "/v2/control"
  let outcome = virtual_pair(address, booted.served.token, booted.session_id)
  let persisted = snapshot_text(booted)
  let detached =
    poll.until(within: 5000, every: 10, attempt: fn() {
      case hub.attached(booted.instance.gateway) == 0 {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })

  // Teardown precedes assertions so a failed frame check releases the lease.
  shutdown(booted)
  case outcome {
    Error(reason) -> io.println_error(reason)
    Ok(Nil) -> Nil
  }
  assert outcome == Ok(Nil) as string.inspect(outcome)
  assert detached == poll.Answered(Nil)
    as "both driver exits must detach their real sockets"
  assert string.contains(persisted, assistant_marker)
  assert string.contains(persisted, second_marker)
  assert string.contains(persisted, second_prompt)
    as "a fresh subscriber must recover both completed turns"
}

fn virtual_pair(
  address: String,
  token: String,
  session_id: String,
) -> Result(Nil, String) {
  use alice <- result.try(
    tui_driver.start(address, token, session_id)
    |> result.map_error(string.inspect),
  )
  let outcome = case tui_driver.start(address, token, session_id) {
    Error(reason) -> Error(string.inspect(reason))
    Ok(bob) -> {
      let outcome = virtual_turns(alice.data, bob.data, session_id)
      tui_driver.stop(bob.data)
      outcome
    }
  }
  tui_driver.stop(alice.data)
  outcome
}

fn virtual_turns(
  alice: process.Subject(tui_driver.Message),
  bob: process.Subject(tui_driver.Message),
  session_id: String,
) -> Result(Nil, String) {
  use Nil <- result.try(
    await_pair(alice, bob, "both initial snapshots", fn(a, b) {
      a.model.session == session_id
      && b.model.session == session_id
      && writable(a)
      && writable(b)
    }),
  )
  let _ =
    tui_driver.play(alice, [
      backend.Paste(prompt_text),
      backend.KeyPress("enter"),
    ])
  use Nil <- result.try(
    await_pair(alice, bob, "Alice's shared turn", fn(a, b) {
      shared_turns(a, b, 1) && writable(b)
    }),
  )
  let _ =
    tui_driver.play(bob, [
      backend.Paste(second_prompt),
      backend.KeyPress("enter"),
    ])
  await_pair(alice, bob, "Bob's shared turn", fn(a, b) { shared_turns(a, b, 2) })
}

fn shared_turns(
  a: tui_driver.Sample,
  b: tui_driver.Sample,
  count: Int,
) -> Bool {
  let users =
    list.filter_map(a.model.records, fn(record) {
      case record.entry {
        entry.MessageEntry(message: message.UserMessage(content:, ..), ..) ->
          Ok(content)
        _ -> Error(Nil)
      }
    })
  let answers =
    list.filter_map(a.model.records, fn(record) {
      case record.entry {
        entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) ->
          Ok(content)
        _ -> Error(Nil)
      }
    })
  let expected_users =
    [prompt_text, second_prompt]
    |> list.take(count)
    |> list.reverse
    |> list.map(fn(text) { [message.UserText(text, None)] })
  let expected_answers =
    [assistant_marker, second_marker]
    |> list.take(count)
    |> list.reverse
    |> list.map(fn(marker) {
      [message.AssistantText("the scripted model answered " <> marker, None)]
    })
  a.model.records == b.model.records
  && users == expected_users
  && answers == expected_answers
  && a.model.streams == []
  && b.model.streams == []
  && a.model.submitting == None
  && b.model.submitting == None
  && list.any(a.model.strands, fn(strand) {
    strand.id == "main" && strand.live_phase == None
  })
  && list.any(b.model.strands, fn(strand) {
    strand.id == "main" && strand.live_phase == None
  })
  && list.all(list.take([assistant_marker, second_marker], count), fn(marker) {
    string.contains(a.frame, marker) && string.contains(b.frame, marker)
  })
}

fn writable(sample: tui_driver.Sample) {
  case sample.model.channel {
    Some(channel) -> session_channel.mutation_available(channel)
    None -> False
  }
}

fn await_pair(
  alice: process.Subject(tui_driver.Message),
  bob: process.Subject(tui_driver.Message),
  condition: String,
  ready: fn(tui_driver.Sample, tui_driver.Sample) -> Bool,
) -> Result(Nil, String) {
  case
    poll.until(within: 10_000, every: 10, attempt: fn() {
      let a = tui_driver.play(alice, [])
      let b = tui_driver.play(bob, [])
      case ready(a, b) {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
  {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> {
      let a = tui_driver.play(alice, [])
      let b = tui_driver.play(bob, [])
      Error(
        condition
        <> " timed out. Alice:\n"
        <> a.frame
        <> "\nBob:\n"
        <> b.frame
        <> "\nAlice records: "
        <> string.inspect(a.model.records)
        <> "\nBob records: "
        <> string.inspect(b.model.records),
      )
    }
  }
}

// --- prerequisites ---------------------------------------------------------

type Ready {
  Ready(tmux: String, tui_path: String, workdir: String)
}

type Tools {
  Tools(tmux: String, gleam: String, workdir: String)
}

// `tmux`, Gleam and Erlang are feature-detected before the native shipment is
// exported. The build is done here rather than depended upon (`make binaries`) on
// purpose: a prerequisite a developer must remember is a prerequisite
// `make check` will skip, and a skipped end-to-end is exactly the
// vacuous pass this test exists to replace.
fn prerequisites() -> Result(Tools, String) {
  use tmux <- result.try(terminal.available())
  use gleam <- result.try(
    ffi_proc.which("gleam")
    |> result.replace_error("gleam is not on PATH, so loom cannot be built"),
  )
  use _erl <- result.try(
    ffi_proc.which("erl")
    |> result.replace_error("erl is not on PATH, so loom cannot run"),
  )
  use workdir <- result.try(
    simplifile.current_directory()
    |> result.replace_error("the working directory is unreadable"),
  )
  Ok(Tools(tmux:, gleam:, workdir:))
}

fn build_tui(gleam: String, workdir: String) -> Result(String, String) {
  let out = workdir <> "/" <> root <> "/loom"
  let assert Ok(Nil) = simplifile.create_directory_all(workdir <> "/" <> root)
    as "the end-to-end's build directory must exist"
  case
    ffi_proc.run(gleam, ["export", "erlang-shipment"], in: workdir <> "/../tui")
  {
    Error(reason) -> Error("native TUI export could not be started: " <> reason)
    Ok(#(0, _output)) -> {
      use _ <- result.try(
        simplifile.write(
          out,
          "#!/bin/sh\nexec erl +Bd -pa '"
            <> workdir
            <> "/../tui/build/erlang-shipment'/*/ebin "
            <> "-eval 'tui@@main:run(tui)' -noshell -extra \"$@\"\n",
        )
        |> result.replace_error(
          "the native TUI test launcher could not be written",
        ),
      )
      use _ <- result.try(
        simplifile.set_permissions_octal(out, 0o700)
        |> result.replace_error(
          "the native TUI test launcher could not be made executable",
        ),
      )
      Ok(out)
    }
    Ok(#(status, output)) ->
      Error(
        "native TUI export exited "
        <> int.to_string(status)
        <> ": "
        <> string.trim(output),
      )
  }
}

// --- the drive -------------------------------------------------------------

fn drive(ready: Ready) -> Nil {
  let test_root = root <> "/" <> int.to_string(ffi_os.system_time_ms())
  let assert Ok(Nil) = simplifile.create_directory_all(test_root <> "/work")
    as "the workspace must exist"

  // 1. The server. A boot failure is its own failure, with its own
  //    message, before any terminal exists to blame.
  let assert Ok(booted) = boot(settings_at(test_root))
    as "the server must boot on an ephemeral port"
  let addr =
    "ws://127.0.0.1:" <> int.to_string(booted.served.port) <> "/v2/control"

  // Nobody is attached yet, and the hub says so. This is the question
  // `client/serve` puts to the escalation seam on every park poll.
  assert hub.attached(booted.instance.gateway) == 0
    as "a server nobody has dialled must count no connections"

  // 2. The real binary, in a real terminal.
  let term = launch(ready, addr, booted.served.token, booted.session_id)

  // 3. It attached over the session route after authenticating to the daemon
  //    control route with its stable owner credential.
  case wait_until(fn() { hub.attached(booted.instance.gateway) > 0 }, 150) {
    True -> Nil
    False -> {
      let pane = result.unwrap(terminal.capture(term), "")
      terminal.stop(term)
      shutdown(booted)
      give_up(terminal.framed(
        "the TUI never attached: the hub still counts 0 connections."
          <> tui_diagnosis(),
        pane,
      ))
    }
  }
  assert hub.attached(booted.instance.gateway) == 1
    as "exactly one client is attached"

  // 4. The snapshot painted. This text is created only after the bounded
  //    initial capture ends, so it is protocol traffic on screen rather than an
  //    echo of a flag the client was given.
  let _painted =
    must_show(term, "Owner · owner", 15_000, "the snapshot never painted")

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
  // "the marker, and no longer responding" rather than just the marker:
  // the sampled stream preview is not a durable entry, so a client that
  // painted the preview and dropped every credited entry would
  // satisfy a bare marker check. Only a settled assistant entry clears
  // the strand's live stream.
  case terminal.settled(term, answered, within_ms: 20_000) {
    Ok(_answered) -> Nil
    Error(pane) -> {
      let served = string.contains(snapshot_text(booted), assistant_marker)
      terminal.stop(term)
      shutdown(booted)
      give_up(terminal.framed(
        case served {
          True ->
            "the assistant entry never settled in the pane, though an "
            <> "independent websocket subscribe can see it: credited entry "
            <> "delivery or its rendering is the fault."
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

  // 6. A named fork through the slash surface. The authoritative metadata cut
  //    replaces the local "fork queued" notice while preserving the active
  //    strand. Inspect the actual agent list after that cut, so a transient
  //    command echo can neither pass this check nor race its observation.
  let assert Ok(Nil) = terminal.type_text(term, "/fork main-fork")
    as "the slash command must be typed"
  let assert Ok(Nil) = terminal.press(term, "Enter")
    as "Enter must reach the pane"
  let _metadata =
    must_show(term, "0 live / 2 agents", 10_000, "fork metadata never painted")
  let fork_is_durable = fn() {
    api.strands(booted.instance.runtime)
    |> result.map(fn(strands) { list.contains(strands, "main-fork") })
    |> result.unwrap(False)
  }
  case wait_until(fork_is_durable, 150) {
    True -> Nil
    False -> {
      let pane = result.unwrap(terminal.capture(term), "")
      let strands = api.strands(booted.instance.runtime)
      terminal.stop(term)
      shutdown(booted)
      give_up(terminal.framed(
        "the fork count painted but its identity was not durable; runtime returned "
          <> string.inspect(strands),
        pane,
      ))
    }
  }
  let assert Ok(Nil) = terminal.type_text(term, "/agents")
    as "the normal slash command opens the authoritative agent list"
  let assert Ok(Nil) = terminal.press(term, "Enter")
    as "Enter must open the agent inspector"
  let _forked =
    must_show(
      term,
      "main-fork",
      10_000,
      "the durable fork never reached the agent inspector",
    )
  let assert Ok(Nil) = terminal.press(term, "Escape")
    as "the agent inspector closes before the terminal quit command"

  // 7. And leaving is observable too, the other half of the question
  //    the park loop re-asks on every poll.
  let assert Ok(Nil) = terminal.press(term, "C-c")
    as "the quit keystroke must reach the pane"
  case wait_until(fn() { hub.attached(booted.instance.gateway) == 0 }, 150) {
    True -> Nil
    False -> {
      let pane = result.unwrap(terminal.capture(term), "")
      terminal.stop(term)
      shutdown(booted)
      give_up(terminal.framed(
        "the hub still counts the client after it quit: a detach that is "
          <> "never noticed would park a call for a human who has gone",
        pane,
      ))
    }
  }

  terminal.stop(term)
  shutdown(booted)
}

// --- the terminal ----------------------------------------------------------

const socket = "loom-e2e"

const tmux_session = "loom"

// The pane runs a generated launcher rather than the binary directly, so
// the TUI's stderr lands in a file worth reading and its exit status
// outlives it. The trailing sleep holds the pane open after a crash: a
// dead pane tmux has already reaped has nothing left to capture.
fn launch(
  ready: Ready,
  addr: String,
  token: String,
  session_id: String,
) -> Terminal {
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
  string.contains(pane, assistant_marker)
  && !string.contains(pane, "responding")
  && !string.contains(pane, "thinking")
  && !string.contains(pane, "starting")
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
fn snapshot_text(booted: Booted) -> String {
  let #(socket, _) =
    wire.connect(
      booted.served.port,
      booted.served.token,
      "/v2/sessions/" <> booted.session_id <> "/ws",
    )
  let #(_, capture) =
    session_socket_test.begin(socket, booted.session_id, within_ms: 1000)
  let chunks =
    session_socket_test.drain(socket, capture, 0, [], 32, within_ms: 1000)
  ffi_ws.tcp_close(socket)
  chunks
  |> list.filter_map(fn(chunk) {
    let assert json.Object(fields) = chunk as "each credited chunk is an object"
    case list.key_find(fields, "kind"), list.key_find(fields, "data") {
      Ok(json.String("entry")), Ok(json.String(data)) ->
        bit_array.base64_decode(data)
      _, _ -> Error(Nil)
    }
  })
  |> bit_array.concat
  |> bit_array.to_string
  |> result.unwrap("")
}

fn wait_until(condition: fn() -> Bool, attempts: Int) -> Bool {
  poll.until(within: attempts * 100, every: 100, attempt: fn() {
    case condition() {
      True -> poll.Done(Nil)
      False -> poll.Retry
    }
  })
  == poll.Answered(Nil)
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
  provider_test.transport(fn(request, subject) {
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

// The answer is conditional on the typed prompt.
fn answer(body: String) -> String {
  case
    string.contains(body, second_prompt),
    string.contains(body, prompt_text)
  {
    True, _ -> sse_transcript("the scripted model answered " <> second_marker)
    False, True ->
      sse_transcript("the scripted model answered " <> assistant_marker)
    False, False ->
      sse_transcript("the provider request did not carry the typed prompt")
  }
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

type Served {
  Served(port: Int, token: String)
}

type Booted {
  Booted(
    serving: daemon_main.Serving(serve.Instance),
    instance: serve.Instance,
    served: Served,
    session_id: String,
  )
}

// The manager owns the runtime and its real SQLite store. Domain maintenance is
// explicitly inert in this scripted terminal fixture; separate domain tests
// cover shared services, and no provider work is fabricated by the TUI itself.
fn boot(settings: serve.Settings) -> Result(Booted, String) {
  let state_root =
    absolute(filepath.directory_name(settings.session_path)) <> "/daemon"
  let assert Ok(config) = daemon_main.parse(["--state-dir", state_root])
    as "the terminal fixture has a private absolute daemon root"
  let assert Ok(daemon) =
    daemon_root.start(
      daemon_root.Config(config.state_root, "Owner", 4),
      manager.Assembly(
        fn(_, _, _) { Ok(domain_service.inert()) },
        fn(record, selected_domain, _services, owner) {
          let assert Ok(id) = ids.parse_session_id(record.id)
            as "the manager reserves a canonical session identity"
          assert bootstrap.ensure_private_directory(filepath.directory_name(
              selected_domain.memory_path,
            ))
            == Ok(Nil)
          let base = serve.base_policy(record.workspace)
          serve.assemble_owned(
            serve.Settings(
              ..settings,
              session_id: record.id,
              session_path: record.path,
              workspace: record.workspace,
              domain_paths: Some(serve.DomainPaths(
                selected_domain.memory_path,
                selected_domain.index_path,
              )),
              base_policy: policy.SandboxPolicy(..base, protected: [
                config.state_root,
                ..base.protected
              ]),
            ),
            id,
            log.discard(),
            owner,
          )
        },
        serve.instance_children,
      ),
    )
    as "the one daemon owns the catalogue before any runtime opens"
  let assert Ok(serving) =
    daemon_main.listen(config, daemon, fn(request, attachment) {
      session_socket.upgrade(
        daemon,
        request,
        attachment,
        attachment.instance.gateway,
      )
    })
    as "the production v2 listener owns both control and conversation routes"
  let assert Ok(created) =
    manager.create(
      serving.ready.registry,
      manager.Creation("terminal-fixture", settings.workspace, "terminal", ""),
      directory: serving.ready.sessions_directory,
      generator: ids.generator(
        clock.from_function(ffi_os.system_time_ms),
        ffi_os.unique_positive_integer(),
      ),
    )
    as "the fixture explicitly creates one session through the registry"
  let assert poll.Answered(instance) =
    poll.until(within: 15_000, every: 5, attempt: fn() {
      case manager.resolve(serving.ready.registry, created.registration.id) {
        Ok(instance) -> poll.Done(instance)
        Error(_) -> poll.Retry
      }
    })
    as "the original managed assembly becomes resident within its deadline"
  let assert Ok(token) = daemon_root.listener_credential(daemon)
    as "the only bearer is the daemon owner credential"
  Ok(Booted(
    serving,
    instance,
    Served(serving.listener.port, token),
    created.registration.id,
  ))
}

fn shutdown(booted: Booted) {
  assert daemon_root.shutdown(booted.serving.daemon, within: 30_000) == Ok(Nil)
    as "the original root confirms native, storage and listener retirement"
}

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
        pricing: None,
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

fn settings_at(test_root: String) -> serve.Settings {
  serve.Settings(
    session_path: test_root <> "/session.db",
    domain_paths: option.None,
    bind_host: "127.0.0.1",
    bind_port: 0,
    token_path: test_root <> "/session.db.token",
    workspace: absolute(test_root) <> "/work",
    base_policy: serve.base_policy(absolute(test_root) <> "/work"),
    // No tool is dispatched in this protocol round trip, so the terminal
    // boundary stays independent of whichever jail layers the host offers.
    helper_path: absolute("../../bin/loom-exec"),
    helper_pool_size: 2,
    session_id: "",
    demand: exec.BestEffort,
    gateway: catalog.gateway(
      scripted_catalog(),
      transport: scripted_transport(),
      secrets: secret.from_list([#("ACME_KEY", "tui-e2e-key")]),
      clock: clock.fixed(at: 0),
    ),
    catalog: scripted_catalog(),
    system: Some("You are a scripted model in a terminal end-to-end."),
    home: empty_home,
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
    codemode_seed: test_root <> "/no-such-seed",
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    deactivated_tools: [],
    // No lifecycle distillation in this rig: the pass would open the
    // memory store this test asserts about and spend the scripted
    // provider's turns. `memory_lifecycle_test` is where the shipped
    // producer is exercised.
    memory: distillpass.no_pass(),
    // Offline, three names: the jail every session had before the
    // `[tools]` table existed.
    tools: catalog.default_tools(),
  )
}
