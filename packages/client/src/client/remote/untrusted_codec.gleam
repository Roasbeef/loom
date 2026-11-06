//// The bytes of the untrusted executor wire (protocol-change/109).
////
//// `client/remote/untrusted_wire` says which frames an orchestrator and an
//// untrusted executor exchange; this module says how each becomes bytes and
//// back. A frame body is one UTF-8 JSON document, an object whose `frame` names
//// the frame and whose `body`, when it has one, is an object whose `kind` names
//// the constructor of the request, reply, callback or answer it carries. Byte
//// strings (tokens, bindings, state pieces, hook files, msgpack values and the
//// sandbox policy) are standard base64 with padding. Nothing here is a term, a
//// pid or a function, so the same bytes mean the same on any machine.
////
//// The executor is assumed hostile, so every decoder is total. A frame is
//// parsed by `core/json`, which bounds nesting and refuses a duplicated key;
//// every field is then read through a helper that answers with a
//// `CorruptionReport` when it is absent, of the wrong JSON type, out of range,
//// or not canonical base64. Ids are at least 1, offsets and sizes are not
//// negative, a token is at most 64 bytes and a binding is exactly
//// `untrusted_wire.binding_bytes`. No decoder calls `let assert`, `panic` or
//// `binary_to_term`, and the module has no `@external`.
////
//// ## Two steps for a reply
////
//// A receiver cannot decode a `Response` or an `Answer` from its own bytes,
//// because the sender chose the `kind` tag and a hostile sender chooses a wrong
//// one. `decode_envelope` therefore reads only the header (the frame name, the
//// id and the binding) and leaves the body as a `JsonValue`. The receiver looks
//// up which reply the id or binding expects and hands that kind to
//// `decode_response` or `decode_answer`, which refuse a body whose tag is any
//// other, even when the body is otherwise well formed. `decode_frame` does both
//// steps for tests and for the executor's side, where the kinds are known.
////
//// ## What reuses what
////
//// The value types that already have a codec are carried by it, so a change to
//// one of them is a change in one place: `core/codec` for the conversation
//// message inside a tool outcome, `client/grants` for a grant and an escalation
//// denial, `client/directories` for a directory access, `broker/policy` and
//// `core/msgpack` for the sandbox policy and capability values,
//// `client/lsp/profile` for a language server (as a JSON string, because it is
//// written with `gleam_json`) and `client/state_object` for a repository state.
////
//// ## What is carried lossily
////
//// Four values lose something on the wire, and each loss is a fact about the
//// existing codec or the orchestrator's own use of the value, not a choice made
//// here.
////
//// - `agent.ResultSchemaUnmet`, which `HoldsAnswered` could in principle carry,
////   holds a schema, the received value and a mismatch description, none of
////   which has a codec. It is encoded as `agent.PlaneFailed("result schema
////   unmet")`. The owner's `holds` answers only `ToolNotHeld`,
////   `AgencyUnavailable` or `PlaneFailed` in practice (`client/agency.holds`),
////   so the case does not arise.
//// - `escalation.ExecutionDenial` carries the helper's enforcement list, and
////   `client/grants.decode_denial` rebuilds it as an empty list, as the stored
////   form of a denial does. The operator is asked about the grants wanted and
////   the reason, not about the list.
//// - `workspace_plane.Census.extensions` is encoded as nothing, and decodes as
////   an empty list. A workspace on an executor registers no extension tool, and
////   the orchestrator reads the discovered list only to name the extensions it
////   refuses (`serve.remote_extension_refusals`). Carrying a `Record` and a
////   `Manifest` faithfully needs a codec for each, which would be a large
////   addition for a list that a hostile executor can in any case forge.
//// - A directory access is a set of roots, and `client/directories` reads its
////   entries back in the reverse of the order it wrote them, so an `Authority`
////   with two or more roots returns with its lists reordered. The roots are
////   the same, and nothing reads their order.
////
//// ## Outcomes and blobs (protocol-change/110)
////
//// `oversized` is the one frame with no body: its id, size and digest are the
//// whole of it. A blob's or an outcome's digest is read only as 64 lower-case
//// hex digits (`digest_of`), the one spelling that may become a file name, and
//// every piece of bytes is bounded by `untrusted_wire.max_piece_bytes` before
//// anything holds it. `encode_outcome_bytes` is the outcome's encoding that an
//// outcome fetched in pieces is cut from; the same outcome always encodes to
//// the same bytes, which is what lets each piece come from a fresh read of the
//// executor's ledger.
////
//// One encoding failure is also handled by refusal rather than by a result.
//// `core/msgpack` can fail to encode an integer outside 64 bits, and
//// `encode_frame` does not return a `Result`. Such a value is written as JSON
//// `null`, which no decoder accepts where bytes belong, so the receiver refuses
//// the frame instead of reading a different value.
////
//// ## Flow
////
//// `encode_frame` → `decode_envelope` → `decode_request` → `decode_response` →
//// `decode_callback` → `decode_answer` → `decode_frame`
////
//// 1. `encode_frame` writes any frame as the bytes of one JSON document.
//// 2. `decode_envelope` reads the header of a received frame and checks the
////    ids and bindings, and keeps the body undecoded.
//// 3. `decode_request` and `decode_callback` read the body of a frame whose
////    constructor the receiver does not choose.
//// 4. `decode_response` and `decode_answer` read the body of a frame against
////    the kind the receiver expects.
//// 5. `decode_frame` runs the two steps together given the kinds.

import broker/escalation
import broker/framing
import broker/policy as sandbox_policy
import client/codemode as codemode_wiring
import client/directories
import client/escalate
import client/grants as grant_codec
import client/hookserve
import client/lsp/profile
import client/notice
import client/owner_services
import client/remote/blob_transfer
import client/remote/protocol
import client/remote/remote_census.{type McpStatus, type StateCensus}
import client/remote/untrusted_wire
import client/state_object
import client/state_transfer
import client/system_prompt
import client/wiring
import client/workspace_plane
import codemode/satellite
import codemode/vet/policy as vet_policy
import core/codec
import core/corruption.{type CorruptionReport}
import core/ids
import core/json.{type JsonValue}
import core/message
import core/msgpack
import gleam/bit_array
import gleam/int
import gleam/json as gleam_json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/operation
import runtime/api
import runtime/effects
import tools/agent
import tools/directory_access
import tools/tool

/// A frame whose header is read and whose body is not yet decoded, because the
/// receiver must first look up which kind of reply the id or binding expects.
pub type Envelope {
  /// The orchestrator's first frame.
  HelloEnvelope(wire: Int, protocol: Int)

  /// The executor's answer to `HelloEnvelope`.
  WelcomeEnvelope(wire: Int, protocol: Int)

  /// A request, whose body `decode_request` reads.
  RequestEnvelope(id: Int, body: JsonValue)

  /// The orchestrator no longer wants the answer to request `id`.
  CancelEnvelope(id: Int)

  /// A reply to request `id`, whose body `decode_response` reads against the
  /// kind that request expects.
  ResponseEnvelope(id: Int, body: JsonValue)

  /// An owner request from the executor, whose body `decode_callback` reads.
  /// `binding` is exactly `untrusted_wire.binding_bytes` bytes.
  CallbackEnvelope(binding: BitArray, id: Int, body: JsonValue)

  /// The owner's answer to callback `id` on `binding`, whose body
  /// `decode_answer` reads against the kind that callback expects.
  AnswerEnvelope(binding: BitArray, id: Int, body: JsonValue)

  /// The executor's promise of an outcome too large for a frame, in place of
  /// the response to request `id`. It has no body: the size and the digest
  /// are the whole of it, and `digest` is 64 lower-case hex digits.
  OversizedEnvelope(id: Int, size: Int, digest: String)
}

// The fields of a decoded JSON object, in the order they were written.
type Fields =
  List(#(String, JsonValue))

// The boundary every report from this module names.
const boundary = "client/remote/untrusted_codec"

// The longest attach token a frame may carry.
const max_token_bytes = 64

// The bounds of a signed 64-bit integer, which no field of the wire exceeds.
const min_int = -9_223_372_036_854_775_808

const max_int = 9_223_372_036_854_775_807

/// Encodes a frame as the bytes of one JSON document.
///
/// ## Examples
///
/// ```gleam
/// let bytes = untrusted_codec.encode_frame(untrusted_wire.Cancel(id: 7))
/// assert untrusted_codec.decode_envelope(bytes)
///   == Ok(untrusted_codec.CancelEnvelope(id: 7))
/// ```
pub fn encode_frame(frame: untrusted_wire.Frame) -> BitArray {
  frame
  |> frame_json
  |> json.to_string
  |> bit_array.from_string
}

/// Reads the header of a received frame and leaves its body undecoded.
///
/// Every input is an `Error` rather than a crash: bytes that are not UTF-8,
/// text that is not one JSON object, a frame name this module does not know,
/// a missing or mistyped header field, an id below 1, and a binding of any
/// length but `untrusted_wire.binding_bytes`.
///
/// ## Examples
///
/// ```gleam
/// let bytes = untrusted_codec.encode_frame(untrusted_wire.Hello(1, 6))
/// assert untrusted_codec.decode_envelope(bytes)
///   == Ok(untrusted_codec.HelloEnvelope(wire: 1, protocol: 6))
/// ```
///
/// ```gleam
/// let assert Error(_report) = untrusted_codec.decode_envelope(<<255, 254>>)
/// ```
pub fn decode_envelope(bytes: BitArray) -> Result(Envelope, CorruptionReport) {
  use <- bounded_frame(bytes)
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.map_error(fn(_not_text) {
      corrupt("frame", "UTF-8 text", "bytes")
    }),
  )
  use value <- result.try(json.parse(text))
  use fields <- result.try(object_of(value, "frame"))
  use name <- result.try(string_field(fields, "frame"))

  // The frame name decides which header fields follow it. A frame that is
  // none of the eight is not one this protocol sends.
  case name {
    "hello" -> versions_envelope(fields, HelloEnvelope)
    "welcome" -> versions_envelope(fields, WelcomeEnvelope)
    "request" -> identified_envelope(fields, RequestEnvelope)
    "cancel" -> cancel_envelope(fields)
    "response" -> identified_envelope(fields, ResponseEnvelope)
    "callback" -> bound_envelope(fields, CallbackEnvelope)
    "answer" -> bound_envelope(fields, AnswerEnvelope)
    "oversized" -> oversized_envelope(fields)
    other -> Error(unknown("frame", other))
  }
}

/// The bytes of a tool outcome as the executor encodes it for an outcome
/// fetched in pieces (protocol-change/110). The same outcome encodes to the same
/// bytes, which is what lets each piece be cut from a fresh read of the ledger.
///
/// ## Examples
///
/// ```gleam
/// let outcome = effects.ToolFailed(reason: "no")
/// assert untrusted_codec.decode_outcome_bytes(
///   untrusted_codec.encode_outcome_bytes(outcome),
/// ) == Ok(outcome)
/// ```
pub fn encode_outcome_bytes(outcome: effects.ToolOutcome) -> BitArray {
  outcome
  |> encode_outcome
  |> json.to_string
  |> bit_array.from_string
}

/// Reads the bytes `encode_outcome_bytes` wrote, totally. The orchestrator calls
/// it only after the bytes' size and SHA-256 matched what the executor declared.
///
/// ## Examples
///
/// ```gleam
/// let assert Error(_report) = untrusted_codec.decode_outcome_bytes(<<"{">>)
/// ```
pub fn decode_outcome_bytes(
  bytes: BitArray,
) -> Result(effects.ToolOutcome, CorruptionReport) {
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.map_error(fn(_not_text) {
      corrupt("outcome", "UTF-8 text", "bytes")
    }),
  )
  use value <- result.try(json.parse(text))
  decode_outcome(value)
}

/// Decodes the body of a `request` frame.
///
/// ## Examples
///
/// ```gleam
/// let frame = untrusted_wire.Request(1, untrusted_wire.ListUnackedRequest("s"))
/// let assert Ok(untrusted_codec.RequestEnvelope(body:, ..)) =
///   untrusted_codec.decode_envelope(untrusted_codec.encode_frame(frame))
/// assert untrusted_codec.decode_request(body)
///   == Ok(untrusted_wire.ListUnackedRequest("s"))
/// ```
pub fn decode_request(
  body: JsonValue,
) -> Result(untrusted_wire.Request, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(body, "request"))

  // The kind names the request constructor, and each constructor reads its
  // own fields; a kind that is none of them is not a request.
  case kind {
    "attach" -> decode_attach_request(fields)
    "run" -> decode_run_request(fields)
    "query" -> {
      use key <- result.map(nested(fields, "key", decode_key))
      untrusted_wire.QueryRequest(key:)
    }
    "query_or_fence" -> {
      use key <- result.try(nested(fields, "key", decode_key))
      use incarnation <- result.map(int_field(fields, "incarnation"))
      untrusted_wire.QueryOrFenceRequest(key:, incarnation:)
    }
    "list_unacked" -> {
      use session <- result.map(string_field(fields, "session"))
      untrusted_wire.ListUnackedRequest(session:)
    }
    "ack" -> {
      use key <- result.map(nested(fields, "key", decode_key))
      untrusted_wire.AckRequest(key:)
    }
    "close" -> decode_close_request(fields)
    "state_capture" -> decode_capture_request(fields)
    "state_apply" -> decode_apply_request(fields)
    "state_chunk" -> {
      use piece <- result.map(nested(fields, "piece", decode_piece))
      untrusted_wire.StateChunkRequest(piece:)
    }
    "state_status" -> {
      use hash <- result.map(string_field(fields, "hash"))
      untrusted_wire.StateStatusRequest(hash:)
    }
    "state_fetch" -> {
      use hash <- result.try(string_field(fields, "hash"))
      use offset <- result.map(nat_field(fields, "offset"))
      untrusted_wire.StateFetchRequest(hash:, offset:)
    }
    "blob_status" -> {
      use binding <- result.try(field_as(fields, "binding", binding_of))
      use digest <- result.map(field_as(fields, "digest", digest_of))
      untrusted_wire.BlobStatusRequest(binding:, digest:)
    }
    "blob_put" -> {
      use binding <- result.try(field_as(fields, "binding", binding_of))
      use piece <- result.map(nested(fields, "piece", decode_blob_piece))
      untrusted_wire.BlobPutRequest(binding:, piece:)
    }
    "outcome_piece" -> {
      use key <- result.try(nested(fields, "key", decode_key))
      use offset <- result.map(nat_field(fields, "offset"))
      untrusted_wire.OutcomePieceRequest(key:, offset:)
    }
    other -> Error(unknown("request", other))
  }
}

/// Decodes the body of a `response` frame against the kind the request it
/// answers expects. A body tagged for any other kind is an `Error`, whatever
/// else is true of it.
///
/// ## Examples
///
/// ```gleam
/// let response = untrusted_wire.ChunkAnswered(state_transfer.Accepted(held: 4))
/// let frame = untrusted_wire.Response(1, response)
/// let assert Ok(untrusted_codec.ResponseEnvelope(body:, ..)) =
///   untrusted_codec.decode_envelope(untrusted_codec.encode_frame(frame))
/// assert untrusted_codec.decode_response(untrusted_wire.ChunkKind, body)
///   == Ok(response)
/// let assert Error(_report) =
///   untrusted_codec.decode_response(untrusted_wire.LookupKind, body)
/// ```
pub fn decode_response(
  kind: untrusted_wire.ResponseKind,
  body: JsonValue,
) -> Result(untrusted_wire.Response, CorruptionReport) {
  use #(tag, fields) <- result.try(tagged_of(body, "response"))
  use Nil <- result.try(expect_tag("response", tag, response_tag(kind)))

  // The expected kind, not the tag the sender wrote, chooses the decoder.
  case kind {
    untrusted_wire.AttachKind ->
      decode_answer_field(fields, decode_attached, decode_refusal)
      |> result.map(untrusted_wire.AttachAnswered)
    untrusted_wire.RunKind ->
      nested(fields, "answer", decode_run_answer)
      |> result.map(untrusted_wire.RunAnswered)
    untrusted_wire.LookupKind ->
      decode_answer_field(fields, decode_lookup, decode_refusal)
      |> result.map(untrusted_wire.LookupAnswered)
    untrusted_wire.UnackedKind ->
      decode_answer_field(fields, decode_unacked, decode_refusal)
      |> result.map(untrusted_wire.UnackedAnswered)
    untrusted_wire.CloseKind ->
      decode_answer_field(fields, decode_close_outcome, decode_refusal)
      |> result.map(untrusted_wire.CloseAnswered)
    untrusted_wire.CaptureKind ->
      decode_answer_field(fields, decode_optional_state, decode_refusal)
      |> result.map(untrusted_wire.CaptureAnswered)
    untrusted_wire.ApplyKind ->
      decode_answer_field(
        fields,
        fn(value) { string_of(value, "ok") },
        decode_refusal,
      )
      |> result.map(untrusted_wire.ApplyAnswered)
    untrusted_wire.ChunkKind ->
      nested(fields, "verdict", decode_verdict)
      |> result.map(untrusted_wire.ChunkAnswered)
    untrusted_wire.StatusKind ->
      decode_answer_field(fields, decode_stage, fn(value) {
        string_of(value, "error")
      })
      |> result.map(untrusted_wire.StatusAnswered)
    untrusted_wire.FetchKind ->
      nested(fields, "fetched", decode_fetched)
      |> result.map(untrusted_wire.FetchAnswered)
    untrusted_wire.BlobStatusKind ->
      decode_answer_field(fields, decode_blob_stage, fn(value) {
        string_of(value, "error")
      })
      |> result.map(untrusted_wire.BlobStatusAnswered)
    untrusted_wire.BlobPutKind ->
      nested(fields, "verdict", decode_blob_verdict)
      |> result.map(untrusted_wire.BlobPutAnswered)
    untrusted_wire.OutcomePieceKind ->
      nested(fields, "piece", decode_outcome_piece)
      |> result.map(untrusted_wire.OutcomePieceAnswered)
  }
}

/// Decodes the body of a `callback` frame.
///
/// ## Examples
///
/// ```gleam
/// let callback = untrusted_wire.FactGetCall(key: "k")
/// let frame = untrusted_wire.Callback(binding, 1, callback)
/// let assert Ok(untrusted_codec.CallbackEnvelope(body:, ..)) =
///   untrusted_codec.decode_envelope(untrusted_codec.encode_frame(frame))
/// assert untrusted_codec.decode_callback(body) == Ok(callback)
/// ```
pub fn decode_callback(
  body: JsonValue,
) -> Result(untrusted_wire.Callback, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(body, "callback"))

  // The kind names the owner request; the two that carry nothing are told
  // apart by the kind alone.
  case kind {
    "escalate" -> {
      use refused <- result.try(nested(fields, "refused", decode_refused))
      use remaining_ms <- result.map(nat_field(fields, "remaining_ms"))
      untrusted_wire.EscalateCall(refused:, remaining_ms:)
    }
    "fact_get" -> {
      use key <- result.map(string_field(fields, "key"))
      untrusted_wire.FactGetCall(key:)
    }
    "fact_put" -> decode_fact_put_call(fields)
    "fact_put_blind" -> {
      use key <- result.try(string_field(fields, "key"))
      use value <- result.map(field(fields, "value"))
      untrusted_wire.FactPutBlindCall(key:, value:)
    }
    "fact_delete" -> {
      use key <- result.map(string_field(fields, "key"))
      untrusted_wire.FactDeleteCall(key:)
    }
    "fact_list" -> {
      use prefix <- result.map(string_field(fields, "prefix"))
      untrusted_wire.FactListCall(prefix:)
    }
    "notify" -> decode_notify_call(fields)
    "strand_activity" -> {
      use strand <- result.map(string_field(fields, "strand"))
      untrusted_wire.StrandActivityCall(strand:)
    }
    "wake" -> {
      use strand <- result.try(string_field(fields, "strand"))
      use text <- result.map(string_field(fields, "text"))
      untrusted_wire.WakeCall(strand:, text:)
    }
    "holds" -> {
      use caller <- result.try(nested(fields, "caller", decode_caller))
      use named <- result.map(string_field(fields, "tool"))
      untrusted_wire.HoldsCall(caller:, tool: named)
    }
    "tail" -> {
      use run <- result.try(nested(fields, "run", decode_tool_run))
      use tail <- result.map(nested(fields, "tail", decode_output_tail))
      untrusted_wire.TailCast(run:, tail:)
    }
    "capability" -> {
      use call <- result.map(nested(fields, "call", decode_cap_call))
      untrusted_wire.CapabilityCall(call:)
    }
    "mcp_plan" -> Ok(untrusted_wire.McpPlanCall)
    "git_identity" -> Ok(untrusted_wire.GitIdentityCall)
    other -> Error(unknown("callback", other))
  }
}

/// Decodes the body of an `answer` frame against the kind the callback it
/// answers expects. A body tagged for any other kind is an `Error`.
///
/// ## Examples
///
/// ```gleam
/// let answer = untrusted_wire.WakeAnswered(Ok(Nil))
/// let frame = untrusted_wire.Answer(binding, 1, answer)
/// let assert Ok(untrusted_codec.AnswerEnvelope(body:, ..)) =
///   untrusted_codec.decode_envelope(untrusted_codec.encode_frame(frame))
/// assert untrusted_codec.decode_answer(untrusted_wire.WakeKind, body)
///   == Ok(answer)
/// let assert Error(_report) =
///   untrusted_codec.decode_answer(untrusted_wire.NotifyKind, body)
/// ```
pub fn decode_answer(
  kind: untrusted_wire.AnswerKind,
  body: JsonValue,
) -> Result(untrusted_wire.Answer, CorruptionReport) {
  use #(tag, fields) <- result.try(tagged_of(body, "answer"))
  use Nil <- result.try(expect_tag("answer", tag, answer_tag(kind)))

  // The expected kind, not the tag the sender wrote, chooses the decoder.
  case kind {
    untrusted_wire.DecidedKind ->
      nested(fields, "decision", decode_decision)
      |> result.map(untrusted_wire.Decided)
    untrusted_wire.FactCellKind ->
      decode_answer_field(fields, decode_fact_cell, decode_fact_fault)
      |> result.map(untrusted_wire.FactCellAnswered)
    untrusted_wire.FactSeqKind ->
      decode_answer_field(
        fields,
        fn(value) { nat_of(value, "ok") },
        decode_fact_fault,
      )
      |> result.map(untrusted_wire.FactSeqAnswered)
    untrusted_wire.FactDoneKind ->
      decode_answer_field(fields, decode_nil, decode_fact_fault)
      |> result.map(untrusted_wire.FactDoneAnswered)
    untrusted_wire.FactListKind ->
      decode_answer_field(fields, decode_fact_entries, decode_fact_fault)
      |> result.map(untrusted_wire.FactListAnswered)
    untrusted_wire.NotifyKind ->
      decode_answer_field(fields, decode_delivered, fn(value) {
        string_of(value, "error")
      })
      |> result.map(untrusted_wire.NotifyAnswered)
    untrusted_wire.ActivityKind ->
      decode_answer_field(fields, decode_activity, fn(value) {
        string_of(value, "error")
      })
      |> result.map(untrusted_wire.ActivityAnswered)
    untrusted_wire.WakeKind ->
      decode_answer_field(fields, decode_nil, fn(value) {
        string_of(value, "error")
      })
      |> result.map(untrusted_wire.WakeAnswered)
    untrusted_wire.HoldsKind ->
      decode_answer_field(fields, decode_nil, decode_agent_refusal)
      |> result.map(untrusted_wire.HoldsAnswered)
    untrusted_wire.CapabilityKind ->
      decode_answer_field(fields, decode_cap_outcome, decode_cap_denial)
      |> result.map(untrusted_wire.CapabilityAnswered)
    untrusted_wire.McpPlanKind ->
      nested(fields, "plan", decode_mcp_plan)
      |> result.map(untrusted_wire.McpPlanAnswered)
    untrusted_wire.GitIdentityKind ->
      option_field(fields, "identity", decode_git_identity)
      |> result.map(untrusted_wire.GitIdentityAnswered)
  }
}

/// Decodes a whole frame when the reply kinds are known: `response` says which
/// reply the request with an id expects, and `answer` says which answer the
/// callback with a binding and id expects. A response or answer for which the
/// lookup says `None` is an `Error`, because nothing was waiting for it.
///
/// ## Examples
///
/// ```gleam
/// let frame = untrusted_wire.Cancel(id: 3)
/// assert untrusted_codec.decode_frame(
///     untrusted_codec.encode_frame(frame),
///     fn(_id) { None },
///     fn(_binding, _id) { None },
///   )
///   == Ok(frame)
/// ```
@internal
pub fn decode_frame(
  bytes: BitArray,
  response: fn(Int) -> Option(untrusted_wire.ResponseKind),
  answer: fn(BitArray, Int) -> Option(untrusted_wire.AnswerKind),
) -> Result(untrusted_wire.Frame, CorruptionReport) {
  use envelope <- result.try(decode_envelope(bytes))

  // The envelope names the frame. Only a reply needs the caller's lookup,
  // because only a reply is decoded against a kind the receiver remembers.
  case envelope {
    HelloEnvelope(wire:, protocol:) ->
      Ok(untrusted_wire.Hello(wire:, protocol:))
    WelcomeEnvelope(wire:, protocol:) ->
      Ok(untrusted_wire.Welcome(wire:, protocol:))
    RequestEnvelope(id:, body:) ->
      decode_request(body)
      |> result.map(fn(request) { untrusted_wire.Request(id:, request:) })
    CancelEnvelope(id:) -> Ok(untrusted_wire.Cancel(id:))
    ResponseEnvelope(id:, body:) -> response_frame(id, body, response(id))
    CallbackEnvelope(binding:, id:, body:) ->
      decode_callback(body)
      |> result.map(fn(callback) {
        untrusted_wire.Callback(binding:, id:, callback:)
      })
    AnswerEnvelope(binding:, id:, body:) ->
      answer_frame(binding, id, body, answer(binding, id))
    OversizedEnvelope(id:, size:, digest:) ->
      Ok(untrusted_wire.Oversized(id:, size:, digest:))
  }
}

// --- the envelope ------------------------------------------------------------

/// Refuses a frame larger than the wire allows before any of it is parsed.
fn bounded_frame(
  bytes: BitArray,
  next: fn() -> Result(Envelope, CorruptionReport),
) -> Result(Envelope, CorruptionReport) {
  let size = bit_array.byte_size(bytes)

  // The socket enforces this limit before it buffers a frame, so a larger one
  // here is a caller that skipped the socket; it is refused all the same.
  case size <= untrusted_wire.max_frame_bytes {
    True -> next()
    False ->
      Error(corrupt(
        "frame",
        "at most " <> int.to_string(untrusted_wire.max_frame_bytes) <> " bytes",
        int.to_string(size) <> " bytes",
      ))
  }
}

/// Reads the two version numbers of a `hello` or a `welcome`.
fn versions_envelope(
  fields: Fields,
  make: fn(Int, Int) -> Envelope,
) -> Result(Envelope, CorruptionReport) {
  use wire <- result.try(int_field(fields, "wire"))
  use protocol <- result.map(int_field(fields, "protocol"))
  make(wire, protocol)
}

/// Reads the id and the body of a `request` or a `response`.
fn identified_envelope(
  fields: Fields,
  make: fn(Int, JsonValue) -> Envelope,
) -> Result(Envelope, CorruptionReport) {
  use id <- result.try(id_field(fields, "id"))
  use body <- result.map(field(fields, "body"))
  make(id, body)
}

/// Reads the id of a `cancel`.
fn cancel_envelope(fields: Fields) -> Result(Envelope, CorruptionReport) {
  use id <- result.map(id_field(fields, "id"))
  CancelEnvelope(id:)
}

/// Reads the binding, the id and the body of a `callback` or an `answer`.
fn bound_envelope(
  fields: Fields,
  make: fn(BitArray, Int, JsonValue) -> Envelope,
) -> Result(Envelope, CorruptionReport) {
  use binding <- result.try(field_as(fields, "binding", binding_of))
  use id <- result.try(id_field(fields, "id"))
  use body <- result.map(field(fields, "body"))
  make(binding, id, body)
}

/// Reads the id, the size and the digest of an `oversized`.
fn oversized_envelope(fields: Fields) -> Result(Envelope, CorruptionReport) {
  use id <- result.try(id_field(fields, "id"))
  use size <- result.try(nat_field(fields, "size"))
  use digest <- result.map(field_as(fields, "digest", digest_of))
  OversizedEnvelope(id:, size:, digest:)
}

/// Decodes a response body against the kind its id expects.
fn response_frame(
  id: Int,
  body: JsonValue,
  expected: Option(untrusted_wire.ResponseKind),
) -> Result(untrusted_wire.Frame, CorruptionReport) {
  // The lookup answers `None` for an id that no request is waiting on, which
  // a hostile executor can choose to name.
  case expected {
    Some(kind) ->
      decode_response(kind, body)
      |> result.map(fn(response) { untrusted_wire.Response(id:, response:) })
    None ->
      Error(corrupt("id", "a request awaiting a reply", int.to_string(id)))
  }
}

/// Decodes an answer body against the kind its callback expects.
fn answer_frame(
  binding: BitArray,
  id: Int,
  body: JsonValue,
  expected: Option(untrusted_wire.AnswerKind),
) -> Result(untrusted_wire.Frame, CorruptionReport) {
  // The lookup answers `None` for a callback that was never sent, or one that
  // waits for no answer, such as a tail.
  case expected {
    Some(kind) ->
      decode_answer(kind, body)
      |> result.map(fn(answer) { untrusted_wire.Answer(binding:, id:, answer:) })
    None ->
      Error(corrupt("id", "a callback awaiting an answer", int.to_string(id)))
  }
}

/// The JSON of a frame: the frame name and its fields.
fn frame_json(frame: untrusted_wire.Frame) -> JsonValue {
  case frame {
    untrusted_wire.Hello(wire:, protocol:) ->
      frame_object("hello", [
        #("wire", json.Int(wire)),
        #("protocol", json.Int(protocol)),
      ])
    untrusted_wire.Welcome(wire:, protocol:) ->
      frame_object("welcome", [
        #("wire", json.Int(wire)),
        #("protocol", json.Int(protocol)),
      ])
    untrusted_wire.Request(id:, request:) ->
      frame_object("request", [
        #("id", json.Int(id)),
        #("body", encode_request(request)),
      ])
    untrusted_wire.Cancel(id:) ->
      frame_object("cancel", [#("id", json.Int(id))])
    untrusted_wire.Response(id:, response:) ->
      frame_object("response", [
        #("id", json.Int(id)),
        #("body", encode_response(response)),
      ])
    untrusted_wire.Callback(binding:, id:, callback:) ->
      frame_object("callback", [
        #("binding", encode_bytes(binding)),
        #("id", json.Int(id)),
        #("body", encode_callback(callback)),
      ])
    untrusted_wire.Answer(binding:, id:, answer:) ->
      frame_object("answer", [
        #("binding", encode_bytes(binding)),
        #("id", json.Int(id)),
        #("body", encode_answer(answer)),
      ])
    untrusted_wire.Oversized(id:, size:, digest:) ->
      frame_object("oversized", [
        #("id", json.Int(id)),
        #("size", json.Int(size)),
        #("digest", json.String(digest)),
      ])
  }
}

/// An object whose `frame` names the frame, followed by its fields.
fn frame_object(name: String, fields: Fields) -> JsonValue {
  json.Object([#("frame", json.String(name)), ..fields])
}

// --- requests ----------------------------------------------------------------

/// The JSON of a request.
fn encode_request(request: untrusted_wire.Request) -> JsonValue {
  case request {
    untrusted_wire.AttachRequest(
      version:,
      session:,
      workspace:,
      incarnation:,
      token:,
      binding:,
    ) ->
      tagged("attach", [
        #("version", json.Int(version)),
        #("session", json.String(session)),
        #("workspace", json.String(workspace)),
        #("incarnation", json.Int(incarnation)),
        #("token", encode_bytes(token)),
        #("binding", encode_bytes(binding)),
      ])
    untrusted_wire.RunRequest(key:, incarnation:, token:, run:, authority:) ->
      tagged("run", [
        #("key", encode_key(key)),
        #("incarnation", json.Int(incarnation)),
        #("token", encode_bytes(token)),
        #("run", encode_tool_run(run)),
        #("authority", encode_authority(authority)),
      ])
    untrusted_wire.QueryRequest(key:) ->
      tagged("query", [#("key", encode_key(key))])
    untrusted_wire.QueryOrFenceRequest(key:, incarnation:) ->
      tagged("query_or_fence", [
        #("key", encode_key(key)),
        #("incarnation", json.Int(incarnation)),
      ])
    untrusted_wire.ListUnackedRequest(session:) ->
      tagged("list_unacked", [#("session", json.String(session))])
    untrusted_wire.AckRequest(key:) ->
      tagged("ack", [#("key", encode_key(key))])
    untrusted_wire.CloseRequest(session:, workspace:, incarnation:) ->
      tagged("close", [
        #("session", json.String(session)),
        #("workspace", json.String(workspace)),
        #("incarnation", json.Int(incarnation)),
      ])
    untrusted_wire.StateCaptureRequest(
      session:,
      incarnation:,
      token:,
      basis:,
      content:,
    ) ->
      tagged("state_capture", [
        #("session", json.String(session)),
        #("incarnation", json.Int(incarnation)),
        #("token", encode_bytes(token)),
        #("basis", encode_basis(basis)),
        #("content", encode_content(content)),
      ])
    untrusted_wire.StateApplyRequest(session:, incarnation:, token:, state:) ->
      tagged("state_apply", [
        #("session", json.String(session)),
        #("incarnation", json.Int(incarnation)),
        #("token", encode_bytes(token)),
        #("state", encode_state(state)),
      ])
    untrusted_wire.StateChunkRequest(piece:) ->
      tagged("state_chunk", [#("piece", encode_piece(piece))])
    untrusted_wire.StateStatusRequest(hash:) ->
      tagged("state_status", [#("hash", json.String(hash))])
    untrusted_wire.StateFetchRequest(hash:, offset:) ->
      tagged("state_fetch", [
        #("hash", json.String(hash)),
        #("offset", json.Int(offset)),
      ])
    untrusted_wire.BlobStatusRequest(binding:, digest:) ->
      tagged("blob_status", [
        #("binding", encode_bytes(binding)),
        #("digest", json.String(digest)),
      ])
    untrusted_wire.BlobPutRequest(binding:, piece:) ->
      tagged("blob_put", [
        #("binding", encode_bytes(binding)),
        #("piece", encode_blob_piece(piece)),
      ])
    untrusted_wire.OutcomePieceRequest(key:, offset:) ->
      tagged("outcome_piece", [
        #("key", encode_key(key)),
        #("offset", json.Int(offset)),
      ])
  }
}

/// Reads an `attach` request.
fn decode_attach_request(
  fields: Fields,
) -> Result(untrusted_wire.Request, CorruptionReport) {
  use version <- result.try(int_field(fields, "version"))
  use session <- result.try(string_field(fields, "session"))
  use workspace <- result.try(string_field(fields, "workspace"))
  use incarnation <- result.try(int_field(fields, "incarnation"))
  use token <- result.try(field_as(fields, "token", token_of))
  use binding <- result.map(field_as(fields, "binding", binding_of))
  untrusted_wire.AttachRequest(
    version:,
    session:,
    workspace:,
    incarnation:,
    token:,
    binding:,
  )
}

/// Reads a `run` request.
fn decode_run_request(
  fields: Fields,
) -> Result(untrusted_wire.Request, CorruptionReport) {
  use key <- result.try(nested(fields, "key", decode_key))
  use incarnation <- result.try(int_field(fields, "incarnation"))
  use token <- result.try(field_as(fields, "token", token_of))
  use run <- result.try(nested(fields, "run", decode_tool_run))
  use authority <- result.map(nested(fields, "authority", decode_authority))
  untrusted_wire.RunRequest(key:, incarnation:, token:, run:, authority:)
}

/// Reads a `close` request.
fn decode_close_request(
  fields: Fields,
) -> Result(untrusted_wire.Request, CorruptionReport) {
  use session <- result.try(string_field(fields, "session"))
  use workspace <- result.try(string_field(fields, "workspace"))
  use incarnation <- result.map(int_field(fields, "incarnation"))
  untrusted_wire.CloseRequest(session:, workspace:, incarnation:)
}

/// Reads a `state_capture` request.
fn decode_capture_request(
  fields: Fields,
) -> Result(untrusted_wire.Request, CorruptionReport) {
  use session <- result.try(string_field(fields, "session"))
  use incarnation <- result.try(int_field(fields, "incarnation"))
  use token <- result.try(field_as(fields, "token", token_of))
  use basis <- result.try(nested(fields, "basis", decode_basis))
  use content <- result.map(nested(fields, "content", decode_content))
  untrusted_wire.StateCaptureRequest(
    session:,
    incarnation:,
    token:,
    basis:,
    content:,
  )
}

/// Reads a `state_apply` request.
fn decode_apply_request(
  fields: Fields,
) -> Result(untrusted_wire.Request, CorruptionReport) {
  use session <- result.try(string_field(fields, "session"))
  use incarnation <- result.try(int_field(fields, "incarnation"))
  use token <- result.try(field_as(fields, "token", token_of))
  use state <- result.map(nested(fields, "state", decode_state))
  untrusted_wire.StateApplyRequest(session:, incarnation:, token:, state:)
}

// --- responses ---------------------------------------------------------------

/// The tag a response of this kind carries.
fn response_tag(kind: untrusted_wire.ResponseKind) -> String {
  case kind {
    untrusted_wire.AttachKind -> "attach"
    untrusted_wire.RunKind -> "run"
    untrusted_wire.LookupKind -> "lookup"
    untrusted_wire.UnackedKind -> "unacked"
    untrusted_wire.CloseKind -> "close"
    untrusted_wire.CaptureKind -> "capture"
    untrusted_wire.ApplyKind -> "apply"
    untrusted_wire.ChunkKind -> "chunk"
    untrusted_wire.StatusKind -> "status"
    untrusted_wire.FetchKind -> "fetch"
    untrusted_wire.BlobStatusKind -> "blob_status"
    untrusted_wire.BlobPutKind -> "blob_put"
    untrusted_wire.OutcomePieceKind -> "outcome_piece"
  }
}

/// The JSON of a response, tagged with the kind its request expects.
fn encode_response(response: untrusted_wire.Response) -> JsonValue {
  case response {
    untrusted_wire.AttachAnswered(answer:) ->
      tagged(response_tag(untrusted_wire.AttachKind), [
        #("answer", encode_result(answer, encode_attached, encode_refusal)),
      ])
    untrusted_wire.RunAnswered(answer:) ->
      tagged(response_tag(untrusted_wire.RunKind), [
        #("answer", encode_run_answer(answer)),
      ])
    untrusted_wire.LookupAnswered(answer:) ->
      tagged(response_tag(untrusted_wire.LookupKind), [
        #("answer", encode_result(answer, encode_lookup, encode_refusal)),
      ])
    untrusted_wire.UnackedAnswered(answer:) ->
      tagged(response_tag(untrusted_wire.UnackedKind), [
        #("answer", encode_result(answer, encode_unacked, encode_refusal)),
      ])
    untrusted_wire.CloseAnswered(answer:) ->
      tagged(response_tag(untrusted_wire.CloseKind), [
        #("answer", encode_result(answer, encode_close_outcome, encode_refusal)),
      ])
    untrusted_wire.CaptureAnswered(answer:) ->
      tagged(response_tag(untrusted_wire.CaptureKind), [
        #(
          "answer",
          encode_result(
            answer,
            fn(held) { encode_option(held, encode_state) },
            encode_refusal,
          ),
        ),
      ])
    untrusted_wire.ApplyAnswered(answer:) ->
      tagged(response_tag(untrusted_wire.ApplyKind), [
        #("answer", encode_result(answer, json.String, encode_refusal)),
      ])
    untrusted_wire.ChunkAnswered(verdict:) ->
      tagged(response_tag(untrusted_wire.ChunkKind), [
        #("verdict", encode_verdict(verdict)),
      ])
    untrusted_wire.StatusAnswered(answer:) ->
      tagged(response_tag(untrusted_wire.StatusKind), [
        #("answer", encode_result(answer, encode_stage, json.String)),
      ])
    untrusted_wire.FetchAnswered(fetched:) ->
      tagged(response_tag(untrusted_wire.FetchKind), [
        #("fetched", encode_fetched(fetched)),
      ])
    untrusted_wire.BlobStatusAnswered(answer:) ->
      tagged(response_tag(untrusted_wire.BlobStatusKind), [
        #("answer", encode_result(answer, encode_blob_stage, json.String)),
      ])
    untrusted_wire.BlobPutAnswered(verdict:) ->
      tagged(response_tag(untrusted_wire.BlobPutKind), [
        #("verdict", encode_blob_verdict(verdict)),
      ])
    untrusted_wire.OutcomePieceAnswered(piece:) ->
      tagged(response_tag(untrusted_wire.OutcomePieceKind), [
        #("piece", encode_outcome_piece(piece)),
      ])
  }
}

/// The JSON of the reply to an attach: the census, the executor's clock and
/// what it holds unacknowledged.
fn encode_attached(
  attached: protocol.Attached(untrusted_wire.Census),
) -> JsonValue {
  json.Object([
    #("census", encode_census(attached.census)),
    #("executor_now_ms", json.Int(attached.executor_now_ms)),
    #("unacked", encode_unacked(attached.unacked)),
  ])
}

/// Reads the reply to an attach. The executor's clock is a monotonic reading
/// and may be negative, so it is not held to a floor.
fn decode_attached(
  value: JsonValue,
) -> Result(protocol.Attached(untrusted_wire.Census), CorruptionReport) {
  use fields <- result.try(object_of(value, "attached"))
  use census <- result.try(nested(fields, "census", decode_census))
  use executor_now_ms <- result.try(int_field(fields, "executor_now_ms"))
  use unacked <- result.map(nested(fields, "unacked", decode_unacked))
  protocol.Attached(census:, executor_now_ms:, unacked:)
}

/// The JSON of the answer to a run.
fn encode_run_answer(answer: protocol.RunAnswer) -> JsonValue {
  case answer {
    protocol.RunFinished(outcome:) ->
      tagged("finished", [#("outcome", encode_outcome(outcome))])
    protocol.RunLost -> tagged("lost", [])
    protocol.RunRefused(refusal:) ->
      tagged("refused", [#("refusal", encode_refusal(refusal))])
  }
}

/// Reads the answer to a run.
fn decode_run_answer(
  value: JsonValue,
) -> Result(protocol.RunAnswer, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "run answer"))

  // A run ends in an outcome, in a loss the ledger will settle, or in a
  // refusal; the kind says which, and only the first and last carry data.
  case kind {
    "finished" -> {
      use outcome <- result.map(nested(fields, "outcome", decode_outcome))
      protocol.RunFinished(outcome:)
    }
    "lost" -> Ok(protocol.RunLost)
    "refused" -> {
      use refusal <- result.map(nested(fields, "refusal", decode_refusal))
      protocol.RunRefused(refusal:)
    }
    other -> Error(unknown("run answer", other))
  }
}

/// The JSON of the answer to a query.
fn encode_lookup(lookup: protocol.Lookup) -> JsonValue {
  case lookup {
    protocol.Missing -> tagged("missing", [])
    protocol.Admitted -> tagged("admitted", [])
    protocol.Terminal(outcome:) ->
      tagged("terminal", [#("outcome", encode_outcome(outcome))])
    protocol.Unknown -> tagged("unknown", [])
    protocol.Fenced -> tagged("fenced", [])
    protocol.Executed(value:) -> tagged("executed", [#("value", value)])
  }
}

/// Reads the answer to a query.
fn decode_lookup(
  value: JsonValue,
) -> Result(protocol.Lookup, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "lookup"))

  // The kind names how far the call got; only a terminal call carries an
  // outcome and only an executed one carries a program's value.
  case kind {
    "missing" -> Ok(protocol.Missing)
    "admitted" -> Ok(protocol.Admitted)
    "terminal" -> {
      use outcome <- result.map(nested(fields, "outcome", decode_outcome))
      protocol.Terminal(outcome:)
    }
    "unknown" -> Ok(protocol.Unknown)
    "fenced" -> Ok(protocol.Fenced)
    "executed" -> {
      use value <- result.map(field(fields, "value"))
      protocol.Executed(value:)
    }
    other -> Error(unknown("lookup", other))
  }
}

/// The JSON of the keys an executor holds unacknowledged.
fn encode_unacked(unacked: protocol.Unacked) -> JsonValue {
  json.Object([
    #("terminal", encode_list(unacked.terminal, encode_key)),
    #("unknown", encode_list(unacked.unknown, encode_key)),
    #("executions", encode_list(unacked.executions, encode_key)),
  ])
}

/// Reads the keys an executor holds unacknowledged.
fn decode_unacked(
  value: JsonValue,
) -> Result(protocol.Unacked, CorruptionReport) {
  use fields <- result.try(object_of(value, "unacked"))
  use terminal <- result.try(list_field(fields, "terminal", decode_key))
  use unknown <- result.try(list_field(fields, "unknown", decode_key))
  use executions <- result.map(list_field(fields, "executions", decode_key))
  protocol.Unacked(terminal:, unknown:, executions:)
}

/// The JSON of how a close ended.
fn encode_close_outcome(outcome: protocol.CloseOutcome) -> JsonValue {
  case outcome {
    protocol.AllRetired -> tagged("all_retired", [])
    protocol.UnknownCleanup(count:) ->
      tagged("unknown_cleanup", [#("count", json.Int(count))])
  }
}

/// Reads how a close ended.
fn decode_close_outcome(
  value: JsonValue,
) -> Result(protocol.CloseOutcome, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "close outcome"))

  // A close either retired everything or reports how many cleanups it could
  // not account for.
  case kind {
    "all_retired" -> Ok(protocol.AllRetired)
    "unknown_cleanup" -> {
      use count <- result.map(nat_field(fields, "count"))
      protocol.UnknownCleanup(count:)
    }
    other -> Error(unknown("close outcome", other))
  }
}

/// Reads the answer to a capture, which is a state or the absence of one.
fn decode_optional_state(
  value: JsonValue,
) -> Result(Option(state_object.State), CorruptionReport) {
  decode_option(value, decode_state)
}

/// The JSON of a refusal.
fn encode_refusal(refusal: protocol.Refusal) -> JsonValue {
  case refusal {
    protocol.StaleToken -> tagged("stale_token", [])
    protocol.StaleIncarnation(stored:) ->
      tagged("stale_incarnation", [#("stored", json.Int(stored))])
    protocol.ScopeNotOpen -> tagged("scope_not_open", [])
    protocol.ScopeClosing -> tagged("scope_closing", [])
    protocol.UncleanClose(count:) ->
      tagged("unclean_close", [#("count", json.Int(count))])
    protocol.CapacityExhausted(limit:) ->
      tagged("capacity_exhausted", [#("limit", json.Int(limit))])
    protocol.BudgetExhausted(limit:) ->
      tagged("budget_exhausted", [#("limit", json.Int(limit))])
    protocol.VersionMismatch(supported:) ->
      tagged("version_mismatch", [#("supported", json.Int(supported))])
    protocol.WorkspaceMismatch(stored:) ->
      tagged("workspace_mismatch", [#("stored", json.String(stored))])
    protocol.NoSuchScope -> tagged("no_such_scope", [])
    protocol.NoPlane(reason:) ->
      tagged("no_plane", [#("reason", json.String(reason))])
    protocol.PlaneBuilding -> tagged("plane_building", [])
    protocol.WorktreeFailed(reason:) ->
      tagged("worktree_failed", [#("reason", json.String(reason))])
    protocol.UnknownHandle -> tagged("unknown_handle", [])
    protocol.AlreadyPublished -> tagged("already_published", [])
    protocol.StaleGeneration(serving:) ->
      tagged("stale_generation", [#("serving", json.Int(serving))])
    protocol.NoEvolution(reason:) ->
      tagged("no_evolution", [#("reason", json.String(reason))])
    protocol.NoStates(reason:) ->
      tagged("no_states", [#("reason", json.String(reason))])
    protocol.Invalid(reason:) ->
      tagged("invalid", [#("reason", json.String(reason))])
    protocol.ExecutorFault(reason:) ->
      tagged("executor_fault", [#("reason", json.String(reason))])
    protocol.Unreachable(reason:) ->
      tagged("unreachable", [#("reason", json.String(reason))])
  }
}

/// Reads a refusal. The two that name an executor's own failure are free text
/// and every count or limit is held to be non-negative.
fn decode_refusal(
  value: JsonValue,
) -> Result(protocol.Refusal, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "refusal"))

  // The kind names the refusal. Those that carry a number, a stored name or a
  // reason read it, and the rest are told apart by the kind alone.
  case kind {
    "stale_token" -> Ok(protocol.StaleToken)
    "stale_incarnation" -> {
      use stored <- result.map(int_field(fields, "stored"))
      protocol.StaleIncarnation(stored:)
    }
    "scope_not_open" -> Ok(protocol.ScopeNotOpen)
    "scope_closing" -> Ok(protocol.ScopeClosing)
    "unclean_close" -> {
      use count <- result.map(nat_field(fields, "count"))
      protocol.UncleanClose(count:)
    }
    "capacity_exhausted" -> {
      use limit <- result.map(nat_field(fields, "limit"))
      protocol.CapacityExhausted(limit:)
    }
    "budget_exhausted" -> {
      use limit <- result.map(nat_field(fields, "limit"))
      protocol.BudgetExhausted(limit:)
    }
    "version_mismatch" -> {
      use supported <- result.map(int_field(fields, "supported"))
      protocol.VersionMismatch(supported:)
    }
    "workspace_mismatch" -> {
      use stored <- result.map(string_field(fields, "stored"))
      protocol.WorkspaceMismatch(stored:)
    }
    "no_such_scope" -> Ok(protocol.NoSuchScope)
    "no_plane" -> {
      use reason <- result.map(string_field(fields, "reason"))
      protocol.NoPlane(reason:)
    }
    "plane_building" -> Ok(protocol.PlaneBuilding)
    "worktree_failed" -> {
      use reason <- result.map(string_field(fields, "reason"))
      protocol.WorktreeFailed(reason:)
    }
    "unknown_handle" -> Ok(protocol.UnknownHandle)
    "already_published" -> Ok(protocol.AlreadyPublished)
    "stale_generation" -> {
      use serving <- result.map(int_field(fields, "serving"))
      protocol.StaleGeneration(serving:)
    }
    "no_evolution" -> {
      use reason <- result.map(string_field(fields, "reason"))
      protocol.NoEvolution(reason:)
    }
    "no_states" -> {
      use reason <- result.map(string_field(fields, "reason"))
      protocol.NoStates(reason:)
    }
    "invalid" -> {
      use reason <- result.map(string_field(fields, "reason"))
      protocol.Invalid(reason:)
    }
    "executor_fault" -> {
      use reason <- result.map(string_field(fields, "reason"))
      protocol.ExecutorFault(reason:)
    }
    "unreachable" -> {
      use reason <- result.map(string_field(fields, "reason"))
      protocol.Unreachable(reason:)
    }
    other -> Error(unknown("refusal", other))
  }
}

// --- the census ---------------------------------------------------------------

/// The JSON of the executor's census.
fn encode_census(census: untrusted_wire.Census) -> JsonValue {
  json.Object([
    #("census", encode_plane_census(census.census)),
    #("tools", encode_list(census.tools, encode_described)),
    #("prompt", encode_prompt(census.prompt)),
    #("mcp", encode_list(census.mcp, encode_mcp_status)),
    #("branch", encode_option(census.branch, json.String)),
    #("states", encode_states(census.states)),
  ])
}

/// Reads the executor's census.
fn decode_census(
  value: JsonValue,
) -> Result(untrusted_wire.Census, CorruptionReport) {
  use fields <- result.try(object_of(value, "census"))
  use census <- result.try(nested(fields, "census", decode_plane_census))
  use tools <- result.try(list_field(fields, "tools", decode_described))
  use prompt <- result.try(nested(fields, "prompt", decode_prompt))
  use mcp <- result.try(list_field(fields, "mcp", decode_mcp_status))
  use branch <- result.try(option_field(fields, "branch", string_reader))
  use states <- result.map(nested(fields, "states", decode_states))
  untrusted_wire.Census(census:, tools:, prompt:, mcp:, branch:, states:)
}

/// The JSON of the workspace plane's startup census. `extensions` is left out
/// on purpose; the module doc says why.
fn encode_plane_census(census: workspace_plane.Census) -> JsonValue {
  json.Object([
    #("workspace", json.String(census.workspace)),
    #("blob_root", json.String(census.blob_root)),
    #(
      "toolchain",
      encode_result(census.toolchain, encode_toolchain, json.String),
    ),
    #("lsp_servers", encode_list(census.lsp_servers, encode_lsp_server)),
    #(
      "platform",
      json.Object([
        #("os", json.String(census.platform.0)),
        #("architecture", json.String(census.platform.1)),
      ]),
    ),
    #("shell", json.String(census.shell)),
    #("base_policy", encode_sandbox_policy(census.base_policy)),
    #("env", encode_pairs(census.env)),
    #("unset_env", encode_list(census.unset_env, json.String)),
    #("git", json.String(census.git)),
    #("hook_files", encode_list(census.hook_files, encode_hook_file)),
    #("warnings", encode_list(census.warnings, encode_warning)),
  ])
}

/// Reads the workspace plane's startup census, with no extensions.
fn decode_plane_census(
  value: JsonValue,
) -> Result(workspace_plane.Census, CorruptionReport) {
  use fields <- result.try(object_of(value, "plane census"))
  use workspace <- result.try(string_field(fields, "workspace"))
  use blob_root <- result.try(string_field(fields, "blob_root"))
  use toolchain <- result.try(decode_result_field(
    fields,
    "toolchain",
    decode_toolchain,
    string_reader,
  ))
  use lsp_servers <- result.try(list_field(
    fields,
    "lsp_servers",
    decode_lsp_server,
  ))
  use platform <- result.try(nested(fields, "platform", decode_platform))
  use shell <- result.try(string_field(fields, "shell"))
  use base_policy <- result.try(nested(
    fields,
    "base_policy",
    decode_sandbox_policy,
  ))
  use env <- result.try(nested(fields, "env", decode_pairs))
  use unset_env <- result.try(list_field(fields, "unset_env", string_reader))
  use git <- result.try(string_field(fields, "git"))
  use hook_files <- result.try(list_field(
    fields,
    "hook_files",
    decode_hook_file,
  ))
  use warnings <- result.map(list_field(fields, "warnings", decode_warning))
  workspace_plane.Census(
    workspace:,
    blob_root:,
    toolchain:,
    lsp_servers:,
    extensions: [],
    platform:,
    shell:,
    base_policy:,
    env:,
    unset_env:,
    git:,
    hook_files:,
    warnings:,
  )
}

/// Reads the operating system and architecture, in that order.
fn decode_platform(
  value: JsonValue,
) -> Result(#(String, String), CorruptionReport) {
  use fields <- result.try(object_of(value, "platform"))
  use os <- result.try(string_field(fields, "os"))
  use architecture <- result.map(string_field(fields, "architecture"))
  #(os, architecture)
}

/// The JSON of the code-mode toolchain the executor found.
fn encode_toolchain(toolchain: codemode_wiring.Toolchain) -> JsonValue {
  json.Object([
    #("gleam_path", json.String(toolchain.gleam_path)),
    #("erl_path", json.String(toolchain.erl_path)),
    #("seed_root", json.String(toolchain.seed_root)),
    #("gleam_prefix", json.String(toolchain.gleam_prefix)),
    #("erl_prefix", json.String(toolchain.erl_prefix)),
    #("gleam_binary", encode_gleam_binary(toolchain.gleam_binary)),
  ])
}

/// Reads the code-mode toolchain the executor found.
fn decode_toolchain(
  value: JsonValue,
) -> Result(codemode_wiring.Toolchain, CorruptionReport) {
  use fields <- result.try(object_of(value, "toolchain"))
  use gleam_path <- result.try(string_field(fields, "gleam_path"))
  use erl_path <- result.try(string_field(fields, "erl_path"))
  use seed_root <- result.try(string_field(fields, "seed_root"))
  use gleam_prefix <- result.try(string_field(fields, "gleam_prefix"))
  use erl_prefix <- result.try(string_field(fields, "erl_prefix"))
  use gleam_binary <- result.map(nested(
    fields,
    "gleam_binary",
    decode_gleam_binary,
  ))
  codemode_wiring.Toolchain(
    gleam_path:,
    erl_path:,
    seed_root:,
    gleam_prefix:,
    erl_prefix:,
    gleam_binary:,
  )
}

/// The JSON of how the toolchain's `gleam` is installed.
fn encode_gleam_binary(binary: codemode_wiring.GleamBinary) -> JsonValue {
  json.String(case binary {
    codemode_wiring.GleamPlainFile -> "plain_file"
    codemode_wiring.GleamSymlink -> "symlink"
  })
}

/// Reads how the toolchain's `gleam` is installed.
fn decode_gleam_binary(
  value: JsonValue,
) -> Result(codemode_wiring.GleamBinary, CorruptionReport) {
  enum_of(value, "gleam_binary", [
    #("plain_file", codemode_wiring.GleamPlainFile),
    #("symlink", codemode_wiring.GleamSymlink),
  ])
}

/// The JSON of a language server, as the text `client/lsp/profile` writes it.
/// A server is a `gleam_json` value, so it rides as a JSON string.
fn encode_lsp_server(server: profile.LspServer) -> JsonValue {
  json.String(gleam_json.to_string(profile.encode_server(server)))
}

/// Reads a language server from the text `client/lsp/profile` wrote.
fn decode_lsp_server(
  value: JsonValue,
) -> Result(profile.LspServer, CorruptionReport) {
  use text <- result.try(string_of(value, "lsp_server"))
  gleam_json.parse(text, profile.server_decoder())
  |> result.map_error(fn(_not_a_profile) {
    corrupt("lsp_server", "a language server profile", "text that is not one")
  })
}

/// The JSON of the sandbox policy, as the base64 of its msgpack bytes. A policy
/// msgpack cannot encode is written as `null`, which no decoder accepts.
fn encode_sandbox_policy(policy: sandbox_policy.SandboxPolicy) -> JsonValue {
  case sandbox_policy.encode(policy) {
    Ok(bytes) -> encode_bytes(bytes)
    Error(_unencodable) -> json.Null
  }
}

/// Reads the sandbox policy from the base64 of its msgpack bytes.
fn decode_sandbox_policy(
  value: JsonValue,
) -> Result(sandbox_policy.SandboxPolicy, CorruptionReport) {
  use bytes <- result.try(bytes_of(value, "base_policy"))
  sandbox_policy.decode(bytes)
}

/// The JSON of one hook settings file: its path and what was read.
fn encode_hook_file(file: #(String, hookserve.Contents)) -> JsonValue {
  json.Object([
    #("path", json.String(file.0)),
    #("contents", encode_hook_contents(file.1)),
  ])
}

/// Reads one hook settings file.
fn decode_hook_file(
  value: JsonValue,
) -> Result(#(String, hookserve.Contents), CorruptionReport) {
  use fields <- result.try(object_of(value, "hook file"))
  use path <- result.try(string_field(fields, "path"))
  use contents <- result.map(nested(fields, "contents", decode_hook_contents))
  #(path, contents)
}

/// The JSON of what the executor read of a hook settings file.
fn encode_hook_contents(contents: hookserve.Contents) -> JsonValue {
  case contents {
    hookserve.Missing -> tagged("missing", [])
    hookserve.Bytes(bytes) -> tagged("bytes", [#("data", encode_bytes(bytes))])
    hookserve.Unreadable(reason:) ->
      tagged("unreadable", [#("reason", json.String(reason))])
  }
}

/// Reads what the executor read of a hook settings file.
fn decode_hook_contents(
  value: JsonValue,
) -> Result(hookserve.Contents, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "hook contents"))

  // A file was absent, was read as bytes, or could not be read for a reason.
  case kind {
    "missing" -> Ok(hookserve.Missing)
    "bytes" -> {
      use bytes <- result.map(field_as(fields, "data", bytes_of))
      hookserve.Bytes(bytes)
    }
    "unreadable" -> {
      use reason <- result.map(string_field(fields, "reason"))
      hookserve.Unreadable(reason:)
    }
    other -> Error(unknown("hook contents", other))
  }
}

/// The JSON of one startup warning.
fn encode_warning(warning: workspace_plane.Warning) -> JsonValue {
  json.Object([
    #("event", json.String(warning.event)),
    #("fields", encode_pairs(warning.fields)),
  ])
}

/// Reads one startup warning.
fn decode_warning(
  value: JsonValue,
) -> Result(workspace_plane.Warning, CorruptionReport) {
  use fields <- result.try(object_of(value, "warning"))
  use event <- result.try(string_field(fields, "event"))
  use pairs <- result.map(nested(fields, "fields", decode_pairs))
  workspace_plane.Warning(event:, fields: pairs)
}

/// The JSON of one tool the plane offers.
fn encode_described(described: tool.Described) -> JsonValue {
  json.Object([
    #("name", json.String(described.name)),
    #("description", json.String(described.description)),
    #("prompt_snippet", encode_option(described.prompt_snippet, json.String)),
    #("schema", described.schema),
    #("replay", encode_replay_safety(described.replay)),
    #("execution_mode", encode_execution_mode(described.execution_mode)),
  ])
}

/// Reads one tool the plane offers.
fn decode_described(
  value: JsonValue,
) -> Result(tool.Described, CorruptionReport) {
  use fields <- result.try(object_of(value, "tool"))
  use name <- result.try(string_field(fields, "name"))
  use description <- result.try(string_field(fields, "description"))
  use prompt_snippet <- result.try(option_field(
    fields,
    "prompt_snippet",
    string_reader,
  ))
  use schema <- result.try(field(fields, "schema"))
  use replay <- result.try(nested(fields, "replay", decode_replay_safety))
  use execution_mode <- result.map(nested(
    fields,
    "execution_mode",
    decode_execution_mode,
  ))
  tool.Described(
    name:,
    description:,
    prompt_snippet:,
    schema:,
    replay:,
    execution_mode:,
  )
}

/// The JSON of whether a tool may be run again after a crash.
fn encode_replay_safety(replay: tool.ReplaySafety) -> JsonValue {
  json.String(case replay {
    tool.Never -> "never"
    tool.Safe -> "safe"
  })
}

/// Reads whether a tool may be run again after a crash.
fn decode_replay_safety(
  value: JsonValue,
) -> Result(tool.ReplaySafety, CorruptionReport) {
  enum_of(value, "replay", [#("never", tool.Never), #("safe", tool.Safe)])
}

/// The JSON of whether a tool runs beside others.
fn encode_execution_mode(mode: tool.ExecutionMode) -> JsonValue {
  json.String(case mode {
    tool.Exclusive -> "exclusive"
    tool.Concurrent -> "concurrent"
  })
}

/// Reads whether a tool runs beside others.
fn decode_execution_mode(
  value: JsonValue,
) -> Result(tool.ExecutionMode, CorruptionReport) {
  enum_of(value, "execution_mode", [
    #("exclusive", tool.Exclusive),
    #("concurrent", tool.Concurrent),
  ])
}

/// The JSON of the facts the system prompt is rendered from.
fn encode_prompt(prompt: workspace_plane.PromptFacts) -> JsonValue {
  json.Object([
    #("guidance", encode_list(prompt.guidance, encode_guidance)),
    #("guidance_notes", encode_list(prompt.guidance_notes, json.String)),
    #("helper", encode_helper(prompt.helper)),
  ])
}

/// Reads the facts the system prompt is rendered from.
fn decode_prompt(
  value: JsonValue,
) -> Result(workspace_plane.PromptFacts, CorruptionReport) {
  use fields <- result.try(object_of(value, "prompt"))
  use guidance <- result.try(list_field(fields, "guidance", decode_guidance))
  use guidance_notes <- result.try(list_field(
    fields,
    "guidance_notes",
    string_reader,
  ))
  use helper <- result.map(nested(fields, "helper", decode_helper))
  workspace_plane.PromptFacts(guidance:, guidance_notes:, helper:)
}

/// The JSON of one guidance file the executor read.
fn encode_guidance(file: system_prompt.GuidanceFile) -> JsonValue {
  json.Object([
    #("path", json.String(file.path)),
    #("origin", encode_guidance_origin(file.origin)),
    #("text", json.String(file.text)),
  ])
}

/// Reads one guidance file the executor read.
fn decode_guidance(
  value: JsonValue,
) -> Result(system_prompt.GuidanceFile, CorruptionReport) {
  use fields <- result.try(object_of(value, "guidance file"))
  use path <- result.try(string_field(fields, "path"))
  use origin <- result.try(nested(fields, "origin", decode_guidance_origin))
  use text <- result.map(string_field(fields, "text"))
  system_prompt.GuidanceFile(path:, origin:, text:)
}

/// The JSON of where a guidance file came from.
fn encode_guidance_origin(origin: system_prompt.GuidanceOrigin) -> JsonValue {
  json.String(case origin {
    system_prompt.WorkspaceFile -> "workspace_file"
    system_prompt.UserDefaultFile -> "user_default_file"
    system_prompt.ApprovedRule -> "approved_rule"
  })
}

/// Reads where a guidance file came from.
fn decode_guidance_origin(
  value: JsonValue,
) -> Result(system_prompt.GuidanceOrigin, CorruptionReport) {
  enum_of(value, "origin", [
    #("workspace_file", system_prompt.WorkspaceFile),
    #("user_default_file", system_prompt.UserDefaultFile),
    #("approved_rule", system_prompt.ApprovedRule),
  ])
}

/// The JSON of whether the sandbox helper enforces.
fn encode_helper(helper: workspace_plane.HelperHealth) -> JsonValue {
  json.String(case helper {
    workspace_plane.Healthy -> "healthy"
    workspace_plane.Degraded -> "degraded"
  })
}

/// Reads whether the sandbox helper enforces.
fn decode_helper(
  value: JsonValue,
) -> Result(workspace_plane.HelperHealth, CorruptionReport) {
  enum_of(value, "helper", [
    #("healthy", workspace_plane.Healthy),
    #("degraded", workspace_plane.Degraded),
  ])
}

/// The JSON of how an executor-side MCP server started.
fn encode_mcp_status(status: McpStatus) -> JsonValue {
  case status {
    remote_census.McpReady(server:, tools:) ->
      tagged("ready", [
        #("server", json.String(server)),
        #("tools", json.Int(tools)),
      ])
    remote_census.McpRefused(server:, reason:) ->
      tagged("refused", [
        #("server", json.String(server)),
        #("reason", json.String(reason)),
      ])
  }
}

/// Reads how an executor-side MCP server started.
fn decode_mcp_status(value: JsonValue) -> Result(McpStatus, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "mcp status"))

  // A server either started and offers some tools, or was refused for a reason.
  case kind {
    "ready" -> {
      use server <- result.try(string_field(fields, "server"))
      use tools <- result.map(nat_field(fields, "tools"))
      remote_census.McpReady(server:, tools:)
    }
    "refused" -> {
      use server <- result.try(string_field(fields, "server"))
      use reason <- result.map(string_field(fields, "reason"))
      remote_census.McpRefused(server:, reason:)
    }
    other -> Error(unknown("mcp status", other))
  }
}

/// The JSON of whether the plane can move repository states.
fn encode_states(states: StateCensus) -> JsonValue {
  case states {
    remote_census.Moves -> tagged("moves", [])
    remote_census.Stays(reason:) ->
      tagged("stays", [#("reason", json.String(reason))])
  }
}

/// Reads whether the plane can move repository states.
fn decode_states(value: JsonValue) -> Result(StateCensus, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "state census"))

  // The plane either moves states or stays put for a stated reason.
  case kind {
    "moves" -> Ok(remote_census.Moves)
    "stays" -> {
      use reason <- result.map(string_field(fields, "reason"))
      remote_census.Stays(reason:)
    }
    other -> Error(unknown("state census", other))
  }
}

// --- calls, outcomes and authority --------------------------------------------

/// The JSON of a call's key.
fn encode_key(key: protocol.Key) -> JsonValue {
  json.Object([
    #("session", json.String(key.session)),
    #("op", json.String(key.op)),
    #("step", json.String(key.step)),
    #("source_index", json.Int(key.source_index)),
  ])
}

/// Reads a call's key.
fn decode_key(value: JsonValue) -> Result(protocol.Key, CorruptionReport) {
  use fields <- result.try(object_of(value, "key"))
  use session <- result.try(string_field(fields, "session"))
  use op <- result.try(string_field(fields, "op"))
  use step <- result.try(string_field(fields, "step"))
  use source_index <- result.map(nat_field(fields, "source_index"))
  protocol.Key(session:, op:, step:, source_index:)
}

/// The JSON of a tool call as the model made it.
fn encode_tool_call(call: message.ToolCall) -> JsonValue {
  json.Object([
    #("id", json.String(call.id)),
    #("name", json.String(call.name)),
    #("arguments", call.arguments),
    #("thought_signature", encode_option(call.thought_signature, json.String)),
    #("namespace", encode_option(call.namespace, json.String)),
  ])
}

/// Reads a tool call as the model made it.
fn decode_tool_call(
  value: JsonValue,
) -> Result(message.ToolCall, CorruptionReport) {
  use fields <- result.try(object_of(value, "tool call"))
  use id <- result.try(string_field(fields, "id"))
  use name <- result.try(string_field(fields, "name"))
  use arguments <- result.try(field(fields, "arguments"))
  use thought_signature <- result.try(option_field(
    fields,
    "thought_signature",
    string_reader,
  ))
  use namespace <- result.map(option_field(fields, "namespace", string_reader))
  message.ToolCall(id:, name:, arguments:, thought_signature:, namespace:)
}

/// The JSON of one tool call to run.
fn encode_tool_run(run: effects.ToolRun) -> JsonValue {
  json.Object([
    #("operation", json.String(ids.op_id_to_string(run.operation))),
    #("step_id", json.String(run.step_id)),
    #("source_index", json.Int(run.source_index)),
    #("strand", json.String(run.strand)),
    #("call", encode_tool_call(run.call)),
    #("arguments", run.arguments),
    #("replay", encode_replay_policy(run.replay)),
    #("grants", json.Array(run.grants)),
  ])
}

/// Reads one tool call to run.
fn decode_tool_run(
  value: JsonValue,
) -> Result(effects.ToolRun, CorruptionReport) {
  use fields <- result.try(object_of(value, "tool run"))
  use operation <- result.try(field_as(fields, "operation", op_id_of))
  use step_id <- result.try(string_field(fields, "step_id"))
  use source_index <- result.try(nat_field(fields, "source_index"))
  use strand <- result.try(string_field(fields, "strand"))
  use call <- result.try(nested(fields, "call", decode_tool_call))
  use arguments <- result.try(field(fields, "arguments"))
  use replay <- result.try(nested(fields, "replay", decode_replay_policy))
  use grants <- result.map(list_field(fields, "grants", Ok))
  effects.ToolRun(
    operation:,
    step_id:,
    source_index:,
    strand:,
    call:,
    arguments:,
    replay:,
    grants:,
  )
}

/// The JSON of whether a call may be replayed.
fn encode_replay_policy(replay: operation.ReplayPolicy) -> JsonValue {
  json.String(case replay {
    operation.ReplayNever -> "never"
    operation.ReplaySafe -> "safe"
  })
}

/// Reads whether a call may be replayed.
fn decode_replay_policy(
  value: JsonValue,
) -> Result(operation.ReplayPolicy, CorruptionReport) {
  enum_of(value, "replay", [
    #("never", operation.ReplayNever),
    #("safe", operation.ReplaySafe),
  ])
}

/// The JSON of a call's stored authority.
fn encode_authority(authority: wiring.Authority) -> JsonValue {
  json.Object([
    #("access", encode_access(authority.access)),
    #("standing", encode_list(authority.standing, grant_codec.encode)),
  ])
}

/// The JSON of a directory access. `client/directories.encode` writes the
/// array of entries and `client/directories.decode` reads an object that holds
/// that array under `directories`, so the array is wrapped here.
fn encode_access(access: directory_access.Access) -> JsonValue {
  json.Object([#("directories", directories.encode(access))])
}

/// Reads a call's stored authority.
fn decode_authority(
  value: JsonValue,
) -> Result(wiring.Authority, CorruptionReport) {
  use fields <- result.try(object_of(value, "authority"))
  use access <- result.try(nested(fields, "access", directories.decode))
  use standing <- result.map(list_field(fields, "standing", grant_codec.decode))
  wiring.Authority(access:, standing:)
}

/// The JSON of a tool outcome, in the envelope `client/remote/codec` stores.
fn encode_outcome(outcome: effects.ToolOutcome) -> JsonValue {
  case outcome {
    effects.ToolCompleted(result:, terminate:) ->
      tagged("completed", [
        #("result", codec.encode_message(result)),
        #("terminate", json.Bool(terminate)),
      ])
    effects.ToolFailed(reason:) ->
      tagged("failed", [#("reason", json.String(reason))])
  }
}

/// Reads a tool outcome.
fn decode_outcome(
  value: JsonValue,
) -> Result(effects.ToolOutcome, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "outcome"))

  // A tool either completed with a result message or failed with a reason.
  case kind {
    "completed" -> {
      use reply <- result.try(
        field(fields, "result") |> result.try(codec.decode_message),
      )
      use terminate <- result.map(field_as(fields, "terminate", bool_of))
      effects.ToolCompleted(result: reply, terminate:)
    }
    "failed" -> {
      use reason <- result.map(string_field(fields, "reason"))
      effects.ToolFailed(reason:)
    }
    other -> Error(unknown("outcome", other))
  }
}

// --- repository states ----------------------------------------------------------

/// The JSON of a repository state: the text `client/state_object` writes.
fn encode_state(state: state_object.State) -> JsonValue {
  json.String(state_object.encode(state))
}

/// Reads a repository state, which `client/state_object` validates.
fn decode_state(
  value: JsonValue,
) -> Result(state_object.State, CorruptionReport) {
  use text <- result.try(string_of(value, "state"))
  state_object.decode(text)
  |> result.map_error(fn(reason) {
    corrupt("state", "a repository state object", reason)
  })
}

/// The JSON of what a capture may be thin against.
fn encode_basis(basis: state_object.Basis) -> JsonValue {
  case basis {
    state_object.Full -> tagged("full", [])
    state_object.Thin(base:) -> tagged("thin", [#("base", json.String(base))])
  }
}

/// Reads what a capture may be thin against.
fn decode_basis(
  value: JsonValue,
) -> Result(state_object.Basis, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "basis"))

  // A capture is either whole or thin against a named base.
  case kind {
    "full" -> Ok(state_object.Full)
    "thin" -> {
      use base <- result.map(string_field(fields, "base"))
      state_object.Thin(base:)
    }
    other -> Error(unknown("basis", other))
  }
}

/// The JSON of whether a capture reads the working tree.
fn encode_content(content: state_object.Content) -> JsonValue {
  json.String(case content {
    state_object.WithWorkingTree -> "with_working_tree"
    state_object.CommittedOnly -> "committed_only"
  })
}

/// Reads whether a capture reads the working tree.
fn decode_content(
  value: JsonValue,
) -> Result(state_object.Content, CorruptionReport) {
  enum_of(value, "content", [
    #("with_working_tree", state_object.WithWorkingTree),
    #("committed_only", state_object.CommittedOnly),
  ])
}

/// The JSON of one piece of a state.
fn encode_piece(piece: state_transfer.Piece) -> JsonValue {
  json.Object([
    #("state", encode_state(piece.state)),
    #("offset", json.Int(piece.offset)),
    #("bytes", encode_bytes(piece.bytes)),
  ])
}

/// Reads one piece of a state. A piece larger than
/// `untrusted_wire.max_piece_bytes` is refused here, before anything holds it.
fn decode_piece(
  value: JsonValue,
) -> Result(state_transfer.Piece, CorruptionReport) {
  use fields <- result.try(object_of(value, "piece"))
  use state <- result.try(nested(fields, "state", decode_state))
  use offset <- result.try(nat_field(fields, "offset"))
  use bytes <- result.try(field_as(fields, "bytes", piece_bytes_of))
  Ok(state_transfer.Piece(state:, offset:, bytes:))
}

/// Reads the bytes of a piece, at most `untrusted_wire.max_piece_bytes`.
fn piece_bytes_of(
  value: JsonValue,
  on: String,
) -> Result(BitArray, CorruptionReport) {
  use bytes <- result.try(bytes_of(value, on))
  let size = bit_array.byte_size(bytes)

  // A larger piece would not have fit in a frame with its description.
  case size <= untrusted_wire.max_piece_bytes {
    True -> Ok(bytes)
    False ->
      Error(corrupt(
        on,
        "at most " <> int.to_string(untrusted_wire.max_piece_bytes) <> " bytes",
        int.to_string(size) <> " bytes",
      ))
  }
}

/// The JSON of the executor's verdict on a piece.
fn encode_verdict(verdict: state_transfer.Verdict) -> JsonValue {
  case verdict {
    state_transfer.Accepted(held:) ->
      tagged("accepted", [#("held", json.Int(held))])
    state_transfer.Refused(refusal:) ->
      tagged("refused", [#("refusal", encode_transfer_refusal(refusal))])
    state_transfer.Failed(reason:) ->
      tagged("failed", [#("reason", json.String(reason))])
  }
}

/// Reads the executor's verdict on a piece.
fn decode_verdict(
  value: JsonValue,
) -> Result(state_transfer.Verdict, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "verdict"))

  // A piece was taken and the executor now holds some bytes, was refused for a
  // named reason, or the executor failed while keeping it.
  case kind {
    "accepted" -> {
      use held <- result.map(nat_field(fields, "held"))
      state_transfer.Accepted(held:)
    }
    "refused" -> {
      use refusal <- result.map(nested(
        fields,
        "refusal",
        decode_transfer_refusal,
      ))
      state_transfer.Refused(refusal:)
    }
    "failed" -> {
      use reason <- result.map(string_field(fields, "reason"))
      state_transfer.Failed(reason:)
    }
    other -> Error(unknown("verdict", other))
  }
}

/// The JSON of why a piece was refused.
fn encode_transfer_refusal(refusal: state_transfer.Refusal) -> JsonValue {
  case refusal {
    state_transfer.BadState(reason:) ->
      tagged("bad_state", [#("reason", json.String(reason))])
    state_transfer.BadPiece(reason:) ->
      tagged("bad_piece", [#("reason", json.String(reason))])
    state_transfer.TooLarge(limit:) ->
      tagged("too_large", [#("limit", json.Int(limit))])
    state_transfer.NoRoom(reason:) ->
      tagged("no_room", [#("reason", json.String(reason))])
    state_transfer.OutOfOrder(expected:) ->
      tagged("out_of_order", [#("expected", json.Int(expected))])
    state_transfer.Mismatch(reason:) ->
      tagged("mismatch", [#("reason", json.String(reason))])
    state_transfer.NotServing -> tagged("not_serving", [])
  }
}

/// Reads why a piece was refused.
fn decode_transfer_refusal(
  value: JsonValue,
) -> Result(state_transfer.Refusal, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "piece refusal"))

  // The kind names the reason; those that carry a reason or a number read it.
  case kind {
    "bad_state" -> {
      use reason <- result.map(string_field(fields, "reason"))
      state_transfer.BadState(reason:)
    }
    "bad_piece" -> {
      use reason <- result.map(string_field(fields, "reason"))
      state_transfer.BadPiece(reason:)
    }
    "too_large" -> {
      use limit <- result.map(nat_field(fields, "limit"))
      state_transfer.TooLarge(limit:)
    }
    "no_room" -> {
      use reason <- result.map(string_field(fields, "reason"))
      state_transfer.NoRoom(reason:)
    }
    "out_of_order" -> {
      use expected <- result.map(nat_field(fields, "expected"))
      state_transfer.OutOfOrder(expected:)
    }
    "mismatch" -> {
      use reason <- result.map(string_field(fields, "reason"))
      state_transfer.Mismatch(reason:)
    }
    "not_serving" -> Ok(state_transfer.NotServing)
    other -> Error(unknown("piece refusal", other))
  }
}

/// The JSON of how much of a state the executor holds.
fn encode_stage(stage: state_transfer.Stage) -> JsonValue {
  case stage {
    state_transfer.Absent -> tagged("absent", [])
    state_transfer.Partial(held:) ->
      tagged("partial", [#("held", json.Int(held))])
    state_transfer.Complete -> tagged("complete", [])
  }
}

/// Reads how much of a state the executor holds.
fn decode_stage(
  value: JsonValue,
) -> Result(state_transfer.Stage, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "stage"))

  // The executor holds none of a state, some bytes of it, or all of it.
  case kind {
    "absent" -> Ok(state_transfer.Absent)
    "partial" -> {
      use held <- result.map(nat_field(fields, "held"))
      state_transfer.Partial(held:)
    }
    "complete" -> Ok(state_transfer.Complete)
    other -> Error(unknown("stage", other))
  }
}

/// The JSON of the executor's answer to a fetch.
fn encode_fetched(fetched: state_transfer.Fetched) -> JsonValue {
  case fetched {
    state_transfer.Served(piece:) ->
      tagged("served", [#("piece", encode_piece(piece))])
    state_transfer.NotHeld -> tagged("not_held", [])
    state_transfer.FetchFailed(reason:) ->
      tagged("fetch_failed", [#("reason", json.String(reason))])
  }
}

/// Reads the executor's answer to a fetch.
fn decode_fetched(
  value: JsonValue,
) -> Result(state_transfer.Fetched, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "fetched"))

  // The executor served a piece, holds no such state, or failed reading it.
  case kind {
    "served" -> {
      use piece <- result.map(nested(fields, "piece", decode_piece))
      state_transfer.Served(piece:)
    }
    "not_held" -> Ok(state_transfer.NotHeld)
    "fetch_failed" -> {
      use reason <- result.map(string_field(fields, "reason"))
      state_transfer.FetchFailed(reason:)
    }
    other -> Error(unknown("fetched", other))
  }
}

// --- placed blobs and outcome pieces ---------------------------------------------

/// The JSON of one piece of a blob.
fn encode_blob_piece(piece: blob_transfer.Piece) -> JsonValue {
  json.Object([
    #("digest", json.String(piece.blob.digest)),
    #("size", json.Int(piece.blob.size)),
    #("offset", json.Int(piece.offset)),
    #("bytes", encode_bytes(piece.bytes)),
  ])
}

/// Reads one piece of a blob. The digest must be one, and the bytes at most
/// `untrusted_wire.max_piece_bytes`; the size and the offset are judged
/// against each other by the receiver.
fn decode_blob_piece(
  value: JsonValue,
) -> Result(blob_transfer.Piece, CorruptionReport) {
  use fields <- result.try(object_of(value, "blob piece"))
  use digest <- result.try(field_as(fields, "digest", digest_of))
  use size <- result.try(nat_field(fields, "size"))
  use offset <- result.try(nat_field(fields, "offset"))
  use bytes <- result.map(field_as(fields, "bytes", piece_bytes_of))
  blob_transfer.Piece(blob: blob_transfer.Blob(digest:, size:), offset:, bytes:)
}

/// The JSON of the executor's verdict on a blob piece.
fn encode_blob_verdict(verdict: blob_transfer.Verdict) -> JsonValue {
  case verdict {
    blob_transfer.Accepted(held:) ->
      tagged("accepted", [#("held", json.Int(held))])
    blob_transfer.Stored -> tagged("stored", [])
    blob_transfer.OutOfOrder(expected:) ->
      tagged("out_of_order", [#("expected", json.Int(expected))])
    blob_transfer.Refused(reason:) ->
      tagged("refused", [#("reason", json.String(reason))])
    blob_transfer.Failed(reason:) ->
      tagged("failed", [#("reason", json.String(reason))])
  }
}

/// Reads the executor's verdict on a blob piece.
fn decode_blob_verdict(
  value: JsonValue,
) -> Result(blob_transfer.Verdict, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "blob verdict"))

  // The piece is held, the blob is whole, the executor stands elsewhere, or it
  // said no, finally or for now.
  case kind {
    "accepted" -> {
      use held <- result.map(nat_field(fields, "held"))
      blob_transfer.Accepted(held:)
    }
    "stored" -> Ok(blob_transfer.Stored)
    "out_of_order" -> {
      use expected <- result.map(nat_field(fields, "expected"))
      blob_transfer.OutOfOrder(expected:)
    }
    "refused" -> {
      use reason <- result.map(string_field(fields, "reason"))
      blob_transfer.Refused(reason:)
    }
    "failed" -> {
      use reason <- result.map(string_field(fields, "reason"))
      blob_transfer.Failed(reason:)
    }
    other -> Error(unknown("blob verdict", other))
  }
}

/// The JSON of how much of a blob the executor holds.
fn encode_blob_stage(stage: blob_transfer.Stage) -> JsonValue {
  case stage {
    blob_transfer.Absent -> tagged("absent", [])
    blob_transfer.Partial(held:) ->
      tagged("partial", [#("held", json.Int(held))])
    blob_transfer.Complete -> tagged("complete", [])
  }
}

/// Reads how much of a blob the executor holds.
fn decode_blob_stage(
  value: JsonValue,
) -> Result(blob_transfer.Stage, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "blob stage"))

  // The executor holds none of a blob, some bytes of it, or all of it.
  case kind {
    "absent" -> Ok(blob_transfer.Absent)
    "partial" -> {
      use held <- result.map(nat_field(fields, "held"))
      blob_transfer.Partial(held:)
    }
    "complete" -> Ok(blob_transfer.Complete)
    other -> Error(unknown("blob stage", other))
  }
}

/// The JSON of one piece of an encoded outcome, or why there is none.
fn encode_outcome_piece(piece: untrusted_wire.OutcomePiece) -> JsonValue {
  case piece {
    untrusted_wire.OutcomeServed(size:, digest:, offset:, bytes:) ->
      tagged("served", [
        #("size", json.Int(size)),
        #("digest", json.String(digest)),
        #("offset", json.Int(offset)),
        #("bytes", encode_bytes(bytes)),
      ])
    untrusted_wire.OutcomeNotHeld(reason:) ->
      tagged("not_held", [#("reason", json.String(reason))])
  }
}

/// Reads one piece of an encoded outcome.
fn decode_outcome_piece(
  value: JsonValue,
) -> Result(untrusted_wire.OutcomePiece, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "outcome piece"))

  // The executor served the bytes at an offset, or holds no ended outcome.
  case kind {
    "served" -> {
      use size <- result.try(nat_field(fields, "size"))
      use digest <- result.try(field_as(fields, "digest", digest_of))
      use offset <- result.try(nat_field(fields, "offset"))
      use bytes <- result.map(field_as(fields, "bytes", piece_bytes_of))
      untrusted_wire.OutcomeServed(size:, digest:, offset:, bytes:)
    }
    "not_held" -> {
      use reason <- result.map(string_field(fields, "reason"))
      untrusted_wire.OutcomeNotHeld(reason:)
    }
    other -> Error(unknown("outcome piece", other))
  }
}

/// Reads a blob's or an outcome's digest: 64 lower-case hex digits, which is
/// the only text that may ever become a file name.
fn digest_of(value: JsonValue, on: String) -> Result(String, CorruptionReport) {
  use text <- result.try(string_of(value, on))

  // Anything else is not a SHA-256 in the one spelling the wire allows.
  case blob_transfer.is_digest(text) {
    True -> Ok(text)
    False -> Error(corrupt(on, "64 lower-case hexadecimal digits", text))
  }
}

// --- callbacks ------------------------------------------------------------------

/// The JSON of an owner request.
fn encode_callback(callback: untrusted_wire.Callback) -> JsonValue {
  case callback {
    untrusted_wire.EscalateCall(refused:, remaining_ms:) ->
      tagged("escalate", [
        #("refused", encode_refused(refused)),
        #("remaining_ms", json.Int(remaining_ms)),
      ])
    untrusted_wire.FactGetCall(key:) ->
      tagged("fact_get", [#("key", json.String(key))])
    untrusted_wire.FactPutCall(key:, value:, expected:) ->
      tagged("fact_put", [
        #("key", json.String(key)),
        #("value", value),
        #("expected", encode_option(expected, json.Int)),
      ])
    untrusted_wire.FactPutBlindCall(key:, value:) ->
      tagged("fact_put_blind", [#("key", json.String(key)), #("value", value)])
    untrusted_wire.FactDeleteCall(key:) ->
      tagged("fact_delete", [#("key", json.String(key))])
    untrusted_wire.FactListCall(prefix:) ->
      tagged("fact_list", [#("prefix", json.String(prefix))])
    untrusted_wire.NotifyCall(strand:, work:, text:) ->
      tagged("notify", [
        #("strand", json.String(strand)),
        #("work", encode_work(work)),
        #("text", json.String(text)),
      ])
    untrusted_wire.StrandActivityCall(strand:) ->
      tagged("strand_activity", [#("strand", json.String(strand))])
    untrusted_wire.WakeCall(strand:, text:) ->
      tagged("wake", [
        #("strand", json.String(strand)),
        #("text", json.String(text)),
      ])
    untrusted_wire.HoldsCall(caller:, tool: named) ->
      tagged("holds", [
        #("caller", encode_caller(caller)),
        #("tool", json.String(named)),
      ])
    untrusted_wire.TailCast(run:, tail:) ->
      tagged("tail", [
        #("run", encode_tool_run(run)),
        #("tail", encode_output_tail(tail)),
      ])
    untrusted_wire.CapabilityCall(call:) ->
      tagged("capability", [#("call", encode_cap_call(call))])
    untrusted_wire.McpPlanCall -> tagged("mcp_plan", [])
    untrusted_wire.GitIdentityCall -> tagged("git_identity", [])
  }
}

/// Reads a `fact_put` callback, whose expected sequence may be absent.
fn decode_fact_put_call(
  fields: Fields,
) -> Result(untrusted_wire.Callback, CorruptionReport) {
  use key <- result.try(string_field(fields, "key"))
  use value <- result.try(field(fields, "value"))
  use expected <- result.map(option_field(fields, "expected", nat_reader))
  untrusted_wire.FactPutCall(key:, value:, expected:)
}

/// Reads a `notify` callback.
fn decode_notify_call(
  fields: Fields,
) -> Result(untrusted_wire.Callback, CorruptionReport) {
  use strand <- result.try(string_field(fields, "strand"))
  use work <- result.try(nested(fields, "work", decode_work))
  use text <- result.map(string_field(fields, "text"))
  untrusted_wire.NotifyCall(strand:, work:, text:)
}

/// The JSON of an escalation the plane could not settle itself.
fn encode_refused(refused: escalate.Refused) -> JsonValue {
  json.Object([
    #("operation", json.String(ids.op_id_to_string(refused.operation))),
    #("strand", json.String(refused.strand)),
    #("step_id", json.String(refused.step_id)),
    #("source_index", json.Int(refused.source_index)),
    #("call_id", json.String(refused.call_id)),
    #("tool", json.String(refused.tool)),
    #(
      "denial",
      grant_codec.encode_denial(
        reason: refused.denial.reason,
        source: refused.denial.source,
        wanted: refused.denial.wanted,
      ),
    ),
    #("arguments", refused.arguments),
    #("deadline_ms", json.Int(refused.deadline_ms)),
  ])
}

/// Reads an escalation. The deadline is on the executor's monotonic clock, so
/// it is not held to a floor.
fn decode_refused(
  value: JsonValue,
) -> Result(escalate.Refused, CorruptionReport) {
  use fields <- result.try(object_of(value, "escalation"))
  use operation <- result.try(field_as(fields, "operation", op_id_of))
  use strand <- result.try(string_field(fields, "strand"))
  use step_id <- result.try(string_field(fields, "step_id"))
  use source_index <- result.try(nat_field(fields, "source_index"))
  use call_id <- result.try(string_field(fields, "call_id"))
  use named <- result.try(string_field(fields, "tool"))
  use denial <- result.try(nested(fields, "denial", decode_denial))
  use arguments <- result.try(field(fields, "arguments"))
  use deadline_ms <- result.map(int_field(fields, "deadline_ms"))
  escalate.Refused(
    operation:,
    strand:,
    step_id:,
    source_index:,
    call_id:,
    tool: named,
    denial:,
    arguments:,
    deadline_ms:,
  )
}

/// Reads an escalation's denial through `client/grants`.
fn decode_denial(
  value: JsonValue,
) -> Result(escalation.Denial, CorruptionReport) {
  use decoded <- result.map(grant_codec.decode_denial(value))
  escalation.Denial(
    reason: decoded.reason,
    source: decoded.source,
    wanted: decoded.wanted,
  )
}

/// The JSON of the work a notice is about.
fn encode_work(work: notice.Work) -> JsonValue {
  case work {
    notice.Job(id:) -> tagged("job", [#("id", json.String(id))])
    notice.Execution(id:) -> tagged("execution", [#("id", json.String(id))])
    notice.Escalation(id:, seq:) ->
      tagged("escalation", [#("id", json.String(id)), #("seq", json.Int(seq))])
  }
}

/// Reads the work a notice is about.
fn decode_work(value: JsonValue) -> Result(notice.Work, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "work"))

  // A notice is about a background job, a program execution, or an escalation.
  case kind {
    "job" -> {
      use id <- result.map(string_field(fields, "id"))
      notice.Job(id:)
    }
    "execution" -> {
      use id <- result.map(string_field(fields, "id"))
      notice.Execution(id:)
    }
    "escalation" -> {
      use id <- result.try(string_field(fields, "id"))
      use seq <- result.map(nat_field(fields, "seq"))
      notice.Escalation(id:, seq:)
    }
    other -> Error(unknown("work", other))
  }
}

/// The JSON of who asks whether a tool is held.
fn encode_caller(caller: agent.Caller) -> JsonValue {
  json.Object([
    #("strand", json.String(caller.strand)),
    #("operation", json.String(ids.op_id_to_string(caller.operation))),
    #("step_id", json.String(caller.step_id)),
    #("source_index", json.Int(caller.source_index)),
    #("minter", encode_minter(caller.minter)),
  ])
}

/// Reads who asks whether a tool is held.
fn decode_caller(value: JsonValue) -> Result(agent.Caller, CorruptionReport) {
  use fields <- result.try(object_of(value, "caller"))
  use strand <- result.try(string_field(fields, "strand"))
  use operation <- result.try(field_as(fields, "operation", op_id_of))
  use step_id <- result.try(string_field(fields, "step_id"))
  use source_index <- result.try(nat_field(fields, "source_index"))
  use minter <- result.map(nested(fields, "minter", decode_minter))
  agent.Caller(strand:, operation:, step_id:, source_index:, minter:)
}

/// The JSON of what minted a caller's call.
fn encode_minter(minter: agent.Minter) -> JsonValue {
  case minter {
    agent.ToolCall -> tagged("tool_call", [])
    agent.Program(ordinal:) ->
      tagged("program", [#("ordinal", json.Int(ordinal))])
  }
}

/// Reads what minted a caller's call.
fn decode_minter(value: JsonValue) -> Result(agent.Minter, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "minter"))

  // A call was minted by the model's tool call or by an ordinal of a program.
  case kind {
    "tool_call" -> Ok(agent.ToolCall)
    "program" -> {
      use ordinal <- result.map(nat_field(fields, "ordinal"))
      agent.Program(ordinal:)
    }
    other -> Error(unknown("minter", other))
  }
}

/// The JSON of the tail of a running call's output.
fn encode_output_tail(tail: tool.OutputTail) -> JsonValue {
  json.Object([
    #("stream", encode_output_stream(tail.stream)),
    #("tail", json.String(tail.tail)),
    #("total_bytes", json.Int(tail.total_bytes)),
  ])
}

/// Reads the tail of a running call's output.
fn decode_output_tail(
  value: JsonValue,
) -> Result(tool.OutputTail, CorruptionReport) {
  use fields <- result.try(object_of(value, "output tail"))
  use stream <- result.try(nested(fields, "stream", decode_output_stream))
  use tail <- result.try(string_field(fields, "tail"))
  use total_bytes <- result.map(nat_field(fields, "total_bytes"))
  tool.OutputTail(stream:, tail:, total_bytes:)
}

/// The JSON of which stream an output tail came from.
fn encode_output_stream(stream: framing.OutputStream) -> JsonValue {
  json.String(case stream {
    framing.Stdout -> "stdout"
    framing.Stderr -> "stderr"
  })
}

/// Reads which stream an output tail came from.
fn decode_output_stream(
  value: JsonValue,
) -> Result(framing.OutputStream, CorruptionReport) {
  enum_of(value, "stream", [
    #("stdout", framing.Stdout),
    #("stderr", framing.Stderr),
  ])
}

/// The JSON of a capability call owned by the session.
fn encode_cap_call(call: owner_services.OwnerCapCall) -> JsonValue {
  json.Object([
    #("strand", json.String(call.strand)),
    #("op_id", json.String(ids.op_id_to_string(call.op_id))),
    #("step_id", json.String(call.step_id)),
    #("source_index", json.Int(call.source_index)),
    #("seam", encode_seam(call.seam)),
    #("cap", json.String(call.cap)),
    #("args", encode_msgpack(call.args)),
    #("ordinal", json.Int(call.ordinal)),
  ])
}

/// Reads a capability call owned by the session.
fn decode_cap_call(
  value: JsonValue,
) -> Result(owner_services.OwnerCapCall, CorruptionReport) {
  use fields <- result.try(object_of(value, "capability call"))
  use strand <- result.try(string_field(fields, "strand"))
  use op_id <- result.try(field_as(fields, "op_id", op_id_of))
  use step_id <- result.try(string_field(fields, "step_id"))
  use source_index <- result.try(nat_field(fields, "source_index"))
  use seam <- result.try(nested(fields, "seam", decode_seam))
  use cap <- result.try(string_field(fields, "cap"))
  use args <- result.try(field_as(fields, "args", msgpack_of))
  use ordinal <- result.map(nat_field(fields, "ordinal"))
  owner_services.OwnerCapCall(
    strand:,
    op_id:,
    step_id:,
    source_index:,
    seam:,
    cap:,
    args:,
    ordinal:,
  )
}

/// The JSON of which seam a capability call came through.
fn encode_seam(seam: vet_policy.Seam) -> JsonValue {
  json.String(case seam {
    vet_policy.WorkspaceSeam -> "workspace"
    vet_policy.OrchestrationSeam -> "orchestration"
    vet_policy.ExtensionSeam -> "extension"
    vet_policy.ResidentSeam -> "resident"
  })
}

/// Reads which seam a capability call came through.
fn decode_seam(value: JsonValue) -> Result(vet_policy.Seam, CorruptionReport) {
  enum_of(value, "seam", [
    #("workspace", vet_policy.WorkspaceSeam),
    #("orchestration", vet_policy.OrchestrationSeam),
    #("extension", vet_policy.ExtensionSeam),
    #("resident", vet_policy.ResidentSeam),
  ])
}

// --- answers --------------------------------------------------------------------

/// The tag an answer of this kind carries.
fn answer_tag(kind: untrusted_wire.AnswerKind) -> String {
  case kind {
    untrusted_wire.DecidedKind -> "decided"
    untrusted_wire.FactCellKind -> "fact_cell"
    untrusted_wire.FactSeqKind -> "fact_seq"
    untrusted_wire.FactDoneKind -> "fact_done"
    untrusted_wire.FactListKind -> "fact_list"
    untrusted_wire.NotifyKind -> "notify"
    untrusted_wire.ActivityKind -> "activity"
    untrusted_wire.WakeKind -> "wake"
    untrusted_wire.HoldsKind -> "holds"
    untrusted_wire.CapabilityKind -> "capability"
    untrusted_wire.McpPlanKind -> "mcp_plan"
    untrusted_wire.GitIdentityKind -> "git_identity"
  }
}

/// The JSON of an owner's answer, tagged with the kind its callback expects.
fn encode_answer(answer: untrusted_wire.Answer) -> JsonValue {
  case answer {
    untrusted_wire.Decided(decision:) ->
      tagged(answer_tag(untrusted_wire.DecidedKind), [
        #("decision", encode_decision(decision)),
      ])
    untrusted_wire.FactCellAnswered(answer:) ->
      tagged(answer_tag(untrusted_wire.FactCellKind), [
        #(
          "answer",
          encode_result(
            answer,
            fn(cell) { encode_option(cell, encode_fact_cell) },
            encode_fact_fault,
          ),
        ),
      ])
    untrusted_wire.FactSeqAnswered(answer:) ->
      tagged(answer_tag(untrusted_wire.FactSeqKind), [
        #("answer", encode_result(answer, json.Int, encode_fact_fault)),
      ])
    untrusted_wire.FactDoneAnswered(answer:) ->
      tagged(answer_tag(untrusted_wire.FactDoneKind), [
        #("answer", encode_result(answer, encode_nil, encode_fact_fault)),
      ])
    untrusted_wire.FactListAnswered(answer:) ->
      tagged(answer_tag(untrusted_wire.FactListKind), [
        #(
          "answer",
          encode_result(
            answer,
            fn(entries) { encode_list(entries, encode_fact_entry) },
            encode_fact_fault,
          ),
        ),
      ])
    untrusted_wire.NotifyAnswered(answer:) ->
      tagged(answer_tag(untrusted_wire.NotifyKind), [
        #("answer", encode_result(answer, encode_delivered, json.String)),
      ])
    untrusted_wire.ActivityAnswered(answer:) ->
      tagged(answer_tag(untrusted_wire.ActivityKind), [
        #("answer", encode_result(answer, encode_activity, json.String)),
      ])
    untrusted_wire.WakeAnswered(answer:) ->
      tagged(answer_tag(untrusted_wire.WakeKind), [
        #("answer", encode_result(answer, encode_nil, json.String)),
      ])
    untrusted_wire.HoldsAnswered(answer:) ->
      tagged(answer_tag(untrusted_wire.HoldsKind), [
        #("answer", encode_result(answer, encode_nil, encode_agent_refusal)),
      ])
    untrusted_wire.CapabilityAnswered(answer:) ->
      tagged(answer_tag(untrusted_wire.CapabilityKind), [
        #(
          "answer",
          encode_result(answer, encode_cap_outcome, encode_cap_denial),
        ),
      ])
    untrusted_wire.McpPlanAnswered(plan:) ->
      tagged(answer_tag(untrusted_wire.McpPlanKind), [
        #("plan", encode_mcp_plan(plan)),
      ])
    untrusted_wire.GitIdentityAnswered(identity:) ->
      tagged(answer_tag(untrusted_wire.GitIdentityKind), [
        #("identity", encode_option(identity, encode_git_identity)),
      ])
  }
}

/// The JSON of the operator's decision on an escalation.
fn encode_decision(decision: escalate.Decision) -> JsonValue {
  case decision {
    escalate.Settle -> tagged("settle", [])
    escalate.Resume(grants:) ->
      tagged("resume", [#("grants", encode_list(grants, grant_codec.encode))])
  }
}

/// Reads the operator's decision on an escalation.
fn decode_decision(
  value: JsonValue,
) -> Result(escalate.Decision, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "decision"))

  // The operator refused, so the call settles, or approved grants and the call
  // resumes under them.
  case kind {
    "settle" -> Ok(escalate.Settle)
    "resume" -> {
      use grants <- result.map(list_field(fields, "grants", grant_codec.decode))
      escalate.Resume(grants:)
    }
    other -> Error(unknown("decision", other))
  }
}

/// The JSON of a fact cell: its value and sequence.
fn encode_fact_cell(cell: api.FactCell) -> JsonValue {
  json.Object([#("value", cell.value), #("seq", json.Int(cell.seq))])
}

/// Reads a fact cell.
fn decode_fact_cell(
  value: JsonValue,
) -> Result(Option(api.FactCell), CorruptionReport) {
  decode_option(value, fn(inner) {
    use fields <- result.try(object_of(inner, "fact cell"))
    use stored <- result.try(field(fields, "value"))
    use seq <- result.map(nat_field(fields, "seq"))
    api.FactCell(value: stored, seq:)
  })
}

/// The JSON of one key and value of a fact listing.
fn encode_fact_entry(entry: #(String, JsonValue)) -> JsonValue {
  json.Object([#("key", json.String(entry.0)), #("value", entry.1)])
}

/// Reads a fact listing.
fn decode_fact_entries(
  value: JsonValue,
) -> Result(List(#(String, JsonValue)), CorruptionReport) {
  use items <- result.try(array_of(value, "ok"))
  list.try_map(items, fn(item) {
    use fields <- result.try(object_of(item, "fact entry"))
    use key <- result.try(string_field(fields, "key"))
    use stored <- result.map(field(fields, "value"))
    #(key, stored)
  })
}

/// The JSON of why a fact call failed.
fn encode_fact_fault(fault: owner_services.FactFault) -> JsonValue {
  case fault {
    owner_services.StoreAbsent -> tagged("store_absent", [])
    owner_services.Conflict -> tagged("conflict", [])
    owner_services.LeaseStolen(held_by:) ->
      tagged("lease_stolen", [
        #("held_by", encode_option(held_by, json.String)),
      ])
    owner_services.Failed(detail:) ->
      tagged("failed", [#("detail", json.String(detail))])
    owner_services.NotServed(key:) ->
      tagged("not_served", [#("key", json.String(key))])
  }
}

/// Reads why a fact call failed.
fn decode_fact_fault(
  value: JsonValue,
) -> Result(owner_services.FactFault, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "fact fault"))

  // The kind names the fault; some carry the holder, a detail or the key.
  case kind {
    "store_absent" -> Ok(owner_services.StoreAbsent)
    "conflict" -> Ok(owner_services.Conflict)
    "lease_stolen" -> {
      use held_by <- result.map(option_field(fields, "held_by", string_reader))
      owner_services.LeaseStolen(held_by:)
    }
    "failed" -> {
      use detail <- result.map(string_field(fields, "detail"))
      owner_services.Failed(detail:)
    }
    "not_served" -> {
      use key <- result.map(string_field(fields, "key"))
      owner_services.NotServed(key:)
    }
    other -> Error(unknown("fact fault", other))
  }
}

/// The JSON of whether a notice was delivered.
fn encode_delivered(delivered: notice.Delivered) -> JsonValue {
  json.String(case delivered {
    notice.Delivered -> "delivered"
    notice.AlreadyDelivered -> "already_delivered"
    notice.Withheld -> "withheld"
  })
}

/// Reads whether a notice was delivered.
fn decode_delivered(
  value: JsonValue,
) -> Result(notice.Delivered, CorruptionReport) {
  enum_of(value, "ok", [
    #("delivered", notice.Delivered),
    #("already_delivered", notice.AlreadyDelivered),
    #("withheld", notice.Withheld),
  ])
}

/// The JSON of whether a strand is busy.
fn encode_activity(activity: notice.Activity) -> JsonValue {
  json.String(case activity {
    notice.Busy -> "busy"
    notice.Idle -> "idle"
  })
}

/// Reads whether a strand is busy.
fn decode_activity(
  value: JsonValue,
) -> Result(notice.Activity, CorruptionReport) {
  enum_of(value, "ok", [#("busy", notice.Busy), #("idle", notice.Idle)])
}

/// The JSON of why a tool is not held. `ResultSchemaUnmet` carries a schema, a
/// received value and a mismatch with no codec, so it is carried as
/// `PlaneFailed`; the module doc says why that loses nothing in practice.
fn encode_agent_refusal(refusal: agent.Refusal) -> JsonValue {
  case refusal {
    agent.AgencyUnavailable -> tagged("agency_unavailable", [])
    agent.MalformedHandle(text:) ->
      tagged("malformed_handle", [#("text", json.String(text))])
    agent.NotAddressable(strand:) ->
      tagged("not_addressable", [#("strand", json.String(strand))])
    agent.NotADescendant(strand:) ->
      tagged("not_a_descendant", [#("strand", json.String(strand))])
    agent.DepthCapReached(depth:) ->
      tagged("depth_cap_reached", [#("depth", json.Int(depth))])
    agent.FanOutCapReached(live:, cap:) ->
      tagged("fan_out_cap_reached", [
        #("live", json.Int(live)),
        #("cap", json.Int(cap)),
      ])
    agent.UnknownTool(name:) ->
      tagged("unknown_tool", [#("name", json.String(name))])
    agent.InvalidArgument(reason:) ->
      tagged("invalid_argument", [#("reason", json.String(reason))])
    agent.ParentRunEnded(strand:) ->
      tagged("parent_run_ended", [#("strand", json.String(strand))])
    agent.ResultSchemaUnmet(..) ->
      encode_agent_refusal(agent.PlaneFailed("result schema unmet"))
    agent.NameAlreadyMinted(strand:) ->
      tagged("name_already_minted", [#("strand", json.String(strand))])
    agent.ToolNotHeld(tool: named) ->
      tagged("tool_not_held", [#("tool", json.String(named))])
    agent.RemoteRefused(orchestrator:, reason:) ->
      tagged("remote_refused", [
        #("orchestrator", json.String(orchestrator)),
        #("reason", json.String(reason)),
      ])
    agent.RemoteSilent(orchestrator:) ->
      tagged("remote_silent", [#("orchestrator", json.String(orchestrator))])
    agent.PlaneFailed(reason:) ->
      tagged("plane_failed", [#("reason", json.String(reason))])
  }
}

/// Reads why a tool is not held.
fn decode_agent_refusal(
  value: JsonValue,
) -> Result(agent.Refusal, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "agent refusal"))

  // The kind names the refusal; the arms read the one field each carries.
  case kind {
    "agency_unavailable" -> Ok(agent.AgencyUnavailable)
    "malformed_handle" -> {
      use text <- result.map(string_field(fields, "text"))
      agent.MalformedHandle(text:)
    }
    "not_addressable" -> {
      use strand <- result.map(string_field(fields, "strand"))
      agent.NotAddressable(strand:)
    }
    "not_a_descendant" -> {
      use strand <- result.map(string_field(fields, "strand"))
      agent.NotADescendant(strand:)
    }
    "depth_cap_reached" -> {
      use depth <- result.map(nat_field(fields, "depth"))
      agent.DepthCapReached(depth:)
    }
    "fan_out_cap_reached" -> {
      use live <- result.try(nat_field(fields, "live"))
      use cap <- result.map(nat_field(fields, "cap"))
      agent.FanOutCapReached(live:, cap:)
    }
    "unknown_tool" -> {
      use name <- result.map(string_field(fields, "name"))
      agent.UnknownTool(name:)
    }
    "invalid_argument" -> {
      use reason <- result.map(string_field(fields, "reason"))
      agent.InvalidArgument(reason:)
    }
    "parent_run_ended" -> {
      use strand <- result.map(string_field(fields, "strand"))
      agent.ParentRunEnded(strand:)
    }
    "name_already_minted" -> {
      use strand <- result.map(string_field(fields, "strand"))
      agent.NameAlreadyMinted(strand:)
    }
    "tool_not_held" -> {
      use named <- result.map(string_field(fields, "tool"))
      agent.ToolNotHeld(tool: named)
    }
    "remote_refused" -> {
      use orchestrator <- result.try(string_field(fields, "orchestrator"))
      use reason <- result.map(string_field(fields, "reason"))
      agent.RemoteRefused(orchestrator:, reason:)
    }
    "remote_silent" -> {
      use orchestrator <- result.map(string_field(fields, "orchestrator"))
      agent.RemoteSilent(orchestrator:)
    }
    "plane_failed" -> {
      use reason <- result.map(string_field(fields, "reason"))
      agent.PlaneFailed(reason:)
    }
    other -> Error(unknown("agent refusal", other))
  }
}

/// The JSON of what a capability call returned. A value msgpack cannot encode
/// is written as `null`.
fn encode_cap_outcome(outcome: framing.CapOutcome) -> JsonValue {
  case outcome {
    framing.CapOk(value:) ->
      tagged("cap_ok", [#("value", encode_msgpack(value))])
    framing.CapErr(code:, message: text) ->
      tagged("cap_err", [
        #("code", json.String(code)),
        #("message", json.String(text)),
      ])
  }
}

/// Reads what a capability call returned.
fn decode_cap_outcome(
  value: JsonValue,
) -> Result(framing.CapOutcome, CorruptionReport) {
  use #(kind, fields) <- result.try(tagged_of(value, "capability outcome"))

  // A capability returned a value or reported an error with a code.
  case kind {
    "cap_ok" -> {
      use value <- result.map(field_as(fields, "value", msgpack_of))
      framing.CapOk(value:)
    }
    "cap_err" -> {
      use code <- result.try(string_field(fields, "code"))
      use text <- result.map(string_field(fields, "message"))
      framing.CapErr(code:, message: text)
    }
    other -> Error(unknown("capability outcome", other))
  }
}

/// The JSON of why the owner denied a capability call.
fn encode_cap_denial(denial: satellite.CapDenial) -> JsonValue {
  json.Object([
    #("code", json.String(denial.code)),
    #("message", json.String(denial.message)),
  ])
}

/// Reads why the owner denied a capability call.
fn decode_cap_denial(
  value: JsonValue,
) -> Result(satellite.CapDenial, CorruptionReport) {
  use fields <- result.try(object_of(value, "capability denial"))
  use code <- result.try(string_field(fields, "code"))
  use text <- result.map(string_field(fields, "message"))
  satellite.CapDenial(code:, message: text)
}

/// The JSON of the MCP façades the session serves.
fn encode_mcp_plan(plan: protocol.McpPlan) -> JsonValue {
  json.Object([
    #("served", encode_list(plan.served, encode_facade)),
    #("expected", encode_list(plan.expected, json.String)),
  ])
}

/// Reads the MCP façades the session serves.
fn decode_mcp_plan(
  value: JsonValue,
) -> Result(protocol.McpPlan, CorruptionReport) {
  use fields <- result.try(object_of(value, "mcp plan"))
  use served <- result.try(list_field(fields, "served", decode_facade))
  use expected <- result.map(list_field(fields, "expected", string_reader))
  protocol.McpPlan(served:, expected:)
}

/// The JSON of one MCP façade.
fn encode_facade(facade: protocol.Facade) -> JsonValue {
  json.Object([
    #("server", json.String(facade.server)),
    #("module_name", json.String(facade.module_name)),
    #("source", json.String(facade.source)),
    #("surface", json.String(facade.surface)),
  ])
}

/// Reads one MCP façade.
fn decode_facade(
  value: JsonValue,
) -> Result(protocol.Facade, CorruptionReport) {
  use fields <- result.try(object_of(value, "facade"))
  use server <- result.try(string_field(fields, "server"))
  use module_name <- result.try(string_field(fields, "module_name"))
  use source <- result.try(string_field(fields, "source"))
  use surface <- result.map(string_field(fields, "surface"))
  protocol.Facade(server:, module_name:, source:, surface:)
}

/// The JSON of the operator's Git identity.
fn encode_git_identity(identity: protocol.GitIdentity) -> JsonValue {
  json.Object([
    #("name", json.String(identity.name)),
    #("email", json.String(identity.email)),
  ])
}

/// Reads the operator's Git identity.
fn decode_git_identity(
  value: JsonValue,
) -> Result(protocol.GitIdentity, CorruptionReport) {
  use fields <- result.try(object_of(value, "git identity"))
  use name <- result.try(string_field(fields, "name"))
  use email <- result.map(string_field(fields, "email"))
  protocol.GitIdentity(name:, email:)
}

// --- shared shapes --------------------------------------------------------------

/// An object whose `kind` names a constructor, followed by its fields.
fn tagged(kind: String, fields: Fields) -> JsonValue {
  json.Object([#("kind", json.String(kind)), ..fields])
}

/// Splits a tagged object into its kind and its fields.
fn tagged_of(
  value: JsonValue,
  on: String,
) -> Result(#(String, Fields), CorruptionReport) {
  use fields <- result.try(object_of(value, on))
  use kind <- result.map(string_field(fields, "kind"))
  #(kind, fields)
}

/// The report for a kind or frame name this module does not know.
fn unknown(on: String, name: String) -> CorruptionReport {
  corrupt(on, "a " <> on <> " kind this protocol defines", name)
}

/// Refuses a body whose tag is not the one the receiver expects.
fn expect_tag(
  on: String,
  found: String,
  expected: String,
) -> Result(Nil, CorruptionReport) {
  case found == expected {
    True -> Ok(Nil)
    False -> Error(corrupt(on, "a body of kind " <> expected, found))
  }
}

/// The JSON of a `Result`: an object with one of `ok` and `error`.
fn encode_result(
  value: Result(a, e),
  ok: fn(a) -> JsonValue,
  refused: fn(e) -> JsonValue,
) -> JsonValue {
  case value {
    Ok(inner) -> json.Object([#("ok", ok(inner))])
    Error(inner) -> json.Object([#("error", refused(inner))])
  }
}

/// Reads a `Result` from an object with exactly one of `ok` and `error`.
fn decode_result(
  value: JsonValue,
  on: String,
  ok: fn(JsonValue) -> Result(a, CorruptionReport),
  refused: fn(JsonValue) -> Result(e, CorruptionReport),
) -> Result(Result(a, e), CorruptionReport) {
  use fields <- result.try(object_of(value, on))

  // Exactly one side must be present. An object with both, or with neither,
  // does not say which the sender meant.
  case list.key_find(fields, "ok"), list.key_find(fields, "error") {
    Ok(inner), Error(Nil) -> result.map(ok(inner), Ok)
    Error(Nil), Ok(inner) -> result.map(refused(inner), Error)
    Ok(_), Ok(_) | Error(Nil), Error(Nil) ->
      Error(corrupt(on, "exactly one of ok and error", "neither or both"))
  }
}

/// Reads a `Result` from the `answer` field of a reply body.
fn decode_answer_field(
  fields: Fields,
  ok: fn(JsonValue) -> Result(a, CorruptionReport),
  refused: fn(JsonValue) -> Result(e, CorruptionReport),
) -> Result(Result(a, e), CorruptionReport) {
  use value <- result.try(field(fields, "answer"))
  decode_result(value, "answer", ok, refused)
}

/// Reads a `Result` from a named field of an object.
fn decode_result_field(
  fields: Fields,
  name: String,
  ok: fn(JsonValue) -> Result(a, CorruptionReport),
  refused: fn(JsonValue) -> Result(e, CorruptionReport),
) -> Result(Result(a, e), CorruptionReport) {
  use value <- result.try(field(fields, name))
  decode_result(value, name, ok, refused)
}

/// The JSON of an optional value: `null` for none.
fn encode_option(value: Option(a), encode: fn(a) -> JsonValue) -> JsonValue {
  case value {
    Some(inner) -> encode(inner)
    None -> json.Null
  }
}

/// Reads an optional value: `null` is none.
fn decode_option(
  value: JsonValue,
  decode: fn(JsonValue) -> Result(a, CorruptionReport),
) -> Result(Option(a), CorruptionReport) {
  case value {
    json.Null -> Ok(None)
    json.Object(..)
    | json.Array(..)
    | json.String(..)
    | json.Int(..)
    | json.Float(..)
    | json.Bool(..) -> result.map(decode(value), Some)
  }
}

/// The JSON of a list.
fn encode_list(items: List(a), encode: fn(a) -> JsonValue) -> JsonValue {
  json.Array(list.map(items, encode))
}

/// The JSON of a value that carries nothing, which is `null`.
fn encode_nil(_nothing: Nil) -> JsonValue {
  json.Null
}

/// Reads a value that carries nothing, which must be `null`.
fn decode_nil(value: JsonValue) -> Result(Nil, CorruptionReport) {
  case value {
    json.Null -> Ok(Nil)
    other -> Error(corrupt("ok", "null", describe(other)))
  }
}

/// The JSON of a list of name and value pairs, as an array of objects so that
/// order and repeated names survive.
fn encode_pairs(pairs: List(#(String, String))) -> JsonValue {
  encode_list(pairs, fn(pair) {
    json.Object([
      #("name", json.String(pair.0)),
      #("value", json.String(pair.1)),
    ])
  })
}

/// Reads a list of name and value pairs.
fn decode_pairs(
  value: JsonValue,
) -> Result(List(#(String, String)), CorruptionReport) {
  use items <- result.try(array_of(value, "pairs"))
  list.try_map(items, fn(item) {
    use fields <- result.try(object_of(item, "pair"))
    use name <- result.try(string_field(fields, "name"))
    use text <- result.map(string_field(fields, "value"))
    #(name, text)
  })
}

/// The JSON of bytes: standard base64 with padding.
fn encode_bytes(bytes: BitArray) -> JsonValue {
  json.String(bit_array.base64_encode(bytes, True))
}

/// The JSON of a msgpack value, as the base64 of its bytes. A value msgpack
/// cannot encode is written as `null`, which no decoder accepts as bytes.
fn encode_msgpack(value: msgpack.MsgPackValue) -> JsonValue {
  case msgpack.encode(value) {
    Ok(bytes) -> encode_bytes(bytes)
    Error(_unencodable) -> json.Null
  }
}

/// Reads a msgpack value from the base64 of its bytes.
fn msgpack_of(
  value: JsonValue,
  on: String,
) -> Result(msgpack.MsgPackValue, CorruptionReport) {
  use bytes <- result.try(bytes_of(value, on))
  msgpack.decode(bytes)
}

// --- primitives -------------------------------------------------------------------

/// Builds the report every decoder in this module returns.
fn corrupt(on: String, expected: String, found: String) -> CorruptionReport {
  corruption.report(at: boundary, on:, expected:, context: found)
}

/// What kind of JSON a value is, for a report that must not echo the value.
fn describe(value: JsonValue) -> String {
  case value {
    json.Object(..) -> "an object"
    json.Array(..) -> "an array"
    json.String(..) -> "a string"
    json.Int(..) -> "an integer"
    json.Float(..) -> "a float"
    json.Bool(..) -> "a boolean"
    json.Null -> "null"
  }
}

/// Reads the fields of an object.
fn object_of(value: JsonValue, on: String) -> Result(Fields, CorruptionReport) {
  case value {
    json.Object(fields) -> Ok(fields)
    other -> Error(corrupt(on, "an object", describe(other)))
  }
}

/// Reads the items of an array.
fn array_of(
  value: JsonValue,
  on: String,
) -> Result(List(JsonValue), CorruptionReport) {
  case value {
    json.Array(items) -> Ok(items)
    other -> Error(corrupt(on, "an array", describe(other)))
  }
}

/// Reads a string.
fn string_of(value: JsonValue, on: String) -> Result(String, CorruptionReport) {
  case value {
    json.String(text) -> Ok(text)
    other -> Error(corrupt(on, "a string", describe(other)))
  }
}

/// Reads a boolean.
fn bool_of(value: JsonValue, on: String) -> Result(Bool, CorruptionReport) {
  case value {
    json.Bool(flag) -> Ok(flag)
    other -> Error(corrupt(on, "a boolean", describe(other)))
  }
}

/// Reads an integer that fits in 64 bits.
fn int_of(value: JsonValue, on: String) -> Result(Int, CorruptionReport) {
  case value {
    json.Int(number) -> in_range(number, on)
    other -> Error(corrupt(on, "an integer", describe(other)))
  }
}

/// Refuses an integer outside the signed 64-bit range.
fn in_range(number: Int, on: String) -> Result(Int, CorruptionReport) {
  case number < min_int || number > max_int {
    True -> Error(corrupt(on, "a 64-bit integer", "an integer out of range"))
    False -> Ok(number)
  }
}

/// Refuses an integer below a floor.
fn at_least(
  number: Int,
  floor: Int,
  on: String,
) -> Result(Int, CorruptionReport) {
  case number >= floor {
    True -> Ok(number)
    False ->
      Error(corrupt(
        on,
        "an integer of at least " <> int.to_string(floor),
        int.to_string(number),
      ))
  }
}

/// Reads a count, an offset, a size or a duration, which is not negative.
fn nat_of(value: JsonValue, on: String) -> Result(Int, CorruptionReport) {
  int_of(value, on) |> result.try(at_least(_, 0, on))
}

/// Reads an id, which is at least 1.
fn id_of(value: JsonValue, on: String) -> Result(Int, CorruptionReport) {
  int_of(value, on) |> result.try(at_least(_, 1, on))
}

/// Reads an operation id from its text.
fn op_id_of(
  value: JsonValue,
  on: String,
) -> Result(ids.OpId, CorruptionReport) {
  use text <- result.try(string_of(value, on))
  ids.parse_op_id(text)
}

/// Reads bytes from standard base64 with padding. A text that decodes but is
/// not what `base64_encode` would write for the same bytes, because it lacks
/// padding or carries whitespace, is refused, so one value has one encoding.
fn bytes_of(
  value: JsonValue,
  on: String,
) -> Result(BitArray, CorruptionReport) {
  use text <- result.try(string_of(value, on))
  use bytes <- result.try(
    bit_array.base64_decode(text)
    |> result.map_error(fn(_not_base64) {
      corrupt(on, "padded base64", "text that is not")
    }),
  )

  // Re-encoding is the whole test of canonical form: it fails on a missing
  // pad, on whitespace the decoder skips, and on stray trailing bits.
  case bit_array.base64_encode(bytes, True) == text {
    True -> Ok(bytes)
    False -> Error(corrupt(on, "canonical padded base64", "text that is not"))
  }
}

/// Reads an attach token, at most 64 bytes.
fn token_of(
  value: JsonValue,
  on: String,
) -> Result(BitArray, CorruptionReport) {
  use bytes <- result.try(bytes_of(value, on))
  let size = bit_array.byte_size(bytes)

  // A token is a short random string. A longer one is not kept.
  case size <= max_token_bytes {
    True -> Ok(bytes)
    False ->
      Error(corrupt(
        on,
        "at most " <> int.to_string(max_token_bytes) <> " bytes",
        int.to_string(size) <> " bytes",
      ))
  }
}

/// Reads a binding, exactly `untrusted_wire.binding_bytes` bytes.
fn binding_of(
  value: JsonValue,
  on: String,
) -> Result(BitArray, CorruptionReport) {
  use bytes <- result.try(bytes_of(value, on))
  let size = bit_array.byte_size(bytes)

  // A binding is compared to the ones the link minted, so any other length is
  // a forgery before it is a comparison.
  case size == untrusted_wire.binding_bytes {
    True -> Ok(bytes)
    False ->
      Error(corrupt(
        on,
        "exactly " <> int.to_string(untrusted_wire.binding_bytes) <> " bytes",
        int.to_string(size) <> " bytes",
      ))
  }
}

/// Reads one of a fixed set of strings, each naming a value.
fn enum_of(
  value: JsonValue,
  on: String,
  table: List(#(String, a)),
) -> Result(a, CorruptionReport) {
  use text <- result.try(string_of(value, on))
  list.key_find(table, text)
  |> result.map_error(fn(_not_listed) {
    let names = list.map(table, fn(entry) { entry.0 })
    corrupt(on, "one of " <> string.join(names, ", "), text)
  })
}

/// A reader for a string, in the shape `list_field` and `option_field` take.
fn string_reader(value: JsonValue) -> Result(String, CorruptionReport) {
  string_of(value, "value")
}

/// A reader for a non-negative integer, in the same shape.
fn nat_reader(value: JsonValue) -> Result(Int, CorruptionReport) {
  nat_of(value, "value")
}

/// Finds a field of an object.
fn field(fields: Fields, name: String) -> Result(JsonValue, CorruptionReport) {
  list.key_find(fields, name)
  |> result.map_error(fn(_absent) {
    corrupt(name, "a field named " <> name, "absent")
  })
}

/// Finds a field and reads it with a reader that names the field in its report.
fn field_as(
  fields: Fields,
  name: String,
  read: fn(JsonValue, String) -> Result(a, CorruptionReport),
) -> Result(a, CorruptionReport) {
  use value <- result.try(field(fields, name))
  read(value, name)
}

/// Finds a field and decodes it with a decoder that names its own boundary.
fn nested(
  fields: Fields,
  name: String,
  decode: fn(JsonValue) -> Result(a, CorruptionReport),
) -> Result(a, CorruptionReport) {
  use value <- result.try(field(fields, name))
  decode(value)
}

/// Finds a string field.
fn string_field(
  fields: Fields,
  name: String,
) -> Result(String, CorruptionReport) {
  field_as(fields, name, string_of)
}

/// Finds an integer field.
fn int_field(fields: Fields, name: String) -> Result(Int, CorruptionReport) {
  field_as(fields, name, int_of)
}

/// Finds a non-negative integer field.
fn nat_field(fields: Fields, name: String) -> Result(Int, CorruptionReport) {
  field_as(fields, name, nat_of)
}

/// Finds an id field, which is at least 1.
fn id_field(fields: Fields, name: String) -> Result(Int, CorruptionReport) {
  field_as(fields, name, id_of)
}

/// Finds an array field and decodes each of its items.
fn list_field(
  fields: Fields,
  name: String,
  decode: fn(JsonValue) -> Result(a, CorruptionReport),
) -> Result(List(a), CorruptionReport) {
  use value <- result.try(field_as(fields, name, array_of))
  list.try_map(value, decode)
}

/// Finds a field that is `null` for none and otherwise decoded.
fn option_field(
  fields: Fields,
  name: String,
  decode: fn(JsonValue) -> Result(a, CorruptionReport),
) -> Result(Option(a), CorruptionReport) {
  use value <- result.try(field(fields, name))
  decode_option(value, decode)
}
