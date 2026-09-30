//// Inviting from an owner's page (protocol-change/051, the addendum on
//// inviting from the session page).
////
//// What these tests read is what the page draws and asks. An owner's page has
//// the control in the Session pane, two buttons at fixed paths beneath
//// `component.invite_path`; a press sends the role its button names to the
//// transport, once; the daemon's answer becomes the invitation, with the
//// command and the token each in a copy box; and hiding it drops the state
//// that held the token. A page whose transport has no capability draws no
//// control and asks nothing whatever message reaches it, and the observer's
//// page draws none even when its transport has one.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import lane_fixture
import lustre/effect
import lustre/element.{type Element}
import page_fixture
import web_view/component
import web_view/invites
import web_view/operator_page

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

const token =
  "loomclaim_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

fn invitation(role: invites.Role) -> invites.Invitation {
  invites.Invitation(
    principal: "guest-1a2b3c4d",
    role:,
    command: "loom claim --addr ws://127.0.0.1:4000/v2/control",
    token:,
    expires_in_ms: invites.claim_ttl_ms,
  )
}

// A page on session `A` with a capture, whose transport answers every request
// to invite with `answer` and reports the role it was asked for. `None` is a
// page that has no capability.
fn page(
  capability: option.Option(invites.Answer),
  asked: Subject(invites.Role),
) -> component.Model(page_fixture.Wire) {
  let start = page_fixture.start()
  component.Start(
    ..start,
    transport: component.Transport(
      ..start.transport,
      invite: option.map(capability, fn(answer) {
        fn(role) {
          process.send(asked, role)
          answer
        }
      }),
    ),
  )
  |> component.new
  |> component.apply([lane_fixture.captured(10, None)])
}

// The owner's page, answering with an invitation for the role asked.
fn owner(asked: Subject(invites.Role)) -> component.Model(page_fixture.Wire) {
  page(Some(invites.Minted(invitation(invites.Observer))), asked)
}

// Delivers `message` to the operator's page and then every message its
// effects dispatch, as the runtime would, so the daemon's answer arrives.
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
fn invite_clicks(keys: List(String)) -> List(String) {
  list.filter(keys, fn(key) {
    string.starts_with(key, component.invite_path <> "\t")
    && string.ends_with(key, "\nclick")
  })
}

fn count(html: String, part: String) -> Int {
  list.length(string.split(html, part)) - 1
}

// An owner's page has the control in the Session pane: a heading, the fixed
// sentence about the claim's lifetime and two buttons named for their roles.
pub fn an_owners_page_draws_the_control_test() {
  let html = drawn(owner(process.new_subject()))
  assert string.contains(html, "Invite to this session")
  assert string.contains(html, "expires in 60 minutes")
  assert string.contains(html, ">Invite an observer<")
  assert string.contains(html, ">Invite an operator<")

  // It is inside the Session pane, after the list of rows.
  let assert Ok(#(_, session)) =
    string.split_once(html, "<section aria-label=\"Session\"")
  assert string.contains(session, "Invite to this session")
  let assert Ok(#(before, _)) = string.split_once(session, "class=\"share\"")
  assert string.contains(before, "Est. cost")
}

// The path constant names the control: its two buttons are the only handlers
// beneath it, and nothing else on the page is.
pub fn the_buttons_are_the_only_handlers_beneath_the_invite_path_test() {
  let keys = handlers(operator_page.view(owner(process.new_subject())))
  assert list.length(invite_clicks(keys)) == 2
  assert list.length(
      list.filter(keys, fn(key) {
        string.starts_with(key, component.invite_path)
      }),
    )
    == 2
}

// A member operator's page and an observer's page draw nothing: the control's
// place holds an empty node, and no handler is beneath the path.
pub fn a_page_without_the_capability_draws_no_control_test() {
  let member = page(None, process.new_subject())
  let html = drawn(member)
  assert !string.contains(html, "Invite to this session")
  assert !string.contains(html, "share")
  assert invite_clicks(handlers(operator_page.view(member))) == []
}

// The observer's view has no message that asks and draws no control, even if
// its transport were handed the capability.
pub fn an_observers_page_never_draws_the_control_test() {
  let model = owner(process.new_subject())
  let html = element.to_string(component.view(model))
  assert !string.contains(html, "Invite")
  assert !string.contains(html, "loom-copy")
  assert invite_clicks(handlers(component.view(model))) == []
}

// Each button sends its role, once, and the answer becomes the invitation.
pub fn a_press_asks_for_its_role_once_test() {
  let asked = process.new_subject()
  let model = owner(asked)
  let shown = deliver(model, operator_page.Inviting(invites.Operator))
  assert process.receive(asked, 0) == Ok(invites.Operator)
  assert process.receive(asked, 0) == Error(Nil)
  assert component.share(shown) == invites.Showing(invitation(invites.Observer))
}

// The invitation shows the role, the principal and the lifetime, the command
// and the token each in a copy box, and the words for handing them over.
pub fn the_invitation_shows_the_command_and_the_token_once_test() {
  let model =
    deliver(
      owner(process.new_subject()),
      operator_page.Inviting(invites.Observer),
    )
  let html = drawn(model)
  assert string.contains(html, "Invitation ready")
  assert string.contains(html, "Role: observer. Principal: guest-1a2b3c4d.")
  assert string.contains(html, "valid for 60 minutes")
  assert string.contains(
    html,
    "<loom-copy subject=\"command\" text=\"loom claim --addr ws://127.0.0.1:4000/v2/control\"></loom-copy>",
  )
  assert string.contains(
    html,
    "<loom-copy subject=\"token\" text=\"" <> token <> "\"></loom-copy>",
  )

  // The token is on the page once, as the copy box's text attribute, and in
  // no text node, key, class or link.
  assert count(html, token) == 1

  // The words 053 asks the owner to see: a channel outside Loom, and the
  // fingerprint the invitee reports.
  assert string.contains(html, "over a channel outside Loom")
  assert string.contains(html, "credential fingerprint")
  assert string.contains(html, "loomd access revoke-credentials guest-1a2b3c4d")

  // While it shows, the buttons are gone and the only handler beneath the
  // path is the one that hides it.
  assert !string.contains(html, "Invite an observer")
  assert list.length(invite_clicks(handlers(operator_page.view(model)))) == 1
}

// Hiding the invitation replaces the state that held the token: neither the
// page nor the component's state names it afterwards, and the buttons return.
pub fn hiding_the_invitation_drops_the_token_test() {
  let model =
    deliver(
      owner(process.new_subject()),
      operator_page.Inviting(invites.Observer),
    )
  assert string.contains(string.inspect(model), token)

  let hidden = deliver(model, operator_page.Dismissing)
  assert !string.contains(string.inspect(hidden), token)
  let html = drawn(hidden)
  assert !string.contains(html, token)
  assert string.contains(html, ">Invite an observer<")
  assert component.share(hidden) == invites.Ready
}

// A second press while a request is with the daemon, or while an invitation is
// on screen, asks for nothing: one press mints at most one invitation.
pub fn a_second_press_mints_nothing_test() {
  let asked = process.new_subject()
  let model = owner(asked)

  // Both presses arrive before the daemon's answer is delivered.
  let #(asking, first) =
    operator_page.update(model, operator_page.Inviting(invites.Observer))
  assert component.share(asking) == invites.Asking
  let #(still_asking, second) =
    operator_page.update(asking, operator_page.Inviting(invites.Operator))
  assert component.share(still_asking) == invites.Asking

  // While the request is out the buttons are disabled and carry no handler.
  assert string.contains(drawn(still_asking), "disabled")
  assert invite_clicks(handlers(operator_page.view(still_asking))) == []
  effect.perform(
    second,
    fn(_) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  assert process.receive(asked, 0) == Error(Nil)
  effect.perform(
    first,
    fn(_) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
    fn() { panic as "no dynamic value" },
    fn(_, _) { Nil },
    fn(_, _) { Nil },
    fn(_) { Nil },
  )
  assert process.receive(asked, 0) == Ok(invites.Observer)

  // With the invitation on screen a press is ignored until it is hidden.
  let shown = deliver(model, operator_page.Inviting(invites.Observer))
  let _ = process.receive(asked, 0)
  let again = deliver(shown, operator_page.Inviting(invites.Operator))
  assert process.receive(asked, 0) == Error(Nil)
  assert component.share(again) == component.share(shown)
}

// Each refusal is worded in its own fixed sentence, which says nothing of the
// daemon's error, draws no token and leaves the buttons to press again.
pub fn a_refusal_is_worded_and_can_be_tried_again_test() {
  let words =
    list.map(
      [
        invites.NotOwner,
        invites.TooMany,
        invites.NotIsolated,
        invites.Unavailable,
      ],
      fn(reason) {
        let asked = process.new_subject()
        let model = page(Some(invites.Declined(reason)), asked)
        let refused = deliver(model, operator_page.Inviting(invites.Observer))
        assert component.share(refused) == invites.Refused(reason)
        let html = drawn(refused)
        assert string.contains(html, invites.reason_words(reason))
        assert !string.contains(html, "loomclaim_")
        assert string.contains(html, ">Invite an observer<")

        // A refused control asks again.
        let retried = deliver(refused, operator_page.Inviting(invites.Operator))
        assert process.receive(asked, 0) == Ok(invites.Observer)
        assert process.receive(asked, 0) == Ok(invites.Operator)
        assert component.share(retried) == invites.Refused(reason)
        invites.reason_words(reason)
      },
    )
  assert list.length(list.unique(words)) == 4
}

// A page with no capability ignores every message that would invite. The
// transport is asked nothing, no state holds a token and the page draws none.
pub fn a_page_without_the_capability_asks_nothing_test() {
  let asked = process.new_subject()
  let model = page(None, asked)
  assert component.share(model) == invites.Withheld
  let forged = deliver(model, operator_page.Inviting(invites.Operator))
  assert component.share(forged) == invites.Withheld
  assert process.receive(asked, 0) == Error(Nil)

  // An answer nobody asked for is dropped as well.
  let #(unasked, _) =
    component.update(
      forged,
      component.Invited(invites.Minted(invitation(invites.Operator))),
    )
  assert component.share(unasked) == invites.Withheld
  assert !string.contains(string.inspect(unasked), token)
  assert !string.contains(drawn(unasked), token)
}

// An answer that arrives when no request is out is dropped on an owner's page
// too, so a browser cannot put a token in the page: no handler carries the
// message, and the state does not take it.
pub fn an_unrequested_answer_is_dropped_test() {
  let model = owner(process.new_subject())
  let #(dropped, _) =
    component.update(
      model,
      component.Invited(invites.Minted(invitation(invites.Operator))),
    )
  assert component.share(dropped) == invites.Ready
  assert !string.contains(drawn(dropped), token)
}

// The invitation belongs to the page that asked. Another page of the same
// session, built from the same start, holds and draws nothing of it, and the
// invitation is in no transcript row the page keeps.
pub fn another_page_never_holds_the_invitation_test() {
  let asked = process.new_subject()
  let mine = deliver(owner(asked), operator_page.Inviting(invites.Observer))
  let theirs = owner(asked)
  assert string.contains(drawn(mine), token)
  assert !string.contains(drawn(theirs), token)
  assert !string.contains(string.inspect(theirs), token)
  assert !string.contains(element.to_string(component.view(mine)), token)
  assert !string.contains(string.inspect(component.pieces(mine)), token)
  assert component.notice(mine) == component.Quiet
}

// The claim's lifetime is a fixed hour, shorter than 053's day.
pub fn the_claim_lives_an_hour_test() {
  assert invites.claim_ttl_ms == 3_600_000
  assert invites.claim_ttl_ms < 86_400_000
}
