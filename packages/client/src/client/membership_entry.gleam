//// One entry of the membership ledger, as bytes: the body a signer writes, the
//// line that carries it, and the total decoder every reader applies.
////
//// A distributed deployment trusts the nodes its ledger names
//// (protocol-change/086). The ledger is a file of signed lines, and a line
//// crosses machines: it is read from disk at boot, pulled from a peer that may
//// be about to be revoked, and carried on a USB stick to a node nothing else
//// reaches. This module is the boundary that turns such bytes into an `Entry`
//// or into a typed refusal. It holds no state and does no I/O, so every rule
//// here is a function of the bytes alone.
////
//// ## Why the signature is checked on the bytes received
////
//// A line is `<body>.<signature>`, each half the unpadded URL-safe base64 of
//// its bytes. The body is JSON written once by the signer, with the keys in a
//// fixed order and no insignificant whitespace. A reader never re-serializes
//// it. It verifies the signature over the exact bytes it received and only then
//// parses them, so two JSON texts that mean the same thing are still two
//// different entries, and no question of canonical JSON arises. The identity
//// of an entry is the SHA-256 of its body bytes, and the signature is not part
//// of it.
////
//// The signature covers `"loom-membership-ledger/1" 0x00 body`. The prefix
//// separates this use of the authority key from every other use of it, so a
//// signature made for a ledger entry cannot be replayed as anything else.
////
//// Signing and verifying are injected as function values (`Signer` and
//// `Verifier`). The ECDSA operations need OTP's `public_key`, which a pure
//// module cannot call, and a test of the format should not need a key.
//// `client/membership_signing` supplies the real pair.
////
//// ## How a line becomes an entry
////
//// `read` runs the first three acceptance steps of protocol-change/086 and
//// stops at the first failure:
////
//// 1. `parse_line` checks the line shape and the size bounds and decodes both
////    halves. A line with padding, whitespace, a second dot, a character
////    outside the base64 alphabet, or an encoding that is not the canonical
////    one for its bytes is malformed. The canonical-encoding rule closes a
////    malleability: without it a line could be altered in its last character
////    and still decode to the same bytes, so a flipped bit would go unnoticed.
//// 2. `verify` asks the injected verifier about the signature over
////    `signing_input`. Nothing is parsed before this passes.
//// 3. `decode_body` parses the verified bytes and requires exactly the keys
////    of the entry's kind and a valid value for each.
////
//// The reverse path is `seal`, which a signer's tool uses: `encode_body` writes
//// the bytes, the signer signs `signing_input`, and `line` frames the result.
//// `seal` does not check that the fields are valid. The fold in
//// `client/membership_ledger` does, and the signer's tool runs it before it
//// signs.

import client/distribution
import client/distribution_plan.{type Role}
import gleam/bit_array
import gleam/crypto
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import storage/catalogue

/// The marker every body carries in its `format` key. A reader refuses any
/// other value, so a future layout is a new marker and not a reinterpretation.
pub const format = "loom-membership-ledger/1"

/// The largest body a line may carry, in bytes after decoding.
pub const max_body_bytes = 4096

/// The largest signature a line may carry, in bytes after decoding. A DER
/// ECDSA P-256 signature is at most 72.
pub const max_signature_bytes = 80

/// The most links a member may list: every other member of a full deployment.
pub const max_links = 63

/// The longest `reason` of a revoke, in bytes.
pub const max_reason_bytes = 200

// The base64 length of the largest body and signature, unpadded. A line over
// these is refused before any decoding, so a hostile peer cannot make a node
// decode megabytes.
const max_body_text = 5462

const max_signature_text = 107

// --- identities --------------------------------------------------------------

/// The identity of an entry: the SHA-256 of its body bytes, 32 bytes. The type
/// is opaque so the only ways to hold one are to hash a body, to read the 64
/// hex characters a body carries, or to be handed 32 bytes.
pub opaque type EntryId {
  EntryId(digest: BitArray)
}

/// The identity of the body bytes.
///
/// ## Examples
///
/// ```gleam
/// assert membership_entry.id_to_hex(membership_entry.id_of_body(<<>>))
///   == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
/// ```
pub fn id_of_body(body: BitArray) -> EntryId {
  EntryId(crypto.hash(crypto.Sha256, body))
}

/// The `prev` of the genesis entry: 32 zero bytes.
///
/// ## Examples
///
/// ```gleam
/// assert string.length(membership_entry.id_to_hex(membership_entry.genesis_prev()))
///   == 64
/// ```
pub fn genesis_prev() -> EntryId {
  EntryId(<<0:size(256)>>)
}

/// The 64 lowercase hex characters a body carries for an identity.
///
/// ## Examples
///
/// ```gleam
/// assert membership_entry.id_to_hex(membership_entry.genesis_prev())
///   == string.repeat("0", 64)
/// ```
pub fn id_to_hex(id: EntryId) -> String {
  hex_of(id.digest)
}

/// The 32 bytes of an identity, as a `Head` message carries it.
///
/// ## Examples
///
/// ```gleam
/// assert membership_entry.id_to_bytes(membership_entry.genesis_prev())
///   == <<0:size(256)>>
/// ```
pub fn id_to_bytes(id: EntryId) -> BitArray {
  id.digest
}

/// An identity from exactly 32 bytes. Any other length is refused.
///
/// ## Examples
///
/// ```gleam
/// assert result.is_error(membership_entry.id_from_bytes(<<1, 2>>))
/// ```
pub fn id_from_bytes(bytes: BitArray) -> Result(EntryId, Nil) {
  case bit_array.byte_size(bytes) == 32 {
    True -> Ok(EntryId(bytes))
    False -> Error(Nil)
  }
}

// --- the entry ---------------------------------------------------------------

/// Whether a member takes part in the session directory (protocol-change/083).
pub type DirectoryStanding {
  /// A Ra voter. It counts toward the quorum once Ra promotes it.
  Voter

  /// A Ra member that replicates the directory and never votes.
  Learner

  /// Not a Ra member. The default for a laptop.
  NotInDirectory
}

/// The wire word of a directory standing.
///
/// ## Examples
///
/// ```gleam
/// assert membership_entry.directory_word(membership_entry.NotInDirectory)
///   == "none"
/// ```
pub fn directory_word(standing: DirectoryStanding) -> String {
  case standing {
    Voter -> "voter"
    Learner -> "learner"
    NotInDirectory -> "none"
  }
}

/// One node the ledger trusts.
pub type Member {
  Member(
    /// The plan name: the bundle name, and the default `[executors.<name>]`
    /// key. It satisfies `catalogue.is_executor_name`.
    name: String,
    /// The full Erlang node name, valid under `distribution.check_node_name`.
    /// The verify callback compares it with the certificate's node-name
    /// subject alternative name.
    node: String,
    /// The host other machines reach it at.
    host: String,
    /// The fixed distribution port, 1 through 65535, if there is one.
    listen_port: Option(Int),
    /// What the daemon does.
    role: Role,
    /// Whether it is a member of the session directory.
    directory: DirectoryStanding,
    /// Names of other members this member may connect to, at most
    /// `max_links`. The fold requires each to be an active member other than
    /// this one.
    links: List(String),
    /// The SHA-256 of the member's leaf certificate, 32 bytes.
    pin: BitArray,
  )
}

/// What an entry does.
pub type Kind {
  /// Starts the log. It is entry 0 and no other entry has this kind.
  Genesis(
    /// 32 lowercase hex characters, random, naming the deployment.
    deployment: String,
    /// The SHA-256 of the DER of the authority certificate, 32 bytes. A node
    /// compares it with its own `ca` file.
    authority: BitArray,
  )

  /// Enrolls, amends or renews the member of that name. The first entry for a
  /// name enrolls it, a later one with the same pin amends it, and a later one
  /// with a different pin renews it.
  Upsert(member: Member)

  /// Removes an active member.
  Revoke(
    /// The member removed.
    name: String,
    /// The pin it held, recorded for audit and not compared with the
    /// member's. 32 bytes.
    pin: BitArray,
    /// At most `max_reason_bytes` bytes of text with no control character.
    reason: String,
  )
}

/// The wire word of a kind: `genesis`, `member` or `revoke`.
///
/// ## Examples
///
/// ```gleam
/// assert membership_entry.kind_word(membership_entry.Revoke("a", <<>>, ""))
///   == "revoke"
/// ```
pub fn kind_word(kind: Kind) -> String {
  case kind {
    Genesis(..) -> "genesis"
    Upsert(..) -> "member"
    Revoke(..) -> "revoke"
  }
}

/// A decoded entry body.
pub type Entry {
  Entry(
    /// 0 for genesis, then one more than the previous entry.
    seq: Int,
    /// The identity of entry `seq - 1`, or `genesis_prev` for genesis.
    prev: EntryId,
    /// The signer's clock as `YYYY-MM-DDTHH:MM:SSZ`. Only the shape is
    /// checked, and no rule reads it.
    time: String,
    /// What the entry does.
    kind: Kind,
  )
}

/// An entry together with the exact bytes that were signed and the signature
/// over them. The bytes are kept because the identity and the signature belong
/// to them, and re-encoding the entry would not necessarily reproduce them.
pub type SignedEntry {
  SignedEntry(
    /// The decoded body.
    entry: Entry,
    /// The body bytes the signature covers.
    body: BitArray,
    /// The DER signature, at most `max_signature_bytes` bytes.
    signature: BitArray,
    /// The SHA-256 of `body`.
    id: EntryId,
  )
}

// --- signing and verifying ---------------------------------------------------

/// What a verifier says about a signature.
pub type Verdict {
  /// The signature is the authority's over the message.
  Authentic

  /// It is not, or the verifier could not check it.
  Forged
}

/// Checks a signature: `fn(message, signature) -> Verdict`, where the message
/// is `signing_input` of the body. A verifier is built from the authority
/// certificate and must answer `Forged` for anything it cannot verify.
pub type Verifier =
  fn(BitArray, BitArray) -> Verdict

/// Signs a message with the authority key, or fails.
pub type Signer =
  fn(BitArray) -> Result(BitArray, Nil)

/// The bytes a signature covers: the format marker, a zero byte and the body.
///
/// ## Examples
///
/// ```gleam
/// assert membership_entry.signing_input(<<"x":utf8>>)
///   == <<"loom-membership-ledger/1":utf8, 0, "x":utf8>>
/// ```
pub fn signing_input(body: BitArray) -> BitArray {
  <<format:utf8, 0, body:bits>>
}

/// Asks the verifier about the signature of a parsed line.
///
/// ## Examples
///
/// ```gleam
/// membership_entry.verify(raw, verifier) // -> Authentic
/// ```
pub fn verify(raw: RawLine, verifier: Verifier) -> Verdict {
  verifier(signing_input(raw.body), raw.signature)
}

/// Why a signer's tool could not produce a line.
pub type SealError {
  /// The signer returned no signature.
  SigningFailed

  /// The body or the signature is larger than a reader accepts, so the line
  /// would be refused everywhere.
  TooLarge
}

/// Writes the body, signs it and returns the entry with the bytes it was
/// signed over.
///
/// The fields are not validated here. A field the decoder would refuse makes a
/// line every node refuses, so a signer's tool runs `membership_ledger.check`
/// first, which also decodes what it encodes.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(signed) = membership_entry.seal(entry, signer)
/// ```
pub fn seal(entry: Entry, sign: Signer) -> Result(SignedEntry, SealError) {
  let body = encode_body(entry)
  use Nil <- result.try(within(body, max_body_bytes))
  use signature <- result.try(
    sign(signing_input(body)) |> result.replace_error(SigningFailed),
  )
  use Nil <- result.try(within(signature, max_signature_bytes))
  Ok(SignedEntry(entry:, body:, signature:, id: id_of_body(body)))
}

fn within(bytes: BitArray, limit: Int) -> Result(Nil, SealError) {
  case bit_array.byte_size(bytes) <= limit {
    True -> Ok(Nil)
    False -> Error(TooLarge)
  }
}

// --- the body ----------------------------------------------------------------

/// The body bytes of an entry: UTF-8 JSON with the keys of the format in
/// their fixed order and no whitespace. The signer writes these once; a reader
/// never produces them again.
///
/// ## Examples
///
/// ```gleam
/// membership_entry.encode_body(entry)
/// // -> <<"{\"format\":\"loom-membership-ledger/1\",\"seq\":0,..}">>
/// ```
pub fn encode_body(entry: Entry) -> BitArray {
  let common = [
    #("format", json.string(format)),
    #("seq", json.int(entry.seq)),
    #("prev", json.string(id_to_hex(entry.prev))),
    #("time", json.string(entry.time)),
    #("kind", json.string(kind_word(entry.kind))),
  ]
  json.object(list.append(common, kind_fields(entry.kind)))
  |> json.to_string
  |> bit_array.from_string
}

fn kind_fields(kind: Kind) -> List(#(String, json.Json)) {
  case kind {
    Genesis(deployment:, authority:) -> [
      #("deployment", json.string(deployment)),
      #("authority", json.string(hex_of(authority))),
    ]

    Upsert(member:) -> member_fields(member)

    Revoke(name:, pin:, reason:) -> [
      #("name", json.string(name)),
      #("pin", json.string(hex_of(pin))),
      #("reason", json.string(reason)),
    ]
  }
}

fn member_fields(member: Member) -> List(#(String, json.Json)) {
  let port = case member.listen_port {
    Some(number) -> [#("listen_port", json.int(number))]
    None -> []
  }
  list.flatten([
    [
      #("name", json.string(member.name)),
      #("node", json.string(member.node)),
      #("host", json.string(member.host)),
    ],
    port,
    [
      #("role", json.string(distribution_plan.role_word(member.role))),
      #("directory", json.string(directory_word(member.directory))),
      #("links", json.array(member.links, json.string)),
      #("pin", json.string(hex_of(member.pin))),
    ],
  ])
}

/// Why a line or a body was refused as malformed. No variant carries the
/// offending bytes, so a refusal can be logged without echoing a peer's input.
pub type Defect {
  /// The line is not text in the base64 alphabet with exactly one dot, or one
  /// of its halves is padded, empty, or not the canonical encoding of its
  /// bytes.
  LineShape

  /// The body is over `max_body_bytes`.
  BodyTooLarge

  /// The signature is over `max_signature_bytes`.
  SignatureTooLarge

  /// The body is not UTF-8.
  BodyNotText

  /// The body is not JSON.
  BodyNotJson

  /// The body is JSON and not an object.
  BodyNotObject

  /// The body's keys are not exactly those of its kind.
  KeysNotExact

  /// The named key is missing from where it is required or holds a value the
  /// format refuses. The key is a field of the body, never peer-chosen text.
  FieldInvalid(key: String)
}

/// Why a line did not become an entry: the steps of protocol-change/086 that
/// precede the fold.
pub type ReadError {
  /// Step 1 or step 3: the line or the body is malformed.
  Malformed(defect: Defect)

  /// Step 2: the signature does not verify.
  BadSignature

  /// Step 3: the body's `format` is not `format`.
  UnsupportedFormat
}

/// The step word the control protocol and the status report use.
///
/// ## Examples
///
/// ```gleam
/// assert membership_entry.read_error_word(membership_entry.BadSignature)
///   == "bad_signature"
/// ```
pub fn read_error_word(error: ReadError) -> String {
  case error {
    Malformed(_) -> "malformed"
    BadSignature -> "bad_signature"
    UnsupportedFormat -> "unsupported_format"
  }
}

/// Decodes verified body bytes. The decoder is total: it returns an `Entry` or
/// a `ReadError`, for every input, and requires exactly the keys of the
/// entry's kind.
///
/// ## Examples
///
/// ```gleam
/// assert membership_entry.decode_body(<<"[]":utf8>>)
///   == Error(membership_entry.Malformed(membership_entry.BodyNotObject))
/// ```
pub fn decode_body(body: BitArray) -> Result(Entry, ReadError) {
  use text <- result.try(
    bit_array.to_string(body) |> result.replace_error(Malformed(BodyNotText)),
  )
  use value <- result.try(
    json.parse(text, decode.dynamic)
    |> result.replace_error(Malformed(BodyNotJson)),
  )
  use fields <- result.try(
    decode.run(value, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(Malformed(BodyNotObject)),
  )

  // The format marker is read before the other keys, because a body of
  // another format may have different keys and should be reported as such.
  use Nil <- result.try(check_format(fields))
  use shape <- result.try(read_shape(fields))
  use Nil <- result.try(check_keys(fields, shape))
  decode.run(value, entry_decoder(shape))
  |> result.map_error(fn(errors) { Malformed(FieldInvalid(failed_key(errors))) })
}

// The three kinds as the decoder sees them. They select the key set and the
// field decoder, and nothing else.
type Shape {
  GenesisShape
  MemberShape
  RevokeShape
}

fn check_format(
  fields: dict.Dict(String, decode.Dynamic),
) -> Result(Nil, ReadError) {
  case dict.get(fields, "format") |> result.try(text_of_dynamic) {
    Ok(marker) if marker == format -> Ok(Nil)
    Ok(_) -> Error(UnsupportedFormat)
    Error(Nil) -> Error(Malformed(FieldInvalid("format")))
  }
}

fn text_of_dynamic(value: decode.Dynamic) -> Result(String, Nil) {
  decode.run(value, decode.string) |> result.replace_error(Nil)
}

fn read_shape(
  fields: dict.Dict(String, decode.Dynamic),
) -> Result(Shape, ReadError) {
  case dict.get(fields, "kind") |> result.try(text_of_dynamic) {
    Ok("genesis") -> Ok(GenesisShape)
    Ok("member") -> Ok(MemberShape)
    Ok("revoke") -> Ok(RevokeShape)
    Ok(_) | Error(Nil) -> Error(Malformed(FieldInvalid("kind")))
  }
}

// The keys a body of each kind carries after the five common ones. The member
// kind has one optional key, `listen_port`, so its required and allowed sets
// differ.
fn required_keys(shape: Shape) -> List(String) {
  let common = ["format", "seq", "prev", "time", "kind"]
  list.append(common, case shape {
    GenesisShape -> ["deployment", "authority"]
    MemberShape -> [
      "name",
      "node",
      "host",
      "role",
      "directory",
      "links",
      "pin",
    ]
    RevokeShape -> ["name", "pin", "reason"]
  })
}

fn allowed_keys(shape: Shape) -> List(String) {
  case shape {
    MemberShape -> ["listen_port", ..required_keys(shape)]
    GenesisShape | RevokeShape -> required_keys(shape)
  }
}

fn check_keys(
  fields: dict.Dict(String, decode.Dynamic),
  shape: Shape,
) -> Result(Nil, ReadError) {
  let allowed = allowed_keys(shape)
  let complete = list.all(required_keys(shape), dict.has_key(fields, _))
  let nothing_extra = list.all(dict.keys(fields), list.contains(allowed, _))
  case complete && nothing_extra {
    True -> Ok(Nil)
    False -> Error(Malformed(KeysNotExact))
  }
}

fn failed_key(errors: List(decode.DecodeError)) -> String {
  case errors {
    [decode.DecodeError(path: [key, ..], ..), ..] -> key
    [decode.DecodeError(path: [], ..), ..] | [] -> "body"
  }
}

fn entry_decoder(shape: Shape) -> decode.Decoder(Entry) {
  use seq <- decode.field("seq", natural_decoder())
  use prev <- decode.field("prev", id_decoder())
  use time <- decode.field("time", text_decoder(is_timestamp))
  use kind <- decode.then(kind_decoder(shape))
  decode.success(Entry(seq:, prev:, time:, kind:))
}

fn kind_decoder(shape: Shape) -> decode.Decoder(Kind) {
  case shape {
    GenesisShape -> {
      use deployment <- decode.field(
        "deployment",
        text_decoder(fn(text) { result.is_ok(parse_hex(text, 32)) }),
      )
      use authority <- decode.field("authority", hex_decoder(64))
      decode.success(Genesis(deployment:, authority:))
    }

    MemberShape -> {
      use member <- decode.then(member_decoder())
      decode.success(Upsert(member:))
    }

    RevokeShape -> {
      use name <- decode.field("name", text_decoder(catalogue.is_executor_name))
      use pin <- decode.field("pin", hex_decoder(64))
      use reason <- decode.field("reason", text_decoder(is_reason))
      decode.success(Revoke(name:, pin:, reason:))
    }
  }
}

fn member_decoder() -> decode.Decoder(Member) {
  use name <- decode.field("name", text_decoder(catalogue.is_executor_name))
  use node <- decode.field("node", text_decoder(is_node_name))
  use host <- decode.field("host", text_decoder(is_host))
  use listen_port <- decode.optional_field("listen_port", None, port_decoder())
  use role <- decode.field("role", role_decoder())
  use directory <- decode.field("directory", directory_decoder())
  use links <- decode.field("links", links_decoder())
  use pin <- decode.field("pin", hex_decoder(64))
  decode.success(Member(
    name:,
    node:,
    host:,
    listen_port:,
    role:,
    directory:,
    links:,
    pin:,
  ))
}

// --- field decoders ----------------------------------------------------------

// A string that satisfies a predicate. The placeholder in `decode.failure`
// is never returned to a caller: a failed decoder yields errors only.
fn text_decoder(accept: fn(String) -> Bool) -> decode.Decoder(String) {
  use text <- decode.then(decode.string)
  case accept(text) {
    True -> decode.success(text)
    False -> decode.failure("", "valid text")
  }
}

fn natural_decoder() -> decode.Decoder(Int) {
  use number <- decode.then(decode.int)
  case number >= 0 {
    True -> decode.success(number)
    False -> decode.failure(0, "non-negative integer")
  }
}

fn port_decoder() -> decode.Decoder(Option(Int)) {
  use number <- decode.then(decode.int)
  case number >= 1 && number <= 65_535 {
    True -> decode.success(Some(number))
    False -> decode.failure(None, "port")
  }
}

fn hex_decoder(digits: Int) -> decode.Decoder(BitArray) {
  use text <- decode.then(decode.string)
  case parse_hex(text, digits) {
    Ok(bytes) -> decode.success(bytes)
    Error(Nil) -> decode.failure(<<>>, "lowercase hex")
  }
}

fn id_decoder() -> decode.Decoder(EntryId) {
  use bytes <- decode.then(hex_decoder(64))
  decode.success(EntryId(bytes))
}

fn role_decoder() -> decode.Decoder(Role) {
  use word <- decode.then(decode.string)
  case distribution_plan.role_from_word(word) {
    Ok(role) -> decode.success(role)
    Error(_) -> decode.failure(distribution_plan.Orchestrator, "role")
  }
}

fn directory_decoder() -> decode.Decoder(DirectoryStanding) {
  use word <- decode.then(decode.string)
  case word {
    "voter" -> decode.success(Voter)
    "learner" -> decode.success(Learner)
    "none" -> decode.success(NotInDirectory)
    _ -> decode.failure(NotInDirectory, "directory standing")
  }
}

fn links_decoder() -> decode.Decoder(List(String)) {
  use links <- decode.then(
    decode.list(text_decoder(catalogue.is_executor_name)),
  )

  // Dropping the allowed prefix and testing for a remainder answers "more
  // than the limit" without walking the whole list.
  case list.drop(links, max_links) {
    [] -> decode.success(links)
    [_, ..] -> decode.failure([], "at most 63 links")
  }
}

// --- value checks ------------------------------------------------------------

fn is_node_name(text: String) -> Bool {
  result.is_ok(distribution.check_node_name("node", text))
}

// The host rule of `distribution_plan.check_node`: a DNS name or an address,
// at most 253 bytes.
fn is_host(text: String) -> Bool {
  let allowed =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.:_"
  text != ""
  && string.byte_size(text) <= 253
  && list.all(string.to_graphemes(text), string.contains(allowed, _))
}

fn is_reason(text: String) -> Bool {
  string.byte_size(text) <= max_reason_bytes
  && !distribution_plan.has_control_character(text)
}

// The shape `YYYY-MM-DDTHH:MM:SSZ`. The calendar is not checked, because no
// rule reads the time.
type Place {
  Digit
  Literal(code: Int)
}

fn is_timestamp(text: String) -> Bool {
  let shape = [
    Digit,
    Digit,
    Digit,
    Digit,
    Literal(45),
    Digit,
    Digit,
    Literal(45),
    Digit,
    Digit,
    Literal(84),
    Digit,
    Digit,
    Literal(58),
    Digit,
    Digit,
    Literal(58),
    Digit,
    Digit,
    Literal(90),
  ]
  let codes =
    list.map(string.to_utf_codepoints(text), string.utf_codepoint_to_int)
  matches_shape(codes, shape)
}

fn matches_shape(codes: List(Int), shape: List(Place)) -> Bool {
  case codes, shape {
    [], [] -> True
    [code, ..codes], [Digit, ..shape] ->
      code >= 48 && code <= 57 && matches_shape(codes, shape)
    [code, ..codes], [Literal(expected), ..shape] ->
      code == expected && matches_shape(codes, shape)
    [], [_, ..] | [_, ..], [] -> False
  }
}

// --- hex ---------------------------------------------------------------------

fn hex_of(bytes: BitArray) -> String {
  string.lowercase(bit_array.base16_encode(bytes))
}

// Exactly `digits` lowercase hex characters. `base16_decode` accepts both
// cases, so the case is checked by comparing the text with its lowercase.
fn parse_hex(text: String, digits: Int) -> Result(BitArray, Nil) {
  case string.byte_size(text) == digits && text == string.lowercase(text) {
    True -> bit_array.base16_decode(text)
    False -> Error(Nil)
  }
}

// --- the line ----------------------------------------------------------------

/// The two halves of a line, decoded but not yet verified or parsed.
pub type RawLine {
  RawLine(
    /// The body bytes the signature covers.
    body: BitArray,
    /// The signature bytes.
    signature: BitArray,
  )
}

/// Frames a body and its signature as a line, without the trailing newline
/// the file adds.
///
/// ## Examples
///
/// ```gleam
/// assert membership_entry.frame_line(<<"a":utf8>>, <<"b":utf8>>)
///   == <<"YQ.Yg":utf8>>
/// ```
pub fn frame_line(body: BitArray, signature: BitArray) -> BitArray {
  let text =
    bit_array.base64_url_encode(body, False)
    <> "."
    <> bit_array.base64_url_encode(signature, False)
  bit_array.from_string(text)
}

/// The line of a signed entry.
///
/// ## Examples
///
/// ```gleam
/// membership_entry.line(signed) // -> <<"eyJ..">>
/// ```
pub fn line(signed: SignedEntry) -> BitArray {
  frame_line(signed.body, signed.signature)
}

/// Step 1: checks the shape and size bounds of a line and decodes both halves.
/// Total over arbitrary bytes.
///
/// ## Examples
///
/// ```gleam
/// assert membership_entry.parse_line(<<"no dots":utf8>>)
///   == Error(membership_entry.LineShape)
/// ```
pub fn parse_line(line: BitArray) -> Result(RawLine, Defect) {
  use text <- result.try(
    bit_array.to_string(line) |> result.replace_error(LineShape),
  )
  use #(body_text, signature_text) <- result.try(split_halves(text))

  // The encoded size is bounded before decoding, so an oversized half costs a
  // length test and not a decode.
  use Nil <- result.try(
    bounded(body_text, max_body_text) |> result.replace_error(BodyTooLarge),
  )
  use Nil <- result.try(
    bounded(signature_text, max_signature_text)
    |> result.replace_error(SignatureTooLarge),
  )
  use body <- result.try(decode_half(body_text))
  use signature <- result.try(decode_half(signature_text))
  use Nil <- result.try(
    bounded_bytes(body, max_body_bytes) |> result.replace_error(BodyTooLarge),
  )
  use Nil <- result.try(
    bounded_bytes(signature, max_signature_bytes)
    |> result.replace_error(SignatureTooLarge),
  )
  Ok(RawLine(body:, signature:))
}

fn split_halves(text: String) -> Result(#(String, String), Defect) {
  case string.split(text, ".") {
    [body, signature] if body != "" && signature != "" -> Ok(#(body, signature))
    _ -> Error(LineShape)
  }
}

fn bounded(text: String, limit: Int) -> Result(Nil, Nil) {
  case string.byte_size(text) <= limit {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

fn bounded_bytes(bytes: BitArray, limit: Int) -> Result(Nil, Nil) {
  case bit_array.byte_size(bytes) <= limit {
    True -> Ok(Nil)
    False -> Error(Nil)
  }
}

// One half of a line. The alphabet test refuses padding and whitespace, and
// the re-encoding test refuses a text whose last character carries bits the
// bytes do not use.
fn decode_half(text: String) -> Result(BitArray, Defect) {
  let in_alphabet =
    list.all(string.to_utf_codepoints(text), fn(point) {
      is_base64_url(string.utf_codepoint_to_int(point))
    })
  use Nil <- result.try(case in_alphabet {
    True -> Ok(Nil)
    False -> Error(LineShape)
  })
  use bytes <- result.try(
    bit_array.base64_url_decode(text) |> result.replace_error(LineShape),
  )
  case bit_array.base64_url_encode(bytes, False) == text {
    True -> Ok(bytes)
    False -> Error(LineShape)
  }
}

fn is_base64_url(code: Int) -> Bool {
  { code >= 65 && code <= 90 }
  || { code >= 97 && code <= 122 }
  || { code >= 48 && code <= 57 }
  || code == 45
  || code == 95
}

/// Steps 1 through 3: parses a line, verifies its signature and decodes its
/// body. The result carries the exact bytes and the identity, which the fold
/// and the file need.
///
/// ## Examples
///
/// ```gleam
/// membership_entry.read(<<"garbage":utf8>>, verifier)
/// // -> Error(Malformed(LineShape))
/// ```
pub fn read(
  line: BitArray,
  verifier: Verifier,
) -> Result(SignedEntry, ReadError) {
  use raw <- result.try(parse_line(line) |> result.map_error(Malformed))

  // Nothing of the body is parsed before the signature passes.
  use Nil <- result.try(case verify(raw, verifier) {
    Authentic -> Ok(Nil)
    Forged -> Error(BadSignature)
  })
  use entry <- result.try(decode_body(raw.body))
  Ok(SignedEntry(
    entry:,
    body: raw.body,
    signature: raw.signature,
    id: id_of_body(raw.body),
  ))
}
