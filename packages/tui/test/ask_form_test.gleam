//// The ask form: which rows an ask has, what each key does to the draft, and
//// when the draft is an answer the daemon's own rule accepts.

import ask_scene
import core/attention
import core/attention_answer
import etui/keys
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tui/ask_form.{type Form}

fn choice() -> Form {
  ask_scene.form(ask_scene.choice_ask(
    "ask-3f9c01a2b4",
    ask_scene.thirteen_forty,
  ))
}

fn kinds() -> Form {
  ask_scene.form(ask_scene.kinds_ask("ask-77d0a1c9e2"))
}

// Presses each key in turn on the form and returns the form it ends in. A key
// that sends or leaves is not expected before the end, so a test that wants
// one folds with `last_action` instead.
fn press(form: Form, pressed: List(keys.Key)) -> Form {
  list.fold(pressed, form, fn(held, key) {
    case ask_form.update(key, held) {
      ask_form.Continue(next) -> next
      ask_form.Leave(next) -> next
      ask_form.Page(next, _) -> next
      ask_form.Send(next, _) -> next
    }
  })
}

// The action the last key asked for, after the earlier keys only continued.
fn last_action(form: Form, pressed: List(keys.Key)) -> ask_form.Action {
  let assert Ok(last) = list.last(pressed) as "a key to press"
  let before = list.take(pressed, list.length(pressed) - 1)
  ask_form.update(last, press(form, before))
}

fn typed(text: String) -> List(keys.Key) {
  text |> string.to_graphemes |> list.map(keys.Char)
}

pub fn the_rows_follow_each_kind_test() {
  assert ask_form.rows(choice())
    == [
      ask_form.Pick(0, 0),
      ask_form.Pick(0, 1),
      ask_form.OtherRow(0),
      ask_form.Pick(1, 0),
      ask_form.Pick(1, 1),
      ask_form.OtherRow(1),
      ask_form.SendRow,
    ]
  assert ask_form.rows(kinds())
    == [
      ask_form.Pick(0, 0),
      ask_form.Pick(0, 1),
      ask_form.Pick(0, 2),
      ask_form.OtherRow(0),
      ask_form.Pick(1, 0),
      ask_form.Pick(1, 1),
      ask_form.OtherRow(1),
      ask_form.FillRow(2),
      ask_form.SendRow,
    ]
}

pub fn the_cursor_stays_inside_the_rows_test() {
  let top = press(choice(), [keys.Up, keys.Up])
  assert top.cursor == 0
  let bottom = press(choice(), list.repeat(keys.Down, 30))
  assert ask_form.row_at(bottom) == ask_form.SendRow
  assert press(choice(), [keys.End]).cursor == 6
  assert press(bottom, [keys.Home]).cursor == 0
}

pub fn tab_moves_between_questions_and_ends_on_send_test() {
  let second = press(choice(), [keys.Tab])
  assert ask_form.row_at(second) == ask_form.Pick(1, 0)
  let send = press(choice(), [keys.Tab, keys.Tab])
  assert ask_form.row_at(send) == ask_form.SendRow
  let back = press(send, [keys.BackTab])
  assert ask_form.row_at(back) == ask_form.Pick(1, 0)
}

pub fn space_picks_one_option_and_a_second_pick_replaces_it_test() {
  let form = press(choice(), [keys.Char(" "), keys.Down, keys.Char(" ")])
  assert ask_form.draft_of(form, 0).picked == [1]
  assert ask_form.values(form) == [#("q1", attention.Picked("Separate list"))]
}

pub fn a_confirm_is_yes_or_no_test() {
  let yes = press(choice(), [keys.Tab, keys.Enter])
  assert ask_form.values(yes) == [#("q2", attention.Yes)]
  let no = press(yes, [keys.Down, keys.Enter])
  assert ask_form.values(no) == [#("q2", attention.No)]
}

pub fn a_checklist_toggles_and_other_replaces_the_options_test() {
  // Toggle a and c of the multiple question, then toggle a off again.
  let toggled =
    press(kinds(), [
      keys.Char(" "),
      keys.Down,
      keys.Down,
      keys.Char(" "),
      keys.Up,
      keys.Up,
      keys.Char(" "),
    ])
  assert ask_form.values(toggled)
    == [
      #("q1", attention.PickedMany(["c"])),
      #("q2", attention.PickedMany([])),
    ]

  // Other clears the picks, and an option clears Other.
  let other = press(toggled, [keys.Down, keys.Down, keys.Down, keys.Enter])
  assert ask_form.draft_of(other, 0).picked == []
  assert ask_form.draft_of(other, 0).other == Some("")
  let again = press(other, [keys.Escape, keys.Up, keys.Char(" ")])
  assert ask_form.draft_of(again, 0).other == None
  assert ask_form.draft_of(again, 0).picked == [2]
}

pub fn enter_on_other_types_and_the_text_is_the_answer_test() {
  let form =
    press(
      choice(),
      list.flatten([
        [keys.Down, keys.Down, keys.Enter],
        typed("do it in a branch"),
        [keys.Backspace, keys.Char("h"), keys.Enter],
      ]),
    )
  assert form.entry == ask_form.Browsing
  assert ask_form.values(form)
    == [#("q1", attention.Other("do it in a branc" <> "h"))]
}

pub fn browsing_never_types_test() {
  let form = press(choice(), typed("hello"))
  assert form == choice()
}

pub fn typing_takes_every_printable_key_and_escape_stops_it_test() {
  let typing = press(choice(), [keys.Down, keys.Down, keys.Enter])
  assert typing.entry == ask_form.Typing

  // Space and the letters that mean something while browsing are text.
  let spaced = press(typing, [keys.Char("a"), keys.Char(" "), keys.Char("j")])
  assert ask_form.draft_of(spaced, 0).other == Some("a j")

  // Escape stops typing and keeps the form, and a second Escape leaves.
  let stopped = press(spaced, [keys.Escape])
  assert stopped.entry == ask_form.Browsing
  assert ask_form.draft_of(stopped, 0).other == Some("a j")
  let assert ask_form.Leave(kept) = ask_form.update(keys.Escape, stopped)
  assert ask_form.draft_of(kept, 0).other == Some("a j")
}

pub fn a_fill_question_takes_typed_text_test() {
  let form =
    press(
      kinds(),
      list.flatten([[keys.End, keys.Up, keys.Enter], typed("src/a.gleam")]),
    )
  assert list.key_find(ask_form.values(form), "q3")
    == Ok(attention.Typed("src/a.gleam"))
}

pub fn pasted_text_joins_while_typing_and_is_dropped_while_browsing_test() {
  let browsing = ask_form.pasted(choice(), "ignored")
  assert browsing == choice()
  let typing = press(choice(), [keys.Down, keys.Down, keys.Enter])
  let pasted = ask_form.pasted(typing, "two\nlines")
  assert ask_form.draft_of(pasted, 0).other == Some("two lines")
}

pub fn an_unanswered_question_is_refused_in_words_test() {
  let assert ask_form.Continue(refused) =
    ask_form.update(keys.Ctrl("s"), choice())
  assert refused.refusal == Some("Question 1: needs an answer")
}

pub fn the_rules_own_words_name_the_question_test() {
  // Nothing picked in a multiple question that needs at least one. The rule
  // reports a question with no answer at all before it judges an answer, so the
  // fill question is answered first.
  let filled =
    press(
      kinds(),
      list.flatten([
        [keys.End, keys.Up, keys.Enter],
        typed("a.gleam"),
        [keys.Enter],
      ]),
    )
  let assert ask_form.Continue(few) = ask_form.update(keys.Ctrl("s"), filled)
  assert few.refusal == Some("Question 1: too few choices")

  // Other with no text is refused as the daemon refuses it.
  let empty_other =
    press(choice(), [keys.Tab, keys.Enter, keys.Up, keys.Enter, keys.Enter])
  let assert ask_form.Continue(empty) =
    ask_form.update(keys.Ctrl("s"), empty_other)
  assert empty.refusal == Some("Question 1: Other needs some text")
}

pub fn a_checked_answer_sends_the_object_the_daemon_takes_test() {
  let form = press(choice(), [keys.Char(" "), keys.Tab, keys.Enter])
  let assert ask_form.Send(_, answer) = ask_form.update(keys.Ctrl("s"), form)
  let values = [
    #("q1", attention.Picked("Fold under open ones")),
    #("q2", attention.Yes),
  ]
  assert answer == attention.answer_object(values)
  assert attention_answer.check(form.ask, answer) == Ok(values)
}

pub fn the_send_row_sends_and_ctrl_s_sends_while_typing_test() {
  let answered = press(choice(), [keys.Char(" "), keys.Tab, keys.Enter])
  let assert ask_form.Send(..) = last_action(answered, [keys.Tab, keys.Enter])
    as "Enter on the Send row sends"

  // Answer the confirm, then type into the first question's Other.
  let typing =
    press(
      choice(),
      list.flatten([
        [keys.Tab, keys.Enter, keys.Up, keys.Enter],
        typed("x"),
      ]),
    )
  assert typing.entry == ask_form.Typing
  let assert ask_form.Send(..) = ask_form.update(keys.Ctrl("s"), typing)
    as "Ctrl+S sends from inside a text field"
}

pub fn an_observer_cannot_send_test() {
  let observer = ask_form.Form(..choice(), standing: ask_form.ObserverOnly)
  let ready = press(observer, [keys.Char(" "), keys.Tab, keys.Enter])
  let assert ask_form.Continue(held) = ask_form.update(keys.Ctrl("s"), ready)
  assert held.refusal == Some("You can read this ask but not answer it.")
}

pub fn escape_leaves_and_keeps_the_draft_test() {
  let form = press(choice(), [keys.Char(" ")])
  let assert ask_form.Leave(kept) = ask_form.update(keys.Escape, form)
  assert ask_form.draft_of(kept, 0).picked == [0]
}

pub fn the_page_keys_ask_for_another_ask_test() {
  let assert ask_form.Page(_, 1) = ask_form.update(keys.PageDown, choice())
  let assert ask_form.Page(_, -1) = ask_form.update(keys.PageUp, choice())
}

pub fn reading_the_same_ask_again_keeps_the_draft_test() {
  let form = press(choice(), [keys.Char(" ")])
  let again = ask_form.refreshed(form, form.ask, 42, ask_form.MayAnswer)
  assert again.revision == 42
  assert again.drafts == form.drafts

  let changed =
    ask_form.refreshed(
      form,
      ask_scene.kinds_ask("ask-3f9c01a2b4"),
      42,
      ask_form.MayAnswer,
    )
  assert changed.drafts != form.drafts
  assert changed.cursor == 0
}

pub fn a_refusal_clears_when_the_owner_edits_test() {
  let form = ask_form.refused(choice(), "The ask changed.")
  assert form.refusal == Some("The ask changed.")
  let edited = press(form, [keys.Char(" ")])
  assert edited.refusal == None
}
