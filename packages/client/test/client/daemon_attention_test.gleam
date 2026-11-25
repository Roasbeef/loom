//// The daemon's attention commands over a real registry, a real catalogue and a
//// real resident session (protocol-change/120): `sessions.attention`,
//// `attention.read` and `attention.close_find` on the control socket, and the
//// door the home page answers an ask through.
////
//// Authority is the point. The owner, an Operator member, an Observer member
//// and a bystander each ask for the same record, and each gets what the
//// registry says it may have, read afresh at the moment of the command.

import client/attention
import client/daemon/attention_door.{
  Declined, NotSent, Reach, Refusal, Unsettled,
}
import client/daemon/brief_door
import client/daemon/limits
import client/daemon/manager
import client/daemon/timeline_door
import client/daemon/ui_socket
import client/daemon_server_test.{connect, frame, send}
import client/deployment
import client/gateway_test
import client/internal/ffi_os
import client/peer_mail
import client/session_directory
import client/session_movers
import core/agency_limits
import core/attention as records
import core/clock
import core/ids
import core/json.{type JsonValue}
import core/register
import core/tx
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap
import machine/codec
import machine/operation
import machine/strand as machine_strand
import runtime/api
import runtime/writer
import session_view/operator as session_operator
import storage/access
import storage/catalogue
import support/internal/ffi_ws
import tools/agent
import tools/attention as tool_attention
import web_view/session_brief
import web_view/thread_send
import web_view/timeline_feed
import weft/poll

const now = 1_790_000_000_000

fn field(value: JsonValue, key: String) -> JsonValue {
  let assert json.Object(fields) = value as "an object"
  let assert Ok(found) = list.key_find(fields, key) as "the field is present"
  found
}

fn body(reply: JsonValue, key: String) -> JsonValue {
  field(field(reply, "body"), key)
}

fn code(reply: JsonValue) -> JsonValue {
  body(reply, "code")
}

fn digest_of(token: String) -> access.Digest {
  let assert Ok(digest) =
    token
    |> bit_array.from_string
    |> bootstrap.sha256
    |> bit_array.base16_encode
    |> string.lowercase
    |> access.credential_digest
    as "the digest is valid"
  digest
}

fn caller(strand: String) -> agent.Caller {
  let #(operation, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed: 9))
  agent.Caller(
    strand:,
    operation:,
    step_id: "step-1",
    source_index: 3,
    minter: agent.ToolCall,
  )
}

fn wiring(runtime: api.Runtime) -> attention.Wiring {
  attention.Wiring(
    runtime: fn() { Ok(runtime) },
    clock: clock.fixed(at: now),
    entropy: ffi_os.unique_positive_integer,
    report: attention.silent(),
  )
}

/// An ask of a confirm and a choice.
fn ask_request(to: Option(String)) -> tool_attention.AskRequest {
  tool_attention.AskRequest(to:, why: None, questions: [
    records.Question("q1", "Retry?", records.Confirm, []),
    records.Question("q2", "Branch?", records.Choice, [
      records.Alternative("a", None, records.Plain),
      records.Alternative("b", None, records.Plain),
    ]),
  ])
}

fn good_answer() -> JsonValue {
  json.Object([
    #(
      "answers",
      json.Object([#("q1", json.Bool(True)), #("q2", json.String("a"))]),
    ),
  ])
}

type Rig {
  Rig(
    harness: gateway_test.Harness,
    runtime: api.Runtime,
    session: String,
    saved: String,
    ask: String,
    find: String,
    owner: access.Digest,
    state_root: String,
    reach: fn(access.Digest) -> attention_door.Reach(String),
  )
}

/// Runs `check` against a daemon with one resident session that holds an ask
/// of a sub-agent and a find, one saved session, and the owner's credential.
fn with_rig(
  check: fn(manager.Manager(String), Int, String, String, Rig, access.Principal) ->
    Nil,
) -> Nil {
  let #(resident, _) = ids.mint_session(ids.generator(clock.fixed(0), 901))
  let #(saved, _) = ids.mint_session(ids.generator(clock.fixed(0), 902))
  let session = ids.session_id_to_string(resident)
  let saved_id = ids.session_id_to_string(saved)
  let harness = gateway_test.reserved_fixture(resident)
  let runtime = harness.runtime

  // The control socket delivers an answer through the gateway of the scripted
  // session, by the web view's own sender (`ui_socket.strand_sender`), so the
  // prompt it sends is the real one and lands in the session's transcript.
  let strand_send = fn(registry, digest, epoch) {
    let send =
      ui_socket.strand_sender(registry, digest, epoch, fn(instance) {
        case instance == session {
          True -> Ok(harness.hub)
          False -> Error(Nil)
        }
      })
    fn(target, strand, text) {
      send(target, strand, text, session_operator.Prompt)
    }
  }
  let endpoint = fn(instance) {
    case instance == session {
      True ->
        Some(
          peer_mail.Endpoint(instance, fn(command) {
            peer_mail.handle(runtime, clock.fixed(now), command)
            |> peer_mail.refused
          }),
        )
      False -> None
    }
  }
  daemon_server_test.fixture_answering(
    limits.defaults,
    endpoint,
    fn(_) { None },
    strand_send,
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
    session_directory.none(),
    session_movers.idle(),
    deployment.alone("nonode@nohost"),
    None,
    None,
    fn(_, ready, port, credential) {
      list.each([#(session, 901), #(saved_id, 902)], fn(pair) {
        let assert Ok(_) =
          manager.create(
            ready.registry,
            manager.Creation(
              pair.0,
              ready.state_root,
              pair.0,
              "",
              None,
              None,
              "",
              "",
              agency_limits.empty,
            ),
            directory: ready.sessions_directory,
            generator: ids.generator(clock.fixed(0), pair.1),
          )
          as "the session is created"
      })
      let assert poll.Answered(_) =
        poll.until(within: 2000, every: 1, attempt: fn() {
          case manager.resolve(ready.registry, session) {
            Ok(instance) -> poll.Done(instance)
            Error(_) -> poll.Retry
          }
        })
        as "the session becomes resident"
      let assert Ok(ask) =
        attention.ask(
          wiring(runtime),
          caller("sub:main/audit"),
          ask_request(None),
        )
      let assert Ok(find) =
        attention.notice(
          wiring(runtime),
          caller("main"),
          tool_attention.NoticeRequest(
            kind: records.Bug,
            text: "No backoff.",
            path: Some("src/retry.gleam"),
            line: Some(41),
          ),
        )
      let owner = digest_of(credential)
      let assert Ok(principal) = manager.authenticate(ready.registry, owner)
        as "the owner authenticates"
      let reach = fn(digest) {
        Reach(registry: ready.registry, digest:, endpoint:)
      }
      check(
        ready.registry,
        port,
        credential,
        ready.epoch,
        Rig(
          harness:,
          runtime:,
          session:,
          saved: saved_id,
          ask:,
          find:,
          owner:,
          state_root: ready.state_root,
          reach:,
        ),
        principal,
      )
    },
  )
}

fn stop(
  socket: ffi_ws.Socket,
  registry: manager.Manager(String),
  epoch: String,
  id: String,
) -> Nil {
  let _ =
    send(
      socket,
      90,
      "sessions.stop",
      json.Object([
        #("session_id", json.String(id)),
        #("epoch", json.String(epoch)),
      ]),
      within_ms: 1000,
    )
  let assert poll.Answered(Nil) =
    poll.until(within: 2000, every: 1, attempt: fn() {
      case manager.get(registry, id) {
        Ok(manager.View(status: manager.Saved, ..)) -> poll.Done(Nil)
        _ -> poll.Retry
      }
    })
    as "the session becomes saved"
  Nil
}

fn read(socket, id: Int, rig: Rig, record: String, epoch: String) -> JsonValue {
  send(
    socket,
    id,
    "attention.read",
    json.Object([
      #("session", json.String(rig.session)),
      #("id", json.String(record)),
      #("epoch", json.String(epoch)),
    ]),
    within_ms: 1000,
  )
}

fn close(
  socket,
  id: Int,
  rig: Rig,
  revision: JsonValue,
  outcome: String,
  epoch: String,
) -> JsonValue {
  send(
    socket,
    id,
    "attention.close_find",
    json.Object([
      #("session", json.String(rig.session)),
      #("find", json.String(rig.find)),
      #("revision", revision),
      #("outcome", json.String(outcome)),
      #("epoch", json.String(epoch)),
    ]),
    within_ms: 1000,
  )
}

// --- the control commands ----------------------------------------------------

pub fn the_owner_reads_the_feed_and_each_record_test() {
  with_rig(fn(_registry, port, credential, epoch, rig, _principal) {
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let feed =
      send(
        socket,
        1,
        "sessions.attention",
        json.Object([
          #("sessions", json.Array([json.String(rig.session)])),
          #("epoch", json.String(epoch)),
        ]),
        within_ms: 1000,
      )
    assert field(feed, "event") == json.String("sessions.attention")
    let assert json.Array([row]) = body(feed, "attention")
      as "one row for the resident"
    assert field(row, "session_id") == json.String(rig.session)
    assert field(row, "state") == json.String("ok")
    assert field(field(row, "asks"), "count") == json.Int(1)
    assert field(field(row, "finds"), "count") == json.Int(1)
    assert field(row, "waiting_since") == json.Int(now)

    // The rules of `sessions.activity`: one to 24 distinct identities, and the
    // current epoch.
    list.each(
      [
        json.Array([]),
        json.Array([json.String(rig.session), json.String(rig.session)]),
      ],
      fn(sessions) {
        let refused =
          send(
            socket,
            2,
            "sessions.attention",
            json.Object([
              #("sessions", sessions),
              #("epoch", json.String(epoch)),
            ]),
            within_ms: 1000,
          )
        assert code(refused) == json.String("bad_request")
      },
    )
    let stale =
      send(
        socket,
        3,
        "sessions.attention",
        json.Object([
          #("sessions", json.Array([json.String(rig.session)])),
          #("epoch", json.String("previous-epoch")),
        ]),
        within_ms: 1000,
      )
    assert code(stale) == json.String("stale_epoch")

    // The ask in full, with its revision and the right to answer it.
    let ask = read(socket, 4, rig, rig.ask, epoch)
    assert field(ask, "event") == json.String("attention.read")
    assert body(ask, "kind") == json.String("ask")
    assert body(ask, "status") == json.String("open")
    assert body(ask, "strand") == json.String("sub:main/audit")
    assert body(ask, "routing") == json.String("owner")
    assert body(ask, "may_answer") == json.Bool(True)
    let assert json.Array([_, _]) = body(ask, "questions")
      as "both questions are carried"
    let assert json.Int(_) = body(ask, "revision") as "a revision"

    let find = read(socket, 5, rig, rig.find, epoch)
    assert body(find, "kind") == json.String("find")
    assert body(find, "find_kind") == json.String("bug")
    assert body(find, "may_close") == json.Bool(True)

    // An id with no record's shape is refused, and one with none is not found.
    assert code(read(socket, 6, rig, "ask-x", epoch))
      == json.String("bad_request")
    assert code(read(socket, 7, rig, "ask-ffffffffff", epoch))
      == json.String("not_found")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn closing_a_find_records_the_closer_and_moves_the_revision_test() {
  with_rig(fn(_registry, port, credential, epoch, rig, principal) {
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let before = body(read(socket, 1, rig, rig.find, epoch), "revision")

    // A revision the record is not at is a conflict and writes nothing.
    assert code(close(socket, 2, rig, json.Int(1), "filed", epoch))
      == json.String("conflict")
    assert code(close(socket, 3, rig, before, "bogus", epoch))
      == json.String("bad_request")

    let closed = close(socket, 4, rig, before, "filed", epoch)
    assert field(closed, "event") == json.String("attention.close_find")
    assert body(closed, "find") == json.String(rig.find)
    let after = body(closed, "revision")
    assert after != before

    let again = read(socket, 5, rig, rig.find, epoch)
    assert body(again, "status") == json.String("closed")
    assert body(again, "revision") == after
    assert body(again, "may_close") == json.Bool(False)
    let closure = body(again, "closure")
    assert field(closure, "outcome") == json.String("filed")
    assert field(closure, "by") == json.String(principal.id)

    // A closed find is not closed twice.
    assert code(close(socket, 6, rig, after, "fixed", epoch))
      == json.String("conflict")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_saved_session_is_not_resident_and_a_pruned_record_is_not_found_test() {
  with_rig(fn(registry, port, credential, epoch, rig, _principal) {
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let saved =
      send(
        socket,
        1,
        "attention.read",
        json.Object([
          #("session", json.String(rig.saved)),
          #("id", json.String(rig.ask)),
          #("epoch", json.String(epoch)),
        ]),
        within_ms: 1000,
      )
    assert code(saved) == json.String("not_resident")

    // Removing the cell, as a prune does, reads as no record.
    let assert Ok(Some(cell)) =
      api.fact_cell(rig.runtime, records.ask_key(rig.ask))
    let assert Ok(Nil) =
      api.edit_reserved_facts(rig.runtime, [
        api.ReservedFactRemove(
          key: records.ask_key(rig.ask),
          expected: cell.seq,
        ),
      ])
    assert code(read(socket, 2, rig, rig.ask, epoch))
      == json.String("not_found")
    stop(socket, registry, epoch, rig.session)
    assert code(read(socket, 3, rig, rig.find, epoch))
      == json.String("not_resident")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn members_act_by_their_role_and_bystanders_see_nothing_test() {
  with_rig(fn(_registry, port, _credential, epoch, rig, _principal) {
    let assert Ok(store) = catalogue.open(rig.state_root <> "/catalogue.db")
      as "the catalogue opens"
    let member = fn(name, token, role) {
      let assert Ok(principal) =
        access.create_member(store, name, name, digest_of(token))
        as "the member exists"
      case role {
        Some(held) -> {
          let assert Ok(Nil) =
            access.grant(store, principal.id, rig.session, held)
          Nil
        }
        None -> Nil
      }
    }
    let operator = string.repeat("1", 64)
    let observer = string.repeat("2", 64)
    let bystander = string.repeat("3", 64)
    member("att-operator", operator, Some(access.Operator))
    member("att-observer", observer, Some(access.Observer))
    member("att-bystander", bystander, None)

    // An operator reads with the right to act, and an observer without it.
    let #(op_socket, _) = connect(port, operator, "/v2/control")
    let _ = frame(op_socket, within_ms: 1000)
    assert body(read(op_socket, 1, rig, rig.ask, epoch), "may_answer")
      == json.Bool(True)
    let _ = ffi_ws.tcp_close(op_socket)

    let #(ob_socket, _) = connect(port, observer, "/v2/control")
    let _ = frame(ob_socket, within_ms: 1000)
    assert body(read(ob_socket, 1, rig, rig.ask, epoch), "may_answer")
      == json.Bool(False)
    assert body(read(ob_socket, 2, rig, rig.find, epoch), "may_close")
      == json.Bool(False)
    let revision = body(read(ob_socket, 3, rig, rig.find, epoch), "revision")
    assert code(close(ob_socket, 4, rig, revision, "filed", epoch))
      == json.String("forbidden")
    let _ = ffi_ws.tcp_close(ob_socket)

    // A member holding nothing is told what an unknown session is told, in the
    // feed and in a read.
    let #(by_socket, _) = connect(port, bystander, "/v2/control")
    let _ = frame(by_socket, within_ms: 1000)
    let feed =
      send(
        by_socket,
        1,
        "sessions.attention",
        json.Object([
          #("sessions", json.Array([json.String(rig.session)])),
          #("epoch", json.String(epoch)),
        ]),
        within_ms: 1000,
      )
    assert body(feed, "attention") == json.Array([])
    assert code(read(by_socket, 2, rig, rig.ask, epoch))
      == json.String("not_found")
    assert code(close(by_socket, 3, rig, revision, "filed", epoch))
      == json.String("not_found")
    let _ = ffi_ws.tcp_close(by_socket)

    // The door answers by the same authority: an observer is forbidden and a
    // bystander is told no such session, and nothing is sent for either.
    let seen = process.new_subject()
    let send = recording_send(seen, thread_send.Delivered(thread_send.Admitted))
    let current = open_revision(rig, rig.ask)
    assert attention_door.answer(
        rig.reach(digest_of(observer)),
        send,
        rig.session,
        rig.ask,
        current,
        good_answer(),
      )
      == Error(
        Declined(Refusal("forbidden", "an observer cannot change a record")),
      )
    assert attention_door.answer(
        rig.reach(digest_of(bystander)),
        send,
        rig.session,
        rig.ask,
        current,
        good_answer(),
      )
      == Error(Declined(Refusal("not_found", "no such session")))
    assert process.receive(seen, 0) == Error(Nil)

    // An Operator member answers, and the record names it as the answerer.
    let assert Ok(attention_door.Answered(delivery: thread_send.Admitted, ..)) =
      attention_door.answer(
        rig.reach(digest_of(operator)),
        send,
        rig.session,
        rig.ask,
        current,
        good_answer(),
      )
      as "an Operator member may answer"
    let assert Ok(#(strand, _text)) = process.receive(seen, 0)
    assert strand == "sub:main/audit"
    assert catalogue.close(store) == Ok(Nil)
  })
}

// --- the answer ---------------------------------------------------------------

fn recording_send(
  seen: process.Subject(#(String, String)),
  answer: thread_send.Answer,
) -> fn(String, String) -> thread_send.Answer {
  fn(strand, text) {
    process.send(seen, #(strand, text))
    answer
  }
}

fn open_revision(rig: Rig, id: String) -> Int {
  let assert Ok(stored) = attention.read(rig.runtime, id)
    as "the record is there"
  attention.revision_of(stored)
}

pub fn an_answer_is_delivered_to_the_asking_strand_then_settled_test() {
  with_rig(fn(_registry, _port, _credential, _epoch, rig, principal) {
    let seen = process.new_subject()
    let revision = open_revision(rig, rig.ask)
    let reach = rig.reach(rig.owner)
    let assert Ok(attention_door.Answered(
      delivery: thread_send.Admitted,
      revision: settled,
    )) =
      attention_door.answer(
        reach,
        recording_send(seen, thread_send.Delivered(thread_send.Admitted)),
        rig.session,
        rig.ask,
        revision,
        good_answer(),
      )
      as "the answer is delivered and settled"
    assert settled > revision

    // One prompt, to the strand that asked, worded as 130 specifies.
    let assert Ok(#(strand, text)) = process.receive(seen, 0)
    assert strand == "sub:main/audit"
    assert string.starts_with(
      text,
      "Answer to your ask " <> rig.ask <> ".\n\n1. ",
    )
    assert process.receive(seen, 0) == Error(Nil)

    // The record is settled with the answer and the answerer.
    let assert Ok(attention.StoredAsk(ask:, revision: stored)) =
      attention.read(rig.runtime, rig.ask)
    assert stored == settled
    let assert records.Answered(answer: records.Answer(values:, by:), ..) =
      ask.state
    assert by == principal.id
    assert values == [#("q1", records.Yes), #("q2", records.Picked("a"))]

    // An answered ask is not answered again.
    assert attention_door.answer(
        reach,
        recording_send(seen, thread_send.Delivered(thread_send.Admitted)),
        rig.session,
        rig.ask,
        settled,
        good_answer(),
      )
      == Error(Declined(Refusal("conflict", "that ask was already answered")))
  })
}

pub fn a_refused_delivery_leaves_the_ask_open_test() {
  with_rig(fn(_registry, _port, _credential, _epoch, rig, _principal) {
    let seen = process.new_subject()
    let revision = open_revision(rig, rig.ask)
    assert attention_door.answer(
        rig.reach(rig.owner),
        recording_send(seen, thread_send.Refused(thread_send.QueueFull)),
        rig.session,
        rig.ask,
        revision,
        good_answer(),
      )
      == Error(NotSent(thread_send.QueueFull))
    let assert Ok(attention.StoredAsk(ask:, revision: after)) =
      attention.read(rig.runtime, rig.ask)
    assert ask.state == records.AskOpen
    assert after == revision
  })
}

pub fn nothing_is_sent_for_a_stale_revision_or_an_invalid_answer_test() {
  with_rig(fn(_registry, _port, _credential, _epoch, rig, _principal) {
    let seen = process.new_subject()
    let revision = open_revision(rig, rig.ask)
    let send = recording_send(seen, thread_send.Delivered(thread_send.Admitted))
    let reach = rig.reach(rig.owner)
    assert attention_door.answer(
        reach,
        send,
        rig.session,
        rig.ask,
        revision - 1,
        good_answer(),
      )
      == Error(
        Declined(Refusal("conflict", "that ask changed since it was read")),
      )

    // The first failing key is named.
    let bad =
      json.Object([
        #(
          "answers",
          json.Object([#("q1", json.Bool(True)), #("q2", json.String("zzz"))]),
        ),
      ])
    assert attention_door.answer(
        reach,
        send,
        rig.session,
        rig.ask,
        revision,
        bad,
      )
      == Error(Declined(Refusal("bad_request", "q2: not one of the options")))
    assert process.receive(seen, 0) == Error(Nil)
  })
}

pub fn an_ask_for_a_strand_or_a_find_is_not_answered_by_a_person_test() {
  with_rig(fn(_registry, _port, _credential, _epoch, rig, _principal) {
    let assert Ok(strand_ask) =
      attention.ask(
        wiring(rig.runtime),
        caller("sub:main/a"),
        ask_request(Some("main")),
      )
    let seen = process.new_subject()
    let send = recording_send(seen, thread_send.Delivered(thread_send.Admitted))
    let assert Error(Declined(Refusal("bad_request", _))) =
      attention_door.answer(
        rig.reach(rig.owner),
        send,
        rig.session,
        strand_ask,
        open_revision(rig, strand_ask),
        good_answer(),
      )
    let assert Error(Declined(Refusal("bad_request", _))) =
      attention_door.answer(
        rig.reach(rig.owner),
        send,
        rig.session,
        rig.find,
        open_revision(rig, rig.find),
        good_answer(),
      )
    assert process.receive(seen, 0) == Error(Nil)
  })
}

pub fn a_delivered_prompt_that_lost_the_settle_write_says_so_test() {
  with_rig(fn(_registry, _port, _credential, _epoch, rig, _principal) {
    let revision = open_revision(rig, rig.ask)

    // Another write settles the ask while the prompt is in flight.
    let racing = fn(_strand, _text) {
      let assert Ok(_) =
        attention.settle(
          rig.runtime,
          clock.fixed(at: now),
          rig.ask,
          revision,
          attention.Answering(records.Answer(
            [#("q1", records.No), #("q2", records.Picked("b"))],
            by: "someone",
          )),
        )
      thread_send.Delivered(thread_send.Queued)
    }
    assert attention_door.answer(
        rig.reach(rig.owner),
        racing,
        rig.session,
        rig.ask,
        revision,
        good_answer(),
      )
      == Error(Unsettled(Refusal("conflict", "delivered; the record changed")))
  })
}

pub fn settling_writes_one_cell_and_the_next_insertion_prunes_test() {
  with_rig(fn(_registry, _port, _credential, _epoch, rig, _principal) {
    // A record settled long ago is retired by the commit that settles another.
    let old =
      records.Ask(
        header: records.Header(
          id: "ask-00000000aa",
          created_at: 1,
          routing: records.ToOwner,
          anchor: records.Anchor(caller("main").operation, "s", 0),
          strand: "main",
          parents: [],
        ),
        why: None,
        questions: [records.Question("q1", "Old?", records.Confirm, [])],
        state: records.Answered(
          at: 1,
          answer: records.Answer([#("q1", records.Yes)], by: "owner"),
        ),
      )
    let assert Ok(Nil) =
      api.put_reserved_fact(
        rig.runtime,
        records.ask_key(old.header.id),
        records.encode_ask(old),
      )
    let seen = process.new_subject()
    let assert Ok(_) =
      attention_door.answer(
        rig.reach(rig.owner),
        recording_send(seen, thread_send.Delivered(thread_send.Admitted)),
        rig.session,
        rig.ask,
        open_revision(rig, rig.ask),
        good_answer(),
      )

    // Settling writes the one cell: the old settled record is still there.
    let assert Ok(asks) = attention.asks(rig.runtime)
    assert list.contains(
      list.map(asks, fn(ask) { ask.header.id }),
      old.header.id,
    )

    // The next insertion already holds the scan and retires it.
    let assert Ok(fresh) =
      attention.ask(wiring(rig.runtime), caller("main"), ask_request(None))
    let assert Ok(asks) = attention.asks(rig.runtime)
    let ids = list.map(asks, fn(ask) { ask.header.id })
    assert !list.contains(ids, old.header.id)
    assert list.contains(ids, fresh)
    assert list.contains(ids, rig.ask)
  })
}

// Approval evidence is a read: the owner and a member at any role get it, a
// bystander is told what an unknown session is told, and no one decides
// anything by it (protocol-change/120, "Approval evidence").
pub fn approval_evidence_is_read_by_authority_and_never_decides_test() {
  with_rig(fn(_registry, port, credential, epoch, rig, _principal) {
    let assert Ok(store) = catalogue.open(rig.state_root <> "/catalogue.db")
      as "the catalogue opens"
    let observer = string.repeat("4", 64)
    let bystander = string.repeat("5", 64)
    let assert Ok(seen) =
      access.create_member(
        store,
        "ev-observer",
        "ev-observer",
        digest_of(observer),
      )
    let assert Ok(Nil) =
      access.grant(store, seen.id, rig.session, access.Observer)
    let assert Ok(_) =
      access.create_member(
        store,
        "ev-bystander",
        "ev-bystander",
        digest_of(bystander),
      )

    // The in-process door answers an observer, and a bystander is not told.
    let assert Ok(json.Object(fields)) =
      attention_door.read_approvals(rig.reach(digest_of(observer)), rig.session)
    assert list.key_find(fields, "approvals") |> result_is_ok
    assert attention_door.read_approvals(
        rig.reach(digest_of(bystander)),
        rig.session,
      )
      == Error(Refusal("not_found", "no such session"))

    // The control command is the same read: the owner is answered, a stale
    // epoch is refused, and a bystander is not found.
    let #(owner_socket, _) = connect(port, credential, "/v2/control")
    let _ = frame(owner_socket, within_ms: 1000)
    let ask = fn(socket, id, epoch) {
      send(
        socket,
        id,
        "approval.read",
        json.Object([
          #("session", json.String(rig.session)),
          #("epoch", json.String(epoch)),
        ]),
        within_ms: 1000,
      )
    }
    assert body(ask(owner_socket, 1, epoch), "approvals")
      == json.Object([
        #("count", json.Int(0)),
        #("items", json.Array([])),
      ])
    assert code(ask(owner_socket, 2, "stale")) == json.String("stale_epoch")
    let _ = ffi_ws.tcp_close(owner_socket)

    let #(by_socket, _) = connect(port, bystander, "/v2/control")
    let _ = frame(by_socket, within_ms: 1000)
    assert code(ask(by_socket, 1, epoch)) == json.String("not_found")
    let _ = ffi_ws.tcp_close(by_socket)
    Nil
  })
}

// The session brief is a read admitted exactly as `attention.read` is
// (protocol-change/125): the owner and a member at any role are answered, a
// bystander is told what an unknown session is told, a stale epoch is refused,
// a saved session is not resident, and the credential's allowance bounds how
// often it may be asked. It never writes.
pub fn the_session_brief_is_read_by_authority_and_never_writes_test() {
  with_rig(fn(_registry, port, credential, epoch, rig, _principal) {
    let assert Ok(store) = catalogue.open(rig.state_root <> "/catalogue.db")
      as "the catalogue opens"
    let observer = string.repeat("6", 64)
    let bystander = string.repeat("7", 64)
    let assert Ok(seen) =
      access.create_member(
        store,
        "br-observer",
        "br-observer",
        digest_of(observer),
      )
    let assert Ok(Nil) =
      access.grant(store, seen.id, rig.session, access.Observer)
    let assert Ok(_) =
      access.create_member(
        store,
        "br-bystander",
        "br-bystander",
        digest_of(bystander),
      )
    let open = brief_door.Allowance(reserve: fn() { Ok(Nil) })

    // The in-process door answers an observer with a brief and a bystander
    // with nothing.
    let assert Ok(brief) =
      brief_door.read_typed(
        rig.reach(digest_of(observer)),
        open,
        rig.session,
        0,
      )
    assert brief.strands != []
    assert brief_door.read_typed(
        rig.reach(digest_of(bystander)),
        open,
        rig.session,
        0,
      )
      == Error(Refusal("not_found", "no such session"))

    // A refused allowance is `unavailable` and asks the session nothing.
    let spent = brief_door.Allowance(reserve: fn() { Error(Nil) })
    assert brief_door.read(
        rig.reach(digest_of(observer)),
        spent,
        rig.session,
        0,
      )
      == Error(Refusal("unavailable", brief_door.busy_words))

    // A saved session is not running.
    assert brief_door.read(rig.reach(rig.owner), open, rig.saved, 0)
      == Error(Refusal("not_resident", "the session is not running"))

    // The control command is the same read.
    let #(owner_socket, _) = connect(port, credential, "/v2/control")
    let _ = frame(owner_socket, within_ms: 1000)
    let ask = fn(socket, id, epoch, extra) {
      send(
        socket,
        id,
        "session.brief",
        json.Object([
          #("session", json.String(rig.session)),
          #("epoch", json.String(epoch)),
          ..extra
        ]),
        within_ms: 1000,
      )
    }
    let answered = ask(owner_socket, 1, epoch, [#("since", json.Int(0))])
    assert field(answered, "event") == json.String("session.brief")
    assert result_is_ok(session_brief.decode(field(answered, "body")))
    assert code(ask(owner_socket, 2, "stale", [])) == json.String("stale_epoch")
    assert code(ask(owner_socket, 3, epoch, [#("since", json.Int(-1))]))
      == json.String("bad_request")
    let _ = ffi_ws.tcp_close(owner_socket)

    let #(by_socket, _) = connect(port, bystander, "/v2/control")
    let _ = frame(by_socket, within_ms: 1000)
    assert code(ask(by_socket, 1, epoch, [])) == json.String("not_found")
    let _ = ffi_ws.tcp_close(by_socket)
    Nil
  })
}

// The session timeline is read as the brief is (protocol-change/134): the owner
// and a member are answered, a bystander is told what an unknown session is told,
// a spent allowance is `unavailable`, a saved session is not resident, the
// control command refuses a stale epoch, a limit outside one to twenty and a
// mistyped cursor, and a read never writes.
pub fn the_session_timeline_is_read_by_authority_and_never_writes_test() {
  with_rig(fn(_registry, port, credential, epoch, rig, _principal) {
    let assert Ok(store) = catalogue.open(rig.state_root <> "/catalogue.db")
      as "the catalogue opens"
    let observer = string.repeat("8", 64)
    let bystander = string.repeat("9", 64)
    let assert Ok(seen) =
      access.create_member(
        store,
        "tl-observer",
        "tl-observer",
        digest_of(observer),
      )
    let assert Ok(Nil) =
      access.grant(store, seen.id, rig.session, access.Observer)
    let assert Ok(_) =
      access.create_member(
        store,
        "tl-bystander",
        "tl-bystander",
        digest_of(bystander),
      )
    let open = brief_door.Allowance(reserve: fn() { Ok(Nil) })

    // The in-process door answers an observer with a page and a bystander with
    // nothing.
    let assert Ok(page) =
      timeline_door.read_typed(
        rig.reach(digest_of(observer)),
        open,
        rig.session,
        None,
        10,
      )
    assert page.older == None
    assert timeline_door.read_typed(
        rig.reach(digest_of(bystander)),
        open,
        rig.session,
        None,
        10,
      )
      == Error(Refusal("not_found", "no such session"))

    // A refused allowance is `unavailable` and asks the session nothing.
    let spent = brief_door.Allowance(reserve: fn() { Error(Nil) })
    assert timeline_door.read(
        rig.reach(digest_of(observer)),
        spent,
        rig.session,
        None,
        10,
      )
      == Error(Refusal("unavailable", brief_door.busy_words))

    // A saved session is not running.
    assert timeline_door.read(rig.reach(rig.owner), open, rig.saved, None, 10)
      == Error(Refusal("not_resident", "the session is not running"))

    // The control command is the same read.
    let #(owner_socket, _) = connect(port, credential, "/v2/control")
    let _ = frame(owner_socket, within_ms: 1000)
    let ask = fn(socket, id, epoch, extra) {
      send(
        socket,
        id,
        "sessions.timeline",
        json.Object([
          #("session", json.String(rig.session)),
          #("epoch", json.String(epoch)),
          ..extra
        ]),
        within_ms: 1000,
      )
    }
    let answered = ask(owner_socket, 1, epoch, [#("limit", json.Int(5))])
    assert field(answered, "event") == json.String("sessions.timeline")
    assert result_is_ok(timeline_feed.decode(field(answered, "body")))
    assert code(ask(owner_socket, 2, "stale", [])) == json.String("stale_epoch")
    assert code(ask(owner_socket, 3, epoch, [#("limit", json.Int(0))]))
      == json.String("bad_request")
    assert code(ask(owner_socket, 4, epoch, [#("limit", json.Int(21))]))
      == json.String("bad_request")
    assert code(ask(owner_socket, 5, epoch, [#("before", json.String("1"))]))
      == json.String("bad_request")

    // A span read is the same door and the same allowance, and its command
    // refuses a malformed record id, a reversed span and a span past the bound.
    let some_id =
      ids.entry_id_to_string(ids.mint_entry(ids.generator(clock.fixed(5), 3)).0)
    assert timeline_door.read_span(
        rig.reach(digest_of(bystander)),
        open,
        rig.session,
        some_id,
        1,
        2,
      )
      == Error(Refusal("not_found", "no such session"))
    assert timeline_door.read_span(
        rig.reach(digest_of(observer)),
        spent,
        rig.session,
        some_id,
        1,
        2,
      )
      == Error(Refusal("unavailable", brief_door.busy_words))
    assert timeline_door.read_span(
        rig.reach(rig.owner),
        open,
        rig.saved,
        some_id,
        1,
        2,
      )
      == Error(Refusal("not_resident", "the session is not running"))

    let span = fn(id, last, from_seq, to_seq) {
      send(
        owner_socket,
        id,
        "sessions.span",
        json.Object([
          #("session", json.String(rig.session)),
          #("epoch", json.String(epoch)),
          #("last", json.String(last)),
          #("from_seq", json.Int(from_seq)),
          #("to_seq", json.Int(to_seq)),
        ]),
        within_ms: 1000,
      )
    }
    assert code(span(6, "not-an-id", 1, 2)) == json.String("bad_request")
    assert code(span(7, some_id, 5, 2)) == json.String("bad_request")
    assert code(span(8, some_id, 0, 5000)) == json.String("bad_request")
    let _ = ffi_ws.tcp_close(owner_socket)

    let #(by_socket, _) = connect(port, bystander, "/v2/control")
    let _ = frame(by_socket, within_ms: 1000)
    assert code(ask(by_socket, 1, epoch, [])) == json.String("not_found")
    let _ = ffi_ws.tcp_close(by_socket)
    Nil
  })
}

fn result_is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}

// --- answering over the control socket (protocol-change/128) -----------------

/// The strand an ask of `ask_request` came from, which the daemon must find in
/// the session to deliver the prompt. `attention.ask` records the strand name
/// and does not create the strand.
fn add_audit_strand(rig: Rig) -> Nil {
  let configuration =
    machine_strand.StrandConfiguration(
      model: machine_strand.ModelIdentity(provider: "acme", model_id: "loom-1"),
      thinking_level: machine_strand.ThinkingOff,
      active_tool_names: [],
    )
  let assert Ok(Nil) =
    api.create_idle_strand(rig.runtime, "sub:main/audit", configuration, None)
    as "the asking strand exists"
  Nil
}

fn answer(
  socket,
  id: Int,
  rig: Rig,
  revision: JsonValue,
  answer: JsonValue,
  epoch: String,
) -> JsonValue {
  send(
    socket,
    id,
    "attention.answer",
    json.Object([
      #("session", json.String(rig.session)),
      #("ask", json.String(rig.ask)),
      #("revision", revision),
      #("answer", answer),
      #("epoch", json.String(epoch)),
    ]),
    within_ms: 1000,
  )
}

/// The prompts the session's transcript holds that answer an ask.
fn answer_prompts(rig: Rig) -> List(String) {
  gateway_test.user_prompt_texts(rig.harness)
  |> list.filter(string.starts_with(_, "Answer to "))
}

/// Waits until the transcript holds `count` answering prompts, since the
/// gateway writes the user entry after it has admitted the message.
fn await_prompts(rig: Rig, count: Int) -> List(String) {
  let assert poll.Answered(prompts) =
    poll.until(within: 5000, every: 10, attempt: fn() {
      let found = answer_prompts(rig)
      case list.length(found) >= count {
        True -> poll.Done(found)
        False -> poll.Retry
      }
    })
    as "the transcript settles"
  prompts
}

pub fn the_owner_answers_an_ask_over_the_control_socket_test() {
  with_rig(fn(_registry, port, credential, epoch, rig, principal) {
    add_audit_strand(rig)
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let before = body(read(socket, 1, rig, rig.ask, epoch), "revision")
    let assert json.Int(read_at) = before

    let answered = answer(socket, 2, rig, before, good_answer(), epoch)
    assert field(answered, "event") == json.String("attention.answer")
    assert field(answered, "reply_to") == json.Int(2)
    assert body(answered, "ask") == json.String(rig.ask)
    assert body(answered, "delivery") == json.String("admitted")
    let assert json.Int(settled) = body(answered, "revision")
    assert settled > read_at

    // The record is settled with the answer and the answerer, and no longer
    // offers to be answered.
    let again = read(socket, 3, rig, rig.ask, epoch)
    assert body(again, "status") == json.String("answered")
    assert body(again, "revision") == json.Int(settled)
    assert body(again, "may_answer") == json.Bool(False)
    assert field(body(again, "answer"), "by") == json.String(principal.id)

    // One prompt reached the asking strand, worded as 130 specifies.
    let assert [prompt] = await_prompts(rig, 1)
    assert string.starts_with(
      prompt,
      "Answer to your ask " <> rig.ask <> ".\n\n1. ",
    )

    // An answered ask is not answered again, and nothing more is sent.
    let twice = answer(socket, 4, rig, json.Int(settled), good_answer(), epoch)
    assert code(twice) == json.String("conflict")
    assert answer_prompts(rig) == [prompt]
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn a_refused_answer_changes_nothing_and_sends_nothing_test() {
  with_rig(fn(_registry, port, credential, epoch, rig, _principal) {
    add_audit_strand(rig)
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let before = body(read(socket, 1, rig, rig.ask, epoch), "revision")
    let assert json.Int(read_at) = before

    // A stale epoch is refused first.
    assert code(answer(socket, 2, rig, before, good_answer(), "previous-epoch"))
      == json.String("stale_epoch")

    // A revision the record is not at is a conflict.
    assert code(answer(
        socket,
        3,
        rig,
        json.Int(read_at - 1),
        good_answer(),
        epoch,
      ))
      == json.String("conflict")

    // The first failing key of an answer the ask does not take is named.
    let bad =
      json.Object([
        #(
          "answers",
          json.Object([#("q1", json.Bool(True)), #("q2", json.String("zzz"))]),
        ),
      ])
    let invalid = answer(socket, 4, rig, before, bad, epoch)
    assert code(invalid) == json.String("bad_request")
    assert body(invalid, "message") == json.String("q2: not one of the options")

    // An answer that is not an object, and a revision that is not a number,
    // never reach the registry.
    assert code(answer(socket, 5, rig, before, json.String("yes"), epoch))
      == json.String("bad_request")
    assert code(answer(socket, 6, rig, json.String("41"), good_answer(), epoch))
      == json.String("bad_request")

    // A find is not an ask, and an absent record is not found.
    let on_find =
      send(
        socket,
        7,
        "attention.answer",
        json.Object([
          #("session", json.String(rig.session)),
          #("ask", json.String(rig.find)),
          #("revision", before),
          #("answer", good_answer()),
          #("epoch", json.String(epoch)),
        ]),
        within_ms: 1000,
      )
    assert code(on_find) == json.String("bad_request")
    let absent =
      send(
        socket,
        8,
        "attention.answer",
        json.Object([
          #("session", json.String(rig.session)),
          #("ask", json.String("ask-ffffffffff")),
          #("revision", before),
          #("answer", good_answer()),
          #("epoch", json.String(epoch)),
        ]),
        within_ms: 1000,
      )
    assert code(absent) == json.String("not_found")

    // A saved session is not running, and an identity the daemon does not hold
    // is told what a bystander is told.
    let saved =
      send(
        socket,
        9,
        "attention.answer",
        json.Object([
          #("session", json.String(rig.saved)),
          #("ask", json.String(rig.ask)),
          #("revision", before),
          #("answer", good_answer()),
          #("epoch", json.String(epoch)),
        ]),
        within_ms: 1000,
      )
    assert code(saved) == json.String("not_resident")
    let #(stranger, _) = ids.mint_session(ids.generator(clock.fixed(0), 999))
    let unknown =
      send(
        socket,
        10,
        "attention.answer",
        json.Object([
          #("session", json.String(ids.session_id_to_string(stranger))),
          #("ask", json.String(rig.ask)),
          #("revision", before),
          #("answer", good_answer()),
          #("epoch", json.String(epoch)),
        ]),
        within_ms: 1000,
      )
    assert code(unknown) == json.String("not_found")

    // The ask is as it was, and the session was sent nothing.
    let after = read(socket, 11, rig, rig.ask, epoch)
    assert body(after, "status") == json.String("open")
    assert body(after, "revision") == before
    assert answer_prompts(rig) == []
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn an_answer_the_gateway_refuses_leaves_the_ask_open_test() {
  with_rig(fn(_registry, port, credential, epoch, rig, _principal) {
    // The asking strand does not exist in the session, so the gateway refuses
    // the prompt and the daemon says the ask is still open.
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    let before = body(read(socket, 1, rig, rig.ask, epoch), "revision")
    let refused = answer(socket, 2, rig, before, good_answer(), epoch)
    assert code(refused) == json.String("not_found")
    assert body(refused, "message")
      == json.String(
        "the asking strand no longer exists; the ask is still open",
      )
    let after = read(socket, 3, rig, rig.ask, epoch)
    assert body(after, "status") == json.String("open")
    assert body(after, "revision") == before
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn members_answer_by_their_role_over_the_control_socket_test() {
  with_rig(fn(_registry, port, _credential, epoch, rig, _principal) {
    add_audit_strand(rig)
    let assert Ok(store) = catalogue.open(rig.state_root <> "/catalogue.db")
      as "the catalogue opens"
    let member = fn(name, token, role) {
      let assert Ok(principal) =
        access.create_member(store, name, name, digest_of(token))
        as "the member exists"
      case role {
        Some(held) -> {
          let assert Ok(Nil) =
            access.grant(store, principal.id, rig.session, held)
          Nil
        }
        None -> Nil
      }
      principal
    }
    let operator = string.repeat("8", 64)
    let observer = string.repeat("9", 64)
    let bystander = string.repeat("a", 64)
    let operating = member("ans-operator", operator, Some(access.Operator))
    let _ = member("ans-observer", observer, Some(access.Observer))
    let _ = member("ans-bystander", bystander, None)
    let revision = open_revision(rig, rig.ask)

    // An observer is refused and a bystander is told no such session; neither
    // reaches the record.
    let #(ob_socket, _) = connect(port, observer, "/v2/control")
    let _ = frame(ob_socket, within_ms: 1000)
    let forbidden =
      answer(ob_socket, 1, rig, json.Int(revision), good_answer(), epoch)
    assert code(forbidden) == json.String("forbidden")
    assert body(forbidden, "message")
      == json.String("an observer cannot change a record")
    let _ = ffi_ws.tcp_close(ob_socket)

    let #(by_socket, _) = connect(port, bystander, "/v2/control")
    let _ = frame(by_socket, within_ms: 1000)
    assert code(answer(
        by_socket,
        1,
        rig,
        json.Int(revision),
        good_answer(),
        epoch,
      ))
      == json.String("not_found")
    let _ = ffi_ws.tcp_close(by_socket)
    assert open_revision(rig, rig.ask) == revision
    assert answer_prompts(rig) == []

    // An Operator member answers, and the record names it as the answerer.
    let #(op_socket, _) = connect(port, operator, "/v2/control")
    let _ = frame(op_socket, within_ms: 1000)
    let answered =
      answer(op_socket, 1, rig, json.Int(revision), good_answer(), epoch)
    assert field(answered, "event") == json.String("attention.answer")
    let settled = read(op_socket, 2, rig, rig.ask, epoch)
    assert field(body(settled, "answer"), "by") == json.String(operating.id)
    let _ = ffi_ws.tcp_close(op_socket)
    assert catalogue.close(store) == Ok(Nil)
  })
}

// This pins `strand_sender`, the function the page's `message_to_strand` calls
// and the control socket's `strand_send` is built from. A page's attachment has
// too many fields to build here, so the page's own wrapper is covered by
// `ui_socket_test` and `ui_route_test`.
pub fn the_strand_sender_the_page_shares_delivers_and_settles_test() {
  with_rig(fn(registry, _port, _credential, epoch, rig, principal) {
    add_audit_strand(rig)

    // The send a home page's answer is made with, over the owner's credential.
    let send =
      ui_socket.strand_sender(registry, rig.owner, epoch, fn(_) {
        Ok(rig.harness.hub)
      })
    let revision = open_revision(rig, rig.ask)
    let assert Ok(attention_door.Answered(
      delivery: thread_send.Admitted,
      revision: settled,
    )) =
      attention_door.answer(
        rig.reach(rig.owner),
        fn(strand, text) {
          send(rig.session, strand, text, session_operator.Prompt)
        },
        rig.session,
        rig.ask,
        revision,
        good_answer(),
      )
      as "the page's path delivers and settles"
    assert settled > revision
    let assert Ok(attention.StoredAsk(ask:, ..)) =
      attention.read(rig.runtime, rig.ask)
    let assert records.Answered(answer: records.Answer(by:, ..), ..) = ask.state
    assert by == principal.id
    let assert [_] = await_prompts(rig, 1)
    Nil
  })
}

// --- saved counts over the control socket (protocol-change/128) --------------

fn saved_request(
  socket,
  id: Int,
  sessions: List(String),
  epoch: String,
) -> JsonValue {
  send(
    socket,
    id,
    "sessions.saved_attention",
    json.Object([
      #("sessions", json.Array(list.map(sessions, json.String))),
      #("epoch", json.String(epoch)),
    ]),
    within_ms: 1000,
  )
}

pub fn saved_counts_are_read_for_the_sessions_a_credential_holds_test() {
  with_rig(fn(registry, port, credential, epoch, rig, _principal) {
    // Both sessions have a row. The writes are casts and the read queues behind
    // them in the registry's turn.
    manager.record_attention(
      registry,
      rig.session,
      catalogue.AttentionSummary(
        pending_approvals: 0,
        open_asks: 1,
        open_finds: 0,
        oldest_open_at: None,
        updated_at: 50,
      ),
    )
    manager.record_attention(
      registry,
      rig.saved,
      catalogue.AttentionSummary(
        pending_approvals: 1,
        open_asks: 0,
        open_finds: 2,
        oldest_open_at: Some(30),
        updated_at: 40,
      ),
    )
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)

    // Each row answers in the order asked, with `oldest_open_at` absent where
    // nothing is open.
    let resident_row =
      json.Object([
        #("session_id", json.String(rig.session)),
        #("pending_approvals", json.Int(0)),
        #("open_asks", json.Int(1)),
        #("open_finds", json.Int(0)),
        #("updated_at", json.Int(50)),
      ])
    let saved_row =
      json.Object([
        #("session_id", json.String(rig.saved)),
        #("pending_approvals", json.Int(1)),
        #("open_asks", json.Int(0)),
        #("open_finds", json.Int(2)),
        #("oldest_open_at", json.Int(30)),
        #("updated_at", json.Int(40)),
      ])
    let saved = saved_request(socket, 1, [rig.session, rig.saved], epoch)
    assert field(saved, "event") == json.String("sessions.saved_attention")
    assert body(saved, "saved") == json.Array([resident_row, saved_row])
    assert body(
        saved_request(socket, 6, [rig.saved, rig.session], epoch),
        "saved",
      )
      == json.Array([saved_row, resident_row])

    // The batch bound is `sessions.attention`'s, and so is the epoch rule.
    assert code(saved_request(socket, 2, [], epoch))
      == json.String("bad_request")
    assert code(saved_request(socket, 3, [rig.saved, rig.saved], epoch))
      == json.String("bad_request")
    let many =
      list.repeat(Nil, 25)
      |> list.index_map(fn(_, seed) {
        let #(id, _) = ids.mint_session(ids.generator(clock.fixed(0), seed))
        ids.session_id_to_string(id)
      })
    assert code(saved_request(socket, 4, many, epoch))
      == json.String("bad_request")
    assert code(saved_request(socket, 5, [rig.saved], "previous-epoch"))
      == json.String("stale_epoch")
    let _ = ffi_ws.tcp_close(socket)

    // A member is answered for what it holds and nothing else.
    let assert Ok(store) = catalogue.open(rig.state_root <> "/catalogue.db")
      as "the catalogue opens"
    let holder = string.repeat("b", 64)
    let bystander = string.repeat("c", 64)
    let assert Ok(held) =
      access.create_member(store, "sv-holder", "sv-holder", digest_of(holder))
    let assert Ok(Nil) =
      access.grant(store, held.id, rig.saved, access.Observer)
    let assert Ok(_) =
      access.create_member(
        store,
        "sv-bystander",
        "sv-bystander",
        digest_of(bystander),
      )
    let #(held_socket, _) = connect(port, holder, "/v2/control")
    let _ = frame(held_socket, within_ms: 1000)
    // Both sessions have a row, and the member holds only the saved one.
    assert body(
        saved_request(held_socket, 1, [rig.session, rig.saved], epoch),
        "saved",
      )
      == json.Array([saved_row])
    assert body(saved_request(held_socket, 2, [rig.session], epoch), "saved")
      == json.Array([])
    let _ = ffi_ws.tcp_close(held_socket)

    let #(by_socket, _) = connect(port, bystander, "/v2/control")
    let _ = frame(by_socket, within_ms: 1000)
    assert body(
        saved_request(by_socket, 1, [rig.session, rig.saved], epoch),
        "saved",
      )
      == json.Array([])
    let _ = ffi_ws.tcp_close(by_socket)
    assert catalogue.close(store) == Ok(Nil)
  })
}

// --- dismissing a stuck strand (protocol-change/131) -----------------------------

/// The operation a failed run is, from a seed.
fn failed_op(seed: Int) -> ids.OpId {
  let #(id, _) = ids.mint_op(ids.generator(clock.fixed(at: 5), seed:))
  id
}

/// Ends a strand's last run as failed, as a run's end writes it.
fn strand_fails(rig: Rig, strand: String, run: ids.OpId) -> Nil {
  let last =
    operation.RunLastResult(
      operation: run,
      leaf: None,
      outcome: operation.RunFailed(operation.OperationError(
        "provider",
        "overloaded",
        None,
      )),
      final_assistant: None,
    )
  let assert Ok(_) =
    writer.commit(
      rig.runtime.tree.writer,
      tx.Tx(
        [
          tx.SetRegister(
            register.StrandLastResult,
            strand,
            register.value(codec.encode_last_result(last)),
          ),
        ],
        [],
      ),
    )
    as "the failed result is committed"
  Nil
}

fn dismiss(
  socket,
  id: Int,
  session: String,
  strand: String,
  run: ids.OpId,
  epoch: String,
) -> JsonValue {
  send(
    socket,
    id,
    "attention.dismiss_stuck",
    json.Object([
      #("session", json.String(session)),
      #("strand", json.String(strand)),
      #("operation", json.String(ids.op_id_to_string(run))),
      #("epoch", json.String(epoch)),
    ]),
    within_ms: 1000,
  )
}

fn stuck_count(socket, id: Int, rig: Rig, epoch: String) -> JsonValue {
  let feed =
    send(
      socket,
      id,
      "sessions.attention",
      json.Object([
        #("sessions", json.Array([json.String(rig.session)])),
        #("epoch", json.String(epoch)),
      ]),
      within_ms: 1000,
    )
  let assert json.Array([row]) = body(feed, "attention") as "one row"
  field(field(row, "stuck"), "count")
}

pub fn the_owner_dismisses_a_stuck_strand_and_the_feed_drops_it_test() {
  with_rig(fn(_registry, port, credential, epoch, rig, _principal) {
    let #(socket, _) = connect(port, credential, "/v2/control")
    let _hello = frame(socket, within_ms: 1000)
    strand_fails(rig, "sub:main/a", failed_op(1))
    assert stuck_count(socket, 1, rig, epoch) == json.Int(1)

    // Each refusal leaves the strand listed.
    assert code(dismiss(
        socket,
        2,
        rig.session,
        "sub:main/a",
        failed_op(1),
        "previous-epoch",
      ))
      == json.String("stale_epoch")
    assert code(dismiss(
        socket,
        3,
        rig.session,
        "sub:main/a",
        failed_op(7),
        epoch,
      ))
      == json.String("conflict")
    assert code(dismiss(
        socket,
        4,
        rig.session,
        "sub:main/none",
        failed_op(1),
        epoch,
      ))
      == json.String("not_found")
    assert code(dismiss(socket, 5, rig.saved, "sub:main/a", failed_op(1), epoch))
      == json.String("not_resident")
    assert stuck_count(socket, 6, rig, epoch) == json.Int(1)

    // The dismissal names the strand and the failure, and the count falls.
    let done =
      dismiss(socket, 7, rig.session, "sub:main/a", failed_op(1), epoch)
    assert field(done, "event") == json.String("attention.dismiss_stuck")
    assert body(done, "strand") == json.String("sub:main/a")
    assert body(done, "operation")
      == json.String(ids.op_id_to_string(failed_op(1)))
    assert stuck_count(socket, 8, rig, epoch) == json.Int(0)

    // A strand that fails again is listed again, and a second press on the
    // first failure is stale.
    strand_fails(rig, "sub:main/a", failed_op(2))
    assert stuck_count(socket, 9, rig, epoch) == json.Int(1)
    assert code(dismiss(
        socket,
        10,
        rig.session,
        "sub:main/a",
        failed_op(1),
        epoch,
      ))
      == json.String("conflict")

    // A malformed request is refused before any registry call.
    let malformed =
      send(
        socket,
        11,
        "attention.dismiss_stuck",
        json.Object([
          #("session", json.String(rig.session)),
          #("strand", json.Int(3)),
          #("epoch", json.String(epoch)),
        ]),
        within_ms: 1000,
      )
    assert code(malformed) == json.String("bad_request")
    let _ = ffi_ws.tcp_close(socket)
    Nil
  })
}

pub fn members_dismiss_by_their_role_over_the_control_socket_test() {
  with_rig(fn(registry, port, _credential, epoch, rig, _principal) {
    let assert Ok(store) = catalogue.open(rig.state_root <> "/catalogue.db")
      as "the catalogue opens"
    let member = fn(name, token, role) {
      let assert Ok(principal) =
        access.create_member(store, name, name, digest_of(token))
        as "the member exists"
      case role {
        Some(held) -> {
          let assert Ok(Nil) =
            access.grant(store, principal.id, rig.session, held)
          Nil
        }
        None -> Nil
      }
    }
    let operator = string.repeat("4", 64)
    let observer = string.repeat("5", 64)
    let bystander = string.repeat("6", 64)
    member("dis-operator", operator, Some(access.Operator))
    member("dis-observer", observer, Some(access.Observer))
    member("dis-bystander", bystander, None)
    strand_fails(rig, "sub:main/a", failed_op(1))

    // An observer may read the session and may not change it, and a bystander
    // is told what an unknown session is told.
    let #(ob_socket, _) = connect(port, observer, "/v2/control")
    let _ = frame(ob_socket, within_ms: 1000)
    assert code(dismiss(
        ob_socket,
        1,
        rig.session,
        "sub:main/a",
        failed_op(1),
        epoch,
      ))
      == json.String("forbidden")
    assert stuck_count(ob_socket, 2, rig, epoch) == json.Int(1)
    let _ = ffi_ws.tcp_close(ob_socket)

    let #(by_socket, _) = connect(port, bystander, "/v2/control")
    let _ = frame(by_socket, within_ms: 1000)
    assert code(dismiss(
        by_socket,
        1,
        rig.session,
        "sub:main/a",
        failed_op(1),
        epoch,
      ))
      == json.String("not_found")
    let _ = ffi_ws.tcp_close(by_socket)

    // An Operator member dismisses, and the cell names it.
    let #(op_socket, _) = connect(port, operator, "/v2/control")
    let _ = frame(op_socket, within_ms: 1000)
    let done =
      dismiss(op_socket, 1, rig.session, "sub:main/a", failed_op(1), epoch)
    assert field(done, "event") == json.String("attention.dismiss_stuck")
    assert stuck_count(op_socket, 2, rig, epoch) == json.Int(0)
    let assert Ok([held]) = attention.dismissals(rig.runtime)
    let assert Ok(principal) =
      manager.authenticate(registry, digest_of(operator))
    assert held.by == principal.id
    let _ = ffi_ws.tcp_close(op_socket)
    assert catalogue.close(store) == Ok(Nil)
  })
}
