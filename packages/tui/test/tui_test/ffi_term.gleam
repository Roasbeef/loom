//// Test support for proving BEAM term identity on cached terminal frames.

// `erts_debug:same/2` is the VM's physical-term identity predicate. Gleam's
// structural equality cannot distinguish a reused Buffer from an equal copy.
/// Reports whether two values are the exact same BEAM term.
@external(erlang, "erts_debug", "same")
pub fn same_term(first: value, second: value) -> Bool {
  first == second
}
