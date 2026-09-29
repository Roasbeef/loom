// The transcript's scroll position and size, behind
// `web_client/internal/ffi_follow`. See that module for why these are
// JavaScript: no Gleam library observes an element's size or reads and
// moves an element's scroll position on this target.

// The scroller is the `<loom-follow>` element itself, whose shadow root is
// `root`: the stylesheet gives it a fixed share of the viewport and lets its
// content scroll inside it, so the header, the agent strip and the dock never
// move with the transcript.
function scroller(root) {
  return root.host || root;
}

// How far the bottom of the scroller's view is from the bottom of its
// content, in whole pixels.
function gap(host) {
  const left = host.scrollHeight - host.scrollTop - host.clientHeight;
  return Math.max(0, Math.round(left));
}

// Starts watching. Every scroll of the transcript reports the gap and how
// far the scroll moved, in pixels, negative for a move up. Every change in
// the size of the scroller or of its content reports growth.
//
// The content is the scroller's children (the line above the oldest row
// and the lane), not the scroller: its own box has a fixed height, so it
// does not change when a row lands. The children are observed as they are
// added, since the scroller can be connected before the server's rows are
// in it.
export function watch(root, scrolled, resized) {
  const host = scroller(root);
  let last = host.scrollTop;
  const onScroll = () => {
    const top = host.scrollTop;
    const moved = top - last;
    last = top;
    scrolled(gap(host), Math.round(moved));
  };
  host.addEventListener("scroll", onScroll, { passive: true });
  const observer = new ResizeObserver(() => resized());
  observer.observe(host);
  const observeChildren = () => {
    for (const child of host.children) observer.observe(child);
  };
  observeChildren();
  const children = new MutationObserver(observeChildren);
  children.observe(host, { childList: true });
  return { onScroll, observer, children, host };
}

// Stops what `watch` started.
export function unwatch(watching) {
  watching.host.removeEventListener("scroll", watching.onScroll);
  watching.observer.disconnect();
  watching.children.disconnect();
}

// The gap now, for a caller that wants it without a scroll.
export function measure(watching) {
  return gap(watching.host);
}

// Scrolls the transcript to its bottom at once. It is never animated: a
// smooth scroll reports its intermediate positions, and each would be a
// move for `<loom-follow>` to read.
export function to_bottom(watching) {
  watching.host.scrollTop = watching.host.scrollHeight;
}

// Holds the first row of the lane inside the watched scroller, and the
// viewport position of its top edge. The lane is the element's `.lane`
// child; nothing here reads a row's content.
export function hold(watching) {
  const host = watching.host;
  const lane = host.querySelector(".lane");
  const row = lane ? lane.firstElementChild : null;
  return { host, lane, row, top: row ? row.getBoundingClientRect().top : 0 };
}

// The same row, measured again after the reader scrolled.
export function remeasure(anchor) {
  const top = anchor.row ? anchor.row.getBoundingClientRect().top : anchor.top;
  return { host: anchor.host, lane: anchor.lane, row: anchor.row, top };
}

// Returns false while the held row is still the lane's first, which means
// no older row has landed above it. Once one has, scrolls the transcript by
// how far the row moved, so it is back where it was, and returns true. It
// also returns true when the row has left the page, since there is nothing
// left to keep. The stylesheet turns the browser's own scroll anchoring off
// for the scroller, so this is the one place the reader's place is kept.
export function restore(anchor) {
  const row = anchor.row;
  if (!row || !row.isConnected) return true;
  if (anchor.lane.firstElementChild === row) return false;
  const moved = row.getBoundingClientRect().top - anchor.top;
  if (moved !== 0) anchor.host.scrollBy(0, moved);
  return true;
}
