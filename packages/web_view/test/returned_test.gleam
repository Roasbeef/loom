//// A prompt the daemon hands back unsent (protocol-change/038) is kept for
//// the composer instead of dropped.
////
//// The daemon holds a queued prompt only in memory, so its push of the
//// returned text is the prompt's last copy. The shared step keeps it until
//// the next step forgets it, and the page used to be the host that forgot it.
//// The page now takes it out of the record at the end of each message, keeps
//// it for `<loom-composer>` to put in the editor, and says what came back.
//// The element alone knows whether the operator has typed in the editor since
//// (that is client code, checked in a browser), so what is held here is the
//// count, the prompts and the notice.

import gleam/erlang/process
import gleam/list
import gleam/string
import lustre/element
import page_fixture
import session_view/connection_event
import web_view/component
import web_view/operator_page

fn page() {
  page_fixture.ready(process.new_subject(), "operator")
}

// The daemon's push, as it arrives on the socket: the body names the strand
// whose queue held the prompt, its own identity for the item, and the text.
fn returned(strand: String, text: String) -> connection_event.Message {
  connection_event.Incoming(
    "{\"v\":2,\"event\":\"held_input_returned\",\"body\":{\"strand\":\""
    <> strand
    <> "\",\"id\":\"h1\",\"kind\":\"queue\",\"text\":\""
    <> text
    <> "\",\"attachment_count\":0}}",
  )
}

fn arrive(model, messages: List(connection_event.Message)) {
  page_fixture.run(model, component.update, [component.Arrived(messages)])
}

pub fn a_returned_prompt_is_kept_for_the_composer_test() {
  let model = arrive(page(), [returned("main", "deploy when green")])
  assert component.returns(model) == 1
  assert component.returned(model)
    == [component.Returned(number: 1, text: "deploy when green")]
}

// Which prompts came back, and that they are in the composer, is said in
// words that name the strand and the count.
pub fn the_notice_names_the_strand_and_the_count_test() {
  let model = arrive(page(), [returned("main", "one"), returned("main", "two")])
  assert component.notice(model)
    == component.Said(
      "The daemon handed back 2 prompts held for main, put back in the composer.",
    )
}

// The editor is not replaced: what the operator is typing stays, which is why
// the element decides where the returned text goes.
pub fn a_return_does_not_replace_the_editor_test() {
  let before = page()
  let after = arrive(before, [returned("main", "deploy when green")])
  assert component.drafts(after) == component.drafts(before)
}

// The view carries the count on the element and each prompt as a text-node
// child in the slot the element reads, numbered, after the textarea.
pub fn the_view_carries_the_count_and_the_prompts_test() {
  let model = arrive(page(), [returned("main", "deploy when green")])
  let html = element.to_string(operator_page.view(model))
  assert string.contains(html, "returned=\"1\"")
  let assert Ok(#(before_slot, after_slot)) =
    string.split_once(html, "slot=\"returned\"")
    as "the prompt is drawn in the returned slot"
  assert string.contains(html, "data-n=\"1\"")
  assert string.contains(after_slot, ">deploy when green</span>")
  assert string.contains(before_slot, "<textarea")
}

// The returned text is what the operator typed, but it reaches the page from
// the daemon, and it is drawn as text like any other session content.
pub fn a_returned_prompt_is_drawn_as_text_test() {
  let model = arrive(page(), [returned("main", "<b>bold</b>")])
  let html = element.to_string(operator_page.view(model))
  assert string.contains(html, "&lt;b&gt;bold&lt;/b&gt;")
  assert !string.contains(html, "<b>")
}

pub fn a_page_that_has_had_no_return_says_zero_test() {
  let html = element.to_string(operator_page.view(page()))
  assert string.contains(html, "returned=\"0\"")
  assert !string.contains(html, "slot=\"returned\"")
}

// A drain returns every held prompt at once, and the element takes them in a
// frame that does not run in a background tab, so none may be dropped: all of
// them are kept, in one message and across two before any is taken.
pub fn every_return_is_kept_test() {
  let texts = ["a", "b", "c", "d", "e", "f"]
  let model =
    arrive(page(), list.map(texts, fn(text) { returned("main", text) }))
  let model = arrive(model, [returned("main", "g"), returned("main", "h")])
  assert component.returns(model) == 8
  assert component.returned(model)
    == list.index_map(["a", "b", "c", "d", "e", "f", "g", "h"], fn(text, index) {
      component.Returned(index + 1, text)
    })
}

// A return in a later message is numbered after the earlier ones.
pub fn returns_are_numbered_across_messages_test() {
  let model = arrive(page(), [returned("main", "first")])
  let model = arrive(model, [returned("main", "second")])
  assert component.returned(model)
    == [component.Returned(1, "first"), component.Returned(2, "second")]
}

// The page has one editor, which addresses the strand on screen. A prompt held
// for another strand of the session is still the prompt's last copy, so it is
// put in that editor, and the notice names the strand it was held for and the
// strand the composer addresses, so the operator sees the difference before
// pressing Send.
pub fn a_prompt_for_another_strand_is_kept_and_named_test() {
  let model = arrive(page(), [returned("advisor", "not for main")])
  assert component.returns(model) == 1
  assert component.returned(model) == [component.Returned(1, "not for main")]
  let assert component.Said(text) = component.notice(model)
    as "the return is said"
  assert string.contains(
    text,
    "1 prompt held for advisor (you are addressing main)",
  )
}

// A prompt returned for a strand the page is showing is named by that strand
// alone.
pub fn a_prompt_for_the_shown_strand_is_named_plainly_test() {
  let model = arrive(page(), [returned("main", "for main")])
  let assert component.Said(text) = component.notice(model)
    as "the return is said"
  assert string.contains(text, "1 prompt held for main, put back")
  assert !string.contains(text, "you are addressing")
}
