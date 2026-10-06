//// The fixed scratch upgrade ABI keeps messages and owned data typed.
////
//// Reviewed implementations share this envelope rather than casting Erlang
//// terms into an arbitrary state type. Only implementation identity changes;
//// entry bounds and least-recently-written ordering remain the scratch contract.

import codemode/workspace.{type KvRefusal}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option}

/// The bounded, VM-global namespaces available to reviewed scratch code.
pub type Slot {
  /// The original implementation shipped with the daemon.
  Builtin

  /// The first reviewed release namespace.
  SlotA

  /// The second reviewed release namespace.
  SlotB
}

/// Exact code identity and the stable typed boundary it implements.
pub type Identity {
  Identity(
    /// The fixed namespace, never derived from a version string.
    slot: Slot,
    /// The reviewed implementation's application version.
    version: String,
    /// SHA-256 of the exact reviewed BEAM artifact.
    digest: String,
    /// The representation version this ABI can migrate.
    state_version: String,
    /// The immutable message ABI accepted by this component.
    boundary: String,
  )
}

/// One admitted change, fenced against expired and replayed sys requests.
pub type Permit {
  Permit(
    /// Fresh control transaction identity, never exposed to capability calls.
    token: String,
    /// Identity which must still be installed when migration begins.
    expected: Identity,
    /// Identity selected by the reviewed artifact resolver.
    target: Identity,
    /// Absolute monotonic deadline, including controller resume custody.
    expires_at: Int,
  )
}

/// One entry in newest-written-first order.
pub type Entry {
  Entry(
    /// The caller's opaque cache key.
    key: String,
    /// The caller's cache bytes.
    value: BitArray,
    /// The byte length tracked for bounded admission.
    bytes: Int,
  )
}

/// The same scratch message ABI across every supported implementation.
pub type Message {
  /// Reads an entry without changing write order.
  Get(
    /// The caller's opaque cache key.
    key: String,
    /// Receives the current value, if present.
    reply_with: Subject(Option(BitArray)),
  )

  /// Writes one bounded entry.
  Set(
    /// The caller's opaque cache key.
    key: String,
    /// The replacement bytes, subject to the existing admission limits.
    value: BitArray,
    /// Receives admission success or the original scratch refusal.
    reply_with: Subject(Result(Nil, KvRefusal)),
  )

  /// Removes one entry.
  Delete(
    /// The caller's opaque cache key.
    key: String,
    /// Receives acknowledgement after removal.
    reply_with: Subject(Nil),
  )

  /// Reads the original scratch count and bytes observation.
  Stat(
    /// Receives the retained entry count and aggregate value bytes.
    reply_with: Subject(#(Int, Int)),
  )

  /// Returns implementation identity without exposing stored values.
  Inspect(
    /// Receives implementation identity and bounded state accounting.
    reply_with: Subject(Observation),
  )

  /// Authorizes exactly one reviewed control transaction before suspension.
  Arm(
    /// The token and identities admitted by the native controller.
    permit: Permit,
    /// Receives admission success or a stale/conflicting transaction error.
    reply_with: Subject(Result(Nil, String)),
  )

  /// Retires a permit only when its token still matches.
  Disarm(
    /// The exact transaction whose permit may be retired.
    token: String,
    /// Receives acknowledgement even when this token is already retired.
    reply_with: Subject(Nil),
  )

  /// Ends the scratch actor normally.
  Stop
}

/// A native operator's state-free component observation.
pub type Observation {
  Observation(
    /// Exact installed artifact identity.
    identity: Identity,
    /// Version reported by the executing implementation callback itself.
    reported_version: String,
    /// Number of retained entries.
    entries: Int,
    /// Number of retained value bytes.
    bytes: Int,
  )
}

/// Stable typed state shared only by reviewed component implementations.
pub type State {
  State(
    /// The per-entry admission ceiling.
    max_entry_bytes: Int,
    /// The whole cache byte ceiling.
    max_total_bytes: Int,
    /// The whole cache entry ceiling.
    max_entries: Int,
    /// Newest-written entries first.
    entries: List(Entry),
    /// Exact aggregate value byte length.
    total_bytes: Int,
    /// Exact entry count.
    count: Int,
    /// The original actor-owned inbox, retained by replacement selectors.
    inbox: Subject(Message),
    /// Current reviewed implementation identity.
    identity: Identity,
    /// At most one admitted control transaction.
    permit: Option(Permit),
  )
}

/// Identity of the immutable daemon-shipped implementation.
///
/// ## Examples
///
/// `state.builtin().version` is `"builtin"`.
pub fn builtin() -> Identity {
  Identity(Builtin, "builtin", "builtin", "v1", "loom.scratch.v1")
}
