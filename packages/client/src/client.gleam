//// The package entry point. `gleam run` on this package — and the
//// erlang shipment's `entrypoint.sh run`, which is what `bin/loom-server`
//// execs — starts the session server. Everything real lives in
//// `client/serve`; this module exists because both runners call the
//// module named after the package.

import client/serve

/// Starts the session server. See `client/serve` for the flag and
/// environment surface.
///
/// ## Examples
///
/// ```gleam
/// // bin/loom-server --session ./loom.db
/// ```
///
pub fn main() -> Nil {
  serve.main()
}
