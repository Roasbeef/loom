//// `<loom-copy subject="token" text="loomclaim_...">`: a box holding one of the
//// invitation's texts, with a button that copies it to the clipboard.
////
//// The owner's page shows an invitation once (protocol-change/051, the
//// addendum on inviting from the session page). It holds two texts the owner
//// must carry out of Loom: the command the invitee runs and the claim token.
//// The server component cannot write the clipboard, and a script of the page
//// that acted on any value the server chose would be a way to put text on an
//// owner's clipboard, so the element takes exactly two attributes and acts
//// only on the shapes the daemon writes (`web_client/copy_rule`). `subject` is
//// one of two fixed words, and `text` is the value. The element draws the
//// text itself, in a `code` element in its shadow root, and one button. The
//// text is never parsed as markup: it is a text node. A `text` that is not
//// the shape its subject allows draws nothing and offers no button.
////
//// The button is a real button, and the copy runs in the press's own turn, not
//// after the next paint, so a browser that allows the clipboard only inside a
//// user's gesture allows this one. The element listens for no key and takes no
//// focus. It reads nothing from the page, keeps the text only as its
//// attribute and sends the server nothing: the copy is between the browser
//// and the system clipboard. Whether the write succeeded is drawn on the
//// button in fixed words, and a refusal leaves the text on screen to select.

import gleam/option.{type Option, None, Some}
import gleam/result
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/copy_rule.{type Copying, type Subject}
import web_client/internal/ffi_dom

/// The element's tag.
pub const name = "loom-copy"

/// What the element holds: the subject its `subject` attribute named, the raw
/// value its `text` attribute held, and what the button has done.
pub type Model {
  Model(subject: Subject, held: Option(String), copying: Copying)
}

/// Everything the element can be told.
pub type Msg {
  /// The server wrote a subject.
  Subjected(subject: Subject)

  /// The server wrote a text. The value is kept as it came and checked
  /// against the subject when it is drawn or copied, because the two
  /// attributes may arrive in either order.
  Texted(value: String)

  /// The owner pressed the button.
  Pressed

  /// The browser answered the clipboard write.
  Written(outcome: Result(Nil, Nil))
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = copy.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("subject", subject),
    component.on_attribute_change("text", texted),
  ])
  |> lustre.register(name)
}

// The attribute decoded totally: a fixed word is a subject and anything else
// is none.
fn subject(value: String) -> Result(Msg, Nil) {
  copy_rule.subject(value) |> result.map(Subjected)
}

fn texted(value: String) -> Result(Msg, Nil) {
  Ok(Texted(value))
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(Model(copy_rule.Command, None, copy_rule.Idle), effect.none())
}

/// Applies one message.
///
/// A new subject or text puts the button back to `Idle`, since what it last
/// copied is no longer what it holds.
///
/// ## Examples
///
/// ```gleam
/// assert copy.update(copy.init_model(), copy.Pressed).0.copying == copy_rule.Idle
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Subjected(subject:) -> #(
      Model(..model, subject:, copying: copy_rule.Idle),
      effect.none(),
    )
    Texted(value:) -> #(
      Model(..model, held: Some(value), copying: copy_rule.Idle),
      effect.none(),
    )
    Pressed -> #(model, copy(model))
    Written(outcome:) -> #(
      Model(..model, copying: copy_rule.after(outcome)),
      effect.none(),
    )
  }
}

/// The starting model, for a test that drives `update`.
///
/// ## Examples
///
/// ```gleam
/// assert copy.init_model().held == None
/// ```
pub fn init_model() -> Model {
  Model(copy_rule.Command, None, copy_rule.Idle)
}

// The write, in the press's own turn. A held text the rule refuses is a
// failed copy and writes nothing.
fn copy(model: Model) -> Effect(Msg) {
  use dispatch <- effect.from
  case shown(model) {
    Some(text) ->
      ffi_dom.write_clipboard(text, fn(outcome) { dispatch(Written(outcome)) })
    None -> dispatch(Written(Error(Nil)))
  }
}

// The text the element may draw and copy: the held value if it has the shape
// its subject allows.
fn shown(model: Model) -> Option(String) {
  case model.held {
    Some(value) -> copy_rule.text(model.subject, value) |> option.from_result
    None -> None
  }
}

fn view(model: Model) -> Element(Msg) {
  case shown(model) {
    None -> element.none()
    Some(text) ->
      element.fragment([
        html.code([attribute.class("share-text")], [html.text(text)]),
        html.button(
          [
            attribute.type_("button"),
            attribute.class("share-copy"),
            attribute.aria_live("polite"),
            event.on_click(Pressed),
          ],
          [html.text(copy_rule.words(model.subject, model.copying))],
        ),
      ])
  }
}
