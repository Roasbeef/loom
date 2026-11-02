//// The jail a project worker runs under, derived from its Mandate.
////
//// Three things are claimed here. The mapping is a function of the Mandate's
//// authority and nothing else, so two Mandates that differ only in who asked,
//// which source carried it, how it was admitted or which policy version wrote
//// it derive the same jail. The mapping is monotone: a Mandate of explicit
//// strength never gets less than an inferred one, in the network, in the
//// approval route or in the tools. And the jail does what it says when it
//// meets the real broker and the real escalation seam.
////
//// The broker here is the production one. Its helper pool is empty, so a call
//// the broker accepts stops at the checkout of a helper and runs nothing. That
//// is enough for what is claimed, which is the broker's decision about the
//// policy: a call it refuses on policy returns `PolicyRefused` before any
//// helper is asked for, and a call it accepts returns any other answer. No
//// kernel jail is started, so nothing here depends on the platform.
////
//// The escalation seam that reaches a person is a recording stand-in. It is the
//// only fake, and it marks the line the claim is about: a refused call under a
//// worker whose approvals are refused must not cross it.

import broker/broker
import broker/budget
import broker/escalation
import broker/exec
import broker/policy as broker_policy
import broker/token
import client/escalate
import client/owned_assembly_test
import client/project_jail
import client/project_standing
import client/serve
import core/clock
import core/ids
import core/json
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import project/model
import project/policy
import qcheck
import tools/project as tools

const seed = 20_261_102

fn config() -> qcheck.Config {
  qcheck.default_config() |> qcheck.with_seed(qcheck.seed(seed))
}

// --- generators ------------------------------------------------------------------------

fn one_of(values: List(a)) -> qcheck.Generator(a) {
  let assert [first, ..rest] = values as "a generator needs a value"
  qcheck.from_generators(qcheck.return(first), list.map(rest, qcheck.return))
}

fn basis() -> qcheck.Generator(model.Basis) {
  qcheck.from_generators(
    one_of([
      model.FromComposer,
      model.FromAddressed,
      model.FromFollowUp,
      model.FromOverheard,
      model.FromAutomation,
    ]),
    [
      qcheck.map(qcheck.string(), fn(rule) {
        model.FromRule(model.RuleId(rule))
      }),
    ],
  )
}

// A Mandate whose every field is arbitrary, including the rule that admitted
// it and the policy version.
fn mandate() -> qcheck.Generator(model.Mandate) {
  qcheck.map6(
    one_of([model.Explicit, model.Inferred]),
    basis(),
    qcheck.map(qcheck.string(), model.ActorId),
    qcheck.map(qcheck.string(), model.SourceId),
    qcheck.tuple2(
      qcheck.string(),
      one_of([model.ApprovalsGranted, model.ApprovalsNotGranted]),
    ),
    qcheck.string(),
    fn(strength, basis, actor, source, scope, policy_version) {
      model.Mandate(
        strength:,
        basis:,
        actor:,
        source:,
        scope: model.Scope(scope.0, scope.1),
        policy_version:,
      )
    },
  )
}

fn owner_with(
  network: broker_policy.NetworkPolicy,
) -> broker_policy.SandboxPolicy {
  broker_policy.SandboxPolicy(
    ..broker_policy.workspace_default("/work/clone"),
    network:,
  )
}

// The owner's session policies a worker may be started under: the shipped
// default (no network), a configured full network, and a proxy allowlist.
fn owner() -> qcheck.Generator(broker_policy.SandboxPolicy) {
  one_of([
    owner_with(broker_policy.NetworkOff),
    owner_with(broker_policy.NetworkFull),
    owner_with(broker_policy.NetworkProxy(["example.test"], "127.0.0.1:9")),
  ])
}

fn jail(
  mandate: model.Mandate,
  owner: broker_policy.SandboxPolicy,
) -> project_jail.Jail {
  project_jail.jail_for(policy.for_mandate(mandate), owner)
}

// --- the mapping -----------------------------------------------------------------------

pub fn mandates_differing_only_outside_authority_derive_one_jail_test() {
  use #(mandate, other, owner) <- qcheck.run(
    config(),
    qcheck.tuple3(mandate(), mandate(), owner()),
  )

  // The first Mandate keeps its strength and its approval grant, which are the
  // authority fields, and takes the rest from the second.
  let varied =
    model.Mandate(
      strength: mandate.strength,
      basis: other.basis,
      actor: other.actor,
      source: other.source,
      scope: model.Scope(other.scope.workspace, mandate.scope.approvals),
      policy_version: other.policy_version,
    )
  assert jail(varied, owner) == jail(mandate, owner)
}

pub fn a_stronger_mandate_never_gets_less_in_any_dimension_test() {
  use #(mandate, owner, name) <- qcheck.run(
    config(),
    qcheck.tuple3(mandate(), owner(), qcheck.string()),
  )
  let explicit = jail(model.Mandate(..mandate, strength: model.Explicit), owner)
  let inferred = jail(model.Mandate(..mandate, strength: model.Inferred), owner)

  // The network is ordered, and the explicit worker has the owner's own.
  assert project_jail.network_rank(explicit.sandbox.network)
    >= project_jail.network_rank(inferred.sandbox.network)
  assert explicit.sandbox.network == owner.network

  // Only the network differs between the two sandboxes.
  assert broker_policy.SandboxPolicy(..inferred.sandbox, network: owner.network)
    == explicit.sandbox

  // Approvals are ordered, and a tool the inferred worker may name is one the
  // explicit worker may name too.
  assert policy.approval_rank(explicit.approvals)
    >= policy.approval_rank(inferred.approvals)
  assert !project_jail.allows(inferred.tools, name)
    || project_jail.allows(explicit.tools, name)
}

pub fn the_tool_ceiling_refuses_the_peer_and_agent_tools_at_both_strengths_test() {
  use #(mandate, owner) <- qcheck.run(
    config(),
    qcheck.tuple2(mandate(), owner()),
  )
  let worker = jail(mandate, owner)
  assert !project_jail.allows(worker.tools, "agent_send")
  assert !project_jail.allows(worker.tools, "peer_send")
  assert project_jail.allows(worker.tools, "bash")
  assert project_jail.allows(worker.tools, "project_report")
}

// --- the real broker -------------------------------------------------------------------

fn broker_without_helpers() -> broker.Broker {
  let assert Ok(started) =
    broker.start(
      broker.BrokerConfig(
        entropy: token.production_entropy(),
        clock: clock.fixed(at: 0),
        checkout: fn() { Error(exec.AllBusy(size: 0)) },
        checkin: fn(_helper) { Nil },
      ),
    )
    as "the broker starts"
  started
}

fn op() -> ids.OpId {
  let generator = ids.generator(clock.fixed(at: 1_700_000_000_000), seed: 5)
  let #(op_id, _) = ids.mint_op(generator)
  op_id
}

// What a worker's tool call is cleared as: the worker's base policy, and a tool
// that asks for the given network.
fn clear(
  worker: project_jail.Jail,
  wanting: broker_policy.NetworkPolicy,
) -> Result(broker.CallHandle, broker.Refusal) {
  let started = broker_without_helpers()
  let spec =
    broker.CallSpec(
      op_id: op(),
      step_id: "step-1",
      base_policy: worker.sandbox,
      requirements: broker_policy.SandboxPolicy(
        ..worker.sandbox,
        network: wanting,
      ),
      grants: [],
      response: broker.RefuseNarrowed,
      demand: exec.BestEffort,
      argv: ["/bin/true"],
      env: [],
      cwd: "/work/clone",
      budget: budget.Budget(max_outstanding: 4, deadline_ms: 100_000),
    )
  let answer =
    broker.clear_call(
      started,
      spec,
      events: process.new_subject(),
      waiting: 2000,
    )
  broker.stop(started)
  answer
}

fn inferred(approvals: model.ApprovalGrant) -> model.Mandate {
  model.Mandate(
    strength: model.Inferred,
    basis: model.FromOverheard,
    actor: model.ActorId("someone"),
    source: model.SourceId("github"),
    scope: model.Scope("/work/clone", approvals),
    policy_version: "v1",
  )
}

fn explicit() -> model.Mandate {
  model.Mandate(
    ..inferred(model.ApprovalsNotGranted),
    strength: model.Explicit,
    basis: model.FromComposer,
    source: model.SourceId("composer"),
  )
}

pub fn an_inferred_worker_is_refused_a_network_an_explicit_worker_is_given_test() {
  let owner = owner_with(broker_policy.NetworkFull)
  let weak = jail(inferred(model.ApprovalsNotGranted), owner)
  let strong = jail(explicit(), owner)

  // A tool that asks for the open network, as a download of an arbitrary host
  // would. The inferred worker's broker refuses it on policy and names the
  // network grant that would satisfy it. The explicit worker's is accepted: it
  // goes on to ask for a helper, which this broker has none of.
  let assert Error(broker.PolicyRefused(denial)) =
    clear(weak, broker_policy.NetworkFull)
  assert denial.source == escalation.PolicyDenial
  assert denial.wanted
    == [broker_policy.GrantNetwork(broker_policy.NetworkFull)]
  let assert Error(broker.NoHelper(..)) =
    clear(strong, broker_policy.NetworkFull)
}

pub fn an_inferred_worker_still_runs_commands_that_need_no_network_test() {
  let owner = owner_with(broker_policy.NetworkFull)
  let weak = jail(inferred(model.ApprovalsNotGranted), owner)

  // The shell asks for whatever its base allows, so a worker confined to no
  // network can still build and test offline.
  let assert Error(broker.NoHelper(..)) = clear(weak, weak.sandbox.network)
}

pub fn a_registry_allowlist_is_not_enforceable_and_fails_closed_for_both_test() {
  let owner = owner_with(broker_policy.NetworkFull)
  let registries =
    broker_policy.NetworkProxy(project_jail.registry_hosts, "127.0.0.1:9")

  // No proxy exists to enforce the list, so the broker narrows it to no
  // network and refuses the call as unenforceable, whatever the strength. This
  // pins the gap the module documents: until a proxy exists, "registries only"
  // is enforced as "none".
  let assert Error(broker.PolicyRefused(..)) =
    clear(jail(inferred(model.ApprovalsNotGranted), owner), registries)
  let assert Error(broker.PolicyRefused(..)) =
    clear(jail(explicit(), owner), registries)
}

// --- the real approval route -----------------------------------------------------------

// A refused call as the escalation seam receives it, with the denial the real
// broker produced for a worker that asked for the open network.
fn refused(denial: escalation.Denial) -> escalate.Refused {
  escalate.Refused(
    operation: op(),
    strand: "main",
    step_id: "step-1",
    source_index: 0,
    call_id: "call-1",
    tool: "bash",
    denial:,
    arguments: json.Object([]),
    deadline_ms: 100_000,
  )
}

fn denial_for(worker: project_jail.Jail) -> escalation.Denial {
  let assert Error(broker.PolicyRefused(denial)) =
    clear(worker, broker_policy.NetworkFull)
  denial
}

// The seam that reaches a person. It records each refusal it is shown and
// answers with an approval, so a refusal that crosses it is visible both ways.
fn person() -> #(escalate.Escalations, process.Subject(String)) {
  let seen = process.new_subject()
  let seam =
    escalate.Escalations(refused: fn(shown) {
      process.send(seen, shown.call_id)
      escalate.Resume([])
    })
  #(seam, seen)
}

pub fn an_inferred_workers_approval_request_reaches_no_one_test() {
  let owner = owner_with(broker_policy.NetworkOff)
  let weak = jail(inferred(model.ApprovalsNotGranted), owner)
  let #(seam, seen) = person()
  let routed = project_jail.escalations(weak.approvals, seam)

  // The refusal settles in band, and the person's seam is never called.
  assert routed.refused(refused(denial_for(weak))) == escalate.Settle
  assert process.receive(seen, 100) == Error(Nil)
}

pub fn a_rule_that_grants_approvals_sends_them_to_a_person_test() {
  let owner = owner_with(broker_policy.NetworkOff)
  let granted = jail(inferred(model.ApprovalsGranted), owner)
  let #(seam, seen) = person()
  let routed = project_jail.escalations(granted.approvals, seam)
  assert routed.refused(refused(denial_for(granted))) == escalate.Resume([])
  assert process.receive(seen, 100) == Ok("call-1")
}

pub fn an_explicit_workers_approval_request_reaches_a_person_test() {
  let owner = owner_with(broker_policy.NetworkOff)
  let strong = jail(explicit(), owner)
  let #(seam, seen) = person()
  let routed = project_jail.escalations(strong.approvals, seam)
  assert routed.refused(refused(denial_for(strong))) == escalate.Resume([])
  assert process.receive(seen, 100) == Ok("call-1")
}

// --- the session the daemon builds -----------------------------------------------------

fn seat_with(
  standing: project_standing.Standing,
  jail: Option(project_jail.Jail),
) -> project_standing.Seat {
  let nothing = tools.Unavailable("this test has no project")
  project_standing.Seat(
    standing:,
    seam: tools.Projects(
      route: fn(_, _) { Error(nothing) },
      read: fn(_, _) { Error(nothing) },
      reply: fn(_, _) { Error(nothing) },
      report: fn(_, _) { Error(nothing) },
      handback: fn(_, _) { Error(nothing) },
    ),
    feed: None,
    run_ended: None,
    workspace: "/workspace",
    jail:,
  )
}

pub fn a_worker_session_is_built_on_its_jails_base_policy_test() {
  let owner =
    serve.Settings(
      ..owned_assembly_test.settings(),
      base_policy: owner_with(broker_policy.NetworkFull),
    )
  let worker = project_standing.Worker("p", "t-a", 1)
  let weak = jail(inferred(model.ApprovalsNotGranted), owner.base_policy)
  let strong = jail(explicit(), owner.base_policy)

  // The explicit worker's base is the owner's. The inferred worker's has no
  // network, and nothing else of the owner's policy moves.
  let explicit_session =
    serve.seat_project(owner, seat_with(worker, Some(strong)))
  assert explicit_session.base_policy == owner.base_policy
  let inferred_session =
    serve.seat_project(owner, seat_with(worker, Some(weak)))
  assert inferred_session.base_policy
    == broker_policy.SandboxPolicy(
      ..owner.base_policy,
      network: broker_policy.NetworkOff,
    )

  // A worker seated with no jail at all fails closed to the same base.
  let sealed = serve.seat_project(owner, seat_with(worker, None))
  assert sealed.base_policy == inferred_session.base_policy

  // A router keeps the owner's policy, since the Mandate rules a worker's jail.
  let router =
    serve.seat_project(owner, seat_with(project_standing.Router("p"), None))
  assert router.base_policy == owner.base_policy
}
