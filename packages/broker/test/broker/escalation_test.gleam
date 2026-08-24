import broker/escalation
import broker/policy

fn denial() -> escalation.Denial {
  escalation.Denial(
    reason: "network off, wants registry.npmjs.org",
    source: escalation.PolicyDenial,
    wanted: [
      policy.GrantNetwork(policy.NetworkProxy(
        allow: ["registry.npmjs.org"],
        proxy: "127.0.0.1:9",
      )),
      policy.GrantEnv("NPM_TOKEN"),
    ],
  )
}

pub fn raise_emits_event_test() {
  let #(raised, event) = escalation.raise("esc-1", denial())
  assert event == escalation.EscalationRaised("esc-1", denial())
  assert escalation.status(raised) == escalation.StatusPending
  assert escalation.id(raised) == "esc-1"
  assert escalation.denial(raised) == denial()
}

pub fn approve_then_consume_once_test() {
  let #(raised, _) = escalation.raise("esc-1", denial())
  let grants = denial().wanted
  let assert Ok(#(approved, event)) = escalation.approve(raised, grants)
  assert event == escalation.EscalationApproved("esc-1", grants)
  assert escalation.status(approved) == escalation.StatusApproved

  // Exactly one re-execution: the first consume yields the grants...
  let assert Ok(#(consumed, granted, event)) = escalation.consume(approved)
  assert granted == grants
  assert event == escalation.EscalationConsumed("esc-1", grants)
  assert escalation.status(consumed) == escalation.StatusConsumed

  // ...and the second is refused.
  assert escalation.consume(consumed)
    == Error(escalation.NotApproved(status: escalation.StatusConsumed))
}

pub fn partial_approval_narrows_test() {
  let #(raised, _) = escalation.raise("esc-2", denial())
  let subset = [policy.GrantEnv("NPM_TOKEN")]
  let assert Ok(#(approved, _)) = escalation.approve(raised, subset)
  let assert Ok(#(_, granted, _)) = escalation.consume(approved)
  assert granted == subset
}

pub fn approval_cannot_widen_beyond_wanted_test() {
  let #(raised, _) = escalation.raise("esc-3", denial())
  let rider = policy.GrantNetwork(policy.NetworkFull)
  assert escalation.approve(raised, [rider])
    == Error(escalation.GrantNotWanted(grant: rider))
}

pub fn reject_blocks_consume_test() {
  let #(raised, _) = escalation.raise("esc-4", denial())
  let assert Ok(#(rejected, event)) = escalation.reject(raised)
  assert event == escalation.EscalationRejected("esc-4")
  assert escalation.status(rejected) == escalation.StatusRejected
  assert escalation.consume(rejected)
    == Error(escalation.NotApproved(status: escalation.StatusRejected))
}

pub fn pending_cannot_consume_test() {
  let #(raised, _) = escalation.raise("esc-5", denial())
  assert escalation.consume(raised)
    == Error(escalation.NotApproved(status: escalation.StatusPending))
}

pub fn approve_twice_refused_test() {
  let #(raised, _) = escalation.raise("esc-6", denial())
  let assert Ok(#(approved, _)) = escalation.approve(raised, [])
  assert escalation.approve(approved, [])
    == Error(escalation.NotPending(status: escalation.StatusApproved))
  assert escalation.reject(approved)
    == Error(escalation.NotPending(status: escalation.StatusApproved))
}

pub fn execution_denial_carries_enforcement_test() {
  let execution =
    escalation.Denial(
      reason: "degraded",
      source: escalation.ExecutionDenial(enforcement: ["skip:bwrap: not found"]),
      wanted: [],
    )
  let #(raised, _) = escalation.raise("esc-7", execution)
  let assert escalation.ExecutionDenial(enforcement:) =
    escalation.denial(raised).source
  assert enforcement == ["skip:bwrap: not found"]
}
