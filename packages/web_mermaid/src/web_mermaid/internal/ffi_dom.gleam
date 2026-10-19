//// Browser primitives used only by the isolated Mermaid frame.
////
//// Neither the standard library nor Lustre exposes XML parsing, arbitrary
//// DOM inspection or Mermaid's promise API. These minimal bindings are the
//// only impurity in this package; policy and queue state stay in Gleam.
//// This package is not a dependency of the session page's client bundle.

import gleam/dynamic.{type Dynamic}

/// The pinned vendor API injected by the fixed bootstrap, never by a message.
pub type Vendor

/// A browser document or DOM element.
pub type Element

/// An XML document parsed inside the opaque frame.
pub type Document

/// One DOM attribute, inspected as data before SVG is installed.
pub type Attribute

/// A width observer owned by the frame's document lifetime.
pub type Observer

/// The frame's document, for fixed-selector lookup.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.document_node(...)
/// ```
@external(javascript, "./dom.mjs", "document_node")
pub fn document_node() -> Element

/// The frame's root element, for viewport width observation.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.document_element(...)
/// ```
@external(javascript, "./dom.mjs", "document_element")
pub fn document_element() -> Element

/// The first match, or absence represented as a Result.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.query_selector(...)
/// ```
@external(javascript, "./dom.mjs", "query_selector")
pub fn query_selector(root: Element, selector: String) -> Result(Element, Nil)

/// All matching descendants, converted from the browser's node list.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.query_selector_all(...)
/// ```
@external(javascript, "./dom.mjs", "query_selector_all")
pub fn query_selector_all(root: Element, selector: String) -> List(Element)

/// An element's local XML name, not an interpreted selector.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.local_name(...)
/// ```
@external(javascript, "./dom.mjs", "local_name")
pub fn local_name(node: Element) -> String

/// An element's attributes as opaque handles for Gleam to inspect.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.attributes(...)
/// ```
@external(javascript, "./dom.mjs", "attributes")
pub fn attributes(node: Element) -> List(Attribute)

/// The literal name of one XML attribute.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.attribute_name(...)
/// ```
@external(javascript, "./dom.mjs", "attribute_name")
pub fn attribute_name(attribute: Attribute) -> String

/// The literal text of one XML attribute.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.attribute_value(...)
/// ```
@external(javascript, "./dom.mjs", "attribute_value")
pub fn attribute_value(attribute: Attribute) -> String

/// Sets one application-selected accessibility attribute.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.set_attribute(...)
/// ```
@external(javascript, "./dom.mjs", "set_attribute")
pub fn set_attribute(node: Element, name: String, value: String) -> Nil

/// Sets one fixed display property on a validated SVG.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.set_style(...)
/// ```
@external(javascript, "./dom.mjs", "set_style")
pub fn set_style(node: Element, name: String, value: String) -> Nil

/// Removes the vendor's temporary or previously displayed nodes.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.clear(...)
/// ```
@external(javascript, "./dom.mjs", "clear")
pub fn clear(node: Element) -> Nil

/// Parses vendor output as XML, converting browser exceptions to refusal.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.parse_svg(...)
/// ```
@external(javascript, "./dom.mjs", "parse_svg")
pub fn parse_svg(markup: String) -> Result(Document, Nil)

/// The parsed XML root, whose name the controller must validate.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.document_root(...)
/// ```
@external(javascript, "./dom.mjs", "document_root")
pub fn document_root(parsed: Document) -> Result(Element, Nil)

/// Copies a validated XML subtree into the frame's document.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.import_node(...)
/// ```
@external(javascript, "./dom.mjs", "import_node")
pub fn import_node(node: Element) -> Element

/// Attaches the validated copy inside the frame's diagram host.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.append(...)
/// ```
@external(javascript, "./dom.mjs", "append")
pub fn append(parent: Element, child: Element) -> Nil

/// Measures the installed SVG's height; Gleam bounds the returned dimension.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.height(...)
/// ```
@external(javascript, "./dom.mjs", "height")
pub fn height(node: Element) -> Float

/// Reads viewport width without coupling observation to changing height.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.width(...)
/// ```
@external(javascript, "./dom.mjs", "width")
pub fn width(node: Element) -> Float

/// The untrusted data of a message event, read only after its sender is checked.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.message_data(event)
/// ```
@external(javascript, "./dom.mjs", "message_data")
pub fn message_data(event: Dynamic) -> Dynamic

/// Compares message source identity with this frame's parent window.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.is_parent_message(...)
/// ```
@external(javascript, "./dom.mjs", "is_parent_message")
pub fn is_parent_message(event: Dynamic) -> Bool

/// Installs the frame's single message listener for its document lifetime.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.listen_messages(...)
/// ```
@external(javascript, "./dom.mjs", "listen_messages")
pub fn listen_messages(handler: fn(Dynamic) -> Nil) -> Nil

/// Creates a size observer without choosing a publication policy.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.resize_observer(...)
/// ```
@external(javascript, "./dom.mjs", "resize_observer")
pub fn resize_observer(callback: fn() -> Nil) -> Observer

/// Attaches an observer to the frame's root element.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.observe(...)
/// ```
@external(javascript, "./dom.mjs", "observe")
pub fn observe(observer: Observer, node: Element) -> Nil

/// Sends a JSON string to the parent; the opaque origin requires a wildcard.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.send_text(...)
/// ```
@external(javascript, "./dom.mjs", "send_text")
pub fn send_text(text: String) -> Nil

/// Passes Gleam's fixed JSON configuration to the vendor API.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.initialize(...)
/// ```
@external(javascript, "./dom.mjs", "initialize")
pub fn initialize(vendor: Vendor, configuration: String) -> Result(Nil, Nil)

/// Normalizes vendor promise success, synchronous exceptions and rejection into a callback.
///
/// ## Examples
///
/// ```gleam
/// // ffi_dom.render(...)
/// ```
@external(javascript, "./dom.mjs", "render")
pub fn render(
  vendor: Vendor,
  id: String,
  source: String,
  host: Element,
  done: fn(Result(String, Nil)) -> Nil,
) -> Nil
