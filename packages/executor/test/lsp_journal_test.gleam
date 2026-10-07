//// Real SQLite controls for original executor LSP custody.
//// Physical callbacks are deliberately fixture witnesses, not production joins.

import core/clock
import core/generation as g
import core/ids
import core/lsp_command as id
import core/msgpack as mp
import core/remote_tool
import core/workspace
import executor/remote/lsp_journal as j
import executor/remote/lsp_wire as wire
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lsp/query
import simplifile
import sqlight
import weft/actor

type TimeMessage {
  Tick(process.Subject(Int))
  SetTick(Int)
  Nonce(process.Subject(BitArray))
  Count(process.Subject(Int))
}

type Rig {
  Rig(
    path: String,
    store: j.Store,
    binding: j.Binding,
    contract: g.Digest,
    incarnation: ids.EntryId,
    limits: j.Limits,
    clock: j.Clock,
    time: process.Subject(TimeMessage),
    profiles: id.EnrolledProfiles,
    scope: workspace.Scope,
    enrollment: g.Digest,
  )
}

fn identity(rig: Rig, number: Int, request: wire.Request) {
  let generator = ids.generator(clock.fixed(1000), number)
  let #(operation, generator) = ids.mint_op(generator)
  let #(request_id, _) = ids.mint_entry(generator)
  let assert Ok(step) = workspace.step("lsp.query")
    as "The physical step is valid."
  let assert Ok(input) = wire.semantic_input(request)
    as "The semantic input is canonical."
  let #(_, digest, _) = id.input_fields(input)
  let assert Ok(system) =
    remote_tool.system_child(workspace.scope_fields(rig.scope).0, "lsp", number)
    as "The original system child is retained."
  let assert Ok(tool) =
    remote_tool.key(
      workspace.scope_fields(rig.scope).0,
      operation,
      "lsp.query",
      0,
      string.repeat("0", 64),
      request_id,
    )
    as "The tool retains the real original invocation."
  let assert Ok(origin) =
    remote_tool.tool_child(
      tool,
      remote_tool.AdmittedCapability(
        "lsp.query",
        0,
        remote_tool.SemanticWorkspace,
      ),
    )
    as "Ordinary finite queries use admitted tool provenance."
  let assert Ok(child) =
    id.original_child_ref(
      origin,
      rig.scope,
      operation,
      step,
      request_id,
      digest,
    )
    as "The exact controlled child retains every coordinate."
  let assert Ok(parent) = id.parent_control(child)
    as "The original control reference is complete."
  let assert Ok(capture) =
    id.lsp_capture(
      origin,
      rig.scope,
      operation,
      step,
      request_id,
      input,
      parent,
      rig.enrollment,
      rig.contract,
    )
    as "The finite original is valid."
  let assert Ok(lease_input) = j.lease_input("gleam", "/workspace", request_id)
    as "The complete lease input names its original incarnation."
  let assert Ok(lease) =
    id.lsp_service_key(
      system,
      rig.scope,
      operation,
      step,
      request_id,
      digest_of(lease_input),
      rig.enrollment,
      rig.contract,
    )
    as "The session lease has its independent exact input."
  #(capture, lease, lease_input)
}

fn timed(
  capture: id.FiniteCapture,
  anchor: id.FiniteAnchor,
  remaining: Int,
) -> id.LspInvocation {
  let parent = id.capture_parent(capture)
  let assert Ok(control) =
    id.verify_parent_control(capture, parent, remaining, 0, None)
    as "The actual original parent supplies its remaining interval."
  let assert Ok(digest) = wire.parent_digest(parent)
    as "The canonical parent digest is retained."
  let assert Ok(proposal) = id.finite_timing_proposal(anchor, control, digest)
    as "The original proposal uses the retained anchor."
  let assert Ok(invocation) = id.lsp_invocation(capture, proposal, digest)
    as "The timing is fixed without an owner absolute timestamp."
  invocation
}

pub fn capture_once_deadline_retry_conflict_and_result_receipt_test() {
  fixture("timing", 4096, 268_435_456, fn(rig) {
    let request = wire.Definition(query.SymbolQuery("name", None, None))
    let #(capture, _, _) = identity(rig, 1, request)
    let assert Ok(original) = j.capture_finite(rig.store, capture, request)
      as "First capture commits before nonce reply."
    let assert Ok(#(anchor, e0)) = j.captured_anchor(original)
      as "The original anchor has one retained E0."
    assert e0 == -1000
    process.send(rig.time, SetTick(-900))
    assert j.capture_finite(rig.store, capture, request) == Ok(original)
    assert process.call(rig.time, 1000, Count) == 1
    let invocation = timed(capture, anchor, 2000)
    let assert Ok(j.FreshFinite(claim)) =
      j.accept_finite(rig.store, invocation, request)
      as "The first timed admission returns one original post-COMMIT claim."
    assert id.control_fields(j.finite_control(claim)).3 == 1000
    let assert Ok(j.RetainedFinite(retained)) =
      j.accept_finite(rig.store, invocation, request)
      as "The duplicate grants history only."
    assert j.finite_disposition(retained) == j.Started
    assert j.accept_finite(rig.store, timed(capture, anchor, 3000), request)
      == Error(j.Conflict)
    let value = wire.Definitions(query.Served([], query.Warm))
    let assert Ok(receipt) = j.finish(claim, value)
      as "Canonical full result COMMIT precedes its reference."
    assert j.finish(claim, value) == Ok(receipt)
    assert j.acknowledge(rig.store, receipt) == Ok(Nil)
    let assert Ok(history) =
      j.inspect_finite(rig.store, rig.binding, capture, request)
      as "Original request and parent still match after ACK."
    assert j.retained_result(history) == Ok(value)
    assert j.result_receipt(history) == Ok(receipt)
    assert j.finite_disposition(history) == j.Acknowledged
    assert j.accept_finite(rig.store, invocation, request)
      == Ok(j.RetainedFinite(history))
  })
}

pub fn original_capture_expiry_and_same_era_recovery_cannot_renew_test() {
  fixture("expiry", 8, 50_000_000, fn(rig) {
    let request = wire.Diagnostics(None)
    let #(capture, _, _) = identity(rig, 1, request)
    let assert Ok(original) = j.capture_finite(rig.store, capture, request)
      as "The original capture is durable."
    let assert Ok(#(anchor, _)) = j.captured_anchor(original)
      as "The immutable anchor is available."
    process.send(rig.time, SetTick(0))
    let assert Ok(j.RetainedFinite(expired)) =
      j.accept_finite(rig.store, timed(capture, anchor, 5000), request)
      as "The 1000ms boundary refuses and retains its fence."
    assert j.finite_disposition(expired) == j.Unknown
    assert j.captured_anchor(expired) == j.captured_anchor(original)
    process.send(rig.time, SetTick(-1000))
    assert j.accept_finite(rig.store, timed(capture, anchor, 5000), request)
      == Error(j.Fenced)
    let #(capture2, _, _) = identity(rig, 2, request)
    let assert Ok(captured2) = j.capture_finite(rig.store, capture2, request)
      as "The independent original has one separate capture."
    let assert Ok(#(anchor2, _)) = j.captured_anchor(captured2)
      as "Its original nonce remains retained."
    let assert Ok(j.FreshFinite(_)) =
      j.accept_finite(rig.store, timed(capture2, anchor2, 5000), request)
      as "Its first claim commits."
    let assert Ok(recovered) =
      j.recover(
        rig.path,
        rig.binding,
        rig.contract,
        rig.incarnation,
        rig.limits,
        rig.clock,
        rig.profiles,
      )
      as "Even reusing the era and endpoint UUID does not recover a claim."
    let assert Ok(j.RetainedFinite(history)) =
      j.accept_finite(recovered, timed(capture2, anchor2, 5000), request)
      as "Only exact historical timing survives."
    assert j.finite_disposition(history) == j.Unknown
    assert j.release(recovered) == Ok(Nil)
  })
}

pub fn cold_search_rows_share_lifetime_quota_and_exact_generation_test() {
  fixture("search", 17, 268_435_456, fn(rig) {
    let request = wire.Diagnostics(None)
    let #(capture, _, _) = identity(rig, 1, request)
    let assert Ok(original) = j.capture_finite(rig.store, capture, request)
      as "The finite original consumes one permanent row."
    let assert Ok(#(anchor, _)) = j.captured_anchor(original)
      as "The exact original anchor is retained."
    let invocation = timed(capture, anchor, 5000)
    let assert Ok(j.FreshFinite(claim)) =
      j.accept_finite(rig.store, invocation, request)
      as "Search belongs to this original admitted finite."
    list.each(
      [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
      fn(ordinal) {
        let assert Ok(profile) = id.checked_profile(rig.profiles, ordinal)
          as "Every admitted profile participates in cold resolution."
        let assert Ok(ref) =
          id.lsp_search_command(
            invocation,
            profile,
            id.cold_search_root(profile),
          )
          as "Search has only a real finite parent."
        let assert Ok(history) =
          j.reserve_command(rig.store, ref, request, None)
          as "Every Search consumes another shared identity."
        assert j.reserve_command(rig.store, ref, request, None) == Ok(history)
        assert j.command_disposition(history) == j.CommandReserved
        assert j.start_command(rig.store, history, Some(claim))
          == Ok(j.RetainedCommand(history))
      },
    )
    let #(other, _, _) = identity(rig, 2, request)
    assert j.capture_finite(rig.store, other, request) == Error(j.Capacity)
    let assert Ok(changed) = g.key(rig.scope, rig.contract, 2)
      as "The same scope has another exact generation."
    assert j.inspect_finite(
        rig.store,
        j.binding(changed, rig.enrollment),
        capture,
        request,
      )
      == Error(j.Conflict)
  })
}

pub fn server_terminal_and_reusable_cannot_advance_slot_test() {
  fixture("lease", 20, 100_000_000, fn(rig) {
    let request = wire.Diagnostics(None)
    let #(_, lease, input) = identity(rig, 1, request)
    let #(_, next_lease, next_input) = identity(rig, 2, request)
    let assert Ok(original) =
      j.reserve_lease(rig.store, lease, input, "gleam", "/workspace")
      as "The original lease occupies the full scoped slot."
    let assert Ok(ref) = id.lsp_startup_command(lease, id.ServerLease)
      as "Only the exact lease can parent ServerLease."
    let assert Ok(command) = j.reserve_command(rig.store, ref, request, None)
      as "The server command is separately charged."
    let assert Ok(offered) =
      j.retain_offer(
        rig.store,
        command,
        raw(mp.ArrayValue([mp.IntValue(1)])),
        fn(_, _) { Ok(Nil) },
      )
      as "Fixture original placement verifies the canonical offer."
    let assert Ok(associated) =
      j.associate(
        rig.store,
        offered,
        raw(mp.ArrayValue([mp.IntValue(2)])),
        raw(mp.ArrayValue([mp.IntValue(3)])),
        fn(_, _, _) { Ok(Nil) },
      )
      as "Fixture native/owner admission retains its exact association."
    let assert Ok(j.FreshServer(claim)) =
      j.start_command(rig.store, associated, None)
      as "First server startup commits one closed claim."
    let assert Ok(serving) = j.serving(claim)
      as "Only the original server claim can announce Serving."
    let assert Ok(started) =
      j.inspect_command(rig.store, rig.binding, ref, request, None)
      as "The exact command retains its original native association."
    let assert Ok(finishing) =
      j.retain_terminal(
        rig.store,
        started,
        raw(mp.ArrayValue([mp.IntValue(4)])),
        <<>>,
        fn(_, _, _) { Ok(Nil) },
      )
      as "Terminal is separate from original helper retirement."
    assert j.retain_reusable(
        rig.store,
        finishing,
        raw(mp.ArrayValue([mp.IntValue(5)])),
        fn(_, _) { Ok(Nil) },
      )
      == Error(j.Invalid)
    assert j.reserve_lease(
        rig.store,
        next_lease,
        next_input,
        "gleam",
        "/workspace",
      )
      == Error(j.Fenced)
    let assert Ok(closing) = j.close_lease(rig.store, serving)
      as "The durable close fence precedes physical cleanup."
    let evidence = raw(mp.ArrayValue([mp.IntValue(6)]))
    assert j.retire_lease(rig.store, closing, evidence, fn(_, _) {
        Error(j.Fenced)
      })
      == Error(j.Fenced)
    assert j.reserve_lease(
        rig.store,
        next_lease,
        next_input,
        "gleam",
        "/workspace",
      )
      == Error(j.Fenced)
    let assert Ok(receipt) =
      j.retire_lease(rig.store, closing, evidence, fn(_, _) { Ok(Nil) })
      as "Only the fixture's original physical joins permit Retired COMMIT."
    assert j.retirement_fields(receipt).1 == lease
    let assert Ok(replacement) =
      j.reserve_lease(rig.store, next_lease, next_input, "gleam", "/workspace")
      as "Verified exact original retirement permits one new charged incarnation."
    assert j.lease_disposition(replacement) == j.Reserved
    let _ = original
    Nil
  })
}

pub fn closing_lease_retains_delayed_admission_without_dispatch_test() {
  list.each([0, 1], fn(close_stage) {
    fixture("late-close", 20, 100_000_000, fn(rig) {
      let request = wire.Diagnostics(None)
      let #(_, lease, input) = identity(rig, 1, request)
      let #(_, successor, successor_input) = identity(rig, 2, request)
      let assert Ok(original) =
        j.reserve_lease(rig.store, lease, input, "gleam", "/workspace")
        as "The original slot precedes command placement."
      let assert Ok(ref) = id.lsp_startup_command(lease, id.ServerLease)
        as "The server command belongs to this exact original lease."
      let assert Ok(command) = j.reserve_command(rig.store, ref, request, None)
        as "The command retains placement custody before the close race."

      // The two controls close before placement and before native association.
      case close_stage {
        0 -> {
          let assert Ok(_) = j.close_lease(rig.store, original)
            as "Closing commits while original placement is still pending."
          Nil
        }
        _ -> Nil
      }
      let assert Ok(offered) =
        j.retain_offer(
          rig.store,
          command,
          raw(mp.ArrayValue([mp.IntValue(1)])),
          fn(_, _) { Ok(Nil) },
        )
        as "A late original placement is retained as historical evidence."

      // Inspect before a second close can conceal a placement reopening the slot.
      case close_stage {
        0 -> {
          let assert Ok(retained) =
            j.inspect_lease(rig.store, rig.binding, lease)
            as "The delayed offer retains the original close fence."
          assert j.lease_disposition(retained) == j.Closing
          Nil
        }
        _ -> Nil
      }
      let assert Ok(closing) = j.close_lease(rig.store, original)
        as "Closing remains durable before native admission returns."
      assert j.lease_disposition(closing) == j.Closing
      let assert Ok(associated) =
        j.associate(
          rig.store,
          offered,
          raw(mp.ArrayValue([mp.IntValue(2)])),
          raw(mp.ArrayValue([mp.IntValue(3)])),
          fn(_, _, _) { Ok(Nil) },
        )
        as "Late exact native association retains cleanup provenance."
      let assert Ok(retained) = j.inspect_lease(rig.store, rig.binding, lease)
        as "The current original lease remains readable after late admission."
      assert j.lease_disposition(retained) == j.Closing
      assert j.start_command(rig.store, associated, None) == Error(j.Fenced)
      assert j.inspect_command(rig.store, rig.binding, ref, request, None)
        == Ok(associated)
      assert j.reserve_lease(
          rig.store,
          successor,
          successor_input,
          "gleam",
          "/workspace",
        )
        == Error(j.Fenced)
    })
  })
}

pub fn corrupt_command_self_and_cycle_parents_refuse_bounded_recovery_test() {
  list.each(
    [
      "UPDATE lsp_command SET parent_address=address",
      "UPDATE lsp_command SET parent_address=(SELECT other.address FROM lsp_command other WHERE other.address<>lsp_command.address LIMIT 1)",
    ],
    fn(corruption) {
      fixture("parent-cycle", 20, 100_000_000, fn(rig) {
        let request = wire.Diagnostics(None)
        let #(_, lease, input) = identity(rig, 1, request)
        let assert Ok(_) =
          j.reserve_lease(rig.store, lease, input, "gleam", "/workspace")
          as "Concrete original ancestry precedes corruption."
        list.each([id.ServerLease, id.Probe], fn(role) {
          let assert Ok(ref) = id.lsp_startup_command(lease, role)
            as "Each command starts with a concrete lease parent."
          let assert Ok(_) = j.reserve_command(rig.store, ref, request, None)
            as "Two original commands make both self and cyclic controls meaningful."
          Nil
        })
        let assert Ok(Nil) = j.release(rig.store)
          as "The original DAL closes before independent stored corruption."
        let assert Ok(connection) = sqlight.open(rig.path)
          as "The fixture opens the actual SQLite binding."
        let assert Ok(Nil) = sqlight.exec(corruption, connection)
          as "Corrupt links retain valid bounded command addresses."
        let assert Ok(Nil) = sqlight.close(connection)
          as "No external transaction outlives fixture mutation."
        assert j.recover(
            rig.path,
            rig.binding,
            rig.contract,
            rig.incarnation,
            rig.limits,
            rig.clock,
            rig.profiles,
          )
          == Error(j.Corrupt)
      })
    },
  )
}

pub fn suppressed_capture_and_deferred_commit_failure_issue_no_claim_test() {
  list.each(
    [
      "CREATE TRIGGER suppress BEFORE INSERT ON lsp_finite BEGIN SELECT RAISE(IGNORE); END",
      "CREATE TABLE parent(id INTEGER PRIMARY KEY); CREATE TABLE child(id INTEGER REFERENCES parent(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_commit AFTER UPDATE ON lsp_finite WHEN NEW.phase=2 BEGIN INSERT INTO child VALUES(1); END",
    ],
    fn(trigger) {
      fixture("sqlrefusal", 8, 50_000_000, fn(rig) {
        let request = wire.Diagnostics(None)
        let #(capture, _, _) = identity(rig, 1, request)
        let assert Ok(connection) = sqlight.open(rig.path)
          as "Independent SQLite control connection."
        let assert Ok(Nil) = sqlight.exec(trigger, connection)
          as "The driver executes a real refusal control."
        let assert Ok(Nil) = sqlight.close(connection)
          as "The control releases its handle."
        case j.capture_finite(rig.store, capture, request) {
          Error(_) -> Nil
          Ok(history) -> {
            let assert Ok(#(anchor, _)) = j.captured_anchor(history)
              as "Capture commits before the timed update."
            assert j.accept_finite(
                rig.store,
                timed(capture, anchor, 5000),
                request,
              )
              == Error(j.Uncertain)
          }
        }
      })
    },
  )
}

pub fn schema_length_and_profile_corruption_refuse_recovery_test() {
  list.each(
    [
      "PRAGMA ignore_check_constraints=ON; UPDATE lsp_meta SET format=2",
      "PRAGMA ignore_check_constraints=ON; UPDATE lsp_finite SET identity=zeroblob(8193)",
      "PRAGMA journal_mode=WAL",
    ],
    fn(corruption) {
      fixture("corrupt", 8, 50_000_000, fn(rig) {
        let request = wire.Diagnostics(None)
        let #(capture, _, _) = identity(rig, 1, request)
        let assert Ok(_) = j.capture_finite(rig.store, capture, request)
          as "Valid canonical history precedes corruption."
        let assert Ok(Nil) = j.release(rig.store)
          as "The original DAL joins before independent corruption."
        let assert Ok(connection) = sqlight.open(rig.path)
          as "The fixture owns a new SQLite connection."
        let assert Ok(Nil) = sqlight.exec(corruption, connection)
          as "The corruption crosses the actual driver."
        let assert Ok(Nil) = sqlight.close(connection)
          as "No long-lived external reader remains."
        assert result_is_error(j.recover(
          rig.path,
          rig.binding,
          rig.contract,
          rig.incarnation,
          rig.limits,
          rig.clock,
          rig.profiles,
        ))
      })
    },
  )
}

pub fn complete_byte_reservation_edges_and_wrong_request_refusal_test() {
  let charge = fixture_charge()
  list.each([charge - 1, charge], fn(bytes) {
    fixture("byte-edge", 8, bytes, fn(rig) {
      let request = wire.Diagnostics(None)
      let #(capture, _, _) = identity(rig, 1, request)
      case bytes < charge {
        True -> {
          assert j.capture_finite(rig.store, capture, request)
            == Error(j.Capacity)
        }
        False -> {
          let assert Ok(_) = j.capture_finite(rig.store, capture, request)
            as "The exact complete result/header/association reservation fits."
          let changed = wire.Hover(query.SymbolQuery("changed", None, None))
          let #(changed_capture, _, _) = identity(rig, 1, changed)
          assert j.capture_finite(rig.store, changed_capture, changed)
            == Error(j.Conflict)
          let #(next, _, _) = identity(rig, 2, request)
          assert j.capture_finite(rig.store, next, request) == Error(j.Capacity)
        }
      }
    })
  })
  assert j.limits(4097, 268_435_456) == Error(j.Invalid)
  assert j.limits(4096, 268_435_457) == Error(j.Invalid)
}

fn fixture_charge() -> Int {
  // The measured original reservation comes from the committed shared ledger,
  // so the edge controls exercise the DAL rather than copying its arithmetic.
  let answer = process.new_subject()
  fixture("measure", 8, 50_000_000, fn(rig) {
    let request = wire.Diagnostics(None)
    let #(capture, _, _) = identity(rig, 1, request)
    let assert Ok(_) = j.capture_finite(rig.store, capture, request)
      as "The measured reservation commits."
    let assert Ok(connection) = sqlight.open(rig.path)
      as "The observer opens an independent bounded read."
    let assert Ok([charge]) =
      sqlight.query(
        "SELECT reserved_bytes FROM lsp_identity",
        connection,
        [],
        decode.field(0, decode.int, decode.success),
      )
      as "The permanent reservation is actually in SQLite."
    let assert Ok(Nil) = sqlight.close(connection)
      as "The reader closes before further mutation."
    process.send(answer, charge)
  })
  let assert Ok(charge) = process.receive(answer, 1000)
    as "The fixture returns its measured charge."
  charge
}

pub fn finite_terminal_reusable_and_absorbing_fence_test() {
  fixture("reusable", 8, 50_000_000, fn(rig) {
    let request = wire.Diagnostics(None)
    let #(capture, _, _) = identity(rig, 1, request)
    let assert Ok(captured) = j.capture_finite(rig.store, capture, request)
      as "The original finite capture commits."
    let assert Ok(#(anchor, _)) = j.captured_anchor(captured)
      as "Its original anchor is retained."
    let invocation = timed(capture, anchor, 5000)
    let assert Ok(j.FreshFinite(claim)) =
      j.accept_finite(rig.store, invocation, request)
      as "Only the original finite admission returns a claim."
    let assert Ok(profile) = id.checked_profile(rig.profiles, 0)
      as "The enrolled profile is checked."
    let assert Ok(ref) =
      id.lsp_search_command(invocation, profile, id.cold_search_root(profile))
      as "The real finite invocation owns this Search."
    let assert Ok(command) = j.reserve_command(rig.store, ref, request, None)
      as "The Search reservation precedes every native effect."
    let assert Ok(offered) =
      j.retain_offer(
        rig.store,
        command,
        raw(mp.ArrayValue([mp.IntValue(1)])),
        fn(_, _) { Ok(Nil) },
      )
      as "The trusted fixture admits its fixed offer."
    assert j.retain_offer(
        rig.store,
        command,
        raw(mp.ArrayValue([mp.IntValue(1)])),
        fn(_, _) { Ok(Nil) },
      )
      == Ok(offered)
    let assert Ok(associated) =
      j.associate(
        rig.store,
        offered,
        raw(mp.ArrayValue([mp.IntValue(2)])),
        raw(mp.ArrayValue([mp.IntValue(3)])),
        fn(_, _, _) { Ok(Nil) },
      )
      as "The original native association is immutable."
    let assert Ok(j.FreshCommand(_)) =
      j.start_command(rig.store, associated, Some(claim))
      as "One original claim commits before native dispatch."
    let assert Ok(j.RetainedCommand(started)) =
      j.start_command(rig.store, associated, Some(claim))
      as "Duplicate dispatch returns history only."
    let assert Ok(finishing) =
      j.retain_terminal(
        rig.store,
        started,
        raw(mp.ArrayValue([mp.IntValue(4)])),
        raw(mp.ArrayValue([])),
        fn(_, _, _) { Ok(Nil) },
      )
      as "Terminal retains the checked complete projection separately."
    assert j.command_disposition(finishing) == j.Finishing
    let witness = raw(mp.ArrayValue([mp.IntValue(5)]))
    let assert Ok(reusable) =
      j.retain_reusable(rig.store, finishing, witness, fn(_, _) { Ok(Nil) })
      as "Only the consumed matching fixture witness permits reusable completion."
    assert j.command_disposition(reusable) == j.Reusable
    assert j.retain_reusable(rig.store, finishing, witness, fn(_, _) { Ok(Nil) })
      == Ok(reusable)
    let changed_invocation = timed(capture, anchor, 6000)
    let assert Ok(changed_ref) =
      id.lsp_search_command(
        changed_invocation,
        profile,
        id.cold_search_root(profile),
      )
      as "A different complete timing parent is constructible data only."
    assert j.inspect_command(rig.store, rig.binding, changed_ref, request, None)
      == Error(j.Conflict)
    let assert Ok(profile2) = id.checked_profile(rig.profiles, 1)
      as "The next cold profile is independent."
    let assert Ok(ref2) =
      id.lsp_search_command(invocation, profile2, id.cold_search_root(profile2))
      as "The second Search retains the same original control."
    let assert Ok(reserved2) = j.reserve_command(rig.store, ref2, request, None)
      as "It consumes another shared reservation."
    let assert Ok(fenced) = j.fence_command(rig.store, reserved2)
      as "Unknown is an absorbing original fence."
    assert j.command_disposition(fenced) == j.UnknownCommand
    assert j.retain_reusable(rig.store, fenced, witness, fn(_, _) { Ok(Nil) })
      == Error(j.Fenced)
  })
}

pub fn changed_clock_era_and_zero_deadline_refuse_original_claim_test() {
  fixture("era", 8, 50_000_000, fn(rig) {
    let request = wire.Diagnostics(None)
    let #(capture, _, _) = identity(rig, 1, request)
    let assert Ok(captured) = j.capture_finite(rig.store, capture, request)
      as "The original native era is retained."
    let assert Ok(#(anchor, _)) = j.captured_anchor(captured)
      as "No owner absolute clock is used."
    let assert Ok(j.RetainedFinite(refused)) =
      j.accept_finite(rig.store, timed(capture, anchor, 1000), request)
      as "Zero deadline is invalid even in a negative clock era."
    assert j.finite_disposition(refused) == j.Unknown
    let #(capture2, _, _) = identity(rig, 2, request)
    let assert Ok(captured2) = j.capture_finite(rig.store, capture2, request)
      as "The next original captures the old era once."
    let assert Ok(#(anchor2, _)) = j.captured_anchor(captured2)
      as "Its original nonce remains unchanged."
    let assert Ok(era) = id.clock_era("00000000-0000-4000-8000-000000000002")
      as "A reboot creates another concrete clock incarnation."
    let clock = j.Clock(era, rig.clock.now, rig.clock.nonce)
    let assert Ok(recovered) =
      j.recover(
        rig.path,
        rig.binding,
        rig.contract,
        rig.incarnation,
        rig.limits,
        clock,
        rig.profiles,
      )
      as "Recovery fences old unspent captures regardless of repeated ticks."
    assert j.accept_finite(recovered, timed(capture2, anchor2, 5000), request)
      == Error(j.Fenced)
    let assert Ok(history) =
      j.inspect_finite(recovered, rig.binding, capture2, request)
      as "History remains readable across concrete eras."
    assert j.captured_anchor(history) == j.captured_anchor(captured2)
    assert j.release(recovered) == Ok(Nil)
  })
}

pub fn linked_sqlite_profile_and_page_refusal_are_executable_test() {
  fixture("profile", 8, 50_000_000, fn(rig) {
    let assert Ok(connection) = sqlight.open(rig.path)
      as "The linked SQLite runtime is observed directly."
    let assert Ok(["3.50.4"]) =
      sqlight.query(
        "SELECT sqlite_version()",
        connection,
        [],
        decode.field(0, decode.string, decode.success),
      )
      as "The pinned rollback engine matches the DAL admission check."
    let assert Ok([4096]) =
      sqlight.query(
        "PRAGMA page_size",
        connection,
        [],
        decode.field(0, decode.int, decode.success),
      )
      as "The physical page size is fixed."
    let assert Ok(["delete"]) =
      sqlight.query(
        "PRAGMA journal_mode",
        connection,
        [],
        decode.field(0, decode.string, decode.success),
      )
      as "The persisted journal profile is DELETE."
    let assert Ok(Nil) =
      sqlight.exec(
        "PRAGMA max_page_count=131072; PRAGMA temp_store=MEMORY",
        connection,
      )
      as "Each original connection selects its nonpersistent settings explicitly."
    let assert Ok([131_072]) =
      sqlight.query(
        "PRAGMA max_page_count",
        connection,
        [],
        decode.field(0, decode.int, decode.success),
      )
      as "The 512MiB database page ceiling is effective."
    let assert Ok([2]) =
      sqlight.query(
        "PRAGMA temp_store",
        connection,
        [],
        decode.field(0, decode.int, decode.success),
      )
      as "The temporary allocation profile is MEMORY."
    let assert Ok(Nil) =
      sqlight.exec(
        "CREATE TABLE profile_allocation(payload BLOB); PRAGMA max_page_count=24",
        connection,
      )
      as "The fixture lowers only its independent allocation ceiling."
    assert result_is_error(sqlight.exec(
      "INSERT INTO profile_allocation VALUES(zeroblob(1048576))",
      connection,
    ))
    let assert Ok(Nil) = sqlight.close(connection)
      as "The original control retains no long-lived reader."
    Nil
  })
}

fn fixture(label: String, rows: Int, bytes: Int, run: fn(Rig) -> Nil) -> Nil {
  let directory =
    "/private/tmp/loom-lsp-"
    <> label
    <> "-"
    <> bit_array.base16_encode(crypto.strong_random_bytes(8))
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
    as "A private fixture directory is created."
  let generator = ids.generator(clock.fixed(1000), 800)
  let #(session, generator) = ids.mint_session(generator)
  let #(incarnation, _) = ids.mint_entry(generator)
  let assert Ok(selector) = workspace.selector("executor", "workspace")
    as "The selector is valid."
  let assert Ok(wbinding) = workspace.registered_binding(selector, 1, 1)
    as "Both authority epochs are retained."
  let scope = workspace.scope(session, wbinding)
  let enrollment = digest_of(<<1>>)
  let contract = digest_of(<<2>>)
  let assert Ok(key) = g.key(scope, contract, 1)
    as "The complete first generation is valid."
  let binding = j.binding(key, enrollment)
  let assert Ok(limits) = j.limits(rows, bytes)
    as "The fixture lowers existing hard ceilings."
  let assert Ok(profiles) =
    id.enrolled_profiles(
      scope,
      enrollment,
      list.map([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], fn(n) {
        id.Profile("server" <> int.to_string(n), "/workspace")
      }),
    )
    as "All sixteen profiles retain their original enrolled order."
  let assert Ok(started) =
    actor.new(#(-1000, 0))
    |> actor.on_message(fn(state, message) {
      case message {
        Tick(reply) -> {
          process.send(reply, state.0)
          actor.continue(state)
        }
        SetTick(value) -> actor.continue(#(value, state.1))
        Count(reply) -> {
          process.send(reply, state.1)
          actor.continue(state)
        }
        Nonce(reply) -> {
          process.send(reply, <<state.1:size(256)>>)
          actor.continue(#(state.0, state.1 + 1))
        }
      }
    })
    |> actor.start
    as "The fixture clock has a serialized original owner."
  let time = started.data
  let assert Ok(era) = id.clock_era("00000000-0000-4000-8000-000000000001")
    as "The host-installed test era is canonical."
  let clock =
    j.Clock(era, fn() { process.call(time, 1000, Tick) }, fn() {
      process.call(time, 1000, Nonce)
    })
  let path = directory <> "/lsp.db"
  let assert Ok(store) =
    j.fresh(path, binding, contract, incarnation, limits, clock, profiles)
    as "The exact SQLite LSP profile opens before admission."
  run(Rig(
    path,
    store,
    binding,
    contract,
    incarnation,
    limits,
    clock,
    time,
    profiles,
    scope,
    enrollment,
  ))
  let _ = j.release(store)
  let assert Ok(Nil) = simplifile.delete(directory)
    as "Every fixture file is removed after custody joins."
  Nil
}

fn raw(value: mp.MsgPackValue) -> BitArray {
  let assert Ok(bytes) = mp.encode(value)
    as "Fixture canonical encoding succeeds."
  bytes
}

fn digest_of(bytes: BitArray) -> g.Digest {
  let assert Ok(digest) = g.digest(crypto.hash(crypto.Sha256, bytes))
    as "SHA-256 is exactly 32 bytes."
  digest
}

fn result_is_error(value: Result(a, e)) -> Bool {
  case value {
    Error(_) -> True
    Ok(_) -> False
  }
}
