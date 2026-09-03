//// The session's satellite registry, without a satellite.
////
//// Everything the registry decides *before* it reaches a node is
//// decidable here: whether an extension is known, and — the case this
//// module exists for — whether the caller of a queued invocation is
//// still waiting for it. `hosts.Extension` is three fields and two of
//// them are functions, so a test hands over a recipe that records what
//// it was asked to launch and launches nothing.
////
//// The node's own behaviour is `packages/codemode`'s `host_test`, over a
//// fake satellite peer, and the whole path end to end is
//// `client/extension_e2e_test`'s over a real jailed one.

import broker/exec
import broker/policy
import client/extension/hosts
import client/internal/ffi_os
import codemode/satellite
import core/clock.{type Clock}
import core/ids
import core/msgpack
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/string

// --- a caller that gave up leaves no work behind --------------------------

/// The registry performs each invocation on its own timeline, so a
/// caller's message outlives the caller's patience. Without the expiry
/// this pins, the actor would go on to make the call for real — a
/// model-made tool call, possibly a POST, executed after the model was
/// told the extension could not be reached, or a `context` transform
/// delivered into a request that settled minutes ago.
///
/// The launch is what is counted, because it is the first thing the
/// registry does on the way to a node: an invocation that never reaches
/// `Extension.start` never reaches a `hook_call` either. Three extensions
/// rather than one, because a second call on the *same* extension would
/// find its host already departed and launch nothing whatever this actor
/// decided — which would be a test that passes without the code it is
/// about.
pub fn an_expired_invocation_is_never_performed_test() {
  let launches = process.new_subject()
  let name = process.new_name(prefix: "loom_hosts_expiry")
  let assert Ok(_started) =
    hosts.start(name, wall(), [
      recipe("slow", launches, holding_for_ms: 1500),
      recipe("stale", launches, holding_for_ms: 0),
      recipe("probe", launches, holding_for_ms: 0),
    ])
    as "the registry must start"

  // The first caller occupies the actor for well over a second, inside
  // the launch it is waiting on.
  process.spawn_unlinked(fn() {
    let _answer = ask("slow", margin_ms: 20_000, within: 5000, over: name)
    Nil
  })

  // Waited for, not assumed: the second caller has to arrive while the
  // first is being served, and a spawn that has not been scheduled yet
  // would let it be served first and answered on time.
  let assert Ok("slow") = process.receive(launches, 5000)
    as "the first caller's launch must be under way"

  // The second is queued behind it and stops waiting almost at once, so
  // by the time the actor reaches its message it is stale.
  let assert Error(hosts.Gone(reason:)) =
    ask("stale", margin_ms: 0, within: 100, over: name)
    as "a caller that gave up is answered rather than served"
  assert string.contains(reason, "did not answer in time")

  // A third, still wanted, and sent after the second: the actor answers
  // in arrival order, so this answer is proof that the stale message has
  // been reached and dealt with. That is what makes the assertion below
  // a fact rather than a sleep long enough to look like one.
  let _probed = ask("probe", margin_ms: 20_000, within: 5000, over: name)

  // "slow" was taken off this subject above, so what is left is every
  // launch the actor attempted after it. "stale" is absent, and that
  // absence is the whole test.
  assert launched(launches) == ["probe"]
}

// --- fixtures --------------------------------------------------------------

// An extension whose launch records its name, takes `holding_for_ms`, and
// then fails. The failure is the point as much as the delay: what is
// under test is what the actor *attempted*, and a recipe that never
// returns a host keeps this module free of satellites entirely.
fn recipe(
  name: String,
  launches: Subject(String),
  holding_for_ms holding_for_ms: Int,
) -> hosts.Extension {
  hosts.Extension(
    name:,
    start: fn(_at) {
      process.send(launches, name)
      process.sleep(holding_for_ms)
      Error("this test launches no node")
    },
    invoking: fn(_at) {
      panic as "a recipe that launches nothing is never invoked against"
    },
  )
}

fn ask(
  extension: String,
  margin_ms margin_ms: Int,
  within within: Int,
  over name: process.Name(hosts.Message),
) -> Result(msgpack.MsgPackValue, hosts.HookFailure) {
  hosts.invoke(
    hosts.seam(name, clock: wall(), margin_ms:),
    extension:,
    invocation: satellite.Tool(name: "anything"),
    args: msgpack.MapValue([]),
    at: coordinates(),
    within:,
  )
}

fn launched(launches: Subject(String)) -> List(String) {
  list.reverse(drain(launches, []))
}

fn drain(launches: Subject(String), seen: List(String)) -> List(String) {
  case process.receive(launches, 100) {
    Ok(name) -> drain(launches, [name, ..seen])
    Error(Nil) -> seen
  }
}

fn wall() -> Clock {
  clock.from_function(ffi_os.system_time_ms)
}

fn coordinates() -> hosts.Coordinates {
  let #(op_id, _generator) =
    ids.mint_op(ids.generator(clock.fixed(at: 0), seed: 11))
  hosts.Coordinates(
    op_id:,
    step_id: "step-1",
    strand: "main",
    workspace: "/work",
    base_policy: policy.workspace_default("/work"),
    demand: exec.BestEffort,
    env: [#("PATH", "/usr/bin")],
  )
}
