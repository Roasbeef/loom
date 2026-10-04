//// Validated names for remote admission, independent of connections and boots.
////
//// The scope binds the session, workspace, executor and both authority epochs.
//// A request key adds the operation and a caller-reserved UUIDv7. Reconnecting
//// does not change that key. These values name authority; they do not grant it.
//// The future adapter must authenticate and validate the authoritative binding.
////
//// Administrative labels are case-sensitive and bounded before validation.
//// Provisioning owns their uniqueness. Request IDs reuse core's UUID parser;
//// this module neither generates randomness nor treats a clock as global identity.
//// Digests are fixed-size evidence supplied by a canonicalizing adapter, not a
//// claim that this module hashed or authenticated a command.

import core/ids
import gleam/result
import gleam/string

/// A provisioned executor name, containing 1..128 ASCII label bytes.
pub opaque type ExecutorId {
  /// The validated administrative label.
  ExecutorId(
    /// The case-sensitive label; provisioning ensures uniqueness.
    value: String,
  )
}

/// A provisioned workspace name, containing 1..128 ASCII label bytes.
pub opaque type WorkspaceId {
  /// The validated administrative label.
  WorkspaceId(
    /// The case-sensitive label, never a host path.
    value: String,
  )
}

/// A caller-reserved logical request UUIDv7, independent of a native process.
pub opaque type RequestId {
  /// Core's validated UUID representation, with no entry-row semantics.
  RequestId(
    /// The validated reserved UUIDv7.
    value: ids.EntryId,
  )
}

/// A positive authority epoch, bounded to a signed 32-bit integer.
pub opaque type Epoch {
  /// The provisioned monotone epoch; construction does not allocate it.
  Epoch(
    /// The validated positive authority epoch.
    value: Int,
  )
}

/// Exactly 32 bytes of request or result evidence, compared byte for byte.
pub opaque type Digest {
  /// The adapter-supplied digest; no payload bytes are retained here.
  Digest(
    /// Exactly 256 bits, compared without normalization.
    value: BitArray,
  )
}

/// One executor's exact session/workspace authority binding.
pub opaque type Scope {
  /// All fields are validated identities; equality checks the entire binding.
  Scope(
    /// The durable session identity.
    session: ids.SessionId,
    /// The registered workspace, not a filesystem path.
    workspace: WorkspaceId,
    /// The provisioned executor.
    executor: ExecutorId,
    /// The current session owner epoch.
    session_epoch: Epoch,
    /// The current workspace authority epoch.
    workspace_epoch: Epoch,
  )
}

/// A stable logical request identity within one exact authority binding.
pub opaque type RequestKey {
  /// Equality includes every scope field, operation and reserved request ID.
  RequestKey(
    /// The executor and both authority epochs.
    scope: Scope,
    /// The durable operation that reserved the request.
    operation: ids.OpId,
    /// The identity retained across retries and reconnections.
    request: RequestId,
  )
}

/// Bounded diagnostics for rejected external identities; input is not retained.
pub type InputError {
  /// A label was empty or exceeded 128 bytes.
  LabelSize

  /// A label contained a byte outside ASCII letters, digits, '.', '_' or '-'.
  LabelCharacter

  /// A request string was not a valid 36-byte UUIDv7.
  InvalidRequestId

  /// An epoch was outside 1..2147483647.
  EpochRange

  /// A digest did not contain exactly 32 bytes.
  DigestSize
}

/// Validates a provisioned executor label without normalizing it.
///
/// ## Examples
///
/// ```gleam
/// assert identity.executor_id("dev-linux") |> result.is_ok
/// assert identity.executor_id("../dev/linux") == Error(identity.LabelCharacter)
/// ```
pub fn executor_id(text: String) -> Result(ExecutorId, InputError) {
  use Nil <- result.try(validate_label(text))
  Ok(ExecutorId(text))
}

/// Validates a provisioned workspace label; it does not resolve a host path.
///
/// ## Examples
///
/// ```gleam
/// assert identity.workspace_id("loom") |> result.is_ok
/// assert identity.workspace_id("") == Error(identity.LabelSize)
/// ```
pub fn workspace_id(text: String) -> Result(WorkspaceId, InputError) {
  use Nil <- result.try(validate_label(text))
  Ok(WorkspaceId(text))
}

/// Parses a bounded UUIDv7 through core's total parser. The caller reserves it
/// once and persists it before transmission; this module provides no generator.
///
/// ## Examples
///
/// ```gleam
/// assert identity.request_id("00000000-0000-7000-8000-000000000001")
///   |> result.is_ok
/// assert identity.request_id("request") == Error(identity.InvalidRequestId)
/// ```
pub fn request_id(text: String) -> Result(RequestId, InputError) {
  use Nil <- result.try(case string.byte_size(text) == 36 {
    True -> Ok(Nil)
    False -> Error(InvalidRequestId)
  })
  use value <- result.try(
    ids.parse_entry_id(text) |> result.map_error(fn(_) { InvalidRequestId }),
  )
  Ok(RequestId(value))
}

/// Validates an externally allocated epoch. Advancing or permanently fencing
/// epochs belongs to the authority adapter, not an identity constructor.
///
/// ## Examples
///
/// ```gleam
/// assert identity.epoch(1) |> result.is_ok
/// assert identity.epoch(0) == Error(identity.EpochRange)
/// ```
pub fn epoch(value: Int) -> Result(Epoch, InputError) {
  case value >= 1 && value <= 2_147_483_647 {
    True -> Ok(Epoch(value))
    False -> Error(EpochRange)
  }
}

/// Validates fixed-size digest evidence. The adapter must define and compute
/// the canonical digest over the full command, policy and inputs.
///
/// ## Examples
///
/// ```gleam
/// assert identity.digest(<<0:size(256)>>) |> result.is_ok
/// assert identity.digest(<<>>) == Error(identity.DigestSize)
/// ```
pub fn digest(bytes: BitArray) -> Result(Digest, InputError) {
  case bytes {
    <<_:size(256)>> -> Ok(Digest(bytes))
    _ -> Error(DigestSize)
  }
}

/// Constructs a complete binding from validated identities. A matching value
/// is necessary for admission, but authentication and current authority are
/// still the adapter's responsibility.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(workspace) = identity.workspace_id("loom")
/// let assert Ok(executor) = identity.executor_id("dev")
/// let assert Ok(epoch) = identity.epoch(1)
/// let scope = identity.scope(session, workspace, executor, epoch, epoch)
/// assert scope == identity.scope(session, workspace, executor, epoch, epoch)
/// ```
pub fn scope(
  session: ids.SessionId,
  workspace: WorkspaceId,
  executor: ExecutorId,
  session_epoch: Epoch,
  workspace_epoch: Epoch,
) -> Scope {
  Scope(session:, workspace:, executor:, session_epoch:, workspace_epoch:)
}

/// Constructs a stable key from the exact binding and durable reservation.
/// A retry uses this same value, including both epochs.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(workspace) = identity.workspace_id("loom")
/// let assert Ok(executor) = identity.executor_id("dev")
/// let assert Ok(epoch) = identity.epoch(1)
/// let scope = identity.scope(session, workspace, executor, epoch, epoch)
/// let assert Ok(operation) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(request) = identity.request_id("00000000-0000-7000-8000-000000000003")
/// let key = identity.request_key(scope, operation, request)
/// assert identity.key_scope(key) == scope
/// ```
pub fn request_key(
  scope: Scope,
  operation: ids.OpId,
  request: RequestId,
) -> RequestKey {
  RequestKey(scope:, operation:, request:)
}

/// Extracts the complete authority binding for comparison with an admission book.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(session) = ids.parse_session_id("00000000-0000-7000-8000-000000000001")
/// let assert Ok(workspace) = identity.workspace_id("loom")
/// let assert Ok(executor) = identity.executor_id("dev")
/// let assert Ok(epoch) = identity.epoch(1)
/// let scope = identity.scope(session, workspace, executor, epoch, epoch)
/// let assert Ok(operation) = ids.parse_op_id("00000000-0000-7000-8000-000000000002")
/// let assert Ok(request) = identity.request_id("00000000-0000-7000-8000-000000000003")
/// assert identity.key_scope(identity.request_key(scope, operation, request)) == scope
/// ```
pub fn key_scope(key: RequestKey) -> Scope {
  key.scope
}

fn validate_label(text: String) -> Result(Nil, InputError) {
  let size = string.byte_size(text)
  use Nil <- result.try(case size >= 1 && size <= 128 {
    True -> Ok(Nil)
    False -> Error(LabelSize)
  })
  validate_label_loop(<<text:utf8>>)
}

fn validate_label_loop(bytes: BitArray) -> Result(Nil, InputError) {
  // Walking at most 128 bytes rejects non-ASCII without allocating graphemes.
  case bytes {
    <<>> -> Ok(Nil)
    <<byte, rest:bits>>
      if byte >= 65
      && byte <= 90
      || byte >= 97
      && byte <= 122
      || byte >= 48
      && byte <= 57
      || byte == 46
      || byte == 95
      || byte == 45
    -> validate_label_loop(rest)
    _ -> Error(LabelCharacter)
  }
}
