//// Descriptor-scoped reads for bounded repository metadata.

/// Opens, validates, and reads one small regular file through one descriptor.
///
/// The descriptor-scoped type and size checks prevent a path replacement from
/// turning repository discovery into an unbounded or blocking read.
@external(erlang, "tui_gleam_workspace_ffi", "read_small_regular")
pub fn read_small_regular(path: String, limit: Int) -> Result(BitArray, Nil)
