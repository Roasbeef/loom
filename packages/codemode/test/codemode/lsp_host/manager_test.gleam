//// Proves the shared physical host can resolve and resynchronize a document
//// using physical workspace facts and injected clearance. This package has
//// no client dependency, so an owner toolchain or owner filesystem callback
//// cannot accidentally enter the construction path.

import broker/broker
import broker/exec
import broker/framing as native_framing
import broker/policy
import codemode/lsp_host/jail
import codemode/lsp_host/leases
import codemode/lsp_host/manager
import codemode/lsp_host/profile
import core/clock
import core/json
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import lsp/framing
import lsp/jsonrpc
import lsp/query
import simplifile
import tools/tool

pub fn resolves_and_resynchronizes_with_only_physical_facts_test() {
  let assert Ok(here) = simplifile.current_directory()
    as "the physical test host has a working directory"
  let workspace = here <> "/build/lsp-host-injected-facts"
  let root = workspace <> "/package"
  let path = root <> "/src/target.gleam"
  let protected = root <> "/private"
  let assert Ok(Nil) = simplifile.create_directory_all(root <> "/src")
    as "the physical package directory exists"
  let assert Ok(Nil) = simplifile.create_directory_all(protected)
    as "the protected physical directory exists"
  let assert Ok(Nil) =
    simplifile.write(root <> "/project.toml", "name = \"target\"")
    as "root resolution uses the physical marker"
  let before = "pub fn greet() -> String { \"physical before\" }\n"
  let after = "pub fn greet() -> String { \"physical after\" }\n"
  let assert Ok(Nil) = simplifile.write(path, before)
    as "the source exists only at the injected physical root"
  let assert Ok(counter) = leases.start(exec.min_pool_size)
    as "the physical host lease counter starts"
  let cleared = process.new_subject()
  let seen = process.new_subject()
  let physical_clock = clock.fixed(0)
  let operation = jail.operation(physical_clock, seed: 697)

  // Both lookup and environment are explicit administrative facts. The
  // lookup returns one approved executable, without consulting ambient PATH.
  let jailed =
    manager.Jailed(
      workspace:,
      session_base: policy.SandboxPolicy(
        ..policy.workspace_default(workspace),
        protected: [protected],
      ),
      demand: exec.BestEffort,
      executables: jail.Executables(gleam_path: None, find: fn(name) {
        case name {
          "physical-test-server" -> Ok("/bin/cat")
          _ -> Error(Nil)
        }
      }),
      places: profile.Places(home: None, cache: None),
      reading: fn(name) {
        case name {
          "PATH" -> Ok("/bin")
          _ -> Error(Nil)
        }
      },
      run: runner(cleared, seen),
      abort_step: fn(_step) { Nil },
      leases: counter,
      op_id: operation,
      clock: physical_clock,
      exec_ms: 1000,
    )
  let assert Ok(host) =
    manager.start(manager.Config(
      workspace:,
      servers: [server()],
      backend: manager.jailed(jailed),
      timing: manager.Timing(..manager.default_timing(), quiet_ms: 0),
    ))
    as "the shared manager starts without owner assembly"
  let door = manager.door(host)
  let assert Ok(cold) = door.outline("package/src/target.gleam")
    as "the injected physical runner serves the resolved file"
  let assert [symbol] = cold.value as "the physical outline has one symbol"
  assert cold.warmth == query.Started("physical")
  assert symbol.site.path == "package/src/target.gleam"
  assert symbol.site.text == "pub fn greet() -> String { \"physical before\" }"
  let assert Ok(probe) = process.receive(cleared, 1000)
    as "the enforcement probe clears before the lease"
  let assert Ok(lease) = process.receive(cleared, 1000)
    as "the server clears through the injected runner"
  assert probe.argv == manager.probe_argv
  assert lease.argv == ["/bin/cat"]
  assert lease.cwd == root
  assert lease.requirements.network == policy.NetworkOff

  // The warm query pulls fresh text from the physical root and opens no
  // second lease. A protected path is refused before another clearance.
  let assert Ok(Nil) = simplifile.write(path, after)
    as "a physical edit lands between semantic queries"
  let assert Ok(warm) = door.outline("package/src/target.gleam")
    as "the shared manager resynchronizes physical disk text"
  let assert [updated] = warm.value as "the warm outline has one symbol"
  assert warm.warmth == query.Warm
  assert updated.site.text == "pub fn greet() -> String { \"physical after\" }"
  let assert Ok(Nil) = simplifile.write(protected <> "/secret.gleam", before)
    as "a protected source tests authoritative admission"
  let assert Error(query.NoServer(_)) =
    door.outline("package/private/secret.gleam")
    as "a marker does not grant a protected file"
  assert process.receive(cleared, 0) == Error(Nil)
  let methods = drain(seen, [])
  assert list.contains(methods, "textDocument/didOpen")
  assert list.contains(methods, "textDocument/didChange")
  manager.stop(host)
  assert leases.held(counter, waiting: 1000) == Ok(0)
  leases.stop(counter)
  let assert Ok(Nil) = simplifile.delete_all([workspace])
    as "the physical fixture is removed after the witnessed lease return"
}

fn server() -> profile.LspServer {
  profile.LspServer(
    name: "physical",
    command: ["physical-test-server"],
    preparation: profile.AlreadyPrepared,
    extensions: [".gleam"],
    root_markers: ["project.toml"],
    project: profile.ProjectReadOnly,
    readable: [],
    writable: [],
    env: [],
    cache_env: [],
    language_id: "gleam",
    qualifier_separators: ["."],
    module_case: profile.AsWritten,
    hint: None,
  )
}

fn runner(
  cleared: Subject(broker.CallSpec),
  seen: Subject(String),
) -> fn(broker.CallSpec, Subject(broker.CallEvent)) ->
  Result(tool.RunningCall, broker.Refusal) {
  fn(spec, events) {
    process.send(cleared, spec)
    case spec.argv == manager.probe_argv {
      True -> {
        process.send(events, broker.CallSettled(clean()))
        Ok(
          tool.RunningCall(stdin: fn(_bytes, _eof) { Nil }, cancel: fn() { Nil }),
        )
      }
      False ->
        Ok(
          tool.RunningCall(
            stdin: fn(bytes, eof) {
              case eof {
                True -> process.send(events, broker.CallSettled(clean()))
                False -> answer(bytes, events, seen)
              }
            },
            cancel: fn() { process.send(events, broker.CallSettled(clean())) },
          ),
        )
    }
  }
}

fn answer(
  bytes: BitArray,
  events: Subject(broker.CallEvent),
  seen: Subject(String),
) -> Nil {
  let assert Ok(#(_, bodies)) = framing.push(framing.new(), bytes)
    as "the client sends complete request frames"
  list.each(bodies, fn(body) {
    let assert Ok(message) = jsonrpc.decode(body)
      as "the client emits valid JSON-RPC"
    case message {
      jsonrpc.ServerRequest(id, method, _) -> {
        process.send(seen, method)
        let result = case method {
          "initialize" ->
            json.Object([
              #(
                "capabilities",
                json.Object([
                  #("documentSymbolProvider", json.Bool(True)),
                  #("textDocumentSync", json.Int(1)),
                ]),
              ),
            ])
          "textDocument/documentSymbol" -> outline()
          _ -> json.Null
        }
        let bytes =
          bit_array.from_string(framing.frame(jsonrpc.response(id, result)))
        process.send(
          events,
          broker.CallOutput(
            stream: native_framing.Stdout,
            data: bytes,
            total_bytes: bit_array.byte_size(bytes),
            truncated: False,
          ),
        )
      }
      jsonrpc.Notification(method, _) -> process.send(seen, method)
      jsonrpc.Response(_, _) -> Nil
    }
  })
}

fn outline() -> json.JsonValue {
  let span =
    json.Object([
      #(
        "start",
        json.Object([#("line", json.Int(0)), #("character", json.Int(7))]),
      ),
      #(
        "end",
        json.Object([#("line", json.Int(0)), #("character", json.Int(12))]),
      ),
    ])
  json.Array([
    json.Object([
      #("name", json.String("greet")),
      #("kind", json.Int(12)),
      #("range", span),
      #("selectionRange", span),
    ]),
  ])
}

fn clean() -> broker.CallOutcome {
  broker.CallExited(exec.ExecResult(
    code: 0,
    signal: 0,
    stdout_bytes: 0,
    stderr_bytes: 0,
    stdout_truncated: False,
    stderr_truncated: False,
    enforcement: [],
    degraded: False,
    wall_ms: 0,
    timed_out: False,
    cancelled: False,
  ))
}

fn drain(subject: Subject(a), held: List(a)) -> List(a) {
  case process.receive(subject, 0) {
    Ok(item) -> drain(subject, [item, ..held])
    Error(Nil) -> list.reverse(held)
  }
}

// Compiler identity is an administrative fact, not an ambient executable
// lookup. The same physical compiler can build programs and analyse files.
pub fn bundled_compiler_does_not_consult_ambient_lookup_test() {
  let looked_up = process.new_subject()
  let executables =
    jail.Executables(gleam_path: Some("/bin/cat"), find: fn(name) {
      process.send(looked_up, name)
      Error(Nil)
    })
  let configured = profile.LspServer(..server(), command: ["gleam", "lsp"])
  let assert Ok(found) = jail.locate(configured, executables)
    as "the injected physical compiler wins over bare-name lookup"
  assert found.path == "/bin/cat"
  assert process.receive(looked_up, 0) == Error(Nil)
  let relative = profile.LspServer(..server(), command: ["tools/server"])
  let assert Error(_) = jail.locate(relative, executables)
    as "relative command paths never use lookup"
  assert process.receive(looked_up, 0) == Error(Nil)
}

pub fn physical_step_retains_the_existing_sha256_identity_test() {
  assert jail.step_id("physical", "/work") == "lsp/physical/0c9a453fad615c83"
}
