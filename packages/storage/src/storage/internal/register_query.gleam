//// Builds the one indexed statement for selected register cells.
//// The caller enforces the input bound and handles empty requests.

import core/register.{type RegisterNs}
import gleam/list
import gleam/string
import sqlight

/// Builds the parameterized query and its namespace/key arguments.
///
/// The caller supplies at least one key, with the public read limit already
/// enforced. No key is interpolated into the statement text.
///
/// ## Examples
///
/// ```gleam
/// // register_query.selected(register.OpState, ["key"])
/// ```
pub fn selected(
  ns: RegisterNs,
  keys: List(String),
) -> #(String, List(sqlight.Value)) {
  let placeholders = keys |> list.map(fn(_) { "?" }) |> string.join(", ")
  #(
    "SELECT key, seq, value FROM registers WHERE ns = ? AND key IN ("
      <> placeholders
      <> ")",
    [sqlight.text(register.ns_to_string(ns)), ..list.map(keys, sqlight.text)],
  )
}
