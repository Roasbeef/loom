//// The history index holder: the one process that owns this
//// repository's search database, and the seams that reach it.
////
//// # Why a holder, and why by name
////
//// `events/search` is a `sqlight` connection behind an opaque handle. A
//// connection is not a value to be copied into every closure that might
//// want it: syncs and queries must serialize somewhere, and a crash must
//// be able to reopen the file rather than leave every holder of a stale
//// handle answering faults forever. So one actor owns it, started under
//// a process **name** by the host's service supervisor — the same
//// indirection `client/scratch` and the Agency use — and both the tool
//// seam and the commit-driven sync reach it through that name. A restart
//// reopens the index file and is the same address.
////
//// # Sync is driven by the writer's commit publication
////
//// Indexing is pull-based: an event never carries content, it only says
//// "something changed, go look" (`events/search`'s module doc). The hint
//// here is the runtime writer's own post-commit publication, delivered to
//// a second subscriber built exactly like `client/gateway.commit_forwarder`
//// — a tiny actor under its own name whose entire job is to poke the
//// holder. That is deliberately *not* the event bus: a one-session server's
//// writer sits in the same VM as its index, so the bus would only make the
//// same pull happen twice, and standing one up would buy a `pg` scope for
//// nothing. A lost poke costs latency and never a row, because `sync`'s own
//// durable cursor decides what to index, not the poke.
////
//// # What the index is for, and why it is protected
////
//// Snippets from this index feed *future* sessions' contexts. A
//// model-writable index is therefore prompt injection with a persistence
//// layer, which is why the host adds the index file to the session base
//// policy's `protected` list: no jailed process and no harness-side write
//// tool may write it, while reads stay readable. This module holds the
//// other half of that bargain — the only writer is `sync`, and `sync`
//// only ever copies text that is already durable in a session file.
////
//// # Two accepted gaps
////
//// **No backfill.** A session's rows enter the index while it runs. The
//// holder syncs once at start, so reopening a pre-wiring session indexes
//// its whole file; a session that is never reopened stays unfindable.
////
//// **A digest is indexed like anything else.** The `agent/` notes digest
//// injected at run start is an ordinary user message, so it is indexed
//// too. It is bounded by its own cap and by the fact that it quotes cells
//// that are already durable, and the structural anti-feedback exclusion
//// belongs to memory stage M2 rather than here.

import core/codec
import core/ids.{type SessionId}
import core/json.{type JsonValue}
import events/search.{type Search, type SearchError}
import gleam/erlang/process.{type Name, type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import runtime/internal/ffi_sup
import runtime/writer
import simplifile
import storage/sqlite
import storage/storage.{type Storage}
import tools/history as history_tool

/// The index database's file name. One file per repository, beside the
/// session file rather than inside it: the index spans every session, and
/// a projection with no authority has no business living in the store it
/// projects.
pub const index_file = "loom-search.db"

/// How long a seam call waits for the holder to answer.
///
/// A query is one FTS5 `MATCH` against a local file, and a sync is a
/// scan plus one transaction, so a holder that has not answered in five
/// seconds is a holder that is wedged behind something large — and a
/// tool call is better refused in band, naming the index, than left
/// hanging inside the model's turn.
pub const default_timeout_ms = 5000

/// The index file that belongs beside `session_path`.
///
/// ## Examples
///
/// ```gleam
/// assert history.index_beside("/data/review.db") == "/data/loom-search.db"
/// ```
///
/// ```gleam
/// assert history.index_beside("review.db") == "loom-search.db"
/// ```
///
pub fn index_beside(session_path: String) -> String {
  case list.reverse(string.split(session_path, "/")) {
    [_file, ..rest] if rest != [] ->
      string.join(list.reverse(rest), "/") <> "/" <> index_file
    _ -> index_file
  }
}

/// Whether an index at `path` can be opened at all, asked once at boot.
///
/// A host that cannot open its index registers no `history_search` tool
/// and says so in one line, rather than refusing the boot: recall is a
/// convenience over a rebuildable projection, and a session that cannot
/// search its own past is still a session. Gating registration rather
/// than refusing at call time is the same arithmetic `code_mode` is
/// gated on — a tool definition renders into the provider's cached byte
/// prefix and is paid for on every request for the life of the session.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = history.probe("/data/loom-search.db")
/// ```
///
pub fn probe(path: String) -> Result(Nil, String) {
  probed(path)
  // The path is in the message because sqlite's own open failure can be
  // an empty string, and "the index would not open" with nothing after
  // it is the log line an operator cannot act on.
  |> result.map_error(fn(reason) {
    "the index at " <> path <> " would not open: " <> reason
  })
}

fn probed(path: String) -> Result(Nil, String) {
  use opened <- result.try(
    search.open(path) |> result.map_error(describe_search_error),
  )
  search.close(opened) |> result.map_error(describe_search_error)
}

/// What a holder needs: where the index is, which session it syncs, and
/// how to pull that session's new entries into it.
///
/// Constructor invariants: `path` is the index database file (the holder
/// opens it itself, and reopens it on restart); `session` is the
/// *canonical* id of the session this holder serves, which is what
/// `ThisSession` scopes to and what a hit from this session is named by;
/// `pull` is total and does its own generation read.
pub type Config {
  Config(
    name: Name(Message),
    path: String,
    session: SessionId,
    pull: fn(Search) -> Result(Nil, String),
    timeout_ms: Int,
  )
}

/// A holder over one open session's store.
///
/// `generation` is a **thunk**, called fresh on every pull rather than
/// captured once, for the reason `events/projection.Options` gives: a
/// precise rewrite swaps the store and bumps the counter underneath a
/// long-lived holder, and a sync that indexed new rows under the old
/// generation would leave the index quietly wrong until something else
/// noticed. A generation that cannot be read skips the sync outright
/// rather than guessing zero — guessing costs a full drop-and-reindex
/// the moment the real number comes back.
///
/// ## Examples
///
/// ```gleam
/// // history.over_session(name:, path:, session:, store: opened.store,
/// //   generation: history.sqlite_generation(session_path), timeout_ms: 5000)
/// ```
///
pub fn over_session(
  name name: Name(Message),
  path path: String,
  session session: SessionId,
  store store: Storage(handle),
  generation generation: fn() -> Result(Int, String),
  timeout_ms timeout_ms: Int,
) -> Config {
  Config(name:, path:, session:, timeout_ms:, pull: fn(index) {
    use generation <- result.try(generation())
    search.sync(index, store, session:, generation:)
    |> result.map_error(describe_search_error)
  })
}

/// Registers this session's source while synchronizing its index.
/// The path comes from host settings, never from tool arguments.
///
/// ## Examples
///
/// ```gleam
/// // config |> history.with_source("/data/session.db")
/// ```
pub fn with_source(config: Config, path: String) -> Config {
  // Capture the host's working directory now. A repository index is shared
  // by sessions launched from different directories, so a relative locator
  // would later resolve against whichever host happened to read it.
  let source = case string.starts_with(path, "/") {
    True -> Ok(path)
    False ->
      simplifile.current_directory()
      |> result.map(fn(here) { here <> "/" <> path })
      |> result.map_error(fn(error) {
        "history source has no absolute path: " <> string.inspect(error)
      })
  }
  Config(..config, pull: fn(index) {
    use path <- result.try(source)
    use Nil <- result.try(config.pull(index))
    search.register_source(index, config.session, path)
    |> result.map_error(describe_search_error)
  })
}

/// The rewrite-generation thunk for a SQLite session file.
///
/// ## Examples
///
/// ```gleam
/// // history.sqlite_generation("/data/review.db")() == Ok(0)
/// ```
///
pub fn sqlite_generation(session_path: String) -> fn() -> Result(Int, String) {
  fn() {
    sqlite.generation(path: session_path)
    |> result.map_error(fn(error) {
      "the session's rewrite generation could not be read: "
      <> string.inspect(error)
    })
  }
}

/// What the holder is asked. Opaque: callers reach it through `seam`,
/// `poke` and `synchronize`, so there is one place that decides what a
/// wedged or absent holder answers.
pub opaque type Message {
  /// A commit landed: pull whatever is new into the index.
  Pull

  /// Pull, and say whether it worked — the deterministic form a test
  /// (or an operator's line) needs, since `Pull` is a cast.
  Synchronize(reply_with: Subject(Result(Nil, String)))
  Query(
    text: String,
    limit: Int,
    scope: history_tool.Scope,
    reply_with: Subject(Result(List(history_tool.Hit), String)),
  )
  ReadEntry(
    session: SessionId,
    entry: ids.EntryId,
    reply_with: Subject(Result(JsonValue, String)),
  )
  Stop
}

type State {
  // `None` is an index that could not be opened: the holder stays alive
  // and answers in band rather than crashing, because it sits in the
  // restartable tier where a start that can fail turns a bad file on
  // disk into a restart loop that spends the tier's shared budget and
  // takes the whole server with it — for a projection with no
  // authority. `None` is settled for this incarnation: `start` is the
  // one place the file is opened, so a supervisor restart over a
  // repaired file is the recovery — deliberately not a retry on every
  // message, which is machinery for a state an operator repairs once.
  State(index: Option(Search), config: Config)
}

/// Starts the holder under its configured name, opening the index file.
///
/// The open happens here rather than being handed in, so a restart
/// reopens the file: a connection captured at boot and handed to a
/// replacement process would make the restart pointless.
///
/// ## Examples
///
/// ```gleam
/// // history.start(config)
/// ```
///
pub fn start(
  config: Config,
) -> Result(actor.Started(Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(subject) {
    // An index that will not open does not fail the start (see `State`);
    // the boot's `probe` is what gates tool registration, and a holder
    // that opens nothing serves refusals until the file is repaired.
    let index = option.from_result(search.open(config.path))

    // The session's existing entries are indexed by the first pull, not
    // by the initialiser: a large session file's scan must not sit
    // inside the supervisor's start timeout.
    process.send(subject, Pull)
    actor.initialised(State(index:, config:))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.named(config.name)
  |> actor.on_message(handle)
  |> actor.start
}

/// The holder as a supervisable child, which is how a host wires it.
///
/// It belongs in the restartable tier: it is addressed by name, and
/// everything it holds — one connection to a rebuildable projection — a
/// restart rebuilds by reopening the file. A crash costs the hints that
/// arrived while it was down, and `sync`'s durable cursor makes those
/// cost latency rather than rows.
pub fn supervised(config: Config) -> ChildSpecification(Subject(Message)) {
  supervision.worker(fn() { start(config) })
}

/// Stops the holder and closes its connection.
pub fn stop(name: Name(Message)) -> Nil {
  case process.named(name) {
    Error(Nil) -> Nil
    Ok(pid) -> ffi_sup.send_to_pid(pid, #(name, Stop))
  }
}

/// Hints the holder that something committed. A cast, and a lost one
/// costs latency only.
pub fn poke(name: Name(Message)) -> Nil {
  case process.named(name) {
    Error(Nil) -> Nil
    Ok(pid) -> ffi_sup.send_to_pid(pid, #(name, Pull))
  }
}

/// Pulls this session's new entries into the index and reports what
/// happened — the synchronous counterpart to `poke`.
///
/// ## Examples
///
/// ```gleam
/// // history.synchronize(name, timeout_ms: 5000) == Ok(Nil)
/// ```
///
pub fn synchronize(
  name: Name(Message),
  timeout_ms timeout_ms: Int,
) -> Result(Nil, String) {
  ask(name, timeout_ms, Synchronize) |> result.flatten
}

/// The recall seam over the holder registered under `name`.
///
/// Closes over the *name* rather than a subject for the reason
/// `client/scratch.seam` does: the seam is built while the tool registry
/// is assembled and the holder starts later, under a supervisor, so a
/// captured subject would go stale on the first restart.
///
/// A holder that is not running, or does not answer inside `timeout_ms`,
/// is an in-band `IndexUnavailable` and never a dead caller —
/// `process.call` exits its caller on a timeout or a dead callee, and
/// this runs on a tool call's own effect process inside a live turn.
///
/// ## Examples
///
/// ```gleam
/// // tools/history.tool(history.seam(name, timeout_ms: 5000))
/// ```
///
pub fn seam(
  name: Name(Message),
  timeout_ms timeout_ms: Int,
) -> history_tool.History {
  history_tool.History(
    read: fn(session, entry) {
      ask(name, timeout_ms, ReadEntry(session:, entry:, reply_with: _))
      |> result.map_error(fn(reason) { history_tool.IndexUnavailable(reason:) })
      |> result.try(fn(result) {
        result
        |> result.map_error(fn(reason) { history_tool.IndexRefused(reason:) })
      })
    },
    search: fn(text, limit, scope) {
      case ask(name, timeout_ms, Query(text:, limit:, scope:, reply_with: _)) {
        Error(reason) -> Error(history_tool.IndexUnavailable(reason:))

        // A holder that is alive but holds nothing is unavailability,
        // not a refusal: the tool's refusal rendering suggests rephrasing
        // the query, and no rephrasing opens an index.
        Ok(Error(reason)) if reason == unavailable_index ->
          Error(history_tool.IndexUnavailable(reason:))
        Ok(Error(reason)) -> Error(history_tool.IndexRefused(reason:))
        Ok(Ok(hits)) -> Ok(hits)
      }
    },
  )
}

/// Starts the commit subscriber that turns the runtime writer's
/// post-commit publication into holder pulls, registered under
/// `as_name`.
///
/// Subscribe the writer to `process.named_subject(as_name)` rather than
/// to the returned subject, exactly as `client/gateway.commit_forwarder`
/// is subscribed: the subscriber holds no state, so it is restartable,
/// and a subscription made by name survives the restart while one made
/// to a pid does not.
///
/// ## Examples
///
/// ```gleam
/// // api.Options(..options, subscribers: [process.named_subject(pulls)])
/// ```
///
pub fn commit_pull(
  to name: Name(Message),
  as_name as_name: Name(writer.Event),
) -> actor.StartResult(Subject(writer.Event)) {
  actor.new(Nil)
  |> actor.on_message(fn(_state, _event: writer.Event) {
    poke(name)
    actor.continue(Nil)
  })
  |> actor.named(as_name)
  |> actor.start
}

/// The commit subscriber as a supervisable child.
pub fn supervised_commit_pull(
  to name: Name(Message),
  as_name as_name: Name(writer.Event),
) -> ChildSpecification(Subject(writer.Event)) {
  supervision.worker(fn() { commit_pull(to: name, as_name:) })
}

// --- internals -------------------------------------------------------------

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message, state.index {
    Pull, Some(index) -> {
      // A hint's pull is best effort: a failed sync leaves the durable
      // cursor exactly where it was, so the next hint retries it.
      let _pulled = state.config.pull(index)
      actor.continue(state)
    }
    Pull, None -> actor.continue(state)
    Synchronize(reply_with:), Some(index) -> {
      process.send(reply_with, state.config.pull(index))
      actor.continue(state)
    }
    Synchronize(reply_with:), None -> {
      process.send(reply_with, Error(unavailable_index))
      actor.continue(state)
    }
    Query(text:, limit:, scope:, reply_with:), Some(index) -> {
      process.send(reply_with, query(state, index, text, limit, scope))
      actor.continue(state)
    }
    Query(reply_with:, ..), None -> {
      process.send(reply_with, Error(unavailable_index))
      actor.continue(state)
    }
    ReadEntry(session:, entry:, reply_with:), Some(index) -> {
      process.send(reply_with, read_entry(index, session, entry))
      actor.continue(state)
    }
    ReadEntry(reply_with:, ..), None -> {
      process.send(reply_with, Error(unavailable_index))
      actor.continue(state)
    }
    Stop, Some(index) -> {
      let _closed = search.close(index)
      actor.stop()
    }
    Stop, None -> actor.stop()
  }
}

fn read_entry(
  index: Search,
  session: SessionId,
  entry: ids.EntryId,
) -> Result(JsonValue, String) {
  use source <- result.try(
    search.source(index, session) |> result.map_error(describe_search_error),
  )
  use path <- result.try(case source {
    Some(path) -> Ok(path)
    None ->
      Error(
        "no registered source for this session; reopen it to enable exact reads",
      )
  })
  sqlite.read_entry(path:, session:, entry:)
  |> result.map(codec.encode_entry)
  |> result.map_error(fn(error) { string.inspect(error) })
}

const unavailable_index = "the search index could not be opened; recall is "
  <> "refused in band until a restart over a repaired file. Removing a "
  <> "corrupt index is safe: the restart recreates it and a sync "
  <> "rebuilds the rows."

fn query(
  state: State,
  index: Search,
  text: String,
  limit: Int,
  scope: history_tool.Scope,
) -> Result(List(history_tool.Hit), String) {
  let found = case scope {
    history_tool.Repository -> search.query(index, text:, limit:)

    // Scoping is in the SQL, not over the results: `rank` and `LIMIT`
    // are applied inside the query, so a post-filter would let a
    // ten-hit request narrowed to one session come back empty while
    // that session has matches.
    history_tool.ThisSession ->
      search.query_in_session(
        index,
        session: state.config.session,
        text:,
        limit:,
      )
  }
  found
  |> result.map(
    list.map(_, fn(hit) {
      history_tool.Hit(
        session: hit.session,
        entry: hit.entry,
        snippet: hit.snippet,
      )
    }),
  )
  |> result.map_error(describe_search_error)
}

// One question to the holder, degrading an absent or wedged holder to an
// in-band refusal rather than to the caller's death. Sent and selected
// by hand, watching the callee's monitor — the pattern
// `client/scratch.ask` and `client/escalate.borrow` use, and for the
// same reason: `process.call` exits its *caller*, and this runs inside a
// live tool call.
fn ask(
  name: Name(Message),
  timeout_ms: Int,
  message: fn(Subject(answer)) -> Message,
) -> Result(answer, String) {
  case process.named(name) {
    Error(Nil) -> Error(no_holder)
    Ok(pid) -> {
      let reply = process.new_subject()
      let monitor = process.monitor(pid)

      // Send to the PID the monitor describes. Re-resolving the name here could
      // panic during a restart or ask a replacement while watching its
      // predecessor.
      ffi_sup.send_to_pid(pid, #(name, message(reply)))
      let answered =
        process.new_selector()
        |> process.select_map(reply, Some)
        |> process.select_specific_monitor(monitor, fn(_down) { None })
        |> process.selector_receive(within: timeout_ms)
      process.demonitor_process(monitor)
      case answered {
        Ok(Some(value)) -> Ok(value)
        Ok(None) | Error(Nil) -> Error(wedged)
      }
    }
  }
}

const no_holder = "this host runs no history index"

const wedged = "the history index did not answer in time"

fn describe_search_error(error: SearchError) -> String {
  case error {
    search.IndexFault(message:) -> message
    search.SessionReadFault(error:) ->
      "the session could not be read for indexing: " <> string.inspect(error)
  }
}
