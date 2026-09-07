//// Distinct native terminal drivers against the shipped daemon executable.
////
//// The owner creates and explicitly isolates one session before issuing real
//// member credentials. Only Alice's terminal changes configuration; Bob and
//// the observer must receive its value and server-assigned origin over their
//// own sockets. Two real provider requests then establish shared durable order;
//// the loopback peer answers only the exact latest user text in its script.
//// Bob then leaves and rejoins; every remaining terminal must observe both
//// presence transitions without confusing principal and attachment identity.
//// Member credentials cannot reach a second workspace's session, and an
//// observer's raw mutation must be refused independently of the TUI guard.
//// Revoking Bob's membership then closes his existing attachments while the
//// remaining members continue exchanging authoritative configuration updates.
//// A revoked selector target must fail without replacing Alice's original
//// channel, which must still accept and deliver a later configuration change.
//// A subsequent successful A-to-B-to-A switch keeps Reader attached to A;
//// two more provider turns prove independent histories and complete catch-up.
//// The coordinator retains the endpoint path outside the bounded body, so a
//// failed assertion still retires the native lifetime before reporting failure.

import client/daemon/admin
import client/daemon_server_test as wire
import client/session_socket_test
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/tui_v2_test
import core/entry
import core/json
import core/message
import etui/backend
import filepath
import gleam/bit_array
import gleam/dict
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap as native
import host/endpoint
import machine/strand
import simplifile
import support/enforcement
import support/internal/ffi_daemon_socket
import support/internal/ffi_ws
import support/provider_http
import support/tui_driver
import tui
import tui/attachment
import tui/bootstrap
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui/protocol as conversation
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import weft
import weft/actor
import weft/poll

// The same prerequisite selects both the optional drive and its exact provider
// suffix. A skipped tool must not make unrelated multiplayer requests optional.
type LiveTool {
  RunLiveTool
  SkipLiveTool
}

// CI run 34056261144 exceeded the component's eight-second cold-open wait on
// macOS. This fixture alone allows twenty seconds for initial session opening.
const shipped_open_timeout_ms = 20_000

// `daemon_server_test.frame`'s 1 s default assumes an in-process fixture;
// against the shipped daemon it must instead cover session_socket.admit's
// own budget — a one-second root permit transfer plus a five-second
// gateway attach (`packages/client/src/client/daemon/session_socket.gleam`,
// the module doc and `admit`) — before the reply this fixture is reading
// for can be written at all. Ten seconds pays that budget in full on a
// loaded runner without silently swallowing a wedged daemon, and stays
// well inside this fixture's own eunit timeout.
const wire_read_ms = 10_000

// This command owns only fixture workspace markers. Its internal deadline
// prevents an assertion failure from leaving a shell waiting for test cleanup.
fn held_arguments() -> json.JsonValue {
  json.Object([
    #(
      "command",
      json.String(
        "printf started > live-started; for ((i=0;i<200;i++)); do if test -f live-release; then printf 'completed\\n' >> live-completed; printf 'RELEASED-ONCE\\n'; exit 0; fi; sleep 0.1; done; printf 'fixture release expired\\n' >&2; exit 1",
      ),
    ),
    #("timeout_ms", json.Int(30_000)),
  ])
}

fn live_tool_script(mode: LiveTool) -> List(provider_http.Exchange) {
  case mode {
    SkipLiveTool -> []
    RunLiveTool -> [
      provider_http.ToolUseExchange(
        "hold A tool",
        "held-call",
        "bash",
        held_arguments(),
      ),
      provider_http.Exchange("A2 progresses while held", "a2heldanswer"),
      provider_http.Exchange("B progresses while held", "bheldanswer"),
      provider_http.ToolResultExchange(
        "held-call",
        "RELEASED-ONCE\n",
        "heldafinalanswer",
      ),
    ]
  }
}

fn live_tool_expected(mode: LiveTool) -> List(provider_http.Latest) {
  case mode {
    SkipLiveTool -> []
    RunLiveTool -> [
      provider_http.UserPrompt("hold A tool"),
      provider_http.UserPrompt("A2 progresses while held"),
      provider_http.UserPrompt("B progresses while held"),
      provider_http.SuccessfulToolResult("held-call", "RELEASED-ONCE\n"),
    ]
  }
}

// One measured verdict from the shared probe, mapped onto this fixture's
// own two-value question. The probe owns the skip line and the reason a
// declaration matches on; the label is what tells a census which fixture
// declined.
fn live_tool_prerequisite(server: String) -> LiveTool {
  case enforcement.probe(server, "shipped multiplayer live tool") {
    enforcement.EnforcementLive -> RunLiveTool
    enforcement.EnforcementAbsent -> SkipLiveTool
  }
}

// Shipped cold attachment can exceed the component helper's eight seconds on
// loaded macOS runners. Only initial opening gets this bounded allowance;
// mutation, provider completion, and the fifteen-second tool marker do not.
fn await_open(
  driver: process.Subject(tui_driver.Message),
  predicate: fn(tui_driver.Sample) -> Bool,
) -> tui_driver.Sample {
  let outcome =
    poll.fold_until(
      clock: poll.monotonic(),
      within: shipped_open_timeout_ms,
      every: poll.Fixed(10),
      from: "no terminal sample",
      attempt: fn(_) {
        let sample = tui_driver.play(driver, [])
        case predicate(sample) {
          True -> poll.Settled(sample)
          False -> poll.Pending(string.slice(sample.model.notice, 0, 512))
        }
      },
    )
  case outcome {
    poll.Answer(sample) -> sample
    poll.RanOut(notice) -> {
      let reason = "shipped session-open deadline: " <> notice
      panic as reason
    }
    poll.Failure(reason) -> panic as reason
  }
}

pub fn tui_shipped_multiplayer_configuration_fans_out_with_author_test_() -> EunitTest {
  // The runner scales EUnit timeouts by ten. The provider callback has 120
  // seconds around the native body's 90-second budget and its cleanup. Leave
  // both original listener witnesses inside this 150-second outer deadline.
  Timeout(15, fn() {
    case native.getenv("LOOM_BOOTSTRAP_E2E_SERVER") {
      Error(Nil) ->
        io.println_error(
          "SKIP shipped multiplayer: LOOM_BOOTSTRAP_E2E_SERVER is unset",
        )
      Ok(server) -> {
        assert native.getenv("LOOM_TEST_PROVIDER_KEY")
          == Ok(provider_http.dummy_key)
          as "the shipped provider receives only the fixture's public dummy key"
        let live_tool = live_tool_prerequisite(server)
        let #(Nil, report) =
          provider_http.with_server(
            list.append(
              [
                provider_http.Exchange("first shipped turn", "shippedanswerone"),
                provider_http.Exchange(
                  "second shipped turn",
                  "shippedanswertwo",
                ),
                provider_http.Exchange("isolated B turn", "isolatedbanswer"),
                provider_http.Exchange(
                  "A continues during switch",
                  "continuingaanswer",
                ),
              ],
              live_tool_script(live_tool),
            ),
            fn(base_url) { fixture(server, base_url, live_tool) },
          )
        let assert Ok(observed) = report
          as "all prerequisite-selected exact provider requests complete without a refused or extra call"
        assert list.map(observed, fn(request) { request.latest })
          == list.append(
            [
              provider_http.UserPrompt("first shipped turn"),
              provider_http.UserPrompt("second shipped turn"),
              provider_http.UserPrompt("isolated B turn"),
              provider_http.UserPrompt("A continues during switch"),
            ],
            live_tool_expected(live_tool),
          )
      }
    }
  })
}

fn fixture(server: String, provider_url: String, live_tool: LiveTool) -> Nil {
  let directory =
    "build/shipped-multiplayer-"
    <> int.to_string(native.current_process_id())
    <> "-"
    <> int.to_string(native.system_time_ms())
  let assert Ok(Nil) = native.ensure_private_directory(directory)
    as "fixture credentials and logs live below a private directory"
  let assert Ok(directory) = native.canonical_directory(directory)
    as "the native daemon receives absolute fixture paths"
  let assert Ok(paths) = endpoint.paths(directory <> "/state")
    as "cleanup retains the endpoint path before native startup"
  io.println_error("shipped multiplayer fixture: " <> directory)
  let outcomes =
    weft.new([
      fn() {
        exercise(server, directory, paths, provider_url, live_tool)
        Ok(Nil)
      },
    ])
    |> weft.deadline(90_000)
    |> weft.start

  // The body may fail even during bootstrap, before publishing a connection.
  // Read its private reservation after the worker has stopped; never infer
  // native retirement from that worker's exit or from a closed control socket.
  retire_native(paths)
  let assert [weft.Completed(0, Nil)] = outcomes
    as "the shipped configuration drive completes inside its deadline"
  Nil
}

fn exercise(
  server: String,
  directory: String,
  paths: endpoint.Paths,
  provider_url: String,
  live_tool: LiveTool,
) -> Nil {
  let workspace = filepath.join(directory, "workspace")
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the session workspace exists independently of private daemon state"
  let configuration = filepath.join(directory, "fixture.toml")
  let assert Ok(Nil) =
    simplifile.write(
      configuration,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"LOOM_TEST_PROVIDER_KEY\"\nbase_url = \""
        <> provider_url
        <> "\"\nmodel_id = \"fixture\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    as "normal provider configuration selects the loopback peer with maintenance off"
  let options =
    bootstrap.Options(workspace, "", server, paths.root, configuration)
  let assert Ok(connected) =
    bootstrap.resolve_daemon(options, process.self(), 40_000)
    as "the supplied shipped executable authenticates through native bootstrap"
  let assert Ok(address) = endpoint.address(connected.record)
    as "the published native endpoint supplies the real control address"
  let assert Ok(token) = simplifile.read(connected.paths.token)
    as "the private owner credential is available only to fixture setup"
  let owner = string.trim(token)
  let protocol.Epoch(epoch) = daemon.hello(connected.control).epoch
  let assert Ok(host) = selection.host(connected.control, address, owner)
    as "the authenticated control retains its own route"
  let assert Ok(target) =
    selection.create(host, "shipped-members", workspace, configuration)
    as "explicit creation opens the fixture session"
  let id = target.expected.session

  // Sharing is not a fixture bypass: ordinary creation is workspace-private.
  // Stop it before the owner's explicit isolation acknowledgement, then use
  // the real invitation and reopen paths without touching the session store.
  let assert Ok(_) =
    daemon.request(connected.control, protocol.StopSession(id), 5000)
    as "the owner requests retirement before changing isolation scope"
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case daemon.request(connected.control, protocol.GetSession(id), 2000) {
        Ok(protocol.SessionReply(protocol.Session(status: protocol.Saved, ..))) ->
          poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "isolation waits for the runtime's retirement witness"
  let assert Ok(isolate) =
    admin.parse(["isolate", id, "--share-existing-transcript"])
    as "the owner explicitly acknowledges transcript sharing"
  let assert Ok(_) = admin.exchange(address, owner, epoch, isolate)
    as "the shipped daemon enforces and persists session-only scope"
  let alice_token =
    invite(address, owner, epoch, id, "alice", "operator", "Alice")
  let bob_token = invite(address, owner, epoch, id, "bob", "operator", "Bob")
  let reader_token =
    invite(address, owner, epoch, id, "reader", "observer", "Reader")
  let assert Ok(_) = selection.open(host, id)
    as "only the owner's explicit reopen starts the isolated session"

  // A real second runtime makes refusal distinguish authorization from absence.
  // Its owner-issued incarnation also makes operation lookup a valid request.
  let foreign_workspace = filepath.join(directory, "workspace-b")
  let assert Ok(Nil) = simplifile.create_directory_all(foreign_workspace)
    as "the uninvited session has a distinct real workspace mapping"
  let assert Ok(foreign) =
    selection.create(
      host,
      "uninvited-session",
      foreign_workspace,
      configuration,
    )
    as "the owner creates an independently resident uninvited session"
  let assert endpoint.Ready(port:, ..) = connected.record
    as "authenticated bootstrap retains the published listener port"
  invitation_boundaries(
    address,
    port,
    owner,
    [#(alice_token, snapshot.Operator), #(reader_token, snapshot.Observer)],
    id,
    foreign.expected,
    connected.control,
  )
  observer_mutation_refused(port, reader_token, id)

  let assert Ok(alice) = tui_driver.start(address, alice_token, id)
    as "Alice owns one native terminal and socket"
  let assert Ok(bob) = tui_driver.start(address, bob_token, id)
    as "Bob owns a separate native terminal and socket"
  let assert Ok(reader) = tui_driver.start(address, reader_token, id)
    as "the observer attaches without opening execution"
  let alice_ready = await_open(alice.data, writable)
  let bob_ready = await_open(bob.data, writable)
  let observed =
    await_open(reader.data, fn(sample) {
      case sample.model.captured {
        Some(#(cut, view)) ->
          cut.attachment.role == snapshot.Observer
          && list.length(view.peers) == 3
        None -> False
      }
    })
  assert !writable(observed)
  list.each(
    [
      #(alice_ready, "alice", snapshot.Operator),
      #(bob_ready, "bob", snapshot.Operator),
      #(observed, "reader", snapshot.Observer),
    ],
    fn(identity) {
      let #(sample, principal, role) = identity
      let assert Some(#(cut, _)) = sample.model.captured
        as "each native client has authenticated attachment metadata"
      assert cut.attachment.origin.principal == principal
      assert cut.attachment.role == role
    },
  )

  let _ =
    tui_driver.play(alice.data, [
      backend.Paste("/effort high"),
      backend.KeyPress("enter"),
    ])
  let alice_view = tui_v2_test.await(alice.data, changed)
  let bob_view = tui_v2_test.await(bob.data, changed)
  let reader_view = tui_v2_test.await(reader.data, changed)
  assert configuration_of(alice_view) == configuration_of(bob_view)
  assert configuration_of(alice_view) == configuration_of(reader_view)
  assert string.contains(reader_view.frame, "changed by Alice")
  assert !writable(reader_view)

  // Only the terminal submits the prompt. The network peer checks the latest
  // user message before responding; all clients must render the durable turn
  // and observe completion before the next actor changes the conversation.
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste("first shipped turn"),
      backend.KeyPress("enter"),
    ])
  assert_shared_turns(
    [alice, bob, reader],
    [
      #("alice", "first shipped turn"),
    ],
    ["shippedanswerone"],
  )

  // Driver exit is not a server detach barrier. Wait for both surviving
  // terminals to lose Bob before reusing his credential on a fresh socket.
  let old_bob = attachment_of(bob_view).connection_id
  stop_driver(bob)
  list.each([alice, reader], fn(driver) {
    let detached =
      tui_v2_test.await(driver.data, fn(sample) {
        has_principals(sample, ["alice", "reader"])
      })
    assert configuration_of(detached) == configuration_of(alice_view)
  })
  let assert Ok(rejoined) = tui_driver.start(address, bob_token, id)
    as "Bob rejoins the same session with his unchanged member credential"
  let bob_returned =
    tui_v2_test.await(rejoined.data, fn(sample) {
      writable(sample) && has_principals(sample, ["alice", "bob", "reader"])
    })
  let new_bob = attachment_of(bob_returned).connection_id
  assert new_bob != old_bob

  // The principal survives reconnection, but its old attachment must not.
  // Compare exact presence identities and roles at each terminal's own cut.
  list.each([alice, rejoined, reader], fn(driver) {
    let returned =
      tui_v2_test.await(driver.data, fn(sample) {
        has_principals(sample, ["alice", "bob", "reader"])
        && list.any(peers_of(sample), fn(peer) {
          peer.origin.principal == "bob" && peer.connection_id == new_bob
        })
      })
    let peers = peers_of(returned)
    assert !list.any(peers, fn(peer) { peer.connection_id == old_bob })
    assert dict.size(
        dict.from_list(list.map(peers, fn(peer) { #(peer.connection_id, Nil) })),
      )
      == 3
    list.each(peers, fn(peer) {
      let expected = case peer.origin.principal {
        "reader" -> snapshot.Observer
        _ -> snapshot.Operator
      }
      assert peer.role == expected
    })
    assert configuration_of(returned) == configuration_of(alice_view)
  })

  // Rejoining must recover the first durable turn before Bob submits another.
  // The second request includes history, so an old prompt marker alone cannot
  // select its response from the finite provider script.
  assert_shared_turns(
    [alice, rejoined, reader],
    [
      #("alice", "first shipped turn"),
    ],
    ["shippedanswerone"],
  )
  let _ =
    tui_driver.play(rejoined.data, [
      backend.Paste("second shipped turn"),
      backend.KeyPress("enter"),
    ])
  assert_shared_turns(
    [alice, rejoined, reader],
    [
      #("alice", "first shipped turn"),
      #("bob", "second shipped turn"),
    ],
    ["shippedanswerone", "shippedanswertwo"],
  )

  revoke_live_member(
    address,
    port,
    owner,
    epoch,
    id,
    bob_token,
    alice,
    rejoined,
    reader,
  )
  failed_switch_preserves_channel(
    host,
    address,
    owner,
    epoch,
    foreign.expected.session,
    alice,
    reader,
  )
  successful_switches(
    address,
    owner,
    epoch,
    daemon.hello(connected.control).principal,
    id,
    foreign.expected.session,
    alice,
    reader,
  )
  case live_tool {
    SkipLiveTool -> Nil
    RunLiveTool ->
      live_tool_switches(
        host,
        address,
        owner,
        epoch,
        workspace,
        configuration,
        id,
        foreign.expected.session,
        alice,
        reader,
      )
  }

  // Observe each driver exit before retiring the native daemon. Failure of
  // any preceding assertion instead closes them through their worker links.
  list.each([alice, rejoined, reader], stop_driver)
  daemon.close(connected.control)
}

// A1 retains execution custody while the terminal rejects A2, then visits A2
// and B. The shell's release is causally after both independent provider turns.
// Workspace markers witness this benign execution, not kernel confinement.
fn live_tool_switches(
  host: selection.Host,
  address: String,
  owner: String,
  epoch: String,
  workspace: String,
  configuration: String,
  original: String,
  foreign: String,
  alice: actor.Started(process.Subject(tui_driver.Message)),
  reader: actor.Started(process.Subject(tui_driver.Message)),
) -> Nil {
  let assert Ok(target) =
    selection.create(host, "held-tool-a2", workspace, configuration)
    as "A2 is a separate durable session in A1's actual workspace"
  let a2 = target.expected.session
  let control = selection.control(host)
  let assert Ok(_) = daemon.request(control, protocol.StopSession(a2), 5000)
    as "A2 retires before the owner changes its sharing scope"
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case daemon.request(control, protocol.GetSession(a2), 2000) {
        Ok(protocol.SessionReply(protocol.Session(status: protocol.Saved, ..))) ->
          poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "A2's original runtime is saved before isolation"
  owner_command(address, owner, epoch, [
    "isolate",
    a2,
    "--share-existing-transcript",
  ])
  owner_command(address, owner, epoch, ["set-role", a2, "alice", "operator"])
  let assert Ok(_) = selection.open(host, a2)
    as "A2 is genuinely resident before entering the selector"

  // Independent A1 terminals retain their original attachments while Alice
  // replaces hers, so their final captures witness execution custody.
  let assert Ok(peer) = tui_driver.start(address, owner, original)
    as "an independent owner stays with Reader on A1 throughout the tool"
  let before = tui_v2_test.await(peer.data, writable)
  let original_attachment = attachment_of(before)
  let prior_messages = recorded_messages(before)
  let reader_attachment = attachment_of(tui_driver.play(reader.data, []))

  // Receipt of the marker and the credited tools phase are independent
  // observations: neither a provider response nor a painted label is enough.
  let submitted =
    tui_driver.play(alice.data, [
      backend.Paste("hold A tool"),
      backend.KeyPress("enter"),
    ])
  let started =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 15_000,
      every: poll.Fixed(10),
      from: submitted,
      attempt: fn(last) {
        case simplifile.read(filepath.join(workspace, "live-started")) {
          Ok("started") -> poll.Settled(Nil)

          // Refreshes complete asynchronously. Drive the ordinary terminal
          // throughout this wait so expiry retains an observed result rather
          // than initiating its first refresh after the deadline.
          Ok(_) | Error(simplifile.Enoent) ->
            poll.Pending(tui_driver.play(alice.data, []))
          Error(reason) -> poll.Broken(#(reason, last))
        }
      },
    )
  // Assertion failures print their matched value. Discard the retained model
  // before asserting, so its credentials cannot enter EUnit's crash report.
  let outcome = case started {
    poll.Answer(Nil) -> Ok(Nil)
    poll.RanOut(last) -> {
      marker_diagnostic(last)
      Error("tool-start marker deadline")
    }
    poll.Failure(#(reason, last)) -> {
      marker_diagnostic(last)
      Error("tool-start marker read: " <> string.inspect(reason))
    }
  }
  let assert Ok(Nil) = outcome
    as "the ordinary shipped bash command actually starts"
  let observed_start = native.monotonic_time_ms()
  list.each([alice, peer, reader], fn(driver) {
    let _ = tui_v2_test.await(driver.data, held_tool)
  })
  let highlighted = highlight_target(alice, a2)
  let original_alice = attachment_of(highlighted)
  let assert Some(channel) = highlighted.model.channel
    as "the selector retains the live original channel"

  // The owner acknowledgement precedes Enter. A2 refusal cannot detach A1
  // or release the tool, even though its durable operation is still live.
  owner_command(address, owner, epoch, ["revoke", a2, "alice"])
  let _ = tui_driver.play(alice.data, [backend.KeyPress("enter")])
  let refused =
    tui_v2_test.await(alice.data, fn(sample) {
      !attachment.busy(sample.model.candidate)
      && sample.model.notice == "open session: not_found: request refused"
      && held_tool(sample)
    })
  assert attachment_of(refused) == original_alice
  assert refused.model.session == original
  assert refused.model.records == highlighted.model.records
  assert refused.model.inbox == highlighted.model.inbox
  let assert Some(retained) = refused.model.channel
    as "the rejected candidate cannot take custody of A1's socket"
  assert session_channel.socket(retained) == session_channel.socket(channel)
  owner_command(address, owner, epoch, ["set-role", a2, "alice", "operator"])
  select_live(alice, a2)
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste("A2 progresses while held"),
      backend.KeyPress("enter"),
    ])
  let assert [a2_done] =
    captured_turns([alice], [#("alice", "A2 progresses while held")], [
      "a2heldanswer",
    ])
    as "A2 completes its independent turn while A1 is held"
  select_live(alice, foreign)
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste("B progresses while held"),
      backend.KeyPress("enter"),
    ])
  let assert [b_done] =
    captured_turns(
      [alice],
      [#("alice", "isolated B turn"), #("alice", "B progresses while held")],
      ["isolatedbanswer", "bheldanswer"],
    )
    as "the distinct workspace B also progresses before release"

  // Both A1 peers still project the tools phase; this observation alone is
  // not fresh liveness proof. Successful completion after the host's release
  // establishes that the bounded shell survived the intervening switches.
  list.each([peer, reader], fn(driver) {
    let _ = tui_v2_test.await(driver.data, held_tool)
  })
  io.println_error(
    "held tool: ms from start marker to release: "
    <> int.to_string(native.monotonic_time_ms() - observed_start),
  )
  let assert Ok(Nil) =
    simplifile.write(filepath.join(workspace, "live-release"), "release")
    as "host release follows both positively completed independent turns"
  let owner_done = tui_v2_test.await(peer.data, completed_tool)
  let reader_done =
    tui_v2_test.await(reader.data, fn(sample) {
      completed_tool(sample) && sample.model.records == owner_done.model.records
    })
  assert attachment_of(owner_done) == original_attachment
  assert attachment_of(reader_done) == reader_attachment
  assert reader_done.model.session == original
  assert list.drop(recorded_messages(owner_done), 4) == prior_messages
  let assert [
    message.AssistantMessage(content: final, ..),
    message.ToolResultMessage(
      tool_call_id: call_id,
      tool_name: name,
      content: output,
      is_error: error,
      ..,
    ),
    message.AssistantMessage(content: invocation, stop_reason: stop, ..),
    message.UserMessage(content: prompt, origin: Some(author), ..),
    ..
  ] = recorded_messages(owner_done)
    as "A1 durably orders user, invocation, exact result, and final answer"
  assert prompt == [message.UserText("hold A tool", None)]
  assert author.principal == "alice"
  assert invocation
    == [
      message.AssistantToolCall(message.ToolCall(
        "held-call",
        "bash",
        held_arguments(),
        namespace: None,
        thought_signature: None,
      )),
    ]
  assert stop == message.ToolUse
  assert call_id == "held-call"
  assert name == "bash"
  assert !error
  assert output == [message.ToolResultText("RELEASED-ONCE\n", None)]
  assert final == [message.AssistantText("heldafinalanswer", None)]
  assert simplifile.read(filepath.join(workspace, "live-completed"))
    == Ok("completed\n")

  // Fresh native attachments after A1's completion obtain new accepted cuts,
  // rather than treating an unchanged local frame as an isolation barrier.
  list.each([#(a2, a2_done), #(foreign, b_done)], fn(target) {
    let assert Ok(probe) = tui_driver.start(address, owner, target.0)
      as "the owner obtains a fresh post-completion cut for the other session"
    let sample = tui_v2_test.await(probe.data, writable)
    assert sample.model.session == target.0
    assert sample.model.records == target.1.model.records
    stop_driver(probe)
  })
  select_live(alice, original)
  let returned =
    tui_v2_test.await(alice.data, fn(sample) {
      completed_tool(sample) && sample.model.records == owner_done.model.records
    })
  assert attachment_of(returned).expected == original_alice.expected
  stop_driver(peer)
}

// The consumed response orders owner authority changes before native input.
fn owner_command(
  address: String,
  owner: String,
  epoch: String,
  arguments: List(String),
) -> Nil {
  let assert Ok(command) = admin.parse(arguments)
    as "membership changes use the public owner command parser"
  let assert Ok(_) = admin.exchange(address, owner, epoch, command)
    as "the owner consumes each acknowledgement before dependent UI input"
  Nil
}

// Selection always uses the real page and its highlighted target assertion.
fn select_live(
  driver: actor.Started(process.Subject(tui_driver.Message)),
  target: String,
) -> Nil {
  let _ = highlight_target(driver, target)
  let _ = tui_driver.play(driver.data, [backend.KeyPress("enter")])
  let _ =
    tui_v2_test.await(driver.data, fn(sample) {
      writable(sample) && sample.model.session == target
    })
  Nil
}

// Failure diagnostics deliberately exclude the model, credentials and requests.
fn marker_diagnostic(sample: tui_driver.Sample) -> Nil {
  let phase = case
    list.find(sample.model.strands, fn(row) { row.id == "main" })
  {
    Ok(row) ->
      case row.live_phase {
        Some(value) -> value
        None -> "idle"
      }
    Error(Nil) -> "missing"
  }
  io.println_error(
    "held tool marker absent: phase="
    <> string.slice(phase, 0, 64)
    <> " notice="
    <> string.inspect(string.slice(sample.model.notice, 0, 512)),
  )
  let latest =
    list.find(sample.model.records, fn(record) {
      case record.entry {
        entry.MessageEntry(message: message.ToolResultMessage(..), ..) -> True
        _ -> False
      }
    })
  case latest {
    Ok(record) -> marker_result(record.entry)
    Error(Nil) -> io.println_error("held tool latest result: absent")
  }
}

// Clip individual text blocks before joining; image bytes never enter logs.
fn marker_result(record: entry.Entry) -> Nil {
  case record {
    entry.MessageEntry(
      message: message.ToolResultMessage(content:, is_error:, ..),
      ..,
    ) -> {
      let status = case is_error {
        True -> "error"
        False -> "success"
      }
      let output =
        list.map(list.take(content, 2), fn(block) {
          case block {
            message.ToolResultText(text, _) -> string.slice(text, 0, 512)
            message.ToolResultImage(..) -> "[image omitted]"
          }
        })
      io.println_error(
        "held tool latest result: "
        <> status
        <> " "
        <> string.inspect(string.join(output, "\n")),
      )
    }
    _ -> Nil
  }
}

// The gateway projects this phase from the durable main-strand operation.
fn held_tool(sample: tui_driver.Sample) -> Bool {
  list.any(sample.model.strands, fn(strand) {
    strand.id == "main" && strand.live_phase == Some("tools")
  })
}

// Settlement requires the final durable message and the idle strand, not just
// a transient text delta or disappearance of the tools phase.
fn completed_tool(sample: tui_driver.Sample) -> Bool {
  case recorded_messages(sample) {
    [
      message.AssistantMessage(
        content: [message.AssistantText("heldafinalanswer", None)],
        ..,
      ),
      ..
    ] ->
      list.any(sample.model.strands, fn(strand) {
        strand.id == "main" && strand.live_phase == None
      })
      && sample.model.streams == []
      && sample.model.submitting == None
    _ -> False
  }
}

// Preserve every message variant in the oracle, including invocation and
// result. Only non-message records such as configuration are projected away.
fn recorded_messages(sample: tui_driver.Sample) -> List(message.AgentMessage) {
  list.filter_map(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(message:, ..) -> Ok(message)
      _ -> Error(Nil)
    }
  })
}

fn failed_switch_preserves_channel(
  host: selection.Host,
  address: String,
  owner: String,
  epoch: String,
  target: String,
  alice: actor.Started(process.Subject(tui_driver.Message)),
  reader: actor.Started(process.Subject(tui_driver.Message)),
) -> Nil {
  // Reuse the foreign runtime only after the earlier isolation refusals.
  // Session-only sharing requires actual retirement and explicit owner consent.
  let control = selection.control(host)
  let assert Ok(_) = daemon.request(control, protocol.StopSession(target), 5000)
    as "the owner stops the target before changing its isolation scope"
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 25, attempt: fn() {
      case daemon.request(control, protocol.GetSession(target), 2000) {
        Ok(protocol.SessionReply(protocol.Session(status: protocol.Saved, ..))) ->
          poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(reason) -> poll.Fail(reason)
      }
    })
    as "the target's original runtime retires before transcript sharing"
  list.each(
    [
      ["isolate", target, "--share-existing-transcript"],
      ["set-role", target, "alice", "operator"],
    ],
    fn(arguments) {
      let assert Ok(request) = admin.parse(arguments)
        as "the owner uses existing public isolation and membership commands"
      let assert Ok(_) = admin.exchange(address, owner, epoch, request)
        as "the existing Alice principal receives only target session membership"
    },
  )
  let assert Ok(_) = selection.open(host, target)
    as "the selectable target is a real resident session before revocation"

  let highlighted = highlight_target(alice, target)
  let original = attachment_of(highlighted)
  let assert Some(original_channel) = highlighted.model.channel
    as "Alice retains her already synchronized original session channel"

  // The acknowledgement happens before Enter across these two connections.
  // No command was queued before revocation, and only the target grant changes.
  let assert Ok(revoke) = admin.parse(["revoke", target, "alice"])
    as "revocation is scoped to the highlighted target, not Alice's credential"
  let assert Ok(_) = admin.exchange(address, owner, epoch, revoke)
    as "the owner observes target membership removal before selection executes"
  let _ = tui_driver.play(alice.data, [backend.KeyPress("enter")])
  let refused =
    tui_v2_test.await(alice.data, fn(sample) {
      !attachment.busy(sample.model.candidate)
      && sample.model.notice == "open session: not_found: request refused"
      && writable(sample)
    })

  // Refusal ends the candidate without transferring custody of the old view.
  assert refused.model.session == highlighted.model.session
  assert attachment_of(refused) == original
  assert refused.model.records == highlighted.model.records
  assert refused.model.inbox == highlighted.model.inbox
  let assert Some(retained_channel) = refused.model.channel
    as "candidate refusal preserves the adopted original channel"
  assert session_channel.socket(retained_channel)
    == session_channel.socket(original_channel)

  // A separate owner terminal must still attach to the exact refused target.
  // This excludes target unavailability without touching Alice's retained view.
  let assert Ok(probe) = tui_driver.start(address, owner, target)
    as "the target remains attachable to its authorized owner after Alice's refusal"
  let _ =
    tui_v2_test.await(probe.data, fn(sample) {
      writable(sample) && sample.model.session == target
    })
  stop_driver(probe)

  // The original channel must still perform work after the failed replacement.
  // Both terminals were low after Bob's revocation, so high is a new update.
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste("/effort high"),
      backend.KeyPress("enter"),
    ])
  let alice_updated = tui_v2_test.await(alice.data, changed)
  let reader_updated = tui_v2_test.await(reader.data, changed)

  // The fresh cut and later traffic still belong to the original attachment.
  assert alice_updated.model.session == highlighted.model.session
  assert reader_updated.model.session == highlighted.model.session
  assert configuration_of(alice_updated) == configuration_of(reader_updated)
  assert attachment_of(alice_updated) == original
  let assert Some(updated_channel) = alice_updated.model.channel
    as "continued traffic uses Alice's original adopted channel"
  assert session_channel.socket(updated_channel)
    == session_channel.socket(original_channel)
}

fn successful_switches(
  address: String,
  owner: String,
  epoch: String,
  owner_principal: String,
  original: String,
  target: String,
  alice: actor.Started(process.Subject(tui_driver.Message)),
  reader: actor.Started(process.Subject(tui_driver.Message)),
) -> Nil {
  let assert Ok(grant) = admin.parse(["set-role", target, "alice", "operator"])
    as "the existing principal regains only the explicit target membership"
  let assert Ok(_) = admin.exchange(address, owner, epoch, grant)
    as "membership is restored before Alice requests a fresh catalogue"
  let reader_before = tui_driver.play(reader.data, [])
  let reader_attachment = attachment_of(reader_before)

  // Alice's fresh catalogue must include the regranted target before selection.
  let _ = highlight_target(alice, target)
  let _ = tui_driver.play(alice.data, [backend.KeyPress("enter")])
  let b_ready =
    tui_v2_test.await(alice.data, fn(sample) {
      writable(sample) && sample.model.session == target
    })
  let b_attachment = attachment_of(b_ready)
  assert b_attachment.expected.session == target
  assert b_attachment.origin.principal == "alice"
  assert configuration_of(b_ready).origin == None
    as "B has no earlier human configuration that could satisfy its later barrier"

  // A separate authorized terminal stays on A while Alice uses B. Requests
  // are sequenced for the finite provider, but both runtimes remain attached.
  let assert Ok(peer) = tui_driver.start(address, owner, original)
    as "the independent owner terminal attaches to the original session"
  let peer_ready = tui_v2_test.await(peer.data, writable)
  assert attachment_of(peer_ready).origin.principal == owner_principal
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste("isolated B turn"),
      backend.KeyPress("enter"),
    ])
  let assert [b_completed] =
    captured_turns([alice], [#("alice", "isolated B turn")], ["isolatedbanswer"])
    as "B captures exactly its own first turn, without A's previous history"
  assert b_completed.model.session == target

  let _ =
    tui_driver.play(peer.data, [
      backend.Paste("A continues during switch"),
      backend.KeyPress("enter"),
    ])
  let a_turns = [
    #("alice", "first shipped turn"),
    #("bob", "second shipped turn"),
    #(owner_principal, "A continues during switch"),
  ]
  let a_answers = ["shippedanswerone", "shippedanswertwo", "continuingaanswer"]
  let assert [a_completed, observed] =
    captured_turns([peer, reader], a_turns, a_answers)
    as "A's remaining terminals receive its independently authored third turn"
  assert a_completed.model.records == observed.model.records
  assert attachment_of(observed) == reader_attachment
  assert observed.model.session == original
  assert !writable(observed)

  // After A positively completes, an attributed B configuration change forces
  // a fresh B cut. Exact turn lists then reject cross-session delivery without
  // accepting an unchanged local sample as a server reconciliation barrier.
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste("/effort high"),
      backend.KeyPress("enter"),
    ])
  let _ = tui_v2_test.await(alice.data, changed)
  let assert [b_retained] =
    captured_turns([alice], [#("alice", "isolated B turn")], ["isolatedbanswer"])
    as "Alice remains on B with only B's complete turn after A makes progress"
  assert b_retained.model.records == b_completed.model.records
  assert attachment_of(b_retained) == b_attachment

  // Returning to the resident original must preserve its epoch and incarnation.
  let _ = highlight_target(alice, original)
  let _ = tui_driver.play(alice.data, [backend.KeyPress("enter")])
  let returned =
    tui_v2_test.await(alice.data, fn(sample) {
      writable(sample) && sample.model.session == original
    })
  assert attachment_of(returned).expected == reader_attachment.expected
  assert attachment_of(returned).origin.principal == "alice"
  assert attachment_of(returned).connection_id != b_attachment.connection_id
  assert_shared_turns([peer, alice, reader], a_turns, a_answers)
  assert attachment_of(tui_driver.play(reader.data, [])) == reader_attachment
  stop_driver(peer)
}

fn highlight_target(
  alice: actor.Started(process.Subject(tui_driver.Message)),
  target: String,
) -> tui_driver.Sample {
  // The page itself is the barrier: no synthetic row or guessed list delay can
  // stand in for Alice having obtained this target while it was authorized.
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste("/sessions"),
      backend.KeyPress("enter"),
    ])
  let listed =
    tui_v2_test.await(alice.data, fn(sample) {
      case sample.model.overlay {
        tui.DaemonSelector(selector) ->
          sample.model.catalogue_request == None
          && list.any(selector.page.sessions, fn(row) {
            row.session_id == target
          })
        _ -> False
      }
    })
  let assert tui.DaemonSelector(selector) = listed.model.overlay
    as "the actual authorized selector supplies the target row and selection"

  // Navigation uses the model's row index, never a position guessed from a frame.
  let target_index =
    list.index_fold(selector.page.sessions, -1, fn(found, row, index) {
      case row.session_id == target {
        True -> index
        False -> found
      }
    })
  let direction = case target_index >= selector.selected {
    True -> "down"
    False -> "up"
  }
  let distance = int.absolute_value(target_index - selector.selected)
  let highlighted =
    tui_driver.play(
      alice.data,
      list.repeat(backend.KeyPress(direction), distance),
    )
  let assert tui.DaemonSelector(selected) = highlighted.model.overlay
    as "real navigation keeps the catalogue open until explicit Enter"
  let assert Ok(row) =
    list.first(list.drop(selected.page.sessions, selected.selected))
    as "the highlighted row exists in the server's page"
  assert row.session_id == target
  highlighted
}

fn revoke_live_member(
  address: String,
  port: Int,
  owner: String,
  epoch: String,
  session: String,
  bearer: String,
  alice: actor.Started(process.Subject(tui_driver.Message)),
  bob: actor.Started(process.Subject(tui_driver.Message)),
  reader: actor.Started(process.Subject(tui_driver.Message)),
) -> Nil {
  // Complete one real credited capture before revoking this idle raw socket.
  // Unlike the terminal, this client cannot pre-reject the subsequent mutation.
  let #(socket, response) =
    wire.connect(port, bearer, "/v2/sessions/" <> session <> "/ws")
  assert string.starts_with(response, "HTTP/1.1 101 ")
  let #(_, transfer) =
    session_socket_test.begin(socket, session, within_ms: wire_read_ms)
  let _ =
    session_socket_test.drain(
      socket,
      transfer,
      0,
      [],
      32,
      within_ms: wire_read_ms,
    )

  // An already-disconnected terminal cannot witness membership revocation.
  // Wait through any normal capture before retaining its live, writable cut.
  let before = tui_v2_test.await(bob.data, writable)
  let assert Ok(revoke) = admin.parse(["revoke", session, "bob"])
    as "membership revocation names the existing principal and session"
  let assert Ok(_) = admin.exchange(address, owner, epoch, revoke)
    as "the owner receives acknowledgement of durable membership revocation"

  // Only work sent after that acknowledgement is tested. Earlier admitted
  // commands may finish; this fixture does not isolate the admission/reply gap.
  let bytes =
    bit_array.from_string(conversation.set_thinking(902, "main", "low"))
  let size = bit_array.byte_size(bytes)
  assert size < 126 as "the fixed mutation fits one short masked client frame"
  assert ffi_daemon_socket.send(socket, <<0x81, 1:1, size:7, 0:32, bytes:bits>>)
    == Ok(Nil)
    as "the raw client submits a valid post-revocation mutation"
  let assert Ok(<<0x88, 2, 1000:16>>) = ffi_ws.tcp_receive(socket, 4, 1000)
    as "the server returns a normal WebSocket close, not a mutation reply or crash"
  let assert Error(reason) = ffi_ws.tcp_receive(socket, 1, 1000)
    as "the peer retires the transport after its close frame"
  assert reason == atom.to_dynamic(atom.create("closed"))
    as "actual TCP closure, never timeout, proves transport retirement"
  let _ = ffi_ws.tcp_close(socket)

  // Bob receives no revocation broadcast. His next idle refresh is refused
  // at admission, closing the terminal's independently owned socket too.
  let closed =
    tui_v2_test.await(bob.data, fn(sample) {
      sample.model.peer == tui.Disconnected
    })
  assert closed.model.records == before.model.records
  list.each([alice, reader], fn(driver) {
    let remaining =
      tui_v2_test.await(driver.data, fn(sample) {
        has_principals(sample, ["alice", "reader"])
      })
    assert configuration_of(remaining) == configuration_of(before)
      as "the refused mutation did not change the shared configuration"
  })

  // A positive update after observed closure replaces a timed absence check.
  // Reader receives Alice's new value; Bob retains his last authorized cut.
  let _ =
    tui_driver.play(alice.data, [
      backend.Paste("/effort low"),
      backend.KeyPress("enter"),
    ])
  let updates =
    list.map([alice, reader], fn(driver) {
      let sample =
        tui_v2_test.await(driver.data, fn(sample) {
          let config = configuration_of(sample)
          config.configuration.thinking_level == strand.ThinkingLow
          && config.origin == Some(message.Origin("alice", "Alice"))
        })
      configuration_of(sample)
    })
  let assert [alice_configuration, reader_configuration] = updates
    as "both surviving terminals have completed their own authoritative capture"
  assert alice_configuration == reader_configuration
  let retained = tui_driver.play(bob.data, [])
  assert retained.model.peer == tui.Disconnected
  assert retained.model.records == before.model.records
  assert configuration_of(retained) == configuration_of(before)

  // Membership loss does not revoke the credential itself. An authenticated
  // control remains usable but cannot discover or reattach to this session.
  let assert Ok(control) = daemon.connect(address, bearer, process.self(), 5000)
    as "Bob's unchanged credential still authenticates after membership loss"
  assert daemon.hello(control).principal == "bob"
  let assert Ok(protocol.SessionsReply(page)) =
    daemon.request(control, protocol.ListSessions("", None), 5000)
    as "the revoked member can still request his authorized catalogue"
  assert page.sessions == []
  assert page.after == None
  assert daemon.request(control, protocol.GetSession(session), 5000)
    == Error(daemon.Refused("not_found", "request refused"))
  daemon.close(control)
  let #(socket, response) =
    wire.connect(port, bearer, "/v2/sessions/" <> session <> "/ws")
  assert string.starts_with(response, "HTTP/1.1 409 ")
    as "the same credential cannot replace its revoked attachment"
  let _ = ffi_ws.tcp_close(socket)
  Nil
}

fn invitation_boundaries(
  address: String,
  port: Int,
  owner: String,
  members: List(#(String, snapshot.Role)),
  invited: String,
  foreign: snapshot.Expected,
  control: daemon.Connection,
) -> Nil {
  let epoch = daemon.hello(control).epoch
  list.each(members, fn(credential) {
    let #(bearer, role) = credential
    let assert Ok(member) =
      daemon.connect(address, bearer, process.self(), 5000)
      as "a valid invited credential authenticates a public control connection"

    // A nonempty page carries a cursor even when its continuation is empty.
    let assert Ok(protocol.SessionsReply(page)) =
      daemon.request(member, protocol.ListSessions("", None), 5000)
      as "membership filters the real catalogue before pagination"
    assert list.map(page.sessions, fn(session) { session.session_id })
      == [invited]
    assert page.after == Some(invited)
    let assert Ok(protocol.SessionsReply(last)) =
      daemon.request(
        member,
        protocol.ListSessions(invited, Some(page.revision)),
        5000,
      )
      as "the authorized continuation contains no foreign registration"
    assert last.sessions == []
    assert last.after == None

    // An observer may attach to a resident session but cannot open execution.
    case role {
      snapshot.Observer -> {
        assert daemon.request(member, protocol.OpenSession(invited), 5000)
          == Error(daemon.Refused("forbidden", "request refused"))
          as "observer membership grants attachment but never runtime admission"
      }
      snapshot.Operator | snapshot.Owner -> Nil
    }

    // Valid foreign identities must be indistinguishable from absent ones.
    list.each(
      [
        protocol.GetSession(foreign.session),
        protocol.OpenSession(foreign.session),
        protocol.GetOperation(foreign.session, foreign.incarnation, epoch),
      ],
      fn(command) {
        assert daemon.request(member, command, 5000)
          == Error(daemon.Refused("not_found", "request refused"))
          as "a foreign registration and its valid operation disclose no metadata"
      },
    )

    // Session membership grants no owner-only lifecycle authority.
    list.each(
      [protocol.StopSession(foreign.session), protocol.Shutdown],
      fn(command) {
        assert daemon.request(member, command, 5000)
          == Error(daemon.Refused("forbidden", "request refused"))
          as "member credentials cannot retire a session or its shared daemon"
      },
    )

    // The owner already invited members here, so the target permits sharing.
    let assert Ok(invitation) =
      admin.parse([
        "invite",
        invited,
        "intruder",
        "operator",
        "Intruder",
      ])
      as "the attempted invitation has a valid public command shape"
    assert admin.exchange(address, bearer, epoch.value, invitation)
      == Error("forbidden")
      as "member credentials cannot issue invitations"
    daemon.close(member)

    // The upgrade refusal is an HTTP response, not a timeout or socket failure.
    let #(socket, response) =
      wire.connect(port, bearer, "/v2/sessions/" <> foreign.session <> "/ws")
    assert string.starts_with(response, "HTTP/1.1 409 ")
      as "an authenticated member cannot attach to the foreign runtime"
    let _ = ffi_ws.tcp_close(socket)
  })

  // Positive owner reads and upgrade run after the refusals. They prove the
  // foreign target still exists and shutdown was not silently accepted.
  let assert Ok(protocol.SessionReply(session)) =
    daemon.request(control, protocol.GetSession(foreign.session), 5000)
    as "the foreign runtime remains available to its owner"
  assert session.status == protocol.Resident(foreign.incarnation)
  let assert Ok(_) =
    daemon.request(
      control,
      protocol.GetOperation(foreign.session, foreign.incarnation, epoch),
      5000,
    )
    as "the denied operation is independently valid for its owner"
  let #(socket, response) =
    wire.connect(port, owner, "/v2/sessions/" <> foreign.session <> "/ws")
  assert string.starts_with(response, "HTTP/1.1 101 ")
    as "the same foreign route permits its owner's websocket upgrade"
  let _ = ffi_ws.tcp_close(socket)
  Nil
}

fn observer_mutation_refused(
  port: Int,
  bearer: String,
  session: String,
) -> Nil {
  // The gateway's observer guard precedes subscription dispatch. This valid
  // set_config reaches the shipped server without the terminal's local guard;
  // Alice's later /effort command proves the same mutation shape is supported.
  // That positive control matters because the guard also refuses unknown names.
  let #(socket, response) =
    wire.connect(port, bearer, "/v2/sessions/" <> session <> "/ws")
  assert string.starts_with(response, "HTTP/1.1 101 ")

  // Correlation distinguishes the command's refusal from an unrelated frame.
  let denied =
    wire.send(
      socket,
      901,
      "set_config",
      json.Object([
        #("strand", json.String("main")),
        #("config", json.Object([#("thinking_level", json.String("high"))])),
      ]),
      within_ms: wire_read_ms,
    )
  let assert json.Object(fields) = denied
    as "the server returns a complete envelope"
  assert list.key_find(fields, "reply_to") == Ok(json.Int(901))
  assert list.key_find(fields, "event") == Ok(json.String("error"))
  let assert Ok(json.Object(body)) = list.key_find(fields, "body")
    as "the refusal carries structured server evidence"
  assert list.key_find(body, "code") == Ok(json.String("forbidden"))
  let _ = ffi_ws.tcp_close(socket)
  Nil
}

fn assert_shared_turns(
  drivers: List(actor.Started(process.Subject(tui_driver.Message))),
  turns: List(#(String, String)),
  answers: List(String),
) -> Nil {
  let assert [first, second, observer] = captured_turns(drivers, turns, answers)
    as "the two operators and observer each completed their own credited capture"
  assert first.model.records == second.model.records
  assert first.model.records == observer.model.records
  assert !writable(observer)
}

fn captured_turns(
  drivers: List(actor.Started(process.Subject(tui_driver.Message))),
  turns: List(#(String, String)),
  answers: List(String),
) -> List(tui_driver.Sample) {
  let expected_users =
    list.reverse(turns)
    |> list.map(fn(turn) {
      let #(principal, text) = turn
      #([message.UserText(text, None)], Some(principal))
    })
  let expected_answers =
    list.reverse(answers)
    |> list.map(fn(text) { [message.AssistantText(text, None)] })
  let samples =
    list.map(drivers, fn(driver) {
      tui_v2_test.await(driver.data, fn(sample) {
        let users =
          list.filter_map(sample.model.records, fn(record) {
            case record.entry {
              entry.MessageEntry(
                message: message.UserMessage(content:, origin:, ..),
                ..,
              ) ->
                Ok(#(
                  content,
                  option.map(origin, fn(author) { author.principal }),
                ))
              _ -> Error(Nil)
            }
          })
        let replies =
          list.filter_map(sample.model.records, fn(record) {
            case record.entry {
              entry.MessageEntry(
                message: message.AssistantMessage(content:, ..),
                ..,
              ) -> Ok(content)
              _ -> Error(Nil)
            }
          })
        users == expected_users
        && replies == expected_answers
        && sample.model.streams == []
        && sample.model.submitting == None
        && list.any(sample.model.strands, fn(strand) {
          strand.id == "main" && strand.live_phase == None
        })
        && list.all(answers, fn(answer) {
          string.contains(sample.frame, answer)
        })
      })
    })
  samples
}

fn stop_driver(
  driver: actor.Started(process.Subject(tui_driver.Message)),
) -> Nil {
  let monitor = process.monitor(driver.pid)
  tui_driver.stop(driver.data)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "the native terminal closes normally before daemon teardown"
  Nil
}

fn attachment_of(sample: tui_driver.Sample) -> snapshot.Attachment {
  let assert Some(#(cut, _)) = sample.model.captured
    as "attachment identity comes from the terminal's authenticated capture"
  cut.attachment
}

fn peers_of(sample: tui_driver.Sample) -> List(snapshot_view.Peer) {
  let assert Some(#(_, view)) = sample.model.captured
    as "presence comes from the terminal's coherent capture"
  view.peers
}

fn has_principals(sample: tui_driver.Sample, principals: List(String)) -> Bool {
  case sample.model.captured {
    Some(#(_, view)) ->
      list.length(view.peers) == list.length(principals)
      && list.all(principals, fn(principal) {
        list.count(view.peers, fn(peer) { peer.origin.principal == principal })
        == 1
      })
    None -> False
  }
}

fn invite(address, owner, epoch, session, principal, role, name) {
  let assert Ok(request) =
    admin.parse(["invite", session, principal, role, name])
    as "member setup uses the shipped owner CLI parser"
  let assert Ok(json.Object(fields)) =
    admin.exchange(address, owner, epoch, request)
    as "the native daemon issues the authorized member credential"
  let assert Ok(json.String(bearer)) = list.key_find(fields, "bearer")
    as "the one-shot credential remains fixture-local and is never printed"
  bearer
}

fn writable(sample: tui_driver.Sample) {
  case sample.model.channel {
    Some(channel) -> session_channel.mutation_available(channel)
    None -> False
  }
}

fn configuration_of(sample: tui_driver.Sample) {
  let assert Some(#(_, view)) = sample.model.captured
    as "configuration is read only from a real credited capture"
  let assert Ok(configuration) = dict.get(view.configurations, "main")
    as "the main strand has a projected configuration"
  configuration
}

fn changed(sample: tui_driver.Sample) {
  case sample.model.captured {
    Some(#(_, view)) ->
      case dict.get(view.configurations, "main") {
        Ok(configuration) ->
          case configuration.origin {
            Some(origin) ->
              origin.principal == "alice"
              && origin.name == "Alice"
              && configuration.configuration.thinking_level
              == strand.ThinkingHigh
            None -> False
          }
        Error(Nil) -> False
      }
    None -> False
  }
}

fn retire_native(paths: endpoint.Paths) {
  let assert Ok(record) = endpoint.load(paths)
    as "cleanup can decode its private native reservation"
  case record {
    None -> Nil
    Some(record) -> {
      let assert Ok(present) = endpoint.is_present(record.fence)
        as "cleanup checks the original PID birth before sending any signal"
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
        as "native retirement is witnessed before reporting the fixture result"
      Nil
    }
  }
}
