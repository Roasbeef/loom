// The browser clock and timer behind `web_client/internal/ffi_clock`. See
// that module for why these are JavaScript: no Gleam library offers a clock
// or a timer on this target.

// Date.now is the one wall clock a page has, on the scale the daemon states
// an operation's start in.
export function now() {
  return Date.now();
}

// setInterval, handing back its handle so the element can stop it when it
// leaves the page.
export function every(interval, callback) {
  return setInterval(() => callback(), interval);
}

// clearInterval for a handle `every` returned.
export function cancel(timer) {
  clearInterval(timer);
}
