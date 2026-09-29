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

import gleam/dynamic/decode
import gleam/int
import gleam/json
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
import web_client/internal/ffi_composer

/// The element's tag.
pub const name = "loom-composer"

/// How much of the draft the element keeps. A command and its partial
/// argument are short, and the rest of a long draft is never matched, so
/// keeping the whole text would only hold it twice.
pub const kept = 200

/// What choosing a row leaves the operator to do.
pub type Then {
  /// The command is whole: nothing more is typed for it.
  Complete

  /// The command takes an argument, so a space follows it in the editor.
  Continues
}

/// One row of the list.
pub type Entry {
  Entry(
    /// The slash-prefixed text written into the editor.
    command: String,
    /// What the command does, in a few words.
    hint: String,
    /// Whether an argument follows it.
    then: Then,
  )
}

/// Whether the list is offered for the draft as it stands.
pub type Palette {
  /// The list is offered when the draft has matches.
  Listing

  /// The operator closed it, or took a row that needs nothing more, and it
  /// stays closed until the next thing typed.
  Closed
}

/// What the element knows of the prompts the daemon has handed back, which
/// the server numbers from one in the order they came.
pub type Returns {
  /// The server has not yet said how many there are.
  Unseen

  /// The server has said. `baseline` is the count when this element first
  /// heard it: the returns up to it were the business of an editor before
  /// this one. `count` is the latest count.
  Seen(baseline: Int, count: Int)
}

/// Which way an arrow key moves the highlight.
pub type Direction {
  Up
  Down
}

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
  )
}

/// Everything the element can be told.
pub type Msg {
  /// The server sent the table of completions.
  Configured(entries: List(Entry))

  /// The server said how many prompts it has handed back.
  Returned(count: Int)

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
      Ok(Configured(entries(value)))
    }),
    component.on_attribute_change("returned", fn(value) {
      int.parse(value) |> result.map(Returned)
    }),
  ])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(
    Model(
      entries: [],
      draft: "",
      selected: 0,
      palette: Listing,
      returns: Unseen,
    ),
    effect.none(),
  )
}

/// The table a `commands` attribute holds, or no table when the attribute is
/// not one: the element then offers no list, and the editor works as it did.
///
/// ## Examples
///
/// ```gleam
/// assert composer.entries("[{\"c\":\"/compact\",\"d\":\"shrink\",\"a\":false}]")
///   == [composer.Entry("/compact", "shrink", composer.Complete)]
/// assert composer.entries("not json") == []
/// ```
pub fn entries(attribute: String) -> List(Entry) {
  json.parse(attribute, decode.list(entry()))
  |> result.unwrap([])
}

fn entry() -> decode.Decoder(Entry) {
  use command <- decode.field("c", decode.string)
  use hint <- decode.field("d", decode.string)
  use takes_argument <- decode.field("a", decode.bool)
  let then = case takes_argument {
    True -> Continues
    False -> Complete
  }
  decode.success(Entry(command:, hint:, then:))
}

/// The rows to offer for `draft`, in the table's order.
///
/// A draft that begins, past leading space, with a command that has a closed
/// argument vocabulary and a space (`/effort `) lists that command's rows
/// that start with what follows the space. Any other draft lists the
/// one-word commands it is a prefix of, when it is one word starting with
/// `/`; the draft's trailing space does not count, as in the terminal.
/// A row with a space in it is an argument row, and its head is the text
/// before the space.
///
/// ## Examples
///
/// ```gleam
/// // composer.matching(table, "/co")  lists /compact and /context
/// // composer.matching(table, "/effort lo")  lists /effort low
/// // composer.matching(table, "hello")  lists nothing
/// ```
pub fn matching(entries: List(Entry), draft: String) -> List(Entry) {
  let lead = string.trim_start(draft)
  case list.find(heads(entries), fn(head) { string.starts_with(lead, head) }) {
    Ok(head) -> {
      let partial = string.trim(string.drop_start(lead, string.length(head)))
      list.filter(entries, fn(row) {
        string.starts_with(row.command, head <> partial)
      })
    }
    Error(Nil) -> {
      let word = string.trim(lead)
      case string.starts_with(word, "/"), string.contains(word, " ") {
        True, False ->
          list.filter(entries, fn(row) {
            !string.contains(row.command, " ")
            && string.starts_with(row.command, word)
          })
        _, _ -> []
      }
    }
  }
}

// The words that take a closed vocabulary, each with the space that follows
// it: the text before the first space of every argument row.
fn heads(entries: List(Entry)) -> List(String) {
  list.filter_map(entries, fn(row) {
    case string.split_once(row.command, " ") {
      Ok(#(head, _)) -> Ok(head <> " ")
      Error(Nil) -> Error(Nil)
    }
  })
  |> list.unique
}

// The rows the list shows now, which is none while it is closed.
fn shown(model: Model) -> List(Entry) {
  case model.palette {
    Listing -> matching(model.entries, model.draft)
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
    // a prompt the daemon has just handed back. The effect is told the
    // baseline, and takes every returned prompt past it that the editor has
    // not taken yet, so two returns that reach the page before one frame
    // paints are each taken once.
    Returned(count:) ->
      case model.returns {
        Unseen -> #(
          Model(..model, returns: Seen(baseline: count, count:)),
          effect.none(),
        )
        Seen(baseline:, count: before) if count > before -> #(
          Model(..model, returns: Seen(baseline:, count:)),
          restoring(baseline),
        )
        Seen(baseline:, count: _) -> #(
          Model(..model, returns: Seen(baseline:, count:)),
          effect.none(),
        )
      }

    // Typing reopens the list and starts it at the top.
    Typed(text:) -> #(
      Model(
        ..model,
        draft: string.slice(text, 0, kept),
        selected: 0,
        palette: Listing,
      ),
      effect.none(),
    )
    Moved(direction:) -> #(
      Model(
        ..model,
        selected: moved(model.selected, list.length(shown(model)), direction),
      ),
      revealing(),
    )
    Accepted -> choose(model, model.selected)
    Picked(index:) -> choose(model, index)
    Dismissed -> #(Model(..model, palette: Closed), effect.none())
    Sent -> #(model, sending())
    Ignored -> #(model, effect.none())
  }
}

/// The highlighted row after an arrow key: it wraps at either end, and an
/// empty list holds it at the top.
///
/// ## Examples
///
/// ```gleam
/// assert composer.moved(0, 3, composer.Up) == 2
/// assert composer.moved(2, 3, composer.Down) == 0
/// ```
pub fn moved(selected: Int, count: Int, direction: Direction) -> Int {
  case count <= 0, direction {
    True, _ -> 0
    False, Down if selected >= count - 1 -> 0
    False, Down -> selected + 1
    False, Up if selected <= 0 -> count - 1
    False, Up -> selected - 1
  }
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
      let palette = case row.then, matching(model.entries, text) {
        Continues, [_, ..] -> Listing
        Continues, [] | Complete, _ -> Closed
      }
      #(Model(..model, draft: text, selected: 0, palette:), placing(text))
    }
    [] -> #(model, effect.none())
  }
}

fn placing(text: String) -> Effect(Msg) {
  use _, root <- effect.after_paint
  ffi_composer.place(root, text)
}

fn sending() -> Effect(Msg) {
  use _, root <- effect.after_paint
  ffi_composer.send(root)
}

fn restoring(baseline: Int) -> Effect(Msg) {
  use _, root <- effect.after_paint
  ffi_composer.restore(root, baseline)
}

fn revealing() -> Effect(Msg) {
  use _, root <- effect.after_paint
  ffi_composer.reveal(root)
}

// The list sits above the editor in the flow, so opening it grows the dock
// upward and leaves the editor and its buttons where they were. The editor
// is the slot's child and is drawn by the server; every word in the list is
// the static table's.
fn view(model: Model) -> Element(Msg) {
  let rows = shown(model)
  element.fragment([
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

/// The modifiers held with a key, reduced to what the element reacts to.
pub type Chord {
  /// No modifier.
  Bare

  /// Command or Control, without Alt: the chord that sends.
  Sending

  /// Shift or Alt, or some other combination, which are the browser's.
  Other
}

/// Where a key stands in the browser's own handling of it.
pub type Phase {
  /// A fresh press.
  Fresh

  /// A key held down, repeating.
  Repeating

  /// A key pressed while an input method composes text, which is the input
  /// method's.
  Composing
}

/// What a key does in the editor.
pub type Response {
  /// The element takes the key: it does this, and the browser's own action
  /// for the key is cancelled.
  Consumed(message: Msg)

  /// The element notes the key and the browser acts on it as well.
  Observed(message: Msg)
}

/// What the element does with a key, or `None` when the key is the browser's.
///
/// Command or Control with Enter sends the draft, and a held chord sends
/// once. With the list showing, Tab and Enter take a row, the arrows move and
/// Escape closes. Every other key, including Enter, is the browser's.
///
/// ## Examples
///
/// ```gleam
/// assert composer.intent("Enter", composer.Sending, composer.Fresh, composer.Closed)
///   == Some(composer.Consumed(composer.Sent))
/// assert composer.intent("Enter", composer.Bare, composer.Fresh, composer.Closed)
///   == None
/// ```
pub fn intent(
  key: String,
  chord: Chord,
  phase: Phase,
  palette: Palette,
) -> Option(Response) {
  case phase, chord, key, palette {
    Composing, _, _, _ -> None

    // Cancelling the default matters: in a textarea, Control with Enter
    // inserts a newline in some browsers.
    Fresh, Sending, "Enter", _ -> Some(Consumed(Sent))
    Repeating, Sending, "Enter", _ -> Some(Consumed(Ignored))

    // These apply only while the list is showing. With it closed, Enter is a
    // newline and Tab moves focus on, as they are anywhere else.
    _, Bare, "ArrowDown", Listing -> Some(Consumed(Moved(Down)))
    _, Bare, "ArrowUp", Listing -> Some(Consumed(Moved(Up)))
    Fresh, Bare, "Tab", Listing | Fresh, Bare, "Enter", Listing ->
      Some(Consumed(Accepted))
    _, Bare, "Escape", Listing -> Some(Observed(Dismissed))
    _, _, _, _ -> None
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
  case intent(key, chord, phase, palette) {
    Some(Consumed(message)) ->
      decode.success(event.handler(
        message,
        prevent_default: True,
        stop_propagation: False,
      ))
    Some(Observed(message)) ->
      decode.success(event.handler(
        message,
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
