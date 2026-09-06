//// Distinct native terminal drivers against the shipped daemon executable.
////
//// The owner creates and explicitly isolates one session before issuing real
//// member credentials. Only Alice's terminal changes configuration; Bob and
//// the observer must receive its value and server-assigned origin over their
//// own sockets. Two real provider requests then establish shared durable order;
//// the loopback peer answers only the exact latest user text in its script.
//// Bob then leaves and rejoins; every remaining terminal must observe both
//// presence transitions without confusing principal and attachment identity.
//// The coordinator retains the endpoint path outside the bounded body, so a
//// failed assertion still retires the native lifetime before reporting failure.

import client/daemon/admin
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/tui_v2_test
import core/entry
import core/json
import core/message
import etui/backend
import filepath
import gleam/dict
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
import support/provider_http
import support/tui_driver
import tui/bootstrap
import tui/daemon
import tui/daemon/protocol
import tui/daemon/selection
import tui/session_channel
import tui/snapshot
import tui/snapshot_view
import weft
import weft/actor
import weft/poll

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
        let #(Nil, report) =
          provider_http.with_server(
            [
              provider_http.Exchange("first shipped turn", "shippedanswerone"),
              provider_http.Exchange("second shipped turn", "shippedanswertwo"),
            ],
            fn(base_url) { fixture(server, base_url) },
          )
        let assert Ok(observed) = report
          as "both exact provider requests complete without a refused or extra call"
        assert list.map(observed, fn(request) { request.prompt })
          == ["first shipped turn", "second shipped turn"]
      }
    }
  })
}

fn fixture(server: String, provider_url: String) -> Nil {
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
        exercise(server, directory, paths, provider_url)
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

  let assert Ok(alice) = tui_driver.start(address, alice_token, id)
    as "Alice owns one native terminal and socket"
  let assert Ok(bob) = tui_driver.start(address, bob_token, id)
    as "Bob owns a separate native terminal and socket"
  let assert Ok(reader) = tui_driver.start(address, reader_token, id)
    as "the observer attaches without opening execution"
  let alice_ready = tui_v2_test.await(alice.data, writable)
  let bob_ready = tui_v2_test.await(bob.data, writable)
  let observed =
    tui_v2_test.await(reader.data, fn(sample) {
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

  // Observe each driver exit before retiring the native daemon. Failure of
  // any preceding assertion instead closes them through their worker links.
  list.each([alice, rejoined, reader], stop_driver)
  daemon.close(connected.control)
}

fn assert_shared_turns(
  drivers: List(actor.Started(process.Subject(tui_driver.Message))),
  turns: List(#(String, String)),
  answers: List(String),
) -> Nil {
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
  let assert [first, second, observer] = samples
    as "the two operators and observer each completed their own credited capture"
  assert first.model.records == second.model.records
  assert first.model.records == observer.model.records
  assert !writable(observer)
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
