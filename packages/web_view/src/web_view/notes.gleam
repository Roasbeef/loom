//// A strand's bounded notes index and its single-note reader. The board is
//// evidence from one read, never a promise that omitted cells were searched.
//// Selection is a durable cell key; numeric positions belong only to DOM paths.

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import session_view/markdown
import session_view/notes_view

/// The progress of the explicit read.
pub type Read {
  /// No read has been requested in this scope.
  Unread

  /// The shared lane has not yet sent the requested read.
  Queued

  /// The lane sent the read and owes an answer.
  Waiting

  /// A board answered the read.
  Ready

  /// The lane ended the read without a board.
  Unavailable
}

/// Which representation the reader chose.
pub type Mode {
  /// Existing structured projection, when the value supports it.
  Readable

  /// Exactly the supplied text, with no reconstruction or projection.
  Raw
}

/// State belonging only to the strand currently on screen.
pub type State {
  State(
    /// The bounded snapshot, retained while a refresh is outstanding.
    board: Option(notes_view.Board),
    /// Search over the supplied keys and original text only.
    query: String,
    /// A key from the current board, never a browser-supplied identifier.
    selected: Option(String),
    /// The selected note's presentation.
    mode: Mode,
    /// The explicit read's progress.
    read: Read,
    /// Page-assigned numeric identities remain stable across refreshes.
    keys: Dict(String, Int),
    /// The next identity is never reused by this page, even after focus changes.
    next_key: Int,
    /// Presentation is projected once per snapshot, away from the render loop.
    presentations: Dict(String, Presentation),
  )
}

/// The bounded preview and existing readable projection of a complete value.
pub type Presentation {
  Presentation(
    /// The key-first row's bounded preview.
    preview: String,
    /// The already parsed safe Markdown tree.
    readable: List(markdown.Block),
    /// Whether readable mode adds a representation distinct from raw text.
    representation: Representation,
  )
}

/// Whether the supplied value may enter the existing readable renderer.
pub type Representation {
  /// The original text is the only representation.
  Literal

  /// A complete value may render its readable text as safe Markdown.
  Structured
}

/// The browser's local read-only intents.
pub type Press {
  /// Request this strand's board.
  Refresh

  /// Open the cell named by the server's handler.
  Open(key: String)

  /// Return to the index, retaining its query.
  Back

  /// Show the existing readable projection.
  ShowReadable

  /// Show the exact supplied text.
  ShowRaw
}

/// Starts a new scope without retaining another strand's text.
///
/// ## Examples
///
/// ```gleam
/// assert notes.new().selected == None
/// ```
pub fn new() -> State {
  State(None, "", None, Readable, Unread, dict.new(), 0, dict.new())
}

/// Clears the departing scope without reusing its browser event identities.
///
/// ## Examples
///
/// ```gleam
/// assert notes.clear(notes.new()) == notes.new()
/// ```
pub fn clear(state: State) -> State {
  State(..new(), next_key: state.next_key)
}

/// Adopts only a matching, non-regressing snapshot, resolving the selected key
/// against the replacement so removed cells cannot remain on screen.
///
/// ## Examples
///
/// ```gleam
/// assert notes.receive(notes.new(), "main", notes_view.Board("other", 1, 0, [])) == notes.new()
/// ```
pub fn receive(state: State, strand: String, board: notes_view.Board) -> State {
  let previous = option_revision(state.board)
  case board.strand == strand && board.as_of >= previous {
    False -> state
    True -> {
      let selected = case state.selected {
        Some(key) ->
          case list.any(board.notes, fn(note) { note.key == key }) {
            True -> Some(key)
            False -> None
          }
        None -> None
      }
      let #(keys, next_key) =
        list.fold(board.notes, #(dict.new(), state.next_key), fn(done, note) {
          let #(keys, next_key) = done
          case dict.get(state.keys, note.key) {
            Ok(number) -> #(dict.insert(keys, note.key, number), next_key)
            Error(Nil) -> #(dict.insert(keys, note.key, next_key), next_key + 1)
          }
        })
      let presentations =
        board.notes
        |> list.map(fn(note) {
          let readable = case note.extent {
            notes_view.Complete -> notes_view.readable_note(note)
            notes_view.Excerpt -> note.text
          }
          let representation = case note.extent == notes_view.Complete {
            True -> Structured
            False -> Literal
          }
          #(
            note.key,
            Presentation(
              string.slice(notes_view.summary(note), 0, 220),
              case representation {
                Structured -> markdown.parse(readable)
                Literal -> []
              },
              representation,
            ),
          )
        })
        |> dict.from_list
      State(
        ..state,
        board: Some(board),
        selected:,
        read: Ready,
        keys:,
        next_key:,
        presentations:,
      )
    }
  }
}

fn option_revision(board: Option(notes_view.Board)) -> Int {
  case board {
    Some(board) -> board.as_of
    None -> -1
  }
}

/// Applies a local intent, validating a selected key against this board.
///
/// ## Examples
///
/// ```gleam
/// assert notes.press(notes.new(), notes.Back) == notes.new()
/// ```
pub fn press(state: State, press: Press) -> State {
  case press {
    Refresh ->
      case state.read {
        Queued | Waiting -> state
        Unread | Ready | Unavailable -> State(..state, read: Queued)
      }
    Open(key) ->
      case state.board {
        Some(board) ->
          case list.any(board.notes, fn(note) { note.key == key }) {
            True -> State(..state, selected: Some(key), mode: Readable)
            False -> state
          }
        None -> state
      }
    Back -> State(..state, selected: None, mode: Readable)
    ShowReadable -> State(..state, mode: Readable)
    ShowRaw -> State(..state, mode: Raw)
  }
}

/// Searches only the supplied board, retaining its server order.
///
/// ## Examples
///
/// ```gleam
/// assert notes.rows(notes.new()) == []
/// ```
pub fn rows(state: State) -> List(notes_view.Note) {
  case state.board {
    None -> []
    Some(board) -> {
      let query = string.lowercase(state.query)
      list.filter(board.notes, fn(note) {
        string.contains(string.lowercase(note.key), query)
        || string.contains(string.lowercase(note.text), query)
      })
    }
  }
}

/// Resolves detail afresh from the current board.
///
/// ## Examples
///
/// ```gleam
/// assert notes.selected(notes.new()) == Error(Nil)
/// ```
pub fn selected(state: State) -> Result(notes_view.Note, Nil) {
  use board <- result.try(case state.board {
    Some(board) -> Ok(board)
    None -> Error(Nil)
  })
  use key <- result.try(case state.selected {
    Some(key) -> Ok(key)
    None -> Error(Nil)
  })
  list.find(board.notes, fn(note) { note.key == key })
}
