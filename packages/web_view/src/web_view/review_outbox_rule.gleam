//// The one prompt a review's Send delivers: its exact words, and the refusal
//// that stops a prompt the composer could not carry (the attention inbox's
//// review pane, `docs/design-notes/attention-inbox/README.md` section 2.1).
////
//// Everything the owner staged (`web_view/review_stage_rule`) becomes one
//// message to the session's strand, in the words below. The composer's bound,
//// 16,384 bytes (`composer.prompt_limit`), is checked here before anything is
//// sent, so an oversized review is refused on the page with the byte count and
//// never reaches the gateway.
////
//// The prompt reads:
////
//// ```text
//// I reviewed your changes. Verdict: changes requested.
////
//// File comments:
////
//// src/retry.gleam:
//// The wait should cap at 30 s.
////
//// Finds I closed:
////
//// find-3f9c01a2b4: fixed. Thanks, this is done.
//// ```
////
//// The verdict line, the comments section and the finds section each appear
//// only when something was staged for them. Files are listed in the review's
//// order, and finds in the order they were staged. The text is the owner's
//// own and the paths are the repository's; the identifiers are the daemon's.
//// No page text is interpreted.
////
//// The module is pure and holds no Lustre.

import core/attention
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import web_view/composer
import web_view/review_stage_rule.{type FindAction, type Staging}

/// Why no prompt could be made.
pub type Refusal {
  /// Nothing is staged, so there is nothing to send.
  NothingStaged

  /// A comment names a file the review no longer holds.
  FileMissing

  /// The prompt is past the composer's bound.
  TooLong(bytes: Int)
}

/// The words of a verdict.
///
/// ## Examples
///
/// ```gleam
/// assert review_outbox_rule.verdict_words(review_stage_rule.Approve) == "approved"
/// ```
pub fn verdict_words(verdict: review_stage_rule.Verdict) -> String {
  case verdict {
    review_stage_rule.Approve -> "approved"
    review_stage_rule.RequestChanges -> "changes requested"
    review_stage_rule.Comment -> "comments only, no decision"
  }
}

/// The words of a way to close a find.
///
/// ## Examples
///
/// ```gleam
/// assert review_outbox_rule.closure_words(attention.Dismissed) == "dismissed"
/// ```
pub fn closure_words(closure: attention.Closure) -> String {
  case closure {
    attention.Fixed -> "fixed"
    attention.Filed -> "filed"
    attention.Dismissed -> "dismissed"
  }
}

/// The prompt for what is staged, or the reason there is none. `files` are the
/// paths of the review in the order it draws them, which orders the comments.
///
/// ## Examples
///
/// ```gleam
/// assert review_outbox_rule.compose([], review_stage_rule.empty())
///   == Error(review_outbox_rule.NothingStaged)
/// ```
pub fn compose(
  files: List(String),
  staging: Staging,
) -> Result(String, Refusal) {
  // An empty staging has nothing to send.
  use Nil <- result.try(case review_stage_rule.is_empty(staging) {
    True -> Error(NothingStaged)
    False -> Ok(Nil)
  })

  // Every comment must still name a file of the review.
  use Nil <- result.try(
    case
      list.all(staging.comments, fn(each) { list.contains(files, each.path) })
    {
      True -> Ok(Nil)
      False -> Error(FileMissing)
    },
  )

  // The verdict, when chosen, opens the prompt.
  let opening = case staging.verdict {
    Some(verdict) ->
      "I reviewed your changes. Verdict: " <> verdict_words(verdict) <> "."
    None -> "I reviewed your changes."
  }

  let text =
    string.join(
      list.flatten([
        [opening],
        comments_section(files, staging),
        finds_section(staging),
      ]),
      "\n\n",
    )

  // The prompt is bounded as the composer is, by bytes.
  let bytes = bit_array.byte_size(bit_array.from_string(text))

  // A prompt past the composer's bound is refused with its size.
  case bytes > composer.prompt_limit {
    True -> Error(TooLong(bytes:))
    False -> Ok(text)
  }
}

/// The refusal's words, which carry the byte counts and nothing the owner wrote.
///
/// ## Examples
///
/// ```gleam
/// assert review_outbox_rule.refusal_words(review_outbox_rule.NothingStaged)
///   == "Nothing is staged."
/// ```
pub fn refusal_words(refusal: Refusal) -> String {
  case refusal {
    NothingStaged -> "Nothing is staged."
    FileMissing -> "A comment names a file this review no longer holds."
    TooLong(bytes:) ->
      "This review is "
      <> int_text(bytes)
      <> " bytes, over the "
      <> int_text(composer.prompt_limit)
      <> " byte limit. Shorten a comment or a note."
  }
}

/// The file comments section, as one block, or nothing when none are staged.
fn comments_section(files: List(String), staging: Staging) -> List(String) {
  let ordered =
    list.filter_map(files, fn(path) {
      list.find(staging.comments, fn(each) { each.path == path })
    })

  // No staged comment draws no section.
  case ordered {
    [] -> []
    [_, ..] -> [
      "File comments:",
      string.join(
        list.map(ordered, fn(each) { each.path <> ":\n" <> each.text }),
        "\n\n",
      ),
    ]
  }
}

/// The closed finds section, as one block, or nothing when none are staged.
fn finds_section(staging: Staging) -> List(String) {
  case staging.finds {
    [] -> []
    [_, ..] -> [
      "Finds I closed:",
      string.join(list.map(staging.finds, find_line), "\n"),
    ]
  }
}

/// One find's line: its identifier, how it was closed and the owner's note.
fn find_line(action: FindAction) -> String {
  let base = action.id <> ": " <> closure_words(action.closure) <> "."

  // The owner's note, when there is one, follows the way the find was closed.
  case action.note {
    Some(note) -> base <> " " <> note
    None -> base
  }
}

/// A count as text.
fn int_text(count: Int) -> String {
  int.to_string(count)
}
