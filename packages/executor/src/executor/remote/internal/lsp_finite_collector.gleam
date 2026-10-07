//// Bounded finite raw collection and durable witness comparison, without effects.
////
//// The original Service will serialize this reducer and own actual helper events.
//// `new` checks the complete finite ref/request/selection and original control;
//// `output` admits bytes before issuing one opaque `Credit`, and `consumed`
//// releases only that current credit. `terminal` and `reusable` remain separate.
//// `project` validates complete output; `projection_committed` compares actual
//// DAL readback before dropping raw references. `reuse_committed` compares the
//// exact retained witness, but only the later original Service may consume it.
//// No value here mints a claim, proves a physical waitDone, or calls a helper.
////
//// `cold_inventory`, `charge_hits` and `charge_group` bound one cold invocation's
//// independent inventories. Their 87748608-byte content sum is not a global
//// runtime/RSS limit. Later semantic custody must serialize profiles, limit
//// admitted collectors with existing endpoint/service admission, and participate
//// in close_scope fencing/drain and ScopeCloseProof before reuse or shutdown.

import broker/dispatch
import broker/framing
import core/internal/msgpack_scan
import core/lsp_command as id
import core/msgpack as mp
import executor/remote/internal/lsp_finite_plan as plan
import executor/remote/internal/lsp_native_plan as native_plan
import executor/remote/lsp_journal
import executor/remote/lsp_wire
import executor/remote/wire
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tools/grep

/// A collection failure cannot advertise an earlier successful prefix.
@internal
pub type Error {
  /// The original ref/request/control, event or producer total does not match.
  InvalidCollection

  /// Original elapsed control expired or the collector is irreversibly fenced.
  FencedCollection

  /// Raw/projection/cold hit/grouping storage exceeds the fixed reservation.
  CollectionLimit

  /// Complete bytes do not form the approved checked Search projection.
  MalformedSearch

  /// A successful native terminal or required durable witness is still missing.
  IncompleteCollection
}

/// Sole admitted ordinal, issued only after bounded collector admission.
@internal
pub opaque type Credit {
  Credit(ref: id.LspCommandRef, ordinal: Int)
}

type Gate {
  Open
  Held(Credit)
  Fenced
}

type Raw {
  Raw(
    stdout: List(BitArray),
    stderr: List(BitArray),
    out_bytes: Int,
    err_bytes: Int,
  )
  RawReleased
}

type Reuse {
  AwaitingReuse
  OfferedReuse(witness: BitArray)
  CommittedReuse(witness: BitArray)
}

/// Checked complete command projection; it is neither dependency readiness nor result receipt.
@internal
pub opaque type Projection {
  Projection(
    /// The complete original canonical command reference.
    ref: id.LspCommandRef,
    /// Original bounded terminal evidence, separate from reuse.
    terminal: BitArray,
    /// The canonical bounded complete command projection.
    bytes: BitArray,
    /// Search path/line content without retained source text.
    hits: Option(grep.RegisteredHits),
  )
}

/// Original finite state, to be retained only by the actual serialized Service owner.
@internal
pub opaque type Collector {
  Collector(
    /// The complete original canonical command reference.
    ref: id.LspCommandRef,
    /// The closed finite recipe, never ServerLease.
    kind: plan.Recipe,
    /// The one original admitted era, E0, R and D.
    control: id.AdmittedFiniteControl,
    /// The single shared output admission window.
    gate: Gate,
    /// Charged raw buffers until projection readback or fencing.
    raw: Raw,
    /// The next original ordinal; consumed credits never renew.
    next: Int,
    /// Original bounded terminal evidence, separate from reuse.
    terminal: Option(#(dispatch.Terminal, framing.ProtocolDisposition)),
    /// The original checked projection retained exactly once.
    projection: Option(Projection),
    /// Distinct retained reusable evidence, never native retirement.
    reuse: Reuse,
  )
}

/// Counters for exactly one original sequential cold invocation, with no hit copies.
@internal
pub opaque type ColdInventory {
  ColdInventory(
    /// The complete original checked cold profile inventory.
    profiles: id.EnrolledProfiles,
    /// The next original ordinal; consumed credits never renew.
    next: Int,
    /// Search path/line content without retained source text.
    hits: Int,
    /// Independently charged retained hit content.
    hit_bytes: Int,
    /// The number of charged grouping projections.
    groups: Int,
    /// Independently charged retained grouping content.
    group_bytes: Int,
  )
}

/// Checks complete original identity and timing without starting native work.
///
/// ## Examples
/// ServerLease, changed request or expired/changed era refuses before collection.
@internal
pub fn new(
  ref: id.LspCommandRef,
  request: lsp_wire.Request,
  profiles: id.EnrolledProfiles,
  selected: Option(id.SelectedProject),
  control: id.AdmittedFiniteControl,
  era: id.ClockEra,
  now: Int,
) -> Result(Collector, Error) {
  use bytes <- result.try(lsp_wire.encode_command(ref) |> invalid)
  use checked <- result.try(
    lsp_wire.decode_command(bytes, request, profiles, selected) |> invalid,
  )
  use <- bool.guard(checked != ref, Error(InvalidCollection))
  use kind <- result.try(plan.recipe(ref) |> invalid)
  use Nil <- result.try(timed(control, era, now))
  use Nil <- result.try(case id.command_parent(ref) {
    id.Startup(_) -> Ok(Nil)
    id.Search(invocation, _, _) -> {
      use digest <- result.try(
        lsp_wire.timing_digest(id.invocation_proposal(invocation)) |> invalid,
      )
      let #(original_era, _, remaining, _, expected_digest) =
        id.control_fields(control)
      case id.timing_value(id.invocation_proposal(invocation)) {
        mp.ArrayValue([_, mp.StringValue(proposed_era), _, mp.IntValue(r), _]) ->
          bool.guard(
            !{
              digest == expected_digest
              && r == remaining
              && proposed_era == id.era_string(original_era)
            },
            Error(InvalidCollection),
            fn() { Ok(Nil) },
          )
        _ -> Error(InvalidCollection)
      }
    }
  })
  Ok(Collector(
    ref,
    kind,
    control,
    Open,
    Raw([], [], 0, 0),
    1,
    None,
    None,
    AwaitingReuse,
  ))
}

/// Admits one complete bounded output chunk under the one shared stream credit.
/// Producer loss or overflow returns refusal; the owner must retain `fence(state)`.
///
/// ## Examples
/// No second stdout or stderr offer is accepted while the original credit is held.
@internal
pub fn output(
  state: Collector,
  ordinal: Int,
  stream: framing.OutputStream,
  bytes: BitArray,
  total: Int,
  disposition: framing.OutputDisposition,
  era: id.ClockEra,
  now: Int,
) -> Result(#(Collector, Credit), Error) {
  use Nil <- result.try(timed(state.control, era, now))
  use <- bool.guard(
    state.gate != Open
      || state.terminal != None
      || ordinal != state.next
      || disposition != framing.OutputComplete,
    Error(FencedCollection),
  )
  let size = bit_array.byte_size(bytes)
  use <- bool.guard(size > 32_768, Error(CollectionLimit))
  case state.raw {
    RawReleased -> Error(FencedCollection)
    Raw(out, err, out_bytes, err_bytes) -> {
      let original_total = case stream {
        framing.Stdout -> out_bytes
        framing.Stderr -> err_bytes
      }
      let cap = plan.stream_bytes(state.kind)
      use <- bool.guard(
        total != original_total + size,
        Error(InvalidCollection),
      )
      use <- bool.guard(
        total > cap || out_bytes + err_bytes + size > cap * 2,
        Error(CollectionLimit),
      )
      let raw = case size, stream {
        0, _ -> state.raw
        _, framing.Stdout -> Raw([bytes, ..out], err, total, err_bytes)
        _, framing.Stderr -> Raw(out, [bytes, ..err], out_bytes, total)
      }
      let credit = Credit(state.ref, ordinal)
      Ok(#(Collector(..state, gate: Held(credit), raw: raw), credit))
    }
  }
}

/// Releases only the exact credit already admitted into this collector window.
/// This reducer result is not an actual broker ACK or task-drain witness.
///
/// ## Examples
/// A repeated credit cannot acknowledge a later offer or return credit twice.
@internal
pub fn consumed(state: Collector, credit: Credit) -> Result(Collector, Error) {
  case state.gate {
    Held(original) if original == credit ->
      Ok(Collector(..state, gate: Open, next: state.next + 1))
    _ -> Error(FencedCollection)
  }
}

/// Retains the actual terminal separately from reusable and projection.
///
/// ## Examples
/// A zero exit with ProtocolFailed remains incomplete for successful projection.
@internal
pub fn terminal(
  state: Collector,
  value: dispatch.Terminal,
  disposition: framing.ProtocolDisposition,
) -> Result(Collector, Error) {
  use <- bool.guard(state.gate != Open, Error(FencedCollection))
  case state.terminal {
    None -> Ok(Collector(..state, terminal: Some(#(value, disposition))))
    Some(original) if original == #(value, disposition) -> Ok(state)
    Some(_) -> Error(InvalidCollection)
  }
}

/// Projects only complete successful output, using the existing strict rg extractor.
/// Prepare's empty command projection means recipe completion, never metadata readiness.
///
/// ## Examples
/// Raw references stay charged until exact projection COMMIT/readback is supplied.
@internal
pub fn project(state: Collector) -> Result(#(Collector, Projection), Error) {
  use <- bool.guard(state.gate != Open, Error(FencedCollection))
  case state.projection, state.terminal, state.raw {
    Some(original), _, _ -> Ok(#(state, original))
    None,
      Some(#(dispatch.Completed(result), framing.ProtocolComplete)),
      Raw(out, _, out_bytes, err_bytes)
      if result.stdout_bytes == out_bytes
      && result.stderr_bytes == err_bytes
      && !result.cancelled
      && !result.timed_out
      && !result.stdout_truncated
      && !result.stderr_truncated
    -> {
      use terminal <- result.try(
        native_plan.encode_terminal(
          dispatch.Completed(result),
          framing.ProtocolComplete,
        )
        |> invalid,
      )
      use hits <- result.try(case state.kind, result.code {
        plan.Search, 0 | plan.Search, 1 -> {
          use hits <- result.try(
            grep.registered_matches(bit_array.concat(list.reverse(out)))
            |> result.map_error(search_error),
          )
          Ok(Some(hits))
        }
        plan.Probe, 0 | plan.Prepare, 0 -> Ok(None)
        _, _ -> Error(IncompleteCollection)
      })
      use bytes <- result.try(projection_bytes(state.kind, hits))
      let projected = Projection(state.ref, terminal, bytes, hits)
      Ok(#(Collector(..state, projection: Some(projected)), projected))
    }
    _, _, _ -> Error(IncompleteCollection)
  }
}

/// Compares immutable actual command readback before dropping all raw references.
/// Later assembly must still independently recheck its original Store/association.
///
/// ## Examples
/// Changed ref, terminal or projection cannot release raw buffers.
@internal
pub fn projection_committed(
  state: Collector,
  projection: Projection,
  retained: lsp_journal.CommandReadback,
) -> Result(Collector, Error) {
  let #(ref, _, _, _, terminal, _, bytes) =
    lsp_journal.command_evidence(retained)
  use <- bool.guard(
    state.gate != Open
      || state.ref != projection.ref
      || ref != state.ref
      || terminal != projection.terminal
      || bytes != projection.bytes,
    Error(InvalidCollection),
  )
  use <- bool.guard(
    state.projection != Some(projection),
    Error(InvalidCollection),
  )
  Ok(Collector(..state, raw: RawReleased))
}

/// Retains a matching post-join event without granting helper reuse yet.
/// The original Service supplies this witness only from its real original execution.
///
/// ## Examples
/// A reusable event before the actual terminal is refused.
@internal
pub fn reusable(
  state: Collector,
  witness: BitArray,
) -> Result(Collector, Error) {
  use <- bool.guard(
    state.gate != Open || state.terminal == None,
    Error(FencedCollection),
  )
  use <- bool.guard(bit_array.byte_size(witness) > 8192, Error(CollectionLimit))
  use value <- result.try(wire.decode_value(witness) |> invalid)
  use canonical <- result.try(wire.encode_value(value) |> invalid)
  use ref <- result.try(lsp_wire.encode_command(state.ref) |> invalid)
  use Nil <- result.try(case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.BinaryValue(ref_digest),
      mp.BinaryValue(association_digest),
      mp.BinaryValue(terminal_digest),
      mp.IntValue(execution),
    ]) ->
      bool.guard(
        execution <= 0
          || bit_array.byte_size(association_digest) != 32
          || bit_array.byte_size(terminal_digest) != 32
          || ref_digest != crypto.hash(crypto.Sha256, ref),
        Error(InvalidCollection),
        fn() { Ok(Nil) },
      )
    _ -> Error(InvalidCollection)
  })
  use <- bool.guard(canonical != witness, Error(InvalidCollection))
  case state.reuse {
    AwaitingReuse -> Ok(Collector(..state, reuse: OfferedReuse(witness)))
    OfferedReuse(original) | CommittedReuse(original) if original == witness ->
      Ok(state)
    _ -> Error(InvalidCollection)
  }
}

/// Compares the exact durable reusable bytes without consuming a native handle.
/// Actual reusable consumption and original helper check-in remain Service effects.
///
/// ## Examples
/// Terminal/projection alone leaves `ready` false.
@internal
pub fn reuse_committed(
  state: Collector,
  retained: lsp_journal.CommandReadback,
) -> Result(Collector, Error) {
  let #(ref, _, association, _, terminal, witness, _) =
    lsp_journal.command_evidence(retained)
  use <- bool.guard(
    state.gate != Open
      || state.raw != RawReleased
      || state.projection == None
      || ref != state.ref
      || lsp_journal.command_disposition(retained) != lsp_journal.Reusable,
    Error(IncompleteCollection),
  )
  use value <- result.try(wire.decode_value(witness) |> invalid)
  use Nil <- result.try(case value {
    mp.ArrayValue([
      _,
      _,
      mp.BinaryValue(association_digest),
      mp.BinaryValue(terminal_digest),
      _,
    ]) ->
      bool.guard(
        association_digest != crypto.hash(crypto.Sha256, association)
          || terminal_digest != crypto.hash(crypto.Sha256, terminal),
        Error(InvalidCollection),
        fn() { Ok(Nil) },
      )
    _ -> Error(InvalidCollection)
  })
  case state.reuse {
    OfferedReuse(original) if original == witness ->
      Ok(Collector(..state, reuse: CommittedReuse(original)))
    CommittedReuse(original) if original == witness -> Ok(state)
    _ -> Error(InvalidCollection)
  }
}

/// Reports only the reducer's retained projection/reusable pairing, not physical drain.
///
/// ## Examples
/// Actual Service must join waitDone-backed consumption and managed AllDelivered.
@internal
pub fn ready(state: Collector) -> Bool {
  case state.gate, state.raw, state.reuse {
    Open, RawReleased, CommittedReuse(_) -> True
    _, _, _ -> False
  }
}

/// Fences local control and drops raw content while keeping original obligations.
///
/// ## Examples
/// Missing original reusable still holds its native borrow after cancellation.
@internal
pub fn fence(state: Collector) -> Collector {
  Collector(..state, gate: Fenced, raw: RawReleased)
}

/// Reads the exact bounded terminal/projection pair for the original DAL mutation.
///
/// ## Examples
/// These bytes cannot issue a final finite ResultReceipt by themselves.
@internal
pub fn projection_fields(
  value: Projection,
) -> #(BitArray, BitArray, Option(grep.RegisteredHits)) {
  #(value.terminal, value.bytes, value.hits)
}

/// Reports retained raw logical bytes without copying the corpus.
///
/// ## Examples
/// Raw charge becomes zero only after checked projection readback or fencing.
@internal
pub fn raw_bytes(state: Collector) -> Int {
  case state.raw {
    Raw(_, _, out, err) -> out + err
    RawReleased -> 0
  }
}

/// Starts counters for one sequential cold invocation, without saving hit copies.
///
/// ## Examples
/// The later manager retains its actual hit/grouping objects under these charges.
@internal
pub fn cold_inventory(profiles: id.EnrolledProfiles) -> ColdInventory {
  ColdInventory(profiles, 0, 0, 0, 0, 0)
}

/// Charges one next enrolled ordinal's complete projection before retaining it.
///
/// ## Examples
/// A repeated ordinal cannot make a second cold Search free or skip a profile.
@internal
pub fn charge_hits(
  state: ColdInventory,
  ordinal: Int,
  value: grep.RegisteredHits,
) -> Result(ColdInventory, Error) {
  use _ <- result.try(id.checked_profile(state.profiles, ordinal) |> invalid)
  use <- bool.guard(ordinal != state.next, Error(InvalidCollection))
  let count = list.length(grep.registered_hits(value))
  let bytes = grep.registered_charge(value)
  use <- bool.guard(
    state.hits + count > 3200 || state.hit_bytes + bytes > 26_316_800,
    Error(CollectionLimit),
  )
  Ok(
    ColdInventory(
      ..state,
      next: ordinal + 1,
      hits: state.hits + count,
      hit_bytes: state.hit_bytes + bytes,
    ),
  )
}

/// Charges a distinct grouping projection before constructing its retained row.
///
/// ## Examples
/// Grouping bytes never borrow the independent hit projection reservation.
@internal
pub fn charge_group(
  state: ColdInventory,
  path: String,
  root: String,
  label: String,
) -> Result(ColdInventory, Error) {
  let path_bytes = string.byte_size(path)
  let root_bytes = string.byte_size(root)
  let label_bytes = string.byte_size(label)
  let bytes = path_bytes + root_bytes + label_bytes + 64
  use <- bool.guard(
    path_bytes > 8192
      || root_bytes > 8192
      || label_bytes > 128
      || state.groups >= state.hits
      || state.groups >= 3200
      || state.group_bytes + bytes > 53_043_200,
    Error(CollectionLimit),
  )
  Ok(
    ColdInventory(
      ..state,
      groups: state.groups + 1,
      group_bytes: state.group_bytes + bytes,
    ),
  )
}

/// Reports independently charged retained logical content for one cold invocation.
///
/// ## Examples
/// Add at most8388608 raw bytes; the combined maximum is87748608.
@internal
pub fn inventory_bytes(state: ColdInventory) -> #(Int, Int) {
  #(state.hit_bytes, state.group_bytes)
}

fn timed(
  control: id.AdmittedFiniteControl,
  era: id.ClockEra,
  now: Int,
) -> Result(Nil, Error) {
  let #(original, e0, _, deadline, _) = id.control_fields(control)
  bool.guard(
    era != original || deadline == 0 || now < e0 || now >= deadline,
    Error(FencedCollection),
    fn() { Ok(Nil) },
  )
}

fn projection_bytes(
  kind: plan.Recipe,
  hits: Option(grep.RegisteredHits),
) -> Result(BitArray, Error) {
  let rows = case hits {
    None -> []
    Some(value) ->
      list.map(grep.registered_hits(value), fn(hit) {
        mp.ArrayValue([mp.StringValue(hit.path), mp.IntValue(hit.line)])
      })
  }
  let tag = case kind {
    plan.Probe -> 0
    plan.Search -> 1
    plan.Prepare -> 2
  }

  // Checked Search rows use the Registered result profile because native wire
  // limits reject admitted Search hits before their own capacity check.
  use bytes <- result.try(
    mp.encode(
      mp.ArrayValue([mp.IntValue(1), mp.IntValue(tag), mp.ArrayValue(rows)]),
    )
    |> invalid,
  )
  let cap = case kind {
    plan.Search -> 1_644_800
    plan.Probe | plan.Prepare -> 131_072
  }
  use <- bool.guard(bit_array.byte_size(bytes) > cap, Error(CollectionLimit))
  use Nil <- result.try(msgpack_scan.lsp_result(bytes) |> invalid)
  Ok(bytes)
}

fn search_error(error: grep.RegisteredError) -> Error {
  case error {
    grep.MalformedRegisteredSearch -> MalformedSearch
    grep.RegisteredSearchLimit -> CollectionLimit
  }
}

fn invalid(answer: Result(a, b)) -> Result(a, Error) {
  result.replace_error(answer, InvalidCollection)
}
