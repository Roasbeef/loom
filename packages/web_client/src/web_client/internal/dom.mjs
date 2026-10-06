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

// The root the element is attached under: the document, or the shadow root of
// the server component that holds it.
export function root_node(element) {
  return element.getRootNode();
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

// Brings the element into view by the least scrolling that shows all of it, at
// once, so a box that is already on screen does not move.
export function scroll_into_view(element) {
  element.scrollIntoView({ block: "nearest", behavior: "instant" });
}

// The browser's offset from UTC at an instant, in minutes, positive west of
// Greenwich (`getTimezoneOffset`). It is the one thing about a zone Gleam
// cannot read, and the arithmetic over it is `web_client/time_rule`.
export function timezone_offset_minutes(milliseconds) {
  return new Date(milliseconds).getTimezoneOffset();
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

// The button that submitted a form (`SubmitEvent.submitter`), or `Error`
// for a submit raised with none.
export function submitter(event) {
  return found(event.submitter);
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

// The files of a `FileList`, as the change event of a file input holds them.
export function file_list(files) {
  return toList(Array.from(files));
}

// The files an event's clipboard holds: none for an event with no clipboard,
// as a `paste` in a browser that withholds it is.
export function clipboard_files(event) {
  return toList(Array.from(event.clipboardData?.files ?? []));
}

// The kinds of data a drag event carries (`dataTransfer.types`): "Files" for a
// drag of files, and media types for anything else. None for an event with no
// data transfer.
export function drag_types(event) {
  return toList(Array.from(event.dataTransfer?.types ?? []));
}

// The files a `drop` event carries (`dataTransfer.files`), or none.
export function drag_files(event) {
  return toList(Array.from(event.dataTransfer?.files ?? []));
}

// The element a drag event is moving to or from (`relatedTarget`), or nothing
// when the pointer left the window or the browser withholds it.
export function related_target(event) {
  return found(event.relatedTarget);
}

// Whether a node is the element or inside it (`Node.contains`).
export function contains(element, node) {
  return element.contains(node);
}

export function file_name(file) {
  return file.name;
}

export function file_type(file) {
  return file.type;
}

export function file_size(file) {
  return file.size;
}

// One read of a file as a `data:` URL, which answers `done` once with the URL
// or with an `Error`. The URL is text the browser made from the file's bytes;
// nothing here is put in the page.
export function read_data_url(file, done) {
  const reader = new FileReader();
  reader.onload = () => done(new Ok(reader.result));
  reader.onerror = () => done(new Error(undefined));
  reader.readAsDataURL(file);
}

// One navigation that adds a history entry, so Back returns to the page it
// left. The address was checked in Gleam before it got here.
export function assign_location(address) {
  window.location.assign(address);
}

// One step back in the tab's history. It takes no address, so it can reach no
// page the tab has not already visited.
export function history_back() {
  window.history.back();
}

// A timer that calls `done` once after `milliseconds`.
export function after(milliseconds, done) {
  window.setTimeout(done, milliseconds);
}

// One clipboard write, with the outcome handed to `done` as a Result. The
// browser answers after the fact, and the call throws at once when the API is
// missing or the page is not a secure context, so both outcomes are reported
// the same way and no exception leaves. The text was checked in Gleam
// (`web_client/copy_rule`) before it got here.
export function write_clipboard(text, done) {
  try {
    navigator.clipboard.writeText(text).then(
      () => done(new Ok(undefined)),
      () => done(new Error(undefined)),
    );
  } catch (_) {
    done(new Error(undefined));
  }
}

export function media_query(query) {
  return window.matchMedia(query);
}

export function media_matches(query) {
  return query.matches;
}

// Writes the document's title as text. Assigning `document.title` never parses
// markup, so a name that holds angle brackets is shown as those characters.
export function set_title(text) {
  document.title = text;
}

// Has the observer watch the text under an element, to any depth, change or
// come and go.
export function observe_text(observer, element) {
  observer.observe(element, {
    childList: true,
    characterData: true,
    subtree: true,
  });
}

// Has the observer watch one attribute of an element and nothing else.
export function observe_attribute(observer, element, name) {
  observer.observe(element, { attributes: true, attributeFilter: [name] });
}
