//// A parked transport owner, published before Mist can bind a socket.
////
//// The daemon retains this owner's original monitor before Begin. This owner
//// retains Mist's original monitor before releasing its startup link or bound
//// port. Neither a stop acknowledgement nor a timeout proves that Mist's child
//// tree retired. Only its original normal or OTP shutdown DOWN permits this
//// owner to exit normally. Root death starts the same bounded close path.

import client/internal/ffi_os
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import mist
import weft/state_machine as sm

/// A prepared listener capability; preparation opens no socket.
pub opaque type Listener {
  Listener(commands: Subject(Message), pid: process.Pid)
}

/// The bound endpoint and original Mist supervisor, without a credential.
pub type Bound {
  Bound(
    /// The kernel-selected port, including when configuration requested zero.
    port: Int,
    /// Original transport supervisor, exposed for lifetime diagnostics.
    supervisor: process.Pid,
  )
}

type Phase {
  Parked
  Serving
  Closing
  Failed(String)
}

type Data {
  Data(
    builder: mist.Builder(mist.Connection, mist.ResponseData),
    selector: process.Selector(Message),
    bound: Option(Bound),
    ports: Subject(Int),
  )
}

type Message {
  Begin
  Ready(Subject(Result(Bound, String)))
  Close
  RootGone
  MistGone(process.ExitReason)
  Deadline
}

/// Prepares an owner whose root monitor also covers a never-started listener.
///
/// ## Examples
///
/// ```gleam
/// // listener.prepare(root_pid, mist.new(handle))
/// ```
@internal
pub fn prepare(
  root: process.Pid,
  builder: mist.Builder(mist.Connection, mist.ResponseData),
) -> Result(Listener, String) {
  sm.new_with_initialiser(1000, fn(commands) {
    let selector =
      process.new_selector()
      |> process.select(commands)
      |> process.select_specific_monitor(process.monitor(root), fn(_) {
        RootGone
      })
    sm.initialised(Parked, Data(builder, selector, None, process.new_subject()))
    |> sm.selecting(selector)
    |> sm.returning(commands)
    |> Ok
  })
  |> sm.trapping_exits(True)
  |> sm.unlinked
  |> sm.on_event(handle)
  |> sm.start
  |> result.map(fn(started) { Listener(started.data, started.pid) })
  |> result.map_error(string.inspect)
}

/// Releases socket acquisition after the root retained this owner's monitor.
///
/// ## Examples
///
/// ```gleam
/// listener.begin(transport)
/// ```
@internal
pub fn begin(listener: Listener) -> Nil {
  process.send(listener.commands, Begin)
}

/// Returns the original owner for publication and subsequent drain proof.
///
/// ## Examples
///
/// ```gleam
/// process.monitor(listener.pid(transport))
/// ```
@internal
pub fn pid(listener: Listener) -> process.Pid {
  listener.pid
}

/// Waits within a caller budget; timeout requests close without claiming drain.
///
/// ## Examples
///
/// ```gleam
/// listener.ready(transport, within: 10_000)
/// ```
@internal
pub fn ready(listener: Listener, within within: Int) -> Result(Bound, String) {
  let replies = process.new_subject()
  let watch = process.monitor(listener.pid)
  process.send(listener.commands, Ready(replies))
  let answer =
    process.new_selector()
    |> process.select(replies)
    |> process.select_specific_monitor(watch, fn(_) {
      Error("daemon listener owner ended before readiness")
    })
    |> process.selector_receive(int.max(within, 0))
    |> result.replace_error("daemon listener readiness timed out")
    |> result.flatten
  process.demonitor_process(watch)
  case answer {
    Error(_) -> close(listener)
    Ok(_) -> Nil
  }
  answer
}

/// Requests orderly shutdown; the root's original monitor proves completion.
///
/// ## Examples
///
/// ```gleam
/// listener.close(transport)
/// ```
@internal
pub fn close(listener: Listener) -> Nil {
  process.send(listener.commands, Close)
}

fn handle(phase: Phase, data: Data, event: Message) {
  case event {
    Begin ->
      case phase {
        Parked -> start(data)
        Serving | Closing | Failed(_) -> sm.keep(data)
      }
    Ready(reply) ->
      case phase, data.bound {
        Serving, Some(bound) -> {
          process.send(reply, Ok(bound))
          sm.keep(data)
        }
        Parked, _ -> sm.keep(data) |> sm.postpone
        Failed(reason), _ -> {
          process.send(reply, Error(reason))
          sm.keep(data)
        }
        Closing, _ | Serving, None -> {
          process.send(reply, Error("daemon listener is closing"))
          sm.keep(data)
        }
      }
    Close | RootGone -> shutdown(phase, data)
    MistGone(reason) ->
      case clean_exit(reason) {
        True -> sm.stop()
        False -> sm.stop_abnormal("daemon listener retirement was unconfirmed")
      }
    Deadline -> {
      // KILL limits the remaining transport lifetime, but loses transitive
      // retirement proof. The root must retain its recovery-blocked lock.
      case data.bound {
        Some(bound) -> process.kill(bound.supervisor)
        None -> Nil
      }
      sm.stop_abnormal("daemon listener shutdown timed out")
    }
  }
}

fn start(data: Data) {
  let builder =
    mist.after_start(data.builder, fn(port, _, _) {
      process.send(data.ports, port)
    })
  case mist.start(builder) {
    Error(error) -> sm.transition(Failed(string.inspect(error)), data)
    Ok(started) -> {
      let watch = process.monitor(started.pid)
      let selector =
        process.select_specific_monitor(data.selector, watch, fn(down) {
          MistGone(down.reason)
        })
      process.unlink(started.pid)

      // Mist calls after_start synchronously before start returns. Retain the
      // acquired supervisor even if that contract fails, then close it normally.
      let port = process.receive(data.ports, 1000)
      let data =
        Data(
          ..data,
          selector:,
          bound: Some(Bound(result.unwrap(port, 0), started.pid)),
        )
      case port {
        Ok(_) -> sm.transition(Serving, data) |> sm.with_selector(selector)
        Error(Nil) -> shutdown(Serving, data) |> sm.with_selector(selector)
      }
    }
  }
}

fn shutdown(phase: Phase, data: Data) {
  case phase, data.bound {
    Closing, _ -> sm.keep(data)
    _, None -> sm.stop()
    _, Some(bound) -> {
      // The selected original DOWN remains authoritative even if sys:terminate
      // times out after accepting the request. The deadline never becomes proof.
      let _requested = ffi_os.terminate_supervisor(bound.supervisor, 1000)
      sm.transition(Closing, data)
      |> sm.with_state_timeout(after: 10_000, sending: Deadline)
    }
  }
}

fn clean_exit(reason: process.ExitReason) -> Bool {
  case reason {
    process.Normal -> True
    process.Killed -> False
    process.Abnormal(reason) ->
      decode.run(reason, atom.decoder())
      |> result.map(fn(reason) { atom.to_string(reason) == "shutdown" })
      |> result.unwrap(False)
  }
}
