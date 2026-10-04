//// What `<loom-shell>` decides: which of the page's two side columns are
//// open, which tab the strand panel shows, what each toggle and tab says,
//// whether a column can be reached by the keyboard, and whether the page has
//// a sidebar at all.
////
//// The element (`web_client/shell`) draws the page's frame around the
//// server's regions: the top bar, the sessions sidebar on the left, the
//// centre, and the strand panel on the right. The server writes what is in
//// each region and knows nothing of whether a column is shown. Which columns
//// are shown is a preference of the reader's browser that changes with
//// nothing the server holds, so it lives in the element, and the two
//// buttons that change it are most of its behaviour. The strand panel has
//// tabs, and which one shows is the same kind of preference: the server
//// draws every tab's pane, and the shell shows one. This module holds the
//// rules over plain values and imports neither Lustre nor the DOM binding,
//// so the tests load it under Node (`scripts/web_client_test.sh` checks
//// that).
////
//// The shell also relays clicks. The transcript's dots and tags, the
//// breadcrumb's `All strands` and a strand view's back link are controls with
//// no handler of their own: each carries `data-loom-focus`, the position of a
//// strand card, and the shell presses that card. `relay` decodes the marker
//// totally, `relayed` says how the layout changes, and `card_selector` names
//// the card to press. The pressing itself is the element's, and it is an
//// ordinary click on the card's ordinary handler, so nothing the socket
//// admits changes (protocol-change/051, the addendum on the marker relay).
////
//// The shell also decides three keys (protocol-change/051, the addendum on
//// the keyboard). `intent` takes what a `keydown` says, as plain values, and
//// answers with one of three intents or nothing: hide or show the sidebar,
//// hide or show the panel, and leave a strand for `main`. Which keystrokes
//// count and where they do not act is in one function, so the tests can walk
//// the key set and every exclusion. No intent sends anything to the session,
//// and none decides an approval: an approval card is a place where no key acts.
////
//// A layout is what a page starts with and what the reader changes. Keeping
//// one across a reload is `web_client/layout_rule`'s, over the same types:
//// the two columns and the tab are the whole of what is stored, and a page
//// with nothing stored starts from `initial`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// One of the two side columns.
pub type Region {
  /// The sessions sidebar, on the left.
  Sidebar

  /// The strand panel, on the right.
  Panel
}

/// One of the strand panel's tabs. The server draws a pane for each, always,
/// and the shell shows the chosen one, so a tab needs no round trip and the
/// server never learns which is showing.
pub type Tab {
  /// The strand cards, and the detail of the strand in focus.
  Strands

  /// The files the session's own edits changed.
  Changes

  /// The session's goal and cost and, where the page shows them, its jobs
  /// and viewers.
  Session

  /// The session's `code_mode` programs, in order, with the newest one's
  /// state, result and budget.
  Trace
}

/// Whether a column is shown.
pub type State {
  /// The column takes its width and its content is reachable.
  Open

  /// The column takes no width and its content is not reachable.
  Closed
}

/// Which columns are shown, and which tab the panel shows.
pub type Layout {
  Layout(
    /// The sessions sidebar's state.
    sidebar: State,
    /// The strand panel's state.
    panel: State,
    /// The tab the strand panel shows, whether or not the panel is open.
    tab: Tab,
  )
}

/// Whether the page draws a sidebar. An observer's page draws none, so its
/// bar has no button for it.
pub type Presence {
  /// The server drew a sidebar.
  Listed

  /// The page has no sidebar.
  Unlisted
}

/// Whether a closed column's content can take focus.
pub type Reach {
  /// The content is in the page's tab order and reachable by assistive
  /// technology.
  Reachable

  /// The content is out of the tab order and hidden from assistive
  /// technology, as though it were not in the page.
  Unreachable
}

/// Whether a change of layout is drawn as an animation.
pub type Motion {
  /// The columns change at once. The frame starts here and stays here until
  /// the saved layout has been read and drawn, so a column saved as closed is
  /// closed on the frame that shows it and does not visibly slide shut on
  /// every load.
  Still

  /// A column's width animates when the reader opens or closes it.
  Animated
}

/// The classes the frame carries for `motion`. `still` is the class the
/// stylesheet reads to turn the width transition off
/// (`.shell.still .region`).
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.frame_classes(shell_rule.Still) == ["shell", "still"]
/// ```
pub fn frame_classes(motion: Motion) -> List(String) {
  case motion {
    Still -> ["shell", "still"]
    Animated -> ["shell"]
  }
}

/// Both columns open on the Strands tab, which is how every page starts.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.initial()
///   == shell_rule.Layout(shell_rule.Open, shell_rule.Open, shell_rule.Strands)
/// ```
pub fn initial() -> Layout {
  Layout(sidebar: Open, panel: Open, tab: Strands)
}

/// The state of one column.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.state(shell_rule.initial(), shell_rule.Panel) == shell_rule.Open
/// ```
pub fn state(layout: Layout, region: Region) -> State {
  case region {
    Sidebar -> layout.sidebar
    Panel -> layout.panel
  }
}

/// The layout after the reader presses one column's button: that column
/// changes and the other stays as it was, as does the panel's tab.
///
/// ## Examples
///
/// ```gleam
/// let closed = shell_rule.toggled(shell_rule.initial(), shell_rule.Sidebar)
/// assert shell_rule.state(closed, shell_rule.Sidebar) == shell_rule.Closed
/// assert shell_rule.state(closed, shell_rule.Panel) == shell_rule.Open
/// ```
pub fn toggled(layout: Layout, region: Region) -> Layout {
  case region {
    Sidebar -> Layout(..layout, sidebar: flipped(layout.sidebar))
    Panel -> Layout(..layout, panel: flipped(layout.panel))
  }
}

fn flipped(state: State) -> State {
  case state {
    Open -> Closed
    Closed -> Open
  }
}

/// The layout after the reader presses a tab: the panel shows that tab and
/// nothing else changes. A tab is pressed inside the panel, so the panel is
/// open when this is called; a closed panel keeps the tab it had.
///
/// ## Examples
///
/// ```gleam
/// let chosen = shell_rule.chosen(shell_rule.initial(), shell_rule.Changes)
/// assert chosen.tab == shell_rule.Changes
/// assert chosen.panel == shell_rule.Open
/// ```
pub fn chosen(layout: Layout, tab: Tab) -> Layout {
  Layout(..layout, tab:)
}

/// The tabs, in the order the bar draws them.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.tabs()
///   == [
///     shell_rule.Strands,
///     shell_rule.Changes,
///     shell_rule.Trace,
///     shell_rule.Session,
///   ]
/// ```
pub fn tabs() -> List(Tab) {
  [Strands, Changes, Trace, Session]
}

/// The word on a tab's button.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.tab_label(shell_rule.Changes) == "Changes"
/// ```
pub fn tab_label(tab: Tab) -> String {
  case tab {
    Strands -> "Strands"
    Changes -> "Changes"
    Session -> "Session"
    Trace -> "Trace"
  }
}

/// The custom state the element sets on itself while `tab` shows. The
/// stylesheet hides the panes of the other tabs with it
/// (`loom-shell:state(tab-changes)`), which is how a slotted pane the server
/// drew is hidden without the server knowing. Each is a whole literal, so the
/// stylesheet can spell it.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.tab_state(shell_rule.Session) == "tab-session"
/// ```
pub fn tab_state(tab: Tab) -> String {
  case tab {
    Strands -> "tab-strands"
    Changes -> "tab-changes"
    Session -> "tab-session"
    Trace -> "tab-trace"
  }
}

/// Whether the content of a column in `state` can take focus. A closed
/// column is out of the tab order, because a control the reader cannot see
/// must not hold the keyboard.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.reach(shell_rule.Closed) == shell_rule.Unreachable
/// ```
pub fn reach(state: State) -> Reach {
  case state {
    Open -> Reachable
    Closed -> Unreachable
  }
}

/// The words on a column's button: what pressing it does. They name the
/// column and hold nothing from the session.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.label(shell_rule.Sidebar, shell_rule.Open) == "Hide sessions"
/// assert shell_rule.label(shell_rule.Panel, shell_rule.Closed) == "Show strands"
/// ```
pub fn label(region: Region, state: State) -> String {
  case region, state {
    Sidebar, Open -> "Hide sessions"
    Sidebar, Closed -> "Show sessions"
    Panel, Open -> "Hide strands"
    Panel, Closed -> "Show strands"
  }
}

/// Whether the bar draws a button for a column: always for the panel, and
/// for the sidebar only when the page has one.
///
/// ## Examples
///
/// ```gleam
/// assert !shell_rule.has_button(shell_rule.Unlisted, shell_rule.Sidebar)
/// assert shell_rule.has_button(shell_rule.Unlisted, shell_rule.Panel)
/// ```
pub fn has_button(presence: Presence, region: Region) -> Bool {
  case region, presence {
    Sidebar, Unlisted -> False
    Sidebar, Listed | Panel, _ -> True
  }
}

/// The presence the server's `sidebar` attribute names. The attribute is a
/// fixed word (`listed` or `none`) that the server writes, and decoding is
/// total: any other value, including none at all, is `Unlisted`, so a page
/// that says nothing draws no button that does nothing.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.presence("listed") == shell_rule.Listed
/// assert shell_rule.presence("Listed ") == shell_rule.Unlisted
/// ```
pub fn presence(value: String) -> Presence {
  case value {
    "listed" -> Listed
    _ -> Unlisted
  }
}

/// How many strands need a decision, from the `needing` attribute the server
/// writes. The server writes a count, and decoding is total: anything that is
/// not a plain non-negative number of at most four digits is none, so a page
/// that says nothing, or something else, draws no badge.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.needing("2") == 2
/// assert shell_rule.needing("-1") == 0
/// assert shell_rule.needing("<b>") == 0
/// ```
pub fn needing(value: String) -> Int {
  let graphemes = string.to_graphemes(value)
  let plain =
    list.all(graphemes, fn(grapheme) { string.contains("0123456789", grapheme) })
    && string.drop_start(value, 4) == ""
  case plain {
    True -> result.unwrap(int.parse(value), 0)
    False -> 0
  }
}

/// What the Strands tab's badge says for `count` strands waiting on a
/// decision: nothing for none, the number up to nine, and `9+` past that.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.badge(0) == None
/// assert shell_rule.badge(3) == Some("3")
/// assert shell_rule.badge(12) == Some("9+")
/// ```
pub fn badge(count: Int) -> Option(String) {
  case count {
    count if count > 9 -> Some("9+")
    count if count > 0 -> Some(int.to_string(count))
    _ -> None
  }
}

/// The words a screen reader gets for the Strands tab: the label alone, or
/// with how many strands wait on a decision, since the badge is a number a
/// reader cannot see.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.strands_words(0) == "Strands"
/// assert shell_rule.strands_words(1) == "Strands, 1 needs approval"
/// assert shell_rule.strands_words(2) == "Strands, 2 need approval"
/// ```
pub fn strands_words(count: Int) -> String {
  case count {
    1 -> "Strands, 1 needs approval"
    count if count > 1 -> "Strands, " <> int.to_string(count) <> " need approval"
    _ -> "Strands"
  }
}

/// Whether a relayed click also shows the strand panel on its Strands tab.
pub type Reveal {
  /// Open the panel if it is closed and choose the Strands tab, so the
  /// strand the click focused is seen where it is described.
  Show

  /// Leave the layout as it is.
  Keep
}

/// What a click on a marked control asks for: the strand card at `card` is
/// pressed, and the layout changes as `reveal` says.
pub type Relay {
  Relay(
    /// The position of the card to press, from the marker's number.
    card: Int,
    /// Whether the panel is shown.
    reveal: Reveal,
  )
}

/// What the click on a control carrying `data-loom-focus` asks for, from the
/// marker's value. The marker is a number the server wrote, a card's position
/// among the cards as drawn, and decoding is total: anything but a plain
/// non-negative number of at most three digits is no request, so a control
/// that says something else does nothing.
///
/// Position zero is `main`, which the strip always lists first. Pressing its
/// card is `All strands`, which leaves the panel as it is: the reader is
/// leaving a strand's view and has no need of a panel they may have closed.
/// Any other position is a strand, and the panel is shown on its Strands tab
/// (the strand's own view is there).
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.relay("2") == Ok(shell_rule.Relay(2, shell_rule.Show))
/// assert shell_rule.relay("0") == Ok(shell_rule.Relay(0, shell_rule.Keep))
/// assert shell_rule.relay("main") == Error(Nil)
/// ```
pub fn relay(value: String) -> Result(Relay, Nil) {
  let graphemes = string.to_graphemes(value)
  let plain =
    graphemes != []
    && list.all(graphemes, fn(grapheme) {
      string.contains("0123456789", grapheme)
    })
    && string.drop_start(value, 3) == ""
  case plain, int.parse(value) {
    True, Ok(0) -> Ok(Relay(card: 0, reveal: Keep))
    True, Ok(card) -> Ok(Relay(card:, reveal: Show))
    _, _ -> Error(Nil)
  }
}

/// The layout after a relayed click: where `relay` says to show the panel,
/// the panel is open on its Strands tab, and otherwise nothing changes. The
/// sidebar is never touched.
///
/// ## Examples
///
/// ```gleam
/// let closed = shell_rule.toggled(shell_rule.initial(), shell_rule.Panel)
/// let shown = shell_rule.relayed(closed, shell_rule.Relay(2, shell_rule.Show))
/// assert shown == shell_rule.initial()
/// ```
pub fn relayed(layout: Layout, relay: Relay) -> Layout {
  case relay.reveal {
    Show -> Layout(..layout, panel: Open, tab: Strands)
    Keep -> layout
  }
}

/// The selector of the strand card at `card`, which the shell presses for a
/// relayed click. The attribute's name is the server's fixed word
/// (`web_view/view/strip.card_marker`), and the value is the number.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.card_selector(3) == "[data-loom-card=\"3\"]"
/// ```
pub fn card_selector(card: Int) -> String {
  "[data-loom-card=\"" <> int.to_string(card) <> "\"]"
}

/// Whether a modifier key was held when a key was pressed.
pub type Modifier {
  /// The modifier was down.
  Held

  /// The modifier was up.
  Free
}

/// The four modifier keys of a keystroke.
pub type Modifiers {
  Modifiers(
    /// Command on a Mac.
    meta: Modifier,
    /// Control.
    ctrl: Modifier,
    /// Option on a Mac.
    alt: Modifier,
    /// Shift.
    shift: Modifier,
  )
}

/// Whether an input method was composing text, as the event says. A key
/// pressed during composition belongs to the input method.
pub type Composition {
  /// An input method is composing.
  Composing

  /// No input method is composing.
  Settled
}

/// Whether the event's default had already been cancelled by the time it
/// reached the shell. A handler nearer the target that took the key says so by
/// cancelling it, and the shell leaves the key to that handler. (The composer
/// cancels the default of the keys it consumes, such as Command or Control with
/// Enter. Its `Escape` that closes the list is not cancelled, and stays the
/// composer's by `Editor`, not by this.)
pub type Prevention {
  /// Something before the shell cancelled the event's default.
  Prevented

  /// Nothing did.
  Unhandled
}

/// Whether the key is the browser repeating a held key.
pub type Repetition {
  /// The key is being held and repeats.
  Repeating

  /// The key was just pressed.
  Fresh
}

/// Where a key was pressed, as far as the shell needs to know.
pub type Target {
  /// In the composer, or in any field that takes text: an input, a
  /// textarea, a select or an element whose text can be edited. What is typed
  /// there is the field's own.
  Editor

  /// Inside the region of approval cards, where no shortcut acts.
  Approvals

  /// Anywhere else in the page.
  Elsewhere
}

/// Everything the shell reads from a `keydown`.
pub type Keystroke {
  Keystroke(
    /// The event's `key`, read only for `Escape`.
    key: String,
    /// The event's `code`, read only for `KeyB`. It names the physical key,
    /// which Option changes `key` away from on a Mac.
    code: String,
    /// The modifier keys.
    modifiers: Modifiers,
    /// Where the key was pressed.
    target: Target,
    /// Whether an input method was composing.
    composition: Composition,
    /// Whether the event's default had been cancelled.
    prevention: Prevention,
    /// Whether the browser was repeating a held key.
    repetition: Repetition,
  )
}

/// What a shortcut asks for. These are the three the page has, and none of them
/// sends anything to the session or decides anything.
pub type Intent {
  /// Hide or show the sessions sidebar.
  ToggleSidebar

  /// Hide or show the strand panel.
  TogglePanel

  /// Put the page back on `main`, by pressing the breadcrumb's `All strands`
  /// link, which is the click a pointer makes.
  LeaveStrand
}

/// Whether the shell cancels the browser's own action for a key it took.
pub type Default {
  /// The shell cancels it: `Ctrl+B` opens the bookmarks in Firefox, and a page
  /// that takes the key must say the browser may not.
  Cancelled

  /// The shell leaves it: `Escape` has no default the page needs to stop.
  Untouched
}

/// What a keystroke asks for, or nothing.
///
/// The key set is exactly three, and any other key is not read. `Command` or
/// `Control` with `B` and no other modifier hides or shows the sessions
/// sidebar, and with `Alt` too hides or shows the strand panel; the letter is
/// read from `code`, since Option changes `key` on a Mac. `Escape` with no
/// modifier puts the page back on `main`. Shift is never part of a shortcut.
///
/// A key does nothing while an input method is composing, when the event's
/// default was already cancelled, while the browser repeats a held key, and
/// anywhere inside the region of approval cards. `Escape` also does nothing in
/// the composer, so that it never changes the focus of a draft; `B` with a
/// command modifier acts there, since it has no meaning in a plain text
/// field. The sidebar shortcut does nothing on a page that has no sidebar.
///
/// ## Examples
///
/// ```gleam
/// // shell_rule.intent(keystroke, shell_rule.Listed)
/// ```
pub fn intent(keystroke: Keystroke, presence: Presence) -> Option(Intent) {
  case
    keystroke.target,
    keystroke.composition,
    keystroke.prevention,
    keystroke.repetition
  {
    Approvals, _, _, _ -> None
    _, Composing, _, _ -> None
    _, _, Prevented, _ -> None
    _, _, _, Repeating -> None
    target, Settled, Unhandled, Fresh -> shortcut(keystroke, target, presence)
  }
}

// The three keys, for a keystroke that may be read at all.
fn shortcut(
  keystroke: Keystroke,
  target: Target,
  presence: Presence,
) -> Option(Intent) {
  case keystroke.key, keystroke.code, keystroke.modifiers {
    "Escape", _, Modifiers(meta: Free, ctrl: Free, alt: Free, shift: Free) ->
      case target {
        Editor -> None
        Elsewhere | Approvals -> Some(LeaveStrand)
      }
    _, "KeyB", Modifiers(meta:, ctrl:, alt:, shift: Free) ->
      case meta == Held || ctrl == Held, alt {
        True, Free ->
          case has_button(presence, Sidebar) {
            True -> Some(ToggleSidebar)
            False -> None
          }
        True, Held -> Some(TogglePanel)
        False, _ -> None
      }
    _, _, _ -> None
  }
}

/// Whether the shell cancels the browser's action for a key it took as
/// `intent`: for the two toggles, which the browser binds to bookmarks, and
/// not for `Escape`.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.cancels(shell_rule.ToggleSidebar) == shell_rule.Cancelled
/// assert shell_rule.cancels(shell_rule.LeaveStrand) == shell_rule.Untouched
/// ```
pub fn cancels(intent: Intent) -> Default {
  case intent {
    ToggleSidebar | TogglePanel -> Cancelled
    LeaveStrand -> Untouched
  }
}

/// The words a column's toggle button carries in its `title`, naming its
/// shortcut beside what pressing it does. The button's own label is
/// `label`'s, and the shortcut is a hint and not a claim about a keyboard.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.title(shell_rule.Sidebar, shell_rule.Open)
///   == "Hide sessions (Command or Control B)"
/// ```
pub fn title(region: Region, state: State) -> String {
  label(region, state)
  <> case region {
    Sidebar -> " (Command or Control B)"
    Panel -> " (Command or Control Alt B)"
  }
}

/// The keys a toggle's visible hint shows, in the notation the design uses.
/// They are the same chord as `shortcuts` names, written for the eye; the
/// hint is decoration beside the button's icon and the button's label stays
/// what assistive technology reads.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.hint(shell_rule.Sidebar) == "⌘B"
/// assert shell_rule.hint(shell_rule.Panel) == "⌘⌥B"
/// ```
pub fn hint(region: Region) -> String {
  case region {
    Sidebar -> "⌘B"
    Panel -> "⌘⌥B"
  }
}

/// The value of a toggle's `aria-keyshortcuts`, which tells assistive
/// technology which keys act.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.shortcuts(shell_rule.Panel) == "Meta+Alt+B Control+Alt+B"
/// ```
pub fn shortcuts(region: Region) -> String {
  case region {
    Sidebar -> "Meta+B Control+B"
    Panel -> "Meta+Alt+B Control+Alt+B"
  }
}

/// The selector of the breadcrumb's `All strands` link, which the shell
/// clicks for `Escape`. It is the link a pointer clicks, so `Escape` is the
/// same press and does nothing when the breadcrumb, and so a strand to leave,
/// is not drawn. The attributes are the server's fixed words
/// (`web_view/view/crumb.marker`, `web_view/view/strip.focus_marker`).
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.crumb_link() == "[data-loom-crumb] [data-loom-focus]"
/// ```
pub fn crumb_link() -> String {
  "[data-loom-crumb] [data-loom-focus]"
}

/// Whether a key is one the shell may read at all: `Escape`, or the physical
/// `B` key. Every other key is dropped before the shell looks at where it was
/// pressed, so typing in the composer costs the shell no lookup, and no other
/// key is read.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.candidate("Escape", "Escape")
/// assert shell_rule.candidate("∫", "KeyB")
/// assert !shell_rule.candidate("a", "KeyA")
/// ```
pub fn candidate(key: String, code: String) -> Bool {
  key == "Escape" || code == "KeyB"
}

/// Whether a node of an event's path carries the marker of the approval
/// cards' region.
pub type Marker {
  /// The node is the region, so the event is inside it.
  Marked

  /// It is not.
  Unmarked
}

/// Whether a node's text can be edited by typing.
pub type Editing {
  /// The node is an element whose text can be edited.
  Editable

  /// It is not, or it is not an element.
  Fixed
}

/// What the shell reads of one node an event passed through.
pub type Step {
  Step(
    /// The node's tag in lower case, or empty for a node with none: the window,
    /// the document and a shadow root.
    tag: String,
    /// Whether the node is the approval region.
    approvals: Marker,
    /// Whether the node's text can be edited.
    editing: Editing,
  )
}

/// Where a key was pressed, from the nodes its event passed through, from the
/// target outward and through shadow trees. Any node that is the approval
/// region makes it `Approvals`, which wins over every other. Otherwise any
/// node that is the composer, a text field of any kind or editable text makes
/// it `Editor`. Anything else, including a path with no nodes, is `Elsewhere`.
///
/// The path is what the shell reads at the document, where an event's target
/// has been retargeted to the outermost shadow host and would hide both the
/// composer's editor and the cards.
///
/// ## Examples
///
/// ```gleam
/// assert shell_rule.target([]) == shell_rule.Elsewhere
/// ```
pub fn target(path: List(Step)) -> Target {
  case list.any(path, fn(step) { step.approvals == Marked }) {
    True -> Approvals
    False ->
      case list.any(path, fn(step) { editable(step) }) {
        True -> Editor
        False -> Elsewhere
      }
  }
}

fn editable(step: Step) -> Bool {
  case step.tag, step.editing {
    "loom-composer", _ -> True
    "textarea", _ -> True
    "input", _ -> True
    "select", _ -> True
    _, Editable -> True
    _, Fixed -> False
  }
}
