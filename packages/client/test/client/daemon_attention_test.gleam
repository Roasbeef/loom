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
import client/daemon_server_test.{connect, fixture_building, frame, send}
import client/gateway_test
import client/internal/ffi_os
import client/peer_mail
import core/agency_limits
import core/attention as records
import core/clock
import core/ids
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import host/bootstrap
import runtime/api
import storage/access
import storage/catalogue
import support/internal/ffi_ws
import tools/agent
import tools/attention as tool_attention
import web_view/session_brief
import web_view/thread_send
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
  let runtime = gateway_test.reserved_fixture(resident).runtime
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
  fixture_building(
    limits.defaults,
    endpoint,
    fn(record, _domain, _services, _owner, _directory) { Ok(record.id) },
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

    // One prompt, to the strand that asked, worded as 119 specifies.
    let assert Ok(#(strand, text)) = process.receive(seen, 0)
    assert strand == "sub:main/audit"
    assert string.starts_with(text, "Answer to " <> rig.ask <> ":\n\n```json\n")
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

fn result_is_ok(result: Result(a, b)) -> Bool {
  case result {
    Ok(_) -> True
    Error(_) -> False
  }
}
