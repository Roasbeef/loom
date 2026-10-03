//// Native SQLite is required for SQL execution and authorizer enforcement.
//// No Gleam library implements SQLite's parser, VM progress handler or prepare
//// authorization; this private bridge delegates to the existing SQLite family
//// and owns all database handles entirely inside the satellite.

/// Materializes fixed fact tables and executes one native bounded query.
///
/// ## Examples
///
/// ```gleam
/// // ffi_lsp_sql.query(documents, symbols, targets, references, sql, params)
/// ```
@external(erlang, "loom_cap_lsp_sql", "query")
pub fn query(
  documents: List(List(a)),
  symbols: List(List(a)),
  targets: List(List(a)),
  references: List(List(a)),
  sql: String,
  params: List(a),
) -> Result(#(List(String), List(List(a))), #(String, String))
