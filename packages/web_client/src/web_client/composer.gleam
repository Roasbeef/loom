//// `<loom-composer>`: the composer's editor, given the three behaviours
//// that belong to the browser: a list of slash commands that narrows as the
//// draft grows, the keys that send it, and the return of a prompt the daemon
//// handed back.
////
//// The server component draws the editor, an uncontrolled `textarea`, inside
//// this element and owns the form around it. The browser owns the text as
//// the operator types, and the server never sees it until the form is
//// submitted, so anything that reacts to the draft as it changes has to run
//// here. The element takes the editor as its default slot and listens for
//// the editor's events as they pass through the slot: `input` to learn the
//// draft, and `keydown` to act on a few keys. It draws one thing of its own,
//// the list of commands, above the slot.
////
//// ## What the element is told
////
//// The server sets two attributes and one child:
////
//// - `commands` is the table of completions as JSON. It is the terminal's
////   own table (`session_view/command.suggestions`) less the commands the
////   page does not run, encoded by `web_view/view/completion`, so the names
////   and hints are the terminal's and no session text is in it.
//// - `returned` counts the prompts the daemon has handed back, from one, in
////   the order they came. A number that rises means the children in the slot
////   named `returned` hold text to put in the editor. The element takes the
////   first value it is given as the count already handled, so an editor the
////   server replaces after a send does not bring an old return back.
//// - Each child in the `returned` slot is one returned prompt, drawn by the
////   server as a text node, and its `data-n` is its number in that count.
////   The shadow root has no such slot, so the browser never displays them
////   here; the element reads them as text. The server keeps every one,
////   and the element takes each number once, in order.
////
//// ## Keys
////
//// Enter in the editor is a newline, as it always was. Command or Control
//// with Enter sends the draft as the Send button does, by submitting the
//// form, which raises the submit event the server already accepts. While the
//// list is showing, the arrow keys move through it, Tab and Enter take the
//// highlighted row, and Escape closes it. A key pressed during composition
//// belongs to the input method, and a held key sends once.
////
//// None of these keys decides an approval. The approval cards are outside
//// this element, in the dock, and this element listens only to its own
//// editor.
////
//// ## The list
////
//// Filtering follows the terminal's palette (`command.suggestions`): a draft
//// that is one word starting with `/` lists the commands it is a prefix of,
//// and a command whose argument has a closed vocabulary (`/effort`, `/goal`)
//// keeps listing its words past the space. `matching` is that rule over the
//// table. Choosing a row writes its command into the editor, followed by a
//// space when the command takes an argument.
////
//// ## The pending line
////
//// The server draws a message's row only once a capture holds it, so a press
//// that waits on the server would show nothing until then. The element
//// listens for the form's `submit` and, in the same turn, shows the draft as
//// a pending line above the editor in its own shadow root, marked `sending`
//// or `queued` (`web_client/pending_rule`), and clears the editor after the
//// paint so the submit has already read it. The line is never a row of the
//// lane. It leaves when the server takes the draft, which replaces this
//// element (the server keys the editor by the drafts sent), or when the
//// server refuses, which it says by raising the count in the `refused`
//// attribute: the line goes and the text is put back in the editor.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import web_client/composer_rule.{
  type Attachments, type Direction, type Entry, type Gate, type Palette,
  type Returns, Bare, Closed, Complete, Composing, Consumed, Continues, Fresh,
  Listing, Nothing, Observed, Open, Other, Repeating, Sending, Shut, Take,
  Unattached, Unseen,
}
import web_client/internal/ffi_dom
import web_client/pending_rule

/// The element's tag.
pub const name = "loom-composer"

/// How much of the draft the element keeps. A command and its partial
/// argument are short, and the rest of a long draft is never matched, so
/// keeping the whole text would only hold it twice.
pub const kept = 200

/// What the element knows.
pub type Model {
  Model(
    /// The table of completions the server sent.
    entries: List(Entry),
    /// The first `kept` characters of the draft, as of the last `input`.
    draft: String,
    /// The highlighted row of `matching(entries, draft)`.
    selected: Int,
    palette: Palette,
    returns: Returns,
    /// Whether `<loom-attach>` holds an image, which it reports in this
    /// element's `attached` attribute. With the draft it decides whether the
    /// send buttons can be pressed (`composer_rule.gate`).
    attachments: Attachments,
    /// The message a press put in flight, shown above the editor until the
    /// server takes or refuses it.
    pending: pending_rule.State,
    /// The last refusal count the server stated, which says when a refusal
    /// is new.
    refusals: pending_rule.Refusals,
    /// The submit listener on the composer's form, so leaving the page can
    /// take it off again.
    submitting: Option(Submitting),
  )
}

/// A running listener on the composer's form.
pub type Submitting {
  Submitting(form: ffi_dom.Element, listener: ffi_dom.Listener)
}

/// Everything the element can be told.
pub type Msg {
  /// The server sent the table of completions.
  Configured(entries: List(Entry))

  /// The server said how many prompts it has handed back.
  Returned(count: Int)

  /// `<loom-attach>` said whether it holds an image.
  Holding(attachments: Attachments)

  /// The editor's text changed to this.
  Typed(text: String)

  /// An arrow key moved the highlight.
  Moved(direction: Direction)

  /// Tab or Enter took the highlighted row.
  Accepted

  /// A row was clicked.
  Picked(index: Int)

  /// Escape closed the list.
  Dismissed

  /// Command or Control with Enter asked to send the draft.
  Sent

  /// A key the element consumed and does nothing more with: a chord held
  /// down after it already sent.
  Ignored

  /// The server said how many submits it has refused with the draft kept.
  Refused(count: Int)

  /// The form was submitted with this draft, by a button of this delivery.
  Pressed(text: String, delivery: pending_rule.Delivery)

  /// The element joined the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The submit listener is on the form.
  Listening(submitting: Submitting)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = composer.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_attribute_change("commands", fn(value) {
      Ok(Configured(composer_rule.entries(value)))
    }),
    component.on_attribute_change("returned", fn(value) {
      int.parse(value) |> result.map(Returned)
    }),
    component.on_attribute_change("attached", fn(value) {
      Ok(Holding(composer_rule.attachments(value)))
    }),
    component.on_attribute_change("refused", fn(value) {
      int.parse(value) |> result.map(Refused)
    }),
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

// A new editor is empty and holds nothing, so its send buttons start shut:
// the server draws the editor afresh after every send, and this is the
// moment the buttons beside it learn there is nothing to send.
fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(
      entries: [],
      draft: "",
      selected: 0,
      palette: Listing,
      returns: Unseen,
      attachments: Unattached,
      pending: pending_rule.Clear,
      refusals: pending_rule.Unheard,
      submitting: None,
    ),
    gating(Shut),
  )
}

// What the draft and the attachments say about the send buttons.
fn gate(model: Model) -> Gate {
  composer_rule.gate(model.draft, model.attachments)
}

// The rows the list shows now, which is none while it is closed.
fn shown(model: Model) -> List(Entry) {
  case model.palette {
    Listing -> composer_rule.matching(model.entries, model.draft)
    Closed -> []
  }
}

/// Applies one message. The editor and the form are reached only inside
/// effects, so `update` stays a function of its messages.
///
/// ## Examples
///
/// ```gleam
/// // composer.update(model, composer.Dismissed)
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message {
    Configured(entries:) -> #(Model(..model, entries:), effect.none())

    // The first count is the baseline: an editor the server draws afresh
    // after a send starts with the count as it stands, and that count was
    // handled by the editor before it. Only a count that rises afterwards is
    // a prompt the daemon has just handed back. The model advances `taken`
    // here, in the turn that hears the count, and the effect is told the
    // range that turn claimed, so two returns that reach the page before one
    // frame paints are two disjoint ranges and each prompt is taken once.
    Returned(count:) -> {
      let #(returns, taking) = composer_rule.hear(model.returns, count)
      #(Model(..model, returns:), case taking {
        Nothing -> effect.none()
        Take(after:, up_to:) -> restoring(after, up_to)
      })
    }

    // Typing reopens the list and starts it at the top, and says whether
    // there is now something to send.
    Typed(text:) -> {
      let typed =
        Model(
          ..model,
          draft: string.slice(text, 0, kept),
          selected: 0,
          palette: Listing,
        )
      #(typed, gating(gate(typed)))
    }

    // An image arriving in an empty editor makes the message sendable, and
    // the last image leaving it makes it empty again.
    Holding(attachments:) -> {
      let holding = Model(..model, attachments:)
      #(holding, gating(gate(holding)))
    }
    Moved(direction:) -> #(
      Model(
        ..model,
        selected: composer_rule.moved(
          model.selected,
          list.length(shown(model)),
          direction,
        ),
      ),
      revealing(),
    )
    Accepted -> choose(model, model.selected)
    Picked(index:) -> choose(model, index)
    Dismissed -> #(Model(..model, palette: Closed), effect.none())

    // The chord is refused while there is nothing to send, as the disabled
    // buttons are, so the server is never asked to refuse an empty message.
    Sent ->
      case gate(model) {
        Open -> #(model, sending())
        Shut -> #(model, effect.none())
      }
    Ignored -> #(model, effect.none())

    // A count that rises while a line is shown is the server's refusal of
    // that press: the line goes and the draft comes back.
    Refused(count:) -> {
      let #(pending, refusals, outcome) =
        pending_rule.refused(model.pending, model.refusals, count)
      #(Model(..model, pending:, refusals:), case outcome {
        pending_rule.Keep -> effect.none()
        pending_rule.Restore(text:) -> restoring_draft(text)
      })
    }

    // The press shows the draft at once. The editor is cleared after the
    // paint, by which time the submit that read it has run.
    Pressed(text:, delivery:) -> {
      let pending = pending_rule.pressed(model.pending, text, delivery)
      #(Model(..model, pending:), case pending {
        pending_rule.Clear -> effect.none()
        pending_rule.Shown(_) -> clearing()
      })
    }

    Connected -> #(
      model,
      effect.batch([unlistening(model.submitting), listening()]),
    )
    Listening(submitting:) -> #(
      Model(..model, submitting: Some(submitting)),
      effect.none(),
    )
    Disconnected -> #(
      Model(..model, submitting: None),
      unlistening(model.submitting),
    )
  }
}

// Listens for the form's submit, which is the one event a press raises, and
// reads the draft and the pressed button from it. The listener is on the
// form because the submit's target is the form, not the editor in the slot.
// Reading is all it does here: the server's own handler reads the same form
// in the same dispatch, so nothing is cleared until after the paint.
fn listening() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let started = {
    use form <- result.map(ffi_dom.closest(
      ffi_dom.host(ffi_dom.as_element(root)),
      "form",
    ))
    let listener =
      ffi_dom.add_listener(form, "submit", fn(event) {
        let delivery =
          ffi_dom.submitter(event)
          |> result.try(ffi_dom.attribute(_, "class"))
          |> result.unwrap("")
          |> pending_rule.delivery
        let text =
          ffi_dom.query_selector(form, "textarea")
          |> result.map(ffi_dom.value)
          |> result.unwrap("")
        dispatch(Pressed(text:, delivery:))
      })
    dispatch(Listening(Submitting(form:, listener:)))
  }
  result.unwrap(started, or: Nil)
}

fn unlistening(submitting: Option(Submitting)) -> Effect(Msg) {
  case submitting {
    None -> effect.none()
    Some(Submitting(form:, listener:)) -> {
      use _ <- effect.from
      ffi_dom.remove_listener(form, "submit", listener)
    }
  }
}

// Empties the editor once the press has been read, and tells the element so
// the send buttons shut as they would after typing nothing.
fn clearing() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let cleared = {
    use area <- result.map(editor(root))
    ffi_dom.set_value(area, "")
    dispatch(Typed(""))
  }
  result.unwrap(cleared, or: Nil)
}

// Puts a refused draft back in the editor, after anything typed since, as a
// returned prompt is joined, and tells the element what it wrote.
fn restoring_draft(text: String) -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let restored = {
    use area <- result.map(editor(root))
    let joined = composer_rule.joined(ffi_dom.value(area), text)
    ffi_dom.set_value(area, joined)
    dispatch(Typed(joined))
  }
  result.unwrap(restored, or: Nil)
}

// Takes row `index` of the list as the draft. A command that takes an
// argument gets its space, and stays listed when it has words of its own to
// offer, as the terminal's palette does after `/effort `; a whole command
// closes the list.
fn choose(model: Model, index: Int) -> #(Model, Effect(Msg)) {
  case list.drop(shown(model), index) {
    [row, ..] -> {
      let text = case row.then {
        Continues -> row.command <> " "
        Complete -> row.command
      }
      let palette = case row.then, composer_rule.matching(model.entries, text) {
        Continues, [_, ..] -> Listing
        Continues, [] | Complete, _ -> Closed
      }
      let chosen = Model(..model, draft: text, selected: 0, palette:)
      #(chosen, effect.batch([placing(text), gating(gate(chosen))]))
    }
    [] -> #(model, effect.none())
  }
}

// The editor the server drew inside this element, which is in the element's
// own children and not in its shadow root. The server keys the editor's
// container by how many drafts have left it, so the element and its textarea
// are replaced together and never outlive one another.
fn editor(root: Dynamic) -> Result(ffi_dom.Element, Nil) {
  ffi_dom.query_selector(ffi_dom.host(ffi_dom.as_element(root)), "textarea")
}

// Puts `text` in the editor as the whole draft, with the caret after it, and
// gives it focus, since the operator has just chosen it from a list beside
// it. A programmatic write fires no `input` event, which is right: the
// component records the text itself when it writes it.
fn placing(text: String) -> Effect(Msg) {
  use _, root <- effect.after_paint
  let placed = {
    use area <- result.map(editor(root))
    let end = ffi_dom.utf16_length(text)
    ffi_dom.set_value(area, text)
    ffi_dom.set_selection_range(area, end, end)
    ffi_dom.focus(area)
  }
  result.unwrap(placed, or: Nil)
}

// Submits the composer's form as a press of its first submit button does:
// the button is Send while the strand is idle and Queue while it is busy, and
// the submit that results carries the button's delivery. `requestSubmit`,
// unlike `submit`, runs the form's own submit listeners, which is where the
// server component's handler is, and it is the same event that button
// raises, so the server sees nothing new.
fn sending() -> Effect(Msg) {
  use _, root <- effect.after_paint
  let submitted = {
    use form <- result.map(ffi_dom.closest(
      ffi_dom.host(ffi_dom.as_element(root)),
      "form",
    ))
    case ffi_dom.query_selector(form, "button[type=\"submit\"]") {
      Ok(button) -> ffi_dom.request_submit_with(form, button)
      Error(Nil) -> ffi_dom.request_submit(form)
    }
  }
  result.unwrap(submitted, or: Nil)
}

// Brings the prompts the daemon handed back into the editor. The server draws
// each as a child of this element in the slot named `returned`, which this
// element's shadow root has no slot for, so none is displayed there; each is
// read here as text, numbered by its `data-n`. `taken` picks the ones this
// call was told are new, and `joined` says how each meets the draft.
//
// A write to the editor fires no `input` event, so the element tells itself
// what it wrote: a returned prompt makes an empty editor sendable.
fn restoring(after: Int, up_to: Int) -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let restored = {
    use area <- result.map(editor(root))
    let held =
      ffi_dom.host(ffi_dom.as_element(root))
      |> ffi_dom.query_selector_all("[slot=\"returned\"]")
      |> list.filter_map(numbered)
    case composer_rule.taken(held, after, up_to) {
      [] -> Nil
      [_, ..] as prompts -> {
        let text = list.fold(prompts, ffi_dom.value(area), composer_rule.joined)
        ffi_dom.set_value(area, text)
        dispatch(Typed(text))
      }
    }
  }
  result.unwrap(restored, or: Nil)
}

// Disables the form's submit buttons while the gate is shut and enables them
// when it opens. The buttons are the server's, drawn beside this element in
// the form, so they are reached through the form and their own `disabled`
// attribute: a disabled button raises no submit, and the stylesheet dims it.
//
// Known residual: the server swaps Send for Queue and Steer when the strand
// turns busy, and the new buttons are fresh nodes this element has not gated,
// so with an empty editor they start enabled until the next keystroke. The
// server's "Nothing to send." still refuses that press, and no observer is
// kept to catch the swap.
fn gating(gate: Gate) -> Effect(Msg) {
  use _, root <- effect.after_paint
  let gated = {
    use form <- result.map(ffi_dom.closest(
      ffi_dom.host(ffi_dom.as_element(root)),
      "form",
    ))
    form
    |> ffi_dom.query_selector_all("button[type=\"submit\"]")
    |> list.each(fn(button) {
      case gate {
        Open -> ffi_dom.remove_attribute(button, "disabled")
        Shut -> ffi_dom.set_attribute(button, "disabled", "")
      }
    })
  }
  result.unwrap(gated, or: Nil)
}

// A returned prompt and its number in the server's count. One without a
// whole-number `data-n` is not a returned prompt.
fn numbered(held: ffi_dom.Element) -> Result(#(Int, String), Nil) {
  use n <- result.try(ffi_dom.dataset_get(held, "n"))
  use n <- result.map(int.parse(n))
  #(n, ffi_dom.text_content(held))
}

// Scrolls the completion list, and only the list, so the highlighted row is
// inside it. The list is positioned, so a row's offset is from the list's
// top edge. The transcript and the page are left where they are, which
// `scrollIntoView` would not promise: it scrolls every ancestor that can.
fn revealing() -> Effect(Msg) {
  use _, root <- effect.after_paint
  let root = ffi_dom.as_element(root)
  let scrolled = {
    use menu <- result.try(ffi_dom.query_selector(root, "[role=\"listbox\"]"))
    use row <- result.map(ffi_dom.query_selector(
      root,
      "[aria-selected=\"true\"]",
    ))
    let before = ffi_dom.scroll_top(menu)
    let after =
      composer_rule.revealed(
        ffi_dom.offset_top(row),
        ffi_dom.offset_height(row),
        before,
        ffi_dom.client_height(menu),
      )
    case after == before {
      True -> Nil
      False -> ffi_dom.set_scroll_top(menu, after)
    }
  }
  result.unwrap(scrolled, or: Nil)
}

// The list sits above the editor in the flow, so opening it grows the dock
// upward and leaves the editor and its buttons where they were. The editor
// is the slot's child and is drawn by the server; every word in the list is
// the static table's.
fn view(model: Model) -> Element(Msg) {
  let rows = shown(model)
  element.fragment([
    pending(model.pending),
    case rows {
      [] -> element.none()
      [_, ..] ->
        html.ul(
          [
            attribute.class("completions"),
            attribute.role("listbox"),
            attribute.aria_label("Commands"),
          ],
          list.index_map(rows, fn(row, index) {
            completion(row, index, model.selected)
          }),
        )
    },
    component.default_slot(
      [
        event.on("input", typed()),
        event.advanced("keydown", keystroke(model.palette, rows)),
      ],
      [],
    ),
  ])
}

// The pending line: the person's own text as a text node, and the fixed
// word for how it is delivered, in the quiet style.
fn pending(state: pending_rule.State) -> Element(Msg) {
  case state {
    pending_rule.Clear -> element.none()
    pending_rule.Shown(pending:) ->
      html.div([attribute.class("pending"), attribute.role("status")], [
        html.p([attribute.class("pending-text")], [html.text(pending.text)]),
        html.span([attribute.class("pending-mark")], [
          html.text(pending_rule.mark(pending.delivery)),
        ]),
      ])
  }
}

fn completion(row: Entry, index: Int, selected: Int) -> Element(Msg) {
  let current = index == selected
  html.li(
    [
      attribute.class("completion"),
      attribute.classes([#("current", current)]),
      attribute.role("option"),
      attribute.aria_selected(current),
      event.on_click(Picked(index)),
    ],
    [
      html.span([attribute.class("completion-command")], [
        html.text(row.command),
      ]),
      html.span([attribute.class("completion-hint")], [html.text(row.hint)]),
    ],
  )
}

fn typed() -> decode.Decoder(Msg) {
  use text <- decode.subfield(["target", "value"], decode.string)
  decode.success(Typed(text))
}

// The message for what a key is to do.
fn message(action: composer_rule.Action) -> Msg {
  case action {
    composer_rule.Send -> Sent
    composer_rule.Hold -> Ignored
    composer_rule.Move(direction:) -> Moved(direction:)
    composer_rule.Accept -> Accepted
    composer_rule.Dismiss -> Dismissed
  }
}

// The decoder for a key press. A key the element leaves to the browser fails
// the decoder, so nothing is dispatched and nothing is cancelled.
fn keystroke(
  palette: Palette,
  rows: List(Entry),
) -> decode.Decoder(event.Handler(Msg)) {
  use key <- decode.field("key", decode.string)
  use meta <- decode.field("metaKey", decode.bool)
  use control <- decode.field("ctrlKey", decode.bool)
  use shift <- decode.field("shiftKey", decode.bool)
  use alt <- decode.field("altKey", decode.bool)
  use composing <- decode.field("isComposing", decode.bool)
  use repeating <- decode.field("repeat", decode.bool)
  let chord = case meta || control, shift, alt {
    True, _, False -> Sending
    False, False, False -> Bare
    _, _, _ -> Other
  }
  let phase = case composing, repeating {
    True, _ -> Composing
    False, True -> Repeating
    False, False -> Fresh
  }

  // A list with no rows is not showing, whatever the model says: the keys
  // that belong to it are the browser's then.
  let palette = case rows {
    [] -> Closed
    [_, ..] -> palette
  }
  case composer_rule.intent(key, chord, phase, palette) {
    Some(Consumed(action)) ->
      decode.success(event.handler(
        message(action),
        prevent_default: True,
        stop_propagation: False,
      ))
    Some(Observed(action)) ->
      decode.success(event.handler(
        message(action),
        prevent_default: False,
        stop_propagation: False,
      ))
    None ->
      decode.failure(
        event.handler(Ignored, prevent_default: False, stop_propagation: False),
        "a key",
      )
  }
}
