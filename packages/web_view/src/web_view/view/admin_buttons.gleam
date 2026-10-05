//// The admin page's buttons: the messages they send, whether they can be
//// pressed, and the two-step shape of a revocation.
////
//// Every button on the page asks the daemon to change something, so each is
//// drawn from one place. A press carries the `Action` the server drew into the
//// tree, so the browser's event names only the path it fired at and never a
//// principal or a session. While a request is out every button is drawn
//// disabled and carries no handler, which is the page's half of "a second press
//// asks nothing"; the component's update and the daemon each refuse a second
//// request as well.
////
//// A revocation is two presses. The first arms it and shows what it will do in
//// words that name the person, and the second sends it; Cancel, or any other
//// press, puts it back. This guards a mis-click and nothing more. The security
//// boundary is the daemon, which checks the principal, the credential and the
//// allowance again for every request (`client/daemon/ui_socket`).
////
//// The module takes the messages as values, because `web_view/admin` owns the
//// message type and imports this module. Every label is fixed text here, except
//// a name, which is the peer's and is drawn as a text node in a label's words.

import gleam/option.{type Option, None, Some}
import lustre/attribute.{type Attribute}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_view/grants.{type Action}

/// Whether the page has a request out, and whether the allowance is spent. A
/// busy page draws every button disabled.
pub type Busy {
  /// Nothing is out. Buttons carry their handlers.
  Free

  /// A request is with the daemon. Buttons are disabled and have no handler.
  Occupied

  /// Nothing is out, but the daemon refused the last grant because the
  /// credential has made as many as it may in the hour, and the hour has not
  /// passed. Buttons carry their handlers, since the daemon decides, and the
  /// buttons that would grant carry `words`, the refusal's own, in their `title`
  /// so the owner reads when the next is free before pressing (round 4, F89).
  Spent(words: String)
}

/// The messages the page's controls send, as values.
pub type Presses(message) {
  Presses(
    /// The message that asks the daemon to make a change.
    ask: fn(Action) -> message,
    /// The message that arms a revocation, which a second press then sends.
    arm: fn(Action) -> message,
    /// The message that puts an armed revocation back.
    disarm: message,
    /// The message that chooses a session, given its identity.
    choose: fn(String) -> message,
    /// The message that hides the claim on screen once the owner has copied it.
    dismiss: message,
    /// The handler of the invitation form's submit, given the session it
    /// invites into.
    invite: fn(String) -> Attribute(message),
    /// The message that opens one person's rename form, given the principal's
    /// identity.
    edit: fn(String) -> message,
    /// The message that closes the open rename form.
    cancel: message,
    /// The handler of a rename form's submit, given the principal it renames.
    rename: fn(String) -> Attribute(message),
  )
}

/// One plain button that sends `message`, or the same button disabled while a
/// request is out.
///
/// ## Examples
///
/// ```gleam
/// // admin_buttons.plain("Make operator", "admin-act", message, busy)
/// ```
pub fn plain(
  label: String,
  class: String,
  message: message,
  busy: Busy,
) -> Element(message) {
  let common = [attribute.type_("button"), attribute.class(class)]
  case busy {
    Free | Spent(_) ->
      html.button([event.on_click(message), ..common], [html.text(label)])
    Occupied ->
      html.button([attribute.disabled(True), ..common], [html.text(label)])
  }
}

/// A button for a change that grants access, which counts against the
/// credential's allowance. It is `plain`, and while the allowance is spent it also
/// carries the refusal's words as its `title`.
///
/// ## Examples
///
/// ```gleam
/// // admin_buttons.granting("Rotate", "admin-act", message, busy)
/// ```
pub fn granting(
  label: String,
  class: String,
  message: message,
  busy: Busy,
) -> Element(message) {
  let common = [attribute.type_("button"), attribute.class(class)]
  case busy {
    Spent(words:) ->
      html.button([event.on_click(message), attribute.title(words), ..common], [
        html.text(label),
      ])
    Free | Occupied -> plain(label, class, message, busy)
  }
}

/// A button for a change that only reduces access and is therefore two presses:
/// `label` while it is not armed, and, once the component has armed `action`,
/// a confirm button worded `sure` and a Cancel. `sure` names what will happen
/// and to whom, so the person confirms what they read.
///
/// ## Examples
///
/// ```gleam
/// // admin_buttons.guarded("Remove", "Remove Bob from Review", action, Some(action), presses, busy)
/// ```
pub fn guarded(
  label: String,
  sure: String,
  action: Action,
  armed: Option(Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  case armed {
    Some(held) if held == action ->
      html.span([attribute.class("admin-confirm")], [
        plain(sure, "admin-act admin-danger", presses.ask(action), busy),
        plain("Cancel", "admin-act", presses.disarm, busy),
      ])
    Some(_) | None -> plain(label, "admin-act", presses.arm(action), busy)
  }
}

/// A button for a change that is slow or hard to undo, which asks first, in
/// place: `label` while it is not armed and, once the component has armed
/// `action`, `question`, a button worded `yes` that sends it, and Cancel. Unlike
/// `guarded`, whose confirm names what is removed and is drawn in the danger
/// colour, the question says what will happen to a session and is drawn quiet,
/// because the change is made on purpose and nothing is lost.
///
/// ## Examples
///
/// ```gleam
/// // admin_buttons.asking("Make shareable", "Make this session shareable?", "Make shareable", action, Some(action), presses, busy)
/// ```
pub fn asking(
  label: String,
  question: String,
  yes: String,
  action: Action,
  armed: Option(Action),
  presses: Presses(message),
  busy: Busy,
) -> Element(message) {
  case armed {
    Some(held) if held == action ->
      html.div([attribute.class("admin-ask")], [
        html.p([attribute.class("admin-lead"), attribute.role("alert")], [
          html.text(question),
        ]),
        html.span([attribute.class("admin-confirm")], [
          plain(yes, "admin-act admin-go", presses.ask(action), busy),
          plain("Cancel", "admin-act", presses.disarm, busy),
        ]),
      ])
    Some(_) | None -> plain(label, "admin-act", presses.arm(action), busy)
  }
}
