# Writing Loom's web view with Lustre

This guide is for people writing Loom's web UI: `packages/web_view`, the
Lustre server components that `loomd --ui` serves, and the daemon code in
`packages/client` that carries it (`client/daemon/ui_socket`,
`client/daemon/ui_relay`). It says how Lustre 5.7.1 works, where that
matches Loom's engine and where it does not, and what the house rules are
for code on this seam. Read [ADR-014](adr/014-second-runtime.md) and
[protocol-change/051](../protocol-change/051-web-view-route.md) first;
this guide assumes both. [The web view](architecture/web-view.md) is the
architecture map: the request path, the processes, and the security
layers.

Lustre is pinned at `== 5.7.1` in `packages/web_view/gleam.toml`. Every
claim below is about that version. When the pin moves, re-check section 8
before anything else.

**How claims are cited.** A claim from the documentation links the page it
came from. A claim from the source names the file and function, with a link
to the `v5.7.1` tag on GitHub; the hex package in
`packages/web_view/build/packages/lustre` is byte-identical to that tag.
A claim marked **(source)** was inferred from reading the code and is not
stated in the documentation. Links are collected at the end of the file.

**Where the documentation is thin.** The 5.7.1 guides cover client-side
apps, server-side rendering and deployment. The `lustre` module page lists
two more guides, `08-components` and `09-server-components`, but neither is
published for 5.7.1 (both return 404) and neither exists under
`pages/guide` at the `v5.7.1` tag. What Lustre documents about server
components is in the [`lustre/server_component`][doc-sc] module page, the
[server component examples][ex-sc], and the source. This guide leans on the
source for that reason.

## 1. The model Lustre gives you

### The loop

A Lustre application is three pure functions and a runtime
([`lustre`][doc-lustre], [state management guide][doc-state]):

- `init(arguments) -> #(model, Effect(message))` builds the first model.
- `update(model, message) -> #(model, Effect(message))` applies one message.
- `view(model) -> Element(message)` draws the model as a virtual DOM tree.

The runtime owns the loop. It calls `update` for each message, calls `view`
on the new model, diffs the new tree against the last one, and performs the
effects `update` returned. Lustre states that it "assumes your `init`,
`update`, and `view` functions are pure" ([pure functions hint][hint-pure]).
The guide's advice on messages is to name them for what happened
(`UserUpdatedPassword`), not for what to do (`SetPassword`), because
"communicating through messages is a way for the _outside world_ to talk to
our application, not for our applications to talk to themselves"
([state management guide][doc-state]).

### How it lines up with Loom's engine

Loom's client engine has the same four parts. ADR-013 describes the
terminal's; ADR-014 describes how the web host reuses them.

| Loom engine | Terminal host | Web host (Lustre) |
|---|---|---|
| Message: `msg.Msg` (`Arrived`, `Input`) | the terminal's own `tui/msg.Msg`, built by `tui/runtime` from etui events | `component.Msg` (`Arrived`, `Ticked`, and the operator's inputs), which `update` turns into `session_view/msg.Msg` |
| Step: the shared units over `model.Shared`; the terminal's `tui.step(msg, model) -> #(Model, List(Effect))` | called by `tui.update`, which calls the shared units one at a time | `session_view/step.update(shared, msg) -> #(Shared, List(step_effect.Effect))`, called from the component's `update` |
| Effect: `tui/effect.Effect`, wrapping the shared `step_effect.Effect` (the lane's `session_channel.Out`) | performed by `tui/runtime`, `tui/terminal_lane.perform` | performed by one `effect.from` in `component.perform` |
| Runtime: reads clocks, mailboxes, sockets; performs effects | `tui/runtime`, `tui/job_runner` | the Lustre runtime process, its `select` subscriptions, `ui_relay` |
| View | `tui/render` over etui | `component.view` over `lustre/element/html` |

The web host runs the shared step. `component.Model` is two records,
`shared` (`session_view/model.Shared`) and the page's own `view`, and the
component's `update` holds no session logic: it reads the clock, calls
`step.update`, derives what it draws from the record the step left, and
performs the effects (ADR-014, the addendum "the step moved into
`session_view`"). The terminal does not call `step.update`, which composes
the same units for a host with no surfaces of its own, and a test holds the
two to one order.

### What differs

**Lustre's effects are closures; Loom's are data.** A Lustre `Effect` is an
opaque record holding three lists of functions (`synchronous`,
`before_paint`, `after_paint`), and `effect.from` wraps a callback that
receives `dispatch` ([`effect.gleam`][src-effect-type], `Effect`, `from`).
Nothing can inspect one. Loom's `Effect` and `Out` are closed custom types
because a test must be able to assert "exactly one `Transmit`", and a second
host must be able to interpret the same vocabulary against its own
transport (ADR-013, "Decision" and "Alternatives considered").

**Lustre does not order a batch.** `effect.batch` "makes no guarantees about
the order on which effects are performed" ([`lustre/effect`][doc-effect]).
In 5.7.1 the server runtime in fact performs `batch([a, b])` as `b` then
`a`, because `batch` prepends each effect's tasks and `perform` walks the
list front to back **(source)** ([`effect.gleam`][src-effect-batch],
`batch`, `perform`). Loom's lane outputs have an order that the protocol
needs: frames on one socket leave in the order the lane issued them
(ADR-013, "Decision").

**Lustre effects run inside the runtime process, synchronously.** On
Erlang the runtime performs an effect by calling each task in turn inside
its own actor, including the effects `init` returns, which run inside the
actor's initialiser **(source)** ([`runtime.gleam`][src-rt-start], `start`
and `handle_effect`). A task that blocks, blocks the page: no message is
handled and no patch is sent until it returns. `dispatch` does not re-enter
`update`; it sends a message to the runtime's own mailbox, which is handled
after the current message **(source)** (same file, `handle_effect`).

**Paint effects do not exist here.** `before_paint` and `after_paint` are
ignored by server components: "There is no concept of a 'paint' for server
components. These effects will be ignored" ([`lustre/effect`][doc-effect]).
A server component cannot read or write the DOM at all.

### Loom's rule for the bridge

**The engine's `Effect` values are interpreted by the web host.** The
component's `update` calls the engine, takes the ordered list of effects it
returns, and returns one Lustre effect that performs that list in order
through the host's transport. Concretely:

- One `effect.from` per list, never one Lustre effect per engine effect
  inside `effect.batch`, because the batch would lose the order.
- The interpreter has the terminal's shape (`tui/terminal_lane.perform`),
  so a new engine effect is a new arm in one `case`, and the compiler finds
  the host that has not handled it.
- No engine decision is written as a closure. If the component needs to
  decide what to send, that decision belongs in `session_view`, where the
  terminal can use it too (ADR-014, "Decision").
- The effect body does not block. `transport.transmit` hands the frame to
  the relay process, which makes the blocking gateway call.

This is `component.perform` today, less the shortcut that returns
`effect.none()` for an empty list:

```gleam
// The lane's outputs are data. One Lustre effect performs the whole list,
// in the order the lane decided it, through the host's transport.
fn perform(
  transport: Transport(socket),
  outputs: List(session_channel.Out(socket, Nil)),
) -> Effect(Msg(socket)) {
  use _dispatch <- effect.from
  list.each(outputs, fn(output) {
    case output {
      session_channel.Transmit(socket:, frame:) ->
        transport.transmit(socket, frame)
      session_channel.Shut(socket:) -> transport.shut(socket)

      // The web host holds no recorder, so the lane never queues a note.
      session_channel.Note(..) -> Nil
    }
  })
}
```

When two effects that are not engine outputs must happen in order, do what
the effect docs say: sequence them in one effect, or dispatch a message
from the first and return the second from that message's `update`
([`lustre/effect`][doc-effect], `batch`).

### Event-driven delivery in Lustre terms

ADR-013's phase 3 addendum chose option C: arrivals are messages that are
only filed, and reduction happens at a tick or a key in a fixed order. Its
addendum on event-driven delivery revises that for both hosts, and in the
component it works like this. The selector that reads the relay's inbox
drains it in its mapping function: the frame it matched and up to
`arrival_batch - 1` more already waiting become one `Arrived`. `update`
reads the clock and files the batch and reduces it at once, in one
message: `step.update` with `msg.Arrived` files the frames, and with a
`Ticked` input every filed frame goes to `session_channel.receive` in
arrival order, through `operator.drain`, and `session_channel.tick` runs at
the reading. There is no periodic tick. After each transition the
component arms one `process.send_after` for the lane's
`session_channel.next_due`, cancelling the timer it armed before, and when
it fires `Ticked` runs the same reduction. `component_test` and
`delivery_test` pin the reduction, the batching and the timer.

The batching is there because of the next section's cost model: Lustre
renders once per message, whatever the message changed, so one message per
burst is the only way to get one render per burst.

### An empty reconcile is still broadcast

Lustre 5.7.1 has no guard for an empty patch. `EffectDispatchedMessage` in
the server runtime ([`runtime.gleam`][src-rt-loop], lines 273 to 283 of the
package's source) runs `update`, `view` and `diff`, then calls `transport.reconcile(diff.patch, ...)` and broadcasts the
result to every registered client, whether or not the patch holds a
change. Each message a component takes therefore costs a view, a diff and
one frame on every page's socket. Two consequences for this package:

- Messages that change nothing are not free. A timer that fires four times
  a second is four renders and four socket frames a second per page, which
  is what the old 250 ms tick cost an idle page.
- Coalescing belongs before `update`. By the time `update` runs, the
  render is already owed, so the batching has to happen where the message
  is built: in the selector's mapping, as `component.open` does.

## 2. Server components in depth

A server component is an ordinary Lustre application whose runtime runs on
the BEAM. A small client runtime in the browser applies the patches it
sends and sends DOM events back ([`lustre/server_component`][doc-sc]). "Lustre's
server component runtime is separate from your application's WebSocket
server": the application owns the socket and forwards messages both ways
(same page).

### Process model

`lustre.start_server_component(app, arguments)` starts one `gleam_otp`
actor per call ([`lustre.gleam`][src-lustre-ssc], `start_server_component`;
[`runtime.gleam`][src-rt-start], `start`). Its initialiser calls `init`,
calls `view` once, builds the event cache from that tree, and performs
`init`'s effects, all under a **1000 ms** start timeout **(source)**. If the
initialiser does not return in time, the start fails with `InitTimeout`.

The actor's state is the model, the last rendered tree (`vdom`), the event
and memo cache, the provided context values, and the registered clients
([`runtime.gleam`][src-rt-state], `State`). The `Runtime(message)` value is
its `Subject`; `server_component.subject` and `server_component.pid`
recover it ([`lustre/server_component`][doc-sc]).

The `lustre` module page says that "applications targeting Erlang should
strongly prefer the `supervised` or `factory` functions"
([`lustre`][doc-lustre]). Loom deliberately does not. `ui_socket.admit`
calls `start_server_component` from the page's mist socket process, so the
component is linked to the socket, exactly as Lustre's own
[basic setup example][ex-basic] does. The component's lifetime is the
connection's: a supervisor would restart a component whose browser is gone.
The client runtime's reconnect (below) plays the part of a restart: a
crashed component takes its socket down, the browser reconnects, and the
new socket starts a new component.

**Per page, Loom runs three processes:** the mist socket
(`client/daemon/ui_socket`), the Lustre runtime (`web_view/component`), and
the relay (`client/daemon/ui_relay`), which attaches to the session's
gateway and stands in for a session socket (051, "The relay").

### The client runtime and the transport

The page holds a `<lustre-server-component route="...">` element. The
client runtime is served from the `lustre` application's `priv/static`
directory (`page.runtime_file`) rather than inlined with
`server_component.script()`, which would put an inline `<script>` in the
page that the policy refuses ([`lustre/server_component`][doc-sc],
`script`; section 3).

What the client runtime does, from
[`server_component.ffi.mjs`][src-client] **(source)** unless marked:

- On connect it attaches a **shadow root** to the element and renders into
  it. With the default `adopt_styles`, it adopts the document's stylesheets
  into the shadow root, which is how `web_view.css` reaches the component's
  elements ([`lustre/component`][doc-component], `adopt_styles`;
  [`runtime/app.gleam`][src-app], `default_config`).
- When `route` is set, it builds the socket URL from it, resolved against
  the page, and sets a `csrf-token` query parameter from the element's
  `csrf-token` attribute, or else from `<meta name="csrf-token">`. With
  neither, the value is the string `null`. The token is read when `route`
  is set, so a page sets `csrf-token` first; changing `csrf-token` on a
  connected element closes the socket and reconnects. The build-out uses
  this parameter to carry the page nonce (section 3).
- For the default `ws` method it passes the resolved `http:` URL straight to
  `new WebSocket(...)`; the `http:` to `ws:` rewrite runs only when a
  `method` attribute *changes* the method, and `method="ws"` does not change
  it. This relies on a browser whose WebSocket constructor accepts `http(s)`
  URLs, which current Chrome, Firefox and Safari do.
- **It keeps one message in flight.** After sending an event it queues
  every later one until the next message from the server arrives, then
  sends the queue as one `Batch`.
- **It reconnects** when the socket closes with any code other than 1000,
  after 500 ms doubling to at most 10 s, and waits for the tab to become
  visible if it is hidden. A close with code 1000 is final. Loom's mist
  fork sends 1000 when a handler returns `mist.stop()` (the `NormalStop`
  arm in `mist/internal/websocket.gleam`), so a page Loom closes that way
  stays closed. It sends 4000 when a handler returns `mist.stop_abnormal`
  (the `AbnormalStop` arm), which the runtime retries. `ui_socket` chooses
  between them from `web_view/ending.close`: 1000 for an ending the person
  resolves, 4000 for one the daemon may clear by itself. A handshake the
  daemon refuses with an HTTP status is a close code 1006 to the browser,
  which cannot read the status, and is retried. A connection that drops
  without a close frame (the daemon restarted) is retried too, and each
  retry is refused with a `401` until the person runs `loom ui` again.
  The runtime attaches the component's shadow root only when the first
  `Mount` arrives, so a paragraph placed inside the element as light-DOM
  content is shown until then and hidden after; the page shell uses that to
  say why a page that never connected is empty
  (protocol-change/051, the addendum on an ended page).

### The wire format

Messages are JSON text frames. Each has an integer `kind`
([`transport.gleam`][src-transport], `ClientMessage`, `ServerMessage`):

| Direction | `kind` | Message | Carries |
|---|---|---|---|
| server to browser | 0 | `Mount` | shadow-root options, observed attribute and property names, contexts, the whole `vdom` |
| server to browser | 1 | `Reconcile` | one `patch` against the last tree |
| server to browser | 2 | `Emit` | an event name and JSON `data`, dispatched on the element |
| server to browser | 3, 4, 5 | `Provide`, `Subscribe`, `Unsubscribe` | context protocol |
| browser to server | 0 | `AttributeChanged` | `name`, `value` |
| browser to server | 1 | `EventFired` | `path`, `name`, `event` |
| browser to server | 2 | `PropertyChanged` | `name`, `value` |
| browser to server | 3 | `Batch` | `messages` |
| browser to server | 4 | `ContextProvided` | `key`, `value`, **not decoded in 5.7.1** (section 8) |

The socket decodes a text frame with
`server_component.runtime_message_decoder()` and hands the result to the
runtime with `lustre.send`; it encodes what the runtime sends with
`server_component.client_message_to_json` ([`lustre/server_component`][doc-sc]).
`ui_socket` does both, drops a frame that does not decode, as Lustre's
example does ([basic setup example][ex-basic]), and stops on a failed
write. The frame size bound is the daemon's mist fork's (ADR-011), set by
the page's role: `root.message_limit(root.Observer)` for an observer's
page and `ui_socket.operator_frame_limit` (1 MiB) for an operator's.

### What the browser can send, and how the runtime refuses it

Four kinds of input reach `update` from the browser, and each passes a
check first **(source)** ([`runtime.gleam`][src-rt-client],
`handle_client_message`):

- **An event** names a `path` and an event `name`. The runtime looks the
  pair up in the event cache built from the tree it last rendered, and runs
  that handler's decoder on the `event` object
  ([`cache.gleam`][src-cache], `decode`, `handle`). If no handler is
  registered at that path for that name, or the decoder fails, nothing
  reaches `update`. The `event` object holds only the properties the
  handler asked for with `server_component.include`, plus the ones the
  client adds itself: `target.value` or `target.checked` for `input` and
  `change`, `key` for key events, `detail.formData` for `submit`, `detail`
  for a Lustre component's own events ([`server_component.ffi.mjs`][src-client-event],
  `#createServerEvent`).
- **An attribute change** is applied only if the application registered a
  decoder for that attribute name with `component.on_attribute_change`.
- **A property change** is applied only if it registered
  `component.on_property_change` for that name.
- **A context value** is applied only if the application subscribed to that
  key, and in 5.7.1 the server's decoder has no arm for it at all.

Loom's observer component registers no attribute, no property and no
context, and its view attaches handlers whose messages are reads or changes of
what the page draws from records it already holds: the lane's "Load older"
click (051, the addendum on history paging), a chip's focus and a settled
turn's divider (070), so every one of these is dropped and `ui_socket`
forwards only those clicks, each at its fixed path. That is the "by type" layer of 051's read-only enforcement. The
operator's component, `web_view/operator_page`, attaches exactly two
kinds of handler, a click on an approval button and the composer form's
submit, and `ui_socket` forwards nothing else to it.

One thing still happens for a dropped message: the runtime diffs and
broadcasts a `Reconcile` after every client message, even when nothing
changed **(source)** ([`runtime.gleam`][src-rt-loop], `loop`,
`ClientDispatchedMessage`). That reply is what releases the client's
one-in-flight queue.

### Subscriptions to BEAM messages: `select`

A server component receives BEAM messages through a selector it gives the
runtime. `server_component.select(fn(dispatch, subject) -> Selector(msg))`
creates a fresh `Subject` inside the runtime process each time the effect
runs, hands it and `dispatch` to the callback, and merges the returned
selector into the runtime's own ([`lustre/server_component`][doc-sc],
`select`; [`runtime.gleam`][src-rt-loop], `EffectAddedSelector`).

- **Use `server_component.select`.** `effect.select` is `@internal` in
  5.7.1 ([`effect.gleam`][src-effect-select]); `server_component.select` is
  the public wrapper and the name ADR-014 uses.
- **Create the subject in the component's process**, which `select` does,
  so a reply is read by the process that owns its subject (ADR-013, the
  phase 2 S4 addendum). `component.open` hands that subject to
  `transport.connect` as the relay's inbox.
- **Select once per source, at `init`.** A merged selector is never
  removed; each run of the effect adds another subject and another selector
  for the life of the runtime **(source)** (`EffectAddedSelector` merges into
  `base_selector`). A `select` returned from `update` on every message leaks.
- **A selector consumes everything it matches**, so the bound on what is
  buffered is the host's to keep (ADR-013 phase 3 addendum; ADR-014,
  "Delivery under option C").
- **Drain the burst in the mapping, and read the clock in `update`.**
  `component.open` drains the inbox in its mapping function, so `Arrived`
  carries a whole burst, and `component.arm`'s mapping turns the timer
  message into `Ticked`. Neither reads a clock. `component.update` reads
  the transport's clock once, at its top, when it takes the message, and
  the step reads none. The one host action `update` performs
  itself is arming the deadline timer (`component.rearm`): its `Timer`
  handle has to be in the model for the next arming to cancel it, and
  handing it back through an effect would cost a second message, and so a
  second render.

Another process can also reach `update` directly with
`lustre.send(runtime, lustre.dispatch(message))`
([`lustre`][doc-lustre], `send`, `dispatch`). Prefer `select`: it keeps the
message constructor inside the component and needs no handle to the
runtime outside it.

### Lifecycle and cleanup

A client is registered with `server_component.register_subject(subject)`.
The runtime monitors the subject's owner, sends it a `Mount` with the whole
current tree, and from then on broadcasts every `Reconcile` to it
([`runtime.gleam`][src-rt-loop], `ClientRegisteredSubject`). "Server
components running on the Erlang target are **strongly** encouraged to use
`register_subject`" rather than `register_callback`, and an anonymous
callback cannot be deregistered ([`lustre/server_component`][doc-sc]).

When a registered owner dies, the runtime drops it and keeps running
**(source)** (`MonitorReportedDown`), because the documentation allows an
application to "keep the application alive even when no clients are
connected". So the runtime must be stopped explicitly with
`lustre.send(runtime, lustre.shutdown())`. Lustre's example says why:
without it "we'll end up with a memory leak and a zombie process"
([basic setup example][ex-basic], `close_counter_socket`).

Loom's chain, one link per process:

1. The browser goes away: mist calls `on_close`, and `ui_socket` sends
   `lustre.shutdown()`.
2. The runtime stops. The relay monitors it (`ComponentDown`), detaches from
   the gateway and exits.
3. The gateway ends the attachment (session stopped, access revoked): the
   relay files `connection_event.Closed` with the component, tells the
   socket (`Ended`), and exits. The reason is one of
   `web_view/ending`'s fixed strings, and the component draws that ending's
   notice. The socket waits a quarter second (`ended_grace_ms`) so the
   patch for the notice is sent first, then stops with the close code the
   ending calls for (1000, or 4000 for an ending that may clear), which is
   step 1.
4. The component crashes: the link takes the socket down, the relay's
   monitor fires, and the browser reconnects.

`component.on_connect` and `component.on_disconnect` dispatch a message
when a client registers or deregisters ([`lustre/component`][doc-component]).
Loom has one client per component, so it does not need them.

### Backpressure

- **Browser to server** is bounded by the client's one-message-in-flight
  rule and by the socket's frame limit. A program that holds the cookie is
  not bound by the first.
- **Server to browser** has no flow control in Lustre. The runtime
  `process.send`s each message to the registered subject, which never
  blocks ([`runtime.gleam`][src-rt-loop], `broadcast`). `ui_socket` writes
  each one with `mist.send_text_frame`, so a slow browser lets the socket's
  mailbox grow. 051 accepts this: "Backpressure is the terminal socket's".
- **Session traffic** is bounded by the batch: a selector mapping reads
  at most `arrival_batch` frames, and the message it builds is reduced at
  once, so the filed buffer never holds more than one batch. What the
  mapping did not read waits in the mailbox for the next message.

### Cost of a message, and sizing

Every message the runtime handles, whatever its source, runs `update`,
then `view` on the whole model, then a diff of the whole new tree against
the old one, then a broadcast **(source)** ([`runtime.gleam`][src-rt-loop],
`EffectDispatchedMessage`, `ClientDispatchedMessage`). Nothing skips the
render when the model did not change. So:

- The cost of one message is the cost of `view` plus the diff. Keep `view`
  cheap: compute derived data in `update`, where it runs once per change,
  not in `view`, where it runs once per message (section 4).
- An idle page receives a `Reconcile` per message. With event-driven
  delivery that is one per idle refresh, every `pushing_refresh_ms` once
  the daemon has pushed (5 s), plus one per reply to that refresh; with the old
  250 ms tick it was four a second before any reply.
- A `Mount` serializes the whole tree, and the runtime holds the whole last
  tree and its handler map. Per-page memory grows with what the page
  renders, not with what changed. Bound the rendered window.
- Pages are counted against `max_connections` and the reserved-byte limit
  through the parser permit `root.acquire` reserves (051, "Checks on every
  `/ui` request").

Measure before optimizing; the [BEAM memory review
skill](../skills/beam-memory-review/SKILL.md) is the tool for per-page
retention.

### Where each piece lives in Loom

| Concern | Lustre | Loom |
|---|---|---|
| Start one runtime per connection | `lustre.start_server_component` | `ui_socket.admit` |
| Register the client | `server_component.register_subject` | `ui_socket.admit`, a subject the socket owns |
| Browser to runtime | `runtime_message_decoder`, `lustre.send` | `ui_socket` handler, `mist.Text` arm |
| Runtime to browser | `client_message_to_json` | `ui_socket` handler, `Client` arm |
| BEAM messages in | `server_component.select` | `component.open` (relay inbox, drained into one `Arrived` per burst), `component.arm` (deadline timer) |
| Engine effects out | one `effect.from` | `component.perform` |
| Shutdown | `lustre.shutdown()` | `ui_socket` `on_close` |
| Session traffic | none | `ui_relay`, one per page, monitors the component and the gateway |
| Page, asset, policy | `<lustre-server-component>`, `priv/static` | `web_view/page` |

## 3. Security

051 sets the threat model: a `loom_ui` cookie is shared with every service
on loopback, a program that holds it can open the socket with any `Origin`,
and the page shows content the session's own agent wrote. These rules keep
a page from becoming a way to act on the session.

### Only events you attach can arrive

The runtime dispatches a browser event only to a handler present in the
tree it last rendered, and only if that handler's decoder succeeds
(section 2). Three consequences for view code:

- **Every handler in the tree is callable by anyone who holds the socket,
  at any time.** Hiding a button with CSS does not remove its handler. A
  handler exists only when the role allows the action it sends. An
  observer's view attaches only reads and changes of what the page draws:
  the "Load older" read (051, the addendum on history paging), a chip's
  focus, and a settled turn's divider, which draws or drops the steps of
  records the page holds (070).
- **The message a handler sends is fixed when the tree is rendered, and
  can arrive after the model moved on.** `update` must still check the
  message against the current state, and the engine must carry what it was
  drawn against, as an approval decision carries `expected_seq`
  ([approvals](architecture/approvals.md)).
- **Key every list whose items carry handlers, by a domain identity.** An
  event names its target by path. A path segment is the child's key when it
  has one and its index otherwise **(source)**
  ([`path.gleam`][src-path], `add`). With an unkeyed list, a click that was
  in flight while the list shifted reaches whichever item now sits at that
  index. With keys, it reaches the same item or nothing.

### Never build handlers or attributes from session content

Session content is anything the daemon relays: entries, tool output,
approval text, names, file paths. The agent can write all of it.

- **Text only.** Session content goes into the tree through `html.text` (or
  the `html` helpers that take a string, like `html.textarea`). Nothing
  else.
- **No attribute name from content.** `element.to_string` escapes attribute
  values and not names **(source)** ([`vattr.gleam`][src-vattr],
  `to_string_tree`), and in the browser the name goes to `setAttribute`
  as it is. An `on*` attribute from content would be an inline handler.
- **No `href`, `src` or `action` from content.** A URL or path in the
  transcript is drawn as text. The policy's `script-src 'self'` refuses a
  `javascript:` URL, and the view must not depend on that. A Markdown link is
  the one place a destination becomes clickable, and the server still writes no
  attribute: it draws `<loom-link>` with the label and the destination as two
  text children, and the browser element checks the destination (`http` or
  `https` only, no credentials, bounded length, `web_client/link_rule`) before
  it draws a real anchor with `target="_blank" rel="noopener noreferrer"` in its
  own shadow root (protocol-change/051, the addendum on clickable links).
- **No `attribute.property` from content, and never for `innerHTML` or
  `outerHTML`.** The client runtime applies a property as `node[name] =
  value` **(source)** ([`reconciler.ffi.mjs`][src-reconciler],
  `property_kind`), so `property("innerHTML", ...)` is raw HTML by another
  name.
- **No `style` from content.** `attribute.style` concatenates
  `property:value;` into one attribute ([`attribute.gleam`][src-style],
  `style`); content there is CSS injection.
- **No key from content.** Keys come from the engine's identities. The
  client's path format separates segments with tab, carriage return and
  newline, so a key containing one of those corrupts every path under it
  **(source)** ([`path.gleam`][src-path], the `separator_*` constants).
- **Classes from a closed type.** Map a domain variant to a class string
  with a `case`, as `speaker_class` in `web_view/view/lane` does.

### Escaping, and `unsafe_raw_html` is never used

Text nodes are escaped with houdini when rendered to a string
([`vnode.gleam`][src-vnode], `to_string_tree`), and the client runtime
creates them as DOM text nodes, which the browser does not parse as markup.
`web_view_parity_test` asserts the escaped form (`&lt;ordering&gt; &amp;
report`) appears in the component's HTML.

`element.unsafe_raw_html` is never used in Loom. Its documentation says
"The provided HTML will not be escaped automatically and may expose your
applications to XSS attacks! ... never use this to display un-sanitised
user HTML!" ([`lustre/element`][doc-element]). `html.script` and
`html.style` take raw strings as content
([`lustre/element/html`][doc-html]) and are not used either; the policy
would refuse them anyway. Rendered Markdown follows the same rule: the
engine parses an answer into a closed tree (`session_view/markdown`) and
the view maps each variant to a fixed element (`web_view/markdown_view`).
HTML in the source is text, a link is drawn as its label followed by its
destination as text with no `href`, a Markdown image is text and is never
loaded, and every class comes from a closed type.

A transcript image is a different thing from a Markdown one. It is a
`Block`'s or a `Step`'s `UserImage` or `ToolResultImage`, and the lane draws
each raster one as an `<img>` after the row's text (`view/lane`). Its `src` is
the one attribute the view builds that is not a class, and it is made of the
page's own session, the engine's name for the row and a number, never of
anything the session wrote, so the rule that no `src` comes from the session
holds in the sense it was written for. The address is same-origin, so the
policy's `img-src 'self'` admits it and no `data:` or `blob:` source exists.
The daemon answers it only after the page grant, the fetch-site check and its
own check of the bytes (`web_view/image.serve`); see the addendum on images in
`protocol-change/051`.

### Client components inside the server component

A client component is a second Lustre runtime, in the browser, inside the
server component's tree. It runs code the daemon did not render, so it
keeps these rules, which `packages/web_client/CLAUDE.md` repeats:

- **It renders only data from its own attributes, and those hold daemon
  identities or numbers.** `<loom-elapsed offset>` is a duration in
  milliseconds, which the element anchors to the browser's clock, since a
  browser's clock need not agree with the daemon's. No attribute carries
  session text. `<loom-shell sidebar needing>` holds a fixed word, `listed`
  or `none`, written from a type, and a count of strands waiting on a
  decision. A control that has no handler carries `data-loom-focus`, and a
  strand card `data-loom-card`, each a number: a card's position among the
  cards as drawn, never a name. `<loom-composer commands>` is the one attribute of
  another kind: the static table of slash-command names and hints, written in
  `session_view` and built for the page by `web_view/completion`.
- **Session text reaches it only as the server's children.** `<loom-fold>`
  shows the divider and the work through a named and a default slot,
  `<loom-expand>` shows a row's line and, once opened, its body through two
  named slots (`head` and `body`), and
  `<loom-follow>` shows the lane through a default slot, and `<loom-shell>`
  shows the top bar, the sidebar, the centre and the strand panel through
  slots named `bar`, `left`, the default and `right`; the words are
  light-DOM nodes the server rendered and escaped.
- **No key acts inside an approval card, and no key decides, dismisses or
  focuses one; no focus near an approval card.** A client
  component's button is a real button, which the browser activates.
  `<loom-follow>` is the transcript's scroll container: it scrolls itself
  and observes the size of itself and of the lane; the approval cards and
  the composer are outside it, in the dock, and it reads nothing inside
  either. `<loom-composer>` is the one element that listens for a key, and
  only on its own editor, through its slot: Command or Control with Enter
  submits the composer's form, and while its list shows the arrows, Tab,
  Enter and Escape act on the list. It calls `focus` on the editor once,
  when the operator chooses a row. The approval cards are outside it, in
  the dock, and none of these keys decides one. `<loom-follow>` also hears,
  passively and without reading them, the wheel, a finger, a pointer press and
  a key pressed inside itself, to tell the reader's scroll from one the layout
  made. Only the composer acts on keys; the follower notes that one was
  pressed, reading nothing from it, so a keyboard scroll counts as the
  reader's. `<loom-shell>` draws the page's frame around the dock and so holds
  an approval card in its subtree. It acts on three keys (Command or Control
  with `B` for the sidebar, with Alt too for the panel, and `Escape` for `All
  strands`, protocol-change/051, the addendum on the keyboard) and drops every
  key pressed inside the region of approval cards, whatever the key; no
  intent decides, sends or focuses, and the server has no key handler. It
  never moves focus, and hears a click only on its own buttons and tabs and on a control
  whose own target carries a strand marker (the marker relay,
  protocol-change/051, the addendum of that name): it then presses the strand
  card with the same number, an ordinary click on the card's ordinary
  handler, and nothing else. No approval card carries a marker, the centre
  column where the dock is has no button, and the panel carries no decision
  control. A hidden side column is `inert`, which takes its content out of
  the tab order. The reader's layout (the two columns and the active tab) is
  kept in the browser's `localStorage` under a workspace digest the daemon
  computes, through the two storage calls in `internal/dom.mjs`; nothing
  session-derived is kept and the server never learns it (protocol-change/051,
  the addendum on the storage decision).
- **`<loom-copy>` is the one element that holds a secret.** An owner's page
  draws an invitation's command and claim token in it (protocol-change/051,
  the addendum on inviting from the session page). Its two attributes are a
  fixed word, `command` or `token`, and the value, and it draws and copies the
  value only when `copy_rule.text` finds exactly the shape the daemon writes
  for that subject: `loom claim --addr ` and an address of address characters,
  or `loomclaim_` and 64 hexadecimal digits. A value with a newline or any
  other character is no value, because what it copies is pasted into a chat
  window or a terminal. It copies in the press's own turn, listens for no key,
  takes no focus and sends the server nothing.
- **No raw HTML.** It renders through Lustre's virtual DOM, as the server
  component does. Its browser calls are one file, `internal/dom.mjs`, one
  DOM call per export and no logic, declared in `internal/ffi_dom.gleam`;
  the components are Gleam over it. `scripts/web_client_js_check.sh` (run by
  `make lint`) fails if any other JavaScript is added under
  `packages/web_client/src`, or if that file names `innerHTML`, `outerHTML`,
  `insertAdjacentHTML`, `eval`, `new Function`, `document.write`, `srcdoc`,
  `DOMParser`, `createContextualFragment` or a dynamic `import(`. The check is
  textual; the guarantee is that the file is a short list of one-call exports
  a reviewer reads.
- **Nothing the server needs.** A fold's open state, a clock reading and
  whether the reader is following the tail live only in the browser; the
  server never renders them, so its later patches leave them alone, and it
  never reads them.

Its styles are the page's: the client runtime adopts the document's
stylesheets into the element's shadow root, as the server component's does.

### CSP compatibility

The policy is `page.content_security_policy`, specified in 051 ("Response
headers"). What it means for view code:

- **The runtime is a file.** `script-src 'self'` allows the runtime served
  from `/ui/assets/`; `server_component.script()` would be an inline script
  and is refused. The asset's name carries the Lustre version
  (`page.runtime_asset`), so a cached runtime never runs against a newer
  server component. Bump it with the pin.
- **Classes, not styles.** `style-src 'self'` refuses `<style>` elements
  and `html.style`. `style-src-attr 'unsafe-inline'` exists only because the
  client runtime applies a `style` attribute with `setAttribute`. Prefer a
  class from the stylesheet. Use `attribute.style` only for a value the
  engine computes (a width, a count), never for content.
- **No inline handlers, no `javascript:` URLs.** Both need
  `'unsafe-inline'` for scripts, which the policy does not grant. Lustre
  event handlers are listeners the client runtime adds, so they are not
  affected.
- **The stylesheet reaches the shadow root by adoption**, which needs no
  policy change.
- **Everything the page loads is a file.** The client components' bundle,
  the stylesheet and the two bootstrap scripts come from
  `packages/web_client` and are built into `packages/web_view/priv/static`
  by `make gen-client`, which runs Lustre's own tool, `lustre_dev_tools`, a
  dev dependency of `web_client` only: it bundles the components with Bun
  and builds the stylesheet with Tailwind v4 from
  `packages/web_client/src/web_client.css`. The daemon reads the outputs
  once at startup and serves them from `/ui/assets`, a closed list of names
  in `ui_http`. `make client-check`, part of `make check`, compares the
  committed outputs with their inputs by digest and needs no network.
- **Class names are complete literal strings.** Tailwind finds the classes
  it builds by reading `packages/web_view/src` and `packages/web_client/src`
  as text; it never runs the code. A class spelled `"hue-" <>
  int.to_string(n)` is invisible to it and silently missing from the
  stylesheet, so a class that varies is chosen with a `case` whose every arm
  is a whole class string, and an element with several classes gets one
  `attribute.class` per literal, which Lustre merges.
- **`form-action 'none'`** refuses native form submission, which is fine:
  `event.on_submit` prevents the default and sends the form's data over the
  socket ([`lustre/event`][doc-event], `on_submit`).

### Event payloads are decoded with total decoders

A handler's decoder runs on JSON that came from the browser, or from any
program that holds the cookie. Lustre's decoders are total already: a
failing decoder means the event "is silently ignored"
([`lustre/event`][doc-event], `on`). Loom's rule on top (`docs/gleam-style.md`
Part IV §2):

- Decode into a domain type in the decoder, not a string that `update`
  parses later.
- Bound what you accept. Frame limits bound a message, not a field; a text
  field is checked against the engine's limit before it becomes a command.
- Name what you need with `server_component.include`; the event object has
  nothing else ([`lustre/server_component`][doc-sc], `include`).
- `event.on_submit` gives you every `#(name, value)` pair the form sent, and
  a forged submit can send any names. Pick the field you expect, and treat a
  missing or repeated field as a refused event.
- Never pass `decode.dynamic` through to `update`.

### CSRF, and the page nonce in Lustre's `csrf-token`

Lustre's CSRF mechanism is a token the client runtime appends to the socket
URL as the `csrf-token` query parameter, taken from the element's
`csrf-token` attribute or a `<meta name="csrf-token">`, which the server
checks before upgrading ([`lustre/server_component`][doc-sc],
`csrf_token`; [CSRF example][ex-csrf]). In Lustre's example the token is
written into the page's HTML.

Loom does not rely on a token for CSRF. A cross-site page cannot open the
socket because `Origin` must equal `http://` followed by the request's
`Host`, port included, and the `loom_ui` cookie is `SameSite=Strict` and
`HttpOnly` (051, "Checks on every `/ui` request").

The build-out ([#554](https://github.com/Roasbeef/loom/pull/554), the 051
addendum "Three secrets, three scopes") uses Lustre's `csrf-token` for a
different secret: a **per-page nonce**. It defends against a server the
session's agent runs on another loopback port. Cookies are not scoped by
port, so that server can receive `loom_ui`, and if the person pasted the
page's address it also knows the page key. The nonce is the one secret it
cannot get:

- It is minted at the ticket exchange and delivered only in the exchange's
  `200` body, as the `data-nonce` attribute of `<body>`, never in a
  redirect and never in the keyed page's HTML. Fetching the keyed page with
  the cookie and the key therefore does not reveal it.
- The exchange page's script stores it in `sessionStorage`, which is scoped
  to scheme, host and port, so no page on another port can read it. It
  lives in one tab: a reload keeps it, a new tab has none.
- The keyed page's script reads it back, sets it as the component's
  `csrf-token` attribute, and only then sets `route`, because the client
  runtime reads the token when `route` is set
  ([`server_component.ffi.mjs`][src-client], `attributeChangedCallback`,
  the `route` arm) **(source)**.
- The upgrade requires the `csrf-token` parameter and compares its SHA-256
  digest with the stored one in constant time
  (`broker/internal/ffi_crypto.constant_time_equal`). A missing or wrong
  nonce refuses the socket.

The reason Lustre's example gives for a token, "only clients that have
access to the token can connect", is the reason here too; what differs is
where the token lives. A nonce written into the page's HTML or a `<meta>`
tag would add nothing, because whoever holds the cookie and the key can
fetch the page and read it; 051 considered that and did not take it.
Rules for view and page code that follow:

- Never render the nonce into any document, attribute of the component's
  tree, or log line. It reaches the browser once, in the exchange body.
- Never set `route` before `csrf-token`, and do not change `csrf-token` on a
  connected element; either opens a socket without the nonce or drops the
  connection.
- `Referrer-Policy: no-referrer` stays on every `/ui` response; the ticket
  and the key are in URLs.

## 4. Views

### What a render costs, and how to keep diffs small

Lustre diffs children in order. For each pair it morphs an element with
the same tag, updates changed attributes, rewrites changed text, and
replaces anything else ([`lustre/element/keyed`][doc-keyed];
[`diff.gleam`][src-diff], `do_diff`). A patch contains only what changed,
so a stable tree sends little. Three practices keep it stable:

**Derive in `update`, not in `view`.** `view` runs on every message
(section 2). `component.refreshed` runs at the end of each message,
compares what the projection and the strip were built from with what the
shared record holds now, and rebuilds only what differs. The keyed rows and
pieces stay in the model, so a frame or a tick that changes none of the
projection's inputs costs the view no projection. The comparison is of
inputs and not of the record's `render_revision`, which moves for stream
fragments, which change the live region and nothing the lane's memos hold.

**Key the transcript.** An append-only list diffs well without keys: the
old lines compare equal and the new ones are inserted at the end. A list
that loses items at its head does not: every surviving line is compared
with the line that used to be at its index, and each one is rewritten.
The history window drops lines at the head. With `lustre/element/keyed`,
Lustre matches children by key and moves or removes only what changed
([`lustre/element/keyed`][doc-keyed]; [rendering lists hint][hint-lists]).
The key must be an identity the engine owns. `transcript.project_rows`
supplies one: each `transcript.Row` carries a key built from the durable
sequence the line was drawn from, the block at that sequence and the
line's index within it, in characters that are safe as a list key. Keys
need only be unique among siblings ([`lustre/element/keyed`][doc-keyed]).

**Memoize what rarely changes.** 5.7.1 has `element.memo(dependencies,
view)` and `element.ref(value)`. When every dependency is equal to its
previous value, the runtime reuses the cached subtree and skips both the
view call and its diff ([`lustre/element`][doc-element], `memo`;
[`diff.gleam`][src-diff-memo], the `Memo` arm). The documentation's warning
that "reference equality is not the same as Gleam's normal equality" is
about JavaScript. "On Erlang, there is no difference between reference
equality and value equality, so all values are compared using normal
equality semantics" ([`lustre/element`][doc-element], `ref`;
[`ref.gleam`][src-ref], `equal`). On the BEAM, an unchanged value that is
the same term compares in constant time, and a rebuilt equal value
compares in time proportional to its size **(source)**. The documentation
also warns that memo costs memory and "if dependencies change regularly,
the overhead ... may be more than the naive cost of re-rendering". Memoize
large subtrees whose inputs change far less often than messages arrive,
such as the transcript body between captures.

The component's transcript does both, keyed by the engine's identity and
memoized on the rows (`component.transcript_view`):

```gleam
pub fn transcript_view(rows: List(transcript.Row)) -> Element(message) {
  use <- element.memo([element.ref(rows)])
  keyed.div(
    [attribute.class("transcript"), attribute.role("log")],
    list.map(rows, fn(row) { #(row.key, line_element(row.line)) }),
  )
}
```

**A memo inside a memo that hit is forgotten.** The runtime keeps memo
elements in a table it starts afresh on every render: `diff.diff` calls
`cache.tick` first, which moves the last render's table to `old_vdoms` and
starts an empty one ([`diff.gleam`][src-diff-memo], line 39;
[`cache.gleam`][src-cache], `tick`). A memo whose dependencies are equal
copies only its own element into the new table (`keep_memo`), and the
memos nested inside that element are not visited. So after one render in
which an enclosing memo hit, the inner memos have no entries, and the next
render that changes the enclosing memo calls every inner view again
**(source)**. A keyed child whose key changes is replaced, and a replaced
subtree's memos are evaluated fresh (`cache.add_children`), so a memo only
survives under a key that stays the same. To memoize many small things,
put the memos at the leaves with no memo around them, and give their keyed
ancestors stable keys. Every render then visits each memo and carries each
hit forward, for the cost of one dependency comparison each. The lane does
this per transcript line (`lane.rows` in `web_view/view/lane`), and `lane_memo_test`
counts the lines a render draws through Lustre's own diff.

**Fragments and `none`.** `element.fragment` and `keyed.fragment` group
children without a wrapper element ([`lustre/element`][doc-element]); the
client marks a fragment's position with an empty text node or a comment.
`element.none()` renders an empty text node **(source)**
([`element.gleam`][src-element], `none`), so a conditional `none()` keeps a
stable child count. Use either instead of a `div` added only to group.

**`element.map` costs a subtree of handlers.** Each mapped node gets its
own event subtree in the cache **(source)** ([`cache.gleam`][src-cache],
`Events`). Map at a module boundary, not per list item.

### Attributes, properties and styles

- **Attributes** are strings set with `setAttribute` and appear in
  `element.to_string`. **Properties** are JavaScript values assigned on the
  DOM object; they do not appear in `to_string`, so a test that inspects the
  HTML string cannot see them ([attributes vs properties hint][hint-attrs];
  [`lustre/attribute`][doc-attribute]). Prefer attributes; a property is
  for a DOM value with no attribute form.
- **Classes** from a closed type are the default for presentation.
  `attribute.classes` toggles several from `#(name, Bool)` pairs.
- **Styles** are attributes and need the `style-src-attr` allowance
  (section 3). An empty property or value makes `attribute.style` produce
  an empty class instead **(source)** ([`attribute.gleam`][src-style],
  `style`).
- **`autofocus` is not a plain attribute.** The client runtime calls
  `focus()` on the element whenever the attribute is added **(source)**
  ([`reconciler.ffi.mjs`][src-reconciler], `SYNCED_ATTRIBUTES`;
  [`lustre/attribute`][doc-attribute] says it is "augmented").

### Accessibility and focus

A server component cannot run DOM effects, so it cannot move focus except
through `autofocus`. That makes focus rules easy to state and easy to
keep.

- **Real controls.** An action is an `html.button` with
  `attribute.type_("button")` and `event.on_click`, or a submit button in an
  `html.form` with `event.on_submit`. Never a `div` or `span` with a click
  handler: it has no keyboard activation and no role.
- **Labels.** Every input has an `html.label` with `attribute.for`, or an
  `attribute.aria_label`. An icon-only button has `aria_label`.
- **Live regions.** The transcript is `attribute.role("log")`, so new lines
  are announced politely; the connection status is `attribute.role("status")`.
- **The approval card never takes focus.** No `autofocus` on it or
  anything inside it, and no `tabindex` that pulls it into the order ahead
  of what the person was doing. A card that grabs focus turns the next key
  the person types into an answer. The terminal's rule is the same: "No
  action is selected on opening" (`packages/tui/CLAUDE.md`).
- **Deny is the default.** If the card is a form, its first submit button
  in tree order is Deny, because implicit submission (Enter in a field)
  uses the first submit button. Allow is a separate button the person must
  activate. A decision carries the escalation's ID and the sequence it was
  drawn at.
- **The composer is uncontrolled.** A controlled input round-trips every
  keystroke through the server, and the client re-sends `value` to an input
  that dispatched events **(source)** ([`diff.gleam`][src-diff-controlled],
  `is_controlled`), which can overwrite what the person typed while a reply
  was in flight. Use an uncontrolled `html.textarea` in a form with
  `event.on_submit`. To clear it after a send, put it in a keyed container
  and change the key; an effect that clears it "is not possible when using
  server components" ([controlled vs uncontrolled hint][hint-inputs]).
  If a field must report as the person types, wrap its handler in
  `event.debounce`, which the docs call "particularly useful for server
  components" ([`lustre/event`][doc-event]).
- **No conditional `prevent_default`.** "It is not possible to
  conditionally stop propagation or prevent the default behaviour of an
  event when using _server components_" ([`lustre/event`][doc-event],
  `advanced`). Use the unconditional `event.prevent_default` wrapper, or
  `on_submit`, which applies it.

### Hydration, and why the server component does not use it

**What it is.** Hydration is how a client-side Lustre app takes over HTML
the server already rendered ([server-side rendering guide][doc-ssr],
"Hydration"). The server renders `view(model)` into the page with
`element.to_document_string`, and embeds the same model as JSON in a
`<script type="application/json" id="model">`. The browser's `main` reads
that element, decodes it, and passes the result as the flags to
`lustre.start(app, "#app", flags)`, so `init` rebuilds the model the
server rendered. The client runtime then adopts the existing DOM rather
than replacing it: the guide reports that "the existing HTML was not
replaced and the app is fully interactive", and the runtime builds its
first virtual tree by reading the DOM under the root
([`runtime.ffi.mjs`][src-spa-runtime], the constructor's
`virtualise(this.root)`) **(source)**. The guide's one condition: "Make
sure the initial model on the client is the same as what the server used
to render the page." It also suggests serialising less and deriving the
rest of the model on the client.

**It is a client-side-app technique.** It exists because a client-side app
runs `view` in the browser and must start from the same model the server
used. Loom's web view runs `view` only on the BEAM.

**Why Loom's view does not need it.** The server component's first message
on the socket is a `Mount` carrying the whole current tree, and the client
renders from that. There is no model in the browser to reconstruct, and
nothing in the page for the client to agree with.

**Can a server component adopt server-rendered HTML in 5.7.1? No.** On
`Mount`, the client runtime attaches (or reuses) the element's shadow root,
removes every child already in it, and renders the `Mount` tree from
scratch ([`server_component.ffi.mjs`][src-client-mount],
`messageReceivedCallback`, the `mount_kind` arm) **(source)**. Anything
server-rendered inside `<lustre-server-component>` is therefore shown only
until the socket's first message, and is then discarded, not adopted. That
is enough for a placeholder, and nothing more.

**Where it could matter later.**

- **First paint.** Today the page is empty until the socket's `Mount`
  arrives, because the heading is part of the component. A static
  placeholder inside the element (a "connecting" line) needs no hydration,
  and the previous paragraph says what happens to it. Server-rendering the transcript itself would be drawn
  twice, and would carry session content in the HTTP response, which the
  second rule below governs.
- **A future client-side piece.** If Loom ever ships a client-side Lustre
  module (for example a composer editor that must not round-trip each
  keystroke), that module's first render is where hydration would apply.
  ADR-014 keeps session logic on the BEAM, so such a module would hold
  view state only.

**The security constraint.** An embedded model is page content: any script
on the page, any extension with page access, and anything that can read
the response can read it. So a model embedded for hydration may carry only
what the viewer's role may already see on the page, and never approval
records, credentials, the page key, the page nonce, tickets or cookie
values. Escape it as JSON inside a `<script type="application/json">`
element, which the policy allows because it is not executed; never inline
it into executable script, which the policy refuses.

## 5. Components and custom elements

Lustre's advice is to prefer view functions: a component is a "stateful
nested Model-View-Update application", and the guide gives five reasons to
avoid one, ending with "If you find yourself thinking 'wow, this is a lot
of boilerplate just to do X' then listen to your gut!"
([state management guide][doc-state]).

In a server component the choice is narrower still:

- **A Lustre client component** (`lustre.component` registered with
  `lustre.register`) is a browser custom element. `register` works only in
  a browser ([`lustre`][doc-lustre]), so it lives in its own JavaScript
  package, `packages/web_client`, bundled into one module the page loads.
  Loom uses one only for behaviour that changes with nothing the server
  knows, so the server would otherwise render and diff the whole page for
  it: a clock that moves every second (`<loom-elapsed>`), a fold the reader
  opens (`<loom-fold>`), the page's scroll position while it follows the
  tail (`<loom-follow>`). The server component renders it by tag name like
  any element. It holds no session state and sends no command; the rules
  it keeps are in section 3, "Client components inside the server
  component".
  What each decides is a pure Gleam function with unit tests in
  `packages/web_client/test` (`make test-web_client`, which needs Node, Bun or
  Deno); the DOM calls beneath them run only in a browser.
- **A second server component** is a separate `<lustre-server-component>`
  with its own route, socket, runtime process and relay. It is the right
  unit for a view with its own lifetime and its own session traffic: another
  session or another agent. ADR-014's direction is exactly that: "Each view
  is its own component keyed by person and session, which the routes
  already allow."
- **Everything else is a view function.** A card, a row, the composer and
  the status bar are functions from the engine's state to `Element(Msg)`.

**Sub-modules within one component** follow the Elm pattern: a module with
its own `Msg`, an `update` the parent calls, and a `view` the parent maps
with `element.map`. Effects from it are lifted with `effect.map`
([`lustre/effect`][doc-effect]). Use this only when the part has state that
is about presentation, not the session; section 1's rule decides where
state goes.

**Parent-child messages.** Within one component there are no parent-child
messages, only function calls. Between server components there is no DOM
parent either: each talks to the session through the engine and the
gateway, and the gateway's pushes are how one view learns what another
changed. `event.emit` and `server_component.emit` dispatch a DOM event on
the element for JavaScript on the page to hear; Loom's page has no such
JavaScript, so neither is used.

**Context.** `effect.provide`, `effect.subscribe` and `effect.unsubscribe`
implement the Web Components context protocol ([`lustre/effect`][doc-effect]).
A server component can provide values to the browser, but a value the
browser sends back (`kind` 4) is not decoded by the 5.7.1 server
**(source)**. Do not use context to pass state between Loom's views.

**Form association** is "Not supported in server components for both
technical and ideological reasons" ([`lustre/component`][doc-component],
`form_associated`).

**Loom's rule: session logic lives in the engine, never in a component.**
What a frame means, when to catch up, which lines a capture becomes, what a
reply settles and whether an approval is still pending are `session_view`'s.
A component reads the engine's state, draws it, and turns DOM events into
engine messages. "A reviewer who finds session logic in `packages/web_view`
has found a bug in the extraction" (ADR-014).

## 6. Loom and Lustre's full-stack layout

Lustre's [full-stack guide][doc-fullstack] splits an application into three
Gleam packages: shared code, a server, and a client. Loom maps onto them
like this:

| Guide | Loom |
|---|---|
| shared | `core` and `session_view`: the engine, pure, compiled for both targets |
| server | `loomd` (`packages/client`) with `packages/web_view`, the server components and the documents around them |
| client | `packages/web_client`: client components, bundled by `lustre_dev_tools` into `web_view`'s `priv/static` |

The guide's client is a single-page app that talks to the server over
HTTP. Loom's client is not an application: it is a few client components
rendered inside the server component. Protocol-change/051 keeps the session
on the BEAM: what a frame means, what a command is and whether an approval
is still pending are the engine's, run by the server component, and the
page's socket carries Lustre's patches and a closed set of events, never
the session protocol. A single-page app would have to hold the session in
the browser, which 051 and ADR-014 rule out. So the client package holds
only what the browser can do without the session.

## 7. Testing

### `lustre/dev/simulate`

A simulation runs `init`, `update` and `view` with no runtime. "Any effects
that would normally be run after update will be discarded"
([`lustre/dev/simulate`][doc-simulate]). You drive it with:

- `simulate.message(sim, msg)` for what an effect or a BEAM message would
  deliver (recorded in the history as `Dispatch`);
- `simulate.event(sim, on: query, name:, data:)`, `simulate.click`,
  `simulate.input` and `simulate.submit` for DOM events;
- `simulate.model`, `simulate.view` and `simulate.history` to observe.

`simulate.event` resolves the target with a query and dispatches through
the same event cache the server runtime uses **(source)**
([`simulate.gleam`][src-simulate], `event`), so it is a faithful test of
"only attached handlers fire". A target that does not exist, or has no
handler for the event, is logged as a `Problem` named
`EventTargetNotFound` or `EventHandlerNotFound`; the simulation does not
fail. A test that expects a refusal must inspect the history.

Loom's component starts its transport and timer from `init`'s effects, so
tests build the simulation around `component.new`, which is `init` without
effects, and deliver `Opened`, `Arrived` and `Ticked` as messages
(`component_test`). The clock is the fixture transport's, which a test
sets with `page_fixture.clock` when it needs a later reading:

```gleam
fn simulation() {
  simulate.application(
    init: fn(start) { #(component.new(start), effect.none()) },
    update: component.update,
    view: component.view,
  )
  |> simulate.start(start())
}
```

The read-only guarantee as a test:

```gleam
pub fn the_page_has_no_handler_to_fire_test() {
  let clicked =
    simulation()
    |> simulate.click(on: query.element(matching: query.tag("main")))

  // The runtime's handler lookup found nothing, so update never ran.
  let assert [simulate.Problem(name: "EventHandlerNotFound", ..), ..] =
    simulate.history(clicked)
    as "a click on a page with no handler reaches no update"
}
```

What a simulation does not cover: the effects, the order of a batch,
`server_component.include` (the test supplies the payload the handler
sees, so a missing `include` passes here and fails in a browser), the wire
format, and the client runtime.

### `lustre/dev/query`

`query.element`, `query.child` and `query.descendant` build a query from
selectors (`tag`, `class`, `id`, `attribute`, `data`, `test_id`, `aria`,
`text`, combined with `and`). `query.find`, `query.find_all`, `query.has`
and `query.matches` run them against an `Element`
([`lustre/dev/query`][doc-query]). `query.text` matches exact text,
whitespace included, and "often it is better to use more precise
selectors". Give an element a test hook with `attribute.data("test-id",
...)` when no domain attribute identifies it.

For whole-view assertions, `element.to_string` gives compact HTML with text
escaped as the browser will receive it, and `element.to_readable_string`
gives indented HTML for snapshots ([`lustre/element`][doc-element]).
Properties do not appear in either.

### The parity pattern

The web view must draw what the terminal draws, and the way to hold it
there is to run one engine script through both hosts and compare.
`client/web_view_parity_test` does it for a capture: one fixed capture goes
through the terminal's reducer and through `component.apply`, the two line
lists are compared for equality, and the component's HTML is checked to
hold every line's escaped text in order. A second test runs one script of
frames and commands through both hosts and compares the lanes' states and
the approvals on offer.

The step is in the engine now, so extend the pattern rather than writing
web-only assertions:

1. Script the engine's messages once (frames, ticks, and the domain events
   a key or a click becomes).
2. Drive the terminal host with the script and record the engine state and
   the effect list after each step.
3. Drive the component with the same script through `update` and
   `simulate.message`, and record the same.
4. Assert the two sequences are equal, then assert the web view's HTML for
   what only the view decides.

A difference in step 4 is a view bug. A difference in steps 2 and 3 is
session logic that leaked into a host.

### Around the component

The route's defences (host, origin, cookie, ticket, revocation) are tested
in `client/ui_route_test` and `client/ui_http_test`, and the relay's ends in
the client tests. Those are where a change to `ui_socket` or `ui_relay` is
tested; the component's tests do not reach the socket.

## 8. Gotchas and anti-patterns

All apply to 5.7.1. Re-check each when the pin moves.

| Gotcha | Consequence | Source |
|---|---|---|
| `effect.select` is `@internal`; the public API is `server_component.select`. | Code on `effect.select` depends on an unpublished function that can change in a patch release. | [`effect.gleam`][src-effect-select], `select` |
| `init`'s effects run inside the actor's 1000 ms initialiser. | A slow effect in `init` makes `start_server_component` fail with `InitTimeout`. **(source)** | [`runtime.gleam`][src-rt-start], `start` |
| Effects run synchronously in the runtime process. | A blocking effect stalls the page. **(source)** | [`runtime.gleam`][src-rt-start], `handle_effect` |
| `effect.batch` has no guaranteed order, and the server runs it in reverse. | Ordered work split across a batch runs backwards. **(source)** for the reversal | [`lustre/effect`][doc-effect]; [`effect.gleam`][src-effect-batch] |
| Every message renders, diffs and broadcasts, including dropped browser messages and no-op messages. | `view` cost is paid per message; an idle page gets a `Reconcile` per timer fire, and a burst costs one per message it arrived in. **(source)** | [`runtime.gleam`][src-rt-loop], `loop` |
| Selectors added with `select` are never removed. | `select` from `update` leaks a subject per call. **(source)** | [`runtime.gleam`][src-rt-loop], `EffectAddedSelector` |
| A registered client's death does not stop the runtime. | Forgetting `lustre.shutdown()` leaves a process per closed page. | [basic setup example][ex-basic]; `MonitorReportedDown` **(source)** |
| `before_paint` and `after_paint` never run in a server component. | DOM measurement or focus effects silently do nothing. | [`lustre/effect`][doc-effect] |
| Conditional `prevent_default` and `stop_propagation` are impossible. | `event.advanced` flags have no effect. | [`lustre/event`][doc-event], `advanced` |
| `memo` compares dependencies with `=:=` on Erlang, not by reference. | Equal rebuilt values count as unchanged, and cost a deep comparison. | [`lustre/element`][doc-element], `ref` |
| The server decoder has no arm for `ContextProvided` (`kind` 4). | Context values from the browser are dropped; a `Batch` containing one fails to decode as a whole. **(source)** | [`transport.gleam`][src-transport], `server_message_decoder` |
| The client reconnects on any close code but 1000, forever, capped at 10 s. | After a daemon restart, an open page retries and gets `401` every 10 s, with nothing on the page saying so. A refused handshake is retried too, so a page's own end must be a 1000 close after the component drew it. **(source)** | [`server_component.ffi.mjs`][src-client-ws], `WebsocketTransport` |
| The client reads `csrf-token` once, when `route` is set, and sends the string `null` when none is present; changing `csrf-token` on a connected element closes and reconnects. | Set `csrf-token` before `route`, or the socket opens without the page nonce and is refused. **(source)** | [`server_component.ffi.mjs`][src-client], `attributeChangedCallback` |
| The default `ws` method passes an `http:` URL to `new WebSocket`. | Needs a browser that accepts `http(s)` URLs there. **(source)** | same |
| `register_callback` with an anonymous function cannot be deregistered. | Use `register_subject` on Erlang. | [`lustre/server_component`][doc-sc] |
| `server_component.script()` inlines the runtime. | Refused by Loom's CSP. | [`lustre/server_component`][doc-sc] |
| `autofocus` focuses the element each time the attribute is added. | Toggling it steals focus. **(source)** | [`reconciler.ffi.mjs`][src-reconciler] |
| Properties are not rendered by `to_string`. | String-based tests cannot see them. | [attributes vs properties hint][hint-attrs] |
| Keyed children: an empty key means unkeyed, and a duplicate key keeps only the last child in the lookup. | Duplicate keys give undefined diffs. **(source)** | [`keyed.gleam`][src-keyed], `do_extract_keyed_children` |
| Keys containing tab, carriage return or newline. | They collide with the event path separators. **(source)** | [`path.gleam`][src-path] |
| `unsafe_raw_html`, `html.script`, `html.style` take raw strings. | XSS, and refused by CSP. | [`lustre/element`][doc-element] |
| Controlled inputs over a socket. | Keystrokes can be overwritten by a late `value`. **(source)** | [`diff.gleam`][src-diff-controlled], `is_controlled` |
| `form_associated` and the form callbacks do nothing in server components. | | [`lustre/component`][doc-component] |
| The `lustre` module page links guides `08-components` and `09-server-components`. | Both 404 for 5.7.1. | [`lustre`][doc-lustre] |
| The "for LiveView developers" page shows `ServerComponent(init, update, view)` and `lustre.start_server_component(component, req, Nil)`. | Neither matches the 5.7.1 API; follow the module docs and examples. | [for LiveView devs][ref-liveview] |

## 9. Checklist for a PR that touches `web_view`

- [ ] No session logic in `web_view`: every decision about frames,
      captures, replies or approvals is in `session_view`, where the
      terminal uses it too.
- [ ] Engine effects are performed by one `effect.from` per list, in
      order; nothing splits them across `effect.batch`.
- [ ] No effect blocks the runtime; blocking work is in the relay or another
      process that reports back through a `select`ed subject.
- [ ] `select` is `server_component.select`, run once per source from
      `init`, never from `update`.
- [ ] `init`'s effects finish well inside the 1000 ms start budget.
- [ ] `view` does no projection or other work proportional to the session;
      derived data is computed in `update` and kept in the model.
- [ ] Lists whose items change at the head or carry handlers are keyed by
      an engine identity; no key contains tab, CR or LF.
- [ ] Every handler in the tree is one the page's role may send; an
      observer's view has only the "Load older" click, at
      `component.older_path`, the chips' clicks, the Home button's click at
      `component.home_path` and the dividers' clicks at
      `component.fold_click`'s exact path, which `ui_socket.observer_accepts`
      admits and `page_events_test` pins. `update` re-checks each command against the
      current state.
- [ ] Session content appears only as text nodes; no attribute name,
      `href`/`src`/`action`, property, style, class string or key is built
      from it; no `unsafe_raw_html`, `html.script` or `html.style`.
- [ ] Event decoders produce domain types, bound their fields, use
      `server_component.include` for exactly what they read, and treat
      unexpected form fields as a refusal.
- [ ] No new inline script or style; the CSP in `page` is unchanged or the
      change is argued in a 051 addendum. `runtime_asset` matches the pin.
- [ ] Every class is a complete literal string, and `make gen-client` was
      run after changing a class, `packages/web_client` or its stylesheet
      input (`make client-check` passes).
- [ ] A client component renders only its own numeric or identity
      attributes and the server's slotted children, and handles no key and
      takes no focus, except `<loom-composer>` in its own editor (see
      section 3, "Client components inside the server component").
- [ ] A control that reaches an owner-only daemon action is drawn only where
      the daemon gave the page the capability (`Transport.invite` is `Some`),
      its path is admitted by the owner's socket alone
      (`ui_socket.owner_accepts`; `component.invite_path`), and the daemon
      checks the principal again. Nothing it shows is kept in the model after
      it is dismissed.
- [ ] Controls are real buttons with labels; the transcript is a `log` and
      the status a `status`; nothing uses `autofocus`; the approval card
      never takes focus and defaults to Deny.
- [ ] Tests: `simulate` for the update/view contract, including a history
      check for refused events; the parity test extended for any new
      engine-driven state; route tests for any change to `ui_socket`,
      `ui_relay` or `page`.
- [ ] Literate docs and stanzas per `docs/gleam-style.md` (R10 gates); no
      naked `Bool`; any process machinery outside Lustre's runtime goes
      through weft.
- [ ] `packages/web_view/CLAUDE.md` and `AGENTS.md` updated if types,
      messages or dependencies changed; `make check-web_view`,
      `make lint` and `make doc-check` pass by their own exit codes.

## Sources

Documentation pages (5.7.1):

[doc-lustre]: https://lustre.hexdocs.pm/5.7.1/lustre.html
[doc-effect]: https://lustre.hexdocs.pm/5.7.1/lustre/effect.html
[doc-element]: https://lustre.hexdocs.pm/5.7.1/lustre/element.html
[doc-html]: https://lustre.hexdocs.pm/5.7.1/lustre/element/html.html
[doc-keyed]: https://lustre.hexdocs.pm/5.7.1/lustre/element/keyed.html
[doc-attribute]: https://lustre.hexdocs.pm/5.7.1/lustre/attribute.html
[doc-event]: https://lustre.hexdocs.pm/5.7.1/lustre/event.html
[doc-sc]: https://lustre.hexdocs.pm/5.7.1/lustre/server_component.html
[doc-component]: https://lustre.hexdocs.pm/5.7.1/lustre/component.html
[doc-simulate]: https://lustre.hexdocs.pm/5.7.1/lustre/dev/simulate.html
[doc-query]: https://lustre.hexdocs.pm/5.7.1/lustre/dev/query.html
[doc-state]: https://lustre.hexdocs.pm/5.7.1/guide/02-state-management.html
[doc-ssr]: https://lustre.hexdocs.pm/5.7.1/guide/05-server-side-rendering.html
[doc-fullstack]: https://lustre.hexdocs.pm/guide/06-full-stack-applications.html
[hint-pure]: https://github.com/lustre-labs/lustre/blob/v5.7.1/pages/hints/pure-functions.md
[hint-attrs]: https://github.com/lustre-labs/lustre/blob/v5.7.1/pages/hints/attributes-vs-properties.md
[hint-lists]: https://github.com/lustre-labs/lustre/blob/v5.7.1/pages/hints/rendering-lists.md
[hint-inputs]: https://github.com/lustre-labs/lustre/blob/v5.7.1/pages/hints/controlled-vs-uncontrolled-inputs.md
[ref-liveview]: https://github.com/lustre-labs/lustre/blob/v5.7.1/pages/reference/for-liveview-devs.md
[ex-sc]: https://github.com/lustre-labs/lustre/tree/v5.7.1/examples/06-server-components
[ex-basic]: https://github.com/lustre-labs/lustre/blob/v5.7.1/examples/06-server-components/01-basic-setup/src/app.gleam
[ex-csrf]: https://github.com/lustre-labs/lustre/blob/v5.7.1/examples/06-server-components/06-csrf-protection/src/app.gleam

- [`lustre`][doc-lustre], [`lustre/effect`][doc-effect],
  [`lustre/element`][doc-element], [`lustre/element/html`][doc-html],
  [`lustre/element/keyed`][doc-keyed], [`lustre/attribute`][doc-attribute],
  [`lustre/event`][doc-event], [`lustre/server_component`][doc-sc],
  [`lustre/component`][doc-component], [`lustre/dev/simulate`][doc-simulate],
  [`lustre/dev/query`][doc-query]. The `svg` and `mathml` element modules
  have nothing specific to server components.
- Guides: [quickstart](https://lustre.hexdocs.pm/5.7.1/guide/01-quickstart.html),
  [state management][doc-state],
  [side effects](https://lustre.hexdocs.pm/5.7.1/guide/03-side-effects.html),
  [server-side rendering][doc-ssr],
  [full-stack applications](https://lustre.hexdocs.pm/5.7.1/guide/06-full-stack-applications.html),
  and the two deployment guides, which do not discuss server components.
- Hints: [pure functions][hint-pure], [attributes vs properties][hint-attrs],
  [rendering lists][hint-lists], [controlled vs uncontrolled inputs][hint-inputs].
- Examples: [server components][ex-sc], in particular
  [basic setup][ex-basic] and [CSRF protection][ex-csrf].

Source at the `v5.7.1` tag:

[src-effect-type]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/effect.gleam#L96-L165
[src-effect-select]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/effect.gleam#L236-L254
[src-effect-batch]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/effect.gleam#L310-L421
[src-lustre-ssc]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre.gleam#L389-L450
[src-app]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/app.gleam#L54-L70
[src-rt-state]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/server/runtime.gleam#L40-L71
[src-rt-start]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/server/runtime.gleam#L73-L123
[src-rt-loop]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/server/runtime.gleam#L158-L359
[src-rt-client]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/server/runtime.gleam#L361-L452
[src-transport]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/transport.gleam#L13-L291
[src-cache]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/cache.gleam#L449-L524
[src-path]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/path.gleam#L11-L71
[src-diff]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/diff.gleam#L34-L92
[src-diff-memo]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/diff.gleam#L613-L664
[src-diff-controlled]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/diff.gleam#L699-L710
[src-ref]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/internals/ref.gleam
[src-element]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/element.gleam#L180-L262
[src-keyed]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/element/keyed.gleam#L176-L205
[src-style]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/attribute.gleam#L434-L465
[src-vattr]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/vattr.gleam#L233-L279
[src-vnode]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/vnode.gleam#L297-L380
[src-simulate]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/dev/simulate.gleam#L184-L247
[src-client]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/client/server_component.ffi.mjs#L85-L135
[src-client-mount]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/client/server_component.ffi.mjs#L139-L175
[src-spa-runtime]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/client/runtime.ffi.mjs#L90-L100
[src-client-event]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/client/server_component.ffi.mjs#L427-L500
[src-client-ws]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/runtime/client/server_component.ffi.mjs#L507-L618
[src-reconciler]: https://github.com/lustre-labs/lustre/blob/v5.7.1/src/lustre/vdom/reconciler.ffi.mjs#L505-L700

The runtime, transport, cache, path and diff modules are internal and have
no documentation page; the links above are the only reference for them.
