//// `<loom-attach name="images" limits="...">`: the operator composer's image
//// attachments (protocol-change/051, the addendum on images).
////
//// The element draws a "+" button, labelled "Attach image" for assistive technology, the chips of the images
//// already attached each with a Remove button, and a line saying why a file
//// was refused. An image comes from the file picker the button opens, from a
//// paste into the composer or from a drop onto it, and its bytes are read in the browser and held
//// here until the form is sent. The element is form-associated: it submits
//// its images under its `name` as one field, a JSON array of their base64
//// text (`attach_rule.value`), so they reach the server in the same submit
//// event as the draft, and the daemon decodes and checks every one
//// (`web_view/image.admit`). Nothing is sent when the element holds none.
////
//// The server draws the element inside the composer's keyed editor, so a
//// draft that was sent replaces it with an empty one and a draft that was
//// refused keeps what the operator attached.
////
//// ## What the element is told
////
//// One attribute, `limits`, the daemon's own numbers and media types as JSON,
//// which `attach_rule.limits` decodes. It holds no session text. The `name`
//// attribute is the form field's, and is the daemon's constant as well.
////
//// ## Pastes
////
//// A `paste` into the composer's form that carries image files attaches them
//// and is cancelled, so the browser does not also insert the file's name as
//// text. A paste with no image file is left alone. The listener is on the
//// form the element is in, and it is removed when the element leaves the
//// page: the element is replaced with every sent draft, and a listener left
//// behind would go on attaching to an element that is gone.
////
//// ## Drops
////
//// Image files dragged onto the composer's form are attached through the
//// same vetting a paste takes (`attach_rule.choose`), so the limits and the
//// refusal words are one set. The listeners are on the form, which is the
//// whole composer box and not only its editor, and they cancel a drag only
//// when it carries files (`drop_rule`), so text dragged into the editor
//// keeps working. While files are over the form and a place is free, the
//// element draws a tinted overlay with a hint (`drop_rule.surface`); the
//// overlay takes no pointer events. The browser reports crossing each child
//// as a leave and an enter, so a leave ends the drag only when the element
//// the pointer went to (`relatedTarget`) is not inside the form, and a leave
//// that never comes, because the server replaced the element under the
//// pointer, is repaired by the next enter or by the document's own `drop` or
//// `dragend` (`drop_rule.Drag`). A form with no place left
//// draws no overlay and still cancels the drag, and a page with no
//// attach element at all is covered by `web_client/drop_guard`.
////
//// ## What it does not do
////
//// It handles no key, takes no focus of its own and never touches the
//// approval cards, which are outside the composer's form. It draws no image:
//// a chip is a file's name and size, text nodes both. What the operator
//// attached is theirs, and the transcript shows it after the daemon accepts
//// it, from the daemon's own copy.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/attach_rule.{type Candidate, type Limits, type State}
import web_client/drop_rule
import web_client/internal/ffi_dom

/// The element's tag.
pub const name = "loom-attach"

/// What the element knows: the rules' state, the listeners it put on its
/// form and the document, so leaving the page can take them off again, and
/// whether a file drag is over the composer.
pub type Model {
  Model(state: State, listening: Option(Listeners), dragging: drop_rule.Drag)
}

/// The running listeners, each with the element it is on and the event it
/// hears.
pub type Listeners {
  Listeners(heard: List(#(ffi_dom.Element, String, ffi_dom.Listener)))
}

/// Everything the element can be told.
pub type Msg {
  /// The server sent its limits.
  Configured(limits: Limits)

  /// The Attach image button was pressed.
  PickRequested

  /// The file picker's `change` reported these files.
  Chosen(files: List(ffi_dom.File))

  /// The composer's form heard a paste that holds these image files.
  Pasted(files: List(ffi_dom.File))

  /// A file finished reading: the `data:` URL, or nothing when it failed.
  Read(id: Int, read: Result(String, Nil))

  /// A chip's Remove button.
  Removed(id: Int)

  /// The element joined the page.
  Connected

  /// The element left the page.
  Disconnected

  /// A drag that carries these kinds of data entered an element of the
  /// composer.
  DragEntered(types: List(String))

  /// A drag that carries these kinds of data left an element of the composer
  /// for `towards`.
  DragLeft(types: List(String), towards: drop_rule.Destination)

  /// A drop or a drag's end was heard anywhere on the page, so no drag is
  /// over the composer any more.
  DragEnded

  /// These files were dropped on the composer.
  Dropped(files: List(ffi_dom.File))

  /// The paste and drag listeners are on the form.
  Listening(listeners: Listeners)
}

/// Registers the element with the browser, form-associated so its value joins
/// the form it is in.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = attach.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.form_associated(),
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
    component.on_attribute_change("limits", fn(value) {
      Ok(Configured(attach_rule.limits(value)))
    }),
  ])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(state: attach_rule.start(), listening: None, dragging: drop_rule.away),
    effect.none(),
  )
}

/// Applies one message. The file input, the form and the file reads are
/// reached only inside effects, so `update` stays a function of its
/// messages.
///
/// ## Examples
///
/// ```gleam
/// // attach.update(model, attach.Removed(1))
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Configured(limits:) -> #(
      Model(..model, state: attach_rule.configured(model.state, limits)),
      effect.none(),
    )
    PickRequested -> #(model, picking())

    // A choice and a paste are vetted alike. The state takes every file it
    // accepts as reading at once, so two files chosen together cannot both
    // take the last place, and the effect starts one read for each.
    Chosen(files:) -> {
      let #(state, reads) = attach_rule.choose(model.state, candidates(files))
      #(Model(..model, state:), effect.batch([reading(reads), clearing()]))
    }
    Pasted(files:) -> {
      let #(state, reads) = attach_rule.choose(model.state, candidates(files))
      #(Model(..model, state:), reading(reads))
    }

    // A drop is vetted as a paste is. It also ends the drag, since no leave
    // follows a drop, and an element with no place left refuses the files
    // with the limit's own words and attaches none.
    Dropped(files:) -> {
      let #(state, reads) = attach_rule.choose(model.state, candidates(files))
      #(
        Model(..model, state:, dragging: drop_rule.dropped(model.dragging)),
        reading(reads),
      )
    }
    DragEntered(types:) -> #(
      Model(..model, dragging: drop_rule.entered(model.dragging, types)),
      effect.none(),
    )
    DragLeft(types:, towards:) -> #(
      Model(..model, dragging: drop_rule.left(model.dragging, types, towards)),
      effect.none(),
    )
    DragEnded -> #(
      Model(..model, dragging: drop_rule.dropped(model.dragging)),
      effect.none(),
    )

    Read(id:, read:) ->
      changed(model, attach_rule.loaded(model.state, id, read))
    Removed(id:) -> changed(model, attach_rule.removed(model.state, id))

    Connected -> #(
      model,
      effect.batch([unlistening(model.listening), listening()]),
    )
    Listening(listeners:) -> #(
      Model(..model, listening: Some(listeners)),
      effect.none(),
    )
    Disconnected -> #(
      Model(..model, listening: None, dragging: drop_rule.away),
      unlistening(model.listening),
    )
  }
}

/// Updates model attachment state and synchronizes form values.
fn changed(model: Model, state: State) -> #(Model, Effect(Msg)) {
  // Compute serialized form value and presence marker for attachment state.
  let #(value, holding) = case attach_rule.value(state) {
    Ok(text) -> #(component.set_form_value(text), "yes")
    Error(Nil) -> #(component.clear_form_value(), "no")
  }

  #(Model(..model, state:), effect.batch([value, telling(holding)]))
}

/// Sets composer element attached attribute to inform send readiness.
fn telling(holding: String) -> Effect(Msg) {
  use _, root <- effect.after_paint
  let told = {
    use form <- result.try(ffi_dom.closest(
      ffi_dom.host(ffi_dom.as_element(root)),
      "form",
    ))
    use editor <- result.map(ffi_dom.query_selector(form, "loom-composer"))
    ffi_dom.set_attribute(editor, "attached", holding)
  }
  result.unwrap(told, or: Nil)
}

/// Transforms DOM file objects into rule candidate descriptors.
fn candidates(files: List(ffi_dom.File)) -> List(Candidate(ffi_dom.File)) {
  list.map(files, fn(file) {
    attach_rule.Candidate(
      name: ffi_dom.file_name(file),
      mime_type: ffi_dom.file_type(file),
      size: ffi_dom.file_size(file),
      file:,
    )
  })
}

/// Initiates asynchronous base64 data URL reads for accepted candidate files.
fn reading(reads: List(#(Int, ffi_dom.File))) -> Effect(Msg) {
  effect.batch(
    list.map(reads, fn(read) {
      let #(id, file) = read
      use dispatch <- effect.from
      ffi_dom.read_data_url(file, fn(result) {
        dispatch(Read(id:, read: result))
      })
    }),
  )
}

/// Triggers a programmatic click on the hidden file input element.
fn picking() -> Effect(Msg) {
  use _, root <- effect.after_paint
  let opened = {
    use input <- result.map(ffi_dom.query_selector(
      ffi_dom.as_element(root),
      "input[type=\"file\"]",
    ))
    ffi_dom.click(input)
  }
  result.unwrap(opened, or: Nil)
}

/// Clears the file input value so subsequent identical selections fire change events.
fn clearing() -> Effect(Msg) {
  use _, root <- effect.after_paint
  let cleared = {
    use input <- result.map(ffi_dom.query_selector(
      ffi_dom.as_element(root),
      "input[type=\"file\"]",
    ))
    ffi_dom.set_value(input, "")
  }
  result.unwrap(cleared, or: Nil)
}

/// Binds paste and drag-drop event listeners to the enclosing form.
fn listening() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let started = {
    use form <- result.map(ffi_dom.closest(
      ffi_dom.host(ffi_dom.as_element(root)),
      "form",
    ))
    let page = ffi_dom.get_document()
    let on = fn(element, event_name, handler) {
      #(element, event_name, ffi_dom.add_listener(element, event_name, handler))
    }
    let heard = [
      on(form, "paste", fn(event) {
        // Dispatch pasted images or ignore non-image paste contents.
        case list.filter(ffi_dom.clipboard_files(event), is_image) {
          [] -> Nil
          files -> {
            ffi_dom.prevent_default(event)
            dispatch(Pasted(files))
          }
        }
      }),
      on(form, "dragenter", fn(event) {
        let types = ffi_dom.drag_types(event)
        use <- when_files(event, types)
        dispatch(DragEntered(types))
      }),
      on(form, "dragover", fn(event) {
        use <- when_files(event, ffi_dom.drag_types(event))
        Nil
      }),
      on(form, "dragleave", fn(event) {
        dispatch(DragLeft(
          ffi_dom.drag_types(event),
          towards(form, ffi_dom.related_target(event)),
        ))
      }),
      on(form, "drop", fn(event) {
        use <- when_files(event, ffi_dom.drag_types(event))
        dispatch(Dropped(ffi_dom.drag_files(event)))
      }),

      // A drag can end with no leave reaching the form, when the element
      // under the pointer was replaced, so the page's own drop and drag end
      // clear the drag state.
      on(page, "drop", fn(_) { dispatch(DragEnded) }),
      on(page, "dragend", fn(_) { dispatch(DragEnded) }),
    ]
    dispatch(Listening(Listeners(heard:)))
  }
  result.unwrap(started, or: Nil)
}

/// Determines whether a drag leave destination remains within or exits form bounds.
fn towards(
  form: ffi_dom.Element,
  target: Result(ffi_dom.Element, Nil),
) -> drop_rule.Destination {
  case target {
    Ok(node) ->
      case ffi_dom.contains(form, node) {
        True -> drop_rule.Within
        False -> drop_rule.Beyond
      }
    Error(Nil) -> drop_rule.Beyond
  }
}

/// Prevents default event action when drag data transfer carries files.
fn when_files(event: Dynamic, types: List(String), next: fn() -> Nil) -> Nil {
  // Cancel default drag behavior when event transfer includes files.
  case drop_rule.carries_files(types) {
    True -> {
      ffi_dom.prevent_default(event)
      next()
    }
    False -> Nil
  }
}

// Whether a clipboard file claims to be an image of any kind. One that is not
// an allowed kind is still taken and cancelled, so `choose` can say why it is
// refused, rather than the browser pasting its name into the draft.
fn is_image(file: ffi_dom.File) -> Bool {
  attach_rule.is_image(ffi_dom.file_type(file))
}

/// Removes form paste and drag event listeners on disconnection.
fn unlistening(listening: Option(Listeners)) -> Effect(Msg) {
  // Remove registered form event listeners.
  case listening {
    None -> effect.none()
    Some(Listeners(heard:)) -> {
      use _ <- effect.from
      list.each(heard, fn(entry) {
        ffi_dom.remove_listener(entry.0, entry.1, entry.2)
      })
    }
  }
}

/// Renders the attachment control bar, chips list, and drop overlay.
fn view(model: Model) -> Element(Msg) {
  let state = model.state
  element.fragment([
    html.div([attribute.class("attach-bar")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("attach-add"),
          attribute.aria_label("Attach image"),
          attribute.title("Attach image"),
          attribute.disabled(attach_rule.full(state)),
          event.on_click(PickRequested),
        ],
        [html.text("+")],
      ),
      html.input([
        attribute.type_("file"),
        attribute.class("attach-input"),
        attribute.accept(state.limits.types),
        attribute.multiple(True),
        attribute.hidden(True),
        attribute.attribute("tabindex", "-1"),
        event.on("change", chosen()),
      ]),
    ]),
    chips(state),
    notice(state),
    drop_hint(model),
  ])
}

/// Renders drop target overlay hint when dragging images over composer.
fn drop_hint(model: Model) -> Element(Msg) {
  case drop_rule.surface(model.dragging, drop_rule.places(model.state)) {
    drop_rule.Inviting ->
      html.div([attribute.class("attach-drop"), attribute.aria_hidden(True)], [
        html.text("Drop images to attach"),
      ])
    drop_rule.Plain -> element.none()
  }
}

fn chosen() -> decode.Decoder(Msg) {
  use files <- decode.subfield(["target", "files"], decode.dynamic)
  decode.success(Chosen(ffi_dom.file_list(files)))
}

/// Renders the collection of held and loading attachment chips.
fn chips(state: State) -> Element(Msg) {
  case state.held, state.reading {
    [], [] -> element.none()
    held, reading ->
      html.ul(
        [
          attribute.class("attachments"),
          attribute.aria_label("Attached images"),
        ],
        list.append(
          list.map(held, chip),
          list.map(reading, fn(image) {
            html.li([attribute.class("attachment reading")], [
              html.span([attribute.class("attachment-name")], [
                html.text("Reading " <> attach_rule.label(image.name) <> "…"),
              ]),
            ])
          }),
        ),
      )
  }
}

/// Renders a single attachment chip with file name and remove action.
fn chip(image: attach_rule.Held) -> Element(Msg) {
  let label = attach_rule.label(image.name)
  html.li([attribute.class("attachment")], [
    html.span([attribute.class("attachment-name")], [
      html.text(label <> " · " <> attach_rule.size_text(image.size)),
    ]),
    html.button(
      [
        attribute.type_("button"),
        attribute.class("attachment-remove"),
        attribute.aria_label("Remove " <> label),
        event.on_click(Removed(image.id)),
      ],
      [html.text("Remove")],
    ),
  ])
}

/// Renders warning notice text when validation rejects an attachment.
fn notice(state: State) -> Element(Msg) {
  case state.notice {
    "" -> element.none()
    text ->
      html.p([attribute.class("notice warned"), attribute.role("status")], [
        html.text(text),
      ])
  }
}
