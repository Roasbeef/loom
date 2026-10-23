//// OTP loading and system calls have no standard typed bindings. Only fixed
//// reviewed namespaces cross this boundary, sharing the concrete scratch ABI.
//// Gun supplies flow-controlled TLS, with the updater's verification policy.

import client/upgrade/state as abi
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Name, type Pid}
import weft/actor

/// Fixed VM-wide owner name; no per-request atom is allocated.
/// ## Examples
/// `fixed_name()` denotes the same owner on every call.
@external(erlang, "client_upgrade_ffi", "fixed_name")
pub fn fixed_name() -> Name(message)

/// Atomic fixed-slot load after the registry has excluded live owners.
/// ## Examples
/// `load(abi.SlotA, bytes, "v2")` never force purges old code.
@external(erlang, "client_upgrade_ffi", "load")
pub fn load(
  slot: abi.Slot,
  bytes: BitArray,
  version: String,
) -> Result(Nil, String)

/// Match a standard sys module against the admitted fixed slot.
/// ## Examples
/// `module_matches(module, abi.Builtin)` matches the shipped component only.
@external(erlang, "client_upgrade_ffi", "module_matches")
pub fn module_matches(module: Atom, slot: abi.Slot) -> Bool

/// Fresh fixed-slot references under the reviewed concrete state/message ABI.
/// ## Examples
/// `handler(abi.SlotA)` executes newly loaded SlotA code.
@external(erlang, "client_upgrade_ffi", "handler")
pub fn handler(
  slot: abi.Slot,
) -> fn(abi.State, abi.Message) -> actor.Next(abi.State, abi.Message)

/// Reviewed pure transformation of current state, with no snapshot restore.
/// ## Examples
/// `migrate(abi.SlotA, current)` transforms the currently populated cache.
@external(erlang, "client_upgrade_ffi", "migrate")
pub fn migrate(slot: abi.Slot, current: abi.State) -> Result(abi.State, String)

/// Bounded suspension, sent by the same custodian which later resumes.
/// ## Examples
/// `suspend(pid, 100)` returns errors instead of exiting its caller.
@external(erlang, "client_upgrade_ffi", "suspend")
pub fn suspend(pid: Pid, timeout: Int) -> Result(Nil, String)

/// Standard sys code change, carrying an admitted transaction token.
/// ## Examples
/// `change(pid, abi.SlotA, "builtin", token, 250)` carries no raw state.
@external(erlang, "client_upgrade_ffi", "change")
pub fn change(
  pid: Pid,
  slot: abi.Slot,
  old_version: String,
  token: String,
  timeout: Int,
) -> Result(Nil, String)

/// Bounded resume from the original suspender, even after a failed operation.
/// ## Examples
/// `resume(pid, 100)` closes late-suspend ordering races.
@external(erlang, "client_upgrade_ffi", "resume")
pub fn resume(pid: Pid, timeout: Int) -> Result(Nil, String)

/// Native flow-controlled request identifier.
pub type Stream

/// Response completion status.
pub type Completion {
  /// No body fragments remain.
  Finished

  /// More body fragments remain.
  More
}

/// One credited response event, accumulated under a Gleam byte budget.
pub type Event {
  /// Response metadata.
  Headers(
    /// Whether the response ends with these headers.
    completion: Completion,
    /// The HTTP response status.
    status: Int,
    /// Header names and values supplied by the transport.
    fields: List(#(String, String)),
  )

  /// One body fragment.
  Data(
    /// Whether this is the final body fragment.
    completion: Completion,
    /// One credited fragment, checked against the caller's byte budget.
    bytes: BitArray,
  )

  /// Bodyless informational response.
  Inform

  /// Final trailers.
  Trailers
}

/// Verified TLS with system roots and hostname verification.
/// ## Examples
/// `open("github.com", 443)` retains certificate verification.
@external(erlang, "client_upgrade_ffi", "open")
pub fn open(host: String, port: Int) -> Result(Pid, String)

/// GET with one body fragment of credit.
/// ## Examples
/// `request(connection, "/release")` returns a typed stream.
@external(erlang, "client_upgrade_ffi", "request")
pub fn request(connection: Pid, path: String) -> Result(Stream, String)

/// One event under a native idle deadline.
/// ## Examples
/// `receive(connection, stream)` does not buffer the full artifact.
@external(erlang, "client_upgrade_ffi", "next")
pub fn receive(connection: Pid, stream: Stream) -> Result(Event, String)

/// One more fragment after the preceding fragment passed its byte budget.
/// ## Examples
/// `credit(connection, stream)` restores one fragment of credit.
@external(erlang, "client_upgrade_ffi", "credit")
pub fn credit(connection: Pid, stream: Stream) -> Nil

/// Normal transport teardown before its ownership proof can settle.
/// ## Examples
/// `close(connection)` is safe after a refused request.
@external(erlang, "client_upgrade_ffi", "close")
pub fn close(connection: Pid) -> Nil

/// Refuse reconstructing an empty ownership ledger after code has been loaded.
/// ## Examples
/// `pristine()` fails closed if the fixed owner was lost while slot code remained.
@external(erlang, "client_upgrade_ffi", "pristine")
pub fn pristine() -> Result(Nil, String)

/// Ordered local signal-delivery barrier before a slot permit leaves.
/// ## Examples
/// `deliver_signals(pid)` makes the newly installed monitor authoritative.
@external(erlang, "client_upgrade_ffi", "deliver_signals")
pub fn deliver_signals(pid: Pid) -> Bool

/// Version reported by the loaded module, called only on a bounded worker.
/// ## Examples
/// `version(abi.SlotA)` is checked against the reviewed manifest before admission.
@external(erlang, "client_upgrade_ffi", "version")
pub fn version(slot: abi.Slot) -> String
