//// What a review stages before Send: a verdict, a comment for each file, and
//// an action on each find the owner chose to close (the attention inbox's
//// review pane, `docs/design-notes/attention-inbox/README.md` section 2.1).
////
//// Nothing here reaches the agent. A staged item is a value in the page's
//// model, replaced by staging it again and taken back by clearing, and
//// `web_view/review_outbox_rule` words all of it as one prompt that Send
//// delivers. The rule decides what may be staged, so a form that could not
//// have been drawn, such as a comment on a file the review does not hold, is
//// refused here and never kept.
////
//// A find action is staged against the revision the page read the find at.
//// When Send applies it, the daemon refuses it if the find moved since
//// (`attention_door.close_find`), so an owner never closes a record they did
//// not read. An action the daemon has applied is kept, marked `Applied`, and
//// not applied twice: a later Send after a refused prompt skips it and the
//// prompt still says it was closed.
////
//// The module is pure and holds no Lustre. A comment's text is the owner's own
//// words and a path is the repository's; the rule bounds the first and
//// compares the second, and the view draws both as text nodes.
////
//// ## Flow
////
//// `empty` → `verdict` / `comment` / `find_action` → `pending_close` →
//// `applied` / `dropped`
////
//// 1. `verdict`, `comment` and `find_action` each stage one item, replacing
////    what was staged for the same thing.
//// 2. `pending_close` is the first find action Send has yet to apply.
//// 3. `applied` marks one applied, and `dropped` takes back one the daemon
////    refused.

import core/attention.{type Closure}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// The most bytes one comment or find note may hold. It is far under the
/// composer's 16,384-byte bound for the whole prompt, so a single note cannot
/// take the whole of it, and the outbox rule still checks the total.
pub const note_limit = 4096

/// The owner's judgement of the work as a whole.
pub type Verdict {
  /// The work is accepted.
  Approve

  /// The work needs changes before it is accepted.
  RequestChanges

  /// Comments, and no decision.
  Comment
}

/// One file's comment.
pub type FileComment {
  FileComment(
    /// The file's path, as the review holds it.
    path: String,
    /// What the owner wrote, trimmed and never empty.
    text: String,
  )
}

/// Whether the daemon has applied a find action.
pub type Standing {
  /// Staged, and not yet applied: Send applies it first.
  Pending

  /// The daemon applied it. It stays, so the prompt still says it was closed.
  Applied
}

/// One find the owner chose to close, and how.
pub type FindAction {
  FindAction(
    /// The find's identifier.
    id: String,
    /// The revision the page read the find at, which the daemon checks.
    revision: Int,
    /// How the find is to be closed.
    closure: Closure,
    /// What the owner wrote about it, trimmed, when they wrote anything.
    note: Option(String),
    /// Whether the daemon has applied it.
    standing: Standing,
  )
}

/// Everything staged.
pub type Staging {
  Staging(
    /// The verdict, when the owner chose one.
    verdict: Option(Verdict),
    /// The file comments, in the order they were first staged.
    comments: List(FileComment),
    /// The find actions, in the order they were first staged.
    finds: List(FindAction),
  )
}

/// Why a stage was refused, in the page's own fixed words.
pub type Problem {
  /// The comment names a file the review does not hold.
  UnknownFile

  /// The text is past `note_limit` bytes.
  TooLong
}

/// Nothing staged.
///
/// ## Examples
///
/// ```gleam
/// assert review_stage_rule.is_empty(review_stage_rule.empty())
/// ```
pub fn empty() -> Staging {
  Staging(verdict: None, comments: [], finds: [])
}

/// Whether nothing is staged.
///
/// ## Examples
///
/// ```gleam
/// assert review_stage_rule.is_empty(review_stage_rule.empty())
/// ```
pub fn is_empty(staging: Staging) -> Bool {
  staging.verdict == None && staging.comments == [] && staging.finds == []
}

/// Stages a verdict. Choosing the verdict that is already staged takes it back,
/// so a verdict pressed by mistake is one press from gone.
///
/// ## Examples
///
/// ```gleam
/// let staged = review_stage_rule.verdict(review_stage_rule.empty(), review_stage_rule.Approve)
/// assert staged.verdict == Some(review_stage_rule.Approve)
/// assert review_stage_rule.verdict(staged, review_stage_rule.Approve).verdict == None
/// ```
pub fn verdict(staging: Staging, chosen: Verdict) -> Staging {
  case staging.verdict == Some(chosen) {
    True -> Staging(..staging, verdict: None)
    False -> Staging(..staging, verdict: Some(chosen))
  }
}

/// Stages a file's comment, replacing the one before it. Text with nothing in
/// it takes the file's comment back. A path the review does not hold, and a
/// text past `note_limit` bytes, are refused and change nothing.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(staged) = review_stage_rule.comment(review_stage_rule.empty(), ["a.gleam"], "a.gleam", " wait ")
/// assert staged.comments == [review_stage_rule.FileComment("a.gleam", "wait")]
/// ```
pub fn comment(
  staging: Staging,
  files: List(String),
  path: String,
  text: String,
) -> Result(Staging, Problem) {
  let trimmed = string.trim(text)

  // The file must be one the review holds, and the text within its bound.
  case list.contains(files, path), too_long(trimmed) {
    False, _ -> Error(UnknownFile)
    True, True -> Error(TooLong)
    True, False ->
      Ok(
        Staging(
          ..staging,
          comments: recommented(staging.comments, path, trimmed),
        ),
      )
  }
}

/// The comments after a file's text was staged: an empty text takes its comment
/// back, a text for a file that has one replaces it where it stood, and any
/// other is added last.
fn recommented(
  comments: List(FileComment),
  path: String,
  text: String,
) -> List(FileComment) {
  let entry = FileComment(path:, text:)
  let held = list.any(comments, fn(each) { each.path == path })

  // The text and whether the file already has a comment decide the change.
  case text, held {
    "", _ -> list.filter(comments, fn(each) { each.path != path })
    _, True ->
      list.map(comments, fn(each) {
        case each.path == path {
          True -> entry
          False -> each
        }
      })
    _, False -> list.append(comments, [entry])
  }
}

/// Stages how a find is closed, with what the owner wrote about it. It replaces
/// the action staged for the same find, unless the daemon has applied that one:
/// a closed find is closed, and is not closed a second way. A note past
/// `note_limit` bytes is refused.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(staged) = review_stage_rule.find_action(review_stage_rule.empty(), "find-1", 4, attention.Fixed, "done")
/// assert list.length(staged.finds) == 1
/// ```
pub fn find_action(
  staging: Staging,
  id: String,
  revision: Int,
  closure: Closure,
  note: String,
) -> Result(Staging, Problem) {
  let trimmed = string.trim(note)
  let entry =
    FindAction(
      id:,
      revision:,
      closure:,
      note: case trimmed {
        "" -> None
        text -> Some(text)
      },
      standing: Pending,
    )

  // An applied action stands, so the staging is unchanged for that find.
  case too_long(trimmed), list.find(staging.finds, fn(each) { each.id == id }) {
    True, _ -> Error(TooLong)
    False, Ok(FindAction(standing: Applied, ..)) -> Ok(staging)
    False, Ok(_) ->
      Ok(
        Staging(
          ..staging,
          finds: list.map(staging.finds, fn(each) {
            case each.id == id {
              True -> entry
              False -> each
            }
          }),
        ),
      )
    False, Error(Nil) ->
      Ok(Staging(..staging, finds: list.append(staging.finds, [entry])))
  }
}

/// The first find action the daemon has not applied, which Send applies next.
///
/// ## Examples
///
/// ```gleam
/// assert review_stage_rule.pending_close(review_stage_rule.empty()) == None
/// ```
pub fn pending_close(staging: Staging) -> Option(FindAction) {
  staging.finds
  |> list.find(fn(each) { each.standing == Pending })
  |> option.from_result
}

/// Marks a find's action applied.
///
/// ## Examples
///
/// ```gleam
/// assert review_stage_rule.applied(review_stage_rule.empty(), "find-1") == review_stage_rule.empty()
/// ```
pub fn applied(staging: Staging, id: String) -> Staging {
  Staging(
    ..staging,
    finds: list.map(staging.finds, fn(each) {
      case each.id == id {
        True -> FindAction(..each, standing: Applied)
        False -> each
      }
    }),
  )
}

/// The staging without a find's action, for a close the daemon refused.
///
/// ## Examples
///
/// ```gleam
/// assert review_stage_rule.dropped(review_stage_rule.empty(), "find-1") == review_stage_rule.empty()
/// ```
pub fn dropped(staging: Staging, id: String) -> Staging {
  Staging(
    ..staging,
    finds: list.filter(staging.finds, fn(each) { each.id != id }),
  )
}

/// The words for a refused stage.
///
/// ## Examples
///
/// ```gleam
/// assert review_stage_rule.problem_words(review_stage_rule.TooLong)
///   == "That note is over 4096 bytes. Shorten it."
/// ```
pub fn problem_words(problem: Problem) -> String {
  case problem {
    UnknownFile -> "That file is not in this review."
    TooLong -> "That note is over 4096 bytes. Shorten it."
  }
}

/// Whether a text is past the note bound, counted in bytes as the wire is.
fn too_long(text: String) -> Bool {
  bit_array.byte_size(bit_array.from_string(text)) > note_limit
}
