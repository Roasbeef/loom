//// A real scoped approval releases exactly one harmless native execution.
//// The provider is scripted, but the daemon, SQLite writer, broker refusal,
//// helper, authenticated sockets and observer terminal are real. The marker
//// lives only in this fixture's fresh workspace. This tests consent ordering,
//// not filesystem confinement or the separate PrivateScratch policy work.
//// Two raw operator sockets preserve identical captured requests through the
//// race; the existing multiplayer fixture separately tests operator keyboards.

import broker/policy
import client/catalog
import client/daemon/admin
import client/daemon/main as daemon_main
import client/daemon/manager
import client/daemon/root
import client/daemon/session_socket
import client/daemon_server_test as wire
import client/owned_assembly_test
import client/serve
import client/session_socket_test
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/tui_v2_test
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
import gleam/list
import gleam/option.{Some}
import gleam/string
import host/bootstrap
import provider/http
import provider/secret
import runtime/api
import runtime/escalation
import simplifile
import storage/domain
import storage/storage
import support/internal/ffi_ws
import support/provider as provider_test
import support/tui_driver
import telemetry/log
import tui/approval
import weft
import weft/poll

const marker = "APPROVED-ONCE\n"

const call_id = "approval-native-call"

// Neither the command nor its destination comes from an external provider.
// Append makes a duplicate native execution visible instead of overwriting it.
const shell_command = "printf 'APPROVED-ONCE\\n' >> approval-count.txt; printf 'APPROVED-ONCE\\n'"

fn field(value, key) {
  let assert json.Object(fields) = value as "wire value is an object"
  let assert Ok(found) = list.key_find(fields, key)
    as "the expected protocol field is present"
  found
}

fn sse(kind, value) {
  "event: " <> kind <> "\ndata: " <> json.to_string(value) <> "\n\n"
}

fn scripted_provider(request: http.HttpRequest, events) {
  process.send(
    events,
    http.ResponseStatus(200, [
      #("content-type", "text/event-stream"),
    ]),
  )
  let start =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"approval\",\"model\":\"test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
  let #(content, reason) = case
    string.contains(request.body, "\"tool_result\"")
  {
    True -> #(
      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"native execution settled\"}}\n\n",
      "end_turn",
    )
    False -> #(
      sse(
        "content_block_start",
        json.Object([
          #("type", json.String("content_block_start")),
          #("index", json.Int(0)),
          #(
            "content_block",
            json.Object([
              #("type", json.String("tool_use")),
              #("id", json.String(call_id)),
              #("name", json.String("bash")),
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
              #(
                "partial_json",
                json.String(
                  json.to_string(
                    json.Object([
                      #("command", json.String(shell_command)),
                      #("timeout_ms", json.Int(30_000)),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
        ]),
      ),
      "tool_use",
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

fn start() {
  let settings = owned_assembly_test.settings()
  let directory = filepath.directory_name(settings.session_path)
  let assert Ok(here) = simplifile.current_directory()
    as "the real helper is relative to the client package"
  let gateway =
    catalog.gateway(
      settings.catalog,
      transport: provider_test.transport(scripted_provider),
      secrets: secret.from_list([#("UNUSED", "fixture-only")]),
      clock: clock.fixed(0),
    )
  let assert Ok(config) =
    daemon_main.parse(["--state-dir", directory <> "/daemon"])
    as "the daemon owns a fresh private root"
  let assert Ok(daemon) =
    root.start(
      root.Config(config.state_root, "Owner", 2),
      manager.Assembly(
        fn(selected, sources, owner) {
          serve.build_domain(selected, sources, log.discard(), owner)
        },
        fn(record, selected, services, owner) {
          let assert Ok(id) = ids.parse_session_id(record.id)
            as "the catalogue reserves a canonical session identity"
          assert bootstrap.ensure_private_directory(filepath.directory_name(
              selected.memory_path,
            ))
            == Ok(Nil)
          let base = serve.base_policy(record.workspace)
          serve.assemble_in_domain(
            serve.Settings(
              ..settings,
              gateway:,
              helper_path: here <> "/../../bin/loom-exec",
              session_path: record.path,
              session_id: record.id,
              workspace: record.workspace,
              base_policy: policy.SandboxPolicy(
                ..base,
                limits: policy.Limits(..base.limits, wall_s: 1),
              ),
              domain_paths: Some(serve.DomainPaths(
                selected.memory_path,
                selected.index_path,
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
    as "the original root owns all effect cleanup"
  let assert Ok(serving) =
    daemon_main.listen(config, daemon, fn(request, attachment) {
      session_socket.upgrade(
        daemon,
        request,
        attachment,
        attachment.instance.gateway,
      )
    })
    as "the production v2 listener starts"
  #(serving, directory)
}

fn create(serving: daemon_main.Serving(serve.Instance), directory) {
  let workspace = directory <> "/workspace"
  assert bootstrap.ensure_private_directory(workspace) == Ok(Nil)
  let configuration = serving.ready.state_root <> "/maintenance-off.toml"
  assert simplifile.write(
      configuration,
      "[models.fixture]\ndialect = \"anthropic\"\napi_key_env = \"UNUSED\"\nmodel_id = \"fixture\"\ncontext_window = 1000\nmax_output_tokens = 100\n[roles]\nmain = [\"fixture\"]\n[memory]\ndistill = \"off\"\n",
    )
    == Ok(Nil)
  let assert Ok(created) =
    manager.create_scoped(
      serving.ready.registry,
      manager.Creation("approval-effect", workspace, "Approval effect", ""),
      directory: serving.ready.sessions_directory,
      generator: ids.generator(clock.fixed(1), 51),
      scope: domain.SessionOnly,
      configuration:,
    )
    as "collaboration explicitly selects an isolated session domain"
  let assert poll.Answered(instance) =
    poll.until(within: 15_000, every: 5, attempt: fn() {
      case manager.resolve(serving.ready.registry, created.registration.id) {
        Ok(instance) -> poll.Done(instance)
        Error(_) -> poll.Retry
      }
    })
    as "the real owned assembly becomes resident"
  #(created.registration, instance)
}

fn invited(address, owner, epoch, session, principal, role) {
  let assert Ok(request) =
    admin.parse(["invite", session, principal, role, principal])
    as "the shipped admin parser accepts a member invitation"
  let assert Ok(response) = admin.exchange(address, owner, epoch, request)
    as "owner administration issues a credential exactly once"
  let assert json.String(bearer) = field(response, "bearer")
    as "only the explicit success returns the credential"
  bearer
}

fn socket(port, bearer, session) {
  let #(socket, response) =
    wire.connect(port, bearer, "/v2/sessions/" <> session <> "/ws")
  assert string.contains(response, "101 Switching Protocols")
  let #(_, transfer) = session_socket_test.begin(socket, session)
  let _ = session_socket_test.drain(socket, transfer, 0, [], 32)
  socket
}

fn tool_results(instance: serve.Instance) {
  let assert Ok(entries) =
    storage.scan_entries(
      instance.runtime.session.store,
      storage.entry_scan() |> storage.entry_limit(100),
    )
    as "the tiny fixture reads its actual durable entries"
  assert list.length(entries) < 100 as "the bounded fixture scan is complete"
  list.filter_map(entries, fn(item) {
    case item {
      entry.MessageEntry(
        message: message.ToolResultMessage(tool_call_id: id, ..) as result,
        ..,
      )
        if id == call_id
      -> Ok(result)
      _ -> Error(Nil)
    }
  })
}

fn exercise(
  serving: daemon_main.Serving(serve.Instance),
  directory: String,
) -> Result(Nil, Nil) {
  let #(registration, instance) = create(serving, directory)
  let assert Ok(owner) = root.listener_credential(serving.daemon)
    as "the owner credential stays inside fixture memory"
  let address =
    "ws://127.0.0.1:" <> int.to_string(serving.listener.port) <> "/v2/control"
  let alice =
    invited(
      address,
      owner,
      serving.ready.epoch,
      registration.id,
      "alice",
      "operator",
    )
  let bob =
    invited(
      address,
      owner,
      serving.ready.epoch,
      registration.id,
      "bob",
      "operator",
    )
  let observer =
    invited(
      address,
      owner,
      serving.ready.epoch,
      registration.id,
      "reader",
      "observer",
    )
  let a = socket(serving.listener.port, alice, registration.id)
  let b = socket(serving.listener.port, bob, registration.id)
  let reader = socket(serving.listener.port, observer, registration.id)
  let assert Ok(terminal) = tui_driver.start(address, observer, registration.id)
    as "a real observer terminal receives the actual pending request"
  let admitted =
    wire.reply(
      a,
      100,
      "prompt",
      json.Object([
        #("strand", json.String("main")),
        #("text", json.String("Run the fixed approval marker once.")),
      ]),
    )
  assert field(admitted, "event") == json.String("mutation_outcome")
  let pending_view =
    tui_v2_test.await(terminal.data, fn(sample) {
      list.any(sample.model.approvals, fn(record) {
        record.status == approval.Pending
      })
    })
  let assert [pending] = pending_view.model.approvals
    as "the actual bash refusal raises exactly one pending question"
  let assert Ok(cell) = api.escalation_cell(instance.runtime, pending.id)
    as "the question is a real durable broker escalation"
  let assert Some(scope) = cell.record.scope
    as "tool clearance binds the question to an execution, not an unscoped fixture"
  assert scope.call_id == call_id
  assert scope.strand == "main"
  assert cell.record.tool == Some("bash")
  assert cell.seq == pending.seq
  assert cell.record.status == escalation.Pending
  let marker_path = registration.workspace <> "/approval-count.txt"
  assert simplifile.is_file(marker_path) == Ok(False)
    as "the native side effect must not precede consent"
  assert tool_results(instance) == []
    as "no result may be committed before the real pending request is approved"

  let assert Ok(encoded) = approval.approve(101, pending)
    as "the real captured action, wanted grants and seq are echoed exactly"
  let assert Ok(envelope) = json.parse(encoded) as "approval is total JSON"
  let body = field(envelope, "body")
  let denied = wire.reply(reader, 101, "approve", body)
  assert field(denied, "event") == json.String("error")
  assert field(field(denied, "body"), "code") == json.String("forbidden")
  assert api.escalation_cell(instance.runtime, pending.id) == Ok(cell)
  assert simplifile.is_file(marker_path) == Ok(False)

  // Each socket has its own caller. Both requests retain the same captured
  // seq even if one wins before the other reaches the serialized gateway.
  let answers =
    weft.new([
      fn() { Ok(#("alice", wire.reply(a, 101, "approve", body))) },
      fn() { Ok(#("bob", wire.reply(b, 101, "approve", body))) },
    ])
    |> weft.deadline(5000)
    |> weft.start
    |> weft.values
  assert list.length(answers) == 2
    as "both competing wire requests receive a result"
  let assert [#(winner, _)] =
    list.filter(answers, fn(answer) {
      field(answer.1, "event") == json.String("mutation_outcome")
    })
    as "exactly one approval is admitted"
  let assert [#(_, loser)] =
    list.filter(answers, fn(answer) {
      field(answer.1, "event") == json.String("error")
    })
    as "the other captured approval loses rather than executing again"
  assert field(field(loser, "body"), "code") == json.String("stale_approval")
    as "the loser names a superseded captured approval sequence"
  let assert poll.Answered(results) =
    poll.until(within: 10_000, every: 10, attempt: fn() {
      case tool_results(instance) {
        [] -> poll.Retry
        results -> poll.Done(results)
      }
    })
    as "the authorized native execution commits its result"
  let assert [message.ToolResultMessage(is_error: False, ..)] = results
    as "one real successful tool result exists for the exact provider call"
  assert simplifile.read(marker_path) == Ok(marker)
    as "one append proves exactly one native execution, not merely one result"
  let assert Ok(consumed) = api.escalation_cell(instance.runtime, pending.id)
    as "the execution consumes the durable approval before running"
  assert consumed.record.status == escalation.Consumed
  assert consumed.seq > pending.seq
  let assert Some(author) = consumed.record.origin
    as "the winning human remains attributed after consumption"
  assert author.principal == winner
  assert consumed.record.scope == Some(scope)
  let _ =
    tui_driver.play(terminal.data, [
      backend.Paste("/approvals " <> pending.id),
      backend.KeyPress("enter"),
    ])
  let _resolved =
    tui_v2_test.await(terminal.data, fn(sample) {
      list.any(sample.model.approvals, fn(record) {
        record.id == pending.id && record.origin == Some(author)
      })
    })

  // Exact-action inspection is modal and covers the transcript summaries.
  // Close that panel before asking whether the winning author is painted.
  let _ = tui_driver.play(terminal.data, [backend.KeyPress("esc")])
  let observed =
    tui_v2_test.await(terminal.data, fn(sample) {
      string.contains(sample.frame, author.name)
    })
  assert string.contains(observed.frame, author.name)
    as "the observer renders the winning author, not just the decoded record"
  tui_driver.stop(terminal.data)
  list.each([a, b, reader], fn(socket) {
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
  Ok(Nil)
}

/// The enclosing task captures assertion failures so root cleanup still runs.
/// Normal root retirement is required before inspecting the captured outcome.
///
/// ## Examples
///
/// `scripts/test.sh client --match tui_approval_effect` runs this finite case.
pub fn tui_approval_effect_two_approvals_execute_once_test_() -> EunitTest {
  Timeout(9, fn() {
    let #(serving, directory) = start()
    let outcomes =
      weft.new([fn() { exercise(serving, directory) }])
      |> weft.deadline(45_000)
      |> weft.start
    assert root.shutdown(serving.daemon, within: 30_000) == Ok(Nil)
      as "the original root joins helpers, SQLite, domain and listener owners"
    assert weft.values(outcomes) == [Nil]
      as "the captured approval/effect drive completed without failure or timeout"
    assert simplifile.read(directory <> "/workspace/approval-count.txt")
      == Ok(marker)
      as "the marker remains single after all original native owners retire"
  })
}
