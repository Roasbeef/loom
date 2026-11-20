//// What the daemon checks of a WebAuthn registration and a WebAuthn assertion
//// (protocol-change/127), as pure functions of the bytes a browser posted and
//// the facts the daemon holds. Nothing here reads a clock, a table or a request,
//// so every refusal can be reached from a test with a key made in the test.
////
//// ## What is verified, and what is left out
////
//// The daemon accepts one kind of credential: an ES256 key, which is ECDSA over
//// P-256 with SHA-256, with user verification and attestation `none`. A
//// registration therefore carries no signature to check, and the daemon does
//// not parse the credential's COSE key. The browser hands over the same key as
//// `SubjectPublicKeyInfo` DER (`getPublicKey()`), which `kryptos` reads and
//// whose curve it names, and the authenticator data (`getAuthenticatorData()`),
//// from which the daemon reads the flags and the credential id and nothing
//// else. A registration that lacks either is refused, and so is a key on any
//// curve but P-256. No custom Erlang or CBOR code is involved.
////
//// An assertion is verified in the order WebAuthn gives, narrowed to what this
//// daemon needs: the client data names `webauthn.get`, the challenge the daemon
//// issued, and the page's own origin byte for byte; the authenticator data
//// carries the hash of the relying party id the daemon expects, the user
//// present and user verified flags, and a counter that has not gone backwards;
//// and the signature verifies over the authenticator data followed by the
//// SHA-256 of the client data, under the key the daemon stored.
////
//// ## The signature counter
////
//// Passkeys that sync between a person's devices report a counter of zero for
//// good, so a zero is accepted when the stored counter is also zero. Any other
//// pair must increase: a counter that stays or falls says a second copy of the
//// credential signed, which is a clone and is refused.
////
//// ## Flow
////
//// `challenge_of` → `verify_registration` / `verify_assertion`
////
//// 1. `challenge_of` reads the challenge out of the client data, which is how
////    the server finds which of the challenges it issued a browser answers.
//// 2. `verify_registration` accepts a new credential and returns the key and
////    counter to store.
//// 3. `verify_assertion` accepts a sign-in and returns the counter to record.
////
//// Both go through `check_client_data` and `parse_authenticator_data`, so the
//// two ceremonies agree on what the origin, the relying party and the flags
//// must be.

import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import kryptos/ec
import kryptos/ecdsa
import kryptos/hash

/// What the daemon requires of a ceremony, from its own state and never from
/// the browser's claims.
pub type Expected {
  Expected(
    /// The page's origin as a browser writes it in `clientDataJSON`, which for a
    /// listed origin is the listed text, byte for byte.
    origin: String,
    /// The relying party id: the host of the page's origin, without a port.
    rp_id: String,
    /// The challenge the daemon issued for this ceremony, in the base64url text
    /// the browser echoes.
    challenge: String,
  )
}

/// What a browser posts to sign in, decoded from its base64url fields.
pub type Assertion {
  Assertion(
    /// The `clientDataJSON` bytes.
    client_data: BitArray,
    /// The authenticator data bytes the signature covers.
    authenticator_data: BitArray,
    /// The signature, an ASN.1 DER ECDSA value as WebAuthn defines ES256.
    signature: BitArray,
  )
}

/// What a browser posts to register a credential, decoded from its base64url
/// fields.
pub type Registration {
  Registration(
    /// The credential id the authenticator chose, as raw bytes.
    credential_id: BitArray,
    /// The `clientDataJSON` bytes.
    client_data: BitArray,
    /// The authenticator data of the attestation, which holds the credential
    /// data when the attested-credential flag is set.
    authenticator_data: BitArray,
    /// The credential's public key as `SubjectPublicKeyInfo` DER.
    public_key: BitArray,
  )
}

/// What the daemon stored for a credential, which an assertion is checked
/// against.
pub type Stored {
  Stored(
    /// The key, `SubjectPublicKeyInfo` DER.
    public_key: BitArray,
    /// The counter of the last accepted ceremony.
    sign_count: Int,
  )
}

/// What a verified registration yields: the key and the counter to store.
pub type Registered {
  Registered(public_key: BitArray, sign_count: Int)
}

/// Why a ceremony was refused. The server answers every one with the same
/// document; the reason is for the tests and the daemon's own log.
pub type Refusal {
  /// The client data is not the JSON object a browser writes.
  MalformedClientData

  /// The client data names another ceremony than the one being verified.
  WrongCeremony

  /// The client data names a challenge other than the one issued.
  WrongChallenge

  /// The client data names another origin than the page's, or says a frame of
  /// another origin made the call.
  WrongOrigin

  /// The authenticator data is shorter than its fixed part, or its credential
  /// data does not parse.
  MalformedAuthenticatorData

  /// The authenticator data hashes another relying party id than the daemon's.
  WrongRelyingParty

  /// The user present flag is clear.
  UserNotPresent

  /// The user verified flag is clear.
  UserNotVerified

  /// A registration without the public key or without attested credential data.
  MissingCredential

  /// The attested credential id is not the one the browser posted.
  CredentialMismatch

  /// The key is not a P-256 key in `SubjectPublicKeyInfo` DER of the expected
  /// size.
  UnsupportedKey

  /// The signature does not verify under the stored key.
  BadSignature

  /// The counter did not increase when either the stored one or the new one is
  /// not zero.
  CounterNotIncreased
}

/// The ceremony a client data names.
type Ceremony {
  Create
  Get
}

/// Whether the call came from the page itself or from a frame of another origin
/// inside it, which `crossOrigin` says.
type CrossOrigin {
  FromPage
  FromFrame
}

// The user present, user verified and attested credential data flags.
const present_flag = 0x01

const verified_flag = 0x04

const attested_flag = 0x40

// The size of a P-256 `SubjectPublicKeyInfo`, which the catalogue also holds
// as the size of every stored key.
const key_bytes = 91

/// The challenge the client data names, as text, for the server to look up
/// among the challenges it issued. It judges nothing else: a value that is not
/// a challenge the daemon issued is found missing there.
///
/// ## Examples
///
/// ```gleam
/// assert passkey.challenge_of(<<"{\"challenge\":\"abc\"}":utf8>>) == Ok("abc")
/// ```
pub fn challenge_of(client_data: BitArray) -> Result(String, Nil) {
  json.parse_bits(client_data, {
    use challenge <- decode.field("challenge", decode.string)
    decode.success(challenge)
  })
  |> result.replace_error(Nil)
}

/// Verifies a sign-in: the client data, the authenticator data and the
/// signature, against what the daemon expects and holds. The answer is the
/// counter to record, which is the authenticator data's.
///
/// ## Examples
///
/// ```gleam
/// // passkey.verify_assertion(expected, stored, assertion) == Ok(7)
/// ```
pub fn verify_assertion(
  expected: Expected,
  stored: Stored,
  assertion: Assertion,
) -> Result(Int, Refusal) {
  use Nil <- result.try(check_client_data(expected, Get, assertion.client_data))
  use data <- result.try(parse_authenticator_data(
    expected.rp_id,
    assertion.authenticator_data,
  ))
  use key <- result.try(read_key(stored.public_key))
  use Nil <- result.try(check_signature(key, assertion))
  use Nil <- result.map(check_counter(stored.sign_count, data.sign_count))
  data.sign_count
}

/// Verifies a registration: the client data and the authenticator data as for a
/// sign-in, that the attested credential id is the one the browser posted, and
/// that the key is an acceptable one. The answer is the key and counter to
/// store. No signature is verified, because attestation is `none`.
///
/// ## Examples
///
/// ```gleam
/// // passkey.verify_registration(expected, registration)
/// ```
pub fn verify_registration(
  expected: Expected,
  registration: Registration,
) -> Result(Registered, Refusal) {
  use Nil <- result.try(check_client_data(
    expected,
    Create,
    registration.client_data,
  ))
  use data <- result.try(parse_authenticator_data(
    expected.rp_id,
    registration.authenticator_data,
  ))
  use attested <- result.try(result.replace_error(
    data.credential_id,
    MissingCredential,
  ))
  use Nil <- result.try(same_credential(attested, registration.credential_id))
  use _key <- result.map(read_key(registration.public_key))
  Registered(public_key: registration.public_key, sign_count: data.sign_count)
}

// What authenticator data holds that a ceremony here reads: the counter and,
// when the credential data is attached, the credential id.
type Data {
  Data(sign_count: Int, credential_id: Result(BitArray, Nil))
}

/// The credential id the authenticator attested is the one the browser posted,
/// so the key a registration stores is filed under the id the authenticator will
/// present at sign-in.
fn same_credential(
  attested: BitArray,
  posted: BitArray,
) -> Result(Nil, Refusal) {
  // The two ids are equal bytes or the registration is for another credential.
  case attested == posted {
    True -> Ok(Nil)
    False -> Error(CredentialMismatch)
  }
}

/// The client data must name this ceremony, the issued challenge and this page's
/// origin, and must not say another origin's frame made the call. The fields are
/// compared in the order a browser would be refused for them, so the refusal
/// names the first thing that is wrong.
fn check_client_data(
  expected: Expected,
  ceremony: Ceremony,
  client_data: BitArray,
) -> Result(Nil, Refusal) {
  use #(kind, challenge, origin, cross) <- result.try(
    json.parse_bits(client_data, {
      use kind <- decode.field("type", decode.string)
      use challenge <- decode.field("challenge", decode.string)
      use origin <- decode.field("origin", decode.string)
      use cross <- decode.optional_field("crossOrigin", False, decode.bool)
      decode.success(
        #(kind, challenge, origin, case cross {
          True -> FromFrame
          False -> FromPage
        }),
      )
    })
    |> result.replace_error(MalformedClientData),
  )

  // The type string a browser writes for this ceremony.
  let named = case ceremony {
    Create -> "webauthn.create"
    Get -> "webauthn.get"
  }

  // The ceremony, then the challenge, then the origin, each refused on its own.
  case kind == named, challenge == expected.challenge {
    False, _ -> Error(WrongCeremony)
    True, False -> Error(WrongChallenge)
    True, True -> check_origin(expected, claimed_origin(origin, cross))
  }
}

/// The origin the client data claims, or nothing when it says a frame of another
/// origin made the call: such a call is for another page whatever origin it names.
fn claimed_origin(origin: String, cross: CrossOrigin) -> Option(String) {
  // A cross-origin call has no origin that could equal the page's.
  case cross {
    FromFrame -> None
    FromPage -> Some(origin)
  }
}

/// The origin the client data names is the page's, byte for byte, and no frame of
/// another origin made the call.
fn check_origin(
  expected: Expected,
  claimed: Option(String),
) -> Result(Nil, Refusal) {
  // A signature for another scheme, host or port is for another service.
  case claimed == Some(expected.origin) {
    True -> Ok(Nil)
    False -> Error(WrongOrigin)
  }
}

/// The fixed part of authenticator data, checked for the relying party and the
/// flags, and, when the attested credential data flag is set, the credential id
/// that data begins with. The answer is the counter and that id.
fn parse_authenticator_data(
  rp_id: String,
  bytes: BitArray,
) -> Result(Data, Refusal) {
  use #(rp_hash, flags, count, rest) <- result.try(fixed_part(bytes))
  use Nil <- result.try(check_relying_party(rp_hash, rp_id))
  use Nil <- result.try(require(flags, present_flag, UserNotPresent))
  use Nil <- result.map(require(flags, verified_flag, UserNotVerified))

  // The credential id is read only when the flag says credential data follows.
  case int.bitwise_and(flags, attested_flag) {
    0 -> Data(sign_count: count, credential_id: Error(Nil))
    _ -> Data(sign_count: count, credential_id: attested_id(rest))
  }
}

/// The 37 fixed bytes of authenticator data: the relying party id hash, one byte
/// of flags and a four-byte counter, with whatever follows them.
fn fixed_part(
  bytes: BitArray,
) -> Result(#(BitArray, Int, Int, BitArray), Refusal) {
  // Fewer than 37 bytes is not authenticator data.
  case bytes {
    <<rp_hash:bytes-size(32), flags:8, count:32, rest:bits>> ->
      Ok(#(rp_hash, flags, count, rest))
    _ -> Error(MalformedAuthenticatorData)
  }
}

/// The hash in the authenticator data is the hash of the relying party id the
/// daemon expects, so a signature made for another site's passkey is refused.
fn check_relying_party(
  rp_hash: BitArray,
  rp_id: String,
) -> Result(Nil, Refusal) {
  // The hash is compared whole; it is not secret.
  case rp_hash == crypto.hash(crypto.Sha256, bit_array.from_string(rp_id)) {
    True -> Ok(Nil)
    False -> Error(WrongRelyingParty)
  }
}

/// The credential id in attested credential data: sixteen bytes of authenticator
/// model id, a two-byte length, and then that many bytes. The key that follows is
/// not read, because the browser hands the key over as `SubjectPublicKeyInfo`.
fn attested_id(rest: BitArray) -> Result(BitArray, Nil) {
  // Data that is shorter than its own length field says does not parse.
  case rest {
    <<_model:bytes-size(16), length:16, id:bytes-size(length), _key:bits>> ->
      Ok(id)
    _ -> Error(Nil)
  }
}

/// A flag of the authenticator data that must be set, or the refusal for it.
fn require(flags: Int, flag: Int, refusal: Refusal) -> Result(Nil, Refusal) {
  // Masking the flag out leaves zero exactly when it is clear.
  case int.bitwise_and(flags, flag) {
    0 -> Error(refusal)
    _ -> Ok(Nil)
  }
}

/// A stored or posted key, read as a P-256 key in the one size the catalogue
/// holds. A parse that succeeds on another curve is still refused.
fn read_key(der: BitArray) -> Result(ec.PublicKey, Refusal) {
  use key <- result.try(parse_key(der))

  // The curve is named by the parsed key, and only P-256 is accepted.
  case ec.public_key_curve(key) {
    ec.P256 -> Ok(key)
    ec.P384 | ec.P521 | ec.Secp256k1 -> Error(UnsupportedKey)
  }
}

/// The key's DER parsed, when it has the size of a P-256 key.
fn parse_key(der: BitArray) -> Result(ec.PublicKey, Refusal) {
  // A key of another size is another curve or not a key, and is not parsed.
  case bit_array.byte_size(der) == key_bytes {
    True -> ec.public_key_from_der(der) |> result.replace_error(UnsupportedKey)
    False -> Error(UnsupportedKey)
  }
}

/// ES256 over the authenticator data followed by the hash of the client data;
/// the verify function hashes that message once with SHA-256, as WebAuthn
/// defines the signature.
fn check_signature(
  key: ec.PublicKey,
  assertion: Assertion,
) -> Result(Nil, Refusal) {
  let digest = crypto.hash(crypto.Sha256, assertion.client_data)
  let message = <<assertion.authenticator_data:bits, digest:bits>>

  // The signature verifies under the stored key or the assertion is refused.
  case
    ecdsa.verify(
      key,
      message,
      signature: assertion.signature,
      hash: hash.Sha256,
    )
  {
    True -> Ok(Nil)
    False -> Error(BadSignature)
  }
}

/// Zero beside zero is an authenticator that does not count; any other pair must
/// have gone up.
fn check_counter(stored: Int, reported: Int) -> Result(Nil, Refusal) {
  // Either both are zero or the reported counter rose.
  case stored == 0 && reported == 0 || reported > stored {
    True -> Ok(Nil)
    False -> Error(CounterNotIncreased)
  }
}
