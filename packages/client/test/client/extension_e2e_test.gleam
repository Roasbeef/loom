//// An installed extension, dispatched for real: a jailed build at
//// install, a jailed satellite per call, a brokered `net.request` to a
//// real TLS origin, and a credential that reaches the origin without ever
//// reaching the jail.
////
//// This is phase 2's exit criterion minus the model. The orchestrator's
//// real drive is what proves a provider calls `web_search`; what is
//// proved here is everything under that: the registry contribution, the
//// `ext.call` hand-over, the `net.request` arm, the egress policy the
//// manifest translated to, the per-execution request ceiling, and the two
//// absence claims the whole design rests on —
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
import client/extension/install
import client/extension/installed
import client/extension/manifest as extension_manifest
import client/extension/record
import client/extension/source
import client/internal/ffi_os
import client/serve
import codemode/launch
import codemode/satellite
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
import simplifile
import support/extensions
import support/origin
import tools/tool

/// The value the operator's environment holds and nothing else may see.
/// Distinctive enough that a substring search over a few thousand frame
/// bytes means what it says.
const secret_value = "loom-fixture-secret-2f9c41ab"

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
const e2e_timeout_seconds = 600

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
      let config =
        dispatch.Config(
          host: installed_at.host,
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
        )

      let registry = contributed(config, installed_at)
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

      // A host the manifest does not name is refused in band, as a
      // `NetDenied` the extension read and turned into a sentence.
      let refused =
        call(registry, installed_at, "https://example.invalid/get", times: 1)
      assert !refused.is_error
      assert string.contains(rendered(refused), "1 denied")
      assert string.contains(rendered(refused), "example.invalid")

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

      origin.stop(server)
      stop(installed_at)
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

fn drain(taps: Subject(BitArray), found: List(BitArray)) -> List(BitArray) {
  case process.receive(taps, within: 0) {
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
    step_id: "turn-1:tools",
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
