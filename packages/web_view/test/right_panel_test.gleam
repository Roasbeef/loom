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
    own_model: None,
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

// The command is the model's own text. The card shows the tool's name in its
// status line and draws nothing of the command: not as a tooltip, not as any
// attribute (protocol-change/051).
pub fn a_tools_command_is_never_an_attribute_test() {
  let drawn =
    card(chip(agent_view.Working, "bash · printf '<b>' > /Users/x/notes.txt"))

  assert string.contains(drawn, "Working · bash</span>")
  assert !string.contains(drawn, "title=")
  assert !string.contains(drawn, "notes.txt")
  assert !string.contains(drawn, "<b>")
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

  // So is the model the capture could not name.
  let unnamed = strip.Chip(..base, model: agent_view.model_unavailable)
  assert !string.contains(
    element.to_string(strand_detail.view(unnamed)),
    "Model",
  )
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

// The answer is drawn as the lane draws it: bold and code kept, no asterisks or
// backticks, and a `\n` the model wrote as two characters is a break, not text.
pub fn the_answers_line_renders_its_markdown_without_a_literal_break_test() {
  let answered =
    strip.Chip(
      ..chip(agent_view.Finished, ""),
      answer: Some("**Current content:** `# calc` \\n Tiny calculator."),
    )
  let drawn = element.to_string(strand_detail.view(answered))

  assert string.contains(drawn, "<strong>Current content:</strong>")
  assert string.contains(drawn, "<code class=\"md-code-span\"># calc</code>")
  assert !string.contains(drawn, "**")
  assert !string.contains(drawn, "`")
  assert !string.contains(drawn, "\\n")
}

// The preview is the answer's first Markdown line, as the lane's is: a heading
// is drawn as its words and the line after it is not run into it.
pub fn a_multi_line_answer_previews_its_first_markdown_line_test() {
  let answered =
    strip.Chip(..chip(agent_view.Finished, ""), answer: Some("# Title\nbody"))
  let drawn = element.to_string(strand_detail.view(answered))
  assert string.contains(drawn, "<p class=\"detail-answer\">Title</p>")
  assert !string.contains(drawn, "body")
  assert !string.contains(drawn, "# Title")
}
