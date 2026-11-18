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
//// `start` → `observe` → `read_text` → `session_view` → `settle`
////
//// 1. `start` runs one weft actor per session, in the session's restartable
////    service tier, which observes the file once a tick.
//// 2. `observe` reads it with `read_text`, which is bounded: a file that is not a
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

import client/untrusted_config
import gleam/bit_array
import gleam/bool
import gleam/crypto
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile
import telemetry/field
import telemetry/log.{type Logger}
import tom
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
    // The SHA-256 of the raw text that failed the check, so it is logged once.
    // It is keyed on the text, not the view: the check also validates the tables
    // the view leaves out, so a fix made only in one of them must be judged
    // again.
    refused: Option(String),
    // The raw text hash of the last read and the view digest computed from it,
    // so an unchanged file costs a read and a hash and no parse.
    last: Option(#(String, String)),
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

/// The fingerprint a watcher compares: the SHA-256, in hex, of what a session
/// reads from the file (`session_view`), or `Error(Nil)` for a file that is
/// missing, not a regular file, larger than `max_file_bytes`, or not text.
///
/// ## Examples
///
/// ```gleam
/// // config_watch.fingerprint("/home/o/.loom/loom.toml")
/// ```
///
pub fn fingerprint(path: String) -> Result(String, Nil) {
  read_text(path) |> result.map(view_digest)
}

/// Builds an actor builder for config watcher.
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
    last: None,
    notify:,
    logger:,
  )
  |> actor.new
  |> actor.on_message(handle)
}

/// Handles incoming timer tick or inspection probe.
fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  // Dispatch according to incoming message.
  case message {
    Tick -> actor.continue(observe(state))
    Probe(reply:) -> {
      let state = observe(state)
      process.send(reply, Nil)
      actor.continue(state)
    }
  }
}

/// Performs one observation pass on the configured file.
///
/// One read, judged. The text is read before the fingerprint is compared, but the
/// loader sees it only once two reads agree, so a file saved in pieces costs
/// reads and never a check of a half-written text.
fn observe(state: State) -> State {
  // Read file from disk and compare fingerprint.
  case read_text(state.source.path) {
    Error(Nil) -> State(..state, seen: None)
    Ok(text) -> {
      let raw = hash(text)

      // The view is parsed only when the bytes changed since the last read.
      let digest = case state.last {
        Some(#(last_raw, last_view)) if last_raw == raw -> last_view
        _ -> view_digest(text)
      }

      let state = State(..state, last: Some(#(raw, digest)))
      let now = Some(digest)

      // Settle change once two consecutive reads agree on new digest.
      case now == state.applied, now == state.seen {
        True, _ -> State(..state, seen: None)
        False, False -> State(..state, seen: now)
        False, True -> settle(state, digest, raw, text)
      }
    }
  }
}

/// Settles an agreed-upon configuration text and notifies the hub if valid.
///
/// A text two reads agreed on. One that passes is now the session's, and the hub
/// is told; one that fails is remembered by the hash of its text so it is logged
/// once and not checked on every tick.
fn settle(state: State, digest: String, raw: String, text: String) -> State {
  let path = field.text("path", state.source.path)

  // A text already refused is not checked again.
  use <- bool.guard(
    when: Some(raw) == state.refused,
    return: State(..state, seen: None),
  )

  // Otherwise the loader judges it.
  case state.source.check(text) {
    Ok(Nil) -> {
      log.info(state.logger, "config.changed", [path])
      state.notify()
      State(..state, applied: Some(digest), seen: None, refused: None)
    }
    Error(_) -> {
      log.warn(state.logger, "config.refused", [path])
      State(..state, seen: None, refused: Some(raw))
    }
  }
}

/// Reads the file's text if it is within limits.
///
/// The bounded read: the size is asked of the file before a byte is read.
fn read_text(path: String) -> Result(String, Nil) {
  use info <- result.try(
    simplifile.file_info(path) |> result.replace_error(Nil),
  )
  use <- bool.guard(
    when: simplifile.file_info_type(info) != simplifile.File
      || info.size > max_file_bytes,
    return: Error(Nil),
  )
  simplifile.read(path) |> result.replace_error(Nil)
}

/// The SHA-256 of a text, in hex.
fn hash(text: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(text))
  |> bit_array.base16_encode
}

/// The fingerprint of what a session reads from a text.
fn view_digest(text: String) -> String {
  hash(session_view(text))
}

/// The text a fingerprint is taken of: the parsed document in a fixed order,
/// without the tables only the daemon reads.
///
/// Two texts with the same view give a session the same values, which is what
/// lets the watcher ignore the difference. One of them may still be refused by
/// the validators of the tables left out, which is why a refusal is remembered
/// by the text and not by the view. A text that does not parse is returned as
/// it is, so the old rule (the whole text, settled by two reads, then checked)
/// applies to it unchanged.
///
/// ## Examples
///
/// ```gleam
/// // config_watch.session_view("[executors.a]\nnode = \"x@h\"\n")
/// //   == config_watch.session_view("")
/// ```
///
@internal
pub fn session_view(text: String) -> String {
  // A text that is not a TOML document has no tables to leave out, so it stands
  // for itself; a document is rendered without the daemon's tables.
  case tom.parse(text) {
    Error(_) -> text
    Ok(document) -> {
      // A session reads the key paths of the two untrusted-link tables and
      // nothing else in them; a table the reader refuses names none, exactly as
      // `serve.link_secrets` would find.
      let masked =
        untrusted_config.from_document(document)
        |> result.map(untrusted_config.secret_files)
        |> result.unwrap([])

      document
      |> dict.drop(daemon_tables)
      |> render_fields
      |> string.append("\nmasked keys: " <> string.inspect(masked))
    }
  }
}

/// The top-level tables a session never reads a value from. `executor_link` and
/// `executor_listener` are here because the view carries their one read, the
/// key paths, apart from the tables themselves.
const daemon_tables = [
  "executors", "distribution", "executor_link", "executor_listener",
]

/// Renders a table's entries ordered by key, so two documents that hold the
/// same values render the same whatever order the file wrote them in.
fn render_fields(fields: Dict(String, tom.Toml)) -> String {
  fields
  |> dict.to_list
  |> list.sort(fn(left, right) { string.compare(left.0, right.0) })
  |> list.map(fn(entry) { string.inspect(entry.0) <> "=" <> render(entry.1) })
  |> string.join(";")
}

/// Renders one value. Containers recurse; every scalar is its own `inspect`,
/// which is exact for each of them.
fn render(value: tom.Toml) -> String {
  case value {
    tom.Table(fields) -> "table{" <> render_fields(fields) <> "}"
    tom.InlineTable(fields) -> "inline{" <> render_fields(fields) <> "}"
    tom.Array(items) -> "[" <> string.join(list.map(items, render), ",") <> "]"
    tom.ArrayOfTables(rows) ->
      "tables["
      <> string.join(
        list.map(rows, fn(row) { "{" <> render_fields(row) <> "}" }),
        ",",
      )
      <> "]"
    tom.Int(_)
    | tom.Float(_)
    | tom.Infinity(_)
    | tom.Nan(_)
    | tom.Bool(_)
    | tom.String(_)
    | tom.Date(_)
    | tom.Time(_)
    | tom.DateTime(..) -> string.inspect(value)
  }
}
