//// A child that runs on another orchestrator is listed on the strip as
//// `<child> @ <orchestrator>`, says how old its glance is once it stops
//// changing, and opens a peek at its transcript in the lower lane instead of a
//// strand switch (protocol-change/090). The peek draws the page as plain text
//// under the harness's framing, so markup in a model's words reaches the
//// screen as the characters it is.

import core/clock
import core/entry
import core/ids
import core/message
import etui/backend
import etui/geometry
import gleam/option.{None, Some}
import gleam/string
import session_view/agent_roster
import session_view/command
import session_view/model as session_model
import session_view/protocol
import session_view/remote_agent
import session_view/remote_transcript
import session_view/shared_set
import tui
import tui/agent_strip.{Browsing}
import tui/connection
import tui/frame
import tui/model as tui_model
import tui/render
import tui/workspace

const child = "sub:^main/build-1a2b3c"

fn agent(age_ms: option.Option(Int)) -> remote_agent.RemoteAgent {
  remote_agent.RemoteAgent(
    id: child,
    parent: "main",
    orchestrator: "box",
    standing: remote_agent.Running,
    title: "build the release",
    summary: "compiling the tests",
    tokens: 12_400,
    model: "fast",
    age_ms:,
  )
}

// A model whose session lists `main` and, from the daemon's list, one child
// running on `box`.
fn with_remote(age_ms: option.Option(Int)) -> tui_model.Model {
  let base =
    tui.new_model_with_clock(
      connection.new_inbox(),
      workspace.Context("/work", None),
      fn() { 0 },
    )
  let shared =
    shared_set.strands(base.shared, [
      protocol.Strand("main", Some("main"), None),
    ])
  let shared =
    shared_set.roster(
      shared,
      agent_roster.observe_remote(shared.roster, [agent(age_ms)], 0),
    )
  tui_model.Model(..base, shared:)
}

fn painted(model: tui_model.Model, width: Int, height: Int) -> String {
  let model = tui.update(backend.Resize(width, height), model)
  let #(buffer, _) = render.view(model, geometry.rect_new(0, 0, width, height))
  frame.buffer_to_text(buffer)
}

pub fn a_remote_child_is_listed_with_where_it_runs_test() {
  let text = painted(with_remote(Some(2000)), 120, 30)
  assert string.contains(text, "build @ box")
  assert string.contains(text, "compiling the tests")
  assert string.contains(text, "12k ctx")

  // A fresh glance says nothing about its age.
  assert !string.contains(text, "seen ")
}

// While the parent's daemon cannot reach the orchestrator no glance arrives,
// and the strip says how long the one it shows has been unchanged.
pub fn a_silent_remote_child_says_how_old_its_glance_is_test() {
  let text = painted(with_remote(Some(125_000)), 120, 30)
  assert string.contains(text, "seen 2m 05s ago · compiling the tests")
}

// Choosing the remote row asks for its transcript and leaves the strand on
// screen where it was, since there is no strand here to switch to.
pub fn opening_a_remote_child_peeks_at_its_transcript_test() {
  let model =
    tui.update(backend.Resize(120, 30), with_remote(Some(1000)))
    |> tui.update(backend.KeyPress("down"), _)
  assert model.view.strip_focus == Browsing(child)
  let opened = tui.update(backend.KeyPress("enter"), model)
  assert opened.shared.active_strand == "main"
  let assert remote_transcript.Loading(child: peeked, orchestrator: "box", ..) =
    opened.shared.peek
    as "the peek is open and waiting for its page"
  assert peeked == child
}

// The page is drawn as text under the harness's framing: the angle brackets a
// model wrote are on screen as characters, and nothing is rendered from them.
pub fn a_peek_draws_its_page_as_plain_text_test() {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(at: 0), seed: 3))
  let said =
    entry.MessageEntry(
      id:,
      parent: None,
      seq: 4,
      ts: 0,
      message: message.UserMessage(
        content: [
          message.UserText(
            text: "<b>bold</b> **not bold**",
            text_signature: None,
          ),
        ],
        timestamp: 0,
        origin: None,
      ),
      terminate: False,
    )
  let page =
    remote_transcript.Page(child:, entries: [said], omitted: 0, next: None)
  let base = with_remote(Some(1000))
  let model =
    tui_model.Model(
      ..base,
      shared: session_model.Shared(
        ..base.shared,
        peek: remote_transcript.Shown(child, "box", page),
      ),
    )
  let text = painted(model, 120, 40)
  assert string.contains(text, "[transcript of sub:^main/build-1a2b3c on box]")
  assert string.contains(text, "asked: <b>bold</b> **not bold**")
  assert string.contains(text, "[end transcript.")
  assert string.contains(text, "/peek close")
}

// `/peek` takes a child's name, and `/peek close` closes it.
pub fn the_peek_command_parses_test() {
  assert command.parse("/peek build") == command.Session(command.Peek("build"))
  assert command.parse("/peek close") == command.Session(command.PeekClose)
}
