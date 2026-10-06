//// An operator's page against a real session gateway: the Lustre runtime
//// the page socket starts, over the relay the page socket builds, with the
//// page's ceiling at Operator. A prompt the page submits reaches the
//// session, and a denial the page decides settles the escalation it was
//// drawn from (protocol-change/051, the operator addendum, "Verification").
////
//// The browser is stood in for by the test: it reads the component's
//// patches to know when the page is connected, and dispatches the two
//// messages a browser's click and submit decode to.

import broker/escalation as broker_escalation
import broker/policy
import client/daemon/ui_relay
import client/gateway
import client/gateway_test
import client/grants
import core/clock
import core/ids
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json as gleam_json
import gleam/option.{None, Some}
import gleam/string
import host/bootstrap
import lustre
import lustre/server_component
import runtime/api
import runtime/escalation as durable
import session_view/operator
import session_view/snapshot
import storage/access
import web_view/component
import web_view/operator_page
import web_view/sessions
import weft/poll

fn fixture_id(seed: Int) -> ids.SessionId {
  let #(id, _) =
    ids.mint_session(ids.generator(clock.fixed(at: 1_700_000_000_000), seed))
  id
}

// How long each wait in this module lasts, in milliseconds. Every step here
// is a chain of asynchronous hops (the relay's attach, the lane's subscribe
// and first capture, the session's commit), and none of them arms a timer
// in the happy path, so a wait ends when the chain completes or never. A
// hang is therefore a stall, and a bound only has to be longer than the
// slowest scheduling the parallel client run produces. The 32-core signoff
// container ran 2328 client tests at once and starved this page past
// 5 000 ms once. Twenty seconds is the bound the daemon-driven client
// tests already use for a reply under the same load
// (`tui_approval_effect_test.reply_wait_ms`).
const patience_ms = 20_000

fn alice() -> access.Principal {
  access.Principal("alice", "Alice", access.MemberPrincipal)
}

// The page as `ui_socket` starts it for an operator's attachment: a relay
// capped at the page's ceiling, opened from inside the component's start.
fn start_page(
  harness: gateway_test.Harness,
) -> #(lustre.Runtime(operator_page.Msg(ui_relay.Relay)), Subject(_)) {
  let session = ids.session_id_to_string(api.session_id(harness.runtime))
  let assert Ok(digest) = access.credential_digest(string.repeat("a", 64))
    as "the fixture digest is valid"
  let attach =
    ui_relay.Attach(
      hub: harness.hub,
      binding: gateway.Binding(
        session_id: session,
        epoch: "epoch",
        incarnation: "incarnation",
        connection_id: "page-alice",
        principal: alice(),
        authority: access.Owner,
        digest:,
      ),
      check: fn() { Ok(#(alice(), access.Owner)) },
      ceiling: access.Operator,
      failed_reader: fn() { Nil },
    )
  let start =
    component.Start(
      session_id: session,
      label: None,
      workspace_digest: "",
      expected: snapshot.Expected(session, "epoch", "incarnation"),
      standing: component.unplaced,
      transport: component.Transport(
        connect: fn(inbox, opened) {
          ui_relay.start(attach, inbox, process.self(), opened, fn(_) { Nil })
        },
        transmit: ui_relay.transmit,
        shut: ui_relay.shut,
        now: bootstrap.monotonic_time_ms,
        sessions: fn(deliver) { deliver([]) },
        activity: fn(_, _) { Nil },
        open: fn(_) { sessions.Declined(sessions.NotHeld) },
        resume: fn(_, _) { Nil },
        invite: None,
        home: None,
        rename: None,
        shareable: None,
        worktree: None,
      ),
    )
  let assert Ok(runtime) =
    lustre.start_server_component(operator_page.app(), start)
    as "the operator's page starts"
  let client = process.new_subject()
  lustre.send(runtime, server_component.register_subject(client))
  #(runtime, client)
}

// Reads the component's messages for the browser until one says the page is
// following the session. The bound is one deadline for the whole wait: a
// page that keeps redrawing without connecting must not restart it with
// each patch, or a wait meant to be `within` long could run for that long
// per message.
fn await_connected(client, within: Int) -> Nil {
  await_connected_until(client, bootstrap.monotonic_time_ms() + within)
}

fn await_connected_until(client, deadline: Int) -> Nil {
  let remaining = int.max(0, deadline - bootstrap.monotonic_time_ms())
  let assert Ok(message) = process.receive(client, remaining)
    as "the page draws until it follows the session, inside the deadline"
  let text =
    gleam_json.to_string(server_component.client_message_to_json(message))
  case string.contains(text, "\"connected\"") {
    True -> Nil
    False -> await_connected_until(client, deadline)
  }
}

pub fn an_operators_page_prompts_and_denies_through_the_gateway_test() {
  let harness = gateway_test.reserved_fixture(fixture_id(5201))
  let assert Ok(Nil) =
    api.raise_escalation(
      harness.runtime,
      "esc-web",
      grants.encode_denial(
        reason: "tool requirements exceed the session policy",
        source: broker_escalation.PolicyDenial,
        wanted: [policy.GrantReadableRoot(path: "/")],
      ),
    )
    as "the escalation is filed"
  let assert Ok(before) = api.leaf(harness.runtime) as "the leaf reads"

  let #(runtime, client) = start_page(harness)
  await_connected(client, patience_ms)

  // The composer's submit, as the browser's form event decodes to it.
  lustre.send(
    runtime,
    lustre.dispatch(
      operator_page.Submitted("hello from the page", operator.Prompt, []),
    ),
  )
  let assert poll.Answered(_) =
    poll.until(within: patience_ms, every: 10, attempt: fn() {
      case api.leaf(harness.runtime) {
        Ok(leaf) if leaf != before -> poll.Done(leaf)
        Ok(_) | Error(_) -> poll.Retry
      }
    })
    as "the page's prompt reaches the session"

  // The card's Deny button, as the click decodes to it: the record's
  // identity and the sequence it was drawn at.
  let assert Ok(Some(cell)) =
    api.fact_cell(harness.runtime, "escalation/esc-web")
    as "the escalation's cell reads"
  lustre.send(
    runtime,
    lustre.dispatch(operator_page.Decided("esc-web", cell.seq, component.Deny)),
  )
  let assert poll.Answered(_) =
    poll.until(within: patience_ms, every: 10, attempt: fn() {
      case api.escalation(harness.runtime, "esc-web") {
        Ok(record) if record.status == durable.Rejected -> poll.Done(Nil)
        Ok(_) | Error(_) -> poll.Retry
      }
    })
    as "the page's denial settles the escalation"
  lustre.send(runtime, lustre.shutdown())
}
