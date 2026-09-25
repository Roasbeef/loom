//// The client actor against a scripted in-process fake server: the
//// handshake, the capability gate, request deadlines and their
//// cancellation, the server's own words, answers to server requests,
//// every way the server dies, document sync and its 64-document bound,
//// ADR-013 §3's two settlement rules replayed against both measured
//// server behaviours, and the stop sequence. No OS process anywhere; every
//// deadline is tens of milliseconds, and nothing asserts an absence by
//// sleeping — an absence is checked behind a later message the server
//// must have seen first.

import core/json.{type JsonValue}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lsp/client
import lsp/protocol
import lsp/range
import mcp/jsonrpc.{type Id, type Inbound}
import mcp/transport
import support/fake_server.{
  type Action, type Fake, Close, Got, GotClose, Later, Raw, Reply,
}

// --- fixtures ---------------------------------------------------------------

const root = "/work"

const a = "/work/src/a.gleam"

const b = "/work/src/b.gleam"

const a_uri = "file:///work/src/a.gleam"

const b_uri = "file:///work/src/b.gleam"

fn advertised(names: List(String)) -> JsonValue {
  json.Object(
    list.map(names, fn(name) { #(name, json.Bool(True)) })
    |> list.append([#("textDocumentSync", json.Int(1))]),
  )
}

// Everything the harness asks except call hierarchy, which `gleam lsp`
// does not serve (ADR-013's measured table).
fn gleam_like_capabilities() -> JsonValue {
  advertised([
    "definitionProvider", "referencesProvider", "hoverProvider",
    "documentSymbolProvider", "renameProvider",
  ])
}

fn options() -> client.Options {
  client.Options(
    ..client.options(server: "fake", root:, language_id: "gleam"),
    initialize_ms: 2000,
  )
}

fn started(
  capabilities: JsonValue,
  initial: state,
  script: fn(state, Inbound) -> #(state, List(Action)),
) -> #(client.Client, Fake(state)) {
  let fake = fake_server.start(capabilities, initial, script)
  let assert Ok(started) = client.start(fake_server.seam(fake), options())
    as "the scripted handshake should succeed"
  #(started, fake)
}

fn silent(state: Nil, _inbound: Inbound) -> #(Nil, List(Action)) {
  #(state, [])
}

fn field(value: JsonValue, key: String) -> JsonValue {
  case value {
    json.Object(fields) -> result.unwrap(list.key_find(fields, key), json.Null)
    json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> json.Null
  }
}

// The params of every notification the client wrote under `method`.
fn notified(fake: Fake(state), method: String) -> List(JsonValue) {
  list.filter_map(fake_server.seen(fake), fn(entry) {
    case entry {
      Got(jsonrpc.Notification(method: sent, params: Some(params)))
        if sent == method
      -> Ok(params)
      Got(..) | GotClose -> Error(Nil)
    }
  })
}

// The ids of every request the client wrote under `method`.
fn requested(fake: Fake(state), method: String) -> List(Id) {
  list.filter_map(fake_server.seen(fake), fn(entry) {
    case entry {
      Got(jsonrpc.ServerRequest(id:, method: sent, ..)) if sent == method ->
        Ok(id)
      Got(..) | GotClose -> Error(Nil)
    }
  })
}

// The client's answer to the server request with `id`.
fn answer_to(
  log: List(fake_server.Seen),
  id: Id,
) -> Result(Result(JsonValue, jsonrpc.RpcError), Nil) {
  list.find_map(log, fn(entry) {
    case entry {
      Got(jsonrpc.Response(id: answered, outcome:)) if answered == id ->
        Ok(outcome)
      Got(..) | GotClose -> Error(Nil)
    }
  })
}

fn messages(
  published: List(#(String, List(protocol.ServerDiagnostic))),
) -> List(#(String, List(String))) {
  list.map(published, fn(entry) {
    #(entry.0, list.map(entry.1, fn(diagnostic) { diagnostic.message }))
  })
}

fn await_down(monitor: process.Monitor) -> process.ExitReason {
  let assert Ok(down) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(2000)
    as "the client should exit"
  down.reason
}

// Runs `work` in its own process and hands its answer back, so a test
// can hold several callers waiting on the client at once.
fn in_background(work: fn() -> a) -> process.Subject(a) {
  let answers = process.new_subject()
  process.spawn(fn() { process.send(answers, work()) })
  answers
}

fn answer(answers: process.Subject(a)) -> a {
  let assert Ok(value) = process.receive(answers, 3000)
    as "the background caller should be answered"
  value
}

// --- the handshake ----------------------------------------------------------

pub fn the_handshake_decodes_capabilities_and_sends_initialized_test() {
  let capabilities =
    json.Object([
      #("hoverProvider", json.Bool(True)),
      #("definitionProvider", json.Object([])),
      #("renameProvider", json.Object([#("prepareProvider", json.Bool(True))])),
      #("textDocumentSync", json.Int(1)),
    ])
  let #(started, fake) = started(capabilities, Nil, silent)

  assert client.capabilities(started)
    == Ok(protocol.ServerCapabilities(
      definition: protocol.Provided,
      references: protocol.NotProvided,
      hover: protocol.Provided,
      document_symbol: protocol.NotProvided,
      rename: protocol.RenameWithPrepare,
      call_hierarchy: protocol.NotProvided,
      sync: protocol.SyncFull,
      open_close: protocol.OpenCloseNotified,
      position_encoding: None,
    ))

  // `initialized` follows the answer; the root travels as `rootUri` and
  // as the one workspace folder.
  let assert Ok(log) =
    fake_server.await(fake, fn(_) {
      fake_server.methods(fake) == ["initialize", "initialized"]
    })
  let assert [Got(jsonrpc.ServerRequest(params: Some(params), ..)), ..] = log
  assert field(params, "rootUri") == json.String("file:///work")
  assert field(params, "workspaceFolders")
    == json.Array([
      json.Object([
        #("uri", json.String("file:///work")),
        #("name", json.String("work")),
      ]),
    ])
}

pub fn a_refused_initialize_fails_start_in_the_servers_words_test() {
  let fake =
    fake_server.start_raw(Nil, fn(state, inbound) {
      case inbound {
        jsonrpc.ServerRequest(id:, method: "initialize", ..) -> #(state, [
          Reply(fake_server.error_response(id, -32_603, "no project here")),
        ])
        jsonrpc.ServerRequest(..)
        | jsonrpc.Notification(..)
        | jsonrpc.Response(..) -> #(state, [])
      }
    })

  assert client.start(fake_server.seam(fake), options())
    == Error(
      client.HandshakeFailed(client.ServerError(
        code: -32_603,
        message: "no project here",
      )),
    )

  // The refused client closed its transport before `start` returned.
  assert list.contains(fake_server.methods(fake), "<close>")
}

pub fn a_non_utf16_position_encoding_is_refused_test() {
  let capabilities = json.Object([#("positionEncoding", json.String("utf-8"))])
  let fake = fake_server.start(capabilities, Nil, silent)

  assert client.start(fake_server.seam(fake), options())
    == Error(client.EncodingUnsupported(encoding: "utf-8"))
}

pub fn a_port_transport_is_refused_before_anything_runs_test() {
  let port = transport.PortTransport(transport.spawn("/bin/true", []))
  let assert Error(client.TransportRefused(_)) = client.start(port, options())
}

// --- requests ---------------------------------------------------------------

pub fn an_unadvertised_request_never_reaches_the_server_test() {
  let capabilities = advertised(["hoverProvider"])
  let #(started, fake) =
    started(capabilities, Nil, fn(state, inbound) {
      case inbound {
        jsonrpc.ServerRequest(id:, method: "textDocument/hover", ..) -> #(
          state,
          [Reply(fake_server.response(id, json.Null))],
        )
        jsonrpc.ServerRequest(..)
        | jsonrpc.Notification(..)
        | jsonrpc.Response(..) -> #(state, [])
      }
    })
  let at = range.Position(0, 0)

  assert client.prepare_call_hierarchy(started, a, at, 1000)
    == Error(client.Unsupported(protocol.CallHierarchyFeature))
  assert client.rename(started, a, at, "salute", 1000)
    == Error(client.Unsupported(protocol.RenameFeature))
  assert client.definition(started, a, at, 1000)
    == Error(client.Unsupported(protocol.DefinitionFeature))

  // The hover was written after the refused three and answered, so the
  // server has seen everything the client ever sent it.
  assert client.hover(started, a, at, 1000) == Ok(None)
  assert fake_server.methods(fake)
    == ["initialize", "initialized", "textDocument/hover"]
}

pub fn a_timed_out_request_is_cancelled_and_the_client_keeps_serving_test() {
  let #(started, fake) =
    started(gleam_like_capabilities(), Nil, fn(state, inbound) {
      case inbound {
        jsonrpc.ServerRequest(id:, method: "textDocument/definition", ..) -> #(
          state,
          [Reply(fake_server.response(id, json.Null))],
        )
        jsonrpc.ServerRequest(..)
        | jsonrpc.Notification(..)
        | jsonrpc.Response(..) -> #(state, [])
      }
    })
  let at = range.Position(2, 4)

  assert client.hover(started, a, at, 30)
    == Error(client.TimedOut(after_ms: 30))

  // The cancellation names the id the hover went out under.
  let assert Ok(Nil) = fake_server.await_method(fake, "$/cancelRequest")
  let assert [hover_id] = requested(fake, "textDocument/hover")
  let assert [cancel] = notified(fake, "$/cancelRequest")
  let assert jsonrpc.IdInt(hover_id) = hover_id
  assert field(cancel, "id") == json.Int(hover_id)

  assert client.definition(started, a, at, 1000) == Ok([])
}

pub fn a_server_error_keeps_the_servers_words_test() {
  let words = "renaming this would make it unexported"
  let #(started, _fake) =
    started(gleam_like_capabilities(), Nil, fn(state, inbound) {
      case inbound {
        jsonrpc.ServerRequest(id:, method: "textDocument/rename", ..) -> #(
          state,
          [Reply(fake_server.error_response(id, -32_803, words))],
        )
        jsonrpc.ServerRequest(..)
        | jsonrpc.Notification(..)
        | jsonrpc.Response(..) -> #(state, [])
      }
    })

  assert client.rename(started, a, range.Position(0, 7), "hello", 1000)
    == Error(client.ServerError(code: -32_803, message: words))
}

pub fn a_path_that_is_not_absolute_is_refused_before_sending_test() {
  let #(started, _fake) = started(gleam_like_capabilities(), Nil, silent)

  assert client.hover(started, "src/a.gleam", range.Position(0, 0), 1000)
    == Error(client.InvalidPath(path: "src/a.gleam"))
}

pub fn server_requests_are_answered_from_policy_test() {
  let #(_started, fake) = started(gleam_like_capabilities(), Nil, silent)
  let items =
    json.Object([#("items", json.Array([json.Object([]), json.Object([])]))])
  let edit = json.Object([#("edit", json.Object([]))])
  fake_server.inject(fake, [
    Reply(fake_server.server_request(
      jsonrpc.IdInt(7),
      "workspace/configuration",
      Some(items),
    )),
    Reply(fake_server.server_request(
      jsonrpc.IdString("apply"),
      "workspace/applyEdit",
      Some(edit),
    )),
    Reply(fake_server.server_request(jsonrpc.IdInt(9), "custom/unknown", None)),
  ])

  let assert Ok(log) =
    fake_server.await(fake, fn(log) {
      result.is_ok(answer_to(log, jsonrpc.IdInt(9)))
    })
  assert answer_to(log, jsonrpc.IdInt(7))
    == Ok(Ok(json.Array([json.Null, json.Null])))
  let assert Ok(Ok(applied)) = answer_to(log, jsonrpc.IdString("apply"))
  assert field(applied, "applied") == json.Bool(False)
  let assert Ok(Error(refusal)) = answer_to(log, jsonrpc.IdInt(9))
  assert refusal.code == protocol.method_not_found_code
}

// --- death ------------------------------------------------------------------

pub fn server_death_answers_every_waiter_and_reports_the_death_test() {
  let #(started, fake) = started(gleam_like_capabilities(), Nil, silent)
  let monitor = process.monitor(client.pid(started))

  let hovering =
    in_background(fn() {
      client.hover(started, a, range.Position(0, 0), 5000)
      |> result.replace(Nil)
    })
  let settling =
    in_background(fn() {
      client.settle(started, [a], 5000) |> result.replace(Nil)
    })

  // Both waiters are in the actor before the server dies.
  let assert Ok(_) =
    fake_server.await(fake, fn(_) {
      let methods = fake_server.methods(fake)
      list.contains(methods, "textDocument/hover")
      && list.contains(methods, "textDocument/documentSymbol")
    })
  fake_server.inject(fake, [Close("killed by the test")])

  let assert Error(client.Unavailable(reason)) = answer(hovering)
  assert string.contains(reason, "killed by the test")
  let assert Error(client.Unavailable(reason)) = answer(settling)
  assert string.contains(reason, "killed by the test")
  let assert process.Abnormal(_) = await_down(monitor)

  // A dead client answers in-band, and a stop finds nothing to stop.
  let assert Error(client.Unavailable(_)) = client.open_paths(started)
  assert client.stop(started, 100) == client.AlreadyGone
}

pub fn framing_garbage_kills_the_client_with_a_reason_test() {
  let #(started, fake) = started(gleam_like_capabilities(), Nil, silent)
  let monitor = process.monitor(client.pid(started))
  let hovering =
    in_background(fn() {
      client.hover(started, a, range.Position(0, 0), 5000)
      |> result.replace(Nil)
    })
  let assert Ok(Nil) = fake_server.await_method(fake, "textDocument/hover")

  fake_server.inject(fake, [Raw(<<"Content-Length: nope\r\n\r\n":utf8>>)])

  let assert Error(client.Unavailable(reason)) = answer(hovering)
  assert string.contains(reason, "not lsp framing")
  assert string.contains(reason, "nope")
  let assert process.Abnormal(_) = await_down(monitor)

  // The faulted client closed its transport rather than abandoning it.
  assert list.contains(fake_server.methods(fake), "<close>")
}

pub fn a_body_that_is_not_json_rpc_kills_the_client_test() {
  let #(started, fake) = started(gleam_like_capabilities(), Nil, silent)
  let monitor = process.monitor(client.pid(started))

  fake_server.inject(fake, [Raw(<<"Content-Length: 2\r\n\r\n{}":utf8>>)])

  let assert process.Abnormal(_) = await_down(monitor)
}

// --- documents --------------------------------------------------------------

pub fn sync_tracks_versions_and_the_last_text_sent_test() {
  let #(started, fake) = started(gleam_like_capabilities(), Nil, silent)

  assert client.sync(started, [client.Open(a, "gleam", "one")]) == Ok(Nil)
  assert client.sync(started, [client.Change(a, "two")]) == Ok(Nil)
  assert client.synced_text(started, a) == Ok(Some("two"))

  // A change to a document the server does not hold opens it, in the
  // options' language.
  assert client.sync(started, [client.Change(b, "bee")]) == Ok(Nil)
  assert client.open_paths(started) == Ok([a, b])
  assert client.sync(started, [client.Close(a)]) == Ok(Nil)
  assert client.synced_text(started, a) == Ok(None)
  assert client.open_paths(started) == Ok([b])

  let assert Ok(Nil) = fake_server.await_method(fake, "textDocument/didClose")
  let assert [opened_a, opened_b] = notified(fake, "textDocument/didOpen")
  let assert [changed_a] = notified(fake, "textDocument/didChange")
  let document = field(opened_a, "textDocument")
  assert field(document, "uri") == json.String(a_uri)
  assert field(document, "text") == json.String("one")
  assert field(field(opened_b, "textDocument"), "languageId")
    == json.String("gleam")

  // The change carries the whole new text under a higher version.
  let assert json.Int(opened_version) = field(document, "version")
  let assert json.Int(changed_version) =
    field(field(changed_a, "textDocument"), "version")
  assert changed_version > opened_version
  assert field(changed_a, "contentChanges")
    == json.Array([json.Object([#("text", json.String("two"))])])
}

pub fn the_sixty_fifth_document_closes_the_least_recently_synced_test() {
  let #(started, fake) = started(gleam_like_capabilities(), Nil, silent)
  let path = fn(n) { "/work/src/m" <> int.to_string(n) <> ".gleam" }
  let first_sixty_four =
    list.map(int.range(from: 63, to: -1, with: [], run: list.prepend), fn(n) {
      client.Open(path(n), "gleam", "")
    })

  assert client.sync(started, first_sixty_four) == Ok(Nil)

  // Touching m0 makes m1 the least recently synced.
  assert client.sync(started, [client.Change(path(0), "touched")]) == Ok(Nil)
  assert notified(fake, "textDocument/didClose") == []
  assert client.sync(started, [client.Open(path(64), "gleam", "")]) == Ok(Nil)

  let assert Ok(Nil) = fake_server.await_method(fake, "textDocument/didClose")
  let assert [closed] = notified(fake, "textDocument/didClose")
  assert field(field(closed, "textDocument"), "uri")
    == json.String("file://" <> path(1))
  let assert Ok(open) = client.open_paths(started)
  assert list.length(open) == client.max_open_documents
  assert list.contains(open, path(0))
  assert list.contains(open, path(64))
  assert !list.contains(open, path(1))
  assert client.synced_text(started, path(1)) == Ok(None)
}

// --- settlement -------------------------------------------------------------

type Health {
  Clean
  Broken
}

// `gleam lsp`, as measured: publications carry no version, every
// affected URI is published before the answer to a request sent after
// the change, and a clean → clean edit publishes nothing at all.
fn gleam_like(health: Health, inbound: Inbound) -> #(Health, List(Action)) {
  case inbound {
    jsonrpc.Notification(method: "textDocument/didChange", params: Some(params)) -> {
      let assert [change] = case field(params, "contentChanges") {
        json.Array(changes) -> changes
        _ -> []
      }
      case field(change, "text") {
        json.String("oops") -> #(Broken, [])
        _ -> #(Clean, [])
      }
    }
    jsonrpc.ServerRequest(id:, method: "textDocument/documentSymbol", ..) -> {
      let answer = Reply(fake_server.response(id, json.Array([])))
      case health {
        Clean -> #(health, [answer])
        Broken -> #(health, [
          Reply(fake_server.publish(a_uri, None, ["type mismatch"])),
          Reply(fake_server.publish(b_uri, None, ["a.oops is not a function"])),
          answer,
        ])
      }
    }
    jsonrpc.ServerRequest(..)
    | jsonrpc.Notification(..)
    | jsonrpc.Response(..) -> #(health, [])
  }
}

pub fn a_gleam_like_server_settles_on_the_barrier_and_collects_dependents_test() {
  let #(started, _fake) = started(gleam_like_capabilities(), Clean, gleam_like)
  assert client.sync(started, [client.Open(a, "gleam", "fine")]) == Ok(Nil)
  assert client.sync(started, [client.Change(a, "oops")]) == Ok(Nil)

  let assert Ok(settlement) = client.settle(started, [a], 2000)

  // Breaking a.gleam broke b.gleam, and both publications are the answer.
  assert settlement.outcome == client.Settled
  assert messages(settlement.published)
    == [#(a, ["type mismatch"]), #(b, ["a.oops is not a function"])]
  let assert Ok(stored) = client.diagnostics(started, Some(b))
  assert messages(stored) == [#(b, ["a.oops is not a function"])]
}

pub fn a_gleam_like_clean_edit_settles_with_nothing_published_test() {
  let #(started, _fake) = started(gleam_like_capabilities(), Clean, gleam_like)
  assert client.sync(started, [client.Open(a, "gleam", "fine")]) == Ok(Nil)
  assert client.sync(started, [client.Change(a, "still fine")]) == Ok(Nil)

  assert client.settle(started, [a], 2000)
    == Ok(client.Settlement(outcome: client.Settled, published: []))
}

// `gopls`, as measured: every publication is versioned, a change always
// publishes, and the publication for a change may arrive after the answer
// to the barrier. `Answering` decides whether the barrier is answered at
// all, which is how rule (a) is tested on its own.
type Answering {
  AnswersBarrier
  IgnoresBarrier
}

type Gopls {
  Gopls(answering: Answering, version: Int)
}

fn gopls_like(state: Gopls, inbound: Inbound) -> #(Gopls, List(Action)) {
  case inbound {
    jsonrpc.Notification(method: "textDocument/didOpen", params: Some(params)) -> {
      let assert json.Int(version) =
        field(field(params, "textDocument"), "version")
      #(Gopls(..state, version:), [
        Reply(fake_server.publish(a_uri, Some(version), [])),
      ])
    }
    jsonrpc.Notification(method: "textDocument/didChange", params: Some(params)) -> {
      let assert json.Int(version) =
        field(field(params, "textDocument"), "version")
      let later =
        Later(5, [
          Reply(fake_server.publish(a_uri, Some(version), ["undefined: x"])),
        ])
      case state.answering {
        AnswersBarrier -> #(Gopls(..state, version:), [])
        IgnoresBarrier -> #(Gopls(..state, version:), [later])
      }
    }
    jsonrpc.ServerRequest(id:, method: "textDocument/documentSymbol", ..) ->
      case state.answering {
        IgnoresBarrier -> #(state, [])
        AnswersBarrier -> #(state, [
          Reply(fake_server.response(id, json.Array([]))),
          Later(5, [
            Reply(
              fake_server.publish(a_uri, Some(state.version), ["undefined: x"]),
            ),
          ]),
        ])
      }
    jsonrpc.ServerRequest(..)
    | jsonrpc.Notification(..)
    | jsonrpc.Response(..) -> #(state, [])
  }
}

fn gopls_capabilities() -> JsonValue {
  advertised([
    "definitionProvider", "referencesProvider", "hoverProvider",
    "documentSymbolProvider", "renameProvider", "callHierarchyProvider",
  ])
}

pub fn a_gopls_like_server_settles_on_the_versioned_publication_test() {
  let #(started, _fake) =
    started(gopls_capabilities(), Gopls(AnswersBarrier, 0), gopls_like)
  assert client.sync(started, [client.Open(a, "go", "package a")]) == Ok(Nil)
  assert client.sync(started, [client.Change(a, "package a; var _ = x")])
    == Ok(Nil)

  // The barrier answers first; the publication for the change follows it,
  // and settling waits for it.
  let assert Ok(settlement) = client.settle(started, [a], 2000)
  assert settlement.outcome == client.Settled
  assert messages(settlement.published) == [#(a, ["undefined: x"])]
}

pub fn a_publication_without_the_barrier_does_not_settle_test() {
  let #(started, _fake) =
    started(gopls_capabilities(), Gopls(IgnoresBarrier, 0), gopls_like)
  assert client.sync(started, [client.Open(a, "go", "package a")]) == Ok(Nil)
  assert client.sync(started, [client.Change(a, "package a; var _ = x")])
    == Ok(Nil)

  // Rule (a): the new version arrived, but the barrier never answered.
  let assert Ok(settlement) = client.settle(started, [a], 60)
  assert settlement.outcome == client.DeadlineExpired
  assert messages(settlement.published) == [#(a, ["undefined: x"])]
}

pub fn a_versioned_server_that_never_publishes_the_change_does_not_settle_test() {
  let script = fn(state: Nil, inbound: Inbound) {
    case inbound {
      jsonrpc.Notification(method: "textDocument/didOpen", ..) -> #(state, [
        Reply(fake_server.publish(a_uri, Some(1), [])),
      ])
      jsonrpc.ServerRequest(id:, method: "textDocument/documentSymbol", ..) -> #(
        state,
        [Reply(fake_server.response(id, json.Array([])))],
      )
      jsonrpc.ServerRequest(..)
      | jsonrpc.Notification(..)
      | jsonrpc.Response(..) -> #(state, [])
    }
  }
  let #(started, _fake) = started(gopls_capabilities(), Nil, script)
  assert client.sync(started, [client.Open(a, "go", "package a")]) == Ok(Nil)
  assert client.sync(started, [client.Change(a, "package b")]) == Ok(Nil)

  // Rule (b): the barrier answered, but this server versions and nothing
  // at the change's version arrived.
  let assert Ok(settlement) = client.settle(started, [a], 60)
  assert settlement.outcome == client.DeadlineExpired
}

pub fn a_silent_server_ends_unsettled_and_the_barrier_is_cancelled_test() {
  let #(started, fake) = started(gleam_like_capabilities(), Nil, silent)
  assert client.sync(started, [client.Open(a, "gleam", "fine")]) == Ok(Nil)
  assert client.sync(started, [client.Change(a, "oops")]) == Ok(Nil)

  assert client.settle(started, [a], 60)
    == Ok(client.Settlement(outcome: client.DeadlineExpired, published: []))

  let assert Ok(Nil) = fake_server.await_method(fake, "$/cancelRequest")
  let assert [barrier] = requested(fake, "textDocument/documentSymbol")
  let assert jsonrpc.IdInt(barrier) = barrier
  let assert [cancel] = notified(fake, "$/cancelRequest")
  assert field(cancel, "id") == json.Int(barrier)
  assert client.open_paths(started) == Ok([a])
}

// --- stopping ---------------------------------------------------------------

pub fn stop_sends_shutdown_then_exit_then_closes_test() {
  let #(started, fake) =
    started(gleam_like_capabilities(), Nil, fn(state, inbound) {
      case inbound {
        jsonrpc.ServerRequest(id:, method: "shutdown", ..) -> #(state, [
          Reply(fake_server.response(id, json.Null)),
        ])
        jsonrpc.ServerRequest(..)
        | jsonrpc.Notification(..)
        | jsonrpc.Response(..) -> #(state, [])
      }
    })
  let monitor = process.monitor(client.pid(started))

  assert client.stop(started, 1000) == client.Graceful
  assert await_down(monitor) == process.Normal
  assert fake_server.methods(fake)
    == ["initialize", "initialized", "shutdown", "exit", "<close>"]
}

pub fn stop_closes_after_the_grace_when_shutdown_is_ignored_test() {
  let #(started, fake) = started(gleam_like_capabilities(), Nil, silent)
  let monitor = process.monitor(client.pid(started))

  assert client.stop(started, 30) == client.Forced
  assert await_down(monitor) == process.Normal
  assert fake_server.methods(fake)
    == ["initialize", "initialized", "shutdown", "exit", "<close>"]
}

pub fn stop_answers_every_waiter_before_shutting_down_test() {
  let #(started, fake) = started(gleam_like_capabilities(), Nil, silent)
  let hovering =
    in_background(fn() {
      client.hover(started, a, range.Position(0, 0), 5000)
      |> result.replace(Nil)
    })
  let assert Ok(Nil) = fake_server.await_method(fake, "textDocument/hover")

  assert client.stop(started, 30) == client.Forced
  let assert Error(client.Unavailable(_)) = answer(hovering)
}

pub fn a_dead_owner_shuts_its_client_down_test() {
  let starting = process.new_subject()
  let fake =
    fake_server.start(gleam_like_capabilities(), Nil, fn(state, inbound) {
      case inbound {
        jsonrpc.ServerRequest(id:, method: "shutdown", ..) -> #(state, [
          Reply(fake_server.response(id, json.Null)),
        ])
        jsonrpc.ServerRequest(..)
        | jsonrpc.Notification(..)
        | jsonrpc.Response(..) -> #(state, [])
      }
    })

  // The owner starts the client, then waits to be released before it
  // exits. Without the release the owner could die, and the client finish
  // its whole shutdown, before this test's monitor exists, which reads as
  // `noproc` rather than the normal exit under test. A subject is received
  // on only by the process that made it, so the owner makes its own.
  process.spawn(fn() {
    let release = process.new_subject()
    process.send(starting, #(
      client.start(fake_server.seam(fake), options()),
      release,
    ))
    let _released = process.receive(release, 3000)
    Nil
  })
  let assert Ok(#(Ok(orphan), release)) = process.receive(starting, 3000)
  let monitor = process.monitor(client.pid(orphan))

  process.send(release, Nil)

  assert await_down(monitor) == process.Normal
  assert fake_server.methods(fake)
    == ["initialize", "initialized", "shutdown", "exit", "<close>"]
}

// Keeps the helper types honest: `Close` is an action the scripts above
// only inject, never return.
pub fn a_close_from_the_script_is_the_servers_death_test() {
  let #(started, _fake) =
    started(gleam_like_capabilities(), Nil, fn(state, inbound) {
      case inbound {
        jsonrpc.ServerRequest(method: "textDocument/hover", ..) -> #(state, [
          Close("crashed mid-request"),
        ])
        jsonrpc.ServerRequest(..)
        | jsonrpc.Notification(..)
        | jsonrpc.Response(..) -> #(state, [])
      }
    })

  let assert Error(client.Unavailable(reason)) =
    client.hover(started, a, range.Position(0, 0), 1000)
  assert string.contains(reason, "crashed mid-request")
}
