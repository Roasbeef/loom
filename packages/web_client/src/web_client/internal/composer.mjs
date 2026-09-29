// The composer's editor and form, behind `web_client/internal/ffi_composer`.
// See that module for why these are JavaScript: no Gleam library reaches the
// DOM, and a client component's effects are handed only its shadow root.

// The editor the server drew inside this element. The server keys the
// editor's container by how many drafts have left it, so the element and its
// textarea are replaced together and never outlive one another.
function editor(root) {
  return root.host.querySelector("textarea");
}

// Puts `text` in the editor as the whole draft, with the caret after it, and
// gives it focus, since the operator has just chosen it from a list beside
// it. A programmatic write fires no `input` event, which is right: the
// component records the text itself when it writes it.
export function place(root, text) {
  const area = editor(root);
  if (area === null) return;
  area.value = text;
  area.setSelectionRange(text.length, text.length);
  area.focus();
}

// Submits the composer's form as a press of its first submit button does:
// the button is Send while the strand is idle and Queue while it is busy, and
// the submit that results carries the button's delivery. `requestSubmit`,
// unlike `submit`, runs the form's own submit listeners, which is where the
// server component's handler is, and it is the same event that button
// raises, so the server sees nothing new.
export function send(root) {
  const form = root.host.closest("form");
  if (form === null) return;
  const button = form.querySelector('button[type="submit"]');
  if (button === null) {
    form.requestSubmit();
  } else {
    form.requestSubmit(button);
  }
}

// Brings the prompts the daemon handed back into the editor. The server draws
// each as a child of this element in the slot named `returned`, which this
// element's shadow root has no slot for, so none is displayed there; each is
// read here as text, numbered by its `data-n`. An editor with nothing in it
// takes the text as its draft. One the operator has typed in keeps that and
// takes the return below it after a blank line, as the terminal does: both are
// theirs, and neither may be lost.
//
// Every number is taken once. Numbers up to `baseline` belonged to an editor
// before this one, and `restored` on the element remembers the highest taken,
// so a second call made before the first frame painted finds nothing new.
export function restore(root, baseline) {
  const area = editor(root);
  if (area === null) return;
  const host = root.host;
  let done = Math.max(host.restored ?? 0, baseline);
  for (const held of host.querySelectorAll('[slot="returned"]')) {
    const n = Number(held.dataset.n);
    if (!(n > done)) continue;
    const text = held.textContent;
    area.value = area.value.trim() === "" ? text : area.value + "\n\n" + text;
    done = n;
  }
  host.restored = done;
}

// Scrolls the completion list, and only the list, so the highlighted row is
// inside it. The list is positioned, so a row's offset is from the list's
// top edge. The page is left where it is, which `scrollIntoView` would not
// promise.
export function reveal(root) {
  const list = root.querySelector('[role="listbox"]');
  const row = root.querySelector('[aria-selected="true"]');
  if (list === null || row === null) return;
  const bottom = row.offsetTop + row.offsetHeight;
  if (row.offsetTop < list.scrollTop) {
    list.scrollTop = row.offsetTop;
  } else if (bottom > list.scrollTop + list.clientHeight) {
    list.scrollTop = bottom - list.clientHeight;
  }
}
