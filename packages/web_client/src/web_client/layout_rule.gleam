//// What `<loom-shell>` keeps in the browser's storage between page loads:
//// the two side columns' open state per workspace, and the panel's active tab
//// and the page's theme per browser.
////
//// The storage itself is two calls in `web_client/internal/ffi_dom`, one that
//// reads an item and one that writes an item, which answer a `Result`
//// because the browser throws when storage is blocked or the window is
//// private. Everything else is here, over plain values: which item a
//// workspace's layout lives in, how a layout is written, how a stored string
//// is read back, and what the page does when there is nothing to read. This
//// module imports neither Lustre nor the DOM binding, so the tests load it
//// under Node (`scripts/web_client_test.sh` checks that).
////
//// Two decisions shape the module. First, reading is total. A stored value
//// is text that any script on the origin, an older release of this code, or
//// the person through the developer tools could have written, so
//// `restore` accepts any string and answers a layout: the default when the
//// item is missing or is not the JSON object it expects, and the default for
//// one field when that field names an unknown word, for example a tab a
//// later release removed. A bad value never stops the page from drawing and
//// is overwritten by the next change.
////
//// Second, nothing that comes from a session is stored. The layout holds two
//// column states and a tab, and the theme one of three words. The focused
//// strand and the session viewed are not saved (docs/design-notes/
//// web-design.md, section 4): a reload shows `main`, and a page's address
//// names its session. The key carries a digest of the workspace, not the
//// workspace's path, and the daemon computes it (`component.Start`), so a
//// path never becomes an attribute or a storage key. The addendum on the
//// storage decision in protocol-change/051 has the rest.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import web_client/shell_rule.{
  type Layout, type State, type Tab, Changes, Closed, Layout, Open, Session,
  Strands, Trace,
}

/// The item the theme lives in. The theme is the reader's preference for the
/// browser and is the same for every workspace, so the item has no digest.
pub const theme_key = "loom.theme.v1"

/// The item the panel's active tab lives in. The tab is the reader's habit and
/// not a fact about a workspace, so it is kept per browser, like the theme: a
/// reader who works in Changes finds Changes on the next session's page too.
/// The layout's own `tab` field is still written, and is what a page uses
/// when this item is missing.
pub const tab_key = "loom.panel.tab.v1"

/// Which workspace a page belongs to, as far as storage is concerned.
pub type Workspace {
  /// The page's `workspace` attribute is a workspace digest, and the layout
  /// is kept under it.
  Identified(digest: String)

  /// The page named no workspace, or named something that is not a digest.
  /// Its layout is neither read nor written, so a page that cannot say which
  /// workspace it is for never shares or overwrites another's.
  Anonymous
}

/// The theme the page draws in.
pub type Theme {
  /// The page follows the operating system's setting
  /// (`prefers-color-scheme`), which is how every page starts.
  System

  /// The page is light whatever the system says.
  Light

  /// The page is dark whatever the system says.
  Dark
}

/// The workspace the `workspace` attribute names. The daemon writes a
/// lower-case SHA-256 in hex, 64 digits. Decoding is total: anything else,
/// including no attribute at all, is `Anonymous`, so the storage key is never
/// built from text the daemon did not compute.
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.workspace("<b>") == layout_rule.Anonymous
/// ```
pub fn workspace(value: String) -> Workspace {
  let digest =
    string.drop_start(value, 64) == ""
    && string.drop_start(value, 63) != ""
    && list.all(string.to_graphemes(value), fn(digit) {
      string.contains("0123456789abcdef", digit)
    })
  case digest {
    True -> Identified(value)
    False -> Anonymous
  }
}

/// The item a workspace's layout lives in, or nothing for a page that has no
/// workspace. The name carries a version, so a later release that writes a
/// different shape moves to a new item and leaves the old one unread.
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.layout_key(layout_rule.Anonymous) == None
/// ```
pub fn layout_key(workspace: Workspace) -> Option(String) {
  case workspace {
    Identified(digest:) -> Some("loom.layout.v1." <> digest)
    Anonymous -> None
  }
}

/// The text to store for `layout`: a JSON object with a word for each of the
/// three fields. Words, not booleans, so a reader of the storage sees what a
/// value means and nothing depends on which polarity a flag had.
///
/// ## Examples
///
/// ```gleam
/// // layout_rule.encode(shell_rule.initial())
/// //   == "{\"sidebar\":\"open\",\"panel\":\"open\",\"tab\":\"strands\"}"
/// ```
pub fn encode(layout: Layout) -> String {
  json.object([
    #("sidebar", json.string(state_word(layout.sidebar))),
    #("panel", json.string(state_word(layout.panel))),
    #("tab", json.string(tab_word(layout.tab))),
  ])
  |> json.to_string
}

/// The word stored under `tab_key` for a tab.
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.encode_tab(shell_rule.Changes) == "changes"
/// ```
pub fn encode_tab(tab: Tab) -> String {
  tab_word(tab)
}

/// The tab the browser's saved item names, or nothing when the item is
/// missing, blocked or holds a word this release does not know, so the
/// workspace's layout decides.
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.restored_tab(Ok("changes")) == Some(shell_rule.Changes)
/// assert layout_rule.restored_tab(Ok("sepia")) == None
/// assert layout_rule.restored_tab(Error(Nil)) == None
/// ```
pub fn restored_tab(stored: Result(String, Nil)) -> Option(Tab) {
  stored |> result.try(tab_of) |> option.from_result
}

/// The layout a page starts with, given what the storage answered for its
/// workspace's item. An item that is missing (`Error`, which is also what a
/// blocked storage answers) or is not a JSON object is the default layout,
/// and a field that is absent or names a word this release does not know is
/// that field's default. Both columns and the Strands tab are the default
/// (`shell_rule.initial`).
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.restore(Error(Nil)) == shell_rule.initial()
/// assert layout_rule.restore(Ok("not json")) == shell_rule.initial()
/// ```
pub fn restore(stored: Result(String, Nil)) -> Layout {
  stored
  |> result.try(fn(text) {
    json.parse(text, layout_decoder()) |> result.replace_error(Nil)
  })
  |> result.lazy_unwrap(shell_rule.initial)
}

// The stored object as a layout. A field that is missing takes the default,
// and so does a word that names nothing, because a tab that a later release
// removed must not discard the columns' state beside it. A field of the
// wrong type, or a value that is not an object, fails the decoder, and
// `restore` answers the whole default.
fn layout_decoder() -> decode.Decoder(Layout) {
  let fallback = shell_rule.initial()
  use sidebar <- decode.optional_field(
    "sidebar",
    fallback.sidebar,
    word_or(state_of, fallback.sidebar),
  )
  use panel <- decode.optional_field(
    "panel",
    fallback.panel,
    word_or(state_of, fallback.panel),
  )
  use tab <- decode.optional_field(
    "tab",
    fallback.tab,
    word_or(tab_of, fallback.tab),
  )
  decode.success(Layout(sidebar:, panel:, tab:))
}

// A string decoded through `of`, or `default` for a word `of` does not know.
fn word_or(
  of: fn(String) -> Result(value, Nil),
  default: value,
) -> decode.Decoder(value) {
  decode.map(decode.string, fn(word) { result.unwrap(of(word), default) })
}

fn state_word(state: State) -> String {
  case state {
    Open -> "open"
    Closed -> "closed"
  }
}

fn state_of(word: String) -> Result(State, Nil) {
  case word {
    "open" -> Ok(Open)
    "closed" -> Ok(Closed)
    _ -> Error(Nil)
  }
}

fn tab_word(tab: Tab) -> String {
  case tab {
    Strands -> "strands"
    Changes -> "changes"
    Session -> "session"
    Trace -> "trace"
  }
}

fn tab_of(word: String) -> Result(Tab, Nil) {
  case word {
    "strands" -> Ok(Strands)
    "changes" -> Ok(Changes)
    "session" -> Ok(Session)
    "trace" -> Ok(Trace)
    _ -> Error(Nil)
  }
}

/// The theme a page starts with, given what the storage answered. Anything
/// but the words `light` and `dark`, a missing or blocked item included, is
/// `System`, so a page whose storage says nothing follows the operating
/// system's setting.
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.theme(Ok("dark")) == layout_rule.Dark
/// assert layout_rule.theme(Ok("sepia")) == layout_rule.System
/// assert layout_rule.theme(Error(Nil)) == layout_rule.System
/// ```
pub fn theme(stored: Result(String, Nil)) -> Theme {
  case stored {
    Ok("light") -> Light
    Ok("dark") -> Dark
    Ok(_) | Error(Nil) -> System
  }
}

/// The text to store for a theme: the word `theme` reads back.
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.encode_theme(layout_rule.Light) == "light"
/// ```
pub fn encode_theme(theme: Theme) -> String {
  case theme {
    System -> "system"
    Light -> "light"
    Dark -> "dark"
  }
}

/// The theme after the reader presses the theme button: system, then light,
/// then dark, then system again. A button that only swapped light and dark
/// could not say which the page is showing without asking the browser what
/// the system prefers, and it could never go back to following the system.
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.next_theme(layout_rule.System) == layout_rule.Light
/// assert layout_rule.next_theme(layout_rule.Dark) == layout_rule.System
/// ```
pub fn next_theme(theme: Theme) -> Theme {
  case theme {
    System -> Light
    Light -> Dark
    Dark -> System
  }
}

/// The value of the page root's `data-theme` attribute for a theme, or
/// nothing where the attribute is absent and the system's setting decides.
/// The stylesheet reads the attribute (`:root[data-theme="light"]`).
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.data_theme(layout_rule.System) == None
/// assert layout_rule.data_theme(layout_rule.Dark) == Some("dark")
/// ```
pub fn data_theme(theme: Theme) -> Option(String) {
  case theme {
    System -> None
    Light -> Some("light")
    Dark -> Some("dark")
  }
}

/// The words on the theme button: what it shows now and what pressing it
/// does.
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.label(layout_rule.System)
///   == "Theme: following the system. Switch to light."
/// ```
pub fn label(theme: Theme) -> String {
  case theme {
    System -> "Theme: following the system. Switch to light."
    Light -> "Theme: light. Switch to dark."
    Dark -> "Theme: dark. Switch to following the system."
  }
}

/// The short word the theme button draws: the theme it is showing.
///
/// ## Examples
///
/// ```gleam
/// assert layout_rule.word(layout_rule.System) == "Auto"
/// ```
pub fn word(theme: Theme) -> String {
  case theme {
    System -> "Auto"
    Light -> "Light"
    Dark -> "Dark"
  }
}
