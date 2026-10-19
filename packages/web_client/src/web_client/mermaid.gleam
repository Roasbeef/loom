//// `<loom-mermaid>` keeps diagram source in the session page and rendering
//// in an opaque, script-only sandbox. The server supplies a text-only `pre`
//// child; no source is ever an attribute, URL, storage item or HTML here.
////
//// The frame's separately served policy forbids network access and storage.
//// A message is trusted only when its source is this element's frame window,
//// then `mermaid_rule` checks its revision and dimensions. No SVG or renderer
//// error crosses that boundary. The default slot stays selectable under a
//// native source disclosure, and a failed render leaves it open.
////
//// Observers and listeners live only while connected. Debounce and deadline
//// callbacks capture only a revision and dispatch, expire within ten seconds,
//// and cannot act on a disconnected or superseded revision.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/internal/ffi_dom
import web_client/mermaid_rule as rule

/// The tag selected only by a Mermaid code fence.
pub const name = "loom-mermaid"

/// Whether the isolated frame installed its message receiver.
pub type Frame {
  /// No request may be sent yet.
  Loading

  /// A request may be sent after the source's quiet interval.
  Ready
}

/// The last explicit clipboard action, never a renderer-supplied message.
pub type Copy {
  /// No clipboard write has completed for this source.
  Untouched

  /// The browser accepted the write.
  Copied

  /// The reader can still select the source when the clipboard is blocked.
  CopyRefused
}

/// The DOM resources owned by a connected element.
pub type Resources {
  Resources(
    /// The element's own shadow root, not the session component's.
    root: ffi_dom.Element,
    /// Its light DOM contains the server's source text.
    host: ffi_dom.Element,
    /// Changes to that source trigger another read.
    source: ffi_dom.Observer,
    /// Explicit theme changes trigger another read.
    theme: ffi_dom.Observer,
    /// System palette changes matter when no explicit theme is selected.
    media: ffi_dom.Element,
    /// The system palette listener, removed on disconnect.
    media_listener: ffi_dom.Listener,
    /// The frame message listener, removed on disconnect.
    messages: ffi_dom.Listener,
  )
}

/// State is source, revision and local browser resources, never session state.
pub type Model {
  Model(
    /// The pure revision and display lifecycle.
    diagram: rule.State,
    /// Whether the child has completed its initial load.
    frame: Frame,
    /// Owned only while connected.
    resources: Option(Resources),
    /// Fixed feedback for an explicit copy press.
    copy: Copy,
  )
}

/// Browser events admitted by this element.
pub type Msg {
  /// The element joined the document.
  Connected

  /// The element left the document.
  Disconnected

  /// Its listeners and observers have been installed.
  Mounted(resources: Resources)

  /// Its source and effective theme were read as text.
  Read(source: String, theme: rule.Theme, units: Int)

  /// A quiet interval ended for this revision.
  Due(revision: Int)

  /// The renderer's bounded waiting period ended.
  Expired(revision: Int)

  /// A message from this element's frame passed the source check.
  Answered(reply: rule.Reply)

  /// The reader pressed Copy source.
  CopyPressed

  /// The browser completed that clipboard write.
  Written(revision: Int, outcome: Result(Nil, Nil))
}

/// Registers the client element once for the browser document.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = mermaid.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(Model(rule.new(), Loading, None, Untouched), effect.none())
}

fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Connected -> #(model, mount())
    Mounted(resources) -> #(
      Model(..model, resources: Some(resources)),
      cleanup(model.resources),
    )
    Disconnected -> {
      let diagram =
        rule.State(
          "",
          model.diagram.theme,
          model.diagram.revision + 1,
          rule.Empty,
        )
      #(Model(diagram, Loading, None, Untouched), cleanup(model.resources))
    }
    Read(source, theme, units) -> reread(model, source, theme, units)
    Due(revision) -> {
      let diagram = rule.due(model.diagram, revision)
      let next = Model(..model, diagram:)
      #(next, send(next))
    }
    Expired(revision) -> #(
      Model(..model, diagram: rule.expire(model.diagram, revision)),
      effect.none(),
    )
    Answered(rule.Ready) -> {
      let next = Model(..model, frame: Ready)
      #(next, send(next))
    }
    Answered(reply) -> #(
      Model(..model, diagram: rule.receive(model.diagram, reply)),
      effect.none(),
    )
    CopyPressed -> #(model, copy(model.diagram))
    Written(revision, outcome) -> {
      let notice = case outcome {
        Ok(Nil) -> Copied
        Error(Nil) -> CopyRefused
      }
      case revision == model.diagram.revision {
        True -> #(Model(..model, copy: notice), effect.none())
        False -> #(model, effect.none())
      }
    }
  }
}

// Reading an unchanged source does nothing: a patch elsewhere in a streaming
// answer must not postpone this diagram or create more timers.
fn reread(
  model: Model,
  source: String,
  theme: rule.Theme,
  units: Int,
) -> #(Model, Effect(Msg)) {
  let diagram = rule.read(model.diagram, source, theme, units)
  case diagram.revision == model.diagram.revision {
    True -> #(model, effect.none())
    False -> {
      let revision = diagram.revision
      let wait = case diagram.phase {
        rule.Waiting -> {
          use dispatch <- effect.from
          ffi_dom.after(rule.debounce_ms, fn() { dispatch(Due(revision)) })
          ffi_dom.after(rule.debounce_ms + rule.timeout_ms, fn() {
            dispatch(Expired(revision))
          })
        }
        rule.Empty
        | rule.Rendering
        | rule.Shown(_)
        | rule.TooLarge
        | rule.Unavailable -> effect.none()
      }
      #(Model(..model, diagram:, copy: Untouched), wait)
    }
  }
}

// The element owns its own message receiver; window identity, not the opaque
// frame's "null" origin, distinguishes it from sibling diagrams and pages.
fn mount() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let root = ffi_dom.as_element(root)
  let host = ffi_dom.host(root)
  let media = ffi_dom.media_query("(prefers-color-scheme: light)")
  let read = fn() { dispatch(read_source(host, media)) }
  let source = ffi_dom.mutation_observer(read)
  let theme = ffi_dom.mutation_observer(read)
  ffi_dom.observe_text(source, host)
  ffi_dom.observe_attribute(theme, ffi_dom.document_element(), "data-theme")

  let media_listener = ffi_dom.add_listener(media, "change", fn(_) { read() })
  let messages =
    ffi_dom.add_listener(ffi_dom.get_window(), "message", fn(event) {
      dispatch(Answered(frame_reply(root, event)))
    })
  dispatch(
    Mounted(Resources(
      root,
      host,
      source,
      theme,
      media,
      media_listener,
      messages,
    )),
  )
  read()
}

fn read_source(host: ffi_dom.Element, media: ffi_dom.Element) -> Msg {
  let source =
    ffi_dom.query_selector(host, ".mermaid-source")
    |> result.map(ffi_dom.text_content)
    |> result.unwrap("")
  let theme = case ffi_dom.attribute(ffi_dom.document_element(), "data-theme") {
    Ok("light") -> rule.Light
    Ok("dark") -> rule.Dark
    _ ->
      case ffi_dom.media_matches(media) {
        True -> rule.Light
        False -> rule.Dark
      }
  }
  Read(source, theme, ffi_dom.utf16_length(source))
}

fn frame_reply(root: ffi_dom.Element, event: Dynamic) -> rule.Reply {
  let reply = {
    use frame <- result.try(ffi_dom.query_selector(root, "iframe"))
    use Nil <- result.try(case ffi_dom.message_from_frame(frame, event) {
      True -> Ok(Nil)
      False -> Error(Nil)
    })
    use text <- result.try(
      decode.run(ffi_dom.message_data(event), decode.string)
      |> result.replace_error(Nil),
    )
    Ok(rule.reply(text))
  }
  result.unwrap(reply, rule.Ignored)
}

// A request is text data sent only to this element's fixed sandbox URL. The
// wildcard is required because sandboxing deliberately gives it an opaque origin.
fn send(model: Model) -> Effect(Msg) {
  case model.frame, model.diagram.phase, model.resources {
    Ready, rule.Rendering, Some(resources) -> {
      let request = rule.request(model.diagram)
      use _, _ <- effect.after_paint
      let _ =
        ffi_dom.query_selector(resources.root, "iframe")
        |> result.map(fn(frame) { ffi_dom.post_to_frame(frame, request) })
      Nil
    }
    _, _, _ -> effect.none()
  }
}

fn cleanup(resources: Option(Resources)) -> Effect(Msg) {
  use _ <- effect.from
  case resources {
    Some(resources) -> {
      ffi_dom.disconnect(resources.source)
      ffi_dom.disconnect(resources.theme)
      ffi_dom.remove_listener(
        resources.media,
        "change",
        resources.media_listener,
      )
      ffi_dom.remove_listener(
        ffi_dom.get_window(),
        "message",
        resources.messages,
      )
    }
    None -> Nil
  }
}

fn copy(diagram: rule.State) -> Effect(Msg) {
  let source = diagram.source
  let revision = diagram.revision
  use dispatch <- effect.from
  ffi_dom.write_clipboard(source, fn(outcome) {
    dispatch(Written(revision, outcome))
  })
}

fn view(model: Model) -> Element(Msg) {
  // Only a shown diagram is visible and focusable; every other phase keeps
  // the frame loaded but hidden, with the source disclosure open instead.
  let #(height, frame_state, disclosure) = case model.diagram.phase {
    rule.Shown(height) -> #(
      height,
      [
        attribute.class("mermaid-frame"),
        attribute.attribute("aria-hidden", "false"),
        attribute.attribute("tabindex", "0"),
      ],
      attribute.none(),
    )
    rule.Empty
    | rule.Waiting
    | rule.Rendering
    | rule.TooLarge
    | rule.Unavailable -> #(
      1,
      [
        attribute.class("mermaid-frame mermaid-pending"),
        attribute.attribute("aria-hidden", "true"),
        attribute.attribute("tabindex", "-1"),
      ],
      attribute.attribute("open", ""),
    )
  }
  let label = case model.copy {
    Untouched -> "Copy source"
    Copied -> "Copied"
    CopyRefused -> "Copy unavailable — select source"
  }

  html.div([attribute.class("mermaid-box")], [
    html.div([attribute.class("mermaid-toolbar")], [
      html.span([], [html.text(status(model.diagram.phase))]),
      html.button([attribute.type_("button"), event.on_click(CopyPressed)], [
        html.text(label),
      ]),
    ]),
    case model.diagram.phase {
      rule.Empty | rule.TooLarge -> element.none()
      rule.Waiting | rule.Rendering | rule.Shown(_) | rule.Unavailable ->
        element.element(
          "iframe",
          [
            attribute.src("/ui/assets/mermaid.html"),
            attribute.title("Mermaid diagram"),
            attribute.attribute("sandbox", "allow-scripts"),
            attribute.attribute("referrerpolicy", "no-referrer"),
            attribute.attribute("height", int.to_string(height)),
            ..frame_state
          ],
          [],
        )
    },
    html.details([attribute.class("mermaid-details"), disclosure], [
      html.summary([], [html.text("Mermaid source")]),
      component.default_slot([], []),
    ]),
  ])
}

fn status(phase: rule.Phase) -> String {
  case phase {
    rule.Empty -> "Mermaid"
    rule.Waiting | rule.Rendering -> "Rendering diagram…"
    rule.Shown(_) -> "Mermaid"
    rule.TooLarge -> "Diagram too large — showing source"
    rule.Unavailable -> "Diagram unavailable — showing source"
  }
}
