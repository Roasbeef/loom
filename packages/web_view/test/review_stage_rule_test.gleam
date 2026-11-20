//// What a review stages, and the one prompt Send delivers
//// (`web_view/review_stage_rule`, `web_view/review_outbox_rule`).

import core/attention
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import web_view/review_outbox_rule as outbox
import web_view/review_stage_rule as stage

const files = ["src/retry.gleam", "test/retry_test.gleam", "docs/retry.md"]

pub fn an_empty_staging_composes_nothing_test() {
  assert stage.is_empty(stage.empty())
  assert outbox.compose(files, stage.empty()) == Error(outbox.NothingStaged)
}

pub fn the_same_verdict_twice_takes_it_back_test() {
  let once = stage.verdict(stage.empty(), stage.Approve)
  assert once.verdict == Some(stage.Approve)
  assert stage.verdict(once, stage.Approve).verdict == None
  assert stage.verdict(once, stage.RequestChanges).verdict
    == Some(stage.RequestChanges)
}

pub fn a_comment_replaces_keeps_its_place_and_empties_test() {
  let assert Ok(one) = stage.comment(stage.empty(), files, "docs/retry.md", "a")
  let assert Ok(two) = stage.comment(one, files, "src/retry.gleam", "b")
  let assert Ok(again) = stage.comment(two, files, "docs/retry.md", " c ")
  assert again.comments
    == [
      stage.FileComment("docs/retry.md", "c"),
      stage.FileComment("src/retry.gleam", "b"),
    ]
  let assert Ok(gone) = stage.comment(again, files, "docs/retry.md", "  ")
  assert gone.comments == [stage.FileComment("src/retry.gleam", "b")]
}

pub fn a_comment_on_an_unknown_file_or_too_long_is_refused_test() {
  assert stage.comment(stage.empty(), files, "elsewhere.gleam", "x")
    == Error(stage.UnknownFile)
  assert stage.comment(
      stage.empty(),
      files,
      "src/retry.gleam",
      string.repeat("x", stage.note_limit + 1),
    )
    == Error(stage.TooLong)
}

pub fn an_applied_find_action_is_not_replaced_test() {
  let assert Ok(one) =
    stage.find_action(stage.empty(), "find-1", 4, attention.Fixed, "done")
  assert stage.pending_close(one)
    == Some(stage.FindAction(
      "find-1",
      4,
      attention.Fixed,
      Some("done"),
      stage.Pending,
    ))
  let assert Ok(changed) =
    stage.find_action(one, "find-1", 4, attention.Filed, "")
  assert list.map(changed.finds, fn(each) { each.closure }) == [attention.Filed]
  let done = stage.applied(changed, "find-1")
  assert stage.pending_close(done) == None
  let assert Ok(kept) =
    stage.find_action(done, "find-1", 4, attention.Dismissed, "")
  assert kept == done
}

pub fn the_prompt_has_exact_words_in_review_order_test() {
  let assert Ok(s) =
    stage.comment(
      stage.empty(),
      files,
      "test/retry_test.gleam",
      "Cover the cap.",
    )
  let assert Ok(s) =
    stage.comment(s, files, "src/retry.gleam", "The wait should cap at 30 s.")
  let assert Ok(s) =
    stage.find_action(s, "find-3f9c01a2b4", 2, attention.Fixed, "Thanks.")
  let assert Ok(s) =
    stage.find_action(s, "find-aaaaaaaaaa", 1, attention.Dismissed, "")
  let s = stage.verdict(s, stage.RequestChanges)

  assert outbox.compose(files, s)
    == Ok(
      "I reviewed your changes. Verdict: changes requested.\n\n"
      <> "File comments:\n\n"
      <> "src/retry.gleam:\nThe wait should cap at 30 s.\n\n"
      <> "test/retry_test.gleam:\nCover the cap.\n\n"
      <> "Finds I closed:\n\n"
      <> "find-3f9c01a2b4: fixed. Thanks.\n"
      <> "find-aaaaaaaaaa: dismissed.",
    )
}

pub fn a_verdict_alone_is_a_prompt_test() {
  let s = stage.verdict(stage.empty(), stage.Approve)
  assert outbox.compose(files, s)
    == Ok("I reviewed your changes. Verdict: approved.")
  let c = stage.verdict(stage.empty(), stage.Comment)
  assert outbox.compose(files, c)
    == Ok("I reviewed your changes. Verdict: comments only, no decision.")
}

pub fn a_comment_on_a_vanished_file_is_refused_test() {
  let assert Ok(s) = stage.comment(stage.empty(), files, "src/retry.gleam", "x")
  assert outbox.compose(["other.gleam"], s) == Error(outbox.FileMissing)
}

pub fn a_prompt_over_the_composer_bound_is_refused_with_its_size_test() {
  // Five notes just under the note bound exceed the composer's bound.
  let big = string.repeat("é", 2000)
  let assert Ok(s) = stage.comment(stage.empty(), files, "src/retry.gleam", big)
  let assert Ok(s) = stage.comment(s, files, "test/retry_test.gleam", big)
  let assert Ok(s) = stage.comment(s, files, "docs/retry.md", big)
  let assert Ok(s) = stage.find_action(s, "find-1", 1, attention.Fixed, big)
  let assert Ok(s) = stage.find_action(s, "find-2", 1, attention.Fixed, big)

  let assert Error(outbox.TooLong(bytes:)) = outbox.compose(files, s)
  assert bytes > 16_384
  assert string.contains(
    outbox.refusal_words(outbox.TooLong(bytes:)),
    "over the 16384 byte limit",
  )
}

pub fn a_prompt_under_the_bound_is_carried_test() {
  let note = string.repeat("a", 4000)
  let assert Ok(s) =
    stage.comment(stage.empty(), files, "src/retry.gleam", note)
  let assert Ok(text) = outbox.compose(files, s)
  assert string.length(text) < 16_384
}
