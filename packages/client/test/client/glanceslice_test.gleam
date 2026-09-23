//// The glance request: what a strand's branch reduces to, how large the
//// request may get, and which answers are read back.
////
//// Every test here is pure. The entries are built in memory, because
//// `gather` reads nothing but the list it is handed, and the answers are
//// strings a model could plausibly send.

import client/glanceslice.{Reply, Titled, Untitled}
import core/clock
import core/entry.{type Entry}
import core/glance
import core/ids.{type EntryId}
import core/json
import core/message
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import runtime/effects

// --- gathering -----------------------------------------------------------------

// The branch arrives newest first and the request reads oldest first, so
// the calls come out in the order the agent made them.
pub fn calls_are_listed_oldest_first_test() {
  let recent = [
    an_assistant(3, [a_call("edit", "{\"path\":\"b.go\"}")]),
    a_result(2),
    an_assistant(1, [a_call("read", "{\"path\":\"a.go\"}")]),
  ]
  let material = glanceslice.gather(prompts: [], recent:, title: Untitled)

  assert material.calls
    == ["read {\"path\":\"a.go\"}", "edit {\"path\":\"b.go\"}"]
}

// One message may carry several calls; they keep their source order.
pub fn calls_in_one_message_keep_their_order_test() {
  let recent = [
    an_assistant(1, [a_call("first", "{}"), a_call("second", "{}")]),
  ]
  let material = glanceslice.gather(prompts: [], recent:, title: Untitled)

  assert material.calls == ["first {}", "second {}"]
}

// Only the newest calls are kept, and each is bounded, so a long operation
// costs the same request as a short one.
pub fn calls_are_capped_and_bounded_test() {
  let long = "{\"path\":\"" <> string.repeat("x", 1000) <> "\"}"
  let recent =
    newest_first(20)
    |> list.map(fn(seq) {
      an_assistant(seq, [a_call("call" <> string.inspect(seq), long)])
    })
  let material = glanceslice.gather(prompts: [], recent:, title: Untitled)

  assert list.length(material.calls) == glanceslice.max_calls
  let assert Ok(first) = list.first(material.calls)
  assert string.starts_with(first, "call13 ")
  assert list.all(material.calls, fn(call) {
    string.byte_size(call) <= glanceslice.max_call_bytes
  })
}

// The latest thing the agent said is the newest assistant text, and
// thinking never counts as something it said.
pub fn said_is_the_newest_visible_text_test() {
  let recent = [
    an_assistant(3, [message.AssistantThinking("secret plan", None, False)]),
    an_assistant(2, [message.AssistantText("Now checking the lexer.", None)]),
    an_assistant(1, [message.AssistantText("Starting out.", None)]),
  ]
  let material = glanceslice.gather(prompts: [], recent:, title: Untitled)

  assert material.said == "Now checking the lexer."
  assert !string.contains(glanceslice.request(material), "secret plan")
}

// The prompt is the accepted user text, bounded.
pub fn the_prompt_is_bounded_test() {
  let prompts = [
    a_user(1, string.repeat("audit the channel funding flow ", 200)),
  ]
  let material = glanceslice.gather(prompts:, recent: [], title: Untitled)

  assert string.byte_size(material.prompt) <= glanceslice.max_prompt_bytes
  assert string.starts_with(material.prompt, "audit the channel funding flow")
}

// The whole request stays near four kilobytes however large its material,
// which is the property that makes a refresh every twenty seconds cheap.
pub fn the_request_stays_near_four_kilobytes_test() {
  let huge = string.repeat("lorem ipsum ", 2000)
  let recent =
    newest_first(40)
    |> list.map(fn(seq) {
      an_assistant(seq, [
        message.AssistantText(huge, None),
        a_call("run", "{\"command\":\"" <> huge <> "\"}"),
      ])
    })
  let material =
    glanceslice.gather(prompts: [a_user(0, huge)], recent:, title: Untitled)

  assert string.byte_size(glanceslice.request(material)) <= 4500
}

// A first request asks for both lines; a later one names the title it
// already has and asks for the "now" line alone.
pub fn the_title_is_asked_for_once_test() {
  let first =
    glanceslice.request(glanceslice.Material("Fix it", [], "", Untitled))
  let later =
    glanceslice.request(glanceslice.Material(
      "Fix it",
      [],
      "",
      Titled("Fix the parser"),
    ))

  assert string.contains(first, "TITLE:")
  assert string.contains(first, "NOW:")
  assert !string.contains(later, "TITLE:")
  assert string.contains(later, "\"Fix the parser\"")
  assert string.contains(later, "NOW:")
}

// --- parsing -------------------------------------------------------------------

pub fn a_plain_answer_parses_test() {
  assert glanceslice.parse(
      "TITLE: Audit funding and peer routing panics\nNOW: Reading fundeeProcessOpenChannel in manager.go",
      Untitled,
    )
    == Ok(Reply(
      "Audit funding and peer routing panics",
      "Reading fundeeProcessOpenChannel in manager.go",
    ))
}

// Cheap models dress their answers up; the markup and a trailing period
// are removed rather than refused.
pub fn a_decorated_answer_parses_test() {
  assert glanceslice.parse(
      "Sure!\n**Title:** \"Fix the parser\"\n- now: `Reading lexer.go`.\n",
      Untitled,
    )
    == Ok(Reply("Fix the parser", "Reading lexer.go"))
}

// A later request keeps its stored title whatever the answer says.
pub fn a_titled_answer_keeps_the_stored_title_test() {
  assert glanceslice.parse(
      "TITLE: Something else\nNOW: Running the tests",
      Titled("Fix the parser"),
    )
    == Ok(Reply("Fix the parser", "Running the tests"))
}

// An answer missing a line it was asked for is unusable, so the loop keeps
// the old cell rather than writing half a glance.
pub fn a_missing_line_is_unusable_test() {
  assert glanceslice.parse("TITLE: Fix the parser", Untitled) == Error(Nil)
  assert glanceslice.parse("NOW: Reading lexer.go", Untitled) == Error(Nil)
  assert glanceslice.parse("TITLE: Fix the parser", Titled("x")) == Error(Nil)
}

pub fn garbage_is_unusable_test() {
  assert glanceslice.parse("", Untitled) == Error(Nil)
  assert glanceslice.parse("I cannot help with that.", Untitled) == Error(Nil)
  assert glanceslice.parse("TITLE:\nNOW:   ", Untitled) == Error(Nil)
  assert glanceslice.parse("TITLE: **\nNOW: \"\"", Untitled) == Error(Nil)
  assert glanceslice.parse("NOWHERE: a place", Titled("x")) == Error(Nil)
}

// A label with nothing after it does not stop the search: a later line
// carrying the label with a value is still found.
pub fn an_empty_label_keeps_looking_test() {
  assert glanceslice.parse("NOW:\nNOW: Reading lexer.go", Titled("x"))
    == Ok(Reply("x", "Reading lexer.go"))
}

// A rambling answer is clipped to the cell's bounds rather than refused,
// and a multi-line value cannot happen because each line is read alone.
pub fn long_answers_are_clipped_to_the_cell_test() {
  let long = string.repeat("very ", 100)
  let assert Ok(reply) =
    glanceslice.parse("TITLE: " <> long <> "\nNOW: " <> long, Untitled)
    as "an over-long answer must still parse"

  assert string.byte_size(reply.title) <= glance.max_title_bytes
  assert string.byte_size(reply.summary) <= glance.max_summary_bytes
  assert !string.contains(reply.summary, "\n")
}

// --- fixtures ------------------------------------------------------------------

// Seqs `count` down to one, the order a branch scan hands back.
fn newest_first(count: Int) -> List(Int) {
  int.range(from: 1, to: count + 1, with: [], run: list.prepend)
}

fn an_assistant(seq: Int, content: List(message.AssistantBlock)) -> Entry {
  a_message(
    seq,
    message.AssistantMessage(
      content:,
      api: "test",
      provider: "test",
      model: "test",
      response_model: None,
      response_id: None,
      diagnostics: None,
      usage: effects.zero_usage(),
      stop_reason: message.ToolUse,
      deferred: None,
      error_message: None,
      raw_stop_reason: None,
      end_turn: None,
      timestamp: seq,
    ),
  )
}

fn a_user(seq: Int, text: String) -> Entry {
  a_message(
    seq,
    message.UserMessage(
      content: [message.UserText(text, None)],
      timestamp: seq,
      origin: None,
    ),
  )
}

fn a_result(seq: Int) -> Entry {
  a_message(
    seq,
    message.ToolResultMessage(
      tool_call_id: "c1",
      tool_name: "read",
      content: [message.ToolResultText("package main", None)],
      details: None,
      usage: None,
      added_tool_names: None,
      is_error: False,
      timestamp: seq,
    ),
  )
}

fn a_call(name: String, arguments: String) -> message.AssistantBlock {
  let assert Ok(parsed) = json.parse(arguments)
    as "fixture arguments must be JSON"
  message.AssistantToolCall(message.ToolCall(
    id: name,
    name:,
    arguments: parsed,
    thought_signature: None,
    namespace: None,
  ))
}

fn a_message(seq: Int, settled: message.AgentMessage) -> Entry {
  entry.MessageEntry(
    id: an_id(seq),
    parent: None,
    seq:,
    ts: seq,
    message: settled,
    terminate: False,
  )
}

fn an_id(seed: Int) -> EntryId {
  let #(id, _generator) = ids.mint_entry(ids.generator(clock.fixed(1), seed))
  id
}
