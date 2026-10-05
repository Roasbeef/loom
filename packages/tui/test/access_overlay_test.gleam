//// The owner's `/access` overlay (protocol-change/053, phase 3).
////
//// The reducer tests drive `access_overlay.update` and the loaders directly:
//// the list and its paging, each action and its y/N review, the refusals a
//// member or the owner's own row meets, and a failed action's notice. The
//// driver tests run the shipped `tui.update` with a control connection
//// adopted, so the command, the job it starts, the reply's drain and the
//// follow-up read are all the real ones.

import core/json
import etui/backend
import etui/buffer
import etui/geometry.{Position}
import etui/keys
import etui/widgets/textarea
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import host/access
import tui
import tui/access_overlay.{
  Active, Apply, ClaimExpired, ClaimOpen, Close, Continue, Member, NoCredential,
  Owner, ReadMemberships, ReadPrincipals, Reviewing, ShowingCommand,
}
import tui/connection
import tui/daemon/protocol
import tui/daemon/selection as daemon_selection
import tui/effect
import tui/job
import tui/model as tui_model
import tui/runtime
import tui/selection
import tui/session_control
import tui/view_set
import tui/workspace
import tui_test/stepping
import weft

const session_a = "01a0d5de-368e-7cc1-beeb-8da1658eec67"

const session_b = "01a0d5de-cf33-7fca-bbff-7c596e26ce46"

const fingerprint = "0123456789abcdef"

const owner_id =
  "0000000000000000000000000000000000000000000000000000000000000001"

fn owner() -> access_overlay.Principal {
  access_overlay.Principal(owner_id, "Owner", Owner, Active(fingerprint, None))
}

fn alice() -> access_overlay.Principal {
  access_overlay.Principal(
    "alice",
    "Alice",
    Member,
    Active("fedcba9876543210", Some(1_700_000_000_000)),
  )
}

fn bob() -> access_overlay.Principal {
  access_overlay.Principal("bob", "Bob", Member, ClaimOpen(90 * 60_000))
}

// A state holding the three principals, as the first page leaves it.
fn listing() -> access_overlay.State {
  let page = access_overlay.PrincipalPage([owner(), alice(), bob()], next: None)
  access_overlay.listed(access_overlay.new(), page, None)
}

// A state that has opened Alice and read her two memberships.
fn opened() -> access_overlay.State {
  let assert ReadMemberships(state, "alice", None) =
    access_overlay.update(keys.Enter, select(listing(), 1))
  let page =
    access_overlay.MembershipPage(
      [
        access_overlay.Membership(session_a, "Review", protocol.ObserverRole),
        access_overlay.Membership(session_b, "Deploy", protocol.OperatorRole),
      ],
      next: None,
    )
  access_overlay.memberships_listed(state, "alice", page, None)
}

// Moves the principal cursor down `count` rows.
fn select(state: access_overlay.State, count: Int) -> access_overlay.State {
  case count {
    0 -> state
    _ -> {
      let assert Continue(next) = access_overlay.update(keys.Down, state)
      select(next, count - 1)
    }
  }
}

fn reviewing(state: access_overlay.State) -> access_overlay.Change {
  let assert Reviewing(change) = state.prompt
  change
}

// ---- decoding -------------------------------------------------------------

const principals_body =
  "{\"principals\":[{\"principal_id\":\"alice\",\"name\":\"Alice\",\"kind\":\"member\",\"credential\":{\"state\":\"active\",\"fingerprint\":\"fedcba9876543210\",\"claimed_at_ms\":5}},{\"principal_id\":\"bob\",\"name\":\"Bob\",\"kind\":\"member\",\"credential\":{\"state\":\"claim_open\",\"expires_in_ms\":60000}},{\"principal_id\":\"carol\",\"name\":\"Carol\",\"kind\":\"member\",\"credential\":{\"state\":\"claim_expired\"}},{\"principal_id\":\"dan\",\"name\":\"Dan\",\"kind\":\"member\",\"credential\":{\"state\":\"none\"}}],\"next\":\"dan\"}"

pub fn principals_decode_all_four_credential_states_and_the_cursor_test() {
  let assert Ok(document) = json.parse(principals_body)
  let assert Ok(page) = access_overlay.decode_principals(document)
  assert page.next == Some("dan")
  assert page.principals
    == [
      access_overlay.Principal(
        "alice",
        "Alice",
        Member,
        Active("fedcba9876543210", Some(5)),
      ),
      access_overlay.Principal("bob", "Bob", Member, ClaimOpen(60_000)),
      access_overlay.Principal("carol", "Carol", Member, ClaimExpired),
      access_overlay.Principal("dan", "Dan", Member, NoCredential),
    ]
}

// The overlay accepts the rows `loom access list` prints and no others, so a
// credential that is not a 16-character fingerprint is refused before it can
// be drawn.
pub fn a_full_credential_in_the_fingerprint_field_is_refused_test() {
  let secret = string.repeat("ab", 32)
  let body =
    "{\"principals\":[{\"principal_id\":\"alice\",\"name\":\"Alice\",\"kind\":\"member\",\"credential\":{\"state\":\"active\",\"fingerprint\":\""
    <> secret
    <> "\"}}]}"
  let assert Ok(document) = json.parse(body)
  let assert Error(reason) = access_overlay.decode_principals(document)
  assert !string.contains(reason, secret)
}

pub fn an_unknown_principal_kind_is_refused_test() {
  let assert Ok(document) =
    json.parse(
      "{\"principals\":[{\"principal_id\":\"x\",\"name\":\"X\",\"kind\":\"admin\",\"credential\":{\"state\":\"none\"}}]}",
    )
  assert access_overlay.decode_principals(document)
    == Error("invalid principal kind")
}

pub fn memberships_decode_and_refuse_another_principals_reply_test() {
  let body =
    "{\"principal_id\":\"alice\",\"memberships\":[{\"session_id\":\""
    <> session_a
    <> "\",\"name\":\"Review\",\"role\":\"observer\"}],\"next\":\""
    <> session_a
    <> "\"}"
  let assert Ok(document) = json.parse(body)
  let assert Ok(page) = access_overlay.decode_memberships(document, "alice")
  assert page.memberships
    == [access_overlay.Membership(session_a, "Review", protocol.ObserverRole)]
  assert page.next == Some(session_a)
  assert access_overlay.decode_memberships(document, "bob")
    == Error("response identity or epoch mismatch")
}

// ---- the list and its paging ----------------------------------------------

pub fn the_cursor_wraps_and_enter_opens_the_selected_principals_sessions_test() {
  let state = listing()
  let assert Continue(up) = access_overlay.update(keys.Up, state)
  assert up.selected_principal == 2 as "Up from the first row wraps"
  let assert Continue(down) = access_overlay.update(keys.Down, up)
  assert down.selected_principal == 0

  let assert ReadMemberships(reading, "bob", None) =
    access_overlay.update(keys.Enter, up)
  assert reading.focus == access_overlay.ListingMemberships(bob())
  assert reading.memberships == []
}

pub fn a_later_page_is_appended_and_a_moved_row_shows_once_test() {
  let first =
    access_overlay.PrincipalPage([owner(), alice()], next: Some("alice"))
  let state = access_overlay.listed(access_overlay.new(), first, None)
  assert state.notice == "more principals available · press n to continue"

  let assert ReadPrincipals(loading, Some("alice")) =
    access_overlay.update(keys.Char("n"), state)
  assert loading.notice == "loading more principals"

  // Alice moved across the cursor between the two reads.
  let renamed = access_overlay.Principal(..alice(), name: "Alice Renamed")
  let second = access_overlay.PrincipalPage([renamed, bob()], next: None)
  let state = access_overlay.listed(loading, second, Some("alice"))
  assert list.map(state.principals, fn(row) { row.id })
    == [owner_id, "alice", "bob"]
  assert list.map(state.principals, fn(row) { row.name })
    == ["Owner", "Alice Renamed", "Bob"]
  assert state.principals_next == None
  assert state.notice == ""

  let assert Continue(done) = access_overlay.update(keys.Char("n"), state)
  assert done.notice == "no more principals"
}

pub fn refresh_reads_the_first_page_again_test() {
  let assert ReadPrincipals(state, None) =
    access_overlay.update(keys.Char("r"), listing())
  assert state.notice == "refreshing"
}

pub fn memberships_page_and_a_stale_reply_is_dropped_test() {
  let state = opened()
  let more =
    access_overlay.MembershipPage(
      [access_overlay.Membership(session_b, "Deploy", protocol.ObserverRole)],
      next: None,
    )

  // A reply for a principal that is no longer the opened one changes nothing.
  assert access_overlay.memberships_listed(state, "bob", more, None) == state

  let merged =
    access_overlay.memberships_listed(state, "alice", more, Some(session_a))
  assert list.map(merged.memberships, fn(row) { row.role })
    == [protocol.ObserverRole, protocol.ObserverRole]
    as "the moved row was replaced, not repeated"
}

pub fn escape_steps_back_from_memberships_and_then_closes_test() {
  let assert Continue(back) = access_overlay.update(keys.Escape, opened())
  assert back.focus == access_overlay.ListingPrincipals
  assert access_overlay.update(keys.Escape, back) == Close
}

// ---- set-role -------------------------------------------------------------

pub fn set_role_is_reviewed_and_only_y_sends_it_test() {
  let assert Continue(review) = access_overlay.update(keys.Char("o"), opened())
  assert reviewing(review)
    == access_overlay.SetRole(
      session_a,
      "Review",
      "alice",
      "Alice",
      protocol.OperatorRole,
    )

  // Enter, another letter and Y in capitals leave the question open.
  let assert Continue(same) = access_overlay.update(keys.Enter, review)
  assert same.prompt == review.prompt
  let assert Continue(same) = access_overlay.update(keys.Char("Y"), review)
  assert same.prompt == review.prompt

  let assert Apply(sending, change) =
    access_overlay.update(keys.Char("y"), review)
  assert change == reviewing(review)
  assert sending.prompt == access_overlay.Browsing
  assert sending.sending == Some(change)
}

pub fn declining_a_review_sends_nothing_test() {
  let assert Continue(review) =
    access_overlay.update(keys.Char("b"), select_second_membership())
  let assert Continue(declined) = access_overlay.update(keys.Char("n"), review)
  assert declined.prompt == access_overlay.Browsing
  assert declined.sending == None
  assert declined.notice == "change cancelled"

  let assert Continue(review) =
    access_overlay.update(keys.Char("b"), select_second_membership())
  let assert Continue(escaped) = access_overlay.update(keys.Escape, review)
  assert escaped.prompt == access_overlay.Browsing
  assert escaped.focus == review.focus
    as "Escape declines the question and does not leave the list"
}

fn select_second_membership() -> access_overlay.State {
  let assert Continue(state) = access_overlay.update(keys.Down, opened())
  state
}

pub fn setting_the_role_a_member_already_holds_is_not_proposed_test() {
  let assert Continue(refused) = access_overlay.update(keys.Char("b"), opened())
  assert refused.prompt == access_overlay.Browsing
  assert refused.notice == "Alice already holds that role in Review"
}

// ---- revoke ---------------------------------------------------------------

pub fn revoking_a_membership_is_reviewed_and_sent_on_y_test() {
  let assert Continue(review) = access_overlay.update(keys.Char("d"), opened())
  let expected =
    access_overlay.RevokeMembership(session_a, "Review", "alice", "Alice")
  assert reviewing(review) == expected
  let assert Apply(sending, change) =
    access_overlay.update(keys.Char("y"), review)
  assert change == expected
  assert sending.sending == Some(expected)
}

pub fn revoking_credentials_is_reviewed_from_either_list_test() {
  let assert Continue(from_principals) =
    access_overlay.update(keys.Char("c"), select(listing(), 1))
  let expected = access_overlay.RevokeCredentials("alice", "Alice")
  assert reviewing(from_principals) == expected

  let assert Continue(from_memberships) =
    access_overlay.update(keys.Char("c"), opened())
  assert reviewing(from_memberships) == expected

  let assert Apply(_, change) =
    access_overlay.update(keys.Char("y"), from_memberships)
  assert change == expected
}

// The owner's credential is the owner token, which authenticates the very
// connection this overlay sends over, so revoking it would end the session.
pub fn the_owners_own_credential_is_not_offered_for_revocation_test() {
  let assert Continue(refused) =
    access_overlay.update(keys.Char("c"), listing())
  assert refused.prompt == access_overlay.Browsing
  assert refused.notice == "the owner's credential is not managed here"
  let assert Continue(refused) =
    access_overlay.update(keys.Char("t"), listing())
  assert refused.notice == "the owner's credential is not rotated here"
}

// ---- what the overlay does not do -----------------------------------------

pub fn invite_and_rotate_show_the_command_and_send_nothing_test() {
  let assert Continue(invite) = access_overlay.update(keys.Char("i"), listing())
  assert invite.prompt == ShowingCommand(access.invite_line(""))

  let assert Continue(rotate) =
    access_overlay.update(keys.Char("t"), select(listing(), 2))
  assert rotate.prompt == ShowingCommand("loom access rotate bob")

  // From a membership list the invitation line names the highlighted session.
  let assert Continue(from_session) =
    access_overlay.update(keys.Char("i"), opened())
  assert from_session.prompt == ShowingCommand(access.invite_line(session_a))

  // Only Escape or Enter dismiss the line; nothing sends.
  let assert Continue(kept) = access_overlay.update(keys.Char("y"), rotate)
  assert kept.prompt == rotate.prompt
  let assert Continue(back) = access_overlay.update(keys.Escape, rotate)
  assert back.prompt == access_overlay.Browsing
  let assert Continue(back) = access_overlay.update(keys.Enter, rotate)
  assert back.prompt == access_overlay.Browsing
}

// The lines the overlay shows are the commands `host/access` parses, with
// the placeholders replaced.
pub fn the_shown_lines_are_commands_the_shared_grammar_accepts_test() {
  let assert Ok(_) = access.parse(["rotate", "bob"], access.Loom)
  assert access.rotate_line("bob") == "loom access rotate bob"
  let assert "loom access " <> words = access.invite_line(session_a)
  let words = string.split(words, " ")
  assert words == ["invite", session_a, "PRINCIPAL", "ROLE", "NAME"]
  let assert Ok(_) =
    access.parse(
      ["invite", session_a, "carol", "observer", "Carol"],
      access.Loom,
    )
}

// The overlay has no key that grants: no letter reaches an invitation or a
// rotation as a control command, and a change sent is one of the three
// reductions.
pub fn no_key_sends_a_grant_test() {
  let states = [listing(), opened()]
  let letters = string.to_graphemes("abcdefghijklmnopqrstuvwxyz")
  list.each(states, fn(state) {
    list.each(letters, fn(letter) {
      case access_overlay.update(keys.Char(letter), state) {
        Apply(..) -> panic as "a single key sent a change without a review"
        Continue(_) | Close | ReadPrincipals(..) | ReadMemberships(..) -> Nil
      }
    })
  })
}

// ---- results and failures -------------------------------------------------

pub fn an_acknowledged_role_change_reads_the_memberships_again_test() {
  let assert Continue(review) = access_overlay.update(keys.Char("o"), opened())
  let assert Apply(sending, _) = access_overlay.update(keys.Char("y"), review)
  let assert Ok(ack) =
    json.parse("{\"principal_id\":\"alice\",\"name\":\"Alice\"}")
  let assert ReadMemberships(after, "alice", None) =
    access_overlay.changed(sending, ack)
  assert after.sending == None
  assert after.outcome == Some("set Alice to operator in Review")
}

pub fn an_acknowledged_credential_revocation_returns_to_the_principals_test() {
  let assert Continue(review) = access_overlay.update(keys.Char("c"), opened())
  let assert Apply(sending, _) = access_overlay.update(keys.Char("y"), review)
  let assert Ok(ack) =
    json.parse("{\"principal_id\":\"alice\",\"name\":\"Alice\"}")
  let assert ReadPrincipals(after, None) = access_overlay.changed(sending, ack)
  assert after.focus == access_overlay.ListingPrincipals
  assert after.outcome == Some("revoked Alice's credentials")
}

pub fn an_acknowledgement_naming_another_principal_is_reported_not_trusted_test() {
  let assert Continue(review) = access_overlay.update(keys.Char("d"), opened())
  let assert Apply(sending, _) = access_overlay.update(keys.Char("y"), review)
  let assert Ok(ack) =
    json.parse("{\"principal_id\":\"mallory\",\"name\":\"M\"}")
  let assert ReadMemberships(after, "alice", None) =
    access_overlay.changed(sending, ack)
  assert after.outcome == None
  assert string.contains(after.notice, "acknowledged a different principal")
}

pub fn an_acknowledgement_with_no_change_outstanding_is_dropped_test() {
  let assert Ok(ack) =
    json.parse("{\"principal_id\":\"alice\",\"name\":\"Alice\"}")
  assert access_overlay.changed(opened(), ack) == Continue(opened())
}

pub fn a_second_change_cannot_start_while_one_is_outstanding_test() {
  let assert Continue(review) = access_overlay.update(keys.Char("d"), opened())
  let assert Apply(sending, _) = access_overlay.update(keys.Char("y"), review)
  let assert Continue(waiting) = access_overlay.update(keys.Char("o"), sending)
  assert waiting.prompt == access_overlay.Browsing
  assert waiting.sending == sending.sending
  assert waiting.notice == "waiting for the daemon's answer"
}

pub fn a_member_is_told_the_overlay_is_for_the_owner_test() {
  let state =
    access_overlay.failed(access_overlay.new(), "forbidden: owner only")
  assert state.notice
    == "the access overlay is for the owner; this connection is not"
}

pub fn a_failed_change_keeps_the_notice_and_clears_the_outstanding_change_test() {
  let assert Continue(review) = access_overlay.update(keys.Char("d"), opened())
  let assert Apply(sending, _) = access_overlay.update(keys.Char("y"), review)
  let failed = access_overlay.failed(sending, "conflict: membership changed")
  assert failed.sending == None
  assert failed.notice == "access request refused: conflict: membership changed"
}

pub fn a_lost_reply_says_to_refresh_and_is_not_retried_test() {
  let state =
    access_overlay.failed(
      access_overlay.new(),
      "unknown outcome for sessions.revoke; request was not retried",
    )
  assert string.ends_with(state.notice, "press r to see the current state")
}

// ---- drawing --------------------------------------------------------------

fn drawn(state: access_overlay.State) -> String {
  let screen = geometry.rect_new(0, 0, 100, 38)
  let rendered = access_overlay.render(buffer.buffer_new(screen), screen, state)
  selection.text(
    rendered,
    selection.start(screen, Position(0, 0))
      |> selection.extend(Position(99, 37)),
  )
}

pub fn the_listing_shows_fingerprints_and_states_and_no_credential_test() {
  let text = drawn(listing())
  assert string.contains(text, "ACCESS")
  assert string.contains(text, "Alice")
  assert string.contains(text, "fingerprint fedcba9876543210")
  assert string.contains(text, "bound by a claim")
  assert string.contains(text, "claim open · expires in 90 minutes")
  assert string.contains(text, "id alice")
}

// A 64-character hexadecimal run is what a credential or a claim looks like.
// The only one a listing may carry is the owner's principal ID, which is an
// identity, so it is set aside by name as the daemon's own test does.
pub fn no_drawn_frame_holds_a_credential_sized_secret_test() {
  let frames = [
    drawn(listing()),
    drawn(opened()),
    drawn(with_prompt(
      opened(),
      access_overlay.ShowingCommand(access.rotate_line("bob")),
    )),
  ]
  list.each(frames, fn(frame) {
    let without_owner = string.replace(frame, owner_id, "")
    assert !has_hex_run(without_owner, 64)
  })
}

fn with_prompt(
  state: access_overlay.State,
  prompt: access_overlay.Prompt,
) -> access_overlay.State {
  access_overlay.State(..state, prompt:)
}

fn has_hex_run(text: String, length: Int) -> Bool {
  let #(longest, _) =
    list.fold(string.to_graphemes(text), #(0, 0), fn(runs, character) {
      let #(longest, current) = runs
      case string.contains("0123456789abcdef", character) {
        True -> #(int_max(longest, current + 1), current + 1)
        False -> #(longest, 0)
      }
    })
  longest >= length
}

fn int_max(left: Int, right: Int) -> Int {
  case left > right {
    True -> left
    False -> right
  }
}

pub fn a_review_states_the_names_the_ids_and_the_consequence_test() {
  let assert Continue(review) = access_overlay.update(keys.Char("d"), opened())
  let text = drawn(review)
  assert string.contains(text, "Revoke Alice's access to Review?")
  assert string.contains(text, "principal alice · session " <> session_a)
  assert string.contains(text, "Other sessions are unchanged")
  assert string.contains(text, "y confirm · n or Esc cancel")

  let assert Continue(credentials) =
    access_overlay.update(keys.Char("c"), opened())
  assert string.contains(
    drawn(credentials),
    "Revoke every credential of Alice?",
  )
}

pub fn the_command_view_says_the_terminal_never_shows_a_claim_test() {
  let assert Continue(rotate) =
    access_overlay.update(keys.Char("t"), select(listing(), 1))
  let text = drawn(rotate)
  assert string.contains(text, "loom access rotate alice")
  assert string.contains(text, "never shows one")
}

// ---- protocol -------------------------------------------------------------

pub fn each_access_command_encodes_with_the_epoch_a_change_needs_test() {
  let epoch = protocol.Epoch("epoch-1")
  let assert Ok(list_text) =
    protocol.encode(1, protocol.ListPrincipals(Some("alice")), epoch)
  assert !string.contains(list_text, "epoch") as "a read carries no epoch"
  assert string.contains(list_text, "\"cmd\":\"principals.list\"")
  assert string.contains(list_text, "\"after\":\"alice\"")

  let assert Ok(shown) =
    protocol.encode(
      2,
      protocol.PrincipalMemberships("alice", Some(session_a)),
      epoch,
    )
  assert !string.contains(shown, "epoch")
  assert string.contains(shown, "\"principal_id\":\"alice\"")
  assert string.contains(shown, "\"after\":\"" <> session_a <> "\"")

  let assert Ok(set_role) =
    protocol.encode(
      3,
      protocol.SetMemberRole(session_a, "alice", protocol.OperatorRole),
      epoch,
    )
  assert string.contains(set_role, "\"cmd\":\"sessions.set_role\"")
  assert string.contains(set_role, "\"epoch\":\"epoch-1\"")
  assert string.contains(set_role, "\"role\":\"operator\"")

  let assert Ok(revoke) =
    protocol.encode(4, protocol.RevokeMembership(session_a, "alice"), epoch)
  assert string.contains(revoke, "\"cmd\":\"sessions.revoke\"")
  assert string.contains(revoke, "\"epoch\":\"epoch-1\"")

  let assert Ok(credentials) =
    protocol.encode(5, protocol.RevokeCredentials("alice"), epoch)
  assert string.contains(credentials, "\"cmd\":\"credentials.revoke\"")
  assert string.contains(credentials, "\"epoch\":\"epoch-1\"")
}

pub fn only_the_three_changes_are_mutations_and_a_bad_id_is_refused_test() {
  assert !protocol.mutates(protocol.ListPrincipals(None))
  assert !protocol.mutates(protocol.PrincipalMemberships("alice", None))
  assert protocol.mutates(protocol.SetMemberRole(
    session_a,
    "alice",
    protocol.ObserverRole,
  ))
  assert protocol.mutates(protocol.RevokeMembership(session_a, "alice"))
  assert protocol.mutates(protocol.RevokeCredentials("alice"))

  let epoch = protocol.Epoch("epoch-1")
  assert protocol.encode(1, protocol.RevokeCredentials("a b"), epoch)
    == Error("invalid principal id")
  assert protocol.encode(
      1,
      protocol.RevokeMembership("not-a-session", "a"),
      epoch,
    )
    == Error("invalid session id")
}

pub fn the_replies_decode_to_unread_documents_test() {
  let listing_reply =
    "{\"v\":2,\"reply_to\":4,\"event\":\"principals.list\",\"body\":{\"principals\":[]}}"
  let assert Ok(protocol.Answer(
    4,
    "principals.list",
    protocol.AccessListingReply(_),
  )) = protocol.decode(listing_reply)
  let change_reply =
    "{\"v\":2,\"reply_to\":5,\"event\":\"credentials.revoke\",\"body\":{\"principal_id\":\"alice\",\"name\":\"Alice\"}}"
  let assert Ok(protocol.Answer(
    5,
    "credentials.revoke",
    protocol.AccessChangeReply(_),
  )) = protocol.decode(change_reply)
}

// ---- the shipped loop -----------------------------------------------------

@external(erlang, "effects_test_ffi", "host_on")
fn host_on(owner: Subject(Dynamic)) -> daemon_selection.Host

fn blank() -> tui_model.Model {
  tui.new_model(connection.new_inbox(), workspace.Context("/work", None))
}

fn typing(model: tui_model.Model, text: String) -> tui_model.Model {
  tui_model.Model(
    ..model,
    view: view_set.input(model.view, textarea.state_from_string(text)),
  )
}

fn control_jobs(effects: List(effect.Effect)) -> List(job.Spec) {
  list.filter_map(effects, fn(requested) {
    case requested {
      effect.StartJob(_, spec) -> Ok(spec)
      _ -> Error(Nil)
    }
  })
}

// Hands the slot's job a completed reply and the relay's end, and drains both.
fn deliver(
  model: tui_model.Model,
  outcome: job.ControlOutcome,
) -> tui_model.Model {
  let assert Some(tui_model.ControlRequest(job: awaiting, ..)) =
    model.view.control_request
  let key = job.key(awaiting)
  model
  |> runtime.hold(job.ControlArrived(
    key,
    weft.PulledOutcome(weft.Completed(0, outcome)),
  ))
  |> runtime.hold(job.ControlArrived(key, weft.AllDelivered))
  |> session_control.drain_control
  |> session_control.drain_control
}

pub fn access_opens_lists_reviews_sends_and_reads_again_test() {
  let owner_inbox: Subject(Dynamic) = process.new_subject()
  let model = runtime.adopt_control(blank(), host_on(owner_inbox))
  let assert Some(daemon) = model.view.daemon_host

  // `/access` starts one principals read and opens the overlay empty.
  let #(opened, effects) =
    stepping.step(backend.KeyPress("enter"), typing(model, "/access"))
  assert control_jobs(effects)
    == [
      job.Control(daemon.control, job.ReadAccess(protocol.ListPrincipals(None))),
    ]
  let assert tui_model.AccessManager(loading) = opened.view.overlay
  assert loading.principals == []

  // The reply fills the list.
  let assert Ok(document) = json.parse(principals_body)
  let listed = deliver(opened, job.AccessListed(document, None))
  let assert tui_model.AccessManager(state) = listed.view.overlay
  assert list.length(state.principals) == 4
  assert listed.view.control_request == None

  // Revoking Alice's credentials: `c`, then `y`, sends exactly one command.
  let #(reviewing_model, effects) = stepping.step(backend.KeyPress("c"), listed)
  assert control_jobs(effects) == []
  let assert tui_model.AccessManager(review) = reviewing_model.view.overlay
  assert review.prompt
    == Reviewing(access_overlay.RevokeCredentials("alice", "Alice"))
    as "the first row is Alice, whose credential is active"
  let #(sending_model, effects) =
    stepping.step(backend.KeyPress("y"), reviewing_model)
  assert control_jobs(effects)
    == [
      job.Control(
        daemon.control,
        job.ChangeAccess(protocol.RevokeCredentials("alice")),
      ),
    ]

  // The acknowledgement starts the read that shows its effect.
  let assert Ok(ack) =
    json.parse("{\"principal_id\":\"alice\",\"name\":\"Alice\"}")
  let acknowledged = deliver(sending_model, job.AccessChanged(ack))
  let assert tui_model.AccessManager(after) = acknowledged.view.overlay
  assert after.outcome == Some("revoked Alice's credentials")
  let assert Some(tui_model.ControlRequest(..)) =
    acknowledged.view.control_request
    as "the follow-up read holds the control slot"
}

pub fn a_second_confirmation_while_busy_sends_nothing_test() {
  let owner_inbox: Subject(Dynamic) = process.new_subject()
  let model = runtime.adopt_control(blank(), host_on(owner_inbox))
  let #(opened, _) =
    stepping.step(backend.KeyPress("enter"), typing(model, "/access"))
  let assert Ok(document) = json.parse(principals_body)
  let listed = deliver(opened, job.AccessListed(document, None))
  let #(reviewing_model, _) = stepping.step(backend.KeyPress("c"), listed)

  // Another control request holds the slot when the confirmation arrives.
  let #(occupied, key) = tui_model.allocate_job(reviewing_model)
  let busy =
    tui_model.Model(
      ..occupied,
      view: view_set.control_request(
        occupied.view,
        Some(tui_model.ControlRequest(job.awaiting(key), None)),
      ),
    )
  let #(refused, effects) = stepping.step(backend.KeyPress("y"), busy)
  assert control_jobs(effects) == []
  let assert tui_model.AccessManager(state) = refused.view.overlay
  assert state.sending == None
  assert state.notice
    == "access request refused: another daemon control request is running"
}

pub fn a_member_connection_sees_the_owner_only_line_test() {
  let owner_inbox: Subject(Dynamic) = process.new_subject()
  let model = runtime.adopt_control(blank(), host_on(owner_inbox))
  let #(opened, _) =
    stepping.step(backend.KeyPress("enter"), typing(model, "/access"))
  let assert Some(tui_model.ControlRequest(job: awaiting, ..)) =
    opened.view.control_request
  let key = job.key(awaiting)
  let refused =
    opened
    |> runtime.hold(job.ControlArrived(
      key,
      weft.PulledOutcome(weft.Failed(0, "forbidden: owner only")),
    ))
    |> runtime.hold(job.ControlArrived(key, weft.AllDelivered))
    |> session_control.drain_control
    |> session_control.drain_control
  let assert tui_model.AccessManager(state) = refused.view.overlay
  assert state.notice
    == "the access overlay is for the owner; this connection is not"
}

pub fn access_without_daemon_control_is_refused_in_the_transcript_test() {
  let #(refused, effects) =
    stepping.step(backend.KeyPress("enter"), typing(blank(), "/access"))
  assert control_jobs(effects) == []
  assert refused.view.overlay == tui_model.NoOverlay
}

// The overlay takes no text, so a paste is ignored and nothing a recording
// captures through it can be a claim.
pub fn a_paste_is_ignored_by_the_overlay_test() {
  let owner_inbox: Subject(Dynamic) = process.new_subject()
  let model = runtime.adopt_control(blank(), host_on(owner_inbox))
  let #(opened, _) =
    stepping.step(backend.KeyPress("enter"), typing(model, "/access"))
  let pasted = tui.update(backend.Paste("clm_secret"), opened)
  assert pasted.view.overlay == opened.view.overlay
}

// A refused read, such as a next page, is not the answer to a change, so it
// must not cancel a review the operator has open.
pub fn a_failed_read_keeps_a_pending_review_open_test() {
  let assert Continue(review) = access_overlay.update(keys.Char("d"), opened())
  let failed = access_overlay.failed(review, "unavailable: busy")
  assert failed.prompt == review.prompt
  assert failed.notice == "access request refused: unavailable: busy"
}
