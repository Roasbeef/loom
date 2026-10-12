// Browser glue for the Loom site.
//
// Gleam's standard library has no bindings for the DOM, timers, `fetch`, the
// clipboard or scroll positions, and the site needs a few small things from
// them: the URL hash, a delayed callback, a text fetch, scrolling, a copy to
// the clipboard, and two scroll-position spies, one for the explainer figures
// and one for the sections of the landing page. Everything else is Lustre
// and Gleam. This is the only JavaScript in the site.

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

// Scrolls to a section of the page the reader is already on, smoothly unless
// the system asks for less motion. The spies stay quiet while it moves, so
// the sidebar does not flicker through every section on the way.
export function jump_to_id(id) {
  const element = document.getElementById(id);
  if (!element) return;
  const smooth = !prefers_reduced_motion();
  suppressedUntil = Date.now() + (smooth ? 900 : 120);
  element.scrollIntoView({ block: "start", behavior: smooth ? "smooth" : "auto" });
}

export function scroll_to_top() {
  window.scrollTo(0, 0);
}

// SCROLL SPIES ----------------------------------------------------------------
//
// A figure on the landing page is a column of step blocks beside a sticky
// panel. The figure spy reads, on every animation frame in which the page
// scrolled, which block is nearest to a "reading line", and tells Gleam when
// that changes. The line sits near the middle of the viewport.
//
// On a phone (760px or narrower) the blocks are not laid out side by side:
// only the current step's text is shown, below the panel, and the reader
// moves with the buttons. The figure spy does nothing there.
//
// Programmatic scrolls (a click on Next, a jump from the sidebar) set
// `suppressedUntil`, so the blocks that pass under the line during a smooth
// scroll do not flip a figure through every step on the way.

let suppressedUntil = 0;
const lastReported = new Map();

function phone() {
  return window.matchMedia("(max-width: 760px)").matches;
}

function readingLine() {
  return window.innerHeight * 0.46;
}

function spyFigures(callback) {
  if (Date.now() < suppressedUntil || phone()) return;
  document.querySelectorAll("[data-fig]").forEach((container) => {
    const rect = container.getBoundingClientRect();
    const line = readingLine();
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

// The section spy reports the last section whose top has passed a probe just
// below the sticky header, and the last section when the page is scrolled
// to its end, because a short last section may never reach the probe.
let sectionIds = [];
let lastSection = null;

function spySections(callback) {
  if (Date.now() < suppressedUntil) return;
  const probe = window.innerHeight * 0.28;
  let current = "";
  for (const id of sectionIds) {
    const element = document.getElementById(id);
    if (element && element.getBoundingClientRect().top <= probe) current = id;
  }
  const atEnd =
    window.innerHeight + window.scrollY >= document.documentElement.scrollHeight - 4;
  if (atEnd && sectionIds.length > 0 && window.scrollY > 0) {
    current = sectionIds[sectionIds.length - 1];
  }
  if (current !== lastSection) {
    lastSection = current;
    callback(current);
  }
}

export function start_scroll_spy(ids, on_step, on_section) {
  sectionIds = ids.toArray();
  let queued = false;
  const schedule = () => {
    if (queued) return;
    queued = true;
    window.requestAnimationFrame(() => {
      queued = false;
      spyFigures(on_step);
      spySections(on_section);
    });
  };
  window.addEventListener("scroll", schedule, { passive: true });
  window.addEventListener("resize", schedule);
  // The page is built after this runs, so look again once it exists.
  window.setTimeout(schedule, 300);
}

// Tells the spy what Gleam believes, so that a step chosen with a button is
// not reported again as a change.
export function note_step(id, step) {
  lastReported.set(id, step);
}

// Brings the block for `step` under the reading line, when the figure is on
// screen and its blocks are laid out. Does nothing for a figure the reader
// has scrolled away from, or on a phone.
export function reveal_step(id, step) {
  const container = document.querySelector(`[data-fig="${id}"]`);
  if (!container || phone()) return;
  const rect = container.getBoundingClientRect();
  if (rect.bottom < 0 || rect.top > window.innerHeight) return;
  const block = container.querySelector(`[data-step="${step}"]`);
  if (!block) return;
  const box = block.getBoundingClientRect();
  const delta = (box.top + box.bottom) / 2 - readingLine();
  if (Math.abs(delta) < 24) return;
  const smooth = !prefers_reduced_motion();
  suppressedUntil = Date.now() + (smooth ? 900 : 120);
  window.scrollBy({ top: delta, behavior: smooth ? "smooth" : "auto" });
}

// Scrolls a figure into view at a step, from a link elsewhere on the page.
// On a wide screen that is the step's text under the reading line, which the
// figure spy then agrees with. On a phone it is the figure's panel.
export function show_step(id, step) {
  window.requestAnimationFrame(() => {
    const container = document.querySelector(`[data-fig="${id}"]`);
    if (!container) return;
    lastReported.set(id, step);
    const smooth = !prefers_reduced_motion();
    suppressedUntil = Date.now() + (smooth ? 1200 : 120);
    const behavior = smooth ? "smooth" : "auto";
    const block = container.querySelector(`[data-step="${step}"]`);
    if (!phone() && block && block.offsetHeight > 0) {
      const box = block.getBoundingClientRect();
      const delta = (box.top + box.bottom) / 2 - readingLine();
      window.scrollBy({ top: delta, behavior });
    } else {
      const panel = container.querySelector("[data-fig-panel]") || container;
      panel.scrollIntoView({ block: "start", behavior });
    }
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
