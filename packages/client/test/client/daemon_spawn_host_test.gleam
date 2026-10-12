//// The daemon's spawn host judges a message by the node it came from
//// (protocol-change/084, slice S1). A node that no `[spawners.<name>]` names is
//// refused as an unknown spawner, and a node that one names is refused as not
//// served yet, because the delegate session that would serve it is slice S2.
//// Neither is a crash and neither is silence.

import client/daemon/main
import client/remote_spawn.{Attached, CallSite, Origin, Parent, Request}
import client/spawners
import core/clock
import core/ids
import gleam/option.{None}
import tools/agent

const distribution =
  "[distribution]
node = \"box@100.64.0.9\"
ca = \"/etc/loom/ca.pem\"
certificate = \"/etc/loom/cert.pem\"
key = \"/etc/loom/key.pem\"
cookie = \"/home/loom/.erlang.cookie\"

[[distribution.peers]]
node = \"laptop@100.64.0.5\"
sha256 = \"0000000000000000000000000000000000000000000000000000000000000001\"

[profiles.cheap-review.roles]
main = [\"fast\"]

[spawners.laptop]
node = \"laptop@100.64.0.5\"
directory = \"/srv/loom/scratch\"
profile = \"cheap-review\"
"

fn operation() -> ids.OpId {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 7))
  operation
}

fn origin(node: String) -> remote_spawn.Origin {
  Origin(node:, parent: Parent(session: "s1", strand: "main"))
}

fn request() -> remote_spawn.Request {
  Request(
    purpose: "run the suite",
    brief: "Run make e2e.",
    model: None,
    tools: None,
    within_ms: None,
    result_schema: None,
    detach: Attached,
  )
}

fn call_site() -> remote_spawn.CallSite {
  CallSite(
    operation: operation(),
    step_id: "step-1",
    source_index: 0,
    minter: agent.ToolCall,
  )
}

pub fn a_node_no_spawner_names_is_an_unknown_spawner_for_all_three_test() {
  let assert Ok(configured) = spawners.parse(distribution)
  let host = main.spawn_host(configured)
  let stranger = origin("stranger@10.0.0.9")
  let refusal = remote_spawn.UnknownSpawner(node: "stranger@10.0.0.9")
  assert host.spawn(stranger, call_site(), 0, [], request()) == Error(refusal)
  assert host.join(stranger, [], 1000) == Error(refusal)
  assert host.run_ended(stranger, operation()) == Error(refusal)
}

pub fn a_daemon_with_no_spawners_refuses_every_node_test() {
  let host = main.spawn_host([])
  let laptop = origin("laptop@100.64.0.5")
  let refusal = remote_spawn.UnknownSpawner(node: "laptop@100.64.0.5")
  assert host.spawn(laptop, call_site(), 0, [], request()) == Error(refusal)
  assert host.join(laptop, [], 1000) == Error(refusal)
  assert host.run_ended(laptop, operation()) == Error(refusal)
}

pub fn a_configured_spawner_is_refused_as_not_served_yet_test() {
  let assert Ok(configured) = spawners.parse(distribution)
  let host = main.spawn_host(configured)
  let laptop = origin("laptop@100.64.0.5")
  let refusal = remote_spawn.Unimplemented
  assert host.spawn(laptop, call_site(), 0, [], request()) == Error(refusal)
  assert host.join(laptop, [], 1000) == Error(refusal)
  assert host.run_ended(laptop, operation()) == Error(refusal)
}
