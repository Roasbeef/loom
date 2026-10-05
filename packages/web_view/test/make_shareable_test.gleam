//// Making a private session shareable from the session page (protocol-change/065,
//// the addendum on making a session shareable).
////
//// What these tests read is what the owner's page draws and asks. A private
//// session draws one sentence and a button; the button asks a question in its
//// place and changes nothing else; only the question's confirm reaches the
//// transport, once; and the daemon's answer either draws the invitation buttons
//// or says why in fixed words. A page whose transport has no capability draws no
//// button and asks nothing whatever message reaches it.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lane_fixture
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import web_view/component
import web_view/creations
import web_view/grants
import web_view/invites
import web_view/operator_page
import web_view/shareables

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

// How the transport answers: not at all (the task is still running), or with an
// answer delivered at once.
type Answering {
  Silent
  With(grants.Answer)
}

// An owner's page on a session of `sharing`, whose transport reports each time
// the task is asked for and answers as `answering` says. `None` is a page with
// no capability.
fn page(
  sharing: creations.Sharing,
  capability: Option(Answering),
  asked: Subject(Nil),
) -> component.Model(page_fixture.Wire) {
  let start = page_fixture.start()
  component.Start(
    ..start,
    standing: component.Standing(
      reader: component.DaemonOwner,
      sharing: Some(sharing),
      opening: component.FromLink,
    ),
    transport: component.Transport(
      ..start.transport,
      invite: Some(fn(_) { invites.Declined(invites.NotIsolated) }),
      shareable: option.map(capability, fn(answering) {
        fn(deliver) {
          process.send(asked, Nil)
          case answering {
            Silent -> Nil
            With(answer) -> deliver(answer)
          }
        }
      }),
    ),
  )
  |> component.new
  |> component.apply([lane_fixture.captured(10, None)])
}

fn deliver(
  model: component.Model(page_fixture.Wire),
  message: operator_page.Msg(page_fixture.Wire),
) -> component.Model(page_fixture.Wire) {
  let #(model, effects) = operator_page.update(model, message)
  let dispatched = process.new_subject()
  effect.perform(
    effects,
    fn(next) { process.send(dispatched, next) },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  case process.receive(dispatched, 0) {
    Ok(next) -> deliver(model, next)
    Error(Nil) -> model
  }
}

fn drawn(model: component.Model(page_fixture.Wire)) -> String {
  element.to_string(operator_page.view(model))
}

// The click handlers at or beneath the invitation control's path.
fn region_clicks(model: component.Model(page_fixture.Wire)) -> Int {
  handlers(operator_page.view(model))
  |> list.filter(fn(key) {
    string.starts_with(key, component.invite_path <> "\t")
    && string.ends_with(key, "\nclick")
  })
  |> list.length
}

fn asks(asked: Subject(Nil)) -> Int {
  case process.receive(asked, 0) {
    Ok(Nil) -> 1 + asks(asked)
    Error(Nil) -> 0
  }
}

// A private session on an owner's page draws the admin page's sentence and one
// button, in the place the invitation buttons would be: exactly one handler
// beneath the invite path, and no invitation button.
pub fn a_private_session_offers_one_button_test() {
  let model = page(creations.Private, Some(Silent), process.new_subject())
  assert component.moving(model) == shareables.Idle
  let html = drawn(model)
  assert string.contains(html, "Private session: it shares the workspace")
  assert string.contains(html, ">Make shareable<")
  assert !string.contains(html, "Invite an observer")
  assert region_clicks(model) == 1
}

// A page with no capability draws no button, and the messages that would ask
// reach nothing: not the daemon and not the model.
pub fn a_page_without_the_capability_draws_and_asks_nothing_test() {
  let asked = process.new_subject()
  let model = page(creations.Private, None, asked)
  assert component.moving(model) == shareables.Withheld
  assert !string.contains(drawn(model), "Make shareable")
  assert region_clicks(model) == 0
  let model = deliver(model, operator_page.AskingShareable)
  let model = deliver(model, operator_page.MakingShareable)
  assert component.moving(model) == shareables.Withheld
  assert asks(asked) == 0
}

// A session that can be shared draws the invitation buttons and no make
// button, and a press that names the make message does nothing.
pub fn a_shareable_session_is_offered_no_button_test() {
  let asked = process.new_subject()
  let model = page(creations.Shareable, Some(Silent), asked)
  assert component.moving(model) == shareables.Withheld
  assert string.contains(drawn(model), "Invite an observer")
  assert !string.contains(drawn(model), "Make shareable")
  let model = deliver(model, operator_page.AskingShareable)
  let _ = deliver(model, operator_page.MakingShareable)
  assert asks(asked) == 0
}

// The confirm guard: the daemon is asked only from the question. A confirm sent
// before the button's first press, or twice, asks nothing more than once.
pub fn only_the_questions_confirm_reaches_the_daemon_test() {
  let asked = process.new_subject()
  let model = page(creations.Private, Some(Silent), asked)

  // A confirm with no question open is ignored.
  let model = deliver(model, operator_page.MakingShareable)
  assert component.moving(model) == shareables.Idle
  assert asks(asked) == 0

  // The first press asks the question in place and changes nothing else.
  let model = deliver(model, operator_page.AskingShareable)
  assert component.moving(model) == shareables.Confirming
  let html = drawn(model)
  assert string.contains(
    html,
    "Make this session shareable? It will stop, move to its own history, and resume.",
  )
  assert region_clicks(model) == 2
  assert asks(asked) == 0

  // Cancel puts the button back and still asks nothing.
  let cancelled = deliver(model, operator_page.CancellingShareable)
  assert component.moving(cancelled) == shareables.Idle
  assert asks(asked) == 0

  // The confirm asks once; a second confirm while the task runs asks nothing.
  let running = deliver(model, operator_page.MakingShareable)
  assert component.moving(running) == shareables.Making
  assert asks(asked) == 1
  let again = deliver(running, operator_page.MakingShareable)
  let again = deliver(again, operator_page.AskingShareable)
  assert component.moving(again) == shareables.Making
  assert asks(asked) == 0
}

// While the task runs the button is gone, a disabled one stands in its place,
// and the sentence says what is happening and that this page ends with the stop.
pub fn a_running_task_is_worded_and_disabled_test() {
  let model = page(creations.Private, Some(Silent), process.new_subject())
  let model = deliver(model, operator_page.AskingShareable)
  let model = deliver(model, operator_page.MakingShareable)
  let html = drawn(model)
  assert string.contains(html, "Making this session shareable")
  assert string.contains(html, "This page ends while it restarts")
  assert string.contains(html, "disabled")
  assert region_clicks(model) == 0
}

// A refusal is worded in the reason's fixed words, the button comes back, and a
// second try goes through the question again.
pub fn a_refusal_is_worded_and_can_be_tried_again_test() {
  let asked = process.new_subject()
  let model =
    page(creations.Private, Some(With(grants.Declined(grants.NotMoved))), asked)
  let model = deliver(model, operator_page.AskingShareable)
  let model = deliver(model, operator_page.MakingShareable)
  assert component.moving(model) == shareables.Refused(grants.NotMoved)
  let html = drawn(model)
  assert string.contains(
    html,
    "The session could not be made shareable and is still private.",
  )
  assert string.contains(html, ">Make shareable<")
  assert asks(asked) == 1

  // Another confirm without the question is still ignored.
  let model = deliver(model, operator_page.MakingShareable)
  assert asks(asked) == 0
  let model = deliver(model, operator_page.AskingShareable)
  assert component.moving(model) == shareables.Confirming
}

// An answer that arrives for a task nobody asked for is dropped.
pub fn an_unasked_answer_changes_nothing_test() {
  let model = page(creations.Private, Some(Silent), process.new_subject())
  let #(model, _) =
    component.update(
      model,
      component.MadeShareable(grants.Declined(grants.Stranded)),
    )
  assert component.moving(model) == shareables.Idle
  let #(model, _) =
    component.update(model, component.MadeShareable(grants.Changed))
  assert component.moving(model) == shareables.Idle
  assert component.share(model) == invites.Unshareable
}

// A page that is still open when the daemon says the session is shareable draws
// the invitation buttons.
pub fn a_done_task_draws_the_invitation_buttons_test() {
  let model =
    page(creations.Private, Some(With(grants.Changed)), process.new_subject())
  let model = deliver(model, operator_page.AskingShareable)
  let model = deliver(model, operator_page.MakingShareable)
  assert component.share(model) == invites.Ready
  let html = drawn(model)
  assert string.contains(html, "Invite an observer")
  assert !string.contains(html, "Make shareable")
}

// An owner's page that a bookmark opened is handed neither capability, which the
// daemon decides and the page only draws: no button of either control, one quiet
// sentence that says why and how to get a page that can, and nothing the browser
// can press in the region. A private session keeps its own sentence.
pub fn a_bookmarks_page_draws_a_sentence_and_no_button_test() {
  let bookmarked = fn(sharing) {
    let start = page_fixture.start()
    component.Start(
      ..start,
      standing: component.Standing(
        reader: component.DaemonOwner,
        sharing: Some(sharing),
        opening: component.FromBookmark,
      ),
    )
    |> component.new
    |> component.apply([lane_fixture.captured(10, None)])
  }

  let private = bookmarked(creations.Private)
  assert component.share(private) == invites.BookmarkedPrivate
  let html = drawn(private)
  assert string.contains(html, "Private session: it shares the workspace")
  assert string.contains(
    html,
    "This page was opened from a bookmark, so it cannot invite people or make a session shareable. Run loom ui for a page that can.",
  )
  assert !string.contains(html, "Make shareable")
  assert !string.contains(html, "Invite an observer")
  assert region_clicks(private) == 0

  let shareable = bookmarked(creations.Shareable)
  assert component.share(shareable) == invites.Bookmarked
  assert string.contains(drawn(shareable), "opened from a bookmark")
  assert !string.contains(drawn(shareable), "Private session")
  assert region_clicks(shareable) == 0

  // No press reaches the daemon, since the page has no capability.
  let #(same, _) = component.invite(shareable, invites.Observer)
  assert component.share(same) == invites.Bookmarked
}
