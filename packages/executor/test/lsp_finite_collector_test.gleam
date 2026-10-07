//// Pure finite reducer controls joined to actual original SQLite custody.
//// Callback witnesses model only future trusted physical joins, never production grants.

import broker/dispatch
import broker/exec
import broker/framing
import core/clock
import core/generation as g
import core/ids
import core/lsp_command as id
import core/msgpack as mp
import core/remote_tool
import core/workspace
import executor/remote/internal/lsp_finite_collector as c
import executor/remote/internal/lsp_finite_plan as plan
import executor/remote/lsp_journal as j
import executor/remote/lsp_wire as wire
import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lsp/query
import simplifile
import sqlight
import tools/grep
import weft

type Rig {
  Rig(
    path: String,
    store: j.Store,
    binding: j.Binding,
    contract: g.Digest,
    incarnation: ids.EntryId,
    limits: j.Limits,
    clock: j.Clock,
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

pub fn original_claim_offer_cas_and_exact_store_test() {
  fixture("finite-original", 24, 200_000_000, fn(rig) {
    let #(request, capture, claim, ref, reserved) = admitted(rig, 1)
    let offer = raw(mp.ArrayValue([mp.IntValue(1)]))
    assert j.verify_finite_claim(
        rig.store,
        rig.binding,
        claim,
        rig.clock.era,
        request,
      )
      == Ok(Nil)
    assert j.verify_finite_claim(
        rig.store,
        rig.binding,
        claim,
        rig.clock.era,
        wire.Diagnostics(None),
      )
      == Error(j.Conflict)
    let assert Ok(era) = id.clock_era("00000000-0000-4000-8000-000000000002")
      as "Another original era is data, not provenance."
    assert j.verify_finite_claim(rig.store, rig.binding, claim, era, request)
      == Error(j.Fenced)
    let assert Ok(j.FreshPlacement(offered)) =
      j.retain_finite_offer(claim, reserved, offer, fn(_, _) { Ok(Nil) })
      as "First original placement commits once."
    assert j.retain_finite_offer(claim, reserved, offer, fn(_, _) { Ok(Nil) })
      == Ok(j.RetainedPlacement(offered))
    assert j.retain_finite_offer(
        claim,
        reserved,
        raw(mp.ArrayValue([])),
        fn(_, _) { Ok(Nil) },
      )
      == Error(j.Conflict)
    let associated = associate(rig, offered)
    let assert Ok(j.FreshCommand(command)) =
      j.start_command(rig.store, associated, Some(claim))
      as "Original native association precedes claim."
    assert j.verify_command_claim(
        rig.store,
        rig.binding,
        command,
        claim,
        rig.clock.era,
        ref,
        request,
        None,
      )
      == Ok(Nil)
    let assert Ok(changed_key) = g.key(rig.scope, rig.contract, 2)
      as "Another generation has a distinct exact binding."
    assert j.verify_command_claim(
        rig.store,
        j.binding(changed_key, rig.enrollment),
        command,
        claim,
        rig.clock.era,
        ref,
        request,
        None,
      )
      == Error(j.Conflict)
    let #(_, _, changed_claim, _, _) = admitted(rig, 2)
    assert j.verify_command_claim(
        rig.store,
        rig.binding,
        command,
        changed_claim,
        rig.clock.era,
        ref,
        request,
        None,
      )
      |> result.is_error
    assert j.command_claim_fields(command).0 == ref
    assert j.start_command(rig.store, associated, Some(claim)) |> result.is_ok
    let assert Ok(other) =
      j.recover(
        rig.path,
        rig.binding,
        rig.contract,
        rig.incarnation,
        rig.limits,
        rig.clock,
        rig.profiles,
      )
      as "Recovery creates a distinct historical Store, never a live original."
    assert j.verify_finite_claim(
        other,
        rig.binding,
        claim,
        rig.clock.era,
        request,
      )
      |> result.is_error
    assert j.verify_command_claim(
        other,
        rig.binding,
        command,
        claim,
        rig.clock.era,
        ref,
        request,
        None,
      )
      |> result.is_error
    let assert Ok(history) =
      j.inspect_finite(other, rig.binding, capture, request)
      as "The old exact request remains queryable."
    assert j.finite_disposition(history) == j.Unknown
    assert j.release(other) == Ok(Nil)
  })
}

pub fn suppressed_offer_and_commit_refusal_never_return_fresh_test() {
  list.each(
    [
      "CREATE TRIGGER suppress BEFORE UPDATE OF phase ON lsp_command WHEN NEW.phase=1 BEGIN SELECT RAISE(IGNORE); END",
      "PRAGMA foreign_keys=ON; CREATE TABLE missing(id INTEGER PRIMARY KEY); CREATE TABLE dependent(id INTEGER REFERENCES missing(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_commit AFTER UPDATE OF phase ON lsp_command WHEN NEW.phase=1 BEGIN INSERT INTO dependent VALUES(1); END",
    ],
    fn(trigger) {
      fixture("finite-refusal", 12, 100_000_000, fn(rig) {
        let #(_, _, claim, _, reserved) = admitted(rig, 1)
        let assert Ok(connection) = sqlight.open(rig.path)
          as "A separate fixture connection installs the refusal."
        assert sqlight.exec(trigger, connection) == Ok(Nil)
        assert sqlight.close(connection) == Ok(Nil)
        assert j.retain_finite_offer(
            claim,
            reserved,
            raw(mp.ArrayValue([mp.IntValue(1)])),
            fn(_, _) { Ok(Nil) },
          )
          |> result.is_error
      })
    },
  )
}

pub fn copied_claim_concurrent_offer_has_one_committed_placement_test() {
  fixture("finite-concurrent", 12, 100_000_000, fn(rig) {
    let #(_, _, claim, _, reserved) = admitted(rig, 1)
    let effect = fn() {
      j.retain_finite_offer(
        claim,
        reserved,
        raw(mp.ArrayValue([mp.IntValue(1)])),
        fn(_, _) { Ok(Nil) },
      )
    }
    let outcomes =
      weft.new([effect, effect])
      |> weft.limit(2)
      |> weft.deadline(2000)
      |> weft.start
    let values = weft.values(outcomes)
    assert list.length(values) == 2
    assert list.length(
        list.filter(values, fn(value) {
          case value {
            j.FreshPlacement(_) -> True
            j.RetainedPlacement(_) -> False
          }
        }),
      )
      == 1
    assert list.length(
        list.filter(values, fn(value) {
          case value {
            j.FreshPlacement(_) -> False
            j.RetainedPlacement(_) -> True
          }
        }),
      )
      == 1
  })
}

pub fn complete_raw_and_per_invocation_inventory_edges_test() {
  fixture("finite-full-raw", 12, 100_000_000, fn(rig) {
    let #(request, _, claim, ref, _) = admitted(rig, 1)
    let assert Ok(original) =
      c.new(
        ref,
        request,
        rig.profiles,
        None,
        j.finite_control(claim),
        rig.clock.era,
        -1000,
      )
      as "Original finite control is immutable."
    let chunk = bit_array.from_string(string.repeat("x", 32_768))
    let full =
      int.range(0, 256, with: original, run: fn(state, n) {
        case n == 128 {
          True -> {
            assert c.output(
                state,
                n + 1,
                framing.Stdout,
                <<1>>,
                4_194_305,
                framing.OutputComplete,
                rig.clock.era,
                -1000,
              )
              == Error(c.CollectionLimit)
          }
          False -> Nil
        }
        let stream = case n < 128 {
          True -> framing.Stdout
          False -> framing.Stderr
        }
        let total = { n % 128 + 1 } * 32_768
        let assert Ok(#(held, credit)) =
          c.output(
            state,
            n + 1,
            stream,
            chunk,
            total,
            framing.OutputComplete,
            rig.clock.era,
            -1000,
          )
          as "Each original credit admits at most32KiB."
        let assert Ok(open) = c.consumed(held, credit)
          as "Exactly one shared credit is consumed."
        open
      })
    assert c.raw_bytes(full) == 8_388_608
    assert c.output(
        full,
        257,
        framing.Stdout,
        <<1>>,
        4_194_305,
        framing.OutputComplete,
        rig.clock.era,
        -1000,
      )
      == Error(c.CollectionLimit)
    let output =
      int.range(0, 50, with: "", run: fn(text, n) {
        let prefix = int.to_string(n)
        let path = prefix <> string.repeat("x", 8192 - string.byte_size(prefix))
        text <> string.repeat(match_line(path, 1), 4)
      })
    let assert Ok(hits) = grep.registered_matches(bit_array.from_string(output))
      as "The exact per-profile hit inventory is bounded before retention."
    let cold =
      int.range(
        0,
        16,
        with: c.cold_inventory(rig.profiles),
        run: fn(state, ordinal) {
          let assert Ok(next) = c.charge_hits(state, ordinal, hits)
            as "Sixteen original profiles are charged sequentially."
          next
        },
      )
    assert c.inventory_bytes(cold) == #(26_316_800, 0)
    assert c.charge_hits(cold, 16, hits) == Error(c.InvalidCollection)
    let path = string.repeat("x", 8192)
    let root = string.repeat("r", 8192)
    let label = string.repeat("s", 128)
    let grouped =
      int.range(0, 3200, with: cold, run: fn(state, _) {
        let assert Ok(next) = c.charge_group(state, path, root, label)
          as "Group content has a separately reserved charge before construction."
        next
      })
    assert c.inventory_bytes(grouped) == #(26_316_800, 53_043_200)
    assert 26_316_800 + 53_043_200 + c.raw_bytes(full) == 87_748_608
    assert c.charge_group(grouped, path, root, label)
      == Error(c.CollectionLimit)
  })
}

pub fn one_shared_output_credit_era_and_absorbing_fence_test() {
  fixture("finite-credit", 12, 100_000_000, fn(rig) {
    let #(request, _, claim, ref, _) = admitted(rig, 1)
    let control = j.finite_control(claim)
    let assert Ok(state) =
      c.new(ref, request, rig.profiles, None, control, rig.clock.era, -1000)
      as "Only complete original timing constructs this pure collector."
    let assert Ok(#(held, credit)) =
      c.output(
        state,
        1,
        framing.Stdout,
        <<1, 2>>,
        2,
        framing.OutputComplete,
        rig.clock.era,
        -1000,
      )
      as "Admission charges bytes before issuing the sole credit."
    assert c.output(
        held,
        2,
        framing.Stderr,
        <<3>>,
        1,
        framing.OutputComplete,
        rig.clock.era,
        -1000,
      )
      == Error(c.FencedCollection)
    assert c.terminal(held, completed(2, 0, 0), framing.ProtocolComplete)
      == Error(c.FencedCollection)
    let assert Ok(open) = c.consumed(held, credit)
      as "Exactly one consumption opens the shared window."
    assert c.consumed(open, credit) == Error(c.FencedCollection)
    assert c.output(
        open,
        2,
        framing.Stderr,
        <<3>>,
        2,
        framing.OutputComplete,
        rig.clock.era,
        -1000,
      )
      == Error(c.InvalidCollection)
    assert c.output(
        open,
        2,
        framing.Stderr,
        <<3>>,
        1,
        framing.OutputTruncated,
        rig.clock.era,
        -1000,
      )
      == Error(c.FencedCollection)
    assert c.new(ref, request, rig.profiles, None, control, rig.clock.era, 4000)
      == Error(c.FencedCollection)
    let assert Ok(era) = id.clock_era("00000000-0000-4000-8000-000000000002")
      as "A different era cannot renew credit."
    assert c.new(ref, request, rig.profiles, None, control, era, -1000)
      == Error(c.FencedCollection)
    let fenced = c.fence(held)
    assert c.raw_bytes(fenced) == 0
    assert c.consumed(fenced, credit) == Error(c.FencedCollection)
    assert !c.ready(fenced)
  })
}

pub fn raw_projection_commit_reusable_are_distinct_test() {
  fixture("finite-projection", 12, 100_000_000, fn(rig) {
    let #(request, _, claim, ref, reserved) = admitted(rig, 1)
    let assert Ok(j.FreshPlacement(offered)) =
      j.retain_finite_offer(
        claim,
        reserved,
        raw(mp.ArrayValue([mp.IntValue(1)])),
        fn(_, _) { Ok(Nil) },
      )
      as "The original fixed offer wins its CAS."
    let associated = associate(rig, offered)
    let assert Ok(j.FreshCommand(_)) =
      j.start_command(rig.store, associated, Some(claim))
      as "A single native command claim commits."
    let assert Ok(started) =
      j.inspect_command(rig.store, rig.binding, ref, request, None)
      as "Exact command readback retains its original request."
    let assert Ok(state) =
      c.new(
        ref,
        request,
        rig.profiles,
        None,
        j.finite_control(claim),
        rig.clock.era,
        -1000,
      )
      as "The bounded reducer retains the original timing."
    let bytes = bit_array.from_string(match_line("/workspace/a", 1))
    let size = bit_array.byte_size(bytes)
    let assert Ok(#(held, credit)) =
      c.output(
        state,
        1,
        framing.Stdout,
        bytes,
        size,
        framing.OutputComplete,
        rig.clock.era,
        -1000,
      )
      as "The one raw chunk is charged."
    let assert Ok(state) = c.consumed(held, credit)
      as "The original credit drains first."
    let assert Ok(bad) =
      c.terminal(state, completed(size + 1, 0, 0), framing.ProtocolComplete)
      as "Terminal evidence is distinct from validation."
    assert c.project(bad) == Error(c.IncompleteCollection)
    let assert Ok(state) =
      c.terminal(state, completed(size, 0, 0), framing.ProtocolComplete)
      as "Actual terminal totals equal admitted bytes."
    let assert Ok(#(state, projection)) = c.project(state)
      as "Complete rg JSON yields its bounded projection."
    assert c.project(state) == Ok(#(state, projection))
    assert c.raw_bytes(state) == size
    assert !c.ready(state)
    assert c.projection_committed(state, projection, started)
      == Error(c.InvalidCollection)
    let assert #(terminal, value, Some(hits)) = c.projection_fields(projection)
      as "Search projection retains its bounded hit content."
    assert grep.registered_hits(hits) == [grep.SearchHit("/workspace/a", 1)]
    let assert Ok(finishing) =
      j.retain_terminal(rig.store, started, terminal, value, fn(_, _, _) {
        Ok(Nil)
      })
      as "Real SQLite COMMIT retains immutable projection and terminal."
    let assert Ok(state) = c.projection_committed(state, projection, finishing)
      as "Only matching durable readback releases raw."
    assert c.raw_bytes(state) == 0
    assert !c.ready(state)
    let association = j.command_evidence(finishing).2
    let assert Ok(ref_bytes) = wire.encode_command(ref)
      as "Canonical ref digest is original."
    let witness =
      raw(
        mp.ArrayValue([
          mp.IntValue(1),
          mp.BinaryValue(crypto.hash(crypto.Sha256, ref_bytes)),
          mp.BinaryValue(crypto.hash(crypto.Sha256, association)),
          mp.BinaryValue(crypto.hash(crypto.Sha256, terminal)),
          mp.IntValue(1),
        ]),
      )
    let assert Ok(state) = c.reusable(state, witness)
      as "A distinct trusted fixture event retains the exact native witness."
    assert c.reuse_committed(state, finishing) == Error(c.IncompleteCollection)
    let assert Ok(retained) =
      j.retain_reusable(rig.store, finishing, witness, fn(_, _) { Ok(Nil) })
      as "Original physical witness callback is explicitly fixture-only."
    let assert Ok(state) = c.reuse_committed(state, retained)
      as "Exact association and terminal digests match durable witness."
    assert c.ready(state)
    assert c.reuse_committed(state, retained) == Ok(state)
  })
}

pub fn projection_capacity_129_hits_test() {
  projection_capacity("finite-projection-129", 129, 32)
}

pub fn projection_capacity_200_hits_test() {
  projection_capacity("finite-projection-200", 200, 32)
}

pub fn projection_capacity_maximum_paths_test() {
  projection_capacity("finite-projection-max-paths", 200, 8192)
}

fn projection_capacity(label: String, count: Int, path_bytes: Int) {
  fixture(label, 12, 100_000_000, fn(rig) {
    let #(request, _, claim, ref, reserved) = admitted(rig, 1)
    let assert Ok(j.FreshPlacement(offered)) =
      j.retain_finite_offer(
        claim,
        reserved,
        raw(mp.ArrayValue([mp.IntValue(1)])),
        fn(_, _) { Ok(Nil) },
      )
      as "The original placement commits once."
    let associated = associate(rig, offered)
    let assert Ok(j.FreshCommand(_)) =
      j.start_command(rig.store, associated, Some(claim))
      as "The original command claim commits before output."
    let assert Ok(started) =
      j.inspect_command(rig.store, rig.binding, ref, request, None)
      as "The actual original command readback is retained."
    let assert Ok(state) =
      c.new(
        ref,
        request,
        rig.profiles,
        None,
        j.finite_control(claim),
        rig.clock.era,
        -1000,
      )
      as "The collector retains its admitted control."

    // Four hits per path keep the maximum fixture within all enrolled Search limits.
    let output =
      int.range(0, count, with: "", run: fn(text, n) {
        let prefix = "/workspace/file" <> int.to_string(n / 4) <> "/"
        let path =
          prefix <> string.repeat("x", path_bytes - string.byte_size(prefix))
        text <> match_line(path, n % 4 + 1)
      })
    let bytes = bit_array.from_string(output)
    let size = bit_array.byte_size(bytes)
    let chunks = { size + 32_767 } / 32_768
    let state =
      int.range(0, chunks, with: state, run: fn(state, n) {
        let offset = n * 32_768
        let total = int.min(size, offset + 32_768)
        let assert Ok(chunk) = bit_array.slice(bytes, offset, total - offset)
          as "Each fixture chunk respects the real shared output window."
        let assert Ok(#(held, credit)) =
          c.output(
            state,
            n + 1,
            framing.Stdout,
            chunk,
            total,
            framing.OutputComplete,
            rig.clock.era,
            -1000,
          )
          as "The bounded original stdout chunk is admitted."
        let assert Ok(state) = c.consumed(held, credit)
          as "Only the actual admitted ordinal returns credit."
        state
      })
    let assert Ok(state) =
      c.terminal(state, completed(size, 0, 0), framing.ProtocolComplete)
      as "Complete terminal evidence matches the actual raw totals."
    let assert Ok(#(state, projection)) = c.project(state)
      as "Every admitted Search boundary projects through its registered encoder."
    let assert #(terminal, value, Some(hits)) = c.projection_fields(projection)
      as "Search retains its exact checked hits."
    assert list.length(grep.registered_hits(hits)) == count
    assert bit_array.byte_size(value) <= 1_644_800
    assert c.raw_bytes(state) == size
    assert c.projection_committed(state, projection, started)
      == Error(c.InvalidCollection)
    assert c.raw_bytes(state) == size

    // The original SQL transaction and independent readback precede raw release.
    let assert Ok(finishing) =
      j.retain_terminal(rig.store, started, terminal, value, fn(_, _, _) {
        Ok(Nil)
      })
      as "The actual SQLite terminal and full projection COMMIT succeeds."
    let assert Ok(retained) =
      j.inspect_command(rig.store, rig.binding, ref, request, None)
      as "The complete immutable projection reads back from original SQLite."
    assert retained == finishing
    let assert Ok(state) = c.projection_committed(state, projection, retained)
      as "Only exact committed terminal and projection readback releases raw."
    assert c.raw_bytes(state) == 0
    assert !c.ready(state)
  })
}

pub fn complete_malformed_search_never_returns_prefix_test() {
  fixture("finite-malformed", 12, 100_000_000, fn(rig) {
    let #(request, _, claim, ref, _) = admitted(rig, 1)
    let assert Ok(state) =
      c.new(
        ref,
        request,
        rig.profiles,
        None,
        j.finite_control(claim),
        rig.clock.era,
        -1000,
      )
      as "The original query has bounded custody."
    let bytes =
      bit_array.from_string(match_line("/workspace/a", 1) <> "invalid\n")
    let size = bit_array.byte_size(bytes)
    let assert Ok(#(held, credit)) =
      c.output(
        state,
        1,
        framing.Stdout,
        bytes,
        size,
        framing.OutputComplete,
        rig.clock.era,
        -1000,
      )
      as "Raw framing remains distinct from JSON validation."
    let assert Ok(state) = c.consumed(held, credit)
      as "Consumption releases only the admitted credit."
    let assert Ok(state) =
      c.terminal(state, completed(size, 0, 0), framing.ProtocolComplete)
      as "Native zero exit cannot validate malformed JSON."
    assert c.project(state) == Error(c.MalformedSearch)
    assert c.raw_bytes(state) == size
  })
}

pub fn startup_finite_parent_and_protocol_failure_do_not_claim_readiness_test() {
  fixture("finite-startup", 20, 150_000_000, fn(rig) {
    let #(request, _, claim, _, _) = admitted(rig, 1)
    let #(_, lease, input) = identity(rig, 1, request)
    let assert Ok(_) =
      j.reserve_lease(rig.store, lease, input, "gleam", "/workspace")
      as "Actual original lease reservation precedes its closed startup commands."
    list.each([id.Probe, id.Prepare], fn(role) {
      let assert Ok(ref) = id.lsp_startup_command(lease, role)
        as "Probe and Prepare retain their real original startup lease."
      let assert Ok(reserved) = j.reserve_command(rig.store, ref, request, None)
        as "Each finite startup command is independently charged."
      let assert Ok(j.FreshPlacement(offered)) =
        j.retain_finite_offer(
          claim,
          reserved,
          raw(mp.ArrayValue([mp.IntValue(1)])),
          fn(_, _) { Ok(Nil) },
        )
        as "The actual live finite control fixes the startup offer."
      let associated = associate(rig, offered)
      let assert Ok(j.FreshCommand(command)) =
        j.start_command(rig.store, associated, Some(claim))
        as "The original finite and actual startup lease jointly precede dispatch claim."
      assert j.verify_command_claim(
          rig.store,
          rig.binding,
          command,
          claim,
          rig.clock.era,
          ref,
          request,
          None,
        )
        == Ok(Nil)
      let assert Ok(state) =
        c.new(
          ref,
          request,
          rig.profiles,
          None,
          j.finite_control(claim),
          rig.clock.era,
          -1000,
        )
        as "The reducer accepts only a closed finite startup recipe."
      assert c.reusable(state, raw(mp.ArrayValue([])))
        == Error(c.FencedCollection)
      let assert Ok(failed) =
        c.terminal(state, completed(0, 0, 0), framing.ProtocolFailed)
        as "A zero exit can still carry protocol failure."
      assert c.project(failed) == Error(c.IncompleteCollection)
      let assert Ok(state) =
        c.terminal(state, completed(0, 0, 0), framing.ProtocolComplete)
        as "Only complete native output permits a command projection."
      let assert Ok(#(state, projection)) = c.project(state)
        as "Startup projection means command completion only."
      assert c.projection_fields(projection).2 == None
      assert !c.ready(state)
    })
    let assert Ok(server) = id.lsp_startup_command(lease, id.ServerLease)
      as "The persistent server remains a separate closed role."
    assert c.new(
        server,
        request,
        rig.profiles,
        None,
        j.finite_control(claim),
        rig.clock.era,
        -1000,
      )
      == Error(c.InvalidCollection)
  })
}

pub fn recipe_caps_and_sequential_cold_inventory_test() {
  assert plan.wall_ms(plan.Search) == 10_000
  assert plan.wall_ms(plan.Prepare) == 60_000
  assert plan.stream_bytes(plan.Search) == 4_194_304
  assert plan.stream_bytes(plan.Prepare) == 1_048_576
  assert plan.stream_bytes(plan.Probe) == 262_144
  fixture("finite-cold", 12, 100_000_000, fn(rig) {
    let assert Ok(hits) =
      grep.registered_matches(
        bit_array.from_string(match_line("/workspace/a", 1)),
      )
      as "One bounded complete projection is retained."
    let original = c.cold_inventory(rig.profiles)
    assert c.charge_hits(original, 1, hits) == Error(c.InvalidCollection)
    let assert Ok(charged) = c.charge_hits(original, 0, hits)
      as "The first checked profile is charged exactly once."
    assert c.charge_hits(charged, 0, hits) == Error(c.InvalidCollection)
    let assert Ok(grouped) =
      c.charge_group(charged, "/workspace/a", "/workspace", "server0")
      as "Grouping has its independent charge."
    assert c.inventory_bytes(grouped) == #(44, 93)
    assert c.charge_group(grouped, "/workspace/a", "/workspace", "server0")
      == Error(c.CollectionLimit)
    assert c.charge_group(
        charged,
        "/workspace/a",
        "/workspace",
        string.repeat("x", 129),
      )
      == Error(c.CollectionLimit)
  })
}

fn admitted(rig: Rig, number: Int) {
  let request = wire.Definition(query.SymbolQuery("name", None, None))
  let #(capture, _, _) = identity(rig, number, request)
  let assert Ok(captured) = j.capture_finite(rig.store, capture, request)
    as "Capture COMMIT retains the first original nonce and E0."
  let assert Ok(#(anchor, _)) = j.captured_anchor(captured)
    as "The immutable anchor is retained."
  let invocation = timed(capture, anchor, 5000)
  let assert Ok(j.FreshFinite(claim)) =
    j.accept_finite(rig.store, invocation, request)
    as "Original first admission returns one live claim."
  let assert Ok(profile) = id.checked_profile(rig.profiles, 0)
    as "The enrolled ordinal is checked."
  let assert Ok(ref) =
    id.lsp_search_command(invocation, profile, id.cold_search_root(profile))
    as "Search retains its exact full finite parent."
  let assert Ok(reserved) = j.reserve_command(rig.store, ref, request, None)
    as "The full eventual reservation precedes offer."
  #(request, capture, claim, ref, reserved)
}

fn associate(rig: Rig, offered: j.CommandReadback) {
  let assert Ok(associated) =
    j.associate(
      rig.store,
      offered,
      raw(mp.ArrayValue([mp.IntValue(2)])),
      raw(mp.ArrayValue([mp.IntValue(3)])),
      fn(_, _, _) { Ok(Nil) },
    )
    as "Trusted fixture evidence retains the original native association."
  associated
}

fn completed(out: Int, err: Int, code: Int) -> dispatch.Terminal {
  dispatch.Completed(exec.ExecResult(
    code,
    0,
    out,
    err,
    False,
    False,
    [],
    False,
    1,
    False,
    False,
  ))
}

fn match_line(path: String, line: Int) -> String {
  "{\"type\":\"match\",\"data\":{\"path\":{\"text\":\""
  <> path
  <> "\"},\"line_number\":"
  <> int.to_string(line)
  <> ",\"lines\":{\"text\":\"hit\"}}}\n"
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
  let assert Ok(era) = id.clock_era("00000000-0000-4000-8000-000000000001")
    as "The trusted fixture installs one concrete original era."
  let clock = j.Clock(era, fn() { -1000 }, fn() { <<0:size(256)>> })
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
