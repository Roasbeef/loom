//// BEAM loading is a trusted satellite-only operation. Gleam, stdlib and
//// weft expose no atomic code loader, so this minimal FFI owns that boundary.
//// Authored source cannot import this internal module. The caller supplies
//// only a verified fixed-slot module set from its native compiler artifact.

/// Atomically installs one verified inactive implementation slot.
///
/// The native host checks byte digests and authority before sending these
/// bytes. This second boundary checks module identities and native byte caps.
///
/// ## Examples
///
/// ```gleam
/// // ffi_live_code.load(modules, expected)
/// ```
///
@external(erlang, "ext_live_code", "load")
pub fn load(
  modules: List(#(String, BitArray, String)),
  expected: List(String),
  baseline: List(String),
) -> Result(Nil, String)

/// Retires an inactive slot only when every old reference has disappeared.
///
/// ## Examples
///
/// ```gleam
/// // ffi_live_code.retire(expected)
/// ```
///
@external(erlang, "ext_live_code", "retire")
pub fn retire(expected: List(String)) -> Result(Nil, String)
