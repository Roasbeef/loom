//// The one-line front door every public cap function goes through:
//// resolve the installed channel, perform one `cap_call`, return its
//// typed outcome. Keeping this in a single internal module means no
//// public cap module touches the registry or the channel directly, and
//// the "how is the channel found" question has exactly one answer.

import cap/internal/channel.{type CallError, type Channel, Unreachable}
import cap/internal/ffi_registry
import cap/internal/wire
import core/msgpack.{type MsgPackValue}
import gleam/erlang/process.{type Pid}

/// Installs a channel unconditionally, recording no owner. Tests use this
/// to put a fake channel in place; the boot module installs through
/// `install_exclusive`, which guards a kept-alive re-install (C-F1).
pub fn install(channel: Channel) -> Nil {
  ffi_registry.clear()
  ffi_registry.put_channel(channel)
}

/// Installs the channel for one execution, refusing if a prior execution's
/// channel actor (`owner`) is still alive.
///
/// The channel and token live in a VM-global slot (`persistent_term`). In
/// the kept-alive satellite mode a process that survived execution *N*
/// would, on its next cap call, read execution *N+1*'s channel and so act
/// under *N+1*'s token. This guard refuses to overwrite a live slot: the
/// executor must reap execution *N*'s processes (its channel actor among
/// them) before *N+1* installs. Once the prior owner is dead the slot is
/// stale and re-install proceeds. Strict L0 (a fresh node per execution)
/// never hits the live case; this is load-bearing only for kept-alive.
pub fn install_exclusive(channel: Channel, owner: Pid) -> Result(Nil, Nil) {
  case ffi_registry.get_owner() {
    Ok(prior) ->
      case process.is_alive(prior) {
        // A prior execution's channel actor is still live: refuse rather
        // than let a survivor pick up this execution's token.
        True -> Error(Nil)
        // The prior owner is dead — a stale slot from a reaped execution.
        // Overwrite it and record the new owner.
        False -> Ok(do_install(channel, owner))
      }
    Error(Nil) -> Ok(do_install(channel, owner))
  }
}

fn do_install(channel: Channel, owner: Pid) -> Nil {
  ffi_registry.put_channel(channel)
  ffi_registry.put_owner(owner)
}

/// Releases the slot if `owner` still holds it, and does nothing if a
/// later execution has already claimed it.
///
/// The boot module calls this on clean teardown. Clearing rather than
/// leaving the channel installed is what makes a process that survived the
/// execution fail its next cap call `Unreachable` instead of finding
/// whatever channel is installed by then; the compare-and-clear is what
/// keeps a slow teardown from clearing a *later* execution's slot.
pub fn release(owner: Pid) -> Nil {
  case ffi_registry.get_owner() {
    Ok(installed) if installed == owner -> ffi_registry.clear()
    _ -> Nil
  }
}

/// Clears the installed channel and owner unconditionally. Used by tests to
/// reset the VM-global slot between cases, standing in for the fresh node
/// each execution really gets.
pub fn reset() -> Nil {
  ffi_registry.clear()
}

/// Performs one capability call with the default deadline.
pub fn call(
  cap: String,
  args: MsgPackValue,
) -> Result(MsgPackValue, CallError) {
  call_within(cap, args, wire.default_deadline_ms)
}

/// Performs one capability call with an explicit per-call deadline.
pub fn call_within(
  cap: String,
  args: MsgPackValue,
  deadline_ms: Int,
) -> Result(MsgPackValue, CallError) {
  case ffi_registry.get_channel() {
    Error(Nil) -> Error(Unreachable("capability channel not installed"))
    Ok(channel) -> {
      let channel.Channel(call:) = channel
      call(cap, args, deadline_ms)
    }
  }
}
