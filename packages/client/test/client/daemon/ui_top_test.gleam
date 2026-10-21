//// What the web view asks of another orchestrator (protocol-change/094), against
//// real orchestrator ports on this node served by a `TopHost` that records what
//// it was asked.
////
//// These tests pin the three things `client/daemon/ui_top` adds to the relay: a
//// box's row and its requests become the page's types by the rules a local
//// approval card follows; a decision is built from a fresh read of the box and
//// refused before anything is sent when the request is gone, has moved, or the
//// box's ceiling admits nothing of it; and a create is judged against a fresh
//// `Placements` answer, so a page can start nothing the box does not offer now.

import broker/policy
import client/daemon/ui_top
import client/protocol
import client/remote/address.{type Address}
import client/remote/orchestrator_port.{type Message}
import client/remote/top_relay
import client/remote_escalation
import client/remote_mail
import client/remote_top
import core/json
import gleam/erlang/node
import gleam/erlang/process.{type Subject}
import gleam/option.{None, Some}
import gleam/string
import session_view/remote_transcript
import web_view/listing
import web_view/relayed

const session = "0198c0de-0000-7000-8000-000000000009"

fn quick() -> top_relay.Timing {
  top_relay.Timing(
    retry_window_ms: 600,
    create_ms: 150,
    call_ms: 150,
    first_pause_ms: 10,
    longest_pause_ms: 40,
  )
}

fn serving(top: orchestrator_port.TopHost) -> Address(Message) {
  let name = process.new_name("orchestrator_port")
  let assert Ok(_) =
    orchestrator_port.start_with_top(
      name,
      fn(_session) { Ok(orchestrator_port.NotOwned) },
      fn(_session, _command) { Error(orchestrator_port.peer_unserved) },
      fn(_session) { Error("not_found") },
      orchestrator_port.declining(),
      orchestrator_port.refusing_spawns(),
      orchestrator_port.refusing_children(),
      orchestrator_port.unheld,
      orchestrator_port.unreported(),
      top,
    )
    as "the port starts"
  address.Address(node: node.self(), name:)
}

// A relay that reaches `top` under the name "box"; any other name is not
// configured.
fn relay_to(top: orchestrator_port.TopHost) -> top_relay.Relay {
  let port = serving(top)
  top_relay.through(
    fn(name) {
      case name {
        "box" -> Ok(port)
        other -> Error(top_relay.NotConfigured(other))
      }
    },
    quick(),
  )
}

fn root_grant() -> policy.Grant {
  policy.GrantWritableRoot(path: "/srv/work")
}

fn env_grant() -> policy.Grant {
  policy.GrantEnv(name: "TOKEN")
}

fn record(
  seq: Int,
  wanted: List(policy.Grant),
  admitted: option.Option(List(policy.Grant)),
) -> protocol.EscalationRecord {
  protocol.EscalationRecord(
    escalation_id: "ask-1",
    op: "op-1",
    strand: "main",
    status: "pending",
    tool: "bash",
    action: "digest-1",
    preview: "go test ./...",
    asked: 1,
    denial: Some(protocol.Denial(
      reason: "write outside the sandbox",
      source: "policy",
      enforcement: None,
      wanted:,
    )),
    seq:,
    origin: None,
    placement: None,
    admitted:,
  )
}

fn row(requests: List(protocol.EscalationRecord)) -> remote_top.Row {
  remote_top.Row(
    session_id: session,
    request_id: "0198c0de-0000-7000-8000-0000000000aa",
    name: "build the thing",
    placement: remote_top.Workspace(executor: "exec", name: "loom"),
    activity: remote_top.NeedsYou,
    updated_at: 42,
    requests:,
    more: 1,
    children: [],
  )
}

fn listing_of(rows: List(remote_top.Row)) -> orchestrator_port.TopHost {
  orchestrator_port.TopHost(
    ..orchestrator_port.refusing_top(),
    sessions: fn(_node, _after, _limit) {
      Ok(remote_top.encode_page(remote_top.page_of(rows, remote_top.Last)))
    },
    history: fn(_node, _session, _cursor, _limit) {
      Ok(
        remote_transcript.encode(remote_transcript.Page(
          child: "main",
          entries: [],
          omitted: 0,
          next: None,
        )),
      )
    },
  )
}

fn need_of(
  wanted: List(policy.Grant),
  admitted: option.Option(List(policy.Grant)),
) -> relayed.Need {
  ui_top.need_of("box", record(4, wanted, admitted))
}

// --- what a box lists, as the page's types ---------------------------------------------

pub fn a_row_is_the_pages_row_with_its_requests_worded_like_a_local_card_test() {
  let relay =
    relay_to(
      listing_of([row([record(4, [root_grant()], Some([root_grant()]))])]),
    )
  let assert relayed.Heard(row: Some(found), history: relayed.Shown(..)) =
    ui_top.read(relay, "box", session)

  assert found.name == "build the thing"
  assert found.code == listing.Registered("exec", "loom")
  assert found.activity == relayed.NeedsYou
  assert found.updated_ms == 42
  assert found.more_needs == 1

  let assert [need] = found.needs
  assert need.escalation == "ask-1"
  assert need.seq == 4
  assert need.strand == "main"
  assert need.tool == "bash"
  assert need.question == "Allow this command?"
  assert need.action == "go test ./..."
  assert need.authority == ["Write files under: \"/srv/work\""]
  assert need.outside == []
  assert need.ability == relayed.Decidable
  assert need.remember == relayed.Rememberable
}

pub fn a_session_the_list_does_not_hold_is_not_listed_test() {
  let relay = relay_to(listing_of([]))

  let assert relayed.Heard(row: None, ..) = ui_top.read(relay, "box", session)
}

pub fn a_box_that_cannot_be_read_is_unreached_in_words_test() {
  let relay = relay_to(listing_of([]))

  assert ui_top.read(relay, "desk", session)
    == relayed.Unreached("desk is not one of this daemon's orchestrators")
}

pub fn a_transcript_that_cannot_be_read_leaves_the_row_and_says_why_test() {
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..listing_of([row([])]),
        history: fn(_node, _session, _cursor, _limit) { Ok(json.Null) },
      ),
    )
  let assert relayed.Heard(row: Some(_), history: relayed.Unreadable(why:)) =
    ui_top.read(relay, "box", session)

  assert string.contains(why, "could not be read")
}

pub fn the_grants_a_ceiling_does_not_admit_are_listed_and_not_carried_test() {
  let need = need_of([root_grant(), env_grant()], Some([root_grant()]))

  assert need.ability == relayed.Decidable
  assert need.authority == ["Write files under: \"/srv/work\""]
  let assert [line] = need.outside
  assert string.contains(line, "TOKEN")
  assert string.contains(line, "outside the spawner's approval ceiling")
}

// A request the ceiling admits nothing of is shown and cannot be decided here.
pub fn a_request_the_ceiling_admits_nothing_of_is_view_only_test() {
  let none_admitted = need_of([root_grant()], None)
  let empty = need_of([root_grant()], Some([]))

  assert none_admitted.ability == relayed.ViewOnly
  assert empty.ability == relayed.ViewOnly
  assert string.contains(none_admitted.question, "cannot be approved")
  assert none_admitted.action == "go test ./..."
  assert none_admitted.authority == []
}

// An environment variable is not something the terminal remembers either, so
// the page offers that request once.
pub fn a_request_that_cannot_be_remembered_is_offered_once_test() {
  let need = need_of([env_grant()], Some([env_grant()]))

  assert need.ability == relayed.Decidable
  assert need.remember == relayed.OnceOnly
}

// --- decisions ----------------------------------------------------------------------------

// A box whose list holds one request, and which records each decision it is
// asked to judge.
fn deciding(
  requests: List(protocol.EscalationRecord),
  log: Subject(#(remote_escalation.Decision, Int, remote_escalation.Decider)),
) -> orchestrator_port.TopHost {
  orchestrator_port.TopHost(
    ..listing_of([row(requests)]),
    resolve: fn(_node, _session, _id, decision, seq, decider) {
      process.send(log, #(decision, seq, decider))
      Ok(remote_escalation.Refused(reason: "stubbed"))
    },
  )
}

fn decider() -> remote_escalation.Decider {
  remote_escalation.Decider(principal: "abc123", name: "Alice")
}

fn decide(
  relay: top_relay.Relay,
  seq: Int,
  choice: relayed.Choice,
) -> relayed.Outcome {
  ui_top.decide(relay, "box", session, decider(), "ask-1", seq, choice)
}

pub fn allowing_carries_what_the_ceiling_admitted_and_the_boxs_digest_test() {
  let log = process.new_subject()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..deciding(
          [record(4, [root_grant(), env_grant()], Some([root_grant()]))],
          log,
        ),
        resolve: fn(_node, _session, _id, decision, seq, who) {
          process.send(log, #(decision, seq, who))
          Ok(remote_escalation.Decided(record: record(5, [], None)))
        },
      ),
    )

  assert decide(relay, 4, relayed.Allow) == relayed.Done

  let assert Ok(#(decision, seq, who)) = process.receive(log, 100)
  assert decision
    == remote_escalation.Approve(
      grants: [root_grant()],
      action: "digest-1",
      scope: remote_escalation.Once,
    )
  assert seq == 4
  assert who == decider()
}

pub fn allowing_for_the_session_widens_the_scope_only_when_rememberable_test() {
  let log = process.new_subject()
  let relay =
    relay_to(deciding([record(4, [root_grant()], Some([root_grant()]))], log))
  let _ = decide(relay, 4, relayed.AllowForSession)
  let assert Ok(#(decision, _, _)) = process.receive(log, 100)
  assert decision
    == remote_escalation.Approve(
      grants: [root_grant()],
      action: "digest-1",
      scope: remote_escalation.Session,
    )

  let other = process.new_subject()
  let once_only =
    relay_to(deciding([record(4, [env_grant()], Some([env_grant()]))], other))
  let assert relayed.Refusal(why:) =
    decide(once_only, 4, relayed.AllowForSession)
  assert string.contains(why, "Session consent")
  assert process.receive(other, 50) == Error(Nil)
}

pub fn denying_asks_the_box_to_reject_test() {
  let log = process.new_subject()
  let relay =
    relay_to(deciding([record(4, [root_grant()], Some([root_grant()]))], log))
  let _ = decide(relay, 4, relayed.Deny)

  let assert Ok(#(decision, seq, _)) = process.receive(log, 100)
  assert decision == remote_escalation.Deny
  assert seq == 4
}

// A request the box no longer lists, or lists at another revision, is refused
// here and nothing is sent: the person decides again from the next read.
pub fn a_request_that_moved_or_left_is_refused_and_nothing_is_sent_test() {
  let log = process.new_subject()
  let relay =
    relay_to(deciding([record(5, [root_grant()], Some([root_grant()]))], log))

  let assert relayed.Refusal(why:) = decide(relay, 4, relayed.Allow)
  assert string.contains(why, "no longer pending")
  let assert relayed.Refusal(_) =
    ui_top.decide(relay, "box", session, decider(), "ask-9", 5, relayed.Deny)
  assert process.receive(log, 50) == Error(Nil)
}

pub fn a_request_with_nothing_admitted_cannot_be_allowed_but_the_box_judges_denial_test() {
  let log = process.new_subject()
  let relay = relay_to(deciding([record(4, [root_grant()], None)], log))

  let assert relayed.Refusal(why:) = decide(relay, 4, relayed.Allow)
  assert why == remote_escalation.outside_the_ceiling
  assert process.receive(log, 50) == Error(Nil)

  // A denial carries no grants, so it is the box's to judge.
  let _ = decide(relay, 4, relayed.Deny)
  assert process.receive(log, 100) |> result_is_ok
}

fn result_is_ok(received: Result(a, Nil)) -> Bool {
  case received {
    Ok(_) -> True
    Error(Nil) -> False
  }
}

pub fn the_boxs_answers_to_a_decision_become_outcomes_test() {
  let answering = fn(answer) {
    relay_to(
      orchestrator_port.TopHost(
        ..deciding(
          [record(4, [root_grant()], Some([root_grant()]))],
          process.new_subject(),
        ),
        resolve: fn(_node, _session, _id, _decision, _seq, _who) { answer },
      ),
    )
  }

  assert decide(
      answering(Ok(remote_escalation.Decided(record: record(5, [], None)))),
      4,
      relayed.Allow,
    )
    == relayed.Done
  assert decide(
      answering(
        Ok(remote_escalation.Stale(
          record: record(5, [], None),
          reason: "the question changed",
        )),
      ),
      4,
      relayed.Allow,
    )
    == relayed.Refusal("the question changed")
  assert decide(answering(Error(remote_top.NotRelayed)), 4, relayed.Allow)
    == relayed.Refusal("that session was not started by your orchestrator")
}

// --- the plain actions ------------------------------------------------------------------

pub fn a_reply_a_stop_and_an_archive_are_done_or_refused_in_the_boxs_words_test() {
  let log = process.new_subject()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        send: fn(_node, _session, message_id, text) {
          process.send(log, message_id <> ":" <> text)
          Ok(remote_mail_admitted())
        },
        stop: fn(_node, _session) { Ok(Nil) },
        archive: fn(_node, _session) { Error(remote_top.NotRelayed) },
      ),
    )

  assert ui_top.send(relay, "box", session, "m-1", "hello") == relayed.Done
  assert process.receive(log, 100) == Ok("m-1:hello")
  assert ui_top.stop(relay, "box", session) == relayed.Done
  assert ui_top.archive(relay, "box", session)
    == relayed.Refusal("that session was not started by your orchestrator")
  assert ui_top.stop(relay, "desk", session)
    == relayed.Refusal("desk is not one of this daemon's orchestrators")
}

fn remote_mail_admitted() -> json.JsonValue {
  remote_mail.encode_landing(remote_mail.Admitted)
}

// --- creates ----------------------------------------------------------------------------

fn offers() -> remote_top.Offers {
  remote_top.Offers(
    folders: [remote_top.FolderOffer(path: "/srv/app", label: "app")],
    executors: [
      remote_top.ExecutorOffer(
        name: "exec",
        state: remote_top.Ready,
        free_scopes: None,
        workspaces: ["loom"],
      ),
      remote_top.ExecutorOffer(
        name: "bare",
        state: remote_top.Ready,
        free_scopes: None,
        workspaces: [],
      ),
    ],
    pools: [remote_top.PoolOffer(name: "linux", ready: 1, workspaces: ["loom"])],
    profiles: ["default", "alt"],
    models: ["glm"],
  )
}

fn judged(
  placement: remote_top.Placement,
  profile: String,
  model: option.Option(String),
) -> Result(Nil, ui_top.CreateRefusal) {
  ui_top.judge(offers(), placement, profile, model)
}

pub fn a_create_the_offers_admit_is_judged_fine_test() {
  assert judged(remote_top.Folder("/srv/app"), "default", None) == Ok(Nil)
  assert judged(remote_top.Workspace("exec", "loom"), "alt", Some("glm"))
    == Ok(Nil)
  assert judged(remote_top.Pooled("linux", "loom"), "default", None) == Ok(Nil)

  // An executor that registered no workspace is asked for a name, and the box
  // judges the name.
  assert judged(remote_top.Workspace("bare", "anything"), "default", None)
    == Ok(Nil)
}

pub fn a_create_names_only_what_the_box_offers_now_test() {
  assert judged(remote_top.Folder("/etc"), "default", None)
    == Error(ui_top.NotOffered(remote_top.OfferedFolder, "/etc"))
  assert judged(remote_top.Workspace("other", "loom"), "default", None)
    == Error(ui_top.NotOffered(remote_top.OfferedExecutor, "other"))
  assert judged(remote_top.Workspace("exec", "nope"), "default", None)
    == Error(ui_top.NotOffered(remote_top.OfferedExecutor, "nope"))
  assert judged(remote_top.Pooled("mac", "loom"), "default", None)
    == Error(ui_top.NotOffered(remote_top.OfferedPool, "mac"))
  assert judged(remote_top.Pooled("linux", "nope"), "default", None)
    == Error(ui_top.NotOffered(remote_top.OfferedPool, "nope"))
  assert judged(remote_top.Folder("/srv/app"), "secret", None)
    == Error(ui_top.NotOffered(remote_top.OfferedProfile, "secret"))
  assert judged(remote_top.Folder("/srv/app"), "default", Some("other"))
    == Error(ui_top.NotOffered(remote_top.OfferedModel, "other"))
}

// The create is judged against offers read at the moment of the create, not the
// ones the composer drew: an offer the box has withdrawn since is refused here,
// and nothing is created.
pub fn a_create_is_judged_against_fresh_offers_and_only_then_made_test() {
  let created = process.new_subject()
  let relay =
    relay_to(
      orchestrator_port.TopHost(
        ..orchestrator_port.refusing_top(),
        placements: fn(_node) { Ok(remote_top.encode_offers(offers())) },
        create: fn(_node, request_id, _placement, profile, _model) {
          process.send(created, request_id <> ":" <> profile)
          Ok(session)
        },
      ),
    )
  let request = "0198c0de-0000-7000-8000-0000000000bb"

  assert ui_top.create(
      relay,
      "box",
      request,
      remote_top.Folder("/srv/app"),
      "alt",
      None,
    )
    == Ok(session)
  assert process.receive(created, 100) == Ok(request <> ":alt")

  assert ui_top.create(
      relay,
      "box",
      request,
      remote_top.Folder("/srv/gone"),
      "alt",
      None,
    )
    == Error(ui_top.NotOffered(remote_top.OfferedFolder, "/srv/gone"))
  assert process.receive(created, 50) == Error(Nil)
}

pub fn a_create_on_a_box_that_cannot_be_reached_fails_in_the_relays_words_test() {
  let relay = relay_to(orchestrator_port.refusing_top())

  assert ui_top.create(
      relay,
      "desk",
      "0198c0de-0000-7000-8000-0000000000bb",
      remote_top.Folder("/srv/app"),
      "alt",
      None,
    )
    == Error(ui_top.Failed(top_relay.NotConfigured("desk")))
}
