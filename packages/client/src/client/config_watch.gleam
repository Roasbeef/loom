//// Notices when the configuration file a resident session loaded has changed,
//// and tells the session's hub once the new text would open it.
////
//// A session reads its `loom.toml` when it opens, and everything it builds
//// from the file is fixed from then on: the provider gateway, the role routes,
//// the tools, the rules and schedules. The way a session takes a new file is to
//// open again (`client/daemon/restart`, the path a profile switch takes), so
//// this module never applies a configuration. It decides only when a reopen is
//// owed, and the hub decides when to pay it (`gateway.configuration_changed`),
//// which is once no strand is running.
////
//// ## Flow
////
//// `start` → `observe` → `read` → `settle`
////
//// 1. `start` runs one weft actor per session, in the session's restartable
////    service tier, which observes the file once a tick.
//// 2. `observe` reads it with `read`, which is bounded: a file that is not a
////    regular file, is too large, or does not read as text is unreadable, and an
////    unreadable file changes nothing, so a save that is half written or a file
////    moved away keeps the session as it is.
//// 3. `settle` takes a changed text only once two reads in a row agree, which
////    lets an editor's save settle, and checks it with the same loader a session
////    open uses (`Source.check`); only a text that passes notifies the hub. A
////    text that fails is logged once, with the path and never the reason: the
////    reason can quote the file, and the file can hold a `[tools.set]` literal.
////
//// ## The start race
////
//// `Source.baseline` is the file's fingerprint read *before* the session loaded
//// it. A save that lands between that read and the load makes the session read
//// the new text and the watcher see a change, which costs one reopen that was
//// not needed; the opposite order could miss a save forever. The race is closed
//// toward the reopen.

import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/result
import simplifile
import telemetry/field
import telemetry/log.{type Logger}
import weft/actor

/// The largest configuration file the watcher reads; a larger one is treated
/// as unreadable and changes nothing.
pub const max_file_bytes = 1_048_576

/// How often the file is read, in milliseconds. Two reads must agree before a
/// change counts, so a save takes effect one to two ticks after it lands.
pub const poll_ms = 1000

/// The file one session loaded, and how a new text of it is judged.
pub type Source {
  Source(
    /// The configuration path the session opened with.
    path: String,
    /// `fingerprint` of the file read before the session loaded it, or `None`
    /// when it could not be read then.
    baseline: Option(String),
    /// Whether a text would open this session: `serve.check_config` with the
    /// session's profile and model.
    check: fn(String) -> Result(Nil, String),
  )
}

/// Read the file again: `Tick` on the watcher's own clock, `Probe` when a test
/// steps it and waits for the read to be judged.
pub opaque type Message {
  Tick
  Probe(reply: Subject(Nil))
}

type State {
  State(
    source: Source,
    // The fingerprint of the text the session has, or has been told to reopen
    // with.
    applied: Option(String),
    // A changed fingerprint read once, waiting for a second read to agree.
    seen: Option(String),
    // A changed fingerprint whose text failed the check, so it is logged once.
    refused: Option(String),
    notify: fn() -> Nil,
    logger: Logger,
  )
}

/// Starts the watcher, reading the file every `poll_ms`. `notify` is called
/// from the watcher's process once per text that changed and passed the check.
///
/// ## Examples
///
/// ```gleam
/// // config_watch.start(source, fn() { gateway.configuration_changed(hub) }, logger)
/// ```
///
pub fn start(
  source: Source,
  notify: fn() -> Nil,
  logger: Logger,
) -> actor.StartResult(Subject(Message)) {
  new(source, notify, logger)
  |> actor.periodic(every: poll_ms, sending: Tick)
  |> actor.start
}

/// Starts a watcher with no clock, which reads the file only when `tick` asks:
/// a test steps it.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(started) = config_watch.start_unticked(source, notify, logger)
/// ```
///
@internal
pub fn start_unticked(
  source: Source,
  notify: fn() -> Nil,
  logger: Logger,
) -> actor.StartResult(Subject(Message)) {
  new(source, notify, logger) |> actor.start
}

/// Reads the file once, as a tick does, and returns when the read is judged.
///
/// ## Examples
///
/// ```gleam
/// // config_watch.tick(started.data)
/// ```
///
@internal
pub fn tick(watcher: Subject(Message)) -> Nil {
  process.call(watcher, 5000, Probe)
}

/// The fingerprint a watcher compares: the SHA-256 of the file's text, in hex,
/// or `Error(Nil)` for a file that is missing, not a regular file, larger than
/// `max_file_bytes`, or not text.
///
/// ## Examples
///
/// ```gleam
/// // config_watch.fingerprint("/home/o/.loom/loom.toml")
/// ```
///
pub fn fingerprint(path: String) -> Result(String, Nil) {
  read(path) |> result.map(fn(pair) { pair.0 })
}

fn new(
  source: Source,
  notify: fn() -> Nil,
  logger: Logger,
) -> actor.Builder(State, Message, Subject(Message)) {
  State(
    source:,
    applied: source.baseline,
    seen: None,
    refused: None,
    notify:,
    logger:,
  )
  |> actor.new
  |> actor.on_message(handle)
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    Tick -> actor.continue(observe(state))
    Probe(reply:) -> {
      let state = observe(state)
      process.send(reply, Nil)
      actor.continue(state)
    }
  }
}

// One read, judged. The text is read before the fingerprint is compared, but it
// is checked only once two reads agree, so a file saved in pieces costs reads
// and never a parse of a half-written document.
fn observe(state: State) -> State {
  case read(state.source.path) {
    Error(Nil) -> State(..state, seen: None)
    Ok(#(digest, text)) -> {
      let now = Some(digest)
      case now == state.applied, now == state.seen {
        True, _ -> State(..state, seen: None)
        False, False -> State(..state, seen: now)
        False, True -> settle(state, digest, text)
      }
    }
  }
}

// A text two reads agreed on. One that passes is now the session's, and the hub
// is told; one that fails is remembered so it is logged once and not parsed on
// every tick.
fn settle(state: State, digest: String, text: String) -> State {
  let path = field.text("path", state.source.path)
  case Some(digest) == state.refused, state.source.check(text) {
    True, _ -> State(..state, seen: None)
    False, Ok(Nil) -> {
      log.info(state.logger, "config.changed", [path])
      state.notify()
      State(..state, applied: Some(digest), seen: None, refused: None)
    }
    False, Error(_) -> {
      log.warn(state.logger, "config.refused", [path])
      State(..state, seen: None, refused: Some(digest))
    }
  }
}

// The bounded read: the size is asked of the file before a byte is read.
fn read(path: String) -> Result(#(String, String), Nil) {
  use info <- result.try(
    simplifile.file_info(path) |> result.replace_error(Nil),
  )
  use <- bool.guard(
    when: simplifile.file_info_type(info) != simplifile.File
      || info.size > max_file_bytes,
    return: Error(Nil),
  )
  use text <- result.try(simplifile.read(path) |> result.replace_error(Nil))
  let digest =
    crypto.hash(crypto.Sha256, bit_array.from_string(text))
    |> bit_array.base16_encode
  Ok(#(digest, text))
}
