//// The authenticated owner reads complete reports through one bounded chunk door.
//// Trusted assembly pins both the custodian and session; a result URI supplies
//// identity, never authority. Historical reads do not borrow the requesting
//// invocation's parent operation, and no path or whole-BLOB read enters here.
////
//// `routing` reserves known calls before fallback and returns `ScopedService`.
//// The existing satellite owns that worker, original identity, deadline and
//// cancellation; this module adds no wait, retry or quota process. Assembly
//// must install `ceilings` with this router before exposing the capability.
////
//// A successful response contains exactly reference, offset and binary bytes. `answer`
//// checks the complete framed CapResult, including its four-byte length prefix
//// and all envelope/body fields. Both satellite response paths use usage None.
//// CapRequest deliberately omits the framing ID: the check instead uses the
//// maximum u64, whose MessagePack encoding occupies nine bytes. Framing refuses
//// negative IDs and its integer encoder refuses values above u64; every admitted
//// actual ID is therefore no wider. This proves the 512-byte envelope allowance
//// without confusing the request's admission ordinal with its wire ID.

import broker/framing
import client/remote/custodian
import codemode/internal/args
import codemode/satellite
import core/ids
import core/msgpack as mp
import core/report_value as report
import gleam/bit_array
import gleam/option.{None}
import gleam/result
import gleam/string
import storage/owner_custody as custody

/// The sole capability owned by this authenticated router.
pub const capability = "report.result_chunk"

/// Maximum UTF-8 bytes of a canonical result reference before parsing.
pub const reference_bytes = 160

/// Fixed aligned slice size; the final slice may be shorter.
pub const chunk_bytes = 65_536

/// Complete encoded response, including u32 prefix and envelope allowance.
pub const encoded_bytes = 66_048

/// Maximum bytes for all 261 admitted replies of one invocation.
pub const aggregate_bytes = 17_238_528

/// Uses the host's serialized global admission ceiling, across all call scopes.
///
/// ## Examples
///
/// ```gleam
/// report_router.ceilings() == [satellite.CapCeiling("report.result_chunk", 261, "admission_ceiling")]
/// ```
pub fn ceilings() -> List(satellite.CapCeiling) {
  [satellite.CapCeiling(capability, 261, "admission_ceiling")]
}

/// Pins owner-local authority at trusted assembly, over the existing fallback.
/// Unknown capabilities forward the original request unchanged. Known malformed
/// or missing references never escape to workspace or another fallback router.
///
/// ## Examples
///
/// ```gleam
/// // report_router.routing(owner, session, over: satellite.default_router)
/// ```
pub fn routing(
  owner: custodian.Handle,
  session: ids.SessionId,
  over router: satellite.CapRouter,
) -> satellite.CapRouter {
  fn(request: satellite.CapRequest) {
    case request.cap {
      "report.result_chunk" -> {
        use held <- result.try(input(request.args, session))
        let #(reference, offset) = held
        Ok(
          satellite.ScopedService(fn() {
            case custodian.read_report_chunk(owner, reference, offset) {
              Ok(chunk) -> answer(chunk)
              Error(refusal) -> refused(refusal)
            }
          }),
        )
      }
      _ -> router(request)
    }
  }
}

fn input(
  value: mp.MsgPackValue,
  session: ids.SessionId,
) -> Result(#(report.ReportRef, Int), satellite.CapDenial) {
  case value {
    mp.MapValue([
      #(mp.StringValue("reference"), mp.StringValue(text)),
      #(mp.StringValue("offset"), mp.IntValue(offset)),
    ])
    | mp.MapValue([
        #(mp.StringValue("offset"), mp.IntValue(offset)),
        #(mp.StringValue("reference"), mp.StringValue(text)),
      ]) -> checked(text, offset, session)
    _ ->
      Error(args.invalid("Expected exactly reference text and offset integer."))
  }
}

fn checked(
  text: String,
  offset: Int,
  session: ids.SessionId,
) -> Result(#(report.ReportRef, Int), satellite.CapDenial) {
  use _ <- result.try(case string.byte_size(text) <= reference_bytes {
    True -> Ok(Nil)
    False -> Error(args.invalid("Reference exceeds its byte bound."))
  })
  use reference <- result.try(
    report.parse_ref(text)
    |> result.map_error(fn(_) {
      args.invalid("Invalid canonical result reference.")
    }),
  )

  // Identity and slice bounds are checked before the owner receives any ask.
  // The original stored row independently checks digest, length and final custody.
  case
    report.ref_session(reference) == session
    && offset >= 0
    && offset % chunk_bytes == 0
    && offset < report.ref_byte_length(reference)
  {
    True -> Ok(#(reference, offset))
    False ->
      Error(args.invalid("Reference session or aligned offset is invalid."))
  }
}

fn answer(chunk: custody.ReportChunk) -> framing.CapOutcome {
  let value =
    mp.MapValue([
      #(
        mp.StringValue("reference"),
        mp.StringValue(report.ref_to_string(chunk.reference)),
      ),
      #(mp.StringValue("offset"), mp.IntValue(chunk.offset)),
      #(mp.StringValue("bytes"), mp.BinaryValue(chunk.bytes)),
    ])
  let framed =
    framing.encode(framing.Frame(
      id: 18_446_744_073_709_551_615,
      body: framing.CapResult(framing.CapOk(value), None),
    ))

  // Encoding covers the actual closed reply shape rather than an estimate.
  case
    result.map(framed, fn(bytes) {
      bit_array.byte_size(bytes) <= encoded_bytes
      && bit_array.byte_size(chunk.bytes) <= chunk_bytes
    })
  {
    Ok(True) -> framing.CapOk(value)
    Ok(False) | Error(_) ->
      framing.CapErr("result_bound", "Report reply exceeds its bound.")
  }
}

fn refused(error: custody.Error) -> framing.CapOutcome {
  case error {
    custody.Missing ->
      framing.CapErr("not_found", "Original report is missing.")
    custody.Conflict | custody.Invalid(_) ->
      framing.CapErr(
        "invalid_reference",
        "Original report identity does not match.",
      )
    custody.Frozen | custody.CollectionPending ->
      framing.CapErr("unavailable", "Original report is not readable.")
    custody.Capacity | custody.Unavailable(_) ->
      framing.CapErr(
        "unavailable",
        "Original owner report read is unavailable.",
      )
  }
}
