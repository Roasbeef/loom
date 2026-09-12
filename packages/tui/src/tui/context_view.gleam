//// A bounded, attachment-scoped context observation and independent inspector.
//// The server prices the complete projection; the terminal never substitutes
//// its retained scrollback or cumulative billing counters. Pending reads keep
//// their original identity while newer changes coalesce into one refresh.

import core/json
import gleam/bool
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/text_hygiene

/// Inspector visibility and detail are one choice.
pub type Surface {
  /// Ordinary conversation remains visible.
  Hidden

  /// Show totals and component estimates.
  Overview

  /// Also show the bounded per-item inventory.
  All
}

/// The read lifecycle retains its identity until terminal delivery.
pub type Request {
  /// No read is needed.
  Idle

  /// Send when the conversation lane is available.
  Requested

  /// Await the asynchronous result for this exact request.
  Awaiting(id: Int)

  /// A later context change requires one more read after this result.
  RefreshAfter(id: Int)

  /// An older server refused this optional command.
  Unavailable
}

/// One estimated inventory row, containing labels rather than prompt text.
pub type Item {
  Item(
    /// Request component which owns these tokens.
    category: String,
    /// The bounded display label.
    name: String,
    /// Independent token estimate.
    tokens: Int,
  )
}

/// The complete validated summary and bounded detail list.
pub type Board {
  Board(
    /// Originating read identity, also carried by the pending acknowledgement.
    request_id: Int,
    /// Strand observed by the server.
    strand: String,
    /// Durable high-water at metadata capture.
    as_of: Int,
    /// Server-resolved model identity.
    model: String,
    /// Positive configured token window.
    window: Int,
    /// Estimated current context use, never cumulative session billing.
    used: Int,
    /// Whether provider usage anchors the estimate.
    basis: String,
    /// Existing compaction accounting, which omits static fallback components.
    compaction_used: Int,
    /// Compaction threshold, absent when disabled.
    checkpoint_at: Option(Int),
    /// Reserved space before the model window ends.
    reserve: Int,
    /// Complete independently estimated component totals.
    categories: List(Item),
    /// A bounded item prefix; totals cover every omitted item too.
    items: List(Item),
    /// Number of detail items omitted by the byte limit.
    omitted: Int,
  )
}

/// Both acknowledgement and completion retain the originating request.
pub type Event {
  /// The server admitted a read outside its command handler.
  Pending(id: Int)

  /// A complete observation can replace its own pending read only.
  Ready(board: Board)

  /// Missing data never becomes an empty-context assertion.
  Failed(id: Int, reason: String)
}

/// One attachment and strand's observation, independent of the composer.
pub type State {
  State(
    /// Attachment identity, including its incarnation.
    owner: String,
    /// Strand selected when the read was issued.
    strand: String,
    /// Independent inspector visibility.
    surface: Surface,
    /// Last completed observation for this selection.
    board: Option(Board),
    /// Coalesced read lifecycle.
    request: Request,
    /// Diagnostic shown when no fresh observation is available.
    notice: String,
    /// Inspector scroll offset.
    scroll: Int,
  )
}

/// Starts with unavailable numbers until the server supplies an observation.
///
/// ## Examples
///
/// ```gleam
/// assert context_view.new().board == None
/// ```
pub fn new() -> State {
  State("", "", Hidden, None, Requested, "Context has not been observed", 0)
}

/// Selects a context without retaining another attachment's measurements.
///
/// ## Examples
///
/// ```gleam
/// // context_view.select(state, owner, "main")
/// ```
pub fn select(state: State, owner: String, strand: String) -> State {
  case state.owner == owner && state.strand == strand {
    True -> state
    False -> {
      // The connection retains its observation slot until the old read ends.
      // A strand change waits for that identity before requesting another one.
      let request = case state.owner == owner {
        True -> invalidate(state).request
        False -> Requested
      }
      State(..new(), owner:, strand:, surface: state.surface, request:)
    }
  }
}

/// Coalesces a newer durable context behind the read already in flight.
///
/// ## Examples
///
/// ```gleam
/// // context_view.invalidate(state)
/// ```
pub fn invalidate(state: State) -> State {
  State(..state, request: case state.request {
    Awaiting(id) | RefreshAfter(id) -> RefreshAfter(id)
    Idle | Requested -> Requested
    Unavailable -> Unavailable
  })
}

/// Records the lane's actual allocated request identifier.
///
/// ## Examples
///
/// ```gleam
/// // context_view.sent(state, 4)
/// ```
pub fn sent(state: State, id: Int) -> State {
  State(..state, request: Awaiting(id), notice: "Refreshing context…")
}

/// Applies only results belonging to this attachment and pending request.
///
/// ## Examples
///
/// ```gleam
/// // context_view.receive(state, owner, event)
/// ```
pub fn receive(state: State, owner: String, event: Event) -> State {
  let expected = case state.request {
    Awaiting(id) | RefreshAfter(id) -> Some(id)
    Idle | Requested | Unavailable -> None
  }
  let actual = case event {
    Pending(id) | Failed(id, _) -> id
    Ready(board) -> board.request_id
  }
  use <- bool.guard(state.owner != owner || expected != Some(actual), state)
  let next = case state.request {
    RefreshAfter(_) -> Requested
    Awaiting(_) | Idle | Requested | Unavailable -> Idle
  }
  case event {
    Pending(_) -> state
    Failed(_, reason) ->
      State(
        ..state,
        board: None,
        request: next,
        notice: "Context unavailable: " <> text_hygiene.single_line(reason),
      )
    Ready(board) if board.strand == state.strand ->
      State(..state, board: Some(board), request: next, notice: "")
    Ready(_) ->
      State(
        ..state,
        board: None,
        request: next,
        notice: "Context response belongs to another strand",
      )
  }
}

/// Refusals of an optional command remain local to the context inspector.
///
/// ## Examples
///
/// ```gleam
/// // context_view.refused(state, id, "unsupported", reason)
/// ```
pub fn refused(state: State, id: Int, code: String, reason: String) -> State {
  use <- bool.guard(
    state.request != Awaiting(id) && state.request != RefreshAfter(id),
    state,
  )
  let changed = receive(state, state.owner, Failed(id, reason))
  case code {
    "unsupported" | "unknown_command" -> State(..changed, request: Unavailable)
    _ -> changed
  }
}

/// Validates the byte budget, counts, and positive denominator before display.
///
/// ## Examples
///
/// ```gleam
/// // context_view.decode(board_json)
/// ```
pub fn decode(value: json.JsonValue) -> Result(Event, String) {
  use <- bool.guard(
    string.byte_size(json.to_string(value)) > 48_000,
    Error("oversized context observation"),
  )
  use fields <- result.try(object(value))
  use id <- result.try(number(fields, "request_id"))
  use status <- result.try(text(fields, "status"))
  case status {
    "pending" -> Ok(Pending(id))
    "failed" -> result.map(text(fields, "message"), Failed(id, _))
    "ready" -> result.map(decode_ready(fields, id), Ready)
    _ -> Error("unknown context observation status")
  }
}

fn decode_ready(fields, id) {
  use strand <- result.try(text(fields, "strand"))
  use as_of <- result.try(number(fields, "as_of"))
  use model <- result.try(text(fields, "model"))
  use window <- result.try(number(fields, "context_window"))
  use used <- result.try(number(fields, "used_tokens"))
  use basis <- result.try(text(fields, "basis"))
  use compaction_used <- result.try(number(fields, "compaction_used_tokens"))
  use reserve <- result.try(number(fields, "reserve_tokens"))
  use omitted <- result.try(number(fields, "items_omitted"))
  use total <- result.try(number(fields, "items_total"))
  use checkpoint <- result.try(case list.key_find(fields, "checkpoint_at") {
    Ok(json.Null) -> Ok(None)
    Ok(json.Int(value)) if value >= 0 -> Ok(Some(value))
    _ -> Error("invalid checkpoint threshold")
  })
  use categories <- result.try(
    rows(fields, "categories", fn(value) {
      use fields <- result.try(object(value))
      use name <- result.try(text(fields, "name"))
      use tokens <- result.try(number(fields, "tokens"))
      Ok(Item(name, name, tokens))
    }),
  )
  use items <- result.try(
    rows(fields, "items", fn(value) {
      use fields <- result.try(object(value))
      use category <- result.try(text(fields, "category"))
      use name <- result.try(text(fields, "name"))
      use tokens <- result.try(number(fields, "tokens"))
      Ok(Item(category, name, tokens))
    }),
  )
  use <- bool.guard(
    window == 0
      || strand == ""
      || model == ""
      || !list.contains(["estimated", "reported_plus_estimate"], basis)
      || total != list.length(items) + omitted
      || list.drop(categories, 16) != [],
    Error("inconsistent context observation"),
  )
  Ok(Board(
    id,
    strand,
    as_of,
    model,
    window,
    used,
    basis,
    compaction_used,
    checkpoint,
    reserve,
    categories,
    items,
    omitted,
  ))
}

fn object(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected context object")
  }
}

fn text(fields, key) {
  case list.key_find(fields, key) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("missing context field " <> key)
  }
}

fn number(fields, key) {
  case list.key_find(fields, key) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    _ -> Error("invalid context count " <> key)
  }
}

fn rows(fields, key, decode) {
  case list.key_find(fields, key) {
    Ok(json.Array(values)) -> list.try_map(values, decode)
    _ -> Error("missing context rows " <> key)
  }
}

/// Keeps context visible before cumulative billing, including on narrow screens.
///
/// ## Examples
///
/// ```gleam
/// assert context_view.footer(context_view.new()) == "ctx —"
/// ```
pub fn footer(state: State) -> String {
  case state.board {
    Some(board) ->
      "ctx ~" <> int.to_string(board.used * 100 / board.window) <> "%"
    None -> "ctx —"
  }
}

/// Renders honest aggregate estimates and optional source-item detail.
///
/// ## Examples
///
/// ```gleam
/// // context_view.lines(state)
/// ```
pub fn lines(state: State) -> List(String) {
  case state.board {
    None -> [state.notice]
    Some(board) -> {
      let filled = int.min(30, board.used * 30 / board.window)
      let common = [
        "CONTEXT USAGE · " <> text_hygiene.single_line(board.model),
        "["
          <> string.repeat("█", filled)
          <> string.repeat("░", 30 - filled)
          <> "] "
          <> footer(state),
        "~"
          <> count(board.used)
          <> " / "
          <> count(board.window)
          <> " tokens · strand "
          <> text_hygiene.single_line(board.strand),
        case board.basis {
          "reported_plus_estimate" ->
            "Provider usage + estimated newer messages (includes output)."
          _ -> "Estimated from the pinned prompt, active tools, and messages."
        },
        "Observed at durable sequence "
          <> int.to_string(board.as_of)
          <> "; r refreshes.",
        state.notice,
        "COMPONENT ESTIMATES · counted independently of the headline",
        ..list.map(board.categories, fn(item) {
          item.name <> ": ~" <> count(item.tokens) <> " tokens"
        })
      ]
      let boundary = case board.checkpoint_at {
        Some(at) ->
          "Auto-compaction at "
          <> count(at)
          <> " tokens · reserve "
          <> count(board.reserve)
          <> " · ~"
          <> count(int.max(0, at - board.compaction_used))
          <> " remaining"
        None -> "Auto-compaction is off."
      }
      let details = case state.surface {
        All -> [
          "",
          "ITEM ESTIMATES",
          ..list.map(board.items, fn(item) {
            text_hygiene.single_line(item.category <> " · " <> item.name)
            <> ": ~"
            <> count(item.tokens)
          })
        ]
        Overview | Hidden -> ["", "/context all or a expands item estimates."]
      }
      list.flatten([
        common,
        [
          "",
          boundary,
          "Free window space: ~"
            <> count(int.max(0, board.window - board.used))
            <> " tokens",
          "Compaction estimate: ~" <> count(board.compaction_used) <> " tokens",
          "",
          "Pinned instructions are included in System prompt; loaded skills, memory, and tool results are included in Messages.",
          "Transient hook transformations and unsent input are not reconstructed. Component estimates need not sum to provider usage.",
        ],
        details,
        case board.omitted {
          0 -> []
          omitted -> [
            int.to_string(omitted)
            <> " detail items omitted; totals include them.",
          ]
        },
      ])
    }
  }
}

fn count(value: Int) -> String {
  case value >= 1000 {
    True ->
      int.to_string(value / 1000)
      <> "."
      <> int.to_string(value % 1000 / 100)
      <> "k"
    False -> int.to_string(value)
  }
}
