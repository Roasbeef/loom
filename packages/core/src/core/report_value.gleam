//// Exact program outcomes and owner observations retained as one bounded bundle.
////
//// Program values keep their MessagePack distinctions, including binary payloads,
//// non-text keys and ordered maps. Owner metadata has a separate closed schema;
//// the program cannot impersonate a call log or enforcement observation. Raw
//// scanning precedes decoding, and bounded term walking precedes encoding.
//// References are data names only: their validity grants no read authority and
//// proves neither durable custody nor the existence of any bytes.
////
//// ## Flow
////
//// `metadata` validates owner observations and encodes their closed schema.
//// `check_manifest` preserves compiler fingerprints separately from URI digests.
//// `complete` validates a raw terminal; `from_outcome` validates a term first.
//// `decode` checks the bundle header before `decode_terminal` and metadata.
//// `encode_terminal` and `walk` share the terminal's fixed allocation budgets.
//// `reference` and `parse_ref` establish identity syntax without read authority.
//// `bytes`, `outcome` and `report_metadata` expose checked bundle contents.

import core/corruption.{type CorruptionReport}
import core/ids.{type EntryId, type SessionId}
import core/internal/msgpack_scan
import core/msgpack as mp
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The complete terminal body's byte ceiling, including its Outcome map.
pub const max_terminal_bytes = 16_777_216

/// The independent owner metadata byte ceiling.
pub const max_metadata_bytes = 262_144

/// Both segments and the sixteen-byte bundle header.
pub const max_bundle_bytes = 17_039_376

/// The full program outcome, without any credential or transport envelope.
pub type Outcome {
  /// The program finished with this exact value.
  Completed(
    /// Arbitrary admitted program data, preserving MessagePack distinctions.
    value: mp.MsgPackValue,
  )

  /// The program reported a controlled error.
  Errored(
    /// The full UTF-8 error message.
    message: String,
    /// Arbitrary admitted program error data.
    details: mp.MsgPackValue,
  )
}

/// A call's actual settlement status observed by the host.
pub type CallStatus {
  /// The call succeeded.
  CallOk

  /// The call failed or was refused.
  CallFailed

  /// The satellite cancelled the call.
  CallCancelled

  /// The call remained in flight at settlement.
  CallUnsettled
}

/// One bounded, redacted host observation in admission order.
pub type CallRecord {
  /// Validated at the Metadata boundary before it can enter a report.
  CallRecord(
    /// The capability name, at most 64 UTF-8 bytes.
    cap: String,
    /// The optional redacted argument summary, at most 96 bytes.
    args: Option(String),
    /// The observed settlement status.
    status: CallStatus,
    /// The optional error code, at most 48 bytes.
    error: Option(String),
    /// Nonnegative u64 milliseconds from execution start.
    start_ms: Int,
    /// Nonnegative u64 call duration in milliseconds.
    duration_ms: Int,
  )
}

/// Exact execution counters with at most 128 itemised calls.
pub type CallLog {
  /// Every numeric field is a nonnegative u64, checked at construction.
  CallLog(
    /// The host's Unix-millisecond execution start.
    started_unix_ms: Int,
    /// The elapsed execution time.
    elapsed_ms: Int,
    /// The count of all admitted calls, itemised or not.
    total: Int,
    /// Failed or refused calls.
    failed: Int,
    /// Cancelled calls.
    cancelled: Int,
    /// Calls still in flight at execution end.
    unsettled: Int,
    /// The first calls in admission order, never more than total.
    items: List(CallRecord),
  )
}

/// Preserves the helper's reported degraded flag without inferring enforcement.
pub type EnforcementQuality {
  /// The helper reported a complete run.
  Complete

  /// The helper reported a degraded run.
  Degraded
}

/// A stage's ground truth, distinct from the absence of a report.
pub type StageReport {
  /// The actual applied and skipped layers, bounded together to 128 entries.
  Reported(
    /// Applied layer names in their original order.
    applied: List(String),
    /// Skipped layer names in their original order.
    skipped: List(String),
    /// The actual helper flag, without inferring it from layer names.
    quality: EnforcementQuality,
  )

  /// No report exists; this is not a confinement claim.
  Unreported(
    /// The full bounded explanation of why it is absent.
    reason: String,
  )
}

/// Both jailed stages must be named, including an unreported stage.
pub type Enforcement {
  /// Independent observations of build and satellite execution.
  Enforcement(
    /// The build stage's report.
    build: StageReport,
    /// The satellite stage's report.
    node: StageReport,
  )
}

/// Checked owner metadata, never arbitrary program data.
pub opaque type Metadata {
  /// Contains only validated, complete owner observations.
  Metadata(
    /// The original artifact fingerprint: `sha256-` followed by lowercase hex.
    manifest_hash: String,
    /// Both validated stage observations.
    sandbox: Enforcement,
    /// The validated complete bounded call log.
    calls: CallLog,
    /// The exact canonical metadata segment, preserving decoded field order.
    encoded: BitArray,
  )
}

/// A checked canonical complete bundle and its decoded values.
pub opaque type CompleteReport {
  /// Retains the exact bytes alongside their checked decoded interpretation.
  CompleteReport(
    /// The complete canonical LOOMRV01 bundle.
    bytes: BitArray,
    /// The complete program outcome without transport authority.
    outcome: Outcome,
    /// The separately checked owner observations.
    metadata: Metadata,
  )
}

/// A validated identity and digest name, without authority or existence proof.
pub opaque type ReportRef {
  /// Names one original result entry and the expected complete bundle.
  ReportRef(
    /// The identity of the retaining owner's session.
    session: SessionId,
    /// The original reserved result entry.
    result_entry: EntryId,
    /// The validated lowercase expected SHA-256 digest.
    digest: String,
    /// The expected bounded complete bundle byte length.
    byte_length: Int,
  )
}

// The private profile gives the term walker the same fixed admission budget.
type TermProfile {
  TermProfile(
    bytes: Int,
    depth: Int,
    nodes: Int,
    array_entries: Int,
    map_entries: Int,
    scalar_bytes: Int,
  )
}

/// Checks actual owner observations before encoding their independent schema.
/// The manifest preserves the compiler fingerprint: `sha256-` plus 64 lowercase
/// hexadecimal digits. Result-reference digests separately remain bare hex.
///
/// ## Examples
///
/// ```gleam
/// // report_value.metadata(manifest_hash, sandbox, calls)
/// ```
pub fn metadata(
  manifest_hash: String,
  sandbox: Enforcement,
  calls: CallLog,
) -> Result(Metadata, CorruptionReport) {
  use Nil <- result.try(check_manifest(manifest_hash))
  use Nil <- result.try(check_log(calls))
  use Nil <- result.try(check_stage(sandbox.build))
  use Nil <- result.try(check_stage(sandbox.node))
  let value =
    object([
      #("kind", mp.StringValue("loom_report_metadata_v1")),
      #("manifest_hash", mp.StringValue(manifest_hash)),
      #(
        "sandbox",
        object([
          #("build", stage_value(sandbox.build)),
          #("node", stage_value(sandbox.node)),
        ]),
      ),
      #("calls", log_value(calls)),
    ])
  use encoded <- result.try(encode_checked(value, metadata_profile()))
  Ok(Metadata(manifest_hash:, sandbox:, calls:, encoded:))
}

/// Validates one raw canonical terminal body and adds checked owner metadata.
///
/// ## Examples
///
/// ```gleam
/// // report_value.complete(terminal_bytes, metadata)
/// ```
pub fn complete(
  terminal: BitArray,
  metadata: Metadata,
) -> Result(CompleteReport, CorruptionReport) {
  use outcome <- result.try(decode_terminal(terminal))
  Ok(bundle(terminal, outcome, metadata))
}

/// Checks a term before encoding, so an oversized term never builds huge bytes.
///
/// ## Examples
///
/// ```gleam
/// // report_value.from_outcome(report_value.Completed(value), metadata)
/// ```
pub fn from_outcome(
  outcome: Outcome,
  metadata: Metadata,
) -> Result(CompleteReport, CorruptionReport) {
  use terminal <- result.try(encode_terminal(outcome))
  Ok(bundle(terminal, outcome, metadata))
}

/// Decodes exactly the versioned two-segment bundle with no trailing bytes.
/// Length ceilings are checked before extracting or decoding either segment.
///
/// ## Examples
///
/// ```gleam
/// assert report_value.decode(<<>>) |> result.is_error
/// ```
pub fn decode(bytes: BitArray) -> Result(CompleteReport, CorruptionReport) {
  case bytes {
    <<
      "LOOMRV01":utf8,
      terminal_length:size(32),
      metadata_length:size(32),
      rest:bits,
    >>
      if terminal_length > 0
      && terminal_length <= max_terminal_bytes
      && metadata_length > 0
      && metadata_length <= max_metadata_bytes
    -> decode_segments(rest, terminal_length, metadata_length)
    _ -> Error(fail("the bounded LOOMRV01 bundle header"))
  }
}

/// Encodes the closed Outcome vocabulary under the fixed terminal profile.
///
/// ## Examples
///
/// ```gleam
/// // report_value.encode_terminal(report_value.Completed(msgpack.NilValue))
/// ```
pub fn encode_terminal(outcome: Outcome) -> Result(BitArray, CorruptionReport) {
  encode_checked(outcome_value(outcome), terminal_profile())
}

/// Scans before decoding and refuses alternative encodings of the same value.
/// Outcome alone occupies one container level, leaving 254 for program data.
///
/// ## Examples
///
/// ```gleam
/// assert report_value.decode_terminal(<<0xc0>>) |> result.is_error
/// ```
pub fn decode_terminal(bytes: BitArray) -> Result(Outcome, CorruptionReport) {
  use Nil <- result.try(msgpack_scan.terminal(bytes))
  use value <- result.try(decode_canonical(bytes))
  decode_outcome(value)
}

/// Returns the exact canonical bundle for hashing and custody.
///
/// ## Examples
///
/// ```gleam
/// // report_value.bytes(report)
/// ```
pub fn bytes(report: CompleteReport) -> BitArray {
  report.bytes
}

/// Returns the complete decoded program outcome.
///
/// ## Examples
///
/// ```gleam
/// // report_value.outcome(report)
/// ```
pub fn outcome(report: CompleteReport) -> Outcome {
  report.outcome
}

/// Returns the checked owner metadata.
///
/// ## Examples
///
/// ```gleam
/// // report_value.report_metadata(report)
/// ```
pub fn report_metadata(report: CompleteReport) -> Metadata {
  report.metadata
}

/// Returns the canonical artifact digest.
///
/// ## Examples
///
/// ```gleam
/// // report_value.manifest_hash(metadata)
/// ```
pub fn manifest_hash(metadata: Metadata) -> String {
  metadata.manifest_hash
}

/// Returns both actual enforcement observations.
///
/// ## Examples
///
/// ```gleam
/// // report_value.enforcement(metadata)
/// ```
pub fn enforcement(metadata: Metadata) -> Enforcement {
  metadata.sandbox
}

/// Returns the full bounded host call log.
///
/// ## Examples
///
/// ```gleam
/// // report_value.calls(metadata)
/// ```
pub fn calls(metadata: Metadata) -> CallLog {
  metadata.calls
}

/// Returns the session whose owner retains the report.
///
/// ## Examples
///
/// ```gleam
/// // report_value.ref_session(reference)
/// ```
pub fn ref_session(reference: ReportRef) -> SessionId {
  reference.session
}

/// Returns the original reserved result entry.
///
/// ## Examples
///
/// ```gleam
/// // report_value.ref_result_entry(reference)
/// ```
pub fn ref_result_entry(reference: ReportRef) -> EntryId {
  reference.result_entry
}

/// Returns the expected canonical SHA-256 digest.
///
/// ## Examples
///
/// ```gleam
/// // report_value.ref_digest(reference)
/// ```
pub fn ref_digest(reference: ReportRef) -> String {
  reference.digest
}

/// Returns the expected complete bundle byte length.
///
/// ## Examples
///
/// ```gleam
/// // report_value.ref_byte_length(reference)
/// ```
pub fn ref_byte_length(reference: ReportRef) -> Int {
  reference.byte_length
}

/// Constructs a reference from trusted identities and a supplied digest.
/// The owner computes and verifies the digest; this module checks only syntax.
/// Valid references grant no authority and do not prove that bytes exist.
///
/// ## Examples
///
/// ```gleam
/// // report_value.reference(session, result_entry, digest, bundle_length)
/// ```
pub fn reference(
  session: SessionId,
  result_entry: EntryId,
  digest: String,
  byte_length: Int,
) -> Result(ReportRef, CorruptionReport) {
  use Nil <- result.try(check_digest(digest))
  use <- bool.lazy_guard(
    when: byte_length < 18 || byte_length > max_bundle_bytes,
    return: fn() { Error(fail("a complete bundle byte length")) },
  )
  Ok(ReportRef(session:, result_entry:, digest:, byte_length:))
}

/// Parses a bounded canonical data reference once for typed use by its readers.
/// Uppercase UUIDs, leading-zero lengths and alternate URI forms are refused.
///
/// ## Examples
///
/// ```gleam
/// assert report_value.parse_ref("result://bad") |> result.is_error
/// ```
pub fn parse_ref(text: String) -> Result(ReportRef, CorruptionReport) {
  use <- bool.lazy_guard(when: string.byte_size(text) > 160, return: fn() {
    Error(fail("a result reference of at most 160 bytes"))
  })
  case string.split(text, "/") {
    ["result:", "", session, entry, digest, length] ->
      parse_ref_fields(text, session, entry, digest, length)
    _ -> Error(fail("the canonical result reference vocabulary"))
  }
}

/// Formats the validated name without re-parsing or granting read authority.
///
/// ## Examples
///
/// ```gleam
/// // report_value.ref_to_string(reference)
/// ```
pub fn ref_to_string(reference: ReportRef) -> String {
  "result://"
  <> ids.session_id_to_string(reference.session)
  <> "/"
  <> ids.entry_id_to_string(reference.result_entry)
  <> "/"
  <> reference.digest
  <> "/"
  <> int.to_string(reference.byte_length)
}

fn parse_ref_fields(
  text: String,
  session: String,
  entry: String,
  digest: String,
  length: String,
) -> Result(ReportRef, CorruptionReport) {
  use session <- result.try(ids.parse_session_id(session))
  use entry <- result.try(ids.parse_entry_id(entry))
  use length <- result.try(
    int.parse(length)
    |> result.map_error(fn(_) { fail("a canonical decimal bundle length") }),
  )
  use reference <- result.try(reference(session, entry, digest, length))
  use <- bool.lazy_guard(when: ref_to_string(reference) != text, return: fn() {
    Error(fail("canonical reference spelling"))
  })
  Ok(reference)
}

fn bundle(
  terminal: BitArray,
  outcome: Outcome,
  metadata: Metadata,
) -> CompleteReport {
  let terminal_length = bit_array.byte_size(terminal)
  let metadata_length = bit_array.byte_size(metadata.encoded)
  CompleteReport(
    bytes: <<
      "LOOMRV01":utf8,
      terminal_length:size(32),
      metadata_length:size(32),
      terminal:bits,
      metadata.encoded:bits,
    >>,
    outcome:,
    metadata:,
  )
}

fn decode_segments(
  rest: BitArray,
  terminal_length: Int,
  metadata_length: Int,
) -> Result(CompleteReport, CorruptionReport) {
  case rest {
    <<
      terminal:bytes-size(terminal_length),
      metadata:bytes-size(metadata_length),
    >> -> {
      use outcome <- result.try(decode_terminal(terminal))
      use metadata <- result.try(decode_metadata(metadata))
      Ok(bundle(terminal, outcome, metadata))
    }
    _ -> Error(fail("exact complete segment lengths and no trailing bytes"))
  }
}

fn decode_canonical(
  bytes: BitArray,
) -> Result(mp.MsgPackValue, CorruptionReport) {
  use value <- result.try(mp.decode(bytes))
  use canonical <- result.try(
    mp.encode(value)
    |> result.map_error(fn(_) { fail("canonical encodable MessagePack") }),
  )
  use <- bool.lazy_guard(when: bytes != canonical, return: fn() {
    Error(fail("canonical MessagePack encoding"))
  })
  Ok(value)
}

fn outcome_value(outcome: Outcome) -> mp.MsgPackValue {
  case outcome {
    Completed(value) -> object([#("ok", mp.BoolValue(True)), #("value", value)])
    Errored(message, details) ->
      object([
        #("ok", mp.BoolValue(False)),
        #("message", mp.StringValue(message)),
        #("details", details),
      ])
  }
}

fn decode_outcome(value: mp.MsgPackValue) -> Result(Outcome, CorruptionReport) {
  use fields <- result.try(fields(value))
  use ok <- result.try(field(fields, "ok"))
  case ok {
    mp.BoolValue(True) -> {
      use Nil <- result.try(closed(fields, ["ok", "value"]))
      use value <- result.map(field(fields, "value"))
      Completed(value)
    }
    mp.BoolValue(False) -> {
      use Nil <- result.try(closed(fields, ["ok", "message", "details"]))
      use message <- result.try(text_field(fields, "message"))
      use details <- result.map(field(fields, "details"))
      Errored(message, details)
    }
    _ -> Error(fail("a boolean Outcome ok discriminator"))
  }
}

fn terminal_profile() -> TermProfile {
  TermProfile(
    max_terminal_bytes,
    255,
    65_536,
    65_536,
    32_768,
    max_terminal_bytes,
  )
}

fn metadata_profile() -> TermProfile {
  TermProfile(max_metadata_bytes, 16, 8192, 128, 128, 8192)
}

fn encode_checked(
  value: mp.MsgPackValue,
  profile: TermProfile,
) -> Result(BitArray, CorruptionReport) {
  use _remaining <- result.try(walk(
    value,
    0,
    #(profile.nodes, profile.bytes),
    profile,
  ))
  mp.encode(value)
  |> result.map_error(fn(_) { fail("an encodable bounded value") })
}

// Both counters transfer to siblings. No recursive call renews either budget.
fn walk(
  value: mp.MsgPackValue,
  depth: Int,
  budget: #(Int, Int),
  profile: TermProfile,
) -> Result(#(Int, Int), CorruptionReport) {
  use <- bool.lazy_guard(
    when: budget.0 <= 0 || depth > profile.depth,
    return: fn() { Error(fail("the shared node and nesting budget")) },
  )
  let budget = #(budget.0 - 1, budget.1)
  case value {
    mp.NilValue | mp.BoolValue(_) -> spend(budget, 1)
    mp.IntValue(value) -> walk_int(value, budget)
    mp.FloatValue(value) -> {
      // JavaScript terms can contain nonfinite numbers. The checked constructor
      // must refuse them before encoding, as the MessagePack decoder does on readback.
      use <- bool.lazy_guard(
        when: !{
          value >=. -1.7976931348623157e308 && value <=. 1.7976931348623157e308
        },
        return: fn() { Error(fail("a finite binary64 float")) },
      )
      spend(budget, 9)
    }
    mp.StringValue(value) ->
      walk_scalar(string.byte_size(value), budget, profile, "str")
    mp.BinaryValue(value) -> {
      use <- bool.lazy_guard(
        when: bit_array.bit_size(value) % 8 != 0,
        return: fn() { Error(fail("byte-aligned binary data")) },
      )
      walk_scalar(bit_array.byte_size(value), budget, profile, "bin")
    }
    mp.ArrayValue(items) -> {
      use <- bool.lazy_guard(when: depth >= profile.depth, return: fn() {
        Error(fail("the container nesting budget"))
      })
      use #(budget, count) <- result.try(walk_items(
        items,
        0,
        depth + 1,
        budget,
        profile,
      ))
      spend(budget, container_header(count))
    }
    mp.MapValue(entries) -> {
      use <- bool.lazy_guard(when: depth >= profile.depth, return: fn() {
        Error(fail("the container nesting budget"))
      })
      use #(budget, count) <- result.try(walk_entries(
        entries,
        0,
        depth + 1,
        budget,
        profile,
        dict.new(),
      ))
      spend(budget, container_header(count))
    }
  }
}

fn spend(
  budget: #(Int, Int),
  bytes: Int,
) -> Result(#(Int, Int), CorruptionReport) {
  case bytes <= budget.1 {
    True -> Ok(#(budget.0, budget.1 - bytes))
    False -> Error(fail("the exact encoded byte budget"))
  }
}

fn walk_int(
  value: Int,
  budget: #(Int, Int),
) -> Result(#(Int, Int), CorruptionReport) {
  use <- bool.lazy_guard(
    when: value < -9_223_372_036_854_775_808
      || value > 18_446_744_073_709_551_615,
    return: fn() { Error(fail("the MessagePack integer range")) },
  )
  let width = case value {
    _ if value >= -32 && value <= 127 -> 1
    _ if value >= -128 && value <= 255 -> 2
    _ if value >= -32_768 && value <= 65_535 -> 3
    _ if value >= -2_147_483_648 && value <= 4_294_967_295 -> 5
    _ -> 9
  }
  spend(budget, width)
}

fn walk_scalar(
  length: Int,
  budget: #(Int, Int),
  profile: TermProfile,
  kind: String,
) -> Result(#(Int, Int), CorruptionReport) {
  use <- bool.lazy_guard(when: length > profile.scalar_bytes, return: fn() {
    Error(fail("the scalar byte budget"))
  })
  let header = case length {
    _ if kind == "str" && length <= 31 -> 1
    _ if length <= 255 -> 2
    _ if length <= 65_535 -> 3
    _ -> 5
  }
  spend(budget, header + length)
}

fn container_header(count: Int) -> Int {
  case count {
    _ if count <= 15 -> 1
    _ if count <= 65_535 -> 3
    _ -> 5
  }
}

fn walk_items(
  items: List(mp.MsgPackValue),
  count: Int,
  depth: Int,
  budget: #(Int, Int),
  profile: TermProfile,
) -> Result(#(#(Int, Int), Int), CorruptionReport) {
  case items {
    [] -> Ok(#(budget, count))
    [item, ..rest] -> {
      use <- bool.lazy_guard(when: count >= profile.array_entries, return: fn() {
        Error(fail("the array element budget"))
      })
      use budget <- result.try(walk(item, depth, budget, profile))
      walk_items(rest, count + 1, depth, budget, profile)
    }
  }
}

fn walk_entries(
  entries: List(#(mp.MsgPackValue, mp.MsgPackValue)),
  count: Int,
  depth: Int,
  budget: #(Int, Int),
  profile: TermProfile,
  seen: Dict(mp.MsgPackValue, Nil),
) -> Result(#(#(Int, Int), Int), CorruptionReport) {
  case entries {
    [] -> Ok(#(budget, count))
    [#(key, value), ..rest] -> {
      use <- bool.lazy_guard(when: count >= profile.map_entries, return: fn() {
        Error(fail("the map entry budget"))
      })
      use budget <- result.try(walk(key, depth, budget, profile))
      use <- bool.lazy_guard(when: dict.has_key(seen, key), return: fn() {
        Error(fail("unique map keys"))
      })
      use budget <- result.try(walk(value, depth, budget, profile))
      walk_entries(
        rest,
        count + 1,
        depth,
        budget,
        profile,
        dict.insert(seen, key, Nil),
      )
    }
  }
}

// Artifact fingerprints and report-content digests are different names. The
// compiler already prefixes its fingerprint; retaining it verbatim avoids a
// renderer-only spelling that cannot be compared with original Compile evidence.
fn check_manifest(manifest: String) -> Result(Nil, CorruptionReport) {
  case <<manifest:utf8>> {
    <<"sha256-":utf8, digest:bytes-size(64)>> -> {
      use digest <- result.try(
        bit_array.to_string(digest)
        |> result.map_error(fn(_) { fail("a canonical artifact fingerprint") }),
      )
      check_digest(digest)
    }
    _ -> Error(fail("sha256- followed by 64 lowercase hexadecimal digits"))
  }
}

fn check_digest(digest: String) -> Result(Nil, CorruptionReport) {
  use <- bool.lazy_guard(when: string.byte_size(digest) != 64, return: fn() {
    Error(fail("a lowercase SHA-256 digest"))
  })
  case
    list.all(string.to_graphemes(digest), fn(char) {
      string.contains("0123456789abcdef", char)
    })
  {
    True -> Ok(Nil)
    False -> Error(fail("a lowercase SHA-256 digest"))
  }
}

fn check_u64(value: Int) -> Result(Nil, CorruptionReport) {
  case value >= 0 && value <= 18_446_744_073_709_551_615 {
    True -> Ok(Nil)
    False -> Error(fail("a nonnegative u64 observation"))
  }
}

fn check_text(value: String, limit: Int) -> Result(Nil, CorruptionReport) {
  case string.byte_size(value) <= limit {
    True -> Ok(Nil)
    False -> Error(fail("bounded UTF-8 observation text"))
  }
}

fn check_optional(
  value: Option(String),
  limit: Int,
) -> Result(Nil, CorruptionReport) {
  case value {
    None -> Ok(Nil)
    Some(text) -> check_text(text, limit)
  }
}

fn check_log(log: CallLog) -> Result(Nil, CorruptionReport) {
  use Nil <- result.try(check_u64(log.started_unix_ms))
  use Nil <- result.try(check_u64(log.elapsed_ms))
  use Nil <- result.try(check_u64(log.total))
  use Nil <- result.try(check_u64(log.failed))
  use Nil <- result.try(check_u64(log.cancelled))
  use Nil <- result.try(check_u64(log.unsettled))
  use count <- result.try(check_records(log.items, 0))
  use <- bool.lazy_guard(
    when: count > log.total
      || log.failed + log.cancelled + log.unsettled > log.total,
    return: fn() { Error(fail("call counters consistent with total")) },
  )
  Ok(Nil)
}

fn check_records(
  items: List(CallRecord),
  count: Int,
) -> Result(Int, CorruptionReport) {
  case items {
    [] -> Ok(count)
    [record, ..rest] -> {
      use <- bool.lazy_guard(when: count >= 128, return: fn() {
        Error(fail("at most 128 call records"))
      })
      use Nil <- result.try(check_text(record.cap, 64))
      use Nil <- result.try(check_optional(record.args, 96))
      use Nil <- result.try(check_optional(record.error, 48))
      use Nil <- result.try(check_u64(record.start_ms))
      use Nil <- result.try(check_u64(record.duration_ms))
      check_records(rest, count + 1)
    }
  }
}

fn check_stage(stage: StageReport) -> Result(Nil, CorruptionReport) {
  use Nil <- result.try(case stage {
    Unreported(reason) -> check_text(reason, 8192)
    Reported(applied, skipped, _) -> {
      use count <- result.try(check_layers(applied, 0))
      use _count <- result.map(check_layers(skipped, count))
      Nil
    }
  })

  // Counting canonical bytes rejects a stage before its segment is allocated.
  use _budget <- result.map(walk(
    stage_value(stage),
    0,
    #(8192, 65_536),
    metadata_profile(),
  ))
  Nil
}

fn check_layers(
  layers: List(String),
  count: Int,
) -> Result(Int, CorruptionReport) {
  case layers {
    [] -> Ok(count)
    [layer, ..rest] -> {
      use <- bool.lazy_guard(when: count >= 128, return: fn() {
        Error(fail("at most 128 applied and skipped entries together"))
      })
      use Nil <- result.try(check_text(layer, 8192))
      check_layers(rest, count + 1)
    }
  }
}

fn object(fields: List(#(String, mp.MsgPackValue))) -> mp.MsgPackValue {
  mp.MapValue(
    list.map(fields, fn(field) { #(mp.StringValue(field.0), field.1) }),
  )
}

fn stage_value(stage: StageReport) -> mp.MsgPackValue {
  case stage {
    Unreported(reason) ->
      object([
        #("kind", mp.StringValue("unreported")),
        #("reason", mp.StringValue(reason)),
      ])
    Reported(applied, skipped, quality) ->
      object([
        #("kind", mp.StringValue("reported")),
        #("applied", mp.ArrayValue(list.map(applied, mp.StringValue))),
        #("skipped", mp.ArrayValue(list.map(skipped, mp.StringValue))),
        #(
          "quality",
          mp.StringValue(case quality {
            Complete -> "complete"
            Degraded -> "degraded"
          }),
        ),
      ])
  }
}

fn log_value(log: CallLog) -> mp.MsgPackValue {
  object([
    #("started_unix_ms", mp.IntValue(log.started_unix_ms)),
    #("elapsed_ms", mp.IntValue(log.elapsed_ms)),
    #("total", mp.IntValue(log.total)),
    #("failed", mp.IntValue(log.failed)),
    #("cancelled", mp.IntValue(log.cancelled)),
    #("unsettled", mp.IntValue(log.unsettled)),
    #("items", mp.ArrayValue(list.map(log.items, record_value))),
  ])
}

fn record_value(record: CallRecord) -> mp.MsgPackValue {
  object(
    list.flatten([
      [#("cap", mp.StringValue(record.cap))],
      optional_field("args", record.args),
      [
        #(
          "status",
          mp.StringValue(case record.status {
            CallOk -> "ok"
            CallFailed -> "failed"
            CallCancelled -> "cancelled"
            CallUnsettled -> "unsettled"
          }),
        ),
      ],
      optional_field("error", record.error),
      [
        #("start_ms", mp.IntValue(record.start_ms)),
        #("duration_ms", mp.IntValue(record.duration_ms)),
      ],
    ]),
  )
}

fn optional_field(
  key: String,
  value: Option(String),
) -> List(#(String, mp.MsgPackValue)) {
  case value {
    None -> []
    Some(text) -> [#(key, mp.StringValue(text))]
  }
}

fn decode_metadata(bytes: BitArray) -> Result(Metadata, CorruptionReport) {
  use Nil <- result.try(msgpack_scan.metadata(bytes))
  use value <- result.try(decode_canonical(bytes))
  use fields <- result.try(fields(value))
  use Nil <- result.try(
    closed(fields, ["kind", "manifest_hash", "sandbox", "calls"]),
  )
  use kind <- result.try(text_field(fields, "kind"))
  use <- bool.lazy_guard(when: kind != "loom_report_metadata_v1", return: fn() {
    Error(fail("the independent owner metadata tag"))
  })
  use manifest <- result.try(text_field(fields, "manifest_hash"))
  use sandbox <- result.try(field(fields, "sandbox"))
  use sandbox <- result.try(decode_enforcement(sandbox))
  use calls <- result.try(field(fields, "calls"))
  use calls <- result.try(decode_log(calls))

  // Reconstruction rechecks all producer invariants without borrowing program data.
  use metadata <- result.map(metadata(manifest, sandbox, calls))
  Metadata(..metadata, encoded: bytes)
}

fn fields(
  value: mp.MsgPackValue,
) -> Result(Dict(String, mp.MsgPackValue), CorruptionReport) {
  case value {
    mp.MapValue(entries) -> {
      use entries <- result.map(
        list.try_map(entries, fn(entry) {
          case entry.0 {
            mp.StringValue(key) -> Ok(#(key, entry.1))
            _ -> Error(fail("text keys in known report metadata"))
          }
        }),
      )
      dict.from_list(entries)
    }
    _ -> Error(fail("a closed report object"))
  }
}

fn closed(
  fields: Dict(String, mp.MsgPackValue),
  names: List(String),
) -> Result(Nil, CorruptionReport) {
  case
    dict.size(fields) == list.length(names)
    && list.all(names, fn(name) { dict.has_key(fields, name) })
  {
    True -> Ok(Nil)
    False -> Error(fail("exactly the known report fields"))
  }
}

fn field(
  fields: Dict(String, mp.MsgPackValue),
  name: String,
) -> Result(mp.MsgPackValue, CorruptionReport) {
  dict.get(fields, name)
  |> result.map_error(fn(_) { fail("the required field " <> name) })
}

fn text(value: mp.MsgPackValue) -> Result(String, CorruptionReport) {
  case value {
    mp.StringValue(value) -> Ok(value)
    _ -> Error(fail("UTF-8 text"))
  }
}

fn text_field(
  fields: Dict(String, mp.MsgPackValue),
  name: String,
) -> Result(String, CorruptionReport) {
  use value <- result.try(field(fields, name))
  text(value)
}

fn number_field(
  fields: Dict(String, mp.MsgPackValue),
  name: String,
) -> Result(Int, CorruptionReport) {
  use value <- result.try(field(fields, name))
  case value {
    mp.IntValue(value) -> Ok(value)
    _ -> Error(fail("an integer observation"))
  }
}

fn array(
  value: mp.MsgPackValue,
) -> Result(List(mp.MsgPackValue), CorruptionReport) {
  case value {
    mp.ArrayValue(items) -> Ok(items)
    _ -> Error(fail("an observation array"))
  }
}

fn decode_enforcement(
  value: mp.MsgPackValue,
) -> Result(Enforcement, CorruptionReport) {
  use fields <- result.try(fields(value))
  use Nil <- result.try(closed(fields, ["build", "node"]))
  use build <- result.try(field(fields, "build"))
  use build <- result.try(decode_stage(build))
  use node <- result.try(field(fields, "node"))
  use node <- result.map(decode_stage(node))
  Enforcement(build:, node:)
}

fn decode_stage(
  value: mp.MsgPackValue,
) -> Result(StageReport, CorruptionReport) {
  use fields <- result.try(fields(value))
  use kind <- result.try(text_field(fields, "kind"))
  case kind {
    "unreported" -> {
      use Nil <- result.try(closed(fields, ["kind", "reason"]))
      use reason <- result.map(text_field(fields, "reason"))
      Unreported(reason)
    }
    "reported" -> decode_reported(fields)
    _ -> Error(fail("reported or unreported stage tag"))
  }
}

fn decode_reported(
  fields: Dict(String, mp.MsgPackValue),
) -> Result(StageReport, CorruptionReport) {
  use Nil <- result.try(
    closed(fields, ["kind", "applied", "skipped", "quality"]),
  )
  use applied <- result.try(field(fields, "applied"))
  use applied <- result.try(array(applied))
  use applied <- result.try(list.try_map(applied, text))
  use skipped <- result.try(field(fields, "skipped"))
  use skipped <- result.try(array(skipped))
  use skipped <- result.try(list.try_map(skipped, text))
  use quality <- result.try(text_field(fields, "quality"))
  use quality <- result.map(case quality {
    "complete" -> Ok(Complete)
    "degraded" -> Ok(Degraded)
    _ -> Error(fail("the actual complete or degraded observation"))
  })
  Reported(applied:, skipped:, quality:)
}

fn decode_log(value: mp.MsgPackValue) -> Result(CallLog, CorruptionReport) {
  use fields <- result.try(fields(value))
  use Nil <- result.try(
    closed(fields, [
      "started_unix_ms",
      "elapsed_ms",
      "total",
      "failed",
      "cancelled",
      "unsettled",
      "items",
    ]),
  )
  use started_unix_ms <- result.try(number_field(fields, "started_unix_ms"))
  use elapsed_ms <- result.try(number_field(fields, "elapsed_ms"))
  use total <- result.try(number_field(fields, "total"))
  use failed <- result.try(number_field(fields, "failed"))
  use cancelled <- result.try(number_field(fields, "cancelled"))
  use unsettled <- result.try(number_field(fields, "unsettled"))
  use items <- result.try(field(fields, "items"))
  use items <- result.try(array(items))
  use items <- result.map(list.try_map(items, decode_record))
  CallLog(
    started_unix_ms:,
    elapsed_ms:,
    total:,
    failed:,
    cancelled:,
    unsettled:,
    items:,
  )
}

fn decode_record(
  value: mp.MsgPackValue,
) -> Result(CallRecord, CorruptionReport) {
  use fields <- result.try(fields(value))
  use <- bool.lazy_guard(
    when: !list.all(dict.keys(fields), fn(key) {
      list.contains(
        ["cap", "args", "status", "error", "start_ms", "duration_ms"],
        key,
      )
    }),
    return: fn() { Error(fail("known call record fields")) },
  )
  use cap <- result.try(text_field(fields, "cap"))
  use args <- result.try(optional_text(fields, "args"))
  use status <- result.try(text_field(fields, "status"))
  use status <- result.try(case status {
    "ok" -> Ok(CallOk)
    "failed" -> Ok(CallFailed)
    "cancelled" -> Ok(CallCancelled)
    "unsettled" -> Ok(CallUnsettled)
    _ -> Error(fail("a known call status"))
  })
  use error <- result.try(optional_text(fields, "error"))
  use start_ms <- result.try(number_field(fields, "start_ms"))
  use duration_ms <- result.map(number_field(fields, "duration_ms"))
  CallRecord(cap:, args:, status:, error:, start_ms:, duration_ms:)
}

fn optional_text(
  fields: Dict(String, mp.MsgPackValue),
  name: String,
) -> Result(Option(String), CorruptionReport) {
  case dict.get(fields, name) {
    Error(Nil) -> Ok(None)
    Ok(value) -> result.map(text(value), Some)
  }
}

fn fail(expected: String) -> CorruptionReport {
  corruption.report(
    at: "core/report_value",
    on: "complete report",
    expected:,
    context: "",
  )
}
