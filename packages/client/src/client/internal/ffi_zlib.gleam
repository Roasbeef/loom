//// Bounded gzip inflation, the one external the extension archive
//// reader needs.
////
//// The boundary exists because inflating an attacker-supplied stream is
//// the one step of `loom ext install` where a few hundred bytes on the
//// wire can become gigabytes in the harness VM. OTP's `zlib` already
//// knows how to inflate one chunk at a time; what it does not do is stop
//// at a byte budget, so the shim in `client_ffi.erl` owns the loop that
//// compares the running output size against the cap after every chunk
//// and abandons the stream the moment it goes over. The bomb is
//// therefore never materialised, which is a stronger property than
//// inflating and then measuring.
////
//// FFI confinement (spec §0.2): the one `@external` this file declares
//// lives here, backed by `client_ffi:inflate_gzip/2`.

/// Why a bounded inflation refused.
pub type InflateError {
  /// The output passed the byte budget the caller set. The stream was
  /// abandoned at that point, so nothing beyond the budget was ever
  /// held in memory.
  OutputTooLarge

  /// zlib refused the stream: a header that is not gzip, a corrupt
  /// deflate block, or a trailing CRC that does not match. The three
  /// collapse to one variant because the caller's recourse — refuse the
  /// archive — is the same for each.
  StreamCorrupt
}

/// Inflates a gzip stream, stopping as soon as the output exceeds
/// `limit` bytes.
///
/// The gzip wrapper (rather than a bare deflate stream) is selected by
/// `zlib:inflateInit/2` with 31 window bits, so the gzip header and the
/// trailing CRC are checked by zlib and a stream that is not gzip is
/// `StreamCorrupt` rather than a pile of nonsense bytes.
///
/// A *truncated* gzip stream is not reliably an error here: zlib may
/// hand back the bytes it managed to inflate and report the stream as
/// finished. That is deliberate rather than overlooked — the caller is
/// the tar reader, and a tar cut short has no pair of trailing zero
/// blocks, so truncation is caught one layer up with a message that
/// names the archive rather than the compression.
///
/// ## Examples
///
/// ```gleam
/// // ffi_zlib.inflate_gzip(<<"not gzip":utf8>>, 1024)
/// // -> Error(ffi_zlib.StreamCorrupt)
/// ```
///
@external(erlang, "client_ffi", "inflate_gzip")
pub fn inflate_gzip(
  bytes: BitArray,
  limit: Int,
) -> Result(BitArray, InflateError)
