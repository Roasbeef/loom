//// FFI confinement module for symlink inspection: the lstat-level
//// primitive workspace containment (`fs.resolve_real`) is built on.
//// See `tools_ffi.erl` for the Erlang side.

import tools/tool.{type LinkStatus}

/// The path's own link status, without following it.
///
/// Uses OTP `file:read_link_all/1` (via `tools_ffi:read_link/1`, which
/// normalizes the errno vocabulary to `LinkStatus` on the Erlang side:
/// `einval` is an existing non-link, `enoent`/`enotdir` are missing).
/// No pure alternative exists: symlink targets live only in the real
/// filesystem, and simplifile can detect a symlink (`link_info`) but
/// cannot read its target.
@external(erlang, "tools_ffi", "read_link")
pub fn read_link(path: String) -> Result(LinkStatus, String)
