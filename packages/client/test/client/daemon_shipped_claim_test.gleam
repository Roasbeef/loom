//// The claim flow against the shipped daemon executable (protocol-change/053).
////
//// The owner creates a session, isolates it with the real `loomd access`
//// command line, and invites an operator with it. The invitee, with a state
//// directory of its own, redeems the claim through `tui/claim`, the code
//// behind `loom claim`, and attaches to the session with the credential it
//// stored, where it holds exactly the granted role. The spent claim is then
//// replayed and refused, presented as a bearer and refused, and the owner
//// revokes the member with `loomd access`, which closes the invitee's
//// attachment at its next frame. Finally every file the daemon wrote,
//// its log included, is searched for the claim token and the credential.
////
//// The coordinator retains the endpoint path outside the bounded body, so a
//// failed assertion still retires the native lifetime before reporting.

import broker/token
import client/daemon_server_test as wire
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap as native
import host/endpoint
import simplifile
import support/daemon_observation
import support/internal/ffi_daemon_socket
import support/internal/ffi_proc
import support/internal/ffi_ws
import support/shipped_server
import tui/bootstrap
import tui/claim
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui/workspace
import weft
import weft/poll

// Reads against the shipped daemon wait behind its own admission budgets,
// as in the shipped multiplayer fixture.
const wire_read_ms = 15_000

/// Invites, claims, attaches, replays and revokes against the shipped daemon.
///
/// ## Examples
///
/// `LOOM_BOOTSTRAP_E2E_SERVER=bin/loomd scripts/test.sh client --match daemon_shipped_claim`.
pub fn daemon_shipped_claim_flow_test_() -> EunitTest {
  // The runner scales EUnit timeouts by ten: 120 seconds around the 70-second
  // body and its independent native cleanup.
  Timeout(12, fn() {
    case shipped_server.from_environment() {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped claim: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) -> fixture(server)
    }
  })
}

fn fixture(server: String) -> Nil {
  let directory =
    "build/shipped-claim-"
    <> bit_array.base16_encode(token.production_entropy()(8))
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "the fixture's owner and invitee state stay private"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the native daemon receives absolute paths"
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains the endpoint before native startup"
  io.println_error("shipped claim fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise(server, directory, paths)
        Ok(Nil)
      },
    ])
    |> weft.deadline(70_000)
    |> weft.start
  retire_native(paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped claim drive completes before native teardown"
  Nil
}

fn exercise(server: String, directory: String, paths: endpoint.Paths) -> Nil {
  let workspace = directory <> "/workspace"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)

  // A provider this drive never calls, so the daemon does not fall back to
  // whatever model the environment names. Memory maintenance stays at its
  // default on purpose: the reopen below builds a fresh domain whose first
  // distillation pass harvests this very session, and the open must wait
  // that harvest out rather than fail.
  let configuration = directory <> "/fixture.toml"
  let assert Ok(Nil) =
    simplifile.write(
      configuration,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \"http://127.0.0.1:9\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n",
    )
  let options =
    bootstrap.Options(workspace, "", server, paths.root, configuration, "")
  let assert Ok(connected) =
    bootstrap.resolve_daemon(options, process.self(), 40_000)
    as "the shipped daemon starts through native bootstrap"
  let assert Ok(address) = endpoint.address(connected.record)
  let assert endpoint.Ready(port:, ..) = connected.record
    as "the daemon published its port"
  let assert Ok(owner) = simplifile.read(connected.paths.token)
  let assert Ok(host) =
    selection.host(connected.control, address, string.trim(owner))
  let assert Ok(created) =
    selection.create_named(
      host,
      "shipped-claim",
      workspace,
      workspace.session_name(workspace.Context(workspace, None)),
      configuration,
      "",
    )
  let session = created.expected.session
  await_resident(connected.control, session, paths)

  // An invitation needs a session_only domain, so the session is stopped
  // and isolated with the owner's command line before anyone is invited.
  let assert Ok(_) =
    daemon.request(connected.control, protocol.StopSession(session), 5000)
  let assert poll.Answered(Nil) =
    daemon_observation.session_until(
      connected.control,
      session,
      within: 15_000,
      every: 25,
      inspect: daemon_observation.saved,
    )
  let #(isolated, _) =
    access(server, directory, paths, [
      "isolate",
      session,
      "--share-existing-transcript",
    ])
  assert isolated == 0
  let failures_before = list.length(start_failures(paths))
  case selection.open(host, session) {
    Ok(_) -> Nil
    Error(reason) ->
      panic as {
        "the owner could not reopen the isolated session: "
        <> reason
        <> "\ndaemon log: "
        <> string.join(list.drop(start_failures(paths), failures_before), "\n")
      }
  }
  await_resident(connected.control, session, paths)

  // The owner invites through the shipped command line. Its output carries a
  // claim and a claim command, and no bearer.
  let #(status, reply) =
    access(server, directory, paths, [
      "invite",
      session,
      "alice",
      "operator",
      "Alice",
    ])
  assert status == 0
  let assert json.String(issued) = field(reply, "claim")
    as "the invitation printed a claim"
  assert !string.contains(json.to_string(reply), "bearer")
  assert field(reply, "claim_command")
    == json.String("loom claim --addr " <> address)

  // The owner's listing shows the open claim and prints neither the claim
  // nor any credential.
  let #(listed, before_claim) =
    access_output(server, directory, paths, ["list"])
  assert listed == 0
  assert string.contains(before_claim, "\"principal_id\":\"alice\"")
  assert string.contains(before_claim, "\"state\":\"claim_open\"")
  assert !string.contains(before_claim, issued)
  assert !string.contains(before_claim, "loomclaim_")

  // The invitee claims with its own state directory; the credential it
  // stores attaches to the session as an operator.
  let assert Ok(remote) =
    claim.remote(claim.Options(address, "", directory <> "/invitee", ""))
    as "the invitee prepares its private remote directory"
  let assert Ok(claimed) = claim.redeem(remote, issued, "")
    as "the invitee binds a credential it drew"
  assert claimed.sessions == [claim.Membership(session, "operator")]
  let assert Ok(bytes) =
    native.read_private_bounded(claim.credential_path(remote), 64)
    as "the stored credential is private"
  let assert Ok(credential) = bit_array.to_string(bytes)
  let #(socket, response) =
    wire.connect(port, credential, "/v2/sessions/" <> session <> "/ws")
  assert string.contains(response, "101 Switching Protocols")
  let begin = wire.subscribe(socket, 1, session, within_ms: wire_read_ms)
  assert field(field(begin, "body"), "role") == json.String("operator")

  // After the claim the listing shows the credential's fingerprint and when
  // the claim was redeemed, and still not the credential.
  let #(relisted, after_claim) =
    access_output(server, directory, paths, ["list"])
  assert relisted == 0
  assert string.contains(after_claim, "\"claimed_at_ms\":")
  assert string.contains(
    after_claim,
    "\"fingerprint\":\"" <> claimed.fingerprint <> "\"",
  )
  assert !string.contains(after_claim, credential)

  // The spent claim buys nothing: another credential is refused, and the
  // claim string is not a bearer.
  let assert Ok(replay) =
    claim.remote(claim.Options(address, "replay", directory <> "/invitee", ""))
    as "a second remote directory for the replay"
  assert claim.redeem(replay, issued, "") == Error(claim.Refused("conflict"))
  let #(bearer_socket, bearer_response) =
    wire.connect(port, issued, "/v2/control")
  assert string.contains(bearer_response, "401 Unauthorized")
  let _ = ffi_ws.tcp_close(bearer_socket)

  // The owner revokes the member; the attachment closes at its next frame.
  let #(revoked, _) =
    access(server, directory, paths, ["revoke-credentials", "alice"])
  assert revoked == 0
  let text =
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("id", json.Int(2)),
        #("cmd", json.String("snapshot_next")),
        #(
          "body",
          json.Object([
            #("snapshot_id", field(field(begin, "body"), "snapshot_id")),
            #("index", json.Int(0)),
          ]),
        ),
      ]),
    )
  let payload = bit_array.from_string(text)
  let size = bit_array.byte_size(payload)
  assert ffi_daemon_socket.send(socket, <<
      0x81,
      1:1,
      size:7,
      0:32,
      payload:bits,
    >>)
    == Ok(Nil)
  assert closes(socket, 8)
  let _ = ffi_ws.tcp_close(socket)
  daemon.close(connected.control)

  // Nothing the daemon wrote holds the claim or the credential.
  let assert Ok(files) = simplifile.get_files(paths.root)
    as "the daemon's state directory is readable"
  assert files != []
  list.each(files, fn(path) {
    let assert Ok(content) = simplifile.read_bits(path) as "state file reads"
    assert !contains(content, bit_array.from_string(issued))
    assert !contains(content, bit_array.from_string(credential))
  })
}

// Waits for a session to become resident. A start failure ends the wait at
// once, with the daemon log's classified cause in the message, rather than
// leaving the fixture to run into its deadline with nothing to read.
fn await_resident(control, session: String, paths: endpoint.Paths) -> Nil {
  let before = list.length(start_failures(paths))
  let outcome =
    daemon_observation.session_until(
      control,
      session,
      within: 20_000,
      every: 50,
      inspect: fn(row) {
        case row.status {
          protocol.Resident(..) -> poll.Done(Nil)
          protocol.Reserved
          | protocol.Saved
          | protocol.Opening(_)
          | protocol.Stopping(_)
          | protocol.RecoveryBlocked ->
            case list.drop(start_failures(paths), before) {
              [] -> poll.Retry
              causes -> poll.Fail(string.join(causes, "\n"))
            }
        }
      },
    )
  case outcome {
    poll.Answered(Nil) -> Nil
    other ->
      panic as {
        "session "
        <> session
        <> " did not become resident: "
        <> string.inspect(other)
        <> "\ndaemon log: "
        <> string.join(start_failures(paths), "\n")
      }
  }
}

// The daemon log's start-failure and other error records. The start
// failures carry only fixed stage and class labels and a session identity,
// never a path or a secret.
fn start_failures(paths: endpoint.Paths) -> List(String) {
  case simplifile.read(paths.log) {
    Error(_) -> []
    Ok(text) ->
      string.split(text, "\n")
      |> list.filter(fn(line) {
        string.contains(line, "session_start_failed")
        || string.contains(line, "domain_start_failed")
        || string.contains(line, "\"level\":\"error\"")
      })
  }
}

// Runs the shipped `loomd access` command against this fixture's state
// directory and answers its exit status and its standard output's JSON line.
fn access(
  server: String,
  directory: String,
  paths: endpoint.Paths,
  arguments: List(String),
) -> #(Int, JsonValue) {
  let assert Ok(#(status, output)) =
    ffi_proc.run(
      server,
      ["access", "--state-dir", paths.root, ..arguments],
      in: directory,
    )
    as "the shipped access command runs"
  let reply =
    string.split(output, "\n")
    |> list.find_map(fn(line) {
      case string.starts_with(line, "{") {
        True -> json.parse(line) |> result.replace_error(Nil)
        False -> Error(Nil)
      }
    })
  #(status, result.unwrap(reply, json.Null))
}

// The same command, answering its exit status and its whole standard output,
// for a command that prints more than one line.
fn access_output(
  server: String,
  directory: String,
  paths: endpoint.Paths,
  arguments: List(String),
) -> #(Int, String) {
  let assert Ok(result) =
    ffi_proc.run(
      server,
      ["access", "--state-dir", paths.root, ..arguments],
      in: directory,
    )
    as "the shipped access command runs"
  result
}

// Reads frames until a close frame or TCP close; a pushed text frame before
// the close is allowed, a reply to the post-revocation frame is not.
fn closes(socket, remaining: Int) -> Bool {
  case remaining, ffi_ws.tcp_receive(socket, 2, wire_read_ms) {
    0, _ -> False
    _, Ok(<<0x88, _>>) -> True
    _, Ok(<<0x81, marker>>) -> {
      let size = case marker {
        126 -> {
          let assert Ok(<<size:16>>) = ffi_ws.tcp_receive(socket, 2, 1000)
          size
        }
        size -> size
      }
      let assert Ok(frame) = ffi_ws.tcp_receive(socket, size, 1000)
      let assert Ok(text) = bit_array.to_string(frame)
      case string.contains(text, "\"reply_to\":2") {
        True -> False
        False -> closes(socket, remaining - 1)
      }
    }
    _, Ok(_) -> False
    _, Error(_) -> True
  }
}

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "the value is an object"
  let assert Ok(found) = list.key_find(fields, key) as "the field is present"
  found
}

fn contains(haystack: BitArray, needle: BitArray) -> Bool {
  let size = bit_array.byte_size(needle)
  contains_from(haystack, needle, size, 0, bit_array.byte_size(haystack) - size)
}

fn contains_from(haystack, needle, size, offset, last) -> Bool {
  case offset > last {
    True -> False
    False ->
      case bit_array.slice(haystack, offset, size) == Ok(needle) {
        True -> True
        False -> contains_from(haystack, needle, size, offset + 1, last)
      }
  }
}

fn retire_native(paths: endpoint.Paths) -> Nil {
  let assert Ok(record) = endpoint.load(paths)
    as "cleanup decodes its private native reservation"
  case record {
    None -> Nil
    Some(record) -> {
      let assert Ok(present) = endpoint.is_present(record.fence)
        as "cleanup checks original PID birth before signalling"
      case present {
        True -> native.terminate_process_group(record.fence.pid)
        False -> Nil
      }
      let assert poll.Answered(Nil) =
        poll.until(within: 10_000, every: 25, attempt: fn() {
          case endpoint.is_present(record.fence) {
            Ok(False) -> poll.Done(Nil)
            Ok(True) -> poll.Retry
            Error(reason) -> poll.Fail(reason)
          }
        })
        as "actual native departure is witnessed before fixture completion"
      Nil
    }
  }
}
