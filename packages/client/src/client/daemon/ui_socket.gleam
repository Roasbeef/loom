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
//// ## Flow
////
//// `upgrade` → `websocket` → `admit` → `start_page` → `serve` → `closing`
////
//// 1. `upgrade` reads the page's `role_of` its attachment, builds the relay
////    `Attach` and the invitation capability, and opens `websocket`.
////    `upgrade_home` opens the same `websocket` for a home, whose `admit_home`
////    starts its component through `launch` in place of `start_page`.
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
import telemetry/owner
import web_view/component
import web_view/ending
import web_view/home
import web_view/invites
import web_view/operator_page
import web_view/page
import web_view/sessions

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
/// Lustre's `EventFired` for a `click`, and only at two places. One is
/// `component.older_path`, the lane's "Load older" button, whose message asks
/// for a read of older history and nothing else (protocol-change/051, the
/// addendum on history paging). The other is any path beneath
/// `component.strip_path`, the agent strip's chip list, where each handler is
/// a chip's button and its message moves the page's focus to that chip's
/// strand, which is a change of what the page reads and sends no command (the
/// addendum on strand focus). The strand is named by the message the server
/// drew and not by the frame, so the frame chooses among the chips and cannot
/// name a strand. Every other message is dropped here, a batch included, so
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

// The two places an observer's click may fire: the older button, and a chip
// beneath the strip's list. The list's own path is not a chip, so the prefix
// includes the separator.
fn observer_path(path: String) -> Bool {
  path == component.older_path
  || string.starts_with(path, component.strip_path <> "\t")
}

/// The browser messages a member operator's page takes: Lustre's `EventFired`
/// for the events its view attaches, a `click` and a `submit`, alone or
/// batched. Every other message is dropped before it reaches the component. A
/// click is admitted at any path but one, so the session buttons beneath
/// `component.sidebar_path` and a peer message's Open button need no entry of
/// their own; Lustre dispatches the event only to a handler the page drew at
/// that path, and the daemon checks the session again before it mints a ticket
/// (`ticket_for`). The one path it drops is `component.invite_path` and
/// anything beneath it, the invitation control, which is an owner's and which
/// this page does not draw (`owner_accepts`; the addendum on inviting from the
/// session page). A message in a batch that reaches it drops the whole batch.
///
/// ## Examples
///
/// ```gleam
/// assert ui_socket.operator_accepts("{\"kind\":1,\"name\":\"click\"}")
/// ```
pub fn operator_accepts(frame: String) -> Bool {
  accepts(frame, ExceptInvite)
}

/// The browser messages an owner's page takes: what `operator_accepts` takes,
/// and a click at or beneath `component.invite_path` as well. It is the one
/// socket that admits the invitation control's buttons, and it is started
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

// Where an operator-class socket admits a click.
type Reach {
  // At any path: an owner's page.
  Everywhere

  // At any path but the invitation control's: a member operator's page.
  ExceptInvite
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

// Whether a socket of this reach admits an event at `path`. The invitation
// control's own path is included, and so is anything beneath it, with the
// separator so that a path that merely begins with the same digits is not.
fn reaches(reach: Reach, path: String) -> Bool {
  case reach {
    Everywhere -> True
    ExceptInvite ->
      path != component.invite_path
      && !string.starts_with(path, component.invite_path <> "\t")
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
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  register: fn(ui_sessions.Images) -> Nil,
  ceiling: access.Role,
) -> Response(mist.ResponseData) {
  let role = role_of(attachment)
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
  websocket(request, limit, settled, fn(signals) {
    admit(
      daemon,
      attachment,
      attach,
      tickets,
      open,
      register,
      invite,
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
/// since the home's view attaches no handler and `home_accepts` admits no
/// browser frame at all.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.upgrade_home(root, request, attachment, open, access.Operator)
/// ```
pub fn upgrade_home(
  daemon: root.Root(instance),
  request: Request(mist.Connection),
  attachment: server.HomeAttachment(instance),
  open: fn() -> Result(Int, Nil),
  ceiling: access.Role,
) -> Response(mist.ResponseData) {
  let settled = process.new_subject()
  let limit = root.message_limit(root.Observer)
  websocket(request, limit, settled, fn(signals) {
    admit_home(daemon, attachment, open, ceiling, signals, settled)
  })
}

/// The browser messages a home page takes: none. The home draws no handler,
/// so no event can name one, and every frame is dropped before it costs the
/// component a render. The component's own messages are sent from this side
/// of the socket, which a browser frame cannot produce.
///
/// ## Examples
///
/// ```gleam
/// assert !ui_socket.home_accepts("{\"kind\":1,\"name\":\"click\"}")
/// ```
pub fn home_accepts(_frame: String) -> Bool {
  False
}

// Takes the permit in the socket's first handler turn, as `admit` does, and
// then starts the home component with the read of the principal's sessions
// as it is: a closure over the attachment, run in the component's process.
fn admit_home(
  daemon: root.Root(instance),
  attachment: server.HomeAttachment(instance),
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
      sessions: fn() {
        home_listing(attachment, open, fn(reason) {
          process.send(signals, Ended(reason))
        })
      },
    )
  let started = case transferred {
    Error(reason) -> {
      upgrade_log.closed_early(upgrade_log.Page, "transfer", reason)
      Error(Nil)
    }
    Ok(Nil) ->
      launch(home.app(), start, home_accepts)
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
  list.map(views, listed_entry)
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
  expected: snapshot.Expected,
  signals: process.Subject(Signal),
  settled: process.Subject(Nil),
) -> mist.Next(Phase, Signal) {
  let role = role_of(attachment)
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
      sessions: fn() { listed_for(role, fn() { listed(attachment) }) },
      open: fn(target) {
        opened_for(role, fn() {
          ticket_for(attachment, tickets, attach.ceiling, open, target)
        })
      },
      invite:,
    )
  let start =
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
      transport:,
    )
  let started = case transferred {
    Error(reason) -> {
      upgrade_log.closed_early(upgrade_log.Page, "transfer", reason)
      Error(Nil)
    }
    Ok(Nil) ->
      start_page(role, start)
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

// The sessions the page's principal may see, for the sidebar
// (protocol-change/051, the addendum on the session sidebar): the same
// authorized read a terminal's session picker makes. It is made with the
// digest of the credential the page was admitted under, which the registry
// authenticates again on every call, so a member is listed only the sessions
// they hold a membership in, an owner every active session, and a revoked
// credential none. It carries the catalogue's own fields, and never a
// database path or a configuration, which the entry has no place for. A
// failed read is an empty list, which the sidebar draws as nothing.
fn listed(attachment: server.Attachment(instance)) -> List(sessions.Entry) {
  case
    manager.authorized_page(attachment.registry, attachment.digest, after: "")
  {
    Ok(#(_, views)) -> list.map(views, listed_entry)
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

/// A ticket for the operator's page's principal to open `target`, or the
/// reason there is none.
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
///    what a link allowed. It is single use and lives 60 seconds like any
///    other, and is minted into the same table, so the page cap and the
///    redemption rules are unchanged.
///
/// The reasons are `NotHeld` for an identity that is not a session's or is
/// not the principal's, `NotRunning` for a saved session and `Unavailable`
/// for anything the daemon could not answer. `NotHeld` covers a session that
/// does not exist and one the principal cannot see alike.
///
/// ## Examples
///
/// ```gleam
/// // ui_socket.ticket_for(attachment, tickets, access.Operator, target)
/// ```
@internal
pub fn ticket_for(
  attachment: server.Attachment(instance),
  tickets: ui_sessions.Sessions,
  ceiling: access.Role,
  open: fn() -> Result(Int, Nil),
  target: String,
) -> sessions.Answer {
  let outcome = {
    use until <- result.try(open() |> result.replace_error(sessions.NotHeld))
    use _ <- result.try(
      ids.parse_session_id(target) |> result.replace_error(sessions.NotHeld),
    )
    use _ <- result.try(
      manager.session_authority(attachment.registry, attachment.digest, target)
      |> result.map_error(not_held),
    )
    use view <- result.try(
      manager.get(attachment.registry, target)
      |> result.replace_error(sessions.Unavailable),
    )
    use _ <- result.try(running(view.status))

    // The switch's page keeps the reach every session page has until a home
    // can open one (protocol-change/065, the second pull request): a page
    // that came from a home will carry its own reach onto the ticket.
    ui_sessions.mint_before(
      tickets,
      ui_sessions.Grant(
        scope: ui_sessions.Session(target),
        credential: attachment.digest,
        principal: attachment.principal.id,
        ceiling:,
        reach: ui_sessions.OneSession,
      ),
      until,
    )
    |> result.replace_error(sessions.Unavailable)
  }
  case outcome {
    Ok(issued) -> sessions.Ticketed(page.exchange_path(target, issued.ticket))
    Error(reason) -> sessions.Declined(reason)
  }
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
        Error(Nil) -> invites.Declined(invites.TooMany)
        Ok(Nil) ->
          case invited(attachment, address, chosen) {
            Ok(invitation) -> invites.Minted(invitation)
            Error(refusal) -> {
              give_back(tickets, attachment, refusal)
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

// The dispatch. The claim is drawn here and handed to the registry as a
// digest, and the token comes back only in the invitation the caller shows.
fn invited(
  attachment: server.Attachment(instance),
  address: String,
  chosen: invites.Role,
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
  use principal <- result.map(
    manager.administer(
      attachment.registry,
      attachment.digest,
      attachment.epoch,
      manager.Invite(
        id,
        "Guest " <> string.drop_start(id, 6),
        enrollment,
        attachment.session_id,
        member,
      ),
    )
    |> result.map_error(Managed),
  )
  invites.Invitation(
    principal: principal.id,
    role: chosen,
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
  attachment: server.Attachment(instance),
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
    | Undrawn -> ui_sessions.release_invite(tickets, attachment.digest)
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
/// and creation time, and whether a process runs the session. The database
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
      manager.Reserved | manager.Saved | manager.RecoveryBlocked(..) ->
        sessions.Saved
    },
  )
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
/// takes one click at two places, or an operator's, which takes only the
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
