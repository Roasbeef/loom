//// Boot smoke for the server entry point: `serve.boot` over a fresh
//// SQLite session with a scripted (dead-transport) provider gateway —
//// the demo rig pattern, injected through `Settings`' gateway seam —
//// then the served surface proven from outside: `/healthz` over plain
//// HTTP, and a real websocket upgrade + `subscribe` answered with the
//// full snapshot. No generation is driven and no tool runs, so the
//// provider transport never sends and the helper never spawns — which
//// is exactly the keyless-environment boot story the module documents.

import broker/exec
import broker/policy
import client/catalog
import client/codemode
import client/distillpass
import client/host
import client/protocol
import client/rules
import client/schedule
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
import support/provider as provider_test

// A home directory that does not exist, so a server booted here never
// picks up the developer's own `~/.agents/AGENTS.md`. A home with no
// global default is silent, which is what keeps these assertions about
// the prompt pack and the workspace alone.
const empty_home = Some("build/no-operator-home")

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
    mcp_servers: [],
  )
}

fn scripted_gateway() -> provider_gateway.Gateway {
  catalog.gateway(
    scripted_catalog(),
    transport: provider_test.silent(),
    secrets: secret.from_list([#("ACME_KEY", "smoke-test-key")]),
    clock: clock.fixed(at: 0),
  )
}

fn settings() -> serve.Settings {
  settings_under(root)
}

// A repository-relative test path as the absolute one every policy path
// must be.
fn absolute(path: String) -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the test runner must have a working directory"
  here <> "/" <> path
}

fn settings_under(root: String) -> serve.Settings {
  // Absolute, because the workspace root really is: it becomes the base
  // policy's writable root, and `serve.base_policy_fault` refuses a boot
  // on a policy whose paths the jail could not accept. A test that
  // booted on a relative one was proving a server can start in a posture
  // no tool call could ever run under.
  let root = absolute(root)
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
    helper_pool_size: 2,
    session_id: "session",
    demand: exec.BestEffort,
    gateway: scripted_gateway(),
    catalog: scripted_catalog(),
    system: None,
    home: empty_home,
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
    rules: [],
    schedules: [],
    schedule_policy: schedule.ModelSchedulesOff,
    deactivated_tools: [],
    // No lifecycle distillation in this rig: the pass would open the
    // memory store this test asserts about and spend the scripted
    // provider's turns. `memory_lifecycle_test` is where the shipped
    // producer is exercised.
    memory: distillpass.no_pass(),
  )
}

pub fn the_session_environment_carries_the_toolchain_home_and_tmpdir_test() {
  // Without a toolchain the shell gets the system PATH; with one it gets
  // the compiler's, so `gleam` resolves in the shell as it does for the
  // build. HOME and TMPDIR are always the workspace's, because the
  // workspace is the one root the jail lets a tool write.
  assert serve.session_environment("/work", None)
    == [
      #("PATH", "/usr/local/bin:/usr/bin:/bin"),
      #("HOME", "/work"),
      #("TMPDIR", "/work/.codemode/tmp"),
    ]
  let toolchain = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  let assert Ok(path) =
    list.key_find(serve.session_environment("/work", Some(toolchain)), "PATH")
  assert path == toolchain
  assert serve.tool_tmp_directory("/work") == "/work/.codemode/tmp"
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

// --- the catalogue's thinking level, seeded (issue #14, ruling 3) ----------

const thinking_root = "build/serve-test-thinking"

// A catalogue entry's `thinking` is not decoration and it is not a
// dispatch override: it *seeds* the strand the boot creates. What the
// server then puts on the wire is the strand's own per-turn level, which
// is why the boot has to get the seed right — nothing downstream will
// re-derive it, and `set_config thinking_level` is the only thing that
// moves it afterwards.
pub fn a_boot_seeds_the_main_strand_from_the_entrys_thinking_test() {
  let _stale = simplifile.delete(thinking_root)
  let bodies = process.new_subject()
  let catalogue = thinking_catalog(model.ThinkingHigh)
  let assert Ok(booted) =
    serve.boot(
      serve.Settings(
        ..settings_under(thinking_root),
        catalog: catalogue,
        gateway: recording_gateway(catalogue, bodies),
      ),
    )
    as "the server must boot"

  // The seed landed durably…
  let assert Ok(Some(session.Cell(value: seeded, ..))) =
    session.strand_configuration(booted.runtime.session, "main")
    as "the main strand's configuration must read cleanly"
  assert seeded.thinking_level == machine_strand.ThinkingHigh

  // …and it is what the *first dispatch* actually asks the provider for.
  // Driven through the whole real stack — the boot's own wiring, gateway
  // and Anthropic adapter — so this is the bytes on the wire and not a
  // restatement of the seed. High is `budget_tokens: 16384`.
  let assert Ok(_op) = api.prompt(booted.runtime, [user("think hard")])
    as "the prompt must be accepted"
  let assert Ok(body) = process.receive(bodies, within: 10_000)
    as "the boot must dispatch one generation"
  assert string.contains(body, "\"budget_tokens\":16384")

  serve.shutdown(booted)
}

fn user(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

fn thinking_catalog(level: model.ThinkingLevel) -> catalog.Catalog {
  let assert [entry] = scripted_catalog().models
    as "the scripted catalogue must have exactly one entry"
  catalog.Catalog(..scripted_catalog(), models: [
    catalog.CatalogModel(..entry, thinking: level),
  ])
}

// A gateway whose transport reports the request body it was handed and
// then fails the attempt terminally, so the run drains at once instead of
// waiting out a provider timeout. The subject belongs to the test
// process, which is what lets the body be read after the fact.
fn recording_gateway(
  catalogue: catalog.Catalog,
  bodies: Subject(String),
) -> provider_gateway.Gateway {
  catalog.gateway(
    catalogue,
    transport: provider_test.transport(fn(request: http.HttpRequest, out) {
      process.send(bodies, request.body)
      process.send(out, http.ResponseStatus(status: 400, headers: []))
      process.send(
        out,
        http.ResponseChunk(chunk: <<
          "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"scripted\"}}":utf8,
        >>),
      )
      process.send(out, http.ResponseEnd)
    }),
    secrets: secret.from_list([#("ACME_KEY", "smoke-test-key")]),
    clock: clock.fixed(at: 0),
  )
}

// --- which seams can reach an MCP server ------------------------------------

/// A host serving the orchestration seam alone starts no MCP server,
/// however many are configured. A server's tools are a module only a
/// *workspace* program can import — the orchestration seam is widened by
/// none of it, ever — so `[mcp.*]` beside `--codemode-seams
/// orchestration` would spawn third-party processes, each holding a
/// configured secret in its environment, that no program could ever
/// call. The boot says so on one `mcp.unavailable` line instead.
pub fn orchestration_only_seams_cannot_reach_an_mcp_server_test() {
  let orchestrating =
    serve.Settings(
      ..settings(),
      codemode_seams: codemode.OrchestrationOnly,
      catalog: catalog.Catalog(..scripted_catalog(), mcp_servers: [
        catalog.McpServer(
          name: "github",
          command: ["mcp-server-github"],
          api_key_env: Some("GITHUB_TOKEN"),
        ),
      ]),
    )
  assert !serve.mcp_reachable(orchestrating.codemode_seams)
  // And both seams that do serve a workspace program reach one, so this
  // is a gate on reachability rather than on MCP.
  assert serve.mcp_reachable(codemode.WorkspaceOnly)
  assert serve.mcp_reachable(codemode.BothSeams)
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
  assert string.contains(pinned, "Workspace root: " <> absolute(workspace))
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

/// The enforcement demand is part of the prompt's durable identity. A
/// changed demand re-renders once so the prompt cannot claim a stronger
/// sandbox than the broker requires; the next boot at that demand reuses
/// the new bytes.
pub fn a_changed_enforcement_demand_repins_the_system_prompt_test() {
  let demand_root = "build/serve-test-prompt-demand"
  let _stale = simplifile.delete(demand_root)
  let workspace = demand_root <> "/work"
  let assert Ok(Nil) = simplifile.create_directory_all(workspace)
    as "the workspace must exist"

  let best_effort = settings_under(demand_root)
  let assert Ok(first) = serve.boot(best_effort)
    as "the first boot must succeed"
  assert first.prompt.origin == system_prompt.Shipped
  assert string.contains(first.prompt.text, "best-effort mode")
  let best_effort_text = first.prompt.text
  serve.shutdown(first)

  let platform = serve.Settings(..best_effort, demand: exec.PlatformEnforcement)
  let assert Ok(second) = serve.boot(platform)
    as "the changed demand must render a truthful replacement"
  assert second.prompt.origin == system_prompt.Shipped
  assert second.prompt.fresh
  assert second.prompt.text != best_effort_text
  assert !string.contains(second.prompt.text, "best-effort mode")
  let platform_text = second.prompt.text
  serve.shutdown(second)

  let assert Ok(third) = serve.boot(platform)
    as "the unchanged demand must reuse the replacement"
  assert third.prompt.origin == system_prompt.Pinned
  assert !third.prompt.fresh
  assert third.prompt.text == platform_text
  serve.shutdown(third)
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
    transport: provider_test.transport(fn(request, _events) {
      process.send(sent, request.body)
    }),
    secrets: secret.from_list([#("ACME_KEY", "smoke-test-key")]),
    clock: clock.fixed(at: 0),
  )
}

// --- the host: what a death costs -------------------------------------------

/// A fatal tree death without its ledger cannot prove a clean provider drain.
///
/// The host still closes the listener and the rest of the stack, but it leaves
/// the lease to its TTL rather than letting a replacement overlap work whose
/// ownership record disappeared. Availability yields to the stream invariant.
///
/// The children this reaches are the ones a boot links to whichever
/// process ran it. Before the host existed that process was the one
/// waiting for `SIGTERM`, it did not trap exits, and the generated
/// runner above it turned the link into `init:stop(1)` with no cleanup at all.
pub fn a_fatal_drain_ledger_death_keeps_the_lease_test() {
  let fault_root = "build/serve-test-fault"
  let _stale = simplifile.delete(fault_root)
  let assert Ok(booted) = serve.boot(settings_under(fault_root))
    as "the server must boot"

  // The significant ledger is fatal by policy. Killing it directly makes the
  // absent-witness condition deterministic instead of racing the ledger's
  // orderly exit after a separately killed root.
  let assert Ok(ledger) =
    process.subject_owner(process.named_subject(booted.runtime.tree.drains))
  process.kill(ledger)

  let assert Ok(host.Faulted(child:, ..)) =
    process.receive(booted.stops, within: 10_000)
    as "the host must report the fault rather than take the node with it"
  assert child == "the session tree"

  // Once both the root and its drain ledger are gone, no later caller can
  // prove whether detached provider work survived them. Failing closed keeps
  // the lease rather than overlapping an unverified predecessor.
  let assert Error(_) =
    session.open_sqlite(
      path: fault_root <> "/session.db",
      owner: "probe",
      lease_ttl_ms: 60_000,
      clock: clock.fixed(at: 0),
    )
    as "a missing drain witness must leave the lease held"
  let _sealed = session.close(booted.runtime.session)

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

// --- the base policy the server refuses to boot on -------------------------

pub fn a_base_policy_the_sandbox_can_enforce_boots_test() {
  assert serve.base_policy_fault(serve.base_policy("/work")) == Ok(Nil)
}

pub fn a_relative_protected_entry_refuses_the_boot_test() {
  // The finding this check exists for. A relative `protected` entry
  // normalizes to `/.git` in the harness's own path work, where it is
  // under no workspace and covers nothing — so the operator who wrote it
  // gets a session that protects nothing while reading as though it
  // does. The jail refuses the very same value (`policy.validate`), and
  // two enforcement points disagreeing is exactly what must not ship.
  // Refused at boot, before a directory is made or a helper is spawned,
  // because the alternative is learning about it from the first tool
  // call of a live session.
  let base =
    policy.SandboxPolicy(..serve.base_policy("/work"), protected: [".git"])
  let assert Error(reason) = serve.base_policy_fault(base)
    as "a relative protected entry refuses the boot"
  assert string.contains(reason, "base policy")
  assert string.contains(reason, ".git")
  assert string.contains(reason, "not absolute")
}

pub fn a_relative_writable_root_refuses_the_boot_test() {
  // Same check, the other kind of path: `validate` is one rule over
  // every path a policy names, and this server refuses on all of them
  // rather than on the one that prompted the check.
  let base =
    policy.SandboxPolicy(..serve.base_policy("/work"), writable_roots: [
      "work",
    ])
  let assert Error(reason) = serve.base_policy_fault(base)
    as "a relative writable root refuses the boot"
  assert string.contains(reason, "`work` is not absolute")
}

pub fn a_negative_limit_refuses_the_boot_naming_the_field_test() {
  let base = serve.base_policy("/work")
  let limits = policy.Limits(..base.limits, wall_s: -1)
  let assert Error(reason) =
    serve.base_policy_fault(policy.SandboxPolicy(..base, limits:))
    as "a negative limit refuses the boot"
  assert string.contains(reason, "wall_s")
  assert string.contains(reason, "cannot be negative")
}

pub fn a_scratch_of_the_host_root_refuses_the_boot_test() {
  let base =
    policy.SandboxPolicy(
      ..serve.base_policy("/work"),
      scratch: policy.ScratchPath(path: "/"),
    )
  let assert Error(reason) = serve.base_policy_fault(base)
    as "a scratch of the host root refuses the boot"
  assert string.contains(reason, "Landlock")
}

pub fn the_boot_itself_refuses_before_anything_is_spawned_test() {
  // Not just the pure check: `assemble` asks it first, so no session
  // file, no lease, no helper pool. The session path is one this test
  // has never created, and the refusal must be about the policy rather
  // than about the missing directory.
  let boot_root = "build/serve-test-policy-fault"
  let _stale = simplifile.delete(boot_root)
  let settings = settings_under(boot_root)
  let base =
    policy.SandboxPolicy(..settings.base_policy, protected: ["relative/entry"])
  let assert Error(reason) =
    serve.boot(serve.Settings(..settings, base_policy: base))
    as "the boot refuses a base policy the sandbox cannot enforce"
  assert string.contains(reason, "relative/entry")
  // Nothing was prepared: the check runs before `prepare_directories`.
  assert simplifile.is_directory(boot_root) == Ok(False)
}

// --- the triggered-rule scanner's presence (issue #27) ---------------------

const rules_root = "build/serve-test-rules"

// A server nobody configured rules for runs exactly the processes it ran
// before rules existed. Not a scanner holding an empty list: no scanner,
// and one log line saying so — the `codemode.unavailable` posture, for
// the same reason.
pub fn a_boot_with_no_rules_starts_no_scanner_test() {
  let _stale = simplifile.delete(rules_root)
  let assert Ok(booted) = serve.boot(settings_under(rules_root))
    as "the server must boot with no rules configured"
  assert booted.rulescan == None
  serve.shutdown(booted)
}

// And a server that *was* configured runs one, under the restartable
// service supervisor, addressable by the name the writer subscribes to.
pub fn a_boot_with_rules_runs_a_supervised_scanner_test() {
  let _stale = simplifile.delete(rules_root <> "-on")
  let base = settings_under(rules_root <> "-on")
  let assert Ok(booted) =
    serve.boot(
      serve.Settings(..base, rules: [
        rules.Rule(
          name: "schema-gate",
          triggers: ["ALTER TABLE"],
          body: "Run the schema gate first.",
        ),
      ]),
    )
    as "the server must boot with a rule configured"
  let assert Some(name) = booted.rulescan
    as "a configured rule must name a scanner"
  let assert Ok(_pid) = process.named(name)
    as "the scanner must be registered under that name"
  serve.shutdown(booted)
}

const schedules_root = "build/serve-test-schedules"

// The same posture as rules: a server nobody configured schedules for
// starts no scanner at all.
pub fn a_boot_with_no_schedules_starts_no_scanner_test() {
  let _stale = simplifile.delete(schedules_root)
  let assert Ok(booted) = serve.boot(settings_under(schedules_root))
    as "the server must boot with no schedules configured"
  assert booted.schedulescan == None
  serve.shutdown(booted)
}

// And a server that *was* configured runs one, under the restartable
// service supervisor, addressable by the name it registered under — not
// a writer subscriber, unlike the rule scanner, but still reached by
// name for the same restart-transparency reason.
pub fn a_boot_with_schedules_runs_a_supervised_scanner_test() {
  let _stale = simplifile.delete(schedules_root <> "-on")
  let base = settings_under(schedules_root <> "-on")
  let assert Ok(booted) =
    serve.boot(
      serve.Settings(..base, schedules: [
        schedule.Schedule(
          name: "heartbeat",
          target: "main",
          timing: schedule.Interval(
            seconds: 300,
            expiry: schedule.Expiry(max_fires: 1000, expires_after_s: 604_800),
          ),
          wake: schedule.SteersOnly,
          body: "Check on things.",
        ),
      ]),
    )
    as "the server must boot with a schedule configured"
  let assert Some(name) = booted.schedulescan
    as "a configured schedule must name a scanner"
  let assert Ok(_pid) = process.named(name)
    as "the scanner must be registered under that name"
  serve.shutdown(booted)
}
