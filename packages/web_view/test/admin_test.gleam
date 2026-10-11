//// The owner's admin page (protocol-change/065, the fifth pull request): the
//// people the catalogue holds, each once, and the sessions with their members,
//// drawn in the home's frame, and the changes the owner makes from it.
////
//// These tests pin what the page lists and says, that every name is escaped
//// text and nothing a peer wrote is an attribute, that every handler is a click
//// or a submit beneath the one region the daemon's socket admits, that an ask is
//// made once and its buttons are disabled meanwhile, that a revocation is two
//// presses, that a claim is on screen once, beside the action that made it, and
//// until it is hidden, that a read that was overtaken is dropped, and how a page
//// that can no longer be served ends.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import lustre/effect
import lustre/element.{type Element}
import web_view/admin
import web_view/creations
import web_view/ending
import web_view/grants
import web_view/home
import web_view/invites
import web_view/sessions.{type Entry, Entry, Live, Saved}
import web_view/signins
import web_view/view/admin_sessions

@external(erlang, "page_events_ffi", "handlers")
fn handlers(view: Element(message)) -> List(String)

type Cache

@external(erlang, "lane_memo_ffi", "first")
fn first(view: Element(message)) -> Cache

// The patch the server runtime would broadcast for a re-render, as JSON text,
// and the cache that carries on.
@external(erlang, "lane_memo_ffi", "patch_text")
fn patch_text(
  cache: Cache,
  old: Element(message),
  new: Element(message),
) -> #(String, Cache)

// A claim token, which is `loomclaim_` and 64 hexadecimal digits.
const token =
  "loomclaim_0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

const session = "0198a2f4-7c3b-7e10-8d5a-3f9b2c4e6a71"

const other_session = "0198a2f4-7c3b-7e10-8d5a-3f9b2c4e6a72"

fn entry(id: String, name: String, residency: sessions.Residency) -> Entry {
  Entry(
    id:,
    name:,
    workspace: "/src/loom",
    created_at: 100_000,
    residency:,
    subtitle: None,
    role: None,
    project: None,
    executor: None,
  )
}

fn people() -> List(grants.Principal) {
  [
    grants.Principal(
      "owner",
      "Olive Owner",
      grants.OwnerKind,
      grants.Active("aaaaaaaaaaaaaaaa", None),
    ),
    grants.Principal(
      "bob",
      "Bob",
      grants.MemberKind,
      grants.Active("bbbbbbbbbbbbbbbb", Some(1000)),
    ),
    grants.Principal(
      "cara",
      "Cara",
      grants.MemberKind,
      grants.ClaimOpen(3_000_000),
    ),
    grants.Principal("dan", "Dan", grants.MemberKind, grants.ClaimExpired),
    grants.Principal("eve", "Eve", grants.MemberKind, grants.NoCredential),
  ]
}

fn holders() -> List(grants.Holder) {
  [
    grants.Holder("bob", "Bob", invites.Observer),
    grants.Holder("cara", "Cara", invites.Operator),
  ]
}

// What a read finds when the owner has chosen `chosen`: the five people, two
// sessions, and the members of the chosen one when it is the first.
fn snapshot(chosen: Option(String)) -> grants.Snapshot {
  grants.Snapshot(
    principals: people(),
    more_principals: grants.Whole,
    sessions: [
      entry(session, "review auth", Live),
      entry(other_session, "notes", Saved),
    ],
    selection: case chosen {
      Some(id) if id == session ->
        Some(grants.Selection(
          session:,
          holders: holders(),
          more: grants.Whole,
          scope: creations.Shareable,
        ))
      Some(_) | None -> None
    },
    logins: [],
    summaries: [
      grants.Summary(session, 3, grants.Whole, creations.Shareable),
      grants.Summary(other_session, 1, grants.Whole, creations.Private),
    ],
  )
}

// A page whose reads answer at once with the catalogue above and tell `reads`
// what was chosen, and whose asks tell `acts` what was asked and answer with
// `answer`.
fn start_with(
  reads: Subject(Option(String)),
  acts: Subject(grants.Action),
  answer: grants.Answer,
) -> admin.Start {
  admin.Start(
    name: "Olive",
    refresh_ms: 5,
    read: fn(chosen, deliver) {
      process.send(reads, chosen)
      deliver(grants.Read(snapshot(chosen)))
    },
    act: fn(action, deliver) {
      process.send(acts, action)
      deliver(answer)
    },
    now: fn() { 7_400_000 },
    login: None,
    ends_at: 7_400_000 + 14 * 60 * 1000,
  )
}

fn start() -> admin.Start {
  start_with(process.new_subject(), process.new_subject(), grants.Changed)
}

// Runs one message through the component and performs its effects the way
// Lustre's runtime would: a dispatched message is applied in its turn. The
// effect's own dispatches are collected and folded back in, in order.
fn run(model: admin.Model, message: admin.Msg) -> admin.Model {
  let #(model, effects) = admin.update(model, message)
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
  settle(model, dispatched)
}

fn settle(model: admin.Model, dispatched: Subject(admin.Msg)) -> admin.Model {
  case process.receive(dispatched, 0) {
    Ok(next) -> run(model, next)
    Error(Nil) -> model
  }
}

// A page whose timer exists and whose first read has answered.
fn opened(start: admin.Start) -> #(admin.Model, Subject(Nil)) {
  let timer = process.new_subject()
  #(run(admin.new(start), admin.TimerReady(timer)), timer)
}

fn drawn(model: admin.Model) -> String {
  element.to_string(admin.view(model))
}

fn count(html: String, needle: String) -> Int {
  list.length(string.split(html, needle)) - 1
}

// A page that has read nothing has nothing to list: its words, the frame and no
// handler, and it is not yet connected.
pub fn a_page_that_has_read_nothing_draws_only_its_words_test() {
  let model = admin.new(start())
  let html = drawn(model)
  assert admin.status(model) == admin.Connecting
  assert string.contains(html, "Reading the catalogue.")
  assert string.contains(html, "connecting")
  assert string.contains(html, ">Admin<")
  assert !string.contains(html, "People")
  assert handlers(admin.view(model)) == [] as "no handler before a read"
}

// The page is the home's frame under its own title, with no sidebar and no
// panel, and the principal's name and the ceiling in the bar.
pub fn the_page_draws_in_the_homes_frame_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert admin.status(model) == admin.Connected
  assert string.contains(html, "<loom-shell")
  assert string.contains(html, "loom-home")
  assert string.contains(html, "sidebar=\"none\"")
  assert string.contains(html, ">Admin<")
  assert string.contains(html, "Olive")
  assert !string.contains(html, ">operator<")
  assert string.contains(html, "connected")
  assert !string.contains(html, "<aside")
}

// The two sections, in order, with each person's credential in words: the
// owner, an active member with when they joined, an open claim with the time it
// has left, an expired one and none. A person whose claim is open is one row of
// the people list, with the count of invited in the heading, and there is no
// second list of them (round 4, F84).
pub fn the_people_are_listed_once_with_their_invitations_in_their_rows_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert !string.contains(html, "Pending invitations")
  assert !string.contains(html, "No invitation is waiting")
  let assert [_, people_and_after] = string.split(html, ">People<")
  let assert [people_section, sessions_section] =
    string.split(people_and_after, ">Sessions<")

  assert string.contains(people_section, ">5<")
  assert string.contains(people_section, "· 1 invited")
  assert string.contains(people_section, "Olive Owner")
  assert string.contains(
    people_section,
    "owner · active · key aaaaaaaaaaaaaaaa",
  )
  assert string.contains(
    people_section,
    "active · key bbbbbbbbbbbbbbbb · joined 2h ago",
  )
  assert string.contains(people_section, "invited · claim open, 50 min left")
  assert string.contains(people_section, "invitation expired")
  assert string.contains(people_section, "no credential")
  assert count(people_section, "<li") == 5
  assert count(html, ">Cara<") == 1

  assert string.contains(sessions_section, "review auth")
  assert string.contains(sessions_section, "notes")
  assert string.contains(sessions_section, "Choose a session")
}

// The owner's row offers no action. A member's actions follow what the member
// holds: an active credential can be rotated or revoked, an open claim can only
// be voided, and a member with neither can be given a new claim.
pub fn each_person_is_offered_the_changes_that_fit_what_they_hold_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)

  // Bob is active, Cara's claim is open, Dan's expired and Eve has none.
  assert count(html, ">Rotate<") == 3
  assert count(html, ">Revoke access<") == 1
  assert count(html, ">Void invitation<") == 1
}

// An identity is drawn as its prefix and eight characters with the whole in the
// `title`, so a long owner identity does not fill the row (round 4, F85).
pub fn a_long_identity_is_drawn_short_with_the_whole_in_its_title_test() {
  let long =
    "owner-2056528fe1be0db0f7105a24da3aac4dcf722898c6655129c0eabc6231181a05"
  let start =
    admin.Start(..start(), read: fn(_, deliver) {
      deliver(grants.Read(
        grants.Snapshot(..snapshot(None), principals: [
          grants.Principal(
            long,
            "Owner",
            grants.OwnerKind,
            grants.Active("aaaaaaaaaaaaaaaa", None),
          ),
          grants.Principal(
            "guest-956fb176",
            "Priya",
            grants.MemberKind,
            grants.Active("bbbbbbbbbbbbbbbb", None),
          ),
        ]),
      ))
    })
  let #(model, _) = opened(start)
  let html = drawn(model)
  assert string.contains(html, ">owner-2056528f<")
  assert string.contains(html, "title=\"" <> long <> "\"")
  assert !string.contains(html, ">" <> long <> "<")
  assert string.contains(html, ">guest-956fb176<")
}

// Names are the peers': drawn as text nodes, escaped, and never an attribute, a
// class or a key. The same holds for a session's name and for the claim's
// principal.
pub fn a_name_is_only_ever_a_text_node_test() {
  let hostile = "<img src=x onerror=alert(1)> \"quoted\" & 'single'"
  let start =
    admin.Start(..start(), read: fn(_, deliver) {
      deliver(
        grants.Read(
          grants.Snapshot(
            principals: [
              grants.Principal(
                "evil",
                hostile,
                grants.MemberKind,
                grants.ClaimOpen(60_000),
              ),
            ],
            more_principals: grants.Whole,
            sessions: [entry(session, hostile, Live)],
            selection: Some(grants.Selection(
              session:,
              holders: [grants.Holder("evil", hostile, invites.Observer)],
              more: grants.Whole,
              scope: creations.Shareable,
            )),
            logins: [],
            summaries: [],
          ),
        ),
      )
    })
  let #(model, _) = opened(start)
  let model = run(model, admin.Choosing(session))
  let model = run(model, admin.Arming(grants.RevokeCredentials("evil")))
  let html = drawn(model)
  assert !string.contains(html, "<img")
  assert !string.contains(html, "onerror=alert(1)>")
  assert string.contains(html, "&lt;img src=x onerror=alert(1)&gt;")
  assert string.contains(html, "&quot;quoted&quot;")
  assert string.contains(html, "&amp;")

  // The name is in the armed button's words, as text.
  assert string.contains(html, "Void &lt;img")
}

// Choosing a session reads its members at once and draws them with the role
// each holds and the change that fits it: a role raised for an observer and
// lowered for an operator, and a removal, and the form that invites someone in.
pub fn choosing_a_session_reads_and_draws_its_members_test() {
  let reads = process.new_subject()
  let #(model, _) =
    opened(start_with(reads, process.new_subject(), grants.Changed))
  assert process.receive(reads, 0) == Ok(None)
  let model = run(model, admin.Choosing(session))
  assert process.receive(reads, 0) == Ok(Some(session))
  let html = drawn(model)
  assert string.contains(html, "Members of review auth")
  assert string.contains(html, ">Make operator<")
  assert string.contains(html, ">Make observer<")
  assert count(html, ">Remove<") == 2
  assert string.contains(html, "Invite someone to review auth")
  assert string.contains(html, "name=\"role\"")
  assert string.contains(html, "name=\"name\"")
  assert string.contains(html, "aria-current=\"true\"")
  assert !string.contains(html, "Choose a session")
}

// A session the catalogue no longer holds is forgotten: the next read finds no
// members, so the page goes back to asking for a choice.
pub fn a_chosen_session_that_is_gone_is_forgotten_test() {
  let start =
    admin.Start(..start(), read: fn(_, deliver) {
      deliver(grants.Read(grants.Snapshot(..snapshot(None), selection: None)))
    })
  let #(model, _) = opened(start)
  let model = run(model, admin.Choosing(session))
  let html = drawn(model)
  assert string.contains(html, "Choose a session")
  assert !string.contains(html, "Members of")
}

// An ask goes to the daemon once. While it is out every button is drawn
// disabled and carries no handler, a second ask asks nothing, and the answer
// clears it, words the result and reads again.
pub fn an_ask_is_made_once_and_its_buttons_wait_for_it_test() {
  let acts = process.new_subject()
  let reads = process.new_subject()
  let pending = process.new_subject()
  let start =
    admin.Start(
      ..start_with(reads, acts, grants.Changed),
      act: fn(action, deliver) {
        process.send(acts, action)
        process.send(pending, deliver)
      },
    )
  let #(model, _) = opened(start)
  let model = run(model, admin.Choosing(session))
  let action = grants.SetRole(session, "bob", invites.Operator)
  let model = run(model, admin.Asking(action))
  assert process.receive(acts, 0) == Ok(action)

  // The second ask, and a revocation armed meanwhile, ask nothing.
  let model = run(model, admin.Asking(grants.Rotate("cara")))
  let model = run(model, admin.Arming(grants.RevokeCredentials("cara")))
  assert process.receive(acts, 0) == Error(Nil)
  let html = drawn(model)
  assert !string.contains(html, "Revoke cara")

  // Every button is disabled and the only handlers are the page's own, which
  // are the session rows and the form.
  assert string.contains(html, "disabled")
  let clicks =
    list.filter(handlers(admin.view(model)), string.ends_with(_, "\nclick"))
  assert list.length(clicks) == 2 as "only the two session rows carry a press"

  // The answer arrives from the daemon's task: it clears the ask, words the
  // change and reads again.
  let assert Ok(deliver) = process.receive(pending, 0)
  let _ = deliver
  let model = run(model, admin.Acted(grants.Changed))
  assert string.contains(drawn(model), "Role changed.")
  assert process.receive(reads, 0) == Ok(None)
  assert process.receive(reads, 0) == Ok(Some(session))
  assert process.receive(reads, 0) == Ok(Some(session))
  let model = run(model, admin.Asking(grants.Rotate("cara")))
  assert process.receive(acts, 0) == Ok(grants.Rotate("cara"))
  let _ = model
}

// The refusal of an allowance that is spent: three grants, and the Unix time
// 1_790_030_460_000 ms, which is 22:41 UTC.
fn too_many() -> grants.Reason {
  grants.TooMany(used: 3, free_at_ms: 1_790_030_460_000)
}

// A refusal is worded in the reason's fixed words and nothing else, and the page
// reads again so it stops drawing what is gone.
pub fn a_refusal_is_worded_in_fixed_words_test() {
  let reads = process.new_subject()
  let #(model, _) =
    opened(start_with(reads, process.new_subject(), grants.Declined(too_many())))
  let model = run(model, admin.Asking(grants.Rotate("cara")))
  let html = drawn(model)
  assert string.contains(html, "3 grants in the last hour")

  // The instant travels as a number the browser words in its own zone, with the
  // UTC time as the element's title and its light text; the server guesses no zone.
  assert string.contains(
    html,
    "<loom-time at=\"1790030460000\" title=\"22:41 UTC\">22:41 UTC</loom-time>",
  )
  assert string.contains(html, grants.throttle_tail)
  assert !string.contains(html, "loomclaim_")
  assert process.receive(reads, 0) == Ok(None)
  assert process.receive(reads, 0) == Ok(None)
}

// A revocation is two presses. The first shows what it will do in words that name
// the person and asks nothing; Cancel puts it back; the second sends it. Choosing
// another session, or a read that no longer lists the person, takes it back too.
pub fn a_revocation_is_two_presses_test() {
  let acts = process.new_subject()
  let #(model, _) =
    opened(start_with(process.new_subject(), acts, grants.Changed))
  let model = run(model, admin.Choosing(session))
  let revoke = grants.RevokeMembership(session, "bob")

  let armed = run(model, admin.Arming(revoke))
  assert process.receive(acts, 0) == Error(Nil)
  let html = drawn(armed)
  assert string.contains(html, "Remove Bob from review auth")
  assert string.contains(html, ">Cancel<")

  let cancelled = run(armed, admin.Disarming)
  assert !string.contains(drawn(cancelled), "Remove Bob from review auth")
  assert process.receive(acts, 0) == Error(Nil)

  let sent = run(armed, admin.Asking(revoke))
  assert process.receive(acts, 0) == Ok(revoke)
  assert !string.contains(drawn(sent), "Remove Bob from review auth")

  // Choosing another session takes it back.
  let moved = run(armed, admin.Choosing(other_session))
  assert !string.contains(drawn(moved), "Remove Bob from review auth")
}

// An armed revocation survives a refresh that still lists what it names, and goes
// when the read no longer does.
pub fn an_armed_revocation_follows_what_it_names_test() {
  let #(model, _) = opened(start())
  let model = run(model, admin.Choosing(session))
  let armed = run(model, admin.Arming(grants.RevokeCredentials("bob")))
  assert string.contains(drawn(armed), "Revoke Bob&#39;s access")
    || string.contains(drawn(armed), "Revoke Bob's access")
  let refreshed = run(armed, admin.Ticked)
  assert string.contains(drawn(refreshed), "access")
  assert count(drawn(refreshed), ">Cancel<") == 1

  // A read without Bob takes the armed button back.
  let without =
    admin.Start(..start(), read: fn(_, deliver) {
      deliver(grants.Read(
        grants.Snapshot(
          ..snapshot(Some(session)),
          principals: list.filter(people(), fn(row) { row.id != "bob" }),
        ),
      ))
    })
  let #(other, _) = opened(without)
  let other = run(other, admin.Choosing(session))
  let other = run(other, admin.Arming(grants.RevokeCredentials("bob")))
  assert count(drawn(other), ">Cancel<") == 0
}

// A claim an ask made is on screen once, in copy boxes, until the owner hides it;
// a read, another ask and a refresh leave it there, and hiding it leaves no trace
// of the token in the page.
pub fn a_claim_is_shown_once_and_dropped_when_hidden_test() {
  let claim =
    grants.Claim(
      principal: "guest-1a2b3c4d",
      purpose: grants.Invited(invites.Operator),
      page: "http://127.0.0.1:4000/ui/claim",
      command: "loom claim --addr ws://127.0.0.1:4000/v2/control",
      token:,
      expires_in_ms: 3_600_000,
    )
  let #(model, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Claimed(claim),
    ))
  assert !string.contains(drawn(model), "loomclaim_")
  let model =
    run(model, admin.Asking(grants.Invite(session, invites.Operator, "")))
  assert admin.claim(model) == Some(claim)
  let html = drawn(model)
  assert count(html, token) == 1
  assert string.contains(html, "text=\"" <> token <> "\"")
  assert string.contains(html, "subject=\"token\"")
  assert string.contains(html, "subject=\"command\"")
  assert string.contains(html, "subject=\"claim-address\"")
  assert string.contains(html, "text=\"http://127.0.0.1:4000/ui/claim\"")
  assert string.contains(html, "Open this address and paste the token:")
  assert string.contains(html, "Or, with loom installed")
  assert string.contains(html, "Invitation ready")
  assert string.contains(html, "Principal: guest-1a2b3c4d.")
  assert !string.contains(html, "Role: operator")
  assert string.contains(html, "<loom-reveal></loom-reveal>")
  assert string.contains(html, "valid for 60 minutes")
  assert string.contains(html, "outside Loom")
  assert string.contains(html, "Hide the token")

  // A refresh and a later answer leave it as it was, and still once.
  let refreshed = run(model, admin.Ticked)
  assert count(drawn(refreshed), token) == 1

  // The button that hides it takes it out of the model and the tree.
  let hidden = run(refreshed, admin.Dismissed)
  assert admin.claim(hidden) == None
  assert !string.contains(drawn(hidden), "loomclaim_")
  assert !string.contains(drawn(hidden), "Hide the token")
}

// A rotation's claim says so, and a page that was never given a claim never
// draws one: the catalogue's reads carry none.
pub fn a_rotation_is_worded_as_one_and_a_read_carries_no_claim_test() {
  let claim =
    grants.Claim(
      principal: "bob",
      purpose: grants.Rotated,
      page: "http://127.0.0.1:4000/ui/claim",
      command: "loom claim --addr ws://127.0.0.1:4000/v2/control",
      token:,
      expires_in_ms: 3_600_000,
    )
  let #(model, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Claimed(claim),
    ))
  assert !string.contains(drawn(model), "loomclaim_")
  assert !string.contains(drawn(run(model, admin.Ticked)), "loomclaim_")
  let model = run(model, admin.Asking(grants.Rotate("bob")))
  let html = drawn(model)
  assert string.contains(html, "New claim ready")
  assert string.contains(html, "Their earlier credentials no longer work.")
}

// One read runs at a time. A tick while one is out only arms the timer again, a
// press asks for one more read (a flag, not a queue), and that read starts when
// the answer lands, however many presses and ticks came in between.
pub fn only_one_read_runs_at_a_time_test() {
  let reads = process.new_subject()
  let start =
    admin.Start(..start(), read: fn(chosen, _) { process.send(reads, chosen) })
  let timer = process.new_subject()
  let model = run(admin.new(start), admin.TimerReady(timer))
  assert process.receive(reads, 0) == Ok(None)

  // Ticks and presses while the first read is out start nothing.
  let model = run(model, admin.Ticked)
  let model = run(model, admin.Ticked)
  let model = run(model, admin.Choosing(session))
  let model = run(model, admin.Choosing(session))
  assert process.receive(reads, 0) == Error(Nil)

  // The answer lands: the one wanted read starts, under the chosen session, once.
  let model = run(model, admin.Answered(1, grants.Read(snapshot(None))))
  assert process.receive(reads, 0) == Ok(Some(session))
  assert process.receive(reads, 0) == Error(Nil)

  // The first read found no members, because it was asked before the press. They
  // are not drawn under the new choice, and the choice is kept.
  assert !string.contains(drawn(model), "Members of review auth")

  // With nothing wanted, an answer starts nothing, and the next tick reads.
  let model =
    run(model, admin.Answered(2, grants.Read(snapshot(Some(session)))))
  assert string.contains(drawn(model), "Members of review auth")
  assert process.receive(reads, 0) == Error(Nil)
  let model = run(model, admin.Ticked)
  assert process.receive(reads, 0) == Ok(Some(session))
  let _ = model
}

// A read that was overtaken is dropped: the page keeps the answer to the latest
// read it asked for, whatever its number.
pub fn an_overtaken_read_is_dropped_test() {
  let start = admin.Start(..start(), read: fn(_, _) { Nil })
  let timer = process.new_subject()
  let model = run(admin.new(start), admin.TimerReady(timer))
  let model = run(model, admin.Answered(1, grants.Read(snapshot(None))))
  let model = run(model, admin.Ticked)

  // Read two is out. A late answer numbered one changes nothing.
  let model = run(model, admin.Answered(1, grants.Closed(ending.AccessRevoked)))
  assert admin.status(model) == admin.Connected
  let model = run(model, admin.Answered(2, grants.Read(snapshot(None))))
  assert admin.status(model) == admin.Connected
}

// A read that cannot be answered leaves the page as it was: a page that has not
// connected stays so, and one that has keeps its snapshot.
pub fn an_unread_read_changes_nothing_test() {
  let unread =
    admin.Start(..start(), read: fn(_, deliver) { deliver(grants.Unread) })
  let #(waiting, _) = opened(unread)
  assert admin.status(waiting) == admin.Connecting
  assert string.contains(drawn(waiting), "Reading the catalogue.")

  let #(connected, _) = opened(start())
  let again = run(connected, admin.Answered(1, grants.Unread))
  assert admin.status(again) == admin.Connected
  assert string.contains(drawn(again), "Olive Owner")
}

// A page that can no longer be served draws why, in the admin page's words, and
// asks for nothing more: not a read, not a change, not a revocation armed.
pub fn a_page_that_ended_asks_nothing_more_test() {
  let acts = process.new_subject()
  let reads = process.new_subject()
  let #(model, _) = opened(start_with(reads, acts, grants.Changed))
  assert process.receive(reads, 0) == Ok(None)
  let ended = run(model, admin.Answered(1, grants.Closed(ending.PageEnded)))
  assert admin.status(ended) == admin.Ended(ending.PageEnded)
  let html = drawn(ended)
  assert string.contains(html, "disconnected")
  assert string.contains(html, ending.admin_headline(ending.PageEnded))
  assert string.contains(html, "fifteen minutes")

  let ended = run(ended, admin.Ticked)
  let ended = run(ended, admin.Choosing(session))
  let ended = run(ended, admin.Asking(grants.Rotate("bob")))
  let ended = run(ended, admin.Arming(grants.RevokeCredentials("bob")))
  assert process.receive(reads, 0) == Error(Nil)
  assert process.receive(acts, 0) == Error(Nil)
  assert admin.status(ended) == admin.Ended(ending.PageEnded)
}

// The refresh is a timer: each tick reads again and arms the next, and a page
// that ended arms none.
pub fn the_timer_reads_and_rearms_test() {
  let reads = process.new_subject()
  let #(model, timer) =
    opened(start_with(reads, process.new_subject(), grants.Changed))
  assert process.receive(reads, 0) == Ok(None)
  assert process.receive(timer, 100) == Ok(Nil)
  let model = run(model, admin.Ticked)
  assert process.receive(reads, 0) == Ok(None)
  assert process.receive(timer, 100) == Ok(Nil)

  let ended = run(model, admin.Answered(2, grants.Closed(ending.AccessRevoked)))
  let _ = run(ended, admin.Ticked)
  assert process.receive(reads, 0) == Error(Nil)
  assert process.receive(timer, 50) == Error(Nil)
}

// Every handler on the page is a click or a submit beneath the body, the one
// region the daemon's socket admits: none is in the bar, the notice's place or
// anywhere else, with a session chosen, a revocation armed, a claim shown and a
// notice drawn.
pub fn every_handler_is_beneath_the_body_test() {
  let claim =
    grants.Claim(
      principal: "guest-1a2b3c4d",
      purpose: grants.Invited(invites.Observer),
      page: "http://127.0.0.1:4000/ui/claim",
      command: "loom claim --addr ws://127.0.0.1:4000/v2/control",
      token:,
      expires_in_ms: 3_600_000,
    )
  let #(model, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Claimed(claim),
    ))
  let model = run(model, admin.Choosing(session))
  let model = run(model, admin.Asking(grants.Rotate("bob")))
  let model = run(model, admin.Arming(grants.RevokeMembership(session, "bob")))
  let keys = handlers(admin.view(model))
  assert keys != []
  assert list.all(keys, fn(key) {
    string.starts_with(key, admin.body_path <> "\t")
    && { string.ends_with(key, "\nclick") || string.ends_with(key, "\nsubmit") }
  })
  assert list.any(keys, string.ends_with(_, "\nsubmit"))

  // The body is where it was pinned, whether or not a notice is drawn above it.
  assert admin.body_path == "0\t2\t1"
  let #(refused, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Declined(grants.NotOwner),
    ))
  let refused = run(refused, admin.Choosing(session))
  let refused = run(refused, admin.Asking(grants.Rotate("bob")))
  assert string.contains(drawn(refused), grants.reason_words(grants.NotOwner))
  assert list.all(handlers(admin.view(refused)), string.starts_with(
    _,
    admin.body_path <> "\t",
  ))
}

// A principal that holds browser logins lists them beneath its row
// (protocol-change/065, the eighth pull request): the history in the home's own
// words, "This browser" on the login the page was opened from, a two-step
// "Revoke sign-in" button for each that asks the one change the daemon checks,
// and a line saying so when more exist than the page lists.
pub fn a_principals_sign_ins_are_listed_with_a_two_step_revoke_test() {
  let mine =
    signins.Signin(
      fingerprint: "aaaaaaaaaaaaaaaa",
      issued_at_ms: 7_000_000,
      last_resumed_ms: Some(7_200_000),
      expires_at_ms: Some(7_400_000 + 86_400_000),
      issued_by: None,
    )
  let theirs =
    signins.Signin(
      ..mine,
      fingerprint: "bbbbbbbbbbbbbbbb",
      issued_by: Some("cc"),
    )
  let acts = process.new_subject()
  let start =
    admin.Start(
      ..start_with(process.new_subject(), acts, grants.Changed),
      login: Some("aaaaaaaaaaaaaaaa"),
      read: fn(_, deliver) {
        deliver(grants.Read(
          grants.Snapshot(..snapshot(None), logins: [
            grants.Logins("owner", 1, [mine]),
            grants.Logins("bob", 12, [theirs]),
          ]),
        ))
      },
    )
  let #(model, _) = opened(start)
  let html = drawn(model)
  assert string.contains(html, "Sign-ins")
  assert string.contains(html, "This browser")
  assert string.contains(html, "aaaaaaaaaaaaaaaa")
  assert string.contains(html, "bbbbbbbbbbbbbbbb")
  assert string.contains(html, "device link")
  assert count(html, ">Revoke sign-in<") == 2
  assert string.contains(html, "More sign-ins exist than this page lists")

  // A revocation is two presses, as every revocation on the page is.
  let revoke = grants.RevokeSignin("bob", "bbbbbbbbbbbbbbbb")
  let armed = run(model, admin.Arming(revoke))
  assert process.receive(acts, 0) == Error(Nil)
  assert string.contains(drawn(armed), "Revoke this sign-in of Bob")
  let sent = run(armed, admin.Asking(revoke))
  assert process.receive(acts, 0) == Ok(revoke)
  assert string.contains(drawn(sent), grants.changed_words(revoke))

  // A read that no longer lists the sign-in takes the armed button back.
  let refreshed =
    admin.Start(..start, read: fn(_, deliver) {
      deliver(grants.Read(snapshot(None)))
    })
  let #(other, _) = opened(refreshed)
  let other = run(other, admin.Arming(revoke))
  assert count(drawn(other), ">Cancel<") == 0

  // Every handler stays beneath the one region the socket admits.
  assert list.all(handlers(admin.view(armed)), string.starts_with(
    _,
    admin.body_path <> "\t",
  ))
}

// The page's own words stay out of the page's attributes: no handler's path
// holds a name, and no class is made from one. The people's rows are keyed by the
// catalogue's identity and by nothing else.
pub fn no_identity_reaches_an_attribute_test() {
  let #(model, _) = opened(start())
  let model = run(model, admin.Choosing(session))
  let html = drawn(model)
  assert !string.contains(html, "class=\"bob")
  assert !string.contains(html, "id=\"bob")

  // The only keys are the people's catalogue identities, one for each row of the
  // list, and the invitation's two fixed words (a form numbered by how many
  // invitations were made, and its notice); no name or session is one.
  assert count(html, "key=\"") == 7
  assert string.contains(html, "key=\"invite-0\"")
  assert string.contains(html, "key=\"notice\"")
  assert !string.contains(html, "key=\"Bob")
  assert !string.contains(html, session <> "\"")
  assert !string.contains(html, "href")
}

// The invitation form takes exactly a name and a role the page offered, and
// refuses everything else, so the daemon never sees a role that is not one of the
// two or a field the form does not have.
pub fn the_invitation_form_takes_exactly_a_name_and_a_role_test() {
  assert admin_sessions.fields([#("name", "Ana"), #("role", "operator")])
    == Ok(#("Ana", invites.Operator))
  assert admin_sessions.fields([#("name", ""), #("role", "observer")])
    == Ok(#("", invites.Observer))
  assert admin_sessions.fields([#("role", "observer"), #("name", "x")])
    == Ok(#("x", invites.Observer))

  list.each(
    [
      [],
      [#("name", "Ana")],
      [#("role", "observer")],
      [#("name", "Ana"), #("role", "owner")],
      [#("name", "Ana"), #("role", "Observer")],
      [#("name", "Ana"), #("role", "")],
      [#("name", "Ana"), #("role", "operator"), #("extra", "x")],
      [#("name", "Ana"), #("name", "Bo"), #("role", "operator")],
      [#("name", "Ana"), #("role", "operator"), #("role", "observer")],
      [#("text", "Ana"), #("role", "operator")],
    ],
    fn(listed) {
      assert admin_sessions.fields(listed) == Error(Nil)
    },
  )
}

// The home's "Admin" button and this page are two ends of one pair, and neither
// moves the other's paths: the page's body is the home's table's own place, and
// the button is in the bar the page does not draw a handler in.
pub fn the_two_pages_pin_their_paths_apart_test() {
  assert admin.body_path == home.table_path
  assert home.admin_path == "0\t0\t5"
  let #(model, _) = opened(start())
  let model = run(model, admin.Choosing(session))
  assert !list.any(handlers(admin.view(model)), string.starts_with(
    _,
    home.admin_path,
  ))
}

// The bar's trailing child is Back, a `<loom-back>` that mints nothing: the
// page draws no handler for it, so the daemon is never asked for a ticket.
pub fn the_bar_ends_with_a_back_control_that_sends_nothing_test() {
  let html = drawn(admin.new(start()))
  assert string.contains(html, "<loom-back>Home</loom-back>")
}

// An invitation's claim is drawn in the Sessions section, under the form that
// made it, and a rotation's under the row of the person it rotated. Neither
// moves to the top of the page, and neither is drawn where it does not belong.
pub fn a_claim_is_drawn_beside_the_action_that_made_it_test() {
  let invited =
    grants.Claim(
      principal: "guest-1a2b3c4d",
      purpose: grants.Invited(invites.Observer),
      page: "http://127.0.0.1:4000/ui/claim",
      command: "loom claim --addr ws://127.0.0.1:4000/v2/control",
      token:,
      expires_in_ms: 3_600_000,
    )
  let #(model, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Claimed(invited),
    ))
  let model = run(model, admin.Choosing(session))
  let model =
    run(model, admin.Asking(grants.Invite(session, invites.Observer, "")))
  let html = drawn(model)
  let assert [people, sessions] = string.split(html, ">Sessions<")
  assert !string.contains(people, token)
  let assert [before_form, after_form] =
    string.split(sessions, "aria-label=\"Invite to this session\"")
  assert !string.contains(before_form, token)
  assert string.contains(after_form, token)
  assert string.contains(after_form, ">Hide the token<")

  // A rotation's claim is in the row of the person, before the next row.
  let rotated =
    grants.Claim(..invited, principal: "bob", purpose: grants.Rotated)
  let #(model, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Claimed(rotated),
    ))
  let model = run(model, admin.Asking(grants.Rotate("bob")))
  let html = drawn(model)
  let assert [before_bob, from_bob] = string.split(html, ">Bob<")
  assert !string.contains(before_bob, token)
  let assert [bobs_row, later_rows] = string.split(from_bob, ">Cara<")
  assert string.contains(bobs_row, token)
  assert !string.contains(later_rows, token)
  assert count(html, token) == 1
}

// Nothing on the page is sticky or covers a list, and a private session draws no
// form: the sentence that says why is drawn in its place (round 4, F88).
pub fn a_private_session_draws_no_invitation_form_test() {
  let private =
    admin.Start(..start(), read: fn(chosen, deliver) {
      deliver(grants.Read(
        grants.Snapshot(
          ..snapshot(chosen),
          selection: option.map(snapshot(chosen).selection, fn(held) {
            grants.Selection(..held, scope: creations.Private)
          }),
        ),
      ))
    })
  let #(model, _) = opened(private)
  let model = run(model, admin.Choosing(session))
  let html = drawn(model)
  assert string.contains(html, "Members of review auth")
  assert string.contains(html, "Private session: it shares the workspace")
  assert !string.contains(html, "name=\"role\"")
  assert !string.contains(html, "Create invitation")
  assert !list.any(handlers(admin.view(model)), string.ends_with(_, "\nsubmit"))
  assert !string.contains(html, "sticky")

  // A shareable session draws the form.
  let #(shared, _) = opened(start())
  let shared = run(shared, admin.Choosing(session))
  assert string.contains(drawn(shared), "Create invitation")
  assert !string.contains(drawn(shared), "Private session")
}

// A change that was made is a quiet line under the section acted on, a refusal is
// the danger line beside its control, and neither is a box at the top of the page,
// where the centre's first child is nothing (round 4, F78).
pub fn a_notice_is_a_line_beside_what_was_acted_on_test() {
  let #(model, _) = opened(start())
  let model = run(model, admin.Choosing(session))
  let model =
    run(model, admin.Asking(grants.SetRole(session, "bob", invites.Operator)))
  let model = run(model, admin.Acted(grants.Changed))
  let html = drawn(model)
  assert !string.contains(html, "home-notice")
  assert string.contains(
    html,
    "<p class=\"notice-line\" role=\"status\">Role changed.</p>",
  )
  let assert [_, members] = string.split(html, "Members of review auth")
  assert string.contains(members, "Role changed.")

  let #(refused, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Declined(too_many()),
    ))
  let refused = run(refused, admin.Choosing(session))
  let refused =
    run(refused, admin.Asking(grants.Invite(session, invites.Observer, "")))
  let html = drawn(refused)
  assert string.contains(html, "notice-refusal")
  assert !string.contains(html, "notice-line")
  let assert [before_form, after_form] =
    string.split(html, "aria-label=\"Invite to this session\"")
  assert !string.contains(before_form, "notice-refusal")
  assert string.contains(after_form, "3 grants in the last hour")
}

// The token is in the frame that shows it and in no later frame: the patch that
// draws the claim carries it once, and neither a refresh that finds the people
// changed nor the page's own re-render after it carries it again.
pub fn the_token_is_in_one_patch_and_no_other_test() {
  let claim =
    grants.Claim(
      principal: "guest-1a2b3c4d",
      purpose: grants.Invited(invites.Observer),
      page: "http://127.0.0.1:4000/ui/claim",
      command: "loom claim --addr ws://127.0.0.1:4000/v2/control",
      token:,
      expires_in_ms: 3_600_000,
    )
  let feed = process.new_subject()
  let start =
    admin.Start(
      ..start_with(
        process.new_subject(),
        process.new_subject(),
        grants.Claimed(claim),
      ),
      read: fn(chosen, deliver) {
        let rows = case process.receive(feed, 0) {
          Ok(rows) -> rows
          Error(Nil) -> people()
        }
        deliver(grants.Read(
          grants.Snapshot(..snapshot(chosen), principals: rows),
        ))
      },
    )
  let #(model, _) = opened(start)
  let model = run(model, admin.Choosing(session))
  let before = admin.view(model)
  let cache = first(before)
  let shown_model =
    run(model, admin.Asking(grants.Invite(session, invites.Observer, "")))
  let shown = admin.view(shown_model)
  let #(patch, cache) = patch_text(cache, before, shown)
  assert count(patch, token) == 1

  // A refresh whose read lists one more person ahead of the others is a
  // different tree around the same claim.
  process.send(feed, [
    grants.Principal("aaron", "Aaron", grants.MemberKind, grants.NoCredential),
    ..people()
  ])
  let refreshed = run(shown_model, admin.Ticked)
  let #(patch, cache) = patch_text(cache, shown, admin.view(refreshed))
  assert string.contains(patch, "Aaron") as "the refresh landed"
  assert !string.contains(patch, "loomclaim_")

  // Hiding it is a patch that removes it and carries no token either.
  let hidden = run(refreshed, admin.Dismissed)
  let #(patch, _) = patch_text(cache, admin.view(refreshed), admin.view(hidden))
  assert !string.contains(patch, "loomclaim_")
}

// After the daemon refuses a grant for want of allowance, the buttons that
// would grant carry the refusal's words in their `title` until the time a place
// frees, so the owner reads when the next is free before pressing, and the
// buttons that only reduce access carry nothing. Once the time has passed they
// carry nothing (round 4, F89).
pub fn the_buttons_that_grant_carry_the_refusal_while_the_allowance_is_spent_test() {
  let words = grants.reason_words(too_many())
  let #(model, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Declined(too_many()),
    ))
  let model = run(model, admin.Choosing(session))
  assert !string.contains(drawn(model), "title=\"" <> words <> "\"")
  let model = run(model, admin.Asking(grants.Rotate("dan")))
  let html = drawn(model)

  // Rotate (three people), Make operator (Bob) and Create invitation carry it;
  // Revoke access, Remove, Make observer and Void invitation do not.
  assert count(html, "title=\"" <> words <> "\"") == 5
  assert count(html, ">Rotate<") == 3
  assert count(html, ">Revoke access<") == 1

  // A refusal whose time has passed marks nothing.
  let #(passed, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Declined(grants.TooMany(used: 3, free_at_ms: 1000)),
    ))
  let passed = run(passed, admin.Choosing(session))
  let passed = run(passed, admin.Asking(grants.Rotate("dan")))
  assert !string.contains(drawn(passed), "title=\"3 grants")
}

// A rotation's claim is the last child of the person's row. A refresh that lists
// a new principal ahead of that person moves the row, and the patch that moves it
// must not carry the token again: the list is keyed by identity, so the row moves
// with its box and no content is sent.
pub fn a_rotation_claim_is_not_resent_when_a_row_is_inserted_ahead_test() {
  let claim =
    grants.Claim(
      principal: "bob",
      purpose: grants.Rotated,
      page: "http://127.0.0.1:4000/ui/claim",
      command: "loom claim --addr ws://127.0.0.1:4000/v2/control",
      token:,
      expires_in_ms: 3_600_000,
    )
  let feed = process.new_subject()
  let start =
    admin.Start(
      ..start_with(
        process.new_subject(),
        process.new_subject(),
        grants.Claimed(claim),
      ),
      read: fn(chosen, deliver) {
        let rows = case process.receive(feed, 0) {
          Ok(rows) -> rows
          Error(Nil) -> people()
        }
        deliver(grants.Read(
          grants.Snapshot(..snapshot(chosen), principals: rows),
        ))
      },
    )
  let #(model, _) = opened(start)
  let before = admin.view(model)
  let cache = first(before)
  let shown_model = run(model, admin.Asking(grants.Rotate("bob")))
  let shown = admin.view(shown_model)
  let #(patch, cache) = patch_text(cache, before, shown)
  assert count(patch, token) == 1

  process.send(feed, [
    grants.Principal("aaron", "Aaron", grants.MemberKind, grants.NoCredential),
    ..people()
  ])
  let refreshed = run(shown_model, admin.Ticked)
  let #(patch, _) = patch_text(cache, shown, admin.view(refreshed))
  assert string.contains(patch, "Aaron") as "the refresh landed"
  assert !string.contains(patch, "loomclaim_")
}

// The page's lifetime is a quiet pill in the bar, counted down in the browser
// by `<loom-elapsed remaining>` from the milliseconds left when the read was
// taken; the body has no sentence about it. Before the first read the pill is
// not drawn, since there is no time yet to count from.
pub fn the_bar_says_when_the_page_ends_in_a_counted_pill_test() {
  let reads = process.new_subject()
  let acts = process.new_subject()
  let model = admin.new(start_with(reads, acts, grants.Changed))
  let html = drawn(model)
  assert !string.contains(html, "ends in")
  assert !string.contains(html, "loom-elapsed")

  let #(model, _) = opened(start_with(reads, acts, grants.Changed))
  let html = drawn(model)
  assert string.contains(
    html,
    "ends in <loom-elapsed remaining=\"840000\"></loom-elapsed>",
  )
  assert !string.contains(html, "fifteen minutes")
  assert !string.contains(html, "admin-note")
}

// Every row has a Rename button, the owner's own included, and pressing one opens
// a form in that row only (protocol-change/065, the tenth pull request): the
// person's name is a text node in the lead, `<loom-rename>` fills the field in the
// browser and no attribute holds the name. One form is open at a time, Cancel
// closes it, and the form's one handler is a submit beneath the body.
pub fn each_row_offers_rename_and_one_form_opens_at_a_time_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert count(html, ">Rename<") == 5
    as "one button for each of the five people"
  assert !string.contains(html, "<form")

  let model = run(model, admin.Editing("bob"))
  let html = drawn(model)
  assert count(html, "<form") == 1
  assert string.contains(html, "Rename <span data-loom-name>Bob</span>")
  assert string.contains(html, "data-loom-renames")
  assert string.contains(html, "<loom-rename><input")
  assert string.contains(html, "name=\"text\"")
  assert !string.contains(html, " value=")
  assert !string.contains(html, "placeholder=\"Bob")
  let keys = handlers(admin.view(model))
  assert list.any(keys, string.ends_with(_, "\nsubmit"))
  assert list.all(keys, string.starts_with(_, admin.body_path <> "\t"))

  // The owner's row has one too, since the owner may rename itself.
  let model = run(model, admin.Editing("owner"))
  let html = drawn(model)
  assert count(html, "<form") == 1
  assert string.contains(html, "Rename <span data-loom-name>Olive Owner</span>")
  assert !string.contains(html, "<span data-loom-name>Bob</span>")

  let model = run(model, admin.EditCancelled)
  assert !string.contains(drawn(model), "<form")
}

// A submit asks the daemon to rename the principal the server drew, with the
// typed text and nothing else. A change closes the form and says so in the row; a
// refusal leaves the form open, in fixed words, so the name can be corrected.
pub fn a_rename_asks_for_the_drawn_principal_and_closes_on_success_test() {
  let acts = process.new_subject()
  let #(model, _) =
    opened(start_with(process.new_subject(), acts, grants.Changed))
  let model = run(model, admin.Editing("bob"))
  let model = run(model, admin.Asking(grants.Rename("bob", "Robert")))
  assert process.receive(acts, 0) == Ok(grants.Rename("bob", "Robert"))
  let html = drawn(model)
  assert string.contains(html, "Renamed.")
  assert !string.contains(html, "<form")

  let acts = process.new_subject()
  let #(refused, _) =
    opened(start_with(
      process.new_subject(),
      acts,
      grants.Declined(grants.InvalidName),
    ))
  let refused = run(refused, admin.Editing("bob"))
  let refused = run(refused, admin.Asking(grants.Rename("bob", "")))
  let html = drawn(refused)
  assert string.contains(html, grants.reason_words(grants.InvalidName))
  assert count(html, "<form") == 1
  assert string.contains(html, "Rename <span data-loom-name>Bob</span>")
}

// While an ask is out the buttons wait and no form opens.
pub fn no_form_opens_while_an_ask_is_out_test() {
  let pending = process.new_subject()
  let start =
    admin.Start(..start(), act: fn(action, deliver) {
      process.send(pending, #(action, deliver))
    })
  let #(model, _) = opened(start)
  let model = run(model, admin.Asking(grants.Rotate("cara")))
  let model = run(model, admin.Editing("bob"))
  assert !string.contains(drawn(model), "<form")
}

// A read that no longer lists the person closes its form, and one that still
// does leaves it, so a refresh does not take back a name that is being typed.
pub fn a_read_closes_the_form_of_a_person_who_is_gone_test() {
  let gone = process.new_subject()
  let start =
    admin.Start(..start(), read: fn(chosen, deliver) {
      let snap = snapshot(chosen)
      case process.receive(gone, 0) {
        Ok(Nil) ->
          deliver(grants.Read(
            grants.Snapshot(
              ..snap,
              principals: list.filter(snap.principals, fn(row) {
                row.id != "bob"
              }),
            ),
          ))
        Error(Nil) -> deliver(grants.Read(snap))
      }
    })
  let #(model, _) = opened(start)
  let model = run(model, admin.Editing("bob"))
  let model = run(model, admin.Choosing(session))
  assert string.contains(drawn(model), "<form")
    as "a read that lists bob keeps it"
  process.send(gone, Nil)
  let model = run(model, admin.Choosing(other_session))
  assert !string.contains(drawn(model), "<form")
}

// A name that carries markup is only ever escaped text in the form's lead.
pub fn a_hostile_name_is_text_in_the_rename_form_test() {
  let hostile = "<script>alert(1)</script>"
  let start =
    admin.Start(..start(), read: fn(chosen, deliver) {
      let snap = snapshot(chosen)
      deliver(grants.Read(
        grants.Snapshot(..snap, principals: [
          grants.Principal(
            "bob",
            hostile,
            grants.MemberKind,
            grants.NoCredential,
          ),
        ]),
      ))
    })
  let #(model, _) = opened(start)
  let html = drawn(run(model, admin.Editing("bob")))
  assert !string.contains(html, hostile)
  assert string.contains(html, "&lt;script&gt;alert(1)&lt;/script&gt;")
}

// Each session's row says who holds it and whether it may be shared, after its
// path, from the summary the read made, and a session the read made none for has
// the path alone.
pub fn a_session_row_says_its_people_and_scope_test() {
  let #(model, _) = opened(start())
  let html = drawn(model)
  assert string.contains(html, " · 3 people · shareable")
  assert string.contains(html, " · 1 person · private")

  let bare =
    admin.Start(..start(), read: fn(chosen, deliver) {
      deliver(grants.Read(grants.Snapshot(..snapshot(chosen), summaries: [])))
    })
  let #(model, _) = opened(bare)
  assert !string.contains(drawn(model), " people")
  assert !string.contains(drawn(model), " person")
}

// The words are fixed, and a count that is only a page of the members is a lower
// bound.
pub fn the_summary_words_are_fixed_test() {
  let words = fn(people, more, scope) {
    grants.summary_words(grants.Summary("s", people, more, scope))
  }
  assert words(1, grants.Whole, creations.Private) == "1 person · private"
  assert words(2, grants.Whole, creations.Shareable) == "2 people · shareable"
  assert words(101, grants.Truncated, creations.Shareable)
    == "101+ people · shareable"
}

// The invitation form is a new form once an invitation was made, so its name
// field is empty again; a read leaves the same form. The key is in the form's
// event path, so the path moves with the count, and the page's body path does
// not move.
pub fn an_invitation_opens_a_fresh_form_test() {
  let claim =
    grants.Claim(
      principal: "guest-1a2b3c4d",
      purpose: grants.Invited(invites.Observer),
      page: "http://127.0.0.1:4000/ui/claim",
      command: "loom claim --addr ws://127.0.0.1:4000/v2/control",
      token:,
      expires_in_ms: 3_600_000,
    )
  let #(model, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Claimed(claim),
    ))
  let model = run(model, admin.Choosing(session))
  let submit = fn(model) {
    list.filter(handlers(admin.view(model)), string.ends_with(_, "\nsubmit"))
  }
  let before = submit(model)
  assert list.length(before) == 1

  let refreshed = run(model, admin.Ticked)
  assert submit(refreshed) == before

  let invited =
    run(model, admin.Asking(grants.Invite(session, invites.Observer, "Priya")))
  assert list.length(submit(invited)) == 1
  assert submit(invited) != before
  assert list.all(submit(invited), string.starts_with(
    _,
    admin.body_path <> "\t",
  ))

  // A second invitation is a second fresh form.
  let again =
    run(invited, admin.Asking(grants.Invite(session, invites.Observer, "Ana")))
  assert submit(again) != submit(invited)
}

// The claim box is keyed by how many invitations were made, so a second
// invitation builds a new box and its `<loom-reveal>` runs again.
pub fn a_second_invitation_builds_a_new_claim_box_test() {
  let claim =
    grants.Claim(
      principal: "guest-1a2b3c4d",
      purpose: grants.Invited(invites.Observer),
      page: "http://127.0.0.1:4000/ui/claim",
      command: "loom claim --addr ws://127.0.0.1:4000/v2/control",
      token:,
      expires_in_ms: 3_600_000,
    )
  let #(model, _) =
    opened(start_with(
      process.new_subject(),
      process.new_subject(),
      grants.Claimed(claim),
    ))
  let model = run(model, admin.Choosing(session))
  let first =
    run(model, admin.Asking(grants.Invite(session, invites.Observer, "A")))
  assert string.contains(drawn(first), "key=\"claim-1\"")

  // The claim adds one key to the seven the page has, and no name or identity is
  // a key.
  assert count(drawn(first), "key=\"") == 8
  assert !string.contains(drawn(first), "key=\"guest")
  let second =
    run(first, admin.Asking(grants.Invite(session, invites.Observer, "B")))
  assert string.contains(drawn(second), "key=\"claim-2\"")
  assert !string.contains(drawn(second), "key=\"claim-1\"")

  // A refresh keeps the box, and so its key, where it was.
  assert string.contains(drawn(run(second, admin.Ticked)), "key=\"claim-2\"")
}

// A read of a catalogue whose chosen session is private: the owner's one
// session, with the residency the test names and the chosen one's members.
fn private_snapshot(
  chosen: Option(String),
  residency: sessions.Residency,
) -> grants.Snapshot {
  grants.Snapshot(
    principals: people(),
    more_principals: grants.Whole,
    sessions: [entry(session, "review auth", residency)],
    selection: case chosen {
      Some(id) if id == session ->
        Some(grants.Selection(
          session:,
          holders: [],
          more: grants.Whole,
          scope: creations.Private,
        ))
      Some(_) | None -> None
    },
    logins: [],
    summaries: [grants.Summary(session, 1, grants.Whole, creations.Private)],
  )
}

// A page over a private session that is `residency`, with the choice already
// made and the ask recorded.
fn private_page(
  residency: sessions.Residency,
  acts: Subject(grants.Action),
  answer: grants.Answer,
) -> admin.Model {
  let start =
    admin.Start(
      ..start_with(process.new_subject(), acts, answer),
      read: fn(chosen, deliver) {
        deliver(grants.Read(private_snapshot(chosen, residency)))
      },
    )
  let #(model, _) = opened(start)
  run(model, admin.Choosing(session))
}

fn make_shareable() -> grants.Action {
  grants.MakeShareable(session)
}

// A private session's members block says it cannot be shared and offers one
// button, with no invitation form.
pub fn a_private_session_offers_make_shareable_and_no_form_test() {
  let html = drawn(private_page(Live, process.new_subject(), grants.Changed))
  assert string.contains(html, "Private session: it shares the workspace")
  assert string.contains(html, ">Make shareable<")
  assert !string.contains(html, "Create invitation")
}

// The press asks first, in place: the question names what happens to a running
// session, Cancel takes it back, and nothing reaches the daemon until the
// confirm, which is the only message that does.
pub fn make_shareable_asks_before_the_daemon_is_asked_test() {
  let acts = process.new_subject()
  let model = private_page(Live, acts, grants.Changed)
  let model = run(model, admin.Arming(make_shareable()))
  let html = drawn(model)
  assert string.contains(
    html,
    "Make this session shareable? It will stop, move to its own history, and resume.",
  )
  assert process.receive(acts, 0) == Error(Nil)

  let cancelled = run(model, admin.Disarming)
  assert !string.contains(drawn(cancelled), "Make this session shareable?")
  assert process.receive(acts, 0) == Error(Nil)

  let model = run(model, admin.Asking(make_shareable()))
  assert process.receive(acts, 0) == Ok(make_shareable())
  assert process.receive(acts, 0) == Error(Nil)
  assert string.contains(drawn(model), "This session is shareable now.")
}

// The confirm guard in update: an ask that names the change without the
// question having been armed is not sent, whatever frame reached the page.
pub fn an_unarmed_make_shareable_asks_nothing_test() {
  let acts = process.new_subject()
  let model = private_page(Live, acts, grants.Changed)
  let model = run(model, admin.Asking(make_shareable()))
  assert process.receive(acts, 0) == Error(Nil)
  assert !string.contains(drawn(model), "This session is shareable now.")

  // Arming another change does not arm this one.
  let model = run(model, admin.Arming(grants.RevokeCredentials("bob")))
  let _ = run(model, admin.Asking(make_shareable()))
  assert process.receive(acts, 0) == Error(Nil)
}

// A saved session is isolated and stays saved, which its question says, and a
// session the daemon would not open offers nothing.
pub fn the_question_says_what_a_saved_session_does_test() {
  let model = private_page(Saved, process.new_subject(), grants.Changed)
  let html = drawn(run(model, admin.Arming(make_shareable())))
  assert string.contains(
    html,
    "It will move to its own history and stay saved.",
  )
  assert !string.contains(html, "It will stop")

  let blocked =
    private_page(sessions.Blocked, process.new_subject(), grants.Changed)
  assert !string.contains(drawn(blocked), "Make shareable")
}

// While the task runs the page says so and offers no button; the ask is out
// once, and a second confirm asks nothing.
pub fn a_running_make_shareable_is_worded_and_blocks_a_second_press_test() {
  let acts = process.new_subject()
  let start =
    admin.Start(
      ..start_with(process.new_subject(), acts, grants.Changed),
      read: fn(chosen, deliver) {
        deliver(grants.Read(private_snapshot(chosen, Live)))
      },
      act: fn(action, _deliver) { process.send(acts, action) },
    )
  let #(model, _) = opened(start)
  let model = run(model, admin.Choosing(session))
  let model = run(model, admin.Arming(make_shareable()))
  let model = run(model, admin.Asking(make_shareable()))
  let html = drawn(model)
  assert string.contains(html, "Making this session shareable")
  assert !string.contains(html, ">Make shareable<")
  assert process.receive(acts, 0) == Ok(make_shareable())
  let model = run(model, admin.Arming(make_shareable()))
  let _ = run(model, admin.Asking(make_shareable()))
  assert process.receive(acts, 0) == Error(Nil)
}

// A refusal is worded where the control is, in the reason's fixed words, and the
// page offers the button again.
pub fn a_refused_make_shareable_says_what_state_it_left_test() {
  let model =
    private_page(
      Live,
      process.new_subject(),
      grants.Declined(grants.NotResumed),
    )
  let model = run(model, admin.Arming(make_shareable()))
  let html = drawn(run(model, admin.Asking(make_shareable())))
  assert string.contains(
    html,
    "The session is shareable now but did not start again.",
  )
  assert string.contains(html, ">Make shareable<")
}

// A refresh that lands while the task is still resuming the session does not end
// the page's wait: the answer that arrives after it, a failed resume, is still
// worded beside the control.
pub fn a_refresh_during_the_task_does_not_drop_a_failed_resume_test() {
  let start =
    admin.Start(
      ..start_with(process.new_subject(), process.new_subject(), grants.Changed),
      read: fn(chosen, deliver) {
        deliver(grants.Read(private_snapshot(chosen, Live)))
      },
      act: fn(_action, _deliver) { Nil },
    )
  let #(model, _) = opened(start)
  let model = run(model, admin.Choosing(session))
  let model = run(model, admin.Arming(make_shareable()))
  let model = run(model, admin.Asking(make_shareable()))
  let model = run(model, admin.Ticked)
  let model = run(model, admin.Acted(grants.Declined(grants.NotResumed)))
  assert string.contains(
    drawn(model),
    "The session is shareable now but did not start again.",
  )
}
