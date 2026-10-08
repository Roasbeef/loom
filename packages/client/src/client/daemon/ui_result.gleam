//// Bounded, explicit reads of immutable tool-result records for the web view.
////
//// The router checks the live page grant and resolves the immutable entry in
//// the authorized resident's store. A page reads one storage fragment, never
//// the whole record. An explicit download reads at most the storage record
//// ceiling within one five-second deadline, and builds a byte tree without
//// decoding or escaping a second copy of the complete JSON.

import core/ids
import gleam/bit_array
import gleam/bytes_tree
import gleam/int
import gleam/list
import gleam/result
import host/bootstrap
import storage/snapshot
import web_view/tool_result
import web_view/utf8_window

/// The immutable descriptor found through a result identity, without a capture.
/// Only one exact entry is requested; the maximum SQLite sequence is its fence.
///
/// ## Examples
///
/// ```gleam
/// // ui_result.descriptor(reader, result_id)
/// ```
pub fn descriptor(
  reader: snapshot.Reader,
  id: ids.EntryId,
) -> Result(snapshot.Descriptor, Nil) {
  use rows <- result.try(
    reader.lineage(id, 9_223_372_036_854_775_807, 1, 1000)
    |> result.replace_error(Nil),
  )
  use found <- result.try(list.first(rows))
  case found.id == id {
    True -> snapshot.validate_descriptor(found) |> result.replace_error(Nil)
    False -> Error(Nil)
  }
}

/// Returns one UTF-8 window, plus the total number of windows for navigation.
/// Window boundaries partition codepoints even when a stride bisects one.
///
/// ## Examples
///
/// ```gleam
/// // ui_result.page(reader, descriptor, 0)
/// ```
pub fn page(
  reader: snapshot.Reader,
  found: snapshot.Descriptor,
  index: Int,
) -> Result(#(String, Int), Nil) {
  let pages =
    int.max(
      1,
      { found.byte_length + tool_result.page_bytes - 1 }
        / tool_result.page_bytes,
    )
  case index >= 0 && index < pages {
    False -> Error(Nil)
    True -> {
      let start = index * tool_result.page_bytes
      let offset = int.max(0, start - 3)
      use bytes <- result.try(
        reader.fragment(found, offset, 1000) |> result.replace_error(Nil),
      )
      let end =
        int.min(
          found.byte_length - offset,
          start + tool_result.page_bytes - offset,
        )
      use text <- result.map(utf8_window.window(bytes, start - offset, end))
      #(text, pages)
    }
  }
}

/// Reads a complete result into a bounded byte tree for an attachment response.
/// The shared deadline and record limit apply before each subsequent read.
///
/// ## Examples
///
/// ```gleam
/// // ui_result.download(reader, descriptor)
/// ```
pub fn download(
  reader: snapshot.Reader,
  found: snapshot.Descriptor,
) -> Result(bytes_tree.BytesTree, Nil) {
  use _ <- result.try(
    snapshot.validate_descriptor(found) |> result.replace_error(Nil),
  )
  chunks(reader, found, 0, bootstrap.monotonic_time_ms() + 5000, [])
}

// Only a complete record leaves the handler. A failed, short, oversized or
// late fragment refuses the download rather than serving a partial JSON file.
fn chunks(
  reader: snapshot.Reader,
  found: snapshot.Descriptor,
  offset: Int,
  deadline: Int,
  kept: List(bytes_tree.BytesTree),
) -> Result(bytes_tree.BytesTree, Nil) {
  let remaining = deadline - bootstrap.monotonic_time_ms()
  case offset == found.byte_length, remaining > 0 {
    True, True -> Ok(bytes_tree.concat(list.reverse(kept)))
    _, False -> Error(Nil)
    False, True -> {
      use bytes <- result.try(
        reader.fragment(found, offset, int.min(remaining, 1000))
        |> result.replace_error(Nil),
      )
      let size = bit_array.byte_size(bytes)
      case
        size > 0
        && size <= snapshot.fragment_bytes_limit
        && offset + size <= found.byte_length
      {
        False -> Error(Nil)
        True ->
          chunks(reader, found, offset + size, deadline, [
            bytes_tree.from_bit_array(bytes),
            ..kept
          ])
      }
    }
  }
}
