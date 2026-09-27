//// A session socket wakes the terminal's loop after every frame it files.
////
//// The terminal sleeps in etui's input wait between ticks, and a frame in
//// its inbox does not end that wait; the socket actor sends etui's
//// `{etui_wake}` to the inbox's owner after it files the frame
//// (`connection.connect_waking`). Two properties matter, and both are only
//// observable on a real socket: the wake arrives, and it arrives after the
//// frames it announces, never ahead of them. This test plays the loop: it
//// owns the inbox and reads its mailbox in order, frames and wakes through
//// one selector, against a real gateway.
////
//// The first live drive found the wake missing entirely: the pacing opened
//// at reading zero, and the BEAM's monotonic clock is negative, so the
//// first wake was scheduled days out and every frame after it was covered.

import client/session_socket_test
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/list
import session_view/connection_event
import session_view/protocol
import tui/connection
import tui/daemon
import tui/daemon/selection

/// What the loop's mailbox delivers, in order.
type Delivered {
  Frame(connection_event.Message)
  Wake
}

// Everything that reaches the loop's mailbox until a wake follows at least
// one frame, oldest first, or an error when nothing more arrives in time.
fn until_wake(
  selector: process.Selector(Delivered),
  seen: List(Delivered),
) -> Result(List(Delivered), List(Delivered)) {
  case process.selector_receive(selector, 5000) {
    Error(Nil) -> Error(list.reverse(seen))
    Ok(Wake) -> Ok(list.reverse([Wake, ..seen]))
    Ok(frame) -> until_wake(selector, [frame, ..seen])
  }
}

pub fn a_session_socket_wakes_its_loop_after_the_frames_test() {
  session_socket_test.fixture(fn(port, token, session, _, _) {
    let address = "ws://127.0.0.1:" <> int.to_string(port) <> "/v2/control"
    let assert Ok(control) =
      daemon.connect(address, token, process.self(), 2000)
      as "the test owns an authenticated control connection"
    let assert Ok(host) = selection.host(control, address, token)
    let assert Ok(target) = selection.open(host, session)
    let inbox = connection.new_inbox()
    let assert Ok(socket) =
      connection.connect_waking(target.address, token, inbox)
      as "the session socket opens with waking on"
    let selector =
      process.new_selector()
      |> process.select_map(inbox, Frame)
      |> process.select_record(atom.create("etui_wake"), 0, fn(_) { Wake })

    // The socket files `Connected` from its initialiser and wakes at once.
    let assert Ok([Frame(connection_event.Connected), Wake]) =
      until_wake(selector, [])
      as "the first frame is followed by a wake, and nothing precedes it"

    // A subscribe's replies arrive and are announced after they are filed,
    // whether the wake went at once or at the end of its interval.
    connection.send(socket, protocol.subscribe(1, session))
    let assert Ok(delivered) = until_wake(selector, [])
      as "the replies to a request are followed by a wake"
    let assert [Frame(connection_event.Incoming(_)), ..] = delivered
      as "a reply reaches the inbox before the wake that announces it"
    connection.close(socket)
    daemon.close(control)
  })
}
