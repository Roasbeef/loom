//// A resident session's last valid configuration and operation snapshots.
////
//// Only an explicit operator-selected path is watched. A bounded regular-file
//// read on a weft periodic tick follows atomic replacements; two equal reads
//// coalesce editor saves before validation. A failed read or validation never
//// changes the published value. Diagnostics contain fixed event names and
//// section names, never document bytes or parser errors which may quote them.
////
//// Capture is lazy on the first operation-scoped fetch, because threshold
//// evaluation can precede run_start. Pins are collected only after durable
//// completion; run_end alone does not prove that an operation is finished.
//// Killing the holder shares fate with the resident session. Its bounded
//// polling workers are cancelled when their owner exits.

import broker/internal/call
import core/ids.{type OpId}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import simplifile
import telemetry/field
import telemetry/log.{type Logger}
import weft
import weft/actor
import weft/registry as address

/// The largest accepted configuration document, enforced during the read.
pub const max_file_bytes = 1_048_576

/// Poll latency; two observations provide a one-second save quiet period.
pub const poll_ms = 500

/// A publication address kept alive until the runtime has drained.
pub opaque type Holder(config) {
  Holder(pid: Pid, requests: Subject(Message(config)))
}

/// Trusted source and complete-document validator, installed by assembly.
pub type Source(config) {
  Source(
    /// Real path resolved once from the explicit selection.
    path: String,
    /// Bytes used to assemble the initial value, closing the startup race.
    initial: String,
    /// Validates all tables and returns the supported value and restart list.
    load: fn(String, config) -> Result(#(config, List(String)), Nil),
  )
}

type State(config) {
  State(
    current: config,
    pinned: Dict(OpId, config),
    source: Option(Source(config)),
    seen: Option(String),
    pending: Option(String),
    finished: fn(OpId) -> Bool,
    logger: Logger,
  )
}

pub opaque type Message(config) {
  Current(reply: Subject(config))
  Capture(operation: OpId, reply: Subject(config))
  Poll

  /// Publishes one approved save without changing active operation pins.
  Refresh(reply: Subject(Result(List(String), String)))
  Stop
}

/// Starts the linked holder before the runtime, then transfers it to custody.
///
/// `finished` must return true only after the operation's durable state is
/// absent. Read failures retain a pin. No watcher starts for an environment
/// configuration, so a workspace file cannot acquire operator authority.
///
/// ## Examples
///
/// ```gleam
/// // config_reload.start(name, initial, source, finished, logger)
/// ```
pub fn start(
  name: address.Address(Message(config)),
  initial: config,
  source: Option(Source(config)),
  finished: fn(OpId) -> Bool,
  logger: Logger,
) -> Result(Holder(config), String) {
  let state =
    State(
      current: initial,
      pinned: dict.new(),
      source:,
      seen: option.map(source, fn(source) { source.initial }),
      pending: None,
      finished:,
      logger:,
    )
  let builder =
    actor.new(state) |> actor.addressed(name) |> actor.on_message(handle)
  let builder = case source {
    None -> builder
    Some(_) -> actor.periodic(builder, poll_ms, Poll)
  }
  builder
  |> actor.start
  |> result.map(fn(started) { Holder(started.pid, started.data) })
  |> result.replace_error("configuration holder could not start")
}

/// Reads the published value for listings and future model selections.
///
/// ## Examples
///
/// ```gleam
/// // config_reload.current(holder)
/// ```
pub fn current(holder: Holder(config)) -> Result(config, Nil) {
  call.try_call(holder.requests, waiting: 3000, sending: Current)
  |> result.replace_error(Nil)
}

/// Borrows the published value through a name minted before assembly.
///
/// ## Examples
///
/// ```gleam
/// // config_reload.current_at(name)
/// ```
pub fn current_at(
  name: address.Address(Message(config)),
) -> Result(config, Nil) {
  use requests <- result.try(address.lookup(name))
  call.try_call(requests, waiting: 3000, sending: Current)
  |> result.replace_error(Nil)
}

/// Borrows an operation snapshot through the same assembly address.
///
/// ## Examples
///
/// ```gleam
/// // config_reload.capture_at(name, operation)
/// ```
pub fn capture_at(
  name: address.Address(Message(config)),
  operation: OpId,
) -> Result(config, Nil) {
  use requests <- result.try(address.lookup(name))
  call.try_call(requests, waiting: 3000, sending: Capture(operation, _))
  |> result.replace_error(Nil)
}

/// Confirms an approved save without waiting for editor-save coalescing.
///
/// Existing operation pins are retained. A failed observation or validation
/// keeps the last publication and reports that reload could not be confirmed.
///
/// ## Examples
///
/// ```gleam
/// // config_reload.refresh_at(name)
/// ```
@internal
pub fn refresh_at(
  name: address.Address(Message(config)),
) -> Result(List(String), String) {
  use requests <- result.try(
    address.lookup(name)
    |> result.replace_error("configuration holder unavailable"),
  )
  use reply <- result.try(
    call.try_call(requests, waiting: 5000, sending: Refresh)
    |> result.replace_error("configuration reload confirmation timed out"),
  )
  reply
}

/// Captures once per operation, shared by all its hooks and provider attempts.
///
/// A missing holder is an availability error, never permission to read a newer
/// snapshot. The caller must refuse the effect rather than change its settings.
///
/// ## Examples
///
/// ```gleam
/// // config_reload.capture(holder, operation)
/// ```
pub fn capture(holder: Holder(config), operation: OpId) -> Result(config, Nil) {
  call.try_call(holder.requests, waiting: 3000, sending: Capture(operation, _))
  |> result.replace_error(Nil)
}

/// Exposes the fatal root for custody and resident monitoring.
///
/// ## Examples
///
/// ```gleam
/// // process.unlink(config_reload.pid(holder))
/// ```
pub fn pid(holder: Holder(config)) -> Pid {
  holder.pid
}

/// Stops polling and acknowledges process retirement, after runtime drain.
///
/// ## Examples
///
/// ```gleam
/// // config_reload.stop(holder)
/// ```
pub fn stop(holder: Holder(config)) -> Result(Nil, String) {
  let watch = process.monitor(holder.pid)
  process.send(holder.requests, Stop)
  let outcome =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(_) { Nil })
    |> process.selector_receive(5000)
  process.demonitor_process(watch)
  result.replace_error(outcome, "configuration holder did not retire")
}

/// Reads a regular UTF-8 document, bounding bytes even across file growth.
///
/// ## Examples
///
/// ```gleam
/// // config_reload.read(path)
/// ```
pub fn read(path: String) -> Result(String, Nil) {
  bounded(fn() { read_regular(path) })
}

/// Resolves operator authority once, before reading the initial document.
///
/// Watch and protect this same real path. Retargeting an original symlink
/// cannot select a different trusted source after startup.
///
/// ## Examples
///
/// ```gleam
/// // config_reload.selected_source(explicit_path)
/// ```
@internal
pub fn selected_source(path: String) -> Result(#(String, String), Nil) {
  bounded(fn() {
    use selected <- result.try(
      bootstrap.canonical_path(path) |> result.replace_error(Nil),
    )
    use text <- result.try(read_regular(selected))
    Ok(#(selected, text))
  })
}

// Check the type before open as well as on the opened handle: opening a FIFO
// can wait for a writer before the handle-based regular-file check runs.
fn read_regular(path: String) -> Result(String, Nil) {
  use info <- result.try(
    simplifile.file_info(path) |> result.replace_error(Nil),
  )
  use Nil <- result.try(case simplifile.file_info_type(info) {
    simplifile.File -> Ok(Nil)
    _ -> Error(Nil)
  })
  use bytes <- result.try(
    bootstrap.read_bounded(path, max_file_bytes) |> result.replace_error(Nil),
  )
  bit_array.to_string(bytes)
}

fn handle(
  state: State(config),
  message: Message(config),
) -> actor.Next(State(config), Message(config)) {
  case message {
    Current(reply) -> {
      process.send(reply, state.current)
      actor.continue(state)
    }
    Capture(operation, reply) -> {
      let pinned = case dict.get(state.pinned, operation) {
        Ok(value) -> #(state.pinned, value)
        Error(Nil) -> {
          // Completed operations lose their pins only at a new capture. The
          // bound is the number of concurrently active operations plus one.
          let live =
            dict.filter(state.pinned, fn(op, _) { !state.finished(op) })
          #(dict.insert(live, operation, state.current), state.current)
        }
      }
      process.send(reply, pinned.1)
      actor.continue(State(..state, pinned: pinned.0))
    }
    Poll -> actor.continue(poll(state))
    Refresh(reply) -> {
      let refreshed = refresh(state)
      case refreshed {
        Ok(#(next, restart)) -> {
          process.send(reply, Ok(restart))
          actor.continue(next)
        }
        Error(reason) -> {
          process.send(reply, Error(reason))
          actor.continue(state)
        }
      }
    }
    Stop -> actor.stop()
  }
}

// Explicit consent has already reviewed the complete save, so this path
// validates one observation immediately while preserving every existing pin.
fn refresh(
  state: State(config),
) -> Result(#(State(config), List(String)), String) {
  use source <- result.try(option.to_result(
    state.source,
    "no explicit configuration source",
  ))
  use text <- result.try(
    read(source.path) |> result.replace_error("configuration unreadable"),
  )
  let load = source.load
  let current = state.current
  use loaded <- result.try(
    bounded(fn() { load(text, current) })
    |> result.replace_error("configuration invalid or validation timed out"),
  )
  let #(current, restart) = loaded
  log.info(state.logger, "config.reloaded", [
    field.text("restart_required", string.join(restart, ",")),
  ])
  Ok(#(State(..state, current:, seen: Some(text), pending: None), restart))
}

fn poll(state: State(config)) -> State(config) {
  case state.source {
    None -> state
    Some(source) -> {
      // One worker at a time, bounded by bytes and wall time. Owner death
      // cancels it through weft even when custody kills this actor.
      case read(source.path) {
        Ok(text) -> observe(state, source, text)
        Error(Nil) -> {
          case state.seen {
            None -> Nil
            Some(_) -> log.warn(state.logger, "config.reload_unreadable", [])
          }
          State(..state, pending: None, seen: None)
        }
      }
    }
  }
}

fn observe(
  state: State(config),
  source: Source(config),
  text: String,
) -> State(config) {
  case state.seen == Some(text), state.pending == Some(text) {
    True, _ -> State(..state, pending: None)
    False, False -> State(..state, pending: Some(text))
    False, True -> {
      let next = State(..state, seen: Some(text), pending: None)
      let load = source.load
      let current = state.current
      case bounded(fn() { load(text, current) }) {
        Error(Nil) -> {
          log.warn(state.logger, "config.reload_invalid", [])
          next
        }
        Ok(#(current, restart)) -> {
          log.info(state.logger, "config.reloaded", [
            field.text(
              "restart_required",
              list.fold(restart, "", fn(out, name) {
                case out {
                  "" -> name
                  other -> other <> "," <> name
                }
              }),
            ),
          ])
          State(..next, current:)
        }
      }
    }
  }
}

// Reads and validation are separately bounded. The actor never overlaps
// workers, and a leaf worker owns no external process requiring a witness.
fn bounded(work: fn() -> Result(a, Nil)) -> Result(a, Nil) {
  case
    weft.new([work])
    |> weft.deadline(1000)
    |> weft.cancel_when_exits(process.self())
    |> weft.start
  {
    [weft.Completed(value:, ..)] -> Ok(value)
    [weft.Failed(..)]
    | [weft.Crashed(..)]
    | [weft.Abandoned(..)]
    | [weft.NeverStarted(..)]
    | [weft.DrainProofLost(..)]
    | [weft.CancellationUnconfirmed(..)]
    | []
    | [_, _, ..] -> Error(Nil)
  }
}
