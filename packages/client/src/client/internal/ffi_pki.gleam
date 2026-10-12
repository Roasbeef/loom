//// X.509 minting and inspection for `loom distribution provision` and
//// `install`.
////
//// No Gleam library generates or signs a certificate, and the operator is not
//// asked to install openssl, so these operations go through OTP's
//// `public_key` and `crypto` applications in `client_pki_ffi.erl`. The
//// boundary is narrow on purpose: it mints, pins, inspects, and signs and
//// verifies raw bytes, and it knows nothing about plans, bundles, ledgers or
//// files. Only `client/distribution_bundle`, `client/distribution_provision`,
//// `client/authority_key` and `client/membership_signing` import it.
////
//// It also holds the primitives that seal the authority key at rest, because
//// the key those seal is the one this file's `authority` makes: PBKDF2 and
//// AES-256-GCM from OTP `crypto`, and a prompt that does not echo.

/// Why a node's credentials were refused. Each names the file that is wrong
/// and carries no certificate or key contents.
pub type Defect {
  /// The CA file is not exactly one PEM certificate.
  UnreadableAuthority

  /// The certificate file is not exactly one PEM certificate.
  UnreadableCertificate

  /// The key file is not exactly one PEM private key.
  UnreadableKey

  /// The certificate does not chain to the CA, or is outside its validity
  /// period.
  ChainRejected

  /// The key is not the private half of the certificate's public key.
  KeyMismatch
}

/// Mints a self-signed ECDSA P-256 certificate authority and returns its
/// certificate and private key as PEM.
///
/// OTP `public_key:generate_key/1`, `pkix_sign/2` and `pem_encode/1`.
///
/// ## Examples
///
/// ```gleam
/// let #(certificate, key) = ffi_pki.authority("loom deployment CA")
/// ```
@external(erlang, "client_pki_ffi", "authority")
pub fn authority(common_name: String) -> #(String, String)

/// Issues a node certificate under the authority. `names` are the DNS names it
/// carries; a name that is an IP literal also becomes an address entry.
///
/// ## Examples
///
/// ```gleam
/// ffi_pki.issue(ca, ca_key, "laptop", ["loom@laptop.example"])
/// ```
@external(erlang, "client_pki_ffi", "issue")
pub fn issue(
  ca_certificate: String,
  ca_key: String,
  common_name: String,
  names: List(String),
) -> Result(#(String, String), Nil)

/// The SHA-256 of the DER of the first certificate in a PEM: the pin a peer
/// row carries.
///
/// OTP `public_key:pem_decode/1` and `crypto:hash/2`; `gleam_stdlib` has no
/// PEM reader.
///
/// ## Examples
///
/// ```gleam
/// ffi_pki.pin(certificate_pem) // -> Ok(<<32 bytes>>)
/// ```
@external(erlang, "client_pki_ffi", "pin")
pub fn pin(certificate: String) -> Result(BitArray, Nil)

/// Checks a node's credentials against each other and returns the DNS names
/// the certificate carries.
///
/// OTP `public_key:pkix_path_validation/3` verifies the signature and the
/// validity period.
///
/// ## Examples
///
/// ```gleam
/// ffi_pki.inspect(ca_pem, certificate_pem, key_pem) // -> Ok(["loom@a.example"])
/// ```
@external(erlang, "client_pki_ffi", "inspect")
pub fn inspect(
  authority: String,
  certificate: String,
  key: String,
) -> Result(List(String), Defect)

/// Draws random bytes from the operating system's strong generator.
///
/// OTP `crypto:strong_rand_bytes/1`.
///
/// ## Examples
///
/// ```gleam
/// ffi_pki.random_bytes(24) // -> 24 bytes
/// ```
@external(erlang, "client_pki_ffi", "random_bytes")
pub fn random_bytes(count: Int) -> BitArray

/// Signs bytes with an ECDSA P-256 private key (PEM), as ECDSA with SHA-256,
/// and returns the DER signature. A key that is not one PEM EC private key
/// fails.
///
/// OTP `public_key:sign/3`; no Gleam package signs with an EC key.
///
/// ## Examples
///
/// ```gleam
/// ffi_pki.sign(key_pem, <<"message":utf8>>) // -> Ok(<<DER signature>>)
/// ```
@external(erlang, "client_pki_ffi", "sign")
pub fn sign(key: String, message: BitArray) -> Result(BitArray, Nil)

/// Checks a DER ECDSA P-256 SHA-256 signature against the public key of the
/// first certificate in a PEM. `Ok` means the signature is valid; an
/// unreadable certificate, a malformed signature and a wrong signature are all
/// `Error`.
///
/// OTP `public_key:verify/4`; no Gleam package verifies with an EC key.
///
/// ## Examples
///
/// ```gleam
/// ffi_pki.verify(certificate_pem, message, signature) // -> Ok(Nil)
/// ```
@external(erlang, "client_pki_ffi", "verify")
pub fn verify(
  certificate: String,
  message: BitArray,
  signature: BitArray,
) -> Result(Nil, Nil)

/// The 32-byte key a passphrase derives under a salt: PBKDF2 with HMAC-SHA256
/// and `iterations` rounds.
///
/// OTP `crypto:pbkdf2_hmac/5`; `gleam_crypto` has no key derivation, and the
/// rounds would be far slower in Gleam.
///
/// ## Examples
///
/// ```gleam
/// ffi_pki.derive_key(<<"passphrase":utf8>>, salt, 600_000) // -> <<32 bytes>>
/// ```
@external(erlang, "client_pki_ffi", "derive_key")
pub fn derive_key(
  passphrase: BitArray,
  salt: BitArray,
  iterations: Int,
) -> BitArray

/// Encrypts with AES-256-GCM under a 32-byte key and a 12-byte nonce, binding
/// `aad` to the result. It returns the ciphertext and the 16-byte tag.
///
/// OTP `crypto:crypto_one_time_aead/7`; `gleam_crypto` has no AEAD cipher.
///
/// ## Examples
///
/// ```gleam
/// let #(ciphertext, tag) = ffi_pki.encrypt(key, nonce, aad, plaintext)
/// ```
@external(erlang, "client_pki_ffi", "encrypt")
pub fn encrypt(
  key: BitArray,
  nonce: BitArray,
  aad: BitArray,
  plaintext: BitArray,
) -> #(BitArray, BitArray)

/// Decrypts what `encrypt` produced. A wrong key, nonce, ciphertext, tag or
/// associated data is the same `Error`.
///
/// OTP `crypto:crypto_one_time_aead/7`.
///
/// ## Examples
///
/// ```gleam
/// ffi_pki.decrypt(key, nonce, aad, ciphertext, tag) // -> Ok(plaintext)
/// ```
@external(erlang, "client_pki_ffi", "decrypt")
pub fn decrypt(
  key: BitArray,
  nonce: BitArray,
  aad: BitArray,
  ciphertext: BitArray,
  tag: BitArray,
) -> Result(BitArray, Nil)

/// Why a prompt could not read a line.
pub type PromptDefect {
  /// There is no terminal the VM can read without echo, so there is nothing to
  /// prompt on.
  NoTerminal

  /// The person at the terminal typed ^C or ^D.
  Cancelled
}

/// Prints `prompt` to standard error and reads one line from the terminal
/// without echo. The line does not include its newline.
///
/// OTP `shell:start_interactive({noshell, raw})` and `io:get_chars/2`:
/// `io:get_password/0` answers `enotsup` under `-noshell`, which is how the
/// daemon runs, and the VM's cooked mode echoes.
///
/// ## Examples
///
/// ```gleam
/// ffi_pki.read_secret("Passphrase: ") // -> Ok("correct horse")
/// ```
@external(erlang, "client_pki_ffi", "read_secret")
pub fn read_secret(prompt: String) -> Result(String, PromptDefect)
