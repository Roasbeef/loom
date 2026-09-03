//// An installed extension, dispatched for real: a jailed build at
//// install, one jailed satellite held open for the session, a brokered
//// `net.request` to a real TLS origin, and a credential that reaches the
//// origin without ever reaching the jail.
////
//// This is phases 2 and 3 minus the model. The orchestrator's real drive
//// is what proves a provider calls `web_search`; what is proved here is
//// everything under that: the registry contribution, the `net.request`
//// arm, the egress policy the manifest translated to, the per-invocation
//// request ceiling, the persistent host's own three claims — two tool
//// calls reach one node launch, an `Event` invocation reaches the
//// handler a `[[hook]]` named, and an extension that ignores its
//// deadline loses its satellite for the session — and the two absence
//// claims the whole design rests on —
////
//// - **the key is not in the jail's environment.** The satellite's
////   `LaunchSpec` is captured on the way past and both halves are read:
////   `launch.node_env` (what the launcher will actually set) and
////   `launch.node_requirements(..).env_allow` (what the kernel will
////    permit through at all). The binding's variable name is in neither,
////   and its value is in no value the node is given.
//// - **the key is on no frame.** Every byte in both directions on the
////   capability channel is recorded by a tap around the production
////   launcher, and the value appears in none of them. That covers the
////   direction that could plausibly carry one — the `cap_result` for
////   `net.request`, composed by the harness — and the direction that
////   could not, so the claim is about the channel rather than about one
////   arm of it.
////
//// The origin answers a body that does not echo the request, deliberately
//// (`support/origin`): an echoing origin would put the credential in the
//// response body, and the second claim would then be false for a reason
//// that has nothing to do with the design.
////
//// # Feature detection
////
//// Everything here needs a sandbox helper, a Gleam and Erlang toolchain
//// and a prepared build seed, exactly as `extension_test`'s jailed-build
//// case and `packages/codemode`'s end-to-end do. Without them the test
//// prints a skip reason and passes, so `make check` stays hermetic; with
//// them (`make binaries && make codemode-seed`) it really builds an
//// extension inside a network-off jail and really boots a node.
////
//// Enforcement is `exec.BestEffort` for the reason every real-helper
//// suite in this tree uses it: the CI gate runners carry a helper that is
//// honest about lacking a layer, and a test demanding the platform's full
//// enforcement would fail on the runner rather than on the code. What the
//// kernel actually provided is printed rather than assumed.

import broker/broker
import broker/egress
import broker/exec
import broker/policy
import broker/token
import client/codemode as codemode_wiring
import client/contributions
import client/extension/archive
import client/extension/cli
import client/extension/dispatch
import client/extension/hooks
import client/extension/hosts
import client/extension/install
import client/extension/installed
import client/extension/manifest as extension_manifest
import client/extension/memory as extension_memory
import client/extension/record
import client/extension/source
import client/internal/ffi_os
import client/serve
import codemode/identity
import codemode/launch
import codemode/satellite
import core/clock
import core/entry
import core/ids
import core/json
import core/message
import core/msgpack
import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import machine/strand as machine_strand
import provider/stream
import runtime/api
import runtime/effects
import session/session
import simplifile
import support/extensions
import support/origin
import telemetry/log
import tools/tool

/// The value the operator's environment holds and nothing else may see.
/// Distinctive enough that a substring search over a few thousand frame
/// bytes means what it says.
const secret_value = "loom-fixture-secret-2f9c41ab"

/// The step every call in this module is dispatched under. Named so the
/// node's own step can be asserted against it: a node dispatched under
/// the caller's coordinates is the bug, not a detail.
const caller_step_id = "turn-1:tools"

/// How many requests one call of the fixture may make. Two, so a call
/// that asks for three proves the third is refused *and* that the first
/// two were not.
const requests_per_call = 2

/// The eunit test representation, built in Gleam: a constructor with
/// fields compiles to a tagged Erlang tuple, so `Timeout(60, body)` is
/// literally `{timeout, 60, Body}` — what eunit reads back from a
/// zero-arity `*_test_` *generator*. gleeunit runs eunit with
/// `ScaleTimeouts(10)`, applied to a generator's explicit timeout too, so
/// the number below is a tenth of the seconds it buys.
pub type EunitTest {
  Timeout(seconds: Int, body: fn() -> Nil)
}

/// The ceiling on the one test here. It spends a hermetic build (up to
/// 180 s of its own) and then three satellite launches, so a smaller
/// ceiling would substitute an anonymous eunit timeout for this suite's
/// own account of what happened.
const e2e_timeout_seconds = 1200

const gleeunit_timeout_scale = 10

pub fn an_installed_extension_reaches_the_network_test_() -> EunitTest {
  Timeout(e2e_timeout_seconds / gleeunit_timeout_scale, fn() { run_e2e() })
}

fn run_e2e() -> Nil {
  case prerequisites() {
    Error(reason) ->
      io.println("SKIP an_installed_extension_reaches_the_network: " <> reason)
    Ok(ready) -> drive(ready)
  }
}

// --- the drive --------------------------------------------------------------

type Ready {
  Ready(helper_path: String, seed_root: String, root: String)
}

fn drive(ready: Ready) -> Nil {
  // The origin first: its port is part of the manifest the install
  // approves, so nothing can be built until it is bound.
  let #(server, port, root_der) = origin.start()
  let host = "localhost:" <> int.to_string(port)
  let url = "https://" <> host <> "/get"

  case install_fixture(ready, host) {
    Error(reason) -> {
      origin.stop(server)
      io.println("SKIP an_installed_extension_reaches_the_network: " <> reason)
    }

    Ok(installed_at) -> {
      let taps = process.new_subject()
      let specs = process.new_subject()
      let hosts_name = process.new_name(prefix: "loom_e2e_hosts")
      let config =
        dispatch.Config(
          host: installed_at.host,
          hosts: hosts.seam(hosts_name, clock: wall_clock(), margin_ms: 20_000),
          // Only the fixture's own binding resolves. A lookup for
          // anything else answers `Error(Nil)`, which is what makes this
          // function's whole reach one variable.
          secrets: fn(name) {
            case name == extensions.fetcher_env {
              True -> Ok(secret_value)
              False -> Error(Nil)
            }
          },
          // The origin's own root, so the client's verification path runs
          // for real against a chain it was actually given. Production is
          // `SystemRoots` and nothing else in the tree is not.
          trust: egress.PinnedRoots(ders: [root_der]),
          launch: tapping(taps, specs),
          // The fetcher remembers nothing, and a door onto no session
          // says so in band rather than leaving `ext.remember` unrouted.
          memory: extension_memory.shut("this fixture has no session"),
        )

      // The registry a booting server would build, and the satellite
      // registry it would build beside it, from one configuration.
      let registry = contributed(config, installed_at)
      let assert Ok(_started) =
        hosts.start(hosts_name, wall_clock(), [
          dispatch.hosting(
            config,
            installed_at.record,
            installed_at.manifest,
            artifact: installed_at.artifact,
          ),
        ])
        as "the session's satellite registry must start"
      assert list.contains(tool.names(registry), "fetcher")

      // Every tool the registry offers is offered to the model, so the
      // manifest's snippet has to reach the prompt index.
      assert list.any(tool.snippets(registry), string.contains(
        _,
        "fetcher: fetch a url",
      ))

      let answered = call(registry, installed_at, url, times: 1)
      assert !answered.is_error
      let text = rendered(answered)
      assert string.contains(text, "1 ok 200 the origin answered")

      // The origin saw the credential, in the header the manifest bound
      // it to, having read it out of band rather than off the wire.
      let seen = string.join(list.flatten(origin.seen(server)), "\n")
      assert string.contains(
        string.lowercase(seen),
        "x-fixture-token: " <> secret_value,
      )

      // And the jail did not. Both halves of the node's environment: what
      // the launcher sets, and what the kernel will pass through at all.
      let assert Ok(spec) = process.receive(specs, within: 0)
        as "the launcher must have been handed a spec"

      // The node runs under an operation of its own, and not under the
      // one of whichever call launched it. `broker.abort(op_id)` is
      // issued at the end of every code-mode execution and by every node
      // teardown, so a node sharing an operation with a run would be
      // killed by the next ordinary thing that run finished — and every
      // hook-launched host shares one operation, so one teardown would
      // take them all. Read off the real spec, because this is the one
      // place the launch's own coordinates are visible.
      assert identity.step_id(spec.identity) == dispatch.host_step_id
      assert identity.step_id(spec.identity) != caller_step_id

      let node_env = launch.node_env(spec)
      assert !list.any(node_env, fn(pair) {
        pair.0 == extensions.fetcher_env
        || string.contains(pair.1, secret_value)
      })
      let #(now, _clock) = clock.read(wall_clock())
      assert !list.contains(
        launch.node_requirements(spec, now).env_allow,
        extensions.fetcher_env,
      )

      // Nor did any frame on the capability channel, in either
      // direction. The tap wraps the production launcher, so these are
      // the bytes the node was really sent and really sent back.
      let frames = drain(taps, [])
      assert frames != []
      assert !list.any(frames, fn(bytes) { carries(bytes, secret_value) })
      io.println(
        "extension egress e2e: "
        <> int.to_string(list.length(frames))
        <> " frames on the channel, none carrying the credential",
      )

      // The persistent shape's own claim: a second call reaches the same
      // node. Counted from the launcher's specs rather than inferred from
      // how quick it felt.
      let second = call(registry, installed_at, url, times: 1)
      assert !second.is_error
      assert string.contains(rendered(second), "1 ok 200 the origin answered")
      assert process.receive(specs, within: 250) == Error(Nil)
      io.println("extension host e2e: two invocations, one node launch")

      // And an event reaches the same node over the same channel. The
      // payload is empty because wave B is what fixes the per-event
      // shapes; what is proved here is that a hook_call of kind `event`
      // is dispatched to the handler the manifest's [[hook]] named.
      let greeted =
        hosts.invoke_event(
          hosts.seam(hosts_name, clock: wall_clock(), margin_ms: 20_000),
          extension: "fetcher",
          event: "session_start",
          args: msgpack.StringValue("{}"),
          at: dispatch.coordinates(live_ctx(
            installed_at.workspace,
            installed_at.base_policy,
          )),
          within: 20_000,
        )
      // `session_start` has nothing to answer, so `ext/hook` renders the
      // empty document; what is proved is that a `hook_call` of kind
      // `event` reached the handler the manifest's `[[hook]]` named.
      assert greeted == Ok(msgpack.StringValue("{}"))

      // A host the manifest does not name is refused in band, as a
      // `NetDenied` the extension read and turned into a sentence.
      let refused =
        call(registry, installed_at, "https://example.invalid/get", times: 1)
      assert !refused.is_error
      assert string.contains(rendered(refused), "1 denied")
      assert string.contains(rendered(refused), "example.invalid")

      // The refusal's frames are held to the same rule as the answer's.
      assert !list.any(drain(taps, []), fn(bytes) {
        carries(bytes, secret_value)
      })

      // And a call past the manifest's `requests_per_call` is refused in
      // band too, on the request after the ceiling — the first two are
      // still answered, which is what makes it a ceiling rather than a
      // failure.
      let capped =
        call(registry, installed_at, url, times: requests_per_call + 1)
      let capped_text = rendered(capped)
      assert string.contains(capped_text, "1 ok 200")
      assert string.contains(capped_text, "2 ok 200")
      assert string.contains(capped_text, "3 denied")
      assert string.contains(capped_text, "lifetime cap")
      assert !list.any(drain(taps, []), fn(bytes) {
        carries(bytes, secret_value)
      })

      // The reverse direction carrying what it was built for: a
      // `tool_call` verdict and a `context` transform, over a real jailed
      // satellite of their own.
      hooks_fire(installed_at)

      // Durable memory over two real satellites and two real sessions.
      memory_persists(installed_at)

      // The last claim, and the one only a real node can make: an
      // extension that does not answer inside its own deadline loses its
      // satellite, and says so on the call after.
      oversleeps(installed_at, hosts_name)

      origin.stop(server)
      stop(installed_at)
    }
  }
}

// The hook bus over a real satellite: install the `gatekeeper` fixture,
// give the bus this session's registry as its invoker, and drive the two
// planes the ruling gives a hook the most authority over.
//
// `hooks.gate` is what `client/extension/hooks.wire` calls from the
// clearance door, and its `Block` is what the driver turns into the
// `ClearanceRefused` the model reads; the attribution asserted here is
// the field that refusal carries. `hooks.fold_context` is the other
// plane, run on the caller's own process, and the transform asserted here
// is the one a provider request would be built from. Wave B's own tests
// pin the two wirings from those functions onward; what only a real node
// can prove — and what is proved here — is that a verdict and a message
// list crossed the capability channel and came back.
fn hooks_fire(installed_at: Installed) -> Nil {
  case install_beside(installed_at, extensions.gatekeeper(), "gatekeeper-src") {
    Error(reason) -> io.println("SKIP the gatekeeper extension: " <> reason)
    Ok(#(written, decoded, artifact)) -> {
      let hosts_name = process.new_name(prefix: "loom_e2e_gate")
      let seam = hosts.seam(hosts_name, clock: wall_clock(), margin_ms: 20_000)
      let config =
        dispatch.Config(
          host: installed_at.host,
          hosts: seam,
          secrets: fn(_name) { Error(Nil) },
          trust: egress.SystemRoots,
          launch: dispatch.jailed_node,
          memory: extension_memory.shut("this fixture has no session"),
        )
      let assert Ok(_started) =
        hosts.start(hosts_name, wall_clock(), [
          dispatch.hosting(config, written, decoded, artifact:),
        ])
        as "the gatekeeper's registry must start"

      let at =
        dispatch.coordinates(live_ctx(
          installed_at.workspace,
          installed_at.base_policy,
        ))
      let assert Ok(bus) =
        hooks.start(
          [
            hooks.Extension(
              name: written.name,
              events: list.map(decoded.hooks, fn(hook) { hook.event }),
              invoke: hosts.invoker(seam, at:),
            ),
          ],
          log.discard(),
        )
        as "the hook bus must start"

      let #(operation, _generator) =
        ids.mint_op(ids.generator(wall_clock(), seed: 20_260_903))

      // A call the extension refuses, refused with the extension named:
      // a block nobody is attributed for is one nobody can act on.
      let assert hooks.Block(extension:, reason:) =
        hooks.gate(
          bus,
          operation,
          extensions.gatekeeper_blocks,
          json.Object([]),
          0,
        )
        as "the gatekeeper must block the tool it names"
      assert extension == "gatekeeper"
      assert string.contains(reason, extensions.gatekeeper_blocks)

      // And a call it does not: a hook that blocked everything would
      // satisfy the assertion above and be useless.
      assert hooks.gate(bus, operation, "harmless", json.Object([]), 0)
        == hooks.Allow

      // The other plane. The transform ran inside the jail, over the
      // durable message format, and its answer is what a request would
      // be built from.
      let messages = [a_user_message("first"), a_user_message("second")]
      let folded = hooks.fold_context(bus, operation, messages)
      assert list.length(folded) == 3
      assert list.last(folded) == list.last(messages)

      // The third plane, phase 4c: a compaction that has already been
      // decided asks the jail for a note. The fixture echoes the cue
      // back, so a note carrying the reason word and the counts is a
      // note whose args document decoded inside the jail.
      let assert [note] =
        hooks.compaction_notes(bus, operation, a_compaction_cue())
        as "the jailed before_compact hook must answer with a note"
      assert string.contains(note, "<extension name=gatekeeper>")
      assert string.contains(note, "overflow/4242/9/2")

      // And the notify-only one. The bus tells the satellite and reads
      // nothing back, so the observable half here is that the extension
      // still holds its subscription: a crash, a deadline or an answer
      // the harness could not read would all have dropped it. The count
      // asked for is the notice manager's, because that is the one the
      // event was cast onto.
      hooks.usage(bus, operation, a_usage_row())
      assert hooks.subscribers(bus, on: hooks.Notifying) == 1

      // What the bus deliberately cannot see: a notification cannot
      // distinguish "answered the empty document" from "declined in
      // band", and the difference is exactly whether the ledger row
      // decoded inside the jail. So the answer itself is read through
      // the same invoker the bus uses.
      let assert Ok(msgpack.StringValue(value: answered)) =
        hosts.invoker(seam, at:)(
          "gatekeeper",
          extension_manifest.usage_event,
          usage_args(),
          hooks.deadline_ms,
        )
        as "the jailed usage hook must answer"
      assert answered == "{}"

      io.println(
        "extension host e2e: a jailed tool_call hook blocked a call, a "
        <> "jailed context hook appended a message, a jailed "
        <> "before_compact hook returned an attributed note and a jailed "
        <> "usage hook took a committed ledger row",
      )
    }
  }
}

// A cue whose every number is distinctive, so the echoed note is
// asserting on the field it means rather than on a zero that would
// match any of them.
fn a_compaction_cue() -> effects.CompactionCue {
  effects.CompactionCue(
    cause: effects.OverflowCompaction,
    tokens_before: 4242,
    summarized_messages: 9,
    retained_messages: 2,
  )
}

fn a_usage_row() -> entry.UsageRow {
  let #(id, _generator) =
    ids.mint_usage(ids.generator(wall_clock(), seed: 20_260_904))
  entry.UsageRow(
    id:,
    seq: 77,
    entry_id: None,
    adjustment: False,
    usage: message.Usage(
      input: 11,
      output: 22,
      cache_read: 0,
      cache_write: 0,
      cache_write_1h: None,
      reasoning: None,
      total_tokens: 33,
      cost: message.UsageCost(
        input: 0.0,
        output: 0.0,
        cache_read: 0.0,
        cache_write: 0.0,
        total: 0.0,
      ),
    ),
    details: None,
  )
}

// The `usage` args document, written out rather than built through the
// bus's own encoder. Both sides of a wire tested against one builder
// would drift together, which is the reasoning `ext/hook`'s own tests
// are written under.
fn usage_args() -> msgpack.MsgPackValue {
  msgpack.StringValue(
    "{\"op_id\":\"op-1\",\"usage_id\":\"u-1\",\"seq\":77,"
    <> "\"entry_id\":null,\"adjustment\":false,"
    <> "\"input_tokens\":11,\"output_tokens\":22,"
    <> "\"cache_read_tokens\":0,\"cache_write_tokens\":0,"
    <> "\"cache_write_1h_tokens\":null,\"thinking_tokens\":null,"
    <> "\"total_tokens\":33,\"cost\":0.0}",
  )
}

fn a_user_message(text: String) -> message.AgentMessage {
  message.UserMessage(
    content: [message.UserText(text:, text_signature: None)],
    timestamp: 0,
  )
}

// --- durable memory ---------------------------------------------------------

// Two installs of the `keeper` fixture under two names, one satellite
// each, and one session file underneath them — reopened halfway through.
//
// Three claims, and the first two are the ones only a real node can
// make. A tool remembers on one call and recalls on the next, over the
// same satellite. The session is then **closed and reopened** while the
// satellites go on running, and the same recall still answers — so the
// value came off the disk rather than out of the node's memory, which is
// the whole difference between this and `cap/kv`. And `keeper-two`,
// asking for the same key over its own satellite, finds nothing: the
// subtree is the extension's name, bound by the harness from the install
// record, and no argument on the channel contributes to it.
fn memory_persists(installed_at: Installed) -> Nil {
  case install_beside(installed_at, extensions.keeper(first_keeper), "k1-src") {
    Error(reason) -> io.println("SKIP the keeper extensions: " <> reason)
    Ok(one) ->
      case
        install_beside(installed_at, extensions.keeper(second_keeper), "k2-src")
      {
        Error(reason) ->
          io.println("SKIP the second keeper extension: " <> reason)
        Ok(two) -> keepers_remember(installed_at, one, two)
      }
  }
}

/// The two names the memory fixture is installed under. Two installs of
/// one source, because what is under test is whose subtree a cell lands
/// in — and the name is the only thing that differs.
const first_keeper = "keeper_one"

const second_keeper = "keeper_two"

fn keepers_remember(
  installed_at: Installed,
  one: #(record.Record, extension_manifest.Manifest, String),
  two: #(record.Record, extension_manifest.Manifest, String),
) -> Nil {
  let path = installed_at.live_root <> "/keeper-session.db"
  case open_session(path) {
    Error(reason) -> io.println("SKIP the keeper session: " <> reason)
    Ok(first) ->
      case open_runtime(first) {
        Error(reason) -> {
          let _sealed = session.close(first)
          io.println("SKIP the keeper runtime: " <> reason)
        }

        Ok(runtime) -> {
          // The door reads the runtime through a holder rather than
          // closing over one, which is what lets the session underneath
          // be replaced while the satellites stay up — the only
          // arrangement in which "it survived the reopen" is a claim
          // about the disk rather than about the node.
          let holder = start_holder(runtime)
          let registry =
            keeper_registry(installed_at, [one, two], borrowing(holder))

          let stored =
            keeper_call(
              registry,
              installed_at,
              first_keeper,
              Some("the origin was slow"),
            )
          assert string.contains(rendered(stored), "stored the origin was slow")

          let recalled = keeper_call(registry, installed_at, first_keeper, None)
          assert string.contains(
            rendered(recalled),
            "recalled the origin was slow",
          )
          io.println(
            "extension memory e2e: a jailed tool remembered on one call and "
            <> "recalled on the next",
          )

          // The session goes; the satellites stay.
          process.kill(runtime.tree.supervisor)
          let _sealed = session.close(first)

          case open_session(path) {
            Error(reason) -> io.println("SKIP the keeper reopen: " <> reason)
            Ok(second) ->
              case open_runtime(second) {
                Error(reason) -> {
                  let _closed = session.close(second)
                  io.println("SKIP the reopened keeper runtime: " <> reason)
                }

                Ok(reopened) -> {
                  process.send(holder, Held(runtime: reopened))
                  let after =
                    keeper_call(registry, installed_at, first_keeper, None)
                  assert string.contains(
                    rendered(after),
                    "recalled the origin was slow",
                  )

                  // And the other extension's own satellite, asking for
                  // the same key, finds nothing.
                  let elsewhere =
                    keeper_call(registry, installed_at, second_keeper, None)
                  assert string.contains(
                    rendered(elsewhere),
                    "recalled nothing",
                  )
                  io.println(
                    "extension memory e2e: the note survived the session "
                    <> "being reopened, and the second extension cannot see it",
                  )
                  process.kill(reopened.tree.supervisor)
                  let _closed = session.close(second)
                  Nil
                }
              }
          }
        }
      }
  }
}

// One keeper call through the registry, exactly as a strand's driver
// makes one. A `note` is a write and no `note` is a read, which is the
// fixture's whole argument schema.
fn keeper_call(
  registry: tool.Registry,
  installed_at: Installed,
  name: String,
  note: Option(String),
) -> tool.ToolOutcome {
  let arguments = case note {
    None -> json.Object([])
    Some(text) -> json.Object([#("note", json.String(text))])
  }
  tool.dispatch(
    registry,
    live_ctx(installed_at.workspace, installed_at.base_policy),
    name,
    arguments,
  )
}

// The registry and the satellite registry both keepers are reached
// through, over one memory door.
fn keeper_registry(
  installed_at: Installed,
  keepers: List(#(record.Record, extension_manifest.Manifest, String)),
  memory: extension_memory.Door,
) -> tool.Registry {
  let hosts_name = process.new_name(prefix: "loom_e2e_keepers")
  let config =
    dispatch.Config(
      host: installed_at.host,
      hosts: hosts.seam(hosts_name, clock: wall_clock(), margin_ms: 20_000),
      secrets: fn(_name) { Error(Nil) },
      trust: egress.SystemRoots,
      launch: dispatch.jailed_node,
      memory:,
    )
  let assert Ok(_started) =
    hosts.start(
      hosts_name,
      wall_clock(),
      list.map(keepers, fn(keeper) {
        let #(written, decoded, artifact) = keeper
        dispatch.hosting(config, written, decoded, artifact:)
      }),
    )
    as "the keepers' registry must start"
  let assert Ok(registry) =
    contributions.registry(
      list.map(keepers, fn(keeper) {
        let #(written, decoded, artifact) = keeper
        let assert Ok(tools) =
          dispatch.tools(
            config,
            written,
            decoded,
            sources: record.sources(installed_at.root, written.name),
            artifact:,
          )
          as "a really-installed keeper contributes its tool"
        contributions.Contribution(
          origin: contributions.Extension(name: written.name),
          tools:,
        )
      }),
    )
    as "two keepers of different names cannot collide"
  registry
}

// --- the session under the keepers ------------------------------------------

// A real session file, because "survives a reopen" is not a question an
// in-memory store can be asked.
fn open_session(path: String) -> Result(session.Session, String) {
  session.open_sqlite(
    path:,
    owner: "extension-memory-e2e",
    lease_ttl_ms: 60_000,
    clock: wall_clock(),
  )
  |> result.map_error(string.inspect)
}

fn open_runtime(opened: session.Session) -> Result(api.Runtime, String) {
  use entropy <- result.try(start_entropy())
  api.open(
    opened,
    effects.Effects(
      clock: wall_clock(),
      entropy:,
      timers: effects.real_timers(),
      provider: hanging_provider(),
      tools: refusing_tools(),
      hooks: effects.default_hooks(),
    ),
    api.default_options(
      machine_strand.StrandConfiguration(
        model: machine_strand.ModelIdentity(
          provider: "acme",
          model_id: "loom-1",
        ),
        thinking_level: machine_strand.ThinkingOff,
        active_tool_names: [],
      ),
    ),
  )
  |> result.map_error(string.inspect)
}

/// What the runtime holder is told when the session underneath it is
/// replaced.
type Holding {
  Held(runtime: api.Runtime)
  Borrow(reply: Subject(api.Runtime))
}

// The live runtime, in one actor, so the door can be built once and the
// session under it swapped. Production borrows through the Agency's
// holder for the same reason: the runtime is not a value the seam can
// close over.
fn start_holder(runtime: api.Runtime) -> Subject(Holding) {
  let assert Ok(started) =
    actor.new(runtime)
    |> actor.on_message(fn(held, message) {
      case message {
        Held(runtime:) -> actor.continue(runtime)
        Borrow(reply:) -> {
          process.send(reply, held)
          actor.continue(held)
        }
      }
    })
    |> actor.start
    as "the runtime holder must start"
  started.data
}

fn borrowing(holder: Subject(Holding)) -> extension_memory.Door {
  extension_memory.door(
    extension_memory.Wiring(runtime: fn() {
      Ok(process.call(holder, waiting: 5000, sending: Borrow))
    }),
  )
}

fn hanging_provider() -> effects.ProviderSurface {
  effects.ProviderSurface(timeout_ms: 30_000, request: fn(_spec) {
    stream.immediate(events: process.new_subject(), cancel: fn() { Nil })
  })
}

fn refusing_tools() -> effects.ToolSurface {
  effects.ToolSurface(
    clear: fn(_query) {
      effects.ClearanceRefused(reason: "the keeper session runs no tools")
    },
    run: fn(_run) {
      effects.ToolFailed(reason: "the keeper session runs no tools")
    },
    replay_still_safe: fn(_name) { False },
    execution_mode: fn(_name) { effects.ExclusiveExecution },
  )
}

fn start_entropy() -> Result(fn() -> Int, String) {
  actor.new(1)
  |> actor.on_message(fn(next, reply) {
    process.send(reply, next)
    actor.continue(next + 1)
  })
  |> actor.start
  |> result.map(fn(counter) {
    fn() { process.call(counter.data, waiting: 1000, sending: fn(r) { r }) }
  })
  |> result.replace_error("the entropy counter did not start")
}

// A second extension, installed for real beside the first, whose one tool
// sleeps in the kernel for far longer than its manifest allows.
//
// The deadline is the satellite host's, armed as the state timeout on the
// invocation it belongs to; when it fires the node is destroyed and the
// extension is out for the rest of the session. Both halves are asserted,
// because a deadline that ended the call without ending the node would
// leave a satellite the harness had stopped trusting still running.
fn oversleeps(
  installed_at: Installed,
  hosts_name: process.Name(hosts.Message),
) -> Nil {
  case install_beside(installed_at, extensions.sleeper(), "sleeper-src") {
    Error(reason) -> io.println("SKIP the oversleeping extension: " <> reason)
    Ok(#(written, decoded, artifact)) -> {
      let config =
        dispatch.Config(
          host: installed_at.host,
          hosts: hosts.seam(hosts_name, clock: wall_clock(), margin_ms: 20_000),
          secrets: fn(_name) { Error(Nil) },
          trust: egress.SystemRoots,
          launch: dispatch.jailed_node,
          memory: extension_memory.shut("this fixture has no session"),
        )
      let sleeper_hosts_name = process.new_name(prefix: "loom_e2e_sleeper")
      let assert Ok(_started) =
        hosts.start(sleeper_hosts_name, wall_clock(), [
          dispatch.hosting(
            dispatch.Config(
              ..config,
              hosts: hosts.seam(
                sleeper_hosts_name,
                clock: wall_clock(),
                margin_ms: 20_000,
              ),
            ),
            written,
            decoded,
            artifact:,
          ),
        ])
        as "the sleeper's registry must start"

      let seam =
        hosts.seam(sleeper_hosts_name, clock: wall_clock(), margin_ms: 20_000)
      let at =
        dispatch.coordinates(live_ctx(
          installed_at.workspace,
          installed_at.base_policy,
        ))
      let overslept =
        hosts.invoke(
          seam,
          extension: "sleeper",
          invocation: satellite.Tool(name: "sleeper"),
          args: tool_args("{}"),
          at:,
          within: extensions.sleeper_timeout_ms,
        )
      assert overslept == Error(hosts.Deadline)

      // And the node is gone rather than merely unanswered: the next
      // call never reaches a satellite at all.
      let assert Error(hosts.Gone(reason:)) =
        hosts.invoke(
          seam,
          extension: "sleeper",
          invocation: satellite.Tool(name: "sleeper"),
          args: tool_args("{}"),
          at:,
          within: extensions.sleeper_timeout_ms,
        )
        as "a destroyed satellite must stay destroyed for the session"
      io.println("extension host e2e: the oversleeper was reaped: " <> reason)
    }
  }
}

// The invocation envelope `ext/runtime` reads for a tool.
fn tool_args(args: String) -> msgpack.MsgPackValue {
  msgpack.MapValue([
    #(msgpack.StringValue("args"), msgpack.StringValue(args)),
    #(msgpack.StringValue("strand"), msgpack.StringValue("main")),
  ])
}

fn install_beside(
  installed_at: Installed,
  files: List(#(String, String)),
  directory: String,
) -> Result(#(record.Record, extension_manifest.Manifest, String), String) {
  let tree =
    extensions.materialise(files, installed_at.live_root <> "/" <> directory)
  case
    install.run(
      install.Config(
        root: installed_at.root,
        caps: archive.default_caps(),
        fetch: fn(_url, _max) {
          Error("an install from a local path fetches nothing")
        },
        build: cli.build_for(installed_at.plane, exec.BestEffort),
        clock: wall_clock(),
        entropy: fn() { 11 },
        approved_by: "operator",
      ),
      source.LocalPath(path: tree),
      rev: None,
    )
  {
    Error(failure) -> Error("it did not install: " <> install.describe(failure))
    Ok(done) ->
      case installed.one(installed_at.root, done.record.name) {
        installed.Refused(name: _, reason:) ->
          Error("the install did not discover: " <> reason)
        installed.Ready(record: written, manifest: decoded, artifact:) ->
          Ok(#(written, decoded, artifact))
      }
  }
}

// One dispatch through the registry, exactly as a strand's driver makes
// one: by name, with JSON arguments, against the contributed table.
fn call(
  registry: tool.Registry,
  installed_at: Installed,
  url: String,
  times times: Int,
) -> tool.ToolOutcome {
  tool.dispatch(
    registry,
    live_ctx(installed_at.workspace, installed_at.base_policy),
    "fetcher",
    json.Object([#("url", json.String(url)), #("times", json.Int(times))]),
  )
}

// The registry a booting server would build from this install: the
// extension's contribution alone, through the very seam `client/serve`
// puts it through, so a collision would refuse here as it would there.
fn contributed(
  config: dispatch.Config,
  installed_at: Installed,
) -> tool.Registry {
  let assert Ok(tools) =
    dispatch.tools(
      config,
      installed_at.record,
      installed_at.manifest,
      sources: record.sources(installed_at.root, installed_at.record.name),
      artifact: installed_at.artifact,
    )
    as "a really-installed extension contributes its tools"
  let assert Ok(registry) =
    contributions.registry([
      contributions.Contribution(
        origin: contributions.Extension(name: installed_at.record.name),
        tools:,
      ),
    ])
    as "one extension alone cannot collide"
  registry
}

// --- the tap ----------------------------------------------------------------

// The production launcher, with every byte in both directions copied to
// `frames` and the `LaunchSpec` copied to `specs`.
//
// Outbound is the easy half: `CapConnection.send` is the one way the
// harness writes to the node. Inbound needs a relay, because the launcher
// delivers to the subject the *host* created — so the tap hands the
// launcher a subject of its own and forwards, which is the only way to
// see a `cap_call` without reimplementing the launcher.
fn tapping(
  frames: Subject(BitArray),
  specs: Subject(satellite.LaunchSpec),
) -> fn(launch.LaunchConfig) -> satellite.Launcher {
  fn(config) {
    let inner = launch.launcher(config)
    fn(spec: satellite.LaunchSpec) {
      process.send(specs, spec)

      // The relay creates its own subject and hands it back, because a
      // subject may only be received on by the process that made it. A
      // subject made here and read there is the one shape this cannot
      // take.
      let handshake = process.new_subject()
      let host_wire = spec.wire
      let _relay =
        process.spawn_unlinked(fn() {
          let watched = process.new_subject()
          process.send(handshake, watched)
          relay(watched, host_wire, frames)
        })
      let assert Ok(watched) = process.receive(handshake, within: 5000)
        as "the wire tap's relay must start"
      case inner(satellite.LaunchSpec(..spec, wire: watched)) {
        Error(reason) -> Error(reason)
        Ok(connection) ->
          Ok(satellite.CapConnection(
            send: fn(bytes) {
              process.send(frames, bytes)
              connection.send(bytes)
            },
            destroy: connection.destroy,
          ))
      }
    }
  }
}

// Forwards the launcher's inbound events to the host, recording the
// bytes. Stops when the channel closes, which the host is told about
// before this process exits.
fn relay(
  from: Subject(satellite.WireIn),
  to: Subject(satellite.WireIn),
  frames: Subject(BitArray),
) -> Nil {
  case process.receive(from, within: 120_000) {
    Error(Nil) -> Nil

    Ok(satellite.WireBytes(data:) as event) -> {
      process.send(frames, data)
      process.send(to, event)
      relay(from, to, frames)
    }

    Ok(satellite.WireClosed(..) as event) -> process.send(to, event)
  }
}

// Every frame the tap recorded, waiting a moment for a straggler.
//
// Two processes send here — the relay and the host's own `send` closure —
// so ordering against `tool.dispatch` returning is only pairwise
// guaranteed. A zero timeout would make a late frame a *weaker*
// assertion rather than a failure, which is the wrong direction for a
// test whose whole claim is that no frame carried the credential.
fn drain(taps: Subject(BitArray), found: List(BitArray)) -> List(BitArray) {
  case process.receive(taps, within: 250) {
    Ok(bytes) -> drain(taps, [bytes, ..found])
    Error(Nil) -> found
  }
}

// Whether a frame's bytes hold the credential anywhere. The channel
// speaks msgpack, whose string payloads are the raw UTF-8 bytes, so a
// substring search over the frame is exactly the right question: a
// credential on the wire in any field would be these bytes contiguously.
fn carries(bytes: BitArray, value: String) -> Bool {
  case bit_array.to_string(bytes) {
    Ok(text) -> string.contains(text, value)
    // Not text as a whole — msgpack frames rarely are — so search the
    // encoding of the value against the raw bytes instead.
    Error(Nil) -> contains_bytes(bytes, <<value:utf8>>)
  }
}

fn contains_bytes(haystack: BitArray, needle: BitArray) -> Bool {
  let size = bit_array.byte_size(needle)
  case bit_array.byte_size(haystack) < size {
    True -> False
    False ->
      case bit_array.slice(haystack, 0, size) {
        Ok(front) if front == needle -> True
        Ok(_other) | Error(Nil) ->
          case bit_array.slice(haystack, 1, bit_array.byte_size(haystack) - 1) {
            Ok(rest) -> contains_bytes(rest, needle)
            Error(Nil) -> False
          }
      }
  }
}

// --- the install ------------------------------------------------------------

type Installed {
  Installed(
    root: record.Root,
    record: record.Record,
    manifest: extension_manifest.Manifest,
    artifact: String,
    host: codemode_wiring.Config,
    workspace: String,
    base_policy: policy.SandboxPolicy,
    plane: serve.BuildPlane,
    live_root: String,
  )
}

// A real install of the `fetcher` fixture: a real fetchless acquisition
// from a local path, a real package vet against the extension seam, and a
// real offline `gleam build` inside a network-off jail — the same build a
// code-mode program gets, from the same seed, under the same base.
fn install_fixture(ready: Ready, host: String) -> Result(Installed, String) {
  let live_root = ready.root
  let workspace = live_root <> "/work"
  let extensions_root = record.root_at(live_root <> "/ext")
  let staging = record.path(extensions_root) <> "/.staging"
  let _made = simplifile.create_directory_all(staging)
  let _worked = simplifile.create_directory_all(workspace <> "/tmp")

  use plane <- result.try(serve.start_build_plane(
    helper: Some(ready.helper_path),
    seed: Some(ready.seed_root),
    workspace: repository_root(),
    writable: live_root,
    tmp_dir: staging,
    // A real wall clock: the broker turns `deadline - now` into a receive
    // timeout, and a fixture clock behind the deadline produces one
    // Erlang refuses outright.
    clock: wall_clock(),
  ))

  let tree =
    extensions.materialise(
      extensions.fetcher(origin: host, per_call: requests_per_call),
      live_root <> "/src",
    )
  let outcome =
    install.run(
      install.Config(
        root: extensions_root,
        caps: archive.default_caps(),
        fetch: fn(_url, _max) {
          Error("an install from a local path fetches nothing")
        },
        build: cli.build_for(plane, exec.BestEffort),
        clock: wall_clock(),
        entropy: fn() { 7 },
        approved_by: "operator",
      ),
      source.LocalPath(path: tree),
      rev: None,
    )

  case outcome {
    Error(failure) -> {
      serve.stop_build_plane(plane)
      Error("the fixture did not install: " <> install.describe(failure))
    }

    Ok(done) -> {
      io.println(
        "extension egress e2e: " <> install.enforcement_line(done.enforcement),
      )
      case installed.one(extensions_root, done.record.name) {
        installed.Refused(name: _, reason:) -> {
          serve.stop_build_plane(plane)
          Error("the fixture install did not discover: " <> reason)
        }

        installed.Ready(record: written, manifest: decoded, artifact:) ->
          Ok(Installed(
            root: extensions_root,
            record: written,
            manifest: decoded,
            artifact:,
            // The host configuration a booting server would build, over
            // the plane's own broker and toolchain: an extension
            // satellite is the same node under the same base as a
            // code-mode one, and building it any other way here would
            // prove something about a configuration nobody ships.
            host: codemode_wiring.default_config(
              broker: plane.broker,
              clock: wall_clock(),
              workspace:,
              toolchain: plane.toolchain,
            ),
            workspace:,
            base_policy: plane.base_policy,
            plane:,
            live_root:,
          ))
      }
    }
  }
}

fn stop(installed_at: Installed) -> Nil {
  serve.stop_build_plane(installed_at.plane)
  let _removed = simplifile.delete_all([installed_at.live_root])
  Nil
}

// --- the context ------------------------------------------------------------

fn live_ctx(workspace: String, base: policy.SandboxPolicy) -> tool.Ctx {
  let wall = wall_clock()
  let #(op, _generator) = ids.mint_op(ids.generator(wall, seed: 20_260_902))
  tool.Ctx(
    workspace:,
    strand: "main",
    op_id: op,
    step_id: caller_step_id,
    source_index: 0,
    base_policy: base,
    grants: [],
    // The kernels this runs on vary; what is under test is the wiring,
    // and the install's own enforcement line says which layers held.
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/local/bin:/usr/bin:/bin")],
    clock: wall,
    filesystem: no_filesystem(),
    blob_root: workspace <> "/.blobs",
    clear_call: fn(_spec, _events) { Error(broker.BrokerUnavailable) },
    raise_refusal: tool.no_raise(),
  )
}

fn no_filesystem() -> tool.FileSystem {
  tool.FileSystem(
    read: fn(path) { Error(tool.FsNotFound(path:)) },
    write: fn(path, _bytes) { Error(tool.FsNotFound(path:)) },
    create_directory_all: fn(path) { Error(tool.FsNotFound(path:)) },
    is_file: fn(_path) { Ok(False) },
    read_link: fn(_path) { Ok(tool.LinkMissing) },
    rename: fn(from, _to) { Error(tool.FsNotFound(path: from)) },
  )
}

fn rendered(outcome: tool.ToolOutcome) -> String {
  outcome.content
  |> list.map(fn(block) {
    case block {
      message.ToolResultText(text:, text_signature: _) -> text
      message.ToolResultImage(..) -> ""
    }
  })
  |> string.join("\n")
}

// --- prerequisites ----------------------------------------------------------

fn prerequisites() -> Result(Ready, String) {
  use Nil <- result.try(platform_prerequisite())
  let repo = repository_root()
  let helper_path = repo <> "/bin/loom-exec"
  let seed_root = repo <> "/build/codemode-seed"
  use Nil <- result.try(case simplifile.is_file(helper_path) {
    Ok(True) -> Ok(Nil)
    Ok(False) | Error(_) ->
      Error("no loom-exec at " <> helper_path <> "; run `make binaries`")
  })
  use _toolchain <- result.try(codemode_wiring.discover(seed_root))
  use root <- result.try(live_root())
  Ok(Ready(helper_path:, seed_root:, root:))
}

fn platform_prerequisite() -> Result(Nil, String) {
  case exec.unjailed_skip_reason(exec.host_platform()) {
    Some(reason) -> Error(reason)
    None -> Ok(Nil)
  }
}

// A shallow base, and never `/tmp`: the jail replaces `/tmp` with its own
// scratch tmpfs, and the cap socket lives under this root and has about a
// hundred bytes to spend.
fn live_root() -> Result(String, String) {
  let discriminator =
    token.production_entropy()(4)
    |> bit_array.base16_encode
    |> string.lowercase
  let root = "/var/tmp/.loom-ext-e2e-" <> discriminator
  case simplifile.create_directory_all(root) {
    Ok(Nil) -> Ok(root)
    Error(error) ->
      Error(
        "no extension end-to-end root at "
        <> root
        <> ": "
        <> simplifile.describe_error(error),
      )
  }
}

fn repository_root() -> String {
  let assert Ok(here) = simplifile.current_directory()
    as "the working directory must be readable"
  here <> "/../.."
}

fn wall_clock() -> clock.Clock {
  clock.from_function(ffi_os.system_time_ms)
}
