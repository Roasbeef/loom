//// `executors.reload` across the real control socket (protocol-change/115).
////
//// The registry behind the command is real, with fake links that only hold a
//// link's registered name, so the tests prove what the socket and the daemon's
//// reading of the file do: an owner is answered with the documented body, a
//// member is refused, a file that a start would refuse changes nothing (the
//// links' processes are the same afterwards), a new `[executor_link]` outside
//// the two vm directories is refused, and a daemon with no configuration file
//// says so.

import client/daemon/limits
import client/daemon/main
import client/daemon/untrusted_links
import client/daemon_server_test as wire
import client/deployment
import client/executors
import client/internal/ffi_os
import client/internal/ffi_tls_stream
import client/remote/untrusted_link
import client/session_directory
import client/session_movers
import core/json
import gleam/bit_array
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import storage/access
import storage/catalogue
import telemetry/log

const pin = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

fn field(value, key) {
  let assert json.Object(fields) = value as "envelope is an object"
  let assert Ok(value) = list.key_find(fields, key)
    as "expected field is present"
  value
}

// A link that holds the registered name and waits, as a started link does.
fn hold(name: String) -> Result(Pid, String) {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let assert Ok(Nil) =
        process.register(process.self(), untrusted_link.name_for(name))
        as "the name is free"
      process.send(ready, Nil)
      process.sleep_forever()
    })
  process.receive(ready, 1000)
  |> result.replace(pid)
  |> result.replace_error("the holder did not register")
}

fn links() -> untrusted_links.Links {
  untrusted_links.Links(
    start: fn(row, _credentials) { hold(row.name) },
    holder: fn(name) { process.named(untrusted_link.name_for(name)) },
  )
}

fn unique(label: String) -> String {
  label <> "-" <> int.to_string(ffi_os.unique_positive_integer())
}

// A scratch state directory, with its `vm` directory and a link table's three
// files in it, made as `loom vm up` makes them.
fn state_with_link() -> String {
  let state = "build/test_db/" <> unique("reload-state")
  let assert Ok(Nil) = bootstrap.ensure_private_directory(state)
    as "the state directory exists"
  let assert Ok(absolute) = bootstrap.absolute_path(state)
    as "the state directory resolves"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(absolute <> "/vm")
    as "the vm directory exists"
  list.each(["ca.pem", "c.pem", "k.pem"], fn(file) {
    let assert Ok(Nil) = simplifile.write(absolute <> "/vm/" <> file, "x")
      as "a credential file is written"
  })
  absolute
}

fn link_table(directory: String) -> String {
  "[executor_link]\nca = \""
  <> directory
  <> "/ca.pem\"\ncertificate = \""
  <> directory
  <> "/c.pem\"\nkey = \""
  <> directory
  <> "/k.pem\"\n"
}

fn rows_text(rows: List(#(String, Int))) -> String {
  string.join(
    list.map(rows, fn(row) {
      "[executors."
      <> row.0
      <> "]\ntrust = \"untrusted\"\naddress = \"127.0.0.1:"
      <> int.to_string(row.1)
      <> "\"\npin = \""
      <> pin
      <> "\"\n"
    }),
    "",
  )
}

fn untrusted(name: String, port: Int) -> executors.Executor {
  executors.Executor(
    ..executors.plain(name, ""),
    trust: executors.Untrusted(host: "127.0.0.1", port:, pin: <<1>>),
  )
}

// A daemon whose capability is `main.executors_reload_for` over `file`, with a
// registry that holds the fake links. The daemon started with no
// `[executor_link]`, and its state root is `state`.
fn reloading(
  state: String,
  file: option.Option(String),
  run: fn(Int, String, untrusted_links.Registry, String) -> Nil,
) {
  let assert Ok(registry) = untrusted_links.start(links(), log.discard())
    as "the registry starts"
  let assert Ok(parsed) = main.parse(["--state-dir", state])
    as "the flags parse"
  let config = main.Config(..parsed, links: Some(registry))
  let capability = case file {
    Some(path) -> main.executors_reload_for(config, path)
    None -> None
  }
  wire.fixture_with_reload(
    limits.defaults,
    fn(_) { None },
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    session_directory.none(),
    session_movers.idle(),
    deployment.alone("nonode@nohost"),
    None,
    capability,
    fn(_daemon, ready, port, credential) {
      run(port, credential, registry, ready.state_root)
    },
  )
}

fn ask(socket, id) {
  wire.send(socket, id, "executors.reload", json.Object([]), within_ms: 6000)
}

fn open(port, credential) {
  let #(socket, _) = wire.connect(port, credential, "/v2/control")
  let _hello = wire.frame(socket, within_ms: 1000)
  socket
}

fn changes(reply) -> List(#(String, String)) {
  assert field(reply, "event") == json.String("executors.reload")
  let assert json.Object(body) = field(reply, "body") as "the body is an object"
  let assert Ok(json.Array(entries)) = list.key_find(body, "executors")
    as "the body lists the executors"
  list.map(entries, fn(entry) {
    let assert json.String(name) = field(entry, "name") as "a name"
    let assert json.String(change) = field(entry, "change") as "a change"
    #(name, change)
  })
}

pub fn the_owner_is_answered_with_what_changed_test() {
  let state = state_with_link()
  let first = unique("reload-a")
  let second = unique("reload-b")
  let path = state <> "/loom.toml"
  let table = link_table(state <> "/vm")
  let assert Ok(Nil) =
    simplifile.write(path, table <> rows_text([#(first, 7000)]))
    as "the file is written"

  reloading(state, Some(path), fn(port, credential, registry, _state_root) {
    let socket = open(port, credential)
    assert changes(ask(socket, 1)) == [#(first, "started")]
    let assert Ok(before) = process.named(untrusted_link.name_for(first))
      as "the first link holds its name"

    let assert Ok(Nil) =
      simplifile.write(
        path,
        table <> rows_text([#(first, 7000), #(second, 7001)]),
      )
      as "the file gains a row"
    assert changes(ask(socket, 2))
      == list.sort([#(first, "unchanged"), #(second, "started")], fn(a, b) {
        string.compare(a.0, b.0)
      })
    assert process.named(untrusted_link.name_for(first)) == Ok(before)
    assert list.length(untrusted_links.rows(registry)) == 2
  })
}

pub fn a_member_is_refused_test() {
  let state = state_with_link()
  let path = state <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(path, "") as "the file is written"

  reloading(state, Some(path), fn(port, _credential, _registry, state_root) {
    let member_token = string.repeat("4", 64)
    let assert Ok(digest) =
      member_token
      |> bit_array.from_string
      |> bootstrap.sha256
      |> bit_array.base16_encode
      |> string.lowercase
      |> access.credential_digest
      as "member digest is valid"
    let assert Ok(store) = catalogue.open(state_root <> "/catalogue.db")
      as "fixture administration opens the durable catalogue"
    let assert Ok(_) = access.create_member(store, "reader", "R", digest)
      as "the member exists"
    let #(member, _) = wire.connect(port, member_token, "/v2/control")
    let _hello = wire.frame(member, within_ms: 1000)
    let reply = ask(member, 1)
    assert field(field(reply, "body"), "code") == json.String("forbidden")
  })
}

pub fn a_daemon_with_no_file_says_not_found_test() {
  reloading(state_with_link(), None, fn(port, credential, _registry, _root) {
    let reply = ask(open(port, credential), 1)
    assert field(field(reply, "body"), "code") == json.String("not_found")
  })
}

pub fn a_file_a_start_would_refuse_changes_nothing_test() {
  let state = state_with_link()
  let name = unique("reload-c")
  let path = state <> "/loom.toml"
  let assert Ok(Nil) = simplifile.write(path, "") as "the file is written"

  reloading(state, Some(path), fn(port, credential, registry, _root) {
    // One row is held through the registry, as a start would have held it.
    let assert Ok(_) =
      untrusted_links.reconcile(registry, fn() {
        Ok(untrusted_links.Wanted(
          rows: [untrusted(name, 7000)],
          credentials: Some(ffi_tls_stream.Credentials("a", "b", "c")),
        ))
      })
      as "the row is held"
    let assert Ok(before) = process.named(untrusted_link.name_for(name))
      as "the link holds the name"

    // Then the file becomes one that no start would accept.
    let assert Ok(Nil) = simplifile.write(path, "[executors.\n")
      as "the file is made invalid"
    let reply = ask(open(port, credential), 1)
    assert field(field(reply, "body"), "code") == json.String("reload_invalid")
    assert process.named(untrusted_link.name_for(name)) == Ok(before)
    assert list.length(untrusted_links.rows(registry)) == 1
  })
}

pub fn a_new_link_table_outside_the_vm_directories_is_refused_test() {
  let state = state_with_link()
  let name = unique("reload-d")
  let path = state <> "/loom.toml"
  let elsewhere = state <> "/elsewhere"
  let assert Ok(Nil) = bootstrap.ensure_private_directory(elsewhere)
    as "the other directory exists"
  list.each(["ca.pem", "c.pem", "k.pem"], fn(file) {
    let assert Ok(Nil) = simplifile.write(elsewhere <> "/" <> file, "x")
      as "a credential file is written"
  })
  let assert Ok(Nil) =
    simplifile.write(path, link_table(elsewhere) <> rows_text([#(name, 7000)]))
    as "the file is written"

  reloading(state, Some(path), fn(port, credential, registry, _root) {
    let reply = ask(open(port, credential), 1)
    assert field(field(reply, "body"), "code") == json.String("reload_invalid")
    assert process.named(untrusted_link.name_for(name)) == Error(Nil)
    assert untrusted_links.rows(registry) == []
  })
}
