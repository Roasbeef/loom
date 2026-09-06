//// Native terminal drivers share a real owned daemon and SQLite sessions.
//// The provider transport is deterministic; catalogue, assembly, helper
//// ownership, WebSocket credit, terminal reducers and restart are real. This
//// fixture does not claim to exercise an external provider's network service.

import broker/policy
import client/catalog
import client/daemon/main as daemon_main
import client/daemon/manager
import client/daemon/root
import client/daemon/session_socket
import client/owned_assembly_test
import client/serve
import core/clock
import core/entry
import core/ids
import core/message
import etui/backend
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import provider/http
import provider/secret
import simplifile
import storage/domain
import storage/sqlite
import support/provider as provider_test
import support/tui_driver
import telemetry/log
import tui
import tui/attachment
import tui/session_channel
import weft/poll

type Arrival =
  #(String, process.Subject(Nil))

fn settings() {
  let settings = owned_assembly_test.settings()
  let assert Ok(here) = simplifile.current_directory()
    as "the real helper is relative to the client package"
  let gateway =
    catalog.gateway(
      settings.catalog,
      transport: provider_test.transport(fn(_, events) {
        process.send(
          events,
          http.ResponseStatus(200, [#("content-type", "text/event-stream")]),
        )
        process.send(
          events,
          http.ResponseChunk(bit_array.from_string(
            "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"daemon\",\"model\":\"test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
            <> "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
            <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"persisted assistant result\"}}\n\n"
            <> "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
            <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
          )),
        )
        process.send(events, http.ResponseEnd)
      }),
      secrets: secret.from_list([#("UNUSED", "fixture-key")]),
      clock: clock.fixed(0),
    )
  serve.Settings(
    ..settings,
    gateway:,
    helper_path: here <> "/../../bin/loom-exec",
  )
}

fn start(settings: serve.Settings, arrivals: process.Subject(Arrival)) {
  let directory = filepath.directory_name(settings.session_path)
  let assert Ok(config) =
    daemon_main.parse(["--state-dir", directory <> "/daemon"])
    as "the daemon state is separate from both workspaces"
  let assert Ok(daemon) =
    root.start(
      root.Config(config.state_root, "Owner", 4),
      manager.Assembly(
        fn(selected_domain, sources, owner) {
          serve.build_domain(selected_domain, sources, log.discard(), owner)
        },
        fn(record, selected_domain, services, owner) {
          let release = process.new_subject()
          process.send(arrivals, #(record.id, release))
          let assert Ok(Nil) = process.receive(release, 10_000)
            as "the test releases explicit assembly within its deadline"
          let assert Ok(id) = ids.parse_session_id(record.id)
            as "the durable catalogue reserves canonical identities"
          let domain = filepath.directory_name(selected_domain.memory_path)
          assert bootstrap.ensure_private_directory(
              config.state_root <> "/workspaces",
            )
            == Ok(Nil)
          assert bootstrap.ensure_private_directory(domain) == Ok(Nil)
          let base = serve.base_policy(record.workspace)
          serve.assemble_in_domain(
            serve.Settings(
              ..settings,
              session_path: record.path,
              session_id: record.id,
              workspace: record.workspace,
              base_policy: policy.SandboxPolicy(..base, protected: [
                config.state_root,
                ..base.protected
              ]),
              domain_paths: Some(serve.DomainPaths(
                selected_domain.memory_path,
                selected_domain.index_path,
              )),
            ),
            id,
            log.discard(),
            owner,
            services,
          )
        },
        serve.instance_children,
      ),
    )
    as "one root owns all native and storage lifetimes"
  let assert Ok(serving) =
    daemon_main.listen(config, daemon, fn(request, attachment) {
      session_socket.upgrade(
        daemon,
        request,
        attachment,
        attachment.instance.gateway,
      )
    })
    as "the production listener routes each selected owned gateway"
  serving
}

fn create(serving: daemon_main.Serving(serve.Instance), workspace, seed) {
  assert bootstrap.ensure_private_directory(workspace) == Ok(Nil)
  let configuration = serving.ready.state_root <> "/fixture-domain.toml"

  // Shared history is real, but maintenance must not acquire credentials from
  // the developer's environment or consume this fixture's scripted turns.
  let assert Ok(Nil) =
    simplifile.write(
      configuration,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"UNUSED\"\nmodel_id = \"fixture\"\ncontext_window = 1000\nmax_output_tokens = 100\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    as "the persisted domain explicitly disables external maintenance"
  let assert Ok(view) =
    manager.create_scoped(
      serving.ready.registry,
      manager.Creation(
        "key-" <> int.to_string(seed),
        workspace,
        "session " <> int.to_string(seed),
        "",
      ),
      directory: serving.ready.sessions_directory,
      generator: ids.generator(clock.fixed(1000), seed),
      scope: domain.WorkspacePrivate,
      configuration:,
    )
    as "setup reserves a session, but its builder remains explicitly held"
  view.registration
}

fn release(arrivals, id) {
  let assert Ok(#(found, release)) = process.receive(arrivals, 5000)
    as "explicit creation or open reaches the actual assembly boundary"
  assert found == id
  process.send(release, Nil)
}

fn resident(serving: daemon_main.Serving(serve.Instance), id) {
  let assert poll.Answered(Nil) =
    poll.until(within: 15_000, every: 5, attempt: fn() {
      case manager.get(serving.ready.registry, id) {
        Ok(manager.View(status: manager.Resident(_), ..)) -> poll.Done(Nil)
        Ok(manager.View(status: manager.RecoveryBlocked(_), ..)) ->
          poll.Fail("assembly blocked")
        _ -> poll.Retry
      }
    })
    as "the original assembly becomes resident within its deadline"
}

fn await(driver, predicate) {
  let result =
    poll.fold_until(
      clock: poll.monotonic(),
      within: 8000,
      every: poll.Fixed(10),
      from: "no sample",
      attempt: fn(_) {
        let sample = tui_driver.play(driver, [])
        case predicate(sample) {
          True -> poll.Settled(sample)
          False -> poll.Pending(sample.model.notice <> "\n" <> sample.frame)
        }
      },
    )
  case result {
    poll.Answer(sample) -> sample
    poll.RanOut(reason) | poll.Failure(reason) -> {
      io.println_error(reason)
      panic as reason
    }
  }
}

fn attached(sample: tui_driver.Sample, id) {
  case sample.model.peer, sample.model.captured {
    tui.Attached(_), Some(#(cut, _)) -> cut.attachment.expected.session == id
    _, _ -> False
  }
}

fn user_turns(sample: tui_driver.Sample) {
  list.filter_map(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(message: message.UserMessage(content:, ..), ..) ->
        Ok(
          list.filter_map(content, fn(block) {
            case block {
              message.UserText(text, _) -> Ok(text)
              message.UserImage(..) -> Error(Nil)
            }
          })
          |> string.join("\n"),
        )
      _ -> Error(Nil)
    }
  })
}

fn settled(sample: tui_driver.Sample) {
  list.any(sample.model.records, fn(record) {
    case record.entry {
      entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) ->
        list.contains(
          content,
          message.AssistantText("persisted assistant result", None),
        )
      _ -> False
    }
  })
  && list.all(sample.model.strands, fn(strand) { strand.live_phase == None })
}

fn writable(sample: tui_driver.Sample) {
  case sample.model.channel {
    Some(channel) -> session_channel.mutation_available(channel)
    None -> False
  }
}

fn connect(serving: daemon_main.Serving(serve.Instance), selected) {
  let assert Ok(token) = root.listener_credential(serving.daemon)
    as "all terminal attachments use the same private daemon owner credential"
  let address =
    "ws://127.0.0.1:" <> int.to_string(serving.listener.port) <> "/v2/control"
  let assert Ok(driver) = tui_driver.start(address, token, selected)
    as "a real terminal owns its control and provisional conversation inboxes"
  driver.data
}

fn stop(serving: daemon_main.Serving(serve.Instance)) {
  assert root.shutdown(serving.daemon, within: 30_000) == Ok(Nil)
    as "the original root proves listener, runtime, native helper and SQLite retirement"
}

pub fn tui_v2_persisted_restart_lists_without_open_then_switches_two_workspaces_test() {
  let settings = settings()
  let arrivals = process.new_subject()
  let first = start(settings, arrivals)
  let directory = filepath.directory_name(settings.session_path)
  let a = create(first, directory <> "/workspace-a", 1)
  release(arrivals, a.id)
  resident(first, a.id)
  let b = create(first, directory <> "/workspace-b", 2)
  release(arrivals, b.id)
  resident(first, b.id)
  let alice = connect(first, a.id)
  let bob = connect(first, a.id)
  let _ = await(alice, fn(sample) { attached(sample, a.id) })
  let _ = await(bob, fn(sample) { attached(sample, a.id) })
  let _ = await(alice, writable)
  let _ =
    tui_driver.play(alice, [
      backend.Paste("A-only durable turn"),
      backend.KeyPress("enter"),
    ])
  let alice_cut = await(alice, settled)
  let bob_cut = await(bob, settled)
  assert alice_cut.model.records == bob_cut.model.records
  assert list.contains(user_turns(bob_cut), "A-only durable turn")
  tui_driver.stop(alice)
  let _ = await(bob, writable)
  let _ =
    tui_driver.play(bob, [
      backend.Paste("A survives peer close"),
      backend.KeyPress("enter"),
    ])
  let _ =
    await(bob, fn(sample) {
      list.contains(user_turns(sample), "A survives peer close")
    })
  tui_driver.stop(bob)
  stop(first)
  let assert Ok(#(Some(identity), _)) = sqlite.identity(a.path)
    as "session identity remains durable after confirmed shutdown"
  assert identity == a.id

  let restored = start(settings, arrivals)
  assert restored.ready.epoch != first.ready.epoch
  assert process.receive(arrivals, 0) == Error(Nil)
  list.each([a.id, b.id], fn(id) {
    let assert Ok(manager.View(status: manager.Saved, ..)) =
      manager.get(restored.ready.registry, id)
      as "restart restores only catalogue rows, not runtimes"
  })
  let terminal = connect(restored, "")
  let listing =
    await(terminal, fn(sample) {
      case sample.model.overlay {
        tui.DaemonSelector(_) -> True
        _ -> False
      }
    })
  assert !attachment.busy(listing.model.candidate)
  assert listing.model.captured == None
  assert process.receive(arrivals, 0) == Error(Nil)
  let assert tui.DaemonSelector(selector) = listing.model.overlay
    as "listing is a server-backed metadata page"
  let assert Ok(selected) =
    list.first(list.drop(selector.page.sessions, selector.selected))
    as "a catalogue row is highlighted but not opened"
  let _ = tui_driver.play(terminal, [backend.KeyPress("enter")])
  release(arrivals, selected.session_id)
  let opened =
    await(terminal, fn(sample) { attached(sample, selected.session_id) })
  assert opened.model.workspace.path == selected.workspace
  let other = case selected.session_id == a.id {
    True -> b
    False -> a
  }
  let _ =
    tui_driver.play(terminal, [
      backend.Paste("/sessions"),
      backend.KeyPress("enter"),
    ])
  let _ =
    await(terminal, fn(sample) {
      case sample.model.overlay {
        tui.DaemonSelector(_) -> True
        _ -> False
      }
    })
  let _ =
    tui_driver.play(terminal, [
      backend.KeyPress("down"),
      backend.KeyPress("enter"),
    ])
  let assert Ok(#(switch_id, permit)) = process.receive(arrivals, 5000)
    as "selecting the other saved row starts its own incarnation"
  assert switch_id == other.id
  let pending = tui_driver.play(terminal, [])
  assert pending.model.session == selected.session_id
  assert pending.model.records == opened.model.records
  process.send(permit, Nil)
  let replaced = await(terminal, fn(sample) { attached(sample, other.id) })
  assert replaced.model.workspace.path == other.workspace
  case other.id == b.id {
    True -> {
      assert user_turns(replaced) == []
    }
    False -> {
      assert list.contains(user_turns(replaced), "A-only durable turn")
    }
  }
  tui_driver.stop(terminal)
  stop(restored)
}
