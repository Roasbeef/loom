//// `<loom-mermaid>` keeps diagram source in the session page and rendering
//// in an opaque, script-only sandbox. The server supplies a text-only `pre`
//// child; no source is ever an attribute, URL, storage item or HTML here.
////
//// The frame's separately served policy forbids network access and storage.
//// A message is trusted only when its source is this element's frame window,
//// then `mermaid_rule` checks its revision and dimensions. No SVG or exception object
//// crosses that boundary; a bounded diagnostic is rendered only as text. The default slot stays selectable under a
//// native source disclosure, and a failed render leaves it open.
////
//// A frame is created only once the element comes within a viewport of the
//// visible area. Each frame carries its own copy of the 5.4 MB renderer and
//// its heap, about 20 to 40 MB, so a transcript opened with two dozen
//// diagrams used to start that many renderers at once. Until then the source
//// stays disclosed and any request waits for the frame's ready message.
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

/// Whether the element has come near enough to the viewport to own a frame.
pub type Distance {
  /// Not yet within a viewport of the visible area; no frame exists.
  Distant

  /// Seen within that margin at least once while connected; the frame stays.
  Near
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

/// Whether the diagram box is inline in the transcript or expanded to full screen.
pub type ViewMode {
  /// Rendered inline inside the transcript column.
  Inline

  /// Expanded to a full-viewport overlay.
  Expanded
}

/// The DOM resources owned by a connected element.
pub type Resources {
  Resources(
    /// The element's own shadow root, not the session component's.
    root: ffi_dom.Element,
    /// Changes to that source trigger another read.
    source: ffi_dom.Observer,
    /// Explicit theme changes trigger another read.
    theme: ffi_dom.Observer,
    /// Reports the element coming within a viewport of the visible area.
    approach: ffi_dom.Observer,
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
    /// Whether a frame may exist at all yet.
    distance: Distance,
    /// Owned only while connected.
    resources: Option(Resources),
    /// Fixed feedback for an explicit copy press.
    copy: Copy,
    /// Whether the diagram is inline or expanded to full screen.
    view_mode: ViewMode,
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

  /// The element came within a viewport of the visible area.
  Approached

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

  /// The reader pressed Expand or Collapse.
  ToggleExpand

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
  #(Model(rule.new(), Loading, Distant, None, Untouched, Inline), effect.none())
}

/// Applies lifecycle and rendering events to the mermaid viewer model.
fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  // Dispatch state transitions for the incoming viewer message.
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
      #(
        Model(diagram, Loading, Distant, None, Untouched, Inline),
        cleanup(model.resources),
      )
    }
    Approached -> #(Model(..model, distance: Near), effect.none())
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
    ToggleExpand -> {
      // Toggle between inline and expanded viewer presentation modes.
      let next_mode = case model.view_mode {
        Inline -> Expanded
        Expanded -> Inline
      }

      #(Model(..model, view_mode: next_mode), effect.none())
    }
    Written(revision, outcome) -> {
      // Map clipboard write outcome to copy status indicator.
      let notice = case outcome {
        Ok(Nil) -> Copied
        Error(Nil) -> CopyRefused
      }

      // Update copy notification if the response matches current revision.
      case revision == model.diagram.revision {
        True -> #(Model(..model, copy: notice), effect.none())
        False -> #(model, effect.none())
      }
    }
  }
}

/// Re-evaluates diagram source text and arms rendering timers on change.
fn reread(
  model: Model,
  source: String,
  theme: rule.Theme,
  units: Int,
) -> #(Model, Effect(Msg)) {
  let diagram = rule.read(model.diagram, source, theme, units)

  // Skip updates when revision is unchanged; otherwise arm debounce timers.
  case diagram.revision == model.diagram.revision {
    True -> #(model, effect.none())
    False -> {
      let revision = diagram.revision

      // The render deadline is armed in `send`, when the request is posted,
      // not here: counting the frame's bundle download against it marked
      // renderable diagrams unavailable on a slow link.
      let wait = case diagram.phase {
        rule.Waiting -> {
          use dispatch <- effect.from
          ffi_dom.after(rule.debounce_ms, fn() { dispatch(Due(revision)) })
        }
        rule.Empty
        | rule.Rendering
        | rule.Shown(_)
        | rule.TooLarge
        | rule.Unavailable(_) -> effect.none()
      }

      // Empty and oversized source drop the iframe from the view, so the
      // next one loads afresh and must announce itself before a post; a
      // stale Ready would post into the unloaded window and start the
      // deadline against the load.
      let frame = case diagram.phase {
        rule.Empty | rule.TooLarge -> Loading
        rule.Waiting | rule.Rendering | rule.Shown(_) | rule.Unavailable(_) ->
          model.frame
      }

      #(Model(..model, diagram:, frame:, copy: Untouched), wait)
    }
  }
}

/// Mounts observer and event listener resources after initial paint.
fn mount() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let root = ffi_dom.as_element(root)
  let host = ffi_dom.host(root)

  // Install listeners only when host element remains connected to the DOM.
  case ffi_dom.is_connected(host) {
    True -> install(dispatch, root, host)

    // Removed before this paint: `Disconnected` already ran with nothing to
    // release, so installing now would leak a window listener for good.
    False -> Nil
  }
}

/// Configures mutation observers, media queries, and window message listeners.
fn install(
  dispatch: fn(Msg) -> Nil,
  root: ffi_dom.Element,
  host: ffi_dom.Element,
) -> Nil {
  let media = ffi_dom.media_query("(prefers-color-scheme: light)")
  let read = fn() { dispatch(read_source(host, media)) }
  let source = ffi_dom.mutation_observer(read)
  let theme = ffi_dom.mutation_observer(read)
  ffi_dom.observe_text(source, host)
  ffi_dom.observe_attribute(theme, ffi_dom.document_element(), "data-theme")

  // The observer reports the first approach at once when the element is
  // already in view, so a visible diagram is not delayed by it.
  let approach =
    ffi_dom.intersection_observer("100% 0px", fn() { dispatch(Approached) })
  ffi_dom.observe(approach, host)

  let media_listener = ffi_dom.add_listener(media, "change", fn(_) { read() })
  let messages =
    ffi_dom.add_listener(ffi_dom.get_window(), "message", fn(event) {
      dispatch(Answered(frame_reply(root, event)))
    })
  dispatch(
    Mounted(Resources(
      root,
      source,
      theme,
      approach,
      media,
      media_listener,
      messages,
    )),
  )
  read()
}

/// Reads mermaid diagram source and resolves active document color theme.
fn read_source(host: ffi_dom.Element, media: ffi_dom.Element) -> Msg {
  let source =
    ffi_dom.query_selector(host, ".mermaid-source")
    |> result.map(ffi_dom.text_content)
    |> result.unwrap("")

  // Determine dark or light theme preference from attribute or system query.
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

/// Extracts and decodes status replies posted from the child iframe window.
fn frame_reply(root: ffi_dom.Element, event: Dynamic) -> rule.Reply {
  let reply = {
    use frame <- result.try(ffi_dom.query_selector(root, "iframe"))

    // Ensure event originates from the matching sandboxed iframe.
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

/// Posts diagram render requests to the child iframe once loaded and ready.
fn send(model: Model) -> Effect(Msg) {
  // Post payload to iframe when frame is ready and diagram is rendering.
  case model.frame, model.diagram.phase, model.resources {
    Ready, rule.Rendering, Some(resources) -> {
      let request = rule.request(model.diagram)
      let revision = model.diagram.revision
      use dispatch, _ <- effect.after_paint
      let _ =
        ffi_dom.query_selector(resources.root, "iframe")
        |> result.map(fn(frame) { ffi_dom.post_to_frame(frame, request) })
      ffi_dom.after(rule.timeout_ms, fn() { dispatch(Expired(revision)) })
    }
    _, _, _ -> effect.none()
  }
}

/// Disconnects mutation observers and window listeners on component teardown.
fn cleanup(resources: Option(Resources)) -> Effect(Msg) {
  use _ <- effect.from

  // Disconnect active observers and remove event listeners.
  case resources {
    Some(resources) -> {
      ffi_dom.disconnect(resources.source)
      ffi_dom.disconnect(resources.theme)
      ffi_dom.disconnect(resources.approach)
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

/// Writes the raw diagram source text to the system clipboard.
fn copy(diagram: rule.State) -> Effect(Msg) {
  let source = diagram.source
  let revision = diagram.revision
  use dispatch <- effect.from
  ffi_dom.write_clipboard(source, fn(outcome) {
    dispatch(Written(revision, outcome))
  })
}

/// Renders diagram toolbar, sandboxed iframe container, and fallback source details.
fn view(model: Model) -> Element(Msg) {
  // Configure iframe layout height and disclosure properties by phase.
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
    | rule.Unavailable(_) -> #(
      1,
      [
        attribute.class("mermaid-frame mermaid-pending"),
        attribute.attribute("aria-hidden", "true"),
        attribute.attribute("tabindex", "-1"),
      ],
      attribute.attribute("open", ""),
    )
  }

  // Choose copy button label reflecting recent clipboard operation status.
  let label = case model.copy {
    Untouched -> "Copy source"
    Copied -> "Copied"
    CopyRefused -> "Copy unavailable — select source"
  }

  // Determine container CSS styling based on expanded view mode and render state.
  let box_class = case model.view_mode, model.diagram.phase {
    Expanded, rule.Shown(_) -> "mermaid-box mermaid-box-expanded"
    _, _ -> "mermaid-box"
  }

  // Resolve expand button toggle action label and aria attribute.
  let #(expand_label, aria_expanded) = case model.view_mode {
    Inline -> #("Expand", "false")
    Expanded -> #("Collapse", "true")
  }

  // Render expand action button when diagram render completes successfully.
  let expand_button = case model.diagram.phase {
    rule.Shown(_) ->
      html.button(
        [
          attribute.type_("button"),
          attribute.attribute("aria-expanded", aria_expanded),
          event.on_click(ToggleExpand),
        ],
        [html.text(expand_label)],
      )
    rule.Empty
    | rule.Waiting
    | rule.Rendering
    | rule.TooLarge
    | rule.Unavailable(_) -> element.none()
  }

  html.div([attribute.class(box_class)], [
    html.div([attribute.class("mermaid-toolbar")], [
      html.span([], [html.text(status(model.diagram.phase))]),
      html.div([attribute.class("mermaid-actions")], [
        expand_button,
        html.button([attribute.type_("button"), event.on_click(CopyPressed)], [
          html.text(label),
        ]),
      ]),
    ]),
    case model.distance, model.diagram.phase {
      Distant, _ | Near, rule.Empty | Near, rule.TooLarge -> element.none()
      Near, rule.Waiting
      | Near, rule.Rendering
      | Near, rule.Shown(_)
      | Near, rule.Unavailable(_)
      ->
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
    case model.diagram.phase {
      rule.Unavailable(diagnostic) if diagnostic != "" ->
        html.pre([attribute.class("mermaid-error"), attribute.role("status")], [
          html.text(diagnostic),
        ])
      rule.Empty
      | rule.Waiting
      | rule.Rendering
      | rule.Shown(_)
      | rule.TooLarge
      | rule.Unavailable(_) -> element.none()
    },
    html.details([attribute.class("mermaid-details"), disclosure], [
      html.summary([], [html.text("Mermaid source")]),
      component.default_slot([], []),
    ]),
  ])
}

/// Returns status banner text appropriate for current diagram phase.
fn status(phase: rule.Phase) -> String {
  case phase {
    rule.Empty -> "Mermaid"
    rule.Waiting | rule.Rendering -> "Rendering diagram…"
    rule.Shown(_) -> "Mermaid"
    rule.TooLarge -> "Diagram too large — showing source"
    rule.Unavailable(_) -> "Diagram unavailable — showing source"
  }
}
