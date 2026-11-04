//// The commit scanner of a project worker: one session-scoped actor that reads
//// the worker's own log and tells the project actor what the log shows.
////
//// A worker is an ordinary session, so the owner can open it and type
//// (`docs/design-notes/project-mode.md`, "Stepping in"). Nothing in the
//// project actor sees that: it hears from a worker only through the worker's
//// tool calls. This scanner closes the gap in the way `client/rulescan` does.
//// It subscribes to the session writer's post-commit hints by name, takes
//// nothing from the hint, and reads the truth from the session store with a
//// branch scan.
////
//// ## What it reports
////
//// - **A person's turn.** A user message whose origin is a human principal is
////   handed to the project actor, keyed by the entry's id. The engine records
////   it as an explicit trigger on the ticket's thread. A user message with any
////   other origin is not a person's turn: the project's own deliveries carry a
////   trigger origin, a peer's message a peer origin, and neither is the owner
////   stepping in.
//// - **A report the actor may have missed.** `project_report` is a synchronous
////   call, so a report that was committed in the log has normally reached the
////   actor too. Where it did not, for example because the actor was
////   restarting when the call arrived, the log is the record. Of the reports
////   committed since the cursor, the scanner hands over the last. The actor
////   drops it if the ticket already holds that report.
////
//// ## Why a restart cannot record a turn twice
////
//// The cursor is a checkpoint, stored in the project ledger by session id. It
//// is written after the turns and reports it covers have been sent, and the
//// actor takes messages from this scanner in the order they were sent. A
//// scanner that is killed between sending and checkpointing starts from the
//// older cursor and sends those turns again, and the actor, which keys a turn
//// by its entry id, records each once. Correctness therefore rests on that key
//// and on the actor's comparison of reports, and the cursor only bounds how
//// much is read again.
////
//// ## Isolation
////
//// Every read goes straight to the session store and never through the
//// writer's mailbox, so a pass cannot sit in front of a settlement. The scanner
//// is a restartable service, and killing it costs the pass in flight.

import core/entry.{type Entry}
import core/ids.{type EntryId, type Seq}
import core/json.{type JsonValue}
import core/message
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import runtime/api.{type Runtime}
import runtime/residency
import runtime/writer
import session/session
import storage/storage
import telemetry/field
import telemetry/log.{type Logger}
import tools/project as tools
import weft/actor
import weft/registry as address

/// The most new entries one pass reads at a time. A pass repeats until a read
/// returns fewer, so a long history is read in pieces and not skipped.
pub const default_scan_limit = 256

/// The strand a worker's person types into. A worker's advisor strands are
/// not read, because a person's turn goes to the session's main strand.
const main_strand = "main"

/// A person's turn found in the log.
pub type Turn {
  Turn(
    /// The id of the entry that carried it.
    entry: String,
    /// The human principal that typed it.
    actor: String,
    /// The text, with the blocks of the message joined by newlines.
    text: String,
  )
}

/// The project actor's side of the scan, as closures so a test can stand a
/// recording fake in its place and the daemon can fill it from a handle.
pub type Feed {
  Feed(
    /// The id of the last entry already taken in, or `None` for a session
    /// never scanned.
    cursor: fn() -> Result(Option(String), String),
    /// Records a person's turn. It must be safe to repeat for one entry.
    turn: fn(Turn) -> Nil,
    /// Hands over the last report committed in a pass.
    report: fn(tools.WorkerReport) -> Nil,
    /// Moves the cursor to an entry id, after the turns and report above.
    checkpoint: fn(String) -> Nil,
  )
}

/// What the scanner is wired to and how much it reads at a time.
///
/// Constructor invariants: `scan_limit` is positive.
pub type Options {
  Options(feed: Feed, logger: Logger, scan_limit: Int)
}

// The actor holds the options, the session it reads, and how far it has read.
// `scanned` is `None` until the first pass has loaded the cursor, and a failed
// load leaves it `None` so the next hint tries again.
type State {
  State(options: Options, runtime: Runtime, scanned: Option(Seq))
}

/// The shipped options for a feed: a silent logger and the default limit.
///
/// ## Examples
///
/// ```gleam
/// // project_scan.default_options(feed)
/// ```
pub fn default_options(feed: Feed) -> Options {
  Options(feed:, logger: log.discard(), scan_limit: default_scan_limit)
}

/// Sets the logger the scanner reports unreadable cursors on.
///
/// ## Examples
///
/// ```gleam
/// // project_scan.default_options(feed) |> project_scan.with_logger(logger)
/// ```
pub fn with_logger(options: Options, logger: Logger) -> Options {
  Options(..options, logger:)
}

/// Starts the scanner under `name`, watching `runtime`'s session.
///
/// Register it as a writer subscriber by name (`api.Options.subscribers`), not
/// by the subject this returns. A restart then registers under the same name
/// and keeps the subscription, and the writer skips a subscriber whose name is
/// momentarily unregistered, so the restart window costs hints and not
/// commits.
///
/// ## Examples
///
/// ```gleam
/// // project_scan.start(project_scan.default_options(feed), runtime, name)
/// ```
pub fn start(
  options: Options,
  runtime: Runtime,
  name: address.Address(writer.Event),
) -> actor.StartResult(Subject(writer.Event)) {
  actor.new_with_initialiser(5000, fn(subject) {
    actor.initialised(State(options:, runtime:, scanned: None))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.addressed(name)
  |> actor.hibernate_after(residency.hibernate_after_ms)
  |> actor.start
}

/// The scanner as a supervision child, which is how a host should wire it: in
/// the restartable tier, beside the rule scanner.
///
/// ## Examples
///
/// ```gleam
/// // sup.add(builder, project_scan.supervised(options, runtime, name))
/// ```
pub fn supervised(
  options: Options,
  runtime: Runtime,
  name: address.Address(writer.Event),
) -> ChildSpecification(Subject(writer.Event)) {
  supervision.worker(fn() { start(options, runtime, name) })
}

/// A commit hint carries nothing the scanner uses, so every hint is a request
/// for one pass.
fn handle(
  state: State,
  _event: writer.Event,
) -> actor.Next(State, writer.Event) {
  actor.continue(pass(state))
}

/// One pass. The cursor is loaded once per incarnation, then every pass reads
/// from the position the last one reached.
fn pass(state: State) -> State {
  // A scanner that has not read its cursor yet must do so before it reads the
  // log, because reading from the start would send every old turn again.
  case state.scanned {
    Some(_) -> read_main(state)
    None ->
      case load_cursor(state) {
        Ok(seq) -> read_main(State(..state, scanned: Some(seq)))
        Error(reason) -> {
          log.warn(state.options.logger, "project.scan_cursor_unreadable", [
            field.text(key: "reason", value: reason),
          ])
          state
        }
      }
  }
}

/// Reads the main strand's new entries and acts on them. It repeats while a
/// read fills its limit, so a pass leaves nothing above the cursor behind.
fn read_main(state: State) -> State {
  let scanned = option.unwrap(state.scanned, 0)

  // A strand with no leaf has no log yet, and a store that will not answer is
  // not worth stopping for: the next commit brings the scanner back.
  case main_leaf(state) {
    Error(Nil) | Ok(None) -> state
    Ok(Some(leaf)) ->
      case new_entries(state, leaf, scanned) {
        Error(Nil) -> state
        Ok([]) -> state
        Ok(entries) -> {
          let advanced = digest(state, entries)

          // A read that filled its limit may have left more above it.
          case list.length(entries) >= state.options.scan_limit {
            True -> read_main(advanced)
            False -> advanced
          }
        }
      }
  }
}

/// What a batch of entries held, collected before anything is sent so the
/// order of sending is chosen in one place.
type Found {
  Found(turns: List(Turn), report: Option(tools.WorkerReport))
}

/// Sends what a batch shows, then moves the cursor over it. The turns go in
/// the order they were typed, then the last report, then the checkpoint, and
/// the actor takes them in that order.
fn digest(state: State, entries: List(Entry)) -> State {
  let found =
    list.fold(entries, Found(turns: [], report: None), fn(so_far, each) {
      read_entry(state, so_far, each)
    })
  let feed = state.options.feed
  list.each(list.reverse(found.turns), feed.turn)
  option.map(found.report, feed.report) |> option.unwrap(Nil)

  // The checkpoint names the newest entry read, whether or not it said
  // anything, so the next pass starts above it.
  case list.last(entries) {
    Error(Nil) -> state
    Ok(last) -> {
      feed.checkpoint(ids.entry_id_to_string(last.id))
      State(..state, scanned: Some(last.seq))
    }
  }
}

/// Folds one entry into what the batch holds.
fn read_entry(state: State, so_far: Found, each: Entry) -> Found {
  case each {
    entry.MessageEntry(id:, message: held, ..) ->
      read_message(state, so_far, id, held)
    entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> so_far
  }
}

/// A user message from a person is a turn, and a successful `project_report`
/// result is a report to replay. Every other message says nothing about the
/// project.
fn read_message(
  state: State,
  so_far: Found,
  id: EntryId,
  held: message.AgentMessage,
) -> Found {
  case held {
    message.UserMessage(content:, origin:, ..) ->
      case origin {
        Some(message.Origin(principal:, ..)) ->
          Found(..so_far, turns: [
            Turn(
              entry: ids.entry_id_to_string(id),
              actor: principal,
              text: user_text(content),
            ),
            ..so_far.turns
          ])

        // The project's own deliveries, a peer's message and another strand's
        // are not the owner stepping in.
        Some(message.PeerOrigin(..))
        | Some(message.StrandOrigin(..))
        | Some(message.TriggerOrigin(..))
        | None -> so_far
      }
    message.ToolResultMessage(tool_call_id:, tool_name:, is_error:, ..) ->
      case tool_name == tools.report_tool_name, is_error {
        True, False ->
          case report_of(state, id, tool_call_id) {
            Ok(report) -> Found(..so_far, report: Some(report))
            Error(Nil) -> so_far
          }
        True, True | False, _ -> so_far
      }
    message.AssistantMessage(..) | message.CustomMessage(..) -> so_far
  }
}

/// The text of a user message, with its blocks joined by newlines. An image
/// has no text and contributes nothing.
fn user_text(content: List(message.UserBlock)) -> String {
  content
  |> list.filter_map(fn(block) {
    case block {
      message.UserText(text:, ..) -> Ok(text)
      message.UserImage(..) -> Error(Nil)
    }
  })
  |> string.join("\n")
}

/// The report a committed result answered. The result carries only "recorded",
/// so the report is read from the arguments of the call it answers. That call
/// is among the result's nearest ancestors, and the read is bounded so a
/// result whose call is gone costs one small read and no more.
fn report_of(
  state: State,
  result_id: EntryId,
  call_id: String,
) -> Result(tools.WorkerReport, Nil) {
  let q =
    storage.branch_scan(from: result_id)
    |> storage.branch_kind(storage.Message)
    |> storage.branch_limit(16)
  use ancestors <- result.try(
    storage.scan_branch(state.runtime.session.store, q)
    |> result.replace_error(Nil),
  )
  list.find_map(ancestors, fn(each) { call_arguments(each, call_id) })
  |> result.try(fn(arguments) {
    tools.decode_report(arguments) |> result.replace_error(Nil)
  })
}

/// The arguments of the `project_report` call with this id, if the entry is the
/// assistant message that made it.
fn call_arguments(each: Entry, call_id: String) -> Result(JsonValue, Nil) {
  case each {
    entry.MessageEntry(message: message.AssistantMessage(content:, ..), ..) ->
      list.find_map(content, fn(block) {
        case block {
          message.AssistantToolCall(call:) ->
            case call.id == call_id && call.name == tools.report_tool_name {
              True -> Ok(call.arguments)
              False -> Error(Nil)
            }
          message.AssistantText(..) | message.AssistantThinking(..) ->
            Error(Nil)
        }
      })
    entry.MessageEntry(..)
    | entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> Error(Nil)
  }
}

/// The seq the cursor entry sits at, or zero for a session never scanned. A
/// cursor that names no entry the store has is treated as no cursor: reading
/// the log again is harmless, and refusing to scan would leave turns unread.
fn load_cursor(state: State) -> Result(Seq, String) {
  use found <- result.try(state.options.feed.cursor())

  // A cursor that does not parse is as good as none.
  case found {
    None -> Ok(0)
    Some(text) ->
      case ids.parse_entry_id(text) {
        Error(_) -> Ok(0)
        Ok(id) -> Ok(seq_of(state, id))
      }
  }
}

/// The seq of an entry, read as the first entry of the path from it to the
/// root. An entry the store does not have reads as zero.
fn seq_of(state: State, id: EntryId) -> Seq {
  let q = storage.branch_scan(from: id) |> storage.branch_limit(1)

  // Newest first, the first entry of the path is the entry itself.
  case storage.scan_branch(state.runtime.session.store, q) {
    Ok([first, ..]) -> first.seq
    Ok([]) | Error(_) -> 0
  }
}

/// The leaf of the main strand. `Ok(None)` is a strand with no entries yet, and
/// `Error` a register that would not read.
fn main_leaf(state: State) -> Result(Option(EntryId), Nil) {
  case session.strand_leaf(state.runtime.session, main_strand) {
    Ok(Some(session.Cell(value: leaf, ..))) -> Ok(leaf)
    Ok(None) -> Ok(None)
    Error(_reason) -> Error(Nil)
  }
}

/// New messages on the strand's branch, oldest first, clipped by the cursor
/// before anything is fetched or decoded.
fn new_entries(
  state: State,
  leaf: EntryId,
  after: Seq,
) -> Result(List(Entry), Nil) {
  let q =
    storage.branch_scan(from: leaf)
    |> storage.branch_kind(storage.Message)
    |> storage.branch_order(storage.OldestFirst)
    |> storage.branch_cursor(after)
    |> storage.branch_limit(state.options.scan_limit)
  storage.scan_branch(state.runtime.session.store, q)
  |> result.replace_error(Nil)
}
