//// A child that runs on another orchestrator has a card named
//// `<child> @ <orchestrator>`, and focusing it opens a peek at its transcript
//// in the Strands tab (protocol-change/090). The peek is drawn as text nodes
//// under the harness's framing, so markup in a model's words reaches the page
//// escaped, as the characters it is.

import core/clock
import core/entry
import core/ids
import core/json
import core/message
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lustre/element
import page_fixture
import session_view/agent_roster
import session_view/agent_view
import session_view/connection_event
import session_view/remote_agent
import session_view/remote_transcript
import session_view/turns
import web_view/component
import web_view/view/peek
import web_view/view/strip

const child = "sub:^main/build-1a2b3c"

const markup = "<b>bold</b><script>alert(1)</script>"

fn agent() -> remote_agent.RemoteAgent {
  remote_agent.RemoteAgent(
    id: child,
    parent: "main",
    orchestrator: "box",
    standing: remote_agent.Running,
    title: "build the release",
    summary: "compiling the tests",
    tokens: 900,
    model: "fast",
    age_ms: Some(1000),
    commits: None,
    returned_ref: None,
  )
}

fn page() -> remote_transcript.Page {
  let #(id, _) = ids.mint_entry(ids.generator(clock.fixed(at: 0), seed: 5))
  let said =
    entry.MessageEntry(
      id:,
      parent: None,
      seq: 3,
      ts: 0,
      message: message.UserMessage(
        content: [message.UserText(text: markup, text_signature: None)],
        timestamp: 0,
        origin: None,
      ),
      terminate: False,
    )
  remote_transcript.Page(child:, entries: [said], omitted: 0, next: None)
}

// The daemon's push of the session's remote children, as the wire carries it.
fn remote_children(
  child: remote_agent.RemoteAgent,
) -> connection_event.Message {
  pushed([remote_agent.encode(child)])
}

// The same push for entries already on the wire, so a test can damage one.
fn pushed(entries: List(json.JsonValue)) -> connection_event.Message {
  connection_event.Incoming(
    json.to_string(
      json.Object([
        #("v", json.Int(2)),
        #("event", json.String("snapshot")),
        #(
          "body",
          json.Object([
            #("mode", json.String("remote_children")),
            #("remote_children", json.Array(entries)),
          ]),
        ),
      ]),
    ),
  )
}

// The observation board for request `id`, with `status` and, when ready, the
// page's fields, correlated to the request or pushed.
fn history_board(
  id: Int,
  status: String,
  reply: option.Option(Int),
) -> connection_event.Message {
  let page_fields = case status {
    "ready" -> {
      let assert json.Object(fields) = remote_transcript.encode(page())
      fields
    }
    _ -> []
  }
  let board =
    json.Object([
      #("status", json.String(status)),
      #("request_id", json.Int(id)),
      ..page_fields
    ])
  let envelope = [
    #("v", json.Int(2)),
    #("event", json.String("snapshot")),
    #(
      "body",
      json.Object([
        #("mode", json.String("child_history")),
        #("board", board),
      ]),
    ),
  ]
  let envelope = case reply {
    Some(id) -> [#("reply_to", json.Int(id)), ..envelope]
    None -> envelope
  }
  connection_event.Incoming(json.to_string(json.Object(envelope)))
}

pub fn a_remote_card_names_where_the_child_runs_test() {
  let line =
    agent_roster.describe(
      agent_roster.observe_remote(agent_roster.new(), [agent()], 0),
      agent_roster.remote_row(agent()),
    )
  let drawn =
    element.to_string(
      strip.view(
        strip.Strip(
          chips: [
            strip.Chip(
              line:,
              hue: turns.Sub(0),
              cache: None,
              running_ms: None,
              model: "",
              own_model: None,
              recent: [],
              answer: None,
            ),
          ],
          advisor: None,
          settled: [],
          earlier: 0,
          followed: "main",
        ),
        fn(name) { name },
      ),
    )
  assert string.contains(drawn, "build @ box")
  assert line.status == agent_view.Working
}

// Every word of the page is a text node: the tags a model wrote are escaped,
// and the harness's framing is drawn around them.
pub fn a_peek_draws_its_page_as_text_test() {
  let assert Some(view) =
    peek.view(remote_transcript.Shown(child, "box", page()))
  let drawn = element.to_string(view)
  assert string.contains(drawn, "[transcript of " <> child <> " on box]")
  assert string.contains(
    drawn,
    "&lt;b&gt;bold&lt;/b&gt;&lt;script&gt;alert(1)&lt;/script&gt;",
  )
  assert !string.contains(drawn, "<b>bold")
  assert !string.contains(drawn, "<script>")
  assert string.contains(drawn, "[end transcript.")
  assert peek.view(remote_transcript.Closed) == None
}

// The page lists the remote child the daemon pushed; focusing its card sends
// a `child_history` read and leaves `main` on screen; the page that comes back
// is drawn in the Strands tab, escaped.
pub fn focusing_a_remote_card_opens_its_transcript_test() {
  let wire = process.new_subject()
  let model =
    page_fixture.ready(wire, "observer")
    |> page_fixture.run(component.update, [
      component.Arrived([remote_children(agent())]),
      component.Ticked,
    ])
  assert string.contains(
    element.to_string(component.view(model)),
    "build @ box",
  )

  let focused =
    page_fixture.run(model, component.update, [component.FocusRequested(child)])
  assert component.strand(focused) == component.primary
  let assert [read] =
    page_fixture.sent(wire)
    |> page_fixture.commands
    |> list.filter(string.contains(_, "\"cmd\":\"child_history\""))
    as "the focus sends one transcript read"
  assert string.contains(read, child)
  let id = page_fixture.request_id(read)

  let shown =
    page_fixture.run(focused, component.update, [
      component.Arrived([history_board(id, "pending", Some(id))]),
      component.Arrived([history_board(id, "ready", None)]),
      component.Ticked,
    ])
  let drawn = element.to_string(component.view(shown))
  assert string.contains(drawn, "[transcript of " <> child <> " on box]")
  assert string.contains(drawn, "&lt;script&gt;alert(1)&lt;/script&gt;")
  assert !string.contains(drawn, "<script>alert")

  // Focusing `main`, which is what the peek's back link does, closes it.
  let back =
    page_fixture.run(shown, component.update, [
      component.FocusRequested(component.primary),
    ])
  assert !string.contains(
    element.to_string(component.view(back)),
    "[transcript of",
  )
}

// A refusal replaces an older progress snapshot. Its reason must be visible
// as escaped, single-line text in the real component's card.
pub fn a_refused_remote_card_shows_its_reason_as_text_test() {
  let wire = process.new_subject()
  let refused =
    remote_agent.RemoteAgent(
      ..agent(),
      standing: remote_agent.Refused,
      summary: "denied <script>alert(1)</script>\u{1b}[31m",
    )
  let model =
    page_fixture.ready(wire, "observer")
    |> page_fixture.run(component.update, [
      component.Arrived([remote_children(agent())]),
      component.Ticked,
      component.Arrived([remote_children(refused)]),
      component.Ticked,
    ])
  let drawn = element.to_string(component.view(model))
  assert string.contains(
    drawn,
    "Failed · denied &lt;script&gt;alert(1)&lt;/script&gt;",
  )
  assert !string.contains(drawn, "compiling the tests")
  assert !string.contains(drawn, "<script>")
  assert !string.contains(drawn, "\u{1b}")
}

// The page as the daemon's push of `child` draws it.
fn page_of(child: remote_agent.RemoteAgent) -> String {
  let wire = process.new_subject()
  page_fixture.ready(wire, "observer")
  |> page_fixture.run(component.update, [
    component.Arrived([remote_children(child)]),
    component.Ticked,
  ])
  |> component.view
  |> element.to_string
}

// A child whose commits came back to the parent's repository says how many and
// where they are, through the real wire decoder and page reducer. The ref is a
// name a remote orchestrator chose, so markup in it reaches the page escaped,
// as a text node and as the tooltip, and nothing else of it is an attribute.
pub fn a_card_names_the_commits_that_came_back_and_their_ref_test() {
  let ref = "refs/loom/children/build-1a2b/0123abcd<script>alert(1)</script>"
  let drawn =
    page_of(
      remote_agent.RemoteAgent(
        ..agent(),
        standing: remote_agent.Completed,
        summary: "",
        commits: Some(3),
        returned_ref: Some(ref),
      ),
    )
  assert string.contains(drawn, "3 commits returned")
  assert string.contains(
    drawn,
    "<span class=\"chip-model\" title=\"refs/loom/children/build-1a2b/0123abcd&lt;script&gt;alert(1)&lt;/script&gt;\">refs/loom/children/build-1a2b/0123abcd&lt;script&gt;alert(1)&lt;/script&gt;</span>",
  )
  assert !string.contains(drawn, "<script>")
}

pub fn one_returned_commit_is_singular_test() {
  let drawn =
    page_of(
      remote_agent.RemoteAgent(
        ..agent(),
        commits: Some(1),
        returned_ref: Some("refs/loom/children/build-1a2b/0123abcd"),
      ),
    )
  assert string.contains(drawn, "1 commit returned")
  assert !string.contains(drawn, "1 commits returned")
}

// A child that returned nothing, or whose pair is incomplete on the wire, is
// drawn exactly as it was before the members existed: no count, no ref.
pub fn a_card_without_returned_work_draws_neither_line_test() {
  let drawn = page_of(agent())
  assert string.contains(drawn, "build @ box")
  assert !string.contains(drawn, "returned")
  assert !string.contains(drawn, "refs/loom")

  // The count alone is not a pair, so the decoder drops it and the card
  // shows nothing of it.
  let assert json.Object(members) = remote_agent.encode(agent())
  let half = json.Object(list.key_set(members, "commits", json.Int(4)))
  let wire = process.new_subject()
  let model =
    page_fixture.ready(wire, "observer")
    |> page_fixture.run(component.update, [
      component.Arrived([pushed([half])]),
      component.Ticked,
    ])
  let drawn = element.to_string(component.view(model))
  assert string.contains(drawn, "build @ box")
  assert !string.contains(drawn, "returned")
}
