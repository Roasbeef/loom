// Browser and vendor calls only. Queueing, configuration, validation and
// publication decisions live in Gleam; this module owns no renderer state.
import { Error, Ok, toList } from "../../gleam.mjs";

function found(value) {
  return value === null || value === undefined ? new Error(undefined) : new Ok(value);
}

export function document_node() { return document; }
export function document_element() { return document.documentElement; }
export function query_selector(root, selector) { return found(root.querySelector(selector)); }
export function query_selector_all(root, selector) { return toList(Array.from(root.querySelectorAll(selector))); }
export function local_name(node) { return node.localName; }
export function attributes(node) { return toList(Array.from(node.attributes)); }
export function attribute_name(attribute) { return attribute.name; }
export function attribute_value(attribute) { return attribute.value; }
export function set_attribute(node, name, value) { node.setAttribute(name, value); }
export function set_style(node, name, value) { node.style.setProperty(name, value); }
export function clear(node) { node.replaceChildren(); }
export function document_root(parsed) { return found(parsed.documentElement); }
export function import_node(node) { return document.importNode(node, true); }
export function append(parent, child) { parent.appendChild(child); }
export function height(node) { return node.getBoundingClientRect().height; }
export function width(node) { return node.clientWidth; }
export function message_data(event) { return event.data; }
export function is_parent_message(event) { return event.source === window.parent; }
export function listen_messages(handler) { window.addEventListener("message", handler); }
export function resize_observer(callback) { return new ResizeObserver(callback); }
export function observe(observer, node) { observer.observe(node); }
export function send_text(text) { window.parent.postMessage(text, "*"); }

// Foreign exceptions and promise rejection become Result values, not leaked
// vendor diagnostics. No source or configuration policy is implemented here.
export function parse_svg(markup) {
  try {
    return new Ok(new DOMParser().parseFromString(markup, "image/svg+xml"));
  } catch (_) {
    return new Error(undefined);
  }
}

export function initialize(vendor, configuration) {
  try {
    vendor.initialize(JSON.parse(configuration));
    return new Ok(undefined);
  } catch (_) {
    return new Error(undefined);
  }
}

export function render(vendor, id, source, host, done) {
  Promise.resolve()
    .then(() => vendor.render(id, source, host))
    .then(result => {
      const svg = result?.svg;
      return typeof svg === "string" ? new Ok(svg) : new Error(undefined);
    })
    .catch(() => new Error(undefined))
    .then(done);
}
