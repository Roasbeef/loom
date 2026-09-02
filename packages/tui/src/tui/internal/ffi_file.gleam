//// Narrow file reads that the terminal image classifier needs.

import gleam/string
import weft

const read_timeout_ms = 1000

@external(erlang, "tui_ffi", "read_prefix")
fn read_prefix_raw(path: String, bytes: Int) -> Result(BitArray, String)

/// Reads no more than `bytes` from the beginning of one file.
///
/// This calls Erlang/OTP's `file:open`, `file:read`, and `file:close` because
/// `simplifile` exposes only whole-file reads. The bounded read lets the image
/// classifier inspect magic bytes before admitting a whole file into memory.
pub fn read_prefix(path: String, bytes: Int) -> Result(BitArray, String) {
  read_safely_within(fn() { read_prefix_raw(path, bytes) }, read_timeout_ms)
}

@external(erlang, "tui_ffi", "read_bounded")
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
/// This is a one-task weft run with a deadline: the worker belongs to
/// weft's scope rather than to this process, and bounds a blocking
/// `file:open` as well as the subsequent read. That closes the race where a
/// regular path is replaced by a FIFO after the metadata check but before
/// the descriptor is opened, and the caller must never block on such a
/// hostile path. Weft's deadline cancellation kills and joins the worker
/// before `start` returns, which is stronger than the fire-and-forget kill
/// this once hand-rolled: the descriptor is provably closed, not merely
/// signalled, before the caller ever sees the timeout.
@internal
pub fn read_safely_within(
  read: fn() -> Result(BitArray, String),
  within_ms: Int,
) -> Result(BitArray, String) {
  let outcomes =
    weft.new([read])
    |> weft.deadline(within_ms)
    |> weft.start

  // A one-task run yields exactly one outcome; the impossible shapes are
  // still answered rather than asserted away, because a wrong account from
  // the engine should refuse the read, not take the terminal down.
  case outcomes {
    [weft.Completed(value:, ..)] -> Ok(value)
    [weft.Failed(error:, ..)] -> Error(error)
    [weft.Crashed(reason:, ..)] ->
      Error("file read worker crashed: " <> string.inspect(reason))
    [weft.Abandoned(..)] -> Error("file read timed out")
    [weft.NeverStarted(..)] -> Error("file read timed out")

    // Only a managed task can lose or leave unconfirmed a drain proof, and
    // this run carries none; the arms are exhaustiveness, not cases.
    [weft.DrainProofLost(..)] | [weft.CancellationUnconfirmed(..)] ->
      Error("file read produced no account")
    [] | [_, _, ..] -> Error("file read produced no account")
  }
}
