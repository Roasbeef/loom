//// A websocket actor for the terminal client.
////
//// The actor owns the socket. The terminal process owns an inbox and drains
//// it on etui ticks, so network traffic never blocks keyboard polling and
//// the view remains a pure function of the current model.

import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/result
import gleam/string
import stratus

type Outbound {
  SendText(String)
  Stop
}

/// A connected websocket actor.
pub opaque type Connection {
  Connection(Subject(stratus.InternalMessage(Outbound)))
}

/// One connection lifecycle message for the terminal process.
pub type Message {
  Connected
  Incoming(String)
  Closed(String)
  NetworkFault(String)
}

/// Creates the inbox the terminal process will own.
pub fn new_inbox() -> Subject(Message) {
  process.new_subject()
}

/// Opens a websocket and starts its socket-owning actor.
pub fn connect(
  address: String,
  token: String,
  inbox: Subject(Message),
) -> Result(Connection, String) {
  use websocket_request <- result.try(
    request.to(http_address(address))
    |> result.replace_error("the websocket address is invalid"),
  )
  let websocket_request = case token {
    "" -> websocket_request
    value ->
      request.set_header(websocket_request, "authorization", "Bearer " <> value)
  }
  let builder =
    stratus.new(websocket_request, inbox)
    |> stratus.on_message(fn(inbox, message, socket) {
      case message {
        stratus.Text(text) -> {
          process.send(inbox, Incoming(text))
          stratus.continue(inbox)
        }
        stratus.Binary(_) -> {
          process.send(inbox, NetworkFault("the gateway sent a binary frame"))
          stratus.continue(inbox)
        }
        stratus.User(SendText(text)) -> {
          let _ = case stratus.send_text_message(socket, text) {
            Ok(Nil) -> Nil
            Error(reason) ->
              process.send(inbox, NetworkFault(string.inspect(reason)))
          }
          stratus.continue(inbox)
        }
        stratus.User(Stop) -> {
          let _ = stratus.close(socket, stratus.GoingAway(<<>>))
          stratus.stop()
        }
      }
    })
    |> stratus.on_close(fn(inbox, reason) {
      process.send(inbox, Closed(string.inspect(reason)))
    })
  use started <- result.try(
    stratus.start(builder)
    |> result.map_error(fn(error) { string.inspect(error) }),
  )
  process.send(inbox, Connected)
  Ok(Connection(started.data))
}

/// Sends one text frame without blocking the terminal process on socket I/O.
pub fn send(connection: Connection, text: String) -> Nil {
  let Connection(subject) = connection
  process.send(subject, stratus.to_user_message(SendText(text)))
}

/// Requests a graceful websocket close.
pub fn close(connection: Connection) -> Nil {
  let Connection(subject) = connection
  process.send(subject, stratus.to_user_message(Stop))
}

/// Receives one queued connection message, if one is ready.
pub fn receive(inbox: Subject(Message)) -> Result(Message, Nil) {
  process.receive(inbox, 0)
}

fn http_address(address: String) -> String {
  case address {
    "ws://" <> rest -> "http://" <> rest
    "wss://" <> rest -> "https://" <> rest
    other -> other
  }
}
