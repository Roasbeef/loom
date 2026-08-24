//// The secret injection seam.
////
//// Spec §3.3 invariant 4: secrets appear only in provider-gateway request
//// memory — never in environments handed to tools, transcripts, logs, or
//// any satellite-reachable state. This module enforces the shape of that
//// rule: a `SecretStore` is an injected lookup capability, and the only
//// call site is `gateway.request`, which copies the value straight into
//// an outbound HTTP header. `ProviderError` carries secret *names* only,
//// and nothing the gateway returns or persists ever embeds a value.
////
//// Backends:
////
//// - `env` — reads process environment variables (`ANTHROPIC_API_KEY`,
////   …). Ships now, via the `provider/internal/ffi_env` shim.
//// - `from_list` — a fixed in-memory store for tests.
//// - `from_function` — arbitrary injection, and the hook where the
////   planned OS-keychain backends attach: macOS `security`
////   find-generic-password and the Linux secret-service D-Bus API are
////   follow-up FFI shims (spec WP-F scope) that will slot in here as
////   `fn(name) -> Result(String, Nil)` without changing any caller.

import gleam/list
import provider/internal/ffi_env

/// A secret lookup capability: name in, value out. Injected into the
/// gateway at construction.
///
/// Constructor invariants: `get` returns `Error(Nil)` for unknown names
/// and never panics; returned values are used for request construction
/// only and must never be logged or persisted by any caller.
pub type SecretStore {
  SecretStore(get: fn(String) -> Result(String, Nil))
}

/// Wraps an injected lookup function — the extension point for future
/// keychain backends.
///
/// ## Examples
///
/// ```gleam
/// let store = secret.from_function(fn(_name) { Error(Nil) })
/// assert secret.lookup(store, "missing") == Error(Nil)
/// ```
///
pub fn from_function(get: fn(String) -> Result(String, Nil)) -> SecretStore {
  SecretStore(get:)
}

/// A fixed in-memory store for tests.
///
/// ## Examples
///
/// ```gleam
/// let store = secret.from_list([#("key", "value")])
/// assert secret.lookup(store, "key") == Ok("value")
/// ```
///
pub fn from_list(pairs: List(#(String, String))) -> SecretStore {
  SecretStore(get: fn(name) { list.key_find(pairs, name) })
}

/// The environment-variable backend: secret names are environment
/// variable names, read at lookup time.
///
/// ## Examples
///
/// ```gleam
/// let store = secret.env()
/// // secret.lookup(store, "ANTHROPIC_API_KEY") // -> Ok("sk-...")
/// ```
///
pub fn env() -> SecretStore {
  SecretStore(get: ffi_env.get_env)
}

/// Looks a secret up by name.
///
/// ## Examples
///
/// ```gleam
/// let store = secret.from_list([#("key", "value")])
/// assert secret.lookup(store, "other") == Error(Nil)
/// ```
///
pub fn lookup(store: SecretStore, name: String) -> Result(String, Nil) {
  store.get(name)
}
