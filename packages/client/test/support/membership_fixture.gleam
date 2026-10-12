//// Fixtures for the membership ledger tests: a fake signature scheme and
//// helpers that build entries. `membership_log` builds whole logs on top.
////
//// The scheme is an HMAC-SHA-256 under a fixed key. It stands in for the
//// authority's ECDSA key because the ledger takes its signer and verifier as
//// injected functions, so every rule the ledger enforces can be exercised
//// without a certificate. `membership_signing_test` runs the same entries
//// through the real key. A "wrong key" verifier is here too, for the test that
//// a forged signature is refused.
////

import client/distribution_plan.{Executor}
import client/membership_entry.{
  type Entry, type Kind, type Member, type SignedEntry, type Signer,
  type Verifier, Authentic, Entry, Forged, Genesis, Member, NotInDirectory,
  Revoke,
}
import gleam/bit_array
import gleam/crypto
import gleam/option.{None}

/// The time every fixture entry carries. A second time is used to make a
/// different body at the same sequence number.
pub const stamp = "2026-10-11T18:02:11Z"

pub const other_stamp = "2026-10-12T09:00:00Z"

/// The fixed deployment id.
pub const deployment = "3f9c00112233445566778899aabbccdd"

// --- the fake scheme ---------------------------------------------------------

fn tag(message: BitArray, key: BitArray) -> BitArray {
  crypto.hmac(message, crypto.Sha256, key)
}

/// Signs with the fixed test key.
pub fn signer() -> Signer {
  fn(message) { Ok(tag(message, <<"test authority":utf8>>)) }
}

/// A signer under a different key, as a stranger would sign.
pub fn stranger_signer() -> Signer {
  fn(message) { Ok(tag(message, <<"someone else":utf8>>)) }
}

/// Verifies the fixed test key.
pub fn verifier() -> Verifier {
  fn(message, signature) {
    case
      crypto.secure_compare(signature, tag(message, <<"test authority":utf8>>))
    {
      True -> Authentic
      False -> Forged
    }
  }
}

// --- entries -----------------------------------------------------------------

/// A pin that is a function of a name and a generation, so a renewal is a new
/// generation.
pub fn pin_for(name: String, generation: Int) -> BitArray {
  crypto.hash(crypto.Sha256, <<name:utf8, 0, generation:size(32)>>)
}

/// An executor with no port, no directory standing and the given links.
pub fn member(name: String, links: List(String)) -> Member {
  Member(
    name:,
    node: "loom@" <> name <> ".example.net",
    host: name <> ".example.net",
    listen_port: None,
    role: Executor,
    directory: NotInDirectory,
    links:,
    pin: pin_for(name, 0),
  )
}

/// The genesis kind, naming the fixed authority fingerprint.
pub fn genesis_kind() -> Kind {
  Genesis(deployment:, authority: crypto.hash(crypto.Sha256, <<"ca":utf8>>))
}

/// A revoke of the member as it was last enrolled.
pub fn revoke_kind(name: String) -> Kind {
  Revoke(name:, pin: pin_for(name, 0), reason: "laptop lost")
}

/// An entry with the fixed time.
pub fn entry(seq: Int, prev: membership_entry.EntryId, kind: Kind) -> Entry {
  Entry(seq:, prev:, time: stamp, kind:)
}

/// Seals an entry under the fixed key.
pub fn seal(entry: Entry) -> SignedEntry {
  let assert Ok(signed) = membership_entry.seal(entry, signer())
    as "the fixture signer never fails"
  signed
}

/// The line of an entry sealed under the fixed key.
pub fn line(entry: Entry) -> BitArray {
  membership_entry.line(seal(entry))
}

/// The bytes of a string, for building lines by hand.
pub fn bytes(text: String) -> BitArray {
  bit_array.from_string(text)
}
