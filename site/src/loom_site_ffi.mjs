// Browser glue for the Loom site.
//
// Gleam's standard library has no bindings for the DOM, timers, `fetch` or
// the History API, and the site needs five small things from them: the URL
// hash, a delayed callback, a text fetch, scrolling, and a scroll-position
// spy for the explainer figures. Everything else is Lustre and Gleam.

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

// SCROLLING -------------------------------------------------------------------

// Scrolls the document so that the element with this id is under the header.
// Called after a render, so it waits one frame for the new DOM to exist.
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

// SCROLL SPY ------------------------------------------------------------------
//
// A figure on the landing page is a column of step blocks beside a sticky
// panel. The spy reads, on every animation frame in which the page scrolled,
// which block is nearest to a "reading line", and tells Gleam when that
// changes. The line sits below the sticky panel on a phone and near the
// middle of the viewport otherwise.
//
// Programmatic scrolls (a click on Next) set `suppressedUntil`, so the blocks
// that pass under the line during a smooth scroll do not flip the figure
// through every step on the way.

let suppressedUntil = 0;
const lastReported = new Map();

function narrow() {
  return window.matchMedia("(max-width: 900px)").matches;
}

function readingLine(container) {
  if (narrow()) {
    const panel = container.querySelector("[data-fig-panel]");
    const bottom = panel ? panel.getBoundingClientRect().bottom : 0;
    return bottom + (window.innerHeight - bottom) * 0.3;
  }
  return window.innerHeight * 0.46;
}

function spyOnce(callback) {
  if (Date.now() < suppressedUntil) return;
  document.querySelectorAll("[data-fig]").forEach((container) => {
    const rect = container.getBoundingClientRect();
    const line = readingLine(container);
    if (rect.top > line || rect.bottom < line) return;
    let best = -1;
    let bestDistance = Infinity;
    container.querySelectorAll("[data-step]").forEach((block) => {
      const box = block.getBoundingClientRect();
      const distance = Math.abs((box.top + box.bottom) / 2 - line);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = Number(block.getAttribute("data-step"));
      }
    });
    const id = container.getAttribute("data-fig");
    if (best >= 0 && lastReported.get(id) !== best) {
      lastReported.set(id, best);
      callback(id, best);
    }
  });
}

export function start_scroll_spy(callback) {
  let queued = false;
  const schedule = () => {
    if (queued) return;
    queued = true;
    window.requestAnimationFrame(() => {
      queued = false;
      spyOnce(callback);
    });
  };
  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", schedule);
}

// Tells the spy what Gleam believes, so that a step chosen with a button is
// not reported again as a change.
export function note_step(id, step) {
  lastReported.set(id, step);
}

// Brings the block for `step` under the reading line, when the figure is on
// screen. Does nothing for a figure the reader has scrolled away from.
export function reveal_step(id, step) {
  const container = document.querySelector(`[data-fig="${id}"]`);
  if (!container) return;
  const rect = container.getBoundingClientRect();
  if (rect.bottom < 0 || rect.top > window.innerHeight) return;
  const block = container.querySelector(`[data-step="${step}"]`);
  if (!block) return;
  const line = readingLine(container);
  const box = block.getBoundingClientRect();
  const delta = (box.top + box.bottom) / 2 - line;
  if (Math.abs(delta) < 24) return;
  const smooth = !prefers_reduced_motion();
  suppressedUntil = Date.now() + (smooth ? 900 : 120);
  window.scrollBy({ top: delta, behavior: smooth ? "smooth" : "auto" });
}
