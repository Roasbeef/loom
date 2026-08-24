import core/json
import gleam/bit_array
import gleam/erlang/process
import gleam/option.{Some}
import gleam/string
import support/fake_broker
import support/memory_fs
import tools/blob
import tools/tool

fn ctx() -> tool.Ctx {
  let filesystem = memory_fs.filesystem(memory_fs.start())
  let recorded = process.new_subject()
  fake_broker.ctx(
    workspace: "/work",
    filesystem:,
    now: 0,
    script: [],
    recorded:,
  )
}

pub fn small_output_stays_inline_test() {
  assert blob.bound(ctx(), "small output") == Ok(blob.Inline("small output"))
}

pub fn threshold_boundary_inline_test() {
  // Exactly the threshold is NOT over it: it stays inline.
  let text = string.repeat("a", blob.overflow_threshold_bytes)
  assert blob.bound(ctx(), text) == Ok(blob.Inline(text))
}

pub fn threshold_boundary_overflow_test() {
  let text = string.repeat("a", blob.overflow_threshold_bytes + 1)
  let assert Ok(blob.Overflowed(ref:, size:, head_excerpt:, tail_excerpt:)) =
    blob.bound(ctx(), text)
  assert size == blob.overflow_threshold_bytes + 1
  assert string.starts_with(ref, "sha256-")
  assert string.length(head_excerpt) == blob.excerpt_bytes
  assert string.length(tail_excerpt) == blob.excerpt_bytes
  assert string.starts_with(text, head_excerpt)
  assert string.ends_with(text, tail_excerpt)
}

pub fn overflow_writes_full_content_test() {
  let context = ctx()
  let text = string.repeat("line of output\n", 10_000)
  let assert Ok(blob.Overflowed(ref:, size:, ..)) = blob.bound(context, text)
  let filesystem = context.filesystem
  let assert Ok(bytes) = filesystem.read(blob.ref_path(context.blob_root, ref))
  assert bytes == <<text:utf8>>
  assert size == bit_array.byte_size(<<text:utf8>>)
}

pub fn content_addressing_same_content_same_ref_test() {
  let context = ctx()
  let text = string.repeat("x", blob.overflow_threshold_bytes + 5)
  let assert Ok(blob.Overflowed(ref: first, ..)) = blob.bound(context, text)
  let assert Ok(blob.Overflowed(ref: second, ..)) = blob.bound(context, text)
  assert first == second
}

pub fn content_addressing_different_content_different_ref_test() {
  let context = ctx()
  let base = string.repeat("x", blob.overflow_threshold_bytes + 5)
  let assert Ok(blob.Overflowed(ref: first, ..)) = blob.bound(context, base)
  let assert Ok(blob.Overflowed(ref: second, ..)) =
    blob.bound(context, base <> "!")
  assert first != second
}

pub fn excerpts_respect_utf8_boundaries_test() {
  // "€" is three UTF-8 bytes; 2048 is not divisible by 3, so a naive
  // byte cut would split a character.
  let count = { blob.overflow_threshold_bytes / 3 } + 10
  let text = string.repeat("€", count)
  let assert Ok(blob.Overflowed(head_excerpt:, tail_excerpt:, ..)) =
    blob.bound(ctx(), text)
  assert string.starts_with(text, head_excerpt)
  assert string.ends_with(text, tail_excerpt)
  assert bit_array.byte_size(<<head_excerpt:utf8>>) <= blob.excerpt_bytes
  assert bit_array.byte_size(<<tail_excerpt:utf8>>) <= blob.excerpt_bytes
}

pub fn bounded_text_names_the_ref_test() {
  let bounded =
    blob.Overflowed(
      ref: "sha256-abc",
      size: 70_000,
      head_excerpt: "HEAD",
      tail_excerpt: "TAIL",
    )
  let text = blob.bounded_text(bounded)
  assert string.starts_with(text, "HEAD")
  assert string.ends_with(text, "TAIL")
  assert string.contains(text, "sha256-abc")
  assert string.contains(text, "70000 bytes")
}

pub fn inline_bounded_text_is_identity_test() {
  assert blob.bounded_text(blob.Inline("as is")) == "as is"
}

pub fn with_blob_details_merges_into_object_test() {
  let outcome =
    tool.success("body")
    |> tool.with_details(json.Object([#("exit_code", json.Int(0))]))
  let bounded =
    blob.Overflowed(
      ref: "sha256-abc",
      size: 70_000,
      head_excerpt: "h",
      tail_excerpt: "t",
    )
  let merged = blob.with_blob_details(outcome, bounded)
  let assert Some(json.Object(fields)) = merged.details
  assert fields
    == [
      #("exit_code", json.Int(0)),
      #(
        "blob",
        json.Object([
          #("ref", json.String("sha256-abc")),
          #("size", json.Int(70_000)),
          #("head_excerpt", json.String("h")),
          #("tail_excerpt", json.String("t")),
        ]),
      ),
    ]
}

pub fn with_blob_details_inline_is_identity_test() {
  let outcome = tool.success("body")
  assert blob.with_blob_details(outcome, blob.Inline("body")) == outcome
}

pub fn ref_is_lowercase_hex_sha256_test() {
  let ref = blob.ref_for(<<"loom":utf8>>)
  let assert "sha256-" <> hex = ref
  assert string.length(hex) == 64
  assert hex == string.lowercase(hex)
}
