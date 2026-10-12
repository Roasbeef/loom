//// Test-side FFI (spec §0.2 confinement): a key the production code must
//// refuse. `client/internal/ffi_pki` only mints P-256 keys, so a test that
//// wants a well-formed key of another type has to ask OTP for it directly.

/// A freshly generated RSA private key as PEM. It decodes as a private key and
/// is not an EC key, which is the shape a signer built for the authority must
/// refuse when it is constructed.
@external(erlang, "client_test_ffi", "rsa_key_pem")
pub fn rsa_private_key() -> String
