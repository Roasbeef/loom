//// The daemon's spawn host judges a message by the node it came from
//// (protocol-change/084). A node that no `[spawners.<name>]` names is refused
//// as an unknown spawner before any session is looked for, and a node that one
//// names is served by the Agency of that spawner's delegate session for the
//// parent the message names, under the terms of the spawner's table.
////
//// The sessions themselves are the registry's and `delegate_host`'s business,
//// and the Agency's behaviour is `agency_test`'s. Here the resolver is a fake
//// that records what it was asked and what the Agency was then told.

import client/agency
import client/daemon/main
import client/remote_spawn.{Attached, CallSite, Origin, Parent, Request}
import client/spawners.{type Spawner}
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
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
max_depth = 2
max_within_s = 7200
default_within_s = 900
tools = [\"bash\", \"agent_note\"]
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

fn configured() -> List(Spawner) {
  let assert Ok(found) = spawners.parse(distribution)
  found
}

// What the Agency of a delegate session was asked, as text, in the order asked.
type Heard {
  Spawn(remote_spawn.Delegation)
  Join(remote_spawn.Parent, Int)
  Ended(ids.OpId)
  Released
}

fn recording(heard: Subject(Heard)) -> agency.DelegateEndpoint {
  agency.DelegateEndpoint(
    spawn: fn(delegation, _site, _request) {
      process.send(heard, Spawn(delegation))
      Error(remote_spawn.StoreFailure(reason: "recorded"))
    },
    join: fn(parent, _handles, within_ms) {
      process.send(heard, Join(parent, within_ms))
      Ok([])
    },
    run_ended: fn(ended) {
      process.send(heard, Ended(ended))
      Ok(3)
    },
    release: fn() {
      process.send(heard, Released)
      Ok(4)
    },
  )
}

pub fn a_node_no_spawner_names_is_an_unknown_spawner_for_all_four_test() {
  let host =
    main.spawn_host(
      configured(),
      fn(_, _) { panic as "an unknown node must not reach a session" },
      fn(_, _) { panic as "an unknown node must not release a session" },
    )
  let stranger = origin("stranger@10.0.0.9")
  let refusal = remote_spawn.UnknownSpawner(node: "stranger@10.0.0.9")
  assert host.spawn(stranger, call_site(), 0, [], request()) == Error(refusal)
  assert host.join(stranger, [], 1000) == Error(refusal)
  assert host.run_ended(stranger, operation()) == Error(refusal)
  assert host.release(stranger) == Error(refusal)
}

pub fn a_daemon_with_no_spawners_refuses_every_node_test() {
  let host =
    main.spawn_host(
      [],
      fn(_, _) { panic as "a daemon with no spawners must not reach a session" },
      fn(_, _) { panic as "a daemon with no spawners must not release one" },
    )
  let laptop = origin("laptop@100.64.0.5")
  let refusal = remote_spawn.UnknownSpawner(node: "laptop@100.64.0.5")
  assert host.spawn(laptop, call_site(), 0, [], request()) == Error(refusal)
  assert host.join(laptop, [], 1000) == Error(refusal)
  assert host.run_ended(laptop, operation()) == Error(refusal)
  assert host.release(laptop) == Error(refusal)
}

pub fn a_configured_spawner_is_served_by_its_delegate_agency_test() {
  let heard = process.new_subject()
  let asked = process.new_subject()
  let released = process.new_subject()
  let host =
    main.spawn_host(
      configured(),
      fn(spawner, parent) {
        process.send(asked, #(spawner.name, parent))
        Ok(recording(heard))
      },
      fn(spawner, parent) {
        process.send(released, #(spawner.name, parent))
        Ok(4)
      },
    )
  let laptop = origin("laptop@100.64.0.5")

  // The spawn carries the parent's depth and tools as the message gave them,
  // with the spawner's table as the terms, in milliseconds.
  assert host.spawn(laptop, call_site(), 1, ["bash", "peer_send"], request())
    == Error(remote_spawn.StoreFailure(reason: "recorded"))
  let assert Ok(Spawn(delegation)) = process.receive(heard, 0)
  assert delegation
    == remote_spawn.Delegation(
      parent: laptop.parent,
      depth: 1,
      parent_tools: ["bash", "peer_send"],
      terms: remote_spawn.Terms(
        ceiling: ["bash", "agent_note"],
        max_depth: 2,
        max_within_ms: 7_200_000,
        default_within_ms: 900_000,
      ),
    )

  // A join and a run end go to the Agency of the same parent's session.
  assert host.join(laptop, [], 1000) == Ok([])
  assert process.receive(heard, 0) == Ok(Join(laptop.parent, 1000))
  assert host.run_ended(laptop, operation()) == Ok(3)
  assert process.receive(heard, 0) == Ok(Ended(operation()))

  // Each message asked for the session of the spawner's name and the parent it
  // named, and for no other.
  assert process.receive(asked, 0) == Ok(#("laptop", laptop.parent))
  assert process.receive(asked, 0) == Ok(#("laptop", laptop.parent))
  assert process.receive(asked, 0) == Ok(#("laptop", laptop.parent))

  // A release is not one of those: it asks the function that finds a session
  // that already exists, with the same spawner and parent, and the function
  // that finds or makes one is never asked, so a release cannot create a session.
  assert host.release(laptop) == Ok(4)
  assert process.receive(released, 0) == Ok(#("laptop", laptop.parent))
  assert process.receive(asked, 0) == Error(Nil)
}

pub fn a_refusal_to_find_the_session_is_the_answer_to_each_message_test() {
  let refusal = remote_spawn.CapReached(cap: remote_spawn.MaxSessions, limit: 4)
  let host =
    main.spawn_host(configured(), fn(_, _) { Error(refusal) }, fn(_, _) {
      Error(refusal)
    })
  let laptop = origin("laptop@100.64.0.5")
  assert host.spawn(laptop, call_site(), 0, [], request()) == Error(refusal)
  assert host.join(laptop, [], 1000) == Error(refusal)
  assert host.run_ended(laptop, operation()) == Error(refusal)
  assert host.release(laptop) == Error(refusal)
}
