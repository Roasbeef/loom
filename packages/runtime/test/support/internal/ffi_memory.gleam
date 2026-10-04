//// Test-only accounting for terms copied across BEAM process boundaries.
////
//// Neither Gleam's standard library nor weft exposes a term's flattened
//// word count. The VM primitive lets regression tests distinguish shared
//// fields from closures that would duplicate unrelated state on a copy.

import gleam/dynamic
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process

/// Counts words in a term with sharing removed, including closure captures.
///
/// ## Examples
///
/// ```gleam
/// assert ffi_memory.flat_words([1, 2]) == 4
/// ```
@external(erlang, "erts_debug", "flat_size")
pub fn flat_words(value: a) -> Int

/// Reads an actual OTP supervisor state for copy-cost regression tests.
/// Gleam exposes no inspection of OTP's retained restart specifications.
///
/// ## Examples
///
/// ```gleam
/// // let words = ffi_memory.flat_words(ffi_memory.state(root, 1000))
/// ```
@external(erlang, "sys", "get_state")
pub fn state(pid: process.Pid, timeout_ms: Int) -> dynamic.Dynamic

/// Reads one `process_info/2` item of a live process, as the inspector
/// that attributes memory to owners does. The ownership label is
/// `process_info(Pid, label)`, which `gleam_erlang` does not bind.
///
/// ## Examples
///
/// ```gleam
/// // ffi_memory.process_info(driver, atom.create("label"))
/// ```
@external(erlang, "erlang", "process_info")
pub fn process_info(pid: process.Pid, item: Atom) -> dynamic.Dynamic
