//// Narrow file reads that the terminal image classifier needs.

import gleam/erlang/process.{type Down}
import gleam/string

const read_timeout_ms = 1000

type ReadReport {
  ReadReturned(Result(BitArray, String))
  ReadCrashed(Down)
}

@external(erlang, "tui_gleam_ffi", "read_prefix")
fn read_prefix_raw(path: String, bytes: Int) -> Result(BitArray, String)

/// Reads no more than `bytes` from the beginning of one file.
///
/// This calls Erlang/OTP's `file:open`, `file:read`, and `file:close` because
/// `simplifile` exposes only whole-file reads. The bounded read lets the image
/// classifier inspect magic bytes before admitting a whole file into memory.
pub fn read_prefix(path: String, bytes: Int) -> Result(BitArray, String) {
  read_safely_within(fn() { read_prefix_raw(path, bytes) }, read_timeout_ms)
}

@external(erlang, "tui_gleam_ffi", "read_bounded")
fn read_bounded_raw(path: String, limit: Int) -> Result(BitArray, String)

/// Reads one regular file without ever retaining more than `limit` bytes.
///
/// The bound is enforced while reading, so growth after an earlier file-size
/// check cannot turn image admission into an unbounded allocation. The read
/// runs in a monitored worker with a bounded wait, so a path swapped to a FIFO
/// cannot block the terminal process indefinitely before descriptor checking.
pub fn read_bounded(path: String, limit: Int) -> Result(BitArray, String) {
  read_safely_within(fn() { read_bounded_raw(path, limit) }, read_timeout_ms)
}

/// Runs one descriptor-level read outside the terminal process.
///
/// The worker bounds a blocking `file:open` as well as the subsequent read.
/// This closes the race where a regular path is replaced by a FIFO after the
/// metadata check but before the descriptor is opened.
@internal
pub fn read_safely_within(
  read: fn() -> Result(BitArray, String),
  within_ms: Int,
) -> Result(BitArray, String) {
  let replies = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() { process.send(replies, ReadReturned(read())) })
  let monitor = process.monitor(worker)
  let selector =
    process.new_selector()
    |> process.select(replies)
    |> process.select_specific_monitor(monitor, ReadCrashed)
  case process.selector_receive(from: selector, within: within_ms) {
    Ok(ReadReturned(result)) -> {
      process.demonitor_process(monitor)
      result
    }
    Ok(ReadCrashed(down)) ->
      Error("file read worker crashed: " <> string.inspect(down))
    Error(Nil) -> {
      process.kill(worker)
      process.demonitor_process(monitor)
      Error("file read timed out")
    }
  }
}
