//// Runs the typed controller inside the opaque Mermaid iframe.
////
//// Lustre owns this document's message loop, not the diagram DOM. Its view is
//// empty and mounted in a separate hidden node, so a controller update cannot
//// reconcile away the SVG that the vendor generated. The pure controller
//// decides which effects may run; this module interprets them in order over
//// the minimal browser/vendor binding. It never forwards SVG or diagnostics.
////
//// The fixed bootstrap injects the pinned vendor object. Neither request data
//// nor the session page can choose an implementation or change these calls.

import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import lustre
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import web_mermaid/controller
import web_mermaid/internal/ffi_dom

// The runtime holds only the vendor handle and the controller's pure state.
type Model {
  Model(vendor: ffi_dom.Vendor, state: controller.Model)
}

/// Starts the isolated frame's application against its fixed hidden mount.
///
/// An absent mount reports failure; the parent retains its source fallback.
/// The document owns this application and its observers until frame teardown.
///
/// ## Examples
///
/// ```gleam
/// // let _ = web_mermaid.start(vendor)
/// ```
pub fn start(vendor: ffi_dom.Vendor) -> Result(Nil, lustre.Error) {
  lustre.application(init, update, view)
  |> lustre.start("#controller", vendor)
  |> result.replace(Nil)
}

fn init(vendor: ffi_dom.Vendor) -> #(Model, Effect(controller.Msg)) {
  #(Model(vendor, controller.new()), subscribe())
}

fn update(
  model: Model,
  message: controller.Msg,
) -> #(Model, Effect(controller.Msg)) {
  let #(state, effects) = controller.update(model.state, message)
  #(Model(..model, state:), perform(model.vendor, effects))
}

// No renderer DOM belongs to Lustre. The diagram is the hidden mount's
// sibling, so every update here leaves that vendor-owned subtree untouched.
fn view(_: Model) -> Element(controller.Msg) {
  element.none()
}

// The listener exists before Ready is sent. Window identity is checked before
// decoding data; an opaque origin's "null" string is not a sender identity.
fn subscribe() -> Effect(controller.Msg) {
  use dispatch <- effect.from
  ffi_dom.listen_messages(fn(event) {
    case ffi_dom.is_parent_message(event) {
      False -> Nil
      True -> {
        let _ =
          decode.run(ffi_dom.message_data(event), decode.string)
          |> result.map(fn(text) {
            case controller.input(text) {
              controller.Accepted(request) ->
                dispatch(controller.Requested(request))
              controller.Forbidden(revision) ->
                dispatch(controller.Refused(revision))
              controller.Ignored -> Nil
            }
          })
        Nil
      }
    }
  })

  // The controller compares widths, so its own height updates cannot cause
  // a feedback loop of resize reports and parent height assignments.
  let root = ffi_dom.document_element()
  let observer =
    ffi_dom.resize_observer(fn() {
      dispatch(controller.Resized(ffi_dom.width(root)))
    })
  ffi_dom.observe(observer, root)
  ffi_dom.send_text(controller.reply_json(controller.Ready))
}

fn perform(
  vendor: ffi_dom.Vendor,
  effects: List(controller.Effect),
) -> Effect(controller.Msg) {
  use dispatch <- effect.from
  list.each(effects, fn(effect) {
    case effect {
      controller.Begin(request) -> begin(vendor, request, dispatch)
      controller.Inspect(revision, svg) -> inspect(revision, svg, dispatch)
      controller.Clear -> {
        let _ = diagram_host() |> result.map(ffi_dom.clear)
        Nil
      }
      controller.ReplyToParent(reply) ->
        ffi_dom.send_text(controller.reply_json(reply))
      controller.Measure(revision) -> measure(revision, dispatch)
    }
  })
}

// Fixed configuration is produced in Gleam. The vendor promise reports only
// a Result carrying SVG text, and only the controller can authorize inspection.
fn begin(
  vendor: ffi_dom.Vendor,
  request: controller.Request,
  dispatch: fn(controller.Msg) -> Nil,
) -> Nil {
  let revision = request.revision
  let began = {
    use Nil <- result.try(ffi_dom.initialize(
      vendor,
      controller.configuration(request.theme),
    ))
    use host <- result.try(diagram_host())
    ffi_dom.clear(host)
    ffi_dom.render(
      vendor,
      "loom-diagram-" <> int.to_string(revision),
      request.source,
      host,
      fn(outcome) { dispatch(controller.Rendered(revision, outcome)) },
    )
    Ok(Nil)
  }
  case began {
    Ok(Nil) -> Nil
    Error(Nil) -> dispatch(controller.Rendered(revision, Error(Nil)))
  }
}

// Inspection is synchronous inside one event-loop turn. The controller has
// already accepted the render revision; publication is checked again when
// the measured result is dispatched, before any reply reaches the parent.
fn inspect(
  revision: Int,
  svg: String,
  dispatch: fn(controller.Msg) -> Nil,
) -> Nil {
  let inspected = {
    use parsed <- result.try(ffi_dom.parse_svg(svg))
    use root <- result.try(ffi_dom.document_root(parsed))
    let nodes =
      [root, ..ffi_dom.query_selector_all(root, "*")]
      |> list.map(node_info)
    use Nil <- result.try(case controller.safe_svg(nodes) {
      True -> Ok(Nil)
      False -> Error(Nil)
    })
    use host <- result.try(diagram_host())

    // Nothing from the parsed document is attached before policy validation.
    let shown = ffi_dom.import_node(root)
    ffi_dom.clear(host)
    ffi_dom.append(host, shown)
    ffi_dom.set_attribute(shown, "role", "img")
    ffi_dom.set_attribute(shown, "aria-label", "Rendered Mermaid diagram")
    ffi_dom.set_style(shown, "max-width", "100%")
    ffi_dom.set_style(shown, "height", "auto")
    Ok(ffi_dom.height(shown))
  }
  dispatch(controller.Published(revision, inspected))
}

fn node_info(node: ffi_dom.Element) -> controller.Node {
  let attributes =
    ffi_dom.attributes(node)
    |> list.map(fn(attribute) {
      controller.Attribute(
        ffi_dom.attribute_name(attribute),
        ffi_dom.attribute_value(attribute),
      )
    })
  controller.Node(ffi_dom.local_name(node), attributes)
}

fn measure(revision: Int, dispatch: fn(controller.Msg) -> Nil) -> Nil {
  let _ =
    diagram_host()
    |> result.try(fn(host) { ffi_dom.query_selector(host, "svg") })
    |> result.map(fn(svg) {
      dispatch(controller.Measured(revision, ffi_dom.height(svg)))
    })
  Nil
}

fn diagram_host() -> Result(ffi_dom.Element, Nil) {
  ffi_dom.query_selector(ffi_dom.document_node(), "#diagram")
}
