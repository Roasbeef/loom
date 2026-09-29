//// The browser's DOM, one call per function, for the client components.
////
//// A client component reads and moves things in the page that no Gleam
//// library reaches on the JavaScript target: `gleam_stdlib` has no DOM,
//// Lustre's effects hand a component its shadow root and nothing to do with
//// it, and neither observes an element's size or its children, moves a
//// scroll position, listens with `passive` or submits a form. (The
//// `plinth` package covers some of this and lacks `ResizeObserver`,
//// `MutationObserver`, `removeEventListener`, `scrollBy` and `requestSubmit`,
//// so it was declined rather than added beside this module.) No pure Gleam
//// alternative exists, so this module declares the calls as `@external`s and
//// is the only module in the package that does.
////
//// Every function is one DOM call or one property access, implemented in
//// `dom.mjs` beside this module, which holds no loop, no decision and no
//// state beyond what the DOM holds. What a component decides, and the state
//// it keeps, are Gleam over these calls, in the component's own module, where
//// its model and tests are. `scripts/web_client_js_check.sh` keeps `dom.mjs`
//// the only JavaScript in the package and free of the calls that turn text
//// into markup or code.
////
//// Nothing here writes HTML. `set_value` writes a form control's text and
//// `text_content` reads text; no function takes markup.

import gleam/dynamic.{type Dynamic}

/// An element, or the shadow root of one, which answers `query_selector` and
/// `query_selector_all` as an element does. Every function that takes one
/// says which it needs.
pub type Element

/// A running event listener, which `remove_listener` stops.
pub type Listener

/// A running `ResizeObserver` or `MutationObserver`, which `disconnect` stops.
pub type Observer

/// A running repeating timer, which `clear_interval` stops.
pub type Timer

/// The shadow root Lustre hands an `after_paint` effect, as an `Element`: a
/// shadow root answers `query_selector` and `query_selector_all` as an
/// element does, and it is the only way into a component's own shadow tree,
/// which `host.querySelector` does not reach.
///
/// ## Examples
///
/// ```gleam
/// // let root = ffi_dom.as_element(root)
/// ```
@external(javascript, "./dom.mjs", "as_element")
pub fn as_element(root: Dynamic) -> Element

/// The element a shadow root belongs to, which is the custom element itself
/// (`root.host`).
///
/// ## Examples
///
/// ```gleam
/// // let host = ffi_dom.host(root)
/// ```
@external(javascript, "./dom.mjs", "host")
pub fn host(element: Element) -> Element

/// Whether two handles name the same node (`===`). Gleam's `==` would
/// compare the objects' fields, which says nothing about identity for a DOM
/// node.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.same(row, row)
/// ```
@external(javascript, "./dom.mjs", "same")
pub fn same(a: Element, b: Element) -> Bool

/// Whether the element is in a document (`isConnected`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.is_connected(row)
/// ```
@external(javascript, "./dom.mjs", "is_connected")
pub fn is_connected(element: Element) -> Bool

/// The element's first child element, or `Error(Nil)` when it has none
/// (`firstElementChild`).
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(row) = ffi_dom.first_element_child(lane)
/// ```
@external(javascript, "./dom.mjs", "first_element_child")
pub fn first_element_child(element: Element) -> Result(Element, Nil)

/// The element's child elements, in document order (`children`).
///
/// ## Examples
///
/// ```gleam
/// // let rows = ffi_dom.children(host)
/// ```
@external(javascript, "./dom.mjs", "children")
pub fn children(element: Element) -> List(Element)

/// The nearest ancestor of the element, itself included, that matches the
/// selector, or `Error(Nil)` (`closest`).
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(form) = ffi_dom.closest(host, "form")
/// ```
@external(javascript, "./dom.mjs", "closest")
pub fn closest(element: Element, selector: String) -> Result(Element, Nil)

/// The first descendant that matches the selector, or `Error(Nil)`
/// (`querySelector`).
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(area) = ffi_dom.query_selector(host, "textarea")
/// ```
@external(javascript, "./dom.mjs", "query_selector")
pub fn query_selector(root: Element, selector: String) -> Result(Element, Nil)

/// Every descendant that matches the selector, in document order
/// (`querySelectorAll`).
///
/// ## Examples
///
/// ```gleam
/// // let held = ffi_dom.query_selector_all(host, "[slot=\"returned\"]")
/// ```
@external(javascript, "./dom.mjs", "query_selector_all")
pub fn query_selector_all(root: Element, selector: String) -> List(Element)

/// A `data-` attribute by its camel-cased key, or `Error(Nil)` when the
/// element does not carry it (`dataset[key]`).
///
/// ## Examples
///
/// ```gleam
/// // let assert Ok(n) = ffi_dom.dataset_get(held, "n")
/// ```
@external(javascript, "./dom.mjs", "dataset_get")
pub fn dataset_get(element: Element, key: String) -> Result(String, Nil)

/// The text of the element and its descendants (`textContent`), read as
/// text and never parsed.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.text_content(held)
/// ```
@external(javascript, "./dom.mjs", "text_content")
pub fn text_content(element: Element) -> String

/// How far the element's content is scrolled, in pixels, which may be
/// fractional (`scrollTop`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.scroll_top(host)
/// ```
@external(javascript, "./dom.mjs", "scroll_top")
pub fn scroll_top(element: Element) -> Float

/// Scrolls the element's content to `top` pixels at once, without animation
/// (`scrollTop = top`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.set_scroll_top(host, 0.0)
/// ```
@external(javascript, "./dom.mjs", "set_scroll_top")
pub fn set_scroll_top(element: Element, top: Float) -> Nil

/// Scrolls the element by `dy` pixels vertically, at once (`scrollBy(0, dy)`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.scroll_by(host, 12.0)
/// ```
@external(javascript, "./dom.mjs", "scroll_by")
pub fn scroll_by(element: Element, dy: Float) -> Nil

/// The full height of the element's content, in pixels (`scrollHeight`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.scroll_height(host)
/// ```
@external(javascript, "./dom.mjs", "scroll_height")
pub fn scroll_height(element: Element) -> Float

/// The height of the element's visible area, in pixels (`clientHeight`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.client_height(host)
/// ```
@external(javascript, "./dom.mjs", "client_height")
pub fn client_height(element: Element) -> Float

/// The element's distance from the top edge of its positioned ancestor, in
/// pixels (`offsetTop`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.offset_top(row)
/// ```
@external(javascript, "./dom.mjs", "offset_top")
pub fn offset_top(element: Element) -> Float

/// The element's layout height, in pixels (`offsetHeight`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.offset_height(row)
/// ```
@external(javascript, "./dom.mjs", "offset_height")
pub fn offset_height(element: Element) -> Float

/// The top edge of the element's box in the viewport, in pixels
/// (`getBoundingClientRect().top`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.bounding_top(row)
/// ```
@external(javascript, "./dom.mjs", "bounding_top")
pub fn bounding_top(element: Element) -> Float

/// Calls `handler` on every `event` the element receives, as a listener
/// that promises not to cancel it (`addEventListener` with `passive`). The
/// handler is told nothing about the event.
///
/// ## Examples
///
/// ```gleam
/// // let listener = ffi_dom.add_passive_listener(host, "scroll", fn() { Nil })
/// ```
@external(javascript, "./dom.mjs", "add_passive_listener")
pub fn add_passive_listener(
  element: Element,
  event: String,
  handler: fn() -> Nil,
) -> Listener

/// Stops a listener `add_passive_listener` returned, on the element and
/// event it was added for (`removeEventListener`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.remove_listener(host, "scroll", listener)
/// ```
@external(javascript, "./dom.mjs", "remove_listener")
pub fn remove_listener(
  element: Element,
  event: String,
  listener: Listener,
) -> Nil

/// A `ResizeObserver` that calls `callback` after any element it observes
/// changes size. It observes nothing until `observe` names an element.
///
/// ## Examples
///
/// ```gleam
/// // let sizes = ffi_dom.resize_observer(fn() { Nil })
/// ```
@external(javascript, "./dom.mjs", "resize_observer")
pub fn resize_observer(callback: fn() -> Nil) -> Observer

/// Has a resize observer watch an element's box (`ResizeObserver.observe`).
/// Observing an element already observed changes nothing.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.observe(sizes, host)
/// ```
@external(javascript, "./dom.mjs", "observe")
pub fn observe(observer: Observer, element: Element) -> Nil

/// A `MutationObserver` that calls `callback` after any element it observes
/// gains or loses a child. It observes nothing until `observe_child_list`
/// names an element.
///
/// ## Examples
///
/// ```gleam
/// // let children = ffi_dom.mutation_observer(fn() { Nil })
/// ```
@external(javascript, "./dom.mjs", "mutation_observer")
pub fn mutation_observer(callback: fn() -> Nil) -> Observer

/// Has a mutation observer watch an element's direct children come and go
/// (`MutationObserver.observe` with `childList`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.observe_child_list(children, host)
/// ```
@external(javascript, "./dom.mjs", "observe_child_list")
pub fn observe_child_list(observer: Observer, element: Element) -> Nil

/// Stops an observer of either kind from reporting anything more
/// (`disconnect`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.disconnect(sizes)
/// ```
@external(javascript, "./dom.mjs", "disconnect")
pub fn disconnect(observer: Observer) -> Nil

/// The text in a form control (`value`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.value(area)
/// ```
@external(javascript, "./dom.mjs", "value")
pub fn value(element: Element) -> String

/// Replaces the text in a form control (`value = text`). Writing it fires
/// no `input` event.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.set_value(area, "/compact")
/// ```
@external(javascript, "./dom.mjs", "set_value")
pub fn set_value(element: Element, text: String) -> Nil

/// The length of `text` in UTF-16 code units (`length`), which is the unit
/// a caret position is counted in. `string.length` counts graphemes, which
/// is not the same for an emoji.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.utf16_length("ab") == 2
/// ```
@external(javascript, "./dom.mjs", "utf16_length")
pub fn utf16_length(text: String) -> Int

/// Selects the text of a form control between two offsets in UTF-16 code
/// units; with the two equal, places the caret there (`setSelectionRange`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.set_selection_range(area, 8, 8)
/// ```
@external(javascript, "./dom.mjs", "set_selection_range")
pub fn set_selection_range(element: Element, start: Int, end: Int) -> Nil

/// Gives the element the keyboard focus (`focus`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.focus(area)
/// ```
@external(javascript, "./dom.mjs", "focus")
pub fn focus(element: Element) -> Nil

/// Submits a form the way a submit button's press does, running its submit
/// listeners and its validation (`requestSubmit`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.request_submit(form)
/// ```
@external(javascript, "./dom.mjs", "request_submit")
pub fn request_submit(form: Element) -> Nil

/// Submits a form as a press of `submitter` does, so the submit event
/// carries that button and its `name` and `value`
/// (`requestSubmit(submitter)`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.request_submit_with(form, button)
/// ```
@external(javascript, "./dom.mjs", "request_submit_with")
pub fn request_submit_with(form: Element, submitter: Element) -> Nil

/// Clicks an element as a person's press does, running its click listeners
/// and, for a button, its activation behaviour (`click`). The shell uses it to
/// press a strand card on behalf of a control that has no handler of its own,
/// so the press is an ordinary click on an ordinary handler.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.click(card)
/// ```
@external(javascript, "./dom.mjs", "click")
pub fn click(element: Element) -> Nil

/// The browser's wall clock in Unix milliseconds (`Date.now`). The daemon
/// states an operation's start on the same scale.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.now() > 0
/// ```
@external(javascript, "./dom.mjs", "now")
pub fn now() -> Int

/// Calls `callback` every `interval` milliseconds until the timer is
/// cleared (`setInterval`).
///
/// ## Examples
///
/// ```gleam
/// // let timer = ffi_dom.set_interval(1000, fn() { Nil })
/// ```
@external(javascript, "./dom.mjs", "set_interval")
pub fn set_interval(interval: Int, callback: fn() -> Nil) -> Timer

/// Stops a timer `set_interval` returned (`clearInterval`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.clear_interval(timer)
/// ```
@external(javascript, "./dom.mjs", "clear_interval")
pub fn clear_interval(timer: Timer) -> Nil
