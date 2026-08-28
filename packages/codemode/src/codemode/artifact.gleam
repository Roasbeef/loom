//// `report.emit` — the one capability both code-mode seams service, and
//// the one mechanism behind it.
////
//// # Why this is its own module
////
//// `cap/report` is on both vetting allowlists. It is the only module
//// they share, deliberately: a program that can say nothing structured
//// is not worth the seam it was vetted against, and an artifact is how
//// anything larger than a message leaves an execution. So both routers
//// have to answer `report.emit`, and if each answered it its own way
//// there would be two byte bounds, two ceilings and two content
//// addresses for one capability. There is one of each, here, and the
//// two routers hand it the same injected closure
//// (`codemode/workspace`, `codemode/orchestration`).
////
//// Before this existed the orchestration seam's `serviced_caps` simply
//// omitted `emit`, so `cap/report`'s one effectful function was on the
//// allowlist and refused as `unsupported_cap` whenever a program called
//// it (issue #91, item 1).
////
//// # What bounds an emission
////
//// Two things, and they bound different quantities.
////
//// A **per-emit byte bound** (`max_emit_bytes`) refuses one oversized
//// call in band. The cap channel's own frame cap is 16 MiB, which is the
//// wrong number to lean on here: a frame is transient and an artifact is
//// a durable mint, written under a content address into a store that
//// outlives the execution, the strand and the session. One megabyte is
//// what a program should be *summarising* into rather than dumping, and
//// a program that genuinely holds more than that has `proc.run` and a
//// path.
////
//// A **lifetime admission ceiling** (`default_emit_ceiling`) bounds how
//// many times one execution may mint at all. This is the
//// `satellite.CapCeiling` test met head on — every call writes something
//// that outlives the execution — and it is the same reason
//// `strand.note` has one. Sixty-four artifacts is more than any
//// deterministic plan we have written produces and far fewer than a loop
//// reaches in a second.
////
//// Neither bounds *storage*: the blob store is content-addressed, so a
//// program that emits the same bytes a hundred times writes them once
//// and gets one id back a hundred times. What the ceiling actually
//// bounds is distinct artifacts and the harness work of hashing and
//// writing them.

import broker/framing.{type CapOutcome}
import codemode/internal/args
import codemode/satellite.{
  type CapCeiling, type CapDenial, type CapPlan, type CapRequest, CapCeiling,
  CapDenial, ServedHere,
}
import core/msgpack
import gleam/bit_array
import gleam/int
import gleam/result

/// The capability name, as `cap/report.emit` sends it.
pub const emit_cap = "report.emit"

/// The largest artifact one call may emit, in bytes.
///
/// One mebibyte. See the module doc for why this is not the frame cap:
/// a frame is transient and an artifact is a durable mint.
pub const max_emit_bytes = 1_048_576

/// The default lifetime ceiling on `report.emit` admissions in one
/// execution.
///
/// Each admitted call writes a content-addressed file that outlives the
/// execution, which is the test `satellite.CapCeiling` states. Sixty-four
/// is generous for a deterministic plan — a program that produces one
/// artifact per reviewed file, over sixty-four files, is doing something
/// a human asked for — and nowhere near what an unbounded loop reaches.
pub const default_emit_ceiling = 64

/// The in-band code an emission refused at its ceiling travels under.
///
/// The same word `codemode/orchestration.admission_ceiling_code` uses,
/// because it is the same fact: this execution has minted as many of
/// these as it may, and waiting will not free a slot. `cap/report` has
/// no named variant for it — `map_error` carries any code verbatim into
/// `EmitDenied` — so the message is what a program reads, and it names
/// the capability and the number. The two constants are held equal by a
/// test rather than shared through an import, so neither seam module
/// depends on the other.
pub const emit_ceiling_code = "admission_ceiling"

/// The in-band code an oversized emission travels under.
pub const too_large_code = "too_large"

/// The in-band code a malformed emission travels under.
pub const invalid_argument_code = args.invalid_argument_code

/// The in-band code a store that would not take the bytes travels under.
pub const store_failed_code = "store_failed"

/// One artifact, as a program asked for it: the bytes, plus the two
/// labels the store records beside them.
///
/// Constructor invariants: `bytes` is at most `max_emit_bytes` long —
/// `plan` refuses a longer one before any closure is called, so an
/// implementation never sees one.
pub type Artifact {
  Artifact(name: String, content_type: String, bytes: BitArray)
}

/// Why an artifact could not be written. The harness's own failure, not
/// the program's: a refusal the program *caused* is caught in `plan`.
pub type EmitRefusal {
  /// The blob store would not take the bytes, with the reason.
  StoreFailed(reason: String)
}

/// How the harness writes one artifact and what it calls the result: the
/// content address the program gets back.
///
/// Injected rather than implemented here for the reason every seam in
/// this package is: `codemode` must not learn where a session keeps its
/// blobs. `client/codemode` fills it from the same `blob_root` the
/// harness's own tools overflow into, so an artifact a program emits and
/// an artifact `bash` overflowed land in one store under one addressing
/// scheme.
pub type Emit =
  fn(Artifact) -> Result(String, EmitRefusal)

/// The lifetime ceiling on `report.emit`, for a seam to include in the
/// list it hands the host.
///
/// ## Examples
///
/// ```gleam
/// // artifact.ceiling(64).cap == artifact.emit_cap
/// ```
///
pub fn ceiling(admissions: Int) -> CapCeiling {
  CapCeiling(cap: emit_cap, admissions:, code: emit_ceiling_code)
}

/// Decodes one `report.emit` frame and plans it onto `emit`.
///
/// Total over anything a satellite can send: a wrong-shaped argument and
/// an oversized payload are both `CapDenial`s the program reads as
/// `EmitDenied` and can repair, never a crash and never a write of
/// something guessed. Both are decided *before* the plan is built, so an
/// emission the harness will refuse costs no process and no store round
/// trip.
///
/// ## Examples
///
/// ```gleam
/// // artifact.plan(emit, request) == Ok(satellite.ServedHere(serve))
/// ```
///
pub fn plan(emit: Emit, request: CapRequest) -> Result(CapPlan, CapDenial) {
  use name <- result.try(args.string(request.args, "name"))
  use content_type <- result.try(args.string(request.args, "content_type"))
  use bytes <- result.try(args.binary(request.args, "bytes"))
  let size = bit_array.byte_size(bytes)
  case size > max_emit_bytes {
    True -> Error(oversized(size))
    False ->
      Ok(
        ServedHere(fn() {
          case emit(Artifact(name:, content_type:, bytes:)) {
            Ok(id) -> answer(id)
            Error(StoreFailed(reason:)) ->
              framing.CapErr(code: store_failed_code, message: reason)
          }
        }),
      )
  }
}

/// The answer a `report.emit` gets when the harness serviced it, as the
/// wire carries it. Named because both the plan above and a test that
/// asserts on the shape want the same one sentence about it: the id is
/// the content address, so two emissions of identical bytes answer
/// identically and neither is a second write.
pub fn answer(id: String) -> CapOutcome {
  framing.CapOk(
    value: msgpack.MapValue([
      #(msgpack.StringValue("id"), msgpack.StringValue(id)),
    ]),
  )
}

fn oversized(size: Int) -> CapDenial {
  CapDenial(
    code: too_large_code,
    message: "an artifact of "
      <> int.to_string(size)
      <> " bytes is larger than the "
      <> int.to_string(max_emit_bytes)
      <> " bytes one report.emit may carry; emit a summary, or write the "
      <> "whole of it to a file with proc.run",
  )
}
