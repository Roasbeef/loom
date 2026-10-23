//// Dynamic code exports and standard sys metadata have no typed Gleam loader.
//// This FFI admits only the compiled definition's exact record/function shape,
//// and only an existing module atom created by the fixed-slot code loader.

import ext/internal/live_types
import ext/live
import gleam/dynamic.{type Dynamic}

/// Reads the fixed definition export from a verified compiled module.
///
/// ## Examples
///
/// ```gleam
/// // ffi_live_definition.definition("loom_live_a@counter@entry")
/// ```
///
@external(erlang, "ext_live_definition", "definition")
pub fn definition(module: String) -> Result(live.Definition, String)

/// Validates trusted sys transition metadata without casting arbitrary state.
///
/// ## Examples
///
/// ```gleam
/// // ffi_live_definition.change(request.extra)
/// ```
///
@external(erlang, "ext_live_definition", "change")
pub fn change(extra: Dynamic) -> Result(live_types.Change, String)

/// Calls the compiled pure migration export over the current JSON document.
///
/// ## Examples
///
/// ```gleam
/// // ffi_live_definition.migrate(module, "v1", state)
/// ```
///
@external(erlang, "ext_live_definition", "migrate")
pub fn migrate(
  module: String,
  from: String,
  state: String,
) -> Result(String, String)
