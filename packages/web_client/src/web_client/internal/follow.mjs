// The page's scroll position and the lane's size, behind
// `web_client/internal/ffi_follow`. See that module for why these are
// JavaScript: no Gleam library observes an element's size or reads and
// moves the page's scroll position on this target.

// The page scrolls as a whole: the lane is in the document's flow, not in a
// scrolling box of its own.
function page() {
  return document.scrollingElement || document.documentElement;
}

// How far the bottom of the viewport is from the bottom of the page, in
// whole pixels.
function gap() {
  const scroller = page();
  const left = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight;
  return Math.max(0, Math.round(left));
}

// Starts watching: every scroll of the page reports the gap, and every change
// in the size of the element whose shadow root is `root` reports growth. The
// element is the `<loom-follow>` around the lane, so its size changes when a
// row lands, and not when the dock's editor grows.
export function watch(root, scrolled, resized) {
  const host = root.host || root;
  const onScroll = () => scrolled(gap());
  window.addEventListener("scroll", onScroll, { passive: true });
  const observer = new ResizeObserver(() => resized());
  observer.observe(host);
  return { onScroll, observer, host };
}

// Stops what `watch` started.
export function unwatch(watching) {
  window.removeEventListener("scroll", watching.onScroll);
  watching.observer.disconnect();
}

// Scrolls the page to its bottom at once. It is never animated: a smooth
// scroll reports its intermediate positions, and each would read as the
// reader leaving the tail.
export function to_bottom() {
  const scroller = page();
  scroller.scrollTop = scroller.scrollHeight;
}

// Holds the first row of the lane inside the watched `<loom-follow>`, and
// the viewport position of its top edge. The lane is the element's `.lane`
// child; nothing here reads a row's content.
export function hold(watching) {
  const lane = watching.host.querySelector(".lane");
  const row = lane ? lane.firstElementChild : null;
  return { lane, row, top: row ? row.getBoundingClientRect().top : 0 };
}

// The same row, measured again after the reader scrolled.
export function remeasure(anchor) {
  const top = anchor.row ? anchor.row.getBoundingClientRect().top : anchor.top;
  return { lane: anchor.lane, row: anchor.row, top };
}

// Returns false while the held row is still the lane's first, which means
// no older row has landed above it. Once one has, scrolls the page by how
// far the row moved, so it is back where it was, and returns true. It also
// returns true when the row has left the page, since there is nothing left
// to keep. A browser that anchors scrolling itself will already have kept
// the row in place, and the scroll is then zero.
export function restore(anchor) {
  const row = anchor.row;
  if (!row || !row.isConnected) return true;
  if (anchor.lane.firstElementChild === row) return false;
  const moved = row.getBoundingClientRect().top - anchor.top;
  if (moved !== 0) window.scrollBy(0, moved);
  return true;
}
