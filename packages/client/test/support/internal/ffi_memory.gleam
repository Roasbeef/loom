//// Test-only accounting for terms copied across BEAM process boundaries.
////
//// Neither Gleam's standard library nor weft exposes a term's flattened
//// word count. The VM primitive lets regression tests distinguish shared
//// fields from closures that would duplicate unrelated state on a copy.

import gleam/erlang/process.{type Pid}

/// Counts words in a term with sharing removed, including closure captures.
///
/// ## Examples
///
/// ```gleam
/// assert ffi_memory.flat_words([1, 2]) == 4
/// ```
@external(erlang, "erts_debug", "flat_size")
pub fn flat_words(value: a) -> Int

/// Finds the Lustre component linked to a fixture's admitted page socket.
/// The pinned runtime record identifies the child without a production API.
///
/// ## Examples
///
/// ```gleam
/// // page_component_pid(socket) == Ok(component)
/// ```
@external(erlang, "client_test_ffi", "page_component_pid")
pub fn page_component_pid(socket: Pid) -> Result(Pid, Nil)
