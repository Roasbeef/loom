//// The one-line front door every public cap function goes through:
//// resolve the installed channel, perform one `cap_call`, return its
//// typed outcome. Keeping this in a single internal module means no
//// public cap module touches the registry or the channel directly, and
//// the "how is the channel found" question has exactly one answer.

import cap/internal/channel.{type CallError, type Channel, Unreachable}
import cap/internal/ffi_registry
import cap/internal/wire
import core/msgpack.{type MsgPackValue}

/// Installs the channel the boot module built, making it the one every
/// cap function in this satellite will use. Called once, before `main`.
pub fn install(channel: Channel) -> Nil {
  ffi_registry.put_channel(channel)
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
