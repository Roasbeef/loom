//// The Updates card and the "Watch all" board (`web_view/view/update_card`,
//// `web_view/view/inbox`): what a card says of a working session, that the words
//// a session wrote reach text nodes only, that the disclosure adds the steps and
//// the last command, that the board holds one card for each working session, and
//// that the page's own state decides which cards are open.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import web_view/inbox_rule
import web_view/session_brief
import web_view/sessions.{Report}
import web_view/view/inbox_parts as parts
import web_view/view/update_card

fn thread() -> inbox_rule.Thread {
  inbox_rule.Thread(
    id: "W",
    name: "build the cards",
    workspace: "/src/loom",
    report: Report(
      sessions.Working,
      Some("Reading."),
      [],
      None,
      Some(1),
      asks: 0,
    ),
  )
}

fn brief() -> session_brief.Brief {
  session_brief.Brief(
    assistant: Some(session_brief.Assistant(
      text: session_brief.untrusted("Splitting the table <b>now</b>."),
      at: 1,
    )),
    steps: [
      step("bash", "Ran make check", session_brief.Running),
      step("fs_edit", "Edit a.gleam +3 −1", session_brief.Succeeded),
      step("fs_read", "Read b.gleam", session_brief.Succeeded),
      step("bash", "Ran make lint", session_brief.Failed),
      step("fs_read", "Read c.gleam", session_brief.Succeeded),
      step("fs_read", "Read d.gleam", session_brief.Succeeded),
    ],
    strands: [
      session_brief.Strand("main", session_brief.Working, None),
      session_brief.Strand("sub:mock-a", session_brief.Working, None),
      session_brief.Strand("sub:mock-b", session_brief.Stopped, None),
    ],
    goal: None,
    peers: [],
    command: Some(session_brief.Command(
      command: session_brief.untrusted("make check"),
      exit: 2,
      at: 1,
    )),
  )
}

fn step(
  tool: String,
  words: String,
  outcome: session_brief.Outcome,
) -> session_brief.Step {
  session_brief.Step(
    at: 1,
    tool: session_brief.untrusted(tool),
    words: session_brief.untrusted(words),
    outcome:,
  )
}

fn card(density: update_card.Density) -> update_card.Card(Nil) {
  update_card.Card(
    thread: thread(),
    state: Some("working, 14 min into a turn"),
    age: None,
    brief: Some(brief()),
    machine: Some("gpu-box"),
    reading: parts.Unread,
    density:,
    pick: Nil,
    open: Nil,
    toggle: Nil,
  )
}

fn drawn(density: update_card.Density) -> String {
  element.to_string(update_card.view(card(density)))
}

// A collapsed card says what the session is doing, its latest message under the
// words that mark it untrusted, the running step, and one compact line of its
// strands, its failed last command and its machine.
pub fn a_collapsed_card_says_what_the_session_is_doing_test() {
  let html = drawn(update_card.Collapsed)

  assert string.contains(html, "build the cards")
  assert string.contains(html, "working, 14 min into a turn")
  assert string.contains(html, "latest message, untrusted text")
  assert string.contains(html, "Ran make check")
  assert string.contains(html, "running")
  assert string.contains(
    html,
    "2 strands: 1 working, 1 stopped · last command exit 2: make check · on gpu-box",
  )
  assert string.contains(html, "Watch live ›")
  assert string.contains(html, "aria-expanded=\"false\"")
}

// The steps, the strands and the last command are the disclosure's, and a
// collapsed card draws none of them.
pub fn the_disclosure_adds_the_steps_and_the_last_command_test() {
  let collapsed = drawn(update_card.Collapsed)
  let open = drawn(update_card.Expanded)

  assert !string.contains(collapsed, "upd-more")
  assert !string.contains(collapsed, "Edit a.gleam")
  assert string.contains(open, "upd-more")
  assert string.contains(open, "Edit a.gleam +3 −1")
  assert string.contains(open, "last command: make check, exit 2")
  assert string.contains(open, "sub:mock-a: working")
  assert string.contains(open, "aria-expanded=\"true\"")

  // At most five steps, however many the brief holds.
  assert !string.contains(open, "Read d.gleam")
  assert list.length(string.split(open, "<li>")) - 1 >= 5
}

// What the session wrote is a text node: markup in it is escaped, and no
// attribute holds it.
pub fn a_sessions_words_reach_text_nodes_only_test() {
  let html = drawn(update_card.Expanded)

  assert string.contains(html, "Splitting the table &lt;b&gt;now&lt;/b&gt;.")
  assert !string.contains(html, "<b>now</b>")
  assert !string.contains(html, "=\"Splitting")
  assert !string.contains(html, "title=")
}

// Before the brief is read the card says what the row said: the session's last
// finished message, and no step or compact line.
pub fn a_card_before_its_brief_is_read_falls_back_to_the_last_message_test() {
  let html =
    element.to_string(update_card.view(
      update_card.Card(
        ..card(update_card.Collapsed),
        brief: None,
        machine: None,
      ),
    ))

  assert string.contains(html, "Reading.")
  assert !string.contains(html, "upd-step")
  assert !string.contains(html, "upd-line")
}
