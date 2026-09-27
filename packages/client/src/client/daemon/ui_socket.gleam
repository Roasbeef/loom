//// The page's WebSocket: Lustre's transport between one browser and one
//// server component, which drives the session's lane through a relay
//// (protocol-change/051).
////
//// `client/daemon/server` has already checked the request's host, origin and
//// cookie, re-authenticated the credential that minted the page's ticket,
//// resolved the resident session and reserved an observer's parser permit.
//// This module does what `session_socket` does for a terminal with the rest:
//// it takes the permit's custody in the socket's first handler turn, and
//// then, instead of serving v2 frames, it starts the component and carries
//// Lustre's messages in both directions.
////
//// One component per connection. It is started from this socket's process
//// and linked to it, and the socket shuts it down when the browser goes
//// away, which is what ends its relay (the relay monitors the component).
//// When the relay ends from the gateway's side (the session stopped, or the
//// attachment was revoked) it tells this socket, which closes, so a revoked
//// page does not stay open showing a transcript it may no longer read.

import client/daemon/manager
import client/daemon/root
import client/daemon/server
import client/daemon/ui_relay
import client/gateway
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{Some}
import gleam/result
import host/bootstrap
import lustre
import lustre/server_component
import mist
import session_view/snapshot
import web_view/component

type Page =
  component.Msg(ui_relay.Relay)

type Signal {
  // The self-addressed message that runs admission, queued by `on_init`.
  Admit

  // One message from the component for the browser's client runtime.
  Client(server_component.ClientMessage(Page))

  // The relay ended from the gateway's side; the page closes.
  Ended(reason: String)
}

type Phase {
  Pending(signals: process.Subject(Signal))
  Serving(runtime: lustre.Runtime(Page))
}

/// Upgrades one checked page request to the component's socket.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.upgrade(root, request, attachment, attachment.instance.gateway)
/// ```
pub fn upgrade(
  daemon: root.Root(instance),
  request: Request(mist.Connection),
  attachment: server.Attachment(instance),
  hub: gateway.Gateway,
) -> Response(mist.ResponseData) {
  let limit = root.message_limit(root.Observer)
  let attach =
    ui_relay.Attach(
      hub:,
      binding: gateway.Binding(
        session_id: attachment.session_id,
        epoch: attachment.epoch,
        incarnation: attachment.incarnation,
        connection_id: attachment.connection_id,
        principal: attachment.principal,
        authority: attachment.authority,
        digest: attachment.digest,
      ),
      check: fn() { authorize(attachment) },
      failed_reader: fn() {
        let _ =
          manager.stop_if_incarnation(
            attachment.registry,
            attachment.session_id,
            attachment.incarnation,
          )
        Nil
      },
    )
  let expected =
    snapshot.Expected(
      attachment.session_id,
      attachment.epoch,
      attachment.incarnation,
    )

  // The barrier that orders the permit's custody transfer against the
  // HTTP process's release, exactly as in `session_socket`.
  let settled = process.new_subject()
  let response =
    mist.websocket_with_options(
      request:,
      options: mist.WebsocketOptions(limit, limit, mist.CompressionDisabled),
      on_init: fn(_) {
        let signals = process.new_subject()

        // Mist arms the socket only after this initializer returns, so
        // `Admit` is the first message the handler sees.
        process.send(signals, Admit)
        #(
          Pending(signals),
          Some(process.new_selector() |> process.select(signals)),
        )
      },
      handler: fn(phase, event, socket) {
        case phase, event {
          Pending(signals), mist.Custom(Admit) ->
            admit(daemon, attachment, attach, expected, signals, settled)

          // Nothing can reach a pending socket before its own `Admit`; the
          // arms are spelled out so a change to that order fails closed.
          Pending(_), mist.Text(_)
          | Pending(_), mist.Binary(_)
          | Pending(_), mist.Closed
          | Pending(_), mist.Shutdown
          | Pending(_), mist.Custom(Client(_))
          | Pending(_), mist.Custom(Ended(_))
          -> mist.stop()

          // The browser's client runtime speaks Lustre's protocol. A frame
          // that does not decode is dropped, as Lustre's own servers do; the
          // component has no handler a decoded event could reach anyway.
          Serving(runtime), mist.Text(text) -> {
            case json.parse(text, server_component.runtime_message_decoder()) {
              Ok(message) -> lustre.send(runtime, message)
              Error(_) -> Nil
            }
            mist.continue(Serving(runtime))
          }

          Serving(runtime), mist.Custom(Client(message)) ->
            case
              mist.send_text_frame(
                socket,
                json.to_string(server_component.client_message_to_json(message)),
              )
            {
              Ok(Nil) -> mist.continue(Serving(runtime))
              Error(_) -> mist.stop()
            }

          Serving(_), mist.Custom(Ended(_))
          | Serving(_), mist.Binary(_)
          | Serving(_), mist.Closed
          | Serving(_), mist.Shutdown
          | Serving(_), mist.Custom(Admit)
          -> mist.stop()
        }
      },
      on_close: fn(phase) {
        case phase {
          Serving(runtime) -> lustre.send(runtime, lustre.shutdown())
          Pending(_) -> Nil
        }
      },
    )
  case response.body {
    mist.Websocket -> {
      let _ = process.receive(settled, within: 5000)
      Nil
    }
    mist.Bytes(_) | mist.Chunked | mist.File(..) | mist.ServerSentEvents -> Nil
  }
  response
}

// Takes the permit in the socket's first handler turn, then starts the
// component with a transport whose `connect` starts the relay. `connect`
// runs in the component's process, so the relay monitors the component and
// the inbox it delivers to belongs to the component.
fn admit(
  daemon: root.Root(instance),
  attachment: server.Attachment(instance),
  attach: ui_relay.Attach,
  expected: snapshot.Expected,
  signals: process.Subject(Signal),
  settled: process.Subject(Nil),
) -> mist.Next(Phase, Signal) {
  let transferred = root.transfer(daemon, attachment.permit, within: 1000)
  process.send(settled, Nil)
  let started = {
    use Nil <- result.try(
      transferred |> result.replace_error("the page's permit was refused"),
    )
    let transport =
      component.Transport(
        connect: fn(inbox) {
          ui_relay.start(attach, inbox, fn(reason) {
            process.send(signals, Ended(reason))
          })
        },
        transmit: ui_relay.transmit,
        shut: ui_relay.shut,
        now: bootstrap.monotonic_time_ms,
      )
    lustre.start_server_component(
      component.app(),
      component.Start(attachment.session_id, expected, transport),
    )
    |> result.replace_error("the page's component did not start")
  }
  case started {
    Error(_) -> mist.stop()
    Ok(runtime) -> {
      // The component's messages for the browser arrive on a subject this
      // socket owns, and are written from this process's own turns.
      let client = process.new_subject()
      lustre.send(runtime, server_component.register_subject(client))
      mist.continue(Serving(runtime))
      |> mist.with_selector(
        process.new_selector()
        |> process.select(signals)
        |> process.select_map(client, Client),
      )
    }
  }
}

// The same check a terminal socket makes, with the digest of the credential
// that minted the page's ticket, so revoking that credential or the
// membership stops the page's pushes and closes it.
fn authorize(attachment: server.Attachment(instance)) {
  manager.frame_authority(
    attachment.registry,
    epoch: attachment.epoch,
    id: attachment.session_id,
    incarnation: attachment.incarnation,
    digest: attachment.digest,
  )
  |> result.replace_error("unauthorized")
}
