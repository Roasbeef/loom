//// A real scoped approval releases exactly one harmless native execution.
//// The provider is scripted, but the daemon, SQLite writer, broker refusal,
//// helper, authenticated sockets and observer terminal are real. The marker
//// lives only in this fixture's fresh workspace. This tests consent ordering,
//// not filesystem confinement or the separate PrivateScratch policy work.
//// Two raw operator sockets preserve identical captured requests through the
//// race; the existing multiplayer fixture separately tests operator keyboards.

import broker/policy
import client/catalog
import client/config_reload
import client/daemon/admin
import client/daemon/limits
import client/daemon/main as daemon_main
import client/daemon/manager
import client/daemon/root
import client/daemon/session_socket
import client/daemon/ui_relay
import client/daemon_server_test as wire
import client/gateway
import client/owned_assembly_test
import client/serve
import client/session_socket_test
import client/tui_e2e_test.{type EunitTest, Timeout}
import client/tui_v2_test
import client/web_operator_page_test
import client/wiring as client_wiring
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/origin
import etui/backend
import filepath
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result as gleam_result
import gleam/string
import host/bootstrap
import host/claim
import lustre
import machine/strand as machine_strand
import provider/http
import provider/secret
import runtime/api
import runtime/escalation
import session_view/approval
import simplifile
import storage/access
import storage/domain
import storage/storage
import support/internal/ffi_ws
import support/provider as provider_test
import support/provider_http
import support/tui_driver
import telemetry/log
import tools/blob
import tui/approval_panel
import tui/model as tui_model
import web_view/component
import web_view/operator_page
import weft
import weft/poll

// Every wait in this fixture already ends on an event the drive produces:
// a socket reply, a rendered frame, a committed tool result. The number
// below is only the failsafe on those waits, so it has to be past any
// round trip this fixture can perform, not just past the ones an idle
// machine performs. One second was the second kind. With seven other tests
// running alongside it, a reply arrived later than that and the drive
// reported neither a completion nor a timeout.
const reply_wait_ms = 20_000

const marker = "APPROVED-ONCE\n"

const call_id = "approval-native-call"

// Neither the command nor its destination comes from an external provider.
// Append makes a duplicate native execution visible instead of overwriting it.
const shell_command =
  "printf 'APPROVED-ONCE\\n' >> approval-count.txt; printf 'APPROVED-ONCE\\n'"

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
  scripted_call(
    request,
    events,
    "bash",
    json.Object([
      #("command", json.String(shell_command)),
      #("timeout_ms", json.Int(30_000)),
    ]),
    call_id,
  )
}

fn scripted_call(
  request: http.HttpRequest,
  events,
  tool_name: String,
  arguments: json.JsonValue,
  identity: String,
) {
  process.send(
    events,
    http.ResponseStatus(200, [
      #("content-type", "text/event-stream"),
    ]),
  )
  let start =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"approval\",\"model\":\"test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n"
  let #(content, reason) = case latest_is_result(request.body) {
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
              #("id", json.String(identity)),
              #("name", json.String(tool_name)),
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
              #("partial_json", json.String(json.to_string(arguments))),
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

fn latest_is_result(body: String) -> Bool {
  let assert Ok(request) = json.parse(body)
    as "the scripted provider receives JSON"
  let assert json.Array(messages) = field(request, "messages")
    as "provider messages are an array"
  let assert Ok(last) = list.last(messages)
    as "the provider has a latest message"
  case field(last, "content") {
    json.Array(blocks) ->
      list.any(blocks, fn(block) {
        case block {
          json.Object(fields) ->
            list.key_find(fields, "type") == Ok(json.String("tool_result"))
          _ -> False
        }
      })
    _ -> False
  }
}

fn latest_is_preflight(body: String) -> Bool {
  let assert Ok(request) = json.parse(body)
    as "the scripted provider receives a complete request"
  let assert json.Array(messages) = field(request, "messages")
    as "the provider has messages"
  let assert Ok(last) = list.last(messages)
    as "the current generation has a latest message"
  string.contains(json.to_string(last), "CONFIG-PREFLIGHT")
}

type Scenario {
  ShellEffect
  ConfigurationEdit
  ConfigurationIterations(url: String)
}

fn start() {
  start_scenario(ShellEffect)
}

fn start_scenario(scenario: Scenario) {
  let initial = owned_assembly_test.settings()
  let initial = case scenario {
    ConfigurationIterations(_) ->
      serve.Settings(
        ..initial,
        catalog: catalog.Catalog(
          ..initial.catalog,
          models: list.map(initial.catalog.models, fn(model) {
            catalog.CatalogModel(..model, model_id: "fixture")
          }),
        ),
        model: machine_strand.ModelIdentity("test", "fixture"),
      )
    ShellEffect | ConfigurationEdit -> initial
  }
  let configuration_path =
    filepath.directory_name(initial.session_path) <> "/loom.toml"
  let document =
    "[models.test]\ndialect = \"anthropic\"\nbase_url = \"https://unused.test\"\napi_key_env = \"UNUSED\"\nmodel_id = \"test\"\ncontext_window = 100000\nmax_output_tokens = 4096\n[roles]\nmain = [\"test\"]\n[memory]\ndistill = \"off\"\n"
  let document = case scenario {
    ConfigurationIterations(url) ->
      document
      |> string.replace("https://unused.test", url)
      |> string.replace("model_id = \"test\"", "model_id = \"fixture\"")
    ShellEffect | ConfigurationEdit -> document
  }
  let source = case scenario {
    ShellEffect -> None
    ConfigurationEdit | ConfigurationIterations(_) -> {
      assert bootstrap.ensure_private_directory(filepath.directory_name(
          configuration_path,
        ))
        == Ok(Nil)
        as "the selected file has a private directory"
      assert simplifile.write(configuration_path, document) == Ok(Nil)
        as "the trusted initial config exists"
      Some(#(configuration_path, document))
    }
  }
  let settings =
    serve.Settings(
      ..initial,
      configuration_source: source,
      secrets: secret.from_list([#("UNUSED", provider_http.dummy_key)]),
    )
  let directory = filepath.directory_name(settings.session_path)
  let assert Ok(here) = simplifile.current_directory()
    as "the real helper is relative to the client package"
  let gateway =
    catalog.gateway(
      settings.catalog,
      transport: provider_test.transport(fn(request, events) {
        case scenario {
          ShellEffect -> scripted_provider(request, events)
          ConfigurationEdit | ConfigurationIterations(_) -> {
            case latest_is_preflight(request.body) {
              True ->
                scripted_call(
                  request,
                  events,
                  "bash",
                  json.Object([
                    #("command", json.String("printf CONFIG-PREFLIGHT")),
                    #("timeout_ms", json.Int(1000)),
                  ]),
                  "config-preflight",
                )
              False -> {
                let assert Ok(observed) = simplifile.read(configuration_path)
                  as "the provider prepares an edit from the current selected file"
                let assert Ok(catalogue) = catalog.parse(observed)
                  as "the current configuration remains valid"
                let assert Ok(model) = catalog.find(catalogue, "test")
                  as "the selected model exists"
                let old =
                  "max_output_tokens = "
                  <> int.to_string(model.max_output_tokens)
                let new =
                  "max_output_tokens = "
                  <> int.to_string(model.max_output_tokens * 2)
                let args =
                  json.Object([
                    #("action", json.String("edit")),
                    #("path", json.String(configuration_path)),
                    #(
                      "digest",
                      json.String(blob.ref_for(bit_array.from_string(observed))),
                    ),
                    #("old", json.String(old)),
                    #("new", json.String(new)),
                  ])
                scripted_call(request, events, "loom_config", args, call_id)
              }
            }
          }
        }
      }),
      secrets: secret.from_list([#("UNUSED", provider_http.dummy_key)]),
      clock: clock.fixed(0),
    )
  let assert Ok(config) =
    daemon_main.parse(["--state-dir", directory <> "/daemon"])
    as "the daemon owns a fresh private root"
  let assert Ok(daemon) =
    root.start(
      root.Config(config.state_root, "Owner", 2, limits.defaults),
      manager.Assembly(
        fn(selected, sources, owner) {
          serve.build_domain(selected, sources, log.discard(), owner)
        },
        fn(record, selected, services, owner, _directory) {
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
        fn(_, _) { Nil },
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
    poll.until(within: reply_wait_ms, every: 5, attempt: fn() {
      case manager.resolve(serving.ready.registry, created.registration.id) {
        Ok(instance) -> poll.Done(instance)
        Error(_) -> poll.Retry
      }
    })
    as "the real owned assembly becomes resident"
  #(created.registration, instance)
}

// The member draws its own credential and the owner enrolls its digest
// (protocol-change/053), so no control reply carries a secret.
fn invited(address, owner, epoch, session, principal, role) {
  let bearer = claim.random_credential()
  let assert Ok(request) =
    admin.parse([
      "invite",
      session,
      principal,
      role,
      principal,
      "--credential-digest",
      claim.digest(bearer),
    ])
    as "the shipped admin parser accepts a member invitation"
  let assert Ok(response) = admin.exchange(address, owner, epoch, request)
    as "owner administration enrolls the member's own credential"
  assert field(response, "principal_id") == json.String(principal)
  bearer
}

fn socket(port, bearer, session) {
  let #(socket, response) =
    wire.connect(port, bearer, "/v2/sessions/" <> session <> "/ws")
  assert string.contains(response, "101 Switching Protocols")
  let #(_, transfer) =
    session_socket_test.begin(socket, session, within_ms: reply_wait_ms)
  let _ =
    session_socket_test.drain(
      socket,
      transfer,
      0,
      [],
      32,
      within_ms: reply_wait_ms,
    )
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
      within_ms: reply_wait_ms,
    )
  assert field(admitted, "event") == json.String("mutation_outcome")
  let pending_view =
    tui_v2_test.await(terminal.data, fn(sample) {
      list.any(sample.model.shared.approvals, fn(record) {
        record.status == approval.Pending
      })
    })
  let assert [pending] = pending_view.model.shared.approvals
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
  let denied =
    wire.reply(reader, 101, "approve", body, within_ms: reply_wait_ms)
  assert field(denied, "event") == json.String("error")
  assert field(field(denied, "body"), "code") == json.String("forbidden")
  assert api.escalation_cell(instance.runtime, pending.id) == Ok(cell)
  assert simplifile.is_file(marker_path) == Ok(False)

  // Each socket has its own caller. Both requests retain the same captured
  // seq even if one wins before the other reaches the serialized gateway.
  let answers =
    weft.new([
      fn() {
        Ok(#(
          "alice",
          wire.reply(a, 101, "approve", body, within_ms: reply_wait_ms),
        ))
      },
      fn() {
        Ok(#(
          "bob",
          wire.reply(b, 101, "approve", body, within_ms: reply_wait_ms),
        ))
      },
    ])
    |> weft.deadline(reply_wait_ms)
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
    poll.until(within: reply_wait_ms, every: 10, attempt: fn() {
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
  assert origin.stable_identity(author) == winner
  assert consumed.record.scope == Some(scope)
  let _ =
    tui_driver.play(terminal.data, [
      backend.Paste("/approvals " <> pending.id),
      backend.KeyPress("enter"),
    ])

  // The keystroke does not open the inspector. `/approvals <id>` only sends a
  // decision lookup, and the overlay appears when the daemon's reply is
  // applied. The streamed approval record arrives on its own channel, so it is
  // no evidence that the lookup has landed. Esc closes an overlay that is
  // already open and is discarded otherwise, which fixes the ordering: the
  // close must follow the inspector, or a late reply opens the panel over the
  // transcript the fixture then reads.
  //
  // A driver sample can retain the control event's model before its separate
  // rendering script returns the corresponding frame. Wait for both facts so
  // the assertion below observes the panel this fixture is about to close.
  let inspected =
    tui_v2_test.await(terminal.data, fn(sample) {
      case sample.model.view.overlay {
        tui_model.ApprovalInspector(_) ->
          list.any(sample.model.shared.approvals, fn(record) {
            record.id == pending.id && record.origin == Some(author)
          })
          && string.contains(sample.frame, "Enter confirms")
        _ -> False
      }
    })
  assert string.contains(inspected.frame, "Enter confirms")
    as "the inspector the fixture is about to close is actually painted"

  // Exact-action inspection is modal and covers the transcript summaries.
  // Close that panel before asking whether the winning author is painted.
  let closed = tui_driver.play(terminal.data, [backend.KeyPress("esc")])
  assert closed.model.view.overlay == tui_model.NoOverlay
    as "Esc dismissed the inspector rather than being dropped before it opened"

  // Completion and live-job observations can change the layout after a scroll
  // sample. Keep navigating within the existing deadline until the sample
  // returned by the wait itself contains the winning author's rendered name.
  let observed =
    tui_v2_test.await(terminal.data, fn(sample) {
      case string.contains(sample.frame, origin.display_label(author)) {
        True -> True
        False -> {
          let _ = tui_driver.play(terminal.data, [backend.KeyPress("pageup")])
          False
        }
      }
    })
  assert string.contains(observed.frame, origin.display_label(author))
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

type ConfigDecision {
  ApproveConfig
  ApproveWebConfig
  DenyConfig
  ApproveStaleConfig
}

fn exercise_configuration(
  serving: daemon_main.Serving(serve.Instance),
  directory: String,
  decision: ConfigDecision,
) -> Result(Nil, Nil) {
  let #(registration, instance) = create(serving, directory)
  let assert Ok(owner) = root.listener_credential(serving.daemon)
    as "the fixture retains the owner credential"
  let address =
    "ws://127.0.0.1:" <> int.to_string(serving.listener.port) <> "/v2/control"
  let operator_socket = socket(serving.listener.port, owner, registration.id)
  let assert Ok(terminal) = tui_driver.start(address, owner, registration.id)
    as "a real operator terminal attaches"
  let _ =
    wire.reply(
      operator_socket,
      100,
      "prompt",
      json.Object([
        #("strand", json.String("main")),
        #("text", json.String("Update my configuration.")),
      ]),
      within_ms: reply_wait_ms,
    )
  let pending_view =
    tui_v2_test.await(terminal.data, fn(sample) {
      list.any(sample.model.shared.approvals, fn(record) {
        record.status == approval.Pending
      })
    })
  let assert [pending] = pending_view.model.shared.approvals
    as "the production config tool raises one question"
  assert pending.tool == "loom_config"
    as "the default registry exposes config proposals"
  assert pending.permission
    == approval.Exact(
      case pending.permission {
        approval.Exact(action, _) -> action
        _ -> "missing"
      },
      [],
    )
    as "consent requests no filesystem grants"
  let path = directory <> "/loom.toml"
  let assert Ok(before) = simplifile.read(path)
    as "the selected file is still available"
  assert string.contains(before, "max_output_tokens = 4096")
    as "no save precedes consent"
  let _ =
    tui_driver.play(terminal.data, [
      backend.Paste("/approvals " <> pending.id),
      backend.KeyPress("enter"),
    ])
  let inspected =
    tui_v2_test.await(terminal.data, fn(sample) {
      case sample.model.view.overlay {
        tui_model.ApprovalInspector(_) ->
          string.contains(sample.frame, "Approve edit")
        _ -> False
      }
    })
  assert string.contains(inspected.frame, "max_output_tokens")
    as "the actual terminal paints the proposed hunk"
  let expected = case decision {
    ApproveConfig | ApproveWebConfig | DenyConfig -> before
    ApproveStaleConfig -> {
      let changed =
        string.replace(
          before,
          "max_output_tokens = 4096",
          "max_output_tokens = 16384",
        )
      assert simplifile.write(path, changed) == Ok(Nil)
        as "an operator saves while consent is pending"
      changed
    }
  }
  case decision {
    ApproveWebConfig -> {
      let assert Some(#(capture, _)) = pending_view.model.shared.captured
        as "the real terminal captured the authenticated session identity"
      let expected = capture.attachment.expected
      let assert Ok(digest) = access.credential_digest(claim.digest(owner))
        as "the operator credential has a bound digest"
      let assert Ok(#(principal, authority)) =
        manager.session_authority(
          serving.ready.registry,
          digest,
          registration.id,
        )
        as "the daemon resolves live operator authority"
      let attach =
        ui_relay.Attach(
          hub: instance.gateway,
          binding: gateway.Binding(
            registration.id,
            expected.epoch,
            expected.incarnation,
            "config-web",
            principal,
            authority,
            digest,
          ),
          check: fn() {
            manager.session_authority(
              serving.ready.registry,
              digest,
              registration.id,
            )
            |> gleam_result.replace_error("authorization unavailable")
          },
          ceiling: access.Operator,
          failed_reader: fn() { Nil },
        )
      let #(page, patches) =
        web_operator_page_test.start_attached(attach, expected)
      web_operator_page_test.await_text(patches, "Approve edit")
      lustre.send(
        page,
        lustre.dispatch(operator_page.Decided(
          pending.id,
          pending.seq,
          component.AllowOnce,
        )),
      )
      let assert poll.Answered(Nil) =
        poll.until(within: reply_wait_ms, every: 10, attempt: fn() {
          case api.escalation_cell(instance.runtime, pending.id) {
            Ok(cell) if cell.record.status == escalation.Consumed ->
              poll.Done(Nil)
            Ok(_) | Error(_) -> poll.Retry
          }
        })
        as "the real web button consumes exact consent through the daemon relay"
      lustre.send(page, lustre.shutdown())
    }
    ApproveConfig | ApproveStaleConfig | DenyConfig -> {
      let choice = case decision {
        DenyConfig -> "3"
        ApproveConfig | ApproveStaleConfig | ApproveWebConfig -> "1"
      }
      let _ =
        tui_driver.play(terminal.data, [
          backend.KeyPress(choice),
          backend.KeyPress("enter"),
        ])
      Nil
    }
  }
  let assert poll.Answered(results) =
    poll.until(within: reply_wait_ms, every: 10, attempt: fn() {
      case tool_results(instance) {
        [] -> poll.Retry
        results -> poll.Done(results)
      }
    })
    as "the real keyboard decision settles the tool"
  let assert [message.ToolResultMessage(is_error:, ..)] = results
    as "one result settles the exact proposal"
  let assert Ok(consumed) = api.escalation_cell(instance.runtime, pending.id)
    as "the decision has durable state"
  case decision {
    ApproveConfig | ApproveWebConfig -> {
      assert !is_error as "approved config saving succeeds through the daemon"
      assert simplifile.read(path)
        == Ok(string.replace(
          before,
          "max_output_tokens = 4096",
          "max_output_tokens = 8192",
        ))
        as "only the displayed replacement reaches disk"
      let assert Ok(revision) = config_reload.current(instance.models)
        as "the running holder remains available"
      let assert Ok(model) =
        catalog.find(client_wiring.revision_catalogue(revision), "test")
        as "the live revision retains the selected model"
      assert model.max_output_tokens == 8192
        as "approval confirms the actual hot reload"
      assert consumed.record.status == escalation.Consumed
        as "the exact action was consumed once"
    }
    DenyConfig -> {
      assert is_error as "denial settles without saving"
      assert simplifile.read(path) == Ok(expected)
        as "denial preserves the original file"
      assert consumed.record.status == escalation.Rejected
        as "the refusal remains durable"
    }
    ApproveStaleConfig -> {
      assert is_error as "approval cannot overwrite a newer observation"
      assert simplifile.read(path) == Ok(expected)
        as "the unrelated edit survives the approval"
      assert consumed.record.status == escalation.Consumed
        as "the stale action cannot replay its consent"
    }
  }
  tui_driver.stop(terminal.data)
  let _ = ffi_ws.tcp_close(operator_socket)
  Ok(Nil)
}

pub fn config_approval_terminal_saves_and_hot_reloads_test_() -> EunitTest {
  Timeout(9, fn() {
    let #(serving, directory) = start_scenario(ConfigurationEdit)
    let outcomes =
      weft.new([
        fn() { exercise_configuration(serving, directory, ApproveConfig) },
      ])
      |> weft.deadline(45_000)
      |> weft.start
    assert root.shutdown(serving.daemon, within: 30_000) == Ok(Nil)
      as "all original daemon owners retire"
    assert weft.values(outcomes) == [Nil]
      as "the real terminal approval and reload complete"
  })
}

fn config_decision_case(decision: ConfigDecision) -> EunitTest {
  Timeout(9, fn() {
    let #(serving, directory) = start_scenario(ConfigurationEdit)
    let outcomes =
      weft.new([fn() { exercise_configuration(serving, directory, decision) }])
      |> weft.deadline(45_000)
      |> weft.start
    assert root.shutdown(serving.daemon, within: 30_000) == Ok(Nil)
      as "all original owners retire after refusal"
    assert weft.values(outcomes) == [Nil]
      as "the real daemon refuses the unsafe save"
  })
}

pub fn config_approval_terminal_denial_preserves_file_test_() -> EunitTest {
  config_decision_case(DenyConfig)
}

pub fn config_approval_terminal_stale_edit_preserves_file_test_() -> EunitTest {
  config_decision_case(ApproveStaleConfig)
}

pub fn config_approval_web_saves_and_hot_reloads_test_() -> EunitTest {
  config_decision_case(ApproveWebConfig)
}

fn exercise_config_iterations(
  serving: daemon_main.Serving(serve.Instance),
  directory: String,
) -> Result(Nil, Nil) {
  let #(registration, instance) = create(serving, directory)
  let assert Ok(owner) = root.listener_credential(serving.daemon)
    as "the fixture retains its owner credential"
  let address =
    "ws://127.0.0.1:" <> int.to_string(serving.listener.port) <> "/v2/control"
  let assert Ok(terminal) = tui_driver.start(address, owner, registration.id)
    as "the real operator terminal makes approval interactive"
  let path = directory <> "/loom.toml"
  assert simplifile.is_file(path <> ".loom-edit.lock") == Ok(True)
    as "assembly establishes the lock before publishing any jail policy"
  let assert Ok(preflight) =
    api.prompt(instance.runtime, [
      message.UserMessage([message.UserText("CONFIG-PREFLIGHT", None)], 0, None),
    ])
    as "the unrelated command starts before any edit"
  let assert Ok(_) =
    api.await_result(instance.runtime, preflight, within_ms: reply_wait_ms)
    as "the unrelated jailed command completes"
  let assert Ok(entries) =
    storage.scan_entries(
      instance.runtime.session.store,
      storage.entry_scan() |> storage.entry_limit(100),
    )
    as "the preflight result is durable"
  assert list.any(entries, fn(item) {
    case item {
      entry.MessageEntry(
        message: message.ToolResultMessage(
          tool_call_id: "config-preflight",
          is_error: False,
          ..,
        ),
        ..,
      ) -> True
      _ -> False
    }
  })
    as "a config outside the writable workspace does not block Linux tool execution"
  list.each([8192, 16_384, 32_768, 65_536], fn(wanted) {
    let assert Ok(before) = simplifile.read(path)
      as "each proposal reads its current base"
    let digest = blob.ref_for(bit_array.from_string(before))
    let assert Ok(operation) =
      api.prompt(instance.runtime, [
        message.UserMessage(
          [
            message.UserText(
              "Propose the next configuration edit at " <> path,
              None,
            ),
          ],
          0,
          None,
        ),
      ])
      as "the same session accepts another editing turn"
    let pending_view =
      tui_v2_test.await(terminal.data, fn(sample) {
        list.any(sample.model.shared.approvals, fn(record) {
          record.status == approval.Pending
          && string.contains(record.preview, digest)
        })
      })
    let assert [pending] =
      list.filter(pending_view.model.shared.approvals, fn(record) {
        record.status == approval.Pending
        && string.contains(record.preview, digest)
      })
      as "every fresh revision produces an independently approvable question"
    let _ =
      tui_driver.play(terminal.data, [
        backend.KeyPress("esc"),
        backend.Paste("/approvals " <> pending.id),
        backend.KeyPress("enter"),
      ])
    let _ =
      tui_v2_test.await(terminal.data, fn(sample) {
        case sample.model.view.overlay {
          tui_model.ApprovalInspector(panel) ->
            approval_panel.review(panel).id == pending.id
            && string.contains(sample.frame, "Approve edit")
          _ -> False
        }
      })
    let _ =
      tui_driver.play(terminal.data, [
        backend.KeyPress("1"),
        backend.KeyPress("enter"),
      ])
    let assert Ok(_) =
      api.await_result(instance.runtime, operation, within_ms: reply_wait_ms)
      as "the approved operation settles"
    let assert Ok(revision) = config_reload.current(instance.models)
      as "the live holder remains available"
    let assert Ok(model) =
      catalog.find(client_wiring.revision_catalogue(revision), "test")
      as "the selected model remains live"
    assert model.max_output_tokens == wanted
      as "all four separately approved revisions publish"
  })
  tui_driver.stop(terminal.data)
  Ok(Nil)
}

pub fn config_approval_four_edits_and_fresh_lock_preflight_test_() -> EunitTest {
  Timeout(15, fn() {
    let script =
      list.flat_map([2, 3, 4], fn(_) {
        [
          provider_http.ComputedExchange(
            provider_http.AwaitPromptPrefix(
              "Propose the next configuration edit at ",
            ),
            fn(observed) {
              let assert Ok(last) = list.last(observed)
                as "the real provider retains request evidence"
              let assert provider_http.UserPrompt(text) = last.latest
                as "the current request names the fixture path"
              let path =
                string.drop_start(
                  text,
                  string.length("Propose the next configuration edit at "),
                )
              let assert Ok(observed) = simplifile.read(path)
                as "each HTTP reply proposes from current bytes"
              let assert Ok(catalogue) = catalog.parse(observed)
                as "the current complete document validates"
              let assert Ok(model) = catalog.find(catalogue, "test")
                as "the selected model remains available"
              provider_http.ReplyToolUse(
                call_id,
                "loom_config",
                json.Object([
                  #("action", json.String("edit")),
                  #("path", json.String(path)),
                  #(
                    "digest",
                    json.String(blob.ref_for(bit_array.from_string(observed))),
                  ),
                  #(
                    "old",
                    json.String(
                      "max_output_tokens = "
                      <> int.to_string(model.max_output_tokens),
                    ),
                  ),
                  #(
                    "new",
                    json.String(
                      "max_output_tokens = "
                      <> int.to_string(model.max_output_tokens * 2),
                    ),
                  ),
                ]),
              )
            },
          ),
          provider_http.ComputedExchange(
            provider_http.AwaitToolResult(call_id),
            fn(_) {
              provider_http.ReplyText("configuration iteration completed")
            },
          ),
        ]
      })
    let #(Nil, report) =
      provider_http.with_server(script, fn(url) {
        let #(serving, directory) = start_scenario(ConfigurationIterations(url))
        let outcomes =
          weft.new([fn() { exercise_config_iterations(serving, directory) }])
          |> weft.deadline(100_000)
          |> weft.start
        assert root.shutdown(serving.daemon, within: 30_000) == Ok(Nil)
          as "the iteration fixture retires every original daemon owner"
        assert weft.values(outcomes) == [Nil]
          as "fresh locking and four distinct exact approvals work end to end"
      })
    let assert Ok(requests) = report
      as "the real HTTP provider completes its finite script"
    assert list.length(requests) == 6
      as "all later revisions route their tool cycles through the actual reloaded endpoint"
  })
}
