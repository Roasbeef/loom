//// The v2 resident-session transport, with no anonymous or v1 upgrade path.
//// HTTP authentication has already resolved the immutable attachment. The
//// actual WebSocket process takes the root's parser permit before initialization
//// returns, then monitors the original gateway rather than its restartable name.
//// Each received frame waits for one bounded gateway reply before the parser
//// accepts another. Snapshot continuation uses the gateway's bounded reader.

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
  Refused
  GatewayDown(process.Down)
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
  mist.websocket_with_options(
    request:,
    options: mist.WebsocketOptions(limit, limit, mist.CompressionDisabled),
    on_init: fn(_) {
      let outbound = process.new_subject()
      let admitted = {
        use Nil <- result.try(root.transfer(
          daemon,
          attachment.permit,
          within: 1000,
        ))
        gateway.attach_authenticated(
          hub,
          gateway.Binding(
            attachment.session_id,
            attachment.epoch,
            attachment.incarnation,
            attachment.connection_id,
            attachment.principal,
            attachment.authority,
            attachment.digest,
          ),
          fn() { authorize(daemon, attachment) },
          fn(_) { Nil },
          fn() { process.send(outbound, Refused) },
          fn() { failed_reader(daemon, attachment) },
          process.self(),
        )
      }
      case admitted {
        Error(_) -> {
          // Returning a state would activate an unadmitted parser. Self-KILL
          // is immediate; the root retains its charge until the original DOWN.
          process.kill(process.self())
          #(admitted, Some(process.new_selector() |> process.select(outbound)))
        }
        Ok(connection) -> {
          let watch = process.monitor(gateway.connection_pid(connection))
          #(
            admitted,
            Some(
              process.new_selector()
              |> process.select(outbound)
              |> process.select_specific_monitor(watch, GatewayDown),
            ),
          )
        }
      }
    },
    handler: fn(admitted, event, socket) {
      case admitted, event {
        Error(_), _ -> mist.stop()
        Ok(connection), mist.Text(frame) ->
          respond(daemon, attachment, connection, frame, socket)
        Ok(_), mist.Binary(_)
        | Ok(_), mist.Closed
        | Ok(_), mist.Shutdown
        | Ok(_), mist.Custom(Refused)
        | Ok(_), mist.Custom(GatewayDown(_))
        -> mist.stop()
      }
    },
    on_close: fn(admitted) {
      case admitted {
        Ok(connection) -> gateway.connection_detach(connection)
        Error(_) -> Nil
      }
    },
  )
}

// The synchronous exchange admits one request at a time. A missing response is
// an unknown outcome, so closing the socket must not retry the command.
fn respond(
  daemon,
  attachment: server.Attachment(instance),
  connection,
  frame,
  socket,
) {
  let sent = {
    use response <- result.try(gateway.connection_request(connection, frame))
    use #(_, authority) <- result.try(authorize(daemon, attachment))
    use Nil <- result.try(case authority == attachment.authority {
      True -> Ok(Nil)
      False -> Error("attachment role changed")
    })
    mist.send_text_frame(socket, response)
    |> result.replace_error("socket delivery failed")
  }
  case sent {
    Ok(Nil) -> mist.continue(Ok(connection))
    Error(_) -> mist.stop()
  }
}

// This returns after stop admission, not after retiring this requesting socket
// or gateway. The registry compares the original incarnation atomically.
fn failed_reader(daemon, attachment: server.Attachment(instance)) -> Nil {
  let _ = {
    use ready <- result.try(root.ready(daemon, within: 1000))
    manager.stop_if_incarnation(
      ready.registry,
      attachment.session_id,
      attachment.incarnation,
    )
    |> result.replace_error("session stop refused")
  }
  Nil
}

fn authorize(daemon, attachment: server.Attachment(instance)) {
  use ready <- result.try(root.ready(daemon, within: 1000))
  use Nil <- result.try(case ready.epoch == attachment.epoch {
    True -> Ok(Nil)
    False -> Error("stale epoch")
  })
  use _ <- result.try(
    manager.resolve_incarnation(
      ready.registry,
      attachment.session_id,
      attachment.incarnation,
    )
    |> result.replace_error("stale incarnation"),
  )
  manager.session_authority(
    ready.registry,
    attachment.digest,
    attachment.session_id,
  )
  |> result.replace_error("unauthorized")
}
