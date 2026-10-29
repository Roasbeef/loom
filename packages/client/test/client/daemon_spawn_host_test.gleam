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
import client/peer_mail
import client/remote/remote_spawner
import client/remote_spawn.{Attached, CallSite, Origin, Parent, Request}
import client/spawners.{type Spawner}
import core/clock
import core/ids
import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import telemetry/field
import telemetry/level
import telemetry/log
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
  Sent(remote_spawn.Parent, agent.Handle, String, String)
  Released
  Read(remote_spawn.Parent, agent.Handle, Int, Int)
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
    send: fn(parent, child, message_id, text) {
      process.send(heard, Sent(parent, child, message_id, text))
      Ok(json.Null)
    },
    history: fn(parent, child, cursor, limit) {
      process.send(heard, Read(parent, child, cursor, limit))
      Ok(json.Object([]))
    },
    occupancy: fn() { agency.Vacant },
    resolve: fn(_parent, _child, _id, _decision, _seq, _decider) {
      Error(remote_spawn.StoreFailure(reason: "not under test"))
    },
  )
}

pub fn a_node_no_spawner_names_is_an_unknown_spawner_for_all_five_test() {
  let host =
    main.spawn_host(
      configured(),
      fn(_, _) { panic as "an unknown node must not reach a session" },
      fn(_, _) { panic as "an unknown node must not release a session" },
      fn(_, _) { panic as "an unknown node must not look for a session" },
      log.discard(),
    )
  let stranger = origin("stranger@10.0.0.9")
  let refusal = remote_spawn.UnknownSpawner(node: "stranger@10.0.0.9")
  assert host.spawn(stranger, call_site(), 0, [], request()) == Error(refusal)
  assert host.join(stranger, [], 1000) == Error(refusal)
  assert host.run_ended(stranger, operation()) == Error(refusal)
  assert host.release(stranger) == Error(refusal)
  assert host.send(stranger, a_child(), "m1", "hello") == Error(refusal)
  assert host.history(stranger, a_child(), 0, 50) == Error(refusal)
}

pub fn a_daemon_with_no_spawners_refuses_every_node_test() {
  let host =
    main.spawn_host(
      [],
      fn(_, _) { panic as "a daemon with no spawners must not reach a session" },
      fn(_, _) { panic as "a daemon with no spawners must not release one" },
      fn(_, _) { panic as "a daemon with no spawners must not look for one" },
      log.discard(),
    )
  let laptop = origin("laptop@100.64.0.5")
  let refusal = remote_spawn.UnknownSpawner(node: "laptop@100.64.0.5")
  assert host.spawn(laptop, call_site(), 0, [], request()) == Error(refusal)
  assert host.join(laptop, [], 1000) == Error(refusal)
  assert host.run_ended(laptop, operation()) == Error(refusal)
  assert host.release(laptop) == Error(refusal)
  assert host.send(laptop, a_child(), "m1", "hello") == Error(refusal)
}

fn a_child() -> agent.Handle {
  agent.Handle(strand: "sub:^main/run-the-suite-1", operation: operation())
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
      fn(spawner, parent) {
        process.send(asked, #(spawner.name, parent))
        Ok(option.Some(recording(heard)))
      },
      log.discard(),
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

  // A send reaches the same session with the parent, the child, the message's
  // identity and its text, and nothing else of the origin.
  assert host.send(laptop, a_child(), "m1", "also the tests") == Ok(json.Null)
  assert process.receive(heard, 0)
    == Ok(Sent(laptop.parent, a_child(), "m1", "also the tests"))

  // Each message asked for the session of the spawner's name and the parent it
  // named, and for no other.
  assert process.receive(asked, 0) == Ok(#("laptop", laptop.parent))
  assert process.receive(asked, 0) == Ok(#("laptop", laptop.parent))
  assert process.receive(asked, 0) == Ok(#("laptop", laptop.parent))
  assert process.receive(asked, 0) == Ok(#("laptop", laptop.parent))

  // A release is not one of those: it asks the function that finds a session
  // that already exists, with the same spawner and parent, and the function
  // that finds or makes one is never asked, so a release cannot create a session.
  assert host.release(laptop) == Ok(4)
  assert process.receive(released, 0) == Ok(#("laptop", laptop.parent))
  assert process.receive(asked, 0) == Error(Nil)

  // The spawner's table names no `transcript`, so its children's transcripts
  // stay here: a read is refused before any session is looked for.
  assert host.history(laptop, a_child(), 0, 50)
    == Error(remote_spawn.TranscriptHidden)
}

pub fn a_refusal_to_find_the_session_is_the_answer_to_each_message_test() {
  let refusal = remote_spawn.CapReached(cap: remote_spawn.MaxSessions, limit: 4)
  let host =
    main.spawn_host(
      configured(),
      fn(_, _) { Error(refusal) },
      fn(_, _) { Error(refusal) },
      fn(_, _) { Error(refusal) },
      log.discard(),
    )
  let laptop = origin("laptop@100.64.0.5")
  assert host.spawn(laptop, call_site(), 0, [], request()) == Error(refusal)
  assert host.join(laptop, [], 1000) == Error(refusal)
  assert host.run_ended(laptop, operation()) == Error(refusal)
  assert host.release(laptop) == Error(refusal)
}

// The receiver records admission and delegate refusals without copying any
// peer-controlled reason or request content into the diagnostic.
pub fn spawn_receiver_logs_only_fixed_refusal_classes_test() {
  let records = process.new_subject()
  let logger = log.new(sink: log.to_subject(records), threshold: level.Warning)
  let canary = "sensitive-canary-in-reason"
  let host =
    main.spawn_host(
      configured(),
      fn(_, _) { Error(remote_spawn.InvalidArgument(canary)) },
      fn(_, _) { Ok(0) },
      fn(_, _) { Ok(None) },
      logger,
    )
  let stranger = origin("untrusted-canary-node")
  let sensitive_request =
    Request(
      ..request(),
      brief: canary,
      model: Some(canary),
      tools: Some([canary]),
    )
  assert host.spawn(stranger, call_site(), 0, [], sensitive_request)
    == Error(remote_spawn.UnknownSpawner("untrusted-canary-node"))
  let assert Ok(first) = process.receive(records, 0)
  assert first.event == "remote_spawn.receiver_refused"
  assert list.contains(first.fields, field.text("class", "unknown_spawner"))
  assert list.contains(
    first.fields,
    field.text("peer", "untrusted-canary-node"),
  )
  assert list.contains(first.fields, field.text("step", "step-1"))
  assert list.contains(first.fields, field.text("minter", "tool"))
  assert !list.any(first.fields, fn(item) { item.key == "program_ordinal" })
  assert !string.contains(string.inspect(first.fields), canary)

  assert host.spawn(origin("laptop@100.64.0.5"), call_site(), 0, [], request())
    == Error(remote_spawn.InvalidArgument(canary))
  let assert Ok(second) = process.receive(records, 0)
  assert second.event == "remote_spawn.receiver_refused"
  assert list.contains(second.fields, field.text("class", "invalid_argument"))
  assert !string.contains(string.inspect(second.fields), canary)
  assert !string.contains(string.inspect(second.fields), "Run make e2e.")

  let cap = remote_spawn.CapReached(remote_spawn.MaxSessions, 4)
  let capped =
    main.spawn_host(
      configured(),
      fn(_, _) { Error(cap) },
      fn(_, _) { Ok(0) },
      fn(_, _) { Ok(None) },
      logger,
    )
  assert capped.spawn(
      origin("laptop@100.64.0.5"),
      CallSite(..call_site(), minter: agent.Program(3)),
      0,
      [],
      request(),
    )
    == Error(cap)
  let assert Ok(third) = process.receive(records, 0)
  assert third.event == "remote_spawn.receiver_refused"
  assert list.contains(third.fields, field.text("class", "cap_max_sessions"))
  assert list.contains(third.fields, field.text("peer", "laptop@100.64.0.5"))
  assert list.contains(third.fields, field.text("minter", "program"))
  assert list.contains(third.fields, field.count("program_ordinal", 3))

  let waiting =
    main.spawn_host(
      configured(),
      fn(_, _) { Error(remote_spawn.NotYetOpen(canary)) },
      fn(_, _) { Ok(0) },
      fn(_, _) { Ok(None) },
      logger,
    )
  assert waiting.spawn(
      origin("laptop@100.64.0.5"),
      call_site(),
      0,
      [],
      request(),
    )
    == Error(remote_spawn.NotYetOpen(canary))
  assert process.receive(records, 0) == Error(Nil)
}

// The sending call records the typed answer before it becomes model-facing
// prose, while retryable answers continue to mean unreachable.
pub fn spawn_sender_logs_only_fixed_refusal_classes_test() {
  let records = process.new_subject()
  let logger = log.new(sink: log.to_subject(records), threshold: level.Warning)
  let refusal = remote_spawn.CapReached(remote_spawn.MaxSessions, 4)
  assert remote_spawner.spawn_answer(
      Ok(Error(refusal)),
      logger,
      call_site(),
      Some("box@100.64.0.9"),
    )
    == Error(peer_mail.Refused(remote_spawn.describe_refusal(refusal)))
  let assert Ok(first) = process.receive(records, 0)
  assert first.event == "remote_spawn.sender_refused"
  assert list.contains(first.fields, field.text("class", "cap_max_sessions"))
  assert list.contains(first.fields, field.count("source_index", 0))
  assert list.contains(first.fields, field.text("peer", "box@100.64.0.9"))
  assert list.contains(first.fields, field.text("step", "step-1"))
  assert list.contains(first.fields, field.text("minter", "tool"))
  assert !list.any(first.fields, fn(item) { item.key == "program_ordinal" })

  let canary = "sensitive-canary-in-store-failure"
  let failure = remote_spawn.StoreFailure(canary)
  assert remote_spawner.spawn_answer(
      Ok(Error(failure)),
      logger,
      call_site(),
      Some("box@100.64.0.9"),
    )
    == Error(peer_mail.Refused(remote_spawn.describe_refusal(failure)))
  let assert Ok(second) = process.receive(records, 0)
  assert second.event == "remote_spawn.sender_refused"
  assert list.contains(second.fields, field.text("class", "store_failure"))
  assert !string.contains(string.inspect(second.fields), canary)

  let tool = remote_spawn.ToolOutsideCeiling(canary)
  assert remote_spawner.spawn_answer(
      Ok(Error(tool)),
      logger,
      call_site(),
      Some("box@100.64.0.9"),
    )
    == Error(peer_mail.Refused(remote_spawn.describe_refusal(tool)))
  let assert Ok(third) = process.receive(records, 0)
  assert list.contains(
    third.fields,
    field.text("class", "tool_outside_ceiling"),
  )
  assert !string.contains(string.inspect(third.fields), canary)
  assert remote_spawner.spawn_answer(
      Ok(Error(remote_spawn.NotYetOpen(canary))),
      logger,
      call_site(),
      Some("box@100.64.0.9"),
    )
    == Error(peer_mail.Unreachable)
  assert process.receive(records, 0) == Error(Nil)

  let destination = peer_mail.Refused("unconfigured-canary")
  assert remote_spawner.spawn_answer(
      Error(destination),
      logger,
      call_site(),
      Some("unconfigured-canary"),
    )
    == Error(destination)
  let assert Ok(fourth) = process.receive(records, 0)
  assert list.contains(fourth.fields, field.text("class", "not_configured"))
  assert !string.contains(string.inspect(fourth.fields), "unconfigured-canary")

  let program_site = CallSite(..call_site(), minter: agent.Program(7))
  assert remote_spawner.spawn_answer(
      Ok(Error(refusal)),
      logger,
      program_site,
      Some("box@100.64.0.9"),
    )
    == Error(peer_mail.Refused(remote_spawn.describe_refusal(refusal)))
  let assert Ok(fifth) = process.receive(records, 0)
  assert list.contains(fifth.fields, field.text("minter", "program"))
  assert list.contains(fifth.fields, field.count("program_ordinal", 7))
}
