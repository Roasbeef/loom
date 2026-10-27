//// Loom's durable conversation, projected into ACP's vocabulary.
////
//// Everything the bridge says to an ACP client about a turn is derived here,
//// from data the daemon already made durable: entries of the conversation
//// tree, the pending-escalation records, the strand's terminal result and the
//// cumulative usage. The functions are pure. That is the point of the split
//// from the session driver: what an assistant message, a tool result or an
//// approval request *means* in ACP can be tested with hand-built entries and
//// no daemon, and the driver is left with only ordering and custody.
////
//// The projection is deliberately lossy in one direction. ACP has no word for
//// compaction entries, custom entries or branch summaries, so they produce no
//// update; they are Loom's bookkeeping, not part of the conversation a
//// client renders. Nothing here invents content: a tool's title is built from
//// the call's own name and arguments, an approval's text from the same
//// `approval.presentation` the terminal shows.
////
//// ## Flow
////
//// `entry_updates` → `tool_call` / `tool_result`; `permission` → `decision`
////
//// 1. `entry_updates` maps one entry to zero or more `session/update` values.
////    Text the live stream already delivered is skipped, by comparing content
////    with what was streamed, so a client never sees an answer twice.
//// 2. `permission` turns a pending escalation into a permission request, and
////    `decision` turns the client's choice back into what the daemon needs.
//// 3. `outcome` and `turn_usage` close a turn.

import core/entry
import core/json.{type JsonValue}
import core/message
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import machine/operation
import session_view/approval
import tui/acp/schema

/// Whether entries are being shown as they happen or replayed from history.
pub type Mode {
  /// A turn in progress. The user's own message is not echoed back, because
  /// the client just sent it.
  Live

  /// A `session/load` replay. The user's messages are part of the history the
  /// client asked for, so they are sent as `user_message_chunk`.
  Replay
}

/// What the client's permission choice means to the daemon.
pub type Decision {
  /// Grant exactly what was shown, once.
  Approve

  /// Grant it and remember it for the session.
  ApproveForSession

  /// Refuse.
  Deny
}

/// Whether the client has asked the running turn to stop.
pub type Cancellation {
  /// Nothing has asked the turn to stop.
  NotAsked

  /// The client sent `session/cancel`.
  Asked
}

/// Provider text the live connection delivered that no durable entry has
/// accounted for yet.
///
/// The daemon pushes fragments as the model writes and commits the finished
/// message later, so the same words arrive twice. The bridge shows the
/// fragments immediately and keeps them here; when the durable message turns
/// up it is compared with what was already shown, and only what the client has
/// not seen is sent. Comparing content rather than counting messages keeps the
/// reconciliation correct when a stream is cut short, when the next request
/// has begun streaming before the previous entry was fetched, and when a
/// provider streams nothing at all.
pub type Streamed {
  Streamed(
    /// Answer text shown but not yet matched by a durable block.
    text: String,
    /// Reasoning text shown but not yet matched by a durable block.
    thinking: String,
  )
}

/// How a prompt turn ended.
pub type Outcome {
  /// The turn ended and ACP has a stop reason for it.
  Stopped(reason: schema.StopReason)

  /// The turn failed; the text is a bounded diagnostic.
  Errored(reason: String)
}

/// The longest tool output sent in one update, in characters.
///
/// Tool results are bounded by the tools themselves; this second bound exists
/// because a protocol peer, unlike the terminal, may render every byte it is
/// given.
pub const max_output_chars = 65_536

/// The most streamed text kept per kind while it waits for its durable block.
///
/// A turn that streams more than this without a single entry being fetched is
/// not a turn the bridge can reconcile; the oldest text is simply forgotten,
/// which can at worst repeat it once.
pub const max_streamed_chars = 1_048_576

/// Nothing streamed and unmatched.
pub const nothing_streamed = Streamed("", "")

/// The option id of the single-use grant.
pub const allow_option = "allow"

/// The option id of the session-scoped grant.
pub const allow_session_option = "allow_session"

/// The option id of the refusal.
pub const reject_option = "reject"

/// Projects one conversation entry into the updates a client should see.
///
/// `streamed` is what the live connection already delivered; blocks it covers
/// are not repeated, and the remainder is handed back for the next entry.
/// Replay passes `nothing_streamed`, since nothing was streamed to a client
/// that has only just attached.
///
/// ## Examples
///
/// ```gleam
/// // let #(updates, streamed) =
/// //   translate.entry_updates(entry, translate.Live, translate.nothing_streamed)
/// ```
pub fn entry_updates(
  entry: entry.Entry,
  mode: Mode,
  streamed: Streamed,
) -> #(List(schema.Update), Streamed) {
  // Only messages are conversation; the other entry kinds are bookkeeping.
  case entry {
    entry.MessageEntry(message:, ..) -> message_updates(message, mode, streamed)
    entry.CompactionEntry(..)
    | entry.BranchSummaryEntry(..)
    | entry.CustomEntry(..) -> #([], streamed)
  }
}

/// Projects one message by its role.
fn message_updates(
  message: message.AgentMessage,
  mode: Mode,
  streamed: Streamed,
) -> #(List(schema.Update), Streamed) {
  case message, mode {
    message.UserMessage(content:, ..), Replay -> #(
      list.filter_map(content, user_block),
      streamed,
    )

    message.UserMessage(..), Live -> #([], streamed)

    message.AssistantMessage(content:, ..), _ ->
      assistant_updates(content, streamed)

    message.ToolResultMessage(tool_call_id:, content:, is_error: True, ..), _ -> #(
      [tool_result(tool_call_id, content, schema.Failed)],
      streamed,
    )

    message.ToolResultMessage(tool_call_id:, content:, is_error: False, ..), _
    -> #([tool_result(tool_call_id, content, schema.Completed)], streamed)

    message.CustomMessage(..), _ -> #([], streamed)
  }
}

/// Projects an assistant message's blocks in order, threading what was streamed.
fn assistant_updates(
  blocks: List(message.AssistantBlock),
  streamed: Streamed,
) -> #(List(schema.Update), Streamed) {
  let #(updates, streamed) =
    list.fold(blocks, #([], streamed), fn(state, block) {
      let #(shown, streamed) = state
      let #(more, streamed) = assistant_block(block, streamed)
      #(list.append(shown, more), streamed)
    })
  #(updates, streamed)
}

/// One assistant block as updates, minus whatever the stream already showed.
fn assistant_block(
  block: message.AssistantBlock,
  streamed: Streamed,
) -> #(List(schema.Update), Streamed) {
  case block {
    message.AssistantText(text:, ..) -> {
      let #(unseen, rest) = reconcile(text, streamed.text)
      #(non_empty(unseen, schema.AgentText), Streamed(..streamed, text: rest))
    }

    // Redacted reasoning is opaque on purpose and is never forwarded.
    message.AssistantThinking(redacted: True, ..) -> #([], streamed)

    message.AssistantThinking(thinking:, redacted: False, ..) -> {
      let #(unseen, rest) = reconcile(thinking, streamed.thinking)
      #(
        non_empty(unseen, schema.AgentThought),
        Streamed(..streamed, thinking: rest),
      )
    }

    message.AssistantToolCall(call:) -> #(
      [schema.ToolStarted(tool_call(call, schema.Pending))],
      streamed,
    )
  }
}

/// Wraps text in an update, or nothing when it is only whitespace.
fn non_empty(
  text: String,
  make: fn(String) -> schema.Update,
) -> List(schema.Update) {
  case string.trim(text) {
    "" -> []
    _ -> [make(text)]
  }
}

/// Compares a durable block with the text already streamed for it.
///
/// Answers what the client has still to be shown and what streamed text is left
/// over for the next block. The three cases are the three ways the two can
/// relate: the stream was a prefix of the block (show the rest), the stream ran
/// on past the block into the next request (consume the block, keep the rest),
/// or they diverged, where the durable text is the authority and is shown whole.
fn reconcile(durable: String, streamed: String) -> #(String, String) {
  case
    string.starts_with(durable, streamed),
    string.starts_with(streamed, durable)
  {
    True, _ -> #(string.drop_start(durable, string.length(streamed)), "")
    False, True -> #("", string.drop_start(streamed, string.length(durable)))
    False, False -> #(durable, "")
  }
}

/// Records a live fragment and answers the update that shows it.
///
/// Kinds other than `text` and `thinking` (tool-argument streaming, for
/// instance) have no ACP counterpart and are ignored.
///
/// ## Examples
///
/// ```gleam
/// let #(update, streamed) =
///   translate.fragment("text", "Hel", translate.nothing_streamed)
/// assert update == Some(schema.AgentText("Hel"))
/// assert streamed.text == "Hel"
/// ```
pub fn fragment(
  kind: String,
  text: String,
  streamed: Streamed,
) -> #(Option(schema.Update), Streamed) {
  case kind {
    "text" -> #(
      Some(schema.AgentText(text)),
      Streamed(..streamed, text: keep(streamed.text <> text)),
    )
    "thinking" -> #(
      Some(schema.AgentThought(text)),
      Streamed(..streamed, thinking: keep(streamed.thinking <> text)),
    )
    _ -> #(None, streamed)
  }
}

/// Keeps the newest `max_streamed_chars` characters of accumulated stream text.
fn keep(text: String) -> String {
  // Dropping the bound's worth of characters leaves "" exactly when the text
  // is within the bound, which answers the question without measuring all of
  // a long string.
  case string.drop_start(text, max_streamed_chars) {
    "" -> text
    _beyond -> string.drop_start(text, string.length(text) - max_streamed_chars)
  }
}

/// A user block as replayed text; an image is named, not inlined.
fn user_block(block: message.UserBlock) -> Result(schema.Update, Nil) {
  case block {
    message.UserText(text:, ..) -> Ok(schema.UserText(text))
    message.UserImage(mime_type:, ..) ->
      Ok(schema.UserText("[image: " <> mime_type <> "]"))
  }
}

/// Describes a model's tool call as ACP's `ToolCall`.
///
/// ## Examples
///
/// ```gleam
/// let call = message.ToolCall("c1", "bash", args, None, None)
/// let described = translate.tool_call(call, schema.Pending)
/// assert described.kind == schema.Execute
/// ```
pub fn tool_call(
  call: message.ToolCall,
  status: schema.ToolStatus,
) -> schema.ToolCall {
  schema.ToolCall(
    id: call.id,
    title: title(call),
    kind: kind(call.name),
    status:,
    raw_input: call.arguments,
  )
}

/// The one-line title: the tool name and the most telling argument.
fn title(call: message.ToolCall) -> String {
  case hint(call.arguments) {
    Some(hint) -> call.name <> ": " <> hint
    None -> call.name
  }
}

/// The first of the usual argument names that holds text, cut to one short line.
fn hint(arguments: JsonValue) -> Option(String) {
  case arguments {
    json.Object(fields) ->
      ["command", "path", "file_path", "pattern", "query", "url", "name"]
      |> list.find_map(fn(key) {
        case list.key_find(fields, key) {
          Ok(json.String(value)) -> Ok(one_line(value, 100))
          _ -> Error(Nil)
        }
      })
      |> option.from_result
    _ -> None
  }
}

/// Collapses text to its first line and cuts it at `limit` characters.
fn one_line(text: String, limit: Int) -> String {
  let first = text |> string.split("\n") |> list.first |> result.unwrap("")

  // Anything left after dropping `limit` characters means the line is longer.
  case string.drop_start(first, limit) {
    "" -> first
    _beyond -> string.slice(first, 0, limit) <> "..."
  }
}

/// Which icon-bearing kind a tool belongs to, from Loom's tool names.
fn kind(name: String) -> schema.ToolKind {
  case name {
    "fs_read" | "blob" -> schema.Read
    "fs_write" | "fs_edit" -> schema.Edit
    "bash" | "code_mode" | "job" -> schema.Execute
    "grep" | "search" -> schema.Search
    "fetch" | "web_fetch" -> schema.Fetch
    _ -> schema.Other
  }
}

/// The update that finishes a tool call.
fn tool_result(
  call_id: String,
  content: List(message.ToolResultBlock),
  status: schema.ToolStatus,
) -> schema.Update {
  let text = result_text(content)
  let raw =
    json.Object([
      #("output", json.String(text)),
      #("is_error", json.Bool(status == schema.Failed)),
    ])
  schema.ToolProgress(call_id, status, Some(text), Some(raw))
}

/// A tool result's text, bounded, with images named.
fn result_text(content: List(message.ToolResultBlock)) -> String {
  content
  |> list.map(fn(block) {
    case block {
      message.ToolResultText(text:, ..) -> text
      message.ToolResultImage(mime_type:, ..) -> "[image: " <> mime_type <> "]"
    }
  })
  |> string.join("\n")
  |> bounded
}

/// Cuts text to `max_output_chars`, saying so when it did.
fn bounded(text: String) -> String {
  case string.drop_start(text, max_output_chars) {
    "" -> text
    _beyond -> string.slice(text, 0, max_output_chars) <> "\n[output truncated]"
  }
}

/// The running update a tool's streamed output tail becomes.
///
/// ## Examples
///
/// ```gleam
/// let update = translate.tool_tail("c1", "partial")
/// assert update
///   == schema.ToolProgress("c1", schema.InProgress, Some("partial"), None)
/// ```
pub fn tool_tail(call_id: String, text: String) -> schema.Update {
  schema.ToolProgress(call_id, schema.InProgress, Some(bounded(text)), None)
}

/// Projects a pending escalation into the permission request ACP asks the client.
///
/// The options are exactly what the daemon can honour for this record: a
/// one-time grant when the authority is exact, a session grant only when the
/// complete grant set is rememberable (the terminal's own rule), and a refusal
/// always. A record the daemon cannot encode an approval for offers refusal
/// alone, which is also what the terminal does.
///
/// ## Examples
///
/// ```gleam
/// // let #(call, options) = translate.permission(review)
/// ```
pub fn permission(
  review: approval.Review,
) -> #(schema.ToolCall, List(schema.PermissionOption)) {
  let call =
    schema.ToolCall(
      id: "escalation-" <> review.id,
      title: permission_title(review),
      kind: kind(review.tool),
      status: schema.Pending,
      raw_input: permission_input(review),
    )
  let refuse = schema.PermissionOption(reject_option, "Deny", schema.RejectOnce)

  // An approval is only offered when the record carries an exact grant.
  let grants = case review.permission {
    approval.Exact(..) -> [
      schema.PermissionOption(allow_option, "Allow once", schema.AllowOnce),
      ..session_option(review)
    ]
    approval.Unavailable(..) -> []
  }

  #(call, list.append(grants, [refuse]))
}

/// The remember-for-session choice, present only when the terminal would offer it.
fn session_option(review: approval.Review) -> List(schema.PermissionOption) {
  case approval.rememberable(review) {
    Ok(Nil) -> [
      schema.PermissionOption(
        allow_session_option,
        "Allow for this session",
        schema.AllowAlways,
      ),
    ]
    Error(_) -> []
  }
}

/// A short question title naming what the agent wants to do.
fn permission_title(review: approval.Review) -> String {
  let wants = "Allow the agent to " <> approval.wants(review.tool)

  // A preview, when the record captured one, says which action is asked about.
  case one_line(review.preview, 120) {
    "" -> wants
    preview -> wants <> ": " <> preview
  }
}

/// The structured detail a client may show beside the question.
fn permission_input(review: approval.Review) -> JsonValue {
  // The same presentation the terminal shows, or the reason there is none.
  let authority = case approval.presentation(review) {
    Ok(presented) -> [
      #("action", json.String(presented.action)),
      #("authority", json.Array(list.map(presented.authority, json.String))),
    ]
    Error(reason) -> [#("unavailable", json.String(reason))]
  }

  json.Object([
    #("tool", json.String(review.tool)),
    #("strand", json.String(option.unwrap(review.strand, "main"))),
    ..authority
  ])
}

/// What a client's answer to a permission request means.
///
/// The answer is read against the options *offered for that request*, not
/// against the vocabulary of every request: a session grant that was not
/// offered (because the grant set cannot be remembered) is a refusal if a
/// client sends it anyway. Anything else that is not an offered allow option
/// is a refusal too, including a dismissal and an id this server never
/// offered, because an unrecognised answer must never widen authority.
///
/// ## Examples
///
/// ```gleam
/// let offered = [schema.PermissionOption("allow", "Allow", schema.AllowOnce)]
/// assert translate.decision(schema.Selected("allow"), offered)
///   == translate.Approve
/// assert translate.decision(schema.Selected("allow_session"), offered)
///   == translate.Deny
/// assert translate.decision(schema.Dismissed, offered) == translate.Deny
/// ```
pub fn decision(
  choice: schema.PermissionChoice,
  offered: List(schema.PermissionOption),
) -> Decision {
  case choice {
    schema.Dismissed -> Deny
    schema.Selected(option_id:) ->
      case list.find(offered, fn(option) { option.id == option_id }) {
        Ok(schema.PermissionOption(kind: schema.AllowOnce, ..)) -> Approve
        Ok(schema.PermissionOption(kind: schema.AllowAlways, ..)) ->
          ApproveForSession
        Ok(schema.PermissionOption(kind: schema.RejectOnce, ..)) | Error(Nil) ->
          Deny
      }
  }
}

/// The wire frame that carries a decision, falling back to a refusal.
///
/// A grant the record cannot encode (an approval whose exact authority is
/// unavailable, or a session grant that is not rememberable) must not leave
/// the escalation pending: the run is parked on it, and the prompt would hang.
/// The frame is therefore a denial whenever the approval cannot be encoded.
/// `Error` means even a denial is impossible, which only a record that is no
/// longer pending can say.
///
/// ## Examples
///
/// ```gleam
/// // translate.decision_frame(review, translate.Approve) -> Ok(frame)
/// ```
pub fn decision_frame(
  review: approval.Review,
  decision: Decision,
) -> Result(String, Nil) {
  // Each decision has its own encoding; only the refusal always exists.
  let encoded = case decision {
    Approve -> approval.approve(0, review)
    ApproveForSession -> approval.approve_for_session(0, review)
    Deny -> approval.deny(0, review)
  }

  result.lazy_or(encoded, fn() { approval.deny(0, review) })
  |> result.replace_error(Nil)
}

/// The outcome to report, given whether the client asked to stop.
///
/// A client that asked to stop is told the turn was cancelled however the run
/// ended (finished, failed, or aborted): ACP requires the prompt response to
/// be `cancelled`, and defines no race between the two.
///
/// ## Examples
///
/// ```gleam
/// let failed = translate.Errored("x")
/// assert translate.after_cancel(failed, translate.Asked)
///   == translate.Stopped(schema.Cancelled)
/// assert translate.after_cancel(failed, translate.NotAsked) == failed
/// ```
pub fn after_cancel(outcome: Outcome, cancellation: Cancellation) -> Outcome {
  case cancellation {
    Asked -> Stopped(schema.Cancelled)
    NotAsked -> outcome
  }
}

/// How a terminal run result ends the prompt that started it.
///
/// ## Examples
///
/// ```gleam
/// // translate.outcome(result, Normal) == translate.Stopped(schema.EndTurn)
/// ```
pub fn outcome(result: operation.LastResult) -> Option(Outcome) {
  case result {
    operation.RunLastResult(outcome: operation.RunCompleted(..), ..) ->
      Some(Stopped(schema.EndTurn))
    operation.RunLastResult(outcome: operation.RunAborted, ..) ->
      Some(Stopped(schema.Cancelled))
    operation.RunLastResult(outcome: operation.RunFailed(error:), ..) ->
      Some(Errored("the run failed: " <> error.code))

    // Compaction and navigation end no prompt turn.
    operation.CompactionLastResult(..) | operation.NavigationLastResult(..) ->
      None
  }
}

/// The tokens one turn spent, from the session's cumulative usage before and after.
///
/// ## Examples
///
/// ```gleam
/// // translate.turn_usage(before, after).total == after.total_tokens - before.total_tokens
/// ```
pub fn turn_usage(
  before: message.Usage,
  after: message.Usage,
) -> schema.TurnUsage {
  // Reasoning is reported only by providers that separate it, so a missing
  // earlier figure is zero and a missing later one stays unreported.
  let reasoning = case after.reasoning, before.reasoning {
    Some(now), Some(then) -> Some(int.max(0, now - then))
    Some(now), None -> Some(now)
    None, _ -> None
  }

  schema.TurnUsage(
    input: int.max(0, after.input - before.input),
    output: int.max(0, after.output - before.output),
    total: int.max(0, after.total_tokens - before.total_tokens),
    thought: reasoning,
    cached_read: int.max(0, after.cache_read - before.cache_read),
    cached_write: int.max(0, after.cache_write - before.cache_write),
  )
}
