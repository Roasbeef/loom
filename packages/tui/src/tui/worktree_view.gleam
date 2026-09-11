//// Worktree observations have a server request identity and an observation
//// time. The terminal keeps raw file identities separate from safe labels,
//// and never presents captured tool edits as a current Git observation.

import core/json
import gleam/bool
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import tui/text_hygiene

/// One bounded file observation; path remains an opaque unsanitized identity.
pub type File {
  File(
    /// Raw Git path used for selection identity.
    path: String,
    /// Index status from the porcelain observation.
    index_status: String,
    /// Working-directory status from the same observation.
    worktree_status: String,
    /// Bounded complete or explicitly limited patch.
    patch: String,
    /// Text, binary, metadata-only, or no net change.
    kind: String,
    /// Complete or limited, independently of the whole observation.
    extent: String,
  )
}

/// A completed Git observation, separate from conversation history.
pub type Board {
  Board(
    /// Actual wire request allocated by the session channel.
    request_id: Int,
    /// Server observation time; this is never a completion timestamp.
    observed_at_ms: Int,
    /// Existing HEAD, unborn repository, or no repository.
    repository: String,
    /// At most twenty-four distinct paths.
    files: List(File),
    /// Total files before bounded omission.
    total: Int,
    /// Files omitted by the observation budget.
    omitted: Int,
    /// Whether the observation exhausted a bound.
    extent: String,
  )
}

/// The pending acknowledgement and eventual push share the same request ID.
pub type Event {
  /// The observation has been admitted and will finish asynchronously.
  Pending(request_id: Int)

  /// A completed observation can replace only its matching request.
  Ready(board: Board)

  /// A failed observation is distinct from an empty worktree.
  Failed(request_id: Int, message: String)
}

/// The composer keeps its ordinary typing semantics until navigation has focus.
pub type Focus {
  /// Characters and history belong to the ordinary composer.
  Composer

  /// Up/down choose files; r refreshes this observation.
  Navigator
}

/// An explicit read waits behind already admitted channel work.
pub type Refresh {
  /// No observation request is waiting to be sent.
  Settled

  /// Send once when the channel becomes idle.
  Requested
}

/// One attachment's latest observation and its independent file selection.
pub type State {
  State(
    /// Attachment whose requests may update this view.
    owner: String,
    /// Actual allocated request ID, including after the pending reply.
    awaiting: Option(Int),
    /// Last completed observation remains visible while refresh runs.
    board: Option(Board),
    /// Zero means all files; positive values select a raw path by index.
    selected: Int,
    /// File navigation never takes characters from the composer implicitly.
    focus: Focus,
    /// Explicit refresh scheduling state.
    refresh: Refresh,
    /// Observation progress, failure, or captured fallback explanation.
    message: String,
  )
}

/// Starts with an explicitly labelled captured-edit fallback.
///
/// ## Examples
///
/// ```gleam
/// worktree_view.new()
/// ```
pub fn new() -> State {
  State(
    "",
    None,
    None,
    0,
    Composer,
    Settled,
    "Captured edits · current worktree observation unavailable",
  )
}

/// Requests one observation while retaining a previous result as stale.
///
/// ## Examples
///
/// ```gleam
/// worktree_view.request(worktree_view.new(), "attachment")
/// ```
pub fn request(state: State, owner: String) -> State {
  let retained = case state.owner == owner {
    True -> state
    False -> new()
  }

  // A file can change while an observation is in flight. Keep one dirty bit
  // behind it, so the completed older observation cannot lose that refresh.
  State(
    ..retained,
    owner:,
    refresh: Requested,
    message: "Refreshing worktree; previous observation may be stale",
  )
}

/// Correlates against the ID actually assigned on the command lane.
///
/// ## Examples
///
/// ```gleam
/// worktree_view.sent(worktree_view.new(), 3)
/// ```
pub fn sent(state: State, request_id: Int) -> State {
  State(..state, awaiting: Some(request_id), refresh: Settled)
}

/// Ignores late results from a superseded request or attachment.
///
/// ## Examples
///
/// ```gleam
/// // worktree_view.receive(state, owner, event)
/// ```
pub fn receive(state: State, owner: String, event: Event) -> State {
  let id = case event {
    Pending(id) | Failed(id, _) -> id
    Ready(board) -> board.request_id
  }
  use <- bool.guard(state.owner != owner || state.awaiting != Some(id), state)
  case event {
    Pending(_) ->
      State(
        ..state,
        message: "Observing worktree… previous observation may be stale",
      )
    Failed(_, reason) ->
      State(
        ..state,
        awaiting: None,
        message: "Worktree observation failed: "
          <> text_hygiene.single_line(reason),
      )
    Ready(board) ->
      State(
        ..state,
        board: Some(board),
        awaiting: None,
        selected: retained_selection(state, board),
        message: "Last workspace observation · r refreshes in file navigation",
      )
  }
}

/// Validates the complete bounded observation before displaying any file.
///
/// ## Examples
///
/// ```gleam
/// // worktree_view.decode(board)
/// ```
pub fn decode(value: json.JsonValue) -> Result(Event, String) {
  use <- bool.guard(
    string.byte_size(json.to_string(value)) > 48_000,
    Error("oversized worktree observation"),
  )
  use fields <- result.try(object(value))
  use id <- result.try(number(fields, "request_id"))
  use status <- result.try(text(fields, "status"))
  case status {
    "pending" -> Ok(Pending(id))
    "failed" -> {
      use code <- result.try(text(fields, "code"))
      use message <- result.try(text(fields, "message"))
      Ok(Failed(id, code <> ": " <> message))
    }
    "ready" -> decode_board(fields, id) |> result.map(Ready)
    _ -> Error("unknown worktree observation status")
  }
}

fn decode_board(fields, id) {
  use observed <- result.try(number(fields, "observed_at_ms"))
  use source <- result.try(text(fields, "source"))
  use repository <- result.try(text(fields, "repository"))
  use total <- result.try(number(fields, "total"))
  use omitted <- result.try(number(fields, "omitted"))
  use extent <- result.try(text(fields, "extent"))
  use raw <- result.try(case list.key_find(fields, "entries") {
    Ok(json.Array(rows)) -> Ok(rows)
    _ -> Error("missing worktree files")
  })
  use <- bool.guard(list.drop(raw, 24) != [], Error("too many worktree files"))
  use files <- result.try(list.try_map(raw, decode_file))
  let distinct = dict.from_list(list.map(files, fn(file) { #(file.path, Nil) }))
  use <- bool.guard(
    source != "git"
      || !list.contains(["head", "unborn", "not_repository"], repository)
      || !list.contains(["complete", "limited"], extent)
      || total != list.length(files) + omitted
      || dict.size(distinct) != list.length(files),
    Error("inconsistent worktree observation"),
  )
  Ok(Board(id, observed, repository, files, total, omitted, extent))
}

fn decode_file(value) {
  use fields <- result.try(object(value))
  use path <- result.try(text(fields, "path"))
  use index <- result.try(text(fields, "index_status"))
  use worktree <- result.try(text(fields, "worktree_status"))
  use patch <- result.try(text(fields, "patch"))
  use kind <- result.try(text(fields, "kind"))
  use extent <- result.try(text(fields, "extent"))
  use <- bool.guard(
    path == ""
      || string.byte_size(path) > 4096
      || string.byte_size(patch) > 16_384
      || !list.contains(
      ["text", "binary", "no_net_change", "metadata_only"],
      kind,
    )
      || !list.contains(["complete", "limited"], extent),
    Error("invalid worktree file"),
  )
  Ok(File(path, index, worktree, patch, kind, extent))
}

/// Returns safe navigation labels without changing any stored file identity.
///
/// ## Examples
///
/// ```gleam
/// worktree_view.labels(worktree_view.new())
/// ```
pub fn labels(state: State) -> List(String) {
  case state.board {
    None -> ["All captured edits"]
    Some(board) -> [
      "All files (" <> int.to_string(board.total) <> ")",
      ..list.map(board.files, fn(file) {
        text_hygiene.single_line(
          file.index_status <> file.worktree_status <> " " <> file.path,
        )
      })
    ]
  }
}

/// Projects only the selected patch, with per-file and whole-view limitations.
///
/// ## Examples
///
/// ```gleam
/// worktree_view.patches(worktree_view.new())
/// ```
pub fn patches(state: State) -> List(String) {
  case state.board {
    None -> []
    Some(board) -> {
      let files = case state.selected {
        0 -> board.files
        n -> list.drop(board.files, n - 1) |> list.take(1)
      }
      let header = case board.repository {
        "not_repository" -> ["Workspace is not a Git repository"]
        _ -> []
      }
      let details =
        list.flat_map(files, fn(file) {
          [
            text_hygiene.single_line(file.path)
              <> " · "
              <> file.kind
              <> " · "
              <> file.extent,
            text_hygiene.multiline(file.patch),
          ]
        })
      list.append(
        header,
        list.append(details, [
          "Observation "
          <> board.extent
          <> " · "
          <> int.to_string(board.omitted)
          <> " files omitted",
        ]),
      )
    }
  }
}

fn object(value) {
  case value {
    json.Object(fields) -> Ok(fields)
    _ -> Error("expected worktree object")
  }
}

fn text(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.String(value)) -> Ok(value)
    _ -> Error("missing worktree text: " <> name)
  }
}

fn number(fields, name) {
  case list.key_find(fields, name) {
    Ok(json.Int(value)) if value >= 0 -> Ok(value)
    _ -> Error("invalid worktree number: " <> name)
  }
}

fn retained_selection(state: State, board: Board) -> Int {
  case state.board, state.selected {
    Some(previous), index if index > 0 -> {
      let selected = previous.files |> list.drop(index - 1) |> list.first
      case selected {
        Ok(file) ->
          board.files
          |> list.index_map(fn(row, index) { #(row.path, index + 1) })
          |> list.key_find(file.path)
          |> result.unwrap(0)
        Error(Nil) -> 0
      }
    }
    _, _ -> 0
  }
}
