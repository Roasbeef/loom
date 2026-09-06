//// Three actual terminal drivers use credentials issued by the owner CLI path.
//// The fixture's scripted session supplies a pending policy request; only the
//// terminal approve/deny commands may resolve it. No test writes a resolution.

import broker/escalation as broker_escalation
import broker/policy
import client/daemon/admin
import client/grants
import client/session_socket_test
import client/tui_v2_test
import core/json
import core/register
import core/tx
import etui/backend
import etui/widgets/textarea
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import runtime/escalation
import runtime/writer
import support/tui_driver
import tui
import tui/approval
import tui/session_channel
import tui/snapshot
import weft

fn invited(address, owner, epoch, session, principal, role, name) {
  let assert Ok(request) =
    admin.parse(["invite", session, principal, role, name])
    as "owner administration uses the shipped CLI parser"
  let assert Ok(json.Object(fields)) =
    admin.exchange(address, owner, epoch, request)
    as "the real epoch-fenced control command issues one member credential"
  let assert Ok(json.String(bearer)) = list.key_find(fields, "bearer")
    as "the secret is returned once and never printed"
  bearer
}

fn writable(sample: tui_driver.Sample) {
  case sample.model.channel {
    Some(channel) -> session_channel.mutation_available(channel)
    None -> False
  }
}

fn decision(sample: tui_driver.Sample, id) {
  list.find(sample.model.approvals, fn(record) { record.id == id })
}

fn resolved(sample: tui_driver.Sample, id) {
  case decision(sample, id) {
    Ok(record) -> record.status != approval.Pending && record.origin != None
    Error(Nil) -> False
  }
}

fn send(driver, command) {
  tui_driver.play(driver, [backend.Paste(command), backend.KeyPress("enter")])
}

pub fn tui_multiplayer_operators_race_exact_approval_and_observer_sees_winner_test() {
  session_socket_test.fixture(fn(port, owner, session, epoch, harness) {
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let alice_token =
      invited(address, owner, epoch, session, "alice", "operator", "Alice")
    let bob_token =
      invited(address, owner, epoch, session, "bob", "operator", "Bob")
    let observer_token =
      invited(address, owner, epoch, session, "reader", "observer", "Reader")
    let assert Ok(alice) = tui_driver.start(address, alice_token, session)
      as "Alice owns a distinct operator terminal"
    let assert Ok(bob) = tui_driver.start(address, bob_token, session)
      as "Bob owns a second operator terminal"
    let assert Ok(observer) = tui_driver.start(address, observer_token, session)
      as "an observer attaches to resident metadata without requesting open authority"
    let _ = tui_v2_test.await(alice.data, writable)
    let _ = tui_v2_test.await(bob.data, writable)
    let observed =
      tui_v2_test.await(observer.data, fn(sample) {
        case sample.model.captured {
          Some(#(cut, view)) ->
            cut.attachment.role == snapshot.Observer
            && list.length(view.peers) == 3
          None -> False
        }
      })
    assert !writable(observed)

    // A metadata-only configuration change must carry the same human origin
    // to operators and observer, independently of the transcript cursor.
    let _ = send(alice.data, "/effort high")
    let changed = fn(sample: tui_driver.Sample) {
      case sample.model.captured {
        Some(#(_, view)) ->
          case dict.get(view.configurations, "main") {
            Ok(config) ->
              case config.origin {
                Some(origin) -> origin.principal == "alice"
                None -> False
              }
            Error(Nil) -> False
          }
        None -> False
      }
    }
    let _ = tui_v2_test.await(alice.data, changed)
    let _ = tui_v2_test.await(bob.data, changed)
    let before = tui_v2_test.await(observer.data, changed)
    assert string.contains(before.frame, "changed by Alice")
    let assert Some(#(before_cut, before_view)) = before.model.captured
      as "observer has the shared coherent configuration cut"

    let pending =
      escalation.raised(
        "ui-approval",
        grants.encode_denial(
          "timeout requires consent",
          broker_escalation.PolicyDenial,
          [policy.GrantLimit(policy.WallSeconds, 60)],
        ),
        action: Some(escalation.Action("bash", "same-action", "sleep 60")),
        scope: None,
      )
    let assert Ok(_) =
      writer.commit(
        harness.runtime.tree.writer,
        tx.Tx(
          [
            tx.SetRegister(
              register.FactCustom,
              escalation.register_key(pending.id),
              register.value(escalation.encode(pending)),
            ),
          ],
          [],
        ),
      )
      as "only the pending request is fixture setup; no resolution is injected"
    let has_pending = fn(sample) {
      case decision(sample, pending.id) {
        Ok(record) -> record.status == approval.Pending
        Error(Nil) -> False
      }
    }
    let a =
      tui_v2_test.await(alice.data, fn(sample) {
        has_pending(sample) && writable(sample)
      })
    let b =
      tui_v2_test.await(bob.data, fn(sample) {
        has_pending(sample) && writable(sample)
      })
    let _ = tui_v2_test.await(observer.data, has_pending)
    let assert Ok(a_question) = decision(a, pending.id)
      as "Alice captured a pending question"
    let assert Ok(b_question) = decision(b, pending.id)
      as "Bob captured the same question"
    assert a_question == b_question
    list.each([alice.data, bob.data, observer.data], fn(driver) {
      let _ = tui_driver.play(driver, [backend.Resize(110, 30)])
      let _ = send(driver, "/approvals ui-approval")
      let inspected =
        tui_v2_test.await(driver, fn(sample) {
          case sample.model.overlay {
            tui.ApprovalInspector(_) ->
              string.contains(sample.frame, "EXACT APPROVAL")
            _ -> False
          }
        })
      assert string.contains(inspected.frame, "same-action")
      assert string.contains(inspected.frame, "wall_seconds")
      assert string.contains(
        inspected.frame,
        "\"seq\":" <> int.to_string(a_question.seq),
      )
      let closed = tui_driver.play(driver, [backend.KeyPress("esc")])
      assert closed.model.overlay == tui.NoOverlay
      Nil
    })
    let _ = tui_v2_test.await(alice.data, writable)
    let _ = tui_v2_test.await(bob.data, writable)
    let blocked = send(observer.data, "/deny ui-approval")
    assert textarea.value(blocked.model.input) == "/deny ui-approval"
    assert decision(blocked, pending.id) == Ok(a_question)

    // Both terminal inputs race under the existing managed test-run boundary.
    // Their commands carry the captured seq; no transport or task resends one.
    let outcomes =
      weft.new([
        fn() { Ok(send(alice.data, "/approve ui-approval")) },
        fn() { Ok(send(bob.data, "/deny ui-approval")) },
      ])
      |> weft.deadline(5000)
      |> weft.start
    assert list.length(weft.values(outcomes)) == 2
    let a =
      tui_v2_test.await(alice.data, fn(sample) { resolved(sample, pending.id) })
    let b =
      tui_v2_test.await(bob.data, fn(sample) { resolved(sample, pending.id) })
    let o =
      tui_v2_test.await(observer.data, fn(sample) {
        resolved(sample, pending.id)
      })
    let assert Ok(winner) = decision(a, pending.id)
      as "the exact lookup supplies the committed winner"
    assert decision(b, pending.id) == Ok(winner)
    assert decision(o, pending.id) == Ok(winner)

    // Both commands carry the same captured seq and the escalation register's
    // compare-and-set admits exactly one of them, so the winning write sits
    // one sequence above the question. Without that fence both decisions
    // commit in turn and the terminal record sits two above — an outcome
    // "greater than" cannot tell from this one.
    assert winner.seq == a_question.seq + 1
    let assert Some(author) = winner.origin
      as "resolution author comes from the winning durable record"
    let loser = case winner.status {
      approval.Approved -> {
        assert author.principal == "alice"
        bob.data
      }
      approval.Rejected -> {
        assert author.principal == "bob"
        alice.data
      }
      approval.Pending | approval.Consumed ->
        panic as "exactly one explicit decision wins"
    }

    // The losing operator is refused rather than quietly ignored, but that
    // refusal is not asserted here. `append_error` puts it in the transcript
    // and the notice, and the very cut that carries the winner's resolution
    // replaces the transcript while the next presence line replaces the
    // notice, so the loser's terminal holds no durable trace of it by the time
    // this driver samples. The wire-level refusal (`stale_approval`) is pinned
    // by tui_approval_effect_test, and the seq arithmetic above already proves
    // exactly one decision committed. Making local refusals survive a cut is
    // a terminal change recorded as a follow-up, not a test to loosen.
    let _ = loser
    assert string.contains(o.frame, author.name)
    let assert Some(#(after_cut, after_view)) = o.model.captured
      as "decision lookup never substitutes its sparse metadata for the conversation view"
    assert after_cut.window == before_cut.window
    assert after_view.configurations == before_view.configurations
    tui_driver.stop(observer.data)
    tui_driver.stop(bob.data)
    tui_driver.stop(alice.data)
    Nil
  })
}
