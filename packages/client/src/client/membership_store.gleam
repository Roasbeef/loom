//// The membership ledger's file: one signed line per entry, kept in order,
//// replayed at boot and extended one durable line at a time.
////
//// A node's copy of the ledger (protocol-change/086) is a text file of lines
//// separated by `\n`. The file is the only record of what the node has
//// applied, so everything the node later says to a peer or to its own TLS
//// verify callback must already be in it. This module owns that file and
//// nothing else. It does not decide whether an entry is valid. The pure
//// fold in `client/membership_ledger` does, and the process in
//// `client/ledger_service` calls this module only for entries the fold
//// accepted.
////
//// ## Opening
////
//// `open` reads the file, drops a torn final line, and replays the rest
//// through `membership_ledger.replay`, so the ledger a node boots with is the
//// fold of exactly the lines on disk. A line that does not verify, does not
//// chain or breaks a rule of the fold stops the open with the number of the
//// line, and the node does not start. Nothing is repaired silently except a
//// final line with no `\n`: an append writes the line and its terminator
//// together, so a line without one is a write that did not finish, and no
//// peer was ever told the node held it.
////
//// ## Appending
////
//// An append writes the whole file again beside the old one, flushes it with
//// `fsync`, and renames it over the old one (`bootstrap.atomic_write_private`,
//// the helper the credentials and bundles use). A reader or a crash therefore
//// sees the old file or the new file and never a partial one. The cost is a
//// write proportional to the file, at most 10,000 entries, for each append.
//// Entries are written by an operator a few times in a deployment's life, and
//// a node that catches up writes once per entry it applies, so the simple
//// mechanism beats a positioned append with an `fsync` of its own, which
//// would need a new Erlang function for the sake of avoiding a rewrite of a
//// few kilobytes.
////
//// The durability assumption is the one the other durable files here make:
//// `fsync` and an atomic rename survive a crash on the file systems the daemon
//// runs on. The tests cannot show it. They show the two states a crash can
//// leave behind, a file that ends in a torn line and a file that is whole.

import client/membership_entry.{type SignedEntry, type Verifier}
import client/membership_ledger.{type Ledger}
import gleam/bit_array
import gleam/bool
import gleam/dict.{type Dict}
import gleam/list
import gleam/result
import gleam/string
import host/bootstrap

/// The largest ledger file `open` reads: 10,000 entries of at most about
/// 5.6 KB each, rounded up. A larger file cannot be a valid ledger.
pub const max_file_bytes = 67_108_864

/// The file of a ledger and the lines it holds, by sequence number.
///
/// Opaque, so the only stores are those `open` read from a file that replayed
/// and those `append` extended after the file took the new line.
pub opaque type Store {
  Store(
    /// The absolute path of the file.
    path: String,
    /// The whole file as it is on disk: every line followed by `\n`.
    text: String,
    /// The line of each entry, keyed by its sequence number.
    lines: Dict(Int, BitArray),
  )
}

/// What `open` did about the end of the file.
pub type Tail {
  /// The file ended in a complete line, or was empty after the last one.
  Clean

  /// The file ended in a line with no `\n`. The line was dropped from memory
  /// and from disk, and `bytes` is how many bytes it had.
  Repaired(bytes: Int)
}

/// A ledger read from its file.
pub type Opened {
  Opened(
    /// The store, ready to append to.
    store: Store,
    /// The fold of every line in the file.
    ledger: Ledger,
    /// Whether the end of the file had to be repaired.
    tail: Tail,
  )
}

/// Why a file did not open. None of the variants carries file contents.
pub type OpenError {
  /// The file could not be read: it is missing, unreadable, over
  /// `max_file_bytes`, or not text.
  Unreadable(reason: String)

  /// The file holds no complete line, so there is no genesis entry.
  NoGenesis

  /// A line is not a valid entry for the chain that precedes it.
  Corrupt(
    /// The one-based number of the line in the file.
    line: Int,
    /// Why the ledger refused it.
    refusal: membership_ledger.Refusal,
  )

  /// The torn final line could not be removed from the file.
  RepairFailed(reason: String)
}

/// Why an entry could not be made durable.
pub type AppendError {
  /// The file could not be written. The store is unchanged and so is the file.
  Unwritable(reason: String)
}

/// Reads the ledger file at `path`, repairs a torn final line, and replays it
/// with `verifier`.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(Opened(store:, ledger:, tail: Clean)) =
///   membership_store.open("/home/me/.loom/ledger.log", verifier)
/// ```
pub fn open(path: String, verifier: Verifier) -> Result(Opened, OpenError) {
  use bytes <- result.try(
    bootstrap.read_bounded(path, max_file_bytes)
    |> result.map_error(Unreadable),
  )
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.replace_error(Unreadable("the file is not text")),
  )
  let #(complete, torn) = split_lines(text)
  use <- guard_genesis(complete)
  use ledger <- result.try(
    membership_ledger.replay(
      list.map(complete, bit_array.from_string),
      verifier,
    )
    |> result.map_error(fn(error) {
      Corrupt(line: error.index + 1, refusal: error.refusal)
    }),
  )
  let store = from_lines(path, complete)
  use tail <- result.try(repair(store, torn))
  Ok(Opened(store:, ledger:, tail:))
}

// A file with no complete line has no genesis. The check comes before the
// replay so the error is the plain one, and not a refusal of a line 0 that
// does not exist.
fn guard_genesis(
  complete: List(String),
  next: fn() -> Result(Opened, OpenError),
) -> Result(Opened, OpenError) {
  case complete {
    [] -> Error(NoGenesis)
    [_, ..] -> next()
  }
}

// The text before each `\n`, and what follows the last one. Splitting on `\n`
// always yields one more piece than there are terminators, so the last piece
// is the unterminated remainder and is empty for a file that ends cleanly.
fn split_lines(text: String) -> #(List(String), String) {
  case list.reverse(string.split(text, "\n")) {
    [] -> #([], "")
    [torn, ..before] -> #(list.reverse(before), torn)
  }
}

fn from_lines(path: String, complete: List(String)) -> Store {
  Store(
    path:,
    text: terminated(complete),
    lines: dict.from_list(
      list.index_map(complete, fn(line, seq) {
        #(seq, bit_array.from_string(line))
      }),
    ),
  )
}

fn terminated(lines: List(String)) -> String {
  string.concat(list.map(lines, fn(line) { line <> "\n" }))
}

// A torn tail is cut from the file before the node writes anything after it,
// or the next append would join its line to the fragment.
fn repair(store: Store, torn: String) -> Result(Tail, OpenError) {
  case torn {
    "" -> Ok(Clean)
    _ ->
      bootstrap.atomic_write_private(store.path, store.text)
      |> result.map(fn(_) { Repaired(bytes: string.byte_size(torn)) })
      |> result.map_error(RepairFailed)
  }
}

/// Makes an applied entry durable: the file holds its line, flushed, before
/// this returns `Ok`. The caller passes only entries the ledger accepted, so
/// the line's sequence number is the next one in the file.
///
/// ## Examples
///
/// ```gleam
/// let assert Ok(store) = membership_store.append(store, signed_entry)
/// ```
pub fn append(store: Store, signed: SignedEntry) -> Result(Store, AppendError) {
  let line = membership_entry.line(signed)
  use text <- result.try(
    bit_array.to_string(line)
    |> result.replace_error(Unwritable("the line is not text")),
  )
  let next = store.text <> text <> "\n"
  use Nil <- result.try(
    bootstrap.atomic_write_private(store.path, next)
    |> result.map_error(Unwritable),
  )
  Ok(
    Store(
      ..store,
      text: next,
      lines: dict.insert(store.lines, signed.entry.seq, line),
    ),
  )
}

/// The lines after sequence number `after`, in order: at most `limit` of them
/// and at most `max_bytes` bytes in all. A peer's pull reads this.
///
/// ## Examples
///
/// ```gleam
/// membership_store.lines_after(store, 7, 64, 262_144) // -> [line8, line9]
/// ```
pub fn lines_after(
  store: Store,
  after: Int,
  limit: Int,
  max_bytes: Int,
) -> List(BitArray) {
  take(store, after + 1, limit, max_bytes, [])
}

fn take(
  store: Store,
  seq: Int,
  left: Int,
  bytes_left: Int,
  taken: List(BitArray),
) -> List(BitArray) {
  use <- bool.guard(when: left <= 0, return: list.reverse(taken))
  case dict.get(store.lines, seq) {
    Error(Nil) -> list.reverse(taken)
    Ok(line) -> {
      let size = bit_array.byte_size(line)
      use <- bool.guard(when: size > bytes_left, return: list.reverse(taken))
      take(store, seq + 1, left - 1, bytes_left - size, [line, ..taken])
    }
  }
}

/// How many entries the store holds.
///
/// ## Examples
///
/// ```gleam
/// membership_store.count(store) // -> 10
/// ```
pub fn count(store: Store) -> Int {
  dict.size(store.lines)
}

/// The path of the file.
///
/// ## Examples
///
/// ```gleam
/// membership_store.path(store) // -> "/home/me/.loom/ledger.log"
/// ```
pub fn path(store: Store) -> String {
  store.path
}
