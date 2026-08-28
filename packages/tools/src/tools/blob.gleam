//// Large-output overflow to a content-addressed blob directory
//// (implementation spec §3.2).
////
//// A tool output larger than `overflow_threshold_bytes` does not go
//// into the transcript wholesale: the full bytes are written once to
//// the session's blob directory under a content-addressed name, and
//// the tool result carries `{ref, size, head_excerpt, tail_excerpt}` —
//// enough for the model to see the shape of the output and decide
//// whether to read the rest. Content addressing (SHA-256 of the bytes)
//// makes writes idempotent: the same content always lands at the same
//// ref, so replaying a `Safe` tool or re-running an identical command
//// never duplicates storage.
////
//// The blob directory is seam-injected (`Ctx.blob_root`); all I/O goes
//// through the `FileSystem` seam, so tests run against an in-memory
//// fake. Context projection (WP-C) is expected to surface the excerpts
//// plus a note that the ref is readable via `fs_read` — which requires
//// the runtime to place `blob_root` under a readable root; recorded as
//// a spec gap.

import core/ids
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/int
import gleam/option.{Some}
import gleam/result
import gleam/string
import tools/internal/ffi_hash
import tools/tool.{type Ctx, type FileSystem, type FsError, type ToolOutcome}

/// Outputs strictly larger than this many bytes overflow to the blob
/// directory (spec §3.2: "> 64 KiB").
pub const overflow_threshold_bytes = 65_536

/// How many bytes of the head and of the tail are kept as excerpts in
/// an overflowed result (each excerpt is at most this long, trimmed to
/// a UTF-8 boundary).
pub const excerpt_bytes = 2048

/// A tool output after the overflow check.
pub type Bounded {
  /// At or under the threshold; carried inline.
  Inline(text: String)
  /// Over the threshold; the full text lives in the blob store.
  /// Invariants: `ref` is the content address (`sha256-<hex>`), `size`
  /// the full byte length, and the excerpts are UTF-8-clean prefixes
  /// and suffixes of at most `excerpt_bytes` bytes.
  Overflowed(ref: String, size: Int, head_excerpt: String, tail_excerpt: String)
}

/// Bounds one text output: small text passes through inline; large text
/// is written to the blob directory and summarized as
/// `{ref, size, head_excerpt, tail_excerpt}`. The write is idempotent —
/// an existing blob with the same content address is left alone.
///
/// ## Examples
///
/// ```gleam
/// assert blob.bound(ctx, "small") == Ok(blob.Inline("small"))
/// ```
///
pub fn bound(ctx: Ctx, text: String) -> Result(Bounded, FsError) {
  let bytes = <<text:utf8>>
  let size = bit_array.byte_size(bytes)
  case size > overflow_threshold_bytes {
    False -> Ok(Inline(text:))
    True -> {
      let ref = ref_for(bytes)
      let filesystem = ctx.filesystem
      use Nil <- result.try(filesystem.create_directory_all(ctx.blob_root))
      let path = ref_path(ctx.blob_root, ref)
      use present <- result.try(filesystem.is_file(path))
      use Nil <- result.try(case present {
        True -> Ok(Nil)
        False ->
          write_addressed(
            filesystem:,
            path:,
            temporary: temp_path(ctx.blob_root, ref, call_tag(ctx)),
            bytes:,
          )
      })
      Ok(Overflowed(
        ref:,
        size:,
        head_excerpt: utf8_prefix(bytes, excerpt_bytes),
        tail_excerpt: utf8_suffix(bytes, excerpt_bytes),
      ))
    }
  }
}

/// The content address of some bytes: `sha256-` plus lowercase hex.
///
/// ## Examples
///
/// ```gleam
/// assert string.starts_with(blob.ref_for(<<"x":utf8>>), "sha256-")
/// ```
///
pub fn ref_for(bytes: BitArray) -> String {
  "sha256-" <> string_lowercase_hex(ffi_hash.sha256(bytes))
}

/// Where a ref's bytes live under a blob root.
///
/// ## Examples
///
/// ```gleam
/// assert blob.ref_path("/blobs", "sha256-ab") == "/blobs/sha256-ab"
/// ```
///
pub fn ref_path(root: String, ref: String) -> String {
  root <> "/" <> ref
}

/// Where a ref's bytes are staged before they are renamed into place.
///
/// In the blob root itself, so the rename stays within one filesystem
/// and is therefore atomic; hidden and `.tmp`-suffixed so a reader
/// walking the store can tell a staging file from an address; and
/// carrying `tag`, which is what makes it unique to *one* write.
///
/// The tag is load-bearing rather than decoration. A shared temporary
/// name would be shared by exactly the writers a content address cannot
/// separate — two concurrent first writes of identical bytes — and the
/// interleave that follows can rename a half-written file into place.
/// A per-write name has no such interleave: each writer stages its own
/// file and the rename replaces the destination whole.
///
/// ## Examples
///
/// ```gleam
/// assert blob.temp_path("/blobs", "sha256-ab", "t")
///   == "/blobs/.sha256-ab.t.tmp"
/// ```
///
pub fn temp_path(root: String, ref: String, tag: String) -> String {
  root <> "/." <> ref <> "." <> tag <> ".tmp"
}

/// Writes bytes to their content address through a staging file.
///
/// The write is not atomic and the rename is, so the address never names
/// a partial file: a crash between the two leaves a stray `.tmp` in the
/// store — a byte of garbage nothing reads and the next `create` of the
/// same tag overwrites — rather than a blob whose SHA-256 name vouches
/// for content it does not hold. That distinction is the whole reason
/// this is two steps: a torn direct write is *permanently* wrong and
/// silently so, because every later reader trusts the address.
///
/// Idempotency is unaffected — the destination is the content address
/// either way, and the caller's `is_file` probe still skips the work.
///
/// The claim is exact for a *process* crash: the page cache survives,
/// so a completed rename names complete bytes. Power loss is outside
/// it — nothing fsyncs before the rename, and some filesystems can
/// persist the rename ahead of the data — which matches the harness's
/// threat model, not a stronger one.
pub fn write_addressed(
  filesystem filesystem: FileSystem,
  path path: String,
  temporary temporary: String,
  bytes bytes: BitArray,
) -> Result(Nil, FsError) {
  use Nil <- result.try(filesystem.write(temporary, bytes))
  filesystem.rename(temporary, path)
}

// What makes one overflow write's staging file its own: the durable
// coordinates of the tool call that produced it. A tool call overflows
// at most one output, so the triple is unique per write — and it is the
// same triple that identifies the call everywhere else in the harness,
// so nothing new has to be minted or threaded to get it. Slashes are
// folded out because a step id is a free-form string and a staging file
// must stay in the blob root.
fn call_tag(ctx: Ctx) -> String {
  [ids.op_id_to_string(ctx.op_id), ctx.step_id, int.to_string(ctx.source_index)]
  |> string.join(with: "-")
  |> string.replace(each: "/", with: "-")
}

/// The transcript text for a bounded output: inline text as-is; an
/// overflowed output as head excerpt, an elision note naming the ref,
/// and tail excerpt.
pub fn bounded_text(bounded: Bounded) -> String {
  case bounded {
    Inline(text:) -> text
    Overflowed(ref:, size:, head_excerpt:, tail_excerpt:) ->
      head_excerpt
      <> "\n[... output of "
      <> int.to_string(size)
      <> " bytes stored as "
      <> ref
      <> " ...]\n"
      <> tail_excerpt
  }
}

/// Merges overflow details into a tool outcome's details object: an
/// inline output leaves the outcome untouched; an overflowed one adds
/// the spec §3.2 `{ref, size, head_excerpt, tail_excerpt}` under
/// `"blob"`.
pub fn with_blob_details(
  outcome: ToolOutcome,
  bounded: Bounded,
) -> ToolOutcome {
  case bounded {
    Inline(text: _) -> outcome
    Overflowed(ref:, size:, head_excerpt:, tail_excerpt:) -> {
      let blob_details =
        json.Object([
          #("ref", json.String(ref)),
          #("size", json.Int(size)),
          #("head_excerpt", json.String(head_excerpt)),
          #("tail_excerpt", json.String(tail_excerpt)),
        ])
      let details = case outcome.details {
        Some(json.Object(fields:)) ->
          json.Object(list_append_field(fields, "blob", blob_details))
        Some(other) ->
          json.Object([#("details", other), #("blob", blob_details)])
        option.None -> json.Object([#("blob", blob_details)])
      }
      tool.with_details(outcome, details)
    }
  }
}

fn list_append_field(
  fields: List(#(String, JsonValue)),
  key: String,
  value: JsonValue,
) -> List(#(String, JsonValue)) {
  case fields {
    [] -> [#(key, value)]
    [first, ..rest] -> [first, ..list_append_field(rest, key, value)]
  }
}

// The longest prefix of at most `max` bytes that is valid UTF-8:
// backing off up to three bytes finds the nearest character boundary.
fn utf8_prefix(bytes: BitArray, max: Int) -> String {
  utf8_slice_at(bytes, 0, int.min(max, bit_array.byte_size(bytes)))
}

// The longest suffix of at most `max` bytes that is valid UTF-8.
fn utf8_suffix(bytes: BitArray, max: Int) -> String {
  let size = bit_array.byte_size(bytes)
  let take = int.min(max, size)
  utf8_slice_from(bytes, size - take, take)
}

fn utf8_slice_at(bytes: BitArray, start: Int, length: Int) -> String {
  case length <= 0 {
    True -> ""
    False ->
      case bit_array.slice(bytes, start, length) {
        Ok(slice) ->
          case bit_array.to_string(slice) {
            Ok(text) -> text
            // The cut landed inside a multi-byte character; shrink.
            Error(Nil) -> utf8_slice_at(bytes, start, length - 1)
          }
        Error(Nil) -> ""
      }
  }
}

fn utf8_slice_from(bytes: BitArray, start: Int, length: Int) -> String {
  case length <= 0 {
    True -> ""
    False ->
      case bit_array.slice(bytes, start, length) {
        Ok(slice) ->
          case bit_array.to_string(slice) {
            Ok(text) -> text
            // The cut landed inside a multi-byte character; move the
            // start forward to the next boundary.
            Error(Nil) -> utf8_slice_from(bytes, start + 1, length - 1)
          }
        Error(Nil) -> ""
      }
  }
}

fn string_lowercase_hex(bytes: BitArray) -> String {
  bytes
  |> bit_array.base16_encode
  |> string.lowercase
}
