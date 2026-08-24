//// FFI shim for reading environment variables.
////
//// Backs the environment-variable `SecretStore` in `provider/secret`.
//// Reading the process environment is inherently effectful, so it lives
//// behind the FFI boundary like every other impurity in this package.

/// Reads one environment variable, `Error(Nil)` when unset.
///
/// Uses `os:getenv/1` via the Erlang shim (`provider_ffi:get_env/1`),
/// which converts the name to a charlist and the value back to a UTF-8
/// binary. No pure alternative exists: the process environment is
/// operating-system state only reachable through `os:getenv`.
@external(erlang, "provider_ffi", "get_env")
pub fn get_env(name: String) -> Result(String, Nil)
