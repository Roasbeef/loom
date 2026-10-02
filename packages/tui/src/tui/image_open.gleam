//// Opening a transcript image outside the terminal.
////
//// A terminal that does not draw a picture can still hand it to whatever
//// the person's desktop opens pictures with. The image's bytes are written
//// to a file of their own in a private directory, `0700` and owned by this
//// user, under the system's temporary directory, and the file's path is
//// given to the platform's opener (`view_link.quiet_opener`), the one
//// `loom ui --open` uses, run through `/bin/sh` with its output sent to
//// `/dev/null` so nothing lands over the frame. The work reads and writes the file system and waits on a child
//// process, so it runs as a job (`job.OpenImage`) and never in a step.
////
//// The path is built from the media type and the clock, never from
//// anything the image's author wrote, so a crafted name cannot place the
//// file anywhere else.

import filepath
import gleam/bit_array
import gleam/int
import gleam/result
import host/bootstrap
import simplifile

/// Writes the image to a private file and opens it, answering the file's
/// path or why it could not be opened.
///
/// ## Examples
///
/// ```gleam
/// // image_open.open("image/png", data, view_link.quiet_opener())
/// ```
pub fn open(
  mime_type: String,
  data: String,
  opener: fn(String) -> Result(Nil, String),
) -> Result(String, String) {
  use bytes <- result.try(
    bit_array.base64_decode(data)
    |> result.replace_error("the image's bytes are not valid base64"),
  )
  let directory = filepath.join(temporary_root(), "loom-images")
  use Nil <- result.try(bootstrap.ensure_private_directory(directory))
  let path =
    filepath.join(
      directory,
      "image-"
        <> int.to_string(bootstrap.system_time_ms())
        <> "."
        <> extension(mime_type),
    )
  use Nil <- result.try(
    simplifile.write_bits(path, bytes)
    |> result.map_error(simplifile.describe_error),
  )
  use Nil <- result.try(opener(path))
  Ok(path)
}

// Where the operating system keeps temporary files for this user: `TMPDIR`
// when it is set, as macOS sets it to a per-user directory, and `/tmp`
// otherwise.
fn temporary_root() -> String {
  case bootstrap.getenv("TMPDIR") {
    Ok(root) if root != "" -> root
    Ok(_) | Error(Nil) -> "/tmp"
  }
}

// The file's extension, from the declared media type, which is what the
// opener reads to choose a viewer.
fn extension(mime_type: String) -> String {
  case mime_type {
    "image/png" -> "png"
    "image/jpeg" | "image/jpg" -> "jpg"
    "image/gif" -> "gif"
    "image/webp" -> "webp"
    _ -> "img"
  }
}
