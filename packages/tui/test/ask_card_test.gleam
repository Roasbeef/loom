//// The ask card, read off whole frames: where it sits, what it says for each
//// kind of question, and how the transcript shows an ask and its answer.

import ask_scene
import core/json
import etui/keys
import frame_scene
import gleam/list
import gleam/string
import tui/ask_control
import tui/frame
import tui/layout
import tui/model as tui_model

fn lines(model: tui_model.Model, width: Int, height: Int) -> List(String) {
  frame_scene.screen(model, width, height) |> frame.buffer_to_lines
}

fn index_of(lines: List(String), needle: String) -> Int {
  let assert Ok(#(index, _)) =
    lines
    |> list.index_map(fn(line, index) { #(index, line) })
    |> list.find(fn(pair) { string.contains(pair.1, needle) })
    as { "the frame draws " <> needle }
  index
}

fn drawn(lines: List(String), needle: String) -> Bool {
  list.any(lines, string.contains(_, needle))
}

fn two_asks() -> tui_model.Model {
  ask_scene.with_asks(
    [
      ask_scene.form(ask_scene.choice_ask(
        "ask-3f9c01a2b4",
        ask_scene.thirteen_forty,
      )),
      ask_scene.form(ask_scene.kinds_ask("ask-77d0a1c9e2")),
    ],
    5,
  )
}

pub fn the_card_sits_above_the_composer_and_names_who_asked_test() {
  list.each([#(120, 40), #(80, 24)], fn(size) {
    let frame = lines(two_asks(), size.0, size.1)
    let heading = index_of(frame, "Ask · waiting since 13:40 · main")
    let input = index_of(frame, "╭─ To main")
    assert heading < input
    assert drawn(frame, "Closed items: fold under open ones, or keep a list?")
    assert list.all(frame, fn(line) { string.length(line) <= size.0 })
  })
}

pub fn the_choices_of_each_kind_are_drawn_test() {
  let frame = lines(two_asks(), 120, 60)
  assert drawn(
    frame,
    "( ) Fold under open ones  (recommended)  Keeps context together.",
  )
  assert drawn(frame, "( ) Separate list  Closed work leaves the page.")
  assert drawn(frame, "( ) Other")
  assert drawn(frame, "2. Keep the independent parts? (yes or no)")
  assert drawn(frame, "( ) Yes")
  assert drawn(frame, "( ) No")
  assert drawn(frame, "Why: The tree has both layouts and one has to go.")

  // The second ask: toggles for multiple and checklist, a field for fill.
  assert drawn(frame, "Ask · waiting since 13:40 · sub:audit · 2 of 2")
  assert drawn(frame, "1. Which files? (pick 1 to 2)")
  assert drawn(frame, "[ ] a")
  assert drawn(frame, "2. Which checks? (pick any)")
  assert drawn(frame, "[ ] lint")
  assert drawn(frame, "3. Which path? (a file path)")
  assert drawn(frame, "[ ] type an answer")
}

pub fn at_most_two_asks_are_drawn_and_the_rest_are_counted_test() {
  let frame = lines(two_asks(), 120, 60)
  assert drawn(frame, "3 more open asks")
  let one =
    lines(
      ask_scene.with_asks(
        [ask_scene.form(ask_scene.choice_ask("ask-3f9c01a2b4", 0))],
        2,
      ),
      120,
      60,
    )
  assert drawn(one, "1 more open ask")
  assert !drawn(one, "1 more open asks")
}

pub fn the_composer_keeps_the_keyboard_and_the_hint_names_the_key_test() {
  let frame = lines(two_asks(), 120, 40)
  assert drawn(frame, "Alt+A answers")
  assert !drawn(frame, "Ctrl+S sends")
  assert !drawn(frame, "Send answer")
}

pub fn the_focused_card_marks_the_cursor_and_names_its_keys_test() {
  let model =
    two_asks()
    |> ask_control.focus
    |> ask_control.key(keys.Down)
    |> ask_control.key(keys.Char(" "))
  let frame = lines(model, 120, 60)
  assert drawn(frame, "› (•) Separate list")
  assert drawn(frame, "Space picks")
  assert drawn(frame, "Ctrl+S sends")
  assert drawn(frame, "Esc composer")
  assert drawn(frame, "Send answer")
}

pub fn typing_into_other_shows_the_text_and_a_cursor_test() {
  let model =
    two_asks()
    |> ask_control.focus
    |> ask_control.key(keys.Down)
    |> ask_control.key(keys.Down)
    |> ask_control.key(keys.Enter)
  let model =
    list.fold(string.to_graphemes("a branch"), model, fn(m, c) {
      ask_control.key(m, keys.Char(c))
    })
  let frame = lines(model, 120, 60)
  assert drawn(frame, "(•) Other: a branch▏")
  assert drawn(frame, "Enter done")
}

pub fn an_observer_sees_the_questions_and_no_controls_test() {
  let model =
    ask_scene.with_asks(
      [
        tui_form_observer(ask_scene.choice_ask(
          "ask-3f9c01a2b4",
          ask_scene.thirteen_forty,
        )),
      ],
      1,
    )
  let frame = lines(model, 120, 40)
  assert drawn(frame, "Closed items: fold under open ones")
  assert drawn(frame, "You can read this ask but not answer it")
  assert !drawn(frame, "Alt+A")
  assert !drawn(frame, "Send answer")
}

fn tui_form_observer(ask) {
  ask_scene.observer(ask)
}

pub fn the_card_takes_rows_from_the_transcript_not_from_the_composer_test() {
  let bare = ask_scene.with_asks([], 0)
  let asked = two_asks()
  assert layout.ask_height(bare) == 0
  assert layout.ask_height(asked) > 0

  // The composer stays where it was; only the body above it is shorter.
  let screen = frame_scene.screen(bare, 100, 40) |> frame.buffer_to_lines
  let with_card = frame_scene.screen(asked, 100, 40) |> frame.buffer_to_lines
  assert index_of(screen, "╭─ To main") == index_of(with_card, "╭─ To main")
}

pub fn a_short_terminal_keeps_its_transcript_and_draws_no_card_test() {
  let frame = lines(two_asks(), 80, 8)
  assert !drawn(frame, "Ask · waiting")
}

pub fn the_ask_call_reads_as_its_question_not_as_json_test() {
  let arguments = [
    #(
      "questions",
      json.Array([
        json.Object([
          #("kind", json.String("choice")),
          #(
            "prompt",
            json.String("Closed items: fold under open ones, or keep a list?"),
          ),
          #("options", json.Array([json.String("a"), json.String("b")])),
        ]),
        json.Object([
          #("kind", json.String("confirm")),
          #("prompt", json.String("Keep the independent parts?")),
        ]),
      ]),
    ),
  ]
  let model =
    frame_scene.attach(frame_scene.model(), ask_scene.session, [
      frame_scene.user(1, "Ask me first"),
      frame_scene.assistant(2, "", [frame_scene.call("c1", "ask", arguments)]),
    ])
  let frame = lines(model, 120, 30)
  assert drawn(
    frame,
    "ask · 2 questions: Closed items: fold under open ones, or keep a list?",
  )
  assert !drawn(frame, "{\"questions\"")
}

pub fn the_delivered_answer_keeps_its_line_breaks_test() {
  let answer =
    "Answer to your ask ask-3f9c01a2b4.\n\n1. Retry?\n   Yes\n\n2. Which branch?\n   \"topic\"\n\n3. Anything else?\n   Other (not one of the options): Do it in a branch\n   instead."
  let model =
    frame_scene.attach(frame_scene.model(), ask_scene.session, [
      frame_scene.user(1, answer),
    ])
  let frame = lines(model, 120, 30)
  let first = index_of(frame, "Answer to your ask ask-3f9c01a2b4.")
  assert index_of(frame, "1. Retry?") == first + 2
  assert index_of(frame, "   Yes") == first + 3
  assert index_of(frame, "2. Which branch?") == first + 5
  assert index_of(frame, "instead.") == first + 10
}

// The window follows the cursor of the card that has the keyboard. With the
// second card focused and the cursor on its Send row, the window must reach it
// even though the first card has a row at the same index.
pub fn the_window_follows_the_cursor_of_the_focused_card_test() {
  let model =
    two_asks()
    |> ask_control.focus
    |> ask_control.key(keys.PageDown)
    |> ask_control.key(keys.End)
  let frame = lines(model, 100, 30)
  assert drawn(frame, "› [ ] Send answer")
}
