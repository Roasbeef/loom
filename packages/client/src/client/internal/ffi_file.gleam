//// Filesystem externals the websocket transport needs for atomic,
//// narrowly-permissioned file creation -- specifically, minting the
//// local-auth token file without a world-readable window.
////
//// FFI confinement (spec §0.2): the one `@external` this file declares
//// lives here, backed by the shim in `client_ffi.erl`.

/// Creates `path` exclusively (failing if anything already exists there)
/// and immediately restricts it to mode 0600, then writes `bytes`.
/// Returns `Nil` on success; `Nil` on any failure (already exists, no
/// such directory, permission denied, ...) since the caller's only
/// recourse in every case is the same: pick a different path or refuse
/// to start.
///
/// Uses `file:write_file/3` with the `exclusive` option (an `O_EXCL`
/// open, so a symlink or pre-existing file at `path` is refused rather
/// than followed or truncated) followed by `file:change_mode/2`. This
/// is the same two-step "create exclusively, then tighten" pattern
/// `broker/internal/ffi_port.write_private_file` uses for the fd-3
/// policy file; there the directory is 0700 so the file's own transient
/// mode never matters. Here `path`'s directory is not ours to lock down
/// (the caller only owns the token file, per `client/server`'s `Config`
/// invariant), so the caller writes this exclusively at an
/// unpredictable temporary name and renames it into place -- the
/// temporary name is never the path anyone is polling, so the brief
/// window between create and chmod is not an exploitable oracle the way
/// a fixed, predictable path would be.
@external(erlang, "client_ffi", "create_exclusive_private_file")
pub fn create_exclusive_private_file(
  path: String,
  bytes: BitArray,
) -> Result(Nil, Nil)
