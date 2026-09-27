//// The page's WebSocket: Lustre's transport between one browser and one
//// server component, which drives the session's lane through a relay
//// (protocol-change/051).
////
//// `client/daemon/server` has already checked the request's host, origin,
//// cookie, page key and nonce, re-authenticated the credential that minted
//// the page's ticket, resolved the resident session with the page's capped
//// role, and reserved the parser permit for that role. This module does what
//// `session_socket` does for a terminal with the rest: it takes the permit's
//// custody in the socket's first handler turn, and then, instead of serving
//// v2 frames, it starts the component and carries Lustre's messages in both
//// directions.
////
//// Which component it starts is decided by the admitted role: an
//// observer's page is `web_view/component`, whose messages hold no command,
//// and an operator's is `web_view/operator_page` (protocol-change/051, the
//// operator addendum). The role also bounds what the browser may send. An
//// observer's page attaches no handler, so every browser message is dropped
//// here before it costs the component a render. An operator's page takes
//// only the events it attaches, a click and a submit; anything else is
//// dropped here too.
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
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import host/bootstrap
import lustre
import lustre/server_component
import mist
import session_view/snapshot
import storage/access
import web_view/component
import web_view/operator_page

/// The inbound frame limit on an operator's page socket: a text prompt fits,
/// a pasted image does not, and a browser's events are far smaller than the
/// terminal's 32 MiB (protocol-change/051, the operator addendum).
pub const operator_frame_limit = 1_048_576

// How long a page's socket stays open after the relay reports the page
// ended, in milliseconds. The component reduces the close as it arrives,
// so its last patch is one message behind; a quarter second covers a
// component busy with a batch when the close lands.
const ended_grace_ms = 250

type Signal {
  // The self-addressed message that runs admission, queued by `on_init`.
  Admit

  // One message from the component for the browser's client runtime,
  // already encoded, so the socket's state names no component's type.
  Client(frame: json.Json)

  // The relay ended from the gateway's side; the page closes shortly.
  Ended(reason: String)

  // The delayed close after `Ended`, once the component has drawn its end.
  Stop
}

// A serving page is the two things the socket does with its component:
// hand it a browser frame (or drop it), and shut it down.
type Phase {
  Pending(signals: process.Subject(Signal))
  Serving(
    forward: fn(String) -> Nil,
    shutdown: fn() -> Nil,
    signals: process.Subject(Signal),
  )
}

/// The browser messages an observer's page takes: none. Its view attaches
/// no handler, so nothing a browser sends could reach its `update`, and a
/// message dropped here costs the component no render.
///
/// ## Examples
///
/// ```gleam
/// assert !ui_socket.observer_accepts("{\"kind\":1,\"name\":\"click\"}")
/// ```
pub fn observer_accepts(_frame: String) -> Bool {
  False
}

/// The browser messages an operator's page takes: Lustre's `EventFired` for
/// the events its view attaches, a `click` and a `submit`, alone or batched.
/// Every other message is dropped before it reaches the component.
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.operator_accepts("{\"kind\":1,\"name\":\"click\"}")
/// ```
pub fn operator_accepts(frame: String) -> Bool {
  case json.parse(frame, accepted()) {
    Ok(accepted) -> accepted
    Error(_) -> False
  }
}

fn accepted() -> decode.Decoder(Bool) {
  use kind <- decode.field("kind", decode.int)
  case kind {
    1 -> {
      use name <- decode.field("name", decode.string)
      decode.success(name == "click" || name == "submit")
    }
    3 -> {
      use messages <- decode.field(
        "messages",
        decode.list(decode.recursive(accepted)),
      )
      decode.success(messages != [] && list.all(messages, fn(ok) { ok }))
    }
    _ -> decode.success(False)
  }
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
  open: fn() -> Result(Nil, Nil),
  ceiling: access.Role,
) -> Response(mist.ResponseData) {
  let role = role_of(attachment.authority)
  let limit = case role {
    Observing -> root.message_limit(root.Observer)
    Operating -> operator_frame_limit
  }
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
      check: ui_relay.while_open(fn() { authorize(attachment) }, open),
      ceiling:,
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
          | Pending(_), mist.Custom(Stop)
          -> mist.stop()

          // The browser's client runtime speaks Lustre's protocol. What the
          // page's role lets through is decided by `forward`.
          Serving(forward, _, _) as serving, mist.Text(text) -> {
            forward(text)
            mist.continue(serving)
          }

          Serving(..) as serving, mist.Custom(Client(frame)) ->
            case mist.send_text_frame(socket, json.to_string(frame)) {
              Ok(Nil) -> mist.continue(serving)
              Error(_) -> mist.stop()
            }

          // The gateway ended the page. The relay has already told the
          // component, which reduces the close as it arrives and sends the
          // patch that draws the ended state; closing now could drop that
          // patch, which reaches this socket through the component rather
          // than from the relay. `ended_grace_ms` covers the component's
          // one message and its broadcast.
          Serving(signals:, ..) as serving, mist.Custom(Ended(_)) -> {
            process.send_after(signals, ended_grace_ms, Stop)
            mist.continue(serving)
          }

          Serving(..), mist.Custom(Stop)
          | Serving(..), mist.Binary(_)
          | Serving(..), mist.Closed
          | Serving(..), mist.Shutdown
          | Serving(..), mist.Custom(Admit)
          -> mist.stop()
        }
      },
      on_close: fn(phase) {
        case phase {
          Serving(shutdown:, ..) -> shutdown()
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

// Whether the admitted page is an observer's or an operator's.
type Role {
  Observing
  Operating
}

// The role the admitted authority gives the page. The router has already
// capped it, so `Owner` does not reach here from a page; it is read as an
// operator's for totality.
fn role_of(authority: access.Authority) -> Role {
  case authority {
    access.Participant(access.Observer) -> Observing
    access.Owner | access.Participant(access.Operator) -> Operating
  }
}

// Takes the permit in the socket's first handler turn, then starts the
// component the page's role calls for, with a transport whose `connect`
// starts the relay and returns at once. `connect` runs in the component's
// process, so the relay monitors the component and the subjects it answers
// on belong to the component; the gateway's attach runs in the relay, after
// the component's start has returned.
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
  let transport =
    component.Transport(
      connect: fn(inbox, opened) {
        ui_relay.start(attach, inbox, process.self(), opened, fn(reason) {
          process.send(signals, Ended(reason))
        })
      },
      transmit: ui_relay.transmit,
      shut: ui_relay.shut,
      now: bootstrap.monotonic_time_ms,
    )
  let start =
    component.Start(
      session_id: attachment.session_id,
      label: label(attachment),
      expected:,
      transport:,
    )
  let started = case transferred {
    Error(_) -> Error(Nil)
    Ok(Nil) -> start_page(attachment.authority, start)
  }
  case started {
    Error(Nil) -> mist.stop()
    Ok(Page(forward:, shutdown:, frames:)) ->
      mist.continue(Serving(forward, shutdown, signals))
      |> mist.with_selector(
        process.new_selector()
        |> process.select(signals)
        |> process.merge_selector(process.map_selector(frames, Client)),
      )
  }
}

// The session's name and workspace from the daemon's catalogue, for the
// page's heading. The lookup reads the registration without waking a saved
// runtime. A page whose lookup fails still opens, with a heading that names
// the session by its identity, because the heading is the only thing the
// label is for.
fn label(attachment: server.Attachment(instance)) -> Option(component.Label) {
  case manager.get(attachment.registry, attachment.session_id) {
    Ok(view) ->
      Some(component.Label(
        name: view.registration.name,
        workspace: view.registration.workspace,
      ))
    Error(_) -> None
  }
}

/// A started page, as its socket holds it: how a browser frame reaches the
/// component, how to shut the component down, and a selector over what the
/// component sends the browser, each message already encoded.
pub type Page {
  Page(
    /// Hands one browser frame to the component, or drops it.
    forward: fn(String) -> Nil,
    /// Shuts the component down.
    shutdown: fn() -> Nil,
    /// The component's messages for the browser, as JSON.
    frames: process.Selector(json.Json),
  )
}

/// Starts the component an attachment with `authority` gets: an observer's
/// page, which takes no browser message, or an operator's, which takes only
/// the events its view attaches. Called from the socket's own process, which
/// then owns the subject the component's messages arrive on.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.start_page(access.Participant(access.Observer), start)
/// ```
@internal
pub fn start_page(
  authority: access.Authority,
  start: component.Start(ui_relay.Relay),
) -> Result(Page, Nil) {
  case role_of(authority) {
    Observing -> serve(component.app(), start, observer_accepts)
    Operating -> serve(operator_page.app(), start, operator_accepts)
  }
}

// Starts one component and returns what the socket needs of it: how a
// browser frame reaches it, how to shut it down, and a selector over the
// subject its client messages arrive on, encoding each as it is received.
// `admits` says which browser frames reach it.
fn serve(
  app: lustre.App(component.Start(ui_relay.Relay), model, message),
  start: component.Start(ui_relay.Relay),
  admits: fn(String) -> Bool,
) -> Result(Page, Nil) {
  case lustre.start_server_component(app, start) {
    Error(_) -> Error(Nil)
    Ok(runtime) -> {
      // The component's messages for the browser arrive on a subject this
      // socket owns, and are written from this process's own turns.
      let client = process.new_subject()
      lustre.send(runtime, server_component.register_subject(client))
      let encoded =
        process.new_selector()
        |> process.select_map(client, server_component.client_message_to_json)
      let forward = fn(text) {
        case admits(text) {
          False -> Nil
          True ->
            case json.parse(text, server_component.runtime_message_decoder()) {
              Ok(message) -> lustre.send(runtime, message)
              Error(_) -> Nil
            }
        }
      }
      Ok(Page(
        forward:,
        shutdown: fn() { lustre.send(runtime, lustre.shutdown()) },
        frames: encoded,
      ))
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
