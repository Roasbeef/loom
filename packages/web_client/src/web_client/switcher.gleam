//// `<loom-switcher>`: a session switcher opened from the keyboard with Command
//// or Control and K, listing the sessions the page already has.
////
//// Both pages draw a sidebar of the sessions the principal may open, each as
//// a button whose one handler asks the daemon for a ticket
//// (`view/sidebar`). The switcher does not ask the server anything new. When
//// it opens it reads those buttons from the page, takes each one's name,
//// workspace and subtitle as text, lists them in a popover that the typed
//// query filters (`switcher_rule`), and on Enter or a click presses the
//// chosen row's own sidebar button. The press is an ordinary click on an
//// ordinary handler, so the ticket is minted, checked and spent exactly as
//// the sidebar's is, and the switcher has no route of its own to the browser's
//// navigation.
////
//// The element sends the server nothing and reads from it nothing but the
//// text that is already in the page. Every name it draws is a text node of its
//// own view: it never assigns a name to markup, an attribute it reads back or
//// the document's address (protocol-change/051, the addendum on the session
//// switcher). The one document listener it keeps is for `keydown`, one per
//// connection, removed when the element leaves the page. While the popover is
//// open the query field has the focus, and Escape or a press outside the
//// panel closes it.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
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
import web_client/composer_rule
import web_client/internal/ffi_dom.{type Listener}
import web_client/switcher_rule.{type Row}

/// The element's tag.
pub const name = "loom-switcher"

/// One row the page offered, with the sidebar button that opens it.
pub type Entry {
  Entry(row: Row, button: ffi_dom.Element)
}

/// Whether the popover is showing.
pub type State {
  /// The popover is not drawn.
  Hidden

  /// The popover is drawn over the page with the rows read when it opened,
  /// what has been typed and which listed row is highlighted.
  Showing(entries: List(Entry), query: String, selected: Int)
}

/// What the element holds: the popover's state and the document's `keydown`
/// listener while the element is connected.
pub type Model {
  Model(state: State, listener: Option(Listener))
}

/// Everything the element can be told.
pub type Msg {
  /// The shortcut was pressed.
  Toggled

  /// Escape was pressed.
  Escaped

  /// The page's rows were read, after the shortcut opened the popover.
  Scanned(entries: List(Entry))

  /// The query field changed.
  Typed(text: String)

  /// An arrow key moved the highlight.
  Moved(direction: switcher_rule.Intent)

  /// Enter was pressed: open the highlighted row.
  Chose

  /// A row was pressed: open it. The index is the row's place among all the
  /// rows the page offered.
  Picked(index: Int)

  /// The backdrop was pressed, outside the panel.
  Dismissed

  /// A press inside the panel that does nothing, so it does not reach the
  /// backdrop.
  Ignored

  /// The element joined the page.
  Connected

  /// The element left the page.
  Disconnected

  /// The document's listener is in place.
  Listening(listener: Listener)
}

/// Registers the element with the browser.
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(Nil) = switcher.register()
/// ```
pub fn register() -> Result(Nil, lustre.Error) {
  lustre.component(init, update, view, [
    component.on_connect(Connected),
    component.on_disconnect(Disconnected),
  ])
  |> lustre.register(name)
}

fn init(_: Nil) -> #(Model, Effect(Msg)) {
  #(init_model(), effect.none())
}

/// The starting model, for a test that drives `update`.
///
/// ## Examples
///
/// ```gleam
/// assert switcher.init_model().state == switcher.Hidden
/// ```
pub fn init_model() -> Model {
  Model(state: Hidden, listener: None)
}

/// Applies one message.
///
/// The shortcut asks the page for its rows, and the popover opens when they
/// arrive, so what it lists is what the page held at that moment. A row is
/// opened by pressing its sidebar button, and the popover closes in the same
/// step, so a second Enter finds nothing to open.
///
/// ## Examples
///
/// ```gleam
/// assert switcher.update(switcher.init_model(), switcher.Escaped).0.state
///   == switcher.Hidden
/// ```
pub fn update(model: Model, message: Msg) -> #(Model, Effect(Msg)) {
  case message, model.state {
    Toggled, Hidden -> #(model, scanning())
    Toggled, Showing(..) | Escaped, Showing(..) | Dismissed, Showing(..) -> #(
      Model(..model, state: Hidden),
      effect.none(),
    )
    Escaped, Hidden | Dismissed, Hidden | Ignored, _ -> #(model, effect.none())

    Scanned(entries:), _ -> #(
      Model(..model, state: Showing(entries:, query: "", selected: 0)),
      focusing(),
    )

    Typed(text:), Showing(entries:, ..) -> #(
      Model(..model, state: Showing(entries:, query: text, selected: 0)),
      effect.none(),
    )
    Moved(direction:), Showing(entries:, query:, selected:) -> {
      let count = list.length(listed(entries, query))
      #(
        Model(
          ..model,
          state: Showing(
            entries:,
            query:,
            selected: switcher_rule.moved(selected, direction, count),
          ),
        ),
        revealing(),
      )
    }
    Chose, Showing(entries:, query:, selected:) ->
      case list.drop(listed(entries, query), selected) {
        [switcher_rule.Match(index:, ..), ..] -> opening(model, entries, index)
        [] -> #(model, effect.none())
      }
    Picked(index:), Showing(entries:, ..) -> opening(model, entries, index)
    Typed(_), Hidden | Moved(_), Hidden | Chose, Hidden | Picked(_), Hidden -> #(
      model,
      effect.none(),
    )

    // One listener per connection: moving the element stops the old one
    // before it starts another.
    Connected, _ -> #(model, effect.batch([stop(model.listener), listen()]))
    Listening(listener:), _ -> #(
      Model(..model, listener: Some(listener)),
      stop(model.listener),
    )
    Disconnected, _ -> #(
      Model(state: Hidden, listener: None),
      stop(model.listener),
    )
  }
}

// The popover closes and the chosen row's own sidebar button is pressed. A
// button the server has since removed is not pressed: the row was drawn from a
// list that has changed, and nothing is opened.
fn opening(
  model: Model,
  entries: List(Entry),
  index: Int,
) -> #(Model, Effect(Msg)) {
  let model = Model(..model, state: Hidden)
  case list.drop(entries, index) {
    [Entry(button:, ..), ..] -> #(model, pressing(button))
    [] -> #(model, effect.none())
  }
}

fn pressing(button: ffi_dom.Element) -> Effect(Msg) {
  use _ <- effect.from
  case ffi_dom.is_connected(button) {
    True -> ffi_dom.click(button)
    False -> Nil
  }
}

// The rows the query lists, in the order they are drawn.
fn listed(entries: List(Entry), query: String) -> List(switcher_rule.Match) {
  switcher_rule.matching(list.map(entries, fn(entry) { entry.row }), query)
}

// Reads the sidebar's openable rows from the page that holds this element:
// the root its host is attached under, which is the server component's. A row
// is a button the server drew, and the name, workspace and subtitle are the
// text it carries, read as text and nothing else.
fn scanning() -> Effect(Msg) {
  use dispatch, root <- effect.after_paint
  let page = ffi_dom.root_node(ffi_dom.host(ffi_dom.as_element(root)))
  ffi_dom.query_selector_all(page, ".sidebar .session-open")
  |> list.filter_map(entry_of)
  |> Scanned
  |> dispatch
}

fn entry_of(button: ffi_dom.Element) -> Result(Entry, Nil) {
  use name <- result.map(text_of(button, ".session-name"))
  let subtitle = result.unwrap(text_of(button, ".session-subtitle"), "")
  let workspace =
    ffi_dom.closest(button, ".workspace-group")
    |> result.try(ffi_dom.query_selector(_, ".workspace"))
    |> result.try(ffi_dom.attribute(_, "title"))
    |> result.map(switcher_rule.workspace_label)
    |> result.unwrap("")
  let kind = case
    ffi_dom.query_selector(button, ".residency")
    |> result.try(ffi_dom.attribute(_, "class"))
  {
    Ok(classes) ->
      case list.contains(string.split(classes, " "), "saved") {
        True -> switcher_rule.Saved
        False -> switcher_rule.Running
      }
    Error(Nil) -> switcher_rule.Running
  }
  Entry(row: switcher_rule.Row(name:, workspace:, subtitle:, kind:), button:)
}

fn text_of(within: ffi_dom.Element, selector: String) -> Result(String, Nil) {
  ffi_dom.query_selector(within, selector)
  |> result.map(fn(found) { string.trim(ffi_dom.text_content(found)) })
}

// Puts the focus in the query field once the popover is drawn.
fn focusing() -> Effect(Msg) {
  use _, root <- effect.after_paint
  case ffi_dom.query_selector(ffi_dom.as_element(root), "input") {
    Ok(field) -> ffi_dom.focus(field)
    Error(Nil) -> Nil
  }
}

// Scrolls the list, and only the list, so the highlighted row is inside it, as
// the composer's completion list does.
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

// Listens for `keydown` on the document, which hears the shortcut wherever the
// focus is, the page's shadow trees included. The shortcut is cancelled so the
// browser's own use of it does not also run; Escape is only observed.
fn listen() -> Effect(Msg) {
  use dispatch, _ <- effect.after_paint
  let listener =
    ffi_dom.add_listener(ffi_dom.get_document(), "keydown", fn(event) {
      case pressed(event) {
        Ok(Toggled) -> {
          ffi_dom.prevent_default(event)
          dispatch(Toggled)
        }
        Ok(message) -> dispatch(message)
        Error(Nil) -> Nil
      }
    })
  dispatch(Listening(listener))
}

// The message a document key press is, or nothing for a key the switcher does
// not read.
fn pressed(event: Dynamic) -> Result(Msg, Nil) {
  let keys = {
    use key <- decode.field("key", decode.string)
    use meta <- decode.field("metaKey", decode.bool)
    use control <- decode.field("ctrlKey", decode.bool)
    use shift <- decode.field("shiftKey", decode.bool)
    use alt <- decode.field("altKey", decode.bool)
    let chord = case meta || control, shift || alt {
      True, False -> switcher_rule.Primary
      False, False -> switcher_rule.Bare
      _, _ -> switcher_rule.Other
    }
    decode.success(case switcher_rule.shortcut(key, chord), key {
      True, _ -> Ok(Toggled)
      False, "Escape" -> Ok(Escaped)
      False, _ -> Error(Nil)
    })
  }
  decode.run(event, keys) |> result.unwrap(Error(Nil))
}

fn stop(listener: Option(Listener)) -> Effect(Msg) {
  case listener {
    None -> effect.none()
    Some(listener) -> {
      use _ <- effect.from
      ffi_dom.remove_listener(ffi_dom.get_document(), "keydown", listener)
    }
  }
}

// The popover: a backdrop that closes it when pressed, and on it the panel
// with the query field and the rows. Every name is a text node.
fn view(model: Model) -> Element(Msg) {
  case model.state {
    Hidden -> element.none()
    Showing(entries:, query:, selected:) -> {
      let rows = listed(entries, query)
      html.div(
        [attribute.class("switcher-backdrop"), event.on_click(Dismissed)],
        [
          html.div(
            [
              attribute.class("switcher"),
              attribute.role("dialog"),
              attribute.aria_modal(True),
              attribute.aria_label("Switch session"),
              event.on_click(Ignored) |> event.stop_propagation,
            ],
            [
              html.input([
                attribute.class("switcher-input"),
                attribute.type_("text"),
                attribute.role("combobox"),
                attribute.aria_expanded(True),
                attribute.aria_label("Find a session"),
                attribute.placeholder("Find a session"),
                attribute.attribute("autocomplete", "off"),
                attribute.attribute("spellcheck", "false"),
                attribute.value(query),
                event.on_input(Typed),
                event.advanced("keydown", keystroke()),
              ]),
              case rows {
                [] -> empty(entries)
                [_, ..] ->
                  html.ul(
                    [
                      attribute.class("switcher-list"),
                      attribute.role("listbox"),
                      attribute.aria_label("Sessions"),
                    ],
                    list.index_map(rows, fn(match, place) {
                      row(match, place == selected)
                    }),
                  )
              },
              html.p([attribute.class("switcher-hint")], [
                html.text("Up and down to move, Enter to open, Esc to close"),
              ]),
            ],
          ),
        ],
      )
    }
  }
}

fn empty(entries: List(Entry)) -> Element(Msg) {
  html.p([attribute.class("switcher-empty")], [
    html.text(case entries {
      [] -> "There is no other session to open."
      [_, ..] -> "No session matches."
    }),
  ])
}

fn row(match: switcher_rule.Match, current: Bool) -> Element(Msg) {
  let row = match.row
  html.li(
    [
      attribute.class("switcher-row"),
      attribute.classes([#("current", current)]),
      attribute.role("option"),
      attribute.aria_selected(current),
      event.on_click(Picked(match.index)),
    ],
    [
      html.span([attribute.class("switcher-name")], [html.text(row.name)]),
      html.span([attribute.class("switcher-detail")], [
        html.text(detail(row)),
      ]),
    ],
  )
}

// The quiet words after a row's name: where it runs, what it began as, and
// that it is only saved.
fn detail(row: Row) -> String {
  let parts = [
    row.workspace,
    row.subtitle,
    case row.kind {
      switcher_rule.Saved -> "saved"
      switcher_rule.Running -> ""
    },
  ]
  list.filter(parts, fn(part) { part != "" }) |> string.join(" · ")
}

// A key pressed in the field. The arrows and Enter are the list's and are
// cancelled so the field's caret does not move; every other key fails the
// decoder, so nothing is dispatched and nothing is cancelled.
fn keystroke() -> decode.Decoder(event.Handler(Msg)) {
  use key <- decode.field("key", decode.string)
  use composing <- decode.field("isComposing", decode.bool)
  let phase = case composing {
    True -> switcher_rule.Composing
    False -> switcher_rule.Typing
  }
  case switcher_rule.intent(key, phase) {
    switcher_rule.Up ->
      decode.success(event.handler(
        Moved(switcher_rule.Up),
        prevent_default: True,
        stop_propagation: False,
      ))
    switcher_rule.Down ->
      decode.success(event.handler(
        Moved(switcher_rule.Down),
        prevent_default: True,
        stop_propagation: False,
      ))
    switcher_rule.Choose ->
      decode.success(event.handler(
        Chose,
        prevent_default: True,
        stop_propagation: False,
      ))
    switcher_rule.Pass ->
      decode.failure(
        event.handler(Ignored, prevent_default: False, stop_propagation: False),
        "key",
      )
  }
}
