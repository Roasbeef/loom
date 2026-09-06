//// The shipped TUI control client against real root/SQLite and controlled peers.
//// Controlled peers delay replies, not clocks: their socket receipts establish
//// that a mutation was transmitted before its deadline or connection is lost.

import client/daemon/manager
import client/daemon/protocol as server_protocol
import client/daemon_server_test
import core/clock
import core/ids
import core/json
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import mist
import simplifile
import storage/domain
import tui/daemon
import tui/daemon/protocol
import weft/poll

fn address(port) {
  "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
}

pub fn tui_daemon_real_control_create_default_stop_lazy_open_test() {
  daemon_server_test.fixture(fn(_, ready, port, credential) {
    let assert Ok(control) =
      daemon.connect(address(port), credential, process.self(), 2000)
      as "TUI keeps the authenticated control socket after hello"
    assert daemon.hello(control).epoch == protocol.Epoch(ready.epoch)
    assert daemon.hello(control).principal == ready.owner.id
    let assert Ok(protocol.StatusReply(summary)) =
      daemon.request(control, protocol.Status, 1000)
      as "real control status is decoded"
    assert summary.occupied == 0
    assert summary.domain_capacity > 0
    assert summary.domain_occupied == 0
    assert summary.domain_blocked == 0
    let assert Ok(protocol.SessionsReply(protocol.Page(_, [], None))) =
      daemon.request(control, protocol.ListSessions("", None), 1000)
      as "empty restored catalogue does not open a session"
    assert simplifile.write(ready.state_root <> "/tui-config.toml", "")
      == Ok(Nil)
    let creation =
      protocol.CreateSession(
        "tui-create",
        ready.state_root,
        "Terminal session",
        ready.state_root <> "/tui-config.toml",
      )
    let assert Ok(protocol.SessionReply(created)) =
      daemon.request(control, creation, 1000)
      as "only explicit creation initializes the session"
    let assert Ok(protocol.SessionReply(retried)) =
      daemon.request(control, creation, 1000)
      as "explicit retry uses the same durable creation key"
    assert retried.session_id == created.session_id
    let id = created.session_id
    let incarnation = resident(ready.registry, id)
    let epoch = daemon.hello(control).epoch
    let assert Ok(protocol.SessionReply(operation)) =
      daemon.request(
        control,
        protocol.GetOperation(id, incarnation, epoch),
        1000,
      )
      as "the opening operation resolves only in its original epoch"
    assert operation.status == protocol.Resident(incarnation)
    let assert Ok(protocol.SessionReply(_)) =
      daemon.request(control, protocol.SetDefault(ready.state_root, id), 1000)
      as "default mutation succeeds without another runtime"
    let assert Ok(protocol.LifecycleReply(_)) =
      daemon.request(control, protocol.StopSession(id), 1000)
      as "stop is explicit and acknowledged"
    saved(ready.registry, id)
    let assert Ok(protocol.SessionReply(selected)) =
      daemon.request(control, protocol.WorkspaceDefault(ready.state_root), 1000)
      as "workspace lookup reads saved metadata"
    assert selected.status == protocol.Saved
    let assert Ok(protocol.SessionsReply(page)) =
      daemon.request(control, protocol.ListSessions("", None), 1000)
      as "one bounded page exposes saved metadata"
    assert list.map(page.sessions, fn(item) { item.session_id }) == [id]
    assert page.after == Some(id)
    let assert Ok(protocol.SessionsReply(last)) =
      daemon.request(
        control,
        protocol.ListSessions(id, Some(page.revision)),
        1000,
      )
      as "continuation uses the same catalogue revision"
    assert last.sessions == []
    assert last.after == None
    let assert Ok(manager.Summary(occupied: 0, ..)) =
      manager.summary(ready.registry)
      as "listing and defaults did not reopen the session"
    let assert Ok(protocol.LifecycleReply(_)) =
      daemon.request(control, protocol.OpenSession(id), 1000)
      as "the user explicitly reopens the saved session"
    let replacement = resident(ready.registry, id)
    assert replacement != incarnation
    assert daemon.request(
        control,
        protocol.GetOperation(id, incarnation, epoch),
        1000,
      )
      == Error(daemon.Refused("stale_operation", "request refused"))
    close_and_join(control)
    let assert Ok(manager.View(status: manager.Resident(_), ..)) =
      manager.get(ready.registry, id)
      as "closing control does not stop the session"
    Nil
  })
}

fn resident(registry, id) {
  let assert poll.Answered(incarnation) =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status: manager.Resident(incarnation), ..)) ->
          poll.Done(incarnation)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "accepted open reaches resident within its budget"
  incarnation
}

fn saved(registry, id) {
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "stop finishes without erasing metadata"
  Nil
}

fn close_and_join(control) {
  let watch = process.monitor(daemon.owner(control))
  daemon.close(control)
  let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(1000)
    as "control owner actually retires normally"
  Nil
}

pub fn tui_daemon_rejects_bad_credentials_and_distinguishes_epochs_test() {
  daemon_server_test.fixture(fn(_, first, port, credential) {
    assert daemon.connect(address(port), "wrong", process.self(), 1000)
      == Error(daemon.HandshakeFailed)
    let assert Ok(control) =
      daemon.connect(address(port), credential, process.self(), 2000)
      as "valid credential establishes a control connection"
    daemon_server_test.fixture(fn(_, second, second_port, second_credential) {
      let assert Ok(other) =
        daemon.connect(
          address(second_port),
          second_credential,
          process.self(),
          2000,
        )
        as "a distinct daemon establishes its own epoch"
      assert first.epoch != second.epoch
      assert daemon.hello(control).epoch != daemon.hello(other).epoch
      assert daemon.request(
          other,
          protocol.GetOperation(
            "unused",
            "operation",
            daemon.hello(control).epoch,
          ),
          1000,
        )
        == Error(daemon.Invalid("stale epoch"))
      close_and_join(other)
    })
    close_and_join(control)
  })
}

pub fn tui_daemon_encoders_agree_with_server_decoder_test() {
  let #(id, _) = ids.mint_session(ids.generator(clock.fixed(0), 1))
  let id = ids.session_id_to_string(id)
  let epoch = protocol.Epoch("epoch")
  let cases = [
    #(protocol.Status, server_protocol.Status),
    #(protocol.ListSessions("", None), server_protocol.ListSessions("", None)),
    #(protocol.GetSession(id), server_protocol.GetSession(id)),
    #(
      protocol.WorkspaceDefault("/work"),
      server_protocol.WorkspaceDefault("/work"),
    ),
    #(protocol.SetDefault("/work", id), server_protocol.SetDefault("/work", id)),
    #(
      protocol.CreateSession("key", "/work", "é \\\"", "/config"),
      server_protocol.CreateSession(
        "key",
        "/work",
        "é \\\"",
        "/config",
        domain.WorkspacePrivate,
      ),
    ),
    #(protocol.OpenSession(id), server_protocol.OpenSession(id, "epoch")),
    #(protocol.StopSession(id), server_protocol.StopSession(id, "epoch")),
    #(
      protocol.GetOperation(id, "op", epoch),
      server_protocol.GetOperation(id, "op", "epoch"),
    ),
    #(protocol.Shutdown, server_protocol.Shutdown("epoch")),
  ]
  list.each(
    list.index_map(cases, fn(pair, index) { #(pair, index + 1) }),
    fn(item) {
      let #(#(command, expected), id) = item
      let assert Ok(text) = protocol.encode(id, command, epoch)
        as "valid request is serializable"
      assert server_protocol.decode(text)
        == Ok(server_protocol.Request(id, expected))
    },
  )
}

type PeerCommand {
  Send(String)
  Disconnect
}

const greeting = "{\"v\":2,\"event\":\"hello\",\"body\":{\"protocol\":2,\"epoch\":\"controlled\",\"principal\":\"owner\",\"limits\":{\"control_bytes\":65536}}}"

fn controlled_peer(run) {
  peer_listener(Some(greeting), fn(port, peers, incoming, _) {
    let assert Ok(control) =
      daemon.connect(address(port), "test-token", process.self(), 2000)
      as "controlled hello is accepted"
    let assert Ok(peer) = process.receive(peers, 1000)
      as "test can release replies through the actual socket owner"
    run(control, peer, incoming)
    daemon.close(control)
  })
}

fn peer_listener(initial, run) {
  let ports = process.new_subject()
  let peers = process.new_subject()
  let incoming = process.new_subject()
  let closed = process.new_subject()
  let assert Ok(listener) =
    mist.new(fn(request) {
      mist.websocket_with_options(
        request:,
        options: mist.WebsocketOptions(65_536, 65_536, mist.CompressionDisabled),
        on_init: fn(_) {
          let commands = process.new_subject()
          process.send(peers, commands)
          case initial {
            Some(text) -> process.send(commands, Send(text))
            None -> Nil
          }
          #(Nil, Some(process.new_selector() |> process.select(commands)))
        },
        on_close: fn(_) { process.send(closed, Nil) },
        handler: fn(_, event, socket) {
          case event {
            mist.Text(text) -> {
              process.send(incoming, text)
              mist.continue(Nil)
            }
            mist.Custom(Send(text)) -> {
              let assert Ok(Nil) = mist.send_text_frame(socket, text)
                as "controlled peer sends its scheduled frame"
              mist.continue(Nil)
            }
            mist.Custom(Disconnect)
            | mist.Closed
            | mist.Shutdown
            | mist.Binary(_) -> mist.stop()
          }
        },
      )
    })
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
    as "controlled listener starts"
  process.unlink(listener.pid)
  let assert Ok(port) = process.receive(ports, 1000)
    as "controlled port is published"
  run(port, peers, incoming, closed)
  process.kill(listener.pid)
}

fn received(incoming) {
  let assert Ok(text) = process.receive(incoming, 1000)
    as "socket observed exactly one request"
  let assert Ok(request) = server_protocol.decode(text)
    as "TUI sent a valid request"
  request
}

fn reply(id, event, body) {
  let assert Ok(text) = server_protocol.event(Some(id), event, body)
    as "controlled response is within wire limits"
  text
}

pub fn tui_daemon_timeout_never_resends_or_matches_a_late_reply_test() {
  controlled_peer(fn(control, peer, incoming) {
    let outcomes = process.new_subject()
    let watch = process.monitor(daemon.owner(control))
    let assert Ok(peer_pid) = process.subject_owner(peer)
      as "peer socket owner exists before timeout"
    let peer_watch = process.monitor(peer_pid)
    let _worker =
      process.spawn(fn() {
        process.send(outcomes, daemon.request(control, protocol.Shutdown, 100))
      })
    let first = received(incoming)
    assert first.command == server_protocol.Shutdown("controlled")
    assert daemon.request(control, protocol.Status, 1000) == Error(daemon.Busy)
    assert process.receive(outcomes, 1000)
      == Ok(Error(daemon.UnknownOutcome("daemon.shutdown")))
    let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
      process.new_selector()
      |> process.select_specific_monitor(watch, fn(down) { down })
      |> process.selector_receive(1000)
      as "deadline retires the control owner"
    let assert Ok(_) =
      process.new_selector()
      |> process.select_specific_monitor(peer_watch, fn(down) { down })
      |> process.selector_receive(1000)
      as "peer observes actual socket retirement"
    list.each([1, 2, 3], fn(_) {
      assert daemon.request(control, protocol.Status, 1000)
        == Error(daemon.Disconnected)
    })
    assert process.receive(incoming, 0) == Error(Nil)

    // Even reused request IDs belong to a new socket and new control inbox.
    controlled_peer(fn(replacement, replacement_peer, replacement_incoming) {
      let _worker =
        process.spawn(fn() {
          process.send(
            outcomes,
            daemon.request(
              replacement,
              protocol.WorkspaceDefault("/work"),
              1000,
            ),
          )
        })
      let second = received(replacement_incoming)
      assert second.id == first.id
      process.send(
        peer,
        Send(reply(
          first.id,
          "daemon.shutdown",
          json.Object([#("state", json.String("draining"))]),
        )),
      )
      process.send(
        replacement_peer,
        Send(reply(
          second.id,
          "error",
          json.Object([
            #("code", json.String("not_found")),
            #("message", json.String("request refused")),
          ]),
        )),
      )
      assert process.receive(outcomes, 1000)
        == Ok(Error(daemon.Refused("not_found", "request refused")))
      assert process.receive(replacement_incoming, 0) == Error(Nil)
    })
  })
}

pub fn tui_daemon_disconnect_leaves_mutation_outcome_unknown_test() {
  controlled_peer(fn(control, peer, incoming) {
    let outcomes = process.new_subject()
    let _worker =
      process.spawn(fn() {
        process.send(
          outcomes,
          daemon.request(
            control,
            protocol.CreateSession("durable-key", "/work", "Name", "/config"),
            1000,
          ),
        )
      })
    let _first = received(incoming)
    process.send(peer, Disconnect)
    assert process.receive(outcomes, 1000)
      == Ok(Error(daemon.UnknownOutcome("sessions.create")))
    assert process.receive(incoming, 0) == Error(Nil)
  })
}

pub fn tui_daemon_read_deadline_is_not_a_mutation_outcome_test() {
  controlled_peer(fn(control, _, incoming) {
    assert daemon.request(control, protocol.Status, 40)
      == Error(daemon.TimedOut)
    assert received(incoming).command == server_protocol.Status
    assert process.receive(incoming, 0) == Error(Nil)
  })
}

pub fn tui_daemon_missing_hello_closes_the_socket_on_deadline_test() {
  peer_listener(None, fn(port, _, _, closed) {
    assert daemon.connect(address(port), "token", process.self(), 100)
      == Error(daemon.HandshakeFailed)
    assert process.receive(closed, 1000) == Ok(Nil)
  })
}

pub fn tui_daemon_terminal_normal_exit_reaps_control_after_starter_exit_test() {
  peer_listener(Some(greeting), fn(port, _, _, closed) {
    let terminal_ready = process.new_subject()
    let terminal =
      process.spawn(fn() {
        let stop = process.new_subject()
        process.send(terminal_ready, stop)
        let assert Ok(Nil) = process.receive(stop, 2000)
          as "terminal exits only on test command"
        Nil
      })
    let assert Ok(stop) = process.receive(terminal_ready, 1000)
      as "terminal owns a lifetime inbox"
    let connections = process.new_subject()
    let starter =
      process.spawn(fn() {
        process.send(
          connections,
          daemon.connect(address(port), "token", terminal, 1000),
        )
      })
    let starter_watch = process.monitor(starter)
    let assert Ok(Ok(control)) = process.receive(connections, 1000)
      as "short-lived bootstrap returns authenticated control"
    let assert Ok(_) =
      process.new_selector()
      |> process.select_specific_monitor(starter_watch, fn(down) { down })
      |> process.selector_receive(1000)
      as "bootstrap worker has exited"
    assert process.is_alive(daemon.owner(control))
    let watch = process.monitor(daemon.owner(control))
    process.send(stop, Nil)
    let assert Ok(process.ProcessDown(reason: process.Normal, ..)) =
      process.new_selector()
      |> process.select_specific_monitor(watch, fn(down) { down })
      |> process.selector_receive(1000)
      as "normal terminal exit retires control owner"
    assert process.receive(closed, 1000) == Ok(Nil)
  })
}

pub fn tui_daemon_refuses_cleartext_remote_credentials_before_connect_test() {
  assert daemon.connect(
      "ws://example.com/v2/control",
      "secret",
      process.self(),
      100,
    )
    == Error(daemon.Invalid("remote control requires TLS"))
  assert daemon.connect(
      "ws://127.0.0.1/v2/control?token=secret",
      "secret",
      process.self(),
      100,
    )
    == Error(daemon.Invalid("expected an unqualified /v2/control endpoint"))
}

pub fn tui_daemon_correlated_shutdown_ack_is_a_known_outcome_test() {
  controlled_peer(fn(control, peer, incoming) {
    let outcomes = process.new_subject()
    let _worker =
      process.spawn(fn() {
        process.send(outcomes, daemon.request(control, protocol.Shutdown, 1000))
      })
    let request = received(incoming)
    process.send(
      peer,
      Send(reply(
        request.id,
        "daemon.shutdown",
        json.Object([#("state", json.String("draining"))]),
      )),
    )
    assert process.receive(outcomes, 1000) == Ok(Ok(protocol.ShutdownReply))
  })
}

pub fn tui_daemon_changed_status_epoch_cannot_replace_hello_test() {
  controlled_peer(fn(control, peer, incoming) {
    let outcomes = process.new_subject()
    let _worker =
      process.spawn(fn() {
        process.send(outcomes, daemon.request(control, protocol.Status, 1000))
      })
    let request = received(incoming)
    let body =
      json.Object([
        #("epoch", json.String("replacement")),
        #("ready", json.Bool(True)),
        #("capacity", json.Int(1)),
        #("occupied", json.Int(0)),
        #("opening", json.Int(0)),
        #("resident", json.Int(0)),
        #("stopping", json.Int(0)),
        #("blocked", json.Int(0)),
        #("domain_capacity", json.Int(1)),
        #("domain_occupied", json.Int(0)),
        #("domain_blocked", json.Int(0)),
      ])
    process.send(peer, Send(reply(request.id, "status", body)))
    assert process.receive(outcomes, 1000) == Ok(Error(daemon.Disconnected))
    assert daemon.hello(control).epoch == protocol.Epoch("controlled")
  })
}
