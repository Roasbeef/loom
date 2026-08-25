//// The process-global slot holding the installed capability `Channel`.
////
//// FFI confinement (spec §0.2): the only `@external` here binds
//// `persistent_term` through `cap_ffi.erl`. `persistent_term` is the
//// right primitive — VM-global, readable at local-memory speed from
//// every process (task workers and actors included), written once per
//// execution by the boot module. No pure alternative can share a value
//// across the unrelated processes a program spawns.
////
//// The stored value is always a `Channel`, so the typed externals below
//// are sound: `put_channel` only ever receives one, and `get_channel`
//// only ever returns one the boot module stored.

import cap/internal/channel.{type Channel}
import gleam/erlang/process.{type Pid}

/// Stores the channel in the global slot, overwriting any prior value.
///
/// Uses `persistent_term:put/2`; there is no pure way to publish a value
/// to processes a program has not yet spawned.
@external(erlang, "cap_ffi", "put_channel")
pub fn put_channel(channel: Channel) -> Nil

/// Reads the channel from the global slot, or `Error(Nil)` when the boot
/// module has not installed one yet.
///
/// Uses `persistent_term:get/2` with a sentinel default, so a missing
/// slot is a `Result`, not a `badarg` crash.
@external(erlang, "cap_ffi", "get_channel")
pub fn get_channel() -> Result(Channel, Nil)

/// Records the pid owning the installed channel actor. `dispatch` reads it
/// back to refuse a kept-alive re-install over a still-live channel (C-F1).
///
/// Uses `persistent_term:put/2`.
@external(erlang, "cap_ffi", "put_owner")
pub fn put_owner(owner: Pid) -> Nil

/// Reads the recorded owner pid, or `Error(Nil)` when none is recorded.
///
/// Uses `persistent_term:get/2` with a sentinel default.
@external(erlang, "cap_ffi", "get_owner")
pub fn get_owner() -> Result(Pid, Nil)

/// Erases both the channel and owner slots. Called on clean teardown so a
/// later execution's `install_exclusive` sees an empty slot, and by tests
/// to reset the VM-global state between cases.
///
/// Uses `persistent_term:erase/1`.
@external(erlang, "cap_ffi", "clear_slot")
pub fn clear() -> Nil
