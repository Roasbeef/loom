//// The authority key's side of the membership ledger: the signer an operator's
//// tool uses and the verifier every node uses.
////
//// `client/membership_entry` and `client/membership_ledger` take their signer
//// and verifier as function values, so the ledger rules never touch a key.
//// This module builds the real pair from the PEM files a deployment already
//// has. A node holds the authority certificate as its `ca` file and builds a
//// verifier from it; the operator holds the authority key and builds a signer.
//// No node holds the key, and a verifier cannot sign.
////
//// The signature is ECDSA over P-256 with SHA-256, DER encoded, and the bytes
//// signed already carry the ledger's domain prefix
//// (`membership_entry.signing_input`). Certificate validity dates are not
//// consulted: a ledger signed by an authority whose certificate has since
//// expired is still a ledger that authority wrote.

import client/internal/ffi_pki
import client/membership_entry.{type Signer, type Verifier, Authentic, Forged}
import gleam/result

/// A signer for the authority key, given as the PEM `provision` wrote. The key
/// is tried once on an empty message, so a PEM that is not an EC private key
/// fails here and not at the first entry.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(sign) = membership_signing.signer(authority_key_pem)
/// membership_entry.seal(entry, sign)
/// ```
pub fn signer(authority_key: String) -> Result(Signer, Nil) {
  use _ <- result.try(ffi_pki.sign(authority_key, <<>>))
  Ok(fn(message) { ffi_pki.sign(authority_key, message) })
}

/// A verifier for the authority certificate, given as the PEM a node holds as
/// its `ca` file. A PEM that is not one readable certificate fails here, so a
/// node does not start with a verifier that refuses every line.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(verify) = membership_signing.verifier(ca_pem)
/// membership_ledger.replay(lines, verify)
/// ```
pub fn verifier(authority_certificate: String) -> Result(Verifier, Nil) {
  use _ <- result.try(ffi_pki.pin(authority_certificate))
  Ok(fn(message, signature) {
    case ffi_pki.verify(authority_certificate, message, signature) {
      Ok(Nil) -> Authentic
      Error(Nil) -> Forged
    }
  })
}

/// The SHA-256 of the DER of the authority certificate: the value a genesis
/// entry's `authority` carries and a node compares with the ledger it loads.
///
/// ## Examples
///
/// ```gleam
/// membership_signing.authority_pin(ca_pem) // -> Ok(<<32 bytes>>)
/// ```
pub fn authority_pin(authority_certificate: String) -> Result(BitArray, Nil) {
  ffi_pki.pin(authority_certificate)
}
