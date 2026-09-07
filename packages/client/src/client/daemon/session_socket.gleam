//// The v2 resident-session transport, with no anonymous or v1 upgrade path.
//// HTTP authentication has already resolved the immutable attachment. The
//// actual WebSocket process takes the root's parser permit in its first
//// handler turn, then monitors the original gateway rather than its
//// restartable name. Each received frame waits for one bounded gateway reply
//// before the parser accepts another. Snapshot continuation uses the
//// gateway's bounded reader.
////
//// ## Two kinds of write, one writer
////
//// Since `protocol-change/018` the hub also *pushes* frames this socket
//// never asked for — a `committed` notice, a stream delta, the presence
//// roster, a fault. They arrive as `Push` messages, because the hub's sink
//// runs on the hub process and must not block on a socket write; this
//// process writes them from its own handler turn.
////
//// So "one bounded reply per received frame" remains true of *the parser*
//// and is no longer true of the socket: what a request buys is the right to
//// send the next request, not silence in between. Both writes happen here,
//// serialised by this process's mailbox, so a reply and a push never
//// interleave mid-frame and a notice for a sequence is never written ahead
//// of a reply computed after that sequence committed. The client is not
//// asked to depend on that ordering — a notice is idempotent and order-free
//// — but it holds.
////
//// ## Why admission is a message and not an initializer
////
//// mist starts every websocket process with a 500 ms initializer budget it
//// does not expose (`actor.new_with_initialiser(500, ...)` in mist's internal
//// websocket module), and an initializer that overruns it is killed together
//// with its TCP socket, which the peer reads as an abrupt close rather than a
//// refusal. Admission here is two cross-actor calls — the root's permit
//// transfer and the gateway's authenticated attach — whose own budgets total
//// six seconds, because either actor may be part-way through slower work.
//// Spending those inside the initializer made a loaded daemon on a small CI
//// runner drop sockets that a wider budget would only have dropped later. So
//// `on_init` mints its subjects, sends itself `Admit`, and returns; the
//// handler pays for admission where no deadline is watching.

import client/daemon/manager
import client/daemon/root
import client/daemon/server
import client/gateway
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/option.{Some}
import gleam/result
import mist
import storage/access

type Signal {
  // The self-addressed message that runs admission. `on_init` queues it and
  // nothing else ever sends it.
  Admit

  Refused

  GatewayDown(process.Down)

  // One encoded frame the hub decided to send with no request outstanding:
  // a `committed` notice, a stream delta, the roster, or a fault
  // (`protocol-change/018`). The hub's sink runs on the hub process and
  // does nothing but hand the text over here, because the sink must not
  // block and a socket write can.
  Push(frame: String)
}

// Where this socket's process sits in the two-step admission above. There is
// no refused variant, because a refusal never becomes a state: the handler
// stops from its admission turn, so `on_close` only ever sees these two.
type Phase {
  // Admission has not run yet. The subject is the one `on_init` selected on,
  // carried so the attach can hand its callbacks a sink reaching this process.
  Pending(outbound: process.Subject(Signal))

  // Admission succeeded, and this handle names the original gateway process
  // rather than its restartable name.
  Admitted(connection: gateway.ConnectionHandle)
}

/// Upgrades one server-resolved resident session with its admitted parser limit.
///
/// The default listener must bind loopback; remote cleartext serving is not a
/// supported deployment. The callback passed to the daemon router supplies the
/// exact gateway from `attachment.instance`, never one selected by a frame.
///
/// ## Examples
///
/// ```gleam
/// // session_socket.upgrade(root, request, attachment, attachment.instance.gateway)
/// ```
pub fn upgrade(
  daemon: root.Root(instance),
  request: Request(mist.Connection),
  attachment: server.Attachment(instance),
  hub: gateway.Gateway,
) -> Response(mist.ResponseData) {
  let class = case attachment.authority {
    access.Participant(access.Observer) -> root.Observer
    access.Owner | access.Participant(access.Operator) -> root.Operator
  }
  let limit = root.message_limit(class)

  // The barrier that keeps the permit's custody transfer ordered against this
  // HTTP process's own release. This process owns it; the websocket process
  // signals it once the transfer has been attempted.
  let settled = process.new_subject()
  let response =
    mist.websocket_with_options(
      request:,
      options: mist.WebsocketOptions(limit, limit, mist.CompressionDisabled),
      on_init: fn(_) {
        let outbound = process.new_subject()

        // This send is what makes admission-by-message safe to order against
        // the peer's own traffic. mist starts this process through its factory
        // supervisor and hands over the socket only afterwards: the transfer
        // of TCP ownership and the `set_active` that arms the parser both run
        // in `mist.websocket_upgrade` *after* the initializer has returned. So
        // `Admit` is in this mailbox before the socket can deliver a byte, and
        // it is the first message the handler sees.
        process.send(outbound, Admit)
        #(
          Pending(outbound),
          Some(process.new_selector() |> process.select(outbound)),
        )
      },
      handler: fn(phase, event, socket) {
        case phase, event {
          Pending(outbound), mist.Custom(Admit) ->
            admit(daemon, attachment, hub, outbound, settled)

          // Unreachable, for the ordering reason given above: nothing can be
          // delivered to a pending socket before its own `Admit`. A push is
          // unreachable here for a second reason of its own — the hub learns
          // the sink from the attach *inside* the admission turn, so the
          // earliest push it can send is already read in the `Admitted`
          // phase. The arms are spelled out rather than folded into a
          // catch-all so that a change to mist's start sequence fails closed
          // on an unadmitted frame instead of quietly serving one.
          Pending(_), mist.Text(_)
          | Pending(_), mist.Binary(_)
          | Pending(_), mist.Closed
          | Pending(_), mist.Shutdown
          | Pending(_), mist.Custom(Refused)
          | Pending(_), mist.Custom(GatewayDown(_))
          | Pending(_), mist.Custom(Push(_))
          -> mist.stop()

          Admitted(connection), mist.Text(frame) ->
            respond(connection, frame, socket)

          // A pushed frame is written the same way a reply is and on the
          // same process, so the two cannot interleave mid-frame and a
          // failed write means the same thing either way: the socket is
          // gone, and continuing would leave an armed parser attached to
          // a transport that cannot answer.
          Admitted(connection), mist.Custom(Push(frame)) ->
            case mist.send_text_frame(socket, frame) {
              Ok(_) -> mist.continue(Admitted(connection))
              Error(_) -> mist.stop()
            }

          Admitted(_), mist.Binary(_)
          | Admitted(_), mist.Closed
          | Admitted(_), mist.Shutdown
          | Admitted(_), mist.Custom(Admit)
          | Admitted(_), mist.Custom(Refused)
          | Admitted(_), mist.Custom(GatewayDown(_))
          -> mist.stop()
        }
      },
      on_close: fn(phase) {
        case phase {
          Admitted(connection) -> gateway.connection_detach(connection)
          Pending(_) -> Nil
        }
      },
    )

  // Hold this HTTP process until the websocket process has attempted the
  // transfer. Its caller releases the reservation the moment this returns and
  // then exits; either would race a transfer still in flight, and a release
  // that won would leave the socket refused with its accounting already freed.
  // The reply is consumed from the one process that sends it, so this orders
  // the two rather than assuming anything about two senders.
  //
  // On a transfer the root answers promptly this waits exactly as long as the
  // initializer used to. What it no longer does is give up at 500 ms: the
  // budget here covers the transfer's own second with room for a starved
  // websocket process that has not yet been scheduled to make it, so a root
  // that answers late is served rather than dropped. The full wait is only
  // ever paid on a doomed path, by a process about to exit that blocks no
  // other connection. A root too wedged to answer at all ends where it did
  // before — the wait expires, the reservation is released, and the late
  // transfer refuses its own socket.
  case response.body {
    mist.Websocket -> {
      let _ = process.receive(settled, within: 5000)
      Nil
    }

    // No websocket process was started, so nothing will ever signal; mist
    // answers a failed start with an empty 400.
    mist.Bytes(_) | mist.Chunked | mist.File(..) | mist.ServerSentEvents -> Nil
  }
  response
}

// Takes the root's permit and attaches to the original gateway, in the handler
// turn rather than the initializer. `process.self()` is still the websocket
// process here, so the permit's new owner and the PID the gateway monitors are
// the ones the initializer would have named; moving these calls changed when
// the work happens, not whose custody it transfers.
fn admit(
  daemon: root.Root(instance),
  attachment: server.Attachment(instance),
  hub: gateway.Gateway,
  outbound: process.Subject(Signal),
  settled: process.Subject(Nil),
) -> mist.Next(Phase, Signal) {
  let transferred = root.transfer(daemon, attachment.permit, within: 1000)

  // Custody is decided either way now, so the waiting HTTP process is released
  // before the attach below, which answers to a different actor and can take
  // several seconds of its own.
  process.send(settled, Nil)
  let admitted = {
    use Nil <- result.try(transferred)
    gateway.attach_authenticated(
      hub,
      // Four of these are adjacent strings that the source record happens
      // to declare in the same order, so positional arguments would let a
      // field added to either record compile into a binding whose repeated
      // authorization compares the wrong identity.
      gateway.Binding(
        session_id: attachment.session_id,
        epoch: attachment.epoch,
        incarnation: attachment.incarnation,
        connection_id: attachment.connection_id,
        principal: attachment.principal,
        authority: attachment.authority,
        digest: attachment.digest,
      ),
      fn() { authorize(attachment) },
      // The outbound sink. It runs on the hub process, so it does the
      // one thing that cannot block there and leaves the socket write
      // to the process that owns the socket.
      fn(frame) { process.send(outbound, Push(frame)) },
      fn() { process.send(outbound, Refused) },
      fn() { failed_reader(attachment) },
      process.self(),
    )
  }
  case admitted {
    // Continuing would leave an armed parser attached to nothing. A stop from
    // a handler turn is terminal: `on_close` sees `Pending` and detaches
    // nothing, the peer gets a close frame rather than a torn socket, and the
    // root frees the refused capacity on the DOWN it already watches for.
    Error(_) -> mist.stop()
    Ok(connection) -> {
      // The replacement selector must carry `outbound` as well as the monitor:
      // mist swaps the whole user selector for the one a handler turn returns.
      let watch = process.monitor(gateway.connection_pid(connection))
      mist.continue(Admitted(connection))
      |> mist.with_selector(
        process.new_selector()
        |> process.select(outbound)
        |> process.select_specific_monitor(watch, GatewayDown),
      )
    }
  }
}

// The synchronous exchange admits one request at a time. A missing response is
// an unknown outcome, so closing the socket must not retry the command.
//
// What this call bounds is *the parser*: no second request is admitted until
// this one is answered. It is not a claim that nothing else is written in
// between. Pushed frames (`protocol-change/018`) are written from the same
// process, from their own handler turn, and this one blocks in
// `connection_request` while it waits — so a push that arrives mid-request
// waits in the mailbox and is written after the reply, and a push that
// arrives between requests is written immediately. Either way the two writes
// are strictly ordered by this process's own mailbox, which is the whole of
// the ordering argument the design note makes: one writer, one queue, no
// interleaving mid-frame. A client is not asked to rely on it — a notice is
// idempotent and order-free by design — but the daemon does not depend on the
// client being careful either.
//
// Authorization is not re-asked here. The gateway checks the binding twice for
// this one command — once when it admits it and once immediately before it
// hands back the reply — and closes the attachment itself when either answer
// has changed, so a third check on this side would repeat the second with the
// same evidence and add another round trip to every frame. A pushed frame is
// checked on the same `check_binding`, once, immediately before the hub hands
// it to this sink.
fn respond(connection, frame, socket) {
  let sent = {
    use response <- result.try(gateway.connection_request(connection, frame))
    mist.send_text_frame(socket, response)
    |> result.replace_error("socket delivery failed")
  }
  case sent {
    Ok(Nil) -> mist.continue(Admitted(connection))
    Error(_) -> mist.stop()
  }
}

// This returns after stop admission, not after retiring this requesting socket
// or gateway. The registry compares the original incarnation atomically.
fn failed_reader(attachment: server.Attachment(instance)) -> Nil {
  // The attachment carries its registry so this request cannot be lost to a
  // readiness round trip that times out: a poisoned hub whose stop never
  // reached the registry left the session resident and every later
  // attachment refused until the daemon restarted.
  let _ =
    manager.stop_if_incarnation(
      attachment.registry,
      attachment.session_id,
      attachment.incarnation,
    )
  Nil
}

// One registry turn answers the three facts a frame's authority rests on: this
// daemon's lifetime, the session's retained incarnation, and the credential's
// current membership. Asking them separately cost three cross-actor calls per
// check, and the gateway performs two checks for every command. The registry
// compares the epoch itself, so the root is not consulted at all on this
// path. It is asked afresh each time rather than cached, so a credential
// revoked between a command's admission and its delivery still closes the
// attachment.
fn authorize(attachment: server.Attachment(instance)) {
  manager.frame_authority(
    attachment.registry,
    epoch: attachment.epoch,
    id: attachment.session_id,
    incarnation: attachment.incarnation,
    digest: attachment.digest,
  )
  |> result.map_error(refusal)
}

// A refusal keeps the words the attached client already saw for each of these,
// so collapsing three calls into one did not change what a closed socket says.
fn refusal(refused: manager.FrameRefusal) -> String {
  case refused {
    manager.StaleEpoch -> "stale epoch"
    manager.StaleIncarnation -> "stale incarnation"
    manager.Unauthorized -> "unauthorized"
    manager.RegistryUnavailable -> "daemon registry is unavailable"
  }
}
