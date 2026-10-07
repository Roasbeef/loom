//// Complete LSP wire tests preserve original identities and bounded payloads.

import core/clock
import core/generation as g
import core/ids
import core/lsp_command as identity
import core/msgpack as m
import core/remote_tool
import core/workspace
import executor/remote/lsp_wire as wire
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import lsp/observation as o
import lsp/query as q

fn asked() -> q.SymbolQuery {
  q.SymbolQuery("name", Some("src/main.gleam"), Some(1))
}

fn site() -> q.Site {
  q.Site("src/main.gleam", 1, 2, "pub fn name() { Nil }\r")
}

fn original(request: wire.Request) {
  let generator = ids.generator(clock.fixed(1000), 41)
  let #(session, generator) = ids.mint_session(generator)
  let #(op, generator) = ids.mint_op(generator)
  let #(request_id, _) = ids.mint_entry(generator)
  let assert Ok(selector) = workspace.selector("executor", "workspace")
    as "The registered selector is valid."
  let assert Ok(binding) = workspace.registered_binding(selector, 1, 1)
    as "The binding has both exact epochs."
  let scope = workspace.scope(session, binding)
  let assert Ok(step) = workspace.step("lsp.query")
    as "The original step is valid."
  let assert Ok(input) = wire.semantic_input(request)
    as "The codec fixes canonical semantic bytes and the actual digest."
  let #(_, digest, _) = identity.input_fields(input)
  let assert Ok(system) = remote_tool.system_child(session, "lsp", 2)
    as "The lease uses the actual lsp system family."
  let assert Ok(tool) =
    remote_tool.key(
      session,
      op,
      "lsp.query",
      0,
      string.repeat("0", 64),
      request_id,
    )
    as "The actual admitted tool retains its complete original coordinates."
  let assert Ok(origin) =
    remote_tool.tool_child(
      tool,
      remote_tool.AdmittedCapability(
        "lsp.definition",
        0,
        remote_tool.SemanticWorkspace,
      ),
    )
    as "The finite request uses its actual original admitted capability origin."
  let assert Ok(child) =
    identity.original_child_ref(origin, scope, op, step, request_id, digest)
    as "The complete original child retains its input digest."
  let assert Ok(parent) = identity.parent_control(child)
    as "The durable original reference fits its own bound."
  let assert Ok(capture) =
    identity.lsp_capture(
      origin,
      scope,
      op,
      step,
      request_id,
      input,
      parent,
      digest,
      digest,
    )
    as "The finite capture names exactly that controlled original child."
  let assert Ok(era) =
    identity.clock_era("00000000-0000-4000-8000-000000000001")
    as "The trusted era has canonical spelling."
  let assert Ok(parent_digest) = wire.parent_digest(parent)
    as "The anchor retains the actual canonical complete parent digest."
  let anchor = identity.finite_anchor(era, digest, parent_digest)
  let assert Ok(control) =
    identity.verify_parent_control(capture, parent, 500_000, 0, case request {
      wire.Observe(_) -> Some(0)
      _ -> None
    })
    as "The original parent supplies its actual remaining allowance."
  let assert Ok(proposal) =
    identity.finite_timing_proposal(anchor, control, parent_digest)
    as "The immutable timing binds the same original control digest."
  let assert Ok(invocation) =
    identity.lsp_invocation(capture, proposal, parent_digest)
    as "The finite original retains exactly one proposal."
  let assert Ok(lease) =
    identity.lsp_service_key(
      system,
      scope,
      op,
      step,
      request_id,
      digest,
      digest,
      digest,
    )
    as "The actual system lease keeps separate startup authority."
  #(scope, digest, child, capture, invocation, lease, anchor)
}

fn raw(value: m.MsgPackValue) -> BitArray {
  let assert Ok(bytes) = m.encode(value)
    as "The malformed semantic fixture still has valid MessagePack framing."
  bytes
}

pub fn all_complete_request_variants_and_omitted_observation_inference_roundtrip_test() {
  let #(_, _, child, _, _, _, _) = original(wire.Definition(asked()))
  let requests = [
    wire.Definition(asked()),
    wire.References(asked()),
    wire.Hover(asked()),
    wire.Outline("src/main.gleam"),
    wire.Calls(asked(), q.Incoming),
    wire.Calls(asked(), q.Outgoing),
    wire.Diagnostics(None),
    wire.Diagnostics(Some("src/main.gleam")),
    wire.PrepareRename(asked(), "renamed"),
    wire.ApplyRename(asked(), "renamed", child),
    wire.AfterWrite("src/main.gleam", child),
    wire.Observe(o.Request("", "", ["src/main.gleam"], [asked()])),
  ]
  list.each(requests, fn(request) {
    let assert Ok(bytes) = wire.encode_request(request)
      as "Every closed request includes all original fields."
    assert wire.decode_request(bytes) == Ok(request)
    assert wire.decode_request(<<bytes:bits, 0>>)
      == Error(wire.PreflightRefused)
  })
}

pub fn all_interactive_successes_and_complete_reports_roundtrip_test() {
  let #(_, _, child, _, _, _, _) = original(wire.Definition(asked()))
  let diag = q.Diagnostic(site(), q.SeverityWarning, "warning\r\nfull detail")
  let cases = [
    #(wire.Definition(asked()), wire.Definitions(q.Served([site()], q.Warm))),
    #(
      wire.References(asked()),
      wire.ReferenceSites(q.Served(
        [q.Reference(site(), Some("Outer.inner"))],
        q.Started("gleam"),
      )),
    ),
    #(
      wire.Hover(asked()),
      wire.Hovered(q.Served(
        q.Hover(site(), "full hover\u{0000}contents"),
        q.Warm,
      )),
    ),
    #(
      wire.Outline("src/main.gleam"),
      wire.Outlined(q.Served(
        [
          q.SymbolEntry("name", "function", Some("fn()"), site(), [
            q.SymbolEntry("child", "variable", None, site(), []),
          ]),
        ],
        q.Warm,
      )),
    ),
    #(
      wire.Calls(asked(), q.Incoming),
      wire.Called(q.Served([q.Call("caller", site(), [site(), site()])], q.Warm)),
    ),
    #(
      wire.Diagnostics(None),
      wire.Diagnosed(q.Served(q.Settled([diag]), q.Warm)),
    ),
    #(
      wire.Diagnostics(None),
      wire.Diagnosed(q.Served(q.Unsettled([diag]), q.Warm)),
    ),
    #(
      wire.PrepareRename(asked(), "renamed"),
      wire.RenamePrepared(q.Served(
        [q.FileEdit("src/main.gleam", "exact base", "exact edited", 2)],
        q.Warm,
      )),
    ),
    #(
      wire.ApplyRename(asked(), "renamed", child),
      wire.RenameApplied(q.Served(
        q.RenameReport(
          [
            q.Landed("src/main.gleam", 2),
            q.Rejected("src/other.gleam", "stale"),
            q.NotAttempted("src/third.gleam"),
          ],
          q.Unsettled([diag]),
        ),
        q.Warm,
      )),
    ),
    #(wire.AfterWrite("src/main.gleam", child), wire.WriteObserved(None)),
    #(
      wire.AfterWrite("src/main.gleam", child),
      wire.WriteObserved(Some(q.Settled([diag]))),
    ),
  ]
  list.each(cases, fn(pair) {
    let assert Ok(bytes) = wire.encode_result(pair.0, pair.1)
      as "Complete interactive rows and report variants fit their reservation."
    assert wire.decode_result(pair.0, bytes) == Ok(pair.1)
    assert wire.decode_result(wire.Observe(o.Request("", "", [], [])), bytes)
      == Error(wire.ResponseMismatch)
  })
}

pub fn closed_errors_limits_and_response_discriminants_roundtrip_test() {
  let expected = wire.Definition(asked())
  list.each(
    [
      q.NoServer("none"),
      q.Unsupported("gleam", "calls"),
      q.NotFound(asked(), Some("/checkout")),
      q.Ambiguous([site()]),
      q.ServerRefused("refused"),
      q.Unavailable("expired"),
    ],
    fn(error) {
      let answer = wire.QueryFailed(error)
      let assert Ok(bytes) = wire.encode_result(expected, answer)
        as "The existing complete query failure remains closed."
      assert wire.decode_result(expected, bytes) == Ok(answer)
    },
  )
  let observe = wire.Observe(o.Request("", "", [], []))
  list.each(
    [
      o.InvalidScope("invalid"),
      o.QueryFailed(q.NoServer("none")),
      o.Changed("changed"),
      o.LimitExceeded("limit"),
      o.DeadlineExceeded,
    ],
    fn(error) {
      let answer = wire.ObservationFailed(error)
      let assert Ok(bytes) = wire.encode_result(observe, answer)
        as "Observation preserves its independent original failure family."
      assert wire.decode_result(observe, bytes) == Ok(answer)
    },
  )
  list.each([wire.Rows, wire.ContentBytes, wire.Inventory], fn(kind) {
    let assert Ok(bytes) = wire.encode_result(expected, wire.Limited(kind))
      as "A limit is explicit and never a successful prefix."
    assert wire.decode_result(expected, bytes) == Ok(wire.Limited(kind))
  })
  assert wire.encode_result(
      expected,
      wire.Hovered(q.Served(q.Hover(site(), "wrong"), q.Warm)),
    )
    == Error(wire.ResponseMismatch)
  assert wire.decode_result(
      expected,
      raw(m.ArrayValue([m.IntValue(1), m.IntValue(13), m.NilValue])),
    )
    == Error(wire.InvalidPayload)
}

pub fn finite_capture_timing_commands_and_result_envelopes_keep_exact_original_identity_test() {
  let request = wire.Definition(asked())
  let #(scope, digest, _, capture, invocation, lease, anchor) =
    original(request)
  let assert Ok(captured) = wire.encode_capture_envelope(capture, request)
    as "Preliminary capture has an unchanged semantic body."
  assert wire.decode_capture_envelope(captured) == Ok(#(capture, request))
  let assert Ok(submitted) =
    wire.encode_invocation_envelope(invocation, request)
    as "Timed Submit fits its complete content ceiling."
  assert wire.decode_invocation_envelope(submitted)
    == Ok(#(invocation, request))
  assert wire.encode_invocation(invocation, wire.Hover(asked()))
    == Error(wire.DigestMismatch)
  let assert Ok(anchor_bytes) = wire.encode_anchor(anchor)
    as "The capture reply has no executor-local E0."
  assert bit_array.byte_size(anchor_bytes) <= 128
  assert wire.decode_anchor(anchor_bytes) == Ok(anchor)
  let assert Ok(lease_bytes) = wire.encode_lease(lease)
    as "The lease retains nil timing and control fields."
  assert wire.decode_lease(lease_bytes) == Ok(lease)
  let assert Ok(inventory) =
    identity.enrolled_profiles(scope, digest, [
      identity.Profile("gleam", "/checkout"),
    ])
    as "The actual enrolled inventory is immutable."
  let assert Ok(profile) = identity.checked_profile(inventory, 0)
    as "The ordinal names the actual first enrolled profile."
  let assert Ok(search) =
    identity.lsp_search_command(
      invocation,
      profile,
      identity.cold_search_root(profile),
    )
    as "Cold search uses the exact enrolled workspace root."
  let assert Ok(search_bytes) = wire.encode_command(search)
    as "Search has the complete timed parent and checked root."
  assert wire.decode_command(search_bytes, request, inventory, None)
    == Ok(search)
  let assert Ok(selection) =
    identity.selected_project(profile, "gleam", "/checkout/sub")
    as "The manager retained its actual selected project."
  assert wire.decode_command(search_bytes, request, inventory, Some(selection))
    |> result.is_error
  list.each([identity.Probe, identity.Prepare, identity.ServerLease], fn(role) {
    let assert Ok(command) = identity.lsp_startup_command(lease, role)
      as "Startup is one of three closed lease roles."
    let assert Ok(bytes) = wire.encode_command(command)
      as "The complete startup command fits its header."
    assert wire.decode_command(bytes, request, inventory, None) == Ok(command)
  })
  let answer = wire.Definitions(q.Served([site()], q.Warm))
  let assert Ok(completed) =
    wire.encode_result_envelope(invocation, request, answer)
    as "The complete result is bound to the retained timed original."
  assert wire.decode_result_envelope(completed, invocation, request)
    == Ok(answer)
  let changed = raw(change_timing(identity.invocation_value(invocation)))
  let assert Ok(body) = wire.encode_result(request, answer)
    as "The replacement result still has valid complete semantic bytes."
  let size = bit_array.byte_size(changed)
  assert wire.decode_result_envelope(
      <<size:32, changed:bits, body:bits>>,
      invocation,
      request,
    )
    == Error(wire.InvalidPayload)
}

fn change_timing(value: m.MsgPackValue) -> m.MsgPackValue {
  let assert m.ArrayValue(fields) = value as "The invocation is a fixed array."
  m.ArrayValue(
    list.index_map(fields, fn(field, index) {
      case index {
        10 -> {
          let assert m.ArrayValue([version, era, nonce, _, parent]) = field
            as "The proposal has its exact five fields."
          m.ArrayValue([version, era, nonce, m.IntValue(1), parent])
        }
        _ -> field
      }
    }),
  )
}

pub fn request_and_result_preflight_refuse_raw_bombs_noncanonical_maps_and_extra_fields_test() {
  let bomb = <<0xdd, 0x7fffffff:32>>
  assert wire.decode_request(bomb) == Error(wire.PreflightRefused)
  assert wire.decode_result(wire.Definition(asked()), bomb)
    == Error(wire.PreflightRefused)
  assert wire.decode_request(<<1:1>>) == Error(wire.PreflightRefused)
  assert wire.decode_request(<<0x92, 0xcc, 0, 0x93, 0xa1, 120, 0xc0, 0xc0>>)
    == Error(wire.InvalidPayload)
  assert wire.decode_request(raw(m.ArrayValue([m.IntValue(0), m.MapValue([])])))
    == Error(wire.InvalidPayload)
  assert wire.decode_result(
      wire.Definition(asked()),
      raw(m.ArrayValue([m.IntValue(1), m.IntValue(0), m.MapValue([])])),
    )
    == Error(wire.InvalidPayload)
  let oversize = string.repeat("x", 131_073)
  assert wire.decode_request(raw(m.StringValue(oversize)))
    == Error(wire.PreflightRefused)
  assert wire.decode_capture_envelope(<<0:32, 0xc0>>)
    == Error(wire.PreflightRefused)
  assert wire.decode_capture_envelope(<<8193:32, 0xc0>>)
    == Error(wire.PreflightRefused)
  assert wire.decode_invocation_envelope(<<0xffffffff:32, 0xc0>>)
    == Error(wire.PreflightRefused)
  assert wire.decode_invocation_envelope(<<8192:32, 0xc0>>)
    == Error(wire.PreflightRefused)
  assert wire.encode_request(
      wire.Definition(q.SymbolQuery("name", None, Some(1))),
    )
    == Error(wire.InvalidPayload)
  assert wire.encode_request(wire.Outline("../escape"))
    == Error(wire.InvalidPayload)
  assert wire.encode_request(wire.PrepareRename(asked(), ""))
    == Error(wire.InvalidPayload)
}

pub fn complete_hover_and_rename_preimage_bytes_share_the_four_mib_reservation_test() {
  let expected = wire.Hover(asked())
  let clean = q.Site("x", 1, 1, "")
  let exact = string.repeat("x", 4_194_304 - 129)
  let answer = wire.Hovered(q.Served(q.Hover(clean, exact), q.Warm))
  let assert Ok(bytes) = wire.encode_result(expected, answer)
    as "All original hover contents exactly meet the shared accounting ceiling."
  assert wire.decode_result(expected, bytes) == Ok(answer)
  assert wire.encode_result(
      expected,
      wire.Hovered(q.Served(q.Hover(clean, exact <> "x"), q.Warm)),
    )
    == Error(wire.LimitExceeded)
  let rename = wire.PrepareRename(asked(), "renamed")
  let large = string.repeat("x", 2_097_120)
  assert wire.encode_result(
      rename,
      wire.RenamePrepared(q.Served([q.FileEdit("x", large, large, 1)], q.Warm)),
    )
    == Error(wire.LimitExceeded)
}

pub fn nested_call_sites_and_diagnostics_count_every_shared_row_test() {
  let small = q.Site("x", 1, 1, "")
  let expected = wire.Calls(asked(), q.Incoming)
  let answer =
    wire.Called(q.Served([q.Call("x", small, list.repeat(small, 9998))], q.Warm))
  let assert Ok(bytes) = wire.encode_result(expected, answer)
    as "One call row, its Site and 9998 at Sites exactly consume 10000 rows."
  assert wire.decode_result(expected, bytes) == Ok(answer)
  assert wire.encode_result(
      expected,
      wire.Called(q.Served(
        [q.Call("x", small, list.repeat(small, 9999))],
        q.Warm,
      )),
    )
    == Error(wire.LimitExceeded)
  let diagnostic = q.Diagnostic(small, q.SeverityInformation, "x")
  let exact =
    wire.Diagnosed(q.Served(q.Settled(list.repeat(diagnostic, 5000)), q.Warm))
  let assert Ok(bytes) = wire.encode_result(wire.Diagnostics(None), exact)
    as "Every diagnostic and nested Site consume one row each."
  assert wire.decode_result(wire.Diagnostics(None), bytes) == Ok(exact)
  assert wire.encode_result(
      wire.Diagnostics(None),
      wire.Diagnosed(q.Served(q.Settled(list.repeat(diagnostic, 5001)), q.Warm)),
    )
    == Error(wire.LimitExceeded)
}

fn nested(depth: Int, children: List(q.SymbolEntry)) -> List(q.SymbolEntry) {
  case depth {
    0 -> children
    _ ->
      nested(depth - 1, [q.SymbolEntry("x", "function", None, site(), children)])
  }
}

pub fn outline_flattening_roundtrips_depth_256_and_refuses_257_and_forward_parents_test() {
  let expected = wire.Outline("src/main.gleam")
  let answer = wire.Outlined(q.Served(nested(256, []), q.Warm))
  let assert Ok(bytes) = wire.encode_result(expected, answer)
    as "Flat rows preserve a bounded 256-deep semantic outline."
  assert wire.decode_result(expected, bytes) == Ok(answer)
  assert wire.encode_result(
      expected,
      wire.Outlined(q.Served(nested(257, []), q.Warm)),
    )
    |> result.is_error
  let forward =
    m.ArrayValue([
      m.IntValue(1),
      m.IntValue(3),
      m.ArrayValue([
        m.ArrayValue([m.IntValue(0)]),
        m.ArrayValue([
          m.ArrayValue([
            m.IntValue(0),
            m.StringValue("x"),
            m.StringValue("function"),
            m.NilValue,
            m.ArrayValue([
              m.StringValue("x"),
              m.IntValue(1),
              m.IntValue(1),
              m.StringValue(""),
            ]),
          ]),
        ]),
      ]),
    ])
  assert wire.decode_result(expected, raw(forward))
    == Error(wire.InvalidPayload)
}

fn huge_batch() -> o.Batch {
  let paths =
    list.index_map(list.repeat(Nil, 16), fn(_, index) {
      "/"
      <> string.repeat("x", 8188)
      <> string.pad_start(int.to_string(index), 3, "0")
    })
  let asked_paths =
    list.index_map(list.repeat(Nil, 16), fn(_, index) {
      "src/" <> int.to_string(index)
    })
  let assert Ok(first) = list.first(paths)
    as "The scope has sixteen canonical paths."
  let content =
    string.repeat("x", 4_194_304 - 16 * { 8192 + 128 } - 8192 - 128 - 9)
  o.Batch(
    requested: o.Request("", "", asked_paths, []),
    root: "/" <> string.repeat("r", 8191),
    generation: "sha256-" <> string.repeat("0", 64),
    started_ms: -100_000,
    finished_ms: -99_999,
    outlined: paths,
    documents: list.map(paths, fn(path) {
      o.Document(path, "sha256-" <> string.repeat("0", 64), None)
    }),
    symbols: [
      o.Symbol(0, None, "x", "function", None, q.Site(first, 1, 1, content)),
    ],
    targets: [],
    references: [],
    counts: o.Counts(16, 0, 17, 4_194_304),
  )
}

pub fn complete_observation_four_mib_facts_with_long_canonical_shell_is_admitted_test() {
  let batch = huge_batch()
  let request = wire.Observe(batch.requested)
  let answer = wire.Observed(batch)
  let assert Ok(bytes) = wire.encode_result(request, answer)
    as "Four-MiB complete facts retain echoed scope and canonical paths separately."
  assert bit_array.byte_size(bytes) > 4_194_304
  assert bit_array.byte_size(bytes) <= wire.max_result_bytes
  assert wire.decode_result(request, bytes) == Ok(answer)
  let #(_, _, _, _, invocation, _, _) = original(request)
  let assert Ok(envelope) =
    wire.encode_result_envelope(invocation, request, answer)
    as "The maximum observation shell fits the fixed result envelope."
  assert bit_array.byte_size(envelope) <= wire.max_result_envelope_bytes
  assert wire.decode_result_envelope(envelope, invocation, request)
    == Ok(answer)
  assert wire.encode_result(
      request,
      wire.Observed(o.Batch(..batch, counts: o.Counts(16, 0, 17, 4_194_303))),
    )
    == Error(wire.InvalidPayload)
  assert wire.encode_result(
      request,
      wire.Observed(o.Batch(..batch, counts: o.Counts(16, 0, 18, 4_194_304))),
    )
    == Error(wire.InvalidPayload)
}

fn repeated_outline_batch(outlines: List(String)) -> o.Batch {
  let path = "/checkout/src/main.gleam"
  let small = q.Site(path, 1, 1, "x")

  // Each requested outline collects its own symbol facts. The shared document
  // remains retained once, while the canonical outline inventory keeps both.

  o.Batch(
    requested: o.Request("gleam", "/checkout", outlines, []),
    root: "/checkout",
    generation: "sha256-" <> string.repeat("0", 64),
    started_ms: -100,
    finished_ms: -99,
    outlined: [path, path],
    documents: [o.Document(path, "sha256-" <> string.repeat("1", 64), Some(1))],
    symbols: [
      o.Symbol(0, None, "x", "function", None, small),
      o.Symbol(1, None, "x", "function", None, small),
    ],
    targets: [],
    references: [],
    counts: o.Counts(2, 0, 3, 1024),
  )
}

pub fn observation_outline_exact_duplicate_requests_roundtrip_test() {
  let batch = repeated_outline_batch(["src/main.gleam", "src/main.gleam"])
  let expected = wire.Observe(batch.requested)
  let assert Ok(request_bytes) = wire.encode_request(expected)
    as "Repeated original paths remain two ordered request entries."
  assert wire.decode_request(request_bytes) == Ok(expected)

  let answer = wire.Observed(batch)
  let assert Ok(result_bytes) = wire.encode_result(expected, answer)
    as "Repeated outlines retain their complete facts and canonical entries."
  assert wire.decode_result(expected, result_bytes) == Ok(answer)
}

pub fn observation_outline_relative_absolute_aliases_roundtrip_test() {
  let batch =
    repeated_outline_batch(["src/main.gleam", "/checkout/src/main.gleam"])
  let expected = wire.Observe(batch.requested)
  let assert Ok(request_bytes) = wire.encode_request(expected)
    as "Relative and absolute spellings remain the original ordered scope."
  assert wire.decode_request(request_bytes) == Ok(expected)

  let answer = wire.Observed(batch)
  let assert Ok(result_bytes) = wire.encode_result(expected, answer)
    as "Both aliases retain their entries after resolving to one document."
  assert wire.decode_result(expected, result_bytes) == Ok(answer)
}

pub fn observation_rejects_changed_scope_digests_parent_identity_and_target_index_test() {
  let request = o.Request("gleam", "/checkout", ["src/main.gleam"], [asked()])
  let path = "/checkout/src/main.gleam"
  let small = q.Site(path, 1, 1, "x")
  let batch =
    o.Batch(
      request,
      "/checkout",
      "sha256-" <> string.repeat("0", 64),
      -100,
      -99,
      [path],
      [o.Document(path, "sha256-" <> string.repeat("1", 64), Some(1))],
      [
        o.Symbol(0, None, "x", "function", None, small),
        o.Symbol(1, Some(0), "y", "variable", None, small),
      ],
      [o.Target(0, asked(), small)],
      [o.Reference(0, small)],
      o.Counts(4, 1, 5, 4096),
    )
  let expected = wire.Observe(request)
  let assert Ok(bytes) = wire.encode_result(expected, wire.Observed(batch))
    as "The complete parent/target/reference relationships are consistent."
  assert wire.decode_result(expected, bytes) == Ok(wire.Observed(batch))
  list.each(
    [
      o.Batch(..batch, generation: "sha256-" <> string.repeat("A", 64)),
      o.Batch(..batch, symbols: [
        o.Symbol(0, Some(1), "x", "function", None, small),
        o.Symbol(1, None, "y", "variable", None, small),
      ]),
      o.Batch(..batch, targets: [o.Target(1, asked(), small)]),
      o.Batch(..batch, references: [o.Reference(1, small)]),
      o.Batch(..batch, documents: [
        o.Document(path, "sha256-" <> string.repeat("1", 63), Some(1)),
      ]),
    ],
    fn(changed) {
      assert wire.encode_result(expected, wire.Observed(changed))
        |> result.is_error
    },
  )
  assert wire.encode_result(
      wire.Observe(o.Request("go", "/checkout", [], [])),
      wire.Observed(batch),
    )
    == Error(wire.ResponseMismatch)
}

pub fn exact_request_and_timed_search_header_ceilings_count_complete_encoding_test() {
  let query = q.SymbolQuery("x", None, None)
  let small_request = wire.PrepareRename(query, "x")
  let assert Ok(small_bytes) = wire.encode_request(small_request)
    as "The short semantic fixture has known complete framing."

  // A string longer than 65535 uses five header bytes instead of one.

  let length = wire.max_request_bytes - bit_array.byte_size(small_bytes) - 3
  let request = wire.PrepareRename(query, string.repeat("x", length))
  let assert Ok(bytes) = wire.encode_request(request)
    as "The unchanged request exactly fills its complete 131072-byte ceiling."
  assert bit_array.byte_size(bytes) == wire.max_request_bytes
  assert wire.decode_request(bytes) == Ok(request)
  assert wire.encode_request(wire.PrepareRename(
      query,
      string.repeat("x", length + 1),
    ))
    == Error(wire.PreflightRefused)

  let expected = wire.Definition(asked())
  let #(scope, digest, _, _, invocation, _, _) = original(expected)
  let assert Ok(inventory) =
    identity.enrolled_profiles(scope, digest, [
      identity.Profile("gleam", "/checkout"),
    ])
    as "The original enrollment is retained unchanged."
  let assert Ok(profile) = identity.checked_profile(inventory, 0)
    as "The profile comes from that actual enrollment."
  let assert Ok(small_selection) =
    identity.selected_project(profile, "gleam", "/x")
    as "The manager selected the actual canonical root."
  let assert Ok(small_command) =
    identity.lsp_search_command(
      invocation,
      profile,
      identity.warm_search_root(small_selection),
    )
    as "The short Search has complete timed coordinates."
  let assert Ok(small_header) = wire.encode_command(small_command)
    as "The whole command framing is measured rather than guessed."

  // A str16 root adds two framing bytes beyond the short root's fixstr.

  let root =
    "/" <> string.repeat("x", 8192 - bit_array.byte_size(small_header) - 1)
  let assert Ok(selection) = identity.selected_project(profile, "gleam", root)
    as "The long canonical root remains individually legal."
  let assert Ok(command) =
    identity.lsp_search_command(
      invocation,
      profile,
      identity.warm_search_root(selection),
    )
    as "The complete timed parent plus root exactly fits the header reservation."
  let assert Ok(header) = wire.encode_command(command)
    as "The whole command header includes timing and both original references."
  assert bit_array.byte_size(header) == 8192
  assert wire.decode_command(header, expected, inventory, Some(selection))
    == Ok(command)
  let assert Ok(oversize_selection) =
    identity.selected_project(profile, "gleam", root <> "x")
    as "The extra byte is legal for the root alone."
  assert identity.lsp_search_command(
      invocation,
      profile,
      identity.warm_search_root(oversize_selection),
    )
    == Error(identity.HeaderTooLarge)
  let assert m.ArrayValue([version, m.ArrayValue([tag, parent, ordinal, _])]) =
    identity.command_value(command)
    as "Search has exactly one closed parent shape."
  let oversize =
    raw(
      m.ArrayValue([
        version,
        m.ArrayValue([tag, parent, ordinal, m.StringValue(root <> "x")]),
      ]),
    )
  assert bit_array.byte_size(oversize) == 8193
  assert wire.decode_command(
      oversize,
      expected,
      inventory,
      Some(oversize_selection),
    )
    == Error(wire.PreflightRefused)
}

pub fn timing_hash_adapter_binds_complete_parent_and_refuses_digest_substitution_test() {
  let request = wire.Definition(asked())
  let #(_, input_digest, _, capture, invocation, _, _) = original(request)
  let parent = identity.capture_parent(capture)
  let assert Ok(parent_bytes) = wire.encode_parent(parent)
    as "The original reference has one canonical bounded representation."
  assert wire.decode_parent(parent_bytes) == Ok(parent)
  let proposal = identity.invocation_proposal(invocation)
  let assert Ok(timing) = wire.encode_timing(proposal)
    as "The exact original proposal fits its independent 128-byte bound."
  assert wire.decode_timing(timing, parent) == Ok(proposal)
  let assert Ok(actual_digest) = wire.parent_digest(parent)
    as "The complete parent is hashed by the effect-layer canonical adapter."
  assert actual_digest != input_digest
  let assert m.ArrayValue(fields) = identity.invocation_value(invocation)
    as "The complete invocation header has fixed positional fields."
  let changed =
    m.ArrayValue(
      list.index_map(fields, fn(field, index) {
        case index {
          10 -> {
            let assert m.ArrayValue([version, era, nonce, remaining, _]) = field
              as "The timing proposal retains all original dimensions."
            m.ArrayValue([
              version,
              era,
              nonce,
              remaining,
              m.BinaryValue(g.digest_bytes(input_digest)),
            ])
          }
          _ -> field
        }
      }),
    )
  assert wire.decode_invocation(raw(changed), request)
    == Error(wire.DigestMismatch)
  let assert m.ArrayValue([_, _, _, _, _, _, _, _, _, _, changed_timing, _]) =
    changed
    as "Only the control digest changed under the same original address."
  assert wire.decode_timing(raw(changed_timing), parent)
    == Error(wire.DigestMismatch)
  assert wire.decode_parent(<<0:size(8200)>>) == Error(wire.PreflightRefused)
  assert wire.decode_timing(<<0:size(1032)>>, parent)
    == Error(wire.PreflightRefused)
}

pub fn after_write_body_matches_the_complete_retained_physical_write_reference_test() {
  let #(scope, enrollment, write, _, _, _, _) =
    original(wire.Definition(asked()))
  let assert m.ArrayValue([origin_value, _, _, _, _, _]) =
    identity.original_child_value(write)
    as "The original complete write retains its checked origin."
  let assert Ok(origin) = remote_tool.decode_child_value(origin_value)
    as "The shared canonical ChildOrigin decoder keeps full provenance."
  let assert Ok(tool) = remote_tool.child_tool(origin)
    as "The original physical write belongs to its actual admitted tool."
  let session = remote_tool.session(tool)
  let operation = remote_tool.operation(tool)
  let #(request_id, _) = ids.mint_entry(ids.generator(clock.fixed(1000), 42))
  let assert Ok(step) = workspace.step("fs.afterwrite")
    as "The actual post-write observation retains its separate physical step."
  let assert Ok(system) = remote_tool.system_child(session, "lsp", 7)
    as "The actual post-write child uses the existing lsp system family."
  let request = wire.AfterWrite("src/main.gleam", write)
  let assert Ok(input) = wire.semantic_input(request)
    as "The original write reference participates in canonical request bytes."
  let #(_, digest, _) = identity.input_fields(input)
  let assert Ok(child) =
    identity.original_child_ref(
      system,
      scope,
      operation,
      step,
      request_id,
      digest,
    )
    as "The post-write child retains its own original request coordinates."
  let assert Ok(parent) = identity.post_write_control(write, child)
    as "The original physical write and admitted observation share scope and operation."
  let assert Ok(capture) =
    identity.lsp_capture(
      system,
      scope,
      operation,
      step,
      request_id,
      input,
      parent,
      enrollment,
      enrollment,
    )
    as "Only the actual AfterWrite body admits a system finite origin."
  let assert Ok(bytes) = wire.encode_capture_envelope(capture, request)
    as "The complete AfterWrite body and retained physical write agree."
  assert wire.decode_capture_envelope(bytes) == Ok(#(capture, request))
  let assert m.ArrayValue([origin, write_scope, op, write_step, id, _]) =
    identity.original_child_value(write)
    as "The original write digest remains complete equality evidence."
  let assert Ok(other_write) =
    identity.decode_child_ref_value(
      m.ArrayValue([
        origin,
        write_scope,
        op,
        write_step,
        id,
        m.BinaryValue(<<1:size(256)>>),
      ]),
    )
    as "Another digest is independently valid immutable identity data."
  let assert Ok(other_parent) = identity.post_write_control(other_write, child)
    as "Complete scope/operation equality cannot erase changed physical write evidence."
  let assert Ok(other_capture) =
    identity.lsp_capture(
      system,
      scope,
      operation,
      step,
      request_id,
      input,
      other_parent,
      enrollment,
      enrollment,
    )
    as "Core receives semantic bytes without interpreting effect-layer Request fields."
  assert wire.encode_capture(other_capture, request)
    == Error(wire.ResponseMismatch)
  assert wire.decode_capture(
      raw(identity.capture_value(other_capture)),
      request,
    )
    == Error(wire.ResponseMismatch)
}
