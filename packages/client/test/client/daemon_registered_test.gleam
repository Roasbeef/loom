//// A session can name a workspace registered on an executor instead of a path
//// on the daemon's host (protocol-change/078). The orchestrator keeps that name
//// exactly as sent: it is never canonicalized, statted or created locally, an
//// executor the configuration does not define is refused before anything is
//// reserved, and opening such a session fails cleanly when the daemon cannot
//// reach the executor.

import client/daemon/limits
import client/daemon/manager
import client/daemon/root
import client/daemon_server_test as wire
import client/remote/workspace
import client/serve
import core/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import simplifile
import storage/catalogue
import storage/domain
import support/internal/ffi_ws
import support/remote_fixtures as fixtures
import weft/poll

// A name that is not a directory relative to the test's working directory, so
// a canonicalization of it would be refused and a stat of it would find
// nothing. It is also not an absolute path, which is how a registered name
// differs from a local workspace.
const registered_name = "registered-checkout-never-on-this-host"

fn field(value, key) {
  let assert json.Object(fields) = value as "envelope is an object"
  let assert Ok(value) = list.key_find(fields, key)
    as "expected field is present"
  value
}

// A creation naming `build-box`, with any of its fields replaced by `extra`.
// The envelope refuses a repeated key, so a replacement removes the original.
fn registered_creation(
  key: String,
  extra: List(#(String, json.JsonValue)),
) -> json.JsonValue {
  let base = [
    #("request_key", json.String(key)),
    #("workspace", json.String(registered_name)),
    #("name", json.String("Registered")),
    #("configuration", json.String("")),
    #("executor", json.String("build-box")),
  ]
  json.Object(list.append(
    extra,
    list.filter(base, fn(field) {
      !list.any(extra, fn(replacement) { replacement.0 == field.0 })
    }),
  ))
}

fn code_of(refused) -> json.JsonValue {
  assert field(refused, "event") == json.String("error")
  field(field(refused, "body"), "code")
}

fn page(ready: root.Ready(String)) {
  manager.page(ready.registry, after: "")
  |> result.map(fn(page) { page.1 })
}

pub fn a_registered_creation_keeps_its_name_and_never_reads_the_disk_test() {
  wire.fixture(fn(_, ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let created =
      wire.send(
        socket,
        1,
        "sessions.create",
        registered_creation("registered", []),
        within_ms: 1000,
      )
    assert field(created, "event") == json.String("sessions.create")
    let body = field(created, "body")
    let assert json.String(id) = field(body, "session_id")
      as "creation exposes its identity"

    // The reply carries the name verbatim and the executor beside it. A local
    // path would have been canonicalized, and a name that is no directory
    // would have been refused as an invalid workspace.
    assert field(body, "workspace") == json.String(registered_name)
    assert field(body, "executor") == json.String("build-box")
    let assert Ok(saved) = manager.get(ready.registry, id)
      as "the creation reply follows durable registration"
    assert saved.registration.workspace == registered_name
    assert saved.registration.executor == "build-box"

    // Nothing was created or remembered for the name on this host.
    assert simplifile.is_directory(registered_name) == Ok(False)
    assert simplifile.is_file(registered_name) == Ok(False)

    // A registered session is private to itself: the default scope for a
    // creation that names an executor is the session-only domain.
    let assert Ok(selected) = manager.session_domain(ready.registry, id)
    assert selected.scope == domain.SessionOnly
    assert selected.workspace == registered_name

    // The record is the same on a read by identity and in the listing, and a
    // retry under the same key is the same session.
    let read =
      wire.send(
        socket,
        2,
        "sessions.get",
        json.Object([#("session_id", json.String(id))]),
        within_ms: 1000,
      )
    assert field(field(read, "body"), "executor") == json.String("build-box")
    let listed =
      wire.send(
        socket,
        3,
        "sessions.list",
        json.Object([#("after", json.String(""))]),
        within_ms: 1000,
      )
    let assert json.Array([row]) = field(field(listed, "body"), "sessions")
      as "the one registered session is listed"
    assert field(row, "executor") == json.String("build-box")
    assert field(row, "workspace") == json.String(registered_name)
    let retried =
      wire.send(
        socket,
        4,
        "sessions.create",
        registered_creation("registered", []),
        within_ms: 1000,
      )
    assert field(field(retried, "body"), "session_id") == json.String(id)

    // The same key without the executor is a different request.
    let local =
      wire.send(
        socket,
        5,
        "sessions.create",
        json.Object([
          #("request_key", json.String("registered")),
          #("workspace", json.String(ready.state_root)),
          #("name", json.String("Registered")),
          #("configuration", json.String("")),
        ]),
        within_ms: 1000,
      )
    assert code_of(local) == json.String("conflict")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

// A creation in the `builders` pool, with any of its fields replaced by
// `extra`: the pool takes the place of the executor.
fn pooled_creation(
  key: String,
  extra: List(#(String, json.JsonValue)),
) -> json.JsonValue {
  let pool = case list.any(extra, fn(each) { each.0 == "pool" }) {
    True -> extra
    False -> [#("pool", json.String("builders")), ..extra]
  }
  registered_creation(key, pool) |> without("executor", pool)
}

// The creation with `key` removed unless `extra` sets it.
fn without(
  creation: json.JsonValue,
  key: String,
  extra: List(#(String, json.JsonValue)),
) -> json.JsonValue {
  let assert json.Object(fields) = creation
  case list.any(extra, fn(each) { each.0 == key }) {
    True -> creation
    False -> json.Object(list.filter(fields, fn(each) { each.0 != key }))
  }
}

pub fn a_pooled_creation_has_a_pool_and_no_executor_until_one_is_chosen_test() {
  wire.fixture(fn(_, ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let created =
      wire.send(
        socket,
        1,
        "sessions.create",
        pooled_creation("pooled", []),
        within_ms: 1000,
      )
    assert field(created, "event") == json.String("sessions.create")
    let body = field(created, "body")
    let assert json.String(id) = field(body, "session_id")
      as "creation exposes its identity"

    // The workspace is a name kept as sent, the pool is named and no executor
    // is, because the pool picks one when the session first opens.
    assert field(body, "workspace") == json.String(registered_name)
    assert field(body, "pool") == json.String("builders")
    let assert json.Object(fields) = body
    assert list.key_find(fields, "executor") == Error(Nil)
    let assert Ok(saved) = manager.get(ready.registry, id)
    assert saved.registration.pool == "builders"
    assert saved.registration.executor == ""
    assert simplifile.is_directory(registered_name) == Ok(False)

    // A pooled session is session-only, as a registered one is.
    let assert Ok(selected) = manager.session_domain(ready.registry, id)
    assert selected.scope == domain.SessionOnly

    // The first attach's choice reaches the listing and the read, and a retry
    // of the creation is still the same session.
    manager.seed_executor(ready.registry, id, "build-box")
    let assert poll.Answered(chosen) =
      poll.until(within: 2000, every: 1, attempt: fn() {
        case manager.get(ready.registry, id) {
          Ok(view) if view.registration.executor == "build-box" ->
            poll.Done(view)
          _ -> poll.Retry
        }
      })
      as "the registry records the chosen executor"
    assert chosen.registration.pool == "builders"
    let read =
      wire.send(
        socket,
        2,
        "sessions.get",
        json.Object([#("session_id", json.String(id))]),
        within_ms: 1000,
      )
    assert field(field(read, "body"), "executor") == json.String("build-box")
    assert field(field(read, "body"), "pool") == json.String("builders")
    let retried =
      wire.send(
        socket,
        3,
        "sessions.create",
        pooled_creation("pooled", []),
        within_ms: 1000,
      )
    assert field(field(retried, "body"), "session_id") == json.String(id)

    // The same key naming that executor is a different request.
    let named =
      wire.send(
        socket,
        4,
        "sessions.create",
        registered_creation("pooled", []),
        within_ms: 1000,
      )
    assert code_of(named) == json.String("conflict")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_pool_the_configuration_lacks_is_refused_and_stores_nothing_test() {
  wire.fixture(fn(_, ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let refused =
      wire.send(
        socket,
        1,
        "sessions.create",
        pooled_creation("unknown-pool", [#("pool", json.String("elsewhere"))]),
        within_ms: 1000,
      )
    assert code_of(refused) == json.String("pool_unknown")
    assert field(field(refused, "body"), "message")
      == json.String("no pool with that name is configured on this daemon")
    assert page(ready) == Ok([])
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_creation_names_an_executor_or_a_pool_and_never_both_test() {
  wire.fixture(fn(_, ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let cases = [
      // Both, however well formed.
      registered_creation("both", [#("pool", json.String("builders"))]),
      // A pool is a name, even an empty one or another type.
      pooled_creation("bad-1", [#("pool", json.String("Not A Name"))]),
      pooled_creation("bad-2", [#("pool", json.String(""))]),
      pooled_creation("bad-3", [#("pool", json.Int(1))]),
      pooled_creation("bad-4", [#("pool", json.Null)]),
      // A pooled workspace is a registered name, never a path or a private
      // domain.
      pooled_creation("bad-5", [#("workspace", json.String("a/b"))]),
      pooled_creation("bad-6", [
        #("domain_scope", json.String("workspace_private")),
      ]),
    ]
    list.index_map(cases, fn(creation, index) {
      let refused =
        wire.send(
          socket,
          index + 1,
          "sessions.create",
          creation,
          within_ms: 1000,
        )
      assert code_of(refused) == json.String("bad_request")
    })
    assert page(ready) == Ok([])
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_local_record_has_no_executor_member_test() {
  wire.fixture(fn(_, ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let created =
      wire.send(
        socket,
        1,
        "sessions.create",
        json.Object([
          #("request_key", json.String("local")),
          #("workspace", json.String(ready.state_root)),
          #("name", json.String("Local")),
          #("configuration", json.String("")),
        ]),
        within_ms: 1000,
      )
    let assert json.Object(fields) = field(created, "body")
    assert list.key_find(fields, "executor") == Error(Nil)
    let assert json.String(id) = field(json.Object(fields), "session_id")
    let read =
      wire.send(
        socket,
        2,
        "sessions.get",
        json.Object([#("session_id", json.String(id))]),
        within_ms: 1000,
      )
    let assert json.Object(read_fields) = field(read, "body")
    assert list.key_find(read_fields, "executor") == Error(Nil)
    let listed =
      wire.send(
        socket,
        3,
        "sessions.list",
        json.Object([#("after", json.String(""))]),
        within_ms: 1000,
      )
    let assert json.Array([json.Object(row)]) =
      field(field(listed, "body"), "sessions")
    assert list.key_find(row, "executor") == Error(Nil)
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn an_executor_the_configuration_lacks_is_refused_and_stores_nothing_test() {
  wire.fixture(fn(_, ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let refused =
      wire.send(
        socket,
        1,
        "sessions.create",
        registered_creation("unknown", [
          #("executor", json.String("elsewhere")),
        ]),
        within_ms: 1000,
      )
    assert code_of(refused) == json.String("executor_unknown")
    assert field(field(refused, "body"), "message")
      == json.String("no executor with that name is configured on this daemon")

    // No identity was reserved for the refused request.
    assert page(ready) == Ok([])
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn malformed_executor_creations_are_bad_requests_test() {
  wire.fixture(fn(_, ready, port, credential) {
    let #(socket, _) = wire.connect(port, credential, "/v2/control")
    let _hello = wire.frame(socket, within_ms: 1000)
    let cases = [
      // An executor must be a name, even an empty one or another type.
      [#("executor", json.String("Not A Name"))],
      [#("executor", json.String(""))],
      [#("executor", json.Int(1))],
      // The workspace is a registered name: no slash, no NUL, bounded.
      [#("workspace", json.String("a/b"))],
      [#("workspace", json.String("/an/absolute/path"))],
      [#("workspace", json.String("a\u{0}b"))],
      [#("workspace", json.String(string.repeat("w", 129)))],
      [#("workspace", json.String(""))],
      // The workspace aggregate is keyed by a local path and a name is none.
      [#("domain_scope", json.String("workspace_private"))],
    ]
    list.index_map(cases, fn(extra, index) {
      let refused =
        wire.send(
          socket,
          index + 1,
          "sessions.create",
          registered_creation("malformed-" <> string.inspect(index), extra),
          within_ms: 1000,
        )
      assert code_of(refused) == json.String("bad_request")
    })
    assert page(ready) == Ok([])
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn opening_a_registered_session_reports_the_executor_is_unavailable_test() {
  // The builder is the daemon's own resolver followed by its reach for the
  // executor, which a daemon that never started distribution cannot make. The
  // resolver is given a state root that does not exist, so any attempt to
  // create a directory for the session would show.
  let build = fn(record, selected, _services, _owner, _directory) {
    use _settings <- result.try(serve.resolve_managed(
      [],
      record,
      selected,
      "/never-created-state-root",
    ))
    workspace.reach(None, [], record.executor)
    |> result.map(fn(_) { record.id })
  }
  wire.fixture_building(
    limits.defaults,
    fn(_) { None },
    build,
    fn(_, ready, port, credential) {
      let #(socket, _) = wire.connect(port, credential, "/v2/control")
      let _hello = wire.frame(socket, within_ms: 1000)
      let created =
        wire.send(
          socket,
          1,
          "sessions.create",
          registered_creation("opening", []),
          within_ms: 1000,
        )
      assert field(created, "event") == json.String("sessions.create")
      let body = field(created, "body")
      let assert json.String(id) = field(body, "session_id")
      let assert json.String(operation) =
        field(field(body, "status"), "operation")
        as "creation starts one opening operation"

      // The operation fails with the reason, once the builder has run.
      let first = failed_reason(ready, id, operation)
      assert first == unreachable
      assert string.starts_with(first, "executor_unavailable: ")

      // The wire reports it the way an unavailable workspace is reported today.
      let polled =
        wire.send(
          socket,
          2,
          "operations.get",
          json.Object([
            #("session_id", json.String(id)),
            #("operation", json.String(operation)),
            #("epoch", json.String(ready.epoch)),
          ]),
          within_ms: 1000,
        )
      assert code_of(polled) == json.String("start_failed")
      assert field(field(polled, "body"), "message") == json.String(unreachable)

      // The registration never reached `saved`, because only a successful
      // assembly confirms it, so an explicit open is refused as not
      // initialized. The creation key is what retries the assembly.
      let opened =
        wire.send(
          socket,
          3,
          "sessions.open",
          json.Object([
            #("session_id", json.String(id)),
            #("epoch", json.String(ready.epoch)),
          ]),
          within_ms: 1000,
        )
      assert code_of(opened) == json.String("not_initialized")

      // Nothing on this host was created for the name or the daemon's state.
      assert simplifile.is_directory(registered_name) == Ok(False)
      assert simplifile.is_file(registered_name) == Ok(False)
      assert simplifile.is_directory("/never-created-state-root") == Ok(False)
      let _ = ffi_ws.tcp_close(socket)
      Nil
    },
  )
}

const unreachable =
  "executor_unavailable: this daemon was not started with [distribution]"

fn failed_reason(ready: root.Ready(String), id: String, operation: String) {
  let assert poll.Answered(reason) =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.operation(ready.registry, id, operation) {
        Error(manager.StartFailed(reason)) -> poll.Done(reason)
        Ok(_) -> poll.Retry
        Error(error) -> poll.Fail(error)
      }
    })
    as "the builder's refusal is recorded against the operation"
  reason
}

pub fn the_resolver_keeps_a_registered_name_and_looks_for_nothing_test() {
  // The defaults name a directory that does not exist, and the registration
  // overrides it. The name is carried as given: no helper is looked for on
  // this host, no Go cache is located for it, and nothing is created for it.
  let directory = fixtures.scratch("resolver")
  let record =
    catalogue.Registration(
      id: "unused",
      path: directory <> "/session.db",
      workspace: registered_name,
      name: "Resolver",
      configuration: "",
      profile: None,
      executor: "build-box",
      pool: "",
      created_at: 0,
      request_key: "resolver",
      state: catalogue.Reserved,
      subtitle: None,
    )
  let selected =
    domain.Domain(
      "session:unused",
      domain.SessionOnly,
      registered_name,
      "",
      directory <> "/memory/memory.db",
      directory <> "/index/search.db",
    )
  let assert Ok(settings) =
    serve.resolve_managed(
      ["--workspace", "/definitely/not/a/directory"],
      record,
      selected,
      "/never-created-state-root",
    )
    as "a registration resolves without a local workspace"
  assert settings.workspace == registered_name
  assert settings.helper_path == ""
  assert settings.go_caches == None
  assert simplifile.is_directory(registered_name) == Ok(False)
  assert simplifile.is_directory("/never-created-state-root") == Ok(False)
}
