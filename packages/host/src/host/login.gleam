//// The browser login: a macaroon-style token the daemon mints and verifies
//// from one root key (protocol-change/065, "The browser login").
////
//// A login lets a browser come back to its home page a month after `loom ui`
//// opened it. The browser carries the token as a cookie. The daemon stores
//// the root key and one catalogue row for each login (so it can be revoked)
//// and never stores a token, so everything a token says is checked here from
//// the token's own contents and the root key.
////
//// The construction is the first-party macaroon and nothing more. A token is
//// an identifier, a list of caveats and an HMAC-SHA256 chain over them: the
//// first signature is keyed by the root key and covers the identifier, and
//// each caveat is signed with the signature before it. So a holder of a token
//// can append a caveat and compute the new signature (`append`), and nobody
//// without the root key can remove or change one. There are no third-party
//// caveats and no discharges, because nothing here would call them.
////
//// The identifier is not secret, and nothing may authenticate with it alone.
//// This module cannot enforce that, since it knows nothing of the catalogue;
//// `row_digest` is the only place the identifier becomes a credential digest,
//// and the catalogue's lookup names the credential kind that digest belongs
//// to (`storage/access`, `Browser`), so a bearer's lookup never finds it.
////
//// This module is pure apart from the root key's file, which `probe_root`
//// reads and writes through the same private-file rules `owner.token` uses.
//// The clock and the entropy are arguments, so a test moves time and draws
//// fixed bytes. The cryptography is `crypto.hmac` and `crypto.secure_compare`
//// and nothing else: a signature is never compared with `==`.
////
//// ## Flow
////
//// `issue` → `parse` → `verify` → `intersect` → `check`, or `open` for all of
//// them
////
//// 1. `issue` draws nothing: it signs the six caveats a login is minted with
////    under an identifier the caller drew and returns the token.
//// 2. `parse` reads the grammar, refusing a token over 384 bytes before it
////    reads a field and any uppercase hex digit anywhere.
//// 3. `verify` recomputes the chain from the root key and compares it with
////    the token's signature in constant time.
//// 4. `intersect` takes what the caveats allow together, narrowing on every
////    repeat and refusing a name it does not know.
//// 5. `check` holds the allowance to the request: the path's key, the
////    posted nonce and the clock.

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap

/// How long a login lives from its minting, in milliseconds: thirty days.
/// The expiry is fixed when the login is minted and never extended by use.
pub const lifetime_ms = 2_592_000_000

/// The longest token the parser reads, in bytes. It is the longest the
/// grammar allows with a 128-byte principal identifier, and the parser refuses
/// anything longer before it reads a field, so a request stuffed with bytes
/// costs one length check.
pub const max_token_bytes = 384

/// The file in the state directory that holds the root key, beside
/// `owner.token`.
pub const root_file = "browser.key"

// The longest value a caveat holds, in bytes: a principal identifier's bound.
const max_value_bytes = 128

// The alphabet of a caveat value, which is the alphabet of a principal
// identifier, so an identifier is a value as it stands. `:` and `|` are legal
// in a cookie value and outside it, so a token parses without escaping.
const value_alphabet =
  "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"

const hex_alphabet = "0123456789abcdef"

/// The most a login may be narrowed to: the ceiling of every page it mints.
pub type Ceiling {
  /// Pages the login mints may only watch.
  Observer

  /// Pages the login mints may operate, within the role the principal holds.
  Operator
}

/// One `name=value` statement a token makes.
pub type Caveat {
  Caveat(
    /// One lowercase letter.
    name: String,
    /// One to 128 bytes of `[A-Za-z0-9._-]`.
    value: String,
  )
}

/// A token that has been read and not yet verified. Its fields are the
/// token's own claims, so nothing about it may be believed until `verify`.
pub opaque type Parsed {
  Parsed(id: String, caveats: List(Caveat), signature: BitArray)
}

/// A login's root key: 32 bytes from the operating system's cryptographic
/// source. It verifies every login, so it never leaves the daemon's host and
/// is never derived from, or written into, a token.
pub opaque type RootKey {
  RootKey(bytes: BitArray)
}

/// What the caveats of one verified token allow together, after every repeat
/// has narrowed.
pub type Allowance {
  Allowance(
    /// Whose login it is.
    principal: String,
    /// The most a page the login mints may do.
    ceiling: Ceiling,
    /// The instant, in unix milliseconds, from which the login is refused.
    expires_at_ms: Int,
    /// The login key: the cookie's path and the route's key must be this.
    key: String,
    /// The SHA-256 of the login nonce the browser must post.
    nonce_digest: String,
    /// The one session the login is narrowed to, when a caveat narrowed it.
    /// A login narrowed to a session mints a page of that session and never a
    /// home.
    session: Option(String),
  )
}

/// A token whose chain verified and whose caveats hold for the request.
pub type Login {
  Login(
    /// The login's identifier, whose `row_digest` is its catalogue row.
    id: String,
    /// What the login allows.
    allowance: Allowance,
  )
}

/// Why a token was refused. A request that carries one is answered `401` with
/// a fixed document and no echo, so none of these reaches a person; they let a
/// test say which rule refused.
pub type Refusal {
  /// The token is longer than `max_token_bytes`.
  TooLong

  /// The token does not parse as the grammar, or has an uppercase hex digit.
  Malformed

  /// The signature is not the chain's.
  BadSignature

  /// One of the six caveats a login is minted with is missing.
  MissingCaveat(name: String)

  /// A caveat names something this module does not know.
  UnknownCaveat(name: String)

  /// A caveat's value is not one its name takes.
  BadCaveat(name: String)

  /// A caveat that may not repeat with another value did.
  ConflictingCaveat(name: String)

  /// Two different sessions were named, so the login allows nothing.
  NothingAllowed

  /// The path's key is not the login key.
  WrongKey

  /// The posted nonce is not the one the login was minted with.
  WrongNonce

  /// The login's expiry has come.
  Expired
}

/// What the root key's file said at start.
pub type Probe {
  /// The file held a key, which is the key.
  Present(key: RootKey)

  /// There was no file. Every login minted under the lost key can no longer
  /// verify, so the caller revokes their rows and then asks `write_root` for a
  /// new key.
  Absent
}

/// What a login is minted with.
pub type Minting {
  Minting(
    /// Whose login it is.
    principal: String,
    /// The ceiling of every page the login mints.
    ceiling: Ceiling,
    /// The instant the login ends, in unix milliseconds.
    expires_at_ms: Int,
    /// The login key, 32 lowercase hex digits (`fresh_key`).
    key: String,
    /// The SHA-256 of the login nonce (`nonce_digest`).
    nonce_digest: String,
  )
}

/// Whether a value is login-shaped, meaning it begins with `loomb1:`. A login is
/// a cookie a browser holds and never a credential a terminal presents, so a
/// value of this shape offered as a bearer is refused before any connection, as
/// a claim token is: presenting it would fail anyway, and refusing it names the
/// mistake. It is a courtesy to the person and not a defence; the daemon refuses
/// every string that is not a 64-digit bearer.
///
/// ## Examples
///
/// ```gleam
/// assert login.is_login_shaped("loomb1:00:p=a:00")
/// assert !login.is_login_shaped(string.repeat("a", 64))
/// ```
pub fn is_login_shaped(value: String) -> Bool {
  string.starts_with(value, "loomb1:")
}

/// Whether a value has the shape of a login key: 32 lowercase hexadecimal
/// digits. A route under `/ui/l` names a login only by one.
///
/// ## Examples
///
/// ```gleam
/// assert login.is_key(string.repeat("a", 32))
/// assert !login.is_key("abc")
/// ```
pub fn is_key(value: String) -> Bool {
  is_hex(value, 32)
}

/// Draws a fresh login identifier: the hex of 16 bytes.
///
/// ## Examples
///
/// ```gleam
/// assert string.byte_size(login.fresh_id(crypto.strong_random_bytes)) == 32
/// ```
pub fn fresh_id(entropy: fn(Int) -> BitArray) -> String {
  hex(entropy(16))
}

/// Draws a fresh login key, the path a login's cookie is scoped to: the hex of
/// 16 bytes.
///
/// ## Examples
///
/// ```gleam
/// assert string.byte_size(login.fresh_key(crypto.strong_random_bytes)) == 32
/// ```
pub fn fresh_key(entropy: fn(Int) -> BitArray) -> String {
  hex(entropy(16))
}

/// Draws a fresh login nonce, which the browser keeps and the daemon does not:
/// the hex of 32 bytes.
///
/// ## Examples
///
/// ```gleam
/// assert string.byte_size(login.fresh_nonce(crypto.strong_random_bytes)) == 64
/// ```
pub fn fresh_nonce(entropy: fn(Int) -> BitArray) -> String {
  hex(entropy(32))
}

/// The SHA-256 of a login nonce as the browser posts it, in lowercase hex.
/// This is the value of the `n` caveat: the daemon keeps the digest in the
/// token and never the nonce.
///
/// ## Examples
///
/// ```gleam
/// assert string.byte_size(login.nonce_digest("00")) == 64
/// ```
pub fn nonce_digest(nonce: String) -> String {
  sha256_hex(nonce)
}

/// The credential digest of the login with this identifier: the SHA-256 of
/// the identifier's 32 ASCII characters, in lowercase hex. It is the key of
/// the login's catalogue row. The identifier is public, so this digest must
/// only ever be looked up as a `Browser` credential.
///
/// ## Examples
///
/// ```gleam
/// assert string.byte_size(login.row_digest(string.repeat("a", 32))) == 64
/// ```
pub fn row_digest(id: String) -> String {
  sha256_hex(id)
}

/// Draws a root key from `entropy`: 32 bytes.
///
/// ## Examples
///
/// ```gleam
/// // let key = login.draw_root(crypto.strong_random_bytes)
/// ```
pub fn draw_root(entropy: fn(Int) -> BitArray) -> RootKey {
  RootKey(entropy(32))
}

/// Reads the root key at `<state_root>/browser.key`, which is the first half of
/// what a daemon start does about logins. A file that holds a key is the key. A
/// file that is present and not readable, that is not the daemon's own private
/// regular file, or that is not exactly a 32-byte key refuses start and is never
/// regenerated: a key that was tampered with or truncated is not a reason to
/// quietly start a new family of logins. A missing file is `Absent`, which is
/// the owner's whole-daemon revocation, and the caller finishes it.
///
/// The key is kept as 64 lowercase hex characters, as `owner.token` is, because
/// the private-file writer takes text. The 32 bytes are what the hex decodes to,
/// and a file of any other length is refused.
///
/// ## Examples
///
/// ```gleam
/// // login.probe_root("/home/o/.loom")
/// ```
pub fn probe_root(state_root: String) -> Result(Probe, String) {
  let path = state_root <> "/" <> root_file
  case bootstrap.path_exists(path) {
    True -> read_root(path) |> result.map(Present)
    False -> Ok(Absent)
  }
}

/// Draws a root key from `entropy`, writes it to `<state_root>/browser.key` at
/// mode `0600` and reads it back through the rule an existing key is read by,
/// so a directory that quietly changed what was written fails here and not at
/// the first login. It is the second half of a start that found no file, and it
/// runs after the rows of the lost key were revoked: a start that crashed
/// between the two finds no file again and revokes nothing more.
///
/// ## Examples
///
/// ```gleam
/// // login.write_root("/home/o/.loom", crypto.strong_random_bytes)
/// ```
pub fn write_root(
  state_root: String,
  entropy: fn(Int) -> BitArray,
) -> Result(RootKey, String) {
  let path = state_root <> "/" <> root_file
  use Nil <- result.try(
    bootstrap.atomic_write_private(path, root_text(draw_root(entropy)))
    |> result.map_error(fn(reason) {
      "the browser login key could not be written: " <> reason
    }),
  )
  read_root(path)
}

fn root_text(key: RootKey) -> String {
  hex(key.bytes)
}

fn read_root(path: String) -> Result(RootKey, String) {
  use bytes <- result.try(
    bootstrap.read_private_bounded(path, 4096)
    |> result.map_error(fn(reason) {
      "the browser login key " <> path <> " is unusable: " <> reason
    }),
  )
  let refused = "the browser login key " <> path <> " is not a 32-byte key"
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(refused),
  )
  use <- bool.guard(when: !is_hex(text, 64), return: Error(refused))
  use decoded <- result.map(
    bit_array.base16_decode(text) |> result.replace_error(refused),
  )
  RootKey(decoded)
}

/// Mints a login's token: the identifier and the six caveats, `p`, `c`, `r`,
/// `e`, `k` and `n`, in that order, under the chain the root key starts.
///
/// ## Examples
///
/// ```gleam
/// // login.issue(root, id, Minting("owner-1", login.Operator, expiry, key, digest))
/// ```
pub fn issue(root: RootKey, id: String, minting: Minting) -> String {
  let ceiling = case minting.ceiling {
    Observer -> "observer"
    Operator -> "operator"
  }
  let caveats = [
    Caveat("p", minting.principal),
    Caveat("c", ceiling),
    Caveat("r", "workspace"),
    Caveat("e", int.to_string(minting.expires_at_ms)),
    Caveat("k", minting.key),
    Caveat("n", minting.nonce_digest),
  ]
  sign(root, id, caveats)
}

/// Signs `caveats` under `id` and returns the token text. It checks nothing
/// about what the caveats say: `intersect` is where a token's meaning is
/// judged, so a test can sign a token the daemon would never mint.
///
/// ## Examples
///
/// ```gleam
/// // login.sign(root, id, [login.Caveat("s", "0198")])
/// ```
pub fn sign(root: RootKey, id: String, caveats: List(Caveat)) -> String {
  let signature = chain(root, id, caveats)
  render(id, caveats, hex(signature))
}

/// Appends one caveat to a parsed token and returns the narrower token. The
/// new signature is computed from the old one alone, which is the macaroon
/// property: whoever holds a token can narrow it without the root key, and
/// nobody can widen it. The result verifies against the same root key.
///
/// ## Examples
///
/// ```gleam
/// // login.append(parsed, login.Caveat("c", "observer"))
/// ```
pub fn append(token: Parsed, caveat: Caveat) -> String {
  let signature = extend(token.signature, caveat)
  render(token.id, list.append(token.caveats, [caveat]), hex(signature))
}

/// Reads a token's grammar. The length is checked before a field is read, a
/// token with an uppercase hex digit anywhere is refused and not lowered, and
/// nothing here says the token is genuine: that is `verify`.
///
/// ## Examples
///
/// ```gleam
/// assert login.parse("nonsense") == Error(login.Malformed)
/// ```
pub fn parse(token: String) -> Result(Parsed, Refusal) {
  use <- bool.guard(
    when: string.byte_size(token) > max_token_bytes,
    return: Error(TooLong),
  )
  use #(id, text, signature) <- result.try(case string.split(token, ":") {
    ["loomb1", id, caveats, signature] -> Ok(#(id, caveats, signature))
    _ -> Error(Malformed)
  })
  use <- bool.guard(when: !is_hex(id, 32), return: Error(Malformed))
  use <- bool.guard(when: !is_hex(signature, 64), return: Error(Malformed))
  use caveats <- result.try(
    string.split(text, "|") |> list.try_map(parse_caveat),
  )
  use signature <- result.map(
    bit_array.base16_decode(signature) |> result.replace_error(Malformed),
  )
  Parsed(id, caveats, signature)
}

fn parse_caveat(text: String) -> Result(Caveat, Refusal) {
  case string.split(text, "=") {
    [name, value] ->
      case valid_name(name) && valid_value(value) {
        True -> Ok(Caveat(name, value))
        False -> Error(Malformed)
      }
    _ -> Error(Malformed)
  }
}

/// The identifier of a parsed token, which the daemon never trusts until the
/// chain has verified.
///
/// ## Examples
///
/// ```gleam
/// // login.id(parsed)
/// ```
pub fn id(token: Parsed) -> String {
  token.id
}

/// Checks that the token's signature is the chain the root key makes of its
/// identifier and caveats, comparing in constant time. A forged or altered
/// token is `BadSignature`, and nothing after this should run on one.
///
/// ## Examples
///
/// ```gleam
/// // login.verify(root, parsed) == Ok(Nil)
/// ```
pub fn verify(root: RootKey, token: Parsed) -> Result(Nil, Refusal) {
  let expected = chain(root, token.id, token.caveats)
  case crypto.secure_compare(expected, token.signature) {
    True -> Ok(Nil)
    False -> Error(BadSignature)
  }
}

/// What the token's caveats allow together. A name may repeat and a repeat
/// narrows: `c` takes the smallest ceiling and `e` the earliest instant, `s`
/// names one session and two different ones allow nothing, and `p`, `r`, `k`
/// and `n` may not repeat with another value. A wider repeat is ignored. A name
/// this module does not know refuses the token, and so does a missing one of
/// the six a login is minted with.
///
/// ## Examples
///
/// ```gleam
/// // login.intersect(parsed)
/// ```
pub fn intersect(token: Parsed) -> Result(Allowance, Refusal) {
  use Nil <- result.try(list.try_each(token.caveats, known))
  let values =
    list.fold(token.caveats, dict.new(), fn(found, caveat) {
      let earlier = dict.get(found, caveat.name) |> result.unwrap([])
      dict.insert(found, caveat.name, list.append(earlier, [caveat.value]))
    })
  use principal <- result.try(same(values, "p"))
  use reach <- result.try(same(values, "r"))
  use <- bool.guard(when: reach != "workspace", return: Error(BadCaveat("r")))
  use key <- result.try(same(values, "k"))
  use <- bool.guard(when: !is_hex(key, 32), return: Error(BadCaveat("k")))
  use digest <- result.try(same(values, "n"))
  use <- bool.guard(when: !is_hex(digest, 64), return: Error(BadCaveat("n")))
  use ceiling <- result.try(narrowest_ceiling(values))
  use expires_at_ms <- result.try(earliest_expiry(values))
  use session <- result.map(one_session(values))
  Allowance(
    principal:,
    ceiling:,
    expires_at_ms:,
    key:,
    nonce_digest: digest,
    session:,
  )
}

/// Holds an allowance to one request: the key in the path must be the login
/// key, the nonce the browser posted must hash to the nonce digest, and the
/// expiry must be after `now_ms`. Keys and digests are compared in constant
/// time.
///
/// ## Examples
///
/// ```gleam
/// // login.check(allowance, now_ms, key_from_path, nonce_from_body)
/// ```
pub fn check(
  allowance: Allowance,
  now_ms now_ms: Int,
  key key: String,
  nonce nonce: String,
) -> Result(Nil, Refusal) {
  use <- bool.guard(when: !equal(allowance.key, key), return: Error(WrongKey))
  use <- bool.guard(
    when: !equal(allowance.nonce_digest, nonce_digest(nonce)),
    return: Error(WrongNonce),
  )
  case allowance.expires_at_ms > now_ms {
    True -> Ok(Nil)
    False -> Error(Expired)
  }
}

/// Reads `token`, verifies its chain, takes the intersection of its caveats
/// and holds the result to the request, in that order and with no other
/// effect, so a request that fails any step has asked nobody anything. A caller
/// with several candidate cookie values tries each and takes the first that
/// opens, which is how a value planted under a longer path is passed over.
///
/// ## Examples
///
/// ```gleam
/// // login.open(root, token, now_ms: now, key: key, nonce: nonce)
/// ```
pub fn open(
  root: RootKey,
  token: String,
  now_ms now_ms: Int,
  key key: String,
  nonce nonce: String,
) -> Result(Login, Refusal) {
  use parsed <- result.try(parse(token))
  use Nil <- result.try(verify(root, parsed))
  use allowance <- result.try(intersect(parsed))
  use Nil <- result.map(check(allowance, now_ms:, key:, nonce:))
  Login(parsed.id, allowance)
}

// A name this module knows. An unknown one refuses the token, so a caveat a
// later version adds is never silently ignored by an older daemon.
fn known(caveat: Caveat) -> Result(Nil, Refusal) {
  case caveat.name {
    "p" | "c" | "r" | "e" | "k" | "n" | "s" -> Ok(Nil)
    other -> Error(UnknownCaveat(other))
  }
}

// The one value a name that may not repeat with another value holds, whether
// it appears once or several times.
fn same(
  values: dict.Dict(String, List(String)),
  name: String,
) -> Result(String, Refusal) {
  case dict.get(values, name) {
    Error(Nil) -> Error(MissingCaveat(name))
    Ok([first, ..rest]) ->
      case list.all(rest, fn(other) { other == first }) {
        True -> Ok(first)
        False -> Error(ConflictingCaveat(name))
      }
    Ok([]) -> Error(MissingCaveat(name))
  }
}

fn narrowest_ceiling(
  values: dict.Dict(String, List(String)),
) -> Result(Ceiling, Refusal) {
  use found <- result.try(
    dict.get(values, "c") |> result.replace_error(MissingCaveat("c")),
  )
  use ceilings <- result.map(
    list.try_map(found, fn(value) {
      case value {
        "observer" -> Ok(Observer)
        "operator" -> Ok(Operator)
        _ -> Error(BadCaveat("c"))
      }
    }),
  )
  case list.contains(ceilings, Observer) {
    True -> Observer
    False -> Operator
  }
}

fn earliest_expiry(
  values: dict.Dict(String, List(String)),
) -> Result(Int, Refusal) {
  use found <- result.try(
    dict.get(values, "e") |> result.replace_error(MissingCaveat("e")),
  )
  use instants <- result.try(
    list.try_map(found, fn(value) {
      case is_digits(value) {
        True -> int.parse(value) |> result.replace_error(BadCaveat("e"))
        False -> Error(BadCaveat("e"))
      }
    }),
  )
  list.reduce(instants, int.min) |> result.replace_error(MissingCaveat("e"))
}

fn one_session(
  values: dict.Dict(String, List(String)),
) -> Result(Option(String), Refusal) {
  case dict.get(values, "s") {
    Error(Nil) -> Ok(None)
    Ok([first, ..rest]) ->
      case list.all(rest, fn(other) { other == first }) {
        True -> Ok(Some(first))
        False -> Error(NothingAllowed)
      }
    Ok([]) -> Ok(None)
  }
}

// The signature a token's chain ends in.
fn chain(root: RootKey, id: String, caveats: List(Caveat)) -> BitArray {
  let start =
    crypto.hmac(
      bit_array.from_string("loomb1:" <> id),
      crypto.Sha256,
      root.bytes,
    )
  list.fold(caveats, start, extend)
}

// One link of the chain: the caveat's text, keyed by the signature before it.
fn extend(signature: BitArray, caveat: Caveat) -> BitArray {
  crypto.hmac(
    bit_array.from_string(caveat.name <> "=" <> caveat.value),
    crypto.Sha256,
    signature,
  )
}

fn render(id: String, caveats: List(Caveat), signature: String) -> String {
  let text =
    caveats
    |> list.map(fn(caveat) { caveat.name <> "=" <> caveat.value })
    |> string.join("|")
  "loomb1:" <> id <> ":" <> text <> ":" <> signature
}

fn equal(left: String, right: String) -> Bool {
  crypto.secure_compare(
    bit_array.from_string(left),
    bit_array.from_string(right),
  )
}

fn valid_name(name: String) -> Bool {
  string.byte_size(name) == 1 && in_alphabet(name, "abcdefghijklmnopqrstuvwxyz")
}

fn valid_value(value: String) -> Bool {
  let size = string.byte_size(value)
  size >= 1 && size <= max_value_bytes && in_alphabet(value, value_alphabet)
}

fn is_hex(value: String, size: Int) -> Bool {
  string.byte_size(value) == size && in_alphabet(value, hex_alphabet)
}

fn is_digits(value: String) -> Bool {
  let size = string.byte_size(value)
  size >= 1 && size <= 15 && in_alphabet(value, "0123456789")
}

// Whether every byte of `value` is one of `alphabet`'s. Bytes and not
// graphemes, so a multi-byte character is outside every alphabet here.
fn in_alphabet(value: String, alphabet: String) -> Bool {
  all_bytes(bit_array.from_string(value), bit_array.from_string(alphabet))
}

fn all_bytes(rest: BitArray, allowed: BitArray) -> Bool {
  case rest {
    <<>> -> True
    <<byte:int, tail:bytes>> ->
      contains_byte(allowed, byte) && all_bytes(tail, allowed)
    _ -> False
  }
}

fn contains_byte(allowed: BitArray, byte: Int) -> Bool {
  case allowed {
    <<head:int, tail:bytes>> -> head == byte || contains_byte(tail, byte)
    _ -> False
  }
}

fn sha256_hex(text: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(text)) |> hex
}

fn hex(bytes: BitArray) -> String {
  bytes |> bit_array.base16_encode |> string.lowercase
}
