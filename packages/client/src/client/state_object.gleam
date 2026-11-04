//// The description of a repository state, and the pure decisions made about
//// it (protocol-change/107, "The state object").
////
//// A state is a Git bundle named by the SHA-256 of its bytes. Capture
//// (`client/repository_snapshot`) produces the bundle, the store
//// (`client/state_store`) keeps it under that hash, and apply
//// (`client/state_apply`) unpacks it on a receiving node. All three need to
//// agree on what a state is, on which commits make a bundle thin, and on what
//// the bundle's own header may say, and none of those questions needs a
//// repository or a process, so they live here and are tested without either.
////
//// The state description is the five fields of 107: the hash, the size, the
//// tip commit the bundle delivers, the base commit it is thin against, and
//// whether the tip is a snapshot of uncommitted work. A state that arrives
//// from a peer is a claim. `verify_bundle` compares it with the bundle's
//// bytes before anything is applied, so that a wrong hash, a truncated file, a
//// tip the bundle does not carry and a base the bundle does not need are each
//// refused by a comparison and not by trusting the peer.
////
//// ## Flow
////
//// `validate` → `verify_bundle` → `parse_header` → `agrees`
////
//// 1. `validate` accepts a description only when its hash, size and commit
////    ids have the shape the rest of the code builds paths and commands from.
//// 2. `verify_bundle` checks the size and the hash of the bytes, then reads
////    the header with `parse_header` and compares it with the description
////    through `agrees`.
//// 3. `choose_basis` is the sender's half of thin capture: it picks the
////    newest commit the receiver reports holding, or asks for a full bundle.

import gleam/bit_array
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap

/// The largest bundle a state may be, in bytes. 107 carries 256 MiB over from
/// the session move as a placeholder; a limit is a disk and memory question as
/// much as a link one. A bundle over it is refused with a reason, never cut
/// down.
pub const size_limit = 268_435_456

/// The ref every state bundle carries its tip under. A bundle holds exactly
/// this one ref, so a receiver never has to choose among a peer's names.
pub const bundle_ref = "refs/loom/snapshot"

/// The most commits a sender offers a receiver as candidate bases: `HEAD` and
/// its first-parent chain, 16 in all, plus the merge base with the upstream
/// branch.
pub const candidate_limit = 16

/// Whether a state's tip records uncommitted work.
pub type Dirtiness {
  /// The tip is a commit the repository already had, usually `HEAD`. Nothing
  /// was uncommitted.
  Clean

  /// The tip is a snapshot commit on top of `HEAD` whose tree is the working
  /// tree's bytes, untracked files included.
  Dirty
}

/// The plain data that names a bundle.
pub type State {
  State(
    /// SHA-256 of the bundle file, lower-case hex.
    hash: String,
    /// Bytes of the bundle file, at least one.
    size: Int,
    /// The commit the bundle delivers, as a full lower-case object id.
    tip: String,
    /// A commit the bundle is thin against, or `None` for a full bundle. The
    /// receiver must already hold it, and so its ancestry.
    base: Option(String),
    /// Whether `tip` is a snapshot of uncommitted work.
    dirty: Dirtiness,
  )
}

/// What a capture bundles against.
pub type Basis {
  /// Every commit reachable from the tip. The only shape that needs nothing
  /// from the receiver.
  Full

  /// Only the commits the receiver lacks. `base` is a commit it reported
  /// holding.
  Thin(
    /// A full object id of a commit that is an ancestor of the source `HEAD`.
    base: String,
  )
}

/// What a bundle file says about itself before its pack begins.
pub type Header {
  Header(
    /// The commits the receiver must hold. Empty for a full bundle.
    prerequisites: List(String),
    /// Each ref the bundle carries, as an object id and a name.
    refs: List(#(String, String)),
  )
}

// --- the description ------------------------------------------------------------

/// Whether text is a full Git object id: 40 or 64 lower-case hex digits.
/// Anything built into a path or a command goes through this first, so a peer's
/// text never reaches either as an option or a path component.
///
/// ## Examples
///
/// ```gleam
/// assert state_object.is_object_id("0123456789abcdef0123456789abcdef01234567")
/// assert !state_object.is_object_id("HEAD")
/// ```
pub fn is_object_id(text: String) -> Bool {
  let length = bounded_length(text)
  { length == 40 || length == 64 } && is_lower_hex(text)
}

/// Whether text is a bundle's SHA-256: 64 lower-case hex digits.
///
/// ## Examples
///
/// ```gleam
/// assert !state_object.is_hash("../etc/passwd")
/// ```
pub fn is_hash(text: String) -> Bool {
  bounded_length(text) == 64 && is_lower_hex(text)
}

/// The length of the text, or 65 when it is longer. Text from a peer is
/// measured by its first 65 characters, so a long one costs no more than a
/// short one.
fn bounded_length(text: String) -> Int {
  string.length(string.slice(text, 0, 65))
}

/// Whether every character is a lower-case hexadecimal digit. The empty text
/// passes, so callers check the length as well.
fn is_lower_hex(text: String) -> Bool {
  list.all(string.to_graphemes(text), fn(grapheme) {
    string.contains("0123456789abcdef", grapheme)
  })
}

/// The SHA-256 of a bundle's bytes in the spelling a state uses.
///
/// ## Examples
///
/// ```gleam
/// assert state_object.hash_of(<<>>)
///   == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
/// ```
pub fn hash_of(bytes: BitArray) -> String {
  bootstrap.sha256(bytes) |> bit_array.base16_encode |> string.lowercase
}

/// The first eight digits of a state's hash, which name the ref a receiver
/// keeps the state under.
///
/// ## Examples
///
/// ```gleam
/// assert state_object.short("0123456789abcdef") == "01234567"
/// ```
pub fn short(hash: String) -> String {
  string.slice(hash, 0, 8)
}

/// The ref a receiver imports a state to: `refs/loom/in/<hash8>`. It is the
/// only ref an apply writes besides the session's own new branch.
///
/// ## Examples
///
/// ```gleam
/// assert state_object.incoming_ref("0123456789abcdef") == "refs/loom/in/01234567"
/// ```
pub fn incoming_ref(hash: String) -> String {
  "refs/loom/in/" <> short(hash)
}

/// Accepts a description only when its parts have the shapes the rest of the
/// code relies on: a hash that is 64 lower-case hex digits, a positive size,
/// and full object ids for the tip and the base.
///
/// ## Examples
///
/// ```gleam
/// assert state_object.validate(State("x", 1, "y", None, Clean)) == Error("the state's hash is not a SHA-256")
/// ```
pub fn validate(state: State) -> Result(State, String) {
  use <- bool.guard(
    when: !is_hash(state.hash),
    return: Error("the state's hash is not a SHA-256"),
  )
  use <- bool.guard(
    when: state.size < 1,
    return: Error("the state's size is not positive"),
  )
  use <- bool.guard(
    when: !is_object_id(state.tip),
    return: Error("the state's tip is not a full object id"),
  )

  // A base, when one is named, is held to the same shape as the tip.
  case option.map(state.base, is_object_id) {
    Some(False) -> Error("the state's base is not a full object id")
    Some(True) | None -> Ok(state)
  }
}

/// The state as JSON text, in the field order of 107.
///
/// ## Examples
///
/// ```gleam
/// // state_object.encode(state)
/// ```
pub fn encode(state: State) -> String {
  json.object([
    #("hash", json.string(state.hash)),
    #("size", json.int(state.size)),
    #("tip", json.string(state.tip)),
    #("base", json.nullable(state.base, json.string)),
    #("dirty", json.bool(is_dirty(state.dirty))),
  ])
  |> json.to_string
}

/// Reads a state from JSON text. Every field is required but `base`, which may
/// be absent or null, and the result must pass `validate`, so a decoded state
/// is always one the store and apply can use.
///
/// ## Examples
///
/// ```gleam
/// assert state_object.decode("{}") == Error("the text is not a state object")
/// ```
pub fn decode(text: String) -> Result(State, String) {
  use state <- result.try(
    json.parse(text, state_decoder())
    |> result.replace_error("the text is not a state object"),
  )
  validate(state)
}

/// Reads the five fields of a state. It checks shapes only; `validate` judges
/// the values.
fn state_decoder() -> decode.Decoder(State) {
  use hash <- decode.field("hash", decode.string)
  use size <- decode.field("size", decode.int)
  use tip <- decode.field("tip", decode.string)
  use base <- decode.optional_field(
    "base",
    None,
    decode.optional(decode.string),
  )
  use dirty <- decode.field(
    "dirty",
    decode.map(decode.bool, fn(flag) {
      case flag {
        True -> Dirty
        False -> Clean
      }
    }),
  )
  decode.success(State(hash:, size:, tip:, base:, dirty:))
}

/// The wire spells the question as a JSON boolean. The conversion happens at
/// this edge so that no function or record elsewhere carries a bare flag.
fn is_dirty(dirtiness: Dirtiness) -> Bool {
  case dirtiness {
    Dirty -> True
    Clean -> False
  }
}

// --- thin or full ---------------------------------------------------------------

/// Chooses what to bundle against. `candidates` are the commits the sender
/// offered, newest first, and `held` is the receiver's answer: the ones it
/// reports holding. The newest candidate the receiver holds becomes the base.
/// When it holds none, the answer is `Full`, because the limit on size is a
/// refusal and not a reason to guess.
///
/// ## Examples
///
/// ```gleam
/// assert state_object.choose_basis(["c3", "c2", "c1"], ["c1", "c2"]) == state_object.Thin("c2")
/// ```
///
/// ```gleam
/// assert state_object.choose_basis(["c3", "c2"], ["elsewhere"]) == state_object.Full
/// ```
pub fn choose_basis(candidates: List(String), held: List(String)) -> Basis {
  case list.find(candidates, fn(candidate) { list.contains(held, candidate) }) {
    Ok(base) -> Thin(base)
    Error(Nil) -> Full
  }
}

// --- the bundle's own account ---------------------------------------------------

/// Compares a state with the bytes it names, before anything is applied.
///
/// The checks run from the cheapest: the size, then the SHA-256 of the whole
/// file, then the bundle's header. A truncated file fails the size or the
/// hash. A bundle that is whole but is not the one described fails the header:
/// it must carry exactly one ref, `bundle_ref`, at the described tip, and it
/// must have prerequisites exactly when the state names a base. The header
/// cannot prove which commit is the base, because a bundle lists every boundary
/// commit and a merge can make that more than one. Holding the base is what
/// satisfies all of them, and the receiver checks that against its repository.
///
/// ## Examples
///
/// ```gleam
/// assert state_object.verify_bundle(state, <<>>)
///   == Error("the bundle is 0 bytes but the state declares 1")
/// ```
pub fn verify_bundle(state: State, bytes: BitArray) -> Result(Nil, String) {
  let size = bit_array.byte_size(bytes)
  use <- bool.lazy_guard(when: size != state.size, return: fn() {
    Error(
      "the bundle is "
      <> int.to_string(size)
      <> " bytes but the state declares "
      <> int.to_string(state.size),
    )
  })
  use <- bool.guard(
    when: hash_of(bytes) != state.hash,
    return: Error("the bundle's SHA-256 is not the state's hash"),
  )
  use header <- result.try(parse_header(bytes))
  agrees(state, header)
}

/// Whether a bundle header says what the state claims.
///
/// ## Examples
///
/// ```gleam
/// assert state_object.agrees(state, state_object.Header([], [])) == Error("the bundle must carry exactly one ref")
/// ```
pub fn agrees(state: State, header: Header) -> Result(Nil, String) {
  use #(oid, name) <- result.try(one_ref(header))
  use <- bool.guard(
    when: name != bundle_ref || oid != state.tip,
    return: Error("the bundle's ref is not the state's tip"),
  )

  // Prerequisites exist exactly when the state is thin.
  case state.base, header.prerequisites {
    None, [] -> Ok(Nil)
    Some(_), [_, ..] -> Ok(Nil)
    None, [_, ..] ->
      Error("the state declares a full bundle but the bundle has prerequisites")
    Some(_), [] -> Error("the state declares a base but the bundle is full")
  }
}

/// The one ref a state bundle carries, or the reason it does not have exactly
/// one.
fn one_ref(header: Header) -> Result(#(String, String), String) {
  case header.refs {
    [only] -> Ok(only)
    _ -> Error("the bundle must carry exactly one ref")
  }
}

// A header is a few lines. Reading past this many bytes without finding its
// end means the file is not a bundle.
const header_limit = 16_384

/// Reads the header of a bundle file: the signature line, the capability lines
/// of version 3, the prerequisite lines that start with `-`, and the ref lines,
/// up to the empty line that ends them. The pack that follows is not read.
///
/// A capability other than the object format is refused, because a filtered
/// bundle is a partial repository, which capture never produces and apply never
/// accepts.
///
/// ## Examples
///
/// ```gleam
/// assert state_object.parse_header(<<"not a bundle\n\n">>)
///   == Error("the file is not a Git bundle")
/// ```
pub fn parse_header(bytes: BitArray) -> Result(Header, String) {
  use lines <- result.try(header_lines(header_prefix(bytes), [], []))

  // The signature line names a bundle version that carries these entries.
  case lines {
    ["# v2 git bundle", ..rest] | ["# v3 git bundle", ..rest] ->
      list.try_fold(rest, Header([], []), header_entry)
      |> result.map(fn(header) {
        Header(
          prerequisites: list.reverse(header.prerequisites),
          refs: list.reverse(header.refs),
        )
      })
    _ -> Error("the file is not a Git bundle")
  }
}

/// The part of the file a header can be in. A file shorter than the limit is
/// all of it.
fn header_prefix(bytes: BitArray) -> BitArray {
  case bit_array.slice(bytes, 0, header_limit) {
    Ok(cut) -> cut
    Error(Nil) -> bytes
  }
}

/// Splits the prefix into ASCII lines and stops at the empty line. A byte
/// outside ASCII, or a prefix that ends first, means no header was found.
fn header_lines(
  bytes: BitArray,
  line: List(UtfCodepoint),
  lines: List(String),
) -> Result(List(String), String) {
  case bytes {
    <<10, rest:bits>> ->
      case line {
        [] -> Ok(list.reverse(lines))
        _ ->
          header_lines(rest, [], [
            string.from_utf_codepoints(list.reverse(line)),
            ..lines
          ])
      }
    <<byte, rest:bits>> if byte < 128 ->
      case string.utf_codepoint(byte) {
        Ok(point) -> header_lines(rest, [point, ..line], lines)
        Error(Nil) -> Error("the bundle header is malformed")
      }
    _ -> Error("the bundle header is truncated or malformed")
  }
}

/// Adds one header line after the signature to the accumulator, which holds
/// each list in reverse. `parse_header` turns them around once.
fn header_entry(header: Header, line: String) -> Result(Header, String) {
  case line {
    "@object-format=" <> _ -> Ok(header)
    "@" <> _ -> Error("the bundle uses a capability apply does not accept")
    "-" <> rest -> prerequisite_entry(header, rest)
    ref -> ref_entry(header, ref)
  }
}

/// Adds a prerequisite line, which is an object id and an optional comment.
fn prerequisite_entry(header: Header, rest: String) -> Result(Header, String) {
  let #(oid, _comment) =
    string.split_once(rest, " ") |> result.unwrap(#(rest, ""))
  use <- bool.guard(
    when: !is_object_id(oid),
    return: Error("a bundle prerequisite is not an object id"),
  )
  Ok(Header(..header, prerequisites: [oid, ..header.prerequisites]))
}

/// Adds a ref line, which is an object id and a ref name.
fn ref_entry(header: Header, ref: String) -> Result(Header, String) {
  use #(oid, name) <- result.try(
    string.split_once(ref, " ")
    |> result.replace_error("a bundle ref line is malformed"),
  )
  use <- bool.guard(
    when: !is_object_id(oid) || name == "",
    return: Error("a bundle ref line is malformed"),
  )
  Ok(Header(..header, refs: [#(oid, name), ..header.refs]))
}
