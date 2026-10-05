//// OTP zlib has no Gleam or Weft wrapper. This native-only bridge inflates
//// a literal table with an actual output ceiling before pure ETF inspection;
//// it never decodes Erlang terms or creates atoms from their contents.

/// Inflates one bounded BEAM literal table without decoding its terms.
///
/// ## Examples
///
/// `literal_bytes(<<0:32, 0:32>>)` returns the empty literal table bytes.
@external(erlang, "codemode_ffi", "literal_bytes")
pub fn literal_bytes(payload: BitArray) -> Result(BitArray, String)
