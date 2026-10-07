//// Canonical registered-generation identities shared by owner and executor.
////
//// A key names the whole immutable workspace authority and one connection
//// generation. An association also names the original enrollment, owner-use
//// UUID and closed predecessor evidence. These values convey identity, never
//// a startup claim, live door, retirement witness or authenticated authority.
//// The executor registry and owner companion consume the same canonical bytes.
////
//// `checked_first` and `checked_successor` compare configured lineage. Actual
//// predecessor COMMIT readbacks and original-owner authentication remain the
//// durable registry's responsibility. `decode_key` and `decode_association`
//// preflight bytes before materialization and reject noncanonical spellings.

import core/bounded_msgpack
import core/corruption.{type CorruptionReport}
import core/ids
import core/msgpack as mp
import core/workspace
import gleam/result

/// Largest supported positive connection generation.
pub const max_generation = 2_147_483_647

/// Fixed maximum for either complete canonical identity frame.
pub const max_identity_bytes = 1024

/// Exactly 32 bytes of canonical-content evidence, without a hashing claim.
pub opaque type Digest {
  /// Already checked fixed-width evidence.
  Digest(
    /// Original bytes, compared without normalization.
    bytes: BitArray,
  )
}

/// Full immutable scope, descriptor identity and checked connection generation.
pub opaque type GenerationKey {
  /// Every field participates in identity equality.
  GenerationKey(
    /// Session, registered selector and both authority epochs.
    scope: workspace.Scope,
    /// SHA-256 of the immutable deployment descriptor.
    descriptor: Digest,
    /// Positive signed-32-bit generation, never a transport nonce.
    generation: Int,
  )
}

/// Closed lineage evidence; digests alone do not certify physical retirement.
pub type Predecessor {
  /// The configured first generation has no predecessor.
  FirstGeneration

  /// The immediate predecessor's two independent committed records.
  Successor(
    /// Executor retirement record digest.
    node_retirement: Digest,
    /// Original owner's generation-close record digest.
    owner_close: Digest,
  )
}

/// Immutable association identifying one original owner door bundle.
pub opaque type GenerationAssociation {
  /// Equality includes every immutable association field.
  GenerationAssociation(
    /// Full generation identity.
    key: GenerationKey,
    /// SHA-256 of the original canonical enrollment snapshot.
    enrollment: Digest,
    /// Once-minted UUIDv7 identifying the original owner-use bundle.
    owner_use: ids.EntryId,
    /// Configured first generation or exact predecessor pair.
    predecessor: Predecessor,
  )
}

/// Fixed diagnostics never retain untrusted identity payloads.
pub type InputError {
  /// A digest did not contain exactly 32 bytes.
  DigestSize

  /// A generation was outside the positive signed-32-bit range.
  GenerationRange

  /// The association does not match configured first or successor lineage.
  LineageMismatch
}

/// Validates adapter-supplied digest bytes without hashing or authenticating.
///
/// ## Examples
///
/// ```gleam
/// assert generation.digest(<<>>) == Error(generation.DigestSize)
/// ```
pub fn digest(bytes: BitArray) -> Result(Digest, InputError) {
  case bytes {
    <<_:size(256)>> -> Ok(Digest(bytes))
    _ -> Error(DigestSize)
  }
}

/// Projects the original 32 bytes for hashing comparisons and wire adapters.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(hash) = generation.digest(<<0:size(256)>>)
/// assert generation.digest_bytes(hash) == <<0:size(256)>>
/// ```
pub fn digest_bytes(value: Digest) -> BitArray {
  value.bytes
}

/// Constructs a checked generation without allocating or advancing authority.
///
/// ## Examples
///
/// ```gleam
/// assert generation.key(scope, descriptor, 0) == Error(generation.GenerationRange)
/// ```
pub fn key(
  scope: workspace.Scope,
  descriptor: Digest,
  generation: Int,
) -> Result(GenerationKey, InputError) {
  case generation >= 1 && generation <= max_generation {
    True -> Ok(GenerationKey(scope, descriptor, generation))
    False -> Error(GenerationRange)
  }
}

/// Projects complete identity; a caller must compare every coordinate.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(key) = generation.key(scope, descriptor, 1)
/// assert generation.key_fields(key) == #(scope, descriptor, 1)
/// ```
pub fn key_fields(value: GenerationKey) -> #(workspace.Scope, Digest, Int) {
  #(value.scope, value.descriptor, value.generation)
}

/// Projects the unchanged full scope for existing registered service adapters.
///
/// ## Examples
///
/// ```gleam
/// assert generation.key_scope(key) == generation.key_fields(key).0
/// ```
pub fn key_scope(value: GenerationKey) -> workspace.Scope {
  value.scope
}

/// Assembles typed identity; use the lineage checks before durable admission.
///
/// ## Examples
///
/// ```gleam
/// let associated = generation.association(key, enrollment, owner_use, generation.FirstGeneration)
/// assert generation.association_key(associated) == key
/// ```
pub fn association(
  key: GenerationKey,
  enrollment: Digest,
  owner_use: ids.EntryId,
  predecessor: Predecessor,
) -> GenerationAssociation {
  GenerationAssociation(key, enrollment, owner_use, predecessor)
}

/// Projects all immutable association fields without granting live custody.
///
/// ## Examples
///
/// ```gleam
/// assert generation.association_fields(associated).0 == generation.association_key(associated)
/// ```
pub fn association_fields(
  value: GenerationAssociation,
) -> #(GenerationKey, Digest, ids.EntryId, Predecessor) {
  #(value.key, value.enrollment, value.owner_use, value.predecessor)
}

/// Projects the association's exact generation identity.
///
/// ## Examples
///
/// ```gleam
/// assert generation.association_key(associated) == generation.association_fields(associated).0
/// ```
pub fn association_key(value: GenerationAssociation) -> GenerationKey {
  value.key
}

/// Checks the configured first generation and its absence of predecessor proof.
///
/// ## Examples
///
/// ```gleam
/// assert generation.checked_first(associated, 0) == Error(generation.LineageMismatch)
/// ```
pub fn checked_first(
  value: GenerationAssociation,
  configured_first: Int,
) -> Result(Nil, InputError) {
  case value.predecessor {
    FirstGeneration
      if configured_first >= 1
      && configured_first <= max_generation
      && value.key.generation == configured_first
    -> Ok(Nil)
    FirstGeneration | Successor(_, _) -> Error(LineageMismatch)
  }
}

/// Checks immediate lineage against independently read original record digests.
/// No range wrap, epoch change, descriptor change or enrollment change is admitted.
///
/// ## Examples
///
/// ```gleam
/// assert generation.checked_successor(previous, previous, node_hash, owner_hash)
///   == Error(generation.LineageMismatch)
/// ```
pub fn checked_successor(
  value: GenerationAssociation,
  previous: GenerationAssociation,
  node_retirement: Digest,
  owner_close: Digest,
) -> Result(Nil, InputError) {
  case value.predecessor {
    Successor(node, owner)
      if previous.key.generation < max_generation
      && value.key.generation == previous.key.generation + 1
      && value.key.scope == previous.key.scope
      && value.key.descriptor == previous.key.descriptor
      && value.enrollment == previous.enrollment
      && value.owner_use != previous.owner_use
      && node == node_retirement
      && owner == owner_close
    -> Ok(Nil)
    FirstGeneration | Successor(_, _) -> Error(LineageMismatch)
  }
}

/// Supplies the single canonical nested key value for other closed codecs.
///
/// ## Examples
///
/// ```gleam
/// assert generation.decode_key_value(generation.key_value(key)) == Ok(key)
/// ```
pub fn key_value(value: GenerationKey) -> mp.MsgPackValue {
  let #(session, binding) = workspace.scope_fields(value.scope)
  let #(selector, workspace_epoch, session_epoch) =
    workspace.binding_fields(binding)
  let #(executor, name) = workspace.selector_fields(selector)
  mp.ArrayValue([
    mp.IntValue(1),
    mp.StringValue("loom.generation.key/1"),
    mp.ArrayValue([
      mp.StringValue(ids.session_id_to_string(session)),
      mp.StringValue(name),
      mp.StringValue(executor),
      mp.IntValue(session_epoch),
      mp.IntValue(workspace_epoch),
    ]),
    mp.BinaryValue(value.descriptor.bytes),
    mp.IntValue(value.generation),
  ])
}

/// Totally decodes a nested key through the existing core scope constructors.
/// An enclosing codec must compare its full canonical re-encoding, just as
/// `decode_key` does, to reject alternate nested UUID spellings.
///
/// ## Examples
///
/// ```gleam
/// assert generation.decode_key_value(generation.key_value(key)) == Ok(key)
/// ```
pub fn decode_key_value(
  value: mp.MsgPackValue,
) -> Result(GenerationKey, CorruptionReport) {
  case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue("loom.generation.key/1"),
      mp.ArrayValue([
        mp.StringValue(session),
        mp.StringValue(name),
        mp.StringValue(executor),
        mp.IntValue(session_epoch),
        mp.IntValue(workspace_epoch),
      ]),
      mp.BinaryValue(descriptor),
      mp.IntValue(number),
    ]) -> {
      use scope <- result.try(
        workspace.scope_from_fields(
          session,
          name,
          executor,
          session_epoch,
          workspace_epoch,
        )
        |> result.map_error(fn(_) { malformed("complete validated scope") }),
      )
      use hash <- result.try(
        digest(descriptor)
        |> result.map_error(fn(_) { malformed("32-byte descriptor") }),
      )
      key(scope, hash, number)
      |> result.map_error(fn(_) {
        malformed("positive signed-32-bit generation")
      })
    }
    _ -> Error(malformed("version-one complete generation key"))
  }
}

/// Canonically encodes the full key for durable equality and hashing.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(bytes) = generation.encode_key(key)
/// assert generation.decode_key(bytes) == Ok(key)
/// ```
pub fn encode_key(value: GenerationKey) -> Result(BitArray, CorruptionReport) {
  mp.encode(key_value(value))
  |> result.map_error(fn(_) { malformed("encodable generation key") })
}

/// Decodes bounded bytes and rejects alternate encodings or UUID spellings.
///
/// ## Examples
///
/// ```gleam
/// assert generation.decode_key(<<>>) |> result.is_error
/// ```
pub fn decode_key(bytes: BitArray) -> Result(GenerationKey, CorruptionReport) {
  use value <- result.try(bounded(bytes))
  use key <- result.try(decode_key_value(value))
  use canonical <- result.try(encode_key(key))
  use Nil <- result.try(exact_bytes(bytes, canonical))
  Ok(key)
}

/// Supplies the canonical nested association value without live authority.
///
/// ## Examples
///
/// ```gleam
/// assert generation.decode_association_value(generation.association_value(associated)) == Ok(associated)
/// ```
pub fn association_value(value: GenerationAssociation) -> mp.MsgPackValue {
  mp.ArrayValue([
    mp.IntValue(1),
    mp.StringValue("loom.generation.association/1"),
    key_value(value.key),
    mp.BinaryValue(value.enrollment.bytes),
    mp.StringValue(ids.entry_id_to_string(value.owner_use)),
    case value.predecessor {
      FirstGeneration -> mp.ArrayValue([mp.IntValue(0)])
      Successor(node, owner) ->
        mp.ArrayValue([
          mp.IntValue(1),
          mp.BinaryValue(node.bytes),
          mp.BinaryValue(owner.bytes),
        ])
    },
  ])
}

/// Totally decodes association identity; actual lineage requires registry readback.
/// The enclosing codec owes a complete canonical re-encoding comparison.
///
/// ## Examples
///
/// ```gleam
/// assert generation.decode_association_value(mp.NilValue) |> result.is_error
/// ```
pub fn decode_association_value(
  value: mp.MsgPackValue,
) -> Result(GenerationAssociation, CorruptionReport) {
  case value {
    mp.ArrayValue([
      mp.IntValue(1),
      mp.StringValue("loom.generation.association/1"),
      key,
      mp.BinaryValue(enrollment),
      mp.StringValue(owner),
      predecessor,
    ]) -> {
      use key <- result.try(decode_key_value(key))
      use enrollment <- result.try(
        digest(enrollment)
        |> result.map_error(fn(_) { malformed("32-byte enrollment") }),
      )
      use owner <- result.try(ids.parse_entry_id(owner))
      use predecessor <- result.try(decode_predecessor(predecessor))
      Ok(association(key, enrollment, owner, predecessor))
    }
    _ -> Error(malformed("version-one immutable association"))
  }
}

/// Encodes one immutable association with the shared key value.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(bytes) = generation.encode_association(associated)
/// assert generation.decode_association(bytes) == Ok(associated)
/// ```
pub fn encode_association(
  value: GenerationAssociation,
) -> Result(BitArray, CorruptionReport) {
  mp.encode(association_value(value))
  |> result.map_error(fn(_) { malformed("encodable association") })
}

/// Decodes bounded exact canonical association bytes without minting identities.
///
/// ## Examples
///
/// ```gleam
/// assert generation.decode_association(<<>>) |> result.is_error
/// ```
pub fn decode_association(
  bytes: BitArray,
) -> Result(GenerationAssociation, CorruptionReport) {
  use value <- result.try(bounded(bytes))
  use associated <- result.try(decode_association_value(value))
  use canonical <- result.try(encode_association(associated))
  use Nil <- result.try(exact_bytes(bytes, canonical))
  Ok(associated)
}

fn decode_predecessor(
  value: mp.MsgPackValue,
) -> Result(Predecessor, CorruptionReport) {
  case value {
    mp.ArrayValue([mp.IntValue(0)]) -> Ok(FirstGeneration)
    mp.ArrayValue([mp.IntValue(1), mp.BinaryValue(node), mp.BinaryValue(owner)]) -> {
      use node <- result.try(
        digest(node)
        |> result.map_error(fn(_) { malformed("32-byte node retirement") }),
      )
      use owner <- result.try(
        digest(owner)
        |> result.map_error(fn(_) { malformed("32-byte owner close") }),
      )
      Ok(Successor(node, owner))
    }
    _ -> Error(malformed("closed predecessor variant"))
  }
}

fn bounded(bytes: BitArray) -> Result(mp.MsgPackValue, CorruptionReport) {
  case bytes {
    <<_:size(8193), _:bits>> -> Error(malformed("at most 1024 identity bytes"))
    _ -> bounded_msgpack.decode(bytes)
  }
}

fn exact_bytes(
  bytes: BitArray,
  canonical: BitArray,
) -> Result(Nil, CorruptionReport) {
  case bytes == canonical {
    True -> Ok(Nil)
    False -> Error(malformed("exact canonical identity bytes"))
  }
}

fn malformed(expected: String) -> CorruptionReport {
  corruption.report(
    at: "core/generation",
    on: "generation identity",
    expected:,
    context: "",
  )
}
