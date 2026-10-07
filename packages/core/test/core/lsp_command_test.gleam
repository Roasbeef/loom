//// Original LSP identities keep startup, finite search and timing disjoint.

import core/clock
import core/generation as g
import core/ids
import core/lsp_command as l
import core/msgpack as m
import core/remote_tool as r
import core/workspace as w
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

fn fixture(tag: Int) {
  let generator = ids.generator(clock.fixed(1000), 41)
  let #(session, generator) = ids.mint_session(generator)
  let #(op, generator) = ids.mint_op(generator)
  let #(request, _) = ids.mint_entry(generator)
  let assert Ok(selector) = w.selector("executor", "workspace")
    as "The selector is valid."
  let assert Ok(binding) = w.registered_binding(selector, 1, 1)
    as "The binding is valid."
  let scope = w.scope(session, binding)
  let assert Ok(step) = w.step("lsp.query") as "The original step is valid."
  let assert Ok(digest) = g.digest(<<0:size(256)>>)
    as "The original digest has exactly 32 bytes."
  let assert Ok(system) = r.system_child(session, "lsp", 2)
    as "The actual system lease origin is valid."
  let assert Ok(tool) =
    r.key(session, op, "lsp.query", 0, string.repeat("0", 64), request)
    as "The existing admitted tool has complete original coordinates."
  let assert Ok(origin) =
    r.tool_child(
      tool,
      r.AdmittedCapability("lsp.definition", 0, r.SemanticWorkspace),
    )
    as "The finite query retains its original admitted capability origin."
  let assert Ok(input) = l.semantic_input(<<0x91, tag>>, digest, tag)
    as "The checked codec supplied bounded semantic bytes."
  let assert Ok(child) =
    l.original_child_ref(origin, scope, op, step, request, digest)
    as "The original complete child is valid."
  let assert Ok(parent) = l.parent_control(child)
    as "The original control reference fits its bound."
  let assert Ok(capture) =
    l.lsp_capture(
      origin,
      scope,
      op,
      step,
      request,
      input,
      parent,
      digest,
      digest,
    )
    as "The original capture matches its complete child."
  let assert Ok(era) = l.clock_era("00000000-0000-4000-8000-000000000001")
    as "The trusted clock era has canonical UUID spelling."
  let anchor = l.finite_anchor(era, digest, digest)
  let assert Ok(control) =
    l.verify_parent_control(capture, parent, 500_000, 0, case tag {
      9 -> Some(0)
      _ -> None
    })
    as "The actual original parent has remaining time."
  let assert Ok(proposal) = l.finite_timing_proposal(anchor, control, digest)
    as "The causal timing uses that actual parent."
  let assert Ok(invocation) = l.lsp_invocation(capture, proposal, digest)
    as "The timed original retains that proposal."
  let assert Ok(lease) =
    l.lsp_service_key(system, scope, op, step, request, digest, digest, digest)
    as "Only the real lsp system family constructs the lease."
  #(
    scope,
    digest,
    input,
    parent,
    capture,
    era,
    anchor,
    proposal,
    invocation,
    lease,
  )
}

pub fn complete_headers_and_both_closed_command_parents_roundtrip_test() {
  let #(
    scope,
    digest,
    input,
    _parent,
    capture,
    _era,
    _anchor,
    _proposal,
    invocation,
    lease,
  ) = fixture(0)
  assert l.decode_lease_value(l.lease_value(lease)) == Ok(lease)
  assert l.decode_capture_value(l.capture_value(capture), input) == Ok(capture)
  assert l.decode_invocation_value(l.invocation_value(invocation), input)
    == Ok(invocation)
  let assert Ok(inventory) =
    l.enrolled_profiles(scope, digest, [
      l.Profile("first", "/checkout"),
      l.Profile("second", "/checkout"),
    ])
    as "Both admitted profiles remain in immutable order."
  let assert Ok(profile) = l.checked_profile(inventory, 1)
    as "The second actual profile is checked."
  let assert Ok(search) =
    l.lsp_search_command(invocation, profile, l.cold_search_root(profile))
    as "Cold Search uses the enrolled workspace root."
  assert l.decode_command_value(l.command_value(search), input, inventory, None)
    == Ok(search)
  list.each([l.Probe, l.Prepare, l.ServerLease], fn(role) {
    let assert Ok(startup) = l.lsp_startup_command(lease, role)
      as "The closed startup role has a lease parent."
    assert l.decode_command_value(
        l.command_value(startup),
        input,
        inventory,
        None,
      )
      == Ok(startup)
    assert l.command_address(startup) != l.command_address(search)
  })
  assert l.decode_lease_value(l.invocation_value(invocation)) |> result.is_error
  assert l.decode_capture_value(l.lease_value(lease), input) |> result.is_error
}

pub fn cold_profile_and_warm_selection_cannot_cross_roots_or_enrollment_test() {
  let #(
    scope,
    digest,
    input,
    _parent,
    _capture,
    _era,
    _anchor,
    _proposal,
    invocation,
    _lease,
  ) = fixture(0)
  let assert Ok(inventory) =
    l.enrolled_profiles(scope, digest, [
      l.Profile("first", "/checkout"),
      l.Profile("second", "/checkout"),
    ])
    as "The full configured inventory is valid."
  let assert Ok(first) = l.checked_profile(inventory, 0)
    as "The first actual profile is checked."
  let assert Ok(second) = l.checked_profile(inventory, 1)
    as "The second actual profile is checked."
  let assert Ok(selected) =
    l.selected_project(first, "first", "/checkout/project")
    as "The trusted manager retained this selected project."
  let root = l.warm_search_root(selected)
  assert l.lsp_search_command(invocation, second, root)
    == Error(l.ParentMismatch)
  let assert Ok(search) = l.lsp_search_command(invocation, first, root)
    as "Warm Search uses the actual retained project."
  assert l.decode_command_value(
      l.command_value(search),
      input,
      inventory,
      Some(selected),
    )
    == Ok(search)
  assert l.decode_command_value(l.command_value(search), input, inventory, None)
    == Error(l.ParentMismatch)
  assert l.selected_project(first, "second", "/checkout/project")
    == Error(l.ParentMismatch)
  assert l.checked_profile(inventory, 16) == Error(l.InvalidIdentity)
  assert l.enrolled_profiles(
      scope,
      digest,
      list.repeat(l.Profile("first", "/checkout"), 17),
    )
    == Error(l.InvalidIdentity)
}

pub fn original_timing_consumes_observation_admission_and_keeps_negative_ticks_test() {
  let #(
    _scope,
    digest,
    _input,
    parent,
    capture,
    era,
    anchor,
    proposal,
    _invocation,
    _lease,
  ) = fixture(0)
  assert l.verify_parent_control(capture, parent, 500_000, 0, Some(0))
    == Error(l.InvalidIdentity)
  let assert Ok(admitted) =
    l.admitted_control(anchor, proposal, -500_001, -500_000, era, digest)
    as "Negative native ticks are valid in this original era."
  assert l.control_fields(admitted).3 == -1
  assert l.admitted_control(anchor, proposal, -500_000, -499_000, era, digest)
    == Error(l.ExpiredControl)
  let assert Ok(other_era) = l.clock_era("00000000-0000-4000-8000-000000000002")
    as "A later VM has a distinct trusted era."
  assert l.admitted_control(
      anchor,
      proposal,
      -500_000,
      -499_999,
      other_era,
      digest,
    )
    == Error(l.ParentMismatch)
  let #(
    _scope,
    digest,
    _input,
    parent,
    capture,
    _era,
    anchor,
    _proposal,
    _invocation,
    _lease,
  ) = fixture(9)
  assert l.verify_parent_control(capture, parent, 500_000, 1000, None)
    == Error(l.InvalidIdentity)
  let assert Ok(control) =
    l.verify_parent_control(capture, parent, 500_000, 1000, Some(0))
    as "Observe includes its original initial control wait."
  let assert Ok(proposal) = l.finite_timing_proposal(anchor, control, digest)
    as "Observe proposal uses the reduced original allowance."
  let assert m.ArrayValue([_, _, _, m.IntValue(remaining), _]) =
    l.timing_value(proposal)
    as "The proposal has exactly five fields."
  assert remaining == 74_000
  assert l.verify_parent_control(capture, parent, 500_000, 75_000, Some(0))
    == Error(l.ExpiredControl)
}

pub fn timing_changes_find_original_address_and_zero_deadline_refuses_test() {
  let #(
    _scope,
    digest,
    input,
    original_parent,
    capture,
    era,
    anchor,
    proposal,
    invocation,
    _lease,
  ) = fixture(0)
  let assert m.ArrayValue([version, clock, nonce, _, parent]) =
    l.timing_value(proposal)
    as "The original proposal has fixed arity."
  let assert Ok(changed) =
    l.decode_timing_value(
      m.ArrayValue([version, clock, nonce, m.IntValue(499_999), parent]),
      original_parent,
    )
    as "Another positive duration is syntactically valid history."
  let assert Ok(other) = l.lsp_invocation(capture, changed, digest)
    as "Identity does not grant changed timing dispatch authority."
  assert l.capture_address(l.invocation_capture(invocation))
    == l.capture_address(l.invocation_capture(other))
  assert l.invocation_value(invocation) != l.invocation_value(other)
  assert l.admitted_control(anchor, proposal, -500_000, -499_999, era, digest)
    == Error(l.ExpiredControl)
  assert l.decode_timing_value(
      m.ArrayValue([version, clock, nonce, m.IntValue(0), parent]),
      original_parent,
    )
    == Error(l.InvalidIdentity)
  assert l.decode_timing_value(
      m.ArrayValue([version, clock, nonce, m.IntValue(86_400_001), parent]),
      original_parent,
    )
    == Error(l.InvalidIdentity)
  assert l.decode_timing_value(
      m.ArrayValue([version, clock, nonce, m.IntValue(1), parent, m.IntValue(0)]),
      original_parent,
    )
    == Error(l.InvalidIdentity)
  assert l.decode_capture_value(l.invocation_value(invocation), input)
    == Error(l.InvalidIdentity)
}

pub fn individually_legal_search_root_cannot_exceed_complete_command_header_test() {
  let #(
    scope,
    digest,
    _input,
    _parent,
    _capture,
    _era,
    _anchor,
    _proposal,
    invocation,
    _lease,
  ) = fixture(0)
  let root = "/" <> string.repeat("a", 8191)
  let assert Ok(inventory) =
    l.enrolled_profiles(scope, digest, [l.Profile("first", root)])
    as "The root alone is at its exact permitted boundary."
  let assert Ok(profile) = l.checked_profile(inventory, 0)
    as "The actual root belongs to an admitted profile."
  assert l.lsp_search_command(invocation, profile, l.cold_search_root(profile))
    == Error(l.HeaderTooLarge)
}

pub fn proposal_keeps_complete_verified_parent_when_digest_values_are_equal_test() {
  let #(_, digest, input, parent, capture, _, anchor, proposal, _, _) =
    fixture(0)
  let assert m.ArrayValue([
    m.IntValue(0),
    m.ArrayValue([origin, scope, op, step, _, input_digest]),
  ]) = l.parent_value(parent)
    as "The complete original parent retains every physical coordinate."
  let #(another_request, _) =
    ids.mint_entry(ids.generator(clock.fixed(1000), 42))
  let other_id = m.StringValue(ids.entry_id_to_string(another_request))
  let assert Ok(child) =
    l.decode_child_ref_value(
      m.ArrayValue([origin, scope, op, step, other_id, input_digest]),
    )
    as "Another original request has independently valid complete identity."
  let assert Ok(other_parent) = l.parent_control(child)
    as "The other complete durable reference is independently bounded."
  assert parent != other_parent
  assert l.verify_parent_control(capture, other_parent, 500_000, 0, None)
    == Error(l.ParentMismatch)
  let assert m.ArrayValue(fields) = l.capture_value(capture)
    as "Capture has fixed positional original coordinates."
  let other_value =
    m.ArrayValue(
      list.index_map(fields, fn(field, index) {
        case index {
          6 -> other_id
          11 -> l.parent_value(other_parent)
          _ -> field
        }
      }),
    )
  let assert Ok(other_capture) = l.decode_capture_value(other_value, input)
    as "The other capture matches its own original complete controlled child."
  let assert Ok(control) =
    l.verify_parent_control(other_capture, other_parent, 1234, 0, None)
    as "Only the actual other original supplies this duration."
  let assert Ok(other_proposal) =
    l.finite_timing_proposal(anchor, control, digest)
    as "A digest argument cannot erase the retained complete parent."
  assert l.lsp_invocation(capture, other_proposal, digest)
    == Error(l.ParentMismatch)
  let assert Ok(history) =
    l.decode_timing_value(l.timing_value(proposal), other_parent)
    as "History decoding remains data tied to its complete retained reference."
  assert l.lsp_invocation(capture, history, digest) == Error(l.ParentMismatch)
}

pub fn system_finite_origin_requires_exact_actual_post_write_family_test() {
  let #(scope, digest, input, parent, _, _, _, _, _, _) = fixture(0)
  let #(session, _) = w.scope_fields(scope)
  let assert m.ArrayValue([_, child_value]) = l.parent_value(parent)
    as "The original admitted control has one complete tool child."
  let assert Ok(write) = l.decode_child_ref_value(child_value)
    as "The existing original write reference is complete checked data."
  let assert m.ArrayValue([tool_origin, _, _, _, _, _]) = child_value
    as "The complete reference retains its actual child origin."
  let assert Ok(tool_origin) = r.decode_child_value(tool_origin)
    as "The shared canonical origin codec retains the complete tool."
  let assert Ok(tool) = r.child_tool(tool_origin)
    as "The finite original has an actual admitted tool parent."
  let op = r.operation(tool)
  let request = r.result_entry(tool)
  let assert Ok(step) = w.step("lsp.query")
    as "The original physical step is retained."
  let assert Ok(system) = r.system_child(session, "lsp", 7)
    as "The actual lsp system family can name a post-write observation."
  let assert Ok(child) =
    l.original_child_ref(system, scope, op, step, request, digest)
    as "The original system child keeps complete post-write coordinates."
  let assert Ok(control) = l.parent_control(child)
    as "A durable original reference grants no finite query authority."
  assert l.lsp_capture(
      system,
      scope,
      op,
      step,
      request,
      input,
      control,
      digest,
      digest,
    )
    == Error(l.InvalidIdentity)
  let assert Ok(post_write) = l.post_write_control(write, child)
    as "The original physically landed write and admitted post-write child share scope and operation."
  let assert Ok(after_input) = l.semantic_input(<<0x91, 8>>, digest, 8)
    as "The checked codec supplied the closed AfterWrite discriminant."
  let assert Ok(after_capture) =
    l.lsp_capture(
      system,
      scope,
      op,
      step,
      request,
      after_input,
      post_write,
      digest,
      digest,
    )
    as "Only actual AfterWrite admits this existing system family."
  assert l.decode_capture_value(l.capture_value(after_capture), after_input)
    == Ok(after_capture)
  let assert Ok(unrelated) = r.system_child(session, "unrelated", 7)
    as "An unrelated system service remains valid general origin data."
  let assert Ok(unrelated_child) =
    l.original_child_ref(unrelated, scope, op, step, request, digest)
    as "The unrelated child has independently valid original coordinates."
  let assert Ok(unrelated_control) =
    l.post_write_control(write, unrelated_child)
    as "Complete scope equality cannot substitute for the lsp system family."
  assert l.lsp_capture(
      unrelated,
      scope,
      op,
      step,
      request,
      after_input,
      unrelated_control,
      digest,
      digest,
    )
    == Error(l.InvalidIdentity)
}
