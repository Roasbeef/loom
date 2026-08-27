//// Boot smoke for the server entry point: `serve.boot` over a fresh
//// SQLite session with a scripted (dead-transport) provider gateway —
//// the demo rig pattern, injected through `Settings`' gateway seam —
//// then the served surface proven from outside: `/healthz` over plain
//// HTTP, and a real websocket upgrade + `subscribe` answered with the
//// full snapshot. No generation is driven and no tool runs, so the
//// provider transport never sends and the helper never spawns — which
//// is exactly the keyless-environment boot story the module documents.

import broker/exec
import client/catalog
import client/codemode
import client/host
import client/protocol
import client/serve
import client/summaries
import client/system_prompt
import core/clock
import core/message
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import machine/operation
import machine/strand as machine_strand
import provider/adapter/anthropic
import provider/gateway as provider_gateway
import provider/http
import provider/model
import provider/secret
import runtime/api
import session/session
import simplifile
import support/internal/ffi_ws

const root = "build/serve-test"

// A one-entry catalogue whose gateway rides a transport that never
// answers: subscribe and healthz touch no provider, so the smoke boot
// needs reachability of the seam, not a live wire — and building the
// gateway *from* the catalogue is exactly what `resolve` does.
fn scripted_catalog() -> catalog.Catalog {
  catalog.Catalog(
    models: [
      catalog.CatalogModel(
        name: "acme",
        dialect: catalog.Anthropic,
        base_url: "https://acme.test",
        api_key_env: "ACME_KEY",
        model_id: "loom-1",
        context_window: 100_000,
        max_output_tokens: 4096,
        thinking: model.ThinkingOff,
      ),
    ],
    roles: [#(model.Main, ["acme"])],
  )
}

fn scripted_gateway() -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: http.Transport(send_streaming: fn(_request, _subject) { Nil }),
    secrets: secret.from_list([#("ACME_KEY", "smoke-test-key")]),
    clock: clock.fixed(at: 0),
  )
}

fn settings() -> serve.Settings {
  settings_under(root)
}

fn settings_under(root: String) -> serve.Settings {
  serve.Settings(
    session_path: root <> "/session.db",
    bind_host: "127.0.0.1",
    bind_port: 0,
    token_path: root <> "/session.db.token",
    workspace: root <> "/work",
    base_policy: serve.base_policy(root <> "/work"),
    // Never spawned: nothing in this test runs a tool, and the pool
    // spawns helpers lazily at first checkout.
    helper_path: "/bin/sh",
    session_id: "session",
    demand: exec.BestEffort,
    gateway: scripted_gateway(),
    catalog: scripted_catalog(),
    system: None,
    model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
    context_window: 100_000,
    max_output_tokens: 4096,
    api: anthropic.api_name,
    compaction: operation.CompactionSettings(
      enabled: True,
      reserve_tokens: 16_384,
      keep_recent_tokens: 20_000,
    ),
    // No seed here: the boot smoke must not go looking for a toolchain,
    // and a host without one registers no `code_mode` tool.
    codemode_seed: root <> "/no-such-seed",
    codemode_seams: codemode.WorkspaceOnly,
  )
}

pub fn boot_serves_healthz_and_ws_subscribe_test() {
  // A fresh root per run so the session always starts empty.
  let _stale = simplifile.delete(root)
  let assert Ok(booted) = serve.boot(settings())
    as "the server must boot on an ephemeral port"

  // The bearer token landed in the announced file, mode 0600.
  let assert Ok(token) = simplifile.read(root <> "/session.db.token")
  assert token == booted.served.token
  let assert Ok(info) = simplifile.file_info(root <> "/session.db.token")
  assert info.mode % 0o1000 == 0o600

  // /healthz answers without auth.
  let base = "http://127.0.0.1:" <> int.to_string(booted.served.port)
  let assert Ok(health) = request.to(base <> "/healthz")
  let assert Ok(health_response) = httpc.send(health)
  assert health_response.status == 200

  // A real websocket subscribe: upgrade with the token from the file,
  // send the command, and the reply is the full snapshot for the
  // session id the server derived from the file name.
  let subscribe =
    protocol.encode_command(protocol.CommandEnvelope(
      id: 1,
      command: protocol.Subscribe(session: "session", from_seq: None),
    ))
  let assert Ok(frame) =
    ffi_ws.ws_roundtrip("127.0.0.1", booted.served.port, token, subscribe)
    as "the websocket round trip must complete"
  let assert Ok(envelope) = protocol.decode_event(frame)
  assert envelope.reply_to == Some(1)
  let assert protocol.SnapshotEvent(protocol.FullSnapshot(..)) = envelope.event

  serve.shutdown(booted)
}

// --- the pinned system prompt ----------------------------------------------

const prompt_root = "build/serve-test-prompt"

/// The prompt is assembled at the first open and pinned; every later boot
/// of the same session sends the pinned bytes rather than deriving them
/// again. The proof is a `CLAUDE.md` that changes between the two boots:
/// a re-derived prompt would carry the new text and cost a fresh
/// one-hour cache write on the first turn after every restart.
pub fn boot_pins_the_system_prompt_and_reuses_it_test() {
  let _stale = simplifile.delete(prompt_root)
  let workspace = prompt_root <> "/work"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the workspace must exist"
  let assert Ok(Nil) =
    simplifile.write(workspace <> "/CLAUDE.md", "# demo\n\nBuild with make.\n")
    as "the guidance file must be written"

  let assert Ok(first) = serve.boot(settings_under(prompt_root))
    as "the first boot must succeed"
  let assert Ok(Some(pinned)) = system_prompt.pinned(first.runtime)
    as "the first boot must pin a system prompt"
  // A first boot renders the shipped pack and owes the pin it just paid.
  assert first.prompt.origin == system_prompt.Shipped
  assert first.prompt.text == pinned
  assert first.prompt.warnings == []
  // It is the rendered pack against this host, not an empty string and
  // not a placeholder: the workspace, the shell, and the repository's own
  // guidance are all in it, framed as project-authored data.
  assert string.contains(pinned, "Workspace root: " <> workspace)
  assert string.contains(pinned, "Shell: " <> serve.shell_path)
  assert string.contains(pinned, "<project-guidance>")
  assert string.contains(pinned, "Build with make.")
  serve.shutdown(first)

  // The guidance changes under the session. A prompt derived from live
  // inputs would move; a pinned one cannot.
  let assert Ok(Nil) =
    simplifile.write(
      workspace <> "/CLAUDE.md",
      "# demo\n\nEverything about this project is different now.\n",
    )
    as "the guidance file must be rewritten"
  let assert Ok(second) = serve.boot(settings_under(prompt_root))
    as "the second boot must succeed"
  let assert Ok(Some(resumed)) = system_prompt.pinned(second.runtime)
    as "the second boot must read the pinned prompt"
  // The second boot took the pin rather than the pack: nothing was
  // rendered, so nothing could have moved.
  assert second.prompt.origin == system_prompt.Pinned
  assert !second.prompt.fresh
  assert resumed == pinned
  assert !string.contains(resumed, "different now")
  serve.shutdown(second)
}

/// `LOOM_SYSTEM_PROMPT` still bypasses the pack entirely, and beats an
/// existing pin, because setting it is a deliberate act.
pub fn an_explicit_override_bypasses_the_pack_test() {
  let override_root = "build/serve-test-override"
  let _stale = simplifile.delete(override_root)
  let assert Ok(booted) =
    serve.boot(
      serve.Settings(
        ..settings_under(override_root),
        system: Some("operator words only"),
      ),
    )
    as "the boot must succeed with an override"
  let assert Ok(Some(pinned)) = system_prompt.pinned(booted.runtime)
    as "the override must be pinned"
  assert pinned == "operator words only"
  serve.shutdown(booted)
}

/// The assembled prompt reaches the wire, not just the durable cell. A
/// capturing transport takes the request the gateway would have sent and
/// the rendered `system` block is in its body — which is the only place
/// the pin is worth anything, and the one thing a pinned-cell assertion
/// alone would not notice going missing.
pub fn the_pinned_prompt_reaches_the_provider_request_test() {
  let wire_root = "build/serve-test-wire"
  let _stale = simplifile.delete(wire_root)
  let workspace = wire_root <> "/work"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the workspace must exist"
  let sent = process.new_subject()
  let assert Ok(booted) =
    serve.boot(
      serve.Settings(
        ..settings_under(wire_root),
        gateway: capturing_gateway(sent),
      ),
    )
    as "the boot must succeed"
  let assert Ok(Some(pinned)) = system_prompt.pinned(booted.runtime)
    as "the boot must pin a system prompt"

  let assert Ok(_operation) =
    api.prompt(booted.runtime, [
      message.UserMessage(
        content: [message.UserText(text: "hello", text_signature: None)],
        timestamp: 1,
      ),
    ])
    as "the prompt must be accepted"
  let assert Ok(body) = process.receive(sent, within: 10_000)
    as "the gateway must have built a request"

  // The pinned bytes are what went out. Line by line, because the body is
  // JSON and the newlines inside the block are escaped there.
  list.each(string.split(pinned, on: "\n"), fn(line) {
    assert string.contains(body, line)
      as { "the system prompt line is missing from the wire: " <> line }
  })
  serve.shutdown(booted)
}

// A gateway whose transport hands the request it would have sent to a
// subject and then says nothing, so the operation stays in flight and the
// test owns the timing.
fn capturing_gateway(sent: Subject(String)) -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: http.Transport(send_streaming: fn(request, _events) {
      process.send(sent, request.body)
    }),
    secrets: secret.from_list([#("ACME_KEY", "smoke-test-key")]),
    clock: clock.fixed(at: 0),
  )
}

// --- the host: what a death costs -------------------------------------------

/// The bar this exists for. Kill a fatal child and the server does not
/// vanish with an unreleased lease: the host runs the whole orderly
/// shutdown first, so the same session file opens again *at once*
/// instead of after its sixty-second TTL — and only then reports what
/// died, leaving the exit status to the entry point.
///
/// The children this reaches are the ones a boot links to whichever
/// process ran it. Before the host existed that process was the one
/// waiting for `SIGTERM`, it did not trap exits, and the generated
/// runner above it turned the link into `init:stop(1)` — no shutdown, no
/// lease release, a session locked out for a minute by a crash.
pub fn a_fatal_childs_death_releases_the_lease_test() {
  let fault_root = "build/serve-test-fault"
  let _stale = simplifile.delete(fault_root)
  let assert Ok(booted) = serve.boot(settings_under(fault_root))
    as "the server must boot"

  // The session tree: fatal by policy, and one of the three the host
  // must *monitor* rather than trap, because it unlinks from its
  // starter by design.
  process.kill(booted.runtime.tree.supervisor)

  let assert Ok(host.Faulted(child:, ..)) =
    process.receive(booted.stops, within: 10_000)
    as "the host must report the fault rather than take the node with it"
  assert child == "the session tree"

  // The proof: the lease is gone, so a second opener wins immediately.
  // With the lease left to expire this refuses with LeaseHeld.
  let assert Ok(reopened) =
    session.open_sqlite(
      path: fault_root <> "/session.db",
      owner: "probe",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 0),
    )
    as "the writer lease must have been released, not left to its TTL"
  let _sealed = session.close(reopened)

  // And the front door is shut: the teardown ran in full, not just far
  // enough to reach the lease.
  let base = "http://127.0.0.1:" <> int.to_string(booted.served.port)
  let assert Ok(health) = request.to(base <> "/healthz")
  assert httpc.send(health) |> result.is_error
    as "the listener must be closed once the host has torn the stack down"
}

/// A linked child — the summary sink is one, started with a plain
/// `actor.start` on the boot process — reaches the host through its exit
/// trap rather than through a monitor, and costs the same orderly
/// shutdown.
pub fn a_linked_childs_death_releases_the_lease_test() {
  let fault_root = "build/serve-test-linked-fault"
  let _stale = simplifile.delete(fault_root)
  let assert Ok(booted) = serve.boot(settings_under(fault_root))
    as "the server must boot"

  let assert Ok(sink) = summaries.pid(booted.summaries)
    as "the summary sink must be alive"
  process.kill(sink)

  let assert Ok(host.Faulted(child:, ..)) =
    process.receive(booted.stops, within: 10_000)
    as "a linked child's death must be reported, not fatal by side effect"
  assert child == "the summary sink"

  let assert Ok(reopened) =
    session.open_sqlite(
      path: fault_root <> "/session.db",
      owner: "probe",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 0),
    )
    as "the writer lease must have been released, not left to its TTL"
  let _sealed = session.close(reopened)
}

/// The other half of the policy: the composition layer is supervised, so
/// a hub crash is a restart under the same name, not the end of the
/// server. The listener, the commit forwarder, and the provider tap all
/// address the hub by name, which is the whole reason this one can be
/// replaced in place — and the session is untouched, so the websocket
/// surface answers again.
pub fn a_hub_crash_restarts_rather_than_ending_the_server_test() {
  let restart_root = "build/serve-test-restart"
  let _stale = simplifile.delete(restart_root)
  let assert Ok(booted) = serve.boot(settings_under(restart_root))
    as "the server must boot"

  let assert Ok(before) = hub_pid(booted)
    as "the hub must be registered before the crash"
  process.kill(before)

  let assert Ok(after) = replacement_hub_pid(booted, before, 400)
    as "the hub must come back under the same name"
  assert after != before
  assert process.receive(booted.stops, within: 250) == Error(Nil)
    as "a restartable child's crash must not stop the server"

  // Proof it is a working hub and not just a live pid: a real subscribe
  // over a real socket, answered with the full snapshot.
  let subscribe =
    protocol.encode_command(protocol.CommandEnvelope(
      id: 7,
      command: protocol.Subscribe(session: "session", from_seq: None),
    ))
  let assert Ok(frame) =
    ffi_ws.ws_roundtrip(
      "127.0.0.1",
      booted.served.port,
      booted.served.token,
      subscribe,
    )
    as "the restarted hub must answer a fresh subscription"
  let assert Ok(envelope) = protocol.decode_event(frame)
  assert envelope.reply_to == Some(7)
  let assert protocol.SnapshotEvent(protocol.FullSnapshot(..)) = envelope.event

  serve.shutdown(booted)
}

/// A crash loop spends the service supervisor's restart budget, and then
/// the composition layer *is* fatal — but still orderly. "Restartable"
/// is a bounded promise, not an unbounded one.
pub fn an_unrecoverable_service_still_releases_the_lease_test() {
  let loop_root = "build/serve-test-service-loop"
  let _stale = simplifile.delete(loop_root)
  let assert Ok(booted) = serve.boot(settings_under(loop_root))
    as "the server must boot"

  // One kill more than the budget, each waiting for the replacement so
  // the intensity counter sees distinct restarts.
  kill_hub_repeatedly(
    booted,
    Ok(before_the_loop(booted)),
    serve.service_restart_intensity + 1,
  )

  let assert Ok(host.Faulted(child:, ..)) =
    process.receive(booted.stops, within: 10_000)
    as "a spent restart budget must end the server, in order"
  assert child == "the service supervisor"

  let assert Ok(reopened) =
    session.open_sqlite(
      path: loop_root <> "/session.db",
      owner: "probe",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 0),
    )
    as "the writer lease must have been released, not left to its TTL"
  let _sealed = session.close(reopened)
}

fn before_the_loop(booted: serve.Booted) -> process.Pid {
  let assert Ok(pid) = settled_hub_pid(booted, 400)
    as "the hub must be registered before the crash loop"
  pid
}

// Kills the hub `times` over, each time waiting for the supervisor to
// put a *different* pid under the name, so every kill costs a restart
// rather than landing on a corpse.
fn kill_hub_repeatedly(
  booted: serve.Booted,
  current: Result(process.Pid, Nil),
  times: Int,
) -> Nil {
  case current, times <= 0 {
    _, True -> Nil
    Error(Nil), _ -> Nil
    Ok(pid), False -> {
      process.kill(pid)
      kill_hub_repeatedly(
        booted,
        replacement_hub_pid(booted, pid, 400),
        times - 1,
      )
    }
  }
}

// The pid under the hub's name once it is neither missing nor the one
// that was just killed.
fn replacement_hub_pid(
  booted: serve.Booted,
  before: process.Pid,
  attempts: Int,
) -> Result(process.Pid, Nil) {
  case hub_pid(booted) {
    Ok(pid) if pid != before -> Ok(pid)
    _ ->
      case attempts <= 0 {
        True -> Error(Nil)
        False -> {
          process.sleep(5)
          replacement_hub_pid(booted, before, attempts - 1)
        }
      }
  }
}

// The hub registers under a name the boot minted, so the only handle a
// test has on it is the gateway record the server holds.
fn hub_pid(booted: serve.Booted) -> Result(process.Pid, Nil) {
  process.subject_owner(process.named_subject(booted.gateway.name))
}

// The pid once the supervisor has finished replacing it, or `Error(Nil)`
// if it never comes back.
fn settled_hub_pid(
  booted: serve.Booted,
  attempts: Int,
) -> Result(process.Pid, Nil) {
  case hub_pid(booted) {
    Ok(pid) -> Ok(pid)
    Error(Nil) ->
      case attempts <= 0 {
        True -> Error(Nil)
        False -> {
          process.sleep(5)
          settled_hub_pid(booted, attempts - 1)
        }
      }
  }
}
