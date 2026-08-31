//// Narrow file reads that the terminal image classifier needs.

/// Reads no more than `bytes` from the beginning of one file.
///
/// This calls Erlang/OTP's `file:open`, `file:read`, and `file:close` because
/// `simplifile` exposes only whole-file reads. The bounded read lets the image
/// classifier inspect magic bytes before admitting a whole file into memory.
@external(erlang, "tui_gleam_ffi", "read_prefix")
pub fn read_prefix(path: String, bytes: Int) -> Result(BitArray, String)

/// Reads one regular file without ever retaining more than `limit` bytes.
///
/// The bound is enforced while reading, so growth after an earlier file-size
/// check cannot turn image admission into an unbounded allocation.
@external(erlang, "tui_gleam_ffi", "read_bounded")
pub fn read_bounded(path: String, limit: Int) -> Result(BitArray, String)
