//// The right panel's content: what a strand's card and its own view say, and
//// which strands get a card.
////
//// A card begins its status line with the state's glyph and names a tool
//// without its command, which is the card's tooltip. A strand that has never
//// run, which is what a fresh fork is, is a live card and not a settled one,
//// and the page that forked it need not focus it to see it. A strand's own
//// view says what it does not know and shows the first line of the strand's
//// answer when no tool ran.

import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/element
import page_fixture
import session_view/agent_roster
import session_view/agent_view
import session_view/turns
import web_view/component
import web_view/view/strand_detail
import web_view/view/strip

fn chip(status: agent_view.Status, text: String) -> strip.Chip {
  strip.Chip(
    line: agent_roster.Line(
      id: "sub:main/x",
      name: "x",
      status:,
      text:,
      title: "",
      elapsed_s: None,
      tokens: None,
    ),
    hue: turns.Sub(0),
    cache: None,
    running_ms: None,
    model: "",
    recent: [],
    answer: None,
  )
}

fn card(chip: strip.Chip) -> String {
  element.to_string(
    strip.view(
      strip.Strip(
        chips: [chip],
        advisor: None,
        settled: [],
        earlier: 0,
        followed: "main",
      ),
      fn(name) { name },
    ),
  )
}

pub fn a_card_begins_its_status_with_the_states_glyph_test() {
  let working = card(chip(agent_view.Working, "assistant"))
  assert string.contains(
    working,
    "<span class=\"chip-status running\"><span aria-hidden=\"true\" class=\"st\">●</span>Working · thinking</span>",
  )

  let waiting = card(chip(agent_view.Waiting, "Waiting for docs"))
  assert string.contains(waiting, "◌</span>Waiting for docs</span>")
  assert !string.contains(waiting, "Waiting · Waiting")
}

// The command is the card's tooltip and not its status, so a long one cannot
// push the line off the card, and it is only ever an escaped attribute.
pub fn a_tool_is_named_and_its_command_is_the_cards_title_test() {
  let drawn =
    card(chip(agent_view.Working, "bash · printf '<b>' > /Users/x/notes.txt"))

  assert string.contains(drawn, "Working · bash</span>")
  assert string.contains(drawn, "title=\"Working · bash · printf ")
  assert string.contains(drawn, "/Users/x/notes.txt\"")
  assert !string.contains(drawn, "<b>")

  // A status that says all there is has no tooltip to repeat it.
  assert !string.contains(card(chip(agent_view.Idle, "")), "title=")
}

// A fork has no operation and no recorded result until its first prompt, so
// the strip lists it among the live cards, and the page that forked it keeps
// its focus on `main`.
pub fn a_strand_that_never_ran_is_a_live_card_without_being_focused_test() {
  let model =
    component.new(page_fixture.start())
    |> component.apply([
      lane_fixture.unrun(
        lane_fixture.captured_with(10, None, []),
        lane_fixture.tester,
      ),
    ])
  let drawn = element.to_string(component.view(model))

  assert component.strand(model) == component.primary
  let assert Ok(#(live, group)) = string.split_once(drawn, "settled-group")
    as "the reviewer finished, so a group is drawn"
  assert string.contains(live, ">tests<")
  assert !string.contains(group, ">tests<")
  assert string.contains(group, "review")
}

pub fn a_strands_view_names_the_task_and_shortens_the_model_test() {
  let base = chip(agent_view.Working, "assistant")
  let known =
    strip.Chip(
      ..base,
      line: agent_roster.Line(..base.line, title: "Fix the <parser>"),
      model: "zai-org/GLM-5.3",
    )
  let drawn = element.to_string(strand_detail.view(known))

  assert string.contains(drawn, "Task")
  assert string.contains(drawn, "Fix the &lt;parser&gt;")
  assert string.contains(
    drawn,
    "<span title=\"zai-org/GLM-5.3\">GLM-5.3</span>",
  )
  assert string.contains(drawn, "not reported")

  // A placeholder the roster words for a task it cannot read is not a task.
  let unread =
    strip.Chip(
      ..base,
      line: agent_roster.Line(
        ..base.line,
        title: "Task brief outside loaded history",
      ),
    )
  assert !string.contains(element.to_string(strand_detail.view(unread)), "Task")
}

pub fn a_strand_that_ran_no_tool_shows_its_answers_first_line_test() {
  let answered =
    strip.Chip(
      ..chip(agent_view.Finished, ""),
      answer: Some("Nothing to correct <here>."),
    )
  let drawn = element.to_string(strand_detail.view(answered))

  assert string.contains(drawn, "Nothing to correct &lt;here&gt;.")
  assert !string.contains(drawn, "No tools yet.")

  // With tools, the tools are the list and the answer is not repeated.
  let tooled = strip.Chip(..answered, recent: ["fs_read"])
  let drawn = element.to_string(strand_detail.view(tooled))
  assert string.contains(drawn, "<li>fs_read</li>")
  assert !string.contains(drawn, "Nothing to correct")
}
