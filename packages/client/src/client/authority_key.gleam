//// Custody of the authority key: how the key that signs a deployment's
//// certificates and ledger entries is kept on the operator's machine.
////
//// Before the membership ledger, `provision` threw the authority key away and
//// no key remained that could admit a node (protocol-change/078). A ledger
//// needs a signer for every later change (protocol-change/086), so the key has
//// to be kept, and a key kept on disk is only as safe as the file. This module
//// is the one place that decides how the file is written, read and protected.
//// A deployment that prefers no persistent key skips it with
//// `provision --drop-authority`.
////
//// ## What is stored
////
//// One directory per deployment, `<home>/.loom/authority/<deployment id>` by
//// default, mode 0700, holding three files mode 0600:
////
//// - `key.enc`, the authority private key sealed under a passphrase;
//// - `ca.pem`, the authority certificate, which `enroll` needs to issue a
////   node certificate;
//// - `ledger.log`, the operator's copy of the ledger.
////
//// No daemon reads this directory and no node holds the key.
////
//// ## The envelope
////
//// `key.enc` is one line of JSON whose first key is the format,
//// `loom-authority-key/1`. The format names the algorithms, so a change of
//// cipher or key derivation is a new format and a reader that does not know it
//// refuses it by name. The other keys are exactly `deployment`, `iterations`,
//// `salt`, `nonce`, `ciphertext` and `tag`. Binary values are unpadded
//// URL-safe base64, and a text that is not the canonical encoding of its bytes
//// is refused, as in the ledger's lines.
////
//// The key is PBKDF2 with HMAC-SHA256 over the passphrase and a random 16-byte
//// salt, at 600,000 iterations (the OWASP figure for this construction, and
//// also the floor 086 states; a reader refuses fewer). The cipher is
//// AES-256-GCM with a random 12-byte nonce. A fresh salt gives a fresh key for
//// every file, so each key encrypts one message and a random nonce cannot
//// repeat under it. The associated data is the format and the deployment id,
//// so a file moved to another deployment's directory, or edited to claim
//// another id, fails to open.
////
//// AES-GCM cannot say whether an open failed because the passphrase was wrong
//// or because the file was changed, and the module does not pretend to:
//// both are `Rejected`.
////
//// ## The seam
////
//// Everything that needs to sign goes through `signer`, which turns a
//// directory and a passphrase into a `membership_entry.Signer`. A keychain or
//// a hardware token replaces that one function, and nothing that holds a
//// `Signer` changes.
////
//// ## The passphrase
////
//// A passphrase is 12 to 1024 bytes. It is read from a terminal with echo off
//// (`passphrase_from_terminal`) or from a file the owner alone can read
//// (`passphrase_from_file`), which is how a test or a script supplies it. It is
//// never a command-line argument, because a process list would show it.

import client/distribution_bundle
import client/internal/ffi_pki
import client/membership_entry.{type Signer}
import client/membership_signing
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap
import simplifile

/// The marker the envelope's first key carries. A reader refuses any other
/// value, so a future layout is a new marker and not a reinterpretation.
pub const format = "loom-authority-key/1"

/// The name of the sealed key inside a deployment's authority directory.
pub const key_file = "key.enc"

/// The name of the authority certificate inside the directory.
pub const certificate_file = "ca.pem"

/// The name of the operator's copy of the ledger inside the directory.
pub const ledger_file = distribution_bundle.ledger_file

/// The PBKDF2 iteration count a new envelope uses.
pub const iterations = 600_000

/// The fewest iterations a reader accepts. An envelope below it was not
/// written by this module, and the count is what slows a guessing attack.
pub const minimum_iterations = 600_000

/// The most iterations a reader accepts, so a hostile file cannot make `open`
/// run for minutes.
pub const maximum_iterations = 10_000_000

/// The shortest passphrase, in bytes.
pub const minimum_passphrase_bytes = 12

/// The longest passphrase, in bytes.
pub const maximum_passphrase_bytes = 1024

// The envelope is a few hundred bytes. The bound is what `open_file` reads, so
// a file that was replaced with something large is refused unread.
const max_envelope_bytes = 8192

const salt_bytes = 16

const nonce_bytes = 12

const tag_bytes = 16

// A PEM EC key is about 230 bytes. The bound is generous and still refuses a
// ciphertext that is not a key.
const max_ciphertext_bytes = 4096

/// A passphrase. It is opaque so nothing prints one by accident: the only way
/// to make one is `passphrase`, and the only use of one is to derive a key.
pub opaque type Passphrase {
  Passphrase(bytes: BitArray)
}

/// How the shape of an envelope was wrong. No variant carries the file's
/// text.
pub type Defect {
  /// The text is not a JSON object.
  NotAnObject

  /// The keys are not exactly those of the format.
  KeysNotExact

  /// The named key is missing or holds a value the format refuses. The key is
  /// a field of the envelope, never file-chosen text.
  FieldInvalid(key: String)
}

/// Why custody of the key failed.
pub type KeyError {
  /// The passphrase is shorter than `minimum_passphrase_bytes`.
  PassphraseTooShort

  /// The passphrase is longer than `maximum_passphrase_bytes`.
  PassphraseTooLong

  /// The two entries of a new passphrase differ.
  PassphrasesDiffer

  /// There is no terminal to prompt on. The caller offers a passphrase file.
  NoTerminal

  /// The person at the terminal typed ^C or ^D.
  Cancelled

  /// The text is not an envelope.
  NotAnEnvelope(defect: Defect)

  /// The envelope's format is not `format`.
  UnsupportedFormat

  /// The envelope was sealed for another deployment.
  WrongDeployment

  /// The passphrase is wrong or the file was changed. The two cannot be told
  /// apart.
  Rejected

  /// The envelope opened and what it held is not an EC private key.
  NotASigningKey

  /// A sealed key is already kept at the path, and a key is never replaced.
  AlreadyKept(path: String)

  /// A file operation failed.
  Io(path: String, reason: String)
}

/// A sentence for an operator. It names the file or the rule and carries no
/// key, passphrase or envelope content.
///
/// ## Examples
///
/// ```gleam
/// authority_key.describe(authority_key.Rejected)
/// // -> "the passphrase is wrong, or the key file was changed"
/// ```
pub fn describe(error: KeyError) -> String {
  case error {
    PassphraseTooShort ->
      "the passphrase must be at least "
      <> int.to_string(minimum_passphrase_bytes)
      <> " bytes"
    PassphraseTooLong ->
      "the passphrase must be at most "
      <> int.to_string(maximum_passphrase_bytes)
      <> " bytes"
    PassphrasesDiffer -> "the two passphrases differ"
    Cancelled -> "the passphrase prompt was cancelled"
    NoTerminal ->
      "there is no terminal to ask for a passphrase on; pass "
      <> "--passphrase-file PATH"
    NotAnEnvelope(NotAnObject) -> "the key file is not a JSON object"
    NotAnEnvelope(KeysNotExact) ->
      "the key file does not have exactly the keys of " <> format
    NotAnEnvelope(FieldInvalid(key)) ->
      "the key file has an invalid `" <> key <> "`"
    UnsupportedFormat -> "the key file is not a " <> format <> " envelope"
    WrongDeployment -> "the key file belongs to another deployment"
    Rejected -> "the passphrase is wrong, or the key file was changed"
    NotASigningKey -> "the key file does not hold an EC private key"
    AlreadyKept(path) ->
      path <> " already holds an authority key, and a key is never replaced"
    Io(path, reason) -> path <> ": " <> reason
  }
}

// --- the passphrase ------------------------------------------------------

/// A passphrase from its text. The bounds are in bytes, so a multibyte
/// passphrase counts what it will hash.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_ok(authority_key.passphrase("correct horse battery"))
/// assert authority_key.passphrase("short") == Error(authority_key.PassphraseTooShort)
/// ```
pub fn passphrase(text: String) -> Result(Passphrase, KeyError) {
  let size = string.byte_size(text)
  case size < minimum_passphrase_bytes, size > maximum_passphrase_bytes {
    True, _ -> Error(PassphraseTooShort)
    _, True -> Error(PassphraseTooLong)
    False, False -> Ok(Passphrase(bytes: bit_array.from_string(text)))
  }
}

/// How many times a terminal asks.
pub type Asking {
  /// Once, to open a key that exists.
  AskOnce

  /// Twice, to catch a typing mistake in the passphrase of a new key.
  AskTwice
}

/// Reads a passphrase from the terminal with echo off. The terminal must be
/// one the VM can drive in raw mode, which `TERM` being set and standard input
/// being a terminal give it; otherwise the answer is `NoTerminal`.
///
/// ## Examples
///
/// ```gleam
/// authority_key.passphrase_from_terminal(authority_key.AskTwice)
/// ```
pub fn passphrase_from_terminal(
  asking: Asking,
) -> Result(Passphrase, KeyError) {
  use first <- result.try(ask("Authority key passphrase: "))
  use _ <- result.try(case asking {
    AskOnce -> Ok(Nil)
    AskTwice -> {
      use again <- result.try(ask("Repeat the passphrase: "))
      case again == first {
        True -> Ok(Nil)
        False -> Error(PassphrasesDiffer)
      }
    }
  })
  passphrase(first)
}

fn ask(prompt: String) -> Result(String, KeyError) {
  ffi_pki.read_secret(prompt)
  |> result.map_error(fn(defect) {
    case defect {
      ffi_pki.NoTerminal -> NoTerminal
      ffi_pki.Cancelled -> Cancelled
    }
  })
}

/// Reads a passphrase from a file. The file must be a regular file owned by
/// the caller with no permission for group or others, so a passphrase left in
/// a readable file is refused rather than used. One trailing newline is not
/// part of the passphrase.
///
/// ## Examples
///
/// ```gleam
/// authority_key.passphrase_from_file("/home/me/.loom/passphrase")
/// ```
pub fn passphrase_from_file(path: String) -> Result(Passphrase, KeyError) {
  use bytes <- result.try(
    bootstrap.read_private_bounded(path, maximum_passphrase_bytes + 2)
    |> result.map_error(fn(reason) { Io(path, reason) }),
  )
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error(Io(path, "the passphrase is not UTF-8 text")),
  )
  passphrase(strip_newline(text))
}

fn strip_newline(text: String) -> String {
  case string.ends_with(text, "\r\n"), string.ends_with(text, "\n") {
    True, _ -> string.drop_end(text, 2)
    _, True -> string.drop_end(text, 1)
    False, False -> text
  }
}

// --- the envelope --------------------------------------------------------

type Envelope {
  Envelope(
    deployment: String,
    iterations: Int,
    salt: BitArray,
    nonce: BitArray,
    ciphertext: BitArray,
    tag: BitArray,
  )
}

/// Seals a PEM private key under a passphrase for a deployment and returns the
/// text of the envelope, newline included. Salt and nonce are drawn fresh, so
/// two seals of the same key differ.
///
/// ## Examples
///
/// ```gleam
/// let text = authority_key.seal(key_pem, passphrase, deployment_id)
/// assert string.starts_with(text, "{\"format\":\"loom-authority-key/1\"")
/// ```
pub fn seal(key: String, passphrase: Passphrase, deployment: String) -> String {
  let salt = ffi_pki.random_bytes(salt_bytes)
  let nonce = ffi_pki.random_bytes(nonce_bytes)
  let derived = ffi_pki.derive_key(passphrase.bytes, salt, iterations)
  let #(ciphertext, tag) =
    ffi_pki.encrypt(
      derived,
      nonce,
      associated_data(deployment),
      bit_array.from_string(key),
    )
  encode(Envelope(deployment:, iterations:, salt:, nonce:, ciphertext:, tag:))
}

/// Opens an envelope for a deployment and returns the PEM key. The deployment
/// is compared before any key derivation, so a file for another deployment is
/// named as such and costs nothing.
///
/// ## Examples
///
/// ```gleam
/// authority_key.open(text, passphrase, deployment_id) // -> Ok(key_pem)
/// ```
pub fn open(
  text: String,
  passphrase: Passphrase,
  deployment: String,
) -> Result(String, KeyError) {
  use envelope <- result.try(decode_envelope(text))
  use _ <- result.try(case envelope.deployment == deployment {
    True -> Ok(Nil)
    False -> Error(WrongDeployment)
  })
  let derived =
    ffi_pki.derive_key(passphrase.bytes, envelope.salt, envelope.iterations)
  use plaintext <- result.try(
    ffi_pki.decrypt(
      derived,
      envelope.nonce,
      associated_data(envelope.deployment),
      envelope.ciphertext,
      envelope.tag,
    )
    |> result.replace_error(Rejected),
  )
  bit_array.to_string(plaintext) |> result.replace_error(Rejected)
}

// The format and the deployment id are authenticated with the ciphertext. The
// zero byte keeps the two from running together.
fn associated_data(deployment: String) -> BitArray {
  <<format:utf8, 0, deployment:utf8>>
}

fn encode(envelope: Envelope) -> String {
  let base64 = fn(bytes) {
    json.string(bit_array.base64_url_encode(bytes, False))
  }
  json.object([
    #("format", json.string(format)),
    #("deployment", json.string(envelope.deployment)),
    #("iterations", json.int(envelope.iterations)),
    #("salt", base64(envelope.salt)),
    #("nonce", base64(envelope.nonce)),
    #("ciphertext", base64(envelope.ciphertext)),
    #("tag", base64(envelope.tag)),
  ])
  |> json.to_string
  <> "\n"
}

// The decoder is total. The format is read first so that an envelope of a
// future format is named as unsupported and not as malformed, and the keys
// are then required to be exactly the format's.
fn decode_envelope(text: String) -> Result(Envelope, KeyError) {
  use fields <- result.try(
    json.parse(text, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(NotAnEnvelope(NotAnObject)),
  )
  use marker <- result.try(read(fields, "format", decode.string))
  use _ <- result.try(case marker == format {
    True -> Ok(Nil)
    False -> Error(UnsupportedFormat)
  })
  use _ <- result.try(case list.sort(dict.keys(fields), string.compare) {
    present if present == sorted_keys -> Ok(Nil)
    _ -> Error(NotAnEnvelope(KeysNotExact))
  })
  use deployment <- result.try(read(fields, "deployment", decode.string))
  use _ <- result.try(case is_deployment_id(deployment) {
    True -> Ok(Nil)
    False -> Error(NotAnEnvelope(FieldInvalid("deployment")))
  })
  use rounds <- result.try(read(fields, "iterations", decode.int))
  use _ <- result.try(
    case rounds >= minimum_iterations && rounds <= maximum_iterations {
      True -> Ok(Nil)
      False -> Error(NotAnEnvelope(FieldInvalid("iterations")))
    },
  )
  use salt <- result.try(binary(fields, "salt", salt_bytes, salt_bytes))
  use nonce <- result.try(binary(fields, "nonce", nonce_bytes, nonce_bytes))
  use ciphertext <- result.try(binary(
    fields,
    "ciphertext",
    1,
    max_ciphertext_bytes,
  ))
  use tag <- result.try(binary(fields, "tag", tag_bytes, tag_bytes))
  Ok(Envelope(deployment:, iterations: rounds, salt:, nonce:, ciphertext:, tag:))
}

const sorted_keys = [
  "ciphertext", "deployment", "format", "iterations", "nonce", "salt", "tag",
]

fn read(
  fields: Dict(String, Dynamic),
  key: String,
  decoder: decode.Decoder(a),
) -> Result(a, KeyError) {
  dict.get(fields, key)
  |> result.try(fn(value) {
    decode.run(value, decoder) |> result.replace_error(Nil)
  })
  |> result.replace_error(NotAnEnvelope(FieldInvalid(key)))
}

// A binary field: unpadded URL-safe base64 in the canonical encoding, whose
// decoded length is within the bounds.
fn binary(
  fields: Dict(String, Dynamic),
  key: String,
  least: Int,
  most: Int,
) -> Result(BitArray, KeyError) {
  use text <- result.try(read(fields, key, decode.string))
  let invalid = NotAnEnvelope(FieldInvalid(key))
  use bytes <- result.try(
    bit_array.base64_url_decode(text) |> result.replace_error(invalid),
  )
  let size = bit_array.byte_size(bytes)
  case
    bit_array.base64_url_encode(bytes, False) == text
    && size >= least
    && size <= most
  {
    True -> Ok(bytes)
    False -> Error(invalid)
  }
}

fn is_deployment_id(text: String) -> Bool {
  string.byte_size(text) == 32
  && list.all(string.to_graphemes(text), string.contains("0123456789abcdef", _))
}

// --- the directory -------------------------------------------------------

/// What `keep` stores for one deployment.
pub type Kept {
  Kept(
    /// The deployment id, 32 lowercase hex characters, which the envelope
    /// binds.
    deployment: String,
    /// PEM of the authority private key.
    key: String,
    /// PEM of the authority certificate.
    certificate: String,
    /// The text of the ledger file as provisioned.
    ledger: String,
  )
}

/// The default directory for a deployment's authority: below the home's
/// `.loom`, one directory per deployment, so a machine can hold several.
///
/// ## Examples
///
/// ```gleam
/// assert authority_key.default_directory("/home/me", "3f9c")
///   == "/home/me/.loom/authority/3f9c"
/// ```
pub fn default_directory(home: String, deployment: String) -> String {
  home <> "/.loom/authority/" <> deployment
}

/// Writes the authority's files into `directory`, which is created with mode
/// 0700. The sealed key is written last, and the call is refused before
/// anything is written when a sealed key is already there, so a key is never
/// replaced and a half-finished call can be repeated.
///
/// ## Examples
///
/// ```gleam
/// authority_key.keep(directory, kept, passphrase) // -> Ok(directory <> "/key.enc")
/// ```
pub fn keep(
  directory: String,
  kept: Kept,
  passphrase: Passphrase,
) -> Result(String, KeyError) {
  let key_path = directory <> "/" <> key_file
  use _ <- result.try(case bootstrap.path_exists(key_path) {
    True -> Error(AlreadyKept(key_path))
    False -> Ok(Nil)
  })
  use _ <- result.try(
    bootstrap.ensure_private_directory(directory)
    |> result.map_error(fn(reason) { Io(directory, reason) }),
  )
  use _ <- result.try(write(
    directory <> "/" <> certificate_file,
    kept.certificate,
  ))
  use _ <- result.try(write(directory <> "/" <> ledger_file, kept.ledger))
  use _ <- result.try(write(
    key_path,
    seal(kept.key, passphrase, kept.deployment),
  ))
  Ok(key_path)
}

fn write(path: String, content: String) -> Result(Nil, KeyError) {
  bootstrap.atomic_write_private(path, content)
  |> result.map_error(fn(reason) { Io(path, reason) })
}

/// Opens the sealed key of a deployment and returns its PEM. The file must be
/// private to its owner.
///
/// ## Examples
///
/// ```gleam
/// authority_key.load(directory, deployment_id, passphrase) // -> Ok(key_pem)
/// ```
pub fn load(
  directory: String,
  deployment: String,
  passphrase: Passphrase,
) -> Result(String, KeyError) {
  let path = directory <> "/" <> key_file
  use bytes <- result.try(
    bootstrap.read_private_bounded(path, max_envelope_bytes)
    |> result.map_error(fn(reason) { Io(path, reason) }),
  )
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error(NotAnEnvelope(NotAnObject)),
  )
  open(text, passphrase, deployment)
}

/// The signer for a deployment's ledger entries, from its kept key. This is
/// the one function a keychain or a hardware token replaces: everything that
/// signs holds the `Signer` and never the key.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(sign) = authority_key.signer(directory, deployment_id, passphrase)
/// membership_entry.seal(entry, sign)
/// ```
pub fn signer(
  directory: String,
  deployment: String,
  passphrase: Passphrase,
) -> Result(Signer, KeyError) {
  use key <- result.try(load(directory, deployment, passphrase))
  membership_signing.signer(key) |> result.replace_error(NotASigningKey)
}

/// Whether a directory already holds a sealed key.
///
/// ## Examples
///
/// ```gleam
/// authority_key.is_kept(directory) // -> True
/// ```
pub fn is_kept(directory: String) -> Bool {
  simplifile.is_file(directory <> "/" <> key_file) == Ok(True)
}
