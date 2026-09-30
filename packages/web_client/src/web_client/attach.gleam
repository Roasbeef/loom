//// `<loom-attach name="images" limits="...">`: the operator composer's image
//// attachments (protocol-change/051, the addendum on images).
////
//// The element draws an "Attach image" button, the chips of the images
//// already attached each with a Remove button, and a line saying why a file
//// was refused. An image comes from the file picker the button opens or from
//// a paste into the composer, and its bytes are read in the browser and held
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
//// ## What it does not do
////
//// It handles no key, takes no focus of its own and never touches the
//// approval cards, which are outside the composer's form. It draws no image:
//// a chip is a file's name and size, text nodes both. What the operator
//// attached is theirs, and the transcript shows it after the daemon accepts
//// it, from the daemon's own copy.

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
import web_client/internal/ffi_dom

/// The element's tag.
pub const name = "loom-attach"

/// What the element knows: the rules' state, and the paste listener it put on
/// its form, so leaving the page can take it off again.
pub type Model {
  Model(state: State, pasting: Option(Pasting))
}

/// A running listener on the composer's form.
pub type Pasting {
  Pasting(form: ffi_dom.Element, listener: ffi_dom.Listener)
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

  /// The paste listener is on the form.
  Listening(pasting: Pasting)
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
  #(Model(state: attach_rule.start(), pasting: None), effect.none())
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

    Read(id:, read:) ->
      changed(model, attach_rule.loaded(model.state, id, read))
    Removed(id:) -> changed(model, attach_rule.removed(model.state, id))

    Connected -> #(
      model,
      effect.batch([unlistening(model.pasting), listening()]),
    )
    Listening(pasting:) -> #(
      Model(..model, pasting: Some(pasting)),
      effect.none(),
    )
    Disconnected -> #(Model(..model, pasting: None), unlistening(model.pasting))
  }
}

// The state after a change to what is held, and the form's value for it: the
// images as one field, or no field at all when none is held.
fn changed(model: Model, state: State) -> #(Model, Effect(Msg)) {
  let value = case attach_rule.value(state) {
    Ok(text) -> component.set_form_value(text)
    Error(Nil) -> component.clear_form_value()
  }
  #(Model(..model, state:), value)
}

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

// One read per accepted file. Each answers in its own message, numbered by
// the state's number for the file, so the reads finish in any order.
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

// Opens the file picker, which is the button's click on the hidden input.
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

// Empties the file input after a choice, so choosing the same file again
// raises `change` again.
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

// Listens for a paste on the composer's form. A paste that holds image files
// attaches them and is cancelled, and any other is left alone. The listener
// is handed back so `unlistening` can end it.
fn listening() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let started = {
    use form <- result.map(ffi_dom.closest(
      ffi_dom.host(ffi_dom.as_element(root)),
      "form",
    ))
    let listener =
      ffi_dom.add_listener(form, "paste", fn(event) {
        case list.filter(ffi_dom.clipboard_files(event), is_image) {
          [] -> Nil
          files -> {
            ffi_dom.prevent_default(event)
            dispatch(Pasted(files))
          }
        }
      })
    dispatch(Listening(Pasting(form:, listener:)))
  }
  result.unwrap(started, or: Nil)
}

// Whether a clipboard file claims to be an image of any kind. One that is not
// an allowed kind is still taken and cancelled, so `choose` can say why it is
// refused, rather than the browser pasting its name into the draft.
fn is_image(file: ffi_dom.File) -> Bool {
  attach_rule.is_image(ffi_dom.file_type(file))
}

fn unlistening(pasting: Option(Pasting)) -> Effect(Msg) {
  case pasting {
    None -> effect.none()
    Some(Pasting(form:, listener:)) -> {
      use _ <- effect.from
      ffi_dom.remove_listener(form, "paste", listener)
    }
  }
}

fn view(model: Model) -> Element(Msg) {
  let state = model.state
  element.fragment([
    html.div([attribute.class("attach-bar")], [
      html.button(
        [
          attribute.type_("button"),
          attribute.class("attach-add"),
          attribute.disabled(attach_rule.full(state)),
          event.on_click(PickRequested),
        ],
        [html.text("Attach image")],
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
  ])
}

fn chosen() -> decode.Decoder(Msg) {
  use files <- decode.subfield(["target", "files"], decode.dynamic)
  decode.success(Chosen(ffi_dom.file_list(files)))
}

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

fn notice(state: State) -> Element(Msg) {
  case state.notice {
    "" -> element.none()
    text ->
      html.p([attribute.class("notice warned"), attribute.role("status")], [
        html.text(text),
      ])
  }
}
