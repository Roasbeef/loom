//// The rules of `executors.reload` that need no process (protocol-change/115):
//// which change a row comes to, which reloads are refused, and the reply.
////
//// `executors.reload` makes a running daemon reread its configuration file
//// and bring the links of the untrusted executors to match it. The part that
//// touches processes lives in `client/daemon/untrusted_links`, and the part
//// that reads the file lives in the daemon. What is left is a set of decisions
//// that depend only on values, and keeping them here lets a property test
//// check them over generated row sets without starting a link.
////
//// There are four decisions. `plan` compares the rows a daemon holds with the
//// rows the file wants and says what happens to each name. `link_rule` says
//// whether a changed `[executor_link]` table may be applied. `check_rows` and
//// `check_names` refuse a file that would hold too many rows, or a daemon that
//// has seen too many names, because each name becomes an atom for the link's
//// registered name. `encode` and `decode` are the two halves of the reply, kept
//// together so the command line can read what the daemon wrote.
////
//// Nothing in this module reads a file or resolves a path. `link_rule` takes
//// paths that the caller has already made canonical, because canonicalising
//// needs the file system and a decision over strings does not.
////
//// ## Flow
////
//// `plan` → `reply_of` → `encode`; and, on the reading side, `decode`.
////
//// 1. `check_rows`, `check_names` and `link_rule` refuse the call before
////    anything changes.
//// 2. `plan` turns the held rows and the wanted rows into one `Step` for every
////    name that is in either.
//// 3. The reconciler performs each step and may turn one into `Failed`.
//// 4. `reply_of` keeps what the caller needs to be told, and `encode` writes it.

import client/internal/ffi_tls_stream.{type Credentials}
import core/json.{type JsonValue}
import gleam/bit_array
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import storage/catalogue

/// The most untrusted rows one file may hold, and the most entries one reply
/// lists.
pub const max_rows = 512

/// The most distinct untrusted names a daemon accepts over its life. A name
/// becomes an atom, which the virtual machine never frees.
pub const max_names = 1024

/// One untrusted executor as a link is started for it: the address it dials
/// and the leaf it expects. These four values are everything a link was started
/// with, so two rows that are equal are the same link.
pub type Row {
  Row(
    /// The `[executors.<name>]` key.
    name: String,
    /// The listener's host.
    host: String,
    /// The listener's port.
    port: Int,
    /// The SHA-256 of the executor's leaf certificate.
    pin: BitArray,
  )
}

/// Whether the process that holds a row's link is running.
pub type Liveness {
  /// The link's process exists.
  Alive

  /// The link's process has ended.
  Dead
}

/// A row the daemon holds, and whether its link is running.
pub type Held {
  Held(row: Row, link: Liveness)
}

/// What a reload did, or would do, to one row.
pub type Change {
  /// The file has a row the daemon did not hold.
  Started

  /// The daemon held the row, and its link was replaced because it had ended
  /// or because the address or the pin changed.
  Restarted

  /// The daemon held a row the file no longer has.
  Stopped

  /// The row and its running link are as the file says.
  Unchanged

  /// The change was not made within the call's bound, and the row stays as it
  /// was before the call.
  Failed
}

/// What happens to one name: the change, the row the daemon held and the row
/// the file wants. `held` is `None` for a new row and `wanted` is `None` for a
/// removed one.
pub type Step {
  Step(name: String, change: Change, held: Option(Row), wanted: Option(Row))
}

/// One line of the reply.
pub type Entry {
  Entry(
    /// The row's name.
    name: String,
    /// What the reload did to it.
    change: Change,
  )
}

/// The reply of `executors.reload`: every untrusted row the file held or the
/// daemon held, strictly ascending by name, at most `max_rows` of them.
pub type Reply {
  Reply(executors: List(Entry))
}

/// The word that names a change in the reply.
///
/// ## Examples
///
/// ```gleam
/// assert executor_reload.change_word(executor_reload.Restarted) == "restarted"
/// ```
pub fn change_word(change: Change) -> String {
  case change {
    Started -> "started"
    Restarted -> "restarted"
    Stopped -> "stopped"
    Unchanged -> "unchanged"
    Failed -> "failed"
  }
}

/// The change a word names, or `Error(Nil)` for any other text.
///
/// ## Examples
///
/// ```gleam
/// assert executor_reload.change_of("stopped") == Ok(executor_reload.Stopped)
/// ```
pub fn change_of(word: String) -> Result(Change, Nil) {
  case word {
    "started" -> Ok(Started)
    "restarted" -> Ok(Restarted)
    "stopped" -> Ok(Stopped)
    "unchanged" -> Ok(Unchanged)
    "failed" -> Ok(Failed)
    _other -> Error(Nil)
  }
}

/// Says what happens to every name that the daemon holds or the file wants,
/// sorted by name with each name once.
///
/// A row that is in both is `Unchanged` when its host, port and pin are the
/// same and its link is alive, and `Restarted` otherwise: a dead link is
/// started again, and a changed address or pin replaces the link. The plan
/// never produces `Failed`, which only the reconciler can know.
///
/// ## Examples
///
/// ```gleam
/// let row = executor_reload.Row("box", "10.0.0.2", 7443, <<1>>)
/// let steps = executor_reload.plan([], [row])
/// assert list.map(steps, fn(step) { step.change }) == [executor_reload.Started]
/// ```
pub fn plan(held: List(Held), wanted: List(Row)) -> List(Step) {
  let held_by_name =
    list.map(held, fn(found) { #(found.row.name, found) }) |> dict.from_list
  let wanted_by_name =
    list.map(wanted, fn(row) { #(row.name, row) }) |> dict.from_list

  // A name that is in both tables is visited once.
  let names =
    list.append(dict.keys(held_by_name), dict.keys(wanted_by_name))
    |> list.unique
    |> list.sort(string.compare)

  list.map(names, fn(name) {
    step(
      name,
      dict.get(held_by_name, name) |> option.from_result,
      dict.get(wanted_by_name, name) |> option.from_result,
    )
  })
}

/// The step for one name.
fn step(name: String, held: Option(Held), wanted: Option(Row)) -> Step {
  case held, wanted {
    None, Some(row) -> Step(name, Started, None, Some(row))
    Some(found), None -> Step(name, Stopped, Some(found.row), None)
    Some(found), Some(row) ->
      Step(name, kept_or_replaced(found, row), Some(found.row), Some(row))

    // `plan` visits only names that are in one of the two tables, so no step
    // has neither row. The arm exists so the match stays exhaustive.
    None, None -> Step(name, Unchanged, None, None)
  }
}

/// A row in both tables stays as it is only when the link serves the same
/// address and pin and is running.
fn kept_or_replaced(found: Held, row: Row) -> Change {
  case found.row == row, found.link {
    True, Alive -> Unchanged
    True, Dead | False, Alive | False, Dead -> Restarted
  }
}

/// The rows the daemon holds after the steps are performed, sorted by name. A
/// `Failed` step leaves its row as it was.
///
/// ## Examples
///
/// ```gleam
/// let row = executor_reload.Row("box", "10.0.0.2", 7443, <<1>>)
/// assert executor_reload.applied(executor_reload.plan([], [row])) == [row]
/// ```
pub fn applied(steps: List(Step)) -> List(Row) {
  list.filter_map(steps, fn(step) {
    case step.change {
      Started | Restarted -> option.to_result(step.wanted, Nil)
      Unchanged | Failed -> option.to_result(step.held, Nil)
      Stopped -> Error(Nil)
    }
  })
}

/// What the caller is told about a set of steps: one entry for each, sorted by
/// name, each name once.
///
/// ## Examples
///
/// ```gleam
/// assert executor_reload.reply_of([]) == executor_reload.Reply([])
/// ```
pub fn reply_of(steps: List(Step)) -> Reply {
  let entries =
    list.map(steps, fn(step) { Entry(step.name, step.change) })
    |> list.sort(fn(a, b) { string.compare(a.name, b.name) })
    |> list.unique
  Reply(executors: entries)
}

/// Refuses a file with more untrusted rows than `max_rows`.
///
/// ## Examples
///
/// ```gleam
/// assert executor_reload.check_rows(512) == Ok(Nil)
/// assert executor_reload.check_rows(513) |> result.is_error
/// ```
pub fn check_rows(count: Int) -> Result(Nil, String) {
  case count > max_rows {
    True ->
      Error(
        "the file holds "
        <> int.to_string(count)
        <> " untrusted executors; a daemon accepts at most "
        <> int.to_string(max_rows),
      )
    False -> Ok(Nil)
  }
}

/// Refuses a reload that would bring the number of distinct untrusted names
/// the daemon has seen past `max_names`. `seen` counts the names the daemon
/// knew before this call together with the names of this file, each once.
///
/// ## Examples
///
/// ```gleam
/// assert executor_reload.check_names(1024) == Ok(Nil)
/// assert executor_reload.check_names(1025) |> result.is_error
/// ```
pub fn check_names(seen: Int) -> Result(Nil, String) {
  case seen > max_names {
    True ->
      Error(
        "the daemon would have seen "
        <> int.to_string(seen)
        <> " distinct untrusted executor names; the most it accepts is "
        <> int.to_string(max_names),
      )
    False -> Ok(Nil)
  }
}

/// Decides whether the `[executor_link]` table of the new file may be applied.
///
/// A table the daemon started with is kept as it is, and a changed one is not
/// applied, because rotating the credentials of a running link is a restart.
/// A daemon that started with no table may take one, but only when each of its
/// three files is under one of the `allowed` directories, which are the
/// directories that every jail masks from its start. A table anywhere else
/// could name a key that a session already open can read.
///
/// The caller passes paths that are canonical, so a prefix test is the whole of
/// the check. A caller that cannot make a file of a proposed table canonical
/// refuses the call and never reaches this rule with the path as written,
/// because `vm/../../elsewhere/k` begins with the vm home and is not inside it.
/// Only the started table may be passed with a path as written, since it is
/// compared for equality with itself.
///
/// ## Examples
///
/// ```gleam
/// assert executor_reload.link_rule(None, None, ["/home/u/.loom/vm"]) == Ok(Nil)
/// ```
pub fn link_rule(
  started: Option(Credentials),
  proposed: Option(Credentials),
  allowed: List(String),
) -> Result(Nil, String) {
  case started == proposed, started, proposed {
    True, _, _ -> Ok(Nil)
    False, Some(_), _ ->
      Error(
        "[executor_link] differs from the table this daemon started with; restart it to apply that",
      )
    False, None, None -> Ok(Nil)
    False, None, Some(table) -> files_under(table, allowed)
  }
}

/// Every file of a table is under an allowed directory.
fn files_under(
  table: Credentials,
  allowed: List(String),
) -> Result(Nil, String) {
  list.try_each([table.ca, table.certificate, table.key], fn(path) {
    case list.any(allowed, under(path, _)) {
      True -> Ok(Nil)
      False ->
        Error(
          "[executor_link] names "
          <> path
          <> ", which is not under the vm home; restart the daemon to apply a new [executor_link]",
        )
    }
  })
}

/// The directory with exactly one trailing slash.
fn slashed(directory: String) -> String {
  // A directory given with a trailing slash already ends as a prefix must.
  case string.ends_with(directory, "/") {
    True -> directory
    False -> directory <> "/"
  }
}

/// Whether `path` is inside `directory`: the directory followed by a slash and
/// at least one more character. The directory itself is not inside it.
fn under(path: String, directory: String) -> Bool {
  let prefix = slashed(directory)
  string.starts_with(path, prefix)
  && string.length(path) > string.length(prefix)
}

/// The reply as the control socket carries it.
///
/// ## Examples
///
/// ```gleam
/// assert json.to_string(executor_reload.encode(executor_reload.Reply([])))
///   == "{\"executors\":[]}"
/// ```
pub fn encode(reply: Reply) -> JsonValue {
  json.Object([
    #(
      "executors",
      json.Array(
        list.map(reply.executors, fn(entry) {
          json.Object([
            #("name", json.String(entry.name)),
            #("change", json.String(change_word(entry.change))),
          ])
        }),
      ),
    ),
  ])
}

/// Reads a reply. It accepts at most `max_rows` entries, each with a name that
/// satisfies the executor grammar and one of the five change words, in strictly
/// ascending order of name, and refuses everything else.
///
/// ## Examples
///
/// ```gleam
/// let reply = executor_reload.Reply([executor_reload.Entry("box", executor_reload.Started)])
/// assert executor_reload.decode(executor_reload.encode(reply)) == Ok(reply)
/// ```
pub fn decode(value: JsonValue) -> Result(Reply, String) {
  case value {
    json.Object(fields) ->
      case list.key_find(fields, "executors") {
        Ok(json.Array(items)) -> entries_of(items)
        Ok(_other) | Error(Nil) -> Error("executors is not an array")
      }
    _other -> Error("the reply is not an object")
  }
}

/// The entries of the array, within the bound and in order.
fn entries_of(items: List(JsonValue)) -> Result(Reply, String) {
  // The bound is checked before any entry is read, so a long array costs one
  // pass over at most one more element than the limit.
  case list.length(list.take(items, max_rows + 1)) > max_rows {
    True -> Error("the reply lists more than the most a daemon sends")
    False -> {
      use entries <- result.try(list.try_map(items, entry_of))
      use Nil <- result.map(ascending(entries))
      Reply(executors: entries)
    }
  }
}

/// One entry: an object with a `name` and a `change`.
fn entry_of(item: JsonValue) -> Result(Entry, String) {
  // An entry is an object, and nothing else is read as one.
  case item {
    json.Object(fields) -> {
      use name <- result.try(name_field(list.key_find(fields, "name")))
      use change <- result.map(change_field(list.key_find(fields, "change")))
      Entry(name:, change:)
    }
    _other -> Error("an entry is not an object")
  }
}

/// An entry's name: a string in the executor grammar.
fn name_field(found: Result(JsonValue, Nil)) -> Result(String, String) {
  // Only a string can be a name, and only some strings are.
  case found {
    Ok(json.String(text)) -> valid_name(text)
    Ok(_other) | Error(Nil) -> Error("an entry has no name")
  }
}

fn valid_name(text: String) -> Result(String, String) {
  case catalogue.is_executor_name(text) {
    True -> Ok(text)
    False -> Error("an entry names an executor that has no valid name")
  }
}

/// An entry's change: one of the five words.
fn change_field(found: Result(JsonValue, Nil)) -> Result(Change, String) {
  // Only a string can be a change word.
  case found {
    Ok(json.String(word)) ->
      change_of(word)
      |> result.replace_error("an entry has a change that is not known")
    Ok(_other) | Error(Nil) -> Error("an entry has no change")
  }
}

/// Names strictly ascend, so each is listed once.
fn ascending(entries: List(Entry)) -> Result(Nil, String) {
  let names = list.map(entries, fn(entry) { entry.name })

  // Every neighbouring pair must ascend, which also rules out a repeat.
  case list.window_by_2(names) |> list.all(in_order) {
    True -> Ok(Nil)
    False -> Error("the entries are not sorted by name, each name once")
  }
}

fn in_order(pair: #(String, String)) -> Bool {
  string.compare(pair.0, pair.1) == order.Lt
}

/// A row's pin as lower-case hexadecimal, for the log line that records a
/// change. A pin is a public value.
///
/// ## Examples
///
/// ```gleam
/// assert executor_reload.pin_text(<<1, 255>>) == "01ff"
/// ```
pub fn pin_text(pin: BitArray) -> String {
  bit_array.base16_encode(pin) |> string.lowercase
}

/// A row as a log line writes it: `host:port pin`, or `none` for a row that is
/// not there.
///
/// ## Examples
///
/// ```gleam
/// assert executor_reload.describe(None) == "none"
/// ```
pub fn describe(row: Option(Row)) -> String {
  case row {
    Some(found) ->
      found.host
      <> ":"
      <> int.to_string(found.port)
      <> " "
      <> pin_text(found.pin)
    None -> "none"
  }
}
