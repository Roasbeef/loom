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

import client/daemon/manager
import client/daemon/root
import client/daemon/server
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
import gleam/option.{Some}
import gleam/result
import gleam/string
import host/bootstrap
import lustre
import lustre/server_component
import mist
import session_view/snapshot
import session_view/transcript_image
import storage/access
import storage/catalogue
import web_view/component
import web_view/ending
import web_view/operator_page
import web_view/page
import web_view/sessions

/// The inbound frame limit on an operator's page socket: 12 MiB, which holds
/// a text prompt and up to `web_view/image.max_attached_bytes` of images (8 MiB
/// before base64, a third more after) in one submit event, and is well under
/// the terminal's 32 MiB. It was 1 MiB while the page sent text alone
/// (protocol-change/051, the operator addendum); the addendum on images raised
/// it and says why. An observer's page keeps the 64 KiB an observer's
/// connection class has. The permit an operator's page holds is charged for
/// the class's own 32 MiB message limit (`root.message_limit`), so this limit
/// is inside what admission already reserves.
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

/// The browser messages an operator's page takes: Lustre's `EventFired` for
/// the events its view attaches, a `click` and a `submit`, alone or batched.
/// Every other message is dropped before it reaches the component. A click
/// is admitted at any path, so the session buttons beneath
/// `component.sidebar_path` and a peer message's Open button need no entry
/// of their own; Lustre dispatches the event only to a handler the page drew
/// at that path, and the daemon checks the session again before it mints a
/// ticket (`ticket_for`).
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
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  register: fn(ui_sessions.Images) -> Nil,
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
            admit(
              daemon,
              attachment,
              attach,
              tickets,
              open,
              register,
              expected,
              signals,
              settled,
            )

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

/// Whether the admitted page is an observer's or an operator's.
pub type Role {
  Observing
  Operating
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
  tickets: ui_sessions.Sessions,
  open: fn() -> Result(Int, Nil),
  register: fn(ui_sessions.Images) -> Nil,
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
      sessions: fn() {
        listed_for(role_of(attachment.authority), fn() { listed(attachment) })
      },
      open: fn(target) {
        opened_for(role_of(attachment.authority), fn() {
          ticket_for(attachment, tickets, attach.ceiling, open, target)
        })
      },
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
      start_page(attachment.authority, start)
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
    Ok(Page(forward:, shutdown:, frames:, images:)) -> {
      register(images)
      mist.continue(Serving(forward, shutdown, signals))
      |> mist.with_selector(
        process.new_selector()
        |> process.select(signals)
        |> process.merge_selector(process.map_selector(frames, Client)),
      )
    }
  }
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
    Operating -> read()
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
    Operating -> ask()
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
    ui_sessions.mint_before(
      tickets,
      ui_sessions.Grant(
        session_id: target,
        credential: attachment.digest,
        principal: attachment.principal.id,
        ceiling:,
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
    Observing ->
      serve(component.app(), start, observer_accepts, component.ImageRequested)
    Operating ->
      serve(operator_page.app(), start, operator_accepts, fn(ref, at, reply) {
        operator_page.Observed(component.ImageRequested(ref, at, reply))
      })
  }
}

// Starts one component and returns what the socket needs of it: how a
// browser frame reaches it, how to shut it down, and a selector over the
// subject its client messages arrive on, encoding each as it is received.
// `admits` says which browser frames reach it, and `ask` builds the message
// that asks it for an image, in the application's own message type.
fn serve(
  app: lustre.App(component.Start(ui_relay.Relay), model, message),
  start: component.Start(ui_relay.Relay),
  admits: fn(String) -> Bool,
  ask: fn(String, Int, process.Subject(Result(transcript_image.Image, Nil))) ->
    message,
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

      // The reader belongs to this socket's process, which owns the
      // component and ends with it. A request that arrives after the socket
      // ended is refused without a message, and one that arrives while it is
      // up waits for the component's own answer on a subject of the asking
      // process.
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
      Ok(Page(
        forward:,
        shutdown: fn() { lustre.send(runtime, lustre.shutdown()) },
        frames: encoded,
        images:,
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
  |> result.replace_error(ending.reason(ending.AccessRevoked))
}
