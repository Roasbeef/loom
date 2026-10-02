//// Measures the directory door's additional copy cost in a real gateway.
////
//// The gateway must retain its executable Runtime. Comparing otherwise equal
//// initialized states with and without directory administration separates that
//// required ownership from an additional callback path. These are isolated
//// fixtures and flat term words, not measurements of the installed daemon.

import broker/policy
import client/directories
import client/gateway
import client/gateway_test
import core/clock
import core/ids
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/system
import gleam/string
import runtime/api
import runtime/effects
import session/session
import storage/storage
import support/addresses
import support/internal/ffi_memory

// The unrelated executor payload is deliberately a list of heap tuples. A
// large refcounted binary would not represent ordinary process-copy cost.
fn with_executor_payload(runtime: api.Runtime, words: Int) -> api.Runtime {
  let payload =
    list.repeat(Nil, words) |> list.index_map(fn(_, n) { #(n, n + 1, n + 2) })
  let tools =
    effects.ToolSurface(..runtime.effects.tools, run: fn(_request) {
      effects.ToolFailed(reason: string.inspect(payload))
    })
  api.Runtime(..runtime, effects: effects.Effects(..runtime.effects, tools:))
}

fn directory_admin(runtime: api.Runtime) -> directories.Admin {
  let facts = api.fact_handle(runtime)
  directories.admin_with_facts(
    runtime.session,
    fn() { Ok(facts) },
    "/",
    policy.workspace_default("/"),
  )
}

// Only application State is copied back from this isolated fixture. Startup
// Options and the supervisor restart specifications are separate owners and
// are not included in this number.
fn initialized_state_words(
  runtime: api.Runtime,
  admin: Option(directories.Admin),
) -> Int {
  let options = gateway.default_options("directory-capture", runtime)
  let options = case admin {
    None -> options
    Some(admin) -> gateway.with_directories(options, admin)
  }
  let name = addresses.new()
  let assert Ok(_) = gateway.start_host_fixture(options, name)
    as "the isolated gateway must initialize"
  let assert Ok(pid) = addresses.owner(name)
    as "the initialized gateway owns its State"
  let words = pid |> system.get_state |> ffi_memory.flat_words

  // These gateways are standalone children of the test, not the runtime
  // supervisor. Observe shutdown before returning rather than leaving their
  // teardown to session close or the test process's eventual exit.
  process.unlink(pid)
  let monitor = process.monitor(pid)
  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  process.send_abnormal_exit(pid, "shutdown")
  let assert Ok(_) = process.selector_receive(stopped, 1000)
    as "the measured gateway must acknowledge termination"
  assert !process.is_alive(pid)
  words
}

fn session_with_renewal_payload(opened: session.Session, words: Int) {
  let payload =
    list.repeat(Nil, words) |> list.index_map(fn(_, n) { #(n, n + 1, n + 2) })
  session.Session(..opened, renew_lease: fn() {
    case list.is_empty(payload) {
      True -> Error(storage.HandleClosed)
      False -> Ok(Nil)
    }
  })
}

/// Unused policy and lease fields do not reach the directory callbacks.
///
/// ## Examples
///
/// ```gleam
/// // This fixture isolates each outer input from the Runtime supplier.
/// ```
pub fn directory_admin_projects_policy_and_session_test() {
  let assert Ok(opened) = session.open_memory(clock.fixed(1000))
    as "the capture-only session must open"
  let base = policy.workspace_default("/")
  let heavy_policy =
    policy.SandboxPolicy(
      ..base,
      env_allow: list.repeat("UNUSED", 4096),
      readable_roots: list.repeat("/unused", 4096),
      writable_roots: list.repeat("/unused", 4096),
    )
  let small = directories.admin(opened, fn() { Error(Nil) }, "/", base)
  let large = directories.admin(opened, fn() { Error(Nil) }, "/", heavy_policy)
  let light_session = session_with_renewal_payload(opened, 1)
  let heavy_session = session_with_renewal_payload(opened, 4096)
  let light_read =
    directories.admin(light_session, fn() { Error(Nil) }, "/", base)
  let heavy_read =
    directories.admin(heavy_session, fn() { Error(Nil) }, "/", base)

  assert ffi_memory.flat_words(heavy_policy)
    > ffi_memory.flat_words(base) + 8192
  assert ffi_memory.flat_words(large.add) == ffi_memory.flat_words(small.add)
  assert ffi_memory.flat_words(heavy_read.read)
    - ffi_memory.flat_words(light_read.read)
    == 0
  assert ffi_memory.flat_words(heavy_session)
    > ffi_memory.flat_words(light_session) + 8192
  assert session.close(opened) == Ok(Nil)
}

/// The directory door adds constant state beyond the required Runtime.
///
/// ## Examples
///
/// ```gleam
/// // Run this fixture through scripts/test.sh client --match directory_capture.
/// ```
pub fn directory_admin_additional_state_cost_is_constant_test() {
  let id = ids.mint_session(ids.generator(clock.fixed(1000), 641)).0
  let harness = gateway_test.reserved_fixture(id)
  let light = with_executor_payload(harness.runtime, 1)
  let heavy = with_executor_payload(harness.runtime, 4096)
  let small = directory_admin(light)
  let large = directory_admin(heavy)

  // Runtime owns execution, while production mutation retains a projected
  // writer capability. Only the legitimate execution path may grow here.
  let runtime_growth =
    ffi_memory.flat_words(heavy) - ffi_memory.flat_words(light)
  let add_growth =
    ffi_memory.flat_words(large.add) - ffi_memory.flat_words(small.add)
  assert runtime_growth > 8192
  assert ffi_memory.flat_words(large.read) == ffi_memory.flat_words(small.read)

  let bare_small = initialized_state_words(light, None)
  let bare_large = initialized_state_words(heavy, None)
  let admin_small = initialized_state_words(light, Some(small))
  let admin_large = initialized_state_words(heavy, Some(large))
  let bare_growth = bare_large - bare_small
  let admin_growth = admin_large - admin_small

  // The control retains one Runtime. The production-shaped directory door
  // contributes constant cost after genuine actor startup and state transfer.
  assert bare_growth == runtime_growth
  assert admin_growth == bare_growth
  assert admin_large - bare_large == admin_small - bare_small
  assert add_growth == 0
  let assert Ok(Nil) = api.close(harness.runtime)
    as "the measured runtime must close"
}
