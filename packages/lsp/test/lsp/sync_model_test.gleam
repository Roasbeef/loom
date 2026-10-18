//// A model-based test of the client's document synchronisation and of the
//// two bounded stores beside it, driven through `statem` against the same
//// in-process fake server `client_test` uses.
////
//// `client_test` pins each rule with one hand-built script: the sixty-fifth
//// open, a versioned publication, a progress token that never ends. This
//// module asks the question those scripts cannot: after any interleaving of
//// opens, changes, closes, publications and progress, does the actor still
//// hold exactly what the docs say it holds? The rules come from
//// `packages/lsp/CLAUDE.md` "Invariants" and `docs/architecture/lsp.md`
//// "Open what a query touches" and "Readiness":
////
//// - at most 64 documents are open, the least recently synced closed first
////   (`open_set`, `open_bound`), and `synced_text` is exactly the last text
////   sent (`synced_text`);
//// - document versions come from one counter shared by every document, so
////   they only rise and a reopened document never reuses one
////   (`version_monotone`, `versions`, `counter`), and the wire carries the
////   `didOpen`, `didChange` and `didClose` the model predicts, evictions
////   included (`wire`);
//// - the diagnostics store holds at most 512 URIs, the oldest publication
////   going first, and at most 200 diagnostics per publication
////   (`published_bound`, `per_uri_bound`, `published_store`,
////   `published_for`); a publication for a URI that is not a local file is
////   dropped;
//// - at most 64 work-done progress tokens are held, the earliest begun
////   evicted first, a `report` for an unknown token adds it under the
////   token's own text, and an `end` for an unknown one does nothing
////   (`progress_bound`, `progress_set`).
////
//// ## The shape of the spec
////
//// The oracle lives in the system under test and the model stays a plain
//// description of what should be held: the open documents oldest synced
//// first with their versions and texts, the next version, the publications
//// oldest first and the active tokens oldest first. `advance` is the one
//// pure function that moves the model and names the wire events a command
//// must produce, so `next_model` and `execute` cannot disagree about what a
//// command means. The model orders documents by recency of sync itself and
//// never reads a version to decide an eviction, which keeps it independent
//// of the client's own "smallest version is the oldest" shortcut.
////
//// The bounds are literals in this file, not `client.max_open_documents`
//// and its siblings: a test that read the constant back from the code under
//// test would pass when someone lowered the constant.
////
//// ## Ordering without sleeping
////
//// The fake's `test/emit` request, the pattern `client_test`'s readiness
//// tests use, sends the notifications its params carry and only then answers.
//// Everything the client was handed before the answer has been handled when
//// the call returns, and the client's own writes reach the fake before that
//// request does, so one call is a barrier for both directions and the test
//// needs no poll.
////
//// ## What shrinks
////
//// Documents, publication targets and tokens are named by an index into a
//// fixed pool, so deleting an earlier command never invalidates a later one.
//// A run command (`OpenRun`, `PublishRun`, `BeginRun`) is how a sequence
//// crosses a bound without a hundred generated commands; it shrinks toward
//// fewer items. Each invariant has its own violation tag, so a shrink stays
//// on the rule that broke.

import core/json.{type JsonValue}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lsp/client
import lsp/jsonrpc
import lsp/protocol
import qcheck
import statem
import support/fake_server.{type Fake}

// --- configuration ----------------------------------------------------------

/// The seed every run of this test derives from. Fixed so a red gate is the
/// same red gate everywhere.
const seed = 25

/// How many command lists one check runs. Each builds a client and a fake,
/// so the cost is a process pair per list; the lists cross the bounds often
/// enough (`generator_reaches_every_bound_test` asserts it) that sixty is
/// enough to cover them.
const test_count = 60

/// The longest command list. Greedy shrinking costs about the square of this
/// in executions, and a run command already crosses a bound in one step.
const max_commands = 22

/// The shrink budget, in executions. A failing list reduces to a handful of
/// commands well inside it.
const max_shrinks = 400

/// The bound on open documents, from `CLAUDE.md`: "At most 64 documents are
/// open".
const open_bound = 64

/// The bound on stored URIs: "512 URIs (the oldest publication goes first)".
const published_bound = 512

/// The bound on diagnostics kept per publication: "200 diagnostics per
/// publication".
const per_uri_bound = 200

/// The bound on held progress tokens: "At most `max_progress_tokens` (64)".
const progress_bound = 64

/// Documents the commands can name. Larger than `open_bound` so a run of
/// opens can overflow it and reopen what it evicted.
const document_pool = 80

/// Publication targets the commands can name. Larger than `published_bound`.
const uri_pool = 600

/// Progress tokens the commands can name. Larger than `progress_bound`.
const token_pool = 100

/// The URIs one `PublishRun` publishes about, and the tokens one `BeginRun`
/// begins. Two runs with distinct starts cross the stores' bounds.
const run_publications = 340

const run_tokens = 50

fn config() -> statem.Config {
  statem.default_config(seed:)
  |> statem.with_test_count(test_count)
  |> statem.with_max_commands(max_commands)
  |> statem.with_max_shrinks(max_shrinks)
}

// --- commands and model -----------------------------------------------------

/// One document operation inside a `Sync`, naming a document by pool index
/// and its text by a small number.
type Step {
  OpenDoc(doc: Int, text: Int)
  ChangeDoc(doc: Int, text: Int)
  CloseDoc(doc: Int)
}

/// One thing that happens to the client.
type Command {
  /// A short batch of document operations in one `client.sync`.
  Sync(steps: List(Step))

  /// Opens `count` consecutive documents from `first`, wrapping the pool:
  /// the way a sequence reaches the sixty-fifth.
  OpenRun(first: Int, count: Int)

  /// The server publishes `diagnostics` messages about one URI.
  Publish(target: Int, diagnostics: Int, version: Option(Int))

  /// The server publishes one diagnostic about each of `run_publications`
  /// URIs from `first`.
  PublishRun(first: Int)

  /// The server publishes about a URI that is not a local file.
  PublishRemote

  /// A work-done `begin`, `report` or `end` for one token.
  Begin(token: Int, title: Int)
  Report(token: Int)
  End(token: Int)

  /// Begins `run_tokens` distinct tokens from `first`.
  BeginRun(first: Int)
}

/// One open document as the model remembers it.
type Doc {
  Doc(doc: Int, version: Int, text: String)
}

/// One stored publication: its target and the messages it carried, already
/// cut to the per-publication bound.
type Publication {
  Publication(target: Int, messages: List(String))
}

/// One held progress token and its title.
type Work {
  Work(token: Int, title: String)
}

/// What the client should hold. Documents, publications and tokens are all
/// oldest first.
type Model {
  Model(
    docs: List(Doc),
    next_version: Int,
    publications: List(Publication),
    works: List(Work),
  )
}

/// A `didOpen`, `didChange` or `didClose` as it appears on the wire. The
/// model predicts these and the fake's log supplies them, so the two are
/// compared as values.
type Wire {
  Opened(uri: String, version: Int, text: String)
  Changed(uri: String, version: Int, text: String)
  Closed(uri: String)
}

/// The system under test: the client, the fake it talks to, and every wire
/// event the model has predicted so far.
type Sut {
  Sut(client: client.Client, fake: Fake(Nil), expected: List(Wire))
}

fn initial() -> Model {
  Model(docs: [], next_version: 1, publications: [], works: [])
}

// --- paths and notifications ------------------------------------------------

fn doc_path(doc: Int) -> String {
  "/work/src/d" <> int.to_string(doc) <> ".gleam"
}

fn doc_uri(doc: Int) -> String {
  "file://" <> doc_path(doc)
}

fn target_path(target: Int) -> String {
  "/work/src/p" <> int.to_string(target) <> ".gleam"
}

fn text_of(text: Int) -> String {
  "text-" <> int.to_string(text)
}

// Even tokens are integers on the wire and odd ones strings, so both
// `ProgressToken` shapes are exercised.
fn token_json(token: Int) -> JsonValue {
  case int.is_even(token) {
    True -> json.Int(token)
    False -> json.String(token_text(token))
  }
}

// The text the client falls back to for a token no `begin` named: an
// integer token's digits, a string token itself.
fn token_text(token: Int) -> String {
  case int.is_even(token) {
    True -> int.to_string(token)
    False -> "t" <> int.to_string(token)
  }
}

fn title_of(title: Int) -> String {
  "work-" <> int.to_string(title)
}

fn progress_notification(
  token: Int,
  value: List(#(String, JsonValue)),
) -> JsonValue {
  jsonrpc.notification(
    "$/progress",
    Some(
      json.Object([
        #("token", token_json(token)),
        #("value", json.Object(value)),
      ]),
    ),
  )
}

fn begin_notification(token: Int, title: String) -> JsonValue {
  progress_notification(token, [
    #("kind", json.String("begin")),
    #("title", json.String(title)),
  ])
}

fn messages_of(count: Int) -> List(String) {
  list.map(int.range(from: 0, to: count, with: [], run: list.prepend), fn(n) {
    "m" <> int.to_string(n)
  })
  |> list.reverse
}

fn publish_notification(
  uri: String,
  version: Option(Int),
  count: Int,
) -> JsonValue {
  fake_server.publish(uri, version, messages_of(count))
}

// --- the model's transitions ------------------------------------------------

// The one definition of what a command means: the model after it, and the
// wire events it must cause. `next_model` takes the first and `execute` the
// second, so the two cannot drift.
fn advance(model: Model, command: Command) -> #(Model, List(Wire)) {
  case command {
    Sync(steps:) -> list.fold(steps, #(model, []), apply_step)
    OpenRun(first:, count:) ->
      run_indices(first, count, document_pool)
      |> list.map(fn(doc) { OpenDoc(doc, doc) })
      |> list.fold(#(model, []), apply_step)
    Publish(target:, diagnostics:, version: _) -> #(
      publish(model, target, messages_of(diagnostics)),
      [],
    )
    PublishRun(first:) -> #(
      list.fold(
        run_indices(first, run_publications, uri_pool),
        model,
        fn(model, target) { publish(model, target, ["m0"]) },
      ),
      [],
    )
    PublishRemote -> #(model, [])
    Begin(token:, title:) -> #(begin(model, token, title_of(title)), [])
    Report(token:) -> #(report(model, token), [])
    End(token:) -> #(end(model, token), [])
    BeginRun(first:) -> #(
      list.fold(run_indices(first, run_tokens, token_pool), model, fn(model, t) {
        begin(model, t, title_of(t))
      }),
      [],
    )
  }
}

fn run_indices(first: Int, count: Int, pool: Int) -> List(Int) {
  list.map(int.range(from: 0, to: count, with: [], run: list.prepend), fn(n) {
    { first + n } % pool
  })
  |> list.reverse
}

// One document operation. A sync of a document already held moves it to the
// newest position; one the client does not hold opens it, closing the
// oldest first when the bound is full. The order of the list, not a
// version, decides who is oldest.
fn apply_step(state: #(Model, List(Wire)), step: Step) -> #(Model, List(Wire)) {
  let #(model, wire) = state
  case step {
    OpenDoc(doc:, text:) | ChangeDoc(doc:, text:) -> {
      let #(model, events) = put(model, doc, text_of(text))
      #(model, list.append(wire, events))
    }
    CloseDoc(doc:) -> {
      let held = list.any(model.docs, fn(d) { d.doc == doc })
      case held {
        False -> state
        True -> #(
          Model(..model, docs: list.filter(model.docs, fn(d) { d.doc != doc })),
          list.append(wire, [Closed(doc_uri(doc))]),
        )
      }
    }
  }
}

fn put(model: Model, doc: Int, text: String) -> #(Model, List(Wire)) {
  let version = model.next_version
  let held = list.any(model.docs, fn(d) { d.doc == doc })
  let #(kept, evicted) = case held {
    True -> #(list.filter(model.docs, fn(d) { d.doc != doc }), [])
    False -> make_room(model.docs)
  }
  let event = case held {
    True -> Changed(doc_uri(doc), version, text)
    False -> Opened(doc_uri(doc), version, text)
  }
  let docs = list.append(kept, [Doc(doc:, version:, text:)])
  #(
    Model(..model, docs:, next_version: version + 1),
    list.append(evicted, [event]),
  )
}

// Under the bound there is room; at it the oldest synced document is closed.
fn make_room(docs: List(Doc)) -> #(List(Doc), List(Wire)) {
  case list.length(docs) >= open_bound, docs {
    True, [oldest, ..rest] -> #(rest, [Closed(doc_uri(oldest.doc))])
    True, [] | False, _ -> #(docs, [])
  }
}

// A publication replaces any earlier one for its target and becomes the
// newest. A new target past the bound pushes the oldest out.
fn publish(model: Model, target: Int, messages: List(String)) -> Model {
  let known = list.any(model.publications, fn(p) { p.target == target })
  let others = list.filter(model.publications, fn(p) { p.target != target })
  let kept = case known || list.length(others) < published_bound {
    True -> others
    False -> list.drop(others, 1)
  }
  let stored =
    Publication(target:, messages: list.take(messages, per_uri_bound))
  Model(..model, publications: list.append(kept, [stored]))
}

// A `begin` for a held token retitles it and keeps its place; a new one is
// appended, evicting the earliest begun at the bound.
fn begin(model: Model, token: Int, title: String) -> Model {
  case list.any(model.works, fn(w) { w.token == token }) {
    True ->
      Model(
        ..model,
        works: list.map(model.works, fn(w) {
          case w.token == token {
            True -> Work(..w, title:)
            False -> w
          }
        }),
      )
    False -> add_work(model, token, title)
  }
}

// A `report` for a token never begun adds it under its own text; for a held
// token it changes nothing.
fn report(model: Model, token: Int) -> Model {
  case list.any(model.works, fn(w) { w.token == token }) {
    True -> model
    False -> add_work(model, token, token_text(token))
  }
}

fn end(model: Model, token: Int) -> Model {
  Model(..model, works: list.filter(model.works, fn(w) { w.token != token }))
}

fn add_work(model: Model, token: Int, title: String) -> Model {
  let room = case list.length(model.works) >= progress_bound {
    True -> list.drop(model.works, 1)
    False -> model.works
  }
  Model(..model, works: list.append(room, [Work(token:, title:)]))
}

// --- generators -------------------------------------------------------------

fn pick(pool: Int) -> qcheck.Generator(Int) {
  qcheck.bounded_int(from: 0, to: pool - 1)
}

fn step_generator() -> qcheck.Generator(Step) {
  let doc = pick(document_pool)
  let text = qcheck.bounded_int(from: 0, to: 9)
  qcheck.from_weighted_generators(#(3, qcheck.map2(doc, text, OpenDoc)), [
    #(4, qcheck.map2(doc, text, ChangeDoc)),
    #(2, qcheck.map(doc, CloseDoc)),
  ])
}

fn diagnostic_count() -> qcheck.Generator(Int) {
  qcheck.from_weighted_generators(#(6, qcheck.bounded_int(from: 0, to: 3)), [
    #(1, qcheck.bounded_int(from: 190, to: 260)),
  ])
}

// Half of the runs are short, so a few documents are opened and reopened;
// the rest are just over the bound, so the sixty-fifth open is common.
fn run_length() -> qcheck.Generator(Int) {
  qcheck.from_weighted_generators(#(1, qcheck.bounded_int(from: 1, to: 30)), [
    #(1, qcheck.bounded_int(from: 60, to: 70)),
  ])
}

// Short syncs and publications dominate, so ordinary interleavings are the
// bulk; each run command is rare enough that most lists cross a bound once
// or twice rather than on every step.
fn command_generator(_model: Model) -> qcheck.Generator(Command) {
  let steps =
    qcheck.generic_list(
      elements_from: step_generator(),
      length_from: qcheck.bounded_int(from: 1, to: 3),
    )
  let token = pick(token_pool)
  qcheck.from_weighted_generators(#(8, qcheck.map(steps, Sync)), [
    #(2, qcheck.map2(pick(document_pool), run_length(), OpenRun)),
    #(
      4,
      qcheck.map3(
        pick(uri_pool),
        diagnostic_count(),
        qcheck.option_from(qcheck.bounded_int(from: 1, to: 50)),
        Publish,
      ),
    ),
    #(2, qcheck.map(pick(uri_pool), PublishRun)),
    #(1, qcheck.return(PublishRemote)),
    #(4, qcheck.map2(token, qcheck.bounded_int(from: 0, to: 5), Begin)),
    #(2, qcheck.map(token, Report)),
    #(3, qcheck.map(token, End)),
    #(2, qcheck.map(pick(token_pool), BeginRun)),
  ])
}

// --- the system under test --------------------------------------------------

// The fake answers `test/emit` with `null` after sending the notifications
// its params list: the barrier described in the module doc. It also answers
// `shutdown`, so `teardown`'s stop is graceful at once instead of waiting out
// its grace period for a reply that never comes.
fn emitter(
  state: Nil,
  inbound: jsonrpc.Inbound,
) -> #(Nil, List(fake_server.Action)) {
  case inbound {
    jsonrpc.ServerRequest(
      id:,
      method: "test/emit",
      params: Some(json.Array(sent)),
    ) -> #(
      state,
      list.append(list.map(sent, fake_server.Reply), [
        fake_server.Reply(fake_server.response(id, json.Null)),
      ]),
    )
    jsonrpc.ServerRequest(id:, method: "shutdown", ..) -> #(state, [
      fake_server.Reply(fake_server.response(id, json.Null)),
    ])
    jsonrpc.ServerRequest(..)
    | jsonrpc.Notification(..)
    | jsonrpc.Response(..) -> #(state, [])
  }
}

fn new_sut() -> Sut {
  let capabilities =
    json.Object([
      #("hoverProvider", json.Bool(True)),
      #("textDocumentSync", json.Int(1)),
    ])
  let fake = fake_server.start(capabilities, Nil, emitter)
  let options =
    client.options(server: "fake", root: "/work", language_id: "gleam")
  let assert Ok(started) = client.start(fake_server.seam(fake), options)
    as "the scripted handshake should succeed"
  Sut(client: started, fake:, expected: [])
}

fn teardown(sut: Sut) -> Nil {
  client.stop(sut.client, 1000)
  Nil
}

// Hands the client `notifications` and returns once it has handled them and
// everything it wrote earlier has reached the fake.
fn emit(
  started: client.Client,
  notifications: List(JsonValue),
) -> Result(Nil, statem.Violation) {
  client.request(
    started,
    protocol.HoverFeature,
    "test/emit",
    Some(json.Array(notifications)),
    5000,
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) {
    statem.Violation(
      "barrier",
      "the emit request failed: " <> string.inspect(error),
    )
  })
}

fn to_op(step: Step) -> client.DocOp {
  case step {
    OpenDoc(doc:, text:) -> client.Open(doc_path(doc), "gleam", text_of(text))
    ChangeDoc(doc:, text:) -> client.Change(doc_path(doc), text_of(text))
    CloseDoc(doc:) -> client.Close(doc_path(doc))
  }
}

// What the command does to the client: syncs through the public API, and
// notifications through the barrier request.
fn perform(
  started: client.Client,
  command: Command,
) -> Result(Nil, statem.Violation) {
  case command {
    Sync(steps:) -> sync(started, list.map(steps, to_op))
    OpenRun(first:, count:) ->
      run_indices(first, count, document_pool)
      |> list.map(fn(doc) { client.Open(doc_path(doc), "gleam", text_of(doc)) })
      |> sync(started, _)
    Publish(target:, diagnostics:, version:) ->
      emit(started, [
        publish_notification(
          "file://" <> target_path(target),
          version,
          diagnostics,
        ),
      ])
    PublishRun(first:) ->
      run_indices(first, run_publications, uri_pool)
      |> list.map(fn(target) {
        publish_notification("file://" <> target_path(target), None, 1)
      })
      |> emit(started, _)
    PublishRemote ->
      emit(started, [
        publish_notification("http://example.invalid/remote.gleam", None, 2),
      ])
    Begin(token:, title:) ->
      emit(started, [begin_notification(token, title_of(title))])
    Report(token:) ->
      emit(started, [
        progress_notification(token, [#("kind", json.String("report"))]),
      ])
    End(token:) ->
      emit(started, [
        progress_notification(token, [#("kind", json.String("end"))]),
      ])
    BeginRun(first:) ->
      run_indices(first, run_tokens, token_pool)
      |> list.map(fn(token) { begin_notification(token, title_of(token)) })
      |> emit(started, _)
  }
}

// A sync is followed by an empty barrier so the fake's log holds every
// notification it wrote before anyone reads the log.
fn sync(
  started: client.Client,
  ops: List(client.DocOp),
) -> Result(Nil, statem.Violation) {
  use Nil <- result.try(
    client.sync(started, ops)
    |> result.map_error(fn(error) {
      statem.Violation("sync", "sync was refused: " <> string.inspect(error))
    }),
  )
  emit(started, [])
}

// --- reading the wire --------------------------------------------------------

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

fn text_field(value: JsonValue, key: String) -> String {
  case field(value, key) {
    json.String(text) -> text
    json.Array(..)
    | json.Object(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> ""
  }
}

fn int_field(value: JsonValue, key: String) -> Int {
  case field(value, key) {
    json.Int(number) -> number
    json.Array(..)
    | json.Object(..)
    | json.String(..)
    | json.Float(..)
    | json.Bool(..)
    | json.Null -> -1
  }
}

// Every document notification the client has written, oldest first, read
// back from the fake's log.
fn wire_log(fake: Fake(Nil)) -> List(Wire) {
  list.filter_map(fake_server.seen(fake), fn(entry) {
    case entry {
      fake_server.Got(jsonrpc.Notification(method:, params: Some(params))) ->
        wire_event(method, field(params, "textDocument"), params)
      fake_server.Got(..) | fake_server.GotClose -> Error(Nil)
    }
  })
}

fn wire_event(
  method: String,
  document: JsonValue,
  params: JsonValue,
) -> Result(Wire, Nil) {
  let uri = text_field(document, "uri")
  let version = int_field(document, "version")
  case method {
    "textDocument/didOpen" ->
      Ok(Opened(uri, version, text_field(document, "text")))
    "textDocument/didChange" ->
      case field(params, "contentChanges") {
        json.Array([change, ..]) ->
          Ok(Changed(uri, version, text_field(change, "text")))
        json.Array([])
        | json.Object(..)
        | json.String(..)
        | json.Int(..)
        | json.Float(..)
        | json.Bool(..)
        | json.Null -> Error(Nil)
      }
    "textDocument/didClose" -> Ok(Closed(uri))
    _ -> Error(Nil)
  }
}

// --- the invariants ----------------------------------------------------------

// A violation's detail cuts each side to a readable length: a full store or
// wire log is hundreds of entries, and the shrunk list, not the dump, is
// what a reader reaches for.
fn shown(value: a) -> String {
  let text = string.inspect(value)
  case string.length(text) > 500 {
    True -> string.slice(text, 0, 500) <> "..."
    False -> text
  }
}

fn fail(tag: String, expected: a, actual: a) -> Result(Nil, statem.Violation) {
  Error(statem.Violation(
    tag,
    "expected " <> shown(expected) <> ", got " <> shown(actual),
  ))
}

fn require(
  tag: String,
  expected: a,
  actual: Result(a, client.RequestError),
) -> Result(Nil, statem.Violation) {
  case actual {
    Ok(value) if value == expected -> Ok(Nil)
    Ok(value) -> fail(tag, expected, value)
    Error(error) ->
      Error(statem.Violation(tag, "the read failed: " <> string.inspect(error)))
  }
}

fn execute(
  sut: Sut,
  model: Model,
  command: Command,
) -> Result(Sut, statem.Violation) {
  let #(after, wire) = advance(model, command)
  let expected = list.append(sut.expected, wire)
  use Nil <- result.try(perform(sut.client, command))
  use Nil <- result.try(check_wire(sut.fake, expected))
  use Nil <- result.try(check_documents(sut.client, after))
  use Nil <- result.try(check_publications(sut.client, after, command))
  use Nil <- result.try(check_progress(sut.client, after))
  Ok(Sut(..sut, expected:))
}

// Versions on the wire only rise, whichever documents carry them; then the
// whole log, evictions and all, is what the model predicted.
fn check_wire(
  fake: Fake(Nil),
  expected: List(Wire),
) -> Result(Nil, statem.Violation) {
  let log = wire_log(fake)
  let versions =
    list.filter_map(log, fn(event) {
      case event {
        Opened(version:, ..) | Changed(version:, ..) -> Ok(version)
        Closed(..) -> Error(Nil)
      }
    })
  case versions == list.sort(list.unique(versions), int.compare) {
    False ->
      Error(statem.Violation(
        "version_monotone",
        "versions on the wire are not strictly rising: "
          <> string.inspect(versions),
      ))
    True ->
      case log == expected {
        True -> Ok(Nil)
        False -> fail("wire", expected, log)
      }
  }
}

fn check_documents(
  started: client.Client,
  model: Model,
) -> Result(Nil, statem.Violation) {
  let paths =
    list.map(model.docs, fn(d) { doc_path(d.doc) }) |> list.sort(string.compare)
  use open <- result.try(
    client.open_paths(started)
    |> result.map_error(fn(error) {
      statem.Violation("open_set", string.inspect(error))
    }),
  )
  case list.length(open) > open_bound {
    True -> fail("open_bound", open_bound, list.length(open))
    False -> {
      use Nil <- result.try(require("open_set", paths, Ok(open)))
      use Nil <- result.try(check_texts(started, model))
      check_observation(started, model)
    }
  }
}

// `synced_text` is the last text sent for every document, and `None` for
// every one the client no longer holds.
fn check_texts(
  started: client.Client,
  model: Model,
) -> Result(Nil, statem.Violation) {
  list.try_each(
    int.range(from: 0, to: document_pool, with: [], run: list.prepend),
    fn(doc) {
      let text =
        list.find(model.docs, fn(d) { d.doc == doc })
        |> result.map(fn(d) { d.text })
        |> option.from_result
      require("synced_text", text, client.synced_text(started, doc_path(doc)))
    },
  )
}

// One read of the actor's own books: the shared counter, and each document's
// version, which must be the one the model handed out at its last sync.
fn check_observation(
  started: client.Client,
  model: Model,
) -> Result(Nil, statem.Violation) {
  use observed <- result.try(
    client.observation_state(started, 1000)
    |> result.map_error(fn(error) {
      statem.Violation("counter", string.inspect(error))
    }),
  )
  let held =
    list.map(observed.documents, fn(d) { #(d.path, d.version, d.text) })
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  let wanted =
    list.map(model.docs, fn(d) { #(doc_path(d.doc), d.version, d.text) })
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  case observed.revision == model.next_version {
    False -> fail("counter", model.next_version, observed.revision)
    True ->
      case held == wanted {
        True -> Ok(Nil)
        False -> fail("versions", wanted, held)
      }
  }
}

// The store is bounded in URIs and in diagnostics per URI, holds exactly the
// newest publications, and answers a single path with that path's entry.
fn check_publications(
  started: client.Client,
  model: Model,
  command: Command,
) -> Result(Nil, statem.Violation) {
  use stored <- result.try(
    client.diagnostics(started, None)
    |> result.map_error(fn(error) {
      statem.Violation("published_store", string.inspect(error))
    }),
  )
  let held =
    list.map(stored, fn(entry) {
      #(
        entry.0,
        list.map(entry.1, fn(d: protocol.ServerDiagnostic) { d.message }),
      )
    })
  let widest =
    list.fold(held, 0, fn(widest, entry) {
      int.max(widest, list.length(entry.1))
    })
  let wanted =
    list.map(model.publications, fn(p) { #(target_path(p.target), p.messages) })
    |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  case list.length(held) > published_bound, widest > per_uri_bound {
    True, _ -> fail("published_bound", published_bound, list.length(held))
    False, True -> fail("per_uri_bound", per_uri_bound, widest)
    False, False ->
      case held == wanted {
        False -> fail("published_store", wanted, held)
        True -> check_published_for(started, wanted, command)
      }
  }
}

fn check_published_for(
  started: client.Client,
  wanted: List(#(String, List(String))),
  command: Command,
) -> Result(Nil, statem.Violation) {
  case command {
    Publish(target:, ..) -> {
      let path = target_path(target)
      let entry = list.filter(wanted, fn(entry) { entry.0 == path })
      use one <- result.try(
        client.diagnostics(started, Some(path))
        |> result.map_error(fn(error) {
          statem.Violation("published_for", string.inspect(error))
        }),
      )
      let one =
        list.map(one, fn(e) {
          #(e.0, list.map(e.1, fn(d: protocol.ServerDiagnostic) { d.message }))
        })
      case one == entry {
        True -> Ok(Nil)
        False -> fail("published_for", entry, one)
      }
    }
    Sync(..)
    | OpenRun(..)
    | PublishRun(..)
    | PublishRemote
    | Begin(..)
    | Report(..)
    | End(..)
    | BeginRun(..) -> Ok(Nil)
  }
}

// The active titles are the model's, in any order (the client reads them
// from a dictionary), and never more than the bound.
fn check_progress(
  started: client.Client,
  model: Model,
) -> Result(Nil, statem.Violation) {
  use observed <- result.try(
    client.observation_state(started, 1000)
    |> result.map_error(fn(error) {
      statem.Violation("progress_set", string.inspect(error))
    }),
  )
  let held = list.sort(observed.busy, string.compare)
  let wanted =
    list.map(model.works, fn(w) { w.title }) |> list.sort(string.compare)
  case list.length(held) > progress_bound {
    True -> fail("progress_bound", progress_bound, list.length(held))
    False ->
      case held == wanted {
        True -> Ok(Nil)
        False -> fail("progress_set", wanted, held)
      }
  }
}

// --- the tests ----------------------------------------------------------------

fn spec() -> statem.Spec(Model, Command, Sut) {
  statem.Spec(
    initial: initial(),
    command: command_generator,
    precondition: fn(_, _) { statem.Admit },
    next_model: fn(model, command) { advance(model, command).0 },
    new_sut:,
    execute:,
    finish: fn(_, _) { Ok(Nil) },
    teardown:,
  )
}

fn describe(command: Command) -> String {
  string.inspect(command)
}

pub fn sync_and_the_bounded_stores_match_their_model_test() {
  case statem.check(spec(), config()) {
    Ok(Nil) -> Nil
    Error(failure) -> panic as statem.report(failure, describe)
  }
}

/// The generator is only worth its name if the lists it draws reach the
/// bounds: some list evicts a document, some fills the diagnostics store, and
/// some fills the progress set. Read from the models, with nothing executed.
pub fn generator_reaches_every_bound_test() {
  let models =
    list.map(
      int.range(from: 0, to: test_count, with: [], run: list.prepend),
      fn(run) {
        statem.commands(spec(), config(), run)
        |> list.fold(initial(), fn(model, command) { advance(model, command).0 })
      },
    )
  let most = fn(measure: fn(Model) -> Int) {
    list.fold(models, 0, fn(most, model) { int.max(most, measure(model)) })
  }
  assert most(fn(m) { list.length(m.docs) }) == open_bound
  assert most(fn(m) { list.length(m.publications) }) == published_bound
  assert most(fn(m) { list.length(m.works) }) == progress_bound
  assert most(fn(m) { m.next_version }) > 2 * open_bound
}
