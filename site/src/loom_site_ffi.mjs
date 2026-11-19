// Browser glue for the Loom site.
//
// Gleam's standard library has no bindings for the DOM, timers, `fetch`, the
// clipboard or scroll positions, and the site needs a few small things from
// them: the URL hash, a delayed callback, a text fetch, scrolling, a copy to
// the clipboard, and an observer that starts the replay. Everything else is
// Lustre and Gleam. This is the only JavaScript in the site.

import { Ok, Error as GleamError } from "./gleam.mjs";

// ROUTING ---------------------------------------------------------------------

export function get_hash() {
  return window.location.hash || "";
}

export function set_hash(hash) {
  if (window.location.hash !== hash) {
    window.location.hash = hash;
  }
}

export function on_hash_change(callback) {
  window.addEventListener("hashchange", () => callback(get_hash()));
}

export function set_title(title) {
  document.title = title;
}

// TIMERS AND FETCH ------------------------------------------------------------

export function after(milliseconds, callback) {
  window.setTimeout(callback, milliseconds);
}

export function fetch_text(url, callback) {
  fetch(url)
    .then((response) => {
      if (!response.ok) throw new globalThis.Error(String(response.status));
      return response.text();
    })
    .then((text) => callback(new Ok(text)))
    .catch(() => callback(new GleamError(undefined)));
}

export function prefers_reduced_motion() {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

// CLIPBOARD -------------------------------------------------------------------

// Copies text and calls back only if the copy worked. The asynchronous
// clipboard API needs a secure context, which GitHub Pages and localhost are.
// A page opened some other way falls back to a selected, offscreen textarea.
export function copy_text(text, on_done) {
  const fallback = () => {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.top = "-1000px";
    document.body.appendChild(area);
    area.select();
    let worked = false;
    try {
      worked = document.execCommand("copy");
    } catch (_) {
      worked = false;
    }
    document.body.removeChild(area);
    if (worked) on_done();
  };
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).then(on_done, fallback);
  } else {
    fallback();
  }
}

// SCROLLING -------------------------------------------------------------------

// Scrolls the document so that the element with this id is under the header.
// Called after a render, so it waits two frames for the new DOM to exist.
export function scroll_to_id(id) {
  window.requestAnimationFrame(() => {
    window.requestAnimationFrame(() => {
      const element = document.getElementById(id);
      if (element) {
        element.scrollIntoView({ block: "start" });
      } else {
        window.scrollTo(0, 0);
      }
    });
  });
}

export function scroll_to_top() {
  window.scrollTo(0, 0);
}

// Scrolls a figure's panel into view, from a link elsewhere on the page.
// Gleam has already set the step, so this only moves the page. It waits a
// frame so the panel it scrolls to is the one drawn at that step, and it
// centres the panel because its caption and controls sit under the drawing.
export function show_figure(id) {
  window.requestAnimationFrame(() => {
    const container = document.querySelector(`[data-fig="${id}"]`);
    if (!container) return;
    const behavior = prefers_reduced_motion() ? "auto" : "smooth";
    container.scrollIntoView({ block: "center", behavior });
  });
}

// OBSERVING -------------------------------------------------------------------

// Calls back once, the first time at least `fraction` of the element with
// this id is on screen. The element may not exist yet, because the page is
// built after the route changes, so this looks for it a few times.
export function observe_once(id, fraction, callback) {
  let tries = 0;
  const start = () => {
    const element = document.getElementById(id);
    if (!element) {
      tries += 1;
      if (tries < 20) window.setTimeout(start, 100);
      return;
    }
    if (!("IntersectionObserver" in window)) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          observer.disconnect();
          callback();
        }
      },
      { threshold: fraction },
    );
    observer.observe(element);
  };
  start();
}
