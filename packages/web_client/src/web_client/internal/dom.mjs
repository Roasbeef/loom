// The browser's DOM, one call at a time, behind `web_client/internal/ffi_dom`.
// See that module for why these are JavaScript.
//
// Every export here is one DOM call or one property access. There is no
// loop, no decision and no state beyond what the DOM holds; each client
// component's logic is Gleam, written over these. The one conversion in the
// file is `found`, which turns a DOM answer of null or undefined into the
// `Error(Nil)` a Gleam caller can match on. Nothing here writes markup: no
// export takes a string that the browser would parse as HTML.

import { Error, Ok, toList } from "../../gleam.mjs";

// The DOM answers "nothing there" with null or undefined; Gleam answers with
// a Result.
function found(value) {
  return value === null || value === undefined ? new Error(undefined) : new Ok(value);
}

// A component's `after_paint` effect is handed its shadow root. It answers
// the calls below as an element does.
export function as_element(root) {
  return root;
}

export function host(root) {
  return root.host;
}

export function same(a, b) {
  return a === b;
}

export function is_connected(element) {
  return element.isConnected;
}

export function first_element_child(element) {
  return found(element.firstElementChild);
}

export function children(element) {
  return toList(Array.from(element.children));
}

export function closest(element, selector) {
  return found(element.closest(selector));
}

export function query_selector(root, selector) {
  return found(root.querySelector(selector));
}

export function query_selector_all(root, selector) {
  return toList(Array.from(root.querySelectorAll(selector)));
}

export function dataset_get(element, key) {
  return found(element.dataset[key]);
}

export function text_content(element) {
  return element.textContent;
}

export function scroll_top(element) {
  return element.scrollTop;
}

export function set_scroll_top(element, top) {
  element.scrollTop = top;
}

export function scroll_by(element, dy) {
  element.scrollBy(0, dy);
}

export function scroll_height(element) {
  return element.scrollHeight;
}

export function client_height(element) {
  return element.clientHeight;
}

export function offset_top(element) {
  return element.offsetTop;
}

export function offset_height(element) {
  return element.offsetHeight;
}

export function bounding_top(element) {
  return element.getBoundingClientRect().top;
}

// The handler is returned so that `remove_listener` can name it.
export function add_passive_listener(element, event, handler) {
  element.addEventListener(event, handler, { passive: true });
  return handler;
}

export function remove_listener(element, event, handler) {
  element.removeEventListener(event, handler);
}

export function resize_observer(callback) {
  return new ResizeObserver(callback);
}

export function observe(observer, element) {
  observer.observe(element);
}

export function mutation_observer(callback) {
  return new MutationObserver(callback);
}

export function observe_child_list(observer, element) {
  observer.observe(element, { childList: true });
}

export function disconnect(observer) {
  observer.disconnect();
}

export function value(element) {
  return element.value;
}

export function set_value(element, text) {
  element.value = text;
}

export function utf16_length(text) {
  return text.length;
}

export function set_selection_range(element, start, end) {
  element.setSelectionRange(start, end);
}

export function focus(element) {
  element.focus();
}

export function request_submit(form) {
  form.requestSubmit();
}

export function request_submit_with(form, submitter) {
  form.requestSubmit(submitter);
}

export function now() {
  return Date.now();
}

export function set_interval(interval, callback) {
  return setInterval(callback, interval);
}

export function clear_interval(timer) {
  clearInterval(timer);
}

export function click(element) {
  element.click();
}

export function get_document() {
  return document;
}

// The handler is returned so that `remove_listener` can name it. Unlike
// `add_passive_listener` it may cancel the event, and it is called with the
// event.
export function add_listener(element, event, handler) {
  element.addEventListener(event, handler);
  return handler;
}

export function composed_path(event) {
  return toList(event.composedPath());
}

// The path can hold the window, the document and shadow roots, which are not
// elements: each of these answers an `Error` for one of them.
export function tag_name(node) {
  return found(node.localName);
}

export function attribute(node, name) {
  return found(node.getAttribute?.(name));
}

export function is_content_editable(node) {
  return found(node.isContentEditable);
}

export function prevent_default(event) {
  event.preventDefault();
}

// The browser's per-origin storage, one item at a time. Storage throws when
// it is blocked and in some private windows, and even reading the property
// can throw, so each call answers a Result and never lets the exception out.
// A missing item and a blocked storage are the same `Error`: what the caller
// does about either is Gleam's (`web_client/layout_rule`).
export function storage_read(key) {
  try {
    return found(window.localStorage.getItem(key));
  } catch (_) {
    return new Error(undefined);
  }
}

export function storage_write(key, value) {
  try {
    window.localStorage.setItem(key, value);
    return new Ok(undefined);
  } catch (_) {
    return new Error(undefined);
  }
}

export function document_element() {
  return document.documentElement;
}

export function set_attribute(element, name, value) {
  element.setAttribute(name, value);
}

export function remove_attribute(element, name) {
  element.removeAttribute(name);
}
