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
////
//// The one call here that is not the DOM proper is the browser's storage,
//// `storage_read` and `storage_write`. They are the only way the package
//// reaches it, each answers a `Result` because storage throws when it is
//// blocked, and what is stored and how it is read back are decided in
//// `web_client/layout_rule`. `scripts/web_client_js_check.sh` refuses any
//// other use of storage in the package.

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

/// A file the browser holds, from a file input or the clipboard. It is
/// opaque: the functions below read its name, type and size, and
/// `read_data_url` reads its bytes.
pub type File

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

/// The root an element is attached under (`getRootNode`): the document, or
/// the shadow root of the server component that holds the element. It answers
/// the element's own subtree when the element is detached.
///
/// ## Examples
///
/// ```gleam
/// // let page = ffi_dom.root_node(ffi_dom.host(root))
/// ```
@external(javascript, "./dom.mjs", "root_node")
pub fn root_node(element: Element) -> Element

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

/// Scrolls every scrolling ancestor of the element by the least that shows all
/// of it (`scrollIntoView({block: "nearest"})`), and does nothing when it is
/// already in view.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.scroll_into_view(section)
/// ```
@external(javascript, "./dom.mjs", "scroll_into_view")
pub fn scroll_into_view(element: Element) -> Nil

/// The browser's offset from UTC at the instant `milliseconds`, in minutes and
/// positive west of Greenwich (`getTimezoneOffset`), so a zone's daylight rule
/// is the browser's and not a table of ours.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.timezone_offset_minutes(1_790_030_460_000)
/// ```
@external(javascript, "./dom.mjs", "timezone_offset_minutes")
pub fn timezone_offset_minutes(milliseconds: Int) -> Int

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

/// Has a mutation observer watch the text under an element, to any depth, for
/// a change or for nodes coming and going (`MutationObserver.observe` with
/// `characterData`, `childList` and `subtree`). `<loom-title>` watches the
/// session's name in the bar with it.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.observe_text(changes, heading)
/// ```
@external(javascript, "./dom.mjs", "observe_text")
pub fn observe_text(observer: Observer, element: Element) -> Nil

/// Has a mutation observer watch one attribute of an element and nothing else
/// (`MutationObserver.observe` with `attributeFilter`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.observe_attribute(changes, frame, "needing")
/// ```
@external(javascript, "./dom.mjs", "observe_attribute")
pub fn observe_attribute(
  observer: Observer,
  element: Element,
  name: String,
) -> Nil

/// Writes the document's title (`document.title`). The value is text and is
/// never parsed as markup, so it needs no escaping here.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.set_title("docs sweep — Loom")
/// ```
@external(javascript, "./dom.mjs", "set_title")
pub fn set_title(text: String) -> Nil

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

/// The page's `document`, on which a listener hears every key pressed in the
/// page whatever has focus, `body` included.
///
/// ## Examples
///
/// ```gleam
/// // let page = ffi_dom.get_document()
/// ```
@external(javascript, "./dom.mjs", "get_document")
pub fn get_document() -> Element

/// Adds a listener that is called with the event and may cancel it
/// (`addEventListener`, not passive). `remove_listener` stops it.
///
/// ## Examples
///
/// ```gleam
/// // let listener = ffi_dom.add_listener(page, "keydown", fn(event) { Nil })
/// ```
@external(javascript, "./dom.mjs", "add_listener")
pub fn add_listener(
  element: Element,
  event: String,
  handler: fn(Dynamic) -> Nil,
) -> Listener

/// The nodes an event passed through, from its target outward, shadow trees
/// included (`composedPath`). A listener on the document sees an event's
/// target retargeted to the outermost shadow host; the path is how it sees
/// what was inside.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.composed_path(event)
/// ```
@external(javascript, "./dom.mjs", "composed_path")
pub fn composed_path(event: Dynamic) -> List(Element)

/// A node's tag in lower case (`localName`), or `Error` for a node that has
/// none: the window, the document and a shadow root.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.tag_name(node) == Ok("textarea")
/// ```
@external(javascript, "./dom.mjs", "tag_name")
pub fn tag_name(node: Element) -> Result(String, Nil)

/// A node's attribute (`getAttribute`), `Ok("")` for one that is present and
/// empty, or `Error` when it is absent or the node is not an element.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.attribute(node, "data-loom-approvals") == Ok("")
/// ```
@external(javascript, "./dom.mjs", "attribute")
pub fn attribute(node: Element, name: String) -> Result(String, Nil)

/// Whether a node's text can be edited (`isContentEditable`), or `Error` for
/// a node that is not an element.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.is_content_editable(node) == Ok(True)
/// ```
@external(javascript, "./dom.mjs", "is_content_editable")
pub fn is_content_editable(node: Element) -> Result(Bool, Nil)

/// Cancels an event's browser action (`preventDefault`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.prevent_default(event)
/// ```
@external(javascript, "./dom.mjs", "prevent_default")
pub fn prevent_default(event: Dynamic) -> Nil

/// The button that submitted a form (`SubmitEvent.submitter`): the one
/// pressed, or the one `request_submit_with` named. `Error` for a submit
/// raised with none.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.submitter(event)
/// ```
@external(javascript, "./dom.mjs", "submitter")
pub fn submitter(event: Dynamic) -> Result(Element, Nil)

/// The files of a `FileList` (`Array.from`), such as the one a file input's
/// `change` event carries as `target.files`.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.file_list(files)
/// ```
@external(javascript, "./dom.mjs", "file_list")
pub fn file_list(files: Dynamic) -> List(File)

/// The files a `paste` event's clipboard holds (`clipboardData.files`), or
/// none.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.clipboard_files(event)
/// ```
@external(javascript, "./dom.mjs", "clipboard_files")
pub fn clipboard_files(event: Dynamic) -> List(File)

/// The kinds of data a drag event carries (`dataTransfer.types`): `"Files"`
/// for a drag of files, media types for anything else. A drag that carries
/// files lists them while it is still over the page, though their contents are
/// readable only on the drop.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.drag_types(event)
/// ```
@external(javascript, "./dom.mjs", "drag_types")
pub fn drag_types(event: Dynamic) -> List(String)

/// The files a `drop` event carries (`dataTransfer.files`), or none.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.drag_files(event)
/// ```
@external(javascript, "./dom.mjs", "drag_files")
pub fn drag_files(event: Dynamic) -> List(File)

/// The element a drag event is moving to or from (`relatedTarget`), or
/// `Error(Nil)` when the pointer left the window or the browser withholds it.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.related_target(event)
/// ```
@external(javascript, "./dom.mjs", "related_target")
pub fn related_target(event: Dynamic) -> Result(Element, Nil)

/// Whether a node is the element or inside it (`Node.contains`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.contains(form, node)
/// ```
@external(javascript, "./dom.mjs", "contains")
pub fn contains(element: Element, node: Element) -> Bool

/// A file's name (`File.name`). It is the person's own file name, a text the
/// browser reports and the page only ever draws as a text node.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.file_name(file)
/// ```
@external(javascript, "./dom.mjs", "file_name")
pub fn file_name(file: File) -> String

/// A file's declared media type (`File.type`), which is the browser's guess
/// from the name and not a check of the bytes.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.file_type(file) == "image/png"
/// ```
@external(javascript, "./dom.mjs", "file_type")
pub fn file_type(file: File) -> String

/// A file's size in bytes (`File.size`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.file_size(file)
/// ```
@external(javascript, "./dom.mjs", "file_size")
pub fn file_size(file: File) -> Int

/// Reads a file's bytes as a `data:` URL (`FileReader.readAsDataURL`) and
/// answers `done` once with the URL, or with `Error` when the read failed.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.read_data_url(file, fn(read) { Nil })
/// ```
@external(javascript, "./dom.mjs", "read_data_url")
pub fn read_data_url(file: File, done: fn(Result(String, Nil)) -> Nil) -> Nil

/// The item the browser's `localStorage` holds under `key`, or `Error` when
/// there is none or the storage cannot be read. The storage throws when it is
/// blocked and in some private windows; the export catches that and answers
/// `Error`, so a caller cannot tell a first visit from a blocked storage and
/// does not need to. Storage is per origin, so the item is only what a page
/// of this scheme, host and port wrote.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.storage_read("loom.layout.v1.<digest>")
/// ```
@external(javascript, "./dom.mjs", "storage_read")
pub fn storage_read(key: String) -> Result(String, Nil)

/// Stores `value` under `key` in the browser's `localStorage` (`setItem`), or
/// answers `Error` when the storage refuses, because it is blocked, full or
/// private. A caller that cannot save carries on with the value it has.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.storage_write("loom.layout.v1.<digest>", "{}")
/// ```
@external(javascript, "./dom.mjs", "storage_write")
pub fn storage_write(key: String, value: String) -> Result(Nil, Nil)

/// The page's root element, `<html>` (`document.documentElement`). Custom
/// properties set on it reach every shadow root under the page, which is why
/// the theme's `data-theme` attribute is written here.
///
/// ## Examples
///
/// ```gleam
/// // let root = ffi_dom.document_element()
/// ```
@external(javascript, "./dom.mjs", "document_element")
pub fn document_element() -> Element

/// Sets an attribute on an element (`setAttribute`). The value is text and is
/// never parsed as markup.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.set_attribute(root, "data-theme", "dark")
/// ```
@external(javascript, "./dom.mjs", "set_attribute")
pub fn set_attribute(element: Element, name: String, value: String) -> Nil

/// Removes an attribute from an element (`removeAttribute`), which is nothing
/// when it has none.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.remove_attribute(root, "data-theme")
/// ```
@external(javascript, "./dom.mjs", "remove_attribute")
pub fn remove_attribute(element: Element, name: String) -> Nil

/// Moves the browser to a new address (`location.assign`), which unloads the
/// page and adds a history entry for it. A page's nonce is kept under its own
/// key, so Back to the page left behind finds the nonce it needs and
/// reconnects. The ticket's own URL does not stay in the history: the exchange
/// page replaces itself with the keyed page. `<loom-switch>` calls it, and only
/// with an address `web_client/switch_rule.target` accepted, so no script of
/// the page navigates to a value the rule has not checked.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.assign_location("/ui/sessions/0198...?ticket=ab12...")
/// ```
@external(javascript, "./dom.mjs", "assign_location")
pub fn assign_location(address: String) -> Nil

/// Goes one step back in the tab's history (`history.back`). It takes no
/// address and mints no ticket, so it can only reach a page the tab already
/// visited. `<loom-back>` calls it.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.history_back()
/// ```
@external(javascript, "./dom.mjs", "history_back")
pub fn history_back() -> Nil

/// Calls `done` once after `milliseconds` (`setTimeout`). `<loom-waiting>`
/// uses it to wait for the socket.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.after(5000, fn() { dispatch(Waited) })
/// ```
@external(javascript, "./dom.mjs", "after")
pub fn after(milliseconds: Int, done: fn() -> Nil) -> Nil

/// Writes `text` to the system clipboard (`navigator.clipboard.writeText`) and
/// hands the outcome to `done` when the browser answers. The write is refused
/// when the page is not a secure context, when the clipboard is not permitted
/// and when the press was not a user's own; each is `Error(Nil)`, and no
/// exception reaches the caller. `<loom-copy>` calls it in the press's own
/// turn, and only with text `web_client/copy_rule.text` accepted.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.write_clipboard("loom claim --addr ws://127.0.0.1:4000/v2/control", done)
/// ```
@external(javascript, "./dom.mjs", "write_clipboard")
pub fn write_clipboard(text: String, done: fn(Result(Nil, Nil)) -> Nil) -> Nil

/// A media query's live answer (`window.matchMedia`), an event target whose
/// `change` event carries the new `matches`. The shell asks it whether the
/// page is narrow, which only the browser knows.
///
/// ## Examples
///
/// ```gleam
/// // let narrow = ffi_dom.media_query("(max-width: 1211px)")
/// ```
@external(javascript, "./dom.mjs", "media_query")
pub fn media_query(query: String) -> Element

/// Whether a media query from `media_query` matches now (`matches`).
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.media_matches(narrow)
/// ```
@external(javascript, "./dom.mjs", "media_matches")
pub fn media_matches(query: Element) -> Bool
