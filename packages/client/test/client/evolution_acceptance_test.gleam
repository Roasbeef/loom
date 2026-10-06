//// The release acceptance sequence drives production session assembly.
//// A real loopback provider authors source through filesystem tools, obtains
//// jailed author-test evidence, and discovers each activated callable. Only
//// the model peer is scripted. Operator mutations enter the authenticated
//// gateway; compilation, capability calls, SQLite and native retirement are real.
//// The same runtime and conversation survive replacement and rollback.

import broker/exec
import broker/internal/call
import broker/token
import client/catalog
import client/codemode
import client/distillpass
import client/evolution/record
import client/gateway
import client/jobs
import client/protocol
import client/retryconf
import client/schedule
import client/serve
import client/tui_e2e_test.{type EunitTest, Timeout}
import core/clock
import core/ids
import core/json
import core/message
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap as native
import machine/operation
import machine/strand
import provider/adapter/anthropic
import provider/http
import provider/model
import provider/secret
import runtime/api
import simplifile
import storage/access
import support/evolution as fixture
import support/extensions
import support/internal/ffi_proc
import support/provider_http as peer
import telemetry/log
import weft/actor
import weft/poll

pub type Authored {
  Authored(candidate_id: String, evidence_id: String, evidence: String)
}

pub type ReceiptMessage {
  Published(Authored)
  Take(Subject(option.Option(Authored)))
  Done
}

/// Proves authoring, approval, replacement and rollback in one live session.
///
/// ## Examples
///
/// `make e2e-evolution` enables this fixture and requires every prerequisite.
pub fn evolution_author_approve_replace_rollback_test_() -> EunitTest {
  Timeout(70, fn() {
    case native.getenv("LOOM_EVOLUTION_E2E") {
      Ok("1") -> exercise()
      Ok(_) | Error(Nil) ->
        io.println_error("SKIP evolution acceptance: run make e2e-evolution")
    }
  })
}

fn exercise() {
  let root =
    extensions.scratch(
      "evo-" <> bit_array.base16_encode(token.production_entropy()(6)),
    )
  let assert Ok(Nil) = native.ensure_private_directory(root)
    as "the acceptance fixture owns its private state directory"
  let assert Ok(root) = native.canonical_directory(root)
    as "native policy roots are canonical absolute paths"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/work")
    as "the author workspace exists before assembly"
  let assert Ok(collector) =
    actor.new([])
    |> actor.on_message(fn(state: List(Authored), message) {
      case message {
        Published(receipt) -> actor.continue(list.append(state, [receipt]))
        Take(reply) -> {
          process.send(
            reply,
            list.first(state) |> result.map(Some) |> result.unwrap(None),
          )
          actor.continue(list.drop(state, 1))
        }
        Done -> actor.stop()
      }
    })
    |> actor.start
    as "a native fixture actor owns receipt delivery across callback processes"
  let authored = collector.data
  let script =
    list.flatten([
      author_script(1, authored),
      invoke_script("invoke version 1", "version-1:fresh"),
      author_script(2, authored),
      invoke_script("invoke version 2", "version-2:fresh"),
      invoke_script("invoke rollback", "version-1:fresh"),
      invoke_script("invoke version 2 again", "version-2:fresh"),
      invoke_script("invoke rollback again", "version-1:fresh"),
      [peer.Exchange("continue the same conversation", "conversation survived")],
    ])
  let before = helpers()
  let #(Nil, observations) =
    peer.with_extended_script(script, fn(url) {
      let settings = settings(root, url)
      let assert Ok(instance) = serve.open_instance(settings, log.discard())
        as "production assembly starts the same session used for every transition"
      let original_session = api.session_id(instance.runtime)
      let socket = operator(instance)
      let base_helpers = helpers()
      run(instance.runtime, "author version 1")
      let first = authored_result(authored)
      verify_evidence(socket, 101, first)
      approve(socket, 102, first)
      select(socket, 103, first, 0, "activate-v1", "select")
      run(instance.runtime, "invoke version 1")
      let first_helpers = new_helpers(base_helpers)
      assert first_helpers != []
        as "an invoked generation owns actual native helpers"

      run(instance.runtime, "author version 2")
      let second = authored_result(authored)
      assert first.candidate_id != second.candidate_id
        as "changed implementation bytes produce a distinct immutable identity"
      verify_evidence(socket, 104, second)
      approve(socket, 105, second)
      select(socket, 106, second, 1, "activate-v2", "select")
      assert_departed(first_helpers)
      run(instance.runtime, "invoke version 2")
      let second_helpers = new_helpers(base_helpers)
      assert second_helpers != [] && list.length(second_helpers) <= 2
        as "an invoked generation retains its bounded native helper pool"

      // A retry names the original committed request even after another version
      // supersedes it. Its receipt cannot retire the current generation again.
      let replayed =
        request(
          socket,
          110,
          "select",
          json.Object([
            #("candidate_id", json.String(first.candidate_id)),
            #("evidence_id", json.String(first.evidence_id)),
            #("expected_generation", json.Int(0)),
            #("request_id", json.String("activate-v1")),
            #("deadline_ms", json.Int(120_000)),
            #("reason", json.String("operator acceptance fixture")),
          ]),
        )
      assert field(replayed, "state") == json.String("committed")
        && field(field(replayed, "committed"), "candidate_id")
        == json.String(first.candidate_id)
        as "the durable retry returns the original commit without staging"
      assert new_helpers(base_helpers) == second_helpers
        as "replaying a superseded request preserves actual current workers"

      select(socket, 107, first, 2, "rollback-v1", "rollback")
      assert_departed(second_helpers)
      run(instance.runtime, "invoke rollback")
      let rolled_back_helpers = new_helpers(base_helpers)
      assert rolled_back_helpers != [] && list.length(rolled_back_helpers) <= 2
      select(socket, 108, second, 3, "activate-v2-again", "select")
      assert_departed(rolled_back_helpers)
      run(instance.runtime, "invoke version 2 again")
      let second_cycle_helpers = new_helpers(base_helpers)
      assert second_cycle_helpers != []
        && list.length(second_cycle_helpers) <= 2
      select(socket, 109, first, 4, "rollback-v1-again", "rollback")
      assert_departed(second_cycle_helpers)
      run(instance.runtime, "invoke rollback again")
      let final_helpers = new_helpers(base_helpers)
      assert final_helpers != [] && list.length(final_helpers) <= 2
      assert api.session_id(instance.runtime) == original_session
        as "rollback keeps the original durable conversation identity"
      run(instance.runtime, "continue the same conversation")
      serve.close_instance(instance)
      assert_departed(final_helpers)
      assert helpers() == before
        as "session retirement leaves no native helper behind"
      Nil
    })
  let assert Ok(requests) = observations
    as "every finite scripted step consumes an actual provider request"
  assert list.length(requests) == list.length(script)
  assert list.any(requests, fn(request) {
      string.contains(json.to_string(request.body), "conversation survived")
    })
    == False
    as "the final answer is emitted by the provider rather than copied from user input"
  process.send(authored, Done)
  io.println_error(
    "evolution acceptance: author, test, approve, replace, rollback, continue and retire passed",
  )
}

fn author_script(
  version: Int,
  authored: Subject(ReceiptMessage),
) -> List(peer.Exchange) {
  author_script_with(version, authored, fixture.extension(version))
}

/// Authors arbitrary source through the same production filesystem tools.
pub fn author_script_with(
  version: Int,
  authored: Subject(ReceiptMessage),
  files: List(#(String, String)),
) -> List(peer.Exchange) {
  let suffix = "v" <> int.to_string(version)
  let writes =
    list.index_map(files, fn(file, index) {
      let expect = case index {
        0 -> peer.AwaitPrompt("author version " <> int.to_string(version))
        _ ->
          peer.AwaitToolResult(
            "write-" <> suffix <> "-" <> int.to_string(index - 1),
          )
      }
      peer.ComputedExchange(expect, fn(_) {
        peer.ReplyToolUse(
          "write-" <> suffix <> "-" <> int.to_string(index),
          "fs_write",
          json.Object([
            #("path", json.String(suffix <> "/" <> file.0)),
            #("content", json.String(file.1)),
          ]),
        )
      })
    })
  let propose =
    peer.ComputedExchange(
      peer.AwaitToolResult(
        "write-" <> suffix <> "-" <> int.to_string(list.length(files) - 1),
      ),
      fn(_) {
        peer.ReplyToolUse(
          "propose-" <> suffix,
          "evolution_propose",
          json.Object([
            #("directory", json.String(suffix)),
            #("name", json.String("echo")),
            #("kind", json.String("extension")),
            #("test_entry", json.String("evolution_check")),
            #(
              "description",
              json.String("Echo fresh inputs with an immutable version marker."),
            ),
            #("input_schema", json.String(json.to_string(fixture.schema()))),
          ]),
        )
      },
    )
  let evaluation =
    peer.ComputedExchange(
      peer.AwaitToolResult("propose-" <> suffix),
      fn(requests) {
        let candidate = latest_result(requests)
        peer.ReplyToolUse(
          "test-" <> suffix,
          "evolution_test",
          json.Object([
            #(
              "candidate_id",
              json.String(required_text(candidate, "candidate_id")),
            ),
          ]),
        )
      },
    )
  let settled =
    peer.ComputedExchange(peer.AwaitToolResult("test-" <> suffix), fn(requests) {
      let observed = latest_result(requests)
      process.send(
        authored,
        Published(Authored(
          required_text(observed, "candidate_id"),
          required_text(observed, "evidence_id"),
          required_text(observed, "evidence"),
        )),
      )
      peer.ReplyText("author evidence retained " <> suffix)
    })
  list.append(writes, [propose, evaluation, settled])
}

pub fn invoke_script(prompt: String, expected: String) -> List(peer.Exchange) {
  [
    peer.ToolUseExchange(
      prompt,
      "catalogue-" <> prompt,
      "evolution_catalogue",
      json.Object([]),
    ),
    peer.ComputedExchange(
      peer.AwaitToolResult("catalogue-" <> prompt),
      fn(requests) {
        let catalogue = latest_result(requests)
        let assert json.Array([active]) = field(catalogue, "active")
          as "discovery yields the single currently published callable"
        assert field(active, "schema") == fixture.schema()
          as "the discovered contract belongs to the implementation being invoked"
        peer.ReplyToolUse(
          "invoke-" <> prompt,
          "evolution_invoke",
          json.Object([
            #("candidate_id", field(active, "candidate_id")),
            #("generation", field(active, "generation")),
            #("tool", field(active, "name")),
            #("arguments", json.Object([#("say", json.String("fresh"))])),
          ]),
        )
      },
    ),
    peer.ToolResultExchange(
      "invoke-" <> prompt,
      expected,
      "invocation verified " <> expected,
    ),
  ]
}

fn latest_result(requests: List(peer.ObservedRequest)) -> json.JsonValue {
  let assert Ok(request) = list.last(requests)
    as "a computed answer receives the actual request it is answering"
  let assert peer.SuccessfulToolResult(_, text) = request.latest
    as "only a successful real tool result can advance this script"
  let assert Ok(value) = json.parse(text)
    as "the stable evolution door returns structured JSON"
  value
}

pub fn field(value: json.JsonValue, name: String) -> json.JsonValue {
  let assert json.Object(fields) = value as "a tool receipt is an object"
  let assert Ok(found) = list.key_find(fields, name)
    as "the receipt contains the exact required field"
  found
}

pub fn required_text(value: json.JsonValue, name: String) -> String {
  let assert json.String(text) = field(value, name)
    as "the receipt identity is text"
  text
}

pub fn authored_result(subject: Subject(ReceiptMessage)) -> Authored {
  let assert Ok(Some(authored)) =
    call.try_call(subject, waiting: 1000, sending: Take)
    as "the real test result carries the durable evidence identity"
  authored
}

/// Runs a user turn through the real runtime and waits for its settled result.
///
/// ## Examples
///
/// `evolution_acceptance_test.run(...)` shares the production fixture seam.
pub fn run(runtime: api.Runtime, text: String) {
  let assert Ok(op) =
    api.prompt(runtime, [
      message.UserMessage(
        content: [message.UserText(text, None)],
        origin: None,
        timestamp: native.system_time_ms(),
      ),
    ])
    as "an ordinary user turn is admitted through the production runtime"
  let assert Ok(operation.RunLastResult(outcome: operation.RunCompleted(_), ..)) =
    api.await_result(runtime, op, within_ms: 120_000)
    as "the model turn and its real tool invocations finish successfully"
  Nil
}

/// Attaches an authenticated owner to the real gateway.
///
/// ## Examples
///
/// `evolution_acceptance_test.operator(...)` shares the production fixture seam.
pub fn operator(instance: serve.Instance) -> gateway.ConnectionHandle {
  let principal =
    access.Principal("fixture-owner", "Fixture Owner", access.OwnerPrincipal)
  let assert Ok(digest) = access.credential_digest(string.repeat("a", 64))
    as "the fixture binding has a valid credential digest"
  let assert Ok(socket) =
    gateway.attach_authenticated(
      instance.gateway,
      gateway.Binding(
        ids.session_id_to_string(api.session_id(instance.runtime)),
        "fixture-epoch",
        "fixture-incarnation",
        "fixture-owner-connection",
        principal,
        access.Owner,
        digest,
      ),
      fn() { Ok(#(principal, access.Owner)) },
      fn(_) { Nil },
      fn() { Nil },
      fn() { Nil },
      process.self(),
    )
    as "the operator reaches the production gateway with a native owner binding"
  let assert Ok(_) =
    gateway.connection_request(
      socket,
      protocol.encode_command(protocol.CommandEnvelope(
        100,
        protocol.Subscribe(
          ids.session_id_to_string(api.session_id(instance.runtime)),
          None,
        ),
      )),
    )
    as "the authenticated operator subscribes before mutation"
  socket
}

/// Sends one correlated command through the authenticated gateway.
///
/// ## Examples
///
/// `evolution_acceptance_test.request(...)` shares the production fixture seam.
pub fn request(
  socket: gateway.ConnectionHandle,
  id: Int,
  action: String,
  arguments: json.JsonValue,
) -> json.JsonValue {
  let assert Ok(frame) =
    gateway.connection_request(
      socket,
      protocol.encode_command(protocol.CommandEnvelope(
        id,
        protocol.Evolution(action, arguments),
      )),
    )
    as "the authenticated evolution command receives its exact bounded reply"
  let assert Ok(protocol.EventEnvelope(
    reply_to: Some(received),
    event: protocol.SnapshotEvent(protocol.EvolutionSnapshot(board)),
    ..,
  )) = protocol.decode_event(frame)
    as "the command returns a correlated evolution receipt"
  assert received == id
  board
}

pub fn verify_evidence(
  socket: gateway.ConnectionHandle,
  id: Int,
  authored: Authored,
) {
  let observed =
    request(
      socket,
      id,
      "evidence",
      json.Object([
        #("evidence_id", json.String(authored.evidence_id)),
      ]),
    )
  let assert Ok(evidence) = record.decode_evidence(authored.evidence)
    as "the author-test envelope is content addressed and totally decoded"
  assert evidence.verdict == record.Passed as evidence.observation
  assert evidence.purpose == record.AuthorTests
  assert record.id_string(evidence.candidate_id) == authored.candidate_id
  let assert Ok(expected) = json.parse(authored.evidence)
    as "the stored evidence has a canonical JSON envelope"
  assert observed == expected
    as "operator inspection reads the evidence durably before approval"
}

pub fn approve(socket: gateway.ConnectionHandle, id: Int, authored: Authored) {
  let _ =
    request(
      socket,
      id,
      "approve",
      json.Object([
        #("candidate_id", json.String(authored.candidate_id)),
        #("evidence_id", json.String(authored.evidence_id)),
      ]),
    )
  Nil
}

pub fn select(
  socket: gateway.ConnectionHandle,
  id: Int,
  authored: Authored,
  expected: Int,
  request_id: String,
  action: String,
) {
  let receipt =
    request(
      socket,
      id,
      action,
      json.Object([
        #("candidate_id", json.String(authored.candidate_id)),
        #("evidence_id", json.String(authored.evidence_id)),
        #("expected_generation", json.Int(expected)),
        #("request_id", json.String(request_id)),
        #("deadline_ms", json.Int(120_000)),
        #("reason", json.String("operator acceptance fixture")),
      ]),
    )
  assert field(receipt, "state") == json.String("queued")
  assert field(receipt, "request_id") == json.String(request_id)

  // Compilation runs outside the gateway response window. The original request
  // identity leads to its durable commit rather than another selection attempt.
  let assert poll.Answered(completed) =
    poll.until(within: 125_000, every: 100, attempt: fn() {
      let status =
        request(
          socket,
          id + 1000,
          "status",
          json.Object([
            #("request_id", json.String(request_id)),
          ]),
        )
      case field(status, "state") {
        json.String("queued")
        | json.String("running")
        | json.String("committed") -> poll.Retry
        json.String("completed") -> poll.Done(status)
        other -> {
          assert other == json.String("completed") as json.to_string(status)
          poll.Done(status)
        }
      }
    })
    as "the admitted transition reaches a conclusive receipt"
  let committed = field(completed, "committed")
  assert field(committed, "candidate_id") == json.String(authored.candidate_id)
  assert field(committed, "generation") == json.Int(expected + 1)
  assert field(completed, "published") == committed
    as "publication follows the exact native commit and retirement witness"
}

/// Assembles an isolated fixture with the real toolchain, SQLite and tools.
///
/// ## Examples
///
/// `evolution_acceptance_test.settings(...)` shares the production fixture seam.
pub fn settings(root: String, url: String) -> serve.Settings {
  let assert Ok(helper) = native.find_executable("../sandbox/loom-exec")
    as "make e2e-evolution provides the real native helper"
  let assert Ok(seed) = native.canonical_directory("../../build/codemode-seed")
    as "make e2e-evolution provides the offline seed"
  let catalogue =
    catalog.Catalog(
      models: [
        catalog.CatalogModel(
          name: "fixture",
          dialect: catalog.Anthropic,
          base_url: url,
          api_key_env: "FIXTURE_KEY",
          model_id: "fixture",
          context_window: 100_000,
          max_output_tokens: 4096,
          thinking: model.ThinkingOff,
          pricing: None,
          vision: catalog.TextOnly,
          max_images: 8,
        ),
      ],
      roles: [#(model.Main, ["fixture"])],
      mcp_servers: [],
      lsp_servers: [],
    )
  let gateway =
    catalog.gateway(
      catalogue,
      http.httpc_transport(),
      secret.from_list([#("FIXTURE_KEY", peer.dummy_key)]),
      clock.from_function(native.system_time_ms),
    )
  serve.Settings(
    first_prompt: None,
    peer_directory: None,
    codemode_sockets: Some(root <> "/run"),
    secrets: secret.from_list([]),
    secret_failures: [],
    session_path: root <> "/session.db",
    domain_paths: None,
    bind_host: "127.0.0.1",
    bind_port: 0,
    token_path: root <> "/session.token",
    workspace: root <> "/work",
    base_policy: serve.base_policy(root <> "/work"),
    helper_path: helper,
    helper_pool_size: 2,
    session_id: "evolution-acceptance",
    demand: exec.BestEffort,
    gateway:,
    evolution_profiles: None,
    catalog: catalogue,
    system: None,
    home: Some(root <> "/empty-home"),
    model: strand.ModelIdentity("fixture", "fixture"),
    context_window: 100_000,
    max_output_tokens: 4096,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(True, 16_384, 20_000),
    codemode_seed: seed,
    codemode_seams: codemode.WorkspaceOnly,
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    jobs_policy: jobs.default_policy,
    retry_policy: retryconf.default_policy,
    deactivated_tools: [],
    memory: distillpass.no_pass(),
    tools: catalog.default_tools(),
    advisor: None,
  )
}

/// Observes native helper birth identities beneath this test VM.
///
/// ## Examples
///
/// `evolution_acceptance_test.helpers(...)` shares the production fixture seam.
pub fn helpers() -> List(#(Int, native.ProcessIdentity)) {
  let assert Ok(ps) = ffi_proc.which("ps")
    as "native worker evidence requires ps"
  let assert Ok(#(0, output)) =
    ffi_proc.run(ps, ["-axo", "pid=,ppid=,comm="], ".")
    as "the native process census completes"
  let parent = native.current_process_id()
  let rows =
    string.split(output, "\n")
    |> list.filter_map(fn(line) {
      let columns =
        string.split(string.trim(line), " ")
        |> list.filter(fn(word) { word != "" })
      case columns {
        [pid, ppid, ..command] -> {
          use pid <- result.try(int.parse(pid))
          use ppid <- result.try(int.parse(ppid))
          Ok(#(pid, ppid, string.join(command, " ")))
        }
        _ -> Error(Nil)
      }
    })
  let ancestry = list.map(rows, fn(row) { #(row.0, row.1) })
  rows
  |> list.filter_map(fn(row) {
    use Nil <- result.try(
      case
        string.contains(row.2, "loom-exec")
        && descendant(row.0, parent, ancestry, list.length(rows))
      {
        True -> Ok(Nil)
        False -> Error(Nil)
      },
    )
    use identity <- result.try(
      native.process_identity(row.0) |> result.replace_error(Nil),
    )
    case identity {
      native.ProcessPresent(_) -> Ok(#(row.0, identity))
      native.ProcessAbsent -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
}

// OTP can retain erl_child_setup between this VM and a port's native helper.
// The finite process inventory bounds the ancestry walk, so a recycled or
// inconsistent snapshot cannot loop and an unrelated VM is never counted.
fn descendant(
  pid: Int,
  parent: Int,
  ancestry: List(#(Int, Int)),
  remaining: Int,
) -> Bool {
  case remaining <= 0 {
    True -> False
    False ->
      case list.key_find(ancestry, pid) {
        Ok(found) if found == parent -> True
        Ok(found) -> descendant(found, parent, ancestry, remaining - 1)
        Error(Nil) -> False
      }
  }
}

pub fn helper_census_follows_native_setup_parent_and_refuses_foreign_vm_test() {
  let rows = [#(20, 10), #(30, 20), #(40, 99), #(50, 50)]
  assert descendant(30, 10, rows, list.length(rows))
  assert !descendant(40, 10, rows, list.length(rows))
  assert !descendant(50, 10, rows, list.length(rows))
}

pub fn new_helpers(
  base: List(#(Int, native.ProcessIdentity)),
) -> List(#(Int, native.ProcessIdentity)) {
  helpers() |> list.filter(fn(helper) { !list.contains(base, helper) })
}

pub fn assert_departed(old: List(#(Int, native.ProcessIdentity))) {
  list.each(old, fn(helper) {
    assert native.process_identity(helper.0) != Ok(helper.1)
      as "publication waits for the predecessor's original native process to depart"
  })
}
