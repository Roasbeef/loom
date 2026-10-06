# web_client

## Purpose

The browser half of the web view: Lustre client components, written in
Gleam and compiled to JavaScript, registered as custom elements that the
server component (`packages/web_view`) renders like any other tag. The
server component holds every piece of session state and is the only thing
that talks to the session (protocol-change/051); this package holds only
behaviour that changes with nothing the server knows, so the server never
renders again just for it:

- `<loom-elapsed offset="<ms>">` counts an operation's elapsed time once a
  second, on from a duration the server measured. With `remaining="<ms>"` it
  counts the time left down instead (`duration.remaining`: whole minutes rounded
  up, then seconds), which the admin page's `ends in 14m` pill uses; whichever
  attribute arrived last sets the direction.
- `<loom-switcher>` is the session switcher Command or Control and K opens
  (`switcher_rule`: the shortcut, the filter and its order, the highlight). It
  reads the sidebar's `.sidebar .session-open` buttons from the page's root
  (`ffi_dom.root_node`) as text, lists them in a popover it draws in its own
  shadow root, and presses the chosen row's own sidebar button, so the daemon
  mints the ticket and `<loom-switch>` navigates. It also reads the bar's
  `.session-head .home-link` and `.home-admin` buttons and lists them first, as
  `Place` rows (`Home`, `Admin`). One document listener for `keydown` and
  `click`, removed with the element: a click whose composed path holds an
  element marked `data-opens="switcher"` (`switcher_rule.summons`) opens it, which
  is how the `Search ⌘K` chip `<loom-shell>` draws in the bar (`shell_rule.has_search`,
  on pages with a sidebar) reaches it across a shadow tree. Every name is a text
  node of its own view. It sends the server nothing (protocol-change/051, the
  addendum on the session switcher).
- `<loom-title>` (`title_rule`) is a hidden, attribute-free element
  `view/heading` draws as the session bar's last child. It reads the bar's `h1`
  text and the frame's `needing` attribute and sets `document.title` to
  `name — Loom`, or `(N) name — Loom` while N strands wait, through a mutation
  observer on both (`ffi_dom.observe_text`, `observe_attribute`, `set_title`). The
  server's document says only `Loom` until then, never the identity.
- `<loom-fold>` opens and closes a turn's folded work with no round trip.
- `<loom-expand>` is a row of a turn's fold: one line with one chevron, and a
  body behind it. The server draws the line and the body as children
  (`slot="head"` and `slot="body"`); the element holds one button around the
  head and the body slot while the row is open, with no round trip. A
  reasoning row carries `kind="live"` while the block streams and
  `kind="settled"` once it has settled: an open live row leaves
  `data-reasoning-open-until` on the document element (a deadline, never
  reached while the row is on the page and `handoff_window_ms` after it leaves)
  and the settled row that connects takes it and opens (`expand_rule.takes`),
  so a reader who opened the reasoning keeps it open when it settles. Only a
  row the server marked `handoff="yes"` (the lane's newest settled reasoning
  row) takes it; an older row mounted by Load older never does. Known edge: the
  note names no block, so a page switch within `handoff_window_ms` of an open
  live row leaving can hand its state to the first marked row of the next page.
- `<loom-follow>` is the transcript's scroll container: the page's frame is
  pinned and only it scrolls. It scrolls itself to a row that lands below
  its view while the reader is at the bottom; once the reader scrolls up it
  stops and shows a "Jump to latest" button once it is more than
  `follow_rule.jump_gap` (96px, a row and the button) from the bottom, so the
  button never covers the row the reader is about to read, and scrolling back
  to the bottom or pressing the button resumes it. When the reader presses the lane's
  "Load older" button, it keeps the row they were looking at in place while
  the older rows arrive above it.
- `<loom-composer commands="<json>" returned="<n>" refused="<n>">` wraps the
  operator's editor, the server's uncontrolled textarea, which is its default
  slot. It lists the slash commands as the draft grows, sends the draft on

  the older rows arrive above it. The server draws `data-strand-key`, a
  small number the page assigned to the strand on screen (`Marks.key`, never the name),
  on it; when the key changes the element saves the departing strand's place
  in memory (`follow_rule.leaving`: an offset, or at the bottom) and restores
  the arriving strand's (`follow_rule.arriving`), following the tail for a
  strand left at the bottom or never seen. Nothing is stored outside the
  element.
- `<loom-composer commands="<json>" returned="<n>">` wraps the operator's
  editor, the server's uncontrolled textarea, which is its default slot.
  It lists the slash commands as the draft grows, sends the draft on
  Command or Control with Enter, and puts a prompt the daemon handed back
  into the editor. These react to text that only the browser has until the
  form is submitted, which is why they are here. It also disables the form's
  submit buttons while the editor is empty and holds no image
  (`composer_rule.gate`, `Open | Shut`); `<loom-attach>` reports images in the
  composer's `attached` attribute (`yes | no`), because an image alone is a
  message the daemon accepts. It also shows a pressed message at once: on
  the form's `submit` it draws the draft as a pending line above the editor
  in its own shadow root, marked `sending`, or `queued` for the Queue
  button (`pending_rule`), and clears the editor after the paint. The line
  is the person's own text as a text node and never a row of the lane. It
  leaves when the server takes the draft, which replaces the element (the
  server keys the editor by the drafts sent), or when the server refuses,
  which the `refused` attribute says: it counts the submits refused with the
  draft kept (`component.refusals`, the page's own refusals and the lane's
  admission check), and a count that rises while a line is shown puts the
  text back in the editor; a notice that is not a refusal, the lane holding
  a send until a read answers, leaves the line until the send. No nonce
  travels with the submit, so a message held by the daemon (a Steer folded
  in at the next boundary, a Queue run after the turn) is shown only until
  the server accepts it.
- `<loom-attach name="images" limits="<json>">` is the operator composer's
  image attachments (protocol-change/051, the addendum on images): an Attach
  image button for the file picker, a paste into the composer's form, a chip
  with a Remove button per image, and a notice for a refused file. It is
  form-associated, so it submits its images under `name` as one field, a JSON
  array of base64 strings, in the same `submit` event as the draft, and nothing
  when it holds none. `limits` is the daemon's count, byte total and media types
  (`web_view/image.limits_attribute`); one that does not decode allows nothing.
  `attach_rule` decides what it accepts before a file is read: declared type,
  size, count, with reads in flight counting; the daemon reads the real type
  from the bytes. A paste holding image files attaches them and is cancelled,
  and its listener on the form is removed when the element leaves. Image files
  dragged onto the composer's form are attached through the same vetting
  (`attach_rule.choose`); the form's `dragenter`, `dragover`, `dragleave` and
  `drop` listeners cancel a drag only when it carries files, and while one is
  over the form with a place free the element draws a tinted `.attach-drop`
  overlay with a hint (`drop_rule`: `carries_files`, the `Drag` state, which a leave ends only by its `relatedTarget`, so
  absorbs child enter/leave, `surface`). `drop_guard` is no element: one
  document listener installed in `main` that cancels any file drag, so a file
  dropped elsewhere, or on a page with no composer, never navigates the tab. The
  chips are the person's own file names as text nodes, and the element draws no
  image.
- `<loom-rename>` wraps the rename form's text field (the home row's form and
  the Session pane's). The server cannot give the field a `value`, because a
  session's name is only ever a text node (protocol-change/051), so when the
  element connects it reads the text of the `[data-loom-name]` element inside the
  nearest `[data-loom-renames]` container and writes it into the field, if the
  field is empty (`rename_rule.copy`, cut to the field's 256 characters), then
  focuses it. It takes no attribute, draws only the default slot and sends the
  server nothing.
- `<loom-switch to="/ui/sessions/<id>?ticket=<t>">` moves the browser to
  another session's page, as `to="/ui/home?ticket=<t>"` to the home, or, as
  `to="/ui/admin?ticket=<t>"`, from the owner's home to the admin page
  (protocol-change/065, the fifth addendum). The
  operator's page draws it hidden (an observer's page too, when it was opened
  from a home), and so does the home, and each writes `to`
  once the daemon has minted a ticket; `switch_rule.target` accepts exactly
  those three address shapes and nothing else, and the element then calls
  `location.assign` (one export in `dom.mjs`), so each keyed page is a history
  entry and Back returns to it with its own nonce (051, the addendum on
  navigation). `<loom-back>Home</loom-back>` calls `history.back()` and mints
  nothing (the admin bar's trailing child, and the spent-ticket document's
  Go back); `<loom-waiting>` wraps the shell's waiting paragraph and after five
  seconds draws the ended document's shape. It renders nothing, takes no
  focus and listens for no event (protocol-change/051, the addendum on
  switching sessions).
- `<loom-link>` makes a Markdown link clickable. The server draws it with two text
  children, the label in `<span class="ll-text">` and the destination in
  `<span class="ll-url" hidden>`, and no attribute carries either. The element
  reads the `ll-url` text and `link_rule.destination` accepts it only as a plain
  absolute `http` or `https` address (any scheme case; no whitespace, control
  character or backslash; a non-empty authority with no `@`; at most 2048
  characters), a text check on purpose because the `URL` constructor forgives what
  a hostile address uses. An accepted address is drawn in the shadow root as
  `<a href target="_blank" rel="noopener noreferrer" title="<address>">` around the
  default slot, plus a `↗` glyph, so focus, Enter, middle click and copy-link-address
  are the browser's and the new tab has no opener. That `href` and `title` are the
  one attribute built from session-derived text, set in the browser from the
  validated value (protocol-change/051, the addendum on clickable links). A refused
  address draws the slot and, unless it is empty or repeats the label
  (`link_rule.hint`), the address as quiet text in parentheses, with no anchor. The
  rule also refuses bidi isolates and other invisible characters. A mutation observer on
  the element's own children re-reads after a patch; it sends the server nothing.
- `<loom-time at="<ms>">` draws an instant as the time of day in the browser's own
  zone (`time_rule.clock`: round up to the minute, then the browser's UTC offset
  from `ffi_dom.timezone_offset_minutes`). The admin page's grant refusal uses it
  for when the next place frees; the server writes the UTC time as its `title` and
  light text, so the zone is the browser's and never a server guess.
- `<loom-reveal>` is an empty element that, when connected, calls
  `scrollIntoView({block: "nearest"})` on its nearest `section` after the first
  paint. The admin claim box opens with one, so a claim made below the fold is on
  screen. It takes no attribute and sends the server nothing.
- `<loom-saved>` (`saved`, `saved_rule`) wraps the sidebar's "N saved" button
  (the light child, drawn through one slot). A press, which reaches the element's
  shadow tree through the slot, flips one fact (`saved_rule.State`, `Hidden |
  Shown`), publishes it as the custom state `shown` (the stylesheet shows the
  saved panel beside it, `loom-saved:state(shown) + .saved-panel`) and as the
  button's `aria-expanded`, and writes it to the browser's storage under
  `saved_rule.key` (`loom.sidebar.saved.v1`, one item for the origin: per viewer,
  the same on every page, through `ffi_dom.storage_read`/`storage_write`, which
  answer `Error` when the storage is blocked). When the element connects it reads
  the item once; anything but `shown` is `Hidden`. It takes no attribute, sends
  the server nothing and adds no socket admission.
- `<loom-popover wanted="open">` wraps the home's name button (the light child,
  drawn through one slot) and toggles the account panel in the browser: it keeps
  one fact, open or closed (`popover_rule.State`), publishes it as the custom
  state `open` on itself (the stylesheet shows the panel under
  `loom-shell:has(loom-popover:state(open))`) and as the button's
  `aria-expanded`. Document listeners for `click` and `keydown` read only the
  fixed `data-popover` marks (`toggle`, `panel`) of the nodes a click passed
  through (`popover_rule.after_click`): the toggle flips, the panel keeps, any
  other press and Escape close. The server's only input is `wanted="open"`, which
  opens it while a device link is on show; any other word is no message. It
  sends the server nothing and adds no socket admission.
- `<loom-copy subject="command|token|link|device|claim-address|bookmark" text="...">`
  (`bookmark` is a remembered login's home address, `http://`, a loopback host,
  `/ui/l/`, 32 lowercase hex digits and `/home`, and nothing else) (`device` is the
  home's device-link address, protocol-change/065, PR 8: `http://`, a loopback
  host, `/ui/home?ticket=` and 64 lowercase hex digits, and nothing else;
  `claim-address` is the browser claim address, `http://`, a loopback host and
  `/ui/claim` with nothing after it) draws one of an
  invitation's two texts, or the ended page's `loom ui` command for a fresh
  link (`link`, protocol-change/065, the addendum on the home list), in a
  `code` element in its shadow root, with a button
  that copies it to the clipboard (protocol-change/051, the addendum on
  inviting from the session page). `copy_rule.subject` decodes the fixed word
  and `copy_rule.text` accepts a value only if it is exactly what the daemon
  writes for that subject: `loom claim --addr ` and an address of address
  characters, or `loomclaim_` and 64 hexadecimal digits. Anything else, a
  newline included, draws nothing and offers no button. The copy runs in the
  press's own turn through `ffi_dom.write_clipboard` (one export in
  `dom.mjs`), and the outcome is drawn on the button in fixed words
  (`copy_rule.words`). It takes no key, no focus and sends the server nothing.
- `<loom-shell sidebar="listed" needing="0" workspace="<digest>">` is the
  page's frame. The server
  draws the top bar, the sessions sidebar, the centre and the strand panel as
  its children, in the slots `bar`, `left`, the default and `right`, and the
  element lays them out and draws a button at each end of the bar that hides
  and shows a side column. Which columns are open is the reader's preference
  and nothing the server holds, so the server never renders it. It is kept
  in the browser's storage, per workspace: on connect the element reads its
  `workspace` attribute, a SHA-256 digest of the workspace path that the
  daemon computed (`component.Start.workspace_digest`), and asks
  `layout_rule` for the stored layout (the two columns and the active tab,
  nothing else; the focused strand is never kept, so a reload shows `main`),
  and every change writes it back through `ffi_dom.storage_write`. A page
  with no digest keeps nothing. A Theme icon button in the bar (a sun, moon or half disc drawn from fixed shapes, labelled by `layout_rule.label`) cycles the page
  through following the system, light and dark (`layout_rule.next_theme`) by
  setting or removing `data-theme` on `<html>`, which the stylesheet reads;
  the choice is kept per browser under its own item, and `assets/web_view_page.js` applies it from that item before first paint, since the shell connects only after the socket opens (`js_check` pins the item name to `layout_rule.theme_key`). The server never learns
  the layout
  (protocol-change/051, the addendum on the storage decision). A hidden column takes no width and is `inert`, so
  its content leaves the tab order. The `sidebar` attribute is a fixed word
  the server writes (`listed` or `none`), so an observer's page, which has no
  sidebar, gets no button for one. The strand panel has four tabs, Strands,
  Changes, Trace and Session. The server draws a pane for each, all of them, as
  children of the panel; the element draws the tab bar above the `right` slot
  and shows the chosen tab's pane by setting a custom state on itself
  (`component.set_pseudo_state`, `tab-strands`, `tab-changes`,
  `tab-session` or `tab-trace`), which the stylesheet reads to hide the others
  (`loom-shell:state(tab-changes) .pane:not(.pane-changes)`). A hidden pane is
  `display: none`, so its controls leave the tab order too; a browser without
  custom states shows every pane, stacked. The `needing` attribute is a count
  the server writes, the number of strands waiting on a decision, which the
  Strands tab shows as a badge and names in its label; decoding is total.
  The shell also relays clicks. A server-drawn control that focuses a strand
  and has no handler (a dot or a tag in the transcript, the breadcrumb's `All
  strands`, a strand view's back link) carries `data-loom-focus` with the
  position of a strand card, and each card carries `data-loom-card` with its
  own. The element hears a `click` that reaches its centre slot or its panel
  slot, reads `dataset.loomFocus` from the click's own target, decodes it
  totally (`shell_rule.relay`), shows the panel on its Strands tab where the
  rule says (`shell_rule.relayed`; position zero, `main`, leaves the layout
  alone) and presses the card with `ffi_dom.click`. The press is an ordinary
  click on the card's ordinary handler, so the socket admits nothing new
  (protocol-change/051, the addendum on the marker relay).

A page that has ended or was refused needs no element here. The server draws
its notice (`web_view/view/ended`, `web_view/page.refusal`), and the shell's
own paragraph inside the component shows while nothing has mounted; this
package only styles them (`.ended-notice`, `.page-note` in `web_client.css`).
A tab that mounted and then lost its socket is the one case no element covers
yet (protocol-change/051, the addendum on an ended page).

It is the client package of Lustre's full-stack layout: `core` and
`session_view` are the shared code, `loomd` with `web_view` is the server,
and this is the client. Unlike the guide's single-page app it is a set of
client components inside a server component, because 051 keeps the session
on the BEAM (`docs/lustre.md`).

The package targets JavaScript only (`target = "javascript"`) and depends on
`lustre == 5.7.1`, `gleam_stdlib` and `gleam_json`. Its only JavaScript is
`src/web_client/internal/dom.mjs`, one DOM call or property read per export
with no logic, declared in `internal/ffi_dom.gleam`; every decision the
components make is Gleam over it (see `internal/ffi_dom` under Key Types).
`make gen-client` bundles it with
`lustre_dev_tools` (a dev dependency here and nowhere else) into
`packages/web_view/priv/static/web_client.mjs`, together with the page's
stylesheet, which Tailwind builds from `src/web_client.css`, and the two
page scripts and the tab icon (`favicon.svg`, the logo's mark, light and dark
by media query) in `assets/`. The daemon serves those files; nothing at run
time builds anything.

## Key Types

- `web_client.main()`: registers every element, once, when the page loads
  the bundle.
- `elapsed.Model(reading, now, timer)`, `elapsed.Reading(offset, anchor)`
  and `elapsed.Msg` (`OffsetChanged`, `Anchored`, `Connected`,
  `Disconnected`, `Started`, `Ticked`): `offset` is how long the operation
  had run, in milliseconds, by the server (`agent_roster.running_ms`), and
  is the only attribute the element reads; `anchor` is the browser's clock
  when it arrived. The element never subtracts a daemon instant from the
  browser's clock. `duration.format` is the terminal strip's format.
- `fold.Model` (`Closed` | `Opened`) and `fold.Msg` (`Toggled`): the fold's
  shadow root holds one button carrying the `summary` slot and, while open,
  the default slot. Each toggle emits `fold.toggled_event`
  (`loom-fold-toggled`, bubbling and composed, no data).
- `expand_rule.Shown` (`Closed` | `Open`), `expand_rule.toggled` and
  `glyph`, and `expand.Msg` (`Toggled`): the element's shadow root holds one
  button (the chevron and the head slot, `aria-expanded`) and, while open, the
  body slot. It has no words of its own. It starts `Closed`, and the server never renders the state, so
  a patch leaves the reader's choice alone. Each toggle emits
  `fold.toggled_event`, so `<loom-follow>` hears it as it hears a fold's: it
  sets `Reading`, and expanding the newest row at the bottom does not scroll
  past the button the reader pressed. Collapsing shrinks the lane and the
  browser fits the scroll position, which the follow rule treats as layout,
  never as the reader leaving.
- `follow.Model(reader, watching, anchor)` (`follow_rule.Reader` holds
  position, gap, top, extent and touched, and `follow_rule` moves it),
  `follow_rule.Position` (`Following` | `Reading`) and `follow.Msg` (`Connected`,
  `Disconnected`, `Watched`, `Touched`, `Scrolled(top, extent, at)`,
  `Resized`, `Measured`, `Folded`, `Paged`, `Jumped`, `Held`, `Released`):
  a scroll sets the position from where it ended, which way it moved and who
  moved it (`follow_rule.after_scroll(current, gap, moved, origin)`). Within
  `follow_rule.slack` pixels of the bottom is `Following`. A move up that ends
  further away is `Reading` only when the reader made it; a move down that
  ends further away changes nothing, because that is either the reader
  coming back or the element's own scroll to the bottom reported after more
  rows landed. `follow_rule.origin` tells who made a scroll: `Input` when a
  `wheel`, `touchstart`, `touchmove`, `pointerdown` or `keydown` on the element was heard
  within `follow_rule.touch_window` (`Touched`, passive listeners that read
  nothing from the event), `Steady` when nothing was heard but the
  transcript's `Extent` (content and view height) is what it was at the
  last scroll (find-in-page, a key pressed outside the transcript, a
  scrollbar drag), and `Layout` when nothing
  was heard and the extent changed, which is the browser fitting the scroll
  position to a box that grew or content that shrank. A `Layout` scroll
  never leaves `Following`; the size change that caused it brings `Resized`,
  which scrolls to the bottom. Each `Input` scroll renews `touched`, so a
  slow scrollbar drag stays the reader's. A resize of the transcript or its
  content scrolls to the bottom only while `Following`; a fold's toggle
  event, heard on the slot, sets `Reading`, so opening a fold never scrolls
  past it. A click heard on the slot whose target carries the server's fixed
  `data-loom-older` marker is `Paged`: it sets `Reading` and holds the
  lane's first row and its place on screen (`follow.Anchor`, `None` when
  the page has no lane row); a scroll by the reader measures it again, and
  the first resize after which that row is no longer the lane's first
  scrolls the transcript to put it back and releases it (`follow_rule.keeping`
  over a `follow_rule.Standing`: `Detached`, `Leading`, `Displaced(top)`). The
  watch (`follow.Watching`) is the element, its scroll listener and input
  listeners, a `ResizeObserver` on the element and on each of its
  children, and a `MutationObserver` that keeps those current: the
  element's own box is fixed, so it is the content that changes size when a
  row lands. The shadow root holds the default slot and, while the reader is
  `Reading` more than `slack` pixels from the bottom, one button, "Jump to
  latest" (`Jumped`), whose wrapper has no height and sticks to the
  scroller's bottom edge.
- `copy_rule.Subject` (`Command` | `Token` | `Link` | `Device` | `ClaimPage`), `Copying` (`Idle` | `Copied` |
  `Failed`), `subject`, `text`, `after` and `words`, and `copy.Model(subject,
  held, copying)` with `copy.Msg` (`Subjected`, `Texted`, `Pressed`,
  `Written`): the element keeps the raw `text` and checks it against the
  subject when it draws and when it copies, because the two attributes may
  arrive in either order.
- `switch_rule.target(value)`: `Ok(value)` only for exactly
  `/ui/sessions/<canonical identity>?ticket=<64 hex digits>`,
  `/ui/home?ticket=<64 hex digits>` or `/ui/admin?ticket=<64 hex digits>`,
  `Error(Nil)` for
  anything else, an absolute URL or another path included. `<loom-switch>`
  navigates only to what it returns.
- `shell_rule.Motion` (`Still` | `Animated`) and `frame_classes`: the frame
  starts `Still`, with the class `still` that the stylesheet reads to turn the
  columns' width transition off, so the saved layout is drawn without a slide,
  and `Settled` (sent after the restored layout is painted) makes it
  `Animated`.
- `shell_rule.Region` (`Sidebar` | `Panel`), `Tab` (`Strands` | `Changes` |
  `Session`), `State` (`Open` | `Closed`), `Layout(sidebar, panel, tab)`,
  `Presence` (`Listed` | `Unlisted`) and `Reach` (`Reachable` | `Unreachable`),
  with `toggled`, `chosen`, `state`, `reach`, `label`, `hint` (the visible
  `⌘B` / `⌘⌥B` words each toggle draws as an `aria-hidden` `kbd.toggle-hint`),
  `tabs`, `tab_label`,
  `tab_state`, `has_button`, `presence` (a total decoder of the `sidebar`
  attribute), `needing` (a total decoder of the `needing` attribute: a plain
  number of at most four digits, else none), `badge` and `strands_words`,
  `relay` (a total decoder of a marker: `Relay(card, reveal)` with `Show` or
  `Keep`), `relayed` and `card_selector`, the keyboard's `Keystroke`
  (`Modifiers`, `Target` as `Editor | Approvals | Elsewhere`, `Composition`,
  `Prevention`, `Repetition`), `intent` (`ToggleSidebar | TogglePanel |
  LeaveStrand`, or nothing), `cancels`, `candidate`, `title`, `shortcuts` and
  `crumb_link`, and
  `shell.Model(layout, sidebar, needing, workspace, keys)` and `shell.Msg`
  (`Toggled(region)`, `Chosen(tab)`, `SidebarChanged(presence)`,
  `NeedingChanged(count)`, `Relayed(relay)`, `Pressed(intent)`, `Connected`,
  `Disconnected`, `Listening(listener)`, `ThemeCycled`,
  `Restored(workspace, saved, theme)`).
  `Listening` stops any listener the model still holds as it keeps the new
  one, because `listen` registers after the paint and can arrive after a
  later `Connected`. The
  shadow root holds the bar (the two buttons around the `bar` slot) and the
  body (a wrapper per side column around its slot, and the default slot in the
  centre; the panel's wrapper holds the tab bar above the slot). A closed
  column's wrapper is `inert` and the stylesheet gives it no width. The
  buttons and the tabs are real buttons, the tabs `aria-pressed`, with words
  from `shell_rule.label` and `shell_rule.tab_label`. A tab press changes
  the custom state and nothing else: closing and reopening the panel keeps the
  tab.
- `shell_rule.Frame` (`Wide` | `Narrow`), `narrow_query` (`(max-width: 1211px)`,
  the stylesheet's breakpoint), `sidebar_state`, `sidebar_pressed`,
  `Dismissal` (`Dismiss` | `Leave`), `dismissal`, `scrimmed` and
  `presses_button`: below 1212px the sidebar is a drawer over the centre
  behind a scrim. `<loom-shell>` keeps a `Frame` from a `matchMedia` listener
  (`ffi_dom.media_query`, `media_matches`) and a drawer `State` beside the
  layout; the drawer is never saved, starts closed, and closes when the frame
  changes. The sidebar's button and Command/Control B flip it, a click on the
  scrim or on a button in the sidebar (read from the click's composed path)
  closes it, and `Escape` closes it before it leaves a strand.
- `layout_rule.Workspace` (`Identified(digest)` | `Anonymous`), with
  `workspace` (a total decoder of the `workspace` attribute: exactly 64
  lower-case hex digits, else `Anonymous`), `layout_key` (`loom.layout.v1.` and
  the digest, or nothing), `encode` (a JSON object of three words) and
  `restore` (total: any stored text, or a missing or blocked item, answers a
  `shell_rule.Layout`; the default for malformed text, and the default of one
  field that is missing or names an unknown word), and the theme:
  `Theme` (`System` | `Light` | `Dark`), `theme` (a total decoder of the stored
  word: anything but `light` and `dark` follows the system), `encode_theme`,
  `next_theme`, `data_theme` (the root's attribute, or nothing for `System`),
  `label` and `word` for the button, and `theme_key`. It imports neither Lustre
  nor the DOM binding, and `layout_test` covers it on Node.
- `composer.Model(entries, draft, selected, palette, returns, attachments,
  pending, refusals, submitting)` and
  `composer.Msg` (`Configured`, `Returned`, `Holding`, `Typed`, `Moved`,
  `Accepted`, `Picked`, `Dismissed`, `Sent`, `Ignored`, `Refused`, `Pressed`,
  `Connected`, `Disconnected`, `Listening`): `commands` is the table the
  server built from the terminal's suggestions (`composer_rule.entries` decodes
  it, and decodes to no table if it is not one); `composer_rule.matching(entries,
  draft)` is `command.suggestions`' rule over that table, one-word commands
  by prefix and a word with a closed vocabulary (`/effort `, `/goal `) by
  its argument rows past the space. `composer_rule.intent(key, chord, phase,
  palette)` says what a key does: Command or Control with Enter is `Sent`
  and its default cancelled; while the list shows, the arrows are `Moved`,
  Tab and Enter are `Accepted` and Escape is `Dismissed`; everything else,
  and every key during composition, is the browser's. `Returns` is `Unseen`
  or `Seen(taken)`: the first `returned` count is the baseline, so an editor
  drawn afresh takes none of the returns before it. `composer_rule.hear` turns
  each later count into `Take(after, up_to)` when it is above `taken` and
  advances `taken` in the same turn, so two returns that arrive before one
  frame paints claim disjoint ranges and each prompt is taken once. The
  effect reads the numbered children of the `returned` slot, and
  `composer_rule.taken` picks the ones in the range, oldest first, and
  `composer_rule.joined` puts each in the draft (an empty editor takes it as its
  draft; a typed one keeps its text and takes it after a blank line).
  `composer_rule.revealed` says where the list scrolls to keep the highlighted
  row in view. The shadow root holds the pending line, then the
  list, above one default slot; the list is `role="listbox"` and its rows
  `role="option"`.
- `pending_rule.State` (`Clear` | `Shown(Pending(text, delivery))`),
  `Delivery` (`Sending` | `Queueing`), `Refusals` (`Unheard` | `Heard(count)`)
  and `Outcome` (`Keep` | `Restore(text)`), with `delivery` (the submit
  button's class: `queue` queues, anything else sends), `mark` (`sending` or
  `queued`), `pressed` (a draft with a word in it is shown; a second press
  replaces the line) and `refused` (the first count is the baseline; one that
  rises while a line is shown clears it and restores the text; one with no
  line, or one that does not rise, only advances what was heard). The element
  hears the form's `submit` through a listener it adds on `Connected` and
  removes on `Disconnected` (`Submitting`), reads the draft and the submitter
  from it, and acts after the paint, so the server's own handler has read the
  form first.
- `internal/ffi_dom` and `internal/dom.mjs`: the package's only browser
  API and its only JavaScript. Every function is one DOM call or property
  access: `host`, `as_element`, `same`, `is_connected`, `first_element_child`,
  `children`, `closest`, `query_selector`, `query_selector_all`, `dataset_get`,
  `text_content`, `scroll_top`, `set_scroll_top`, `scroll_by`,
  `scroll_height`, `client_height`, `offset_top`, `offset_height`,
  `bounding_top`, `media_query`, `media_matches`, `add_passive_listener`, `add_listener` (called with the
  event, and may cancel it), `remove_listener`, `get_document`, `composed_path`,
  `tag_name`, `attribute`, `is_content_editable`, `prevent_default`,
  `resize_observer`, `observe`, `mutation_observer`, `observe_child_list`,
  `disconnect`, `value`, `set_value`, `utf16_length`, `set_selection_range`,
  `focus`, `click`, `request_submit`, `request_submit_with`, `now`,
  `set_interval`, `clear_interval`, `document_element`, `set_attribute`,
  `remove_attribute`, `storage_read` and `storage_write` (each
  one `localStorage` call inside a `try`, answering a `Result`, since storage
  throws when blocked; the only way the package reaches storage). Its types are `Element` (an element, or the shadow root
  Lustre hands an `after_paint` effect, which answers queries alike),
  `Listener`, `Observer` and `Timer`. The one decision in `dom.mjs` is
  turning a null or undefined DOM answer into `Error(Nil)`. Add a function
  there only when a component needs a DOM call that is not bound, and keep
  the logic in Gleam. There is no other `.mjs`: the lint gate below fails
  one.

## Tests

What the components decide is in seven modules that import neither Lustre nor
`ffi_dom`: `attach_rule` (the limits, which files are accepted and refused,
the held images and the form field they make), `drop_rule` (which drags carry
files, the drag state, when the drop state shows), `follow_rule` (the scroll rule, `Reader` and its transitions,
`keeping`), `expand_rule` (the two states and the chevron), `shell_rule`
(which columns are open, the buttons' words, what a closed column lets the
keyboard reach), `composer_rule` (the table, `matching`, `intent`, `hear`, `taken`,
`joined`, `revealed`), `pending_rule` (the pending line: `pressed`, `refused`,
`mark`) and `duration`. `follow`, `composer` and `elapsed` are
the elements over them. The split is enforced, not just conventional: Lustre's
client runtime declares `class LustreEvent extends CustomEvent` at load, Node
18 (the signoff container's) has no global `CustomEvent`, and a test that
imports an element throws before any test runs. `scripts/web_client_test.sh`
walks the imports reachable from `test/` and fails if one reaches `lustre` or
`web_client/internal/`.

`test/` holds gleeunit tests for what the components decide: `follow`'s
scroll rules and the sequences of messages the page sends, `composer`'s
`matching`, `intent`, `hear`, `taken`, `joined` and `revealed`, and
`duration.format`. They run on the JavaScript target, so they need Node,
Bun or Deno: `make test-web_client` (`scripts/web_client_test.sh`, which
`scripts/check.sh` runs after the compile). The container the signoff runs in
installs Node for this; a machine with no runtime prints a `SKIP` line that
`.github/scripts/skip_census.sh` refuses. What the tests do not reach is the
DOM: the listeners, the observers, the scroll events, the caret and focus,
`requestSubmit`, and the way the browser lays the page out. Those run only in
a browser and are checked by hand.

## Relationships

- **Depends on**: `lustre` (client components, `lustre.register`),
  `gleam_stdlib`, `gleam_json` (the fold event's empty payload). Dev only:
  `lustre_dev_tools`, for `make gen-client`, and `gleeunit`, for the tests.
- **Depended on by**: nothing at compile time. `packages/web_view` renders
  its elements by tag name, and `packages/client` serves its bundle from
  `web_view`'s `priv/static` (`ui_http.Client`).

## Traffic

None over the socket. Each element is a Lustre runtime inside the browser:
attribute changes and DOM events reach its `update`; its timers dispatch
messages to it. Nothing here opens a connection. The one element that
looks outside itself is `<loom-follow>`, which reads and sets its own
scroll position, observes the size of itself and its children, and hears
(passively, reading nothing from them, not even the key) the wheel, a finger,
a pointer press and a key pressed inside itself; it reads no content. `<loom-composer>` listens to its own
editor's `input` and `keydown`, and writes the editor's value; the one thing
it sends is the form's submit, which the server already accepts.
`<loom-shell>` listens to `keydown` on the document while connected, reads the
event's key fields and, for `Escape` and `B` only, its composed path, and
sends the server nothing.

## Invariants

- **Only attributes that hold daemon identities or numbers.** An element
  never renders an attribute's value as text unless it is a number it
  computes from, and never takes session text as an attribute. Text inside
  `<loom-fold>` is the server's light-DOM children, projected through slots.
  The one exception in kind is `<loom-composer commands>`, the static table
  of command names and hints written in `session_view`; the returned
  prompts it takes arrive as text-node children, never as attributes.
- **No key acts inside an approval card, and no key decides, dismisses or
  focuses one; no focus near an approval card.** `<loom-composer>` acts on a
  key on its own editor, through its slot. `<loom-shell>` holds the dock in its
  subtree, as the page's frame, and is the one other element that acts on a
  key, on three (protocol-change/051, the addendum on the keyboard): Command or
  Control with `B` hides or shows the sidebar, with Alt too the panel, and
  `Escape` presses the breadcrumb's `All strands` link. It listens on the
  document while connected (removed on disconnect), since the page's usual
  focus is `body`; decodes the keystroke into plain values; reads where it was
  pressed from the event's composed path (`shell_rule.Step` per node,
  `shell_rule.target`), because at the document the target is retargeted to
  the outermost shadow host; and lets `shell_rule.intent` decide. A key that is
  neither `Escape` nor `KeyB` is dropped before its path is looked at. The rule
  takes no key at all when the path includes an element marked
  `data-loom-approvals`, treats the composer and any input, textarea, select or
  editable text as the editor, and takes none while
  composing, when the default was cancelled, or while a key repeats; `Escape`
  does nothing in the composer, and the sidebar shortcut nothing on a page with
  no sidebar. The toggles cancel the browser's action, `Escape` does not.
  Nothing takes focus and the element sends the server nothing: no intent
  decides, sends or focuses, and the server registers no key handler (the
  socket admits none). Its clicks are its own buttons and tabs and a click
  whose own target carries a strand marker (which presses a strand card and
  nothing else); the centre column, where the dock is, has no button, and no
  approval card carries a marker. `<loom-follow>` may note that a key was pressed inside the transcript
  (a passive `keydown` that reads nothing from the event, never cancels it and
  sends nothing), so a keyboard scroll counts as the reader's. It calls `focus` once, on that editor, when the operator chooses
  a row. The approval cards are outside it, in the dock, and no key it
  handles decides one: Command or Control with Enter submits the composer's
  form, which sends a prompt or a command and decides nothing.
- **No raw HTML.** Lustre renders through its virtual DOM; nothing here
  uses `unsafe_raw_html` or `innerHTML`. `scripts/web_client_js_check.sh`, run
  by `make lint` (so by `make lint-web_client` and `make check`), fails if any
  JavaScript file under `src` is not `internal/dom.mjs`, or if one names
  `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `eval`, `new Function`,
  `document.write`, `srcdoc`, `DOMParser`, `createContextualFragment` or a
  dynamic `import(`, or if `localStorage` is used other than by
  `window.localStorage.getItem(` and `.setItem(`, or `sessionStorage`,
  `indexedDB`, `document.cookie` or `cookieStore` appears, or a Gleam
  `@external(javascript, ...)` names a file other than `./dom.mjs`. It has its
  own self-test.
- **Words use a `-text` token; marks use the plain one.** The stylesheet's
  hues come in pairs (`--color-signal` and `--color-signal-text`, and the same
  for `advisor`, `peer`, `danger`, `added` and `strand-2` to `strand-6`). The
  plain token is the redesign's colour for a dot, ring, bar or border; the
  `-text` token is the value for words in that hue, which is darker in the
  light theme because the design's light hues are under 4.5:1 there
  (`docs/design-notes/web-design.md`, section 5). A strand's hue is `--hue`
  for marks and `--hue-text` for words. `--color-fg-faint` is never text.
  `scripts/web_client_contrast_check.sh`, run by `make lint`, fails if a text
  token is under 4.5:1 on a surface it is drawn on (`bg`, `bg-raised`,
  `bg-sunk`, `bg-user`, `code`, and the diff backgrounds for `added-text` and
  `danger-text`) in either theme, or if a rule sets `color:` from a mark
  token, `--hue` or `fg-faint`. It has its own self-test. `on-danger` (the
  tab badge's text) is held against `danger`, and `bg` against `fg` for the
  filled primary buttons.
- **The monospace face is for code.** Labels, rows and headings are
  `--font-sans`; `--font-mono` is for code, paths, tags, diffs and tool
  output. `scripts/web_client_css_check.sh`, run by `make lint`, fails a rule
  whose selector names `.line`, `.step`, `.chip` or `.panel-title` and sets
  the monospace face; a row that carries code names the code's own class
  (`pre.tool-result`, `.step-summary`, `.diff-row`). It has its own self-test.
- **Tokens live on `:root`; a shadow root only inherits them.** The Theme
  button sets `data-theme` on `<html>`, and custom properties inherit through
  every shadow root under it. Tailwind's `@theme` also writes the dark palette
  on `:host`, which would shadow the inherited value in each element, so the
  stylesheet ends the palettes with a `:host` rule that sets every token to
  `inherit` (`web_client.css`, the light tokens). A new token needs a line in
  the dark `@theme`, in both light palettes (`:root:not([data-theme="dark"])`
  under the light media query, and `:root[data-theme="light"]`) and in that
  `:host` rule; the contrast check fails when the light palettes disagree or a
  token has no `inherit` line.
- **State the DOM would hold in an expando lives in the model.** The
  returned-prompt bookkeeping (`Seen(taken)`), the scroll bookkeeping (`top`,
  `extent`, `touched`) and the held row are Lustre model fields, never
  properties set on the host element.
- **No state the server needs.** A fold's open state, a clock reading and
  whether the reader follows the tail live only in the browser; the server
  never reads them.
- **The follower never touches an approval card.** `<loom-follow>` wraps
  the lane only, as the scroll container between the pinned header and
  the pinned dock; the cards and the composer are in the dock outside it.
  It scrolls instantly, never smoothly, because a smooth scroll reports
  intermediate positions that read as the reader leaving the tail. The row
  it holds for "Load older" is found by structure (the lane's first
  child), and only its box is read.
- **Only a scroll the reader made leaves the tail.** A browser moves the
  scroll position up by itself when content shrinks or the box grows, and the
  event is heard after the rows that landed since, so by geometry alone it is
  the reader leaving. `follow_rule.origin` refuses that (see `follow.Model`
  above). Keep any change to the follow rule inside `follow_rule.after_scroll` and
  `follow_rule.origin`, and add a sequence to `test/follow_test.gleam`.
- **The committed bundle is generated.** Change this package and run `make
  gen-client`; `make client-check` (part of `make check`) fails on drift,
  by digests, without Node, Bun or a network.

## Deep Docs

- `docs/lustre.md`: server components, client components inside them, the
  security rules, and how the bundle is built and gated.
- `protocol-change/051-web-view-route.md`: the page's threat model.
