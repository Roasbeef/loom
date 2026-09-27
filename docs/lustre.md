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
claim below is about that version. When the pin moves, re-check section 7
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
| Message: `msg.Msg` (`Arrived`, `Input`) | built by `tui/runtime` from etui events | `component.Msg`: `Arrived`, `Ticked` |
| Step: `tui.step(msg, model) -> #(Model, List(Effect))`; the lane's `session_channel` transitions | called by `tui.update` | called from the component's `update` |
| Effect: `tui/effect.Effect`, the lane's `session_channel.Out` | performed by `tui/runtime`, `tui/terminal_lane.perform` | performed by one `effect.from` in `component.perform` |
| Runtime: reads clocks, mailboxes, sockets; performs effects | `tui/runtime`, `tui/job_runner` | the Lustre runtime process, its `select` subscriptions, `ui_relay` |
| View | `tui/render` over etui | `component.view` over `lustre/element/html` |

Today the web host drives only the lane (`session_channel`) and
`transcript.project`; the step itself moves into the engine in the
build-out (ADR-014, "Why the step waits for the build-out phase"). The
table's middle column for the web host is what the build-out keeps.

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

### Option C in Lustre terms

ADR-013's phase 3 addendum chose option C: arrivals are messages that are
only filed, and reduction happens at a tick or a key in a fixed order. In
the component, `Arrived` appends to `filed`, and `Ticked` hands every filed
frame to `session_channel.receive` in arrival order, through
`operator.drain`, then runs `session_channel.tick`. One case does not wait
for the tick: while the lane has a request in flight
(`session_channel.in_flight`), an arrival runs the same reduction at once,
without re-arming the timer, so a credited transfer does not pay a tick
per chunk (ADR-014, the addendum on waking). A push to an idle lane is
still only filed. `component_test` pins both cases.

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
  arm in `mist/internal/websocket.gleam`), so a page Loom closes stays
  closed. A connection that drops without a close frame (the daemon
  restarted) is retried, and each retry is refused with a `401` until the
  person runs `loom --ui` again.

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
| browser to server | 4 | `ContextProvided` | `key`, `value`, **not decoded in 5.7.1** (section 7) |

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
context, and its view attaches no handler, so every one of these is
dropped. That is the "by type" layer of 051's read-only enforcement. The
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
- **Read host inputs in the mapping.** `component.arm` reads the clock in
  the selector's mapping function when the timer message is received, so
  `Ticked` carries the instant of the tick and `update` stays pure.

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
   socket (`Ended`), and exits. The socket waits two ticks so the ended
   state is drawn, then stops, which is step 1.
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
- **Session traffic** is bounded by option C: the component drains its
  whole filed buffer on each 250 ms tick, which bounds it by 250 ms of
  pushed frames plus the credited transfer (ADR-014).

### Cost of a message, and sizing

Every message the runtime handles, whatever its source, runs `update`,
then `view` on the whole model, then a diff of the whole new tree against
the old one, then a broadcast **(source)** ([`runtime.gleam`][src-rt-loop],
`EffectDispatchedMessage`, `ClientDispatchedMessage`). Nothing skips the
render when the model did not change. So:

- The cost of one message is the cost of `view` plus the diff. Keep `view`
  cheap: compute derived data in `update`, where it runs once per change,
  not in `view`, where it runs once per message (section 4).
- An idle page still receives a `Reconcile` per tick, four a second.
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
| BEAM messages in | `server_component.select` | `component.open` (relay inbox), `component.arm` (tick) |
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
  observer's view attaches none (051, "Read-only enforcement").
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
  `javascript:` URL, and the view must not depend on that.
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
  with a `case`, as `speaker_class` in `web_view/component` does.

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
would refuse them anyway. If the view ever needs rendered markdown, the
engine produces a tree of typed spans and the view maps each span to an
element.

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
(section 2). `component.apply` projects a capture once, when its
`Captured` update is applied, and keeps the keyed rows in the model, so a
frame or a tick that brings no capture costs the view no projection.

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
  a browser ([`lustre`][doc-lustre]), so using one inside the web view would
  mean shipping a client-side Gleam bundle as another asset, and running
  view logic in the browser. Loom does not do this.
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

## 6. Testing

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
(`component_test`):

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
hold every line's escaped text in order.

As the build-out moves the step into the engine, extend the pattern rather
than writing web-only assertions:

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

## 7. Gotchas and anti-patterns

All apply to 5.7.1. Re-check each when the pin moves.

| Gotcha | Consequence | Source |
|---|---|---|
| `effect.select` is `@internal`; the public API is `server_component.select`. | Code on `effect.select` depends on an unpublished function that can change in a patch release. | [`effect.gleam`][src-effect-select], `select` |
| `init`'s effects run inside the actor's 1000 ms initialiser. | A slow effect in `init` makes `start_server_component` fail with `InitTimeout`. **(source)** | [`runtime.gleam`][src-rt-start], `start` |
| Effects run synchronously in the runtime process. | A blocking effect stalls the page. **(source)** | [`runtime.gleam`][src-rt-start], `handle_effect` |
| `effect.batch` has no guaranteed order, and the server runs it in reverse. | Ordered work split across a batch runs backwards. **(source)** for the reversal | [`lustre/effect`][doc-effect]; [`effect.gleam`][src-effect-batch] |
| Every message renders, diffs and broadcasts, including dropped browser messages and no-op messages. | `view` cost is paid per message; an idle page gets a `Reconcile` per tick. **(source)** | [`runtime.gleam`][src-rt-loop], `loop` |
| Selectors added with `select` are never removed. | `select` from `update` leaks a subject per call. **(source)** | [`runtime.gleam`][src-rt-loop], `EffectAddedSelector` |
| A registered client's death does not stop the runtime. | Forgetting `lustre.shutdown()` leaves a process per closed page. | [basic setup example][ex-basic]; `MonitorReportedDown` **(source)** |
| `before_paint` and `after_paint` never run in a server component. | DOM measurement or focus effects silently do nothing. | [`lustre/effect`][doc-effect] |
| Conditional `prevent_default` and `stop_propagation` are impossible. | `event.advanced` flags have no effect. | [`lustre/event`][doc-event], `advanced` |
| `memo` compares dependencies with `=:=` on Erlang, not by reference. | Equal rebuilt values count as unchanged, and cost a deep comparison. | [`lustre/element`][doc-element], `ref` |
| The server decoder has no arm for `ContextProvided` (`kind` 4). | Context values from the browser are dropped; a `Batch` containing one fails to decode as a whole. **(source)** | [`transport.gleam`][src-transport], `server_message_decoder` |
| The client reconnects on any close code but 1000, forever, capped at 10 s. | After a daemon restart, an open page retries and gets `401` every 10 s. **(source)** | [`server_component.ffi.mjs`][src-client-ws], `WebsocketTransport` |
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

## 8. Checklist for a PR that touches `web_view`

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
      observer's view has none. `update` re-checks each command against the
      current state.
- [ ] Session content appears only as text nodes; no attribute name,
      `href`/`src`/`action`, property, style, class string or key is built
      from it; no `unsafe_raw_html`, `html.script` or `html.style`.
- [ ] Event decoders produce domain types, bound their fields, use
      `server_component.include` for exactly what they read, and treat
      unexpected form fields as a refusal.
- [ ] No new inline script or style; the CSP in `page` is unchanged or the
      change is argued in a 051 addendum. `runtime_asset` matches the pin.
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
