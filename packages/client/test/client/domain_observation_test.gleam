//// Gateway observation admission uses the authenticated request path. A held
//// capture proves the pending acknowledgement releases the actor, while each
//// completion must return only to its original, still-authorized connection.

import client/gateway
import client/gateway_test
import client/protocol
import core/clock
import core/ids
import core/json
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import runtime/api
import storage/access
import support/addresses
import weft/actor
import weft/poll

type Socket {
  Socket(handle: gateway.ConnectionHandle, inbox: Subject(String))
}

fn request(
  socket: Socket,
  id: Int,
  command: protocol.Command,
) -> protocol.Event {
  let assert Ok(frame) =
    gateway.connection_request(
      socket.handle,
      protocol.encode_command(protocol.CommandEnvelope(id, command)),
    )
    as "the authenticated request returns its bounded response"
  let assert Ok(envelope) = protocol.decode_event(frame)
    as "the gateway response decodes"
  assert envelope.reply_to == Some(id)
  envelope.event
}

fn field(value, name) {
  let assert json.Object(fields) = value as "the observation is an object"
  let assert Ok(value) = list.key_find(fields, name)
    as "the observation field exists"
  value
}

fn attach(hub, runtime, identity: String, authority) -> Socket {
  let principal =
    access.Principal(identity, identity, case authority {
      access.Owner -> access.OwnerPrincipal
      access.Participant(_) -> access.MemberPrincipal
    })
  attach_checked(hub, runtime, principal, authority, fn() {
    Ok(#(principal, authority))
  })
}

fn attach_checked(
  hub,
  runtime,
  principal: access.Principal,
  authority,
  check,
) -> Socket {
  let assert Ok(digest) = access.credential_digest(string.repeat("a", 64))
    as "the fixture credential has the production shape"
  let assert Ok(socket) =
    actor.new(Nil)
    |> actor.on_message(fn(_state, _stop: Nil) { actor.stop() })
    |> actor.start
    as "the socket has an independently cancellable lifetime"
  let inbox = process.new_subject()
  let assert Ok(handle) =
    gateway.attach_authenticated(
      hub,
      gateway.Binding(
        ids.session_id_to_string(api.session_id(runtime)),
        "epoch",
        "incarnation",
        principal.id,
        principal,
        authority,
        digest,
      ),
      check,
      fn(frame) { process.send(inbox, frame) },
      fn() { process.send(socket.data, Nil) },
      fn() { Nil },
      socket.pid,
    )
    as "the fixture attaches with actual authority"
  let result = Socket(handle, inbox)
  let _ =
    request(
      result,
      1,
      protocol.Subscribe(
        ids.session_id_to_string(api.session_id(runtime)),
        None,
      ),
    )
  result
}

fn runtime() {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.stepping(1_756_000_000_000, 1), 91))
  gateway_test.reserved_fixture(id).runtime
}

fn final_frame(socket: Socket, id: Int) -> json.JsonValue {
  let assert poll.Answered(board) =
    poll.until(within: 5000, every: 1, attempt: fn() {
      case process.receive(socket.inbox, 0) {
        Ok(frame) ->
          case protocol.decode_event(frame) {
            Ok(protocol.EventEnvelope(
              reply_to: None,
              event: protocol.SnapshotEvent(protocol.WorktreeDiffSnapshot(board)),
              ..,
            ))
            | Ok(protocol.EventEnvelope(
                reply_to: None,
                event: protocol.SnapshotEvent(protocol.ContextSnapshot(board)),
                ..,
              )) ->
              case field(board, "request_id") == json.Int(id) {
                True -> poll.Done(board)
                False -> poll.Retry
              }
            _ -> poll.Retry
          }
        Error(Nil) -> poll.Retry
      }
    })
    as "the original request receives a pushed final observation"
  board
}

pub fn worktree_admission_is_owner_only_bounded_and_nonblocking_test() {
  let runtime = runtime()
  let started = process.new_subject()
  let capture = fn() {
    let release = process.new_subject()
    process.send(started, release)
    let assert Ok(Nil) = process.receive(release, 5000)
      as "the fixture releases its bounded capture"
    Ok(json.Object([#("entries", json.Array([]))]))
  }
  let options =
    gateway.default_options("observations", runtime)
    |> gateway.with_worktree_diff(capture)
    |> gateway.with_live_jobs(fn(strand) {
      Ok(
        json.Object([
          #("strand", json.String(strand)),
          #("jobs", json.Array([])),
        ]),
      )
    })
  let assert Ok(hub) = gateway.start(options, addresses.new())
    as "the observation gateway starts"
  let owner = attach(hub.data, runtime, "owner", access.Owner)
  let second = attach(hub.data, runtime, "second", access.Owner)
  let third = attach(hub.data, runtime, "third", access.Owner)
  let operator =
    attach(hub.data, runtime, "operator", access.Participant(access.Operator))
  let observer =
    attach(hub.data, runtime, "observer", access.Participant(access.Observer))
  list.each([operator, observer], fn(socket) {
    let assert protocol.ErrorEvent(code: "forbidden", ..) =
      request(socket, 2, protocol.WorktreeDiffGet)
      as "transcript access does not authorize workspace observation"
  })
  let assert protocol.SnapshotEvent(protocol.WorktreeDiffSnapshot(pending)) =
    request(owner, 3, protocol.WorktreeDiffGet)
    as "the capture starts with a pending acknowledgement"
  assert field(pending, "status") == json.String("pending")
  assert field(pending, "request_id") == json.Int(3)
  let assert Ok(release_first) = process.receive(started, 1000)
    as "the capture actually runs outside the gateway"
  let assert protocol.ErrorEvent(code: "busy", ..) =
    request(owner, 4, protocol.WorktreeDiffGet)
    as "one connection cannot admit a second capture"
  let assert protocol.SnapshotEvent(protocol.LiveJobsSnapshot(_)) =
    request(owner, 5, protocol.LiveJobsGet("main"))
    as "another command completes while Git remains held"
  let _ = request(second, 6, protocol.WorktreeDiffGet)
  let assert Ok(release_second) = process.receive(started, 1000)
    as "the second global slot starts"
  let assert protocol.ErrorEvent(code: "busy", ..) =
    request(third, 7, protocol.WorktreeDiffGet)
    as "two captures bound global admission"
  process.send(release_first, Nil)
  assert field(final_frame(owner, 3), "status") == json.String("ready")
  process.send(release_second, Nil)
  assert field(final_frame(second, 6), "request_id") == json.Int(6)
}

pub fn worktree_failure_is_explicit_and_detach_cancels_the_original_worker_test() {
  let runtime = runtime()
  let started = process.new_subject()
  let options =
    gateway.default_options("observations", runtime)
    |> gateway.with_worktree_diff(fn() {
      process.send(started, process.self())
      process.sleep_forever()
      Error("unreachable")
    })
  let assert Ok(hub) = gateway.start(options, addresses.new())
    as "the observation gateway starts"
  let owner = attach(hub.data, runtime, "owner", access.Owner)
  let _ = request(owner, 10, protocol.WorktreeDiffGet)
  let assert Ok(worker) = process.receive(started, 1000)
    as "the controlled worker started"
  let watch = process.monitor(worker)
  gateway.connection_detach(owner.handle)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(watch, fn(down) { down })
    |> process.selector_receive(5000)
    as "original socket closure cancels the worktree worker"
  let unavailable = attach(hub.data, runtime, "replacement", access.Owner)
  let assert protocol.ErrorEvent(code: "unavailable", ..) =
    request(unavailable, 11, protocol.LiveJobsGet("main"))
    as "a missing jobs capability is distinct from an empty roster"
}

pub fn worktree_capture_failures_and_revoked_results_are_not_empty_success_test() {
  let runtime = runtime()
  list.each(
    [
      fn() { Error("capture refused by its policy") },
      fn() { panic as "scripted capture crash" },
    ],
    fn(capture) {
      let options =
        gateway.default_options("observations", runtime)
        |> gateway.with_worktree_diff(capture)
      let assert Ok(hub) = gateway.start(options, addresses.new())
        as "the failing observation gateway starts"
      let owner = attach(hub.data, runtime, "owner", access.Owner)
      let _ = request(owner, 20, protocol.WorktreeDiffGet)
      let board = final_frame(owner, 20)
      assert field(board, "status") == json.String("failed")
      assert field(board, "code") == json.String("unavailable")
    },
  )

  let principal = access.Principal("revoked", "Owner", access.OwnerPrincipal)
  let assert Ok(auth) =
    actor.new(Ok(#(principal, access.Owner)))
    |> actor.on_message(fn(state, message) {
      case message {
        Probe(reply) -> {
          process.send(reply, state)
          actor.continue(state)
        }
        Revoke -> actor.continue(Error("owner credential revoked"))
      }
    })
    |> actor.start
    as "the fixture can revoke authority while capture is held"
  let started = process.new_subject()
  let options =
    gateway.default_options("observations", runtime)
    |> gateway.with_worktree_diff(fn() {
      let release = process.new_subject()
      process.send(started, release)
      let assert Ok(Nil) = process.receive(release, 5000)
        as "the fixture releases its captured sensitive bytes"
      Ok(json.Object([#("secret", json.String("never deliver"))]))
    })
  let assert Ok(hub) = gateway.start(options, addresses.new())
    as "the revocation gateway starts"
  let owner =
    attach_checked(hub.data, runtime, principal, access.Owner, fn() {
      actor.call(auth.data, 1000, Probe)
    })
  let _ = request(owner, 21, protocol.WorktreeDiffGet)
  let assert Ok(release) = process.receive(started, 1000)
    as "the owner was admitted before revocation"
  process.send(auth.data, Revoke)
  let assert Error(_) = actor.call(auth.data, 1000, Probe)
    as "revocation is ordered before capture delivery"
  process.send(release, Nil)
  let assert poll.Answered(Nil) =
    poll.until(within: 5000, every: 1, attempt: fn() {
      case gateway.attached(hub.data) == 0 {
        True -> poll.Done(Nil)
        False -> poll.Retry
      }
    })
    as "delivery revalidation retires the revoked original attachment"
  assert no_observation(owner.inbox, 21, 100)
    as "captured workspace bytes never reach the revoked owner"
}

type AuthProbe {
  Probe(reply: Subject(Result(#(access.Principal, access.Authority), String)))
  Revoke
}

fn no_observation(inbox: Subject(String), id: Int, remaining: Int) -> Bool {
  case remaining <= 0 {
    True -> False
    False ->
      case process.receive(inbox, 0) {
        Error(Nil) -> True
        Ok(frame) ->
          case protocol.decode_event(frame) {
            Ok(protocol.EventEnvelope(
              event: protocol.SnapshotEvent(protocol.WorktreeDiffSnapshot(board)),
              ..,
            ))
            | Ok(protocol.EventEnvelope(
                event: protocol.SnapshotEvent(protocol.ContextSnapshot(board)),
                ..,
              )) ->
              field(board, "request_id") != json.Int(id)
              && no_observation(inbox, id, remaining - 1)
            _ -> no_observation(inbox, id, remaining - 1)
          }
      }
  }
}

pub fn context_is_an_ordinary_read_and_shares_bounded_observation_slots_test() {
  let runtime = runtime()
  let started = process.new_subject()
  let capture = fn() {
    let release = process.new_subject()
    process.send(started, release)
    let assert Ok(Nil) = process.receive(release, 5000)
      as "the fixture releases its read worker"
    Ok(json.Object([#("strand", json.String("main"))]))
  }
  let options =
    gateway.default_options("context-observations", runtime)
    |> gateway.with_context(fn(_) { capture() })
    |> gateway.with_worktree_diff(capture)
  let assert Ok(hub) = gateway.start(options, addresses.new())
    as "the shared observation gateway starts"
  let observer =
    attach(
      hub.data,
      runtime,
      "context-observer",
      access.Participant(access.Observer),
    )
  let owner = attach(hub.data, runtime, "context-owner", access.Owner)
  let third = attach(hub.data, runtime, "context-third", access.Owner)
  let assert protocol.SnapshotEvent(protocol.ContextSnapshot(pending)) =
    request(observer, 30, protocol.ContextGet("main"))
    as "an observer can inspect the context it can read"
  assert field(pending, "status") == json.String("pending")
  let assert Ok(release_context) = process.receive(started, 1000)
    as "context runs outside the gateway handler"
  let assert protocol.ErrorEvent(code: "busy", ..) =
    request(observer, 31, protocol.ContextGet("main"))
    as "one context worker occupies this connection's only slot"
  let assert protocol.ErrorEvent(code: "forbidden", ..) =
    request(observer, 32, protocol.WorktreeDiffGet)
    as "ordinary context access does not widen workspace access"
  let assert protocol.SnapshotEvent(protocol.WorktreeDiffSnapshot(_)) =
    request(owner, 33, protocol.WorktreeDiffGet)
    as "worktree reads occupy the same worker pool"
  let assert Ok(release_worktree) = process.receive(started, 1000)
    as "the second shared slot starts"
  let assert protocol.ErrorEvent(code: "busy", ..) =
    request(third, 34, protocol.ContextGet("main"))
    as "mixed observers cannot exceed the global bound"
  process.send(release_context, Nil)
  assert field(final_frame(observer, 30), "status") == json.String("ready")
  process.send(release_worktree, Nil)
  assert field(final_frame(owner, 33), "status") == json.String("ready")
}
