//// What the terminal remembers of its layout between launches, per workspace.
////
//// The web view keeps a reader's layout in the browser's storage, keyed by a
//// digest of the workspace (`web_client/layout_rule`). The terminal has no
//// browser, so it keeps the same thing in one small file in the launcher's
//// state root, `<state-dir>/tui/layout.json`, under a key of the same
//// construction: the lower-case SHA-256 of a workspace path, in hex. The
//// path is the one the terminal discovered for its workspace, made absolute,
//// which is not always the string the daemon hashes for the web page, so the
//// two stores do not share keys and nothing relies on them matching. A path
//// is never written to the file, and neither is anything a session says. The file holds the
//// layout words and nothing else: not the transcript, not the focused
//// strand, not the session. Those are not layout, and a launch shows `main`
//// of the session it was asked for.
////
//// ## Flow
////
//// `load` → `lookup` → `remember` → `save`
////
//// 1. `load` reads the file once at launch. It is total: a file that is
////    missing, unreadable, owned by someone else, readable by someone else,
////    larger than 64 KiB, not JSON, or written by another version is an
////    empty memory, and `lookup` then answers the default layout for every
////    workspace. Nothing here can stop the terminal from starting.
//// 2. `lookup` answers one workspace's layout, the default when it has none.
//// 3. `remember` puts a workspace's layout first in the memory and drops
////    the least recently changed beyond 64, so the file cannot
////    grow with the number of workspaces a person has ever opened.
//// 4. `save` is what a layout change costs: it reads the file again, applies
////    `remember` to that fresh copy, and replaces the file atomically. Two
////    terminals therefore never overwrite each other's other workspaces,
////    because each writes only its own workspace's entry into whatever the
////    file holds now. Two terminals on the same workspace race for the one
////    entry, and the later change wins: neither sees the other's change
////    until its next launch, and a layout is a preference, not state worth a
////    lock. A write between one terminal's read and its rename can still
////    cost the other's entry for a different workspace; the rename is
////    atomic, so the file is never torn.
////
//// ## What is stored
////
//// ```json
//// {"version":1,"workspaces":[{"key":"<64 hex digits>","rail":"shown","tab":"trace"}]}
//// ```
////
//// `rail` is `shown` or `hidden`, and is absent for a workspace whose rail
//// the person never toggled, so a remembered choice can be told from the
//// default. `tab` is `strands`, `trace` or `session`, the rail's tab, and is
//// absent the same way. Further words, such as a todo line's, are added as
//// optional fields, which an older terminal ignores and a newer one defaults,
//// so adding one is not a new version. An unknown word is that field's
//// default, and an entry whose key is not a digest is dropped, so a hand
//// edit or a newer release's word never discards the rest of the file.

import core/json.{type JsonValue}
import filepath
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import host/bootstrap

/// The shape of the file this release writes and reads. A file naming
/// another version is read as empty and replaced by the next change.
pub const version = 1

/// The most workspaces the file keeps, most recently changed first.
pub const max_workspaces = 64

/// The largest file `load` will read. Sixty-four entries are under ten
/// kilobytes, so a larger file is not this file.
pub const max_bytes = 65_536

/// Whether the agent rail is shown. It is a choice a person made, so it is
/// held as an `Option`: `None` is no choice, which draws the default.
pub type Rail {
  RailShown
  RailHidden
}

/// The rail's tab a person left it on. The changes tab is not here: it
/// opens an observation of the worktree, which a launch has not made, so a
/// remembered tab is one of the three that need nothing read first.
pub type Tab {
  TabStrands
  TabTrace
  TabSession
}

/// One workspace's remembered layout.
pub type Layout {
  Layout(rail: Option(Rail), tab: Option(Tab))
}

/// A workspace's layout under its key.
pub type Entry {
  Entry(key: String, layout: Layout)
}

/// Where a running terminal keeps its layout, and what it last wrote there.
/// A terminal that keeps none (a replay, a demo, a test) has no target.
pub type Target {
  Target(
    /// The file, `<state-dir>/tui/layout.json`.
    path: String,
    /// The workspace's key (`workspace_key`).
    key: String,
    /// The layout the file holds for the key, as this terminal last read or
    /// wrote it. A change is a difference from this.
    saved: Layout,
  )
}

/// The remembered layouts, most recently changed first.
pub type Memory {
  Memory(entries: List(Entry))
}

/// The layout of a workspace nobody has changed.
///
/// ## Examples
///
/// ```gleam
/// assert layout_memory.default().rail == option.None
/// ```
pub fn default() -> Layout {
  Layout(rail: None, tab: None)
}

/// A memory that holds nothing.
///
/// ## Examples
///
/// ```gleam
/// assert layout_memory.lookup(layout_memory.empty(), "k") == layout_memory.default()
/// ```
pub fn empty() -> Memory {
  Memory(entries: [])
}

/// The key of a workspace: the lower-case SHA-256 of its path in hex, the
/// construction the daemon uses to name a workspace to the web view. The path
/// is not recoverable from it.
///
/// ## Examples
///
/// ```gleam
/// assert layout_memory.workspace_key("abc")
///   == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
/// ```
pub fn workspace_key(path: String) -> String {
  path
  |> bit_array.from_string
  |> bootstrap.sha256
  |> bit_array.base16_encode
  |> string.lowercase
}

/// The layout remembered for a key, or the default.
///
/// ## Examples
///
/// ```gleam
/// assert layout_memory.lookup(layout_memory.empty(), "k") == layout_memory.default()
/// ```
pub fn lookup(memory: Memory, key: String) -> Layout {
  case list.find(memory.entries, fn(entry) { entry.key == key }) {
    Ok(entry) -> entry.layout
    Error(Nil) -> default()
  }
}

/// The memory with `layout` first under `key`, any earlier entry for the key
/// replaced, and the entries past `max_workspaces` dropped.
///
/// ## Examples
///
/// ```gleam
/// let memory = layout_memory.remember(layout_memory.empty(), "k", layout)
/// assert layout_memory.lookup(memory, "k") == layout
/// ```
pub fn remember(memory: Memory, key: String, layout: Layout) -> Memory {
  let others = list.filter(memory.entries, fn(entry) { entry.key != key })
  Memory(entries: list.take([Entry(key:, layout:), ..others], max_workspaces))
}

/// The text of a memory.
///
/// ## Examples
///
/// ```gleam
/// assert layout_memory.encode(layout_memory.empty())
///   == "{\"version\":1,\"workspaces\":[]}"
/// ```
pub fn encode(memory: Memory) -> String {
  json.Object([
    #("version", json.Int(version)),
    #("workspaces", json.Array(list.map(memory.entries, entry_json))),
  ])
  |> json.to_string
}

fn entry_json(entry: Entry) -> JsonValue {
  let rail = case entry.layout.rail {
    Some(rail) -> [#("rail", json.String(rail_word(rail)))]
    None -> []
  }
  let tab = case entry.layout.tab {
    Some(tab) -> [#("tab", json.String(tab_word(tab)))]
    None -> []
  }
  json.Object([#("key", json.String(entry.key)), ..list.append(rail, tab)])
}

fn tab_word(tab: Tab) -> String {
  case tab {
    TabStrands -> "strands"
    TabTrace -> "trace"
    TabSession -> "session"
  }
}

fn rail_word(rail: Rail) -> String {
  case rail {
    RailShown -> "shown"
    RailHidden -> "hidden"
  }
}

/// A memory read from text. Total: text that is not JSON, not an object of
/// this version, or has no list of workspaces is the empty memory. Within a
/// readable file an entry that is not an object with a digest for a key is
/// dropped, a repeated key keeps its first (most recent) entry, a field that
/// is absent or names an unknown word is that field's default, and the list
/// is cut at `max_workspaces`.
///
/// ## Examples
///
/// ```gleam
/// assert layout_memory.decode("not json") == layout_memory.empty()
/// ```
pub fn decode(text: String) -> Memory {
  case json.parse(text) {
    Ok(json.Object(fields)) -> from_fields(fields)
    Ok(_) | Error(_) -> empty()
  }
}

fn from_fields(fields: List(#(String, JsonValue))) -> Memory {
  case field(fields, "version"), field(fields, "workspaces") {
    Some(json.Int(found)), Some(json.Array(items)) if found == version ->
      items
      |> list.filter_map(entry_of)
      |> list.fold([], fn(kept: List(Entry), entry: Entry) {
        case list.any(kept, fn(seen) { seen.key == entry.key }) {
          True -> kept
          False -> [entry, ..kept]
        }
      })
      |> list.reverse
      |> list.take(max_workspaces)
      |> Memory
    Some(_), Some(_) | Some(_), None | None, Some(_) | None, None -> empty()
  }
}

// One entry, or nothing for a value that is not an object with a key that is
// a digest.
fn entry_of(value: JsonValue) -> Result(Entry, Nil) {
  case value {
    json.Object(fields) ->
      case field(fields, "key") {
        Some(json.String(key)) ->
          case digest(key) {
            True ->
              Ok(Entry(
                key:,
                layout: Layout(
                  rail: rail_of(field(fields, "rail")),
                  tab: tab_of(field(fields, "tab")),
                ),
              ))
            False -> Error(Nil)
          }
        Some(_) | None -> Error(Nil)
      }
    json.Array(_)
    | json.String(_)
    | json.Int(_)
    | json.Float(_)
    | json.Bool(_)
    | json.Null -> Error(Nil)
  }
}

// A tab word this release knows. `changes`, and any word a later release
// adds, is no choice.
fn tab_of(value: Option(JsonValue)) -> Option(Tab) {
  case value {
    Some(json.String("strands")) -> Some(TabStrands)
    Some(json.String("trace")) -> Some(TabTrace)
    Some(json.String("session")) -> Some(TabSession)
    Some(_) | None -> None
  }
}

fn rail_of(value: Option(JsonValue)) -> Option(Rail) {
  case value {
    Some(json.String("shown")) -> Some(RailShown)
    Some(json.String("hidden")) -> Some(RailHidden)
    Some(_) | None -> None
  }
}

// The first field of that name, as the parser promises there is at most one.
fn field(
  fields: List(#(String, JsonValue)),
  name: String,
) -> Option(JsonValue) {
  list.key_find(fields, name) |> option.from_result
}

// Whether a key is what `workspace_key` writes: 64 lower-case hex digits.
fn digest(key: String) -> Bool {
  string.drop_start(key, 64) == ""
  && string.drop_start(key, 63) != ""
  && list.all(string.to_graphemes(key), string.contains("0123456789abcdef", _))
}

/// The memory a file holds, or the empty memory for any reason it cannot be
/// read. The read refuses a file another user owns or can read, a link, and
/// anything over `max_bytes`; each of those is an empty memory, not an error,
/// because the terminal has to start.
///
/// ## Examples
///
/// ```gleam
/// assert layout_memory.load("/no/such/file") == layout_memory.empty()
/// ```
pub fn load(path: String) -> Memory {
  bootstrap.read_private_bounded(path, max_bytes)
  |> result.try(fn(bytes) {
    bit_array.to_string(bytes) |> result.replace_error("not UTF-8")
  })
  |> result.map(decode)
  |> result.lazy_unwrap(empty)
}

/// Writes `layout` under `key` into the file, keeping every other workspace
/// the file holds now.
///
/// The file is read again here, not taken from the launch, so a layout
/// another terminal saved since is kept. The directory is made private
/// (`0700`) and the file is replaced atomically with mode `0600`, so a reader
/// sees the whole previous file or the whole new one. The error says why a
/// save failed; the caller has nowhere to show it, since the alternate screen
/// is open, and drops it.
///
/// ## Examples
///
/// ```gleam
/// // layout_memory.save(path, key, layout)
/// ```
pub fn save(path: String, key: String, layout: Layout) -> Result(Nil, String) {
  use Nil <- result.try(
    bootstrap.ensure_private_directory(filepath.directory_name(path)),
  )
  let memory = remember(load(path), key, layout)
  bootstrap.atomic_write_private(path, encode(memory))
}
