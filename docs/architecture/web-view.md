# The web view

`loomd --ui` serves a page for one session to a browser. The page is a
Lustre 5.7.1 server component that runs inside the daemon, and it drives
the same session lane and transcript projection as the terminal, from
`packages/session_view`. The browser runs only Lustre's small client
runtime, which applies the patches the component sends and sends back the
DOM events the component's view asked for. No credential, session state or
session logic reaches the browser.

Three terms recur below and name different things. **The session lane**,
or the lane, is one attached client's connection to one session,
`session_view/session_channel.Channel`: each terminal and each page holds
its own, and a lane carries the frames of every strand in the session. **A
strand** is one conversation thread in the session, such as `main`, the
advisor or `sub:reviewer`. **The transcript** is what the page draws of one
strand's entries; today that strand is always `main`. So one page has one
lane, the lane sees every strand, and the transcript shows one of them.

The view is off unless the daemon was started with `--ui`. With it off, the
listener routes exactly `/v2/control` and `/v2/sessions/<id>/ws`, and the
control `hello` does not mention the view. A person gets a page by running
`loom ui --session <id>`, which prints a single-use link.

This document describes how the view is built. The decisions behind it are
in [ADR-014](../adr/014-second-runtime.md) (one engine, two views) and
[protocol-change/051](../../protocol-change/051-web-view-route.md) (the
routes, the tickets and cookies, and the operator addendum).
[protocol-change/052](../../protocol-change/052-web-view-remote-origin.md)
proposes serving the page behind a TLS origin; it is a design and is not
implemented. [Writing the web view with Lustre](../lustre.md) is the
companion guide to Lustre itself: how server components work, the rules
for view code, and the checklist for a change. This document links to it
rather than repeating it. The [web UI design note](../design-notes/web-ui.md)
is the working spec for where the page is going.

## Why a second runtime exists

The terminal is one person at one keyboard. Loom's sessions are shared: an
owner invites operators and observers, and several people can watch the
same agents work ([multiplayer](multiplayer.md)). A browser page lets a
person follow a session without a terminal attached, and it is where the
agent-first, multi-session views of the design note will live.

The page could have been built three other ways, and each was rejected for
a stated reason ([ADR-014](../adr/014-second-runtime.md), "Alternatives
considered"):

- **A single-page app that speaks the protocol from the browser.**
  `session_view` compiles to JavaScript, so the lane could run there. It
  would put the person's bearer credential in the browser, and it would
  make the browser a second place where session behaviour must match the
  terminal's.
- **A sidecar program that serves the page.** Per-person authentication
  needs the daemon's own credential store, which a sidecar does not have.
- **A web model of its own.** Less code at first, and a rewrite later.

The server component keeps the engine on the BEAM, next to the terminal's
copy of the same code. One rule follows, and reviews hold the code to it:
**the web view grows no session logic of its own.** What a frame means,
when to catch up, which lines a capture becomes, and what an operator's
input becomes on the wire are `session_view`'s. [The client engine and its
hosts](client.md#the-client-engine-and-its-hosts) draws the layering this
rule keeps.

## What runs where

Each open page is three processes in the daemon, plus the client runtime
in the browser.

```mermaid
flowchart LR
    subgraph browser["Browser tab"]
        rt["Lustre client runtime<br/>(shadow root, patches)"]
        script["web_view_page.js<br/>(nonce from sessionStorage)"]
    end
    subgraph daemon["loomd --ui"]
        router["server.handle<br/>ui_http checks"]
        tickets[("ui_sessions actor<br/>tickets and UI sessions")]
        socket["ui_socket<br/>(mist WebSocket)"]
        subgraph comp["Lustre runtime process"]
            app["component or operator_page"]
            engine["session_view lane<br/>and projection"]
        end
        relay["ui_relay"]
        gateway["session gateway"]
    end
    script -- "sets csrf-token, then route" --> rt
    rt -- "GET /ui/..." --> router
    router --> tickets
    router -- "upgrade" --> socket
    rt <-- "Lustre JSON frames" --> socket
    socket <-- "events in, patches out" --> app
    app --- engine
    engine -- "Transmit / Shut" --> relay
    relay -- "connection_request, pushes" --> gateway
```

- **The browser** holds the page shell, Lustre's client runtime (served
  from the `lustre` application's `priv` directory), the stylesheet and
  two small scripts. It keeps the page nonce in `sessionStorage` and never
  holds a credential.
- **The router** is `client/daemon/server.handle`, which sends every
  `/ui/...` path to the web view's checks (`web_view` at
  `packages/client/src/client/daemon/server.gleam:186`) when the view is
  on. The checks themselves are pure functions of the request in
  `client/daemon/ui_http`.
- **`client/daemon/ui_sessions`** is one `weft/actor` that owns the ticket
  and UI-session tables. Every mint, redemption and lookup is a call to
  it, so a ticket is redeemed at most once.
- **`client/daemon/ui_socket`** is the page's WebSocket. It takes the
  connection permit's custody, starts one Lustre runtime for the
  connection, forwards the browser's frames that the page's role allows,
  and writes the runtime's patches to the browser.
- **The Lustre runtime** runs `web_view/component` for an observer or
  `web_view/operator_page` for an operator. The engine lives inside its
  model, which is two records: the shared session state
  (`session_view/model.Shared`, holding the `session_channel.Channel`, the
  inbox of frames not yet reduced, the last capture, the history window,
  the approvals and the agent rows) and what only the page holds (the
  transport, the timer, the rows and the strip it draws, the connection's
  status).
- **`client/daemon/ui_relay`** stands in for a session socket. It attaches
  to the session's gateway with the page's principal and capped role,
  turns each frame the lane transmits into one bounded
  `gateway.connection_request`, and hands every reply and push back to the
  component as a `connection_event.Message`. One mailbox serializes both,
  as in `session_socket`, so a reply and a push never interleave.

The component is linked to the socket process, and the relay monitors the
component and the gateway. When the browser goes away, the socket shuts
the component down and the relay detaches. When the gateway ends the
attachment, the relay reports it, the socket waits a quarter second so
the component's patch for the ended state is sent, and then closes. The
reason is a closed type (`web_view/ending`), so the page draws a fixed
notice for it, and the close code follows from it: 1000 (final, the client
runtime does not reconnect) when the person has to act, 4000 (retried) when
the daemon may clear it. [lustre.md](../lustre.md#lifecycle-and-cleanup)
walks that chain one link at a time.

## From `loom ui` to a live socket

A page is reached in four requests: one control command from the person's
own `loom`, then three HTTP requests from the browser.

### Minting the link

```mermaid
sequenceDiagram
    participant L as loom ui
    participant D as loomd control socket
    participant T as ui_sessions
    L->>D: authenticate, read hello
    D-->>L: hello with ui field
    L->>D: sessions.open, if the session is not resident
    L->>D: ui.link session_id and page
    D->>D: check membership
    D->>T: mint ticket for principal, session, credential, ceiling
    T-->>D: ticket, expires in 60 s
    D-->>L: path /ui/sessions/ID?ticket=T
    L->>L: print origin + path, then open it if --open
```

`loom ui --session <id> [--operate] [--open]` is `tui.run_view`
(`packages/tui/src/tui.gleam:1024`). It resolves the daemon with
`bootstrap.resolve_viewing_daemon`, which adds `--ui` to the launch
arguments when it has to start one. A daemon that is already running and
whose `hello` has no `ui` field was started without the view; `loom`
prints that, exits with status 1, and leaves that daemon alone, because
other people's terminals may be attached to it. Otherwise it opens the
session if it is not resident and sends `ui.link` with `page:"operator"`
when `--operate` was given and `page:"observer"` otherwise.

The command also takes the daemon options a local launch takes
(`--state-dir`, `--config`, `--server`, `--workspace`), in any order.
`loom --ui ...` is the older spelling and still works: `parse_launch`
takes `--ui` out wherever it appears in argv and hands the rest to the
same parser, `tui.view_request`, so both spellings accept the same
options in the same orders.

The daemon answers `ui.link` only for a member of the session
(`manager.session_authority`), and refuses it with `unavailable` when the
view is off. `ui_sessions.mint` draws a 32-byte ticket from the same
entropy source invitations use and keeps only its SHA-256 digest, with
the principal, the session, the digest of the credential that asked, and
the page's ceiling. The ticket lives 60 seconds (`ticket_ms`) and is spent
by its first redemption. `loom` joins the returned path to the address it
discovered and prints the link as the first line of standard output.
With `--open` it then hands the link to `open` or `xdg-open`
(`tui/view_link`); a failed opener is a note on standard error, not a
failure, because the printed link still works.

### Exchanging the ticket and opening the socket

```mermaid
sequenceDiagram
    participant B as Browser
    participant R as server.handle
    participant T as ui_sessions
    participant S as ui_socket
    participant C as component
    participant Y as ui_relay
    B->>R: GET /ui/sessions/ID?ticket=T
    R->>T: redeem T for ID
    T-->>R: cookie, page key K, nonce N
    R-->>B: 200 enter page, Set-Cookie loom_ui Path=/ui/p/K
    B->>B: keep N in sessionStorage, replace location
    B->>R: GET /ui/p/K/sessions/ID
    R->>T: look up cookie under K
    R-->>B: 200 page shell
    B->>R: GET /ui/p/K/sessions/ID/ws?csrf-token=N
    R->>T: look up cookie under K, compare N
    R->>S: upgrade with the capped role
    S->>C: start component for the role
    C->>Y: connect, returns at once
    Y-->>C: Opened, after the gateway attach
    C->>Y: subscribe, then the credited transfer
```

1. **The exchange.** `GET /ui/sessions/<id>?ticket=<t>` redeems the ticket
   inside the actor. A redemption ends no other page, except that a
   principal already holding `ui_sessions.max_pages` (four) live pages for
   the session has its oldest ended to make room (protocol-change/051, the
   addendum on several pages). It mints three secrets for the new page: the `loom_ui` cookie, the page key, and the page nonce. The
   response is a small same-origin page whose body carries the keyed path
   and the nonce as data attributes, and whose script
   (`web_view_enter.js`) stores the nonce in `sessionStorage` and calls
   `location.replace` on the keyed path. A `303` redirect was not used: a
   `SameSite=Strict` cookie is not sent on a redirect that started from
   another site, so a link clicked on a cross-site page would land on a
   `401`.
2. **The page.** `GET /ui/p/<key>/sessions/<id>` returns the shell
   (`web_view/page.shell`), one empty `<lustre-server-component>` element
   and the page script. The script reads the nonce back, sets it as the
   element's `csrf-token` attribute, and only then sets `route`, because
   the client runtime reads the token when `route` is set. A tab with no
   nonce opens no socket and tells the person to run `loom ui` again.
3. **The socket.** The client runtime opens
   `/ui/p/<key>/sessions/<id>/ws?csrf-token=<nonce>`. The router checks the
   `Origin`, the nonce, the cookie under the key, the credential and the
   membership, then resolves the resident session exactly as a terminal's
   socket does, with the role capped by the page's ceiling
   (`web_socket` at `packages/client/src/client/daemon/server.gleam:242`).
   The parser permit it reserves counts the page against the daemon's
   connection limits.
4. **The component.** In its first handler turn the socket takes the
   permit's custody and starts the component for the admitted role
   (`start_page` at `packages/client/src/client/daemon/ui_socket.gleam:1301`).
   The component's `init` selects two sources: the transport, whose
   `connect` starts the relay and returns at once, and a deadline timer,
   which it arms for the lane's next due reading once the lane exists.
   The relay attaches to the gateway as its first message and answers
   `Opened` or `Refused`. On `Opened` the component starts the lane, which
   issues `subscribe` and pulls the transfer chunk by chunk, and the first
   `Captured` update puts the transcript on the page.

"Security layers" below lists what each check in steps 1 to 3 stops.

## Two components, chosen by role

The page's role is the smallest of three things: the principal's
membership role, the ceiling the link was minted with, and Operator
(`ui_relay.capped`). A page never carries `Owner`: the one power an owner
has inside a session beyond an operator's is the worktree bytes, and a
page does not need them. Without `--operate` every page is an observer's,
whatever the person's membership says.

```mermaid
flowchart LR
    link["ui.link ceiling<br/>observer by default"] --> cap
    member["membership role"] --> cap
    cap{"ui_relay.capped<br/>min(membership, ceiling, Operator)"}
    cap -- "Observer" --> obs["component.app()<br/>no command in Msg<br/>one handler: Load older<br/>socket admits only that click"]
    cap -- "Operator" --> op["operator_page.app()<br/>Submitted and Decided<br/>composer and approval cards<br/>socket forwards click and submit"]
```

- **The observer's page** is `web_view/component`. Its message type is the
  connection's outcome, the timer's subject, batches of arrivals, the
  timer's fire, `OlderRequested`, a read of older history, `FocusRequested`,
  a change of the strand the page shows, the sidebar read's answer
  `SessionsListed` and the daemon's answer to a request to open a session,
  `Linked` (both dispatched by effects and carried by no handler), and
  nothing else, so it has no way to express a command or to ask for a
  session. Its view attaches two kinds of event handler: the lane's "Load
  older" click, drawn only while older rows exist (051, the addendum on
  history paging), and one click per chip of the agent strip (051, the
  addendum on strand focus). Where an operator's page has its composer, it
  draws a fixed line saying the page is read-only. The socket admits only a
  click at the button's fixed path (`component.older_path`) or beneath the
  strip's chip list (`component.strip_path`), and drops every other browser
  frame before it reaches the runtime (`observer_accepts`), which also
  spares the component a render per dropped frame.
- **The operator's page** is `web_view/operator_page`. It wraps the
  observer's messages in `Observed` and adds `Submitted(text, delivery)`
  and `Decided(id, seq, answer)`. The lane's "Load older" button sends
  the observer's own `OlderRequested`, wrapped. Its model is the
  observer's model. The inputs reach the shared step through
  `component.submit` and `component.decide`, which wrap them as the step's
  commands (`msg.Submit` and `msg.Decide`, run by `session_view/commands`),
  and the read through `component.older`. The socket forwards only
  Lustre's `EventFired` for `click` and `submit`, alone or in a batch
  (`operator_accepts`). A draft may be any session command, since the page
  parses it as the terminal does; the socket's admitted events and the role
  checks are as they were (protocol-change/051, the addendum "the operator
  page runs session commands"). The page also has buttons for commands the
  terminal runs from a typed draft, `Controlled(control)` and
  `Replying(key)`, which are clicks and submits like the rest (the
  addendum "the page's session controls, the pending nudges and the peer
  reply", and the addendum of 2026-10-02): the goal's Pause, Resume and
  Clear, a Fork form, and a Reply button on a peer's message. The goal's
  buttons and the Fork form are in the Session pane, after the invitation
  control, and the dock keeps one goal line while a goal is active or paused
  (the addendum of 2026-10-03). A control's
  command is `msg.Control`, which has no draft, so it never empties the
  composer. Stop and the Set goal form are gone: stopping a strand is the
  terminal's Escape, and a goal is pinned by typing `/goal ...` in the
  composer, which the page parses as a command.
  The advisor's pending nudges are a card on both pages with no button,
  because the queue has no accept or dismiss command. It sits under the
  strand panel's four panes, on every tab, so the dock holds only what the
  operator types into or answers.

The socket's inbound frame limit follows the role: 64 KiB for an
observer's page, which is the daemon's observer limit, and 12 MiB for an
operator's (`operator_frame_limit`), below a terminal operator's 32 MiB. The
largest thing a page sends is a draft with up to four images and 8 MiB of them,
at their base64 size, in one `submit` event (051, the addendum on images).

## Images

A row that carries images draws each raster one as a thumbnail, on both pages.
`session_view/transcript_image` names them (a row's key and a position) and
`view/lane` draws a `<details><img>` whose `src` is
`<session>/image/<row>/<position>`, relative to the page's address, so the
policy's `img-src 'self'` admits it and no `data:` or `blob:` source exists. The
daemon answers `GET /ui/p/<key>/sessions/<id>/image/<row>/<position>` after the
host, the shape, the fetch site (`same-origin` or `none`) and the page grant,
by asking the page's component whether it drew that image: the page socket
registers, under the page's cookie in `ui_sessions`, a function that sends the
component `ImageRequested` with `lustre.dispatch`. What comes back is checked by
`web_view/image.serve` (a raster type, base64 that decodes, at most 20 MiB, and a
magic number that says the type) and sent with the view's headers, so the browser
draws what was checked.

An operator's composer draws `<loom-attach>`, which reads files and pasted images
in the browser and submits them as one form field, a JSON array of base64
strings, with the draft. `component.submit` runs `web_view/image.admit` on them,
which reads each type from its bytes and bounds the count and the total, and the
prompt goes out as `prompt_content` through the shared step. One bad image
refuses the whole prompt with a notice.

The role does not change while a page is open. The relay's binding
carries the capped role, and its `check` recomputes the same minimum from
the current membership record at every request and every push. The
gateway refuses a frame unless the answer equals the binding, so a
demotion, a removed membership or a revoked credential closes the page at
its next frame. A reload admits a page for whatever the record and the
ceiling allow then.

## The engine inside the component

The component is a host in ADR-014's sense: it reads what the engine may
not read and performs what the engine decides, and it holds no session
logic. Its model is two records, as the terminal's is. `shared` is
`session_view/model.Shared(socket, Nil, Nil, Nil)`, the session state the
shared step reads and writes; the component has no recorder and its two
inboxes have no sources to tell apart, so the last three handle parameters
are `Nil`. `view` is what only this host holds. The component writes
`shared` in two places, both the page's own: it trims the history window to
the rows the page draws, and it marks the window as wanting older rows.

**Delivery.** Delivery is event-driven (ADR-013, the addendum on
event-driven delivery; [delivery.md](delivery.md) traces it end to end).
The selector's mapping for the relay's inbox drains the inbox behind the
frame it matched, up to `arrival_batch` (64) frames, and builds one
`Arrived(messages)`. `update` turns it into two step messages in one
Lustre message: `step.update(msg.Arrived(..))` files the frames into the
record's `session_view/inbox` and reduces nothing, and a `Ticked` input
then drains every filed frame to the lane, oldest first, and ticks the
lane. One burst is one message, and so one render: Lustre renders, diffs
and broadcasts once per message whatever the message changed
([lustre.md](../lustre.md#an-empty-reconcile-is-still-broadcast)), and
`delivery_test` counts the patches a burst costs.

There is no periodic tick. After each transition `component.rearm`
cancels the timer it armed before and arms one `process.send_after` for
the lane's `session_channel.next_due`: the in-flight deadline, or the idle
refresh, which is 250 ms until the daemon has pushed a frame and
`pushing_refresh_ms` (5 s) after (see [delivery.md](delivery.md)). The
daemon pushes the roster to a page when it subscribes
([protocol-change/054](../../protocol-change/054-roster-push-on-subscribe.md)),
so a page moves to the 5 s refresh at attach even on a quiet session. When
the timer fires, `Ticked` runs the same tick. An idle page wakes once
every five seconds, where the 250 ms tick woke it four times a second.
`Opened` adopts the lane and ticks, so frames filed before the lane
existed are drained in order.

**Time.** `component.update` reads the transport's clock once, at its top,
and every step the message takes runs at that reading, as the terminal's
`runtime.message` stamps each input once. The step reads no clock: the
messages it is given carry the reading as a `msg.Stamp`, and the shared
record stores it. The component's own messages carry no reading, and
neither selector mapping reads a clock: `update` takes the reading when it
takes the message. The one host action `update`
performs is arming the timer, because its `Timer` handle has to stay in
the model for the next arming to cancel. Tests give the transport a
settable clock (`page_fixture.clock`).

**Commands.** `component.submit` refuses empty text and text over 256 KiB
(`prompt_limit`) with a notice, since those are the page socket's limits.
It then parses the draft with `command.parse_with_skills`, as the terminal
does. A `command.Session` goes to the shared step as `msg.Submit`, run by
`commands.act`, so `/compact` is a compaction and `/model`, `/fork`,
`/goal` and the rest run as they do in the terminal, and an unknown
command is refused as the terminal refuses it. A `command.Surface` is
refused with a notice and never sent, and so are `/add-dir` and
`/add-write-dir`, which name a path on the daemon's host that a browser
reader can neither see nor pick (`component.page_command`). The page loads
no skills catalogue, so a skill's slash command is refused as unknown until
it does. `component.decide` finds the pending record with exactly the drawn
escalation ID and sequence (`operator.drawn`) and hands the step
`msg.Decide`, which encodes an `approve` or a `deny` that echoes that
record's action digest, grants and `expected_seq`. A record that moved after
its card was drawn is not decided, and the page says so. A decision takes
the same refusals as any mutation (`outbound.mutation_refusal`): it is
refused when the strand is unknown, when no conversation is attached, and
when the lane cannot take a mutation (`session_channel.mutation_available`:
another mutation is in flight, the queued slot is taken, the attachment is
read-only, or the lane has not synchronized). The card stays and the
operator presses again. On a synchronized lane a read in flight does not
refuse it, and the lane queues the decision behind the read. The lane
itself refuses a mutation when the attachment's role is observer
(`session_channel.can_mutate`), which is a third layer under the
component's type and the gateway's role check. The step leaves the facts a
command recorded on the record; the component reads `DraftTaken` to know
the command consumed the composer's draft, then drops them
(`step.forget_surfaces`).

**The composer and its notice.** The editor is drawn inside
`<loom-composer>` (`packages/web_client`), which lists the slash commands as
the draft grows (`web_view/completion` builds its table from the terminal's
suggestions, less what `component.page_command` refuses), sends the draft on
Command or Control with Enter by submitting the form, and puts a prompt the
daemon handed back into the editor. None adds a handler or a socket event.
The page's notice is an outcome, not the shared record's notice: the
refusal the page made, else the daemon's reply to the last command
(`Shared.answer`), else what the step worded when the page ran it. A
returned prompt is taken from `Shared.returned_drafts` at the end of every
message and kept, with a number, for the element (protocol-change/051, the
addendum on the composer's element).

**Effects.** The step returns the effects it decided, and the component
performs them through the transport inside one `effect.from`, in the
order the step decided them: `Transmit(socket, frame)` writes a frame and
`Shut(socket)` closes the relay. The component holds no recorder, so the
step never queues a `Note`. The interpreter has the shape of the
terminal's `tui/terminal_lane.perform`.

**What the page draws.** `component.refreshed` runs at the end of every
message and derives what the page draws from the shared record. It
compares what each projection was built from and rebuilds only what
moved. The blocks and turns are rebuilt when the capture, the history
window, the cache notices, the agent rows or the paging differ from the
inputs of the last projection (`Projected`), and the strip when its inputs
(`Stripped`, less the roster's clock) or a cache label it draws did. The
record's `render_revision` is not the signal. It moves for stream fragments,
which change the live region and nothing a capture projects, and for tool
tails the page does not draw, and a page that re-projected on each would
project once per batch of a streaming answer. The comparison
is of state, so an unchanged input is the same term and costs a pointer
check, and a change of paging forces a reprojection without a `before`
record. A projection folds the history window's branch into keyed blocks
for `main` with `transcript.branch_blocks`, keeps the newest turns that fit
the row limit (below) and lays them out as `turns.Piece` values. Only
durable records are in the blocks; the response still being written is the
live region, below. The page draws no tool tail. After a `history` read is answered, refused or abandoned, the window
is still in the reading mode `history_view.older` set, which the terminal
leaves until its reader scrolls back; `refreshed` resumes it and folds
the newest capture in.

**The live region.** Between a request going out and its answer
committing, the page would say nothing for as long as the model takes. It
draws what the terminal draws for that interval, from the same state: the
shared record's `streams` for the followed strand
(`transcript_lines.display_streams`, which also seeds a stream from the
capture's sampled preview when the page attached mid-answer), the
summarizer's `summaries` for the request's headline (protocol 050), and the
generation clock. No read and no socket event is added. `component.live`
turns them into `live.Row`s and `view/live` draws them as the last entry of
the lane's keyed list, keyed `live`:

- a reasoning row, `12 lines · <loom-elapsed> so far`, or with a headline
  the same count and clock and the headline as text beneath. The thinking
  itself is never drawn. The time is a `<loom-elapsed offset>` in
  milliseconds since the generation clock started, so the browser counts the
  seconds and the server renders again for a fragment and not to move a
  clock (the chips' mechanism);
- the answer so far, drawn as the lane draws an assistant line, Markdown
  parsed into text nodes.

A tool call the model is composing is not drawn; the capture shows it as a
running call. The region carries `aria-live="off"` so the polite log does
not read an answer out as it grows, and the committed row that replaces it
is announced once.

The hand-over is exact. A pushed entry clears the strand's streams in the
shared record before the capture that gives the page the row, and a page
that drew only what the record holds would show a gap. `component.streamed`
therefore keeps the streams it last drew when the record has none, while
`transcript_lines.response_awaited` says their answer is still owed: the
request's identity names the entry it reserved (`stream_identity`), the
window the page projects does not hold that entry, and the capture still
shows the operation running on the strand. When the capture holds the entry,
the row replaces the region in the same patch, and the keyed list places it
where the region was. When the capture says the operation ended without the
entry (an interrupted answer), the region goes. A request that reserved no
entry (an older daemon) leaves with the record's streams. A stream whose
entry the window already holds is dropped, so a capture that lands before
the push cannot draw the answer twice. A page that attached mid-answer keeps
the capture's sampled preview until the pushed text is at least as long,
where the record alone would shrink the answer to the first fragment.

The patch cost is the region's, and the committed rows do not enter it.
A fragment changes `Shared.streams` and nothing a capture projects, so
`refreshed` projects nothing and every committed line's memo holds
(`live_test` counts the lines a render draws: the live answer's one, and
none of a page's 150). Lustre replaces the text node of the paragraph being
written, so a fragment's patch is that paragraph and a fixed envelope. The
patch does not grow with the answer or the page. Measured in `live_test`
with Lustre's own diff, one fragment of a stream of 120 sentences (paragraphs
of six, about 50 bytes each) costs 107 to 268 bytes on a page of 150 rows, and
the same within two bytes on a page of one; and in `delivery_test` on the
real runtime, a burst of eight fragments is one patch of 576 to 668 bytes and
the burst that opens the region 864. The worst case is a single paragraph as
long as the stream's limit, 24 KiB (`live_stream_limit`), sent again for
each batch.

**What the step does for surfaces the page lacks.** The page runs the
shared step and so does what the step does, including reads for surfaces
it does not draw. After a first capture it reads the strand's notes, to
seed a todo board, which the todo panel draws, and then the session's context, the
advisor's pending nudges and the goal, each when the one before is
answered; it reads the context again when an operation ends and when the
configuration changes. Ten seconds after it opens, and then on a tick at most every ten seconds, it also reads the followed
strand's live jobs for the Session pane (the lane also asks for them whenever a run's completion changes; the delay keeps the startup reads the same as the terminal's):
`live_jobs` is one of the gateway's read-only commands, every role may send
it, and its answer is a snapshot the lane folds like the others, so it adds
no page event. That is four round trips at load that hold the
lane's one command slot, and a context read the daemon answers with a
branch scan on each operation, for every open page. Ruling 12 of the step
extraction design chose that over choosing which reads a host has a
surface for. The step's tick leaves out the block-summary read, because
the daemon may run a summarizer for a label it is asked for and the page
draws no labels. The composer's notice line shows the outcome of the
last command, not the shared record's `notice`, so "notes sent" after that
first read and "streaming text" during an answer do not appear there; only
the page's own refusals are drawn as warnings. The facts a
fold records for surfaces the page lacks are dropped with
`step.forget_surfaces`. That includes a held prompt the daemon hands back
(protocol-change/038's custody return): the page has no editor to put it
in, so the operator does not see it, and it is the prompt's last copy.

## Paging older history

The page holds a bounded number of transcript rows, so its memory does not
grow with the session. Lustre's server runtime keeps every element it
rendered, to diff the next render against, and a row of rendered Markdown
retains several times what a plain row does: 600 Markdown rows held 6.7
MB where the same rows as plain text held 2.5 MB (#587).

**The window.** The page holds the newest `component.live_rows` (150) rows
of `main`. The rows are cut between turns (`turns.grouped`), so the oldest
row the page holds is a turn's input. A turn keyed by its input keeps its
key when rows are added above it or the oldest turn leaves, and its lines'
memos are reused (`lane_memo_test`). When a new capture brings rows, the
oldest turns leave the page. The one exception to the turn boundary is a
single turn longer than the limit, which the page holds from its newest
blocks back. Once rows are cut, the history window is trimmed to the
oldest record the page draws (`history_view.retain_from`), so each capture
projects only what the page draws and the records the capture adds. The
end of a turn whose input is older than the window is not drawn but stays
in the window, so the next read asks for the sequences below it; a turn
longer than one read then arrives over several reads, and is drawn once
its input does. When that end alone no longer fits in the room left, the
page counts the turn as cut. A read that finds none of the strand's
records, because other strands wrote every sequence in it, still moves the
next read below it (`history_view.capture` keeps the progress `accept`
made).

**Load older.** Above the oldest row the lane draws `lane.Top`: the
beginning of the conversation, a "Load older" button, "Loading older
rows…" while a read is out, or a line saying the page is full. The button
sends `component.OlderRequested` on both pages, which `component.older` turns into
`history_view.older`: the history window asks for the interval of at most
100 sequences below its oldest record. The page sends that as a `history`
read on its own lane, the read the terminal pages with
(`session_channel.history`), and the lane's `HistoryPage` update is folded
back with `history_view.accept`. The lane has one request out at a time:
when it is busy the demand stays `Wanted` and is offered again after every
reduction until the lane takes it, and a second press while a read is out
asks nothing. While the read is out the history window is frozen, so a
capture that lands meanwhile cannot move the endpoint the reply is placed
against; the reply, or a refusal, resumes it and folds in the newest
capture.

**The cap.** Loading older rows raises the page's limit to
`component.held_rows` (300). The page still holds the newest rows, so new
rows keep arriving at the bottom. When the page, paged, has to cut a whole
turn to stay within 300 rows, it is `Full`: it keeps its newest 300 rows
and loads no more, and the lane says so. The page refuses rather than
dropping its newest rows because dropping them would stop it following the
session and need a second mode to return to the tail, which the terminal
has and the page does not.

**Keeping the reader's place.** Rows loaded above the reader would move
everything they are reading down by the height of what arrived. The
stylesheet turns the browser's scroll anchoring off for the transcript, so
the page keeps the reader's place itself. `<loom-follow>` hears the click on
the button (it carries a fixed `data-loom-older` marker) as it hears a
fold's toggle: it becomes `Reading`, so the growth that follows does not
scroll to the tail, and it holds the lane's first row and its position on
screen. When that row stops being the lane's first, the older rows have
arrived, and it scrolls the transcript by however far the row moved. This
is the one place the reader's place is kept.

**Observers.** A `history` read is a read. The gateway admits it for an
observer's binding (`gateway.read_only` lists `History`), and the lane
sends it on any attachment (`session_channel.history` checks no role).
Protocol-change/051's addendum on history paging lets the observer's page
carry this one handler: the button's message is `component.OlderRequested`
on both pages, and the page socket admits from an observer a `click` at
`component.older_path` and drops every other frame
(`ui_socket.observer_accepts`). `page_events_test` pins that the
observer's rendered view registers that handler at that path.

## Strand focus and the session sidebar

**Focus.** Each chip of the agent strip is a button whose message is
`FocusRequested(name)`, built from the name the strip was drawn with, so a
browser's click chooses among the chips and cannot name a strand. The
component runs `step.focus` (the terminal's change of strand less its
surfaces: cancel the lane's unsent frames, `commands.focus`,
`commands.load_strand`), drops any history read owed for the strand being
left, and restarts paging at the newest rows. The projection, strip, todo
panel and composer then read the active strand instead of `main`. It is a
change of what the page reads and sends no command, so it is on the
observer's page as well; the gateway and the lane refuse an observer's
mutation as before, and an operator's prompt, steer, queue and commands go
to the strand on screen. The socket admits an observer's click beneath
`component.strip_path` (051, the addendum on strand focus).
`focus_test` covers the behaviour and `page_events_test` the paths.

**The sidebar.** `ui_socket` gives the component `Transport.sessions`, the
authorized catalogue read the terminal's session picker uses
(`manager.authorized_page`) made with the page's credential digest, so a
member sees only their own sessions and a revoked credential none. The
component reads it when the page opens and at most every 30 seconds on a
tick (an observer's page is given an empty list and draws no sidebar, so a
stolen observer link does not disclose the principal's other sessions),
groups it by workspace (`web_view/sessions`), and `view/sidebar`
draws it as the frame's second child (the left column). The row of the session
on screen also carries one thin bar per live strand in the strand's hue, drawn
from the strip the page already has and pulsing while the strand works; the
bars are decoration with no handler and no focus. An empty `nav` child sits
above the first group for the app's navigation. The entry carries
name, workspace, creation time and residency, and nothing of the registration's
path, key or configuration.

## Switching sessions

A page is bound to one session by its key, cookie and nonce, so opening another
session is a navigation to a new page (051, the addendum on switching
sessions). Only an operator page does it.

- **The request.** On an operator page a sidebar row for a running session
  other than the one on screen is a button (`view/sidebar`, beneath
  `component.sidebar_path`), and a peer message in the lane has an `Open <name>`
  button when the session it names is one of the principal's listed running
  sessions (`component.openable`, `lane.Replies.open`). Both send
  `operator_page.Opening(id)` with the catalogue's identity.
  `component.switch_to` calls `Transport.open`, and the daemon's answer returns
  as `Linked`.
- **The daemon.** `ui_socket.ticket_for` runs the checks afresh with the page's
  credential digest: a canonical identity, `manager.session_authority`
  (membership), `manager.get` (resident), then `ui_sessions.mint` with the
  page's principal and its own ceiling. `ui_socket.opened_for` refuses an
  observer page without asking. The answer is `sessions.Ticketed(path)` or
  `sessions.Declined(reason)` with the fixed words of `sessions.reason_words`.
- **The browser.** A ticket becomes `component.departure`, which the operator
  page writes into the `to` attribute of the hidden `<loom-switch>`, the
  centre's last child. The element accepts only
  `/ui/sessions/<identity>?ticket=<64 hex digits>` (`switch_rule.target`) and
  calls `location.replace`, so the old page leaves no history entry. The exchange, the keyed page and the nonce are the
  ones `loom ui` already uses, and the page left behind is not ended.
- **What holds.** A page for one session holds no text of another
  (`session_isolation_test`); the sidebar is the one region that lists the
  others. The observer's socket drops a click beneath `component.sidebar_path`.

## Inviting from the session page

An owner's operator page has one control that a member's page and every
observer's page lack: "invite to this session" (051, the addendum on inviting
from the session page). It is the last child of the Session pane, at
`component.invite_path`.

- **Who has it.** `ui_socket.role_of` gives a page the role `Owning` when its
  authority is operator and its principal is the daemon's owner. Only `Owning`
  gets `Transport.invite`; the component draws nothing and ignores the message
  without it. The socket admits a click at or beneath the path only for an
  owner (`owner_accepts`), `invite_for` reads the principal again, and
  `manager.administer` authenticates the credential as the owner a last time.
- **The request.** Two buttons, observer and operator, send
  `operator_page.Inviting(role)`; a third, "Hide the token", sends
  `Dismissing`. `component.invite` moves the control from `Ready` to `Asking`,
  and the daemon's answer returns as `Invited`. A press while a request is out
  or an invitation is on screen asks nothing.
- **The daemon.** `ui_socket.invite_for` checks that the page is still open and
  that the principal is the owner, takes one of the credential's three
  invitations an hour (`ui_sessions.reserve_invite`), and runs
  `manager.Invite` for a new `guest-` principal in the page's own session with
  a claim that lives an hour (`server.claim_enrollment`). The answer is an
  `invites.Invitation` or a `Declined` reason with fixed words.
- **The browser.** The control shows the role, the principal, the lifetime, the
  command and the token, and the words for handing them over. The command and
  the token are each a `<loom-copy>` box (`subject` and `text` attributes),
  which draws its text and copies it to the clipboard only when it has exactly
  the shape the daemon writes (`copy_rule.text`).
- **What holds.** The token is in the component's state only while the
  invitation shows and is dropped when the owner hides it. It is not in the
  session's transcript, the shared record, a log, a URL, the catalogue (which
  holds its digest) or another page. A stolen owner page can mint three
  invitations an hour for its credential, and each is a membership that
  outlives the page; 051's addendum prices that.

## The home page

Protocol-change/065 and `docs/design-notes/web-workspace-mode.md` add a page
bound to no session: the principal's home, which lists the sessions the
credential may see, grouped by workspace, with resident and saved marked.
`loom ui` with no `--session` sends `ui.link` without a `session_id`
(an operator's page unless `--observe`; `loom ui --session ID` keeps its
observer default) and prints `/ui/home?ticket=<t>`.

A `ui_sessions.Grant` now names a `Scope` (`Session(id)` or `Home`) and a
`Reach` (`OneSession` or `Workspace`; only a later change reads it). The
scope is part of redemption: a session's ticket at the home exchange and a
home's at a session's are each spent and refused (`OtherScope`). The page cap
(`max_pages`) is counted per principal and per scope, and a home lives
`ui_sessions.session_ms`, as a session page does. The router adds `GET /ui/home`, `GET /ui/p/<key>/home`
and `GET /ui/p/<key>/home/ws`, checked in the session routes' order against a
`Home` grant (`server.home_grant`); there is no membership check, since there
is no session. One function (`server.entered`) builds the exchange response
for both kinds of ticket.

The socket (`ui_socket.upgrade_home`) shares `websocket` with the session
page and starts `web_view/home` with no relay. The component draws the A2
frame with the sidebar (`sidebar.home`, a "Home" entry above text rows), a
table per workspace (`view/home_table`), and no strand panel (the frame class
`loom-home` hides the panel column in the stylesheet). It reads the sessions
with the page's credential digest when it opens and every 30 s
(`ui_socket.home_listing`); that read is also the page's check: a UI session
that ended or a credential that no longer authenticates answers `Closed`, the
page draws the home's words (`ending.home_headline`, `home_advice`) and
the socket closes. The read runs in the component's process, as the
sidebar's does. The view attaches no handler and the socket admits no browser
frame (`ui_socket.home_accepts`).

## Expanding a row

The terminal's `Ctrl+g` expands every row at once; the page lets the reader
expand one. A code-mode call whose program succeeded shows only its summary
and a result line, and a reasoning block shows its opening line, so the
program and the reasoning could not be read from the page.

The full text is already in the model. When `component.relaned` projects a
capture it asks `turns.pieces` for the terminal's own expanded rows, cut by
the page's budget, and stores them on the pieces: `Step.full` for a call,
`thoughts` for a reasoning row. They are built once per projection, not per
render, and no piece holds the uncapped text. A step reads as one line
(`session_view/step_words`: `Edit calc.py +3 −1`, `Memory · 4 lines`,
`Reasoning · 4s`), and `view/fold_row` draws a row that has a body as
`<loom-expand>` holding the line in a child marked `slot="head"` and the body
in one marked `slot="body"`. The element draws the row's one chevron, so a
turn of ten steps has ten chevrons and no "Expand" buttons, and a row with
nothing behind it has none. The body is the full form when the page holds one.
A button in the element's shadow root shows or hides the body. That choice is
the browser's alone, as a fold's is: no read, no page event and no new entry
in the socket's accepted list, so it works on an observer's page, and the
server never renders which rows are open, so a later patch leaves the reader's
choice alone. The alternative, sending the expanded row on request, would need
a new event and a round trip for text the page already holds.

The cost is that every body is in every viewer's document whether or not
anyone opens it, so each expanded row is cut to 300 lines or 8,000
characters (`view/expansion`), with one line after a cut row saying so. The
terminal shows all of it. The element emits the fold's toggle event, so
`<loom-follow>` treats an expansion as the reader's doing: the reader at the
bottom who expands the newest row keeps the button in view instead of being
scrolled past it.

The heading's status reads "connected" (it read "following"). It is the
connection's state, and the word was mistaken for the scroll state, which
only `<loom-follow>` knows.

### A page with no session says why

A page can be without its session because a newer link replaced it, its
eight hours ran out, its access was revoked, the session stopped, the
daemon has not opened the session yet, or the daemon was not ready. Each is
one variant of `web_view/ending.Ending`, and everything the page says about
it is a fixed string chosen by the variant; a reason that names none is
drawn as a failed connection, so no text from a peer reaches the browser.
Three places draw it:

- **A live page that ended** draws a notice inside its heading
  (`view/ended`): the headline and what to do, usually to run
  `loom ui --session <id>` for a fresh link. The last transcript stays under
  it, and no region after the heading changes its path.
- **A reload of an ended page**, and a ticket that was used or expired, get a
  small document for the ending (`page.refusal`) under the status they always
  had, in place of the bare status text.
- **A page that never connects** shows a fixed paragraph the shell puts inside
  the `<lustre-server-component>` element. It is the element's light-DOM
  content, which Lustre's runtime hides when it attaches the shadow root on
  the first tree, so it is on screen exactly while the page has no session.
  A refused WebSocket handshake shows the browser nothing but a failure, so
  the shell is where a refusal can be explained.

What it does not do: a tab that had mounted and then lost its socket (the
daemon restarted, the network broke) keeps its last transcript with no
notice while the client runtime retries, because nothing in the browser
tells the two apart. Protocol-change/051's addendum on an ended page lists
what was considered and why a client element was not added.

## Security layers

The page is served from loopback, and loopback does not protect a page:
every other page the browser loads can reach it, including through DNS
rebinding, and any program on another loopback port receives cookies for
the host. Protocol-change/051 sets the threat model. The case that matters
most is the session's own agent, whose tools can reach the loopback
listener unless the session runs with `--network off`, trying to drive an
operator's page and answer its own escalations. Each layer below stops a
named attack, and several are independent, so that any one of them alone
keeps a page from acting.

| Layer | What it stops | Where |
|---|---|---|
| `--ui` flag | Any `/ui` surface on a daemon that did not ask for one. | `client/daemon/main`, `server.handle` |
| Loopback `Host` | DNS rebinding: an attacker's page reaches the listener under its own host name and gets `403`. | `ui_http.loopback_host` |
| Single-use ticket | A replayed or forwarded link. 60 s, redeemed once inside one actor, digest stored, minted only for a member. | `ui_sessions.mint`, `ui_sessions.redeem` |
| `Sec-Fetch-Site` | Another site, or another loopback port, driving the exchange or navigating to the keyed page. Only `none` and `same-origin` pass. | `ui_http.navigation_allowed` |
| Cookie attributes | Script reading the cookie (`HttpOnly`) and cross-site requests sending it (`SameSite=Strict`). No `Max-Age`; the UI session lives 8 hours. | `ui_http.set_cookie` |
| Page key | The cookie reaching other ports. Its `Path=/ui/p/<key>` means a browser sends it only to a path holding the key. The unkeyed page route is `404`. | `ui_http.route`, `page_grant` |
| Page nonce | A server on another port that learned the key. The nonce is delivered once, in the exchange body, and kept in `sessionStorage`, which is scoped by port. The socket compares its digest in constant time. | `page.enter`, `ui_sessions.admits` |
| `Origin` on upgrade | A page on another origin, including another loopback port, opening the socket. It must equal `http://` and the request's `Host`. | `ui_http.origin_matches` |
| Credential and membership | A page outliving its authority. Every page request re-authenticates the minting credential and its membership, and the gateway re-checks at every frame. | `page_grant`, `ui_relay.while_open` |
| Role ceiling | An operator's power by default. A page is an observer's unless minted with `--operate`, and never above Operator. | `ui_relay.capped` |
| Component type | An observer's page sending a command. Its `Msg` has no command and its view one handler, the "Load older" read; the socket admits only that click at its fixed path and drops every other frame. | `web_view/component`, `ui_socket.observer_accepts` |
| Approval card rules | Tricking the person into approving (below). | `web_view/operator_page` |
| Text only | Script injected through session content. Session text is drawn only as text nodes; no attribute, handler, key or URL is built from it. An answer's Markdown becomes fixed elements from a closed tree, and a link's destination is text. | `web_view/view/lane`, `web_view/view/strip`, `web_view/view/todo_panel`, `web_view/markdown_view`, `web_view/operator_page` |
| Response headers | Inline script and style, framing, `Referer` leaks of the ticket and key, caching. | `ui_http.secured`, `page.content_security_policy` |

The approval card follows its own rules, because it is where an agent
would try to trick the person into approving:

- It is drawn from the escalation record alone
  (`approval.presentation`), never from transcript text, in a region
  that transcript content cannot occupy, and in a style no transcript
  line uses. The region sits directly above the composer in the dock, the
  footer at the bottom of the page's pinned frame, so a pending card is on
  screen wherever the operator has scrolled the transcript. A card
  appearing grows the dock upward, shrinks the transcript by as much, and
  leaves the composer's controls where they were. For 600 ms after a card is
  inserted its buttons refuse clicks and are drawn dimmed (a CSS
  animation on the action row's `arming` class), so a click already
  heading for the bottom of the transcript cannot land on Allow (051, the
  addendum on the pinned composer).
- Deny comes first, each button names the tool ("Deny bash", "Allow bash
  once"), nothing has `autofocus`, and a new card never takes focus.
- Enter in the composer is a newline. A draft is sent by the form's own
  Send, Queue or Steer button, or by Command or Control with Enter in the
  editor, which submits that same form; the form's submit never carries a
  decision.
- The page offers allow once and deny. Allow for the session is left out,
  because a remembered grant outlives the page that gave it.
- Cards are keyed by the record's sequence, so a click in flight while the
  list shifts reaches the same card or none.

What the layers do not defend: a process that can read the browser's
profile gets the cookie, and with the key and a live tab's nonce, an
operator's page for one session for up to 8 hours or until revocation.
`loom ui --open` passes the ticket in the opener's argument vector,
which other local users can read with `ps` while the opener runs; printing
the link without `--open` avoids that. A daemon restart ends every UI
session, since the tables live in memory.

## Lustre specifics that shape the code

Four properties of Lustre 5.7.1 decide the shape of `web_view`. Each is
covered in full in [lustre.md](../lustre.md).

- **`effect.batch` does not order its effects, and the server runtime
  performs them in reverse.** The lane's outputs must leave in the order
  the lane decided them, so `component.perform` runs the whole list inside
  one `effect.from`. The component uses `effect.batch` only for effects
  that do not depend on each other: in `init`, opening the transport and
  selecting the timer; and in `Opened`, the subscribe the lane wrote and
  whatever the first reduction wrote after it
  ([lustre.md](../lustre.md#what-differs)).
- **`init` and its effects must finish within a 1000 ms start timeout.**
  The gateway's attach can take longer, so the transport's `connect`
  starts the relay and returns at once, and the relay attaches as its own
  first message and answers on a subject the component selected in `init`
  ([lustre.md](../lustre.md#process-model)).
- **A browser event names its target by path, and a path segment is the
  child's key.** Lists whose items change are keyed by identities the
  engine owns: the transcript by `transcript.Row.key`, which names the
  durable sequence, block and line a row came from; approval cards by the
  record's sequence; and the composer's editor by the count of drafts that
  left it (`component.drafts`: the ones the lane sent and the ones a
  command consumed), which is how the uncontrolled editor is emptied after
  a send
  ([lustre.md](../lustre.md#only-events-you-attach-can-arrive)).
- **Every message runs `view` on the whole model and diffs the whole
  tree.** Nothing skips the render when the model did not change, and an
  idle page receives a patch per message, which is why arrivals are
  batched before `update`. So the rows are projected only when an input
  of the projection moved (`refreshed`), and the lane draws every transcript
  line and card body inside its own `element.memo`, so a capture draws,
  parses and diffs only the lines that are new. The memos are the lane's
  leaves with no memo around them, and a turn's work is keyed by its
  input, because Lustre forgets memos nested in a memo that hit and
  redraws a keyed subtree whose key changed
  ([lustre.md](../lustre.md#cost-of-a-message-and-sizing)).

Two further rules come from the runtime's process model: every
`server_component.select` runs once, from `init`, because a selector added
later is never removed; and the socket sends `lustre.shutdown()` when the
browser goes away, because a runtime outlives its last client.

## What is not built yet

- **Remote access.** A page reached through a TLS proxy at a listed
  origin, with a `__Host-` cookie and a `wss:` policy, is
  [protocol-change/052](../../protocol-change/052-web-view-remote-origin.md),
  proposed and not implemented. Today a remote person reaches the page
  through `ssh -L`, which presents a loopback `Host`.
- **Accepting or dismissing an advisor nudge.** The card shows the queue and
  offers no action. The wire has one operation on it, the read-only
  `advisor_pending`, and the primary's next run start is the drain, so an
  accept or a dismiss needs a new gateway command and a protocol change.
- **The rest of the page's features.** The page runs the shared step, and
  what it draws is a small part of what the step knows. Part 2 of
  [issue #569](https://github.com/Roasbeef/loom/issues/569) builds the
  page out: strand focus and the session sidebar, among others. History paging is built on the shared record's `scrollback`
  (`history_view.State`); the row limit and `Paging` stay the page's view
  state.
- **One strand, one session.** The page shows and addresses `main`. The
  routes already carry the session ID, so a later page can mount one
  component per session or agent.

## Where the code lives

| Path | What it owns |
|---|---|
| `packages/web_view/src/web_view/component.gleam` | The observer's application: the shared step's host, event-driven delivery (a batch per burst, one timer for the lane's next due reading), the clock read once per message, `submit` and `decide` wrapping the operator's inputs as the step's commands, the history read `older`, `refreshed` deriving the row window (`live_rows`, `held_rows`, `Paging`) and the strip from the record, and `view`, which lays out the regions below. |
| `packages/web_view/src/web_view/ending.gleam` | `Ending`, the closed reason a page has no session, with its fixed headline and advice, its reason string (the relay's hop to the component) and its close code (`Final` or `Retry`). |
| `packages/web_view/src/web_view/view/ended.gleam` | The notice a page draws from an `Ending`, inside the heading. |
| `packages/web_view/src/web_view/view/heading.gleam` | The top bar: the brand, the session's workspace and name, the connection's status and the context and cost estimates, drawn from plain values the component hands it. |
| `packages/web_view/src/web_view/view/shell.gleam` | The page's frame, `<loom-shell>`, and the order of its four children: the top bar, the sidebar, the centre column and the strand panel. The `sidebar` attribute is written from the `Sidebar` type, and `workspace` carries the digest the daemon computed, for the browser's saved layout. |
| `packages/web_view/src/web_view/view/panel.gleam` | The strand panel, the right column and the frame's last child: four panes, always all drawn, the Strands pane (a title and the strip's cards), the Changes pane, the Session pane and the Trace pane. `<loom-shell>` draws the tabs and shows one pane; the panel carries no decision control. |
| `packages/web_view/src/web_view/view/strip.gleam` | The strand cards (the agent strip's old name) and their `Strip` and `Chip` types: each card a ring, a name and one status line, with `data-loom-card` for its position (`positions` numbers the cards for the cards and the lane), and the hue, ring and status classes. |
| `packages/web_view/src/web_view/view/strand_detail.gleam` | A strand's own view in the Strands tab, while a strand other than `main` is in focus: the back link (a marker, no handler), the ring, name and status line, the figures a card leaves out (model, context, cache, running) and the tools it ran lately. |
| `packages/web_view/src/web_view/view/crumb.gleam` | The breadcrumb above the transcript while a strand other than `main` is in focus: the session and strand names and an `All strands` link that is a marker, with no handler, and an `Esc` hint for the shell's key. |
| `packages/web_view/src/web_view/view/sidebar.gleam` | The session sidebar: the principal's sessions by workspace, memoized, the frame's second child. A row for a running session other than the one on screen is a button that asks to open it. |
| `packages/web_view/src/web_view/sessions.gleam` | The sidebar's `Entry`, `Residency` and `Group`, `grouped`, the ordering (current workspace first, newest first), `label`, and `Answer` and `Reason` with their fixed words, which a switch request and its refusal are made of. |
| `packages/web_view/src/web_view/view/todo_panel.gleam` | The todo panel: the followed strand's board as one line (`Todo · n of m done · <active task>`, a `<loom-fold>` summary) which opens to the phase that holds the active task expanded and the others folded into one row, the terminal's status glyphs, `n/m done`, and the reviewer band beneath it, drawn from plain values (`component.plan` reads the shared record's `todo_boards` and `reviewer_status.lines`). It is the operator's dock's first child and sits above the observer's bar; its height is capped and it scrolls on its own. |
| `packages/web_view/src/web_view/view/trace.gleam` | The Trace pane: the session's `code_mode` programs (`session_view/trace_view`), the newest with its state, result excerpt and a collapsed budget line, the earlier ones as rows, the panel's fourth pane after Session. It lists programs and says capability calls are not recorded yet; every string is a text node and it holds no handler. |
| `packages/web_view/src/web_view/view/changes.gleam` | The Changes pane: the files the session's own `fs_edit` results and `fs_write` calls named (a write is one hunk of added lines, `written · N lines`) and their diffs (`session_view/changes_view`), the panel's second pane on both pages, bounded and drawn as text nodes with a class from a closed row kind. It reads no worktree. |
| `packages/web_view/src/web_view/view/session_tab.gleam` | The Session pane: the goal, the followed strand's live jobs (the read-only `live_jobs` read the component makes on a tick, first ten seconds after opening and then at most every 10 s), on an operator's page only the attached viewers, and the estimated cost, as text nodes in the panel's third pane. |
| `packages/web_view/src/web_view/invites.gleam` | The invitation an owner's page may mint: `Role` (observer or operator, never an owner), `Invitation`, `Reason` with its fixed words, `Answer`, the control's `Share` state and `claim_ttl_ms` (one hour). |
| `packages/web_view/src/web_view/view/share.gleam` | The invitation control in the Session pane: two buttons, or the invitation with a `<loom-copy>` box for the command and for the token. Drawn on an owner's page only; the messages its buttons send are values handed in. |
| `packages/web_view/src/web_view/view/nudges.gleam` | The advisor's pending nudges, read-only, every body received as a text node and the count the server left out. It is drawn under the strand panel's panes on both pages and has no handler. |
| `packages/web_view/src/web_view/view/commentary.gleam` | The advisor's settled commentary, read-only: the request labels and full bodies the lane's hairlines stand for, drawn in the Strands pane under the strand cards as one closed `details` whose summary is `Advisor · N reviews · last: …`, the bodies as Markdown, newest three then a count, with the board's not-loaded line. No handler, and nothing while the advisor itself is on screen. |
| `packages/web_view/src/web_view/view/controls.gleam` | The operator's session controls: the goal row with its buttons and the Fork form (`session`, in the Session pane), and the dock's one goal line while a goal runs or is held (`dock`). It takes the messages its buttons send and the form's submit handler as values. |
| `packages/web_view/src/web_view/view/expansion.gleam` | The budget an expanded row is cut to (300 lines, 8,000 characters) and the line that says a row was cut. |
| `packages/web_view/src/web_view/view/lane.gleam` | The transcript lane: the line above its oldest row (`Top`, the "Load older" button), the keyed pieces as timeline rows with a dot in the strand's hue, the tags and dots that carry a marker for a listed strand (`Marks`), folded work, the cards, the advisor's one-line commentary hairline, and each transcript line and card body in its own leaf memo. |
| `packages/web_view/src/web_view/markdown_view.gleam` | The elements for an answer's Markdown, drawn from `session_view/markdown`'s tree: fixed tags, classes from closed types, every string a text node. |
| `packages/web_view/src/web_view/operator_page.gleam` | The operator's application: `Submitted`, `Decided`, `Controlled` and `Replying`, the uncontrolled composer and its total form decoder, the control forms' decoder, the approval cards. |
| `packages/web_view/src/web_view/page.gleam` | The shell, the exchange page, the two scripts, the stylesheet, the keyed paths and the content security policy. |
| `packages/client/src/client/daemon/server.gleam` | `/ui` routing and its check order, `ui.link`, and the `hello` `ui` field. |
| `packages/client/src/client/daemon/ui_http.gleam` | Pure request checks and response headers: route, host, `Sec-Fetch-Site`, origin, cookies. |
| `packages/web_view/src/web_view/home.gleam`, `view/home_bar.gleam`, `view/home_table.gleam` | The home page's component, top bar and per-workspace tables (protocol-change/065). |
| `packages/client/src/client/daemon/ui_sessions.gleam` | The ticket and UI-session actor: mint, single-use redeem, lookup, key and nonce comparison, sweep, and the page-minted invitations' allowance (three an hour per credential). |
| `packages/client/src/client/daemon/ui_socket.gleam` | The page's WebSocket: permit custody, the component chosen by role (observer, member operator, owner), frame filtering by role, the session ticket and the invitation the daemon makes for a page, shutdown. |
| `packages/client/src/client/daemon/ui_relay.gleam` | The relay into the gateway, the role cap, and the four ways a page ends. |
| `packages/tui/src/tui.gleam` (`run_view`), `packages/tui/src/tui/view_link.gleam` | `loom ui`: daemon resolution, `ui.link`, printing and opening the link. |
| `packages/session_view/src/session_view/step.gleam`, `commands.gleam`, `operator.gleam` | The whole-event entry `step.update` the component calls, the commands it runs, and what an operator's input becomes on the wire, shared with the terminal. |

Tests: `web_view/test/component_test` and `operator_page_test` drive the
components through `lustre/dev/simulate`; `paging_test` holds the row
window, the history read and its one-in-flight rule, the cap and the
refused read, through the page's real lane, and `lane_memo_test` counts
the lines a capture, a slide and a prepended page draw; `client/web_view_parity_test`
checks that the component draws the lines the terminal's projection draws
for the same capture; `client/ui_http_test`, `ui_route_test`,
`ui_sessions_test`, `ui_socket_test`, `ui_relay_test` and
`web_operator_page_test` cover the route's defences and the relay's ends;
`web_view/test/invite_test` and the invitation tests in `ui_route_test` cover
the owner's control.
