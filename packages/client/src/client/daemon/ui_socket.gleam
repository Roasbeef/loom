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
//// The socket also makes the one way the page's images are read. A request
//// for an image (`GET .../image/<row>/<position>`) arrives on an HTTP handler
//// that knows the page's cookie and nothing of the component, whose lane holds
//// the images the page drew. When the component starts, the socket registers,
//// under the page's cookie, a function that asks it (`ui_sessions.Images`),
//// and the handler reads that function back after its own checks
//// (protocol-change/051, the addendum on images). The question is a Lustre
//// message sent from the daemon's side with `lustre.dispatch`, which a browser
//// frame cannot produce, so an observer's socket, which forwards almost
//// nothing, still answers it.
////
//// A third role is an operator's page whose principal is the daemon's owner
//// (`Owning`). A page never carries owner authority, but its principal may be
//// the owner, and only that page draws the invitation control and is handed
//// the capability to use it (`invite_for`; the addendum on inviting from the
//// session page). The socket admits a click beneath `component.invite_path`
//// only for it, so a member operator's browser cannot press the control even
//// by forging the path.
////
//// An owner's page also draws a rename control for the page's own session
//// (protocol-change/067). It is admitted the way the invitation control is: the
//// socket takes a submit beneath `component.rename_path` only for an owner's
//// page, and `rename_for` is the daemon's own check, made afresh in a task of
//// its own (`rename_task`) so the page's runtime never waits on the registry.
//// The page sends the typed name and nothing else, and no frame can name a
//// session, because the session is the attachment's.
////
//// One component per connection. It is started from this socket's process
//// and linked to it, and the socket shuts it down when the browser goes
//// away, which is what ends its relay (the relay monitors the component).
//// When the relay ends from the gateway's side (the session stopped, or the
//// attachment was revoked) it tells this socket, which closes, so a revoked
//// page does not stay open showing a transcript it may no longer read.
////
//// The close code is the message to Lustre's client runtime, which
//// reconnects after any code but 1000 and treats 1000 as final. A page that
//// ended for a reason the person resolves (a newer link replaced it, access
//// was revoked, the session stopped) closes with 1000 after the component
//// has drawn why, so the notice stays and no reconnect is refused every ten
//// seconds. A failure the daemon may clear by itself (the session was still
//// opening, the permit transfer or the component's start ran over its
//// budget) closes with 4000, which the runtime retries. `web_view/ending`
//// decides which is which, one closed type for both the words and the code
//// (protocol-change/051, the addendum on an ended page).
////
//// The home page (protocol-change/065) is the other page this socket serves.
//// It is bound to no session, so `upgrade_home` starts `web_view/home`
//// with no relay, over the same `websocket`, and its reads of the principal's
//// sessions (`home_listing`) are also what end it: a page whose UI session
//// ended or whose credential was revoked is told so by its next read.
////
//// A page and the home lead to each other by tickets (the second pull
//// request). A running session's row on the home asks `ticket_for` for a page
//// of that session, and a session page opened from a home asks
//// `home_ticket_for` for the way back. Both mint with the asking page's own
//// `Standing`: its credential, principal, ceiling and reach, so the page they
//// open can do no more than the page that asked, and both carry the asking
//// page's deadline, so a chain home, session, home never outlives the page it
//// began from. A page a link for one session opened has `OneSession` reach and
//// is handed no capability to go home.
////
//// A saved session is opened by the same two pages, and only when the page was
//// minted to operate (protocol-change/065, the third pull request).
//// `resume_for` is the control command's `OpenSession` run on the page's behalf
//// with the page's credential digest: the authority check, the registry's own
//// open, a bounded wait for the session to become resident, and then the
//// ticket `ticket_for` mints. The wait is long, so `resume_task` runs it in a
//// weft run of its own and the page's runtime, which called it, returns at
//// once; the run's last act is to hand its answer back as the message the
//// component is waiting for.
////
//// An owner's home page also draws a "New session" control under each workspace
//// (protocol-change/065, the fourth pull request). It is admitted as the
//// invitation control is: the socket takes a `submit` beneath `home.table_path`
//// only for a home whose principal is the owner and which was minted to operate
//// (`home_owner_accepts`, which the rename form shares), and `create_for` is the
//// daemon's own check, made
//// afresh in a task of its own (`create_task`). The page sends a workspace its
//// own list drew, a name and a sharing choice, and nothing else, and the
//// daemon creates only in a workspace the owner already holds a session in.
////
//// A home page also manages the browser logins of its own principal
//// (protocol-change/065, PR 8). `signins_read` lists them, `sign_out_for` and
//// `sign_out_all_for` end one or all, and `device_link_for` makes a link that
//// signs in another device. Each is the daemon's own check, made afresh from the
//// grant the daemon holds and never from the page: the page is still open, the
//// credential still authenticates as the principal, and for the link the page is
//// a fresh home (`Origin`) and the credential's grant allowance has a place. A
//// home the bookmark resumed is handed no device capability, and the daemon
//// refuses the request from one as well.
//// The owner's home also draws an "Admin" button (protocol-change/065, the fifth
//// pull request), and the admin page it opens is the third page this socket
//// serves. The button is admitted as the creation control is, and only a little
//// narrower: the socket takes a click at `home.admin_path` only for a home whose
//// principal is the owner, minted to operate and opened by a fresh `loom ui`
//// exchange (`home_admin_capability`, `home_admin_accepts`), and
//// `admin_ticket_for` is the daemon's own check, made afresh in a task of its own
//// (`admin_ticket_task`). `upgrade_admin` starts `web_view/admin` over the same
//// `websocket`. The page's reads of the catalogue (`admin_reading`) are also what
//// end it, and each of its five changes (`admin_for`) is made afresh in a task of
//// its own (`admin_task`): the page open, its ceiling, the credential
//// authenticating as the owner, the epoch, and, for a grant, the one allowance
//// the session page's invitation control is held to.
////
//// ## Flow
////
//// `upgrade` → `websocket` → `admit` → `start_page` → `serve` → `closing`
////
//// 1. `upgrade` reads the page's `role_of` its attachment, builds the relay
////    `Attach` and the invitation capability, and opens `websocket`.
////    `upgrade_home` opens the same `websocket` for a home, whose `admit_home`
////    starts its component through `launch` in place of `start_page`, and
////    `upgrade_admin` does the same for the admin page through `admit_admin`.
//// 2. The socket's first turn handles `Admit`, which calls `admit`: it takes
////    the permit's custody with `root.transfer`, then builds the component's
////    transport from `listed_for`, `opened_for` and `ticket_for`.
//// 3. `start_page` picks the component the role calls for and `serve` starts
////    it, returning the `Page` the socket holds for its life: forward a
////    browser frame (after `observer_accepts`, `operator_accepts` or
////    `owner_accepts`), shut down, read an image.
//// 4. Afterwards the handler forwards browser frames, writes the component's
////    frames to the browser, and on the relay's `Ended` schedules `Stop`.
//// 5. `closing` turns an ending's close code into mist's clean stop (1000) or
////    its abnormal one (4000, which the client runtime retries).
////
//// ## Transitions
////
//// <!-- transitions: ui_socket.Phase -->
////
//// | state | Admit | browser text | component frame | Ended | Stop | binary, closed, shutdown |
//// | --- | --- | --- | --- | --- | --- | --- |
//// | `Pending` | `Serving` once the permit transfers and the component starts; otherwise `closing` with a retry close | socket stops | socket stops | socket stops | socket stops | socket stops |
//// | `Serving` | socket stops | forwarded to the component, filtered by role; stays `Serving` | written to the browser, stays `Serving`; socket stops if the write fails | stays `Serving`; schedules `Stop` after the grace period | `closing`: clean stop or retry close | socket stops |
////
//// Leaving `Serving` for any reason runs the component's shutdown from
//// `on_close`.

import broker/token
import client/daemon/manager
import client/daemon/root
import client/daemon/server
import client/daemon/ui_http
import client/daemon/ui_login
import client/daemon/ui_project
import client/daemon/ui_relay
import client/daemon/ui_sessions
import client/daemon/upgrade_log
import client/gateway
import core/ids
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap
import host/claim
import lustre
import lustre/server_component
import mist
import session_view/snapshot
import session_view/transcript_image
import storage/access
import storage/catalogue
import storage/domain
import telemetry/field
import telemetry/level
import telemetry/log
import telemetry/owner
import web_view/actions
import web_view/admin
import web_view/component
import web_view/creations
import web_view/ending
import web_view/grants
import web_view/home
import web_view/invites
import web_view/names
import web_view/operator_page
import web_view/page
import web_view/renames
import web_view/sessions
import web_view/signins
import weft
import weft/poll

/// The inbound frame limit on an operator's page socket: 12 MiB, which holds
/// a text prompt and up to `web_view/image.max_attached_bytes` of images (8 MiB
/// before base64, a third more after) in one submit event, and is well under
/// the terminal's 32 MiB. It was 1 MiB while the page sent text alone
/// (protocol-change/051, the operator addendum); the addendum on images raised
/// it and says why. An observer's page keeps the 64 KiB an observer's
/// connection class has. The permit an operator's page holds is charged
/// `root.operator_peak` (64 MiB, the `PageOperator` class), which covers the transient peak of one such
/// submit: the frame, the event string, the parsed images, their decoded bytes
/// and the re-encoding, five copies of at most 12 MiB.
pub const operator_frame_limit = 12_582_912

/// How long a page's request to resume a saved session waits for the session to
/// become resident, in milliseconds. A session that is not resident by then is
/// refused in the fixed words and no ticket is minted, though the registry may
/// still finish the open and the session then shows as running on the next
/// read. Thirty seconds is a terminal's patience for the same open, and the
/// bound is on the wait and not on the open, which the registry owns.
pub const resume_wait_ms = 30_000

// How long a request for an image waits for the component's answer, in
// milliseconds. The component answers from a lane it holds in memory, so a
// second is long; a component that does not answer in that time is gone or
// stuck, and the request is refused rather than held.
const image_wait_ms = 2000

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
  Ended(reason: ending.Ending)

  // The delayed close after `Ended`, once the component has drawn its end,
  // with the close code that ending calls for.
  Stop(close: ending.Close)
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

/// The browser messages an observer's page takes: exactly one kind,
/// Lustre's `EventFired` for a `click`, and only at three places. One is
/// `component.older_path`, the lane's "Load older" button, whose message asks
/// for a read of older history and nothing else (protocol-change/051, the
/// addendum on history paging). The other is any path beneath
/// `component.strip_path`, the agent strip's chip list, where each handler is
/// a chip's button and its message moves the page's focus to that chip's
/// strand, which is a change of what the page reads and sends no command (the
/// addendum on strand focus). The strand is named by the message the server
/// drew and not by the frame, so the frame chooses among the chips and cannot
/// name a strand. The third is `component.home_path`, the "Home" button of a
/// page opened from a home, whose message carries nothing and whose answer is
/// a ticket the daemon mints for the page's own principal and ceiling
/// (`home_ticket_for`; protocol-change/065, the second pull request). Every
/// other message is dropped here, a batch included, so
/// it costs the component no render; the gateway refuses any mutation from an
/// observer's binding on its own, whatever reaches it. A click beneath
/// `component.sidebar_path`, where an operator's page has its session
/// buttons, is dropped: an observer's page has no sidebar, and switching
/// sessions is an operator's (the addendum on switching sessions).
///
/// ## Examples
///
/// ```gleam
/// assert !ui_socket.observer_accepts("{\"kind\":1,\"name\":\"submit\"}")
/// ```
pub fn observer_accepts(frame: String) -> Bool {
  case json.parse(frame, observer_click()) {
    Ok(accepted) -> accepted
    Error(_) -> False
  }
}

fn observer_click() -> decode.Decoder(Bool) {
  use kind <- decode.field("kind", decode.int)
  use name <- decode.field("name", decode.string)
  use path <- decode.field("path", decode.string)
  decode.success(kind == 1 && name == "click" && observer_path(path))
}

// The three places an observer's click may fire: the older button, the Home
// button, and a chip beneath the strip's list. The list's own path is not a
// chip, so the prefix includes the separator.
fn observer_path(path: String) -> Bool {
  path == component.older_path
  || path == component.home_path
  || string.starts_with(path, component.strip_path <> "\t")
}

/// The browser messages a member operator's page takes: Lustre's `EventFired`
/// for the events its view attaches, a `click` and a `submit`, alone or
/// batched. Every other message is dropped before it reaches the component. A
/// click is admitted at any path but one, so the session buttons beneath
/// `component.sidebar_path` and a peer message's Open button need no entry of
/// their own; Lustre dispatches the event only to a handler the page drew at
/// that path, and the daemon checks the session again before it mints a ticket
/// (`ticket_for`). The two places it drops are `component.invite_path` and
/// `component.rename_path` and anything beneath either, the invitation control
/// and the rename control, which are an owner's and which this page does not
/// draw (`owner_accepts`; the addendum on inviting from the session page, and
/// protocol-change/067). A message in a batch that reaches one of them drops the
/// whole batch.
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.operator_accepts("{\"kind\":1,\"name\":\"click\"}")
/// ```
pub fn operator_accepts(frame: String) -> Bool {
  accepts(frame, ExceptOwner)
}

/// The browser messages an owner's page takes: what `operator_accepts` takes,
/// and an event at or beneath `component.invite_path` and
/// `component.rename_path` as well. It is the one socket that admits the
/// invitation control's buttons and the rename form's submit, and it is started
/// only for a page whose principal is the daemon's owner.
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.owner_accepts("{\"kind\":1,\"name\":\"submit\"}")
/// ```
pub fn owner_accepts(frame: String) -> Bool {
  accepts(frame, Everywhere)
}

// Where an operator-class socket admits an event.
type Reach {
  // At any path: an owner's page.
  Everywhere

  // At any path but the two owner controls': a member operator's page.
  ExceptOwner
}

fn accepts(frame: String, reach: Reach) -> Bool {
  case json.parse(frame, accepted(reach)) {
    Ok(accepted) -> accepted
    Error(_) -> False
  }
}

// An event names its path when the browser sent one. A frame with none
// cannot name a handler and is judged as a click at no path, which the
// runtime drops if nothing is drawn there.
fn accepted(reach: Reach) -> decode.Decoder(Bool) {
  use kind <- decode.field("kind", decode.int)
  case kind {
    1 -> {
      use name <- decode.field("name", decode.string)
      use path <- decode.optional_field("path", "", decode.string)
      decode.success(
        { name == "click" || name == "submit" } && reaches(reach, path),
      )
    }
    3 -> {
      use messages <- decode.field(
        "messages",
        decode.list(decode.recursive(fn() { accepted(reach) })),
      )
      decode.success(messages != [] && list.all(messages, fn(ok) { ok }))
    }
    _ -> decode.success(False)
  }
}

// Whether a socket of this reach admits an event at `path`. Each owner
// control's own path is excluded for a member, and so is anything beneath it,
// with the separator so that a path that merely begins with the same digits is
// not.
fn reaches(reach: Reach, path: String) -> Bool {
  case reach {
    Everywhere -> True
    ExceptOwner ->
      !beneath(path, component.invite_path)
      && !beneath(path, component.rename_path)
  }
}

// Whether `path` is `region` or inside it.
fn beneath(path: String, region: String) -> Bool {
  path == region || string.starts_with(path, region <> "\t")
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
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  register: fn(ui_sessions.Images) -> Nil,
  seen: server.PageGrant,
) -> Response(mist.ResponseData) {
  let role = role_of(attachment)
  let ceiling = seen.grant.ceiling
  let limit = case role {
    Observing -> root.message_limit(root.Observer)
    Operating | Owning -> operator_frame_limit
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
      check: ui_relay.while_open(fn() { authorize(attachment) }, fn() {
        result.replace(open(), Nil)
      }),
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

  // The capability to invite exists only on an owner's page. Any other page
  // has none to draw a control for or to call. It is made here, from the
  // request's own host, so the address the command names is the one the page
  // was reached at.
  let address = claim_address(request)
  let invite =
    invite_capability(role, fn(chosen) {
      invite_for(attachment, tickets, open, address, chosen)
    })

  // The capability to rename is an owner's too, and is made from the same
  // attachment: the session it renames is the attachment's, and the daemon's
  // epoch is the one the router read when it admitted the page.
  let standing = page_standing(attachment, seen)
  let rename =
    rename_capability(role, fn(name, deliver) {
      rename_task(
        standing,
        open,
        attachment.epoch,
        attachment.session_id,
        name,
        deliver,
      )
    })
  websocket(request, limit, settled, fn(signals) {
    admit(
      daemon,
      attachment,
      attach,
      tickets,
      open,
      register,
      invite,
      rename,
      seen,
      expected,
      signals,
      settled,
    )
  })
}

// The WebSocket both kinds of page run on: a page of a session
// (`upgrade`) and the home (`upgrade_home`). `admit` is what the socket does
// in its first handler turn, which differs: it takes the permit's custody and
// starts the component the page calls for. Everything after that is the same
// for both: the browser's frames go to the component's `forward`, the
// component's frames go to the browser, and an ending closes the socket.
// The HTTP process waits on `settled` for the custody transfer to have been
// attempted, so its release of the permit cannot overtake the transfer.
fn websocket(
  request: Request(mist.Connection),
  limit: Int,
  settled: process.Subject(Nil),
  admit: fn(process.Subject(Signal)) -> mist.Next(Phase, Signal),
) -> Response(mist.ResponseData) {
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
          Pending(signals), mist.Custom(Admit) -> admit(signals)

          // Nothing can reach a pending socket before its own `Admit`; the
          // arms are spelled out so a change to that order fails closed.
          Pending(_), mist.Text(_)
          | Pending(_), mist.Binary(_)
          | Pending(_), mist.Closed
          | Pending(_), mist.Shutdown
          | Pending(_), mist.Custom(Client(_))
          | Pending(_), mist.Custom(Ended(_))
          | Pending(_), mist.Custom(Stop(_))
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
          // one message and its broadcast. The reason picks the close code:
          // a reason that names no ending is a failure the person resolves.
          Serving(signals:, ..) as serving, mist.Custom(Ended(reason)) -> {
            process.send_after(
              signals,
              ended_grace_ms,
              Stop(ending.close(reason)),
            )
            mist.continue(serving)
          }

          Serving(..), mist.Custom(Stop(close)) -> closing(close)

          Serving(..), mist.Binary(_)
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

/// Upgrades one checked home request to the home component's socket
/// (protocol-change/065).
///
/// The home is bound to no session, so there is no relay, no lane and no
/// gateway: the socket starts `web_view/home`, which asks the daemon for the
/// principal's sessions when it opens and on a timer, and draws them. The
/// permit is an observer's, whose frame limit is the one this socket takes,
/// since the home takes only clicks, `home_accepts` admits nothing else, and a
/// click is a few dozen bytes.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.upgrade_home(root, request, attachment, tickets, open, seen)
/// ```
pub fn upgrade_home(
  daemon: root.Root(instance),
  request: Request(mist.Connection),
  attachment: server.HomeAttachment(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  seen: server.PageGrant,
) -> Response(mist.ResponseData) {
  let settled = process.new_subject()
  let limit = root.message_limit(root.Observer)
  let ceiling = seen.grant.ceiling
  let standing = home_standing(attachment, seen)

  // An owner's page minted to operate may rename the sessions it lists
  // (protocol-change/067) and create new ones (protocol-change/065, the fourth
  // pull request). Each is its own capability, handed to that page alone, and
  // each is checked again by the daemon when the request runs (`rename_for`,
  // `create_for`). Both forms submit beneath `home.table_path`, so the owner's
  // socket admits a submit when it holds either capability, and every other home
  // draws no control and drops the event. Which form a submit belongs to is
  // decided by the component, where each form's own decoder and message are.
  let rename =
    home_rename_capability(
      attachment.principal,
      ceiling,
      fn(target, name, deliver) {
        rename_task(standing, open, attachment.epoch, target, name, deliver)
      },
    )
  let creating =
    home_create_capability(
      attachment.principal,
      ceiling,
      fn(workspace, name, sharing, deliver) {
        create_task(
          standing,
          tickets,
          open,
          attachment.create,
          workspace,
          name,
          sharing,
          deliver,
        )
      },
    )

  // The same fresh home may stop, archive and delete the sessions it lists
  // (protocol-change/065, the addendum on session actions). The click on a row's
  // button is beneath `home.table_path`, which every home's socket admits, so no
  // admission is added: the capability is what makes the buttons exist, and
  // `manage_for` is what decides each press.
  let managing =
    home_manage_capability(
      attachment.principal,
      ceiling,
      seen.grant.reach,
      seen.grant.origin,
      fn(action, target, deliver) {
        manage_task(
          standing,
          open,
          attachment.epoch,
          attachment.sessions_directory,
          action,
          target,
          deliver,
        )
      },
    )

  // The owner's operating home that a `loom ui` exchange opened may also open
  // the admin page, and its socket then admits the one click that asks for it
  // (`home_admin_accepts`). Every other home draws no button and admits no such
  // click, so each layer holds alone.
  let administering =
    home_admin_capability(
      attachment.principal,
      ceiling,
      seen.grant.reach,
      seen.grant.origin,
      fn(deliver) { admin_ticket_task(standing, tickets, open, deliver) },
    )
  let admits = case rename, creating, administering {
    _, _, Some(_) -> home_admin_accepts
    Some(_), _, None | None, Some(_), None -> home_owner_accepts
    None, None, None -> home_accepts
  }

  // The page's own sign-ins. Every home reads and ends its principal's logins,
  // whatever its ceiling, since they are the principal's own. Only a fresh home
  // is handed the capability to make a device link.
  let signing =
    Signing(
      read: fn() { signins_read(standing, open) },
      login: option.map(seen.login, fn(issuer) { issuer.fingerprint }),
      bookmark: option.map(seen.login, fn(issuer) {
        seen.address <> page.login_home_path(issuer.key)
      }),
      out: fn(fingerprint) {
        sign_out_for(standing, attachment.epoch, open, fingerprint)
      },
      all: fn() { sign_out_all_for(standing, attachment.epoch, open) },
      device: device_capability(seen.grant.origin, fn() {
        device_link_for(standing, tickets, open, seen.address)
      }),
      who: fn() { name_read(standing, open) },
      rename_self: home_rename_self_capability(ceiling, fn(name, deliver) {
        rename_self_task(standing, open, attachment.epoch, name, deliver)
      }),
    )
  websocket(request, limit, settled, fn(signals) {
    admit_home(
      daemon,
      attachment,
      fn(target) { ticket_for(standing, tickets, open, target) },
      fn(target, deliver) {
        resume_task(standing, tickets, open, target, deliver)
      },
      rename,
      managing,
      creating,
      signing,
      administering,
      admits,
      open,
      ceiling,
      signals,
      settled,
    )
  })
}

// What a home page is handed to manage its principal's sign-ins and name: the
// read, the fingerprint of the login this page belongs to, the bookmark it draws,
// the two ways to end logins and, on a fresh home alone, the way to make a device
// link, the read of the principal's display name and, on a page minted to
// operate, the way to rename the principal.
type Signing {
  Signing(
    read: fn() -> signins.Listing,
    login: Option(String),
    bookmark: Option(String),
    out: fn(String) -> signins.Answer,
    all: fn() -> signins.Answer,
    device: Option(fn() -> signins.Answer),
    who: fn() -> Option(String),
    rename_self: Option(fn(String, fn(names.Answer) -> Nil) -> Nil),
  )
}

/// The capability to rename a listed session that a home page minted for
/// `principal` with `ceiling` is handed: `ask` for the daemon's owner on a page
/// minted to operate, and none for any other (protocol-change/067). The daemon
/// checks both facts again when the request runs (`rename_for`).
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.home_rename_capability(member, access.Operator, ask) == None
/// ```
@internal
pub fn home_rename_capability(
  principal: access.Principal,
  ceiling: access.Role,
  ask: fn(String, String, fn(renames.Answer) -> Nil) -> Nil,
) -> Option(fn(String, String, fn(renames.Answer) -> Nil) -> Nil) {
  case principal.kind, ceiling {
    access.OwnerPrincipal, access.Operator -> Some(ask)
    access.OwnerPrincipal, access.Observer
    | access.MemberPrincipal, access.Operator
    | access.MemberPrincipal, access.Observer
    -> None
  }
}

/// The capability to stop, archive and delete the sessions a home page lists,
/// that a home minted for `principal` with `ceiling`, `reach` and `origin` is
/// handed: `ask` for the daemon's owner on a page minted to operate and opened
/// by a fresh `loom ui` exchange, and none for any other (protocol-change/065,
/// the addendum on session actions). The origin rule is the Admin button's
/// (`fresh_home`): a home that a bookmark resumed, a member's home and a
/// read-only link are all refused, so a stolen bookmark cannot delete a
/// session. The daemon checks all of it again when the request runs
/// (`manage_for`).
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.home_manage_capability(member, access.Operator, ui_sessions.Workspace, ui_sessions.Fresh, ask) == None
/// ```
@internal
pub fn home_manage_capability(
  principal: access.Principal,
  ceiling: access.Role,
  reach: ui_sessions.Reach,
  origin: ui_sessions.Origin,
  ask: fn(actions.Action, String, fn(actions.Answer) -> Nil) -> Nil,
) -> Option(fn(actions.Action, String, fn(actions.Answer) -> Nil) -> Nil) {
  case principal.kind, ceiling, fresh_home(reach, origin) {
    access.OwnerPrincipal, access.Operator, Ok(Nil) -> Some(ask)
    access.OwnerPrincipal, access.Operator, Error(Nil)
    | access.OwnerPrincipal, access.Observer, _
    | access.MemberPrincipal, access.Operator, _
    | access.MemberPrincipal, access.Observer, _
    -> None
  }
}

/// The capability to create a session that a home page minted for `principal`
/// with `ceiling` is handed: `ask` for the daemon's owner on a page minted to
/// operate, and none for any other (protocol-change/065, the fourth pull
/// request). The daemon checks both facts again when the request runs
/// (`create_for`).
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.home_create_capability(member, access.Operator, ask) == None
/// ```
@internal
pub fn home_create_capability(
  principal: access.Principal,
  ceiling: access.Role,
  ask: fn(String, String, creations.Sharing, fn(creations.Answer) -> Nil) -> Nil,
) -> Option(
  fn(String, String, creations.Sharing, fn(creations.Answer) -> Nil) -> Nil,
) {
  case principal.kind, ceiling {
    access.OwnerPrincipal, access.Operator -> Some(ask)
    access.OwnerPrincipal, access.Observer
    | access.MemberPrincipal, access.Operator
    | access.MemberPrincipal, access.Observer
    -> None
  }
}

/// The browser messages a home page takes: Lustre's `EventFired` for a
/// `click`, alone or batched, at a path beneath `home.table_path`,
/// `home.sidebar_path` or `home.signins_path`, where the home's only handlers
/// are, and a `submit` beneath `home.signins_path`, where the "Your name" form is
/// (protocol-change/065, the tenth pull request), and nothing else. Each handler in the first two is one session's row,
/// whose message names the session the server drew and not one the frame chose,
/// so the frame can choose only among the rows that were drawn. Each in the
/// third is one of the page's own sign-in controls (protocol-change/065, PR 8),
/// which the daemon answers only for the principal's own logins and, for a
/// device link, only from a fresh home. Every other frame is dropped before it costs
/// the component a render, a batch with one of them included.
///
/// The paths and the separator are exact, so a path that merely begins with the
/// same digits is not admitted. The daemon refuses a row whose session the
/// principal does not hold or that no process runs (`ticket_for`), whatever
/// frame reached it, and the home's component sends its own messages from this
/// side of the socket, which a browser frame cannot produce.
///
/// ## Examples
///
/// ```gleam
/// assert !ui_socket.home_accepts("{\"kind\":1,\"name\":\"submit\"}")
/// ```
pub fn home_accepts(frame: String) -> Bool {
  case json.parse(frame, home_event(Browsing)) {
    Ok(accepted) -> accepted
    Error(_) -> False
  }
}

/// The browser messages an owner's home page takes: what `home_accepts` takes,
/// and a `submit` beneath `home.table_path`, where the forms of the owner's home
/// are: a row's rename form (protocol-change/067) and a workspace's form that
/// creates a session (protocol-change/065, the fourth pull request). It is
/// started only for a home whose principal is the daemon's owner on a page
/// minted to operate, so a member's home and an observer-ceiling home drop the
/// submit even if a frame names the path. A submit anywhere else, including the
/// sidebar, is still dropped, and so is a batch with one in it.
///
/// The socket does not say which form a submit belongs to, and cannot: it
/// admits the event by path, as it does a click. Each form's decoder and message
/// are in the component, which draws them at different places in the tree, so a
/// frame that names one form's path reaches that form's handler and only its
/// decoder, and no other.
///
/// ## Examples
///
/// ```gleam
/// assert !ui_socket.home_owner_accepts("{\"kind\":1,\"name\":\"submit\",\"path\":\"0\\t1\\t0\"}")
/// ```
pub fn home_owner_accepts(frame: String) -> Bool {
  case json.parse(frame, home_event(Submitting)) {
    Ok(accepted) -> accepted
    Error(_) -> False
  }
}

/// The browser messages an owner's home page takes when it may open the admin
/// page: what `home_owner_accepts` takes, and a `click` at `home.admin_path`,
/// where the "Admin" button is (protocol-change/065, the fifth pull request). It
/// is started only for a home whose principal is the daemon's owner, minted to
/// operate and opened by a fresh `loom ui` exchange (`home_admin_capability`), so
/// every other home, an owner's resumed one included, drops the click even if a
/// frame names the path. The path is exact: the bar holds no other handler, and a
/// path that merely begins with the same digits is not admitted.
///
/// ## Examples
///
/// ```gleam
/// assert !ui_socket.home_accepts("{\"kind\":1,\"name\":\"click\",\"path\":\"0\\t0\\t5\"}")
/// ```
pub fn home_admin_accepts(frame: String) -> Bool {
  case json.parse(frame, home_event(Administering)) {
    Ok(accepted) -> accepted
    Error(_) -> False
  }
}

// What a home socket admits besides a click on a row: nothing, the owner's
// submit of one of its forms, or that and the click on the "Admin" button.
type HomeRights {
  Browsing
  Submitting
  Administering
}

fn home_event(rights: HomeRights) -> decode.Decoder(Bool) {
  use kind <- decode.field("kind", decode.int)
  case kind {
    1 -> {
      use name <- decode.field("name", decode.string)
      use path <- decode.field("path", decode.string)
      decode.success(case name, rights {
        "click", Administering -> home_row_path(path) || path == home.admin_path
        "click", Browsing | "click", Submitting -> home_row_path(path)
        "submit", Submitting | "submit", Administering ->
          string.starts_with(path, home.table_path <> "\t") || named_path(path)
        "submit", Browsing -> named_path(path)
        _, _ -> False
      })
    }
    3 -> {
      use messages <- decode.field(
        "messages",
        decode.list(decode.recursive(fn() { home_event(rights) })),
      )
      decode.success(messages != [] && list.all(messages, fn(ok) { ok }))
    }
    _ -> decode.success(False)
  }
}

// The "Your name" form is beneath the account panel (`home.signins_path`), where
// the page's own controls are, so a page that draws it is admitted a submit there
// and nowhere else outside the owner's table forms.
fn named_path(path: String) -> Bool {
  string.starts_with(path, home.signins_path <> "\t")
}

// A row's button is beneath the table's section or the sidebar's column. The
// region's own path is not a row, so the prefix includes the separator.
fn home_row_path(path: String) -> Bool {
  string.starts_with(path, home.table_path <> "\t")
  || string.starts_with(path, home.sidebar_path <> "\t")
  || string.starts_with(path, home.signins_path <> "\t")
}

// Takes the permit in the socket's first handler turn, as `admit` does, and
// then starts the home component with the read of the principal's sessions
// and the request to open one as they are: closures over the attachment, run
// in the component's process.
fn admit_home(
  daemon: root.Root(instance),
  attachment: server.HomeAttachment(instance),
  opening: fn(String) -> sessions.Answer,
  resuming: fn(String, fn(sessions.Answer) -> Nil) -> Nil,
  rename: Option(fn(String, String, fn(renames.Answer) -> Nil) -> Nil),
  managing: Option(fn(actions.Action, String, fn(actions.Answer) -> Nil) -> Nil),
  creating: Option(
    fn(String, String, creations.Sharing, fn(creations.Answer) -> Nil) -> Nil,
  ),
  signing: Signing,
  administering: Option(fn(fn(sessions.Answer) -> Nil) -> Nil),
  admits: fn(String) -> Bool,
  open: fn() -> Result(Int, Nil),
  ceiling: access.Role,
  signals: process.Subject(Signal),
  settled: process.Subject(Nil),
) -> mist.Next(Phase, Signal) {
  let transferred = root.transfer(daemon, attachment.permit, within: 1000)
  process.send(settled, Nil)
  let start =
    home.Start(
      name: attachment.principal.display_name,
      ceiling: home_ceiling(ceiling),
      refresh_ms: home.refresh_ms,
      sessions: fn(deliver) {
        read_task(deliver, fn() {
          // The project lookup is a few stats for each entry, so it runs in the
          // same task as the read it decorates and never on the home's runtime.
          case
            home_listing(attachment, open, fn(reason) {
              process.send(signals, Ended(reason))
            })
          {
            home.Listed(entries) -> home.Listed(with_projects(entries))
            home.Unread -> home.Unread
            home.Closed(reason) -> home.Closed(reason)
          }
        })
      },
      open: opening,
      resume: resuming,
      now: bootstrap.system_time_ms,
      activity: fn(ids, deliver) {
        activity_task(attachment.activity, ids, deliver)
      },
      rename:,
      manage: managing,
      create: creating,
      signins: fn(deliver) { read_task(deliver, signing.read) },
      login: signing.login,
      bookmark: signing.bookmark,
      sign_out: signing.out,
      sign_out_all: signing.all,
      device: signing.device,
      admin: administering,
      who: fn(deliver) { read_task(deliver, signing.who) },
      rename_self: signing.rename_self,
    )
  let started = case transferred {
    Error(reason) -> {
      upgrade_log.closed_early(upgrade_log.Page, "transfer", reason)
      Error(Nil)
    }
    Ok(Nil) ->
      launch(home.app(), start, admits)
      |> result.map_error(fn(_) {
        upgrade_log.closed_early(
          upgrade_log.Page,
          "start_page",
          "the component did not start",
        )
      })
  }
  case started {
    // The permit transfer was slow or the component's start ran over its
    // budget: the close is one the client runtime retries.
    Error(Nil) -> closing(ending.close(ending.DaemonNotReady))
    Ok(#(_, page)) -> serving(page, signals)
  }
}

// The ceiling a home page was minted with, as the home words it.
fn home_ceiling(ceiling: access.Role) -> home.Ceiling {
  case ceiling {
    access.Operator -> home.OperatorCeiling
    access.Observer -> home.ObserverCeiling
  }
}

// Why a read of the home's sessions gave no list.
type Failure {
  // The page can no longer be served, for this reason.
  Gone(reason: ending.Ending)

  // The registry did not answer. The page keeps the list it has.
  Unreadable
}

/// The home's list of sessions, read as the page's principal with the digest
/// of the credential the page was admitted under. A member is listed only the
/// sessions they hold a membership in, an owner every active session, and the
/// catalogue's own fields are all an entry carries (`listed_entry`).
///
/// The read is the home's frame check as well. A page whose UI session has
/// ended, or whose credential no longer authenticates, is not listed anything:
/// the answer is `Closed`, and `ended` tells the socket, which closes after
/// the component has drawn why. A registry that does not answer is `Unread`,
/// which keeps the page's last list and ends nothing, since a slow registry
/// is no reason to sign a person out.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.home_listing(attachment, open, ended) == home.Listed([])
/// ```
@internal
pub fn home_listing(
  attachment: server.HomeAttachment(instance),
  open: fn() -> Result(Int, Nil),
  ended: fn(ending.Ending) -> Nil,
) -> home.Listing {
  case home_read(attachment, open) {
    Ok(entries) -> home.Listed(entries)
    Error(Unreadable) -> home.Unread
    Error(Gone(reason)) -> {
      ended(reason)
      home.Closed(reason)
    }
  }
}

// The two steps of a home's read, each made afresh: the page is live, and the
// catalogue's authorized page is read with the credential, which authenticates
// it first.
fn home_read(
  attachment: server.HomeAttachment(instance),
  open: fn() -> Result(Int, Nil),
) -> Result(List(sessions.Entry), Failure) {
  use _ <- result.try(open() |> result.replace_error(Gone(ending.PageEnded)))
  use #(_, views) <- result.map(
    manager.authorized_page(attachment.registry, attachment.digest, after: "")
    |> result.map_error(authentication_failure),
  )
  let entries = list.map(views, listed_entry)

  // A failed read of the roles leaves the rows without one, which is the owner's
  // case too: a row that says less than it could is the safe way to be wrong.
  case manager.authorized_roles(attachment.registry, attachment.digest) {
    Ok(roles) -> with_roles(entries, roles)
    Error(_) -> entries
  }
}

// The catalogue holding no such credential is a revoked one. Every other
// refusal is the registry failing to answer, which is not the person's doing.
fn authentication_failure(error: manager.Error) -> Failure {
  case error {
    manager.Catalogue(catalogue.Missing) -> Gone(ending.AccessRevoked)
    manager.Catalogue(_)
    | manager.NotInitialized
    | manager.SessionArchived
    | manager.Capacity
    | manager.Unavailable
    | manager.StaleOperation
    | manager.StartFailed(_)
    | manager.Preparation(_) -> Unreadable
  }
}

/// What the admitted page is: an observer's, an operator's, or an operator's
/// whose principal is the daemon's owner.
pub type Role {
  /// Read-only. The page's authority, capped by its ceiling, is observer.
  Observing

  /// The page may send prompts and answer approvals, for a member.
  Operating

  /// An operator's page whose principal is the owner: the page that draws the
  /// invitation control and holds the capability behind it. A page's
  /// authority never becomes `Owner`, so this is a fact about the principal
  /// and never about what the page's role permits.
  Owning
}

// The lower-case SHA-256 of a workspace path in hex, which the page carries
// as its storage identity (`component.Start`). A digest is not the path: the
// page's attribute and the browser's storage key never hold a path, and the
// browser cannot recover one from it.
fn digest(workspace: String) -> String {
  workspace
  |> bit_array.from_string
  |> bootstrap.sha256
  |> bit_array.base16_encode
  |> string.lowercase
}

/// The role the admitted authority and the principal give the page. The
/// router has already capped the authority, so `Owner` does not reach here
/// from a page; it is read as a member operator's for totality, which never
/// lets it invite. A page is `Owning` only when it is an operator's and its
/// principal is the daemon's owner, so an owner who asked for an observer's
/// page has no control either.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.role_of(attachment) == ui_socket.Owning
/// ```
@internal
pub fn role_of(attachment: server.Attachment(instance)) -> Role {
  case attachment.authority, attachment.principal.kind {
    access.Participant(access.Observer), _ -> Observing
    access.Owner, _
    | access.Participant(access.Operator), access.MemberPrincipal
    -> Operating
    access.Participant(access.Operator), access.OwnerPrincipal -> Owning
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
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  register: fn(ui_sessions.Images) -> Nil,
  invite: Option(fn(invites.Role) -> invites.Answer),
  rename: Option(fn(String, fn(renames.Answer) -> Nil) -> Nil),
  seen: server.PageGrant,
  expected: snapshot.Expected,
  signals: process.Subject(Signal),
  settled: process.Subject(Nil),
) -> mist.Next(Phase, Signal) {
  let role = role_of(attachment)
  let standing = page_standing(attachment, seen)
  let reach = seen.grant.reach
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
      sessions: fn(deliver) {
        listed_task(role, fn() { listed(attachment) }, deliver)
      },
      activity: fn(ids, deliver) {
        activity_for(role, attachment.activity, ids, deliver)
      },
      open: fn(target) {
        opened_for(role, fn() { ticket_for(standing, tickets, open, target) })
      },
      resume: fn(target, deliver) {
        resumed_for(role, deliver, fn() {
          resume_task(standing, tickets, open, target, deliver)
        })
      },
      invite:,
      home: home_capability(reach, fn() {
        home_ticket_for(standing, tickets, open)
      }),
      rename:,
    )

  // The start takes its standing as an argument because reading it can wait on
  // the registry for seconds, which only a page whose permit transferred should
  // pay.
  let start = fn(standing) {
    component.Start(
      session_id: attachment.session_id,
      // The route read the registration when it resolved the session,
      // so the heading's name and workspace cost no second lookup.
      label: Some(component.Label(
        name: attachment.registration.name,
        workspace: attachment.registration.workspace,
      )),
      // The digest, not the path, is what the page's storage is keyed by.
      workspace_digest: digest(attachment.registration.workspace),
      expected:,
      standing:,
      transport:,
    )
  }
  let started = case transferred {
    Error(reason) -> {
      upgrade_log.closed_early(upgrade_log.Page, "transfer", reason)
      Error(Nil)
    }
    Ok(Nil) ->
      start_page(role, start(standing_of(role, attachment)))
      |> result.map_error(fn(_) {
        upgrade_log.closed_early(
          upgrade_log.Page,
          "start_page",
          "the component did not start",
        )
      })
  }
  case started {
    // Neither failure is the person's to resolve: the daemon's permit
    // transfer was slow, or the component's start ran over its budget. The
    // close is one the client runtime retries, so a tab that hit one is not
    // left empty for good behind a final close (1000).
    Error(Nil) -> closing(ending.close(ending.DaemonNotReady))

    // The page's images are readable from the moment its component is, and a
    // reload's new socket replaces the reader the old one left.
    Ok(page) -> {
      register(page.images)
      serving(page, signals)
    }
  }
}

// What the page is told about its principal and session beyond the capture:
// whether the principal is the daemon's owner, and, for a page that may invite,
// whether the session was created to be shared. The scope is the catalogue's
// domain record, read through the owner-only members read the admin page makes
// (`chosen_members`), so a page for a private session can say so before the
// owner presses a button and no new frame exists. A page that cannot invite
// reads nothing, and a read that fails leaves the scope unknown, which draws
// the buttons as before: the daemon refuses an invitation to a private session
// whether or not the page knew.
fn standing_of(
  role: Role,
  attachment: server.Attachment(instance),
) -> component.Standing {
  let reader = case attachment.principal.kind {
    access.OwnerPrincipal -> component.DaemonOwner
    access.MemberPrincipal -> component.Participant
  }
  let sharing = case role {
    Owning ->
      case
        manager.session_member_page(
          attachment.registry,
          attachment.digest,
          attachment.session_id,
          after: "",
        )
      {
        Ok(members) ->
          Some(case members.scope {
            domain.SessionOnly -> creations.Shareable
            domain.WorkspacePrivate -> creations.Private
          })
        Error(_) -> None
      }
    Observing | Operating -> None
  }
  component.Standing(reader:, sharing:)
}

// A started page as the socket serves it: its browser frames go to the
// component, and what the component sends, like a signal of the socket's own,
// arrives in this process's mailbox.
fn serving(page: Page, signals: process.Subject(Signal)) {
  mist.continue(Serving(page.forward, page.shutdown, signals))
  |> mist.with_selector(
    process.new_selector()
    |> process.select(signals)
    |> process.merge_selector(process.map_selector(page.frames, Client)),
  )
}

// Ends the page's socket with the close code the ending calls for. Mist
// sends 1000, which Lustre's client runtime treats as final, when a handler
// returns `stop`, and 4000, which it retries after a backoff, when a handler
// returns `stop_abnormal` (the user-message path of mist's websocket
// module). The abnormal stop also exits this process abnormally, which takes
// the linked component down with it; the relay follows on its monitor.
fn closing(close: ending.Close) -> mist.Next(Phase, Signal) {
  case close {
    ending.Final -> mist.stop()
    ending.Retry -> mist.stop_abnormal("the page may retry")
  }
}

/// Starts the sidebar's read in a run of its own and returns at once, so the
/// page's runtime is free while the registry answers; `deliver` is called,
/// from that run, with the list, whatever it is. `listed_for` decides the
/// read's place: an observer's page is handed its empty list and `read` is
/// never called, so no task is started for it.
///
/// The read is one registry call (`manager.authorized_page`), bounded by its
/// own five-second timeout, and a registry busy with a turn can hold it for
/// that long. Made in the runtime's own process it held every click and
/// patch of the page behind it for up to five seconds every thirty
/// (protocol-change/051: the runtime never blocks, and daemon work runs as
/// weft tasks). The run is linked to the calling process, the page's runtime,
/// so a page that goes away cancels a read still waiting; the task's last act
/// is `deliver`, so a page that stays open is always answered.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.listed_task(Operating, read, deliver)
/// ```
@internal
pub fn listed_task(
  role: Role,
  read: fn() -> List(sessions.Entry),
  deliver: fn(List(sessions.Entry)) -> Nil,
) -> Nil {
  case role {
    Observing -> deliver(listed_for(role, read))
    Operating | Owning -> {
      let _ =
        weft.new([
          fn() {
            deliver(listed_for(role, read))
            Ok(Nil)
          },
        ])
        |> weft.start_witnessed
      Nil
    }
  }
}

// The sessions the page's principal may see, for the sidebar
// (protocol-change/051, the addendum on the session sidebar): the same
// authorized read a terminal's session picker makes. It is made with the
// digest of the credential the page was admitted under, which the registry
// authenticates again on every call, so a member is listed only the sessions
// they hold a membership in, an owner every active session, and a revoked
// credential none. It carries the catalogue's own fields, and never a
// database path or a configuration, which the entry has no place for. A
// failed read is an empty list, which the sidebar draws as nothing. It blocks
// the calling process on the registry for up to the call's five seconds, and
// on a few stats for each entry's project, so `listed_task` runs it off the
// page's runtime.
fn listed(attachment: server.Attachment(instance)) -> List(sessions.Entry) {
  case
    manager.authorized_page(attachment.registry, attachment.digest, after: "")
  {
    Ok(#(_, views)) -> list.map(views, listed_entry) |> with_projects
    Error(_) -> []
  }
}

/// The sidebar's list for a page of `role`: the read's result for an
/// operator's page, and an empty list for an observer's, with the read never
/// made.
///
/// An observer's page is the one a person hands to someone who may only watch
/// one session, and the page's authority is already the smaller of the
/// membership and the link's ceiling. The names, host paths and residency of
/// the principal's other sessions are not part of what watching one session
/// grants, so a stolen observer link must not widen to them
/// (protocol-change/051, the addendum on strand focus and the session
/// sidebar). Only an operator's page lists, and only an operator's page will
/// be offered switching.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.listed_for(Observing, read) == []
/// ```
@internal
pub fn listed_for(
  role: Role,
  read: fn() -> List(sessions.Entry),
) -> List(sessions.Entry) {
  case role {
    Observing -> []
    Operating | Owning -> read()
  }
}

/// The sidebar's activity read for a page of `role`: the daemon's read
/// (`server.home_activity`, held by the page's own credential) from a task of
/// its own for an operator's page, and nothing for an observer's, which lists no
/// sessions and so asks about none. The answer is delivered from the task.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.activity_for(Observing, ask, ["0198..."], deliver)
/// ```
@internal
pub fn activity_for(
  role: Role,
  ask: fn(List(String)) -> List(#(String, sessions.Activity)),
  ids: List(String),
  deliver: fn(List(#(String, sessions.Activity))) -> Nil,
) -> Nil {
  case role {
    Observing -> Nil
    Operating | Owning -> activity_task(ask, ids, deliver)
  }
}

/// The daemon's answer to an operator's page asking to open another session:
/// `ask`'s result for an operator's page, and a refusal for an observer's,
/// with nothing asked.
///
/// The observer's view draws no sidebar and its message type has no way to
/// ask, and its socket drops every click beneath the sidebar's path, so no
/// request reaches here from one. This is the third independent layer, so that
/// a change to either of the others cannot let a link handed to someone who
/// may only watch mint a ticket (protocol-change/051, the addendum on
/// switching sessions). The refusal is `NotHeld`, the same words as for a
/// session the principal does not hold.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.opened_for(Observing, ask) == sessions.Declined(sessions.NotHeld)
/// ```
@internal
pub fn opened_for(role: Role, ask: fn() -> sessions.Answer) -> sessions.Answer {
  case role {
    Observing -> sessions.Declined(sessions.NotHeld)
    Operating | Owning -> ask()
  }
}

/// Starts the resume of a saved session for an operator's page, and answers a
/// refusal for an observer's without starting anything. `start` is the task
/// that does the work and `deliver` is where the refusal goes.
///
/// As `opened_for`, this is the third independent layer for an observer's page:
/// the observer's view draws no sidebar and its message type has no resume, its
/// socket drops every click beneath the sidebar, and the daemon refuses here.
/// The refusal is `NotHeld`, the words for a session the principal does not
/// hold, so a page learns nothing about sessions it may not open.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.resumed_for(Observing, deliver, start)
/// ```
@internal
pub fn resumed_for(
  role: Role,
  deliver: fn(sessions.Answer) -> Nil,
  start: fn() -> Nil,
) -> Nil {
  case role {
    Observing -> deliver(sessions.Declined(sessions.NotHeld))
    Operating | Owning -> start()
  }
}

/// What a page that asks for a ticket stands for: the registry that answers
/// its questions, the digest of the credential it was admitted under, its
/// principal, the ceiling it was minted with and the reach it was minted for.
/// The daemon builds it from the attachment the router authenticated and never
/// from anything the page said, and every ticket the page asks for carries its
/// credential, principal, ceiling and reach, so a page can mint nothing that
/// stands for more than it does. A session page and a home page are asked for
/// tickets in the same way, which is why they share it.
pub type Standing(instance) {
  Standing(
    /// The registry the page's questions go to.
    registry: manager.Manager(instance),
    /// The credential the page was admitted under. Every later check
    /// authenticates it again.
    digest: access.Digest,
    /// The authenticated principal's identity.
    principal: String,
    /// The most the page may do, which caps the role every page it opens is
    /// admitted with.
    ceiling: access.Role,
    /// What the page was minted for, carried onto every page it opens.
    reach: ui_sessions.Reach,
    /// How the page was reached, carried onto every ticket it mints so a chain
    /// from a resumed page stays resumed (protocol-change/065, PR 8).
    origin: ui_sessions.Origin,
    /// The browser login the page is the browser of, carried onto every ticket
    /// it mints so the page it opens belongs to the same login, and which a
    /// device link inherits its expiry from.
    login: Option(ui_sessions.Issuer),
  )
}

/// The standing of a session page, from its attachment and the grant it was
/// admitted under.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.page_standing(attachment, seen)
/// ```
@internal
pub fn page_standing(
  attachment: server.Attachment(instance),
  seen: server.PageGrant,
) -> Standing(instance) {
  Standing(
    registry: attachment.registry,
    digest: attachment.digest,
    principal: attachment.principal.id,
    ceiling: seen.grant.ceiling,
    reach: seen.grant.reach,
    origin: seen.grant.origin,
    login: seen.login,
  )
}

/// The standing of a home page, from its attachment and the grant it was
/// admitted under.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.home_standing(attachment, seen)
/// ```
@internal
pub fn home_standing(
  attachment: server.HomeAttachment(instance),
  seen: server.PageGrant,
) -> Standing(instance) {
  Standing(
    registry: attachment.registry,
    digest: attachment.digest,
    principal: attachment.principal.id,
    ceiling: seen.grant.ceiling,
    reach: seen.grant.reach,
    origin: seen.grant.origin,
    login: seen.login,
  )
}

/// The principal's own sign-ins, read with the page's credential, or `Unread`
/// when the page has ended or the registry did not answer. The registry
/// authenticates the credential again and reads only that principal's rows, so a
/// page learns nothing about another principal's logins. A page whose credential
/// was revoked is ended by the sessions read; this read has nothing to add.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.signins_read(standing, open)
/// ```
@internal
pub fn signins_read(
  standing: Standing(instance),
  open: fn() -> Result(Int, Nil),
) -> signins.Listing {
  case open() {
    Error(Nil) -> signins.Unread
    Ok(_) ->
      case
        manager.signins(
          standing.registry,
          standing.digest,
          None,
          after: "",
          now_ms: bootstrap.system_time_ms(),
        )
      {
        Ok(#(_, page)) -> signins.Listed(list.map(page.entries, listed_signin))
        Error(_) -> signins.Unread
      }
  }
}

// A login as the catalogue holds it, as the page draws it.
fn listed_signin(row: access.Signin) -> signins.Signin {
  signins.Signin(
    fingerprint: row.fingerprint,
    issued_at_ms: row.issued_at_ms,
    last_resumed_ms: row.last_resumed_ms,
    expires_at_ms: row.expires_at_ms,
    issued_by: row.issued_by,
  )
}

/// Ends one of the page's principal's own sign-ins, named by `fingerprint`
/// (protocol-change/065, PR 8). The page must still be open and the registry
/// authenticates its credential and the daemon's epoch again in the same turn as
/// the write, and finds the login among this principal's `browser` rows and no
/// other: a fingerprint of another principal's login, or of a bearer, is
/// `NotFound`. Revoking the row ends every page the login minted at that page's
/// next frame. It is logged as `daemon.login_revoked`.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.sign_out_for(standing, epoch, open, "9c1e0f2ab3d4e5f6")
/// ```
@internal
pub fn sign_out_for(
  standing: Standing(instance),
  epoch: String,
  open: fn() -> Result(Int, Nil),
  fingerprint: String,
) -> signins.Answer {
  case open() {
    Error(Nil) -> signins.Declined(signins.Unavailable)
    Ok(_) ->
      case
        manager.revoke_login(
          standing.registry,
          standing.digest,
          epoch,
          None,
          fingerprint,
        )
      {
        Ok(#(principal, digest)) -> {
          ui_login.revoked(principal, digest)
          signins.Revoked
        }
        Error(error) -> signins.Declined(sign_out_reason(error))
      }
  }
}

/// Ends every sign-in of the page's principal ("sign out everywhere"), under the
/// rules of `sign_out_for`, and logs the count as `daemon.login_revoked`.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.sign_out_all_for(standing, epoch, open)
/// ```
@internal
pub fn sign_out_all_for(
  standing: Standing(instance),
  epoch: String,
  open: fn() -> Result(Int, Nil),
) -> signins.Answer {
  case open() {
    Error(Nil) -> signins.Declined(signins.Unavailable)
    Ok(_) ->
      case
        manager.revoke_logins(standing.registry, standing.digest, epoch, None)
      {
        Ok(#(principal, count)) -> {
          ui_login.revoked_all(principal, count)
          signins.Revoked
        }
        Error(error) -> signins.Declined(sign_out_reason(error))
      }
  }
}

// A refused sign-out in the page's words. A fingerprint the principal does not
// hold is the one the person can act on; every other refusal is the daemon's.
fn sign_out_reason(error: manager.AdminError) -> signins.Reason {
  case error {
    manager.AdminMetadata(catalogue.Missing)
    | manager.AdminMetadata(catalogue.Invalid(_)) -> signins.NotFound
    manager.AdminMetadata(_)
    | manager.IsolationRequired
    | manager.AdminForbidden
    | manager.AdminStaleEpoch
    | manager.AdminUnavailable
    | manager.AdminBusy
    | manager.AdminForeignPath -> signins.Unavailable
  }
}

/// The capability to make a device link that a home page of `origin` is handed:
/// `ask` for a fresh home, and none for a home the bookmark resumed, which draws
/// no control. The daemon checks the origin again when the request runs
/// (`device_link_for`).
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.device_capability(ui_sessions.Resumed, ask) == None
/// ```
@internal
pub fn device_capability(
  origin: ui_sessions.Origin,
  ask: fn() -> signins.Answer,
) -> Option(fn() -> signins.Answer) {
  case origin {
    ui_sessions.Fresh -> Some(ask)
    ui_sessions.Resumed -> None
  }
}

/// A link that signs in another device, or the reason there is none
/// (protocol-change/065, PR 8). The link is a `Home` ticket that is
/// `Remembered`, so its exchange sets a browser login on the device that opens
/// it, and it lives ten minutes (`ui_sessions.device_ms`) instead of sixty
/// seconds.
///
/// Each step is the daemon's own and is made afresh, and none is taken from the
/// page:
///
/// 0. The page must still be open (`open`), and its deadline goes on the ticket,
///    so the page the link opens never outlives the page that made it.
/// 1. The page must be a fresh home: opened by a `loom ui` exchange, a claim or a
///    device link, and not by the bookmark and not by a chain from the bookmark.
///    A stolen bookmark must not be able to make a second credential, so a
///    resumed home is `NotFresh` (the second layer; it is handed no control).
/// 2. The credential the page was admitted under must still authenticate as the
///    principal.
/// 3. The credential must have a place in its grant allowance
///    (`ui_sessions.reserve_invite`), the one allowance an invitation, a
///    promotion and a link share. A place is given back if no ticket was minted.
/// 4. The ticket carries the page's own principal, credential and ceiling, and
///    the login the page belongs to, so the login the link sets inherits that
///    login's expiry and names it as its parent: no family of logins outlives the
///    one it began from. A page with no login (`loom ui --no-remember`) gives the
///    new login thirty days of its own.
///
/// The answer is the whole address, `address` (the daemon's own, as the browser
/// reached it) and the ticket's exchange.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.device_link_for(standing, tickets, open, "http://127.0.0.1:4000")
/// ```
@internal
pub fn device_link_for(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  address: String,
) -> signins.Answer {
  let checked = {
    use until <- result.try(open() |> result.replace_error(signins.Unavailable))
    use Nil <- result.try(case standing.origin {
      ui_sessions.Fresh -> Ok(Nil)
      ui_sessions.Resumed -> Error(signins.NotFresh)
    })
    use principal <- result.try(
      manager.authenticate(standing.registry, standing.digest)
      |> result.replace_error(signins.Unavailable),
    )
    use Nil <- result.map(case principal.id == standing.principal {
      True -> Ok(Nil)
      False -> Error(signins.Unavailable)
    })
    until
  }
  case checked {
    Error(reason) -> signins.Declined(reason)
    Ok(until) ->
      case ui_sessions.reserve_invite(tickets, standing.digest) {
        Error(_) -> signins.Declined(signins.TooMany)
        Ok(Nil) ->
          case
            ui_sessions.mint_device(
              tickets,
              ui_sessions.Grant(
                scope: ui_sessions.Home,
                credential: standing.digest,
                principal: standing.principal,
                ceiling: standing.ceiling,
                reach: ui_sessions.Workspace,
                origin: ui_sessions.Fresh,
                remember: ui_sessions.Remembered,
              ),
              until,
              standing.login,
            )
          {
            Ok(issued) ->
              signins.Linked(address <> page.home_exchange_path(issued.ticket))
            Error(Nil) -> {
              ui_sessions.release_invite(tickets, standing.digest)
              signins.Declined(signins.Unavailable)
            }
          }
      }
  }
}

/// The capability to go home that a page of `reach` is handed: `ask` for a
/// page that was opened from a home, and none for a page a link for one
/// session opened, which is the whole of who draws the "Home" button.
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.home_capability(ui_sessions.OneSession, ask) == None
/// ```
@internal
pub fn home_capability(
  reach: ui_sessions.Reach,
  ask: fn() -> sessions.Answer,
) -> Option(fn() -> sessions.Answer) {
  case reach {
    ui_sessions.Workspace -> Some(ask)
    ui_sessions.OneSession -> None
  }
}

/// A ticket for the home page of the asking page's principal, or the reason
/// there is none (protocol-change/065, the second pull request).
///
/// Each step is the daemon's own and is made afresh, and none is taken from
/// the page:
///
/// 0. The asking page must still be open, as for `ticket_for`: `open` answers
///    its deadline while the page's UI session is live and unreplaced. The
///    deadline goes on the ticket, so the home it becomes ends no later than
///    this page, and a chain home, session, home never outlives the home it
///    began from.
/// 1. The credential the page was admitted under must still authenticate, and
///    must still be the principal's: a revoked credential gets no way back.
/// 2. The ticket carries the page's own credential, principal, ceiling, origin
///    and login, so a home reached from an observer page is an observer's home
///    and a home reached from a resumed page is a resumed one. Its reach is
///    `Workspace`, and it is never remembered: nothing a page mints sets a
///    browser login.
///
/// Every refusal is `NoHome`, whose words do not say which step failed.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.home_ticket_for(standing, tickets, open)
/// ```
@internal
pub fn home_ticket_for(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
) -> sessions.Answer {
  let outcome = {
    use until <- result.try(open() |> result.replace_error(sessions.NoHome))
    use principal <- result.try(
      manager.authenticate(standing.registry, standing.digest)
      |> result.replace_error(sessions.NoHome),
    )
    use _ <- result.try(case principal.id == standing.principal {
      True -> Ok(Nil)
      False -> Error(sessions.NoHome)
    })
    ui_sessions.mint_in(
      tickets,
      ui_sessions.Grant(
        scope: ui_sessions.Home,
        credential: standing.digest,
        principal: standing.principal,
        ceiling: standing.ceiling,
        reach: ui_sessions.Workspace,
        origin: standing.origin,
        remember: ui_sessions.Forgotten,
      ),
      until,
      standing.login,
    )
    |> result.replace_error(sessions.NoHome)
  }
  case outcome {
    Ok(issued) -> sessions.Ticketed(page.home_exchange_path(issued.ticket))
    Error(reason) -> sessions.Declined(reason)
  }
}

/// A ticket for the asking page's principal to open `target`, or the reason
/// there is none. The asking page is a session page's operator or a home.
///
/// Each step is the daemon's own and is made afresh, with the digest of the
/// credential the page was admitted under, and none is taken from the page:
///
/// 0. The asking page must still be open: `open` answers its deadline while
///    the page's UI session is live and unreplaced, and a page that has ended
///    but whose socket is still up mints nothing (`NotHeld`). The deadline
///    goes on the ticket (`ui_sessions.mint_before`), so the page it becomes
///    ends no later than this one, and a chain of switches never outlives
///    the page it began from.
/// 1. `target` must be a canonical session identity.
/// 2. `manager.session_authority` must find a membership of the page's
///    principal in `target`, an owner's in every active session. This is the
///    check `ui.link` makes for `loom ui`, so a page can open exactly the
///    sessions its principal could already ask a link for, and a revoked
///    credential or a removed membership opens none.
/// 3. `target` must have a process running it, since the ticket's page would
///    otherwise be refused at its socket with nothing to say why.
/// 4. The ticket carries the page's own ceiling, which caps the role the new
///    page is admitted with and never grants one, so a switch cannot raise
///    what a link allowed, and its own reach, so a page opened from a home
///    draws its way back and a page opened from a link for one session does
///    not. It is single use and lives 60 seconds like any other, and is minted
///    into the same table, so the page cap and the redemption rules are
///    unchanged.
///
/// The reasons are `NotHeld` for an identity that is not a session's or is
/// not the principal's, `NotRunning` for a saved session and `Unavailable`
/// for anything the daemon could not answer. `NotHeld` covers a session that
/// does not exist and one the principal cannot see alike.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.ticket_for(standing, tickets, open, target)
/// ```
@internal
pub fn ticket_for(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  target: String,
) -> sessions.Answer {
  let outcome = {
    use until <- result.try(open() |> result.replace_error(sessions.NotHeld))
    use _ <- result.try(
      ids.parse_session_id(target) |> result.replace_error(sessions.NotHeld),
    )
    use _ <- result.try(
      manager.session_authority(standing.registry, standing.digest, target)
      |> result.map_error(not_held),
    )
    use view <- result.try(
      manager.get(standing.registry, target)
      |> result.replace_error(sessions.Unavailable),
    )
    use _ <- result.try(running(view.status))
    ui_sessions.mint_in(
      tickets,
      ui_sessions.Grant(
        scope: ui_sessions.Session(target),
        credential: standing.digest,
        principal: standing.principal,
        ceiling: standing.ceiling,
        reach: standing.reach,
        origin: standing.origin,
        remember: ui_sessions.Forgotten,
      ),
      until,
      standing.login,
    )
    |> result.replace_error(sessions.Unavailable)
  }
  case outcome {
    Ok(issued) -> sessions.Ticketed(page.exchange_path(target, issued.ticket))
    Error(reason) -> sessions.Declined(reason)
  }
}

/// Resumes a saved session for the asking page's principal and mints a ticket
/// for the page it opens, waiting at most `within` milliseconds for the session
/// to become resident, or gives the reason there is no ticket
/// (protocol-change/065, the third pull request). It blocks the calling process
/// for the wait, so a page's component never calls it directly: `resume_task`
/// runs it in a run of its own.
///
/// It is the control command's `OpenSession` (`client/daemon/server`) made on
/// the page's behalf. Each step is the daemon's and is made afresh, with the
/// digest of the credential the page was admitted under, and none is taken from
/// the page:
///
/// 0. The asking page must still be open (`open` answers its deadline). That is
///    also the page's epoch: a page's UI session lives in this daemon's memory,
///    so a page that is open was admitted by this daemon and by no earlier one,
///    which is the check the control command makes by comparing epochs.
/// 1. The page's ceiling must be Operator. An observer-ceiling page's home and
///    session pages are refused as a session the principal does not hold, so
///    they learn nothing about it.
/// 2. `target` must be a canonical session identity, and
///    `manager.session_authority` must find the principal Owner or Operator in
///    it. An observer member gets `NotOperator`, the words the control command's
///    own refusal ("forbidden") has, and a principal with no membership gets
///    `NotHeld` as `ticket_for` does.
/// 3. `manager.open` is the registry turn `sessions.open` runs: capacity, a
///    reserved creation, an archived session, the domain slot. Any refusal is
///    `NotOpened`, and its detail stays in the daemon.
/// 4. The registry is read until the session is resident, for at most `within`.
///    A session still opening is waited for. A session that stops being
///    openable (back to saved, stopping, blocked) or an unreadable registry
///    ends the wait at once, and a wait that runs out is `NotOpened` too: no
///    ticket exists for a session that did not open in time.
/// 5. `ticket_for` mints as it does for a switch, after checking the page,
///    membership and residency a second time, since the wait was long.
///
/// A ticket that `ticket_for` would refuse as `NotRunning` is `NotOpened` here:
/// the session was resident a moment ago and is not now.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.resume_for(standing, tickets, open, target, within: 30_000)
/// ```
@internal
pub fn resume_for(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  target: String,
  within within: Int,
) -> sessions.Answer {
  let checked = {
    use _ <- result.try(open() |> result.replace_error(sessions.NotHeld))
    use _ <- result.try(operating_ceiling(standing.ceiling))
    use _ <- result.try(
      ids.parse_session_id(target) |> result.replace_error(sessions.NotHeld),
    )
    use #(_, authority) <- result.try(
      manager.session_authority(standing.registry, standing.digest, target)
      |> result.map_error(not_held),
    )
    operating_authority(authority)
  }
  case checked {
    Error(reason) -> sessions.Declined(reason)
    Ok(Nil) -> opened_ticket(standing, tickets, open, target, within)
  }
}

// Asks the registry to open `target`, waits for it to be resident and mints the
// page's ticket, which is the part of a resume and of a creation that comes after
// the page's standing has been checked. A ticket that `ticket_for` would refuse
// as `NotRunning` is `NotOpened` here: the session was resident a moment ago and
// is not now.
fn opened_ticket(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  target: String,
  within: Int,
) -> sessions.Answer {
  let outcome = {
    use _ <- result.try(
      manager.open(standing.registry, target)
      |> result.replace_error(sessions.NotOpened),
    )
    resident_within(standing.registry, target, within)
  }
  case outcome {
    Error(reason) -> sessions.Declined(reason)
    Ok(Nil) ->
      case ticket_for(standing, tickets, open, target) {
        sessions.Declined(sessions.NotRunning) ->
          sessions.Declined(sessions.NotOpened)
        answer -> answer
      }
  }
}

// Only a page minted to operate may ask the daemon to run a session. The
// refusal is the one for a session the principal does not hold, as an
// observer's switch is refused.
fn operating_ceiling(ceiling: access.Role) -> Result(Nil, sessions.Reason) {
  case ceiling {
    access.Operator -> Ok(Nil)
    access.Observer -> Error(sessions.NotHeld)
  }
}

// The control command's own role check for an open: Owner or Operator.
fn operating_authority(
  authority: access.Authority,
) -> Result(Nil, sessions.Reason) {
  case authority {
    access.Owner | access.Participant(access.Operator) -> Ok(Nil)
    access.Participant(access.Observer) -> Error(sessions.NotOperator)
  }
}

// Reads the registry until `target` is resident or the wait ends, by
// `weft/poll`. A status that cannot become resident without a new request ends
// the wait at once rather than burning the budget on it.
fn resident_within(
  registry: manager.Manager(instance),
  target: String,
  within: Int,
) -> Result(Nil, sessions.Reason) {
  let outcome =
    poll.until(within:, every: 50, attempt: fn() {
      case manager.get(registry, target) {
        Error(_) -> poll.Fail(sessions.NotOpened)
        Ok(view) ->
          case view.status {
            manager.Resident(_) -> poll.Done(Nil)
            manager.Opening(_) -> poll.Retry
            manager.Reserved
            | manager.Saved
            | manager.Stopping(_)
            | manager.RecoveryBlocked(_) -> poll.Fail(sessions.NotOpened)
          }
      }
    })
  case outcome {
    poll.Answered(Nil) -> Ok(Nil)
    poll.Failed(reason) -> Error(reason)
    poll.Expired -> Error(sessions.NotOpened)
  }
}

/// Starts `resume_for` in a run of its own and returns at once, so the page's
/// runtime is free while a session starts; `deliver` is called, from that run,
/// with the answer, whatever it is.
///
/// The run is a weft run with one task, linked to the calling process, which
/// is the page's runtime: a page that goes away cancels the wait, and the open
/// it already asked for finishes on the registry's own custody as any open
/// does. The task's last act is `deliver`, so a page that stays open is always
/// answered.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.resume_task(standing, tickets, open, target, deliver)
/// ```
@internal
pub fn resume_task(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  target: String,
  deliver: fn(sessions.Answer) -> Nil,
) -> Nil {
  // The run has no deadline of its own. Every step of `resume_for` is bounded
  // by its own call timeouts (the wait by `resume_wait_ms`, each registry call
  // by its own few seconds), so the task always answers within about a minute;
  // a deadline could only kill a task that would have answered. The link to
  // the runtime still cancels it when the page goes away.
  let _ =
    weft.new([
      fn() {
        deliver(resume_for(
          standing,
          tickets,
          open,
          target,
          within: resume_wait_ms,
        ))
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  Nil
}

/// Creates a session for the asking page's owner in `workspace`, opens it and
/// mints a ticket for its page, waiting at most `within` milliseconds for it to
/// become resident, or gives the reason there is no ticket (protocol-change/065,
/// the fourth pull request). It blocks the calling process, so a page's
/// component never calls it directly: `create_task` runs it in a run of its own.
///
/// It is the control command `sessions.create` (`server.create_session`) made
/// on the page's behalf. Each step is the daemon's and is made afresh, with the
/// digest of the credential the page was admitted under, and nothing is taken
/// from the page but the text of the name, the sharing it chose and the
/// workspace its own list drew:
///
/// 0. The asking page must still be open (`open`). That is also the page's
///    epoch, as for `resume_for`: a page that is open was admitted by this
///    daemon and by no earlier one.
/// 1. The page's ceiling must be Operator, and the credential must still
///    authenticate as the principal the page was admitted for, and that
///    principal must be the daemon's owner. Each is `NotOwner`, so a page
///    learns nothing else about its standing.
/// 2. The name must pass `creations.chosen_name` (`InvalidName`), and the
///    workspace must be one the owner holds a session in, read afresh from the
///    catalogue with the page's credential (`NotKnown`). The page never names a
///    path the owner has no session in, whatever frame reached the daemon.
/// 3. The credential must have a creation left (`ui_sessions.reserve_creation`),
///    counted for the credential and not for the page (`TooMany`).
/// 4. `create` makes the session under a key drawn here, which no other
///    request shares, so a retry of this call is a new creation and a repeat of
///    the page's press is stopped by the component, which has one out at a
///    time. The sharing becomes the domain scope: `Shareable` is
///    `session_only` and `Private` is `workspace_private`.
/// 5. The session is opened and its ticket minted as a resume's is
///    (`opened_ticket`), with the page's own ceiling, reach and deadline. A
///    session that was created and did not open is `NotOpened`, which says it
///    exists.
///
/// A success is logged as `daemon.session_created` with the principal and the
/// session, so a run of creations from a page is visible in the daemon's log.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.create_for(standing, tickets, open, create, "/work/loom", "", creations.Private, within: 30_000)
/// ```
@internal
pub fn create_for(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  create: fn(access.Principal, manager.Creation, domain.Scope) ->
    Result(manager.View, String),
  workspace: String,
  name: String,
  sharing: creations.Sharing,
  within within: Int,
) -> creations.Answer {
  let outcome = {
    use _ <- result.try(open() |> result.replace_error(creations.NotOwner))
    use _ <- result.try(
      operating_ceiling(standing.ceiling)
      |> result.replace_error(creations.NotOwner),
    )
    use principal <- result.try(
      manager.authenticate(standing.registry, standing.digest)
      |> result.replace_error(creations.NotOwner),
    )
    use _ <- result.try(case principal.id == standing.principal {
      True -> owner_of(principal)
      False -> Error(creations.NotOwner)
    })
    use name <- result.try(
      creations.chosen_name(name, workspace)
      |> result.replace_error(creations.InvalidName),
    )
    use _ <- result.try(known_workspace(standing, workspace))
    use _ <- result.try(
      ui_sessions.reserve_creation(tickets, standing.digest)
      |> result.replace_error(creations.TooMany),
    )
    let key = "web-" <> hex_entropy(16)
    manager.Creation(key, workspace, name, "")
    |> create(principal, _, scope_of(sharing))
    |> result.map(fn(view) { #(principal, view.registration.id) })
    |> result.map_error(creation_refusal)
  }
  case outcome {
    Error(reason) -> creations.Declined(reason)
    Ok(#(principal, session)) -> {
      // Both are identifiers the catalogue minted and carry no authority, so
      // they are written as `ident`: the free-text rule would replace a long
      // unbroken run, which a principal's identity can be, with a redaction
      // marker, and the line exists so a run of creations can be attributed.
      log.info(log.erlang(threshold: level.Info), "daemon.session_created", [
        field.ident("principal", principal.id),
        field.ident("session", session),
        field.ident("via", "page"),
      ])
      case opened_ticket(standing, tickets, open, session, within) {
        sessions.Ticketed(path:) -> creations.Ticketed(path)
        sessions.Declined(_) -> creations.Declined(creations.NotOpened)
      }
    }
  }
}

// Only the daemon's owner creates a session. A member's page is refused here
// even if a message reached it.
fn owner_of(principal: access.Principal) -> Result(Nil, creations.Reason) {
  case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error(creations.NotOwner)
  }
}

// A workspace is known when the owner holds a session in it now. The read is the
// home's own list, made with the page's credential, so the creation is possible
// in exactly the workspaces the page could have drawn a button for.
fn known_workspace(
  standing: Standing(instance),
  workspace: String,
) -> Result(Nil, creations.Reason) {
  case manager.authorized_page(standing.registry, standing.digest, after: "") {
    Error(_) -> Error(creations.Unavailable)
    Ok(#(_, views)) ->
      case
        list.any(views, fn(view) { view.registration.workspace == workspace })
      {
        True -> Ok(Nil)
        False -> Error(creations.NotKnown)
      }
  }
}

fn scope_of(sharing: creations.Sharing) -> domain.Scope {
  case sharing {
    creations.Shareable -> domain.SessionOnly
    creations.Private -> domain.WorkspacePrivate
  }
}

// The control command's code for a refused creation, in the page's fixed words.
// A workspace that cannot be canonicalized now is not one the owner can use, a
// full registry is its own words, and the rest read alike: the daemon's detail
// stays in the daemon.
fn creation_refusal(code: String) -> creations.Reason {
  case code {
    "forbidden" -> creations.NotOwner
    "invalid_workspace" -> creations.NotKnown
    "capacity" -> creations.Full
    _ -> creations.Unavailable
  }
}

fn hex_entropy(bytes: Int) -> String {
  token.production_entropy()(bytes)
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Starts `create_for` in a run of its own and returns at once, so the page's
/// runtime is free while a session is created and started; `deliver` is called,
/// from that run, with the answer, whatever it is.
///
/// The run is a weft run with one task, linked to the calling process, which is
/// the page's runtime, as `resume_task`'s is: a page that goes away cancels the
/// wait, and a creation the registry has already begun finishes on the
/// registry's own custody. The run has no deadline, since every step of
/// `create_for` is bounded by its own call timeouts (the wait by
/// `resume_wait_ms`) and a deadline could only kill a task that would have
/// answered. Its last act is `deliver`, so a page that stays open is always
/// answered.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.create_task(standing, tickets, open, create, workspace, "", creations.Private, deliver)
/// ```
@internal
pub fn create_task(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  create: fn(access.Principal, manager.Creation, domain.Scope) ->
    Result(manager.View, String),
  workspace: String,
  name: String,
  sharing: creations.Sharing,
  deliver: fn(creations.Answer) -> Nil,
) -> Nil {
  let _ =
    weft.new([
      fn() {
        deliver(create_for(
          standing,
          tickets,
          open,
          create,
          workspace,
          name,
          sharing,
          within: resume_wait_ms,
        ))
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  Nil
}

/// Starts the home page's activity read in a run of its own and returns at
/// once, so the page's runtime never waits for the sessions to answer;
/// `deliver` is called, from that run, with what `ask` returned.
///
/// `ask` is the daemon's `sessions.activity` read (`server.activity_states`),
/// which asks every named session concurrently under one deadline of its own
/// and leaves out any that did not answer, so the run ends within that
/// deadline. The run is linked to the calling process, which is the page's
/// runtime, so a page that goes away cancels the read, and `deliver` is its last
/// act, so a page that stays open is always answered, with an empty list when
/// nothing answered. A run that crashed delivers nothing, and the page keeps
/// the words it had until the next list asks again.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.activity_task(attachment.activity, ["0198..."], deliver)
/// ```
@internal
pub fn activity_task(
  ask: fn(List(String)) -> List(#(String, sessions.Activity)),
  ids: List(String),
  deliver: fn(List(#(String, sessions.Activity))) -> Nil,
) -> Nil {
  read_task(deliver, fn() { ask(ids) })
}

/// Runs `read`, a registry read that may wait up to its calls' timeouts, in
/// a weft run of its own and returns at once; `deliver` is called from that
/// run with the answer, whatever it is. The home's three timer-driven reads
/// (the list, the sign-ins and the name) take this shape, as the activity
/// read does, so the home's runtime never waits on the registry
/// (protocol-change/051, the addendum on the sidebar's read). The run is
/// linked to the calling process, the page's runtime, so a page that goes
/// away cancels a read still waiting; the task's last act is `deliver`, so a
/// page that stays open is always answered.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.read_task(deliver, fn() { signins_read(standing, open) })
/// ```
@internal
pub fn read_task(deliver: fn(answer) -> Nil, read: fn() -> answer) -> Nil {
  let _ =
    weft.new([
      fn() {
        deliver(read())
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  Nil
}

/// The daemon's answer to an owner's page asking to invite a person to the
/// page's own session: an invitation, or the reason there is none
/// (protocol-change/051, the addendum on inviting from the session page).
///
/// It is the `sessions.invite` the control endpoint runs, through the same
/// manager dispatch and the same claim, made on the page's behalf and for its
/// own session only. Each step is the daemon's and is made afresh, with the
/// digest of the credential the page was admitted under, and nothing is taken
/// from the page but the role its button named:
///
/// 0. The asking page must still be open. A page that ended but whose socket
///    is still up invites nobody (`NotOwner`).
/// 1. The page's principal must be the daemon's owner, read from the
///    principal the router authenticated and never from the page.
/// 2. The claim's address must be known: the page was reached at a loopback
///    host, and `loom claim` accepts the address made from it.
/// 3. The credential must have an invitation left
///    (`ui_sessions.reserve_invite`), counted for the credential and not for
///    the page. A page taken by a program is held to the same count as the
///    owner's own, and opening or switching pages does not reset it.
/// 4. `manager.administer` invites a new principal into this session with a
///    claim that lives `invites.claim_ttl_ms`. It authenticates the credential
///    and the epoch a second time and needs the owner, so it is the last word
///    on who may. A refusal that made nothing gives the invitation back; an
///    unknown outcome (the registry did not answer) keeps it spent, since a
///    principal may have been made.
///
/// The principal's ID and name are the daemon's, `guest-` and eight
/// hexadecimal digits, so the page chooses neither. The claim exists in this
/// function's result and nowhere else: it is not logged, stored or put in a
/// URL, and the catalogue holds only its digest.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.invite_for(attachment, tickets, open, Ok(address), invites.Observer)
/// ```
@internal
pub fn invite_for(
  attachment: server.Attachment(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  address: Result(String, Nil),
  chosen: invites.Role,
) -> invites.Answer {
  case may_invite(open, attachment.principal, address) {
    Error(reason) -> invites.Declined(reason)
    Ok(address) ->
      case ui_sessions.reserve_invite(tickets, attachment.digest) {
        Error(_) -> invites.Declined(invites.TooMany)
        Ok(Nil) ->
          case invited(attachment, address, chosen) {
            Ok(invitation) -> invites.Minted(invitation)
            Error(refusal) -> {
              give_back(tickets, attachment.digest, refusal)
              invites.Declined(reason_of(refusal))
            }
          }
      }
  }
}

/// The capability a page of `role` is handed: `ask` for an owner's page and
/// none for any other, which is the whole of who may draw and call the
/// invitation control.
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.invite_capability(ui_socket.Operating, ask) == None
/// ```
@internal
pub fn invite_capability(
  role: Role,
  ask: fn(invites.Role) -> invites.Answer,
) -> Option(fn(invites.Role) -> invites.Answer) {
  case role {
    Owning -> Some(ask)
    Observing | Operating -> None
  }
}

/// The first three steps of `invite_for`, which reach neither the allowance
/// nor the manager: the page must still be open, its principal must be the
/// owner, and the claim address must be known. Returns the address.
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.may_invite(fn() { Ok(0) }, member, Error(Nil)) == Error(invites.NotOwner)
/// ```
@internal
pub fn may_invite(
  open: fn() -> Result(Int, Nil),
  principal: access.Principal,
  address: Result(String, Nil),
) -> Result(String, invites.Reason) {
  use _ <- result.try(open() |> result.replace_error(invites.NotOwner))
  use _ <- result.try(owner_principal(principal))
  address |> result.replace_error(invites.Unavailable)
}

// Only the daemon's owner invites. A member operator's page is refused here
// even if a message reached it.
fn owner_principal(principal: access.Principal) -> Result(Nil, invites.Reason) {
  case principal.kind {
    access.OwnerPrincipal -> Ok(Nil)
    access.MemberPrincipal -> Error(invites.NotOwner)
  }
}

// Why an invitation was not made, in the daemon's own terms: the manager's
// refusal, or that no claim could be drawn.
type Refusal {
  Managed(error: manager.AdminError)
  Undrawn
}

// The session page's invitation: the page's own session, the daemon's default
// name.
fn invited(
  attachment: server.Attachment(instance),
  address: String,
  chosen: invites.Role,
) -> Result(invites.Invitation, Refusal) {
  invitation(
    attachment.registry,
    attachment.digest,
    attachment.epoch,
    attachment.session_id,
    address,
    chosen,
    None,
  )
}

// The dispatch both invitations share, the session page's and the admin page's,
// so a claim and its principal are made one way whichever asked. The claim is
// drawn here and handed to the registry as a digest, and the token comes back
// only in the invitation the caller shows. `named` is the inviter's suggested
// name, which the caller has already judged, or none for the daemon's own.
fn invitation(
  registry: manager.Manager(instance),
  digest: access.Digest,
  epoch: String,
  session: String,
  address: String,
  chosen: invites.Role,
  named: Option(String),
) -> Result(invites.Invitation, Refusal) {
  use #(enrollment, claim_token) <- result.try(
    server.claim_enrollment(invites.claim_ttl_ms)
    |> result.replace_error(Undrawn),
  )
  let id =
    "guest-"
    <> {
      token.production_entropy()(4)
      |> bit_array.base16_encode
      |> string.lowercase
    }
  let member = case chosen {
    invites.Observer -> access.Observer
    invites.Operator -> access.Operator
  }
  let name = option.unwrap(named, "Guest " <> string.drop_start(id, 6))
  use principal <- result.map(
    manager.administer(
      registry,
      digest,
      epoch,
      manager.Invite(id, name, enrollment, session, member),
    )
    |> result.map_error(Managed),
  )
  invites.Invitation(
    principal: principal.id,
    role: chosen,
    page: browser_claim_address(address),
    command: "loom claim --addr " <> address,
    token: claim_token,
    expires_in_ms: invites.claim_ttl_ms,
  )
}

// A refusal that made nothing gives the invitation back. The registry not
// answering leaves an unknown outcome, in which a principal may exist, so that
// one stays counted.
fn give_back(
  tickets: ui_sessions.Sessions,
  credential: access.Digest,
  refusal: Refusal,
) -> Nil {
  case refusal {
    Managed(manager.AdminUnavailable) -> Nil
    Managed(manager.IsolationRequired)
    | Managed(manager.AdminForbidden)
    | Managed(manager.AdminStaleEpoch)
    | Managed(manager.AdminBusy)
    | Managed(manager.AdminForeignPath)
    | Managed(manager.AdminMetadata(..))
    | Undrawn -> ui_sessions.release_invite(tickets, credential)
  }
}

// The fixed reason a page words for a refusal. A stale epoch, a busy session
// and a metadata refusal are the daemon's to sort out and read alike.
fn reason_of(refusal: Refusal) -> invites.Reason {
  case refusal {
    Managed(manager.IsolationRequired) -> invites.NotIsolated
    Managed(manager.AdminForbidden) -> invites.NotOwner
    Managed(manager.AdminStaleEpoch)
    | Managed(manager.AdminUnavailable)
    | Managed(manager.AdminBusy)
    | Managed(manager.AdminForeignPath)
    | Managed(manager.AdminMetadata(..))
    | Undrawn -> invites.Unavailable
  }
}

/// The capability to rename the page's session that a page of `role` is
/// handed: `ask` for an owner's page and none for any other, which is the whole
/// of who may draw and use the rename control (protocol-change/067).
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.rename_capability(ui_socket.Operating, ask) == None
/// ```
@internal
pub fn rename_capability(
  role: Role,
  ask: fn(String, fn(renames.Answer) -> Nil) -> Nil,
) -> Option(fn(String, fn(renames.Answer) -> Nil) -> Nil) {
  case role {
    Owning -> Some(ask)
    Observing | Operating -> None
  }
}

/// Renames `target` to `name` for the asking page's principal, or gives the
/// reason it did not (protocol-change/067). A page's own session is the one it
/// names, and the daemon reads it from the attachment and never from a frame.
///
/// Every step is the daemon's and is made afresh, with the digest of the
/// credential the page was admitted under, and nothing is taken from the page
/// but the text of the name:
///
/// 0. The asking page must still be open (`open`), as for every other action the
///    page takes. A page that ended but whose socket is still up renames
///    nothing (`NotOwner`).
/// 1. The page must have been minted to operate. An observer-ceiling page is
///    refused, whatever its principal is.
/// 2. The credential must still authenticate, and as the principal the page was
///    admitted for, and that principal must be the daemon's owner. The page's
///    own role is not read: the rename control's presence says nothing here.
/// 3. `target` must be a canonical session identity, which a forged or
///    malformed one is not (`NotOwner`, the words for every standing the page
///    cannot claim).
/// 4. The name, trimmed, must pass `catalogue.display_name`: nonblank, at most
///    256 bytes, no control, zero-width or direction-changing character
///    (`InvalidName`).
/// 5. `manager.rename` is the registry turn the control command's
///    `sessions.rename` runs: it authenticates the credential and the epoch a
///    second time, needs the owner, and writes the name and the catalogue
///    revision together. An identity the catalogue does not hold is refused
///    there (`NotOwner`), as is a stale epoch or a member.
///
/// The name an answer carries is the one the catalogue now holds. The detail of
/// any other refusal stays in the daemon.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.rename_for(standing, open, epoch, session_id, "review auth")
/// ```
@internal
pub fn rename_for(
  standing: Standing(instance),
  open: fn() -> Result(Int, Nil),
  epoch: String,
  target: String,
  name: String,
) -> renames.Answer {
  let outcome = {
    use _ <- result.try(open() |> result.replace_error(renames.NotOwner))
    use _ <- result.try(
      operating_ceiling(standing.ceiling)
      |> result.replace_error(renames.NotOwner),
    )
    use principal <- result.try(
      manager.authenticate(standing.registry, standing.digest)
      |> result.replace_error(renames.NotOwner),
    )
    use _ <- result.try(
      case principal.id == standing.principal, principal.kind {
        True, access.OwnerPrincipal -> Ok(Nil)
        True, access.MemberPrincipal | False, _ -> Error(renames.NotOwner)
      },
    )
    use _ <- result.try(
      ids.parse_session_id(target) |> result.replace_error(renames.NotOwner),
    )
    let name = string.trim(name)
    use _ <- result.try(
      catalogue.display_name(name) |> result.replace_error(renames.InvalidName),
    )
    use view <- result.map(
      manager.rename(standing.registry, standing.digest, epoch, target, name)
      |> result.map_error(rename_refusal),
    )
    view.registration.name
  }
  case outcome {
    Ok(stored) -> renames.Renamed(stored)
    Error(reason) -> renames.Declined(reason)
  }
}

// The fixed reason for a refusal of the registry's rename. A principal that is
// not the owner, a stale epoch and a session the catalogue does not hold read
// alike, so a page learns nothing about which; a name the catalogue itself
// refused is a bad name, and anything else is the daemon's to sort out.
fn rename_refusal(error: manager.AdminError) -> renames.Reason {
  case error {
    manager.AdminForbidden
    | manager.AdminStaleEpoch
    | manager.AdminMetadata(catalogue.Missing) -> renames.NotOwner
    manager.AdminMetadata(catalogue.Invalid(_)) -> renames.InvalidName
    manager.AdminMetadata(catalogue.Unsupported)
    | manager.AdminMetadata(catalogue.Conflict)
    | manager.AdminMetadata(catalogue.Database(_))
    | manager.IsolationRequired
    | manager.AdminUnavailable
    | manager.AdminBusy
    | manager.AdminForeignPath -> renames.Unavailable
  }
}

/// Starts `rename_for` in a run of its own and returns at once, so the page's
/// runtime is free while the registry answers; `deliver` is called, from that
/// run, with the answer, whatever it is.
///
/// The run is a weft run with one task, linked to the calling process, which is
/// the page's runtime, as `resume_task`'s is: a page that goes away cancels it,
/// and a rename the registry has already begun finishes on the registry's own
/// turn. Every step of `rename_for` is bounded by its own call timeouts, so the
/// task always answers within seconds and needs no deadline of its own. Its last
/// act is `deliver`, so a page that stays open is always answered.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.rename_task(standing, open, epoch, session_id, "review auth", deliver)
/// ```
@internal
pub fn rename_task(
  standing: Standing(instance),
  open: fn() -> Result(Int, Nil),
  epoch: String,
  target: String,
  name: String,
  deliver: fn(renames.Answer) -> Nil,
) -> Nil {
  let _ =
    weft.new([
      fn() {
        deliver(rename_for(standing, open, epoch, target, name))
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  Nil
}

/// How long a stop waits for the session to leave the registry before it
/// answers, in milliseconds. The registry begins a stop without waiting for the
/// drain, so the answer would otherwise come before the session is saved and the
/// page's next read would still list it running. A drain that takes longer is
/// not a failure: the stop has begun, the session leaves at its own pace, and
/// the page's own timer reads it as saved.
const stop_wait_ms = 5000

/// Stops, archives or deletes `target` for the asking home's owner, or gives the
/// reason it did not (protocol-change/065, the addendum on session actions). The
/// session is named by the page's row and the daemon decides everything else,
/// each step made afresh with the digest of the credential the page was
/// admitted under:
///
/// 0. The home must have been opened by a fresh `loom ui` exchange
///    (`fresh_home`), and must still be open and minted to operate, with a
///    credential that still authenticates as the daemon's owner
///    (`owner_operating`). One refusal, `NotOwner`, for each, so a page learns
///    nothing about which.
/// 1. `target` must be a canonical session identity.
/// 2. A stop is `manager.stop_session`, which the control command's
///    `sessions.stop` runs after its own owner check, and then waits for the
///    registry to report the session saved (`stop_wait_ms`). An archive is
///    `manager.set_visibility` and a delete is `manager.delete_session`, which
///    authenticate the credential and the epoch a second time in the registry's
///    own turn, need the owner, and refuse a session a process still holds
///    (`Running`). The page offers neither on a running row, and the registry
///    does not rely on that.
///
/// The detail of every other refusal stays in the daemon.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.manage_for(standing, open, epoch, sessions, actions.Archive, session_id)
/// ```
@internal
pub fn manage_for(
  standing: Standing(instance),
  open: fn() -> Result(Int, Nil),
  epoch: String,
  sessions_directory: String,
  action: actions.Action,
  target: String,
) -> actions.Answer {
  let outcome = {
    use _ <- result.try(
      fresh_home(standing.reach, standing.origin)
      |> result.replace_error(actions.NotOwner),
    )
    use _ <- result.try(
      owner_operating(standing, open) |> result.replace_error(actions.NotOwner),
    )
    use _ <- result.try(
      ids.parse_session_id(target) |> result.replace_error(actions.NotOwner),
    )
    case action {
      actions.Stop -> stop_for(standing.registry, target)
      actions.Archive ->
        manager.set_visibility(
          standing.registry,
          standing.digest,
          epoch,
          target,
          catalogue.Archived,
        )
        |> result.replace(Nil)
        |> result.map_error(action_refusal)
      actions.Delete ->
        manager.delete_session(
          standing.registry,
          standing.digest,
          epoch,
          target,
          sessions_directory,
        )
        |> result.replace(Nil)
        |> result.map_error(action_refusal)
    }
  }
  case outcome {
    Ok(Nil) -> actions.Done(action)
    Error(reason) -> actions.Declined(reason)
  }
}

// Begins the stop and waits, within `stop_wait_ms`, for the registry to report
// the session saved. A drain that outlasts the wait is still a stop that was
// made. A session the registry holds as recovering is not one a stop can end.
fn stop_for(
  registry: manager.Manager(instance),
  target: String,
) -> Result(Nil, actions.Reason) {
  use status <- result.try(
    manager.stop_session(registry, target)
    |> result.map_error(fn(error) {
      case error {
        manager.Catalogue(catalogue.Missing) -> actions.NotOwner
        manager.Catalogue(_)
        | manager.NotInitialized
        | manager.SessionArchived
        | manager.Capacity
        | manager.Unavailable
        | manager.StaleOperation
        | manager.StartFailed(_)
        | manager.Preparation(_) -> actions.Unavailable
      }
    }),
  )
  case status {
    manager.Saved | manager.Reserved -> Ok(Nil)
    manager.Stopping(_) ->
      case drained(registry, target) {
        poll.Failed(reason) -> Error(reason)
        poll.Answered(Nil) | poll.Expired -> Ok(Nil)
      }
    manager.Resident(_) | manager.Opening(_) | manager.RecoveryBlocked(_) ->
      Error(actions.Unavailable)
  }
}

// Looks at the session until the registry holds nothing for it.
fn drained(
  registry: manager.Manager(instance),
  target: String,
) -> poll.Outcome(Nil, actions.Reason) {
  poll.until(within: stop_wait_ms, every: 100, attempt: fn() {
    case manager.get(registry, target) {
      Error(_) -> poll.Fail(actions.Unavailable)
      Ok(view) ->
        case view.status {
          manager.Saved | manager.Reserved -> poll.Done(Nil)
          manager.Stopping(_) | manager.Resident(_) | manager.Opening(_) ->
            poll.Retry
          manager.RecoveryBlocked(_) -> poll.Fail(actions.Unavailable)
        }
    }
  })
}

// The fixed reason for a refusal of the registry's archive or delete. A
// principal that is not the owner, a stale epoch and a session the catalogue
// does not hold read alike, so a page learns nothing about which; a session a
// process holds is the one reason a person can act on.
fn action_refusal(error: manager.AdminError) -> actions.Reason {
  case error {
    manager.AdminForbidden
    | manager.AdminStaleEpoch
    | manager.AdminMetadata(catalogue.Missing) -> actions.NotOwner
    manager.AdminBusy -> actions.Running
    manager.AdminMetadata(catalogue.Invalid(_))
    | manager.AdminMetadata(catalogue.Unsupported)
    | manager.AdminMetadata(catalogue.Conflict)
    | manager.AdminMetadata(catalogue.Database(_))
    | manager.IsolationRequired
    | manager.AdminUnavailable
    | manager.AdminForeignPath -> actions.Unavailable
  }
}

/// Starts `manage_for` in a run of its own and returns at once, so the page's
/// runtime is free while the registry answers, and a stop is free to wait for a
/// drain; `deliver` is called, from that run, with the answer, whatever it is.
///
/// The run is a weft run with one task, linked to the calling process, which is
/// the page's runtime, as `rename_task`'s is: a page that goes away cancels it,
/// and a change the registry has already begun finishes on the registry's own
/// turn. Every step is bounded by its own call timeouts and the stop's wait is
/// bounded by `stop_wait_ms`, so the task always answers within seconds and needs
/// no deadline of its own. Its last act is `deliver`.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.manage_task(standing, open, epoch, sessions, actions.Stop, session_id, deliver)
/// ```
@internal
pub fn manage_task(
  standing: Standing(instance),
  open: fn() -> Result(Int, Nil),
  epoch: String,
  sessions_directory: String,
  action: actions.Action,
  target: String,
  deliver: fn(actions.Answer) -> Nil,
) -> Nil {
  let _ =
    weft.new([
      fn() {
        deliver(manage_for(
          standing,
          open,
          epoch,
          sessions_directory,
          action,
          target,
        ))
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  Nil
}

/// The capability to rename the page's own principal that a home page minted
/// with `ceiling` is handed: `ask` on a page minted to operate, whoever its
/// principal is, and none on a read-only link (protocol-change/065, the tenth
/// pull request). A member renames itself and the owner renames itself, so the
/// principal does not decide it. The daemon checks the ceiling and the credential
/// again when the request runs (`rename_self_for`).
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.home_rename_self_capability(access.Observer, ask) == None
/// ```
@internal
pub fn home_rename_self_capability(
  ceiling: access.Role,
  ask: fn(String, fn(names.Answer) -> Nil) -> Nil,
) -> Option(fn(String, fn(names.Answer) -> Nil) -> Nil) {
  case ceiling {
    access.Operator -> Some(ask)
    access.Observer -> None
  }
}

/// The page's principal's display name as the catalogue holds it now, read with
/// the page's own credential, or `None` when the page has ended or the registry
/// did not answer. The registry authenticates the credential again, so a page
/// whose credential was revoked reads nothing; the sessions read is what ends it.
/// The home asks with every list, so a name the owner changed from the admin page
/// reaches an open home at its next read.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.name_read(standing, open)
/// ```
@internal
pub fn name_read(
  standing: Standing(instance),
  open: fn() -> Result(Int, Nil),
) -> Option(String) {
  case open() {
    Error(Nil) -> None
    Ok(_) ->
      case manager.authenticate(standing.registry, standing.digest) {
        Ok(principal) if principal.id == standing.principal ->
          Some(principal.display_name)
        Ok(_) | Error(_) -> None
      }
  }
}

/// Renames the asking page's own principal to `name`, or gives the reason it did
/// not (protocol-change/065, the tenth pull request). The page sends the text of
/// the name and nothing else: whose name it is, is the page's principal, which
/// the daemon reads from the grant it holds and never from a frame.
///
/// Every step is the daemon's and is made afresh, with the digest of the
/// credential the page was admitted under:
///
/// 0. The asking page must still be open (`open`). A page that ended but whose
///    socket is still up renames nothing (`NotAllowed`).
/// 1. The page must have been minted to operate. A read-only page is refused,
///    whoever its principal is.
/// 2. `manager.rename_principal` is the registry turn the control command's
///    `principals.rename` runs, with no principal named: it authenticates the
///    credential and the epoch in the same dispatch as the write, so a revoked
///    credential and a stale epoch are `NotAllowed`, and the credential's own
///    principal is the one renamed. The credential must also still authenticate
///    as the principal the page was admitted for.
/// 3. The name is trimmed and judged there by the rule a claim's chosen name is
///    held to (`storage/access.rename`): nonblank, at most 256 bytes, no control,
///    zero-width or direction-changing character (`InvalidName`).
///
/// The name an answer carries is the one the catalogue now holds. An origin
/// already admitted keeps the name it was admitted under.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.rename_self_for(standing, open, epoch, "Alex")
/// ```
@internal
pub fn rename_self_for(
  standing: Standing(instance),
  open: fn() -> Result(Int, Nil),
  epoch: String,
  name: String,
) -> names.Answer {
  let outcome = {
    use _ <- result.try(open() |> result.replace_error(names.NotAllowed))
    use _ <- result.try(
      operating_ceiling(standing.ceiling)
      |> result.replace_error(names.NotAllowed),
    )
    use principal <- result.try(
      manager.authenticate(standing.registry, standing.digest)
      |> result.replace_error(names.NotAllowed),
    )
    use _ <- result.try(case principal.id == standing.principal {
      True -> Ok(Nil)
      False -> Error(names.NotAllowed)
    })
    use renamed <- result.map(
      manager.rename_principal(
        standing.registry,
        standing.digest,
        epoch,
        None,
        name,
      )
      |> result.map_error(name_refusal),
    )
    renamed.display_name
  }
  case outcome {
    Ok(stored) -> names.Renamed(stored)
    Error(reason) -> names.Declined(reason)
  }
}

// The fixed reason for a refusal of the registry's rename of a principal. A
// credential that no longer authenticates, a stale epoch, a principal the
// catalogue does not hold and a member naming another read alike, so a page
// learns nothing about which; a name the catalogue itself refused is a bad name,
// and anything else is the daemon's to sort out.
fn name_refusal(error: manager.AdminError) -> names.Reason {
  case error {
    manager.AdminForbidden
    | manager.AdminStaleEpoch
    | manager.AdminMetadata(catalogue.Missing) -> names.NotAllowed
    manager.AdminMetadata(catalogue.Invalid(_)) -> names.InvalidName
    manager.AdminMetadata(catalogue.Unsupported)
    | manager.AdminMetadata(catalogue.Conflict)
    | manager.AdminMetadata(catalogue.Database(_))
    | manager.IsolationRequired
    | manager.AdminUnavailable
    | manager.AdminBusy
    | manager.AdminForeignPath -> names.Unavailable
  }
}

/// Starts `rename_self_for` in a run of its own and returns at once, so the
/// page's runtime is free while the registry answers; `deliver` is called, from
/// that run, with the answer, whatever it is.
///
/// The run is a weft run with one task, linked to the calling process, which is
/// the page's runtime, as `rename_task`'s is: a page that goes away cancels it,
/// and a rename the registry has already begun finishes on the registry's own
/// turn. Every step of `rename_self_for` is bounded by its own call timeouts, so
/// the task always answers within seconds and needs no deadline of its own. Its
/// last act is `deliver`, so a page that stays open is always answered.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.rename_self_task(standing, open, epoch, "Alex", deliver)
/// ```
@internal
pub fn rename_self_task(
  standing: Standing(instance),
  open: fn() -> Result(Int, Nil),
  epoch: String,
  name: String,
  deliver: fn(names.Answer) -> Nil,
) -> Nil {
  let _ =
    weft.new([
      fn() {
        deliver(rename_self_for(standing, open, epoch, name))
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  Nil
}

/// The capability to open the admin page that a home page minted for
/// `principal` with `ceiling` and `reach` is handed: `ask` for the daemon's
/// owner on a page minted to operate and opened by a fresh `loom ui` exchange,
/// and none for any other (protocol-change/065, the fifth pull request). The
/// daemon checks all of it again when the request runs (`admin_ticket_for`).
///
/// The origin rule is `fresh_home` and nothing else reads it, so a home the
/// bookmark resumed is refused in one place.
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.home_admin_capability(member, access.Operator, ui_sessions.Workspace, ui_sessions.Fresh, ask) == None
/// ```
@internal
pub fn home_admin_capability(
  principal: access.Principal,
  ceiling: access.Role,
  reach: ui_sessions.Reach,
  origin: ui_sessions.Origin,
  ask: fn(fn(sessions.Answer) -> Nil) -> Nil,
) -> Option(fn(fn(sessions.Answer) -> Nil) -> Nil) {
  case principal.kind, ceiling, fresh_home(reach, origin) {
    access.OwnerPrincipal, access.Operator, Ok(Nil) -> Some(ask)
    access.OwnerPrincipal, access.Operator, Error(Nil)
    | access.OwnerPrincipal, access.Observer, _
    | access.MemberPrincipal, access.Operator, _
    | access.MemberPrincipal, access.Observer, _
    -> None
  }
}

/// Whether a home page was opened by a fresh `loom ui` exchange, which is the
/// only home an admin page may be opened from (protocol-change/065, the fifth
/// pull request; the design note's section 4.3, ruled by the owner on
/// 2026-10-04). It is the one place the rule is judged: the capability and the
/// ticket both ask it.
///
/// A fresh step is what bounds the admin page's fifteen minutes. A page that a
/// bookmark could mint again would bound nothing against a stolen login, so the
/// owner runs `loom ui` on the day they administer. A home is fresh when it is
/// a home (the `Workspace` reach) and a `loom ui` exchange or a device link
/// opened it, not the bookmark's resume (`Origin`, protocol-change/065, the
/// eighth pull request). The origin travels on every ticket a page mints, so a
/// chain that began at a resumed home is never fresh.
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.fresh_home(ui_sessions.Workspace, ui_sessions.Fresh) == Ok(Nil)
/// ```
@internal
pub fn fresh_home(
  reach: ui_sessions.Reach,
  origin: ui_sessions.Origin,
) -> Result(Nil, Nil) {
  case reach, origin {
    ui_sessions.Workspace, ui_sessions.Fresh -> Ok(Nil)
    ui_sessions.Workspace, ui_sessions.Resumed | ui_sessions.OneSession, _ ->
      Error(Nil)
  }
}

/// A ticket for an admin page of the asking home's owner, or the reason there is
/// none (protocol-change/065, the fifth pull request).
///
/// Each step is the daemon's own and is made afresh, with the digest of the
/// credential the page was admitted under, and none is taken from the page:
///
/// 0. The asking home must still be open: `open` answers its deadline while its
///    UI session is live and unreplaced. The deadline goes on the ticket
///    (`ui_sessions.mint_before`), so the admin page ends at the earlier of this
///    home's end and fifteen minutes from its own exchange, and a chain home,
///    admin, never outlives the home it began from.
/// 1. The home must have been minted to operate, and must be a fresh one
///    (`fresh_home`).
/// 2. The credential must still authenticate, as the principal the home was
///    admitted for, and that principal must be the daemon's owner.
/// 3. The ticket carries the home's own credential, principal and ceiling, so an
///    admin page can do no more than the home that asked. Its reach is
///    `Workspace`, and a ticket redeems only at the admin exchange.
///
/// Every refusal is `NoAdmin`, whose words do not say which step failed.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.admin_ticket_for(standing, tickets, open)
/// ```
@internal
pub fn admin_ticket_for(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
) -> sessions.Answer {
  let outcome = {
    use _ <- result.try(
      fresh_home(standing.reach, standing.origin)
      |> result.replace_error(sessions.NoAdmin),
    )
    use until <- result.try(
      owner_operating(standing, open) |> result.replace_error(sessions.NoAdmin),
    )
    ui_sessions.mint_in(
      tickets,
      ui_sessions.Grant(
        scope: ui_sessions.Admin,
        credential: standing.digest,
        principal: standing.principal,
        ceiling: standing.ceiling,
        reach: ui_sessions.Workspace,
        origin: ui_sessions.Fresh,
        remember: ui_sessions.Forgotten,
      ),
      until,
      standing.login,
    )
    |> result.replace_error(sessions.NoAdmin)
  }
  case outcome {
    Ok(issued) -> sessions.Ticketed(page.admin_exchange_path(issued.ticket))
    Error(reason) -> sessions.Declined(reason)
  }
}

// The steps an admin ticket and every admin change begin with: the asking page
// is open (its deadline is the answer), was minted to operate, and its credential
// still authenticates as the principal it was admitted for, who is the daemon's
// owner. A member's page is refused here even if a message reached it.
fn owner_operating(
  standing: Standing(instance),
  open: fn() -> Result(Int, Nil),
) -> Result(Int, Nil) {
  use until <- result.try(open())
  use _ <- result.try(
    operating_ceiling(standing.ceiling) |> result.replace_error(Nil),
  )
  use principal <- result.try(
    manager.authenticate(standing.registry, standing.digest)
    |> result.replace_error(Nil),
  )
  case principal.id == standing.principal, principal.kind {
    True, access.OwnerPrincipal -> Ok(until)
    True, access.MemberPrincipal | False, _ -> Error(Nil)
  }
}

/// Starts `admin_ticket_for` in a run of its own and returns at once, so the
/// page's runtime is free while the registry authenticates; `deliver` is
/// called, from that run, with the answer, whatever it is.
///
/// The run is a weft run with one task, linked to the calling process, which is
/// the page's runtime, as `resume_task`'s is: a page that goes away cancels it.
/// Every step of `admin_ticket_for` is bounded by its own call timeouts, so the
/// task always answers within seconds and needs no deadline of its own. Its last
/// act is `deliver`, so a page that stays open is always answered.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.admin_ticket_task(standing, tickets, open, deliver)
/// ```
@internal
pub fn admin_ticket_task(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  deliver: fn(sessions.Answer) -> Nil,
) -> Nil {
  let _ =
    weft.new([
      fn() {
        deliver(admin_ticket_for(standing, tickets, open))
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  Nil
}

/// Upgrades one checked admin request to the admin component's socket
/// (protocol-change/065, the fifth pull request).
///
/// The admin page is bound to no session, so there is no relay, no lane and no
/// gateway: the socket starts `web_view/admin`, which asks the daemon for the
/// catalogue when it opens and on a timer, and for the owner's changes when a
/// button is pressed, each in a task of its own. The permit is an observer's,
/// whose frame limit is the one this socket takes: the page sends clicks and one
/// small form, and `admin_accepts` admits nothing else.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.upgrade_admin(root, request, attachment, tickets, open, access.Operator)
/// ```
pub fn upgrade_admin(
  daemon: root.Root(instance),
  request: Request(mist.Connection),
  attachment: server.AdminAttachment(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  ceiling: access.Role,
) -> Response(mist.ResponseData) {
  let settled = process.new_subject()
  let limit = root.message_limit(root.Observer)
  let standing = admin_standing(attachment, ceiling)

  // The address a claim's command names is the one the page was reached at, as
  // the session page's invitation makes it.
  let address = claim_address(request)
  websocket(request, limit, settled, fn(signals) {
    admit_admin(
      daemon,
      attachment,
      standing,
      tickets,
      open,
      address,
      signals,
      settled,
    )
  })
}

/// The browser messages an admin page takes: Lustre's `EventFired` for a `click`
/// or a `submit`, alone or batched, at a path beneath `admin.body_path`, where
/// every control of the page is, and nothing else. Every other frame is dropped
/// before it costs the component a render, a batch with one of them included.
///
/// Each handler names the principal or the session the server drew, and the
/// invitation form's fields are judged by the page's own decoder, so the frame
/// chooses only among the controls that were drawn. The path and the separator
/// are exact, so a path that merely begins with the same digits is not admitted,
/// and the top bar, which holds no handler on this page, is not either. The daemon
/// checks the page, the credential and the owner again for every change
/// (`admin_for`), whatever frame reached it.
///
/// ## Examples
///
/// ```gleam
/// assert !ui_socket.admin_accepts("{\"kind\":1,\"name\":\"click\",\"path\":\"0\\t0\\t5\"}")
/// ```
pub fn admin_accepts(frame: String) -> Bool {
  case json.parse(frame, admin_event()) {
    Ok(accepted) -> accepted
    Error(_) -> False
  }
}

fn admin_event() -> decode.Decoder(Bool) {
  use kind <- decode.field("kind", decode.int)
  case kind {
    1 -> {
      use name <- decode.field("name", decode.string)
      use path <- decode.field("path", decode.string)
      decode.success(
        { name == "click" || name == "submit" }
        && string.starts_with(path, admin.body_path <> "\t"),
      )
    }
    3 -> {
      use messages <- decode.field(
        "messages",
        decode.list(decode.recursive(fn() { admin_event() })),
      )
      decode.success(messages != [] && list.all(messages, fn(ok) { ok }))
    }
    _ -> decode.success(False)
  }
}

// What an admin page asks the daemon with: the registry, the credential it was
// admitted under, its principal and the ceiling it was minted with. Its reach is
// `Workspace` and its origin `Fresh`, which only the tickets a page mints read,
// and the admin page mints none; the login it was opened from is the one its
// sign-in rows mark as this browser.
//
// `Fresh` is written here and not read from the page, and that is sound only
// because `admin_ticket_for` mints an admin ticket from nothing but a `Fresh`
// home (`fresh_home`), and the admin socket mints no tickets of any scope. If an
// admin page ever minted one, its origin would have to travel on the grant as
// the home's does.
fn admin_standing(
  attachment: server.AdminAttachment(instance),
  ceiling: access.Role,
) -> Standing(instance) {
  Standing(
    registry: attachment.registry,
    digest: attachment.digest,
    principal: attachment.principal.id,
    ceiling:,
    reach: ui_sessions.Workspace,
    origin: ui_sessions.Fresh,
    login: attachment.login,
  )
}

// Takes the permit in the socket's first handler turn, as `admit_home` does, and
// then starts the admin component with its two requests as closures over the
// attachment: each starts the daemon's task and returns at once.
fn admit_admin(
  daemon: root.Root(instance),
  attachment: server.AdminAttachment(instance),
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  address: Result(String, Nil),
  signals: process.Subject(Signal),
  settled: process.Subject(Nil),
) -> mist.Next(Phase, Signal) {
  let transferred = root.transfer(daemon, attachment.permit, within: 1000)
  process.send(settled, Nil)

  // A change needs only the epoch of the attachment, since the registry and the
  // credential it asks with are the standing's, so its closure keeps that.
  let epoch = attachment.epoch

  // The page's end, read once as the page opens: the live UI session's deadline,
  // which already is the earlier of the home's end and fifteen minutes from the
  // exchange (`ui_sessions.mint_before`). The table answers it on its own
  // monotonic clock, whose zero is arbitrary, so it is carried to the wall clock
  // the page's reads are counted in as how far it is from the monotonic clock
  // now, added to the wall clock now (`ui_sessions` does the same for an
  // allowance). That is correct because `daemon/main` injects the same
  // `bootstrap.monotonic_time_ms` as the table's `now`, and the arithmetic is
  // `ui_sessions.frees_at`'s. A page that is not open at this instant has no deadline to show,
  // and its first read ends it.
  let wall = bootstrap.system_time_ms()
  let ends_at = case open() {
    Ok(until) -> wall + { until - bootstrap.monotonic_time_ms() }
    Error(Nil) -> wall
  }
  let start =
    admin.Start(
      name: attachment.principal.display_name,
      refresh_ms: admin.refresh_ms,
      read: fn(chosen, deliver) {
        admin_read_task(attachment, open, chosen, deliver, fn(reason) {
          process.send(signals, Ended(reason))
        })
      },
      act: fn(action, deliver) {
        admin_task(standing, tickets, open, epoch, address, action, deliver)
      },
      now: bootstrap.system_time_ms,
      login: option.map(attachment.login, fn(issuer) { issuer.fingerprint }),
      ends_at:,
    )
  let started = case transferred {
    Error(reason) -> {
      upgrade_log.closed_early(upgrade_log.Page, "transfer", reason)
      Error(Nil)
    }
    Ok(Nil) ->
      launch(admin.app(), start, admin_accepts)
      |> result.map_error(fn(_) {
        upgrade_log.closed_early(
          upgrade_log.Page,
          "start_page",
          "the component did not start",
        )
      })
  }
  case started {
    // The permit transfer was slow or the component's start ran over its
    // budget: the close is one the client runtime retries.
    Error(Nil) -> closing(ending.close(ending.DaemonNotReady))
    Ok(#(_, page)) -> serving(page, signals)
  }
}

/// What the admin page reads of the catalogue, as the page's principal with the
/// digest of the credential the page was admitted under: who exists and what
/// each can authenticate with, the owner's sessions, and, when the owner has
/// chosen one, that session's members. Every row is a catalogue field. A claim
/// is not among them, because the catalogue holds only its digest.
///
/// The read is the page's frame check as well, as the home's is. A page whose UI
/// session has ended, or whose credential no longer authenticates as the owner,
/// is not read anything: the answer is `Closed`, and `ended` tells the socket,
/// which closes after the component has drawn why. A registry that does not
/// answer is `Unread`, which keeps the page's last snapshot and ends nothing,
/// since a slow registry is no reason to sign the owner out.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.admin_reading(attachment, open, None, ended)
/// ```
@internal
pub fn admin_reading(
  attachment: server.AdminAttachment(instance),
  open: fn() -> Result(Int, Nil),
  chosen: Option(String),
  ended: fn(ending.Ending) -> Nil,
) -> grants.Reading {
  case admin_snapshot(attachment, open, chosen) {
    Ok(snapshot) -> grants.Read(snapshot)
    Error(Unreadable) -> grants.Unread
    Error(Gone(reason)) -> {
      ended(reason)
      grants.Closed(reason)
    }
  }
}

// The three reads of a snapshot, each made afresh: the page is live, the
// principals with their credential state, the owner's sessions, and the chosen
// session's members. A credential that no longer authenticates as the owner is
// the registry's own refusal on the first read.
fn admin_snapshot(
  attachment: server.AdminAttachment(instance),
  open: fn() -> Result(Int, Nil),
  chosen: Option(String),
) -> Result(grants.Snapshot, Failure) {
  use _ <- result.try(open() |> result.replace_error(Gone(ending.PageEnded)))
  use people <- result.try(
    manager.principal_page(
      attachment.registry,
      attachment.digest,
      after: "",
      now_ms: bootstrap.system_time_ms(),
    )
    |> result.map_error(admin_failure),
  )
  use #(_, views) <- result.try(
    manager.authorized_page(attachment.registry, attachment.digest, after: "")
    |> result.map_error(authentication_failure),
  )
  use selection <- result.try(chosen_members(attachment, chosen))
  use logins <- result.try(admin_logins(attachment, people.entries))
  let listed = list.take(views, sessions.listed_limit)
  use summaries <- result.map(admin_summaries(attachment, listed))
  grants.Snapshot(
    principals: owner_first(list.map(people.entries, listed_principal)),
    more_principals: more_of(people.remainder),
    sessions: list.map(listed, listed_entry),
    selection:,
    logins:,
    summaries:,
  )
}

// The most principals whose sign-ins one read lists. A principal beyond them
// still shows its count, and the terminal's `loom access signins` lists any.
const admin_logins_principals = 20

// The sign-ins of each principal that holds any, the first few of at most
// `admin_logins_principals` of them, each read as the page's owner with the
// registry's own `signins` (which authenticates the credential and names the
// principal again). A principal whose read fails fails the snapshot: the
// registry's refusal ends the page or leaves the last snapshot, as `admin_failure`
// words it, and no principal is shown without its rows.
fn admin_logins(
  attachment: server.AdminAttachment(instance),
  rows: List(access.Listing),
) -> Result(List(grants.Logins), Failure) {
  list.filter(rows, fn(row) { row.logins > 0 })
  |> list.take(admin_logins_principals)
  |> list.try_map(fn(row) {
    case
      manager.signins(
        attachment.registry,
        attachment.digest,
        Some(row.principal.id),
        after: "",
        now_ms: bootstrap.system_time_ms(),
      )
    {
      Ok(#(_, page)) ->
        Ok(grants.Logins(
          principal: row.principal.id,
          count: row.logins,
          shown: list.map(
            list.take(page.entries, grants.signins_shown),
            listed_signin,
          ),
        ))
      Error(error) -> Error(admin_failure(error))
    }
  })
}

// One summary for each listed session: how many people hold it and whether it
// may be shared, read with the same registry call that reads the chosen
// session's members, as the page's owner (protocol-change/065, the addendum on
// the admin page's session rows). A session the catalogue no longer holds when
// the read reaches it is left out, so its row has no line; any other failure
// of the registry is the registry failing to answer, as it is for the chosen
// session. The count is the owner and the members one page lists, with the page
// saying whether that is all of them.
fn admin_summaries(
  attachment: server.AdminAttachment(instance),
  views: List(manager.View),
) -> Result(List(grants.Summary), Failure) {
  list.try_fold(views, [], fn(kept, view) {
    let session = view.registration.id
    case
      manager.session_member_page(
        attachment.registry,
        attachment.digest,
        session,
        after: "",
      )
    {
      Ok(members) -> {
        let selected = selection_of(session, members)
        Ok([
          grants.Summary(
            session:,
            people: 1 + list.length(selected.holders),
            more: selected.more,
            scope: selected.scope,
          ),
          ..kept
        ])
      }
      Error(manager.AdminMetadata(catalogue.Missing)) -> Ok(kept)
      Error(error) -> Error(admin_failure(error))
    }
  })
}

// The chosen session's members, or none when no session is chosen or the
// catalogue holds none by that identity. A chosen identity that is not a session
// identity is none too: a page only ever chooses one it drew.
fn chosen_members(
  attachment: server.AdminAttachment(instance),
  chosen: Option(String),
) -> Result(Option(grants.Selection), Failure) {
  case chosen {
    None -> Ok(None)
    Some(session) ->
      case ids.parse_session_id(session) {
        Error(_) -> Ok(None)
        Ok(_) ->
          case
            manager.session_member_page(
              attachment.registry,
              attachment.digest,
              session,
              after: "",
            )
          {
            Ok(members) -> Ok(Some(selection_of(session, members)))
            Error(manager.AdminMetadata(catalogue.Missing)) -> Ok(None)
            Error(error) -> Error(admin_failure(error))
          }
      }
  }
}

// One session's members as the page's selection: who holds it, whether there are
// more, and whether it may be shared. The registry holds `SessionOnly` for a
// session created to be shared, and the page words the two scopes by what they
// allow.
fn selection_of(session: String, members: manager.Members) -> grants.Selection {
  grants.Selection(
    session:,
    holders: list.map(members.page.entries, listed_holder),
    more: more_of(members.page.remainder),
    scope: case members.scope {
      domain.SessionOnly -> creations.Shareable
      domain.WorkspacePrivate -> creations.Private
    },
  )
}

// The registry's refusal of an administration read as the page's failure: a
// credential that is not the owner's or no longer exists ends the page, and
// anything else is the registry failing to answer.
fn admin_failure(error: manager.AdminError) -> Failure {
  case error {
    manager.AdminForbidden -> Gone(ending.AccessRevoked)
    manager.AdminMetadata(catalogue.Missing) -> Gone(ending.AccessRevoked)
    manager.AdminMetadata(catalogue.Invalid(_))
    | manager.AdminMetadata(catalogue.Unsupported)
    | manager.AdminMetadata(catalogue.Conflict)
    | manager.AdminMetadata(catalogue.Database(_))
    | manager.IsolationRequired
    | manager.AdminStaleEpoch
    | manager.AdminUnavailable
    | manager.AdminBusy
    | manager.AdminForeignPath -> Unreadable
  }
}

// The owner leads the list and the invited follow in the catalogue's identity
// order, so the owner is where the eye starts and an invitation's `guest-` name
// does not sort above them.
fn owner_first(rows: List(grants.Principal)) -> List(grants.Principal) {
  let #(owners, members) =
    list.partition(rows, fn(row) {
      case row.kind {
        grants.OwnerKind -> True
        grants.MemberKind -> False
      }
    })
  list.append(owners, members)
}

fn more_of(remainder: access.Remainder) -> grants.More {
  case remainder {
    access.Exhausted -> grants.Whole
    access.Remaining -> grants.Truncated
  }
}

// One principal as the page draws it: the catalogue's own fields and the
// credential's state, with a fingerprint and a lifetime and nothing to sign in
// with.
fn listed_principal(row: access.Listing) -> grants.Principal {
  grants.Principal(
    id: row.principal.id,
    name: row.principal.display_name,
    kind: case row.principal.kind {
      access.OwnerPrincipal -> grants.OwnerKind
      access.MemberPrincipal -> grants.MemberKind
    },
    credential: case row.credential {
      access.CredentialActive(fingerprint:, claimed_at_ms:) ->
        grants.Active(fingerprint:, claimed_at_ms:)
      access.CredentialClaimOpen(expires_in_ms:) ->
        grants.ClaimOpen(expires_in_ms:)
      access.CredentialClaimExpired -> grants.ClaimExpired
      access.CredentialNone -> grants.NoCredential
    },
  )
}

fn listed_holder(row: access.SessionMember) -> grants.Holder {
  grants.Holder(
    principal: row.principal_id,
    name: row.name,
    role: page_role(row.role),
  )
}

fn page_role(role: access.Role) -> invites.Role {
  case role {
    access.Observer -> invites.Observer
    access.Operator -> invites.Operator
  }
}

/// Starts `admin_reading` in a run of its own and returns at once, so the page's
/// runtime is free while the registry answers; `deliver` is called, from that
/// run, with the reading, whatever it is, and `ended` tells the socket a page that
/// can no longer be served.
///
/// The run is a weft run with one task, linked to the calling process, which is
/// the page's runtime, as `resume_task`'s is: a page that goes away cancels it.
/// Every step of the reading is bounded by its own call timeouts, so the task
/// always answers, though not within seconds: a reading makes one registry call
/// for each listed session (up to `sessions.listed_limit`), each bounded by its
/// own call timeout, so the bound is that timeout times the sessions listed. It
/// needs no deadline of its own, and the page runs one reading at a time
/// (`web_view/admin`), so a slow registry is never asked for two at once. Its last act
/// is `deliver`, so a page that stays open is always answered.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.admin_read_task(attachment, open, None, deliver, ended)
/// ```
@internal
pub fn admin_read_task(
  attachment: server.AdminAttachment(instance),
  open: fn() -> Result(Int, Nil),
  chosen: Option(String),
  deliver: fn(grants.Reading) -> Nil,
  ended: fn(ending.Ending) -> Nil,
) -> Nil {
  let _ =
    weft.new([
      fn() {
        deliver(admin_reading(attachment, open, chosen, ended))
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  Nil
}

/// Makes one change the admin page asked for, or gives the reason it did not
/// (protocol-change/065, the fifth pull request). It blocks the calling process
/// for the registry's call, so a page's component never calls it directly:
/// `admin_task` runs it in a run of its own.
///
/// Each step is the daemon's and is made afresh, with the digest of the
/// credential the page was admitted under, and nothing is taken from the page but
/// the identities the server drew into its tree and the text of a name:
///
/// 0. The asking page must still be open (`open`). That is also the page's epoch,
///    as for `resume_for`: a page that is open was admitted by this daemon and by
///    no earlier one. A page that ended but whose socket is still up changes
///    nothing (`NotOwner`).
/// 1. The page's ceiling must be Operator, and the credential must still
///    authenticate as the principal the page was admitted for, and that
///    principal must be the daemon's owner. Each is `NotOwner`.
/// 2. A change that grants access, an invitation, a rotation or a role raised to
///    operator, must have one of the credential's allowance left
///    (`ui_sessions.reserve_invite`), counted for the credential and not for the
///    page, and counted with the session page's invitation control: a page taken
///    by a program is held to three an hour across both (`TooMany`). A change
///    that only reduces access, lowering a role, removing a membership or
///    revoking credentials, is not counted. A raised role is counted whatever
///    the member held, since a read of the held role would be a second read to
///    save a place on a no-op.
/// 3. `manager.administer` is the registry turn `loomd access` runs: it
///    authenticates the credential and the epoch a second time and needs the
///    owner, so it is the last word on who may. A refusal that made nothing gives
///    an allowance back; an unknown outcome (the registry did not answer) keeps
///    it spent, since the change may have been made.
///
/// An invitation's principal identity is the daemon's, `guest-` and eight
/// hexadecimal digits, and its name is the suggested one when it passes the
/// catalogue's display-name rule. A claim exists in this function's result and
/// nowhere else: it is not logged, stored or put in a URL, and the catalogue
/// holds only its digest.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.admin_for(standing, tickets, open, epoch, Ok(address), grants.Rotate("alice"))
/// ```
@internal
pub fn admin_for(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  epoch: String,
  address: Result(String, Nil),
  action: grants.Action,
) -> grants.Answer {
  let outcome = {
    use _ <- result.try(administering(standing, open))
    case action {
      grants.Invite(session:, role:, name:) ->
        invite_for_admin(standing, tickets, epoch, address, session, role, name)
      grants.SetRole(session:, principal:, role: invites.Operator) ->
        granted(
          standing,
          tickets,
          epoch,
          manager.SetRole(principal, session, access.Operator),
        )
      grants.SetRole(session:, principal:, role: invites.Observer) ->
        reduced(
          standing,
          epoch,
          manager.SetRole(principal, session, access.Observer),
        )
      grants.RevokeMembership(session:, principal:) ->
        reduced(standing, epoch, manager.RevokeMembership(principal, session))
      grants.RevokeCredentials(principal:) ->
        reduced(standing, epoch, manager.RevokeMember(principal))
      grants.RevokeSignin(principal:, fingerprint:) ->
        revoke_signin_for_admin(standing, epoch, principal, fingerprint)
      grants.Rotate(principal:) ->
        rotate_for_admin(standing, tickets, epoch, address, principal)
      grants.Rename(principal:, name:) ->
        rename_for_admin(standing, epoch, principal, name)
    }
  }
  case outcome {
    Ok(answer) -> answer
    Error(reason) -> grants.Declined(reason)
  }
}

// The steps every change begins with: the page is open, was minted to operate,
// and its credential still authenticates as the owner it was admitted for.
fn administering(
  standing: Standing(instance),
  open: fn() -> Result(Int, Nil),
) -> Result(Nil, grants.Reason) {
  owner_operating(standing, open)
  |> result.replace(Nil)
  |> result.replace_error(grants.NotOwner)
}

// One sign-in of the named principal ended, which only reduces access and costs
// no allowance. The registry authenticates the owner's credential and the epoch
// in the same turn as the write and drops its frame memo before it answers, so
// every page the login minted ends at its next frame. The log says which login,
// by fingerprint, as the control command's does.
fn revoke_signin_for_admin(
  standing: Standing(instance),
  epoch: String,
  principal: String,
  fingerprint: String,
) -> Result(grants.Answer, grants.Reason) {
  case
    manager.revoke_login(
      standing.registry,
      standing.digest,
      epoch,
      Some(principal),
      fingerprint,
    )
  {
    Ok(#(revoked, digest)) -> {
      ui_login.revoked(revoked, digest)
      Ok(grants.Changed)
    }
    Error(error) -> Error(admin_reason(error))
  }
}

// One principal's display name changed, which grants nothing and costs no
// allowance. The registry authenticates the owner's credential and the epoch in
// the same turn as the write and judges the name there, by the rule a claim's
// chosen name is held to, so a refused name writes nothing.
fn rename_for_admin(
  standing: Standing(instance),
  epoch: String,
  principal: String,
  name: String,
) -> Result(grants.Answer, grants.Reason) {
  case
    manager.rename_principal(
      standing.registry,
      standing.digest,
      epoch,
      Some(principal),
      name,
    )
  {
    Ok(_) -> Ok(grants.Changed)
    Error(manager.AdminMetadata(catalogue.Invalid(_))) ->
      Error(grants.InvalidName)
    Error(error) -> Error(admin_reason(error))
  }
}

// A change that grants access: one allowance first, then the registry turn, and
// the allowance back when the turn made nothing.
fn granted(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  epoch: String,
  action: manager.Administration,
) -> Result(grants.Answer, grants.Reason) {
  use _ <- result.try(
    ui_sessions.reserve_invite(tickets, standing.digest)
    |> result.map_error(too_many),
  )
  case manager.administer(standing.registry, standing.digest, epoch, action) {
    Ok(_) -> Ok(grants.Changed)
    Error(error) -> {
      give_back(tickets, standing.digest, Managed(error))
      Error(admin_reason(error))
    }
  }
}

// A change that only reduces access, which costs no allowance.
fn reduced(
  standing: Standing(instance),
  epoch: String,
  action: manager.Administration,
) -> Result(grants.Answer, grants.Reason) {
  case manager.administer(standing.registry, standing.digest, epoch, action) {
    Ok(_) -> Ok(grants.Changed)
    Error(error) -> Error(admin_reason(error))
  }
}

// An invitation into a session the page chose, with the suggested name when it
// is one, and one allowance. The name and the session are judged before the
// allowance is taken, so a refused name costs nothing.
fn invite_for_admin(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  epoch: String,
  address: Result(String, Nil),
  session: String,
  role: invites.Role,
  name: String,
) -> Result(grants.Answer, grants.Reason) {
  use named <- result.try(suggested_name(name))
  use _ <- result.try(
    ids.parse_session_id(session) |> result.replace_error(grants.NotFound),
  )
  use address <- result.try(address |> result.replace_error(grants.Unavailable))
  use _ <- result.try(
    ui_sessions.reserve_invite(tickets, standing.digest)
    |> result.map_error(too_many),
  )
  case
    invitation(
      standing.registry,
      standing.digest,
      epoch,
      session,
      address,
      role,
      named,
    )
  {
    Ok(made) ->
      Ok(
        grants.Claimed(grants.Claim(
          principal: made.principal,
          purpose: grants.Invited(role),
          page: made.page,
          command: made.command,
          token: made.token,
          expires_in_ms: made.expires_in_ms,
        )),
      )
    Error(refusal) -> {
      give_back(tickets, standing.digest, refusal)
      Error(refusal_reason(refusal))
    }
  }
}

// The refusal of a grant that found the allowance spent, with the count and the
// instant a place frees. The count is the whole allowance, since a refusal only
// happens when every place is taken.
fn too_many(free_at_ms: Int) -> grants.Reason {
  grants.TooMany(used: ui_sessions.invite_limit, free_at_ms:)
}

// The suggested name: none when blank, the trimmed text when it passes the
// catalogue's display-name rule, and a refusal when it does not.
fn suggested_name(name: String) -> Result(Option(String), grants.Reason) {
  case string.trim(name) {
    "" -> Ok(None)
    text ->
      catalogue.display_name(text)
      |> result.map(fn(_) { Some(text) })
      |> result.replace_error(grants.InvalidName)
  }
}

// A rotation of one principal's credentials, which makes a new claim and costs
// one allowance.
fn rotate_for_admin(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  epoch: String,
  address: Result(String, Nil),
  principal: String,
) -> Result(grants.Answer, grants.Reason) {
  use address <- result.try(address |> result.replace_error(grants.Unavailable))
  use _ <- result.try(
    ui_sessions.reserve_invite(tickets, standing.digest)
    |> result.map_error(too_many),
  )
  case rotation(standing, epoch, address, principal) {
    Ok(claim) -> Ok(grants.Claimed(claim))
    Error(refusal) -> {
      give_back(tickets, standing.digest, refusal)
      Error(refusal_reason(refusal))
    }
  }
}

// The dispatch: a claim is drawn and handed to the registry as a digest, and the
// token comes back only in the claim the page shows.
fn rotation(
  standing: Standing(instance),
  epoch: String,
  address: String,
  principal: String,
) -> Result(grants.Claim, Refusal) {
  use #(enrollment, claim_token) <- result.try(
    server.claim_enrollment(invites.claim_ttl_ms)
    |> result.replace_error(Undrawn),
  )
  use rotated <- result.map(
    manager.administer(
      standing.registry,
      standing.digest,
      epoch,
      manager.RotateMember(principal, enrollment),
    )
    |> result.map_error(Managed),
  )
  grants.Claim(
    principal: rotated.id,
    purpose: grants.Rotated,
    page: browser_claim_address(address),
    command: "loom claim --addr " <> address,
    token: claim_token,
    expires_in_ms: invites.claim_ttl_ms,
  )
}

// The fixed reason for a refused administration. A principal or session the
// catalogue does not hold is `NotFound`, which is what a row that was removed
// since it was drawn reads as; the rest are the daemon's to sort out.
fn admin_reason(error: manager.AdminError) -> grants.Reason {
  case error {
    manager.IsolationRequired -> grants.NotIsolated
    manager.AdminForbidden -> grants.NotOwner
    manager.AdminMetadata(catalogue.Missing) -> grants.NotFound
    manager.AdminMetadata(catalogue.Invalid(_))
    | manager.AdminMetadata(catalogue.Unsupported)
    | manager.AdminMetadata(catalogue.Conflict)
    | manager.AdminMetadata(catalogue.Database(_))
    | manager.AdminStaleEpoch
    | manager.AdminUnavailable
    | manager.AdminBusy
    | manager.AdminForeignPath -> grants.Unavailable
  }
}

fn refusal_reason(refusal: Refusal) -> grants.Reason {
  case refusal {
    Managed(error) -> admin_reason(error)
    Undrawn -> grants.Unavailable
  }
}

/// Starts `admin_for` in a run of its own and returns at once, so the page's
/// runtime is free while the registry answers; `deliver` is called, from that
/// run, with the answer, whatever it is.
///
/// The run is a weft run with one task, linked to the calling process, which is
/// the page's runtime, as `rename_task`'s is: a page that goes away cancels it,
/// and a change the registry has already begun finishes on the registry's own
/// turn. Every step of `admin_for` is bounded by its own call timeouts, so the
/// task always answers within seconds and needs no deadline of its own. Its last
/// act is `deliver`, so a page that stays open is always answered.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.admin_task(standing, tickets, open, epoch, Ok(address), grants.Rotate("alice"), deliver)
/// ```
@internal
pub fn admin_task(
  standing: Standing(instance),
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  epoch: String,
  address: Result(String, Nil),
  action: grants.Action,
  deliver: fn(grants.Answer) -> Nil,
) -> Nil {
  let _ =
    weft.new([
      fn() {
        deliver(admin_for(standing, tickets, open, epoch, address, action))
        Ok(Nil)
      },
    ])
    |> weft.start_witnessed
  Nil
}

/// The address a person without `loom` opens to claim in a browser, made from
/// the address `claim_address` made for the command: `http://`, the same host
/// and `/ui/claim` (`page.claim_path`). It names no token, and the command's
/// address ends in `/v2/control` by construction, so only the scheme and the
/// path change.
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.browser_claim_address("ws://127.0.0.1:4000/v2/control")
///   == "http://127.0.0.1:4000/ui/claim"
/// ```
@internal
pub fn browser_claim_address(address: String) -> String {
  let host =
    address
    |> string.drop_start(string.length("ws://"))
    |> string.drop_end(string.length("/v2/control"))
  "http://" <> host <> page.claim_path
}

/// The address a page's claim command names: `ws://` and the `Host` the page
/// was reached at, then `/v2/control`, when `loom claim` accepts it.
///
/// The router has already required the host to be a loopback name
/// (`ui_http.loopback_host`), and `localhost` is written as `127.0.0.1`
/// because `loom claim` refuses a `ws` address that is not a literal loopback
/// one. The command therefore works on the machine that runs the daemon,
/// which the page says. A daemon reached through a proxy on another origin
/// would need its own address, which no page can learn from a `Host` that the
/// router refused.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.claim_address(request) == Ok("ws://127.0.0.1:4000/v2/control")
/// ```
@internal
pub fn claim_address(request: Request(body)) -> Result(String, Nil) {
  use host <- result.try(ui_http.loopback_host(request))
  let literal = case string.lowercase(host) {
    "localhost" <> rest -> "127.0.0.1" <> rest
    other -> other
  }
  let address = "ws://" <> literal <> "/v2/control"
  claim.remote_address(address)
  |> result.replace(address)
  |> result.replace_error(Nil)
}

// A refused membership check: the catalogue holds no such membership, or the
// registry could not answer.
fn not_held(error: manager.Error) -> sessions.Reason {
  case error {
    manager.Catalogue(catalogue.Missing) -> sessions.NotHeld
    _ -> sessions.Unavailable
  }
}

// Only a resident session has a page to show.
fn running(status: manager.Status) -> Result(Nil, sessions.Reason) {
  case status {
    manager.Resident(_) -> Ok(Nil)
    manager.Reserved
    | manager.Saved
    | manager.Opening(_)
    | manager.Stopping(_)
    | manager.RecoveryBlocked(_) -> Error(sessions.NotRunning)
  }
}

/// One catalogue view as the sidebar's entry: the identity, name, workspace
/// and creation time, whether a process runs the session and, for one that
/// does not, whether a page may ask the daemon to resume it. The database
/// path, the request key and the configuration reference the registration
/// also holds have no place in an entry, so none reaches a page.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.listed_entry(manager.View(registration, manager.Saved))
/// ```
@internal
pub fn listed_entry(view: manager.View) -> sessions.Entry {
  let record = view.registration
  sessions.Entry(
    id: record.id,
    name: record.name,
    workspace: record.workspace,
    created_at: record.created_at,
    residency: case view.status {
      manager.Opening(..) | manager.Resident(..) | manager.Stopping(..) ->
        sessions.Live
      manager.Saved -> sessions.Saved
      manager.Reserved | manager.RecoveryBlocked(..) -> sessions.Blocked
    },
    subtitle: record.subtitle,
    role: None,
    project: None,
  )
}

/// The entries with the project of each one's workspace, read from the host's
/// disk now (`ui_project.locate`). A workspace that is no repository, or whose
/// pointer does not check out, keeps no project, which makes it its own.
///
/// The read is a few stats for each entry, so a caller runs it off the page's
/// runtime: the session page's list task does, and the home's listing keeps it
/// beside `home_listing` so it moves into that read's task with it. It uses the
/// workspace the catalogue recorded, and nothing a page sent reaches it.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.with_projects(entries)
/// ```
@internal
pub fn with_projects(entries: List(sessions.Entry)) -> List(sessions.Entry) {
  list.map(entries, fn(entry) {
    sessions.Entry(..entry, project: ui_project.locate(entry.workspace))
  })
}

/// The entries with the role the principal holds in each, from the daemon's
/// own membership rows (`manager.authorized_roles`). A session with no row,
/// which is every session of the owner's, keeps no role.
///
/// The roles are matched by session identity and nothing else reaches them: a
/// page sends the daemon no role, so the word a row says is the catalogue's
/// and a person cannot raise it by anything they send.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.with_roles(entries, [#(session_id, access.Observer)])
/// ```
@internal
pub fn with_roles(
  entries: List(sessions.Entry),
  roles: List(#(String, access.Role)),
) -> List(sessions.Entry) {
  list.map(entries, fn(entry) {
    case list.key_find(roles, entry.id) {
      Ok(access.Operator) ->
        sessions.Entry(..entry, role: Some(sessions.Operates))
      Ok(access.Observer) ->
        sessions.Entry(..entry, role: Some(sessions.Observes))
      Error(Nil) -> entry
    }
  })
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
    /// Asks the component for the image its lane drew at a row's name and
    /// position. It answers `Error(Nil)` for any other, and at once when the
    /// socket that owns the component has ended.
    images: ui_sessions.Images,
  )
}

// The message that asks an operator's page for an image, in its own message
// type.
fn operator_image(
  ref: String,
  at: Int,
  reply: process.Subject(Result(transcript_image.Image, Nil)),
) -> operator_page.Msg(ui_relay.Relay) {
  operator_page.Observed(component.ImageRequested(ref, at, reply))
}

/// Starts the component a page of `role` gets: an observer's page, which
/// takes one click at three places, or an operator's, which takes only the
/// events its view attaches, with an owner's also taking the invitation
/// control's. Called from the socket's own process, which then owns the
/// subject the component's messages arrive on.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.start_page(ui_socket.Observing, start)
/// ```
@internal
pub fn start_page(
  role: Role,
  start: component.Start(ui_relay.Relay),
) -> Result(Page, Nil) {
  case role {
    Observing ->
      serve(component.app(), start, observer_accepts, component.ImageRequested)
    Operating ->
      serve(operator_page.app(), start, operator_accepts, operator_image)
    Owning -> serve(operator_page.app(), start, owner_accepts, operator_image)
  }
}

// Starts a session's component and returns what the socket needs of it,
// including the reader of its images: the message that asks the component for
// one, `ask`, is built in the application's own message type.
fn serve(
  app: lustre.App(component.Start(ui_relay.Relay), model, message),
  start: component.Start(ui_relay.Relay),
  admits: fn(String) -> Bool,
  ask: fn(String, Int, process.Subject(Result(transcript_image.Image, Nil))) ->
    message,
) -> Result(Page, Nil) {
  use #(runtime, page) <- result.map(launch(app, start, admits))

  // This process owns the component and ends with it, so it is the page's
  // owner for the inspector; the component's own process belongs to Lustre
  // and stays unlabelled.
  owner.label([#("session", start.session_id)], owner.PageSocket)

  // The reader belongs to this socket's process, which owns the component and
  // ends with it. A request that arrives after the socket ended is refused
  // without a message, and one that arrives while it is up waits for the
  // component's own answer on a subject of the asking process.
  let socket = process.self()
  let images = fn(ref, position) {
    case process.is_alive(socket) {
      False -> Error(Nil)
      True -> {
        let reply = process.new_subject()
        lustre.send(runtime, lustre.dispatch(ask(ref, position, reply)))
        process.receive(reply, image_wait_ms) |> result.flatten
      }
    }
  }
  Page(..page, images:)
}

// Starts one component and returns its runtime and what the socket needs of
// it: how a browser frame reaches it, how to shut it down, and a selector over
// the subject its client messages arrive on, encoding each as it is received.
// `admits` says which browser frames reach it. The page has no image reader
// until `serve` makes one, and the home never does.
fn launch(
  app: lustre.App(arguments, model, message),
  start: arguments,
  admits: fn(String) -> Bool,
) -> Result(#(lustre.Runtime(message), Page), Nil) {
  use runtime <- result.map(
    lustre.start_server_component(app, start) |> result.replace_error(Nil),
  )

  // The component's messages for the browser arrive on a subject this socket
  // owns, and are written from this process's own turns.
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
  #(
    runtime,
    Page(
      forward:,
      shutdown: fn() { lustre.send(runtime, lustre.shutdown()) },
      frames: encoded,
      images: fn(_, _) { Error(Nil) },
    ),
  )
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
  |> result.replace_error(ending.reason(ending.AccessRevoked))
}
